# TUI porting inventory

Status: all inventory slices are implemented in the terminal's shape. P1–P3
are complete; P4 has the full terminal view/view-model/controller/widget stack
(DOM-only parts are documented omissions); P5a–P5h are complete except the
documented terminal omissions (Icon themes/extension-enumerated values,
heuristic charset guessing, remote-agent suites, disk backup/history
persistence, ICU collation, browser-only tab/tooltip/view DOM cases). The file
table (§7) and the UI/view code map (§7.1) are current at the snapshot HEAD.

- Local snapshot: `src/tui/` at HEAD `cd69afb` (28 files, 19,012 lines).
- Upstream: VS Code **1.147.0**, `../vscode` at commit `e31c2e52`.
- Date: 2026-11-16.
- Scope: the existing 28 files in `src/tui/`. This is not a feature wishlist;
  it answers which terminal-side code is actually portable VS Code logic,
  where that logic belongs, and in what order it can be moved.

Sections 1–7 are the original audit and plan: their “remaining” notes describe
the starting snapshot, not the current tree (see §0, the current snapshot and
the end status). Line numbers for `src/tui/...` refer to this working-tree
snapshot. Upstream `.ts` paths are relative to
`../vscode/src/vs/` unless they start with `src/`. Zig paths ending in `.zig`
are local; when written without a `src/` prefix (`vs/...`, `platform/...`,
`editor/...`, `base/...`, `workbench/...`), the prefix is relative to `src/`.

## 0. Implementation status

P1–P3 are implemented. P4 and P5a–P5h are implemented in the terminal shape
with the documented omissions listed at the end of this document.

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
  `statusbarModel.zig`, `statusbarItem.zig`, `statusbarPart.zig`,
  `statusbarActions.zig`, `editorStatus.zig` and the statusbar service contract
  under the upstream paths, plus the one-shot quick-input service in
  `platform/quickinput/browser/quickInputService.zig`. The workbench status bar is now a full-width flex `ui` surface with
  entry focus, hover/tooltips and command activation; it owns hit testing and
  entry actions, and `src/tui/workbench.zig` paints it on the bottom row and
  disables the per-pane fallback status row. Selection, indentation, encoding,
  EOL and language entries open their quick pickers; the TUI-only file-path
  entry was removed because upstream's status bar does not show one.
- `src/tui/activityBar.zig` is now the terminal view over the activity model.
- `src/tui/workbench.zig` uses the activity model, sidebar model, layout model
  and status-bar model/part for its shell state.
- The Search activity publishes its current match count through the activity
  service; the activity-bar view paints the first badge character in the
  rail's rightmost cell.
- Ported model tests are registered in `src/tests.zig`.

**Search view (post-P2):**
- `f10e1a6` ported the Search view controller, data source, comparers,
  renderers and action helpers under
  `src/vs/workbench/contrib/search/browser/`; `src/tui/searchView.zig` is the
  terminal adapter over them.

**P5f (log service):**
- `src/vs/platform/log/common/log.zig` ports `LogLevel`, `canLog`, `log`,
  `format`, `AbstractLogger`, `AbstractMessageLogger`, `AdapterLogger`,
  `MultiplexLogger`, `NullLogger`, `NullLogService`,
  `createUnexpectedErrorHandler`, `parseLogLevel` and the level helpers;
  `logService.zig` ports `LogService`.
- `src/vs/base/common/errorMessage.zig` ports `toErrorMessage`, which
  `createUnexpectedErrorHandler` needs.
- `src/vs/platform/log/common/bufferLog.zig` ports `BufferLogger` (buffer
  until a logger is attached, level forwarding, flush and disposal).
- `src/vs/platform/log/test/common/log.test.zig` ports the 10 upstream tests
  (adapter forwarding/no-swallow behavior, duplicate suppression window,
  native-error and stackless formatting, per-handler suppression, level
  filtering).
- `src/tui/logger.zig` is now the terminal host over that core: one synchronous
  `main.log` in upstream `FileLogger` line format with UTC timestamps, and
  `app.zig` reports startup, session outcomes and errors through the log
  service. `VSCODE_TEXTBUFFER_LOG` overrides the path.
- Documented gap: the console loggers, the URI-keyed `ILoggerService` registry
  and the log-output picker are not ported. The TUI owns the terminal and has a
  single log file instead of per-channel resources.

§7 and the new §7.1 are current at the snapshot HEAD. P4 and the remaining P5
slices below are still pending.

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

## 4. Headline findings (initial audit)

> These findings describe the starting snapshot and remain useful as history;
> the current implementation status is in §0 and the end-of-document status
> block.



1. **The largest unported portable block is the editor browser stack.**
   `src/tui/editor.zig` (2,654 lines) and `src/tui/view.zig` (3,346 lines)
   together hold 6,000 lines (3,789 excluding inline tests). `editor.zig` is
   currently model + editor widget + cursor controller + command host + editor
   configuration. `view.zig` collapses `view`, `viewLayer`, `viewOverlays`,
   `viewPart` and most `viewParts` into one file. The substrate they need is
   already ported (§6), so the remaining work is structural, not a model
   rewrite.
2. **Key dispatch is a hand-written table, not a keybinding service.**
   `app.zig:444-495` and `app.zig:692-841` route terminal keys directly to
   `Editor` methods; `workbench.zig:1137-1207` (tabs/groups),
   `1385-1485` (status bar) and `1492-1564` (sidebar/activity) add workbench
   maps; `searchView.zig:604-772`, `quickAccess.zig:162-193` and
   `explorerTreeSidebar.zig:236-258` add view-specific maps. About 700 lines
   of routing have no registry, resolver, context keys or command metadata.
   `src/vs/editor/browser/editorExtensions.zig` already defines action and
   keybinding metadata, but nothing consumes it.
3. **The Search view still owns a flattened results model.**
   `searchView.zig` is 1,329 lines with no inline tests. The portable
   controller, data source, renderers, comparers and action helpers are ported,
   but the adapter keeps its own collapse/selection/scroll state and row
   painting (`rebuildRows` 427, `applyDefaultCollapse` 457, `moveToNextMatch`
   551, `renderRow` 950) instead of using the ported
   `ObjectTree`/`CompressibleObjectTree` the Explorer already renders through.
4. **The workbench shell is mostly ported; the actions above it are not.**
   The status bar, activity bar, sidebar and layout models/parts are ported and
   wired. `workbench.zig` still owns the terminal composition, tab/group action
   orchestration (`openPath` 981, `splitActive` 1075, `closeActive` 1096) and
   input routing. Those are the workbench action/keybinding layer (P3), not new
   shell state.
5. **Theme, storage, language and file/editor-input services are TUI
   stand-ins.** 56 hard-coded color/style constants live across `view.zig`
   (29), `searchView.zig` (11), `searchWidget.zig`/`quickInput.zig` (5 each),
   `preview.zig` (3), `workbench.zig` (2) and `syntaxTheme.zig` (1);
   `theme.zig` only maps token color ids. `session.zig` invents a JSON session
   format instead of using `platform/storage` + `workbench/common/memento.ts`.
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
| Editor core | 4 | 6,780 | `editor.zig`, `view.zig`, `tab.zig`, `preview.zig` |
| Workbench shell and commands | 5 | 5,732 | `app.zig`, `workbench.zig`, `activityBar.zig`, `tabBar.zig`, `commands.zig` |
| Views and pickers | 6 | 3,995 | Explorer, search, quick open, quick input, file index |
| Services, theme and language | 9 | 1,586 | Session, editor input, settings, theme, language, logger, hover |
| Terminal host | 4 | 919 | Raw mode, ANSI, cell-border probe, UTF-8 helpers |
| **Total** | **28** | **19,012** | 161 inline tests |

The numbers are current `wc -l` values and include tests (13,434 non-test
lines and 5,578 lines in the trailing test sections). The editor core and the
shell are 66% of the terminal tree.

## 6. Already-ported substrate

Do not re-port these when executing the roadmap. They are the dependencies
that make the later phases tractable.

