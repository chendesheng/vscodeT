# Diff view audit: terminal port vs VS Code 1.147.0

**Status:** partial remediation in progress. The historical findings below describe the re-audited baseline; see the implementation ledger for changes and remaining gaps.
Re-audited after the 2026-11-26 source refactor.
**Date:** 2026-11-25, re-audited 2026-11-26
**Initial audit commit:** `cdde4cf8`
**Re-audited local commit:** `90d001e9`
**Upstream:** VS Code 1.147.0, `vscode/` pinned at
`e31c2e52f563620846caab877103f630ea361b9c`
**Local scope:** `src/vs/editor/browser/widget/diffEditor/**`,
`src/vs/workbench/browser/parts/editor/textDiffEditor.zig`,
`src/vs/workbench/browser/parts/editor/diffEditorCommands*.zig`,
`src/vs/workbench/services/editor/browser/editorService.zig`,
`src/extensions/git/src/{commands,git}.zig`,
`src/vs/workbench/common/editor/diffEditorInput.zig`, and the `src/tui/`
workbench/view glue that opens, paints and routes input.

**Method:** read both implementations and their tests; trace the widget,
workbench, Git extension and TUI call paths; compare the upstream feature
objects, options, commands and view state against the local composition. No
profiler run was performed, so §4 separates confirmed code-level cost from a
measurement plan.

The reported symptoms are "the diff view seems slow" and "there are missing UI
elements of the diff view". This audit confirms both. It also records several
correctness gaps that are visible as missing or misplaced UI and that should be
fixed together with the presentation work.

---

## Implementation ledger (2026-11-26)

The following changes are implemented in separate commits. This is not full
upstream parity, and the historical findings below remain useful as a baseline.
The second implementation pass established shared view-zone geometry, but
retaining real snapshot models and mounting the diff-specific zone content
remain necessary to remove the pre-aligned text representation.

| Plan item | Current implementation |
|---|---|
| 1 — worker and snapshot reads | Initial SCM and history diff opens/refreshes resolve owned Git virtual snapshot sources and compute diffs on the native editor worker. A one-second progress deadline, detached stale replies, and a 10-entry content/computation-options cache are implemented. Direct test construction and live diff-option recomputation are still synchronous; cancellation detaches the reply rather than interrupting a running algorithm. |
| 2 — double rendering | Diff tab refresh invalidates both views; rendering is deferred to the frame. |
| 3–4 — gutter and moved coordinates | Binary search on sorted aligned hunk ranges; pure deletion and post-filler paint regressions; moved ranges are converted to display rows. The 1k/10k benchmark measures 40,000 lookups across 1,000 viewport offsets (about 3–4 ms in the local Debug run; this is not end-to-end rendering). |
| 5 — hidden coordinates | Convert view rows to model rows for line numbers/gutter, use model positions for navigation. The upstream region range model now feeds the generic folding substitution; disclosure UI and independent view-zone state remain open. |
| 6 — narrow fallback | Automatic interleaved inline layout across width transitions; respects the inline fallback setting and projects the configurable breakpoint to cells. True inline view zones are still absent; the shared layout and renderer now support blank whitespace regions. |
| 7 — key routing | Shared editor key dispatch and scroll synchronization restored. Independent contribution controllers attach to both views; focus and mouse/key routing use the active inner editor. Contributions still operate on projected snapshot text. |
| 8 — indicators | Margin classes and indicator glyphs are ported. Contiguous filler blocks share one decoration; the real view-zone representation and empty-range markers remain open. |
| 9 — theme/settings | Both panes receive theme updates; line and filler colors resolve theme IDs. Editor and diff settings are reapplied on configuration events; diff-specific option changes still regenerate snapshots synchronously. |
| 10 — gutter/sash | Current hunk follows the cursor; split ratio validation and disabled-sash behavior corrected. Gutter theme colors are resolved; the sash has its own drag/reset lifecycle. Toolbar remains open. |
| 11–13 — features | Combined two-lane overview ruler and viewport slider are wired. The upstream `UnchangedRegion` range/reveal model is ported and used by the folding projection; disclosure widgets, moved connectors and hover/compare remain open. |
| 14 — commands and swap | Swap reverses mappings, decorations, snapshot identity and title, including inline layout. Upstream command IDs for focus side, toggle inline, explicit view modes, and ignore whitespace are registered. Other commands and editor-title actions remain open. |
| 15–17 — larger parity | `ViewLayout` whitespace transactions update scroll dimensions and notify listeners before render. View lines, margin, cursor, widgets, scrollbar and mouse targets use zone-aware vertical offsets. The delegate/node owner, real inline/alignment diff zones, accessible viewer and remaining contributions over real models are open. |
| 18 — state | Refresh preserves split, cursor and scroll and reapplies theme; explicit diff word wrap is applied to both sides with the hidden original forced off. Session serialization, code lens and unequal wrapped-row alignment remain open. |
| 19 — tests | New focused regressions cover input/scroll, narrow transitions, gutter paint, filler grouping, hidden coordinates, theme and swap/refresh. The worker/cancellation/cache tests and SCM integration are in `test-view`. New coverage includes ruler cells/slider, sash reset, independent find, all four upstream unchanged-region range scenarios, whitespace event ordering, and zone-row paint, hit testing and scrolling. Complete upstream widget scenarios and end-to-end performance measurements remain open. |

Local verification after this pass: `zig build`, `zig build check-workbench`,
`zig build test-view --summary all` (390/390) and
`zig build test --summary all` (3,430 passed, 20 skipped; 48/48 build steps)
succeeded. The full suite was run outside the filesystem sandbox because the
native watcher tests cannot receive events within it. Formatting and Git
whitespace checks passed. No end-to-end large-file terminal latency or
cross-platform CI result is claimed.

## 0. Re-audit update (2026-11-26)

The source tree changed substantially after the first audit, mainly through the
portable-workbench split (`src/tui/workbenchWindow.zig`,
`src/vs/workbench/services/editor/browser/editorService.zig`,
`src/extensions/git/src/commands.zig`) and the generic editor-view injection
(`DiffEditorWidget(View)` / `DiffView(View)`). This revision re-checked every
finding at commit `90d001e9` and updated the evidence paths.

What changed:

* The diff widget no longer imports `src/tui/editorView.zig`. It is a generic
  `DiffEditorWidget(comptime View: type)`, and `textDiffEditor.zig` is generic
  over the injected `View`; the composition root supplies the real terminal
  view (`src/vs/workbench/browser/parts/editor/editorPane.zig:24`,
  `src/vs/workbench/services/editor/browser/editorService.zig:109-170`). This
  is an ownership/import-boundary refactor, not a behavior change to the
  alignment, gutter, decorations or navigation logic.
* Diff configuration moved from `Workbench` to
  `textDiffEditor.computeConfiguration`
  (`src/vs/workbench/browser/parts/editor/textDiffEditor.zig:27-80`). It is
  still the same reduced option projection, read when the diff is opened or
  refreshed.
* Diff opening/snapshot resolution moved to
  `EditorService.openSnapshotDiff` plus the Git extension
  (`src/vs/workbench/services/editor/browser/editorService.zig:109-170`,
  `src/extensions/git/src/commands.zig:458-485`,
  `src/extensions/git/src/git.zig:534-562`). The reads remain synchronous on
  the UI-thread path.
* Normal editor keys now flow through the `CodeEditorWidget` input boundary
  (`IEditorKeyTarget` / `codeEditorWidgetTerminalInput.zig`). The diff path was
  not changed: it still calls `View.dispatchKey` directly and never invokes the
  editor dispatcher, so the keyboard finding remains.
* New upstream-path test files now exist
  (`src/vs/editor/test/browser/widget/diffEditorWidget.test.zig`,
  `src/vs/workbench/test/browser/parts/editor/textDiffEditor.test.zig`), but
  they contain the same terminal helper/pane cases as before. The upstream
  compact-disclosure, width-layout and `UnchangedRegion` tests are still not
  ported.
