# Memory Service — Implementation Plan

**Parent design:** [memory-service.md](memory-service.md)
**Repos touched:** `cowork-memory-service` (new), `cowork-platform`, `cowork-agent-runtime`, `cowork-infra`

---

## Status Tracker

| Step | Name | Repo | Status | Branch | Notes |
|------|------|------|--------|--------|-------|
| 1 | Repo Scaffold + Interfaces | `cowork-memory-service` | ⏳ Pending | — | FastAPI skeleton, protocols, InMemoryVectorStore, domain models |
| 2 | MongoDB Atlas Vector Store | `cowork-memory-service` | ⏳ Pending | — | MongoDBAtlasVectorStore, CRUD, vector search, tenant filtering |
| 3 | Core CRUD API | `cowork-memory-service` | ⏳ Pending | — | REST endpoints: create, get, list, search, update, delete |
| 4 | Mem0 Integration + Ingest Pipeline | `cowork-memory-service` | ⏳ Pending | — | Mem0 wrapping, ingest endpoint, memory type classification |
| 5 | OpenSearch Vector Store | `cowork-memory-service` | ⏳ Pending | — | OpenSearchVectorStore, env var switching |
| 6 | Version History + GDPR + Audit | `cowork-memory-service` | ⏳ Pending | — | History endpoint, user deletion, audit events |
| 7 | Reranker + Rate Limiting | `cowork-memory-service` | ⏳ Pending | — | Optional reranker, per-tenant quotas |
| 8 | Platform Contracts | `cowork-platform` | ⏳ Pending | — | JSON schemas for memory types |
| 9 | Agent Runtime — Memory Tools | `cowork-agent-runtime` | ⏳ Pending | — | Memory.Search + Memory.Save in Tool Runtime |
| 10 | Agent Runtime — Auto Injection + Ingestion | `cowork-agent-runtime` | ⏳ Pending | — | Agent Host auto-retrieve + auto-ingest |

---

## Principles

1. **Incremental delivery**: Each step produces a testable, working unit. No step depends on untested work from a prior step.
2. **Tests from the start**: Every step includes unit tests. Service tests added when MongoDB is involved. Integration tests at integration boundaries.
3. **Existing patterns**: Same project structure, error handling, logging, CI, and Makefile conventions as `cowork-session-service`. Repository pattern with Protocol-based interfaces, dependency injection via FastAPI `Depends`, pydantic-settings for config, structlog for logging, async all the way.
4. **No agent-runtime regression**: All agent-runtime changes (Steps 9-10) are additive. Desktop and sandbox sessions must pass existing tests at every step. `make test-chat` must pass after Steps 9-10.
5. **Step numbers = execution order**: Steps are numbered in the order they should be implemented. Steps 1-4 deliver a functional memory service. Steps 5-7 harden it. Steps 8-10 connect it to agents.
6. **Wiring verification**: Every step must verify end-to-end wiring with adjacent components. After implementing, trace the data flow from caller to callee and back — check request/response types match, error codes are handled, timeouts are set, and no integration seams are left untested.
7. **Self-review before done**: Every step includes a mandatory self-review pass before marking complete. Review all changed files for: unhandled exceptions, missing error handling at boundaries, type mismatches between components, hardcoded values that should be configurable, missing structured logging, missing tests for error paths, and any deviation from existing patterns. Fix all issues found before proceeding.
8. **Logical bug review**: Every step must include a dedicated pass to check for logical bugs — race conditions, off-by-one errors, null/None dereferences, incorrect state transitions, missing edge cases, wrong comparison operators, inverted boolean logic, and incorrect error propagation. Fix all issues before marking complete.
9. **Design doc sync**: Every step must update design docs in `cowork-infra/docs/` and documentation (CLAUDE.md, README.md) in affected repos to reflect what was actually implemented. Never let docs drift from implementation.
10. **Protocol-first design**: All storage backends implement the `VectorStore` protocol. All embedding providers implement the `EmbeddingProvider` protocol. Business logic depends only on protocols, never on concrete implementations. This enables testing with `InMemoryVectorStore` and swapping backends without code changes.
11. **Multi-tenancy from day 1**: Every query, every test, every endpoint must enforce `tenant_id` filtering. No shortcut that skips tenant isolation, even in development. Integration tests must verify that Tenant A cannot see Tenant B's memories.
12. **Audit from day 1**: Structured log events emitted for every write operation (create, update, delete) from the first step. No PII in audit events — only event type, scope, tenant_id, memory_id, timestamp.
13. **Pre-step review**: Before starting any step, review the existing code and design docs for the areas being changed. Understand current behavior before modifying it.

---

## Local Development Setup

All memory service features must be testable locally. The local stack runs on a MacBook with:

```bash
# 1. Start infrastructure
# MongoDB for service tests (no vector search — Atlas-only feature)
docker run -p 27017:27017 mongo:7

# OpenSearch for Step 5 service tests
docker run -p 9200:9200 -e "discovery.type=single-node" -e "DISABLE_SECURITY_PLUGIN=true" opensearchproject/opensearch:2

# Existing LocalStack (DynamoDB + S3 for other services)
docker-compose up -d

# 2. Start memory service
cd cowork-memory-service && make run     # http://localhost:8003

# 3. Start other backend services (for agent-runtime integration, Steps 9-10)
cd cowork-session-service && make run     # http://localhost:8000
cd cowork-policy-service && make run      # http://localhost:8001
cd cowork-workspace-service && make run   # http://localhost:8002
```

**Key env vars for local development:**
- `ENVIRONMENT=dev` — resource name prefixing
- `VECTOR_STORE_BACKEND=memory` — use InMemoryVectorStore (no infra needed)
- `VECTOR_STORE_BACKEND=mongodb` — use local MongoDB (service tests)
- `VECTOR_STORE_BACKEND=opensearch` — use local OpenSearch (Step 5)
- `MONGODB_URI=mongodb://localhost:27017` — local MongoDB connection
- `MONGODB_DATABASE=dev-memories` — database name
- `MONGODB_COLLECTION=memories` — collection name
- `OPENSEARCH_URL=http://localhost:9200` — local OpenSearch connection
- `EMBEDDING_PROVIDER=mock` — use mock embeddings (deterministic, no LLM cost)
- `EMBEDDING_PROVIDER=openai` — use OpenAI embeddings (requires API key)
- `EMBEDDING_MODEL=text-embedding-3-small` — embedding model name
- `EMBEDDING_DIMENSIONS=1536` — embedding vector dimensions
- `LLM_GATEWAY_URL=http://localhost:8080` — LLM Gateway for Mem0 extraction (Step 4)
- `MEMORY_SERVICE_URL=http://localhost:8003` — agent-runtime config (Steps 9-10)

**docker-compose addition** (to be added in Step 1):
```yaml
  mongodb:
    image: mongo:7
    ports:
      - "27017:27017"
    volumes:
      - mongodb-data:/data/db
```

---

## Step 1 — Repo Scaffold + Interfaces (cowork-memory-service)

**Repo:** `cowork-memory-service` (new)

Create the `cowork-memory-service` repository with full FastAPI skeleton, Protocol-based interfaces, `InMemoryVectorStore`, domain models, and health checks. This establishes the project structure and core abstractions that all subsequent steps build on.

### Work

**Project scaffold:**

1. Initialize git repo with `main` branch

2. Create `pyproject.toml`:
   ```toml
   [build-system]
   requires = ["hatchling"]
   build-backend = "hatchling.build"

   [project]
   name = "cowork-memory-service"
   version = "0.1.0"
   requires-python = ">=3.12"
   dependencies = [
       "cowork-platform[sdk]",
       "fastapi>=0.115,<1.0",
       "uvicorn[standard]>=0.34,<1.0",
       "pydantic>=2.0,<3.0",
       "pydantic-settings>=2.0,<3.0",
       "httpx>=0.27,<1.0",
       "structlog>=24.0,<26.0",
       "tenacity>=9.0,<10.0",
       "numpy>=1.26,<3.0",
   ]
   ```

3. Create `Makefile` with standard targets: `help`, `install`, `lint`, `format`, `format-check`, `typecheck`, `test`, `test-service`, `test-integration`, `run`, `build`, `check`, `clean`

4. Create `.github/workflows/ci.yml` — lint, format-check, typecheck, unit tests (all branches, no filter)

5. Create `.env.example`, `.gitignore`, `.python-version` (3.12), `CLAUDE.md`, `README.md`

**Application structure:**

6. Create `src/memory_service/config.py` — `MemoryServiceConfig(BaseSettings)`:
   ```python
   class MemoryServiceConfig(BaseSettings):
       model_config = SettingsConfigDict(env_prefix="")

       environment: str = "dev"
       service_name: str = "memory-service"
       host: str = "0.0.0.0"
       port: int = 8003

       # Vector store
       vector_store_backend: Literal["memory", "mongodb", "opensearch"] = "memory"

       # MongoDB
       mongodb_uri: str = "mongodb://localhost:27017"
       mongodb_database: str = "dev-memories"
       mongodb_collection: str = "memories"

       # OpenSearch
       opensearch_url: str = "http://localhost:9200"
       opensearch_index: str = "dev-memories"

       # Embedding
       embedding_provider: Literal["mock", "openai"] = "mock"
       embedding_model: str = "text-embedding-3-small"
       embedding_dimensions: int = 1536

       # LLM Gateway (for Mem0 extraction in Step 4)
       llm_gateway_url: str = "http://localhost:8080"
   ```

7. Create `src/memory_service/models/domain.py` — domain models:
   ```python
   class MemoryScope(str, Enum):
       TENANT = "tenant"
       USER = "user"
       AGENT_USER = "agent_user"
       USECASE_AGENT_USER = "usecase_agent_user"

   class MemoryType(str, Enum):
       SEMANTIC = "semantic"
       EPISODIC = "episodic"
       PROCEDURAL = "procedural"

   class Entity(BaseModel):
       name: str
       type: str

   class MemoryRecord(BaseModel):
       id: str
       tenant_id: str
       user_id: str | None = None
       agent_id: str | None = None
       usecase_id: str | None = None
       scope: MemoryScope
       memory_type: MemoryType
       content: str
       embedding: list[float] | None = None
       embedding_model: str | None = None
       metadata: dict[str, Any] = Field(default_factory=dict)
       entities: list[Entity] = Field(default_factory=list)
       valid_from: datetime | None = None
       valid_until: datetime | None = None
       created_by: str | None = None
       created_at: datetime
       updated_at: datetime | None = None
       last_accessed_at: datetime | None = None
       version: int = 1
       is_deleted: bool = False
   ```

8. Create `src/memory_service/models/requests.py` — request models:
   - `CreateMemoryRequest` — content, scope, memory_type, metadata, entities, valid_from, valid_until
   - `UpdateMemoryRequest` — content (optional), metadata (optional), valid_until (optional)
   - `SearchMemoriesRequest` — query, tenant_id, user_id, agent_id, usecase_id, scopes (list), memory_types (list), limit, min_relevance
   - `ListMemoriesRequest` — tenant_id, user_id, scope, memory_type, limit, cursor

9. Create `src/memory_service/models/responses.py` — response models:
   - `MemoryResponse` — id, tenant_id, user_id, agent_id, usecase_id, scope, memory_type, content, metadata, entities, valid_from, valid_until, created_at, updated_at, relevance (optional)
   - `MemoryListResponse` — memories (list), cursor, total_count
   - `SearchResult` — memory (MemoryResponse), relevance (float), recency (float)
   - `SearchResponse` — results (list[SearchResult])
   - `HealthResponse` — status, version, vector_store_backend