| Area | Existing Zig modules | State |
| --- | --- | --- |
| Text model and tokens | `vs/editor/common/model/...`, piece-tree buffer, `textModelTokens`, token stores, `textMateTokenizer` | Ported and wired into `TextModel` |
| View model | `vs/editor/common/viewModel/viewModelLines.zig`, `viewModelDecorations.zig`, `modelLineProjection.zig`, `vs/editor/common/coordinatesConverter.zig` | Ported |
| View layout and line rendering | `vs/editor/common/viewLayout/lineDecorations.zig`, `viewLineRenderer.zig`, `lineHeights.zig`, `linesLayout.zig`, `vs/editor/common/viewModel/inlineDecorations.zig` | Ported |
| Editor options and layout | `vs/editor/common/config/editorOptions.zig` (option value types, `IComputedEditorOptions`, `EditorLayoutInfoComputer`, `EditorWrappingInfoComputer`), `vs/editor/browser/config/editorConfiguration.zig` (`ComputedEditorOptions`) | Ported: upstream defaults, layout/minimap/wrapping computation and the 21-case `editorLayoutProvider.test.ts`; `IEditorConfiguration.options` is typed |
| View parts | `vs/editor/browser/viewParts/viewLines/viewLineOptions.zig`, `vs/editor/browser/viewParts/viewLines/viewLine.zig`, `vs/editor/browser/viewParts/viewLines/viewLines.zig`, `vs/editor/browser/viewParts/lineNumbers/lineNumbers.zig`, `vs/editor/browser/viewParts/currentLineHighlight/currentLineHighlight.zig`, `vs/editor/browser/viewParts/selections/selections.zig`, `vs/editor/browser/viewParts/wordWrapIndicator/wordWrapIndicator.zig`, `vs/editor/browser/viewParts/glyphMargin/glyphMargin.zig` (dedup helpers), `vs/editor/browser/viewParts/linesDecorations/linesDecorations.zig`, `vs/editor/browser/viewParts/marginDecorations/marginDecorations.zig`, `vs/editor/browser/viewParts/viewCursors/viewCursor.zig` and `viewCursors.zig`, `indentGuides.zig`, `overviewRuler/decorationsOverviewRuler.zig` | Line numbers (absolute/relative/interval/custom, final newline, decoration classes), view-line options and the current-line highlight (content/margin, focus-only, empty-selection, word-wrap first pass), selections (styled ranges, rounded-corner enrichment, gaps, multi-selection insets), the word-wrap indicator (indicator presence, wrapping-column position, height, viewport clipping, event/config invalidation), the terminal `viewLine` (`IVisibleLine` over the shared line renderer, invalidation and change detection, integration with `VisibleLinesCollection`) and `viewLines` (viewport-window rendering into a `StringBuilder`, line/option/token/scroll/zones/theme event wiring, and `IViewLines` cell-column ranges/positions), visible whitespace (all/boundary/trailing/selection) and control-character pictures in the shared renderer, the line/margin decoration overlays (class extraction, glyph-margin dedup/order, viewport clipping, tooltips, zIndex) and the view cursors (plurality, blinking-style resolution, focus/composition visibility, selection-empty state, token invalidation, per-cursor viewport data) ported with tests; the glyph-margin DOM widget host and the pixel cursor geometry/blink timers remain host-side; the overlay/part scaffolding now initializes in place so event handlers point at the final object; the `View` orchestrator, `viewController` and terminal `codeEditorWidget` subset are now ported; the remaining upstream view parts are browser-only except visible whitespace/control characters, which are in the shared renderer (see documented terminal omissions) |
| Cursors and edit operations | `vs/editor/common/cursor/...`, `cursorCommon.zig`, `cursorMoveCommands.zig`, `cursorTypeOperations.zig`, `cursorCollection.zig` | Ported; exercised through `editor.zig` |
| Editor contributions | Find, hover, suggest, bracket matching, folding, word highlighter, smart select, in-place replace, comment, indentation, multicursor, line selection, line operations, snippet, insert-final-newline, word operations | Ported under `vs/editor/contrib/...` |
| Workbench editor group | `vs/workbench/common/editor/editorGroupModel.zig`, `vs/workbench/services/editor/common/editorGroupsService.zig` | Ported |
| Editor part shell | `vs/base/browser/ui/grid/grid.zig`, `vs/workbench/browser/parts/editor/editorPart.zig`, `editorGroupView.zig`, `editorPanes.zig`, `editorDropTarget.zig` | Ported and wired into `workbench.zig` |
| Status bar | `vs/workbench/browser/parts/statusbar/` (`statusbarModel.zig`, `statusbarItem.zig`, `statusbarPart.zig`, `statusbarActions.zig`), `vs/workbench/browser/parts/editor/editorStatus.zig`, `vs/platform/quickinput/browser/quickInputService.zig`, `vs/workbench/services/statusbar/browser/statusbar.zig` | Ported; terminal part renders one flex row, workbench paints it full-width, editor-status values open the ported quick pickers |
| Lists and trees | `vs/base/browser/ui/list/...`, `vs/base/browser/ui/tree/...` | Ported; Explorer renders through `CompressibleObjectTree` |
| Search | `vs/workbench/services/search/common/searchService.zig`, `search.zig`, `replace.zig`, `ignoreFile.zig`, `vs/workbench/contrib/search/browser/searchTreeModel/...` | Ported; wired to the TUI view |
| Configuration and files | `vs/workbench/services/configuration/...`, `vs/platform/configuration/...`, `vs/platform/files/...` | Ported; settings and watcher are wired |
| Quick input | `vs/platform/quickinput/browser/quickAccess.zig`, `quickInput.zig`, `commandsQuickAccess.zig`, `vs/workbench/contrib/quickaccess/...`, `anythingQuickAccess.zig` | Ported; TUI widget is the terminal view |
| Services | `history`, `undoRedo`, `notifications`, `workspaceContext`, `commands` | Ported |
| Actions | `vs/base/common/actions.zig` (action/runner/separator/submenu) and `vs/platform/action{,s}/common/*.zig` (`ICommandAction`, the 262 `MenuId`s, `MenuRegistry`, `Action2`) | Ported; `menuService.zig` ports visibility/ordering/grouping, enablement/toggled state, flattened submenus and the hidden-item state (defaults, inversion, reset) persisted under the upstream `menu.hiddenCommands` profile-storage key; registered commands appear implicitly in the command palette (deduplicated against explicit items, upstream `_appendImplicitItems`). `Menu` is live: registry changes (including nested submenu registrations) and context-key changes rebuild it and fire `onDidChange`; dependency keys are collected from `when`/precondition/toggled expressions (including submenus), so unrelated key changes do not refresh it. Menu items expose default keybinding labels by resolving the ported keybinding registry (`MenuService.initWithKeybindings`); `MenuRegistry` exposes a get-menu-items call counter and menus collect ids/keys in the same single read as groups; 21 of the 23 `menuService.test.ts` cases are ported, including group/title/order/navigation sorting with stable case-insensitive group order. The `MenuId.for`/duplicate-throw case is not portable (name-backed `MenuId` values, no singleton registry); the filter-before-sorting spy case remains (getter read counts are not observable on Zig string fields) together with one-shot `getMenuActions`/`getMenuContexts` and disposable tracked registrations. The rest still need sinon-style spies, more ordering/nested cases and async storage/context-key mocks |
| Keys and chords | `vs/base/common/keyCodes.zig`, `keybindings.zig`, `platform.zig`, `keybindingLabels.zig`, `vs/platform/keybinding/common/{baseResolvedKeybinding,usLayoutResolvedKeybinding,resolvedKeybindingItem,keybindingResolver,keybindingsRegistry}.zig` | Ported with the `keyCodes.test.ts` (4) and `keybindingLabels.test.ts` (5) cases; P3 foundation (no registry/resolver yet) |
| Context keys | `vs/platform/contextkey/common/scanner.zig`, `contextkey.zig` | Scanner (34 upstream cases), the expression model (all types including regex `=~`, normalization with OR distribution/redundant-term checks, evaluation, serialization, keys, negation, `cmp`/equality, `implies`) and the `when`-clause parser (all 33 `parser.test.ts` cases) are ported. `contextKeyService` and late-bound constants still to port; `contextkey.test.ts` is gated on the constants |
| Language configuration | `vs/editor/common/languages/languageConfigurationRegistry.zig` (`LanguageConfigurationRegistry`, `LanguageConfigurationRegistration`) | Ported priority registration/merging, default plaintext contribution and invalidation; the TUI service promotes `LanguageService` configurations into it; 11 `languageConfiguration.test.ts` cases ported |
| Theme | `vs/platform/theme/common/themeService.zig`, `theme.zig`, `colorUtils.zig`, `tokenClassificationRegistry.zig`, `vs/workbench/services/themes/browser/workbenchThemeService.zig`, `common/colorThemeData.zig`, `common/themeConfiguration.zig`, `common/hostColorSchemeService.zig` | Portable color registry/theme data and the terminal theme service; the color-theme configuration/preference subset is ported, the schema contribution and icon themes are not |
| Editor widget contracts | `vs/editor/browser/editorBrowser.zig` (149 lines), `editorExtensions.zig` (117 lines) | Partial contracts; no widget/controller implementation |
| View plumbing (P4 start) | `vs/editor/browser/view/renderingContext.zig`, `IViewLayout` subset in `vs/editor/common/viewModel.zig` | `RestrictedRenderingContext`/`RenderingContext`, visible ranges/horizontal positions ported; `ViewPart`/`ViewLayer`/`ViewOverlays` and the `view.zig` split remain |

## 7. File-by-file inventory

The table covers all 28 files. Phase values refer to §9; “—” means the file is
not scheduled for a port. §7.1 breaks the UI/view files down by code block.

