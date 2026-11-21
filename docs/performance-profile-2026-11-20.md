> Historical note: the VSCodeVim measurements below describe the removed extension path. Vim is now a compiled-in built-in extension; see `docs/vim.md`.

# End-to-end performance profile — 2026-11-20

Status: measurement report only. No runtime code was changed for this run.

This is an end-to-end profile of the TUI editor under normal editing
operations: opening a file, moving the cursor in normal mode through
VSCodeVim, inserting text, undoing/redoing, and paging. The work was run with
the default **Debug** build and with **ReleaseFast**, with the pinned Node
extension host and VSCodeVim 1.32.4.

Raw profiler logs, latency traces and the parsed hotspot tables are in
[`perf/2026-11-20/`](perf/2026-11-20/README.md).

## Headline results

- **Debug CPU is dominated by the debug allocator, not the editor.** Zig's
  `SafeAllocator` stack-trace capture accounts for 70.6% of active startup
  samples, 81.5% of the VSCodeVim burst and 94.1% of the native burst. Debug
  peak footprint is 129.8 MB versus 12.5 MB for ReleaseFast. Algorithmic
  hotspots have to be read from the ReleaseFast profile.
- **The dominant algorithmic cost is a full workbench layout on every frame.**
  In ReleaseFast, `Workbench.render` is 84–92% of active samples and
  `Surface.ensureLayout` is 61–74% *self* time. The status bar's layout alone
  is 33–38% of active CPU because it rebuilds its whole DOM/surface every
  frame, almost as much as the editor-view layout (42–48%).
- **VSCodeVim normal-mode motions are quantised at ~60 ms**, while native
  cursor moves are 4.8 ms (median). The extension-host reply is only pumped at
  the top of the main loop; the poll set has no host wakeup fd. ReleaseFast
  motions were bimodal: 4/10 at 5–14 ms, 6/10 at 60–71 ms.
- **Background tokenization is gated by a full repaint per 1 ms chunk.** A
  1,000-line file takes 8.1 s (Debug) / 0.61 s (ReleaseFast) to reach a quiet
  state; 2,843 lines take 23.5 s / 1.03 s. Debug performs 170 / 533 full
  workbench render passes while doing so (the ANSI diff is usually empty). In
  the Debug startup profile the tokenizer
  itself is only 1.7% of active CPU; the repeated full rebuild + render is the
  cost.
- **Idle is genuinely idle** after settle: 0.1% active main-thread samples in
  ReleaseFast and 0.9% in Debug. The earlier startup work does finish; the
  problem is how long it takes and how much it repaints.
- Every edit also produces **2–5 trailing render passes over ~0.4 s** from the
  deferred folding/bracket-guide/tokenization passes. The edit is visible
  early, but the app keeps repainting the whole workbench afterwards.

## Environment and method

- Repository at commit `508b752`; no runtime source was modified for the run.
- macOS 26.6.2 (25G83), Apple M1 Pro (10-core), arm64, Zig 0.17.0.
- App builds: default `zig build` (Debug) and
  `zig build -Doptimize=ReleaseFast`. Binary sizes 29 MB / 9.9 MB.
- VSCodeVim 1.32.4 from `.cache-ext/vim`, loaded through
  `host/dist/extensionHost.mjs` (Node 24.22.2). A no-VSCodeVim native baseline
  used the same host but no Vim extension.
- Terminal: 140 columns × 44 rows, `TERM=xterm-256color`,
  `COLORTERM=truecolor`. The app ran on a PTY; the harness answered the
  cell-border query and DA1, then decoded the ANSI output.
- Workload: a 1,000-line Zig file (44,984 bytes, the first 1,000 lines of
  `src/tui/editorView.zig`) in an isolated one-file workspace. Startup scaling
  used the 500-line and 2,843-line (117,967-byte) variants.
- Timing: a frame is the `CSI ?25h` cursor-show write that follows each
  `workbench.render`. Operation latency is measured from the write to the PTY
  to the first frame whose cursor/content differs from the pre-key frame.
  Keys were spaced 350–600 ms apart.
- Profiles: `/usr/bin/sample <pid> <seconds> 1 -file <log>`. Startup sampling
  starts at spawn; burst sampling starts after the app settles and drives a
  continuous workload; idle sampling sends no keys. `analysis.json` subtracts
  blocked samples (`poll`, `__semwait_signal`, `nanosleep`, `__recvmsg`,
  `kevent`) and reports shares of the remaining active main-thread samples.