10. Create `src/memory_service/models/__init__.py` — re-export all models

**Protocols:**

11. Create `src/memory_service/repositories/vector_store.py` — `VectorStore` protocol:
    ```python
    @runtime_checkable
    class VectorStore(Protocol):
        async def insert(self, record: MemoryRecord) -> None: ...
        async def get(self, memory_id: str, tenant_id: str) -> MemoryRecord | None: ...
        async def update(self, record: MemoryRecord) -> None: ...
        async def delete(self, memory_id: str, tenant_id: str) -> bool: ...
        async def search(
            self,
            embedding: list[float],
            tenant_id: str,
            *,
            user_id: str | None = None,
            agent_id: str | None = None,
            usecase_id: str | None = None,
            scopes: list[MemoryScope] | None = None,
            memory_types: list[MemoryType] | None = None,
            limit: int = 10,
            min_relevance: float = 0.0,
        ) -> list[tuple[MemoryRecord, float]]: ...
        async def list_memories(
            self,
            tenant_id: str,
            *,
            user_id: str | None = None,
            scope: MemoryScope | None = None,
            memory_type: MemoryType | None = None,
            limit: int = 50,
            cursor: str | None = None,
        ) -> tuple[list[MemoryRecord], str | None]: ...
        async def delete_by_user(self, tenant_id: str, user_id: str) -> int: ...
        async def count_by_tenant(self, tenant_id: str) -> int: ...
        async def health_check(self) -> bool: ...
    ```

12. Create `src/memory_service/repositories/embedding_provider.py` — `EmbeddingProvider` protocol:
    ```python
    @runtime_checkable
    class EmbeddingProvider(Protocol):
        @property
        def model_name(self) -> str: ...
        @property
        def dimensions(self) -> int: ...
        async def embed(self, text: str) -> list[float]: ...
        async def embed_batch(self, texts: list[str]) -> list[list[float]]: ...
    ```

**InMemory implementations:**

13. Create `src/memory_service/repositories/memory_store.py` — `InMemoryVectorStore`:
    - Dictionary-based storage keyed by `(tenant_id, memory_id)`
    - Cosine similarity search using numpy
    - Filtering by scope, type, user_id, agent_id, usecase_id
    - Cursor-based pagination (cursor = last seen memory_id)
    - `delete_by_user` — iterates and removes matching records
    - `count_by_tenant` — counts records for a tenant

14. Create `src/memory_service/repositories/mock_embedding.py` — `MockEmbeddingProvider`:
    - Deterministic embeddings: hash content string to produce consistent vector
    - Used for unit tests and local development without LLM cost
    - `model_name` returns `"mock-embedding"`
    - `dimensions` returns configured value (default 1536)

15. Create `src/memory_service/repositories/__init__.py`

**Exceptions:**

16. Create `src/memory_service/exceptions.py`:
    ```python
    class MemoryServiceError(Exception):
        def __init__(self, message: str, code: str, status_code: int = 500): ...

    class MemoryNotFoundError(MemoryServiceError): ...       # 404
    class MemoryConflictError(MemoryServiceError): ...       # 409
    class TenantQuotaExceededError(MemoryServiceError): ...  # 429
    class VectorStoreError(MemoryServiceError): ...          # 502
    class EmbeddingError(MemoryServiceError): ...            # 502
    class ValidationError(MemoryServiceError): ...           # 422
    ```

**Service layer:**

17. Create `src/memory_service/services/memory_service.py` — `MemoryService`:
    - Constructor takes `VectorStore` and `EmbeddingProvider` (dependency injection)
    - `create_memory(tenant_id, request) -> MemoryResponse` — generate ID, compute embedding, insert via VectorStore, emit audit event
    - `get_memory(memory_id, tenant_id) -> MemoryResponse` — fetch via VectorStore, update last_accessed_at
    - `search_memories(request) -> SearchResponse` — embed query, search via VectorStore, return results with relevance scores
    - `list_memories(request) -> MemoryListResponse` — list via VectorStore with filters
    - `update_memory(memory_id, tenant_id, request) -> MemoryResponse` — fetch, re-embed if content changed, update via VectorStore, emit audit event
    - `delete_memory(memory_id, tenant_id) -> None` — delete via VectorStore, emit audit event

18. Create `src/memory_service/services/__init__.py`

**Dependency injection:**

19. Create `src/memory_service/dependencies.py`:
    ```python
    def get_config() -> MemoryServiceConfig: ...
    def get_vector_store(config: MemoryServiceConfig = Depends(get_config)) -> VectorStore: ...
    def get_embedding_provider(config: MemoryServiceConfig = Depends(get_config)) -> EmbeddingProvider: ...
    def get_memory_service(
        store: VectorStore = Depends(get_vector_store),
        embedder: EmbeddingProvider = Depends(get_embedding_provider),
    ) -> MemoryService: ...
    ```
    Factory pattern: `get_vector_store` reads `config.vector_store_backend` and returns the appropriate implementation. Step 1 only supports `"memory"` — MongoDB and OpenSearch added in Steps 2 and 5.

**Routes:**

20. Create `src/memory_service/routes/health.py`:
    - `GET /health` — returns 200 always (liveness)
    - `GET /ready` — checks VectorStore health (readiness)

21. Create `src/memory_service/routes/__init__.py`

**Middleware:**

22. Create `src/memory_service/middleware.py`:
    - Request ID middleware (generate `request_id`, bind to structlog context)
    - Request logging middleware (log method, path, status, duration)
    - Same pattern as `cowork-session-service/src/session_service/middleware.py`

**Application:**

23. Create `src/memory_service/main.py`:
    - FastAPI app with lifespan handler
    - Register exception handlers (catch-all + MemoryServiceError)
    - Mount health routes
    - Configure structlog (JSON in production, human-readable in dev)
    - Same pattern as `cowork-session-service/src/session_service/main.py`

24. Create `src/memory_service/__init__.py`

**Structured logging:**

25. Create `src/memory_service/logging.py`:
    - Configure structlog processors (timestamp, log level, request context)
    - Audit event helper: `emit_audit_event(event_type, tenant_id, memory_id, scope, ...)` — emits structured log with `audit_event=True` marker, no PII content
    - Event types: `memory.created`, `memory.updated`, `memory.deleted`, `memory.searched`, `memory.bulk_deleted`

### Tests

**Unit tests (all use InMemoryVectorStore + MockEmbeddingProvider):**

- `tests/unit/repositories/test_memory_store.py`:
  - Insert and retrieve a memory record
  - Search returns results sorted by relevance
  - Search with scope filter
  - Search with memory_type filter
  - Search with user_id filter
  - Search with min_relevance threshold
  - Search across multiple scopes (tenant + user + agent_user)
  - List with cursor pagination
  - Delete returns True for existing, False for missing
  - delete_by_user removes all user-scoped records, preserves tenant-scoped
  - count_by_tenant returns correct count
  - Tenant isolation — Tenant A cannot see Tenant B's memories
  - health_check returns True

- `tests/unit/repositories/test_mock_embedding.py`:
  - Deterministic: same text produces same vector
  - Different texts produce different vectors
  - Correct dimensions
  - Batch embedding works

- `tests/unit/services/test_memory_service.py`:
  - create_memory generates ID, computes embedding, stores record
  - get_memory returns record, updates last_accessed_at
  - get_memory raises MemoryNotFoundError for missing ID
  - search_memories embeds query and returns ranked results
  - update_memory re-embeds when content changes
  - update_memory increments version
  - delete_memory removes record
  - delete_memory raises MemoryNotFoundError for missing ID
  - Audit events emitted for create, update, delete

- `tests/unit/models/test_domain.py`:
  - MemoryScope enum values
  - MemoryType enum values
  - MemoryRecord validation (required fields, optional fields, defaults)
  - Scope validation rejects invalid values

- `tests/unit/test_config.py`:
  - Config loads from env vars
  - Config defaults are correct

- `tests/conftest.py`:
  - Fixtures: `memory_store` (InMemoryVectorStore), `mock_embedder` (MockEmbeddingProvider), `memory_service` (MemoryService wired with test deps), `test_client` (FastAPI TestClient with test app)
  - Test app registers same exception handlers as production app

**Route tests:**

- `tests/unit/routes/test_health.py`:
  - GET /health returns 200
  - GET /ready returns 200 when store is healthy
  - GET /ready returns 503 when store is unhealthy

### Definition of Done

- `make check` passes on `cowork-memory-service` (lint + format-check + typecheck + test)
- `/health` returns 200 when running locally (`make run`)
- `/ready` returns 200 with InMemoryVectorStore
- Unit tests pass with InMemoryVectorStore + MockEmbeddingProvider (no infrastructure needed)
- CI pipeline configured and passing (triggers on all branches)
- **Wiring check**: Verify `MemoryService` constructor accepts `VectorStore` protocol (not concrete type). Verify `InMemoryVectorStore` satisfies `VectorStore` protocol (mypy structural check). Verify `MockEmbeddingProvider` satisfies `EmbeddingProvider` protocol. Verify `dependencies.py` returns correct implementations based on config.
- **Self-review**: Review all files for unhandled exceptions (especially in embedding and store calls), missing error handling at boundaries, type mismatches between request/response models and domain models, hardcoded values that should be configurable, missing structured logging on error paths, and missing tests for error paths.
- **Logical bug review**: Verify cosine similarity in InMemoryVectorStore handles zero vectors (division by zero). Verify cursor pagination doesn't skip or duplicate records. Verify tenant_id filtering is applied in ALL VectorStore methods (insert, get, update, delete, search, list). Verify memory ID generation is collision-resistant (use `mem_` prefix + UUID). Verify `last_accessed_at` update doesn't fail if the record was just created (updated_at may be None).
- **Local run**: `make run` starts the service on `localhost:8003`. Verify `/health` and `/ready` return 200.
- **Documentation**: Create CLAUDE.md and README.md for `cowork-memory-service`. Update `cowork-infra/docs/services/memory-service.md` status section.

### Principle Checklist

- [ ] P1 Incremental delivery
- [ ] P2 Tests from the start
- [ ] P3 Existing patterns
- [ ] P6 Wiring verification
- [ ] P7 Self-review
- [ ] P8 Logical bug review
- [ ] P10 Protocol-first
- [ ] P11 Multi-tenancy
- [ ] P12 Audit from day 1
- [ ] P9 Design doc sync

---

## Step 2 — MongoDB Atlas Vector Store (cowork-memory-service)

**Repo:** `cowork-memory-service`

Implement `MongoDBAtlasVectorStore` that satisfies the `VectorStore` protocol. Supports CRUD operations, vector search with `tenant_id` filtering, and ENN/ANN switching per tenant.

### Work

1. Add `motor>=3.6,<4.0` and `pymongo>=4.9,<5.0` to `pyproject.toml` dependencies

