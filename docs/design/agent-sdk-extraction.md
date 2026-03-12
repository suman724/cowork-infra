# Agent SDK Extraction — Design Doc

**Status:** Proposed
**Repos:** `cowork-agent-sdk` (new), `cowork-agent-runtime` (modified)
**Phase:** Infrastructure refactoring (no user-facing behavior changes)

---

## Motivation

The `agent_host/` package in `cowork-agent-runtime` currently mixes two concerns:

1. **Reusable agent building blocks** — LLM clients, message threads, context compaction, memory management, policy enforcement, token budgeting, loop strategies, error recovery, skill loading, checkpointing
2. **Cowork application wiring** — event emission, transport protocols, session lifecycle, sandbox orchestration, service HTTP clients, JSON-RPC handlers

These are entangled in a flat module structure where `SessionManager` directly constructs `LoopRuntime` by wiring 15+ components together. This makes it difficult to:

- Test loop strategies without mocking the full infrastructure stack
- Build alternative agents (team loops, plan-and-execute, headless CLI) using the same primitives
- Improve individual components (compactor, memory, LLM client) without risking session lifecycle regressions
- Reason about dependency direction — everything imports everything
- Reuse agent primitives in future agent implementations (web agents, specialized agents, third-party agents)

### Goal

Extract reusable building blocks into a new standalone repo (`cowork-agent-sdk`) that can be pip-installed as a dependency. Slim `agent_host/` in `cowork-agent-runtime` to the cowork-specific application shell that wires SDK components together with real infrastructure.

By making this a separate package now, we enforce clean boundaries from day one and avoid accumulating bad dependencies as we build more agents.

### Non-Goals

- Refactor `tool_runtime/` (already well-isolated)
- Change any runtime behavior, API contracts, or event formats
- Add new features or capabilities
- Publish to PyPI (same local-path/git dependency strategy as `cowork-platform`)

---

## Repository & Package Layout

### New Repo: `cowork-agent-sdk`

| Property | Value |
|----------|-------|
| Repo name | `cowork-agent-sdk` |
| Python package name | `cowork-agent-sdk` |
| Python import name | `agent_sdk` |
| Language | Python 3.12+ |
| Build system | hatchling (same as `cowork-platform`) |
| Tooling | ruff, mypy --strict, pytest, pytest-asyncio |

The SDK follows the same patterns established by `cowork-platform`:
- **Local development**: `pip install -e "../cowork-agent-sdk"` (path dependency)
- **CI**: `cowork-agent-sdk @ git+https://github.com/suman724/cowork-agent-sdk.git@main`
- **No registry publishing** for now — same strategy as `cowork-platform`

### Dependency Chain

```
cowork-platform          ← shared contracts (Pydantic models, error codes)
       ↑
cowork-agent-sdk         ← reusable agent building blocks
       ↑
cowork-agent-runtime     ← cowork application (agent_host + tool_runtime)
```

`cowork-agent-sdk` depends on `cowork-platform` (for `PolicyBundle`, `ToolDefinition`, `ToolRequest`, `ToolResult`, and SDK constants like `CapabilityName`, `ErrorCode`).

`cowork-agent-runtime` depends on both `cowork-agent-sdk` and `cowork-platform`.

### Package Split

### Guiding Principle

**`agent_sdk`** (in `cowork-agent-sdk` repo) = components any agent could use. No knowledge of cowork services, event plumbing, or transport.

**`agent_host`** + **`tool_runtime`** (in `cowork-agent-runtime` repo) = cowork's application layer. Wires SDK components with real HTTP clients, event emission, session lifecycle, and sandbox infrastructure.

### Dependency Rules

```
cowork-platform  ←──  cowork-agent-sdk  ←──  cowork-agent-runtime
                                                    │
                          agent_sdk  ✗→ agent_host     (never — separate repo enforces this)
                          agent_sdk  ✗→ tool_runtime   (never — separate repo enforces this)
                          tool_runtime ✗→ agent_host   (never — existing boundary)
                          tool_runtime ✗→ agent_sdk    (never — no dependency)
```

Since `agent_sdk` lives in a separate repo, the boundary is physically enforced — it literally cannot import `agent_host` or `tool_runtime`. This is stronger than an import linter.

---

## What Goes Where

### cowork-agent-sdk (separate repo) — Reusable Building Blocks

Portable components with no cowork infrastructure dependencies. External dependencies limited to: `cowork-platform`, `openai`, `httpx`, `structlog`, `tiktoken`, `pydantic`, `tenacity`.

| Module | Source (current location) | Contents |
|--------|--------------------------|----------|
| `loop/` | `agent_host/loop/` | `LoopContext` protocol, `LoopStrategy` protocol, `ReactLoop`, `ErrorRecovery`, `VerificationConfig`, `SystemPromptBuilder`, `LoopResult`, `ToolCallResult` |
| `thread/` | `agent_host/thread/` | `MessageThread`, `CompactionStrategy` protocol, `DropOldestCompactor`, `HybridCompactor`, `estimate_message_tokens()`, `estimate_tokens()` |
| `memory/` | `agent_host/memory/` | `WorkingMemory`, `PersistentMemory`, `Plan`, `TaskTracker`, `MemoryManager`, `ProjectInstructionsLoader` |
| `policy/` | `agent_host/policy/` | `PolicyEnforcer`, `path_matcher`, `command_matcher`, `domain_matcher`, `risk_assessor` |
| `llm/` | `agent_host/llm/` | `LLMClient`, `LLMResponse`, `ToolCallMessage`, `error_classifier` |
| `budget/` | `agent_host/budget/` | `TokenBudget` |
| `approval/` | `agent_host/approval/` | `ApprovalGate` (async Future mechanism only — not the HTTP client) |
| `skills/` | `agent_host/skills/` | `SkillLoader`, `SkillDefinition`, `substitute_arguments()` |
| `checkpoint/` | `agent_host/session/checkpoint_manager.py` | `CheckpointManager`, `SessionCheckpoint` |
| `tracking/` | `agent_host/agent/file_change_tracker.py` | `FileChangeTracker` |
| `models.py` | `agent_host/models.py` | `SessionContext`, `PolicyCheckResult` |
| `exceptions.py` | `agent_host/exceptions.py` | Full `AgentHostError` hierarchy |

### cowork-agent-runtime (existing repo) — Cowork Application Layer

`agent_host/` — infrastructure wiring, event plumbing, service clients, session lifecycle.

| Module | Contents | Why agent_host |
|--------|----------|----------------|
| `loop/` | `LoopRuntime` (implements `LoopContext`), `ToolExecutor`, `AgentToolHandler` | Wires SDK primitives + event emission + service clients into concrete runtime |
| `session/` | `SessionManager`, `SessionClient`, `WorkspaceClient`, `ApprovalClient` | Cowork session lifecycle + HTTP clients for cowork backend services |
| `events/` | `EventEmitter`, `EventBuffer` | Cowork-specific event notifications to transport layer |
| `transport/` | `Transport` protocol, `StdioTransport`, `HttpTransport`, `JsonRpc`, `MethodDispatcher` | Cowork-specific communication (JSON-RPC, SSE, stdio) |
| `server/` | `Handlers` | JSON-RPC method → SessionManager delegation |
| `sandbox/` | `startup.py`, `workspace_sync.py` | Cowork sandbox self-registration, ECS metadata, workspace file sync |
| `config.py` | `AgentHostConfig` | Cowork env var configuration |
| `main.py` | Process entry point | Cowork CLI bootstrap |

`tool_runtime/` — unchanged. Continues to export `ToolRouter`, `ExecutionContext`, `ToolExecutionResult`, `ArtifactData`, `ImageContent`.

---

## Key Interface: LoopContext Protocol

The central design element is a protocol that defines what any `LoopStrategy` needs from its runtime environment. Today `ReactLoop` accesses `LoopRuntime` directly. After extraction, `ReactLoop` depends only on this protocol — `LoopRuntime` in `agent_host/` implements it.

