# Verification Matrix

Map a changed surface to the smallest reliable proof. Use exact repository commands and observable signals; do not invent passing counts or require a higher tier when it is out of scope.

## Verification tiers

| Tier | Use when | Minimum evidence | Completion effect |
| --- | --- | --- | --- |
| Focused | Every changed behavior with an available check | Focused test, lint, fixture, or direct behavior observation and its result | Required for the changed surface when a check exists |
| Repository | The repository has an applicable native gate such as typecheck, test, or build | Existing native command and short result | Run for ordinary engineering completion when present |
| Release | Packaging, publishing, deployment, or release behavior is requested | Release smoke, artifact readback, deployment, or health result | Does not block local engineering when release is out of scope |
| Production | Customer or production behavior and authority are explicitly in scope | Production smoke/health, approval, rollback, and target evidence | Requires the relevant authority; never infer from local checks |

## Surface mapping

| Change surface | Focused check | Repository check | Release/production check | Evidence and fallback |
| --- | --- | --- | --- | --- |
| Documentation only | Link or Markdown check | Existing docs gate, if present | N/A unless published docs are requested | Links/examples resolve; record `not run` when no checker exists |
| Library or core logic | Focused unit or behavior test | Existing full test/type/build gate | N/A unless release behavior changes | Fixture output and command result |
| API or service | Focused request/response test | Existing integration or service gate | Smoke/health only when requested | Response and concise observation; do not require logs/traces by default |
| Web UI | Focused component or interaction test | Existing browser/e2e gate | Deployed smoke only when requested | Visible UI state and result; use screenshots only when they are the requested artifact |
| Mobile or desktop | Focused unit/UI test | Existing simulator/device gate | Release/device proof only when requested | Observable UI/accessibility state |
| Data or migration | Focused fixture or dry run | Existing reconciliation/rollback gate | Production migration proof only when requested | Invariant and rollback result |
| CI or build system | Config/parser check | Representative native job when applicable | Release artifact check only when requested | Expected command graph or artifact |
| Security-sensitive boundary | Focused regression or threat-specific test | Existing security gate | Production/security approval only when requested | Reproduction fails after the fix; escalate missing authority |
| Model/provider/runtime configuration | Config/schema or focused smoke when applicable | Existing runtime gate | Provider/production check only when requested | Snapshot, settings, state strategy, and result |
| Agent evaluation suite | Deterministic smoke when explicitly applicable | Representative evaluation only when requested | N/A unless production behavior is in scope | Task outcome and concise result reference |
| Tool/MCP permissions and side effects | Policy or fixture check | Existing tool validation | External-action verification only when requested | Scope, approval, retry, and error behavior |
| Long-running state, compaction, and resume | Replay smoke when applicable | Recovery test only when requested | N/A unless deployed state is in scope | IDs, completed actions, blockers, and next goal |
| Programmatic or multi-agent routing | Route-selection smoke when applicable | Bounded comparison only when requested | N/A unless an external route is in scope | Allowed tools, concurrency, synthesis, and escalation |
| Repository harness authority and maintenance | Existing native harness gate | Broader local check only when applicable | Strict certification or production proof only when explicitly requested | Keep normal evidence concise and local |

## Rules

- Start with focused verification, then run the applicable repository tier. Add release or production tiers only when that outcome is requested or an existing repository gate requires them.
- Use `verified locally`, `not run`, and `blocked` literally, with the reason for `not run` or `blocked`.
- Treat flaky, unavailable, or untrusted checks as a gap or blocker for the tier that is in scope, not as a pass.
- Preserve tenant isolation, authorization, secret safety, migration integrity, customer/production data boundaries, and destructive-operation limits with direct behavior checks.
