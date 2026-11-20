# Git integration and diff view plan

**Status:** proposed
**Date:** 2026-11-20
**Upstream:** VS Code 1.147.0, `vscode/` pinned at `e31c2e52f563620846caab877103f630ea361b9c`

This document plans two connected contributions: read-only Git/SCM integration
and a terminal side-by-side diff viewer. It is written against the current
tree, where the terminal editor view lives in `src/tui/editorView.zig` and is
assembled from the ported `src/vs/editor/browser/view.zig` and view parts.

## 1. Goal

Make the terminal editor usable in a Git repository end to end:

1. Discover the repository, read `git status`, and show changed/untracked files
   in a Source Control sidebar with counts, a branch status-bar entry and an
   activity badge.
2. Show live quick-diff decorations (gutter + overview ruler) in normal
   editors, updated on edit, save and external change.
3. Open a side-by-side diff tab from a changed file, using the already-ported
   diff engine, with line/word decorations, change navigation, pane layout and
   resizing.

Success criteria: in a temporary Git repository the workbench lists changed
files, decorates the open file, opens `HEAD ↔ working tree`, `HEAD ↔ index` and
`index ↔ working tree` diffs correctly, navigates blocks, never crashes on a
missing Git/not-a-repo/binary/large file, and `zig build`,
`zig build test --summary all`, `zig fmt --check` and `git diff --check` pass.
README and `docs/terminal-ui.md` state the ported scope and remaining gaps.

## 2. Scope

This change is **read-only**. It does not add staging, commit, discard, a merge
editor, a multi-diff editor, the quick-diff peek widget, inline diff mode,
hidden unchanged regions, moved-block lines, or the accessible diff viewer.

The diff tab uses **read-only snapshot editors** on both sides. The terminal
`Editor` still bundles model + undo + view, so a diff cannot share a live model
with a normal tab without the model/view split that is already a documented
limitation for splits. The modified snapshot is taken from the open buffer
(including unsaved edits) or from disk; a `Refresh Diff` command re-snapshots.
A live editable diff and the features listed above are follow-up milestones
whose hooks are named below.

## 3. Current-state findings

- Diff computation is complete under `src/vs/editor/common/diff/` (default and
  legacy computers, mappings, moves, verification, tests). There is no concrete
  `IDocumentDiffProvider` implementation yet.
- `DiffEditorInput` and its serializer exist at the workbench layer; no diff
  editor pane or widget exists.
- A tab is a `FileEditorInput` + one `Editor` + one `View`; the workbench has
  119 `tab.editor` uses and 3 `tab.input.editor` uses. `tab.input.base` is used
  for group identity.
- No `scm/`, `git/`, quick-diff or observable infrastructure exists. The
  extension host does not register SCM actors, so `vscode.git` cannot be used;
  a native command-line adapter is required.
- The terminal editor view is `src/tui/editorView.zig`. It is assembled from
  the ported `View`/`ViewLines`/line-numbers/selection/current-line/margin/
  scrollbar/widget parts through `terminalViewHost.zig`.
- The ported `LinesDecorationsOverlay` exists but is not instantiated by the
  host. Whole-line decoration backgrounds are not painted. Inline decoration
  classes already flow through `ViewModelDecorations` → `ViewLine` →
  `decorationBits`.
- The model exposes `onDidChangeDecorationsWithContext`, and the host tracks
  `Editor.decorationGeneration()` and invalidates the inline-decoration cache
  when it changes. The host does not dispatch `ViewDecorationsChanged`, and the
  lines-decorations overlay is not registered; overlays would stay stale when
  quick-diff decorations change without a content edit.
- Only `F12` is decoded as a function key; there is no `F5`/`F7`. TUI-specific
  keys are needed for diff navigation.

## 4. Architecture and data flow

