# Audit: `src/vs/editor/common/model` vs VS Code 1.147.0

Upstream: `vscode/` pinned at `e31c2e52` (1.147.0).
Scope: all 32 Zig files in `src/vs/editor/common/model` compared file-by-file
against `vscode/src/vs/editor/common/model`, including the upstream files that
the port merges or does not have.

Method: read both sides of every file; compare public API, event ordering,
ownership/lifetimes and edge cases; reproduce suspected defects with focused
tests before fixing them. Four parallel read-only audits covered the piece
tree, `textModel`/stacks/interval tree, tokenization and the bracket-pair
model part; their findings were re-checked against the source before any edit.

---

## 0. UTF-16 vs UTF-8

Upstream works in UTF-16 code units: `Position.column`, `TextLength`, string
lengths, search offsets and token indices. This port uses UTF-8 bytes
throughout the editor (see `AGENTS.md` and `core-audit.md` §0). The audit
therefore treats **byte columns/offsets as the contract**, and only reports
places where the adaptation is internally wrong (a byte count used where a
code-point boundary matters, a surrogate/`\r\n` assumption, a column outside
`1..lineLength+1`).

The one deliberate UTF-16 boundary is TextMate tokenization: the standalone
`textmate` package and `vscode-textmate` use UTF-16 token indices;
`tokens/textMateTokenizer.zig` converts token starts to byte offsets with
`Utf16Cursor`. That conversion was audited and found consistent (start
offsets are the only indices carried; end offsets are derived from the next
start by `LineTokens.convertToEndOffset`, with the byte line length).

## 1. Inventory

| Upstream | Port | Status |
|---|---|---|
| `fixedArray.ts` | `fixedArray.zig` | audited, fixed clamp bug |
| `utils.ts` | `utils.zig` | faithful |
| `textModelPart.ts` | `textModelPart.zig` | faithful (error instead of throw) |
| `textModelText.ts` | `textModelText.zig` | faithful |
| `decorationProvider.zig` | `decorationProvider.zig` | faithful interface adaptation |
| `indentationGuesser.ts` | `indentationGuesser.zig` | audited, fixed 2-vs-4 rule |
| `prefixSumComputer.ts` | `prefixSumComputer.zig` | audited, fixed index trim |
| `mirrorTextModel.ts` | `mirrorTextModel.zig` | faithful; ownership is explicit |
| `textModelStringEdit.ts` | `textModelStringEdit.zig` | faithful |
| `textModelSearch.ts` | `textModelSearch.zig` | audited, fixed iterator/multiline/groups |
| `textModel.ts` | `textModel.zig` | audited, fixed several high/medium issues |
| `editStack.ts` | `editStack.zig` | single-model path faithful; multi-model is unreachable debt |
| `intervalTree.ts` | `intervalTree.zig` | audited; `maxEnd` seeding and font bit remain |
| `guidesTextModelPart.ts` | `guidesTextModelPart.zig` | now ports active guide, offSide, bracket guides and class names |
| `textModelTokens.ts` | `textModelTokens.zig` | audited, fixed arena lifetime |
| `pieceTreeTextBuffer/pieceTreeBase.ts` | `pieceTreeBase.zig` | audited, fixed CR/EOL/precision issues |
| `pieceTreeTextBuffer/pieceTreeTextBuffer.ts` | `pieceTreeTextBuffer.zig` | audited, fixed large-edit collapse |
| `pieceTreeTextBuffer/pieceTreeTextBufferBuilder.ts` | `pieceTreeTextBufferBuilder.zig` | audited, fixed `_finish` copy |
| `pieceTreeTextBuffer/rbTreeBase.ts` | `rbTreeBase.zig` | algorithmically faithful; dead malformed helpers remain |
| `bracketPairsTextModelPart/bracketPairsImpl.ts` | `bracketPairsImpl.zig` | partial; matching/colorization gaps remain |
| `bracketPairsTree/beforeEditPositionMapper.ts` | `.../beforeEditPositionMapper.zig` | faithful |
| `bracketPairsTree/combineTextEditInfos.ts` | `.../combineTextEditInfos.zig` | audited, fixed copy-all sentinel |
| `bracketPairsTree/nodeReader.ts` | `.../nodeReader.zig` | faithful; monotonic guard collapsed |
| `bracketPairsTree/bracketPairsTree.ts` + `ast.ts` + `parser.ts` + `tokenizer.ts` + `length.ts` + `brackets.ts` + `smallImmutableSet.ts` + `concat23Trees.ts` | merged into `bracketPairsTree/bracketPairsTree.zig` | behavioral gaps; structure does not mirror upstream |
| `bracketPairsTextModelPart/colorizedBracketPairsDecorationProvider.ts` | `.../colorizedBracketPairsDecorationProvider.zig` | medium; unstable ids, dirty short-circuit |
| `bracketPairsTextModelPart/fixBrackets.ts` | `.../fixBrackets.zig` | logic faithful; debug print removed |
| `tokens/abstractSyntaxTokenBackend.ts` | `tokens/abstractSyntaxTokenBackend.zig` | partial; scheduler/font view ownership gaps |
| `tokens/annotations.ts` | `tokens/annotations.zig` | used subset faithful; serialization absent |
| `tokens/tokenizationTextModelPart.ts` | `tokens/tokenizationTextModelPart.zig` | partial; font events and bracket notification order differ |
| `tokens/tokenizerSyntaxTokenBackend.ts` | `tokens/tokenizerSyntaxTokenBackend.zig` | partial; view handler copy fixed |
| `textMateTokenizer.ts`-backed pipeline | `tokens/textMateTokenizer.zig` | adapter; language ids/theme/time limit differ |
| `tokens/tokenizationFontDecorationsProvider.ts` | — | not ported: terminal has one font/size/line height; bold/italic from `TokenMetadata` still work. Documented gap |
| `tokens/treeSitter/*` | — | not ported: requires a wasm parser + grammars and is never the default backend |
| `tokens/test/browser/tokenizationUndo.test.zig` | project-specific regression test | no upstream counterpart |
| 8 upstream test files under `test/common/model/` | only `astTests`, `bracketPairsTests` | test-tree gap (see §4) |