Timings and percentages are diagnostic, not assertions. The sample logs are
committed gzipped with their parsed analysis.

## Startup, first paint and deferred-work settle

“Settle” is the last frame before 1.5 s of no output, i.e. after the deferred
background tokenization, folding and bracket-guide passes have finished. The
frame count is the number of render passes up to that point.

| File | Build | First frame | Settle | Render passes during settle |
| --- | --- | ---: | ---: | ---: |
| 500 lines | Debug | 0.81 s | 4.32 s | 81 |
| 1,000 lines | Debug | 0.95 s | 8.10 s | 170 |
| 2,843 lines | Debug | 1.48 s | 23.48 s | 533 |
| 500 lines | ReleaseFast | 0.23 s | 0.52 s | 39 |
| 1,000 lines | ReleaseFast | 0.23 s | 0.61 s | 78 |
| 2,843 lines | ReleaseFast | 0.23 s | 1.03 s | 255 |

The first frame is essentially constant in ReleaseFast and grows only with the
visible-line paint in Debug. The settle time scales with line count: Debug adds
roughly 8.1–8.6 ms per line, while ReleaseFast settles in 0.52 s, 0.61 s and
1.03 s for the three sizes. The Debug/ReleaseFast gap therefore grows from
about 8× at 500 lines to about 23× at 2,843 lines. That gap is not the
tokenizer's algorithm: Debug spends it in the debug allocator and repeated full
viewport rebuilds (below).

## Interaction latency

Median time from key write to the first frame that reflects the operation.
Ranges are min–max; `n` is the number of measured operations. “Motion” covers
`j`, `k`, `w`, `b`, `Ctrl-D`, `Ctrl-U`, `G`, `gg`; “insert char” is a
character after `i`; native “edit char” is a raw `x`/`y` with no Vim mode.

| Build | Path | Operation | n | Median | Range |
| --- | --- | --- | ---: | ---: | ---: |
| Debug | native | cursor move | 8 | 95.7 ms | 87.5–216.2 ms |
| Debug | native | edit char | 2 | 194.0 ms | 125.5–262.6 ms |
| Debug | native | undo/redo | 2 | 127.7 ms | 85.3–170.0 ms |
| Debug | VSCodeVim | motion | 10 | 165.4 ms | 126.6–222.2 ms |
| Debug | VSCodeVim | insert char | 5 | 160.4 ms | 139.3–368.8 ms |
| Debug | VSCodeVim | undo/redo | 2 | 146.6 ms | 127.6–165.5 ms |
| ReleaseFast | native | cursor move | 8 | **4.8 ms** | 2.5–8.1 ms |
| ReleaseFast | native | edit char | 2 | 6.8 ms | 5.8–8.0 ms |
| ReleaseFast | native | undo/redo | 2 | 14.1 ms | 13.1–15.2 ms |
| ReleaseFast | VSCodeVim | motion | 10 | **60.2 ms** | 5.2–70.7 ms |
| ReleaseFast | VSCodeVim | insert char | 5 | **12.0 ms** | 5.6–13.3 ms |
| ReleaseFast | VSCodeVim | undo/redo | 2 | 36.1 ms | 10.2–62.1 ms |

The ReleaseFast VSCodeVim motion distribution is the interesting one: 4 of 10
operations completed in 5.2–13.5 ms, the other 6 in 60.1–70.7 ms. That is a
wakeup-quantisation signature, not a CPU-bound editor path. Insert-mode text
mostly lands in the fast group (median 12.0 ms), consistent with its edit
request being applied during the same pump loop. See hotspot 7.

### Trailing maintenance frames

Every edit produces more than one render pass. Measure this by the last frame
in the operation window, not by the first visible change:

| Build / path | Render passes per edit | Last frame after key |
| --- | ---: | ---: |
| ReleaseFast native edit | 3 | ~420 ms |
| ReleaseFast VSCodeVim insert | 5 | ~422 ms |
| Debug native edit | 2–3 | ~409 ms |
| Debug VSCodeVim insert | 4 | ~381 ms |
| Debug VSCodeVim undo/redo | 4 | ~610 ms (occasionally higher) |

