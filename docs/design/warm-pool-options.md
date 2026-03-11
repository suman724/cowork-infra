# Warm Pool — Design Options

**Problem:** Cold-starting an ECS Fargate sandbox takes 15–45 seconds. We want session start time < 3 seconds.

**Context:** Session Service runs N instances behind an ALB. The current flow is: `POST /sessions` → `ecs:RunTask` → container starts → `POST /sessions/{id}/register` → `SANDBOX_READY`. The warm pool pre-provisions idle containers so session creation can skip the ECS launch wait.

---

## Option A: DynamoDB-Coordinated Pool (Full Distributed Design)

All pool state lives in a dedicated `{env}-warm-pool` DynamoDB table. Every instance reads/writes this table. No in-memory pool state.

### How it works

1. **Replenishment:** Background task on each instance attempts a DynamoDB distributed lock (`__REPLENISH_LOCK__` sentinel item with conditional write + 60s TTL). Lock winner queries IDLE count, launches deficit containers via `RunTask`, releases lock.
2. **Claim:** Session creation queries IDLE containers from a GSI, attempts atomic conditional write (`status = IDLE → CLAIMED`). `ConditionalCheckFailedException` means another instance won — try next candidate.
3. **Assignment:** Session Service calls `POST /assign` on the warm container with session context (sessionId, policyBundle, workspaceId). Container initializes and becomes a live sandbox.
4. **Heartbeat:** Warm containers send periodic heartbeats to Session Service. Stale containers (no heartbeat) are cleaned up.
5. **Lifecycle:** Separate checker handles stale claims (release back), launch timeouts, max age, version drain.
6. **Auto-scaling:** Pool config stored in DynamoDB. Scaling logic runs inside the replenishment lock using CloudWatch metrics (hit rate, cold start count).

### New components

- `{env}-warm-pool` DynamoDB table (7 states, 2 GSIs, sentinel records for lock + config)
- `WarmPoolManager` service (acquire, assign, release, replenish, drain)
- `WarmPoolLifecycleChecker` background task
- `WarmPoolRepository` (DynamoDB + InMemory implementations)
- `POST /warm-pool/register` and `POST /warm-pool/heartbeat` routes
- `POST /assign` endpoint on agent-runtime HttpTransport
- CloudWatch metrics, alarms, EventBridge schedules
- Terraform: DynamoDB table, IAM policies, CloudWatch resources

### Pros

- Fully distributed — works correctly with any number of Session Service instances
- No single point of failure (DynamoDB is the coordination layer)
- Precise pool management — exact target maintained, no overshoot
- Supports auto-scaling, time-based schedules, version draining
- All state is durable and queryable for debugging

### Cons

- **High complexity** — 7-state machine, distributed lock, heartbeat protocol, assignment protocol, lifecycle checker, 5+ new files
- **Many DynamoDB operations per cycle** — replenishment lock acquire/release, IDLE count query, heartbeat updates
- **New RPC protocol** — `POST /assign` on agent-runtime is a new endpoint and communication pattern (Session Service → container, opposite of current container → Session Service flow)
- **Estimated effort:** 3–4 weeks
- **Testing complexity** — need to test distributed lock contention, stale recovery, concurrent claims, heartbeat timeout, version drain

---

## Option B: Single-Writer with SQS Queue

One Session Service instance is the designated pool manager. Other instances request warm containers via an SQS queue.

### How it works

1. **Leader election:** Use a DynamoDB-based lease (single record, conditional write, 30s TTL). One instance becomes the "pool leader."
2. **Pool leader responsibilities:**
   - Maintains an in-memory list of idle container endpoints
   - Runs replenishment loop (no distributed lock needed — single writer)
   - Polls an SQS "claim request" queue
   - On claim request: pop from idle list, send container endpoint to SQS "claim response" queue (keyed by requestId)
3. **Session creation (any instance):**
   - Send claim request to SQS queue with `requestId`
   - Wait for response on SQS response queue (long-poll, 5s timeout)
   - If response received: container endpoint ready, proceed with assignment
   - If timeout: fall back to cold start
