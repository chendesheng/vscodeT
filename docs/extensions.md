# Extension system: reuse VS Code's host, port the editor side

Status: proposed design.

## 1. Context

The TUI editor has the portable editor core ported: text model, tokens, decorations,
commands, actions, and a language service. It has no extension system. Everything a user
configures today is either built in or hard coded in `src/tui/`.

VS Code's extension system has two halves that are worth separating:

1. **Declarative extensions.** A `package.json` declares contributions (`languages`,
   `grammars`, `commands`, `keybindings`, `configuration`, `themes`, ...). These never run
   code; the workbench scans them, validates them, and feeds the contributions into
   registries.
2. **Active extensions.** Code runs in a separate **extension host** process. The workbench
   and the host talk over an RPC protocol in which both sides expose named "actors"
   (`MainThreadCommands` on the workbench side, `ExtHostCommands` on the host side). The
   host loads the extension's `main` module, calls `activate(context)`, and the extension
   calls back into the workbench through the `vscode` module.

The first half is portable data logic and belongs in this repository, like the rest of
`src/vs/`. The second half is the part that must run JavaScript, and that is exactly what
VS Code already ships as ordinary Node code.

This document proposes how to get both: **reuse VS Code's extension host unmodified, and
port the workbench half (RPC codec, actors, scanner, contribution points, TUI wiring) to
Zig.**

Upstream reference: `../vscode` at version 1.108.0, commit `e5d4511`. Line counts below
are from that checkout.

## 2. Decisions

1. **Reuse the real extension host.** The host is a normal Node program. Only
   `src/vs/workbench/api/node/extensionHostProcess.ts` (475 lines) is Electron specific: it
   attaches `PersistentProtocol` to a `MessagePort` or socket and patches `process`. Below
   that, `ExtensionHostMain`, `ExtHostExtensionService`, `ExtensionsActivator`, the
   `vscode` API (`extHost.api.impl.ts`, `extHostTypes.ts`) and every `ExtHost*` actor are
   plain TypeScript over a `IMessagePassingProtocol` (send `VSBuffer` + `onMessage`).

   We replace the 475-line bootstrap with a small stdio launcher and keep the rest.

2. **No `vscode` shim, no vendoring.** The host code is loaded from a VS Code build that the
   user provides: `../vscode` compiled once (`npm ci && npm run compile`), or any checkout
   of the matching version pointed at by `--vscode-host-path` / `VSCODE_HOST_PATH`. The
   repository does not copy VS Code sources or build output into git.

3. **The transport is ours, the messages are not.** The launcher speaks
   `[u32 big-endian length][payload]` over stdio. The payload is a byte-for-byte RPC
   message as defined by `rpcProtocol.ts`; nothing inside the message changes.

4. **Zig owns the workbench side.** `rpcProtocol.zig`, the `MainThread*` actors, the
   manifest scanner, the contribution registry, and the TUI wiring live here, mirroring the
   upstream file layout.

5. **Actor identifiers must be identical.** `ProxyIdentifier.nid` is a static counter over
   the 150 identifiers in `extHost.protocol.ts`, assigned in file order and written on the
   wire as a `u8`. The Zig table is generated from that file and must contain the whole
   ordered list, including actors we do not implement, otherwise every call lands on the
   wrong actor.

6. **The editor loop stays single-threaded.** A reader thread drains the host's stdout into
   a frame queue and writes one byte to a self-pipe; `app.zig` polls stdin and the self-pipe
   together and calls `pump()`. Replies are callbacks, not promises; requests that need
   user input (quick pick, input box) stay pending until the TUI answers.

7. **JSON is the type system.** Message arguments are `std.json.Value`; handlers decode
   them and reply with JSON. `Uri` travels as `{ "$mid": 1, scheme, authority, path, query,
   fragment }`, `VSBuffer` travels as a binary argument, `undefined` travels as the JSON
   `null` in the simple encoding and as `ArgType.Undefined` in the mixed encoding.

8. **Trim the Node services loaded by the launcher.** The real bootstrap imports
   `extHost.common.services.js` plus `api/node/extHost.node.services.js`, which registers
   terminal, search, task, debug, authentication and tunnel services. We register the common
   singletons plus only the node services we support (extension service, storage paths,
   logger). This avoids native modules such as `node-pty` and keeps the unsupported
   features out of the API rather than half-working.