* `src/tui/editorView.zig` now resolves character backgrounds and moved-block
  borders through the theme (`diffEditor.insertedTextBackground`,
  `diffEditor.removedTextBackground`, `diffEditor.move*.border`). Diff views
  still never receive the palette because both theme paths skip diff tabs, and
  whole-line/filler backgrounds remain hard-coded.
* No functional change was found in the gutter coordinate bug, the narrow
  modified-only fallback, the hide-unchanged folding model, the synchronous
  diff computation, the per-input double refresh, the filler-line explosion,
  swap state, or command coverage. All findings below still apply.

Verification note: the audit is documentation-only. At `90d001e9`,
`zig build check-workbench` passes, and
`zig build test-view --summary all` passes with 368/368 tests once Zig's global
cache is redirected into the writable workspace
(`ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache/global`); the default `/root/.cache/zig`
write is denied by the sandbox. The findings below come from code-path reading
plus the existing test sources.

---

## 1. Executive summary

The current diff view is a working **read-only, two-snapshot comparison**, but
it is not yet a port of the upstream diff editor's view layer. The line-diff
model and a subset of model decorations are shared with upstream; the rest is a
terminal-only composition:

* two read-only `Editor`/`View` instances built from **pre-aligned display
  texts**;
* whole-line/character/filler decorations applied directly to the two snapshot
  models;
* a one-cell hand-painted center gutter;
* mouse-only split resizing;
* no view zones, no widget/view-part orchestration, no diff-specific overlays.

Upstream instead composes two full `CodeEditorWidget`s with a diff view model,
view zones, a gutter with an action toolbar, a sash, a combined overview ruler,
moved-block line connectors, hide-unchanged-region widgets, an accessible diff
viewer, revert buttons, and the normal editor contributions (find, hover,
context menu, etc.). Most of those have no local equivalent.

Highest-impact findings:

1. **Diff pane keyboard input is effectively disconnected from the editor.**
   The diff key path ends at `View.dispatchKey`, which only dispatches to a
   focused DOM widget and never invokes the editor command dispatcher. Normal
   tabs call `codeEditorWidgetTerminalInput.handleKeyEvent` (which does invoke it);
   diff tabs do not. Arrow/Page/Home/End/selection/fold/copy/find keys are
   therefore no-ops unless a widget owns DOM focus. See §3.2.
2. **Narrow widths lose deletions.** When the pane is narrower than the
   hard-coded 50-cell threshold, the widget paints the modified pane only and
   does not switch to inline mode. Deleted content exists only in the original
   aligned text, so it disappears from the UI. Upstream switches to the inline
   view using `useInlineViewWhenSpaceIsLimited` and the configurable breakpoint.
   See §3.3.
3. **Opening/refreshing a diff blocks the TUI thread.** Diff computation is
   synchronous inside `DiffEditorWidget.create`, with a default 5 s budget and
   an unbounded budget when `diffEditor.maxComputationTime` is `0`. Upstream
   computes in a worker, caches results, and shows progress. See §4.2.
4. **The aligned-display representation explodes for whole-file changes.** A
   new/untracked file is represented as N filler lines in the original snapshot
   plus one `diff-filler` model decoration per filler line. Upstream uses one
   view zone per changed block with a pixel height. This is both memory and
   open-time cost. See §4.3.
5. **Display-row and real-line coordinates are mixed.** The gutter and moved
   block decorations use real model line numbers while the editor view is
   indexed by aligned display rows. Pure deletions get no gutter marker at all,
   and markers after earlier fillers are shifted. Hide-unchanged folding
   additionally invalidates the line-number map and navigation because folding
   changes view-line numbering without any conversion. See §5.
6. **The diff view never receives the active theme or live editor settings.**
   `TextEditorConfiguration.applyToTab` and `TerminalWorkbench.applyThemeToParts`
   skip diff tabs; whole-line/filler/gutter colors stay hard-coded dark-theme
   constants and the newer themed character/moved-border mappings never receive
   a palette. Diff options are only read when the widget is created. See §3.10.

A short version of the verdict: the diff **model/decoration subset is partial**;
the diff **view layer is an ad-hoc terminal painter**, and several visible
features are missing rather than merely simplified for a cell grid.

---

## 2. Pipeline comparison

### 2.1 Upstream composition

```text
original text model ─┐
                     ├─ DiffEditorViewModel (worker/cache, observable)
modified text model ─┘
        │
        ├─ DiffEditorDecorations  (line/char/empty/moved model decorations)
        ├─ DiffEditorViewZones    (alignment view zones; inline deleted-code zones)
        ├─ HideUnchangedRegionsFeature (collapsed-region widgets/view zones)
        ├─ OverviewRulerFeature   (combined two-lane ruler + viewport slider)
        ├─ DiffEditorGutter       (per-hunk toolbar, current hunk from cursor)
        ├─ MovedBlocksLinesFeature(SVG connectors + overlays + view zones)
        ├─ AccessibleDiffViewer   (alternative line review panel)
        └─ RevertButtonsFeature   (glyph-margin revert controls, writable only)
        │
        └─ two full CodeEditorWidgets (all editor contributions, options,
           find/hover/context menu/sticky scroll, view state)
```

Relevant upstream sources:

* orchestration: `vscode/src/vs/editor/browser/widget/diffEditor/diffEditorWidget.ts`
* options: `.../diffEditorOptions.ts`
* view model: `.../diffEditorViewModel.ts`
* full sub-editors: `.../components/diffEditorEditors.ts`
* view zones: `.../components/diffEditorViewZones/diffEditorViewZones.ts`
* decorations: `.../components/diffEditorDecorations.ts`
* gutter: `.../features/gutterFeature.ts`
* overview ruler: `.../features/overviewRulerFeature.ts`
* hide unchanged: `.../features/hideUnchangedRegionsFeature.ts`
* moved blocks: `.../features/movedBlocksLinesFeature.ts`
* accessible viewer: `.../components/accessibleDiffViewer.ts`
* sash: `.../components/diffEditorSash.ts`
* workbench pane: `vscode/src/vs/workbench/browser/parts/editor/textDiffEditor.ts`

### 2.2 Local composition

```text
original text buffer ─┐
                      ├─ splitOwnedLines (one allocation per line)
modified text buffer ─┘
        │
        ├─ DiffEditorViewModel.compute()   (synchronous, on the TUI thread)
        ├─ computeAlignedRows()            (arrays of display rows, fillers)
        ├─ buildDisplayText()              (full aligned text copy per side)
        └─ two read-only Editor/View instances over those text copies
              │
              ├─ DiffEditorDecorations (model decorations on the aligned text)
              └─ hand-painted one-cell gutter + mouse split drag
```

The concrete terminal view is injected by the composition root
(`EditorService`/`editorPane`), and snapshot diff opening now lives in
`EditorService.openSnapshotDiff`. The local pipeline replaces upstream's
**layout-time view zones** with **pre-materialized aligned text**. This is the
root of both the missing UI (unrelated features have nothing to attach to) and
several coordinate bugs (the view line no longer equals the model line).

### 2.3 File/feature map