2. Create `src/memory_service/repositories/mongodb_store.py` — `MongoDBAtlasVectorStore`:
   ```python
   class MongoDBAtlasVectorStore:
       def __init__(
           self,
           uri: str,
           database: str,
           collection: str,
           *,
           index_name: str = "vector_index",
           enn_threshold: int = 10_000,
       ) -> None: ...

       async def initialize(self) -> None:
           """Create indexes on first connection. Called during app lifespan."""
           # Create compound index: (tenant_id, 1) for filtering
           # Create index: (tenant_id, user_id) for user deletion
           # Create index: (tenant_id, scope) for listing
           # Create unique index: (tenant_id, id) for dedup
           # Vector search index created via Atlas UI/API (not programmatic)

       async def insert(self, record: MemoryRecord) -> None:
           """Insert memory document. Raises MemoryConflictError on duplicate."""

       async def get(self, memory_id: str, tenant_id: str) -> MemoryRecord | None:
           """Fetch by memory_id + tenant_id. Returns None if not found."""

       async def update(self, record: MemoryRecord) -> None:
           """Update document. Uses optimistic concurrency via version field."""

       async def delete(self, memory_id: str, tenant_id: str) -> bool:
           """Delete by memory_id + tenant_id. Returns True if deleted."""

       async def search(
           self,
           embedding: list[float],
           tenant_id: str,
           *,
           user_id: str | None = None,
           agent_id: str | None = None,
           usecase_id: str | None = None,
           scopes: list[MemoryScope] | None = None,
           memory_types: list[MemoryType] | None = None,
           limit: int = 10,
           min_relevance: float = 0.0,
       ) -> list[tuple[MemoryRecord, float]]:
           """Vector search with tenant_id pre-filtering.

           Uses $vectorSearch aggregation stage:
           - ENN (exact=True, no numCandidates) for tenants with <enn_threshold memories
           - ANN (exact=False, numCandidates=limit*10) for tenants above threshold
           - Pre-filter on tenant_id (always), plus optional user_id, scopes, memory_types
           - Post-filter on min_relevance
           """

       async def list_memories(
           self,
           tenant_id: str,
           *,
           user_id: str | None = None,
           scope: MemoryScope | None = None,
           memory_type: MemoryType | None = None,
           limit: int = 50,
           cursor: str | None = None,
       ) -> tuple[list[MemoryRecord], str | None]:
           """List with filters. Cursor is last memory_id (sorted by created_at desc)."""

       async def delete_by_user(self, tenant_id: str, user_id: str) -> int:
           """Delete all memories for a user within a tenant.
           Deletes at user, agent_user, and usecase_agent_user scopes.
           Preserves tenant-scoped memories (even if created_by matches)."""

       async def count_by_tenant(self, tenant_id: str) -> int:
           """Count memories for a tenant. Used for ENN/ANN threshold check."""

       async def health_check(self) -> bool:
           """Ping MongoDB. Returns False on connection failure."""

       # Internal helpers
       def _should_use_enn(self, tenant_id: str) -> bool:
           """Check tenant memory count against enn_threshold.
           Reads from a cached counter updated on insert/delete."""

       def _record_to_document(self, record: MemoryRecord) -> dict[str, Any]: ...
       def _document_to_record(self, doc: dict[str, Any]) -> MemoryRecord: ...
   ```

3. Create `src/memory_service/repositories/tenant_counter.py` — `TenantCounter`:
   - In-memory cache of per-tenant memory counts
   - Updated on insert (increment) and delete (decrement)
   - Populated on first query via `count_by_tenant`
   - Used by `_should_use_enn` to avoid runtime counting
   - Thread-safe (asyncio lock)

4. Update `src/memory_service/dependencies.py`:
   - `get_vector_store` now supports `"mongodb"` backend
   - Creates `MongoDBAtlasVectorStore` with config values
   - Stores instance in app state for lifespan management

5. Update `src/memory_service/main.py`:
   - Add lifespan handler: call `vector_store.initialize()` on startup, close motor client on shutdown

### Tests

**Unit tests:**

- `tests/unit/repositories/test_mongodb_store.py`:
  - `_record_to_document` serialization roundtrip
  - `_document_to_record` deserialization
  - `_should_use_enn` returns True below threshold, False above
  - Verify search aggregation pipeline structure (mock motor collection)
  - Verify tenant_id is always in the pre-filter

- `tests/unit/repositories/test_tenant_counter.py`:
  - Increment and decrement
  - Get returns 0 for unknown tenant
  - Thread safety with concurrent increments

**Service tests (require local MongoDB via Docker):**

- `tests/service/repositories/test_mongodb_store.py` (marked `@pytest.mark.service`):
  - Insert and retrieve a memory record
  - Update with version increment
  - Delete returns True/False correctly
  - List with cursor pagination
  - List with scope filter
  - List with memory_type filter
  - delete_by_user removes user-scoped, preserves tenant-scoped
  - count_by_tenant returns correct count
  - Duplicate insert raises MemoryConflictError
  - Tenant isolation: insert as tenant A, query as tenant B returns empty
  - Optimistic concurrency: concurrent updates with same version — one succeeds, one fails
  - health_check returns True with valid connection

Note: Vector search tests are NOT possible against local MongoDB (Atlas Vector Search is Atlas-only). Vector search is tested in integration tests against Atlas.

**Integration tests (require MongoDB Atlas free tier):**

- `tests/integration/test_vector_search.py` (marked `@pytest.mark.integration`):
  - Insert memories with embeddings, search returns relevant results
  - ENN search (exact=True) returns correct results
  - ANN search (exact=False) returns correct results
  - Pre-filter by scope narrows results
  - Pre-filter by memory_type narrows results
  - min_relevance threshold filters low-relevance results
  - Multi-scope search (query across tenant + user + agent_user)

### Definition of Done

- `make check` passes (unit tests, no Docker needed)
- `make test-service` passes against local MongoDB (`docker run -p 27017:27017 mongo:7`)
- `VECTOR_STORE_BACKEND=mongodb make run` starts the service and `/ready` returns 200
- All unit tests from Step 1 still pass (no regression)
- **Wiring check**: Verify `MongoDBAtlasVectorStore` satisfies `VectorStore` protocol (mypy). Verify `dependencies.py` creates MongoDB store when `vector_store_backend=mongodb`. Verify motor client is properly closed on shutdown. Verify all MongoDB operations use `tenant_id` in the query filter.
- **Self-review**: Review MongoDB operations for: unhandled `pymongo.errors` (ConnectionFailure, ServerSelectionTimeoutError, DuplicateKeyError), missing `await` on async motor calls, missing timeout configuration on motor client, missing error wrapping (translate pymongo errors to MemoryServiceError subtypes), missing structlog context binding for MongoDB operations.
- **Logical bug review**: Verify `_document_to_record` handles missing optional fields (documents may have been created before a field was added). Verify `delete_by_user` query correctly excludes `scope=tenant` — check the query filter is `{"tenant_id": tid, "user_id": uid, "scope": {"$ne": "tenant"}}` not just `{"tenant_id": tid, "user_id": uid}`. Verify optimistic concurrency: update filter includes `version: record.version - 1` (match old version), set `version: record.version`. Verify cursor pagination handles edge case of deleted records (cursor points to a deleted ID). Verify `TenantCounter` is initialized on first query, not on startup (avoid blocking startup for large datasets).
- **Local run**: `VECTOR_STORE_BACKEND=mongodb make run` connects to local MongoDB, `/ready` returns 200.
- **Documentation**: Update CLAUDE.md with MongoDB setup instructions. Update design doc status.

### Principle Checklist

- [ ] P1 Incremental delivery
- [ ] P2 Tests from the start
- [ ] P3 Existing patterns
- [ ] P6 Wiring verification
- [ ] P7 Self-review
- [ ] P8 Logical bug review
- [ ] P10 Protocol-first
- [ ] P11 Multi-tenancy
- [ ] P9 Design doc sync

---

## Step 3 — Core CRUD API (cowork-memory-service)

**Repo:** `cowork-memory-service`

Add REST endpoints for direct memory management (create, get, list, search, update, delete). These endpoints use the `MemoryService` from Step 1, which delegates to whichever `VectorStore` backend is configured. No LLM involvement — this is direct CRUD.

### Work

1. Create `src/memory_service/routes/memories.py` — memory CRUD routes:
   ```python
   router = APIRouter(prefix="/v1/memories", tags=["memories"])

   @router.post("", status_code=201, response_model=MemoryResponse)
   async def create_memory(
       request: CreateMemoryRequest,
       tenant_id: str = Header(..., alias="X-Tenant-ID"),
       user_id: str | None = Header(None, alias="X-User-ID"),
       service: MemoryService = Depends(get_memory_service),
   ) -> MemoryResponse:
       """Create a specific memory directly (no LLM extraction)."""

   @router.get("/{memory_id}", response_model=MemoryResponse)
   async def get_memory(
       memory_id: str,
       tenant_id: str = Header(..., alias="X-Tenant-ID"),
       service: MemoryService = Depends(get_memory_service),
   ) -> MemoryResponse:
       """Get a single memory by ID."""

   @router.get("", response_model=MemoryListResponse)
   async def list_memories(
       tenant_id: str = Header(..., alias="X-Tenant-ID"),
       user_id: str | None = Query(None),
       scope: MemoryScope | None = Query(None),
       memory_type: MemoryType | None = Query(None),
       limit: int = Query(50, ge=1, le=200),
       cursor: str | None = Query(None),
       service: MemoryService = Depends(get_memory_service),
   ) -> MemoryListResponse:
       """List memories with filters and pagination."""

   @router.post("/search", response_model=SearchResponse)
   async def search_memories(
       request: SearchMemoriesRequest,
       tenant_id: str = Header(..., alias="X-Tenant-ID"),
       service: MemoryService = Depends(get_memory_service),
   ) -> SearchResponse:
       """Semantic search across memories with scope/type filtering."""

   @router.put("/{memory_id}", response_model=MemoryResponse)
   async def update_memory(
       memory_id: str,
       request: UpdateMemoryRequest,
       tenant_id: str = Header(..., alias="X-Tenant-ID"),
       service: MemoryService = Depends(get_memory_service),
   ) -> MemoryResponse:
       """Update a memory. Re-embeds if content changes."""

   @router.delete("/{memory_id}", status_code=204)
   async def delete_memory(
       memory_id: str,
       tenant_id: str = Header(..., alias="X-Tenant-ID"),
       service: MemoryService = Depends(get_memory_service),
   ) -> None:
       """Delete a single memory."""
   ```

2. Update `src/memory_service/main.py`:
   - Mount memories router
   - Add exception handler for `MemoryNotFoundError` → 404
   - Add exception handler for `MemoryConflictError` → 409
   - Add exception handler for `ValidationError` → 422
   - Add exception handler for `VectorStoreError` → 502
   - Add exception handler for `EmbeddingError` → 502
   - Add catch-all exception handler → 500 (no internal details leaked)

3. Update `src/memory_service/services/memory_service.py`:
   - Add scope validation: verify scope-field consistency (e.g., `agent_user` scope requires `agent_id` to be set)
   - Add `_resolve_search_scopes(tenant_id, user_id, agent_id, usecase_id)` — given the caller's identity, return all applicable scopes to query (tenant scope always included, plus user/agent_user/usecase_agent_user based on provided IDs)
   - Add `_validate_scope_fields(scope, user_id, agent_id, usecase_id)` — raise `ValidationError` if required fields for the scope are missing

4. Update `src/memory_service/models/requests.py`:
   - Add `SearchMemoriesRequest` field: `include_all_scopes: bool = True` — when True, automatically include all applicable scopes for the given identity. When False, use only explicitly provided `scopes` list.

### Tests

**Unit tests:**

