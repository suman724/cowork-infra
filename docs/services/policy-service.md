# Policy Service — Detailed Design

**Phase:** 1 (MVP)
**Repo:** `cowork-policy-service`
**Bounded Context:** PolicyGuardrails

---

## Purpose

The Policy Service generates policy bundles that define what a session is allowed to do. It is the authoritative source for capability rules, approval requirements, LLM guardrail configuration, and token budgets. It is called by the Session Service at session creation — it does not communicate directly with desktop clients.

---

## Responsibilities

- Generate policy bundles per tenant, user, and session
- Define and manage capability rules (which tools are allowed, with what scope)
- Define approval requirements per capability
- Define LLM policy (allowed models, token limits)
- Manage policy bundle versioning and expiry
- Provide policy schema versioning so clients can detect incompatibility

---

## Relationships

| Called by | Purpose |
|-----------|---------|
| Session Service | Fetch policy bundle at session creation and resume |

The Policy Service has no direct communication with the Local Agent Host or Desktop App. All policy reaches the client through the Session Service.

---

## Policy Bundle

A policy bundle is a JSON document returned to the Session Service, which passes it to the Local Agent Host. Transit integrity is guaranteed by HTTPS — no additional signing is applied.

### Structure

```json
{
  "policyBundleVersion": "2026-02-21.a1b2c3d4",
  "schemaVersion": "1.0",
  "tenantId": "tenant_abc",
  "userId": "user_123",
  "sessionId": "sess_789",
  "expiresAt": "2026-02-21T18:30:00Z",
  "capabilities": [
    {
      "name": "File.Read",
      "allowedPaths": [
        "/Users/suman/projects/demo"
      ],
      "requiresApproval": false
    },
    {
      "name": "Shell.Exec",
      "allowedCommands": ["git", "python", "npm", "pytest"],
      "requiresApproval": true,
      "approvalRuleId": "approval_shell_exec"
    }
  ],
  "llmPolicy": {
    "allowedModels": ["claude-sonnet-4-6"],
    "maxInputTokens": 200000,
    "maxOutputTokens": 16384,
    "maxSessionTokens": 1000000
  },
  "approvalRules": [
    {
      "approvalRuleId": "approval_shell_exec",
      "title": "Local command execution",
      "description": "User approval required for shell commands"
    }
  ]
}
```

### Client-side Validation

After receiving the bundle via the Session Service, the Local Agent Host must verify:
- `expiresAt` is in the future — reject if expired
- `sessionId` matches the current session — reject if mismatched
- `schemaVersion` is supported — reject if incompatible

If any check fails the session must not start.

---

## Capability Model

Capabilities define what the agent is permitted to do. Each capability has a name, scope constraints, and an approval requirement.

### Capability Table

| Capability | Description | Typical Scope | Approval Required | Enforced By |
|---|---|---|---|---|
| `File.Read` | Read file contents | Allowed path prefixes | Usually no | Local Policy Enforcer, Local Tool Runtime |
| `File.Write` | Create or modify files | Allowed path prefixes | Sometimes | Local Policy Enforcer, Local Tool Runtime |
| `File.Delete` | Delete files | Allowed path prefixes | Usually yes | Local Policy Enforcer, Local Tool Runtime |
| `Shell.Exec` | Run local commands | Command allowlist, cwd paths | Often yes | Local Policy Enforcer, Local Tool Runtime |
| `Network.Http` | Outbound HTTP requests | Domain allowlist | Sometimes | Local Policy Enforcer, Local Tool Runtime |
| `Workspace.Upload` | Upload artifacts | Workspace id, size limits | Usually no | Local Agent Host |
| `BackendTool.Invoke` | Invoke remote-only tools | Tool names | Sometimes | Local Agent Host, Policy Service |
| `LLM.Call` | Call LLM Gateway | Model allowlist, token budgets | No | LLM Gateway, Policy Service |
| `Search.Web` | Web search | — | No | Local Tool Runtime |
| `Code.Execute` | Execute Python code | Language allowlist, timeout, network flag | Usually yes | Local Policy Enforcer, Local Tool Runtime |
| `Browser.Navigate` | Navigate browser to URLs | Domain allowlist/blocklist | First visit to new domain | Local Policy Enforcer, Local Tool Runtime |
| `Browser.Interact` | Click, type, select, scroll in browser | — | Sensitive elements only | Local Tool Runtime (SensitiveDetector) |
| `Browser.Extract` | Read page content and take screenshots | — | No | Local Tool Runtime |
| `Browser.Submit` | Submit forms in browser | — | Always | Local Tool Runtime |
| `Browser.Download` | Download files via browser | Allowed paths, file size limit | Always | Local Policy Enforcer, Local Tool Runtime |

### Scope Fields

Capability entries can include any of these scope constraints:

