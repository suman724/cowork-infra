# Desktop App — Component Design

**Repo:** `cowork-desktop-app` (`app/` and `updater/` packages)
**Bounded Context:** AgentExecution (UI)
**Phase:** 1 (MVP)
**Covers:** Desktop App, Local Approval UI

---

The Desktop App is the user-facing application for Windows and macOS. It provides the conversation interface, renders approval dialogs, previews file changes, and manages the `cowork-agent-runtime` lifecycle. It communicates with the Local Agent Host exclusively via JSON-RPC 2.0 — it never imports agent-runtime code directly.

This document describes the internal design of the `cowork-desktop-app/` repo. For the agent loop, see [local-agent-host.md](local-agent-host.md). For tool execution, see [local-tool-runtime.md](local-tool-runtime.md).

**Prerequisites:** [architecture.md](../architecture.md) (architecture, protocol contracts), [domain-model.md](../domain-model.md) (session, task, workspace concepts)

---

## 1. Overview

### What this component does

- Presents the conversation UI — message list, prompt input, streaming assistant responses
- Manages the agent-runtime process — spawn, monitor, restart, shutdown
- Sends JSON-RPC requests to the Local Agent Host and handles responses and notifications
- Renders the Local Approval UI — approval dialogs for risky tool actions
- Provides patch preview — shows pending file changes before and after agent actions
- Fetches and displays conversation history from the Workspace Service
- Downloads and manages agent-runtime versions (Phase 4 — bundled in Phase 1)

### What this component does NOT do

- Run the agent loop — that is the Local Agent Host
- Execute tools — that is the Local Tool Runtime
- Enforce policy — that is the Local Policy Enforcer
- Store canonical history — that is the Workspace Service
- Make LLM calls — that is the Local Agent Host via the LLM Gateway

### Key constraints

- **No direct imports from `cowork-agent-runtime`** — all communication is via JSON-RPC over stdio or local socket
- **Depends only on `cowork-platform`** — for JSON-RPC method names, error codes, and event types
- **Cross-platform** — must work on macOS and Windows with the same codebase

### Component Context

```mermaid
flowchart LR
  User["User"]
  DA["Desktop App"]
  AH["Local Agent Host<br/><small>JSON-RPC 2.0<br/>stdio / local socket</small>"]
  WS["Workspace Service<br/><small>HTTPS REST</small>"]
  Manifest["Version Manifest<br/><small>HTTPS (Phase 4)</small>"]

  User <--> DA
  DA <--> AH
  DA <--> WS
  DA -.-> Manifest
```

The Desktop App has two external communication paths:
1. **Local Agent Host** — JSON-RPC 2.0 for session and task control during active sessions
2. **Workspace Service** — HTTPS REST for fetching conversation history when browsing past sessions

---

## 2. Internal Module Structure

### Package layout

```
src/
  main/               — Electron main process
    index.ts          — App entry point, window lifecycle
    ipc-handlers.ts   — IPC channel handlers (main ↔ renderer bridge)
    agent-runtime.ts  — Agent-runtime process spawning, health monitoring
    json-rpc-client.ts — JSON-RPC 2.0 client for agent-runtime communication
    session-client.ts — Session Service HTTP client
    workspace-client.ts — Workspace Service HTTP client
    settings-store.ts — Persistent user preferences (electron-store)
    preload.ts        — Context bridge (secure IPC exposure to renderer)
  renderer/           — React UI (Vite-bundled)
    views/
      conversation/   — Active conversation view (message list, prompt input, streaming)
      home/           — Home/landing view (project list, recent sessions)
      approval/       — Local Approval UI (approval dialogs, risk display)
      patch/          — Patch preview (file diff viewer, before/after)
      settings/       — User preferences, connection settings
    components/       — Shared React components
    hooks/            — React hooks (session state, events, IPC)
    state/            — Application state management (Zustand stores)
    lib/              — Utility functions
  shared/             — Cross-process types
    ipc-channels.ts   — IPC channel name constants and type definitions
    types.ts          — Shared TypeScript types (main ↔ renderer)
```

### Module dependencies

