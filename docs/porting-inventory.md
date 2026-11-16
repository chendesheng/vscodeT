# TUI porting inventory

Status: P1 and P2 implemented; P3-P5 remain. The file table is the
pre-P1/P2 audit snapshot.

- Local snapshot: `src/tui/` at HEAD `5559512`, plus the in-progress
  `editorPart`/`editorGroupView`/`editorPanes` extraction in the working tree.
- Upstream: VS Code **1.147.0**, `../vscode` at commit `e31c2e52`.
- Date: 2026-11-16.
- Scope: the existing 29 files in `src/tui/`. This is not a feature wishlist;
  it answers which terminal-side code is actually portable VS Code logic,
  where that logic belongs, and in what order it can be moved.

Line numbers for `src/tui/...` refer to this working-tree snapshot. A number in
parentheses after an upstream path is the line of the named class or function
in the pinned upstream checkout. Upstream `.ts` paths are relative to
`../vscode/src/vs/` unless they start with `src/`. Zig paths ending in `.zig`
are local; when written without a `src/` prefix (`vs/...`, `platform/...`,
`editor/...`, `base/...`, `workbench/...`), the prefix is relative to `src/`.

## 0. Implementation status

P1 and P2 are implemented.

**P1 (Explorer filter):**
- `FilesFilter` moved to
  `src/vs/workbench/contrib/files/browser/views/explorerViewer.zig`.
- `glob.zig` gained `parseExcludeExpression`, exception segmentation,
  `evaluateExcludeTreeEntry`, `couldExceptionMatchBeneath`, sibling `when`
  clauses and the upstream exclusion test suite; exception-leading folders,
  `!` exceptions and sibling clauses now work.
- `src/tui/sidebar.zig` was deleted; its `Action` moved to
  `src/tui/explorerTreeSidebar.zig`, and the live tree uses the upstream
  filter.
- The open-editor exception is wired through a `Workbench` callback.

**P2 (workbench shell):**
- Added `activitybarPart.zig`, `activityService.zig`,
  `paneCompositePart.zig`, `sidebarPart.zig`, `layout.zig`,
  `statusbarModel.zig` and `statusbarPart.zig` under the upstream paths.
- `src/tui/activityBar.zig` is now the terminal view over the activity model.
- `src/tui/workbench.zig` uses the activity model, sidebar model, layout model
  and status-bar model/part for its shell state.
- The Search activity publishes its current match count through the activity
  service; the activity-bar view paints the first badge character in the
  rail's rightmost cell.
- Ported model tests are registered in `src/tests.zig`.

The table in §7 is the pre-P1/P2 snapshot, so its `sidebar.zig` row and its
`activityBar.zig`/`workbench.zig` descriptions record the old boundary. P3-P5
below are still pending.

## 1. Purpose

`src/tui/` is the terminal host, but it also accumulated portable editor and
workbench behavior that upstream keeps outside the host: editor widgets,
view parts, controllers, keybindings, actions, view filters, storage, theme
and language services. The goal of the audit is to make that boundary
explicit and prevent two opposite mistakes:

1. **Porting terminal-only code.** Raw mode, ANSI parsing, cell painting,
   hit rectangles and the capability probe have no VS Code counterpart.
2. **Leaving portable behavior in the host.** Key dispatch tables, editor
   command wrappers, the collapsed editor view and the Explorer filter are
   upstream-shaped behavior that belongs under `src/vs/...`.

The output is a file-by-file status table, subsystem notes that name the
upstream sources and existing ports, and a dependency-ordered roadmap.

This document changes no runtime behavior. It is the input for the follow-up
ports listed in §9.

## 2. Method

For every file in `src/tui/`:

1. Read the file header and public surface, then the implementation of every
   behavior that is not obviously terminal I/O.
2. Locate the upstream counterpart by name, class and call shape
   (`editor/browser/...`, `workbench/browser/...`, `workbench/contrib/...`,
   `platform/...`, `base/...`).
3. Read the upstream implementation and its test file before classifying it.
4. Mark the code as `portable-embedded`, `tui-adapter`, `terminal-only`,
   `missing-service` or `mixed`.
5. Record the upstream test path, effort and dependencies.
6. Verify each referenced upstream path exists in the pinned checkout.

The audit deliberately excludes upstream features that the TUI does not
implement at all (for example diff editors, notebooks, chat, the extension
host). It only classifies code that already exists under `src/tui/`.

## 3. Legend

### Status

| Status | Meaning |
| --- | --- |
| `portable-embedded` | Portable upstream behavior is implemented inside a TUI file and should move to an upstream-shaped module. |
| `tui-adapter` | The file is the terminal boundary for an already-ported model. Keep the adapter; only the documented missing service may move. |
| `terminal-only` | No VS Code counterpart. Keep it in `src/tui/` (or `ui/`). |
| `missing-service` | The TUI first needs a ported service before the portable layer can be extracted. |
| `mixed` | The file contains both portable-embedded logic and terminal-only adaptation. |

### Effort

| Size | Rough effort (one engineer familiar with the repo) |
| --- | --- |
| S | 1-3 days |
| M | 1-2 weeks |
| L | 2-4 weeks |
| XL | More than 4 weeks, normally split into multiple commits |

Effort numbers are estimates, not commitments. They assume the port carries
the upstream tests and does not invent browser-only behavior.

### Priority

P1 is the first slice, P5 is the last. Priority includes risk and dependency,
not only value: a small self-contained port with an upstream test is preferred
over a larger port that needs missing services.

## 4. Headline findings

1. **The largest unported portable block is the editor browser stack.**
   `src/tui/editor.zig` (2,639 lines) and `src/tui/view.zig` (3,295 lines)
   together hold 5,934 lines. `editor.zig` is currently model + editor widget
   + cursor controller + command host + editor configuration. `view.zig`
   collapses `view`, `viewLayer`, `viewOverlays`, `viewPart` and most
   `viewParts` into one file. The substrate they need is already ported
   (§6), so the remaining work is structural, not a model rewrite.
2. **Key dispatch is a hand-written table, not a keybinding service.**
   `app.zig:430-490` and `app.zig:678-825` route terminal keys directly to
   `Editor` methods; `workbench.zig:967-1037` and `1213-1284` add tab, group
   and sidebar maps; `searchView.zig:609-750`, `quickAccess.zig:162-193` and
   `explorerTreeSidebar.zig:231-259` add view-specific maps. Roughly 600 lines
   of routing have no registry, resolver, context keys or command metadata.
   `src/vs/editor/browser/editorExtensions.zig` already defines action and
   keybinding metadata, but nothing consumes it.
3. **The Explorer contains about 700 lines of dead duplicate view code.**
   `sidebar.zig:253-948` defines a legacy direct-painted `Sidebar` that the
   workbench no longer uses; `explorerTreeSidebar.zig` is the live tree view.
   Only `FilesFilter` (`sidebar.zig:52-245`) and `Action` are still consumed.
   `FilesFilter` belongs in
   `workbench/contrib/files/browser/views/explorerViewer.ts`, and the
   documented missing exclusion behavior has an upstream implementation and
   test.
