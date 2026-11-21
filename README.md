# vscodeT

`vscodeT` is a Zig 0.17 port of Visual Studio Code's editor and workbench
internals to a terminal UI. It started as a port of the editor's pieceTree text
buffer; the target is now the whole pinned VS Code tree in the `vscode/`
submodule: editor core, view/view-model/controller layers, workbench services,
and the Node extension host bridge. Upstream files are never modified; behavior
is ported into `src/vs/...` at matching upstream paths, and built-in extension
sources (currently the Git extension) into `src/extensions/...`, mirroring
`vscode/extensions/...`.

Requires Zig 0.17 or newer.

```sh
# macOS
brew install oniguruma

# Debian/Ubuntu
sudo apt install libonig-dev

zig build        # build the TUI editor
zig build run -- <folder> [<file>...]   # open a workspace folder and files
zig build run -- <file>...   # open files in an empty workspace
zig build run -- --session <file> [<folder>] [<file>...]  # restore/save the tab session
zig build run -- --preview <file>   # read-only terminal UI preview
zig build test   # run the editor and ui library tests
zig build test-watcher -Dwatcher-only=true   # run the file-watcher tests without the TUI
zig build bench-open   # Debug open/edit benchmarks (skipped by zig build test)
```

## Performance

The TUI targets a reasonable default **Debug** build; no ReleaseFast step is
required for the measurements below.

- Workspace watching starts in the `AfterRestored` phase, after the first
  frame, and `fileService.watch` is asynchronous. On macOS the recursive side
  uses FSEvents (constant-time subscribe); Linux and non-FSEvents macOS builds
  run the kqueue/inotify scan on a watcher worker thread. Opening a folder
  therefore no longer walks the whole workspace on the UI thread before first
  paint. The remaining pre-paint costs are theme discovery, workbench setup,
  and the native git initialization; those are separate upstream service
  ports. `main.log`
  records `startup:` stage timings (`workbench-init`, `themes`,
  `workspace-git`, `first-frame`, `after-restored`) for diagnosing them.
- Interactive file and directory reads run off the TUI thread. `Workbench`
  owns a dedicated `std.Io.Threaded` instance (passed explicitly as `async_io`)
  and starts work with `Io.async`: opening a file (read + BOM decode +
  canonical path), expanding an explorer directory, loading image tabs and
  Markdown images, and fetching remote Markdown images. Each feature owns its
  `Io.Future` plus a completion flag; the event loop polls those flags, applies
  results on the TUI thread and clamps the input timeout while a short read is
  pending. Background workers (search, watcher, JSON server, extension host)
  keep their own threads, matching upstream's worker model. The synchronous
  `openPath` remains for startup/session restore and tests. Watcher-triggered
  settings, user-keybindings, color-theme and clean-editor external-change
  reloads also read their files on the async Io: configuration sources,
  keybindings, theme files and editor contents are prepared on a worker and
  installed on the TUI poll tick, matching upstream's asynchronous
  configuration/theme/text-file reload flows. Startup scans and mouse-click
  preview opens plus extension-host `openPath` calls still use the synchronous
  path.
- Opening a file performs one view render and one full wrapping pass. The
  workbench reserves the overview-ruler/scrollbar columns before that pass, and
  a path that is already open reuses its existing tab/editor instead of
  re-reading and constructing a new one.
- Edits apply the model's raw changes through
  `ProjectedViewModelLines.applyRawChanges` instead of re-wrapping the whole
  file, matching upstream's incremental view-model update. A keystroke lets
  the token store invalidate from the edited line and tokenizes from the first
  invalid line; it no longer forces a refresh of the whole visible range.
- Scrolling goes through the ported upstream pipeline: the wheel is owned by
  the `EditorScrollbar` view part (`mouseWheelScrollSensitivity`,
  `fastScrollSensitivity`, clamped by the same scroll state), and the vertical
  position lives in a line-granular `ViewLayout` instead of an editor field.
  The layout emits upstream's `ViewScrollChanged`; `ViewLines` reuses the
  overlapping rendered-line window, re-renders only lines invalidated by the
  view events, and paints the retained output. The editor keeps a retained,
  windowed line DOM (only the visible `ViewLine` elements exist); a scroll
  updates their box geometry and leaves their text nodes alone, an entering
  line gets the recycled node, and a changed line rewrites only its own runs.
  Text runs share interned paint styles keyed like CSS classes (`mtk*` +
  decoration classes). A scroll no longer rebuilds the whole editor model,
  the line DOM or the workbench chrome.
- Status bar, side bar title and panel title keep their last painted surface
  grid and skip the clear + flex layout when their content, width, theme,
  focus and hover state are unchanged, matching the editor's retained line
  DOM: a scroll in the editor renders only the lines that moved or entered.
- The Unicode line-break property tables are decoded at compile time instead
  of rebuilt on every `layoutTree` call, which removes a fixed per-layout cost
  from every surface. The paint path also has an ASCII fast path.
- Folding is scheduled like upstream: a 200 ms minimum debounce, coalesced while
  typing, and driven by the main-loop tick. Fold commands and gutter clicks
  still compute immediately.
- Large documents defer the initial bracket-pair AST/guide/colorization build
  (another whole-document pass) until the debounced main-loop tick. Bracket
  matching uses the ported upstream fallback matcher when bracket-pair
  colorization is disabled, and the AST otherwise, as upstream does. The
  deferral keeps first paint and key echo fast, but the one-time AST build can
  cause a brief pause when the app is idle after opening or editing a large
  file.
- Visible-line tokens are forced synchronously for the viewport. An incremental
  scroll tokenizes only the new lines; a jump tokenizes the visible range from
  a guessed start state instead of walking every line from the first invalid
  one. The remaining lines are tokenized by the upstream-shaped threaded
  TextMate worker (one dedicated thread, state/token deltas applied on the
  TUI loop). The ported `DefaultBackgroundTokenizer` remains the fallback for
  disabled async tokenization, too-large models, tests and non-TextMate
  tokenizers. The first open of a language still loads its TextMate grammar
  once per process on the worker.
- Idle maintenance repaints are coalesced: while background tokenization is
  running the main loop repaints at most once per 8 ms (the final delta always
  paints). Folding/bracket-guide passes and input are not delayed. The
  extension-host pump also skips rebuilding the editor-tabs spec list when the
  tab set, active tab and dirty flags are unchanged.
- The TUI process uses a stack-trace-free `DebugAllocator` in Debug builds.
  The debug allocator's unwinding used to be 70-94% of active CPU in the
  end-to-end profile; safety checks and the leak report at exit are kept, and
  the test suite still uses the fully instrumented testing allocator.
- `zig build bench-open` runs the opt-in `benchmark:` tests: open stages, edit
  stage breakdown, one-line/page/wheel scroll frames, a full-workbench scroll
  frame, word-highlight scanning, and the viewport-tokenization contract. Pass
  `-Dbench-file=<path>` to benchmark another file (default
  `src/tui/app.zig`). The 2026-11-21 scroll-pipeline numbers are in
  [docs/perf/2026-11-21/README.md](docs/perf/2026-11-21/README.md).
- An end-to-end profile of the default Debug build and ReleaseFast, including
  historical VSCodeVim interaction latency and CPU hotspots, is in
  [docs/performance-profile-2026-11-20.md](docs/performance-profile-2026-11-20.md).

## Upstream VS Code checkout

The upstream tree is embedded as the `vscode/` git submodule, pinned to VS Code
**1.147.0** at commit `e31c2e52f563620846caab877103f630ea361b9c`. That is the
exact tree the port inventory, generated extension-host RPC table and line
counts were taken from. The `1.147.0` release tag points at a different commit
(`8a14f0cc`), so pin the commit, not the tag.

The submodule is shallow (`.gitmodules` sets `shallow = true`), so cloning does
not download VS Code's history and the checkout is pinned to the recorded
commit. Git's submodule initializer may also fetch the current default-branch
tip at depth 1; that tip is not checked out.

```sh
git clone --recurse-submodules --shallow-submodules <repo-url>
# or, in an existing checkout:
git submodule update --init --depth 1
```

Without an initialized submodule, `zig build` still works with the vendored
grammar and theme fallbacks in `src/support/` (Zig, TOML, YAML and Markdown,
plus Dark+); the remaining upstream syntax/theme assets, language
configurations and the Node extension host need `vscode/`.
The host bundle always reads the pinned `vscode/` submodule; there is no
checkout override, so the protocol table and bundle cannot drift apart.

Bumping the pin is not a routine dependency update: the generated protocol
table and the ported line counts are tied to this commit. Move the submodule
checkout, rerun `node host/generateProtocol.js`, and update this section,
`AGENTS.md` and the pin in `docs/` in the same change.

Notes for the Zig 0.17 port:

- `@cImport` was removed in Zig 0.17, so `oniguruma.h` is translated by the
  build system (`addTranslateC`) and imported as the `oniguruma` module. The
  build searches the standard Homebrew and Linux prefixes for the header and
  library. The editor tokenizer uses the standalone `vscode_textmate` package
  in `textmate/`; Zig/TOML/YAML/Markdown fallback grammars and the fallback
  Dark+ theme are vendored under `src/support/`.
- `std.io` was replaced by the `std.Io` reader/writer interfaces; the app
  receives its `Io` instance through `std.process.Init`.
- `std.ArrayList` is unmanaged in Zig 0.17. This port currently uses the
  deprecated-but-supported `std.array_list.Managed` shim as an intermediate
  step; moving to unmanaged lists is the main remaining modernization.

## Integrated terminal

The TUI has a bottom terminal panel backed by a real POSIX pty and the
[libghostty-vt](https://libghostty.tip.ghostty.org/vt/) terminal engine
(pinned in `build.zig.zon`). It is the terminal counterpart of VS Code's
xterm.js instance: VS Code's portable profile/environment/title/service code is
ported under `src/vs/{platform,workbench}/.../terminal/`, the pty replaces
node-pty, and libghostty-vt replaces xterm.js. No upstream files are modified.

| Action | Shortcut |
| --- | --- |
| Toggle terminal panel | `Alt+Shift+T` (also "Terminal: Toggle Terminal" in the command palette) |
| New terminal | `Alt+Shift+N` |
| Kill active terminal | `Alt+Shift+W` |
| Previous / next terminal tab | `Ctrl+PageUp` / `Ctrl+PageDown` while the terminal has focus |
| Resize panel | `Alt+Shift+Up` / `Alt+Shift+Down` (mouse drag is a follow-up) |

The panel handles interactive programs (alternate screen, colors, cursor
addressing), UTF-8 and grapheme clusters, scrollback, resize (pty `TIOCSWINSZ`),
mouse reporting, focus reporting and bracketed paste. `Ctrl+Q` remains the TUI
quit shortcut even while the terminal is focused. Width and height come from
the panel view's cell layout: `terminalTabbedView.layout` reserves the tab-strip
row and hands the remaining cells to `TerminalInstance.layout` for every tab,
mirroring upstream's `TerminalGroup.layout` → `TerminalInstance.layout` flow.
Tab-strip actions (`+`, `x`, tab switching) only run on a left-button press;
idle motion, wheel and non-left buttons never create, close or switch tabs.

Known phase-1 limits:

- POSIX only. Windows reports the terminal as unsupported; ConPTY is a
  follow-up.
- One pane per group (tabs, no split terminals) and no terminal editors.
- No terminal selection/copy, find, link opening, shell-integration
  decorations or runtime theme switching. The TUI has no system clipboard;
  copy is planned as an OSC 52 bridge to the outer terminal.
- The integrated terminal panel does not forward kitty images; the workbench
  editor uses them for image previews (see **Image preview**). WebGL/ligature/
  unicode addons, persistent/remote terminals and accessibility mode are not
  ported.
- The terminal cursor uses the outer terminal's cursor shape; bar/underline
  cursor settings are approximated.

The full rationale and the phased scope are in
[`docs/terminal-ui.md`](docs/terminal-ui.md). `zig build test-terminal` runs the
terminal-specific tests without compiling the editor.

## Logging

The TUI logs through the ported service in
`src/vs/platform/log/common/log.zig` and `logService.zig` (the upstream
`AbstractLogger`/`AbstractMessageLogger`, `AdapterLogger`, `BufferLogger`,
`MultiplexLogger`, `NullLogger`, `createUnexpectedErrorHandler` and
`format`). `src/vs/platform/log/common/fileLog.zig`
is the terminal host: it keeps one synchronous `main.log` and writes the same
line format as upstream's `FileLogger`:

```text
2026-11-17 03:36:00.568Z [info] workbench ready: 2 tab(s)
```

The file lives in the terminal user data directory's `logs` folder
(`~/Library/Application Support/vscode-textbuffer/logs/main.log` on macOS,
`$XDG_CONFIG_HOME/vscode-textbuffer/logs/main.log` on Linux,
`%APPDATA%\vscode-textbuffer\logs\main.log` on Windows); the upstream
`--logsPath <dir>` switch overrides the directory. Timestamps are UTC because
the terminal host has no time-zone database.
Console loggers, the URI-keyed `ILoggerService` registry and the log-output
picker are not ported: the TUI owns the terminal (alternate screen, raw mode)
and has a single log file instead of per-channel resources.

Because the alternate screen belongs to the TUI, nothing may write log output
to stderr while it is active. `src/main.zig` installs `std_options.logFn`, and
`src/tui/app.zig` routes `std.log` lines — including libghostty-vt's parser
diagnostics such as unimplemented OSC sequences — through the same `ILogger`
into `main.log`. The file logger's level filters them as usual (its `info`
default drops engine `debug` lines); if no log file is available, engine logs
are dropped while the TUI is running instead of painting over the cell grid.

Crash reports are the exception: `panic` and the SIGSEGV/SIGBUS/SIGILL/SIGFPE
handler leave the alternate screen, re-enable wrapping/cursor visibility and
restore raw mode before the Zig stack trace is printed to stderr. The trace
therefore stays on the normal screen after the editor exits instead of being
written to a discarded alternate screen.

## File watcher

The workspace watcher is the ported parcel watcher, started through the
upstream-shaped async client in `src/vs/platform/files/node/watcher/watcherClient.zig`.
`WorkspaceWatcher` is registered in the `AfterRestored` workbench phase, after
the first frame; `fileService.watch` only queues the request, and the recursive
scan runs on a watcher worker thread instead of the UI thread. This mirrors
VS Code's watcher utility process without an Electron process: the worker
thread is the terminal transport, and the watcher implementation itself is
unchanged. Stopping the watcher cancels an in-progress recursive scan
cooperatively, so quitting does not wait for a large tree walk.

`files.watcherExclude` (upstream defaults plus the user setting) and
`files.watcherInclude` are wired.