- `tests/unit/routes/test_memories.py` (using TestClient + InMemoryVectorStore):
  - POST /v1/memories — creates memory, returns 201 with MemoryResponse
  - POST /v1/memories — missing X-Tenant-ID header returns 422
  - POST /v1/memories — invalid scope (missing required fields) returns 422
  - GET /v1/memories/{id} — returns memory with correct fields
  - GET /v1/memories/{id} — missing memory returns 404
  - GET /v1/memories/{id} — wrong tenant returns 404 (tenant isolation)
  - GET /v1/memories — returns paginated list
  - GET /v1/memories?scope=user — filters by scope
  - GET /v1/memories?memory_type=semantic — filters by type
  - GET /v1/memories — cursor pagination returns next page
  - POST /v1/memories/search — returns results sorted by relevance
  - POST /v1/memories/search — empty query returns empty results
  - POST /v1/memories/search — scope filter narrows results
  - POST /v1/memories/search — include_all_scopes resolves applicable scopes
  - PUT /v1/memories/{id} — updates content and re-embeds
  - PUT /v1/memories/{id} — updates metadata without re-embedding
  - PUT /v1/memories/{id} — increments version
  - PUT /v1/memories/{id} — missing memory returns 404
  - DELETE /v1/memories/{id} — returns 204
  - DELETE /v1/memories/{id} — missing memory returns 404

- `tests/unit/services/test_scope_resolution.py`:
  - Resolve scopes for tenant-only caller: returns `[tenant]`
  - Resolve scopes for user caller: returns `[tenant, user]`
  - Resolve scopes for agent+user caller: returns `[tenant, user, agent_user]`
  - Resolve scopes for usecase+agent+user caller: returns all four scopes
  - Validate scope fields: `agent_user` without `agent_id` raises ValidationError
  - Validate scope fields: `usecase_agent_user` without `usecase_id` raises ValidationError

**End-to-end route test:**

- `tests/unit/routes/test_memory_crud_flow.py`:
  - Create → Get → Update → Get (verify updated) → Delete → Get (verify 404)
  - Create multiple → List → Search → verify ordering
  - Multi-tenant isolation: create as tenant A, search as tenant B returns empty

### Definition of Done

- `make check` passes
- All CRUD endpoints functional against InMemoryVectorStore (testable with no infrastructure)
- All CRUD endpoints functional against local MongoDB (`make test-service`)
- **Wiring check**: Verify request models match route parameter names (no mismatches between request body fields and Header/Query params). Verify response model serialization matches API contract in design doc. Verify error codes in exception handlers match the error codes defined in `exceptions.py`. Verify `tenant_id` from header is passed through to all service calls (never lost in the chain).
- **Self-review**: Review routes for: missing input validation (empty content, negative limit), missing error handling (what if embedding fails during create?), missing logging (log every create/update/delete with tenant_id + memory_id), correct HTTP status codes (201 for create, 204 for delete, not 200). Review exception handlers: catch-all must not leak stack traces. Test conftest must register same exception handlers.
- **Logical bug review**: Verify `include_all_scopes` correctly expands scopes — test that a search with `user_id` set and `include_all_scopes=True` queries both `tenant` and `user` scopes. Verify cursor-based pagination handles: first page (no cursor), middle page, last page (returns None cursor), empty results. Verify update doesn't re-embed when only metadata changes (avoid unnecessary embedding cost). Verify delete returns 404 for wrong tenant (not 204 — don't leak existence information across tenants).
- **Local run**: `make run` and test all endpoints with curl/httpie.
- **Documentation**: Update design doc API section if any deviations from planned contract.

### Principle Checklist

- [ ] P1 Incremental delivery
- [ ] P2 Tests from the start
- [ ] P3 Existing patterns
- [ ] P6 Wiring verification
- [ ] P7 Self-review
- [ ] P8 Logical bug review
- [ ] P11 Multi-tenancy
- [ ] P12 Audit from day 1
- [ ] P9 Design doc sync

---

## Step 4 — Mem0 Integration + Ingest Pipeline (cowork-memory-service)

**Repo:** `cowork-memory-service`

Integrate Mem0 (Apache 2.0) as the extraction and consolidation engine. Add the ingest endpoint that accepts raw conversation messages, extracts memories via LLM, classifies memory types, and stores them. Supports async/sync modes and `allowed_scopes` governance.

> **Important: Mem0 async behavior.** Use `AsyncMemory` (not `Memory`) since we're in a FastAPI async context. However, `AsyncMemory` is **not truly async** — it wraps synchronous calls in `ThreadPoolExecutor`. This is acceptable at our scale (<10K tenants). The real latency is in LLM and vector store HTTP calls. Create the `AsyncMemory` instance once at app startup (FastAPI lifespan), not per-request. Our own `VectorStore`/`EmbeddingProvider` protocols are natively async — if Mem0's thread-pool becomes a bottleneck later, we can bypass its storage layer.

### Work

1. Add `mem0ai>=0.1,<1.0` to `pyproject.toml` dependencies

2. Create `src/memory_service/services/extraction.py` — `MemoryExtractor`:
   ```python
   class ExtractedMemory(BaseModel):
       content: str
       scope: MemoryScope
       memory_type: MemoryType
       entities: list[Entity]
       valid_from: datetime | None
       valid_until: datetime | None
       metadata: dict[str, Any]

   class ExtractionResult(BaseModel):
       memories: list[ExtractedMemory]
       consolidation_actions: list[ConsolidationAction]

   class ConsolidationAction(BaseModel):
       action: Literal["ADD", "UPDATE", "DELETE", "NOOP"]
       memory_id: str | None  # existing memory ID for UPDATE/DELETE
       extracted_memory: ExtractedMemory | None  # for ADD/UPDATE

   class MemoryExtractor:
       """Wraps Mem0 for memory extraction and consolidation.

       Mem0 is used as an internal implementation detail. The service's
       own API contract is never exposed to Mem0's API.
       """

       def __init__(
           self,
           llm_gateway_url: str,
           embedding_provider: EmbeddingProvider,
           model: str = "gpt-4o-mini",
       ) -> None: ...

       async def extract_memories(
           self,
           messages: list[dict[str, str]],
           *,
           tenant_id: str,
           user_id: str | None = None,
           agent_id: str | None = None,
           usecase_id: str | None = None,
           allowed_scopes: list[MemoryScope] | None = None,
           existing_memories: list[MemoryRecord] | None = None,
       ) -> ExtractionResult:
           """Extract memories from conversation messages.

           1. Call Mem0's extraction pipeline (LLM call via LLM Gateway)
           2. Classify each memory's type (semantic/episodic/procedural)
           3. Extract entities and temporal metadata
           4. Determine consolidation actions against existing memories
           5. Filter by allowed_scopes — discard memories outside permitted scopes
           """
   ```

3. Create `src/memory_service/services/consolidation.py` — `ConsolidationService`:
   ```python
   class ConsolidationService:
       """Applies consolidation actions from extraction to the vector store."""

       def __init__(
           self,
           store: VectorStore,
           embedder: EmbeddingProvider,
       ) -> None: ...

       async def apply(
           self,
           actions: list[ConsolidationAction],
           *,
           tenant_id: str,
           user_id: str | None,
           agent_id: str | None,
           usecase_id: str | None,
       ) -> list[MemoryResponse]:
           """Apply consolidation actions:
           - ADD: create new memory (generate ID, embed, insert)
           - UPDATE: update existing memory (re-embed if content changed)
           - DELETE: soft-delete existing memory (set is_deleted=True, set valid_until=now)
           - NOOP: skip (low-value, duplicate, or irrelevant)

           Returns list of created/updated memories.
           Emits audit events for each action.
           """
   ```

4. Create `src/memory_service/services/ingest.py` — `IngestService`:
   ```python
   class IngestService:
       """Orchestrates the ingest pipeline: extract → consolidate → store."""

       def __init__(
           self,
           extractor: MemoryExtractor,
           consolidator: ConsolidationService,
           store: VectorStore,
       ) -> None: ...

       async def ingest(
           self,
           request: IngestRequest,
           *,
           tenant_id: str,
       ) -> IngestResponse:
           """Full ingest pipeline:
           1. Fetch existing memories for the scope (for consolidation context)
           2. Extract memories from messages (LLM call)
           3. Apply consolidation actions (ADD/UPDATE/DELETE/NOOP)
           4. Return created/updated memories
           """

       async def ingest_async(
           self,
           request: IngestRequest,
           *,
           tenant_id: str,
       ) -> IngestAcknowledgment:
           """Submit for async processing. Returns acknowledgment immediately.
           Processing happens in background via asyncio.create_task."""
   ```

5. Create `src/memory_service/models/requests.py` additions:
   ```python
   class IngestRequest(BaseModel):
       messages: list[ConversationMessage]
       user_id: str | None = None
       agent_id: str | None = None
       usecase_id: str | None = None
       allowed_scopes: list[MemoryScope] | None = None
       async_mode: bool = True  # default async
       session_id: str | None = None  # for audit trail

   class ConversationMessage(BaseModel):
       role: Literal["user", "assistant", "system"]
       content: str
       timestamp: datetime | None = None
   ```

6. Create `src/memory_service/models/responses.py` additions:
   ```python
   class IngestResponse(BaseModel):
       """Returned for sync ingest."""
       memories_created: int
       memories_updated: int
       memories_deleted: int
       memories: list[MemoryResponse]

   class IngestAcknowledgment(BaseModel):
       """Returned for async ingest."""
       accepted: bool = True
       ingest_id: str  # tracking ID for the background job
   ```

7. Create `src/memory_service/routes/ingest.py`:
   ```python
   router = APIRouter(prefix="/v1/memories", tags=["ingest"])

   @router.post("/ingest", response_model=IngestResponse | IngestAcknowledgment)
   async def ingest_memories(
       request: IngestRequest,
       tenant_id: str = Header(..., alias="X-Tenant-ID"),
       service: IngestService = Depends(get_ingest_service),
   ) -> IngestResponse | IngestAcknowledgment:
       """Extract memories from conversation messages.

       async_mode=true (default): Returns acknowledgment immediately,
       processes in background.
       async_mode=false: Waits for extraction and returns results.
       """
   ```

8. Update `src/memory_service/dependencies.py`:
   - Add `get_memory_extractor` — creates `MemoryExtractor` with LLM Gateway URL
   - Add `get_consolidation_service` — creates `ConsolidationService` with store + embedder
   - Add `get_ingest_service` — creates `IngestService` with extractor + consolidator + store

9. Update `src/memory_service/main.py`:
   - Mount ingest router
   - Add background task tracking for async ingests (in-memory dict of ingest_id → status). This is ephemeral — lost on restart. Acceptable because the actual memory data is durable in the vector store; the tracking is best-effort status reporting only.

10. Create `src/memory_service/services/mock_extractor.py` — `MockMemoryExtractor`:
    - Deterministic extraction for testing (no LLM calls)
    - Extracts one memory per message with predictable content
    - Classifies based on keywords: "prefer" → semantic, "failed" → episodic, "always" → procedural
    - Used in unit tests and local development without LLM Gateway

### Tests

**Unit tests (all use InMemoryVectorStore + MockExtractor):**

- `tests/unit/services/test_extraction.py`:
  - Extract from single user message → returns ExtractedMemory
  - Extract from multi-turn conversation → returns multiple memories
  - Memory type classification: semantic, episodic, procedural
  - Entity extraction from content
  - allowed_scopes filtering: memories outside allowed scopes are discarded
  - allowed_scopes=None allows all scopes
  - Empty messages → empty extraction

- `tests/unit/services/test_consolidation.py`:
  - ADD action creates new memory
  - UPDATE action updates existing memory content and re-embeds
  - DELETE action sets valid_until on existing memory
  - NOOP action does nothing
  - Mixed actions: ADD + UPDATE + NOOP in one batch
  - Audit events emitted for ADD, UPDATE, DELETE (not NOOP)

