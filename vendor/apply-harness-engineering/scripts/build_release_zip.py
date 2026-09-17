#!/usr/bin/env python3
"""Build a deterministic ZIP from one clean Git HEAD."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import stat
import subprocess
import threading
import time
from typing import Optional, Sequence
import unicodedata
import zipfile


ARCHIVE_PREFIX = "apply-harness-engineering"
ARCHIVE_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
GIT_TIMEOUT_SECONDS = 20
MAX_GIT_METADATA_BYTES = 8 * 1024 * 1024
MAX_TRACKED_FILES = 4_096
MAX_PATH_DEPTH = 32
MAX_COMPONENT_BYTES = 255
MAX_ARCHIVE_PATH_BYTES = 4_096
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024
REQUIRED_TRACKED_PATHS = frozenset({"SKILL.md", "agents/openai.yaml"})
WINDOWS_INVALID_CHARS = frozenset('<>:"\\|?*')
WINDOWS_RESERVED_NAMES = {
    "aux",
    "clock$",
    "con",
    "conin$",
    "conout$",
    "nul",
    "prn",
    *(f"com{number}" for number in range(1, 10)),
    *(f"lpt{number}" for number in range(1, 10)),
    *(f"com{number}" for number in "¹²³"),
    *(f"lpt{number}" for number in "¹²³"),
}


def _safe_diagnostic(value: str) -> str:
    rendered: list[str] = []
    for character in value:
        category = unicodedata.category(character)
        if character == "\\":
            rendered.append("\\\\")
        elif category in {"Cc", "Cf", "Cs", "Zl", "Zp"}:
            codepoint = ord(character)
            escape = "u" if codepoint <= 0xFFFF else "U"
            width = 4 if codepoint <= 0xFFFF else 8
            rendered.append(f"\\{escape}{codepoint:0{width}x}")
        else:
            rendered.append(character)
    return "".join(rendered)


class PackageError(ValueError):
    """Raised when the release snapshot cannot be packaged safely."""

    def __str__(self) -> str:
        return _safe_diagnostic(super().__str__())


def _require_secure_filesystem_primitives() -> None:
    required_dir_fd = ("open", "stat", "link", "unlink")
    missing = [
        name
        for name in required_dir_fd
        if getattr(os, name, None) not in getattr(os, "supports_dir_fd", set())
    ]
    required_no_follow = ("stat", "link")
    missing.extend(
        f"{name}(follow_symlinks=False)"
        for name in required_no_follow
        if getattr(os, name, None)
        not in getattr(os, "supports_follow_symlinks", set())
    )
    if os.scandir not in getattr(os, "supports_fd", set()):
        missing.append("scandir(fd)")
    for name in ("O_DIRECTORY", "O_NOFOLLOW", "fchmod"):
        if not hasattr(os, name):
            missing.append(name)
    if missing:
        raise PackageError(
            "secure release packaging requires POSIX dirfd/no-follow primitives; "
            f"unavailable: {', '.join(missing)}"
        )


def _run_bounded_process(
    command: Sequence[str],
    *,
    environment: dict[str, str],
    input_bytes: bytes,
    max_stdout: int,
    max_stderr: int,
    timeout_seconds: int,
) -> tuple[int, bytes, bytes]:
    """Run one process while actively capping both captured output streams."""

    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    if process.stdin is None or process.stdout is None or process.stderr is None:
        process.kill()
        process.wait()
        raise OSError("could not create bounded Git pipes")

    stdout_buffer = bytearray()
    stderr_buffer = bytearray()
    overflow: list[str] = []
    thread_errors: list[BaseException] = []
    changed = threading.Event()

    def drain(stream, buffer: bytearray, limit: int, label: str) -> None:
        try:
            while True:
                remaining = limit + 1 - len(buffer)
                if remaining <= 0:
                    overflow.append(label)
                    changed.set()
                    return
                chunk = stream.read(min(64 * 1024, remaining))
                if not chunk:
                    return
                buffer.extend(chunk)
                if len(buffer) > limit:
                    overflow.append(label)
                    changed.set()
                    return
                changed.set()
        except BaseException as exc:  # pragma: no cover - defensive pipe failure
            thread_errors.append(exc)
            changed.set()
        finally:
            stream.close()
            changed.set()

    def feed() -> None:
        try:
            if input_bytes:
                process.stdin.write(input_bytes)
            process.stdin.close()
        except BrokenPipeError:
            pass
        except BaseException as exc:  # pragma: no cover - defensive pipe failure
            thread_errors.append(exc)
        finally:
            changed.set()

    threads = [
        threading.Thread(
            target=drain,
            args=(process.stdout, stdout_buffer, max_stdout, "output"),
            daemon=True,
        ),
        threading.Thread(
            target=drain,
            args=(process.stderr, stderr_buffer, max_stderr, "error output"),
            daemon=True,
        ),
        threading.Thread(target=feed, daemon=True),
    ]
    for thread in threads:
        thread.start()

    deadline = time.monotonic() + timeout_seconds
    failure: Optional[str] = None
    while process.poll() is None:
        if overflow:
            failure = f"Git query exceeded its {overflow[0]} budget"
            process.kill()
            break
        if thread_errors:
            failure = f"bounded Git pipe failed: {thread_errors[0]}"
            process.kill()
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            failure = "bounded Git query timed out"
            process.kill()
            break
        changed.wait(min(0.05, remaining))
        changed.clear()

    process.wait()
    for thread in threads:
        thread.join()
    if failure is None and overflow:
        failure = f"Git query exceeded its {overflow[0]} budget"
    if failure is None and thread_errors:
        failure = f"bounded Git pipe failed: {thread_errors[0]}"
    if failure is not None:
        raise PackageError(failure)
    return process.returncode, bytes(stdout_buffer), bytes(stderr_buffer)


@dataclass(frozen=True)
class TrackedFile:
    path: PurePosixPath
    object_id: str
    git_mode: str
    archive_mode: int
    size: int


class GitReader:
    """Run fixed, bounded, non-shell Git queries against one repository."""

    def __init__(self, root: Path) -> None:
        executable = shutil.which("git")
        if executable is None:
            raise PackageError("Git executable is unavailable")
        self.executable = Path(executable).resolve(strict=True)
        try:
            self.executable.relative_to(root)
        except ValueError:
            pass
        else:
            raise PackageError("Git executable may not come from inside the package")
        self.root = root
        self.environment = {
            name: value
            for name, value in os.environ.items()
            if not name.startswith("GIT_")
        }
        self.environment.update(
            {
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_NO_LAZY_FETCH": "1",
                "GIT_NO_REPLACE_OBJECTS": "1",
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_PAGER": "cat",
                "GIT_TERMINAL_PROMPT": "0",
                "LC_ALL": "C",
            }
        )

    def run(
        self,
        arguments: Sequence[str],
        *,
        max_output: int,
        input_bytes: bytes = b"",
    ) -> bytes:
        command = [
            str(self.executable),
            "--no-replace-objects",
            "--no-optional-locks",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "-c",
            "diff.external=",
            "-c",
            "protocol.allow=never",
            "-c",
            "protocol.ext.allow=never",
            "-c",
            "protocol.file.allow=never",
            "-c",
            "submodule.recurse=false",
            "-C",
            str(self.root),
            *arguments,
        ]
        try:
            completed_returncode, stdout, stderr = _run_bounded_process(
                command,
                environment=self.environment,
                input_bytes=input_bytes,
                max_stdout=max_output,
                max_stderr=64 * 1024,
                timeout_seconds=GIT_TIMEOUT_SECONDS,
            )
        except OSError as exc:
            raise PackageError(f"bounded Git query failed: {exc}") from exc
        if completed_returncode != 0:
            detail = stderr[:500].decode(
                "utf-8", errors="backslashreplace"
            )
            raise PackageError(f"Git query failed: {detail!r}")
        return stdout

    def text(self, arguments: Sequence[str], *, max_output: int = 4096) -> str:
        try:
            return self.run(arguments, max_output=max_output).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise PackageError("Git returned non-UTF-8 metadata") from exc


def _identity(path: Path) -> tuple[int, int]:
    metadata = path.stat()
    return metadata.st_dev, metadata.st_ino


def _require_path_identity(
    path: Path,
    expected: tuple[int, int],
    label: str,
) -> None:
    try:
        current = _identity(path)
    except OSError as exc:
        raise PackageError(f"{label} path became unavailable: {path}") from exc
    if current != expected:
        raise PackageError(f"{label} path identity changed: {path}")


def _is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def _resolve_git_path(git: GitReader, root: Path, option: str) -> Path:
    try:
        value = git.text(
            ("rev-parse", "--path-format=absolute", option)
        ).strip()
    except PackageError:
        value = git.text(("rev-parse", option)).strip()
    path = Path(value)
    if not path.is_absolute():
        path = root / path
    return path.resolve(strict=True)


def _portable_component_key(component: str) -> str:
    if (
        component in {"", ".", ".."}
        or component.endswith((" ", "."))
        or any(character in WINDOWS_INVALID_CHARS for character in component)
        or any(unicodedata.category(character).startswith("C") for character in component)
        or len(component.encode("utf-8")) > MAX_COMPONENT_BYTES
    ):
        raise PackageError(f"unsafe portable path component: {component!r}")
    normalized = unicodedata.normalize("NFC", component)
    windows_stem = normalized.split(".", 1)[0].casefold()
    if windows_stem in WINDOWS_RESERVED_NAMES:
        raise PackageError(f"reserved Windows path component: {component!r}")
    return normalized.casefold()


def _portable_path_key(parts: Sequence[str]) -> tuple[str, ...]:
    return tuple(_portable_component_key(part) for part in parts)


def _parse_tracked_files(raw_tree: bytes, object_id_length: int) -> list[TrackedFile]:
    records = [record for record in raw_tree.split(b"\x00") if record]
    if len(records) > MAX_TRACKED_FILES:
        raise PackageError(
            f"tracked file count exceeds the {MAX_TRACKED_FILES}-file limit"
        )
    files: list[TrackedFile] = []
    total_size = 0
    for record in records:
        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode, object_type, object_id, raw_size = metadata.split()
            path_text = raw_path.decode("utf-8")
            git_mode = mode.decode("ascii")
            object_type_text = object_type.decode("ascii")
            object_id_text = object_id.decode("ascii").casefold()
            size_text = raw_size.decode("ascii")
        except (UnicodeDecodeError, ValueError) as exc:
            raise PackageError("Git tree contains malformed metadata or paths") from exc
        if object_type_text != "blob" or git_mode not in {"100644", "100755"}:
            raise PackageError(
                f"unsupported tracked Git entry {path_text!r}: "
                f"mode={git_mode!r}, type={object_type_text!r}"
            )
        if re.fullmatch(rf"[0-9a-f]{{{object_id_length}}}", object_id_text) is None:
            raise PackageError(f"invalid Git object ID for {path_text!r}")
        if not size_text.isascii() or not size_text.isdecimal():
            raise PackageError(f"invalid Git blob size for {path_text!r}")
        size = int(size_text)
        if size > MAX_FILE_BYTES:
            raise PackageError(
                f"tracked file exceeds the {MAX_FILE_BYTES}-byte limit: {path_text}"
            )
        total_size += size
        if total_size > MAX_TOTAL_BYTES:
            raise PackageError(
                f"tracked content exceeds the {MAX_TOTAL_BYTES}-byte package limit"
            )
        raw_parts = path_text.split("/")
        if (
            path_text.startswith("/")
            or "\\" in path_text
            or len(raw_parts) > MAX_PATH_DEPTH
        ):
            raise PackageError(f"unsafe or over-deep tracked path: {path_text!r}")
        _portable_path_key(raw_parts)
        archive_name = f"{ARCHIVE_PREFIX}/{path_text}"
        if len(archive_name.encode("utf-8")) > MAX_ARCHIVE_PATH_BYTES:
            raise PackageError(f"archive path is too long: {path_text!r}")
        files.append(
            TrackedFile(
                path=PurePosixPath(*raw_parts),
                object_id=object_id_text,
                git_mode=git_mode,
                archive_mode=0o755 if git_mode == "100755" else 0o644,
                size=size,
            )
        )
    return files


def _directory_parts(files: Sequence[TrackedFile]) -> list[tuple[str, ...]]:
    directories: set[tuple[str, ...]] = set()
    for tracked in files:
        parts = tracked.path.parts
        for length in range(1, len(parts)):
            directories.add(tuple(parts[:length]))
    return sorted(directories, key=lambda parts: "/".join(parts).encode("utf-8"))


def _validate_portable_collisions(
    files: Sequence[TrackedFile],
    directories: Sequence[tuple[str, ...]],
) -> None:
    seen: dict[tuple[str, ...], tuple[str, tuple[str, ...]]] = {}
    entries = [
        ("directory", parts)
        for parts in directories
    ] + [
        ("file", tuple(tracked.path.parts))
        for tracked in files
    ]
    for kind, parts in entries:
        key = _portable_path_key(parts)
        prior = seen.get(key)
        current = kind, parts
        if prior is not None and prior != current:
            raise PackageError(
                "portable archive path collision: "
                f"{'/'.join(prior[1])!r} and {'/'.join(parts)!r}"
            )
        seen[key] = current


def _zip_info(name: str, mode: int, *, directory: bool) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, ARCHIVE_TIMESTAMP)
    info.create_system = 3
    info.compress_type = zipfile.ZIP_STORED
    info.external_attr = (
        (stat.S_IFDIR | mode) if directory else (stat.S_IFREG | mode)
    ) << 16
    if directory:
        info.external_attr |= 0x10
    return info


def _read_blobs(
    git: GitReader,
    files: Sequence[TrackedFile],
    *,
    object_hash: str,
) -> list[memoryview]:
    request = b"".join(
        tracked.object_id.encode("ascii") + b"\n" for tracked in files
    )
    expected_output_size = sum(
        len(tracked.object_id)
        + len(" blob ")
        + len(str(tracked.size))
        + 1
        + tracked.size
        + 1
        for tracked in files
    )
    raw = git.run(
        ("cat-file", "--batch"),
        max_output=expected_output_size,
        input_bytes=request,
    )
    contents: list[memoryview] = []
    raw_view = memoryview(raw)
    offset = 0
    for tracked in files:
        header_end = raw.find(b"\n", offset)
        if header_end < 0 or header_end - offset > 256:
            raise PackageError(
                f"malformed Git batch header for {tracked.path.as_posix()}"
            )
        try:
            returned_id, returned_type, returned_size = raw[
                offset:header_end
            ].decode("ascii").split()
            parsed_size = int(returned_size)
        except (UnicodeDecodeError, ValueError) as exc:
            raise PackageError(
                f"malformed Git batch header for {tracked.path.as_posix()}"
            ) from exc
        if (
            returned_id.casefold() != tracked.object_id
            or returned_type != "blob"
            or parsed_size != tracked.size
        ):
            raise PackageError(
                f"Git batch identity or size mismatch for {tracked.path.as_posix()}"
            )
        content_start = header_end + 1
        content_end = content_start + tracked.size
        if content_end >= len(raw) or raw[content_end : content_end + 1] != b"\n":
            raise PackageError(
                f"truncated Git batch content for {tracked.path.as_posix()}"
            )
        content = raw_view[content_start:content_end]
        digest = hashlib.new(object_hash)
        digest.update(f"blob {tracked.size}\0".encode("ascii"))
        digest.update(content)
        if digest.hexdigest() != tracked.object_id:
            raise PackageError(
                f"Git blob identity mismatch for {tracked.path.as_posix()}"
            )
        contents.append(content)
        offset = content_end + 1
    if offset != len(raw):
        raise PackageError("Git batch returned trailing data")
    return contents


def _validate_index_matches_head(
    git: GitReader,
    files: Sequence[TrackedFile],
    object_id_length: int,
) -> None:
    expected = {
        tracked.path.as_posix(): (tracked.git_mode, tracked.object_id)
        for tracked in files
    }
    raw_index = git.run(
        ("ls-files", "--stage", "-z"),
        max_output=MAX_GIT_METADATA_BYTES,
    )
    actual: dict[str, tuple[str, str]] = {}
    records = [record for record in raw_index.split(b"\x00") if record]
    if len(records) > MAX_TRACKED_FILES:
        raise PackageError("index entry count exceeded its safety limit")
    for record in records:
        try:
            metadata, raw_path = record.split(b"\t", 1)
            raw_mode, raw_object_id, raw_stage = metadata.split()
            mode = raw_mode.decode("ascii")
            object_id = raw_object_id.decode("ascii").casefold()
            stage = raw_stage.decode("ascii")
            path = raw_path.decode("utf-8")
        except (UnicodeDecodeError, ValueError) as exc:
            raise PackageError("Git index contains malformed metadata or paths") from exc
        if (
            stage != "0"
            or mode not in {"100644", "100755"}
            or re.fullmatch(
                rf"[0-9a-f]{{{object_id_length}}}",
                object_id,
            )
            is None
        ):
            raise PackageError(
                f"unsupported Git index entry: path={path!r}, "
                f"mode={mode!r}, stage={stage!r}"
            )
        if path in actual:
            raise PackageError(f"duplicate Git index path: {path!r}")
        actual[path] = mode, object_id
    if actual != expected:
        differing_paths = sorted(
            path
            for path in set(actual) | set(expected)
            if actual.get(path) != expected.get(path)
        )
        detail = differing_paths[0] if differing_paths else "<unknown>"
        raise PackageError(
            f"Git index does not exactly match captured HEAD at {detail!r}"
        )

    raw_flags = git.run(
        ("ls-files", "-v", "-f", "-z"),
        max_output=MAX_GIT_METADATA_BYTES,
    )
    flagged_paths: set[str] = set()
    for record in (item for item in raw_flags.split(b"\x00") if item):
        try:
            tag, raw_path = record[:1], record[2:]
            if len(record) < 3 or record[1:2] != b" ":
                raise ValueError
            path = raw_path.decode("utf-8")
        except (UnicodeDecodeError, ValueError) as exc:
            raise PackageError("Git index flag listing is malformed") from exc
        if tag != b"H":
            raise PackageError(
                f"Git index path has unsupported state flags: "
                f"path={path!r}, tag={tag.decode('ascii', errors='backslashreplace')!r}"
            )
        if path in flagged_paths:
            raise PackageError(f"duplicate Git index flag path: {path!r}")
        flagged_paths.add(path)
    if flagged_paths != set(expected):
        raise PackageError("Git index flag listing does not match captured HEAD")


def _stat_fingerprint(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _validate_worktree_snapshot(
    pinned_root_fd: int,
    files: Sequence[TrackedFile],
    directories: Sequence[tuple[str, ...]],
    object_hash: str,
) -> None:
    """Verify no-follow worktree bytes, modes, and inventory against HEAD."""

    expected_files = {
        tuple(tracked.path.parts): tracked
        for tracked in files
    }
    expected_directories = set(directories)
    seen_files: set[tuple[str, ...]] = set()
    seen_directories: set[tuple[str, ...]] = set()
    examined = 0
    maximum_entries = MAX_TRACKED_FILES * (MAX_PATH_DEPTH + 1)
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_CLOEXEC", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    file_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    file_flags |= getattr(os, "O_NOFOLLOW", 0)
    file_flags |= getattr(os, "O_NONBLOCK", 0)

    def validate_file(
        directory_fd: int,
        entry_name: str,
        parts: tuple[str, ...],
        listed_metadata: os.stat_result,
        tracked: TrackedFile,
    ) -> None:
        descriptor = os.open(entry_name, file_flags, dir_fd=directory_fd)
        try:
            before = os.fstat(descriptor)
            if (
                _stat_fingerprint(before) != _stat_fingerprint(listed_metadata)
                or not stat.S_ISREG(before.st_mode)
            ):
                raise PackageError(
                    f"tracked worktree file identity changed: {'/'.join(parts)!r}"
                )
            expected_executable = tracked.git_mode == "100755"
            actual_executable = bool(before.st_mode & 0o111)
            if actual_executable != expected_executable:
                raise PackageError(
                    f"tracked worktree executable mode differs from HEAD: "
                    f"{'/'.join(parts)!r}"
                )
            if before.st_size != tracked.size:
                raise PackageError(
                    f"tracked worktree file size differs from HEAD: "
                    f"{'/'.join(parts)!r}"
                )
            digest = hashlib.new(object_hash)
            digest.update(f"blob {tracked.size}\0".encode("ascii"))
            remaining = tracked.size
            while remaining:
                chunk = os.read(descriptor, min(64 * 1024, remaining))
                if not chunk:
                    raise PackageError(
                        f"tracked worktree file was truncated: "
                        f"{'/'.join(parts)!r}"
                    )
                digest.update(chunk)
                remaining -= len(chunk)
            if os.read(descriptor, 1):
                raise PackageError(
                    f"tracked worktree file grew during validation: "
                    f"{'/'.join(parts)!r}"
                )
            after = os.fstat(descriptor)
            if _stat_fingerprint(after) != _stat_fingerprint(before):
                raise PackageError(
                    f"tracked worktree file changed during validation: "
                    f"{'/'.join(parts)!r}"
                )
            if digest.hexdigest() != tracked.object_id:
                raise PackageError(
                    f"tracked worktree bytes differ from HEAD: "
                    f"{'/'.join(parts)!r}"
                )
        finally:
            os.close(descriptor)

    def walk(directory_fd: int, parent_parts: tuple[str, ...]) -> None:
        nonlocal examined
        with os.scandir(directory_fd) as entries:
            for entry in entries:
                if not parent_parts and entry.name == ".git":
                    continue
                examined += 1
                if examined > maximum_entries:
                    raise PackageError("worktree entry count exceeded its safety limit")
                parts = (*parent_parts, entry.name)
                metadata = entry.stat(follow_symlinks=False)
                tracked = expected_files.get(parts)
                if tracked is not None:
                    if not stat.S_ISREG(metadata.st_mode):
                        raise PackageError(
                            "tracked worktree entry is not a regular file: "
                            f"{'/'.join(parts)!r}"
                        )
                    validate_file(
                        directory_fd,
                        entry.name,
                        parts,
                        metadata,
                        tracked,
                    )
                    seen_files.add(parts)
                    continue
                if parts in expected_directories:
                    if not stat.S_ISDIR(metadata.st_mode):
                        raise PackageError(
                            "tracked worktree directory is not a directory: "
                            f"{'/'.join(parts)!r}"
                        )
                    child_fd = os.open(entry.name, directory_flags, dir_fd=directory_fd)
                    try:
                        opened = os.fstat(child_fd)
                        if (
                            opened.st_dev,
                            opened.st_ino,
                        ) != (
                            metadata.st_dev,
                            metadata.st_ino,
                        ):
                            raise PackageError(
                                "worktree directory identity changed during validation"
                            )
                        directory_fingerprint = _stat_fingerprint(opened)
                        seen_directories.add(parts)
                        walk(child_fd, parts)
                        if _stat_fingerprint(os.fstat(child_fd)) != directory_fingerprint:
                            raise PackageError(
                                "worktree directory changed during validation"
                            )
                    finally:
                        os.close(child_fd)
                    continue
                raise PackageError(
                    "worktree contains an untracked or ignored path: "
                    f"{'/'.join(parts)!r}"
                )

    root_fd = os.dup(pinned_root_fd)
    try:
        root_fingerprint = _stat_fingerprint(os.fstat(root_fd))
        walk(root_fd, ())
        if _stat_fingerprint(os.fstat(root_fd)) != root_fingerprint:
            raise PackageError("worktree root changed during validation")
    finally:
        os.close(root_fd)
    missing_files = set(expected_files) - seen_files
    missing_directories = expected_directories - seen_directories
    if missing_files or missing_directories:
        missing_paths = sorted(
            "/".join(parts) for parts in missing_files | missing_directories
        )
        raise PackageError(
            f"tracked worktree path is missing: {missing_paths[0]!r}"
        )


def _validate_repository_snapshot(
    git: GitReader,
    pinned_root_fd: int,
    files: Sequence[TrackedFile],
    directories: Sequence[tuple[str, ...]],
    object_hash: str,
    object_id_length: int,
) -> None:
    _validate_index_matches_head(git, files, object_id_length)
    _validate_worktree_snapshot(
        pinned_root_fd,
        files,
        directories,
        object_hash,
    )


def _entry_metadata(directory_fd: int, name: str) -> Optional[os.stat_result]:
    try:
        return os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def _create_temporary_file(directory_fd: int) -> tuple[str, int]:
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    for _ in range(64):
        name = f".harness-release-{secrets.token_hex(16)}.tmp"
        try:
            descriptor = os.open(name, flags, 0o600, dir_fd=directory_fd)
        except FileExistsError:
            continue
        return name, descriptor
    raise PackageError("could not reserve a unique release ZIP temporary file")


def _validate_pinned_output_directory(
    directory_fd: int,
    lexical_path: Path,
    forbidden_identities: set[tuple[int, int]],
) -> tuple[int, int]:
    pinned_metadata = os.fstat(directory_fd)
    pinned_identity = pinned_metadata.st_dev, pinned_metadata.st_ino
    try:
        lexical_metadata = os.stat(lexical_path, follow_symlinks=False)
    except OSError as exc:
        raise PackageError(
            f"output directory path became unavailable: {lexical_path}"
        ) from exc
    if (
        not stat.S_ISDIR(pinned_metadata.st_mode)
        or not stat.S_ISDIR(lexical_metadata.st_mode)
        or (lexical_metadata.st_dev, lexical_metadata.st_ino) != pinned_identity
    ):
        raise PackageError("output directory path does not match its pinned directory")

    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_CLOEXEC", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    current_fd = os.dup(directory_fd)
    try:
        for _ in range(1_024):
            current_metadata = os.fstat(current_fd)
            current_identity = current_metadata.st_dev, current_metadata.st_ino
            if current_identity in forbidden_identities:
                raise PackageError(
                    "output directory is inside the worktree or Git metadata"
                )
            parent_fd = os.open("..", directory_flags, dir_fd=current_fd)
            parent_metadata = os.fstat(parent_fd)
            parent_identity = parent_metadata.st_dev, parent_metadata.st_ino
            if parent_identity == current_identity:
                os.close(parent_fd)
                break
            os.close(current_fd)
            current_fd = parent_fd
        else:
            raise PackageError("output directory ancestry exceeded its safety limit")
    finally:
        os.close(current_fd)

    if _stat_fingerprint(os.fstat(directory_fd)) != _stat_fingerprint(
        pinned_metadata
    ):
        raise PackageError("output directory changed during ancestry validation")
    try:
        final_lexical = os.stat(lexical_path, follow_symlinks=False)
    except OSError as exc:
        raise PackageError(
            f"output directory path changed: {lexical_path}"
        ) from exc
    if (final_lexical.st_dev, final_lexical.st_ino) != pinned_identity:
        raise PackageError("output directory path identity changed")
    return pinned_identity


def build_release_zip(root: Path, output: Path) -> None:
    """Write a no-clobber deterministic archive from one clean Git HEAD."""

    _require_secure_filesystem_primitives()
    requested_root = Path(os.path.abspath(os.fspath(root.expanduser())))
    root_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    root_flags |= getattr(os, "O_CLOEXEC", 0)
    root_flags |= getattr(os, "O_NOFOLLOW", 0)
    root_fd = os.open(requested_root, root_flags)
    output_directory_fd: Optional[int] = None
    try:
        root_metadata = os.fstat(root_fd)
        if not stat.S_ISDIR(root_metadata.st_mode):
            raise PackageError(f"package root is not a directory: {requested_root}")
        root_identity = root_metadata.st_dev, root_metadata.st_ino
        root = requested_root.resolve(strict=True)
        _require_path_identity(root, root_identity, "package root")
        output = Path(os.path.abspath(os.fspath(output.expanduser())))
        if output.is_symlink():
            raise PackageError(f"output path may not be a symlink: {output}")
        output_parent = output.parent
        if not output_parent.is_dir():
            raise PackageError(
                f"output directory must already exist: {output_parent}"
            )
        output_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        output_flags |= getattr(os, "O_CLOEXEC", 0)
        output_flags |= getattr(os, "O_NOFOLLOW", 0)
        output_directory_fd = os.open(output_parent, output_flags)
        output_parent_identity = _validate_pinned_output_directory(
            output_directory_fd,
            output_parent,
            {root_identity},
        )
        if _entry_metadata(output_directory_fd, output.name) is not None:
            raise PackageError(
                f"output already exists; refusing to overwrite: {output}"
            )
        _build_release_zip_pinned(
            root,
            output,
            root_fd,
            root_identity,
            output_directory_fd,
            output_parent_identity,
        )
    finally:
        if output_directory_fd is not None:
            os.close(output_directory_fd)
        os.close(root_fd)


def _build_release_zip_pinned(
    root: Path,
    output: Path,
    root_fd: int,
    root_identity: tuple[int, int],
    output_directory_fd: int,
    output_parent_identity: tuple[int, int],
) -> None:
    """Build while the user-selected root directory remains pinned."""

    git = GitReader(root)
    top_level = Path(
        git.text(("rev-parse", "--show-toplevel")).strip()
    ).resolve(strict=True)
    _require_path_identity(root, root_identity, "package root")
    if top_level != root:
        raise PackageError("package root must be the Git worktree top level")
    git_directory = _resolve_git_path(git, root, "--absolute-git-dir")
    common_git_directory = _resolve_git_path(git, root, "--git-common-dir")
    _require_path_identity(root, root_identity, "package root")
    git_identity = _identity(git_directory)
    common_git_identity = _identity(common_git_directory)
    forbidden_output_identities = {
        root_identity,
        git_identity,
        common_git_identity,
    }
    if (
        _validate_pinned_output_directory(
            output_directory_fd,
            output.parent,
            forbidden_output_identities,
        )
        != output_parent_identity
    ):
        raise PackageError("output directory identity changed during Git discovery")
    head = git.text(
        ("rev-parse", "--verify", "--end-of-options", "HEAD^{commit}")
    ).strip().casefold()
    _require_path_identity(root, root_identity, "package root")
    if re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", head) is None:
        raise PackageError("HEAD did not resolve to a full Git commit ID")
    object_hash = "sha256" if len(head) == 64 else "sha1"
    raw_tree = git.run(
        ("ls-tree", "-r", "-z", "-l", "--full-tree", head),
        max_output=MAX_GIT_METADATA_BYTES,
    )
    _require_path_identity(root, root_identity, "package root")
    files = _parse_tracked_files(raw_tree, len(head))
    if not files:
        raise PackageError("Git HEAD contains no tracked files")
    tracked_paths = {tracked.path.as_posix() for tracked in files}
    missing_required_paths = REQUIRED_TRACKED_PATHS - tracked_paths
    if missing_required_paths:
        missing = ", ".join(sorted(missing_required_paths))
        raise PackageError(
            f"Git HEAD must contain regular tracked skill markers: {missing}"
        )
    directories = _directory_parts(files)
    _validate_portable_collisions(files, directories)
    files = sorted(files, key=lambda item: item.path.as_posix().encode("utf-8"))
    _validate_repository_snapshot(
        git,
        root_fd,
        files,
        directories,
        object_hash,
        len(head),
    )
    contents = _read_blobs(git, files, object_hash=object_hash)
    _require_path_identity(root, root_identity, "package root")

    output_parent = output.parent
    directory_fd = output_directory_fd
    temporary_name: Optional[str] = None
    temporary_fd: Optional[int] = None
    temporary_identity: Optional[tuple[int, int]] = None
    output_created = False
    published = False
    try:
        if (
            _validate_pinned_output_directory(
                directory_fd,
                output_parent,
                forbidden_output_identities,
            )
            != output_parent_identity
        ):
            raise PackageError("output directory identity changed before build")
        if _entry_metadata(directory_fd, output.name) is not None:
            raise PackageError(
                f"output already exists; refusing to overwrite: {output}"
            )
        temporary_name, temporary_fd = _create_temporary_file(directory_fd)
        temporary_metadata = os.fstat(temporary_fd)
        temporary_identity = (
            temporary_metadata.st_dev,
            temporary_metadata.st_ino,
        )
        with os.fdopen(temporary_fd, "w+b", closefd=False) as temporary:
            with zipfile.ZipFile(
                temporary,
                "w",
                compression=zipfile.ZIP_STORED,
            ) as archive:
                archive.writestr(
                    _zip_info(
                        f"{ARCHIVE_PREFIX}/",
                        0o755,
                        directory=True,
                    ),
                    b"",
                )
                for parts in directories:
                    name = str(PurePosixPath(ARCHIVE_PREFIX, *parts)) + "/"
                    archive.writestr(_zip_info(name, 0o755, directory=True), b"")
                for tracked, content in zip(files, contents):
                    name = str(PurePosixPath(ARCHIVE_PREFIX, *tracked.path.parts))
                    archive.writestr(
                        _zip_info(name, tracked.archive_mode, directory=False),
                        content,
                    )
            temporary.flush()
            os.fsync(temporary.fileno())

        final_head = git.text(
            ("rev-parse", "--verify", "--end-of-options", "HEAD^{commit}")
        ).strip().casefold()
        if final_head != head:
            raise PackageError("Git HEAD changed while the archive was built")
        _validate_repository_snapshot(
            git,
            root_fd,
            files,
            directories,
            object_hash,
            len(head),
        )
        if (
            _identity(root) != root_identity
            or _identity(git_directory) != git_identity
            or _identity(common_git_directory) != common_git_identity
        ):
            raise PackageError("repository identity changed while the archive was built")
        if (
            _validate_pinned_output_directory(
                directory_fd,
                output_parent,
                forbidden_output_identities,
            )
            != output_parent_identity
        ):
            raise PackageError("output directory identity changed while building")
        current_temporary = _entry_metadata(directory_fd, temporary_name)
        if (
            current_temporary is None
            or not stat.S_ISREG(current_temporary.st_mode)
            or (current_temporary.st_dev, current_temporary.st_ino)
            != temporary_identity
            or current_temporary.st_nlink != 1
        ):
            raise PackageError("release ZIP temporary-file identity changed")
        if _entry_metadata(directory_fd, output.name) is not None:
            raise PackageError(
                f"output appeared during build; refusing to overwrite: {output}"
            )
        os.fchmod(temporary_fd, 0o644)
        try:
            os.link(
                temporary_name,
                output.name,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
                follow_symlinks=False,
            )
        except FileExistsError as exc:
            raise PackageError(
                f"output appeared during build; refusing to overwrite: {output}"
            ) from exc
        output_created = True
        created_metadata = _entry_metadata(directory_fd, output.name)
        if (
            created_metadata is None
            or (created_metadata.st_dev, created_metadata.st_ino)
            != temporary_identity
            or _validate_pinned_output_directory(
                directory_fd,
                output_parent,
                forbidden_output_identities,
            )
            != output_parent_identity
        ):
            raise PackageError("published ZIP or output directory identity changed")
        published_head = git.text(
            ("rev-parse", "--verify", "--end-of-options", "HEAD^{commit}")
        ).strip().casefold()
        if published_head != head:
            raise PackageError("Git HEAD changed during archive publication")
        _validate_repository_snapshot(
            git,
            root_fd,
            files,
            directories,
            object_hash,
            len(head),
        )
        if (
            _identity(root) != root_identity
            or _identity(git_directory) != git_identity
            or _identity(common_git_directory) != common_git_identity
            or _validate_pinned_output_directory(
                directory_fd,
                output_parent,
                forbidden_output_identities,
            )
            != output_parent_identity
        ):
            raise PackageError(
                "repository or output identity changed during archive publication"
            )
        os.fsync(directory_fd)
        os.unlink(temporary_name, dir_fd=directory_fd)
        temporary_name = None
        os.fsync(directory_fd)
        published = True
    finally:
        if output_created and not published and temporary_identity is not None:
            try:
                current_output = _entry_metadata(directory_fd, output.name)
                if (
                    current_output is not None
                    and (current_output.st_dev, current_output.st_ino)
                    == temporary_identity
                ):
                    os.unlink(output.name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
        if temporary_fd is not None:
            os.close(temporary_fd)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Build a deterministic, no-clobber release ZIP from a clean Git HEAD."
        )
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="skill Git repository root (defaults to the parent of scripts/)",
    )
    parser.add_argument("--output", type=Path, required=True, help="new output ZIP path")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        build_release_zip(args.root, args.output)
    except PackageError as exc:
        print(f"error: {exc}", file=os.sys.stderr)
        return 2
    except (OSError, NotImplementedError, zipfile.BadZipFile) as exc:
        print(f"error: {_safe_diagnostic(str(exc))}", file=os.sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