```mermaid
flowchart TD
  main["main/<br/><small>Electron main process<br/>window lifecycle</small>"]
  agentRuntime["main/agent-runtime<br/><small>process spawn<br/>health monitor</small>"]
  jsonRpc["main/json-rpc-client<br/><small>JSON-RPC 2.0</small>"]
  sessionClient["main/session-client<br/><small>Session Service</small>"]
  workspaceClient["main/workspace-client<br/><small>Workspace Service</small>"]
  ipcHandlers["main/ipc-handlers<br/><small>IPC bridge</small>"]

  conversation["views/conversation/<br/><small>message list<br/>prompt input</small>"]
  home["views/home/<br/><small>project list<br/>recent sessions</small>"]
  approval["views/approval/<br/><small>approval dialogs</small>"]
  patch["views/patch/<br/><small>diff viewer</small>"]
  settings["views/settings/<br/><small>preferences</small>"]
  hooks["hooks/<br/><small>React hooks</small>"]
  state["state/<br/><small>Zustand stores</small>"]

  main --> agentRuntime
  main --> ipcHandlers
  agentRuntime --> jsonRpc
  ipcHandlers --> jsonRpc
  ipcHandlers --> sessionClient
  ipcHandlers --> workspaceClient
  conversation --> hooks
  home --> hooks
  approval --> hooks
  hooks --> state
```

**Dependency rules:**
- `main/` is the Electron main process entry point — it manages windows, spawns agent-runtime, and bridges IPC
- `main/ipc-handlers` exposes backend functionality to the renderer via Electron's context bridge
- All renderer views use `hooks/` for data access, which reads from `state/` (Zustand stores)
- Views never call JSON-RPC or HTTP directly — all communication flows through IPC handlers in the main process
- `main/agent-runtime` manages the agent-runtime child process and provides the JSON-RPC connection

---

## 3. Application Lifecycle

### 3.1 Startup Sequence

```mermaid
sequenceDiagram
  participant User
  participant Main as Main Process
  participant AR as agent-runtime.ts
  participant AH as Local Agent Host
  participant WS as Workspace Service

  User->>Main: Launch Desktop App
  Main->>Main: Show main window (home view)
  User->>Main: Open project or start new chat
  Main->>AR: Spawn agent-runtime process
  AR->>AH: Start process (stdio)
  AR-->>Main: JSON-RPC connection established
  Main->>Main: Switch to conversation view
```

**Phase 1:** The agent-runtime binary is bundled in the desktop installer. `agent-runtime.ts` locates and spawns it.

**Phase 4:** A separate updater module checks the version manifest, downloads if needed, verifies integrity, then spawns.

### 3.2 Shutdown Sequence

1. User closes the conversation or exits the app
2. Desktop App sends `Shutdown` JSON-RPC request to Local Agent Host
3. Wait for clean shutdown confirmation (Local Agent Host uploads history, cleans state store)
4. If no response within 10 seconds, terminate the agent-runtime process
5. Close the application window

### 3.3 Crash Recovery

If the agent-runtime process exits unexpectedly:

1. Updater detects child process exit
2. Notify the user: "The agent process exited unexpectedly"
3. Offer options:
   - **Resume** — respawn agent-runtime, send `ResumeSession` (uses checkpoint from Local State Store)
   - **Start fresh** — respawn agent-runtime, create a new session (history is in Workspace Service from the last completed task)
   - **Close** — return to history view

---

## 4. Views

### 4.1 Conversation View

The primary view during an active session. Shows the live conversation and agent activity.

**Layout:**

```
┌─────────────────────────────────────────────┐
│  [Project name / General chat]    [Settings] │
├─────────────────────────────────────────────┤
│                                             │
│  [System] Agent initialized for project...  │
│                                             │
│  [User] Refactor the API client and add     │
│         tests                               │
│                                             │
│  [Assistant] I'll start by reading the      │
│  current API client...                      │
│    ┌─ Tool: ReadFile ──────────────────┐    │
│    │ /src/api/client.ts                │    │
│    │ ✓ Completed                       │    │
│    └───────────────────────────────────┘    │
│    ┌─ Tool: WriteFile ─────────────────┐    │
│    │ /src/api/client.ts                │    │
│    │ ⏳ Awaiting approval...           │    │
│    └───────────────────────────────────┘    │
│                                             │
├─────────────────────────────────────────────┤
│  [Step 3/40]              [Cancel task]     │
├─────────────────────────────────────────────┤
│  > Type your message...          [Send]     │
└─────────────────────────────────────────────┘
```

**Behavior:**

