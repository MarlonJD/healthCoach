---
name: apply-harness-engineering
description: Apply the smallest repository-scoped harness that helps an agent discover intent, make a change, observe behavior, and verify the result. Use when a request explicitly invokes harness engineering, an agent-readable repository, repository knowledge maps, docs/agent-harness, an optional AI-runtime/evaluation contract, or an existing harness lifecycle. Do not use for ordinary feature work, informal planning, generic CI/testing, documentation cleanup, or code review unless the request also asks to establish or use the repository harness.
---

# Apply Harness Engineering

Make the repository agent-discoverable and reliably verifiable with the smallest durable change set. Prefer reuse, consolidation, and deletion over new harness machinery.

Start with the smallest useful repository outcome. Reuse an existing clear route when it already works; otherwise make the smallest durable change that exposes the requested behavior and proportionate local proof. Add governance only when the request or an observed risk requires it.

## Installation and authority

- Installing this package only makes the skill available to Codex. It does not inspect, execute, modify, monitor, schedule, or certify a repository.
- Begin repository work only after an explicit `$apply-harness-engineering` request for a named repository. `agents/openai.yaml` disables implicit invocation.
- Treat the invoked package directory as the package authority. Existing or copied harness packages are migration inputs, not a newer contract.
- A repository-scoped request authorizes ordinary reversible local discovery, harness implementation, focused testing, and diff review. It does not grant secrets, production access, external writes, release, deployment, merge, destructive action, human approval, or product judgment.
- A later release or production approval is not a blocker for completing an in-scope local engineering change. Omit that layer or mark it `not run`; use `blocked` only when release or production is itself requested and cannot progress.
- Use `blocked` only when the requested in-scope outcome cannot progress because a named dependency, signal, decision, or permission is missing. Do not block on optional proof outside the request.
- Certification is not used by default. The native project gate and concise local evidence are the normal completion proof. The read-only `certify` command is an optional strict overlay for an explicitly requested bounded attestation; it never claims product deployment. See the certification guidance for its result codes. Add `--require-production-attestation` only for an explicit provider-backed production request; without such an integration it fails closed.

## Default fast path

1. Inspect the current tree, instructions, manifests, native commands, and working state. Preserve unrelated changes.
2. Run an adaptive audit when a baseline is useful. Adaptive findings describe gaps and do not by themselves block local work.
3. State the requested outcome and implement the smallest independently observable increment.
4. Run the focused check for the changed behavior, run the existing native repository gate when one is present, and review the diff.
5. Hand off the outcome, changed paths, exact commands/results, and anything `not run`, `blocked`, or approval-dependent.

The fast path does not create a new checker, ExecPlan, coverage matrix, evidence store, evaluation suite, CI workflow, maintenance schedule, pilot, backlog, or governance layer by default. Reuse an existing authority when one already exists. Add one of those artifacts only when the user asks for it, the repository already requires it, or a concrete repeated risk justifies it.

Zero-change adoption is valid when the repository already exposes the requested route and verification; report the observed state instead of creating files to signal completion.

## Choose a proportional operation

- **Audit:** inspect and report gaps without modifying the repository.
- **MVP scaffold:** preview the one-file `AGENTS.md` orientation with `scaffold` (default profile `mvp`). The helper remains read-only; tailor the fragment only after inspecting the target.
- **Adopt:** audit first, preserve existing authorities, and add only the missing route or command needed for the requested outcome.
- **Repair:** fix a named harness defect with the smallest reversible repository-local change.
- **Simplify:** an explicit named-repository request authorizes controlled reversible harness-surface merge or removal; it never authorizes product, domain, service, or database changes.
- **Govern:** add the governed exact-layout contract only when the request or a concrete repeated risk requires it.
- **Governed scaffold:** choose `governed` deliberately when the repository asks for the broader exact-layout contract. Replace placeholders with repository facts before claiming adoption.
- **ExecPlan lifecycle:** use an existing or new plan for cross-cutting, risky, multi-hour, uncertainty-heavy, or context-loss-sensitive work. Small, low-risk work need not create one. Plans are restartable current state, not execution transcripts; see [exec-plans.md](references/exec-plans.md).
- **Strict certification:** enter the optional convergence loop in [certification-and-convergence.md](references/certification-and-convergence.md) only when strict attestation or provider-backed production evidence is explicitly required.

## Interface boundary

Audit, adopt, repair, simplify, and govern are skill workflow modes: Codex interprets them from the request and repository context. They do not imply callable MCP or CLI tools. Some names overlap with helper commands, while others remain instruction-only.

The bundled helper is a separate deterministic, read-only interface. It exposes `audit`, `check`, `certify`, `scaffold`, `validate-plan`, and the explicit `simplify --preview` candidate report, plus top-level `--version`. `simplify --preview` never edits or removes files and does not authorize later writes; actual simplification follows the named-repository authority and safety rules below.

This is a standalone skill with instructions, references, assets, and optional scripts. It does not bundle or require an MCP server or plugin runtime. Add such an integration only for a separately requested tool/context use case.

## Test every addition

