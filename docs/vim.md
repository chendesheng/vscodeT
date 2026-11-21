# Native Vim

Vim is a compiled-in built-in extension (`vscode-textbuffer.vim`). It does not
run in the Node extension host and does not load VSCodeVim.

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
registers three commands:

- `Vim: Enable` (`vim.enable`)
- `Vim: Disable` (`vim.disable`)
- `Vim: Toggle` (`vim.toggle`)

They are available from the command picker (`Ctrl-Shift-P`). The commands are
session-only: they do not rewrite the `vim.enabled` setting. With the setting
left at `false`, Vim starts disabled again on the next launch. With it set to
`true`, Vim starts enabled and the same commands can still toggle it.

## Editor state ownership

The Vim engine keeps only Vim command state: pending count/operator, registers,
search pattern, mode and pending prefixes. Everything else belongs to the
editor:

- `u` / `Ctrl-R` call `Editor.undo()` / `Editor.redo()`.
- An insert session or an operator change is one editor undo group. The engine
  brackets it with `Editor.beginUndoGroup()` / `endUndoGroup()`.
- `j` / `k` call `Editor.moveLogicalLine`, which uses the cursor's
  `leftoverVisibleColumns`. The remembered column survives short lines, tabs and
  wide characters.
- Visual selections are the editor's `Selection` values.
- Insert-mode text goes through `Editor.typeCharacter`/`newline`, so
  auto-closing and auto-indent continue to work.

There is no separate diff-based undo history and no Vim-owned desired-column
field.

## Supported surface

Normal/edit:

- Modes: normal, insert, visual character/line, operator pending, command line,
  `/` and `?` search prompts.
- Counts, `h j k l`, `w W b B e E`, `0 ^ $`, `gg G`, `f F t T ; ,`.
- Operators `d c y`, doubled linewise forms (`dd`, `cc`, `yy`), `x X s S D C Y`.
- `i I a A o O`, `p P`, `r` (pending), `~`, `J`.
- Registers: unnamed and named (`"a`–`"z`).
- Text objects: `iw aw iW aW`.
- Visual character/line operators and `o` to swap the selection anchor.
- `u`, `Ctrl-R`.
- Insert mode: text, Enter, Tab, Backspace, Delete, arrows, `Ctrl-W`, `Ctrl-U`,
  `Ctrl-R` register insert, `Esc`.

Command surface:

- `/`, `?`, `n`, `N` literal search through the editor model.
- `:w`, `:q`, `:q!`, `:wq`, `:e`, `:bn`, `:bp`, `:bd`, `:sp`, `:vsp`, `:noh`,
  `:set ignorecase`/`:set noignorecase`, line jumps and `:$`.
- `gd`, `gD`, `gh`, `gO`, `gf`, `Ctrl-]`.
- `zz`, `zt`, `zb`, fold commands through the editor command registry.
- `Ctrl-E/Y/D/U/F/B` scrolling.
- `<C-w>` window prefix and `gt`/`gT`.
- `:` and `/` prompts render in the Vim status entry.

## Deliberate non-goals

- Vimscript evaluation, `.vimrc`, plugins and Neovim integration.
- Macro recording/replay (`q`/`@`), marks and the jumplist.
- Visual block, replace mode (`R`), multi-cursor operators.
- Full regular-expression search; search is literal until a later phase.
- `%`, `>`/`<`, `U`, `gv`, `gi`, `f`/`t` as operator motions and full
  regular-expression search are not implemented yet.
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
