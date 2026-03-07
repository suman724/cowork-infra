# Loop Strategy & Loop Runtime — Component Design

**Repo:** `cowork-agent-runtime` (`agent_host/loop/` package)
**Bounded Context:** AgentExecution
**Phase:** 2+
**Status:** Implemented
**Superseded:** Monolithic `AgentLoop` class in `agent_host/loop/agent_loop.py` (now a deprecated alias)

---

The agent loop was previously a single class (`AgentLoop`) that mixed orchestration strategy, context assembly, and infrastructure plumbing. This refactor separated those concerns into a **LoopRuntime** (infrastructure primitives) and a **LoopStrategy** (orchestration + context decisions), enabling multiple loop implementations to be developed and swapped without duplicating service integration code.

**Prerequisites:** [local-agent-host.md](local-agent-host.md) (current agent loop design), [architecture.md](../architecture.md) (protocol contracts)

---

## 1. Motivation

### Problem

The original `AgentLoop.run()` method (~240 lines) interleaved three concerns:

1. **Orchestration strategy** — step iteration order, termination conditions, when to call LLM vs tools
2. **Context assembly** — what messages the LLM sees each turn (memory injection, compaction, error recovery prompts)
3. **Infrastructure plumbing** — step ID generation, cancellation, token budget, policy checks, event emission, checkpoint callbacks, tool routing

This made it impossible to experiment with alternative loop strategies (plan-then-execute, reflection loops, parallel tool execution) without duplicating all the infrastructure code.

### Goals

- Enable multiple loop strategy implementations that share infrastructure
- Keep all backend service coupling (LLM Gateway, Workspace Service, event emission) in one place
- Let each strategy fully own context assembly (what the LLM sees each turn)
- Let each strategy control sub-agent and skill spawning behavior
- Maintain the current `ReactLoop` behavior as the default — zero functional regression
- Keep `SessionManager` as the composition root with minimal changes

### Non-goals

- Abstracting away LLM provider differences (that stays in `LLMClient`)
- Runtime strategy switching mid-session (strategy is chosen at session/task creation)
- Plugin system for external strategy implementations (internal-only for now)

---

## 2. Architecture

### Why Three Layers (SessionManager → LoopRuntime → LoopStrategy)

An alternative would be to put LoopRuntime methods directly on SessionManager behind a protocol. A separate LoopRuntime was chosen for these reasons:

1. **Different lifetimes.** SessionManager lives for the entire session (process lifetime). LoopRuntime is built fresh per task — fresh `ErrorRecovery`, fresh compactor state, potentially different strategy config per task. Mixing per-session and per-task state in one object invites bugs.

2. **SessionManager is already large.** It handles session lifecycle, JSON-RPC dispatch, backend service calls (Session Service, Workspace Service), component construction, checkpoint management, and task reporting. Adding loop-facing methods turns it into a god class.

3. **Sub-agent spawning.** LoopRuntime builds child LoopRuntime instances for sub-agents. If this lived on SessionManager, you'd have SessionManager building "mini SessionManagers" — but sub-agents don't have sessions, don't do JSON-RPC, don't call Session Service. The abstraction leaks.

4. **Testability.** To test a loop strategy, mock one LoopRuntime. If it were on SessionManager, tests would carry implicit session lifecycle baggage and mock a much larger surface.

### Layered Responsibility

```
SessionManager (session lifecycle, backend service calls, JSON-RPC dispatch)
  │  Lifetime: one per session (process lifetime)
  │
  ├── builds LoopRuntime (component facade for loop execution)
  │     │  Lifetime: one per task
  │     └── owns: LLMClient, ToolExecutor, MessageThread, PolicyEnforcer,
  │               TokenBudget, EventEmitter, WorkingMemory, MemoryManager,
  │               ErrorRecovery, ContextCompactor, CheckpointCallback,
  │               SubAgent/Skill spawning
  │
  └── selects LoopStrategy (orchestration + context decisions)
        │  Lifetime: one per task
        └── receives LoopRuntime, makes all decisions:
              orchestration, context assembly, termination
```

### What Goes Where

| Concern | LoopRuntime (infrastructure) | LoopStrategy (decisions) |
|---------|------------------------------|--------------------------|
| LLM calls | `call_llm()` — policy check, budget check, streaming, usage recording | What messages and tools to send, when to call |
| Tool execution | `execute_tools()` — routing, policy, approval, event emission | When to execute, how to handle results |
| Context assembly | Exposes `thread`, `compactor`, `working_memory`, `memory_manager` as properties | Builds the message list: decides what to inject, where, when to compact |
| Sub-agents | `spawn_sub_agent()` — builds child harness, enforces concurrency semaphore | When to spawn, what prompt, what strategy for the child |
| Skills | `execute_skill()` — builds child harness, loads skill prompt | When to invoke, which skill |
| Memory | `memory_manager` property — file I/O (read/write) | When/where to inject memory into context |
| Working memory | `working_memory` property — state storage | When/where to inject, whether to use at all |
| Error recovery | `error_recovery` property — failure tracking state | When to check for loops, what prompts to inject |
| Events | `emit_*()` methods — fire-and-forget delivery | When to emit step boundaries |
| Cancellation | `is_cancelled()` — checks the event | When to check, how to respond |
| Checkpointing | `on_step_complete()` — atomic write | When a "step" boundary occurs |
| Step IDs | `new_step_id()` — UUID generation | When to create a new step |
| Token budget | `token_budget` property — read-only access to remaining budget | Whether to adjust behavior based on budget |
| Thread | `thread` property — message storage | What to add, when to compact |

