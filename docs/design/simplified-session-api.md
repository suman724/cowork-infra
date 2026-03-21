# Simplified Session API — Design Doc

**Status:** Proposed
**Scope:** Session Service, Agent Runtime, Platform Contracts, Web App, Desktop App
**Date:** 2026-03-21

---

## Problem

The current API exposes backend internals to frontend clients:

1. Sending a message requires 2 calls: `POST /tasks` (create record) + `POST /rpc` (JSON-RPC `StartTask`)
2. Frontend constructs JSON-RPC envelopes, generates task IDs, parses protocol responses
3. Frontend polls `GET /sessions/{id}` after session creation to detect sandbox readiness
4. SSE exposes 18+ internal event types — frontend uses ~6

## Goals

1. One API call per user action
2. No JSON-RPC or task ID management in frontend
3. No polling for sandbox readiness
4. Simplified event stream
5. Same logical contract for Web and Desktop
6. Backward compatible — existing endpoints stay for internal use

---

## Key Design Decision: Bundled First Task

The user's intent when creating a session is always "I want to start working on something." Rather than creating a session and then separately sending a message, **the first prompt is bundled with session creation.**

`POST /sessions` gains an optional `prompt` field. When present, Session Service creates the session, creates the task record, and includes the task in the SQS message. The sandbox picks up the message, registers, downloads workspace, and **immediately starts the task** — no second call, no polling, no SSE notification coordination.

