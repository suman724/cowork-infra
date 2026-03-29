# Agent Improvement Roadmap

**Status:** Proposed
**Date:** 2026-03-28
**Scope:** cowork-agent-sdk, cowork-agent-runtime, cowork-memory-service, cowork-session-service, cowork-web-app, cowork-infra

---

## Overview

This roadmap organizes all pending improvements across the cowork agent system into phases based on dependency order and impact. It covers tooling expansion, agent loop quality, production readiness, memory service, operational excellence, and UI polish.

The roadmap is informed by:
- Current implementation analysis (agent-sdk + agent-runtime code review)
- Design docs (local-agent-host, local-tool-runtime, browser-automation, agent-sdk-extraction)
- Anthropic's engineering guidance on [harness design for long-running agents](https://www.anthropic.com/engineering/harness-design-long-running-apps)
- Known limitations and gaps identified in code review

---

## Phase A — Plan Quality & Tool Execution

**Goal:** Fix critical gaps in plan+sub-agent execution and improve the tool execution pipeline.

**Why first:** Plan+sub-agent fixes are quick wins with high impact on task quality. Tool execution improvements (streaming, cancellation, shell args) make the agent more responsive and safer. All changes are in `cowork-agent-sdk` and `cowork-agent-runtime` — no new services or dependencies.

### A1: Add "failed" Status to PlanStep

**Repo:** `cowork-agent-sdk`
**Design doc:** `plan-subagent-improvements.md`

PlanStep only has `pending`, `in_progress`, `completed`, `skipped`. No way to represent failure.

**What to build:**
- Add `"failed"` to PlanStep status literal type
- Update `UpdatePlanStep` tool to accept `"failed"` status
- Update plan rendering to show failed steps distinctly

**Acceptance criteria:**
- Agent can mark a step as failed
- Failed steps render visibly in working memory
- Plan continuation logic treats failed steps same as completed/skipped (not blocking)

### A2: Pass Plan Context to Sub-agents

**Repo:** `cowork-agent-runtime`
**Design doc:** `plan-subagent-improvements.md`

Sub-agents have zero visibility into the parent's plan.

**What to build:**
- Include parent plan summary in sub-agent context: goal, all steps with status, current step highlighted
- Fix `EnterPlanMode` tool description (currently misleading — says "only read-only tools" but SpawnAgent is available)
- Add system prompt guidance for delegation during plan execution

**Acceptance criteria:**
- Sub-agent's system prompt includes parent plan context
- Sub-agent output is relevant to the specific plan step it's executing

