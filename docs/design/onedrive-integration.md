# OneDrive Integration — Design Doc

**Status:** Proposed
**Scope:** Workspace Service, Session Service, Web App, Platform Contracts
**Date:** 2026-03-15

---

## Problem

Cowork supports two workspace scopes for file access: `local` (direct filesystem on desktop) and `cloud` (S3-backed for web sandbox). Users who store their project files in OneDrive cannot use them in web sessions — they must manually upload files through the browser, losing the folder structure and context of their existing project.

On desktop, OneDrive is mapped as a local drive, so users can already point a `local` workspace at a OneDrive-synced folder with no special handling. The gap is **web/sandbox only**: the agent runtime runs in a container with no access to the user's OneDrive.

---

## Goals

1. Allow users to associate a OneDrive folder with a workspace and launch web sessions against it
2. Agent runtime works on OneDrive files identically to S3-backed cloud workspaces — no tool changes
3. Modified files are written back to OneDrive at task completion
4. No changes to agent-runtime, tool-runtime, or desktop app
5. Support personal OneDrive and SharePoint document libraries (same Graph API)

## Non-Goals

- Desktop-specific OneDrive handling (unnecessary — OS handles it)
- Real-time sync during task execution (last-write-wins at push-back)
- Lazy/on-demand file fetching (eager download at startup)
- Staging area for review before write-back (direct write-back, OneDrive version history as undo)

---

## Design Overview

OneDrive integration follows the same pattern as existing S3-backed cloud workspaces. The Workspace Service gets a new `FileStore` implementation that calls Microsoft Graph API instead of S3. The agent runtime is unaware of the change — it calls the same Workspace Service HTTP API.

```
                          ┌─────────────────────┐
                          │      Web App         │
                          │  (folder picker UI)  │
                          └──────────┬───────────┘
                                     │ POST /sessions
                                     │ { oneDrive: { driveId, folderItemId, tokens } }
                                     ▼
                          ┌─────────────────────┐
                          │   Session Service    │
                          │  (token custodian)   │
                          │  stores + refreshes  │
                          │  OneDrive tokens     │
                          └──────────┬───────────┘
                                     │ X-Graph-Access-Token header
                                     ▼
                          ┌─────────────────────┐
                          │  Workspace Service   │
                          │  OneDriveFileStore   │◄──── Microsoft Graph API
                          │  (new FileStore impl)│      /me/drive/items/{id}/...
                          └──────────┬───────────┘
                                     │ same HTTP API as S3
                                     ▼
                          ┌─────────────────────┐
                          │   Sandbox Container  │
                          │  download_workspace()│
                          │  agent works locally │
                          │  upload_workspace()  │
                          └─────────────────────┘
```

### Key Property

From the sandbox container's perspective, nothing changes. It calls `GET /workspaces/{id}/files` and `POST /workspaces/{id}/files?path=X` — the same HTTP API used for S3-backed workspaces.

**Sandbox always routes through Session Service proxy** — for all workspace types. The `workspace_service_url` returned during registration always points to Session Service proxy endpoints. Session Service forwards to Workspace Service, injecting the `X-Graph-Access-Token` header for OneDrive workspaces (pass-through for S3).

```
All workspace types (S3 and OneDrive):
  Sandbox → Session Service (proxy) → Workspace Service
```

This is consistent with how browser requests already work (always proxied through Session Service). One routing pattern for all workspace types eliminates conditional logic in the sandbox and registration response. For OneDrive workspaces, Session Service injects the Graph token. For S3 workspaces, it's a simple pass-through. The extra hop is negligible — Session Service proxy is already optimized for this path.

---

## Design Decisions and Rationale

This section documents the key trade-offs evaluated and the reasoning behind each decision. These were considered in the context of the existing cowork architecture (workspace model, sandbox execution, tool runtime) and the goal of minimizing complexity while maintaining production quality.

### D1: One OneDrive Folder Per Workspace

A workspace maps to exactly one OneDrive folder, identified by `driveId` + `folderItemId`. This binding is set at workspace creation and is immutable for the workspace lifetime.

- Mirrors the `local` scope pattern: one `localPath` = one project directory
- Policy enforcement scopes `allowedPaths` per workspace — multiple folders would complicate path validation
- Multiple sessions can reuse the same OneDrive workspace (like `local`, unlike single-use `cloud`)

The workspace record stores `driveId` (not just personal OneDrive) so the same model supports SharePoint document libraries later.

### D2: Eager Download at Startup with Size Caps

All eligible files are downloaded from OneDrive to the sandbox's local disk at startup, before the agent loop begins. No lazy/on-demand fetching.

**Alternatives considered:**

