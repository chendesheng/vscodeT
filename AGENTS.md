# AGENTS.md — porting rules for vscodeT

This repository is a Zig 0.17 port of VS Code editor internals. The upstream
checkout is expected at `vscode/`. Upstream source paths therefore start with:

```
vscode/src/vs/editor/...
```

Do not edit upstream files. Port behavior into this repository instead.

`vscode/` and `vscode-textmate/` are shallow git submodules. `vscode/` is
pinned to VS Code 1.147.0 at commit
`e31c2e52f563620846caab877103f630ea361b9c`; `vscode-textmate/` is pinned to
v9.3.2 at commit `5fc1758043624ace930a2b417259852e534668d8`. Initialize both
with `git submodule update --init --depth 1`. Do not bump either pin in an
unrelated change: the generated extension-host protocol table and the port
inventory are tied to the `vscode` commit.

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

## Standalone vscode-textmate port

- `textmate/` is a standalone Zig package outside `src/` porting the
  `vscode-textmate/` submodule (currently v9.3.2). It must not import anything
  from `src/`.
- Keep upstream basenames (`matcher.ts` → `matcher.zig`) and port the upstream
  tests. See `textmate/README.md` for the source map, status, faithful-port
  rules and remaining integration work. The engine and all upstream test
  suites (including the copied `test-cases/` fixtures) are ported.
- Token indices are UTF-16 code units, matching vscode-textmate; only
  `OnigString` converts at the Oniguruma boundary. Do not replace this with
  UTF-8 byte offsets.
- The editor uses this package through `ITokenizationSupport` in
  `src/vs/editor/common/model/tokens/textMateTokenizer.zig`. The old
  `textmate.zig` dependency has been removed; do not reintroduce it. Keep the
  editor's adapter boundary explicit: the port works in UTF-16 code units,
  while editor text and token offsets are UTF-8 bytes.

## Standalone UI library

- `ui/` is a separate Zig package outside `src/` (a path dependency in
  `build.zig.zon`). It must not import anything from `src/`.
- There is no CSS parser, no selector engine and no HTML parser. Node styles
  are authored `Style` declarations; an unset field inherits from the parent's
  `ComputedStyle` when CSS makes the property inherited, otherwise it uses the
  initial value. A CSS class is an integer ID into the document's array-backed
  stylesheet (`ui.css.StyleTable`); `addClass`/`setClasses` pass IDs or enum
  names, never style records. See `docs/css.md`.
- Editor `.css` files are ported by hand to a sibling `*_css.zig` module with a
  disjoint `u16` class-ID range, a `Class` enum, a `styles` array and a
  `ui.css.Sheet`; register it in
  `src/vs/editor/browser/editorCss.zig`. Do not add a CSS parser or generator.
- The renderer is a double-buffered cell grid with an ANSI frame diff; see
  `docs/terminal-ui.md`. Library tests read `Surface.grid()`, not ANSI strings.
- Layout runs on the derived box tree in `ui/src/layout/box.zig`, never on DOM nodes:
  viewport root, principal element boxes, anonymous inline/flex-item boxes and
  text boxes. `ui/src/layout/layout.zig` solves that tree; `ui/src/render/paint.zig` walks it. Copy
  geometry back to DOM rects only at the measurement boundary.
- Invalidation is WebKit-like: DOM mutations notify the attached box tree,
  which marks boxes/tree dirty (`needs_rebuild`, `needs_layout`). Do not add a
  document-level revision or dirty flag.
