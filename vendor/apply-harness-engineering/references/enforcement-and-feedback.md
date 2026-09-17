# Enforcement and Feedback Loops

Build feedback loops in stages. Prefer a small reliable loop over a broad noisy platform, and add a loop only when a requested outcome or repeated risk justifies its maintenance cost.

## Mechanize stable boundaries

Promote a rule from prose into code when at least one condition holds:

- it protects correctness, security, privacy, reliability, or data integrity;
- agents or people have repeated the same mistake;
- architectural drift compounds downstream work;
- the rule is deterministic enough to produce an actionable failure.

Enforce dependency direction, boundary validation, schema ownership, structured logging, generated-file provenance, or platform reliability only when relevant to the project. Keep implementation choices flexible inside the enforced boundary.

Stage new checks as `documented -> runnable -> report-only -> blocking`. Record baseline noise and remediation before making a check block CI. A local change normally needs only its focused check and the existing repository gate; missing release or production proof is not a local blocker when that scope was not requested.

## Expose runtime behavior

Choose the cheapest observable proof for each surface:

| Surface | Useful evidence |
| --- | --- |
| Library | Focused tests, examples, type checks, benchmarks |
| CLI | Exit code, stdout/stderr contract, fixture-driven invocation |
| API/service | Health check, request/response transcript, structured logs, traces |
| Web UI | Isolated boot, browser-driven flow, DOM state, screenshot or video, console/network logs |
| Mobile/desktop | Simulator or test device flow, accessibility tree, screenshot/video, application logs |
| Data pipeline | Fixture input, deterministic output, lineage, reconciliation metrics |

Prefer per-task or per-worktree isolation when concurrent agents can collide. Document startup, reset, seed, teardown, port allocation, and log locations.

Do not install OpenAI's example observability stack by default. Reuse the project's telemetry and add only the query paths an agent needs to diagnose and verify relevant behavior.

## Evaluate model and tool changes

When a repository invokes an AI runtime and its behavior changes, start with a small deterministic smoke evaluation. Add a broader representative suite only when the request, risk, or repository policy requires it. Compare one bounded change at a time on task success, required evidence, tool behavior, recovery, latency, tokens, cached tokens, and cost. Record the model/provider/snapshot and reasoning settings. Use Programmatic Tool Calling only for bounded deterministic processing, and use multi-agent routing only when work divides into independent branches with explicit synthesis, shared-state, retry, and approval boundaries. Keep these controls `N/A` for non-AI repositories.

## Capture human judgment

After a review correction, incident, or user-facing failure, classify the lesson:

- Update a canonical document for durable context or rationale.
- Add a fixture or test for reproducible behavior.
- Add a linter or structural test for a stable invariant.
- Add a runbook or recovery command for operational knowledge.
- Add a debt item when the fix is known but deliberately deferred.

Avoid copying entire review conversations. Preserve the decision, rationale, evidence, and affected boundary.

## Control entropy

When a repository has adopted a maintenance loop or explicitly requests one, run a lightweight recurring sweep for:

- stale or broken links and indexes;
- docs that disagree with commands or code;
- duplicated helpers or divergent patterns;
- growing files, modules, dependency edges, or flaky tests;
- unchecked completed plans and abandoned active plans;
- expired suppressions, temporary flags, or TODOs without owners;
- verification surfaces whose commands no longer run.

Prefer small targeted repairs. Update the quality score or debt tracker only when that authority exists or the request calls for it. Escalate broad refactors into an ExecPlan; do not create a backlog or maintenance system merely to record a small gap.

## Expand autonomy safely

Increase agent responsibility only when the previous level is observable and recoverable. A repository-scoped request is enough authority for ordinary reversible local work; it is not authority for external action:

1. Discover context and propose work.
2. Modify code and run focused checks.
3. Reproduce and verify end-to-end behavior.
4. Self-review and respond to review feedback.
5. Handle CI failures and safe retries.
6. Prepare external changes for approval.
7. Merge, release, or operate production only with explicit authority and project-specific gates.

High throughput does not justify weakening a gate when failures are expensive, irreversible, regulated, or difficult to detect.

## Keep optional certification disabled by default and block unsupported production claims

Installing this skill creates no watcher, CI job, schedule, or repair loop. After an explicit repository-scoped `$apply-harness-engineering` invocation, run the existing project-native gate manually before task completion when one exists; add a new gate only when the request or a concrete repeated risk requires it. Certification is not used by default: do not create HMAC evidence, a certification manifest, or an attestation overlay unless the user or repository policy explicitly requests it. Do not create or modify hosted CI workflow files unless the user explicitly requests CI automation; only then may the gate run on pull requests, pushes, and a bounded schedule. When the optional strict overlay is enabled, bind it to source commit `S` and verify it only from its clean direct-child attestation commit `A`. Expire strict attestation within seven days or sooner, and invalidate it on the next check when `HEAD` moves past `A` or a required command, coverage row, record, or declared applicability or authority input changes or fails. These local records support bounded repository-harness attestation but do not authenticate production authority; result codes belong in certification guidance.

Only an explicitly authorized repository-native trigger may repair safe repository-local drift within existing authority. It must fail closed and escalate when repair requires secrets, destructive actions, external writes, merge, release, deployment, production access, or product judgment. Refreshing and rechecking the evidence can restore strict attestation; it cannot establish production authority. Add `--require-production-attestation` only when that stricter result is explicitly required. The certification guidance defines unavailable-provider handling; a successful implementation must use an independently provisioned trust root and verify repository identity, production target, issuer, approval, rollback, artifact provenance, freshness, and revocation.
