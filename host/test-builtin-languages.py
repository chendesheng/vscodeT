"""Exercise the installed grammars, editing and color themes in a POSIX PTY."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import time

INSTALL = Path(__file__).resolve().parents[1] / "zig-out"
CATALOG = INSTALL / "share/vscode-textbuffer/extensions"
# One independently recognizable token and filename per language-basics package.
# Empty initial lines keep the syntax probe off the highlighted cursor row.
SAMPLES = (
    ("example.bat", "Batch", "REM Marker"),
    ("example.clj", "Clojure", "; Marker"),
    ("example.coffee", "CoffeeScript", "# Marker"),
    ("example.c", "C", "// Marker"),
    ("example.cs", "C#", "// Marker"),
    ("example.css", "CSS", "/* Marker */"),
    ("example.dart", "Dart", "// Marker"),
    ("example.diff", "Diff", "+Marker"),
    ("Dockerfile", "Docker", "# Marker"),
    (".env", "Dotenv", "# Marker"),
    ("example.fs", "F#", "// Marker"),
    ("example.go", "Go", "// Marker"),
    ("Jenkinsfile", "Groovy", "// Marker"),
    ("example.handlebars", "Handlebars", "{{! Marker }}"),
    ("example.hlsl", "HLSL", "// Marker"),
    ("example.html", "HTML", "<!-- Marker -->"),
    ("example.ini", "Ini", "; Marker"),
    ("example.java", "Java", "// Marker"),
    ("example.jsx", "JavaScript JSX", "// Marker"),
    ("example.json", "JSON", '{"name": "Marker"}'),
    ("example.jl", "Julia", "# Marker"),
    ("example.sty", "TeX", "% Marker"),
    ("example.less", "Less", "/* Marker */"),
    ("example.log", "Log", "TRACE"),
    ("example.lua", "Lua", "-- Marker"),
    ("Makefile", "Makefile", "# Marker"),
    ("example.md", "Markdown", "# Marker"),
    ("example.m", "Objective-C", "// Marker"),
    ("example.pl", "Perl", "# Marker"),
    ("example.php", "PHP", "<?php // Marker"),
    ("example.ps1", "PowerShell", "# Marker"),
    ("example.prompt.md", "Prompt", "# Marker"),
    ("example.pug", "Pug", "//- Marker"),
    ("example.py", "Python", "# Marker"),
    ("example.r", "R", "# Marker"),
    ("example.cshtml", "Razor", "@* Marker *@"),
    ("example.rst", "reStructuredText", ".. Marker"),
    ("example.rb", "Ruby", "# Marker"),
    ("example.rs", "Rust", "// Marker"),
    ("example.scss", "SCSS", "/* Marker */"),
    ("example.shader", "ShaderLab", "// Marker"),
    ("example.sh", "Shell Script", "# Marker"),
    ("example.sql", "MS SQL", "-- Marker"),
    ("example.swift", "Swift", "// Marker"),
    ("example.ts", "TypeScript", "// Marker"),
    ("example.vb", "Visual Basic", "' Marker"),
    ("example.xml", "XML", "<!-- Marker -->"),
    ("example.yaml", "YAML", "# Marker"),
)
CSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
# The renderer emits one foreground and background pair per styled run.
RUN = re.compile(rb"\x1b\[38;2;(\d+;\d+;\d+)m\x1b\[48;2;(\d+;\d+;\d+)m(?:\x1b\[\d+m)*([^\x1b]*)")


def check(filename, language, code, theme="Dark+", background=b"30;30;30"):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        source = root / filename
        original = "\n" + code + "\n"
        source.write_text(original)
        settings = root / "profile/User/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"workbench.colorTheme": theme}))
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 140, 0, 0))
        env = {"HOME": directory, "XDG_CONFIG_HOME": directory, "PATH": os.environ["PATH"],
               "TERM": "xterm-256color", "COLORTERM": "truecolor"}
        process = subprocess.Popen([INSTALL / "bin/zig", "--user-data-dir", settings.parent.parent, source],
                                   cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            output = bytearray()
            token = b"TRACE" if filename.endswith(".log") else b"Marker"
            edited = False
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.05)[0]:
                    output.extend(os.read(master, 65536))
                if process.poll() is not None:
                    raise AssertionError(f"{filename} / {theme}: editor exited {process.returncode}")
                if edited:
                    if source.read_text() == "x" + original:
                        return
                elif (b"LF  " + language.encode() + b" ") in CSI.sub(b"", output):
                    for fg, bg, run in RUN.findall(output):
                        if token in run and bg == background and (theme != "Dark+" or fg != b"212;212;212"):
                            os.write(master, b"x")
                            time.sleep(0.1)
                            os.write(master, b"\x13")
                            edited = True
                            break
            colors = [(fg, bg) for fg, bg, run in RUN.findall(output) if token in run]
            statuses = re.findall(rb"LF  ([^\r\n]{1,32})", CSI.sub(b"", output))
            raise AssertionError(f"{filename} / {theme}: colors={colors}, status={statuses[-1:]}, edit_sent={edited}, file={source.read_text()!r}")
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
            os.close(master)


def editor_background(path, ui_theme):
    # Upstream themes are JSON with comments and can inherit a base palette.
    source = path.read_text()
    match = re.search(r'^\s*"editor\.background"\s*:\s*"#([0-9a-f]{6})"', source, re.I | re.M)
    if match:
        return b";".join(str(value).encode() for value in bytes.fromhex(match[1]))
    base = re.search(r'"include"\s*:\s*"([^"]+)"', source)
    if base:
        return editor_background(path.parent / base[1], ui_theme)
    return {"vs": b"255;255;255", "vs-dark": b"30;30;30", "hc-light": b"255;255;255",
            "hc-black": b"0;0;0"}[ui_theme]


if __name__ == "__main__":
    for filename, language, code in SAMPLES:
        check(filename, language, code)
        print(language, flush=True)
    for manifest in sorted(CATALOG.glob("theme-*/package.json")):
        for theme in json.loads(manifest.read_text())["contributes"].get("themes", []):
            check("sample.py", "Python", "# Marker", theme["id"], editor_background(manifest.parent / theme["path"], theme["uiTheme"]))
            print(theme["id"], flush=True)