Before adding or retaining a harness artifact, decide whether an existing file or command already satisfies the need, which requested outcome or concrete current risk consumes it, and whether code, tests, Git, or an existing command can reproduce the information. A gate must catch a concrete defect rather than merely create evidence about evidence. Avoid artifacts that create more maintenance than value, and prefer reuse, merge, or deletion when that is smaller.

These are decision criteria, not a checklist, scorecard, or new repository artifact.

## Simplification boundary

An explicit `$apply-harness-engineering simplify` request for a named repository authorizes controlled merge or removal of repository-local harness artifacts within the requested scope after their consumers and current working state are inspected. Clean tracked harness artifacts are recoverable through Git and do not require per-file reapproval. Preserve unrelated or overlapping uncommitted work; do not delete untracked material that is not otherwise recoverable without separate confirmation or a safe backup.

Simplification may cover duplicate root or nested agent guidance, repository-local harness skills, harness documentation and authorities, managed plan lifecycle files, verification and completion rules, persisted harness evidence, proof-of-proof gates, and redundant harness maintenance. Before removal, identify the retained authority, search references and consumers, preserve unique active decisions, update affected routes in the same change, and avoid silently invalidating an explicitly required governed or certification contract. Review the diff and run the focused and existing native gates afterward.

This authority does not extend to product code, domain models, service architecture, databases, ordinary product tests, or unrelated documentation. Those changes require a separate feature or refactor request.

## Discover and classify

- Read applicable `AGENTS.override.md`, `AGENTS.md`, `CLAUDE.md`, `UI_RULES.md`, and repository-local skills before editing. Preserve the effective instruction route and unrelated work.
- Inspect project manifests, native test/build commands, existing docs, CI, architecture, and generated areas only as needed for the requested change.
- Treat the repository as a fresh adoption only when it has no explicit harness configuration or equivalent authority. Treat any existing artifact as partial/existing adoption and migrate incrementally; do not overwrite it with a wholesale scaffold.
- When the state is ambiguous, choose migration or repair rather than fresh adoption and report the ambiguity.
- Use `source-boundaries.md` for case-study applicability, `repository-contract.md` for artifact ownership, and `enforcement-and-feedback.md` for a concrete guardrail or recurring risk. Read [assessment-rubric.md](references/assessment-rubric.md) only when maturity assessment is requested.

## Apply and verify

- The bundled `scripts/harness.py` helper is read-only. Use `audit` for a non-blocking report, `check` for deterministic structural errors, `scaffold` for a manifest preview, `simplify --preview` for concrete reduction candidates, and `validate-plan` only for an adopted managed plan lifecycle. Never infer adoption from installation or a preview.
- Keep the root `AGENTS.md` concise: orientation, canonical routes, commands, constraints, and definition of done. The MVP fragment has no target-specific placeholders or links; an existing `AGENTS.md` is preserved.
- Prefer verification tiers: focused changed-behavior check; repository-native typecheck/test/build or equivalent when present; release or production smoke/deployment/health proof only when that scope is requested. Do not force release checks onto ordinary development.
- Record concise evidence as command, result, and short observation. Do not put raw proof JSONL, full logs, traces, screenshots, HTTP inventories, or repeated hashes in plans or normal handoffs. Keep durable release or regulated artifacts only when they are the requested deliverable.
- Preserve tenant isolation, authorization, secret and credential safety, migration integrity, customer/production data boundaries, and destructive-operation limits. Protect these directly with behavior checks rather than additional proof layers.
- Keep `verified locally`, `not run`, and `blocked` literal. Separate engineering completion from release and production state; omit out-of-scope layers, and report an in-scope layer as `not run` or `blocked` unless its own evidence was observed.

## Existing governed contract

When a repository deliberately adopts the governed contract:

- Keep one cross-repository owning plan. Child repositories carry only their local change and verification; do not copy the owning plan.
- Keep plans self-contained and restartable. Each step traces to the requested outcome or a concrete current risk. Plan size is a review signal, not a hard limit. Store short observations, not reproducible raw output.
- Use the repository's native checker as the normal gate. A coverage matrix, evaluation contract, evidence records, CI, maintenance loop, and approval workflow remain optional or repository-specific unless explicitly in scope.
- Use the target [model-and-agent runtime contract](assets/templates/project/docs/agent-harness/model-and-agent-runtime.md) and [evaluation contract](assets/templates/project/docs/agent-harness/evals.md) only when an AI runtime change or explicit evaluation request makes them applicable.

## Optional strict certification

For an explicit strict request, bind v2 HMAC-consistent records and the manifest to concrete repository and harness-target identities, source commit `S`, and a clean direct-child attestation commit `A`; then run the read-only `certify` command from trusted source-control context. A successful result means only that the bounded repository-harness attestation passed. It does not grant release, deployment, production, merge, or human authority. Use `--require-production-attestation` only when an independently provisioned provider verifier is required; report the verifier's failure result when it is unavailable.

## Report

Lead with the delivered behavior or artifact. Name changed paths, focused and repository checks with their results, and separate `not run`, `blocked`, release, production, and approval-dependent work. State only evidence actually observed. The next step should be the smallest remaining improvement that materially reduces a current risk or user-facing gap.