4. **Assignment:** Same as Option A — `POST /assign` on the warm container.
5. **Failover:** If leader stops renewing lease, another instance takes over. New leader discovers running IDLE containers by calling `ecs:DescribeTasks` with the pool's task group.

### New components

- SQS claim-request and claim-response queues
- Leader election lease (DynamoDB, 1 record)
- `WarmPoolLeader` background task (only runs on leader instance)
- `WarmPoolClient` (used by non-leader instances to request containers via SQS)
- `POST /assign` endpoint on agent-runtime
- Terraform: SQS queues, IAM policies

### Pros

- **Single writer eliminates most coordination problems** — no distributed lock for replenishment, no double-launch, no contention on claims
- In-memory pool list is fast (no DynamoDB query per claim)
- Leader failover is straightforward

### Cons

- **SQS adds latency** — claim request → queue → leader processes → queue → response adds 100–500ms vs. direct DynamoDB conditional write (~10ms)
- **Leader is a bottleneck** — all claims go through one instance. If pool leader is slow, all session starts are slow
- **Failover gap** — when leader crashes, 30s lease expiry + container discovery delay = ~45s gap with no warm pool (cold starts only)
- **Harder to debug** — state is in-memory on leader, not visible in a DynamoDB table
- **SQS infrastructure** — two queues, dead-letter config, IAM policies
- **Estimated effort:** 2–3 weeks

---

## Option C: Simplified DynamoDB Pool (No Heartbeat, No Assignment RPC)

Like Option A but with two key simplifications:
1. **No heartbeat protocol** — rely on ECS task health checks and `DescribeTasks` for container liveness.
2. **No `POST /assign` RPC** — reuse the existing self-registration flow. The warm container re-registers with the assigned session ID.

### How it works

1. **Replenishment:** Same distributed lock approach as Option A, but simpler table schema (3 states: `IDLE`, `CLAIMED`, `TERMINATED`).
2. **Warm container startup:** Container starts with `WARM_POOL_MODE=true` and no `SESSION_ID`. It calls `POST /warm-pool/register { containerId, endpoint }` and then enters an idle wait loop, polling `GET /warm-pool/assignment/{containerId}` every 2 seconds.
3. **Claim:** Same atomic conditional write as Option A (`IDLE → CLAIMED`). On success, Session Service writes the assignment details (sessionId, policyBundle, workspaceId) to a new `assignment` attribute on the warm-pool record.
4. **Container picks up assignment:** Container's poll detects the assignment, reads sessionId + config, then follows the existing self-registration flow: `POST /sessions/{sessionId}/register { endpoint, taskArn, registrationToken }`.
5. **Stale detection:** Instead of heartbeats, the replenishment cycle calls `ecs:DescribeTasks` for all IDLE containers. Any container not in RUNNING state is cleaned up.
6. **No lifecycle checker needed** — stale detection is part of the replenishment cycle.

### New components

- `{env}-warm-pool` DynamoDB table (3 states: IDLE, CLAIMED, TERMINATED; 1 GSI)
- `WarmPoolManager` service (acquire, replenish, drain — no assign/heartbeat logic)
- `POST /warm-pool/register` route (container → Session Service)
- `GET /warm-pool/assignment/{containerId}` route (container polls for assignment)
- Polling loop in agent-runtime (instead of `POST /assign` endpoint)
- Terraform: DynamoDB table, IAM policies

### Pros

- **Simpler than Option A** — 3 states instead of 7, no heartbeat protocol, no `POST /assign` RPC
- **Reuses existing registration flow** — container calls `POST /sessions/{id}/register` just like cold start, so Session Service registration code is unchanged
- **No new agent-runtime endpoint** — just a polling loop in the warm pool idle mode
- **Fewer background tasks** — no lifecycle checker (stale detection in replenishment cycle)
- **Still distributed** — works with N instances via DynamoDB coordination

### Cons

