# Audit: `src/vs/editor/common/core` vs VS Code 1.147.0

Upstream: `vscode/` pinned at `e31c2e52` (1.147.0).
Scope: all 35 Zig files in `src/vs/editor/common/core` (the user-supplied tree), compared
file-by-file against `vscode/src/vs/editor/common/core`.

Method: read both sides, then additionally force semantic analysis of every concrete
(unreferenced) declaration with a temporary recursive `refAllDecls` harness. Anything
marked **[latent]** below compiles today only because Zig never analyzes it, and fails
as soon as a caller uses it.

---

## 0. Fundamental divergence: UTF-16 code units vs UTF-8 bytes

This is the deepest difference from upstream and it is not local to any one file.
JavaScript strings, `Position.column`, `Range` columns, `TextLength`, string
lengths and `StringEdit`/`TextEdit` offsets are all UTF-16 code-unit counts
upstream. This port stores UTF-8 and uses UTF-8 **byte** columns/offsets
throughout the editor (as documented in `AGENTS.md`).

Consequences, all observable on non-ASCII text:

* `TextLength.ofText("😀").columnCount` is 4 here and 2 upstream.
* `TextModel.getLineLength` / `Position.column` are byte counts; every
  `lineContent[column - 1 ..]` is a byte slice.
* `StringEdit`, `TextEdit`, `LineEdit`, `OffsetRange` and `TextChange`
  positions are byte offsets.
* `CursorColumns.visibleColumnFromColumn` receives byte columns while still
  computing grapheme-based visible columns; upstream receives UTF-16 columns.
* `wordHelper`, `eolCounter` and indentation lengths are byte lengths.
* Core contains no UTF-8↔UTF-16 conversion at all; `stringBuilder` is UTF-8-only.
  The sole UTF-16 boundary is the TextMate tokenizer adapter, which keeps UTF-16
  token indices by design and converts token starts to byte offsets.

This is a contract-level adaptation, not a bug that can be fixed
file-by-file: matching upstream's numeric columns would require converting the
whole editor position/offset model to UTF-16 code units. Because of it,
`TextChange` serialization cannot be byte-compatible with upstream (upstream
writes UTF-16 code units and UTF-16-unit positions); the port writes UTF-8 byte
lengths and byte positions, which is internally consistent. The audit entries
below that mention serialization should be read with this in mind.

---

## 0.1 Summary

| Category | Finding |
|---|---|
| Upstream files not ported | 0 (`editorColorRegistry.ts` is ported as ID constants; registration wiring is documented) |
| Extra port-side files | 1 (`ranges/rangePriorityQueue.zig`) |
| Closest to faithful | `editOperation`, `rgba`, `columnRange`, `rangeSingleLine` |
| API surface | Omitted in most files; only a handful are 1:1 |
| Uncompilable dead code | Multiple sites in 6 files (`selection`, `offsetRange`, `lineRange`, `abstractText`, `positionToOffsetImpl`, `wordCharacterClassifier`) |
| Behavioral divergences | `indentation`, `cursorColumns`, `wordHelper` (EOL), `StringEdit.parse`, `TextEdit.format`, `LineEdit.humanReadablePatch`, `Range.equalsRange`, `LineRange.toInclusiveRange` |
| Incompatible serialization formats | `TextChange` (UTF-8 bytes vs upstream UTF-16 units — see §0), `LineEdit` |

The port is generally a close structural copy for the *edits* tree, but it systematically
(a) drops upstream API surface, (b) replaces borrowed strings with owned allocations
without a consistent ownership contract, and (c) keeps dead code that was never type-checked.
`AbstractText` and the two position/offset transformers are the largest structural rewrites.

Suggested fix order: (1) `LineRange.toInclusiveRange`/`getRange` signatures, because the
diff layer currently cannot compile; (2) the output/semantics bugs (`StringEdit.parse`,
`TextEdit.format`, `indentation`, `cursorColumns`); (3) the dead helpers either get
deleted or repaired + tested; (4) restore the omitted APIs that consumers need
(`AnnotatedStringEdit`, `wordHelper` config, `OffsetRange.withMargin`, rect helpers,
`TextLength.sum`); (5) decide ownership for each owned-returning API.

---

## 1. Behavioral differences (output or semantics)

These are ordered by likely impact. Several are in helpers that currently have no
production caller (`StringEdit.parse`, `TextEdit.format`, `humanReadablePatch`); they are
still listed because they are public API and their inline tests do not cover the
problematic cases.

### `misc/indentation.zig` — leading `\r`/`\n` are treated as indentation
`normalizeIndentation` scans for the first non-space/tab/`\r`/`\n` byte
(`indentation.zig:29-35`), while upstream uses
`strings.firstNonWhitespaceIndex`, which only skips space and tab
(`strings.ts:284-292`).
`normalizeIndentation("\rfoo")` therefore normalizes `"\r"` into spaces/tabs and
changes the text, whereas upstream preserves the CR and normalizes nothing.
Leading `\r\n` in a multi-line insertion is collapsed this way.

### `cursorColumns.zig` — wrong full-width/emoji ranges, no grapheme iterator
Upstream imports `strings.isFullWidthCharacter` / `strings.isEmojiImprecise` and walks
`GraphemeIterator`; this port reimplements the predicates locally
(`cursorColumns.zig:132-160`) and walks UTF-8 code points (`decodeAt`).
* `isFullWidthCharacter` does **not** match upstream: upstream is
  `0x2E80-0xD7AF, 0xF900-0xFAFF, 0xFF01-0xFF5E, 0xFFE0-0xFFE6`
  (`strings.ts:757-764`); the port adds `0x1100-0x115F`, `0xFE10-0xFE19`,
  `0xFE30-0xFE6F`, `0xFF00`, `0xFF5F-0xFF60`, `0x20000-0x3FFFD` and several emoji blocks.
  The repo's own `src/vs/base/common/strings.zig:156` already has the correct upstream
  ranges, so this is a duplicated, divergent copy. (`isEmojiImprecise` itself was never
  ported to `strings.zig`, so the local copy is currently the only implementation.)
