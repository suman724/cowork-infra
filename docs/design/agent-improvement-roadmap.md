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

## Phase A — Plan Quality, Tool Execution & Tooling Expansion

**Goal:** Fix critical gaps in plan+sub-agent execution, improve the tool execution pipeline, expand tooling with browser automation, and enable third-party tool integration via MCP.

**Execution order:** Plan+sub-agent fixes first (quick wins, high impact on task quality), then tool execution improvements, then browser automation, then MCP client last (most complex, builds on everything else).

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

### A9: Browser Automation

**Repo:** `cowork-agent-runtime` (tool_runtime/tools/browser/)
**Design doc:** `browser-automation.md`

11 browser tools using Playwright for web research, form filling, and multi-step workflows.

**What to build:**
- BrowserManager: Playwright lifecycle (lazy launch, idle timeout, session-end cleanup)
- DomService: Accessibility tree extraction with indexed interactive elements
- PageState: Token-efficient page representation for LLM
- 11 tools: Navigate, Click, Type, Select, Scroll, Back, Extract, Screenshot, Submit, Download, Wait
- SensitiveDetector: Password fields, destructive buttons, payment forms
- Three-tier HITL: domain approval → sensitive action detection → submission checkpoints
- User takeover: pause agent, interact with headed browser, resume
- Session persistence: cookies/localStorage saved per workspace
- Session-scoped opt-in: browser tools only when user enables toggle + policy grants `Browser.*`

**Acceptance criteria:**
- Agent can navigate to a URL, extract information, fill forms, click buttons
- HITL approval triggers for new domains, sensitive actions, and form submissions
- User can pause and interact with the browser directly
- Browser state persists across Cowork sessions within the same workspace
- No browser resources allocated until first browser tool call (lazy launch)

### A10: MCP Client

**Repo:** `cowork-agent-runtime` (tool_runtime/mcp/)
**Design doc:** `mcp-client.md`

Enables the agent to use tools from remote MCP servers — third-party APIs, custom tools, enterprise integrations.

**What to build:**
- MCP 2025-11-25 spec: Streamable HTTP transport, session management, tool annotations
- Tool manifest discovery with pagination and list change notifications
- Namespace prefixing: `{serverName}/{toolName}`
- Per-tool timeout, output truncation, response size cap (10MB)
- Policy bundle: `mcpServers` config with `MCP.{serverName}` capability mapping
- Per-server circuit breaker (5 failures → open, 30s → half-open)
- Bearer token auth via Secrets Manager (web) or env var (desktop)
- Response translation: text, structured content, image, audio, resource links, error

**Acceptance criteria:**
- Agent can discover and call tools from a remote MCP server
- MCP tools appear in tool definitions sent to LLM with namespace prefix
- Policy enforcer gates MCP tools the same as built-in tools
- Connection failure doesn't crash the agent — circuit breaker, graceful degradation
- Tool annotations (readOnlyHint, destructiveHint) influence policy decisions
- Unit tests with mock MCP server, integration test with real MCP server

---

## Phase B — Agent Loop Quality

**Goal:** Improve the agent's ability to handle long, complex tasks reliably. Informed by Anthropic's harness design research.

**Why second:** Once tools work well (Phase A), the quality of how the agent plans, evaluates, and iterates becomes the bottleneck.

### B1: Sprint Contracts (Acceptance Criteria per Plan Step)

**Repo:** `cowork-agent-sdk`

Each PlanStep gets testable `acceptanceCriteria` — the agent knows what "done" looks like before starting.

**What to build:**
- Extend `PlanStep` with `acceptance_criteria: list[str]`
- `CreatePlan` tool accepts criteria per step
- Plan rendering shows criteria alongside steps
- Verification phase (or evaluator in B3) checks against criteria

### B2: Context Resets with Structured Handoffs

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`

When context hits 80% capacity, spawn a continuation agent with a structured handoff rather than degrading in a bloated context.

**What to build:**
- Detect context approaching limit (80% of max_context_tokens)
- Generate handoff document: what was accomplished, current state, remaining work, key decisions
- Spawn continuation agent with handoff as initial context
- Original agent completes cleanly after handoff

### B3: Separate Evaluator Agent

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`

Replace single-shot verification with a separate agent that evaluates work against criteria, returns pass/fail with specific feedback.

**What to build:**
- Evaluator agent spawned after task/sprint completion
- Evaluates against acceptance criteria (from B1)
- Returns structured feedback: pass/fail per criterion, specific issues, fix recommendations
- Generator receives feedback and iterates (B4)

### B4: Iterative Refinement Loop

**Repo:** `cowork-agent-sdk`

Generate → evaluate → feedback → regenerate cycle until evaluator passes or max iterations reached.

