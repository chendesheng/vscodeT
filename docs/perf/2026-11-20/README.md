> Historical note: the VSCodeVim measurements below describe the removed extension path. Vim is now a compiled-in built-in extension; see `docs/vim.md`.

# Raw end-to-end profile artifacts — 2026-11-20

Supporting data for
[`docs/performance-profile-2026-11-20.md`](../../performance-profile-2026-11-20.md).
No runtime code was changed for this run; these are profiler logs, timing
traces and the parsed hotspot tables.

## What was run

- **Default Debug build** (`zig build`) and **ReleaseFast**
  (`zig build -Doptimize=ReleaseFast`) of the TUI.
- **VSCodeVim 1.32.4** from the pinned `.cache-ext/vim` fixture, plus a
  no-VSCodeVim native baseline. Both used the pinned Node extension host in
  `host/dist/extensionHost.mjs`.
- Workload: a 1,000-line Zig file (44,984 bytes, the first 1,000 lines of
  `src/tui/editorView.zig`), opened in an isolated workspace with one file.
  Startup scaling used the 500-line and 2,843-line variants of the same file.
- Terminal geometry: 140 columns × 44 rows, `TERM=xterm-256color`,
  `COLORTERM=truecolor`.
- Host: macOS 26.6.2 (25G83), Apple M1 Pro (10-core), arm64, Zig 0.17.0.

## How the timing was taken

The app was spawned on a PTY. The harness answered the cell-border DCS query
and DA1, then decoded the app's output. A completed frame is bounded by the
`CSI ?25h` cursor-show write that `syncCursor` emits after each
`workbench.render`. Cursor position is the last `CSI row;col H` in a frame.

- **Startup / settle:** time from `execve` to the first frame, then to the last
  frame before 1.5 s with no output. At that point the deferred background
  tokenization, folding and bracket-guide passes are done.
- **Operation latency:** one key is written to the PTY; latency is the time
  until the first frame whose cursor or content differs from the pre-key
  frame. Keys were spaced 350–600 ms apart so operations did not overlap.
  This measures the app side, not the outer terminal's render.
- **Profiler:** `/usr/bin/sample <pid> <seconds> 1 -file <log>`. The startup
  sample starts at spawn; the burst samples start after the app settles and
  drive a continuous workload; the idle sample sends no keys. `analysis.json`
  was produced from the call graphs by subtracting blocked samples
  (`poll`, `__semwait_signal`, `nanosleep`, `__recvmsg`, `kevent`) and
  aggregating the remaining active main-thread samples. The report gives both
  inclusive and self (`exclusive`) shares.

## Files

| File | Description |
| --- | --- |
| `release-startup.txt.gz` | ReleaseFast startup: first paint, open, deferred tokenization clearing |
| `release-burst-native.txt.gz` | ReleaseFast, 8 s native key burst after settle |
| `release-burst-vim.txt.gz` | ReleaseFast, 8 s VSCodeVim key burst after settle |
| `release-idle.txt.gz` | ReleaseFast, 5 s with no input after settle |
| `debug-startup.txt.gz` | Debug startup: first paint through background-tokenization settle |
| `debug-burst-native.txt.gz` | Debug, 8 s native key burst after settle |
| `debug-burst-vim.txt.gz` | Debug, 8 s VSCodeVim key burst after settle |
| `debug-idle.txt.gz` | Debug, 5 s with no input after settle |
| `analysis.json` | Parsed main-thread call graphs: active/inclusive/self samples |
| `hotspots.md` | Human-readable hotspot tables generated from `analysis.json` |
| `latency-release-vim.jsonl` | Per-operation ReleaseFast + VSCodeVim timings |
| `latency-release-native.jsonl` | Per-operation ReleaseFast native timings |
| `latency-debug-vim.jsonl` | Per-operation Debug + VSCodeVim timings |
| `latency-debug-native.jsonl` | Per-operation Debug native timings |
| `latency-summary.md` | Median/min/max table for the four latency traces |
| `bench-debug-1000.log` | `zig build bench-open` output for the 1,000-line file |

The `.txt.gz` files are plain `sample` text; `gunzip -c <file> | less` works.
The JSONL traces contain one JSON object per key/frame/operation; the `op`
records include `before`/`after` cursor cells, `effect_ms` (first changed
frame), `last_frame_ms` (last frame in the measurement window) and the number
of frames.

## Caveats

- `sample` at 1 ms is a statistical sample. Percentages are shares of the
  **active** main-thread samples, not wall-clock percentages.
- The Debug allocator captures a stack trace for every allocation; this
  dominates Debug CPU and memory. Use the ReleaseFast numbers for algorithmic
  hotspot analysis.
- The PTY harness has no GPU/terminal emulator: it excludes the outer
  terminal's rendering time and includes the app's ANSI encode and write.
- The extension host and VSCodeVim run out of process; the profiler samples
  only the Zig process. Extension-host CPU and Node startup are visible as
  blocked time in the startup profile, not as Zig samples.