* `isEmojiImprecise` upstream is a specific list (`0x1F1E6-0x1F1FF`, `0x2600-0x27BF`,
  `0x2B00` partial, `0x1F300+` specific ranges, etc., `strings.ts:769-777`);
  the port uses `0x1F000-0x1FAFF | 0x2600-0x27BF | 0x2B00-0x2BFF`.
  Visible columns therefore differ for flags (U+1F1E6..), Dingbats/Misc Symbols,
  and U+1F000..U+1F1E5.
* Upstream `visibleColumnFromColumn`/`columnFromVisibleColumn` count **graphemes**
  (`GraphemeIterator`); the port counts code points. Emoji ZWJ sequences and combining
  marks produce different visible columns and different `columnFromVisibleColumn`
  results (one grapheme = 1 column upstream, N columns here).
* Extra API not upstream: `columnFromVisibleColumnFrom` (`cursorColumns.zig:52`).

### `edits/textEdit.zig` — `format()` output differs
Upstream `TextEdit.toString(text)` (`textEdit.ts:582-643`) truncates and ellipsizes
both sides. The port (`textEdit.zig:569-635`):
* truncates `after_text` to 10 bytes **without appending `...`** (`:597`), whereas
  upstream does `substring(0, maxLength) + '...'`;
* in the insertion branch (`original_text.len == 0`) writes `replacement.text` raw
  (`:602`) instead of truncating it to `maxLength` with an ellipsis as upstream does.
So `TextEdit.format` is not output-compatible for text longer than 10 chars. It has no
production caller today.

### `edits/lineEdit.zig` — `humanReadablePatch` output differs
* Each line is written with a trailing `'\n'` (`lineEdit.zig:484`), so the result ends
  with a newline; upstream `join('\n')` has no trailing newline (`lineEdit.ts:192`).
* (The context loop itself matches upstream: the `startLineNumber - 2` value is
  clamped with `max(1, ...)` before use, so line-1 edits do not produce warning
  lines in either implementation.) `humanReadablePatch` has no production caller
  today.

### `edits/stringEdit.zig` — `parse` composes edits instead of collecting them
Upstream `StringEdit.parse` builds a replacement list and constructs one
simultaneous edit (`stringEdit.ts:294-310`). The port feeds each parsed replacement
through `StringEdit.compose`, which treats the second edit as applied *after* the first
and therefore shifts later ranges by earlier deltas (`stringEdit.zig:247-310`).
Measured result for the port's own test string
`[[2, 12) -> "fgh", [14, 20) -> "qrst", [22, 22) -> "de\n"]`:
`[2,12)`, **`[21,27)`**, **`[31,31)`** instead of upstream `[2,12)`, `[14,20)`, `[22,22)`.
The inline test only asserts the first range and the last text, so it does not catch
this. `parse` currently has no production caller.

### `wordHelper.zig` — a word at the end of a line is not found
Upstream allows the query position to equal the end of the text: for `"abc"` with
`column = 4`, `pos = 3`, and the match `[0,3)` satisfies `lastIndex >= pos`, so the
word `"abc"` is returned (`wordHelper.ts:132-163`). The port returns early on
`pos >= text.len` (`wordHelper.zig:65`) before scanning, so
`getWordAtText(4, null, "abc", 0)` is `null`. This is reachable through
`TokenizationTextModelPart.getWordAtPosition` for a cursor at end-of-line
(`position.column == lineLength + 1`), where upstream returns the last word.

### `range.zig` — `equalsRange(null, null)`
Upstream returns `true` when both arguments are nullish (`range.ts:269-283`);
the port returns `false` for either null (`range.zig:147-153`).

### `ranges/lineRange.zig` — `toInclusiveRange` / `toExclusiveRange` are the wrong type
Upstream returns `Range` values (`lineRange.ts:178-190`):
`toInclusiveRange()` → `(startLine,1)..(endExclusive-1,MAX_SAFE_INTEGER)`,
`toExclusiveRange()` → `(startLine,1)..(endExclusive,1)`.
The port returns `?LineRange` / `LineRange` (`lineRange.zig:163-173`). This is not just
cosmetic: `src/vs/editor/common/diff/rangeMapping.zig:110` passes the result to
`RangeMapping.init(Range, Range)` and therefore **does not compile** when reached
(`expected type Range, found LineRange`).

---

## 2. Broken code paths that today are never exercised

Zig analyzes function bodies lazily, so all of the following compile as long as no one
calls them. `range.zig:174` is not a compile error, but a silently dangling return.

| File:line | Problem |
|---|---|
| `selection.zig:80,123` | `setEndPosition` / `setSelectionStart` are declared `void` but return a `Selection` value. |
| `selection.zig:59-62` | `toString` returns `error{NoSpaceLeft}![]u8` where `[]const u8` is declared (missing `try`). |
| `range.zig:174-177` | `toString` formats into a stack-local `buf` and returns a slice into it → dangling pointer after return (and fails with `NoSpaceLeft` beyond 1024 bytes). |
| `ranges/offsetRange.zig:233,237,257,268,271` | `OffsetRangeSet` uses `self.sortedRanges.len` on a `std.array_list.Managed` (should be `.items.len`). `addRange`, `toString`, `intersectsStrict`, `length` are all uncompilable. |
| `ranges/offsetRange.zig:254` | `OffsetRangeSet.toString` calls `range.toString(allocator)`, but `OffsetRange.toString` takes `*Io.Writer`. |
| `ranges/lineRange.zig:54-63` | `joinMany` returns `[_]LineRange{}` without `&`, and passes `[]LineRange` to `LineRangeSet.init(ArrayList(LineRange))`. Never compiled. |
| `text/abstractText.zig:108-110` | `getValueOfOffsetRange` calls `self.getTransformer().getRange(...)` on the `!*PositionOffsetTransformer` error union (missing `try`/unwrap). |
| `text/positionToOffsetImpl.zig:196-198` | `getTextLength` calls `self.getRange(...)`, but the concrete `PositionOffsetTransformer` has no `getRange`/`getOffsetRange` (only `asBase()` does). |
| `wordCharacterClassifier.zig:39-41` | `set` ignores the `!void` returned by `CharacterClassifier.set` (“error union is ignored”). |
| `text/abstractText.zig:271-278` | `getLineAt` on a string-backed text passes `maxInt(usize)` as the column; `offsetAt` computes `offset + column - 1` and panics with integer overflow for any line after the first. |
| `diff/rangeMapping.zig:110` | Consumer breakage caused by `LineRange.toInclusiveRange`’s wrong return type (see §1). |

