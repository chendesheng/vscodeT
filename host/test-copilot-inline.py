"""POSIX installed-TUI smoke test. Run zig build and zig build host first."""
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

HOST = Path(__file__).resolve().parent
EDITOR = HOST.parent / "zig-out/bin/zig"


def run(root):
    profile = root / "profile"
    (profile / "User").mkdir(parents=True)
    (profile / "User/settings.json").write_text(
        '{"editor.quickSuggestions":false,"editor.wordBasedSuggestions":"off"}'
    )
    source = root / "example.py"
    source.touch()
    events = root / "events"
    events.touch()
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    env = {
        "HOME": str(root), "XDG_CONFIG_HOME": str(root / "config"),
        "PATH": os.environ["PATH"], "TERM": "xterm-256color",
        "VSCODE_TEXTBUFFER_COPILOT_SERVER": str(HOST / "test-fixtures/copilot-server.cjs"),
        "COPILOT_TEST_EVENTS": str(events),
    }
    process = subprocess.Popen([EDITOR, "--user-data-dir", profile, source],
                               cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)

    def wait_for(predicate):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if predicate():
                return
            if process.poll() is not None:
                break
            if select.select([master], [], [], 0.1)[0]:
                os.read(master, 65536)
        raise AssertionError(f"Editor exit={process.poll()}, server events={events.read_text()!r}")

    try:
        wait_for(lambda: "initialize" in events.read_text())
        # Registration and document mirroring finish asynchronously at startup.
        # A second edit after a presented suggestion also exercises didChange.
        os.write(master, b"val")
        wait_for(lambda: "shown val = 42" in events.read_text())
        os.write(master, b"ue")
        wait_for(lambda: "shown value = 42" in events.read_text())
        assert "changed value" in events.read_text() and "focused" in events.read_text()
        os.write(master, b"\t")
        wait_for(lambda: "github.copilot.didAcceptCompletionItem fixture" in events.read_text())
        os.write(master, b"\x13")
        wait_for(lambda: source.read_text() == "value = 42")
        os.write(master, b"\x1a\x13")
        wait_for(lambda: source.read_text() == "value")
        os.write(master, b"\x11")
        process.wait(timeout=5)
        assert process.returncode == 0
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        os.close(master)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as temp:
        run(Path(temp))
    print("Copilot inline completion, acceptance notification and undo passed")
