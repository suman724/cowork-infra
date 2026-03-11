# Workspace File Sync — Design Doc

**Status:** Proposed
**Scope:** Session Service, Agent Runtime, Workspace Service, Web App
**Date:** 2026-03-11

---

## Problem

The current proxy upload endpoint (`POST /sessions/{id}/upload`) forwards files directly to the sandbox container, bypassing Workspace Service and S3. This creates three problems:

1. **No persistence** — files exist only in the sandbox container's ephemeral filesystem. If the sandbox terminates (idle timeout, crash, max duration), files are lost.
2. **Timing dependency** — uploads can't happen until the sandbox is `SANDBOX_READY`, adding latency.
3. **Two write paths** — the proxy upload writes to sandbox only, while Workspace Service writes to S3 only. Users must choose the right one depending on sandbox state.

---

## Design: Unified Upload via Session Service

All file uploads go through a single endpoint: `POST /sessions/{id}/upload`. Session Service orchestrates persistence (Workspace Service / S3) and sandbox notification (RPC sync) internally. The frontend makes one call regardless of sandbox state.

### Upload Flow

```
Web App
  │
  │  POST /sessions/{id}/upload
  │  (multipart: file + path)
  │
  ▼
Session Service
  │
  ├─ 1. Forward file to Workspace Service
  │     POST /workspaces/{workspaceId}/files?path=X
  │     (always — persists to S3)
  │
  ├─ 2. Is sandbox READY/RUNNING?
  │     ├─ YES → Send RPC to sandbox: workspace.sync
  │     │        POST {sandboxEndpoint}/rpc
  │     │        {"jsonrpc":"2.0","method":"workspace.sync","params":{"paths":["X"]}}
  │     │        (sandbox pulls file from S3)
  │     │
  │     └─ NO → Done. Sandbox will download on startup.
  │
  └─ 3. Return success to Web App
```

### Key Properties

- **One endpoint, one behavior.** Frontend never checks sandbox state.
- **S3 is always the source of truth.** Every uploaded file is persisted before the sandbox sees it.
- **Sandbox sync is best-effort.** If the RPC fails (sandbox restarting, network blip), the file is still in S3 and will be picked up on next sync or restart.
- **Pre-sandbox uploads work.** During `SANDBOX_PROVISIONING`, files land in S3. The startup `download_workspace()` pulls them all.

---

## Download Flow (unchanged)

File downloads continue to go through the sandbox proxy:

```
Web App
  │
  │  GET /sessions/{id}/files/{path}
  │
  ▼
Session Service (proxy)
  │
  ▼
Sandbox Container (reads from local filesystem)
```

**Rationale:** The sandbox filesystem is the live working copy. The agent may have modified files that haven't been synced back to S3 yet. Downloading from S3 would return stale data.

---

## Workspace Sync RPC

New JSON-RPC method on the sandbox's HTTP transport.

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "workspace.sync",
  "params": {
    "direction": "pull",
    "paths": ["src/main.py", "data/config.json"]
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `direction` | `"pull"` or `"push"` | `pull` = download from S3 to sandbox. `push` = upload from sandbox to S3. |
| `paths` | `string[]` (optional) | Specific files to sync. If omitted, sync all files. |

### Response

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "synced": ["src/main.py", "data/config.json"],
    "failed": [],
    "direction": "pull"
  }
}
```

### Implementation (Agent Runtime)

Add a `workspace.sync` handler to `HttpTransport`'s `MethodDispatcher`:

```python
async def _handle_workspace_sync(self, params: dict) -> dict:
    direction = params.get("direction", "pull")
    paths = params.get("paths")  # None = sync all

    if direction == "pull":
        if paths:
            # Download specific files from Workspace Service
            await download_files(self._ws_url, self._ws_id, self._workspace_dir, paths)
        else:
            # Full sync — same as startup
            await download_workspace(self._ws_url, self._ws_id, str(self._workspace_dir))
        return {"synced": paths or [], "direction": "pull"}

    elif direction == "push":
        if paths:
            await upload_files(self._ws_url, self._ws_id, self._workspace_dir, paths)
        else:
            await upload_workspace(self._ws_url, self._ws_id, str(self._workspace_dir))
        return {"synced": paths or [], "direction": "push"}
