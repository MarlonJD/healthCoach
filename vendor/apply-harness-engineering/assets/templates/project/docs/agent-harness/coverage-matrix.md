# Harness Engineering Coverage Matrix

Use this matrix to prove that the repository implements every applicable harness-engineering capability. A document name alone is not evidence.

## Status contract

- `verified`: the artifact and behavior were exercised with recorded evidence. When the optional strict attestation profile is enabled, link the status cell to exactly one fresh HMAC-consistent v2 evidence record bound to the source commit, repository identity, and stable harness evaluation target. This is not external authentication.
- `candidate`: the proposed implementation exists but has not been exercised.
- `blocked`: a named dependency or authority prevents completion.
- `N/A`: the capability is genuinely irrelevant, with a written reason. When strict attestation is enabled, link the status cell to exactly one fresh HMAC-consistent v2 applicability record.

## Coverage

| Source principle or capability | Repository implementation | Required evidence | Status and reason |
| --- | --- | --- | --- |
| Humans set intent; agents execute within authority | [`operating-loop.md`](operating-loop.md) and product sources | Named human judgment boundaries and one completed task trace | <!-- TODO(harness) --> |
| Break large goals into reusable design, code, review, test, and verification steps | [`../PLANS.md`](../PLANS.md) and active ExecPlans | A restartable plan with independently verified milestones | <!-- TODO(harness) --> |
| Agents can self-review and respond to feedback | [`operating-loop.md`](operating-loop.md) and [`output-contract.md`](output-contract.md) | Review command/process plus resolved finding evidence | <!-- TODO(harness) --> |
| Application behavior is directly readable | [`environment-contract.md`](environment-contract.md) | Reproduced UI/API/CLI behavior with observed before/after evidence | <!-- TODO(harness) --> |
| Logs, metrics, and traces are queryable when relevant | [`environment-contract.md`](environment-contract.md) and [`registry.md`](registry.md) | Project-appropriate query and correlated result, or justified N/A | <!-- TODO(harness) --> |
| Repository knowledge is the durable record | [`../index.md`](../index.md) | Canonical links resolve and key decisions do not depend on hidden conversation context | <!-- TODO(harness) --> |
| Repository tools and authorized work context are directly invocable | [`registry.md`](registry.md) | A repository-local script/skill and relevant source-control, review, or CI query can be discovered and exercised, or each is justified N/A | <!-- TODO(harness) --> |
| Dependencies and abstractions remain agent-legible | [`../../ARCHITECTURE.md`](../../ARCHITECTURE.md), [`registry.md`](registry.md), and checked-in references or fixtures | Important upstream behavior has a discoverable contract and executable proof; any local reimplementation has a recorded tradeoff | <!-- TODO(harness) --> |
| `AGENTS.md` is a concise map, not an encyclopedia | [`../../AGENTS.md`](../../AGENTS.md) | Scannable canonical routes before the effective byte cutoff plus root-to-working-directory instruction-chain evidence where nested files exist | <!-- TODO(harness) --> |
| Plans are versioned living artifacts | [`../PLANS.md`](../PLANS.md) and [`../exec-plans/index.md`](../exec-plans/index.md) | Active/completed lifecycle and a plan with current progress/decisions/evidence | <!-- TODO(harness) --> |
| Architecture and critical taste boundaries are mechanical | [`../../ARCHITECTURE.md`](../../ARCHITECTURE.md) and project-native checks | A documented invariant with an actionable failing and passing check | <!-- TODO(harness) --> |
| Local autonomy exists inside enforced central boundaries | [`operating-loop.md`](operating-loop.md) and repository instructions | Clear allowed actions, escalation gates, and recovery path | <!-- TODO(harness) --> |
| Verification proves working behavior, not only code changes | [`verification-matrix.md`](verification-matrix.md) | Exact commands plus user-visible or operational acceptance evidence | <!-- TODO(harness) --> |
| Failures and review judgment feed back into the harness | [`operating-loop.md`](operating-loop.md) | One example promoted to docs, a test, linter, runbook, or debt item | <!-- TODO(harness) --> |
| Entropy and technical debt are continuously controlled | [`entropy-cleanup-checklist.md`](entropy-cleanup-checklist.md) and [`../exec-plans/tech-debt-tracker.md`](../exec-plans/tech-debt-tracker.md) | Dated sweep evidence and bounded follow-up | <!-- TODO(harness) --> |
| Autonomy increases only after test, review, recovery, and escalation loops exist | [`operating-loop.md`](operating-loop.md), [`registry.md`](registry.md), and [`output-contract.md`](output-contract.md) | Evidence for the granted level and explicitly unavailable higher levels | <!-- TODO(harness) --> |
| Merge throughput policy matches project risk | CI/review policy and [`../SECURITY.md`](../SECURITY.md)/[`../RELIABILITY.md`](../RELIABILITY.md) | Project-specific gate rationale; no copied low-blocking default | <!-- TODO(harness) --> |
| Release, deployment, and production actions require repository-local authority | [`operating-loop.md`](operating-loop.md), [`output-contract.md`](output-contract.md), and approval policy | An exercised repository-local gate that denies unauthorized actions, plus documented approval, escalation, and rollback paths; or a fresh justified N/A when the repository has no such action. When `--require-production-attestation` is requested, additionally require provider-authenticated authority, rollback, and audit evidence and do not use N/A | <!-- TODO(harness) --> |
| Repository-specific OpenAI examples are treated as options, not universal mandates | Case-study decision ledger below and architectural decisions | Every listed choice has its own status and project-specific reason | <!-- TODO(harness) --> |

