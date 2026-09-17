# Package Architecture

This package has four intentionally separate layers:

| Layer | Owns | Boundary |
| --- | --- | --- |
| Skill contract | [`SKILL.md`](SKILL.md) and [`agents/openai.yaml`](agents/openai.yaml) | Defines invocation, authority, adoption, and reporting behavior; it does not mutate target repositories. |
| Target templates | [`assets/templates/project/`](assets/templates/project/) and [`assets/templates/fragments/`](assets/templates/fragments/) | Provides adaptable repository documents. The default MVP is a concise one-file `AGENTS.md` fragment; the governed bundle is an explicit exact-layout option. |
| Guidance | [`references/`](references/) | Explains source boundaries, plans, assessment, feedback loops, runtime/eval extensions, and the optional, disabled-by-default attestation overlay. |
| Read-only tooling | [`scripts/harness.py`](scripts/harness.py) and [`scripts/build_release_zip.py`](scripts/build_release_zip.py) | Audits, validates, previews concrete simplification candidates, reports package version, or packages a clean snapshot without applying target-project changes. |

The test suite under [`scripts/tests/`](scripts/tests/) exercises parser behavior, MVP/governed scaffold behavior, structured-input hardening, certification integrity, and release packaging. Target repositories provide their own native runtime and gates; evaluation and maintenance contracts are optional and request-driven.