4. **The workbench shell is still mostly TUI-local.** After the recent
   `grid`, `editorDropTarget`, `editorPart`, `editorGroupView` and
   `editorPanes` extraction, `workbench.zig` still owns part layout
   (`layoutAll`, `sidebarRect`, `activityRect`), activity-container switching,
   sidebar visibility, status-row placement and rendering. The upstream
   counterparts are `workbench/browser/layout.ts` and the part implementations
   under `workbench/browser/parts/`.
5. **Theme, storage, language and file/editor-input services are TUI
   stand-ins.** About 70 hard-coded color/style constants live across
   `view.zig`, `tabBar.zig`, `activityBar.zig`, `sidebar.zig`,
   `searchView.zig`, `searchWidget.zig` and `quickInput.zig`; `theme.zig` only
   maps token color ids. `session.zig` invents a JSON session format instead
   of using `platform/storage` + `workbench/common/memento.ts`.
   `language.zig` hard-codes an extension map instead of the workbench
   language service, and `editorInput.zig` owns the `Editor` instead of a text
   file working copy/editor service.
6. **The ported substrate is substantial.** The text model, tokenization,
   view model, coordinate conversion, cursor operations, most editor
   contributions, list/tree, search model/service, configuration, file
   watcher, editor-group model/service, grid and quick-input controller already
   exist. Several “remaining” tasks are wiring, not new model work. The audit
   separates the two in §6 and in the phase notes.

## 5. Metrics

| Category | Files | Lines | Contents |
| --- | ---: | ---: | --- |
| Editor core | 4 | 6,714 | `editor.zig`, `view.zig`, `tab.zig`, `preview.zig` |
| Workbench shell and commands | 5 | 4,894 | `app.zig`, `workbench.zig`, `activityBar.zig`, `tabBar.zig`, `commands.zig` |
| Views and pickers | 7 | 4,573 | Explorer, search, quick open, quick input, file index |
| Services, theme and language | 9 | 1,494 | Session, editor input, settings, theme, language, logger, hover |
| Terminal host | 4 | 919 | Raw mode, ANSI, cell-border probe, UTF-8 helpers |
| **Total** | **29** | **18,594** | 164 inline tests |

The numbers are current `wc -l` values and include tests. The editor core and
the shell are 62% of the terminal tree.

## 6. Already-ported substrate

Do not re-port these when executing the roadmap. They are the dependencies
that make the later phases tractable.

| Area | Existing Zig modules | State |
| --- | --- | --- |
| Text model and tokens | `vs/editor/common/model/...`, piece-tree buffer, `textModelTokens`, token stores, `textMateTokenizer` | Ported and wired into `TextModel` |
| View model | `vs/editor/common/viewModel/viewModelLines.zig`, `viewModelDecorations.zig`, `modelLineProjection.zig`, `vs/editor/common/coordinatesConverter.zig` | Ported |
| View layout and line rendering | `vs/editor/common/viewLayout/lineDecorations.zig`, `viewLineRenderer.zig`, `lineHeights.zig`, `linesLayout.zig`, `vs/editor/common/viewModel/inlineDecorations.zig` | Ported |
| Cursors and edit operations | `vs/editor/common/cursor/...`, `cursorCommon.zig`, `cursorMoveCommands.zig`, `cursorTypeOperations.zig`, `cursorCollection.zig` | Ported; exercised through `editor.zig` |
| Editor contributions | Find, hover, suggest, bracket matching, word highlighter, smart select, in-place replace, comment, indentation, multicursor, line selection, line operations, snippet, insert-final-newline, word operations | Ported under `vs/editor/contrib/...` |
| Workbench editor group | `vs/workbench/common/editor/editorGroupModel.zig`, `vs/workbench/services/editor/common/editorGroupsService.zig` | Ported |
| Editor part shell | `vs/base/browser/ui/grid/grid.zig`, `vs/workbench/browser/parts/editor/editorPart.zig`, `editorGroupView.zig`, `editorPanes.zig`, `editorDropTarget.zig` | Ported/being extracted in this working tree |
| Lists and trees | `vs/base/browser/ui/list/...`, `vs/base/browser/ui/tree/...` | Ported; Explorer renders through `CompressibleObjectTree` |
| Search | `vs/workbench/services/search/common/searchService.zig`, `search.zig`, `replace.zig`, `ignoreFile.zig`, `vs/workbench/contrib/search/browser/searchTreeModel/...` | Ported; wired to the TUI view |
| Configuration and files | `vs/workbench/services/configuration/...`, `vs/platform/configuration/...`, `vs/platform/files/...` | Ported; settings and watcher are wired |
| Quick input | `vs/platform/quickinput/browser/quickAccess.zig`, `quickInput.zig`, `commandsQuickAccess.zig`, `vs/workbench/contrib/quickaccess/...`, `anythingQuickAccess.zig` | Ported; TUI widget is the terminal view |
| Services | `history`, `undoRedo`, `notifications`, `workspaceContext`, `commands` | Ported |
| Theme | `vs/platform/theme/common/themeService.zig`, `theme.zig` | Minimal; no workbench color registry or theme service |
| Editor widget contracts | `vs/editor/browser/editorBrowser.zig` (149 lines), `editorExtensions.zig` (117 lines) | Partial contracts; no widget/controller implementation |

## 7. File-by-file inventory

The table covers all 29 files. Phase values refer to §9; “—” means the file is
not scheduled for a port.