**Principle:** The harness holds state and provides I/O primitives. The strategy decides what to read, what to build, and in what order.

---

## 3. LoopRuntime Interface

```python
class LoopRuntime:
    """Infrastructure primitives for loop strategies.

    Owns all backend service coupling, event emission, and bookkeeping.
    Has no opinions about orchestration order or context assembly.
    """

    def __init__(
        self,
        llm_client: LLMClient,
        tool_executor: ToolExecutor,
        thread: MessageThread,
        compactor: ContextCompactor,
        policy_enforcer: PolicyEnforcer,
        token_budget: TokenBudget,
        event_emitter: EventEmitter | None,
        cancellation_event: asyncio.Event,
        max_context_tokens: int,
        working_memory: WorkingMemory | None,
        memory_manager: MemoryManager | None,
        error_recovery: ErrorRecovery,
        agent_tool_handler: AgentToolHandler | None,
        on_step_complete: Callable[[str, int], Awaitable[None]] | None,
        default_sub_agent_factory: Callable[[LoopRuntime], LoopStrategy] | None,
        skills: list[SkillDefinition] | None,
        max_concurrent_sub_agents: int = 5,
    ) -> None:
        # ... store references ...
        self._sub_agent_semaphore = asyncio.Semaphore(max_concurrent_sub_agents)

    # ── Primitives ──────────────────────────────────────────────

    def is_cancelled(self) -> bool:
        """Check if the task has been cancelled."""

    def new_step_id(self) -> str:
        """Generate a new UUID v4 step ID."""

    # ── LLM ─────────────────────────────────────────────────────

    async def call_llm(
        self,
        messages: list[dict],
        tools: list[dict],
        task_id: str,
        step_id: str,
        on_text_chunk: Callable[[str], None] | None = None,
    ) -> LLMResponse:
        """Policy check + budget pre-check + stream LLM + record usage.

        Raises: CapabilityDeniedError, LLMBudgetExceededError, LLMGatewayError
        """

    # ── Tools ───────────────────────────────────────────────────

    def get_external_tool_defs(self) -> list[dict]:
        """Tool definitions from ToolRouter (policy-filtered)."""

    def get_agent_tool_defs(self) -> list[dict]:
        """Agent-internal tool definitions (TaskTracker, CreatePlan, memory tools, etc.)."""

    async def execute_external_tools(
        self,
        tool_calls: list[ToolCall],
        task_id: str,
        step_id: str,
    ) -> list[ToolCallResult]:
        """Execute tools through ToolExecutor (policy, approval, events).

        Results are NOT automatically added to thread — strategy decides.
        """

    async def execute_agent_tool(
        self,
        tool_call: ToolCall,
        task_id: str,
    ) -> dict:
        """Execute an agent-internal tool (no policy, no ToolRouter).

        Result is NOT automatically added to thread — strategy decides.
        """

    def is_agent_tool(self, tool_name: str) -> bool:
        """Check if a tool name is agent-internal."""

    # ── Events ──────────────────────────────────────────────────

    def emit_step_started(self, task_id: str, step: int, step_id: str) -> None: ...
    def emit_step_completed(self, task_id: str, step: int, step_id: str) -> None: ...
    def emit_text_chunk(self, task_id: str, text: str, step_id: str) -> None: ...
    def emit_step_limit_approaching(self, task_id: str, step: int, max_steps: int) -> None: ...
    def emit_task_failed(self, task_id: str, reason: str) -> None: ...
    def emit_tool_requested(self, **kwargs) -> None: ...
    def emit_tool_completed(self, **kwargs) -> None: ...

    # ── Checkpoint ──────────────────────────────────────────────

    async def on_step_complete(self, task_id: str, step: int) -> None:
        """Invoke the checkpoint callback. Errors are logged, never raised."""

    # ── Sub-agents & Skills ─────────────────────────────────────

    async def spawn_sub_agent(
        self,
        prompt: str,
        task_id: str,
        max_steps: int = 25,
        strategy_factory: Callable[[LoopRuntime], LoopStrategy] | None = None,
    ) -> LoopResult:
        """Spawn a sub-agent with an isolated thread but shared token budget.

        Builds a child LoopRuntime with:
          - Shared: LLMClient, TokenBudget, PolicyEnforcer (same instances)
          - Fresh: MessageThread (isolated), ContextCompactor
          - Excluded: WorkingMemory, MemoryManager, SubAgent spawning (no recursion)
          - Constrained: max_steps (default 25, less than parent)

        If strategy_factory is None, uses default_sub_agent_factory.
        Enforces concurrency via sub_agent_semaphore.
        """

    async def execute_skill(
        self,
        skill: SkillDefinition,
        task_id: str,
        strategy_factory: Callable[[LoopRuntime], LoopStrategy] | None = None,
    ) -> LoopResult:
        """Execute a skill as a focused sub-conversation.

        Same child harness rules as spawn_sub_agent, plus the skill
        definition is injected as the system prompt.
        """

    # ── Read-only Properties ────────────────────────────────────

    @property
    def thread(self) -> MessageThread:
        """The conversation thread. Strategy reads and writes messages."""

    @property
    def compactor(self) -> ContextCompactor:
        """Context compaction strategy. Strategy calls build_llm_payload with it."""

    @property
    def working_memory(self) -> WorkingMemory | None:
        """Working memory (task tracker, plan, notes). Strategy decides injection."""

    @property
    def memory_manager(self) -> MemoryManager | None:
        """Persistent memory manager. Strategy decides when/where to inject."""

    @property
    def error_recovery(self) -> ErrorRecovery:
        """Error recovery tracker. Strategy decides when to check and inject."""

    @property
    def token_budget(self) -> TokenBudget:
        """Token budget (read-only view for strategy decisions)."""

    @property
    def max_context_tokens(self) -> int:
        """Maximum context window size."""

    @property
    def policy_enforcer(self) -> PolicyEnforcer:
        """Policy enforcer (read-only, for strategy-level policy queries)."""
```

