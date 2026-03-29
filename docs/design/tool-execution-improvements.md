# Tool Execution Improvements — Design Doc

**Status:** Implementation Ready
**Scope:** cowork-agent-runtime, cowork-agent-sdk, cowork-platform
**Date:** 2026-03-28
**Roadmap:** Phase A, items A6-A8
**Branch:** `feature/phase-a-implementation` (single branch for all Phase A work)

---

## Overview

Three improvements to the tool execution pipeline that make agents more responsive, safer, and more precisely governed. All three modify the existing `RunCommand` / `ToolExecutor` / `PolicyEnforcer` code paths.

---

## A3: Streaming Tool Output

### Problem

Long-running shell commands block until completion. The user sees nothing during a `npm install` (30s), `make build` (60s+), or `pytest` (variable). The LLM also can't react to intermediate output — it must wait for the full result.

### Current Behavior

```
RunCommand("npm install")
  → asyncio.create_subprocess_exec()
  → stdout.read() blocks until process exits
  → return full output as single string
```

### Proposed Behavior

```
RunCommand("npm install")
  → asyncio.create_subprocess_exec()
  → read stdout line-by-line
  → emit tool_output_chunk event per line (or batch of lines)
  → accumulate full output for final tool result
  → return full output as single string (unchanged for LLM)
```

### Changes

**New event type:** `tool_output_chunk`

```json
{
    "type": "tool_output_chunk",
    "toolCallId": "tc_123",
    "toolName": "RunCommand",
    "content": "added 1247 packages in 32s\n",
    "taskId": "task_456"
}
```

This event is emitted to the SSE/event stream for the frontend to display. It does NOT go into the message thread — the LLM only sees the final accumulated result.

**File:** `cowork-agent-runtime/src/tool_runtime/tools/shell/run_command.py`

The `RunCommand` tool currently reads stdout/stderr after process completion:

```python
# Current
stdout, stderr = await process.communicate()
```

Change to line-by-line streaming:

```python
# Proposed
output_lines = []
async for line in process.stdout:
    decoded = line.decode("utf-8", errors="replace")
    output_lines.append(decoded)
    if on_output_chunk:
        on_output_chunk(decoded)

await process.wait()
full_output = "".join(output_lines)
```

**Callback plumbing:**

The `on_output_chunk` callback flows from:
1. `ToolExecutor.execute_tool_calls()` — creates callback that emits `tool_output_chunk` event
2. `ToolRouter.execute()` — passes callback to tool via `ExecutionContext`
3. `RunCommand.execute()` — calls callback per line

**ExecutionContext extension:**

```python
@dataclass
class ExecutionContext:
    workspace_dir: str | None = None
    on_output_chunk: Callable[[str], None] | None = None  # NEW
```

**Event filtering for `/stream`:**

`tool_output_chunk` should be in the frontend event allow-list (from `simplified-session-api.md`). Users see real-time command output.

### What Does NOT Change

- The final tool result in the message thread is the full accumulated output (same as today)
- Output truncation still applies to the final result (80/20 head/tail)
- Artifact extraction still applies for large outputs (>10KB)
- Timeout behavior unchanged — process killed after timeout regardless of streaming
- LLM sees the same final result — streaming is a frontend/UX improvement only

### Tests

- Unit: RunCommand with streaming callback — verify chunks emitted, final result correct
- Unit: RunCommand without callback — backward compatible, no streaming
- Unit: Timeout during streaming — process killed, partial output returned
- Integration: Long-running command streams output to SSE in real-time

---

## A4: Force Cancellation with Hard Timeout

### Problem

Tool cancellation is cooperative. The `cancel_event` is set, and the agent loop checks it at the next iteration boundary. But a tool that's currently executing (e.g., a shell command stuck in an infinite loop) won't see the cancellation until it returns. There's no way to kill a runaway tool.

### Current Behavior

```
User clicks Cancel
  → cancel_event.set()
  → ReactLoop checks cancel_event at top of next iteration
  → If tool is mid-execution, wait for it to finish (no timeout)
```

For `RunCommand`, there IS a timeout (default 300s), but:
- It applies to the command itself, not to the cancellation
- If the user cancels, the command still runs until its own timeout
- No way to interrupt a command that's within its timeout but the user wants to stop

### Proposed Behavior

