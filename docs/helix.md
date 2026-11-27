# Native Helix

Helix is a compiled-in built-in extension (`vscode-textbuffer.helix`). It does
not run in the Node extension host and does not load a Helix plugin. It is a
deliberate Zig addition, not a VS Code upstream port, and follows Helix's
selection-first editing model: a movement builds a selection, then `d`/`c`/`y`
acts on it.

## Enable

Add to the user settings file:

```json
{
  "helix.enabled": true
}
```

The setting is read at startup. Helix can also be enabled after the editor
starts through the command picker (`Ctrl-Shift-P`):

- `Helix: Enable` (`helix.enable`)
- `Helix: Disable` (`helix.disable`)

Both commands write the user-level `helix.enabled` setting, so the choice
survives a restart. There is no `Helix: Toggle` command.

## Vim and Helix are mutually exclusive

Only one modal built-in consumes keys at a time. Enabling Helix disables Vim for
the session and persists `vim.enabled:false`; enabling Vim does the same to
Helix. If both settings are true at startup, Helix takes precedence, Vim is
disabled and persisted off, and the editor reports the precedence.

## Editor state ownership

The Helix engine keeps only Helix command state: pending prefix/count, the
selected register, search pattern, macro recording and the last inserted text.
Everything else belongs to the editor:

- Selections, cursor state and desired columns are the editor's selections.
- `u`/`U` call `Editor.undo()`/`Editor.redo()`. An insert session or a change
  command is one editor undo group; the engine brackets it with
  `beginUndoGroup()`/`endUndoGroup()`.
- `j`/`k` use the editor's visual-line movement and `gj`/`gk` its logical-line
  movement, so wrapped lines and tabs keep their visible column. Repeated
  vertical movement remembers the desired column, so crossing a shorter line
  and moving on restores the original column instead of staying clamped. At the
  first and last line the motion is a no-op and keeps the remembered column.
- Insert mode uses the regular editor key dispatch for suggestions, snippet
  navigation, auto-closing pairs, and auto-indent.
- Search uses the model's regular-expression matcher. `/` and `?` preview
  matches while the prompt is edited: the selection moves to the match (or,
  in select mode, is extended with it) and every match is highlighted with the
  Ctrl+F find-match colors. `Enter` commits and `Esc` restores the prompt-start
  selections and the previous pattern's highlights; `n`/`N` keep the current
  match emphasized. `ITextEditor` is the only editor surface the engine sees.

There is no Helix-owned undo history and no separate selection store. The engine
stores the last selection set only for `gv`.

## Supported surface