`OffsetRangeSet` also has no `deinit` (leaks its list), and `getRanges()` returns the
internal slice.

---

## 3. File-by-file

Status key: **faithful** = no behavioral difference; **API** = omitted/extended surface;
**behavior** = observable difference; **broken** = fails when called; **rewrite** = structure
does not follow upstream.

| File | Status |
|---|---|
| `2d/dimension.zig` | API (extra methods over an interface) |
| `2d/point.zig` | API missing `toString`, `mapComponents` |
| `2d/rect.zig` | API missing ~20 methods; `union` renamed |
| `2d/size.zig` | API missing `deltaX/deltaY/toString/mapComponents` |
| `characterClassifier.zig` | API/typing (generic, no `toUint8`) |
| `cursorColumns.zig` | behavior (full-width/emoji ranges, no graphemes) |
| `editOperation.zig` | faithful |
| `position.zig` | API missing half of the class |
| `range.zig` | API + behavior (`equalsRange`, `fromPositions`) + broken `toString` |
| `selection.zig` | API + broken setters/`toString` |
| `stringBuilder.zig` | API/encoding (UTF-8 builder, missing decoders) |
| `textChange.zig` | behavior (labels, wire format) + leaks |
| `wordCharacterClassifier.zig` | missing Intl segmenter, cache/LRU, byte separators, broken `set` |
| `wordHelper.zig` | behavior (EOL), missing config/time budget |
| `edits/edit.zig` | minor (aliases, equality semantics) |
| `edits/arrayEdit.zig` | API shape; invalid-input panic |
| `edits/lengthEdit.zig` | API shape; `toString` punctuation |
| `edits/lineEdit.zig` | behavior (patch text), wire format, leaks |
| `edits/stringEdit.zig` | missing annotated layer; `parse` behavior |
| `edits/textEdit.zig` | behavior (`format`) |
| `misc/eolCounter.zig` | API shape; byte lengths; extra helpers |
| `misc/indentation.zig` | behavior (CR/LF) |
| `misc/rgba.zig` | faithful |
| `misc/textModelDefaults.zig` | API (two extra fields) |
| `ranges/columnRange.zig` | faithful (error vs throw) |
| `ranges/lineRange.zig` | behavior (`toInclusiveRange`/`toExclusiveRange`), broken `joinMany`, ownership |
| `ranges/offsetRange.zig` | missing `withMargin`; broken `OffsetRangeSet` |
| `ranges/rangeMapping.zig` | API/perf/ownership |
| `ranges/rangePriorityQueue.zig` | relocated; faithful implementation |
| `ranges/rangeSingleLine.zig` | faithful |
| `text/abstractText.zig` | rewrite; broken `getValueOfOffsetRange`; ownership |
| `text/getPositionOffsetTransformerFromTextModel.zig` | API (extra methods) |
| `text/positionToOffset.zig` | duplicate eager transformer (upstream is a re-export file) |
| `text/positionToOffsetImpl.zig` | broken `getTextLength`; base/`asBase` shape |
| `text/textLength.zig` | API missing `sum`, `toString` |


### `2d/dimension.zig`
* Upstream `dimension.ts` is only an interface `{width,height}`; the port adds
  `init`, `equals`, `toString` (invented API, harmless).
* No behavioral port to compare.

### `2d/point.zig`
* Missing: `toString()`, `mapComponents()`, static-vs-instance shape (fine).
* `equals` is static-shaped; upstream also static. `withThreshold` is inlined (same math).

### `2d/rect.zig` (87 vs 273 lines)
Missing upstream methods: `hull`, all three `withMargin` overloads,
`intersectVertical`, `intersectHorizontal`, `toString`, `moveToBeContainedIn`,
`withWidth`, `withHeight`, `withTop`, `withLeft`, `translateX`, `translateY`,
`deltaRight`, `deltaTop`, `deltaLeft`, `deltaBottom`, `getLeftTop/RightTop/LeftBottom/RightBottom`,
`toStyles`, `withHorizontalRange`, `withVerticalRange`.
Also renamed: upstream `union` → port `unionRect`.
`init` returns `error.InvalidRect` instead of throwing `BugIndicatingError`;
`intersect` swallows the error with `catch null` (unreachable in practice).
`getHorizontalRange`/`getVerticalRange` truncate float edges with `@intFromFloat`
(upstream keeps numbers; here `OffsetRange` is `usize`, so this is an adaptation).

### `2d/size.zig`
* Missing: `deltaX`, `deltaY`, `toString`, `mapComponents`.
* Otherwise matches.

### `characterClassifier.zig`
* Port generalizes `CharacterClassifier<T>` over any value type (upstream `T extends number`
  backed by `Uint8Array` + `toUint8`). No truncation, no numeric coercion.
* `get` returns the stored value instead of upstream’s
  `map.get(...) || default` fallback. Observable only if a stored value is falsy but not
  the default; not reachable with the two enums used here.
