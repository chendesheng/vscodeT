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

## 3. Remaining known divergences (not yet fixed)

Ordered by risk. Line numbers are approximate after the fixes above.

### High

- **Piece tree snapshot API is not usable.** `pieceTreeBase.zig`
  (`PieceTreeSnapshot`) stores `*const Piece` pointers into live tree nodes and
  returns the BOM as a separate chunk; `PieceTreeSnapshot` is private while
  `pieceTreeTextBuffer.createSnapshot` exposes it, and takes `[]u8` from a
  `[]const u8` BOM. `pieceTreeTextBuffer.equals` also returns `bool` for a
  `!bool` base call. These declarations are dead because Zig never analyzes
  them; they will fail to compile when wired. Port upstream's immutable
  snapshot (piece values + BOM prefix) and a `refAllDecls`-style compile test.
- **`intervalTree.computeMaxEnd` seeds from `maxEnd`, not `end`**
  (`intervalTree.zig`): the bound never shrinks. Queries stay correct but
  pruning degrades after edits. Change the seed to `node.end`.
- **Bracket colorization levels/filtering.** `bracketPairsImpl.zig` assigns
  levels over all pairs and filters by a per-token `isColorized` flag;
  upstream computes levels per pair when colorizing, returns `-1` for invalid
  closers, always emits unexpected closers, and treats
  `brackets ∪ colorizedBracketPairs` as the bracket table. This affects
  `editorBracketHighlighting*` colors and the colorized decoration provider.
- **Bracket matching falls back to the legacy scanner when colorization is
  off** (`useFallbackMatcher`). Upstream chooses the AST solely by
  `canBuildAST()`. Matching results therefore diverge with colorization
  disabled.

### Medium

- `pieceTreeBase`: `getValueLengthInRange` EOL compensation sign is inverted;
  `getLineCharCode`/`getCharCode` return one UTF-8 byte (dead byte-based APIs
  next to the codepoint ones); `nodeAt` returns `undefined` past the document;
  `getNearestChunk` returns a borrowed slice into mutable buffers; cache fields
  (`_searchCache`, `_lastVisitedLine`) are reset but never populated.
- `pieceTreeTextBufferBuilder`: `getFirstLineText` slices without clamping and
  keeps `\r`; RTL/unusual-terminator checks inspect only the new chunk;
  factory/create ownership allows a second `create` to alias the same chunks.
- `textModel`: font-decoration tracking/events and `filterFontDecorations`
  parameters are absent (font families/sizes are a terminal capability gap,
  but the API surface is upstream); `changeDecorations` accessor methods are
  private and unused; raw-content injected-text slices reference short-lived
  buffers; `onWillDispose` is never fired and there is no disposed guard;
  `_deltaDecorationsImpl` never normalizes options; `MultiModelEditStackElement`
  and `split()` are unreachable and would double-free if wired.
- `tokens`: non-stabilized visible-range refresh has no 50 ms scheduler;
  attached views are destroyed by `AttachedViews` even though the consumer
  owns them; `forceTokenizeRange` writes guessed end states and can mark
  stale tokens accurate; `onDidChangeFontTokens` plumbing is absent;
  textmate metadata language id is hard-coded (embedded languages are not
  attributed); the theme is matched per scope instead of via the engine;
  `tokenizeEncoded` has no 500 ms limit / `stoppedEarly` handling.
- `guidesTextModelPart`: horizontal guide segments are produced but the
  terminal view intentionally skips them (documented in
  `indentGuides.zig`); wrapping-column fields are carried but the terminal has
  no wrapping.
- `bracketPairsTree`: tokenizer/parser are a merged reimplementation without
  `concat23Trees`, the streaming tokenizers, two-tree mode or the upstream
  bracket matcher (case/world-boundary rules); `SmallImmutableSet` silently
  drops ids ≥ 256; `getBracketPairsInRange`/matching queries use flat sorted
  lists instead of AST traversal (O(document) per query).
- `language configuration changes` do not invalidate bracket pairs or
  tokenization (`handleLanguageConfigurationServiceChange` has no producer),
  so replacing a configuration leaves an existing AST stale.
- `editStack`: `redo` silently ignores URI-backed elements; `split()` copies
  heap-owning elements.

### Low / process

- Missing required `// Port of ...` headers in several files
  (`bracketPairsTree.zig` and its merged modules, `beforeEditPositionMapper`,
  `combineTextEditInfos`, `nodeReader`, `colorizedBracketPairsDecorationProvider`,
  the tokens files, and most misc files). The merged 8-file bracket tree needs
  a header naming all upstream modules and stating the merge.
- Missing upstream tests: `bracketPairColorizer/{beforeEditPositionMapper,
  brackets, combineTextEditInfos, concat23Trees, getBracketPairsInRange,
  length, smallImmutableSet, tokenizer}.test.ts`; `pieceTreeTextBuffer.test.ts`
  (≈2.1k lines, CRLF/random/snapshot suites); `annotations.test.ts`;
  `textModelTokens.test.ts`; `editableTextModel*.test.ts`; `model*.test.ts`;
  `textModelSearch.test.ts`. These are the suites that would have caught the
  fixed bugs and the remaining ones.
- Dead/malformed declarations that only compile because they are never
  analyzed: `rbTreeBase.TreeNode.iterate`, `pieceTreeTextBuffer.equals`,
  `createSnapshot`, `getCharCode` return type, `intervalTree` font bit,
  `model.zig` `initModelDecorationOptionsDefaults`.

## 4. Verification

Every fix above was validated with:

```sh
zig build
zig build test --summary all
zig fmt --check <changed files>
git diff --check
```

The full suite currently passes (3019+ tests, 19 skipped; the only observed
failure was the unrelated pre-existing quick-access `rg` test, which passes on
re-run).

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
