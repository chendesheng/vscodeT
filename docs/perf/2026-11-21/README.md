# Scroll-pipeline port and profile — 2026-11-21

Status: measurement report for the scroll-pipeline port. The runtime changes
are in the same working tree.

This run follows [the 2026-11-20 end-to-end profile](../performance-profile-2026-11-20.md).
That profile showed that the dominant cost of a scroll frame was a full
workbench + surface rebuild and that the Debug allocator's stack-trace capture
was 70–94% of active CPU. This work ported the missing upstream scroll/render
pieces and removed the fixed per-layout costs; this report records the
before/after numbers.

## What changed

- The wheel is owned by the ported `EditorScrollbar`
  (`mouseWheelScrollSensitivity`, `fastScrollSensitivity`, whole-line clamping)
  instead of the pointer handler.
- The vertical scroll position moved from `Editor.top_view_line` into a
  line-granular `ViewLayout` (port of `common/viewLayout/viewLayout.ts` on top
  of the ported `LinesLayout`) with upstream's `onDidScroll` →
  `ViewScrollChanged` flow. `TerminalViewHost` reads the viewport from it and
  `ViewLines` re-renders only lines dirtied by view events.
- Viewport tokenization is bounded: an incremental scroll tokenizes the new
  lines, an edit walks from the first invalid line, and a jump tokenizes the
  visible range from a guessed start state instead of every line in between.
  The model version guards the forced interval so steady-state frames skip it.
- Unicode line-break tables are decoded at compile time. They used to be
  rebuilt (with allocations) on every `layoutTree` call.
- Status bar, side-bar title and panel title keep their last painted surface
  grid and skip the clear + flex layout when their state is unchanged.
- The TUI process uses `DebugAllocator(.{ .stack_trace_frames = 0 })` in Debug
  builds. The safety and leak checks stay; the unwinding goes away. Tests still
  use the fully instrumented testing allocator.
- Background-tokenization repaints are coalesced to ~8 ms while chunks are
  still pending, and the extension-host pump skips the editor-tabs spec/RPC
  work when the tab set, active tab and dirty flags are unchanged. These two
  were hotspots 5 and 6 of the 2026-11-20 report; they are not part of the
  editor-only benchmark below.

## Method

`zig build bench-open` on the same machine as the 2026-11-20 profile
(Apple M1 Pro, macOS, Zig 0.17). The benchmark file is `src/tui/app.zig`
(the default `-Dbench-file`), terminal geometry 140×44. Numbers are the best or
averaged stage timings printed by the opt-in `benchmark:` tests; they are
diagnostics, not assertions.

The new `benchmark: workbench scroll frame` constructs a real `Workbench` with
one file open and measures the full frame: scroll state update, editor view
refresh, status-bar refresh and `Workbench.render` (editor paint, tab strip,
status bar, ANSI encode/write). It does not include the PTY, the outer terminal
emulator or the extension host.

Debug runs use the benchmark's page allocator, like the rest of `bench-open`;
the app's own Debug allocator adds metadata overhead on top. PTY end-to-end
measurement was not possible in this environment (PTY allocation is blocked),
so these are in-process numbers.

## Editor-only scroll (`benchmark: scroll frame`)

| Build | Metric | Before | After | Change |
| --- | --- | ---: | ---: | ---: |
| Debug | one-line scroll (best) | 6.45 ms | **2.93 ms** | 2.2× |
| Debug | wheel, 3 lines (best) | 6.52 ms | **3.01 ms** | 2.2× |
| Debug | page scroll (best) | 6.80 ms | **3.25 ms** | 2.1× |
| Debug | average refresh | 2.02 ms | 2.11 ms | same |
| Debug | average paint | 5.00 ms | **1.48 ms** | 3.4× |
| ReleaseFast | one-line scroll (best) | 1.09 ms | **0.87 ms** | 1.3× |
| ReleaseFast | wheel, 3 lines (best) | 1.13 ms | **1.03 ms** | 1.1× |
| ReleaseFast | page scroll (best) | 1.31 ms | **1.07 ms** | 1.2× |
| ReleaseFast | average refresh | 0.86 ms | 0.88 ms | same |
| ReleaseFast | average paint | 0.42 ms | **0.16 ms** | 2.6× |

