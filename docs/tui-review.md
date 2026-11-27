# `src/tui` review: what to port, what to move to `ui`, what to delete

**Current Workbench architecture:** `src/vs/workbench/browser/workbench.zig` owns the portable Workbench startup, Layout, registered parts, notifications and lifecycle. `src/tui/workbenchWindow.zig` owns the native TerminalWorkbench window and remaining service/feature adapters; `src/tui/workbenchServices.zig` constructs the native service contracts; `src/tui/workbench.zig` owns the terminal event loop, rendering, and input. No production feature imports the portable Workbench or the native window. The old workbench polling methods are replaced by events and I/O readiness/deadline adapters. Outline editor subscriptions follow the view body visibility and active/visible-editor events, without render-time synchronization. ViewsService resolves registered views, active composites and body visibility through the layout and descriptor services. Sidebar title-area events drive the active toolbar. The legacy command table has been replaced by owner Action2 registrations. Layout supports all four panel positions, panel alignment and maximization. See the [Workbench port audit](workbench-audit.md) for the live architectural boundaries and remaining port omissions.

This review records the 2026-11-19 working tree. The subsequent workbench split,
service boundaries, test moves and remaining work are tracked in the
[workbench port audit](workbench-audit.md).
The latest extraction also puts terminal tab/sash/quick-input routing and image capability changes in the native host. Notification model, service, center, toast, status and message bridge now follow their upstream owners. The dialog queue, extension modal prompts and editor close confirmation also live with their upstream owners.
The editor and diff panes now receive the native editor view through explicit factories; the src/vs → src/tui import boundary has no exceptions.
This supersedes the snapshot and file table in
[`porting-inventory.md`](porting-inventory.md) §0 and §7; that document's
subsystem notes and test map are still useful, but its line numbers, file count
and "remaining" verdicts are stale.

- `src/tui/`: **37 files, ~28,100 lines** at audit start. Roughly 8,000 of
  those are inline `test` blocks (approximate: `editor.zig`, `workbench.zig`
  and `session.zig` interleave production code after the first test, so a
  first-test split undercounts production by ~550 lines).
- `src/vs/`: 676 Zig files, 192,332 lines.
- `ui/`: 22 Zig files, 15,085 lines.
- Upstream: VS Code **1.147.0**, `vscode/` at `e31c2e52`.

## Update (2026-11-21): scroll pipeline

The scroll path now follows the upstream flow instead of rebuilding the view on
every scroll. `Editor` owns a line-granular `common/viewLayout/viewLayout.zig`
(port of `viewLayout.ts` on the ported `LinesLayout`/`Scrollable`), the wheel is
handled by the ported `EditorScrollbar` part with upstream sensitivity/fast
scroll, `TerminalViewHost.renderViewport` takes the visible range from the view
layout, and `ViewLines` re-renders only lines dirtied by view events. Status
bar, side-bar title and panel title retain their painted grids while unchanged,
and the Unicode line-break tables are compile-time constants. The editor
viewport now keeps a retained, windowed DOM: only the visible `ViewLine`
elements exist, a scroll moves them by updating the box geometry (no text
re-render, no document clear), and dirty lines rewrite only their own text
children. Text runs share interned `PaintStyle` objects. The remaining
editor-refresh cost is the per-frame gutter/scrollbar/status DOM rebuild; see
[`perf/2026-11-21/README.md`](perf/2026-11-21/README.md).

## Consolidation progress (2026-11-19)

- Git/SCM/quick diff/diff editor: added the read-only Git service + CLI
  delegate, SCM service/provider/view, quick-diff model/decorator/controller,
  aligned diff view model/widget/decorations and the terminal diff tab. The
  remaining gap is the documented read-only scope (no staging/commit,
  inline/hidden-region/moved-block/peek/multi-diff, editable or serialized diff
  tabs) and the single-repository terminal simplification.

The consolidation is complete: **`src/tui/` is now the 2-file process host**
(`app.zig` + `tui.zig`, 2,391 lines) from the original 37 files / ~28,100
lines. The audit table above and the per-file notes are the starting snapshot;
they are kept as the rationale for where each piece went.

- **Host files:** `app.zig` (CLI/boot/event loop/frame output/preview/input
  bridges) and `tui.zig` (raw mode, size, poll/read, SIGWINCH, panic).
- **Ported/relocated:** editor widget + terminal view, editor pane and input,
  workbench shell, extension host adapter, search view/widget, explorer view,
  quick input/access, command table, keybinding service, activity rail, tab
  strip, file index, settings watcher, bundled languages, session host, theme
  loader, file logger, terminal input/renderer/tabbed view, hover fallback,
  working-copy adapter.
- **Deleted:** dead ANSI tokenizer, UTF-8 helper (moved to
  `base/common/strings.zig`), token-color wrapper, preview renderer (now
  `View`), language-configuration workaround, file badges (folded into the tab
  strip), cell-border probe (moved to `ui`).
- The remaining `src/vs` files with `Terminal` in the name are deliberate
  terminal adaptations of their upstream counterparts; they are the merge
  targets for the next iteration (port `ICodeEditor`, `ViewParts`,
  `ObjectTree` search results, `ContentWidgets`).
- Verification: `zig build` and `zig build test --summary all` pass
  (2,280 passed / 12 skipped in the final run).

No runtime code was changed for this review. Every line range is from this
snapshot, not the older inventory. The working tree has uncommitted changes
(including `app.zig`, `extensions.zig` and `workbench.zig`, plus files being
edited concurrently); the audit uses those working-tree contents.

## 0. Executive summary

The terminal tree is no longer mostly terminal host. Roughly **four fifths of
the non-test code has an upstream VS Code counterpart** and should live under a
mirrored `src/vs/...` path, or is generic terminal UI that belongs in `ui/`.
Only the process/terminal host is irreducibly `src/tui/`.

The biggest problem is not a missing port, it is a **second editor runtime**:

- `src/tui/editor.zig` (~3,000 production lines) is not a widget; it owns the model,
  view model lines, cursor controller, command wrappers, folding, multicursor,
  status contribution, file save/reload and working-copy listeners.
- `src/tui/editorView.zig` (2,043 code lines) collapses `View`, `ViewLayer`,
  `ViewOverlays` and fourteen view parts into one rebuild-and-paint function.
- The real ports already exist under `src/vs/editor/browser/`:
  `widget/codeEditor/codeEditorWidget.zig` (215), `view.zig` (385),
  `view/viewController.zig` (343), `view/viewLayer.zig` (486),
  `viewParts/viewLines/viewLines.zig` (434), `viewLine.zig` (289), and
  `config/editorConfiguration.zig` (394). **No TUI code imports them**; the
  widget/view have only their own two tests, and `viewController.zig` has no
  importer and no tests at all. Conversely, seven production contribution
  files under `src/vs/editor/contrib/` import `src/tui/editor.zig`, because
  there is no `ICodeEditor` contract to depend on.

That inversion is the thing to fix first: it is what keeps the editor files in
`src/tui/`, and it means the "ported" contributions are not reusable outside
the TUI.

Next largest: **three command/keybinding layers** (`editor.zig` action table,
`workbench.zig` command table, `commands.zig` metadata table, plus the key
switch in `app.zig`) all bypass the ported `EditorActionRegistry`, `Action2` /
`MenuRegistry`, `MenuService` and `AbstractKeybindingService`.

Direct duplication that can be deleted (two entries need the small port named
in the bullet):

- `src/tui/ansi.zig` is dead: **zero imports**, not registered in `tests.zig`;
  `ui/src/terminal/ansi.zig` (encoding) and `ui/src/terminal/input.zig` (decoding) replaced it.
- `src/tui/preview.zig` is a second, weaker view renderer (gutter, tokens,
  status) for `--preview`; upstream has no preview view. Fold the mode into
  `View`/`Editor` with `readOnly`.
- `src/tui/editorInput.zig` duplicates the already-ported
  `src/vs/workbench/contrib/files/browser/editors/fileEditorInput.zig` (386
  lines) and its serializer, with a different type id.
- `src/tui/workingCopy.zig` duplicates `textFileEditorModel.zig` (358 lines).
- `src/tui/languageConfiguration.zig` exists only because the concrete upstream
  `LanguageConfigurationService` was not ported and the interface has no
  context pointer; it works around that with a global `active_service`.
- `src/tui/theme.zig` and ~200 lines of the legacy loader in
  `src/tui/syntaxTheme.zig` duplicate the ported theme service and the
  upstream `standaloneThemeService` token-theme application.
- `src/tui/utf8Helper.zig` is imported by the **editor core**
  (`textModelSearch.zig`, `pieceTreeTextBuffer*.zig`): the dependency direction
  is backwards.

Target shape after the roadmap:

```
src/vs/editor/browser/...        ported editor widget/view/controllers on ui
src/vs/workbench/browser/...     ported workbench shell/parts/actions
src/vs/workbench/contrib/...     ported views/widgets (explorer/search/tabs)
src/tui/                         ~5-7 host files: app, tui, extensions,
                                 hover fallback, log/session/asset file hosts
ui/                              terminal DOM/layout/paint + generic widgets
```

### Top moves at a glance

| # | Move | Why it matters | `src/tui` lines out (est.) |
| ---: | --- | --- | ---: |
| 1 | Define `ICodeEditor`; decouple find/suggest/snippet/wordHighlighter from `tui/editor.zig` | Unblocks the whole editor move; removes the host->contribution inversion | 0 now, ~3,000 unlocked |
| 2 | Move `view.zig` into `editor/browser/view.zig` + `viewParts/*`; add line decorations to `viewLineRenderer` | Deletes the 1,400-line rebuild/paint pass and the unused-stack duplication | ~2,000 |
| 3 | Move `editor.zig` into `codeEditorWidget`/`coreCommands`/contributions | Deletes the second editor runtime and 357 lines of action/keybinding tables | ~2,700 |
| 4 | Replace the three command tables with `Action2`/`MenuRegistry` + keybinding rules | One dispatch path; fixes diverged bindings | ~900 |
| 5 | Build search on `ObjectTree` and move the view/renderer to `contrib/search` | Deletes the invented flatten/selection/collapse/scroll viewport | ~1,000 |
| 6 | Move `tabBar`/`activityBar`/`workbench` parts+actions to mirrored parts | Parts own their view and actions, as `statusbarPart` already does | ~1,500 |
| 7 | Move the actor state out of `extensions.zig` | The header is wrong: ~700 lines are missing `MainThread*` state | ~700 |
| 8 | Delete dead/duplicate leaves: `ansi`, `preview`, `theme`, `editorInput`, `workingCopy`, `languageConfiguration`, legacy `syntaxTheme` loader | No new ports needed | ~1,000 |
| 9 | Move `utf8Helper` to `base/common`; move terminal files to `contrib/terminal` | Fixes the dependency direction and finishes the terminal contribution | ~650 |
| 10 | Add `ui/screen`, `ui/cell_border` probe, `ui/text`, `ui/scrollbar` helpers | Removes the copy-paste UI code from the host | ~500 |