| TUI file | Upstream source(s) | Portable content and evidence | Status | Phase | Effort | Upstream tests |
| --- | --- | --- | --- | --- | --- | --- |
| `activityBar.zig` | `workbench/browser/parts/activitybar/activitybarPart.ts` (46), `workbench/browser/parts/compositeBar.ts`, `workbench/services/activity/common/activity.ts`, `workbench/services/activity/browser/activityService.ts` | Activity order/active container, next/previous, hit rectangle; glyph paint is terminal-only | `mixed` | P2 | S | `workbench/test/browser/parts/activitybar/activitybarPart.test.ts` (38) |
| `ansi.zig` | none | ANSI tokenization/encoding for the terminal boundary | `terminal-only` | — | — | none |
| `app.zig` | `workbench/browser/workbench.ts` (66), `workbench/services/keybinding/browser/keybindingService.ts`, `editor/browser/coreCommands.ts` | Host loop/CLI is terminal-only; `handleKeyEvent` (444-495), mouse routing (506-540) and `dispatch` (692-841) are portable key/command behavior | `mixed` | P3 | M | `platform/keybinding/test/common/keybindingResolver.test.ts`, `platform/actions/test/common/menuService.test.ts` |
| `cellBorders.zig` | none | DCS capability probe and byte-stream handling | `terminal-only` | — | — | none |
| `commands.zig` | `platform/actions/common/actions.ts` (801), `workbench/browser/actions/layoutActions.ts`, `workbench/browser/parts/editor/editorActions.ts`, `editor/browser/editorExtensions.ts`, `editor/browser/coreCommands.ts` | Command metadata, editor availability, picker source; replace with the actions registry | `portable-embedded` | P3 | M | `platform/actions/test/common/menuService.test.ts` (23) |
| `editorInput.zig` | `workbench/contrib/files/browser/editors/fileEditorInput.ts` (39), `workbench/services/textfile/common/textFileEditorModel.ts` (56) | Input identity, dirty/save, serialization; needs file service and working-copy model | `tui-adapter` + missing service | P5e | L | `workbench/contrib/files/test/browser/fileEditorInput.test.ts` (17), `workbench/services/textfile/test/browser/textFileEditorModel.test.ts` (55) |
| `editor.zig` | `editor/browser/widget/codeEditor/codeEditorWidget.ts` (70), `editor/browser/view/viewController.ts` (51), `editor/browser/coreCommands.ts`, `editor/browser/config/editorConfiguration.ts` (40) | Model/widget/controller/command host: creation (181-324), cursor/edit wrappers (715-1747), bracket/word/selection actions | `portable-embedded` | P4 | XL | `editor/test/browser/widget/codeEditorWidget.test.ts` (13), `editor/test/browser/controller/cursor.test.ts` (206), `editor/test/browser/controller/cursorMoveCommand.test.ts` (55) |
| `explorerTreeSidebar.zig` | `workbench/contrib/files/browser/views/explorerView.ts` (178), `workbench/contrib/files/browser/views/explorerViewer.ts` (ExplorerDelegate 75, ExplorerDataSource 89, FilesRenderer 822, ExplorerCompressionDelegate 2073, FileSorter 1415) | Tree wiring, filter integration and row paint (368-540); compressed label, sort order and incompressible-chain rules are still inline | `mixed` | P1/P2 | M | `workbench/contrib/files/test/browser/explorerView.test.ts`, `workbench/contrib/files/test/browser/explorerFilesFilter.test.ts` (2) |
| `fileIndex.zig` | `base/common/fuzzyScorer.ts` (25), `workbench/services/search/common/searchService.ts`, `workbench/contrib/search/browser/anythingQuickAccess.ts` | Workspace walk, ignore/exclude handling; replace simple matcher with `scoreItemFuzzy`; honor `search.exclude` | `portable-embedded` | P5b/P5g | M | `base/test/common/fuzzyScorer.test.ts` (68), `workbench/services/search/test/common/search.test.ts`, `workbench/contrib/search/test/browser/anythingQuickAccess.test.ts` |
| `hoverProvider.zig` | none (requires language extension host) | Word/token stand-in for the ported hover contribution | `terminal-only` | — | — | none |
| `languageConfiguration.zig` | `editor/common/languages/languageConfigurationRegistry.ts`, `workbench/services/language/common/languageService.ts` | `ILanguageConfigurationService` implementation and global activation | `portable-embedded` | P5d | M | `editor/test/common/modes/languageConfiguration.test.ts` |
| `language.zig` | `workbench/services/language/common/languageService.ts` (223), language association extension point | Bundled language contributions, comment rules, brackets; path matching now uses `LanguageService`/`languagesAssociations` | `portable-embedded` | P5d | S | none direct |
| `logger.zig` | `platform/log/common/log.ts` (233), `platform/log/common/logService.ts` (10), `platform/log/common/fileLog.ts` (18) | Terminal host over the ported log core: one synchronous `main.log` in upstream `FileLogger` line format with UTC timestamps; `app.zig` reports lifecycle and errors through the service | `ported` | — | — | `platform/log/test/common/log.test.ts` (10, ported) |
| `preview.zig` | none (read-only host) | Read-only duplicate of the view renderer (gutter/tokens/scroll); fold into a read-only `Editor`/`View` instead of keeping a second renderer | `terminal-only` (duplicate view code) | — | S | none |
| `quickAccess.zig` | `workbench/browser/quickaccess.ts`, `platform/quickinput/common/quickAccess.ts`, `platform/quickinput/browser/quickAccess.ts` | Provider/controller host and terminal key/mouse routing | `tui-adapter` | P3/P5 | S | `platform/quickinput/test/browser/quickinput.test.ts` |
| `quickInput.zig` | `platform/quickinput/browser/quickInput.ts`, `platform/quickinput/browser/quickInputList.ts` | Terminal picker layout/paint; model/controller already ported | `tui-adapter` | — | S | `platform/quickinput/test/browser/quickinput.test.ts` |
| `searchView.zig` | `workbench/contrib/search/browser/searchView.ts` (128), `searchResultsView.ts` (SearchDelegate 79, renderers 103-505), `searchActions*.ts` | Terminal adapter over the ported controller/data source/action helpers; still owns flattened rows, collapse/selection/scroll and painting (427-1017); no inline tests | `mixed` | P2/P3/P5g | L | `workbench/contrib/search/test/browser/searchView.test.ts`, `searchActions.test.ts` (6), `searchCompare.test.ts` |
| `searchWidget.zig` | `workbench/contrib/search/browser/searchWidget.ts` (115) | Query fields, option toggles, details rows; terminal form | `tui-adapter` | P5g | S | `workbench/contrib/search/test/browser/searchWidget.test.ts` (1) |
| `session.zig` | `platform/storage/common/storage.ts` (61), `workbench/common/memento.ts` (12), editor-part serialization | Group/session JSON, atomic write, restore; replace host format with storage/memento | `tui-adapter` | P5a | M | `platform/storage/test/common/storageService.test.ts` (10, ported), `workbench/test/common/memento.test.ts` (4) |
| `settingsWatcher.zig` | `workbench/services/configuration/browser/configurationService.zig`, file watcher | Watch user/workspace/folder settings, reload | `tui-adapter` | P5h | S | `workbench/services/configuration/test/browser/configurationService.test.ts` (existing) |
| `syntaxTheme.zig` | `workbench/services/themes/browser/workbenchThemeService.ts` (80), `workbench/services/themes/common/colorThemeData.ts` (54) | JSONC theme loading, token rules, color map; reduce to a theme-service consumer | `portable-embedded` | P5c | M | `workbench/services/themes/test/common/workbenchThemeService.test.ts` (4), `workbench/services/themes/test/common/colorThemeData.test.ts` (5) |
| `tab.zig` | `workbench/browser/parts/editor/editorPane.ts` (49), `workbench/browser/parts/editor/textEditor.ts` (49), `workbench/browser/parts/editor/textCodeEditor.ts` (24), `editor/browser/widget/codeEditor/codeEditorContributions.ts` (14) | Per-tab editor/controllers/overlays and contribution host (43-270) | `mixed` | P4 | M | `workbench/test/browser/parts/editor/editorPane.test.ts`, `workbench/test/browser/parts/editor/textEditorPane.test.ts` |
| `tabBar.zig` | `workbench/browser/parts/editor/editorTabsControl.ts` (100), `workbench/browser/parts/editor/singleEditorTabsControl.ts` (28), `workbench/browser/parts/editor/editorTitleControl.ts` (36) | Strip layout/hit/reveal/dirty marker (82-159); tab order/state already in `EditorGroupModel` | `tui-adapter` | P2 | S | `workbench/test/browser/parts/editor/multiEditorTabsControl.test.ts` |
| `theme.zig` | `platform/theme/common/themeService.ts`, `platform/theme/common/colorRegistry.ts`, token styles | Token color id → RGB and fallback palette | `missing-service` | P5c | S | `workbench/services/themes/test/common/colorThemeData.test.ts` |
| `tui.zig` | none | Raw mode, alternate screen, mouse capture, poll, SIGWINCH | `terminal-only` | — | — | none |
| `utf8Helper.zig` | none direct; compare with `base/common/strings.ts` utilities | UTF-8 safe slicing/codepoint helpers | `terminal-only`/utility | — | S | none |
| `view.zig` | `editor/browser/view.ts` (87), `editor/browser/view/viewLayer.ts`, `editor/browser/view/viewOverlays.ts`, `editor/browser/view/viewPart.ts`, `editor/browser/viewParts/*` | Gutter/line rendering, decorations, selection, cursor, scrollbar, overlays/content widgets, mouse targets; the status row is now a standalone fallback (355, 1639), disabled by workbench tabs | `portable-embedded` | P4 | XL | `editor/test/browser/view/viewController.test.ts` (17), `editor/test/browser/view/viewLayer.test.ts` (4), existing TUI snapshots |
| `workbench.zig` | `workbench/browser/parts/editor/editorPart.ts` (128), `workbench/browser/layout.ts` (158), `workbench/browser/parts/sidebar/sidebarPart.ts` (42), `workbench/browser/parts/paneCompositePart.ts`, `workbench/browser/parts/statusbar/*` | Terminal composition, part rects (621-700, 925), tab/group actions (981-1136), key/mouse routing (1137-1640), status entry refresh (1683), render (1821) | `mixed` | P2/P3 | L | `workbench/test/browser/layout.test.ts` (2), `workbench/test/browser/parts/sidebar/sidebarPart.test.ts` (1), `workbench/test/browser/parts/statusbar/statusbarModel.test.ts`, `statusbarPart.test.ts`, `statusbarItem.test.ts` |

### 7.1 UI/view code map at HEAD

The editor and workbench view code is the largest remaining portable block.
This table breaks it down by code block; it is the list to work from for P3
and P4. `Extract` means the portable decision logic moves to the mirrored
`src/vs/...` module and the TUI keeps only the cell paint; `move` means the
code is a command/action wrapper that belongs in the ported command layer;
`keep` means the block is a terminal adaptation of an already-ported model or
has no upstream counterpart.

**Editor view (`view.zig`)**