| Upstream | Local | Status | Note |
|---|---|---|---|
| `diffEditorWidget.ts` | `diffEditorWidget.zig` | **Ad-hoc collapse** | Generic `DiffEditorWidget(View)` with the terminal view injected by the composition root; one widget still owns panes, decorations, gutter, input and layout. No `View`/view-part/feature lifecycle. |
| `diffEditorOptions.ts` | `diffEditorOptions.zig` | **Partial** | Small option subset; many upstream options are absent or ignored (§3.10). |
| `diffEditorViewModel.ts` | `diffEditorViewModel.zig` | **Partial** | Compute/state/normalize only. No `isDiffUpToDate`, async/cancellation, incremental edits, unchanged regions, moved comparison or serialization. |
| `diffEditorEditors.ts` | `diffEditorEditors.zig` | **Partial** | Pane-width math only. No full editor option sync or contributions. |
| `diffEditorViewZones/` | `diffEditorViewZones.zig` | **Terminal substitution** | Aligned rows instead of view zones; loses wrapping/inner-hunk/foreign-zone alignment and creates one row per filler. |
| `diffEditorDecorations.ts` | `diffEditorDecorations.zig` | **Partial** | Line/filler/char classes exist; indicators, margin classes, empty markers, current moved block and theme colors do not. |
| `gutterFeature.ts` | `gutterFeature.zig` + `paintGutter` | **Partial/ad-hoc** | Marker helpers only; no action toolbar, no cursor-driven current hunk, wrong coordinates. |
| `overviewRulerFeature.ts` | `overviewRulerFeature.zig` | **Partial** | Constants plus an unused `collect`; actual markers are per-side model decorations. No combined ruler/viewport slider. |
| `hideUnchangedRegionsFeature.ts` | folding ranges in widget | **Ad-hoc substitution** | No disclosure widgets, counts, reveal controls or breadcrumbs; folding breaks display-row coordinates (§5.3). |
| `movedBlocksLinesFeature.ts` | absent | **Missing** | Only block decorations; no connectors, overlays, active/hover state or moved-block view zones. |
| `revertButtonsFeature.ts` | absent | **Missing (read-only scope)** | Upstream also suppresses these for read-only diffs; local snapshots are always read-only. |
| `diffEditorSash.ts` | inline in `dispatchMouse` | **Partial** | Invisible one-cell drag; no reset, min-width policy, disabled state or boundary sash. |
| `accessibleDiffViewer.ts` | absent | **Missing** | No accessible review panel and no `onlyShowAccessibleDiffViewer`. |
| `commands.ts` / `diffEditor.contribution.ts` | `diffEditorCommands.zig` + `diffEditorCommandsService.zig` + `src/tui/workbench.zig` | **Partial** | Four commands only; no inline/whitespace/focus/open/collapse/accessible-viewer commands or title actions. |
| `textDiffEditor.ts` | `textDiffEditor.zig` | **Partial** | Read-only snapshots; `computeConfiguration` projects the option subset. No view-state save/restore, live option application, model reuse or diff-editor contributions. |

---

## 3. Missing UI elements

### 3.1 Complete visual-element checklist

| Element | Upstream | Local | Effect |
|---|---|---|---|
| Original + modified panes | yes | yes | Present. |
| Line numbers | yes | yes | Present for real rows; filler rows blank. |
| Changed-line backgrounds | yes | yes | `line-insert` / `line-delete` model decorations. |
| Changed-character backgrounds | yes | yes | `char-insert` / `char-delete`; terminal has no alpha. |
| Insert/delete line indicators (`+`/`-`) | yes (`renderIndicators`) | **no** | `lineDecorationsWidth` is forced to 0 and no `linesDecorationsClassName` is set. |
| Gutter tint / margin class | yes (`gutter-insert`/`gutter-delete`) | **no** | `marginClassName` is not set. |
| Center gutter separator | yes (sash/gutter area) | partial | One-cell `│`/`+`/`~`/`-`; no toolbar, hover or theme. |
| Per-hunk action toolbar | yes (`DiffEditorHunkToolbar`) | **no** | Read-only scope removes revert actions, but the toolbar/affordance is absent entirely. |
| Current hunk highlight follows cursor | yes | partial | Follows command index only; gutter uses wrong coordinates. |
| Split sash | yes | partial | Mouse drag works; no visible handle/reset/min-width/disabled state. |
| Combined two-lane overview ruler | yes (30 px strip) | **no** | Per-side scrollbar markers only; `collect` is unused. |
| Overview viewport slider / click-drag navigation | yes | **no** | No diff-specific overview hit testing. |
| Hide-unchanged-region disclosure widget | yes (`N hidden lines`, toggle, reveal top/bottom, breadcrumbs) | **no** | Generic folding only. |
| Collapse/show-all unchanged commands | yes | **no** | No commands or title actions. |
| Moved-block connector lines | yes (SVG) | **no** | Block decorations only. |
| Active moved-block highlight / compare overlay | yes | **no** | No hover/click/compare state. |
| Inline deleted-code injection (true inline view) | yes | **no** | Inline mode interleaves whole rows; no `before` deleted text. |
| Inline deleted-code margin actions | yes (copy line(s), revert) | **no** | No lightbulb/context actions; read-only removes revert but copy is still useful. |
| Inline overview-ruler markers | yes (through line decorations) | **no** | Inline decoration options have no overview-ruler entries. |
| Accessible diff viewer | yes | **no** | No panel, no command, no `onlyShowAccessibleDiffViewer`. |
| Find widget in either pane | yes (full sub-editor) | **no** | Diff tabs never create controllers; key path does not dispatch to editor. |
| Hover / diagnostics / code actions | yes (full sub-editor) | **no** | Same reason. |
| Context menu | yes | **no** | Diff mouse path has no context-menu branch. |
| Sticky scroll / word highlighter / suggest | yes (full sub-editor) | **no** | Controllers are not created for diff tabs. Bracket matching and the other `View`-level parts still run. |
| Diff editor title actions / toolbar | yes | **no** | No editor-title contribution for diff. |
| Diff code lens | optional upstream | **no** | Option not represented. |
| Word wrap (`diffEditor.wordWrap`) | yes | **no** | Option not represented; snapshots use the default wrap. |
| Theme-aware diff colors | yes | **partial** | Character and moved-border colors resolve through `themedColor`, but diff views never receive the palette and whole-line/filler/gutter colors stay hard-coded dark. |
| Live editor settings/options | yes (`updateOptions`) | **no** | Snapshot editors skip `applyEditorSettings`; diff options read only at create. |
| View state persistence | yes (`saveViewState`/`restoreViewState`) | **no** | Refresh/reopen recreates the widget and loses scroll/split/current change. |
| Editable modified side / revert | yes for writable workbench diffs | **not implemented** | Intentional read-only snapshot scope, not a terminal limitation. |

### 3.2 Keyboard/editor contribution routing (critical)

Local path:

* `src/tui/app.zig:836-838` sends every diff key to
  `Tab.handleDiffKey`.
* `src/vs/workbench/browser/parts/editor/editorPane.zig:503-506` calls
  `DiffView.handleKey`.
* `src/vs/workbench/browser/parts/editor/textDiffEditor.zig:312-314` calls
  `DiffEditorWidget.dispatchKey`.
* `src/vs/editor/browser/widget/diffEditor/diffEditorWidget.zig:700-703`
  forwards to `View.dispatchKey`.
* `src/tui/editorView.zig:895-901` only dispatches the event to the focused DOM
  element and returns false when there is none.

The editor's real key path lives in
`src/vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminalInput.zig:159-189`: it calls the hover/suggest/find
controllers, then `view.dispatchKey`, then `dispatch(editor, event, is_pasting)`.
Diff tabs never reach the last step, and because `ensureControllers` returns
early for diff tabs (`editorPane.zig:324-325`), none of the controllers exist.
The editor root also is not a focusable DOM node, so `View.dispatchKey` normally
has no focused element and returns false.

Effects:

* Arrow keys, PageUp/PageDown, Home/End, selection movement, folding keys and
  Ctrl+C are not handled by the snapshot editor.
* Ctrl+F (and all other editor commands) never reaches the editor command
  registry; there is no find widget anyway.
* Only workbench-level keys handled before the diff branch (`Alt+Down/Up`,
  Ctrl+W, group/tab shortcuts) and mouse input work.
* The test suite exercises `Alt+Down`/`Alt+Up` through `handleTabKey` and a
  code-editor command on the focused original pane
  (`src/tui/workbench.test.zig:8359-8379`), but it never sends a plain
  arrow/Ctrl+F key through the diff path, so this gap is not visible in CI.

Upstream diff panes are ordinary `CodeEditorWidget`s
(`diffEditorEditors.ts:64-65,103-139`), so every editor keybinding and
contribution applies automatically.

### 3.3 Width fallback and inline mode (critical)

* `src/vs/editor/browser/widget/diffEditor/diffEditorWidget.zig:481-483`
  defines side-by-side as `render_side_by_side and width >= minimum_side_by_side_width`.
* `:298` sets `inline_mode` once from `!render_side_by_side`; a width fallback
  does **not** enable inline mode.