```

This reuses existing `download_workspace()` and `upload_workspace()` from `workspace_sync.py`, plus new `download_files()` and `upload_files()` for targeted sync.

---

## Edge Cases

### 1. Upload during `SANDBOX_PROVISIONING`

**Scenario:** User uploads files before sandbox is ready.
**Behavior:** File goes to S3 only. No RPC. Sandbox downloads it during startup `download_workspace()`.
**No issue.**

### 2. Upload during sandbox startup (race)

**Scenario:** Sandbox transitions to `SANDBOX_READY` but is still running `download_workspace()` when the RPC arrives.
**Behavior:** The `workspace.sync` RPC handler must wait for startup sync to complete before executing. Use an `asyncio.Event` flag (`_startup_sync_complete`) set after `download_workspace()` finishes. The RPC handler awaits this event (with timeout) before proceeding.
**Mitigation:** If timeout expires, return an error. Session Service treats this as best-effort — file is still in S3.

### 3. File conflict — user uploads while agent is editing the same file

**Scenario:** Agent is modifying `main.py` in the sandbox. User uploads a new `main.py` via the web app.
**Behavior:** The `workspace.sync` pull overwrites the sandbox's local copy.
**Mitigation:** The `workspace.sync` handler should check if the target file has been modified locally since last sync. If so, return a conflict status for that file and skip it:

```json
{
  "synced": [],
  "failed": [],
  "conflicts": [{"path": "main.py", "reason": "locally_modified"}],
  "direction": "pull"
}
```

Session Service returns a `207 Multi-Status` or includes conflict info in the response so the web app can inform the user.

**Phase 1 simplification:** Skip conflict detection. Overwrite unconditionally. The agent will re-read the file on next tool call. Conflict detection can be added in Phase 2 if needed.

### 4. Large file upload

**Scenario:** User uploads a file exceeding `max_artifact_size_bytes` (Workspace Service config).
**Behavior:** Workspace Service rejects with `413 Payload Too Large`. Session Service propagates the error to the web app.
**No special handling needed** — Workspace Service already enforces this.

### 5. Sandbox terminated after upload starts

**Scenario:** Sandbox is terminated (idle timeout, max duration) between the S3 write and the RPC sync.
**Behavior:** S3 write succeeds. RPC fails (sandbox gone). Session Service returns success — the file is persisted. If the session is resumed later, the new sandbox picks it up via `download_workspace()`.
**No data loss.**

### 6. Multiple rapid uploads

**Scenario:** User uploads 10 files in quick succession.
**Behavior:** Each upload is a separate `POST /sessions/{id}/upload` call. Each triggers a Workspace Service write + RPC sync.
**Optimization (future):** Batch uploads into a single request with multiple files. Session Service makes one Workspace Service call per file but batches the RPC sync (one `workspace.sync` with all paths). Not needed for Phase 1.

### 7. Upload to non-existent session or wrong owner

**Scenario:** Upload with invalid session ID or different user.
**Behavior:** Session Service validates session existence and ownership (same as other proxy endpoints). Returns `404` or `403`.
**Existing behavior, unchanged.**

### 8. Sandbox sync on session resume

**Scenario:** Session was completed, sandbox terminated, user resumes session.
**Behavior:** New sandbox starts → `download_workspace()` pulls all files from S3 (including any uploaded during the previous session). This already works.
**No change needed.**

### 9. Concurrent pull and push

**Scenario:** Agent triggers `workspace.sync push` (e.g., on task completion) at the same time Session Service triggers `workspace.sync pull` for a user upload.
**Mitigation:** The `workspace.sync` handler must serialize sync operations. Use an `asyncio.Lock` in the handler — only one sync at a time. If a pull is in progress, the push waits (or vice versa).

### 10. Network partition — S3 write succeeds, RPC times out

**Scenario:** File persisted in S3 but sandbox doesn't get the sync signal.
**Behavior:** Return success to the web app (file is safe). The sandbox filesystem is stale for that file until:
  - Next `workspace.sync` call (from another upload), or
  - Sandbox restart (full `download_workspace()`)
**Acceptable for Phase 1.** If this becomes a UX issue, the web app can show "file uploaded but not yet synced to sandbox" status.

---

## API Changes

### Session Service

**Modified:** `POST /sessions/{sessionId}/upload`

Current behavior: Forward multipart to `{sandboxEndpoint}/upload`
New behavior: Write to Workspace Service, then optionally RPC sync to sandbox.

**Request:** Same — multipart form with `file` field and `path` query parameter.

**Response:**
```json
{
  "path": "src/main.py",
  "size": 1234,
  "persisted": true,
  "sandboxSynced": true
}
```

| Field | Type | Description |
|-------|------|-------------|
| `path` | string | Relative file path |
| `size` | int | File size in bytes |
| `persisted` | bool | Always `true` (S3 write succeeded) |
| `sandboxSynced` | bool | `true` if sandbox was running and sync succeeded. `false` if sandbox not ready or sync failed (file will sync on startup). |

**Status codes:**
- `200` — File persisted (and possibly synced)
- `400` — Invalid path (traversal attempt)
- `403` — Not session owner
- `404` — Session not found
- `409` — Session is in a terminal state (`SESSION_CANCELLED`, `SANDBOX_TERMINATED`)
- `413` — File too large

**Note:** Upload is allowed in states that are NOT currently "proxyable" — specifically `SANDBOX_PROVISIONING` and `SANDBOX_READY`. The endpoint only requires the session to be non-terminal. This is a difference from other proxy endpoints which require an active sandbox.

### Agent Runtime

**New RPC method:** `workspace.sync` (described above)

**New functions in `workspace_sync.py`:**
- `download_files(ws_url, ws_id, target_dir, paths)` — download specific files
- `upload_files(ws_url, ws_id, source_dir, paths)` — upload specific files

---

## Removing Direct Sandbox Upload

The sandbox's `POST /upload` endpoint in `HttpTransport` becomes internal-only (used by `workspace.sync` pull which writes to the local filesystem directly). No external traffic should hit it.

**Phase 1:** Keep the endpoint but don't expose it through the Session Service proxy. The proxy_upload route in Session Service changes its implementation.
**Phase 2:** Remove `POST /upload` from `HttpTransport` if no other use case emerges.

---

## Status Tracker

| Step | Name | Repo | Status | Branch | Notes |
|------|------|------|--------|--------|-------|
| 1 | workspace.sync RPC | `cowork-agent-runtime` | ⏳ Pending | `feature/workspace-file-sync` | New RPC method, targeted sync functions, startup gate, sync lock |
| 2 | Unified Upload Endpoint | `cowork-session-service` | ⏳ Pending | `feature/workspace-file-sync` | Two-phase upload: S3 persist + conditional sandbox sync |
| 3 | Web App Upload Integration | `cowork-web-app` | ⏳ Pending | `feature/workspace-file-sync` | Upload UI uses Session Service, shows sync status |
| 4 | Integration Tests | `cowork-session-service` | ⏳ Pending | `feature/workspace-file-sync` | E2E: preseed, live sync, terminal session rejection |
| 5 | Design Doc Sync | `cowork-infra` | ⏳ Pending | `feature/workspace-file-sync` | Update session-service, agent-runtime, workspace-service docs |

---

## Principles

- **Incremental delivery**: Each step produces a testable, working unit. No step depends on untested work from a prior step.
- **Tests from the start**: Every step includes unit tests. Integration tests added at integration boundaries.
- **Existing patterns**: Same project structure, error handling, logging, CI, and Makefile conventions as existing repos.
- **No sandbox regression**: All agent-runtime changes are additive. Existing sandbox startup (`download_workspace`) and shutdown (`upload_workspace`) must pass existing tests at every step.
- **No desktop regression**: All agent-runtime changes are additive. Stdio transport is completely unaffected. Solo/desktop sessions must pass existing tests at every step. All changes are gated behind HTTP transport / sandbox mode.
- **Step numbers = execution order**: Steps are numbered in the order they should be implemented.
- **Wiring verification**: Every step must verify end-to-end wiring with adjacent components. After implementing, trace the data flow from caller to callee and back — check request/response types match, error codes are handled, timeouts are set, and no integration seams are left untested.
- **Self-review before done**: Every step includes a mandatory self-review pass before marking complete. Review all changed files for: unhandled exceptions, missing error handling at boundaries, type mismatches between components, hardcoded values that should be configurable, missing structured logging, missing tests for error paths, and any deviation from existing patterns. Fix all issues found before proceeding.
- **Logical bug review**: Every step must include a dedicated pass to check for logical bugs — race conditions, off-by-one errors, null/None dereferences, incorrect state transitions, missing edge cases, wrong comparison operators, inverted boolean logic, and incorrect error propagation. Fix all issues before marking complete.
- **Design doc sync**: Every step must update the corresponding design docs in `cowork-infra/docs/` to reflect what was actually implemented. This includes `architecture.md`, `domain-model.md`, and the service-specific design doc (e.g., `services/session-service.md`). If the implementation introduces new states, fields, endpoints, or behaviors not covered by the design doc, update the doc in the same commit or immediately after. Never let docs drift from implementation.
- **Agent runtime doc sync**: When a step touches `cowork-agent-runtime`, update `cowork-infra/docs/components/local-agent-host.md` and/or `cowork-infra/docs/components/local-tool-runtime.md` to reflect any new transport modes, protocols, endpoints, configuration, or behavioral changes. The runtime design docs are the authoritative reference for how the agent host and tool runtime work.
- **Local-first development**: Every change must work locally with `SANDBOX_LAUNCHER_TYPE=local` + LocalStack. No AWS credentials required. Every step's Definition of Done includes verifying the feature works against LocalStack, not just in unit tests.
- **Local run instructions**: Each repo must have a `make run` target and `.env.example` that allows running the service locally against LocalStack. Integration tests and manual testing should be possible without AWS credentials, using only `docker-compose up` + `make run` in each service.
- **Documentation sync**: Every step must update all relevant documentation — CLAUDE.md files in affected repos, design docs in `cowork-infra/docs/`, README files, and any other docs that describe changed behavior. This is mandatory and must be included in the Definition of Done.
- **Pre-step review**: Before starting any step, review the existing code and design docs for the areas being changed. Understand current behavior before modifying it. Check what has already been completed to avoid regressions or duplicate work.
- **Simplify review**: After completing each step, run `/simplify` on all changed files. This triggers three parallel review agents (code reuse, code quality, efficiency) that identify redundant code, hacky patterns, and performance issues. Fix all legitimate findings before marking the step complete. This is mandatory and must be included in the Definition of Done.

---

## Implementation Plan

---

### Step 1 — `workspace.sync` RPC (agent-runtime)

**Repo:** `cowork-agent-runtime`

Add a `workspace.sync` JSON-RPC method to `HttpTransport` that allows Session Service to trigger targeted file sync between S3 and the sandbox filesystem.

#### Work

1. **Add targeted sync functions to `workspace_sync.py`:**
   - `download_files(ws_url, ws_id, target_dir, paths: list[str])` — download specific files from Workspace Service to local directory. Reuses the same path validation, concurrency control (`asyncio.Semaphore(10)`), and error handling as `download_workspace()`.
   - `upload_files(ws_url, ws_id, source_dir, paths: list[str])` — upload specific files from local directory to Workspace Service. Reuses the same excluded-dir filtering and error handling as `upload_workspace()`.

2. **Add `workspace.sync` handler to `MethodDispatcher`:**
   - Register `"workspace.sync"` method in `HttpTransport`'s dispatcher
   - Handler accepts `params: {"direction": "pull"|"push", "paths": [...]}`
   - `direction=pull` + `paths` → call `download_files()` for targeted sync
   - `direction=pull` + no paths → call `download_workspace()` for full sync
   - `direction=push` + `paths` → call `upload_files()` for targeted sync
   - `direction=push` + no paths → call `upload_workspace()` for full sync
   - Returns `{"synced": [...], "failed": [...], "direction": "pull"|"push"}`

3. **Add startup sync gate (`asyncio.Event`):**
   - Create `_startup_sync_complete: asyncio.Event` on `HttpTransport`
   - Set the event after `download_workspace()` completes in `main.py` startup sequence
   - `workspace.sync` handler awaits this event (with 30s timeout) before executing
   - If timeout expires, return JSON-RPC error `-32061` (`WorkspaceSyncError`)

4. **Add sync serialization lock (`asyncio.Lock`):**
   - Create `_sync_lock: asyncio.Lock` on `HttpTransport`
   - `workspace.sync` handler acquires lock before executing
   - Prevents concurrent pull and push from corrupting the workspace

5. **Wire workspace context into `HttpTransport`:**
   - Pass `workspace_service_url` and `workspace_id` from registration result to `HttpTransport` (or to a shared context that the handler can access)
   - Pass `workspace_dir` (already available as `self._workspace_dir`)

#### Tests

- Unit: `download_files()` — downloads listed paths, skips missing, validates path traversal
- Unit: `upload_files()` — uploads listed paths, skips non-existent local files
- Unit: `workspace.sync` handler — pull with paths, pull without paths, push with paths, push without paths
- Unit: `workspace.sync` handler — returns error before startup sync completes (event not set)
- Unit: `workspace.sync` handler — serialization: concurrent calls queue, don't interleave
- Unit: `workspace.sync` handler — invalid direction returns JSON-RPC error
- Unit: Startup gate — event set after `download_workspace()`, handler proceeds after set
- Existing tests: `download_workspace()` and `upload_workspace()` still pass unchanged

#### Definition of Done

- `make check` passes on `cowork-agent-runtime`
- Can start agent-runtime in HTTP mode, call `workspace.sync` via `/rpc`, verify files are downloaded/uploaded
- Startup gate blocks sync RPC until initial `download_workspace()` completes
- Concurrent sync RPCs are serialized (no interleaving)
- Stdio transport completely unaffected — no imports, no runtime changes
- **Wiring check**: Verify `workspace.sync` request/response shape matches what Session Service (Step 2) will send. Verify `download_files()` calls the same Workspace Service API as `download_workspace()`. Verify the handler is registered in `MethodDispatcher` with the correct method name (`workspace.sync`, not `WorkspaceSync` or other casing).
- **Self-review**: Review for unhandled exceptions in `download_files`/`upload_files` (httpx errors, file I/O errors). Verify path traversal prevention on downloaded files (same as `download_workspace`). Verify `_sync_lock` is released on exception (use `async with`). Verify `_startup_sync_complete` event is set even if `download_workspace()` fails (otherwise all future sync RPCs hang). Verify structured logging on sync start, success, and failure.
- **Logical bug review**: Verify `download_files()` doesn't fail on files that don't exist in S3 yet (best-effort, skip missing). Verify `upload_files()` doesn't fail on files that don't exist locally (best-effort, skip missing). Verify sync lock timeout is reasonable (30s default, configurable). Verify no deadlock: startup gate event → sync lock (never lock → event). Verify `workspace.sync` is only registered when `--transport http` (not in stdio mode).
- **Local run**: Start agent-runtime with `make run-sandbox`, call `workspace.sync` via `curl -X POST http://localhost:8080/rpc -d '{"jsonrpc":"2.0","id":1,"method":"workspace.sync","params":{"direction":"pull","paths":["test.txt"]}}'`. Verify file appears in workspace directory.
- **Documentation**: Update `cowork-agent-runtime/CLAUDE.md` — add `workspace.sync` to RPC method list. Update `cowork-infra/docs/components/local-agent-host.md` — add workspace sync RPC section.
- **Simplify review**: Run `/simplify` on all changed files. Fix all legitimate findings (code reuse, quality, efficiency) before marking complete.

