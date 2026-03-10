# Web Execution — Implementation Plan

**Parent design:** [web-execution.md](web-execution.md)
**Repos touched:** `cowork-agent-runtime`, `cowork-session-service`, `cowork-workspace-service`, `cowork-web-app` (new), `cowork-platform`, `cowork-infra`

---

## Principles

- **Incremental delivery**: Each step produces a testable, working unit. No step depends on untested work from a prior step.
- **Tests from the start**: Every step includes unit tests. Integration tests added at integration boundaries.
- **Existing patterns**: Same project structure, error handling, logging, CI, and Makefile conventions as existing repos.
- **No desktop regression**: All agent-runtime changes are additive. Solo/desktop sessions must pass existing tests at every step.
- **Step numbers = execution order**: Steps are numbered in the order they should be implemented.

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

## Step 5 — ECS Integration (session-service)

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
2. New DynamoDB table `{env}-warm-pool` or reuse sessions table with a `POOL_IDLE` status:
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

---

## Step 17 — EventBridge Lifecycle Manager (session-service, infra)

**Repos:** `cowork-session-service`, `cowork-infra`

Move idle timeout and provisioning timeout checks from in-process background tasks to EventBridge + Lambda for single-execution reliability at scale.

### Work

1. Create Lambda function (`sandbox-lifecycle-checker`):
   - Same logic as `SandboxLifecycleManager` from Step 8
   - Query idle sessions, check for running tasks, terminate idle ones
   - Check provisioning timeouts, max duration
   - No conditional updates needed (single execution per interval)
2. EventBridge rule: trigger Lambda every 5 minutes
3. Remove background task from Session Service (feature flag to switch between in-process and Lambda)
4. Lambda shares the same DynamoDB/ECS client code as Session Service (extract to shared module or Lambda reads service config)
5. Terraform: Lambda function, EventBridge rule, IAM roles, CloudWatch alarm on Lambda errors

### Tests

- Unit: Lambda handler with mocked DynamoDB/ECS (same tests as Step 8, adapted)
- Integration: EventBridge triggers Lambda, Lambda terminates idle session

### Definition of Done

- EventBridge rule triggers Lambda on schedule
- Lambda correctly identifies and terminates idle/timed-out sessions
- Session Service background task can be disabled via config
- CloudWatch metrics on Lambda invocations and errors

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

---

# Full Dependency Graph

```
Phase 3a (MVP):
  Step 1 (Contracts) ──────────────────────────────────────────┐
  Step 2 (HttpTransport) ──→ Step 7 (Sandbox Mode) ──┐        │
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