---

## 4. LoopStrategy Protocol

```python
class LoopStrategy(Protocol):
    """A pluggable agent loop orchestration strategy.

    Receives a LoopRuntime and makes all decisions about:
    - How to assemble context (messages) for each LLM call
    - When and how many times to call the LLM
    - When and how to execute tools
    - When to inject memory, working memory, error recovery prompts
    - When to spawn sub-agents or execute skills
    - When to terminate (completion, step limit, cancellation)
    """

    async def run(self, task_id: str) -> LoopResult: ...
```

### LoopResult (unchanged)

```python
@dataclass
class LoopResult:
    reason: Literal["completed", "cancelled", "max_steps_exceeded", "budget_exceeded"]
    text: str = ""
    step_count: int = 0
```

---

## 5. ReactLoop — Default Strategy

The current `AgentLoop` behavior, extracted cleanly. This is the reference implementation.

```python
class ReactLoop:
    """Linear ReAct loop: LLM -> tools -> repeat until done.

    Context assembly:
    - Persistent memory (MEMORY.md) injected after system prompt every turn
    - Working memory (task tracker + plan + notes) injected after persistent memory
    - Context compaction at 90% of max_context_tokens minus injection overhead
    - Error recovery prompts appended when loop detection or reflection triggers fire
    """

    def __init__(self, harness: LoopRuntime, max_steps: int = 50) -> None:
        self._h = harness
        self._max_steps = max_steps

    async def run(self, task_id: str) -> LoopResult:
        step = 0
        last_text = ""

        while step < self._max_steps:
            step_id = self._h.new_step_id()

            if self._h.is_cancelled():
                return LoopResult(reason="cancelled", step_count=step)

            # ── Context assembly ────────────────────────────
            messages = self._build_messages()
            tools = self._h.get_external_tool_defs() + self._h.get_agent_tool_defs()

            # ── LLM call ────────────────────────────────────
            self._h.emit_step_started(task_id, step + 1, step_id)

            def _on_chunk(text: str, _sid: str = step_id) -> None:
                self._h.emit_text_chunk(task_id, text, _sid)

            response = await self._h.call_llm(messages, tools, task_id, step_id, _on_chunk)

            # ── Record in thread ────────────────────────────
            self._h.thread.add_assistant_message(response.text, response.tool_calls)
            last_text = response.text

            # ── Step bookkeeping ────────────────────────────
            step += 1
            self._h.emit_step_completed(task_id, step, step_id)
            await self._h.on_step_complete(task_id, step)

            if step == int(self._max_steps * 0.8):
                self._h.emit_step_limit_approaching(task_id, step, self._max_steps)

            if step >= self._max_steps:
                self._h.emit_task_failed(
                    task_id, f"Step limit reached ({step}/{self._max_steps})"
                )
                return LoopResult(
                    reason="max_steps_exceeded", text=last_text, step_count=step
                )

            # ── Termination check ───────────────────────────
            if not response.tool_calls and response.stop_reason == "stop":
                return LoopResult(reason="completed", text=last_text, step_count=step)

            # ── Tool execution ──────────────────────────────
            await self._execute_tools(response.tool_calls, task_id, step_id)

            # ── Error recovery tracking ─────────────────────
            self._track_tool_errors(response.tool_calls)

        return LoopResult(
            reason="max_steps_exceeded", text=last_text, step_count=step
        )

    def _build_messages(self) -> list[dict]:
        """Assemble LLM context: memory + working memory + compaction + error recovery."""
        injection_overhead = 0
        injections: list[str] = []

        # Persistent memory (MEMORY.md)
        if self._h.memory_manager:
            mem = self._h.memory_manager.render_memory_context()
            if mem:
                injections.append(mem)
                injection_overhead += estimate_message_tokens(
                    {"role": "system", "content": mem}
                )

        # Working memory (task tracker + plan + notes)
        if self._h.working_memory:
            wm = self._h.working_memory.render()
            if wm:
                injections.append(wm)
                injection_overhead += estimate_message_tokens(
                    {"role": "system", "content": wm}
                )

        # Compact conversation history
        budget = int(self._h.max_context_tokens * 0.9) - injection_overhead
        messages = self._h.thread.build_llm_payload(budget, self._h.compactor)

        # Insert injections after system prompt
        for i, text in enumerate(injections):
            messages.insert(1 + i, {"role": "system", "content": text})

        # Error recovery prompt injection
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

    async def _execute_tools(
        self, tool_calls: list[ToolCall], task_id: str, step_id: str
    ) -> None:
        """Route tool calls to agent-internal or external execution."""
        agent_calls = []
        external_calls = []
        for tc in tool_calls:
            if self._h.is_agent_tool(tc.name):
                agent_calls.append(tc)
            else:
                external_calls.append(tc)

        # Agent-internal tools
        for ac in agent_calls:
            result_dict = await self._h.execute_agent_tool(ac, task_id)
            result_text = json.dumps(result_dict, default=str)
            self._h.thread.add_tool_result(ac.id, ac.name, result_text)

        # External tools (policy-checked, approval-gated)
        if external_calls:
            results = await self._h.execute_external_tools(
                external_calls, task_id, step_id
            )
            for r in results:
                self._h.thread.add_tool_result(
                    r.tool_call_id, r.tool_name, r.result_text, image_url=r.image_url
                )

    def _track_tool_errors(self, tool_calls: list[ToolCall]) -> None:
        """Feed tool results into error recovery tracker."""
        er = self._h.error_recovery
        for tc in tool_calls:
            for msg in reversed(self._h.thread.messages):
                if msg.get("role") == "tool" and msg.get("tool_call_id") == tc.id:
                    content = msg.get("content", "")
                    try:
                        result_data = json.loads(content)
                        status = result_data.get("status", "")
                    except (json.JSONDecodeError, AttributeError):
                        status = "success"
                    if status in ("failed", "denied"):
                        error_msg = str(
                            result_data.get("error", {}).get("message", "")
                        )
                        er.record_tool_failure(tc.name, tc.arguments, error_msg)
                    else:
                        er.record_tool_success(tc.name)
                    break
```