- `tests/unit/services/test_ingest.py`:
  - Sync ingest: messages → extract → consolidate → return results
  - Sync ingest: verify memories are searchable after ingest
  - Async ingest: returns acknowledgment immediately
  - Async ingest: verify memories appear after background processing
  - allowed_scopes filtering: tenant scope excluded → no tenant memories created
  - Empty messages → no memories created
  - Ingest with session_id included in audit events

- `tests/unit/routes/test_ingest.py`:
  - POST /v1/memories/ingest with async_mode=false returns IngestResponse
  - POST /v1/memories/ingest with async_mode=true returns IngestAcknowledgment
  - POST /v1/memories/ingest without messages returns 422
  - POST /v1/memories/ingest without X-Tenant-ID returns 422

**End-to-end test:**

- `tests/unit/test_ingest_to_search_flow.py`:
  - Ingest conversation → search with related query → verify relevant memories returned
  - Ingest with allowed_scopes=["user"] → verify no tenant-scoped memories exist
  - Ingest same fact twice → consolidation deduplicates (UPDATE not double ADD)

### Definition of Done

- `make check` passes
- Ingest endpoint works with MockExtractor (no LLM needed for unit tests)
- Sync and async modes both functional
- `allowed_scopes` governance correctly filters extracted memories
- All Step 1-3 tests still pass (no regression)
- **Wiring check**: Verify `IngestService` → `MemoryExtractor` → `ConsolidationService` → `VectorStore` chain is correctly wired. Verify async ingest actually runs in background (not blocking the response). Verify `allowed_scopes` filtering happens AFTER extraction but BEFORE storage (memories are extracted at their natural scope, then filtered).
- **Self-review**: Review for: unhandled LLM Gateway errors (timeout, 5xx, rate limit), missing retry logic on LLM calls (use tenacity), missing error handling in async background tasks (exceptions in `create_task` are silently swallowed — add error logging), missing validation on `ConversationMessage` (empty content, invalid role), Mem0 library errors not wrapped in `MemoryServiceError`.
- **Logical bug review**: Verify consolidation UPDATE uses the correct existing memory ID (not the new memory's ID). Verify consolidation DELETE sets `valid_until` but does NOT hard-delete (soft delete for history). Verify async ingest error handling — if extraction fails, the error is logged and the ingest_id status is updated (not silently lost). Verify `allowed_scopes` filtering handles edge case where ALL extracted memories are outside allowed scopes (returns empty, not error). Verify memory type classification defaults to `semantic` if LLM doesn't provide a type (defensive fallback).
- **Local run**: `make run` with `EMBEDDING_PROVIDER=mock` and test ingest endpoint with curl.
- **Documentation**: Update design doc with Mem0 integration details and ingest endpoint contract.

### Principle Checklist

- [ ] P1 Incremental delivery
- [ ] P2 Tests from the start
- [ ] P3 Existing patterns
- [ ] P6 Wiring verification
- [ ] P7 Self-review
- [ ] P8 Logical bug review
- [ ] P11 Multi-tenancy
- [ ] P12 Audit from day 1
- [ ] P9 Design doc sync

---

## Step 5 — OpenSearch Vector Store (cowork-memory-service)

**Repo:** `cowork-memory-service`

Implement `OpenSearchVectorStore` as the secondary vector store backend. Switchable via `VECTOR_STORE_BACKEND=opensearch` environment variable. Same `VectorStore` protocol, same test suite.

### Work

1. Add `opensearch-py>=2.7,<3.0` to `pyproject.toml` dependencies

2. Create `src/memory_service/repositories/opensearch_store.py` — `OpenSearchVectorStore`:
   ```python
   class OpenSearchVectorStore:
       def __init__(
           self,
           url: str,
           index_name: str,
           *,
           embedding_dimensions: int = 1536,
       ) -> None: ...

       async def initialize(self) -> None:
           """Create index with kNN mapping if it doesn't exist.

           Index mapping:
           - embedding: knn_vector with configured dimensions
           - tenant_id: keyword (filterable)
           - user_id: keyword (filterable)
           - agent_id: keyword (filterable)
           - usecase_id: keyword (filterable)
           - scope: keyword (filterable)
           - memory_type: keyword (filterable)
           - content: text (for BM25 search in future)
           - created_at: date
           - All other MemoryRecord fields as appropriate types
           """

       async def insert(self, record: MemoryRecord) -> None:
           """Index document. Document ID = memory_id."""

       async def get(self, memory_id: str, tenant_id: str) -> MemoryRecord | None:
           """Get by ID, verify tenant_id matches."""

       async def update(self, record: MemoryRecord) -> None:
           """Update document. Optimistic concurrency via _seq_no/_primary_term."""

       async def delete(self, memory_id: str, tenant_id: str) -> bool:
           """Delete by ID with tenant_id verification."""

       async def search(
           self,
           embedding: list[float],
           tenant_id: str,
           *,
           user_id: str | None = None,
           agent_id: str | None = None,
           usecase_id: str | None = None,
           scopes: list[MemoryScope] | None = None,
           memory_types: list[MemoryType] | None = None,
           limit: int = 10,
           min_relevance: float = 0.0,
       ) -> list[tuple[MemoryRecord, float]]:
           """kNN search with pre-filtering.

           Uses OpenSearch kNN query with filter clause:
           - Always filter on tenant_id
           - Optional filters: user_id, scopes, memory_types
           - k = limit, min_score = min_relevance
           """

       async def list_memories(
           self,
           tenant_id: str,
           *,
           user_id: str | None = None,
           scope: MemoryScope | None = None,
           memory_type: MemoryType | None = None,
           limit: int = 50,
           cursor: str | None = None,
       ) -> tuple[list[MemoryRecord], str | None]:
           """Query with filters, sorted by created_at desc.
           Cursor = search_after value (created_at of last result)."""

       async def delete_by_user(self, tenant_id: str, user_id: str) -> int:
           """Delete by query: tenant_id + user_id + scope != tenant."""

       async def count_by_tenant(self, tenant_id: str) -> int:
           """Count query filtered by tenant_id."""

       async def health_check(self) -> bool:
           """Cluster health check."""

       # Internal helpers
       def _record_to_document(self, record: MemoryRecord) -> dict[str, Any]: ...
       def _document_to_record(self, doc: dict[str, Any]) -> MemoryRecord: ...
   ```

3. Update `src/memory_service/dependencies.py`:
   - `get_vector_store` now supports `"opensearch"` backend
   - Creates `OpenSearchVectorStore` with config values

4. Update `src/memory_service/main.py`:
   - Lifespan handler calls `initialize()` for OpenSearch store on startup

### Tests

**Unit tests:**

- `tests/unit/repositories/test_opensearch_store.py`:
  - `_record_to_document` serialization roundtrip
  - `_document_to_record` deserialization
  - Verify kNN query structure (mock OpenSearch client)
  - Verify tenant_id is always in the filter clause

**Service tests (require local OpenSearch via Docker):**

- `tests/service/repositories/test_opensearch_store.py` (marked `@pytest.mark.service`):
  - Insert and retrieve a memory record
  - Update with optimistic concurrency
  - Delete returns True/False correctly
  - kNN search returns results sorted by relevance
  - Search with scope filter
  - Search with memory_type filter
  - Search with min_relevance threshold
  - List with cursor pagination
  - delete_by_user removes user-scoped, preserves tenant-scoped
  - count_by_tenant returns correct count
  - Tenant isolation: insert as tenant A, search as tenant B returns empty
  - health_check returns True

**Cross-backend test:**

- `tests/service/test_backend_parity.py`:
  - Parameterized test that runs the same CRUD + search operations against InMemoryVectorStore, MongoDBAtlasVectorStore (local MongoDB, no vector search), and OpenSearchVectorStore
  - Verifies all three backends produce consistent results for non-vector operations (CRUD, list, delete_by_user)

### Definition of Done

- `make check` passes
- `make test-service` passes against local OpenSearch (`docker run -p 9200:9200 ...`)
- `VECTOR_STORE_BACKEND=opensearch make run` starts the service and `/ready` returns 200
- All Step 1-4 tests still pass (no regression)
- **Wiring check**: Verify `OpenSearchVectorStore` satisfies `VectorStore` protocol (mypy). Verify `dependencies.py` creates OpenSearch store when `vector_store_backend=opensearch`. Verify OpenSearch client is properly closed on shutdown. Verify env var switching works: set `VECTOR_STORE_BACKEND=opensearch`, verify OpenSearch is used; set to `mongodb`, verify MongoDB is used; set to `memory`, verify InMemory is used.
- **Self-review**: Review OpenSearch operations for: unhandled `opensearchpy.exceptions` (ConnectionError, NotFoundError, RequestError), missing `await` on async calls, missing timeout configuration, missing error wrapping, missing index creation idempotency (`ignore=[400]` on create_index for already-exists).
- **Logical bug review**: Verify kNN search filter uses `bool` query with `must` clause for tenant_id (not `should`). Verify `delete_by_user` uses `delete_by_query` and correctly excludes tenant scope. Verify cursor pagination with `search_after` handles: first page (no search_after), last page (no more results), concurrent writes between pages. Verify index refresh: after insert/update/delete, data may not be immediately searchable — service tests should use `refresh=True` or explicit refresh.
- **Local run**: `VECTOR_STORE_BACKEND=opensearch make run` connects to local OpenSearch, all endpoints work.
- **Documentation**: Update CLAUDE.md with OpenSearch setup. Update design doc with OpenSearch implementation notes.

### Principle Checklist

- [ ] P1 Incremental delivery
- [ ] P2 Tests from the start
- [ ] P3 Existing patterns
- [ ] P6 Wiring verification
- [ ] P7 Self-review
- [ ] P8 Logical bug review
- [ ] P10 Protocol-first
- [ ] P11 Multi-tenancy
- [ ] P9 Design doc sync

---

## Step 6 — Version History + GDPR + Audit (cowork-memory-service)

**Repo:** `cowork-memory-service`

Add memory version history tracking, GDPR-compliant user deletion, and formalize audit event emission.

### Work

**Version history:**

1. Create `src/memory_service/models/domain.py` addition — `MemoryVersion`:
   ```python
   class MemoryVersion(BaseModel):
       version: int
       content: str
       memory_type: MemoryType
       metadata: dict[str, Any]
       entities: list[Entity]
       changed_by: str | None
       changed_at: datetime
       change_reason: Literal["created", "updated", "consolidation"]
   ```

2. Update `src/memory_service/repositories/vector_store.py` — add to `VectorStore` protocol:
   ```python
   async def get_history(self, memory_id: str, tenant_id: str) -> list[MemoryVersion]: ...
   async def save_version(self, memory_id: str, tenant_id: str, version: MemoryVersion) -> None: ...
   ```

3. Update `src/memory_service/repositories/memory_store.py` — `InMemoryVectorStore`:
   - Add `_history: dict[tuple[str, str], list[MemoryVersion]]` storage
   - Implement `get_history` and `save_version`

4. Update `src/memory_service/repositories/mongodb_store.py` — `MongoDBAtlasVectorStore`:
   - Store versions in a separate collection (`{collection}_history`) or as a sub-document array
   - Decision: separate collection — avoids unbounded document growth, enables efficient queries
   - Collection: `memories_history` with compound index `(tenant_id, memory_id, version)`
   - Implement `get_history` (query by memory_id + tenant_id, sorted by version desc)
   - Implement `save_version` (insert into history collection)

5. Update `src/memory_service/repositories/opensearch_store.py` — `OpenSearchVectorStore`:
   - Store versions in a separate index (`{index}_history`)
   - Implement `get_history` and `save_version`

6. Update `src/memory_service/services/memory_service.py`:
   - On create: save initial version (version=1, change_reason="created")
   - On update: save version snapshot BEFORE applying update (version=N, change_reason="updated")
   - On consolidation update: save version snapshot (change_reason="consolidation")

7. Create `src/memory_service/routes/memories.py` addition:
   ```python
   @router.get("/{memory_id}/history", response_model=list[MemoryVersionResponse])
   async def get_memory_history(
       memory_id: str,
       tenant_id: str = Header(..., alias="X-Tenant-ID"),
       service: MemoryService = Depends(get_memory_service),
   ) -> list[MemoryVersionResponse]:
       """Get version history for a memory. Sorted by version descending."""
   ```

8. Create `src/memory_service/models/responses.py` addition:
   ```python
   class MemoryVersionResponse(BaseModel):
       version: int
       content: str
       memory_type: MemoryType
       metadata: dict[str, Any]
       entities: list[Entity]
       changed_by: str | None
       changed_at: datetime
       change_reason: str
   ```

**GDPR user deletion:**

9. Create `src/memory_service/routes/admin.py`:
   ```python
   router = APIRouter(prefix="/v1", tags=["admin"])

   @router.delete("/users/{user_id}/memories", status_code=200)
   async def delete_user_memories(
       user_id: str,
       tenant_id: str = Header(..., alias="X-Tenant-ID"),
       service: MemoryService = Depends(get_memory_service),
   ) -> UserDeletionResponse:
       """GDPR user deletion.

       Deletes all memories at user, agent_user, and usecase_agent_user
       scopes for the given user within the tenant.
       Preserves tenant-scoped memories (organizational knowledge survives).
       Also deletes version history for deleted memories.
       """

   @router.get("/tenants/{tenant_id}/stats", response_model=TenantStatsResponse)
   async def get_tenant_stats(
       tenant_id: str,
       requesting_tenant_id: str = Header(..., alias="X-Tenant-ID"),
       service: MemoryService = Depends(get_memory_service),
   ) -> TenantStatsResponse:
       """Get memory statistics for a tenant.
       Verifies requesting_tenant_id matches path tenant_id."""
   ```

10. Create response models:
    ```python
    class UserDeletionResponse(BaseModel):
        user_id: str
        memories_deleted: int
        history_records_deleted: int

    class TenantStatsResponse(BaseModel):
        tenant_id: str
        total_memories: int
        memories_by_scope: dict[str, int]
        memories_by_type: dict[str, int]
    ```

11. Update `src/memory_service/services/memory_service.py`:
    - `delete_user_memories(tenant_id, user_id) -> UserDeletionResponse`
    - `get_tenant_stats(tenant_id) -> TenantStatsResponse`

12. Update `src/memory_service/main.py`:
    - Mount admin router

**Audit events (formalize):**

13. Update `src/memory_service/logging.py` — formalize audit event structure:
    ```python
    class AuditEventType(str, Enum):
        MEMORY_CREATED = "memory.created"
        MEMORY_UPDATED = "memory.updated"
        MEMORY_DELETED = "memory.deleted"
        MEMORY_SEARCHED = "memory.searched"
        MEMORY_BULK_DELETED = "memory.bulk_deleted"
        USER_MEMORIES_DELETED = "memory.user_deleted"

    def emit_audit_event(
        event_type: AuditEventType,
        *,
        tenant_id: str,
        memory_id: str | None = None,
        user_id: str | None = None,
        scope: str | None = None,
        memory_type: str | None = None,
        action_by: str | None = None,
        count: int | None = None,
        session_id: str | None = None,
    ) -> None:
        """Emit structured audit log event.

        NO PII: no memory content, no user prompts, no entities.
        Only event type, IDs, scope, type, and timestamp.
        """
    ```

14. Review all existing service methods and add audit events where missing.

### Tests

**Unit tests:**

- `tests/unit/services/test_version_history.py`:
  - Create memory → history has version 1 with change_reason="created"
  - Update memory → history has version 1 (original) + current is version 2
  - Multiple updates → history grows with each version
  - History returns versions sorted by version desc

- `tests/unit/routes/test_history.py`:
  - GET /v1/memories/{id}/history returns version list
  - GET /v1/memories/{id}/history for non-existent memory returns 404
  - GET /v1/memories/{id}/history wrong tenant returns 404

- `tests/unit/services/test_user_deletion.py`:
  - Delete user memories: removes user, agent_user, usecase_agent_user scoped
  - Delete user memories: preserves tenant-scoped memories
  - Delete user memories: also deletes version history
  - Delete user memories: returns correct counts
  - Delete user memories: no memories → returns 0 counts (not error)
  - Audit event emitted for user deletion

- `tests/unit/routes/test_admin.py`:
  - DELETE /v1/users/{id}/memories returns UserDeletionResponse
  - DELETE /v1/users/{id}/memories without X-Tenant-ID returns 422
  - GET /v1/tenants/{id}/stats returns TenantStatsResponse
  - GET /v1/tenants/{id}/stats with mismatched tenant_id returns 403

- `tests/unit/test_audit_events.py`:
  - Verify audit events contain expected fields
  - Verify audit events do NOT contain memory content (no PII)
  - Verify audit events are emitted for create, update, delete, bulk_delete, user_delete

**Service tests (MongoDB):**

- `tests/service/test_version_history_mongodb.py`:
  - Version history persisted and retrieved correctly in separate collection
  - User deletion cascades to history collection

### Definition of Done

- `make check` passes
- `make test-service` passes
- Version history endpoint returns correct data
- GDPR user deletion removes correct scopes, preserves tenant scope
- Audit events verified in structured logs (no PII)
- All Step 1-5 tests still pass (no regression)
- **Wiring check**: Verify history is saved BEFORE update is applied (to capture the pre-update state). Verify user deletion → VectorStore.delete_by_user + history deletion are both called. Verify admin route mounts correctly. Verify tenant stats query aggregates correctly.
- **Self-review**: Review for: missing history save on consolidation updates (Step 4 consolidation service must also save versions), missing error handling on history save failure (should not fail the main update — best-effort), missing tenant_id validation on admin routes (requesting tenant must match path tenant).
- **Logical bug review**: Verify version numbering: create = version 1, first update = version 2. Verify history save uses write-before-delete ordering (save version, then update record). Verify user deletion handles concurrent writes (a new memory created during deletion should not be left orphaned — use retry or eventual consistency). Verify tenant stats handles zero memories (returns zeroes, not error). Verify audit events for bulk operations include count, not individual IDs (avoid large log entries).
- **Local run**: Test version history and user deletion via curl.
- **Documentation**: Update design doc GDPR section and API summary.

### Principle Checklist

- [ ] P1 Incremental delivery
- [ ] P2 Tests from the start
- [ ] P3 Existing patterns
- [ ] P6 Wiring verification
- [ ] P7 Self-review
- [ ] P8 Logical bug review
- [ ] P10 Protocol-first
- [ ] P11 Multi-tenancy
- [ ] P12 Audit from day 1
- [ ] P9 Design doc sync

---

## Step 7 — Reranker + Rate Limiting (cowork-memory-service)

**Repo:** `cowork-memory-service`

Add optional reranker support for improved search relevance, and per-tenant rate limiting / quota enforcement.

### Work

**Reranker:**

1. Create `src/memory_service/repositories/reranker.py` — `Reranker` protocol:
   ```python
   @runtime_checkable
   class Reranker(Protocol):
       async def rerank(
           self,
           query: str,
           results: list[tuple[MemoryRecord, float]],
           *,
           top_k: int = 10,
       ) -> list[tuple[MemoryRecord, float]]:
           """Rerank search results. Returns reordered list with updated scores."""
   ```

2. Create `src/memory_service/repositories/llm_reranker.py` — `LLMReranker`:
   - Uses LLM Gateway to rerank results
   - Sends query + result contents to LLM
   - LLM returns relevance scores for each result
   - Fallback: if LLM call fails, return original ranking (graceful degradation)

3. Create `src/memory_service/repositories/mock_reranker.py` — `MockReranker`:
   - Deterministic reranking for tests (reverses order, for predictable assertions)

4. Update `src/memory_service/models/requests.py`:
   ```python
   class SearchMemoriesRequest(BaseModel):
       # ... existing fields ...
       rerank: bool = False  # opt-in reranking
   ```

5. Update `src/memory_service/services/memory_service.py`:
   - `search_memories` — if `request.rerank=True` and reranker is configured, apply reranking after vector search
   - Reranker is optional dependency (None if not configured)

6. Update `src/memory_service/dependencies.py`:
   - Add `get_reranker` — returns `LLMReranker` or `None` based on config
   - Update `get_memory_service` to accept optional reranker

7. Update `src/memory_service/config.py`:
   ```python
   # Reranker
   reranker_enabled: bool = False
   reranker_model: str = "gpt-4o-mini"
   ```

**Rate limiting:**

8. Create `src/memory_service/services/rate_limiter.py` — `RateLimiter`:
   ```python
   class TenantQuota(BaseModel):
       max_memories: int = 100_000  # per tenant
       max_ingests_per_minute: int = 60
       max_searches_per_minute: int = 300

   class RateLimiter:
       """In-memory per-tenant rate limiting.

       Uses sliding window counters for rate limits.
       Uses VectorStore.count_by_tenant for quota checks.
       """

       def __init__(self, default_quota: TenantQuota) -> None: ...

       async def check_memory_quota(
           self, tenant_id: str, current_count: int
       ) -> None:
           """Raises TenantQuotaExceededError if at limit."""

       async def check_ingest_rate(self, tenant_id: str) -> None:
           """Raises TenantQuotaExceededError if rate exceeded."""

       async def check_search_rate(self, tenant_id: str) -> None:
           """Raises TenantQuotaExceededError if rate exceeded."""

       def record_ingest(self, tenant_id: str) -> None:
           """Record an ingest operation for rate tracking."""

       def record_search(self, tenant_id: str) -> None:
           """Record a search operation for rate tracking."""
   ```

9. Update `src/memory_service/services/memory_service.py`:
   - `create_memory` — check memory quota before insert
   - `search_memories` — check search rate before searching

10. Update `src/memory_service/services/ingest.py`:
    - `ingest` — check ingest rate before processing

11. Update `src/memory_service/main.py`:
    - Add exception handler for `TenantQuotaExceededError` → 429 with `Retry-After` header

12. Update `src/memory_service/config.py`:
    ```python
    # Rate limiting
    rate_limit_enabled: bool = True
    default_max_memories: int = 100_000
    default_max_ingests_per_minute: int = 60
    default_max_searches_per_minute: int = 300
    ```

13. Update `src/memory_service/dependencies.py`:
    - Add `get_rate_limiter` — creates `RateLimiter` with config values
    - Wire into memory service and ingest service

### Tests

**Unit tests:**

- `tests/unit/repositories/test_llm_reranker.py`:
  - Rerank reorders results
  - Rerank with top_k limits output
  - LLM failure → graceful fallback to original order
  - Empty results → empty output

- `tests/unit/services/test_rate_limiter.py`:
  - Under quota → passes
  - At quota limit → raises TenantQuotaExceededError
  - Rate limit sliding window: requests expire after window
  - Different tenants have independent counters
  - Memory quota check uses current count

- `tests/unit/routes/test_rate_limiting.py`:
  - Exceeding ingest rate → 429 with Retry-After header
  - Exceeding search rate → 429
  - Exceeding memory quota on create → 429
  - Under limits → normal response

- `tests/unit/services/test_reranked_search.py`:
  - Search with rerank=True applies reranker
  - Search with rerank=False skips reranker
  - Search with rerank=True but reranker not configured → uses original ranking

### Definition of Done

- `make check` passes
- Reranker improves search result ordering (verified in integration test with real LLM)
- Rate limiting returns 429 when limits exceeded
- Rate limiting doesn't affect normal operation under limits
- All Step 1-6 tests still pass (no regression)
- **Wiring check**: Verify reranker is optional — service works without it. Verify rate limiter is checked BEFORE expensive operations (embedding, vector search, LLM extraction). Verify 429 response includes `Retry-After` header.
- **Self-review**: Review for: rate limiter memory leak (sliding window must expire old entries), reranker timeout handling (LLM rerank call must have timeout), missing rate limit check on any write endpoint, incorrect quota counting (count_by_tenant should be cached, not called on every create).
- **Logical bug review**: Verify sliding window counter handles clock skew (use monotonic time). Verify rate limit applies to async ingests (count at submission time, not completion time). Verify memory quota check is atomic with insert (check + insert without race condition — or accept eventual consistency). Verify reranker doesn't modify the original result list (returns new list). Verify `Retry-After` header value is reasonable (60 seconds for rate limit, not 0 or infinity).
- **Local run**: Test rate limiting by sending rapid requests, verify 429 responses.
- **Documentation**: Update design doc with reranker and rate limiting details.

### Principle Checklist

- [ ] P1 Incremental delivery
- [ ] P2 Tests from the start
- [ ] P3 Existing patterns
- [ ] P6 Wiring verification
- [ ] P7 Self-review
- [ ] P8 Logical bug review
- [ ] P10 Protocol-first
- [ ] P11 Multi-tenancy
- [ ] P9 Design doc sync

---

## Step 8 — Platform Contracts (cowork-platform)

**Repo:** `cowork-platform`

Add JSON schemas for memory service types to `cowork-platform`. Generate Pydantic (Python) and TypeScript bindings. These contracts enable type-safe communication between the memory service, agent runtime, and desktop app.

### Work

1. Create `contracts/schemas/memory-record.json`:
   - id, tenant_id, user_id, agent_id, usecase_id
   - scope (enum: tenant, user, agent_user, usecase_agent_user)
   - memory_type (enum: semantic, episodic, procedural)
   - content, metadata, entities
   - valid_from, valid_until
   - created_by, created_at, updated_at, last_accessed_at
   - version (integer)
   - relevance (optional float — present in search results)

2. Create `contracts/schemas/memory-search-request.json`:
   - query (string)
   - tenant_id, user_id, agent_id, usecase_id
   - scopes (array of scope enum)
   - memory_types (array of type enum)
   - limit, min_relevance
   - include_all_scopes (boolean)
   - rerank (boolean)

3. Create `contracts/schemas/memory-search-response.json`:
   - results: array of { memory (memory-record), relevance (float), recency (float) }

4. Create `contracts/schemas/memory-ingest-request.json`:
   - messages: array of { role, content, timestamp }
   - user_id, agent_id, usecase_id
   - allowed_scopes (array of scope enum)
   - async_mode (boolean)
   - session_id (optional)

5. Create `contracts/schemas/memory-ingest-response.json`:
   - memories_created, memories_updated, memories_deleted
   - memories: array of memory-record

6. Create `contracts/schemas/memory-save-request.json` (for Memory.Save tool):
   - content (string)
   - memory_type (optional enum — defaults to semantic)
   - scope (optional enum — defaults to user)
   - metadata (optional object)

7. Run codegen: generate Python (Pydantic via datamodel-code-generator) and TypeScript (via json-schema-to-typescript) bindings

8. Verify generated types match the domain models in `cowork-memory-service`

9. Update `cowork-platform` SDK helpers if needed (e.g., `MemoryScope`, `MemoryType` enums as SDK constants)

### Tests

- Schema validation tests for all new schemas (valid + invalid examples)
- Codegen output matches expected type names and field types
- Generated Pydantic models can serialize/deserialize sample data
- Generated TypeScript types compile with tsc

### Definition of Done

- `make check` passes on `cowork-platform`
- Python and TypeScript bindings generated and importable
- All new schemas have validation tests
- **Wiring check**: Import new Pydantic types in `cowork-memory-service` — verify they match existing domain models (field names, types, optionality). Import new TypeScript types in `cowork-desktop-app` — verify they compile. Verify enum values in schemas match the `MemoryScope` and `MemoryType` enums in the memory service.
- **Self-review**: Review schemas for: field name consistency (camelCase in JSON, snake_case in Python generated code), enum value consistency with memory service domain models, optional vs required fields matching the actual API behavior, missing fields that the API returns but the schema doesn't include.
- **Logical bug review**: Verify `relevance` is optional in `memory-record.json` (only present in search results, not in CRUD responses). Verify `async_mode` defaults to `true` in schema (matches service behavior). Verify `allowed_scopes` is optional and nullable (caller can omit to allow all scopes). Verify `memory-save-request.json` fields match what the Memory.Save tool will accept in Step 9.
- **Documentation**: Update cowork-platform CLAUDE.md and README.md with new schemas. Update memory service design doc to reference platform contracts.

### Principle Checklist

- [ ] P1 Incremental delivery
- [ ] P2 Tests from the start
- [ ] P3 Existing patterns
- [ ] P6 Wiring verification
- [ ] P7 Self-review
- [ ] P8 Logical bug review
- [ ] P9 Design doc sync

---

## Step 9 — Agent Runtime: Memory Tools (cowork-agent-runtime)

**Repo:** `cowork-agent-runtime`

Add `Memory.Search` and `Memory.Save` tools to the Tool Runtime. These tools allow the agent to explicitly search and save memories during task execution.

### Work

1. Create `src/tool_runtime/tools/memory/__init__.py`

2. Create `src/tool_runtime/tools/memory/search_memory.py` — `SearchMemoryTool`:
   ```python
   class SearchMemoryTool(BaseTool):
       """Memory.Search — semantic search across persistent memories.

       Capability: Memory.Search
       Parameters:
         - query (str, required): natural language search query
         - memory_types (list[str], optional): filter by type
         - scopes (list[str], optional): filter by scope
         - limit (int, optional, default=5): max results
       Returns:
         - list of memories with content, scope, type, relevance, created_at
       """

       name = "Memory.Search"
       capability = "Memory.Search"

       def __init__(self, memory_client: MemoryClient) -> None: ...

       async def execute(self, params: dict[str, Any], context: ExecutionContext) -> ToolExecutionResult:
           """
           1. Extract query + filters from params
           2. Call MemoryClient.search(query, tenant_id, user_id, agent_id, ...)
           3. Format results as human-readable text
           4. Return ToolExecutionResult with formatted content
           """
   ```

3. Create `src/tool_runtime/tools/memory/save_memory.py` — `SaveMemoryTool`:
   ```python
   class SaveMemoryTool(BaseTool):
       """Memory.Save — explicitly save a memory.

       Capability: Memory.Save
       Parameters:
         - content (str, required): the memory to save
         - memory_type (str, optional, default="semantic"): semantic/episodic/procedural
         - scope (str, optional, default="user"): tenant/user/agent_user/usecase_agent_user
         - metadata (dict, optional): additional metadata
       Returns:
         - confirmation with memory ID
       """

       name = "Memory.Save"
       capability = "Memory.Save"

       def __init__(self, memory_client: MemoryClient) -> None: ...

       async def execute(self, params: dict[str, Any], context: ExecutionContext) -> ToolExecutionResult:
           """
           1. Validate params (content required, valid scope/type)
           2. Call MemoryClient.create(content, scope, memory_type, tenant_id, user_id, ...)
           3. Return ToolExecutionResult with confirmation
           """
   ```

4. Create `src/tool_runtime/tools/memory/memory_client.py` — `MemoryClient`:
   ```python
   class MemoryClient:
       """HTTP client for the Memory Service."""

       def __init__(self, base_url: str, http_client: httpx.AsyncClient) -> None: ...

       async def search(
           self,
           query: str,
           *,
           tenant_id: str,
           user_id: str | None = None,
           agent_id: str | None = None,
           usecase_id: str | None = None,
           scopes: list[str] | None = None,
           memory_types: list[str] | None = None,
           limit: int = 5,
           rerank: bool = False,
       ) -> list[dict[str, Any]]:
           """POST /v1/memories/search with X-Tenant-ID header."""

       async def create(
           self,
           content: str,
           *,
           tenant_id: str,
           user_id: str | None = None,
           agent_id: str | None = None,
           usecase_id: str | None = None,
           scope: str = "user",
           memory_type: str = "semantic",
           metadata: dict[str, Any] | None = None,
       ) -> dict[str, Any]:
           """POST /v1/memories with X-Tenant-ID header."""

       async def health_check(self) -> bool:
           """GET /health — returns True if 200."""
   ```

5. Update `src/tool_runtime/router/tool_router.py`:
   - Register `SearchMemoryTool` and `SaveMemoryTool` when `MEMORY_SERVICE_URL` is configured
   - Tools are optional — if memory service is not configured, tools are not registered (no error)

6. Update `src/agent_host/config.py`:
   ```python
   # Memory Service
   memory_service_url: str | None = None  # None = memory tools disabled
   ```

7. Update `.env.example`:
   - Add `MEMORY_SERVICE_URL=http://localhost:8003`

8. Add `Memory.Search` and `Memory.Save` to capability definitions in platform contracts (if not already defined in Step 8)

### Tests

**Unit tests:**

- `tests/unit/tool_runtime/tools/memory/test_search_memory.py`:
  - Search with query returns formatted results
  - Search with filters passes them to client
  - Search with no results returns empty message
  - Search with memory service error returns error result (not exception)
  - Empty query returns validation error

- `tests/unit/tool_runtime/tools/memory/test_save_memory.py`:
  - Save with content creates memory
  - Save with memory_type and scope passes them to client
  - Save with invalid scope returns validation error
  - Save with memory service error returns error result
  - Empty content returns validation error

- `tests/unit/tool_runtime/tools/memory/test_memory_client.py`:
  - Search sends correct request (POST /v1/memories/search, X-Tenant-ID header)
  - Create sends correct request (POST /v1/memories, X-Tenant-ID header)
  - HTTP error → appropriate exception
  - Timeout → appropriate exception
  - Retry on transient errors (5xx, connection error)

- `tests/unit/tool_runtime/router/test_tool_router_memory.py`:
  - Memory tools registered when MEMORY_SERVICE_URL is set
  - Memory tools NOT registered when MEMORY_SERVICE_URL is None
  - Existing tools unaffected by memory tool registration

### Definition of Done

- `make check` passes on `cowork-agent-runtime`
- Memory tools available in tool list when MEMORY_SERVICE_URL is configured
- Memory tools NOT available when MEMORY_SERVICE_URL is not set (no regression for existing setups)
- All existing tests pass (no regression)
- **Wiring check**: Verify `MemoryClient` sends `X-Tenant-ID` header on all requests. Verify `ExecutionContext` provides `tenant_id`, `user_id`, `agent_id` that tools need — trace from `SessionManager` through `ToolExecutor` to `ExecutionContext` to `MemoryTool`. Verify tool parameter names match what the LLM will generate (based on tool definitions). Verify tool result format is compatible with `ToolResult` schema.
- **Self-review**: Review for: unhandled httpx exceptions (TimeoutException, ConnectError), missing retry with backoff on MemoryClient calls, missing timeout configuration on MemoryClient (default httpx timeout may be too long for a tool call), missing structured logging on tool execution, tool definitions have clear descriptions that guide LLM usage.
- **Logical bug review**: Verify Memory.Save respects `allowed_scopes` from the session's policy bundle (agent should not be able to save tenant-scoped memories unless permitted). Verify Memory.Search results are formatted in a way the LLM can use (not raw JSON — human-readable with clear memory content, scope, type). Verify tool error results don't leak internal service errors to the LLM (sanitize error messages). Verify MemoryClient handles empty response body (204 from delete) without crashing.
- **Local run**: Start memory service + agent runtime, verify Memory.Search and Memory.Save tools appear in tool list, test tool execution.
- **Documentation**: Update `cowork-agent-runtime` CLAUDE.md and README.md. Update `cowork-infra/docs/components/local-tool-runtime.md` with memory tools. Update design doc.

### Principle Checklist

- [ ] P1 Incremental delivery
- [ ] P2 Tests from the start
- [ ] P3 Existing patterns
- [ ] P4 No agent-runtime regression
- [ ] P6 Wiring verification
- [ ] P7 Self-review
- [ ] P8 Logical bug review
- [ ] P11 Multi-tenancy
- [ ] P9 Design doc sync

---

## Step 10 — Agent Runtime: Auto Injection + Ingestion (cowork-agent-runtime)

**Repo:** `cowork-agent-runtime`

Add automatic memory retrieval before each LLM call (context injection) and automatic background ingestion after each task completion. This ensures memories are always used and captured without relying on the LLM to explicitly invoke tools.

### Work

**Memory retrieval (Agent Host — auto-inject before LLM calls):**

1. Create `src/agent_host/session/memory_client.py` — reuse or import `MemoryClient` from tool_runtime:
   - Agent Host needs its own reference to `MemoryClient` (separate from Tool Runtime's copy)
   - Or: move `MemoryClient` to a shared location importable by both
   - Decision: `MemoryClient` lives in `tool_runtime/tools/memory/memory_client.py`, Agent Host imports it. This is a one-way dependency (agent_host → tool_runtime is already the existing pattern via `ToolRouter` interface) — but actually this would violate the no-cross-import rule.
   - Correct approach: Create `src/agent_host/clients/memory_client.py` as Agent Host's own HTTP client for the memory service. Tool Runtime has its own copy. Both are simple HTTP clients — duplication is acceptable to maintain the boundary.

2. Create `src/agent_host/clients/memory_client.py` — `AgentHostMemoryClient`:
   ```python
   class AgentHostMemoryClient:
       """Memory Service HTTP client for Agent Host.

       Used for automatic memory retrieval and ingestion.
       Separate from Tool Runtime's MemoryClient to maintain boundary.
       """

       def __init__(self, base_url: str, http_client: httpx.AsyncClient) -> None: ...

       async def search(
           self,
           query: str,
           *,
           tenant_id: str,
           user_id: str | None = None,
           agent_id: str | None = None,
           limit: int = 10,
       ) -> list[dict[str, Any]]:
           """Search memories. Used for auto-retrieval before LLM calls."""

       async def ingest(
           self,
           messages: list[dict[str, str]],
           *,
           tenant_id: str,
           user_id: str | None = None,
           agent_id: str | None = None,
           allowed_scopes: list[str] | None = None,
           session_id: str | None = None,
       ) -> None:
           """Async ingest (fire-and-forget). Used for auto-ingestion after tasks."""

       async def health_check(self) -> bool: ...
   ```

3. Update `src/agent_host/loop/loop_runtime.py` — add memory retrieval to `call_llm`:
   ```python
   class LoopRuntime:
       def __init__(self, ..., memory_client: AgentHostMemoryClient | None = None): ...

       async def call_llm(self, messages, tools, task_id, step_id, on_text_chunk=None):
           # NEW: Auto-retrieve relevant memories before LLM call
           if self._memory_client is not None:
               memory_context = await self._retrieve_memory_context(messages)
               if memory_context:
                   messages = self._inject_memory_context(messages, memory_context)

           # Existing LLM call logic
           response = await self._llm_client.chat(messages, tools, ...)
           return response

       async def _retrieve_memory_context(
           self, messages: list[dict[str, Any]]
       ) -> str | None:
           """Extract query from recent messages, search memory service.

           Strategy: use the last user message as the search query.
           Returns formatted memory context string, or None if no results.
           """
           try:
               last_user_msg = self._get_last_user_message(messages)
               if not last_user_msg:
                   return None

               results = await self._memory_client.search(
                   query=last_user_msg,
                   tenant_id=self._session_context.tenant_id,
                   user_id=self._session_context.user_id,
                   agent_id=self._session_context.agent_id,
                   limit=10,
               )

               if not results:
                   return None

               return self._format_memory_context(results)
           except Exception:
               # Memory retrieval failure must never break the agent loop
               logger.warning("memory_retrieval_failed", exc_info=True)
               return None

       def _inject_memory_context(
           self, messages: list[dict[str, Any]], context: str
       ) -> list[dict[str, Any]]:
           """Inject memory context as a system message.

           Inserts after the main system prompt, before conversation messages.
           Format:
           [RELEVANT MEMORIES]
           - (semantic, user) User prefers TypeScript [2026-03-10]
           - (procedural, tenant) Always run tests before committing [2026-02-28]
           [/RELEVANT MEMORIES]
           """

       def _get_last_user_message(self, messages: list[dict[str, Any]]) -> str | None: ...
       def _format_memory_context(self, results: list[dict[str, Any]]) -> str: ...
   ```

**Memory ingestion (Agent Host — auto-ingest after task completion):**

4. Update `src/agent_host/session/session_manager.py` — add auto-ingestion:
   ```python
   class SessionManager:
       def __init__(self, ..., memory_client: AgentHostMemoryClient | None = None): ...

       async def _on_task_complete(self, task_id: str, messages: list[dict[str, Any]]) -> None:
           """Called after a task completes successfully.

           Sends conversation messages to memory service for background extraction.
           Fire-and-forget: ingestion failure must never affect task completion.
           """
           if self._memory_client is None:
               return

           try:
               # Filter to user + assistant messages only (no system prompts)
               conversation_messages = [
                   {"role": m["role"], "content": m["content"]}
                   for m in messages
                   if m["role"] in ("user", "assistant")
               ]

               if not conversation_messages:
                   return

               # Determine allowed_scopes from session policy
               allowed_scopes = self._get_allowed_memory_scopes()

               await self._memory_client.ingest(
                   messages=conversation_messages,
                   tenant_id=self._session_context.tenant_id,
                   user_id=self._session_context.user_id,
                   agent_id=self._session_context.agent_id,
                   allowed_scopes=allowed_scopes,
                   session_id=self._session_context.session_id,
               )

               logger.info(
                   "memory_ingestion_submitted",
                   task_id=task_id,
                   message_count=len(conversation_messages),
               )
           except Exception:
               # Ingestion failure must never affect task completion
               logger.warning("memory_ingestion_failed", task_id=task_id, exc_info=True)

       def _get_allowed_memory_scopes(self) -> list[str] | None:
           """Read allowed memory scopes from session policy bundle.
           Returns None if not configured (allows all scopes)."""
   ```

5. Update `src/agent_host/session/session_manager.py` — wire memory client:
   - If `config.memory_service_url` is set, create `AgentHostMemoryClient` in `__init__`
   - Pass to `LoopRuntime` constructor
   - Call `_on_task_complete` after task completes in the task execution flow

6. Update `src/agent_host/config.py`:
   - `memory_service_url` already added in Step 9 — verify it's accessible from SessionManager

7. Update `.env.example`:
   - Verify `MEMORY_SERVICE_URL` is documented

### Tests

**Unit tests:**

- `tests/unit/agent_host/clients/test_memory_client.py`:
  - Search sends correct request
  - Ingest sends correct request with async_mode=True
  - HTTP error → logged, not raised
  - Timeout → logged, not raised

- `tests/unit/agent_host/loop/test_memory_retrieval.py`:
  - Memory context retrieved from last user message
  - Memory context injected after system prompt
  - No user message → no retrieval
  - Empty search results → no injection
  - Memory client failure → LLM call proceeds normally (graceful degradation)
  - Memory retrieval disabled when memory_client is None

- `tests/unit/agent_host/session/test_memory_ingestion.py`:
  - Task completion triggers ingestion
  - Only user + assistant messages sent (no system prompts)
  - allowed_scopes from policy bundle passed through
  - Ingestion failure → task still succeeds (logged warning)
  - Memory client None → no ingestion (no error)
  - Empty conversation → no ingestion

- `tests/unit/agent_host/loop/test_memory_context_format.py`:
  - Format includes scope, type, content, date
  - Multiple memories formatted as list
  - Long memories truncated
  - Memory context wrapped in [RELEVANT MEMORIES] markers

**Integration test (requires memory service + backend services + LLM Gateway running):**

- Update `scripts/test-chat.py`:
  - Add memory service health check at startup
  - Add test: send a conversation → verify memories are ingested → start new session → verify memories are retrieved in context
  - Add test: explicit Memory.Search tool call returns relevant memories
  - Add test: explicit Memory.Save tool call creates a memory
  - Add test: memory service down → agent still works (graceful degradation)

### Definition of Done

- `make check` passes on `cowork-agent-runtime`
- `make test-chat` passes with memory service running (memories persist across sessions)
- `make test-chat` passes WITHOUT memory service running (graceful degradation, no errors)
- All existing tests pass (no regression)
- Memories are automatically retrieved before LLM calls and injected as context
- Conversations are automatically ingested after task completion
- Memory retrieval and ingestion failures never break the agent loop
- **Wiring check**: Verify `SessionManager` creates `AgentHostMemoryClient` when `memory_service_url` is configured. Verify `LoopRuntime` receives memory client and uses it in `call_llm`. Verify `_on_task_complete` is called at the correct point in the task lifecycle (after task success, not on cancellation or failure). Verify `tenant_id`, `user_id`, `agent_id` are correctly propagated from `SessionContext` to memory client calls.
- **Self-review**: Review for: memory retrieval adding latency to every LLM call (should be fast — search with small limit, timeout of 2-3 seconds), memory context bloating the prompt (limit injected memories, truncate long content), missing error handling in `_retrieve_memory_context` (must catch ALL exceptions, not just httpx errors), missing structured logging for memory operations, system prompt injection location correctness (after main system prompt, before conversation).
- **Logical bug review**: Verify memory retrieval doesn't cause infinite recursion (retrieving memories → injecting them → LLM sees them → next step retrieves again with same query → same memories injected). Mitigation: deduplicate injected memories across steps within the same task. Verify auto-ingestion doesn't ingest the injected memory context (only raw conversation messages, not the `[RELEVANT MEMORIES]` block). Verify `_get_last_user_message` handles edge cases: no user messages, very long messages (truncate before searching), multi-part messages. Verify auto-ingestion happens AFTER task completion response is sent (don't delay the response). Verify memory context is NOT included in messages sent to ingestion (would create circular memory extraction).
- **Local run**: Start full stack (memory service + backend services + agent runtime), run a conversation, verify memories appear in logs. Start a new session, verify memories are retrieved.
- **Documentation**: Update `cowork-agent-runtime` CLAUDE.md and README.md. Update `cowork-infra/docs/components/local-agent-host.md` with memory retrieval and ingestion. Update `cowork-infra/docs/services/memory-service.md` with agent runtime integration details.

### Principle Checklist

- [ ] P1 Incremental delivery
- [ ] P2 Tests from the start
- [ ] P3 Existing patterns
- [ ] P4 No agent-runtime regression
- [ ] P6 Wiring verification
- [ ] P7 Self-review
- [ ] P8 Logical bug review
- [ ] P11 Multi-tenancy
- [ ] P9 Design doc sync