| Approach | Description | Verdict |
|---|---|---|
| **A. Eager download (chosen)** | Download all eligible files at startup, agent works on local disk | Simple, identical to existing S3 cloud workspaces, zero tool changes |
| **B. Lazy fetch (per-tool pre-hook)** | Download metadata at startup, fetch file content on first `ReadFile` call via a `WorkspaceFetcher` hook in `ToolExecutor` | Efficient for large folders where agent touches few files. But breaks when agent reads files via `RunCommand("python script.py")` or `ExecuteCode("open('file.txt')")` — arbitrary code bypasses the pre-hook. This is a fundamental gap that cannot be closed without OS-level interception (FUSE). |
| **C. Network-only access (no local copy)** | Every file read/write goes through Graph API in real-time | Incompatible with the tool runtime architecture. All file tools assume POSIX filesystem semantics. Would require rewriting ReadFile, WriteFile, EditFile, ListDirectory, FindFiles, GrepFiles. Shell.Exec and ExecuteCode become impossible. Performance is 200ms/read (Graph API) vs <1ms (local disk) — unacceptable for an agent loop making 50-200 tool calls per task. |
| **D. User-selected subfolder sync** | User picks which subfolders to sync at workspace creation | Puts burden on user to predict which files the agent needs before the task starts. Breaks analogy with desktop where agent has full project access. Rejected. |

**Decision: Approach A.** The lazy fetch (B) was tempting for efficiency but the shell/code execution gap is a fundamental flaw — the agent can read files through arbitrary code paths that no pre-hook can intercept. Eager download with size caps is simpler, matches existing patterns, and requires zero changes to tool-runtime or tool-executor.

**Size constraints:**

| Constraint | Default | Configurable via |
|---|---|---|
| Per-file size cap | 50 MB | Policy bundle |
| Total workspace sync cap | 1 GB | Policy bundle |
| Auto-excluded patterns | `.git/`, `node_modules/`, `__pycache__/`, `.venv/`, `*.zip`, `*.tar.gz`, etc. | Workspace Service config |

If the OneDrive folder exceeds 1 GB after exclusions, workspace creation fails with a clear error.

### D3: Direct Write-Back at Task Completion

Modified files are pushed back to OneDrive at the same sync points as S3 workspaces:
- After task completion
- Every N steps (configurable, default 10)
- On graceful shutdown (SIGTERM)

**Alternatives considered:**

| Approach | Description | Verdict |
|---|---|---|
| **A. Direct write-back (chosen)** | Push changed files to OneDrive at sync points | Consistent with desktop (agent writes directly to filesystem). Simple. OneDrive version history provides undo. |
| **B. Staging area** | Write to S3 staging location. User reviews diffs in web UI, then explicitly "applies" to OneDrive. | Safer — user reviews before committing. But adds significant complexity: diff review UI, selective apply API, merge logic. No other workspace type has this pattern. The existing approval gates on risky tool calls are already the safety net. |
| **C. Read-only** | Agent can read OneDrive files but not write back. Output goes to S3 only. | Undercuts the core product value — the agent makes changes to the user's project. Limits to analysis-only tasks. |

**Decision: Approach A.** The safety concern is real but already addressed by the existing approval gate mechanism (policy-controlled `File.Write` capability). Adding a staging area would be a significant UX investment (diff review, selective apply) that doesn't exist for any workspace type today. OneDrive's built-in version history (accessible via OneDrive web UI) lets users revert any bad changes.

Write access is policy-controlled — `File.Write` capability with `allowedPaths` scoped to the workspace folder, same as today.

### D4: Last-Write-Wins for Concurrent Edits

If a user or collaborator edits a OneDrive file while the agent is working, the agent's version overwrites at push-back time. No conflict detection.

**Alternatives considered:**

