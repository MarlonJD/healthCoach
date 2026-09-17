from __future__ import annotations

import hashlib
import importlib.util
import os
from pathlib import Path, PurePosixPath
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "build_release_zip.py"
ARCHIVE_PREFIX = "apply-harness-engineering"


def isolated_git_environment() -> dict[str, str]:
    environment = {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }
    environment.update(
        {
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Release ZIP Test",
            "GIT_AUTHOR_EMAIL": "release-zip@example.invalid",
            "GIT_COMMITTER_NAME": "Release ZIP Test",
            "GIT_COMMITTER_EMAIL": "release-zip@example.invalid",
            "LC_ALL": "C",
        }
    )
    return environment


def git(root: Path, *arguments: str, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["git", "-C", str(root), *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
        timeout=20,
        env=isolated_git_environment(),
    )


def run_builder(
    root: Path,
    output: Path,
    *,
    timeout: int = 20,
) -> subprocess.CompletedProcess[str]:
    environment = dict(os.environ)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return subprocess.run(
        [
            sys.executable,
            "-B",
            str(SCRIPT),
            "--root",
            str(root),
            "--output",
            str(output),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        text=True,
        timeout=timeout,
        env=environment,
    )


def load_builder_module():
    specification = importlib.util.spec_from_file_location(
        "harness_release_zip_builder_test",
        SCRIPT,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load build_release_zip.py")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


BUILDER = load_builder_module()


class ReleaseZipTests(unittest.TestCase):
    def make_repository(self, parent: Path, name: str = "source") -> Path:
        root = parent / name
        root.mkdir()
        subprocess.run(
            ["git", "init", "-q", str(root)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            timeout=20,
            env=isolated_git_environment(),
        )
        (root / "agents").mkdir()
        (root / "scripts").mkdir()
        (root / "SKILL.md").write_text(
            "---\n"
            "name: apply-harness-engineering\n"
            "description: Explicitly audit and adopt a repository harness.\n"
            "---\n",
            encoding="utf-8",
        )
        (root / "agents" / "openai.yaml").write_text(
            "interface:\n  display_name: Harness\n",
            encoding="utf-8",
        )
        (root / "scripts" / "tool.py").write_text(
            "print('ok')\n",
            encoding="utf-8",
        )
        executable = root / "scripts" / "run.sh"
        executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        executable.chmod(0o755)
        git(root, "add", "--all")
        git(root, "commit", "-q", "-m", "fixture")
        return root

    def commit_all(self, root: Path, message: str = "fixture change") -> None:
        git(root, "add", "--all")
        git(root, "commit", "-q", "-m", message)

    def test_missing_dirfd_capability_fails_with_a_structured_error(self) -> None:
        with mock.patch.object(BUILDER.os, "supports_dir_fd", set()):
            with self.assertRaisesRegex(
                BUILDER.PackageError,
                "requires POSIX dirfd/no-follow primitives",
            ):
                BUILDER._require_secure_filesystem_primitives()

    def test_archive_is_checkout_independent_and_matches_tracked_head(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            first_root = self.make_repository(parent, "checkout-a")
            second_root = parent / "checkout-b"
            subprocess.run(
                ["git", "clone", "-q", "--no-local", str(first_root), str(second_root)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
                timeout=20,
                env=isolated_git_environment(),
            )
            first = parent / "first.zip"
            second = parent / "second.zip"

            first_result = run_builder(first_root, first)
            second_result = run_builder(second_root, second)

            self.assertEqual(0, first_result.returncode, first_result.stderr)
            self.assertEqual(0, second_result.returncode, second_result.stderr)
            self.assertEqual(
                hashlib.sha256(first.read_bytes()).digest(),
                hashlib.sha256(second.read_bytes()).digest(),
            )
            tracked_paths = [
                path.decode("utf-8")
                for path in git(first_root, "ls-files", "-z").stdout.split(b"\x00")
                if path
            ]
            expected_files = {
                f"{ARCHIVE_PREFIX}/{path}": (first_root / path).read_bytes()
                for path in tracked_paths
            }
            with zipfile.ZipFile(first) as archive:
                infos = {info.filename: info for info in archive.infolist()}
                actual_files = {
                    info.filename: archive.read(info)
                    for info in archive.infolist()
                    if not info.is_dir()
                }
                self.assertEqual(expected_files, actual_files)
                self.assertIn(f"{ARCHIVE_PREFIX}/", infos)
                self.assertNotIn("checkout-a", "\n".join(infos))
                for name, info in infos.items():
                    expected_mode = (
                        0o755
                        if name.endswith("/") or name.endswith("/scripts/run.sh")
                        else 0o644
                    )
                    expected_type = stat.S_IFDIR if name.endswith("/") else stat.S_IFREG
                    self.assertEqual((1980, 1, 1, 0, 0, 0), info.date_time)
                    self.assertEqual(3, info.create_system)
                    self.assertEqual(expected_mode, (info.external_attr >> 16) & 0o777)
                    self.assertEqual(
                        expected_type,
                        (info.external_attr >> 16) & 0o170000,
                    )

    def test_dirty_untracked_modified_and_staged_states_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            fixtures = {
                "untracked": lambda root: (root / ".env").write_text(
                    "SECRET=value\n", encoding="utf-8"
                ),
                "modified": lambda root: (root / "SKILL.md").write_text(
                    "changed\n", encoding="utf-8"
                ),
                "staged": lambda root: (
                    (root / "staged.txt").write_text("staged\n", encoding="utf-8"),
                    git(root, "add", "staged.txt"),
                ),
            }
            for name, mutate in fixtures.items():
                with self.subTest(name=name):
                    root = self.make_repository(parent, name)
                    mutate(root)
                    output = parent / f"{name}.zip"

                    result = run_builder(root, output)

                    self.assertEqual(2, result.returncode)
                    self.assertRegex(
                        result.stderr,
                        r"(untracked or ignored|worktree file size differs|"
                        r"index does not exactly match)",
                    )
                    self.assertFalse(output.exists())

    def test_repository_clean_filter_is_never_executed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            marker = parent / "clean-filter-executed"
            (root / ".gitattributes").write_text(
                "SKILL.md filter=pwn\n",
                encoding="utf-8",
            )
            filter_command = (
                "sh -c "
                + shlex.quote(f"touch {shlex.quote(str(marker))}; cat")
            )
            git(root, "config", "filter.pwn.clean", filter_command)
            git(root, "config", "filter.pwn.required", "true")
            self.commit_all(root, "malicious clean filter fixture")
            marker.unlink(missing_ok=True)
            output = parent / "package.zip"

            result = run_builder(root, output)

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertFalse(marker.exists())
            self.assertTrue(output.is_file())

    @unittest.skipUnless(
        Path("/usr/bin/touch").is_file(),
        "partial-clone ext transport fixture requires /usr/bin/touch",
    )
    def test_missing_promised_blob_never_starts_lazy_fetch_transport(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            marker = parent / "lazy-fetch-executed"
            object_id = (
                git(root, "rev-parse", "HEAD:SKILL.md")
                .stdout.decode("ascii")
                .strip()
            )
            object_path = (
                root
                / ".git"
                / "objects"
                / object_id[:2]
                / object_id[2:]
            )
            self.assertTrue(object_path.is_file())
            backup = parent / "missing-promised-blob"
            object_path.rename(backup)
            git(root, "config", "extensions.partialClone", "origin")
            git(root, "config", "remote.origin.promisor", "true")
            git(root, "config", "remote.origin.partialCloneFilter", "blob:none")
            git(root, "config", "protocol.ext.allow", "always")
            git(
                root,
                "config",
                "remote.origin.url",
                f"ext::/usr/bin/touch {marker}",
            )
            output = parent / "package.zip"

            result = run_builder(root, output)

            self.assertEqual(2, result.returncode)
            self.assertFalse(marker.exists())
            self.assertFalse(output.exists())

    def test_index_state_flags_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            fixtures = {
                "assume-unchanged": "--assume-unchanged",
                "skip-worktree": "--skip-worktree",
            }
            for name, option in fixtures.items():
                with self.subTest(name=name):
                    root = self.make_repository(parent, name)
                    git(root, "update-index", option, "SKILL.md")
                    output = parent / f"{name}.zip"

                    result = run_builder(root, output)

                    self.assertEqual(2, result.returncode)
                    self.assertIn("unsupported state flags", result.stderr)
                    self.assertFalse(output.exists())

    def test_ignored_worktree_markers_cannot_replace_tracked_head_markers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            (root / ".gitignore").write_text(
                "SKILL.md\nagents/openai.yaml\n",
                encoding="utf-8",
            )
            git(root, "rm", "SKILL.md", "agents/openai.yaml")
            self.commit_all(root, "remove tracked skill markers")
            (root / "agents").mkdir(exist_ok=True)
            (root / "SKILL.md").write_text(
                "---\nname: ignored-impostor\n---\n",
                encoding="utf-8",
            )
            (root / "agents" / "openai.yaml").write_text(
                "interface: {}\n",
                encoding="utf-8",
            )
            self.assertEqual(
                b"",
                git(
                    root,
                    "status",
                    "--porcelain=v1",
                    "-z",
                    "--untracked-files=all",
                ).stdout,
            )
            output = parent / "package.zip"

            result = run_builder(root, output)

            self.assertEqual(2, result.returncode)
            self.assertIn("regular tracked skill markers", result.stderr)
            self.assertFalse(output.exists())

    def test_tracked_pyc_is_included_instead_of_silently_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            pyc = root / "scripts" / "tool.pyc"
            pyc.write_bytes(b"tracked-bytecode")
            self.commit_all(root)
            output = parent / "package.zip"

            result = run_builder(root, output)

            self.assertEqual(0, result.returncode, result.stderr)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(
                    b"tracked-bytecode",
                    archive.read(f"{ARCHIVE_PREFIX}/scripts/tool.pyc"),
                )

    def test_tracked_symlink_is_rejected_as_an_unsupported_git_entry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            (root / "__pycache__").symlink_to("scripts")
            self.commit_all(root)
            output = parent / "package.zip"

            result = run_builder(root, output)

            self.assertEqual(2, result.returncode)
            self.assertIn("unsupported tracked Git entry", result.stderr)
            self.assertFalse(output.exists())

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO creation is unavailable")
    def test_untracked_fifo_fails_as_dirty_without_being_opened(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            (root / ".gitignore").write_text(".DS_Store\n", encoding="utf-8")
            self.commit_all(root, "ignore adversarial FIFO name")
            os.mkfifo(root / ".DS_Store")
            output = parent / "package.zip"

            result = run_builder(root, output, timeout=10)

            self.assertEqual(2, result.returncode)
            self.assertIn("untracked or ignored", result.stderr)
            self.assertFalse(output.exists())

    def test_portability_hazards_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            for index, unsafe_name in enumerate(
                ("trailing.", "CON.txt", "COM¹", "COM².txt", "LPT³.doc")
            ):
                with self.subTest(name=unsafe_name):
                    root = self.make_repository(parent, f"unsafe-{index}")
                    (root / unsafe_name).write_text("unsafe\n", encoding="utf-8")
                    self.commit_all(root)
                    output = parent / f"unsafe-{index}.zip"

                    result = run_builder(root, output)

                    self.assertEqual(2, result.returncode)
                    self.assertRegex(
                        result.stderr,
                        r"(unsafe portable|reserved Windows)",
                    )
                    self.assertFalse(output.exists())

    def test_casefold_collision_is_rejected_even_on_case_insensitive_hosts(self) -> None:
        files = [
            BUILDER.TrackedFile(PurePosixPath("Readme"), "0" * 40, "100644", 0o644, 0),
            BUILDER.TrackedFile(PurePosixPath("README"), "1" * 40, "100644", 0o644, 0),
        ]

        with self.assertRaisesRegex(BUILDER.PackageError, "portable archive path collision"):
            BUILDER._validate_portable_collisions(files, [])

    def test_existing_output_and_symlink_output_are_never_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            existing = parent / "existing.zip"
            existing.write_bytes(b"keep-existing")
            target = parent / "target"
            target.write_bytes(b"keep-target")
            symlink = parent / "linked.zip"
            symlink.symlink_to(target)

            existing_result = run_builder(root, existing)
            symlink_result = run_builder(root, symlink)

            self.assertEqual(2, existing_result.returncode)
            self.assertIn("refusing to overwrite", existing_result.stderr)
            self.assertEqual(b"keep-existing", existing.read_bytes())
            self.assertEqual(2, symlink_result.returncode)
            self.assertIn("may not be a symlink", symlink_result.stderr)
            self.assertEqual(b"keep-target", target.read_bytes())
            self.assertTrue(symlink.is_symlink())

    def test_control_bearing_output_error_is_one_escaped_line(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            output = parent / "release\nFORGED\x1b[31m.zip"
            output.write_bytes(b"keep")

            result = run_builder(root, output)

            self.assertEqual(2, result.returncode)
            self.assertEqual(1, result.stderr.count("\n"))
            self.assertNotIn("\x1b", result.stderr)
            self.assertNotIn("release\nFORGED", result.stderr)
            self.assertIn("\\u000a", result.stderr)
            self.assertIn("\\u001b", result.stderr)
            self.assertEqual(b"keep", output.read_bytes())

    def test_oversized_control_bearing_tracked_path_error_is_escaped(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            hostile = root / "evil\nFORGED\x1b[31m.bin"
            hostile.write_bytes(b"x" * (BUILDER.MAX_FILE_BYTES + 1))
            self.commit_all(root, "oversized hostile path")
            output = parent / "package.zip"

            result = run_builder(root, output)

            self.assertEqual(2, result.returncode)
            self.assertEqual(1, result.stderr.count("\n"))
            self.assertNotIn("\x1b", result.stderr)
            self.assertNotIn("evil\nFORGED", result.stderr)
            self.assertIn("\\u000a", result.stderr)
            self.assertIn("\\u001b", result.stderr)
            self.assertFalse(output.exists())

    def test_output_inside_repository_is_rejected_without_creation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            output = root / "release.zip"

            result = run_builder(root, output)

            self.assertEqual(2, result.returncode)
            self.assertIn(
                "inside the worktree or Git metadata",
                result.stderr,
            )
            self.assertFalse(output.exists())

    def test_head_mutation_during_blob_reads_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            output = parent / "package.zip"
            original_read_blobs = BUILDER._read_blobs
            mutation_done = False

            def mutating_read_blobs(git_reader, files, *, object_hash):
                nonlocal mutation_done
                contents = original_read_blobs(
                    git_reader,
                    files,
                    object_hash=object_hash,
                )
                if not mutation_done:
                    mutation_done = True
                    (root / "new-head.txt").write_text("new head\n", encoding="utf-8")
                    self.commit_all(root, "change HEAD during package build")
                return contents

            with mock.patch.object(
                BUILDER,
                "_read_blobs",
                side_effect=mutating_read_blobs,
            ):
                with self.assertRaisesRegex(BUILDER.PackageError, "HEAD changed"):
                    BUILDER.build_release_zip(root, output)

            self.assertTrue(mutation_done)
            self.assertFalse(output.exists())

    def test_head_mutation_at_publication_removes_the_stale_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            output = parent / "package.zip"
            original_link = BUILDER.os.link
            mutation_done = False

            def mutating_link(source, destination, **kwargs):
                nonlocal mutation_done
                if not mutation_done:
                    mutation_done = True
                    (root / "published-race.txt").write_text(
                        "new head\n",
                        encoding="utf-8",
                    )
                    self.commit_all(root, "change HEAD at publication")
                return original_link(source, destination, **kwargs)

            with mock.patch.object(
                BUILDER,
                "_require_secure_filesystem_primitives",
                return_value=None,
            ), mock.patch.object(
                BUILDER.os,
                "link",
                side_effect=mutating_link,
            ):
                with self.assertRaisesRegex(
                    BUILDER.PackageError,
                    "HEAD changed during archive publication",
                ):
                    BUILDER.build_release_zip(root, output)

            self.assertTrue(mutation_done)
            self.assertFalse(output.exists())

    def test_path_depth_limit_is_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            over_deep = root.joinpath(*(["d"] * BUILDER.MAX_PATH_DEPTH), "leaf.txt")
            over_deep.parent.mkdir(parents=True)
            over_deep.write_text("deep\n", encoding="utf-8")
            self.commit_all(root)
            output = parent / "package.zip"

            result = run_builder(root, output)

            self.assertEqual(2, result.returncode)
            self.assertIn("over-deep tracked path", result.stderr)
            self.assertFalse(output.exists())

    def test_nested_package_directory_is_not_accepted_as_repository_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            repository = self.make_repository(parent)
            nested = repository / "nested"
            (nested / "agents").mkdir(parents=True)
            (nested / "SKILL.md").write_text("---\nname: nested\n---\n", encoding="utf-8")
            (nested / "agents" / "openai.yaml").write_text(
                "interface: {}\n",
                encoding="utf-8",
            )
            self.commit_all(repository)
            output = parent / "package.zip"

            result = run_builder(nested, output)

            self.assertEqual(2, result.returncode)
            self.assertIn("Git worktree top level", result.stderr)
            self.assertFalse(output.exists())

    def test_maximum_file_fixture_uses_one_bounded_batch_blob_query(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            bulk = root / "bulk"
            bulk.mkdir()
            existing_count = len(
                [
                    path
                    for path in git(root, "ls-files", "-z").stdout.split(b"\x00")
                    if path
                ]
            )
            for index in range(BUILDER.MAX_TRACKED_FILES - existing_count):
                (bulk / f"{index:04d}.txt").write_text(
                    f"{index}\n",
                    encoding="utf-8",
                )
            self.commit_all(root, "maximum bounded tree")
            output = parent / "package.zip"
            original_run = BUILDER.GitReader.run
            batch_calls: list[tuple[str, ...]] = []

            def counting_run(git_reader, arguments, **kwargs):
                if arguments[:2] == ("cat-file", "--batch"):
                    batch_calls.append(tuple(arguments))
                return original_run(git_reader, arguments, **kwargs)

            with mock.patch.object(BUILDER.GitReader, "run", new=counting_run):
                BUILDER.build_release_zip(root, output)

            self.assertEqual([("cat-file", "--batch")], batch_calls)
            with zipfile.ZipFile(output) as archive:
                archived_files = [
                    info for info in archive.infolist() if not info.is_dir()
                ]
                self.assertEqual(BUILDER.MAX_TRACKED_FILES, len(archived_files))

    def test_output_parent_replacement_is_detected_without_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            destination = parent / "destination"
            destination.mkdir()
            moved_destination = parent / "destination-before-swap"
            output = destination / "package.zip"
            original_validation = BUILDER._validate_repository_snapshot
            validation_calls = 0

            def replacing_validation(*args, **kwargs):
                nonlocal validation_calls
                validation_calls += 1
                result = original_validation(*args, **kwargs)
                if validation_calls == 2:
                    destination.rename(moved_destination)
                    destination.mkdir()
                return result

            with mock.patch.object(
                BUILDER,
                "_validate_repository_snapshot",
                side_effect=replacing_validation,
            ):
                with self.assertRaisesRegex(
                    BUILDER.PackageError,
                    r"output directory (?:identity changed|path does not match)",
                ):
                    BUILDER.build_release_zip(root, output)

            self.assertFalse(output.exists())
            self.assertFalse((moved_destination / "package.zip").exists())

    def test_root_replacement_at_initial_identity_check_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent, "selected-root")
            alternate = self.make_repository(parent, "alternate-root")
            (alternate / "SKILL.md").write_text(
                "---\n"
                "name: apply-harness-engineering\n"
                "description: Alternate repository content.\n"
                "---\n",
                encoding="utf-8",
            )
            self.commit_all(alternate, "alternate content")
            saved_root = parent / "selected-root-before-swap"
            output = parent / "package.zip"
            original_identity = BUILDER._identity
            canonical_root = root.resolve()
            swapped = False

            def swapping_identity(path):
                nonlocal swapped
                if Path(path) == canonical_root and not swapped:
                    swapped = True
                    root.rename(saved_root)
                    alternate.rename(root)
                return original_identity(path)

            with mock.patch.object(
                BUILDER,
                "_identity",
                side_effect=swapping_identity,
            ):
                with self.assertRaisesRegex(
                    BUILDER.PackageError,
                    "package root path identity changed",
                ):
                    BUILDER.build_release_zip(root, output)

            self.assertTrue(swapped)
            self.assertFalse(output.exists())

    def test_output_parent_symlink_swap_cannot_publish_into_git_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            destination = parent / "destination"
            destination.mkdir()
            saved_destination = parent / "destination-before-symlink-swap"
            output = destination / "package.zip"
            original_open = BUILDER.os.open
            swapped = False

            def swapping_open(path, flags, mode=0o777, *, dir_fd=None):
                nonlocal swapped
                if (
                    dir_fd is None
                    and Path(path) == destination
                    and not swapped
                ):
                    swapped = True
                    destination.rename(saved_destination)
                    destination.symlink_to(
                        root / ".git",
                        target_is_directory=True,
                    )
                if dir_fd is None:
                    return original_open(path, flags, mode)
                return original_open(path, flags, mode, dir_fd=dir_fd)

            with mock.patch.object(
                BUILDER,
                "_require_secure_filesystem_primitives",
                return_value=None,
            ), mock.patch.object(
                BUILDER.os,
                "open",
                side_effect=swapping_open,
            ):
                with self.assertRaises((OSError, BUILDER.PackageError)):
                    BUILDER.build_release_zip(root, output)

            self.assertTrue(swapped)
            self.assertFalse((root / ".git" / "package.zip").exists())
            self.assertFalse((saved_destination / "package.zip").exists())

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO creation is unavailable")
    def test_regular_to_fifo_preopen_swap_is_nonblocking_and_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = self.make_repository(parent)
            output = parent / "package.zip"
            backup = parent / "SKILL.md.before-fifo-swap"
            original_open = BUILDER.os.open
            swapped = False

            def swapping_open(path, flags, mode=0o777, *, dir_fd=None):
                nonlocal swapped
                if dir_fd is not None and path == "SKILL.md" and not swapped:
                    swapped = True
                    (root / "SKILL.md").rename(backup)
                    os.mkfifo(root / "SKILL.md")
                    if not flags & os.O_NONBLOCK:
                        raise AssertionError("tracked file open must be nonblocking")
                if dir_fd is None:
                    return original_open(path, flags, mode)
                return original_open(path, flags, mode, dir_fd=dir_fd)

            with mock.patch.object(
                BUILDER,
                "_require_secure_filesystem_primitives",
                return_value=None,
            ), mock.patch.object(
                BUILDER.os,
                "open",
                side_effect=swapping_open,
            ):
                with self.assertRaisesRegex(
                    BUILDER.PackageError,
                    "identity changed",
                ):
                    BUILDER.build_release_zip(root, output)

            self.assertTrue(swapped)
            self.assertFalse(output.exists())

    def test_linked_worktree_git_directory_is_not_an_output_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            main = self.make_repository(parent, "main")
            linked = parent / "linked"
            git(main, "worktree", "add", "-q", str(linked), "HEAD")
            common_git_directory = Path(
                git(
                    linked,
                    "rev-parse",
                    "--path-format=absolute",
                    "--git-common-dir",
                )
                .stdout.decode("utf-8")
                .strip()
            )
            output = common_git_directory / "unexpected-release.zip"

            result = run_builder(linked, output)

            self.assertEqual(2, result.returncode)
            self.assertIn(
                "inside the worktree or Git metadata",
                result.stderr,
            )
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
