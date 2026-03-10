# Web Execution — Implementation Plan

**Parent design:** [web-execution.md](web-execution.md)
**Phase:** 3a (MVP)
**Repos touched:** `cowork-agent-runtime`, `cowork-session-service`, `cowork-workspace-service`, `cowork-web-app` (new), `cowork-platform`, `cowork-infra`

---

## Principles

- **Incremental delivery**: Each step produces a testable, working unit. No step depends on untested work from a prior step.
- **Tests from the start**: Every step includes unit tests. Integration tests added at integration boundaries.
- **Existing patterns**: Same project structure, error handling, logging, CI, and Makefile conventions as existing repos.
- **No desktop regression**: All agent-runtime changes are additive. Solo/desktop sessions must pass existing tests at every step.

---

## Step 1 — Transport Protocol and HttpTransport (agent-runtime)

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

---

## Step 2 — Sandbox Self-Registration Endpoint (session-service)

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

---

## Step 3 — ECS Integration (session-service)

**Repo:** `cowork-session-service`

Add ECS client to launch Fargate tasks when creating `cloud_sandbox` sessions.

### Work

1. Create `clients/ecs_client.py`:
   - `run_task(session_id, config) → task_arn` — calls ECS `RunTask` with session-specific overrides (env vars, security group)
   - `stop_task(task_arn)` — calls ECS `StopTask`
   - Error handling: catch `ClientError`, raise `SandboxProvisionError`
2. Create `services/sandbox_service.py`:
   - `provision_sandbox(session)` — calls ECS client, stores `expected_task_arn` on session record
   - `terminate_sandbox(session)` — sends shutdown to sandbox endpoint (best-effort), calls `stop_task`, updates status with conditional write
3. Update `POST /sessions` handler: after creating session record, call `sandbox_service.provision_sandbox()`. If RunTask fails, transition to `SESSION_FAILED`.
4. Add `aioboto3` dependency for async ECS calls
5. Add config: `ecs_cluster`, `ecs_task_definition`, `ecs_subnets`, `ecs_security_groups`, `sandbox_image`
6. Concurrent session limit: query active sandbox sessions for user before provisioning, reject with 409 if over limit

### Tests

- Unit: `SandboxService` with mocked ECS client — provision success, provision failure, terminate
- Unit: Concurrent session limit enforcement (at limit → 409, under limit → allowed)
- Unit: RunTask failure → session transitions to SESSION_FAILED
- Service: Full session creation flow with mocked ECS (DynamoDB Local for session persistence)

### Definition of Done

- `make check` passes
- Creating a `cloud_sandbox` session stores `expected_task_arn` and sets status to `SANDBOX_PROVISIONING`
- RunTask failure results in `SESSION_FAILED` with structured error
- Concurrent session limit rejects excess sessions with 409

---

## Step 4 — Proxy Layer (session-service)

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

---

## Step 5 — Cloud Workspace Support (workspace-service)

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

### Tests

- Unit: Cloud workspace creation, file upload/download/list/delete (InMemory stores)
- Service: DynamoDB repo with new field
- Integration: Full flow with LocalStack (S3 + DynamoDB)

### Definition of Done

- `make check` passes
- Can create a `cloud` workspace, upload files, list them, download them, delete them
- Workspace deletion cleans up both artifacts and workspace files
- `local` and `general` workspace behavior unchanged

---

## Step 6 — Idle Timeout and Provisioning Timeout (session-service)

**Repo:** `cowork-session-service`

Add background task for idle timeout enforcement and provisioning timeout cleanup.

### Work

1. Create `services/sandbox_lifecycle.py`:
   - `SandboxLifecycleManager` — started as a background task on app startup
   - `check_idle_sessions()` — query active sandbox sessions, check `lastActivityAt` against timeout, terminate idle ones with conditional DynamoDB update
   - `check_provisioning_timeouts()` — query `SANDBOX_PROVISIONING` sessions older than 120s, transition to `SESSION_FAILED`
   - Both use conditional updates for multi-instance safety
2. Register lifecycle manager in FastAPI lifespan (start on startup, cancel on shutdown)
3. Add config: `sandbox_idle_timeout_seconds` (default 1800), `sandbox_max_duration_seconds` (default 14400), `sandbox_provision_timeout_seconds` (default 120), `sandbox_lifecycle_check_interval_seconds` (default 300)
4. Max duration enforcement: check `created_at + maxDuration < now` for active sandbox sessions

