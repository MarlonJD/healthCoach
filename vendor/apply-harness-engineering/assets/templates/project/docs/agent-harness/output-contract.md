# Agent Output Contract

Use this contract for implementation handoffs. More local or risk-specific instructions may add requirements.

## Required outcome

1. Lead with the behavior or artifact delivered.
2. Name the material files or systems changed.
3. Report exact verification commands and scoped outcomes.
4. Separate remaining gaps, deferred debt, and approval-dependent work.
5. Separate engineering completion from release and production state. State destructive, external, release, production, or real-device work only when it actually occurred with the required authority.
6. When an AI runtime is applicable, include the model/provider/snapshot, runtime route, evaluation command or replay ID, and measured evidence needed to reproduce the result.

## Evidence labels

| Label | Meaning |
| --- | --- |
| `verified locally` | The stated command or behavior was exercised in the local task environment. |
| `not run` | The check was intentionally not executed; include the reason. |
| `blocked` | A named condition prevented required progress or verification. |

## Handoff shape

- Outcome: <!-- TODO(harness): project-specific expectation -->
- Changed: <!-- paths or surfaces -->
- Engineering verification: <!-- focused command/result and existing native gate, or not run/blocked with reason -->
- Release state: <!-- verified locally, not run, or blocked; include only if in scope -->
- Production state: <!-- verified locally, not run, or blocked; include only if in scope -->
- Remaining work: <!-- explicit debt, follow-up, approval, or none -->

For an AI-runtime change, also report the model/runtime baseline, focused evaluation result, tool/state evidence, and any untested route as `not run` or `blocked`.

<!-- TODO(harness): Add repository-specific generated-file, migration, security, accessibility, observability, release, or reviewer evidence requirements. -->