---

## 6. Alternative Strategy Examples

These illustrate what the LoopRuntime/LoopStrategy separation makes possible. Not all need to be built immediately.

### 6.1 PlanThenExecuteLoop

Two-phase strategy: first ask the LLM to produce a plan, then execute each step.

```python
class PlanThenExecuteLoop:
    def __init__(self, harness: LoopRuntime, max_steps: int = 50) -> None:
        self._h = harness
        self._max_steps = max_steps

    async def run(self, task_id: str) -> LoopResult:
        step = 0

        # Phase 1: Planning (no tools, just LLM)
        step_id = self._h.new_step_id()
        plan_messages = self._build_planning_context()
        self._h.emit_step_started(task_id, step + 1, step_id)
        response = await self._h.call_llm(plan_messages, [], task_id, step_id)
        self._h.thread.add_assistant_message(response.text, None)
        step += 1
        self._h.emit_step_completed(task_id, step, step_id)

        plan_steps = self._parse_plan(response.text)

        # Phase 2: Execution (with tools, one plan step at a time)
        for plan_step in plan_steps:
            if step >= self._max_steps or self._h.is_cancelled():
                break

            step_id = self._h.new_step_id()
            exec_messages = self._build_execution_context(plan_step)
            tools = self._h.get_external_tool_defs() + self._h.get_agent_tool_defs()

            self._h.emit_step_started(task_id, step + 1, step_id)
            response = await self._h.call_llm(exec_messages, tools, task_id, step_id)
            self._h.thread.add_assistant_message(response.text, response.tool_calls)
            step += 1
            self._h.emit_step_completed(task_id, step, step_id)

            if response.tool_calls:
                await self._execute_tools(response.tool_calls, task_id, step_id)

        return LoopResult(reason="completed", text=response.text, step_count=step)

    def _build_planning_context(self) -> list[dict]:
        """Inject memory + planning system prompt. No tools exposed."""
        messages = self._h.thread.build_llm_payload(
            self._h.max_context_tokens, self._h.compactor
        )
        # Inject memory (once, during planning)
        if self._h.memory_manager:
            mem = self._h.memory_manager.render_memory_context()
            if mem:
                messages.insert(1, {"role": "system", "content": mem})
        # Planning instruction
        messages.append({
            "role": "system",
            "content": "Produce a numbered step-by-step plan. Do not execute yet.",
        })
        return messages

    def _build_execution_context(self, plan_step: str) -> list[dict]:
        """Focused context for one plan step. No memory re-injection."""
        budget = int(self._h.max_context_tokens * 0.9)
        messages = self._h.thread.build_llm_payload(budget, self._h.compactor)
        messages.append({
            "role": "system",
            "content": f"Execute this plan step: {plan_step}",
        })
        return messages
```

### 6.2 ReflectLoop

Injects a self-critique prompt every N steps.