- **Use TermDOM and WebKit as the reference implementations for this layer.**
  When adding or changing UI behavior, read the corresponding implementation
  and mirror its structure and rules before inventing a new one:
  - [TermDOM](https://github.com/bikeshaving/termdom) for the terminal
    pipeline: box derivation over the DOM, cell painting and paint order,
    background propagation (`setCell` keeps the existing cell background
    unless the box owns one), frame diffing, ANSI encoding and cursor
    handling.
  - [WebKit](https://github.com/WebKit/WebKit) for the browser architecture:
    the separate `Layout::Box` tree, block/inline/flex formatting contexts,
    layout invalidation and style-driven dirtying.
  Reimplement the behavior in Zig; do not copy code (TermDOM is MIT, WebKit is
  LGPL-2.1/BSD). When a terminal constraint forces a deviation (no CSS parser or
  selectors, no subpixel units, no HTML parser), state it in the file comment and in
  `docs/terminal-ui.md`. Lightpanda remains a reference for DOM linking and
  ownership only; it has no layout engine.
- Keyboard events and focus live in `ui/src/dom/event.zig`; terminal byte decoding is
  `ui/src/terminal/input.zig`. Key events capture/target/bubble and only `key_down` exists.
  Focus uses `Document.activeElement`, `Element.focusable` / `tab_index`, and
  `focus`/`blur` plus bubbling `focusin`/`focusout`; Tab is a default action,
  not a global shortcut. Keep these rules in the library, not in `src/tui/`.
- TUI integration (terminal raw mode/read loop, status) stays in `src/tui/`.
  `src/tui/editorView.zig` is the editor view on the `ui` tree: it owns the
  retained line window and retained chrome parts (gutter, scrollbar, widgets,
  status) and drives the `ui` Surface and box tree. Do not rebuild the whole
  document per frame; `Document.clear` is only for document creation or reset.
  A viewport change must resize the `ui.Surface` in place and discard only the
  line window, not the retained chrome. The read-only `--preview` variant is
  the `runPreview` path in `src/tui/app.zig`.
- Widgets and view contributions ported from `src/vs/editor/contrib/...` build
  their view on this document; keep their model/state code upstream-shaped and
  put only the terminal DOM adaptation in the widget. Sidebar/preview/read-loop
  code must not re-implement focus or key dispatch that the library owns.
  The find contribution is the first consumer: `findState`/`findModel` are the
  model, `findWidget` is the terminal view, and `findController` wires state,
  model, widget and the view's decoration sink.
- `zig build test` builds and runs `ui/tests/tests.zig` alongside the editor tests;
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
5. **Port the view logic too, not just the model or controller.** When a
   contribution has browser view parts (view lines, decorations, widgets,
   overlays, hit testing, rendering decisions), port the portable view logic
   and keep its data flow, names, decoration kinds/classes, option values and
   ordering close to upstream. Browser DOM/CSS/event plumbing is replaced by
   the terminal `ui` layer; the surrounding behavior is still ported.
6. Keep the implementation close to VS Code's structure. Prefer the upstream
   pipeline over a new one: model -> view model -> line decorations -> renderer,
   or contribution -> view part -> paint. Adapt only the terminal boundary
   (cells, clipping, focus/input routing). Do not replace a portable view layer
   with an ad hoc widget just because it is shorter.
7. A view behavior may be left unported only when:
   - the terminal has no corresponding capability (for example DOM/CSS layout
     effects, subpixel rendering, browser text selection/IME); or
   - porting it would require the infrastructure of a full web browser
     (HTML/CSS parser, event loop, compositor, Web APIs), which this project
     deliberately does not have.

   State the exact reason in the file header, in `README.md`, and in
   `docs/terminal-ui.md` when the limitation is in the UI library. Do not use
   these exceptions for work that is merely larger than expected.
8. Do not invent behavior that upstream does not have. If a shortcut or command
   is TUI-specific, say so.
9. Update `README.md` when adding a contribution, changing supported behavior,
   or leaving a notable feature unported.
10. **Port upstream event and state flows faithfully.** Do not invent a
    parallel mechanism (a revision counter, snapshot poll, dirty flag, or
    similar) when upstream already has an event or callback for the same
    transition. Port the upstream trigger, event, handler and ordering, using
    the existing ported contracts such as `ViewModelEventDispatcher` and
    `ViewEventHandler`. For example, `ViewModelImpl.setHiddenAreas` emits
    `ViewFlushedEvent`, `ViewLineMappingChangedEvent` and
    `ViewDecorationsChangedEvent`; the port must emit those events rather than
    detect the change later by comparing state. A terminal/browser adapter may
    replace the plumbing, but not the event flow itself.
11. **Do not add a polling layer.** Never add `workbench.poll*`/`editor.poll*`
    ticks, snapshot-comparison loops, revision counters or similar state
    scans to detect transitions. If the needed event surface does not exist,
    port the upstream emitter, handler and lifecycle first. The TUI read loop
    may poll file descriptors and terminal input for I/O readiness, but model,
    view, cursor or content state must be driven by the ported events.

## Fixing bugs

1. **Compare with upstream before changing anything.** Find the upstream file
   named in the Zig file's header comment and read the corresponding code and
   tests at the pinned `vscode/` commit. A reported problem is usually a
   deviation from that code, not a missing feature.
2. **Port the upstream behavior literally** unless the problem is specific to:
   - the terminal UI layer (`ui/`, `src/tui/`), which replaces the browser DOM,
     CSS and event plumbing; or
   - the UTF-16 ↔ UTF-8 boundary (token offsets, `OnigString`, string slices).

   For everything else — defaults, control flow, argument handling, event order,
   error reporting — copy upstream, including values it leaves implicit (for
   example a defaulted parameter that upstream passes as `true`).
3. Do not patch the symptom locally when the upstream implementation fits. Fix
   the ported line so the Zig code reads like the upstream code, and state any
   unavoidable UI/UTF-16 adaptation in the file header.
4. Add a regression test that fails before the fix. A change that only silences
   a diagnostic without restoring the upstream behavior is not a fix.
5. **Prove CI fixes in CI.** A CI failure is fixed only when the fix is
   committed, pushed and the workflow run for that commit passes. Local
   `zig build test` is necessary but not sufficient: CI runs Linux, macOS and
   Windows, and platform-specific or timing-sensitive failures may not
   reproduce locally. Never report CI as fixed while the change is uncommitted,
   unpushed or its run is still in progress. Fetch `origin/main` first; if the
   remote already contains the fix, sync with it instead of pushing a duplicate.

## Faithful porting and performance ownership

- Port VS Code faithfully and literally. Keep the upstream file, type, method,
  event, dirtying and render-pipeline structure. When upstream has a `View`,
  `ViewPart`, `render()` / `_flushAccumulatedAndRenderNow()` or a view-part
  lifecycle, port that pipeline; do not replace it with a terminal-only
  `View.rebuild`, `View.resize` or similar collapsed method.
- Terminal adaptations belong at the boundary: cell-grid painting, `ui` DOM
  nodes and styles, input/focus routing and terminal capabilities. Control
  flow, state transitions, event ordering and part structure stay
  upstream-shaped.
- Performance work belongs in `ui/` as much as possible. Optimize the
  DOM/box/layout/paint/frame/ANSI primitives instead of adding caches,
  revisions, fast paths or special cases to ported editor/workbench code. An
  editor-side performance change is allowed only when it mirrors an upstream
  optimization; a verified upstream divergence must be documented in the file
  header, `README.md` and `docs/terminal-ui.md` before it is relied on.
- A collapsed terminal-only renderer is debt to remove, not a pattern to
  extend. When touching one, move the behavior into the upstream-shaped
  `View`/view-part pipeline and keep only the terminal boundary adapter.

## View and rendering ports

- Port the view-side behavior as part of the contribution: decorated ranges,
  line/decoration rendering, widget layout and state, hover/selection/cursor
  paint order, hit testing and focus/input handling. A model-only port is not
  complete when upstream renders observable UI from that model.
- Keep upstream concepts and names where practical: view model, line
  decorations, inline decoration classes/kinds, `getViewLineData`, view parts,
  and contribution/view/widget boundaries. The terminal implementation may
  replace DOM nodes with `ui` nodes and CSS rules with typed class records or
  direct `Style`/cell attributes, but the decision-making logic and order
  should match.
- Reuse the existing ported layers (`viewModelDecorations`, `lineDecorations`,
  `viewLineRenderer`, the `editorBrowser` widget contracts) instead of
  inventing a parallel path. For example, bracket and find highlights go
  through model decorations and `LineDecoration.filter`/`extractWrapped`, the
  same route VS Code's ViewLine uses, before the terminal maps classes to
  cells.
- Terminal constraints are expected at the paint boundary: no CSS selectors or
  parser, no subpixel geometry, no DOM, fixed cells. Declarations do cascade
  through `ui.Style`/`ui.ComputedStyle` and typed class records; use that layer
  instead of inventing per-widget style tables. Implement the closest terminal
  rendering, document the substitution in the file header, and keep the
  upstream behavior and tests intact.
- When a view part is genuinely browser-only (full HTML/CSS engine, browser
  event loop, compositor, native selection), isolate the missing piece, port
  the portable state/commands, wire what the TUI can support, and document the
  exact gap in `README.md` and `docs/terminal-ui.md`.
- Port upstream `View`/`ViewPart` orchestration (`render`,
  `_flushAccumulatedAndRenderNow`, `shouldRender`/`prepareRender`/`render`).
  Do not add a terminal-only `rebuild`/`resize` method; rendering and size
  changes flow through the upstream layout/configuration and view-event
  contracts.
- Performance optimizations go into `ui/`; a ported view must not accumulate
  non-upstream caches or fast paths. An editor-side optimization is acceptable
  only when it mirrors an upstream one.

### Porting CSS files

When a ported widget needs rules from an upstream `.css` file, port that file
by hand instead of copying the styling decisions into the widget:

1. Put the port beside the upstream CSS, with `_css.zig` appended to the
   basename: `.../viewLines/viewLines.css` ->
   `.../viewLines/viewLines_css.zig`. Start with
   `// Port of .../viewLines.css.` and list the browser-only rules that are
   omitted.
2. Assign a disjoint `u16` class-ID block in the table in `docs/css.md`.
   Export a `Class` enum whose variants are named after the CSS classes and
   whose values are `base + index`, a `styles` array in the same order, and a
   `ui.css.Sheet { .base = base, .styles = &styles }`.
3. Register the sheet in `src/vs/editor/browser/editorCss.zig`. The document
   owns the array; `Document.clear()` preserves it. Re-register a range for a
   themed sheet; do not rebuild class tables in each widget.
4. Attach rules with `Node.addClass` / `Node.setClasses` using the enum names.
   Keep inline `Style` only for computed geometry or values that cannot be a
   class rule. Class list order is the cascade order; inline style wins.
5. Resolve `var(--vscode-*)` at the TUI boundary by passing resolved colors
   into the sheet. There is no custom-property engine. Omit selectors,
   descendant matching, `!important`, media queries, animations, transitions,
   `box-sizing`, radii, shadows and unit conversion; state the omission in the
   file header and `docs/css.md`.
6. Test the registration (`editorCss.zig`), the class attachment and the
   resulting box/cell style, and keep the existing widget behavior and tests
   intact. Update `docs/css.md` and the ported-file table when adding a sheet.

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

### Disk space

- Build caches are disposable and can grow to many gigabytes. Check `df -h`
  before and after large builds, and clean the build cache before free space is
  exhausted instead of waiting for `NoSpaceLeft` or a corrupted build.
- The normal cache to remove is the workspace build cache, for example
  `.zig-cache/` (including its `global/` subdirectory); `zig-out/` and
  temporary Zig caches outside the repository are also disposable. Rebuild
  after clearing.
- Delete only build caches. Never delete source files, `zig-pkg/`, docs, or
  anything under `vscode/`, and verify the resolved path before removing a
  directory.

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
- [ ] View-side behavior is ported through the upstream-shaped layers, not only
      the model/controller; any terminal/browser-infrastructure exception is
      documented in the file header and `README.md`.
- [ ] Ported view/render code keeps the upstream `View`/`ViewPart`/event
      structure; no terminal-only `rebuild`/`resize` method was added.
- [ ] Performance work is in `ui/` or is a documented, verified upstream
      difference.
- [ ] New public command/interface adapters use `interface()`.
- [ ] Allocations have cleanup paths.
- [ ] TUI wiring and shortcuts are documented if applicable.
- [ ] README notes the ported scope and any remaining limitations.
- [ ] Build caches were checked and cleaned as needed; the filesystem still has
      free space.
- [ ] The working tree contains only intentional changes.
- [ ] For a CI fix, the fix is committed, pushed, and the CI run for that
      commit has passed (or any remaining failure is reported explicitly).
