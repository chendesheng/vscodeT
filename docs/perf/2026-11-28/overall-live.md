# Overall live workbench profile — 2026-11-28

## Actual session

The detached worktree was fast-forwarded to main's `1c7eed0c` and launched
with **`zig build run -- .`** in a dedicated 140×44 tmux terminal, targeting
the real repository, not a benchmark model. Zig 0.17 Debug; macOS ARM64.
The profile used a temporary `VSCODE_APPDATA` with a copy of the user's
TUI settings, the normal base VS Code settings and installed extension
inventory (150 enabled extensions, 87 system and 71 user before
 deduplication). Vim was enabled. The already-built extension-host runtime
was copied from the main worktree so the detached checkout did not run its
older installed host bundle. No application source or user settings were
modified permanently.

The harness sent terminal mouse/keyboard events to the actual editor,
observed rendered screens and recorded the next synchronized-output frame
in the tmux pipe. It ran `sample <editor-pid> 3 1` for interaction phases,
with longer startup/search/diff-open samples. This is not an isolated
in-process render benchmark and is not a comparison against graphical
VS Code. Times include tmux command dispatch and host scheduling; the
post-send median is a second diagnostic, not an exact app-only latency.
Async updates can also emit a frame independently of the input.

## Startup and idle

| Cumulative stage from main entry | First launch | Warm build run |
| --- | ---: | ---: |
| Workbench init | 226 ms | 248 ms |
| Settings/modal setup | 252 ms | 282 ms |
| Themes | 257 ms | 287 ms |
| Workspace/Git | 1,107 ms | 849 ms |
| Extension host | 2,453 ms | 1,968 ms |
| First frame | 2,483 ms | 1,979 ms |

The first `zig build run` command took approximately 63.55 s to build and
start the editor process; the cached command took 0.56 s before process
detection. Do not confuse the rebuild with editor initialization. The first
startup sample attached too early and mostly observed dyld notification
handling, so the application timings above are taken from `main.log`.
The warm sample attached after the log recorded `starting` and confirms
synchronous IPC accept during extension-host creation (186 samples) and
configuration registration/reload (162 samples in the reload stack).
The Git repository scan also spent 224 samples in `ConfigurationService.getValue`.
The installed Zig extension displayed a failed toolchain-download notification;
no successful Zig extension language-server session is assumed.

Settled idle: zero synchronized frames in 3.24 s; 2,374/2,378 main-thread
samples in `TerminalHostLoop.wait → poll`. There is no evidence of a
continuously busy render loop. Final idle after interaction also emitted no
synchronized frames during the sample, although a scheduled repository scan
consumed 159 samples of configuration merge work.

## Real interactions

`src/tui/app.zig` (2,278 lines) was opened through Quick Open, visible in
259 ms from Enter; a real workspace search for `forceTokenization` showed
132 matches in 26 files after 335 ms, including the debounce. A visible
search-result row opened `viewController.zig` after 277 ms. A temporary
tracked change to `src/tui/benchmark.zig` was detected by SCM and opened via
its Changed Files row; the target side-by-side diff was visually verified.
The initial click response was 11.56 ms, but the complete diff-open time
was not captured reliably, so it is not reported as a mount latency.

| Phase | Inputs with frame / sent | Median | p95 | Maximum | Post-send median | ANSI bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Source wheel scroll | 40/40 | 24.80 ms | 53.64 ms | 65.24 ms | 13.98 ms | 1,071,059 |
| Vim cursor movement | 40/40 | 16.27 ms | 34.73 ms | 55.11 ms | 6.55 ms | 515,934 |
| Vim insert typing | 30/30 | 39.69 ms | 86.81 ms | 284.94 ms | 29.29 ms | 100,830 |
| Git diff wheel scroll | 35/35 | 29.86 ms | 55.82 ms | 217.05 ms | 22.39 ms | 958,161 |
| Git diff typing | 25/25 | 20.80 ms | 31.72 ms | 51.95 ms | 13.41 ms | 58,694 |
| Git history graph wheel | 24/25 | 11.48 ms | 14.22 ms | 256.06 ms | 4.03 ms | 328,789 |

