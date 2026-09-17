# Agent Harness

This directory is the progressive-disclosure entry point for capabilities that help coding agents work reliably in this repository.

Its presence records an explicit governed repository adoption; installing the external skill neither creates this directory nor runs any workflow. The repository's existing native gate owns local task verification when one exists. Hosted workflows and schedules are optional and require an explicit user request.

Root [`AGENTS.md`](../../AGENTS.md) is the canonical instruction map. If root `AGENTS.override.md` exists, Codex loads that higher-precedence entry point instead, and it must preserve routes to the same authorities before the effective `project_doc_max_bytes` cutoff. Codex defaults that budget to 32 KiB and combines project instructions from root toward the working directory. `config.json` declares downstream authorities but does not make an arbitrary instruction filename auto-loadable or change Codex configuration.

## Capability map

| Need | Source of truth |
| --- | --- |
| Available commands and tools | [`registry.md`](registry.md) |
| Adopted authority paths | [`config.json`](config.json) |
| End-to-end human/agent workflow | [`operating-loop.md`](operating-loop.md) |
| Local isolation and runtime observability | [`environment-contract.md`](environment-contract.md) |
| Model, tool, state, and multi-agent runtime contract | [`model-and-agent-runtime.md`](model-and-agent-runtime.md) |
| Representative agent evaluations and model migration evidence | [`evals.md`](evals.md) |
| Required completion evidence | [`output-contract.md`](output-contract.md) |
| Change-to-verification mapping | [`verification-matrix.md`](verification-matrix.md) |
| Recurring drift cleanup | [`entropy-cleanup-checklist.md`](entropy-cleanup-checklist.md) |
| Source-principle coverage | [`coverage-matrix.md`](coverage-matrix.md) |
| Long-running work | [`../exec-plans/index.md`](../exec-plans/index.md) |

Strict certification is not used by default. The native project gate and concise local evidence are the completion proof. Add the optional `certification.md`, `certification.json`, and evidence overlay only when a user or repository policy explicitly requests strict attestation.

## Route by task

| Task | Read first | Continue with |
| --- | --- | --- |
| Understand the repository | [`../../AGENTS.md`](../../AGENTS.md) | [`../../ARCHITECTURE.md`](../../ARCHITECTURE.md) and [`../index.md`](../index.md) |
| Start or resume complex work | [`../PLANS.md`](../PLANS.md) | [`../exec-plans/index.md`](../exec-plans/index.md) and the matching active plan |
| Implement and verify a change | [`operating-loop.md`](operating-loop.md) | [`registry.md`](registry.md), [`verification-matrix.md`](verification-matrix.md), and [`output-contract.md`](output-contract.md) |
| Reproduce UI, API, or runtime behavior | [`environment-contract.md`](environment-contract.md) | The relevant capability in [`registry.md`](registry.md) and row in [`verification-matrix.md`](verification-matrix.md) |
| Change an architecture boundary | [`../../ARCHITECTURE.md`](../../ARCHITECTURE.md) | [`../design-docs/index.md`](../design-docs/index.md) and an ExecPlan when cross-cutting |
| Handle review feedback or a recurring failure | [`output-contract.md`](output-contract.md) | Add context, a test, an enforceable rule, or a debt item according to the evidence |
| Sweep drift and technical debt | [`entropy-cleanup-checklist.md`](entropy-cleanup-checklist.md) | [`../exec-plans/tech-debt-tracker.md`](../exec-plans/tech-debt-tracker.md) or a new active plan |
| Prepare security, reliability, release, or external work | [`output-contract.md`](output-contract.md) | [`../SECURITY.md`](../SECURITY.md), [`../RELIABILITY.md`](../RELIABILITY.md), and applicable approval rules |
| Audit whether the governed contract is complete | [`coverage-matrix.md`](coverage-matrix.md) | Verify every canonical row with a repository artifact and observed evidence |
| Run strict harness attestation | Optional `certification.md` and `certification.json` | Not used by default. Add the optional overlay only when strict attestation is explicitly required; add `--require-production-attestation` only when independent production evidence is explicitly in scope |

## Operating loop

Follow this loop: discover intent, select or create a plan when continuity is needed, implement an observable increment, run the mapped verification, review concise evidence, and update only the durable knowledge that changed. Escalate judgment, destructive actions, external writes, releases, and production operations according to repository and user authority.

## Current maturity

| Dimension | State | Evidence | Next useful increment |
| --- | --- | --- | --- |
| Knowledge routing | <!-- TODO(harness): discoverable/repeatable/enforced/self-maintaining --> | <!-- link or observation --> | <!-- bounded improvement --> |
| Planning continuity | <!-- TODO(harness) --> | <!-- evidence --> | <!-- improvement --> |
| Executable verification | <!-- TODO(harness) --> | <!-- evidence --> | <!-- improvement --> |
| Agent-readable runtime | <!-- TODO(harness) --> | <!-- evidence or N/A --> | <!-- improvement --> |
| Mechanical boundaries | <!-- TODO(harness) --> | <!-- evidence --> | <!-- improvement --> |
| Entropy control | <!-- TODO(harness) --> | <!-- evidence --> | <!-- improvement --> |
| Safe autonomy | <!-- TODO(harness) --> | <!-- evidence --> | <!-- improvement --> |
| AI runtime and evaluations (when applicable) | <!-- TODO(harness): N/A for non-AI repositories --> | <!-- model/tool/state/eval evidence --> | <!-- bounded improvement --> |

Do not infer maturity from documents, templates, or skill installation alone. Require a repeatable command or observable result for repeatable and higher states.
