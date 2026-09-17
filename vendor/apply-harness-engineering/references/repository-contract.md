# Repository Knowledge Contract

Keep one authoritative home for each kind of knowledge. Link from indexes instead of copying the same rule into several files.

## Artifact ownership

Create an artifact only when the requested outcome, an existing repository policy, or a concrete repeated risk needs it. A one-file `AGENTS.md` can be a complete starting point; installation or an adaptive audit does not require the full table below.

| Artifact | Owns | Update trigger |
| --- | --- | --- |
| Root `AGENTS.md` | Canonical orientation, links, commands, durable constraints, and definition of done | A repeated agent failure or a navigation/command change |
| Root `AGENTS.override.md` (when present) | Codex's higher-precedence root entry point; must preserve routes to the canonical authorities | A temporary override is introduced, changed, or retired |
| Nested `AGENTS.md` | Rules that differ for one subtree | A genuine local exception appears or disappears |
| `ARCHITECTURE.md` | System map, boundaries, dependency direction, runtime topology | Components, boundaries, or major data flows change |
| `docs/PLANS.md` | The repository's ExecPlan authoring and execution contract | The plan process or required evidence changes |
| `docs/exec-plans/index.md` | Active/completed plan registry and lifecycle | A plan starts, completes, pauses, or is superseded |
| `docs/exec-plans/tech-debt-tracker.md` | Known debt with evidence, impact, and next action | Debt is discovered, changes priority, or is resolved |
| `docs/design-docs/` | Durable design rationale and alternatives | A cross-cutting design is proposed or materially revised |
| `docs/product-specs/` | User behavior, scope, and acceptance semantics | Product behavior or intent changes |
| `docs/generated/` | Machine-produced snapshots and provenance | The generating source changes |
| `docs/references/` | Stable external constraints needed offline | An authoritative dependency reference changes |
| `docs/agent-harness/registry.md` | Agent-callable commands and capabilities | A command, tool, owner, or status changes |
| `docs/agent-harness/config.json` | Paths to adopted canonical authorities | An authority is created, moved, or intentionally mapped to an equivalent |
| `docs/agent-harness/operating-loop.md` | Human/agent responsibilities, review loop, recovery, and escalation | The development or approval workflow changes |
| `docs/agent-harness/environment-contract.md` | Isolation, lifecycle commands, runtime signals, and cleanup | Local runtime or observability behavior changes |
| `docs/agent-harness/model-and-agent-runtime.md` | Optional model/provider, state, compaction, tool/MCP, safety, and direct/PTC/multi-agent contract | An AI runtime, tool catalog, state strategy, or approval boundary changes |
| `docs/agent-harness/evals.md` | Optional focused or representative task baselines and model/orchestration comparison evidence | A prompt, model, reasoning setting, tool, orchestration, or eval dataset changes |
| `docs/agent-harness/output-contract.md` | Completion evidence and handoff language | Review or release evidence requirements change |
| `docs/agent-harness/verification-matrix.md` | Requirement-to-check-to-evidence mapping | A surface, risk, or verification path changes |
| `docs/agent-harness/entropy-cleanup-checklist.md` | Recurring drift checks and escalation rules | A recurring anti-pattern or cleanup loop changes |
| `docs/agent-harness/coverage-matrix.md` | Optional source-principle-to-artifact-to-evidence traceability for an adopted governed contract | A harness capability is added, removed, or reclassified when this authority is in use |
| `docs/agent-harness/certification.md` | Optional strict attestation convergence, invalidation, and production-attestation boundary | The native gate, CI triggers, repair authority, evidence profile, or provider-verifier boundary changes |
| `docs/agent-harness/certification.json` | Source-commit-, repository-, evaluation-target-, environment-, coverage-, and freshness-bound strict manifest carried in a direct-child attestation commit | Any bound commit, identity, record, coverage digest, applicability decision, or freshness window changes |
| `docs/agent-harness/evidence/` | HMAC-consistent v2 harness observation and applicability records referenced by coverage and the manifest; not externally authenticated production proof | A capability is exercised, reclassified, invalidated, or refreshed |

