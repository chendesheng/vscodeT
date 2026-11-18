Port of vscode's pieceTree to zig.

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
```

Notes for the Zig 0.17 port:

- `@cImport` was removed in Zig 0.17, so `oniguruma.h` is translated by the
  build system (`addTranslateC`) and imported as the `oniguruma` module. The
  build searches the standard Homebrew and Linux prefixes for the header and
  library. The editor tokenizer uses the standalone `vscode_textmate` package
  in `textmate/`; Zig/TOML/YAML fallback grammars and the fallback Dark+ theme
  are vendored under `src/support/`.
- `std.io` was replaced by the `std.Io` reader/writer interfaces; the app
  receives its `Io` instance through `std.process.Init`.
- `std.ArrayList` is unmanaged in Zig 0.17. This port currently uses the
  deprecated-but-supported `std.array_list.Managed` shim as an intermediate
  step; moving to unmanaged lists is the main remaining modernization.

## Logging

The TUI logs through the ported service in
`src/vs/platform/log/common/log.zig` and `logService.zig` (the upstream
`AbstractLogger`/`AbstractMessageLogger`, `AdapterLogger`, `BufferLogger`,
`MultiplexLogger`, `NullLogger`, `createUnexpectedErrorHandler` and
`format`). `src/tui/logger.zig`
is the terminal host: it keeps one synchronous `main.log` and writes the same
line format as upstream's `FileLogger`:

```text
2026-11-17 03:36:00.568Z [info] workbench ready: 2 tab(s)
```

The file defaults to `$XDG_STATE_HOME/vscode-textbuffer/logs/main.log`
(`$HOME/.local/state/...` fallback) and `VSCODE_TEXTBUFFER_LOG` overrides the
path. Timestamps are UTC because the terminal host has no time-zone database.
Console loggers, the URI-keyed `ILoggerService` registry and the log-output
picker are not ported: the TUI owns the terminal (alternate screen, raw mode)
and has a single log file instead of per-channel resources.

## Extension host (experimental)

The workbench half of VS Code's extension system is being ported under
`src/vs/workbench/services/extensions/` and `src/vs/workbench/api/`. The Node
extension host itself is reused, not vendored: the launcher in
`host/extensionHost.ts` bundles the module graph reachable from
`../vscode/src/vs/workbench/api/common/extensionHostMain.ts` with esbuild, so
a full `../vscode/out` build is not required.

```sh
cd host && npm install && npm run build   # host/dist/extensionHost.mjs
zig build run -- [--extension-path <extension-dir>] [<file>...]
zig build test-e2e                        # boots the host and edits through VSCodeVim
```

`--extension-path` points at an unpacked extension directory (for VSCodeVim,
the directory containing its `package.json` and `out/extension.js`). Without
the flag, `VSCODE_TEXTBUFFER_EXTENSION_PATH`, the test fixture, then
`~/.vscode*/extensions/vscodevim.vim-*/extension` are tried. The TUI
starts the pinned host, mirrors the active tab as a document/editor, routes
printable keys through the `type` command, and applies the extension's edits
and selections back to the editor. VSCodeVim 1.32.4 insert/normal/visual
editing, `Esc`, motions, `x`/`dd`/`yy`/`p`, undo/redo (`u`, `Ctrl-R`),
`o`/`O`, `:e`/`:w`/`:q`, `:bd`, and `:bnext` across open tabs work in this loop;
the status bar shows its mode entry.

Host stderr is written to `<data dir>/extension-host.log` (normally
`~/.local/state/vscode-textbuffer/extensions/extension-host.log`) so it cannot
corrupt the TUI frame. `test-e2e` is skipped unless `host/dist/extensionHost.mjs`
and the extracted fixture at `.cache-ext/vim/extension` are present. Still missing: the
contribution scanner, configuration writes, full `tabGroups`, the built-in
command set VSCodeVim delegates to, and the extension keybinding registry. See
`docs/extensions.md` for the port status and the remaining work.

## Continuous integration

GitHub Actions (`.github/workflows/ci.yml`) runs the full `zig build test`
suite on Linux (inotify), macOS (kqueue) and Windows (`ReadDirectoryChangesW`),
and cross-compiles the watcher-only test root for `x86_64-windows` and
`aarch64-macos` on Linux. The Linux and macOS jobs check out the pinned
upstream VS Code grammar and theme assets into `../vscode`, so the
tokenizer/theme tests run against the real assets instead of the fallback
theme. The Windows job installs oniguruma with vcpkg and passes
`-Donig-include`/`-Donig-lib` to the build; the terminal layer uses the Windows
console API for raw mode, sizing and input polling.

## Design docs

- [Terminal UI architecture](docs/terminal-ui.md) — the standalone `ui/`
  library: DOM tree model, cell-grid renderer, and the POC-first plan for
  porting the browser UI.
- [Extension system](docs/extensions.md) — reuse VS Code's Node extension host
  unmodified, port the workbench side (RPC codec, `MainThread*` actors,
  scanner, contribution points, TUI wiring) to Zig.
- [TUI porting inventory](docs/porting-inventory.md) — file-by-file mapping of
  `src/tui/` to the VS Code internals it should port, with a UI/view code map
  (what is still collapsed into `view.zig`/`editor.zig` and where it belongs)
  and a prioritized, dependency-ordered roadmap.

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
  terminal tab strip (`src/tui/tabBar.zig`) and a terminal breadcrumb bar
  (`src/vs/base/browser/ui/breadcrumbs/breadcrumbsWidget.zig`,
  `src/vs/workbench/browser/parts/editor/breadcrumbs{,Model,Control,Picker}.zig` with
  the outline service under `src/vs/workbench/services/outline/`). Each tab keeps
  its own `Editor`, `View` and lazy editor contributions; only the active view is
  composited under the two chrome rows, so switching tabs preserves scroll
  position and decorations. Tabs show a two-cell language badge (the file icon
  theme is not ported), preview italics, a close cell and a dirty dot; the close
  cell and middle click close the tab, and a dirty tab still asks for a second
  activation. Double-clicking a preview tab pins it; double-clicking a pinned
  tab toggles the group's expanded (whole-editor-area) state, matching
  upstream's default `doubleClickTabToToggleEditorGroupSizes: 'expand'`.
  Explorer single clicks open a preview editor, while Enter, quick open, CLI
  paths and session restore open pinned; editing a preview pins it.
  `Ctrl-W` closes the active tab, `Ctrl-PgUp`/`Ctrl-PgDn` switch tabs, `Alt-1..9`
  activates a tab by position, `Ctrl-S` saves and `Ctrl-Q` quits (a second
  `Ctrl-Q` is required while any tab is dirty). Empty groups collapse out of
  the split tree when their last tab closes, the divider between panes is a
  draggable sash, and dragging a tab into another pane (or onto its edge)
  retiles the editor part. `--preview` remains a single-file mode.
- The breadcrumb row shows the workspace-relative file path (absolute segments
  outside the workspace) with `>` separators and a 2-cell language badge; `>` and
  the segments follow the upstream focus/selection rules. Clicking a folder or
  file opens the terminal quick pick with the directory's children, and clicking
  a symbol reveals it. Symbol segments are supplied by the ported
  `IOutlineService`/`IOutline` plumbing; **no built-in document-symbol provider is
  shipped yet**, so JavaScript and other files show only the file path until a
  provider is registered (for example by the future extension host). A fake
  provider is used in the tests. `Ctrl+Shift+.` focuses/selects the last segment
  and `Ctrl+Shift+;` focuses it; Left/Right navigate, Enter/Down opens the picker,
  Space reveals and Escape returns to the editor. Terminal substitutions: the
  browser chevron/codicon is `>`, the file icon theme is the language badge, the
  tree picker is the existing quick pick, and overflow clips leading segments
  behind an ellipsis instead of a horizontal scrollbar. The editor-type dropdown,
  breadcrumb drag-and-drop, tab context menus/actions toolbar and the symbol-kind
  filters are not ported.
- A terminal Explorer sidebar (`src/tui/explorerTreeSidebar.zig`) sits left of the editor
  area over the ported `ExplorerModel`
  (`src/vs/workbench/contrib/files/common/explorerModel.zig`). It lists the
  workspace folders lazily, directories first, expands/collapses with
  `Right`/`Left` or a click, moves with `Up`/`Down`, and opens a file on
  `Enter` or a click through the same cross-group `openPath` path as the tab
  model. In a single-folder workspace the folder is the tree input, so its
  children are the top-level rows; a multi-root workspace shows root rows and
  expands the first five roots, matching the Explorer view's default. Deeper
  directories resolve only when expanded. Filtering now runs through the
  upstream-shaped `FilesFilter`
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
  child through `autoExpandCompressedChildren`. `Ctrl-B` toggles the side panel
  and
  `Escape` returns focus to the editor. The generic VS Code list/tree view is
  being replaced in layers under `src/vs/base/browser/ui/list` and
  `src/vs/base/browser/ui/tree`: `rangeMap`, the virtualized `ListView`,
  `ListWidget`, the index/object tree models and a terminal `AbstractTree`.
  The Explorer now renders through that
  `CompressibleObjectTree`/`CompressedObjectTreeModel`/`AbstractTree` path.
  `ObjectTree`, `IndexTree`, a synchronous `DataTree` and the
  `CompressibleObjectTree` view adapter are also ported. Remaining work is the
  async data tree, drag/drop, sticky scroll, the compressed-label navigation
  controller (per-segment focus/hover) and identity-provider diffing through
  the object models.
- The configuration service (`src/vs/workbench/services/configuration/browser/configurationService.zig`)
  resolves defaults, user settings, the workspace file's `settings` block and
  each folder's `.vscode/settings.json`, in that precedence order. It uses the
  ported `ConfigurationModel`/`ConfigurationRegistry` and accepts JSONC
  comments and trailing commas. User settings default to
  `$XDG_CONFIG_HOME/vscode-textbuffer/settings.json` (or
  `$HOME/.config/vscode-textbuffer/settings.json`); set
  `VSCODE_TEXTBUFFER_USER_SETTINGS` to override the path. The TUI watches the
  user settings file, the workspace file and each folder's
  `.vscode/settings.json`, and reloads the service automatically. Not ported:
  - `updateValue` and settings editing (needs the JSONC-preserving configuration
    editing service);
  - language override blocks such as `[typescript]` (override models are not
    ported);
  - policy, application, remote and profile scopes (those services do not exist
    in the terminal workbench);
  - trusted-workspace filtering and restricted settings (no workspace-trust
    service);
  - the Settings editor/view, which remains a placeholder.
- The file watcher (`src/vs/platform/files/...`) ports the VS Code service and
  the Linux/macOS/Windows backends: `common/files.zig` and
  `common/watcher.zig` for change/request contracts, coalescing, pattern
  normalization and filters; `baseWatcher.zig` for correlation,
  suspend/resume and retry; `parcelWatcher.zig` plus the in-tree
  `parcel/watcherLib` for recursive watching; `nodejsWatcherLib.zig` for
  non-recursive watching; and `watcher.zig`/`watcherStats.zig` for the
  universal watcher and diagnostics. The Linux backend uses inotify, macOS
  uses kqueue (the upstream parcel kqueue backend; FSEvents/CoreServices is not
  ported), and Windows uses overlapped `ReadDirectoryChangesW`. Brute-force
  snapshot polling backs the polling mode. The `@parcel/watcher` N-API binding,
  JS wrapper, prebuilds and Electron IPC watcher clients are not ported; the
  terminal embeds one in-process `UniversalWatcher`. The only wired consumer is
  automatic settings reload; Explorer and Search still do not refresh on
  external changes. `src/tui/settingsWatcher.zig` owns the settings requests
  and `src/tui/app.zig` polls the watcher's fd alongside stdin.
  `zig build test-watcher -Dwatcher-only=true` runs the watcher-only suite;
  `zig build check-watcher -Dwatcher-only=true -Dtarget=x86_64-windows` and
  `zig build check-watcher -Dwatcher-only=true -Dtarget=aarch64-macos` type-check the other
  platform backends without the POSIX TUI.
- The activity bar is split into the ported model
  (`src/vs/workbench/browser/parts/activitybar/activitybarPart.zig`), the
  activity service model
  (`src/vs/workbench/services/activity/browser/activityService.zig`) and the
  terminal view (`src/tui/activityBar.zig`). The Search activity shows a badge
  dot while matches are present (the exact count is in the panel); the service
  also supports view and global badges. It
  switches between
  Explorer, Search and Settings containers; Explorer is wired to the file tree
  and Search to the workspace text-search panel, while Settings remains a
  placeholder. `Alt-1..3` switches containers while the side panel has focus.
  The model owns order, visibility, the active container and compact width.
  There is still no registered view-container contribution registry, live
  Explorer/Search file-change integration, context menu or drag-and-drop.
- The Search panel is a terminal adapter (`src/tui/searchView.zig` and
  `src/tui/searchWidget.zig`) over the upstream-shaped portable view:
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
  `files.exclude` and `search.exclude` are now honored through
  `src/vs/workbench/services/search/common/search.zig` and the ported glob
  expression, including `false` entries, `!` exceptions and `{ when: ... }`
  sibling clauses; `search.useIgnoreFiles` disables ignore-file loading. The
  implementation still honors `.gitignore`/`.ignore` through
  `IgnoreFile` (`src/vs/workbench/services/search/common/ignoreFile.zig`) when
  enabled, and skips symlinks, binary/invalid-UTF-8 files, files over 10 MB,
  version control metadata and Zig build output. Not ported: AI/notebook/
  search-editor results, only-open-editors and SCM changed-files modes,
  multi-selection, context menus, drag/drop, clipboard actions, search history
  and view-state persistence, compressed folder chains, and `./`/absolute
  search-path expansion or per-folder settings. The filesystem is not watched;
  edits to the active editor schedule a debounced re-search instead.
- Folder opening follows the workspace model: a directory argument stat'd from
  the CLI becomes a `Workspace` folder through
  `src/vs/platform/workspace/common/workspace.zig` and
  `src/vs/workbench/services/workspaces/common/workspaceContextService.zig`.
  `ExplorerModel` builds its roots from `getWorkspace().folders`, so opening a
  folder shows that folder as the Explorer root and starts with an empty
  editor group; files on the command line still open as tabs. Opening only
  files uses an empty workspace, as upstream does.
- The editor is rendered through the library (`src/tui/view.zig`): text,
  syntax colors, right-aligned line numbers, wrapped-line markers, selections,
  the current line and a hardware cursor. The workbench status bar is a
  full-width bottom row built from the ported
  `StatusbarModel`/`StatusbarPart`/`StatusbarService`
  (`src/vs/workbench/browser/parts/statusbar/`) and the ported editor-status
  controller (`src/vs/workbench/browser/parts/editor/editorStatus.zig`):
  entries use upstream alignment/priority/compact rules, the bar builds a one-row flex `ui` surface
  (left items grow and right items are row-reverse), and the right side
  shows selection, indentation, encoding, EOL and language. Clicking an entry
  focuses it and runs its command: selection opens Go to Line/Column, and the
  other values open the indentation, encoding, EOL and language pickers
  through the ported quick-input service
  (`src/vs/platform/quickinput/browser/quickInputService.zig`).
  Arrow keys, Home/End, Enter/Space and Escape navigate while focused,
  `Ctrl-Alt-S` toggles editor/status focus, and the `Focus Status Bar` command
  is in the palette.
  The editor view keeps its fallback status row for standalone tests and the
  read-only preview. The bar's terminal adaptations are documented in
  `docs/terminal-ui.md`: codicons are plain text, text ellipsis is
  pre-truncation, focus is an underline, the tooltip is plain text, hidden
  entry state is in memory, and the context menu/auxiliary parts are not
  ported. The
  `zig build run -- --preview <file>` read-only mode uses the same token
  renderer and adds Up/Down, PageUp/PageDown, Home, End and mouse-wheel
  scrolling; Ctrl-Q quits. Overlay widgets and a single-line terminal input box
  (`ui/inputbox.zig`) are in place, and the find bar is wired: Ctrl-F opens
  find (a single-line selection seeds the query), Ctrl-R opens the replace row,
  Enter/Shift-Enter go to the next/previous match, Escape closes, Tab switches
  between the find and replace inputs, Alt-C/Alt-W/Alt-R toggle match case,
  whole word and regex, Alt-P toggles preserve case, Alt-L limits the search to
  the current selection(s), Alt-Enter selects all matches, and Ctrl-Alt-Enter
  replaces all. The bar shows the match position/count and option state. The
  find, search and quick-open inputs share the completed `InputBox` editing
  behavior: Shift selection, Ctrl-A, word-wise movement/deletion, undo/redo,
  mouse drag selection and caret-follow horizontal scrolling.
- Quick open is wired through `src/tui/quickAccess.zig`: `Ctrl-P` opens
  "Go to File" with recent editors first and workspace files as the query is
  typed, and typing `>` switches to the command selector. The command selector
  is also bound to `Alt-P` because a plain terminal reports `Ctrl-Shift-P` as
  `Ctrl-P`; the action metadata keeps the upstream command ids and labels. Up,
  Down, PageUp/PageDown, Ctrl-Home/Ctrl-End navigate, Enter accepts, Escape or
  an outside click closes, the wheel scrolls the list, and clicking a row
  accepts it. The workspace file index is built lazily while the picker is
  open, honors `.gitignore`/`.ignore` through the same ported `IgnoreFile`,
  skips `.git`, `.hg`, `.svn`, `node_modules`, `.zig-cache`, `zig-cache` and
  `zig-out`, does not follow symlinks, does not honor `search.exclude`, and
  caps at 100,000 files. Matching uses the ported `fuzzyScorer.scoreItemFuzzy`
  label/description/path scorer, including its path-identity, label-prefix and
  match-compactness boosts (Unicode words are scored per codepoint and word
  filters fold ASCII + Latin-1 case, so the emoji/UTF-8 highlight alignment from
  #113404 and the Japanese/Umlaut word cases match upstream); the scorer cache
  is not used by the picker.
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
  unmatched-closing detection.
- `ColorizedBracketPairsDecorationProvider` turns colorized brackets into
  `bracket-highlighting-N` / `unexpected-closing-bracket` decorations, honoring
  `bracketPairColorizationOptions`.
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
- Background tokenization is synchronous (1 ms chunks) because this port has
  no browser idle loop; behavior is otherwise equivalent.

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
  originals, embedded from `../vscode/extensions/*/syntaxes/*.tmLanguage.json`
  at build time (`vscode-syntax`). `zig`, `toml` and `yaml` use vendored
  fallback grammars in `src/support/grammars` (the current VS Code YAML
  grammar does not tokenize with this parser). The vendored Dark+ theme is the
  fallback when the checkout is absent.
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
  with the reference checkout at `../vscode-textmate`. It covers the engine
  and all upstream test suites, including the first-mate/suite1 tokenization
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
  `src/vs/editor/contrib/hover/browser/hoverMarkdownRenderer.zig` maps that
  tree to styles and cells: paragraphs, headings, nested/ordered/task lists,
  block quotes, fenced and indented code, thematic breaks, GFM tables,
  emphasis, strikethrough, inline code, links/autolinks and images. Fenced
  code blocks are tokenized with the same TextMate grammars as the editor; the
  fence info string resolves through common aliases (`js`, `ts`, `py`, `sh`,
  ...), a fence without a language falls back to the editor's language, and an
  unknown language renders as plain code.
- Terminal substitutions: a link shows its text underlined and, when the URL
  differs, the URL in dim text because cells cannot open a link; images show
  their alt text (there is no image protocol); tables render as box-drawing
  grids with width-capped columns; raw HTML is dropped (there is no HTML
  sanitizer or renderer); one blank line separates sibling blocks in place of
  browser margins; tabs expand to four spaces. MDX, math and frontmatter are
  disabled; there is no clickable-link or image support.


TUI editor:

- The app edits through `TextModel` (not `PieceTreeTextBuffer` directly) and uses
  the ported wrapping stack.
- Text soft-wraps at the terminal width. Wrapped continuation lines are indented
  (`WrappingIndent.Same`) and marked with an arrow in the gutter. The generic
  `ui` text engine (UAX #14, `white-space`, line fragments) wraps widget and
  prose text; editor line boxes stay `pre` so the view-model wrapping is not
  applied twice.
- `q` is ordinary text. Quit with `Ctrl-Q` (press twice if there are unsaved
  changes); save with `Ctrl-S`; undo/redo with `Ctrl-Z`/`Ctrl-Y`.
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
- Indentation and bracket guides: a dim `│` is drawn at each indentation
  column of a line's leading whitespace, using the ported
  `common/model/guidesTextModelPart.zig` rules. Blank lines inherit the guide
  count from the surrounding content. Vertical bracket-pair guides are
  computed from the existing bracket-pairs model and colored by nesting level.
  The guide level around the caret and the bracket pair containing the caret
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
  `Alt-Shift-R` reindents the whole buffer.
- Folding: the last gutter cell shows `▾` for an expanded region and `▸` when
  collapsed; clicking it toggles the region on that line. `Ctrl-Shift-[` /
  `Ctrl-Shift-]` fold/unfold at the caret, `Ctrl-K Ctrl-L` toggles,
  `Ctrl-K Ctrl-0` folds all and `Ctrl-K Ctrl-J` unfolds all. Collapsed regions
  hide their model lines and end the first visible line with `…`.
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
  `src/tui/language.zig`.
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
  `85bcc67`, MIT) and rendered to styled cells by `markdownHoverRenderer.zig`;
  tables, nested/task lists, setext and indented code, autolinks and reference
  links are supported. The hovered range is painted through the same
  `LineDecoration.filter`/`extractWrapped` path as find and bracket highlights
  (`hoverHighlight`). The app registers a TUI-local provider
  (`src/tui/hoverProvider.zig`) that reports the word, language and token type,
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
  gutter state). `ProjectedViewModelLines.setHiddenAreas` removes collapsed
  lines from the view projection, so view/model conversion, cursor movement,
  selection adjustment, wrapping and the scrollbar all see the folded view.
  The TUI gutter paints `▾`/`▸` in its last cell and handles the click; the
  editor binds the upstream fold/unfold/toggle/fold-all/unfold-all commands and
  registers them in the workbench command palette. Syntax folding providers,
  folding-decoration CSS classes, sticky scroll, fold-imports-by-default,
  folding mementos/view state, manual folding-range actions and the
  goto-parent/previous/next-fold actions are not ported. Fold state survives
  edits on the folded line, but inserting or deleting lines above a collapsed
  region re-expands it because the TUI has no tracked folding decorations.
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
  (active pane, page position, size constraints); `src/tui/workbench.zig` is
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
  `src/tui/session.zig` stores the group list and active group as JSON.
  `--session <file>` restores them on startup and writes them back on exit; a
  missing file falls back to the given paths. Split positions are restored as
  equal horizontal splits. Dirty working copies are not persisted by the
  session format (the in-memory backup/history services are ported but not
  wired into session restore). Side-by-side/diff inputs exist at the workbench
  layer while the TUI tab strip remains single-editor; the Settings editor is
  still a placeholder; tab drag-and-drop moves tabs between groups but does not
  reorder them within one strip. Quick open searches
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
  registry/resolver/label/store suites pass. `src/tui/keybindings.zig` remains
  the terminal host for status/search/editor shortcuts, while
  `src/tui/keybindingService.zig` runs the workbench-global, editor-tab group,
  status-bar, search-view and editor shortcuts through the abstract service (flat context, no-op
  notifications, command execution; tab-command results such as quit are
  carried back to the caller). Workbench tab/group shortcuts
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
  identifiers with the upstream dedup/order rules, and the view cursors part the
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
  `languageService.ts` registration surface that would replace
  `src/tui/language.zig` still needs to be ported.

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

- `ViewModelEventDispatcher` is ported (handler registry, direct delivery and a
  re-entrant event queue) and the terminal `ViewModel` now dispatches through
  it for content/cursor/focus events.

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