```python
class ReflectLoop:
    """ReactLoop variant that forces reflection every reflect_interval steps."""

    def __init__(
        self, harness: LoopRuntime, max_steps: int = 50, reflect_interval: int = 5
    ) -> None:
        self._h = harness
        self._max_steps = max_steps
        self._reflect_interval = reflect_interval

    async def run(self, task_id: str) -> LoopResult:
        step = 0
        last_text = ""

        while step < self._max_steps:
            if self._h.is_cancelled():
                return LoopResult(reason="cancelled", step_count=step)

            step_id = self._h.new_step_id()
            is_reflection_turn = (step > 0 and step % self._reflect_interval == 0)

            if is_reflection_turn:
                messages = self._build_reflection_context()
                tools = []  # Reflection turn: no tools, just thinking
            else:
                messages = self._build_action_context()
                tools = self._h.get_external_tool_defs() + self._h.get_agent_tool_defs()

            self._h.emit_step_started(task_id, step + 1, step_id)
            response = await self._h.call_llm(messages, tools, task_id, step_id)
            self._h.thread.add_assistant_message(response.text, response.tool_calls)
            last_text = response.text
            step += 1
            self._h.emit_step_completed(task_id, step, step_id)
            await self._h.on_step_complete(task_id, step)

            if not response.tool_calls and response.stop_reason == "stop":
                return LoopResult(reason="completed", text=last_text, step_count=step)

            if response.tool_calls:
                await self._execute_tools(response.tool_calls, task_id, step_id)

        return LoopResult(reason="max_steps_exceeded", text=last_text, step_count=step)

    def _build_reflection_context(self) -> list[dict]:
        budget = int(self._h.max_context_tokens * 0.9)
        messages = self._h.thread.build_llm_payload(budget, self._h.compactor)
        messages.append({
            "role": "system",
            "content": (
                "Pause and reflect: Review your progress so far. "
                "Are you on track? Have you made any mistakes? "
                "What should you do differently in the next steps?"
            ),
        })
        return messages

    def _build_action_context(self) -> list[dict]:
        """Standard ReactLoop-style context assembly."""
        # ... same as ReactLoop._build_messages()
```

### 6.3 BudgetAwareLoop

Adjusts behavior as token budget depletes.

```python
class BudgetAwareLoop:
    """Adjusts context and tool availability based on remaining token budget."""

    async def run(self, task_id: str) -> LoopResult:
        # ...
        # Key difference: _build_messages checks budget percentage
        pass

    def _build_messages(self) -> list[dict]:
        remaining_pct = self._h.token_budget.remaining_percentage()

        if remaining_pct > 0.5:
            # Full context: memory + working memory + generous compaction
            ...
        elif remaining_pct > 0.2:
            # Reduced: skip persistent memory, tighter compaction
            ...
        else:
            # Minimal: only recent messages, inject "wrap up" prompt
            ...
```

---

## 7. SessionManager Integration

### Previous Wiring (before refactor)

```python
class SessionManager:
    async def _run_agent(self, prompt, task_id, max_steps):
        tool_executor = ToolExecutor(...)
        compactor = DropOldestCompactor(...)
        working_memory = WorkingMemory()
        sub_agent_manager = SubAgentManager(...)
        skill_executor = SkillExecutor(...)

        loop = AgentLoop(
            llm_client=self._llm_client,
            tool_executor=tool_executor,
            thread=self._thread,
            compactor=compactor,
            policy_enforcer=self._policy_enforcer,
            token_budget=self._token_budget,
            event_emitter=self._event_emitter,
            cancellation_event=self._cancel_event,
            max_steps=max_steps,
            working_memory=working_memory,
            sub_agent_manager=sub_agent_manager,
            skill_executor=skill_executor,
            # ... 16 parameters
        )
        return await loop.run(task_id)
```

### Current Wiring (after refactor)

```python
class SessionManager:
    async def _run_agent(self, prompt, task_id, max_steps):
        tool_executor = ToolExecutor(...)
        compactor = DropOldestCompactor(...)
        working_memory = WorkingMemory()
        agent_tool_handler = AgentToolHandler(working_memory, ...)

        harness = LoopRuntime(
            llm_client=self._llm_client,
            tool_executor=tool_executor,
            thread=self._thread,
            compactor=compactor,
            policy_enforcer=self._policy_enforcer,
            token_budget=self._token_budget,
            event_emitter=self._event_emitter,
            cancellation_event=self._cancel_event,
            max_context_tokens=self._max_context_tokens,
            working_memory=working_memory,
            memory_manager=self._memory_manager,
            error_recovery=ErrorRecovery(),
            agent_tool_handler=agent_tool_handler,
            on_step_complete=self._checkpoint_callback,
            default_sub_agent_factory=lambda h: ReactLoop(h, max_steps=25),
            skills=self._skills,
        )

        strategy = self._create_loop_strategy(harness, max_steps)
        return await strategy.run(task_id)

    def _create_loop_strategy(
        self, harness: LoopRuntime, max_steps: int
    ) -> LoopStrategy:
        """Select loop strategy based on configuration or policy flags.

        Default: ReactLoop. Can be overridden via:
        - Session-level config (from CreateSession params)
        - Policy bundle feature flags
        - Environment variable (for development/testing)
        """
        strategy_name = self._config.loop_strategy  # default: "react"

        match strategy_name:
            case "react":
                return ReactLoop(harness, max_steps=max_steps)
            case "plan_execute":
                return PlanThenExecuteLoop(harness, max_steps=max_steps)
            case "reflect":
                return ReflectLoop(harness, max_steps=max_steps)
            case _:
                logger.warning("unknown_loop_strategy", strategy=strategy_name)
                return ReactLoop(harness, max_steps=max_steps)
```