```
User clicks Cancel
  → cancel_event.set()
  → ToolExecutor checks cancel_event during tool execution
  → If tool supports cancellation: signal the tool to stop
  → Hard timeout (configurable): if tool doesn't stop within grace period, kill it
```

### Changes

**File:** `cowork-agent-runtime/src/agent_host/loop/tool_executor.py`

Add cancellation awareness to tool execution:

```python
async def _execute_single(self, tool_call, task_id, step_id):
    # ... policy check, approval ...

    # Execute with cancellation monitoring
    try:
        result = await asyncio.wait_for(
            self._tool_router.execute(request, context),
            timeout=self._get_tool_timeout(tool_call.name),
        )
    except asyncio.TimeoutError:
        result = ToolExecutionResult(
            status="timeout",
            output=f"Tool {tool_call.name} timed out after {timeout}s",
            artifacts=[],
        )
    except asyncio.CancelledError:
        result = ToolExecutionResult(
            status="cancelled",
            output=f"Tool {tool_call.name} cancelled by user",
            artifacts=[],
        )
```

**Per-tool timeout configuration:**

```python
_TOOL_TIMEOUTS: dict[str, int] = {
    "RunCommand": 300,       # 5 minutes (existing default)
    "ExecuteCode": 30,       # 30 seconds (existing default)
    "HttpRequest": 30,       # 30 seconds
    "FetchUrl": 30,          # 30 seconds
    "WebSearch": 15,         # 15 seconds
    # File tools: no timeout (local I/O, always fast)
}
_DEFAULT_TOOL_TIMEOUT = 60   # 1 minute for unrecognized tools
```

**Process kill on cancellation** (for RunCommand):

```python
# In RunCommand, when cancellation is detected:
async def _kill_process(self, process, grace_seconds=5):
    """SIGTERM → wait → SIGKILL if still alive."""
    process.terminate()
    try:
        await asyncio.wait_for(process.wait(), timeout=grace_seconds)
    except asyncio.TimeoutError:
        process.kill()
        await process.wait()
```

**File:** `cowork-agent-runtime/src/tool_runtime/tools/shell/run_command.py`

RunCommand already has timeout logic. Extend it to support external cancellation:

```python
async def execute(self, request, context):
    process = await asyncio.create_subprocess_exec(...)

    try:
        stdout, stderr = await asyncio.wait_for(
            process.communicate(),
            timeout=self._timeout,
        )
    except asyncio.TimeoutError:
        await self._kill_process(process)
        return ToolExecutionResult(status="timeout", output="Command timed out")
    except asyncio.CancelledError:
        await self._kill_process(process)
        # Capture any partial output
        partial = await self._read_partial_output(process)
        return ToolExecutionResult(status="cancelled", output=f"Cancelled. Partial output:\n{partial}")
```

### What Does NOT Change

- File tools (ReadFile, WriteFile, etc.) don't need force cancellation — they're local I/O and always fast
- The cancel_event mechanism stays — it handles loop-level cancellation
- Tool-level cancellation is an additional layer for long-running tools

### Tests

- Unit: RunCommand cancelled mid-execution — process killed, partial output captured
- Unit: RunCommand timeout — existing behavior preserved
- Unit: ExecuteCode timeout — script killed after 30s
- Unit: File tool — no timeout applied (instant completion)
- Integration: User cancels during long shell command — command killed, task cancelled cleanly

---

## A5: Shell Argument Inspection

### Problem

Policy enforcement for `Shell.Exec` only inspects the base command. `rm -rf /` and `rm temp.txt` both match the base command `rm`. The policy can either allow all `rm` or block all `rm` — no granularity.

### Current Behavior

```python
# PolicyEnforcer.check_command()
# Extracts base command: "rm -rf /" → "rm"
# Checks against allowedCommands: ["rm"] → ALLOWED
# No argument inspection
```

### Proposed Behavior

```python
# PolicyEnforcer.check_command()
# Full command: "rm -rf /"
# Check against allowedCommands patterns:
#   "rm *" → ALLOWED (matches any rm)
#   "rm -rf *" → check against blockedPatterns: ["rm -rf /", "rm -rf ~"] → DENIED
#   "git push --force *" → DENIED by blockedPatterns
```

### Changes

**File:** `cowork-agent-sdk/src/agent_sdk/policy/command_matcher.py`

Extend command matching to support argument patterns:

