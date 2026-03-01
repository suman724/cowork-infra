# Domain Model Reference

This document is the authoritative reference for all core domain concepts in the Local First Agent System. All services, repos, and implementation work should use this as the source of truth for terminology, relationships, and ownership.

---

## Entity Hierarchy

```
Workspace
  └── Session  (one or more per workspace, over time)
        └── Task  (one or more per session)
              └── Step  (one or more per task)
                    ├── LLM Call
                    ├── Tool Call  (zero or more per step)
                    ├── Approval   (zero or more per step)
                    └── Artifact   (zero or more per step)
```

Every session always has a workspace. There are no workspace-less sessions.

---

## Entities

### Workspace

A backend namespace that scopes a session's history and artifacts for a given project or user context. Auto-created by the Session Service — the user never explicitly creates one.

| Attribute | Type | Description |
|-----------|------|-------------|
| `workspaceId` | string | Unique identifier assigned by the Workspace Service |
| `workspaceScope` | enum | Where the source files live (see below) |
| `createdAt` | datetime | When the workspace was first created |
| `lastActiveAt` | datetime | Last time a session was created under this workspace |

**workspaceScope values:**

| Value | Source files | Reuse policy | When used |
|-------|-------------|--------------|-----------|
| `local` | Live on the client machine. No project files uploaded to backend. | Reused across many sessions — one workspace per project. | Desktop project sessions |
| `general` | May exist, scoped to this session only. | Single-use — a new workspace is created for each general chat session. Nothing carries over to the next chat. | Desktop general chat |
| `cloud` | Live in a cloud sandbox in the backend. | TBD (Phase 3+). | Web sessions |

The distinction between `local` and `general` is **reuse policy**, not the presence of files. A `general` workspace can hold files and context, but it is not shared across general chat sessions.

**What a workspace stores:**
- `session_history` artifacts — the full conversation thread per session, uploaded after each task
- Agent-produced artifacts — tool outputs, generated files, diffs created by the agent

**What a workspace does NOT store:**
- Project source files — these always stay on the client machine or in the cloud sandbox

**Lifecycle:**
- `local` workspaces: created once per project, reused across all future sessions on that project — long-lived, accumulates history and artifacts over time
- `general` workspaces: created fresh for each general chat session — single-use, contains only the history and artifacts from that one session
- `cloud` workspaces: lifecycle TBD (Phase 3+)
- A user can explicitly delete a workspace; all artifacts and session history are permanently removed
- Auto-purge after 90 days of inactivity (implementation deferred)

**Owned by:** Workspace Service

---

### Session

The governance container for one continuous working period. From the user's perspective in the UI, a session is a **conversation**.

| Attribute | Type | Description |
|-----------|------|-------------|
| `sessionId` | string | Unique identifier |
| `workspaceId` | string | Always present — every session has a workspace |
| `tenantId` | string | Tenant the session belongs to |
| `userId` | string | User who owns the session |
| `executionEnvironment` | enum | Where the agent is running (see below) |
| `status` | enum | Current state machine state (see below) |
| `createdAt` | datetime | Session creation time |
| `expiresAt` | datetime | Policy bundle expiry |

**executionEnvironment values:**

| Value | Meaning |
|-------|---------|
| `desktop` | Agent runs locally via Desktop App and Local Agent Host |
| `cloud_sandbox` | Agent runs in a backend sandbox (Phase 3+) |

> `executionEnvironment` answers "where is the agent running?"
> `workspaceScope` answers "where do the source files live?"
> These are independent — the same workspace can be accessed from different environments.

**Session state machine:**

```
SESSION_CREATED
  └── SESSION_RUNNING
        ├── WAITING_FOR_LLM
        ├── WAITING_FOR_TOOL
        ├── WAITING_FOR_APPROVAL
        └── SESSION_PAUSED
              └── SESSION_COMPLETED
              └── SESSION_FAILED
              └── SESSION_CANCELLED
```

