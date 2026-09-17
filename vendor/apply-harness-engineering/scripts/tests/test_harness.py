from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
import unittest
import zipfile
from datetime import datetime, timezone
from unittest import mock
from pathlib import Path, PurePosixPath


SCRIPT = Path(__file__).resolve().parents[1] / "harness.py"
SPEC = importlib.util.spec_from_file_location("harness", SCRIPT)
assert SPEC and SPEC.loader
harness = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = harness
SPEC.loader.exec_module(harness)

try:
    from .test_certification_security import CertificationFixture
except ImportError:
    from test_certification_security import CertificationFixture


def put(root: Path, rel: str, text: str) -> Path:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def empty_index() -> str:
    return """# ExecPlan Registry

## Active

| Plan | Owner | State | Updated (UTC) | Current milestone or blocker |
| --- | --- | --- | --- | --- |
<!-- harness:plans:active:start -->
_None._
<!-- harness:plans:active:end -->

## Completed

| Plan | Completed (UTC) | Outcome | Verification |
| --- | --- | --- | --- |
<!-- harness:plans:completed:start -->
_None._
<!-- harness:plans:completed:end -->
"""


def index_with_active(
    *,
    slug: str = "safe-plan",
    title: str = "Verify the repository harness lifecycle",
    owner: str = "platform-team",
    state: str = "implementing",
    updated: str = "2026-07-22",
    milestone: str = "Final validation",
) -> str:
    row = f"| [{title}](active/{slug}.md) | {owner} | {state} | {updated} | {milestone} |"
    return empty_index().replace(
        "_None._\n<!-- harness:plans:active:end -->",
        f"{row}\n<!-- harness:plans:active:end -->",
        1,
    )


def index_with_completed(
    *,
    slug: str = "safe-plan",
    title: str = "Verify the repository harness lifecycle",
    completed: str = "2026-07-22",
    outcome: str = "Harness verified",
    verification: str = "Project check passed",
) -> str:
    row = f"| [{title}](completed/{slug}.md) | {completed} | {outcome} | {verification} |"
    return empty_index().replace(
        "_None._\n<!-- harness:plans:completed:end -->",
        f"{row}\n<!-- harness:plans:completed:end -->",
        1,
    )


def plan_text(
    slug: str = "safe-plan",
    *,
    state: str = "active",
    created: str = "2026-07-20",
    updated: str = "2026-07-22",
    completed: str = "",
    progress: str = "- [x] (2026-07-22 10:30Z) Verified the independently observable increment.",
    extra_artifacts: str = "The focused and broad evidence is recorded below.",
) -> str:
    text = f"""<!-- harness-plan:v1
id: {slug}
status: {state}
created: {created}
updated: {updated}
completed: {completed}
owner: platform-team
-->

# Verify the repository harness lifecycle

Maintain this plan according to the [configured planning policy](../../PLANS.md).

## Purpose / Big Picture

Operators can run the repository validation and directly observe a successful result without relying on previous conversation context.

## Progress

{progress}

## Surprises & Discoveries

The validation surface required no undocumented external dependency. Evidence came from the repository command and its exit status.

## Decision Log

Use the repository-native checker as the durable gate because it remains available without an installed user skill. Date/Author: 2026-07-22 / platform-team.

## Outcomes & Retrospective

The promised harness behavior was exercised from a clean fixture, the expected command returned success, and the result remained observable through its structured report. No user-visible gap remains in this scoped plan; broader release authority remains outside scope.

## Context and Orientation

The policy is in docs/PLANS.md, the lifecycle registry is in docs/exec-plans/index.md, and this file is the restartable execution record.

## Plan of Work

First establish the structural baseline and observe its failure. Then add the narrow repository-native check, rerun focused validation, and finally exercise the complete acceptance command.

## Concrete Steps

From the repository root, run the focused checker and then the full validation command. Both must return exit code zero and a stable success summary.

## Validation and Acceptance

Run the focused checker from the repository root and observe exit code zero with the named harness success message. Run the complete project verification and observe every test pass. Re-run after a clean checkout-equivalent fixture to prove no hidden task state is required.

## Idempotence and Recovery

The checks are read-only and safe to repeat. If a command fails, restore the fixture, rerun the focused reproduction, and keep this plan active until the failure is explained.

## Artifacts and Notes

{extra_artifacts}

## Interfaces and Dependencies

The stable interfaces are the repository-local validation command, Markdown authority paths, process exit status, and the structured finding schema.

## Revision History

- (2026-07-22 10:30Z) Change: Recorded final scoped evidence. Reason: Make completion restartable and auditable.
"""
    return text


