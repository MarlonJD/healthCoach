# Entropy Cleanup Checklist

Run this sweep only when repository maintenance is in scope and at a cadence justified by change rate. Keep the process read-only until a finding is verified; use an ExecPlan for broad remediation.

Certification is not used by default. Apply the strict-attestation checks below only when that optional overlay has been explicitly enabled; the native project gate remains the ordinary completion proof.

The cadence may be a manual repository-native procedure. Installing the external skill does not schedule this sweep or grant repair, pull-request, merge, release, or production authority. Do not add hosted automation unless the user explicitly requests it.

## Documentation and navigation

- [ ] Check local Markdown links and indexes.
- [ ] Compare documented commands with current manifests and CI.
- [ ] Find architecture or product docs that disagree with current behavior.
- [ ] Find abandoned active plans and completed plans with unchecked work.

## Code and architecture

- [ ] Find duplicated helpers, divergent conventions, and bypassed shared boundaries.
- [ ] Check dependency direction and cross-boundary imports against current architecture.
- [ ] Check growing files, modules, generated diffs, suppressions, flags, and ownerless TODOs.
- [ ] Identify a repeated review or incident pattern that should become a test or linter.

## Verification and runtime

- [ ] Exercise registry commands that are marked `verified locally`.
- [ ] Check flaky tests, stale fixtures, inaccessible logs, and nondeterministic setup/reset paths.
- [ ] Confirm UI, API, migration, or operational evidence still matches the verification matrix.
- [ ] Check isolation and cleanup for concurrent or long-running agent work.
- [ ] If strict attestation is explicitly in scope, follow its separate certification document; do not duplicate its records here.
- [ ] Confirm the existing project-native gate runs when one is present. Add pull-request, push, or scheduled automation only when explicitly requested.

## Triage

| Finding | Evidence | Impact | Action | Destination | Owner | Status |
| --- | --- | --- | --- | --- | --- | --- |
| <!-- TODO(harness): observed drift --> | <!-- command/link --> | <!-- concrete consequence --> | <!-- small repair or planned refactor --> | <!-- direct fix/debt/ExecPlan --> | <!-- role --> | <!-- verified locally/not run/blocked --> |

## Cadence and escalation

<!-- TODO(harness): Define the trigger or cadence, responsible role, report location, and conditions that require human judgment. Do not enable automated writes or merges without explicit authority. -->

## Automation decision

OpenAI's case study scheduled Codex maintenance that updated quality grades and opened targeted repair pull requests. Treat that as an explicit repository policy choice, not a default created by this checklist.

| Runner and cadence | Scan/repair scope | Read or write mode | Pull-request and merge authority | Rollback and escalation | Evidence and status |
| --- | --- | --- | --- | --- | --- |
| <!-- TODO(harness): task/agent or N/A --> | <!-- docs or code entropy --> | <!-- report-only/propose/write --> | <!-- explicit boundaries --> | <!-- safe recovery --> | <!-- concise result plus verified locally/not run/blocked --> |