```python
def matches_command_pattern(command: str, pattern: str) -> bool:
    """Match a full command string against a pattern.

    Patterns:
    - "git" → matches base command only (backward compatible)
    - "git push" → matches command + subcommand
    - "git push --force *" → matches with specific flags
    - "rm -rf *" → matches rm with -rf flag and any argument
    """
    # Tokenize both command and pattern
    cmd_parts = shlex.split(command)
    pattern_parts = shlex.split(pattern)

    for i, pat in enumerate(pattern_parts):
        if pat == "*":
            return True  # Wildcard matches rest
        if i >= len(cmd_parts):
            return False  # Pattern longer than command
        if pat != cmd_parts[i]:
            return False  # Mismatch

    # Pattern exhausted — matches if command has no more parts or pattern didn't require exact match
    return True
```

**PolicyEnforcer changes:**

```python
def check_command(self, command: str) -> PolicyCheckResult:
    capability = self.get_capability("Shell.Exec")
    if not capability:
        return PolicyCheckResult(decision="DENIED", reason="Shell.Exec not granted")

    # Check blockedCommands first (deny takes precedence)
    if capability.blockedCommands:
        for pattern in capability.blockedCommands:
            if matches_command_pattern(command, pattern):
                return PolicyCheckResult(decision="DENIED", reason=f"Command blocked: {pattern}")

    # Check allowedCommands
    if capability.allowedCommands:
        for pattern in capability.allowedCommands:
            if matches_command_pattern(command, pattern):
                return PolicyCheckResult(decision="ALLOWED")
        return PolicyCheckResult(decision="DENIED", reason="Command not in allowlist")

    # No allowlist/blocklist — default allow
    return PolicyCheckResult(decision="ALLOWED")
```

**Risk assessor update:**

```python
# High-risk argument patterns
_HIGH_RISK_PATTERNS = [
    "rm -rf /",
    "rm -rf ~",
    "rm -rf .",
    "git push --force",
    "git push -f",
    "git reset --hard",
    "chmod 777",
    "dd if=",
    "mkfs",
    "> /dev/",
]

def assess_command_risk(command: str) -> str:
    for pattern in _HIGH_RISK_PATTERNS:
        if pattern in command:
            return "high"
    return "low"
```

### Backward Compatibility

- Existing `allowedCommands: ["git", "npm", "make"]` still works — base command matching is the fallback when pattern has no spaces
- New pattern matching only activates when patterns contain spaces or wildcards
- `blockedCommands` patterns are checked first (deny takes precedence)

### Policy Bundle Example

```json
{
    "name": "Shell.Exec",
    "allowedCommands": ["git *", "npm *", "make *", "python *"],
    "blockedCommands": ["git push --force *", "git reset --hard *", "rm -rf /", "rm -rf ~"]
}
```

### Tests

- Unit: `matches_command_pattern()` — exact match, wildcard match, subcommand match, no match
- Unit: PolicyEnforcer with argument patterns — allowed, blocked, default
- Unit: Risk assessor with high-risk argument patterns
- Unit: Backward compat — base command matching without patterns still works
- Integration: Agent tries `git push --force` → blocked by policy

---

## Endpoint Change Summary

No HTTP endpoint changes. All modifications are internal to the agent-runtime tool execution pipeline and agent-sdk policy enforcement.

---

## Files Changed

| File | Changes |
|---|---|
| `cowork-agent-runtime/src/tool_runtime/tools/shell/run_command.py` | Streaming output callback, cancellation handling, process kill |
| `cowork-agent-runtime/src/agent_host/loop/tool_executor.py` | Per-tool timeout, cancellation monitoring, output chunk callback |
| `cowork-agent-runtime/src/tool_runtime/router/tool_router.py` | Pass `on_output_chunk` callback via ExecutionContext |
| `cowork-agent-sdk/src/agent_sdk/policy/command_matcher.py` | Argument pattern matching |
| `cowork-agent-sdk/src/agent_sdk/policy/policy_enforcer.py` | Use pattern matching for command checks |
| `cowork-agent-sdk/src/agent_sdk/policy/risk_assessor.py` | High-risk argument pattern detection |
| `cowork-platform/contracts/enums/event-types.json` | Add `tool_output_chunk` event type |
| `cowork-platform/contracts/enums/frontend-event-types.json` | Add `tool_output_chunk` to allow-list |

---

## Dependency Between A3, A4, A5