**What to build:**
- Configurable max iterations (default: 3)
- Each iteration: generator receives evaluator feedback, attempts fixes
- Loop exits when: all criteria pass, max iterations reached, or no progress detected

### B5: Plan Improvements (Sub-plans, Dependencies)

**Repo:** `cowork-agent-sdk`

Currently plans are flat lists. Complex tasks need hierarchy and dependencies.

**What to build:**
- Sub-plans: a step can contain its own nested plan
- Step dependencies: "step 4 depends on step 2 and 3"
- Conditional steps: "step 5 only if step 3 produced errors"

### B6: Adaptive Verification

**Repo:** `cowork-agent-sdk`

Currently verification runs once with a fixed prompt. Can't re-verify or adapt to task type.

**What to build:**
- Re-verification if issues found (loop until pass or max attempts)
- Task-type specific verification prompts (code → run tests, writing → check structure)
- Configurable verification depth

### B7: Error Recovery Fuzzy Matching

**Repo:** `cowork-agent-sdk`

Loop detection uses exact argument matching. Similar but not identical calls aren't detected.

**What to build:**
- Normalize arguments before hashing (sort keys, strip whitespace)
- Fuzzy matching on argument similarity (e.g., same tool + similar path)
- Configurable similarity threshold

### B8: Compaction Prompt Customization

**Repo:** `cowork-agent-sdk`

Summarization prompt is fixed. Different task types benefit from different summarization strategies.

**What to build:**
- Configurable summarization prompt per task type or via COWORK.md
- Preserve different information based on context (code tasks preserve code, research tasks preserve findings)

---

## Phase C — Production Readiness

**Goal:** Enable production deployment for real users.

### C1: Merge Pending Branches

Merge all reviewed branches:
- `fix/plan-step-verification` (agent-sdk)
- `docs/simplified-session-api` (infra)
- `docs/onedrive-storage-backend` (infra)
- `docs/memory-service-hybrid-search` (infra)
- Docker build CI fix (agent-runtime)

### C2: OIDC Authentication

**Repos:** `cowork-session-service`, `cowork-web-app`

Multi-tenant auth for production. JWT validation, OIDC login flow, session ownership from token.

### C3: Simplified Session API

**Repos:** `cowork-session-service`, `cowork-agent-runtime`, `cowork-platform`, `cowork-web-app`
**Design doc:** `simplified-session-api.md`

- Stage 1: `/messages`, `/cancel`, `/approve`, `/stream` endpoints in Session Service
- Stage 2: Web App migration to new endpoints

### C4: Connection Draining

**Repos:** `cowork-session-service`, `cowork-agent-runtime`

Graceful shutdown with in-flight requests. SSE shutdown event, proxy retry vs shutdown detection.

---

## Phase D — Memory & Services

**Goal:** Add persistent cross-session memory and external integrations.

### D1: Memory Service Phase 1

**Repos:** `cowork-memory-service` (new), `cowork-agent-runtime`, `cowork-platform`
**Design doc:** `services/memory-service.md`

Centralized multi-tenant memory with hybrid search (vector + BM25 + RRF).

### D2: OneDrive Integration

**Repos:** `cowork-workspace-service`, `cowork-session-service`, `cowork-web-app`
**Design doc:** `design/onedrive-integration.md`

OneDriveFileStore with Microsoft Graph API. storageBackend model, token custodian in Session Service.

