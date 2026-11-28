"""Check GitHub publishing and private port forwarding with offline CLI fixtures."""
import fcntl
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

EDITOR = Path(__file__).resolve().parent.parent / "zig-out/bin/minecode"


def run(root, tool):
    workspace = root / "workspace"
    workspace.mkdir()
    source = workspace / "sample.txt"
    source.touch()
    bin_dir = root / "bin"
    bin_dir.mkdir()
    program = bin_dir / tool
    program.write_text(
        "#!/bin/sh\npwd > \"$FIXTURE_DIR/cwd\"\nprintf '%s\\n' \"$@\" > \"$FIXTURE_DIR/args\"\n"
        "trap 'echo stopped > \"$FIXTURE_DIR/stopped\"; exit 0' INT\n"
        "echo cli-fixture-ready\nwhile :; do sleep 1; done\n"
    )
    program.chmod(0o700)
    env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(root), FIXTURE_DIR=str(root),
               PATH=str(bin_dir) + os.pathsep + os.environ["PATH"], TERM="xterm-256color")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    process = subprocess.Popen([EDITOR, "--user-data-dir", root / "profile", workspace, source],
                               cwd=workspace, env=env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)

    def expect(text):
        data = b""
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and process.poll() is None:
            if select.select([master], [], [], 0.1)[0]:
                data += os.read(master, 65536)
                if text in re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", data):
                    return
        raise AssertionError(f"Missing {text!r}")

    try:
        expect(b"sample.txt")
        os.write(master, b"\x10")
        time.sleep(0.15)
        command = b"Publish to GitHub" if tool == "gh" else b"Forward a Port"
        os.write(master, b">" + command)
        expect(command)
        os.write(master, b"\r")
        if tool == "devtunnel":
            expect(b"Local port to forward privately")
            os.write(master, b"43127\r")
        expect(b"cli-fixture-ready")
        args = (root / "args").read_text().splitlines()
        assert args == (["repo", "create"] if tool == "gh" else ["host", "-p", "43127"]), args
        assert Path((root / "cwd").read_text().strip()).resolve() == workspace.resolve()
        os.write(master, b"\x03")
        deadline = time.monotonic() + 5
        while not (root / "stopped").exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        assert (root / "stopped").exists()
    finally:
        process.terminate()
        process.wait(timeout=5)
        os.close(master)


if __name__ == "__main__":
    for tool in ("gh", "devtunnel"):
        with tempfile.TemporaryDirectory() as temp:
            run(Path(temp), tool)
        print(f"{tool} command, workspace and stop verified")