9. **Extensions degrade gracefully.** Missing `node` binary, missing host build, or a
   version mismatch all disable extensions with a clear message; the editor still runs.
   A host crash is reported, outstanding replies are rejected as canceled, and one restart
   is attempted.

10. **Declarative extensions work without a host.** Scanning, contribution points and
    activation-event triggers do not need the Node process. A machine without Node still
    gets contributed languages, grammars, themes, commands and settings.

## 3. Reuse map

| Upstream | Lines | Here |
|---|---|---|
| `api/common/extensionHostMain.ts` | 234 | reused |
| `api/common/extHostExtensionService.ts` | 1263 | reused |
| `api/common/extHostExtensionActivator.ts` | 454 | reused |
| `api/common/extHost.api.impl.ts`, `extHostTypes.ts` | 1953 + 3897 | reused |
| `vscode-dts/vscode.d.ts` | 21164 | reused (API surface of the host) |
| `api/common/extHost*.ts` actors | — | reused |
| `api/node/extensionHostProcess.ts` | 475 | **replaced** by `host/extensionHost.js` |
| Electron transport (`base/parts/ipc/common/ipc.net.ts`, `node/ipc.net.ts`) | 1189 + 968 | **replaced** by stdio framing |
| `services/extensions/common/rpcProtocol.ts` | 968 | ported to Zig |
| `services/extensions/common/proxyIdentifier.ts` | 85 | ported to Zig |
| `services/extensions/common/extensionHostProtocol.ts` | 153 | ported to Zig |
| `api/common/extHost.protocol.ts` | 3483 | actor table generated, subset of shapes ported |
| `platform/extensions/common/extensions.ts` | 551 | ported to Zig |
| `platform/extensions/common/extensionValidator.ts` | 430 | ported to Zig |
| `platform/extensionManagement/common/extensionsScannerService.ts` | 1082 | ported subset |
| `platform/extensionManagement/common/implicitActivationEvents.ts` | 87 | ported |
| `services/extensions/common/extensionsRegistry.ts` | 696 | ported |
| `services/extensions/common/extensionDescriptionRegistry.ts` | 423 | ported |
| `api/browser/mainThread*.ts` | — | ported subset |
| `base/common/buffer.ts`, `uri.ts`, `marshalling.ts`, `uriIpc.ts` | 499 + 750 + 84 + 163 | ported to Zig |

The rejected alternative is running `extensionHostProcess.js` itself over its Unix-socket
`IPCExtHostConnection`. That keeps the bootstrap, but requires porting `PersistentProtocol`
(frame types, flow control, keep-alive, reconnection) just to avoid a 150-line launcher.

## 4. Architecture

```
┌───────────────────── zig editor (one process) ──────────────────────┐
│ src/tui/app.zig ──poll(stdin, wakeup)──► ExtensionService           │
│                                           ├─ Scanner                 │
│                                           ├─ DescriptionRegistry     │
│                                           ├─ ContributionRegistry    │
│                                           └─ ExtensionHostManager    │
│                                                ├─ RpcProtocol        │
│                                                └─ MainThread* actors │
└──────────────────────────────┬──────────────────────────────────────┘
                stdin/stdout: [u32 BE len][RPC message]
┌──────────────────────────────▼──────────────────────────────────────┐
│ node host/extensionHost.js   (launcher, replaces the 475-line file) │
│   └─ upstream ExtensionHostMain                                     │
│        ├─ upstream RpcProtocol (JS)                                 │
│        ├─ upstream ExtHost* services                                │
│        └─ vscode module → extension activate()                      │
└─────────────────────────────────────────────────────────────────────┘
```

Activation stays host side, as upstream: the workbench sends `$activateByEvent` or
`$activate`, and the host's `ExtensionsActivator` resolves dependencies, loads the module
and calls `activate(context)`. The workbench keeps its own description registry so it can
answer "which extension contributes this command" and decide when an activation event
happened.

## 5. Wire protocol

Message layout, from `rpcProtocol.ts`:

```
[u8 messageType][u32 requestId] ...payload
```

