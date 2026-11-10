# AGENTS.md — porting rules for vscode-textbuffer

This repository is a Zig 0.17 port of VS Code editor internals. The upstream
checkout is expected at `../vscode`. Upstream source paths therefore start with:

```
../vscode/src/vs/editor/...
```

Do not edit upstream files. Port behavior into this repository instead.

## Source layout

- Mirror the upstream file and folder structure exactly under
  `src/vs/editor/...`: same directory names, same basenames, only changing
  `.ts` to `.zig`.
- TUI-only integration belongs in `src/tui/`; portable editor logic belongs in
  `src/vs/editor/...`.
- Tests are part of that structure. Keep the upstream `test/...` folder and the
  upstream `.test.ts` basename, e.g.
  `src/vs/editor/contrib/lineSelection/test/browser/lineSelection.test.ts`
  becomes `.../lineSelection.test.zig`. Do not relocate tests to an alternative
  tree and do not rename them to `...Tests.zig`.
- Register new test files in `src/tests.zig` so `zig build test` discovers them.
- Add a short header comment naming the upstream file being ported:

```zig
// Port of `src/vs/editor/contrib/.../file.ts`.
```

When a file contains a deliberate Zig adaptation rather than a literal port,
state that in the comment and keep the behavioral contract intact.

## Standalone UI library

- `ui/` is a separate Zig package outside `src/` (a path dependency in
  `build.zig.zon`). It must not import anything from `src/`.
- There is no CSS and no HTML in this layer: node styles are direct `Style`
  values, and class names are identifiers, never selectors.
- The renderer is a double-buffered cell grid with an ANSI frame diff; see
  `docs/terminal-ui.md`. Library tests read `Surface.grid()`, not ANSI strings.
- Layout runs on the derived box tree in `ui/box.zig`, never on DOM nodes:
  viewport root, principal element boxes, anonymous inline/flex-item boxes and
  text boxes. `ui/layout.zig` solves that tree; `ui/paint.zig` walks it. Copy
  geometry back to DOM rects only at the measurement boundary.
- Invalidation is WebKit-like: DOM mutations notify the attached box tree,
  which marks boxes/tree dirty (`needs_rebuild`, `needs_layout`). Do not add a
  document-level revision or dirty flag.
- Keyboard events and focus live in `ui/event.zig`; terminal byte decoding is
  `ui/input.zig`. Key events capture/target/bubble and only `key_down` exists.
  Focus uses `Document.activeElement`, `Element.focusable` / `tab_index`, and
  `focus`/`blur` plus bubbling `focusin`/`focusout`; Tab is a default action,
  not a global shortcut. Keep these rules in the library, not in `src/tui/`.
- TUI integration (terminal raw mode/read loop, status) stays in `src/tui/`.
  `src/tui/view.zig` is the editor view on the `ui` tree: it owns the gutter,
  token runs, selection, cursor cell and status bar, and rebuilds the document
  through `Document.clear` so the `Surface` keeps its frame diff. The
  read-only `--preview` variant is `src/tui/preview.zig`.
- Widgets and view contributions ported from `src/vs/editor/contrib/...` build
  their view on this document; keep their model/state code upstream-shaped and
  put only the terminal DOM adaptation in the widget. Sidebar/preview/read-loop
  code must not re-implement focus or key dispatch that the library owns.
  The find contribution is the first consumer: `findState`/`findModel` are the
  model, `findWidget` is the terminal view, and `findController` wires state,
  model, widget and the view's decoration sink.
- `zig build test` builds and runs `ui/tests.zig` alongside the editor tests;
  `cd ui && zig build test` runs the library on its own.
- Because `ui/` is a new package, it uses Zig 0.17 unmanaged `std.ArrayList`;
  the editor's `std.array_list.Managed` shim is the legacy side.

## Porting approach

1. Read the upstream implementation and its tests before writing code.
2. Port the complete portable behavior, not just the happy path.
3. Keep upstream names where practical. Use Zig naming for fields/functions
   (`snake_case`) and PascalCase for types; follow nearby code when a binding
   already exists.
4. Preserve upstream edge cases: empty selections, multi-cursor paths, mixed
   line endings, surrogate/UTF-8 boundaries, undo grouping, and option values.
