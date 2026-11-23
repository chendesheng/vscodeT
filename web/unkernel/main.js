// vscodeT on unkernel: a real wasm Linux kernel runs the native aarch64 TUI,
// and Ghostty (ghostty-web) is the terminal frontend.
import { Ghostty, Terminal, FitAddon } from "./vendor/ghostty-web/ghostty-web.js";
import { createKernel, checkSupport } from "./vendor/unkernel/web.mjs";

const statusElement = document.getElementById("status");
const terminalElement = document.getElementById("terminal");
const decoder = new TextDecoder();
const FONT_FAMILY = '"IosevkaTerm Nerd Font", "JetBrains Mono", "Cascadia Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace';

const THEME = {
  background: "#1e1e1e",
  foreground: "#d4d4d4",
  cursor: "#aeafad",
  cursorAccent: "#1e1e1e",
  selectionBackground: "#264f78",
  selectionForeground: "#ffffff",
  black: "#000000",
  red: "#cd3131",
  green: "#0dbc79",
  yellow: "#e5e510",
  blue: "#2472c8",
  magenta: "#bc3fbc",
  cyan: "#11a8cd",
  white: "#e5e5e5",
  brightBlack: "#666666",
  brightRed: "#f14c4c",
  brightGreen: "#23d18b",
  brightYellow: "#f5f543",
  brightBlue: "#3b8eea",
  brightMagenta: "#d670d6",
  brightCyan: "#29b8db",
  brightWhite: "#e5e5e5",
};

const WORKSPACE = {
  "demo.ts": `// vscodeT in unkernel — a real Linux kernel in WebAssembly.
import { greet } from "./src/main";

const answer = 42;
console.log(greet("vscodeT"), answer);
`,
  "src/main.ts": `export function greet(name: string): string {
  const message = \`Hello, \${name}!\`;
  // The sidebar, tabs, Ctrl+P and the integrated terminal are native features.
  return message;
}
`,
  "README.md": `# vscodeT on unkernel

This is a real aarch64 Debian/Alpine userland booted by unkernel, a Linux
kernel compiled to WebAssembly. The editor is the native vscodeT TUI, not a
wasm reimplementation.

Press Ctrl+P for quick open, or Alt+Shift+T for the integrated terminal.
`,
  "package.json": `{
  "name": "vscodet-unkernel-demo",
  "private": true,
  "version": "0.0.0"
}
`,
};

function showStatus(message, isError = false) {
  statusElement.textContent = message;
  statusElement.classList.toggle("error", isError);
  statusElement.classList.toggle("hidden", message.length === 0);
  if (isError) console.error(message);
}