#### Principle Checklist

- [ ] Incremental delivery — step is testable standalone without Step 2
- [ ] Tests from the start — unit tests for all new functions and handlers
- [ ] Existing patterns — follows existing `workspace_sync.py` patterns (semaphore, path validation, structured logging)
- [ ] No sandbox regression — `download_workspace()` and `upload_workspace()` unchanged and passing
- [ ] No desktop regression — stdio transport unaffected, no new imports in non-sandbox code
- [ ] Wiring verification — RPC shape matches Step 2's expected call format
- [ ] Self-review — completed, all findings fixed
- [ ] Logical bug review — completed, all findings fixed
- [ ] Design doc sync — agent-runtime CLAUDE.md and local-agent-host.md updated
- [ ] Agent runtime doc sync — local-agent-host.md updated with workspace.sync RPC
- [ ] Local-first development — verified against LocalStack with `make run-sandbox`
- [ ] Documentation sync — CLAUDE.md, README, design docs all updated
- [ ] Simplify review — `/simplify` run, all findings addressed

---

### Step 2 — Unified Upload Endpoint (session-service)

**Repo:** `cowork-session-service`

Change `POST /sessions/{id}/upload` from a direct sandbox proxy to a two-phase operation: persist to S3 via Workspace Service, then conditionally notify the sandbox to sync.