5. Browser DOM, widgets, keybinding registries, and other UI infrastructure are
   not portable. Implement the underlying model/command logic, wire it into the
   TUI where applicable, and document the missing UI layer.
6. Do not invent behavior that upstream does not have. If a shortcut or command
   is TUI-specific, say so.
7. Update `README.md` when adding a contribution, changing supported behavior,
   or leaving a notable feature unported.

## Zig conventions

- Target Zig 0.17; `zig build` must succeed without warnings.
- Pass allocators explicitly. Prefer `std.mem.Allocator` and the existing
  `std.array_list.Managed` shim unless the surrounding code already uses an
  unmanaged list.
- Every returned owned slice/map must have a clear owner and a `deinit`/`free`
  path. Use `defer` and `errdefer` for cleanup.
- Prefer `!T`, `try`, and typed errors over panics. `unreachable` is only for
  genuinely impossible enum/state branches.
- Do not add hidden global state. Services are passed through interfaces or
  owned by the editor/test.
- Keep lazy-analysis-friendly code: avoid unnecessarily forcing large
  tokenization or decoration work.
- Run `zig fmt` on changed Zig files.

## Interfaces

Zig has no `implements` keyword. Concrete types adapt to `I*` interfaces with a
single, explicit method:

```zig
pub fn interface(self: *Type) IType {
    return .{ .context = self, ... };
}
```

Rules:

- Every concrete adapter for an `I*` vtable exposes `interface()`.
- Do not introduce `toInterface`, `asInterface`, `asIFoo`, or similar variants.
- Existing call sites should use `.interface()`.
- Pure data structs (`IColorInformation`, `ISingleEditOperation`, etc.) are not
  adapters and do not need an `interface()` method.
- Interfaces store a `*anyopaque` context plus function pointers. Keep the
  context lifetime tied to the concrete object.

## Commands

Command structs implement the upstream `ICommand` contract with:

- `getEditOperations(model, builder)`
- `computeCursorState(model, helper)`
- `interface() ICommand` using `commandOf(T).of(self)`

Every ported command class must expose `interface()`. The TUI and helpers should
construct command vtable arrays with `.interface()` instead of calling
`commandOf` directly.

## Editor actions

Portable editor actions use `src/vs/editor/browser/editorExtensions.zig`:

- Keep action `id`, `label`, `description`, precondition, and keybinding
  metadata aligned with upstream.
- Implement `run` through an explicit callback or editor target.
- Register/execute through `EditorActionRegistry` when a runtime registry is
  available; otherwise expose the action from the contribution for TUI wiring.
- Do not skip an upstream action test merely because it requires a mock editor;
  adapt it to the TUI editor or a focused harness.

## Tests

### Test placement

Keep the upstream file/folder structure exactly:

```text
src/vs/editor/contrib/lineSelection/browser/lineSelection.zig
src/vs/editor/contrib/lineSelection/test/browser/lineSelection.test.zig
```

Do not move a contribution test to a separate parent tree, and do not rename it
to a custom `...Tests.zig` name. When touching a legacy test that does not match
the upstream path, move and rename it to match, then update `src/tests.zig`.

Port upstream tests completely:

- Copy every case and assertion from the upstream test file.
- Adapt browser/editor setup to the existing `TestModel`/TUI editor harness; do
  not delete assertions that are inconvenient to set up.
- Add integration tests in `src/tui/editor.zig` or `src/tui/app.zig` when the
  feature is wired into the TUI.
- Add a regression test for every bug found while porting.
- If a test exposes a latent model bug, fix the model instead of weakening the
  test.
- Use descriptive test names, including upstream test names where useful.

## Definition of done

Before reporting a port as complete:

```sh
zig build
zig build test --summary all
zig fmt --check <changed files>
git diff --check
```

Also verify:

- [ ] The portable upstream behavior and tests are present.
- [ ] New public command/interface adapters use `interface()`.
- [ ] Allocations have cleanup paths.
- [ ] TUI wiring and shortcuts are documented if applicable.
- [ ] README notes the ported scope and any remaining limitations.
- [ ] The working tree contains only intentional changes.
