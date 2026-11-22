# View fidelity audit

Status: work in progress.

Upstream: VS Code **1.147.0**, `vscode/` at `e31c2e52f563620846caab877103f630ea361b9c`.
Local: `src/` and `ui/` of this repository.

This document is the audit ledger for the view plan. Every rendered view gets
one row. A row is closed only when it has a verdict, evidence (`file:line`), the
fix (or the documented terminal exception), and the tests that cover it.

## Verdicts

| Verdict | Meaning |
|---------|---------|
| **F** | Faithful port/adaptation: upstream structure, options, theme and behavior are preserved; only the terminal paint/input boundary differs. |
| **T** | Terminal adaptation: the view intentionally differs because a cell grid cannot express the browser behavior; the exact limitation is documented in the file header, `README.md` and `docs/terminal-ui.md`. |
| **P** | Partial: the upstream model/controller exists, but parts of the view logic, controls, options, theme, or tests are missing. |
| **A** | Ad-hoc: the view is a terminal-only painter without the upstream control/view-part structure. Fix required. |
| **M** | Missing: upstream has the view, this repository has no implementation. Decide implement-or-document. |

## Audit procedure

For each row:

1. Read the local Zig file(s), the upstream `.ts` file(s) and the upstream test.
2. Compare structure (Part/ViewPart/widget lifecycle, model -> view -> controller,
   events), view logic (ordering, decoration classes, options, hit testing,
   clipping), theme ids, interaction (keyboard/mouse/focus/hover/drag/context
   menu) and tests.
3. Record the verdict and evidence here.
4. Fix if needed; keep upstream names/structure and put terminal substitutions
   only at the paint/input boundary.
5. Add or port tests.
6. Update the file header, `README.md` and `docs/terminal-ui.md` for any
   remaining terminal exception.
7. Run `zig build`, the focused tests, `zig fmt` and `git diff --check`.

## Group 1 — views named in the request