| TUI block | Upstream target | Portable logic still inside | Disposition |
| --- | --- | --- | --- |
| `view.zig:204-457` | `editor/browser/view.ts` (`View` 87), `editor/browser/view/viewPart.ts` | View state/lifecycle, widget registration, decoration sinks, document rebuild driver | extract |
| `view.zig:843-1182` | `editor/browser/view/viewLayer.ts` (`RenderedLinesCollection` 43, `VisibleLinesCollection` 253), `editor/browser/viewParts/viewLines/viewLines.ts` (97), `editor/browser/viewParts/viewLines/viewLine.ts` (52), `editor/browser/viewParts/lineNumbers/lineNumbers.ts` (21), `editor/browser/viewParts/currentLineHighlight/currentLineHighlight.ts` (207) | Per-view-line nodes, gutter numbers/wrap arrows, current-line background, token runs, guide composition | extract |
| `view.zig:1699-1834`, `1863-1910` | `editor/browser/viewParts/viewLines/viewLines.ts`/`viewLine.ts` on the ported `viewLineRenderer.zig` | Run emission, inline decoration classes, column↔cell mapping, wrapped-segment clipping | extract |
| `view.zig:1794-1834` | `editor/browser/viewParts/selections/selections.ts` (62) | Selection cell flags (inverted cells) | extract |
| `view.zig:816-831` | `editor/browser/viewParts/viewCursors/viewCursors.ts` (30), `editor/browser/viewParts/viewCursors/viewCursor.ts` | Hardware cursor cell and offset | extract |
| `view.zig:1183-1236` | `editor/browser/viewParts/decorations/decorations.ts` (15) | Model decoration classes → cell flags | extract |
| `view.zig:1237-1387` | `editor/browser/viewParts/editorScrollbar/editorScrollbar.ts` (23) + the ported `decorationsOverviewRuler.zig` | Scrollbar column, thumb, overview markers, cursor markers | extract |
| `view.zig:1388-1524` | `editor/browser/viewParts/overlayWidgets/overlayWidgets.ts` (33), `editor/browser/viewParts/contentWidgets/contentWidgets.ts` (25) | Widget anchoring, preference, clamping, focus restore | extract |
| `view.zig:481-756` | `editor/browser/controller/mouseTarget.ts` (`MouseTargetFactory` 517), `editor/browser/controller/mouseHandler.ts` (59), `editor/browser/controller/pointerHandler.ts` (23), `editor/browser/view/viewController.ts` (51) | Hit testing, drag selection, scrollbar drag, click synthesis | extract |
| `view.zig:355-375`, `1639-1698` | `workbench/browser/parts/statusbar/statusbarPart.ts` (122) | Standalone fallback status row; workbench tabs disable it and use the ported status bar | keep (documented fallback) |
| 29 palette literals in `view.zig` | `platform/theme/common/colorRegistry.ts`, `workbench/services/themes/...` | Direct RGB styles | keep until P5c |

**Editor widget (`editor.zig`) and tab pane (`tab.zig`)**

| TUI block | Upstream target | Portable logic still inside | Disposition |
| --- | --- | --- | --- |
| `editor.zig:181-324` | `editor/browser/widget/codeEditor/codeEditorWidget.ts` (70), `editor/browser/config/editorConfiguration.ts` (40), `editor/common/config/editorOptions.zig` | Lifecycle, model/view-model/cursor/contribution/options wiring | extract |
| `editor.zig:715-928`, `1375-1402` | `editor/browser/view/viewController.ts` (51) | Cursor movement, selection extension, set-position/set-selection | extract |
| `editor.zig:929-1111` | `editor/browser/coreCommands.ts` | Typing, newline, tab/outdent, replace commands | move |
| `editor.zig:1112-1229` | `editor/browser/coreCommands.ts`, indentation contribution | Indent/outdent/reindent/indentation conversion | move |
| `editor.zig:1230-1302` | `editor/browser/coreCommands.ts` | Delete left/right, undo/redo wrappers | move |
| `editor.zig:1335-1517` | `editor/browser/coreCommands.ts`, `editor/browser/editorExtensions.zig` | Line operations and command dispatch | move |
| `editor.zig:1518-1747` | `editor/browser/widget/codeEditor/codeEditorContributions.ts` (14) + the ported contributions | Action wrappers for bracket matching, comments, smart select, in-place replace, final newline | move |
| `editor.zig:630-714` | multicursor contribution + `editor/browser/view/viewController.ts` | Multi-cursor session plumbing, add-cursor/select-occurrence | move |
| `editor.zig:1748-1802` | `workbench/contrib/files/browser/editors/fileEditorInput.ts` (39), editor part | Save, quit/close confirmation | move (P5e) |
| `tab.zig:43-270` | `workbench/browser/parts/editor/editorPane.ts` (49), `workbench/browser/parts/editor/textEditor.ts` (49), `workbench/browser/parts/editor/textCodeEditor.ts` (24), `editor/browser/widget/codeEditor/codeEditorContributions.ts` (14) | Per-tab editor/view/controller/overlay wiring, lazy contribution activation | extract |

**Workbench chrome and panels**

| TUI block | Upstream target | Portable logic still inside | Disposition |
| --- | --- | --- | --- |
| `workbench.zig:621-700`, `925-946` | `workbench/browser/layout.ts` (158), `workbench/browser/parts/*` | Part rectangles and the editor area above the status row | keep (terminal composition) |
| `workbench.zig:981-1136` | `workbench/browser/parts/editor/editorPart.ts` (128), `editorGroupView.ts` (67), `editorActions.ts` | Open/activate/switch/split/close actions | move |
| `workbench.zig:1137-1640` | `workbench/browser/actions/layoutActions.ts`, `workbench/browser/parts/editor/editorActions.ts`, keybinding service | Tab/group/sidebar/status key and mouse routing | P3 |
| `workbench.zig:1683-1769` | `workbench/browser/parts/statusbar/statusbarPart.ts` (122) | Entry text refresh; the bar itself is a ported part | keep adapter |
| `workbench.zig:1821-1990` | none | Pane compositing and cell paint | terminal-only |
| `tabBar.zig:82-159` | `workbench/browser/parts/editor/editorTabsControl.ts` (100), `workbench/browser/parts/editor/singleEditorTabsControl.ts` (28), `workbench/browser/parts/editor/editorTitleControl.ts` (36) | Strip layout, label truncation, active/dirty marker, reveal, hit testing | extract small / keep paint |
| `activityBar.zig:32-106` | `workbench/browser/parts/activitybar/activitybarPart.ts` (46), `workbench/browser/parts/compositeBar.ts`, activity service | Rail hit testing and glyphs; model ported | keep adapter |
| `explorerTreeSidebar.zig:368-540` | `workbench/contrib/files/browser/views/explorerViewer.ts` (`FilesRenderer` 822, `ExplorerCompressionDelegate` 2073, `CompressedNavigationController` 715, `FileSorter` 1415) | Compressed label join, sort order, incompressible-chain rules | move small |
| `searchView.zig:427-1017` | `workbench/contrib/search/browser/searchView.ts` (128), `workbench/contrib/search/browser/searchResultsView.ts` (`SearchDelegate` 79, renderers 103-505), `workbench/contrib/search/browser/searchActions*.ts` | Flattened row model, collapse/selection/scroll, key/mouse, row paint | mixed: use the ported tree; P3 for keys |
| `searchWidget.zig:79-433` | `workbench/contrib/search/browser/searchWidget.ts` (115) | Terminal form fields/toggles/details | keep adapter |
| `quickAccess.zig:64-319` | `workbench/browser/quickaccess.ts`, `platform/quickinput/browser/quickAccess.zig` | Provider/controller host + key routing | keep adapter; P3 for keys |
| `quickInput.zig:43-408` | `platform/quickinput/browser/quickInput.ts` (524, 1182), `quickInputList.ts` (709) | Terminal list layout/paint | keep adapter |
| `app.zig:444-540`, `692-841` | `workbench/browser/workbench.ts` (66), `workbench/services/keybinding/browser/keybindingService.ts`, `editor/browser/coreCommands.ts` | Input routing and the editor shortcut table | P3 |
| `preview.zig:1-332` | none | Duplicate gutter/token/scroll renderer | fold into a read-only `Editor`/`View` |

The 37 `view.zig` tests (from line 1936) and the 31 `editor.zig` tests (from
line 1855) move with their subjects; they are the regression net for the
extraction.

## 8. Subsystem notes

### 8.1 Editor core (`editor.zig`, `tab.zig`)

`Editor` (181-324) creates a `TextModel`, language codec/service,
`ProjectedViewModelLines`, `CoordinatesConverter`, `CursorContext`,
`CursorCollection`, bracket matching, smart select, multicursor session and
undo/redo. The public surface then wraps ported contributions and cursor
operations: `moveLeft` through `movePageDown` (715-928), typing/editing
(929-1111), indentation (1112-1229), delete/undo (1230-1302), line operations
(1335-1375), selection/edits (1375-1517), contribution actions (1518-1747).

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

- `dispatchKey` (471), `dispatchMouse` (481), `mouseTargetAt` (664) — terminal
  input and hit testing;
- `refresh` (780) and `rebuild` (843) — full document rebuild;
- line/gutter/current-line render and token runs inside `rebuild`;
- `markDecorations` (1183) — model decorations through
  `LineDecoration.filter`/`extractWrapped`;
- `buildScrollbar` (1237) — the ported `decorationsOverviewRuler` plus
  `ScrollbarState`;
- `buildOverlays` (1388), `buildContentWidgets` (1444) — widget anchoring;
- `appendStatus` (1639) — the standalone fallback status row; workbench tabs
  call `setStatusBarVisible(false)` (355) and the ported `StatusbarPart` paints
  the workbench bar instead;
- `appendRuns` (1699), `markSelections` (1794).

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