#### Work

1. **Add Workspace Service client dependency:**
   - Add `workspace_http: httpx.AsyncClient` to `dependencies.py` (separate from proxy_http, with its own connection pool)
   - Configure base URL from `WORKSPACE_SERVICE_URL` setting (already in config for other uses)
   - Add `get_workspace_http` dependency provider

2. **Create `services/file_upload_service.py`:**
   - `FileUploadService` with injected `workspace_http`, `proxy_http`, `session_repo`
   - `upload_file(session_id, user_id, file_path, file_content, content_type) → UploadResult`
   - Logic:
     1. Get session from repo — validate exists, not terminal, user owns it
     2. Forward file to Workspace Service: `POST /workspaces/{workspaceId}/files?path={file_path}`
     3. Check session status: if in proxyable state (sandbox running), send `workspace.sync` RPC to sandbox endpoint
     4. Return `UploadResult(path, size, persisted=True, sandbox_synced=bool)`
   - Allowed states for upload: anything except terminal (`SESSION_CANCELLED`, `SANDBOX_TERMINATED`). This is broader than the current proxyable set.

3. **Modify `routes/proxy.py` — `proxy_upload` endpoint:**
   - Replace current implementation (forward to sandbox) with call to `FileUploadService.upload_file()`
   - Accept `path` as query parameter (currently not present — the sandbox infers from filename)
   - Return new response shape: `{path, size, persisted, sandboxSynced}`

