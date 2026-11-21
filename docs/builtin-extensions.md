# Built-in extensions

A built-in extension is a Zig value registered at the product composition root.
It is compiled into the editor and receives the same focused extension API as a
future native extension; it is not a `.vsix` and does not run in the Node
extension host.

## Contract

`src/vs/workbench/api/common/extensionApi.zig` defines:

- `IBuiltinExtension`: id, display name, version, `activate` and `deactivate`.
- `IExtensionContext`: commands, raw key input, editor access, window/status,
  workspace/configuration and a per-extension disposable store.
- `ITextEditor`: the editor operations a built-in extension may use. It never
  exposes `Editor` or `Workbench` directly.

`BuiltinExtensionRegistry` (`src/vs/workbench/api/common/builtinExtension.zig`)
owns activation and one disposable store per extension.

## Key input

`src/vs/workbench/api/common/keyInput.zig` defines the generic contribution
point:

```zig
pub const Handler = struct {
    context: *anyopaque,
    priority: KeyInputPriority,
    is_enabled: ?*const fn (context: *anyopaque) bool,
    handle: *const fn (context: *anyopaque, event: *const KeyInputEvent) anyerror!bool,
};
```

The host dispatches to registered handlers after modal UI and before workbench
global/tab shortcuts. A handler returns `true` to consume the event and `false`
to pass it on. Registration returns an `IDisposable`.

This is intentionally different from VS Code extension keybindings:

- keybindings dispatch a command id and cannot carry printable text;
- a modal editor needs the ordered key stream;
- the handler is synchronous and in-process for native extensions.

Node extensions keep the existing `vscode` bridge. They cannot use the raw key
handler without a future RPC addition.

## Host and composition

`src/vs/workbench/api/browser/builtinExtensionHost.zig` adapts workbench/editor
services to the interfaces. `src/tui/app.zig` decides which built-ins to
register; the workbench/editor core has no Vim import.

## Lifecycle

- `activateAll` creates a disposable store per extension and passes a context.
- Activation failures are reported and the extension is disabled.
- `deactivateAll` calls `deactivate` and disposes every registration in reverse
  order.
- The product composition root owns the registry; the editor core only sees the
  generic interfaces.