The paint drop is the compile-time line-break tables (the layout pass is the
same tree; it just no longer re-decodes 2,812 Unicode ranges). This table is
the pipeline-port checkpoint; the retained-DOM result below supersedes it.

## Full-workbench scroll (`benchmark: workbench scroll frame`, new)

| Build | Frame (best) | avg refresh | avg render |
| --- | ---: | ---: | ---: |
| Debug | **3.56 ms** | 2.52 ms | 2.09 ms |
| ReleaseFast | **1.00 ms** | 1.06 ms | 0.25 ms |

`render` here includes the editor surface paint, tab strip, status bar and the
ANSI frame diff/write. Before the status-bar/title caches the status bar alone
was 33–38% of active CPU in the end-to-end profile; it is now skipped when
unchanged.

## Retained DOM window (latest tree)

The cell-layer experiment was reverted: the editor renders through the `ui` DOM
again, but the document is now retained and only the visible window exists. A
scroll translates the retained line boxes (`translateSubtree`), dirty lines
rebuild only their own children (`rebuildSubtree` + `layoutSubtree`), entering
lines are added from the recycled node pool and leaving lines are destroyed.
Text runs share interned `PaintStyle` objects instead of copying a full `Style`
per node. The gutter, scrollbar, widgets and status row are still rebuilt in
place every frame; the box arena is reset by a full box solve when it crosses
its bound.

| Build | Metric | Pipeline port | Retained DOM |
| --- | --- | ---: | ---: |
| Debug | one-line scroll (best) | 2.93 ms | **1.16 ms** |
| Debug | wheel, 3 lines (best) | 3.01 ms | **1.32 ms** |
| Debug | page scroll (best) | 3.25 ms | **1.55 ms** |
| Debug | average refresh / paint | 2.11 / 1.48 ms | 1.28 / **0.11 ms** |
| Debug | full-workbench frame (best) | 3.56 ms | **1.86 ms** |
| ReleaseFast | one-line scroll (best) | 0.87 ms | **0.58 ms** |
| ReleaseFast | wheel / page scroll (best) | 1.03 / 1.07 ms | **0.73 / 0.76 ms** |
| ReleaseFast | full-workbench frame (best) | 1.00 ms | **0.76 ms** |

The average paint is now small because layout happens once per refresh (on the
dirty subtrees or, for a large dirty set, on the retained tree) instead of
inside every paint. The useful number is the frame total.

The edit frame is the one regression: Debug 4.62 ms and ReleaseFast 1.67 ms,
versus 5.37/1.81 ms before this series but 3.18/1.50 ms in the reverted cell
build. Each dirty line is solved separately to keep the scroll path cheap, and
Debug text layout makes that expensive; a batched full solve was measured
slower in Debug, so the next edit-path work is reusing per-line layout results
across the dirty set rather than batching.

## Other stages

| Build | Stage | Before | After |
| --- | --- | ---: | ---: |
| Debug | edit frame (best) | 8.72 ms | **5.37 ms** |
| Debug | edit refresh / paint | 3.26 / 5.15 ms | 3.49 / 1.65 ms |
| ReleaseFast | edit frame (best) | 2.03 ms | **1.81 ms** |
| Debug | open (best) | 34.5 ms | 32.1 ms |
| ReleaseFast | open (best) | 16.0 ms | 16.3 ms |

## Remaining hotspots

1. The gutter, scrollbar, widgets and status row are still rebuilt in place on
   every refresh. They are now the main fixed cost of an editor refresh; the
   next step is retaining their per-line/per-marker nodes the same way as
   `ViewLines` (and reusing their boxes instead of growing the box arena).
2. `View.rebuild` still computes indentation/bracket guides and the gutter
   document on every refresh. The guide pass is the largest remaining
   editor-refresh cost in a Debug profile of the benchmark.
3. The status-bar/title caches use a content hash in `render`; a per-part
   revision would make the unchanged case cheaper still.
4. The rAF render coordinator from `view.ts` has no direct terminal
   equivalent; the main loop's input batch is the frame boundary, and the
   wheel path applies whole-line deltas immediately. Smooth sub-line scrolling
   is intentionally not ported (cells cannot show it).

## Artifacts

- `zig build bench-open` output for the tables above (not committed; rerun to
  reproduce).
- Historical profile and raw samples:
  [`perf/2026-11-20/`](../2026-11-20/README.md).