## Case-study decision ledger

These rows prevent OpenAI's implementation choices from being either copied blindly or skipped silently. Give each choice an independent status and reason.

| OpenAI case-study choice | Local decision or implementation | Required evidence | Status and reason |
| --- | --- | --- | --- |
| Zero human-authored code as an operating constraint | <!-- TODO(harness): adopt, reject, or limit --> | Explicit responsibility model; if adopted, provenance covers product code, tests, CI, documentation, internal tools, evaluation harnesses, review artifacts, repository scripts, release tooling, and dashboard definitions | <!-- TODO(harness) --> |
| Reported repository size, pull-request throughput, elapsed-time speedup, and long agent-run duration as targets | <!-- TODO(harness): normally context-only/N/A --> | Project goal, if any, uses outcome and quality measures rather than copied vanity or duration metrics | <!-- TODO(harness) --> |
| Local and cloud agent review loops continue until reviewers are satisfied while human review is optional | [`operating-loop.md`](operating-loop.md) and review policy | Project-specific reviewer independence, stopping condition, human gate, failure handling, and one exercised review trace | <!-- TODO(harness) --> |
| Per-worktree application isolation | [`environment-contract.md`](environment-contract.md) | Collision-free setup/reset/teardown proof or a safer local isolation model | <!-- TODO(harness) --> |
| Per-worktree observability stack | [`environment-contract.md`](environment-contract.md) | Isolated signal correlation and cleanup proof, shared-stack alternative, or justified N/A | <!-- TODO(harness) --> |
| Chrome DevTools Protocol for UI control | [`environment-contract.md`](environment-contract.md) and [`verification-matrix.md`](verification-matrix.md) | Browser-flow evidence through the selected project tool, or justified N/A | <!-- TODO(harness) --> |
| Victoria Logs, Metrics, and Traces with LogQL/PromQL/TraceQL | [`environment-contract.md`](environment-contract.md) and [`registry.md`](registry.md) | Queries through the project's actual telemetry system, or justified N/A | <!-- TODO(harness) --> |
| OpenAI's fixed layered domain architecture | Configured architecture authority and project-native checks | Project-specific dependency model and executable boundary evidence; do not copy layer names by default | <!-- TODO(harness) --> |
| Reimplementing upstream dependency behavior locally | Configured architecture authority, decision record, and tests | Tradeoff covering inspectability, maintenance, security, licensing, and compatibility | <!-- TODO(harness) --> |
| Minimally blocking merge gates and short-lived pull requests | CI/review policy and risk documents | Project-specific failure cost, recovery, and follow-up rationale | <!-- TODO(harness) --> |
| Scheduled Codex documentation gardening and quality-scoring agents open targeted repair pull requests | [`entropy-cleanup-checklist.md`](entropy-cleanup-checklist.md), quality/debt records, and external-write policy | Cadence, read/write authority, review/merge gate, rollback, and one observed maintenance trace; otherwise justified N/A | <!-- TODO(harness) --> |
| Automated merge and agent-authored release tooling | CI/review policy, release tooling, and [`operating-loop.md`](operating-loop.md) | Project-specific automation and gate rationale; do not infer deployment or production authority | <!-- TODO(harness) --> |

Review this matrix after major architecture, CI, runtime, or agent-workflow changes. Do not mark the harness complete while an applicable row is missing evidence.

## Optional AI-runtime extension

When the repository invokes a model or agent runtime, use [`model-and-agent-runtime.md`](model-and-agent-runtime.md) and [`evals.md`](evals.md) as additional authorities. Keep these checks outside the canonical 31-row source/case-study inventory so a non-AI repository can record a justified `N/A` without pretending to exercise model behavior. The extension should cover model/provider/snapshot identity, reasoning and state settings, tool/MCP permissions, prompt-injection and data boundaries, PTC/multi-agent routing, representative task evals, and quality/latency/token/cost evidence.