### D3: Agent Teams

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`
**Design doc:** `components/agent-teams.md`

Multi-agent orchestration: lead agent spawns teammates with roles, shared workspace, peer communication, task delegation. Extends sub-agent model into persistent collaborating peers (planner → generator → evaluator pattern from Anthropic research).

---

## Phase E — Sub-agent & Skill Improvements

**Goal:** Improve the quality and flexibility of sub-agents and skills.

### E1: Sub-agent Adaptive Steps

**Repo:** `cowork-agent-runtime`

Dynamic max_steps based on task complexity instead of fixed 10. Estimate from prompt length, plan step complexity, or parent hint.

### E2: Skill Nesting

**Repo:** `cowork-agent-runtime`

Skills calling other skills. Requires dependency resolution and circular reference prevention.

### E3: Per-capability Token Budgets

**Repo:** `cowork-agent-sdk`

Separate budgets for different tool types (e.g., LLM calls vs tool execution). Prevents one expensive operation from consuming the entire session budget.

### E4: Multi-model LLM Selection

**Repo:** `cowork-agent-sdk`

Select model by task complexity from `allowedModels` list. Simple tasks → fast/cheap model, complex tasks → capable model.

---

## Phase F — Operational & Security

**Goal:** Production hardening and operational excellence.

### F1: EventBridge Crash Detection + Lifecycle Migration

**Repos:** `cowork-session-service`, `cowork-infra`

Replace polling-based timeout checks with EventBridge events. Faster crash detection, precise timeouts.

### F2: Version-Aware Task Drain

**Repo:** `cowork-agent-runtime`

Tasks check revision after session ends, exit if outdated. Zero-interruption deploys.

### F3: Persistent Memory Encryption

**Repo:** `cowork-agent-sdk`

Encrypt memory files at rest using OS keychain (macOS Keychain, Windows DPAPI).

### F4: Checkpoint Versioning

**Repo:** `cowork-agent-sdk`

Schema versioning for crash recovery files. Graceful handling of version mismatches.

### F5: Workspace TTL Cleanup

**Repo:** `cowork-workspace-service`

Auto-expire `general` and `cloud` workspaces. Implement the deferred 90-day inactivity purge.

### F6: Tool Result Caching

**Repo:** `cowork-agent-runtime`

Cache repeated tool calls within a task (e.g., same `ReadFile` twice). Invalidate on writes.

---

## Phase G — UI & Polish

**Goal:** Frontend improvements and cross-platform consistency.

### G1: Enhanced File Management

**Repo:** `cowork-web-app`

Tree view, inline editor (Monaco), drag-and-drop upload, multi-file download, file change indicators.

### G2: Desktop App Migration

**Repo:** `cowork-desktop-app`

Refactor IPC handlers to simplified contract (`session:create`, `session:send-message`, etc.). Shared `SessionClient` TypeScript interface.

### G3: File Watching for Patch Preview

**Repo:** `cowork-agent-runtime`

Real-time file change detection for GetPatchPreview. Currently uses in-memory list, Phase 2 adds filesystem watch.

---

## Dependency Graph

```
Phase A (Plan Quality + Tool Execution + Tooling Expansion)
  ├── A1 (Failed status for PlanStep) ──┐
  ├── A2 (Plan context to sub-agents) ──┤
  ├── A3 (Auto plan step update) ───────┤ depends on A1
  ├── A4 (Sub-agent results) ──────────┤
  ├── A5 (Read-only working memory) ───┘
  ├── A6 (Streaming output) ─────────────────────────────────┐
  ├── A7 (Force cancel) ─────────────────────────────────────┤
  ├── A8 (Shell args) ──────────────────────────────────────┤
  ├── A9 (Browser) ──────────────────────────────────────────┤
  └── A10 (MCP) ─────────────────────────────────────────────┘
                                                              │
Phase B (Loop Quality) ──────────────────────────────────────┘
  ├── B1 (Sprint contracts) ──┐
  ├── B2 (Context resets) ────┤
  ├── B3 (Evaluator) ─────────┤ depends on B1
  ├── B4 (Refinement loop) ───┘ depends on B3
  ├── B5 (Plan hierarchy)
  ├── B6 (Adaptive verification)
  ├── B7 (Fuzzy error recovery)
  └── B8 (Compaction customization)

Phase C (Production) ← can run parallel with A/B
  ├── C1 (Merge branches)
  ├── C2 (OIDC) ──────────┐
  ├── C3 (Simplified API) ─┘ depends on C2 for auth
  └── C4 (Connection draining)

Phase D (Memory & Services) ← depends on C2 for auth
  ├── D1 (Memory Service)
  ├── D2 (OneDrive) ← depends on C2 for EntraID SSO
  └── D3 (Agent Teams) ← depends on B3 (evaluator pattern)

Phase E (Sub-agent improvements) ← depends on A1-A5
  ├── E1 (Adaptive steps)
  ├── E2 (Skill nesting)
  ├── E3 (Per-capability budgets)
  └── E4 (Multi-model selection)

Phase F (Operations) ← can run parallel with D/E
  ├── F1 (EventBridge)
  ├── F2 (Task drain)
  ├── F3 (Memory encryption)
  ├── F4 (Checkpoint versioning)
  ├── F5 (Workspace TTL)
  └── F6 (Tool result caching)

Phase G (UI) ← depends on C3 (simplified API)
  ├── G1 (File management)
  ├── G2 (Desktop migration)
  └── G3 (File watching)
```

---

## Execution Tracks (Parallelizable)

These tracks can run concurrently:

**Track 1 — Plan Quality:** A1→A2→A3→A4→A5 → B1→B3→B4
**Track 2 — Tool Execution & Tooling:** A6 (Streaming) → A7 (Force cancel) → A8 (Shell args) → A9 (Browser) → A10 (MCP)
**Track 3 — Production:** C1→C2→C3→C4
**Track 4 — Memory:** D1 (Memory Service)
**Track 5 — Operations:** F1→F2 (can start anytime)