* `:628-643` paints only the modified pane when `sideBySide()` is false.
* `minimum_side_by_side_width` defaults to 50 cells
  (`diffEditorOptions.zig:34-35`) and is not read from configuration.
* The upstream default is different: `useInlineViewWhenSpaceIsLimited: true`
  and `renderSideBySideInlineBreakpoint: 900` with automatic/temporary inline
  switching (`diffEditorOptions.ts:33-54`; layout at
  `diffEditorWidget.ts:157-181`).

Consequence: resizing a diff below 50 cells hides every deleted line and every
deletion background, and does not show the inline diff the user expects. The
README already documents the modified-only fallback, but this is a visible
feature loss, not just a layout choice.

The inline mode itself is also an approximation. `buildInlineDisplay`
(`diffEditorWidget.zig:72-163`) interleaves full deleted and inserted rows in one
editor. Upstream's default inline view inserts the deleted code through view
zones (`diffEditorViewZones.ts:190-286`) with its own deleted-code margin,
wrapping, indicators, copy/context actions and overview-ruler zones; the
optional true-inline view injects deleted text before the modified range
(`diffEditorDecorations.ts:61-84`). Local inline mode has none of those
affordances and, in addition, omits overview-ruler entries from its inline
decorations (`diffEditorWidget.zig:179-184,406-407`).

### 3.4 Indicators, gutter tint and empty ranges

* `diffEditorWidget.zig:357-358` calls `setLineDecorationsWidth(0)` on both
  snapshot editors.
* `DiffEditorDecorations.createWholeLine` (`components/diffEditorDecorations.zig:291-299`)
  sets only `className`/`isWholeLine`; it never sets
  `linesDecorationsClassName` or `marginClassName`.
* `render_indicators` is stored in the decoration config
  (`diffEditorWidget.zig:384-388`) but `buildOptions`
  (`components/diffEditorDecorations.zig:124-134`) never reads it.
* Upstream uses `diffLineAddDecorationBackgroundWithIndicator` /
  `...Delete...WithIndicator` and sets `lineDecorationsWidth: '2ch'`
  (`registrations.contribution.ts:29-56`;
  `diffEditorDecorations.ts:39-50`; `textDiffEditor.ts:318-324`).

Result: no `+`/`-` signs in the line-number area, no `gutter-insert` /
`gutter-delete` tint, and `diffEditor.renderIndicators` has no observable
effect.

The dedicated empty-range marker is never used: `Config.show_empty_decorations`
defaults to false (`diffEditorDecorations.zig:34-38`) and is never populated
from `diffEditor.experimental.showEmptyDecorations` (upstream defaults to true:
`vscode/src/vs/editor/common/config/diffEditor.ts:24-28`). Empty ranges
therefore fall back to a generic zero-length `char-insert`/`char-delete`
decoration instead of the upstream `diff-range-empty` marker.

### 3.5 Center gutter/toolbar and current hunk

`paintGutter` (`diffEditorWidget.zig:659-688`) paints one cell:

* it scans all mappings for every visible row;
* it uses `mapping.line_range_mapping.modified` (real model line numbers) and
  compares them to a **display row**;
* a pure deletion has an empty modified range, so it never matches and gets no
  marker at all;
* the "current" style is keyed off `current_change` (the last
  next/previous command), not the cursor position;
* only the glyph is painted; there is no gutter background, hover, action
  toolbar, click-to-focus or theme.

Upstream's gutter is a 35 px column with per-hunk toolbar items, current hunk
derived from the modified cursor, hover layouts and split-sash integration
(`gutterFeature.ts:35-260`). Even with a read-only diff (which removes revert
actions), the cursor-driven current-hunk feedback and gutter surface are still
upstream behavior.

The marker coordinate bug is detailed in §5.1.

### 3.6 Split sash

`dispatchMouse` (`diffEditorWidget.zig:707-749`) treats the one gutter cell as
the drag target and stores `split_ratio`. Missing compared with upstream
`DiffEditorSash` / `SashLayout`
(`components/diffEditorSash.ts:18-96`; used at `diffEditorWidget.ts:328-341`):

* no visible sash or hover/active affordance (only `.vertical` pointer shape);
* no double-click/reset;
* no upstream 100 px minimum editor width policy (local clamps the ratio only,
  `diffEditorOptions.zig:53-59`; drag clamps 0.2..0.8 at
  `diffEditorWidget.zig:723-727`, upstream validates 0.1..0.9);
* no disabled-state handling when `enableSplitViewResizing` is false (the drag
  flag is still set);
* no boundary sashes.

### 3.7 Overview ruler

Local behavior is per-side: whole-line decorations carry `overviewRuler`
entries (`diffEditorDecorations.zig:291-299`) and the normal editor scrollbar
paints them. `overviewRulerFeature.collect` exists but is only used by its unit
test (`features/overviewRulerFeature.zig:34-59,61-86`).

Upstream renders a dedicated 30 px strip outside the modified pane with two
lanes (removed/inserted), a viewport slider, and click/wheel delegation
(`overviewRulerFeature.ts:20-170`; layout in
`diffEditorWidget.ts:309-326`). Consequences:

* no combined two-lane diff overview;
* no viewport rectangle;
* no click/drag navigation on the overview;
* `diffEditor.renderOverviewRuler = false` removes decorations but the local
  view still reserves its normal two-cell scrollbar/overview column
  (`View.refresh`/`flush` always call `setScrollbarWidth(overviewRulerWidth(...))`
  in `src/tui/editorView.zig:1855-1858`), so the pane does not regain the space
  upstream does.

The file header documents the per-side choice as a terminal simplification. The
remaining gaps are that the combined interaction is absent and the option is not
a real layout toggle.

### 3.8 Moved blocks

Only model decorations exist:

* `DiffEditorDecorations.update` applies `movedOriginal` / `movedModified`
  block decorations (`components/diffEditorDecorations.zig:172-188`).
* The inline path adds similar block decorations
  (`diffEditorWidget.zig:851-902`).

Missing:

* connector lines between the original and modified blocks (upstream SVG in
  `movedBlocksLinesFeature.ts:31-220`);
* placeholder view zones/overlays at the moved ranges;
* active/hover moved-block state and the "compare moved code" interaction
  (`activeMovedText`, `movedTextToCompare`);
* active `currentMove` state: `editorView` can paint a themed
  `diffEditor.moveActive.border`/`diffEditor.move.border`, but no code ever
  appends `currentMove` to the moved block class;
* the side-by-side-only gating of `showMoves` (upstream
  `diffEditorOptions.ts:69`; local adds moved decorations in inline mode too,
  and its tests assert that).

In addition, the moved block ranges are applied with **real model line
numbers** instead of the aligned display rows used by the rest of the aligned
representation, so they can be misplaced after any filler row.

### 3.9 Hidden-unchanged regions

Local `hide_unchanged_regions` is implemented by adding collapsed user-defined
folding ranges to the aligned snapshot models
(`diffEditorWidget.zig:361-370,912-947`; inline variant `:766-809`). Upstream
creates:

* a 24 px collapsed-region widget per region with a disclosure toggle,
  "N hidden lines" label, breadcrumbs, reveal-top/bottom click/drag targets and
  `Show Unchanged Region` affordance
  (`hideUnchangedRegionsFeature.ts:279-345`);
* unchanged-line decorations and fold glyphs (`:190-235`);
* collapse-all/show-all commands and `allUnchangedRegionsShown` state;
* a dedicated unchanged-region model (`UnchangedRegion`, reveal preferences)
  whose hidden ranges are view-level, not model-level
  (`diffEditorViewModel.ts:458-636`).

Local consequences:

* the UI is a generic fold row; no hidden-line count, disclosure, drag reveal or
  breadcrumbs;
* no collapse-all/show-all commands;
* the region is a **model fold**, so it changes view-line numbering; the
  line-number map and navigation are not converted and become wrong after a
  fold (§5.3);