```python
# agent_sdk/loop/context.py

from __future__ import annotations

from typing import TYPE_CHECKING, Any, Protocol, runtime_checkable

if TYPE_CHECKING:
    from collections.abc import Callable

    from agent_sdk.budget.token_budget import TokenBudget
    from agent_sdk.llm.models import LLMResponse, ToolCallMessage
    from agent_sdk.loop.error_recovery import ErrorRecovery
    from agent_sdk.loop.models import ToolCallResult
    from agent_sdk.memory.memory_manager import MemoryManager
    from agent_sdk.memory.working_memory import WorkingMemory
    from agent_sdk.thread.compactor import ContextCompactor
    from agent_sdk.thread.message_thread import MessageThread


@runtime_checkable
class LoopContext(Protocol):
    """Runtime environment for loop strategies.

    Defines the primitives a LoopStrategy needs to execute.
    Implemented by agent_host's LoopRuntime which wires in
    real event emission, service clients, and approval flow.

    Strategies MUST only depend on this protocol, never on
    the concrete LoopRuntime implementation.
    """

    # ── Read-only state ──────────────────────────────────────

    @property
    def thread(self) -> MessageThread: ...

    @property
    def compactor(self) -> ContextCompactor: ...

    @property
    def working_memory(self) -> WorkingMemory | None: ...

    @property
    def memory_manager(self) -> MemoryManager | None: ...

    @property
    def error_recovery(self) -> ErrorRecovery: ...

    @property
    def token_budget(self) -> TokenBudget: ...

    @property
    def max_context_tokens(self) -> int: ...

    @property
    def plan_mode_locked(self) -> bool: ...

    # ── Primitives ───────────────────────────────────────────

    def is_cancelled(self) -> bool: ...

    def new_step_id(self) -> str: ...

    # ── LLM ──────────────────────────────────────────────────

    async def call_llm(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]],
        task_id: str,
        step_id: str,
        on_text_chunk: Callable[[str], None] | None = None,
    ) -> LLMResponse: ...

    # ── Tool execution ───────────────────────────────────────

    def get_external_tool_defs(self) -> list[dict[str, Any]]: ...

    def get_agent_tool_defs(self) -> list[dict[str, Any]]: ...

    async def execute_external_tools(
        self,
        tool_calls: list[ToolCallMessage],
        task_id: str,
        step_id: str,
    ) -> list[ToolCallResult]: ...

    async def execute_agent_tool(
        self,
        tool_call: ToolCallMessage,
        task_id: str,
    ) -> dict[str, Any]: ...

    def is_agent_tool(self, tool_name: str) -> bool: ...

    # ── Events (fire-and-forget) ─────────────────────────────

    def emit_step_started(self, task_id: str, step: int, step_id: str) -> None: ...
    def emit_step_completed(self, task_id: str, step: int, step_id: str) -> None: ...
    def emit_text_chunk(self, task_id: str, text: str, step_id: str) -> None: ...
    def emit_step_limit_approaching(self, task_id: str, step: int, max_steps: int) -> None: ...
    def emit_task_failed(self, task_id: str, reason: str) -> None: ...
    def emit_context_compacted(
        self, task_id: str, dropped: int, pre_count: int, post_count: int, step_id: str
    ) -> None: ...
    def emit_plan_updated(
        self, task_id: str, goal: str, steps: list[dict[str, object]]
    ) -> None: ...
    def emit_plan_mode_changed(self, task_id: str, plan_mode: bool, source: str) -> None: ...
    def emit_verification_started(self, task_id: str) -> None: ...
    def emit_verification_completed(self, task_id: str, *, passed: bool) -> None: ...

    # ── Lifecycle callbacks ──────────────────────────────────

    async def on_step_complete(self, task_id: str, step: int) -> None: ...
```

### Why a Protocol, Not an Abstract Base Class

- `ReactLoop` can be tested with a simple mock or dataclass that satisfies `LoopContext` — no inheritance required
- `LoopRuntime` in `agent_host/` doesn't need to explicitly inherit from anything in `agent_sdk` — structural subtyping is sufficient
- Third-party consumers can implement `LoopContext` with their own infrastructure without importing agent_host

### What ReactLoop Changes

Minimal. The only change is the type annotation:

```python
# Before (in agent_host/loop/react_loop.py)
class ReactLoop:
    def __init__(self, harness: LoopRuntime, ...): ...

# After (in agent_sdk/loop/react_loop.py)
class ReactLoop:
    def __init__(self, harness: LoopContext, ...): ...
```

`ReactLoop` already accesses `LoopRuntime` only through public methods and properties. Every method `ReactLoop` calls is captured in the `LoopContext` protocol. No logic changes required.

### What LoopRuntime Changes

`LoopRuntime` stays in `agent_host/loop/loop_runtime.py`. Its constructor and methods are unchanged. It satisfies `LoopContext` via structural typing (duck typing) — no explicit `class LoopRuntime(LoopContext)` needed, though adding it as documentation is optional.

The key change: `LoopRuntime` now imports SDK components from `agent_sdk.*` instead of `agent_host.*`:

```python
# Before
from agent_host.llm.client import LLMClient
from agent_host.budget.token_budget import TokenBudget

# After
from agent_sdk.llm.client import LLMClient
from agent_sdk.budget.token_budget import TokenBudget
```

---

## New Repo: cowork-agent-sdk

### Repository Structure

```
cowork-agent-sdk/
├── CLAUDE.md
├── README.md
├── Makefile
├── pyproject.toml
├── .python-version                 # 3.12
├── .env.example
├── .github/
│   └── workflows/
│       └── ci.yml
├── src/
│   └── agent_sdk/                  # ~4,500 LOC — portable building blocks
│       ├── __init__.py             # Public API exports
│       ├── exceptions.py           # AgentHostError hierarchy
│       ├── models.py               # SessionContext, PolicyCheckResult
│       │
│       ├── loop/                   # Agent loop strategies & protocols
│       │   ├── __init__.py
│       │   ├── context.py          # LoopContext protocol (NEW)
│       │   ├── strategy.py         # LoopStrategy protocol
│       │   ├── react_loop.py       # ReactLoop (harness type → LoopContext)
│       │   ├── error_recovery.py   # ErrorRecovery
│       │   ├── verification.py     # VerificationConfig
│       │   ├── system_prompt.py    # SystemPromptBuilder
│       │   └── models.py           # LoopResult, ToolCallResult
│       │
│       ├── thread/                 # Conversation thread management
│       │   ├── __init__.py
│       │   ├── message_thread.py   # MessageThread
│       │   ├── compactor.py        # CompactionStrategy, DropOldest, Hybrid
│       │   └── token_counter.py    # Token estimation utilities
│       │
│       ├── memory/                 # Agent memory systems
│       │   ├── __init__.py
│       │   ├── working_memory.py   # WorkingMemory
│       │   ├── persistent_memory.py # PersistentMemory
│       │   ├── plan.py             # Plan
│       │   ├── task_tracker.py     # TaskTracker
│       │   ├── memory_manager.py   # MemoryManager
│       │   └── project_instructions.py # ProjectInstructionsLoader
│       │
│       ├── policy/                 # Policy enforcement (pure, no I/O)
│       │   ├── __init__.py
│       │   ├── policy_enforcer.py  # PolicyEnforcer
│       │   ├── path_matcher.py     # check_path()
│       │   ├── command_matcher.py  # check_command()
│       │   ├── domain_matcher.py   # check_domain()
│       │   └── risk_assessor.py    # assess_risk()
│       │
│       ├── llm/                    # LLM Gateway client
│       │   ├── __init__.py
│       │   ├── client.py           # LLMClient
│       │   ├── models.py           # LLMResponse, ToolCallMessage
│       │   └── error_classifier.py # Transient error detection
│       │
│       ├── budget/                 # Token budget accounting
│       │   ├── __init__.py
│       │   └── token_budget.py     # TokenBudget
│       │
│       ├── approval/               # Approval gate mechanism
│       │   ├── __init__.py
│       │   └── approval_gate.py    # ApprovalGate
│       │
│       ├── skills/                 # Skill discovery & loading
│       │   ├── __init__.py
│       │   ├── skill_loader.py     # SkillLoader, substitute_arguments
│       │   └── models.py           # SkillDefinition
│       │
│       ├── checkpoint/             # Crash recovery persistence
│       │   ├── __init__.py
│       │   └── checkpoint_manager.py # CheckpointManager, SessionCheckpoint
│       │
│       └── tracking/               # File change tracking
│           ├── __init__.py
│           └── file_change_tracker.py # FileChangeTracker
│
└── tests/
    ├── conftest.py
    ├── unit/
    │   ├── loop/
    │   ├── thread/
    │   ├── memory/
    │   ├── policy/
    │   ├── llm/
    │   ├── budget/
    │   ├── approval/
    │   ├── skills/
    │   ├── checkpoint/
    │   └── tracking/
    └── fixtures/                   # Shared test data (policy bundles, mock LLM)
```

### pyproject.toml (cowork-agent-sdk)

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "cowork-agent-sdk"
version = "0.1.0"
description = "Reusable agent building blocks for the cowork platform"
requires-python = ">=3.12"
dependencies = [
    "cowork-platform[sdk]",
    "openai>=1.60,<2.0",
    "pydantic>=2.0,<3.0",
    "httpx>=0.27,<1.0",
    "tenacity>=9.0,<10.0",
    "structlog>=24.0,<26.0",
    "pyyaml>=6.0,<7.0",
]

[project.optional-dependencies]
dev = [
    "ruff>=0.8,<1.0",
    "mypy>=1.13,<2.0",
    "pytest>=8.0,<9.0",
    "pytest-asyncio>=0.24,<1.0",
    "coverage>=7.0,<8.0",
    "types-PyYAML",
]