### A3: Auto-Update Plan Step on Sub-agent Return

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`
**Design doc:** `plan-subagent-improvements.md`

When a sub-agent completes work for a plan step, the parent must manually call `UpdatePlanStep`. The LLM often forgets.

**What to build:**
- `SpawnAgent` gains optional `planStepIndex` parameter
- On sub-agent completion: auto-call `UpdatePlanStep(planStepIndex, "completed")`
- On sub-agent failure: auto-call `UpdatePlanStep(planStepIndex, "failed")` (uses A1)
- Emit `plan_updated` event after auto-update

**Acceptance criteria:**
- Plan step status updates automatically when sub-agent returns
- Parent doesn't need to remember to call `UpdatePlanStep`
- Works for both successful and failed sub-agents

### A4: Improve Sub-agent Result Handling

**Repo:** `cowork-agent-runtime`
**Design doc:** `plan-subagent-improvements.md`

Sub-agent results are truncated to 2000 characters. Complex work output is lost.

**What to build:**
- Increase default result limit to 8000 characters
- For results exceeding the limit: write full result to workspace file, return file path + summary

**Acceptance criteria:**
- Sub-agent results not silently truncated
- Parent can access full results via workspace file if needed

### A5: Pass Read-Only Working Memory to Sub-agents

**Repo:** `cowork-agent-runtime`
**Design doc:** `plan-subagent-improvements.md`

Sub-agents start with empty working memory — no task tracker, no notes, no plan context.

**What to build:**
- Read-only snapshot of parent's working memory at spawn time
- Include in sub-agent's system prompt as context
- Contains: task tracker summary, notes

**Acceptance criteria:**
- Sub-agent sees parent's task list and notes
- Sub-agent cannot corrupt parent's working memory

### A6: Streaming Tool Output

**Repos:** `cowork-agent-runtime`, `cowork-agent-sdk`
**Design doc:** `tool-execution-improvements.md`

Long-running shell commands block until completion. Users see nothing until the command finishes.

**What to build:**
- Callback-based output streaming from RunCommand
- Output chunks emitted as events (new `tool_output_chunk` event type)
- Final result still assembled for thread history

**Acceptance criteria:**
- User sees incremental output from long-running commands
- Output chunks appear in SSE stream
- Final output in thread history is complete

### A7: Force Cancellation with Hard Timeout

**Repo:** `cowork-agent-runtime`
**Design doc:** `tool-execution-improvements.md`

Tool cancellation is cooperative — a runaway tool runs indefinitely.

**What to build:**
- Configurable hard timeout per tool type (default: 300s for shell, 30s for code)
- Process tree kill if timeout exceeded (SIGTERM → 5s → SIGKILL)
- Tool result marked as `timeout` with partial output captured

**Acceptance criteria:**
- Runaway shell commands killed after hard timeout
- Partial output captured and returned to LLM
- No zombie processes left behind

### A8: Shell Argument Inspection

**Repo:** `cowork-agent-runtime`
**Design doc:** `tool-execution-improvements.md`

Policy only inspects the base command. Cannot distinguish `rm -rf /` from `rm temp.txt`.

**What to build:**
- Argument pattern matching in PolicyEnforcer
- Capability `allowedCommands` extended with patterns that include arguments
- Risk assessor considers arguments

**Acceptance criteria:**
- Policy can allow `git *` but block `git push --force`
- Risk assessment elevates destructive argument patterns

---

## Phase B — Browser Automation

**Goal:** Give the agent a browser for web research, form filling, and multi-step workflows with human-in-the-loop oversight.

**Why second:** Browser tools are the highest-value capability expansion. Users need web research, form filling, and data extraction. The design is comprehensive (1,200+ lines) and self-contained — all changes in `cowork-agent-runtime` and `cowork-desktop-app`.

**Repos:** `cowork-agent-runtime` (tool_runtime/tools/browser/), `cowork-desktop-app`, `cowork-platform`
**Design doc:** `browser-automation.md`

### B1: BrowserManager & Playwright Integration

Core lifecycle management for the browser process.

**What to build:**
- BrowserManager: Playwright launch/shutdown, state machine (Idle → Launching → Active → Suspended → ShuttingDown)
- Lazy launch: Playwright starts on first browser tool call, not session start
- Idle timeout (10 min): suspend browser, save storage state, re-launch on next call
- Session-end cleanup: close browser, persist cookies/localStorage
- Headed Chromium window (visible to user)

**Acceptance criteria:**
- Browser launches only when needed, suspends when idle, cleans up on session end
- Storage state (cookies, localStorage) persists to `{workspace_dir}/.cowork/browser-state.json`
- Re-launch after suspension restores storage state seamlessly

### B2: DomService & PageState

Accessibility tree extraction and token-efficient page representation for the LLM.

**What to build:**
- DomService: `page.accessibility.snapshot()` with indexed interactive elements `[1]`, `[2]`, `[3]`...
- PageState: Markdown rendering of page content (headings, text, links, forms) within token budget (~2K-20K tokens)
- Interactive element detection: links, buttons, inputs, selects, textareas, ARIA controls, contenteditable
- Truncation strategy for large pages

**Acceptance criteria:**
- LLM receives a structured, readable representation of any web page
- Interactive elements are addressable by index number
- Token budget stays within bounds even for complex pages

### B3: Core Browser Tools (6 tools)

The foundational navigation and interaction tools.

**What to build:**
- BrowserNavigate: Navigate to URL with `waitUntil` options (domcontentloaded, load, networkidle)
- BrowserClick: Click interactive elements by index
- BrowserType: Type into input fields by index
- BrowserSelect: Select dropdown options, checkboxes, radio buttons
- BrowserScroll: Scroll page in any direction
- BrowserBack: Navigate browser history back

**Acceptance criteria:**
- Agent can navigate to any URL and interact with page elements
- All tools return updated PageState after action

### B4: Extraction & Screenshot Tools (2 tools)

Read-only tools for extracting information from pages.

**What to build:**
- BrowserExtract: Read page content as markdown/text/HTML with optional CSS selector scope
- BrowserScreenshot: Capture viewport or full page as PNG, store as workspace artifact

**Acceptance criteria:**
- Agent can extract structured content from any page
- Screenshots stored as artifacts in Workspace Service

### B5: Submission, Download & Wait Tools (3 tools)

Higher-risk tools that always require approval.

**What to build:**
- BrowserSubmit: Submit forms — always triggers approval checkpoint with form data summary (sensitive values redacted)
- BrowserDownload: Download files to workspace — requires approval, respects `maxFileSizeBytes`
- BrowserWait: Wait for elements, navigation, or network idle with CSS selectors

**Acceptance criteria:**
- Form submissions always require user approval before executing
- Downloads respect file size limits and path restrictions
- Wait tool supports CSS selectors and configurable timeout

### B6: Three-Tier HITL & SensitiveDetector

Human-in-the-loop oversight system.

**What to build:**
- Tier 1 — Domain approval: first interaction with new domain triggers approval (policy `allowedDomains`/`blockedDomains` with wildcards)
- Tier 2 — Sensitive element detection: password fields, destructive buttons, payment/government ID fields
- Tier 3 — Submission checkpoints: `BrowserSubmit` always triggers approval with screenshot + form data
- SensitiveDetector: heuristic-based detection of password, payment, destructive, and PII fields
- Approval dialogs: three variants (domain=low risk, sensitive=medium, submission=high)

**Acceptance criteria:**
- New domains require explicit approval before interaction
- Password fields, payment forms, and destructive actions detected and gated
- Form submissions show full context (screenshot, URL, form data) in approval dialog

### B7: Desktop App Integration & User Takeover

Browser UI in the desktop app and user takeover capability.

**What to build:**
- Browser side panel: collapsible right panel showing URL, screenshot stream, action buttons
- Browser toggle: per-session opt-in control (off by default), requires `Browser.*` policy capability
- User takeover: pause agent → user interacts with headed browser → click Resume
- Auth pause flow: detect login forms/401s/OAuth redirects → pause → user authenticates → resume
- New event types: `browser_started`, `browser_stopped`, `browser_page_state`, `browser_auth_required`, `browser_takeover_started`
- New IPC channels: `browser:takeover`, `browser:pause`, `browser:resume`, `browser:close`

**Acceptance criteria:**
- User can see browser state in real-time via side panel
- User can take over the browser at any time, agent pauses cleanly
- Authentication flows handled via takeover (auto-detected when possible)

### B8: Policy & Contract Updates

Formal schema and cross-cutting updates.

**What to build:**
- Five new capabilities in `cowork-platform`: `Browser.Navigate`, `Browser.Interact`, `Browser.Extract`, `Browser.Submit`, `Browser.Download`
- Policy bundle schema for `allowedDomains`, `blockedDomains`, `maxFileSizeBytes`
- ApprovalRequest variants for browser-specific approval types
- Update `architecture.md` capability table
- SSRF prevention: block `file://`, `127.0.0.1`, `10.*`, `192.168.*` unless explicitly allowed
- Plan mode interaction: read-only tools (Extract, Screenshot) allowed, mutation tools blocked