* `CharacterSet.add` returns `!void` (upstream `void`) because a non-ASCII `Map` insert can
  allocate.

### `cursorColumns.zig`
See §1. In addition: `nextVisibleColumn` is public (upstream private
`_nextVisibleColumn`), and the port uses `column -| 1`/byte decoding rather than
`substring` + grapheme walking. `toStatusbarColumn` (code points) is otherwise equivalent.

### `editOperation.zig`
Faithful (`insert` sets `forceMoveMarkers`, `delete` null text, `replace`,
`replaceMove`). No functional differences.

### `position.zig`
* Missing: `with`, `clone`, `toString`, `lift`, `isIPosition`, static `equals`
  (with null handling), static `isBefore`/`isBeforeOrEqual`, `toJSON`.
* `delta(lineDelta: ?isize, columnDelta)` requires the column delta and uses an optional
  line delta; upstream defaults both to 0.
* Extra `create` duplicates `init`.
* `compare` returns `isize` (sign-compatible); upstream subtracts clamped ints.

### `range.zig` (495 vs 520 lines)
Missing:
* static `isEmpty`, static `containsPosition`, `strictContainsPosition`,
  static `containsRange`, static `strictContainsRange`;
* `collapseToStart` (only `collapseToEnd` exists);
* `lift`, `isIRange`, `toJSON`;
* null-aware `compareRangesUsingStarts` (upstream orders `null` before values);
* instance `plusRange` shape (static two-arg form is callable as `a.plusRange(&b)`).
Divergent:
* `equalsRange` both-null → `false` (§1).
* Free `fromPositions(start, ?end)` does **not** normalize inverted ranges, while
  `Range.fromPositions` (associated) does. Upstream always constructs through the
  normalizing constructor.
* `delta(lineCount: usize)` cannot move upwards; upstream accepts negatives.
* Extra `lessThan` is not upstream and its logic is wrong: it uses `or` instead of
  `(same line && column<)`, so `Range(3,1)` is reported `lessThan(Range(2,9))` (`:254`).
* `toString` dangling (§2).
* `areOnlyIntersecting` uses unsigned subtraction (`b.startLineNumber - 1`); safe for
  1-based lines, but panics on 0 unlike upstream’s number arithmetic.

### `selection.zig`
Missing: `liftSelection`, `isISelection`, public static `selectionsEqual`
(the helper is private), null handling in `selectionsArrEqual`.
Broken: both override setters (§2), `toString` (§2).
`init`/constructor normalization matches upstream; `getDirection`, `getPosition`,
`getSelectionStart`, `createWithDirection`, `fromRange`, `plusRange`, `isEmpty` match.

### `stringBuilder.zig`
* The port is a UTF-8 builder. Upstream's `decodeUTF16LE` / platform decoder /
  `compatDecodeUTF16LE` and `getPlatformTextDecoder` are intentionally **not**
  ported: editor core is UTF-8, and UTF-16 conversion belongs only at the
  TextMate adapter boundary.
* `StringBuilder` is an unbounded UTF-8 `ArrayList`; upstream is a fixed UTF-16
  capacity buffer with flush/`_completedStrings`. Output is equivalent; the capacity
  parameter is only a reservation here. `appendCharCode` appends one UTF-8 encoded
  code point (astral code points are 4 bytes).
* `build()` returns a borrowed slice; upstream returns a new string.

### `textChange.zig`
* `toString` tags differ from upstream: `(inserted@` / `(deleted@` / `(replaced@`
  vs `(insert@` / `(delete@` / `(replace@` (`textChange.zig:52,58,65`).
* `writeSize`/`write`/`read` serialize UTF-8 **byte** lengths and raw bytes; upstream
  writes a UTF-16 code-unit count followed by 2-byte code units. The wire format is
  incompatible both in text encoding and in the meaning of the position fields
  (bytes here, UTF-16 units upstream) — see §0. `read` returns `UnexpectedEof` on a
  truncated buffer.
* `compressConsecutiveTextChanges` returns a shallow copy of `currEdits` when
  `prevEdits` is empty; upstream returns the same array. Because `TextChange` owns
  `String` values, result + input can double-free if both are deinited.
* `TextChangeCompressor._merge` overwrites/truncates entries without deiniting them and
  `_removeNoOps` drops entries without freeing their strings → leaks in the merge path.
  Split results that are replaced also leak.
* Compression algorithm itself matches upstream line-for-line.

### `wordCharacterClassifier.zig`
* Missing the entire `Intl.Segmenter` half of upstream: `intlSegmenterLocales`,
  `_segmenter`, `findPrevIntlWordBeforeOrAtOffset`, `findNextIntlWordAtOrAfterOffset`,
  `_getIntlSegmenterWordsOnLine`, `_filterWordSegments`, `_isWordLike`,
  `IntlWordSegmentData`. CJK word selection therefore cannot use `Intl`.
* `init` iterates UTF-8 **bytes** of `wordSeparators`; upstream iterates UTF-16 code
  units. A non-ASCII separator (e.g. U+FF0C) is registered as 3 byte values here and
  never matches the `u21` code point passed to `get`.
* Cache: upstream is an `LRUCache<string, WordCharacterClassifier>(10)` keyed by
  `separators + locales`; the port is an unbounded process-global
  `StringHashMap`, keyed only by separators, allocated with `page_allocator`
  (`_ = allocator`), requiring `freeWordClassifierCache` at shutdown.
* `set` is uncompilable (§2).

### `wordHelper.zig`
* Missing `setDefaultGetWordAtTextConfig`, the `_defaultConfig` linked list, and the
  exported `DEFAULT_WORD_REGEXP`; config is hardcoded (`GetWordAtTextConfig`).
* `getWordAtText` signature drops the optional `config` argument (separate
  `getWordAtTextWithConfig` added).