## 1. Decision rules used here

Every file was read for its file header, public surface and its non-obvious
behaviour, then checked against the upstream file it names and against the
existing ports under `src/vs/`.

| Destination | Rule | Precedent already in the tree |
| --- | --- | --- |
| `src/vs/...` mirrored path | The behaviour exists in VS Code, including view logic and widgets. Terminal cells replace DOM/CSS, but the decision logic keeps the upstream file and names. | `workbench/browser/parts/statusbar/statusbarPart.zig` (716 lines) renders a `ui` surface; `editorGroupView.zig` keeps tab state and hit rectangles; `breadcrumbsControl.zig` draws itself; 40 files under `src/vs` import `ui`. |
| `ui/` | Generic terminal capability with no VS Code semantics: screen control, cell-border protocol, text drawing, scrollbar geometry, reusable form/overlay primitives. | `ui/src/widgets/inputbox.zig`, `ui/src/widgets/dialog.zig`, `ui/src/widgets/scroll_view.zig`, `ui/src/terminal/ansi.zig`. |
| `src/tui/` | Process/terminal host only: CLI, raw mode, read/poll loop, signals, frame output, platform paths, spawning the extension host, and explicitly TUI-only fallbacks. | `tui.zig` raw mode/poll, `app.zig` CLI and loop. |

The repo's long-term architecture in `docs/terminal-ui.md` says the same thing:
`src/vs/editor/browser/...` holds ported UI code, `src/tui/...` is the host, and
`ui/` is the standalone library.

A file is **not** kept in `src/tui/` merely because it paints cells. Painting
cells through `ui` is already a `src/vs` pattern. It stays only when it has no
upstream counterpart and is not a generic UI capability.

## 2. File-by-file inventory

`lines` is the whole file at audit start, including its inline `test` blocks
(tests are not separated in this table; §6 discusses them). The working tree is
being edited concurrently, so individual totals can drift by a few lines. "Delete" means the file
disappears; "Move" means the code is re-homed and the file disappears; "Split"
means a smaller host file remains; "Keep" means it stays.

| File | lines | Verdict | Destination |
| --- | ---: | --- | --- |
| `workbench.zig` | 6,676 | **Split** | parts, actions, terminal/close-quit/outline/status modules; host shell remains (cell layout stays host) |
| `editor.zig` | 4,623 | **Split** | `editor/browser/widget/codeEditor/codeEditorWidget.zig`, `view/viewController.zig`, `browser/coreCommands.zig`, contributions; file host remains |
| `view.zig` | 3,561 | **Move** | `editor/browser/view.zig` + `viewParts/*` |
| `app.zig` | 1,875 | **Split** | key dispatch → `coreCommands`/keybinding; host boot/loop remains |
| `extensions.zig` | 1,698 | **Split** | missing `workbench/api/browser/MainThread*` host contracts; TUI adapter remains |
| `searchView.zig` | 1,459 | **Move** | `contrib/search/browser/searchView.zig` + `searchResultsView.zig` (ObjectTree) |
| `explorerTreeSidebar.zig` | 916 | **Move** | `contrib/files/browser/views/explorerView.zig` + `explorerViewer.zig` |
| `syntaxTheme.zig` | 556 | **Split** | `editor/standalone/browser/standaloneThemeService.zig`; asset reader host; delete legacy loader |
| `preview.zig` | 510 | **Delete** | read-only `Editor`/`View`; tests move to `View` |
| `fileIndex.zig` | 487 | **Split** | `workbench/services/search/common/searchService.zig` (`fileSearch`); ~120-line `std.Io` walker stays |
| `searchWidget.zig` | 472 | **Move** | `contrib/search/browser/searchWidget.zig`; generic rows → `ui/form.zig` |
| `quickInput.zig` | 463 | **Move** | `platform/quickinput/browser/quickInputList.zig`; input row/overlay host remains |
| `tui.zig` | 439 | **Split** | screen sequences → `ui`; raw mode/poll/size/signal stays |
| `quickAccess.zig` | 422 | **Move** | `workbench/browser/quickaccess.zig`; composition/poll host remains |
| `tab.zig` | 323 | **Move** | `workbench/browser/parts/editor/editorPane.zig` + `codeEditorContributions.zig` |
| `tabBar.zig` | 369 | **Move** | `workbench/browser/parts/editor/multiEditorTabsControl.zig` (+ `editorTabsControl.zig`) |
| `keybindingService.zig` | 276 | **Move** | `workbench/services/keybinding/browser/keybindingService.zig` |
| `session.zig` | 298 | **Split** | memento/DTO → `editorPart.zig`/`editorGroupsService.zig`; file host remains |
| `editorInput.zig` | 242 | **Delete** | merge into ported `contrib/files/.../fileEditorInput.zig` |
| `terminalInput.zig` | 255 | **Move** | `contrib/terminal/browser/terminalInput.zig` |
| `ansi.zig` | 237 | **Delete** | dead; `ui/src/terminal/ansi.zig` + `ui/src/terminal/input.zig` cover it |
| `utf8Helper.zig` | 199 | **Move** | `base/common/strings.zig` (Zig-only UTF-8 helpers) |
| `language.zig` | 156 | **Move** | `workbench/services/language/common/bundledLanguages.zig` (bundled subset) |
| `terminalView.zig` | 127 | **Move** | `contrib/terminal/browser/terminalRenderer.zig` |
| `terminalPanel.zig` | 180 | **Move** | `contrib/terminal/browser/terminalTabbedView.zig` + `terminalTabsList.zig` |
| `activityBar.zig` | 146 | **Move** | `workbench/browser/parts/activitybar/activitybarPart.zig` + `compositeBar.zig` |
| `keybindings.zig` | 105 | **Move** | fold the `KeyEvent`→`IKeyboardEvent` mapping into the host keybinding adapter; delete `dispatchString` |
| `logger.zig` | 151 | **Split** | `platform/log/common/fileLog.zig`; ~40-line path/open host remains |
| `languageConfiguration.zig` | 146 | **Delete** | concrete `LanguageConfigurationService` + context in `editor/common/languages/languageConfigurationRegistry.zig` |
| `commands.zig` | 167 | **Delete** | `Action2`/`MenuRegistry` + `CommandRegistry.getCommands` |
| `theme.zig` | 23 | **Delete** | `TokenizationRegistry`/theme service helper |
| `fileIconThemeData.zig` | Moved | Theme service | Resolves contributed file icon definitions for terminal glyphs |
| `workingCopy.zig` | 70 | **Delete** | `textFileEditorModel.zig` adapter |
| `hoverProvider.zig` | 175 | **Keep** | TUI-only word/token fallback; documented |
| `cellBorders.zig` | 61 | **Move** | probe state machine → `ui/src/render/cell_border.zig`; app drives it |
| `terminalView.test.zig` | 29 | **Move** | with `terminalRenderer.zig` |
| `settingsWatcher.zig` | 145 | **Move** | `workbench/services/configuration/browser/configurationService.zig` |

Twenty-six files disappear outright (19 move, 7 delete). Nine become smaller
host files (`workbench`, `editor`, `app`, `extensions`, `syntaxTheme`,
`fileIndex`, `tui`, `session`, `logger`), and two stay documented
TUI-only (`hoverProvider`, `fileIcon`). The end state after P6 is ~6-8 host
files because the host halves of `editor`/`workbench` collapse into `app`/
`workbench`/`extensions` as their behavior moves. Several test sections are
upstream-behavior tests and must move with their subject to mirrored
`test/...` paths (see §6).

## 3. Headline findings (with evidence)

### 3.1 The contributions depend on `src/tui/editor.zig`, not on an editor contract

Production imports of the host editor:

```
src/vs/editor/contrib/find/browser/{findController,findModel}.zig
src/vs/editor/contrib/snippet/browser/snippetSession.zig
src/vs/editor/contrib/suggest/browser/{suggestController,suggestModel,suggestOvertypingCapturer}.zig
src/vs/editor/contrib/wordHighlighter/browser/wordHighlighter.zig
```

Eight test files do the same. `src/vs/editor/browser/editorBrowser.zig` has
widget contracts (`IOverlayWidget`, `IContentWidget`) but **no `ICodeEditor`**.
The contributions were therefore written against the concrete terminal
`Editor`, which is why they cannot be tested or reused without the TUI.

This is the root cause of the editor split:

- `editor.zig` is the only editor runtime; the ported `codeEditorWidget.zig`
  cannot host them.
- The 215-line `codeEditorWidget.zig` only renders, focuses and sets
  selections. It does not own the cursor/contribution/command surface.
- Moving `editor.zig` without first defining the interface would break
  `find`, `suggest`, `snippet` and `wordHighlighter`.

**Fix before moving the editor:** port the upstream `ICodeEditor` surface used
by these contributions into `editorBrowser.zig` (upstream `editorBrowser.ts`),
make `Editor` implement it via `interface()`, then swap the imports. The interface should carry model access,
selection get/set, reveal range, decoration access, `executeCommands`, layout
info and the cursor/content/save events actually used.

### 3.2 Two editor stacks, and the real one is unused

`src/vs/editor/browser/` already contains a faithful, terminal-shaped stack:

| Port | Lines | Used by TUI? |
| --- | ---: | --- |
| `widget/codeEditor/codeEditorWidget.zig` | 215 | no |
| `view.zig` (View skeleton, parts, overlays) | 385 | no |
| `view/viewController.zig` | 343 | no (and no tests) |
| `view/viewLayer.zig` (`RenderedLinesCollection`, `VisibleLinesCollection`) | 486 | no |
| `viewParts/viewLines/viewLines.zig` | 434 | no |
| `viewParts/viewLines/viewLine.zig` | 289 | no |
| `config/editorConfiguration.zig` | 394 | no |