| TUI file | Upstream source(s) | Portable content and evidence | Status | Phase | Effort | Upstream tests |
| --- | --- | --- | --- | --- | --- | --- |
| `activityBar.zig` | `workbench/browser/parts/activitybar/activitybarPart.ts` (46), `workbench/browser/parts/compositeBar.ts`, `workbench/services/activity/common/activity.ts`, `workbench/services/activity/browser/activityService.ts` | Activity order/active container, next/previous, hit rectangle; glyph paint is terminal-only | `mixed` | P2 | S | `workbench/test/browser/parts/activitybar/activitybarPart.test.ts` (38) |
| `ansi.zig` | none | ANSI tokenization/encoding for the terminal boundary | `terminal-only` | — | — | none |
| `app.zig` | `workbench/browser/workbench.ts` (66), `workbench/services/keybinding/browser/keybindingService.ts`, `editor/browser/coreCommands.ts` | Host loop/CLI is terminal-only; `handleKeyEvent` (430-490), mouse routing (492-535) and `dispatch` (678-825) are portable key/command behavior | `mixed` | P3 | M | `platform/keybinding/test/common/keybindingResolver.test.ts`, `platform/actions/test/common/menuService.test.ts` |
| `cellBorders.zig` | none | DCS capability probe and byte-stream handling | `terminal-only` | — | — | none |
| `commands.zig` | `platform/actions/common/actions.ts` (801), `workbench/browser/actions/layoutActions.ts`, `workbench/browser/parts/editor/editorActions.ts`, `editor/browser/editorExtensions.ts`, `editor/browser/coreCommands.ts` | Command metadata, editor availability, picker source; replace with the actions registry | `portable-embedded` | P3 | M | `platform/actions/test/common/menuService.test.ts` (23) |
| `editorInput.zig` | `workbench/contrib/files/browser/editors/fileEditorInput.ts` (39), `workbench/services/textfile/common/textFileEditorModel.ts` (56) | Input identity, dirty/save, serialization; needs file service and working-copy model | `tui-adapter` + missing service | P5e | L | `workbench/contrib/files/test/browser/fileEditorInput.test.ts` (17), `workbench/services/textfile/test/browser/textFileEditorModel.test.ts` (55) |
| `editor.zig` | `editor/browser/widget/codeEditor/codeEditorWidget.ts` (70), `editor/browser/view/viewController.ts` (51), `editor/browser/coreCommands.ts`, `editor/browser/config/editorConfiguration.ts` (40) | Model/widget/controller/command host: creation (177-320), cursor/edit wrappers (700-1790), bracket/word/selection actions | `portable-embedded` | P4 | XL | `editor/test/browser/widget/codeEditorWidget.test.ts` (13), `editor/test/browser/controller/cursor.test.ts` (206), `editor/test/browser/controller/cursorMoveCommand.test.ts` (55) |
| `explorerTreeSidebar.zig` | `workbench/contrib/files/browser/views/explorerView.ts`, `workbench/contrib/files/browser/views/explorerViewer.ts` (ExplorerDelegate 75, ExplorerDataSource 89, FilesRenderer 822) | Tree wiring, filter integration, row label/description/decoration decisions; cell painting is terminal-only | `mixed` | P1/P2 | M | `workbench/contrib/files/test/browser/explorerView.test.ts`, `workbench/contrib/files/test/browser/explorerFilesFilter.test.ts` (2) |
| `fileIndex.zig` | `base/common/fuzzyScorer.ts` (25), `workbench/services/search/common/searchService.ts`, `workbench/contrib/search/browser/anythingQuickAccess.ts` | Workspace walk, ignore/exclude handling; replace simple matcher with `scoreItemFuzzy`; honor `search.exclude` | `portable-embedded` | P5b/P5g | M | `base/test/common/fuzzyScorer.test.ts` (68), `workbench/services/search/test/common/search.test.ts`, `workbench/contrib/search/test/browser/anythingQuickAccess.test.ts` |
| `hoverProvider.zig` | none (requires language extension host) | Word/token stand-in for the ported hover contribution | `terminal-only` | — | — | none |
| `languageConfiguration.zig` | `editor/common/languages/languageConfigurationRegistry.ts`, `workbench/services/language/common/languageService.ts` | `ILanguageConfigurationService` implementation and global activation | `portable-embedded` | P5d | M | `editor/test/common/modes/languageConfiguration.test.ts` |
| `language.zig` | `workbench/services/language/common/languageService.ts` (223), language association extension point | Hard-coded extension→language map, comment rules, brackets | `portable-embedded` | P5d | S | none direct |
| `logger.zig` | `platform/log/common/log.ts` (233), `platform/log/common/logService.ts` (10), `platform/log/common/fileLog.ts` | File logger and formatting | `tui-adapter` | P5f | S | `platform/log/test/common/log.test.ts` |
| `preview.zig` | none (read-only host) | Read-only token renderer and scroll keys | `terminal-only` | — | — | none |
| `quickAccess.zig` | `workbench/browser/quickaccess.ts`, `platform/quickinput/common/quickAccess.ts`, `platform/quickinput/browser/quickAccess.ts` | Provider/controller host and terminal key/mouse routing | `tui-adapter` | P3/P5 | S | `platform/quickinput/test/browser/quickinput.test.ts` |
| `quickInput.zig` | `platform/quickinput/browser/quickInput.ts`, `platform/quickinput/browser/quickInputList.ts` | Terminal picker layout/paint; model/controller already ported | `tui-adapter` | — | S | `platform/quickinput/test/browser/quickinput.test.ts` |
| `searchView.zig` | `workbench/contrib/search/browser/searchView.ts` (128), `workbench/contrib/search/browser/searchResultsView.ts`, `workbench/contrib/search/browser/searchActions*.ts` | Query/replace flow, result navigation, dismiss/replace actions; flattened rows are terminal-only | `mixed` | P2/P5g | L | `workbench/contrib/search/test/browser/searchView.test.ts` (2), `workbench/contrib/search/test/browser/searchActions.test.ts` (6) |
| `searchWidget.zig` | `workbench/contrib/search/browser/searchWidget.ts` (115) | Query fields, option toggles, details rows; terminal form | `tui-adapter` | P5g | S | `workbench/contrib/search/test/browser/searchWidget.test.ts` (1) |
| `session.zig` | `platform/storage/common/storage.ts` (61), `workbench/common/memento.ts` (12), editor-part serialization | Group/session JSON, atomic write, restore; replace host format with storage/memento | `tui-adapter` | P5a | M | `platform/storage/test/common/storageService.test.ts` (10), `workbench/test/common/memento.test.ts` (4) |
| `settingsWatcher.zig` | `workbench/services/configuration/browser/configurationService.zig`, file watcher | Watch user/workspace/folder settings, reload | `tui-adapter` | P5h | S | `workbench/services/configuration/test/browser/configurationService.test.ts` (existing) |
| `sidebar.zig` | `workbench/contrib/files/browser/views/explorerViewer.ts` (FilesFilter 1177), `workbench/contrib/files/browser/views/explorerView.ts` | `FilesFilter` (52-245) with exclusion/ignore logic; legacy `Sidebar` (253-948) is dead | `portable-embedded` + dead code | P1 | M | `workbench/contrib/files/test/browser/explorerFilesFilter.test.ts` (2), `base/test/common/glob.test.ts` (63) |
| `syntaxTheme.zig` | `workbench/services/themes/browser/workbenchThemeService.ts` (80), `workbench/services/themes/common/colorThemeData.ts` (54) | JSONC theme loading, token rules, color map; reduce to a theme-service consumer | `portable-embedded` | P5c | M | `workbench/services/themes/test/common/workbenchThemeService.test.ts` (4), `workbench/services/themes/test/common/colorThemeData.test.ts` (5) |
| `tab.zig` | `workbench/browser/parts/editor/editorPane.ts`, `workbench/browser/parts/editor/textEditor.ts`, `workbench/browser/parts/editor/textCodeEditor.ts`, `editor/browser/widget/codeEditor/codeEditorContributions.ts` | Per-tab editor/controllers/overlays and contribution host | `mixed` | P4/P2 | M | `workbench/test/browser/parts/editor/editorPane.test.ts`, `workbench/test/browser/parts/editor/textEditorPane.test.ts` |
| `tabBar.zig` | `workbench/browser/parts/editor/editorTabsControl.ts` (100), `workbench/browser/parts/editor/editorTitleControl.ts` (36), `workbench/browser/parts/editor/singleEditorTabsControl.ts` | Strip layout/hit/reveal/dirty marker; tab order/state already in `EditorGroupModel` | `tui-adapter` | P2 | S | `workbench/test/browser/parts/editor/multiEditorTabsControl.test.ts` |
| `theme.zig` | `platform/theme/common/themeService.ts`, `platform/theme/common/colorRegistry.ts`, token styles | Token color id → RGB and fallback palette | `missing-service` | P5c | S | `workbench/services/themes/test/common/colorThemeData.test.ts` |
| `tui.zig` | none | Raw mode, alternate screen, mouse capture, poll, SIGWINCH | `terminal-only` | — | — | none |
| `utf8Helper.zig` | none direct; compare with `base/common/strings.ts` utilities | UTF-8 safe slicing/codepoint helpers | `terminal-only`/utility | — | S | none |
| `view.zig` | `editor/browser/view.ts` (87), `editor/browser/view/viewLayer.ts`, `editor/browser/view/viewOverlays.ts`, `editor/browser/view/viewPart.ts`, `editor/browser/viewParts/*` | Gutter/line rendering, decorations, selection, cursor, scrollbar, overlays/content widgets, mouse targets, status row | `portable-embedded` | P4 | XL | `editor/test/browser/view/viewController.test.ts` (17), `editor/test/browser/view/viewLayer.test.ts` (4), existing TUI snapshots |
| `workbench.zig` | `workbench/browser/parts/editor/editorPart.ts` (partly ported), `workbench/browser/layout.ts` (158), `workbench/browser/parts/sidebar/sidebarPart.ts` (42), `workbench/browser/parts/paneCompositePart.ts`, `workbench/browser/parts/statusbar/statusbarModel.ts`, `workbench/browser/parts/statusbar/statusbarPart.ts` | Part layout/visibility, activity switching, sidebar/tab mouse, pane compositing, status placement | `mixed` | P2/P3 | L | `workbench/test/browser/layout.test.ts` (2), `workbench/test/browser/parts/sidebar/sidebarPart.test.ts` (1), `workbench/test/browser/parts/statusbar/statusbarModel.test.ts` (10) |