| View | Local | Upstream | Verdict | Evidence / next action |
|------|-------|----------|---------|------------------------|
| Find & replace overlay | `vs/editor/contrib/find/browser/findWidget.zig`, `findController.zig`, `findModel.zig`, `findDecorations.zig` | `editor/contrib/find/browser/findWidget.ts`, `findController.ts`, `findModel.ts`, `findDecorations.ts` | **T** | Controller/model/state/decorations are ported and tested (`findController.test.zig`). The terminal bar now has the upstream control set (replace toggle, previous, next, close, match count, Aa/ab/.*/Sel, preserve-case, replace-one, replace-all), hit tests and a host-resolved `Theme` bundle (`editorWidget.*`, `input.*`, `inputOption.*`). `editor.find.findOnType`, `closeOnResult`, `loop` and
`seedSearchStringFromSelection` (never/always/selection) and
`autoFindInSelection` (never/always/multiline) and
`editor.find.history`/`replaceHistory` enablement are honored. The terminal find view zone reserves the bar's 1-2 rows above line 1 when `editor.find.addExtraSpaceOnTop` is enabled; text, cursor and hit testing shift below it. The inset is applied while line 1 is at the top and released when the editor scrolls; unlike the browser zone it does not add scrollable space above line 1. Documented terminal omissions: no focusable buttons, browser accessibility tree or macOS shared find clipboard. The browser sash is replaced by a draggable terminal sash. Find- and replace-input history is navigated with Up/Down. New control/theme/view-zone tests in `findController.test.zig`. |
| Gutter / margin | `vs/editor/browser/viewParts/margin/margin.zig`, `lineNumbers/`, `glyphMargin/`, `linesDecorations/`, `marginDecorations/`, folding decorations | `editor/browser/viewParts/margin/`, `lineNumbers/`, `glyphMargin/`, `linesDecorations/`, `marginDecorations/`, `editor/contrib/folding/browser/` | **F** | Line-number and quick-diff data are ported and painted; the terminal `Theme` bundle resolves `editorLineNumber.foreground/activeForeground`, `editorGutter.foldingControlForeground`, `editorGutter.{added,modified,deleted}Background`, and the active line number is detected. Gutter widths follow `lineNumbers`, `lineNumbersMinChars`, `folding`/`showFoldingControls` and `lineDecorationsWidth`. The glyph-margin host paints themed glyphs in up to three compacted lanes, maps the known glyph classes to `●`/`▲`, reports `.gutter_glyph_margin` hit targets, reserves lanes only while a glyph decoration exists, and renders `glyphMarginHoverMessage` as a one-line content-widget tooltip. Both current-line overlays are ported: `renderLineHighlight: gutter|all` paints the gutter row background, with a regression test. `marginClassName` decorations are wired through `MarginViewLineDecorationsOverlay`; the known diff/edit classes tint the gutter row. `linesDecorationsClassName` maps `insert-sign`, `delete-sign`, `comment-range-glyph` and `first-line` to marker-cell glyphs; the marker cell is now reserved automatically while such a decoration exists and released when it disappears. `renderLineHighlightOnlyWhenFocus` follows the workbench focus forwarded to `View.setFocused`, and glyph hover messages render as a one-line content-widget tooltip. Unknown decoration classes remain invisible like classes without CSS. |
| Status bar | `vs/workbench/browser/parts/statusbar/statusbarPart.zig`, `statusbarModel.zig`, `statusbarItem.zig`, `statusbarActions.zig` | `workbench/browser/parts/statusbar/statusbarPart.ts`, `statusbarModel.ts`, `statusbarItem.ts`, `statusbarActions.ts` | **T** | Model/part/item split, ordering, compact flags, focus and hit testing are ported. Item kinds now resolve `statusBarItem.{prominent,warning,error,remote,offline}{Background,Foreground,HoverBackground,HoverForeground}` and `statusBarItem.hoverBackground` through a terminal `Theme`. Compact-group hover lights the referenced entry through `statusBarItem.compactHoverBackground`, the extra flex gap was removed, and a right-click opens the `statusbarActions.zig` Hide/Manage Extension actions through the quick pick. Escape now dismisses the hover tooltip while the status bar is focused; tooltip pinning and the browser's non-action context-menu parts remain documented terminal omissions. |
| Tab bar / title control | `vs/workbench/browser/parts/editor/multiEditorTabsControl.zig`, `editorGroupView.zig`, tab sections of `workbench/browser/workbench.zig` | `workbench/browser/parts/editor/editorTabsControl.ts`, `singleEditorTabsControl.ts`, `multiEditorTabsControl.ts`, `editorTitleControl.ts` | **T** | Right-click opens a terminal context menu (Close, Close Others, Close to the Right, Close Saved, Close All, Pin/Unpin, Split Right/Down) instead of closing or activating a tab; hover foreground/background, `tab.border`, `tab.lastPinnedBorder` and the cell-border active top stroke are themed and tested. Duplicate labels now append a dimmed directory description and `workbench.editor.labelFormat` (default/short/medium/long) is read. Clicking the leading ellipsis opens a quick pick of the clipped tabs, `workbench.editor.tabCloseButton` supports off/left/right, `workbench.editor.tabSizing` supports fit/shrink/fixed, and `workbench.editor.showTabs` none/single hides the row and reclaims its cells for content. The terminal uses one retained strip instead of the browser `EditorTabsControl` class hierarchy; `showTabs`, `tabSizing`, `tabCloseButton`, labels, hover/borders, context actions and clickable overflow share that strip. The browser tab action toolbar and the separate pinned-tabs row (`pinnedTabsOnSeparateRow`) are omitted as terminal layout adaptations. |
| Breadcrumbs | `vs/workbench/browser/parts/editor/breadcrumbsControl.zig`, `breadcrumbsModel.zig`, `breadcrumbsPicker.zig`, `breadcrumbs.zig`, `vs/base/browser/ui/breadcrumbs/breadcrumbsWidget.zig` | `workbench/browser/parts/editor/breadcrumbsControl.ts`, `breadcrumbsModel.ts`, `breadcrumbsPicker.ts`, `breadcrumbs.ts`, `base/browser/ui/breadcrumbs/breadcrumbsWidget.ts` | **T** | Inactive groups now keep one persistent breadcrumb control (no per-frame outline rebuild); widget hits respect `enabled`, hover only applies when not focused/selected, `focused.selected` uses `breadcrumb.activeSelectionForeground`, and separators inherit `breadcrumb.foreground`. Also fixed the split path leaving a group without an active tab, the workspace-root inclusion rule, and the picker's leading `..` parent entry. The widget exposes `onDidSelectItem`/`onDidFocusItem`/`onDidChangeFocus` and the control fires them. Files under `$HOME` outside the workspace get a `~` root segment (upstream per-component labels are collapsed). The browser editor-type dropdown, breadcrumb drag-and-drop and the outline sibling pick list have no terminal cell equivalent; the terminal reveals outline elements directly and uses the quick pick for directories. |

