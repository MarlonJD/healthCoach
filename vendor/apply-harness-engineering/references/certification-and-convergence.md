# Optional Strict Harness-Ready Convergence and Production Attestation

Use this contract only when the requested outcome includes the strict bounded `harness-ready` attestation rather than a limited audit, native-gate adoption, or scaffold. The repository-native gate and local evidence are the default completion path; source/attestation commits and HMAC records are an optional strict overlay. Production attestation is a separate optional layer.

Certification is not used by default. Do not create the manifest, HMAC evidence, or direct-child attestation commit during ordinary harness adoption; enter this contract only after an explicit certification request or repository-policy requirement.

## Guarantee boundary

Installing this skill is inert: it does not inspect or modify a repository, run project commands, add CI, schedule maintenance, watch for drift, or certify anything. Start the workflow below only after the user explicitly invokes `$apply-harness-engineering` for the named repository; implicit invocation is disabled. Do not claim that installing a skill changes an uninspected repository.

A successful `harness-ready` claim covers only one source commit and its clean direct-child attestation commit, the declared harness evaluation environment, and a non-expired evidence window. It requires every canonical capability to be independently resolved, every applicable capability to have fresh observed evidence, every inapplicable capability to have a fresh applicability record, and a project-native gate with a declared manual or automated revalidation path. The bundled verifier emits `CERT000` and exits zero when this bounded contract passes without an error or warning.

The workflow does not create deployment credentials, secrets, production access, human approval, production authority, product intent, or irreversible-action permission. Missing authority remains a real `blocked` state for any action that requires it. Do not weaken the native or strict harness gate, invent an artifact, or treat a local self-assertion as external evidence.

The caller supplies the HMAC key, repository identity, stable harness evaluation target, and evidence files. Coherent HMAC records therefore establish local integrity, not provider authentication. That limitation narrows the strict result to `harness-ready`; ordinary repository-harness adoption does not require this overlay. Add `--require-production-attestation` only when a stricter provider-backed result is explicitly required.

## Explicitly authorized convergence loop

For an explicit, authorized `$apply-harness-engineering` adoption request, continue the ordinary loop until the native project gate passes. Continue into the strict steps below only when the user or repository policy explicitly requires `harness-ready`, `CERT000`, or provider-backed production evidence:

1. Discover the actual stack, authorities, evaluation environments, CI provider, runtime surfaces, release path, and production boundary.
2. Create or resume an ExecPlan that inventories the applicable harness capabilities and, when strict attestation is requested, all 31 canonical coverage rows and every additional project-specific surface.
3. Run the adaptive audit, select the proportional target, and preserve existing canonical authorities.
4. Implement missing repository-native commands, routing, verification, observability, isolation, recovery, review, and maintenance behavior. Do not stop after copying templates.
5. Exercise each applicable capability through its real project or authorized external boundary. Record native evidence; only the strict profile stores one v2 HMAC-consistent record under the configured evidence root and links exactly one record from each completed coverage row. Do not treat a locally supplied issuer or key as external authority.
6. Implement a repository-native fail-closed gate in the project's own language or existing tooling. Do not make CI depend on the installed skill path.
7. Default to manual revalidation: run the native gate before task completion and record fresh evidence. Do not create or modify hosted CI workflow files unless the user explicitly requests CI automation. If requested, wire the native gate to pull requests, pushes, and a bounded schedule. When drift is safe and authorized to repair, rerun the native gate; otherwise fail the gate and expose the blocker. For the strict profile only, bind records and the manifest to the source/direct-child pair and refresh the attestation.
8. For the strict profile, commit the implementation as source commit `S`; then create one direct-child attestation commit `A` containing only the coverage matrix, certification manifest, and referenced HMAC records. Include approval and rollback records only when the production-authority row is `verified`; use a fresh applicability record and null `production_authority` fields when that row is justified `N/A`.
9. Re-run project-native tests, the full harness check, the project-native gate, the applicable AI-runtime smoke/eval suite, and—only for the strict profile—the bundled read-only `certify` command against trusted current commit `A`. Report `harness-ready` only when `CERT000` returns.
10. If independent production proof is explicitly requested, rerun strict certification with `--require-production-attestation`. Treat its provider evidence and outcome separately from ordinary native-gate readiness.

Routine reversible repository edits and tests remain inside an authorized adoption request. External writes, secrets, human approvals, destructive actions, merge, release, deployment, and production operations still require the authority declared by the user and repository. A `harness-ready` result never grants that authority. When an explicitly requested production attestation lacks it, report the blocker and do not claim production readiness.

## Harness-evidence record v2

Every linked evidence file is a JSON object with exactly these fields:

```json
{
  "schema_version": 2,
  "repository_commit": "0123456789abcdef0123456789abcdef01234567",
  "repository_identity": "scm://provider.example/immutable-repository-id",
  "deployment_target_id": "harness://provider.example/stable-evaluation-target-id",
  "capabilities": ["Exact coverage-row identity"],
  "environment": "ci",
  "command": "project-native exact command or named review procedure",
  "exit_code": 0,
  "observed_at": "2026-07-23T09:30:00Z",
  "result": "passed",
  "artifacts": ["immutable job, trace, approval, screenshot, or repository evidence ID"],
  "issuer": "ci-harness-observer",
  "key_id": "<lowercase-sha256-of-raw-evidence-key-bytes>",
  "signature": "<lowercase-hmac-sha256>"
}
```