**Acceptance criteria:**
- Browser capabilities formally defined in platform contracts
- Policy enforcer gates all browser tools consistently
- SSRF prevention blocks local/internal URLs

---

## Phase C — MCP Client

**Goal:** Enable the agent to use tools from remote MCP servers — third-party APIs, custom tools, enterprise integrations.

**Why third:** MCP is the most complex tooling expansion. It introduces external dependencies (remote servers), new authentication flows, and protocol-level complexity (MCP 2025-11-25 spec). Best tackled after the core agent and browser are solid.

**Repos:** `cowork-agent-runtime` (tool_runtime/mcp/), `cowork-platform`, `cowork-policy-service`
**Design doc:** `mcp-client.md`

### C1: Streamable HTTP Transport & Session Management

Core MCP protocol implementation.

**What to build:**
- MCP 2025-11-25 Streamable HTTP transport (replaces deprecated SSE transport)
- Session management: `Mcp-Session-Id` header, session initialization via `initialize` request
- Protocol version negotiation: `MCP-Protocol-Version: 2025-11-25` header
- Connection lifecycle: connect → initialize → capability exchange → ready

**Acceptance criteria:**
- Client can establish and maintain sessions with MCP servers
- Protocol version negotiated correctly
- Session recovery on reconnection

### C2: Tool Discovery & Namespace Management

Discover and register MCP tools alongside built-in tools.

**What to build:**
- `tools/list` with pagination support (cursor-based)
- List change notifications via `notifications/tools/list_changed`
- Namespace prefixing: `{serverName}/{toolName}` to avoid collisions with built-in tools
- Tool manifest translation: MCP `Tool` → cowork `ToolDefinition`
- Tool annotations: `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint` → influence policy