- **A6 (Streaming) and A7 (Force cancel)** both modify `RunCommand` — implement together to avoid double refactoring
- **A8 (Shell args)** is independent — modifies PolicyEnforcer, not tool execution
- **A6 depends on** the `ExecutionContext` extension — coordinate with ToolRouter changes
- **A7 depends on** `asyncio.CancelledError` propagation through the tool execution chain

---

## Implementation Plan

### Codebase Context (Current State)

Key structures discovered during implementation readiness review:

**`RunCommand`** (`tool_runtime/tools/shell/run_command.py:24-153`): Uses `asyncio.create_subprocess_exec()` with `os.setsid` for process groups. Captures stdout/stderr via `process.communicate()` (blocking until completion). Timeout via `asyncio.wait_for()` (default 300s). On timeout: `platform.kill_process_tree()`. Output >10KB triggers artifact extraction.

**`ExecutionContext`** (`tool_runtime/models.py:25-43`): `@dataclass(frozen=True)` with capability constraint fields. Adding `on_output_chunk` requires changing from frozen or passing callback separately. **Decision:** Add `on_output_chunk` field and change to `frozen=False`, since ExecutionContext is created fresh per tool call and never shared across threads.

**`ToolExecutor._execute_single()`** (`agent_host/loop/tool_executor.py:205-382`): Handles plan mode check → policy check → approval gate → ToolRouter dispatch → artifact upload → event emission. No timeout wrapper currently — timeout is only in RunCommand itself. Adding per-tool timeout wraps the ToolRouter dispatch call.

**`ToolRouter.execute()`** (`tool_runtime/router/tool_router.py`): Dispatches to registered tool. Passes `ExecutionContext` to tool. Adding `on_output_chunk` requires passing it through ExecutionContext.

**`command_matcher.py`** (`agent_sdk/policy/command_matcher.py:1-68`): `extract_base_command()` strips path prefix, returns first token. `check_command()` compares base command against allowlist/blocklist. No pattern matching — only exact base command comparison.

**`PolicyEnforcer`** (`agent_sdk/policy/policy_enforcer.py`): Pure, stateless, no I/O. `check_tool_call()` delegates to `check_command()` for `Shell.Exec`. No risk assessment currently.

### Resolved Ambiguities

| Question | Resolution |
|----------|-----------|
| ExecutionContext is frozen — how to add callback? | Change to `frozen=False`. Context is created fresh per call, never shared. Safe. |
| Line-by-line vs batched streaming? | Line-by-line. Each `\n`-terminated line emits one chunk. Simple, predictable. |
| How does ToolRouter pass callback? | Via `ExecutionContext.on_output_chunk` field. ToolRouter passes ExecutionContext to tool unchanged. |
| File tools excluded from timeout? | Yes. `_TOOL_TIMEOUTS` dict omits file tools. `_execute_single()` only wraps in `wait_for` when tool name is in `_TOOL_TIMEOUTS` or `_DEFAULT_TOOL_TIMEOUT` applies. File tools (ReadFile, WriteFile, etc.) are excluded via a `_NO_TIMEOUT_TOOLS` set. |
| SIGTERM grace period configurable? | No — hardcoded 5s. Sufficient for all current tools. |
| Pattern matching: wildcard semantics? | `*` matches zero or more remaining tokens. `"git *"` matches `"git"`, `"git push"`, `"git push --force origin"`. |
| Risk assessor integration? | `assess_command_risk()` is a standalone function. Not wired into PolicyEnforcer in Phase A — available for future use (approval flow, UI risk display). |
| Backward compat for base-only patterns? | If pattern has no spaces and no `*`, use existing base command matching. Patterns with spaces/wildcards use new `matches_command_pattern()`. |

### Implementation Order

**Step 7: A8 — Shell argument inspection** (`cowork-agent-sdk`)
- Add `matches_command_pattern()` to `command_matcher.py`
- Update `check_command()` to use pattern matching for complex patterns
- Create `risk_assessor.py` with `assess_command_risk()`
- Extend tests in `test_command_matcher.py`, create `test_risk_assessor.py`

**Step 8: A6+A7 — Streaming output + force cancellation** (`cowork-agent-runtime`, `cowork-platform`)
- Modify `ExecutionContext` to add `on_output_chunk` (change to `frozen=False`)
- Modify `RunCommand`: replace `process.communicate()` with line-by-line streaming, add `_kill_process()`, handle `CancelledError`
- Modify `ToolExecutor._execute_single()`: create output chunk callback, wrap execution in `asyncio.wait_for()` with per-tool timeout
- Add `tool_output_chunk` to platform contract enums
- Add tests for streaming, timeout, cancellation, backward compat