---

## 8. Sub-Agent & Skill Spawning Detail

### Child Harness Construction

When a strategy calls `harness.spawn_sub_agent()`:

```
Parent LoopRuntime
  │
  └── spawn_sub_agent(prompt, task_id, strategy_factory)
        │
        ├── acquire sub_agent_semaphore (max 5 concurrent)
        │
        ├── build child LoopRuntime:
        │     Shared (same instances):
        │       - LLMClient
        │       - TokenBudget (shared budget enforcement)
        │       - PolicyEnforcer
        │     Fresh (new instances):
        │       - MessageThread (isolated conversation with prompt as first user message)
        │       - ContextCompactor (fresh state)
        │       - ErrorRecovery (fresh state)
        │     Excluded (None):
        │       - WorkingMemory (sub-agents don't need task tracking)
        │       - MemoryManager (sub-agents don't access persistent memory)
        │       - SubAgent spawning (no recursion — depth limit = 1)
        │       - Skills (sub-agents don't invoke skills)
        │     Inherited:
        │       - EventEmitter (events tagged with parent task_id)
        │       - AgentToolHandler (None — sub-agents have no agent-internal tools)
        │
        ├── create strategy:
        │     strategy_factory(child_harness) or default_sub_agent_factory(child_harness)
        │
        ├── run: await strategy.run(task_id)
        │
        └── release semaphore, return LoopResult
```

### Strategy Controls Sub-Agent Strategy

A parent strategy decides what kind of loop its children run:

```python
# ReactLoop: sub-agents are small ReactLoops
await self._h.spawn_sub_agent(prompt, task_id)  # uses default factory

# PlanThenExecuteLoop: sub-agents are focused executors
await self._h.spawn_sub_agent(
    prompt, task_id,
    strategy_factory=lambda h: ReactLoop(h, max_steps=10),
)

# Custom: sub-agents use a specialized research strategy
await self._h.spawn_sub_agent(
    prompt, task_id,
    strategy_factory=lambda h: ResearchLoop(h, max_steps=15),
)
```

### Skills

Skills work identically to sub-agents, except:
- The skill definition provides the system prompt (not user prompt)
- The skill's `constraints` (allowed tools, max steps) are applied to the child harness
- The strategy factory default is `ReactLoop` (skills are focused linear tasks)

---

## 9. Testing Strategy

### Unit Testing Loop Strategies

Mock only `LoopRuntime` — strategies have one dependency:

```python
class MockLoopRuntime:
    """Configurable mock for testing loop strategies in isolation."""

    def __init__(self, llm_responses: list[LLMResponse]):
        self.llm_responses = iter(llm_responses)
        self.thread = MockMessageThread()
        self.call_log: list[str] = []  # track what the strategy called
        # ... pre-configure all properties

    async def call_llm(self, messages, tools, task_id, step_id, on_text_chunk=None):
        self.call_log.append(f"call_llm:{len(messages)} msgs, {len(tools)} tools")
        return next(self.llm_responses)

    async def execute_external_tools(self, tool_calls, task_id, step_id):
        self.call_log.append(f"execute_tools:{len(tool_calls)}")
        return [MockToolCallResult(tc) for tc in tool_calls]
```

Test cases per strategy:

| Test | What it verifies |
|------|-----------------|
| `test_completes_on_stop` | Strategy returns `completed` when LLM says stop |
| `test_max_steps` | Strategy returns `max_steps_exceeded` at limit |
| `test_cancellation` | Strategy returns `cancelled` when event is set |
| `test_tool_execution` | Tools are dispatched and results added to thread |
| `test_context_assembly` | Messages passed to `call_llm` contain expected injections |
| `test_memory_injection` | Persistent memory appears in messages when present |
| `test_error_recovery` | Loop detection prompts injected at correct time |
| `test_sub_agent_spawn` | `spawn_sub_agent` called with correct factory |

### Unit Testing LoopRuntime

Test that harness correctly delegates to real components:

| Test | What it verifies |
|------|-----------------|
| `test_call_llm_checks_policy` | PolicyEnforcer.check_llm_call() called before LLM |
| `test_call_llm_checks_budget` | TokenBudget.pre_check() called before LLM |
| `test_call_llm_records_usage` | TokenBudget.record_usage() called with response tokens |
| `test_execute_tools_emits_events` | EventEmitter called for each tool |
| `test_spawn_sub_agent_semaphore` | Concurrency limited to semaphore size |
| `test_spawn_sub_agent_isolation` | Child gets fresh thread, shared budget |
| `test_on_step_complete_error_swallowed` | Callback errors logged, not raised |