## 8. Subsystem notes

### 8.1 Editor core (`editor.zig`, `tab.zig`)

`Editor` (121-320) creates a `TextModel`, language codec/service,
`ProjectedViewModelLines`, `CoordinatesConverter`, `CursorContext`,
`CursorCollection`, bracket matching, smart select, multicursor session and
undo/redo. The public surface then wraps ported contributions and cursor
operations: `moveLeft` through `movePageDown` (700-899), typing/editing
(960-1070), indentation (1097-1214), delete/undo (1215-1319), line operations
(1320-1360), selection/edits (1360-1495), contribution actions (1495-1785).

Upstream, those responsibilities are split across:

- `editor/browser/widget/codeEditor/codeEditorWidget.ts` — editor lifecycle,
  options, contributions, commands;
- `editor/browser/widget/codeEditor/codeEditorContributions.ts` — contribution
  host and activation;
- `editor/browser/view/viewController.ts` — position/selection commands;
- `editor/browser/coreCommands.ts` — `CoreEditingCommands`/`CursorCommands` and
  their keybindings;
- `editor/browser/config/editorConfiguration.ts` and
  `editor/common/config/editorOptions.ts` — options and configuration;
- `editor/common/services/modelService.ts` / `codeEditorService.ts` — model and
  editor registries.

The model, view model, cursor and contribution layers already exist (§6).
The missing structural pieces are the editor configuration/options subset,
the widget/controller split, the contribution host, and the command/keybinding
services in P3. This is why P4 is a refactor of existing behavior, not a
rewrite.

`tab.zig` is the terminal pane host: it owns one `Editor`, one `View`, one
`FileEditorInput`, and lazily creates the find/hover/word/suggest controllers
on first activation. Upstream equivalent is
`workbench/browser/parts/editor/editorPane.ts` plus
`workbench/browser/parts/editor/textEditor.ts` and
`workbench/browser/parts/editor/textCodeEditor.ts`, with the contribution host.
It stays a TUI adapter for the pane boundary, but its controller/overlay
wiring should move to the widget and contribution host in P4.

### 8.2 Editor view (`view.zig`)

`View` (204) keeps the `ui.Surface`, guides, overlay/content widgets,
line entries, scrollbar drag state and mouse press state. The main pipeline is:

- `dispatchKey` (441), `dispatchMouse` (451), `mouseTargetAt` (634) — terminal
  input and hit testing;
- `refresh` (750) and `rebuild` (813) — full document rebuild;
- line/gutter/current-line render and token runs inside `rebuild`;
- `markDecorations` (1153) — model decorations through
  `LineDecoration.filter`/`extractWrapped`;
- `buildScrollbar` (1207) — the ported `decorationsOverviewRuler` plus
  `ScrollbarState`;
- `buildOverlays` (1358), `buildContentWidgets` (1414) — widget anchoring;
- `appendStatus` (1609) — the status row (an editor status string, not the
  workbench status-bar part);
- `appendRuns` (1648), `markSelections` (1743).

The upstream pipeline is `view.ts` (`View`, view parts, rendering context) →
`viewLayer`/`viewOverlays` → `viewParts` (`viewLines`, `lineNumbers`,
`currentLineHighlight`, `selections`, `viewCursors`, `decorations`,
`contentWidgets`, `overlayWidgets`, `editorScrollbar`). The port already has
`src/vs/editor/browser/viewParts/overviewRuler/decorationsOverviewRuler.zig` and
`src/vs/editor/browser/viewParts/indentGuides/indentGuides.zig`; the other
parts are collapsed into this file.

Terminal constraints: no CSS cascade, no DOM measurement, no subpixel
geometry, cells instead of pixels, and a hardware cursor cell. These are the
documented adaptations in `docs/terminal-ui.md`; the portable part is the
decision logic (which line/decoration/guide/cursor/widget is painted where),
not the browser DOM.

### 8.3 Commands, actions and keybindings (`app.zig`, `commands.zig`, component key handlers)

`app.zig` routes decoded terminal events:

- `handleKeyEvent` (430-490) gives focused widgets the keyboard, then opens
  find, then falls through to `dispatch`;
- `dispatch` (678-825) is a switch over keys/modifiers that calls `Editor`
  methods directly;
- `handleMouseEvent` (492-535) routes mouse events through the view and the
  hover controller.

Component-specific maps add more:

- `workbench.zig:967-1037` — close tab, split, tab/group switching, Alt-1..9;
- `workbench.zig:1213-1284` — sidebar/activity focus and activation;
- `explorerTreeSidebar.zig:231-259` — tree navigation;
- `searchView.zig:609-750` — search fields/results/replace keys;
- `quickAccess.zig:162-193` — Ctrl-P/Alt-P and picker navigation.

Upstream has no such tables in the views. `Action2` (801) + `MenuId` (86) +
`MenuRegistry` (515) register commands; `KeybindingsRegistry` (280) +
`KeybindingResolver` (43) resolve keys with when-clause context;
`viewController` and `coreCommands` issue editor commands. The TUI has the
platform command execution registry (`vs/platform/commands/common/commands.zig`)
but not the actions/menu/keybinding layers.

