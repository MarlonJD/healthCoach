# Human and Agent Operating Loop

Use this loop to turn human intent into a proportionate, verified repository change. Keep authority boundaries explicit at every stage.

Run this loop only after an explicit repository-scoped request or an already-authorized repository-native trigger. Installing the external skill does not start the loop, grant authority, or schedule future runs.

## Responsibilities

| Role | Owns |
| --- | --- |
| Human | Priorities, user intent, risk tolerance, product judgment, exceptional approvals, and final acceptance where required |
| Agent | Repository discovery, planning, implementation, local verification, self-review, evidence capture, and durable documentation updates within granted authority; explicit blockers when authority is missing |
| Mechanical harness | Existing deterministic setup, tests, lint, structural boundaries, and observable runtime signals |

<!-- TODO(harness): Name repository-specific roles and decisions that always require human judgment. -->

## Task loop

1. Read the applicable instructions and authoritative repository knowledge.
2. Inspect the current tree and working state; preserve unrelated changes.
3. Reproduce the reported behavior or establish a measurable baseline when applicable.
4. Create or resume an ExecPlan only when the work is cross-cutting, risky, long-running, uncertainty-heavy, or likely to outlive the current context.
5. Implement the smallest independently observable increment.
6. Run the focused check, then the existing repository-native gate when one is present. Add release or production checks only when that scope is requested.
7. Observe user-visible or operational behavior when the changed surface needs it.
8. Review the diff, failure modes, and recovery path. Keep evidence to the command, result, and short observation needed to reproduce the outcome.
9. Request additional review only when the risk or repository policy justifies it; address findings and repeat relevant verification.
10. Update only the canonical document or plan that changed. Do not create a new tracker, evidence store, or governance layer merely to close a small task.
11. Hand off with literal `verified locally`, `not run`, or `blocked` labels and separate engineering, release, and production state.

## AI-runtime loop (when applicable)

When the repository invokes a model or agent runtime and that surface changes, read [`model-and-agent-runtime.md`](model-and-agent-runtime.md) and [`evals.md`](evals.md). Use a small focused smoke or existing project evaluation appropriate to the change; broader comparison is optional unless the repository or request requires it. Keep direct calls, Programmatic Tool Calling, and multi-agent routing distinct.

## Review policy decision

Request independent or human review only for the repository's stated risk and approval boundaries. Do not make a reviewer, sign-off, or repeated evidence artifact a universal completion gate. Record the repository's independent decision:

| Change surface | Local self-review | Independent or cloud review | Stop condition | Human review required? | Failure/escalation path | Owner and evidence |
| --- | --- | --- | --- | --- | --- | --- |
| <!-- TODO(harness): surface or N/A --> | <!-- command/process --> | <!-- reviewer/process or N/A --> | <!-- explicit condition --> | <!-- always/risk-based/optional --> | <!-- action --> | <!-- role plus exercised trace --> |

## Review and recovery loop

| Signal | Immediate response | Durable feedback |
| --- | --- | --- |
| Focused test failure | Diagnose and correct the current increment | Add or improve the reproducing fixture when it exposes a gap |
| CI-only failure | Reproduce the job or isolate the environment difference | Make the command and environment discoverable |
| Repeated review finding | Fix the current change and inspect nearby occurrences | Promote a stable rule into docs, a test, linter, or structural check |
| User-facing defect | Capture a reproducible path and validate the repair | Add acceptance evidence and update product or reliability knowledge |
| Agent cannot proceed | Identify the missing tool, context, signal, or permission | Improve the registry/harness or escalate the judgment boundary |
| Harness gate or maintenance failure | Repair only safe explicitly authorized drift and keep the native gate failed until it passes | Add a reproducer or durable rule only when the failure exposes a repeatable risk |

## Escalation boundaries

<!-- TODO(harness): Define project-specific escalation for destructive changes, migrations, secrets, security findings, external writes, merge, release, deployment, and production operations. -->

Never interpret continuous execution as broader authority. Continue through ordinary milestones, but stop when a required in-scope judgment or approval lies outside the granted scope; later release or production approval does not block local engineering.