### Integration Testing

Existing `test-chat.py` and agent loop integration tests continue to work — `ReactLoop` + `LoopRuntime` together produce identical behavior to the current `AgentLoop`.

---

## 10. Migration Path

This was a refactor, not a rewrite. The steps were ordered to maintain a working system at every point. Each step ended with `make check` passing. Implementation steps (1-6) are complete; documentation steps (7-9) are in progress.

### Step 1: Add `strategy.py` — LoopStrategy Protocol ✅ Done

Create the protocol and move `LoopResult` here. Keep re-export from `models.py` for backcompat.

**Files:**
- New: `src/agent_host/loop/strategy.py`
- Modified: `src/agent_host/loop/models.py` (re-export LoopResult from strategy.py)

**Verify:** `make check` — no imports reference this yet, zero impact.

### Step 2: Add `loop_runtime.py` — LoopRuntime Class ✅ Done

Extract infrastructure plumbing from `AgentLoop.__init__` and `AgentLoop.run()` into `LoopRuntime`. The harness methods are extracted directly from the existing code:
- `call_llm()` — policy check → budget check → stream → record usage
- `execute_external_tools()` / `execute_agent_tool()` — tool dispatch with event emission
- `spawn_sub_agent()` — child harness construction, semaphore, result truncation (absorbs `SubAgentManager` logic)
- `execute_skill()` — child harness construction, skill prompt injection (absorbs `SkillExecutor` logic)
- `emit_*()` — delegate to EventEmitter
- `on_step_complete()` — error-swallowing callback wrapper
- Properties: `thread`, `compactor`, `working_memory`, `memory_manager`, `error_recovery`, `token_budget`, `max_context_tokens`, `policy_enforcer`

**Files:**
- New: `src/agent_host/loop/loop_runtime.py`
- New: `tests/unit/agent_host/test_loop_runtime.py`

**Verify:** `make check` — additive only, existing code unchanged.

### Step 3: Add `react_loop.py` — ReactLoop Strategy ✅ Done

Create `ReactLoop` that takes a `LoopRuntime` and implements the current `AgentLoop.run()` orchestration + context assembly logic:
- `run()` — the step loop (identical behavior to current `AgentLoop.run()`)
- `_build_messages()` — memory injection, working memory, compaction, error recovery prompts
- `_execute_tools()` — route agent-internal vs external, add results to thread
- `_track_tool_errors()` — feed results into error recovery tracker

**Files:**
- New: `src/agent_host/loop/react_loop.py`
- New: `tests/unit/agent_host/test_react_loop.py` (with `MockLoopRuntime`)

**Verify:** `make check` — additive only, existing code unchanged.

### Step 4: Wire SessionManager → LoopRuntime + ReactLoop ✅ Done

Replace `AgentLoop(...)` construction in `_run_agent()` with `LoopRuntime(...)` + `ReactLoop(harness)`. Add `_create_loop_strategy()` factory method. Remove direct construction of `SubAgentManager` and `SkillExecutor` (their logic now lives in `LoopRuntime`).

**Files:**
- Modified: `src/agent_host/session/session_manager.py`
- Modified: `tests/unit/agent_host/test_session_manager.py` (patch `ReactLoop` instead of `AgentLoop`)

**Verify:** `make check` — **this is the cut-over step.** All existing behavior preserved.

### Step 5: Simplify Sub-Agent and Skill Modules ✅ Done

`SubAgentManager` and `SkillExecutor` logic has moved into `LoopRuntime.spawn_sub_agent()` and `LoopRuntime.execute_skill()`. Simplify or remove the standalone classes. `AgentToolHandler` delegates to the harness instead.

**Files:**
- Modified: `src/agent_host/loop/sub_agent.py` (simplified or removed)
- Modified: `src/agent_host/skills/skill_executor.py` (simplified or removed)
- Modified: `src/agent_host/loop/agent_tools.py` (delegates to harness for SpawnAgent/skills)
- Modified: corresponding test files

**Verify:** `make check`

### Step 6: Deprecate AgentLoop Alias ✅ Done

Keep `agent_loop.py` as a thin re-export for any external references:

```python
# agent_loop.py — deprecated, will be removed
from agent_host.loop.react_loop import ReactLoop as AgentLoop
__all__ = ["AgentLoop"]
```

Update existing `test_agent_loop.py` to build `LoopRuntime` + `ReactLoop` instead of `AgentLoop` directly. Private attr access (`loop._token_budget`) changes to harness properties (`harness.token_budget`).

**Files:**
- Modified: `src/agent_host/loop/agent_loop.py` (alias only)
- Modified: `tests/unit/agent_host/test_agent_loop.py`

**Verify:** `make check`

### Step 7: Update Documentation — Agent Runtime Repo 🔄 In Progress

Update all docs within `cowork-agent-runtime` to reflect the new architecture:

**Files:**
- Modified: `cowork-agent-runtime/CLAUDE.md`
  - Update package layout: add `loop_runtime.py`, `react_loop.py`, `strategy.py` to `loop/` description
  - Update "Custom agent loop" bullet: describe LoopRuntime + LoopStrategy pattern instead of monolithic AgentLoop
  - Update "Agent loop harness layers" section: mention LoopRuntime as the infrastructure facade
  - Add `ReactLoop` as the default strategy