On macOS the recursive side uses the ported FSEvents backend
(`src/vs/platform/files/node/watcher/parcel/watcherLib/fsevents.zig`), the
backend VS Code's `@parcel/watcher` uses there. It runs a CFRunLoop thread and
subscribes in constant time, so recursive watching needs no initial tree walk
and no per-directory descriptors. FSEvents only watches directories, so
non-recursive requests (the settings watcher and `NodeJSWatcher`) stay on
kqueue; kqueue is also used when cross-compiling macOS watcher tests from a
non-macOS host. FSEvents has no initial directory snapshot, so its first event
for a pre-existing path can be `ADDED`; open editors treat `ADDED` and
`UPDATED` the same way for content reloads. Large build caches should still be
added to `files.watcherExclude`: the patterns are passed to the FSEvents
stream's exclusion paths and filtered on the worker.

## Extension host (experimental)

The workbench half of VS Code's extension system is being ported under
`src/vs/workbench/services/extensions/` and `src/vs/workbench/api/`. The Node
extension host itself is reused, not vendored: the launcher in
`host/extensionHost.ts` bundles the module graph reachable from the pinned
tree's `src/vs/workbench/api/common/extensionHostMain.ts` with esbuild, so a
full VS Code `out/` build is not required.

The bundle must come from the **pinned VS Code 1.147.0** tree (commit
`e31c2e5`): the Zig workbench's generated RPC actor table only matches that
version, and a mismatch makes every handshake call land on the wrong actor.
`host/build.js` refuses any other version instead of producing a bundle that
fails at runtime.

```sh
cd host && npm ci                          # esbuild, @vscode/ripgrep, @vscode/spdlog
cd .. && zig build host                    # bundles from the pinned vscode/ submodule
zig build run -- [--user-data-dir <dir>] [--extensions-dir <dir>] [--logsPath <dir>] [<file>...]
zig build test-e2e                        # boots the Node host and runs TypeScript extension interop
```

`host/build.js` always reads the embedded pinned `vscode/` checkout. `zig build`
itself never runs Node; `zig build host` is the explicit step that produces
`host/dist/extensionHost.mjs`.

`npm run build:json` (in `host/`) is the optional `host/dist/jsonServer.mjs`
step. If the host bundle is missing at startup, the app reports
`extension host disabled: host/dist/extensionHost.mjs is missing` in the main
log instead of waiting for the host socket to time out.

On Windows the host is not started: its transport is a Unix socket and the
launcher runs through `/bin/sh`. The app reports
`extension host disabled: UnsupportedPlatform` and otherwise keeps running;
ConPTY and a named-pipe transport are follow-ups.

`npm run build:typescript-extension` (in `host/`) is the optional step that
provisions VS Code's real `typescript-language-features` extension and
its TypeScript SDK under `host/dist/extensions`. It autodetects a standard VS Code
installation and copies the extension and SDK from it; there is no path or SDK
override. The extension is a runtime asset, not vendored source.

The JSON server bundle reuses the runtime dependencies of the pinned
`vscode/extensions/json-language-features/server`; install them there first
with `npm install` if the bundle step cannot resolve `vscode-languageserver`.

The Node host is used for provisioned built-in Node extensions such as
`typescript-language-features`. VSCodeVim is no longer discovered or loaded.

Vim is a compiled-in built-in extension (`vscode-textbuffer.vim`), enabled
with `"vim.enabled": true` in the user settings or after startup with the
`Vim: Enable` / `Vim: Disable` commands; both persist the user-level
`vim.enabled` setting. It does not use the Node extension
host. The editor core knows only the generic built-in extension and
key-input interfaces; the Vim extension registers its own key handler through
them. The normal/insert/replace/visual character/line/block modes, counts, motions
(`{`/`}`, `(`, `)`, `H`/`M`/`L`, `gj`/`gk`, `f`/`t`), operators, text objects, marks, macros,
registers, undo/redo (`u`/`U`/`Ctrl-R`), visual-block `I`/`A`, dot-repeat,
regular-expression search, the workbench editor navigation history (`Ctrl-O`/`Ctrl-I`)
(`/`, `?`, `n`, `N`), viewport commands (`zz`/`zt`/`zb`, `Ctrl-D`/`U`) and the
basic `:` commands (`:w`, `:q`, `:q!`, `:wq`, `:e`, `:bn`, `:bp`, `:bd`, `:sp`,
`:vsp`, `:noh`) are implemented in Zig.

Vim uses the editor's own state instead of a parallel history:

- `u`/`Ctrl-R` call `Editor.undo()`/`Editor.redo()`. One insert session or
  operator change is one editor undo group; no diff tracker is kept.
- `j`/`k` use the editor's `leftoverVisibleColumns`, so the visible column is
  preserved across tabs, wide characters and short lines.
- Visual selections and cursor positions live in the editor's selection state.
  Vim keeps only command state (pending count/operator, registers, search).

The status bar shows `-- NORMAL --`, `-- INSERT --`, `-- VISUAL --`, pending
keys and the `:`/`/` prompt. See `docs/vim.md` for the supported feature list
and the deliberate non-goals (Vimscript, plugins and `.vimrc`).

Helix is the second compiled-in modal editor (`vscode-textbuffer.helix`),
enabled with `"helix.enabled": true` or with the `Helix: Enable` /
`Helix: Disable` commands; both persist the user-level `helix.enabled`
setting. It uses the same editor-state ownership and raw key-input contract as
Vim, but follows Helix's selection-first model: `w` selects a word, `d` acts on
the selection, `x` selects a line, `%` selects the file, `s` selects regex
matches, and editing commands work on every selection. The normal/insert/select
modes, multiple selections, registers, macros, `.` repeat, search, command line,
goto/match/view/window/space minor modes, linewise, surround and text-object
operations (`mi`/`ma`), and the `:` commands (`:w`, `:q`, `:q!`, `:wq`, `:e`,
`:reload`, `:bn`, `:bp`, `:bd`, `:sp`, `:vsp`, `:noh`, `:set`) are implemented
in Zig. Vim and Helix are mutually exclusive: enabling one disables and
persists the other off. See `docs/helix.md` for the supported surface and
deliberate gaps.

Declarative built-ins are scanned from `vscode/extensions/theme-defaults`
and `vscode/extensions/markdown-basics`: their themes, languages, grammars
and language configurations are loaded at startup. The markdown language
therefore gets its upstream `<!-- -->` comment rule, bracket pairs, auto-closing
pairs and off-side folding even when the built-in grammar was already bundled.

JSON and JSONC editors use the bundled VS Code JSON language server when
`host/dist/jsonServer.mjs` is present. Syntax diagnostics are pulled after
edits and shown as severity-colored squiggle underlines over their ranges in
the editor, in the `Problems` panel view and in the status-bar counts; `Ctrl-Space` completion
comes from the same server. Without the server bundle the editor keeps the
bundled grammar and reports no diagnostics. Hover, formatting and document
symbols are forwarded to the same server, and the `json.schemas` setting is
passed through so configured schemas drive validation, completion and hover.
JSON document symbols feed breadcrumbs/outline and `Go to Symbol in Editor`.
The pinned JSON server does not advertise definition or references, so those
navigation actions stay unavailable for JSON. Indentation does not come from the
language server: `json-language-features` contributes only the client/server,
while the indent rules live in the separate built-in `extensions/json`
language configuration. The build embeds that upstream
`language-configuration.json`, so JSON/JSONC `Enter` auto-indent and
closing-bracket outdent also work without `host/dist/jsonServer.mjs`.

TypeScript and JavaScript editors use VS Code's real
`typescript-language-features` extension when `host/dist/extensions` has been
provisioned. The extension is activated by `onLanguage:<id>` after the document
delta is queued; its own tsserver client provides semantic/syntax diagnostics
(shown as squiggly underlines, overview marks, the Problems view and the workspace count),
`Ctrl-Space` completion, hover, `F12`/`Ctrl-]` go-to-definition,
`Ctrl-F12` go-to-implementation, `Shift-F12` go-to-references, the
`Go to Declaration`, `Go to Type Definition`, `Peek References` and
`Find All References` commands, `Ctrl-Shift-O`/`Ctrl-O`/`gO` go-to-symbol,
`Alt-F` document formatting and breadcrumb document symbols. Without the extension bundle, TS/JS tabs keep the bundled
grammar and indentation behavior. The extension host receives the extension's
`contributes.configuration` defaults, so settings such as
`js/ts.format.enabled` resolve like VS Code. Position-bearing RPCs (diagnostics,
completion/hover ranges, formatting edits, document changes and selections) are
converted between the host's UTF-16 code units and the editor's UTF-8 byte
columns. Semantic tokens, inlay hints, code lens, links, colors, call
hierarchy and inline completions are registered by the extension but have no
terminal renderer; navigation and reference results open in the terminal
quick pick, while code actions still have no TUI command surface. Configuration writes are accepted in memory and are not
persisted.

Extensions can also contribute language features through the ported
language-feature bridge: hover, completion, definition, declaration,
implementation, type definition, references, document symbols, code actions and
document/range/on-type formatting register in `LanguageFeaturesService`, and
diagnostics feed the marker service, which paints severity-colored squiggly
range underlines, overview-ruler marks, the `Problems` panel view and the workspace
error/warning/info status counts. Selecting a problem highlights its code range
in the editor while the Problems view owns focus. Hover, completion, the
navigation actions, breadcrumb symbols and document formatting are wired to the
terminal editor. Code-action providers are transported but have no TUI command
surface yet, and the remaining `MainThreadLanguageFeatures` methods stay
unsupported. Provider calls are synchronous with a bounded timeout
because the terminal editor has no asynchronous provider boundary.

Host stderr is written to `<data dir>/extension-host.log` (normally
`<user-data-dir>/logs/extension-host.log`) so it cannot
corrupt the TUI frame. Startup failures that disable the host are logged to
the main log (`<user-data-dir>/logs/main.log`). `test-e2e` is skipped unless
`host/dist/extensionHost.mjs` and the TypeScript extension fixture are present.
Caret and selection changes the TUI makes itself (click, drag, TUI-handled
keys, find) are pushed to the host with upstream's `source` string so Node
language extensions stay in step. Still missing: the contribution scanner,
configuration writes, full `tabGroups`, the rest of the built-in command set,
and the extension keybinding registry. See `docs/extensions.md` for the port
status and the remaining work.

## Continuous integration

GitHub Actions (`.github/workflows/ci.yml`) runs the full `zig build test`
suite on Linux (inotify), macOS (kqueue) and Windows (`ReadDirectoryChangesW`),
and cross-compiles the watcher-only test root for `x86_64-windows` and
`aarch64-macos` on Linux. The Linux, macOS and Windows jobs initialize the
shallow `vscode/` submodule at the pinned commit, so the tokenizer, theme and
extension-asset tests run against the real upstream tree instead of the
fallbacks. The Windows job installs oniguruma with vcpkg and passes
`-Donig-include`/`-Donig-lib` to the build; the terminal layer uses the Windows
console API for raw mode, sizing and input polling.

## Design docs

- [Terminal UI architecture](docs/terminal-ui.md) — the standalone `ui/`
  library: DOM tree model, cell-grid renderer, and the POC-first plan for
  porting the browser UI.
- [Extension system](docs/extensions.md) — reuse VS Code's Node extension host
  unmodified, port the workbench side (RPC codec, `MainThread*` actors,
  scanner, contribution points, TUI wiring) to Zig.
- [Built-in extensions](docs/builtin-extensions.md) — the compiled-in extension
  contract, raw key-input contribution point and lifecycle.
- [Native Vim](docs/vim.md) — editor-state ownership, supported Vim surface and
  deliberate gaps.
- [Native Helix](docs/helix.md) — selection-first model, supported Helix
  surface, mutual exclusion with Vim and deliberate gaps.
- [TUI porting inventory](docs/porting-inventory.md) — file-by-file mapping of
  `src/tui/` to the VS Code internals it should port, with a UI/view code map
  (what is still collapsed into `view.zig`/`editor.zig` and where it belongs)
  and a prioritized, dependency-ordered roadmap.
- [TUI review](docs/tui-review.md) — current file-by-file verdict on `src/tui/`:
  what still has a VS Code port, what moves into `ui/`, what is dead or
  duplicated, and the dependency-ordered path to a thin host.
- [Git integration and diff view plan](docs/git-diff-plan.md) — proposed
  read-only Git/SCM integration, quick-diff decorations and a terminal
  side-by-side diff viewer, with the view-parts wiring and test plan.

## Terminal UI library

- `ui/` is a standalone Zig package outside `src/`: a DOM-like tree with direct
  styles (no CSS), a derived layout box tree (viewport, principal, anonymous and
  text boxes), whole-cell layout with margin/padding/border boxes and borders
  that paint as cell-edge attributes under the draft cell-border protocol (with
  box-drawing fallback), block/inline/flex formatting contexts, CSS white-space
  and UAX #14 text wrapping, and a double-buffered cell renderer that emits only
  an ANSI frame diff. Flex supports direction, wrap, grow/shrink/basis,
  content-box `min_width`/`max_width`, justify/align, gap, order, auto margins
  and content-derived auto sizes. Text
  fragments and inline-element fragments paint per line. On startup the TUI
  probes the draft cell-border protocol; when the terminal supports it, every
  editor pane is outlined on its own cell edges (active pane on top by
  priority), adjacent outlines merge, and panes are resized by dragging the
  sash between them. Without support the glyph fallback keeps the gutter and
  box-drawing dividers. It does not import editor code.