## Navigation rules

- Keep the effective root entry point concise and inside Codex's instruction-load budget. Codex tries a non-empty root `AGENTS.override.md`, then non-empty root `AGENTS.md`, then each configured `project_doc_fallback_filenames` entry in order. The default `project_doc_max_bytes` is 32 KiB, and more local project instructions consume the effective root-to-working-directory chain. Prefer links over embedded essays; a one-file MVP orientation is valid until deeper routes are needed.
- Treat `.codex/config.toml` as a Codex configuration layer, not a harness authority map. Project configuration is trust-dependent and may be overridden by user, profile, nested project, or CLI layers. A repository-declared budget above 32 KiB requires runtime effective-config and instruction-load evidence; the bundled static checker remains conservative at 32 KiB. Run the helper with Python 3.11+ when this TOML file exists; older Python emits fail-closed `CODEXCFG001` because `tomllib` is unavailable.
- Use repository-relative links and verify them mechanically.
- Add an index to a collection whose members change over time; do not create an index for a one-off local change.
- Name owners as roles or teams when individuals would make the document decay quickly.
- Record `last verified` only when a person or command can actually refresh it.
- Mark generated documents with their source and regeneration command. Do not hand-edit generated content.
- Use `N/A` with a reason for intentionally absent surfaces; do not leave unexplained empty sections.
- Treat certification as disabled by default. A strict manifest, when explicitly enabled, is optional expiring state rather than durable truth. Bind HMAC-consistent v2 records and the manifest to source commit `S`, bind verification to clean direct-child attestation commit `A`, and keep records under the configured repository evidence root. Any later commit invalidates `A`. Result codes and unavailable-provider behavior belong in the certification guidance; records remain local integrity evidence rather than provider-authenticated production proof.
- Treat the installed skill as external tooling, not a repository lifecycle service. Installation alone creates no repository files, CI gate, scheduled invalidation, evidence, certificate, or repair authority.

## Change rules

- Extend existing authoritative documents before creating competing ones.
- When `docs/agent-harness/config.json` maps an authority away from a bundled fallback, update `AGENTS.md`, documentation maps, harness routers, coverage rows, and ExecPlan links that still present the fallback as canonical. The JSON mapping does not rewrite Markdown links by itself; run the harness check after every mapping change.
- A mapped coverage authority may adapt implementation paths and evidence when the governed contract is adopted. Do not create or expand a coverage inventory for a small local change; when strict certification is explicitly requested, its existing certification guidance defines the required inventory.
- Keep the canonical `instructions` authority at root `AGENTS.md`. When root `AGENTS.override.md` exists, Codex loads it instead, so it must route the same canonical authorities directly or through `AGENTS.md`. Naming an arbitrary path in this harness config does not make Codex load it.
- When nested `AGENTS.override.md`, `AGENTS.md`, fallback instruction files, or nested `.codex/config.toml` layers exist, verify the effective chain from repository root to each relevant working directory. Do not infer that a root-only static pass proves every working-directory context.
- Preserve repository terminology and language conventions.
- Migrate content additively: create the target, link it, validate consumers, then retire duplicates in a separate safe step. For an MVP orientation, preserve an existing root `AGENTS.md` rather than replacing it.
- Keep policy in prose while it is exploratory. Promote it into a test or linter after it proves stable or protects a critical boundary.
- Write failure messages for agents: state what failed, why it matters, the affected path, and the command or edit that fixes it. Keep successful evidence to a command, result, and short observation.

## Minimum useful content

Do not count an empty template as adoption. Require every created artifact to contain project-specific facts, a clear owner or update trigger, and at least one navigation or verification path. A fresh MVP fragment is intentionally generic but immediately usable and has no placeholders or broken links; tailor it when adopting it into a target repository.
