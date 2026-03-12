# Agent Loop Improvements — Implementation Plan

**Date:** 2026-03-07
**Status:** Implemented — merged to feature branches (cowork-agent-runtime#36, cowork-platform#11, cowork-desktop-app feat/agent-loop-ui-indicators)
**Scope:** 5 features from agent-loop-comparison-report.md (sections 1.3, 2.3/7.1, 7.3, 2.1, 1.1)

---

## Feature 1: Parallel Tool Execution

**Report section:** 1.3
**Problem:** `ToolExecutor.execute_tool_calls()` runs tools sequentially. When the LLM returns multiple independent tool calls (e.g., read 5 files), they execute one at a time.

### Current Code

`tool_executor.py:85-106`:
```python
async def execute_tool_calls(self, calls, task_id, step_id=""):
    results = []
    for call in calls:
        result = await self._execute_single(call, task_id, step_id=step_id)
        results.append(result)
    return results
```

### Design

**Conservative parallelism with grouping.** Not all tool calls are safe to parallelize — file writes to the same path would conflict, shell commands have unpredictable side effects. The solution partitions tool calls into ordered groups where calls within a group run concurrently.

**Parallelization rules:**

| Tool Category | Capability | Parallelizable? |
|--------------|-----------|-----------------|
| ReadFile, ListDirectory, FindFiles, GrepFiles, ViewImage | File.Read | Yes — always safe with other reads |
| WriteFile, EditFile, MultiEdit | File.Write | Yes — only if targeting different file paths |
| DeleteFile | File.Delete | No — serialize (ordering matters) |
| CreateDirectory, MoveFile | File.Write | No — serialize (filesystem structure changes) |
| RunCommand | Shell.Exec | No — serialize (unpredictable side effects) |
| ExecuteCode | Code.Execute | No — serialize (writes to filesystem) |
| HttpRequest | Network.Http | No — serialize (could be POST/PUT/DELETE) |
| FetchUrl, WebSearch | Network read | Yes — safe with other reads/fetches |

**Grouping algorithm:**

```
Input:  [ReadFile("/a"), ReadFile("/b"), WriteFile("/c"), ReadFile("/d"), GrepFiles("/e")]
Output: [
  Group 1: [ReadFile("/a"), ReadFile("/b")]   ← parallel
  Group 2: [WriteFile("/c")]                  ← serial
  Group 3: [ReadFile("/d"), GrepFiles("/e")]  ← parallel
]
```

1. Iterate tool calls in order
2. Accumulate parallelizable calls into a "batch"
3. When hitting a non-parallelizable call, flush the current batch as a group, then emit the serial call as its own group
4. Special case: multiple File.Write calls to *different* paths can share a batch

**Agent-internal tools** (`ReactLoop._execute_tools`): stay sequential. They mutate shared WorkingMemory state (TaskTracker, CreatePlan, notes).

### Implementation

**File: `src/agent_host/loop/tool_executor.py`**

```python
# New constant: tools safe to run in parallel
_PARALLELIZABLE_TOOLS = {
    "ReadFile", "ListDirectory", "FindFiles", "GrepFiles", "ViewImage",
    "FetchUrl", "WebSearch",
}

# File.Write tools that are parallelizable if targeting different paths
_PARALLEL_IF_DIFFERENT_PATH = {"WriteFile", "EditFile", "MultiEdit"}


def _partition_parallel_groups(
    self, calls: list[ToolCallMessage]
) -> list[list[ToolCallMessage]]:
    """Partition tool calls into ordered groups for parallel/serial execution."""
    groups: list[list[ToolCallMessage]] = []
    current_batch: list[ToolCallMessage] = []
    current_batch_paths: set[str] = set()  # track write paths in batch

    for call in calls:
        if call.name in _PARALLELIZABLE_TOOLS:
            current_batch.append(call)
        elif call.name in _PARALLEL_IF_DIFFERENT_PATH:
            path = call.arguments.get("path", "")
            if path and path not in current_batch_paths:
                current_batch.append(call)
                current_batch_paths.add(path)
            else:
                # Path conflict or unknown — flush and serialize
                if current_batch:
                    groups.append(current_batch)
                    current_batch = []
                    current_batch_paths = set()
                groups.append([call])
        else:
            # Non-parallelizable — flush batch, then serialize this call
            if current_batch:
                groups.append(current_batch)
                current_batch = []
                current_batch_paths = set()
            groups.append([call])

    if current_batch:
        groups.append(current_batch)

    return groups


async def execute_tool_calls(
    self, calls: list[ToolCallMessage], task_id: str, step_id: str = ""
) -> list[ToolCallResult]:
    """Execute tool calls with parallel grouping."""
    groups = self._partition_parallel_groups(calls)
    results: list[ToolCallResult] = []

    for group in groups:
        if len(group) == 1:
            results.append(
                await self._execute_single(group[0], task_id, step_id=step_id)
            )
        else:
            group_results = await asyncio.gather(
                *(self._execute_single(c, task_id, step_id=step_id) for c in group)
            )
            results.extend(group_results)

    return results
```

### Files Changed

| File | Change |
|------|--------|
| `src/agent_host/loop/tool_executor.py` | Add `_partition_parallel_groups()`, update `execute_tool_calls()` |
| `tests/unit/agent_host/test_tool_executor.py` | Test parallel grouping logic, verify result ordering |

### Risks & Mitigations

- **Approval gate**: Two tools needing approval fire concurrent approval requests. Safe — `ApprovalGate` uses per-request Futures keyed by `approval_id`.
- **File change tracker**: `_capture_pre_state` / `_record_file_changes` called concurrently. Safe — asyncio is single-threaded, no true parallelism, just concurrent I/O waits.
- **Event ordering**: `tool_requested`/`tool_completed` events may interleave for parallel tools. Safe — desktop app matches events by `tool_call_id`, not arrival order.
- **Error isolation**: One tool failure in a parallel group must not cancel others. `asyncio.gather(return_exceptions=False)` is fine because `_execute_single` already catches all exceptions internally and returns a `ToolCallResult` with `status="failed"`.

---

## Feature 2: Prompt Caching Optimization

**Report sections:** 2.3, 7.1
**Problem:** Message ordering isn't optimized for LLM provider prompt caching. Volatile content (working memory) is injected early in the message list, breaking the cache prefix every turn.

### Background

LLM providers (Anthropic, OpenAI) cache the longest matching prefix of the message list. If the first N tokens are identical between consecutive calls, the provider serves them from cache — cheaper and faster. Any change in the prefix invalidates everything after it.

### Current Ordering

From `ReactLoop._build_messages()`:
```
[system prompt] → [persistent memory] → [working memory] → [conversation history]
```

**Problem:** Working memory changes every turn (task status updates, plan modifications). Persistent memory can also change when the agent calls SaveMemory. Both are injected at position 1 (right after system prompt), breaking the cache prefix immediately.

### New Ordering

```
[system prompt]                     ← STABLE (set at session start, never changes mid-task)
[persistent memory (MEMORY.md)]     ← SEMI-STABLE (changes only on SaveMemory calls)
... conversation history ...        ← GROWS each turn (but prefix is stable)
[working memory]                    ← VOLATILE (changes every turn — at the END)
[error recovery prompts]            ← CONDITIONAL (only when triggered)
```

**Key insight:** Tool definitions are passed as a separate `tools` parameter to the OpenAI API, not in the message list. Providers include them in the cache prefix automatically. Since our tool set is stable per session, this is already optimal.

### Implementation

**File: `src/agent_host/loop/react_loop.py` — `_build_messages()`**

Current flow:
1. Render persistent memory → estimate overhead
2. Render working memory → estimate overhead
3. Compact conversation history (budget = 90% max tokens - injection overhead)
4. Insert both injections at position 1 (right after system prompt)

New flow:
1. Render persistent memory → estimate overhead
2. Render working memory → estimate overhead
3. Compact conversation history (budget = 90% max tokens - injection overhead)
4. Insert persistent memory at position 1 (stable, right after system prompt)
5. Append working memory at the END of messages (volatile, after conversation)
6. Append error recovery prompts at the very end (conditional)

```python
def _build_messages(self, task_id, step, step_id):
    injection_overhead = 0
    persistent_memory_text = None
    working_memory_text = None

    # Persistent memory (MEMORY.md) — semi-stable
    if self._h.memory_manager:
        mem = self._h.memory_manager.render_memory_context()
        if mem:
            persistent_memory_text = mem
            injection_overhead += estimate_message_tokens(
                {"role": "system", "content": mem}
            )

    # Working memory (task tracker + plan + notes) — volatile
    if self._h.working_memory:
        wm = self._h.working_memory.render()
        if wm:
            working_memory_text = wm
            injection_overhead += estimate_message_tokens(
                {"role": "system", "content": wm}
            )

    # Compact conversation history
    compaction_budget = int(self._h.max_context_tokens * 0.9) - injection_overhead
    messages = self._h.thread.build_llm_payload(compaction_budget, self._h.compactor)

    # Insert persistent memory right after system prompt (stable prefix)
    if persistent_memory_text:
        messages.insert(1, {"role": "system", "content": persistent_memory_text})

    # Append working memory at the end (volatile — doesn't break prefix)
    if working_memory_text:
        messages.append({"role": "system", "content": working_memory_text})

    # Error recovery at the very end
    er = self._h.error_recovery
    if er.detect_loop():
        prompt = er.build_loop_break_prompt()
        self._h.thread.add_system_injection(prompt)
        messages.append({"role": "system", "content": prompt})
    elif er.should_inject_reflection():
        prompt = er.build_reflection_prompt()
        self._h.thread.add_system_injection(prompt)
        messages.append({"role": "system", "content": prompt})

    return messages
```

### Anthropic Cache Control Hints

For Anthropic's API, you can mark cache breakpoints with `cache_control: {"type": "ephemeral"}` on the last message of the stable prefix. This tells the provider to cache everything up to that point.

Add optional cache control annotation in `LLMClient`:
```python
# In _do_stream, before sending:
if self._enable_cache_hints and messages:
    # Find the last system message before conversation history starts
    # and add cache_control hint
    ...
```

This is provider-specific and can be added as a follow-up. The message reordering alone provides the benefit for all providers.

### Files Changed

| File | Change |
|------|--------|
| `src/agent_host/loop/react_loop.py` | Reorder `_build_messages()` — persistent memory at position 1, working memory at end |
| `tests/unit/agent_host/test_agent_loop.py` | Update memory injection ordering tests |

### Cache Hit Measurement

To validate improvement, add a log line in `LLMClient._do_stream()` that records `usage.prompt_tokens_details.cached_tokens` (returned by Anthropic/OpenAI when caching is active). This tells us what percentage of the prompt was served from cache.

---

## Feature 3: Plan Mode

**Report section:** 7.3
**Problem:** The agent has no concept of planning vs executing phases. Complex tasks jump straight into execution without structured analysis.

### Design

Plan mode is a **runtime state** on the agent loop, not just a startup flag. Three entry paths:

| Entry | Mechanism | Behavior |
|-------|-----------|----------|
| **User-explicit** | `taskOptions.planOnly: true` in StartTask | Hard lock. Read-only tools for entire task. Agent cannot exit plan mode. |
| **LLM-initiated** | Agent calls `EnterPlanMode` tool | Soft lock. Agent enters plan mode, explores with read-only tools, builds a plan, then calls `ExitPlanMode` to switch to execution. |
| **System prompt guided** | Instructions in system prompt | Encourages the agent to call `EnterPlanMode` for complex multi-step tasks. Not a mechanism — just makes LLM-initiated mode work well. |

**LLM-initiated plan mode** is the primary feature. The agent autonomously decides whether a task needs planning.

### State Machine

```
                    StartTask
                       │
                       ▼
              ┌─────────────────┐
              │   EXECUTING     │ ← default state
              │  (all tools)    │
              └────────┬────────┘
                       │ EnterPlanMode tool call
                       ▼
              ┌─────────────────┐
              │   PLANNING      │
              │ (read-only      │
              │  tools only)    │
              └────────┬────────┘
                       │ ExitPlanMode tool call
                       ▼
              ┌─────────────────┐
              │   EXECUTING     │
              │  (all tools)    │
              └─────────────────┘

Exception: planOnly=true → starts in PLANNING, cannot transition to EXECUTING.
```

### Plan-Mode Tool Restrictions

When in plan mode, `ToolExecutor` filters available tools:

**Allowed in plan mode:**
- `ReadFile`, `ListDirectory`, `FindFiles`, `GrepFiles`, `ViewImage` — File.Read
- `FetchUrl`, `WebSearch` — read-only network
- All agent-internal tools — TaskTracker, CreatePlan, memory tools, EnterPlanMode, ExitPlanMode

**Blocked in plan mode:**
- `WriteFile`, `EditFile`, `MultiEdit`, `DeleteFile`, `CreateDirectory`, `MoveFile` — File.Write/Delete
- `RunCommand` — Shell.Exec (side effects)
- `HttpRequest` — could be POST/PUT/DELETE
- `ExecuteCode` — writes to filesystem, runs arbitrary code

Blocked tools are removed from `get_tool_definitions()` so the LLM never sees them. If the LLM somehow calls a blocked tool (hallucinated name), `_execute_single` returns a denial result.

### Desktop App Notification

When plan mode state changes, emit a `plan_mode_changed` SessionEvent:

```json
{
  "type": "plan_mode_changed",
  "taskId": "task-123",
  "planMode": true,
  "source": "agent"  // or "user" for planOnly=true
}
```

The desktop app receives this via `push:session-event` and can show a visual indicator (e.g., "Planning..." badge on the conversation header, blue accent on the message area).

### Plan Storage in Working Memory

The plan created during plan mode is stored in WorkingMemory's existing `Plan` component. This is already injected as a system message every turn, so the agent sees its own plan during execution.

Flow:
1. Agent enters plan mode → calls `CreatePlan` tool to structure its plan
2. Plan is stored in `WorkingMemory.plan` (already exists)
3. Agent exits plan mode → plan persists in WorkingMemory
4. During execution, WorkingMemory renders the plan every turn — agent follows it
5. Agent can update the plan during execution via `CreatePlan` (already supported)

### Agent-Internal Tools

**`EnterPlanMode`** — no arguments, returns `{"status": "success", "planMode": true}`

```python
# In AgentToolHandler
async def _handle_enter_plan_mode(self, arguments, task_id):
    if self._plan_mode_locked:
        return {"status": "error", "message": "Already in hard plan-only mode"}
    self._plan_mode = True
    if self._on_plan_mode_changed:
        self._on_plan_mode_changed(True, "agent")
    return {"status": "success", "planMode": True}
```

**`ExitPlanMode`** — no arguments, returns `{"status": "success", "planMode": false}`

```python
async def _handle_exit_plan_mode(self, arguments, task_id):
    if self._plan_mode_locked:
        return {"status": "error", "message": "Cannot exit plan-only mode"}
    self._plan_mode = False
    if self._on_plan_mode_changed:
        self._on_plan_mode_changed(False, "agent")
    return {"status": "success", "planMode": False}
```

Tool definitions:
```python
{
    "type": "function",
    "function": {
        "name": "EnterPlanMode",
        "description": "Switch to plan mode. In plan mode, only read-only tools "
                       "are available. Use this to explore and analyze before making "
                       "changes. Call ExitPlanMode when ready to execute.",
        "parameters": {"type": "object", "properties": {}}
    }
}
```

### System Prompt Addition

Add to `_BASE_SYSTEM_PROMPT` guidelines:

```
- For complex multi-step tasks, enter plan mode first (EnterPlanMode tool) to
  explore the workspace and create a structured plan before making changes.
  Exit plan mode (ExitPlanMode) when ready to execute your plan.
```

### Implementation

**File: `src/agent_host/loop/tool_executor.py`**

```python
# New constant
PLAN_MODE_ALLOWED_TOOLS = {
    "ReadFile", "ListDirectory", "FindFiles", "GrepFiles", "ViewImage",
    "FetchUrl", "WebSearch",
}

class ToolExecutor:
    def __init__(self, ..., plan_mode: bool = False, plan_mode_locked: bool = False):
        ...
        self._plan_mode = plan_mode
        self._plan_mode_locked = plan_mode_locked

    @property
    def plan_mode(self) -> bool:
        return self._plan_mode

    @plan_mode.setter
    def plan_mode(self, value: bool) -> None:
        if not self._plan_mode_locked:
            self._plan_mode = value

    def get_tool_definitions(self) -> list[dict[str, Any]]:
        """Return tool definitions, filtered for plan mode if active."""
        all_defs = [...]  # existing logic
        if self._plan_mode:
            return [d for d in all_defs
                    if d["function"]["name"] in PLAN_MODE_ALLOWED_TOOLS]
        return all_defs

    async def _execute_single(self, call, task_id, step_id=""):
        tool_name = call.name
        # Plan mode enforcement
        if self._plan_mode and tool_name not in PLAN_MODE_ALLOWED_TOOLS:
            return ToolCallResult(
                tool_call_id=call.id,
                tool_name=tool_name,
                status="denied",
                result_text=json.dumps({
                    "status": "denied",
                    "error": {
                        "code": "PLAN_MODE_RESTRICTED",
                        "message": f"{tool_name} is not available in plan mode. "
                                   "Call ExitPlanMode first to enable write operations."
                    }
                }),
            )
        # ... existing logic
```

**File: `src/agent_host/loop/agent_tools.py`**

Add `EnterPlanMode` and `ExitPlanMode` to the agent tool handler. Wire plan mode state to ToolExecutor and event emitter.

**File: `src/agent_host/session/session_manager.py`**

Parse `taskOptions.planOnly` from StartTask params. When true, set `plan_mode=True, plan_mode_locked=True` on ToolExecutor.

**File: `src/agent_host/loop/system_prompt.py`**

Add plan mode guidance to base system prompt.

**File: `src/agent_host/events/event_emitter.py`**

Add `emit_plan_mode_changed(task_id, plan_mode, source)` method.

### Files Changed

| File | Change |
|------|--------|
| `src/agent_host/loop/tool_executor.py` | Add `plan_mode` flag, filter tool defs, deny blocked tools |
| `src/agent_host/loop/agent_tools.py` | Add `EnterPlanMode`, `ExitPlanMode` tools |
| `src/agent_host/session/session_manager.py` | Parse `planOnly` from taskOptions |
| `src/agent_host/loop/system_prompt.py` | Add plan mode guidance to system prompt |
| `src/agent_host/events/event_emitter.py` | Add `plan_mode_changed` event |
| `src/agent_host/loop/loop_runtime.py` | Expose plan_mode property from ToolExecutor |
| Desktop app: `use-session-events.ts` | Handle `plan_mode_changed` event |
| Desktop app: `session-store.ts` | Add `planMode: boolean` to task state |
| Desktop app: conversation UI | Show plan mode indicator |
| Tests | Plan mode filtering, tool denial, enter/exit transitions, locked mode |

---

## Feature 4: LLM-Based Compaction — Hybrid Observation Masking + Summarization

**Report section:** 2.1
**Problem:** `DropOldestCompactor` completely loses all information from dropped messages. Early conversation context (file paths discovered, decisions, error patterns) vanishes permanently.

### Design — Two-Phase Hybrid

**Phase 1: Observation Masking** (no LLM call, fast, always applied first)
- Replace old tool *result* messages with one-line summaries
- Preserve assistant's tool_call messages (the LLM needs to see *what* it decided to do)
- Only mask tool results older than the recency window
- Typically achieves 50-70% compression (tool outputs are the largest messages)

**Phase 2: LLM Summarization** (one LLM call, only when masking isn't enough)
- When observation masking alone can't fit the budget, generate a structured summary
- Summarize the oldest masked messages into a single system message
- Insert the summary in place of the dropped messages
- Use the same LLM or a configured cheaper/faster model

### Observation Masking Examples

Before masking:
```json
{"role": "tool", "name": "ReadFile", "content": "{\"status\": \"success\", \"output\": \"import os\\nimport sys\\n... 200 lines of Python code ...\"}"}
```

After masking:
```json
{"role": "tool", "name": "ReadFile", "content": "[ReadFile: success, 200 lines]"}
```

**Masking heuristics by tool:**

| Tool | Masked Summary |
|------|---------------|
| ReadFile | `[ReadFile {path}: {N} lines]` |
| WriteFile | `[WriteFile {path}: {N} lines written]` |
| EditFile | `[EditFile {path}: replacement applied]` |
| ListDirectory | `[ListDirectory {path}: {N} entries]` |
| FindFiles | `[FindFiles: {N} matches]` |
| GrepFiles | `[GrepFiles "{pattern}": {N} matches]` |
| RunCommand | `[RunCommand: exit {code}, {N} lines output]` |
| FetchUrl | `[FetchUrl {domain}: {N} chars]` |
| Other | `[{tool_name}: {status}, {N} chars]` |

### LLM Summarization Prompt

```
Summarize the following conversation segment. This summary will replace
the original messages in the context window, so it must preserve all
information needed to continue the task correctly.

Preserve:
- File paths and directories examined or modified
- Key decisions made and their reasoning
- Errors encountered and resolutions
- Data values, calculations, or results that may be referenced later
- Current approach and strategy

Format as a concise structured summary (200-400 words max).

Conversation segment to summarize:
{messages}
```

### Architecture

**New class: `HybridCompactor`** implementing `ContextCompactor`

The `ContextCompactor` protocol has a synchronous `compact()` method. LLM summarization is async. Solution: the compactor pre-computes the summary asynchronously before `compact()` is called.

```python
class HybridCompactor(ContextCompactor):
    """Hybrid compaction: observation masking + LLM summarization."""

    def __init__(
        self,
        recency_window: int = 20,
        mask_only: bool = False,  # disable LLM summarization
    ) -> None:
        self._recency_window = recency_window
        self._mask_only = mask_only
        self._cached_summary: str | None = None
        self._summary_covers_up_to: int = 0  # message index

    def compact(self, messages: list[dict], budget_tokens: int) -> list[dict]:
        """Synchronous compaction: masking + cached summary."""
        # Phase 1: observation masking
        masked = self._mask_old_observations(messages)
        total = sum(estimate_message_tokens(m) for m in masked)
        if total <= budget_tokens:
            return masked

        # Phase 2: apply cached summary if available
        if self._cached_summary:
            return self._apply_cached_summary(masked, budget_tokens)

        # Fallback: drop-oldest (same as current behavior)
        return DropOldestCompactor(self._recency_window).compact(
            masked, budget_tokens
        )

    async def precompute_summary(
        self,
        messages: list[dict],
        budget_tokens: int,
        llm_client: LLMClient,
    ) -> None:
        """Async pre-computation: generate LLM summary if needed."""
        masked = self._mask_old_observations(messages)
        total = sum(estimate_message_tokens(m) for m in masked)
        if total <= budget_tokens or self._mask_only:
            return  # masking is sufficient, no summary needed

        # Identify messages to summarize
        to_summarize = self._select_for_summary(masked, budget_tokens)
        if not to_summarize:
            return

        self._cached_summary = await self._generate_summary(
            to_summarize, llm_client
        )

    def _mask_old_observations(self, messages):
        """Replace old tool results with one-line summaries."""
        cutoff = len(messages) - self._recency_window
        result = []
        for i, msg in enumerate(messages):
            if i > 0 and i < cutoff and msg.get("role") == "tool":
                tool_name = msg.get("name", "tool")
                content = msg.get("content", "")
                masked_content = self._mask_tool_output(tool_name, content)
                result.append({**msg, "content": masked_content})
            else:
                result.append(msg)
        return result

    def _mask_tool_output(self, tool_name, content):
        """Generate a one-line summary of a tool output without LLM."""
        try:
            data = json.loads(content)
            status = data.get("status", "success")
            output = data.get("output", "")
        except (json.JSONDecodeError, TypeError):
            output = str(content)
            status = "success"

        if status == "denied":
            return f"[{tool_name}: denied]"
        if status == "failed":
            err = data.get("error", {}).get("message", "unknown error")
            return f"[{tool_name}: failed — {err[:80]}]"

        lines = output.count("\n") + 1 if output else 0
        chars = len(output)
        return f"[{tool_name}: {status}, {lines} lines / {chars} chars]"
```

### Integration in ReactLoop

`_build_messages()` becomes async to support summary pre-computation:

```python
async def _build_messages(self, task_id, step, step_id):
    # ... compute injection overhead ...

    compaction_budget = int(self._h.max_context_tokens * 0.9) - injection_overhead

    # Pre-compute LLM summary if hybrid compactor needs it
    compactor = self._h.compactor
    if hasattr(compactor, "precompute_summary"):
        all_messages = self._h.thread.build_llm_payload(
            compaction_budget, compactor=None  # raw, uncompacted
        )
        await compactor.precompute_summary(
            all_messages, compaction_budget, self._h._llm_client
        )

    messages = self._h.thread.build_llm_payload(compaction_budget, compactor)
    # ... rest of method ...
```

This means `run()` calls `await self._build_messages(...)` instead of `self._build_messages(...)`.

### Configuration

```python
# config.py
compaction_strategy: str = "hybrid"  # "drop_oldest" | "hybrid"
compaction_llm_summary: bool = True  # enable LLM summarization phase
```

### Files Changed

| File | Change |
|------|--------|
| `src/agent_sdk/thread/compactor.py` | Add `HybridCompactor` class |
| `src/agent_sdk/loop/react_loop.py` | Make `_build_messages` async, call `precompute_summary` |
| `src/agent_host/session/session_manager.py` | Instantiate `HybridCompactor` based on config |
| `src/agent_host/config.py` | Add `compaction_strategy`, `compaction_llm_summary` config |
| Tests | Observation masking accuracy, summarization flow, fallback to drop-oldest |

### Risks & Mitigations

- **LLM summarization cost**: One extra LLM call per compaction. Mitigated by: only triggered when masking isn't enough (typically after 15-20+ tool calls), summary is cached and reused until more messages accumulate.
- **Summary quality**: LLM may miss important context. Mitigated by: observation masking preserves tool call structure (assistant messages kept intact), summary only replaces the tool *outputs*.
- **Latency**: Summary generation adds one LLM round-trip. Mitigated by: only happens when approaching context limit, which is already a slow path.

---

## Feature 5: Verification Phase

**Report section:** 1.1
**Problem:** The agent loop terminates when the LLM says "stop" without systematically verifying its work. The agent may declare success without validation.

**Context:** Cowork is for business user task automation (data processing, document generation, API integrations, file management), not just code generation. Verification must be domain-agnostic.

### Design — Self-Verification via LLM

Instead of running a hardcoded shell command, the verification phase asks the LLM itself to review its work. This is the "gather → act → verify" pattern adapted for general tasks.

**Flow:**

```
Agent completes task (stop_reason="stop", no tool calls)
         │
         ▼
┌─────────────────────┐
│ Inject verification  │
│ prompt into thread   │
│ (system message)     │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ LLM reviews its own │  ← agent can use read-only tools to check
│ work, checks output │    (re-read files, list directories, etc.)
└──────────┬──────────┘
           │
     ┌─────┴─────┐
     │           │
  Issues      All good
  found         │
     │           ▼
     │      Task completes
     ▼      (reason: "completed")
┌──────────┐
│ LLM gets │
│ more     │  ← up to max_verify_steps additional steps
│ steps to │
│ fix      │
└──────┬───┘
       │
  Retries exceeded?
       │
  ┌────┴────┐
  No       Yes
  │         │
  ▼         ▼
 Loop    Task completes
 back    (reason: "verification_failed")
```

### Verification Prompt

Default verification prompt (injected as system message after agent signals completion):

```
VERIFICATION: Before confirming completion, review your work:

1. Re-read the original request and compare with what you delivered
2. Check any files you created or modified — verify content is correct
3. If you performed calculations or data transformations, spot-check the results
4. Confirm nothing was missed from the original request

Use read-only tools (ReadFile, ListDirectory, etc.) to verify.
If everything is correct, confirm you are done.
If you find issues, fix them before completing.
```

### Custom Verification Instructions

Users can provide task-specific verification instructions via:

**1. COWORK.md (workspace-level):**
```markdown
## Verification
After completing tasks, verify:
- Output files exist and are non-empty
- CSV files have correct headers
- JSON files are valid
```

**2. taskOptions (per-task):**
```json
{
  "taskOptions": {
    "verifyInstructions": "Verify the output Excel file has all 12 monthly sheets and the summary sheet totals match."
  }
}
```

When custom instructions are provided, they replace the "spot-check" section of the default prompt:

```
VERIFICATION: Before confirming completion, review your work:

1. Re-read the original request and compare with what you delivered
2. Verify: {custom instructions}
3. Confirm nothing was missed from the original request

Use read-only tools (ReadFile, ListDirectory, etc.) to verify.
If everything is correct, confirm you are done.
If you find issues, fix them before completing.
```

### Implementation

**New module: `src/agent_host/loop/verification.py`**

```python
@dataclass
class VerificationConfig:
    """Configuration for the post-completion verification phase."""
    enabled: bool = True
    max_verify_steps: int = 3     # additional steps for verification + fixing
    custom_instructions: str = ""  # task-specific verification instructions

    _DEFAULT_PROMPT = (
        "VERIFICATION: Before confirming completion, review your work:\n\n"
        "1. Re-read the original request and compare with what you delivered\n"
        "2. Check any files you created or modified — verify content is correct\n"
        "3. If you performed calculations or data transformations, "
        "spot-check the results\n"
        "4. Confirm nothing was missed from the original request\n\n"
        "Use read-only tools (ReadFile, ListDirectory, etc.) to verify.\n"
        "If everything is correct, confirm you are done.\n"
        "If you find issues, fix them before completing."
    )

    _CUSTOM_PROMPT_TEMPLATE = (
        "VERIFICATION: Before confirming completion, review your work:\n\n"
        "1. Re-read the original request and compare with what you delivered\n"
        "2. Verify: {instructions}\n"
        "3. Confirm nothing was missed from the original request\n\n"
        "Use read-only tools (ReadFile, ListDirectory, etc.) to verify.\n"
        "If everything is correct, confirm you are done.\n"
        "If you find issues, fix them before completing."
    )

    def build_prompt(self) -> str:
        if self.custom_instructions:
            return self._CUSTOM_PROMPT_TEMPLATE.format(
                instructions=self.custom_instructions
            )
        return self._DEFAULT_PROMPT
```

**Integration in `ReactLoop.run()`:**

```python
async def run(self, task_id: str) -> LoopResult:
    step = 0
    last_text = ""
    verification_injected = False

    while step < self._max_steps:
        # ... existing step logic (steps 1-6) ...

        # 6. Natural termination check
        if not response.tool_calls and response.stop_reason == "stop":
            # Verification phase
            if (
                self._verification
                and self._verification.enabled
                and not verification_injected
            ):
                # Inject verification prompt — give agent more steps
                verification_injected = True
                prompt = self._verification.build_prompt()
                self._h.thread.add_system_injection(prompt)
                self._h.emit_verification_started(task_id)
                # Don't return — continue the loop so the agent can verify
                continue

            # Agent confirmed completion (or verification not configured)
            if verification_injected:
                self._h.emit_verification_completed(task_id, passed=True)
            return LoopResult(
                reason="completed", text=last_text, step_count=step
            )

        # 7-8. Execute tools + error tracking (existing) ...

    # Step limit reached
    return LoopResult(
        reason="max_steps_exceeded", text=last_text, step_count=step
    )
```

**Key insight:** We don't need a separate "verification loop" or retry counter. The verification prompt is injected once. The agent either:
- Confirms everything is good → next turn has no tool calls, stop_reason="stop" → completes
- Finds issues → uses tools to fix → eventually confirms → completes
- Runs out of steps → max_steps_exceeded (existing behavior)

The `max_verify_steps` from config translates to bumping `self._max_steps` by that amount when verification is injected:
```python
if not verification_injected:
    verification_injected = True
    self._max_steps += self._verification.max_verify_steps
    # ... inject prompt ...
```

### Events

```python
# event_emitter.py
def emit_verification_started(self, task_id: str) -> None: ...
def emit_verification_completed(self, task_id: str, passed: bool) -> None: ...
```

Desktop app shows: "Verifying..." indicator during the verification phase.

### Configuration Sources

| Source | Field | Scope |
|--------|-------|-------|
| `AgentHostConfig` | `verification_enabled: bool = True` | Global default |
| `taskOptions` | `verifyInstructions: str` | Per-task |
| `taskOptions` | `skipVerification: bool` | Per-task opt-out |
| COWORK.md | `## Verification` section | Per-workspace |

Priority: `taskOptions.skipVerification` > `taskOptions.verifyInstructions` > COWORK.md > global default.

### Files Changed

| File | Change |
|------|--------|
| `src/agent_host/loop/verification.py` | New module: VerificationConfig |
| `src/agent_host/loop/react_loop.py` | Inject verification prompt after natural completion |
| `src/agent_host/session/session_manager.py` | Parse verification config from taskOptions + COWORK.md |
| `src/agent_host/config.py` | Add `verification_enabled` config |
| `src/agent_host/events/event_emitter.py` | Add verification events |
| Desktop app: `use-session-events.ts` | Handle verification events |
| Tests | Verification injection, step budget extension, skip verification |

---

## Implementation Order

| Order | Feature | Scope | Dependencies |
|-------|---------|-------|-------------|
| 1 | **Parallel tool execution** | ~150 lines | None — isolated to ToolExecutor |
| 2 | **Prompt caching optimization** | ~50 lines changed | None — message reordering only |
| 3 | **Plan mode** | ~250 lines | None — new tools + tool filtering |
| 4 | **Verification phase** | ~150 lines | None — prompt injection + step budget |
| 5 | **LLM-based compaction** | ~300 lines | Feature 2 (stable prefix ordering) |

Features 1-4 are independent and could be done in parallel branches. Feature 5 depends on feature 2 (prefix must be stable before optimizing compaction).

### PR Strategy

Two PRs per feature:
1. **Agent runtime PR** — core implementation + unit tests
2. **Desktop app PR** (features 3, 4, 5 only) — event handling + UI indicators

Or batch into two larger PRs:
1. **Agent runtime** — all 5 features
2. **Desktop app** — plan mode indicator + verification indicator