4. **Add `workspace.sync` RPC call helper:**
   - In `FileUploadService` or `ProxyService`: method to send JSON-RPC `workspace.sync` to sandbox endpoint
   - Uses `proxy_http` client (same connection pool as other proxy calls)
   - Best-effort: catch connection errors and timeouts, log warning, return `sandbox_synced=False`
   - Timeout: 10s (configurable via `UPLOAD_SYNC_TIMEOUT_SECONDS`)

5. **Add request/response models:**
   - `UploadFileResponse(path: str, size: int, persisted: bool, sandbox_synced: bool)` in `models/responses.py`

6. **Error handling:**
   - Workspace Service returns 413 → propagate as `ValidationError` with "File too large"
   - Workspace Service returns 400 (path traversal) → propagate as `ValidationError`
   - Workspace Service unreachable → `DownstreamError` (502)
   - Session not found → `NotFoundError` (404)
   - Session terminal → `SessionInactiveError` (409)
   - Not owner → `ForbiddenError` (403)

#### Tests

- Unit: Upload with sandbox running → S3 write + RPC sync, `sandbox_synced=True`
- Unit: Upload with sandbox provisioning → S3 write only, `sandbox_synced=False`
- Unit: Upload with sandbox terminated → reject with 409
- Unit: Upload with S3 write success but RPC timeout → `persisted=True`, `sandbox_synced=False`
- Unit: Upload with S3 write failure (Workspace Service down) → 502
- Unit: Upload with invalid path (traversal) → 400
- Unit: Upload by non-owner → 403
- Unit: Upload to non-existent session → 404
- Unit: File size exceeds limit → 413 propagated
- Service: Full upload flow with DynamoDB Local (session lookup, activity update)