The visible edit is fast. The trailing frames are the 200 ms folding and
bracket-guide debounces plus background tokenization; each one goes through
`view.refresh()` and a full `workbench.render()`.

## Hotspots, ranked

Percentages are shares of **active** main-thread samples. “Inclusive” includes
callees; “self” is time in that frame. Use the ReleaseFast numbers for
algorithmic work; the Debug numbers show how much the allocator distorts the
profile.

### 1. Debug allocator stack-trace capture (Debug builds only)

| Profile | `heap.SafeAllocator.captureStackTrace` |
| --- | ---: |
| Debug startup | 70.6% inclusive |
| Debug VSCodeVim burst | 81.5% inclusive |
| Debug native burst | 94.1% inclusive |

Zig's debug allocator records a stack trace for every allocation and free. In
this workload that is most of the CPU, and the reason Debug is 10–20× slower
than ReleaseFast for CPU-bound native operations; it also uses 129.8 MB
instead of 12.5 MB. It is not an editor hot
path, but it makes Debug profiles useless for algorithmic attribution and it
is the dominant cost of the default build. Profile ReleaseFast, or use a
debug allocator configuration without stack traces, when investigating CPU
hotspots.

### 2. Full workbench layout on every frame

| Build / workload | `Workbench.render` inclusive | `Surface.ensureLayout` inclusive | `ensureLayout` self |
| --- | ---: | ---: | ---: |
| ReleaseFast native burst | 91.6% | 85.7% | 74.4% |
| ReleaseFast VSCodeVim burst | 84.2% | 75.0% | 60.6% |

`Workbench.render` composites every pane and then the status bar on every
render (`src/vs/workbench/browser/workbench.zig:3440`, `:3463`, `:3534`,
`:3471`). `Surface.paintFrame` (`ui/surface.zig:119`) calls `ensureLayout`
(`ui/surface.zig:164`), which rebuilds the box tree and solves layout whenever
the document changed. Because both the editor view and the status bar clear
their documents on every frame, layout is never warm.

Layout split by caller in the ReleaseFast profiles:

| Workload | Editor view | Status bar |
| --- | ---: | ---: |
| ReleaseFast native burst | 883 samples (47.8% of active) | 701 samples (37.9%) |
| ReleaseFast VSCodeVim burst | 500 samples (41.7%) | 399 samples (33.3%) |

This is the single biggest ReleaseFast cost. A cursor move should not relayout
the status bar, and a status bar whose text did not change should not be
rebuilt at all.

### 3. Status bar rebuilds its entire DOM and surface every frame

`StatusbarPart.render` (`src/vs/workbench/browser/parts/statusbar/statusbarPart.zig:344`)
does `doc.clear()` at `:361`, recreates the root/left/right containers and all
item nodes, calls `doc.setRoot(root)`, then `surface.paintFrame()` at `:432`
and blits the result into the workbench grid. A one-row status bar therefore
pays a full flex layout and paint every frame, even when no item changed.
Measured layout cost: 33–38% of active CPU, almost as much as the editor
viewport layout.

### 4. The editor view is fully rebuilt on every refresh

`View.refresh` (`src/tui/editorView.zig:737`) always calls `rebuild`
(`:800`), which clears the whole document (`doc.clear()` at `:836`), renders
the viewport through `paintViewport` (`:1017`), recomputes guides and cursor
state, and dirties the box tree for the next layout. It is called after every
input batch (`src/tui/app.zig:754`) and after every maintenance tick
(`:593`).

| Profile | `View.refresh` / `View.rebuild` inclusive |
| --- | ---: |
| ReleaseFast native burst | 5.1% |
| ReleaseFast VSCodeVim burst | 10.9% |
| Debug VSCodeVim burst | 50.8% |
| Debug startup | 46.6% |

In ReleaseFast the rebuild itself is not the top cost; the expensive part is
the layout it forces. In Debug the allocator makes the rebuild very expensive
as well.

### 5. Background tokenization is gated by a full repaint per 1 ms chunk