Meanwhile `view.zig` uses only two of the ported browser view parts
(`decorationsOverviewRuler.render`, `indentGuides.getBracketGuides`; it does
use the shared line renderer and decoration helpers) and re-implements the
rest. It rebuilds every gutter cell, line, guide, selection,
scrollbar row and widget subtree on each `refresh` (`rebuild`, lines 884-1263),
instead of a `ViewLayer` + `ViewPart` render cycle. The file header says the
split is "until the view model is ported"; the view model **is** ported
(`common/viewModel/viewModelImpl.zig`, 757 lines).

Concrete consequence: `viewLineRenderer.renderLine` still takes no line
decorations (`RenderLineInput` has no `line_decorations`), so `view.zig` must
re-apply decoration classes itself (`markDecorations` 1265-1317,
`appendModelInlineDecorations` 1961-2002). Upstream applies them inside
`_applyInlineDecorations` in `viewLineRenderer.ts`. Porting that input field
removes the side channel and fixes overlap/order behavior.

### 3.3 Three command layers and several key paths

| Layer | Location | Size | Upstream counterpart |
| --- | --- | --- | --- |
| Editor action table + 65 `cmd_*` trampolines + 67 keybinding rules | `editor.zig:4146-4502` | 357 lines | `editor/browser/editorExtensions.ts` `registerEditorAction`, `browser/coreCommands.ts`, contribution action classes |
| Editor private `KeybindingService` | `editor.zig:554`, `570-590` | ~40 | Should be the workbench service; editor actions register, not resolve |
| Workbench command metadata table (74 entries) | `workbench.zig:712-791` | 79 lines | `Action2` + `MenuRegistry` + `MenuService` |
| `commands.zig` double registry | `commands.zig:41-116` | 76 lines | `platform/commands/common/commands.zig` + actions metadata |
| Hard-coded key switch | `app.zig:975-1097` | 123 lines | `coreCommands` keybindings dispatched by the keybinding service |

`EditorActionRegistry` (`editor/browser/editorExtensions.zig`) and `Action2` /
`MenuRegistry` (`platform/actions/common/actions.zig`) are fully ported; the
TUI uses neither (`Action2`/`MenuRegistry` are exercised only by their own
tests). `MenuService` is ported and unused by the TUI. `command.get` is dead;
`keybindings.dispatchString` is dead.

This also explains duplicated binding metadata: `inPlaceReplace` deliberately
dispatches `Alt+,`/`Alt+.` because terminals cannot encode the upstream
Ctrl+Shift+Comma/Period chords, but the TUI table and the ported action
metadata both carry keys instead of one adaptation point; insertCursorAbove/
Below rules are duplicated outright.

### 3.4 Two file-editor inputs and two working-copy models

`src/vs/workbench/contrib/files/browser/editors/fileEditorInput.zig` (386
lines) already ports `FileEditorInput` + `FileEditorSerializer`, backed by
`TextFileService` and with upstream type id
`workbench.editors.files.textFileEditor`. `src/tui/editorInput.zig` is a
second input that owns the TUI `Editor` and uses the non-upstream type id
`workbench.editors.files.fileEditorInput`. `workingCopy.zig` then adapts the
same `Editor` to `IWorkingCopy`, duplicating `textFileEditorModel.zig`.

The ownership difference is real (the TUI editor owns model + undo + view), but
the answer is to make the ported input hold the ported editor widget, not to
keep a second input. Until then, the two serializers and type ids must not
both be registered.

### 3.5 The language-configuration service is a workaround

`src/tui/languageConfiguration.zig` is the concrete implementation of
`ILanguageConfigurationService`. `languageConfigurationRegistry.zig` defines the
interface as a vtable **without a context pointer** plus a module-level
`active_service`; the file header admits this. Upstream
`LanguageConfigurationService` is a normal class in
`editor/common/languages/languageConfigurationRegistry.ts` (line 59) and is
constructed by `CodeEditorWidget` (line 283 in
`codeEditorWidget.ts`), not a singleton.

Two fixes, both required by repo rules:

1. Add `context: *anyopaque` to `ILanguageConfigurationService` (AGENTS.md
   interface convention).
2. Port the concrete `LanguageConfigurationService` class (registry, change
   emitter, `register`/`getLanguageConfiguration`) and construct it with the
   editor. Then `languageConfiguration.zig` is deleted.

### 3.6 Dependency inversion: core editor imports `src/tui/`

`utf8Helper.zig` is imported by:

```
src/vs/editor/common/model/textModelSearch.zig
src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeTextBufferBuilder.zig
src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeTextBuffer.zig
src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.zig
```

A text-buffer utility must not live in the host. Move it to
`src/vs/base/common/strings.zig` (append a clearly-marked Zig-only section) or
a `base/common/utf8.zig` with an "adaptation" header. This is a five-line
change plus imports and has no behavioural risk.

### 3.7 `preview.zig` is a second view

`preview.zig` builds its own gutter, token runs and status row on a `ui.Surface`
(332 lines). It duplicates `view.zig`'s paint path with fewer features and
different colors, and its tests assert text output that `View` already covers.
Upstream has no preview view; `--preview` is a host mode. Add a `read_only`
flag to the editor/view, make `Preview` a thin mode wrapper (or delete it and
use `View` with input disabled), and move the rendering tests to `view.zig`.

### 3.8 `ansi.zig` is dead

`src/tui/ansi.zig` tokenizes ANSI sequences (`AnsiToken`, `tokenize`, tests).
Nothing imports it; it is not in `tests.zig`. The replacement is
`ui/src/terminal/input.zig` (decode) and `ui/src/terminal/ansi.zig` (encode). Delete it before doing
anything else.

### 3.9 Theme loading has two implementations

`syntaxTheme.zig` has:

- `initFromThemeService` / `initFromThemeFiles` / `initFromColorThemeData`,
  which use the ported `ColorThemeData` and `ThemeService` correctly; and
- `init` plus `appendTheme` / `appendRule` / `appendScopes` (~200 lines), a
  hand-written JSONC walker over the bundled assets.

The hand-written path duplicates `colorThemeData.zig` and the JSONC strip. It is
only a fallback for the absence of the submodule/theme assets. Since the
submodule is required by CI and the asset reader already has a
`themeData(name)` fallback, delete it.

The upstream home for turning a color theme into a `TokenTheme` and calling
`TokenizationRegistry.setColorMap` is
`editor/standalone/browser/standaloneThemeService.ts` (lines 158, 415), not the
workbench theme service. Port that subset (no DOM/CSS; the token rules are
independent) and let the TUI only choose the theme and feed assets.

### 3.10 UI-library gaps produce copy-paste in the host

Five near-identical `drawText` functions and three scrollbar implementations
live in `src/tui/`:

| Duplicate | Files |
| --- | --- |
| `drawText`/`drawPlainText` | `explorerTreeSidebar.zig:543`, `quickInput.zig:377`, `searchView.zig:1389`, `terminalPanel.zig:154`, `workbench.zig:4547`, plus `tabBar.zig` label drawing and `fileIcon.zig:54` |
| Text width/clip/truncate | `tabBar.zig:73-128`, the `drawText` copies, `ui.paint.drawText` |
| Scrollbar thumb math/paint | `view.zig:1639-1705`, `searchView.zig:1003-1020`, `explorerTreeSidebar.zig:405-431`, `ui/src/widgets/scroll_view.zig` |
| Overlay placement/blit/outside-click | `quickInput.zig:62-169`, `ui/src/widgets/dialog.zig`, `workbench.zig` dialog path |
| Screen control sequences | `tui.zig:132-286` (alt screen, mouse capture, cursor, clear, line wrap, bracketed paste) |

None of these is VS Code-specific. They belong in `ui/` (see §5).

### 3.11 The search view re-implements a tree viewport

`contrib/search/browser/searchResultsView.zig` contains
`SearchViewDataSource.visibleRows` (lines 141-172). This is **not upstream**:
upstream feeds an `ObjectTree`/list widget whose index model flattens,
virtualizes, scrolls, selects and collapses. The TUI then re-implements all of
that in `searchView.zig`:

- `rows`/`depths`/`selected`/`scroll` (136-141, 489-510);
- collapse state in `OwnedStringSet` + `applyDefaultCollapse` (519-547);
- selection/scroll clamping and reveal (548-631);
- mouse row math (916-924);
- scrollbar painting (1003-1020).

`explorerTreeSidebar.zig` already shows the right pattern: drive the ported
`CompressibleObjectTree` and let it own selection/collapse/scroll. Search should
do the same with `ObjectTree`; then `visibleRows`, `OwnedStringSet` and the
selection/scroll code disappear. The same applies to `search.collapseResults`
policy, which belongs with the search view model.

### 3.12 Tests are half of the terminal tree and are misplaced

About 8,000 of the ~28,100 lines are inline tests. The largest trailing test
sections (first-test heuristic; production tables after the first test are
excluded where known):

| File | approximate test lines |
| --- | ---: |
| `workbench.zig` | ~2,000 (+78-line rule/executor block interleaved) |
| `editor.zig` | ~1,600 (+357-line action/keybinding block interleaved) |
| `view.zig` | ~1,500 |
| `app.zig` | ~780 |
| `extensions.zig` | ~500 |
| `explorerTreeSidebar.zig` | ~360 |
| `syntaxTheme.zig` | ~240 |
| `session.zig` | ~250 |

Most of these are upstream-behavior tests (view line rendering, cursor moves,
editor group, keybindings) and must move with their subjects to mirrored
`test/...` paths, per AGENTS.md. `searchView.zig` has **no tests** at all,
which is why its invented flattening went unnoticed; the ported
`searchView.test.ts` and `searchWidget.test.ts` should come with the move.

## 4. Per-file notes

### 4.1 Editor core: `editor.zig`, `view.zig`, `tab.zig`, `preview.zig`

**`editor.zig` (~3,000 production lines, `Editor` 195-2941)**

The struct collapses `CodeEditorWidget`, `ViewModel` cursor ownership,
`CursorsController`, `ViewController`, `EditorStatusContribution`,
`TextFileEditorModel`, the contribution controllers and a service collection.
It does not use the ported `ViewModel` or `View`.

Portable blocks and targets:

| Lines | Behavior | Upstream | Destination |
| --- | --- | --- | --- |
| 108-193, 1891-1965 | replace-command cursor computation, `afterEdit`, type-result execution | `common/cursor/cursor.ts`, `common/commands/commandRunner.ts`, `replaceCommand.zig` | extend `common/cursor/cursor.zig`; reuse `ReplaceCommandWithOffsetCursorState` |
| 281-533 | construction, model/services, cursor setup, controllers | `codeEditorWidget.ts` (`_create`, ctor), `standaloneServices.ts` | extend `browser/widget/codeEditor/codeEditorWidget.zig` + a standalone service helper |
| 534-593 | find hook, shortcut keybindings, dispatch | `contrib/find`, `editorExtensions.ts`, `keybindingsRegistry.ts` | contribution registration; delete the private table |
| 594-795 | JSON attach/sync/format/completion | no upstream `jsonLanguageClient.ts` (invented path); JSON lives in the bundled extension | extension-host/workbench glue; keep out of mirrored editor paths |
| 796-874 | formatter ordering + JSON fallback | `contrib/format/browser/{format,formatActions}.ts` | new `contrib/format/browser/format.zig` |
| 901-1081 | dirty/save listeners, metrics/layout getters | `codeEditorWidget.ts`, textfile model | generic events to widget; dirty/save host |
| 1082-1196 | folding wrappers | `contrib/folding/browser/folding.ts` | extend `folding.zig` |
| 1197-1442 | language/encoding/status target, message | `parts/editor/editorStatus.ts`, `languageService.ts`, `textfile/encoding.ts` | extend `editorStatus.zig` adapter; disk encoding stays host |
| 1443-1586 | viewport/reveal/position math | `browser/view.ts`, `viewController.ts` | terminal geometry stays; portable reveal/hit test to `view.zig`/`viewController.zig` |
| 1587-1676 | multicursor session and commands | `contrib/multicursor/browser/multicursor.ts` | extend `multicursor.zig` |
| 1677-1890 | 16 `move*` wrappers + select all/cancel | `browser/coreCommands.ts` | new `browser/coreCommands.zig` |
| 1966-2141 | typing/newline/tab/outdent/insert line | `cursor.ts`, `cursorTypeEditOperations.ts`, `coreCommands.ts`, `linesOperations.ts` | extend cursor type ops + `coreCommands.zig` |
| 2142-2444 | edit application, indentation, delete, undo/redo, line ops | `codeEditorWidget.ts`, `editorExtensions.ts`, `contrib/indentation`, `contrib/linesOperations` | extend widget + actions |
| 2445-2582 | selection setters, `executeEdits`, `executeCommand` | `codeEditorWidget.ts`, `cursor.ts` | extend widget + `ViewModel.executeEdits` |
| 2583-2820 | line/smart select, in-place replace, bracket, comment, final newline wrappers | the corresponding `contrib/*` action classes | extend those ports; port missing action classes |
| 4146-4502 | 65 action trampolines + 67 keybindings | `registerEditorAction`, contribution actions | register action objects; delete tables |

Dead adapters already present with no callers: `expandLineSelectionAction`,
`smartSelectExpandAction`/`ShrinkSelectionAction`,
`inPlaceReplaceUp/DownAction`; the ported action classes exist. `undo`/`redo`
duplicate the ported commands; `selectAll` duplicates `SelectAllCommand`.
`fileUri` (3000-3015) duplicates `base/common/stdUri.zig`.

The `find` controller imports this file (`findController.zig:16`,
`findModel.zig:37`), as do `suggest`, `snippet` and `wordHighlighter`. That
import is why the editor cannot move and why the ported find/suggest action
classes cannot be registered without a host. It is the first thing P2 fixes.

The file also **imports `./view.zig` in its tests**, so the two test blocks move
together.

**`view.zig` (2,043 code lines, `View` 214-1606)**

Collapsed classes: `View`, `ViewLines`/`ViewLine`, `ViewLayer`,
`ViewOverlays` (content/margin), `CurrentLineHighlight`, `Selections`,
`IndentGuides`, line/margin decorations, `DecorationsOverviewRuler`,
`EditorScrollbar`, `ContentViewWidgets`/`ViewOverlayWidgets`, `ViewCursors`,
`MouseTargetFactory`/`MouseHandler` subset, folding gutter handling, and a
status fallback row that has no `view.ts` counterpart.

It paints correctly, but the whole document is rebuilt in one pass
(`rebuild` 884-1263) and every portable decision is inline. The target is the
existing `browser/view.zig` skeleton plus the existing `viewParts/*`; the
terminal substitutions (cell flags, glyph fallbacks, half-cell overview rows,
scrollbar quadrants, no rounding) stay as documented paint-boundary
adaptations.

Recommended order inside this file:

1. `viewLineRenderer` gains `line_decorations` + class/metadata per part, and
   `ViewLine` applies them. Delete `markDecorations`/`appendModelInlineDecorations`.
2. Port content/overlay widgets into `viewParts/{contentWidgets,overlayWidgets}`.
3. Port `mouseTarget.zig` + `mouseHandler.zig`; keep click synthesis and wheel
   routing in the host.
4. Port `editorScrollbar.zig` + `overviewRuler.zig`; reuse
   `base/browser/ui/scrollbar/scrollbarState.zig`.
5. Port folding decorations into `contrib/folding/browser/foldingDecorations.zig`.
6. Wire the ported `View`/`ViewLayer`/`ViewPart` cycle and feed
   `getViewportViewLineRenderingData`; delete the rebuild loop.
7. Delete the fallback status row once `StatusbarPart` is always used (it is
   disabled by the workbench today).

`View` also owns `ModelDecorationSink` (407-452), a view-level decoration
backdoor. Upstream contributions use model decorations through
`ICodeEditor`/`IEditorDecorationsCollection`; port that instead.

**`tab.zig` (323 code lines)**

Lines 38-158 are the missing `EditorPane` lifecycle (`create`/`setInput`/
`clearInput`/`layout`/`dispose`); 173-283 are the missing
`CodeEditorContributions` host (`initialize`/`get`/`set`). Targets:

- `workbench/browser/parts/editor/editorPane.zig` (new, mirror `editorPane.ts`)
- `workbench/browser/parts/editor/textEditor.zig` / `textCodeEditor.zig`
- `editor/browser/widget/codeEditor/codeEditorContributions.zig` (new)

The lazy-instantiation comment at the top is exactly upstream
`EditorContributionInstantiation`; once `codeEditorContributions.zig` exists,
the `Tab.controllers` struct and the `ensureControllers` wiring go away.
`app.zig` currently has a second copy of the controller construction in its
test section; that disappears too.

**`preview.zig` (332 code lines)**

Delete; see §3.7. Keep a `read_only`/`no_input` mode on the editor and reuse
`View`. The color/gutter/status constants are duplicated from `view.zig`.

### 4.2 Workbench shell: `workbench.zig`, `app.zig`, `tabBar.zig`, `activityBar.zig`, `commands.zig`, keybindings

**`workbench.zig` (~4,700 production lines, `Workbench` 212-3828)**

This is the whole browser workbench window in one struct: part models and
layout, editor group views, tab strip composition, sidebar/search/terminal
hosts, status bar, quick access, breadcrumbs, dialogs, key/mouse routing,
render compositing, file/settings watchers, working copies, extension
configuration and ~74 command wrappers.

Portable blocks:

- **Window/part layout** (`statusBarRect`, `panelRect`,
  `editorAreaX/Width`, `chromeHeight`, `sidebarWidth`, `panelHeight`,
  `layoutAll`, 945-1045, 1690-1732): **keep host.** Upstream
  `workbench/browser/layout.ts` computes pixel/DOM grid geometry; there is no
  portable cell-layout decision to lift. Two cleanups only: `chromeHeight`
  duplicates `EditorGroupView.chromeHeight`, and `layoutAll` already delegates
  to `editorPart.layout`, so the duplicate branch should be deleted. This is a
  legitimate terminal-layout exception, not an unported feature.
- **Command wrappers** (`command*` 4007-4543 + `registerDefaultCommands`
  712-791): replace with `Action2` registrations and contribution action
  classes. The palette should read from `MenuRegistry`/`CommandRegistry`, not
  a parallel `CommandInfo` table. The editor wrappers map to already-ported
  `contrib/*` modules (comment, linesOperations, indentation, folding,
  smartSelect, bracketMatching, multicursor, inPlaceReplace,
  insertFinalNewLine, wordHighlighter, find); file/save/close/split to
  `fileCommands.ts`/`editorActions.ts`; sidebar/status to `layoutActions.ts`/
  `statusbarActions.ts`; terminal to `terminalActions.ts`; search to
  `searchActions*`.
- **Session serialization** (`initFromSerialized*` 384-616): both restore
  constructors duplicate `init` (292-380) almost line-for-line, including the
  tab-materialization loop. Collapse to one constructor and move the grid/DTO
  restore into `editorPart.zig`/`editorGroupsService.zig`; keep the
  `--session` file read/write host.
- **Search host callbacks** (4302-4452): these implement the ported
  `FileContentProvider` (`open_match`, `read_file`, `apply_edits`, ...).
  Retarget `read_file`/`save_file` to the already-ported but unwired
  `textFileService.zig`/`textFileEditorModel.zig`, and move
  `applyClosedFileEdits` into `textFileService.zig`/`replaceService.zig`
  (`offsetAt` is a hand-rolled line/column conversion there).
- **Terminal commands** (1437-1521, 1536-1618): the show/hide/new/kill/focus/
  resize/paste bodies map to `contrib/terminal/browser/terminalActions.ts`.
  Move them to a new `terminalActions.zig`; keep the pty/fd poll/flush methods
  (1653-1688) and the input routing in the host.
- **Outline and breadcrumbs** (3829-3866, 3703-3759, 3545-3769): the outline
  creator is upstream `DocumentSymbolsOutlineCreator` and belongs in
  `contrib/codeEditor/browser/outline/documentSymbolsOutline.zig`; the
  breadcrumb picker construction belongs in `breadcrumbsPicker.zig`. The
  single global `breadcrumbs_control` is a structural adaptation of upstream's
  per-group factory and needs a ported `editorHeaderControl.zig` first.
- **Working copy registration** (1220-1230): move self-registration into
  `textFileEditorModel.zig` (upstream registers there); the shell should not
  own it.
- **Status entries** (3264-3313): the editor-status half is ported; the
  Problems/markers half belongs in a `MarkersStatusBarContributions` port
  (`contrib/markers/browser/markers.contribution.ts`).
- **Key/mouse routing** (`handleGlobalKey`, `handleTabKey`, `handleSidebarKey`,
  `handleStatusbarKey`, `handleSashMouse`, `handleTabDragMouse`,
  2449-3230): the keybinding service should dispatch commands; only focus
  ownership and hit-target synthesis are host. Drag/gesture state stays host;
  its decisions already live in `editorDropTarget.zig`/`editorPart.zig`.
