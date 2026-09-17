# Repository Agent Guide

Use this file as a map. Keep detailed explanations in the linked canonical documents.

This file exists only after an explicitly authorized repository adoption. Installing the external Harness Engineering skill does not create, update, or enforce this repository contract.

## Start here

- Repository documentation map: [`docs/index.md`](docs/index.md)
- Current architecture: [`ARCHITECTURE.md`](ARCHITECTURE.md)
- ExecPlan contract: [`docs/PLANS.md`](docs/PLANS.md)
- Active and completed work: [`docs/exec-plans/index.md`](docs/exec-plans/index.md)
- Agent capabilities and verification: [`docs/agent-harness/index.md`](docs/agent-harness/index.md)

## Repository orientation

<!-- TODO(harness): Name the main packages, services, applications, and generated areas. -->

## Working contract

- Read the most local instruction file before editing a subtree.
- Preserve unrelated user changes and follow existing repository conventions.
- Use an ExecPlan for cross-cutting, risky, long-running, or context-loss-sensitive work; small local changes do not need one by default.
- Keep an active ExecPlan as restartable current state, not an execution transcript; record decisions, the next action, and concise observed evidence.
- Validate behavior with the narrowest reliable command first, then run broader required checks.
- A repository-scoped request authorizes ordinary reversible local work. Do not perform external writes, releases, deployments, destructive operations, or branch changes without the authority required by repository and user instructions.
- Complete local engineering when the requested behavior is observed, the focused check passes, the existing native gate (when present) passes, and the diff is reviewed. Report later release or production work separately as `not run` or `blocked`.
- Treat missing project commands, secrets, production access, or human approval as blockers only when the in-scope requested outcome requires them. Never convert a template, placeholder, or local assertion into external evidence.

## Commands

| Intent | Command | Expected evidence |
| --- | --- | --- |
| Install or bootstrap | <!-- TODO(harness): exact command --> | <!-- TODO(harness): success signal --> |
| Focused test | <!-- TODO(harness): exact command --> | <!-- TODO(harness): success signal --> |
| Full test | <!-- TODO(harness): exact command --> | <!-- TODO(harness): success signal --> |
| Lint or format check | <!-- TODO(harness): exact command --> | <!-- TODO(harness): success signal --> |
| Type or build check | <!-- TODO(harness): exact command or N/A with reason --> | <!-- TODO(harness): success signal --> |

## Definition of done

<!-- TODO(harness): State the repository-specific minimum verification, documentation, generated-artifact, and review requirements. -->

## Durable constraints

<!-- TODO(harness): List only proven constraints and link to the detailed source of truth. -->