The implementation follows Helix's published keymap
(<https://docs.helix-editor.com/keymap.html>) with a small number of documented
TUI/Vim-compatibility aliases.

### Normal mode

Motions (normal mode replaces the selection; select mode extends it):

- `h`/Left, `j`/Down (visual line), `k`/Up, `l`/Right.
- `w`, `b`, `e`, `W`, `B`, `E`.
- `f`/`F`/`t`/`T` across the whole document; `Alt-.` repeats the last find.
- `Ctrl-b`/PageUp, `Ctrl-f`/PageDown, `Ctrl-u`/`Ctrl-d`.
- `Home`/`End`, `Ctrl-o`/`Ctrl-i` (editor navigation history), `Ctrl-s` (save
  the current selection to the history jumplist).

Selection manipulation:

- `v` toggles select (extend) mode.
- `x` selects the current line and repeated `x` extends down; `X` extends to
  whole-line bounds including the break; `Alt-x` shrinks to line bounds without
  the break; `%` selects the whole file.
- `;` collapses to the cursor, `Alt-;` flips anchor/head, `Alt-:` ensures a
  forward selection.
- `,` keeps the primary selection; `Alt-,` removes it.
- `C`/`Alt-C` copy the selection to the next/previous line.
- `(`/`)` rotate the primary selection.
- `Alt-s` splits on newlines; `Alt-minus` merges all selections; `Alt-_`
  merges consecutive selections; `_` trims spaces and tabs while keeping line
  breaks.
- `s` opens a regex prompt and selects matches inside the current selections;
  `S` splits selections on regex matches. `%s` is the global-replace entry
  point.

Changes:

- `d`, `Alt-d` (no yank), `c`, `Alt-c` (no yank), `y`, `p`, `P`, `R`, `r`,
  `~`, `` ` ``, `Alt-``.
- `i`, `a`, `I`, `A`, `o`, `O`; `.` repeats the last insertion; `u`/`U`
  undo/redo; `Ctrl-R` is a TUI redo alias.
- `>`/`<` indent/outdent selected lines; `=` runs format selection through the
  command service.
- `J` joins lines inside the selections; `Alt-J` joins and selects the inserted
  space.
- `Ctrl-a`/`Ctrl-x` increment/decrement the number at or after each selection.
- `Ctrl-c` toggles line comments.
- `"` selects a register; `Q` starts/stops macro recording and `q` replays.
- `/`, `?` (incremental, with match highlighting), `n`, `N`, `*`
  (word-boundary search), `Alt-*` (raw selection regex).

### Minor modes

- `g` goto mode: `gg` first line, `<n>gg`/`<n>G` line n, `ge` last line, `gh`
  line start, `gl` line end, `gs` first non-blank, `gt`/`gc`/`gb` viewport
  top/center/bottom, `gj`/`gk` textual line down/up, `gd` definition, `gD`
  declaration, `gy` type definition, `gi` implementation, `gr` references,
  `gf` file under cursor, `gn`/`gp` next/previous buffer, `gv` last selection.
  `0`, `$` and `^` are TUI aliases for `gh`, `gl` and `gs`; `V` is a TUI alias
  for `X`.
- `m` match mode: `mm` matching bracket, `ms`/`md`/`mr` add/delete/replace a
  simple bracket or quote surround, and `mi`/`ma` select inside/around a
  text object. Text objects are `w`/`W` (word/WORD), `p` (paragraph), a
  specified bracket or quote (`(`, `[`, `{`, `"`, `'`, `` ` ``), or `m`
  for the closest surround pair. Bracket matching and bracket text objects use
  the editor's token-aware bracket-pair AST, so they follow the language's
  configured bracket pairs and skip brackets inside comments and strings.
  `<`/`>` is available only when the language configuration declares it
  (plaintext declares `()[]{}`). Tree-sitter-only objects (`f`, `t`, `a`, `c`,
  `T`, `g`, `x`) report that the grammar object is unavailable.
- `z` and `Z` view mode: `zc`/`zz` center, `zt` top, `zb` bottom, `zj`/`zk`
  scroll one line, `Ctrl-d`/`Ctrl-u`/`Ctrl-f`/`Ctrl-b` page. `zm` is a no-op
  because the terminal has no horizontal scroll.
- `Ctrl-w` window mode: `w` navigate groups, `v` vertical split, `s` horizontal
  split, `h/j/k/l` navigate, `q` close, `o` close others, `=` even widths.
- Space mode maps to existing workbench commands only: `space f`/`space b`
  quick open, `space e` explorer, `space s` go-to-symbol, `space /` find in
  files, `space d` markers, `space k` hover, `space c` line comment, `space C`
  block comment, `space h` references, `space w` window mode, `space ?` command
  palette.

### Insert mode

- Text/UTF-8 character input, Enter/Ctrl-j, Tab (smart tab), Shift-Tab,
  Backspace/Ctrl-h, Delete/Ctrl-d, arrows, Home/End, PageUp/PageDown.
- `Ctrl-Space` opens suggestions. Tab or Enter accepts the selected item,
  and Tab and Shift-Tab navigate snippet placeholders. Shift-Tab inserts a
  literal tab outside snippets.
- `Ctrl-w`/`Alt-Backspace` and `Alt-d`/`Alt-Delete` delete a word backward or
  forward; `Ctrl-u` deletes to line start; `Ctrl-k` deletes to line end.
- `Ctrl-r` inserts a register; `Ctrl-s` commits an undo checkpoint; Escape or
  Ctrl-c returns to normal mode.
- Escape ends the insert undo group and collapses each selection one character
  to the left, matching Helix's one-character normal cursor.
- `i` inserts before the selection, `a` after it, `I` at the first non-blank,
  `A` at the line end, and `o`/`O` open a line below/above.
- `.` repeats the last inserted text at the current selections, including
  accepted completions and automatically inserted closing characters.

### Command line and prompts

- `:w`, `:q`, `:q!`, `:wq`, `:x`, `:e <path>`, `:reload`, `:bn`, `:bp`,
  `:bd`, `:sp`, `:vsp`, `:noh`, `:$`, a numeric line, `:format`, and
  `:set ignorecase|noignorecase|smartcase|regex|noregex`.
- Unknown commands report `Helix: unsupported command`.
- The `:`, `/`, `?`, `s`/`S` and replace prompts support text input,
  Backspace, `Ctrl-u`, `Ctrl-w`, Enter and Escape.
- The status bar shows `-- NORMAL --`, `-- INSERT --`, `-- SELECT --`, pending
  prefixes/counts, and the active prompt. Handler failures report
  `Helix: <error>`.

## Deliberate non-goals

These are documented gaps, not hidden behavior:

- Tree-sitter syntax nodes, the tree-sitter-only text objects (`f`, `t`, `a`,
  `c`, `T`, `g`, `x`), syntax-aware expand/shrink, and unimpaired `[`/`]`
  motions.
- Shell integration (`|`, `!`, `$`, `:sh`, `:pipe`, `:read`, `:write`).
- System clipboard registers; only the internal unnamed/named and black-hole
  registers are implemented.
- LSP pickers (file/buffer/jumplist/symbol/diagnostic pickers), rename, code
  actions and workspace diagnostics. Only existing workbench commands are
  mapped from the goto and space modes.
- Sticky view mode `Z` (the `Z` key enters plain view mode), horizontal
  scrolling `zm`, relative line numbers, themes and `config.toml`.
- Insert-mode completion (`Ctrl-x`).
- Selection filtering/alignment (`K`, `Alt-K`, `&`) and selection-content
  rotation (`Alt-(`, `Alt-)`).
- Change-history walking (`Alt-u`, `Alt-U`).
- Vim/Helix plugins and any parallel undo or selection model.

## Layout

- `src/vs/editor/contrib/helix/browser/helixEngine.zig` — state machine,
  selections, edits, registers, search and prompts.
- `src/vs/workbench/contrib/helix/browser/helixExtension.zig` — built-in
  extension adapter and per-model engines.
- `src/vs/workbench/contrib/helix/browser/helixRuntime.zig` — enable/disable
  commands and persisted `helix.enabled`.
- `src/tui/app.zig` — startup selection and the single active modal host.

Tests:

- `src/vs/editor/contrib/helix/test/browser/helixEngine.test.zig`
- `src/vs/workbench/contrib/helix/test/browser/helixExtension.test.zig`
- `src/vs/workbench/contrib/helix/test/browser/helixRuntime.test.zig`
- `src/vs/editor/contrib/helix/test/browser/helixCassette.test.zig`

Run the focused suite with:

```sh
zig build test-helix
```

## Reference cassettes

Unlike Neovim, Helix has no embeddable RPC. The cassettes in
`test/data/oracle/` are therefore generated **only in GitHub Actions** from the
pinned `helix/` submodule: `.github/workflows/record-cassettes.yml` applies
`scripts/oracle/helix/record.patch`, runs Helix's own integration harness, and
uploads the JSON artifact for review and commit. Helix is never built on a
developer machine.

`helixCassette.test.zig` replays the committed data against the native engine
via `zig build test` / `zig build test-oracle`. The first corpus covers ASCII
documents, a single starting cursor, final normal mode, and the selection
count. Helix selection ranges and registers are recorded raw but not asserted
yet. See [scripts/oracle/README.md](../scripts/oracle/README.md) for the
`check`/`record` workflow and artifact flow.

The cassette suite is strict: every recorded cursor and, when present, every
cursor position in a multi-cursor set is asserted. `zig build test-oracle` is a
separate test binary from `zig build test`; its CI job is allowed to fail until
the native engine divergences it exposes are fixed. No cases or cursor
assertions are excluded. Helix selection ranges and registers are recorded raw
but not asserted yet.

Tutor coverage is tracked explicitly. Covered: basic `hjkl`, character and
multi-cursor deletion, insert/append/open variants, line selection/delete,
change, replace, text objects, registers, surround, search selection, and
multi-cursor edits. Still uncovered or known-divergent: select/extend and
collapse mode, counts with cursor assertions, undo cursor restoration, copy
selection to next line (`C`), split selections on lines, regex selection,
join/indent/increment, macros, match mode, comments, and the window/split
chapters. Those are engine gaps or UI-only features, not silently skipped
requirements.