`editorExtensions.zig` already defines `EditorAction`, `EditorActionRegistry`
and keybinding metadata, so the eventual port can reuse that shape instead of
inventing a new one.

### 8.4 Workbench shell (`workbench.zig`, `activityBar.zig`, `tabBar.zig`)

`workbench.zig` currently owns:

- part rectangles: `activity_width` (528), `sidebarWidth` (523),
  `sidebarShown` (530), `activityRect` (535), `sidebarRect` (544);
- layout: `layoutAll` (757);
- activity switching and sidebar visibility: `showActivity` (721),
  `toggleSidebar` (733), `focusSidebar`/`focusEditor` (744/752);
- tab/group key and mouse routing: `handleTabKey` (967), `handleSidebarMouse`
  (1285), `handleTabMouse` (1319);
- compositing and the activity/sidebar divider: `render` (1380-1476);
- placeholders and pane borders.

Upstream targets:

- `workbench/browser/layout.ts` — part visibility, sizes and positions;
- `workbench/browser/parts/activitybar/activitybarPart.ts` — activity bar and
  composite bar;
- `workbench/browser/parts/sidebar/sidebarPart.ts` and
  `paneCompositePart.ts` — side bar/pane container;
- `workbench/browser/parts/statusbar/statusbarModel.ts` and
  `statusbarPart.ts` — status entries and bar;
- `workbench/browser/parts/editor/editorTabsControl.ts` and
  `editorTitleControl.ts` — title/tabs control. The tab *model* is already
  `EditorGroupModel`; `tabBar.zig` is only strip layout/hit/paint.

The recent extraction already removed grid, drop-target, group-view and pane
bookkeeping from `workbench.zig`. What remains is the part layout/visibility
model and the terminal compositor. P2 targets the model; the compositor and
cell painting stay in the terminal.

### 8.5 Explorer (`explorerViewer.zig`, `explorerTreeSidebar.zig`)

P1 moved the filter and removed the old view:

- `FilesFilter` now lives in
  `workbench/contrib/files/browser/views/explorerViewer.zig`, with the
  configuration, `files.exclude`, `.gitignore`/`.ignore` chains and per-root
  filters.
- The old direct-painted `Sidebar` and `src/tui/sidebar.zig` were deleted;
  `Action` moved to `explorerTreeSidebar.zig`, which is the live tree view.

The upstream filter evaluates exclusion exceptions and tracks folders that
lead to exceptions. `base/common/glob.zig` now ports
`parseExcludeExpression`, `evaluateExcludeTreeEntry`, sibling `when` clauses
and exception-leading-folder handling; `explorerFilesFilter.test.zig` covers
the behavior.

`explorerTreeSidebar.zig` renders through the ported compressed tree. Its
renderer callback (`renderRow`) is the terminal equivalent of `FilesRenderer`
(822): label, description, icon/decoration decisions and the compressed
label. The portable label/description/decoration logic should move to the
upstream-shaped renderer module; the cell paint stays in the TUI.

Explorer actions (new file/folder, rename, delete, refresh, collapse all) are
not wired in the TUI. If they are added, they belong in
`workbench/contrib/files/browser/fileActions.ts`/`fileCommands.ts`, not in the
sidebar widget.

### 8.6 Search and quick open (`searchView.zig`, `searchWidget.zig`, `quickAccess.zig`, `quickInput.zig`, `fileIndex.zig`)

The portable search model is already under
`workbench/contrib/search/browser/searchTreeModel/` and
`workbench/services/search/`. `searchView.zig` adds terminal rows, focus and
mouse routing, plus command methods for toggles, navigation, dismiss and
replace. `searchWidget.zig` is the terminal form for the upstream
`searchWidget.ts` fields/toggles.

Missing portable pieces:

- `search.exclude`/`files.exclude` configuration is not consulted by the TUI
  search view (README and `searchService.zig` both note the gap).
- Search actions (`searchActionsTopBar.ts`, `searchActionsNav.ts`,
  `searchActionsFind.ts`, `searchActionsRemoveReplace.ts`) exist upstream but
  the TUI runs its own command methods.
- Replace-all grouping/preview is model-side already; the view should consume
  it rather than grow more row logic.

Quick open is mostly an adapter already: `quickAccess.zig` hosts the ported
provider registry/controller, `quickInput.zig` is the terminal widget, and the
command/file providers live under `vs/platform/quickinput` and
`vs/workbench/contrib/...`. The portable gaps are:

- `fileIndex.zig` implements a simpler matcher than `base/common/fuzzyScorer.ts`
  (README calls this out);
- it has its own walk instead of upstream `ISearchService.fileSearch` (the
  ported search service currently implements text search only) and does not
  honor `search.exclude`;
- quick open key handling should move to P3’s keybinding layer.

### 8.7 Services, theme and language

- **Session/storage.** `session.zig` serializes `EditorGroupModel` state to a
  JSON file with `SessionDto`/`PartDto` (21-34, 170-192) and atomic writes
  (251). Upstream uses `IStorageService` (`storage.ts:61`) and `Memento`
  (`memento.ts:12`), with editor-part serialization already ported in
  `editorGroupsService.zig`. P5a replaces the ad-hoc format with storage +
  memento while keeping the explicit `--session` path as a terminal host
  choice. Dirty-buffer restore remains blocked on the working-copy backup
  service.
- **Editor input.** `editorInput.zig` is explicitly a TUI adapter for
  `fileEditorInput.ts`: it stores a `*Editor`, reports dirty/save, and
  serializes only the path (97-135). Upstream `FileEditorInput` (39) owns a
  text file working copy/model (`TextFileEditorModel`, 56) and gets the pane
  from the editor service. P5e ports the file service, working copy and
  editor-input layer; encoding, external changes and backup restore follow.
- **Theme.** `theme.zig` maps a token color id through
  `TokenizationRegistry.getColorMap()` and a small fallback palette.
  `syntaxTheme.zig` loads Dark+ JSONC and builds a `TokenTheme`. Hard-coded
  RGB values across the view/widgets bypass any theme service. Upstream
  `workbenchThemeService.ts` (80), `colorThemeData.ts` (54) and the color
  registry replace this. P5c should port the color/token theme service first,
  then replace the constants one widget at a time.
- **Language.** `language.zig` hard-codes extension→language id, comment rules
  and brackets; `languageConfiguration.zig` is a minimal
  `ILanguageConfigurationService` selected through a module-global
  `active_service` (23). Upstream is `WorkbenchLanguageService` (223) and the
  language-configuration registry. The editor-side registry and language
  configuration types are already ported; P5d replaces the stand-ins.
- **Logger.** `logger.zig` opens a file and formats into a 4 KiB buffer.
  Upstream `ILogService` (`platform/log/common/log.ts:233`), `LogService`
  (`platform/log/common/logService.ts:10`) and `FileLoggerService`
  (`platform/log/common/fileLog.ts:105`) add levels, channels and lifecycle.
  P5f is small and independent.
