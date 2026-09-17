# Optional Strict Harness Attestation (Disabled by Default)

Certification is not used by default. The ordinary harness workflow ends at the project-native gate and literal local evidence. Use this document, the manifest, and the HMAC evidence overlay only after a user or repository policy explicitly requests a bounded `harness-ready`/`CERT000` result.

The bundled verifier can issue the bounded claim `harness-ready` only for the optional strict attestation profile. Normal adoption should stop at the repository-native gate and literal local evidence; do not create HMAC records or an attestation overlay unless the user or repository policy explicitly requires this stricter result. In strict mode, the verifier checks the complete 31-row repository contract, local structure, HMAC record consistency, freshness, the project-native gate, and the Git source/attestation boundary. When every required check passes without an error or warning, `certify` emits `CERT000` and exits zero. This result says that the inspected repository harness is current for one source/direct-child attestation pair and one evidence window; it does not say that the application was released, deployed, or independently certified for production. Installation, scaffolding, documentation presence, an arbitrary caller-selected key, or a local-only assertion is not certification. Keep [`certification.json`](certification.json) at `claim: "harness-ready"`.

The `certify` command accepts `--profile governed` (the default) or `--profile adaptive`. Both strict paths require the canonical coverage inventory; adaptive mode changes authority discovery, not the certification inventory.

## Convergence owner and command

- Owner: <!-- TODO(harness): durable role or team -->
- Project-native gate: <!-- TODO(harness): exact repository command; do not depend on the installed skill path -->
- Strict attestation enabled? <!-- TODO(harness): yes only when explicitly required; otherwise N/A -->
- Authorized safe repair command or procedure: <!-- TODO(harness): bounded repository-native convergence path and trigger -->
- Evidence record issuer: <!-- TODO(harness): local process or explicitly requested CI that observes harness checks; this field is not externally authenticated -->
- Evidence HMAC key custody: <!-- TODO(harness): key owner and storage policy; never record the key -->
- Optional production verifier: <!-- TODO(harness): provider-specific asymmetric verifier or explicitly unavailable/N/A -->
- Escalation boundary: <!-- TODO(harness): production, secret, human-approval, destructive, external-write, and product-judgment blockers -->

Missing project commands, current evidence, or source-control authority blocks `harness-ready`. Missing production access, approval, rollback exercise, or provider authority blocks only an explicitly requested `--require-production-attestation` result unless the corresponding canonical capability is otherwise applicable. Never replace external authority with a template, default, inferred pass, local self-attestation, fabricated artifact, or self-selected HMAC key.

## Source and attestation commits (strict profile only)

Commit all implementation, project commands, maintenance behavior, and any explicitly requested CI as source commit `S`. Every HMAC-consistent evidence record and `certification.json.repository_commit` names `S`.

Create direct-child attestation commit `A` only after the harness checks were observed and recorded. `A` may change exactly the configured coverage matrix, configured certification manifest, one referenced HMAC JSON file for every `verified` or justified `N/A` row, and the named project-gate and maintenance files. When the production-authority row is `verified`, it also includes the named approval and rollback records; when that row is justified `N/A`, all three `production_authority` fields are `null` and no approval or rollback record belongs in the overlay. `A` must contain no implementation change. The certification check receives trusted current `A` as `--commit`; `A` must be clean `HEAD` and have `S` as its only parent. Any next commit invalidates `harness-ready`.

## Revalidation and invalidation

Run the project-native harness gate before task completion. Keep strict attestation disabled or invalid unless it is explicitly enabled. When strict mode is enabled, use `triggers: ["manual"]` by default and refresh the source/direct-child pair after relevant changes. Do not create or modify hosted CI workflow files unless the user explicitly requests CI automation. If requested, replace manual mode with pull-request, push, and scheduled triggers no less frequent than the manifest's `max_age_hours`. Fail closed when routing, commands, records, declared applicability or authority, behavior, or the [`coverage matrix`](coverage-matrix.md) drifts. An explicitly authorized repository-native maintenance path may repair only safe drift within existing repository and user authority. A successful strict recovery produces fresh evidence and a new `CERT000` result; it cannot invent production authority.

## Evidence rules (strict profile only)

Store exact-schema v2 JSON evidence records beneath the manifest's `evidence_root`. Each record contains `schema_version`, `repository_commit`, `repository_identity`, `deployment_target_id`, `capabilities`, `environment`, `command`, `exit_code`, `observed_at`, `result`, `artifacts`, `issuer`, `key_id`, and `signature` exactly once. For schema compatibility, `deployment_target_id` names the stable harness evaluation target: the repository, package, service, deployment target, or other concrete subject whose evidence is being evaluated. It is not necessarily a production deployment. `repository_identity` and `deployment_target_id` exactly match the concrete values in the manifest. Link every `verified` and justified `N/A` status cell to one matching record. V1 records are invalid.

The caller supplies an absolute owner-only HMAC key file outside the repository. It must be a non-symlinked regular file with one hard link, 32–4096 raw bytes, and no group or world permission. `key_id` is lowercase SHA-256 of those raw bytes. `signature` is lowercase HMAC-SHA256 over `harness-engineering-evidence-v2\x00` followed by UTF-8 canonical JSON of every field except `signature`, using sorted keys, ASCII escaping, no whitespace separators, and no non-finite numbers.

For `verified`, require `result: "passed"` and the exact integer `exit_code: 0`. For justified `N/A`, require `result: "not-applicable"` and `exit_code: null`. Record substantive immutable artifact IDs. HMAC validity checks consistency with the caller-supplied key; it does not authenticate `issuer`, validate an artifact URL, prove a provider event, or establish human, deployment, rollback, or production authority. That limitation narrows the strict result to `harness-ready`; it does not replace the repository-native gate.

## Production-authority applicability

Strict certification may use a fresh justified `N/A` for the exact coverage row `Release, deployment, and production actions require repository-local authority` when the repository has no such action. In that case, keep the exact `production_authority` object in the v2 manifest but set `owner`, `approval_evidence`, and `rollback_evidence` to `null`.

When that row is `verified`, name a substantive durable owner and provide fresh HMAC-consistent approval and rollback observation records. Those local records verify the repository contract but still do not authenticate a production provider. Populate them with `environment: "production"` only when the observations actually occurred in production or the optional stricter profile is requested.

## Optional production attestation

Add `--require-production-attestation` only when independent production evidence is explicitly required. This stricter request requires the manifest environment to be `production`, forbids `N/A` for the production-authority coverage row, and requires provider-authenticated repository and production-target identity, approval, rollback authority, artifact provenance, freshness, and revocation.

The bundled package currently has no provider-specific asymmetric verifier with an independently provisioned trust root. Therefore a valid strict attestation returns `CERT000`, while an explicit `--require-production-attestation` request returns nonzero `CERT015` until such a verifier is configured. The manifest claim remains `harness-ready`; changing it to `production-ready` is rejected with `CERT003` and does not simulate production proof.

<!-- TODO(harness): Record the repository-native manual command and one observed invalidate-and-recover trace when strict attestation is enabled. If CI automation was explicitly requested, also record the CI job, triggers, consumer, and failure notification. -->