| Type | Value | Payload |
|---|---|---|
| `RequestJSONArgs` | 1 | `u8 rpcId`, short string method, long string JSON args |
| `RequestJSONArgsWithCancellation` | 2 | same, plus a cancellation token argument on the receiving side |
| `RequestMixedArgs` | 3 | `u8 rpcId`, short string method, mixed argument array |
| `RequestMixedArgsWithCancellation` | 4 | same |
| `Acknowledged` | 5 | — |
| `Cancel` | 6 | — |
| `ReplyOKEmpty` | 7 | — |
| `ReplyOKVSBuffer` | 8 | buffer |
| `ReplyOKJSON` | 9 | long string JSON |
| `ReplyOKJSONWithBuffers` | 10 | `u32 count`, long string JSON, buffers |
| `ReplyErrError` | 11 | long string JSON error |
| `ReplyErrEmpty` | 12 | — |

Mixed argument array: `u8 count`, then per argument `u8 argType` (`1` string, `2` buffer,
`3` serialized object with buffers, `4` undefined). Strings are `u32` length + UTF-8;
"short" strings (method names) use a `u8` length. Buffers are `u32` length + bytes.

Behaviour we must preserve:

- The receiver sends `Acknowledged` **before** invoking the handler.
- `Cancel` maps to the `CancellationToken` handler for an in-flight request, if any.
- Errors serialize as `{ "$isError": true, name, message, stack, noTelemetry?, cause?, code? }`;
  other thrown values pass through as JSON.
- Reply JSON uses the "safe" stringifier: a value that cannot be stringified (cycles)
  becomes `null`.
- `SerializableObjectWithBuffers` replaces buffers in the JSON with `{ "$$ref$$": n }` and
  ships them as a side table.
- `undefined` becomes `null` in the simple encoding and `ArgType.Undefined` in the mixed
  encoding.
- URI arguments carry `$mid: 1` and are revived on the receiving side.
- Limits: one frame is capped at 64 MiB, method names at 255 bytes (the `u8` length).
- Unresponsive detection: while requests are unacknowledged for three seconds the protocol
  reports the remote side unresponsive.

## 6. Boot sequence

`ExtensionHostMain` receives its init data as the **first message** on the protocol, not as
an argument. The launcher and the manager must agree on this order:

1. host → `Ready` (single byte `2`).
2. workbench → init data JSON frame.
3. host → `Initialized` (single byte `1`).
4. workbench → `ExtHostWorkspace.$initializeWorkspace(workspace, trusted)`.
5. workbench → `ExtHostConfiguration.$initializeConfiguration(data)`.
6. workbench → `ExtHostExtensionService.$startExtensionHost(delta)`.
7. workbench → `$activateByEvent("*")`, then `onStartupFinished`, `onLanguage:<id>`,
   `onCommand:<id>` as they occur.

Steps 4 and 5 are mandatory before activation: `ExtHostExtensionService.initialize()`
awaits `_extHostWorkspace.waitForInitializeCall()`, and `activate()` reads configuration
synchronously. Skipping either leaves the host waiting forever.

`initData` is `IExtensionHostInitData`:

| Field | Value here |
|---|---|
| `version`, `quality` | host version (`1.108.0`), `"stable"` |
| `commit`, `date` | omitted (the host only compares `commit` when present) |
| `parentPid` | `0` (disables the parent watchdog) |
| `environment` | `appName: "zig-editor"`, `appHost: "node"`, `appRoot`, `appLanguage: "en"`, `appUriScheme`, `globalStorageHome`, `workspaceStorageHome`, `useHostProxy: false`, `skipWorkspaceStorageLock: true` |
| `workspace` | `{ id, name }`, or `null` for a single file |
| `extensions` | `{ versionId, allExtensions, activationEvents, myExtensions }` |
| `telemetryInfo` | empty strings; never sent anywhere |
| `logLevel`, `loggers`, `logsLocation` | `1`, `[]`, `file://` URI under the data dir |
| `autoStart` | `false`; the workbench drives `$startExtensionHost` |
| `remote` | `{ isRemote: false, authority: null, connectionData: null }` |
| `consoleForward` | `{ includeStack: false, logNative: false }` |
| `uiKind` | `1` (desktop) |

`ExtensionHostMain._transform` revives `extensionLocation`, `appRoot`,
`globalStorageHome`, `workspaceStorageHome`, `logsLocation` and `workspace`, so those
fields must be JSON URI components, not strings.

## 7. Main-thread actors

Ported to `src/vs/workbench/api/browser/mainThread*.zig` (upstream location), registered on
the Zig `RpcProtocol` by actor id.