```text
git (argv, cwd = repo root)
  -> src/tui/gitCli.zig: rev-parse, status --porcelain=v2 -z --branch -uall,
     show HEAD:<p>, show :<p>, read working file, blob cache
  -> contrib/git (common interfaces + browser service): state + change events
  -> src/tui/gitScmProvider.zig: SCM groups/resources + quick-diff providers
  -> contrib/scm common service -> contrib/scm browser quick-diff model/decorator
  -> TextModel decorations (+ decoration generation)
  -> terminalViewHost: LinesDecorationsOverlay / DecorationsOverlay,
     ViewDecorationsChanged
  -> src/tui/editorView.zig + margin: quick-diff cell, whole-line backgrounds,
     inline classes
  -> src/tui/scmView.zig --open--> Workbench.openDiff
  -> DiffEditorViewModel (line diff) -> aligned display texts
  -> two snapshot Editors/Views -> DiffEditorWidget
  -> Tab.paint composites both views + the center gutter
```

Adaptations to state in each file header:

- Synchronous recompute + emitters replace `IObservable`/`autorun`; the
  observable system is not ported.
- URI-based original-resource indirection collapses to
  `Original { content, ref_label }`; there is no cross-process git
  file-system provider.
- Upstream diff view-zone alignment becomes **aligned snapshot rows** (filler
  lines at changed-block ends), so both panes have equal line counts and
  scroll in lockstep.
- Browser DOM/CSS decorations map to terminal model-decoration classes and
  cell styles; colors are composited dark-theme values because cells have no
  alpha.

## 5. Implementation

### 5.1 Editor and view foundations

**Model decoration signaling** — existing APIs

- Use the already-landed `TextModel.onDidChangeDecorationsWithContext` and
  `Editor.decorationGeneration()` rather than adding a new model counter. The
  host already compares `decorationGeneration()` in `renderRange`; this change
  adds the missing `ViewDecorationsChanged` dispatch at that point.

**View-part host** — `src/vs/editor/browser/widget/codeEditor/terminalViewHost.zig`

- Own a `LinesDecorationsOverlay` (already ported) and register it as a content
  overlay; expose `lineDecorations(view_line)`.
- Add a `DecorationsOverlay` (below) and register it as a content overlay;
  expose per-line class data.
- In `renderRange`, dispatch `ViewDecorationsChanged` in the existing
  `editor.decorationGeneration()`-changed branch, so both overlays re-prepare
  after quick-diff/diff decoration updates without a content edit.
- `ViewportPaintArgs` gains `line_backgrounds: []const ?ui.Color` indexed by
  visible row; `linePaintData` returns that background and falls back to the
  current-line highlight only when no decoration background exists.

**Whole-line decoration data** — new
`src/vs/editor/browser/viewParts/decorations/decorations.zig`

- Port the `DecorationsOverlay.prepareRender` subset of
  `src/vs/editor/browser/viewParts/decorations/decorations.ts`: filter
  decorations with `className`, sort by `zIndex`/class/range, and produce
  per-visible-line class lists (with whole-line flags).
- DOM positions/sections are not needed because the terminal maps classes to a
  row background. The header documents the reduced shape.

**Margin/gutter** — `src/vs/editor/browser/viewParts/margin/margin.zig`

- Add a quick-diff marker cell after the fold cell. Gutter layout becomes
  `line numbers | fold | quick-diff`, where `line_decorations_width` is 1 when
  quick-diff decorations are enabled, else 0.
- Read the `LinesDecorationsOverlay` result (passed through
  `DocumentPartsOptions`) and paint `dirty-diff-added`,
  `dirty-diff-modified` and `dirty-diff-deleted` (primary/secondary/pattern
  variants dimmed) as a colored `+` / `~` / `-` marker.
- Use `editor.displayLineNumber(view_line)` when a line-number map is set by a
  diff snapshot; null renders a blank number (filler row).
- Update `DocumentPartsOptions` in `src/vs/editor/browser/view.zig` to forward
  `line_decorations` to the margin.

**Editor** — `src/vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig`

- Add `read_only` (`setReadOnly`/`isReadOnly`) and guard every mutation entry
  point: `insertText`, `typeCharacter`, `newline`, `insertTab`,
  `deleteLeft/Right`, `undo`, `redo`, `replaceRange`, `applyTextEdits*`,
  paste/drop, line move/copy/sort/duplicate/trim, indent/outdent/reindent,
  comment toggles, formatting and `save`.