- **Dialogs** (2122-2447): uses `ui.Dialog` and ported `dialogs.zig`, good.
  The close/quit flow is upstream `doHandleCloseConfirmation` +
  `AbstractCloseAllAction`; move the policy into `editorGroupView.zig` + a new
  `editorActions.zig` with a dialog-host callback, keeping only presentation
  in the TUI.
- **`syncSearchActivity`** (3246-3259): no upstream counterpart; keep in the
  host and document as TUI-only.

Target: the `Workbench` struct remains the terminal composition root (upstream
`workbench.ts` + service DI in `main.ts` is likewise composition), but its
parts, actions, terminal commands, close/quit policy, outline creator and
status contributions move to their mirrored modules. The struct should shrink
to service wiring, focus/fd/render host methods and the documented TUI-only
pieces.

**`app.zig` (~1,100 production lines, `main` 163-735)**

The host portion is legitimate: CLI parsing, env paths, extension discovery,
terminal raw mode, theme/session load, event loop, frame encoding, signals.

The portable portion is the fallback key switch (`dispatch`, 975-1097, 123
lines). Navigation and editing already go through the ported keybinding +
command services (`Editor.dispatchShortcut` -> `KeybindingService` ->
`shortcut_specs`), so most arms of this switch are dead fallback; only
`.text`/`.char` typing and `paste_start`/`paste_end` are live. Do **not** port
the switch as-is: port `coreCommands.zig` and delete it, leaving decode +
forward `ui.KeyEvent`. The `runPreview` path (897-958) disappears with
`preview.zig`.

Other portable crumbs:

- `isCtrlQ`/`isCtrlChar` (958-968): the quit chord should be a global
  keybinding rule (`workbench.action.quit`), not a hard-coded byte check.
- `defaultExtensionDataPath`/`defaultUserSettingsPath` (140-161): upstream
  environment/user-data policy (`platform/environment/.../environmentService.ts`);
  extend `environmentService.zig` instead of duplicating XDG paths.
- `handleKeyEvent`/`handleMouseEvent` (736-825): the contribution routing order
  (suggest -> hover -> wordHighlighter -> view -> typing) mirrors
  `CodeEditorWidget._onKeyDown`/`_onMouseDown`; keep host for now, move with the
  widget once `ICodeEditor` exists.
- `syncCursor` (886-895) and the input remainder assembly (578-616) are weak
  `ui` candidates (renderer cursor ownership and a buffered input stream);
  `ui.input` already exposes `decodeWithRemainder`.

`findVimExtension` and the extension-data path logic partially duplicate
`platform/extensionManagement` scanner behavior; keep the process path
resolution but reuse the scanner's folder layout (already imported).

**`tabBar.zig` (282 code lines)**

Portable: tab width (`icon + label + close reserve`), label truncation,
preview italics, dirty dot/close glyph decisions, strip reveal with ellipsis,
hit rectangles (`TabHit` already exists in `editorGroupView.zig`). Upstream
`multiEditorTabsControl.ts` (`redrawTabLabel`, `doRedrawTabActive`,
`doRedrawTabDirty`, `redrawTabAction`, `layout`, `doLayoutTabs`) and
`editorTabsControl.ts` (title height/action space).

Target: move layout/reveal/hit into
`workbench/browser/parts/editor/multiEditorTabsControl.zig` (new) and delete
`tabBar.zig`. Paint can move with it (the `statusbarPart.zig` precedent) or
stay behind a small cell renderer during the transition; the decision logic
must not stay in the host. The strip's RGB constants are theme colors and
should become theme lookups. `TabHit` already exists in
`editorGroupView.zig`; do not keep a second hit model.

**`activityBar.zig` (106 code lines)**

The model is already ported, but it is misnamed: `activitybarPart.zig` holds
activity entries/order/visibility/compact width, while the browser part is the
view. Upstream splits the rail view (`activitybarPart.ts`) from
`compositeBar.ts` (entry rendering) and the activity service (badges).
`activityBar.zig` is the view half: rail hit, glyph centering, active marker,
badge painting.

Move it to `workbench/browser/parts/activitybar/activitybarPart.zig` (view
methods) with entries/badges in `compositeBar.zig`; `default_activities` should
become view-container registrations, not a static host table. This follows the
`statusbarPart.zig` precedent: terminal paint lives in the ported part. If the
part is split first, the minimum is to rename the current model file to
`activitybarModel.zig`/`compositeBar.zig` and keep the view in a mirrored
`activitybarPart.zig`; leaving the model named after the browser view is the
part of this split that is actually wrong.

**`commands.zig` (117 code lines)**

Delete. The `CommandInfo` table duplicates the platform `CommandRegistry`
registration and `MenuRegistry` metadata. Extend
`platform/commands/common/commands.zig` with `getCommands` /
`onDidRegisterCommand` (upstream `commands.ts`), feed
`CommandPickSource` from command service + action metadata, and register TUI
commands as `Action2` with precondition/keybinding metadata. The current header
("this port has no menu or keybinding registry") is stale: both exist and are
ported.

**`keybindingService.zig` (238 code lines)**

This is the workbench keybinding service, not a host helper: default-rule
decode → resolver → `AbstractKeybindingService`, dispatch, resolve callbacks
(58-196). Upstream
`workbench/services/keybinding/browser/keybindingService.ts` (365-390,
442-458, 564-575). Move it to a new mirrored file.

Terminal-only adaptations stay as host callbacks: `bindingOS()` (CtrlCmd →
Ctrl), noop notification service (no chord hint UI), `toKeyboardEvent` from
`ui.input.KeyEvent`, `last_command`.

**`keybindings.zig` (84 code lines)**

Keep the terminal `KeyEvent` → `KeyCode`/`IKeyboardEvent` mapping
(`keyCodeFor`, `charKeyCode`); it has no browser counterpart (xterm boundary).
Delete `dispatchString` (16-32) and its tests: unused, and the logic already
exists in ported `USLayoutResolvedKeybinding.getDispatchStr`. Fold the
remaining mapping into the host keybinding adapter so one file disappears.

### 4.3 Views and pickers: explorer, search, quick open

**`explorerTreeSidebar.zig` (556 code lines)**

Already on the right tree layer (`CompressibleObjectTree`), so this is not a
second tree. Portable residue:

- `loadChildren`/`setChildren`/`buildElements` (143-205) → `ExplorerDataSource`
  and `autoExpandCompressedChildren` in `explorerViewer.zig`/`explorerView.ts`.
- `isIncompressible` (458-462) → `ExplorerCompressionDelegate`.
- `readSortOrder`/`readCompactFolders` (445-478) → `FileSorter`/configuration
  in `explorerViewer.zig`.
- `renderRow` (480-541): indent, twistie, compressed path join
  (`renderCompressedElements`).
- `handleClick` twistie test (279-309) → the renderer's twistie hit rule.
- `revealPath` (319-359) → `explorerView.ts` reveal/select.
- `filterItem` (436-444) → `ExplorerDataSource`/`FilesFilter` integration.

Target: new `contrib/files/browser/views/explorerView.zig` (mirror
`explorerView.ts`, 1,207 lines) for the shell (tree creation, filter
integration, reveal) and extend `explorerViewer.zig` (currently 378 lines; it
has `FilesFilter` but not the delegate/data source/renderer/compression
delegate). The `CompressibleObjectTree` itself stays; this is an extraction of
the data source/delegate/renderer/reveal decisions, not a second tree. Paint
stays terminal but on `ui`. The twistie-only x test in `handleClick` is a TUI
hack around the list not exposing twistie targets; keep the hit test host-side
but move the twistie rule into the renderer.

**`searchView.zig` (1,459 code lines, no tests)**

Portable: collapse policy, selection/scroll/reveal, row rendering
(heading/folder/file/match), action keybinding metadata, command dispatch,
scrollbar. Terminal/host: panel geometry, input routing, host callbacks that
open editors and apply edits.

The right shape is the explorer shape: build an `ObjectTree(tree.Node)` in
`contrib/search/browser/searchView.zig`, with a data source from
`searchResultsView.zig`, delegate/renderers there, and keybindings/actions in
`searchActions*.zig` (already ported). Then delete:

- `rows`/`depths`/`selected`/`scroll` and `rebuildRows` (136-141, 489-510);
- `SearchViewDataSource.visibleRows` (invented, 141-172);
- `OwnedStringSet` + `applyDefaultCollapse` (519-547), replaced by tree
  collapse state and `shouldCollapse`;
- selection/scroll/reveal (548-631), replaced by the tree;
- `renderRow` (1023-1089) → `searchResultsView` cell renderer;
- direct scrollbar paint (1003-1020) → shared `ui` scrollbar helper.

Keep a host `Host` struct for open/match/read/write/save (already designed) and
move it next to the view. The ported `searchView.test.ts` and
`searchWidget.test.ts` should come with this.

**`searchWidget.zig` (433 code lines)**

The form mechanics (row layout, `visibleFields`, `cycleFocus`, `fieldAt`,
labeled inputs, toggle hit rects, `appendTextAt`, Surface assembly) are generic
terminal form layout → `ui/form.zig`. The search semantics
(`replace_visible`/`details_visible`/`use_excludes`, option toggles, replace-all
request, focus restoration) mirror `searchWidget.ts` → new
`contrib/search/browser/searchWidget.zig`. The two halves separate cleanly;
only the `Host`/callbacks stay TUI until the search view moves.

**`quickAccess.zig` (370 code lines) and `quickInput.zig` (408 code lines)**

`quickInput.zig` is the missing `quickInputList.ts` plus the input row:

- list layout/page size (62-88): upstream `quickInputList.ts` `layout`
  (1,389-1,398) and `quickInputController.ts` `updateLayout` (1,007-1,090);
- separators, item/active/hover rows, highlights, description (171-249);
- up/down/page/home/end (251-296), row hit/mouse/wheel (298-352).

Target: new `platform/quickinput/browser/quickInputList.zig`; keep the
`ui.InputBox` row + overlay rect/outside-click in the TUI host (or in the
ported quick input controller once its UI interface is ported).

`quickAccess.zig` mostly composes already-ported pieces (`Registry`,
`QuickAccessController`, `QuickInputService`, providers). Move the composition
to `workbench/browser/quickaccess.zig` (upstream
`workbench/browser/quickaccess.ts`); keep the `std.Io` file-index polling and
the TUI modifier quirks (Ctrl-P only) in the host. The in-picker
Ctrl-P/Ctrl-Shift-P prev/next branch (187-221) is upstream
`getQuickNavigateHandler` and moves with it.

**`fileIndex.zig` (424 code lines)**