#### Definition of Done

- `make check` passes on `cowork-session-service`
- Upload before sandbox ready → file persisted in S3, `sandbox_synced=false`
- Upload while sandbox running → file persisted in S3 AND synced to sandbox, `sandbox_synced=true`
- Upload to terminal session → 409
- RPC failure does not fail the upload — file is still persisted, response indicates `sandbox_synced=false`
- Existing proxy endpoints (`rpc`, `events`, `files` download, `files` list) unchanged
- **Wiring check**: Verify Workspace Service file upload API matches what `FileUploadService` sends (multipart form, `path` query param). Verify `workspace.sync` RPC request matches what agent-runtime (Step 1) expects. Verify response model field names match web app expectations (camelCase in JSON).
- **Self-review**: Review for missing error handling on Workspace Service call (all httpx exceptions). Verify `path` query parameter is validated before forwarding to Workspace Service (reject `..`, absolute paths). Verify activity update fires on upload (same as other proxy endpoints). Verify structured logging: log workspace_service_upload_success/failure and sandbox_sync_success/failure with session_id, path, size.
- **Logical bug review**: Verify upload is allowed in `SANDBOX_PROVISIONING` state (not just proxyable states). Verify S3 write happens BEFORE sandbox sync (never sync without persistence). Verify `sandbox_synced` is `false` (not error) when sandbox is not ready — this is expected behavior, not an error. Verify no double-read of request body (multipart stream can only be read once — read into memory, then forward to Workspace Service). Verify session lookup caching: upload endpoint should use the same `ProxyService` cache or its own — but must include `workspaceId` in the cached data.
- **Local run**: Start session-service + workspace-service + agent-runtime locally. Create sandbox session. Upload file via `curl -F "file=@test.txt" "http://localhost:8000/sessions/{id}/upload?path=test.txt"`. Verify file appears in LocalStack S3 AND in sandbox's workspace directory.
- **Documentation**: Update `cowork-session-service/CLAUDE.md` — update upload endpoint description. Update `cowork-infra/docs/services/session-service.md` — document new upload behavior and response shape.
- **Simplify review**: Run `/simplify` on all changed files. Fix all legitimate findings (code reuse, quality, efficiency) before marking complete.

#### Principle Checklist

- [ ] Incremental delivery — step is testable standalone (upload to S3 works even without Step 1 agent-runtime changes — just `sandboxSynced=false`)
- [ ] Tests from the start — unit tests for all new service methods and error paths
- [ ] Existing patterns — follows existing proxy endpoint patterns (Depends injection, fire-and-forget activity, error mapping)
- [ ] No sandbox regression — existing proxy endpoints (`rpc`, `events`, `files`) unchanged
- [ ] No desktop regression — desktop sessions unaffected (upload endpoint only used for sandbox sessions)
- [ ] Wiring verification — Workspace Service API call matches actual endpoint; RPC call matches Step 1 handler
- [ ] Self-review — completed, all findings fixed
- [ ] Logical bug review — completed, all findings fixed
- [ ] Design doc sync — session-service design doc updated with new upload behavior
- [ ] Local-first development — verified against LocalStack with `make run`
- [ ] Local run instructions — `.env.example` includes `WORKSPACE_SERVICE_URL` and `UPLOAD_SYNC_TIMEOUT_SECONDS`
- [ ] Documentation sync — CLAUDE.md, README, design docs all updated
- [ ] Simplify review — `/simplify` run, all findings addressed

---

### Step 3 — Web App Upload Integration (cowork-web-app)

**Repo:** `cowork-web-app`

Update the web app to use the unified upload endpoint and display sync status.

#### Work

1. **Add upload API function in `src/api/client.ts`:**
   - `uploadFile(sessionId: string, path: string, file: File): Promise<UploadResult>`
   - Calls `POST /sessions/{sessionId}/upload?path={path}` with multipart form
   - Returns `{path, size, persisted, sandboxSynced}`

2. **Add upload state to `sessionStore` or new `fileStore`:**
   - Track uploaded files per session: `uploadedFiles: Map<string, {path, size, persisted, sandboxSynced}>`
   - `uploadFile(sessionId, path, file)` action — calls API, stores result
   - `clearUploads(sessionId)` action — clears on session end

3. **Add file upload UI to Conversation view:**
   - File input button or drag-and-drop zone (minimal Phase 1 — a button is sufficient)
   - Show upload progress (uploading → persisted → synced)
   - Show `sandboxSynced: false` as informational, not error ("File saved. Will sync when sandbox is ready.")

4. **Handle upload errors:**
   - 413 → "File too large" message
   - 409 → "Session is no longer active" message
   - 502 → "Upload service unavailable, please retry"

#### Tests