| Approach | Description | Verdict |
|---|---|---|
| **A. Last-write-wins (chosen)** | Agent's version overwrites. No conflict check. | Consistent with desktop `local` workspaces. Simple. OneDrive version history preserves overwritten content. |
| **B. Fail on conflict** | Store OneDrive etags at download time, compare at upload. Refuse to push if etag differs. | Safer but adds complexity: must store etags for every file, compare at upload, handle partial push (some files conflict, some don't). Agent's work is preserved locally but not synced — user must resolve manually. |
| **C. Skip conflicting files** | Push non-conflicting files, report conflicts to user. | Partial sync could leave project in broken state (e.g., updated `main.py` but skipped `config.py` that it depends on). Worse than all-or-nothing. |

**Decision: Approach A.** The realistic scenario: the user launches an agent task and waits for it. Concurrent editing of the same files during a task is uncommon. Adding conflict detection is straightforward (store etags at download, compare at upload) and can be added later without architectural changes. For now, parity with desktop behavior keeps the implementation simple.

### D5: Desktop Needs No OneDrive-Specific Code

On desktop, OneDrive is a mapped drive. Users already point `local` workspaces at OneDrive-synced folders. The agent reads/writes local files; the OneDrive client syncs in the background.

This feature is **web/sandbox only**. No changes to the desktop app or stdio transport.

### D6: Delegated Access with Session Service as Token Custodian

Authentication uses the OAuth 2.0 On-Behalf-Of (OBO) flow.

**Alternatives considered for auth model:**

| Approach | Description | Verdict |
|---|---|---|
| **A. Delegated access / OBO (chosen)** | Cowork acts on behalf of the user. User consents individually. Only accesses files the user can access. | Standard pattern for apps accessing user files. No admin consent required. Respects per-user permissions. |
| **B. App-only access** | Cowork registers with `Files.ReadWrite.All` application permission. Admin consents once. | Gives Cowork access to ALL users' files in the tenant — significant security concern. Doesn't respect per-user sharing/permissions correctly. |

**Alternatives considered for token custodian:**

| Component | Pros | Cons |
|---|---|---|
| **Browser** | Already has OIDC library. Simple — just refresh and send new token per request. | Browser might close, tab might sleep, mobile browser kills background tabs. Sandbox can't sync files back at task completion if browser is gone. |
| **Workspace Service** | Closest to where token is used. Refresh right before Graph API call. | Stateless by design — doesn't store anything between requests. Would need token persistence, violating its architectural role. |
| **Session Service (chosen)** | Already manages session lifecycle. Already stores per-session state in DynamoDB. Already proxies every request to Workspace Service. Self-sufficient even if browser closes. | Adds OIDC client logic (token refresh) — modest complexity increase. |

**Decision:** Session Service is the token custodian. It already owns session lifecycle and state. The critical requirement is that the backend must be self-sufficient after session creation — the browser may close, but the sandbox must still be able to push files back to OneDrive at task completion. Only server-side token refresh guarantees this.

**Flow:**

1. User authenticates via EntraID SSO in the web app
2. Web app obtains access token + refresh token with `Files.ReadWrite` scope
3. Tokens are passed to Session Service at session creation
4. Session Service stores tokens (encrypted) on the session record in DynamoDB
5. On each proxied request to Workspace Service, Session Service checks token expiry
6. If expired: Session Service refreshes via EntraID token endpoint, updates DynamoDB
7. Workspace Service receives a fresh access token via `X-Graph-Access-Token` request header
8. Workspace Service is stateless — no token storage, no refresh logic

**Token expiry:**
- Access token: ~1 hour (auto-refreshed by Session Service)
- Refresh token: ~90 days (configurable by tenant admin). If it expires mid-session, return error asking user to re-authenticate.

### D7: OneDrive Adapter in Workspace Service

**Alternatives considered for where the adapter lives:**

| Option | Description | Verdict |
|---|---|---|
| **A. Workspace Service (chosen)** | New `FileStore` implementation alongside existing S3 code | Natural fit — Workspace Service already owns file CRUD. Agent runtime unchanged. Single abstraction boundary. |
| **B. Session Service (proxy layer)** | Session Service translates OneDrive files to S3 format before forwarding to Workspace Service | Adds file transformation logic to what should be a thin proxy. Session Service becomes a data plane, not just control plane. |
| **C. New OneDrive Connector Service** | Dedicated microservice for Graph API interactions | Over-engineering for a single storage backend. Adds network hop, deployment complexity, and a new service to operate. Justified only if we need to support many storage backends with complex logic. |

**Decision: Approach A.** Workspace Service is the file storage abstraction layer. Adding a new backend is its natural extension point. The key architectural insight is that artifacts (session_history, tool_output, file_diff) and workspace project files are separate concerns — artifacts always stay in S3 (Cowork's internal data), only user project files use OneDrive.

The Workspace Service gets a new `FileStore` implementation. Artifacts (session_history, tool_output, file_diff) always stay in S3 — only user project files use OneDrive.

```python
class FileStore(Protocol):
    """Backend for workspace project files."""
    async def list_files(self, prefix: str) -> list[FileEntry]: ...
    async def download_file(self, path: str) -> bytes: ...
    async def upload_file(self, path: str, content: bytes, content_type: str) -> None: ...
    async def delete_file(self, path: str) -> None: ...

class S3FileStore(FileStore):
    """Existing implementation — extracted from current code."""
    ...

class OneDriveFileStore(FileStore):
    """New implementation — calls Microsoft Graph API."""
    def __init__(self, access_token: str, drive_id: str, folder_item_id: str): ...
    ...
```

Dependency injection per-request based on workspace type:
```python
if workspace.workspace_scope == "onedrive":
    file_store = OneDriveFileStore(
        access_token=request.headers["X-Graph-Access-Token"],
        drive_id=workspace.drive_id,
        folder_item_id=workspace.folder_item_id,
    )
else:
    file_store = S3FileStore(s3_client, bucket)
```

---

## Workspace Scope: `onedrive`

New workspace scope alongside `local`, `general`, and `cloud`.

### Workspace Record (extended fields)

| Field | Type | Description |
|---|---|---|
| `workspaceScope` | `"onedrive"` | New scope value |
| `driveId` | `string` | OneDrive or SharePoint drive ID |
| `folderItemId` | `string` | Graph API item ID of the root folder |
| `folderPath` | `string` | Display path (e.g., `/Projects/myapp`) for UI |

### Workspace Reuse (User-Controlled)

No automatic idempotent resolution for OneDrive workspaces. Instead, the web app lists the user's existing workspaces (via `GET /workspaces?tenantId=X&userId=Y`, using the existing `tenantId-userId-index` GSI) and lets the user choose:

- **"Continue existing workspace"** — reuse a prior workspace for the same OneDrive folder (sees past sessions)
- **"Start fresh"** — create a new workspace regardless

This avoids a new GSI and gives the user control over whether to group sessions or keep them separate. The existing `tenantId-userId-index` GSI already supports listing a user's workspaces.

### Lifecycle

| Aspect | Behavior |
|---|---|
| Creation | User creates via web app when starting a session with a OneDrive folder. |
| Reuse | User-controlled — web app lists existing workspaces and offers "continue" or "start fresh." |
| Deletion | User-initiated. Deletes workspace record + all artifacts in S3. Does NOT delete OneDrive files. |
| TTL | No auto-expiry (user's ongoing project). |

---

## API Changes

### Session Service

**`POST /sessions` — extended request:**

```json
{
  "tenantId": "tenant_abc",
  "userId": "user_123",
  "executionEnvironment": "cloud_sandbox",
  "workspaceHint": {
    "oneDrive": {
      "driveId": "b!abc123...",
      "folderItemId": "01ABC...",
      "folderPath": "/Projects/myapp",
      "accessToken": "eyJ...",
      "refreshToken": "0.ARw..."
    }
  }
}
```

When `workspaceHint.oneDrive` is present:
1. Session Service resolves or creates an `onedrive`-scoped workspace via Workspace Service
2. Stores `accessToken` + `refreshToken` (encrypted) on the session record
3. Proceeds with sandbox provisioning as normal

**Token refresh endpoint (internal):**

Session Service uses an `OneDriveTokenManager` that:
- Checks `expiresAt` before each proxied request to Workspace Service
- If expired: calls EntraID `POST /oauth2/v2.0/token` with `grant_type=refresh_token`
- Updates session record with new tokens
- Attaches fresh `accessToken` as `X-Graph-Access-Token` header

### Workspace Service

**`POST /workspaces` — extended request:**

```json
{
  "tenantId": "tenant_abc",
  "userId": "user_123",
  "workspaceScope": "onedrive",
  "driveId": "b!abc123...",
  "folderItemId": "01ABC...",
  "folderPath": "/Projects/myapp"
}
```

**File endpoints — no API changes.** Existing endpoints work for all workspace scopes:

| Endpoint | S3 behavior | OneDrive behavior |
|---|---|---|
| `GET /workspaces/{id}/files` | List S3 objects under prefix | List children via Graph API |
| `GET /workspaces/{id}/files/{path}` | S3 GetObject | Graph API download |
| `POST /workspaces/{id}/files?path=X` | S3 PutObject | Graph API upload |
| `DELETE /workspaces/{id}/files/{path}` | S3 DeleteObject | Graph API delete |

The `X-Graph-Access-Token` header is required for `onedrive`-scoped workspaces. Workspace Service returns 401 if missing or invalid.

### Platform Contracts

**`workspace.json` schema — extended:**

```json
{
  "workspaceScope": {
    "enum": ["local", "general", "cloud", "onedrive"]
  },
  "driveId": { "type": "string" },
  "folderItemId": { "type": "string" },
  "folderPath": { "type": "string" }
}
```

**New error codes:**

| Code | HTTP | Meaning |
|---|---|---|
| `ONEDRIVE_UNAUTHORIZED` | 401 | Token invalid or expired (refresh also failed) |
| `ONEDRIVE_FORBIDDEN` | 403 | User lacks access to the specified drive/folder |
| `ONEDRIVE_NOT_FOUND` | 404 | Drive or folder no longer exists |
| `ONEDRIVE_QUOTA_EXCEEDED` | 507 | User's OneDrive storage is full |
| `ONEDRIVE_RATE_LIMITED` | 429 | Microsoft Graph API throttling |
| `WORKSPACE_TOO_LARGE` | 413 | Folder exceeds 1 GB sync cap after exclusions |

---

## Microsoft Graph API Usage

### Key Endpoints

| Operation | Graph API Call |
|---|---|
| List folder contents (recursive) | `GET /drives/{driveId}/items/{folderItemId}/children` (paginated, recursive via expansion or per-folder traversal) |
| Download file | `GET /drives/{driveId}/items/{itemId}/content` (302 redirect to download URL) |
| Upload small file (<4MB) | `PUT /drives/{driveId}/items/{folderId}:/{path}:/content` |
| Upload large file (>4MB) | Create upload session: `POST /drives/{driveId}/items/{folderId}:/{path}:/createUploadSession`, then upload chunks |
| Delete file | `DELETE /drives/{driveId}/items/{itemId}` |
| Get folder metadata | `GET /drives/{driveId}/items/{folderItemId}?$select=id,name,size,folder` |

### Rate Limits and Throttle Handling

Microsoft Graph enforces rate limits at multiple levels:
- **Per app per tenant**: ~2000 requests / 10 seconds
- **Per user**: ~10,000 requests / 10 minutes
- **SharePoint/OneDrive specific**: Additional limits on file operations (not publicly documented, varies by tenant size)

When throttled, Graph API returns `429 Too Many Requests` with a `Retry-After` header (value in seconds, typically 1–120s).

**Request budget for typical workspaces:**

| Workspace size | List requests | Download requests | Total | Fits in budget? |
|---|---|---|---|---|
| 100 files, 20 MB | ~1 | 100 | ~101 | Yes — well under limit |
| 500 files, 200 MB | ~5 | 500 | ~505 | Yes — single burst |
| 1000 files, 800 MB | ~10 | 1000 | ~1010 | Borderline — needs pacing |
| 2000 files, 1 GB | ~20 | 2000 | ~2020 | Hits limit — needs throttle handling |

**Throttle handling strategy — adaptive concurrency with backoff:**

The `OneDriveFileStore` implements a `ThrottleAwareClient` wrapper around httpx that manages concurrency and respects throttle signals:

```python
class ThrottleAwareClient:
    """HTTP client that adapts concurrency based on Graph API throttle signals."""

    def __init__(
        self,
        client: httpx.AsyncClient,
        initial_concurrency: int = 10,
        min_concurrency: int = 2,
        max_concurrency: int = 20,
    ):
        self._client = client
        self._semaphore = asyncio.Semaphore(initial_concurrency)
        self._concurrency = initial_concurrency
        self._min_concurrency = min_concurrency
        self._max_concurrency = max_concurrency
        self._throttle_until: float = 0  # monotonic time
        self._consecutive_successes: int = 0

    async def request(self, method: str, url: str, **kwargs) -> httpx.Response:
        """Make a request with adaptive concurrency and throttle backoff."""
        async with self._semaphore:
            # Wait if we're in a throttle backoff period
            now = asyncio.get_event_loop().time()
            if self._throttle_until > now:
                await asyncio.sleep(self._throttle_until - now)

            for attempt in range(4):  # max 3 retries
                resp = await self._client.request(method, url, **kwargs)

                if resp.status_code == 429:
                    retry_after = int(resp.headers.get("Retry-After", "5"))
                    self._handle_throttle(retry_after)
                    await asyncio.sleep(retry_after)
                    continue

                if resp.status_code >= 500:
                    # Server error — backoff and retry
                    await asyncio.sleep(2 ** attempt * 0.5)
                    continue

                # Success — consider ramping concurrency back up
                self._on_success()
                return resp

            return resp  # Return last response after retries exhausted

    def _handle_throttle(self, retry_after: int):
        """Reduce concurrency and set backoff window."""
        self._consecutive_successes = 0
        new_concurrency = max(self._min_concurrency, self._concurrency // 2)
        if new_concurrency != self._concurrency:
            self._concurrency = new_concurrency
            self._semaphore = asyncio.Semaphore(new_concurrency)
            log.warning("graph_api_throttled", concurrency=new_concurrency,
                        retry_after=retry_after)
        self._throttle_until = asyncio.get_event_loop().time() + retry_after

    def _on_success(self):
        """Gradually ramp concurrency back up after sustained success."""
        self._consecutive_successes += 1
        if self._consecutive_successes >= 50 and self._concurrency < self._max_concurrency:
            self._concurrency = min(self._max_concurrency, self._concurrency + 2)
            self._semaphore = asyncio.Semaphore(self._concurrency)
            self._consecutive_successes = 0
            log.info("graph_api_concurrency_increased", concurrency=self._concurrency)
```

**Behavior:**
1. **Start at concurrency 10** — safe default for most workspaces
2. **On 429**: halve concurrency (minimum 2), wait `Retry-After` seconds, then resume
3. **On sustained success** (50 consecutive): increase concurrency by 2 (max 20)
4. **All in-flight requests** share the backoff window — when one request gets 429, all pending requests wait before their next attempt
5. **On 5xx**: retry with exponential backoff (0.5s, 1s, 2s), no concurrency change

**Impact on startup time:**

| Scenario | Concurrency | 500 files @ 200KB avg | Notes |
|---|---|---|---|
| No throttling | 10 | ~15 seconds | 500 requests, ~50 batches, ~300ms per request |
| Mild throttle (one 429) | 5 | ~25 seconds | Halved concurrency + 5s pause |
| Heavy throttle (multiple 429s) | 2 | ~90 seconds | Still completes, just slower |

This is acceptable — sandbox provisioning already takes 30-60s for ECS cold start. The download runs concurrently with provisioning where possible.

**Circuit breaker:** If more than 5 consecutive requests fail (429 or 5xx) after all retries, `OneDriveFileStore` raises `OneDriveUnavailableError`. The sandbox startup fails, session moves to `SESSION_FAILED`, and the user sees a clear error: "OneDrive is temporarily unavailable. Please try again."

### Path Handling

OneDrive uses `/`-separated paths, case-preserving but case-insensitive. The `OneDriveFileStore` must:
- Normalize paths to forward slashes
- Reject `..` components (same traversal prevention as S3)
- Use item IDs internally where possible (paths can change if files are renamed externally)
- Map between relative paths (as seen by agent) and Graph API item paths

---

## Data Flow: Complete Session Lifecycle

```
1. USER SELECTS ONEDRIVE FOLDER
   Web App → OneDrive folder picker (Graph API file picker component)
   User selects: driveId=X, folderItemId=Y, folderPath="/Projects/myapp"

2. SESSION CREATION
   Web App → POST /sessions { workspaceHint: { oneDrive: {..., tokens} } }
   Session Service:
     → Create/resolve workspace (Workspace Service)
     → Store encrypted tokens on session record
     → Launch ECS sandbox task
     → Return sessionId, status=SANDBOX_PROVISIONING

3. SIZE CHECK (during workspace creation)
   Workspace Service:
     → List OneDrive folder recursively (metadata only)
     → Apply exclusion rules (.git, node_modules, etc.)
     → Apply per-file cap (50MB) and total cap (1GB)
     → If over cap → reject workspace creation with WORKSPACE_TOO_LARGE
     → Store total eligible size on workspace record

4. SANDBOX STARTUP
   Sandbox container:
     → Self-registers with Session Service
     → Receives workspaceId, policyBundle, workspace_service_url
       (always points to Session Service proxy — same for all workspace types)
     → Calls download_workspace():
         → GET {workspace_service_url}/workspaces/{id}/files (list all files)
         → GET {workspace_service_url}/workspaces/{id}/files/{path} for each file (parallel, max 10)
         → Session Service proxy forwards to Workspace Service
           (for OneDrive: injects X-Graph-Access-Token header)
         → Workspace Service routes to OneDriveFileStore → Graph API
         → Files written to sandbox local disk
     → Agent loop starts

5. TASK EXECUTION
   Agent works on local files. No OneDrive awareness.
   ReadFile, WriteFile, GrepFiles, RunCommand — all local filesystem.

6. PERIODIC SYNC (every N steps)
   Agent host → upload_workspace():
     → POST /workspaces/{id}/files?path=X for each changed file
     → Workspace Service routes to OneDriveFileStore
     → OneDriveFileStore uploads to OneDrive via Graph API

7. TASK COMPLETION
   Agent host → upload_workspace() (final push of all changed files)
   Session Service → update session status

8. SESSION END / SANDBOX TERMINATION
   Graceful: upload_workspace() on SIGTERM → sandbox terminated
   Forced: sandbox killed → changes since last sync are lost (same as S3 cloud workspaces)
```

---

## DynamoDB Changes

### Workspaces Table

New fields on workspace items with `workspaceScope = "onedrive"`:

| Field | Type | Description |
|---|---|---|
| `driveId` | `S` | OneDrive/SharePoint drive ID |
| `folderItemId` | `S` | Graph API item ID of root folder |
| `folderPath` | `S` | Display path for UI |
| `totalSyncSizeBytes` | `N` | Eligible size at last check (for display) |

No new GSI required. Workspace listing uses the existing `tenantId-userId-index` GSI. The web app filters by `driveId + folderItemId` client-side to offer workspace reuse.

### Sessions Table

New fields on session items with OneDrive workspaces:

| Field | Type | Description |
|---|---|---|
| `oneDriveAccessToken` | `S` | Encrypted access token |
| `oneDriveRefreshToken` | `S` | Encrypted refresh token |
| `oneDriveTokenExpiresAt` | `S` | ISO 8601 expiry timestamp |

Encryption: AES-256-GCM using a key from AWS Secrets Manager. Token fields are never returned in API responses.

---

## Component Changes Summary

| Component | Changes | Scope |
|---|---|---|
| **cowork-platform** | Add `"onedrive"` to `workspaceScope` enum. Add `driveId`, `folderItemId`, `folderPath` to workspace schema. Add OneDrive error codes. | Schema + codegen |
| **cowork-workspace-service** | Extract `FileStore` protocol from existing S3 code. Add `OneDriveFileStore` implementation. Size check on workspace creation. | New file store |
| **cowork-session-service** | Accept `workspaceHint.oneDrive` in CreateSession. Store/refresh OneDrive tokens. Attach `X-Graph-Access-Token` header on proxied requests. | Token management + proxy |
| **cowork-web-app** | OneDrive folder picker UI. Pass tokens in CreateSession. | New UI component |
| **cowork-agent-runtime** | **No changes.** | — |
| **cowork-desktop-app** | **No changes.** | — |
| **cowork-policy-service** | Add `WORKSPACE_TOO_LARGE` to known error codes. Add sync size caps to policy bundle schema. | Config |
| **cowork-infra** | IAM/secrets for token encryption key. | Terraform |

---

## Security Considerations

### Token Storage
- OneDrive tokens stored encrypted at rest in DynamoDB (AES-256-GCM)
- Encryption key in AWS Secrets Manager, rotated per environment
- Tokens never logged, never returned in API responses
- Tokens deleted when session is cleaned up (TTL or explicit delete)

### Access Scope
- Delegated access only — Cowork acts as the user, never has broader access
- `Files.ReadWrite` scope limited to files the user can already access
- No admin consent required — individual user consent sufficient

### Path Traversal
- Same prevention as S3: reject `..`, null bytes, absolute paths after normalization
- OneDrive item IDs used internally (not paths) where possible
- All paths validated at Workspace Service before Graph API calls

### Rate Limiting
- Respect Microsoft Graph 429 responses with `Retry-After` header
- Bounded concurrency (semaphore=10) on parallel downloads/uploads
- Circuit breaker on sustained Graph API failures

---

## Testing Strategy

### Unit Tests (InMemory)
- `OneDriveFileStore` with mocked Graph API responses (httpx mock)
- Token refresh logic in Session Service (mock EntraID endpoint)
- Workspace creation with OneDrive hint
- Size cap enforcement (folder over/under limit)
- Path validation for OneDrive paths

### Service Tests (DynamoDB Local)
- Workspace CRUD with `onedrive` scope
- Session record with encrypted token fields
- Token refresh + DynamoDB update

### Integration Tests (LocalStack + Mock Graph API)
- Full session lifecycle: create → download → agent task → upload → terminate
- Token expiry → auto-refresh → continued operation
- Folder exceeds size cap → workspace creation rejected
- Graph API errors (401, 403, 404, 429, 500) → correct error codes propagated

---

## Future Considerations

- **Conflict detection**: Store OneDrive etags at download time, compare at upload. Report conflicts instead of overwriting.
- **Incremental sync**: Use OneDrive delta API (`/drives/{id}/items/{id}/delta`) for faster subsequent syncs on workspace reuse.
- **Google Drive**: Same `FileStore` pattern — add `GoogleDriveFileStore` with equivalent Google Drive API calls.
- **Dropbox**: Same pattern — `DropboxFileStore`.
- **Lazy fetch**: If size caps prove too restrictive, add on-demand file fetching with a `WorkspaceFetcher` pre-hook in `ToolExecutor`. Requires handling the shell/code execution gap (files read via `RunCommand` won't trigger pre-fetch).
- **Folder picker caching**: Cache OneDrive folder tree in browser for faster repeat selections.
- **Shared workspaces**: Multiple users accessing the same OneDrive/SharePoint folder in separate sessions. Current model supports this (workspace scoped to individual user).

---

## Implementation Plan

### Step 1: Platform Contracts

**Repo:** `cowork-platform`

**Work:**
- Add `"onedrive"` to `workspaceScope` enum in `contracts/schemas/workspace.json`
- Add optional fields: `driveId`, `folderItemId`, `folderPath` to workspace schema
- Add `WorkspaceCreateRequest` variant for OneDrive (with `oneDrive` hint)
- Add OneDrive error codes to shared error schema
- Add sync size cap fields to policy bundle schema (`maxWorkspaceSyncBytes`, `maxFileSyncBytes`)
- Run codegen: regenerate Python (Pydantic) and TypeScript bindings
- Update CLAUDE.md with new schema fields

**Tests:**
- Schema validation: `onedrive` scope requires `driveId` + `folderItemId`
- Schema validation: `local` scope does not require OneDrive fields
- Generated bindings compile cleanly

**Definition of Done:**
- `make check` passes
- New schema fields present in both Python and TypeScript generated code
- No breaking changes to existing schemas (additive only)

### Step 2: Workspace Service — FileStore Protocol + OneDriveFileStore

**Repo:** `cowork-workspace-service`

**Work:**
- Extract `FileStore` protocol from existing S3 file operations in `WorkspaceFileService`
- Create `S3FileStore` implementing `FileStore` (refactor, not new logic)
- Create `OneDriveFileStore` implementing `FileStore`:
  - `list_files()`: recursive folder listing via Graph API with pagination
  - `download_file()`: Graph API content download (handle 302 redirect)
  - `upload_file()`: simple upload (<4MB) and upload session (>4MB)
  - `delete_file()`: Graph API delete
- Add exclusion filtering in `list_files()`: skip `.git/`, `node_modules/`, etc.
- Add per-file size filtering: skip files > `maxFileSyncBytes`
- Add total size calculation and cap enforcement
- Dependency injection: select `FileStore` implementation based on workspace scope
- Read `X-Graph-Access-Token` header for OneDrive-scoped requests
- Return 401 `ONEDRIVE_UNAUTHORIZED` if header missing or Graph API rejects token

**Tests:**
- Unit: `OneDriveFileStore` with mocked httpx responses (list, download, upload, delete)
- Unit: exclusion filtering (skips `.git`, large files, etc.)
- Unit: size cap enforcement (total > 1GB rejected)
- Service: DynamoDB CRUD for `onedrive` workspace scope

**Definition of Done:**
- `make check` passes
- Existing S3 tests still pass (refactor doesn't break anything)
- `OneDriveFileStore` has full unit test coverage
- File endpoints work for both `cloud` (S3) and `onedrive` scopes

### Step 3: Session Service — Token Management + Proxy

**Repo:** `cowork-session-service`

**Work:**
- Accept `workspaceHint.oneDrive` in `POST /sessions`
- Store encrypted `accessToken`, `refreshToken`, `tokenExpiresAt` on session record
- Implement `OneDriveTokenManager`:
  - `get_valid_token(session_id)`: check expiry, refresh if needed, return access token
  - `refresh_token(session)`: call EntraID `POST /oauth2/v2.0/token`, update session record
  - Token encryption/decryption using AWS Secrets Manager key
- Update proxy layer: attach `X-Graph-Access-Token` header on requests to Workspace Service for OneDrive sessions
- Pass `workspaceScope: "onedrive"` + OneDrive fields to Workspace Service on workspace creation
- Handle `ONEDRIVE_UNAUTHORIZED` from Workspace Service: attempt refresh, retry once, then propagate

**Tests:**
- Unit: token encryption round-trip
- Unit: token refresh logic (mock EntraID endpoint)
- Unit: proxy attaches `X-Graph-Access-Token` header for OneDrive sessions
- Unit: token expiry detection + auto-refresh
- Service: session record with token fields stored/retrieved correctly
- Integration: CreateSession with OneDrive hint → workspace created → token stored

**Definition of Done:**
- `make check` passes
- Token fields never appear in API responses or logs
- Existing session tests still pass
- Token refresh works for expired access tokens
- Graceful error when refresh token is also expired

### Step 4: Infrastructure

**Repo:** `cowork-infra`

**Work:**
- Add Secrets Manager secret for OneDrive token encryption key (per environment)
- Add environment variables to Session Service task definition: `ONEDRIVE_TOKEN_ENCRYPTION_KEY_ARN`
- Add environment variables to Workspace Service task definition: (none — stateless, token comes via header)
- Update ALB health check if needed

**Tests:**
- `terraform plan` shows expected changes

**Definition of Done:**
- `make plan-dev` shows clean diff
- No changes to existing resources beyond Secrets Manager addition

### Step 5: Web App — OneDrive Folder Picker

**Repo:** `cowork-web-app`

**Work:**
- Integrate Microsoft Graph Toolkit file picker or build custom folder browser
- OneDrive OAuth consent flow (request `Files.ReadWrite` scope)
- New workspace creation flow: user selects "OneDrive" source → picks folder → creates session
- Display folder path + estimated size before confirmation
- Handle `WORKSPACE_TOO_LARGE` error with user-friendly message
- Pass `workspaceHint.oneDrive` in CreateSession request

**Tests:**
- Component tests for folder picker UI
- Integration test: folder selection → session creation → sandbox provisioning

**Definition of Done:**
- User can select a OneDrive folder and launch a web session
- Size cap error is displayed clearly
- Existing upload flow (manual file upload) still works unchanged

---

## Status Tracker

| Step | Name | Repo | Status | Branch | Notes |
|------|------|------|--------|--------|-------|
| 1 | Platform Contracts | cowork-platform | Not started | | |
| 2 | Workspace Service — FileStore + OneDrive | cowork-workspace-service | Not started | | |
| 3 | Session Service — Token Management | cowork-session-service | Not started | | |
| 4 | Infrastructure | cowork-infra | Not started | | |
| 5 | Web App — Folder Picker | cowork-web-app | Not started | | |
