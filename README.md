Port of vscode's pieceTree to zig.

Requires Zig 0.17 or newer.

```
brew install oniguruma
zig build        # build the TUI editor
zig build run    # run it
zig build test   # run the test suite
```

Notes for the Zig 0.17 port:

- `@cImport` was removed in Zig 0.17, so `oniguruma.h` is translated by the
  build system (`addTranslateC`) and imported as the `oniguruma` module.
- `std.io` was replaced by the `std.Io` reader/writer interfaces; the app
  receives its `Io` instance through `std.process.Init`.
- `std.ArrayList` is unmanaged in Zig 0.17. This port currently uses the
  deprecated-but-supported `std.array_list.Managed` shim as an intermediate
  step; moving to unmanaged lists is the main remaining modernization.

Tokenizer status:

- The syntax-tokenizer stack from `vscode/src/vs/editor/common/model/tokens`
  and `textModelTokens.ts` is ported and wired into `TextModel`:
  tokenizer state tracking, incremental edits, background tokenization,
  attached views, token events, language switching, semantic-token overlays,
  and `getWordAtPosition`/`getWordUntilPosition`.
- Ported tests: upstream `lineTokens.test.ts`, `tokensStore.test.ts`,
  `model.modes.test.ts`, and the default-word cases from `model.test.ts`.
- Not ported: tree-sitter tokenization, font-token annotations, bracket-pair
  colorization, and custom `wordPattern` language configurations.
- Background tokenization is synchronous (1 ms chunks) because this port has
  no browser idle loop; behavior is otherwise equivalent.
