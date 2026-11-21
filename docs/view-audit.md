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
| Find & replace overlay | `vs/editor/contrib/find/browser/findWidget.zig`, `findController.zig`, `findModel.zig`, `findDecorations.zig` | `editor/contrib/find/browser/findWidget.ts`, `findController.ts`, `findModel.ts`, `findDecorations.ts` | **T** | Controller/model/state/decorations are ported and tested (`findController.test.zig`). The terminal bar now has the upstream control set (replace toggle, previous, next, close, match count, Aa/ab/.*/Sel, preserve-case, replace-one, replace-all), hit tests and a host-resolved `Theme` bundle (`editorWidget.*`, `input.*`, `inputOption.*`). Documented terminal omissions: no focusable buttons, browser sash, find view zone, input history or accessibility tree. New control/theme tests in `findController.test.zig`. |
| Gutter / margin | `vs/editor/browser/viewParts/margin/margin.zig`, `lineNumbers/`, `glyphMargin/`, `linesDecorations/`, `marginDecorations/`, folding decorations | `editor/browser/viewParts/margin/`, `lineNumbers/`, `glyphMargin/`, `linesDecorations/`, `marginDecorations/`, `editor/contrib/folding/browser/` | **P** | Line-number and quick-diff data are ported and painted; the terminal `Theme` bundle resolves `editorLineNumber.foreground/activeForeground`, `editorGutter.foldingControlForeground`, `editorGutter.{added,modified,deleted}Background`, and the active line number is detected. Gutter widths follow `lineNumbers`, `lineNumbersMinChars`, `folding`/`showFoldingControls` and `lineDecorationsWidth`. The glyph-margin host paints themed glyphs in up to three compacted lanes, maps the known glyph classes to `●`/`▲`, reports `.gutter_glyph_margin` hit targets, and reserves lanes only while a glyph decoration exists. Both current-line overlays are ported: `renderLineHighlight: gutter|all` paints the gutter row background, with a regression test. `marginClassName` decorations are wired through `MarginViewLineDecorationsOverlay`; the known diff/edit classes tint the gutter row. Still pending: glyph hover tooltips, `renderLineHighlightOnlyWhenFocus` focus tracking, and all line-decoration classes. |
| Status bar | `vs/workbench/browser/parts/statusbar/statusbarPart.zig`, `statusbarModel.zig`, `statusbarItem.zig`, `statusbarActions.zig` | `workbench/browser/parts/statusbar/statusbarPart.ts`, `statusbarModel.ts`, `statusbarItem.ts`, `statusbarActions.ts` | **P** | Model/part/item split, ordering, compact flags, focus and hit testing are ported. Item kinds now resolve `statusBarItem.{prominent,warning,error,remote,offline}{Background,Foreground,HoverBackground,HoverForeground}` and `statusBarItem.hoverBackground` through a terminal `Theme`. Compact-group hover lights the referenced entry through `statusBarItem.compactHoverBackground`, the extra flex gap was removed, and a right-click opens the `statusbarActions.zig` Hide/Manage Extension actions through the quick pick. Still pending: hover tooltip pin/Escape and the browser's non-action context-menu parts. |
| Tab bar / title control | `vs/workbench/browser/parts/editor/multiEditorTabsControl.zig`, `editorGroupView.zig`, tab sections of `workbench/browser/workbench.zig` | `workbench/browser/parts/editor/editorTabsControl.ts`, `singleEditorTabsControl.ts`, `multiEditorTabsControl.ts`, `editorTitleControl.ts` | **P** | Right-click opens a terminal context menu (Close, Close Others, Close All, Pin/Unpin) instead of closing or activating a tab; hover foreground/background, `tab.border`, `tab.lastPinnedBorder` and the cell-border active top stroke are themed and tested. Duplicate labels now append a dimmed directory description and `workbench.editor.labelFormat` (default/short/medium/long) is read. Still pending: the `editorTabsControl` base/single/no-tab variants, duplicate-label decorations, other `workbench.editor.*` tab configs, tab actions/toolbar, clickable overflow and sticky rows. |
| Breadcrumbs | `vs/workbench/browser/parts/editor/breadcrumbsControl.zig`, `breadcrumbsModel.zig`, `breadcrumbsPicker.zig`, `breadcrumbs.zig`, `vs/base/browser/ui/breadcrumbs/breadcrumbsWidget.zig` | `workbench/browser/parts/editor/breadcrumbsControl.ts`, `breadcrumbsModel.ts`, `breadcrumbsPicker.ts`, `breadcrumbs.ts`, `base/browser/ui/breadcrumbs/breadcrumbsWidget.ts` | **P** | Inactive groups now keep one persistent breadcrumb control (no per-frame outline rebuild); widget hits respect `enabled`, hover only applies when not focused/selected, `focused.selected` uses `breadcrumb.activeSelectionForeground`, and separators inherit `breadcrumb.foreground`. Also fixed the split path leaving a group without an active tab, the workspace-root inclusion rule, and the picker's leading `..` parent entry. The widget now exposes `onDidSelectItem`/`onDidFocusItem`/`onDidChangeFocus` and the control fires them. Still pending: home-relative labels, editor-type/drop, the outline pick list, and the remaining style/config gaps. |