* Early return `if (pos >= text.len) return null;` drops the end-of-line position
  (§1). Upstream only rejects `pos < 0` (implicitly) and accepts `pos == length`
  when a word ends there.
* The truncation path slices `text[start..]`; upstream slices
  `text.substring(start, column + maxLen/2)`. For a >500-char word the port returns the
  whole word, upstream returns a truncated word.
* The windowed search (`windowSize`, `prevRegexIndex`) and `timeBudget` are not
  implemented. `_findRegexMatchEnclosingPosition` semantics are folded into one full
  scan, and `lastIndex` reset/global-flag handling is delegated to the Zig regex wrapper.
  Results are usually equal, but the time budget never applies.
* `defaultWordRegExp` caches with `page_allocator` and is never freed (upstream module
  constant).

### `edits/edit.zig`
* Missing aliases `AnyEdit`, `AnyReplacement`; no public `BaseReplacement` base type
  (each replacement is standalone, which is fine for Zig).
* `AnnotationReplacement.equals`/`tryJoinTouching` compare annotations with
  `std.meta.eql` (structural) instead of upstream’s `===` (identity). Same for
  `ArrayReplacement.equals` elements (`std.meta.eql` vs `===`), which matters for
  non-scalar element types.
* `create` deep-clones every replacement into an arena; upstream shares references.
  This is a deliberate ownership adaptation but means annotations are copied too.
* `normalize`, `compose`, `decomposeSplit`, `getNewRanges`, `getJoinedReplaceRange`,
  `isEmpty`, `getLengthDelta`, `getNewDataLength`, `applyToOffset`,
  `applyToOffsetRange`, `applyInverseToOffset`, `applyToOffsetOrUndefined`,
  `applyToOffsetRangeOrUndefined` match upstream logic.
* `toString` formatting matches.

### `edits/arrayEdit.zig`
* Upstream static methods (`ArrayEdit.create/single/replace/insert/delete/apply/inverse`)
  are free functions here; `ArrayEdit.apply`/`inverse` are `apply()`/`inverse()`
  free functions. API shape only.
* `apply` computes the output length first and `std.debug.assert(dst == result.len)`;
  upstream just pushes slices and tolerates out-of-range input (JS clamps). Invalid
  edits can panic here.
* `inverse` duplicates replacement payloads, calls `create` (which clones again), then
  frees the temporary copies — correct but double allocation.
* `ArrayReplacement.equals` deep-compares elements with `std.meta.eql` (upstream `===`).
* `ArrayReplacement.toString` prints `range -> [N items]`; upstream does not override
  `BaseReplacement.toString`, so it renders `{ range -> newLength }`.
* `tryJoinTouching` always joins (matches upstream).

### `edits/lengthEdit.zig`
* Upstream static `LengthEdit.compose(edits)` → free `composeAll`.
* `LengthReplacement.toString` omits upstream’s trailing stray `}`:
  upstream `[start, +len) -> +new}}`, port `[start, +len) -> +new`.
* `fromEdit` is generic over replacement type vs upstream `AnyEdit`; `inverse`,
  `applyArray`, `replace`, `insert`, `delete` match.
* `composeAll` deinits the accumulator then assigns the new edit; on an error mid-loop
  the accumulator leaks (the `errdefer` only covers the first value).

### `edits/lineEdit.zig`
* Serialization shape differs: upstream `SerializedLineReplacement` is a tuple
  `[startLineNumber, endLineNumber, newLines]`; the port is a struct with named fields
  (`lineEdit.zig:17-23`). Any serialized data exchanged with upstream is incompatible.
  Missing `SerializedLineReplacement.is`.
* `LineReplacement.toString` approximates `JSON.stringify` but does not escape quotes/
  control characters (`:230-238`).
* `humanReadablePatch` differs (§1).
* `fromSingleTextEdit` leaks the `new_lines` backing array and any lines removed by
  `orderedRemove`/`pop`; it also reads `surviving_first_line_text.len` after freeing
  that allocation (value read only, but fragile).
* `LineEdit.create` clones all `LineReplacement`s (and every line string) into an arena;
  upstream stores the given array. `deserialize`, `fromStringEdit`, `fromTextEdit`,
  `toEdit`, `normalize`-equivalent behavior, `getNewLineRanges`, `mapLineNumber`,
  `mapLineRange`, `inverse`, `apply`, `rebase`, `touches` match logic.
* Method name: upstream static `LineRange.join`; port `joinAll` (see lineRange).
* `LineRange` validation in `LineEdit.create` matches upstream’s
  `checkAdjacentItems` (`end <= next.start`).

### `edits/stringEdit.zig`
* **Missing whole annotated-edit layer**: `IEditData`, `VoidEditData`,
  `AnnotatedStringEdit`, `AnnotatedStringReplacement` (`stringEdit.ts:493-611`).
  There is no `mapData`, no `toStringEdit`, no data-joining during normalize/compose.
  (Grepping `src` shows no equivalent elsewhere.)
* Missing `BaseStringEdit.composeOrUndefined` (upstream static returning `undefined`
  for zero edits); `composeAll` returns an empty edit instead.
* Missing `BaseStringEdit.TReplacement` accessor (upstream oddity).
* `parse` is a hand-written scanner that **composes** replacements via
  `StringEdit.compose` instead of building one simultaneous edit. This is wrong for
  every replacement after the first when an earlier replacement changes length: e.g.
  `[[0, 1) -> "XX", [2, 3) -> "b"]` applied to `"abc"` yields `"XXbc"`
  (one merged replacement) instead of `"XXbb"`. See §1. Upstream’s regex parser keeps
  the ranges verbatim and rejects unsorted input. `parse` has no production caller and
  its inline test does not assert intermediate ranges.
* `StringReplacement.toString` writes the raw text (` -> "{s}"`) instead of
  `JSON.stringify`, so quotes/newlines/backslashes are not escaped.
