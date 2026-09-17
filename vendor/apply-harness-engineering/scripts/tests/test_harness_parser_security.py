from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "harness.py"
SPEC = importlib.util.spec_from_file_location("harness_parser_security", SCRIPT)
assert SPEC and SPEC.loader
harness = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = harness
SPEC.loader.exec_module(harness)


class HarnessParserSecurityTests(unittest.TestCase):
    def test_inline_link_closer_parses_each_candidate_once(self) -> None:
        malformed = '(target.md "' + (")" * 8_000)
        with mock.patch.object(
            harness,
            "normalized_link_destination",
            wraps=harness.normalized_link_destination,
        ) as normalized:
            self.assertEqual(
                -1,
                harness.closing_inline_link_parenthesis(malformed, 0),
            )
        self.assertLessEqual(normalized.call_count, 1)

        valid = '(target(a).md "Observed proof")'
        self.assertEqual(
            len(valid) - 1,
            harness.closing_inline_link_parenthesis(valid, 0),
        )

        _, missing = harness.scan_markdown_links(
            " ".join(["[x](target.md (" for _ in range(2_000)])
        )
        self.assertIn(harness.MARKDOWN_PARSE_BUDGET_SENTINEL, missing)

    def test_mismatched_html_end_tags_use_amortized_stack_work(self) -> None:
        count = 4_000
        parser = harness._VisibleHTMLTextParser()
        parser.feed(("<div>" * count) + ("</span>" * count))
        parser.close()
        self.assertEqual(count, len(parser.stack))
        self.assertLessEqual(parser.work_units, count * 2)

        self.assertEqual(
            "beforeafter",
            harness.visible_html_text(
                "before<span hidden>secret<em>nested</em></span>after"
            ),
        )

    def test_unclosed_inline_comment_suffix_is_scanned_once(self) -> None:
        payload = "x<!--" * 12_000
        with mock.patch.object(
            harness,
            "is_escaped",
            wraps=harness.is_escaped,
        ) as escaped:
            self.assertEqual([], harness.valid_html_comment_spans(payload))
        self.assertLessEqual(escaped.call_count, 1)
        self.assertEqual(
            [(1, 17)],
            harness.valid_html_comment_spans("x<!-- visible -->y"),
        )
        inner = "x<!-- bad -- <!-- [Architecture](ARCHITECTURE.md) -->"
        self.assertEqual(
            [(inner.rfind("<!--"), len(inner))],
            harness.valid_html_comment_spans(inner),
        )
        self.assertEqual(
            [],
            harness.markdown_navigation_destinations(inner),
        )
        escaped_then_block = (
            "\\<!-- escaped -->\n"
            "\\<!-- escaped and unclosed\n"
            "<!-- [Architecture](ARCHITECTURE.md)\n"
        )
        block_start = escaped_then_block.rfind("<!--")
        self.assertEqual(
            [(block_start, len(escaped_then_block))],
            harness.valid_html_comment_spans(escaped_then_block),
        )
        self.assertEqual(
            [],
            harness.markdown_navigation_destinations(escaped_then_block),
        )
        cr_only = (
            "paragraph\r<!--\n"
            + harness.ACTIVE_START
            + "\n| plan | title | owner | status |\n"
            + harness.ACTIVE_END
            + "\n"
        )
        self.assertEqual(
            [
                (cr_only.index("<!--"), cr_only.index("-->") + 3),
                (cr_only.rfind("<!--"), cr_only.rfind("-->") + 3),
            ],
            harness.valid_html_comment_spans(cr_only),
        )
        masked_index = harness.mask_index_markdown(cr_only)
        self.assertNotIn(harness.ACTIVE_START, masked_index)
        self.assertIsNone(
            harness.region_lines(
                masked_index,
                harness.ACTIVE_START,
                harness.ACTIVE_END,
            )
        )

    def test_many_comment_openers_share_one_monotonic_closer_scan(self) -> None:
        class CountingText(str):
            find_work = 0
            rfind_work = 0

            def find(
                self,
                substring: str,
                start: int = 0,
                end: int | None = None,
            ) -> int:
                limit = len(self) if end is None else end
                result = (
                    super().find(substring, start)
                    if end is None
                    else super().find(substring, start, end)
                )
                scanned_end = limit if result < 0 else result + len(substring)
                type(self).find_work += max(0, scanned_end - start)
                return result

            def rfind(
                self,
                substring: str,
                start: int = 0,
                end: int | None = None,
            ) -> int:
                limit = len(self) if end is None else end
                type(self).rfind_work += max(0, limit - start)
                return (
                    super().rfind(substring, start)
                    if end is None
                    else super().rfind(substring, start, end)
                )

        repetitions = 8_000
        payload = CountingText(("x<!--" * repetitions) + "-->")
        expected_start = str(payload).rfind("<!--")
        self.assertEqual(
            [(expected_start, len(payload))],
            harness.valid_html_comment_spans(payload),
        )
        self.assertLessEqual(CountingText.find_work, len(payload) * 4)
        self.assertLessEqual(CountingText.rfind_work, len(payload) * 3)

    def test_distinct_backtick_runs_use_one_boundary_index(self) -> None:
        payload = "x".join("`" * width for width in range(1, 500))
        with mock.patch.object(
            harness,
            "inline_code_block_boundaries",
            wraps=harness.inline_code_block_boundaries,
        ) as boundaries:
            self.assertEqual(payload, harness.mask_inline_code_spans(payload))
        self.assertEqual(1, boundaries.call_count)

        control = "before `literal [not-a-link](missing.md)` after"
        masked = harness.mask_inline_code_spans(control)
        self.assertEqual(len(control), len(masked))
        self.assertNotIn("not-a-link", masked)

    def test_scaffold_comment_fingerprints_do_not_retry_unclosed_openers(self) -> None:
        payload = "x<!--" * 12_000
        with mock.patch.object(
            harness.re,
            "finditer",
            side_effect=AssertionError("unanchored retry loop must not be used"),
        ):
            self.assertEqual(set(), harness.scaffold_comment_fingerprints(payload))
        self.assertEqual(
            {"replace this authority"},
            harness.scaffold_comment_fingerprints(
                "<!-- TODO(harness): replace this authority -->"
            ),
        )

    def test_special_html_token_scanner_abandons_one_unclosed_suffix(self) -> None:
        payload = "x<![CDATA[" * 12_000
        with mock.patch.object(
            harness,
            "is_escaped",
            wraps=harness.is_escaped,
        ) as escaped:
            self.assertEqual([], harness.inline_special_html_spans(payload))
        self.assertLessEqual(escaped.call_count, 12_000)

        control = (
            "<?proof?> <![CDATA[proof]]> <!DECL proof> "
            "<https://example.test> <agent@example.test>"
        )
        self.assertEqual(5, len(harness.inline_special_html_spans(control)))
        self.assertEqual(
            [(19, 28)],
            harness.inline_special_html_spans(
                "<![CDATA[ unclosed <?proof?>"
            ),
        )

    def test_container_prefix_peeling_uses_offsets_not_suffix_copies(self) -> None:
        list_depth = 12_000
        listed = ("- " * list_depth) + "payload"
        with mock.patch.object(
            harness,
            "list_item_prefix_end",
            wraps=harness.list_item_prefix_end,
        ) as list_prefix:
            content, quote_depth = harness.quoted_container_content(listed)
        self.assertEqual(("payload", 0), (content, quote_depth))
        self.assertEqual(list_depth + 1, list_prefix.call_count)

        quote_depth = 12_000
        quoted = ("> " * quote_depth) + "payload\n"
        with mock.patch.object(
            harness,
            "blockquote_prefix_end",
            wraps=harness.blockquote_prefix_end,
        ) as quote_prefix:
            normalized = harness.normalize_blockquote_container_indentation(quoted)
        self.assertTrue(normalized.text.endswith("payload\n"))
        self.assertEqual(quote_depth + 1, quote_prefix.call_count)

    def test_nested_labels_share_one_work_budget_and_fail_closed(self) -> None:
        unit = ("[" * 63) + "x" + ("](target.md)" * 63)
        with mock.patch.object(
            harness,
            "_scan_markdown_links_with_budget",
            wraps=harness._scan_markdown_links_with_budget,
        ) as scans:
            destinations, missing = harness.scan_markdown_links(unit)
        self.assertEqual(["target.md"], destinations)
        self.assertEqual([], missing)
        self.assertLessEqual(scans.call_count, 64)

        destinations, missing = harness.scan_markdown_links("\n".join([unit] * 4))
        self.assertLessEqual(len(destinations), 4)
        self.assertIn(harness.MARKDOWN_PARSE_BUDGET_SENTINEL, missing)

    def test_heading_slug_handles_unmatched_image_prefixes_linearly(self) -> None:
        payload = ("![" * 12_000) + "proof"
        self.assertEqual("proof", harness.markdown_heading_slug(payload))
        self.assertEqual(
            "release-proof",
            harness.markdown_heading_slug(
                "[Release](release.md) ![proof](proof.png)"
            ),
        )

    def test_missing_link_diagnostics_are_bounded_and_fail_closed(self) -> None:
        total = harness.MAX_MARKDOWN_LINK_RESULTS + 500
        payload = "\n".join(
            f"[label-{index}][missing-{index}]" for index in range(total)
        )
        root = Path("/tmp/harness-parser-security").resolve()
        source = root / "README.md"
        report = harness.Report(command="check", root=str(root))
        harness.check_text_links(report, root, source, payload)
        ids = {finding.id for finding in report.findings}
        self.assertIn("LINK004", ids)
        self.assertLessEqual(
            len(report.findings),
            harness.MAX_MARKDOWN_LINK_RESULTS + 1,
        )

    def test_global_report_admission_is_bounded_and_fail_closed(self) -> None:
        root = Path("/tmp/harness-parser-global-report").resolve()
        report = harness.Report(command="check", root=str(root))
        payload = "\n".join(
            f"[label-{index}](missing-{index}.md)" for index in range(128)
        )
        for file_index in range(32):
            harness.check_text_links(
                report,
                root,
                root / f"file-{file_index}.md",
                payload,
            )
        encoded = json.dumps(report.payload(), sort_keys=True)
        self.assertLessEqual(len(report.findings), harness.MAX_REPORT_FINDINGS)
        self.assertIn("REPORT001", {item.id for item in report.findings})
        self.assertTrue(report.payload()["truncated"])
        self.assertGreater(report.payload()["omitted"]["findings"], 0)
        self.assertLess(len(encoded), harness.MAX_REPORT_TEXT_CHARS * 8)

        action_report = harness.Report(command="scaffold", root=str(root))
        for action_index in range(harness.MAX_REPORT_ACTIONS + 100):
            action_report.add_action(
                {"action": "would-create", "path": f"path-{action_index}"}
            )
        self.assertLessEqual(
            len(action_report.actions),
            harness.MAX_REPORT_ACTIONS,
        )
        self.assertIn(
            "REPORT001",
            {item.id for item in action_report.findings},
        )
        self.assertGreater(action_report.payload()["omitted"]["actions"], 0)

        post_cap_report = harness.Report(command="check", root=str(root))
        with mock.patch.object(harness, "MAX_REPORT_FINDINGS", 2):
            post_cap_report.add("ONE", "error", ".", "one", "one")
            post_cap_report.add("TWO", "error", ".", "two", "two")

            class PoisonFinding:
                @property
                def id(self):
                    raise AssertionError("post-cap additions must not rescan findings")

            post_cap_report.findings.insert(0, PoisonFinding())
            post_cap_report.add("THREE", "error", ".", "three", "three")

    def test_markdown_traversal_budgets_stop_early_and_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            for index in range(40):
                (root / f"{index:04d}.md").write_text("", encoding="utf-8")
            report = harness.Report(command="check", root=str(root))
            with mock.patch.object(harness, "MAX_MARKDOWN_FILES", 32):
                files = list(harness.markdown_files(root, report))
            self.assertEqual([], files)
            self.assertIn("LINK005", {item.id for item in report.findings})
            self.assertTrue(report.payload()["truncated"])

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / "a.md").write_text("123", encoding="utf-8")
            (root / "b.md").write_text("456", encoding="utf-8")
            report = harness.Report(command="check", root=str(root))
            with mock.patch.object(
                harness,
                "MAX_MARKDOWN_AGGREGATE_BYTES",
                5,
            ):
                files = list(harness.markdown_files(root, report))
            self.assertEqual([], files)
            self.assertIn("LINK005", {item.id for item in report.findings})

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / "alpha.md").write_text("", encoding="utf-8")
            (root / "beta.md").write_text("", encoding="utf-8")
            report = harness.Report(command="check", root=str(root))
            with mock.patch.object(
                harness,
                "MAX_MARKDOWN_PATH_BYTES",
                len(harness.os.fsencode("alpha.md")),
            ):
                files = list(harness.markdown_files(root, report))
            self.assertEqual([], files)
            self.assertIn("LINK005", {item.id for item in report.findings})

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            for name in ("a.txt", "b.txt", "c.txt"):
                (root / name).write_text("", encoding="utf-8")
            report = harness.Report(command="check", root=str(root))
            with mock.patch.object(harness, "MAX_REPOSITORY_WALK_ENTRIES", 2):
                self.assertEqual([], list(harness.markdown_files(root, report)))
            self.assertIn("LINK005", {item.id for item in report.findings})

    def test_literal_container_boundary_text_has_no_parser_authority(self) -> None:
        former_sentinel = "\ue100HARNESS_CONTAINER_BOUNDARY\ue101"
        spoofed = (
            "paragraph\n"
            f"{former_sentinel}\n"
            "[arch]: ARCHITECTURE.md\n"
            "[Architecture][arch]\n"
        )
        control = spoofed.replace(former_sentinel, "ordinary text")
        self.assertEqual(
            harness.markdown_navigation_destinations(control),
            harness.markdown_navigation_destinations(spoofed),
        )
        self.assertEqual([], harness.markdown_navigation_destinations(spoofed))

    def test_heading_link_markup_uses_valid_commonmark_closers(self) -> None:
        controls = {
            '[Foo](target.md "title ) still") Bar': "foo-bar",
            '[Foo](target(a).md "Title") Bar': "foo-bar",
            '[Outer ![Alt](img.png)](target.md) Bar': "outer-alt-bar",
        }
        for source, expected in controls.items():
            with self.subTest(source=source):
                self.assertEqual(expected, harness.markdown_heading_slug(source))

    def test_heading_slugs_preserve_code_and_require_reference_definitions(
        self,
    ) -> None:
        self.assertEqual(
            {"fooid-bar"},
            harness.markdown_anchors("# [Foo][id] Bar\n"),
        )
        self.assertEqual(
            {"foo-bar"},
            harness.markdown_anchors(
                "# [Foo][id] Bar\n\n[id]: target.md\n"
            ),
        )
        self.assertEqual(
            {"a-c", "fooid-bar"},
            harness.markdown_anchors(
                "# A `C`\n\n# `[Foo][id]` Bar\n"
            ),
        )
        self.assertEqual(
            {"full-link", "collapsed-link", "shortcut-link"},
            harness.markdown_anchors(
                "# [Full][full-ref] Link\n"
                "# [Collapsed][] Link\n"
                "# [Shortcut] Link\n\n"
                "[full-ref]: full.md\n"
                "[Collapsed]: collapsed.md\n"
                "[Shortcut]: shortcut.md\n"
            ),
        )

    def test_lifecycle_marker_masking_indexes_comments_once_total(self) -> None:
        repetitions = 4_000
        former_sentinel = (
            "\ue000HARNESS_LIFECYCLE_MARKER_0\ue001"
            + ("\ue002" * 100_000)
        )
        payload = (
            (harness.ACTIVE_START + "\n") * repetitions
            + former_sentinel
            + "\n"
            + "<!-- ordinary comment -->\n"
        )
        with mock.patch.object(
            harness,
            "valid_html_comment_spans",
            wraps=harness.valid_html_comment_spans,
        ) as comments:
            masked = harness.mask_index_markdown(payload)
        self.assertEqual(1, comments.call_count)
        self.assertEqual(repetitions, masked.count(harness.ACTIVE_START))
        self.assertIn(former_sentinel, masked)
        self.assertNotIn("ordinary comment", masked)


if __name__ == "__main__":
    unittest.main()