- **Settings watcher.** `settingsWatcher.zig` watches the user settings file,
  workspace file and each folder’s `.vscode/settings.json` and reloads the
  configuration service. Upstream configuration service normally owns this
  through the file service. P5h moves the watch into the service, or documents
  it as a host adapter if the service stays explicit.
- **Hover.** `hoverProvider.zig` is a TUI stand-in that reports the word under
  the cursor. It is not upstream behavior; it exercises the ported hover
  contribution until a language/extension host exists. Keep it documented as
  TUI-specific (already in its header and README).

### 8.8 Terminal host (`tui.zig`, `ansi.zig`, `cellBorders.zig`, `utf8Helper.zig`, `preview.zig`)

These have no VS Code counterpart and should not be moved into `src/vs`:

- `tui.zig` — POSIX/Windows raw mode, alternate screen, mouse capture,
  bracketed paste, SIGWINCH, input polling.
- `ansi.zig` — terminal escape tokenization/encoding.
- `cellBorders.zig` — DCS capability probe for the terminal cell-border
  protocol.
- `utf8Helper.zig` — UTF-8 slicing helpers. This is utility code; before
  replacing it with `base/common/strings.zig`, check whether the base port
  already exposes equivalent safe-slice functions. Until then, keep it in the
  terminal boundary.
- `preview.zig` — read-only single-file mode built on the same renderer.
  It has no upstream feature beyond “read-only editor”; keep it as a host
  mode.

Cell painting and hit rectangles in `view.zig`, `tabBar.zig`,
`activityBar.zig`, `sidebar.zig`, `searchWidget.zig` and `quickInput.zig` are
also terminal-only. Porting the model must not move cell geometry into
`src/vs`.

## 9. Prioritized roadmap

The phases are ordered by dependency and risk. P1 is a self-contained cleanup
and behavior port; P4 is the large editor-browser refactor. P2 and P3 can run
in parallel with different owners, but P4 depends on P3’s command/keybinding
layer.

### P1 — Explorer filter and dead-code removal (implemented)

**Goal:** remove the dead legacy Explorer view and move the live filter to the
upstream-shaped module, including the documented exclusion-exception behavior.

**Scope:**

- Port `FilesFilter` from `sidebar.zig:52-245` to
  `vs/workbench/contrib/files/browser/views/explorerViewer.zig`.
- Port the missing exclusion expression/traversal pieces from
  `base/common/glob.ts` (`parseExcludeExpression` 735,
  `evaluateExcludeTreeEntry` 817) into `vs/base/common/glob.zig`.
- Keep the TUI tree/filter wiring in `explorerTreeSidebar.zig`; adapt the
  upstream filter through a terminal configuration/ignore adapter.
- Delete the unused `Sidebar` (253-948) from `sidebar.zig`; keep `Action`
  where the live tree consumes it.
- Port `workbench/contrib/files/test/browser/explorerFilesFilter.test.ts`
  and the relevant `base/test/common/glob.test.ts` cases.
- Update README/docs to remove the “exception-leading folders not ported”
  limitation.

**Upstream tests:** `workbench/contrib/files/test/browser/explorerFilesFilter.test.ts`
(2 tests), `base/test/common/glob.test.ts` (63 tests).

**Effort/risk:** M (1-2 weeks), medium risk because the filter behavior is user-visible.

**Exit criteria:** the TUI Explorer uses the upstream filter; exclusion
exceptions and `.gitignore` exception-leading folders behave like upstream;
the dead view is gone; tests are registered in `src/tests.zig`; README no
longer lists the gap.

### P2 — Workbench shell model (implemented)

**Goal:** move activity/part visibility and layout decisions out of
`workbench.zig` and `activityBar.zig` into upstream-shaped part models.

**Scope:**

- `workbench/browser/parts/activitybar/activitybarPart.zig` — activity
  registry/order/active/visibility and keyboard navigation.
- `workbench/services/activity/...` — activity service over
  `ViewContainerModel`.
- `workbench/browser/parts/sidebar/sidebarPart.zig` and
  `paneCompositePart.zig` — side-bar visibility, width/position, active
  container.
- `workbench/browser/parts/statusbar/statusbarModel.zig` and
  `statusbarPart.zig` — status entries, alignment, priority; replace the
  editor’s single status string where it represents workbench state.
- `workbench/browser/layout.zig` — the portable part-visibility/size subset.
- Keep terminal paint/hit testing and the compositor in `workbench.zig`.

**Upstream tests:**
`workbench/test/browser/parts/activitybar/activitybarPart.test.ts` (38),
`workbench/test/browser/parts/sidebar/sidebarPart.test.ts` (1),
`workbench/test/browser/parts/statusbar/statusbarModel.test.ts` (10),
`workbench/test/browser/layout.test.ts` (2),
`workbench/test/browser/parts/editor/multiEditorTabsControl.test.ts` (102).

**Effort/risk:** M, medium risk because it changes visible shell behavior.

**Exit criteria:** activity/container/sidebar/status state is in
upstream-shaped models; the TUI only paints and routes cells; the ported part
tests pass; README’s activity-bar/view-container limitations are updated.

### P3 — Actions, commands and keybindings

**Goal:** replace roughly 600 lines of hand-written key routing with the
upstream actions/keybinding pipeline, and register the existing editor
commands as actions.

**Scope:**

- `platform/actions/common/actions.zig` — `Action2`, `MenuId`,
  `MenuRegistry`, menu contributions; port `menuService` as needed for the
  command picker.
- `platform/keybinding/common/keybindingsRegistry.zig`,
  `keybindingResolver.zig`, `keybinding.zig` — registry, when-clause resolver
  and context keys.
- `workbench/services/keybinding/browser/keybindingService.zig` — the
  workbench service, or a terminal host adapter with the same resolution
  contract.
- `editor/browser/coreCommands.zig` — `CoreEditingCommands`/`CursorCommands`
  and their keybindings; use the already-ported cursor operations.
- Workbench/editor action subsets: tab/group actions, sidebar/activity
  actions, search actions, quick-open commands.
- Replace `app.zig` dispatch, `workbench.zig` tab/sidebar maps,
  `searchView.zig`/`quickAccess.zig`/`explorerTreeSidebar.zig` key maps.
- Feed `CommandRegistry`/`CommandPickSource` from the action registry.

**Upstream tests:**
`platform/keybinding/test/common/keybindingResolver.test.ts` (36),
`platform/keybinding/test/common/abstractKeybindingService.test.ts` (21),
`platform/actions/test/common/menuService.test.ts` (23),
`editor/test/browser/controller/cursorMoveCommand.test.ts` (55), plus the
existing ported cursor tests.

**Effort/risk:** L, high risk: it changes every input path.

**Exit criteria:** one registry resolves editor/workbench/view keys; action
metadata (id/label/category/precondition/keybinding) is consumed; the command
picker reads actions rather than `commands.zig`’s private table; keybinding
resolver and action tests are ported; README’s “no keybinding registry”
limitation is removed.

