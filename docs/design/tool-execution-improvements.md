# Tool Execution Improvements — Design Doc

**Status:** Proposed
**Scope:** cowork-agent-runtime, cowork-agent-sdk
**Date:** 2026-03-28
**Roadmap:** Phase A, items A3-A5

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

- **A3 (Streaming) and A4 (Force cancel)** both modify `RunCommand` — implement together to avoid double refactoring
- **A5 (Shell args)** is independent — modifies PolicyEnforcer, not tool execution
- **A3 depends on** the `ExecutionContext` extension — coordinate with ToolRouter changes
- **A4 depends on** `asyncio.CancelledError` propagation through the tool execution chain