- Multi-file editing uses the ported workbench editor-group model
  (`src/vs/workbench/common/editor/editorGroupModel.zig`), the editor part,
  group view and pane layers (`src/vs/workbench/browser/parts/editor/`), a
  terminal tab strip (`src/vs/workbench/browser/parts/editor/multiEditorTabsControl.zig`) and a terminal breadcrumb bar
  (`src/vs/base/browser/ui/breadcrumbs/breadcrumbsWidget.zig`,
  `src/vs/workbench/browser/parts/editor/breadcrumbs{,Model,Control,Picker}.zig` with
  the outline service under `src/vs/workbench/services/outline/`). Each tab keeps
  its own `Editor`, `View` and lazy editor contributions; only the active view is
  composited under the two chrome rows, so switching tabs preserves scroll
  position and decorations. Tabs show the Explorer's Nerd Font file icon (the
  terminal adaptation of the file icon theme), preview italics, a close cell
  and a dirty dot; tab hover, borders, the last-pinned separator and the
  active-tab top border use their theme ids (the top border only when the
  terminal supports cell borders), right-click opens the terminal tab context
  menu (Close, Close Others, Close All, Pin/Unpin) instead of closing or
  activating a tab, duplicate labels append a dimmed parent-directory
  description (`workbench.editor.labelFormat` short/medium/long/default is
  read), the close cell and middle click close it, and `Ctrl-W` closes the
  active tab. A dirty tab first opens VS Code's save confirmation
  (Save / Don't Save / Cancel): Save writes and then closes only if the buffer
  is clean, Don't Save discards the changes, and Cancel or Escape leaves the
  tab open. The dialog is
  modal, names the file, dims the rest of the workbench and hides the caret;
  short terminals collapse its vertical buttons to one row.
  Double-clicking a preview tab pins it; double-clicking a pinned
  tab toggles the group's expanded (whole-editor-area) state, matching
  upstream's default `doubleClickTabToToggleEditorGroupSizes: 'expand'`.
  Explorer single clicks open a preview editor, while Enter, quick open, CLI
  paths and session restore open pinned; editing a preview pins it.
  `Ctrl-W` closes the active tab, `Ctrl-PgUp`/`Ctrl-PgDn` switch tabs, `Alt-1..9`
  activates a tab by position, `Ctrl-S` saves and `Ctrl-Q` quits. With dirty
  tabs, `Ctrl-Q` opens the same save confirmation for all of them (Save All /
  Don't Save / Cancel) and exits after saving or discarding. Empty groups
  collapse out of the split tree when their last tab closes, the divider between panes is a
  draggable sash, and dragging a tab into another pane (or onto its edge) retiles the
  editor part. A drag over a tab strip previews the insertion position; dropping
  reorders the tab within its strip or inserts it at that position in another group.
  `--preview` remains a single-file mode.
- The breadcrumb row shows the workspace-relative file path (absolute segments
  outside the workspace) with `>` separators and the Explorer's Nerd Font file
  icon; `>` and the segments follow the upstream focus/selection rules. Each
  editor group keeps one persistent breadcrumb control, so an inactive group
  is not rebuilt every frame; disabled breadcrumbs ignore clicks, hover only
  applies when the item is neither focused nor selected, `focused.selected`
  uses `breadcrumb.activeSelectionForeground`, and separators inherit
  `breadcrumb.foreground`; files outside the workspace under `$HOME` get a
  `~` root segment; the widget also exposes the upstream
  `onDidSelectItem`/`onDidFocusItem`/`onDidChangeFocus` events. The terminal
  picker adds a `..` parent entry after
  drilling into a folder, and workspace roots follow the upstream
  multi-root/single-folder rule.
  Clicking a folder or file opens the terminal quick pick with the directory's
  children, and clicking a symbol reveals it. Symbol segments are supplied by
  the ported `IOutlineService`/`IOutline` plumbing. The real TypeScript
  extension registers a document-symbol provider for TS/JS files; other
  languages still show only the file path until an extension provider is
  registered. `Ctrl+Shift+.` focuses/selects the last segment
  and `Ctrl+Shift+;` focuses it; Left/Right navigate, Enter/Down opens the picker,
  Space reveals and Escape returns to the editor. Terminal substitutions: the
  browser chevron/codicon is `>`, the file icon theme is the Explorer's Nerd Font
  file icon, the tree picker is the existing quick pick, and overflow clips
  leading segments behind an ellipsis instead of a horizontal scrollbar. The
  editor-type dropdown, breadcrumb drag-and-drop, tab context menus/actions
  toolbar and the symbol-kind filters are not ported.
- A terminal Explorer sidebar (`src/vs/workbench/contrib/files/browser/views/explorerView.zig`) sits left of the editor
  area over the ported `ExplorerModel`
  (`src/vs/workbench/contrib/files/common/explorerModel.zig`). It lists the
  workspace folders lazily, directories first, expands/collapses with
  `Right`/`Left` or a click, moves with `Up`/`Down`, and opens a file on
  `Enter` or a click through the same cross-group `openPath` path as the tab
  model. In a single-folder workspace the folder is the tree input, so its
  children are the top-level rows; a multi-root workspace shows root rows and
  expands the first five roots, matching the Explorer view's default. Deeper
  directories resolve only when expanded. Directory listings resolve symbolic
  links to the target file type, mirroring upstream's
  `DiskFileSystemProvider.readdir`: a linked directory renders and expands as a
  directory, files under it open through the link path, and a dangling link
  stays an unknown entry with its `SymbolicLink` flag. Filtering now runs
  through the upstream-shaped `FilesFilter`
  (`src/vs/workbench/contrib/files/browser/views/explorerViewer.zig`): it
  evaluates `files.exclude` per workspace root, applies `!` exceptions and
  keeps the folders that lead to an exception visible. Entries matched by
  `.gitignore`/`.ignore` are hidden through the ported `IgnoreFile`
  (`src/vs/workbench/services/search/common/ignoreFile.zig`), including nested
  ignore files and `!` negations; the ignore files themselves stay visible.
  VS Code's default `**/.git`, `**/.svn`, `**/.hg`, `**/.jj`, `**/.DS_Store`
  and `**/Thumbs.db` patterns still apply, and `explorer.excludeGitIgnore`
  controls the ignore-file filtering. The TUI default for that setting is on,
  unlike upstream's off default, because the Explorer hid ignored entries
  before the configuration service existed; workspace settings can turn it off.
  An open editor keeps an otherwise excluded file and its parent folders
  visible. `explorer.autoReveal` is honored, and
  opening or activating a file selects it in the Explorer without moving focus;
  directory twisties toggle on click while the rest of the row only selects.
  A one-cell scrollbar appears when the list overflows, and the selection is
  dimmed while the Explorer is unfocused. `explorer.sortOrder` is honored for
  `default`, `mixed`, `filesFirst` and `type` (`modified` falls back until
  mtimes are collected), and ignore/exclude filtering now runs through the tree
  filter instead of pruning the model. `explorer.compactFolders` is honored
  (default on): a lone child chain such as `src/vs/editor` renders as one
  compressed row, expands/collapses as one node, and resolves the compressed
  child through `autoExpandCompressedChildren`. Rows paint Nerd Font folder and
  file glyphs from `src/vs/workbench/browser/fileIcon.zig`: VS Code's SVG icon
  themes have no terminal image layer, so the Nerd Font glyph is the terminal
  adaptation of `workbench.iconTheme` (a Nerd Font must be configured in the
  terminal). Tree indent guides follow `workbench.tree.renderIndentGuides`
  (`none`, `onHover` or `always`; default `onHover`) and
  `workbench.tree.indent` is measured in cells (default 2, unlike upstream's
  pixel unit). The one-cell divider between the activity bar/side bar and the
  editor area is draggable: press and move to resize the side bar, clamped to
  half the window. `Ctrl-B` toggles the side panel
  and
  `Escape` returns focus to the editor. The generic VS Code list/tree view is
  being replaced in layers under `src/vs/base/browser/ui/list` and
  `src/vs/base/browser/ui/tree`: `rangeMap`, the virtualized `ListView`,
  `ListWidget`, the index/object tree models and a terminal `AbstractTree`.
  The Explorer now renders through that
  `CompressibleObjectTree`/`CompressedObjectTreeModel`/`AbstractTree` path.
  `ObjectTree`, `IndexTree`, a synchronous `DataTree` and the
  `CompressibleObjectTree` view adapter are also ported. Remaining work is the
  async data tree, file drag/drop inside the tree, sticky scroll, the
  compressed-label navigation controller (per-segment focus/hover) and
  identity-provider diffing through the object models. The side-bar divider is
  draggable; that is part-size resizing, not Explorer file drag/drop.
- The configuration service (`src/vs/workbench/services/configuration/browser/configurationService.zig`)
  resolves defaults, the VS Code profile's user settings, the terminal's own
  user settings, the workspace file's `settings` block and each folder's
  `.vscode/settings.json`, in that precedence order. It uses the ported
  `ConfigurationModel`/`ConfigurationRegistry` and accepts JSONC comments and
  trailing commas. The profile layer is the VS Code stable `User` directory
  (`~/Library/Application Support/Code/User` on macOS, `~/.config/Code/User` on
  Linux, `%APPDATA%\Code\User` on Windows). There is no environment override,
  matching upstream. The terminal layer is the TUI profile's
  `<user-data-dir>/User/settings.json`, using upstream `userDataPath.ts`
  precedence: `VSCODE_PORTABLE` → `<portable>/user-data`, `VSCODE_APPDATA` →
  `<appdata>/vscode-textbuffer`, `--user-data-dir <dir>`, then the platform
  application-data directory (`~/Library/Application Support/vscode-textbuffer`,
  `$XDG_CONFIG_HOME/vscode-textbuffer`, `%APPDATA%\vscode-textbuffer`).
  `src/tui/vscodeProfile.zig` owns the discovery. The TUI watches every user
  layer, the workspace file, each folder's `.vscode/settings.json` and the
  keybinding files, and reloads automatically. "Preferences: Open User Settings
  (JSON)" in the command palette opens the terminal layer and creates it when
  missing. Not ported:
  - `updateValue` and settings editing through the configuration service (the
    JSON file is edited directly);
  - policy, application, remote and profile scopes (those services do not exist
    in the terminal workbench);
  - trusted-workspace filtering and restricted settings (no workspace-trust
    service);
  - the Settings editor/view, and with it the activity-bar gear's Settings
    entry. Language override blocks such as `[typescript]` resolve through
    `getValue(..., override_identifier)` but are not projected by a Settings
    UI.
- Color themes are discovered from the pinned `theme-defaults` extension (all
  ten built-in themes), then the VS Code profile's extensions folder (later
  roots win for duplicate theme ids). `src/tui/vscodeProfile.zig` resolves the
  extensions path with upstream's `--extensions-dir`/`VSCODE_EXTENSIONS`/
  `VSCODE_PORTABLE` behavior and `extensionsRegistry.scanThemes` parses only
  `contributes.themes`, so installed languages/grammars are not pulled in. The
  setting value is the contributed theme `id` (falling back to its label) and
  `workbench.colorTheme` defaults to `Dark 2026`; the preferred dark/light/HC
  theme settings and `migrateThemeSettingsId` legacy ids are honored.
  `ThemeService` loads JSONC themes and `include` chains from the extension
  root, applies `workbench.colorCustomizations` (flat and `[theme]`-scoped),
  `editor.tokenColorCustomizations` (`textMateRules`, flat and theme-scoped) and
  the flat semantic rule map, and fires a change event. The TUI rebuilds the
  token theme from the active `ColorThemeData`, so syntax colors switch live
  when the settings file is saved. `src/vs/workbench/browser/themeColors.zig`
  resolves color ids to terminal cells (alpha composited over
  `editor.background`, with the previous literal as fallback); the editor
  current-line highlight is wired through it. The remaining UI chrome
  (status bar, tabs, activity bar, side bar view contents, search/SCM,
  terminal panel, quick picker, markdown preview) still uses the original
  terminal palette and is the remaining full-UI theming work; the side bar
  title/header/footer rows now resolve `sideBarTitle.*` and
  `activityBarTop.*`. Icon themes and the Color Theme picker are not ported.
  The terminal host reports a dark scheme for
  `window.autoDetectColorScheme` (no portable OS color-scheme API). Without the
  `vscode/` submodule the built-in theme files are unavailable; the workbench
  keeps the `vs-dark` fallback entry active and installs the bundled Dark+
  syntax theme through the legacy loader.
- User keybindings are read from the VS Code profile's `keybindings.json` and
  then the TUI profile's `<user-data-dir>/User/keybindings.json` (later entries
  win). Use the upstream `--user-data-dir <dir>` switch to relocate the TUI
  profile; "Preferences: Open Keyboard Shortcuts (JSON)" opens its file. The ported
  `KeybindingParser`/`keybindingIO` read the upstream array format (JSONC,
  platform `key` variants, chords, `when`, `args`, `systemWide` and
  `-command` removals), and the resolved items are passed to the workbench
  keybinding hosts: user bindings resolve before defaults, removals subtract
  the matching default rules from the global, tab, status-bar, search and
  editor-shortcut hosts. The shared `ContextKeyService` sets the focus keys
  (`editorTextFocus`, `editorFocus`, `listFocus`, `inputFocus`, `sideBarFocus`,
  `statusBarFocus`, `terminalFocus`, `inQuickOpen`, `inFilesPicker`, the
  Explorer/Search/SCM viewlet keys and a small `resourceScheme`/read-only set);
  unknown keys stay undefined and therefore false. User items whose command is
  not registered in the terminal's command table are ignored with a log entry
  instead of swallowing the key, a documented terminal deviation from VS Code's
  command-not-found error. The file is watched and the hosts rebuild on change.
  Not ported: extension-contributed `contributes.keybindings`, the Keyboard
  Shortcuts editor, `keyboard.dispatch`/layout settings, command arguments
  consumed by commands (they are parsed and carried on the item only). The
  VS Code `list.*` navigation ids are registered as a small bridge that
  synthesizes the corresponding list navigation for the focused Explorer,
  Search or Source Control view (`focusUp/Down/First/Last/PageUp/PageDown`,
  `collapse`, `expand`, `toggleExpand`, `select`); Explorer file-operation
  commands (rename/delete/copy/cut/paste/new file/folder) remain unported and
  are filtered as unknown.
- The file watcher (`src/vs/platform/files/...`) ports the VS Code service and
  the Linux/macOS/Windows backends: `common/files.zig` and
  `common/watcher.zig` for change/request contracts, coalescing, pattern
  normalization and filters; `baseWatcher.zig` for correlation,
  suspend/resume and retry; `parcelWatcher.zig` plus the in-tree
  `parcel/watcherLib` for recursive watching; `nodejsWatcherLib.zig` for
  non-recursive watching; and `watcher.zig`/`watcherStats.zig` for the
  universal watcher and diagnostics. The Linux backend uses inotify, macOS
  uses the ported FSEvents backend for recursive requests and kqueue for
  non-recursive requests (kqueue remains the cross-compile fallback), and
  Windows uses overlapped `ReadDirectoryChangesW`. Brute-force
  snapshot polling backs the polling mode. The `@parcel/watcher` N-API binding,
  JS wrapper, prebuilds and Electron IPC watcher clients are not ported. The
  terminal uses `UniversalWatcherClient`, a worker-thread adaptation of
  upstream's watcher process; `WorkspaceWatcher` (port of
  `src/vs/workbench/contrib/files/browser/workspaceWatcher.ts`) owns the
  `files.watcherExclude`/`files.watcherInclude` requests and is instantiated in
  the `AfterRestored` phase. The workspace watcher reloads clean open editors
  and marks SCM dirty; Explorer and Search still do not refresh on external
  changes. The settings watcher remains an in-process non-recursive
  `UniversalWatcher` owned by
  `src/vs/workbench/services/configuration/browser/configurationService.zig`,
  and `src/tui/app.zig` polls its fd alongside stdin.
  `zig build test-watcher -Dwatcher-only=true` runs the watcher-only suite;
  `zig build check-watcher -Dwatcher-only=true -Dtarget=x86_64-windows` and
  `zig build check-watcher -Dwatcher-only=true -Dtarget=aarch64-macos` type-check the other
  platform backends without the POSIX TUI.
