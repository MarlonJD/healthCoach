# ExecPlan Contract and Lifecycle

Base a plan on OpenAI's [Using PLANS.md for multi-hour problem solving](https://developers.openai.com/cookbook/articles/codex_exec_plans) only when the work needs continuity. Treat that Cookbook article as a customizable pattern, not a built-in Codex protocol. A small, low-risk change can use a normal handoff without an ExecPlan.

## Official pattern principles

Make every ExecPlan:

- self-contained and usable by a contributor with no prior conversation context;
- a living document that remains accurate after each update;
- focused on demonstrably working user behavior;
- explicit about repository paths, commands, expected observations, and recovery;
- explicit about expected outputs and relevant failure/error messages so a novice can distinguish success from failure;
- written in plain language with repository-specific terms defined;
- safe to resume from the plan file alone.
- a restartable current-state record rather than an execution transcript;
- proportionate to the requested outcome or a concrete risk. Plan size is a review signal, not a hard limit, and every step should trace to that outcome or risk;
- concise about evidence: retain commands, results, and short observations, not raw logs, traces, JSONL proof, screenshots, or repeated reproducible output;
- independent of unversioned external context: embed the knowledge needed to execute the plan, while allowing references to relevant checked-in repository documents;
- explicit about narrative milestones as goal/work/result/proof, while using granular checkboxes separately for current progress;
- willing to use additive, independently testable prototypes or parallel implementations when meaningful uncertainty must be reduced.
- prescriptive about selected dependencies and final interfaces: explain why they are chosen and name required types, interfaces/traits, function signatures, services, and stable paths when applicable.
- grounded in direct dependency evidence when difficult requirements turn on upstream behavior: inspect available library source or an authoritative contract, record what was learned, and use isolated spikes when several unknowns can be tested independently.

The Cookbook's supplied `PLANS.md` contract explicitly treats `Progress`, `Surprises & Discoveries`, `Decision Log`, and `Outcomes & Retrospective` as non-optional living sections. The article also says teams may customize the contract.

## Optional managed plan schema

When a repository chooses this skill's managed lifecycle, maintain these sections in order:

1. `Purpose / Big Picture`
2. `Progress`
3. `Surprises & Discoveries`
4. `Decision Log`
5. `Outcomes & Retrospective`
6. `Context and Orientation`
7. `Plan of Work`
8. `Concrete Steps`
9. `Validation and Acceptance`
10. `Idempotence and Recovery`
11. `Artifacts and Notes`
12. `Interfaces and Dependencies`
13. `Revision History`

The exact thirteen-heading set and order, metadata block, `Revision History` heading, and path conventions below are optional local schema choices. Do not impose them on a repository that has another working plan authority. Adopting or configuring this managed lifecycle is an explicit choice; this guidance does not create a new validator or schema. Use timestamped checkboxes only in `Progress`, keep narrative sections prose-first, and include user-visible proof rather than compilation alone.

For the managed schema, use valid ATX Markdown headings and leave one blank line after every heading (two newline characters, with CRLF accepted). A standalone plan file is not wrapped in an outer fence; use indented examples for concise commands, results, diffs, or code when they help a restart.

The local `harness-plan:v1` metadata contains `id`, `status`, `created`, `updated`, `completed`, and `owner` exactly once. The `id` equals the lowercase-hyphenated filename stem. Active plans use `status: active`, leave `completed` empty, assign an owner, and keep `created <= updated`. Completed plans use `status: completed`, populate `completed`, retain the same `id` and `created`, and keep `created <= completed <= updated`.

The managed lifecycle is valid only when its configured planning authority exists as a regular repository file. Owners must be substantive roles or teams rather than sentinel values such as `none`, `N/A`, `unknown`, or punctuation. Every Active registry row must likewise name a substantive current milestone or blocker.

## Local lifecycle extension

1. Resolve the configured ExecPlan index only when the managed lifecycle is adopted. Create a lowercase hyphenated filename in its sibling `active/` directory; the bundled default is `docs/exec-plans/active/`.
2. Keep one owning plan for a cross-repository outcome. Child repositories carry only their local change and verification; they do not copy the owning plan.
3. Keep the exact registry title, Active/Completed headings, table headers, and lifecycle markers from the selected index template when that lifecycle is in use; add the plan to the Active table with owner, status, and update date.
4. Update the four living sections at every stopping point. Split partially completed progress into explicit done and remaining parts.
5. Record design changes in `Decision Log` at the moment they occur. Record unexpected behavior with concise evidence.
6. Before completion, run the applicable focused and repository checks and replace placeholders with observed facts.
7. Move unresolved non-blocking follow-up work into the plan outcome or an existing debt authority only when that authority exists or the request requires it.
8. Review the current plan for self-containment, meaningful milestones, observable behavior, recovery, and concise evidence before completion. This is ordinary plan review, not a signed approval or production evidence.
9. Move the file to the index's sibling `completed/` directory only when all required progress is checked and the retrospective states achieved behavior, remaining gaps, and evidence.
10. Update the index atomically with the move when the managed lifecycle is in use. Keep completed plans immutable except for corrections or supersession notes.

When revising a plan, propagate the change through every affected section so the document remains internally consistent, then record what changed and why in `Revision History`. Remove stale detail and repeated facts. The Cookbook sample advises frequent commits, but that sentence does not grant source-control write authority: create commits or other Git checkpoints only when current user and repository instructions authorize them; otherwise use the living plan and working tree as the restart record.

## Completion checks

- Reject a completion with unchecked progress items.
- Reject a completion with unresolved placeholders such as `TODO` or `<replace>`.
- Reject a completion with an empty `Outcomes & Retrospective` section.
- Ensure every local Markdown link resolves.
- Ensure the plan links to the planning authority declared in `docs/agent-harness/config.json`.
- Ensure every revision records what changed and why.
- Verify that commands and outcomes reflect the current tree, not an earlier milestone.
- A plan review confirms self-containment, meaningful milestones, observable behavior, recovery, and concise evidence; structural validation cannot prove natural-language meaning or external approval.

Do not treat moving a file as proof of completion. Treat the recorded behavior and evidence as proof.