* the "whole file unchanged" special case is not handled; local can fold most
  of an identical file, while upstream suppresses unchanged-region widgets for
  that case (`hideUnchangedRegionsFeature.ts:95-101`).

### 3.10 Theme and live editor settings

`TextEditorConfiguration.applyToTab` returns immediately for diff tabs, apart
from the zen-mode line-number override, which touches only that option
(`src/vs/workbench/browser/parts/editor/textEditor.zig:140-160`).
`TerminalWorkbench.applyThemeToParts`
(`src/tui/workbenchWindow.zig:3527-3546`) and `refreshOpenViews` (`:3564-3570`)
skip diff-tab views. The snapshot editors are created once with default options
(`diffEditorWidget.zig:319-360`), and diff line/filler/gutter colors remain
hard-coded dark-theme constants (`src/tui/editorView.zig:293-302`;
`components/diffEditorDecorations.zig:40-47`). `editorView` does now route
`diffEditor.insertedTextBackground`/`removedTextBackground` and
`diffEditor.move*.border` through `themedColor` (`editorView.zig:2667-2670`,
`1661-1664`), but diff views never get the palette.

So a diff tab:

* keeps hard-coded dark diff backgrounds regardless of the active theme;
* does not get `editor.lineNumbers`, `editor.folding`,
  `editor.renderLineHighlight`, etc. when settings change;
* does not repaint on a theme change;
* does not react to any `diffEditor.*` option change until the diff is reopened
  or `Refresh Diff` recreates the widget.

The workbench projection in `textDiffEditor.computeConfiguration`
(`src/vs/workbench/browser/parts/editor/textDiffEditor.zig:27-80`) is also
reduced: `renderIndicators` is passed but unused, `renderOverviewRuler` only
removes model markers, and
`renderMarginRevertIcon`, `renderGutterMenu`, `diffWordWrap`, `diffCodeLens`,
`originalEditable`, `accessibilityVerbose`, `onlyShowAccessibleDiffViewer`,
`renderSideBySideInlineBreakpoint`, `useInlineViewWhenSpaceIsLimited`,
`compactMode`, `hideOriginalLineNumbers`, `experimental.showEmptyDecorations`
and `experimental.useTrueInlineView` are absent. The full default type exists at
`src/vs/editor/common/config/diffEditor.zig:24-55` but is not wired into the
widget.

`DiffEditorDecorations.setConfig` exists
(`components/diffEditorDecorations.zig:115-122`) but has no caller.

### 3.11 Commands, title actions and context menu

Only four diff commands are registered (`src/vs/workbench/browser/parts/editor/diffEditorCommands.zig:9-14`):

* `workbench.action.compareEditor.nextChange`
* `workbench.action.compareEditor.previousChange`
* `workbench.action.compareEditor.swapSides`
* `workbench.action.compareEditor.refreshDiff`

Missing from the upstream command set (`diffEditorCommands.ts:17-28,31-140`):

* toggle inline / side-by-side / automatic view mode;
* toggle ignore-trim-whitespace;
* focus primary/secondary/other side;
* open active diff side;
* collapse all / show all unchanged regions;
* accessible diff viewer next/previous;
* toggle show-moved-code-blocks;
* revert hunk/selection (not applicable while read-only, but also not exposed);
* diff code lens.

The terminal now has a Source Control `git.openFile` path that opens the
modified side through `open_active_diff`
(`src/tui/workbenchWindow.zig:793-800`), but there is no upstream
`workbench.action.compareEditor.openSide` command or diff title action wired to
it.

There are also no diff editor-title actions or context menu entries
(`diffEditor.contribution.ts:21-75`; title menu items for moved blocks and the
accessible viewer). The command palette therefore cannot reach many features,
and the tab/editor title exposes no diff action.

The next/previous behavior is also different: local cycles an index
(`diffEditorWidget.zig:548-566`), while upstream finds the next/previous change
relative to the modified cursor and plays accessibility signals
(`diffEditorWidget.ts:724-756`). Moving the cursor does not update the local
current change.

### 3.12 Swap, refresh and view state

`DiffEditorWidget.swapSides`
(`diffEditorWidget.zig:592-608`) swaps the editor/view pointers and widget
labels only. It does not:

* update `DiffView.model` labels, `DiffEditorInput` name/description or the tab
  title;
* swap the inline representation (it is a no-op in inline mode);
* recompute navigation maps: `revealChange` still uses
  `aligned.mappings[index].modified`, but after the swap that editor displays
  the original aligned side;
* preserve view state.

Upstream swap replaces the workbench input with the swapped untyped diff
(`diffEditorCommandsService.ts:179-220`), so title/identity/order change
together.

`DiffView.replace`
(`src/vs/workbench/browser/parts/editor/textDiffEditor.zig:274-293`) creates a
complete new widget before destroying the old one. It loses split ratio, scroll
position, cursor, current change and any view state, and re-runs the synchronous
diff and display-text construction. `EditorService.openSnapshotDiff` invokes it
for both `Refresh Diff` and re-opening an existing diff tab from SCM
(`src/vs/workbench/services/editor/browser/editorService.zig:120-129`).

Upstream restores diff view state through
`saveViewState`/`restoreViewState` and `TextDiffEditor.restoreTextDiffEditorViewState`
(`textDiffEditor.ts:135-159,193-210,423-447`).

### 3.13 Read-only snapshots (scope divergence, not a terminal limitation)

Both local snapshot editors are read-only
(`diffEditorWidget.zig:351-354`). Upstream's working-tree diff has an editable
modified side (subject to input readonly state) with revert buttons, code lens,
editing, undo and context actions. This is a deliberate scope decision already
documented in the README, but it explains why several upstream diff affordances
cannot simply be ported as-is. When scoping future work, distinguish:

* **terminal substitution** (one-cell gutter, no alpha, per-side overview);
* **read-only scope** (no revert/edit/discard);
* **unfinished port** (missing indicator/gutter/hide-unchanged/overview/
  accessible viewer/contributions/options/theme).

Only the third category is implementation debt rather than a documented scope
or terminal constraint.

---

## 4. Performance findings

No profiler was run. The findings below are confirmed code-path costs; the
reported "slow" behavior should be measured after the suggested instrumentation
to establish which term dominates on the user's files.

### 4.1 Cost model

| Phase | Local evidence | Cost | Upstream |
|---|---|---|---|
| Text acquisition | `openDiff` -> `resolveDiffTexts` -> `diffTextFor` -> `git.readRef`/`readWorkingFile` (`src/extensions/git/src/commands.zig:461-477`; `git.zig:534-562`) | Two sequential synchronous Git/file reads before the widget is created | Async editor input resolution |
| Diff computation | `DiffEditorWidget.create` calls `diff_model.compute()` synchronously (`diffEditorWidget.zig:276-284`) | Blocks the TUI thread up to `maxComputationTime` (default 5000 ms; `0` = infinite, `defaultLinesDiffComputer.zig:119-125`) | Worker + cancellation + progress + cache (`diffProviderFactoryService.ts:44-170`, `diffEditorWidget.ts:458-469`) |
| Text duplication | `splitOwnedLines` allocates every line (`:993-1000`), `buildDisplayText` copies the whole side (`:1008-1019`), then two editor models are created (`:319-345`) | At least 3 explicit copies per side plus the model/piece tree; per-line allocation overhead | Existing text models; view zones do not copy text |
| Alignment data | `computeAlignedRows` writes one entry per display row (`diffEditorViewZones.zig:75-188`) | O(total aligned lines), including N fillers for a whole-side change | One alignment/view zone per changed block/alignment (`diffEditorViewZones.ts:190-340`) |
| Filler decorations | One `diff-filler` decoration per filler row (`diffEditorDecorations.zig:233-246,191-197`) | O(N) model decorations for an untracked/deleted file; interval-tree memory | Filler is layout (view zone), not a model decoration |
| First render | `layout` + `selectInitialChange` refresh both views during `create` (`diffEditorWidget.zig:435-436,536-590`) | Two forced renders before the first workbench frame | Diff becomes visible after async diff; rendering is scheduled |
| Per-input refresh | `app.zig:959-967` calls `Tab.refresh` after every input batch; diff branch force-refreshes both panes (`editorPane.zig:363-366`); `View.refresh` invalidates then renders immediately (`editorView.zig:1477-1480`) | Two full editor renders per input batch, even for ignored keys/mouse motion | View render scheduling/coalescing |
| Per-frame gutter | `paintGutter` scans all mappings for each visible row (`diffEditorWidget.zig:669-687`) | O(visible rows × mappings) on every frame | Gutter items are laid out per hunk; current hunk found by cursor |
| Refresh/reopen | `DiffView.replace` rebuilds the entire widget (`textDiffEditor.zig:276-293`) | Recompute + re-allocate + re-decorate + lose state | Model swap/update and view-state restore |
| Theme/settings | Diff tabs are skipped (`src/vs/workbench/browser/parts/editor/textEditor.zig:140-160; src/tui/workbenchWindow.zig:3538-3545`) | Avoids work, but requires reopen/refresh to see changes | `updateOptions` and theme-driven repaint |