### P4 — Editor browser stack

**Goal:** split the 5,934-line editor/view monolith into the upstream widget,
controller and view-part layers, reusing the ported model/view model and
contributions.

**Suggested commits:**

1. `editor/browser/view/viewPart.zig`, `editor/browser/view/renderingContext.zig`,
   `editor/browser/view/viewLayer.zig`, `editor/browser/view/viewOverlays.zig`
   scaffolding; a thin `View` orchestrator.
2. `editor/browser/viewParts/viewLines/viewLines.zig`,
   `editor/browser/viewParts/viewLines/viewLine.zig`,
   `editor/browser/viewParts/lineNumbers/lineNumbers.zig`,
   `editor/browser/viewParts/currentLineHighlight/currentLineHighlight.zig`;
   move gutter/line/token rendering out of `view.zig`.
3. `editor/browser/viewParts/selections/selections.zig`,
   `editor/browser/viewParts/viewCursors/viewCursors.zig`; move
   selection/cursor cell state.
4. `editor/browser/viewParts/decorations/decorations.zig`,
   `editor/browser/viewParts/contentWidgets/contentWidgets.zig`,
   `editor/browser/viewParts/overlayWidgets/overlayWidgets.zig`; move the
   current overlay/content/widget anchoring.
5. `editor/browser/viewParts/editorScrollbar/editorScrollbar.zig`; keep the
   ported overview ruler and `ScrollbarState`.
6. `editor/browser/view/viewController.zig`; move position/selection commands
   out of `Editor`.
7. `editor/browser/controller/mouseHandler.zig`,
   `editor/browser/controller/pointerHandler.zig`; move mouse target/drag
   behavior.
8. `editor/browser/widget/codeEditor/codeEditorWidget.zig` +
   `editor/browser/widget/codeEditor/codeEditorContributions.zig`; move editor
   lifecycle/config/contribution host out of `editor.zig` and `tab.zig`.

`editor/browser/config/editorConfiguration.zig` and the used subset of
`editor/common/config/editorOptions.ts` should land with step 8 (or step 1 if
the view needs options first).

**Upstream tests:** `editor/test/browser/view/viewController.test.ts` (17),
`editor/test/browser/view/viewLayer.test.ts` (4),
`editor/test/browser/widget/codeEditorWidget.test.ts` (13),
`editor/test/browser/controller/cursor.test.ts` (206),
`editor/test/browser/viewModel/viewModelDecorations.test.ts`, plus the
existing TUI snapshot tests which must keep passing.

**Effort/risk:** XL, high risk; split into the commits above and keep the TUI
snapshot tests as the regression net.

**Exit criteria:** `editor.zig` is model/widget/controller/config rather than
a monolith; `view.zig` is a terminal rendering adaptation of the view parts;
the ported view/controller tests pass; the model/view split allows independent
view state later (the split-pane limitation in README).

### P5 — Services and remaining views

**Goal:** replace the TUI stand-ins with the upstream services, in
independently shippable slices.

| Slice | TUI code | Upstream | Tests | Effort |
| --- | --- | --- | --- | --- |
| P5a Storage/memento | `session.zig` | `platform/storage/common/storage.ts`, `workbench/common/memento.ts` | `platform/storage/test/common/storageService.test.ts` (10), `workbench/test/common/memento.test.ts` (4) | M |
| P5b Fuzzy scoring | `fileIndex.zig` | `base/common/fuzzyScorer.ts` | `base/test/common/fuzzyScorer.test.ts` (68) | M |
| P5c Theme service | `theme.zig`, `syntaxTheme.zig`, hard-coded palettes | `workbench/services/themes/browser/workbenchThemeService.ts`, `platform/theme/common/themeService.ts` | `workbench/services/themes/test/common/workbenchThemeService.test.ts` (4), `workbench/services/themes/test/common/colorThemeData.test.ts` (5) | M/L |
| P5d Language service | `language.zig`, `languageConfiguration.zig` | `workbench/services/language/common/languageService.ts`, `editor/common/languages/languageConfigurationRegistry.ts` | `editor/test/common/modes/languageConfiguration.test.ts` | M |
| P5e File/editor input | `editorInput.zig` | `workbench/contrib/files/browser/editors/fileEditorInput.ts`, `workbench/services/textfile/common/textFileEditorModel.ts`, file service | `workbench/contrib/files/test/browser/fileEditorInput.test.ts` (17), `workbench/services/textfile/test/browser/textFileEditorModel.test.ts` (55) | L |
| P5f Log service | `logger.zig` | `platform/log/common/log.ts`, `platform/log/common/logService.ts` | `platform/log/test/common/log.test.ts` (10) | S |
| P5g Search actions/config | `searchView.zig`, `searchWidget.zig`, `fileIndex.zig` | `workbench/contrib/search/browser/searchActions*.ts`, `workbench/contrib/search/browser/searchView.ts`, `workbench/contrib/search/browser/searchWidget.ts`, search service | `workbench/contrib/search/test/browser/searchActions.test.ts` (6), `workbench/contrib/search/test/browser/searchWidget.test.ts` (1), `workbench/contrib/search/test/browser/searchView.test.ts` (2) | M |
| P5h Settings watch | `settingsWatcher.zig` | `workbench/services/configuration/browser/configurationService.zig`, file service | `workbench/services/configuration/test/browser/configurationService.test.ts` | S |

**Exit criteria per slice:** the upstream module exists under the mirrored
path, its upstream tests are ported and registered, the TUI consumes it, and
README/docs drop the corresponding limitation.

All P5 slices are independent of P4. P5a, P5b, P5c and P5f are the smallest
and can start earlier. P5c is a prerequisite for removing the hard-coded
widget palettes, but not for the editor view refactor.

## 10. Dependency graph

```
P1 (Explorer filter)                    independent

P2 (shell model) ──> P3 (actions/keybindings) ──> P4 (editor browser stack)

P5a storage        ─┐
P5b fuzzy scorer   ─┤
P5c theme          ─┤
P5d language       ─┼── independent slices; may run before or alongside P2-P4
P5e editor input   ─┤
P5f log            ─┤
P5g search actions ─┤
P5h settings watch ─┘
```

P2 can proceed without P3, but its actions should register through the P3
registry once it exists. P4 needs P3’s commands to move the `Editor` wrappers
out; the view-part work (P4 steps 1-5) can start before the command split if
the controller boundary is kept explicit.

## 11. Won’t port / explicit deviations

These stay in `src/tui/` (or `ui/`) because VS Code has no corresponding
terminal behavior, or because the browser infrastructure is deliberately out
of scope:

- Raw mode, alternate screen, mouse capture, bracketed paste, input polling,
  SIGWINCH, Windows console handling (`tui.zig`).
- ANSI parsing/encoding and the frame diff (`ansi.zig`, `ui/`).
- Cell-border capability probe (`cellBorders.zig`).
- CLI argument parsing, session file path selection and process lifecycle
  (`app.zig` host portion).