The diff pane did not route literal `j` as a Vim cursor command, so that
phase is **typing** rather than cursor movement. The captured frame shows
those unsaved characters. The regular source-file Vim motion phase is
verified by the displayed cursor position; source typing was undone. The
tracked file used for the Git diff was restored byte-for-byte and the
remaining synthetic diff-pane edits were discarded using the quit dialog.
Both runs exited normally. Neither printed the DebugAllocator leak-summary
message; that does not prove every allocator or process-global cache is
leak-free. The worktree was clean before writing this report.

## Main verified hotspots

### 1. Configuration cloning on the window thread

The strongest shared cost is `ConfigurationService.getValue` calling
`ConfigurationModel.override` for each language-scoped read. The Zig
implementation clones the entire model even when no valid override exists,
then discards the result through its scratch arena on the next read.
The machine/user-only branch separately calls `mergeModels(defaults,user)`
for each lookup. Its `hasKey` linear scans add substantial CPU cost.

| Sample phase | Main-thread samples | Workbench configuration getValue | Model override | Model merge |
| --- | ---: | ---: | ---: | ---: |
| Source open | 2,229 | 170 | 27 | 143 |
| Source scroll | 2,165 | 134 | 133 | 0 |
| Vim cursor | 2,098 | 54 | 53 | 0 |
| Vim edit | 2,111 | 319 | 193 | 126 |
| Diff open | 3,316 | 398 | 248 | 149 |
| Diff scroll | 2,404 | 441 | 286 | 153 |
| Diff typing | 2,409 | 379 | 209 | 169 |

These are inclusive call-stack counts summed over distinct caller branches
for the exact named function; model override/merge are nested beneath
`getValue`. The wall-clock samples include idle and background delivery, so
these are not percentages of exclusive CPU execution. On scrolling, 133
samples were inside the viewport semantic-token contribution's `enabled`
configuration checks, and on edits 96 inside document semantic coloring's
`schedule → enabled`. Repository discovery also invokes
`ensureGit → ConfigurationService.getValue`, repeatedly rebuilding the
machine-scoped configuration; this accounts for the 126 model-merge samples
in the edit phase. This is not Git status subprocess time.

Pinned VS Code (`vscode/src/vs/platform/configuration/common/configurationModels.ts`)
maintains `overrideConfigurations` keyed by override identifier. Its
`createOverrideConfigurationModel` returns the same model if there are no
valid overrides, otherwise it clones/merges only affected object values.
It caches consolidated workspace/folder models and invalidates them on the
corresponding configuration changes. The Zig workbench already has cached
workspace/folder consolidated base models; the per-language and
user-only paths do not have equivalent caches. Restore the upstream model
ownership and invalidation, rather than caching individual semantic-token
settings or suppressing their events.

### 2. Git Graph pagination blocks the main thread

The history graph is normally responsive, but scrolling to load more
history runs `SCMHistoryViewPane.handleMouse → loadMore → refresh →
ISCMHistoryProvider.provideHistoryItems → Git.log → process.run` directly
on the window thread. **1,067 of 2,575 main-thread samples** in the graph
phase were in this path, 1,040 in the subprocess-read `poll`. This accounts
for real cross-feature stalls even after the separate automatic Git status
and ref-refresh async fix. The pinned upstream `_loadMore` awaits the
provider; `extensions/git/src/historyProvider.ts` exposes asynchronous
`provideHistoryItems` and `git.ts` exposes async `log`. Port that asynchronous
request/cancellation/publication lifecycle to the existing window dispatcher.
The Zig port's `.more` refresh also resets its arena/view rows; upstream
incrementally appends fetched pages to the retained history model.

### 3. Rendering and retained memory

`View.refresh → TerminalViewHost.renderViewport` and viewport decoration
collection remain measurable alongside ANSI encoding/writes. They are
not the dominant newly identified edit/graph stalls. During source scroll,
107 samples were in `View.refresh`; during edits, 146; only six edit samples
were in bracket tree parsing. Diff scroll emitted nearly 1 MB in 35 events,
so actual emulator rendering can add latency beyond the measured pipe.

Main process physical footprint from macOS `sample`: ~98 MB settled with
no documents, 300–325 MB with the Markdown and Zig editors open, and
~393 MB after the real search and diff sessions. A separate process snapshot
showed the Node extension host at ~92 MB RSS plus extension children;
RSS and physical footprint are different metrics and must not be added
as though they were the same. A full allocation-stack trace was not enabled
because it changes runtime timing; use the new opt-in allocator diagnostics
in a separate ownership/lifetime run.

## Artifacts

