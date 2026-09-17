# Harness Engineering Assessment Rubric

Use this rubric only when assessment is requested. Diagnose capabilities, not file count, and record the smallest useful improvement for each dimension. A gap is not a blocker for ordinary local engineering unless the requested outcome depends on it.

## Maturity levels

| Level | Meaning |
| --- | --- |
| 0 — Invisible | Knowledge or feedback exists only in people, chats, or undocumented tools. |
| 1 — Discoverable | A repository-local document or command exposes the capability. |
| 2 — Repeatable | An agent can follow a deterministic path and obtain expected evidence. |
| 3 — Enforced | CI, structural tests, schemas, or runtime checks prevent known drift. |
| 4 — Self-maintaining | Scheduled or event-driven loops detect decay, propose repairs, and preserve evidence. |

Strict attestation is an optional bounded result layered on this rubric, not a maturity score or a universal production claim. It requires the complete 31-row inventory, a trusted source/direct-child attestation commit binding, fresh HMAC-consistent evidence for every `verified` or justified `N/A` capability, and a fail-closed project-native gate. An explicitly requested production attestation is stricter: it additionally requires production-scoped, provider-authenticated repository, target, approval, rollback, artifact, freshness, and revocation evidence. Keep its result codes in the certification guidance.

## Dimensions

1. **Orientation and knowledge routing**
   - Check whether a concise `AGENTS.md` points to authoritative, versioned sources.
   - For a fresh or lightly adopted repository, a one-file orientation may be sufficient; do not score a larger documentation tree as inherently better.
   - Check that the effective `AGENTS.override.md`/`AGENTS.md` routes occur before the instruction byte cutoff and that relevant root-to-working-directory chains fit the trusted effective `project_doc_max_bytes` configuration.
   - Check whether architecture, product intent, operational constraints, and decisions are discoverable without external conversation history.
   - Check whether repository-local scripts or skills and authorized source-control, review, and CI context are directly invocable and documented.
2. **Planning and continuity**
   - Check whether complex work uses self-contained living ExecPlans with progress, discoveries, decisions, outcomes, commands, and acceptance evidence. Small work does not need a plan by default; a plan is current state, not a command transcript.
   - Check whether active, completed, and technical-debt states are indexed and unambiguous.
3. **Executable verification**
   - Check for deterministic setup, build, test, lint, type, security, and end-to-end commands.
   - Check whether success is observable as behavior rather than inferred from code changes alone.
4. **Agent-readable runtime**
   - Check whether agents can start an isolated instance, reproduce failures, inspect UI or API state, and query useful logs, metrics, or traces.
   - Score only signals the project actually needs; do not require a browser or telemetry stack for a static library.
5. **Mechanical architecture and quality boundaries**
   - Check whether important dependency directions, schemas, naming rules, file limits, security boundaries, and reliability constraints are executable.
   - Check whether failures explain how to recover.
   - Check whether important upstream behavior is inspectable through stable APIs, adapters, fixtures, or checked-in references rather than hidden assumptions.
6. **Feedback capture and entropy control**
   - Check whether repeated review findings, incidents, flaky tests, stale docs, and duplicated patterns feed back into docs or tooling.
   - Check for a small, recurring cleanup loop and a visible quality or debt register only when maintenance is in scope; do not create either merely to raise the score.
7. **Safe autonomy and recovery**
   - Check whether agents can validate their own work, obtain review, handle failures, retry safely, and escalate judgment calls.
   - Keep destructive, production, release, merge, and external-write authority separate from local implementation capability.
8. **AI runtime and evaluation (when applicable)**
   - Check whether the model/provider/snapshot, reasoning settings, state/replay, compaction, prompt caching, output schemas, and tool/MCP permissions are discoverable.
   - Check whether representative tasks measure success, evidence completeness, tool behavior, recovery, latency, tokens, and cost before a model or orchestration change is promoted.
   - Mark this dimension `N/A` for repositories with no AI runtime; do not manufacture model evidence.

## Prioritization rule

Fix the earliest broken feedback loop before adding higher autonomy. Prefer this order:

1. Make intent and commands discoverable.
2. Make verification deterministic.
3. Make runtime behavior observable.
4. Mechanize proven invariants.
5. Capture decisions and recurring failures.
6. Automate maintenance.
7. Expand autonomy within explicit authority.

Treat missing production, real-device, release, or external approval evidence as a scoped gap, not as proof that ordinary local work or native harness adoption failed. A fresh justified `N/A` is valid for an inapplicable surface. When strict `--require-production-attestation` is explicitly requested, every required production authority and proof becomes a hard blocker and cannot be replaced by a local assertion, default value, caller-selected HMAC key, or `N/A`; consult the certification guidance for unavailable-verifier handling.