| Element | Source | Interaction |
|---------|--------|-------------|
| Message list | `state/` — accumulated from `SessionEvent` notifications | Scroll, select to copy |
| Streaming text | `SessionEvent` with `eventType: "text_chunk"` | Renders incrementally as chunks arrive |
| Tool call cards | `SessionEvent` with `eventType: "tool_requested"` / `"tool_completed"` | Shows category icon, tool name, category badge, status badge, collapsible arguments, and live result output. Categories: File (`FileText`, blue), Shell (`Terminal`, amber), Network (`Globe`, purple), Agent (`Brain`, slate), Sub-Agent (`GitFork`, indigo), Skill (`Sparkles`, emerald). Category resolved from `toolType` field first, then inferred from `toolName` for backward compat. |
| Step counter | `SessionEvent` with `eventType: "step_started"` | Shows `stepCount / maxSteps` |
| Step limit warning | `SessionEvent` with `eventType: "step_limit_approaching"` | Highlighted counter when 80% reached |
| System messages | `SessionEvent` errors/warnings/info | Severity-aware rendering: error (red AlertCircle), warning (yellow AlertTriangle), info (muted Info icon) |
| Retry button | `task_failed` event with `isRecoverable: true` | Appears in footer when task is not running; re-submits the same prompt via `StartTask`. Cleared on new task start. |
| LLM retry indicator | `SessionEvent` with `eventType: "llm_retry"` | Warning system message showing retry attempt count |
| Plan mode badge | `SessionEvent` with `eventType: "plan_mode_changed"` | Blue "Planning" badge in header when `planMode: true`; info system message on enter/exit. "Working" badge hidden during plan mode. |
| Plan panel | `SessionEvent` with `eventType: "plan_updated"` | Collapsible panel between header and message list showing plan goal, progress counter [completed/total], and step list with status icons (spinner=in_progress, check=completed, ban=skipped, circle=pending). Skipped steps shown with strikethrough. Auto-collapses at 7+ steps. |
| Verification badge | `SessionEvent` with `eventType: "verification_started"` / `"verification_completed"` | Amber pulsing "Verifying" badge in header during verification; info/warning system message on start/complete. Footer shows "· Verifying" label. |
| Prompt input | User types and submits | Sends `StartTask` JSON-RPC. Includes a "Plan first" toggle (checklist icon) that sends `taskOptions.planOnly: true` to lock the agent into read-only plan mode for the task. |
| Cancel button | User clicks | Sends `CancelTask` JSON-RPC |

**Markdown Rendering:**

Assistant messages are rendered with full markdown formatting using `react-markdown` with `remark-gfm` (GitHub Flavored Markdown: tables, strikethrough, task lists) and `rehype-highlight` (syntax-highlighted code blocks via highlight.js). Custom component overrides provide:
- Code blocks with dark background, language label header, and copy-to-clipboard button
- Inline code with muted background
- External links with `target="_blank"`
- Streaming cursor (blinking bar) appended while response is streaming

User messages are rendered as plain text in right-aligned chat bubbles.

### 4.2 History View

The landing page. Shows past conversations grouped by workspace.

**Layout:**

```
┌─────────────────────────────────────────────┐
│  Conversations                  [New chat]  │
├──────────────────┬──────────────────────────┤
│  Projects        │  Sessions                │
│                  │                          │
│  > demo/         │  Feb 21 — Refactor API   │
│    my-app/       │  Feb 20 — Add auth       │
│    website/      │  Feb 18 — Fix bug #42    │
│                  │                          │
│  General chats   │                          │
│    Feb 22 chat   │                          │
│    Feb 19 chat   │                          │
└──────────────────┴──────────────────────────┘
```

**Data source:** Workspace Service

| Data | API call |
|------|----------|
| Workspace list | `GET /workspaces?tenantId={tenantId}&userId={userId}` (via workspace client) |
| Sessions per workspace | `GET /workspaces/{workspaceId}/sessions` |
| Session messages | `GET /workspaces/{workspaceId}/artifacts/{artifactId}` (the `session_history` artifact) |

**Interactions:**
- **Select a project** → shows sessions for that workspace
- **Select a session** → loads `session_history` from Workspace Service and displays in read-only conversation view
- **Continue session** → creates a new session under the same workspace, bootstraps thread from `session_history`
- **New chat** → creates a new `general`-scoped session
- **Open project** → OS file picker to select a project directory → creates/resolves a `local`-scoped workspace

### 4.3 Approval View (Local Approval UI)

A modal dialog shown when the agent requests approval for a risky action.

**Layout:**

```
┌─────────────────────────────────────────────┐
│  ⚠ Approval Required                       │
│                                             │
│  Local command execution                    │
│                                             │
│  The agent wants to run:                    │
│  ┌─────────────────────────────────────┐    │
│  │ pytest tests/ --verbose             │    │
│  │ Working directory: ~/projects/demo  │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  Risk level: ● Medium                       │
│                                             │
│  [Deny]                        [Approve]    │
│                                             │
│  Reason (optional): ___________________     │
└─────────────────────────────────────────────┘
```

**Trigger:** `SessionEvent` with `eventType: "approval_requested"` containing the `ApprovalRequest` payload.