## 2. Fixed in this audit

Small commits, each with a regression test:

1. `592713b` guides: `getActiveIndentGuide`, folding-rule `offSide`, upstream
   indent-guide test suite from `textModelWithTokens.test.ts`.
2. `e940c27` bracket pairs: `AstNode.computeMinIndentation` (text/list/pair,
   list cache), `BracketPairWithMinIndentationInfo`,
   `getBracketPairsInRangeWithMinIndentation`, `getLinesBracketGuides`.
3. `6655043` `indentGuides`: upstream `getGuidesByLine` merge (indent + active
   scope + bracket guides, default active suppression by bracket guides) moved
   into the view part; TUI only maps class names to cell colors.
4. `49e11c2` three data bugs: `FixedArray.replace` clamps like JS `slice`;
   `lengthOfString` treats CRLF as one break; `UNUSUAL_LINE_TERMINATORS` is
   the LS/PS regex source again (the removed method also type-checks).
5. `1a2d00c` `validateRange` only expands endpoints inside a code point;
   `_onAfterEOLChange` uses a signed delta; no decoration-list leak there.
6. `f5e0bc7` search: non-overlapping regex iteration (JS `/g` semantics),
   multiline find-next starts at the cursor column, optional capture groups
   are empty instead of `unreachable`, non-ASCII uses the regex path,
   multiline match lists/counters are freed.
7. `f991ebf` piece tree: dangling-CR `getLinesContent` no longer frees a
   live line; `fixCRLF` end column; `normalizeEOL` resets
   `_lastChangeBufferPos`; 1000+ operation collapse keeps text and ownership;
   large inserts split at the CRLF/UTF-8 boundary; builder `_finish` mutates
   the stored chunk.
8. `800e9c5` bracket pairs: explicit copy-all sentinel in
   `combineTextEditInfos`; stable bracket ids owned by the model part.
9. `523364a` tokens: token arrays use a scratch arena reset per line; only
   end states are cloned into the long-lived state arena (editor and worker).
   `nullTokenizeEncoded` keeps the encoded language id.
