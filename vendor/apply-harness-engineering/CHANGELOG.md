# Changelog

## 0.2.1 — 2026-08-31

- Clarify that audit, adopt, repair, simplify, and govern are skill workflow modes rather than MCP tools or helper subcommands.
- Add `harness.py --version` backed by the package `VERSION` file.
- Add the explicit, read-only `simplify --preview` helper for concrete duplicate-authority, duplicate-plan, legacy proof, and unconsumed raw-evidence candidates.
- Keep the standalone package free of MCP or plugin runtime requirements.

## 0.2.0 — 2026-08-31

- Add the read-only, one-file MVP scaffold with a default `mvp` profile; preserve existing `AGENTS.md` files and keep the governed scaffold separate.
- Make zero-change adoption and explicit harness-surface simplification first-class outcomes; prefer reuse, consolidation, and deletion before adding machinery.
- Replace the pre-release `standard`/`full` profiles with adaptive discovery, an MVP scaffold, and one explicit governed contract; keep the 31-row inventory and certification outside normal adaptive checks.
- Reject certification for the MVP scaffold while preserving adaptive/governed audit, check, and certify behavior.
- Remove the unauthenticated semantic-review digest gate, the unused quality scorecard, the empty evidence placeholder, and full-profile routing ceremony.
- Make the skill and target guidance outcome-first: adaptive gaps are nonblocking, local engineering completion is separate from release/production state, and plans/evidence are proportionate and restartable.
- Align governed templates and references around focused, repository, release, and production verification tiers, one cross-repository owning plan, and concise evidence.
- Add behavioral coverage for MVP scaffold actions, parser/profile boundaries, template quality, and package version metadata.

## 0.1.0 — 2026-08-24 (unreleased development baseline)

- Keep package self-checks separate from target-repository template fragments.
- Add package-level contributor documentation and bytecode hygiene.
- Add optional AI-runtime and agent-evaluation contracts for current model/tool workflows.
- Make strict harness attestation an explicit governance profile instead of the default adoption path.
- Keep certification files out of the governed scaffold; certification is not used unless the optional overlay is explicitly requested with `--with-certification`.
- Document GPT-5.5/GPT-5.6 state, tool, multi-agent, caching, and evaluation boundaries without imposing them on unrelated repositories.