| Field | Applies to |
|-------|-----------|
| `allowedPaths` | File.Read, File.Write, File.Delete, Browser.Download |
| `blockedPaths` | File.Read, File.Write, File.Delete |
| `allowedCommands` | Shell.Exec |
| `blockedCommands` | Shell.Exec |
| `allowedDomains` | Network.Http, Browser.Navigate |
| `blockedDomains` | Browser.Navigate |
| `maxFileSizeBytes` | File.Read, File.Write, Workspace.Upload, Browser.Download |
| `maxOutputBytes` | Shell.Exec, tool outputs |
| `requiresApproval` | All capabilities |
| `approvalRuleId` | All capabilities where requiresApproval is true |
| `allowedLanguages` | Code.Execute |
| `maxExecutionTimeSeconds` | Code.Execute |
| `allowCodeNetwork` | Code.Execute |
| `browserIdleTimeoutSeconds` | Browser.* (default: 600) |
| `browserViewportWidth` | Browser.* (default: 1280) |
| `browserViewportHeight` | Browser.* (default: 800) |

> **Workspace path enrichment:** The Policy Service does **not** inject workspace-specific paths into `allowedPaths`. That is the responsibility of the Local Agent Host, which appends the session's workspace directory to file-operation capabilities after receiving the policy bundle. This keeps the Policy Service workspace-agnostic and reusable across desktop and backend execution environments. See [components/local-agent-host.md](../components/local-agent-host.md), Section 8.1.

---

## LLM Policy

The `llmPolicy` block controls what the agent is allowed to send to and receive from the LLM Gateway:

| Field | Description |
|-------|-------------|
| `allowedModels` | List of model IDs the agent may request |
| `maxInputTokens` | Maximum tokens in a single LLM request |
| `maxOutputTokens` | Maximum tokens in a single LLM response |
| `maxSessionTokens` | Total token budget across the entire session |

---

## Policy Bundle Versioning and Expiry

- `policyBundleVersion` — a dated version string (e.g. `2026-02-21.a1b2c3d4` — ISO date + 8-char hex UUID suffix) identifying when this policy was generated
- `schemaVersion` — the schema version of the bundle format, used by the client for compatibility checks
- `expiresAt` — bundles are short-lived; the client must not use an expired bundle. On expiry, the session must end or re-authenticate.
- Policy bundles are not refreshed mid-session in Phase 1. Policy revocation mid-session is a Phase 3 feature.

---

## Data Store

### Phase 1 — configuration files

In Phase 1 there is no per-tenant policy authoring. Policy rules are defined as static configuration (JSON or YAML files) loaded at service startup. The Policy Service reads these files and assembles bundles on demand — no database is required.

This keeps Phase 1 simple: no table to manage, no migration, and policies can be changed by deploying updated config.

### Phase 3 — DynamoDB for per-tenant policy

When per-tenant policy authoring is introduced in Phase 3, policies move into DynamoDB.

**Table:** `{env}-policies`

| Key | Value |
|-----|-------|
| Partition key | `tenantId` (String) |
| Sort key | `policyVersion` (String) — e.g. `2026-02-21.a1b2c3d4` |

| GSI | Partition key | Sort key | Use |
|-----|--------------|----------|-----|
| `tenantId-active-index` | `tenantId` | `isActive` | Fetch the current active policy for a tenant |

Stored attributes: `tenantId`, `policyVersion`, `isActive`, `capabilities`, `llmPolicy`, `approvalRules`, `schemaVersion`, `createdAt`, `createdBy`

### Testing (Phase 3 only)

| Tier | Infrastructure |
|------|---------------|
| Unit tests | `InMemoryPolicyRepository` — no infrastructure needed |
| Service tests | DynamoDB Local: `docker run -p 8000:8000 amazon/dynamodb-local` |
| Integration tests | LocalStack: `docker run -p 4566:4566 localstack/localstack` |

---

## Internal API (called by Session Service only)

### GET /policy-bundles — Generate Policy Bundle

```
GET /policy-bundles?tenantId=tenant_abc&userId=user_123&sessionId=sess_789&capabilities=File.Read,Shell.Exec,...
```

**Response:** Policy bundle JSON as shown above.

This endpoint is internal — not exposed to desktop clients.

---

## Observability

### Request ID Middleware

Every inbound request is assigned a unique `X-Request-ID` (UUID v4). If the caller (Session Service) provides an `X-Request-ID` header, the service propagates it; otherwise it generates a new one. The ID is:

- Bound to `structlog` context via `structlog.contextvars.bind_contextvars(request_id=...)` so all log lines during that request include it
- Returned in the `X-Request-ID` response header

### Structured Logging

All log output is JSON-formatted via `structlog` with the following processors: `merge_contextvars`, `add_log_level`, `TimeStamper(fmt="iso")`, `StackInfoRenderer`, `format_exc_info`, `JSONRenderer`.

Every request logs on completion:
```json
{"event": "request_completed", "method": "GET", "path": "/policy-bundles", "status_code": 200, "duration_ms": 12.1, "request_id": "abc-123", "level": "info", "timestamp": "..."}
```