- `handleKeyEvent` (444-495) gives focused widgets the keyboard, then opens
  find, then falls through to `dispatch`;
- `dispatch` (692-841) is a switch over keys/modifiers that calls `Editor`
  methods directly;
- `handleMouseEvent` (506-540) routes mouse events through the view and the
  hover controller.

Component-specific maps add more:

- `workbench.zig:1137-1207` — close tab, split, tab/group switching, Alt-1..9;
- `workbench.zig:1385-1485` — status-bar pointer and key navigation;
- `workbench.zig:1492-1564` — sidebar/activity focus and activation;
- `explorerTreeSidebar.zig:236-258` — tree navigation;
- `searchView.zig:604-772` — search fields/results/replace keys;
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

- part rectangles and the status row: `statusBarRect` (621), `sidebarWidth`
  (641), `sidebarShown` (650), `activityRect` (682), `sidebarRect` (691);
- layout: `layoutAll` (925);
- activity switching and sidebar visibility: `showActivity` (867),
  `toggleSidebar` (882), `focusSidebar`/`focusEditor` (895/904),
  `focusStatusBar` (910);
- tab/group key and mouse routing: `handleTabKey` (1137),
  `handleStatusbarMouse`/`handleStatusbarKey` (1385/1435),
  `handleSidebarMouse` (1566), `handleTabMouse` (1601);
- status entry refresh: `refreshStatus` (1683);
- compositing and the activity/sidebar divider: `render` (1821-1990);
- placeholders and pane borders.

Upstream targets:

- `workbench/browser/layout.ts` — part visibility, sizes and positions;
- `workbench/browser/parts/activitybar/activitybarPart.ts` — activity bar and
  composite bar;
- `workbench/browser/parts/sidebar/sidebarPart.ts` and
  `paneCompositePart.ts` — side bar/pane container;
- `workbench/browser/parts/statusbar/` — status model, item, part and actions;
  ported, with `workbench.zig` painting the full-width row and routing focus;
- `workbench/browser/parts/editor/editorTabsControl.ts` and
  `editorTitleControl.ts` — title/tabs control. The tab *model* is already
  `EditorGroupModel`; `tabBar.zig` is only strip layout/hit/paint.

The P2 extraction already removed grid, drop-target, group-view, pane
bookkeeping and the status bar from `workbench.zig`. What remains is the
terminal compositor, tab/group actions and the input maps that P3 replaces.

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
renderer callback (`renderRow`, 470) is the terminal equivalent of
`FilesRenderer` (822): label, description/icon decisions and the compressed
label join. `readSortOrder` (454), `isIncompressible` (448) and
`readCompactFolders` (435) duplicate `FileSorter` (1415) and
`ExplorerCompressionDelegate` (2073). The portable sort/compression decisions
should move to those upstream-shaped modules; the cell paint stays in the TUI.

Explorer actions (new file/folder, rename, delete, refresh, collapse all) are
not wired in the TUI. If they are added, they belong in
`workbench/contrib/files/browser/fileActions.ts`/`fileCommands.ts`, not in the
sidebar widget.

### 8.6 Search and quick open (`searchView.zig`, `searchWidget.zig`, `quickAccess.zig`, `quickInput.zig`, `fileIndex.zig`)

The portable search model is under
`workbench/contrib/search/browser/searchTreeModel/` and
`workbench/services/search/`. The view layer now mirrors upstream:
`browser/searchView.zig` is the portable controller (query lifecycle, focus,
messages, replace-all request/execute), `browser/searchResultsView.zig` owns the
data source, ordering and row labels, `browser/searchCompare.zig` ports the
comparers, and `browser/searchActions*.zig` hold the action helpers/runners.
`services/search/common/queryBuilder.zig` builds the text query and
`files.exclude`/`search.exclude` are applied by the service through the ported
glob expression, including `!` exceptions and `{ when: ... }` clauses.
`searchView.zig` is now the terminal adapter: flattened rows, painting, focus
and mouse routing. The flattened path is still a second view model:
`rebuildRows` (427), `applyDefaultCollapse` (457) and `moveToNextMatch` (551)
maintain their own collapse/selection/scroll state instead of using the ported
`ObjectTree`/`CompressibleObjectTree`, and the file has no inline tests. Moving
it onto the ported tree (as the Explorer did) would delete that state and let
the renderer decisions stay in `searchResultsView.zig`. `searchWidget.zig`
remains the terminal form for the upstream `searchWidget.ts` fields/toggles.

Remaining portable pieces:

- `searchActionsFind.ts` is context-menu-only (find in folder/workspace,
  exclude folder/file type) and is not wired because the TUI has no search
  context menu.
- `searchActionsCopy.ts` needs a clipboard service that the terminal does not
  have.
- Search history/memento storage, AI/notebook/search-editor results,
  multi-selection, compressed folder chains and `./`/absolute search-path
  expansion remain unported.

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
- **Logger (P5f, implemented).** `platform/log/common/log.zig` and
  `logService.zig` port `ILogService`/`LogService` (`log.ts:233`,
  `logService.ts:10`), `AbstractLogger`/`AbstractMessageLogger`,
  `AdapterLogger`, `MultiplexLogger`, `NullLogger` and
  `createUnexpectedErrorHandler`. `logger.zig` is the terminal file host over
  them; `app.zig` logs startup/session/exit. Still missing: console loggers,
  the URI-keyed logger registry (`AbstractLoggerService`) and the log-output
  picker (`fileLog.ts`), which need a URI/file-service layer and a workbench
  log picker; the TUI has one `main.log`.
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
`activityBar.zig`, `searchWidget.zig` and `quickInput.zig` are also
terminal-only. Porting the model must not move cell geometry into `src/vs`.
The editor view's fallback status row (`view.zig:355-375, 1639-1698`) is a
standalone/preview adaptation: workbench tabs disable it and use the ported
`StatusbarPart`, so it is not part of the port backlog.

## 9. Prioritized roadmap

The phases are ordered by dependency and risk. P1 is a self-contained cleanup
and behavior port; P4 is the large editor-browser refactor. P2 and P3 can run
in parallel with different owners, but P4 depends on P3’s command/keybinding
layer.

### P1 — Explorer filter and dead-code removal (implemented)

**Goal:** remove the dead legacy Explorer view and move the live filter to the
upstream-shaped module, including the documented exclusion-exception behavior.

**Scope:**

- Move `FilesFilter` from the deleted `src/tui/sidebar.zig` to
  `vs/workbench/contrib/files/browser/views/explorerViewer.zig`.
- Port the missing exclusion expression/traversal pieces from
  `base/common/glob.ts` (`parseExcludeExpression` 735,
  `evaluateExcludeTreeEntry` 817) into `vs/base/common/glob.zig`.
- Keep the TUI tree/filter wiring in `explorerTreeSidebar.zig`; adapt the
  upstream filter through a terminal configuration/ignore adapter.
- Delete the unused direct-painted `Sidebar` and keep `Action` where the live
  tree consumes it.
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
- `workbench/browser/parts/statusbar/statusbarModel.zig`,
  `statusbarPart.zig`, `statusbarItem.zig`, `statusbarActions.zig` and
  `workbench/services/statusbar/browser/statusbar.zig` — status entries,
  alignment, priority, flex part/item, focus, overrides and actions; the
  full-width workbench row replaces the editor-local status string.
- `workbench/browser/layout.zig` — the portable part-visibility/size subset.
- Keep terminal paint/hit testing and the compositor in `workbench.zig`.

**Upstream tests:**
`workbench/test/browser/parts/activitybar/activitybarPart.test.ts` (38),
`workbench/test/browser/parts/sidebar/sidebarPart.test.ts` (1),
`workbench/test/browser/parts/statusbar/statusbarModel.test.ts` (10),
`workbench/test/browser/parts/statusbar/statusbarPart.test.ts` (7),
`workbench/test/browser/parts/statusbar/statusbarItem.test.ts` (10),
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

- Foundation is ported: `base/common/keyCodes.zig` (`KeyCode`, `ScanCode`,
  `KeyMod`, `KeyChord`, `KeyCodeUtils`, `ScanCodeUtils`, immutable/event-key
  maps), `base/common/keybindings.zig` (`KeyCodeChord`, `ScanCodeChord`,
  `Keybinding`, `decodeKeybinding`, `ResolvedKeybinding`), the
  `OperatingSystem` subset of `base/common/platform.zig`,
  `keybindingLabels.zig` and `platform/keybinding/common/baseResolvedKeybinding.zig`
  + `usLayoutResolvedKeybinding.zig` + `resolvedKeybindingItem.zig` +
  `keybindingResolver.zig` (removals/aliases/resolution) and
  `keybindingsRegistry.zig` (default/extension rules, per-OS bindings,
  registration disposal); the full 36-case `keybindingResolver.test.ts` is
  ported; `base/common/actions.zig` ports the base action/runner layer, and
  `platform/action(s)/common` ports `ICommandAction`, the `MenuId` set,
  `MenuRegistry` and `Action2` (command + keybinding + menu registration); `src/tui/keybindings.zig` is the terminal host (event -> dispatch
  string, multi-chord state, command execution) and the workbench tab/group
  shortcuts are wired through it (`workbench.action.closeActiveEditor`,
  next/previous editor, focus group, `openEditorAtIndex1-9`), and the editor
  Ctrl/Alt character shortcuts (save/undo/redo/select/comment/bracket/replace/
  reindent/occurrences/line-selection/indent), the cursor
  navigation/selection keys, line moves/copies, multi-cursor inserts, smart
  selection and the editing keys (enter/tab/outdent/backspace/delete/escape)
  resolve through the same host, together with the find/replace actions and the
  workbench-global shortcuts (quick open/commands, find/replace in files,
  sidebar toggle, status-bar focus, status-bar entry navigation, find-in-files
  Alt+F) and the search-view toggle/replace shortcuts; the 4 `keyCodes.test.ts`
  and 5
  `keybindingLabels.test.ts` cases are ported. `platform/contextkey/common/scanner.zig`
  ports the context-key scanner and its 34 upstream cases;
  `platform/contextkey/common/contextkey.zig` ports the expression model
  (including regex expressions) and the `when`-clause parser with the 33
  upstream parser cases. `contextKeyService` and late-bound constants remain.
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
- Replace `app.zig` dispatch (444-540, 692-841), `workbench.zig` tab/sidebar/
  status maps (1137-1640), `searchView.zig` (604-772), `quickAccess.zig`
  (162-193) and `explorerTreeSidebar.zig` (236-258) key maps.