### Tests

- Unit: Idle timeout detection (mock clock, mock repo)
- Unit: Provisioning timeout detection
- Unit: Max duration enforcement
- Unit: Conditional update conflict handling (simulated concurrent instance)
- Unit: Lifecycle manager start/stop lifecycle

### Definition of Done

- `make check` passes
- Idle sessions are terminated after configured timeout
- Stuck provisioning sessions are cleaned up after 120s
- Max duration sessions are terminated
- Multiple lifecycle managers running concurrently don't cause errors (conditional updates)

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

### Tests

- Unit: Sandbox startup with mocked HTTP (registration success, registration failure)
- Unit: Workspace sync (mock S3 operations)
- Unit: Graceful shutdown sequence
- Unit: SIGTERM handling
- Integration: Full sandbox startup → register → serve → shutdown flow (with mocked Session Service)

### Definition of Done

- `make check` passes (all existing tests + new tests)
- Agent runtime in HTTP mode reads session ID, registers with Session Service, syncs workspace, serves HTTP
- SIGTERM triggers graceful shutdown with workspace sync
- Stdio mode is completely unaffected

---

## Step 8 — Platform Contracts (cowork-platform)

**Repo:** `cowork-platform`

Add schemas and SDK helpers for web execution.

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

---

## Step 9 — End-to-End Integration Test

**Repos:** `cowork-agent-runtime`, `cowork-session-service`, `cowork-workspace-service`

Verify the full sandbox lifecycle works across services.

### Work

1. Create integration test script (similar to `test-chat.py` for desktop):
   - `POST /sessions` with `cloud_sandbox` → verify `SANDBOX_PROVISIONING`
   - Mock/start sandbox container → `POST /register` → verify `SANDBOX_READY`
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

- Integration: Full lifecycle with DynamoDB Local + LocalStack + real agent-runtime process

### Definition of Done

- Full sandbox lifecycle runs end-to-end in CI (with LocalStack)
- Reconnect replays missed events correctly
- File upload/download works through proxy
- Idle timeout and provisioning timeout tested

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

---

## Dependency Graph

```
Step 1 (HttpTransport)
  ↓
Step 2 (Registration) ──→ Step 3 (ECS Integration) ──→ Step 4 (Proxy)
  ↓                                                        ↓
Step 7 (Sandbox Mode) ←─────────────────────────────── Step 6 (Idle Timeout)
  ↓                                                        ↓
Step 8 (Contracts) ────→ Step 9 (E2E Integration) ←── Step 5 (Cloud Workspace)
  ↓
Step 10 (Web App)
  ↓
Step 11 (Terraform) ──→ Step 12 (Docker/CI)
```

**Parallelizable work:**
- Steps 1, 2, 5, 8 can start in parallel (no dependencies between them)
- Step 10 (web app) can start after Step 8 (contracts) and progress in parallel with Steps 3, 4, 6, 7
- Step 11 (Terraform) can start any time (no code dependency)

---

## Implementation Order (Recommended)

| Order | Step | Repo | Rationale |
|-------|------|------|-----------|
| 1 | Step 8 — Contracts | cowork-platform | Unblocks all repos — types needed everywhere |
| 2 | Step 1 — HttpTransport | cowork-agent-runtime | Core transport layer, most complex new code |
| 3 | Step 2 — Registration | cowork-session-service | Foundation for all sandbox lifecycle |
| 4 | Step 5 — Cloud Workspace | cowork-workspace-service | Independent, needed for file flows |
| 5 | Step 3 — ECS Integration | cowork-session-service | Builds on registration |
| 6 | Step 4 — Proxy Layer | cowork-session-service | Builds on ECS integration |
| 7 | Step 7 — Sandbox Mode | cowork-agent-runtime | Builds on HttpTransport + registration |
| 8 | Step 6 — Idle Timeout | cowork-session-service | Builds on ECS integration |
| 9 | Step 9 — E2E Integration | all | Validates everything works together |
| 10 | Step 10 — Web App | cowork-web-app | Can start earlier, but full testing needs Steps 1–7 |
| 11 | Step 11 — Terraform | cowork-infra | Can start any time, needed for deploy |
| 12 | Step 12 — Docker/CI | agent-runtime, infra | Final step before deploy |