## Group 2 — remaining editor views and widgets

| View | Local | Upstream | Verdict | Evidence / next action |
|------|-------|----------|---------|------------------------|
| View orchestrator | `vs/editor/browser/view.zig`, `view/viewPart.zig`, `viewLayer.zig`, `viewOverlays.zig`, `renderingContext.zig` | `editor/browser/view.ts`, `view/*.ts` | **F** | Ported `View`/`ViewPart`/content-overlay lifecycle, event fan-out, focus, render scheduling and the accumulated render path. Tests cover part registration, configuration/focus fan-out, line widths/offsets, render scheduling and the `ViewFocusChanged` event. The terminal frame driver substitutes for the browser animation frame only. |
| View lines / whitespace / word wrap | `vs/editor/browser/viewParts/viewLines/` | `editor/browser/viewParts/viewLines/` | **T** | `ViewLines`/line renderer keep the upstream view-line data and wrapping/whitespace/control-character decisions; the cell grid replaces DOM line nodes and subpixel geometry. Wrapped-line/whitespace behavior is covered by the view-line tests. |
| Current line highlight | `vs/editor/browser/viewParts/currentLineHighlight/` | same | **F** | Both content and margin overlays are registered; `renderLineHighlight` (`line`/`gutter`/`all`/`none`), empty-selection, wrapped-line and focus-only rules are ported, and the theme resolves `editor.lineHighlightBackground`. Covered by overlay + View tests (`892f580`, `f04dff1`). |
| Indent guides | `vs/editor/browser/viewParts/indentGuides/` | same | **T** | Vertical bracket-pair guides, nesting levels, active scope and theme pools are ported through `guidesTextModelPart`; horizontal bracket-guide segments are not painted because a cell row cannot carry browser HTML overlays. The omission is documented in the file header. |
| Selections | `vs/editor/browser/viewParts/selections/` | same | **T** | Multi-selection range/style computation, insets and focus rules are ported; the cell grid cannot paint rounded corners, so the inner/outer corner pieces collapse to rectangle ranges. Theme resolution and range tests are present. |
| View cursors | `vs/editor/browser/viewParts/viewCursors/` | same | **T** | Plurality, primary/secondary styling and focus are ported; the terminal paints block cells and keeps the hardware cursor as the terminal boundary, with no browser IME/composition or subpixel caret. Covered by cursor tests. |
| Decoration overlays | `vs/editor/browser/viewParts/decorations/` + `src/tui/editorView.zig` | `editor/browser/viewParts/decorations/decorations.ts` | **T** | Whole-line/range class lists, merge order and visible cell ranges are ported; find/word/bracket/diagnostic classes route through the terminal style map with theme colors. `shouldFillLineOnLineBreak` has no cell representation and is omitted (documented in the header/terminal-ui). |
| Scrollbar | `vs/editor/browser/viewParts/editorScrollbar/editorScrollbar.zig` | `editor/browser/viewParts/editorScrollbar/editorScrollbar.ts` | **T** | The accepted 3-lane cell geometry replaces the pixel scrollbar; wheel/drag/hit and `scrollbarSlider.*` theme resolution are ported and tested. Arrow buttons/rounded slider CSS are omitted as browser-only. |
| Overview ruler | `vs/editor/browser/viewParts/overviewRuler/decorationsOverviewRuler.zig` | `editor/browser/viewParts/overviewRuler/decorationsOverviewRuler.ts` | **T** | The upstream line-to-row projection, lane choice and z-index/group paint order are kept; the canvas collapses to one terminal column and one-cell minimum heights. Lane, multi-line, z-order, cursor and collapse tests pass. |
| Content widgets | `vs/editor/browser/viewParts/contentWidgets/` | same | **F** | Registry, anchor-to-cell mapping, above/below placement, clamping, hit rectangles, insertion order and focus restore are ported. Below/above anchoring, clamping, multi-widget order and focus are covered by tests. |
| Overlay widgets | `vs/editor/browser/viewParts/overlayWidgets/` | same | **F** | Corner preferences, size, insertion paint order, hit rectangles and focus restoration are ported; origin, top-right, bottom-right and top-center placement plus focus are covered by tests. |
| Block decorations | `vs/editor/browser/viewParts/blockDecorations/blockDecorations.zig` | `editor/browser/viewParts/blockDecorations/blockDecorations.ts` | **F** | Ported in `113764e`; block ranges, padding, `blockIsAfterEnd`/`blockDoesNotCollapse`; terminal maps moved classes to one-cell borders. Covered by `block decorations:` tests and `View: block decorations paint a bordered range under the text`. |
| Suggest widget | `vs/editor/contrib/suggest/browser/*` | `editor/contrib/suggest/browser/*` | **T** | Trigger/session model, windowed list, one-cell scrollbar, selection, mouse listeners, plain-text documentation and the `editorSuggestWidget.*`/`scrollbarSlider.*` theme are ported (20 tests); browser details/status chrome and accessibility panes are replaced by the terminal list/docs panes. |
| Hover widget | `vs/editor/contrib/hover/browser/*` | `editor/contrib/hover/browser/*` | **T** | Content-hover controller, scheduling, markdown rendering, the marker participant and the `editorHoverWidget.*`/`focusBorder`/scrollbar theme are ported; browser sticky/pin chrome, status-bar actions and code-action links are terminal omissions. |
| Sticky scroll | `vs/editor/contrib/stickyScroll/browser/*`, `src/tui/stickyScrollHost.zig` | `editor/contrib/stickyScroll/browser/*` | **T** | Candidate rebuild, folding, 25% cap, overlay focus and theme are ported; it paints as a top-left overlay instead of an upstream view zone. |
| Diff editor | `vs/editor/browser/widget/diffEditor/**`, `vs/workbench/browser/parts/editor/textDiffEditor.zig` | `editor/browser/widget/diffEditor/**`, `workbench/.../textDiffEditor.ts` | **T** | Side-by-side aligned rows, filler rows, gutter/overview-ruler features, decorations, navigation and snapshot editors are ported (20 tests). The terminal uses two cell panes with a one-cell center gutter; moved-block detection is wired through `state.moved_texts` into `movedOriginal`/`movedModified` block decorations. Inline diff mode and hide-unchanged regions remain documented terminal/view-layout omissions. |
| Snippet tab stops | decorations in `src/tui/editorView.zig` | `editor/contrib/snippet/browser/*` | **T** | Parser/session, placeholder groups, transforms, `snippet-placeholder`/`finish-snippet-placeholder` themed decorations and TUI Tab/Shift-Tab/Escape placeholder navigation are ported. The browser controller's remaining action/context-key plumbing and full upstream session tests are terminal command-layer omissions. |
| Rulers | `vs/editor/browser/viewParts/rulers/rulers.zig` | `editor/browser/viewParts/rulers/rulers.ts` | **T** | Configured `editor.rulers` columns are mapped to visible cell columns and painted as one-cell vertical guides through the view-line guide layer; the guide is skipped where a text glyph occupies the cell because a cell cannot show both. Per-ruler CSS color overrides are not parsed; `editorRuler.foreground` is used. |
| Scroll decoration | `vs/editor/browser/viewParts/scrollDecoration/scrollDecoration.zig` + `src/tui/editorView.zig` | `editor/browser/viewParts/scrollDecoration/` | **T** | The shadow appears after the first view line scrolls away and tints the first text row with `scrollbar.shadow`; the terminal has no alpha/blur, so it is a solid one-row background instead of a CSS box shadow. Covered by a View test. |
| View zones | absent | `editor/browser/viewParts/viewZones/` | **T** | Confirmed absent. Sticky scroll paints as a top-left overlay and find uses the inline bar; arbitrary-height browser view zones (peek/diff spacers) are not represented as cell rows. The terminal keeps those features as overlays/inline UI; this substitution is documented. |
| Minimap | absent | `editor/browser/viewParts/minimap/` | **T** | Confirmed absent and documented as a terminal limitation (`README.md`: no minimap/pixel lanes); a cell-grid thumbnail is not the upstream minimap and is intentionally omitted. |