- Add `line_number_map: ?[]const ?usize` (borrowed; owned by the diff widget),
  `setLineNumberMap`, `displayLineNumber`; use it in the margin and
  `statusTarget.selection`.
- Add `line_decorations_width` to `gutterWidthFor`/`refreshLayout`; expose
  `foldCellColumn()` and the quick-diff cell position so hit testing and fold
  toggles stay correct.

**Terminal view paint** — `src/tui/editorView.zig`

- After `terminal_view_host.renderRange`, query the `DecorationsOverlay` for the
  visible rows, map `line-insert`/`line-delete`/`diff-filler` classes to
  composited RGB backgrounds, and pass them through
  `paintViewport`/`linePaintData`.
- Add `char-insert`/`char-delete` to `decorationBit`/`decorationBits` with
  composited backgrounds. Diff decorations set both `className` and
  `inlineClassName` (the same pattern used by the find/word decorations in
  this file), so char ranges paint through `ViewLine` without a second
  decoding path.
- Keep the current-line highlight subordinate to decoration backgrounds on
  diff rows.
- Update gutter hit testing/fold-cell coordinates and tests for the new cell.

**Tab generalization** —
`src/vs/workbench/browser/parts/editor/editorPane.zig` + `workbench.zig`

- `Tab` fields become `input: *EditorInput`, `editor: *Editor`
  (modified/first), `view: *View` (modified/first),
  `file_input: ?*FileEditorInput`, `diff: ?*DiffView`, plus existing
  `controllers`.
- Add `isDiff()`, `paint(frame,x,y,w,h)`, `cursorCell()`,
  `adjustMouse`/`handleDiffMouse`, `refreshDiff`, a diff `layoutCells` branch
  and a diff `deinit` branch.
- File-tab behavior stays identical: the 119 `tab.editor` uses remain valid;
  replace `&tab.input.base` with `tab.input` and the 3
  `tab.input.editor.path` uses with `tab.editor.path`.
- `workbench.renderPane` calls `tab.paint(...)` instead of painting/blitting
  `active.view`; `Workbench.cursorCell` calls `tab.cursorCell()` and adds the
  pane offset. Diff tabs paint both view grids plus the center gutter;
  `cursorCell` returns the modified cursor at its pane offset.

### 5.2 Git core

Portable:

- `src/vs/workbench/contrib/git/common/gitService.zig` — port the types and
  interfaces of `gitService.ts`: `GitRefType`, `GitRef`, `GitRefQuery`,
  `GitChange`, `GitDiffChange`, `GitRemote`, `GitRepositoryState`, `GitBranch`,
  `GitBaseRef`, `GitUpstreamRef`, `GitCommitOptions`, `IGitRepository`,
  `IGitExtensionDelegate`, `IGitService`. Replace observables with a state
  getter + change event; keep method semantics.
- `src/vs/workbench/contrib/git/browser/gitService.zig` — port
  `GitService`/`GitRepository`: one delegate (`error.DelegateAlreadySet`),
  repository map, state updates + change event, forwarding of refs, diff and
  commit; no 10 s barrier timer.

TUI host:

- `src/tui/gitCli.zig` — implements `IGitExtensionDelegate`:
  - `git.path` override + PATH lookup; `git.enabled` gate; a dedicated
    `std.Io.Threaded` spawn helper (no shell), explicit cwd, bounded
    stdout/stderr, POSIX deadline/kill (Windows wait).
  - `discover(start)`, `status(root)` from
    `status --porcelain=v2 -z --branch -uall -c core.quotepath=false` with a
    10000-entry cap, and
    `readRef(root, path, head|index|working) -> ?[]u8` via
    `show --textconv HEAD:<p>` / `show --textconv :<p>` / a file read.
  - Parse ordinary, rename/copy, unmerged and untracked v2 records, branch
    headers (head, upstream, ahead/behind), detached/unborn HEAD, and paths
    with spaces/UTF-8; group index/working/untracked/merge changes.
  - Skip NUL/invalid-UTF-8/oversized blobs (over `diffEditor.maxFileSize`),
    missing blobs and deleted files without failing.
  - Blob cache keyed by path+ref, invalidated on status refresh; failures are
    logged once, and a missing binary or non-repo disables the provider.