- Modified: `cowork-agent-runtime/docs/agent-loop-architecture.md`
  - Replace all `AgentLoop` references with `LoopRuntime` + `ReactLoop`
  - Update the "Build AgentLoop with all components" step to show harness + strategy construction
  - Update sub-agent section: `SubAgentManager` → `LoopRuntime.spawn_sub_agent()`
  - Update skill section: `SkillExecutor` → `LoopRuntime.execute_skill()`
  - Update component table: add LoopRuntime, ReactLoop, LoopStrategy
  - Add section on strategy selection and how to implement new strategies
- Modified: `cowork-agent-runtime/docs/integration-gaps.md`
  - Update `AgentLoop` references to reflect new structure (or mark resolved if gaps are addressed)
- Modified: `cowork-agent-runtime/README.md`
  - Update architecture section if it describes the agent loop

**Verify:** Docs are accurate. `make lint-docs` if available.

### Step 8: Update Documentation — Design Docs (cowork-infra) 🔄 In Progress

Update the authoritative design docs to reflect the refactored architecture:

**Files:**
- Modified: `cowork-infra/docs/components/local-agent-host.md`
  - Section 2 (Internal Module Structure): update package layout — `loop/` now contains `strategy.py`, `loop_runtime.py`, `react_loop.py`
  - Section 2 (Module dependencies): update diagram — `session/` → `LoopRuntime` → `ReactLoop`, no direct `session/` → `loop/` arrow
  - Add new section or subsection: "Loop Strategy Pattern" — explain LoopRuntime/LoopStrategy separation, strategy selection, how to add new strategies
  - Update agent loop description: from "single AgentLoop class" to "LoopRuntime + pluggable LoopStrategy"
  - Update sub-agent and skill references: spawning now goes through LoopRuntime
- Modified: `cowork-infra/docs/components/loop-strategy.md` (this doc)
  - Update status from **Proposed** to **Implemented**
  - Remove/resolve open questions that were answered during implementation
  - Add any implementation notes or deviations from the original design
- Modified: `cowork-infra/docs/architecture.md`
  - If it references AgentLoop by name, update to mention the strategy pattern
- Modified: `cowork-infra/docs/domain-model.md`
  - If it references the agent loop internals, update accordingly
- Review (no changes expected unless they reference AgentLoop internals):
  - `cowork-infra/docs/components/local-tool-runtime.md`
  - `cowork-infra/docs/components/desktop-app.md`
  - `cowork-infra/docs/services/approval-service.md`
  - `cowork-infra/docs/services/backend-tool-service.md`

**Verify:** Design docs match implementation. No doc-code drift.

### Step 9: Update Implementation Plan and Memory 🔄 In Progress

**Files:**
- Modified: `IMPLEMENTATION_PLAN.md` (root)
  - Add this refactor as a completed task (e.g., Task 1G.1: Loop Strategy Refactor)
  - Update Phase 2 tasks that reference AgentLoop (Task 2.2, 2.3, 2.4) to reference LoopRuntime/ReactLoop
- Modified: `~/.claude/projects/.../memory/MEMORY.md`
  - Update architecture key points to mention LoopRuntime/LoopStrategy
- Modified: `~/.claude/projects/.../memory/architecture-details.md`
  - Update Agent Loop section with new structure

**Verify:** Plan and memory reflect current state.

---

## 11. File Layout (Current)

```
agent_host/loop/
  __init__.py
  strategy.py          ← LoopStrategy protocol + LoopResult
  loop_runtime.py      ← LoopRuntime class (infrastructure primitives)
  react_loop.py        ← ReactLoop (default strategy, extracted from AgentLoop)
  agent_loop.py        ← Deprecated alias: AgentLoop = ReactLoop
  tool_executor.py     ← Unchanged
  agent_tools.py       ← Unchanged
  error_recovery.py    ← Unchanged
  sub_agent.py         ← Simplified: factory logic moves to LoopRuntime
  models.py            ← LoopResult (may merge into strategy.py)
```

---

## 12. Open Questions

1. **Strategy selection mechanism** — Configuration? Policy feature flag? Per-task parameter from Desktop App? All three? Start with config + env var, add policy flags later.

2. **Strategy-specific parameters** — `ReactLoop` needs `max_steps`, `ReflectLoop` needs `reflect_interval`. Use a `strategy_config: dict` bag, or typed config per strategy? Typed configs are safer but require SessionManager to know about each strategy.

3. **Shared utility methods** — `_execute_tools` and `_track_tool_errors` will be duplicated across strategies. Extract a `LoopMixin` or utility module? Or accept some duplication for strategy independence? Lean toward a utility module (`loop_utils.py`) for common patterns that strategies can opt into.

4. **Event contract** — Should step events (step_started, step_completed) be mandatory for all strategies, or optional? If a PlanThenExecuteLoop has a "planning phase" that isn't really a "step," does it emit step events? Lean toward: strategies emit events at whatever granularity makes sense for them — the harness provides the primitives, strategies decide.