- **Polling adds 0–2s latency** — container polls every 2s for assignment, so average assignment delay is 1s on top of claim time
- **DescribeTasks API calls** — `ecs:DescribeTasks` per replenishment cycle (max 100 tasks per call). At small pool sizes (<20) this is fine; at scale could hit API rate limits
- **Assignment details in DynamoDB** — policyBundle can be large (several KB). Storing it on the warm-pool record is awkward. Could use a presigned URL or separate `{env}-warm-pool-assignments` table
- **Estimated effort:** 2 weeks

---

## Option D: ECS Service with Target Tracking (AWS-Native)

Instead of managing individual tasks, run warm containers as an ECS Service with a desired count. Use a separate "pool" ECS service that auto-scales.

### How it works

1. **Pool ECS Service:** A separate ECS service (`{env}-sandbox-pool`) runs N container instances. Each container starts in idle mode, registers its endpoint to a DynamoDB table.
2. **Claim:** Session creation queries IDLE containers from DynamoDB, does a conditional write (same as Options A/C).
3. **Assignment:** Claimed container receives session context (via `POST /assign` or polling).
4. **After assignment:** Container is removed from the pool ECS service (by updating the DynamoDB record). The ECS service detects desired count > running count and launches a replacement automatically.
5. **Scaling:** Use ECS Service auto-scaling (target tracking on a custom CloudWatch metric like `IdleContainerCount`) instead of custom replenishment logic.

### New components

- Separate ECS service definition for pool containers
- DynamoDB table for pool container registry (simpler — ECS manages lifecycle)
- Claim logic (same conditional write pattern)
- Assignment protocol
- CloudWatch metric + auto-scaling policy
- Terraform: new ECS service, auto-scaling, CloudWatch

### Pros

- **AWS manages container lifecycle** — no custom replenishment, no distributed lock, no launch logic
- **Auto-scaling is built-in** — ECS Service auto-scaling with target tracking, no custom scaling code
- **Automatic replacement** — when a container is claimed, ECS automatically starts a new one to maintain desired count
- **Health checks handled by ECS** — no heartbeat protocol needed

### Cons

- **ECS Service model mismatch** — ECS services expect long-running tasks. "Claiming" a container means it leaves the service's control, which ECS will interpret as a task failure and replace. This works but is a hack — we're abusing ECS service scaling to get automatic replacement
- **Minimum running tasks** — ECS service always has N running tasks even during zero-traffic periods (wastes money overnight). Time-based scaling helps but is less flexible than custom logic
- **Task deregistration is messy** — to "claim" a container, we either need to stop the ECS task (which ECS replaces) and start a new standalone task (defeating the purpose), or somehow transfer the task from service-managed to standalone. ECS doesn't support this — a task is either part of a service or it isn't
- **The fundamental problem:** A warm container needs to transition from "pool-managed" to "session-managed." ECS services don't support this transition. The container would need to be stopped and a new standalone task started with the session context, which is essentially a cold start with a pre-pulled image
- **Estimated effort:** 2–3 weeks, but the ECS service/standalone task transition problem may make this infeasible

---

## Option E: Pre-Pulled Image + Fargate Spot (Reduce Cold Start Instead)

Instead of pre-provisioning containers, reduce the cold-start time itself so a warm pool isn't needed.

### How it works

1. **Smaller image:** Optimize the Docker image for fast startup — slim base, minimal layers, pre-compiled Python bytecode, no unnecessary packages.
2. **ECR image cache:** Fargate caches recently-used images. Frequent launches keep the image in cache, reducing pull time from ~15s to ~2s.
3. **Init container pattern:** Use an ECS init container to pull workspace files while the main container starts.
4. **Parallel initialization:** Start the agent-runtime HTTP server first (responds to health checks), then sync workspace and load policy in background.
5. **Fargate Spot:** Use Fargate Spot for development sandboxes (70% cheaper), reserve on-demand for production.
6. **Provisioning UI:** Show a meaningful progress indicator during the 5–10s startup instead of a spinner.

### New components

- Dockerfile optimizations (multi-stage, `.pyc` pre-compilation, layer ordering)
- Parallel startup logic in agent-runtime
- Init container in ECS task definition
- UI progress indicator in web-app
- Fargate Spot capacity provider config