The walk/ignore/queue duplicates the ported search service's engine and the
`anythingQuickAccess` file source. Upstream file search is
`ISearchService.fileSearch` (`searchService.ts:165`), served by the local file
search provider. Extend `workbench/services/search/common/searchService.zig`
with a `fileSearch` job (walker injected), make
`AnythingQuickAccessProvider` consume it, and keep at most a ~120-line
`std.Io` walker adapter in the host. `describe`/`describePath` duplicate each
other; `capped` is set but never read.

**`fileIcon.zig` (62 code lines)**

The language badge is an invented terminal substitute for the file icon theme
(`fileIconThemeData.ts` + `getIconClassesForLanguageId`). Keep it documented as
TUI-only short term; if icon themes are ported later, move the badge table into
`workbench/services/themes/browser/fileIconThemeData.zig` and let the tab strip
ask for an icon. Do not invent a mirrored file for the current table.

### 4.4 Services, theme, language

**`language.zig` / `languageConfiguration.zig`**

`language.zig` is bundled data (language ids, extensions, comment rules,
brackets, folding flags, bundled `language-configuration.json`). It is not a
port of one upstream file; the closest upstream mechanism is the built-in
language extensions + `WorkbenchLanguageService.registerLanguageContribution`.
Move the table to
`workbench/services/language/common/bundledLanguages.zig` (new, clearly marked
as the bundled subset; no DOM) and register through the existing
`WorkbenchLanguageService`. Keep the `vscode-syntax` asset lookup in the host
and pass it in as a reader, so the mirrored module does not depend on the
generated asset package. Then delete `language.zig`.

`languageConfiguration.zig` is the service workaround described in §3.5. Port
the concrete upstream class and add the interface context; delete the file.

**`logger.zig`**

The line format (`YYYY-MM-DD HH:MM:SS.mmmZ [level] message`) is upstream
`FileLogger.log`/`stringifyLogLevel`; file open/flush is host (rotation and
backup are not ported).
Port `FileLogger` into `platform/log/common/fileLog.zig` (mirror upstream,
without `IFileService`/URI: inject a writer/file handle) and keep ~40 lines in
the host for the default path
(`<user-data-dir>/logs/main.log`, or the upstream `--logsPath` directory).

**`session.zig`**

The memento path is already upstream-shaped (`InMemoryStorageService` +
`Memento`, key `memento/editorPart`). Move the DTO ↔ `SerializedEditorPart`
conversion into `editorPart.zig`/`editorGroupsService.zig` (upstream
`EditorPart.serialize`/`EditorGroupsService` restore); keep only the `--session`
file read/atomic write in the host. The legacy bare-part format can be dropped
once sessions are versioned, or kept as a one-way migration with a comment.

**`settingsWatcher.zig`**

The watch-request construction and reload are upstream
`ConfigurationService` behavior (`onDidFilesChange` → `reloadConfiguration`).
Move `update`/`onFileChanges` into
`workbench/services/configuration/browser/configurationService.zig` as a
`watchSettingsFiles(watcher)` method; the host only creates
`UniversalWatcher`, polls it and forwards the wait handle. Then delete the
file.

**`syntaxTheme.zig`**

See §3.9. Target:
`editor/standalone/browser/standaloneThemeService.zig` (new subset: color theme
→ token rules → `TokenTheme` → `TokenizationRegistry.setColorMap`). Keep a
small host loader that selects Dark+ and supplies `ThemeAssetReader` /
`FileThemeReader`; delete the legacy JSONC walker.

**`theme.zig` (23 lines)**

`colorForToken` is a color-map lookup with a hard-coded fallback palette used by
the view. Move the lookup next to `TokenizationRegistry` (or the new standalone
theme service) and let the terminal view map `Color` → `ui.Color`. The fallback
palette is only for tests before a theme is installed; keep it in the test
helper rather than production.

**`hoverProvider.zig` (111 code lines)**

Keep. It is a documented TUI-only stand-in for a language hover provider
(word + language/token type, plus the JSON language server); it exercises the
ported hover contribution and is not upstream behavior. It is the one file in
`src/tui` with no upstream home by design. Do not move it into
`src/vs/editor/contrib/hover`; keep it next to the host adapter.

**`editorInput.zig` / `workingCopy.zig`**

Merge into the ported
`contrib/files/browser/editors/fileEditorInput.zig` and
`services/textfile/common/textFileEditorModel.zig`. The input should own the
editor pane/widget; the TUI `Editor` is not an input. Until the editor widget
is ported, keep a single adapter in the host (one file, ~50 lines) and do not
register two serializers/type ids.

**`utf8Helper.zig`**

Move to `base/common/strings.zig` and update the four model imports. See §3.6.

### 4.5 Terminal contribution: `terminalInput.zig`, `terminalView.zig`, `terminalPanel.zig`

These are the terminal contribution's input encoder, renderer and tabbed view,
not process host:

- `terminalInput.zig` replaces xterm.js DOM input encoding (key/mouse/focus/
  paste, bracketed-paste scanner). Upstream is xterm's input path, so there is
  no Zig file to port; it belongs next to `terminalEmulator.zig` under
  `workbench/contrib/terminal/browser/`.
- `terminalView.zig` is the render-state → `ui.CellGrid` paint (xterm renderer
  replacement). Same destination.
- `terminalPanel.zig` maps to `terminalTabbedView.ts` / `terminalTabsList.ts`
  (tab strip layout, `+`/`x` actions, hit testing). Port the layout/action
  decisions into those mirrored files; the cell paint stays on `ui`.

`terminalView.test.zig` moves with the renderer. The pty/service already live
under `contrib/terminal/browser` and `platform/terminal`. After this, `src/tui`
only wires terminal focus/keys in `workbench.zig` (and even that can move with
the workbench shell).

**`tui.zig`**

Split:

- `ui`: alternate screen, mouse capture, bracketed paste, line wrap, cursor
  position/move/hide/show, clear screen, cursor-position query.
- host: terminal-size ioctl/console API, raw mode (POSIX termios / Windows
  console), `readFd`, `pollInput*`, file-descriptor/handle wait, SIGWINCH
  self-pipe, panic handler.

The host keeps the fd/poll API; `ui` owns the ANSI strings and a `Screen`
helper. This removes ~150 lines from `tui.zig` and lets examples reuse screen
setup (they currently have their own).

**`cellBorders.zig`**

`ui/src/render/cell_border.zig` already owns the query, DA1, parser and capabilities. Move
the probe state machine there (`Probe.feed(bytes)` / `Probe.finished()` /
`Result`) and let `app.zig` drive the reads/timeout. The host keeps the
`readFd`/`pollInput` loop only.

### 4.6 Extensions: `extensions.zig` (~1,200 production lines)

The portable pieces are under `src/vs/workbench/services/extensions/` (RPC,
protocol, host manager, scanner) and `src/vs/workbench/api/browser/`
(`mainThreadDocuments`, `mainThreadTextEditors`, `mainThreadCommands`,
`mainThreadConfiguration`, diagnostics, language features, storage, statusbar,
window, editor tabs). The header claims this file owns "only the active tab's
document mirror, the command surface and the typed-text path", but roughly
**700 lines are re-implemented `MainThread*` actor state**:

| Lines | State | Upstream / target |
| --- | --- | --- |
| 49-55, 670-716, 737-749, 979-997 | `ActiveDocument` mirror, add/remove document, model-changed pushes with an independent version counter and synthetic range offsets/EOL | `mainThreadDocuments.ts` (114/126), `mainThreadDocumentsAndEditors.ts` (377); extend the two ported actors, use the model version as the single source and send real content deltas |
| 62-74, 999-1021, 1042-1068 | `last_selections`, capture/sync selection, source strings (`keyboard`/`mouse`/`command`) | Upstream `MainThreadTextEditor` (`mainThreadEditor.ts` 31-360). New `api/browser/mainThreadEditor.zig`; the current `mainThreadTextEditors.zig` name is wrong (upstream has `mainThreadEditor.ts` + `mainThreadEditors.ts`) |
| 473-506, 950-977 | set-selections/apply-edits host callbacks, no version check/undo stop; edit specs | `mainThreadEditors.ts` (422 lines); rename/extend the port and add version/undo-stop checks |
| 424-447, 718-735 | tab model sync/close/move (move is a no-op) | extend `mainThreadEditorTabs.zig` |
| 542-627 | `$initializeWorkspace`, `$initializeConfiguration`, `$startExtensionHost`, startup activation wait | new `mainThreadWorkspace.zig`; extend `mainThreadConfiguration.zig` + `extensionHostManager.zig` |
| 1071-1161 (+914-948) | `executeHostCommand` switch: split/close/save/next/prev/`vscode.open`/`_setContext`/`insertLineAfter`/`default:type`/`deleteLeft` | `mainThreadCommands.ts` (81-95) + `editorActions.ts`, `editorCommands.ts`, `fileCommands.ts`, `linesOperations.ts`, `contextKeyService.ts`; extend `platform/commands` with args/results |
| 751-873, 875-899, 1144-1161 | VSCodeVim key table, direct `$executeContributedCommand`, `vim.active`/`vim.mode` booleans | **Removed.** Native Vim registers a generic key-input handler through the built-in extension API; the Node host has no Vim-specific key table. |
| 523-540 | configuration change push duplicates `MainThreadConfiguration.push` | dedupe into the actor |
| 901-912 | unregistered-actor stubs `$getTools`/`$ensureActivation` | `extensionHostManager` default-actor policy |
| 458-462 | `documentsCreateHost` returns a fake `/tmp/untitled` | untitled/working-copy service (port `untitledTextFileEditorModel` or a host temp resource) |
| 1026-1040 | `isStaleAutoIndentSelection` workaround | **Removed** with VSCodeVim support; native Vim uses the editor cursor state directly. |

Genuinely host in this file: `windowOpenUriHost`, `documentsOpen`/`Save`,
show/reveal (call `Workbench`), diagnostics model lookup (a tab lookup until
`IModelService` exists), editor-tab callbacks, the typed-text transport,
`handleKey`, Vim mode state, the extension host spawn, and the default
`type` shim.

What stays TUI after the actor state moves: the Vim command surface, the
`type` path that sends typed text through the extension host, the socket/Node
spawn call (already in `extensionHostManager.zig`), and the workbench binding.

### 4.7 What genuinely stays in `src/tui/`

- `tui.zig` raw mode/read/poll/signal/size (minus screen sequences).
- `app.zig` CLI/env/session/theme/extension boot, event loop, frame output,
  signal handling.
