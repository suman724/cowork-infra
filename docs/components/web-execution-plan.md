# Web Execution — Implementation Plan

**Parent design:** [web-execution.md](web-execution.md)
**Repos touched:** `cowork-agent-runtime`, `cowork-session-service`, `cowork-workspace-service`, `cowork-web-app` (new), `cowork-platform`, `cowork-infra`

---

## Status Tracker

| Step | Name | Repo | Status | Branch | Notes |
|------|------|------|--------|--------|-------|
| 1 | Platform Contracts | `cowork-platform` | ✅ Done | `feature/web-execution-design` | Schemas, codegen, SDK helpers |
| 2 | Transport Protocol & HttpTransport | `cowork-agent-runtime` | ✅ Done | `feature/web-execution-design` | Transport protocol, HttpTransport, EventBuffer, GetEvents RPC |
| 2b | Desktop App Event Replay | `cowork-desktop-app` | ⏳ Pending | — | Event replay on view navigation; not blocking web MVP but required |
| 3 | Sandbox Self-Registration | `cowork-session-service` | ✅ Done | `feature/web-execution-design` | Registration endpoint, sandbox session states, conditional write, URL validation |
| 4 | Cloud Workspace Support | `cowork-workspace-service` | ✅ Done | `feature/web-execution-design` | s3WorkspacePrefix, file CRUD, path traversal prevention |
| 5 | Sandbox Launcher & ECS | `cowork-session-service` | ✅ Done | `feature/web-execution-design` | EcsSandboxLauncher + LocalSandboxLauncher |
| 6 | Proxy Layer | `cowork-session-service` | ✅ Done | `feature/web-execution-design` | ProxyService + 5 proxy endpoints |
| 7 | Agent Runtime Sandbox Mode | `cowork-agent-runtime` | ⏳ Pending | — | Self-registration, workspace sync, sandbox startup |
| 7b | Skills Adaptation for Web | `cowork-agent-runtime` | ⏳ Pending | — | Workspace-based skills, SKILLS_DIR env var |
| 8 | Idle/Provisioning Timeout | `cowork-session-service` | ⏳ Pending | — | Timeout enforcement, background cleanup |
| 9 | End-to-End Integration Test | Multiple | ⏳ Pending | — | Full flow: create → provision → register → task → shutdown |
| 10 | Web App Foundation | `cowork-web-app` (new) | ⏳ Pending | — | React SPA, session create, SSE events |
| 11 | Terraform Infrastructure | `cowork-infra` | ⏳ Pending | — | ECS task def, ALB, security groups |
| 12 | Docker and CI | `cowork-agent-runtime`, `cowork-infra` | ⏳ Pending | — | Dockerfile, CI pipeline |
| 13 | Warm Pool | `cowork-session-service`, `cowork-infra` | ⏳ Pending | — | Pre-provisioned idle containers |
| 14 | Connection Draining | `cowork-session-service`, `cowork-agent-runtime` | ⏳ Pending | — | Graceful shutdown with in-flight requests |
| 15 | Workspace Snapshot/Restore | `cowork-workspace-service` | ⏳ Pending | — | Session resume from S3 snapshot |
| 16 | OIDC Authentication | `cowork-session-service`, `cowork-web-app` | ⏳ Pending | — | Browser auth flow |
| 17 | EventBridge Lifecycle Manager | `cowork-session-service`, `cowork-infra` | ⏳ Pending | — | ECS task state change events |
| 18 | Auto-Scaling Warm Pool | `cowork-session-service`, `cowork-infra` | ⏳ Pending | — | Dynamic warm pool sizing |
| 19 | Enhanced File Management | `cowork-web-app` | ⏳ Pending | — | File tree, drag-and-drop upload |
| 20 | Virus Scanning for Uploads | `cowork-workspace-service`, `cowork-infra` | ⏳ Pending | — | S3 event → Lambda → ClamAV |
| 21 | GPU-Enabled Sandbox | `cowork-infra`, `cowork-session-service` | ⏳ Pending | — | GPU task definitions |
| 22 | Shared Workspace Across Sessions | Multiple | ⏳ Pending | — | Workspace reuse for cloud sessions |

---

## Principles

- **Incremental delivery**: Each step produces a testable, working unit. No step depends on untested work from a prior step.
- **Tests from the start**: Every step includes unit tests. Integration tests added at integration boundaries.
- **Existing patterns**: Same project structure, error handling, logging, CI, and Makefile conventions as existing repos.
- **No desktop regression**: All agent-runtime changes are additive. Solo/desktop sessions must pass existing tests at every step.
- **Step numbers = execution order**: Steps are numbered in the order they should be implemented.
- **Wiring verification**: Every step must verify end-to-end wiring with adjacent components. After implementing, trace the data flow from caller to callee and back — check request/response types match, error codes are handled, timeouts are set, and no integration seams are left untested.
- **Self-review before done**: Every step includes a mandatory self-review pass before marking complete. Review all changed files for: unhandled exceptions, missing error handling at boundaries, type mismatches between components, hardcoded values that should be configurable, missing structured logging, missing tests for error paths, and any deviation from existing patterns. Fix all issues found before proceeding.
- **Logical bug review**: Every step must include a dedicated pass to check for logical bugs — race conditions, off-by-one errors, null/None dereferences, incorrect state transitions, missing edge cases, wrong comparison operators, inverted boolean logic, and incorrect error propagation. Fix all issues before marking complete.
- **Design doc sync**: Every step must update the corresponding design docs in `cowork-infra/docs/` to reflect what was actually implemented. This includes `architecture.md`, `domain-model.md`, and the service-specific design doc (e.g., `services/session-service.md`). If the implementation introduces new states, fields, endpoints, or behaviors not covered by the design doc, update the doc in the same commit or immediately after. Never let docs drift from implementation.
- **Agent runtime doc sync**: When a step touches `cowork-agent-runtime`, update `cowork-infra/docs/components/local-agent-host.md` and/or `cowork-infra/docs/components/local-tool-runtime.md` to reflect any new transport modes, protocols, endpoints, configuration, or behavioral changes. The runtime design docs are the authoritative reference for how the agent host and tool runtime work.
- **Local-first development**: Every infrastructure change (DynamoDB tables, GSIs, S3 buckets) must be reflected in `scripts/localstack-init.sh` so the full stack runs locally on a developer's MacBook via `docker-compose up`. Every step's Definition of Done includes verifying the feature works against LocalStack, not just in unit tests.
- **Local run instructions**: Each repo must have a `make run` target and `.env.example` that allows running the service locally against LocalStack. Integration tests and manual testing should be possible without AWS credentials, using only `docker-compose up` + `make run` in each service.
- **Documentation sync**: Every step must update all relevant documentation — CLAUDE.md files in affected repos, design docs in `cowork-infra/docs/`, README files, and any other docs that describe changed behavior. This is mandatory and must be included in the Definition of Done.
- **Pre-step review**: Before starting any step, review the existing code and design docs for the areas being changed. Understand current behavior before modifying it. Check what has already been completed to avoid regressions or duplicate work.

---

## Local Development Setup

All web execution features must be testable locally. The local stack runs on a MacBook with:

```bash
# 1. Start infrastructure (DynamoDB + S3 via LocalStack)
cd /path/to/cowork
docker-compose up -d

# 2. Start backend services (each in a separate terminal)
cd cowork-session-service && make run     # http://localhost:8000
cd cowork-workspace-service && make run   # http://localhost:8002
cd cowork-policy-service && make run      # http://localhost:8001

# 3. Agent runtime sandbox — started AUTOMATICALLY by session-service
# When SANDBOX_LAUNCHER_TYPE=local, session-service spawns agent-runtime
# as a subprocess on a random port when you create a cloud_sandbox session.
# No manual start needed! The subprocess self-registers and session transitions
# to SANDBOX_READY automatically.
#
# To start manually (for debugging):
cd cowork-agent-runtime && make run-sandbox   # http://localhost:8080

# 4. Start web app
cd cowork-web-app && make dev             # http://localhost:5173
```

**Key env vars for local development:**
- `AWS_ENDPOINT_URL=http://localhost:4566` — all services use LocalStack
- `ENVIRONMENT=dev` — table/bucket names prefixed with `dev-`
- `SESSION_SERVICE_URL=http://localhost:8000` — agent runtime → session service
- `WORKSPACE_SERVICE_URL=http://localhost:8002` — agent runtime → workspace service
- `SANDBOX_LAUNCHER_TYPE=local` — session-service spawns agent-runtime as subprocess instead of ECS RunTask
- `AGENT_RUNTIME_PATH=../cowork-agent-runtime` — path to agent-runtime repo (used by LocalSandboxLauncher)
- `SANDBOX_LOCAL_MODE=true` — agent-runtime skips ECS metadata lookup, uses localhost for self-registration

**docker-compose.yml** already provides LocalStack with DynamoDB + S3. The `scripts/localstack-init.sh` script creates all tables and buckets on startup. When new tables, GSIs, or buckets are added in any step, `localstack-init.sh` must be updated in the same step.

---

# Phase 3a — MVP

---

## Step 1 — Platform Contracts (cowork-platform)

**Repo:** `cowork-platform`

Add schemas and SDK helpers for web execution. This unblocks all other repos.

### Work

1. Add new event types to event schema: `SANDBOX_PROVISIONING`, `SANDBOX_READY`, `SANDBOX_TERMINATED`
2. Add `SandboxRegistrationRequest` and `SandboxRegistrationResponse` schemas
3. Add `ProxyErrorResponse` schema (sandbox_unreachable, session_not_active, etc.)
4. Extend `SessionResponse` schema with sandbox-specific fields (`sandboxEndpoint`, `taskArn`, `networkAccess`, `lastActivityAt`)
5. Extend `CreateSessionRequest` with `networkAccess` field
6. Add `WorkspaceFileUpload` and `WorkspaceFileList` schemas
7. Run codegen: generate Python (Pydantic) and TypeScript bindings

### Tests

- Schema validation tests for all new schemas
- Codegen output matches expected types

### Definition of Done