### Pros

- **Zero operational complexity** — no pool management, no DynamoDB table, no background tasks, no coordination
- **No idle resource cost** — containers only run when sessions are active
- **Works at any scale** — no pool sizing concerns, no target tuning
- **Simpler debugging** — one container per session, simple lifecycle
- **Fargate Spot saves money** — 70% cost reduction for non-critical sandboxes

### Cons

- **Cold start still 5–15 seconds** — even with all optimizations, Fargate task placement + ENI attachment takes ~5s minimum. Image pull from cache adds ~2s. Total: 7–15s best case
- **Does not meet <3s target** — if <3s is a hard requirement, this option fails. If 5–10s with a good UX is acceptable, this is the simplest path
- **Fargate Spot interruptions** — Spot can be reclaimed with 2-minute warning. Need graceful handling (checkpoint workspace, notify user)
- **ECR cache is best-effort** — cold start in a new AZ or after cache eviction reverts to full pull time
- **Estimated effort:** 1 week

---

## Option F: Hybrid — Small Fixed Pool + Cold Start Fallback

A minimal warm pool (2–5 containers) managed simply, with cold-start fallback when pool is empty. No auto-scaling, no heartbeats, no complex lifecycle. Optimized for the common case (a few concurrent users) rather than peak load.

### How it works

1. **Fixed pool size** configured per environment (dev: 1, staging: 2, prod: 5). Stored as an env var, not DynamoDB.
2. **Replenishment:** Single background task per instance attempts a DynamoDB lock (same as Option A). Lock winner counts IDLE containers, launches deficit up to target. Runs every 60 seconds.
3. **Warm container startup:** Container starts in idle mode, calls `POST /warm-pool/register`. Then polls `GET /warm-pool/assignment/{containerId}` every 2 seconds (same as Option C).
4. **Claim:** Atomic conditional write on DynamoDB (`IDLE → CLAIMED`). On success, write assignment details. On miss, cold-start fallback.
5. **Assignment pickup:** Container's poll detects assignment, follows existing self-registration flow.
6. **Stale cleanup:** Replenishment cycle also calls `DescribeTasks` on IDLE containers and removes dead ones. No separate lifecycle checker.
7. **No auto-scaling.** Fixed target. Adjust via config change + redeploy when usage patterns change.
8. **No heartbeat.** Use `DescribeTasks` in replenishment cycle.
9. **Container max age:** Containers older than 1 hour are replaced during replenishment (prevents stale images).

### DynamoDB table: `{env}-warm-pool`

| Attribute | Type | Description |
|-----------|------|-------------|
| `containerId` (PK) | String | ECS task ARN |
| `status` | String | `IDLE`, `CLAIMED`, `TERMINATED` |
| `sandboxEndpoint` | String | Container IP:port |
| `claimedBySessionId` | String | Session ID (set on claim) |
| `assignmentPayload` | String | JSON: `{sessionId, workspaceId, registrationToken, policyBundle}` |
| `launchedAt` | String | ISO 8601 |
| `createdAt` / `updatedAt` | String | Standard fields |
| `ttl` | Number | DynamoDB TTL |

One GSI: `status-launchedAt-index` (PK: `status`, SK: `launchedAt`).

One sentinel: `__REPLENISH_LOCK__` (same as Option A, simpler usage).

### New components

- `{env}-warm-pool` DynamoDB table (3 states, 1 GSI, 1 sentinel)
- `WarmPoolManager` (acquire, replenish — ~200 lines)
- `POST /warm-pool/register` and `GET /warm-pool/assignment/{containerId}` routes
- Polling loop in agent-runtime idle mode
- Terraform: DynamoDB table, IAM policy
- LocalStack init script update

### Pros

- **Simple** — 3 states, 1 background task, no heartbeat, no assignment RPC, no lifecycle checker
- **Reuses existing registration flow** — claimed container calls `POST /sessions/{id}/register` like a cold start
- **No new agent-runtime endpoint** — just a polling loop
- **Works with multiple instances** — DynamoDB lock + conditional writes handle coordination
- **Low risk** — small fixed pool means worst case is cold-start fallback (current behavior)
- **Easy to reason about** — replenishment runs every 60s, claim is one conditional write, that's it
- **Easy to turn off** — set `warm_pool_target=0` and pool is disabled