### 4.2 Blocking diff computation (P0)

`DiffView.create` calls `DiffEditorWidget.create`
(`textDiffEditor.zig:193-207`), which runs `compute()` synchronously before the
first frame. `maxComputationTime` is a UI freeze budget, not a background
budget:

* default `5000` ms (`diffEditorOptions.zig:26`);
* `0` selects `InfiniteTimeout`
  (`src/vs/editor/common/diff/defaultLinesDiffComputer/defaultLinesDiffComputer.zig:119-125`);
* `computeMoves` can add significant work when `diffEditor.experimental.showMoves`
  is enabled;
* there is no cancellation token or progress UI.

This is the most likely explanation for "opening a big diff hangs", and a
plausible explanation for general sluggishness on large files. The existing
`EditorWorkerService` (`src/vs/editor/browser/services/editorWorkerService.zig`)
already provides the native worker/request/reply pattern used by quick diff; the
diff widget does not use it.

Before `create` even runs, `openDiff`
(`src/extensions/git/src/commands.zig:461-477`) resolves both sides
synchronously through `resolveDiffTexts`/`readRef`
(`src/extensions/git/src/git.zig:539-562`; `git show --textconv`, capped by the
configured timeout) or `readWorkingFile`. That adds up to two blocking
Git/file operations on the same TUI-thread path. `readRefCached` exists but the
diff open path uses `readRef`; a `Refresh Diff` repeats the reads and the
computation.

### 4.3 Aligned-text/filler explosion (P0)

For a whole-file insertion (untracked file) or deletion, the shorter side is
materialized as N filler rows:

* `computeAlignedRows` stores N `null` entries in each side's display array;
* `buildDisplayText` emits N newline-separated blank lines;
* the original snapshot editor gets an N-line model;
* `DiffEditorDecorations` adds N `diff-filler` model decorations on the empty
  side;
* the line-number map is N entries.

Upstream keeps the original one-line model and adds one view zone with a pixel
height for the block. The local representation is therefore O(total aligned
display lines) instead of O(original model lines + alignments): the model,
line-number map and decoration set all grow with the number of inserted or
deleted lines. A 100k-line untracked file produces 100k original filler rows and
100k decorations; a 50 MB file (the configured `diffEditor.maxFileSize` limit)
can multiply into hundreds of MB and long open times.

### 4.4 Per-input double render (P1, likely visible while moving the mouse)

The TUI main loop calls `current.refresh()` after every input batch that reaches
the editor, including mouse motion (`src/tui/app.zig:959-967`). For diff tabs,
`Tab.refresh` calls
`original_view.refresh()` and `modified_view.refresh()`
(`editorPane.zig:363-366`). `View.refresh` performs `invalidate()` followed by an
immediate render (`editorView.zig:1477-1480`). Therefore every mouse-motion
batch and every keypress (including diff keys that are currently ignored)
forces two complete view renders. Combined with the gutter scan and decoration
overlays, this can dominate pointer/keyboard responsiveness on large diffs.

Upstream renders once per animation frame and only when the view is invalidated;
diff view zones and decorations are updated through observables rather than a
forced full repaint per input.

### 4.5 Gutter scan (P1, and coordinate bug)

`paintGutter` runs on every paint and scans `state.mappings` from the beginning
for every visible row. With H visible rows and M changes this is O(H × M). A
50-row viewport and 5,000 hunks means ~250,000 mapping checks per frame; 50,000
hunks means ~2.5 million. The scan also uses the wrong coordinate space (§5.1),
so optimizing it without fixing the mapping would preserve the bug.

Expected fix direction: build a per-display-row lookup once (or binary-search
aligned mapping ranges) and paint from the aligned mapping, not the raw diff.

### 4.6 Refresh/reopen cost (P1)

`DiffView.replace` (used by `Refresh Diff` and by re-opening the same SCM diff)
creates a new widget, which re-runs the synchronous diff and all allocation,
even when the text is unchanged. It also destroys the user's scroll/split/
current-change state. Upstream has a diff cache keyed by model versions
(`diffProviderFactoryService.ts:48-53,132-155`) and swaps/updates the model
rather than rebuilding the pane.

### 4.7 Initial forced render (P2)

`selectInitialChange` calls `refresh()` on both views during construction
(`diffEditorWidget.zig:536-590`), so the first frame work happens inside the
open call. This is useful for revealing the first change but can be folded into
the first scheduled frame; it is secondary to the synchronous diff computation.

### 4.8 Measurement plan

Before optimizing, instrument and measure these scenarios (the existing
`src/tui/benchmark.zig` / `zig build bench-open` pattern can host a diff
benchmark without changing the production path):

1. **Open latency / first frame**: 1k, 10k, 100k lines; identical, one hunk,
   many hunks, whole-file insert, whole-file delete; `maxComputationTime` 0,
   100, 5000; `showMoves` on/off. Split the measurement into Git/file
   acquisition, diff compute, display-text construction and editor creation.
2. **Scroll frame**: p50/p95 time for `Tab.paint` with 50 rows and 100/1k/10k
   changes; separate gutter time from view render time.
3. **Per-input cost**: time per mouse-move and per key event with a diff open;
   count `View.render_count` and `PerfCounters` for both panes.
4. **Memory**: peak bytes for the text copies, display texts, line arrays,
   maps, models and decoration counts (especially the empty-side filler case).
5. **Refresh**: open-to-refresh time with identical content.

Expected counters to add temporarily: compute ms, input line counts, aligned
display rows, decoration count, `paintGutter` iterations, per-view render
duration/count, RSS. These will show whether the blocking compute, the two
per-input renders, or the gutter scan dominates on the user's data.

---

## 5. Coordinate, navigation and state correctness

These are not merely cosmetic; they produce missing/misplaced UI and wrong
navigation in the current implementation.

### 5.1 Gutter uses real model lines as display rows

`paintGutter` (`diffEditorWidget.zig:669-687`):

```zig
const display_row = self.modified_editor.topViewLine() + row;
...
const start = mapping.line_range_mapping.modified.startLineNumber;
const end = mapping.line_range_mapping.modified.endLineNumberExclusive;
if (display_row < start or display_row >= end) continue;
```

`display_row` is an aligned **view/display** row. `mapping.line_range_mapping`
is the raw diff mapping with **real modified model line numbers**. They diverge
whenever an earlier changed block inserted a filler row on the modified side.

Examples:

* **Pure deletion**: original `a\nx\nb`, modified `a\nb`. The mapping's modified
  range is `[2,2)`, so `display_row < 2 or display_row >= 2` is always true; no
  `-` marker and no current-block highlight for the deletion.
* **Deletion before a later change**: a one-line filler shifts the later
  modified display row by one; its gutter marker is painted one row too high.
* **Original focus/scroll**: the gutter is based on
  `modified_editor.topViewLine()` even when the original pane is focused or
  scrolled independently.

The aligned `AlignedMapping.modified` range already contains the correct display
coordinates and should be the source for gutter painting. The test suite only
checks `gutterFeature` marker helpers, not rendered gutter rows, so these bugs
are uncovered.