- `make check` passes on cowork-platform
- Python and TypeScript bindings generated and importable
- All downstream repos can import the new types
- **Wiring check**: Import new types in session-service, workspace-service, agent-runtime — verify they compile/typecheck with no errors
- **Self-review**: Review all schemas for field name consistency (camelCase in JSON, snake_case in Python), verify enum values match design doc, check codegen output for correctness
- **Logical bug review**: Verify enum values are exhaustive (no missing states), verify optional vs required fields are correct (e.g. `sandboxEndpoint` must be optional — only present after registration), verify schema defaults don't conflict with domain logic
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 2 — Transport Protocol and HttpTransport (agent-runtime)

**Repo:** `cowork-agent-runtime`

Extract a `Transport` protocol from the existing `StdioTransport`, then implement `HttpTransport` with the same interface.

### Work

1. Create `agent_host/server/transport.py` — `Transport` protocol (`start()`, `send_event()`, `shutdown()`)
2. Update `StdioTransport` to implement the protocol (no behavior change, just conformance)
3. Create `agent_host/server/http_transport.py` — FastAPI-based HTTP server:
   - `POST /rpc` — accepts JSON-RPC 2.0, dispatches to `MethodDispatcher`, returns response
   - `GET /events` — SSE endpoint, subscribes to `EventEmitter`, streams `SessionEvent` objects with monotonic integer IDs
   - `GET /events?since={id}` — replays events from in-memory buffer after the given ID, then continues live
   - `GET /health` — returns 200 (liveness)
   - `GET /ready` — returns 200 when SessionManager is initialized (readiness)
   - `POST /upload` — accepts multipart file upload, writes to workspace directory
   - `GET /files/{path:path}` — serves file from workspace directory
   - `GET /files` — returns zip archive of workspace (when `?archive=true`)
4. Create `agent_host/server/event_buffer.py` — bounded ring buffer (default 10,000 events) with monotonic IDs for SSE replay
5. Update `EventEmitter` to also push events to the event buffer (when HttpTransport is active)
6. Update `main.py` — add `--transport` CLI arg, select `StdioTransport` or `HttpTransport` based on flag
7. Add `uvicorn` to dependencies (for HttpTransport only, already used by backend services)

### Tests

- Unit: `HttpTransport` endpoint tests (TestClient), event buffer replay, SSE serialization
- Unit: `StdioTransport` still passes all existing tests (no regression)
- Unit: `main.py` transport selection (mock both transports)
- Integration: Start HttpTransport, send JSON-RPC via httpx, verify SSE events received

### Definition of Done

- `make check` passes on agent-runtime (lint, typecheck, all tests)
- Can start agent-runtime with `--transport http`, hit `/health`, send a JSON-RPC request to `/rpc`, and receive SSE events on `/events`
- Starting with `--transport stdio` (or no flag) behaves identically to before
- File upload to `/upload` and download from `/files/{path}` work with a local workspace directory
- **Wiring check**: Verify `MethodDispatcher` receives identical request/response types from both transports. Verify `EventEmitter` → event buffer → SSE stream chain delivers events without data loss. Verify JSON-RPC error codes propagate correctly through HttpTransport
- **Self-review**: Review all changed files for unhandled exceptions (especially in SSE streaming and file upload), missing timeouts, missing structured logging on error paths, and ensure Transport protocol is satisfied by both implementations
- **Logical bug review**: Verify event buffer doesn't lose events under high throughput (ring buffer overwrite vs backpressure). Verify SSE `since` parameter handles edge cases: `since=0` (replay all), `since` greater than max ID (return empty), `since` for an ID that was evicted from buffer (return error, not silent data loss). Verify concurrent SSE clients each get their own stream and don't interfere. Verify file upload path traversal prevention (resolve path, verify within workspace root)
- **Local run**: `make run-sandbox` starts agent-runtime in HTTP mode on `localhost:8080`. Verify `/health`, `/rpc`, `/events`, `/upload`, `/files` all work locally
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 2b — Desktop App Event Replay (cowork-desktop-app)

**Repo:** `cowork-desktop-app`
**Branch:** `feature/web-execution-design` (branch from latest `main`)
**Depends on:** Step 2 (EventBuffer refactor — shared buffer at EventEmitter level, `GetEvents` JSON-RPC method in agent-runtime)

The `EventBuffer` introduced in Step 2 is shared by both transports, enabling event replay for **all** clients — not just SSE/HTTP. This step adds replay support to the Desktop App so it can recover missed events when the user navigates away from a running session and returns.

### Problem

Currently, the Desktop App dispatches events from `useSessionEvents()` to Zustand stores in real time. If the user navigates away from the conversation view (e.g., to settings or history) while a task is running, and the Electron renderer clears/resets store state on view switch, events emitted during that window are lost. The user returns to a stale or incomplete conversation.

### Work

1. **Agent-runtime: `GetEvents` JSON-RPC method** — Add a new handler that returns buffered events since a given ID. The Desktop App calls this when reconnecting to a running session:
   ```
   Request:  { "method": "GetEvents", "params": { "sinceId": 42 } }
   Response: { "events": [...], "gapDetected": false, "latestId": 87 }
   ```
2. **Desktop App: Track last seen event ID** — In the main process (`AgentRuntimeManager` or `JsonRpcClient`), track the monotonic event ID from each `SessionEvent` notification. Store it in memory (not persisted — process restart = full reload from workspace history).
3. **Desktop App: Replay on view return** — When the user navigates back to the conversation view for an active session:
   - Call `GetEvents({ sinceId: lastSeenId })` via JSON-RPC
   - Dispatch each missed event through the same `useSessionEvents` handler (deduplicate by event ID)
   - Update `lastSeenId` to the latest returned ID
4. **Desktop App: Handle gap detection** — If `gapDetected: true` (events were evicted from the ring buffer), fall back to loading full session history from Workspace Service (same as current historical session loading).
5. **Agent-runtime: Include event ID in SessionEvent notifications** — Add an `eventId` field to the `SessionEvent` JSON-RPC notification payload so the Desktop App can track the last seen ID.

### Tests

- Unit (agent-runtime): `GetEvents` handler — returns events since ID, handles gap detection, empty buffer
- Unit (desktop-app): Event ID tracking in main process — increments on each notification
- Unit (desktop-app): Replay logic — missed events dispatched in order, duplicates filtered
- Unit (desktop-app): Gap fallback — triggers full history reload from Workspace Service
- Integration: Navigate away during task, navigate back, verify no missing messages

### Definition of Done