## Group 3 — workbench chrome

| View | Local | Upstream | Verdict | Evidence / next action |
|------|-------|----------|---------|------------------------|
| Activity bar | `vs/workbench/browser/parts/activitybar/activitybarPart.zig` | `workbench/browser/parts/activitybar/activitybarPart.ts` | **T** | Glyphs, order/visibility, bottom entries, hit testing and layout are ported (3 tests); an overflowing rail shows an ellipsis that opens a quick pick of hidden activities. The browser context menu is replaced by the terminal quick pick; no browser menu service is available. |
| Composite bar | `vs/workbench/browser/parts/compositeBar.zig` | `workbench/browser/parts/compositeBar.ts` | **T** | Portable model, pinned/unpinned behavior, badges and order are ported (2 tests); the browser composite-bar view/menu/drag is replaced by the activity/panel terminal painters and quick-pick overflow. |
| Side bar | `vs/workbench/browser/parts/sidebar/sidebarPart.zig` | `workbench/browser/parts/sidebar/sidebarPart.ts` | **T** | Size/position, one-cell title, actions, focus and persistence are ported (6 tests); the browser sash/menu/animation surface is replaced by the terminal divider/title row. |
| Panel | `vs/workbench/browser/parts/panel/panelPart.zig` | `workbench/browser/parts/panel/panelPart.ts` | **T** | Composite tabs, `showLabels`, position and active border are ported (2 tests); browser overflow/preferred-size chrome is replaced by cell sizing. |
| View panes/container | `vs/workbench/browser/parts/views/viewPane.zig`, `viewPaneContainer.zig` | `workbench/browser/parts/views/viewPane.ts`, `viewPaneContainer.ts` | **T** | Terminal header/content painters, actions, progress and event wiring exist; header title/action/outdated/hit testing is covered. Browser split/sash/view-cap chrome is replaced by the terminal pane layout. |
| Editor part/group/panes | `vs/workbench/browser/parts/editor/editorPart.zig`, `editorGroupView.zig`, `editorDropTarget.zig` | same | **T** | Group lifecycle, split/grid math, maximize, serialization and drop-target decisions are ported (4+3+3+1 tests); the browser watermark/empty-state artwork is omitted as a terminal-only placeholder. |
| Editor status | `vs/workbench/browser/parts/editor/editorStatus.zig` | `workbench/browser/parts/editor/editorStatus.ts` | **T** | Selection/indent/encoding/EOL/language/problem entries and their pickers are ported; browser accessibility/overtype modes have no terminal equivalent and are omitted. |
| Quick input/access | `vs/platform/quickinput/browser/*`, `vs/workbench/browser/quickaccess.zig`, `vs/workbench/contrib/quickaccess/browser/*` | `platform/quickinput/browser/*`, `workbench/browser/quickaccess.ts`, `workbench/contrib/quickaccess/*` | **T** | List rows, filtering, history, keybinding labels and theme are ported; browser buttons/accessibility and some providers are replaced by terminal pick rows. |
| Dialog | `ui/dialog.zig` + save/quit path in `workbench.zig` | `base/browser/ui/dialog/dialog.ts` | **F** | Terminal dialog structure, focus, save/quit flows, warning/message/detail layout, keyboard/mouse activation and host-resolved `dialog.*`/`button.*` theme colors are ported. Covered by four UI tests plus a custom-theme test. |