**What a session holds:**
- Policy bundle (capabilities, approval rules, LLM policy) — received over authenticated HTTPS, validated by expiry and session id match
- LLM Gateway config is NOT part of the session — endpoint and auth token are read from local environment variables (`LLM_GATEWAY_ENDPOINT`, `LLM_GATEWAY_AUTH_TOKEN`)
- Token budget limits
- Feature flags
- In-memory message thread (owned by Local Agent Host during the session)

**Session end conditions:**
- User explicitly closes the session
- Policy bundle expires
- Session is cancelled

**Terminology note:** The design doc uses "session" throughout. The Desktop App UI shows the user a "conversation". These are the same entity — different vocabulary for different audiences.

**Owned by:** Session Service (lifecycle); Local Agent Host (state machine and message thread during execution)

---

### Task

A single agent work cycle triggered by one user prompt. One session contains one or more tasks — each task is one conversational turn.

| Attribute | Type | Description |
|-----------|------|-------------|
| `taskId` | string | Unique identifier, scoped to the session |
| `sessionId` | string | Parent session |
| `prompt` | string | The user's instruction |
| `maxSteps` | integer | Maximum number of agent loop iterations allowed |
| `allowNetwork` | boolean | Whether outbound network tool calls are permitted |
| `approvalMode` | enum | When to require user approval (`always`, `on_risky_actions`, `never`) |
| `status` | enum | `running`, `completed`, `failed`, `cancelled` |

**Key behaviours:**
- Can be cancelled independently without ending the session
- When a task completes, the full session message thread is uploaded to the Workspace Service as a `session_history` artifact
- Cancelling a task does not destroy the policy bundle or session state — the user can start a new task immediately

**Owned by:** Local Agent Host

---

### Step

One iteration of the agent loop inside a task. Consists of one LLM call followed by zero or more tool calls based on the model's response.

| Attribute | Type | Description |
|-----------|------|-------------|
| `stepId` | string | Unique identifier, scoped to the task |
| `taskId` | string | Parent task |
| `sessionId` | string | Parent session |

**A step contains:**
- Exactly one LLM call
- Zero or more tool calls (executed by Local Tool Runtime)
- Zero or more approval requests (if tool calls require approval)
- Zero or more artifact outputs

**Owned by:** Local Agent Host

---

### Message

One entry in the session's conversation thread.

| Attribute | Type | Description |
|-----------|------|-------------|
| `messageId` | string | Unique identifier |
| `sessionId` | string | Parent session |
| `taskId` | string | The task this message was generated in |
| `stepId` | string | The step this message was generated in |
| `role` | enum | `system`, `user`, `assistant`, `tool` |
| `content` | string | Message content |
| `tokenCount` | integer | Token count for this message |
| `timestamp` | datetime | When the message was created |

Messages accumulate across all tasks in a session to form the full conversation thread. The Local Agent Host holds the full thread in memory during the session and passes it to the LLM Gateway on every LLM call.

**Owned by:** Local Agent Host (in-memory during session); Workspace Service (via `session_history` artifact)

---

### session_history Artifact

A snapshot of the full session message thread, uploaded to the Workspace Service after each task completes. This is the canonical store of conversation history — the Desktop App and future web client always read from it.

| Attribute | Type | Description |
|-----------|------|-------------|
| `artifactType` | string | Always `session_history` |
| `workspaceId` | string | The workspace this belongs to |
| `sessionId` | string | The session this history belongs to |
| `snapshotAfterTaskId` | string | The last completed task at the time of this snapshot |
| `snapshotAt` | datetime | When the snapshot was taken |
| `messages` | Message[] | The full conversation thread up to this snapshot |

One `session_history` artifact exists per session. Each task completion overwrites the previous snapshot with a complete up-to-date thread.

**Owned by:** Workspace Service

---

## ID Chain

