# Large TypeScript file — startup, editing and allocation profile (2026-11-28)

Baseline: `1251b2b2`, after the extension-host and ANSI fixes. Both builds
use Zig 0.17 Debug, macOS ARM64, the pinned TypeScript grammar, the same
1,357,380-byte / 36,300-line synthetic file, a 140 × 44 PTY and fresh settings
with word wrap and modal editing off. No executable extension host was
installed in these isolated runs, so its startup cannot account for the
results below.

## Why the functional audit missed the regression

The port had the right data structures and functional results, but the
following execution and ownership contracts were different from VS Code
(`e31c2e52f563620846caab877103f630ea361b9c`):

- `bracketMatching.ts` queries `model.bracketPairs.matchBracket` with a
  bounded duration (20 ms for cursor updates). The Zig controller called
  `ensureTokenized` (introduced in `c3acf51f`) before querying the tree;
  the TUI wrapper in `bdea321a` carried that behavior into every update.
  This forced TextMate over the entire file before first paint.
- Upstream `bracketPairsTree.ts` starts with available syntax metadata or a
  fast text-only initial tree, not synchronous whole-file syntax. Upstream
  also retains a token-aware tree and switches at background completion.
- Upstream `parser.ts` returns the cached node itself and seeks past it;
  `concat23Trees.ts` only makes mutable copies along a shared path. The Zig
  parser cloned the unchanged subtree recursively (`79abc903`), and its
  tokenizer scanned the whole document before allowing the parser to seek.
  The extra flattened/sorted bracket list also traversed the entire AST.
- Upstream JavaScript objects are garbage collected once unreachable. The
  Zig grammar retained states in its process-lifetime arena, even for
  closed documents, and used the page allocator for small short-lived
  allocations. Native lifetime and allocator choices require their own
  audit even when the tokenization algorithm has been ported correctly.

The corrected controller leaves tokenization to the model, the bracket
reader is lazy and seeks directly, and cached nodes are shared with explicit
reference counting. Only changed paths need new list nodes. The redundant
flattened bracket list is removed; bracket queries traverse the tree. The
TextMate adapter gives retained token states a document lifetime and uses a
pooled native allocator for shared grammars and Oniguruma results; scanner
captures are materialized only for the winning match.

## Native PTY measurements

`sample <pid> <seconds> 1` collected startup, idle, scroll, cursor and edit
stacks. The harness sent 60 wheel events, 50 cursor-down events and 40 single
character insertions, with the next input waiting for a synchronized frame.

| Measurement | Baseline | Patched |
| --- | ---: | ---: |
| First frame, app startup log | 18,694 ms | 663 ms |
| First frame, external wall clock | 18,733 ms | 2,928 ms |
| Scroll median | 6.58 ms | 6.83 ms |
| Scroll tail (maximum of 60) | 181.77 ms | 13.80 ms |
| Cursor median | 4.16 ms | 3.91 ms |
| Cursor tail (maximum of 50) | 36.95 ms | 23.90 ms |
| Edit median | 2,030.24 ms | 10.16 ms |
| Edit max | 2,389.08 ms | 29.07 ms |
| Physical footprint in startup sample | 1.0 GiB | 147.3 MiB |
| Peak physical footprint in edit sample | 2.0 GiB | 261.1 MiB |

The external startup includes process launch and macOS sampling overhead;
the app's internal timer starts from main entry. In the baseline, 3,546 of
3,567 main-thread startup samples occurred under forced tokenization. After
fixing it, the main thread waits for input for most of the sampled editing
phase. The remaining scroll and cursor median costs are similar; the tail
improved. The largest remaining sampled edit-side main-thread deadline was
sticky-scroll outline/indentation computation, including per-line allocation.
The threaded TextMate worker's results are also deserialized and copied on
the main thread while it runs. In the cursor sample, 609 of 2,180 main-thread
samples were in the tree's synchronous background-completion reparse. This
is the remaining single-tree difference described below. The other costs
require separate upstream comparisons.

## Allocation benchmark

The opt-in benchmark exercises the workbench's selected file and renders
frames to an in-memory writer. Its counter wraps the application's normal
thread-safe DebugAllocator (stack traces disabled), counts actual backing
allocator calls and successful growth requests, and tracks outstanding
requested bytes. It does not count every internal arena allocation, pooled
process grammar allocation or libonig's own malloc. The native physical
footprint above is a separate measurement of the whole process.

Run with:

```sh
zig build bench-open -Dbench-filter='benchmark: allocation profile' -Dbench-file=/path/to/large.ts
```