`schema_version` is the exact integer `2`; v1 evidence is invalid. `repository_commit` is source commit `S`, not attestation commit `A`. For schema compatibility, `deployment_target_id` names the stable harness evaluation target: a repository, package, service, deployment target, or other concrete subject. It is not necessarily a production deployment. `repository_identity` and `deployment_target_id` must exactly match the concrete values in the manifest; placeholders such as `default`, `repository`, `production`, `prod`, and `unknown` are invalid. These locally declared identities prevent accidental cross-target reuse but are not provider authentication.

`capabilities` is a non-empty list of non-empty strings and must name the exact covered capability. A verified record uses `result: "passed"` and the exact integer `exit_code: 0`. For a justified `N/A`, use `result: "not-applicable"`, `exit_code: null`, a current applicability-review procedure in `command`, and a durable decision artifact.

The caller supplies an absolute `--attestation-key-file`. The key file must be outside the repository, non-symlinked, regular, single-linked, 32–4096 raw bytes, and inaccessible to group and world. `key_id` is lowercase SHA-256 of those exact raw bytes. These controls prevent simple repository-key substitution and accidental tampering, but the verifier does not pin the key to an external provider identity. A caller can generate another compliant key and matching records, so HMAC validation cannot establish production authority.

Compute `signature` as HMAC-SHA256 over the domain bytes `harness-engineering-evidence-v2\x00` followed by UTF-8 canonical JSON of every evidence field except `signature`. Canonical JSON uses ASCII escaping, sorted keys, no whitespace separators, and rejects non-finite numbers. Store the lowercase hexadecimal digest. The helper checks record consistency but does not authenticate `issuer`, independently dereference artifact IDs, verify a provider event, or prove the truth of an observation. Never present a valid HMAC as human approval, deployment authority, rollback proof, or production certification.

The project-native gate and maintenance trace always use the same schema with these capability identities:

- `project-native-harness-gate`
- `continuous-harness-maintenance`

Production approval and rollback observations use the same schema only when the production-authority row is `verified`:

- `production-authority-approval`
- `production-rollback-readiness`

Those local observation records do not become provider-authenticated proof merely because their environment is `production`.

## Harness-ready validity

The ordinary read-only command is:

```text
python3 <skill-dir>/scripts/harness.py certify --root <repo> --profile <governed|adaptive> --commit <trusted-attestation-commit-A> --attestation-key-file <absolute-evidence-key-path>
```

The v2 `harness-ready` manifest's `repository_commit` field is source commit `S`. The caller must obtain `--commit` as attestation commit `A` from a trusted CI or source-control context, not from the manifest. `A` must be the clean current `HEAD` and the direct single-parent child of `S`. The exact `S..A` changed-path set contains only the configured certification path, configured coverage path, exactly one referenced HMAC-consistent JSON file for each `verified` or justified `N/A` row, the named gate and maintenance records, and any approval and rollback records required by a verified production-authority row. All other project changes belong in `S`, never in the attestation overlay.

Strict certification fails on any error or warning and checks:

- the exact 31-row canonical inventory plus any project-specific rows;
- only `verified` or justified `N/A` states, each linked to one fresh HMAC-consistent v2 record bound to `S`, the declared repository identity, and the stable harness evaluation target;
- an exact digest of the configured coverage matrix;
- a project-native gate and a maintenance trace;
- exactly `manual` maintenance, or pull-request, push, and scheduled triggers when CI automation was explicitly requested;
- a maximum freshness window of seven days;
- a substantive harness evaluation environment;
- no unresolved structural, routing, link, plan, coverage, or semantic warning.

The exact row `Release, deployment, and production actions require repository-local authority` may be a fresh justified `N/A` during strict certification when the repository has no such action. In that case, `production_authority.owner`, `approval_evidence`, and `rollback_evidence` must all be `null`, and no approval or rollback file belongs in the attestation overlay. If the row is `verified`, name a substantive durable owner and include fresh approval and rollback observation records. Those records satisfy the repository contract but do not independently authenticate a provider.

The template manifest stays `harness-ready` only for the strict profile. A complete strict certification returns `CERT000` and zero. `candidate-only` describes incomplete evidence and is not a successful manifest claim. Adaptive validation still requires the complete canonical inventory when strict certification is requested. Non-Git projects cannot satisfy the source/attestation binding.

## Optional production attestation

The stricter read-only command adds one flag:

```text
python3 <skill-dir>/scripts/harness.py certify --root <repo> --profile <governed|adaptive> --commit <trusted-attestation-commit-A> --attestation-key-file <absolute-evidence-key-path> --require-production-attestation
```

This explicit request additionally requires:

- manifest and required authority evidence scoped to `environment: "production"`;
- the production-authority coverage row marked `verified`, never `N/A`;
- a substantive production owner and fresh approval and rollback evidence;
- provider-authenticated repository and production-target identity, approval, rollback, artifact provenance, freshness, and revocation.

The current package has no provider-specific asymmetric verifier with a trust root provisioned independently of the repository and invocation. It therefore emits nonzero `CERT015` only when this optional stricter flag is used. The caller-selected HMAC key remains sufficient for ordinary evidence integrity but never substitutes for the requested external verifier. The manifest claim remains `harness-ready`; a `production-ready` claim is rejected with `CERT003`.

Any commit after `A`, source change, evidence change, expired timestamp, invalid declared maintenance mode, failed project-native gate, changed applicability or authority input, or changed coverage digest invalidates `harness-ready` when certification is rerun. Manual or explicitly requested automated maintenance can restore it by selecting the new source state, refreshing records, producing a new direct-child attestation commit, and receiving `CERT000`. It cannot establish external production authority or make a historical claim permanently true.