- `extensions.zig` TUI binding to the extension host: the Vim command surface,
  the `type` transport, `isStaleAutoIndentSelection` (documented TUI workaround
  until the typed-text path uses the applied-edit result), and the host
  spawn/binding (minus the portable `MainThread*` state).
- `workbench.zig` host shell: part composition, focus ownership, frame
  composite, view lifecycle, fd/event-loop polling, `syncSearchActivity`
  (documented TUI-only; no upstream counterpart) and the terminal key/mouse
  routing (shrinks as actions/parts move).
- `hoverProvider.zig`: TUI-only word/token hover fallback (documented).
- Small file hosts if not fully folded: log path/open, session file I/O, theme
  asset reader, `fileIcon` badge until icon themes exist.
- The `keybindings.zig` key mapping, folded into the host keybinding adapter
  (no separate file).

Everything else has an upstream home.

## 5. What belongs in `ui/`

These are generic terminal capabilities currently implemented in `src/tui/`.
They have no VS Code semantics and no dependency on `src/`.

1. **`ui/src/terminal/screen.zig`** (or extend `ui/src/terminal/ansi.zig`): alternate screen, bracketed
   paste, mouse capture, line wrap, clear screen, cursor position/move/hide/
   show, cursor-position query. Replace `tui.zig:132-286` and the duplicate
   setup in `ui/examples/*`.
2. **`ui/src/render/cell_border.zig` probe**: `Probe` state machine fed by the host, with
   `Result { supported, capabilities }`. Remove `src/tui/cellBorders.zig`.
3. **`ui/text.zig`**: `drawText(grid, text, x, y, max_width, paint, measure)`,
   `measure`, `truncate`, and `drawStyledRuns` (coalesce equal-style runs into
   one paint pass). Replaces five `drawText` copies, `textWidth`/
   `truncateLabel`, and the run emitter in `view.zig`. `ui.paint.drawText`
   already exists but takes a `Document` and a clip rect; add the grid-only
   variant and a `drawStyledRuns` next to it.
4. **`ui/scrollbar.zig`**: proportional thumb geometry (`thumbHeight`,
   `thumbTop`, track↔offset mapping) and cell paint over a `CellGrid`.
   `ui.scroll_view` already has the policy; share it. Do **not** move
   `scrollbarState.zig` (VS Code behavior) into `ui`.
5. **`ui/form.zig`** (candidate): labeled `InputBox` rows, inline toggles,
   absolute placement, hit rectangles, visible-field/focus cycling. Used first
   by the search widget; reusable by settings/dialogs. Keep labels/options as
   caller data.
6. **`ui/overlay.zig`** (candidate, defer): centered/anchored overlay
   rectangle, `clearBordersRect`, `blit`, outside-click hit test. Duplicated
   by `quickInput.zig` and `ui/src/widgets/dialog.zig`, but the editor anchoring
   preferences are VS Code contracts; wait for the second non-editor consumer
   (quick input) before extracting.
7. **`ui.CellGrid.addBorderRect`**: the pane-border and drop-target rectangle
   loops in `workbench.zig` (3520-3543, 2765-2792) duplicate cell-border
   bookkeeping. Keep colors/priorities in the workbench; the grid helper is
   generic.
8. **`ui.input` buffered stream**: the read remainder / "awaiting
   continuation" assembly in `app.zig` (578-616) can be a buffered
   `ui.input` stream; `decodeWithRemainder` already exists. Weak candidate,
   do it with the host loop cleanup.
9. **Small value helpers**: `ui.Style.eql`/`ui.Color.eql`, `ui.Color.fromRgb`,
   `ui.dom.appendStyledRuns`. `ui/src/style/style.zig` has `Color.eql`; `view.zig` has a
   private `styleEql`. Cursor show/hide/place is renderer state; a
   `Surface`/`Frame` cursor API is a weak candidate (app currently emits the
   ANSI cursor sequence).

Explicitly **not** `ui/`: `fileIcon` badges, theme palettes, `measureCodepoint`
via `CursorColumns`, editor scrollbar visibility policy, search/explorer row
semantics, the quick-pick list widget. Those are VS Code behavior and belong
under `src/vs/...`, even when they render cells.

## 6. Tests

The inline test sections move with their subjects. Placement must follow
AGENTS.md: mirror the upstream `test/...` folder and keep the `.test.ts`
basename, e.g.:

```
src/vs/editor/contrib/find/test/browser/findController.test.zig
src/vs/editor/test/browser/view/viewLayer.test.zig
src/vs/editor/test/browser/controller/mouseTarget.test.zig
src/vs/workbench/test/browser/parts/editor/multiEditorTabsControl.test.zig
src/vs/workbench/contrib/search/test/browser/searchWidget.test.zig
```

Currently `searchView.zig` has zero tests, and its flatten/collapse/select
logic is exactly what `searchView.test.ts` covers. Add those tests with the
ObjectTree move, not after.

`app.zig` tests that construct `Editor` + `View` + find/hover/word controllers
are integration tests for the TUI; keep a small set there and move the
editor-behavior cases to the mirrored editor test paths. `editor.zig`'s 49
tests are mostly upstream behavior; only file I/O/conflict tests belong to the
host.

## 7. Roadmap (dependency-ordered)

Estimates are rough; "delete" means lines leave `src/tui/` (some are re-homed,
some are removed).

### P0 — leaf cleanup (no dependencies, ~900 lines out)

1. Delete `src/tui/ansi.zig` (dead, 171).
2. Move `utf8Helper.zig` to `src/vs/base/common/strings.zig`; update the four
   model imports (139).
3. Delete `preview.zig`; add read-only mode to `View`/`Editor`; port its tests
   (332).
4. Delete `theme.zig`; move `colorForToken` to the tokenization/theme layer
   (23).
5. Delete `keybindings.dispatchString`, `CommandRegistry.get`, the unused
   `capped` field; fix stale headers (commands "no registry", keybindings
   "TuiKeybindings retired") (~40).
6. Move the cell-border probe to `ui/src/render/cell_border.zig`; move screen sequences
   from `tui.zig` to `ui/src/terminal/screen.zig` (~210).
7. Add `ui/text.zig` and replace the five `drawText` copies (~150).

### P1 — service and duplicate-model ports (~1,500 lines out)

8. Port `LanguageConfigurationService` into
   `languageConfigurationRegistry.zig`; add the interface context; delete
   `languageConfiguration.zig` (146).
9. Port `FileLogger` into `platform/log/common/fileLog.zig`; shrink
   `logger.zig` to the path/open host (~90).
10. Move session DTO/parse/conversion into `editorPart.zig`; keep the
    `--session` read/atomic-write host (~100 moved, ~35 host).
11. Move settings watching into `configurationService.zig`; delete
    `settingsWatcher.zig` (104).
12. Move bundled languages into
    `workbench/services/language/common/bundledLanguages.zig`; delete
    `language.zig` (123).
13. Port the standalone theme-service token-theme application; delete the
    legacy `syntaxTheme` JSONC loader (~200).
14. Unify `FileEditorInput`/`TextFileEditorModel`; delete `editorInput.zig` and
    `workingCopy.zig` (~216).
15. Move `keybindingService.zig` to
    `workbench/services/keybinding/browser/keybindingService.zig`; keep the
    host adapter (~160).
16. Add `fileSearch` to the search service; shrink `fileIndex.zig` to the
    walker (~300).
17. Replace `commands.zig` with `Action2`/`MenuRegistry` + `getCommands`
    (~117).

### P2 — editor contract and widget (~3,000 lines out)

18. Port the `ICodeEditor` subset into `editorBrowser.zig`; make `Editor`
    implement it; switch the seven contribution imports to the interface.
    **This unblocks everything else.**
19. Extend `codeEditorWidget.zig` to own the cursor controller, view model,
    commands and editing API; grow `viewModelImpl.zig` with `executeEdits`.
20. Add `codeEditorContributions.zig`; move `tab.zig` to
    `editorPane.zig`/`textEditor.zig`.
21. Port `coreCommands.zig`; move the `move*`/typing/delete/indent wrappers out
    of `editor.zig`; register the missing action classes (comment, lines,
    folding, bracket, multicursor, indentation, format, final-newline).
22. Delete the `editor.zig` action/keybinding tables; route `app.zig` keys
    through the keybinding service.
23. Port `viewLineRenderer` line decorations; port
    mouseTarget/mouseHandler/editorScrollbar/overviewRuler/contentWidgets/
    overlayWidgets; wire `browser/view.zig` + `ViewLayer` + `ViewPart`;
    delete the `view.zig` rebuild loop.

### P3 — workbench shell and parts (~3,000 lines out)

24. Keep cell-layout geometry host (justified exception); delete duplicated
    `chromeHeight` branches and reuse `EditorGroupView.chromeHeight` /
    `editorPart.layout`.
25. Collapse the three `Workbench` constructors into one and move the session
    restore materialization into `editorPart.restoreGroups`.
26. Move `activityBar.zig` into the ported activity part/composite bar.
27. Move `tabBar.zig` layout/reveal/hit (and paint, following
    `statusbarPart.zig`) into
    `multiEditorTabsControl.zig`/`editorTabsControl.zig`.
28. Replace the `Workbench` command wrappers with action registrations; move
    terminal command bodies to `terminalActions.zig`; move close/quit policy
    to `editorGroupView.zig` + new `editorActions.zig`; move the outline
    creator and breadcrumb picker construction to their mirrored files; add
    the markers status contribution; move working-copy self-registration into
    `textFileEditorModel.zig`.
29. Retarget the search host callbacks to `textFileService.zig`/
    `textFileEditorModel.zig`/`replaceService.zig`; delete
    `applyClosedFileEdits`/`offsetAt`.
30. Split `workbench.zig` into a smaller host shell plus the ported
    parts/actions. `syncSearchActivity` stays host (TUI-only).

### P4 — panels, pickers, views (~2,300 lines out)

31. Explorer: move data source/delegate/renderer/reveal into
    `explorerView.zig`/`explorerViewer.zig`.
32. Search: build `ObjectTree` in `searchView.zig`; delete the flatten/
    selection/collapse/scroll/scrollbar code; move the renderer into
    `searchResultsView.zig`; add upstream tests.
33. Search widget: `ui/form.zig` + `contrib/search/browser/searchWidget.zig`.
34. Quick input list: `platform/quickinput/browser/quickInputList.zig`; keep the
    input row/overlay host.
35. Quick access: move composition/navigate to
    `workbench/browser/quickaccess.zig`; keep index polling/modifier quirks.

### P5 — terminal contribution (~500 lines out)

