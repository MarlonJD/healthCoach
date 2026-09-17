# HealthCoach Agent Guide

Deliver the smallest complete change that meets the current request and can be verified. Keep working product behavior intact while adding the next useful increment.

## Start here

- [README.md](README.md): architecture, repository layout, setup, native build commands, and product boundaries.
- [Package.swift](Package.swift): shared library, MCP executable, test target, and pinned dependencies; [HealthCoachKitTests.swift](Packages/HealthCoachKit/Tests/HealthCoachKitTests/HealthCoachKitTests.swift): existing behavior checks.
- [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md): product requirements and design decisions. Historical paths, environment details, and release permissions are not current instructions or fresh authorization.
- [docs/VERIFICATION.md](docs/VERIFICATION.md): recorded evidence and execution limits. Recheck relevant facts before claiming a new result; update only when useful evidence changes.
- [docs/generated/codex-app-server/README.md](docs/generated/codex-app-server/README.md): generated protocol provenance. Regenerate schemas from the documented source instead of editing generated output.

## Preserve the product boundaries

- The iPhone owns user records, the Mac mirrors them and hosts Codex jobs, and the Watch communicates through the iPhone. Keep platform-specific work in the corresponding `Apps/` target and shared behavior in `Packages/HealthCoachKit/`.
- Keep state, validation, synchronization, deterministic summaries, and UI in HealthCoach. Codex provides estimates and proposals. Keep the existing local-first design without adding a backend, account system, cloud database, custom model client, or recommendation engine.
- Reuse Swift concurrency, SwiftUI, GRDB, and the official MCP Swift SDK. Keep domain, persistence, transport, Codex integration, and presentation separate with small interfaces where needed.
- Use synthetic fixtures. Preserve pairing authentication, transactional outboxes, revision checks, and the read-only MCP boundary. Never commit health records, credentials, local databases, or build output.

## Anti-overengineering defaults

- Implement the requested behavior directly. Introduce an abstraction, dependency, configuration option, or service only when a concrete current requirement needs it and existing code or dependencies do not cover it.
- Remove obsolete paths when behavior changes. Do not add speculative compatibility layers, fallback implementations, or migrations.
- Reuse the existing documentation and native commands. Small changes need no new ExecPlan, backlog, coverage matrix, evidence store, checker, CI workflow, or maintenance automation. Use a concise plan only for work whose complexity or risk needs one.
- Add tests that protect meaningful behavior or a demonstrated regression. Documentation-only changes need link and structural checks, not application builds or device runs.
- Stop when the requested outcome and relevant checks pass. Do not expand into unrelated refactors, repeated verification, or additional proof layers.
- Work on the current branch. Branch operations, commits, pushes, and releases require an explicit request for that action; old plan permissions do not authorize them.

## Verification

- For shared Swift changes, run focused tests with `xcrun swift test --filter <test-name>` and the relevant package suite with `xcrun swift test`. Compiling with `swift build --build-tests` alone does not execute tests.
- The two macOS MCP/App Server integration tests currently expect an executable at `.build/out/Products/Debug/healthcoach-mcp`; the App Server test also needs an installed Codex CLI. Check those prerequisites before running the full suite and report unavailable integration coverage explicitly.
- For app changes, use the affected scheme's build command in [README.md](README.md). Use [script/build_and_run.sh](script/build_and_run.sh) only when Mac runtime verification is needed; it builds and launches the companion.
- Review the diff and run `git diff --check`. Report commands, outcomes, and remaining limits briefly. Keep `verified locally`, `not run`, and `blocked` literal; local checks do not establish real-device behavior or release readiness.

## Repository harness

The unmodified [apply-harness-engineering skill](.agents/skills/apply-harness-engineering/SKILL.md) is installed locally at version `0.2.1`. Use it for explicit harness requests; ordinary feature work follows this guide without activating an additional workflow.

Use the MVP workflow and the helper's `adaptive` profile. Governed scaffolding, certification, AI-runtime/evaluation contracts, and production attestation require an explicit request. Bundled templates are reference material, not adopted repository requirements.

Read-only checks from the repository root:

```sh
python3 -B .agents/skills/apply-harness-engineering/scripts/harness.py check --root . --profile adaptive
python3 -B .agents/skills/apply-harness-engineering/scripts/harness.py simplify --preview --root .
```

The helper's filename-based discovery does not recognize `Package.swift` or this repository's existing architecture and plan routes. Treat those advisory findings as discovery limitations; use the authorities above and do not create duplicate files or wrappers just to silence them. Native checks remain the verification authority for application behavior.
