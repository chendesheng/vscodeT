# Native Vim

Vim is a compiled-in built-in extension (`vscode-textbuffer.vim`). It does not
run in the Node extension host and does not load VSCodeVim.

Vim and the native Helix built-in (`docs/helix.md`) are mutually exclusive:
enabling one disables the other for the session and persists the other setting
off. Only one modal built-in consumes terminal keys at a time.

## Enable

Add to the user settings file:

```json
{
  "vim.enabled": true
}
```

The setting is read at startup, before the Node host starts. VSCodeVim is not
discovered or loaded regardless of whether it is installed.

Vim can also be enabled after the editor starts. The product composition root
registers two commands:

- `Vim: Enable` (`vim.enable`)
- `Vim: Disable` (`vim.disable`)

They are available from the command picker (`Ctrl-Shift-P`). Both commands
write `vim.enabled` to the user settings file (the same file opened by
`Open User Settings (JSON)`), so the choice survives a restart.

## Editor state ownership

The Vim engine keeps only Vim command state: pending count/operator, registers,
search pattern, mode and pending prefixes. Everything else belongs to the
editor:

- `u` / `Ctrl-R` call `Editor.undo()` / `Editor.redo()`.
- An insert session or an operator change is one editor undo group. The engine
  brackets it with `Editor.beginUndoGroup()` / `endUndoGroup()`.
- `j` / `k` call `Editor.moveLogicalLine`, which uses the cursor's
  `leftoverVisibleColumns`. The remembered column survives short lines, tabs and
  wide characters. At the first/last line the motion is a no-op (as in
  VSCodeVim), so a repeated `k`/`j` does not clear the remembered column.
- Visual selections are the editor's `Selection` values.
- Insert-mode typing, editing, and navigation use the regular editor key
  dispatch. This gives Insert mode the same suggestions, snippet navigation,
  auto-closing pairs, and auto-indent as editing with Vim disabled.

There is no separate diff-based undo history and no Vim-owned desired-column
field.

## Supported surface

Normal/edit:

- Modes: normal, insert, replace, visual character/line/block, operator
  pending, command line, `/` and `?` search prompts.
- Counts, `h j k l`, `w W b B e E`, `0 ^ $`, `gg G`, `f F t T ; ,`,
  `{`/`}`, `+`/`-`/`_`, `H`/`M`/`L`, `gj`/`gk`.
- Operators `d c y`, `>`/`<` indentation, `f`/`t` operator motions,
  doubled linewise forms (`dd`, `cc`, `yy`), `x X s S D C Y`.
- `i I a A o O`, `p P`, `r`, `~`, `J`/`gJ`, `Ctrl-A`/`Ctrl-X`.
- Registers: unnamed and named (`"a`–`"z`).
- Macro recording/replay (`q{a-z}`, `@{a-z}`, `@@`) with a recursion guard.
- Text objects: `iw aw iW aW`, `i(`/`a(`/`ib`/`ab`, `i[`/`a[`,
  `i{`/`a{`, and `i"`/`a"`, `i'`/`a'`, `` i` ``/`` a` ``. `i<`/`a<` work only
  when the language configuration declares `< >` (plaintext declares
  `()[]{}`). Bracket text objects and `%` use the editor's token-aware
  bracket-pair AST, so brackets inside comments and strings are skipped.
- `%`, `(`, `)`, `g_`, `g0`/`g^`/`g$`, `*`/`#`, `U`, `gv`, `gi`, and `.`
  dot-repeat for the last change. Local marks use `m` and the mark-jump
  keys. Visual-block `I`/`A` prefix/suffix every selected line in one undo
  group. `Ctrl-O`/`Ctrl-I` use the workbench editor navigation history.
- Visual character/line/block operators and `o` to swap the selection anchor.
- `u`, `Ctrl-R`.
- Insert mode: text, Enter, Tab, Backspace, Delete, arrows, `Ctrl-W`, `Ctrl-U`,
  `Ctrl-R` register insert, `Esc`.

Command surface:

- `/`, `?` incremental search through the editor model. While the prompt is
  edited, the cursor previews the first match after the prompt-start cursor and
  every match is highlighted with the Ctrl+F find-match colors (`incsearch` +
  `hlsearch`). `Enter` commits the pattern (a count before `/`/`?` commits to
  the count-th match), `Esc` restores the cursor and the previous pattern's
  highlights. `n`, `N` move through matches and move the current-match
  emphasis; `:noh`/`:nohlsearch` (any unambiguous prefix, like Vim) stops
  painting the highlights but keeps the pattern, so `n`/`N` keep searching and
  turn the paint back on; `*`/`#` highlight every occurrence of the word under
  the cursor. `:set regex`/`:set noregex` selects regex or literal matching.
- `:w`, `:q`, `:q!`, `:wq`, `:e`, `:bn`, `:bp`, `:bd`, `:sp`, `:vsp`,
  `:noh`/`:nohlsearch`, `:set ignorecase`/`:set noignorecase`, line jumps and
  `:$`.
- `gd`, `gD`, `gh`, `gO`, `gf`, `Ctrl-]`.
  `gh` opens the hover at the cursor. Editor keydown listeners run before Vim,
  so the next key dismisses the hover before Vim executes its command; a motion
  key both hides the popup and moves the cursor.
- `zz`, `zt`, `zb`, fold commands through the editor command registry; each
  viewport command centers or aligns relative to the cursor, not the current
  top line.
- `Ctrl-E/Y/D/U/F/B` scrolling.
- `<C-w>` window prefix and `gt`/`gT`.
- `:` and `/` prompts render in the Vim status entry.

## Editor navigation history

`Ctrl-O` and `Ctrl-I` use the ported VS Code editor navigation history, not a
Vim-owned jump stack:

- `IHistoryService`-shaped `goBack`/`goForward` exposed through the built-in
  extension API.
- `EditorNavigationStack` stores group, path, pane selection and viewport.
- Separate `NONE`, `EDITS` and `NAVIGATION` filtered stacks.
- Default, per-editor-group and per-editor scoped stacks.
- The stack is persisted under the user-data directory in `history.json` and
  reloaded on startup; stale paths are ignored.
- Recently closed editors (up to 20) are recorded and can be reopened through
  `workbench.action.reopenClosedEditor`. Closing a group in one operation keeps
  a shared batch id.

Vim records jump points explicitly (`G`, `gg`, `%`, paragraphs, `H`/`M`/`L`,
search, marks and definition jumps) before moving. Plain horizontal/word
motions do not enter the history.

The full upstream history service also tracks selection reason events and
persisted recent-file history. This port implements the pane-selection
abstraction and event source, the filtered/scoped stacks and JSON persistence;
it does not port upstream's SQLite storage or cross-window propagation.

## Deliberate non-goals

- Vimscript evaluation, `.vimrc`, plugins and Neovim integration.
- Global marks. Local marks are supported.
- Multi-cursor operators.
- System clipboard registers fall back to the unnamed register.

These are documented gaps, not hidden behavior. Do not add VSCodeVim back as a
fallback; extend the native engine instead.

## Layout

- `src/vs/editor/contrib/vim/browser/vimEngine.zig` — state machine and edits.
- `src/vs/workbench/contrib/vim/browser/vimExtension.zig` — built-in extension
  adapter.
- `src/vs/workbench/api/common/extensionApi.zig` — extension-facing interfaces.
- `src/vs/workbench/api/common/keyInput.zig` — generic key-input registry.
- `src/vs/workbench/api/browser/builtinExtensionHost.zig` — host adapters.

Tests:

- `src/vs/editor/contrib/vim/test/browser/vimEngine.test.zig`
- `src/vs/workbench/contrib/vim/test/browser/vimExtension.test.zig`

## Reference cassettes

`src/vs/editor/contrib/vim/test/browser/vimCassette.test.zig` replays JSON
cassettes recorded from a real Neovim by `scripts/oracle/record_nvim.py`
(pinned release in `scripts/oracle/nvim/PIN`, currently `v0.10.4`). The data
lives in `test/data/oracle/`. Replay is hermetic, needs no Neovim, and runs
via `zig build test-oracle` (both lanes) or `zig build test-oracle-vim` (this
lane only).

The corpus covers ASCII documents, one cursor, and final normal, insert and
replace modes; the 329 cases are green and gate CI. Visual selections are not a
recorded final mode, and register contents are checked through their resulting
text rather than as raw register state. To
refresh or add recordings, see [scripts/oracle/README.md](../scripts/oracle/README.md):
install the pinned Neovim, run the recorder, and regenerate the embedded index.
The same recording/check also runs in the `Record cassettes` GitHub workflow.