36. Move `terminalInput.zig`, `terminalView.zig`, `terminalPanel.zig` and the
    renderer test to `contrib/terminal/browser/` as the xterm replacement +
    `terminalTabbedView`/`terminalTabsList` port.

### P6 — extension adapters (~600 lines out)

37. Define the narrow editor/text-file/workspace service interfaces the
    `MainThread*` actors need; move the host implementations out of
    `extensions.zig`; keep the Vim document mirror and `type` path.

After P0-P4 the terminal tree should be roughly 6-8 host files and ~2,000-3,000
lines; the rest is `src/vs` (on `ui`) plus the `ui` library. P5/P6 finish the
relocation.

## 8. Expected result / scorecard

| Area | Now | Target | Change |
| --- | ---: | ---: | --- |
| `src/tui` files | 37 | 6-8 | -30 |
| `src/tui` non-test lines | ~20,100 | ~2,500-3,500 | -16k to -17k |
| `src/tui` test lines | ~8,000 | ~800 (host integration) | -7.2k |
| Editor stacks | 2 live (one used) | 1 | -2,043 (`view.zig`) -2,700 (`editor.zig` host residue) |
| Command tables | 4 | 1 (actions + registry) | ~-900 |
| File editor inputs | 2 | 1 | ~-200 |
| `drawText` copies | 5+ | 1 (`ui`) | ~-150 |
| Scrollbar implementations | 3-4 | 1 helper + editor part | ~-150 |

The moves add code under `src/vs/` and `ui/`; the point is not total line
count, it is one implementation per behavior and a host that can be swapped
without touching VS Code ports.

## 9. Risks and open questions

- **`ICodeEditor` scope.** Porting the full upstream interface is large. Start
  with the subset used by find/suggest/snippet/folding/wordHighlighter and grow
  it. Do not make contributions depend on the TUI `Editor` again.
- **Editor ownership.** `Editor` currently owns the model + view state;
  upstream `CodeEditorWidget` owns a model that can be shared between panes.
  Splitting sessions/tabs across panes may expose this. The ported
  `EditorGroupModel` already supports multiple inputs per group.
- **View parity.** The collapsed view has terminal-specific paint decisions
  (cell flags, glyph fallbacks, half-cell scrollbar/overview rows, no rounded
  corners). When wiring `ViewParts`, document these at the paint boundary and
  keep the behavior, not the DOM.
- **Search tree.** Moving search to `ObjectTree` changes focus/selection
  semantics (upstream tree behavior). Port `searchView.test.ts` to lock it.
- **Theme colors.** `view.zig`/`tabBar.zig`/`activityBar.zig` hard-code RGB.
  Moving them into `src/vs` makes the missing theme lookups obvious; do not
  move the literals into `ui`.
- **Test relocation.** Moving tests changes `src/tests.zig` registrations in
  bulk. Do it per subject, not in one sweep, so failures are attributable.
- **Stale docs.** `porting-inventory.md` and several file headers still say
  "stay in `src/tui/`" (e.g. `activitybarPart.zig:7`, `editorGroupView.zig:19`,
  `editorPart.zig:8`). Update them as the moves land; this review supersedes
  their status.

## Appendix A: upstream path map

| TUI file | Upstream source(s) (`vscode/src/vs/...` unless noted) | Zig target under `src/` |
| --- | --- | --- |
| `activityBar.zig` | `workbench/browser/parts/activitybar/activitybarPart.ts`, `workbench/browser/parts/compositeBar.ts` | `vs/workbench/browser/parts/activitybar/activitybarPart.zig`, `compositeBar.zig` |
| `ansi.zig` | none (dead; `ui/src/terminal/ansi.zig` + `ui/src/terminal/input.zig` replaced it) | delete |
| `app.zig` | `workbench/browser/workbench.ts` (boot), `editor/browser/coreCommands.ts` | host + `vs/editor/browser/coreCommands.zig` |
| `commands.zig` | `platform/actions/common/actions.ts`, `platform/commands/common/commands.ts`, `platform/quickinput/browser/commandsQuickAccess.ts` | `vs/platform/{actions,commands,quickinput}/...` |
| `editor.zig` | `editor/browser/widget/codeEditor/codeEditorWidget.ts`, `editor/common/cursor/cursor.ts`, `editor/browser/view/viewController.ts`, `editor/browser/coreCommands.ts` | `vs/editor/...` |
| `editorInput.zig` | `workbench/contrib/files/browser/editors/fileEditorInput.ts` | `vs/workbench/contrib/files/browser/editors/fileEditorInput.zig` |
| `explorerTreeSidebar.zig` | `workbench/contrib/files/browser/views/explorerView.ts`, `explorerViewer.ts` | `vs/workbench/contrib/files/browser/views/...` |
| `extensions.zig` | `workbench/api/browser/MainThread*.ts`, `workbench/services/extensions/...` | `vs/workbench/api/browser/...` |
| `fileIndex.zig` | `workbench/services/search/common/searchService.ts` (`fileSearch`), `contrib/search/browser/anythingQuickAccess.ts` | `vs/workbench/services/search/common/searchService.zig` |
| `keybindingService.zig` | `workbench/services/keybinding/browser/keybindingService.ts` | `vs/workbench/services/keybinding/browser/keybindingService.zig` |
| `keybindings.zig` | `base/browser/keyboardEvent.ts` (terminal `KeyEvent` adaptation) | host; fold into the keybinding adapter |
| `language.zig` | built-in language contributions / `workbench/services/language/common/languageService.ts` | `vs/workbench/services/language/common/bundledLanguages.zig` |
| `languageConfiguration.zig` | `editor/common/languages/languageConfigurationRegistry.ts` (`LanguageConfigurationService`) | `vs/editor/common/languages/languageConfigurationRegistry.zig` |
| `logger.zig` | `platform/log/common/fileLog.ts` | `vs/platform/log/common/fileLog.zig` |
| `preview.zig` | none (host mode) | delete |
| `quickAccess.zig` | `workbench/browser/quickaccess.ts`, `platform/quickinput/browser/quickAccess.ts` | `vs/workbench/browser/quickaccess.zig` |
| `quickInput.zig` | `platform/quickinput/browser/quickInputList.ts`, `quickInputController.ts`, `quickInput.ts` | `vs/platform/quickinput/browser/quickInputList.zig` |
| `searchView.zig` | `workbench/contrib/search/browser/searchView.ts`, `searchResultsView.ts` | `vs/workbench/contrib/search/browser/searchView.zig`, `searchResultsView.zig` |
| `searchWidget.zig` | `workbench/contrib/search/browser/searchWidget.ts` | `vs/workbench/contrib/search/browser/searchWidget.zig` |
| `session.zig` | `platform/storage/common/storage.ts`, `workbench/common/memento.ts`, `workbench/browser/parts/editor/editorPart.ts` | host file + `vs/workbench/.../editorPart.zig` |
| `settingsWatcher.zig` | `workbench/services/configuration/browser/configurationService.ts` | `vs/workbench/services/configuration/browser/configurationService.zig` |
| `syntaxTheme.zig` | `editor/standalone/browser/standaloneThemeService.ts`, `workbench/services/themes/...` | `vs/editor/standalone/browser/standaloneThemeService.zig` + host assets |
| `tab.zig` | `workbench/browser/parts/editor/editorPane.ts`, `textEditor.ts`, `textCodeEditor.ts`; `editor/browser/widget/codeEditor/codeEditorContributions.ts` | `vs/workbench/browser/parts/editor/...`, `vs/editor/browser/widget/codeEditor/...` |
| `tabBar.zig` | `workbench/browser/parts/editor/editorTabsControl.ts`, `multiEditorTabsControl.ts` | `vs/workbench/browser/parts/editor/multiEditorTabsControl.zig` |
| `terminalInput.zig` | none (xterm input replacement) | `vs/workbench/contrib/terminal/browser/terminalInput.zig` |
| `terminalPanel.zig` | `workbench/contrib/terminal/browser/terminalTabbedView.ts`, `terminalTabsList.ts` | `vs/workbench/contrib/terminal/browser/terminalTabbedView.zig` |
| `terminalView.zig` | none (xterm renderer replacement) | `vs/workbench/contrib/terminal/browser/terminalRenderer.zig` |
| `terminalView.test.zig` | none (moves with `terminalView.zig`) | `vs/workbench/contrib/terminal/browser/terminalView.test.zig` |
| `theme.zig` | `editor/common/languages/supports/tokenization.ts`, `platform/theme/common/themeService.ts` | `vs/editor/common/tokenizationRegistry.zig` / theme service |
| `tui.zig` | none (terminal host) | host + `ui/src/terminal/screen.zig` |
| `utf8Helper.zig` | none direct (Zig adaptation) | `vs/base/common/strings.zig` |
| `view.zig` | `editor/browser/view.ts`, `view/viewLayer.ts`, `view/viewOverlays.ts`, `viewParts/*` | `vs/editor/browser/view.zig`, `view/viewPart.zig`, `viewParts/*` |
| `workbench.zig` | `workbench/browser/workbench.ts`, `browser/parts/editor/editorActions.ts`, `browser/actions/layoutActions.ts`, `contrib/terminal/browser/terminalActions.ts`, `contrib/search/browser/searchActions*` | `vs/workbench/browser/...` parts/actions; host shell |
| `workingCopy.zig` | `workbench/services/textfile/common/textFileEditorModel.ts`, `workbench/services/workingCopy/common/workingCopy.ts` | `vs/workbench/services/textfile/common/textFileEditorModel.zig` |
| `hoverProvider.zig` | none (TUI fallback) | keep host |
| `fileIconThemeData.zig` | `workbench/services/themes/browser/fileIconThemeData.ts` | Active icon theme belongs to the theme service |
| `cellBorders.zig` | none (terminal protocol) | `ui/src/render/cell_border.zig` |

## Appendix B: classification checklist

When reviewing a new file or a new block, ask:

1. Does VS Code have this behavior? → mirrored `src/vs/...`, even if it paints
   cells. Find the upstream file and keep names/ordering/options.
2. Is it a generic terminal capability with no VS Code semantics? → `ui/`.
3. Is it process/terminal I/O, platform paths, spawning, or a documented
   TUI-only fallback? → `src/tui/`.
4. Does a port already exist? Extend it instead of adding a second copy.
5. Does the port import `src/tui/`? That is a bug: define the contract in
   `src/vs` and make the host implement it.
6. Does the block paint a grid directly? That is fine in `src/vs` via `ui`; it
   is not a reason to keep it in `src/tui/`.