Every event, tool call, artifact, and audit record carries the full chain:

```
workspaceId → sessionId → taskId → stepId
```

All four IDs are always present. `workspaceId` is never null — every session has a workspace.

---

## Message Storage Model

| Layer | Storage | Purpose | Lifecycle |
|-------|---------|---------|-----------|
| In-flight | Memory in Local Agent Host | LLM request construction | Exists for the duration of the active session |
| Crash recovery | Local State Store (checkpoint) | Recover from unexpected desktop restart or crash | Written after each step; **deleted on clean session end** |
| Canonical history | Workspace Service (`session_history` artifact) | History browsing, cross-device access, session continuation | Written after each task; persists for workspace lifetime |

**The Local State Store is purely transient.** It is a crash recovery buffer only. It is never used for history browsing. When a session ends cleanly, the checkpoint is deleted.

**History is always fetched from the backend.** The Desktop App reads session history from the Workspace Service. This keeps the desktop and web implementations identical.

---

## Session Resume — Two Scenarios

### Scenario A: Crash Recovery

The desktop restarted or crashed while a session was active. The session did not end cleanly.

```
1. Desktop App launches
2. Local Agent Host detects existing checkpoint in Local State Store
3. Loads checkpoint → reconstructs in-memory message thread
4. Calls Session Service → re-validates policy and gets current limits
5. Continues execution from the checkpoint cursor
```

The Local State Store checkpoint makes this possible. Works identically for all session types.

### Scenario B: Continue a Past Conversation

The session ended cleanly. The user wants to pick up where they left off in a new session.

```
1. User opens Desktop App and selects a past conversation
2. Desktop App creates a new session under the same workspace
3. Fetches session_history artifact from Workspace Service
4. Bootstraps new session's message thread from the artifact
5. User continues the conversation seamlessly
```

The `session_history` artifact makes this possible. The Local State Store is not involved.

---

## Session Types

| Type | workspaceScope | Workspace creation | Workspace reuse | Session history |
|------|---------------|-------------------|-----------------|-----------------|
| **Project session** | `local` | Auto-resolved from `workspaceHint` (local directory path) | Reused across sessions — one per project | Uploaded to Workspace Service after each task |
| **General chat** | `general` | Auto-created fresh for each session | Single-use — not shared across general chat sessions | Uploaded to Workspace Service after each task |
| **Web session** (Phase 3+) | `cloud` | Auto-created or resolved | TBD | Uploaded to Workspace Service after each task |

---

## Service Ownership

| Concept | Owned by |
|---------|----------|
| Workspace lifecycle | Workspace Service |
| Workspace artifact storage | Workspace Service |
| `session_history` artifact | Workspace Service |
| Session lifecycle and metadata | Session Service |
| Workspace resolution at session creation | Session Service |
| Session state machine | Local Agent Host |
| In-memory message thread | Local Agent Host |
| Task execution | Local Agent Host |
| Step execution | Local Agent Host |
| Local State Store checkpoint | Local Agent Host |
| Tool execution | Local Tool Runtime |
| Approval decisions | Approval Service |
| Policy bundle generation | Policy Service |
| LLM routing and guardrails | LLM Gateway (external — not implemented) |
| Audit records | Audit Service |
| Telemetry and traces | Telemetry Service |

---

## Key Distinctions

| Pair | Distinction |
|------|------------|
| `workspaceScope` vs `executionEnvironment` | `workspaceScope` = where source files live; `executionEnvironment` = where the agent runs |
| Session vs Conversation | Same entity — "session" in the codebase, "conversation" in the UI |
| Crash recovery vs Continue conversation | Crash recovery uses Local State Store checkpoint; continuation uses `session_history` from Workspace Service |
| Local State Store vs Workspace Service | Local State Store = transient crash buffer; Workspace Service = canonical history and artifact store |
| Task cancel vs Session end | Cancelling a task does not end the session; the user can start a new task immediately |