### 5.3 SCM and quick-diff model

- `src/vs/workbench/contrib/scm/common/scm.zig` — port the interface subset
  needed by the terminal: `ISCMResource`, `ISCMResourceGroup`, `ISCMProvider`,
  `ISCMRepository`, a minimal `ISCMInput`, and `ISCMService`; observables
  become plain fields/events (documented).
- `src/vs/workbench/contrib/scm/common/scmService.zig` —
  `registerSCMProvider` (duplicate id error), repository map/events,
  `getRepository(id|path)` longest-root matching, disposal/count semantics; no
  context keys/storage/history.
- `src/vs/workbench/contrib/scm/common/quickDiff.zig` — `ChangeType`,
  `getChangeType`, `compareChanges`, `getChangeHeight`,
  `getModifiedEndLineNumber`, `lineIntersectsChange`, `QuickDiffProvider`
  (synchronous `Original { content, ref_label }`), `QuickDiff`,
  `QuickDiffChange`, `QuickDiffResult`, `IQuickDiffService`; port the upstream
  color constants as terminal RGB defaults.
- `src/vs/workbench/contrib/scm/common/quickDiffService.zig` — provider
  add/remove/change events, root/kind ordering, selector handling, visibility
  toggles persisted through the in-memory storage service.
- `src/vs/workbench/contrib/scm/browser/quickDiffModel.zig` — per-provider
  originals, `changes`/`changes2`/`version_id`, change map, 200 ms recompute
  trigger, `getQuickDiffResults`, `getDiffEditorModel`; no chat/progress/
  text-file-model dependencies.
- `src/vs/workbench/contrib/scm/browser/quickDiffDecorator.zig` —
  primary/secondary/contributed kinds, overlap suppression, added/modified/
  deleted ranges, `dirty-diff-*` classes, overview-ruler entries,
  `scm.diffDecorations*` settings; applies `ModelDeltaDecoration`s directly and
  keeps decoration ids.
- `src/vs/workbench/contrib/scm/browser/scm.contribution.zig` (small) —
  settings defaults/schema subset and quick-diff visibility commands.
- `src/tui/gitScmProvider.zig` — implements `ISCMProvider` over the git
  service: groups `Merge Changes`, `Staged Changes`, `Changes` (untracked
  mixed in, matching `git.untrackedChanges=mixed`), status letters, counts and
  branch name; `getOriginal` for working/index/HEAD; registers the primary
  (working vs index) and secondary (index vs HEAD, staged files only)
  quick-diff providers.

### 5.4 Quick-diff wiring

- Add a `QuickDiffController` (in `quickDiffDecorator.zig` or a small terminal
  controller): attach on tab creation/restore and detach on close through the
  existing `registerWorkingCopy`/`unregisterWorkingCopy` hooks; skip diff tabs;
  recompute when `model.getVersionId()` or git state changes; clear on tab
  switch/close; honor `scm.diffDecorations*` and
  `scm.diffDecorationsIgnoreTrimWhitespace` (`inherit` follows
  `diffEditor.ignoreTrimWhitespace`).
- Add a concrete line-diff provider to
  `src/vs/editor/common/diff/documentDiffProvider.zig`:
  `computeDiffFromLines` using `linesDiffComputers.getLegacy()` /
  `getDefault()` (external/wasm fall back to advanced), `identical` line
  comparison, `maxComputationTimeMs`, and inner changes. Quick diff uses
  `ignoreTrimWhitespace` and `computeMoves=false`.
- `Workbench.pollGit(now)` (new): quick-diff ticks, debounced SCM status
  refresh (save, workspace watcher, `git.refresh`, visible SCM view every
  ~5 s), activity/status updates; `gitWantsTick()` shortens the app poll
  timeout. `src/tui/app.zig` calls `workbench.initGit()` after
  `initSidebarFromWorkspace()` and calls `pollGit` in the loop.

### 5.5 Source Control sidebar and workbench chrome

