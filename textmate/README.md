# vscode-textmate port

This directory is a faithful Zig port of
[`microsoft/vscode-textmate`](https://github.com/microsoft/vscode-textmate),
the TextMate engine used by VS Code.

- Reference checkout: `../vscode-textmate`
- Pinned version: **9.3.2** (commit `5fc1758`, package.json version `9.3.2`)
- Zig: 0.17
- Status: **early** — the path is being built up file by file while the editor
  continues to use the pinned `textmate.zig` dependency.

The package is standalone: it must not import from `src/`. It is a path
dependency named `vscode_textmate` in the root `build.zig.zon`.

## Why

`textmate.zig` is a compact TextMate engine, not a complete equivalent of
`vscode-textmate`. Known divergences include:

- fixed limits (`max_line_len = 1024`, 9 match ranges, 64 span captures,
  pruned state stacks);
- no `$self`/`$base` completion, `firstLineMatch`, folding markers,
  `embeddedLanguages` or per-grammar `tokenTypes`;
- partial injection support and a simplified scope-selector grammar;
- system Oniguruma instead of `vscode-oniguruma`, with no retry/timeout policy;
- silent regex compile failures.

The long-term goal is to replace the dependency with this port and delete the
remaining compatibility layer.

## Current status

| Upstream source | Port | Status |
| --- | --- | --- |
| `src/matcher.ts` | `src/matcher.zig` | **Ported**, all upstream matcher tests |
| `src/rawGrammar.ts` | — | TODO |
| `src/onigLib.ts` | — | TODO (binding decision needed) |
| `src/utils.ts` | — | TODO |
| `src/parseRawGrammar.ts` | — | TODO |
| `src/json.ts` | — | TODO |
| `src/plist.ts` | — | TODO |
| `src/encodedTokenAttributes.ts` | — | TODO |
| `src/rule.ts` | — | TODO |
| `src/grammar/grammarDependencies.ts` | — | TODO |
| `src/grammar/basicScopesAttributeProvider.ts` | — | TODO |
| `src/grammar/grammar.ts` | — | TODO |
| `src/grammar/tokenizeString.ts` | — | TODO |
| `src/theme.ts` | — | TODO |
| `src/registry.ts` | — | TODO |
| `src/main.ts` | — | TODO |
| `src/diffStateStacks.ts` | — | TODO |
| `src/debug.ts` | — | TODO (optional) |
| `src/tests/*` | `src/*.test.zig` | Matcher tests ported; rest TODO |

## Allocator model (reference: textmate.zig)

The port follows the allocator conventions of the pinned `textmate.zig`
dependency rather than introducing a new ownership style:

- Every constructor and factory takes an explicit `std.mem.Allocator`; there is
  no global or hidden allocator.
- `textmate.zig`'s `Grammar` and `Theme` each own an `ArenaAllocator`, while
  `Parser` owns its string arenas and unmanaged `std.ArrayList` fields. Objects
  store the allocator they were created with and expose `deinit`.
- This port mirrors that: `MatcherSet(T)` owns an `ArenaAllocator` created from
  the caller's allocator. The selector copy, matcher nodes and identifier
  slices all live in that arena, and `MatcherSet.deinit` releases them.
- Use Zig 0.17 unmanaged `std.ArrayList` with explicit allocator arguments in
  this package. The editor's legacy `std.array_list.Managed` shim belongs to
  `src/`, not to `textmate/`.
- Tests allocate with `std.testing.allocator` and always `defer` the set's
  `deinit`, so leaks are visible under `zig build test`.

## Porting rules

1. **Read the upstream file and its tests first.**
2. Keep the upstream basename: `matcher.ts` → `matcher.zig`, `grammar.ts` →
   `grammar.zig`. Test files keep the upstream `*.test.ts` name:
   `tests/matcher.test.ts` → `src/matcher.test.zig`.
3. Prefer upstream control flow, names and edge cases over Zig rewrites. Use
   Zig naming for fields/functions and PascalCase for types; comments may keep
   upstream terminology (`IRawRule`, `ScopePath`, `RuleId`, ...).
4. Port every upstream test case. Do not delete inconvenient assertions.
5. State every deliberate adaptation in the file header and here:
   - TypeScript closures/interfaces become explicit tagged unions and
     function pointers.
   - TypeScript garbage collection becomes explicit allocators/arenas with a
     `deinit` path.
   - JavaScript regular expressions used for tokenizing selectors become hand
     scanners when a regex would obscure the exact behavior; tests must prove
     equivalence.
   - `console.log` diagnostics are not part of the API.
6. Do not add features that upstream does not have. If the terminal/editor
   needs a deviation, isolate it outside this package.
7. Keep the copyright/license notice of the source file being ported.

## Matcher port (done)

The first vertical slice ports `src/matcher.ts` and
`src/tests/matcher.test.ts`.

- `createMatchers` returns a `MatcherSet(T)` with matcher/priority entries.
- `MatcherSet.any(matchesName, input)` matches the upstream
  `matchers.some(m => m.matcher(input))` test pattern.
- Priorities are `-1`, `0`, `1` for `L:`, none, `R:`.
- The matcher AST mirrors the upstream closure tree: name, negation,
  conjunction, disjunction. An empty conjunction is true; an empty disjunction
  is false; negating a missing operand is false.
- The selector is copied into the set's arena so matcher identifiers remain
  valid until `deinit`.

All 27 cases from `src/tests/matcher.test.ts`, plus priority and empty-selector
coverage, are ported. Run:

```sh
cd textmate
zig build test
```

or from the repository root:

```sh
zig build test
```

## Future work

### Phase 1 — foundations

- `rawGrammar.zig`: `IRawGrammar`, `IRawRule`, `IRawCaptures`,
  `IRawRepository`, `IncludeString`, `RegExpString`, `ScopeName`, `RuleId`.
- `onigLib.zig`: `IOnigLib`, `OnigScanner`, `OnigString`, `FindOption`.
  Decide between:
  - a `libonig` C binding like the existing editor build; or
  - `vscode-oniguruma` compatibility.
  This decision affects regex features, retry limits and portability.
- `utils.zig`, `parseRawGrammar.zig`, `json.zig`, `plist.zig`:
  grammar-file parsing, including JSONC/plist forms.
- Port `src/tests/json.test.ts`.

### Phase 2 — rules and grammar

- `encodedTokenAttributes.zig`: metadata bit layout and standard token types.
- `rule.zig`: `Rule`, `CaptureRule`, `BeginEndRule`, `BeginWhileRule`,
  `MatchRule`, include resolution.
- `grammar/grammarDependencies.zig`, `basicScopesAttributeProvider.zig`,
  `grammar.zig`, `tokenizeString.zig`: grammar loading, injection/embedded
  language resolution, tokenization state and encoded binary tokens.
- Port `src/tests/grammar.test.ts` and the tokenization fixtures.

### Phase 3 — theme, registry, main

- `theme.zig`: full scope-stack theme matching, parent selectors, exclusions,
  priorities, font styles and color maps.
- `registry.zig`: grammar registry, injection grammar resolution,
  `embeddedLanguages`, `tokenTypes`, `firstLineMatch`.
- `main.zig`: public API (`Registry`, `IGrammar`, `StateStack`, encoded tokens,
  `INITIAL`), matching upstream signatures where Zig allows.
- `diffStateStacks.zig` and `debug.zig`.
- Port `src/tests/themes.test.ts`, `themeTest.ts`, `tokenization.test.ts`.

### Phase 4 — conformance

- Port the upstream test harness and fixtures, including grammar spec tests.
- Compare token streams against `vscode-textmate` for the bundled grammars:
  - same scopes and encoded metadata;
  - same state transitions and stack diffs;
  - same behavior for injections, embedded languages and theme selectors.
- Add fuzz tests for state round-trips and malformed grammars.
- Remove fixed limits only when the port has no equivalent upstream limit.

### Phase 5 — integration

- Add the port as the editor's tokenizer behind the existing
  `ITokenizationSupport` interface.
- Remove the `textmate` dependency from `build.zig.zon` and delete
  `textmate.zig` imports.
- Keep the editor's current `TokenTheme`/Dark+ integration until the ported
  theme matcher is proven equivalent, then switch.
- Update `README.md`, `docs/extensions.md` and `AGENTS.md` with the new
  reference path and porting rules.

## Definition of done

The port is complete when:

- every upstream source file and test has a Zig counterpart;
- all upstream tests and grammar fixtures pass;
- token output is byte-for-byte compatible for the supported grammars, modulo
  documented Zig adaptations;
- the editor no longer imports `textmate.zig`;
- the package is covered by `zig build test` from the repository root.

## License

`vscode-textmate` is MIT-licensed. Ported files retain the upstream copyright
notice and the port is distributed under the repository's license.