Raw samples, ANSI logs, captured terminal screens, event-level and phase
summary JSONL, startup logs and shutdown evidence are retained locally in
`/tmp/vsc-overall-profile-1/` and `/tmp/vsc-overall-profile-2/`. The first
contains the interactive session, the second the warm startup. These are
not committed because they contain machine-specific paths. Profile runs
used the application as built; no production changes are made by this
report.

## Follow-up: priority fixes and matched interaction replay

At `0af3713e`, the same source file, terminal size, Debug build and input
sequence were replayed in a fresh isolated profile. The configuration model
now retains consolidated and language-override results rather than cloning
on each read (`aefabfa3`). Native graph pagination captures a detached Git
reader, requests `limit=50, skip=loadedCount`, and appends on the window
completion (`0af3713e`). No dedicated history worker thread was added.

| Phase | Baseline median | Follow-up median | Baseline p95 | Follow-up p95 | Baseline max | Follow-up max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Source wheel scroll | 24.80 | 13.91 | 53.64 | 86.17 | 65.24 | 129.51 |
| Vim cursor | 16.27 | 14.93 | 34.73 | 18.05 | 55.11 | 19.02 |
| Vim insert typing | 39.69 | 7.84 | 86.81 | 26.55 | 284.94 | 26.73 |
| Git diff wheel scroll | 29.86 | 16.76 | 55.82 | 24.30 | 217.05 | 25.66 |
| Git diff typing | 20.80 | 24.27 | 31.72 | 27.42 | 51.95 | 29.26 |
| Git history graph wheel | 11.48 | 11.10 | 14.22 | 14.16 | 256.06 | 31.82 |

All times are milliseconds, measured to the next synchronized-output frame.
The graph emitted a frame for 23/25 inputs (previously 24/25); multiple
inputs at the scroll limit can be no-ops. Git diff typing is still typing,
not cursor motion. Source-scroll tail latency and diff typing median were
worse in this run, so the changes do not establish improvement for every
interaction. The new sample confirms the principal bottlenecks independently
of tmux dispatch timing:

| Phase | Baseline `ConfigurationService.getValue` samples | Follow-up samples | Follow-up main-thread total |
| --- | ---: | ---: | ---: |
| Source scroll | 134 | 3 | 2,377 |
| Vim cursor | 54 | 2 | 2,496 |
| Vim edit | 319 | 1 | 2,460 |
| Diff scroll | 441 | 0 | 2,438 |
| Diff typing | 379 | 3 | 2,438 |

The graph sample has zero main-thread `Git.log` samples, and 30 worker
samples in `PageJob.read → HistoryRead.run → Git.log`; compare the 1,067
main-thread samples in the original pagination path. The graph still
recomputes swimlanes and renders on the window, as expected.
The final idle emitted zero frames, and the isolated editor exited normally
after discarding synthetic edits. The tracked diff fixture was restored.
Raw follow-up artifacts: `/tmp/vsc-overall-profile-3/`.

The first replay startup still contained 539 main-thread `Git.log` samples
from the initial history load. `90fe6a55` moves that query to the same worker
executor, deduplicates provider attachment, and owns the auto-ref filter
strings across async requests. Ref/merge-base resolution and cursor reveal
still use synchronous provider calls. Other Git commands have not all been
converted to async.

Remaining foreground rendering cost includes box derivation and out-of-flow
layout, `paintBox`, and viewport cell painting. These have recursive sample
counts, so their inclusive counts cannot be treated as independent CPU time.
The follow-up does not justify another editor-level render cache. The next
optimization should isolate UI library box/layout/paint allocation costs
and verify any primitive change against a matched interaction replay.

The final cached-build startup at `90fe6a55` first detected the editor process
in 0.716 s and produced its first frame 1,357 ms after process entry (baseline
warm startup 1,979 ms). Workspace/Git initialization ended at 533 ms versus
849 ms baseline. A preceding cold-after-rebuild run produced its frame at
2,916 ms, demonstrating startup variance; both final samples nevertheless
contain zero main-thread `Git.log` samples. The cached run contains 632
worker samples in `Git.log`. The rebuild itself took around 50 s, so the
`zig build run` command is not a pure startup benchmark when source changes
force a full Debug compilation. Both isolated sessions exited normally.
Raw final startup artifacts: `/tmp/vsc-overall-profile-4/` and
`/tmp/vsc-overall-profile-5/`.