`DefaultBackgroundTokenizer.poll` tokenizes for about 1 ms
(`src/vs/editor/common/model/textModelTokens.zig:466`) and returns `true`
whenever it did work. The app's idle branch treats that as
`maintenance = true` and then calls `view.refresh()` and `workbench.render()`
(`src/tui/app.zig:581-598`). So every 1 ms tokenization slice pays a complete
viewport rebuild, status-bar rebuild, layout, ANSI encode and write.

The result is the settle table above: 170 render passes for 1,000 lines and
533 for 2,843 lines in Debug. In the Debug startup profile:

| Symbol | Inclusive |
| --- | ---: |
| `View.refresh` / `rebuild` | 46.6% |
| `Workbench.render` | 37.8% |
| `Surface.ensureLayout` | 36.0% |
| TextMate tokenization (`tokenizeEncoded`) | **1.7%** |

The tokenizer is only 1.7% of the work; the repaint loop around it is the
cost. ReleaseFast improves both sides: each repaint is cheaper and each 1 ms
slice tokenizes more lines, so it needs 78 frames instead of 170 for 1,000
lines. Coalescing maintenance renders (or only repainting when visible tokens
actually changed) would remove most of the 8 s / 23 s Debug settle.

### 6. Extension-host pump and tab sync run on every loop iteration

`Extensions.pump` (`src/vs/workbench/api/browser/extensionHostAdapter.zig:659`)
calls `syncActiveDocument()` → `syncTabs()` (`:719`) every time the main loop
iterates. `syncTabs` creates an arena, rebuilds a `TabSpec` list for every pane
and tab, and calls the editor-tabs actor even when nothing changed. There is
no dirty check.

| Profile | `Extensions.pump` inclusive |
| --- | ---: |
| Debug native burst | 64.1% |
| Debug VSCodeVim burst | 12.7% |
| ReleaseFast VSCodeVim burst | 1.2% |

The Debug figures are inflated by allocator stack traces, but the redundant
work is real: in ReleaseFast this is still a per-iteration allocation and RPC
path that does nothing when the tab set is unchanged. Cache the tab model and
skip the sync when nothing changed.

### 7. No extension-host wakeup: VSCodeVim motions wait for an unrelated timer

The main loop polls stdin, the file watcher and terminals
(`src/tui/app.zig:537-560`), but not the extension-host socket or a wakeup
pipe. `HostManager.readerLoop`
(`src/vs/workbench/services/extensions/common/extensionHostManager.zig:236`)
queues frames under a mutex and does not signal the main thread.
`Extensions.pump` only runs at the top of the loop (`src/tui/app.zig:489-491`).
A reply that arrives after that pump waits for the next unrelated wakeup or
poll timeout.

This matches the observed distribution: native moves 2.5–8.1 ms, while
VSCodeVim motions are either 5–14 ms (reply lands in the pump window) or
60–71 ms (reply misses it and waits). The 50 ms occurrence-highlight delay
(`src/vs/editor/contrib/wordHighlighter/browser/wordHighlighter.zig:54`) is
one plausible wakeup source, but it is not the only timer in the loop.
Regardless of the exact timer, the architectural gap is the missing wakeup:
adding an eventfd/pipe from the host reader to the main poll set should remove
the 60 ms quantisation.

### 8. Deferred maintenance cascades after every edit

A content change triggers folding and bracket-guide updates with a 200 ms
debounce (`codeEditorWidgetTerminal.zig:1081`, `:1274`, `:1299`) and schedules
background tokenization. Each of those passes ends in a full
`view.refresh()` + `workbench.render()`, so every edit produces 2–5 render
passes and keeps the app busy for about 0.4 s after the visible change (table
above). The trailing work is not visible to the user but competes with the next
keystroke. Coalescing these into one repaint per idle/frame budget would avoid
the cascade.

### Hotspots that did not reproduce

- **Model edits, undo/redo and scrolling are not the bottleneck.** The
  in-process Debug benchmark (below) measures a 0.127 ms edit stage, 3.5 ms
  view refresh and 5.4 ms paint for the editor view alone.
- **Tokenization in steady state** is 0.3–1.3% of active CPU after settle.
- **ANSI encoding and painting** are secondary: `ansi.encode` is 2.6–4.2% and
  `paint.paintBox` ~6% inclusive in ReleaseFast.
- **File-watcher polling** varied between 1.5% and 11% of active CPU across
  runs, depending on workspace/cache churn (2.3–2.9% in the isolated-workspace
  profiles); it is not a stable hotspot and is not ranked.