This eliminates the need for:
- Frontend polling for `SANDBOX_READY`
- In-memory SSE waiter maps in Session Service (which don't scale across instances)
- A separate `POST /messages` call for the first message

For **subsequent messages** within the same session, `POST /sessions/{id}/messages` handles orchestration (task record + RPC dispatch) in one call.

---

## Architecture

The simplified API is a **shared contract** implemented in two places:

- **Web**: Session Service hosts HTTP endpoints
- **Desktop**: Electron main process hosts IPC handlers

This split exists because the cloud cannot reach the user's desktop machine — Session Service can proxy to ECS sandboxes but not to a local agent-runtime behind NAT/firewall.

### Component Diagram

```mermaid
flowchart TB
    subgraph Web
        WebUI["Web App (React)"]
        WebUI -->|"HTTP<br/>POST /sessions (with prompt)<br/>POST /sessions/{id}/messages<br/>GET /sessions/{id}/stream"| SS
    end

    subgraph Desktop
        Renderer["Desktop App (renderer)"]
        Main["Desktop App (main process)"]
        Renderer -->|"IPC<br/>session:create (with prompt)<br/>session:send-message<br/>session:events"| Main
        Main -->|"JSON-RPC stdio"| LocalAgent["Agent Runtime (local)"]
        Main -->|"HTTP"| SS
    end

    subgraph Cloud["AWS"]
        SS["Session Service"]
        SS -->|"SQS (with task)"| SQS["SQS Queue"]
        SQS -->|"poll"| CloudAgent["Agent Runtime (ECS)"]
        SS -->|"POST /rpc<br/>GET /events"| CloudAgent
        SS --- DB["DynamoDB"]
        SS --- WS["Workspace Service"]
    end
```

### Shared Contract

| Operation | Web (HTTP) | Desktop (IPC) | Request | Response |
|---|---|---|---|---|
| Create + first message | `POST /sessions` | `session:create` | `{ ..., prompt, taskOptions? }` | `{ sessionId, taskId? }` |
| Subsequent messages | `POST /sessions/{id}/messages` | `session:send-message` | `{ prompt, options? }` | `{ taskId }` |
| Cancel | `POST /sessions/{id}/cancel` | `session:cancel` | — | `{ cancelled, taskId? }` |
| Approve | `POST /sessions/{id}/approve` | `session:approve` | `{ approvalId, decision }` | `{ status }` |
| Event stream | `GET /sessions/{id}/stream` | `session:events` (IPC push) | — | Simplified events |

---

## Endpoint Changes

### POST /sessions (modified — optional prompt)

Creates a session. If `prompt` is provided, also creates a task record and includes it in the SQS dispatch. The sandbox auto-starts the task on pickup.

**Request (with prompt — typical):**
```json
{
    "tenantId": "t1",
    "userId": "u1",
    "executionEnvironment": "cloud_sandbox",
    "clientInfo": {},
    "supportedCapabilities": ["File.Read", "File.Write", "Shell.Exec"],
    "prompt": "Fix the authentication bug in login.py",
    "taskOptions": { "maxSteps": 50 }
}
```

**Request (without prompt — session only):**
```json
{
    "tenantId": "t1",
    "userId": "u1",
    "executionEnvironment": "cloud_sandbox",
    "clientInfo": {},
    "supportedCapabilities": ["File.Read", "File.Write", "Shell.Exec"]
}
```

**Response (201):**
```json
{
    "sessionId": "sess_123",
    "workspaceId": "ws_456",
    "status": "SANDBOX_PROVISIONING",
    "taskId": "task_789"
}
```

`taskId` is present only when `prompt` was provided.

**Internal flow (with prompt):**
1. Create session record in DynamoDB (`SANDBOX_PROVISIONING`)
2. Generate `taskId`, create task record in DynamoDB
3. Publish to SQS — message includes session config AND task info
4. Return `{ sessionId, taskId, status }`

**Internal flow (without prompt):**
Unchanged from today — creates session, publishes to SQS, returns.

### Registration status with bundled task

At registration time, Session Service knows whether the session has a bundled task (it created the task record in `POST /sessions`). The registration handler transitions to the appropriate status:

```python
if session_has_bundled_task:
    new_status = "SESSION_RUNNING"   # Task will auto-start immediately
else:
    new_status = "SANDBOX_READY"     # Waiting for POST /messages
```

This avoids the agent-runtime needing to call back to update status. The status is accurate — by the time registration + workspace download completes, the task is starting. If the auto-start fails, the agent-runtime reports the failure through the normal event stream (`task_failed`).

### SQS Message Schema (extended)

```json
{
    "sessionId": "sess_123",
    "registrationToken": "tok_abc",
    "sessionServiceUrl": "https://...",
    "workspaceServiceUrl": "https://...",
    "publishedAt": "2026-03-21T10:00:00Z",
    "task": {
        "taskId": "task_789",
        "prompt": "Fix the authentication bug in login.py",
        "maxSteps": 50
    }
}
```

`task` is `null` when no prompt was provided. The sandbox checks for it on startup.

### Sandbox Startup (modified)

After registration and workspace download, the sandbox checks for a bundled task:

```python
# In sandbox startup (after registration + workspace sync)
if sqs_config.task:
    # Auto-start the task — no RPC needed
    await session_manager.start_task({
        "taskId": sqs_config.task.task_id,
        "prompt": sqs_config.task.prompt,
        "taskOptions": {"maxSteps": sqs_config.task.max_steps},
    })
```

Events flow immediately through the agent-runtime's HTTP transport. The frontend connects to `/stream` and receives events as they happen.

---

## New Endpoints

### POST /sessions/{id}/messages

Send a subsequent message (after the first task completes). One call replaces `POST /tasks` + `POST /rpc StartTask`.

**Request:**
```json
{ "prompt": "Now add unit tests for the fix", "options": { "maxSteps": 50 } }
```

**Response (200):**
```json
{ "taskId": "task_abc", "status": "running" }
```

**Errors:** 404 (not found), 403 (not owner), 409 (not active or task already running), 502 (agent unreachable)

**Internal flow:**
1. Validate session is active and caller owns it
2. Proxy `GetSessionState` RPC to agent runtime — check if a task is running
3. If task running → return 409 immediately (no DynamoDB write)
4. Generate `taskId`, create task record in DynamoDB
5. Proxy `StartTask` JSON-RPC to agent runtime
6. Return `{ taskId, status }`

The state check (step 2) queries the agent-runtime directly — it's the source of truth for whether a task is running. This avoids writing a task record and then rolling it back if the agent rejects the start. The round-trip to the sandbox (~5-10ms on the same VPC) is cheaper than a DynamoDB write + rollback.

### POST /sessions/{id}/cancel

Cancel the running task, or cancel the session if no task is running.

**Response (200):**
```json
{ "cancelled": "task", "taskId": "task_abc" }
```

**Internal flow:**
1. If a task is running: proxy `CancelTask` RPC to agent runtime
2. If no task running: cancel the session

### POST /sessions/{id}/approve

Resolve a pending approval.

**Request:**
```json
{ "approvalId": "apr_1", "decision": "approve" }
```

**Response (200):**
```json
{ "approvalId": "apr_1", "status": "resolved" }
```

### GET /sessions/{id}/stream

Simplified SSE event stream. Maps internal agent events to frontend-friendly types.

**Query params:** `since={eventId}` for reconnect replay.

---

## Simplified Events

`/stream` maps 18+ internal events to 7 frontend types:

| Internal event | Simplified type | Payload |
|---|---|---|
| `text_chunk` | `message_chunk` | `{ content, taskId }` |
| `tool_requested` | `tool_started` | `{ toolName, toolCallId, taskId }` |
| `tool_completed` | `tool_completed` | `{ toolCallId, output, taskId }` |
| `approval_requested` | `approval_needed` | `{ approvalId, toolName, riskLevel }` |
| `task_completed` | `task_done` | `{ taskId, status: "completed" }` |
| `task_failed` | `task_done` | `{ taskId, status: "failed", error }` |
| `step_limit_approaching` | `warning` | `{ message }` |

Dropped: `step_started`, `step_completed`, `llm_request_started`, `llm_request_completed`, `checkpoint_saved`, `verification_started`, `verification_completed`, `context_compacted`.

Raw `GET /sessions/{id}/events` remains available for debugging.

### Shared event mapping contract

The event mapping is implemented in two places — Session Service (Python, for web `/stream`) and Desktop main process (TypeScript, for IPC events). To prevent drift, the mapping table lives in `cowork-platform` as the source of truth:

```
cowork-platform/contracts/enums/simplified-event-mapping.json
```

Both implementations reference this file. CI validates that the mapping is consistent. If a new internal event type is added, the mapping file determines whether it's exposed to frontends or dropped.

---

## How Each BFF Works Internally

| Step | Web BFF (Session Service) | Desktop BFF (Main Process) |
|---|---|---|
| **Create + first message** | Session + task record in DynamoDB → SQS with task → return | Session via agent-runtime stdio → task record via Session Service HTTP → return |
| **Subsequent messages** | Generate taskId → DynamoDB task record → proxy `StartTask` RPC | Generate taskId → `StartTask` JSON-RPC via stdio → task record via HTTP |
| **Cancel** | Proxy `CancelTask` RPC to sandbox | `CancelTask` JSON-RPC via stdio |
| **Approve** | Proxy `ApproveAction` RPC to sandbox | `ApproveAction` JSON-RPC via stdio |
| **Events** | Proxy agent SSE → map events → push to client SSE | Receive stdio notifications → map events → push to renderer via IPC |

---

## Web Session Lifecycle

```mermaid
sequenceDiagram
    participant Web as Web App
    participant SS as Session Service
    participant SQS as SQS
    participant Agent as Agent Runtime (ECS)

    Web->>SS: POST /sessions { prompt: "Fix the bug", ... }
    SS->>SS: Create session + task records
    SS->>SQS: Publish { sessionId, task: { taskId, prompt } }
    SS-->>Web: 201 { sessionId, taskId }

    Web->>SS: GET /sessions/{id}/stream (SSE)
    Note over SS: Sandbox not ready yet.<br/>SSE waits for proxy target.

    Agent->>SQS: ReceiveMessage
    Agent->>SS: POST /sessions/{id}/register
    SS->>SS: Has bundled task → status = SESSION_RUNNING
    Agent->>Agent: download_workspace()
    Agent->>Agent: auto-start task from SQS message

    Note over SS: Sandbox registered (SESSION_RUNNING).<br/>Start proxying agent SSE.

    SS-->>Web: SSE: { type: "message_chunk", content: "I'll fix..." }
    SS-->>Web: SSE: { type: "tool_started", toolName: "WriteFile" }
    SS-->>Web: SSE: { type: "tool_completed", output: "Done" }
    SS-->>Web: SSE: { type: "task_done", status: "completed" }

    Note over Web: User sends follow-up message
    Web->>SS: POST /sessions/{id}/messages { prompt: "Add tests" }
    SS-->>Web: 200 { taskId: "task_2" }

    SS-->>Web: SSE: { type: "message_chunk", content: "Adding tests..." }
    SS-->>Web: SSE: { type: "task_done", status: "completed" }
```

## Desktop Session Lifecycle

```mermaid
sequenceDiagram
    participant UI as Desktop (renderer)
    participant Main as Desktop (main process)
    participant Agent as Agent Runtime (stdio)
    participant SS as Session Service (cloud)

    Main->>Agent: Spawn process (stdio)

    UI->>Main: IPC: session:create { prompt: "Fix the bug" }
    Main->>Agent: JSON-RPC: CreateSession
    Main->>Main: Generate taskId
    Main->>Agent: JSON-RPC: StartTask { taskId, prompt }
    Main->>SS: POST /sessions + POST /tasks (background)
    Main-->>UI: { sessionId, taskId }

    Agent-->>Main: stdio: text_chunk
    Main-->>UI: IPC push: { type: "message_chunk", content: "I'll fix..." }
    Agent-->>Main: stdio: task_completed
    Main-->>UI: IPC push: { type: "task_done", status: "completed" }

    UI->>Main: IPC: session:send-message { prompt: "Add tests" }
    Main->>Main: Generate taskId
    Main->>Agent: JSON-RPC: StartTask { taskId, prompt }
    Main->>SS: POST /tasks (background)
    Main-->>UI: { taskId }
```

## Approval Flow

```mermaid
sequenceDiagram
    participant App as Web or Desktop
    participant BFF as BFF (Session Service or Main Process)
    participant Agent as Agent Runtime

    Agent-->>BFF: approval_requested
    BFF-->>App: { type: "approval_needed", approvalId: "apr_1", toolName: "RunCommand" }

    App->>BFF: approve { approvalId: "apr_1", decision: "approve" }
    BFF->>Agent: ApproveAction RPC
    BFF-->>App: { status: "resolved" }

    Agent-->>BFF: tool_completed
    BFF-->>App: { type: "tool_completed", output: "..." }
```

---

## What Changes in Agent Runtime

The SQS consumer and sandbox startup gain awareness of the bundled task:

**SQS message parsing** — `SqsSessionConfig` gets an optional `task` field:
```python
@dataclass(frozen=True)
class SqsTaskConfig:
    task_id: str
    prompt: str
    max_steps: int = 50

@dataclass(frozen=True)
class SqsSessionConfig:
    session_id: str
    registration_token: str
    session_service_url: str
    workspace_service_url: str
    receipt_handle: str
    task: SqsTaskConfig | None = None  # Bundled first task
```

**Sandbox startup** — after registration and workspace sync, auto-start the task:
```python
# In main.py run_http(), after init_from_registration():
if sqs_config.task:
    logger.info("auto_starting_task", task_id=sqs_config.task.task_id)
    await session_manager.start_task({
        "taskId": sqs_config.task.task_id,
        "prompt": sqs_config.task.prompt,
        "taskOptions": {"maxSteps": sqs_config.task.max_steps},
    })
```

---

## SSE `/stream` During Provisioning

When the frontend connects to `/stream` while the sandbox is still provisioning, the SSE connection opens but no events flow yet. The `/stream` endpoint:

1. Checks session status
2. If `SANDBOX_PROVISIONING` or `SANDBOX_READY` with no sandbox endpoint yet — holds the connection open
3. Periodically retries resolving the sandbox endpoint (every 2s, from DynamoDB cache)
4. Once sandbox is registered — starts proxying agent SSE events
5. Events from the auto-started task arrive immediately (the sandbox started working as soon as it registered)

This is a lightweight retry on the proxy resolution, not a notification system. The retry loop is bounded by the session's provisioning timeout (180s). If the sandbox never registers, the SSE connection returns an error event and closes.

The frontend sees: open SSE connection → brief wait → events start flowing. No separate status polling or notification coordination needed.

---

## Desktop App Impact

These changes are web-focused. Desktop is unaffected in Phases 1-2:

| Change | Desktop impact |
|---|---|
| `POST /sessions` with prompt | None — desktop uses agent-runtime stdio |
| `POST /sessions/{id}/messages` | None — Stage 3 IPC equivalent |
| `/cancel`, `/approve` | None — Stage 3 IPC equivalent |
| `/stream` event mapping | **Shared contract needed** — mapping logic in `cowork-platform` prevents drift between Python (Session Service) and TypeScript (desktop main process) |
| Registration status for bundled tasks | None — desktop doesn't use SQS |
| SQS task bundling | None — desktop doesn't use SQS |

Desktop gains value in **Stage 3** when IPC handlers are refactored to the simplified contract. Until then, desktop continues working exactly as today.

---

## Migration Path

### Stage 1: Session Service + Agent Runtime

- Add optional `prompt`/`taskOptions` to `POST /sessions` — creates task record, includes in SQS
- Add `/messages`, `/cancel`, `/approve` endpoints (orchestrate task + RPC)
- Add `/stream` endpoint (event mapping + proxy retry during provisioning)
- Agent runtime: parse `task` from SQS message, auto-start after registration
- Platform: update schemas

### Stage 2: Web App

- Use `POST /sessions` with prompt for first message
- Use `POST /messages` for follow-ups
- Use `GET /stream` for events
- Remove JSON-RPC, task ID generation, polling

### Stage 3: Desktop App

- Refactor IPC handlers to match shared contract
- Event mapping in main process (stdio notifications → simplified types)
- Extract shared `SessionClient` TypeScript interface

### Stage 4: Cleanup

- Mark `/rpc` and `/events` as internal
- Remove `X-User-Id` header (OIDC auth)

---

## Repos Affected

| Repo | Changes | Phase |
|---|---|---|
| `cowork-session-service` | `POST /sessions` with prompt, `/messages`, `/cancel`, `/approve`, `/stream`, event mapper | 1 |
| `cowork-agent-runtime` | SQS consumer parses `task` field, auto-start task after registration | 1 |
| `cowork-platform` | Simplified event types, updated session creation schema, `/messages` schema | 1 |
| `cowork-web-app` | New API client, remove JSON-RPC/polling, use `/stream` | 2 |
| `cowork-desktop-app` | Refactor IPC handlers, event mapping, shared SessionClient | 3 |

---

## Open Questions

| # | Question |
|---|---|
| 1 | Should `/stream` replay conversation history on connect (so frontend renders without separate fetch)? |
| 2 | Should `/cancel` be two separate endpoints for task vs session, or auto-detect? |
| 3 | Should `/stream` support `?detail=full` to return raw unfiltered events? |
| 4 | For resumed sessions: should `POST /sessions/{id}/resume` also accept a `prompt` to bundle the next task? |
