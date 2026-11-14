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
```

Notes for the Zig 0.17 port:

- `@cImport` was removed in Zig 0.17, so `oniguruma.h` is translated by the
  build system (`addTranslateC`) and imported as the `oniguruma` module. The
  build searches the standard Homebrew and Linux prefixes for the header and
  library; `textmate` is wired from its package sources so its macOS-only
  build script is not used.
- `std.io` was replaced by the `std.Io` reader/writer interfaces; the app
  receives its `Io` instance through `std.process.Init`.
- `std.ArrayList` is unmanaged in Zig 0.17. This port currently uses the
  deprecated-but-supported `std.array_list.Managed` shim as an intermediate
  step; moving to unmanaged lists is the main remaining modernization.

## Design docs

- [Terminal UI architecture](docs/terminal-ui.md) — the standalone `ui/`
  library: DOM tree model, cell-grid renderer, and the POC-first plan for
  porting the browser UI.
- [Extension system](docs/extensions.md) — reuse VS Code's Node extension host
  unmodified, port the workbench side (RPC codec, `MainThread*` actors,
  scanner, contribution points, TUI wiring) to Zig.

## Terminal UI library

- `ui/` is a standalone Zig package outside `src/`: a DOM-like tree with direct
  styles (no CSS), a derived layout box tree (viewport, principal, anonymous and
  text boxes), whole-cell layout with margin/padding/border boxes and
  box-drawing borders, block/inline/flex formatting contexts, and a
  double-buffered cell renderer that emits only an ANSI frame diff. Flex
  supports direction, wrap, grow/shrink/basis, justify/align, gap, order, auto
  margins and content-derived auto sizes. It does not import editor code.
- Multi-file editing uses the ported workbench editor-group model
  (`src/vs/workbench/common/editor/editorGroupModel.zig`) with a terminal tab
  strip (`src/tui/tabBar.zig`, `src/tui/workbench.zig`). Each tab keeps its own
  `Editor`, `View` and lazy editor contributions; only the active view is
  composited under the tab row, so switching tabs preserves scroll position and
  decorations. `Ctrl-W` closes the active tab (a dirty tab asks
  for a second `Ctrl-W`), `Ctrl-PgUp`/`Ctrl-PgDn` switch tabs, `Alt-1..9`
  activates a tab by position, `Ctrl-S` saves and `Ctrl-Q` quits (a second
  `Ctrl-Q` is required while any tab is dirty). `--preview` remains a
  single-file mode.
- A terminal Explorer sidebar (`src/tui/sidebar.zig`) sits left of the editor
  area over the ported `ExplorerModel`
  (`src/vs/workbench/contrib/files/common/explorerModel.zig`). It lists the
  workspace folders lazily, directories first, expands/collapses with
  `Right`/`Left` or a click, moves with `Up`/`Down`, and opens a file on
  `Enter` or a click through the same cross-group `openPath` path as the tab
  model. In a single-folder workspace the folder is the tree input, so its
  children are the top-level rows; a multi-root workspace shows root rows and
  expands the first five roots, matching the Explorer view's default. Deeper
  directories resolve only when expanded. `Ctrl-B` toggles the side panel and
  `Escape` returns focus to the editor.
- A minimal activity bar (`src/tui/activityBar.zig`) switches between Explorer,
  Search and Settings containers. Explorer is wired to the file tree and Search
  to the workspace text-search panel; Settings remains a placeholder.
  `Alt-1..3` switches containers while the side panel has focus. The width is
  fixed for now; there is no registered activity-bar/view-container service,
  file watching, context menu or drag-and-drop.
- The Search panel (`src/tui/searchView.zig` and `src/tui/searchWidget.zig`) is
  a plain-text workspace search over
  `src/vs/workbench/services/search/common/searchService.zig` and the ported
  search result tree. `Alt-F` opens it (Ctrl-Shift-F is indistinguishable from
  Ctrl-F in a normal terminal), `Ctrl-R` toggles replace, `Alt-D` toggles the
  files-to-include/exclude rows, and `Tab` cycles the inputs. Matching options
  are `Alt-C` (case), `Alt-W` (whole word), `Alt-R` (regex) and `Alt-P`
  (preserve case). `Enter` opens a match or toggles a folder/file; `Left`/
  `Right` collapse/expand; `Delete` dismisses; `Alt-Enter` replaces the
  selection and `Ctrl-Alt-Enter` replaces all. Results stream incrementally
  and are grouped as Text Results -> workspace/nested folder -> file -> line.
  The implementation honors `.gitignore` and `.ignore` through the ported
  `IgnoreFile` (`src/vs/workbench/services/search/common/ignoreFile.zig`):
  every directory's ignore file inherits the enclosing one, so nested files,
  directory-only patterns and `!` negations behave like git. It still skips
  symlinks, binary/invalid-UTF-8 files, files over 10 MB and version control
  metadata (`.git`/`.hg`/`.svn`) plus `node_modules` and Zig build output. It
  does not honor `search.exclude`/`files.exclude` configuration, has no
  AI/notebook/search-editor results, no replace preview, no
  multi-selection/context menus, and does not watch the filesystem; edits to
  the active editor schedule a debounced re-search instead.
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
  the current line, a hardware cursor and the status row. The
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
  caps at 100,000 files. Matching uses the ported
  `filters.fuzzyScore` scorer; the browser `fuzzyScorer.ts` path-aware scorer
  and its identity/prefix boosts are not ported. Symbol (`@`), go-to-line
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
  `registerLanguageConfiguration`.
- The language-support helpers are ported: rich bracket grouping and
  forward/reversed bracket search (`RichEditBrackets`, `BracketsUtils`),
  `ScopedLineTokens`, electric-character matching, and `OnEnterSupport`
  evaluation.
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
- The TUI uses a reduced port of `viewModelLines`: wrapped model-line projections,
  view-line prefix sums, view/model conversion, and incremental line mapping.
  Folding, view zones, decorations, and the browser-facing `viewModelImpl`
  rendering stack are not ported. Indentation guides are ported separately at
  the model/view boundary (see below).

TextMate tokenization:

- The `textmate.zig` fork (`chendesheng/textmate.zig`, commit `55ea72f`) is
  used for language tokenization as a pinned Zig package dependency.
- Supported language IDs include `zig`, `json`, `javascript`,
  `typescript`, `python`, `rust`, `go`, `c`, `cpp`, `java`, `html`, `css`,
  `scss`, `markdown`, `yaml`, `toml`, and `shellscript`/`bash`.
- TextMate scopes are mapped to token types (`comment`, `string`, `regexp`)
  and foreground color IDs.
- Languages without a TextMate mapping continue to use the null tokenizer.


TUI editor:

- The app edits through `TextModel` (not `PieceTreeTextBuffer` directly) and uses
  the ported wrapping stack.
- Text soft-wraps at the terminal width. Wrapped continuation lines are indented
  (`WrappingIndent.Same`) and marked with an arrow in the gutter.
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
  markdown-rendered to styled cells by
  `markdownHoverRenderer.zig`; the hovered range is painted through the same
  `LineDecoration.filter`/`extractWrapped` path as find and bracket highlights
  (`hoverHighlight`). The app registers a TUI-local provider
  (`src/tui/hoverProvider.zig`) that reports the word, language and token type,
  because VS Code gets hover contents from language extensions. Not ported,
  each because the corresponding infrastructure has no terminal counterpart:
  marker/glyph/color-picker/inlay-hint hover participants (no marker service,
  glyph margin, color picker or inlay hints), hover verbosity actions (no
  command/keybinding service), the copy button (no clipboard plumbing),
  accessible hover views (no screen-reader/accessible-view service), sash
  resizing and horizontal scrolling, status-bar actions (the bar renders
  labels but no participant adds one), and a keyboard "show hover" command (no
  keybinding registry). Hover over the empty area *after* a line needs
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
- Folding is ported at the model/provider layer:
  `foldingRanges` (range storage, parent lookup, collapse state, merge/sanitize),
  `indentRangeProvider` (indentation-based folding and marker handling),
  `foldingModel` (region state and collapse transitions), and
  `hiddenRangeModel` (hidden-line ranges and selection adjustment). The
  browser folding controller, decorations/chevrons, syntax folding providers,
  sticky scroll, and TUI folding UI are not ported.
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
  and multi-group serialization. `src/tui/workbench.zig` renders a binary split
  tree with a tab row per group and composites every pane into one frame;
  `Alt-\` splits horizontally, `Alt-Shift-\` vertically, `Ctrl-Alt-Left` /
  `Ctrl-Alt-Right` switch groups, and clicking a group activates it. A split
  moves the active tab into the new group (independent view state for one
  shared model still needs the model/view split).
- Serialization/restore is ported at the model and TUI boundaries:
  `src/vs/workbench/common/editor/editorFactory.zig` holds the editor
  serializer registry, `EditorGroupModel.serialize`/`deserialize` rebuilds the
  ordered group/MRU/preview/sticky state through registered serializers, and
  `src/tui/session.zig` stores the group list and active group as JSON.
  `--session <file>` restores them on startup and writes them back on exit; a
  missing file falls back to the given paths. Split positions are restored as
  equal horizontal splits. Dirty working copies are not persisted because the
  working-copy backup service is not ported. Side-by-side/diff inputs, settings
  editors and tab drag-and-drop are still not ported. Quick open searches
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
  browser-facing editor controllers, keybinding registry, menus, and context
  keys are not part of this port. Quick open has no `fuzzyScorer.ts`
  path-aware scoring, symbol/go-to-line/link providers, quick-input buttons,
  icons, keybinding labels or persisted command history.
