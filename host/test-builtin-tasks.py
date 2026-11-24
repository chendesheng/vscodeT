"""Installed TUI smoke test. Pass a directory containing grunt, gulp and jake node_modules to include those providers."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

EDITOR = Path(__file__).resolve().parent.parent / 'zig-out/bin/zig'


def check(root, kind):
    profile = root / 'profile'
    (profile / 'User').mkdir(parents=True)
    (profile / 'User/settings.json').write_text(json.dumps({
        f'{kind}.autoDetect': 'on', 'npm.packageManager': 'npm', 'npm.scriptRunner': 'npm',
    }))
    output = root / 'task-output'
    (root / 'example.txt').touch()
    js = "require('node:fs').writeFileSync('task-output','done')"
    (root / 'package.json').write_text(json.dumps({'scripts': {'verify-workbench': f'node -e "{js}"'}}))
    if kind != 'npm':
        (root / 'node_modules').symlink_to(Path(sys.argv[1]).resolve() / 'node_modules', target_is_directory=True)
        (root / 'Gruntfile.js').write_text("module.exports = g => g.registerTask('verify-workbench','Verify the workbench', () => {" + js + "})")
        (root / 'gulpfile.js').write_text("exports['verify-workbench'] = done => {" + js + "; done()}")
        (root / 'Jakefile').write_text("desc('Verify the workbench'); task('verify-workbench', () => {" + js + "})")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 140, 0, 0))
    env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(profile), TERM='xterm-256color')
    process = subprocess.Popen([EDITOR, '--user-data-dir', profile, root / 'example.txt'],
                               cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)

    def wait(text=None):
        data = plain = b''
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and process.poll() is None:
            if text is None and output.exists() and output.read_text() == 'done':
                return
            if select.select([master], [], [], 0.1)[0]:
                data += os.read(master, 65536)
                plain = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', data)
                if text and text in plain:
                    return
        raise AssertionError(f'{kind}: missing {text!r}, last output {plain[-1200:]!r}')

    try:
        wait(b'example.txt')
        # Wait for the installed host and its lazily activated task extensions.
        time.sleep(1)
        os.write(master, b'\x10')
        time.sleep(0.15)
        os.write(master, b'>Tasks: Run Task')
        wait(b'Run Task')
        os.write(master, b'\r')
        wait(b'Select a task type')
        os.write(master, kind.encode() + b'\r')
        wait(b'verify-workbench')
        os.write(master, b'verify-workbench\r')
        wait()
    finally:
        process.terminate()
        process.wait(timeout=5)
        os.close(master)


if __name__ == '__main__':
    for provider in (['npm', 'grunt', 'gulp', 'jake'] if len(sys.argv) > 1 else ['npm']):
        with tempfile.TemporaryDirectory() as temp:
            check(Path(temp), provider)
        print(f'{provider}: discovered and executed verify-workbench', flush=True)