def tree_fingerprint(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[rel] = f"symlink:{os.readlink(path)}"
        elif path.is_file():
            result[rel] = hashlib.sha256(path.read_bytes()).hexdigest()
        elif path.is_dir():
            result[rel] = "directory"
    return result


CERT_COMMIT = "0123456789abcdef0123456789abcdef01234567"
CERT_NOW = datetime(2026, 7, 23, 12, 0, tzinfo=timezone.utc)


def evidence_record(
    capability: str,
    *,
    environment: str = "ci",
    command: str = "make verify-harness",
    result: str = "passed",
    observed_at: str = "2026-07-23T11:00:00Z",
    commit: str = CERT_COMMIT,
) -> str:
    return json.dumps(
        {
            "schema_version": 1,
            "repository_commit": commit,
            "capabilities": [capability],
            "environment": environment,
            "command": command,
            "exit_code": 0 if result == "passed" else None,
            "observed_at": observed_at,
            "result": result,
            "artifacts": ["ci-job:immutable-12345"],
        },
        indent=2,
    )


def install_legacy_v1_production_claim_fixture(root: Path) -> dict[str, object]:
    template = (
        harness.TEMPLATE_ROOT / "docs/agent-harness/coverage-matrix.md"
    ).read_text(encoding="utf-8")
    rows, _, _, _ = harness.coverage_table_rows(template)
    coverage_lines = [
        "# Harness Engineering Coverage Matrix",
        "",
        "| Source principle or capability | Repository implementation | Required evidence | Status and reason |",
        "| --- | --- | --- | --- |",
    ]
    production_identity = harness.normalize_coverage_identity(
        "Release, deployment, and production actions require repository-local authority"
    )
    for index, row in enumerate(rows):
        filename = f"capability-{index:02d}.json"
        environment = (
            "production"
            if harness.normalize_coverage_identity(row.identity) == production_identity
            else "ci"
        )
        put(
            root,
            f"docs/agent-harness/evidence/{filename}",
            evidence_record(row.identity, environment=environment),
        )
        coverage_lines.append(
            f"| {row.identity} | Project-native implementation | Observed behavior | "
            f"verified — [fresh evidence](evidence/{filename}) |"
        )
    coverage_text = "\n".join(coverage_lines) + "\n"
    put(root, "docs/agent-harness/coverage-matrix.md", coverage_text)

    named_records = {
        "project-native-gate.json": (
            harness.PROJECT_GATE_CAPABILITY,
            "ci",
            "make verify-harness",
        ),
        "continuous-maintenance.json": (
            harness.MAINTENANCE_CAPABILITY,
            "ci",
            "make maintain-harness",
        ),
        "production-approval.json": (
            harness.PRODUCTION_APPROVAL_CAPABILITY,
            "production",
            "release-approval verify immutable-approval-123",
        ),
        "production-rollback.json": (
            harness.PRODUCTION_ROLLBACK_CAPABILITY,
            "production",
            "release-rollback verify immutable-drill-123",
        ),
    }
    for filename, (capability, environment, command) in named_records.items():
        put(
            root,
            f"docs/agent-harness/evidence/{filename}",
            evidence_record(
                capability,
                environment=environment,
                command=command,
            ),
        )

    manifest: dict[str, object] = {
        "schema_version": 1,
        "claim": "production-ready",
        "profile": "adaptive",
        "repository_commit": CERT_COMMIT,
        "environment": "production",
        "issued_at": "2026-07-23T11:30:00Z",
        "expires_at": "2026-07-24T11:30:00Z",
        "coverage_sha256": hashlib.sha256(coverage_text.encode()).hexdigest(),
        "evidence_root": "docs/agent-harness/evidence",
        "project_native_gate": {
            "command": "make verify-harness",
            "evidence": "docs/agent-harness/evidence/project-native-gate.json",
        },
        "maintenance": {
            "command": "make maintain-harness",
            "triggers": ["pull_request", "push", "schedule"],
            "max_age_hours": 48,
            "evidence": "docs/agent-harness/evidence/continuous-maintenance.json",
        },
        "production_authority": {
            "owner": "release-engineering",
            "approval_evidence": "docs/agent-harness/evidence/production-approval.json",
            "rollback_evidence": "docs/agent-harness/evidence/production-rollback.json",
        },
    }
    put(
        root,
        harness.CERTIFICATION_REL,
        json.dumps(manifest, indent=2),
    )
    return manifest


class HarnessTests(unittest.TestCase):
    def make_root(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        return temporary, Path(temporary.name)

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            text=True,
            capture_output=True,
            check=False,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )

    def install_governed_templates(self, root: Path) -> None:
        for rel in harness.GOVERNED_FILES:
            source = harness.TEMPLATE_ROOT / rel
            target = root / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        for rel in harness.MANAGED_DIRS:
            (root / rel).mkdir(parents=True, exist_ok=True)

    def install_plan_lifecycle(self, root: Path, index_rel: str = "docs/exec-plans/index.md") -> None:
        put(root, "docs/PLANS.md", "# Plans\n\nRepository planning authority.\n")
        put(root, index_rel, empty_index())
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"exec_plan_index": index_rel},
                }
            ),
        )
        index_parent = (root / index_rel).parent
        (index_parent / "active").mkdir(parents=True, exist_ok=True)
        (index_parent / "completed").mkdir(parents=True, exist_ok=True)

    def test_helper_source_contains_no_filesystem_mutation_primitives(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        forbidden = (
            ".write_text(",
            ".write_bytes(",
            ".mkdir(",
            ".unlink(",
            ".rmdir(",
            "os.replace(",
            "os.remove(",
            "os.unlink(",
            "tempfile.mkstemp(",
            "shutil.move(",
            "shutil.copy",
        )
        for token in forbidden:
            self.assertNotIn(token, source)
        self.assertNotIn("--apply", source)

    def test_all_helper_commands_are_read_only(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "AGENTS.md", "# Map\n")
        put(root, "ARCHITECTURE.md", "# Architecture\n")
        self.install_plan_lifecycle(root)
        put(root, "docs/exec-plans/active/safe-plan.md", plan_text())
        put(
            root,
            "docs/exec-plans/index.md",
            empty_index().replace(
                "_None._\n<!-- harness:plans:active:end -->",
                "| [Verify](active/safe-plan.md) | platform-team | implementing | 2026-07-22 | Final validation |\n<!-- harness:plans:active:end -->",
                1,
            ),
        )
        before = tree_fingerprint(root)
        commands = (
            ("audit", "--root", str(root), "--allow-non-git"),
            ("check", "--root", str(root), "--allow-non-git"),
            (
                "certify",
                "--root",
                str(root),
                "--allow-non-git",
                "--profile",
                "adaptive",
                "--commit",
                CERT_COMMIT,
            ),
            (
                "scaffold",
                "--root",
                str(root),
                "--allow-non-git",
                "--profile",
                "governed",
            ),
            (
                "validate-plan",
                "--root",
                str(root),
                "--allow-non-git",
                "--slug",
                "safe-plan",
                "--state",
                "active",
                "--completion",
            ),
            (
                "simplify",
                "--preview",
                "--root",
                str(root),
                "--allow-non-git",
            ),
        )
        for command in commands:
            self.run_cli(*command)
            self.assertEqual(before, tree_fingerprint(root), command)

    def test_adaptive_audit_preserves_equivalent_authorities(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "AGENTS.md", "# Guide\n\nUse the test command.\n")
        put(root, "docs/adr/0001.md", "# Boundary\n")
        put(root, "planning/PLAN_POLICY.md", "# Planning\n")
        put(root, "tests/test_example.py", "# fixture\n")
        report = harness.audit_repository(root, "adaptive", "audit")
        self.assertEqual(0, report.summary()["errors"])
        self.assertEqual(0, report.summary()["warnings"])
        ids = {item.id for item in report.findings}
        self.assertTrue({"CAP001", "CAP002", "CAP003", "CAP004"}.issubset(ids))

    def test_alternative_authority_with_stale_fallback_link_is_reported(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "AGENTS.md", "# Guide\n\n[Plans](docs/PLANS.md)\n")
        put(root, "ARCHITECTURE.md", "# Architecture\n")
        put(root, "planning/PLAN_POLICY.md", "# Planning\n")
        put(root, "tests/test_example.py", "# fixture\n")
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"planning": "planning/PLAN_POLICY.md"},
                }
            ),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("ROUTE001", {item.id for item in report.findings})

    def test_configured_exec_plan_index_is_honored(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "AGENTS.md", "# Guide\n")
        put(root, "ARCHITECTURE.md", "# Architecture\n")
        put(root, "planning/PLAN_POLICY.md", "# Planning\n")
        put(root, "tests/test_example.py", "# fixture\n")
        put(root, "planning/exec-plans/index.md", empty_index())
        (root / "planning/exec-plans/active").mkdir(parents=True)
        (root / "planning/exec-plans/completed").mkdir(parents=True)
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {
                        "planning": "planning/PLAN_POLICY.md",
                        "exec_plan_index": "planning/exec-plans/index.md",
                    },
                }
            ),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        relevant = [
            item
            for item in report.findings
            if item.id.startswith("INDEX") or item.id.startswith("PLAN")
        ]
        self.assertEqual([], relevant)

    def test_validate_plan_uses_both_configured_lifecycle_authorities(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "planning/PLAN_POLICY.md", "# Planning\n")
        put(root, "planning/exec-plans/index.md", index_with_active())
        put(
            root,
            "planning/exec-plans/active/safe-plan.md",
            plan_text().replace("../../PLANS.md", "../../PLAN_POLICY.md"),
        )
        (root / "planning/exec-plans/completed").mkdir(parents=True)
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {
                        "planning": "planning/PLAN_POLICY.md",
                        "exec_plan_index": "planning/exec-plans/index.md",
                    },
                }
            ),
        )
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertEqual([], [item for item in report.findings if item.severity == "error"])

    def test_mvp_scaffold_is_one_file_preview_and_preserves_existing_file(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "AGENTS.md", "custom\n")
        before = tree_fingerprint(root)
        report = harness.scaffold_preview(root)
        self.assertEqual(before, tree_fingerprint(root))
        self.assertEqual([{"action": "preserve", "path": "AGENTS.md"}], report.actions)
        self.assertEqual([], report.findings)

        empty_temporary, empty_root = self.make_root()
        self.addCleanup(empty_temporary.cleanup)
        empty_report = harness.scaffold_preview(empty_root)
        self.assertEqual(
            [{"action": "would-create", "path": "AGENTS.md"}],
            empty_report.actions,
        )
        self.assertEqual([], empty_report.findings)
        self.assertEqual({}, tree_fingerprint(empty_root))

    def test_adaptive_zero_change_is_a_valid_observed_adoption(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "AGENTS.md", "# Guide\n\nRun the existing check.\n")
        before = tree_fingerprint(root)
        report = harness.audit_repository(root, "adaptive", "audit")
        self.assertEqual(0, report.summary()["errors"])
        self.assertEqual(before, tree_fingerprint(root))

    def test_mvp_scaffold_has_no_managed_directories_or_extra_actions(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        report = harness.scaffold_preview(root, "mvp")
        self.assertEqual(1, len(report.actions))
        self.assertEqual("AGENTS.md", report.actions[0]["path"])
        self.assertNotIn("docs/exec-plans/active", {item["path"] for item in report.actions})
        self.assertNotIn("docs/exec-plans/completed", {item["path"] for item in report.actions})

    def test_scaffold_mvp_fragment_is_self_contained_and_link_safe(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        fragment_path = (
            harness.SKILL_ROOT
            / "assets"
            / "templates"
            / "fragments"
            / "AGENTS.mvp.md"
        )
        fragment = fragment_path.read_text(encoding="utf-8")
        self.assertFalse(harness.has_scaffold_placeholder("AGENTS.md", fragment))
        self.assertNotIn("TODO", fragment)
        self.assertNotIn("<replace", fragment)
        target = put(root, "AGENTS.md", fragment)
        report = harness.Report(command="check", root=str(root.resolve()))
        harness.check_text_links(report, root, target, fragment)
        self.assertEqual([], [item for item in report.findings if item.severity == "error"])

    def test_mvp_certification_is_rejected_without_mutation(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        before = tree_fingerprint(root)
        with self.assertRaises(harness.SafeRefusal):
            harness.scaffold_preview(root, "mvp", include_certification=True)
        self.assertEqual(before, tree_fingerprint(root))
        result = self.run_cli(
            "scaffold",
            "--root",
            str(root),
            "--allow-non-git",
            "--profile",
            "mvp",
            "--with-certification",
            "--format",
            "json",
        )
        self.assertEqual(2, result.returncode)
        self.assertEqual("CLI001", json.loads(result.stdout)["findings"][0]["id"])
        self.assertEqual(before, tree_fingerprint(root))

    def test_profile_matrix_keeps_audit_check_certify_and_scaffold_distinct(self) -> None:
        parser = harness.build_parser()
        self.assertEqual("adaptive", parser.parse_args(["audit"]).profile)
        self.assertEqual("adaptive", parser.parse_args(["check"]).profile)
        self.assertEqual("governed", parser.parse_args(["certify", "--commit", CERT_COMMIT]).profile)
        self.assertEqual("adaptive", parser.parse_args(["certify", "--profile", "adaptive", "--commit", CERT_COMMIT]).profile)
        self.assertEqual("mvp", parser.parse_args(["scaffold"]).profile)
        self.assertEqual("governed", parser.parse_args(["scaffold", "--profile", "governed"]).profile)
        for command in ("audit", "check", "certify"):
            args = [command, "--profile", "standard"]
            if command == "certify":
                args += ["--commit", CERT_COMMIT]
            result = self.run_cli(*args, "--allow-non-git")
            self.assertEqual(2, result.returncode, command)
            mvp_args = [command, "--profile", "mvp"]
            if command == "certify":
                mvp_args += ["--commit", CERT_COMMIT]
            mvp_result = self.run_cli(*mvp_args, "--allow-non-git")
            self.assertEqual(2, mvp_result.returncode, f"{command}:mvp")
        for profile in ("standard", "full"):
            result = self.run_cli(
                "scaffold", "--profile", profile, "--allow-non-git"
            )
            self.assertEqual(2, result.returncode, profile)

    def test_cli_version_reports_the_package_authority(self) -> None:
        result = self.run_cli("--version")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("harness.py 0.2.1", result.stdout.strip())
        self.assertEqual("0.2.1", harness.package_version())

    def test_simplify_requires_explicit_preview_without_mutation(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "AGENTS.md", "# Guide\n")
        before = tree_fingerprint(root)
        result = self.run_cli(
            "simplify",
            "--root",
            str(root),
            "--allow-non-git",
            "--format",
            "json",
        )
        self.assertEqual(2, result.returncode)
        self.assertEqual("CLI000", json.loads(result.stdout)["findings"][0]["id"])
        self.assertEqual(before, tree_fingerprint(root))

    def test_simplify_preview_reports_only_concrete_review_candidates(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "ARCHITECTURE.md", "# Legacy architecture\n")
        put(root, "docs/architecture.md", "# Canonical architecture\n")
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"architecture": "docs/architecture.md"},
                }
            ),
        )
        put(root, "docs/QUALITY_SCORE.md", "# Legacy scorecard\n")
        put(root, "docs/agent-harness/evidence/run.jsonl", "{}\n")
        put(root, "docs/exec-plans/index.md", "# Plans\n")
        put(root, "docs/exec-plans/active/shared.md", "# Active\n")
        put(root, "docs/exec-plans/completed/shared.md", "# Completed\n")
        put(
            root,
            "docs/legacy-plan.md",
            "# Legacy plan\n\n Semantic-Review: reviewer=agent; reviewed-at=2026-01-01 00:00Z\n",
        )
        before = tree_fingerprint(root)

        result = self.run_cli(
            "simplify",
            "--preview",
            "--root",
            str(root),
            "--allow-non-git",
            "--format",
            "json",
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        payload = json.loads(result.stdout)
        actions = {(item["action"], item["path"]) for item in payload["actions"]}
        self.assertTrue(
            {
                ("review-consolidate-authority", "ARCHITECTURE.md"),
                ("review-remove-legacy", "docs/QUALITY_SCORE.md"),
                ("review-raw-evidence", "docs/agent-harness/evidence/run.jsonl"),
                ("review-consolidate-plan", "docs/exec-plans/active/shared.md"),
                ("review-remove-proof-of-proof", "docs/legacy-plan.md"),
            }.issubset(actions)
        )
        self.assertTrue(all(item.get("reason") for item in payload["actions"]))
        self.assertEqual(before, tree_fingerprint(root))

    def test_simplify_preview_preserves_evidence_with_a_certification_consumer(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "docs/agent-harness/evidence/run.jsonl", "{}\n")
        put(root, harness.CERTIFICATION_REL, "{}\n")
        report = harness.simplification_preview(root)
        self.assertNotIn(
            "review-raw-evidence",
            {item["action"] for item in report.actions},
        )

    def test_simplify_preview_does_not_follow_evidence_symlinks(self) -> None:
        temporary, root = self.make_root()
        outside_temporary, outside = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.addCleanup(outside_temporary.cleanup)
        put(outside, "run.jsonl", "{}\n")
        (root / "docs/agent-harness").mkdir(parents=True)
        (root / "docs/agent-harness/evidence").symlink_to(
            outside,
            target_is_directory=True,
        )
        report = harness.simplification_preview(root)
        self.assertNotIn(
            "review-raw-evidence",
            {item["action"] for item in report.actions},
        )

    def test_simplify_preview_reports_no_safe_candidates_without_guessing(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        before = tree_fingerprint(root)
        report = harness.simplification_preview(root)
        self.assertEqual([], report.actions)
        self.assertIn("SIMPLIFY000", {item.id for item in report.findings})
        self.assertEqual(before, tree_fingerprint(root))

    def test_governed_bundle_excludes_optional_resources(self) -> None:
        self.assertNotIn("docs/agent-harness/evidence/.gitkeep", harness.GOVERNED_FILES)
        self.assertNotIn("docs/QUALITY_SCORE.md", harness.GOVERNED_FILES)
        self.assertFalse(
            (harness.TEMPLATE_ROOT / "docs/agent-harness/evidence/.gitkeep").exists()
        )
        self.assertFalse((harness.TEMPLATE_ROOT / "docs/QUALITY_SCORE.md").exists())
        self.assertFalse(
            (harness.SKILL_ROOT / "assets/templates/fragments/docs-index.full.md").exists()
        )
        self.assertNotIn("DESIGN.md", {Path(path).name for path in harness.GOVERNED_FILES})
        self.assertNotIn("FRONTEND.md", {Path(path).name for path in harness.GOVERNED_FILES})
        self.assertNotIn("PRODUCT_SENSE.md", {Path(path).name for path in harness.GOVERNED_FILES})

    def test_governed_check_requires_canonical_coverage_but_adaptive_does_not(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "AGENTS.md", "# Guide\n")
        custom_coverage = put(
            root,
            "custom/coverage.md",
            "# Coverage\n\n| Capability | Implementation | Evidence | Status and reason |\n| --- | --- | --- | --- |\n| Orientation | AGENTS.md | local check | verified — route was exercised locally |\n",
        )
        put(
            root,
            harness.CONFIG_REL,
            json.dumps({"schema_version": 1, "authorities": {"coverage": "custom/coverage.md"}}),
        )
        adaptive = harness.audit_repository(root, "adaptive", "check")
        self.assertNotIn("COVERAGE003", {item.id for item in adaptive.findings})
        governed = harness.audit_repository(root, "governed", "check")
        self.assertIn("PATH001", {item.id for item in governed.findings})
        report = harness.Report(command="check", root=str(root.resolve()))
        harness.validate_coverage(report, root, custom_coverage, require_canonical_rows=True)
        self.assertIn("COVERAGE003", {item.id for item in report.findings})

    def test_validate_plan_has_no_semantic_review_flag_or_findings(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        result = self.run_cli(
            "validate-plan",
            "--root",
            str(root),
            "--allow-non-git",
            "--slug",
            "safe-plan",
            "--state",
            "active",
            "--semantic-review",
            "--format",
            "json",
        )
        self.assertEqual(2, result.returncode)
        self.assertEqual("CLI000", json.loads(result.stdout)["findings"][0]["id"])
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("SemanticReviewAttestation", source)
        self.assertNotIn("PLAN013", source)
        self.assertNotIn("PLAN016", source)

    def test_certification_is_disabled_and_not_scaffolded_by_default(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)

        self.assertNotIn("docs/agent-harness/certification.md", harness.GOVERNED_FILES)
        self.assertNotIn(harness.CERTIFICATION_REL, harness.GOVERNED_FILES)

        default_report = harness.scaffold_preview(root, "governed")
        default_paths = {item["path"] for item in default_report.actions}
        self.assertNotIn("docs/agent-harness/certification.md", default_paths)
        self.assertNotIn(harness.CERTIFICATION_REL, default_paths)

        opted_in_report = harness.scaffold_preview(
            root,
            "governed",
            include_certification=True,
        )
        opted_in_actions = {
            item["path"]: item["action"] for item in opted_in_report.actions
        }
        self.assertEqual(
            "would-create",
            opted_in_actions["docs/agent-harness/certification.md"],
        )
        self.assertEqual(
            "would-create",
            opted_in_actions[harness.CERTIFICATION_REL],
        )

        config = json.loads(
            (
                harness.TEMPLATE_ROOT
                / "docs/agent-harness/config.json"
            ).read_text(encoding="utf-8")
        )
        self.assertNotIn("certification", config["authorities"])

    def test_default_authority_map_does_not_require_certification(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        report = harness.Report(command="audit", root=str(root))
        authorities = harness.load_authorities(root, report)
        self.assertNotIn("certification", authorities)
        self.assertNotIn("certification", harness.DEFAULT_AUTHORITIES)

    def test_scaffold_rejects_broken_final_symlink(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        (root / "AGENTS.md").symlink_to(root / "missing-outside-target.md")
        with self.assertRaises(harness.SafeRefusal):
            harness.scaffold_preview(root, "mvp")

    def test_governed_templates_have_no_broken_links(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_governed_templates(root)
        report = harness.audit_repository(root, "governed", "check")
        self.assertEqual([], [item for item in report.findings if item.severity == "error"])
        self.assertIn("DOC001", {item.id for item in report.findings})

    def test_existing_agents_merge_fragment_routes_governed_authorities(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_governed_templates(root)
        fragment = (
            harness.SKILL_ROOT
            / "assets"
            / "templates"
            / "fragments"
            / "AGENTS.harness.md"
        ).read_text(encoding="utf-8")
        put(root, "AGENTS.md", "# Existing repository instructions\n\n" + fragment)
        report = harness.audit_repository(root, "governed", "check")
        self.assertNotIn("ROUTE002", {item.id for item in report.findings})

    def test_index_escape_and_malformed_rows_are_findings_not_exceptions(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        malformed = empty_index().replace(
            "_None._\n<!-- harness:plans:active:end -->",
            "[Escape](../escape.md)\n<!-- harness:plans:active:end -->",
            1,
        )
        put(root, "docs/exec-plans/index.md", malformed)
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("INDEX002", {item.id for item in report.findings})

    def test_index_rejects_cross_region_duplicate_and_wrong_shape(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        index = empty_index()
        index = index.replace(
            "_None._\n<!-- harness:plans:active:end -->",
            "| [Plan](active/safe-plan.md) | team | implementing | 2026-07-22 | Work |\n<!-- harness:plans:active:end -->",
            1,
        )
        index = index.replace(
            "_None._\n<!-- harness:plans:completed:end -->",
            "| [Plan](active/safe-plan.md) | 2026-07-22 | Done | Proof | extra |\n<!-- harness:plans:completed:end -->",
            1,
        )
        put(root, "docs/exec-plans/index.md", index)
        report = harness.audit_repository(root, "adaptive", "check")
        ids = {item.id for item in report.findings}
        self.assertIn("INDEX002", ids)

    def test_index_row_must_mirror_plan_title_owner_and_date(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(root, "docs/exec-plans/active/safe-plan.md", plan_text())
        index = empty_index().replace(
            "_None._\n<!-- harness:plans:active:end -->",
            "| [Wrong title](active/safe-plan.md) | wrong-team | implementing | 2026-07-21 | Work |\n<!-- harness:plans:active:end -->",
            1,
        )
        put(root, "docs/exec-plans/index.md", index)
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("INDEX006", {item.id for item in report.findings})

    def test_active_plan_placeholders_are_visible_before_completion(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(
            root,
            "docs/exec-plans/active/safe-plan.md",
            plan_text(extra_artifacts="TODO replace this artifact with evidence."),
        )
        report = harness.validate_plan_command(
            root, "safe-plan", "active", False
        )
        finding = next(item for item in report.findings if item.id == "PLAN008")
        self.assertEqual("warning", finding.severity)

    def test_completion_gate_catches_nested_unchecked_and_uppercase_timestamp(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        progress = "- [X] Finished without a timestamp.\n  - [ ] Required nested follow-up."
        put(root, "docs/exec-plans/active/safe-plan.md", plan_text(progress=progress))
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        ids = {item.id for item in report.findings}
        self.assertIn("PLAN004", ids)
        self.assertIn("PLAN005", ids)

    def test_completion_gate_checks_links_from_completed_location(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(root, "docs/exec-plans/active/peer.md", "# Peer\n")
        put(
            root,
            "docs/exec-plans/active/safe-plan.md",
            plan_text(extra_artifacts="Current peer evidence is [here](peer.md)."),
        )
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN014", {item.id for item in report.findings})

    def test_valid_completion_gate_passes(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(root, "docs/exec-plans/active/safe-plan.md", plan_text())
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertEqual([], [item for item in report.findings if item.severity == "error"])

    def test_validate_plan_rejects_orphan_not_listed_in_index(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(root, "docs/exec-plans/active/safe-plan.md", plan_text())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN011", {item.id for item in report.findings})

    def test_completion_relocation_treats_active_source_as_missing(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(
            root,
            "docs/exec-plans/active/safe-plan.md",
            plan_text(extra_artifacts="The plan links to [its active source](../active/safe-plan.md)."),
        )
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN014", {item.id for item in report.findings})

    def test_same_plan_id_cannot_exist_in_both_lifecycle_states(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(root, "docs/exec-plans/active/safe-plan.md", plan_text())
        put(
            root,
            "docs/exec-plans/completed/safe-plan.md",
            plan_text(
                state="completed",
                completed="2026-07-22",
            ),
        )
        index = index_with_active().replace(
            "_None._\n<!-- harness:plans:completed:end -->",
            "| [Verify the repository harness lifecycle](completed/safe-plan.md) | 2026-07-22 | Harness verified | Project check passed |\n"
            "<!-- harness:plans:completed:end -->",
            1,
        )
        put(root, "docs/exec-plans/index.md", index)
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("INDEX003", {item.id for item in report.findings})

    def test_completion_catches_ordered_preamble_work(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text().replace(
            "-->\n\n# Verify",
            "-->\n\n1. [ ] Undeclared preamble work remains.\n\n# Verify",
            1,
        )
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN006", {item.id for item in report.findings})

    def test_completion_catches_four_space_nested_task(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        progress = (
            "- [x] (2026-07-22 10:30Z) Parent work is complete.\n"
            "    - [ ] Required nested follow-up remains."
        )
        put(root, "docs/exec-plans/active/safe-plan.md", plan_text(progress=progress))
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN005", {item.id for item in report.findings})

    def test_invalid_backtick_info_string_cannot_hide_progress(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        progress = (
            "- [x] (2026-07-22 10:30Z) Parent work is complete.\n"
            "```bad`info\n"
            "- [ ] Required visible follow-up remains.\n"
            "```"
        )
        put(root, "docs/exec-plans/active/safe-plan.md", plan_text(progress=progress))
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN005", {item.id for item in report.findings})

    def test_tab_indented_backticks_cannot_hide_progress(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        progress = (
            "- [x] (2026-07-22 10:30Z) Parent work is complete.\n"
            "\t```\n"
            "- [ ] Required visible follow-up remains."
        )
        put(root, "docs/exec-plans/active/safe-plan.md", plan_text(progress=progress))
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN005", {item.id for item in report.findings})

    def test_tab_indented_fence_cannot_close_over_hidden_plan(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text().replace(
            "-->\n\n# Verify",
            "-->\n\n```\n\t```\n# Verify",
            1,
        )
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN003", {item.id for item in report.findings})

    def test_blockquoted_unchecked_progress_is_live_work(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        progress = (
            "- [x] (2026-07-22 10:30Z) Parent work is complete.\n"
            "> - [ ] Required quoted follow-up remains."
        )
        put(root, "docs/exec-plans/active/safe-plan.md", plan_text(progress=progress))
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN005", {item.id for item in report.findings})

    def test_indented_code_checkbox_is_not_live_work(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(
            root,
            "docs/exec-plans/active/safe-plan.md",
            plan_text(extra_artifacts="Example syntax only:\n\n    - [ ] not live work"),
        )
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertNotIn("PLAN006", {item.id for item in report.findings})

    def test_reference_style_planning_link_resolves(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text().replace(
            "[configured planning policy](../../PLANS.md)",
            "[configured planning policy][plans]",
            1,
        )
        text += "\n[plans]: ../../PLANS.md\n"
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        ids = {item.id for item in report.findings}
        self.assertNotIn("PLAN007", ids)
        self.assertNotIn("PLAN015", ids)

    def test_first_duplicate_reference_definition_controls_resolution(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text().replace(
            "[configured planning policy](../../PLANS.md)",
            "[configured planning policy][plans]",
            1,
        )
        text += "\n[plans]: missing.md\n[plans]: ../../PLANS.md\n"
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        ids = {item.id for item in report.findings}
        self.assertIn("PLAN007", ids)
        self.assertIn("PLAN015", ids)

    def test_nested_bracket_link_is_checked(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(
            root,
            "docs/exec-plans/active/safe-plan.md",
            plan_text(extra_artifacts="Required [evidence [details]](missing.md) is absent."),
        )
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", False
        )
        self.assertIn("PLAN015", {item.id for item in report.findings})

    def test_policy_image_does_not_satisfy_navigation_requirement(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text().replace(
            "[configured planning policy](../../PLANS.md)",
            "![configured planning policy](../../PLANS.md)",
            1,
        )
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN007", {item.id for item in report.findings})

    def test_missing_reference_and_bad_anchor_are_reported(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(
            root,
            "docs/exec-plans/active/safe-plan.md",
            plan_text(
                extra_artifacts="Missing [reference][no-definition] and [heading](#absent-heading)."
            ),
        )
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", False
        )
        link_findings = [item for item in report.findings if item.id == "PLAN015"]
        self.assertGreaterEqual(len(link_findings), 2)

    def test_escaped_and_commented_links_do_not_count(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        artifacts = r"\[literal](missing.md)" + "\n<!-- [example](also-missing.md) -->"
        put(
            root,
            "docs/exec-plans/active/safe-plan.md",
            plan_text(extra_artifacts=artifacts),
        )
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", False
        )
        self.assertNotIn("PLAN015", {item.id for item in report.findings})

    def test_crlf_plan_metadata_is_valid(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(
            root,
            "docs/exec-plans/active/safe-plan.md",
            plan_text().replace("\n", "\r\n"),
        )
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", False
        )
        self.assertNotIn("PLAN002", {item.id for item in report.findings})

    def test_placeholder_detection_is_specific_and_catches_template_prose(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        legitimate = plan_text(
            extra_artifacts="The change removes TODO token handling from the parser."
        )
        put(root, "docs/exec-plans/active/safe-plan.md", legitimate)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", False
        )
        self.assertNotIn("PLAN008", {item.id for item in report.findings})

        template_prose = plan_text(
            extra_artifacts="Not completed. Compare the final result with the initial promise."
        )
        put(root, "docs/exec-plans/active/safe-plan.md", template_prose)
        report = harness.validate_plan_command(
            root, "safe-plan", "active", False
        )
        self.assertIn("PLAN008", {item.id for item in report.findings})

    def test_completion_rejects_tbd_and_code_placeholders(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        artifacts = "TBD: final evidence.\n\n```text\n<replace-command>\n```"
        put(
            root,
            "docs/exec-plans/active/safe-plan.md",
            plan_text(extra_artifacts=artifacts),
        )
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN008", {item.id for item in report.findings})

    def test_unclosed_html_comment_cannot_hide_plan_structure(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text().replace("\n# Verify", "\n<!--\n# Verify", 1)
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN003", {item.id for item in report.findings})

    def test_extra_h2_is_rejected_by_exact_plan_schema(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text().replace(
            "## Artifacts and Notes",
            "## Extra local section\n\nUnexpected H2.\n\n## Artifacts and Notes",
            1,
        )
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", False
        )
        self.assertIn("PLAN003", {item.id for item in report.findings})

    def test_plan_requires_one_leading_h1(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text().replace(
            "## Context and Orientation",
            "# Second title\n\n## Context and Orientation",
            1,
        )
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", False
        )
        self.assertIn("PLAN003", {item.id for item in report.findings})

    def test_every_revision_entry_must_be_structured(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text() + "\n- Untimestamped revision without fields.\n"
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN010", {item.id for item in report.findings})

    def test_revision_validation_handles_many_bad_entries_linearly(self) -> None:
        text = "- (2026-01-01 00:00Z) Change: missing reason\n" * 5000
        self.assertFalse(harness.revision_history_is_structured(text))

    def test_marker_only_index_is_not_navigable(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "docs/PLANS.md", "# Plans\n")
        put(
            root,
            "docs/exec-plans/index.md",
            f"{harness.ACTIVE_START}\n_None._\n{harness.ACTIVE_END}\n"
            f"{harness.COMPLETED_START}\n_None._\n{harness.COMPLETED_END}\n",
        )
        (root / "docs/exec-plans/active").mkdir(parents=True)
        (root / "docs/exec-plans/completed").mkdir(parents=True)
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {
                        "exec_plan_index": "docs/exec-plans/index.md"
                    },
                }
            ),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("INDEX001", {item.id for item in report.findings})

    def test_commented_index_structure_is_not_navigable(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "docs/PLANS.md", "# Plans\n")
        index = f"""<!--
# ExecPlan Registry
## Active
| Plan | Owner | State | Updated (UTC) | Current milestone or blocker |
| --- | --- | --- | --- | --- |
-->
{harness.ACTIVE_START}
_None._
{harness.ACTIVE_END}
<!--
## Completed
| Plan | Completed (UTC) | Outcome | Verification |
| --- | --- | --- | --- |
-->
{harness.COMPLETED_START}
_None._
{harness.COMPLETED_END}
"""
        put(root, "docs/exec-plans/index.md", index)
        (root / "docs/exec-plans/active").mkdir(parents=True)
        (root / "docs/exec-plans/completed").mkdir(parents=True)
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {
                        "exec_plan_index": "docs/exec-plans/index.md"
                    },
                }
            ),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("INDEX001", {item.id for item in report.findings})

    def test_index_accepts_escaped_pipe_in_prose_cell(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(root, "docs/exec-plans/active/safe-plan.md", plan_text())
        put(
            root,
            "docs/exec-plans/index.md",
            index_with_active(milestone=r"API \| CLI evidence recorded"),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertNotIn("INDEX002", {item.id for item in report.findings})

    def test_completion_requires_living_sections_and_structured_revision(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text()
        text = re.sub(
            r"## Surprises & Discoveries\n.*?(?=\n## Decision Log)",
            "## Surprises & Discoveries\n",
            text,
            flags=re.DOTALL,
        )
        text = re.sub(
            r"## Decision Log\n.*?(?=\n## Outcomes & Retrospective)",
            "## Decision Log\n",
            text,
            flags=re.DOTALL,
        )
        text = re.sub(
            r"## Revision History\n.*\Z",
            "## Revision History\n\nReviewed on (2026-07-22 10:30Z).\n",
            text,
            flags=re.DOTALL,
        )
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        ids = {item.id for item in report.findings}
        self.assertIn("PLAN009", ids)
        self.assertIn("PLAN010", ids)

    def test_public_read_only_apis_refuse_home_root(self) -> None:
        with self.assertRaises(harness.SafeRefusal):
            harness.audit_repository(Path.home(), "adaptive", "audit")
        with self.assertRaises(harness.SafeRefusal):
            harness.scaffold_preview(Path.home(), "mvp")

    def test_unreadable_config_becomes_a_finding(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, harness.CONFIG_REL, "{}")
        report = harness.Report(command="check", root=str(root.resolve()))
        with mock.patch.object(harness, "read_text_safe", side_effect=OSError("denied")):
            harness.load_authorities(root, report)
        self.assertIn("CONFIG001", {item.id for item in report.findings})

    def test_nul_authority_path_is_a_structured_finding(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"coverage": "bad\x00/path.md"},
                }
            ),
        )
        result = self.run_cli(
            "check",
            "--root",
            str(root),
            "--allow-non-git",
            "--format",
            "json",
        )
        self.assertEqual(1, result.returncode)
        self.assertEqual("", result.stderr)
        payload = json.loads(result.stdout)
        self.assertIn("CONFIG002", {item["id"] for item in payload["findings"]})

    @unittest.skipIf(harness.tomllib is None, "requires stdlib tomllib")
    def test_adaptive_discovery_honors_configured_instruction_fallback(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(
            root,
            harness.CODEX_PROJECT_CONFIG_REL,
            'project_doc_fallback_filenames = ["CLAUDE.md"]\n',
        )
        put(root, "CLAUDE.md", "# Repository guide\n\nUse the project checks.\n")
        report = harness.audit_repository(root, "adaptive", "audit")
        capability = next(item for item in report.findings if item.id == "CAP001")
        self.assertEqual("info", capability.severity)
        self.assertEqual("CLAUDE.md", capability.path)
        self.assertIn("CODEXCFG003", {item.id for item in report.findings})

    def test_stale_router_scan_includes_every_mapped_markdown_authority(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "docs/agent-harness/coverage-matrix.md", "# Default coverage\n")
        put(
            root,
            "custom/coverage.md",
            "# Custom coverage\n\n[Stale fallback](../docs/agent-harness/coverage-matrix.md)\n",
        )
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"coverage": "custom/coverage.md"},
                }
            ),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("ROUTE001", {item.id for item in report.findings})

    def test_configured_authority_must_be_reachable_from_root_agents(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "AGENTS.md", "# Guide\n")
        put(root, "custom/coverage.md", "# Coverage\n")
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"coverage": "custom/coverage.md"},
                }
            ),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("ROUTE002", {item.id for item in report.findings})

        put(root, "AGENTS.md", "# Guide\n\n[Coverage](custom/coverage.md)\n")
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertNotIn("ROUTE002", {item.id for item in report.findings})

    def test_authority_routes_respect_the_default_instruction_byte_budget(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "custom/coverage.md", "# Coverage\n")
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"coverage": "custom/coverage.md"},
                }
            ),
        )
        late_route = (
            "# Guide\n\n"
            + ("x" * harness.DEFAULT_PROJECT_DOC_MAX_BYTES)
            + "\n[Coverage](custom/coverage.md)\n"
        )
        put(root, "AGENTS.md", late_route)
        report = harness.audit_repository(root, "adaptive", "check")
        ids = {item.id for item in report.findings}
        self.assertIn("DOC003", ids)
        self.assertIn("ROUTE002", ids)

        early_route = (
            "# Guide\n\n[Coverage](custom/coverage.md)\n"
            + ("x" * harness.DEFAULT_PROJECT_DOC_MAX_BYTES)
        )
        put(root, "AGENTS.md", early_route)
        report = harness.audit_repository(root, "adaptive", "check")
        ids = {item.id for item in report.findings}
        self.assertIn("DOC003", ids)
        self.assertNotIn("ROUTE002", ids)

    @unittest.skipIf(harness.tomllib is None, "requires stdlib tomllib")
    def test_repository_instruction_budget_can_only_tighten_static_routing(self) -> None:
        for declared, filler_size, expected_info in (
            (1024, 1500, False),
            (65536, 40 * 1024, True),
        ):
            with self.subTest(declared=declared):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                put(root, "custom/coverage.md", "# Coverage\n")
                put(
                    root,
                    harness.CONFIG_REL,
                    json.dumps(
                        {
                            "schema_version": 1,
                            "authorities": {"coverage": "custom/coverage.md"},
                        }
                    ),
                )
                put(
                    root,
                    harness.CODEX_PROJECT_CONFIG_REL,
                    f"project_doc_max_bytes = {declared}\n",
                )
                put(
                    root,
                    "AGENTS.md",
                    "# Guide\n\n" + ("x" * filler_size)
                    + "\n[Coverage](custom/coverage.md)\n",
                )
                report = harness.audit_repository(root, "adaptive", "check")
                ids = {item.id for item in report.findings}
                self.assertIn("DOC003", ids)
                self.assertIn("ROUTE002", ids)
                self.assertEqual(expected_info, "CODEXCFG002" in ids)

    @unittest.skipIf(harness.tomllib is None, "requires stdlib tomllib")
    def test_invalid_project_instruction_budgets_fail_closed(self) -> None:
        invalid_values = ("true", "1.5", '"1024"', "0", "-1", "[")
        for value in invalid_values:
            with self.subTest(value=value):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                put(root, "AGENTS.md", "# Guide\n")
                put(
                    root,
                    harness.CODEX_PROJECT_CONFIG_REL,
                    f"project_doc_max_bytes = {value}\n",
                )
                report = harness.audit_repository(root, "adaptive", "check")
                self.assertIn(
                    "CODEXCFG001", {item.id for item in report.findings}
                )

    @unittest.skipIf(harness.tomllib is None, "requires stdlib tomllib")
    def test_instruction_budget_uses_effective_override_and_utf8_prefix(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "custom/coverage.md", "# Coverage\n")
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"coverage": "custom/coverage.md"},
                }
            ),
        )
        put(root, harness.CODEX_PROJECT_CONFIG_REL, "project_doc_max_bytes = 11\n")
        put(root, "AGENTS.md", "# Guide\n\n[Coverage](custom/coverage.md)\n")
        put(
            root,
            "AGENTS.override.md",
            "😀😀😀\n[Coverage](custom/coverage.md)\n",
        )
        report = harness.audit_repository(root, "adaptive", "check")
        ids = {item.id for item in report.findings}
        self.assertIn("DOC003", ids)
        self.assertIn("ROUTE002", ids)

    def test_instructions_authority_cannot_remap_codex_entry_point(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "GUIDE.md", "# Not automatically loaded\n")
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"instructions": "GUIDE.md"},
                }
            ),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("CONFIG005", {item.id for item in report.findings})

    def test_authority_map_without_root_agents_is_a_routing_error(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "custom/coverage.md", "# Coverage\n")
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"coverage": "custom/coverage.md"},
                }
            ),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("ROUTE002", {item.id for item in report.findings})

    def test_nested_agents_are_checked_for_stale_authority_routes(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "AGENTS.md", "# Guide\n\n[Plans](planning/PLAN_POLICY.md)\n")
        put(root, "planning/PLAN_POLICY.md", "# Planning\n")
        put(root, "docs/PLANS.md", "# Old planning fallback\n")
        put(root, "subsystem/AGENTS.md", "# Local guide\n\n[Old plans](../docs/PLANS.md)\n")
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"planning": "planning/PLAN_POLICY.md"},
                }
            ),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        stale = [item for item in report.findings if item.id == "ROUTE001"]
        self.assertTrue(any(item.path == "subsystem/AGENTS.md" for item in stale))

    def test_unreadable_markdown_and_lifecycle_paths_are_findings(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        hidden = root / "hidden"
        hidden.mkdir()
        active = root / "docs/exec-plans/active"
        real_scandir = os.scandir

        def denied(path: object):
            resolved = Path(path).resolve() if not isinstance(path, int) else None
            if resolved in {hidden.resolve(), active.resolve()}:
                raise PermissionError(13, "denied", str(resolved))
            return real_scandir(path)

        with mock.patch.object(harness.os, "scandir", side_effect=denied):
            report = harness.audit_repository(root, "adaptive", "check")
        ids = {item.id for item in report.findings}
        self.assertIn("LINK000", ids)
        self.assertIn("INDEX004", ids)

    def test_data_id_and_plain_text_do_not_create_markdown_anchors(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(
            root,
            "target.md",
            '# Target\n\n<div data-id="ghost">No anchor</div>\n\nPlain id="other".\n',
        )
        source = put(root, "README.md", "[One](target.md#ghost) [Two](target.md#other)\n")
        report = harness.Report(command="check", root=str(root.resolve()))
        harness.check_text_links(report, root, source, source.read_text(encoding="utf-8"))
        self.assertEqual(2, len([item for item in report.findings if item.id == "LINK001"]))

    def test_governed_profile_is_documented_as_exact_layout(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "planning/PLAN_POLICY.md", "# Planning\n")
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"planning": "planning/PLAN_POLICY.md"},
                }
            ),
        )
        report = harness.audit_repository(root, "governed", "check")
        planning = next(
            item for item in report.findings if item.id == "PATH001" and item.path == "docs/PLANS.md"
        )
        self.assertIn("exact-layout", planning.remediation)

    def test_index_duplicate_scan_does_not_use_quadratic_count(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("all_targets.count", source)

    def test_validate_plan_rejects_symlinked_lifecycle_parent(self) -> None:
        temporary, root = self.make_root()
        outside_temporary, outside = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.addCleanup(outside_temporary.cleanup)
        put(root, "docs/PLANS.md", "# Plans\n")
        put(root, "docs/exec-plans/index.md", empty_index())
        (root / "docs/exec-plans/completed").mkdir(parents=True)
        put(outside, "safe-plan.md", plan_text())
        (root / "docs/exec-plans/active").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(harness.SafeRefusal):
            harness.validate_plan_command(root, "safe-plan", "active", False)

    def test_fenced_markdown_cannot_supply_plan_schema_or_progress(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text(progress="```markdown\n- [x] (2026-07-22 10:30Z) Fake progress.\n```")
        text = text.replace(
            "# Verify the repository harness lifecycle",
            "```markdown\n# Fake example title\n```",
            1,
        )
        text = text.replace("## Context and Orientation", "### Context and Orientation", 1)
        text += "\n```markdown\n## Context and Orientation\n```\n"
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        ids = {item.id for item in report.findings}
        self.assertIn("PLAN003", ids)
        self.assertIn("PLAN004", ids)

    def test_validate_plan_reports_broken_current_location_link(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(
            root,
            "docs/exec-plans/active/safe-plan.md",
            plan_text(extra_artifacts="Required [evidence](missing.md) is absent."),
        )
        report = harness.validate_plan_command(
            root, "safe-plan", "active", False
        )
        self.assertIn("PLAN015", {item.id for item in report.findings})

    def test_present_index_requires_both_lifecycle_directories(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "docs/PLANS.md", "# Plans\n")
        put(root, "docs/exec-plans/index.md", empty_index())
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {
                        "exec_plan_index": "docs/exec-plans/index.md"
                    },
                }
            ),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        missing = [item for item in report.findings if item.id == "INDEX004"]
        self.assertEqual(2, len(missing))

    def test_duplicate_plan_metadata_keys_are_rejected(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        duplicate = plan_text().replace(
            "status: active", "status: completed\nstatus: active", 1
        )
        put(root, "docs/exec-plans/active/safe-plan.md", duplicate)
        report = harness.validate_plan_command(
            root, "safe-plan", "active", False
        )
        self.assertIn("PLAN002", {item.id for item in report.findings})

    def test_link_check_includes_images_ignores_fences_and_handles_parentheses(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "docs/file_(v1).md", "# Existing\n")
        put(root, "docs/file#part.md", "# Encoded path\n")
        source = put(
            root,
            "README.md",
            "![missing evidence](missing.png)\n"
            "```markdown\n[example only](not-real.md)\n```\n"
            "[balanced](docs/file_(v1).md?view=local)\n"
            "[encoded](docs/file%23part.md)\n",
        )
        report = harness.Report(command="check", root=str(root.resolve()))
        harness.check_text_links(report, root, source, source.read_text(encoding="utf-8"))
        findings = [item for item in report.findings if item.id == "LINK001"]
        self.assertEqual(1, len(findings))
        self.assertIn("missing.png", findings[0].message)

    def test_impossible_progress_and_revision_timestamps_are_rejected(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text(
            progress="- [x] (2026-99-99 99:99Z) This timestamp is impossible."
        ).replace("(2026-07-22 10:30Z) Change:", "(2026-99-99 99:99Z) Change:")
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        ids = {item.id for item in report.findings}
        self.assertIn("PLAN004", ids)
        self.assertIn("PLAN010", ids)

    def test_unknown_authority_key_is_rejected(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "planning/PLAN_POLICY.md", "# Planning\n")
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"planing": "planning/PLAN_POLICY.md"},
                }
            ),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("CONFIG004", {item.id for item in report.findings})

    def test_adaptive_discovery_does_not_follow_architecture_symlink_outside(self) -> None:
        temporary, root = self.make_root()
        outside_temporary, outside = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.addCleanup(outside_temporary.cleanup)
        put(root, "AGENTS.md", "# Guide\n")
        put(root, "tests/test_example.py", "# fixture\n")
        put(outside, "0001.md", "# Outside decision\n")
        (root / "docs").mkdir()
        (root / "docs/adr").symlink_to(outside, target_is_directory=True)
        report = harness.audit_repository(root, "adaptive", "audit")
        architecture_info = [
            item
            for item in report.findings
            if item.id == "CAP002" and item.severity == "info"
        ]
        self.assertEqual([], architecture_info)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO support is required")
    def test_safe_reader_rejects_fifo_without_blocking(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        fifo = root / "docs.md"
        os.mkfifo(fifo)
        with self.assertRaises(harness.SafeRefusal):
            harness.read_text_safe(root, fifo)

    def test_completed_plan_rejects_backdated_metadata(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(
            root,
            "docs/exec-plans/completed/safe-plan.md",
            plan_text(
                state="completed",
                created="2026-07-22",
                updated="2026-07-22",
                completed="2026-01-01",
            ),
        )
        report = harness.validate_plan_command(
            root, "safe-plan", "completed", False
        )
        self.assertIn("PLAN002", {item.id for item in report.findings})

    def test_cli_audit_json_is_nonblocking_even_with_errors(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, harness.CONFIG_REL, "{not-json")
        result = self.run_cli(
            "audit", "--root", str(root), "--allow-non-git", "--format", "json"
        )
        self.assertEqual(0, result.returncode)
        payload = json.loads(result.stdout)
        self.assertEqual(1, payload["schema_version"])
        self.assertGreater(payload["summary"]["errors"], 0)

    def test_cli_warnings_as_errors_and_root_refusal(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        default = self.run_cli("check", "--root", str(root), "--allow-non-git")
        strict = self.run_cli(
            "check",
            "--root",
            str(root),
            "--allow-non-git",
            "--warnings-as-errors",
        )
        self.assertEqual(0, default.returncode)
        self.assertEqual(1, strict.returncode)

        refused = self.run_cli(
            "audit",
            "--root",
            str(Path.home()),
            "--allow-non-git",
            "--format",
            "json",
        )
        self.assertEqual(2, refused.returncode)
        self.assertEqual("CLI001", json.loads(refused.stdout)["findings"][0]["id"])

    def test_cli_has_no_apply_flag_and_rejects_unsafe_slug(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        apply_result = self.run_cli(
            "scaffold",
            "--root",
            str(root),
            "--allow-non-git",
            "--profile",
            "governed",
            "--apply",
        )
        self.assertEqual(2, apply_result.returncode)
        slug_result = self.run_cli(
            "validate-plan",
            "--root",
            str(root),
            "--allow-non-git",
            "--slug",
            "../escape",
            "--state",
            "active",
            "--format",
            "json",
        )
        self.assertEqual(2, slug_result.returncode)
        self.assertEqual("CLI001", json.loads(slug_result.stdout)["findings"][0]["id"])

    def test_cli_argument_error_honors_json_format(self) -> None:
        result = self.run_cli(
            "check",
            "--profile",
            "unknown",
            "--format",
            "json",
            "--allow-non-git",
        )
        self.assertEqual(2, result.returncode)
        self.assertEqual("", result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual("CLI000", payload["findings"][0]["id"])

        equals_result = self.run_cli(
            "check",
            "--profile",
            "unknown",
            "--format=json",
            "--allow-non-git",
        )
        self.assertEqual(2, equals_result.returncode)
        self.assertEqual("CLI000", json.loads(equals_result.stdout)["findings"][0]["id"])

        repeated = self.run_cli(
            "check",
            "--profile",
            "unknown",
            "--format",
            "text",
            "--format=json",
            "--allow-non-git",
        )
        self.assertEqual(2, repeated.returncode)
        self.assertEqual("CLI000", json.loads(repeated.stdout)["findings"][0]["id"])

    def test_raw_html_block_cannot_supply_plan_structure(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text()
        metadata, body = text.split("# Verify the repository harness lifecycle", 1)
        put(
            root,
            "docs/exec-plans/active/safe-plan.md",
            metadata
            + "<pre>\n# Verify the repository harness lifecycle"
            + body
            + "</pre>\n",
        )
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", False
        )
        ids = {item.id for item in report.findings}
        self.assertTrue({"PLAN003", "PLAN004", "PLAN007"}.issubset(ids))

    def test_markdown_escape_is_unescaped_before_link_resolution(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        source = put(root, "docs/source.md", "[proof](evidence\\).md)\n")
        put(root, "docs/evidence\\).md", "# Decoy\n")
        report = harness.Report(command="check", root=str(root.resolve()))
        harness.check_text_links(
            report, root, source, source.read_text(encoding="utf-8")
        )
        self.assertIn("LINK001", {item.id for item in report.findings})

    def test_markdown_entity_is_decoded_before_link_resolution(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        source = put(root, "docs/source.md", "[proof](evidence&amp;proof.md)\n")
        put(root, "docs/evidence&amp;proof.md", "# Decoy\n")
        report = harness.Report(command="check", root=str(root.resolve()))
        harness.check_text_links(
            report, root, source, source.read_text(encoding="utf-8")
        )
        self.assertIn("LINK001", {item.id for item in report.findings})

        put(root, "docs/evidence&proof.md", "# Evidence\n")
        corrected = harness.Report(command="check", root=str(root.resolve()))
        harness.check_text_links(
            corrected, root, source, source.read_text(encoding="utf-8")
        )
        self.assertEqual(
            [], [item for item in corrected.findings if item.severity == "error"]
        )

    def test_invalid_markdown_entity_is_not_partially_decoded(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        source = put(root, "docs/source.md", "[proof](proof&notanentity;.md)\n")
        put(root, "docs/proof¬anentity;.md", "# Decoy\n")
        report = harness.Report(command="check", root=str(root.resolve()))
        harness.check_text_links(
            report, root, source, source.read_text(encoding="utf-8")
        )
        self.assertIn("LINK001", {item.id for item in report.findings})

    def test_overlong_numeric_markdown_entity_remains_literal(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        source = put(root, "docs/source.md", "[proof](proof&#00000000;.md)\n")
        put(root, "docs/proof�.md", "# Decoy\n")
        report = harness.Report(command="check", root=str(root.resolve()))
        harness.check_text_links(
            report, root, source, source.read_text(encoding="utf-8")
        )
        self.assertIn("LINK001", {item.id for item in report.findings})

    def test_repeated_anchor_target_is_parsed_once_per_link_check(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        root = root.resolve()
        put(root, "docs/target.md", "# Shared target\n")
        first = put(root, "docs/first.md", "[one](target.md#shared-target)\n")
        second = put(root, "docs/second.md", "[two](target.md#shared-target)\n")
        report = harness.Report(command="check", root=str(root.resolve()))
        with mock.patch.object(
            harness, "markdown_anchors", wraps=harness.markdown_anchors
        ) as anchors:
            harness.check_links(report, root, (first, second))
        self.assertEqual([], [item for item in report.findings if item.severity == "error"])
        self.assertEqual(1, anchors.call_count)

    def test_standalone_tbd_inside_fence_blocks_completion(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text(extra_artifacts="Evidence follows.\n\n```text\nTBD\n```")
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN008", {item.id for item in report.findings})

    def test_invalid_link_title_cannot_satisfy_policy_or_registry(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(
            root,
            "docs/exec-plans/active/safe-plan.md",
            plan_text().replace("../../PLANS.md", "../../PLANS.md garbage"),
        )
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN007", {item.id for item in report.findings})

        put(root, "docs/exec-plans/active/safe-plan.md", plan_text())
        put(
            root,
            "docs/exec-plans/index.md",
            index_with_active().replace(
                "active/safe-plan.md)", "active/safe-plan.md garbage)"
            ),
        )
        registry_report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("INDEX002", {item.id for item in registry_report.findings})

    def test_invalid_reference_definition_cannot_satisfy_policy_link(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text().replace(
            "[configured planning policy](../../PLANS.md)",
            "[configured planning policy][policy]",
        )
        text += "\n[policy]: ../../PLANS.md garbage\n"
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN007", {item.id for item in report.findings})

    def test_inline_html_attribute_cannot_supply_policy_link(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text().replace(
            "[configured planning policy](../../PLANS.md)",
            '<span title="[configured planning policy](../../PLANS.md)">the policy</span>',
        )
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN007", {item.id for item in report.findings})

    def test_multiline_code_span_cannot_supply_policy_link(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text().replace(
            "[configured planning policy](../../PLANS.md)",
            "`[configured planning policy](../../PLANS.md)\n`",
        )
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN007", {item.id for item in report.findings})

    def test_inline_code_span_cannot_cross_into_live_task_block(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        progress = (
            "- [x] (2026-07-22 10:30Z) Real checked task.\n"
            "`unclosed code span\n"
            "- [ ] Unfinished live work.\n"
            "`"
        )
        put(
            root,
            "docs/exec-plans/active/safe-plan.md",
            plan_text(progress=progress),
        )
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN005", {item.id for item in report.findings})

    def test_nested_fenced_example_cannot_supply_policy_link(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text().replace(
            "[configured planning policy](../../PLANS.md)", "configured planning policy"
        )
        text = text.replace(
            "The focused and broad evidence is recorded below.",
            "- Example only\n"
            "    ```md\n"
            "    [configured planning policy](../../PLANS.md)\n"
            "    ```",
        )
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(root, "docs/exec-plans/index.md", index_with_active())
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        self.assertIn("PLAN007", {item.id for item in report.findings})

    def test_autolink_and_processing_instruction_cannot_supply_policy_link(self) -> None:
        replacements = {
            "autolink": "<https://example.test/[policy](../../PLANS.md)>",
            "processing": "<?probe [policy](../../PLANS.md)?>",
        }
        for label, replacement in replacements.items():
            with self.subTest(label=label):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                self.install_plan_lifecycle(root)
                text = plan_text().replace(
                    "[configured planning policy](../../PLANS.md)", replacement
                )
                put(root, "docs/exec-plans/active/safe-plan.md", text)
                put(root, "docs/exec-plans/index.md", index_with_active())
                report = harness.validate_plan_command(
            root, "safe-plan", "active", True
                )
                self.assertIn("PLAN007", {item.id for item in report.findings})

    def test_list_container_code_cannot_supply_progress_task(self) -> None:
        cases = {
            "fence": (
                "- Status evidence container\n"
                "    ```text\n"
                "    - [x] (2026-07-22 10:30Z) Fake checked task.\n"
                "    ```"
            ),
            "html": (
                "- Status evidence container\n"
                "    <pre>\n"
                "    - [x] (2026-07-22 10:30Z) Fake checked task.\n"
                "    </pre>"
            ),
        }
        for label, progress in cases.items():
            with self.subTest(label=label):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                self.install_plan_lifecycle(root)
                put(
                    root,
                    "docs/exec-plans/active/safe-plan.md",
                    plan_text(progress=progress),
                )
                put(root, "docs/exec-plans/index.md", index_with_active())
                report = harness.validate_plan_command(
            root, "safe-plan", "active", True
                )
                self.assertIn("PLAN004", {item.id for item in report.findings})

    def test_non_html_text_cannot_hide_unchecked_progress(self) -> None:
        cases = {
            "invalid-tag": (
                "- [x] (2026-07-22 10:30Z) Real checked task.\n\n"
                "<x ???>\n"
                "- [ ] Unfinished live work."
            ),
            "paragraph-interruption": (
                "- [x] (2026-07-22 10:30Z) Real checked task.\n"
                "Paragraph continues\n"
                "<x>\n"
                "- [ ] Unfinished live work."
            ),
        }
        for label, progress in cases.items():
            with self.subTest(label=label):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                self.install_plan_lifecycle(root)
                put(
                    root,
                    "docs/exec-plans/active/safe-plan.md",
                    plan_text(progress=progress),
                )
                put(root, "docs/exec-plans/index.md", index_with_active())
                report = harness.validate_plan_command(
            root, "safe-plan", "active", True
                )
                self.assertIn("PLAN005", {item.id for item in report.findings})

    def test_plain_attribute_syntax_does_not_create_anchor(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "target.md", "# Target\n\nOrdinary prose contains {#ghost}.\n")
        source = put(root, "README.md", "[Ghost](target.md#ghost)\n")
        report = harness.Report(command="check", root=str(root.resolve()))
        harness.check_text_links(
            report, root, source, source.read_text(encoding="utf-8")
        )
        self.assertIn("LINK001", {item.id for item in report.findings})

    def test_markdown_discovery_includes_long_and_uppercase_extensions(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        root = root.resolve()
        put(root, "README.markdown", "[Missing](one.md)\n")
        put(root, "UPPER.MD", "[Missing](two.md)\n")
        report = harness.Report(command="check", root=str(root))
        files = list(harness.markdown_files(root, report))
        self.assertEqual({"README.markdown", "UPPER.MD"}, {path.name for path in files})
        harness.check_links(report, root, files)
        self.assertEqual(2, len([item for item in report.findings if item.id == "LINK001"]))

    def test_root_override_is_the_authority_reachability_entry(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_governed_templates(root)
        put(root, "AGENTS.override.md", "# Temporary override\n\nNo authority routes.\n")
        report = harness.audit_repository(root, "governed", "check")
        route_findings = [item for item in report.findings if item.id == "ROUTE002"]
        self.assertTrue(route_findings)
        self.assertTrue(any("AGENTS.override.md" in item.message for item in route_findings))

    def test_profile_check_detects_generic_scaffold_comments(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_governed_templates(root)
        for rel in harness.GOVERNED_FILES:
            path = root / rel
            if not path.is_file():
                continue
            text = path.read_text(encoding="utf-8")
            path.write_text(
                text.replace("TODO(harness): ", "").replace("TODO(harness)", ""),
                encoding="utf-8",
            )
        report = harness.audit_repository(root, "governed", "check")
        self.assertIn("DOC001", {item.id for item in report.findings})

    def test_tbd_owner_and_title_block_completion(self) -> None:
        cases = {
            "owner": (
                plan_text().replace("owner: platform-team", "owner: TBD"),
                index_with_active(owner="TBD"),
                {"PLAN002", "PLAN008"},
            ),
            "title": (
                plan_text().replace(
                    "# Verify the repository harness lifecycle", "# TBD"
                ),
                index_with_active(title="TBD"),
                {"PLAN008"},
            ),
        }
        for label, (text, index, expected) in cases.items():
            with self.subTest(label=label):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                self.install_plan_lifecycle(root)
                put(root, "docs/exec-plans/active/safe-plan.md", text)
                put(root, "docs/exec-plans/index.md", index)
                report = harness.validate_plan_command(
            root, "safe-plan", "active", True
                )
                self.assertTrue(expected.issubset({item.id for item in report.findings}))

    def test_blockquoted_code_cannot_supply_routes_or_hide_following_tasks(self) -> None:
        quoted = (
            "> ```markdown\n"
            "> [Policy](docs/PLANS.md)\n"
            "> ```\n"
            ">     [Indented](docs/PLANS.md)\n"
        )
        self.assertEqual([], harness.markdown_navigation_destinations(quoted))
        tasks = harness.markdown_task_items(
            "> ```\n> inert example\n- [ ] Live work after the quote.\n"
        )
        self.assertEqual([(" ", "Live work after the quote.")], tasks)

    def test_escaped_code_and_html_openers_do_not_hide_live_links(self) -> None:
        escaped_code = r"\` [Broken](missing-one.md) \`"
        escaped_html = r'\<span title="[Broken](missing-two.md)">'
        destinations = harness.markdown_navigation_destinations(
            escaped_code + "\n" + escaped_html
        )
        self.assertEqual({"missing-one.md", "missing-two.md"}, set(destinations))

    def test_pointy_destination_parentheses_are_checked(self) -> None:
        self.assertEqual(
            ["<missing(foo.md>"],
            harness.markdown_navigation_destinations(
                "[Broken](<missing(foo.md>)\n"
            ),
        )

    def test_html_type_seven_and_list_nested_h2_cannot_supply_plan_schema(self) -> None:
        replacements = (
            "<span>   \n## Artifacts and Notes\n\n",
            "- Nested wrapper\n\n  ## Artifacts and Notes\n",
        )
        for replacement in replacements:
            with self.subTest(replacement=replacement):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                self.install_plan_lifecycle(root)
                text = plan_text().replace(
                    "## Artifacts and Notes\n", replacement, 1
                )
                put(root, "docs/exec-plans/active/safe-plan.md", text)
                put(root, "docs/exec-plans/index.md", index_with_active())
                report = harness.validate_plan_command(
            root, "safe-plan", "active", True
                )
                self.assertIn("PLAN003", {item.id for item in report.findings})

    def test_ten_digit_ordered_marker_and_bodyless_task_do_not_bypass_progress(self) -> None:
        cases = {
            "not-a-commonmark-list": (
                "1234567890. [x] (2026-07-22 10:30Z) Fake item.",
                "PLAN004",
            ),
            "comment-only-unchecked": (
                "- [x] (2026-07-22 10:30Z) Real item.\n"
                "- [ ] <!-- unfinished work -->",
                "PLAN005",
            ),
            "rendered-empty-checked": (
                "- [x] (2026-07-22 10:30Z) <span></span>",
                "PLAN004",
            ),
        }
        for label, (progress, expected) in cases.items():
            with self.subTest(label=label):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                self.install_plan_lifecycle(root)
                put(
                    root,
                    "docs/exec-plans/active/safe-plan.md",
                    plan_text(progress=progress),
                )
                put(root, "docs/exec-plans/index.md", index_with_active())
                report = harness.validate_plan_command(
            root, "safe-plan", "active", True
                )
                self.assertIn(expected, {item.id for item in report.findings})

    def test_escaped_lifecycle_markers_are_not_registry_markers(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        index = empty_index().replace(
            harness.ACTIVE_START, "\\" + harness.ACTIVE_START
        ).replace(harness.COMPLETED_START, "\\" + harness.COMPLETED_START)
        put(root, "docs/exec-plans/index.md", index)
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("INDEX001", {item.id for item in report.findings})

    def test_lifecycle_rejects_uppercase_extensions_and_nested_directories(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(root, "docs/exec-plans/active/rogue.MD", "# Rogue\n")
        put(root, "docs/exec-plans/active/drafts/rogue.md", "# Nested\n")
        report = harness.audit_repository(root, "adaptive", "check")
        lifecycle = [item for item in report.findings if item.id == "INDEX004"]
        self.assertGreaterEqual(len(lifecycle), 2)

    def test_html_anchor_entities_and_escaped_openers_match_rendered_dom(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        target = put(
            root,
            "target.md",
            '<div id="foo&amp;bar">Real</div>\n\\<div id="fake">Text</div>\n',
        )
        anchors = harness.markdown_anchors(target.read_text(encoding="utf-8"))
        self.assertIn("foo&bar", anchors)
        self.assertNotIn("foo&amp;bar", anchors)
        self.assertNotIn("fake", anchors)
        source = put(
            root,
            "source.md",
            "[Entity mismatch](target.md#foo%26amp%3Bbar)\n"
            "[Escaped tag](target.md#fake)\n",
        )
        report = harness.Report(command="check", root=str(root.resolve()))
        harness.check_text_links(
            report, root, source, source.read_text(encoding="utf-8")
        )
        self.assertEqual(2, len([item for item in report.findings if item.id == "LINK001"]))

    def test_rendered_unresolved_markers_block_plan_and_index_completion(self) -> None:
        markers = (
            "TODO&#58; fill this section with evidence.",
            "TODO implement the fallback after release.",
            "This remains TODO for the owning team.",
            "TBD by the owning team.",
        )
        for marker in markers:
            with self.subTest(marker=marker):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                self.install_plan_lifecycle(root)
                put(
                    root,
                    "docs/exec-plans/active/safe-plan.md",
                    plan_text(extra_artifacts=marker),
                )
                put(root, "docs/exec-plans/index.md", index_with_active())
                report = harness.validate_plan_command(
            root, "safe-plan", "active", True
                )
                self.assertIn("PLAN008", {item.id for item in report.findings})

        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        put(root, "docs/exec-plans/active/safe-plan.md", plan_text())
        put(
            root,
            "docs/exec-plans/index.md",
            index_with_active(milestone="TODO implement the remaining gate."),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("INDEX002", {item.id for item in report.findings})

    def test_adaptive_index_and_coverage_schemas_require_explicit_opt_in(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "docs/exec-plans/index.md", "# Unrelated project index\n")
        put(root, "docs/agent-harness/coverage-matrix.md", "# Unrelated matrix\n")
        report = harness.audit_repository(root, "adaptive", "check")
        ids = {item.id for item in report.findings}
        self.assertFalse(any(item.startswith("INDEX") for item in ids))
        self.assertFalse(any(item.startswith("COVERAGE") for item in ids))

    def test_coverage_status_contract_and_incomplete_states_are_enforced(self) -> None:
        def matrix(*statuses: str) -> str:
            rows = "\n".join(
                f"| Capability {index} | implementation | evidence | {status} |"
                for index, status in enumerate(statuses, 1)
            )
            return (
                "# Coverage\n\n"
                "| Capability | Implementation | Evidence | Status and reason |\n"
                "| --- | --- | --- | --- |\n"
                f"{rows}\n"
            )

        cases = {
            "invalid": (
                ("done — command passed locally", "verified"),
                {"COVERAGE001"},
            ),
            "incomplete": (
                (
                    "candidate — implementation exists but is unexercised",
                    "blocked — owner approval is still pending",
                ),
                {"COVERAGE002"},
            ),
            "complete": (
                (
                    "verified — make verify passed on 2026-07-22",
                    "N/A — this CLI-only repository has no browser surface",
                ),
                set(),
            ),
        }
        for label, (statuses, expected) in cases.items():
            with self.subTest(label=label):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                path = put(root, "coverage.md", matrix(*statuses))
                report = harness.Report(command="check", root=str(root.resolve()))
                harness.validate_coverage(
                    report, root, path, require_canonical_rows=False
                )
                found = {
                    item.id for item in report.findings if item.id.startswith("COVERAGE")
                }
                self.assertEqual(expected, found)

    def test_canonical_coverage_inventory_rejects_missing_rows(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        template = (
            harness.TEMPLATE_ROOT / "docs/agent-harness/coverage-matrix.md"
        ).read_text(encoding="utf-8")
        tailored = template.replace(
            "<!-- TODO(harness) -->",
            "verified — project verification passed locally",
        )
        tailored = tailored.replace(
            "| Humans set intent; agents execute within authority |", "| Removed row |", 1
        )
        path = put(root, "coverage.md", tailored)
        report = harness.Report(command="check", root=str(root.resolve()))
        harness.validate_coverage(report, root, path, require_canonical_rows=True)
        self.assertIn("COVERAGE003", {item.id for item in report.findings})

    def test_canonical_coverage_inventory_remains_19_plus_12_rows(self) -> None:
        text = (
            harness.TEMPLATE_ROOT / "docs/agent-harness/coverage-matrix.md"
        ).read_text(encoding="utf-8")
        general, case_study = text.split("## Case-study decision ledger", 1)
        general_rows, general_tables, _, _ = harness.coverage_table_rows(general)
        case_rows, case_tables, _, _ = harness.coverage_table_rows(case_study)
        self.assertEqual(1, general_tables)
        self.assertEqual(1, case_tables)
        self.assertEqual(19, len(general_rows))
        self.assertEqual(12, len(case_rows))
        self.assertEqual(
            31,
            len(
                {
                    harness.normalize_coverage_identity(row.identity)
                    for row in general_rows + case_rows
                }
            ),
        )

    def test_empty_override_falls_back_and_override_placeholders_are_scanned(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_governed_templates(root)
        put(root, "AGENTS.override.md", "  \n\t\n")
        report = harness.audit_repository(root, "governed", "check")
        self.assertNotIn("ROUTE002", {item.id for item in report.findings})

        put(
            root,
            "AGENTS.override.md",
            "# Override\n\n<!-- TODO(harness): add authority routes -->\n",
        )
        report = harness.audit_repository(root, "governed", "check")
        self.assertIn("DOC001", {item.id for item in report.findings})

    def test_policy_text_naming_forbidden_markers_is_not_a_scaffold_placeholder(self) -> None:
        text = "Policy forbids `TODO(harness)`, `TODO:`, `TBD:`, and `<replace>`.\n"
        self.assertFalse(harness.has_scaffold_placeholder("docs/PLANS.md", text))

    def test_plain_unresolved_managed_prose_is_a_scaffold_placeholder(self) -> None:
        self.assertTrue(
            harness.has_scaffold_placeholder(
                "docs/SECURITY.md", "Implementation remains TODO.\n"
            )
        )

    def test_commonmark_link_boundaries_do_not_create_route_false_successes(self) -> None:
        inert = (
            "`example\n2. [Policy](../../PLANS.md)\nend`\n"
            "[Policy][ ]\n\n[ ]: ../../PLANS.md\n"
            "Policy discussion continues\n[p]: ../../PLANS.md\n\n[Policy][p]\n"
            "[Policy](\n\n../../PLANS.md)\n"
        )
        self.assertNotIn(
            "../../PLANS.md", harness.markdown_navigation_destinations(inert)
        )

        live = (
            '[One](missing-one.md "title (")\n'
            '[Two](missing-two.md "title )")\n'
            "[Three](\n<missing-three(foo.md>)\n"
            "`code\n---\n[Four](missing-four.md)\n`\n"
            "\\<!-- [Five](missing-five.md) -->\n"
            "Prefix <!-- [Six](missing-six.md)\n"
        )
        destinations = harness.markdown_navigation_destinations(live)
        for expected in (
            "missing-one.md",
            "missing-two.md",
            "missing-three(foo.md",
            "missing-four.md",
            "missing-five.md",
            "missing-six.md",
        ):
            self.assertTrue(
                any(harness.rendered_link_destination(item) == expected for item in destinations),
                expected,
            )

    def test_nested_links_images_and_html_brackets_follow_inline_precedence(self) -> None:
        nested_link = "[foo [bar](other.md)](policy.md)"
        self.assertEqual(
            ["other.md"], harness.markdown_navigation_destinations(nested_link)
        )
        nested_image = "[![Alt](missing.png)](existing.md)"
        self.assertEqual(
            {"missing.png", "existing.md"},
            set(harness.markdown_link_destinations(nested_image)),
        )
        self.assertEqual(
            ["missing.md"],
            harness.markdown_navigation_destinations(
                '[foo <span title="]">](missing.md)'
            ),
        )

    def test_alternating_quoted_list_fence_is_inert(self) -> None:
        text = (
            "> - > ```\n"
            ">   > [Broken](missing.md)\n"
            ">   > ```\n"
        )
        self.assertEqual([], harness.markdown_link_destinations(text))
        self.assertEqual([], harness.markdown_navigation_destinations(text))

    def test_ordered_noninterrupting_paragraph_cannot_supply_progress(self) -> None:
        progress = (
            "Status prose\n"
            "2. Not a list interrupt\n"
            "2. [x] (2026-07-22 10:30Z) Fake task."
        )
        self.assertEqual([], harness.markdown_task_items(progress))

    def test_rendered_heading_slugs_decode_entities_and_reference_links(self) -> None:
        anchors = harness.markdown_anchors(
            "# A &amp; B\n\n# A [C][ref]\n\n[ref]: /target\n"
        )
        self.assertEqual({"a-b", "a-c"}, anchors)

    def test_extra_setext_or_list_child_h2_blocks_plan_completion(self) -> None:
        extras = (
            "Extra rendered section\n----------------------",
            "- ## Extra nested section",
        )
        for extra in extras:
            with self.subTest(extra=extra):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                self.install_plan_lifecycle(root)
                put(
                    root,
                    "docs/exec-plans/active/safe-plan.md",
                    plan_text(extra_artifacts=f"Evidence is recorded.\n\n{extra}"),
                )
                put(root, "docs/exec-plans/index.md", index_with_active())
                report = harness.validate_plan_command(
            root, "safe-plan", "active", True
                )
                self.assertIn("PLAN003", {item.id for item in report.findings})

    def test_rendered_blank_plan_facts_and_evidence_block_completion(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        text = plan_text().replace(
            "owner: platform-team", "owner: <span></span>", 1
        ).replace(
            "# Verify the repository harness lifecycle", "# <span></span>", 1
        )
        for heading in (
            "Surprises & Discoveries",
            "Decision Log",
            "Outcomes & Retrospective",
            "Validation and Acceptance",
            "Idempotence and Recovery",
        ):
            text = re.sub(
                rf"(## {re.escape(heading)}\n\n).*?(?=\n## )",
                rf"\1{'<span></span>' * 40}\n",
                text,
                count=1,
                flags=re.DOTALL,
            )
        put(root, "docs/exec-plans/active/safe-plan.md", text)
        put(
            root,
            "docs/exec-plans/index.md",
            index_with_active(
                title="<span></span>",
                owner="<span></span>",
                milestone="<span></span>",
            ),
        )
        report = harness.validate_plan_command(
            root, "safe-plan", "active", True
        )
        ids = {item.id for item in report.findings}
        self.assertTrue({"PLAN002", "PLAN003", "PLAN009", "INDEX002"}.issubset(ids))

    def test_list_child_fenced_registry_and_coverage_controls_are_inert(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_plan_lifecycle(root)
        index = (
            "# ExecPlan Registry\n\n## Active\n\n"
            "| Plan | Owner | State | Updated (UTC) | Current milestone or blocker |\n"
            "| --- | --- | --- | --- | --- |\n"
            "- ```markdown\n"
            f"  {harness.ACTIVE_START}\n  _None._\n  {harness.ACTIVE_END}\n    ```\n\n"
            "## Completed\n\n"
            "| Plan | Completed (UTC) | Outcome | Verification |\n"
            "| --- | --- | --- | --- |\n"
            f"{harness.COMPLETED_START}\n_None._\n{harness.COMPLETED_END}\n"
        )
        put(root, "docs/exec-plans/index.md", index)
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("INDEX001", {item.id for item in report.findings})

        template = (
            harness.TEMPLATE_ROOT / "docs/agent-harness/coverage-matrix.md"
        ).read_text(encoding="utf-8").replace(
            "<!-- TODO(harness) -->", "verified — observed project evidence recorded"
        )
        wrapped = "- ```markdown\n" + "".join(
            f"  {line}\n" for line in template.splitlines()
        ) + "    ```\n"
        path = put(root, "coverage.md", wrapped)
        coverage_report = harness.Report(command="check", root=str(root.resolve()))
        harness.validate_coverage(
            coverage_report, root, path, require_canonical_rows=True
        )
        coverage_ids = {item.id for item in coverage_report.findings}
        self.assertTrue({"COVERAGE001", "COVERAGE003"}.issubset(coverage_ids))

    def test_plan_template_does_not_timestamp_unchecked_progress(self) -> None:
        template = (
            harness.TEMPLATE_ROOT / "docs/exec-plans/plan-template.md"
        ).read_text(encoding="utf-8")
        progress = template.split("## Progress", 1)[1].split("## Surprises", 1)[0]
        self.assertNotIn("<YYYY-MM-DD HH:MMZ>", progress)

    def test_adaptive_mapped_coverage_does_not_require_canonical_inventory(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "AGENTS.md", "# Guide\n\n[Coverage](custom/coverage.md)\n")
        put(
            root,
            "custom/coverage.md",
            "# Coverage\n\n"
            "| Capability | Implementation | Evidence | Status and reason |\n"
            "| --- | --- | --- | --- |\n"
            "| Orientation | AGENTS.md | local check | verified — route was exercised locally |\n",
        )
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {"coverage": "custom/coverage.md"},
                }
            ),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertNotIn("COVERAGE003", {item.id for item in report.findings})

    def test_explicit_exec_plan_lifecycle_requires_planning_authority(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "AGENTS.md", "# Guide\n\n[Plans](docs/exec-plans/index.md)\n")
        put(root, "docs/exec-plans/index.md", empty_index())
        (root / "docs/exec-plans/active").mkdir(parents=True)
        (root / "docs/exec-plans/completed").mkdir(parents=True)
        put(
            root,
            harness.CONFIG_REL,
            json.dumps(
                {
                    "schema_version": 1,
                    "authorities": {
                        "exec_plan_index": "docs/exec-plans/index.md"
                    },
                }
            ),
        )
        report = harness.audit_repository(root, "adaptive", "check")
        self.assertIn("PLAN007", {item.id for item in report.findings})

    def test_sentinel_owners_and_milestones_block_completion(self) -> None:
        for owner, milestone in (
            ("none", "Final validation"),
            ("N/A", "Final validation"),
            ("??", "??"),
            ("not available", "Final validation"),
            ("awaiting assignment", "Final validation"),
            ("none assigned", "Final validation"),
            ("no current owner", "Final validation"),
            ("not assigned yet", "Final validation"),
            ("unassigned team", "Final validation"),
            ("awaiting team assignment", "Final validation"),
            ("to be confirmed", "Final validation"),
            ("assignment pending", "Final validation"),
            ("not currently assigned", "Final validation"),
            ("currently unassigned", "Final validation"),
            ("not assigned currently", "Final validation"),
            ("still unassigned", "Final validation"),
            ("owner to be assigned", "Final validation"),
            ("no owner assigned", "Final validation"),
            ("none currently assigned", "Final validation"),
            ("TBC", "Final validation"),
            ("not selected", "Final validation"),
            ("not named", "Final validation"),
            ("to assign", "Final validation"),
            ("owner forthcoming", "Final validation"),
            ("needs assignment", "Final validation"),
            ("assign later", "Final validation"),
            ("platform-team", "not yet"),
            ("platform-team", "no milestone yet"),
            (
                '<span title="x>team"></span>',
                '<span title="x>done"></span>',
            ),
            (
                "<span hidden>platform-team</span>",
                "<span hidden>Final validation</span>",
            ),
        ):
            with self.subTest(owner=owner, milestone=milestone):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                self.install_plan_lifecycle(root)
                put(
                    root,
                    "docs/exec-plans/active/safe-plan.md",
                    plan_text().replace("owner: platform-team", f"owner: {owner}"),
                )
                put(
                    root,
                    "docs/exec-plans/index.md",
                    index_with_active(owner=owner, milestone=milestone),
                )
                report = harness.validate_plan_command(
            root, "safe-plan", "active", True
                )
                ids = {item.id for item in report.findings}
                if not harness.is_substantive_owner(owner):
                    self.assertIn("PLAN002", ids)
                self.assertIn("INDEX002", ids)

    def test_image_alt_links_cannot_route_and_outer_image_is_checked(self) -> None:
        text = "![[Policy](../../PLANS.md)](missing.png)\n"
        self.assertEqual([], harness.markdown_navigation_destinations(text))
        self.assertEqual(["missing.png"], harness.markdown_link_destinations(text))

    def test_lazy_blockquotes_and_blank_line_labels_cannot_supply_routes(self) -> None:
        cases = (
            "> quoted\n[Policy](../../PLANS.md)\n",
            "[Policy\n\n](../../PLANS.md)\n",
            "> quoted\n2. still paragraph\n[Policy](../../PLANS.md)\n",
            "> quoted\n- \n[Policy](../../PLANS.md)\n",
            "> quoted\n1. \n[Policy](../../PLANS.md)\n",
            "> quoted\n\u00a0\n[Policy](../../PLANS.md)\n",
            "> quoted\n\f\n[Policy](../../PLANS.md)\n",
        )
        for text in cases:
            with self.subTest(text=text):
                self.assertEqual([], harness.markdown_navigation_destinations(text))

        live_interruptions = (
            "> quoted\n- real item\n[Policy](../../PLANS.md)\n",
            "> quoted\n1. real item\n[Policy](../../PLANS.md)\n",
            "> quoted\n \t\n[Policy](../../PLANS.md)\n",
        )
        for text in live_interruptions:
            with self.subTest(live=text):
                self.assertEqual(
                    ["../../PLANS.md"],
                    harness.markdown_navigation_destinations(text),
                )

    def test_comment_and_type_seven_html_blocks_cannot_supply_routes(self) -> None:
        cases = (
            "<!-- x --> [Policy](../../PLANS.md)\n",
            "# Heading\n<span>\n[Policy](../../PLANS.md)\n\n",
        )
        for text in cases:
            with self.subTest(text=text):
                self.assertEqual([], harness.markdown_navigation_destinations(text))

    def test_recursively_nested_list_heading_blocks_plan_completion(self) -> None:
        nested_headings = (
            "- - ## Extra twice nested",
            ("- " * 129) + "## Extra deeply nested",
        )
        for nested_heading in nested_headings:
            with self.subTest(depth=nested_heading.count("- ")):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                self.install_plan_lifecycle(root)
                put(
                    root,
                    "docs/exec-plans/active/safe-plan.md",
                    plan_text(
                        extra_artifacts=f"Evidence is recorded.\n\n{nested_heading}"
                    ),
                )
                put(root, "docs/exec-plans/index.md", index_with_active())
                report = harness.validate_plan_command(
            root, "safe-plan", "active", True
                )
                self.assertIn("PLAN003", {item.id for item in report.findings})

    def test_five_post_marker_spaces_do_not_create_a_task(self) -> None:
        self.assertEqual(
            [],
            harness.markdown_task_items(
                "-     [x] (2026-07-22 10:30Z) Indented code, not a task.\n"
            ),
        )

    def test_rendered_link_markup_cannot_split_placeholder_tokens(self) -> None:
        cases = (
            "TO[DO](https://example.com): fill this section",
            "TO![](https://example.com/a.png)DO: fill this section",
            "TO![![](https://example.com/a)](https://example.com/b)DO: fill this section",
            "TO[](https://example.com/a((b)))DO: fill this section",
            'TO![<span title="]"></span>](https://example.com/a)DO: fill this section',
            'TO![<x a="["></x>](https://example.com/a)DO: fill this section',
        )
        for text in cases:
            with self.subTest(text=text):
                self.assertTrue(harness.has_unresolved_marker(text))

    def test_excessive_nested_link_labels_fail_closed_without_recursion(self) -> None:
        nested = "[" * 1200 + "x" + "](target.md)" * 1200
        destinations, missing = harness.scan_markdown_links(nested)
        self.assertEqual([], destinations)
        self.assertIn(harness.MARKDOWN_LINK_NESTING_SENTINEL, missing)

        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        put(root, "AGENTS.md", "# Routes\n\n" + nested + "\n")
        result = self.run_cli(
            "check",
            "--root",
            str(root),
            "--allow-non-git",
            "--format",
            "json",
        )
        self.assertEqual(1, result.returncode)
        self.assertEqual("", result.stderr)
        payload = json.loads(result.stdout)
        self.assertIn("LINK002", {item["id"] for item in payload["findings"]})

    def test_special_html_blocks_interrupt_inline_code_before_live_link(self) -> None:
        for block in ("<?x?>", "<!DECL>", "<![CDATA[x]]>"):
            with self.subTest(block=block):
                text = f"`code\n{block}\n[Broken](missing.md)\n`"
                self.assertIn("missing.md", harness.markdown_link_destinations(text))

    def test_lowercase_multiline_html_declaration_masks_nested_routes(self) -> None:
        declaration = "<!foo\n[Policy](../../PLANS.md)\n>\n"
        self.assertEqual([], harness.markdown_navigation_destinations(declaration))
        inline = "<!foo>\n[Policy](../../PLANS.md)\n"
        self.assertEqual(
            ["../../PLANS.md"],
            harness.markdown_navigation_destinations(inline),
        )

    def test_commonmark_non_ascii_whitespace_does_not_end_html_blocks(self) -> None:
        for separator in ("\u00a0", "\f", "\v"):
            with self.subTest(separator=repr(separator)):
                text = f"<div>\n{separator}\n[Policy](../../PLANS.md)\n"
                self.assertEqual([], harness.markdown_navigation_destinations(text))
        self.assertEqual(
            ["../../PLANS.md"],
            harness.markdown_navigation_destinations(
                "<div>\n \t\n[Policy](../../PLANS.md)\n"
            ),
        )

    def test_reference_definitions_require_a_commonmark_block_boundary(self) -> None:
        for separator in ("\u00a0", "\f", "\v"):
            with self.subTest(separator=repr(separator)):
                text = f"{separator}\n[policy]: ../../PLANS.md\n[Policy]\n"
                self.assertEqual([], harness.markdown_navigation_destinations(text))
        self.assertEqual(
            ["../../PLANS.md"],
            harness.markdown_navigation_destinations(
                " \t\n[policy]: ../../PLANS.md\n[Policy]\n"
            ),
        )

    def test_inline_code_paragraph_cannot_become_reference_boundary(self) -> None:
        text = (
            "`This is a nonempty paragraph.`\n"
            "[coverage]: docs/agent-harness/coverage-matrix.md\n"
            "\n[Coverage]\n"
        )
        self.assertEqual([], harness.markdown_navigation_destinations(text))

    def test_invalid_definition_cannot_open_a_reference_chain(self) -> None:
        text = (
            '[invalid]: /bad "title" extra\n'
            "[coverage]: docs/agent-harness/coverage-matrix.md\n"
            "\n[Coverage]\n"
        )
        self.assertEqual([], harness.markdown_navigation_destinations(text))

    def test_commonmark_multiline_and_post_heading_definitions_resolve(self) -> None:
        destination_next_line = "[policy]:\n../../PLANS.md\n\n[Policy]\n"
        after_heading = "# [Policy]\n[policy]: ../../PLANS.md\n> quoted text\n"
        title_chain = (
            '[one]: /one "One"\n'
            "[two]: /two\n"
            '  "Two"\n'
            "[three]: /three\n\n"
            "[One] [Two] [Three]\n"
        )
        empty_destination = "[empty]: <>\n\n[Empty]\n"
        self.assertEqual(
            ["../../PLANS.md"],
            harness.markdown_navigation_destinations(destination_next_line),
        )
        self.assertEqual(
            ["../../PLANS.md"],
            harness.markdown_navigation_destinations(after_heading),
        )
        self.assertEqual(
            ['/one "One"', '/two\n  "Two"', "/three"],
            harness.markdown_navigation_destinations(title_chain),
        )
        self.assertEqual(
            ["<>"],
            harness.markdown_navigation_destinations(empty_destination),
        )

    def test_link_destination_preserves_nbsp_and_rejects_ascii_controls(self) -> None:
        self.assertEqual(
            "docs/PLANS.md\u00a0",
            harness.normalized_link_destination("docs/PLANS.md\u00a0"),
        )
        for control in ("\f", "\v"):
            with self.subTest(control=repr(control)):
                self.assertIsNone(
                    harness.normalized_link_destination(f"docs/PLANS.md{control}")
                )

    def test_non_ascii_whitespace_does_not_open_ordered_task_interruptions(self) -> None:
        task = "2. [x] (2026-07-22 10:30Z) Verified observable increment.\n"
        for separator in ("\u00a0", "\f", "\v"):
            with self.subTest(separator=repr(separator)):
                self.assertEqual(
                    [], harness.markdown_task_items(f"paragraph\n{separator}\n{task}")
                )
        self.assertEqual(
            [("x", "(2026-07-22 10:30Z) Verified observable increment.")],
            harness.markdown_task_items(f"paragraph\n \t\n{task}"),
        )

    def test_unquoted_html_id_and_anchor_name_are_discoverable(self) -> None:
        anchors = harness.markdown_anchors(
            "<span id=foo></span>\n<a name=legacy></a>\n"
        )
        self.assertTrue({"foo", "legacy"}.issubset(anchors))

    def test_every_live_plan_heading_requires_a_following_blank_line(self) -> None:
        replacements = (
            "## Purpose / Big Picture\n",
            "## Purpose / Big Picture\n<!-- not a blank line -->\n",
            "## Purpose / Big Picture\n\u00a0\n",
            "## Purpose / Big Picture\n\f\n",
            "## Purpose / Big Picture\n\v\n",
        )
        for replacement in replacements:
            with self.subTest(replacement=replacement):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                self.install_plan_lifecycle(root)
                text = plan_text().replace(
                    "## Purpose / Big Picture\n\n", replacement, 1
                )
                put(root, "docs/exec-plans/active/safe-plan.md", text)
                put(root, "docs/exec-plans/index.md", index_with_active())
                report = harness.validate_plan_command(
                    root, "safe-plan", "active", True
                )
                self.assertIn("PLAN003", {item.id for item in report.findings})

    def test_governed_harness_index_routes_every_operational_authority(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        self.install_governed_templates(root)
        path = root / "docs/agent-harness/index.md"
        text = path.read_text(encoding="utf-8").replace(
            "(output-contract.md)", "(registry.md)"
        )
        path.write_text(text, encoding="utf-8")
        report = harness.audit_repository(root, "governed", "check")
        self.assertIn("ROUTE005", {item.id for item in report.findings})

    def test_plain_angle_comparisons_remain_substantive_facts(self) -> None:
        self.assertTrue(
            harness.is_substantive_lifecycle_fact("Keep p95 < 200 ms")
        )
        status, detail = harness.parse_coverage_status(
            "verified — p95 < 200 ms in the local benchmark"
        )
        self.assertEqual("verified", status)
        self.assertIn("p95", detail)

    def test_legacy_v1_production_certification_is_rejected_and_read_only(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        install_legacy_v1_production_claim_fixture(root)
        before = tree_fingerprint(root)
        report = harness.Report(command="certify", root=str(root))
        harness.validate_certification(
            report,
            root,
            dict(harness.DEFAULT_AUTHORITIES),
            "adaptive",
            CERT_COMMIT,
            now=CERT_NOW,
        )
        self.assertIn("CERT002", {item.id for item in report.findings})
        self.assertNotIn("CERT000", {item.id for item in report.findings})
        self.assertEqual(before, tree_fingerprint(root))

    def test_certification_rejects_commit_expiry_and_coverage_drift(self) -> None:
        cases = ("commit", "expiry", "coverage")
        for case in cases:
            with self.subTest(case=case):
                fixture = CertificationFixture(
                    manifest_mutation=(
                        "expired"
                        if case == "expiry"
                        else "coverage-digest" if case == "coverage" else None
                    )
                )
                self.addCleanup(fixture.close)
                if case == "commit":
                    result = fixture.run_cli(commit="f" * 40)
                else:
                    result = fixture.run_cli()
                self.assertNotEqual(0, result.returncode)
                payload = json.loads(result.stdout)
                ids = {item["id"] for item in payload["findings"]}
                expected = {
                    "commit": "CERT014",
                    "expiry": "CERT005",
                    "coverage": "CERT007",
                }
                self.assertIn(expected[case], ids)
                self.assertNotIn("CERT000", ids)

    def test_certification_rejects_forged_stale_and_image_only_evidence(self) -> None:
        cases = ("capability", "stale", "postissue", "duplicate", "image")
        mutations = {
            "capability": "wrong-capability",
            "stale": "stale",
            "postissue": "postissue",
            "duplicate": "duplicate-json",
        }
        for case in cases:
            with self.subTest(case=case):
                fixture = CertificationFixture(
                    mutate_first_evidence=mutations.get(case),
                    first_link_as_image=case == "image",
                )
                self.addCleanup(fixture.close)
                result = fixture.run_cli()
                self.assertNotEqual(0, result.returncode)
                ids = {
                    item["id"]
                    for item in json.loads(result.stdout)["findings"]
                }
                self.assertIn("CERT009", ids)
                self.assertNotIn("CERT000", ids)

    def test_harness_certification_accepts_evidenced_na_including_non_deployable_projects(
        self,
    ) -> None:
        applicable = CertificationFixture(mutate_first_evidence="n/a")
        self.addCleanup(applicable.close)
        accepted = applicable.run_cli()
        self.assertEqual(0, accepted.returncode, accepted.stdout + accepted.stderr)
        accepted_payload = json.loads(accepted.stdout)
        accepted_ids = {item["id"] for item in accepted_payload["findings"]}
        self.assertIn("CERT000", accepted_ids)
        self.assertNotIn("CERT015", accepted_ids)

        production = CertificationFixture(production_na=True)
        self.addCleanup(production.close)
        accepted_non_deployable = production.run_cli()
        self.assertEqual(
            0,
            accepted_non_deployable.returncode,
            accepted_non_deployable.stdout + accepted_non_deployable.stderr,
        )
        ids = {
            item["id"]
            for item in json.loads(accepted_non_deployable.stdout)["findings"]
        }
        self.assertIn("CERT000", ids)
        self.assertNotIn("CERT015", ids)

        strict_production = CertificationFixture(
            production_na=True,
            manifest_environment="production",
        )
        self.addCleanup(strict_production.close)
        rejected = strict_production.run_cli(require_production_attestation=True)
        self.assertNotEqual(0, rejected.returncode)
        strict_ids = {
            item["id"] for item in json.loads(rejected.stdout)["findings"]
        }
        self.assertIn("CERT009", strict_ids)
        self.assertNotIn("CERT015", strict_ids)
        self.assertNotIn("CERT000", strict_ids)

    def test_certification_accepts_manual_maintenance_without_ci_workflows(self) -> None:
        fixture = CertificationFixture(manifest_mutation="manual-triggers")
        self.addCleanup(fixture.close)
        result = fixture.run_cli()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        ids = {
            item["id"]
            for item in json.loads(result.stdout)["findings"]
        }
        self.assertIn("CERT000", ids)
        self.assertNotIn("CERT006", ids)

    def test_bundled_certification_defaults_to_manual_maintenance(self) -> None:
        manifest = json.loads(
            (
                harness.TEMPLATE_ROOT
                / "docs/agent-harness/certification.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual(["manual"], manifest["maintenance"]["triggers"])
        skill_text = (harness.SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn(
            "The fast path does not create a new checker, ExecPlan, coverage matrix, evidence store, evaluation suite, CI workflow, maintenance schedule, pilot, backlog, or governance layer by default.",
            skill_text,
        )

    def test_certification_requires_declared_maintenance_native_and_production_gates(self) -> None:
        cases = ("triggers", "native", "approval")
        for case in cases:
            with self.subTest(case=case):
                fixture = CertificationFixture(
                    manifest_mutation=(
                        case if case == "triggers" else "native-evidence"
                        if case == "native"
                        else None
                    ),
                    named_evidence_mutation=(
                        "approval-environment" if case == "approval" else None
                    ),
                )
                self.addCleanup(fixture.close)
                result = fixture.run_cli()
                self.assertNotEqual(0, result.returncode)
                ids = {
                    item["id"]
                    for item in json.loads(result.stdout)["findings"]
                }
                expected = {"triggers": "CERT006", "native": "CERT008", "approval": "CERT008"}
                self.assertIn(expected[case], ids)
                self.assertNotIn("CERT000", ids)

    def test_cli_certify_is_structured_and_fails_closed_on_audit_warnings(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        install_legacy_v1_production_claim_fixture(root)
        result = self.run_cli(
            "certify",
            "--root",
            str(root),
            "--allow-non-git",
            "--profile",
            "adaptive",
            "--commit",
            CERT_COMMIT,
            "--format",
            "json",
        )
        self.assertEqual(1, result.returncode)
        payload = json.loads(result.stdout)
        self.assertEqual("certify", payload["command"])
        self.assertGreater(payload["summary"]["warnings"], 0)
        self.assertNotIn("CERT000", {item["id"] for item in payload["findings"]})

    def test_skill_metadata_and_source_tree_are_release_clean(self) -> None:
        skill_text = (harness.SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        frontmatter = skill_text.split("---", 2)[1]
        keys = {
            line.split(":", 1)[0].strip()
            for line in frontmatter.splitlines()
            if ":" in line
        }
        self.assertEqual({"name", "description"}, keys)
        openai_metadata = (
            harness.SKILL_ROOT / "agents" / "openai.yaml"
        ).read_text(encoding="utf-8")
        self.assertRegex(
            openai_metadata,
            r"(?m)^policy:\n  allow_implicit_invocation: false$",
        )
        default_prompt = re.search(
            r'(?m)^  default_prompt: "([^"]+)"$', openai_metadata
        )
        self.assertIsNotNone(default_prompt)
        self.assertEqual(1, default_prompt.group(1).count("."))
        self.assertIn("$apply-harness-engineering", default_prompt.group(1))
        self.assertIn(
            "Installing this package only makes the skill available to Codex.",
            skill_text,
        )
        self.assertIn(
            "Treat the invoked package directory as the package authority.",
            skill_text,
        )
        self.assertIn("## Discover and classify", skill_text)
        self.assertIn(
            "Treat the repository as a fresh adoption only when it has no explicit harness configuration",
            skill_text,
        )
        self.assertIn(
            "When the state is ambiguous, choose migration or repair rather than fresh adoption",
            skill_text,
        )
        self.assertIn("explicit `$apply-harness-engineering` request", skill_text)
        self.assertIn("Make the repository agent-discoverable", skill_text)
        forbidden = {"__pycache__", ".DS_Store"}
        git_listing = subprocess.run(
            ["git", "-C", str(harness.SKILL_ROOT), "ls-files", "-z"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=10,
        )
        if git_listing.returncode == 0:
            candidates = [
                harness.SKILL_ROOT / Path(raw)
                for raw in git_listing.stdout.decode("utf-8").split("\0")
                if raw and (harness.SKILL_ROOT / Path(raw)).exists()
            ]
        else:
            candidates = [
                path
                for path in harness.SKILL_ROOT.rglob("*")
                if not any(
                    part in forbidden
                    for part in path.relative_to(harness.SKILL_ROOT).parts
                )
            ]
        for path in candidates:
            rel = path.relative_to(harness.SKILL_ROOT)
            self.assertTrue(path.exists(), rel.as_posix())
            self.assertFalse(path.is_symlink(), rel.as_posix())
            self.assertFalse(any(part in forbidden for part in rel.parts), rel.as_posix())
            self.assertNotIn(path.suffix.casefold(), {".pyc", ".pyo"})

    def test_package_version_metadata_is_consistent_for_v021(self) -> None:
        version = (harness.SKILL_ROOT / "VERSION").read_text(encoding="utf-8").strip()
        readme = (harness.SKILL_ROOT / "README.md").read_text(encoding="utf-8")
        changelog = (harness.SKILL_ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        self.assertEqual("0.2.1", version)
        self.assertIn("Package version: `0.2.1`", readme)
        self.assertRegex(changelog, r"(?m)^## 0\.2\.1 — 2026-08-31$")
        self.assertRegex(changelog, r"(?m)^## 0\.2\.0 — 2026-08-31$")
        self.assertRegex(changelog, r"(?m)^## 0\.1\.0 — 2026-08-24 \(unreleased development baseline\)$")

    def test_openai_metadata_is_durable_and_non_implicit(self) -> None:
        metadata = (harness.SKILL_ROOT / "agents/openai.yaml").read_text(encoding="utf-8")
        self.assertIn('display_name: "Apply Harness Engineering"', metadata)
        short_description = re.search(
            r'(?m)^  short_description: "([^"]+)"$', metadata
        )
        self.assertIsNotNone(short_description)
        self.assertGreaterEqual(len(short_description.group(1)), 25)
        self.assertLessEqual(len(short_description.group(1)), 64)
        default_prompt = re.search(r'(?m)^  default_prompt: "([^"]+\.?)"$', metadata)
        self.assertIsNotNone(default_prompt)
        self.assertIn("$apply-harness-engineering", default_prompt.group(1))
        self.assertIn("smallest durable change", default_prompt.group(1))
        self.assertRegex(metadata, r"(?m)^policy:\n  allow_implicit_invocation: false$")
        self.assertNotIn("standard", metadata.casefold())
        self.assertNotIn("full", metadata.casefold())

    def test_package_check_ignores_target_repository_fragments(self) -> None:
        result = self.run_cli("check", "--root", str(harness.SKILL_ROOT))
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertNotIn("LINK001", result.stdout)

    def test_adjacent_release_zip_matches_source_tree(self) -> None:
        archive = harness.SKILL_ROOT.with_suffix(".zip")
        if not archive.is_file():
            self.skipTest("Adjacent release ZIP is not present in an installed skill")
        prefix = harness.SKILL_ROOT.name + "/"
        source_files = {
            path.relative_to(harness.SKILL_ROOT).as_posix(): hashlib.sha256(
                path.read_bytes()
            ).hexdigest()
            for path in harness.SKILL_ROOT.rglob("*")
            if path.is_file() and not path.is_symlink()
        }
        source_keys = [
            unicodedata.normalize("NFC", path).casefold() for path in source_files
        ]
        self.assertEqual(len(source_keys), len(set(source_keys)))
        with zipfile.ZipFile(archive) as bundle:
            names = [item.filename for item in bundle.infolist()]
            self.assertEqual(len(names), len(set(names)))
            portable_names = [
                unicodedata.normalize("NFC", name).casefold() for name in names
            ]
            self.assertEqual(len(portable_names), len(set(portable_names)))
            archive_files: dict[str, str] = {}
            for item in bundle.infolist():
                path = PurePosixPath(item.filename)
                self.assertFalse(path.is_absolute())
                self.assertNotIn("..", path.parts)
                self.assertTrue(item.filename.startswith(prefix))
                self.assertEqual(0, item.flag_bits & 0x1)
                self.assertNotEqual(0o120000, (item.external_attr >> 16) & 0o170000)
                mode = (item.external_attr >> 16) & 0o777
                self.assertEqual(0o755 if item.is_dir() else 0o644, mode)
                self.assertNotIn("__pycache__", path.parts)
                self.assertNotIn(path.suffix.casefold(), {".pyc", ".pyo"})
                if not item.is_dir():
                    rel = item.filename[len(prefix) :]
                    archive_files[rel] = hashlib.sha256(bundle.read(item)).hexdigest()
        self.assertEqual(source_files, archive_files)


if __name__ == "__main__":
    unittest.main()