10. `fa7ca24` debug print removed from `fixBracketsInLine`; indentation 2/3
    rule; constant-time prefix-sum trim; `getOffsetAt` clamping;
    `getLinesDecorations` end-line clamp; decoration-effect flags OR;
    `pushEOL` deferred event order; attached-view handler mutated in place;
    left word definition in `getWordAtPosition`.
11. `80477f0` interval-tree `maxEnd` shrinks with the node end; EOL-length
    compensation uses `desired - actual`; URI-backed redo reports an error.
12. `1823d22` language-configuration changes invalidate the bracket tree
    (LanguageService event -> TextModel -> bracket/tokenization parts);
    bracket matching always uses the AST when it can be built, regardless of
    colorization.
13. `acde702` bracket colorization levels: the bracket table is
    `brackets ∪ colorizedBracketPairs`; closing tokens carry which openings
    they colorize; `getBracketsInRange` walks the AST like upstream
    `collectBrackets` (levels only advance for colorized pairs, unclosed pairs
    are colorized, unexpected closers are emitted at level -1); decoration ids
    are stable.
14. `927d4e3` piece-tree snapshots are immutable value copies, prepend the BOM
    to the first piece, expose public read/deinit, and the buffer/TextModel
    wrappers type-check.
15. `88e2cac` forced tokenization only records end states from a known-valid
    start; TextMate tokenization has the 500 ms limit and keeps the input
    state on `stoppedEarly`; callback registration is idempotent.
16. `ed781d6` provenance headers for every model file.
17. `619c81c` piece-tree substring/substr clamp and swap like JS.
18. `9c3f193` builder first-line clamping/CR stripping, combined RTL checks,
    single-use factory, unconsumed-chunk cleanup.
19. `a4f3e48` AST-based findPrev/findNext/findEnclosing bracket navigation
    (invalid closers skipped, strict containment) and onDidChange on
    token-aware trees.
20. `45d3461` dead malformed declarations removed, `onWillDispose` fired,
    decoration change accessor made public.
21. `14959e3` raw content events own injected-text copies; injected-text
    event releases per-line arrays.
22. `746dd42` find-next returns null after the two line-by-line scans; the
    middle-line loop stops at the result limit.
23. `7b01abd` decoration options are normalized (stickiness/zIndex/lineHeight
    clamp) at insertion and option changes.
24. `cfe655d` bracket matching is case-insensitive with upstream `\b`
    boundaries and token-end clamping; ported the randomized
    combineTextEditInfos test (50 seeds).
25. `38004d8` ported the length and smallImmutableSet test suites.
26. `9ad3231` ported the getBracketPairsInRange Basic cases with an
    annotated-position helper.
27. `3830ce3` ported the piece-tree CRLF cases and a 500-step seeded random
    CR/LF insert/delete test.
28. `092ffa3` attached views follow upstream ownership: `detachView` leaves
    the allocation to the caller.
29. `e06d22f` bracket-id set overflow is a typed error instead of a silent
    dropped bit.
30. `cb97bde` piece-tree `nodeAt` returns null past the document; char/chunk
    accessors and insert/delete are safe at invalid offsets.
31. `3f417c6` removed the non-upstream inside-edit mapper branch and ported
    the upstream mapper Single-Line/Multi-Line-Replace cases; added
    `lengthToObj`.
32. `820b8ab` search line-by-line scopes clamp/swap like JS substring.
33. `f40eece` attached-view handlers own their visible-line ranges and are
    deinitialized on view removal/backend teardown.

## 3. Remaining known divergences (not yet fixed)

Ordered by risk. Line numbers are approximate after the fixes above.

### High

- **Bracket-pair core is a merged reimplementation.** `bracketPairsTree.zig`
  carries eight upstream modules in one file and has no `concat23Trees`,
  streaming `TextBufferTokenizer`/`FastTokenizer`, two-tree mode
  (`initialAstWithoutTokens`/`astWithTokens`) or upstream bracket matcher
  (case folding, word boundaries, token clamping). Queries use flat sorted
  lists for pair/matching APIs, so many operations remain O(document) and
  incremental parses deep-clone cached nodes. See the audit findings F9/F15
  for concrete differences and the staged split plan.
- **Piece-tree public APIs still have byte/UTF-16 and safety gaps.**
  `getLineCharCode`/`getCharCode` are byte accessors next to the codepoint
  helpers; `getNearestChunk` returns a borrowed slice into mutable buffers;
  some error paths still leak partially built results.