## Group 2 — remaining editor views and widgets

| View | Local | Upstream | Verdict | Evidence / next action |
|------|-------|----------|---------|------------------------|
| View orchestrator | `vs/editor/browser/view.zig`, `view/viewPart.zig`, `viewLayer.zig`, `viewOverlays.zig`, `renderingContext.zig` | `editor/browser/view.ts`, `view/*.ts` | Pending audit | Check ViewPart lifecycle and event fan-out; no collapsed terminal-only path. |
| View lines / whitespace / word wrap | `vs/editor/browser/viewParts/viewLines/` | `editor/browser/viewParts/viewLines/` | Pending audit | Check render pipeline, wrapping, whitespace/control chars, invalidation. |
| Current line highlight | `vs/editor/browser/viewParts/currentLineHighlight/` | same | Pending audit | Options, theme, paint order. |
| Indent guides | `vs/editor/browser/viewParts/indentGuides/` | same | Pending audit | Model rules, theme pools, active scope. |
| Selections | `vs/editor/browser/viewParts/selections/` | same | Pending audit | Multi-selection, rounded-corner substitution, theme. |
| View cursors | `vs/editor/browser/viewParts/viewCursors/` | same | Pending audit | Plurality, focus/composition, hardware cursor boundary, theme. |
| Decoration overlays | `vs/editor/browser/viewParts/decorations/` + `src/tui/editorView.zig` | `editor/browser/viewParts/decorations/decorations.ts` | Pending audit | Find/word/bracket/diagnostic classes, theme, z-order. |
| Scrollbar | `vs/editor/browser/viewParts/editorScrollbar/editorScrollbar.zig` | `editor/browser/viewParts/editorScrollbar/editorScrollbar.ts` | Pending audit | 3-lane geometry accepted; check sensitivity, wheel, drag, theme, hit. |
| Overview ruler | `vs/editor/browser/viewParts/overviewRuler/decorationsOverviewRuler.zig` | `editor/browser/viewParts/overviewRuler/decorationsOverviewRuler.ts` | Pending audit | Lane mapping/colors, cursor markers, z-order, theme. |
| Content widgets | `vs/editor/browser/viewParts/contentWidgets/` | same | Pending audit | Anchoring, above/below, clamping, hit/focus. |
| Overlay widgets | `vs/editor/browser/viewParts/overlayWidgets/` | same | Pending audit | Corner preferences, size, paint order, focus. |
| Block decorations | `vs/editor/browser/viewParts/blockDecorations/blockDecorations.zig` | `editor/browser/viewParts/blockDecorations/blockDecorations.ts` | **F** | Ported in `113764e`; block ranges, padding, `blockIsAfterEnd`/`blockDoesNotCollapse`; terminal maps moved classes to one-cell borders. Covered by `block decorations:` tests and `View: block decorations paint a bordered range under the text`. |
| Suggest widget | `vs/editor/contrib/suggest/browser/*` | `editor/contrib/suggest/browser/*` | Pending audit | Widget/list/status/details, icons, theme, keyboard/mouse, scroll. |
| Hover widget | `vs/editor/contrib/hover/browser/*` | `editor/contrib/hover/browser/*` | Pending audit | Content widget, status bar actions, scroll, sticky, theme. |
| Sticky scroll | `vs/editor/contrib/stickyScroll/browser/*`, `src/tui/stickyScrollHost.zig` | `editor/contrib/stickyScroll/browser/*` | Pending audit | Overlay-vs-view-zone decision, options, folding, theme, focus. |
| Diff editor | `vs/editor/browser/widget/diffEditor/**`, `vs/workbench/browser/parts/editor/textDiffEditor.zig` | `editor/browser/widget/diffEditor/**`, `workbench/.../textDiffEditor.ts` | Pending audit | Aligned rows, center gutter, overview ruler, theme, hit, documented omissions. |
| Snippet tab stops | decorations in `src/tui/editorView.zig` | `editor/contrib/snippet/browser/*` | Pending audit | Decoration classes, selection behavior, theme. |
| Rulers | absent | `editor/browser/viewParts/rulers/rulers.ts` | M — decision pending | Confirm absence, decide terminal feasibility and scope. |
| Scroll decoration | absent | `editor/browser/viewParts/scrollDecoration/` | M — decision pending | Confirm absence, decide terminal feasibility and scope. |
| View zones | absent | `editor/browser/viewParts/viewZones/` | M — decision pending | Decide implement-or-document; sticky currently paints as an overlay. |
| Minimap | absent | `editor/browser/viewParts/minimap/` | M — decision pending | Confirm absence; document the terminal limitation or decide a text minimap. |

## Group 3 — workbench chrome