**Acceptance criteria:**
- MCP tools appear in tool definitions sent to LLM with namespace prefix
- Tool list refreshes automatically on server notification
- Tool annotations preserved and used by policy enforcer

### C3: Tool Execution & Response Translation

Execute MCP tools and translate responses.

**What to build:**
- `tools/call` with per-tool timeout and output truncation
- Response size cap (10MB) to prevent memory exhaustion
- Response translation: text → string, image → base64 artifact, structured content → formatted text, audio → artifact, resource links → fetch + inline, error → tool error
- Progress notifications for long-running tools

**Acceptance criteria:**
- Agent can call MCP tools and receive translated results
- Large responses truncated gracefully
- All MCP content types handled

### C4: Policy Integration & Authentication

Security, policy enforcement, and auth for MCP servers.

**What to build:**
- Policy bundle: `mcpServers` config section with server URL, auth, and allowed tools
- `MCP.{serverName}` capability mapping (e.g., `MCP.github` gates all GitHub MCP tools)
- Per-server circuit breaker: 5 consecutive failures → open (30s) → half-open → retry
- Bearer token auth: Secrets Manager (web sandbox) or env var (desktop)
- Tool annotations influence policy: `destructiveHint=true` → require approval

**Acceptance criteria:**
- Policy enforcer gates MCP tools the same as built-in tools
- Circuit breaker prevents cascading failures from unreachable servers
- Auth tokens securely managed per deployment model

---

## Phase D — Agent Loop Quality

**Goal:** Improve the agent's ability to handle long, complex tasks reliably. Informed by Anthropic's harness design research.

**Why fourth:** Once tools work well (Phases A-C), the quality of how the agent plans, evaluates, and iterates becomes the bottleneck.

### D1: Sprint Contracts (Acceptance Criteria per Plan Step)

**Repo:** `cowork-agent-sdk`

Each PlanStep gets testable `acceptanceCriteria` — the agent knows what "done" looks like before starting.

**What to build:**
- Extend `PlanStep` with `acceptance_criteria: list[str]`
- `CreatePlan` tool accepts criteria per step
- Plan rendering shows criteria alongside steps
- Verification phase (or evaluator in D3) checks against criteria

### D2: Context Resets with Structured Handoffs

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`

When context hits 80% capacity, spawn a continuation agent with a structured handoff rather than degrading in a bloated context.

**What to build:**
- Detect context approaching limit (80% of max_context_tokens)
- Generate handoff document: what was accomplished, current state, remaining work, key decisions
- Spawn continuation agent with handoff as initial context
- Original agent completes cleanly after handoff

### D3: Separate Evaluator Agent

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`

Replace single-shot verification with a separate agent that evaluates work against criteria, returns pass/fail with specific feedback.

**What to build:**
- Evaluator agent spawned after task/sprint completion
- Evaluates against acceptance criteria (from D1)
- Returns structured feedback: pass/fail per criterion, specific issues, fix recommendations
- Generator receives feedback and iterates (D4)

### D4: Iterative Refinement Loop

**Repo:** `cowork-agent-sdk`

Generate → evaluate → feedback → regenerate cycle until evaluator passes or max iterations reached.

**What to build:**
- Configurable max iterations (default: 3)
- Each iteration: generator receives evaluator feedback, attempts fixes
- Loop exits when: all criteria pass, max iterations reached, or no progress detected

### D5: Plan Improvements (Sub-plans, Dependencies)

**Repo:** `cowork-agent-sdk`

Currently plans are flat lists. Complex tasks need hierarchy and dependencies.

**What to build:**
- Sub-plans: a step can contain its own nested plan
- Step dependencies: "step 4 depends on step 2 and 3"
- Conditional steps: "step 5 only if step 3 produced errors"

### D6: Adaptive Verification

**Repo:** `cowork-agent-sdk`

Currently verification runs once with a fixed prompt. Can't re-verify or adapt to task type.

**What to build:**
- Re-verification if issues found (loop until pass or max attempts)
- Task-type specific verification prompts (code → run tests, writing → check structure)
- Configurable verification depth

### D7: Error Recovery Fuzzy Matching

**Repo:** `cowork-agent-sdk`

Loop detection uses exact argument matching. Similar but not identical calls aren't detected.

