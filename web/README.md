# vscodeT WebAssembly demo

A single-file browser build of the editor. The editor core and view are Zig
compiled to `wasm32-wasi`; the terminal is **Ghostty** through
[`ghostty-web`](https://github.com/coder/ghostty-web) (the Ghostty VT engine
compiled to wasm with a canvas renderer and an xterm.js-compatible API).

Live: <https://chendesheng.github.io/vscodeT/>

## Build and run locally

```sh
# from the repository root
git submodule update --init --depth 1 third_party/oniguruma
zig build wasm -Doptimize=ReleaseSmall

# serve the generated page (HTTP is required; file:// cannot fetch wasm)
python3 -m http.server -d zig-out/web 8000
# open http://localhost:8000
```

`zig build wasm -Dwasm-only=true` skips the native TUI configuration on a
machine without `libonig-dev`; the wasm build uses the Oniguruma submodule at
`third_party/oniguruma/` (pinned to v6.9.10).

The Ghostty browser bundle is **not checked in**. `zig build wasm` downloads
the pinned `ghostty-web@0.4.0` npm tarball into
`zig-out/web/vendor/ghostty-web/` and verifies the tarball and every extracted
file against [`ghostty-web.lock.json`](ghostty-web.lock.json). The first build
needs network access; later builds reuse the files in `zig-out/web`.

## Smoke test

```sh
zig build wasm-smoke
```

`smoke.mjs` initializes `editor.wasm` with the same WASI shim as the page,
renders its ANSI frames, feeds them to the actual Ghostty parser, and checks
the resulting cells (text, syntax colors, typing, resize and save round-trip).
It does not need a DOM or a browser.

## What is in the demo

- Single-file editing with syntax highlighting (TextMate grammars + wasm
  Oniguruma).
- Cursor, selection, multi-cursor keys, mouse click/drag/wheel, resize/reflow.
- `Ctrl/Cmd+S` save (download), `Ctrl/Cmd+C` copy, `Ctrl/Cmd+V` paste.
- `Open…` loads a UTF-8 text file from the browser; `Save` downloads the
  current buffer.
- The editor's overview-ruler scrollbar is hidden (the browser terminal has no
  local scrollbar); wheel and keyboard scrolling still work.

## Not in the demo

- The workbench shell (explorer, tabs, command palette, panels).
- The integrated terminal: it needs a PTY, which browsers/wasm cannot provide.
- File watching, the Node extension host and language servers, image previews.
- Find/hover widgets and the diff editor.

## How it fits together

```
ghostty-web onData ──UTF-8────▶ editor.wasm: wasm_input
                                    │ ui.input.decodeWithRemainder
                                    ▼
                       editorInputDispatch / view.dispatchMouse
                                    ▼
                              view.refresh()
                                    ▼
ghostty-web write ◀── ANSI diff + cursor ── wasm_render ◀── View.renderAnsi
```

- `editor.wasm` is a reactor; `web/main.js` calls its exported `wasm_*`
  functions. `web/wasi.js` provides only clock, randomness and stdio — no
  filesystem, threads or sockets.
- [`fetch-ghostty-web.mjs`](fetch-ghostty-web.mjs) downloads the pinned
  `ghostty-web@0.4.0` tarball at build time; [`ghostty-web.lock.json`](ghostty-web.lock.json)
  pins the tarball and each extracted file by SHA-256. The generated vendor
  directory includes the MIT `LICENSE` and a provenance `README.md`.
- All page URLs are relative so the same files work at `/` and under a GitHub
  Pages project path such as `/vscodeT/`.

## GitHub Pages

`.github/workflows/pages.yml` builds the wasm demo, runs the smoke test and
uploads `zig-out/web` as the Pages artifact. The repository's Pages source must
be **GitHub Actions** (one-time setup; see the workflow comments). Pushes to
`main` and manual dispatches deploy.

## Limits and notes

- UTF-8 only; `File.text()` does not preserve a BOM or decode legacy encodings.
- Cell widths for emoji/CJK come from Ghostty's Unicode 15.1 tables; the editor
  layout uses the `ui` width tables, so exotic graphemes can differ by a cell.
- Ghostty's `SelectionManager` also starts a local canvas selection on mousedown.
  The demo clears it after each frame so the editor's cell-painted selection is
  the visible one.
- The wasm module is built with `ReleaseSmall` in CI; a debug build is much
  larger and slower.
