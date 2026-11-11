Port of vscode's pieceTree to zig.

Requires Zig 0.17 or newer.

```
brew install oniguruma
zig build        # build the TUI editor
zig build run -- <file>   # run the TUI editor on a file
zig build run -- --preview <file>   # read-only terminal UI preview
zig build test   # run the editor and ui library tests
```

Notes for the Zig 0.17 port:

- `@cImport` was removed in Zig 0.17, so `oniguruma.h` is translated by the
  build system (`addTranslateC`) and imported as the `oniguruma` module.
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
  box-drawing borders, and a double-buffered cell renderer that emits only an
  ANSI frame diff. It does not import editor code.
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
  replaces all. The bar shows the match position/count and option state.
- Mouse input is wired through the library: SGR reports in mode 1003/1006 become
  `ui.MouseEvent`s, `Surface.elementFromPoint` hit-tests the box tree, and a
  press focuses the element under the cell. In the editor, left-click places the
  caret, Shift-click extends, dragging selects (a selecting drag is not a
  click), and the wheel scrolls three view lines without moving the caret.
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
  and are all fullscreen. `cd ui && zig build examples` opens the gallery with a
  side navigation menu; individual `example-hello`, `example-list`,
  `example-overflow`, `example-focus`, `example-mouse`, `example-mouse-events`
  steps still run one scene directly.

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
  Folding, view zones, decorations, guides, and the browser-facing
  `viewModelImpl` rendering stack are not ported.

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
- Editing: `Enter`, `Tab`/`Shift-Tab`, `Backspace`, `Delete`, bracketed paste.
- `Ctrl-A` selects all; `Escape` clears the selection.
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
- `src/vs/editor/contrib/bracketMatching` ports the controller logic: jump to
  bracket, select to bracket, remove brackets, and the cached bracket-match
  data used for visual highlighting. The TUI turns that data into model
  decorations and paints them through the ported `LineDecoration.filter` /
  `extractWrapped` path, the same route find ranges take; the overview-ruler
  part and CSS decoration classes are still unpainted.
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
- Known limitations: `MoveLinesCommand` does not yet implement VS Code's
  `Full` auto-indent branch (plain line moves only); line sorting is bytewise
  rather than locale-aware; and the browser-facing editor controllers,
  keybinding registry, menus, and context keys are not part of this port.
  Bracket matching paints its inline match cells, but not the overview-ruler
  marker.