- `make check` passes on both `cowork-agent-runtime` and `cowork-desktop-app`
- User can navigate away from a running session and return with no visible data loss
- Events emitted while user was away appear in correct order after returning
- If too many events were missed (buffer overflow), full history is loaded from Workspace Service
- **Wiring check**: Verify `GetEvents` response shape matches what Desktop App expects. Verify `eventId` field is present in all `SessionEvent` notifications. Verify replay events go through the same validation path as live events in `useSessionEvents`
- **Self-review**: Verify no race conditions between live event dispatch and replay (events could arrive while replay is in progress). Verify `lastSeenId` is reset on session change (don't carry over between sessions). Verify gap fallback actually clears store state before reloading
- **Logical bug review**: Verify deduplication works (same event dispatched both live and via replay should not appear twice). Verify replay doesn't re-trigger side effects (e.g., approval dialogs). Verify `lastSeenId` is 0 for fresh sessions (not undefined/null)
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 3 — Sandbox Self-Registration Endpoint (session-service)

**Repo:** `cowork-session-service`

Add the `/sessions/{sessionId}/register` endpoint and the new session status states for sandbox lifecycle.

### Work

1. Extend `SessionDomain` status enum with `SANDBOX_PROVISIONING`, `SANDBOX_READY`, `SANDBOX_TERMINATED`
2. Update state machine transitions to include the new states
3. Add new fields to `SessionDomain`: `sandbox_endpoint`, `task_arn`, `expected_task_arn`, `network_access`, `last_activity_at`
4. Update `DynamoSessionRepository` to persist/query new fields
5. Create `routes/sandbox.py`:
   - `POST /sessions/{sessionId}/register` — validates `SANDBOX_PROVISIONING` state, validates `taskArn` matches `expected_task_arn`, stores `sandbox_endpoint`, transitions to `SANDBOX_READY`
6. Add structured error for registration failures (`SandboxRegistrationError`)
7. Update `POST /sessions` handler: when `executionEnvironment == "cloud_sandbox"`, set initial status to `SANDBOX_PROVISIONING` (instead of `SESSION_CREATED`)

### Tests

- Unit: Registration with valid state → success, status transitions correctly
- Unit: Registration with wrong state → rejection
- Unit: Registration with mismatched `taskArn` → rejection
- Unit: New session status transitions (SANDBOX_PROVISIONING → SANDBOX_READY → SESSION_RUNNING, etc.)
- Unit: Desktop session creation still works (skips sandbox states)
- Service: DynamoDB repo correctly persists and queries new fields

### Definition of Done

- `make check` passes on session-service
- Registration endpoint works end-to-end with DynamoDB Local
- Desktop session creation is not affected (existing tests pass unchanged)
- **Wiring check**: Verify registration request/response types match what agent-runtime will send (from Step 2's HttpTransport). Verify new session fields are persisted and queryable. Verify state machine transitions are consistent — no orphaned states
- **Self-review**: Review all changed files for missing validation (e.g. malformed taskArn), missing error handling on DynamoDB conditional updates, ensure new fields have proper defaults for desktop sessions (null/None, not breaking)
- **Logical bug review**: Verify state machine has no impossible transitions (e.g. can't go from `SANDBOX_TERMINATED` back to `SANDBOX_READY`). Verify `expected_task_arn` comparison is exact string match (not prefix/contains). Verify registration is idempotent — calling register twice with same data doesn't fail. Verify conditional update expression handles `ConditionalCheckFailedException` gracefully (race between registration and timeout)
- **Local run**: Run session-service locally with `make run`, test registration endpoint via `curl` against LocalStack DynamoDB. Verify new fields are persisted and queryable
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 4 — Cloud Workspace Support (workspace-service)

**Repo:** `cowork-workspace-service`

Implement `cloud` workspace scope — S3-backed workspace that sandboxes sync files to/from.

### Work

1. Update `WorkspaceService.create_workspace()`:
   - `cloud` scope: always creates new workspace (like `general`), sets `workspace_scope = "cloud"`
   - Store `s3_workspace_prefix = "{workspaceId}/workspace-files/"` on workspace record
2. Add workspace file endpoints in `routes/workspaces.py`:
   - `POST /workspaces/{id}/files` — upload files to S3 under workspace prefix
   - `GET /workspaces/{id}/files/{path}` — download file from S3
   - `GET /workspaces/{id}/files` — list files in workspace
   - `DELETE /workspaces/{id}/files/{path}` — delete file from S3
3. Add `s3_workspace_prefix` field to `WorkspaceDomain`
4. Workspace deletion (`DELETE /workspaces/{id}`) already cascades artifacts; extend to also delete workspace files under the prefix
5. **No localstack-init.sh changes needed** — existing `dev-workspaces` table and `dev-workspace-artifacts` S3 bucket already support this. The new `s3_workspace_prefix` field is just a new attribute on existing workspace records, and workspace files use the same S3 bucket under a different key prefix

### Tests

- Unit: Cloud workspace creation, file upload/download/list/delete (InMemory stores)
- Service: DynamoDB repo with new field
- Integration: Full flow with LocalStack (S3 + DynamoDB)

### Definition of Done

- `make check` passes
- Can create a `cloud` workspace, upload files, list them, download them, delete them
- Workspace deletion cleans up both artifacts and workspace files
- `local` and `general` workspace behavior unchanged
- **Wiring check**: Verify file upload/download API matches what session-service proxy (Step 6) and agent-runtime workspace sync (Step 7) will call. Verify S3 key prefixes are consistent with artifact storage keys. Verify workspace creation response includes `s3_workspace_prefix`
- **Self-review**: Review for missing S3 error handling (ClientError → service exceptions), missing size limits on file uploads, missing cleanup on partial failures, ensure delete cascades cover both artifacts and workspace files
- **Logical bug review**: Verify file path sanitization prevents directory traversal (e.g. `../../etc/passwd` must be rejected). Verify file listing pagination handles empty directories. Verify workspace deletion with thousands of files uses batch delete (not one-by-one). Verify `cloud` workspace creation returns `s3_workspace_prefix` in response (not just stored internally). Verify file upload content-type is preserved in S3 metadata
- **Local run**: Run workspace-service locally with `make run` against LocalStack. Upload files via `curl`, verify they appear in LocalStack S3 (`awslocal s3 ls s3://dev-workspace-artifacts/{workspaceId}/workspace-files/`)
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 5 — Sandbox Launcher and ECS Integration (session-service) ✅ Done

**Repo:** `cowork-session-service`

Add a `SandboxLauncher` abstraction to launch sandbox containers. Two implementations: `EcsSandboxLauncher` for production (ECS Fargate) and `LocalSandboxLauncher` for local development (spawns agent-runtime as a subprocess). This lets us test the full provisioning lifecycle locally without ECS.

### Work

1. Create `services/sandbox_launcher.py` — `SandboxLauncher` protocol:
   - `launch(session_id, config) → LaunchResult(task_id, endpoint_hint)` — start a sandbox
   - `stop(task_id)` — stop a sandbox
   - `is_healthy(task_id) → bool` — check if sandbox is still running
2. Create `clients/ecs_launcher.py` — `EcsSandboxLauncher`:
   - `launch()` → calls ECS `RunTask` with session-specific overrides (env vars, security group), returns `task_arn`
   - `stop()` → calls ECS `StopTask`
   - `is_healthy()` → calls ECS `DescribeTasks`, checks `lastStatus`
   - Error handling: catch `ClientError`, raise `SandboxProvisionError`
   - Add `aioboto3` dependency for async ECS calls
3. Create `clients/local_launcher.py` — `LocalSandboxLauncher`:
   - `launch()` → spawns `python -m agent_host.main --transport http --port {free_port}` as a subprocess, returns `(pid, http://localhost:{port})`
   - `stop()` → sends SIGTERM to subprocess, waits up to 30s, then SIGKILL
   - `is_healthy()` → checks if subprocess is alive and `/health` returns 200
   - Picks a free port using `socket.bind(('', 0))` before spawning
   - Passes env vars to subprocess: `SESSION_ID`, `SESSION_SERVICE_URL`, `WORKSPACE_SERVICE_URL`, `AWS_ENDPOINT_URL`, `SANDBOX_LOCAL_MODE=true`
4. Create `services/sandbox_service.py`:
   - `provision_sandbox(session)` — calls `launcher.launch()`, stores `expected_task_arn` (or `local:{pid}`) on session record
   - `terminate_sandbox(session)` — sends shutdown to sandbox endpoint (best-effort), calls `launcher.stop()`, updates status with conditional write
5. Update `POST /sessions` handler: after creating session record, call `sandbox_service.provision_sandbox()`. If launch fails, transition to `SESSION_FAILED`.
6. Add config: `sandbox_launcher_type` (`ecs` or `local`, default `ecs`), `ecs_cluster`, `ecs_task_definition`, `ecs_subnets`, `ecs_security_groups`, `sandbox_image`, `agent_runtime_path` (for local launcher — path to agent-runtime repo)
7. Concurrent session limit: query active sandbox sessions for user before provisioning, reject with 409 if over limit
8. Wire launcher selection in `dependencies.py`: read `SANDBOX_LAUNCHER_TYPE` from config, instantiate the correct implementation via FastAPI `Depends`

### Tests

- Unit: `SandboxService` with mocked launcher — provision success, provision failure, terminate
- Unit: `LocalSandboxLauncher` — spawn, stop, health check (use a simple HTTP server as stand-in, not real agent-runtime)
- Unit: `EcsSandboxLauncher` with mocked boto3 — RunTask success/failure, StopTask, DescribeTasks
- Unit: Concurrent session limit enforcement (at limit → 409, under limit → allowed)
- Unit: Launch failure → session transitions to SESSION_FAILED
- Service: Full session creation flow with `LocalSandboxLauncher` (DynamoDB Local for session persistence, real subprocess spawn)

### Definition of Done

- `make check` passes
- Creating a `cloud_sandbox` session stores task identifier and sets status to `SANDBOX_PROVISIONING`
- Launch failure results in `SESSION_FAILED` with structured error
- Concurrent session limit rejects excess sessions with 409
- `SANDBOX_LAUNCHER_TYPE=local`: session creation spawns a real agent-runtime subprocess on a random port, subprocess self-registers, session transitions to `SANDBOX_READY` — **full lifecycle works locally with zero AWS dependencies**
- `SANDBOX_LAUNCHER_TYPE=ecs`: session creation calls ECS RunTask (tested with mocked boto3)
- **Wiring check**: Verify ECS RunTask overrides (env vars, security groups) match what agent-runtime expects in sandbox startup (Step 7). Verify `expected_task_arn` stored on session matches what container will read from ECS metadata. Verify `LocalSandboxLauncher` passes the same env vars to subprocess that ECS task definition would set. Verify error responses use platform contract types from Step 1
- **Self-review**: Review for missing error handling on ECS API calls (ClientError subtypes), ensure session status rollback on launch failure is atomic, verify concurrent limit query uses correct GSI and status filters, check for race conditions between session creation and limit check. Review `LocalSandboxLauncher` for subprocess cleanup (no zombie processes on failure)
- **Logical bug review**: Verify concurrent session limit count query filters by correct statuses (`SANDBOX_PROVISIONING` + `SANDBOX_READY` + running sessions, not terminated). Verify launch failure doesn't leave session in `SANDBOX_PROVISIONING` forever (must transition to `SESSION_FAILED`). Verify `expected_task_arn` is stored BEFORE launch returns (not after — race with fast-starting container). Verify ECS client handles throttling (too many RunTask calls). Verify `LocalSandboxLauncher` doesn't leak file descriptors (subprocess stdout/stderr must be captured or redirected). Verify free port selection doesn't race (port freed between `socket.bind` and subprocess start — use SO_REUSEADDR or accept the rare collision)
- **Local run**: Set `SANDBOX_LAUNCHER_TYPE=local` and `AGENT_RUNTIME_PATH=../cowork-agent-runtime` in `.env`. Run `make run`. Create a `cloud_sandbox` session via `curl POST http://localhost:8000/sessions`. Verify: subprocess spawns, registers, session status transitions to `SANDBOX_READY`, proxy endpoints work (Step 6). This is the **primary local testing flow** for all sandbox features
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 6 — Proxy Layer (session-service)

**Repo:** `cowork-session-service`

Add proxy endpoints that forward browser requests to the sandbox container.

### Work

1. Create `services/proxy_service.py`:
   - `resolve_sandbox(session_id) → sandbox_endpoint` — reads from DynamoDB with TTL cache (30s)
   - `validate_proxy_request(session, user_id)` — checks session is active, caller owns it
   - `update_activity(session_id)` — batched `lastActivityAt` updates (>60s since last write)
2. Create `routes/proxy.py`:
   - `POST /sessions/{sessionId}/rpc` — forward JSON-RPC to sandbox `/rpc`, return response
   - `GET /sessions/{sessionId}/events` — SSE proxy: `httpx.AsyncClient.stream()` → `StreamingResponse`
   - `POST /sessions/{sessionId}/upload` — forward multipart to sandbox `/upload`
   - `GET /sessions/{sessionId}/files/{path:path}` — forward to sandbox `/files/{path}`
   - `GET /sessions/{sessionId}/files` — forward to sandbox `/files?archive=true`
3. Error handling:
   - Sandbox unreachable → `503 Service Unavailable` with `sandbox_unreachable` error code
   - Session not found → 404
   - Session not active → `409 Conflict` with current status
   - Not session owner → 403
4. SSE proxy specifics:
   - Pass `Last-Event-ID` header through to sandbox
   - Set proxy timeout to `maxSessionDuration` (default 4h)
   - Detect client disconnect, close upstream connection
5. Add `httpx` connection pool for sandbox connections (separate from existing service-to-service clients)

### Tests

- Unit: Proxy resolves sandbox endpoint, caches correctly, cache expires
- Unit: Activity batching (first call writes, second within 60s skips, after 60s writes again)
- Unit: SSE proxy streams chunks correctly (mock sandbox)
- Unit: Error cases (sandbox down → 503, wrong owner → 403, inactive session → 409)
- Integration: Full proxy flow with real HttpTransport running in a subprocess

### Definition of Done

- `make check` passes
- Can proxy JSON-RPC, SSE, file upload/download through Session Service to a running sandbox
- SSE reconnect with `Last-Event-ID` works through the proxy
- Activity tracking updates DynamoDB at most once per 60s per session
- **Wiring check**: Verify proxy forwards all headers correctly (Last-Event-ID, Content-Type, Authorization). Verify SSE proxy streams events byte-for-byte without corruption. Verify error responses from sandbox are translated to proxy error responses matching platform contract types. Test with real HttpTransport from Step 2 running in a subprocess
- **Self-review**: Review for connection leak risks (SSE proxy must close upstream on client disconnect), missing timeouts on proxy connections, missing structured logging for proxy errors, ensure cache invalidation on session status changes, verify 403/404/409/503 error paths all return structured responses
- **Logical bug review**: Verify SSE proxy doesn't buffer entire response before forwarding (must stream chunk-by-chunk). Verify `lastActivityAt` batching timer resets correctly (not using wall clock that drifts). Verify cache TTL is per-session (not global — stale entry for session A shouldn't affect session B). Verify proxy doesn't forward internal sandbox errors (500s from sandbox should be wrapped in proxy error response, not passed through raw). Verify endpoint cache is invalidated when session status changes to terminated (don't proxy to dead sandbox)
- **Local run**: Run session-service with `SANDBOX_ENDPOINT=http://localhost:8080` to bypass DynamoDB sandbox endpoint lookup. Run agent-runtime in HTTP mode on port 8080. Test full proxy flow: `curl http://localhost:8000/sessions/{id}/rpc` → verify it reaches agent-runtime. Test SSE: `curl http://localhost:8000/sessions/{id}/events` → verify events stream through
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 7 — Agent Runtime Sandbox Mode (agent-runtime)

**Repo:** `cowork-agent-runtime`

Wire the sandbox startup flow: read session ID from env, self-register with Session Service, create session via HTTP (not JSON-RPC).

### Work

1. Create `agent_host/sandbox/startup.py`:
   - Read `SESSION_ID`, `SESSION_SERVICE_URL` from env
   - Read container IP from ECS metadata endpoint (`$ECS_CONTAINER_METADATA_URI_V4`)
   - Call `POST /sessions/{sessionId}/register` with endpoint and task ARN
   - Receive session token, workspace config
2. Create `agent_host/sandbox/workspace_sync.py`:
   - Sync workspace files from S3 (via Workspace Service) to local `/workspace` directory on startup
   - Sync local `/workspace` back to S3 on task completion and shutdown
3. Update `main.py` for `--transport http` mode:
   - Run sandbox startup (register, sync workspace)
   - Start HttpTransport (serves /rpc, /events, /upload, /files, /health)
   - On shutdown: sync workspace, notify Session Service
4. Update `SessionManager` or create `SandboxSessionManager`:
   - Skip `CreateSession` JSON-RPC handler (session already exists)
   - Load session context from registration response instead of creating new
5. Graceful shutdown: on SIGTERM, sync workspace to S3, complete in-flight operations (30s grace)
6. **Skills for sandbox mode** — see Step 7b for full details. In this step, ensure the skill loader can operate in sandbox mode (no home directory). Skills must come from workspace files or policy bundle, not `~/.cowork/skills/`.

### Tests

- Unit: Sandbox startup with mocked HTTP (registration success, registration failure)
- Unit: Workspace sync (mock S3 operations)
- Unit: Graceful shutdown sequence
- Unit: SIGTERM handling
- Unit: Skill loader in sandbox mode (no home directory, skills from workspace)
- Integration: Full sandbox startup → register → serve → shutdown flow (with mocked Session Service)

### Definition of Done

- `make check` passes (all existing tests + new tests)
- Agent runtime in HTTP mode reads session ID, registers with Session Service, syncs workspace, serves HTTP
- SIGTERM triggers graceful shutdown with workspace sync
- Stdio mode is completely unaffected
- **Wiring check**: Verify registration request matches Step 3's endpoint contract exactly (field names, types, auth). Verify workspace sync calls match Step 4's file upload/download API. Verify session token from registration response is used for all subsequent backend calls. Test full startup → register → serve → shutdown sequence against a real Session Service instance
- **Self-review**: Review for missing error handling on registration failure (retry? fail fast?), missing cleanup if workspace sync fails on startup, ensure SIGTERM handler doesn't race with in-flight requests, verify ECS metadata endpoint parsing handles all edge cases
- **Logical bug review**: Verify workspace sync downloads files BEFORE marking sandbox as ready (don't serve requests with empty workspace). Verify SIGTERM handler waits for workspace sync to complete before exiting (data loss risk). Verify registration retry has a max attempt limit (don't retry forever if session-service is down). Verify `SANDBOX_LOCAL_MODE` code path is tested — local mode must skip ECS metadata but still register with session-service. Verify file sync handles empty workspace (no files to sync — should not error)
- **Local run**: Add `make run-sandbox` target to agent-runtime Makefile: `SANDBOX_LOCAL_MODE=true SESSION_ID=test-session-123 SESSION_SERVICE_URL=http://localhost:8000 WORKSPACE_SERVICE_URL=http://localhost:8002 python -m agent_host.main --transport http`. Verify: starts up, registers with local session-service, serves `/health`, accepts JSON-RPC on `/rpc`, streams events on `/events`
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 7b — Skills Adaptation for Web Execution (agent-runtime)

**Repo:** `cowork-agent-runtime`
**Depends on:** Step 7 (Sandbox Mode)

Skills currently load from `~/.cowork/skills/` on the host filesystem. In a sandbox (ECS container), there is no home directory with user-created skills. This step ensures skills work correctly in web execution mode.

### Problem

The `SkillLoader` (`skills/skill_loader.py`) discovers skills from three sources:
1. **Built-in skills** — bundled in the agent-runtime package (work in sandbox as-is)
2. **User skills** — loaded from `~/.cowork/skills/<name>/SKILL.md` (home directory, **not available in sandbox**)
3. **Policy skills** — injected via policy bundle (work in sandbox as-is)

In web execution mode, user skills must come from a different source.

### Work

1. **Audit skill sources** — Review all three skill loading paths in `SkillLoader` to understand dependencies on the local filesystem
2. **Workspace-based skills** — In sandbox mode, look for user skills in the workspace directory (e.g., `/workspace/.cowork/skills/`) instead of `~/.cowork/skills/`. This way, users can include custom skills in their uploaded workspace files
3. **Configurable skill directory** — Add `SKILLS_DIR` env var to override the default user skills path. In sandbox mode, default to `/workspace/.cowork/skills/`; in desktop mode, keep `~/.cowork/skills/`
4. **Graceful degradation** — If no user skills directory exists in the sandbox, load only built-in and policy skills without errors
5. **Project-level skills** — Also check workspace root for `.cowork/skills/` (project-level skills). This pattern already benefits desktop mode (project-specific skills) and works naturally in sandbox mode (skills uploaded with workspace)

### Tests

- Unit: SkillLoader with no home directory (sandbox simulation) — loads built-in + policy skills only
- Unit: SkillLoader with workspace-based skills directory — discovers and loads skills correctly
- Unit: `SKILLS_DIR` env var override — uses specified directory
- Unit: Missing skills directory — graceful degradation, no errors
- Integration: Upload workspace with custom skills, verify they load in sandbox mode

### Definition of Done

- Skills work in sandbox mode without home directory access
- Users can include custom skills in workspace files
- Built-in and policy skills always load regardless of mode
- Desktop mode behavior unchanged (no regression)
- `make check` passes
- **Wiring check**: Verify skill loading paths in sandbox mode resolve within the workspace directory. Verify workspace sync (Step 7) preserves the `.cowork/skills/` directory structure. Verify uploaded skills pass through the same validation as filesystem skills
- **Self-review**: Verify no path traversal is possible via skill file paths. Verify skill files from workspace are size-limited (same as local skills). Verify error messages clearly indicate where skills were searched
- **Logical bug review**: Verify skill name collisions between built-in, workspace, and policy skills are resolved in a predictable order (policy > workspace > built-in). Verify markdown skill parsing handles edge cases (empty files, invalid YAML frontmatter). Verify skill directory creation doesn't fail in read-only filesystems
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 8 — Idle Timeout and Provisioning Timeout (session-service)

**Repo:** `cowork-session-service`

Add background task for idle timeout enforcement and provisioning timeout cleanup.

### Work

1. Create `services/sandbox_lifecycle.py`:
   - `SandboxLifecycleManager` — started as a background task on app startup
   - `check_idle_sessions()` — query active sandbox sessions, check `lastActivityAt` against timeout, verify no running tasks for that session (busy sandbox is never idle), terminate idle ones with conditional DynamoDB update
   - `check_provisioning_timeouts()` — query `SANDBOX_PROVISIONING` sessions older than 180s (3 min), transition to `SESSION_FAILED`
   - Both use conditional updates for multi-instance safety
2. Register lifecycle manager in FastAPI lifespan (start on startup, cancel on shutdown)
3. Add config: `sandbox_idle_timeout_seconds` (default 1800), `sandbox_max_duration_seconds` (default 14400), `sandbox_provision_timeout_seconds` (default 180), `sandbox_lifecycle_check_interval_seconds` (default 300)
4. Max duration enforcement: check `created_at + maxDuration < now` for active sandbox sessions

### Tests

- Unit: Idle timeout detection — session idle with no running task → terminated
- Unit: Idle timeout skip — session idle but task still running → not terminated
- Unit: Provisioning timeout detection (>180s → SESSION_FAILED)
- Unit: Max duration enforcement
- Unit: Conditional update conflict handling (simulated concurrent instance)
- Unit: Lifecycle manager start/stop lifecycle

### Definition of Done

- `make check` passes
- Idle sessions (no running task + no user activity) are terminated after configured timeout
- Sessions with active tasks are never terminated by idle check, even if user is away
- Stuck provisioning sessions are cleaned up after 180s
- Max duration sessions are terminated
- Multiple lifecycle managers running concurrently don't cause errors (conditional updates)
- **Wiring check**: Verify lifecycle manager queries use correct GSI and status filters matching Step 3's session model. Verify terminate flow calls sandbox shutdown endpoint (matching Step 7's HttpTransport) before calling `launcher.stop()` (matching Step 5's SandboxLauncher). Verify task status check queries the tasks table with correct index from session-service
- **Self-review**: Review for missing error handling when sandbox is unreachable during shutdown (best-effort, don't block), ensure lifecycle manager doesn't crash on individual session failures (catch per-session, continue loop), verify conditional update expressions are correct, check that background task shuts down cleanly on app exit
- **Logical bug review**: Verify idle check compares `lastActivityAt` using UTC consistently (not mixing local time). Verify provisioning timeout uses `createdAt` of the session, not `lastActivityAt` (which may not be set yet). Verify max duration check uses session `createdAt`, not task `createdAt`. Verify the "running task" check queries the tasks table with status filter (only `running` tasks count, not `completed` or `failed`). Verify conditional update prevents double-termination (two lifecycle checks running concurrently on different instances)
- **Local run**: Run session-service with `SANDBOX_LAUNCHER_TYPE=local`, create a sandbox session, wait for idle timeout (set to 30s for testing via env var). Verify the `LocalSandboxLauncher` subprocess is killed and session transitions to `SANDBOX_TERMINATED`. Verify lifecycle manager logs appear in structured format
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 9 — End-to-End Integration Test

**Repos:** `cowork-agent-runtime`, `cowork-session-service`, `cowork-workspace-service`

Verify the full sandbox lifecycle works across services. Uses `LocalSandboxLauncher` — session-service spawns agent-runtime subprocesses automatically, no ECS needed.

### Work

1. Create integration test script `scripts/test-web-sandbox.py` (similar to `test-chat.py` for desktop):
   - `POST /sessions` with `cloud_sandbox` → verify `SANDBOX_PROVISIONING`
   - Wait for `LocalSandboxLauncher` to spawn subprocess → subprocess self-registers → verify `SANDBOX_READY`
   - `GET /sessions/{id}/events` via proxy → verify SSE stream opens
   - `POST /sessions/{id}/rpc` with `start_task` → verify task runs
   - Verify events stream through proxy
   - Verify workspace sync to S3
   - Cancel session → verify sandbox terminates
2. Test reconnect: disconnect SSE, reconnect with `Last-Event-ID`, verify replay
3. Test file upload/download through proxy
4. Test idle timeout (set to short duration in test)
5. Test provisioning timeout (sandbox never registers)

### Tests

- Integration: Full lifecycle with LocalStack + `LocalSandboxLauncher` (real agent-runtime subprocesses, no ECS)

### Definition of Done

- Full sandbox lifecycle runs end-to-end in CI (with LocalStack)
- Reconnect replays missed events correctly
- File upload/download works through proxy
- Idle timeout and provisioning timeout tested
- **Wiring check**: This step IS the wiring check — verify every integration seam from Steps 1–8 works together. Document any mismatches found and fix them in the originating step before proceeding
- **Self-review**: Review test coverage for all error paths (sandbox crash mid-task, network timeout during proxy, workspace sync failure). Ensure test script has clear error reporting so failures are easy to diagnose
- **Logical bug review**: Verify test assertions check for correct status transitions (not just final state). Verify SSE reconnect test actually disconnects mid-stream (not just opens a new connection). Verify file upload test checks content integrity (not just 200 status). Verify idle timeout test doesn't race with the lifecycle check interval (use short interval for tests)
- **Local run**: The E2E test IS the local run — `scripts/test-web-sandbox.py` runs entirely locally: `docker-compose up -d` + session-service with `SANDBOX_LAUNCHER_TYPE=local` + workspace-service + policy-service. The script creates a session, session-service auto-spawns agent-runtime subprocess, and the test drives the full lifecycle: provisioning → ready → proxy RPC → stream SSE → upload file → idle timeout. Add `make test-sandbox` target to cowork-agent-runtime Makefile. No AWS credentials needed
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 10 — Web App Foundation (cowork-web-app)

**Repo:** `cowork-web-app` (new)

Set up the repo and build the core web UI.

### Work

1. Initialize repo: Vite + React + TypeScript, Tailwind CSS, Zustand, ESLint, Prettier
2. Create CLAUDE.md, README.md, Makefile (standard targets), .github/workflows/ci.yml
3. Add `@cowork/platform` dependency for TypeScript types
4. Implement core infrastructure:
   - `api/` — Session Service API client (fetch-based, typed)
   - `sse/` — SSE client with auto-reconnect, `Last-Event-ID`, typed event parsing
   - `state/` — Zustand stores: `sessionStore`, `conversationStore`, `fileStore`
   - `auth/` — Simple auth (API key header for Phase 3a)
5. Implement views:
   - Session list — create new session, list active/recent, delete
   - Conversation — message input, LLM response streaming, tool call results
   - File browser — tree view of workspace files, upload, download
   - Approval dialog — approve/deny with tool call details
   - Patch preview — diff view for file changes
6. Implement provisioning UX:
   - Session creation → loading state ("Starting sandbox...")
   - Poll `GET /sessions/{id}` until `SANDBOX_READY`
   - Transition to conversation view, open SSE connection

### Tests

- Unit: Zustand stores (session state transitions, conversation message handling)
- Unit: SSE client (connect, reconnect, event parsing)
- Unit: API client (request/response handling, error mapping)
- Component: Key view components with React Testing Library

### Definition of Done

- `make check` passes (lint, typecheck, test)
- Can create a session, see provisioning state, transition to conversation
- Can send tasks, see streaming responses, approve/deny tool calls
- Can upload/download files
- Reconnect after page refresh shows full history
- **Wiring check**: Verify SSE event types match what HttpTransport emits (Step 2). Verify JSON-RPC method names and params match agent-runtime handlers. Verify API client URLs and request/response shapes match session-service proxy endpoints (Step 6). Verify auth header format matches session-service expectations
- **Self-review**: Review for missing error states in UI (sandbox provisioning failure, proxy 503, SSE disconnect without reconnect), ensure all API errors are shown to user with actionable messages, check for memory leaks in SSE client (event listener cleanup), verify Zustand stores handle all state transitions correctly
- **Logical bug review**: Verify SSE client doesn't accumulate event listeners on reconnect (must remove old listener before adding new). Verify provisioning poll stops when component unmounts (memory leak / state update on unmounted component). Verify conversation store handles out-of-order events (SSE replay may deliver events the store already has). Verify session list doesn't show terminated sessions as active after page refresh. Verify file upload progress tracking handles network errors (don't show stuck progress bar)
- **Local run**: `make dev` starts Vite dev server on `localhost:5173`. Configure `.env.development` with `VITE_SESSION_SERVICE_URL=http://localhost:8000`. Full local flow: create session in web UI → see provisioning → conversation loads → send task → see streaming response. Add instructions to `cowork-web-app/README.md` for local development setup
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 11 — Terraform Infrastructure (cowork-infra)

**Repo:** `cowork-infra`

Add Terraform modules for sandbox ECS resources.

### Work

1. Create `iac/modules/sandbox/`:
   - ECS task definition (cowork-{env}-sandbox)
   - Security groups (sandbox SG, Session Service → sandbox ingress rule)
   - IAM task role (S3 access scoped to workspace, CloudWatch Logs)
   - IAM execution role (ECR pull, CloudWatch Logs)
   - CloudWatch log group (`/cowork/{env}/sandbox/`)
2. Update `iac/modules/ecs-service/` for Session Service:
   - Add ECS `RunTask` permissions to Session Service task role
   - Add sandbox security group ID as output for cross-reference
3. Update environment configs (`iac/environments/dev/`, `staging/`, `prod/`):
   - Add sandbox module instantiation
   - Add sandbox-specific variables (CPU, memory, subnets, idle timeout)
4. Add S3 bucket policy: sandbox task role can read/write under `{workspaceId}/` prefix only

### Tests

- `terraform validate` for all environments
- `terraform plan` produces expected resources

### Definition of Done

- `make validate` passes for all environments
- `terraform plan-dev` shows sandbox task definition, security groups, IAM roles, log groups
- Session Service task role has `ecs:RunTask` and `ecs:StopTask` permissions
- Sandbox task role has scoped S3 and CloudWatch access
- **Wiring check**: Verify ECS task definition env vars match what agent-runtime expects (Step 7). Verify security group rules match proxy flow (Session Service → sandbox on port 8080). Verify IAM policies scope to correct S3 bucket and DynamoDB tables. Verify log group name matches what agent-runtime's structlog writes to
- **Self-review**: Review for overly permissive IAM policies, missing tags on resources, hardcoded values that should be variables, ensure all resources are prefixed with `cowork-{env}-`
- **Logical bug review**: Verify security group rules are not overly permissive (sandbox ingress only from Session Service SG, not 0.0.0.0/0). Verify S3 bucket policy scopes sandbox task role to `{workspaceId}/*` prefix (not entire bucket). Verify log group retention is set (not infinite). Verify ECS task definition CPU/memory values are valid Fargate combinations. Verify IAM execution role has ECR pull permissions for the correct registry
- **No localstack-init.sh changes needed** — Terraform resources are for AWS environments. Local development uses the existing LocalStack setup
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 12 — Docker and CI (agent-runtime, infra)

**Repo:** `cowork-agent-runtime`, `cowork-infra`

Add Dockerfile for agent-runtime and CI pipeline for sandbox builds.

### Work

1. Create `Dockerfile` in agent-runtime:
   - Multi-stage build (same pattern as session-service, workspace-service)
   - Python 3.12, non-root user
   - Install `uvicorn` for HTTP transport
   - Default entrypoint: `python -m agent_host.main --transport http`
   - Health check: `GET /health`
2. Update agent-runtime Makefile: add `docker-build` target
3. Update agent-runtime CI: add Docker build step
4. Update `cowork-infra/ci/`:
   - Add sandbox image build workflow (build, push to ECR)
   - Add sandbox deploy workflow (update ECS task definition)

### Tests

- Docker build succeeds
- Container starts, `/health` returns 200
- CI pipeline runs end-to-end

### Definition of Done

- `make docker-build` produces a working image
- Container starts in HTTP mode, responds to health checks
- CI builds and pushes image to ECR
- **Wiring check**: Verify Dockerfile installs all dependencies needed for HTTP mode (uvicorn, fastapi). Verify entrypoint and health check match ECS task definition from Step 11. Verify container can reach Session Service URL for registration (network connectivity). Run the E2E test from Step 9 against the Docker container instead of a local process
- **Self-review**: Review Dockerfile for unnecessary layers, missing non-root user, missing health check interval, ensure .dockerignore excludes tests/docs/dev files, verify CI pipeline triggers on correct branches
- **Logical bug review**: Verify Dockerfile doesn't copy `.env` or secrets into the image. Verify health check endpoint matches the one HttpTransport exposes (`/health`, not `/healthz`). Verify entrypoint uses exec form (not shell form — PID 1 issue for SIGTERM handling). Verify non-root user has write access to `/workspace` directory inside container
- **Local run**: `make docker-build && docker run -p 8080:8080 -e SANDBOX_LOCAL_MODE=true -e SESSION_ID=test -e SESSION_SERVICE_URL=http://host.docker.internal:8000 -e WORKSPACE_SERVICE_URL=http://host.docker.internal:8002 -e AWS_ENDPOINT_URL=http://host.docker.internal:4566 cowork-sandbox:latest` — verify container starts, `/health` returns 200, `/rpc` accepts JSON-RPC. Add this to agent-runtime README. Can also test with `SANDBOX_LAUNCHER_TYPE=local` in session-service pointing `AGENT_RUNTIME_PATH` to the Docker image (future enhancement)
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

# Phase 3b — Optimization

Prerequisite: Phase 3a complete and deployed.

---

## Step 13 — Warm Pool (session-service, infra)

**Repos:** `cowork-session-service`, `cowork-infra`

Pre-provision idle sandbox containers so sessions start in <3s instead of 15–45s.

### Work

1. Create `services/warm_pool.py` in session-service:
   - `WarmPoolManager` — background task that maintains a target number of idle containers
   - `acquire_container() → (task_arn, sandbox_endpoint)` — claim an idle container from the pool, assign it to a session
   - `replenish()` — if pool size < target, launch new ECS tasks (pre-registered as `POOL_IDLE`)
   - `drain_excess()` — if pool size > target, stop excess idle containers
2. New DynamoDB table `{env}-warm-pool` (update `scripts/localstack-init.sh` to create this table):
   - Track idle containers: `taskArn`, `sandboxEndpoint`, `createdAt`, `status` (POOL_IDLE, POOL_CLAIMED)
   - Conditional update on claim to prevent double-assignment
3. Update `POST /sessions` for `cloud_sandbox`:
   - Try `warm_pool.acquire_container()` first
   - If pool empty, fall back to cold-start `RunTask` (same as Phase 3a)
   - If warm container acquired, skip `SANDBOX_PROVISIONING` → go directly to `SANDBOX_READY`
4. Warm container startup: containers start in HTTP mode, register with Session Service as `POOL_IDLE`, wait for assignment
5. Assignment flow: Session Service updates the container's `SESSION_ID` env via RPC, container initializes session context
6. Terraform: add warm pool config variables (target size, min, max), CloudWatch alarm for pool depletion

### Tests

- Unit: WarmPoolManager — replenish, acquire, drain, concurrent acquire (conditional update)
- Unit: Session creation — warm hit (instant), warm miss (fallback to cold start)
- Unit: Pool container lifecycle (POOL_IDLE → POOL_CLAIMED → SESSION_RUNNING)
- Integration: Full warm pool flow with mocked ECS

### Definition of Done

- `make check` passes on session-service
- Session creation with available warm container skips provisioning wait
- Pool auto-replenishes after containers are claimed
- Cold-start fallback works when pool is empty
- Pool size is configurable per environment
- **Wiring check**: Verify warm container assignment RPC matches HttpTransport's endpoint. Verify session creation flow still works end-to-end (both warm hit and cold miss paths). Verify pool containers use same task definition and security groups as cold-start containers from Step 5
- **Self-review**: Review for race conditions in concurrent acquire (conditional update correctness), ensure pool replenishment doesn't exceed max, verify cleanup of stale pool entries (container crashed before claim)
- **Logical bug review**: Verify conditional update on `POOL_IDLE → POOL_CLAIMED` transition uses correct condition expression (status must equal `POOL_IDLE`, not just exist). Verify pool replenishment doesn't launch tasks when pool is at max (check count before launching). Verify stale detection uses `createdAt` not `lastActivityAt` (pool containers have no user activity). Verify pool drain stops the right containers (LIFO — drain newest first to keep warmed containers)
- **Local run**: Update `scripts/localstack-init.sh` with `dev-warm-pool` DynamoDB table creation. Test warm pool flow locally with `SANDBOX_LOCAL_MODE=true` — pool "containers" are just DynamoDB entries. Verify acquire/release/replenish operations against LocalStack
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 14 — Connection Draining (session-service, agent-runtime)

**Repos:** `cowork-session-service`, `cowork-agent-runtime`

Gracefully handle sandbox shutdown while SSE connections and in-flight requests are active.

### Work

1. Agent-runtime (`http_transport.py`):
   - On shutdown signal, stop accepting new requests (return 503)
   - Wait for in-flight RPC requests to complete (up to 30s grace)
   - Send final SSE event `{"type": "sandbox_shutting_down"}` to all connected clients
   - Close all SSE connections
2. Session Service proxy:
   - On `503` from sandbox, check if session is terminating
   - If terminating, return structured error `sandbox_shutting_down` with session history URL
   - If not terminating (transient error), retry once
3. Web app:
   - On `sandbox_shutting_down` SSE event, show "Session ending" UI
   - Fetch final history from Workspace Service
   - Disable input, show session summary

### Tests

- Unit: HttpTransport drain sequence (stop accepting → flush → close)
- Unit: Proxy retry vs shutdown detection
- Unit: Web app handles shutdown event gracefully
- Integration: Trigger shutdown during active SSE stream, verify clean handoff

### Definition of Done

- No dropped events during graceful shutdown
- Browser shows clean transition from live to terminated
- In-flight requests complete before container stops
- **Wiring check**: Verify shutdown SSE event type is handled by web app. Verify proxy correctly distinguishes 503-from-shutdown vs 503-from-transient-error. Verify workspace sync completes before container exits. Test with real proxy and real web app connected
- **Self-review**: Review for edge cases (shutdown during file upload, shutdown during LLM streaming), ensure no goroutine/task leaks on shutdown, verify grace period is configurable
- **Logical bug review**: Verify drain sequence order is correct: stop accepting → flush in-flight → send shutdown event → close connections (not close connections → then try to send event). Verify 503 from sandbox during shutdown includes a distinguishable error code (not generic 503). Verify web app doesn't try to auto-reconnect SSE after receiving `sandbox_shutting_down` event (infinite reconnect loop). Verify workspace sync on shutdown doesn't race with final artifact upload
- **Local run**: Start agent-runtime in HTTP mode, connect SSE client, send SIGTERM — verify shutdown event arrives before connection closes. Verify in-flight `/rpc` request completes before shutdown
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 15 — Workspace Snapshot/Restore (workspace-service, session-service, web-app)

**Repos:** `cowork-workspace-service`, `cowork-session-service`, `cowork-web-app`

Allow users to resume work from a terminated sandbox by restoring the workspace state into a new container.

### Work

1. Workspace Service:
   - `POST /workspaces/{id}/snapshot` — create a point-in-time snapshot of all workspace files in S3 (copy to `{workspaceId}/snapshots/{snapshotId}/`)
   - `GET /workspaces/{id}/snapshots` — list available snapshots
   - Auto-snapshot on sandbox termination (triggered by Session Service)
2. Session Service:
   - `POST /sessions/{sessionId}/restore` — create a new session from a terminated one:
     - Create new `cloud_sandbox` session linked to same workspace
     - Provision sandbox, restore workspace files from latest snapshot
     - Return new session ID
3. Web app:
   - On terminated session view, show "Resume" button
   - Resume triggers restore flow, shows provisioning state, transitions to new session
   - Conversation history loaded from Workspace Service (previous session's history)

### Tests

- Unit: Snapshot creation and listing
- Unit: Restore flow — new session creation, workspace file restore
- Unit: Web app resume UX (terminated → provisioning → running)
- Integration: Full terminate → snapshot → restore → verify files present

### Definition of Done

- Terminated sessions show "Resume" option in web app
- Resume creates new sandbox with all previous workspace files restored
- Conversation history from previous session is visible
- Snapshot cleanup (auto-delete after 30 days)
- **Wiring check**: Verify snapshot S3 keys don't collide with workspace file keys or artifact keys. Verify restore creates workspace sync that matches Step 7's startup flow. Verify web app's resume flow correctly polls for new session provisioning. Verify conversation history loads from Workspace Service API matching Step 4's endpoints
- **Self-review**: Review for missing error handling on large workspace snapshots (timeout, partial copy), ensure snapshot cleanup doesn't delete active snapshots, verify restore works when original workspace has been deleted
- **Logical bug review**: Verify snapshot S3 copy handles large files (multipart copy for >5GB). Verify snapshot listing is sorted by creation time (newest first). Verify restore creates a new session linked to same workspace (not a new workspace). Verify conversation history is fetched from workspace-service using the OLD session ID (not new one). Verify snapshot auto-delete TTL doesn't delete snapshots for active sessions
- **Local run**: Test snapshot/restore flow against LocalStack: create workspace → upload files → create snapshot → list snapshots → restore → verify files present in new workspace. All via `curl` against local services
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

# Phase 3c — Scale

Prerequisite: Phase 3b complete and deployed.

---

## Step 16 — OIDC Authentication (session-service, web-app)

**Repos:** `cowork-session-service`, `cowork-web-app`

Replace simple auth with OIDC for production multi-tenant use.

### Work

1. Session Service:
   - Add OIDC token validation middleware (verify JWT signature, issuer, audience, expiry)
   - Extract `userId`, `tenantId` from JWT claims
   - Support multiple OIDC providers via configuration (list of issuer URLs + JWKS endpoints)
   - Cache JWKS keys with TTL (default 1 hour)
   - Reject requests with invalid/expired tokens → `401 Unauthorized`
2. Web app:
   - Add OIDC login flow using `oidc-client-ts`:
     - Redirect to OIDC provider
     - Handle callback, store tokens
     - Silent token renewal before expiry
     - Logout (clear tokens, redirect to provider logout)
   - Attach `Authorization: Bearer {token}` to all API calls
   - Handle 401 → redirect to login
3. Configuration:
   - `OIDC_ISSUER_URLS` — comma-separated list of trusted issuers
   - `OIDC_AUDIENCE` — expected audience claim
   - `OIDC_CLIENT_ID` — client ID for web app (public client, PKCE flow)

### Tests

- Unit: JWT validation (valid, expired, wrong issuer, wrong audience, malformed)
- Unit: JWKS cache hit and miss
- Unit: Claims extraction (userId, tenantId mapping)
- Unit: Web app login flow, token renewal, logout
- Integration: Full login → create session → verify ownership enforcement

### Definition of Done

- `make check` passes on both repos
- Web app redirects to OIDC provider on first visit
- Valid JWT required for all API calls
- Session ownership enforced via JWT claims
- Token renewal happens transparently
- Simple auth still works as fallback (configurable, for dev environments)
- **Wiring check**: Verify JWT claims extraction produces correct `userId`/`tenantId` that match session-service's existing field names. Verify proxy endpoints enforce ownership using JWT-derived userId. Verify web app attaches token to SSE connections (EventSource doesn't support headers — verify workaround via query param or cookie). Verify sandbox registration endpoint is excluded from OIDC validation (internal-only)
- **Self-review**: Review for missing token refresh edge cases (refresh fails during active session), ensure JWKS cache invalidation works when keys rotate, verify no sensitive data in JWT is logged, check that 401 responses don't leak internal details
- **Logical bug review**: Verify JWT validation checks `exp` claim BEFORE signature verification (fail fast on expired tokens). Verify JWKS cache doesn't serve stale keys indefinitely (TTL must be enforced). Verify `userId`/`tenantId` extraction handles missing claims gracefully (reject, don't default to empty string). Verify OIDC middleware doesn't apply to health/ready endpoints. Verify SSE connection token validation happens at connection time (not per-event)
- **Local run**: For local dev, OIDC is disabled by default (`AUTH_MODE=none`). Add `AUTH_MODE=simple` for API key auth (existing), `AUTH_MODE=oidc` for production OIDC. Document in `.env.example` and README
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 17 — EventBridge Lifecycle Manager (session-service, infra)

**Repos:** `cowork-session-service`, `cowork-infra`

Move idle timeout and provisioning timeout checks from in-process background tasks to EventBridge + Lambda for single-execution reliability at scale. The Lambda code lives in `cowork-session-service` alongside the existing lifecycle logic — same codebase, one set of tests, no drift.

### Work

1. Refactor `services/sandbox_lifecycle.py` in session-service:
   - Extract core lifecycle logic into a pure function: `check_and_terminate_idle_sessions(session_repo, task_repo, launcher, config) → list[TerminationResult]`
   - Keep `SandboxLifecycleManager` (background task) as a thin wrapper that calls the core function on a timer
   - Core function has no dependency on FastAPI, asyncio event loops, or app state — just repos and config
2. Create `lambda_handler/` directory in session-service:
   - `lambda_handler/__init__.py`
   - `lambda_handler/lifecycle.py` — Lambda entry point:
     - Instantiates DynamoDB repos and `EcsSandboxLauncher` from environment variables
     - Calls the same `check_and_terminate_idle_sessions()` core function
     - Returns structured result (sessions checked, terminated, errors)
   - `lambda_handler/requirements.txt` — subset of session-service dependencies (no FastAPI/uvicorn)
3. Add `make build-lambda` target to session-service Makefile:
   - Builds a Lambda deployment zip from `lambda_handler/` + shared modules (`services/`, `repositories/`, `clients/`)
   - Excludes FastAPI, uvicorn, test dependencies
4. Add feature flag: `SANDBOX_LIFECYCLE_MODE` = `in_process` (default) | `lambda`
   - `in_process`: existing background task runs (Phase 3a behavior)
   - `lambda`: background task is disabled, EventBridge invokes Lambda
5. Terraform (`cowork-infra`):
   - Lambda function definition (runtime Python 3.12, handler `lambda_handler.lifecycle.handler`)
   - EventBridge rule: trigger every 5 minutes
   - IAM role: DynamoDB read/write (`dev-sessions`, `dev-tasks`), ECS StopTask, CloudWatch Logs
   - S3 bucket for Lambda deployment artifact (or inline zip for small packages)
   - CloudWatch alarm on Lambda errors

### Tests

- Unit: Core lifecycle function with mocked repos and launcher (same tests as Step 8, but calling the extracted function directly)
- Unit: Lambda handler — verify it instantiates repos correctly from env vars and calls core function
- Unit: `make build-lambda` produces a valid zip with all required modules
- Integration: Lambda handler invoked locally against LocalStack DynamoDB — verify it terminates idle sessions

### Definition of Done

- `make check` passes on session-service (all existing + new tests)
- `make build-lambda` produces a deployable zip
- Lambda handler and in-process background task produce identical behavior (same core function)
- EventBridge rule triggers Lambda on schedule (verified in staging)
- Session Service background task can be disabled via `SANDBOX_LIFECYCLE_MODE=lambda`
- CloudWatch metrics on Lambda invocations and errors
- **Wiring check**: Verify Lambda imports the same repository classes and launcher as session-service (no copy-paste). Verify Lambda env vars match Terraform configuration (table names, cluster name). Verify feature flag transition doesn't create a gap (both Lambda and in-process running for a brief overlap is better than neither running). Verify Lambda deployment zip includes all transitive dependencies
- **Self-review**: Review for Lambda timeout configuration (must be long enough to process all idle sessions), ensure Lambda has correct IAM permissions for DynamoDB + ECS, verify error handling doesn't cause Lambda to retry on partial failures (use dead letter queue). Verify `make build-lambda` doesn't accidentally include test files or dev dependencies
- **Logical bug review**: Verify Lambda processes all sessions in a single invocation (paginate DynamoDB scan, don't stop at first page). Verify Lambda doesn't terminate sessions that were just created (race between creation and lifecycle check — check `createdAt` grace period). Verify feature flag transition doesn't create a gap (both Lambda and in-process running for a brief overlap is better than neither running). Verify the extracted core function doesn't hold references to async event loops or FastAPI app state (must be callable from sync Lambda context)
- **Local run**: Invoke the Lambda handler locally: `python -c "from lambda_handler.lifecycle import handler; handler({}, None)"` with `AWS_ENDPOINT_URL=http://localhost:4566`. Verify it queries LocalStack DynamoDB and processes sessions. No actual Lambda deployment needed for local testing
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 18 — Auto-Scaling Warm Pool (session-service, infra)

**Repos:** `cowork-session-service`, `cowork-infra`

Scale warm pool size based on usage patterns instead of fixed target.

### Work

1. Metrics-based scaling:
   - Track `sandbox.provision_requests` (counter) and `warm_pool.hit_rate` (percentage)
   - CloudWatch custom metrics published by Session Service
2. Scaling policy:
   - If hit rate < 80% for 15 minutes → shrink pool (reduce target by 20%)
   - If hit rate < 50% → shrink aggressively (reduce to min)
   - If cold starts > 5 in 10 minutes → expand pool (increase target by 50%)
   - Min pool size: 0 (off-hours), Max pool size: configurable per environment
3. Time-based scaling:
   - Schedule-based overrides via EventBridge (e.g. scale up at 8am, scale down at 8pm)
   - Weekend/holiday schedules
4. Terraform: CloudWatch alarms, EventBridge schedules, scaling config variables

### Tests

- Unit: Scaling policy decisions (hit rate → target size)
- Unit: Schedule-based overrides
- Integration: Publish metrics → verify scaling action taken

### Definition of Done

- Warm pool scales up on demand spikes (cold starts detected)
- Warm pool scales down during low usage (cost savings)
- Time-based schedules work for predictable patterns
- CloudWatch dashboard shows pool metrics
- **Wiring check**: Verify custom metrics published by session-service match CloudWatch alarm metric names exactly. Verify scaling actions call the same WarmPoolManager API from Step 13. Verify schedule-based scaling doesn't conflict with metrics-based scaling (priority rules)
- **Self-review**: Review for missing bounds checks (pool size never goes negative, never exceeds max), ensure scaling decisions are logged for debugging, verify dashboard queries match published metric dimensions
- **Logical bug review**: Verify scaling down doesn't drain containers that are in the process of being claimed (race condition). Verify hit rate calculation handles zero-request periods correctly (0/0 is not 0% — it's no data, don't scale down). Verify time-based schedule uses the correct timezone. Verify min pool size of 0 actually stops all containers (not leaves 1 running)
- **Local run**: Scaling logic is testable locally — mock CloudWatch metrics, verify scaling decisions. No actual CloudWatch or EventBridge needed for local testing
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

# Phase 3d — Polish

Prerequisite: Phase 3c complete and deployed.

---

## Step 19 — Enhanced File Management (web-app)

**Repo:** `cowork-web-app`

Improve the file browser from basic list to a full workspace explorer.

### Work

1. Tree view: hierarchical directory display with expand/collapse
2. Inline file viewer: syntax-highlighted code viewer for common languages
3. Inline editor: Monaco-based editor for quick edits (saves back to sandbox)
4. Drag-and-drop upload: drop files/folders onto file browser
5. Multi-file download: select multiple files → download as zip
6. File change indicators: show which files were modified by the agent (from `file_diff` artifacts)

### Tests

- Component: Tree view rendering with nested directories
- Component: File viewer with syntax highlighting
- Component: Editor save round-trip (edit → save → verify)
- Unit: Change indicator logic from artifact data

### Definition of Done

- `make check` passes
- File browser shows full directory tree
- Can view and edit files inline
- Drag-and-drop upload works
- Modified files are visually indicated
- **Wiring check**: Verify file list API response structure matches tree view component's expected format. Verify inline editor save calls the correct sandbox file write endpoint. Verify file change indicators correctly parse `file_diff` artifact data from workspace-service
- **Self-review**: Review for missing loading/error states in all file operations, ensure large file handling (don't load 10MB file into Monaco), verify drag-and-drop respects upload size limits from policy
- **Logical bug review**: Verify tree view handles symlinks and circular references (if present in workspace). Verify inline editor doesn't lose unsaved changes on SSE event (agent modifies same file). Verify multi-file download zip generation handles special characters in filenames. Verify file change indicators correctly match artifact `file_diff` paths to tree view paths (relative vs absolute)
- **Local run**: `make dev` with all backend services running locally. Upload files, browse tree, edit inline, download — all against LocalStack
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 20 — Virus Scanning for Uploads (workspace-service, infra)

**Repos:** `cowork-workspace-service`, `cowork-infra`

Scan uploaded files for malware before they enter the sandbox workspace.

### Work

1. Integrate ClamAV (or AWS-native solution like S3 Object Lambda + ClamAV layer):
   - S3 event notification on upload to `workspace-files/` prefix
   - Lambda function scans the file with ClamAV
   - Tag clean files as `scan-status: clean`, infected files as `scan-status: infected`
2. Workspace Service:
   - After upload, check scan status before making file available to sandbox
   - If infected, delete file and return `400` with `file_infected` error
   - If scan pending (async), return `202 Accepted` with scan status polling endpoint
3. Terraform:
   - Lambda function with ClamAV layer
   - S3 event notification configuration
   - IAM roles for Lambda → S3 access

### Tests

- Unit: Scan result handling (clean, infected, pending)
- Integration: Upload file → verify scan triggered → verify clean file accessible

### Definition of Done

- Uploaded files are scanned before sandbox can access them
- Infected files are rejected with clear error message
- Clean files are available within seconds of upload
- Scan infrastructure deployed via Terraform
- **Wiring check**: Verify S3 event notification triggers on correct prefix (`workspace-files/`). Verify Lambda scan result tags are read by workspace-service before serving files. Verify scan status polling endpoint is called by web app upload flow. Verify infected file deletion uses same S3 client patterns as workspace-service
- **Self-review**: Review for missing edge cases (scan timeout, Lambda cold start delay, file uploaded faster than scan completes), ensure scan doesn't block small file uploads excessively, verify Lambda has access to latest ClamAV definitions
- **Logical bug review**: Verify scan status check doesn't have TOCTOU race (file tagged clean, then replaced before sandbox reads it). Verify `202 Accepted` polling endpoint returns final status (not stuck in `pending` forever — add scan timeout). Verify infected file is deleted from S3 (not just tagged — sandbox must not be able to read it). Verify scan applies to all upload paths (direct workspace upload, workspace sync from agent)
- **Local run**: For local dev, virus scanning is disabled by default (`VIRUS_SCAN_ENABLED=false`). When enabled locally, use ClamAV Docker container instead of Lambda. Document in README
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

# Phase 3e — Advanced

Prerequisite: Phase 3d complete and deployed.

---

## Step 21 — GPU-Enabled Sandbox (infra, session-service)

**Repos:** `cowork-infra`, `cowork-session-service`

Support GPU instances for ML workloads (model training, data processing).

### Work

1. Terraform:
   - New ECS task definition with GPU resource requirements
   - GPU-capable instance type in ECS capacity provider (p3/g4/g5 instances)
   - Separate warm pool for GPU instances (expensive — small pool or on-demand only)
2. Session Service:
   - Accept `resourceProfile` in session creation: `standard` (default) or `gpu`
   - Select task definition and capacity provider based on profile
   - GPU session limits: lower concurrent limit (e.g. 1 per user)
3. Agent runtime:
   - No changes needed — same codebase, GPU is available as system resource
   - `ExecuteCode` tool can access GPU via CUDA (if available in container)
4. Policy:
   - New capability `Compute.GPU` — controlled by policy bundle
   - GPU sessions may have different cost/budget limits

### Tests

- Unit: Resource profile selection (standard vs GPU task definitions)
- Unit: GPU session limits (lower concurrent cap)
- Integration: Create GPU session, verify GPU is accessible in container

### Definition of Done

- GPU sandbox can be requested via session creation
- GPU is accessible inside the container (CUDA, PyTorch, etc.)
- Separate concurrency limits for GPU sessions
- Cost tracking per resource profile
- **Wiring check**: Verify GPU task definition is selected based on `resourceProfile` in session creation request. Verify GPU capacity provider has instances available. Verify policy bundle includes `Compute.GPU` capability for GPU sessions. Verify concurrent limit check distinguishes standard vs GPU sessions
- **Self-review**: Review for missing fallback when GPU instances are unavailable (queue? reject?), ensure GPU container image includes CUDA drivers, verify cost tracking metrics are published correctly
- **Logical bug review**: Verify `resourceProfile` is validated against allowed values (not arbitrary string). Verify GPU concurrent limit check is separate from standard limit (user can have 3 standard + 1 GPU, not 3 total). Verify GPU task definition uses correct capacity provider (not default Fargate — needs GPU instances). Verify session response includes `resourceProfile` so web app can show GPU indicator
- **Local run**: GPU is not available locally. For local dev, `resourceProfile=gpu` creates a standard session with a flag — test the selection logic, not the GPU hardware. Document in README
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

## Step 22 — Shared Workspace Across Sessions (workspace-service, session-service, web-app)

**Repos:** `cowork-workspace-service`, `cowork-session-service`, `cowork-web-app`

Allow multiple sessions to share a workspace — enabling iterative work across sessions and team collaboration.

### Work

1. Workspace Service:
   - Shared workspace type: multiple sessions can reference the same `workspaceId`
   - Workspace file locking (advisory): prevent concurrent writes to same file from different sessions
   - Workspace access control: list of authorized `userId`s per workspace
2. Session Service:
   - `POST /sessions` accepts existing `workspaceId` for `cloud` sessions (reuse workspace)
   - Validate user has access to the workspace
   - Multiple active sessions on same workspace: each gets its own sandbox, but S3 workspace files are shared
3. Sync conflict handling:
   - Last-write-wins for file sync (simple, same as git)
   - Conflict detection: if file changed in S3 since last sync, warn user before overwriting
4. Web app:
   - Workspace view: list sessions associated with a workspace
   - Share workspace: invite other users
   - Conflict resolution UI

### Tests

- Unit: Workspace access control (authorized user, unauthorized user)
- Unit: File locking (advisory lock acquire, release, timeout)
- Unit: Conflict detection (file changed since last sync)
- Integration: Two sessions on same workspace, verify file changes are visible

### Definition of Done

- Multiple sessions can use the same workspace
- Workspace files are shared via S3
- File conflicts are detected and surfaced to user
- Workspace access control enforced
- **Wiring check**: Verify workspace access control is checked on session creation (session-service), file operations (workspace-service), and proxy requests (session-service). Verify workspace sync in agent-runtime handles concurrent writes from other sessions. Verify web app workspace view correctly fetches sessions from session-service and files from workspace-service
- **Self-review**: Review for missing edge cases (session reads file while another session is writing), ensure advisory locks have TTL to prevent deadlocks, verify access control can't be bypassed via direct workspace-service calls, check that conflict resolution UI handles all conflict types
- **Logical bug review**: Verify workspace access control is checked on every file operation (not just workspace creation). Verify advisory lock TTL is shorter than session idle timeout (lock shouldn't outlive session). Verify conflict detection compares S3 ETag (not timestamp — clock skew). Verify workspace deletion is blocked when active sessions exist (don't delete workspace under a running session). Verify shared workspace file sync handles concurrent modifications (last-write-wins must be consistent, not data-corrupting)
- **Local run**: Test shared workspace flow locally with two agent-runtime instances on different ports, both pointing at same workspace. Upload file from one, verify visible from other. Document multi-instance local testing in README
- **Documentation**: Update CLAUDE.md, README.md, and design docs in `cowork-infra/docs/` for any changed behavior, new endpoints, new config options, or architectural changes introduced in this step

---

# Known Issues

Issues discovered during implementation that need to be addressed:

- **LLM uses ExecuteCode tool for knowledge questions**: Regression — the model calls `Code.Execute` tool even when answering from pretrained knowledge (e.g. "tell me how AWS ECS works"). The system prompt or tool descriptions in `cowork-agent-runtime` need to instruct the LLM to only use tools when the user's request requires taking an action, not for answering knowledge questions. Likely in `cowork-agent-runtime` system prompt or tool definition area. Investigate and fix.

---

# Full Dependency Graph

```
Phase 3a (MVP):
  Step 1 (Contracts) ──────────────────────────────────────────┐
  Step 2 (HttpTransport) ──→ Step 2b (Desktop Event Replay)    │
                           ──→ Step 7 (Sandbox Mode) ──→ Step 7b (Skills for Web) │
                                                       ──┐     │
  Step 3 (Registration) ──→ Step 5 (ECS) ──→ Step 6 (Proxy) ──┤
  Step 4 (Cloud Workspace) ─────────────────────────────────────┤
  Step 8 (Idle Timeout) ───────────────────────────────────────┤
                                                                ↓
  Step 9 (E2E Integration) ──→ Step 10 (Web App) ──→ Step 12 (Docker/CI)
  Step 11 (Terraform) ──────────────────────────────→ Step 12

Phase 3b (Optimization) — depends on Phase 3a:
  Step 13 (Warm Pool)
  Step 14 (Connection Draining)
  Step 15 (Snapshot/Restore)

Phase 3c (Scale) — depends on Phase 3b:
  Step 16 (OIDC Auth)
  Step 17 (EventBridge Lifecycle)
  Step 18 (Auto-Scaling Warm Pool) — depends on Step 13

Phase 3d (Polish) — depends on Phase 3c:
  Step 19 (Enhanced File Management)
  Step 20 (Virus Scanning)

Phase 3e (Advanced) — depends on Phase 3d:
  Step 21 (GPU Sandbox)
  Step 22 (Shared Workspace)
```