---

## Definition of Done — A6 through A8

### A6: Streaming Tool Output

**Code changes:**
| File | Change |
|------|--------|
| `cowork-agent-runtime/src/tool_runtime/models.py` | Change `ExecutionContext` from `frozen=True` to `frozen=False`. Add `on_output_chunk: Callable[[str], None] \| None = None` field. |
| `cowork-agent-runtime/src/tool_runtime/tools/shell/run_command.py` | Replace `process.communicate()` with `async for line in process.stdout` loop. Call `context.on_output_chunk(line)` per line if callback set. Accumulate lines for final result. Handle stderr separately via `process.stderr.read()` after stdout completes. |
| `cowork-agent-runtime/src/agent_host/loop/tool_executor.py` | In `_execute_single()`: create `on_output_chunk` lambda that calls `self._event_emitter.emit_tool_output_chunk(tool_call_id, tool_name, content, task_id)`. Pass via `ExecutionContext`. |
| `cowork-platform/contracts/enums/event-types.json` | Add `"tool_output_chunk"` to the enum array. |
| `cowork-platform/contracts/enums/frontend-event-types.json` | Add `"tool_output_chunk"` to the frontend allow-list array. |

**Tests:**
| Test | File | Assertion |
|------|------|-----------|
| `test_run_command_streaming_emits_lines` | `test_run_command.py` | Callback called once per line of stdout |
| `test_run_command_streaming_final_result_complete` | `test_run_command.py` | Final result equals full stdout content |
| `test_run_command_no_callback_backward_compat` | `test_run_command.py` | No callback → same behavior as before |
| `test_run_command_timeout_during_streaming` | `test_run_command.py` | Timeout kills process, partial lines returned |
| `test_tool_executor_creates_output_chunk_callback` | `test_tool_executor.py` | Callback wired to event emitter |

**Acceptance criteria:**
- [ ] Long-running commands emit `tool_output_chunk` events per line
- [ ] Final tool result is complete accumulated output (same as today for LLM)
- [ ] No callback → behavior unchanged (backward compatible)
- [ ] Timeout still kills process and returns partial output
- [ ] Output truncation (80/20 head/tail) still applies to final result
- [ ] `tool_output_chunk` event type added to platform contracts
- [ ] `make check` passes in `cowork-agent-runtime` and `cowork-platform`

---

### A7: Force Cancellation with Hard Timeout

**Code changes:**
| File | Change |
|------|--------|
| `cowork-agent-runtime/src/agent_host/loop/tool_executor.py` | Add `_TOOL_TIMEOUTS` dict (RunCommand=300, ExecuteCode=30, HttpRequest=30, FetchUrl=30, WebSearch=15), `_DEFAULT_TOOL_TIMEOUT = 60`, `_NO_TIMEOUT_TOOLS` set (all file tools). Wrap `self._tool_router.execute()` in `asyncio.wait_for(timeout)`. Catch `asyncio.TimeoutError` → return `ToolExecutionResult(status="timeout", ...)`. Catch `asyncio.CancelledError` → return `ToolExecutionResult(status="cancelled", ...)`. |
| `cowork-agent-runtime/src/tool_runtime/tools/shell/run_command.py` | Add `_kill_process(process, grace_seconds=5)` method: `process.terminate()` → `wait_for(process.wait(), timeout=5)` → `process.kill()`. In streaming loop: catch `asyncio.CancelledError` → call `_kill_process()` → return partial output. |

**Tests:**
| Test | File | Assertion |
|------|------|-----------|
| `test_run_command_cancelled_kills_process` | `test_run_command.py` | CancelledError triggers process termination |
| `test_kill_process_sigterm_then_sigkill` | `test_run_command.py` | SIGTERM sent first, SIGKILL after grace timeout |
| `test_run_command_cancelled_returns_partial_output` | `test_run_command.py` | Partial stdout captured before cancellation |
| `test_tool_executor_per_tool_timeout` | `test_tool_executor.py` | RunCommand gets 300s, ExecuteCode gets 30s |
| `test_tool_executor_default_timeout` | `test_tool_executor.py` | Unknown tool gets 60s default |
| `test_tool_executor_no_timeout_for_file_tools` | `test_tool_executor.py` | ReadFile, WriteFile etc. not wrapped in wait_for |
| `test_tool_executor_timeout_returns_timeout_result` | `test_tool_executor.py` | TimeoutError caught, status="timeout" returned |