- Cell painting, clipping, hit rectangles, hardware cursor placement and the
  terminal compositor.
- Read-only preview mode (`preview.zig`).
- The word/token hover stand-in (`hoverProvider.zig`) until a language
  extension host exists.
- Browser-only editor features already documented as deviations in
  `docs/terminal-ui.md` (DOM/CSS, subpixel geometry, IME, native selection,
  minimap, pixel lanes, HTML/CSS parsers, compositor).
- UTF-8 helper replacement is deferred until the base `strings.zig` surface
  is confirmed equivalent; it is utility code, not an upstream port.

## 12. Assumptions and open questions

**Assumptions**

- Upstream is pinned to VS Code 1.147.0 at `e31c2e52`. If the checkout moves,
  paths and line numbers must be refreshed before starting a phase.
- “Port” means an upstream-shaped Zig module plus the upstream tests under
  `src/vs/.../test/...`, with terminal substitutions documented in the file
  header and `docs/terminal-ui.md`.
- The existing ported substrate in §6 is trusted; the roadmap does not
  re-port it.
- Effort estimates assume one engineer familiar with the repository and with
  the port’s `std.ArrayList`/allocator conventions.
- This document is a snapshot; it is not an implementation commitment.

**Open questions**

- Should P2 (shell) or P3 (commands) start first? P2 is more visible; P3
  unblocks P4 and removes the largest architectural duplication.
- Should P4 be split by view part (as suggested) or by widget lifecycle
  (view first, then controller, then widget)?
- Do we want a full workbench theme service, or a terminal color adapter that
  consumes a ported color registry? The current `theme.zig` is too small to
  decide.
- Is a terminal-specific file-service adapter acceptable for P5e, or must the
  full text file service land first?
- Which upstream browser tests can be adapted to cell grids versus which
  need a focused harness? The existing TUI view tests are the model for
  adaptations.
- How often should the upstream pin be refreshed? The inventory should be
  re-run when `../vscode` changes materially.

## 13. Appendix A: upstream test map

| Upstream test | Lines | Tests | Target phase |
| --- | ---: | ---: | --- |
| `workbench/contrib/files/test/browser/explorerFilesFilter.test.ts` | 94 | 2 | P1 |
| `workbench/contrib/files/test/browser/explorerView.test.ts` | 505 | 17 | P1/P2 |
| `base/test/common/glob.test.ts` | 1,402 | 63 | P1 |
| `workbench/test/browser/parts/activitybar/activitybarPart.test.ts` | 1,146 | 38 | P2 |
| `workbench/test/browser/parts/sidebar/sidebarPart.test.ts` | 75 | 1 | P2 |
| `workbench/test/browser/parts/statusbar/statusbarModel.test.ts` | 294 | 10 | P2 |
| `workbench/test/browser/layout.test.ts` | 121 | 2 | P2 |
| `workbench/test/browser/parts/editor/multiEditorTabsControl.test.ts` | 4,786 | 102 | P2 |
| `platform/keybinding/test/common/keybindingResolver.test.ts` | 638 | 36 | P3 |
| `platform/keybinding/test/common/abstractKeybindingService.test.ts` | 773 | 21 | P3 |
| `platform/actions/test/common/menuService.test.ts` | 644 | 23 | P3 |
| `editor/test/browser/controller/cursorMoveCommand.test.ts` | 736 | 55 | P3 |
| `editor/test/browser/view/viewController.test.ts` | 394 | 17 | P4 |
| `editor/test/browser/view/viewLayer.test.ts` | 247 | 4 | P4 |
| `editor/test/browser/widget/codeEditorWidget.test.ts` | 352 | 13 | P4 |
| `editor/test/browser/controller/cursor.test.ts` | 6,435 | 206 | P4 |
| `workbench/test/browser/parts/editor/editorPane.test.ts` | 525 | 12 | P4 |
| `workbench/test/browser/parts/editor/textEditorPane.test.ts` | 104 | 2 | P4 |
| `platform/storage/test/common/storageService.test.ts` | 301 | 10 | P5a |
| `workbench/test/common/memento.test.ts` | 230 | 4 | P5a |
| `base/test/common/fuzzyScorer.test.ts` | 1,452 | 68 | P5b |
| `workbench/services/search/test/common/search.test.ts` | 211 | 17 | P5b/P5g |
| `workbench/contrib/search/test/browser/anythingQuickAccess.test.ts` | 392 | 20 | P5b/P5g |
| `workbench/services/themes/test/common/workbenchThemeService.test.ts` | 73 | 4 | P5c |
| `workbench/services/themes/test/common/colorThemeData.test.ts` | 109 | 5 | P5c |
| `workbench/services/themes/test/node/tokenStyleResolving.test.ts` | 359 | 7 | P5c |
| `editor/test/common/modes/languageConfiguration.test.ts` | 106 | 11 | P5d |
| `platform/log/test/common/log.test.ts` | 162 | 10 | P5f |
| `platform/quickinput/test/browser/quickinput.test.ts` | 1,431 | 47 | TUI adapter |
| `workbench/contrib/search/test/browser/searchActions.test.ts` | 165 | 6 | P5g |
| `workbench/contrib/search/test/browser/searchWidget.test.ts` | 47 | 1 | P5g |
| `workbench/contrib/search/test/browser/searchView.test.ts` | 69 | 2 | P5g |
| `workbench/contrib/files/test/browser/fileEditorInput.test.ts` | 446 | 17 | P5e |
| `workbench/services/textfile/test/browser/textFileEditorModel.test.ts` | 1,192 | 55 | P5e |
| `workbench/services/configuration/test/browser/configurationService.test.ts` | 4,200 | 199 | P5h |

Test counts are the `test(` occurrences in the pinned upstream checkout. They
are an effort signal, not a requirement to port every browser/DOM case
verbatim; the portable cases must be ported, and browser-only cases must be
documented or adapted.

## 14. Appendix B: port checklist

Use this for every phase and every extracted module:

- [ ] The Zig file lives at the mirrored upstream path and keeps the upstream
      basename (`.ts` → `.zig`).
- [ ] The file header starts with `// Port of \`src/vs/.../file.ts\`.` and
      states any deliberate terminal adaptation.
- [ ] The portable behavior is complete, including edge cases; no ad-hoc
      shortcut replaces an upstream branch.
- [ ] The upstream test is mirrored under the same `test/...` path, with the
      same cases; browser setup is adapted, assertions are not deleted.
- [ ] The test file is registered in `src/tests.zig`.
- [ ] Concrete interface adapters expose `interface()`; command structs use
      `commandOf(T).of(self)`.
- [ ] Allocations have `deinit`/`free` paths and `errdefer` cleanup.
- [ ] `zig fmt` was run on changed Zig files.
- [ ] README and `docs/terminal-ui.md` are updated for the newly ported scope
      or the remaining limitation.
- [ ] `zig build`, `zig build test --summary all`, `zig fmt --check`, and
      `git diff --check` pass.
- [ ] The working tree contains only intentional changes.