- Feed `CommandRegistry`/`CommandPickSource` from the action registry. The
  status-bar commands already execute through `statusbarActions.zig`; keep
  `Ctrl-Alt-S` as the documented TUI focus shortcut.

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

**Goal:** split the 6,000-line editor/view monolith (3,789 non-test lines)
into the upstream widget, controller and view-part layers, reusing the ported
model/view model and contributions.

**Status:** step 1 in progress. `editor/browser/view/renderingContext.zig`, the
`IViewLayout` subset in `common/viewModel.zig`, and
`editor/browser/view/viewUserInputEvents.zig` (view-to-model mouse target
conversion incl. view zones) are ported, together with the extended
`MouseTargetType`/view-zone detail; `viewPart.zig`, `viewLayer.zig`,
`viewOverlays.zig` and the thin `View` orchestrator are next; `viewLayer.zig` is also ported (RenderedLinesCollection and the terminal-adapted VisibleLinesCollection window/render loop), with the full `viewLayer.test.ts` case matrix ported; `viewOverlays.zig` ports ViewOverlays/ViewOverlayLine (content/margin subclasses still need layoutInfo options). Visible-lines DOM plumbing stays terminal-side. `viewContext.zig` and `viewPart.zig` (handler registration + prepare/render callbacks) are now ported too, along with `IViewModel.view_layout`/event-handler hooks. The computed-options blocker is removed: `common/config/editorOptions.zig` ports the option value types, `IComputedEditorOptions`, `EditorLayoutInfoComputer` and `EditorWrappingInfoComputer`, `browser/config/editorConfiguration.zig` ports `ComputedEditorOptions` with the upstream defaults and `compute` step, and the 21-case `editorLayoutProvider.test.ts` is ported at the upstream test path. Step 2 has started: `viewParts/viewLines/viewLineOptions.zig`, `viewParts/lineNumbers/lineNumbers.zig`, `viewParts/currentLineHighlight/currentLineHighlight.zig`, `viewParts/selections/selections.zig`, `viewParts/wordWrapIndicator/wordWrapIndicator.zig`, the glyph-margin dedup helpers, the line/margin decoration overlays and the view cursors are ported (structured terminal data instead of DOM HTML) with focused tests, and `ViewPart`/`DynamicViewOverlay` now initialize in place so registered handlers point at the final object. `viewParts/viewLines/viewLine.zig` now provides the terminal `IVisibleLine` over the shared renderer, and `viewLines.zig` renders the viewport window into a `StringBuilder` and implements `IViewLines` with cell-column ranges (the ported `Range.intersectRanges` column bug was fixed while testing it). `browser/view/viewController.zig` ports the mouse dispatch decision tree through an explicit navigation-command sink and the double-click block selection (bracket content, matching-quote string content, RTL/mismatch bail-outs); the complete `viewController.test.ts` suite is ported (bracket/string happy paths, exotic token spans, RTL/mismatch bail-outs and word-select fallbacks), with a per-test token-span harness in the ported test. `browser/view.zig` now provides the terminal `View` orchestrator: it owns `viewLines` plus registered view parts/content overlays, fans view events (configuration, cursor, decorations, flushed/lines/scroll/tokens/zones/theme/focus) across them, and runs the prepare-render/text-render/part-render pipeline; DOM edit-context/animation-frame plumbing is documented as absent and the TUI paints the parts' structured data. `common/viewModel/viewModelImpl.zig` now ports a terminal `ViewModel` subset
(projected lines + converter, `IViewModel` metrics/rendering data, selections,
focus, viewport and cell-height layout, model content-change application, glyph-margin lane computation,
view-event dispatch to registered handlers (including cursor state), plus
model-decoration viewport mapping into view ranges and inline decoration
data) with tests, including end-to-end
rendering through `VisibleLinesCollection` and the terminal `codeEditorWidget` subset
(model/configuration/view-model/view ownership, `render`, selections, focus and
cell positions) and `ViewModelDecorations` now supplies inline-decoration
viewport data to the renderer. The browser cursor controller and the full outgoing-event dispatcher remain.

**Suggested commits:**

1. `editor/browser/view/viewPart.zig`, `editor/browser/view/renderingContext.zig`,
   `editor/browser/view/viewLayer.zig`, `editor/browser/view/viewOverlays.zig`
   scaffolding; a thin `View` orchestrator.
2. `editor/browser/viewParts/viewLines/viewLines.zig`,
   `editor/browser/viewParts/viewLines/viewLine.zig`,
   `editor/browser/viewParts/lineNumbers/lineNumbers.zig`,
   `editor/browser/viewParts/currentLineHighlight/currentLineHighlight.zig`;
   move the `rebuild` line loop (843-1182) and the run/inline-decoration
   helpers (1699-1910) out of `view.zig`.
3. `editor/browser/viewParts/selections/selections.zig`,
   `editor/browser/viewParts/viewCursors/viewCursors.zig` +
   `viewCursor.zig`; move selection/cursor cell state (816-831, 1794-1834).
4. `editor/browser/viewParts/decorations/decorations.zig`,
   `editor/browser/viewParts/contentWidgets/contentWidgets.zig`,
   `editor/browser/viewParts/overlayWidgets/overlayWidgets.zig`; move the
   current decoration classes and overlay/content anchoring (1183-1236,
   1388-1524).
5. `editor/browser/viewParts/editorScrollbar/editorScrollbar.zig`; keep the
   ported overview ruler and `ScrollbarState` (1237-1387).
6. `editor/browser/view/viewController.zig`; move position/selection commands
   out of `Editor` (715-928, 1375-1402).
7. `editor/browser/controller/mouseTarget.zig`,
   `editor/browser/controller/mouseHandler.zig`,
   `editor/browser/controller/pointerHandler.zig`; move hit testing and
   mouse target/drag behavior (481-756).
8. `editor/browser/widget/codeEditor/codeEditorWidget.zig` +
   `editor/browser/widget/codeEditor/codeEditorContributions.zig`; move editor
   lifecycle/config/command wrappers/contribution host out of `editor.zig`
   (181-324, 929-1747) and `tab.zig` (43-270). Move the `tabBar.zig` strip
   rules to `editorTabsControl.zig`/`singleEditorTabsControl.zig` in the same
   slice.

`editor/browser/config/editorConfiguration.zig` and the used subset of
`editor/common/config/editorOptions.ts` should land with step 8 (or step 1 if
the view needs options first).

**Upstream tests:** `editor/test/browser/view/viewController.test.ts` (17),
`editor/test/browser/view/viewLayer.test.ts` (4),
`editor/test/browser/widget/codeEditorWidget.test.ts` (13),
`editor/test/browser/controller/cursor.test.ts` (206),
`editor/test/browser/viewModel/viewModelDecorations.test.ts`, plus the
existing TUI snapshot tests which must keep passing. The 37 `view.zig` tests
(starting at line 1936) and 31 `editor.zig` tests (starting at line 1855)
move with their subjects.

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
| P5a Storage/memento | `session.zig` | `platform/storage/common/storage.ts`, `workbench/common/memento.ts` | `platform/storage/test/common/storageService.test.ts` (10, ported), `workbench/test/common/memento.test.ts` (4, ported); `session.zig` still uses its host format | M |
| P5b Fuzzy scoring | `fileIndex.zig` | `base/common/fuzzyScorer.ts` | `base/test/common/fuzzyScorer.test.ts` (68) | M |
| P5c Theme service | `theme.zig`, `syntaxTheme.zig`, hard-coded palettes | `workbench/services/themes/browser/workbenchThemeService.ts`, `platform/theme/common/themeService.ts` | `workbench/services/themes/test/common/workbenchThemeService.test.ts` (4), `workbench/services/themes/test/common/colorThemeData.test.ts` (5) | M/L |
| P5d Language service | `language.zig`, `languageConfiguration.zig` | `workbench/services/language/common/languageService.ts`, `editor/common/languages/languageConfigurationRegistry.ts` | `editor/test/common/modes/languageConfiguration.test.ts` | M |
| P5e File/editor input | `editorInput.zig` | `workbench/contrib/files/browser/editors/fileEditorInput.ts`, `workbench/services/textfile/common/textFileEditorModel.ts`, file service | `workbench/contrib/files/test/browser/fileEditorInput.test.ts` (17), `workbench/services/textfile/test/browser/textFileEditorModel.test.ts` (55) | L |
| P5f Log service (implemented) | `logger.zig` | `platform/log/common/log.ts`, `platform/log/common/logService.ts` | `platform/log/test/common/log.test.ts` (10) | S |
| P5g Search actions/config | `searchView.zig`, `searchWidget.zig`, `fileIndex.zig` | `workbench/contrib/search/browser/searchActions*.ts`, `workbench/contrib/search/browser/searchView.ts`, `workbench/contrib/search/browser/searchWidget.ts`, search service | `workbench/contrib/search/test/browser/searchActions.test.ts` (6), `workbench/contrib/search/test/browser/searchWidget.test.ts` (1), `workbench/contrib/search/test/browser/searchView.test.ts` (2) | M |
| P5h Settings watch | `settingsWatcher.zig` | `workbench/services/configuration/browser/configurationService.zig`, file service | `workbench/services/configuration/test/browser/configurationService.test.ts` | S |