- The activity bar is split into the ported model
  (`src/vs/workbench/browser/parts/activitybar/activitybarPart.zig`), the
  activity service model
  (`src/vs/workbench/services/activity/browser/activityService.zig`) and the
  terminal view (`src/vs/workbench/browser/parts/activitybar/activitybarPart.zig`). The Search activity shows a badge
  dot while matches are present (the exact count is in the panel); the service
  also supports view and global badges. It
  switches between the Explorer, Search and Source Control containers;
  Explorer is wired to the file tree, Search to the workspace text-search
  panel and Source Control to the git SCM view. `Alt-1..3` switches containers
  while the side panel has focus. There is no Settings container: upstream's
  Settings entry is the `workbench.actions.manage` activity-bar gear, an
  action whose Settings item opens the Settings editor as an editor tab, not a
  view container. The port has no Settings editor, so settings are edited
  through the `Open User Settings (JSON)` command.
  The model owns order, visibility, the active container and compact width.
  Containers are registered in the ported view-container registry
  (`src/vs/workbench/common/views.zig`), but there is still no extension
  contribution point, live Explorer/Search file-change integration, context
  menu or drag-and-drop.
  `workbench.activityBar.location` (`default`/`top`/`bottom`/`hidden`),
  `workbench.activityBar.autoHide` and `workbench.activityBar.compact` are read
  from settings (workspace `.vscode/settings.json` or the user setting files).
  For `top`/`bottom` the rail is hidden and the activity items move into the
  side bar as a one-row icon composite bar in the header/footer. Closing the
  side bar (`Ctrl-B`) keeps the rail visible and clickable, so an activity
  entry reopens the side bar.
- The primary side bar is a ported pane-composite part
  (`src/vs/workbench/browser/parts/sidebar/sidebarPart.zig`), the same way as
  the bottom panel. The part owns the side bar width/position/visibility, the
  active viewlet, the `EXPLORER`/`SEARCH`/`SOURCE CONTROL` title row and its
  toolbar actions; the row is built with the `ui` DOM (`Document` painted
  through a `Surface`) exactly like the panel title, and the view pane
  containers render below it without their own section headers. The Search
  title toolbar runs `Clear Search Results` (`x`) and `Toggle Search Details`
  (`…`); the Explorer's New File/New Folder/Refresh/Collapse All actions and
  the SCM provider refresh action are not ported as commands (SCM keeps its
  `r` key). `Ctrl-0` focuses the side bar,
  `workbench.action.closeSidebar` closes it,
  `workbench.action.toggleSidebarVisibility` toggles it and
  `workbench.action.previousSideBarView`/`nextSideBarView` cycle the visible
  containers. Not ported: view title context menus, the title toolbar's
  overflow/"More Actions" menu, `focusActivityBar` (the rail has no keyboard
  focus model), `workbench.activityBar.iconClickBehavior`,
  the toggle-activity-bar-visibility action (the configuration service has no
  `updateValue`), the right-hand side bar position, the
  `workbench.sidebar.activeviewletid` workbench-storage persistence, boundary
  sash classes and the active viewlet's optimal width (the terminal keeps the
  configured width).
- The bottom panel is a ported pane-composite part
  (`src/vs/workbench/browser/parts/panel/panelPart.zig`) with a one-row
  composite bar. Problems and Terminal are registered at the upstream
  `ViewContainerLocation.Panel` (`markers.contribution.ts` order 0,
  `terminal.contribution.ts` order 3), so Problems opens as a panel tab next
  to the terminal, not as a side-bar view. `Ctrl-J` toggles the panel,
  `Ctrl-Shift-M` opens/focuses Problems and `Alt-Shift-T` toggles the
  terminal container. `hideIfEmpty` containers keep their tab while active and
  drop it again once empty. Panel position (top/left/right), floating panels,
  alignment, maximize and the overflow switcher are not ported.
- Source Control is a read-only Git/SCM port. `src/extensions/git/src/git.zig` implements
  the ported `IGitExtensionDelegate` over the Git command line (argv, never a
  shell; explicit cwd; bounded stdout/stderr; per-command deadline), and
  `src/vs/workbench/contrib/git/{common,browser}/gitService.zig` keep the
  upstream repository state/ref/diff/commit contract. The terminal provider
  (`src/extensions/git/src/repository.zig`) exposes the upstream `Merge Changes`,
  `Staged Changes` and `Changes` groups (untracked files mixed into `Changes`,
  matching `git.untrackedChanges=mixed`), v2 status letters, rename/delete and
  unmerged entries, and registers primary (`working ↔ index`) and secondary
  (`index ↔ HEAD`) quick-diff providers. The SCM sidebar
  (`src/vs/workbench/contrib/scm/browser/scmViewPane.zig`) shows `SOURCE CONTROL`, a repository/branch row,
  group counts and relative-path resource rows. `Up`/`Down` select, `Enter` or
  a click opens the change, `r` refreshes and `Escape` returns to the editor.
  Resource groups collapse/expand with the header click, `Left`/`Right` or
  `Space`. The branch/count status entry (`⎇ branch ↑n ↓m (count)`) opens the
  SCM view, and the activity badge follows `scm.countBadge`
  (`all`/`focused`/`off`). There is no extension-host SCM actor, so `vscode.git`
  is replaced by the CLI delegate and the mirrored
  `src/extensions/git/src/historyProvider.zig`.
- The Source Control Graph (`workbench.scm.history`) is a second section of the
  SCM container. `src/vs/workbench/contrib/scm/browser/scmHistory.zig` ports the
  swimlane/color/reference/view-model generation, and `scmHistoryViewPane.zig`
  renders it on the `ui` DOM: one cell per swimlane, commit subjects/authors,
  ref badges, `●`/`◉`/`◎`/`◌` circles and `│`/`╱`/`╲`/`─` lanes. Commits start
  collapsed; expanding shows changed files in list or compressed tree mode;
  `Enter` opens a parent↔commit diff. `scm.graph.pageSize` (50),
  `scm.graph.pageOnScroll` (true), `scm.graph.badges` (`filter`),
  `scm.graph.showIncomingChanges`/`showOutgoingChanges` (true),
  `scm.defaultViewMode` (`list`), `scm.compactFolders` (true) and
  `git.commitShortHashLength` (7) are honored. The title actions select
  All/Auto/one history-item reference, reveal the current commit, refresh and
  toggle list/tree; background ref changes while scrolled show "Outdated".
  View sections are 1-row headers split into weighted bodies (Changes/Graph
  40/40); with one visible view the header merges into the container title.
  Not ported: multi-diff "Open Changes" for a whole commit (only per-file
  diffs), context menus, drag/drop, chat, clipboard copy actions and Git write
  operations (checkout/cherry-pick/push/publish); the ref picker is
  single-select instead of upstream's multi-select; one repository per
  workspace so the repository picker is hidden; hover is plain text without
  avatars/markdown/command links; page fetches are capped at 20 per call.
  Staging, committing, discarding, the SCM input box, multi-repository
  selection and artifacts remain unported.
- Quick diff is applied as `TextModel` decorations with the upstream
  `dirty-diff-*` classes: whole-line added/modified/deleted ranges, the
  one-cell gutter marker (`+`/`~`/`-`, primary/secondary/pattern variants
  dimmed) and overview-ruler entries. `src/tui/quickDiffController.zig`
  attaches a `QuickDiffModel`/`QuickDiffDecorator` per file editor, skips diff
  tabs, recomputes on model version change (200 ms debounce driven by the main
  loop) and on git status changes, and honors `scm.diffDecorations`,
  `scm.diffDecorationsIgnoreTrimWhitespace` (including `inherit`) and
  `scm.diffDecorationsGutterPattern`. `Alt-Down`/`Alt-Up` navigate changes
  (TUI-specific because a normal terminal cannot deliver F5/F7).
- The diff editor view (`src/vs/editor/browser/widget/diffEditor/` plus
  `src/vs/workbench/browser/parts/editor/textDiffEditor.zig`) opens a read-only
  side-by-side comparison from a changed SCM resource. Both sides are
  **aligned display snapshots**: `diffEditorViewZones.zig` pads changed blocks
  with `diff-filler` rows so the two panes have equal line counts and scroll in
  lockstep; `diffEditorDecorations.zig` paints `line-insert`/`line-delete`,
  `char-insert`/`char-delete` and the fillers; the center gutter shows
  `│`/`+`/`~`/`-` and highlights the current block; dragging it resizes the
  panes. Diffs cover `HEAD ↔ working tree`, `HEAD ↔ index` and
  `index ↔ working tree` (untracked = empty ↔ working, deleted = working side
  empty); title labels name both refs. `Alt-Down`/`Alt-Up` navigate,
  `workbench.action.compareEditor.swapSides` swaps panes and
  `refreshDiff` re-snapshots. Binary, invalid-UTF-8 and oversized files are
  skipped with an empty side; a missing git binary, `git.enabled=false` or a
  non-repository leaves the editor untouched. Diff tabs are read-only: save,
  revert, reload and external-change handling are inert, they are not working
  copies, history entries or session-serialized, and closing them returns to
  the untouched file tab. Terminal limitations: no inline diff mode, hidden
  unchanged regions, moved-block lines, quick-diff peek, multi-diff editor,
  accessible diff viewer, or editing either side; the original pane is not
  keyboard-focusable; the combined two-lane overview ruler is per-side; the
  gutter width/pattern/minimap settings are reduced to one marker cell and a
  dimmed pattern; panes narrower than 50 cells fall back to a modified-only
  view without the gutter or original pane; and only one repository per
  workspace folder is shown.
- The Search panel is a terminal adapter (`src/vs/workbench/contrib/search/browser/searchViewTerminal.zig` and
  `src/vs/workbench/contrib/search/browser/searchWidget.zig`) over the upstream-shaped portable view:
  `src/vs/workbench/contrib/search/browser/searchView.zig` owns the query
  lifecycle, messages, focus state and replace flow;
  `searchResultsView.zig` owns the data source, ordering, row labels and
  accessibility labels; `searchCompare.zig` ports the comparers;
  `searchActionsBase.zig`, `searchActionsNav.zig`, `searchActionsTopBar.zig`
  and `searchActionsRemoveReplace.zig` hold the action helpers/runners; and
  `src/vs/workbench/services/search/common/queryBuilder.zig` builds the text
  query. `Alt-F` opens the panel (Ctrl-Shift-F is indistinguishable from Ctrl-F
  in a normal terminal), `Ctrl-R` toggles the replace row (hidden by
  default, as upstream), `Alt-D` toggles the files-to-include/exclude rows, and `Tab`/`Ctrl-Down`/`Ctrl-Up` cycle inputs.
  Matching options are `Alt-C` (case), `Alt-W` (whole word), `Alt-R` (regex)
  and `Alt-P` (preserve case). `Enter` opens a match or toggles a folder/file;
  `Left`/`Right` collapse/expand; `Delete` dismisses; `Alt-Enter` replaces the
  selection; `Ctrl-Alt-Enter` shows the upstream replace-all confirmation and a
  second invocation performs it; `Escape` cancels an active search before
  leaving the panel. Results stream incrementally and follow
  `search.defaultViewMode` (list by default), `search.sortOrder` (`modified`
  falls back to path order because the terminal search service does not collect
  file stats), `search.collapseResults` and `search.showLineNumbers`; a single
  workspace root is transparent and list mode flattens files, matching
  upstream. The
  result count and empty/limit messages use upstream grammar.
  `files.exclude` and `search.exclude` are honored through
  `src/vs/workbench/services/search/common/search.zig` and the ported glob
  expression, including `false` entries, `!` exceptions and `{ when: ... }`
  sibling clauses; `search.useIgnoreFiles`, `useParentIgnoreFiles`,
  `useGlobalIgnoreFiles` and `search.followSymlinks` are read by the query
  builder. Workspace files are searched by `rg --json`
  (`src/vs/workbench/services/search/node/ripgrepTextSearchEngine.zig` and
  `textSearchWorker.zig`): one bounded worker streams matches from each
  workspace folder while the event loop stays responsive, and open/dirty editor
  buffers are searched synchronously with the editor matcher and suppress the
  stale on-disk result for the same path. `rg` must be installed and on `PATH`;
  a missing binary is reported in the panel. `surroundingContext` /
  `ITextSearchContext` rows are collected by the parser and stored on
  `FileMatch` (the pinned upstream Search view also keeps them as file-match
  data rather than separate tree rows). `.gitignore`/`.ignore`, binary files,
  oversized files and symlinks are left to ripgrep (plus the same 10 MB guard
  for open buffers). Not ported: explicit `files.encoding` conversion,
  extension-provider/remote text search, AI/notebook/search-editor results,
  only-open-editors and SCM changed-files modes, multi-selection, context
  menus, drag/drop, clipboard actions, search history and view-state
  persistence, compressed folder chains, and `./`/absolute search-path
  expansion or per-folder settings. PCRE2-specific patterns require an `rg`
  built with PCRE2, and the AST-level `fixRegexNewline` rewrites are not
  ported. Workspace folders are searched sequentially, not in parallel. The
  filesystem is not watched; edits to the active editor schedule a debounced
  re-search instead.
- Folder opening follows the workspace model: a directory argument stat'd from
  the CLI becomes a `Workspace` folder through
  `src/vs/platform/workspace/common/workspace.zig` and
  `src/vs/workbench/services/workspaces/common/workspaceContextService.zig`.
  `ExplorerModel` builds its roots from `getWorkspace().folders`, so opening a
  folder shows that folder as the Explorer root and starts with an empty
  editor group; files on the command line still open as tabs. Opening only
  files uses an empty workspace, as upstream does.