* `apply` slices `base[pos..start]` without clamping; upstream `substring` clamps.
  Invalid edits panic instead of producing a best-effort result.
* `isNeutralOn`, `removeCommonSuffixPrefix`, `normalizeEOL`, `normalizeOnSource`,
  `removeCommonSuffixAndPrefix`, `applyEditsToRanges`, `applyOnText`,
  `tryRebase`/`rebaseSkipConflicting`, `trySwap`, `inverse`, `inverseOnSlice`,
  `toJson`/`fromJson` match upstream logic.
* Ownership is mixed: `StringReplacement.newText` is borrowed when constructed by value,
  but `create` clones into an arena; several helpers allocate with the passed allocator
  and are not uniformly freed.

### `edits/textEdit.zig`
* `format()` replaces upstream `toString(text?)`; two output bugs (§1).
* Missing `rangeFromPositions` helper and its `MAX_SAFE_INTEGER` special case
  (`textEdit.ts:777-786`), which upstream uses in `mapPosition`.
* `TextEdit` is a standalone arena-owning struct (not `BaseEdit`), matching upstream’s
  separate `TextEdit`; `create` clones all replacements and errors on non-adjacent input
  where upstream uses `assertFn`.
* `mapPosition`/`getNewRanges`/`compose`/`inverse`/`toReplacement`/`normalize`/
  `mapRange`/`inverseMapPosition`/`inverseMapRange`/`apply`/`applyToString`/`equals`
  follow upstream. The `Composer` port is line-for-line equivalent, with unsigned
  intermediate arithmetic where upstream uses arbitrary numbers (potential panic on
  positions that would go negative upstream).
* `joinReplacements` clones for the one-replacement case (upstream returns the same
  object); `toSingleEditOperation` matches (no `forceMoveMarkers`).

### `misc/eolCounter.zig`
* Upstream is `countEOL(text): [eolCount, firstLineLength, lastLineLength, StringEOL]`;
  the port returns a `CountEOLResult` struct (API shape).
* Lengths are UTF-8 **bytes**, not UTF-16 code units (consistent with the rest of the
  port, but a numeric divergence for non-ASCII lines).
* Extra, not upstream: `EOL` enum, `eolToString`, `replaceEOL`. `replaceEOL` rewrites
  CRLF/LF pairs in place; it has no upstream counterpart to compare.

### `misc/indentation.zig`
See §1. Also: the result is an owned slice (upstream returns a string); indentation is
counted in bytes; any non-tab counts as one space (matches upstream).

### `misc/rgba.zig`
Faithful: clamp `[0,255]`, `empty`, `equals`. `_clamp` is private here vs public static
upstream (irrelevant).

### `misc/textModelDefaults.zig`
Upstream `EDITOR_MODEL_DEFAULTS` has no `defaultEOL` or `isForSimpleWidget`; the port
adds `.defaultEOL = .LF` and `.isForSimpleWidget = false` because the Zig
`TextModelCreationOptions` requires them. Values match the conventional upstream
defaults, but they are no longer left to the consumer.

### `ranges/columnRange.zig`
Faithful. `init` returns `error.InvalidColumnRange` instead of throwing;
`fromOffsetRange`, `toRange`, `equals`, `toZeroBasedOffsetRange` match.

### `ranges/lineRange.zig`
* `toInclusiveRange` / `toExclusiveRange` are the wrong type and break the diff layer
  (§1).
* `joinMany` is uncompilable and has the wrong signature for `LineRangeSet.init`
  (§2); it also returns a slice backed by a leaked local `LineRangeSet`.
* Missing `compareByStart`; static `join` is named `joinAll` here; extra `deltaSigned`.
* `LineRange.init` uses `unreachable` (UB in release-fast) where upstream throws
  `BugIndicatingError`.
* `LineRangeSet`: `getUnion` returns `other` / `self.*` **by value**, so two sets share
  one `ArrayList` and can double-deinit; upstream returns one of the operands by
  reference (GC). `deinit`, `empty`, `init` are port additions. `addRange`, `contains`,
  `intersects`, `subtractFrom`, `toString`, `getIntersection`, `getWithDelta` match.
* Extra `getWithDeltaSigned`.
* `serialize`/`deserialize` use `[2]usize` (tuple equivalent to upstream’s
  `ISerializedLineRange`).

### `ranges/offsetRange.zig`
* Missing `withMargin` (both overloads). `fromTo` is the constructor here.
* `init` does **not** validate `start <= endExclusive`; upstream throws on violation.
  `tryCreate` exists but callers use `init`.
* `delta`/`deltaStart`/`deltaEnd` take `isize` (upstream `number`); `usizeAdd` clamps
  by trapping/`@intCast` on negative results.
* `offsetRange.zig:222-289` `OffsetRangeSet` is essentially dead and broken:
  `.len` on Managed lists, `toString` passing an allocator where a writer is expected,
  no `deinit`, `getRanges` returning the internal slice.
* Extra `addRange`, `map`, `forEach`, `joinRightTouching` shapes are otherwise
  upstream-equivalent; `intersect`, `intersectionLength`, `intersects`,
  `intersectsOrTouches`, `isBefore`, `isAfter`, `clip`, `clipCyclic` match.
* `toString` matches format `[start, end)`.

### `ranges/rangeMapping.zig`
* `mapPosition` uses a reverse linear scan; upstream uses `findLastMonotonous`
  (binary search over the sorted mappings). Same result for sorted input, O(n) vs O(log n).
* `RangeMapping.reverse` allocates with the given allocator; the struct has no
  `deinit`, and `init` borrows its slice — ownership is inconsistent and callers can
  leak or double-free.
* Missing `SingleRangeMapping.toString`.
* `PositionOrRange` is a tagged union with static constructors absent; upstream is a
  class with optional fields. `mapRange` logic matches.

