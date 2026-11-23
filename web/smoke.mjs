#!/usr/bin/env node
// Headless end-to-end check for the browser demo:
//   editor.wasm -> ANSI frames -> Ghostty's actual VT parser -> cells.
//
// It uses the same `wasi.js` shim as the page, so it also catches missing WASI
// imports. Canvas rendering and DOM input are exercised manually in a browser.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createWasiImports } from './wasi.js';

const editorPath = process.argv[2] ?? 'zig-out/web/editor.wasm';
const ghosttyPath = process.argv[3] ?? 'zig-out/web/vendor/ghostty-web/ghostty-vt.wasm';
const ghosttyJsPath = process.argv[4] ?? 'zig-out/web/vendor/ghostty-web/ghostty-web.js';
if (!fs.existsSync(ghosttyJsPath)) {
  throw new Error(`missing ${ghosttyJsPath}; run \`zig build wasm\` first`);
}
const { Ghostty } = await import(pathToFileURL(path.resolve(ghosttyJsPath)).href);
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const COLS = 80;
const ROWS = 24;

const SAMPLE = `// vscodeT wasm smoke
export function greet(name: string): string {
  return \`Hello, \${name}!\`;
}
const answer = 42;
`;

let editor = null;
let wasm = null;

function memory() {
  return editor?.exports?.memory;
}

function allocCopy(bytes) {
  if (bytes.length === 0) return 0;
  const ptr = wasm.wasm_alloc(bytes.length);
  assert.notEqual(ptr, 0, 'wasm_alloc failed');
  // wasm_alloc may grow memory; take the view afterwards.
  new Uint8Array(memory().buffer, ptr, bytes.length).set(bytes);
  return ptr;
}

function readError() {
  const len = wasm.wasm_error_len();
  if (!len) return '';
  const ptr = wasm.wasm_error_ptr();
  return decoder.decode(new Uint8Array(memory().buffer, ptr, len).slice());
}

function init(text) {
  const textBytes = encoder.encode(text);
  const pathBytes = encoder.encode('/smoke.ts');
  const textPtr = allocCopy(textBytes);
  const pathPtr = allocCopy(pathBytes);
  try {
    const status = wasm.wasm_init(
      textPtr,
      textBytes.length,
      pathPtr,
      pathBytes.length,
      COLS,
      ROWS,
    );
    assert.equal(status, 0, `wasm_init failed: ${readError()}`);
  } finally {
    wasm.wasm_free(textPtr, textBytes.length);
    wasm.wasm_free(pathPtr, pathBytes.length);
  }
}

function renderFrame() {
  wasm.wasm_render();
  const len = wasm.wasm_frame_len();
  if (!len) return new Uint8Array(0);
  const ptr = wasm.wasm_frame_ptr();
  return new Uint8Array(memory().buffer, ptr, len).slice();
}

function sendBytes(bytes) {
  const ptr = allocCopy(bytes);
  try {
    const status = wasm.wasm_input(ptr, bytes.length);
    assert.equal(status, 0, `wasm_input failed: ${readError()}`);
  } finally {
    wasm.wasm_free(ptr, bytes.length);
  }
}

function send(text) {
  sendBytes(encoder.encode(text));
}

function saveText() {
  wasm.wasm_text();
  const len = wasm.wasm_text_len();
  if (!len) return '';
  const ptr = wasm.wasm_text_ptr();
  return decoder.decode(new Uint8Array(memory().buffer, ptr, len).slice());
}

function viewportText(vt, cols, rows) {
  const lines = [];
  for (let y = 0; y < rows; y++) {
    let line = '';
    for (let x = 0; x < cols; x++) {
      const grapheme = vt.getGraphemeString(y, x);
      line += grapheme || ' ';
    }
    lines.push(line.replace(/\s+$/, ''));
  }
  return lines.join('\n');
}

function nonDefaultForegroundCount(vt) {
  const colors = vt.getColors();
  const fg = colors.foreground;
  const cells = vt.getViewport();
  let count = 0;
  for (const cell of cells) {
    if (cell.codepoint === 0 || cell.codepoint === 32) continue;
    if (cell.fg_r !== fg.r || cell.fg_g !== fg.g || cell.fg_b !== fg.b) count++;
  }
  return count;
}

