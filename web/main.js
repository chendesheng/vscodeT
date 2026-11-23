import { Ghostty, Terminal, FitAddon } from './vendor/ghostty-web/ghostty-web.js';
import { createWasiImports } from './wasi.js';

const terminalElement = document.getElementById('terminal');
const statusElement = document.getElementById('status');
const fileLabel = document.getElementById('file-label');
const openButton = document.getElementById('open');
const saveButton = document.getElementById('save');
const copyButton = document.getElementById('copy');
const pasteButton = document.getElementById('paste');
const fileInput = document.getElementById('file-input');

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const SAMPLE = `// vscodeT WebAssembly demo
// Ghostty (ghostty-web) parses the ANSI frames; the editor is Zig wasm.
import { Editor } from "./core/editor";

export function greet(name: string): string {
  const message = \`Hello, \${name}!\`;
  // syntax colors come from the embedded TextMate grammar
  return message;
}

const answer = 42;
console.log(greet("vscodeT"), answer);
`;

const MODES = '\x1b[?1049h\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[?7l';

const THEME = {
  background: '#1e1e1e',
  foreground: '#d4d4d4',
  cursor: '#aeafad',
  cursorAccent: '#1e1e1e',
  selectionBackground: '#264f78',
  selectionForeground: '#ffffff',
  black: '#000000',
  red: '#cd3131',
  green: '#0dbc79',
  yellow: '#e5e510',
  blue: '#2472c8',
  magenta: '#bc3fbc',
  cyan: '#11a8cd',
  white: '#e5e5e5',
  brightBlack: '#666666',
  brightRed: '#f14c4c',
  brightGreen: '#23d18b',
  brightYellow: '#f5f543',
  brightBlue: '#3b8eea',
  brightMagenta: '#d670d6',
  brightCyan: '#29b8db',
  brightWhite: '#e5e5e5',
};

let ghostty = null;
let term = null;
let fit = null;
let editorInstance = null;
let wasm = null;
let ready = false;
let renderPending = false;
let currentPath = '/demo.ts';
let editorCols = 0;
let editorRows = 0;

function memory() {
  return editorInstance?.exports?.memory;
}

function showStatus(message, isError = false) {
  statusElement.textContent = message;
  statusElement.classList.toggle('error', isError);
  if (isError) console.error(message);
}

function readWasmError() {
  if (!wasm || !memory()) return '';
  const len = wasm.wasm_error_len();
  if (!len) return '';
  const ptr = wasm.wasm_error_ptr();
  return decoder.decode(new Uint8Array(memory().buffer, ptr, len).slice());
}

function fail(message) {
  const detail = readWasmError();
  showStatus(detail ? `${message}: ${detail}` : message, true);
}