- `src/tui/scmView.zig` — terminal view over `ISCMService`: `SOURCE CONTROL`
  header, branch/repository row, group headers with counts, relative-path
  resource rows with status letters, selection, windowed scrolling, one-cell
  scrollbar, dim when unfocused, welcome text when no provider, refresh.
  Host callbacks: `open_change`, `refresh`, `focus_editor`.
- `activitybarPart.zig`: add a `scm` activity (`G`, order 3; Settings becomes
  4) and update activity-index tests. `sidebarPart.zig`: add composite `scm`.
- `workbench.zig`:
  - Fields/init paths: `git_service`, `scm_service`, `quick_diff_service`,
    `quick_diff_controller`, `scm_view`, `git_scm_provider`,
    `git_status_entry`, `next_git_refresh`.
  - `initGit()`: resolve repo roots from workspace folders, create the CLI
    delegate/service/provider, attach existing tabs, create the status entry,
    sync the activity badge.
  - Render SCM in the sidebar; `handleSidebarKey`/`handleSidebarMouse` for SCM
    (Up/Down select, Enter/click opens the diff, `r` refresh, Escape returns
    to the editor).
  - Status entry `workbench.scm.branch` (left, high priority):
    `⎇ branch`, `↑n ↓m`, change count; click runs `workbench.view.scm` (new
    command that focuses the SCM view). `scm.countBadge=all|focused|off`
    drives the activity badge.
  - Commands: `workbench.view.scm`, `git.refresh`, `git.openChange`,
    `git.openFile`, `workbench.action.compareEditor.nextChange`,
    `previousChange`, `swapSides`, `refreshDiff`.
  - Skip diff tabs in save/revert/reload/autoReveal/working-copy/history/
    session serialization; exclude them from quick diff.
- `src/tui/app.zig`: diff keys `Alt-Down`/`Alt-Up` = next/previous change
  (F5 is not decodable), documented as TUI-specific; `Ctrl-W`, `Ctrl-S`
  (no-op) and `Ctrl-PgUp`/`Ctrl-PgDn` keep working.

### 5.6 Diff editor model, alignment and decorations

- `src/vs/editor/browser/widget/diffEditor/diffEditorOptions.zig` — options
  adapter over `ValidDiffEditorBaseOptions` + config; invalid external/wasm
  algorithms fall back.
- `src/vs/editor/browser/widget/diffEditor/diffEditorViewModel.zig` — port
  behavior: `DiffState` (`mappings`, `movedTexts`, `identical`, `quitEarly`),
  `DiffMapping`, `normalizeDocumentDiff`/`normalizeRangeMapping`,
  `toLineChanges`, compute/recompute + change events. Terminal adaptation:
  line arrays + synchronous compute instead of text models/observables;
  unchanged-region state is not ported in this change.
- `src/vs/editor/browser/widget/diffEditor/components/diffEditorViewZones.zig`
  — aligned snapshot rows: walk the mappings into unchanged segments and
  changed segments of height `max(orig_len, mod_len)`, padding the shorter side
  with blank filler lines at the block end (leading fillers for top-of-file
  insert/delete), producing equal-length display line arrays, `display -> real`
  maps and equal-height display mappings. Verify equal counts and aligned
  block starts.
- `src/vs/editor/browser/widget/diffEditor/components/diffEditorDecorations.zig`
  — port decoration lists: `line-insert`/`line-delete` whole-line backgrounds,
  `char-insert`/`char-delete` inner ranges (also `inlineClassName` for the
  ViewLine path), `diff-filler` rows, overview-ruler entries and empty-range
  decorations; apply to the display models.
- `src/vs/editor/browser/widget/diffEditor/components/diffEditorEditors.zig` —
  two snapshot editors, read-only, line-number maps, viewport/focus,
  synchronized top line, pane widths.
- `src/vs/editor/browser/widget/diffEditor/features/gutterFeature.zig` — a
  one-cell center gutter (`│`, `+`, `~`, `-`, current block highlighted);
  click focuses modified; drag resizes the split ratio
  (`enableSplitViewResizing`, `splitViewDefaultRatio`).