- **TextMate metadata loses embedded languages and engine theme semantics.**
  `textMateTokenizer.zig` hard-codes `languageId = 0` and matches theme rules
  per scope instead of through the engine's full scope path; embedded
  languages (HTML `<script>`, markdown fences) are not attributed. Font-token
  metadata is discarded. This is partly a documented single-language terminal
  limitation, but the language-id path should still be ported.
- **Font-decoration API surface is absent.** `onDidChangeFont*`,
  `tokenizationFontDecorationsProvider.ts`, `TextModel.getFontDecorationsInRange`
  and the `filterFontDecorations` parameters do not exist. A terminal has one
  font/size/line height, so the provider itself is a documented capability
  gap; the cheap model flags/parameters should be ported or their absence
  documented in `README.md` (currently only in file headers).

### Medium

- `pieceTreeTextBufferBuilder`: the factory is deliberately single-use; a
  second `create` after the first would alias the same chunks, matching the
  documented terminal host contract. First-line clamping and combined RTL/
  unusual-terminator checks are fixed.
- `textModel`: there is no disposed guard on public members;
  `MultiModelEditStackElement` and `split()` are unreachable and would
  double-free if wired; class-name cleaning/tooltip encoding in decoration
  normalization remain unported.
- `tokens`: non-stabilized visible-range refresh has no 50 ms scheduler (the
  TUI drives refresh); `tokenizeHeuristically`/`forceTokenizeRange` callers
  still have scheduler-specific differences; `onDidChangeFontTokens` is
  absent.
- `bracketPairsTree`: `SmallImmutableSet` is still inline (ids 0..255) and
  reports `BracketSetOverflow` rather than implementing upstream's
  `additionalItems`; `colorizedBracketPairsDecorationProvider` returns no
  decorations while dirty (documented terminal adaptation).
- `editStack`: `split()` copies heap-owning elements; `heapSize` contains a
  JS-specific overhead constant; the multi-model/delegate path is unreachable.
- `annotations`: serialization (`ISerializedAnnotation`, `serialize`,
  `deserialize`) is absent; the port uses its own worker protocol.
- `textModelSearch`: line-by-line ranges now clamp like JS substring; the
  remaining difference is the buffer-level path returning empty for invalid
  node positions (same as upstream) while the line path clamps.
- `guidesTextModelPart`: horizontal guide segments are produced but the
  terminal view intentionally skips them; wrapping columns are unused.

### Low / process

- Missing upstream tests remain the main safety net:
  full `beforeEditPositionMapper.test.ts` (three cases ported),
  `brackets`, `concat23Trees`, full `getBracketPairsInRange`,
  `tokenizer`; most of `pieceTreeTextBuffer.test.ts` (CRLF/random and
  snapshot suites partly ported); `annotations.test.ts`,
  `textModelTokens.test.ts`, `editableTextModel*.test.ts`, `model*.test.ts`,
  `textModelSearch.test.ts`.
- Dead/malformed declarations that only compile because they are never
  analyzed: `rbTreeBase.TreeNode.iterate`, `intervalTree` font bit,
  `model.zig` `initModelDecorationOptionsDefaults`.
- The terminal UI's guide painting skips horizontal segments and wrapping
  columns; these are documented in `indentGuides.zig`.

## 4. Verification

Every fix above was validated with:

```sh
zig build
zig build test --summary all
zig fmt --check <changed files>
git diff --check
```

The full suite currently passes (3052 tests, 19 skipped; the only observed
failure was the unrelated pre-existing quick-access file-search worker hang,
which passes on re-run).

## 5. Next steps

1. Port the upstream model test suites listed above; they are the safety net
   for the remaining bracket-pair/piece-tree behavior.
2. Fix the piece-tree snapshot API and the interval-tree `maxEnd` seed.
3. Split `bracketPairsTree.zig` into the upstream modules and restore
   `concat23Trees`, streaming tokenizers and AST query helpers.
4. Port bracket colorization levels and the AST-only matching choice.
5. Document the deliberate unported pieces (tree-sitter backend, font
   decorations, horizontal guide painting) in `README.md` and in the file
   headers, with the exact terminal limitation.