- Unit: `uploadFile` API function — sends correct multipart request
- Unit: File store — tracks upload results, clears on session end
- Unit: Upload button — renders, calls store action on file select
- Unit: Error display — shows correct message for each error code

#### Definition of Done

- `make check` passes on `cowork-web-app`
- User can upload a file from the conversation view
- Upload works during provisioning (before sandbox ready) — user sees "File saved"
- Upload works while sandbox running — user sees "File synced to sandbox"
- Upload to terminated session shows clear error
- **Wiring check**: Verify `uploadFile` API call matches Session Service endpoint (multipart form, `path` query param, response shape). Verify error status codes match Session Service responses. Verify Zustand selectors use granular access (not full-store destructuring).
- **Self-review**: Review for missing loading states (button disabled during upload). Review for missing error clearing (dismiss error on next upload). Verify file input accepts reasonable types (don't allow 1GB video uploads — enforce client-side size limit).
- **Logical bug review**: Verify drag-and-drop preserves relative path if user drops a folder (or reject folders in Phase 1). Verify concurrent uploads don't overwrite each other's state in the store. Verify upload button is disabled when session is in terminal state.
- **Documentation**: Update `cowork-web-app` README with upload feature description.
- **Simplify review**: Run `/simplify` on all changed files. Fix all legitimate findings (code reuse, quality, efficiency) before marking complete.

#### Principle Checklist

- [ ] Incremental delivery — step is testable standalone (upload UI works against Session Service from Step 2)
- [ ] Tests from the start — unit tests for API function, store, and UI components
- [ ] Existing patterns — follows existing Zustand store patterns (granular selectors, camelCase actions)
- [ ] Wiring verification — API call matches Session Service endpoint (multipart, path param, response shape)
- [ ] Self-review — completed, all findings fixed
- [ ] Logical bug review — completed, all findings fixed
- [ ] Documentation sync — README updated
- [ ] Simplify review — `/simplify` run, all findings addressed

---

### Step 4 — Integration Tests (session-service)

**Repo:** `cowork-session-service`

Update `scripts/test-web-sandbox.py` with comprehensive E2E tests for the unified upload flow.

#### Work

1. **Update existing `test_file_upload_download` scenario:**
   - Change from testing proxy-to-sandbox to testing unified upload (S3 + sync)
   - Upload file via `POST /sessions/{id}/upload?path=X`
   - Verify response includes `persisted=true`, `sandboxSynced=true` (sandbox is running)
   - Download file via `GET /sessions/{id}/files/X` — verify content matches
   - Verify file exists in Workspace Service S3: `GET /workspaces/{workspaceId}/files/X`

2. **Update existing `test_workspace_preseed_sync` scenario:**
   - Change from uploading directly to Workspace Service to using unified upload endpoint
   - Upload while session is in `SANDBOX_PROVISIONING` state
   - Verify response includes `persisted=true`, `sandboxSynced=false`
   - Wait for sandbox ready
   - Download file via proxy — verify content matches (sandbox synced on startup)

3. **Add new scenario: `test_upload_to_terminated_session`:**
   - Create session, wait for ready, cancel session
   - Attempt upload → verify 409 error

4. **Add new scenario: `test_upload_persistence_after_termination`:**
   - Create session, wait for ready
   - Upload file (persisted + synced)
   - Terminate sandbox
   - Verify file still exists in Workspace Service S3: `GET /workspaces/{workspaceId}/files/X`

5. **Add new scenario: `test_upload_sync_failure_still_persists`:**
   - Create session, wait for ready
   - Stop sandbox process (kill, don't cancel session)
   - Upload file — should persist to S3 but fail sandbox sync
   - Verify response: `persisted=true`, `sandboxSynced=false`
   - Verify file in S3

#### Tests

All scenarios run as part of `make test-web-sandbox`.

#### Definition of Done

- All new and updated scenarios pass against local stack (session-service + workspace-service + agent-runtime + LocalStack)
- Upload-before-ready flow works end-to-end
- Upload-while-running flow works end-to-end
- S3 persistence verified independently of sandbox state
- Terminated session rejects uploads
- **Wiring check**: Verify test HTTP calls match the actual Session Service endpoint signatures. Verify assertions check both S3 state and sandbox state independently.
- **Self-review**: Review for flaky timing assumptions (use polling with timeout, not sleep). Review for test isolation (each scenario creates its own session). Verify cleanup on test failure (cancel sessions, don't leak sandboxes).
- **Logical bug review**: Verify preseed test doesn't race between upload and sandbox registration (upload must complete before sandbox calls `download_workspace()`). Verify terminated-session test actually reaches terminal state before attempting upload.
- **Documentation**: Update scenario list in test script docstring. Update `cowork-session-service/CLAUDE.md` with new test scenarios.
- **Simplify review**: Run `/simplify` on all changed files. Fix all legitimate findings (code reuse, quality, efficiency) before marking complete.

#### Principle Checklist

- [ ] Tests from the start — all scenarios pass in local stack
- [ ] Existing patterns — follows existing test script patterns (helper functions, polling, structured error messages)
- [ ] Wiring verification — test HTTP calls match actual endpoint signatures
- [ ] Self-review — completed, all findings fixed
- [ ] Logical bug review — completed, no race conditions or flaky timing
- [ ] Local-first development — all scenarios verified against LocalStack
- [ ] Documentation sync — test script docstring and CLAUDE.md updated
- [ ] Simplify review — `/simplify` run, all findings addressed

---

### Step 5 — Design Doc Sync (cowork-infra)

**Repo:** `cowork-infra`

Update all affected design docs to reflect the new unified upload architecture.

#### Work

1. **Update `docs/services/session-service.md`:**
   - Update `POST /sessions/{id}/upload` endpoint description — new behavior, response shape, allowed states
   - Add `FileUploadService` to service architecture section
   - Add `UPLOAD_SYNC_TIMEOUT_SECONDS` to configuration table
   - Update proxy layer description — upload is no longer a simple proxy

2. **Update `docs/components/local-agent-host.md`:**
   - Add `workspace.sync` to RPC method table
   - Document startup sync gate and sync lock
   - Add `download_files()` and `upload_files()` to workspace sync section
   - Document `_startup_sync_complete` event and `_sync_lock`

3. **Update `docs/services/workspace-service.md`:**
   - Add cross-reference to workspace file sync design
   - Clarify that Session Service is the primary caller for file uploads (not just agent-runtime)

4. **Update `docs/components/web-execution-plan.md`:**
   - Update existing Step 19 ("Enhanced File Management") to reference workspace file sync as prerequisite
   - Add principles and `/simplify` requirement if not already present
   - Link to this design doc (`docs/design/workspace-file-sync.md`)
   - Update Status Tracker — add workspace file sync steps or note dependency

5. **Update `docs/design/web-execution.md`:**
   - Update the file upload/download section to reflect the new unified upload flow (S3-first, not proxy-to-sandbox)
   - Update sandbox architecture diagram — show S3 as intermediary for all file writes
   - Update the "Proxy Layer" section — upload is no longer a simple forward, it's a two-phase orchestration
   - Remove or update any references to direct sandbox upload as the primary upload path
   - Add cross-reference to this design doc (`docs/design/workspace-file-sync.md`)

6. **Update `docs/architecture.md`:**
   - Update file flow diagram in sandbox section — show S3 as intermediary for uploads
   - Update the sandbox data flow to reflect: Web App → Session Service → Workspace Service (S3) → Sandbox (via sync)

#### Definition of Done

- All design docs accurately reflect the implemented upload flow
- `web-execution.md` updated — no references to direct sandbox upload as the primary write path
- `web-execution-plan.md` updated — Step 19 references workspace file sync, links to this doc
- No doc anywhere references the old "proxy forward to sandbox" upload behavior
- Cross-references between docs are correct and bidirectional
- **Self-review**: Verify API signatures in docs match actual implementation. Verify config variable names match code. Verify state machine descriptions include the new upload-allowed states. Grep all docs for "upload" and verify each reference is accurate.
- **Documentation**: This IS the documentation step — ensure all affected CLAUDE.md files are also updated.

#### Principle Checklist

- [ ] Design doc sync — all service docs reflect implemented behavior
- [ ] Agent runtime doc sync — local-agent-host.md reflects workspace.sync RPC
- [ ] Documentation sync — all CLAUDE.md files, READMEs, and design docs updated
- [ ] Self-review — API signatures in docs match actual code, config var names match, state machine descriptions accurate
- [ ] No stale references — grep all docs for "proxy.*upload", "/upload", "forward.*sandbox" — no stale references to old behavior
- [ ] web-execution.md — updated with unified upload flow, S3-first architecture, cross-reference to this doc
- [ ] web-execution-plan.md — Step 19 updated, workspace file sync dependency noted

---

## Future Considerations

- **Batch upload:** Single request with multiple files to reduce round trips. Session Service makes one Workspace Service call per file but sends a single `workspace.sync` RPC with all paths.
- **Conflict detection:** Track file modification times in sandbox, warn on overwrite of locally-modified files. Return `conflicts` array in sync response.
- **SSE sync notification:** After sandbox confirms sync, emit an SSE event (`file_synced`) so the web app can update UI in real time.
- **Bidirectional live sync:** Agent file writes trigger automatic push to S3 (hook into `ToolExecutor` file change tracking). Would make S3 always up-to-date, enabling download from S3 instead of proxy.
- **Progress events:** For large file uploads, emit SSE events with upload progress percentage.
- **Folder upload:** Accept directory trees as a single upload, preserving structure.
- **Virus scanning:** Integrate with S3 event → Lambda → ClamAV pipeline (see web-execution-plan Step 20) before allowing sandbox to pull uploaded files.