- `src/vs/editor/browser/widget/diffEditor/features/overviewRulerFeature.zig` —
  per-side markers (original/deleted red, modified/inserted green); the
  upstream combined two-lane ruler is not representable in one terminal
  column (documented).
- `src/vs/editor/browser/widget/diffEditor/diffEditorWidget.zig` — terminal
  orchestration: model, compute, align, editors/views, decorations, layout
  (modified-only fallback under 50 cells), paint, next/previous, swap,
  current-change status, timeout/message handling.

### 5.7 Workbench diff pane and tab

- `src/vs/workbench/browser/parts/editor/textDiffEditor.zig`:
  - `DiffEditorModel { original_path, modified_path, original_lines,
    modified_lines, original_label, modified_label }`.
  - `SnapshotEditorInput` (`workbench.editors.textDiffSnapshot`): owns a
    read-only `Editor`, resource key includes path + ref, basename name, no
    dirty/save/revert, `matches` by resource key, no serializer. Documented as
    a terminal workbench input (no upstream counterpart) needed so
    HEAD/index/working variants do not collide and snapshots never write.
  - `DiffView`/`DiffEditorWidget` creation, snapshot texts from the git service
    or open buffer/disk, aligned display text + line maps.
  - Tab title `basename (HEAD ↔ Working Tree)`, `(HEAD ↔ Index)` or
    `(Index ↔ Working Tree)` through `DiffEditorInput` preferred
    name/description.
- `src/vs/workbench/browser/parts/editor/diffEditorCommands.zig` — upstream
  ids/labels for next/previous change, swap sides and refresh; no
  revert/open-side/focus-side (no writable side, documented).
- `Workbench.openDiff(path, left_ref, right_ref, labels)`:
  - Resolve texts (HEAD/index via git CLI; working via the open tab's model
    snapshot including unsaved edits, else disk; untracked = empty original;
    deleted = empty modified).
  - Binary/oversized inputs produce a message/status instead of a diff.
  - Compute diff, align, create two snapshot inputs/editors/views and the
    widget, wrap in `DiffEditorInput`, open in the active group, create the
    diff tab.
  - If a matching diff input exists, refresh it in place and activate;
    otherwise open. No serializer is registered, so session save skips diff
    tabs cleanly.
- SCM resource opening maps refs: staged = HEAD↔index, working =
  index↔working (HEAD if not staged), untracked = empty↔working, merge = open
  the file.
- `Tab.paint`/`cursorCell`/`layoutCells`/`refresh`/`onEditorChanged` handle
  both views and the center gutter; `Workbench.editorMouseEvent` translates
  modified-pane coordinates and routes original-gutter/original-pane
  wheel/click to the diff widget; `Workbench.handleTabKey` routes diff
  navigation commands.
- Normal file tabs are untouched when a diff opens; closing the diff returns
  to the existing editor with no data loss.

### 5.8 Config defaults and docs

Add defaults to `src/vs/platform/configuration/common/configurationRegistry.zig`
(`tui_defaults_json`):

- `git.enabled=true`, `git.path=null`, `git.countBadge=all`
- `scm.diffDecorations=all`, `scm.diffDecorationsGutterWidth=3`,
  `scm.diffDecorationsGutterVisibility=always`,
  `scm.diffDecorationsGutterPattern={added:false,modified:true}`,
  `scm.diffDecorationsIgnoreTrimWhitespace=false`, `scm.countBadge=all`
- `diffEditor.ignoreTrimWhitespace=true`, `diffEditor.renderSideBySide=true`,
  `diffEditor.renderIndicators=true`, `diffEditor.renderOverviewRuler=true`,
  `diffEditor.enableSplitViewResizing=true`,
  `diffEditor.splitViewDefaultRatio=0.5`,
  `diffEditor.maxComputationTime=5000`, `diffEditor.maxFileSize=50`,
  `diffEditor.diffAlgorithm=advanced`,
  `diffEditor.experimental.showMoves=false`