**Behavior:**
1. Parse the `ApprovalRequest` from the event payload
2. Display the modal with title, action summary, risk level, and details
3. Risk level indicator: `Low` (green), `Medium` (amber), `High` (red)
4. Wait for user to click Approve or Deny
5. Send `ApproveAction` JSON-RPC request with `approvalId`, `decision`, and optional `reason`
6. Close the modal and resume conversation view

**Edge cases:**
- **Multiple pending approvals:** Queue them — show one at a time, next appears when current is resolved. Tool calls not needing approval continue in the background.
- **Approval timeout:** If the user doesn't respond within the timeout (set by Local Agent Host, default 5 min), the agent treats it as denied. The modal is dismissed with a notice: "Approval timed out — treated as denied."
- **Session cancelled while approval is pending:** Dismiss the modal.

> ApprovalRequest schema: [services/approval-service.md](../services/approval-service.md)

### 4.4 Patch Preview View

Shows pending file changes made by the agent during the current task. Accessed via a "Review changes" button in the conversation view.

**Layout:**

```
┌─────────────────────────────────────────────┐
│  Pending Changes (3 files)     [Close]      │
├──────────────────┬──────────────────────────┤
│  Changed files   │  Diff view              │
│                  │                          │
│  ✚ src/new.ts    │  @@ -10,7 +10,9 @@      │
│  ✎ src/api.ts    │   import { Client }      │
│  ✎ src/test.ts   │  -  const old = ...      │
│                  │  +  const refactored = ..│
│                  │  +  // Added validation  │
│                  │                          │
└──────────────────┴──────────────────────────┘
```

**Data source:** `GetPatchPreview` JSON-RPC method on the Local Agent Host. Returns a list of modified files with their diffs.

**Interactions:**
- **Select a file** → show its diff in the right panel
- **View modes** → unified diff or side-by-side

### 4.5 Settings View

User preferences and connection configuration.

| Setting | Description | Default |
|---------|-------------|---------|
| Approval mode | `always`, `on_risky_actions`, `never` | `on_risky_actions` |
| Max steps per task | Step limit for agent loop | 40 |
| Theme | Light / dark / system | System |
| Agent-runtime version | Current version, check for updates | *(display only)* |
| Network timeout | Default shell command timeout | 300s |

Settings are stored locally in the OS-native preferences store (macOS: `UserDefaults`, Windows: Registry or `%APPDATA%` config file). They are passed as `taskOptions` in `StartTask` calls.

---

## 5. JSON-RPC Client

The `ipc/` module manages all communication with the Local Agent Host.

### 5.1 Connection Management

```
1. Updater spawns the agent-runtime process
2. IPC module connects via:
   - stdio: reads from process stdout, writes to process stdin
   - local socket: connects to a named pipe / Unix domain socket
3. JSON-RPC 2.0 framing over the transport
4. Connection is held for the lifetime of the session
5. On disconnect: notify views, offer reconnect or restart
```

**Transport selection:**
- **Phase 1:** stdio (simplest — the process is a child of the Desktop App)
- **Phase 2+:** local socket (enables reconnection after Desktop App restart without killing the agent-runtime)

### 5.2 Request/Response Handling

The IPC module provides a typed async interface for each JSON-RPC method:

```
ipcClient.createSession(params)  → Promise<CreateSessionResult>
ipcClient.startTask(params)      → Promise<void>  (fire-and-forget, results come via events)
ipcClient.cancelTask(params)     → Promise<void>
ipcClient.resumeSession(params)  → Promise<ResumeSessionResult>
ipcClient.getSessionState()      → Promise<SessionState>
ipcClient.getPatchPreview()      → Promise<PatchPreview>
ipcClient.approveAction(params)  → Promise<void>
ipcClient.shutdown()             → Promise<void>
```

Additional invoke channels for Workspace Service operations (HTTPS REST, not JSON-RPC):

```
workspace:list             → listWorkspaces(tenantId, userId)
workspace:list-sessions    → listSessions(workspaceId)
workspace:get-session-history → getSessionHistory(workspaceId, sessionId)
workspace:delete           → deleteWorkspace(workspaceId)
workspace:delete-session   → deleteSession(workspaceId, sessionId)
```