- **Idle** is blocked in `poll` 99.1–99.9% of the time.

## In-process benchmark (Debug, 1,000 lines)

`zig build bench-open -Dbench-file=<path>` using the same 1,000-line file. These stages are editor-only; they exclude the workbench
composite, status bar, ANSI encode, PTY and extension host.

| Stage | Time |
| --- | ---: |
| Open, first iteration | 28.2 ms |
| Open, best iteration | 25.1 ms |
| Open: editor construction | 12.9 ms |
| Open: view refresh | 6.6 ms |
| Open: paint | 5.4 ms |
| Edit frame, best | 8.9 ms |
| Edit: model edit | **0.127 ms** |
| Edit: view refresh | 3.5 ms |
| Edit: paint | 5.4 ms |
| Scroll one line | 7.6 ms |
| Page scroll | 8.2 ms |
| Deferred background tokenization | 161 ms (81 polls) |
| Deferred folding | 2.5 ms |
| Deferred bracket guides | 23.7 ms |

The 8.9 ms Debug editor-only edit frame versus the ~96 ms Debug native key is
an order-of-magnitude gap; it is the workbench composite/layout/encode path
plus Debug allocator overhead. The ReleaseFast end-to-end native key (4.8 ms
median) is already below the Debug editor-only edit frame, which shows how
much of the Debug cost is instrumentation. The first-open numbers also show
that building the editor/model is only about half of the first-paint work; the
rest is the first full layout and paint.

## Recommendations

Not applied in this change (the request was profile-only). In rough priority
order:

1. **Add an extension-host wakeup to the main poll set.** An eventfd/pipe
   written by `HostManager.readerLoop`, added to `pollInputWithFds`, lets the
   loop pump replies immediately instead of waiting for an unrelated timer.
   Expected to remove most of the 60 ms VSCodeVim motion latency.
2. **Stop rebuilding the status bar every frame.** Keep a dirty/version check
   and only clear/repaint when an item, width or hover state changed. Its
   layout is 33–38% of active CPU for one row of mostly static text.
3. **Make the editor view incremental or cache layout/paint between
   unchanged frames.** `View.refresh` should not clear the whole document for
   a cursor move; layout should be reused when the box tree is unchanged.
4. **Coalesce maintenance repaints.** Do not call `view.refresh()` +
   `workbench.render()` after every 1 ms tokenization chunk, or after every
   folding/guide pass. Repaint once when the idle budget is exhausted or when
   visible cells actually changed.
5. **Dirty-check `syncTabs`.** Skip the arena/TabSpec/RPC work when the tab
   set and active tab are unchanged.
6. **Profile ReleaseFast for CPU work**, or give the Debug build a
   stack-trace-free allocator. The current default hides every algorithmic
   hotspot under `SafeAllocator.captureStackTrace`.

## Caveats

- `sample` at 1 ms is statistical. Active shares exclude blocked waits; they
  are not wall-clock percentages and small phases (ReleaseFast startup is only
  121 active samples) have wide error bars.
- Debug and ReleaseFast are different binaries. Some Debug percentages are
  dominated by the allocator and cannot be compared directly with ReleaseFast.
- The PTY harness measures the app side only. It does not include the outer
  terminal emulator's rendering; it does include ANSI encoding and the write
  syscall.
- Only one machine, one editor geometry and one file shape were used. Large
  single-line files, very long files and different terminals may shift the
  balance.
- The extension host is a separate Node process; the profiler samples only the
  Zig process. Node startup and VSCodeVim CPU appear as blocked time in the
  startup trace, not as samples.
- VSCodeVim logs a non-fatal `ENOENT .../globalStorage/vscodevim.vim/.registers`
  unhandled rejection on a fresh data directory. It did not prevent activation,
  motions, edits or undo/redo in these runs.

## Artifacts

- [`perf/2026-11-20/README.md`](perf/2026-11-20/README.md) — method and file
  index.
- `release-*.txt.gz` / `debug-*.txt.gz` — raw `sample` call graphs.
- `analysis.json`, `hotspots.md` — parsed active-sample tables.
- `latency-*.jsonl`, `latency-summary.md` — per-operation timings.
- `bench-debug-1000.log` — in-process open/edit benchmark output.
