"""Portable cassette filenames, separate from case-sensitive case IDs."""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path
from typing import Iterable


class CassetteFileError(ValueError):
    pass


def validate_names(names: Iterable[str]) -> None:
    """Reject aliases even when the filesystem exposes only one spelling."""
    folded: dict[str, str] = {}
    names = sorted(set(names))
    for name in names:
        previous = folded.setdefault(name.casefold(), name)
        if previous != name:
            raise CassetteFileError(f"case-insensitive filename collision: {previous!r} and {name!r}")
    for name in names:
        if not re.fullmatch(r"[a-z0-9][a-z0-9_]*\.json", name):
            raise CassetteFileError(f"non-portable cassette filename: {name!r}; use lowercase ASCII names (e.g. append_upper_a.json)")


def tracked_names(directory: Path, root: Path) -> list[str]:
    # Directory enumeration alone silently loses aliases on Windows/macOS.
    # Git still knows both paths on those filesystems.
    try:
        relative = directory.resolve().relative_to(root.resolve())
    except ValueError:
        return []  # A custom directory outside this checkout.
    paths = subprocess.check_output(
        ["git", "ls-files", "-z", "--", relative.as_posix()], cwd=root
    ).decode("utf-8").split("\0")
    return [Path(p).name for p in paths if p.lower().endswith(".json")]


def load_cases(directory: Path, only: str | None = None, *, tracked_names: Iterable[str] = ()) -> list[Path]:
    """Validate the whole directory before selecting a case or recording it."""
    files = sorted(p for p in directory.iterdir() if p.is_file() and p.suffix.lower() == ".json")
    validate_names([p.name for p in files] + list(tracked_names))
    ids: dict[str, Path] = {}
    for path in files:
        case = json.loads(path.read_text(encoding="utf-8"))["case"]
        if not isinstance(case, str) or not case:
            raise CassetteFileError(f"{path}: invalid cassette case ID")
        if case in ids:
            raise CassetteFileError(f"duplicate cassette case ID {case!r}: {ids[case].name} and {path.name}")
        ids[case] = path
    if only is None:
        return files
    # The historical --case value is the JSON case ID, which retains the
    # original capitalization even when its filename has changed.
    if only in ids:
        return [ids[only]]
    matches = [p for p in files if p.stem == only]
    if not matches:
        raise CassetteFileError(f"no cassette named {only!r} in {directory}")
    return matches