Update README with Git/SCM, quick-diff and diff-viewer bullets, including
limitations (read-only snapshots, no inline/hide-unchanged/moved
blocks/staging/commit, single repo, TUI keys, hover-only gutter visibility
falls back to always, pattern/minimap/gutter-width settings not
representable). Add a terminal-substitution section to
`docs/terminal-ui.md`: no-alpha decoration colors, gutter marker cell,
per-side overview ruler, aligned snapshot rows vs view zones, line-number
override, decoration generation/event dispatch. Update
`docs/porting-inventory.md`/`tui-review.md` with the contribution status and
remaining gaps.

## 6. Public API, schema and data-flow changes

- No new model API: `TextModel.onDidChangeDecorationsWithContext` and
  `Editor.decorationGeneration()` already exist; the host gains the missing
  `ViewDecorationsChanged` dispatch.
- `Editor`: `read_only`, `setReadOnly`/`isReadOnly`, `line_number_map`/
  `setLineNumberMap`, `displayLineNumber`, `line_decorations_width`, fold-cell/
  quick-diff-cell accessors; `save` fails for read-only editors.
- `TerminalViewHost`: `LinesDecorationsOverlay` + `DecorationsOverlay`
  ownership and accessors; `ViewDecorationsChanged` dispatch;
  `ViewportPaintArgs.line_backgrounds`.
- `View`/`DocumentPartsOptions`: forward the line-decorations overlay to the
  margin.
- `Tab`: `input` becomes `*EditorInput`, adds `file_input: ?*FileEditorInput`,
  `diff: ?*DiffView`, `paint`, `cursorCell`, `handleDiffMouse`, `refreshDiff`,
  `isDiff`.
- `Workbench`: `initGit`, `openDiff`, `pollGit`, `gitWantsTick`,
  `showActivityById`, `syncGitActivity`, `refreshGitStatus`, `openScmChange`,
  new service/view fields.
- New modules/interfaces: git service/delegate, SCM service/provider/resource/
  group, quick-diff service/model/decorator, diff editor options/view
  model/widget.
- New config keys in §5.8; no persistence schema change (diff tabs are not
  serialized; quick-diff visibility uses in-memory storage).
- Data-flow change: quick diff and diff decorations are `TextModel`
  decorations with upstream class names; the terminal view maps classes to
  cell styles/gutter markers and the overview ruler instead of CSS.

## 7. Edge cases and failure modes

- No Git binary, `git.enabled=false`, not a repository, or a repository
  deleted mid-session: provider absent/disabled; SCM welcome text; editor
  unaffected; log once.
- Detached HEAD, unborn branch, worktrees, nested repos/submodules:
  best-effort; single-repository view; unsupported entries skipped.
- Untracked, deleted, renamed, type-changed, merge-conflicted, ignored and
  submodule paths; paths with spaces/UTF-8; CRLF; BOM/UTF-16 and invalid UTF-8;
  binary/NUL; files over `diffEditor.maxFileSize`: explicit skip/message;
  never partial writes.
- Huge diffs/timeouts: `quitEarly` status and partial decorations; bounded
  status entries (10000) and process output; git calls have a deadline/kill.
- External changes: clean editors reload as today; quick diff invalidates; diff
  snapshots stay stable until `refreshDiff`.
- Diff tab: no save/revert/reload/working-copy/history/autoReveal; no dirty
  prompt; session restore skips it; Ctrl-W/tab switching works.
- Narrow panes (<50 cells): modified-only fallback with a status note; mouse
  in the original pane scrolls/focuses the modified pane; the original is not
  keyboard-focusable (documented terminal simplification).
- Filler rows: blank line numbers, nearest-real-line click/navigation, no find
  hits unless text exists; line maps used by gutter and status; block-end
  padding only.
- Read-only editors: typing/paste/undo/format/save blocked;
  navigation/selection/find still work.
- Terminal resize with a diff active; cell-border and non-cell-border layouts
  both composite correctly.
- Decoration changes without content edits must not leave stale overlays
  (decoration-generation dispatch test).
- Missing `git` in CI: skip `error.SkipZigTest` for the CLI integration test;
  parser/unit tests always run.

## 8. Tests

Add and register in `src/tests.zig`:

- `src/vs/editor/browser/widget/codeEditor/terminalViewHost.zig` in-file:
  `ViewDecorationsChanged` dispatch on decoration-generation change; line
  backgrounds from `ViewportPaintArgs`; line-decorations overlay registration.
  Model decoration events are already covered by the existing
  `onDidChangeDecorationsWithContext` model tests.
- `src/vs/editor/browser/viewParts/decorations/decorations.zig` in-file:
  whole-line class filtering/sorting, visible-range clipping, zIndex/order.
- `src/vs/editor/browser/viewParts/margin/margin.zig` in-file: quick-diff
  marker classes/colors, fold+marker cells, line-number map/blank fillers.
- `src/tui/editorView.zig` in-file: gutter quick-diff markers,
  `scm.diffDecorations=none/gutter/overview`, diff line backgrounds, char
  inline colors, filler rows, fold hit-test with the extra cell.
- `src/vs/editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig`
  in-file: read-only guards, line-number map/status, gutter width.
- `src/vs/workbench/contrib/git/test/common/gitService.test.zig`: delegate
  set-once, forwarding, repository state change, lookup.
- `src/tui/gitCli.zig` in-file: v2 status parser (branch headers, ordinary,
  rename/copy, unmerged, untracked, spaces/UTF-8, malformed/truncated),
  grouping, 10000 cap; temp-repo integration (init/commit/modify/stage/rename/
  delete/untracked; HEAD/index/working reads; binary/oversized skip) with git
  unavailable → skip.
- `src/vs/workbench/contrib/scm/test/common/scmService.test.zig`:
  register/duplicate/dispose, events, repository-by-path longest root.
- `src/vs/workbench/contrib/scm/test/common/quickDiff.test.zig`: change
  classification/helpers, provider ordering/selector/visibility storage.
- `src/vs/workbench/contrib/scm/test/browser/quickDiffModel.test.zig`:
  modified/clean/staged/untracked, ignore-trim-whitespace, version tracking,
  provider changes, primary/secondary overlap suppression.
- `src/vs/workbench/contrib/scm/test/browser/quickDiffDecorator.test.zig`:
  decoration ranges/classes/overview colors, config toggles, detach cleanup.
- `src/vs/editor/test/browser/widget/diffEditorWidget.test.zig`: adapted
  upstream assertions for diff states, alignment equal line counts/block
  starts (top-of-file insert/delete), next/previous navigation, swap, narrow
  fallback, read-only behavior.
- `src/vs/editor/common/diff/documentDiffProvider.zig` in-file: line-diff
  projection, identical/insert/delete/modify, inner changes, moves,
  timeout/fallback.
- `src/vs/workbench/browser/workbench.zig` integration: temp-repo `initGit`,
  SCM rows/branch/status entry/activity badge, open staged/working/untracked
  diffs, render both sides/markers, `Alt-Down` navigation, save/revert/reload
  inert on diff tabs, session skips diff tabs,
  `scm.diffDecorations=none` clears decorations.

## 9. Validation

1. `zig build`
2. `zig build test --summary all`
3. `zig fmt --check <changed files>`
4. `git diff --check`
5. `df -h` before/after builds; clean `.zig-cache` if free space drops below
   ~5 GiB (never `zig-pkg/`, `vscode/`, or source).
6. Manual smoke in a temporary repository: gutter/overview marks, each diff
   kind, navigation, resize, close, and `--session` restart (diff tabs gone,
   normal tabs restored).

## 10. Assumptions and follow-ups

- `vscode/` stays pinned at `e31c2e52`; no upstream edits; no new
  dependencies.
- Git is on PATH or configured via `git.path`; local git commands are
  acceptable on the UI thread with deadlines.
- One Git repository per workspace folder is presented. Multi-repository
  selection, SCM input/commit/stage/discard, merge editor, multi-diff,
  quick-diff peek, inline diff mode, hide-unchanged-regions, moved-block
  lines, accessible diff viewer, editable diff sides, diff session restore and
  minimap are follow-ups. `DiffState.movedTexts` and the quick-diff interfaces
  remain so they can be added without redesign.
- Riskiest parts: Git v2 status parsing on Windows, aligned-display edge
  cases, and synchronous git latency; parser tests, alignment tests and the
  deadline/size caps target them.
