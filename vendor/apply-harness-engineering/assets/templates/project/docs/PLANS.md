# Execution Plans (ExecPlans)

Use a plan when work is cross-cutting, risky, multi-hour, uncertainty-heavy, or likely to cross a context or contributor boundary. A small, low-risk change can use the normal task handoff without creating a plan.

## Purpose and shape

An ExecPlan is a restartable current-state record. A contributor should be able to resume from the file and current tree without replaying a chat or reading an execution transcript. Keep the purpose, current progress, decisions, next action, validation, recovery, and remaining work accurate.

Plan size is a review signal, not a hard limit. Remove stale detail and repeated facts when they stop helping resume the work. Every required step must trace to the requested outcome or a concrete current risk; do not add steps only to produce more process or evidence.

Keep evidence concise: command, result, and short observation. Do not paste raw logs, traces, JSONL proof, screenshots, HTTP inventories, or reproducible output into the plan. Link a durable release or regulated artifact only when it is the requested deliverable.

## Ownership and lifecycle

- Keep one owning plan for a cross-repository outcome. Child repositories carry only their local change and verification; do not copy the owning plan into each repository.
- Resolve `exec_plan_index` from `agent-harness/config.json` when this managed lifecycle is adopted. Its sibling `active/` and `completed/` directories are the lifecycle; preserve an existing repository-native lifecycle when it is not compatible.
- Keep `Progress`, `Surprises & Discoveries`, `Decision Log`, and `Outcomes & Retrospective` current when a plan exists.
- Keep an unresolved plan active when an in-scope outcome is blocked. Release, production, or external approval work that is out of scope is recorded separately and does not block local engineering completion.
- Move a plan to `completed/` only after its requested behavior and applicable focused/repository checks pass and the handoff records remaining release or production state separately.

## Recommended sections

Use the repository's existing plan structure. The bundled template provides these restartable sections:

1. Purpose / Big Picture
2. Progress
3. Surprises & Discoveries
4. Decision Log
5. Outcomes & Retrospective
6. Context and Orientation
7. Plan of Work
8. Concrete Steps
9. Validation and Acceptance
10. Idempotence and Recovery
11. Artifacts and Notes
12. Interfaces and Dependencies
13. Revision History

Use checkboxes only for current `Progress`; keep the other sections prose-first. Name exact paths and commands when they materially help a restart. Record timestamps for meaningful progress or revisions, not every command.

## Verification and handoff

Use the smallest applicable verification tier: focused changed-behavior check, existing repository-native gate, then release or production proof only when requested. Report `verified locally`, `not run`, and `blocked` literally, with a reason. A passing local check proves engineering state only; it does not prove release, deployment, customer impact, or production authority.

Before closing a plan, compare the outcome with its purpose, state any gaps or follow-up, and confirm that retry and recovery instructions describe the final implementation. The bundled helper may validate an adopted managed plan's structure, but this guidance does not create a new validator or schema.