### 5.2 Moved-block decorations use real model lines

`DiffEditorDecorations.update` applies moved block ranges from
`moved.lineRangeMapping.original` / `.modified` directly
(`components/diffEditorDecorations.zig:172-188`). The target text is the aligned
display text; after any filler, those real line numbers are not the display
rows. The test only asserts that a decoration with a `movedOriginal*` class
exists, not where it is (`src/vs/editor/test/browser/widget/diffEditorWidget.test.zig`).

### 5.3 Hide-unchanged folding breaks the display-row coordinate system

The snapshot editors are built with a full `line_number_map` of aligned rows
(`diffEditorWidget.zig:355-356`). `Editor.displayLineNumber` indexes that map
directly by the editor's **view line**
(`codeEditorWidgetTerminal.zig:2031-2038`), and the margin uses it for the
painted number (`margin.zig:348-354`). When a user-defined fold is collapsed,
the projected view-line count shrinks; all view lines after the fold shift, but
the map is still indexed by the unfolded display row. Line numbers after a
hidden region are therefore wrong.

The same mismatch affects:

* `paintGutter` (display row vs folded view row);
* `revealChange` (`setTopViewLine`/`setCursorPosition` use display rows, but the
  editor interprets them as folded view lines);
* `DiffEditorWidget.lineCount()` (returns the aligned line count, not the
  current view-line count);
* any status/cursor reporting that goes through the line-number map.

The inline hide-unchanged path has the same issue: it folds the interleaved
display rows and keeps `inline_display.line_numbers` indexed by unfolded rows
(`diffEditorWidget.zig:356,766-809`).

Upstream hidden areas are view-level and navigation uses model positions /
`revealRangeInCenter` (`diffEditorWidget.ts:724-727`), so its line numbers and
navigation remain correct.

### 5.4 Keyboard scroll does not synchronize panes

`dispatchKey` forwards only to the focused pane
(`diffEditorWidget.zig:700-703`). `syncScrollFromPane` is called from
`dispatchMouse` (`:751-756`) and `syncTopLines` from `layout` (`:493`), but no
keyboard path synchronizes the other pane. Once the key path is fixed, PageUp/
PageDown/arrow scrolling must also synchronize, or the two panes will drift and
the gutter (based on modified top) will point at unrelated rows.

Upstream synchronizes scroll through the view-zone manager's scroll observers
(`diffEditorViewZones.ts:378-430`).

### 5.5 Swap invalidates navigation and identity

See §3.12. In particular, after `swapSides`:

* `revealChange` uses the aligned **modified** display start, but
  `modified_editor` now displays the original aligned text;
* gutter mapping remains keyed to the old modified coordinates;
* the widget labels swap but `DiffView.model`/the diff input name and tab title
  do not;
* inline mode cannot swap at all.

### 5.6 Navigation is index-based, not cursor-based

`nextChange`/`previousChange` (`diffEditorWidget.zig:548-566`) operate on
`current_change`, initialized to 0 at open. Upstream uses the modified cursor
line and wraps only at the document end (`diffEditorWidget.ts:729-756`). If the
user clicks/moves the cursor in a diff and then presses next/previous, the local
result is relative to the last command, not the cursor. There is also no
accessibility signal for deleted/inserted/modified lines.

### 5.7 Resize fallback and state

* A resize below `minimum_side_by_side_width` changes the painted composition
  but not `inline_mode`; deleted content disappears (§3.3).
* `sideBySide()` can change while the original view is detached/mounted; the
  paint path handles a detached original by blitting, but the transition should
  be tested (no test covers cross-breakpoint resize).
* `Tab.syncDiffViews` updates the tab's cached modified editor/view after
  `replace`; the original view is not part of the cache and no user state is
  transferred.

### 5.8 Option-value divergences

* Local split ratio clamp: 0.2..0.8 (`diffEditorOptions.zig:53-59`,
  `diffEditorWidget.zig:723-727`); upstream validates 0.1..0.9
  (`diffEditorOptions.ts:205`).
* Local minimum side-by-side width: 50 cells, hard-coded
  (`diffEditorOptions.zig:34-35`); upstream uses a pixel breakpoint (default
  900) plus a 100 px minimum editor width
  (`diffEditorOptions.ts:33-54`; `diffEditorSash.ts:38-55`).
* `experimental.showMoves` is effective in inline mode locally; upstream
  derives `showMoves` as `experimental.showMoves && renderSideBySide`
  (`diffEditorOptions.ts:69`).
* `renderSideBySide` and other options are read only at create time, so a
  setting change does not update an open diff.
* `renderOverviewRuler` does not change the pane geometry, only the model
  marker decorations.

---

## 6. Test coverage gaps

There are 29 test declarations across the diff editor files and the workbench
diff-pane file (plus the separate workbench integration test), but they are
concentrated on model/decorations/alignment helpers. The diff widget/pane
tests now live at the upstream test paths, but their bodies are unchanged:

* `diffEditorViewModel.zig`: 3 tests (identical, insert/delete encoding, max-column
  normalization).
* `diffEditorViewZones.zig`: 5 tests (equal rows, insert/delete, top-of-file,
  line-number maps).
* `diffEditorDecorations.zig`: 2 tests (classes exist, detach).
* `src/vs/editor/test/browser/widget/diffEditorWidget.test.zig`: 12 tests
  (sizes, navigation index, read-only, split drag, wheel sync, moved
  decorations exist, hide folds, inline basics).
* `diffEditorEditors.zig`, `gutterFeature.zig`, `overviewRulerFeature.zig`,
  `diffEditorOptions.zig`: 5 helper-only tests.
* `src/vs/workbench/test/browser/parts/editor/textDiffEditor.test.zig`: 2 tests
  (input identity, replace).
* Workbench integration: one large SCM test that renders the diff frame and
  checks the labels/cursor, focus switching and a copy command, but not diff
  rows, gutter markers, theme or plain key dispatch.

The upstream `diffEditorWidget.test.ts` cases (compact disclosures, width-based
layout, `UnchangedRegion` behavior) are still not ported. Missing regression
coverage directly corresponding to the findings:

1. Pure deletion paints a `-` gutter marker at the aligned block start.
2. A change after an earlier filler paints its marker on the correct row.
3. Hide-unchanged collapsed: line numbers after the fold, next/previous and
   cursor row are correct.
4. Narrow width: deleted lines remain visible (inline fallback).
5. `renderIndicators` on/off changes line-number decorations and gutter tint.
6. Moved block decoration position equals the aligned display range.
7. Theme change repaints diff decorations; light/custom palette is used.
8. `diffEditor.*` and `editor.*` settings update an open diff.
9. Arrow/PageUp/PageDown/Ctrl+F in a diff reach the editor (keyboard routing).
10. `Refresh Diff` preserves split ratio/scroll/current change.
11. Swap updates title/identity and navigation targets.
12. Per-input refresh does not force two full renders when nothing changed.
13. A whole-file insertion does not create one decoration per filler row
    (performance regression test/benchmark).

The existing tests also assert only decoration **presence** in several places,
which is why misplaced moved blocks and missing/misplaced gutter markers pass.

---

## 7. Documentation drift

The current docs overstate the port and/or contradict each other:

* `docs/terminal-ui.md:2050-2052` still says "no inline diff/hidden-unchanged/
  moved blocks/peek/multi-diff/accessible viewer", while the code has inline,
  hide-unchanged and moved-block *models* and the README describes them.
* `docs/view-audit.md:71` marks the diff editor **T** and says gutter/
  overview-ruler features are ported with "20 tests". The actual test count is
  29, and the view-level gutter/overview/accessible/contributions gaps in this
  audit are not represented.
* `docs/git-diff-plan.md:3-5` still lists inline/hide-unchanged/moved-block
  diff as follow-ups; its test plan at `:531-534` calls the upstream-path test
  file "adapted upstream assertions", although it only contains the earlier
  terminal tests.