| Phase | Before: alloc calls | After: alloc calls | Before: requested bytes | After: requested bytes |
| --- | ---: | ---: | ---: | ---: |
| First frame | 593,622 | 3,248 | 207,641,195 | 66,096,793 |
| 10 scrolls | 7,446 | 7,458 | 5,677,321 | 5,700,685 |
| 10 cursor moves | 9,598 | 9,598 | 4,554,260 | 4,554,260 |
| 3 edits | 1,123,821 | 5,071 | 440,215,936 | 5,751,195 |

The in-process first-frame elapsed time decreased from 22,210 ms to 254 ms;
the three edits decreased from 6,815 ms to 20 ms. At disposal the tracked
live bytes returned to zero in both builds. The winner-only Oniguruma
capture optimization operates inside the separate grammar allocator and
therefore is not counted here.

## Remaining differences in the first optimization pass

The first patched Zig tree switched from one initial tree to a fresh token-aware
tree at background completion rather than retaining both trees and their
separate edit queues as upstream does. A full one-time reparse is therefore
still possible at that point. The [two-tree follow-up](#two-tree-follow-up)
below addresses this difference. Document-owned TextMate state arenas release on model
shutdown rather than collecting individual obsolete state stacks; similarly
AST parse regions release when their last node dies, not per node. These are
explicit remaining differences from upstream GC and the two-tree model.

The approximately 750 backing allocations per scroll and 960 per cursor move
are a separate optimization target; this change primarily removes the
whole-document work from startup and local edits. No desktop VS Code latency
measurement was made, so this is not evidence of parity with desktop VS Code.

## Validation

- `zig build` and `zig build check-workbench`: passed.
- Native `zig build test --summary all`: 48/48 build steps succeeded;
  4,239 tests passed and 61 skipped (3,858 editor, 322 UI, 59 TextMate
  tests passed). This includes the new bracket and TextMate regressions.
- The allocation benchmark passed; tracked live bytes returned to zero.
- All changed Zig files pass `zig fmt --check`; `git diff --check` passes.

## Two-tree follow-up

`BracketPairsTree` now owns `initialAstWithoutTokens`, `astWithTokens`, and
both edit queues. The model part forwards model events and the tree's change
event. Construction uses exactly the upstream three cases: no tokens (fast
initial tree), partial tokens (shared token-aware initial tree), or completed
with tokens (only the token-aware tree). Native root references share the
initial allocation and the incremental parser copies changed 2-3 tree paths.
Content edits enter both queues; token edits enter only the token-aware
queue. Queries flush both, and background completion drops the initial tree
and emits the change event without parsing. The unmatched-closing query
reads the token-aware tree once the last line has accurate tokens, even if
an initial tree is still present.

The same PTY harness and fixture were run again:

| Measurement | First patched (single tree) | Two trees |
| --- | ---: | ---: |
| First frame, app startup log | 663 ms | 649 ms |
| Scroll median | 6.83 ms | 7.97 ms |
| Scroll max | 13.80 ms | 232.61 ms |
| Cursor median | 3.91 ms | 4.72 ms |
| Cursor max | 23.90 ms | 15.83 ms |
| Edit median | 10.16 ms | 11.03 ms |
| Edit max | 29.07 ms | 18.97 ms |
| Peak physical footprint in edit sample | 261.1 MiB | 331.0 MiB |

The prior cursor sample had 609/2,180 main-thread samples inside the
synchronous background-completion reparse. The two-tree cursor sample had
only 1/2,396 samples in the completion handler, releasing the initial root,
not parsing. Incremental queue flushes appear in the scroll and cursor
samples. The first scroll after the idle interval can process accumulated
background token edits; as upstream does, the tree flushes lazily on queries.
This run demonstrates removal of the completion-time rebuild, not a general
latency improvement for scrolling. Retaining both trees also increases the
peak footprint during background parsing; parse regions are released at
last-node lifetime rather than individually. No editor-side eager polling
or non-upstream queue policy was added.

Regression coverage verifies initially shared roots, isolated token queues,
content updates in both queues, no initial-tree change event on token edits,
and deferred parsing when the completion event switches the tree. The focused
bracket test suite passed 143/143 tests.

The allocation benchmark on the two-tree build passed: first-frame allocations
3,249, ten scrolls 8,035, ten cursor moves 9,598, and three edits 5,206
(5,819,818 requested bytes). All 40,189 backing allocations were freed at
workbench disposal, with zero tracked live bytes. The initial root sharing
keeps startup allocation count essentially unchanged from the single-tree
patch; this benchmark is not a measurement of both background trees at their
peak.

The follow-up full `zig build test --summary all` succeeded (48/48 steps;
3,858 editor tests passed, 59 skipped; UI and standalone TextMate test runs
reused their successful cached results). `zig build`, `zig build
check-workbench`, `zig fmt --check`, and `git diff --check` also passed.
