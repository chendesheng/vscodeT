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
| Find & replace overlay | `vs/editor/contrib/find/browser/findWidget.zig`, `findController.zig`, `findModel.zig`, `findDecorations.zig` | `editor/contrib/find/browser/findWidget.ts`, `findController.ts`, `findModel.ts`, `findDecorations.ts` | **P** | Controller/model/state/decorations are ported and tested (`findController.test.zig`). The widget is a terminal bar: hardcoded colors (`findWidget.zig:28-31`); no visible replace toggle, previous, next, close, replace-current, or preserve-case controls (only Aa/ab/.*/Sel and All); no sash/view-zone/history/accessibility parts. Theme bundle added (`editorWidget.*`/`input.*`/`inputOption.*` via the workbench palette); next: visible replace toggle, previous/next/close, replace-current, preserve-case, control hit tests, widget tests. |
| Gutter / margin | `vs/editor/browser/viewParts/margin/margin.zig`, `lineNumbers/`, `glyphMargin/`, `linesDecorations/`, `marginDecorations/`, folding decorations | `editor/browser/viewParts/margin/`, `lineNumbers/`, `glyphMargin/`, `linesDecorations/`, `marginDecorations/`, `editor/contrib/folding/browser/` | Pending audit | Check gutter geometry/options, line-number modes, glyph-margin host/lanes, margin/line decorations, folding, theme, hit testing. |
| Status bar | `vs/workbench/browser/parts/statusbar/statusbarPart.zig`, `statusbarModel.zig`, `statusbarItem.zig`, `statusbarActions.zig` | `workbench/browser/parts/statusbar/statusbarPart.ts`, `statusbarModel.ts`, `statusbarItem.ts`, `statusbarActions.ts` | Pending audit | Check model/part/item split, actions menu wiring, kind/hover theme, compact mode, focus/hit/tooltip, tests. |
| Tab bar / title control | `vs/workbench/browser/parts/editor/multiEditorTabsControl.zig`, `editorGroupView.zig`, tab sections of `workbench/browser/workbench.zig` | `workbench/browser/parts/editor/editorTabsControl.ts`, `singleEditorTabsControl.ts`, `multiEditorTabsControl.ts`, `editorTitleControl.ts` | Pending audit | Check control layer/variants, tab configs, labels/descriptions/decorations, hover/borders, actions/toolbar, context menu, overflow, sticky/pinned, right-click. |
| Breadcrumbs | `vs/workbench/browser/parts/editor/breadcrumbsControl.zig`, `breadcrumbsModel.zig`, `breadcrumbsPicker.zig`, `breadcrumbs.zig`, `vs/base/browser/ui/breadcrumbs/breadcrumbsWidget.zig` | `workbench/browser/parts/editor/breadcrumbsControl.ts`, `breadcrumbsModel.ts`, `breadcrumbsPicker.ts`, `breadcrumbs.ts`, `base/browser/ui/breadcrumbs/breadcrumbsWidget.ts` | Pending audit | Check widget event flow, focus/hover/selection, scroll/reveal, model path/home/root, picker, editor-type/drag, per-frame control cost. |

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

## Next slice

Group 1, in this order:

1. Find & replace overlay.
2. Gutter / margin / line numbers / glyph margin / decorations / folding.
3. Status bar.
4. Tab bar / title control.
5. Breadcrumbs.

Each row is audited before code changes, then fixed in a small commit with
tests and the corresponding ledger update.