**P5a status:** `platform/storage/common/storage.zig` ports the in-memory
storage service (scopes/targets, value stringification, key-target bookkeeping,
change events, `storeAll`, `remove`, `keys`, `isNew`, `flush`). Async
initialization, database persistence, profile/workspace switching and
cross-window propagation are terminal deviations. The full 10-case
`storageService.test.ts` is ported at the upstream test path against the
synchronous harness, including scoped/key-filtered change events and
key/target bookkeeping.
`workbench/common/memento.zig` is ported on top of it: the upstream static maps
become an explicit `MementoStore` (shared id -> scoped object), and a memento
value is a `std.json.ObjectMap` mutated through `put/get/remove/clear`; all four
`memento.test.ts` cases are ported at
`workbench/test/common/memento.test.zig`. `src/tui/session.zig` writes the
editor part through storage + memento under `memento/editorPart` (the explicit
`--session` file hosts the value) and still loads legacy bare-part files. The
older single-group save/load helpers were retired; the part path is the only
session format left.

**P5c status:** the `Color` HSL/mix/opacity helpers and
`platform/theme/common/colorUtils.zig` are ported: color transforms (three
upstream `colorUtils.test.ts` cases) and an explicit `ColorRegistry`
(contributions, per-theme defaults, update/deregister/resolve, schema-change
event). `platform/theme/common/sizeUtils.zig` ports the size registry
(values/defaults/customizations/circular-reference detection, CSS helpers,
bounded-int customization schema), with `sizes/baseSizes.zig`/`semanticSizes.zig`
registering the base and semantic tokens; the full `sizeRegistry.test.ts` suite
passes (schema data is a plain map, not a JSON-contribution registry). `workbench/services/themes/common/colorThemeData.zig` ports the
in-memory theme data (theme/custom/transient colors, derived defaults, base
theme, token background cache and profile-storage round-trip); four of the five
`colorThemeData.test.ts` cases pass, while `ensureLoaded` now also ports the
JSON/JSONC `include` chain (base colors first, derived overrides, token rules
appended) and tmTheme parsing through an explicit resource reader; the
extension resource loader/watch are host-provided. `browser/workbenchThemeService.zig` now ports the
terminal theme service (explicit registration, active-theme persistence,
`ThemeSettings`/`ThemeSettingDefaults` and `migrateThemeSettingsId` with its
three cases), and `common/themeConfiguration.zig` ports the color-theme
selection/preference subset of `ThemeConfiguration` (`getColorTheme`,
customizations, preferred color scheme, `isPreferredColorSchemeChange` and the
color-theme setting id); the four `workbenchThemeService.test.ts` cases are
ported at the upstream test path. `registerThemeConfigurationSchemas` also ports
the static settings contribution (color theme, preferred themes, customization
objects, auto-detect flags with their defaults/scopes, and the token
customization settings). The extension-point theme enums/dynamic schema updates,
the icon-theme getters and the `fontSize`->`lineHeight` token-customization
rewrite remain.

**P5d status:** `editor/common/services/languagesAssociations.zig` ports the
platform/configured language association registry, path/first-line matching
(exact filename, longest pattern, longest extension, registration order,
first-line predicates, data-URI labels) and the 10 upstream
`languagesAssociations.test.ts` cases; `base/common/strings.zig` gained
`endsWithIgnoreCase`. The editor `LanguageService` now registers association
entries for every language contribution and resolves file paths through the
matcher (filename > pattern > longest case-insensitive extension, later
registrations win); first-line matching keeps the simple prefix/suffix form.
`languageConfigurationRegistry.zig`
now carries the upstream registry (priority ordering, `combineLanguageConfigurations`, plaintext default,
change events) and the 11 `languageConfiguration.test.ts` cases pass; the TUI
`languageConfiguration.zig` service consumes it. The existing
`languages/supports/onEnter.zig` is now wired into the resolved configuration:
`ResolvedLanguageConfiguration` builds `OnEnterSupport` when the language has
brackets, indentation rules or onEnter rules, delegates `onEnter` to it, and
releases its bracket/rule regexes when the resolved configuration is
invalidated; the editor/TUI `onEnter` call sites use the service configuration.
The upstream `onEnter.test.ts` cases (including the JavaScript rule fixture)
and registry integration/lifecycle tests pass.
The resolved configuration also builds `RichEditBrackets` and
`BracketElectricCharacterSupport` eagerly (upstream lazily) and exposes
`getBrackets`/`getElectricCharacter`, releasing the bracket regexes when the
configuration is invalidated. The TUI consumes the theme service: `syntaxTheme.initFromThemeService` loads
`dark_plus.json` (with its `dark_vs.json` include) through `ColorThemeData` and
converts its token colors into the editor `TokenTheme`; `app.zig` uses it with
the bundled loader as a fallback, and a test asserts the resulting color map
matches the legacy loader. The workbench registration surface is ported in
`workbench/services/language/common/languageService.zig`
(`WorkbenchLanguageService`: contribution validation/registration and
`files.associations` → configured associations), and the TUI editor resolves
paths through the service's association matcher instead of the removed
`language.zig` extension map. Remaining host wiring: feed the TUI
`files.associations` setting into `updateMime` and implement the
`onLanguage` activation hook (a no-op without an extension host).

**P5f status:** `log.zig`, `logService.zig`, `bufferLog.zig` and
`errorMessage.zig` exist under the mirrored paths, the 10 upstream
`log.test.ts` cases are ported and registered, and `app.zig`/`logger.zig`
consume `ILogService`. The console loggers and the URI-keyed logger registry
remain unported for the reasons in §8.6; README documents the single-file
logging scope.

