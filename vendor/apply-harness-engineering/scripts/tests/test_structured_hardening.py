from __future__ import annotations

from contextlib import redirect_stdout
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts.tests import test_harness as base


harness = base.harness
SCRIPT = base.SCRIPT


class StructuredHardeningTests(unittest.TestCase):
    def make_root(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        return temporary, Path(temporary.name)

    def run_cli(
        self,
        *args: str,
        interpreter: str | Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(interpreter or base.sys.executable), str(SCRIPT), *args],
            text=True,
            capture_output=True,
            check=False,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )

    def test_harness_config_rejects_duplicate_keys_and_boolean_schema(self) -> None:
        cases = {
            "duplicate": (
                '{"schema_version":1,"authorities":'
                '{"coverage":"one.md","coverage":"two.md"}}'
            ),
            "boolean-schema": '{"schema_version":true,"authorities":{}}',
        }
        for label, text in cases.items():
            with self.subTest(label=label):
                temporary, root = self.make_root()
                self.addCleanup(temporary.cleanup)
                base.put(root, harness.CONFIG_REL, text)
                report = harness.Report(command="check", root=str(root))
                authorities = harness.load_authorities(root, report)
                self.assertEqual(
                    harness.DEFAULT_AUTHORITIES["coverage"],
                    authorities["coverage"],
                )
                self.assertIn("CONFIG001", {item.id for item in report.findings})

    def test_deep_harness_config_returns_structured_cli_finding(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        path = base.put(
            root,
            harness.CONFIG_REL,
            "[" * 200 + "0" + "]" * 200,
        )
        before = path.read_bytes()
        result = self.run_cli(
            "audit",
            "--root",
            str(root),
            "--allow-non-git",
            "--format",
            "json",
        )
        self.assertEqual(0, result.returncode)
        self.assertEqual("", result.stderr)
        self.assertIn("CONFIG001", {item["id"] for item in json.loads(result.stdout)["findings"]})
        self.assertEqual(before, path.read_bytes())

    def test_deep_manifest_and_evidence_are_bounded_by_shared_loader(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        root = root.resolve()
        deep = "[" * 200 + "0" + "]" * 200
        manifest = base.put(root, harness.CERTIFICATION_REL, deep)
        payload, issue = harness.certification_json_object(root, manifest)
        self.assertIsNone(payload)
        self.assertIn("nesting exceeds", issue or "")

        evidence = base.put(
            root,
            "docs/agent-harness/evidence/deep.json",
            deep,
        )
        issue = harness.evidence_record_issue(
            root,
            evidence,
            attestation_key=b"x" * 32,
            attestation_key_id="test-key",
            expected_repository_identity="scm://example.invalid/repository",
            expected_deployment_target_id="deploy://example.invalid/production",
            expected_capability="capability",
            expected_status="verified",
            expected_commit=base.CERT_COMMIT,
            now=datetime(2026, 7, 23, 12, 0, tzinfo=timezone.utc),
            not_after=datetime(2026, 7, 23, 11, 30, tzinfo=timezone.utc),
            max_age_hours=48,
        )
        self.assertIn("nesting exceeds", issue or "")

    def test_deep_project_toml_returns_structured_cli_finding(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        path = base.put(
            root,
            harness.CODEX_PROJECT_CONFIG_REL,
            "project_doc_max_bytes = " + "[" * 100 + "0" + "]" * 100 + "\n",
        )
        before = path.read_bytes()
        result = self.run_cli(
            "audit",
            "--root",
            str(root),
            "--allow-non-git",
            "--format",
            "json",
        )
        self.assertEqual(0, result.returncode)
        self.assertEqual("", result.stderr)
        self.assertIn(
            "CODEXCFG001",
            {item["id"] for item in json.loads(result.stdout)["findings"]},
        )
        self.assertEqual(before, path.read_bytes())

    def test_python_39_starts_and_reports_missing_tomllib_as_config_error(self) -> None:
        interpreter = Path("/usr/bin/python3")
        if not interpreter.is_file():
            self.skipTest("system Python is unavailable")
        version = subprocess.run(
            [str(interpreter), "-c", "import sys; print(sys.version_info[:2])"],
            text=True,
            capture_output=True,
            check=False,
        )
        if version.returncode != 0 or "(3, 9)" not in version.stdout:
            self.skipTest("system Python is not Python 3.9")
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        base.put(
            root,
            harness.CODEX_PROJECT_CONFIG_REL,
            "project_doc_max_bytes = 1024\n",
        )
        result = self.run_cli(
            "audit",
            "--root",
            str(root),
            "--allow-non-git",
            "--format",
            "json",
            interpreter=interpreter,
        )
        self.assertEqual(0, result.returncode)
        self.assertEqual("", result.stderr)
        payload = json.loads(result.stdout)
        self.assertIn("CODEXCFG001", {item["id"] for item in payload["findings"]})
        self.assertTrue(
            any("Python 3.11+" in item["message"] for item in payload["findings"])
        )

    def test_owner_validation_is_exactly_typed_bounded_and_linear(self) -> None:
        self.assertTrue(harness.is_substantive_owner("platform-team"))
        self.assertFalse(harness.is_substantive_owner(["platform-team"]))
        self.assertFalse(harness.is_substantive_owner("x" * (harness.MAX_OWNER_CHARS + 1)))
        self.assertFalse(harness.is_substantive_owner("no owner assigned"))
        self.assertFalse(harness.is_substantive_owner("assign later"))

    def test_text_report_escapes_terminal_controls(self) -> None:
        report = harness.Report(command="check\x1b[2J", root="/fixture")
        report.add(
            "TERM001",
            "error",
            "evil\x1b]8;;https://example.invalid\x07name\nnext\u202e",
            "message\rrewritten\u2028continued",
            "remedy\tvalue",
        )
        output = io.StringIO()
        with redirect_stdout(output):
            harness.print_report(report, "text")
        rendered = output.getvalue()
        self.assertNotIn("\x1b", rendered)
        self.assertNotIn("\x07", rendered)
        self.assertNotIn("\r", rendered)
        self.assertIn(r"\x1b", rendered)
        self.assertIn(r"\x07", rendered)
        self.assertIn(r"\nnext", rendered)
        self.assertIn(r"\rrewritten", rendered)
        self.assertIn(r"\tvalue", rendered)
        self.assertIn(r"\u202e", rendered)
        self.assertIn(r"\u2028", rendered)
        self.assertNotIn("\u202e", rendered)
        self.assertNotIn("\u2028", rendered)
        self.assertEqual(
            "Türkçe 日本語 🙂",
            harness.terminal_safe("Türkçe 日本語 🙂"),
        )

    def test_text_report_escapes_unicode_format_separator_and_surrogate_classes(self) -> None:
        raw = "left\u2066middle\u2069\u2029\ud800right"
        rendered = harness.terminal_safe(raw)
        self.assertEqual(
            r"left\u2066middle\u2069\u2029\ud800right",
            rendered,
        )
        for character in ("\u2066", "\u2069", "\u2029", "\ud800"):
            self.assertNotIn(character, rendered)

    def test_default_text_cli_neutralizes_control_bearing_filename(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        malicious_name = "evil\x1b[2J\n[info] CERT000 forged.md"
        (root / malicious_name).write_text("[bad](missing.md)\n", encoding="utf-8")
        result = self.run_cli(
            "check",
            "--root",
            str(root),
            "--allow-non-git",
            "--profile",
            "adaptive",
            "--format",
            "text",
        )
        self.assertEqual(1, result.returncode)
        self.assertEqual("", result.stderr)
        self.assertNotIn("\x1b", result.stdout)
        self.assertNotIn("\n[info] CERT000 forged.md", result.stdout)
        self.assertIn(r"\x1b", result.stdout)
        self.assertIn(r"\n[info] CERT000 forged.md", result.stdout)

    def test_authority_routing_has_an_aggregate_byte_budget(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        base.put(root, "AGENTS.md", "# Routes\n\n[One](one.md)\n")
        base.put(root, "one.md", "[Two](two.md)\n" + "a" * 400)
        base.put(root, "two.md", "[Three](three.md)\n" + "b" * 400)
        base.put(root, "three.md", "# Authority\n")
        report = harness.Report(command="check", root=str(root))
        with mock.patch.object(harness, "MAX_ROUTED_DOCUMENT_BYTES", 512):
            harness.validate_authority_reachability(
                report,
                root,
                {
                    "instructions": "AGENTS.md",
                    "architecture": "three.md",
                },
                harness.DEFAULT_PROJECT_DOC_MAX_BYTES,
                root / "AGENTS.md",
            )
        route_findings = [item for item in report.findings if item.id == "ROUTE003"]
        self.assertEqual(1, len(route_findings))
        self.assertIn("aggregate document budget", route_findings[0].message)


if __name__ == "__main__":
    unittest.main()