### `ranges/rangePriorityQueue.zig` (no upstream file)
* Upstream defines `RangePriorityQueue`/`RangePriorityQueueImpl` inside
  `model/textModelTokens.ts:326-424`; the port promotes it to its own core file, which
  violates the “mirror the upstream tree” rule but is otherwise a faithful copy of
  `RangePriorityQueueImpl` (`min`, `removeMin`, `delete`, `addRange`,
  `addRangeAndResize`, `getRanges`, `toString`).
* Missing the `RangePriorityQueue` interface type (only the implementation exists).

### `ranges/rangeSingleLine.zig`
Faithful. `fromRange` returns `null` when the column range is invalid (upstream would
throw, but a normalized `Range` cannot trigger it); `toRange` matches.

### `text/abstractText.zig` (370 vs 130 lines) — structural rewrite
* Upstream has an abstract `AbstractText` with `LineBasedText`, `ArrayText`,
  `StringText` subclasses. The port collapses them into one tagged union
  (`kind: string|array|line_based`) plus callback-based `LineBasedText`. Behavior is
  mostly reproduced, but it is not extensible and method names differ
  (`getLength()` vs `length`).
* `getValueOfRange`, `getLineAt`, `getLinesOfRange` return **owned allocations**
  (callers must free), whereas upstream returns substrings. `getLines` returns an
  `ArrayList` of slices into the cached value.
* `getValueOfOffsetRange` is uncompilable (§2).
* `getValueOfRangeString` uses custom `offsetAt`/`rangeToOffsets` rather than the
  transformer: for columns past the line length it clamps to the `\r` position, so
  `getValueOfRange(Range(1,1,1,4))` on `"ab\r\n"` returns `"ab\r"` while upstream’s
  validated transformer returns `"ab"`. Valid positions agree.
* `getValueOfRangeLineBased` clamps out-of-range line numbers/columns to the text
  bounds; upstream assumes valid positions (JS `substring` clamps columns, but not
  lines).
* `getLineAt` on a `.string` text panics with integer overflow for line 2+ because
  `offsetAt` adds `maxInt(usize)` to the line start (`abstractText.zig:278`). The array
  and line-based paths are unaffected; there is no caller today, so this is latent.
* `getLength` for an empty array/line-based text returns `(0,0)`; upstream asserts
  `lineCount >= 1`.
* `getLineLength` for strings = bytes up to `\n`, trailing `\r` stripped; matches the
  transformer’s notion.
* `equals` compares values only (no identity shortcut).

### `text/getPositionOffsetTransformerFromTextModel.zig`
* Upstream subclass overrides only `getOffset`/`getPosition` and inherits
  `getOffsetRange`/`getRange` from `PositionOffsetTransformerBase`. The port adds
  `getOffsetRange`, `getRange`, `getLineLength`, `textLength` and returns the concrete
  type. Extra API, no conflict.
* `init`/`getPositionOffsetTransformerFromTextModel` match.

### `text/positionToOffset.zig` — duplicate transformer
* Upstream `positionToOffset.ts` is only dependency wiring and re-exports
  `PositionOffsetTransformer` from `positionToOffsetImpl.ts`. The port instead defines
  a second, **eager** `PositionOffsetTransformer` here (arrays built in `init`) and
  `abstractText.zig` imports this one. `positionToOffsetImpl.zig` is used only by its
  own tests.
* Missing the base-class conversion methods and `getTextLength`; has
  `getOffset`/`getOffsetRange`/`getPosition`/`getRange`/`getLineLength`/`textLength`.
* Algorithm matches `positionToOffsetImpl` (validated positions, lazy upstream vs eager
  here; `init` can now fail on allocation).

### `text/positionToOffsetImpl.zig`
* Concrete class is missing `getOffsetRange`/`getRange`; they exist only on
  `asBase()`. `getTextLength` therefore fails to compile (§2).
* `asBase()` replaces upstream inheritance; the base struct exposes
  `getOffset`, `getOffsetRange`, `getPosition`, `getRange`, and the four
  `getStringEdit`/`getStringReplacement`/`getTextReplacement`/`getTextEdit`
  conversions, matching upstream minus the `Deps` indirection (documented in header).
* Lazy line offsets: getters use `catch unreachable` (allocation failure panics) where
  upstream never fails.
* `_validatePosition`, `getOffset`, `getPosition` (binary search via
  `findLastIdxMonotonous`), `textLength`, `getLineLength`, `computeLineOffsets` match.
* Divergences are documented in the file header (no `Deps`, function-pointer base,
  byte offsets).

### `text/textLength.zig`
* Missing `sum(fragments, getLength)` and `toString`.
* `zero`, `lengthDiffNonNegative`, `betweenPositions`, `fromPosition`, `ofRange`,
  `ofText`, `ofSubstr`, comparisons, `add`, `createRange`, `toRange`, `toLineRange`,
  `addToPosition`, `addToRange` match. `ofText` iterates bytes but only tests `\n`, so
  the result matches for UTF-8.

---

## 4. Cross-cutting differences

**Upstream file with a reduced port**
* `editorColorRegistry.ts`: the exported color IDs are ported as string
  constants in `editorColorRegistry.zig` (the terminal palette consumes the IDs
  directly). Upstream's `registerColor` defaults and theming participant are not
  duplicated; that wiring belongs to the platform theme layer.

**Extra files**
* `ranges/rangePriorityQueue.zig` (upstream inside `model/textModelTokens.ts`).

**Header comments**
All 36 Zig files under `common/core` (including the added
`editorColorRegistry.zig`) now carry a `// Port of ...` header.