**P5b status:** `base/common/fuzzyScorer.zig` ports query preparation
(`prepareQuery`/`pieceToQuery`), the `scoreFuzzy` matrix and character scoring,
`scoreFuzzy2`, item label/description/path scoring, item comparison and the
optional scorer cache; `base/common/comparers.zig` now also has
`compareAnything`/`compareByPrefix` for the comparison fallback. 26 upstream
`fuzzyScorer.test.ts` cases (including the resource ordering/scattering matrix)
are ported and registered. The `filters.fuzzyScore` dynamic-programming scorer
(`filters.ts`) is ported as an explicit `FuzzyScorer` (scratch tables, no
globals), with its `fuzzyScore` regression and top-score cases, and `scoreFuzzy2` now uses it.
The #134723 item case passes; only the exact upstream cache-hash identity cases
and the ICU collation cases remain (the terminal cache key is a readable composite; Unicode fuzzy highlighting now scores per codepoint and the emoji #113404 case is ported). `fileIndex.zig` now
scores via `scoreItemFuzzy` (label/description/path, all query words required)
instead of its ad-hoc matcher.

**P5g status:** the `search.test.ts` suite is fully ported
(`TextSearchMatch` previews including byte-column elision, `isFilePatternMatch`,
`QueryGlobTester`/provider exclude exceptions and exception counts), and the
search action/view tests under `contrib/search/test/browser` are ported for the
terminal tree model. Search quick-access and anything quick-access remain tied
to the quick-input widget gaps.

**P5h status:** `platform/configuration/common/configurationModels.zig` now
parses language-override blocks (`[x][y]`, duplicate identifiers dropped),
supports the `exclude` parse option, and ports the ConfigurationModel parsing
cases (override identifiers, exclude/exclude-with-include, invalid keys, null
values), the setValue/removeValue segmented-key cases, and override-model/merge cases (with `ConfigurationModel.override`, override-preserving merges and identifier precedence). `configurationRegistry.zig` also
has explicit property registration with default merging, disallowed defaults and
policy deduplication, policy references, and hidden/excluded and agent-host settings, node deregistration, source-tracked default contributions (including the effective value source) with deregistration/rebuild, covering the `configurationRegistry.test.ts` cases through deregistration;
schema/scope/policy-reference/excluded-property cases remain. `configurationVariables.zig` (variable parsing/scanning) and its test suite are
ported too. `configurationService.zig` ports an in-memory user-target `ConfigurationService`
(getValue/inspect/updateValue, default-value removal, non-user target rejection),
with the update, workspace-document, DEFAULT change events, restricted-setting trust filtering, language-override fallback (including missing identifiers), invalid/non-object workspace
reset, override-aware `affectsConfiguration`,
workspace-reload inspect, `isConfigured` and override-aware inspect cases from
`configurationService.test.ts`;
enforced policy configuration and folder scoping are covered; remote scoping is a documented terminal omission.
`workbench/services/configuration/browser/configurationService.zig` already
provides the file-backed workspace service (user/workspace/folder scopes,
`.code-workspace`, settings watcher) with five terminal workspace-scope tests;
the 198-case upstream file is otherwise unported. `configurations.zig` ports the explicit `DefaultConfiguration` model lifecycle
(with automatic registry-change updates, JSON default contributions and
language-override defaults),
(initialize/reload/property updates, override-identifier values), with the
registration, override and deregistration cases (including merged language object defaults) from `configurations.test.ts`. The merge/remove helper cases in `configuration.test.ts` are also ported
(except the `__proto__` pollution case, which is N/A for Zig maps). The
registry/scope-dependent cases (`configurationRegistry`,
`configuration.test`, `configurations`, `policyConfiguration`,
`configurationService`, `configurationVariables`) remain, as does the TUI
settings watcher's upstream parity pass.

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
- Read-only preview mode (`preview.zig`); the mode stays, but its duplicate
  renderer should be folded into a read-only `Editor`/`View` (see §7.1).
- The word/token hover stand-in (`hoverProvider.zig`) until a language
  extension host exists.
- Console loggers, the URI-keyed `ILoggerService` registry and the log-output
  picker; the TUI has one `main.log` and owns the terminal (see §8.6).
- Browser-only editor features already documented as deviations in
  `docs/terminal-ui.md` (DOM/CSS, subpixel geometry, IME, native selection,
  minimap, pixel lanes, HTML/CSS parsers, compositor).
- UTF-8 helper replacement is deferred until the base `strings.zig` surface
  is confirmed equivalent; it is utility code, not an upstream port.

## 12. Assumptions and open questions

**Assumptions**

- This snapshot is `src/tui/` at HEAD `cd69afb` (28 files, 19,012 lines);
  the status bar (`413fa55`), the Search view (`f10e1a6`), P1/P2 and P5f
  (`cd69afb`) landed after the original audit. Refresh the line numbers when
  HEAD moves.
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

**Current implementation snapshot (clean build, 2,124 editor tests + 187 UI
tests + 58/60 textmate tests):** P1, P2 and P3 are ported (explorer filter,
shell/parts models, actions/menus/keybindings/context keys). P4 is complete for
the terminal shape: the view/rendering stack (view contexts, parts, overlays,
rendered/visible lines), computed editor options, `View`, `viewController`, the
terminal `codeEditorWidget`, `ViewModel` (lines, selections, decorations, glyph
lanes, event dispatcher), cursor selection/state, and whitespace/control
character rendering, with the DOM-only parts documented as omissions. P5a/P5b/P5f/P5g
are complete; P5c has color-theme data/registry/loading, a terminal
workbench theme service (+ its test suite) and the size registry; P5h has the
configuration model parser/filters/merges/overrides, registry defaults/policies/
deregistration, variables, DefaultConfiguration, an in-memory user-target
ConfigurationService and `ExperimentalSettingsService`; P5d is ported (associations, workbench registration
surface, TUI path matching and settings-driven `files.associations` applied to
opened editors and on settings reload); P5e has the URI/file-service/editor-input foundation, the provider contracts,
the in-memory provider, the provider-registry `FileService` (with the upstream
in-memory service suite) and the disk provider (provider contract over
`std.Io`, watch-request filtering and host-forwarded change delivery, with
direct/service/watcher tests), BOM-based UTF-8/UTF-16 encoding
(detect/decode/encode), encoding-preserving text-file-model load/save and
save participants (modify/skip/error), soft/hard revert with revert events and
the working-copy registry/dirty tracking with its events, the working-copy
editor handler registry/find path, all wired to TUI editors on
open/restore/close; heuristic charset guessing is a documented terminal
omission; clean editors
now reload on external changes
(`Workbench.handleFileChanges` → `Editor.reloadFromDisk`), with dirty editors
preserved and marked as conflicted (status message, cleared by save/reload or the `workbench.action.files.revert` command); the workbench now
starts a `UniversalWatcher` for absolute workspace folders and forwards its
changes into that handler. The working-copy model includes the registry/editor service, save participants
and in-memory history/backups; disk persistence and the browser conflict
notification UI are documented terminal omissions.

**Status at the end of the current session:** 2,124 editor tests, 187 UI tests
and 58/60 textmate tests pass from a clean build. All inventory slices are
implemented in terminal shape. P4 includes the terminal `View`, controller,
`codeEditorWidget`, `ViewModel` (lines/decorations/glyph lanes/event
dispatcher), cursor selection/state and renderer features; P5e includes the
provider/disk file services, encoding, save participants, revert, working-copy
registry/editor service and in-memory backups/history wired to the TUI. The
remaining differences are the documented terminal omissions below (plus the
browser-only view/tab DOM parts).

**Documented terminal omissions**

- **Icon themes** (P5c): the terminal has no icon surface (file icons, codicon
  image sprites); theme color data is ported, but icon theme data has no
  corresponding capability. Extension-enumerated theme values are also absent
  because the terminal has no extension host that could register themes at
  runtime.
- **Heuristic charset guessing** (P5e): ANSI/ShiftJIS detection depends on
  jschardet/ICU, which the terminal does not ship; BOM-based UTF-8/UTF-16
  detection is ported.
- **Disk working-copy backups/history** (P5e): the terminal backup and history
  services keep entries in memory; the node storage/serialization layers are
  omitted.
- **Remote configuration/experiment suites** (P5h): they require a remote
  agent, remote environment and remote configuration channel, none of which
  exist in the terminal host.
- **Browser-only view parts** (P4): `blockDecorations` and `viewZones` need
  variable-height/extra rows outside the terminal's fixed cell grid;
  `contentWidgets`/`overlayWidgets` are replaced by the TUI `ui` widget layer;
  the margin view parts are implemented directly by the TUI gutter; `rulers`
  draw background lines behind text (the terminal renderer has no per-column
  background layer); `scrollDecoration` is a CSS shadow; inline decorations
  are delivered through the line renderer instead of a DOM part.
- **Browser tooltip/focus DOM cases** (P2): the TUI status bar and tab strip
  are `ui` nodes without the browser managed-hover/focus DOM; the portable
  state machines they exercise are covered by the status/tab model tests.

**Remaining upstream files by slice**

| Slice | Remaining upstream work |
| --- | --- |
| P4 | `editor/browser/view.ts`, `viewController.ts` and the terminal `codeEditorWidget` subset are ported, along with the view stack, computed options, whitespace/control characters and inline decorations; a terminal `CursorsController` selection/state subset and the `ViewModelEventDispatcher` (handler registry + re-entrant queue) are ported; typing/command orchestration stays in the TUI editor |
| P5e | URI/VSBuffer/file types, the disk-backed service, the provider registry + in-memory/disk providers with change events, text-file service/encoding/save participants/revert, working-copy registry/editor service, in-memory backups/history, editor inputs/serializers and composite matching are ported; disk backup/history persistence remains |
| P5c | `tokenClassificationRegistry`, the TextMate scope matcher, `ColorThemeData` token-style resolution, the terminal `workbenchThemeService` (registration/persistence/migrations) and the `ThemeConfiguration` color-theme/preference subset and its static settings schemas are ported; icon themes and extension-enumerated theme values are documented terminal omissions, and theme settings re-application is host wiring |
| P5h | in-memory policy service, `PolicyConfiguration`, language overrides, scope/trust filtering and `ExperimentalSettingsService` (assignments/coalescing/keyed requests) are ported; remote-agent configuration suites are a documented terminal omission |
| P2 | `multiEditorTabsControl.test.ts` and browser tooltip cases are DOM-specific (documented terminal omissions); `editorGroupModel.test.ts` has the direct-vs-side-by-side open/index preferences and the remaining explorer tree cases are covered by the TUI tree tests |
| filters | `Intl.Collator` locale ordering (ICU-dependent) |

**Known blockers for the remaining work**

- `matchesContiguousSubString`, `matchesSubString`, `matchesPrefix`,
  `matchesStrictPrefix` and `matchesCamelCase` are ported with their upstream
  cases (including camel-case heuristics, weak-first fuzzy scoring and the
  many-matches, graceful-permutation, #26423/#26995/#26511 and
  separator-only, top-score ranking and HTML closing-tag cases, plus the
  `patternPos`/`wordPos`, anyScore-highlight, truncated-filter-text and
  Go-to-Symbol regressions; a signed
  skipped-character penalty fixes a pattern-start underflow found there);
  separator equivalence, `C++`, punctuation boundaries, the basic word cases
  and the Japanese/Umlaut WordFilter cases are covered by the recursive port
  (ASCII + Latin-1 case folding; other scripts compare byte-for-byte).
- The remaining workbench configuration-service cases are the 198-case browser
  harness and the remote-scope suites (documented terminal omissions).
- Workbench extension-contribution registration is absent by design (no
  extension host).
- The `base/test/browser/comparers.test.ts` suite depends on `Intl.Collator`
  locale rules (punctuation order, case grouping); the terminal
  `compareFileNames` is a documented natural/unicode approximation; the numeric/equality/extension/path assertions are ported in
  `base/test/browser/comparers.test.zig`, while
  the locale-specific punctuation/case-group cases remain unported.

**Open questions**

- Should P3 (commands) or P4's view-part steps start first? P3 unblocks the
  input/caller side; P4 steps 1-5 (the view parts) can start in parallel if the
  `View` orchestrator boundary stays explicit.
- Should the `preview.zig` duplicate renderer be folded into a read-only
  `View` (small, removes ~300 lines) before or during P4?
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
| `workbench/test/browser/parts/statusbar/statusbarPart.test.ts` | 329 | 7 | P2 |
| `workbench/test/browser/parts/statusbar/statusbarItem.test.ts` | 237 | 10 | P2 |
| `workbench/test/browser/layout.test.ts` | 121 | 2 | P2 |
| `workbench/test/browser/parts/editor/multiEditorTabsControl.test.ts` | 4,786 | 102 | P2 |
| `base/test/common/keyCodes.test.ts` | 138 | 4 | P3 |
| `platform/keybinding/test/common/keybindingLabels.test.ts` | 177 | 5 | P3 |
| `platform/contextkey/test/common/scanner.test.ts` | 251 | 34 | P3 |
| `platform/contextkey/test/common/parser.test.ts` | 233 | 33 | P3 |
| `platform/contextkey/test/common/contextkey.test.ts` | 435 | 24 | P3 (expression/in/implies/comparison cases ported) |
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
