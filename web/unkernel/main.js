// minecode on unkernel: a real wasm Linux kernel runs the native aarch64 TUI,
// and Ghostty (ghostty-web) is the terminal frontend.
import { Ghostty, Terminal } from "./vendor/ghostty-web/ghostty-web.js";
import { createKernel, checkSupport } from "./vendor/unkernel/web.mjs";

const statusElement = document.getElementById("status");
const terminalElement = document.getElementById("terminal");
const decoder = new TextDecoder();
const FONT_FAMILY = '"IosevkaTerm Nerd Font", "JetBrains Mono", "Cascadia Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace';
let lastTouchAt = 0;

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
  "demo.ts": `// minecode in unkernel — a real Linux kernel in WebAssembly.
import { greet } from "./src/main";

const answer = 42;
console.log(greet("minecode"), answer);
`,
  "src/main.ts": `export function greet(name: string): string {
  const message = \`Hello, \${name}!\`;
  // The sidebar, tabs, Ctrl+P and the integrated terminal are native features.
  return message;
}
`,
  "README.md": `# minecode on unkernel

This is a real aarch64 Debian/Alpine userland booted by unkernel, a Linux
kernel compiled to WebAssembly. The editor is the native minecode TUI, not a
wasm reimplementation.

Press Ctrl+P for quick open, or Alt+Shift+T for the integrated terminal.
`,
  "package.json": `{
  "name": "minecode-unkernel-demo",
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
    if (performance.now() - lastTouchAt < 800) return;
    if (!inside(event) || event.button > 2) return;
    event.preventDefault();
    event.stopPropagation();
    term.focus();
    pressed = event.button;
    const { col, row } = cellAt(event);
    send(event.button + modifiers(event), col, row, false);
  };
  const onMove = (event) => {
    if (performance.now() - lastTouchAt < 800) return;
    if (pressed === null) return;
    event.preventDefault();
    event.stopPropagation();
    if (!inside(event)) return;
    const { col, row } = cellAt(event);
    send(32 + pressed + modifiers(event), col, row, false);
  };
  const onUp = (event) => {
    if (performance.now() - lastTouchAt < 800) return;
    if (pressed === null) return;
    event.preventDefault();
    event.stopPropagation();
    const button = pressed;
    pressed = null;
    const { col, row } = cellAt(event);
    send(button + modifiers(event), col, row, true);
  };
  const onWheel = (event) => {
    if (performance.now() - lastTouchAt < 800) return;
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

function installTouchAdapter(term, terminalElement, write) {
  const canvas = term.element?.querySelector("canvas") ?? terminalElement.querySelector("canvas");
  if (!canvas) return;
  let active = null;

  const inside = (point) => {
    const rect = canvas.getBoundingClientRect();
    return point.clientX >= rect.left && point.clientX < rect.right &&
      point.clientY >= rect.top && point.clientY < rect.bottom;
  };
  const cellAt = (point) => {
    const rect = canvas.getBoundingClientRect();
    const metrics = term.renderer?.getMetrics?.();
    const cw = term.renderer?.charWidth || metrics?.width || rect.width / Math.max(term.cols, 1);
    const ch = term.renderer?.charHeight || metrics?.height || rect.height / Math.max(term.rows, 1);
    const col = Math.floor((point.clientX - rect.left) / cw);
    const row = Math.floor((point.clientY - rect.top) / ch);
    return {
      col: Math.min(Math.max(col, 0), Math.max(term.cols - 1, 0)) + 1,
      row: Math.min(Math.max(row, 0), Math.max(term.rows - 1, 0)) + 1,
    };
  };
  const send = (code, x, y, release) => {
    write(`\x1b[<${code};${x};${y}${release ? "m" : "M"}`);
  };
  const markTouch = () => { lastTouchAt = performance.now(); };

  const onDown = (event) => {
    if (event.pointerType === "mouse") return;
    if (active || !event.isPrimary) return;
    if (!inside(event)) return;
    event.preventDefault();
    event.stopPropagation();
    markTouch();
    const cell = cellAt(event);
    active = {
      id: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      lastY: event.clientY,
      startCol: cell.col,
      startRow: cell.row,
      lastCol: cell.col,
      lastRow: cell.row,
      mode: "pending",
      accum: 0,
    };
    try { terminalElement.setPointerCapture(event.pointerId); } catch { /* ignore */ }
  };

  const onMove = (event) => {
    if (!active || event.pointerId !== active.id) return;
    event.preventDefault();
    event.stopPropagation();
    markTouch();

    const dy = event.clientY - active.startY;
    const dx = event.clientX - active.startX;
    if (active.mode === "pending" && Math.hypot(dx, dy) >= 8) {
      active.mode = Math.abs(dy) > Math.abs(dx) ? "scroll" : "drag";
      if (active.mode === "drag") {
        send(0, active.startCol, active.startRow, false);
      }
      active.lastY = event.clientY;
    }

    const cell = cellAt(event);
    if (active.mode === "scroll") {
      const step = Math.max(6, Math.round((term.renderer?.charHeight || 16) * 0.75));
      active.accum += event.clientY - active.lastY;
      active.lastY = event.clientY;
      while (active.accum >= step) {
        send(64, cell.col, cell.row, false);
        active.accum -= step;
      }
      while (active.accum <= -step) {
        send(65, cell.col, cell.row, false);
        active.accum += step;
      }
    } else if (active.mode === "drag") {
      if (cell.col !== active.lastCol || cell.row !== active.lastRow) {
        send(32, cell.col, cell.row, false);
        active.lastCol = cell.col;
        active.lastRow = cell.row;
      }
    }
  };

  const onUp = (event) => {
    if (!active || event.pointerId !== active.id) return;
    event.preventDefault();
    event.stopPropagation();
    markTouch();
    try { terminalElement.releasePointerCapture(event.pointerId); } catch { /* ignore */ }
    if (active.mode === "pending") {
      send(0, active.startCol, active.startRow, false);
      send(0, active.startCol, active.startRow, true);
    } else if (active.mode === "drag") {
      const cell = cellAt(event);
      send(0, cell.col, cell.row, true);
    }
    active = null;
  };

  const onCancel = (event) => {
    if (!active || event.pointerId !== active.id) return;
    event.preventDefault();
    event.stopPropagation();
    markTouch();
    if (active.mode === "drag") {
      send(0, active.lastCol, active.lastRow, true);
    }
    active = null;
  };

  terminalElement.addEventListener("pointerdown", onDown, { capture: true, passive: false });
  terminalElement.addEventListener("pointermove", onMove, { capture: true, passive: false });
  terminalElement.addEventListener("pointerup", onUp, { capture: true, passive: false });
  terminalElement.addEventListener("pointercancel", onCancel, { capture: true, passive: false });
}

function installResizeHandler(terminalElement, refit) {
  let scheduled = false;
  const schedule = () => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      refit();
    });
  };

  if (typeof ResizeObserver !== "undefined") {
    new ResizeObserver(schedule).observe(terminalElement);
  }
  window.addEventListener("resize", schedule);
  window.visualViewport?.addEventListener("resize", schedule);
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

  const fitGrid = () => {
    const rect = terminalElement.getBoundingClientRect();
    const metrics = term.renderer?.getMetrics?.();
    const cw = term.renderer?.charWidth || metrics?.width || 0;
    const ch = term.renderer?.charHeight || metrics?.height || 0;
    if (!cw || !ch) return;
    const cols = Math.max(20, Math.floor(rect.width / cw));
    const rows = Math.max(5, Math.floor(rect.height / ch));
    if (cols !== term.cols || rows !== term.rows) term.resize(cols, rows);
  };
  fitGrid();

  showStatus("Booting Linux…");
  const binary = await fetchBytes("./minecode");
  const vm = await createKernel({
    kernel: "./vendor/unkernel/unkernel.wasm",
    distro: "./alpine.erofs",
    worker: false,
    memoryMiB: 1024,
    mounts: {
      "/mnt/host": {
        minecode: binary,
        workspace: WORKSPACE,
      },
    },
  });

  showStatus("Installing the workbench…");
  await vm.exec(
    "sh",
    ["-c", "cp /mnt/host/minecode /home/user/minecode && chmod +x /home/user/minecode && cp -r /mnt/host/workspace /home/user/workspace"],
    { user: "user" },
  );

  showStatus("Starting minecode…");
  const pty = await vm.spawn(
    "/home/user/minecode",
    ["--user-data-dir", "/home/user/.minecode", "/home/user/workspace", "/home/user/workspace/demo.ts"],
    { cols: term.cols, rows: term.rows, cwd: "/home/user", user: "user" },
  );

  installMouseAdapter(term, terminalElement, (data) => { pty.write(data).catch(() => {}); });
  installTouchAdapter(term, terminalElement, (data) => { pty.write(data).catch(() => {}); });

  pty.output.pipeTo(new WritableStream({
    write(chunk) { term.write(chunk); },
  })).catch(() => {});

  term.onData((data) => { pty.write(data).catch(() => {}); });
  term.onResize(({ cols, rows }) => pty.resize(cols, rows));
  const resize = () => {
    fitGrid();
    try { pty.resize(term.cols, term.rows); } catch { /* pty ended */ }
  };
  installResizeHandler(terminalElement, resize);
  showStatus("");
  resize();

  pty.ended.then((result) => {
    showStatus(`minecode ended: ${JSON.stringify(result)}`, true);
  }).catch((error) => {
    showStatus(`minecode error: ${error?.message ?? error}`, true);
  });
}

start().catch((error) => {
  console.error(error);
  showStatus(error?.message ?? String(error), true);
});