- **Request timeout:** 30 seconds for most methods. `createSession` and `resumeSession` use 60 seconds (they involve backend calls).
- **Error handling:** JSON-RPC errors are parsed into typed error objects using the standard error shape (see [architecture.md, Section 6.5](../architecture.md#65-error-shape--all-components)). The IPC module maps error codes to user-facing messages.

### 5.3 Event Listener

The IPC module listens for `SessionEvent` JSON-RPC notifications (no `id`, no reply expected) and dispatches them to registered handlers:

```
ipcClient.on("text_chunk",            handler)  — streaming LLM text
ipcClient.on("step_started",          handler)  — new step began
ipcClient.on("step_completed",        handler)  — step finished
ipcClient.on("tool_requested",        handler)  — tool call started
ipcClient.on("tool_completed",        handler)  — tool call finished
ipcClient.on("approval_requested",    handler)  — approval needed
ipcClient.on("approval_resolved",     handler)  — approval decision made
ipcClient.on("step_limit_approaching", handler) — 80% of maxSteps
ipcClient.on("policy_expired",        handler)  — session paused
ipcClient.on("plan_updated",          handler)  — plan progress update
ipcClient.on("error",                 handler)  — agent-level error
```

The conversation view registers handlers to update the message list in real time. The approval view registers for `approval_requested` to show the modal.

### 5.3.1 Event Replay

All `SessionEvent` notifications include an `eventId` field (monotonic integer assigned by the agent-runtime's `EventBuffer`). The Desktop App tracks the highest seen `eventId` in session state (`lastSeenEventId`).

When the user navigates away from the conversation view (e.g., to settings or history) and returns, the `useEventReplay` hook fires:

1. **Call `GetEvents`** — `{ method: "GetEvents", params: { sinceId: lastSeenEventId } }` via JSON-RPC
2. **Dispatch missed events** — Each event is dispatched through the same `dispatchSessionEvent()` function with `isReplay: true`, which:
   - Skips `approval_requested` events (if an approval is genuinely pending, the live stream delivers it)
   - Deduplicates by checking `event.eventId <= currentLastSeenId` (handles race with live events)
   - Updates `lastSeenEventId` as events are processed
3. **Gap fallback** — If `gapDetected: true` (ring buffer overflow, events evicted), the app falls back to loading full session history from Workspace Service via `getSessionHistory()`, replacing the messages store entirely

`lastSeenEventId` resets to 0 on session change and store reset, ensuring no stale replay across sessions.

### 5.4 Error Code to UI Message Mapping

| Error Code | User-Facing Message |
|------------|-------------------|
| `SESSION_NOT_FOUND` | "Session not found. Start a new conversation." |
| `SESSION_EXPIRED` | "Session expired. Please start a new conversation." |
| `POLICY_EXPIRED` | "Session paused — security policy expired. Reconnecting..." |
| `CAPABILITY_DENIED` | "The agent tried an action that is not permitted by your organization's policy." |
| `APPROVAL_DENIED` | "You denied this action. The agent will try a different approach." |
| `LLM_GUARDRAIL_BLOCKED` | "The request was blocked by content safety filters." |
| `LLM_BUDGET_EXCEEDED` | "Token budget exhausted for this session. Start a new conversation to continue." |
| `TOOL_EXECUTION_FAILED` | "A tool encountered an error. The agent will attempt to recover." |
| `TOOL_EXECUTION_TIMEOUT` | "A tool timed out. The agent will attempt to recover." |
| `INTERNAL_ERROR` | "Something went wrong. Please try again." |

---

## 6. Application State

The `state/` module manages all UI state. Views read from and write to this centralized store.

### 6.1 State Shape

```
AppState {
  // Current session (null when in history view)
  session: {
    sessionId: string
    workspaceId: string
    status: SessionStatus
    task: {
      taskId: string
      status: TaskStatus
      stepCount: number
      maxSteps: number
    } | null
  } | null

  // Event replay tracking (reset on session change)
  lastSeenEventId: number  // 0 = fresh session

  // Conversation thread (accumulated from events during active session)
  messages: ConversationMessage[]

  // Pending approvals (queued, shown one at a time)
  pendingApprovals: ApprovalRequest[]

  // Patch preview data
  patchPreview: PatchPreview | null

  // History browsing
  workspaces: WorkspaceSummary[]
  selectedWorkspace: string | null
  sessionsForWorkspace: SessionSummary[]

  // Agent mode indicators
  planMode: boolean                  // true when agent is in plan (read-only) mode
  isVerifying: boolean               // true during post-completion verification phase

  // Plan progress (from plan_updated events)
  plan: {
    goal: string
    steps: { index: number, description: string, status: string }[]
  } | null

  // UI
  view: "history" | "conversation" | "settings"
  theme: "light" | "dark" | "system"

  // Agent-runtime
  agentRuntimeStatus: "not_started" | "starting" | "running" | "stopped" | "crashed"
  agentRuntimeVersion: string | null
}
```

### 6.2 State Transitions

| Trigger | State Change |
|---------|-------------|
| User opens project / starts new chat | `view → "conversation"`, spawn agent-runtime, `agentRuntimeStatus → "starting"` |
| IPC connection established | `agentRuntimeStatus → "running"` |
| `CreateSession` response | `session` populated with sessionId, workspaceId |
| User submits prompt | `session.task` populated, `StartTask` sent |
| `SessionEvent: text_chunk` | Append to current assistant message in `messages` |
| `SessionEvent: tool_requested` | Add tool call card to `messages` |
| `SessionEvent: tool_completed` | Update tool call card status in `messages` |
| `SessionEvent: approval_requested` | Add to `pendingApprovals` queue, show modal |
| User approves/denies | Remove from `pendingApprovals`, send `ApproveAction` |
| `SessionEvent: step_started` | Increment `session.task.stepCount` |
| `SessionEvent: plan_mode_changed` | Set `planMode` from payload; add info system message |
| `SessionEvent: plan_updated` | Set `plan` from payload (goal + steps with status); displayed in PlanPanel |
| `SessionEvent: verification_started` | Set `isVerifying → true`; add info system message |
| `SessionEvent: verification_completed` | Set `isVerifying → false`; add info/warning system message |
| Task completes/fails/cancelled | `session.task → null`, `planMode → false`, `isVerifying → false`, `plan → null`, re-enable prompt input |
| User clicks "Review changes" | Fetch `GetPatchPreview`, populate `patchPreview` |
| Agent-runtime process exits | `agentRuntimeStatus → "crashed"`, show recovery dialog |
| User navigates to history | `view → "history"`, `session → null` |

---

## 7. Workspace Service Client

The `workspace/` module communicates directly with the Workspace Service over HTTPS REST. This is separate from the IPC channel — the Desktop App reads history from the backend independently of whether an agent-runtime process is running.

### 7.1 Operations

| Method | API Call | Used By |
|--------|----------|---------|
| `listWorkspaces(tenantId, userId)` | `GET /workspaces?tenantId=...&userId=...` | History view — workspace list |
| `listSessions(workspaceId)` | `GET /workspaces/{workspaceId}/sessions` | History view — session list |
| `getSessionHistory(workspaceId, sessionId)` | Fetch `session_history` artifact | History view — conversation display; session continuation |
| `deleteWorkspace(workspaceId)` | `DELETE /workspaces/{workspaceId}` | Sidebar — workspace management |
| `deleteSession(workspaceId, sessionId)` | `DELETE /workspaces/{workspaceId}/sessions/{sessionId}` | Sidebar — session management |

### 7.2 Session Continuation Flow

When the user selects "Continue" on a past session:

```mermaid
sequenceDiagram
  participant User
  participant Main as Main Process
  participant WS as Workspace Service
  participant AR as agent-runtime.ts
  participant AH as Local Agent Host

  User->>Main: Select past session → "Continue"
  Main->>WS: Fetch session_history artifact
  WS-->>Main: ConversationMessage[]
  Main->>AR: Spawn agent-runtime
  AR->>AH: Start process
  Main->>AH: CreateSession (workspaceHint with same workspace)
  AH-->>Main: New sessionId, same workspaceId
  Main->>Main: Bootstrap message list from session_history
  Main->>AH: StartTask (user's new prompt, with thread context)
```

The new session gets a fresh `sessionId` but reuses the same `workspaceId`. The conversation thread is bootstrapped from the `session_history` artifact — the user sees their past messages and can continue seamlessly.

### 7.3 Authentication

The Desktop App authenticates to the Workspace Service using the same tenant/user credentials used for the session. The auth token is acquired at application login (implementation deferred — Phase 1 may use a simple API key or delegated token from the Session Service).

---

## 8. Agent-Runtime Lifecycle

The `main/agent-runtime.ts` module manages the full lifecycle of the agent-runtime binary.

### 8.1 Phase 1 — Bundled

In Phase 1, the agent-runtime binary ships inside the desktop installer:

```
macOS:  AppName.app/Contents/Resources/agent-runtime
Windows: C:\Program Files\AppName\agent-runtime.exe
```

`agent-runtime.ts` locates the bundled binary, verifies it exists, and spawns it.

### 8.2 Phase 4 — Independent Download

```mermaid
flowchart TD
  Launch["App launches"] --> Check{"agent-runtime<br/>present?"}
  Check -- Yes --> VerifyVer{"Version<br/>compatible?"}
  Check -- No --> Fetch["Fetch version manifest"]
  VerifyVer -- Yes --> Spawn["Spawn agent-runtime"]
  VerifyVer -- No --> Fetch
  Fetch --> Download["Download platform bundle"]
  Download --> Verify["Verify integrity<br/>(SHA-256 + code signing)"]
  Verify --> Store["Store in app data directory"]
  Store --> Spawn

  Spawn --> Monitor["Monitor child process"]
  Monitor --> Healthy{"Process<br/>healthy?"}
  Healthy -- Yes --> Monitor
  Healthy -- No --> Crash["Handle crash<br/>(offer resume / restart)"]
```

**Version manifest:**

```json
{
  "latest": "1.4.0",
  "minDesktopAppVersion": "2.0.0",
  "platforms": {
    "darwin-arm64": {
      "url": "https://releases.example.com/agent-runtime/1.4.0/agent-runtime-1.4.0-darwin-arm64.tar.gz",
      "sha256": "abc123..."
    },
    "darwin-x64": { "url": "...", "sha256": "..." },
    "win32-x64": { "url": "...", "sha256": "..." }
  }
}
```

**Storage location:**

```
macOS:   ~/Library/Application Support/{AppName}/agent-runtime/{version}/
Windows: %APPDATA%\{AppName}\agent-runtime\{version}\
```

Multiple versions can coexist. The updater activates the latest compatible version on the next session start.

### 8.3 Process Management

| Concern | Behavior |
|---------|----------|
| Spawning | Start as child process; connect via stdio (Phase 1) or local socket (Phase 2+) |
| Health check | Monitor process exit code; detect unexpected termination |
| Graceful shutdown | Send `Shutdown` JSON-RPC → wait 10s → SIGTERM → wait 5s → SIGKILL |
| Crash recovery | Detect exit, notify user, offer resume/restart (see [Section 3.3](#33-crash-recovery)) |
| One process per session | Desktop App spawns one agent-runtime per active session |
| Multiple sessions | Future: multiple agent-runtime processes (one per conversation tab). Phase 1: single session. |

---

## 9. Platform Considerations

### 9.1 macOS

| Concern | Approach |
|---------|----------|
| Application packaging | `.app` bundle, distributed via DMG or direct download |
| Code signing | Apple Developer ID + Notarization |
| Agent-runtime binary | Code-signed, stored in `~/Library/Application Support/` |
| Window management | Standard macOS window with traffic lights, menu bar integration |
| Notifications | `NSUserNotification` for approval requests when app is backgrounded |
| Auto-update | Sparkle framework or custom updater |

### 9.2 Windows

| Concern | Approach |
|---------|----------|
| Application packaging | MSI or MSIX installer |
| Code signing | Authenticode (EV certificate recommended) |
| Agent-runtime binary | Signed, stored in `%APPDATA%` |
| Window management | Standard Windows window with title bar, system tray icon |
| Notifications | Windows Toast notifications for approval requests when app is backgrounded |
| Auto-update | Squirrel.Windows or WinGet |

### 9.3 Cross-Platform UI

The UI framework must support both macOS and Windows from a single codebase. Candidates include Electron, Tauri, or platform-native with shared logic. The framework choice is an implementation decision — this design is framework-agnostic.

**Key requirements for the framework:**
- Native look and feel on both platforms
- Efficient rendering of long message lists (virtualized scrolling)
- Syntax-highlighted code blocks in messages and diffs
- Support for streaming text (incremental rendering)
- Child process management (spawning and monitoring agent-runtime)
- Local socket / stdio communication

---

## 10. Security

### 10.1 IPC Security

- The JSON-RPC connection between Desktop App and Local Agent Host is local-only (stdio or local socket) — no network exposure
- No authentication on the IPC channel — the process is a child of the Desktop App, and only one client connects
- The Desktop App never sends credentials over IPC — auth tokens are managed by the agent-runtime from the Session Service

### 10.2 Credential Management

- Tenant/user credentials for backend services are stored in the OS keychain (macOS Keychain, Windows Credential Manager)
- Credentials are never written to disk in plaintext
- The Desktop App retrieves credentials from the keychain at startup and passes them to the agent-runtime via the `CreateSession` params

### 10.3 Agent-Runtime Integrity

- In Phase 4 (independent download): verify SHA-256 checksum and OS code signature before spawning
- Reject binaries that fail integrity checks
- Log integrity verification results for audit

---

## 11. Notification and Background Behavior

When the Desktop App is backgrounded or minimized, agent execution continues (the agent-runtime is a separate process).

| Event | Background behavior |
|-------|-------------------|
| Approval requested | Show OS notification: "Agent needs your approval — {actionSummary}" |
| Task completed | Show OS notification: "Agent finished — {task summary}" |
| Task failed | Show OS notification: "Agent encountered an error" |
| Agent-runtime crashed | Show OS notification: "Agent process stopped unexpectedly" |

Clicking any notification brings the Desktop App to the foreground and navigates to the relevant view.

---

## 12. Browser Integration (Phase 2)

Browser automation adds a browser side panel, toggle, and approval dialogs to the desktop app. The browser itself runs as a separate headed Playwright process — the desktop app only displays screenshots and provides controls. Full design: [browser-automation.md](browser-automation.md).

### Browser side panel

Collapsible right panel in the conversation view. Hidden by default, opens automatically on first browser tool call. Shows:
- Current page URL (read-only)
- Screenshot stream (event-driven updates after each browser action)
- Action buttons: **Takeover** (focus browser window), **Pause** (suspend agent), **Close** (shut down browser)

### Browser toggle

Per-session opt-in control in the prompt input area (🌐 icon, off by default). Grayed out if policy doesn't grant `Browser.*` capabilities. Enabling adds browser tools to the LLM's tool definitions; disabling removes them and shuts down the browser.

### Browser approval dialogs

Three variants extend the existing approval system:
- **Domain approval** (low risk) — first interaction with a new domain
- **Sensitive action** (medium risk) — password fields, destructive buttons, payment forms (includes screenshot)
- **Submission checkpoint** (high risk) — form submissions with form data summary and screenshot

### New event types

| Event | Payload | Purpose |
|-------|---------|---------|
| `browser_started` | `{ browserChannel }` | Browser launched (side panel opens) |
| `browser_stopped` | `{ reason }` | Browser closed (idle, session end, user close, crash) |
| `browser_page_state` | `{ url, screenshotBase64 }` | Screenshot update for side panel |
| `browser_auth_required` | `{ domain, signals[] }` | Auth detected, waiting for user takeover |
| `browser_takeover_started` | — | User took over browser control |
| `browser_takeover_ended` | — | User resumed agent control |
| `browser_domain_approved` | `{ domain }` | User approved a new domain |

### New IPC channels

| Channel | Direction | Purpose |
|---------|-----------|---------|
| `browser:takeover` | Renderer → Main | Focus browser window for user interaction |
| `browser:pause` | Renderer → Main | Suspend agent after current tool completes |
| `browser:resume` | Renderer → Main | Resume agent loop after takeover |
| `browser:close` | Renderer → Main | Shut down browser, disable toggle |
| `push:browser-page-state` | Main → Renderer | Screenshot + URL update |
| `push:browser-auth-required` | Main → Renderer | Auth detection notification |

### State management

New `browser-store` (Zustand) tracks `browserEnabled`, `browserStatus`, `currentUrl`, `currentScreenshot`, `approvedDomains`, and `panelOpen`. Follows the same pattern as existing stores in `state/`.

### Package layout additions

```
renderer/
  views/
    conversation/
      browser-panel.tsx     — Browser side panel component (NEW)
  components/
    browser-toggle.tsx      — Browser enable/disable toggle (NEW)
    browser-approval.tsx    — Browser-specific approval dialogs (NEW)
  state/
    browser-store.ts        — Browser state management (NEW)
main/
  ipc-handlers.ts           — Add browser:* channel handlers (MODIFIED)
shared/
  ipc-channels.ts           — Add browser channel constants (MODIFIED)
```

---

## 13. Open Questions

| Question | Context | Recommendation |
|----------|---------|----------------|
| UI framework | Electron, Tauri, or native? | Implementation decision — evaluate based on team expertise, bundle size, and performance. Tauri for smaller bundle; Electron for broader ecosystem. |
| Multiple simultaneous sessions | Should the user be able to have multiple conversations open in tabs? | Phase 1: single session. Phase 2+: tab-based multi-session (one agent-runtime process per tab). |
| Offline mode | What happens if the backend is unreachable? | Phase 1: show error, block session creation. Phase 2+: allow browsing cached history offline. |
| Conversation search | Should the history view support full-text search across sessions? | Defer to Phase 2 — requires a search index or backend search endpoint. |
| Theming / accessibility | Dark mode, high contrast, keyboard navigation | Phase 1: system theme detection, basic keyboard nav. Phase 2: full accessibility audit. |
| Agent-runtime log access | Should the user be able to view agent-runtime logs for debugging? | Phase 1: logs written to `~/Library/Logs/` (macOS) or `%APPDATA%\Logs\` (Windows). Settings view shows log path. Phase 2: in-app log viewer. |
| Desktop App auto-update | How does the Desktop App itself update? | OS-native auto-update (Sparkle on macOS, Squirrel on Windows). Separate from agent-runtime updates. |