async function fetchBytes(url) {
  const response = await fetch(url, { cache: 'no-cache' });
  if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status} ${response.statusText}`);
  return new Uint8Array(await response.arrayBuffer());
}

async function loadGhostty() {
  const bytes = await fetchBytes('./vendor/ghostty-web/ghostty-vt.wasm');
  let memoryRef = null;
  const { instance } = await WebAssembly.instantiate(bytes, {
    env: {
      log(ptr, len) {
        if (!memoryRef || !globalThis.__VSCODET_DEBUG__) return;
        try {
          console.debug('[ghostty]', decoder.decode(new Uint8Array(memoryRef.buffer, ptr, len)));
        } catch {
          // A log call during teardown is not fatal.
        }
      },
    },
  });
  memoryRef = instance.exports.memory;
  return new Ghostty(instance);
}

async function loadEditor() {
  const bytes = await fetchBytes('./editor.wasm');
  const wasi = createWasiImports(() => memory());
  const { instance } = await WebAssembly.instantiate(bytes, {
    wasi_snapshot_preview1: wasi,
  });
  editorInstance = instance;
  wasm = instance.exports;
}

function allocCopy(bytes) {
  if (bytes.length === 0) return 0;
  const ptr = wasm.wasm_alloc(bytes.length);
  if (!ptr) throw new Error('editor.wasm is out of memory');
  new Uint8Array(memory().buffer, ptr, bytes.length).set(bytes);
  return ptr;
}

function initDocument(text, path) {
  const textBytes = encoder.encode(text);
  const pathBytes = encoder.encode(path);
  const textPtr = allocCopy(textBytes);
  const pathPtr = allocCopy(pathBytes);
  try {
    const status = wasm.wasm_init(
      textPtr,
      textBytes.length,
      pathPtr,
      pathBytes.length,
      term.cols,
      term.rows,
    );
    if (status !== 0) throw new Error(readWasmError() || 'editor init failed');
  } finally {
    wasm.wasm_free(textPtr, textBytes.length);
    wasm.wasm_free(pathPtr, pathBytes.length);
  }
  currentPath = path;
  editorCols = term.cols;
  editorRows = term.rows;
  updateFileLabel();
}

function openDocument(text, path) {
  const textBytes = encoder.encode(text);
  const pathBytes = encoder.encode(path);
  const textPtr = allocCopy(textBytes);
  const pathPtr = allocCopy(pathBytes);
  try {
    const status = wasm.wasm_open(
      textPtr,
      textBytes.length,
      pathPtr,
      pathBytes.length,
      term.cols,
      term.rows,
    );
    if (status !== 0) throw new Error(readWasmError() || 'open failed');
  } finally {
    wasm.wasm_free(textPtr, textBytes.length);
    wasm.wasm_free(pathPtr, pathBytes.length);
  }
  currentPath = path;
  editorCols = term.cols;
  editorRows = term.rows;
  updateFileLabel();
  term.clearSelection();
  scheduleRender();
  term.focus();
}

function syncSize() {
  if (!ready || !wasm) return;
  if (term.cols === editorCols && term.rows === editorRows) return;
  editorCols = term.cols;
  editorRows = term.rows;
  wasm.wasm_resize(term.cols, term.rows);
  scheduleRender();
}

function scheduleRender() {
  if (!ready || renderPending) return;
  renderPending = true;
  requestAnimationFrame(() => {
    renderPending = false;
    renderNow();
  });
}

function renderNow() {
  if (!ready || !wasm) return;
  wasm.wasm_render();
  const len = wasm.wasm_frame_len();
  if (len > 0) {
    const ptr = wasm.wasm_frame_ptr();
    const bytes = new Uint8Array(memory().buffer, ptr, len).slice();
    term.write(bytes);
  }
  // The editor paints its selection in the cell grid. Ghostty's local
  // SelectionManager also starts one on mousedown; keep its canvas overlay from
  // competing with (or erasing) the editor's selection.
  if (term.hasSelection()) term.clearSelection();
  const error = readWasmError();
  if (error) showStatus(error, true);
}

function sendInput(bytes) {
  if (!ready || !wasm || bytes.length === 0) return;
  const ptr = allocCopy(bytes);
  try {
    const status = wasm.wasm_input(ptr, bytes.length);
    if (status !== 0) fail('input failed');
  } finally {
    wasm.wasm_free(ptr, bytes.length);
  }
  scheduleRender();
}

// Ghostty's Terminal has its own terminal-centric mouse handling: in the
// alternate screen its wheel handler turns a wheel notch into Up/Down arrow
// keys, and its SelectionManager competes with the editor's selection. For a
// full-screen TUI we want the same SGR reports the native TUI would read.
// Intercept at window capture, before Ghostty's parent/canvas listeners, and
// feed SGR bytes to the editor host ourselves.
function installMouseAdapter() {
  const canvas = term.element?.querySelector('canvas') ?? terminalElement.querySelector('canvas');
  if (!canvas) return;

  let pressed = null;

  function canvasRect() {
    return canvas.getBoundingClientRect();
  }

  function inside(event) {
    const rect = canvasRect();
    return (
      event.clientX >= rect.left &&
      event.clientX < rect.right &&
      event.clientY >= rect.top &&
      event.clientY < rect.bottom
    );
  }

  function cellAt(event) {
    const rect = canvasRect();
    const cw = term.renderer?.charWidth || rect.width / Math.max(term.cols, 1);
    const ch = term.renderer?.charHeight || rect.height / Math.max(term.rows, 1);
    const col = Math.floor((event.clientX - rect.left) / cw);
    const row = Math.floor((event.clientY - rect.top) / ch);
    return {
      col: Math.min(Math.max(col, 0), Math.max(term.cols - 1, 0)) + 1,
      row: Math.min(Math.max(row, 0), Math.max(term.rows - 1, 0)) + 1,
    };
  }

  function modifiers(event) {
    return (event.shiftKey ? 4 : 0) + (event.altKey ? 8 : 0) + (event.ctrlKey ? 16 : 0);
  }

  function sendMouse(code, x, y, release) {
    sendInput(encoder.encode(`\x1b[<${code};${x};${y}${release ? 'm' : 'M'}`));
  }

  function onDown(event) {
    if (!inside(event) || event.button > 2) return;
    event.preventDefault();
    event.stopPropagation();
    term.focus();
    pressed = event.button;
    const { col, row } = cellAt(event);
    sendMouse(event.button + modifiers(event), col, row, false);
  }

  function onMove(event) {
    if (pressed === null) return;
    event.preventDefault();
    event.stopPropagation();
    if (!inside(event)) return;
    const { col, row } = cellAt(event);
    sendMouse(32 + pressed + modifiers(event), col, row, false);
  }

  function onUp(event) {
    if (pressed === null) return;
    event.preventDefault();
    event.stopPropagation();
    const button = pressed;
    pressed = null;
    const { col, row } = cellAt(event);
    sendMouse(button + modifiers(event), col, row, true);
  }

  function onWheel(event) {
    if (!inside(event) || event.deltaY === 0) return;
    event.preventDefault();
    event.stopPropagation();
    const { col, row } = cellAt(event);
    const button = event.deltaY < 0 ? 64 : 65;
    sendMouse(button + modifiers(event), col, row, false);
  }

  function onContextMenu(event) {
    if (!inside(event)) return;
    event.preventDefault();
    event.stopPropagation();
  }

  window.addEventListener('mousedown', onDown, { capture: true, passive: false });
  window.addEventListener('mousemove', onMove, { capture: true, passive: false });
  window.addEventListener('mouseup', onUp, { capture: true, passive: false });
  window.addEventListener('wheel', onWheel, { capture: true, passive: false });
  window.addEventListener('contextmenu', onContextMenu, { capture: true, passive: false });
  window.addEventListener('blur', () => { pressed = null; });
}

async function copySelection() {
  if (!wasm) return;
  wasm.wasm_selection();
  const len = wasm.wasm_selection_len();
  if (!len) return;
  const ptr = wasm.wasm_selection_ptr();
  const text = decoder.decode(new Uint8Array(memory().buffer, ptr, len).slice());
  try {
    await navigator.clipboard.writeText(text);
    showStatus(`Copied ${text.length} character${text.length === 1 ? '' : 's'}`);
  } catch (error) {
    showStatus(`Clipboard write failed: ${error}`, true);
  }
}

async function pasteClipboard() {
  if (!wasm) return;
  try {
    const text = await navigator.clipboard.readText();
    if (!text) return;
    const bytes = encoder.encode(text);
    const ptr = allocCopy(bytes);
    try {
      const status = wasm.wasm_paste(ptr, bytes.length);
      if (status !== 0) fail('paste failed');
    } finally {
      wasm.wasm_free(ptr, bytes.length);
    }
    scheduleRender();
  } catch (error) {
    showStatus(`Clipboard read failed: ${error}`, true);
  }
}

function saveFile() {
  if (!wasm) return;
  wasm.wasm_text();
  const len = wasm.wasm_text_len();
  const bytes = len
    ? new Uint8Array(memory().buffer, wasm.wasm_text_ptr(), len).slice()
    : new Uint8Array(0);
  const name = currentPath.split('/').pop() || 'untitled.txt';
  const url = URL.createObjectURL(new Blob([bytes], { type: 'text/plain;charset=utf-8' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  showStatus(`Saved ${name}`);
}

function updateFileLabel() {
  fileLabel.textContent = currentPath;
  fileLabel.title = currentPath;
  document.title = `${currentPath.split('/').pop() || 'demo'} — vscodeT wasm`;
}

function isModifierCombo(event) {
  return (event.ctrlKey || event.metaKey) && !event.altKey;
}

function onKeyDown(event) {
  if (event.type !== 'keydown' || !isModifierCombo(event)) return false;
  switch (event.code) {
    case 'KeyS':
      event.preventDefault();
      saveFile();
      return true; // consumed: true means "do not pass to the terminal"
    case 'KeyC':
      event.preventDefault();
      void copySelection();
      return true;
    default:
      // Ctrl/Cmd+V deliberately falls through so Ghostty's paste handler can
      // emit a bracketed-paste sequence.
      return false;
  }
}

async function start() {
  if (location.protocol === 'file:') {
    showStatus('This demo must be served over HTTP (GitHub Pages or `python3 -m http.server`).', true);
    return;
  }

  try {
    ghostty = await loadGhostty();
    term = new Terminal({
      ghostty,
      cols: 80,
      rows: 24,
      scrollback: 0,
      convertEol: false,
      cursorBlink: true,
      cursorStyle: 'bar',
      fontSize: 14,
      fontFamily: '"JetBrains Mono", "Cascadia Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
      theme: THEME,
    });
    term.open(terminalElement);

    fit = new FitAddon();
    term.loadAddon(fit);
    try {
      fit.fit();
    } catch {
      // Keep the 80x24 fallback when the container has no layout yet.
    }
    fit.observeResize();

    await loadEditor();
    term.write(MODES);
    initDocument(SAMPLE, '/demo.ts');
    ready = true;

    term.attachCustomKeyEventHandler(onKeyDown);
    term.onData((data) => sendInput(encoder.encode(data)));
    term.onResize(() => syncSize());
    installMouseAdapter();

    syncSize();
    scheduleRender();
    term.focus();
    showStatus('Ready — editor-only demo (no workbench/sidebar/Ctrl+P). Ctrl/Cmd+S saves, Ctrl/Cmd+C copies, Ctrl/Cmd+V pastes.');
  } catch (error) {
    console.error(error);
    showStatus(`Failed to start: ${error?.message ?? error}`, true);
  }
}

openButton.addEventListener('click', () => fileInput.click());
saveButton.addEventListener('click', saveFile);
copyButton.addEventListener('click', () => void copySelection());
pasteButton.addEventListener('click', () => void pasteClipboard());
fileInput.addEventListener('change', async () => {
  const file = fileInput.files?.[0];
  if (!file) return;
  fileInput.value = '';
  try {
    const text = await file.text();
    openDocument(text, `/${file.name}`);
    showStatus(`Opened ${file.name}`);
  } catch (error) {
    showStatus(`Open failed: ${error}`, true);
  }
});

window.addEventListener('beforeunload', () => {
  try {
    wasm?.wasm_deinit();
  } catch {
    // The instance may already be gone.
  }
  term?.dispose();
});

void start();