| View | Local | Upstream | Verdict | Evidence / next action |
|------|-------|----------|---------|------------------------|
| Activity bar | `vs/workbench/browser/parts/activitybar/activitybarPart.zig` | `workbench/browser/parts/activitybar/activitybarPart.ts` | Pending audit | Glyphs/icons, order/visibility, bottom entries, overflow, hit, context menu. |
| Composite bar | `vs/workbench/browser/parts/compositeBar.zig` | `workbench/browser/parts/compositeBar.ts` | Pending audit | Model/view split, pinned/unpinned, overflow, badges, menu. |
| Side bar | `vs/workbench/browser/parts/sidebar/sidebarPart.zig` | `workbench/browser/parts/sidebar/sidebarPart.ts` | Pending audit | Size/position, title, actions/overflow, persistence, focus. |
| Panel | `vs/workbench/browser/parts/panel/panelPart.zig` | `workbench/browser/parts/panel/panelPart.ts` | Pending audit | Composite tabs, `showLabels`, position, active border, overflow, preferred size. |
| View panes/container | `vs/workbench/browser/parts/views/viewPane.zig`, `viewPaneContainer.zig` | `workbench/browser/parts/views/viewPane.ts`, `viewPaneContainer.ts` | Pending audit | Real ViewPane vs header painter, split/sash, actions, progress, events, view cap. |
| Editor part/group/panes | `vs/workbench/browser/parts/editor/editorPart.zig`, `editorGroupView.zig`, `editorPanes.zig`, `editorDropTarget.zig` | same | Pending audit | Group lifecycle/events, watermark, maximize, serialization, split math, drop target. |
| Editor status | `vs/workbench/browser/parts/editor/editorStatus.zig` | `workbench/browser/parts/editor/editorStatus.ts` | Pending audit | All entries (selection/indent/encoding/EOL/language/info/accessibility/overtype/column/problem), pickers. |
| Quick input/access | `vs/platform/quickinput/browser/*`, `vs/workbench/browser/quickaccess.zig`, `vs/workbench/contrib/quickaccess/browser/*` | `platform/quickinput/browser/*`, `workbench/browser/quickaccess.ts`, `workbench/contrib/quickaccess/*` | Pending audit | List rows, icons, buttons, keybinding labels, history, theme. |
| Dialog | `ui/dialog.zig` + save/quit path in `workbench.zig` | `base/browser/ui/dialog/dialog.ts` | Pending audit | Structure vs terminal widget, theme, focus, button order, detail/message. |

## Group 4 — workbench content views

| View | Local | Upstream | Verdict | Evidence / next action |
|------|-------|----------|---------|------------------------|
| Explorer | `vs/workbench/contrib/files/browser/views/explorerView.zig`, `explorerViewer.zig` | `workbench/contrib/files/browser/views/explorerView.ts`, `explorerViewer.ts` | Pending audit | Tree/renderer/filter, async data tree, DnD, sticky, theme, selection. |
| Search | `vs/workbench/contrib/search/browser/searchView*.zig`, `searchWidget.zig`, `searchResultsView.zig` | `workbench/contrib/search/browser/*` | Pending audit | Controller/data source/view split, results tree, widget, theme. |
| SCM / Graph | `vs/workbench/contrib/scm/browser/scmViewPane.zig`, `scmHistoryViewPane.zig`, `quickDiffDecorator.zig` | `workbench/contrib/scm/browser/*` | Pending audit | Documented read-only scope, rendering, theme, hit. |
| Problems | `vs/workbench/contrib/markers/browser/markersView.zig`, `src/tui/problemsView.zig` | `workbench/contrib/markers/browser/markersView.ts` | Pending audit | Model/view split, filter/tree/context/quick-fix/related, theme. |
| Terminal panel | `vs/workbench/contrib/terminal/browser/terminalTabbedView.zig`, `terminalRenderer.zig` | `workbench/contrib/terminal/browser/terminalTabbedView.ts` | Pending audit | Tab strip/renderer, theme, selection, focus. |
| Markdown preview | `vs/workbench/contrib/markdown/browser/*`, `src/tui/markdownPreview.zig` | markdown preview webview | Pending audit | Scroll sync, theme, chrome. |
| Image preview | `vs/workbench/contrib/mediaPreview/browser/*`, `src/tui/imagePreview.zig` | media preview | Pending audit | Theme, status, zoom, hit. |
| Notifications | absent | `workbench/browser/parts/notifications/*` | M — decision pending | Confirm absence; backlog decision. |

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
  gutter row tints, with a View test. Glyph tooltips, focus-only tracking and
  all line-decoration classes remain pending.

## Next slice

Group 1, in this order:

1. Find & replace overlay.
2. Gutter / margin / line numbers / glyph margin / decorations / folding.
3. Status bar.
4. Tab bar / title control.
5. Breadcrumbs.

Each row is audited before code changes, then fixed in a small commit with
tests and the corresponding ledger update.
