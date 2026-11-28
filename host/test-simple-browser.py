"""Open and navigate a local site in the installed editor with Lynx on PATH."""
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import threading
import time

EDITOR = Path(__file__).resolve().parent.parent / "zig-out/bin/minecode"


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        page = b'<h1>BrowserFirstPage</h1><a href="/next">Visit next page</a>' if self.path == '/' else b'<h1>BrowserSecondPage</h1>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, *args):
        pass


def run(root, url):
    source = root / 'example.txt'
    source.touch()
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 45, 140, 0, 0))
    env = dict(os.environ, HOME=str(root), XDG_CONFIG_HOME=str(root), TERM='xterm-256color',
               NO_PROXY='127.0.0.1', no_proxy='127.0.0.1')
    process = subprocess.Popen([EDITOR, '--user-data-dir', root / 'profile', source],
                               cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)

    def expect(text):
        data = plain = b''
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and process.poll() is None:
            if select.select([master], [], [], 0.15)[0]:
                data += os.read(master, 65536)
                plain = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', data)
                if text in plain:
                    return
        raise AssertionError(f'Missing {text!r}. Last terminal output: {plain[-1600:]!r}')

    try:
        expect(b'example.txt')
        os.write(master, b'\x10')  # Ctrl+P
        time.sleep(0.2)
        os.write(master, b'>Simple Browser')
        expect(b'Simple Browser')
        os.write(master, b'\r')
        expect(b'Enter an HTTP')
        os.write(master, url.encode() + b'\r')
        expect(b'BrowserFirstPage')
        os.write(master, b'\r')
        expect(b'BrowserSecondPage')
        os.write(master, b'\x1b[D')
        expect(b'BrowserFirstPage')
    finally:
        process.terminate()
        process.wait(timeout=5)
        os.close(master)


if __name__ == '__main__':
    with tempfile.TemporaryDirectory() as temp, ThreadingHTTPServer(('127.0.0.1', 0), Site) as site:
        threading.Thread(target=site.serve_forever, daemon=True).start()
        try:
            run(Path(temp), f'http://127.0.0.1:{site.server_port}/')
        finally:
            site.shutdown()
    print('Simple Browser opened a page, followed a link and navigated back')
