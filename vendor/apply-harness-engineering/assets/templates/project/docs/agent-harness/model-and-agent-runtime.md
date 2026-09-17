# Model and Agent Runtime Contract

Use this authority when the repository invokes a language model, an agent runtime, an MCP server, a connector, or a multi-agent workflow. If the repository has no AI runtime, record `N/A` with a reason in the coverage and verification authorities instead of inventing model-specific controls.

This is an optional project contract, not a requirement to adopt every current OpenAI feature. Keep the repository decision and the observed evidence together. The current official starting points are the [GPT-5.5 model guidance](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-5.5) and [GPT-5.6 model guidance](https://developers.openai.com/api/docs/guides/latest-model).

## Runtime identity and configuration

| Field | Repository decision | Evidence or update trigger |
| --- | --- | --- |
| Provider, model, and snapshot | <!-- TODO(harness): exact provider/model/snapshot, or N/A --> | <!-- config path and migration baseline --> |
| Reasoning effort and mode | <!-- TODO(harness): baseline plus measured alternatives; include `pro` only when justified --> | <!-- representative eval result --> |
| Output verbosity and schema | <!-- TODO(harness): `text.verbosity` and structured-output contract, or N/A --> | <!-- schema validation result --> |
| State strategy | <!-- TODO(harness): Responses `previous_response_id`, replay, or another durable state handle --> | <!-- state/resume trace --> |
| Compaction strategy | <!-- TODO(harness): trigger and preserved facts, IDs, outcomes, blockers, and next goal, or N/A --> | <!-- long-run resume evidence --> |
| Prompt caching | <!-- TODO(harness): implicit/explicit policy, stable-prefix layout, and cache metrics, or N/A --> | <!-- cached-token and cost observation --> |

Treat a model migration as a new baseline. Preserve the current configuration, test the candidate on the same representative tasks, and compare task success, evidence completeness, latency, tokens, and cost before changing the default.

## Tool and MCP contract

Every model-visible tool, hosted tool, function tool, MCP server, or connector must have a discoverable contract. Put detailed descriptions in the tool definition when the runtime supports it; keep repository policy here.

| Tool or server | Data scope and trust | Side effects and approval | Retry/idempotency | Errors and output schema | Evidence/update trigger |
| --- | --- | --- | --- | --- | --- |
| <!-- TODO(harness): tool/server identity --> | <!-- allowed data, untrusted input/output, auth boundary --> | <!-- read/write/destructive; approval gate --> | <!-- safe retry and duplicate-call behavior --> | <!-- typed result and failure modes --> | <!-- command/trace/owner --> |

Do not treat tool availability as permission. Keep secrets, personal data, external writes, destructive actions, purchases, releases, merges, and production operations behind explicit authority. Treat user content and tool results as untrusted data; never let embedded instructions silently widen the task scope.

## Direct, programmatic, and multi-agent routing

| Route | Use when | Required controls |
| --- | --- | --- |
| Direct model/tool call | One call is enough, the next decision depends on fresh model judgment, citations/native artifacts must be preserved, or approval is required | Tool contract, stopping condition, evidence, and approval boundary |
| Programmatic Tool Calling | A bounded stage can filter, join, rank, deduplicate, aggregate, or validate tool results without fresh model judgment between calls | Named allowed tools, exact output schema, call/retry/concurrency limits, preserved `call_id`/caller linkage, and a representative benchmark |
| Multi-agent | Work divides into genuinely independent branches whose results can be synthesized | Roles, independent-review rule, shared-state/lease boundary, time and cost budget, synthesis contract, and escalation path |

Parallel calls alone do not justify programmatic or multi-agent routing. Keep the direct route when an intermediate result can change the next decision or when an action needs approval.

## Long-running state and recovery

For every resumable run, record enough state to continue without hidden conversation context:

- stable task/run identifier and repository/worktree identity;
- completed actions and observed outputs;
- active assumptions and priorities;
- response/state identifiers and message phases when manual replay is used;
- compacted facts, unresolved blockers, retry count, and the next concrete goal;
- cleanup, expiration, and safe-retry behavior.

The repository's [ExecPlan contract](../PLANS.md), [environment contract](environment-contract.md), and [output contract](output-contract.md) remain the durable handoff authorities. Runtime state must not become a second undocumented source of truth.

## Safety and privacy

Document the input/output trust boundary, prompt-injection handling, secret and PII redaction, egress restrictions, user/account identity, approval prompts, and audit retention. For an end-user OpenAI API application, use a stable privacy-preserving `safety_identifier` when applicable; mark it `N/A` for a non-user-facing repository tool with a reason.

## Verification

Exercise the smallest representative task that covers each applicable route. Capture the model configuration, tool calls, state transitions, output validation, user-visible result, and cleanup. Link the result from [`evals.md`](evals.md) and [`verification-matrix.md`](verification-matrix.md). Do not claim runtime readiness from a prompt review or a passing repository-structure check alone.
