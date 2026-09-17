from __future__ import annotations

import hashlib
import hmac
import importlib.util
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "harness.py"
SPEC = importlib.util.spec_from_file_location("harness_certification_security", SCRIPT)
assert SPEC and SPEC.loader
harness = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = harness
SPEC.loader.exec_module(harness)

TEST_KEY = b"independent-test-attestation-key-material-0123456789"
HMAC_CONTEXT = b"harness-engineering-evidence-v2\x00"
REPOSITORY_IDENTITY = "scm://example.invalid/platform/harness-fixture"
DEPLOYMENT_TARGET_ID = "harness://example.invalid/repository/harness-fixture"


def put(root: Path, relative: str, text: str) -> Path:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def git(root: Path, *arguments: str) -> str:
    completed = subprocess.run(
        [
            "git",
            "--no-optional-locks",
            "-c",
            f"core.hooksPath={os.devnull}",
            "-C",
            str(root),
            *arguments,
        ],
        stdin=subprocess.DEVNULL,
        text=True,
        capture_output=True,
        check=False,
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"git {' '.join(arguments)} failed: {completed.stderr!r}"
        )
    return completed.stdout.strip()


def sign_evidence(payload: dict[str, object], key: bytes = TEST_KEY) -> None:
    unsigned = {name: value for name, value in payload.items() if name != "signature"}
    encoded = json.dumps(
        unsigned,
        allow_nan=False,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    payload["signature"] = hmac.new(
        key, HMAC_CONTEXT + encoded, hashlib.sha256
    ).hexdigest()


def evidence_payload(
    capability: str,
    source_commit: str,
    observed_at: str,
    *,
    environment: str = "ci",
    command: str = "make verify-harness",
) -> dict[str, object]:
    payload: dict[str, object] = {
        "schema_version": 2,
        "repository_commit": source_commit,
        "repository_identity": REPOSITORY_IDENTITY,
        "deployment_target_id": DEPLOYMENT_TARGET_ID,
        "capabilities": [capability],
        "environment": environment,
        "command": command,
        "exit_code": 0,
        "observed_at": observed_at,
        "result": "passed",
        "artifacts": ["ci-job:immutable-12345"],
        "issuer": "independent-release-attestor",
        "key_id": hashlib.sha256(TEST_KEY).hexdigest(),
        "signature": "",
    }
    sign_evidence(payload)
    return payload


def tree_fingerprint(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[relative] = f"symlink:{os.readlink(path)}"
        elif path.is_file():
            result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
        elif path.is_dir():
            result[relative] = "directory"
    return result


class CertificationFixture:
    def __init__(
        self,
        *,
        mutate_first_evidence: object | None = None,
        v1_evidence: str | None = None,
        manifest_schema_version: object = 2,
        omit_canonical_row: bool = False,
        source_commit_override: str | None = None,
        production_na: bool = False,
        first_link_as_image: bool = False,
        manifest_mutation: str | None = None,
        named_evidence_mutation: str | None = None,
        manifest_claim: str = "harness-ready",
        manifest_environment: object = "ci",
        authority_shape: str | None = None,
        include_production_files_when_na: bool = False,
        gitattributes_filter: bool = False,
    ) -> None:
        self.repository_temporary = tempfile.TemporaryDirectory()
        self.key_temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.repository_temporary.name)
        self.key_path = Path(self.key_temporary.name) / "attestation.key"
        self.key_path.write_bytes(TEST_KEY)
        self.key_path.chmod(0o600)

        git(self.root, "init", "-q")
        git(self.root, "config", "user.name", "Harness Test")
        git(self.root, "config", "user.email", "harness@example.invalid")
        put(
            self.root,
            "AGENTS.md",
            "# Project map\n\n"
            "[Architecture](ARCHITECTURE.md)\n"
            "[Coverage](docs/agent-harness/coverage-matrix.md)\n"
            "[Certification](docs/agent-harness/certification.json)\n",
        )
        put(
            self.root,
            "ARCHITECTURE.md",
            "# Architecture\n\nThe test fixture has one local validation boundary.\n",
        )
        put(
            self.root,
            "Makefile",
            "verify-harness:\n\t@printf 'verified\\n'\n",
        )
        put(self.root, ".gitignore", ".env\n")
        if gitattributes_filter:
            put(self.root, ".gitattributes", "*.md filter=evil\n")
        source_paths = [".gitignore", "AGENTS.md", "ARCHITECTURE.md", "Makefile"]
        if gitattributes_filter:
            source_paths.append(".gitattributes")
        git(
            self.root,
            "add",
            *source_paths,
        )
        git(self.root, "commit", "-q", "-m", "source")
        self.real_source_commit = git(self.root, "rev-parse", "HEAD")
        self.source_commit = source_commit_override or self.real_source_commit

        now = datetime.now(timezone.utc)
        observed_at = (now - timedelta(minutes=2)).isoformat(
            timespec="seconds"
        ).replace("+00:00", "Z")
        issued_at = (now - timedelta(minutes=1)).isoformat(
            timespec="seconds"
        ).replace("+00:00", "Z")
        expires_at = (now + timedelta(hours=1)).isoformat(
            timespec="seconds"
        ).replace("+00:00", "Z")
        stale_observed_at = (now - timedelta(hours=72)).isoformat(
            timespec="seconds"
        ).replace("+00:00", "Z")
        post_issue_observed_at = now.isoformat(timespec="seconds").replace(
            "+00:00", "Z"
        )

        template = (
            harness.TEMPLATE_ROOT / "docs/agent-harness/coverage-matrix.md"
        ).read_text(encoding="utf-8")
        rows, _, _, _ = harness.coverage_table_rows(template)
        if omit_canonical_row:
            rows = rows[1:]
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
                if harness.normalize_coverage_identity(row.identity)
                == production_identity
                else "ci"
            )
            payload = evidence_payload(
                row.identity,
                self.source_commit,
                observed_at,
                environment=environment,
            )
            status_text = "verified — [fresh evidence]"
            if index == 0 and mutate_first_evidence is not None:
                if mutate_first_evidence == "false-exit":
                    payload["exit_code"] = False
                elif mutate_first_evidence == "float-exit":
                    payload["exit_code"] = 0.0
                elif mutate_first_evidence == "empty-capability":
                    payload["capabilities"] = [row.identity, ""]
                elif mutate_first_evidence == "repository-identity":
                    payload["repository_identity"] = (
                        "scm://example.invalid/attacker/replayed-repository"
                    )
                elif mutate_first_evidence == "deployment-target":
                    payload["deployment_target_id"] = (
                        "deploy://example.invalid/production/replayed-target"
                    )
                elif mutate_first_evidence == "wrong-capability":
                    payload["capabilities"] = ["different-capability"]
                elif mutate_first_evidence == "stale":
                    payload["observed_at"] = stale_observed_at
                elif mutate_first_evidence == "postissue":
                    payload["observed_at"] = post_issue_observed_at
                elif mutate_first_evidence == "n/a":
                    payload["exit_code"] = None
                    payload["result"] = "not-applicable"
                    status_text = "N/A — [applicability evidence]"
                elif mutate_first_evidence == "duplicate-json":
                    pass
                else:
                    raise AssertionError(f"unknown mutation: {mutate_first_evidence}")
                sign_evidence(payload)
            if (
                production_na
                and harness.normalize_coverage_identity(row.identity)
                == production_identity
            ):
                payload["exit_code"] = None
                payload["result"] = "not-applicable"
                status_text = "N/A — [applicability evidence]"
                sign_evidence(payload)
            serialized_payload = json.dumps(payload, indent=2)
            if index == 0 and mutate_first_evidence == "duplicate-json":
                serialized_payload = serialized_payload.replace(
                    '"result": "passed"',
                    '"result": "failed",\n  "result": "passed"',
                    1,
                )
            put(
                self.root,
                f"docs/agent-harness/evidence/{filename}",
                serialized_payload,
            )
            opening = "!" if first_link_as_image and index == 0 else ""
            coverage_lines.append(
                f"| {row.identity} | Project-native implementation | Observed behavior | "
                f"{status_text.replace('[', opening + '[', 1)}"
                f"(evidence/{filename}) |"
            )
        coverage_text = "\n".join(coverage_lines) + "\n"
        put(
            self.root,
            "docs/agent-harness/coverage-matrix.md",
            coverage_text,
        )

        named = {
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
        for filename, (capability, environment, command) in named.items():
            if (
                production_na
                and not include_production_files_when_na
                and filename
                in {"production-approval.json", "production-rollback.json"}
            ):
                continue
            payload = evidence_payload(
                capability,
                self.source_commit,
                observed_at,
                environment=environment,
                command=command,
            )
            if v1_evidence == filename:
                payload = {
                    "schema_version": 1,
                    "repository_commit": self.source_commit,
                    "capabilities": [capability],
                    "environment": environment,
                    "command": command,
                    "exit_code": 0,
                    "observed_at": observed_at,
                    "result": "passed",
                    "artifacts": ["locally-forged-production-result"],
                }
            if (
                named_evidence_mutation == "approval-environment"
                and filename == "production-approval.json"
            ):
                payload["environment"] = "ci"
            put(
                self.root,
                f"docs/agent-harness/evidence/{filename}",
                json.dumps(payload, indent=2),
            )

        manifest: dict[str, object] = {
            "schema_version": manifest_schema_version,
            "claim": manifest_claim,
            "profile": "adaptive",
            "repository_commit": self.source_commit,
            "repository_identity": REPOSITORY_IDENTITY,
            "deployment_target_id": DEPLOYMENT_TARGET_ID,
            "environment": manifest_environment,
            "issued_at": issued_at,
            "expires_at": expires_at,
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
            "production_authority": (
                {
                    "owner": None,
                    "approval_evidence": None,
                    "rollback_evidence": None,
                }
                if (
                    authority_shape == "null"
                    or (production_na and authority_shape != "configured")
                )
                else {
                    "owner": "release-engineering",
                    "approval_evidence": "docs/agent-harness/evidence/production-approval.json",
                    "rollback_evidence": "docs/agent-harness/evidence/production-rollback.json",
                }
            ),
        }
        if manifest_mutation == "expired":
            manifest["expires_at"] = issued_at
        elif manifest_mutation == "coverage-digest":
            manifest["coverage_sha256"] = "0" * 64
        elif manifest_mutation == "triggers":
            maintenance = manifest["maintenance"]
            assert isinstance(maintenance, dict)
            maintenance["triggers"] = ["push"]
        elif manifest_mutation == "manual-triggers":
            maintenance = manifest["maintenance"]
            assert isinstance(maintenance, dict)
            maintenance["triggers"] = ["manual"]
        elif manifest_mutation == "native-evidence":
            project_gate = manifest["project_native_gate"]
            assert isinstance(project_gate, dict)
            project_gate["evidence"] = "docs/agent-harness/coverage-matrix.md"
        elif manifest_mutation is not None:
            raise AssertionError(f"unknown manifest mutation: {manifest_mutation}")
        put(
            self.root,
            harness.CERTIFICATION_REL,
            json.dumps(manifest, indent=2),
        )
        git(self.root, "add", "docs/agent-harness")
        git(self.root, "commit", "-q", "-m", "authenticated attestation overlay")
        self.attestation_commit = git(self.root, "rev-parse", "HEAD")

    def close(self) -> None:
        self.repository_temporary.cleanup()
        self.key_temporary.cleanup()

    def run_cli(
        self,
        *,
        root: Path | None = None,
        commit: str | None = None,
        key_path: Path | None = None,
        allow_non_git: bool = False,
        require_production_attestation: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        arguments = [
            sys.executable,
            str(SCRIPT),
            "certify",
            "--root",
            str(root or self.root),
            "--profile",
            "adaptive",
            "--commit",
            commit or self.attestation_commit,
            "--attestation-key-file",
            str(key_path or self.key_path),
            "--format",
            "json",
        ]
        if allow_non_git:
            arguments.append("--allow-non-git")
        if require_production_attestation:
            arguments.append("--require-production-attestation")
        return subprocess.run(
            arguments,
            text=True,
            capture_output=True,
            check=False,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )


class CertificationSecurityTests(unittest.TestCase):
    def fixture(self, **kwargs: object) -> CertificationFixture:
        fixture = CertificationFixture(**kwargs)
        self.addCleanup(fixture.close)
        return fixture

    def assert_failed_with(
        self,
        result: subprocess.CompletedProcess[str],
        finding: str,
    ) -> dict[str, object]:
        self.assertNotEqual(0, result.returncode, result.stdout)
        payload = json.loads(result.stdout)
        findings = payload["findings"]
        self.assertIn(finding, {item["id"] for item in findings})
        self.assertNotIn("CERT000", {item["id"] for item in findings})
        return payload

    def test_complete_harness_contract_certifies_read_only(self) -> None:
        fixture = self.fixture()
        before = tree_fingerprint(fixture.root)
        result = fixture.run_cli()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        payload = json.loads(result.stdout)
        ids = {item["id"] for item in payload["findings"]}
        self.assertIn("CERT000", ids)
        self.assertNotIn("CERT015", ids)
        self.assertEqual(0, payload["summary"]["errors"])
        self.assertEqual(0, payload["summary"]["warnings"])
        self.assertEqual(before, tree_fingerprint(fixture.root))

    def test_optional_production_attestation_fails_without_external_verifier(
        self,
    ) -> None:
        fixture = self.fixture(manifest_environment="production")
        result = fixture.run_cli(require_production_attestation=True)
        payload = self.assert_failed_with(result, "CERT015")
        certification_errors = {
            item["id"]
            for item in payload["findings"]
            if item["severity"] == "error" and item["id"].startswith("CERT")
        }
        self.assertEqual({"CERT015"}, certification_errors)

    def test_strict_production_attestation_rejects_non_production_scope(
        self,
    ) -> None:
        fixture = self.fixture()
        result = fixture.run_cli(require_production_attestation=True)
        payload = self.assert_failed_with(result, "CERT003")
        ids = {item["id"] for item in payload["findings"]}
        self.assertNotIn("CERT015", ids)

    def test_production_authority_shape_matches_coverage_applicability(
        self,
    ) -> None:
        cases = (
            {"production_na": True, "authority_shape": "configured"},
            {"production_na": False, "authority_shape": "null"},
        )
        for case in cases:
            with self.subTest(case=case):
                fixture = CertificationFixture(**case)
                try:
                    payload = self.assert_failed_with(
                        fixture.run_cli(),
                        "CERT011",
                    )
                    self.assertNotIn(
                        "CERT000",
                        {item["id"] for item in payload["findings"]},
                    )
                finally:
                    fixture.close()

    def test_harness_environment_is_substantive_and_exactly_typed(self) -> None:
        for environment in (None, False, "", "<replace-with-scope>"):
            with self.subTest(environment=environment):
                fixture = CertificationFixture(
                    manifest_environment=environment,
                )
                try:
                    payload = self.assert_failed_with(
                        fixture.run_cli(),
                        "CERT003",
                    )
                    self.assertNotIn(
                        "CERT000",
                        {item["id"] for item in payload["findings"]},
                    )
                finally:
                    fixture.close()

    def test_non_deployable_overlay_rejects_unreferenced_authority_files(
        self,
    ) -> None:
        fixture = self.fixture(
            production_na=True,
            include_production_files_when_na=True,
        )
        payload = self.assert_failed_with(fixture.run_cli(), "CERT014")
        self.assertNotIn(
            "CERT000",
            {item["id"] for item in payload["findings"]},
        )

    def test_v1_locally_forged_production_evidence_is_rejected(self) -> None:
        fixture = self.fixture(v1_evidence="production-approval.json")
        payload = self.assert_failed_with(fixture.run_cli(), "CERT008")
        messages = " ".join(item["message"] for item in payload["findings"])
        self.assertIn("v1 evidence is never valid", messages)

    def test_v1_manifest_is_never_a_production_certificate(self) -> None:
        fixture = self.fixture(manifest_schema_version=1)
        payload = self.assert_failed_with(fixture.run_cli(), "CERT002")
        messages = " ".join(item["message"] for item in payload["findings"])
        self.assertIn("v1 manifests can never establish candidate integrity", messages)

    def test_bundled_v2_manifest_rejects_production_ready_claim(self) -> None:
        fixture = self.fixture(manifest_claim="production-ready")
        payload = self.assert_failed_with(fixture.run_cli(), "CERT003")
        ids = {item["id"] for item in payload["findings"]}
        self.assertNotIn("CERT015", ids)
        self.assertNotIn("CERT000", ids)

    def test_boolean_float_and_empty_capability_evidence_fail_closed(self) -> None:
        cases = {
            "false-exit": "exact integer exit_code 0",
            "float-exit": "exact integer exit_code 0",
            "empty-capability": "only non-empty strings",
        }
        for mutation, expected_message in cases.items():
            with self.subTest(mutation=mutation):
                fixture = CertificationFixture(mutate_first_evidence=mutation)
                try:
                    payload = self.assert_failed_with(
                        fixture.run_cli(), "CERT009"
                    )
                    messages = " ".join(
                        item["message"] for item in payload["findings"]
                    )
                    self.assertIn(expected_message, messages)
                finally:
                    fixture.close()

    def test_adaptive_certification_requires_every_canonical_coverage_row(self) -> None:
        fixture = self.fixture(omit_canonical_row=True)
        payload = self.assert_failed_with(fixture.run_cli(), "COVERAGE003")
        self.assertGreater(payload["summary"]["warnings"], 0)

    def test_nonexistent_source_and_attestation_commits_are_rejected(self) -> None:
        missing = "f" * 40
        source_fixture = self.fixture(source_commit_override=missing)
        self.assert_failed_with(source_fixture.run_cli(), "CERT014")

        attestation_fixture = self.fixture()
        self.assert_failed_with(
            attestation_fixture.run_cli(commit=missing),
            "CERT014",
        )

    def test_dirty_worktree_and_non_git_copy_are_rejected(self) -> None:
        fixture = self.fixture()
        put(fixture.root, "untracked.txt", "drift\n")
        self.assert_failed_with(fixture.run_cli(), "CERT014")

        non_git_temporary = tempfile.TemporaryDirectory()
        self.addCleanup(non_git_temporary.cleanup)
        non_git_root = Path(non_git_temporary.name)
        for child in fixture.root.iterdir():
            if child.name == ".git":
                continue
            target = non_git_root / child.name
            if child.is_dir():
                shutil.copytree(child, target)
            else:
                shutil.copy2(child, target)
        self.assert_failed_with(
            fixture.run_cli(root=non_git_root, allow_non_git=True),
            "CERT014",
        )

    def test_any_next_commit_invalidates_the_previous_attestation(self) -> None:
        fixture = self.fixture()
        put(fixture.root, "later.txt", "subsequent source drift\n")
        git(fixture.root, "add", "later.txt")
        git(fixture.root, "commit", "-q", "-m", "later change")
        next_commit = git(fixture.root, "rev-parse", "HEAD")
        self.assert_failed_with(
            fixture.run_cli(commit=fixture.attestation_commit),
            "CERT014",
        )
        self.assert_failed_with(
            fixture.run_cli(commit=next_commit),
            "CERT014",
        )

    def test_assume_unchanged_cannot_hide_worktree_drift(self) -> None:
        fixture = self.fixture()
        certification = fixture.root / harness.CERTIFICATION_REL
        git(
            fixture.root,
            "update-index",
            "--assume-unchanged",
            harness.CERTIFICATION_REL,
        )
        certification.write_text(
            certification.read_text(encoding="utf-8") + "\n",
            encoding="utf-8",
        )
        payload = self.assert_failed_with(fixture.run_cli(), "CERT014")
        messages = " ".join(item["message"] for item in payload["findings"])
        self.assertIn("assume-unchanged", messages)

    def test_skip_worktree_cannot_hide_worktree_drift(self) -> None:
        fixture = self.fixture()
        certification = fixture.root / harness.CERTIFICATION_REL
        git(
            fixture.root,
            "update-index",
            "--skip-worktree",
            harness.CERTIFICATION_REL,
        )
        certification.write_text(
            certification.read_text(encoding="utf-8") + "\n",
            encoding="utf-8",
        )
        payload = self.assert_failed_with(fixture.run_cli(), "CERT014")
        messages = " ".join(item["message"] for item in payload["findings"])
        self.assertIn("skip-worktree", messages)

    def test_ignored_untracked_environment_cannot_escape_tree_binding(self) -> None:
        fixture = self.fixture()
        put(fixture.root, ".env", "DEPLOYMENT_TARGET=attacker-controlled\n")
        payload = self.assert_failed_with(fixture.run_cli(), "CERT014")
        messages = " ".join(item["message"] for item in payload["findings"])
        self.assertIn("ignored untracked files", messages)

    def test_tracked_symlink_to_external_fifo_fails_without_blocking(self) -> None:
        if not hasattr(os, "mkfifo"):
            self.skipTest("FIFO creation is unavailable on this platform")
        fixture = self.fixture()
        external_fifo = Path(fixture.key_temporary.name) / "external.fifo"
        os.mkfifo(external_fifo, 0o600)
        tracked = fixture.root / "ARCHITECTURE.md"
        tracked.unlink()
        tracked.symlink_to(external_fifo)
        result = fixture.run_cli()
        payload = self.assert_failed_with(result, "CERT014")
        messages = " ".join(item["message"] for item in payload["findings"])
        self.assertIn("hashed safely", messages)

    def test_signed_identity_and_deployment_target_replay_are_rejected(self) -> None:
        cases = {
            "repository-identity": "repository_identity does not match",
            "deployment-target": "deployment_target_id does not match",
        }
        for mutation, expected_message in cases.items():
            with self.subTest(mutation=mutation):
                fixture = CertificationFixture(mutate_first_evidence=mutation)
                try:
                    payload = self.assert_failed_with(
                        fixture.run_cli(), "CERT009"
                    )
                    messages = " ".join(
                        item["message"] for item in payload["findings"]
                    )
                    self.assertIn(expected_message, messages)
                finally:
                    fixture.close()

    def test_missing_no_follow_platform_capability_fails_closed(self) -> None:
        fixture = self.fixture()
        with mock.patch.object(harness.os, "supports_dir_fd", set()):
            issue = harness.git_index_worktree_issue(fixture.root)
        self.assertIn("descriptor-relative no-follow", issue or "")

    def test_repository_clean_filter_is_never_executed(self) -> None:
        fixture = self.fixture(gitattributes_filter=True)
        sentinel = Path(fixture.key_temporary.name) / "filter-ran"
        filter_script = Path(fixture.key_temporary.name) / "evil-filter"
        filter_script.write_text(
            "#!/bin/sh\n"
            f": > {shlex.quote(str(sentinel))}\n"
            "cat\n",
            encoding="utf-8",
        )
        filter_script.chmod(0o700)
        git(fixture.root, "config", "filter.evil.clean", str(filter_script))
        git(fixture.root, "config", "filter.evil.required", "true")
        result = fixture.run_cli()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        payload = json.loads(result.stdout)
        ids = {item["id"] for item in payload["findings"]}
        self.assertIn("CERT000", ids)
        self.assertNotIn("CERT015", ids)
        self.assertNotIn("CERT014", ids)
        self.assertFalse(sentinel.exists())

    def test_readonly_git_bounds_both_pipes_and_kills_the_process_group(self) -> None:
        if os.name != "posix" or not hasattr(os, "fork"):
            self.skipTest("POSIX process-group fixture is unavailable")
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        root = base / "repository"
        root.mkdir()
        child_pid_path = base / "child.pid"
        marker = base / "completed"
        fake_git = base / "git"
        fake_git.write_text(
            "#!/usr/bin/env python3\n"
            "import os\n"
            "import signal\n"
            "import time\n"
            f"pid_path = {str(child_pid_path)!r}\n"
            f"marker = {str(marker)!r}\n"
            "child = os.fork()\n"
            "if child == 0:\n"
            "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "    time.sleep(30)\n"
            "    os._exit(0)\n"
            "with open(pid_path, 'w', encoding='ascii') as handle:\n"
            "    handle.write(str(child))\n"
            "chunk = b'x' * 65536\n"
            "for _ in range(4096):\n"
            "    os.write(1, chunk)\n"
            "    os.write(2, chunk)\n"
            "with open(marker, 'w', encoding='ascii') as handle:\n"
            "    handle.write('unbounded')\n",
            encoding="utf-8",
        )
        fake_git.chmod(0o700)

        with (
            mock.patch.object(harness.shutil, "which", return_value=str(fake_git)),
            mock.patch.object(harness, "MAX_GIT_COMMAND_OUTPUT_BYTES", 1024),
        ):
            code, output, issue = harness.readonly_git(root, ("status",))
        self.assertIsNone(code)
        self.assertEqual(b"", output)
        self.assertIn("bounded output budget", issue or "")
        self.assertFalse(marker.exists())
        self.assertTrue(child_pid_path.is_file())
        child_pid = int(child_pid_path.read_text(encoding="ascii"))
        for _ in range(100):
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.01)
        else:
            self.fail("bounded Git query left a process-group child running")

    def test_prefix_compressed_index_output_is_stopped_at_the_pipe_budget(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        git(root, "init", "-q")
        blob = subprocess.run(
            ["git", "-C", str(root), "hash-object", "-w", "--stdin"],
            input=b"x",
            capture_output=True,
            check=True,
        ).stdout.decode("ascii").strip()
        prefix = ("a" * 200 + "/") * 4
        index_rows = "".join(
            f"100644 {blob}\t{prefix}{index:05d}\n"
            for index in range(3_000)
        )
        subprocess.run(
            ["git", "-C", str(root), "update-index", "--index-info"],
            input=index_rows,
            text=True,
            capture_output=True,
            check=True,
        )
        git(root, "update-index", "--index-version", "4")
        self.assertLess((root / ".git/index").stat().st_size, 1024 * 1024)

        code, output, issue = harness.readonly_git(
            root, ("ls-files", "-v", "-z")
        )
        self.assertIsNone(code)
        self.assertEqual(b"", output)
        self.assertIn("bounded output budget", issue or "")

    def test_oversized_compressed_commit_is_rejected_before_parent_walk(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        git(root, "init", "-q")
        git(root, "config", "user.name", "Harness Test")
        git(root, "config", "user.email", "harness@example.invalid")
        put(root, "source.txt", "source\n")
        git(root, "add", "source.txt")
        git(root, "commit", "-q", "-m", "source")
        source_commit = git(root, "rev-parse", "HEAD")
        tree = git(root, "rev-parse", "HEAD^{tree}")
        oversized_message = "A" * (
            harness.MAX_CERTIFICATION_COMMIT_OBJECT_BYTES + 1024
        )
        attestation = subprocess.run(
            [
                "git",
                "-c",
                "user.name=Harness Test",
                "-c",
                "user.email=harness@example.invalid",
                "-C",
                str(root),
                "commit-tree",
                tree,
                "-p",
                source_commit,
            ],
            input=oversized_message,
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
        git(root, "update-ref", "HEAD", attestation)

        with mock.patch.object(
            harness,
            "readonly_git",
            wraps=harness.readonly_git,
        ) as readonly:
            issue = harness.git_attestation_issue(
                root,
                source_commit=source_commit,
                attestation_commit=attestation,
                allowed_overlay_paths=set(),
            )
        self.assertIn("commit object exceeds", issue or "")
        commands = [call.args[1] for call in readonly.call_args_list]
        self.assertNotIn(
            ("rev-list", "--parents", "--max-count=1", attestation),
            commands,
        )
        self.assertFalse(any(command[:1] == ("diff-tree",) for command in commands))

    def test_promisor_remote_config_cannot_execute_during_object_lookup(self) -> None:
        if os.name != "posix":
            self.skipTest("executable transport fixture is POSIX-only")
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        root = base / "repository"
        root.mkdir()
        git(root, "init", "-q")
        marker = base / "lazy-fetch-ran"
        fake_ssh = base / "fake-ssh"
        fake_ssh.write_text(
            "#!/bin/sh\n"
            f": > {shlex.quote(str(marker))}\n"
            "exit 7\n",
            encoding="utf-8",
        )
        fake_ssh.chmod(0o700)
        git(root, "config", "extensions.partialClone", "origin")
        git(root, "config", "remote.origin.promisor", "true")
        git(root, "config", "remote.origin.partialclonefilter", "blob:none")
        git(root, "config", "remote.origin.url", "ssh://example.invalid/repository")
        git(root, "config", "protocol.ssh.allow", "always")
        git(root, "config", "core.sshCommand", str(fake_ssh))
        missing = "3" * 40

        control = subprocess.run(
            ["git", "-C", str(root), "cat-file", "-t", missing],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=5,
            env={
                **os.environ,
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_TERMINAL_PROMPT": "0",
            },
        )
        self.assertNotEqual(0, control.returncode)
        self.assertTrue(marker.exists(), control.stderr)
        marker.unlink()

        code, output, issue = harness.readonly_git(
            root, ("cat-file", "-t", missing)
        )
        self.assertNotEqual(0, code)
        self.assertEqual(b"", output)
        self.assertIn("Git query failed", issue or "")
        self.assertFalse(marker.exists())

    def test_tracked_byte_budget_returns_a_fail_closed_issue(self) -> None:
        fixture = self.fixture()
        with mock.patch.object(
            harness, "MAX_CERTIFICATION_TRACKED_BYTES", 0
        ):
            issue = harness.git_index_worktree_issue(fixture.root)
        self.assertIn("tracked bytes exceed", issue or "")

    def test_key_and_managed_file_in_place_read_races_fail_closed(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name) / "repository"
        root.mkdir()
        managed = put(root, "managed.json", '{"value":"before"}\n')
        key = Path(temporary.name) / "attestation.key"
        key.write_bytes(TEST_KEY)
        key.chmod(0o600)

        original_read = os.read
        mutated = False

        def mutate_managed_after_read(descriptor: int, size: int) -> bytes:
            nonlocal mutated
            data = original_read(descriptor, size)
            if data and not mutated:
                mutated = True
                managed.write_text('{"value":"after!"}\n', encoding="utf-8")
            return data

        with mock.patch.object(harness.os, "read", mutate_managed_after_read):
            with self.assertRaises(harness.SafeRefusal):
                harness.read_bytes_safe(root, managed)

        mutated = False

        def mutate_key_after_read(descriptor: int, size: int) -> bytes:
            nonlocal mutated
            data = original_read(descriptor, size)
            if data and not mutated:
                mutated = True
                key.write_bytes(b"K" * len(TEST_KEY))
                key.chmod(0o600)
            return data

        with mock.patch.object(harness.os, "read", mutate_key_after_read):
            loaded, key_id, issue = harness.load_external_attestation_key(
                root, key
            )
        self.assertIsNone(loaded)
        self.assertIsNone(key_id)
        self.assertIn("changed while it was being read", issue or "")

    def test_replace_refs_cannot_forge_attestation_lineage(self) -> None:
        fixture = self.fixture()
        put(fixture.root, "later.txt", "later source drift\n")
        git(fixture.root, "add", "later.txt")
        git(fixture.root, "commit", "-q", "-m", "later")
        replacement_subject = git(fixture.root, "rev-parse", "HEAD")
        git(
            fixture.root,
            "replace",
            replacement_subject,
            fixture.attestation_commit,
        )
        self.assert_failed_with(
            fixture.run_cli(commit=replacement_subject),
            "CERT014",
        )

    def test_fork_origin_replay_never_becomes_production_attested(self) -> None:
        fixture = self.fixture(manifest_environment="production")
        replay_temporary = tempfile.TemporaryDirectory()
        self.addCleanup(replay_temporary.cleanup)
        replay_root = Path(replay_temporary.name) / "different-origin"
        completed = subprocess.run(
            ["git", "clone", "-q", str(fixture.root), str(replay_root)],
            text=True,
            capture_output=True,
            check=False,
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        result = fixture.run_cli(
            root=replay_root,
            require_production_attestation=True,
        )
        self.assertNotEqual(0, result.returncode)
        ids = {item["id"] for item in json.loads(result.stdout)["findings"]}
        self.assertIn("CERT015", ids)
        self.assertNotIn("CERT000", ids)

    def test_repository_key_symlink_and_weak_permissions_are_rejected(self) -> None:
        fixture = self.fixture()
        repository_key = put(
            fixture.root,
            "repository-controlled.key",
            TEST_KEY.decode("ascii"),
        )
        self.assert_failed_with(
            fixture.run_cli(key_path=repository_key),
            "CERT012",
        )

        weak_key = Path(fixture.key_temporary.name) / "weak.key"
        weak_key.write_bytes(TEST_KEY)
        weak_key.chmod(0o644)
        self.assert_failed_with(
            fixture.run_cli(key_path=weak_key),
            "CERT012",
        )

        symlink_key = Path(fixture.key_temporary.name) / "symlink.key"
        symlink_key.symlink_to(fixture.key_path)
        self.assert_failed_with(
            fixture.run_cli(key_path=symlink_key),
            "CERT012",
        )

        if hasattr(os, "mkfifo"):
            fifo_key = Path(fixture.key_temporary.name) / "fifo.key"
            os.mkfifo(fifo_key, 0o600)
            self.assert_failed_with(
                fixture.run_cli(key_path=fifo_key),
                "CERT012",
            )


if __name__ == "__main__":
    unittest.main()