### Cons

- **0–2s polling latency** — container polls every 2s, so average extra delay is 1s
- **Fixed pool wastes resources off-hours** — 5 idle containers running 24/7 at ~$0.05/hr each = ~$180/month. Acceptable for production; set to 0 or 1 for dev
- **No auto-scaling** — pool can be depleted during traffic spikes. Users get cold starts (current behavior, not worse)
- **policyBundle in DynamoDB** — assignment payload can be several KB. DynamoDB max item size is 400KB so this is fine, but it's not elegant. Alternative: store a presigned URL or reference
- **DescribeTasks API** — called every 60s for pool containers. At pool size ≤20 this is negligible
- **Estimated effort:** 1–1.5 weeks

---

## Comparison Matrix

| Criteria | A: Full DynamoDB | B: SQS Queue | C: Simplified DynamoDB | D: ECS Service | E: No Pool | F: Hybrid Fixed |
|----------|:---:|:---:|:---:|:---:|:---:|:---:|
| **Claim latency** | ~10ms | 100–500ms | 0–2s | ~10ms | N/A (7–15s) | 0–2s |
| **Implementation effort** | 3–4 weeks | 2–3 weeks | 2 weeks | 2–3 weeks* | 1 week | 1–1.5 weeks |
| **Operational complexity** | High | Medium | Medium | Medium | None | Low |
| **New components** | 7+ files, 2 bg tasks | 5+ files, SQS queues | 4 files, 1 bg task | ECS service, scaling | Dockerfile tweaks | 3 files, 1 bg task |
| **Multi-instance safe** | Yes | Yes (leader) | Yes | Yes (ECS) | N/A | Yes |
| **Auto-scaling** | Yes | Via leader | No (manual) | ECS native | N/A | No (manual) |
| **Idle resource cost** | Variable (auto) | Variable (leader) | Fixed | Fixed (ECS min) | Zero | Fixed (low) |
| **Failover gap** | <60s (lock TTL) | ~45s (lease) | <60s (lock TTL) | None (ECS) | N/A | <60s (lock TTL) |
| **Debugging** | DynamoDB table | In-memory + SQS | DynamoDB table | ECS console | Simple | DynamoDB table |
| **Meets <3s target** | Yes | Marginal | Marginal (1–2s) | Depends* | No (7–15s) | Marginal (1–2s) |
| **Risk** | Medium (complexity) | Medium (bottleneck) | Low | High (infeasible) | None | Low |

*Option D has a fundamental feasibility issue: ECS services don't support transferring a task from service-managed to standalone.

---

## Recommendation

**For MVP / Phase 1: Option F (Hybrid Fixed Pool)** — simplest path that delivers most of the value. A fixed pool of 3–5 containers handles the common case. Cold-start fallback ensures no regression. Can be built in ~1 week.

**If <3s is a hard requirement and polling latency is unacceptable: Option C (Simplified DynamoDB)** — adds the assignment polling approach but still avoids the full heartbeat/lifecycle/auto-scaling complexity. Upgrade from F to C later if needed.

**If auto-scaling becomes necessary at scale: Option A (Full DynamoDB)** — the full distributed design. Build this as a Phase 2 evolution of Option F, not as the starting point.

**Option E (No Pool) is worth doing regardless** — Docker image optimization and parallel startup reduce cold-start time for pool misses. These improvements compound with any pool option.

---

## Migration Path

```
Option E (optimize cold start)     ← Do first regardless, 1 week
    ↓
Option F (fixed pool, 3–5 containers)  ← MVP warm pool, 1–1.5 weeks
    ↓
Option C (polling assignment, DynamoDB)  ← If polling latency is acceptable
    ↓
Option A (full distributed, auto-scaling)  ← If scale demands it
```

Each step is additive — F builds on E, C refines F, A extends C. No throwaway work.