## Group 4 — workbench content views

| View | Local | Upstream | Verdict | Evidence / next action |
|------|-------|----------|---------|------------------------|
| Explorer | `vs/workbench/contrib/files/browser/views/explorerView.zig`, `explorerViewer.zig` | `workbench/contrib/files/browser/views/explorerView.ts`, `explorerViewer.ts` | **T** | Tree/filter/selection and themed rows are ported; the browser async-data-tree chrome, drag/drop, sticky rows and context menus are replaced by terminal tree/quick-pick behavior. |
| Search | `vs/workbench/contrib/search/browser/searchView*.zig`, `searchWidget.zig`, `searchResultsView.zig` | `workbench/contrib/search/browser/*` | **T** | Controller/data-source/view split, result tree, widget and replace preview are ported (2 widget tests); browser result actions/details are replaced by terminal quick picks. |
| SCM / Graph | `vs/workbench/contrib/scm/browser/scmViewPane.zig`, `scmHistoryViewPane.zig`, `quickDiffDecorator.zig` | `workbench/contrib/scm/browser/*` | **T** | Documented read-only scope, themed rows, hit testing and quick-diff decorations are ported (2+3 tests); Git write actions and browser graph gestures are intentionally out of scope. |
| Problems | `vs/workbench/contrib/markers/browser/markersView.zig`, `src/tui/problemsView.zig` | `workbench/contrib/markers/browser/markersView.ts` | **T** | Model/view split, filters, tree, themed severity rows and quick-fix entries are ported (1 test); related-information/context-menu UI is replaced by terminal rows/quick picks. |
| Terminal panel | `vs/workbench/contrib/terminal/browser/terminalTabbedView.zig`, `terminalRenderer.zig` | `workbench/contrib/terminal/browser/terminalTabbedView.ts` | **T** | Tab strip/renderer, theme, selection and focus are ported (tab + renderer tests); browser terminal services/accessibility are replaced by the cell terminal adapter. |
| Markdown preview | `vs/workbench/contrib/markdown/browser/*`, `src/tui/markdownPreview.zig` | markdown preview webview | **T** | Scroll sync, themed cell rendering and chrome are ported; the webview HTML/CSS/script and in-preview link/action surface are terminal-rendered. |
| Image preview | `vs/workbench/contrib/mediaPreview/browser/*`, `src/tui/imagePreview.zig` | media preview | **T** | Cell image rendering, status and theme are ported; browser zoom/pan and image context actions are omitted as terminal limitations. |
| Notifications | absent | `workbench/browser/parts/notifications/*` | **T** | Confirmed absent; the terminal routes errors/messages through the status bar and save/quit dialogs instead of a notification center. This is documented as a terminal omission. |

