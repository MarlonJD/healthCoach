# Agent Evaluation Contract

Use this authority only when model, prompt, tool, orchestration, or agent-runtime behavior changes, or when an evaluation is explicitly requested. It is optional for repositories with no AI runtime. A repository-level harness check is not a substitute for evaluating the agent's actual behavior, but an evaluation suite is not a default requirement for unrelated work.

## Evaluation applicability

State the runtime surface, owner, dataset location, and reason when this contract is `N/A`. For an applicable runtime, start with the smallest deterministic smoke set that can detect the changed behavior; use a broader representative set only when the request, risk, or repository policy requires it.

| Surface | Dataset or scenario | Expected outcome | Evidence artifact | Status/update trigger |
| --- | --- | --- | --- | --- |
| <!-- TODO(harness): task family --> | <!-- fixture, prompt, or replay ID --> | <!-- user-visible and safety criteria --> | <!-- concise run/result reference --> | <!-- verified locally/not run/blocked/N/A; owner/trigger --> |

## Required comparison dimensions

When a model or orchestration change needs evaluation, compare the same task set before and after it:

- task success and acceptance-criteria completion;
- required evidence and output/schema completeness;
- tool selection, arguments, retries, and unauthorized side effects;
- recovery/resume behavior after failure or compaction;
- latency, total tokens, cached tokens, and cost;
- refusal, escalation, privacy, and prompt-injection behavior where relevant.

Do not promote a configuration because it is faster or cheaper if it loses required evidence or user-visible correctness. Do not promote a higher reasoning effort, `pro` mode, or a multi-agent route unless the quality gain is measured on a task set appropriate to the decision.

## GPT-5.5 and GPT-5.6 migration baseline

For GPT-5.5, start from a fresh baseline rather than carrying forward an old prompt stack. Begin with `medium` reasoning effort, test `low` for latency-sensitive work, and increase effort only when the eval shows a measurable gain. Verify Responses state, `phase` replay, compaction, structured output, tool descriptions, and prompt-cache behavior when those surfaces are used.

For GPT-5.6, preserve the current GPT-5.5/GPT-5.4 reasoning setting as the baseline and compare one level lower. Evaluate model tier (`sol`, `terra`, or `luna`), `max`/`pro` only for quality-first work, persisted reasoning, explicit prompt caching, Programmatic Tool Calling, and multi-agent routing independently. Benchmark task success, final-answer completeness, required evidence, total tokens, latency, and cost.

## Run and report

Record the exact command or named procedure, model/provider/snapshot, prompt or skill revision, tool catalog, environment, dataset/replay IDs, timestamp, and a concise result reference. Report `verified locally`, `not run`, `blocked`, or `N/A` literally. A local eval result is not production evidence unless the production environment and authority were actually in scope.

The repository-native gate should run the smallest deterministic smoke set only when the runtime surface is applicable. Broader evals may remain report-only until the baseline is stable; promote a check to blocking only after its noise and recovery path are understood.