- The editor is rendered through the library (`src/tui/editorView.zig`): text,
  syntax colors, `marginClassName` gutter row tints and marker-cell glyphs for
  the known diff/edit/comment line classes (the marker cell is reserved while
  such a decoration exists), glyph-margin glyphs (compacted 1-3 cell lanes with a themed
  `●`/`▲` mapping for the known glyph classes, reserved only while a glyph
  decoration exists),
  right-aligned line numbers (inactive/active colors from
  `editorLineNumber.*`; the column follows `editor.lineNumbers`,
  `editor.lineNumbersMinChars` and the digit count), wrapped-line markers,
  `renderLineHighlight: gutter|all`, focus-only highlighting via the forwarded
  editor focus, selections
  (the theme `editor.selectionBackground` with dimmed covered text), the current
  line and a hardware cursor. The workbench status bar is a
  full-width bottom row built from the ported
  `StatusbarModel`/`StatusbarPart`/`StatusbarService`
  (`src/vs/workbench/browser/parts/statusbar/`) and the ported editor-status
  controller (`src/vs/workbench/browser/parts/editor/editorStatus.zig`):
  entries use upstream alignment/priority/compact rules and resolve the
  `statusBarItem.*` kind/hover colors (including the compact-group hover pair),
  the bar builds a one-row flex `ui` surface
  (left items grow and right items are row-reverse), and the right side
  shows selection, indentation, encoding, EOL and language. Clicking an entry
  focuses it and runs its command: selection opens Go to Line/Column, and the
  other values open the indentation, encoding, EOL and language pickers
  through the ported quick-input service
  (`src/vs/platform/quickinput/browser/quickInputService.zig`).
  Arrow keys, Home/End, Enter/Space and Escape navigate while focused,
  `Ctrl-Alt-S` toggles editor/status focus, and the `Focus Status Bar` command
  is in the palette.
  The workbench uses its status-bar part; the editor view no longer renders a
  built-in fallback status string. The read-only preview supplies its own status
  row text through `setStatusText`. The bar's terminal adaptations are documented in
  `docs/terminal-ui.md`: codicons are plain text, text ellipsis is
  pre-truncation, focus is an underline, the tooltip is plain text, hidden
  entry state is in memory; Escape dismisses the hover tooltip, a right-click
  opens the hide/manage-extension actions through the quick pick, while the browser's other context-menu and
  auxiliary parts are not ported. The
  `zig build run -- --preview <file>` read-only mode uses the same token
  renderer and adds Up/Down, PageUp/PageDown, Home, End and mouse-wheel
  scrolling; Ctrl-Q quits. Overlay widgets and a single-line terminal input box
  (`ui/inputbox.zig`) are in place, and the find bar is wired: Ctrl-F opens
  find (a single-line selection seeds the query), Ctrl-R opens the replace row,
  Enter/Shift-Enter go to the next/previous match, Escape closes, Tab switches
  between the find and replace inputs, Alt-C/Alt-W/Alt-R toggle match case,
  whole word and regex, Alt-P toggles preserve case, Alt-L limits the search to
  the current selection(s), Alt-Enter selects all matches, and Ctrl-Alt-Enter
  replaces all. The bar shows clickable replace-toggle, previous, next, close,
  match position/count, `Aa`/`ab`/`.*`/`Sel`, preserve-case, replace-one and
  replace-all controls (clicks do not take focus; the keyboard keeps its key
  map), and its bar/input/toggle colors resolve the `editorWidget.*`,
  `input.*` and `inputOption.*` theme ids (the terminal fallback keeps the dark
  defaults). The browser sash, find widget view zone, input history and
  accessibility tree are not ported. The
  find, search and quick-open inputs share the completed `InputBox` editing
  behavior: Shift selection, Ctrl-A, word-wise movement/deletion, undo/redo,
  mouse drag selection and caret-follow horizontal scrolling.