**What to build:**
- Normalize arguments before hashing (sort keys, strip whitespace)
- Fuzzy matching on argument similarity (e.g., same tool + similar path)
- Configurable similarity threshold

### D8: Compaction Prompt Customization

**Repo:** `cowork-agent-sdk`

Summarization prompt is fixed. Different task types benefit from different summarization strategies.

**What to build:**
- Configurable summarization prompt per task type or via COWORK.md
- Preserve different information based on context (code tasks preserve code, research tasks preserve findings)

---

## Phase E — Production Readiness

**Goal:** Enable production deployment for real users.

### E1: Merge Pending Branches

Merge all reviewed branches:
- `fix/plan-step-verification` (agent-sdk)
- `docs/simplified-session-api` (infra)
- `docs/onedrive-storage-backend` (infra)
- `docs/memory-service-hybrid-search` (infra)
- Docker build CI fix (agent-runtime)

### E2: OIDC Authentication

**Repos:** `cowork-session-service`, `cowork-web-app`

Multi-tenant auth for production. JWT validation, OIDC login flow, session ownership from token.

### E3: Simplified Session API

**Repos:** `cowork-session-service`, `cowork-agent-runtime`, `cowork-platform`, `cowork-web-app`
**Design doc:** `simplified-session-api.md`

- Stage 1: `/messages`, `/cancel`, `/approve`, `/stream` endpoints in Session Service
- Stage 2: Web App migration to new endpoints

### E4: Connection Draining

**Repos:** `cowork-session-service`, `cowork-agent-runtime`

Graceful shutdown with in-flight requests. SSE shutdown event, proxy retry vs shutdown detection.

---

## Phase F — Memory & Services

**Goal:** Add persistent cross-session memory and external integrations.

### F1: Memory Service Phase 1

**Repos:** `cowork-memory-service` (new), `cowork-agent-runtime`, `cowork-platform`
**Design doc:** `services/memory-service.md`

Centralized multi-tenant memory with hybrid search (vector + BM25 + RRF).

### F2: OneDrive Integration

**Repos:** `cowork-workspace-service`, `cowork-session-service`, `cowork-web-app`
**Design doc:** `design/onedrive-integration.md`

OneDriveFileStore with Microsoft Graph API. storageBackend model, token custodian in Session Service.

### F3: Agent Teams

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`
**Design doc:** `components/agent-teams.md`

Multi-agent orchestration: lead agent spawns teammates with roles, shared workspace, peer communication, task delegation. Extends sub-agent model into persistent collaborating peers (planner → generator → evaluator pattern from Anthropic research).

---

## Phase G — Sub-agent & Skill Improvements

**Goal:** Improve the quality and flexibility of sub-agents and skills.

### G1: Sub-agent Adaptive Steps

**Repo:** `cowork-agent-runtime`

Dynamic max_steps based on task complexity instead of fixed 10. Estimate from prompt length, plan step complexity, or parent hint.

### G2: Skill Nesting

**Repo:** `cowork-agent-runtime`

Skills calling other skills. Requires dependency resolution and circular reference prevention.

### G3: Per-capability Token Budgets

**Repo:** `cowork-agent-sdk`

Separate budgets for different tool types (e.g., LLM calls vs tool execution). Prevents one expensive operation from consuming the entire session budget.

### G4: Multi-model LLM Selection

**Repo:** `cowork-agent-sdk`

Select model by task complexity from `allowedModels` list. Simple tasks → fast/cheap model, complex tasks → capable model.

---

## Phase H — Operational & Security

**Goal:** Production hardening and operational excellence.

### H1: EventBridge Crash Detection + Lifecycle Migration

**Repos:** `cowork-session-service`, `cowork-infra`

Replace polling-based timeout checks with EventBridge events. Faster crash detection, precise timeouts.

### H2: Version-Aware Task Drain

**Repo:** `cowork-agent-runtime`

Tasks check revision after session ends, exit if outdated. Zero-interruption deploys.

### H3: Persistent Memory Encryption

**Repo:** `cowork-agent-sdk`

Encrypt memory files at rest using OS keychain (macOS Keychain, Windows DPAPI).

### H4: Checkpoint Versioning

**Repo:** `cowork-agent-sdk`

Schema versioning for crash recovery files. Graceful handling of version mismatches.

### H5: Workspace TTL Cleanup

**Repo:** `cowork-workspace-service`

Auto-expire `general` and `cloud` workspaces. Implement the deferred 90-day inactivity purge.

### H6: Tool Result Caching

**Repo:** `cowork-agent-runtime`

Cache repeated tool calls within a task (e.g., same `ReadFile` twice). Invalidate on writes.

---

## Phase I — UI & Polish

**Goal:** Frontend improvements and cross-platform consistency.

### I1: Enhanced File Management

**Repo:** `cowork-web-app`

Tree view, inline editor (Monaco), drag-and-drop upload, multi-file download, file change indicators.

### I2: Desktop App Migration

**Repo:** `cowork-desktop-app`

Refactor IPC handlers to simplified contract (`session:create`, `session:send-message`, etc.). Shared `SessionClient` TypeScript interface.

### I3: File Watching for Patch Preview

**Repo:** `cowork-agent-runtime`

Real-time file change detection for GetPatchPreview. Currently uses in-memory list, Phase 2 adds filesystem watch.

---

## Dependency Graph

```
Phase A (Plan Quality + Tool Execution)
  ├── A1 (Failed PlanStep status) ──┐
  ├── A2 (Plan context to sub-agents)┤
  ├── A3 (Auto plan step update) ───┤ depends on A1
  ├── A4 (Sub-agent results) ──────┤
  ├── A5 (Read-only working memory)┘
  ├── A6 (Streaming output)
  ├── A7 (Force cancel)
  └── A8 (Shell args)