[tool.hatch.build.targets.wheel]
packages = ["src/agent_sdk"]
```

### Makefile Targets (cowork-agent-sdk)

Standard targets following existing conventions:

```makefile
install:     pip install -e "../cowork-platform[sdk]" -e ".[dev]"
lint:        ruff check src/ tests/
format:      ruff format src/ tests/
format-check: ruff format --check src/ tests/
typecheck:   mypy src/
test:        pytest -m "unit or not integration" -x -q
build:       python -m build
check:       lint + format-check + typecheck + test  (CI gate)
clean:       rm -rf build/ dist/ .mypy_cache/ .pytest_cache/
```

### CI Pipeline (cowork-agent-sdk)

Same pattern as `cowork-platform`:

```yaml
# .github/workflows/ci.yml
on: [push, pull_request]  # All branches, no filter

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - run: pip install "cowork-platform[sdk] @ git+https://github.com/suman724/cowork-platform.git@main"
      - run: pip install -e ".[dev]"
      - run: ruff check src/ tests/
      - run: ruff format --check src/ tests/
      - run: mypy src/
      - run: pytest -m "unit or not integration" -x -q

  build:
    needs: check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - run: pip install "cowork-platform[sdk] @ git+https://github.com/suman724/cowork-platform.git@main"
      - run: pip install -e ".[dev]"
      - run: python -m build
      # Verify package contents
      - run: pip install "$(ls dist/*.whl)"
      - run: python -c "from agent_sdk import LoopContext, ReactLoop, PolicyEnforcer; print('OK')"
```

### Dependency Changes in cowork-agent-runtime

```toml
# cowork-agent-runtime/pyproject.toml — updated dependencies
dependencies = [
    "cowork-platform[sdk]",
    "cowork-agent-sdk",           # NEW — replaces inline agent_sdk modules
    "openai>=1.60,<2.0",
    # ... rest unchanged
]
```

```makefile
# cowork-agent-runtime/Makefile — updated install target
install:
    pip install -e "../cowork-platform[sdk]" -e "../cowork-agent-sdk" -e ".[dev]"
```

```yaml
# cowork-agent-runtime/.github/workflows/ci.yml — updated CI
- run: pip install "cowork-platform[sdk] @ git+https://github.com/suman724/cowork-platform.git@main"
- run: pip install "cowork-agent-sdk @ git+https://github.com/suman724/cowork-agent-sdk.git@main"
- run: pip install -e ".[dev]"
```

---

## Directory Structure After Extraction

### cowork-agent-runtime (after extraction)

```
cowork-agent-runtime/
└── src/
    ├── agent_host/                 # ~4,500 LOC — cowork application layer
    │   ├── __init__.py
    │   ├── config.py               # AgentHostConfig (stays)
    │   ├── main.py                 # Process entry point (stays)
    │   │
    │   ├── loop/                   # Concrete runtime wiring
    │   │   ├── __init__.py
    │   │   ├── loop_runtime.py     # LoopRuntime — implements LoopContext (stays)
    │   │   ├── tool_executor.py    # ToolExecutor — policy+approval+events (stays)
    │   │   └── agent_tools.py      # AgentToolHandler — internal tools (stays)
    │   │
    │   ├── session/                # Session lifecycle & service clients
    │   │   ├── __init__.py
    │   │   ├── session_manager.py  # SessionManager (stays)
    │   │   ├── session_client.py   # Session Service HTTP client (stays)
    │   │   ├── workspace_client.py # Workspace Service HTTP client (stays)
    │   │   └── approval_client.py  # Approval Service HTTP client (stays)
    │   │
    │   ├── events/                 # Event emission & buffering
    │   │   ├── __init__.py
    │   │   ├── event_emitter.py    # EventEmitter (stays)
    │   │   └── event_buffer.py     # EventBuffer (stays)
    │   │
    │   ├── transport/              # Communication protocols
    │   │   ├── __init__.py
    │   │   ├── transport.py        # Transport protocol (moved from server/)
    │   │   ├── stdio_transport.py  # StdioTransport (moved from server/)
    │   │   ├── http_transport.py   # HttpTransport (moved from server/)
    │   │   ├── json_rpc.py         # JSON-RPC 2.0 (moved from server/)
    │   │   └── method_dispatcher.py # MethodDispatcher (moved from server/)
    │   │
    │   ├── server/                 # JSON-RPC handlers
    │   │   ├── __init__.py
    │   │   └── handlers.py         # Method → SessionManager delegation (stays)
    │   │
    │   └── sandbox/                # Sandbox infrastructure
    │       ├── __init__.py
    │       ├── startup.py          # Self-registration (stays)
    │       └── workspace_sync.py   # Workspace file sync (stays)
    │
    └── tool_runtime/               # ~3,000 LOC — unchanged
        └── (no changes)