async function fetchBytes(url) {
  const response = await fetch(url, { cache: "no-cache" });
  if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status}`);
  return new Uint8Array(await response.arrayBuffer());
}

async function loadGhostty() {
  const bytes = await fetchBytes("./vendor/ghostty-web/ghostty-vt.wasm");
  let memory = null;
  const { instance } = await WebAssembly.instantiate(bytes, {
    env: {
      log(ptr, len) {
        if (!memory || !globalThis.__VSCODET_DEBUG__) return;
        try {
          console.debug("[ghostty]", decoder.decode(new Uint8Array(memory.buffer, ptr, len)));
        } catch {
          // ignore a log during teardown
        }
      },
    },
  });
  memory = instance.exports.memory;
  return new Ghostty(instance);
}

function installMouseAdapter(term, terminalElement, write) {
  const canvas = term.element?.querySelector("canvas") ?? terminalElement.querySelector("canvas");
  if (!canvas) return;
  let pressed = null;

  const inside = (event) => {
    const rect = canvas.getBoundingClientRect();
    return event.clientX >= rect.left && event.clientX < rect.right &&
      event.clientY >= rect.top && event.clientY < rect.bottom;
  };
  const cellAt = (event) => {
    const rect = canvas.getBoundingClientRect();
    const cw = term.renderer?.charWidth || rect.width / Math.max(term.cols, 1);
    const ch = term.renderer?.charHeight || rect.height / Math.max(term.rows, 1);
    const col = Math.floor((event.clientX - rect.left) / cw);
    const row = Math.floor((event.clientY - rect.top) / ch);
    return {
      col: Math.min(Math.max(col, 0), Math.max(term.cols - 1, 0)) + 1,
      row: Math.min(Math.max(row, 0), Math.max(term.rows - 1, 0)) + 1,
    };
  };
  const modifiers = (event) => (event.shiftKey ? 4 : 0) + (event.altKey ? 8 : 0) + (event.ctrlKey ? 16 : 0);
  const send = (code, x, y, release) => {
    write(`\x1b[<${code};${x};${y}${release ? "m" : "M"}`);
  };
  const onDown = (event) => {
    if (!inside(event) || event.button > 2) return;
    event.preventDefault();
    event.stopPropagation();
    term.focus();
    pressed = event.button;
    const { col, row } = cellAt(event);
    send(event.button + modifiers(event), col, row, false);
  };
  const onMove = (event) => {
    if (pressed === null) return;
    event.preventDefault();
    event.stopPropagation();
    if (!inside(event)) return;
    const { col, row } = cellAt(event);
    send(32 + pressed + modifiers(event), col, row, false);
  };
  const onUp = (event) => {
    if (pressed === null) return;
    event.preventDefault();
    event.stopPropagation();
    const button = pressed;
    pressed = null;
    const { col, row } = cellAt(event);
    send(button + modifiers(event), col, row, true);
  };
  const onWheel = (event) => {
    if (!inside(event) || event.deltaY === 0) return;
    event.preventDefault();
    event.stopPropagation();
    const { col, row } = cellAt(event);
    send((event.deltaY < 0 ? 64 : 65) + modifiers(event), col, row, false);
  };
  const onContextMenu = (event) => {
    if (!inside(event)) return;
    event.preventDefault();
    event.stopPropagation();
  };

  window.addEventListener("mousedown", onDown, { capture: true, passive: false });
  window.addEventListener("mousemove", onMove, { capture: true, passive: false });
  window.addEventListener("mouseup", onUp, { capture: true, passive: false });
  window.addEventListener("wheel", onWheel, { capture: true, passive: false });
  window.addEventListener("contextmenu", onContextMenu, { capture: true, passive: false });
  window.addEventListener("blur", () => { pressed = null; });
}

function installResizeHandler(term, fit, terminalElement, pty) {
  let scheduled = false;
  const refit = () => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      try { fit.fit(); } catch { return; }
      try { pty.resize(term.cols, term.rows); } catch { /* pty ended */ }
    });
  };

  if (typeof ResizeObserver !== "undefined") {
    new ResizeObserver(refit).observe(terminalElement);
  }
  window.addEventListener("resize", refit);
  window.visualViewport?.addEventListener("resize", refit);
}

async function start() {
  const support = await checkSupport();
  if (!support.ok) {
    throw new Error(`this browser cannot run unkernel: ${support.problems.join("; ")}`);
  }

  showStatus("Loading terminal…");
  await document.fonts.load('14px "IosevkaTerm Nerd Font"').catch(() => {});
  const ghostty = await loadGhostty();
  const term = new Terminal({
    ghostty,
    cols: 80,
    rows: 24,
    scrollback: 2000,
    convertEol: false,
    cursorBlink: true,
    cursorStyle: "block",
    fontSize: 14,
    fontFamily: FONT_FAMILY,
    theme: THEME,
  });
  term.open(terminalElement);
  const fit = new FitAddon();
  term.loadAddon(fit);
  fit.observeResize?.();
  try { fit.fit(); } catch { /* keep 80x24 */ }

  showStatus("Booting Linux…");
  const binary = await fetchBytes("./vscodet");
  const vm = await createKernel({
    kernel: "./vendor/unkernel/unkernel.wasm",
    distro: "./alpine.erofs",
    worker: false,
    memoryMiB: 1024,
    mounts: {
      "/mnt/host": {
        vscodet: binary,
        workspace: WORKSPACE,
      },
    },
  });

  showStatus("Installing the workbench…");
  await vm.exec(
    "sh",
    ["-c", "cp /mnt/host/vscodet /home/user/vscodet && chmod +x /home/user/vscodet && cp -r /mnt/host/workspace /home/user/workspace"],
    { user: "user" },
  );

  showStatus("Starting vscodeT…");
  const pty = await vm.spawn(
    "/home/user/vscodet",
    ["--user-data-dir", "/home/user/.vscodet", "/home/user/workspace", "/home/user/workspace/demo.ts"],
    { cols: term.cols, rows: term.rows, cwd: "/home/user", user: "user" },
  );

  installMouseAdapter(term, terminalElement, (data) => { pty.write(data).catch(() => {}); });

  pty.output.pipeTo(new WritableStream({
    write(chunk) { term.write(chunk); },
  })).catch(() => {});

  term.onData((data) => { pty.write(data).catch(() => {}); });
  term.onResize(({ cols, rows }) => pty.resize(cols, rows));
  installResizeHandler(term, fit, terminalElement, pty);
  showStatus("");
  try { fit.fit(); } catch { /* keep the current size */ }
  try { pty.resize(term.cols, term.rows); } catch { /* pty ended */ }

  pty.ended.then((result) => {
    showStatus(`vscodeT ended: ${JSON.stringify(result)}`, true);
  }).catch((error) => {
    showStatus(`vscodeT error: ${error?.message ?? error}`, true);
  });
}

start().catch((error) => {
  console.error(error);
  showStatus(error?.message ?? String(error), true);
});