async function main() {
  assert.ok(fs.existsSync(editorPath), `missing ${editorPath}; run \`zig build wasm\``);
  assert.ok(fs.existsSync(ghosttyPath), `missing ${ghosttyPath}`);

  // editor.wasm
  let editorInstance = null;
  const wasi = createWasiImports(() => editorInstance?.exports.memory);
  const editorResult = await WebAssembly.instantiate(fs.readFileSync(editorPath), {
    wasi_snapshot_preview1: wasi,
  });
  editorInstance = editorResult.instance;
  editor = editorInstance;
  wasm = editor.exports;

  // ghostty-vt.wasm, instantiated the same way the page does it.
  let ghosttyMemory = null;
  const ghosttyResult = await WebAssembly.instantiate(fs.readFileSync(ghosttyPath), {
    env: {
      log(ptr, len) {
        if (!globalThis.__VSCODET_DEBUG__) return;
        console.debug('[ghostty]', decoder.decode(new Uint8Array(ghosttyMemory.buffer, ptr, len)));
      },
    },
  });
  ghosttyMemory = ghosttyResult.instance.exports.memory;
  const ghostty = new Ghostty(ghosttyResult.instance);
  const vt = ghostty.createTerminal(COLS, ROWS);

  init(SAMPLE);
  const first = renderFrame();
  assert.ok(first.length > 0, 'first frame is empty');
  assert.ok(first.includes(0x1b), 'first frame has no ANSI escape');

  vt.write(first);
  vt.update();
  const text = viewportText(vt, COLS, ROWS);
  assert.match(text, /vscodeT/, `sample text not rendered by Ghostty:\n${text}`);
  assert.ok(nonDefaultForegroundCount(vt) > 0, 'no syntax-colored cells reached Ghostty');

  // Ghostty's key encoder -> the same terminal bytes the page receives.
  // (The bundle does not export the Key/Mods enum objects, so use the wire
  // values from ghostty-web's types: DOWN=75, PRESS=1, NONE=0.)
  const keyEncoder = ghostty.createKeyEncoder();
  const beforeArrow = wasm.wasm_cursor();
  const arrowDown = keyEncoder.encode({ action: 1, key: 75, mods: 0 });
  assert.ok(arrowDown.length > 0, 'Ghostty key encoder produced no bytes');
  sendBytes(arrowDown);
  const afterArrow = wasm.wasm_cursor();
  assert.notEqual(afterArrow, beforeArrow, 'arrow-down did not move the editor cursor');

  // Typing goes through the same input decoder and editor dispatch as the page.
  send('X');
  const typedFrame = renderFrame();
  vt.write(typedFrame);
  vt.update();
  const typedText = viewportText(vt, COLS, ROWS);
  assert.match(typedText, /X/, `typed character not rendered:\n${typedText}`);

  // A resize must produce a cleared full frame and a 100x30 Ghostty screen.
  assert.equal(wasm.wasm_resize(100, 30), 0, `resize failed: ${readError()}`);
  const resizedFrame = renderFrame();
  assert.ok(resizedFrame.length > 0, 'resized frame is empty');
  vt.resize(100, 30);
  vt.write(resizedFrame);
  vt.update();
  assert.equal(vt.cols, 100);
  assert.equal(vt.rows, 30);
  assert.match(viewportText(vt, 100, 30), /vscodeT/);

  // An SGR mouse press/release must reach View.dispatchMouse and place the caret.
  send('\x1b[<0;10;3M');
  send('\x1b[<0;10;3m');
  assert.notEqual(wasm.wasm_cursor(), 0xFFFFFFFF, 'mouse click left the cursor hidden');

  const saved = saveText();
  assert.match(saved, /vscodeT/, 'saved text lost the document');
  assert.match(saved, /X/, 'saved text lost the typed character');

  wasm.wasm_deinit();
  console.log(`ok: ${editorPath} -> Ghostty (${COLS}x${ROWS}, then 100x30), ${saved.length} saved chars`);
}

main().catch((error) => {
  console.error(error?.stack ?? error);
  process.exitCode = 1;
});