* `README.md:1239-1265` describes aligned snapshots, moved block decorations,
  hide-unchanged folding and the 50-cell fallback, but does not call out the
  missing indicators, gutter controls, theme/settings behavior, keyboard
  routing, combined overview ruler, accessible viewer, moved-block connectors,
  or the coordinate bugs. It also says the original pane is "not
  keyboard-focusable"; the code has a mouse path that sets `focused`, while the
  missing piece is the editor key dispatch itself.

Recommendation: treat this audit as the current gap ledger, and update
`README.md`, `docs/terminal-ui.md`, `docs/view-audit.md` and
`docs/git-diff-plan.md` as fixes land. Do not close the view-audit row as **T**
until the documented terminal substitutions are separated from the unfinished
port items listed in §3.13.

---

## 8. Prioritized remediation plan

The ordering below separates user-visible correctness from feature parity.

### P0 — responsiveness

1. **Move diff work off the TUI thread.** Reuse the existing
   `EditorWorkerService` request/reply path (as quick diff does) for the diff
   computation, return a versioned result to the widget, show a progress/message
   state after the upstream 1 s threshold, support cancellation and a result
   cache keyed by content/options. Also resolve the two snapshot texts through
   the existing async read path instead of synchronous `git show`/file reads.
   This removes the unbounded `maxComputationTime = 0` freeze and the two
   blocking Git processes.
2. **Remove the per-input double render for diff tabs.** `Tab.refresh` should
   invalidate, not force-render both panes; the frame should render once from
   the accumulated invalidation, like normal View scheduling.
3. **Replace O(rows × mappings) gutter painting** with a display-row lookup
   built from `aligned.mappings` (and fix the coordinate space at the same
   time). Add a benchmark with 1k/10k hunks.

### P0 — visible correctness

4. **Fix display-row/real-line mixing** in the gutter and moved-block
   decorations; use `AlignedMapping` display ranges consistently.
5. **Fix hide-unchanged coordinate handling** before adding controls: either
   keep hidden regions view-level (preferred, matching upstream) or convert
   line-number maps/navigation for the folded projection. Add line-number and
   navigation tests after collapsing.
6. **Make the narrow-width fallback use inline mode** (or otherwise preserve
   deletions). Honor `useInlineViewWhenSpaceIsLimited` /
   `renderSideBySideInlineBreakpoint` instead of the 50-cell modified-only
   fallback.
7. **Restore editor key routing** for diff panes: route through the editor
   command dispatcher (and then synchronize scroll after navigation), or
   instantiate the normal controllers for the modified pane. This is required
   before find/hover/context menu work.

### P1 — common UI parity

8. Add line indicators, margin classes and empty-range decorations; wire
   `renderIndicators`.
9. Apply the theme and live editor/diff options to diff panes; remove the
   hard-coded colors and skipped settings paths.
10. Make the gutter cursor-driven, theme-aware and interactive for the
    read-only actions that make sense (navigate/focus); add the sash affordance
    and min-width/reset behavior.
11. Add the hide-unchanged disclosure controls (count/toggle/reveal) once the
    coordinate model is correct.
12. Add the combined overview ruler (or explicitly finalize the per-side
    substitution) and stop reserving its width when disabled.
13. Add moved-block connectors and active/hover compare state; fix the
    side-by-side-only gating.
14. Wire the missing commands/title actions: toggle inline, toggle ignore
    whitespace, focus side, open active side, collapse/show unchanged,
    accessible viewer, swap. Make swap update title/identity and navigation.

### P2 — larger feature parity

15. Inline deleted-code view zones with margin actions/copy and overview
    markers; optional true-inline deleted text.
16. Accessible diff viewer and `onlyShowAccessibleDiffViewer`.
17. Find/hover/context menu/sticky scroll on diff panes (the full sub-editor
    contribution set).
18. View-state save/restore and session behavior; diff code lens; word-wrap
    option.
19. Port the upstream `diffEditorWidget.test.ts` scenarios and add paint-level
    regression tests/benchmarks.

A reasonable first milestone is items 1-7: it fixes the perceived slowness,
restores deletions at narrow widths, makes keyboard/mouse navigation usable and
prevents the current coordinate bugs from becoming entrenched in new UI work.

---

## Appendix A — local evidence index

| Concern | Local evidence |
|---|---|
| Text acquisition | `src/extensions/git/src/commands.zig:461-477`; `src/extensions/git/src/git.zig:539-552` |
| Synchronous create/compute | `diffEditorWidget.zig:276-284`; `textDiffEditor.zig:193-207,276-293` |
| Text duplication/filler rows | `diffEditorWidget.zig:264-345,993-1019`; `diffEditorViewZones.zig:75-188`; `diffEditorDecorations.zig:233-254` |
| One-cell gutter and scan | `diffEditorWidget.zig:659-688` |
| Wrong gutter coordinates | `diffEditorWidget.zig:669-687` vs `AlignedRows.mappings` at `diffEditorViewZones.zig:134-138` |
| Keyboard dead end | `editorPane.zig:503-506`; `textDiffEditor.zig:312-314`; `diffEditorWidget.zig:700-703`; `editorView.zig:895-901`; normal path `codeEditorWidgetTerminalInput.zig:159-189` |
| No controllers on diff tabs | `editorPane.zig:324-325` |
| Indicators disabled | `diffEditorWidget.zig:357-358`; `diffEditorDecorations.zig:124-134,291-299` |
| Hide-unchanged folding | `diffEditorWidget.zig:361-370,766-809,912-947` |
| Line-number map indexing | `diffEditorWidget.zig:355-356`; `codeEditorWidgetTerminal.zig:2031-2038`; `margin.zig:348-354` |
| Swap/refresh state | `diffEditorWidget.zig:592-608`; `textDiffEditor.zig:274-293` |
| Theme/settings skip | `src/vs/workbench/browser/parts/editor/textEditor.zig:140-160; src/tui/workbenchWindow.zig:3538-3545`; `src/tui/editorView.zig:293-302` |
| Options subset | `diffEditorOptions.zig:24-60`; `diffEditorWidget.zig:276-284,384-388`; `src/vs/workbench/browser/parts/editor/textDiffEditor.zig:27-80` |
| Commands | `src/vs/workbench/browser/parts/editor/diffEditorCommands.zig:9-14`; `src/tui/workbench.zig:1503-1526` |
| Read-only snapshot | `diffEditorWidget.zig:351-354` |
| Per-input diff refresh | `app.zig:959-967`; `editorPane.zig:363-366`; `editorView.zig:1477-1480` |

## Appendix B — upstream evidence index

| Concern | Upstream evidence |
|---|---|
| Composition/features | `diffEditorWidget.ts:114-118,309-417,426-473` |
| Full sub-editors/options | `diffEditorEditors.ts:64-139`; `diffEditorOptions.ts:33-100` |
| Worker/cache/progress | `diffProviderFactoryService.ts:44-170`; `diffEditorWidget.ts:458-469` |
| View zones / alignment | `diffEditorViewZones.ts:46-340` |
| Inline deleted code/margin | `diffEditorViewZones.ts:190-286`; `inlineDiffDeletedCodeMargin.ts:24-160` |
| Decorations/indicators | `diffEditorDecorations.ts:39-100`; `registrations.contribution.ts:29-56` |
| Gutter/toolbar/current hunk | `gutterFeature.ts:35-260` |
| Overview ruler | `overviewRulerFeature.ts:20-170` |
| Hide unchanged widgets | `hideUnchangedRegionsFeature.ts:95-101,279-345` |
| Moved blocks | `movedBlocksLinesFeature.ts:31-220` |
| Sash | `diffEditorSash.ts:18-96` |
| Accessible viewer | `accessibleDiffViewer.ts:63-120`; `diffEditorWidget.ts:401-417` |
| Commands/title actions | `diffEditorCommands.ts:17-140`; `diffEditor.contribution.ts:21-75` |
| Workbench view state/live options | `textDiffEditor.ts:126-159,193-210,318-324,423-447` |
| Defaults | `vscode/src/vs/editor/common/config/diffEditor.ts:6-41` |
| Upstream widget tests | `vscode/src/vs/editor/test/browser/widget/diffEditorWidget.test.ts` |