## Work log

- `113764e` port: add block decorations view part. Ported the ViewPart,
  wired it through `TerminalViewHost`, painted blocks under the text, added
  six focused tests and the `test-view` build step.
- `86348cc` docs: add the view audit ledger.
- `54d88ee` find: theme the terminal find bar. Resolved `editorWidget.*`,
  `input.*` and `inputOption.*` through the host palette; added a theme test.
- `210ce82` find: expose the upstream bar controls. Added the visible replace
  toggle, previous, next, close, preserve-case, replace-one and replace-all
  controls; added click tests; updated the README and ledger.
- `5a796b8` gutter: theme the line numbers and quick-diff markers. Added a
  terminal gutter `Theme`, active-line detection, themed quick-diff markers and
  a margin theme test.
- `75d45cc` gutter: honor line-number and folding options. Gutter widths now
  follow `lineNumbers`, `lineNumbersMinChars`, `folding`/`showFoldingControls`
  and the quick-diff marker width. Added an option-matrix test. The glyph-margin
  host/lanes, margin/glyph decorations and all line-decoration classes remain
  pending.
- `2c73bb7` statusbar: theme item kinds and hover states. Added the
  `statusBarItem.*` kind/foreground/hover palette and applied it through the
  model/item; added a theme test. Context-menu actions, compact-group hover and
  tooltip pinning remain pending.
- `17885a5` tabs: guard right-click and theme hover/borders. Right-click no
  longer closes or activates a tab; hover, `tab.border`, `tab.lastPinnedBorder`
  and the active top stroke are themed. Added tab-strip and Workbench
  regression tests. The control-layer variants, tab options, labels/actions,
  context menu and clickable overflow remain pending.
- `fe65946` gutter: paint the glyph-margin host. Added the ported
  `GlyphMarginOverlay`, a dynamic one-cell glyph gutter, known-class glyph
  mapping and the `.gutter_glyph_margin` hit target; added overlay and View
  tests.
- `22999be` gutter: compact glyph-margin lanes. Build the
  `GlyphMarginLanesModel` from `glyphMargin` options, resize the gutter to the
  compacted lane count (1-3), and paint one glyph per active lane. Added a
  multi-lane compaction test. Glyph tooltips, margin decorations and all
  line-decoration classes remain pending.
- `5cbb73a` breadcrumbs: persist inactive controls and fix widget states.
  One control per inactive group, disabled-click gating, focused.selected and
  hover precedence, separator color, and the split-path active-tab fix. Added
  widget and persistent-control tests.