```

---

## What Moves, What Stays

### Moves: agent_host → cowork-agent-sdk (pure moves, no logic changes)

Files are moved from `cowork-agent-runtime/src/agent_host/` to `cowork-agent-sdk/src/agent_sdk/`.

| File (current in agent-runtime) | Destination (in agent-sdk) | Changes Required |
|--------------------------------|---------------------------|------------------|
| `agent_host/loop/strategy.py` | `agent_sdk/loop/strategy.py` | Import path only |
| `agent_host/loop/react_loop.py` | `agent_sdk/loop/react_loop.py` | Import paths + `harness` type annotation → `LoopContext` |
| `agent_host/loop/error_recovery.py` | `agent_sdk/loop/error_recovery.py` | Import path only |
| `agent_host/loop/verification.py` | `agent_sdk/loop/verification.py` | Import path only |
| `agent_host/loop/system_prompt.py` | `agent_sdk/loop/system_prompt.py` | Import path only |
| `agent_host/loop/models.py` | `agent_sdk/loop/models.py` | Import path only |
| `agent_host/thread/message_thread.py` | `agent_sdk/thread/message_thread.py` | Import path only |
| `agent_host/thread/compactor.py` | `agent_sdk/thread/compactor.py` | Import path only |
| `agent_host/thread/token_counter.py` | `agent_sdk/thread/token_counter.py` | Import path only |
| `agent_host/memory/*.py` (all 6 files) | `agent_sdk/memory/*.py` | Import path only |
| `agent_host/policy/*.py` (all 5 files) | `agent_sdk/policy/*.py` | Import path only |
| `agent_host/llm/*.py` (all 3 files) | `agent_sdk/llm/*.py` | Import path only |
| `agent_host/budget/token_budget.py` | `agent_sdk/budget/token_budget.py` | Import path only |
| `agent_host/approval/approval_gate.py` | `agent_sdk/approval/approval_gate.py` | Import path only |
| `agent_host/skills/skill_loader.py` | `agent_sdk/skills/skill_loader.py` | Import path only |
| `agent_host/skills/models.py` | `agent_sdk/skills/models.py` | Import path only |
| `agent_host/session/checkpoint_manager.py` | `agent_sdk/checkpoint/checkpoint_manager.py` | Import path only |
| `agent_host/agent/file_change_tracker.py` | `agent_sdk/tracking/file_change_tracker.py` | Import path only |
| `agent_host/models.py` | `agent_sdk/models.py` | Import path only |
| `agent_host/exceptions.py` | `agent_sdk/exceptions.py` | Import path only |

**New file:** `agent_sdk/loop/context.py` — the `LoopContext` protocol (see above).

### Stays in agent_host (with updated imports)

| File | Why it stays |
|------|-------------|
| `loop/loop_runtime.py` | Wires SDK primitives + emits events via EventEmitter + manages service coupling |
| `loop/tool_executor.py` | Policy check + approval gate + event emission + artifact upload + plan mode filtering |
| `loop/agent_tools.py` | Registers cowork-specific internal tools, wires callbacks to LoopRuntime |
| `session/session_manager.py` | Cowork session lifecycle, constructs all components, manages checkpoints |
| `session/session_client.py` | HTTP client for cowork Session Service |
| `session/workspace_client.py` | HTTP client for cowork Workspace Service |
| `session/approval_client.py` | HTTP client for cowork Approval Service |
| `events/event_emitter.py` | Cowork event notification plumbing |
| `events/event_buffer.py` | Ring buffer for SSE replay |
| `server/handlers.py` | JSON-RPC method delegation |
| `sandbox/startup.py` | ECS self-registration |
| `sandbox/workspace_sync.py` | Workspace file sync |
| `config.py` | Cowork env var configuration |
| `main.py` | Process entry point |

### Moves within agent_host (reorganization)

| File (current) | Destination | Reason |
|----------------|-------------|--------|
| `agent_host/server/transport.py` | `agent_host/transport/transport.py` | Conceptually transport, not server |
| `agent_host/server/stdio_transport.py` | `agent_host/transport/stdio_transport.py` | Same |
| `agent_host/server/http_transport.py` | `agent_host/transport/http_transport.py` | Same |
| `agent_host/server/json_rpc.py` | `agent_host/transport/json_rpc.py` | Same |
| `agent_host/server/method_dispatcher.py` | `agent_host/transport/method_dispatcher.py` | Same |
| `agent_host/server/event_buffer.py` | `agent_host/events/event_buffer.py` | Conceptually events, not server |
| `agent_host/server/handlers.py` | `agent_host/server/handlers.py` | Stays in server/ (only file left) |

---

## Import Changes

### ReactLoop (the key change)

```python
# Before (agent_host/loop/react_loop.py)
from agent_host.loop.models import LoopResult
from agent_host.thread.token_counter import estimate_message_tokens
if TYPE_CHECKING:
    from agent_host.llm.models import ToolCallMessage
    from agent_host.loop.loop_runtime import LoopRuntime
    from agent_host.loop.verification import VerificationConfig

class ReactLoop:
    def __init__(self, harness: LoopRuntime, ...): ...

# After (agent_sdk/loop/react_loop.py)
from agent_sdk.loop.models import LoopResult
from agent_sdk.thread.token_counter import estimate_message_tokens
if TYPE_CHECKING:
    from agent_sdk.llm.models import ToolCallMessage
    from agent_sdk.loop.context import LoopContext
    from agent_sdk.loop.verification import VerificationConfig

class ReactLoop:
    def __init__(self, harness: LoopContext, ...): ...
```

### LoopRuntime (stays in agent_host, imports change)

```python
# Before (agent_host/loop/loop_runtime.py)
from agent_host.loop.error_recovery import ErrorRecovery
if TYPE_CHECKING:
    from agent_host.budget.token_budget import TokenBudget
    from agent_host.llm.client import LLMClient
    # ...

# After (agent_host/loop/loop_runtime.py)
from agent_sdk.loop.error_recovery import ErrorRecovery
if TYPE_CHECKING:
    from agent_sdk.budget.token_budget import TokenBudget
    from agent_sdk.llm.client import LLMClient
    # ...
    # Still imports agent_host-specific things:
    from agent_host.loop.tool_executor import ToolExecutor
    from agent_host.loop.agent_tools import AgentToolHandler
    from agent_host.events.event_emitter import EventEmitter
```

### SessionManager (stays in agent_host, imports change)

```python
# Before
from agent_host.loop.loop_runtime import LoopRuntime
from agent_host.loop.react_loop import ReactLoop
from agent_host.thread.message_thread import MessageThread
from agent_host.policy.policy_enforcer import PolicyEnforcer
# ...

# After
from agent_host.loop.loop_runtime import LoopRuntime  # stays agent_host
from agent_sdk.loop.react_loop import ReactLoop        # now from SDK
from agent_sdk.thread.message_thread import MessageThread  # now from SDK
from agent_sdk.policy.policy_enforcer import PolicyEnforcer  # now from SDK
# ...
```

---

## Re-exports for Backward Compatibility

`agent_host/__init__.py` re-exports from `agent_sdk` so tests and any code importing from `agent_host` continues to work:

```python
# agent_host/__init__.py (in cowork-agent-runtime)
from agent_sdk.exceptions import AgentHostError
from agent_sdk.models import PolicyCheckResult, SessionContext
from agent_host.config import AgentHostConfig

# Re-export for backward compatibility
__all__ = [
    "AgentHostConfig",
    "AgentHostError",
    "PolicyCheckResult",
    "SessionContext",
]
```

Since `agent_host` is not published as a library (only consumed within `cowork-agent-runtime` and its tests), the re-exports are primarily for test import stability during migration.

---

## Test Migration

Tests move from `cowork-agent-runtime` to `cowork-agent-sdk` alongside their source:

| Test file (current in agent-runtime) | Destination (in agent-sdk) |
|--------------------------------------|---------------------------|
| `tests/unit/agent_host/loop/test_react_loop.py` | `tests/unit/loop/test_react_loop.py` |
| `tests/unit/agent_host/thread/test_*.py` | `tests/unit/thread/test_*.py` |
| `tests/unit/agent_host/memory/test_*.py` | `tests/unit/memory/test_*.py` |
| `tests/unit/agent_host/policy/test_*.py` | `tests/unit/policy/test_*.py` |
| `tests/unit/agent_host/llm/test_*.py` | `tests/unit/llm/test_*.py` |
| `tests/unit/agent_host/budget/test_*.py` | `tests/unit/budget/test_*.py` |
| ... | ... |

Tests for `agent_host/` components (LoopRuntime, ToolExecutor, SessionManager, etc.) stay in `cowork-agent-runtime/tests/unit/agent_host/`.

Integration tests (`test-chat`, `test-sandbox`) stay in `cowork-agent-runtime` — they exercise the full stack which still works identically.

Shared test fixtures (policy bundles, mock LLM responses) that are used by both repos should be duplicated or extracted into a shared fixtures module in `cowork-agent-sdk`.

---

## Boundary Enforcement

### Physical Separation (Primary)

The strongest boundary enforcement is physical: `agent_sdk` lives in a separate repo (`cowork-agent-sdk`). It literally cannot import `agent_host` or `tool_runtime` — those packages don't exist in its environment. This is enforced by:

- **Separate `pyproject.toml`** — `cowork-agent-sdk` only depends on `cowork-platform`, `openai`, `httpx`, etc. No dependency on `cowork-agent-runtime`.
- **CI builds in isolation** — `cowork-agent-sdk` CI installs only its own dependencies. If any module imports `agent_host`, the import fails at test time.
- **mypy catches it** — any `from agent_host import ...` is a missing module error.

### Import Linter (Secondary — for agent_host ↔ tool_runtime boundary)

The existing `agent_host` ↔ `tool_runtime` boundary within `cowork-agent-runtime` is enforced by `import-linter`:

```ini
# cowork-agent-runtime pyproject.toml

[importlinter]
root_packages = agent_host,tool_runtime

[importlinter:contract:tool-runtime-independence]
name = tool_runtime must not import agent_host
type = forbidden
source_modules = tool_runtime
forbidden_modules = agent_host
```

Add `import-linter` to `cowork-agent-runtime` dev dependencies and wire into `make lint` and CI.

---

## What This Enables

### Today (this refactoring)

- `ReactLoop` tested with a mock `LoopContext` — no EventEmitter, no HTTP clients, no service mocking
- Clear dependency direction enforced by import linter
- Individual SDK modules (policy, memory, compactor, LLM client) improved and tested in isolation

### Future (not part of this work)

- Alternative loop strategies (`PlanAndExecuteLoop`, `TeamLoop`) that implement `LoopStrategy` and consume `LoopContext`
- Headless agent (no transport, no session service) for CLI/script use — build `LoopContext` with stubs
- Extract `agent_sdk` to its own package/repo when there's a second consumer
- Third-party agents built on SDK primitives

---

## Risk Assessment

### What Could Go Wrong

| Risk | Mitigation |
|------|-----------|
| Circular imports after move | `LoopContext` protocol breaks the cycle — SDK defines the interface, agent_host implements it. Physical repo separation makes SDK→agent_host imports impossible. |
| Test failures from import path changes | Mechanical find-and-replace. Run full test suite after each module move. |
| Sub-agent spawning breaks (LoopRuntime self-reference) | `spawn_sub_agent()` and `execute_skill()` stay in `LoopRuntime` (agent_host). They construct child `LoopRuntime` instances and call `ReactLoop` from agent_sdk. The import direction is agent_host → agent_sdk, which is allowed. |
| Desktop mode regression | No behavior changes. Same LoopRuntime, same SessionManager, same Transport. Only import paths change. |
| Sandbox mode regression | Same — sandbox code stays in agent_host. `workspace_sync` and `startup` are untouched. |
| Shared test fixtures | Some tests use fixtures (policy bundles, mock LLM responses) that exist in agent-runtime. Copy needed fixtures to agent-sdk. Both repos can maintain their own fixtures independently. |
| CI dependency chain | `cowork-agent-runtime` CI must install `cowork-agent-sdk` from git before running tests. Same pattern as `cowork-platform` — proven to work. |
| Two-repo development friction | Local development uses path dependencies (`pip install -e "../cowork-agent-sdk"`). Changes to SDK are immediately visible in agent-runtime without publish/install cycles. Same workflow as `cowork-platform`. |
| Version drift between SDK and runtime | Both repos pin to `@main` in CI. For local dev, both are editable installs. Breaking changes in SDK are caught immediately by agent-runtime's test suite. |

### Verification Strategy

- `make check` in `cowork-agent-sdk` after each module is added (SDK tests pass in isolation)
- `make check` in `cowork-agent-runtime` after each module is removed + imports updated
- `make test-chat` (end-to-end desktop flow) after completing all moves
- `make test-sandbox` (end-to-end sandbox flow) after completing all moves
- SDK CI passes in isolation (no agent-runtime dependency)
- Agent-runtime CI passes with SDK as git dependency

---

## Status Tracker

| Step | Name | Repo | Status | Branch | Notes |
|------|------|------|--------|--------|-------|
| 1 | Create cowork-agent-sdk Repo | `cowork-agent-sdk`, `cowork-agent-runtime` | ✅ Done | `feature/agent-sdk-extraction` | Scaffold + CI + dependency wiring |
| 2 | LoopContext Protocol | `cowork-agent-sdk`, `cowork-agent-runtime` | ✅ Done | `feature/agent-sdk-extraction` | Protocol + has_event_emitter property |
| 3 | Move Leaf Modules | `cowork-agent-sdk`, `cowork-agent-runtime` | ✅ Done | `feature/agent-sdk-extraction` | 8 source files + 4 test files moved, 831 runtime tests pass |
| 4 | Move Policy Module | `cowork-agent-sdk`, `cowork-agent-runtime` | ✅ Done | `feature/agent-sdk-extraction` | 5 source + 4 test files moved, 760 runtime tests pass |
| 5 | Move Thread Module | `cowork-agent-sdk`, `cowork-agent-runtime` | ✅ Done | `feature/agent-sdk-extraction` | 2 source + 3 test files moved, O(n²)→O(n) compaction fix, 724 runtime tests pass |
| 6 | Move Memory Module | `cowork-agent-sdk`, `cowork-agent-runtime` | ✅ Done | `feature/agent-sdk-extraction` | 6 source + 6 test files moved, 622 runtime tests pass |
| 7 | Move LLM Client | `cowork-agent-sdk`, `cowork-agent-runtime` | ✅ Done | `feature/agent-sdk-extraction` | 1 source + 1 test file moved, EventEmitter→Any, 611 runtime tests pass |
| 8 | Move Loop Strategy Components | `cowork-agent-sdk`, `cowork-agent-runtime` | ✅ Done | `feature/agent-sdk-extraction` | 4 source + 2 test files moved, 589 runtime tests pass |
| 9 | Move ReactLoop | `cowork-agent-sdk`, `cowork-agent-runtime` | ✅ Done | `feature/agent-sdk-extraction` | LoopRuntime→LoopContext, new conformance + mock tests, 590 runtime tests pass |
| 10 | Move Remaining SDK Modules | `cowork-agent-sdk`, `cowork-agent-runtime` | ✅ Done | `feature/agent-sdk-extraction` | 4 source files moved (skills, checkpoint, tracking), 590 runtime tests pass |
| 11 | Reorganize agent_host Transport/Events | `cowork-agent-runtime` | ✅ Done | `feature/agent-sdk-extraction` | server/ → transport/ + events/event_buffer, 590 runtime tests pass |
| 12 | Clean Up & Enforce Boundaries | `cowork-agent-sdk`, `cowork-agent-runtime` | ✅ Done | `feature/agent-sdk-extraction` | Dead dirs removed, SDK __init__.py exports, no stale imports, 590+302 tests pass |
| 13 | Update Documentation | `cowork-agent-sdk`, `cowork-agent-runtime`, `cowork-infra` | Not Started | `feature/agent-sdk-extraction` | |

---

## Principles

1. **Incremental delivery**: Each step produces a fully passing `make check` in both repos. Every intermediate state is a valid, working codebase.
2. **Tests from the start**: Every step moves tests alongside source files and verifies they pass with updated imports. New tests added for new code (`LoopContext` protocol conformance).
3. **Existing patterns**: Same project structure, error handling, logging, CI, and Makefile conventions as existing repos. No new patterns — this is a pure restructuring.
4. **No regressions**: All agent-runtime changes are pure import path changes. Desktop (`make test-chat`) and sandbox (`make test-sandbox`) must pass after the final step.
5. **Pre-step review**: Before starting any step, review the files being moved and their dependents. Understand the import graph before touching anything.
6. **Self-review**: Every step includes a mandatory review pass before marking complete. Check for: broken imports, missing `__init__.py` updates, missing re-exports, circular imports (especially cross-repo), `TYPE_CHECKING` guards that now cross the boundary incorrectly, late imports that may break after a move, test imports pointing to old locations, and files accidentally left behind or duplicated.
7. **Documentation sync**: Update all relevant docs when implementation changes — CLAUDE.md files in affected repos, design docs in `cowork-infra/docs/`, README files. Final step updates `architecture.md`, `components/local-agent-host.md`, and this doc's status tracker.
8. **Boundary verification**: After every step, verify `make check` passes in both `cowork-agent-sdk` (SDK tests pass in isolation, no agent_host/tool_runtime available) and `cowork-agent-runtime` (imports from agent_sdk resolve correctly).
9. **Atomic two-repo moves**: Each file is moved exactly once. Add to `cowork-agent-sdk` first (verify SDK tests pass), then update imports in `cowork-agent-runtime` and delete the original (verify runtime tests pass). No file exists in both repos simultaneously (except re-exports in `agent_host/__init__.py`).
10. **Simplify review**: After completing each step, run `/simplify` on all changed files. Fix all legitimate findings before marking the step complete.

---

## Implementation Plan

Each step is an atomic commit that passes `make check`. Steps are ordered to minimize broken intermediate states.

---

### Step 1 — Create cowork-agent-sdk Repo

**Repo:** `cowork-agent-sdk` (new), `cowork-agent-runtime` (dependency update)

Create the new `cowork-agent-sdk` repository with full project scaffold, CI pipeline, and empty package structure. Update `cowork-agent-runtime` to depend on it.

#### Work

**In new `cowork-agent-sdk` repo:**

1. Initialize git repo with `main` branch
2. Create project structure:
   - `pyproject.toml` — hatchling build, `cowork-platform[sdk]` dependency, dev dependencies (ruff, mypy, pytest)
   - `Makefile` — standard targets (install, lint, format, typecheck, test, build, check, clean)
   - `.python-version` — `3.12`
   - `.env.example` — empty (SDK has no env vars)
   - `CLAUDE.md` — architecture context for the SDK
   - `README.md` — setup guide, purpose, development workflow
   - `.github/workflows/ci.yml` — lint, typecheck, test, build (all branches)
   - `.gitignore` — Python standard
3. Create `src/agent_sdk/` with `__init__.py`
4. Create empty `__init__.py` for all subpackages: `loop/`, `thread/`, `memory/`, `policy/`, `llm/`, `budget/`, `approval/`, `skills/`, `checkpoint/`, `tracking/`
5. Create `tests/` directory structure mirroring source
6. Verify `make check` passes (empty package, trivially passes)
7. Push to GitHub

**In `cowork-agent-runtime`:**

8. Add `cowork-agent-sdk` to `pyproject.toml` dependencies
9. Update `Makefile` install target: `pip install -e "../cowork-platform[sdk]" -e "../cowork-agent-sdk" -e ".[dev]"`
10. Update `.github/workflows/ci.yml`: install `cowork-agent-sdk` from git before `.[dev]`
11. Add `import-linter` for `tool_runtime` ↔ `agent_host` boundary (SDK boundary is enforced by repo separation)
12. Verify `make check` passes (no imports from agent_sdk yet, so trivially passes)

#### Definition of Done

- `cowork-agent-sdk` repo exists on GitHub
- `make check` passes in `cowork-agent-sdk` (empty package builds and tests pass)
- `make check` passes in `cowork-agent-runtime` (with SDK as editable install)
- CI pipeline configured for `cowork-agent-sdk` (triggers on all branches)
- `cowork-agent-runtime` CI updated to install SDK from git
- **Self-review**: Verify `pyproject.toml` dependencies are correct in both repos. Verify Makefile install targets use correct paths. Verify CI installs SDK before agent-runtime dev dependencies.
- **Logical bug review**: Verify `cowork-agent-sdk` depends on `cowork-platform[sdk]` (not just `cowork-platform`). Verify `cowork-agent-runtime` still depends on `cowork-platform[sdk]` directly (not transitively through SDK, since local editable installs may not resolve transitives).

#### Principle Checklist

- [ ] P1 Incremental delivery — both repos' `make check` pass
- [ ] P3 Existing patterns — follows same repo structure as `cowork-platform`
- [ ] P4 No regressions — zero runtime changes
- [ ] P6 Self-review — completed, dependency chain verified
- [ ] P7 Documentation sync — CLAUDE.md and README.md created for new repo
- [ ] P10 Simplify review — `/simplify` run, all findings addressed

---

### Step 2 — LoopContext Protocol (agent-sdk)

**Repo:** `cowork-agent-sdk`

Write the `LoopContext` protocol — the only new code in the entire refactoring.

#### Work

1. Create `agent_sdk/loop/context.py` with the `LoopContext` protocol (see protocol definition above)
2. Add unit test: verify `LoopContext` is `runtime_checkable`, verify a mock class satisfying the protocol passes `isinstance` check
3. Update `agent_sdk/loop/__init__.py` to export `LoopContext`

#### Tests

- Unit: `LoopContext` is runtime_checkable
- Unit: Mock implementation satisfies protocol (structural subtyping)
- Unit: Verify all methods/properties match current `LoopRuntime` public API (protocol conformance test)

#### Definition of Done

- `make check` passes
- `import-linter` passes (agent_sdk only imports stdlib + typing)
- `LoopContext` protocol covers every method/property that `ReactLoop` currently calls on `LoopRuntime`
- **Wiring check**: Compare `LoopContext` methods against actual `ReactLoop` usage — every `self._h.xxx()` call in `react_loop.py` must have a corresponding method in the protocol
- **Self-review**: Verify no missing methods by grepping `self._h.` in `react_loop.py`. Verify type annotations match `LoopRuntime`'s current signatures exactly.
- **Logical bug review**: Verify `LoopContext` uses `Protocol` not `ABC` (structural subtyping, no inheritance required). Verify `runtime_checkable` decorator is present. Verify `TYPE_CHECKING` guards are correct — protocol members reference SDK types, not agent_host types.

#### Principle Checklist

- [ ] P1 Incremental delivery — `make check` passes
- [ ] P2 Tests from the start — protocol conformance tests
- [ ] P3 Existing patterns — follows existing protocol patterns (e.g., `Transport`, `LoopStrategy`)
- [ ] P4 No regressions — no runtime changes
- [ ] P6 Self-review — protocol matches ReactLoop's actual usage, no missing methods
- [ ] P8 Boundary verification — agent_sdk imports only stdlib/typing
- [ ] P10 Simplify review — `/simplify` run, all findings addressed

---

### Step 3 — Move Leaf Modules (agent-sdk + agent-runtime)

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`

Move modules with zero internal dependencies — only external libraries and `cowork-platform`.

#### Work

**In `cowork-agent-sdk`** (add files):

1. Copy files from `cowork-agent-runtime/src/agent_host/` to `cowork-agent-sdk/src/agent_sdk/`:
   - `agent_sdk/models.py` ← `agent_host/models.py`
   - `agent_sdk/exceptions.py` ← `agent_host/exceptions.py`
   - `agent_sdk/budget/token_budget.py` ← `agent_host/budget/token_budget.py`
   - `agent_sdk/approval/approval_gate.py` ← `agent_host/approval/approval_gate.py`
   - `agent_sdk/thread/token_counter.py` ← `agent_host/thread/token_counter.py`
   - `agent_sdk/loop/models.py` ← `agent_host/loop/models.py`
   - `agent_sdk/llm/error_classifier.py` ← `agent_host/llm/error_classifier.py`
   - `agent_sdk/llm/models.py` ← `agent_host/llm/models.py`
2. Update internal imports (replace `agent_host.` → `agent_sdk.` within moved files)
3. Copy corresponding test files from `cowork-agent-runtime/tests/` to `cowork-agent-sdk/tests/`
4. Verify `make check` passes in `cowork-agent-sdk`

**In `cowork-agent-runtime`** (remove files, update imports):

5. Delete the original files from `agent_host/`
6. Update all imports in `agent_host/` that reference moved modules → `agent_sdk.*`
7. Add re-exports in `agent_host/__init__.py` for `AgentHostError`, `SessionContext`, `PolicyCheckResult`
8. Remove moved test files, update remaining test imports
9. Verify `make check` passes in `cowork-agent-runtime`

#### Tests

- All existing unit tests for moved modules pass at new locations
- Verify re-exports: `from agent_host import AgentHostError` still works

#### Definition of Done

- `make check` passes (lint + typecheck + test)
- `import-linter` passes — moved modules have no agent_host imports
- No files remain at old locations (no duplicates)
- **Wiring check**: `grep -r "from agent_host.models import"`, `grep -r "from agent_host.exceptions import"`, etc. — all updated to `agent_sdk.*` or using re-exports
- **Self-review**: Verify every file that imported moved modules has been updated. Check both runtime imports and `TYPE_CHECKING` imports. Verify `__init__.py` re-exports are correct.
- **Logical bug review**: Verify no circular imports created. Verify `agent_host/budget/`, `agent_host/approval/` directories can be safely emptied (no other files remain). Verify `agent_host/llm/client.py` (NOT moved yet) still imports `agent_sdk.llm.models` correctly.

#### Principle Checklist

- [ ] P1 Incremental delivery — `make check` passes
- [ ] P2 Tests from the start — all moved tests pass
- [ ] P4 No regressions — zero behavioral changes
- [ ] P6 Self-review — no stale imports, no circular imports, no orphaned files
- [ ] P8 Boundary verification — import-linter passes
- [ ] P9 Atomic two-repo moves — each file exists in exactly one location
- [ ] P10 Simplify review — `/simplify` run, all findings addressed

---

### Step 4 — Move Policy Module (agent-sdk + agent-runtime)

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`

Move all 5 policy files. Pure validation with no agent_host dependencies.

#### Work

1. Move files:
   - `agent_sdk/policy/policy_enforcer.py` ← `agent_host/policy/policy_enforcer.py`
   - `agent_sdk/policy/path_matcher.py` ← `agent_host/policy/path_matcher.py`
   - `agent_sdk/policy/command_matcher.py` ← `agent_host/policy/command_matcher.py`
   - `agent_sdk/policy/domain_matcher.py` ← `agent_host/policy/domain_matcher.py`
   - `agent_sdk/policy/risk_assessor.py` ← `agent_host/policy/risk_assessor.py`
2. Update imports in: `agent_host/loop/loop_runtime.py`, `agent_host/loop/tool_executor.py`, `agent_host/session/session_manager.py`
3. Move corresponding tests
4. Remove empty `agent_host/policy/` directory

#### Definition of Done

- `make check` passes
- `import-linter` passes
- **Wiring check**: grep for `from agent_host.policy` — zero results outside re-exports
- **Self-review**: Verify `PolicyEnforcer` import updated in all 3 consumers. Verify `models.py` import of `PolicyCheckResult` (already moved in Step 3) is consistent.
- **Logical bug review**: Verify `policy_enforcer.py` only imports from `agent_sdk.models` (already moved) and stdlib/pydantic.

#### Principle Checklist

- [ ] P1 Incremental delivery — `make check` passes
- [ ] P2 Tests from the start — policy tests pass at new location
- [ ] P4 No regressions — zero behavioral changes
- [ ] P6 Self-review — no stale `agent_host.policy` imports
- [ ] P8 Boundary verification — import-linter passes
- [ ] P9 Atomic two-repo moves — old directory removed
- [ ] P10 Simplify review — `/simplify` run, all findings addressed

---

### Step 5 — Move Thread Module (agent-sdk + agent-runtime)

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`

Move `message_thread.py` and `compactor.py`. Depends on `token_counter.py` already moved in Step 3.

#### Work

1. Move files:
   - `agent_sdk/thread/message_thread.py` ← `agent_host/thread/message_thread.py`
   - `agent_sdk/thread/compactor.py` ← `agent_host/thread/compactor.py`
2. Update internal imports (compactor imports token_counter — both now in agent_sdk)
3. Update imports in: `agent_host/loop/loop_runtime.py`, `agent_host/session/session_manager.py`
4. Move corresponding tests
5. Remove empty `agent_host/thread/` directory

#### Definition of Done

- `make check` passes
- `import-linter` passes
- **Wiring check**: grep for `from agent_host.thread` — zero results
- **Self-review**: Verify `MessageThread` and `ContextCompactor` imports updated in all consumers. Verify `compactor.py` imports `token_counter` from `agent_sdk.thread`, not `agent_host.thread`.
- **Logical bug review**: Verify `HybridCompactor` (which calls LLM for summarization) has its LLM dependency injected, not hard-imported from agent_host.

#### Principle Checklist

- [ ] P1 Incremental delivery — `make check` passes
- [ ] P2 Tests from the start — thread tests pass at new location
- [ ] P4 No regressions — zero behavioral changes
- [ ] P6 Self-review — no stale `agent_host.thread` imports
- [ ] P8 Boundary verification — import-linter passes
- [ ] P9 Atomic two-repo moves — old directory removed
- [ ] P10 Simplify review — `/simplify` run, all findings addressed

---

### Step 6 — Move Memory Module (agent-sdk + agent-runtime)

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`

Move all 6 memory files. Depends on `agent_sdk/thread/` (already moved).

#### Work

1. Move files:
   - `agent_sdk/memory/working_memory.py` ← `agent_host/memory/working_memory.py`
   - `agent_sdk/memory/persistent_memory.py` ← `agent_host/memory/persistent_memory.py`
   - `agent_sdk/memory/plan.py` ← `agent_host/memory/plan.py`
   - `agent_sdk/memory/task_tracker.py` ← `agent_host/memory/task_tracker.py`
   - `agent_sdk/memory/memory_manager.py` ← `agent_host/memory/memory_manager.py`
   - `agent_sdk/memory/project_instructions.py` ← `agent_host/memory/project_instructions.py`
2. Update imports in: `agent_host/loop/loop_runtime.py`, `agent_host/loop/agent_tools.py`, `agent_host/session/session_manager.py`
3. Move corresponding tests
4. Remove empty `agent_host/memory/` directory

#### Definition of Done

- `make check` passes
- `import-linter` passes
- **Wiring check**: grep for `from agent_host.memory` — zero results
- **Self-review**: Verify `MemoryManager` and `WorkingMemory` imports updated in all consumers. Verify `memory_manager.py` internal imports (project_instructions, persistent_memory) now reference `agent_sdk.memory`.
- **Logical bug review**: Verify `MemoryManager.load_all()` file I/O doesn't depend on any agent_host context — it receives workspace_dir as a parameter, not from config.

#### Principle Checklist

- [ ] P1 Incremental delivery — `make check` passes
- [ ] P2 Tests from the start — memory tests pass at new location
- [ ] P4 No regressions — zero behavioral changes
- [ ] P6 Self-review — no stale `agent_host.memory` imports
- [ ] P8 Boundary verification — import-linter passes
- [ ] P9 Atomic two-repo moves — old directory removed
- [ ] P10 Simplify review — `/simplify` run, all findings addressed

---

### Step 7 — Move LLM Client (agent-sdk + agent-runtime)

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`

Move `llm/client.py`. Depends on `llm/models.py` and `llm/error_classifier.py` already moved in Step 3.

#### Work

1. Move `agent_sdk/llm/client.py` ← `agent_host/llm/client.py`
2. Update internal imports (client.py imports models and error_classifier — both now in agent_sdk)
3. Update imports in: `agent_host/loop/loop_runtime.py`, `agent_host/session/session_manager.py`
4. Move corresponding tests
5. Remove empty `agent_host/llm/` directory

#### Definition of Done

- `make check` passes
- `import-linter` passes
- **Wiring check**: grep for `from agent_host.llm` — zero results
- **Self-review**: Verify `LLMClient` uses `openai.AsyncOpenAI` (external dep, not agent_host). Verify retry logic imports from `tenacity` (external). Verify no reference to `EventEmitter` or other agent_host types.
- **Logical bug review**: Verify `LLMClient.stream_chat()` callback `on_text_chunk` is a plain callable — no agent_host types in its signature.

#### Principle Checklist

- [ ] P1 Incremental delivery — `make check` passes
- [ ] P2 Tests from the start — LLM client tests pass at new location
- [ ] P4 No regressions — zero behavioral changes
- [ ] P6 Self-review — no stale `agent_host.llm` imports
- [ ] P8 Boundary verification — import-linter passes
- [ ] P9 Atomic two-repo moves — old directory removed
- [ ] P10 Simplify review — `/simplify` run, all findings addressed

---

### Step 8 — Move Loop Strategy Components (agent-sdk + agent-runtime)

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`

Move loop infrastructure that ReactLoop depends on: strategy protocol, error recovery, verification, system prompt builder.

#### Work

1. Move files:
   - `agent_sdk/loop/strategy.py` ← `agent_host/loop/strategy.py`
   - `agent_sdk/loop/error_recovery.py` ← `agent_host/loop/error_recovery.py`
   - `agent_sdk/loop/verification.py` ← `agent_host/loop/verification.py`
   - `agent_sdk/loop/system_prompt.py` ← `agent_host/loop/system_prompt.py`
2. Update imports in: `agent_host/loop/loop_runtime.py`, `agent_host/session/session_manager.py`
3. Move corresponding tests

#### Definition of Done

- `make check` passes
- `import-linter` passes
- **Wiring check**: grep for `from agent_host.loop.strategy`, `from agent_host.loop.error_recovery`, etc. — zero results outside agent_host consumers
- **Self-review**: Verify `ErrorRecovery` has no agent_host imports (only structlog). Verify `VerificationConfig` is a pure dataclass. Verify `SystemPromptBuilder` doesn't import EventEmitter or SessionManager.
- **Logical bug review**: Verify `LoopStrategy` protocol in `strategy.py` references `LoopResult` from `agent_sdk.loop.models` (already moved). Verify no circular dependency between `strategy.py` and `context.py`.

#### Principle Checklist

- [ ] P1 Incremental delivery — `make check` passes
- [ ] P2 Tests from the start — strategy component tests pass at new location
- [ ] P4 No regressions — zero behavioral changes
- [ ] P6 Self-review — no stale imports
- [ ] P8 Boundary verification — import-linter passes
- [ ] P9 Atomic two-repo moves — files moved exactly once
- [ ] P10 Simplify review — `/simplify` run, all findings addressed

---

### Step 9 — Move ReactLoop (agent-sdk + agent-runtime)

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`

The key step: move `ReactLoop` and change its dependency from concrete `LoopRuntime` to `LoopContext` protocol.

#### Work

1. Move `agent_sdk/loop/react_loop.py` ← `agent_host/loop/react_loop.py`
2. Change `harness` type annotation from `LoopRuntime` to `LoopContext`:
   ```python
   # Before
   if TYPE_CHECKING:
       from agent_host.loop.loop_runtime import LoopRuntime
   class ReactLoop:
       def __init__(self, harness: LoopRuntime, ...): ...

   # After
   if TYPE_CHECKING:
       from agent_sdk.loop.context import LoopContext
   class ReactLoop:
       def __init__(self, harness: LoopContext, ...): ...
   ```
3. Update all internal imports to `agent_sdk.*`
4. Update imports in: `agent_host/loop/loop_runtime.py` (spawn_sub_agent, execute_skill), `agent_host/session/session_manager.py`
5. Move corresponding tests
6. Add new test: verify `LoopRuntime` satisfies `LoopContext` protocol (isinstance check)

#### Tests

- All existing ReactLoop unit tests pass at new location
- New: `LoopRuntime` satisfies `LoopContext` (isinstance check with runtime_checkable)
- New: ReactLoop can be constructed with a mock `LoopContext` (no real LoopRuntime needed)

#### Definition of Done

- `make check` passes
- `import-linter` passes — `react_loop.py` has zero `agent_host` imports
- `ReactLoop` type-checks against `LoopContext`, not `LoopRuntime`
- **Wiring check**: Verify `LoopRuntime.spawn_sub_agent()` and `LoopRuntime.execute_skill()` still import `ReactLoop` from `agent_sdk.loop.react_loop` — this is the correct direction (agent_host → agent_sdk).
- **Self-review**: Verify `self._h._event_emitter` access in `react_loop.py` line 80 — this accesses a private attribute of LoopRuntime. Either add `event_emitter` property to `LoopContext` protocol or refactor to use a public method. This is the most likely breakage point.
- **Logical bug review**: Verify the `_on_chunk` lambda in `react_loop.py` doesn't capture agent_host types. Verify `_build_messages()` only uses `LoopContext` properties (thread, compactor, working_memory, memory_manager, error_recovery, max_context_tokens). Verify `_execute_tools()` only uses `LoopContext` methods (is_agent_tool, execute_agent_tool, execute_external_tools, thread.add_tool_result).

#### Principle Checklist

- [ ] P1 Incremental delivery — `make check` passes
- [ ] P2 Tests from the start — existing tests + new protocol conformance tests
- [ ] P4 No regressions — zero behavioral changes
- [ ] P6 Self-review — private attribute access resolved, no agent_host references in ReactLoop
- [ ] P8 Boundary verification — ReactLoop has zero agent_host imports
- [ ] P9 Atomic two-repo moves — react_loop.py moved exactly once
- [ ] P10 Simplify review — `/simplify` run, all findings addressed

---

### Step 10 — Move Remaining SDK Modules (agent-sdk + agent-runtime)

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`

Move skills (loader + models), checkpoint, and file change tracking.

#### Work

1. Move files:
   - `agent_sdk/skills/skill_loader.py` ← `agent_host/skills/skill_loader.py`
   - `agent_sdk/skills/models.py` ← `agent_host/skills/models.py`
   - `agent_sdk/checkpoint/checkpoint_manager.py` ← `agent_host/session/checkpoint_manager.py`
   - `agent_sdk/tracking/file_change_tracker.py` ← `agent_host/agent/file_change_tracker.py`
2. Update imports in: `agent_host/loop/loop_runtime.py`, `agent_host/loop/agent_tools.py`, `agent_host/session/session_manager.py`
3. Move corresponding tests
4. Remove empty directories: `agent_host/skills/`, `agent_host/agent/`

#### Definition of Done

- `make check` passes
- `import-linter` passes
- **Wiring check**: grep for `from agent_host.skills`, `from agent_host.session.checkpoint`, `from agent_host.agent.file_change` — zero results
- **Self-review**: Verify `SkillLoader` doesn't import `SkillExecutor` (executor stays in agent_host). Verify `CheckpointManager` uses only file I/O (no HTTP clients). Verify `FileChangeTracker` has no EventEmitter dependency.
- **Logical bug review**: Verify `LoopRuntime.execute_skill()` imports `SkillLoader.load_skill_content` and `substitute_arguments` from `agent_sdk.skills` — this is the correct direction. Verify `SessionManager` imports `CheckpointManager` from `agent_sdk.checkpoint` — correct direction.

#### Principle Checklist

- [ ] P1 Incremental delivery — `make check` passes
- [ ] P2 Tests from the start — all moved tests pass
- [ ] P4 No regressions — zero behavioral changes
- [ ] P6 Self-review — no stale imports
- [ ] P8 Boundary verification — import-linter passes
- [ ] P9 Atomic two-repo moves — old directories removed
- [ ] P10 Simplify review — `/simplify` run, all findings addressed

---

### Step 11 — Reorganize agent_host Transport/Events (agent-runtime)

**Repo:** `cowork-agent-runtime`

Reorganize `server/` into `transport/` and move `event_buffer.py` to `events/`. Internal agent_host restructuring only.

#### Work

1. Create `agent_host/transport/` with `__init__.py`
2. Move files:
   - `agent_host/transport/transport.py` ← `agent_host/server/transport.py`
   - `agent_host/transport/stdio_transport.py` ← `agent_host/server/stdio_transport.py`
   - `agent_host/transport/http_transport.py` ← `agent_host/server/http_transport.py`
   - `agent_host/transport/json_rpc.py` ← `agent_host/server/json_rpc.py`
   - `agent_host/transport/method_dispatcher.py` ← `agent_host/server/method_dispatcher.py`
   - `agent_host/events/event_buffer.py` ← `agent_host/server/event_buffer.py`
3. Update all internal imports within agent_host
4. Move corresponding tests
5. `agent_host/server/` retains only `handlers.py`

#### Definition of Done

- `make check` passes
- `import-linter` passes
- **Wiring check**: grep for `from agent_host.server.transport`, `from agent_host.server.stdio`, etc. — zero results (all updated to `agent_host.transport.*`)
- **Self-review**: Verify `main.py` imports `StdioTransport` and `HttpTransport` from `agent_host.transport`. Verify `HttpTransport` imports `EventBuffer` from `agent_host.events`. Verify `handlers.py` imports `MethodDispatcher` from `agent_host.transport`.
- **Logical bug review**: Verify `HttpTransport`'s `workspace.sync` handler still works after move — it imports `workspace_sync` from `agent_host.sandbox`, which is unchanged. Verify `StdioTransport`'s JSON-RPC serialization imports are updated.

#### Principle Checklist

- [ ] P1 Incremental delivery — `make check` passes
- [ ] P2 Tests from the start — transport tests pass at new location
- [ ] P4 No regressions — HttpTransport and StdioTransport behavior unchanged
- [ ] P6 Self-review — no stale `agent_host.server.*` imports (except handlers.py)
- [ ] P10 Simplify review — `/simplify` run, all findings addressed

---

### Step 12 — Clean Up & Enforce Boundaries (agent-sdk + agent-runtime)

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`

Final cleanup: remove empty directories, finalize exports, verify all boundaries in both repos.

#### Work

**In `cowork-agent-sdk`:**

1. Update `agent_sdk/__init__.py` with clean public API exports
2. Run `make check` — all SDK tests pass in isolation
3. Verify no `agent_host` or `tool_runtime` references in any file

**In `cowork-agent-runtime`:**

4. Remove empty directories left behind:
   - `agent_host/budget/`, `agent_host/approval/`, `agent_host/thread/`, `agent_host/memory/`
   - `agent_host/llm/`, `agent_host/policy/`, `agent_host/skills/`, `agent_host/agent/`
5. Verify `import-linter` passes (tool_runtime ↔ agent_host boundary)
6. Verify no stale imports: `grep -r "from agent_host\.\(thread\|memory\|policy\|llm\|budget\|approval\|skills\|agent\)\." src/`
7. Run full test suite: `make check` + `make test-chat` + `make test-sandbox`

#### Definition of Done

- `make check` passes
- `make test-chat` passes (end-to-end desktop flow)
- `make test-sandbox` passes (end-to-end sandbox flow)
- `import-linter` passes with zero violations
- No empty directories remain in `agent_host/`
- No stale imports referencing moved modules
- `agent_sdk/__init__.py` exports a clean public API
- **Self-review**: Verify `agent_sdk/__init__.py` doesn't import everything — only the key public types. Verify no test file still imports from old locations. Run `make typecheck` — zero errors.
- **Logical bug review**: Verify `agent_host/__init__.py` re-exports `AgentHostError`, `SessionContext`, `PolicyCheckResult` from `agent_sdk` for backward compatibility. Verify no circular import between agent_sdk and agent_host at runtime (not just under TYPE_CHECKING).
- **Local run**: Start full desktop flow with `make test-chat`. Start full sandbox flow with `make test-sandbox`. Both must complete successfully.

#### Principle Checklist

- [ ] P1 Incremental delivery — `make check` passes in both repos
- [ ] P4 No regressions — `make test-chat` and `make test-sandbox` pass
- [ ] P6 Self-review — no circular imports, no stale references
- [ ] P8 Boundary verification — import-linter zero violations, SDK passes in isolation
- [ ] P10 Simplify review — `/simplify` run, all findings addressed

---

### Step 13 — Update Documentation (all repos)

**Repos:** `cowork-agent-sdk`, `cowork-agent-runtime`, `cowork-infra`

Update all documentation to reflect the three-package architecture.

#### Work

1. **Update `cowork-agent-sdk/CLAUDE.md`:**
   - Finalize architecture context, module listing, dependency rules
   - Document `LoopContext` protocol and how consumers implement it

2. **Update `cowork-agent-runtime/CLAUDE.md`:**
   - Remove extracted modules from architecture section
   - Add `cowork-agent-sdk` dependency description
   - Update dependency rules section (agent_host imports from agent_sdk, not internal)
   - Update package structure diagram
   - Add `LoopContext` protocol reference

3. **Update `cowork-agent-runtime/README.md`:**
   - Update architecture overview — agent_host uses agent_sdk as external dependency
   - Update directory structure

4. **Update `cowork-infra/docs/components/local-agent-host.md`:**
   - Add `cowork-agent-sdk` as external dependency
   - Update module dependency diagram (Mermaid)
   - Document `LoopContext` protocol
   - Update import examples

5. **Update `cowork-infra/docs/architecture.md`:**
   - Add `cowork-agent-sdk` to repo mapping table
   - Update `cowork-agent-runtime` entry (note: depends on agent-sdk)
   - Update agent-runtime folder structure
   - Update dependency chain diagram

6. **Update `cowork-infra/docs/design/agent-sdk-extraction.md`:**
   - Mark all steps ✅ Done in status tracker

7. **Update root `cowork/CLAUDE.md`:**
   - Add `cowork-agent-sdk` to repo table
   - Update agent-runtime module listing
   - Update dependency rules section

#### Definition of Done

- All CLAUDE.md files reflect three-package architecture
- Design docs updated with new module structure
- Mermaid diagrams updated
- Status tracker shows all steps complete
- **Self-review**: Grep all docs for references to old module paths (`agent_host/thread`, `agent_host/policy`, etc.) — verify they've been updated or removed. Verify Mermaid diagrams render correctly.

#### Principle Checklist

- [ ] P6 Self-review — grep confirms no stale module path references in any doc
- [ ] P7 Documentation sync — all CLAUDE.md files, READMEs, design docs updated

---

## Global Definition of Done

**cowork-agent-sdk (new repo):**
- [ ] Repo exists on GitHub with full project scaffold (pyproject.toml, Makefile, CI, CLAUDE.md, README.md)
- [ ] Contains all extracted modules (~4,500 LOC)
- [ ] `LoopContext` protocol defined in `agent_sdk/loop/context.py`
- [ ] `ReactLoop` depends on `LoopContext`, not `LoopRuntime`
- [ ] `make check` passes in isolation (lint + typecheck + unit tests)
- [ ] CI pipeline runs on all branches
- [ ] Zero imports from `agent_host` or `tool_runtime` (enforced by repo separation)
- [ ] Clean public API exported from `agent_sdk/__init__.py`

**cowork-agent-runtime (existing repo):**
- [ ] `agent_host/` contains only cowork application layer (~4,500 LOC)
- [ ] `tool_runtime/` unchanged (~3,000 LOC)
- [ ] `LoopRuntime` satisfies `LoopContext` (verified by isinstance test)
- [ ] `import-linter` enforces: `tool_runtime` never imports `agent_host`
- [ ] Depends on `cowork-agent-sdk` (local path for dev, git for CI)
- [ ] All unit tests pass (`make test`)
- [ ] Type checking passes (`make typecheck`)
- [ ] All integration tests pass (`make test-chat`, `make test-sandbox`)
- [ ] No behavior changes — desktop and sandbox modes work identically
- [ ] No stale imports — zero references to moved module paths in `agent_host/`
- [ ] No empty directories — all cleaned up
- [ ] Makefile and CI updated with SDK dependency

**Documentation (all repos):**
- [ ] `cowork-agent-sdk/CLAUDE.md` — architecture context for the SDK
- [ ] `cowork-agent-runtime/CLAUDE.md` — updated with three-package architecture
- [ ] Root `cowork/CLAUDE.md` — repo table includes `cowork-agent-sdk`
- [ ] `cowork-infra/docs/architecture.md` — repo table includes `cowork-agent-sdk`
- [ ] `cowork-infra/docs/components/local-agent-host.md` — updated module structure
- [ ] Status tracker in this doc shows all 13 steps complete