| Actor | Methods |
|---|---|
| `MainThreadExtensionService` | `$getExtension`, `$activateExtension`, `$onWillActivateExtension`, `$onDidActivateExtension`, `$onExtensionActivationError`, `$onExtensionRuntimeError` |
| `MainThreadErrors` | `$onUnexpectedError` |
| `MainThreadConsole` | `$logExtensionHostMessage` |
| `MainThreadTelemetry` | `$publicLog`, `$publicLog2` (drop) |
| `MainThreadStorage` | `$initializeExtensionStorage`, `$setValue` |
| `MainThreadWorkspace` | `$save`, `$saveAll`, `$checkExists`, `$updateWorkspaceFolders` |
| `MainThreadConfiguration` | `$updateConfigurationOption`, `$removeConfigurationOption` |
| `MainThreadCommands` | `$registerCommand`, `$unregisterCommand`, `$executeCommand` |
| `MainThreadDocuments` | `$tryOpenDocument`, `$tryCreateDocument`, `$trySaveDocument` |
| `MainThreadTextEditors` | `$tryShowTextDocument`, `$tryShowEditor`, active-editor notifications |
| `MainThreadLanguages` | `$changeLanguage`, `$getLanguages` |
| `MainThreadLanguageFeatures` | hover, completion, definition, document symbols, code actions, formatting (handle based) |
| `MainThreadDiagnostics` | `$changeMany`, `$clear` |
| `MainThreadStatusBar` | `$setEntry`, `$disposeEntry` |
| `MainThreadMessageService` | `$showMessage` |
| `MainThreadWindow` | `$openUri`, `$asExternalUri` |
| `MainThreadClipboard` | `$readText`, `$writeText` |

Boot-critical are ExtensionService, Errors, Console, Telemetry, Storage, Workspace and
Configuration; without them the host either fails activation or hangs at startup.

Actors we do not implement stay unregistered. Calls to them reject with an explicit
"not supported by this host" error, which the extension sees as a rejected promise instead
of a hang. The upstream `assertRegistered(every MainContext identifier)` check is not
ported for that reason.

## 8. Declarative extensions

Ported to `src/vs/platform/extensionManagement/common/extensionsScannerService.zig`,
`src/vs/platform/extensions/common/extensionValidator.zig`, and
`src/vs/workbench/services/extensions/common/{extensionsRegistry,extensionDescriptionRegistry}.zig`.

Scan roots: bundled extensions, `~/.local/share/zig-editor/extensions/<publisher>.<name>-<version>/`,
and every `--extension-development-path`. For each directory we read `package.json`,
normalise the identifier, apply defaults, validate with `extensionValidator`, and keep the
manifest JSON arena for the process lifetime because contribution values borrow from it.

Deliberate deviation: no profile scanning, no `extensions.*.cache` files, no mtime
bookkeeping. Upstream is 1082 lines mostly because of that machinery; we rescan at startup.

Contribution points ported first: `commands`, `languages`, `grammars`, `themes`,
`configuration`, `keybindings`. Each is an `ExtensionPoint(T)` with a handler that receives
`(users, delta)` and applies additions, removals and changes. `ImplicitActivationEvents`
turns contributions into activation events (`onCommand:` for each command, `onLanguage:`
for each language and grammar), so an extension without explicit `activationEvents` still
activates.

Activation triggers on the workbench side:

| Event | Fired when |
|---|---|
| `*` | host is ready |
| `onStartupFinished` | first frame painted |
| `onLanguage:<id>` | a model with that language opens |
| `onCommand:<id>` | a contributed command is about to run |
| `workspaceContains:<glob>` | the workspace root matches |
| `onDebug`, `onView`, `onUri`, `onFileSystem` | never (unsupported, documented) |

## 9. TUI integration

| Feature | Where |
|---|---|
| Command palette (`Ctrl+Shift+P`) | new `src/tui/palette.zig`, TUI-only |
| Quick pick / input box | new `src/tui/quickInput.zig`, backs `window.showQuickPick` / `showInputBox` |
| Status bar | bottom row in `src/tui/render.zig` |
| Diagnostics | markers stored on the model, painted as gutter marks + status count |
| Contributed languages | replace the hard-coded map in `src/tui/language.zig` |
| Contributed grammars | register with the existing `textMateTokenizer.zig` |
| Contributed themes | map `tokenColors` foregrounds to the ANSI palette in `src/tui/theme.zig` |
| Contributed keybindings | `src/vs/platform/keybinding/common/keybindingsRegistry.zig` + `input.zig` dispatch |
| Configuration | defaults from `contributes.configuration`, user settings file, `getConfiguration()` |
| Documents | model open/change/close events pushed to the host as deltas, not full text |