- `f40c6ff` breadcrumbs: add the picker parent and root rule. Added the
  `..` parent entry, the upstream multi-root/single-folder root condition and
  pure model/picker tests. Widget emitters, home labels, outline picker and
  editor-type/drop remain pending.
- `9cd5b9f` statusbar: add compact-group hover and drop the flex gap. The
  referenced half of a compact pair now uses `statusBarItem.compactHoverBackground`,
  and entries are separated by padding alone.
- `95c3c9b` statusbar: wire the context menu actions. Right-click opens the
  Hide/Manage Extension actions through the quick pick; left-click keeps the
  command/focus path. Added a context-menu hide test. Tooltip pin/Escape
  remains pending.
- `dcde701` tabs: open the context menu on right-click. The quick-pick menu
  offers Close, Close Others, Close All and Pin/Unpin; added a menu-close test.
- `dbabf31` tabs: show duplicate-label directory descriptions. Duplicate names
  append a dimmed parent directory; `workbench.editor.labelFormat` selects the
  short/medium/long form. Added a duplicate-label test. Tab actions/overflow
  and the control-layer variants remain pending.
- `f04dff1` gutter: paint the current-line margin highlight. Registered the
  margin current-line overlay and painted the gutter row for
  `renderLineHighlight: gutter|all`; added a View regression test. Focus-only
  tracking, glyph tooltips, margin decorations and line-decoration classes
  remain pending.
- `2243776` breadcrumbs: emit widget item/focus events. Added the upstream
  `onDidSelectItem`/`onDidFocusItem`/`onDidChangeFocus` emitters and fired them
  from selection, focus-next/previous and focus changes. Home labels,
  editor-type/drop and the outline picker remain pending.
- `a471dda` gutter: paint marginClassName decorations. Registered the
  `MarginViewLineDecorationsOverlay` and mapped the known diff/edit classes to
  gutter row tints, with a View test.
- `7e064be` gutter: map remaining line-decoration classes. `insert-sign`,
  `delete-sign`, `comment-range-glyph` and `first-line` paint the marker cell
  after quick-diff, with a regression test.
- `96bfa0a` gutter: reserve the marker cell automatically. `prepareFrame`
  reserves/releases the marker cell for mapped `linesDecorationsClassName`
  decorations; quick-diff configuration still owns its width. Extended the
  marker-cell test.
- `892f580` editor: forward focus to the view overlays. `View.setFocused` is the
  terminal focus boundary and the active tab is synchronized before each
  workbench frame; focus-only line highlighting now works in content and
  gutter. Added a regression test. Glyph tooltips remain pending.
- `802e6c1` breadcrumbs: add home-relative roots. Files under `$HOME` outside
  the workspace get a `~` root; the workbench caches HOME through
  `Environ.Map`. Added a model test. Editor-type/drop and the outline picker
  remain pending.
- Audited the core editor views: view orchestrator (**F**), view lines (**T**),
  current-line highlight (**F**), selections (**T**), view cursors (**T**),
  scrollbar (**T**) and overview ruler (**T**), with the evidence recorded in
  their ledger rows.
- Audited the next editor-view batch: indent guides (**T**), decoration
  overlays (**T**), content widgets (**P**), overlay widgets (**P**); decided
  the missing views: rulers/scroll decoration/view zones (**M**, next action)
  and minimap (**T**, documented terminal omission).
- `statusbar` escape now clears the hover tooltip; added a regression test.
  Tooltip pinning remains a browser hover behavior.
- Implemented the missing rulers view: mapped `editor.rulers` to one-cell
  vertical guides, skipping text-occupied cells; added a View test.
- Implemented the scroll decoration: a one-row `scrollbar.shadow` tint after
  scrolling, with a View test.
- Audited the remaining editor contributions: suggest (**P**), hover (**P**),
  sticky scroll (**T**), diff (**P**), snippet (**P**) and view zones (**T**,
  overlay/inline substitution). No `M` rows remain in the editor-view section.
- Audited the workbench and content rows: parts/editor/quick-input/dialog and
  explorer/search/SCM/Problems/terminal/preview are **P** with their remaining
  gaps recorded; the absent notification center is **T** (status/dialog
  substitution). No `M` rows remain in the ledger.
- Added a content-widget placement test (below/above anchor, clamping and
  width/height), tightening the **P** evidence for that row.