**Acceptance criteria:**
- [ ] Runaway shell commands killed after configured timeout
- [ ] SIGTERM → 5s grace → SIGKILL escalation
- [ ] Partial output captured and returned to LLM
- [ ] File tools not wrapped in timeout (local I/O, always fast)
- [ ] Per-tool timeout configurable via `_TOOL_TIMEOUTS` dict
- [ ] `make check` passes

---

### A8: Shell Argument Inspection

**Code changes:**
| File | Change |
|------|--------|
| `cowork-agent-sdk/src/agent_sdk/policy/command_matcher.py` | Add `matches_command_pattern(command: str, pattern: str) -> bool`. Tokenize both with `shlex.split()`, compare token-by-token, `*` matches zero-or-more remaining tokens. Update `check_command()`: for patterns containing spaces or `*`, use `matches_command_pattern()`; for simple patterns (no spaces, no `*`), use existing base command comparison. |
| **New:** `cowork-agent-sdk/src/agent_sdk/policy/risk_assessor.py` | `_HIGH_RISK_PATTERNS` list (substring patterns: `"rm -rf /"`, `"rm -rf ~"`, `"rm -rf ."`, `"git push --force"`, `"git push -f"`, `"git reset --hard"`, `"chmod 777"`, `"dd if="`, `"mkfs"`, `"> /dev/"`). `assess_command_risk(command: str) -> Literal["high", "low"]` — substring check against patterns. |

**Tests:**
| Test | File | Assertion |
|------|------|-----------|
| `test_matches_pattern_exact_subcommand` | `test_command_matcher.py` | `"git push"` matches `"git push"` |
| `test_matches_pattern_wildcard` | `test_command_matcher.py` | `"git push origin main"` matches `"git push *"` |
| `test_matches_pattern_wildcard_zero_args` | `test_command_matcher.py` | `"git push"` matches `"git push *"` (zero remaining) |
| `test_matches_pattern_no_match` | `test_command_matcher.py` | `"npm install"` doesn't match `"git *"` |
| `test_matches_pattern_base_only` | `test_command_matcher.py` | `"git status"` matches `"git"` |
| `test_matches_pattern_flags` | `test_command_matcher.py` | `"git push --force origin"` matches `"git push --force *"` |
| `test_check_command_blocked_with_pattern` | `test_command_matcher.py` | `"git push --force x"` blocked by `["git push --force *"]` |
| `test_check_command_allowed_with_pattern` | `test_command_matcher.py` | `"git status"` allowed by `["git *"]` |
| `test_check_command_base_only_backward_compat` | `test_command_matcher.py` | `["git", "npm"]` (no spaces) still works as before |
| `test_assess_risk_high_rm_rf` | `test_risk_assessor.py` | `"rm -rf /"` → `"high"` |
| `test_assess_risk_high_force_push` | `test_risk_assessor.py` | `"git push --force origin"` → `"high"` |
| `test_assess_risk_low_normal_command` | `test_risk_assessor.py` | `"git status"` → `"low"` |
| `test_assess_risk_high_all_patterns` | `test_risk_assessor.py` | Every pattern in `_HIGH_RISK_PATTERNS` detected |

**Acceptance criteria:**
- [ ] `matches_command_pattern()` handles exact, wildcard, subcommand, and base-only patterns
- [ ] `check_command()` uses pattern matching for complex patterns (spaces/wildcards)
- [ ] Existing base-command-only policies (`["git", "npm"]`) still work unchanged
- [ ] Blocklist patterns checked before allowlist (deny takes precedence)
- [ ] `assess_command_risk()` detects all high-risk patterns via substring match
- [ ] `make check` passes in `cowork-agent-sdk`

---

## Cross-cutting Requirements

All items (A1-A8):
- [ ] Single feature branch: `feature/phase-a-implementation`
- [ ] `make check` passes in all affected repos (lint + format-check + typecheck + test)
- [ ] No regressions in existing tests
- [ ] Structured logging with `structlog` for all new code paths
- [ ] Error handling: no unhandled exceptions, graceful fallbacks
- [ ] Backward compatible: no breaking changes to existing tool calls or APIs
- [ ] PR with squash merge to main after all items complete
