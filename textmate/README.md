# vscode-textmate port

This directory is a faithful Zig port of
[`microsoft/vscode-textmate`](https://github.com/microsoft/vscode-textmate),
the TextMate engine used by VS Code.

- Reference checkout: `../vscode-textmate`
- Pinned version: **9.3.2** (commit `5fc1758`, package.json version `9.3.2`)
- Zig: 0.17
- Status: **complete port of the engine and its upstream test suites**. The
  editor still uses the pinned `textmate.zig` dependency until integration is
  done; that is the remaining step, not a missing engine feature.

The package is standalone: it does not import anything from `src/`. It is a
path dependency named `vscode_textmate` in the root `build.zig.zon`.

## Source map

| Upstream source | Port | Status |
| --- | --- | --- |
| `src/rawGrammar.ts` | `src/rawGrammar.zig` | Ported |
| `src/onigLib.ts` | `src/onigLib.zig` | Ported; libonig-backed `OnigLib` |
| `src/utils.ts` | `src/utils.zig` | Ported |
| `src/parseRawGrammar.ts` | `src/parseRawGrammar.zig` | Ported |
| `src/json.ts` | `src/json.zig` | Ported |
| `src/plist.ts` | `src/plist.zig` | Ported |
| `src/encodedTokenAttributes.ts` | `src/encodedTokenAttributes.zig` | Ported |
| `src/rule.ts` | `src/rule.zig` | Ported |
| `src/grammar/grammarDependencies.ts` | `src/grammar/grammarDependencies.zig` | Ported |
| `src/grammar/basicScopesAttributeProvider.ts` | `src/grammar/basicScopesAttributeProvider.zig` | Ported |
| `src/grammar/grammar.ts` | `src/grammar/grammar.zig` | Ported |
| `src/grammar/tokenizeString.ts` | `src/grammar/tokenizeString.zig` | Ported |
| `src/grammar/index.ts` | `src/grammar/index.zig` | Ported |
| `src/theme.ts` | `src/theme.zig` | Ported |
| `src/registry.ts` | `src/registry.zig` | Ported |
| `src/main.ts` | `src/main.zig` | Ported |
| `src/diffStateStacks.ts` | `src/diffStateStacks.zig` | Ported |
| `src/debug.ts` | `src/debug.zig` | Ported as explicit flags |
| `src/matcher.ts` | `src/matcher.zig` | Ported |
| `src/tests/matcher.test.ts` | `src/matcher.test.zig` | All cases |
| `src/tests/json.test.ts` | `src/tests/json.test.zig` | All cases |
| `src/tests/grammar.test.ts` | `src/tests/grammar.test.zig` | All cases; upstream skipped case remains skipped |
| `src/tests/tokenization.test.ts` | `src/tests/tokenization.test.zig` | All three fixture suites |
| `src/tests/themes.test.ts` | `src/tests/theme.test.zig`, `src/tests/themes.test.zig` | Unit cases and all theme fixtures |
| `src/tests/themeTest.ts` | `src/tests/themes.test.zig` | Folded into the fixture runner |
| `src/tests/themedTokenizer.ts` | `src/tests/themedTokenizer.zig` | Ported |
| `src/tests/resolver.ts` | `src/tests/resolver.zig` | Ported |
| `src/tests/onigLibs.ts` | `src/onigLib.zig` | Replaced by the libonig binding |
| `src/tests/inspect.ts` | — | Not ported; interactive debugging utility only |

The upstream `test-cases/` fixtures are copied unchanged and include the
first-mate/suite1 tokenization suites and 14 themes × 72 theme fixtures.
`themes.test.ts`'s `test2.ts` timing probe is ported but skipped by default: it
has no assertions and runs over a 54k-line file with an unbounded upstream
timeout, which is too slow for the debug test suite on small CI machines.

## Building and testing

```sh
cd textmate
zig build test
```

or from the repository root:

```sh
zig build test
```

The package needs Oniguruma headers and library, like the editor build:

```sh
# macOS
brew install oniguruma
# Debian/Ubuntu
sudo apt install libonig-dev
```

The package's `build.zig` translates `src/oniguruma.h` with Zig's build-time
translate-c support; it does not rely on the editor's build graph.

## Faithful-port notes

The port follows the upstream control flow, names and edge cases. The
deliberate adaptations are:

- **Oniguruma binding.** `onigLib.zig` keeps the `IOnigLib`/`OnigScanner`/
  `OnigString` contract and provides a libonig-backed implementation. The
  upstream tests use `vscode-oniguruma` WASM; this package uses the same
  Oniguruma engine through the system library.
- **UTF-16 indices.** vscode-textmate indexes JavaScript strings in UTF-16 code
  units. `OnigString` builds the same UTF-16↔UTF-8 offset maps as
  `vscode-oniguruma` and exposes UTF-16 capture indices. ASCII strings use the
  identity path with no maps. This keeps token boundaries, captures and
  `linePos` identical to upstream. `textmate.zig` by contrast exposes UTF-8
  byte offsets.
- **Synchronous registry.** Upstream `Registry`/`RegistryOptions` use Promises.
  This port walks the grammar dependency graph synchronously; `loadGrammar`
  returns the grammar (or null) directly.
- **Dynamic raw grammar.** `IRawGrammar`/`IRawRule` are a JSON-like `Value`
  tree instead of TypeScript `any`. Object `id` and `$vscodeTextmateLocation`
  are stored on the object; grammar files are deep-cloned before compilation
  just like `initGrammar`.
- **Allocators and ownership.** Constructors take explicit allocators. A
  `Grammar` owns a persistent arena for its cloned grammar, rules and the live
  state stacks, plus per-call scratch arenas. Tokenization allocates scope and
  state nodes in a line arena and copies only the reachable end-of-line stack
  into the persistent arena; the line arena is reset on the next call. Returned
  tokens are therefore valid until the next tokenization on that grammar, and
  memory does not grow with the number of lines. `RawGrammar`/`Theme` own their
  arenas and expose `deinit`; `StackDiff` has `deinit`.
- **No JavaScript GC.** Rule objects, matcher sets and scanner caches have
  explicit ownership. `Grammar.deinit` disposes compiled scanners and matcher
  sets.
- **Scope matchers.** Selector matching keeps upstream's selector syntax via
  `matcher.zig`; embedded-language and standard-token-type matching use
  direct prefix/word scans instead of JavaScript regular expressions.
- **RTL merging.** `containsRTL` uses a compact Unicode range table for the
  characters that affect the "merge consecutive equal-metadata tokens" rule.
- **Diagnostics.** `debug.zig` exposes the upstream flags directly instead of
  reading `process.env.VSCODE_TEXTMATE_DEBUG`; console diagnostics are not part
  of the ported API.
- **Dates/data in plists.** `Value.date` and `Value.data` preserve the raw
  plist text because Zig has no JavaScript `Date` object; grammars and themes
  treat them as opaque values.
- **Font attribute cache.** The behavior of `FontAttribute` is ported without
  the static cache; the observable token/font output is identical.

### Memory model

Each `tokenizeLine*` call resets a line arena. Scope stacks, state stacks and
dynamic end/while regex sources created during that call live there. At the
end of the call, only the nodes reachable from the returned `ruleStack` that
are not already persistent are copied into the grammar arena (`persistent`
flags on state/scope nodes stop the copy at the previous line's live stack).
The next call resets the line arena, so token text/scopes from the previous
result must be consumed before then. This keeps long-file memory bounded by
the live stack depth rather than by the number of lines.

## Definition of done

- [x] Every upstream source file has a Zig counterpart (except the dev-only
      `inspect.ts` utility).
- [x] Every upstream test suite has a Zig counterpart.
- [x] The first-mate, suite1 and while tokenization fixtures pass.
- [x] All theme unit tests and all 14×72 theme fixtures pass.
- [x] The 54k-line timing benchmark is ported but skipped by default (no
      assertions; debug/CI runtime).
- [x] `cd textmate && zig build test` passes.
- [x] The package is covered by `zig build test` from the repository root.
- [ ] Replace the editor's pinned `textmate.zig` dependency with this package
      behind `ITokenizationSupport` and remove the old dependency.

## Integration notes

When wiring this package into the editor:

- The editor currently stores UTF-8 line text. Convert at the tokenization
  boundary or keep a UTF-16 view; token indices are UTF-16 code units.
- `tokenizeLine2` results are scratch-owned until the next call. Copy tokens
  or consume them before tokenizing the next line.
- The editor's existing `TokenTheme`/Dark+ mapping can be replaced by
  `Theme`/`ColorMap` once the editor is ready to use scratch-arena state
  stacks.

## License

`vscode-textmate` is MIT-licensed. Ported files retain the upstream copyright
notice and the port is distributed under the repository's license.