**Tests**
Upstream core tests are not mirrored in `src/vs/editor/test/common/core/`:
present are only `lineTokensTests.zig` (renamed from upstream
`lineTokens.test.ts`) and `stringBuilder.test.zig`. Missing upstream test files:
`characterClassifier.test.ts`, `cursorColumns.test.ts`, `lineRange.test.ts`,
`positionOffsetTransformer.test.ts`, `range.test.ts`, `stringEdit.test.ts`,
`textEdit.test.ts`. Coverage for the fixed behavior exists as inline `test` blocks
in the ported modules plus the focused `zig build test-core` step; it is still not
at the upstream `test/...` path/basename.

**Serialization**
* `TextChange.write/read/writeSize`: UTF-8 byte length vs upstream UTF-16 code-unit
  count + 2-byte units.
* `LineEdit`/`LineReplacement`: struct field serialization vs upstream tuple
  `[start, end, newLines]`.
* `StringEdit.toJson/fromJson`: same `{txt,pos,len}` fields, but a Zig struct rather
  than an interface (JSON shape is compatible if field names are preserved by the
  serializer).

**Ownership**
The port repeatedly turns borrowed upstream references into owned copies, without a
uniform contract: `AbstractText` values/lines, `StringReplacement.newText`,
`TextChange` strings, `LineEdit` lines, `RangeMapping.reverse`,
`LineRangeSet.getUnion`, `StringEdit`/`TextEdit` arenas. Several deinit paths are
missing or share storage:
* `RangeMapping.reverse` allocates; no deinit.
* `LineRangeSet.getUnion` returns a copy of an existing set (double-deinit).
* `LineEdit.fromSingleTextEdit` leaks its `new_lines` list.
* `TextChangeCompressor` leaks merged/dropped entries.
* `TextChange` compression can alias owned strings between input and result.

**Naming/structure**
`joinAll` vs upstream `join`; `unionRect` vs `union`; `format` vs `toString`;
`getLength` vs `length`; free functions vs static methods for `ArrayEdit`,
`LengthEdit`, `StringEdit`; `AbstractText` union vs class hierarchy; duplicate
`PositionOffsetTransformer`; `RangePriorityQueue` relocated.

---

## 5. Fix status (this session)

### Fixed

* Compile-when-referenced failures: `Selection` setters/`toString`,
  `OffsetRangeSet` (`addRange`/`toString`/`intersectsStrict`/`length` and missing
  `deinit`), `LineRange.joinMany`, `AbstractText.getValueOfOffsetRange`,
  `PositionOffsetTransformer.getTextLength` (and the missing concrete
  `getOffsetRange`/`getRange` methods), `WordCharacterClassifier.set`.
* `LineRange.toInclusiveRange`/`toExclusiveRange` now return `Range`; the diff
  layer's `toRangeMapping` type-checks again.
* `Range.equalsRange(null, null)`, free `fromPositions` normalization,
  `lessThan`, dangling `toString`; added `collapseToStart`, `strictContainsPosition`,
  `lift`, `isEmptyRange`, `deltaSigned`.
* `indentation.zig` no longer treats CR/LF as indentation.
* `cursorColumns.zig` now uses the correct `strings.isFullWidthCharacter`, the
  upstream emoji ranges, and a faithful UTF-8 `GraphemeIterator`
  (`src/vs/base/common/graphemeBreak.zig`, generated from upstream's table).
* `wordHelper.zig`: end-of-line lookup, windowed search, time budget, settable
  default config, and UTF-8-safe truncation.
* `StringEdit.parse` now builds one simultaneous edit; its test asserts every
  range.
* `TextEdit.format` now matches upstream truncation/ellipsis and truncates at
  UTF-8 sequence boundaries; `rangeFromPositions` handles the
  `MAX_SAFE_INTEGER` sentinel.
* `LineEdit.humanReadablePatch` no longer appends a trailing newline and
  `LineReplacement.toString` escapes JSON-sensitive characters.
* `TextChange` debug labels match upstream; serialization intentionally uses
  UTF-8 byte lengths (see §0); compressor merge/remove paths release consumed
  entries.
* Added the annotated string-edit layer
  (`AnnotatedStringEdit`/`AnnotatedStringReplacement`/`VoidEditData`).
* Added the missing small APIs: `Position.with/clone/lift/toString`,
  `Point.mapComponents/toString`, `Size2D.deltaX/deltaY/mapComponents/toString`,
  the missing `Rect` methods, `OffsetRange.withMargin/withMargins/fromTo`,
  `TextLength.sum/toString`, `LineRange.compareByStart`,
  `SingleRangeMapping.toString`, `RangeMapping.deinit`.
* Unified the duplicated position/offset transformer: `positionToOffset.zig` is
  now the upstream-shaped re-export of `positionToOffsetImpl.zig`; `abstractText`
  uses the single lazy implementation.
* Every core file now has the required `// Port of ...` header.

### Remaining intentional divergences

* **UTF-8 byte columns/offsets instead of UTF-16 code units** (§0). This is the
  project contract and the user-requested behavior. No UTF-8↔UTF-16 conversion
  remains in core; the only UTF-16 boundary is the TextMate adapter (plus
  extension-host RPC conversion in `src/tui`/workbench).
* `wordCharacterClassifier.zig` does not expose the `Intl.Segmenter` API; Zig
  has no browser `Intl` and nothing in this port consumes it.
* `editorColorRegistry.ts` is ported only as ID constants; `registerColor`
  defaults/theming are not duplicated (the terminal palette consumes the IDs).
* `rangePriorityQueue.zig` lives in `core/ranges/` while upstream keeps the
  class in `model/textModelTokens.ts`; the implementation matches upstream.
* `AbstractText` is one tagged union instead of an abstract class hierarchy;
  behavior is covered by tests but it is not extensible.
* `LineEdit` serializes replacements as structs rather than upstream's tuple
  `[start, end, newLines]`; internal code never exchanges this data with
  upstream.
* Core tests remain inline in the ported modules; the upstream
  `test/common/core/*.test.ts` files are not mirrored one-for-one.