`src/tui/extensions.zig` owns the service: scan, build the registry, attach contribution
handlers, start the host, pump messages, fire activation events, and deactivate on quit.
`app.zig` gains a `pump()` call in the main loop and an extra file descriptor in the input
poll.

## 10. Roadmap

Each stage lands green (`zig build`, `zig build test --summary all`, `zig fmt`, clean
`git diff --check`) and updates this document.

**S0 — spike.** `host/extensionHost.js` plus a JS driver: real `ExtensionHostMain` boots,
a fixture extension reaches `activate()`, the boot call list is captured and recorded here.

**S1 — foundation codecs.** `buffer.zig` (`VSBuffer`), `uri.zig` (`UriComponents`, parse,
`joinPath`, `$mid`), `marshalling.zig`, `marshallingIds.zig`, `errors.zig`
(`SerializedError`, `transformErrorForSerialization`). Ports `buffer.test.ts` and the
implemented part of `uri.test.ts`.

**S2 — manifest and scan.** `platform/extensions/common/extensions.zig`,
`extensionValidator.zig`, `extensionsScannerService.zig`,
`implicitActivationEvents.zig`, `extensionDescriptionRegistry.zig`. Ports
`extensionValidator.test.ts`, `extensions.test.ts`,
`extensionDescriptionRegistry.test.ts`.

**S3 — contributions and TUI.** `extensionsRegistry.zig`, `commands.zig`,
`contextkey.zig` + `scanner.zig`, `keybindingsRegistry.zig`, the contribution points from
§8, palette, quick input, status bar, diagnostics. Ports `commands.test.ts` and the
contextkey suites.

**S4 — RPC.** `proxyIdentifier.zig`, `rpcProtocol.zig`, `extensionHostProtocol.zig`,
`ipc.zig`, `ipc.stdio.zig`, generated `extHost.protocol.zig`. Ports the full
`rpcProtocol.test.ts` and adds golden hex vectors captured from the real host.

**S5 — manager and actors.** `extensionHostManager.zig`, `extensionHostProxy.zig`, and the
`mainThread*.zig` set from §7, boot-critical first.

**S6 — launcher and harness.** `host/package.json`, `scripts/setup-ext-host.sh`, fixture
extensions, `zig build test-e2e`.

**S7 — end to end and docs.** `src/tui/extensions.zig`, `app.zig` wiring, README scope and
limitations, this document's status.

## 11. Testing

- **Ported upstream suites** for everything ported to Zig.
- **Golden vectors**: messages captured from the real host, stored as hex, asserted by the
  Zig codec and by the Node launcher, so the two implementations cannot drift.
- **Integration**: spawn the real host with a fixture extension and assert activate-once,
  dependency ordering, command round-trip, status bar, diagnostics, configuration and
  clean deactivation.
- **Hermetic vs e2e**: `zig build test` stays hermetic; `zig build test-e2e` needs the built
  host and Node.

## 12. Deferred / explicit limitations

- Electron transport, `PersistentProtocol`, socket reconnection.
- Remote extension hosts, marketplace install and update, profiles.
- Proposed APIs and `engines.vscode` proposal checks.
- Webviews, terminals, debug, SCM, notebooks, chat, tasks, tree views, custom editors,
  authentication, tests API: the host exposes them, calls reject.
- Localisation bundles (`nlsBaseUrl` is omitted).
- Windows named pipes are not implemented yet; stdio framing is the only transport.

## 13. Open questions

1. Node version floor: the host build targets the Node version VS Code bundles (20+);
   should we pin and check it at startup?
2. Host discovery: `--vscode-host-path`, `VSCODE_HOST_PATH`, `../vscode/out`, or a
   downloaded release? Proposed order is the same, first hit wins.
3. Storage: the host can persist mementos itself (`globalStorageHome`/`workspaceStorageHome`
   are passed in), but upstream routes them through `MainThreadStorage`. Doing it host-side
   is simpler; it diverges from upstream for remote setups we do not support anyway.
4. Should `onStartupFinished` fire before or after the first paint when a file is opened
   from the command line?
