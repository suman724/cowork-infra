# Telemetry Service — Detailed Design

> **Status: Future Implementation**
> The Telemetry Service is planned but not required for Phase 1 or 2. A basic implementation may be added in Phase 3 alongside stronger observability features. References in other service docs to `POST /telemetry/events` and `POST /telemetry/traces` should be treated as no-ops or logged locally until this service exists.

**Phase:** 3
**Repo:** `cowork-observability` (`telemetry/` package)
**Bounded Context:** ObservabilityAudit

---

## Purpose

The Telemetry Service ingests structured operational events, traces, and metrics from all system components. It provides the observability layer for diagnosing performance issues, understanding usage patterns, and monitoring system health. Unlike the Audit Service (which focuses on security-relevant and compliance events), the Telemetry Service focuses on operational data.

---

## Responsibilities

- Ingest telemetry events and trace spans from desktop and backend components
- Aggregate metrics for system health and usage monitoring
- Route data to observability infrastructure (e.g. distributed tracing systems, metrics stores)
- Support trace correlation across component boundaries using shared trace and span IDs
- Retain operational data per retention policy (shorter than audit retention)

---

## Relationships

| Called by | Purpose |
|-----------|---------|
| Local Agent Host | Session lifecycle events, LLM call traces, step execution metrics |
| Local Tool Runtime | Tool execution timing and outcome metrics |
| Session Service | Session creation and handshake metrics |
| LLM Gateway | LLM request and response latency, token usage metrics |
| Backend Tool Service | Remote tool execution metrics |

---

## Telemetry vs Audit

The Telemetry Service and Audit Service are separate because their data has different characteristics and requirements:

| Dimension | Telemetry Service | Audit Service |
|-----------|------------------|---------------|
| Purpose | Operational observability | Security and compliance |
| Data type | Traces, metrics, performance events | Security-relevant decisions and actions |
| Retention | Short-term (days to weeks) | Long-term (months to years) |
| Mutability | Mutable — data may be aggregated or rolled up | Immutable — append-only |
| Sensitivity | Low (no business content) | High (approval decisions, access records) |
| Consumers | Operations team, developers | Compliance, security, governance |

---

## Event Envelope

All telemetry events use the same standard envelope as audit events:

```json
{
  "eventId": "evt_456",
  "eventType": "llm_request_completed",
  "timestamp": "2026-02-21T15:09:05Z",
  "tenantId": "tenant_abc",
  "userId": "user_123",
  "workspaceId": "ws_456",
  "sessionId": "sess_789",
  "taskId": "task_001",
  "component": "LocalAgentHost",
  "boundedContext": "AgentExecution",
  "severity": "info",
  "payload": {
    "model": "claude-sonnet-4-6",
    "inputTokens": 1204,
    "outputTokens": 312,
    "latencyMs": 1850
  }
}
```

---

## Trace Model

For distributed tracing, the Telemetry Service accepts trace spans that can be correlated across component boundaries.

### Trace Span Schema

```json
{
  "traceId": "trace_abc123",
  "spanId": "span_def456",
  "parentSpanId": "span_ghi789",
  "operationName": "llm_request",
  "component": "LocalAgentHost",
  "sessionId": "sess_789",
  "taskId": "task_001",
  "stepId": "step_003",
  "startTime": "2026-02-21T15:09:03Z",
  "endTime": "2026-02-21T15:09:05Z",
  "durationMs": 1850,
  "status": "ok",
  "tags": {
    "model": "claude-sonnet-4-6",
    "inputTokens": 1204,
    "outputTokens": 312
  }
}
```

### Trace Correlation

A `traceId` spans the full step lifecycle:
- `LocalAgentHost` starts a trace at the beginning of a step
- Child spans are created for LLM calls, tool calls, and approval gates
- All spans share the same `traceId` for correlation
- `sessionId`, `taskId`, and `stepId` are always present for filtering

---

## Key Telemetry Events

| Event | Emitted by | Key payload fields |
|-------|------------|--------------------|
| `session_started` | Local Agent Host | `executionEnvironment` |
| `session_completed` | Local Agent Host | `taskCount`, `totalTokens`, `durationMs` |
| `llm_request_started` | Local Agent Host | `model`, `inputTokens` |
| `llm_request_completed` | Local Agent Host | `model`, `inputTokens`, `outputTokens`, `latencyMs` |
| `tool_requested` | Local Agent Host | `toolName`, `capability` |
| `tool_completed` | Local Agent Host | `toolName`, `status`, `latencyMs` |
| `approval_requested` | Local Agent Host | `riskLevel` |
| `approval_resolved` | Local Agent Host | `decision`, `latencyMs` |
| `session_handshake_completed` | Session Service | `compatibilityStatus`, `latencyMs` |

---

## API Endpoints

### POST /telemetry/events — Ingest Telemetry Event

```json
{
  "eventId": "evt_456",
  "eventType": "llm_request_completed",
  "timestamp": "2026-02-21T15:09:05Z",
  "tenantId": "tenant_abc",
  "userId": "user_123",
  "sessionId": "sess_789",
  "taskId": "task_001",
  "component": "LocalAgentHost",
  "boundedContext": "AgentExecution",
  "severity": "info",
  "payload": {
    "model": "claude-sonnet-4-6",
    "inputTokens": 1204,
    "outputTokens": 312,
    "latencyMs": 1850
  }
}
```

**Response:** `202 Accepted`

---

### POST /telemetry/traces — Ingest Trace Span

```json
{
  "traceId": "trace_abc123",
  "spanId": "span_def456",
  "parentSpanId": "span_ghi789",
  "operationName": "llm_request",
  "component": "LocalAgentHost",
  "sessionId": "sess_789",
  "taskId": "task_001",
  "stepId": "step_003",
  "startTime": "2026-02-21T15:09:03Z",
  "endTime": "2026-02-21T15:09:05Z",
  "durationMs": 1850,
  "status": "ok",
  "tags": {}
}
```

**Response:** `202 Accepted`

---

## Data Store

The Telemetry Service does **not** use DynamoDB. Telemetry data (traces, metrics, operational events) has characteristics that purpose-built observability infrastructure handles better:

- High write throughput at low latency
- Time-series aggregation and rollup
- Trace correlation across spans
- Short retention with automatic expiry

**Production:** Route events to an OpenTelemetry-compatible backend — CloudWatch, Jaeger, Grafana Tempo, Datadog, or equivalent. The specific backend is an infrastructure decision, not a product decision.

**Local testing:** Run a local OpenTelemetry collector or use LocalStack's CloudWatch emulation. For Phase 1 and 2, telemetry events can simply be logged to stdout — the caller interface is stable even if the backend is a no-op.

```bash
# LocalStack CloudWatch (if using CloudWatch as the backend)
docker run -p 4566:4566 localstack/localstack
```

No repository pattern or DynamoDB table is needed for the Telemetry Service.

---

## Implementation Notes

- Telemetry submission is fire-and-forget with retry. Agent execution must never block on telemetry confirmation.
- The Telemetry Service routes data to underlying observability infrastructure (e.g. OpenTelemetry collector, Prometheus, Jaeger, or cloud-native equivalents) — the specific backend is an infrastructure concern, not a product concern.
- No business content (file contents, user prompts, code) should appear in telemetry payloads. Only metadata (counts, latencies, statuses, IDs).
- In Phase 1 and Phase 2, telemetry events can be logged locally or dropped. The interface should be defined so callers are compatible when the real service is introduced in Phase 3.