- Quick open is wired through `src/vs/workbench/browser/quickaccess.zig`: `Ctrl-P` opens
  "Go to File" with recent editors first and workspace files as the query is
  typed, and typing `>` switches to the command selector. The command selector
  is also bound to `Alt-P` because a plain terminal reports `Ctrl-Shift-P` as
  `Ctrl-P`; the action metadata keeps the upstream command ids and labels.
  Ctrl-N/Ctrl-P select the next/previous item (the terminal form of the macOS
  quick-pick bindings), Up/Down and PageUp/PageDown move by one or a page,
  Ctrl-Home/Ctrl-End jump to the ends, Enter accepts, Escape or
  an outside click closes, the wheel scrolls the list, and clicking a row
  accepts it. Go to File is backed by `rg --files`, like upstream's
  `ISearchService.fileSearch`: opening the picker starts one listing per
  session, honors `files.exclude` and `search.exclude`, `.gitignore`/`.ignore`,
  `search.useIgnoreFiles`/`useParentIgnoreFiles`/`useGlobalIgnoreFiles`, and
  `search.followSymlinks`. The listing and filter/sort work run on a background
  worker thread; keystrokes never walk or score the checkout on the event-loop
  thread, and the cached raw paths serve every later keystroke in that session.
  Results are capped at 512 per query (200,000 cached paths per session), and
  matching uses the ported `fuzzyScorer.scoreItemFuzzy`
  label/description/path scorer, including its path-identity, label-prefix and
  match-compactness boosts (Unicode words are scored per codepoint and word
  filters fold ASCII + Latin-1 case, so the emoji/UTF-8 highlight alignment from
  #113404 and the Japanese/Umlaut word cases match upstream); the scorer cache
  is not used by the picker. `rg` must be installed and on `PATH`; a missing
  binary is reported in the picker instead of hanging. macOS Unicode
  normalization and the bundled `@vscode/ripgrep-universal` download are not
  ported. Text search in the Search view is ripgrep-backed too; see the Search
  panel paragraph above.
  Symbol (`@`), go-to-line
  (`:`), link and help providers, absolute/relative path queries, open-to-side,
  icons, quick-input buttons and keybinding labels are not ported. Command
  history is in memory for the session.
- Mouse input is wired through the library: SGR reports in mode 1003/1006 become
  `ui.MouseEvent`s, `Surface.elementFromPoint` hit-tests the box tree, and a
  press focuses the element under the cell. In the editor, left-click places the
  caret, Shift-click extends, dragging selects (a selecting drag is not a
  click), the wheel scrolls three view lines without moving the caret, and the
  right-edge overview-ruler/scrollbar column accepts click and thumb drags.
  Idle motion drives hover in the find bar: the option toggles and `All`
  highlight, clicking them runs the action without stealing input focus, and
  clicking an input places its byte caret. Clicking the editor blurs the find
  bar so the keyboard returns to the editor. Double-click, context menus and
  horizontal scrolling are not wired.
- Keyboard events and focus are library features: nodes take listeners, the
  active element receives keys, and Tab/Shift-Tab move through focusable nodes
  (`Element.focusable` / `Element.tab_index`). See `ui/README.md` and
  `docs/terminal-ui.md` §4.4.
- The library's tests are part of `zig build test`; when working inside `ui/`,
  `cd ui && zig build test` runs them directly. Examples live in `ui/examples/`
  and are all fullscreen. They install a `SIGWINCH` self-pipe and resize their
  surface and scene when the terminal viewport changes. `cd ui && zig build examples` opens the gallery with a
  side navigation menu; individual steps (`example-hello`, `example-list`,
  `example-overflow`, `example-focus`, `example-mouse`, `example-mouse-events`,
  `example-todo`) still run one scene directly.

Tokenizer status:

- The syntax-tokenizer stack from `vscode/src/vs/editor/common/model/tokens`
  and `textModelTokens.ts` is ported and wired into `TextModel`:
  tokenizer state tracking, incremental edits, background tokenization,
  attached views, token events, language switching, semantic-token overlays,
  and `getWordAtPosition`/`getWordUntilPosition`.
- Ported tests: upstream `lineTokens.test.ts`, `tokensStore.test.ts`,
  `model.modes.test.ts`, and the default-word cases from `model.test.ts`.
  The threaded path is covered by
  `workbench/services/textMate/test/browser/backgroundTokenization.test.zig`
  and the `MonotonousIndexTransformer` port tests.

Bracket-pair colorization:

- Bracket pairs are parsed by the ported 2-3 tree AST
  (`src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/bracketPairsTree.zig`): compact lengths, dense immutable
  bracket-id sets, bracket tokenizer, parser, and text/bracket/pair/invalid/list
  nodes.
- Edits are mapped through `beforeEditPositionMapper`, combined across queued
  changes, and parsed incrementally using `nodeReader` subtree reuse. The
  parser falls back to a full rebuild when no reusable node is available.
- `TextModel.bracketPairs()` exposes `getBracketPairsInRange`,
  `getBracketsInRange`, matching/enclosing/navigation helpers, and
  unmatched-closing detection. The upstream non-AST fallback matcher is ported
  as well; the TUI uses it when bracket-pair colorization is disabled. The AST
  is built for the visible bracket guides and colorization and is deferred for
  large documents.
- `ColorizedBracketPairsDecorationProvider` turns colorized brackets into
  `bracket-highlighting-N` / `unexpected-closing-bracket` decorations, honoring
  `bracketPairColorizationOptions`. The view resolves them before decorations,
  and the AST's change event invalidates the resolved decoration cache. A dirty
  AST produces no colorization decorations, so a paint never triggers a
  whole-document parse.
- Colorization is enabled by default, matching
  `EDITOR_MODEL_DEFAULTS`/upstream. `editor.bracketPairColorization.enabled` and
  `editor.bracketPairColorization.independentColorPoolPerBracketType` are read
  from settings. The TUI paint boundary maps `bracket-highlighting-N` to
  `editorBracketHighlight.foreground1..6`, skipping transparent/missing entries
  and cycling the rest exactly like upstream's theme participant; unmatched
  closing brackets use
  `editorBracketHighlight.unexpectedBracket.foreground`. When the active theme
  does not define the ids (the default themes do not), the scheme-specific
  upstream defaults are used.
- Small documents (at most 500 lines) are tokenized eagerly for the first AST so
  strings/comments are respected immediately. Larger documents start from
  upstream's fast initial tree and are rebuilt token-aware when the background
  tokenizer completes. Content edits and retokenized line ranges are queued as
  same-length edits for the incremental parser, like upstream.
- Language configurations are registered on `LanguageService` with
  `registerLanguageConfiguration` and promoted on first use into the ported
  `LanguageConfigurationRegistry`, which implements upstream priority merging,
  the default `plaintext` contribution and change invalidation.
- `LanguageService` also carries the language registry: id/alias/mimetype
  contributions (generated `text/x-<id>` mimetypes, first-mimetype-wins),
  extension/filename/filename-pattern and first-line detection, sorted
  language names, and `createById`/`createByMimeType`/`createByFilepathOrFirstLine`
  selections that re-emit when languages are registered. The TUI editor
  registers its bundled language table (extensions per language) on the service
  at startup and resolves file paths through the ported language associations
  (the old hard-coded extension map is gone). `workbench/services/language/common/languageService.zig`
  ports the workbench registration surface, including `files.associations` →
  configured associations. The TUI workbench feeds `files.associations` into
  every opened editor (re-detecting the language and rebuilding comment/bracket
  support) and re-applies it after a settings reload.
- The language-support helpers are ported: rich bracket grouping and
  forward/reversed bracket search (`RichEditBrackets`, `BracketsUtils`),
  `ScopedLineTokens`, electric-character matching, and `OnEnterSupport`
  (`languages/supports/onEnter.zig`, wired into the resolved language
  configuration with the upstream `onEnter.test.ts` cases). The resolved
  configuration also exposes `getBrackets`/`getElectricCharacter` backed by the
  ported `RichEditBrackets`/`BracketElectricCharacterSupport`.
- The TUI paints TextMate syntax colors for supported file extensions.
- Bracket-pair decorations remain model-level only; the TUI does not paint
  inline decoration classes yet.
- Not ported: tree-sitter tokenization, font-token annotations, and custom
  `wordPattern` language configurations.
- Background tokenization is ported from the upstream workbench path, not
  just the fallback: `ThreadedBackgroundTokenizerFactory` owns one dedicated
  worker thread, `TextMateWorkerTokenizerController` keeps the renderer state
  store and pending edits, and the worker streams serialized token blocks and
  state-stack deltas back with `std.Io.Queue` (the terminal stand-in for
  `postMessage`). The renderer applies deltas on its main loop and shares the
  compiled token theme with the worker through a read/write lock instead of
  upstream's serialized `$acceptTheme` copy. TUI startup
  enables it with `Workbench.enableAsyncTokenization`; tests keep the
  synchronous `DefaultBackgroundTokenizer` unless they opt in. The default
  tokenizer remains the fallback when async tokenization is disabled, the
  model is too large for syncing, or the tokenizer has no TextMate grammar.

View model:

- Ported the portable view-model decoration core: glyph-margin lane
  assignment, the coordinates-converter interface with its identity
  implementation, model-decoration visibility filtering, and the inline /
  injected-text decoration computers.
- The TUI uses a reduced port of `viewModelLines`: wrapped model-line
  projections, view-line prefix sums, view/model conversion, incremental line
  mapping, and hidden model-line ranges. Folding uses the hidden ranges to
  project a smaller view (see below); view zones, decorations, and the
  browser-facing `viewModelImpl` rendering stack are not ported. Indentation
  guides are ported separately at the model/view boundary (see below).

TextMate tokenization:

- Tokenization runs on the standalone `vscode_textmate` port in `textmate/`,
  wired through `ITokenizationSupport` in
  `src/vs/editor/common/model/tokens/textMateTokenizer.zig`. The old
  `textmate.zig` package dependency has been removed.
- Supported language IDs include `zig`, `json`, `javascript`,
  `typescript`, `python`, `rust`, `go`, `c`, `cpp`, `java`, `html`, `css`,
  `scss`, `markdown`, `yaml`, `toml`, and `shellscript`/`bash`.
- Languages that ship a grammar in the upstream checkout use VS Code's
  originals, embedded from `vscode/extensions/*/syntaxes/*.tmLanguage.json`
  at build time (`vscode-syntax`). `zig`, `toml` and `yaml` use vendored
  fallback grammars in `src/support/grammars` (the current VS Code YAML
  grammar does not tokenize with this parser), and `markdown` falls back to a
  vendored copy of its pinned VS Code grammar. The vendored Dark+ theme is the
  fallback when the `vscode/` submodule is not initialized.
- Language configurations for the same languages are read from each
  extension's upstream `language-configuration.json` and embedded by
  `vscode-syntax` too (JSON/JSONC have a vendored fallback in
  `src/support/languageConfigurations`). `src/vs/workbench/services/language/common/bundledLanguages.zig` only holds the
  terminal's built-in language-ID/extension table and the portable fallback
  used when no upstream configuration asset exists (for example Zig, or any
  language when the `vscode/` submodule is not initialized).
- Token colors come from VS Code's Dark+ theme
  (`theme-defaults/themes/dark_plus.json` and its `dark_vs.json` include).
  `TokenTheme` resolves the `tokenColors` rules (foreground and
  bold/italic/underline/strikethrough), and the TUI paints through the theme's
  color map. Markdown inline code and its backticks therefore use Dark+'s
  string color without a separate scope table. Token backgrounds are kept in
  the token metadata but the terminal view uses the workspace background.
- TextMate scopes still provide the standard token types (`comment`, `string`,
  `regexp`) used by bracket and language features.
- Markdown fenced blocks for every supported language are enabled by a small
  fence grammar (`src/support/markdownCodeFences.tmLanguage.json`), including
  aliases such as `js`, `ts`, `py`, `rs`, `yml`, `md`, `sh` and `c++`. VS
  Code's built-in fence list does not cover Zig or TOML.
- A faithful Zig port of `microsoft/vscode-textmate` lives in `textmate/`,
  with the reference checkout at the `vscode-textmate/` submodule. It covers
  the engine and all upstream test suites, including the first-mate/suite1 tokenization
  fixtures and all 14×72 theme fixtures. It is the editor's tokenizer and
  converts UTF-16 token boundaries to the editor's UTF-8 offsets at the
  adapter boundary. See `textmate/README.md` for the source map, UTF-16 index
  contract and porting notes.
- Theme selectors that combine a parent scope with a target (`a b`) or exclude
  a scope (`a - b`) are reduced to the target scope; the terminal theme trie
  matches one scope at a time.
- Languages without a TextMate mapping continue to use the null tokenizer.

Markdown:

- Hover markdown is parsed by the pinned `taggon/markdown-zig` package
  (commit `85bcc67`, MIT), a CommonMark + GFM parser that produces mdast. The
  terminal renderer in
  `src/vs/editor/common/markdown/markdownTerminalRenderer.zig` maps that
  tree to styles and cells: paragraphs, headings, nested/ordered/task lists,
  block quotes, fenced and indented code, thematic breaks, GFM tables,
  emphasis, strikethrough, inline code, links/autolinks and images. Fenced
  code blocks are tokenized with the same TextMate grammars as the editor; the
  fence info string resolves through common aliases (`js`, `ts`, `py`, `sh`,
  ...), a fence without a language falls back to the editor's language, and an
  unknown language renders as plain code. Code-block backgrounds resolve
  `textCodeBlock.background` from the active theme; when the theme does not
  define it, code spans stay transparent and the hover/preview surface shows
  through.
- Terminal substitutions: a link shows its text underlined and, when the URL
  differs, the URL in dim text because cells cannot open a link; hover images
  show their alt text; tables render as box-drawing grids with width-capped
  columns; raw HTML is dropped (there is no HTML sanitizer or renderer); one
  blank line separates sibling blocks in place of browser margins; tabs expand
  to four spaces. MDX, math and frontmatter are disabled; there is no clickable
  link support.

Markdown preview:

- `Markdown: Open Preview to the Side`, `Markdown: Toggle Preview`
  (`Ctrl-Shift-V`) and `Markdown: Refresh Preview` open a rendered preview
  beside the source in the active tab. The active Markdown editor also shows a
  two-cell `◫⌕` preview button at the right end of its tab row; clicking it
  toggles the split, and the icon is highlighted while the preview is open.
- The preview shares the terminal Markdown renderer and keeps VS Code's
  bidirectional scroll sync: `markdown.preview.scrollPreviewWithEditor`
  (editor to preview) and `markdown.preview.scrollEditorWithPreview` (preview
  wheel to editor) default to true. `markdown.preview.markEditorSelection`
  marks the cursor's block, and `markdown.preview.breaks` renders source soft
  breaks as rows. Timers use the same 300 ms refresh debounce, 50 ms throttles,
  and 50/200 ms scroll-suppression windows as `preview.ts`/`scroll-sync.ts`.
- Headings get GitHub-style anchors; clicking an internal `#fragment` link in
  the preview scrolls to that heading. The rendered block model carries source
  line ranges for the ported `scroll-sync` mapping, including multi-line code
  blocks.
- Local raster images render as image blocks through the same kitty
  Unicode-placeholder path as the image preview: PNG is sent unchanged and
  JPEG/GIF/BMP/TIFF are decoded by `zigimg`. Image reads/decodes and remote
  http(s) fetches run on the async Io; a missing, failed, `data:` or SVG image
  keeps its alt text, as does any image when the terminal has no placeholder
  support. Remote images use the ported request service (30 s deadline, 32 MiB
  body cap) and are fetched only while the preview is visible. Because a cell
  grid has no replaced inline element, an image occupies its own rows at the
  content left edge; text before and after continues on the surrounding rows.
- Terminal substitutions: the preview is a fixed 50/50 side pane rather than a
  webview; there is no HTML/CSS/script execution, external link opening,
  security selector, preview lock, in-place preview (`markdown.showPreview`),
  or `markdown.styles`/font/line-height setting. External links are not
  clickable and the `Ctrl-K V` chord is not bound (the command palette is
  available instead). Preview visibility and scroll are not serialized in
  sessions.

Image preview:

- Opening a file that matches the image preview pattern
  (`*.{jpg,jpe,jpeg,png,bmp,gif,ico,webp,avif,svg}`) creates a read-only image
  tab instead of loading binary content into a text buffer. `.svg` opens in the
  text editor because the terminal has no SVG rasterizer; an already-open image
  is reused, and image tabs are restored from `--session`.
- Images render with the kitty graphics protocol's Unicode placeholders
  (`U+10EEEE` plus row/column diacritics; the 24-bit image id is the cell
  foreground). The terminal is probed once at startup; kitty and Ghostty are
  recognized, using the 0.50+ feature query when available. Terminals without
  placeholder support keep a message and an **Open in Text Editor** button.
- PNG is transmitted as-is. JPEG, GIF (first frame), BMP and TIFF are decoded by
  the pinned `zigimg` package (commit `bbdbb86`, MIT) and re-encoded as PNG;
  WebP, AVIF and ICO report an unsupported format, LFS pointer files report the
  upstream message, and remote/`data:` resources are not fetched. Local image
  reads and decodes run on the async Io; the loading placeholder is replaced on
  the completion tick.
- Fit/zoom/scroll: click zooms in, Ctrl/Alt+click zooms out, Ctrl/Alt+wheel
  zooms and a plain wheel scrolls. `+`/`=`/`-`/`0` and
  arrows/PageUp/PageDown/Home/End are TUI-specific keyboard alternatives. The
  command palette exposes **Zoom In**, **Zoom Out**, **Select Zoom Level** and
  **Open in Text Editor**, and the status bar shows the zoom label, image
  dimensions and file size.
- Image files reload when they change on disk, keeping the current zoom and
  scroll. The current view state is not persisted across sessions. Opening a
  binary image in the text editor replaces invalid UTF-8 sequences with
  U+FFFD, so it cannot break the text model.
- Omitted or unsupported: clipboard image copy, image context menus, pinch
  zoom, browser scrollbars and pixelated rendering, remote/animated/video/audio
  previews, image diffs, SVG/WebP/AVIF/ICO rendering, images over 32 MiB or
  16 megapixels, and placements wider/taller than the 297-entry placeholder
  table. The terminal position lookup expects truecolor.


TUI editor:

- The app edits through `TextModel` (not `PieceTreeTextBuffer` directly) and uses
  the ported wrapping stack.
- Text soft-wraps at the terminal width. Wrapped continuation lines are indented
  (`WrappingIndent.Same`) and marked with an arrow in the gutter. The generic
  `ui` text engine (UAX #14, `white-space`, line fragments) wraps widget and
  prose text; editor line boxes stay `pre` so the view-model wrapping is not
  applied twice.
- `q` is ordinary text. Quit with `Ctrl-Q`; unsaved tabs open the save
  confirmation first. Save with `Ctrl-S`; undo/redo with `Ctrl-Z`/`Ctrl-Y`.
- Navigation: arrows, `Shift`+arrows for selection, `Ctrl`+left/right for words,
  `Home`/`End`, `Ctrl`+`Home`/`End` for buffer edges, `PageUp`/`PageDown`.
- Mouse: left-click places the caret, `Shift`-click extends, drag selects, and
  the wheel scrolls three view lines (the caret stays put until it moves).
  Resting the pointer on a word opens a hover after 300 ms (see the hover
  contribution below); moving over the gutter or status row closes it.
- Find, bracket, word and hover highlights are stored as `TextModel`
  decorations with upstream class names (`findMatch`, `currentFindMatch`,
  `bracket-match`, `wordHighlight*`, `hoverHighlight`) and overview-ruler
  colors/lanes. In the app, find/word/hover contributions receive a
  `View.ModelDecorationSink` that writes the `TextModel` directly; the bracket
  pass writes model decorations from the view. The view reads inline
  decorations through `getLineDecorations` and overview markers through
  `getOverviewRulerDecorations`, so edits track the ranges and all highlights
  share one z-order. The `View.set*` setters remain as test/compatibility
  wrappers.
- Rainbow bracket colorization is on by default: matching `{ }`, `[ ]` and
  `( )` pairs are painted by nesting level with the theme's
  `editorBracketHighlight.foreground1..6` colors, and an unmatched closing
  bracket is red. `editor.bracketPairColorization.enabled` turns it off.
- Indentation and bracket guides: a dim `│` is drawn at each indentation
  column of a line's leading whitespace, using the ported
  `common/model/guidesTextModelPart.zig` rules. Blank lines inherit the guide
  count from the surrounding content. Indentation guides cycle the
  `editorIndentGuide.background1..6` / `activeBackground1..6` pools (the
  deprecated unnumbered ids supply level 1); the default themes only define
  level 1, so indentation guides are a single gray, matching upstream.
  Vertical bracket-pair guides are computed from the existing bracket-pairs
  model and colored by nesting level: inactive guides use
  `editorBracketPairGuide.background1..6` or the same-level bracket-highlight
  color at 30% opacity, and the active pair uses
  `activeBackground1..6` or the full bracket-highlight color. That is why
  bracket guides are rainbow-tinted while indentation guides are not. The
  indentation scope around the caret and the bracket pair containing the caret
  are highlighted. Guides are only painted over leading whitespace or blank
  cells, so a guide never replaces a text glyph; horizontal guide segments are
  not painted. Flow uses the same solid `│` glyph for its indent whitespace
  mode.
- Scrollbar and overview ruler: the scrollbar is right-aligned and 1.5 cells
  wide: the right half of the first reserved cell plus the whole second cell.
  It uses foreground block glyphs, so it carries no background run at the
  terminal edge. Three half-cell marker lanes occupy that width: find matches
  use the left lane (right half of the first cell), word occurrences the
  center lane (left half of the second cell), bracket matches the right lane
  (right half of the second cell), and the current find match and cursors use
  the full 1.5-cell width. The cursor tick is half-height at the top of its
  row (`▝▀`), closer to the browser's two-pixel cursor line. The thumb is also
  1.5 cells wide and covers the markers on its rows. Its top and bottom edges
  are quantized to half cells:
  `▝▀` on an upper edge, `▗▄` on a lower edge, and `▐█` on a full row, using the
  unrounded slider position from `ScrollbarState`. Because
  a terminal has one row per cell, a row can represent many document lines:
  markers are quantized to rows and collisions use the upstream z-order
  (current find over find over bracket/word, cursors last). Clicking the track
  jumps the viewport and dragging the thumb scrolls; the caret does not move.
  Cells have no alpha, so the upstream translucent colors are composited over
  the dark background. The read-only `--preview` mode does not reserve this
  column. No minimap, pixel lanes, horizontal scrollbar or smooth scrolling.
- Editing: `Enter`, `Tab`/`Shift-Tab`, `Backspace`, `Delete`, bracketed paste.
- `Ctrl-A` selects all; `Escape` clears the selection.
- Smart select: `Shift-Alt-Right` expands and `Shift-Alt-Left` shrinks every
  selection through the subword, word, bracket, line and document ranges. The
  controller caches ranges per selection and invalidates them when the
  selections or model version change.
- In-place replace: `Alt-.` and `Alt-,` replace the value under the primary
  caret with the next/previous value in its value set (numbers, `true`/`false`
  and the access-modifier sets). The replaced range is underlined for 350 ms.
  Terminals cannot encode the upstream `Ctrl-Shift-Period`/`Ctrl-Shift-Comma`
  chords, so the TUI uses the Alt keys; the action metadata keeps the upstream
  keybindings.
- Line operations: `Alt-Up`/`Alt-Down` move the current line or selection,
  `Shift-Alt-Up`/`Shift-Alt-Down` copy it, and `Ctrl-L` expands the selection
  line by line.
- Comments: `Ctrl-/` toggles line comments and `Alt-/` toggles block comments
  for the languages the TUI recognizes. Unsupported languages report a status
  message.
- Bracket matching: `Ctrl-\` jumps to the matching/enclosing/next bracket,
  `Alt-B` selects to the bracket pair, and `Alt-Shift-B` removes the bracket
  pair around the cursor. While the cursor is on a bracket, that bracket and
  its match are highlighted (including across lines); the highlight disappears
  while a widget such as the find bar has focus. Typing or moving the cursor
  updates it immediately.
- Occurrences: the word under the caret (or a selection that stays inside one
  word) highlights every whole-word occurrence in the file. `Alt-N` and
  `Alt-Shift-N` jump to the next/previous occurrence. Highlights stop on edits,
  on a multi-line selection and while a widget has the keyboard; they return
  after the next cursor move.
- Bracket completion: typing an opening bracket inserts its closing bracket and
  places the cursor between them. Typing an existing closing bracket moves
  over it, and Backspace removes an auto-inserted pair.
- Indentation: `Tab`/`Shift-Tab` indent or outdent the selected lines;
  `Ctrl-]` indents lines; `Alt-R` reindents the selected line block and
  `Alt-Shift-R` reindents the whole buffer. `Enter` goes through the ported
  `autoIndent` path for languages whose upstream language configuration defines
  `indentationRules` (JSON/JSONC, JavaScript/TypeScript, C/C++, Java, Rust, Go,
  CSS/SCSS, HTML and YAML). Braces and brackets inside strings are ignored for
  JSON, and typing a matching closing bracket outdents the line. Languages
  without a ported upstream configuration (for example Zig) keep the caret's
  current indentation.
- Folding: the gutter reserves a control cell when `editor.folding` is on and
  `showFoldingControls` is not `never`; it shows `▾` for an expanded region and
  `▸` when collapsed (the `mouseover` mode keeps expanded controls hidden until
  hover, as upstream); clicking it toggles the region on that line. `Ctrl-Shift-[` /
  `Ctrl-Shift-]` fold/unfold at the caret, `Ctrl-K Ctrl-L` toggles,
  `Ctrl-K Ctrl-0` folds all and `Ctrl-K Ctrl-J` unfolds all. Collapsed regions
  hide their model lines and end the first visible line with `…`.
- Sticky scroll: enclosing outline scopes stay pinned in the first rows of the
  editor, above the text and below later overlays such as the find widget. Up
  to `min(25% of the visible text rows, editor.stickyScroll.maxLineCount)` rows
  are shown. The widget is a top-left overlay, so it covers the rows rather
  than shrinking the viewport; line heights are one cell. `defaultModel` uses
  document symbols first and falls back to indentation folding; the syntax
  folding provider is not ported. Clicking a sticky row moves the caret to its
  scope line, Shift-click reveals the line after the scope, and `▸`/`▾` toggles
  that folding region. `editor.action.toggleStickyScroll` and
  `editor.action.focusStickyScroll` are in the command palette; while focused,
  Up/Down select a row, Enter goes to it and Escape returns to the editor.
  The toggle is session-only because the TUI has no settings-write service.
  Model providers run synchronously on the UI thread; the 300 ms debounce
  coalesces edits but does not cancel an in-flight provider call.
  Terminal limits: no CSS border/shadow, no sub-row/partial scrolling (the
  header is not duplicated while its line is still the first visible row), no
  horizontal `scrollWithEditor` coupling, no context menu or go-to-definition
  from a sticky row, and no preview syntax folding provider.
- Multi-cursor: `Ctrl-Alt-Up`/`Ctrl-Alt-Down` add a cursor above/below,
  `Ctrl-D` adds the next occurrence of the selection, and `Alt-D` selects all
  occurrences. `Escape` removes secondary cursors before clearing a selection.
- Status messages clear on the next key press.
- Syntax colors come from the `TextModel` tokenization stack.

Editor contributions:

- `src/vs/editor/contrib/linesOperations` ports `CopyLinesCommand`,
  `MoveLinesCommand`, and `SortLinesCommand`, plus command-producing helpers for
  duplicate selection and trailing-whitespace trimming.
- `src/vs/editor/contrib/comment` ports `LineCommentCommand` and
  `BlockCommentCommand`. Comment rules for the TUI's languages live in
  `src/vs/workbench/services/language/common/bundledLanguages.zig`.
- `src/vs/editor/contrib/suggest` ports automatic completions: a 10 ms
  quick-suggest deadline, provider trigger characters, optional explicit `Ctrl-Space`,
  fuzzy filtering/ranking, a windowed content widget with keyboard/mouse
  selection and a scrollbar, synchronous `resolveCompletionItem` plus a
  documentation pane, commit characters, additional text edits, multi-cursor
  acceptance and deferred/async provider requests. Snippet items use the
  upstream-shaped `snippetParser`/`snippetSession` port: the full marker AST
  (text, placeholders, choices, variables/defaults, escaped characters, nested
  placeholders, regex transforms with options, format conditionals and case
  shorthands), `OneSnippet` placeholder decorations and groups, transform
  re-runs when leaving a placeholder, nested snippet merge, choice completion
  through the suggest widget, per-edit snippet templates, multi-cursor
  snippets, and model/file/time/workspace/comment/random/selection/clipboard
  variable resolvers. Overtyping capture is ported and wired through the app.
  Remaining host limits: the terminal has no clipboard service (clipboard text
  is supplied by the caller), workspace variables use the edited file's parent
  directory, time variables use UTC, Unicode case mapping is ASCII-only, and
  `SnippetController2`'s actions/context keys/undo-stop options and a full
  upstream snippet-session test suite adaptation are not ported.
  The default provider suggests document words; language providers use the
  same `CompletionItemProvider` interface.
- `src/vs/editor/contrib/hover` ports the content-hover contribution end to
  end: anchors and result filtering, the delayed hover operation
  (`hoverOperation.zig`, with injected deadline timers), the widget wrapper and
  controller (sticky grace period, hide on scroll/mouse leave/edit, modifier
  modes), the terminal content widget (bordered, sized and clamped to the text
  area, line scrolling with wheel/arrows/PageUp/PageDown/Home/End, click to
  focus, Escape to close), and the markdown participant. Hover contents are
  parsed by the pinned `taggon/markdown-zig` CommonMark + GFM parser (commit
  `85bcc67`, MIT) and rendered to styled cells by
  `markdownTerminalRenderer.zig`; tables, nested/task lists, setext and indented code, autolinks and reference
  links are supported. The hovered range is painted through the same
  `LineDecoration.filter`/`extractWrapped` path as find and bracket highlights
  (`hoverHighlight`). The app registers a TUI-local provider
  (`src/vs/editor/contrib/hover/browser/terminalHoverProvider.zig`) that reports the word, language and token type,
  because VS Code gets hover contents from language extensions. Not ported,
  each because the corresponding infrastructure has no terminal counterpart:
  marker/glyph/color-picker/inlay-hint hover participants (no marker service,
  glyph margin, color picker or inlay hints), hover verbosity actions (no
  command/keybinding service), the copy button (no clipboard plumbing),
  accessible hover views (no screen-reader/accessible-view service),
  horizontal scrolling, status-bar actions (the bar renders
  labels but no participant adds one), and a keyboard "show hover" command
  (no hover action is wired to the keybinding host yet). Hover over the empty area *after* a line needs
  sub-cell horizontal distances, so only a zero-cell distance (the first cell
  past the text) anchors a hover. Mouse leave is inferred from motion over the
  gutter, the status row or another widget; a pointer that leaves the terminal
  window without another event leaves the hover visible until the next input.
  A focused hover returns the keyboard to the editor with Tab, and Escape
  closes it. The read-only `--preview` mode does not wire the hover
  contribution.
- Auto-closing brackets are ported from
  `src/vs/editor/common/cursor/cursorTypeEditOperations.ts` into
  `src/vs/editor/common/cursor/autoClosing.zig`. Single-character bracket pairs
  are supported; quotes, comments, multi-character opening pairs, and the
  surrounding-selection path are not ported yet.
- `src/vs/editor/contrib/wordHighlighter` ports the word-occurrence
  contribution for the single-model TUI: cursor/selection tracking, the 50 ms
  run delay and `occurrencesHighlightDelay`, the textual whole-word provider,
  `wordHighlight`/`wordHighlightText`/`wordHighlightStrong` ranges painted
  through the same line-decoration path as the other highlights, and the
  next/previous navigation actions (bound to `Alt-N`/`Alt-Shift-N` because the
  terminal decoder has no F7). The ranges also contribute markers to the
  overview-ruler column. Language-feature providers, multi-file/notebook/diff
  highlighting, the accessible announcement, context keys and minimap
  decorations are not ported; the TUI always uses the textual provider. The
  `wordHighlighter` colors are composited from
  `editor.wordHighlightBackground`/`wordHighlightStrongBackground` because cells
  have no alpha.
- `src/vs/editor/contrib/bracketMatching` ports the controller logic: jump to
  bracket, select to bracket, remove brackets, and the cached bracket-match
  data used for visual highlighting. The TUI turns that data into model
  decorations and paints them through the ported `LineDecoration.filter` /
  `extractWrapped` path, the same route find ranges take; matches that use the
  with-overview-ruler mode also paint a marker in the overview-ruler column,
  while CSS decoration classes remain unpainted.
- `src/vs/editor/contrib/multicursor` ports cursor insertion above/below,
  cursors at line ends/top/bottom, occurrence search sessions, and
  add/move/select-all occurrence actions. The TUI renders secondary cursors and
  selections. Find-widget option integration, the selection highlighter
  contribution, and its decorations are not ported. Navigation now applies to
  every cursor in the collection.
- `src/vs/editor/contrib/indentation` ports the reindent edit generator,
  indent-utils, tab/space conversion commands, selected-line reindentation,
  detect-indentation, and indentation option changes. The quick-pick actions
  and the auto-indent-on-paste contribution are UI/paste-path specific and not
  ported yet.
- `src/vs/editor/contrib/lineSelection` and
  `src/vs/editor/contrib/insertFinalNewLine` are ported.
- `src/vs/editor/contrib/smartSelect` ports the word and bracket selection-range
  providers, the provider merge/filter/leading-trailing-whitespace logic, the
  selection-range cache and the expand/shrink action metadata. There is no
  generic language-feature registry in this port, so providers are passed
  explicitly and the TUI uses the bracket + word providers; the upstream suite
  is adapted to `TestModel`.
- `src/vs/editor/contrib/inPlaceReplace` ports the `InPlaceReplaceCommand` and
  the controller's value-set lookup. The browser editor-worker service is
  replaced by a direct call to the already-ported `BasicInplaceReplace`; the
  lookup is synchronous, so the upstream async `EditorState` validation is not
  needed. The TUI owns the timed decoration.
- Folding is ported through
  `foldingRanges` (range storage, parent lookup, collapse state, merge/sanitize),
  `indentRangeProvider` (indentation-based folding and marker handling),
  `foldingModel` (region state and collapse transitions),
  `hiddenRangeModel` (hidden-line ranges and selection adjustment), and the
  terminal-facing `folding` controller (range computation, collapse actions,
  gutter state). Range computation is scheduled through upstream's ~200 ms
  `Delayer` debounce on the main-loop tick; fold actions force it immediately.
  `ProjectedViewModelLines.setHiddenAreas` removes collapsed
  lines from the view projection, so view/model conversion, cursor movement,
  selection adjustment, wrapping and the scrollbar all see the folded view.
  The TUI gutter paints `▾`/`▸` in its last cell and handles the click; the
  editor binds the upstream fold/unfold/toggle/fold-all/unfold-all commands and
  registers them in the workbench command palette. Syntax folding providers,
  folding-decoration CSS classes, fold-imports-by-default, folding
  mementos/view state, manual folding-range actions and the
  goto-parent/previous/next-fold actions are not ported. Fold state survives
  edits on the folded line, but inserting or deleting lines above a collapsed
  region re-expands it because the TUI has no tracked folding decorations.
- Sticky scroll is ported from
  `src/vs/editor/contrib/stickyScroll/browser`: the sticky element/model tree,
  outline and indentation candidate providers, the candidate walker with hidden
  range filtering, the widget state and cell painting (line numbers, syntax
  colors, fold glyphs), and the controller events. `stickyScrollActions.zig`
  keeps the upstream action ids/metadata; the workbench registers the toggle
  and focus commands, and the widget handles the focused-row keys. Not ported:
  the syntax folding provider (no folding-range registry), outline provider-id
  preference, context menus, Ctrl/Cmd-click go-to-definition, browser hover
  definition underlining, embedded-editor peek styling, and CSS border/shadow.
  The model rebuild debounce coalesces upstream's 50 ms provider scheduler and
  300 ms model delayer into one 300 ms terminal scheduler ticked by the app.
- Cursor/editing contributions are ported at the portable command/model layer:
  `anchorSelect` (position anchor state and action metadata), `caretOperations`
  (`MoveCaretCommand` and action metadata), `cursorUndo` (cursor undo/redo
  stack), `wordOperations` (word movement and deletion commands),
  `wordPartOperations` (word-part movement and deletion), `clipboard`
  (in-memory copy metadata and action IDs), and `toggleTabFocusMode` (tab-focus
  state and action metadata). Browser clipboard integration, anchor
  decorations, selection-event wiring for cursor undo, and keybinding
  registration remain TUI/browser-specific and are not ported.
- `src/vs/editor/common/commands/commandRunner.zig` executes a batch of
  `ICommand`s, including multi-selection commands, and maps their resulting
  selections.
- The workbench editor-group model is ported at
  `src/vs/workbench/common/editor/editorGroupModel.zig` with an
  `EditorInput` base at `src/vs/workbench/common/editor/editorInput.zig`:
  ordered editors, MRU order, preview/pinned/sticky/transient state,
  multi-selection, close-next selection, lock, clone, and dirty/label/
  capability/will-dispose re-emission. The upstream `editorGroupModel.test.ts`
  cases for this behavior are ported.
- The editor-groups service and split layout are ported:
  `src/vs/workbench/services/editor/common/editorGroupsService.zig` provides
  group creation/removal, active-group MRU ordering, typed `openEditor`
  resolution with `revealIfOpen`/`revealIfVisible`/`ForceReveal`/`Singleton`,
  and multi-group serialization. The upstream editor-part layers are ported at
  `src/vs/workbench/browser/parts/editor/editorPart.zig` (group registry,
  oriented grid, branch demotion, sash resize), `editorGroupView.zig`
  (model-to-tab mapping, active tab, pane activation) and `editorPanes.zig`
  (active pane, page position, size constraints); `src/vs/workbench/browser/workbench.zig` is
  the terminal adapter that renders the split tree with a tab row per group
  and composites every pane into one frame. With cell borders each pane
  is outlined and the active pane's outline wins shared edges; the divider is
  a draggable sash, and a tab can be dragged into another pane or onto an edge
  to tile a new group. `Alt-\` splits horizontally, `Alt-Shift-\` vertically,
  `Ctrl-Alt-Left` / `Ctrl-Alt-Right` switch groups, and clicking a group
  activates it. A split moves the active tab into the new group (independent
  view state for one shared model still needs the model/view split).
- Serialization/restore is ported at the model and TUI boundaries:
  `src/vs/workbench/common/editor/editorFactory.zig` holds the editor
  serializer registry, `EditorGroupModel.serialize`/`deserialize` rebuilds the
  ordered group/MRU/preview/sticky state through registered serializers, and
  `src/vs/workbench/browser/parts/editor/editorSession.zig` stores the group list and active group as JSON.
  `--session <file>` restores them on startup and writes them back on exit; a
  missing file falls back to the given paths. Split positions are restored as
  equal horizontal splits. Dirty working copies are not persisted by the
  session format (the in-memory backup/history services are ported but not
  wired into session restore). Side-by-side/diff inputs exist at the workbench
  layer while the TUI tab strip remains single-editor; the Settings editor is
  still a placeholder; tab drag-and-drop moves tabs between groups, inserts at
  the previewed tab-strip position and reorders within one strip. Quick open
  searches
  workspace files and the TUI command table; extension-contributed commands and
  files outside the workspace are not reachable through it yet.
- Known limitations: `MoveLinesCommand` does not yet implement VS Code's
  `Full` auto-indent branch (plain line moves only); line sorting is bytewise
  rather than locale-aware; the overview-ruler/scrollbar column is
  row-quantized (no pixel lanes, translucent alpha, minimap or horizontal
  scrollbar); guides are not drawn on wrapped continuation lines, horizontal
  bracket guide segments are not painted, and a bracket guide is suppressed
  where text occupies the same cell; advanced snippet variable services,
  asynchronous resolve, markdown details rendering, Unicode case mapping for
  snippet transforms, and `SnippetController2` action/context-key plumbing are
  not ported; smart select has no language selection-range provider registry
  (it takes explicit providers and otherwise uses bracket + word); the
  in-place-replace decoration is an underline instead of the browser's 2 px
  outline; and the
  browser-facing editor controllers and menus are not part of this port. The
  keybinding registry/resolver, the abstract keybinding service and the
  context-key scanner/parser/expression model plus a flat context-key service
  are ported; all 21 upstream `abstractKeybindingService.test.ts` cases and the
  registry/resolver/label/store suites pass. The terminal key decoding and the
  workbench-global, editor-tab group, status-bar, search-view and editor
  shortcut dispatch now live in
  `src/vs/workbench/services/keybinding/browser/keybindingService.zig` (flat
  context, no-op notifications, command execution; tab-command results such as
  quit are carried back to the caller). Workbench tab/group shortcuts
  already dispatch through a `KeybindingsRegistry` + `KeybindingResolver`
  (`workbench.action.closeActiveEditor`, next/previous editor, focus group
  left/right, `openEditorAtIndex1-9`). Workbench-global shortcuts also resolve
  through a registry/resolver host: Ctrl+P (quick open), Ctrl+Shift+P (command
  palette), Ctrl+Shift+F/H (find/replace in files), Ctrl+B (toggle sidebar) and
  Ctrl+Alt+S (focus status bar); quick access keeps owning the keyboard while
  its picker is open (Alt+F is the TUI binding for Find in Files, alongside
  Ctrl+Shift+F). Terminals never deliver Cmd, so the TUI resolves `CtrlCmd`
  rules as Ctrl on every host, macOS included; labels and chord hints say Ctrl
  there too. Status-bar keyboard navigation (arrows/home/end/enter/space/
  escape) dispatches through its own binding host while the bar owns focus. The
  search view's Ctrl+R and Alt+C/W/R/P/D/Enter shortcuts resolve through its own
  registry host as well. The editor's Ctrl/Alt character
  shortcuts (save, undo/redo, select all, comment, bracket
  jump/select/remove, in-place replace, reindent, occurrences, line selection,
  indent) and the cursor navigation/selection keys (arrows, word moves,
  home/end, page up/down) resolve through the registry. Unregistered
  combinations (Alt+Arrow line moves, Ctrl+Alt cursors, Alt+Shift smart
  selection) and the editing keys (enter/tab/backspace/delete/escape) still
  use the hand-written dispatch until the core-command layer is ported. Quick open
  uses the ported path-aware item scorer but has no symbol/go-to-line/link
  providers, quick-input buttons,
  icons, keybinding labels or persisted command history.

- The remaining porting roadmap and its blockers live in
  [`docs/porting-inventory.md`](docs/porting-inventory.md). The computed
  editor-options substrate is now ported: `editor/common/config/editorOptions.zig`
  carries the option value types, the `IComputedEditorOptions` interface and
  `EditorLayoutInfoComputer` (minimap, glyph margin, line numbers, wrapping
  columns and overview ruler); `editor/browser/config/editorConfiguration.zig`
  carries `ComputedEditorOptions` with the upstream defaults and the
  environment-dependent options; `editorLayoutProvider.test.ts` is ported.
  `IEditorConfiguration.options` is now a typed `IComputedEditorOptions` rather
  than an opaque pointer. The view-part slice has started:
  `editor/browser/viewParts/viewLines/viewLineOptions.zig`,
  `editor/browser/viewParts/lineNumbers/lineNumbers.zig` and
  `editor/browser/viewParts/currentLineHighlight/currentLineHighlight.zig` and
  `editor/browser/viewParts/selections/selections.zig` and
  `editor/browser/viewParts/wordWrapIndicator/wordWrapIndicator.zig`,
  `editor/browser/viewParts/glyphMargin/glyphMargin.zig` (the shared
  decoration dedup helpers; the DOM widget host is not ported),
  `editor/browser/viewParts/linesDecorations/linesDecorations.zig`,
  `editor/browser/viewParts/marginDecorations/marginDecorations.zig`,
  `editor/browser/viewParts/blockDecorations/blockDecorations.zig`,
  `editor/browser/viewParts/viewCursors/viewCursor.zig`,
  `editor/browser/viewParts/viewCursors/viewCursors.zig` and
  `editor/browser/viewParts/viewLines/viewLine.zig` and
  `editor/browser/viewParts/viewLines/viewLines.zig` are ported.
  The line-numbers part produces terminal line-number data
  (absolute/relative/interval/custom numbering, final-newline and decoration
  class handling), the highlight part per-view-line content/margin/exact flags,
  the selections part per-view-line styled ranges with the rounded-corner
  enrichment and multi-selection insets (rounded corner background pieces are
  DOM-only), the word-wrap indicator part per-line indicator data at the
  wrapping column, and the line/margin decoration parts the per-line class
  identifiers with the upstream dedup/order rules, and the block-decoration
  part the `blockClassName` ranges and `blockIsAfterEnd`/
  `blockDoesNotCollapse`/`blockPadding` decisions (the terminal paints them as
  cell backgrounds or one-cell borders and maps `movedOriginal`/
  `movedModified`/`currentMove` to `diffEditor.move*.border`), and the view
  cursors part the
  plural/visibility/blinking decisions and per-cursor viewport data (the
  terminal host owns the hardware cursor cell and blink timer), and the view-line
  wrapper renders tab-expanded line text through the shared renderer for
  `VisibleLinesCollection`, and the `viewLines` host drains that collection into
  a `StringBuilder` and exposes `IViewLines` cell-column ranges (DOM measurement
  is replaced by `CursorColumns`); all have focused tests. The open P4 work is the `View` orchestrator,
  `viewController.ts` and the terminal `codeEditorWidget` are ported; the
  TUI cursor orchestration replaces the browser cursor/controller, and the
  remaining DOM view parts are documented omissions. The P5e file-service layer
  now has provider/disk providers, encoding, save participants, revert and the
  working-copy services wired to editors; backups/history remain.

- Language associations: `editor/common/services/languagesAssociations.zig` ports
  the platform/configured association registry and matching (exact filename,
  longest pattern, longest extension, registration order, first-line matchers,
  data-URI labels) with the upstream test suite; `base/common/strings.zig` gained
  `endsWithIgnoreCase`, and the editor `LanguageService` now resolves file paths
  through the associations (case-insensitive filename/extension, longest
  extension, pattern priority, registration order). The workbench
  `languageService.ts` extension-point registration surface is still partial;
  the bundled language table itself now lives in
  `src/vs/workbench/services/language/common/bundledLanguages.zig`.

- The view controller's double-click block selection is ported in
  `editor/browser/view/viewController.zig`: bracket content (after an opening or
  before a closing bracket, innermost pair) and quoted-string content (matching
  double/single/backtick quotes, RTL and mismatched-quote bail-outs) with the
  upstream mouse dispatch decision tree routed through an explicit navigation
  command sink. The complete upstream `viewController.test.ts` suite is ported
  (bracket and string happy paths, exotic token spans, RTL/mismatch bail-outs
  and word-select fallbacks) with a per-test token-span harness.

- The terminal `View` orchestrator (`editor/browser/view.zig`) now owns the view
  lines and the registered view parts/overlays: it fans configuration, cursor,
  decoration, flushed, line, scroll, token, zone, theme and focus events across
  them, drives the `prepareRender` → `viewLines.renderText` → part-render
  pipeline, and tracks focus. DOM/edit-context/animation-frame plumbing is
  absent (documented in the file header); the TUI compositor paints the parts'
  structured data.

- The file-system provider contract and the in-memory provider are ported
  (`platform/files/common/files.zig` provider types, `inMemoryFilesystemProvider.zig`
  with tree/stat/readdir/read/write/append/open/read/write/close/rename/delete,
  capability flags, synchronous change listeners and provider error codes).
  `ProviderFileService` in `fileService.zig` registers providers by scheme and
  ports `exists`/`resolve` (with `resolveTo`)/`readFile` (positions)/
  `writeFile` (append)/`createFolder` (recursive)/`move`/`copy`/`del`/
  `onDidRunOperation`/`onDidFilesChange`, including read-only enforcement; the
  complete upstream `inmemoryFileService.test.ts` suite (20 cases, with the
  stream case adapted to the synchronous terminal read) is ported. The disk
  provider (`platform/files/node/diskFileSystemProvider.zig`) implements the
  provider contract over `std.Io` (stat/readdir/read/write/append/delete/
  rename/copy/open-read-write-close and operation change events), records
  `watch` requests and filters host-forwarded watcher changes through
  `deliverChanges`, and is tested directly, through `ProviderFileService` and
  for watcher filtering.

- The terminal network request layer is ported in
  `base/parts/request/common/request.zig` and
  `platform/request/node/requestService.zig`: `IHeaders`/`IRequestOptions`/
  `IRequestContext`, `std.http.Client` transport, status and response-header
  copying, a buffered body cap, redirect limits, Basic auth and TLS through
  Zig's system CA bundle. Proxy fields are available on the service
  (`configure`) but are not wired to `http.proxy` settings yet. Remote Markdown
  images are the first consumer; requests run on the workbench async Io. The
  Node retry/backoff policy, proxy agent, Kerberos, request timeout enforcement
  (the Markdown job enforces its own 30 s deadline) and streaming response
  bodies are documented terminal omissions.

- `ExperimentalSettingsService` (`workbench/services/configuration/common/experimentalSettings.zig`)
  is ported: assignment membership updates synchronously while change
  notifications are coalesced through a polled zero-delay scheduler, keyed
  experiment keys are requested once, and the upstream test cases are ported
  with the terminal `poll` adaptation.

- External file changes now reload clean open editors: `Workbench.handleFileChanges`
  forwards updated resources to `Editor.reloadFromDisk` (whole-document edit,
  saved-version reset, cursor reset) while dirty editors keep their in-memory
  content and marks a conflict on the dirty editor (`Conflict: file changed on
  disk` in its status message, cleared by save or reload). The
  `workbench.action.files.revert` command discards edits/conflicts by reloading
  the file from disk. The workbench starts a `UniversalWatcher` for absolute workspace
  folders, polls it with the settings watcher and forwards its changes into
  this handler (the terminal loop also polls on its frame timeout).

- A terminal `ViewModel` subset is ported in
  `common/viewModel/viewModelImpl.zig`: it owns the projected lines and
  coordinates converter, exposes `IViewModel` (line metrics, viewport
  rendering data and model-decoration viewport mapping into view ranges), and
  tracks selections, focus, viewport and a cell-height layout, applies model
  content changes to the projected lines/decorations, computes glyph-margin
  lanes from decorations, dispatches view events
  (flush/line-mapping/lines/decorations/tokens/focus/cursor state) to
  registered `ViewEventHandler`s, wires `ViewModelDecorations` for inline-decoration
  viewport data, and is wired to
  the terminal `View` (focus/view and collection render integration are
  tested). Rendering real model
  tokens through `VisibleLinesCollection` and the terminal `codeEditorWidget`
  render pipeline is tested, including inline decorations, glyph lanes,
  whitespace/control-character rendering and cursor-state events. Cursor
  selection/state and the event dispatcher are ported; typing/command
  orchestration remains in the TUI editor.

- `EditorGroupModel.openEditor` now forwards the requested `supportSideBySide`
  mode into editor matching, so opening a plain input with
  `supportSideBySide: BOTH` reuses an existing side-by-side composite. The
  upstream preference tests (`openEditor` and `indexOf` direct-vs-composite)
  are ported.

- BOM-based text encoding is ported
  (`workbench/services/textfile/common/encoding.zig`): UTF-8/UTF-16 LE/BE
  detection, decode (stripping BOMs) and encode (adding them); `TextFileService`
  exposes `readWithEncoding`/`writeWithEncoding`, and `TextFileEditorModel`
  preserves the detected encoding across load/save. Save participants are
  ported (participant-driven content updates, `skipSaveParticipants` and error
  propagation that keeps the model dirty). Soft revert (keep current text,
  clear dirty) and hard revert (reload from disk) fire `onDidRevert`. Heuristic charset guessing
  (ANSI/ShiftJIS via jschardet/ICU) is a documented terminal omission.

- Visible whitespace rendering is ported through the shared line renderer:
  `renderWhitespace` modes `all`, `boundary`, `trailing` and `selection` draw
  middle dots for spaces and a right arrow for tabs (selection mode receives
  the view selections through `IViewModel.getSelections`). Control characters
  render as Unicode control pictures when `renderControlCharacters` is on.

- `WorkingCopyService` is ported
  (`workbench/services/workingCopy/common/workingCopyService.zig`): working-copy
  registration/unregistration by resource/type, dirty/modified tracking,
  `isDirty`, and register/unregister/dirty/content/save events, with the
  terminal `IWorkingCopy` listener contract and the full upstream
  registry-basics / duplicate-identifier / same-resource-different-type tests.
  The TUI registers every opened/restored editor with the service (via a
  terminal `IWorkingCopy` adapter) and unregisters on close, so dirty counts,
  per-resource queries and dirty/content/save events track the open editors.
  `WorkingCopyEditorService` registers editor handlers and finds the open editor
  for a working copy (callers pass the open editor list).

- `CursorCollection` gained the remaining selection-tracking operations
  (`startTrackingSelections`/`stopTrackingSelections`/`readSelectionFromMarkers`)
  and top/bottom view-position queries, with a tracking/extents test. A
  terminal `CursorsController` subset (`common/cursor/cursor.zig`) adds
  selection/position access, set selections/states, state save/restore,
  secondary-cursor removal and post-edit validity; typing/command
  orchestration stays in the TUI editor.

- `ViewModelEventDispatcher` is ported in full: handler registry, event
  collector batching (`beginEmitViewEvents`/`endEmitViewEvents`),
  `emitSingleViewEvent`, the re-entrant view-event queue, the outgoing-event
  emitter, and merge/no-op handling for every upstream
  `OutgoingViewModelEvent` kind. The terminal `ViewModel` and editor dispatch
  their content/cursor/focus/scroll/decoration events through it.

- A terminal `CursorsController` subset is ported
  (`common/cursor/cursor.zig`): selection/position access, set selections and
  states, save/restore cursor state, secondary-cursor removal and
  post-edit validity; the TUI editor retains typing/command orchestration.

- `WorkingCopyHistoryService` is ported in memory: newest-first per-resource
  entries, per-resource cap, list/remove/clear and change events, with tests.
  Disk/history persistence remains a documented omission.

- `WorkingCopyBackupService` is ported in memory
  (`workingCopyBackupService.zig`): backup/replace/discard, resource deletion,
  lookup and change events, with a backup/replace/discard/delete test. Disk
  backup persistence is a documented terminal omission.

- Ported infrastructure for the remaining work: `base/common/uri.zig` (components,
  parse/file/toString/encoding, dirname/basename/extname, joinPath, JSON
  round-trip, fs-path decoding) plus portable `extpath` and `network` (scheme/FileAccess) helpers; the in-memory
  policy service with `PolicyConfiguration` (types, restricted/managed metadata,
  changes and owner/reference fallback); and the token-classification registry
  with TextMate scope matching and `ColorThemeData` token-style resolution
  (theme/custom token colors, semantic rules, language/super-type selectors and
  custom settings JSON). Minimal `DiskFileService`/`TextFileService` and
  file/untitled editor inputs and side-by-side/diff identity/serializers
  provide the terminal file-editing foundation. The terminal theme service
  (`workbench/services/themes/browser/workbenchThemeService.zig`) registers
  themes explicitly and persists the active id; `themeConfiguration.zig` ports
  the color-theme selection/preferred-scheme logic, registers the theme settings
  schemas (`workbench.colorTheme`, preferred themes, customizations and the
  auto-detect flags) and `migrateThemeSettingsId` handles legacy ids. The TUI
  now loads its syntax theme through this service: `syntaxTheme.initFromThemeService`
  reads `dark_plus.json` plus its `dark_vs.json` include via `ColorThemeData`
  (JSONC include chains are ported) and converts the token colors into the
  editor `TokenTheme`; the bundled loader remains as a fallback. The file-backed workbench
  configuration service applies
  language overrides, application/machine scope filtering, and untrusted
  workspace filtering for restricted/unregistered settings.
