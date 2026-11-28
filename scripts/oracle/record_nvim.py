#!/usr/bin/env python3
"""Record Vim reference cassettes from a real Neovim.

Development-only. The committed cassettes are replayed by `zig build
test-oracle`; CI and normal builds never need Neovim installed.

Run through the virtualenv created by `scripts/oracle/setup.sh`:

    scripts/oracle/.venv/bin/python scripts/oracle/record_nvim.py --all
    scripts/oracle/.venv/bin/python scripts/oracle/record_nvim.py --check --all
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys

from cassette_files import CassetteFileError, load_cases, tracked_names

try:
    import pynvim
except ImportError:  # pragma: no cover - developer guidance
    sys.exit(
        "pynvim is missing. Run scripts/oracle/setup.sh, then use "
        "scripts/oracle/.venv/bin/python to run this script."
    )

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_DIR = ROOT / "src/vs/editor/contrib/vim/test/data/oracle"

NAMED = {
    "Esc": "<Esc>",
    "Escape": "<Esc>",
    "CR": "<CR>",
    "Enter": "<CR>",
    "Tab": "<Tab>",
    "BS": "<BS>",
    "Backspace": "<BS>",
    "Del": "<Del>",
    "Delete": "<Del>",
    "Space": "<Space>",
    "Up": "<Up>",
    "Down": "<Down>",
    "Left": "<Left>",
    "Right": "<Right>",
    "Home": "<Home>",
    "End": "<End>",
    "PageUp": "<PageUp>",
    "PageDown": "<PageDown>",
}


def nvim_key_sequence(tokens: list[str]) -> str:
    """Translate cassette key tokens into the literal bytes feedkeys executes.

    `feedkeys()` with the `x` flag is synchronous, unlike `nvim_input()`, whose
    typeahead is not consumed before the next RPC request. Special keys are
    represented by their terminal bytes (ESC, CR, TAB, control bytes); the
    `<...>` notation is not interpreted by feedkeys.
    """
    parts: list[str] = []
    for token in tokens:
        if len(token) == 1:
            parts.append(token)
            continue
        if not (token.startswith("<") and token.endswith(">")):
            raise SystemExit(f"invalid key token {token!r}: expected one character or <Name>")
        inner = token[1:-1]
        if inner in ("Esc", "Escape"):
            parts.append("\x1b")
        elif inner in ("CR", "Enter"):
            parts.append("\r")
        elif inner == "Tab":
            parts.append("\t")
        elif inner in ("BS", "Backspace"):
            parts.append("\x08")
        elif inner == "Space":
            parts.append(" ")
        elif inner == "lt":
            parts.append("<")
        elif len(inner) == 3 and inner[0] == "C" and inner[1] == "-":
            parts.append(chr(ord(inner[2].lower()) & 0x1F))
        elif len(inner) == 3 and inner[0] == "A" and inner[1] == "-":
            parts.append("\x1b" + inner[2])
        else:
            raise SystemExit(
                f"key token {token!r} is not supported by the synchronous recorder; "
                "use a literal byte-mapped key or extend nvim_key_sequence"
            )
    return "".join(parts)


def record_state(nvim) -> dict:
    mode = nvim.eval("mode()")
    if mode not in ("n", "i", "R"):
        raise RuntimeError(f"unsupported final mode {mode!r}; v1 records n/i/R only")
    lines = nvim.current.buffer[:]
    text = "\n".join(lines)
    _, line, column, _ = nvim.eval("getcurpos()")[:4]
    view = nvim.funcs.winsaveview()
    return {
        "text": text,
        "cursor": [int(line), int(column)],
        "mode": {"n": "normal", "i": "insert", "R": "replace"}[mode],
        "scroll": {
            "top_line": int(view["topline"]),
            "left": int(view["leftcol"]),
        },
    }


def seed(nvim, case: dict) -> None:
    text = case["seed"]["text"]
    cursor = case["seed"]["cursor"]
    nvim.command("enew!")
    nvim.current.buffer[:] = text.split("\n")
    # Match the replay editor's viewport: `height` is the number of text rows
    # (Neovim's window height excludes the statusline), and `width` is the
    # text column count. The replay editor reserves one row for its own status
    # line and adds it to the cassette height.
    window = nvim.current.window
    window.height = int(case.get("height", 12))
    window.width = int(case.get("width", 60))
    nvim.funcs.cursor(cursor[0], cursor[1])
    actual = "\n".join(nvim.current.buffer[:])
    if actual != text:
        raise SystemExit(
            f"seed text round-trip failed for {case['case']!r}:\n"
            f"  expected {text!r}\n  actual   {actual!r}"
        )
    _, line, column, _ = nvim.eval("getcurpos()")[:4]
    if [int(line), int(column)] != [cursor[0], cursor[1]]:
        raise SystemExit(
            f"seed cursor round-trip failed for {case['case']!r}: "
            f"expected {cursor}, got {[int(line), int(column)]}"
        )


def record_case(nvim, case: dict) -> dict:
    seed(nvim, case)
    if nvim.eval("mode()") != "n":
        raise SystemExit(f"{case['case']}: seed did not leave Neovim in normal mode")
    keys = nvim_key_sequence(case["keys"])
    nvim.funcs.feedkeys(keys, "x")
    # Scroll state is only updated by the redraw loop; force it so the cassette
    # records the viewport a UI would show.
    nvim.command("redraw")
    return record_state(nvim)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", type=pathlib.Path, default=DEFAULT_DIR)
    parser.add_argument("--case", help="record one cassette by name")
    parser.add_argument("--all", action="store_true", help="record every cassette (default)")
    parser.add_argument("--out", type=pathlib.Path, help="write recordings under this directory")
    parser.add_argument("--check", action="store_true", help="re-record and compare to committed states")
    parser.add_argument("--force", action="store_true", help="overwrite existing states")
    parser.add_argument("--accept-reference-version", action="store_true")
    parser.add_argument("--nvim", default=os.environ.get("NVIM", "nvim"))
    args = parser.parse_args()

    try:
        files = load_cases(args.dir, args.case, tracked_names=tracked_names(args.dir, ROOT))
    except CassetteFileError as error:
        raise SystemExit(str(error)) from error

    if shutil.which(args.nvim) is None:
        raise SystemExit(f"{args.nvim}: Neovim not found; install the pinned version or pass --nvim")

    version = subprocess.check_output([args.nvim, "--version"], text=True).splitlines()[0]
    nvim = pynvim.attach("child", argv=[args.nvim, "--embed", "--clean", "-n"])
    changed = 0
    checked = 0
    try:
        for path in files:
            case = json.loads(path.read_text())
            if case.get("engine") != "vim" or case.get("reference") != "neovim":
                raise SystemExit(f"{path}: not a Vim/Neovim cassette")
            recorded_version = case.get("reference_version", "")
            if recorded_version and recorded_version != version and not args.accept_reference_version:
                raise SystemExit(
                    f"{path}: recorded with {recorded_version!r} but running {version!r}; "
                    "pass --accept-reference-version to refresh"
                )
            if case.get("states") and not (args.check or args.force):
                continue
            state = record_case(nvim, case)
            case["reference_version"] = version
            case["height"] = int(case.get("height", 12))
            new_states = [state]
            if args.check:
                checked += 1
                if case.get("states") != new_states:
                    print(f"drift: {path} ({case['case']})", file=sys.stderr)
                    print(f"  committed: {json.dumps(case.get('states'))}", file=sys.stderr)
                    print(f"  recorded:  {json.dumps(new_states)}", file=sys.stderr)
                    return 1
                continue
            case["states"] = new_states
            out_dir = args.out if args.out is not None else path.parent
            out_dir.mkdir(parents=True, exist_ok=True)
            (out_dir / path.name).write_text(json.dumps(case, indent=2) + "\n")
            changed += 1
            print(f"recorded {case['case']} ({len(case['keys'])} keys)")
    finally:
        try:
            nvim.command("qa!")
        except Exception:
            pass

    if args.check:
        print(f"checked {checked} cassettes against {version}")
    else:
        print(f"recorded {changed} cassettes with {version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
