"""Complete a Git flag through the installed provider in a real Bash terminal."""
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

EDITOR = Path(__file__).resolve().parent.parent / "zig-out/bin/zig"


def run(root):
    source = root / "example.txt"
    source.touch()
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 44, 150, 0, 0))
    env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(root), SHELL="/bin/bash",
               TERM="xterm-256color", BASH_SILENCE_DEPRECATION_WARNING="1")
    process = subprocess.Popen([EDITOR, "--user-data-dir", root / "profile", source],
                               cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)

    def expect(needle):
        data = b""
        deadline = time.monotonic() + 20
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                data += os.read(master, 65536)
                if needle in re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", data):
                    return
        raise AssertionError(f"Missing {needle!r}")

    try:
        expect(b"example.txt")
        os.write(master, b"\x10")
        time.sleep(0.2)
        os.write(master, b">Terminal: Create New Terminal")
        expect(b"Create New Terminal")
        os.write(master, b"\r")
        expect(b"$ ")
        # OSC 7 reports cwd; OSC 133 A/B delimit the prompt and its command input.
        prompt = rb"\[\e]7;file://localhost$PWD\a\]\[\e]133;A\a\]Demo$ \[\e]133;B\a\]"
        os.write(master, b"PS1='" + prompt + b"'\r")
        time.sleep(0.25)
        os.write(master, b"git --ver")
        expect(b"--ver")
        os.write(master, b"\x00")  # Ctrl+Space
        expect(b"--version")
        os.write(master, b"\r")
        time.sleep(0.25)
        os.write(master, b"\r")
        expect(b"git version")
    finally:
        process.terminate()
        process.wait(timeout=5)
        os.close(master)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as temp:
        run(Path(temp))
    print("Accepted --version from the terminal provider and ran git version")
