# Workspace Service — Detailed Design

**Phase:** 1 (MVP)
**Repo:** `cowork-workspace-service`
**Bounded Context:** WorkspaceArtifacts

---

## Purpose

The Workspace Service is the canonical backend store for agent-produced artifacts and session conversation history. It provides the storage layer that makes history browsing, cross-device access, and session continuation possible.

---

## Responsibilities

- Workspace lifecycle — create, retrieve, delete
- Artifact upload and retrieval (tool outputs, diffs, generated files)
- Session history storage — store and serve `session_history` artifacts
- Workspace auto-purge after 90 days of inactivity (deferred)
- Storage adapter abstraction over the underlying Artifact Store and Metadata Store

---

## What the Workspace Service Stores

| Artifact Type | Produced by | When |
|---|---|---|
| `session_history` | Local Agent Host | After each task completes — overwrites previous snapshot for the same session |
| `tool_output` | Local Tool Runtime (via Local Agent Host) | After a tool call produces output |
| `file_diff` | Local Tool Runtime (via Local Agent Host) | After a file write or edit |

**What it does NOT store:**
- Project source files — these stay on the client machine
- Live session state (that's the Local State Store on the desktop)
- Audit records (that's the Audit Service)

---

## Relationships

| Called by | Purpose |
|-----------|---------|
| Session Service | Create or resolve workspace at session start |
| Local Agent Host | Upload `session_history` after each task; upload tool output artifacts |
| Desktop App | Fetch session history for browsing; fetch artifacts |

---

## Workspace Model

| Field | Type | Description |
|-------|------|-------------|
| `workspaceId` | string | Unique identifier |
| `workspaceScope` | enum | `local`, `general`, or `cloud` |
| `tenantId` | string | Tenant |
| `userId` | string | Owner |
| `localPath` | string (optional) | The local directory this workspace maps to — present for `local`-scoped workspaces only |
| `createdAt` | datetime | |
| `lastActiveAt` | datetime | Updated on every artifact upload — used for auto-purge |

### workspaceScope

| Value | Meaning | Reuse |
|-------|---------|-------|
| `local` | Maps to a project directory on client machine. No source files uploaded. | Reused across many sessions for the same project |
| `general` | General chat with no project directory. May have files scoped to this session. | Single-use — one workspace per session |
| `cloud` | Files in cloud sandbox (Phase 3+) | TBD |

---

## API Endpoints

### POST /workspaces — Create Workspace

Called by Session Service during session creation.

**Request:**
```json
{
  "tenantId": "tenant_abc",
  "userId": "user_123",
  "workspaceScope": "local",
  "localPath": "/Users/suman/projects/demo"
}
```

**Idempotency:** For `local`-scoped workspaces, the service resolves by `(tenantId, userId, localPath)` — if a workspace already exists for that path it is returned rather than creating a duplicate.

For `general`-scoped workspaces, a new workspace is always created.

**Response:**
```json
{
  "workspaceId": "ws_456",
  "workspaceScope": "local",
  "createdAt": "2026-02-21T14:00:00Z"
}
```

---

### POST /workspaces/{workspaceId}/artifacts — Upload Artifact

Called by the Local Agent Host to upload tool output artifacts or session history snapshots.

**Request — tool output:**
```json
{
  "sessionId": "sess_789",
  "taskId": "task_001",
  "stepId": "step_006",
  "artifactType": "tool_output",
  "artifactName": "pytest_output.txt",
  "contentType": "text/plain",
  "contentBase64": "cHl0ZXN0IG91dHB1dA==",
  "metadata": {
    "toolName": "RunCommand"
  }
}
```

**Request — session history snapshot:**
```json
{
  "sessionId": "sess_789",
  "artifactType": "session_history",
  "snapshotAfterTaskId": "task_003",
  "snapshotAt": "2026-02-21T16:00:00Z",
  "messages": [
    {
      "messageId": "msg_001",
      "role": "system",
      "content": "...",
      "timestamp": "2026-02-21T14:00:00Z"
    },
    {
      "messageId": "msg_002",
      "role": "user",
      "content": "Refactor the API client",
      "timestamp": "2026-02-21T14:01:00Z"
    }
  ]
}
```

**Session history overwrite semantics:** There is one `session_history` artifact per session. Each upload for the same `sessionId` replaces the previous snapshot entirely.

**Response:**
```json
{
  "artifactId": "art_123",
  "artifactUri": "workspaces/ws_456/artifacts/art_123"
}
```

---

### GET /workspaces/{workspaceId}/artifacts/{artifactId} — Retrieve Artifact

Called by the Desktop App to fetch session history or tool output for display.

**Response:** Artifact payload (JSON for `session_history`, binary for file artifacts)

---

### GET /workspaces/{workspaceId}/sessions — List Sessions in Workspace

Called by the Desktop App to show the conversation history list for a project. Sessions are aggregated from artifact metadata (grouped by `sessionId`), sorted by most recent activity first.

**Query Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `limit` | int (1–100) | 20 | Page size |
| `nextToken` | string | — | Opaque cursor for next page |

**Response:**
```json
{
  "sessions": [
    {
      "sessionId": "sess_789",
      "createdAt": "2026-02-21T14:00:00Z",
      "lastTaskAt": "2026-02-21T16:00:00Z",
      "taskCount": 4
    }
  ],
  "nextToken": "eyJvZmZzZXQiOiAyMH0="
}
```

`nextToken` is only present when more pages exist. Pass it as a query parameter to fetch the next page.

---

## Workspace Lifecycle

```
Created (by Session Service at session start)
  │
  ├── Artifacts uploaded throughout session lifetime
  │
  ├── User explicitly deletes workspace
  │     └── All artifacts and session history permanently removed
  │
  └── 90 days of inactivity (lastActiveAt not updated)
        └── Auto-purge (implementation deferred)
```

---

## Storage Architecture

The Workspace Service uses two stores:

| Store | Technology | Holds |
|-------|-----------|-------|
| **Metadata Store** | DynamoDB | Workspace records, artifact metadata, session lists |
| **Artifact Store** | S3 | Raw artifact content (binary, text, JSON payloads) |

The API layer never exposes the underlying store — clients always go through the service.

### DynamoDB — `{env}-workspaces` table

Stores workspace records.

| Key | Value |
|-----|-------|
| Partition key | `workspaceId` (String) |

| GSI | Partition key | Sort key | Use |
|-----|--------------|----------|-----|
| `tenantId-userId-index` | `tenantId` | `userId` | List workspaces for a user |
| `localpath-lookup-index` | `localPathKey`* | — | Idempotent resolve of `local`-scoped workspaces |

*`localPathKey` is a composite attribute: `{tenantId}#{userId}#{localPath}` — populated only for `local`-scoped workspaces.

Stored attributes: `workspaceId`, `tenantId`, `userId`, `workspaceScope`, `localPath`, `localPathKey`, `createdAt`, `lastActiveAt`

### DynamoDB — `{env}-artifacts` table

Stores artifact metadata. Artifact content lives in S3; this table holds the pointer.

| Key | Value |
|-----|-------|
| Partition key | `workspaceId` (String) |
| Sort key | `artifactId` (String) |

| GSI | Partition key | Sort key | Use |
|-----|--------------|----------|-----|
| `sessionId-type-index` | `sessionId` | `artifactType#createdAt` | Retrieve `session_history` for a session; list tool outputs |

Stored attributes: `workspaceId`, `artifactId`, `sessionId`, `taskId`, `artifactType`, `artifactName`, `contentType`, `s3Key`, `createdAt`

### S3 — `{env}-workspace-artifacts` bucket

Stores raw artifact content. Each object is addressed by:

```
s3://{env}-workspace-artifacts/{workspaceId}/{artifactId}
```

The `s3Key` attribute in the DynamoDB artifact record is the full S3 object key.

### Testing

| Tier | Infrastructure |
|------|---------------|
| Unit tests | `InMemoryWorkspaceRepository` — no infrastructure needed |
| Service tests | DynamoDB Local + LocalStack S3: both accessible via LocalStack on port 4566 |
| Integration tests | LocalStack: `docker run -p 4566:4566 localstack/localstack` — emulates both DynamoDB and S3 together |

The Workspace Service is the primary reason LocalStack is preferred over DynamoDB Local for integration tests — it needs both S3 and DynamoDB running simultaneously.

```bash
# LocalStack covers both stores
AWS_ENDPOINT_URL=http://localhost:4566
```
