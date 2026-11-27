# Startup and scrolling profile — 2026-11-27

Baseline: `38383736`, Zig 0.17 Debug build, macOS ARM64, 140×44 PTY,
`src/tui/app.zig`, word wrap off. Both builds used the same pinned upstream
grammar and system extension assets. No ReleaseFast switch or view-model
shortcut was used.

## Startup

The reported slow launch's existing `main.log` showed a first frame at
69,099 ms; the extension host alone took 67,504 ms before reporting
`HostTimeout`. The macOS `sample` call graph placed the main thread in
`HostManager.start → ipc.Server.accept → poll`. The installed Node bundle
recognized the legacy `--socket` switch but not the new
`VSCODE_EXTHOST_IPC_HOOK` variable. It fell back to fd 3/4, reporting EBADF
and ENXIO instead of connecting. Commit `b39231fb` had extended the
connection deadline from 10 seconds to 60 seconds.

A matched workspace launch with the same older Node bundle, 87 system
extensions and 73 user extension manifests, but fresh temporary user-data and
log directories, reproduced the issue:

| Stage (cumulative from main entry) | Baseline | Patched |
| --- | ---: | ---: |
| Workbench init | 292 ms | 234 ms |
| Workspace/git | 1,512 ms | 855 ms |
| Extension host | 61,632 ms (timed out) | 1,132 ms (initialized) |
| First frame | 62,196 ms | **1,748 ms** |

The manager now passes the same endpoint through both the canonical
environment contract and the legacy argument. Its protocol and deadline are
unchanged. The host log confirms successful initialization. The configuration
extension point also reloads the effective configuration once per inventory,
as upstream batches the additions in `configurationRegistry.deltaConfiguration`.
The startup profile had shown repeated configuration-content comparisons
during per-extension registration.

## Scrolling

`sample <pid> 3 1` during continuous wheel input showed visible line rendering
(including bracket guides and foreground tokenization), ANSI formatting and
terminal writes. Neither the 60-second wait nor the main scrolling stacks
pointed to the WindowIo executor as the dominant cost.

The UI encoder now emits only the changed foreground/background for
color-only style transitions. It preserves the other rendition attributes
and the border pen; non-color changes still use the existing reset path.
RGB color escapes use a bounded decimal encoder. The frame-diff, row erase,
wide glyph and synchronized-output contracts are unchanged.

For a matched scrolling run, both builds used the same empty temporary
extension directory and no executable host runtime. After the initial
frame and a one-second settling interval, send 25 SGR wheel-down inputs
at column 100, row 20, waiting for the next synchronized frame and spacing
inputs by 35 ms. Then send 180 wheel-down inputs at approximately 60 Hz
and allow one second for the final frames.

| Metric | Baseline | Patched |
| --- | ---: | ---: |
| Median input-to-frame completion | 6.35 ms | **5.08 ms** |
| 90th percentile | 9.25 ms | **7.59 ms** |
| Synchronized frame bytes (179 frames each) | 7,262,311 | **4,183,030** |

That is approximately 20% lower median latency and 42% less terminal
traffic. The PTY reader drains output but does not run a graphical terminal
emulator, so this measures editor/PTY latency rather than screen presentation.
Bracket guides, tokenization and editor layout remain measurable costs;
very large documents, different settings and other platforms require their
own profiles.

## Validation

- `zig build` and `zig build check-workbench` succeeded.
- Native `zig build test --summary all` succeeded (3,862 main-suite tests
  passed, 52 skipped); the standalone UI suite passed all 322 tests.
- The two extension-host transport integration tests passed (legacy
  socket-argument launcher and the current pinned launcher, including its
  intentionally slow connection). The configuration-delta test passed.
- The sandboxed test run did not deliver native watcher events and denied
  Unix socket binding; the native rerun resolved those failures.

## Reproducing

Use the built executable with its adjacent `share/vscode-textbuffer` and
`lib/vscode-textbuffer` directories. Launch it in a 140×44 PTY using
`--user-data-dir`, `--extensions-dir` and `--logsPath` for isolated runs.
Compare the `startup:` stages from `main.log`; profile startup and wheel
input independently using macOS `sample`. For in-process measurements
without a PTY, use the existing `zig build bench-open` and
`zig build bench-ui` targets.
