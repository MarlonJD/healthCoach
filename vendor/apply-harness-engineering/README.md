# Apply Harness Engineering

`apply-harness-engineering` turns the principles from OpenAI's Harness Engineering case study into an explicit, repository-scoped workflow. It helps an agent discover intent, execute within authority, observe behavior, verify outcomes, and leave durable knowledge behind.

Make the repository agent-discoverable and reliably verifiable with the smallest durable change set. Prefer reuse, consolidation, and deletion over new harness machinery.

Package version: `0.2.1` (2026-08-31). Version `0.2.0` is the first tagged release; `0.1.0` is the unreleased development baseline.

The package is deliberately not a generic agent framework. It does not install services, run target-project commands, create CI, schedule maintenance, or certify a repository merely because the skill is installed.

## Interface map

| Surface | Meaning | Available names |
| --- | --- | --- |
| Skill workflow modes | Prompt-level instructions interpreted by Codex; not CLI commands or MCP tools | audit, adopt, repair, simplify, govern |
| Read-only helper CLI | Deterministic local inspection and preview | `--version`, `audit`, `check`, `certify`, `scaffold`, `validate-plan`, `simplify --preview` |
| MCP | Not bundled or required by this standalone skill | none |

This follows the official separation between [Codex skills](https://developers.openai.com/codex/skills) and [MCP tool/context servers](https://developers.openai.com/codex/mcp).

Use `simplify --preview` when a machine-readable candidate list is useful. It only reports concrete review candidates and never removes or edits files; actual simplification still requires an explicit skill request and repository-aware judgment.

## Use it

Invoke the skill for a named repository, then choose the smallest operation that matches the request. Audit, adopt, repair, and simplify reuse existing repository authorities first; governed coverage and certification are explicit opt-ins. An already discoverable and verifiable repository may need zero changes. The default scaffold is only a read-only one-file MVP orientation when an `AGENTS.md` route is actually missing:

```text
$apply-harness-engineering audit <repository>
python3 -B scripts/harness.py scaffold --root <repository>
```

Use `scaffold --profile governed` only when the broader governed documentation contract is in scope. MVP scaffold output contains one possible `AGENTS.md` action and no lifecycle directories; an existing `AGENTS.md` is preserved.

The helper uses `adaptive` (default) or `governed` for `audit` and `check`; `certify` accepts `governed` (default) or `adaptive`. Legacy profile aliases are rejected.

The bundled helper is a read-only cross-check:

```text
python3 -B scripts/harness.py audit --root <repository>
python3 -B scripts/harness.py check --root <repository>
python3 -B scripts/harness.py simplify --preview --root <repository> --format json
python3 -B scripts/harness.py --version
```

Use the target repository's native commands for real setup, tests, runtime exercise, and maintenance. The optional target-project AI-runtime contract covers model snapshots, reasoning settings, Responses state, compaction, prompt caching, tool/MCP permissions, and multi-agent routing when that surface changes. The companion eval contract covers representative tasks, quality, evidence, latency, tokens, and cost only when evaluation is applicable.

Certification is not used by default. Strict `certify` is an opt-in bounded harness attestation for a source/attestation commit pair; it is not a production certificate. Use `scaffold --profile governed --with-certification` and the strict command only when that overlay is explicitly requested; MVP rejects certification. Use provider-backed production attestation only when that external authority is explicitly available.

## Package checks

```text
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests
python3 -B scripts/harness.py check --root .
```

See [`CHANGELOG.md`](CHANGELOG.md) for package changes and [`references/source-boundaries.md`](references/source-boundaries.md) for the distinction between transferable principles and case-study-specific choices.