Phase B (Browser Automation) ← can start after A6-A8
  ├── B1 (BrowserManager + Playwright)
  ├── B2 (DomService + PageState)
  ├── B3 (Core browser tools) ──────┐ depends on B1, B2
  ├── B4 (Extract + Screenshot) ────┤ depends on B2
  ├── B5 (Submit + Download + Wait) ┤ depends on B3
  ├── B6 (Three-tier HITL) ─────────┤ depends on B3
  ├── B7 (Desktop integration) ─────┘ depends on B6
  └── B8 (Policy + contracts)

Phase C (MCP Client) ← can start after A6-A8
  ├── C1 (Streamable HTTP transport)
  ├── C2 (Tool discovery + namespaces) ── depends on C1
  ├── C3 (Tool execution + response) ──── depends on C2
  └── C4 (Policy + auth) ──────────────── depends on C2

Phase D (Agent Loop Quality) ← depends on Phase A
  ├── D1 (Sprint contracts) ──┐
  ├── D2 (Context resets) ────┤
  ├── D3 (Evaluator) ─────────┤ depends on D1
  ├── D4 (Refinement loop) ───┘ depends on D3
  ├── D5 (Plan hierarchy)
  ├── D6 (Adaptive verification)
  ├── D7 (Fuzzy error recovery)
  └── D8 (Compaction customization)

Phase E (Production) ← can run parallel with B/C/D
  ├── E1 (Merge branches)
  ├── E2 (OIDC) ──────────┐
  ├── E3 (Simplified API) ─┘ depends on E2 for auth
  └── E4 (Connection draining)

Phase F (Memory & Services) ← depends on E2 for auth
  ├── F1 (Memory Service)
  ├── F2 (OneDrive) ← depends on E2 for EntraID SSO
  └── F3 (Agent Teams) ← depends on D3 (evaluator pattern)

Phase G (Sub-agent improvements) ← depends on Phase A
  ├── G1 (Adaptive steps)
  ├── G2 (Skill nesting)
  ├── G3 (Per-capability budgets)
  └── G4 (Multi-model selection)

Phase H (Operations) ← can run parallel with F/G
  ├── H1 (EventBridge)
  ├── H2 (Task drain)
  ├── H3 (Memory encryption)
  ├── H4 (Checkpoint versioning)
  ├── H5 (Workspace TTL)
  └── H6 (Tool result caching)

Phase I (UI) ← depends on E3 (simplified API)
  ├── I1 (File management)
  ├── I2 (Desktop migration)
  └── I3 (File watching)
```

---

## Execution Tracks (Parallelizable)

These tracks can run concurrently:

**Track 1 — Agent Core:** A1→A5 (plan fixes) → A6→A8 (tool execution) → D1→D3→D4 (loop quality)
**Track 2 — Browser:** B1→B2→B3→B6→B7 (after A6-A8)
**Track 3 — MCP:** C1→C2→C3→C4 (after A6-A8, parallel with Track 2)
**Track 4 — Production:** E1→E2→E3→E4 (can start anytime)
**Track 5 — Memory:** F1 (after E2)
**Track 6 — Operations:** H1→H2 (can start anytime)