- Added overlay-widget corner/focus tests; that row is now **F**.
- Implemented glyph-margin hover messages as a one-line content-widget tooltip,
  with a View test.
- Made the clipped-tab ellipsis clickable: it lists the hidden tabs in a quick
  pick and activates the chosen tab, with a narrow-strip test.
- Added multi-widget/focus coverage for content widgets; that row is now **F**.
- Honored `workbench.editor.tabCloseButton` off/left/right for the tab close
  cell, with helper and left-cell tests.
- Added a view-pane header test for title/action/outdated painting and hit
  testing, tightening the **P** evidence.
- Promoted the named-view verdicts after the recent fixes: gutter **F**,
  status bar **T** (tooltip pin/aux context menu are browser-only) and
  breadcrumbs **T** (editor-type/drop/outline sibling picker are browser-only).
- Added `workbench.editor.tabSizing` fit/shrink/fixed support with a tab-width
  test.
- Added the Close to the Right tab action with a context-menu test.
- Added Split Right/Down tab actions that activate the captured tab before
  splitting, with a context-menu test.
- Added the Close Saved tab action with a context-menu test, including keeping
  dirty tabs open.
- Added an activity-bar overflow ellipsis and quick pick for hidden entries,
  with a render/hit test.
- Threaded the workbench theme into the terminal dialog (`dialog.*` and
  `button.*` colors), added a custom-theme UI test, and promoted the dialog row
  to **F**.
- Added `workbench.editor.showTabs` none/single support with a dynamic title
  row, plus a test that the reclaimed row shows editor content.
- Wired Tab/Shift-Tab/Escape snippet placeholder navigation from the TUI into
  `SuggestController`, with a helper test.
- Added find/replace input history (Up/Down recall, deduped, capped) with
  find-controller tests.
- Added `editor.find.findOnType`, `closeOnResult`, `loop`,
  `seedSearchStringFromSelection`, `autoFindInSelection` and
  history-enablement settings with find-controller tests; the browser
  sash/accessibility remain documented omissions.
- Released the find top inset when the editor scrolls past line 1, with a
  workbench scroll test.
- Added a draggable find-bar sash (width clamped to the terminal), with a
  mouse-drag test.
- Ported moved-block detection into the diff editor's block decorations
  (`movedOriginal`/`movedModified`), with a decorated-model test. The terminal find widget now covers the upstream control
  set, options, history, view zone and sash; browser accessibility/global
  clipboard remain documented terminal omissions.
- Ported the find widget view zone as a terminal top inset: `find.viewZoneRows`,
  `editor.find.addExtraSpaceOnTop`, dynamic editor/tab relayout, shifted
  content/gutter/scrollbar/content widgets, cursor and mouse mapping, plus
  find/View/workbench tests.
- Promoted the tab bar to **T** once the single-strip adaptations (showTabs,
  sizing, close placement, labels, context actions, overflow) were complete;
  the browser tab action toolbar and separate pinned row are documented
  omissions.
- Classified the remaining workbench chrome as **T** where the gap is browser
  chrome/menu/accessibility (activity bar, composite bar, side bar, panel, view
  panes, editor part, editor status, quick input).
- Classified the content views and suggest/hover as **T** where the remaining
  gaps are browser chrome/accessibility. Snippet tab stops are **T** after the
  TUI placeholder navigation. The diff editor is **T**: the terminal side-by-side
  cell panes replace inline mode/hide-unchanged/moved-block layout, with the
  omissions documented. All ledger rows now have a terminal-aware verdict.
- Resolved the suggest widget's `editorSuggestWidget.*`/`scrollbarSlider.*`
  theme through `SuggestController.setTheme` in the editor pane.
- Resolved the content-hover widget's `editorHoverWidget.*`, `focusBorder` and
  scrollbar colors through `ContentHoverController.setTheme`.

## Next slice

The audit is complete: every listed view has an **F** or **T** verdict with
evidence, and no `Pending audit`, **P** or **M** rows remain. The terminal
adaptations' remaining optional enhancements are recorded in the **T** rows,
for example diff inline/hide-unchanged layout, the separate pinned-tab row and
the browser menu/accessibility surfaces. Further work should start from those
documented omissions rather than reopen a view's verdict.
