# Extension system: reuse VS Code's host, port the editor side

Status: proposed design.

Upstream reference: `../vscode` at **1.147.0**, commit
`e31c2e52f563620846caab877103f630ea361b9c`. The actor table, method
inventory, init-data shape and line counts below were taken from that tree.
They are version-specific: upgrading the host invalidates the generated
protocol table, so the host version is pinned and checked at startup (see
§2.5 and §6.4). This document replaces an earlier draft that referenced
1.108.0.

## 1. Context

The TUI editor has the portable editor core ported: text model, tokens,
decorations, commands, actions, and a language service. It has no extension
system. Everything a user configures today is either built in or hard coded
in `src/tui/`.

VS Code's extension system has two halves that are worth separating:

1. **Declarative extensions.** A `package.json` declares contributions
   (`languages`, `grammars`, `commands`, `keybindings`, `configuration`,
   `themes`, ...). These never run code; the workbench scans them, validates
   them, and feeds the contributions into registries.
2. **Active extensions.** Code runs in a separate **extension host** process.
   The workbench and the host talk over an RPC protocol in which both sides
   expose named "actors" (`MainThreadCommands` on the workbench side,
   `ExtHostCommands` on the host side). The host loads the extension's `main`
   module, calls `activate(context)`, and the extension calls back into the
   workbench through the `vscode` module.

The first half is portable data logic and belongs in this repository, like
the rest of `src/vs/`. The second half is the part that must run JavaScript,
and that is exactly what VS Code already ships as ordinary Node code.

This document proposes how to get both: **reuse VS Code's extension host
unmodified, and port the workbench half (RPC codec, actors, scanner,
contribution points, TUI wiring) to Zig.**

## 2. Decisions

1. **Reuse the real extension host.** The host is a normal Node program. Most
   of `src/vs/workbench/api/common/extensionHostMain.ts` (239 lines),
   `extHostExtensionService.ts` (1264), `extHostExtensionActivator.ts` (454),
   the `vscode` API (`extHost.api.impl.ts`, `extHostTypes.ts`) and every
   `ExtHost*` actor are plain TypeScript over an
   `IMessagePassingProtocol` (send `VSBuffer` + `onMessage`).
   `api/node/extensionHostProcess.ts` (475 lines) is the Node/Electron
   bootstrap; it is replaced by `host/extensionHost.js`.

2. **Pin the host, do not vendor it.** The host code is loaded from a VS Code
   build that the user provides: `../vscode` compiled once, or any checkout
   pointed at by `--vscode-host-path` / `VSCODE_HOST_PATH`. The repository
   does not copy VS Code sources or build output into git. It does keep the
   *generated* protocol table and method manifest, because those are part of
   this repository's protocol contract, not upstream code. A host whose
   `package.json` version or (when defined) `product.commit` does not match
   the pinned value is rejected before startup; extensions are disabled with a
   clear message.

3. **The transport is ours, the messages are not.** The launcher speaks
   `[u32 big-endian length][payload]` over **dedicated file descriptors**
   (3 and 4), not the host's stdin/stdout. The payload is a byte-for-byte RPC
   message as defined by `rpcProtocol.ts`; nothing inside the message
   changes. stdin/stdout remain available to the host, extension code and
   child processes without corrupting the RPC stream.

4. **Zig owns the workbench side.** `rpcProtocol.zig`, the `MainThread*`
   actors, the manifest scanner, the contribution registry, and the TUI
   wiring live here, mirroring the upstream file layout. `src/tui/` holds only
   the terminal adapter (palette, quick input, status row, key routing); the
   portable extension logic lives under `src/vs/`.

5. **Actor identifiers must be identical.** `ProxyIdentifier.nid` is a static
   counter over every `createProxyIdentifier` call, assigned in evaluation
   order and written on the wire as a `u8`. In 1.147.0 there are **171**
   identifiers: **89** in `MainContext` and **82** in `ExtHostContext`. The
   Zig table is generated from `extHost.protocol.ts` and must contain the
   whole ordered list, including actors we do not implement; otherwise every
   call lands on the wrong actor. The generator also emits a per-actor method
   manifest used to decide whether a request is supported, and asserts the
   count fits in a `u8`.

6. **The editor loop stays single-threaded.** A reader thread drains fd 3 into
   a frame queue and writes one byte to a self-pipe; `app.zig` polls stdin and
   the self-pipe together and calls `pump()`. Replies are callbacks, not
   promises; requests that need user input (quick pick, input box) stay
   pending until the TUI answers. `pump()` must also run on host-death and
   timer events, not only when a frame arrives.

7. **JSON is the type system.** Message arguments are `std.json.Value`;
   handlers decode them and reply with JSON. `Uri` travels as
   `{ "$mid": 1, scheme, authority, path, query, fragment }`, `VSBuffer`
   travels as a binary argument, and `undefined` has different encodings
   depending on context (see §5).

8. **Trim the Node services loaded by the launcher.** The real bootstrap
   imports `extHost.common.services.js` plus
   `api/node/extHost.node.services.js`, which registers terminal, search,
   task, debug, authentication and tunnel services. We register the common
   singletons plus the node singletons required by the extension service:
   `IExtHostExtensionService` (the **node** subclass, which installs
   `ExtHostConsoleForwarder`), `ILogService`, `ILoggerService`,
   `IExtensionStoragePaths` and `IExtHostTelemetry`. This avoids native
   modules such as `node-pty` and keeps the unsupported features out of the
   API rather than half-working.

9. **Extensions degrade gracefully.** Missing `node` binary, missing host
   build, or a version mismatch all disable extensions with a clear message;
   the editor still runs. A host crash is reported, outstanding replies are
   rejected as canceled, and one restart is attempted with the state resync
   described in §13.

10. **Declarative extensions work without a host.** Scanning, contribution
    points and activation-event triggers do not need the Node process. A
    machine without Node still gets contributed languages, grammars, themes
    and settings. Contributed commands can be listed, but executing one
    requires the host.

11. **Workspace trust is explicit.** Extension code is arbitrary code. The
    TUI decides the trust state for a workspace (see §12), passes it to
    `$initializeWorkspace`, and exposes it through `vscode.workspace.isTrusted`.
    The plan does not pretend that a terminal process is sandboxed.

12. **Interfaces and ownership follow the repository rules.** Services are
    passed explicitly, adapters expose `interface()`, and every owned frame,
    buffer and JSON arena has a `deinit` path.

## 3. Reuse map

| Upstream | Lines (1.147.0) | Here |
|---|---|---|
| `api/common/extensionHostMain.ts` | 239 | reused |
| `api/common/extHostExtensionService.ts` | 1264 | reused |
| `api/common/extHostExtensionActivator.ts` | 454 | reused |
| `api/common/extHost.api.impl.ts`, `extHostTypes.ts` | 2357 + 4345 | reused |
| `vscode-dts/vscode.d.ts` | 21506 | reused (API surface of the host) |
| `api/common/extHost*.ts` actors | — | reused |
| `api/node/extensionHostProcess.ts` | 475 | **replaced** by `host/extensionHost.js` |
| Electron transport (`base/parts/ipc/common/ipc.net.ts`, `node/ipc.net.ts`) | 1232 + 874 | **replaced** by fd framing |
| `services/extensions/common/rpcProtocol.ts` | 968 | ported to Zig |
| `services/extensions/common/proxyIdentifier.ts` | 85 | ported to Zig |
| `services/extensions/common/extensionHostProtocol.ts` | 157 | ported to Zig |
| `services/extensions/common/extensionHostProxy.ts` | 45 | ported to Zig |
| `api/common/extHost.protocol.ts` | 4434 | actor table and method manifest generated; subset of shapes ported |
| `platform/extensions/common/extensions.ts` | 627 | ported to Zig |
| `platform/extensions/common/extensionValidator.ts` | 391 | ported to Zig |
| `platform/extensionManagement/common/extensionsScannerService.ts` | 1111 | ported subset |
| `platform/extensionManagement/common/implicitActivationEvents.ts` | 87 | ported |
| `services/extensions/common/extensionsRegistry.ts` | 729 | ported subset |
| `services/extensions/common/extensionDescriptionRegistry.ts` | 423 | ported |
| `api/browser/mainThread*.ts` | — | ported subset (see §7) |
| `base/common/buffer.ts`, `uri.ts`, `marshalling.ts`, `uriIpc.ts` | 582 + 765 + 84 + 163 | ported to Zig |
| `base/common/json.ts` | 1344 | minimal JSONC subset ported to Zig |
| `base/common/semver/semver.js` | 52 (minified UMD) | small semver subset ported to Zig |

The rejected alternative is running `extensionHostProcess.js` itself over its
Unix-socket `IPCExtHostConnection`. That keeps the bootstrap, but requires
porting `PersistentProtocol` (frame types, flow control, keep-alive,
reconnection) just to avoid our launcher.

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
                fd 3 / fd 4: [u32 BE len][RPC message]
┌──────────────────────────────▼──────────────────────────────────────┐
│ node host/extensionHost.js   (launcher, replaces the 475-line file) │
│   └─ upstream ExtensionHostMain                                     │
│        ├─ upstream RpcProtocol (JS)                                 │
│        ├─ upstream ExtHost* services                                │
│        └─ vscode module → extension activate()                      │
└─────────────────────────────────────────────────────────────────────┘
```

The launcher reserves fd 3 for host→workbench frames and fd 4 for
workbench→host frames, or uses a socketpair on POSIX. The host's stdin and
stdout are left alone; the launcher redirects its own bootstrap logging to
stderr or a log file. This is the only way to coexist with extension code
that writes to stdout or spawns children with inherited stdio.

Activation stays host side, as upstream: the workbench sends
`$activateByEvent` or `$activate`, and the host's `ExtensionsActivator`
resolves dependencies, loads the module and calls `activate(context)`. The
workbench keeps its own description registry so it can answer "which
extension contributes this command" and decide when an activation event
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

Mixed argument array: `u8 count`, then per argument `u8 argType`
(`1` string, `2` buffer, `3` serialized object with buffers, `4` undefined).
Strings are `u32` length + UTF-8; "short" strings (method names) use a `u8`
length. Buffers are `u32` length + bytes. Request IDs are `u32` and start at
1 on each side.

Behaviour we must preserve:

- **The receiver invokes the handler first, then sends `Acknowledged`**
  (`rpcProtocol.ts:358-380`). A handler that synchronously sends a request
  does so before the ack. Do not "optimize" this by acking first; the
  ordering is observable.
- `Cancel` maps to the `CancellationToken` handler for an in-flight request,
  if any. Cancellation tokens are appended to the argument list on the
  receiving side; the sender sets the "WithCancellation" message type.
- Errors serialize as
  `{ "$isError": true, name, message, stack, noTelemetry?, cause?, code? }`;
  other thrown values pass through as JSON. A missing error serializes as
  `ReplyErrEmpty`.
- Replies use the "safe" stringifier: a value that cannot be stringified
  (cycles) becomes `null`. **Requests do not**; they use plain
  `JSON.stringify`, so a cyclic request argument throws before the message is
  sent. The Zig encoder should mirror this asymmetry, or reject cycles with a
  clear local error.
- `SerializableObjectWithBuffers` replaces buffers in the JSON with
  `{ "$$ref$$": n }` and ships them as a side table. `undefined` inside such
  an object becomes `{ "$$ref$$": -1 }` (`rpcProtocol.ts:42-62`).
- In the simple encoding, `undefined` in an **array** becomes `null`; an
  `undefined` **object property** is dropped by `JSON.stringify`. A top-level
  `undefined` argument forces the mixed encoding and uses
  `ArgType.Undefined`. Do not model all three cases as "undefined becomes
  null".
- URI arguments carry `$mid: 1` and are revived by the handler on the
  receiving side.
- Limits: the actor id and method-name length are `u8` (max 255); the
  generator asserts the actor count. The **64 MiB frame cap is our transport
  policy**, not an upstream `rpcProtocol` rule; enforce it on both sides and
  reject oversized frames with a typed error. A request with a method name
  longer than 255 bytes must fail locally, not be silently truncated.
- Unresponsive detection: the protocol starts a 3-second deadline when the
  first request becomes unacknowledged, resets it to `now + 3s` on every ack,
  and checks every second (`rpcProtocol.ts:182-219`). It reports the remote
  side unresponsive only while at least one request is outstanding.
- `dispose()` rejects outstanding replies as canceled. Shutdown uses
  `Terminate` (a 1-byte message with value 3), `drain()`, then closing the
  fds. `Terminate` is filtered by the host's protocol wrapper before the RPC
  layer sees it (`extensionHostProcess.ts:307-315`).

The Zig codec should be tested against golden frames captured from the real
host and against a reimplementation of `rpcProtocol.test.ts`; see §15.

## 6. Boot sequence and launcher

### 6.1 What the launcher must replace

Replacing `extensionHostProcess.ts` is more than opening two pipes. The
launcher must provide:

- Node `require` blocklist for the `natives` module and the
  `process.exit`/`process.crash` patches, or an explicit decision to omit
  them and document the divergence.
- `navigator` shadowing on Node versions where it is a global, unless
  `supportGlobalNavigator` is set.
- `unhandledRejection`, `rejectionHandled` and `uncaughtException` handlers.
- A `NodeHost` implementation (`pid`, `exit`, `fsExists`, `fsRealpath`) for
  `IHostUtils`.
- The init-data first-message handshake, `Ready`/`Initialized` bytes, the
  commit check, and `Terminate` filtering.
- Framing, partial reads/writes, backpressure, and fd lifecycle.
- Console/stdout isolation: the host's bootstrap logging must not reach the
  RPC channel, and the upstream `ExtHostConsoleForwarder` only takes over
  after the node extension service is constructed.
- On shutdown, EOF/fd close detection. If the host outlives the editor, the
  parent-pid watchdog may be used (the JS interval works even without
  `@vscode/native-watchdog`).

The launcher can import the compiled `ExtensionHostMain` and the trimmed
service modules from the host build. It does not need to modify upstream
files.

### 6.2 Order

`ExtensionHostMain` receives its init data as the **first message** on the
protocol, not as an argument. The launcher and the manager must agree on this
order:

1. host → `Ready` (framed 1-byte payload `2`).
2. workbench → init data JSON frame.
3. host → `Initialized` (framed 1-byte payload `1`).
4. workbench → `ExtHostWorkspace.$initializeWorkspace(workspace, trusted)`.
5. workbench → `ExtHostConfiguration.$initializeConfiguration(data)`.
6. workbench → `ExtHostExtensionService.$startExtensionHost(delta)`.
7. workbench → `$activateByEvent("*", ActivationKind.Normal)`, then
   `onStartupFinished`, `onLanguage:<id>`, `onCommand:<id>` as they occur.

Steps 4 and 5 are mandatory before activation: `ExtHostExtensionService`
awaits `_extHostWorkspace.waitForInitializeCall()`, and `activate()` reads
configuration synchronously. Skipping either leaves the host waiting forever.

Upstream triggers steps 4 and 5 from the constructors of
`MainThreadWorkspace` and `MainThreadConfiguration`. In Zig, call the ExtHost
proxies explicitly after the `Initialized` frame and before
`$startExtensionHost`, and keep the same ordering.

`$activateByEvent` takes a second `ActivationKind` argument (normally
`Normal`; `Immediate` is used for eager paths). `onStartupFinished` also
causes the host to call `$setPerformanceMarks` on
`MainThreadExtensionService`; that actor method must exist.

### 6.3 `initData`

`initData` is `IExtensionHostInitData` (`extensionHostProtocol.ts:28-87`):

| Field | Value here |
|---|---|
| `version`, `quality` | `"1.147.0"`, `"stable"` |
| `commit`, `date` | expected host commit for the mismatch check, date omitted |
| `parentPid` | the editor pid, so the JS watchdog can detect an orphan; `0` only if the launcher also handles EOF |
| `environment` | `appName: "zig-editor"`, `appHost: "node"`, `appRoot`, `appLanguage: "en"`, `appUriScheme`, `globalStorageHome`, `workspaceStorageHome`, `useHostProxy: false`, `skipWorkspaceStorageLock: true`, `isExtensionDevelopmentDebug: false`, `isExtensionTelemetryLoggingOnly: false` |
| `workspace` | `null` for a single file, or `IStaticWorkspaceData` (`id`, `name`, optional `transient`, `configuration`, `isUntitled`) |
| `extensions` | `{ versionId, allExtensions, activationEvents, myExtensions }` |
| `telemetryInfo` | `sessionId`, `machineId`, `sqmId`, `devDeviceId`, `firstSessionDate`; empty strings, never sent anywhere |
| `logLevel`, `loggers`, `logsLocation` | `1`, `[]`, `file://` URI under the data dir |
| `autoStart` | `false`; the workbench drives `$startExtensionHost` |
| `remote` | `{ isRemote: false, authority: null, connectionData: null }` |
| `consoleForward` | `{ includeStack: false, logNative: false }` |
| `uiKind` | `1` (desktop) |

`ExtensionHostMain._transform` revives `extensionLocation`, `appRoot`,
`extensionDevelopmentLocationURI`, `extensionTestsLocationURI`,
`globalStorageHome`, `workspaceStorageHome`, `nlsBaseUrl`, `logsLocation` and
`workspace`, so those fields must be JSON URI components, not strings.

`$initializeWorkspace` takes `IWorkspaceData`, which extends
`IStaticWorkspaceData` with `folders: { uri, name, index }[]`. A plain
`{ id, name }` is not enough when the workspace has folders.

### 6.4 Mismatch detection

The host only compares `initData.commit` to its own `product.commit` when
both are present (`extensionHostProcess.ts:341-349`). Two checks are needed:

1. The launcher reads the host build's `package.json` version and
   `product.commit` and, before spawning, compares them to the pinned values.
   Fail closed with a clear message if they differ.
2. `initData.commit` carries the expected host commit. The host's own check
   then catches a mismatched `--vscode-host-path` even if the launcher was
   pointed at the wrong tree.

The generated protocol table is only valid for one host version; the version
check is what makes that safe.

## 7. Main-thread actors

Ported to `src/vs/workbench/api/browser/mainThread*.zig` (upstream location),
registered on the Zig `RpcProtocol` by actor id. The table below is the
**baseline** for the first usable extension system, not the whole API. Counts
are from 1.147.0.

| Actor | Methods | Stage | Notes |
|---|---|---|---|
| `MainThreadExtensionService` | 8 | S5 | boot-critical named customer; includes `$setPerformanceMarks`, `$asBrowserUri` |
| `MainThreadErrors` | 1 | S5 | `$onUnexpectedError` |
| `MainThreadConsole` | 1 | S5 | console forwarding; fire-and-forget |
| `MainThreadTelemetry` | 2 | S5 | `$publicLog`, `$publicLog2` (drop) |
| `MainThreadStorage` | 3 | S5 | mementos; `$registerExtensionStorageKeysToSync` |
| `MainThreadWorkspace` | 20 | S5 | first cut: save/saveAll/checkExists/updateWorkspaceFolders/startFileSearch/startTextSearch/isResourceTrusted/requestWorkspaceTrust/resolveEncoding/validateDetectedEncoding/resolveDecoding |
| `MainThreadConfiguration` | 2 | S5 | `$updateConfigurationOption`, `$removeConfigurationOption`; push `$acceptConfigurationChanged` |
| `MainThreadCommands` | 5 | S5 | includes `$fireCommandActivationEvent`, `$getCommands` |
| `MainThreadDocuments` | 3 | S5 | `$tryOpenDocument`, `$tryCreateDocument`, `$trySaveDocument` |
| `MainThreadTextEditors` | 13 | S5 | show/options/selections/decorations/edits/snippets/diff |
| `MainThreadLanguages` | 5 | S5 | no `$getLanguages`; `$setLanguageStatus`/`$removeLanguageStatus` |
| `MainThreadLanguageFeatures` | 47 | S6 | first cut: hover, completion, definition, document symbols, code actions, formatting/range/on-type |
| `MainThreadDiagnostics` | 2 | S5 | `$changeMany`, `$clear` |
| `MainThreadStatusBar` | 2 | S5 | `$setEntry`, `$disposeEntry` |
| `MainThreadMessageService` | 1 | S5 | `$showMessage` |
| `MainThreadWindow` | 3 | S5 | `$getInitialState`, `$openUri`, `$asExternalUri` |
| `MainThreadClipboard` | 2 | S5 | `$readText`, `$writeText` |
| `MainThreadQuickOpen` | 6 | S3/S5 | backs `showQuickPick`/`showInputBox`; not `MainThreadWindow` |
| `MainThreadDialogs` | 2 | S5 | `$showOpenDialog`, `$showSaveDialog` |
| `MainThreadFileSystem` | 12 | S6 | `workspace.fs` for local files; provider registration deferred |
| `MainThreadOutputService` | 5 | S6 | output channels |
| `MainThreadProgress` | 3 | S6 | `withProgress` |
| `MainThreadSecretState` | 4 | S6 | `context.secrets` |
| `MainThreadEditorTabs` | 3 | S6 | `window.tabGroups` |

Easy-to-miss methods in actors the original draft listed:

- `MainThreadExtensionService.$setPerformanceMarks` and `$asBrowserUri`.
- `MainThreadStorage.$registerExtensionStorageKeysToSync`.
- `MainThreadCommands.$fireCommandActivationEvent` and `$getCommands`.
- `MainThreadWorkspace.$startFileSearch`/`$startTextSearch` (the
  `workspace.findFiles`/`findText` path) and the trust/encoding methods.
- `MainThreadTextEditors` decoration, selection, reveal, edit, snippet and
  diff methods. Active-editor changes are **not** here; they are
  `IDocumentsAndEditorsDelta.newActiveEditor` on
  `ExtHostDocumentsAndEditors.$acceptDocumentsAndEditorsDelta`.
- `MainThreadWindow.$getInitialState`.
- `MainThreadLanguages` has no `$getLanguages` in 1.147.0; `getLanguages()`
  is resolved from the language IDs already sent to the host.

Actors outside the baseline (authentication, bulk edits, language models,
chat, terminal, task, debug, SCM, notebooks, webviews, custom editors, tree
views, tests, comments, timeline, speech, MCP, GitHub, localization, file
decorations) stay unregistered. Promise-returning calls to them reject with
an explicit "not supported by this host" error; void notifications return
empty success (see below).

**Notification vs request policy.** RPC does not distinguish `void` methods,
but the host often fires them without awaiting. Returning an error for an
unimplemented notification produces host-side unhandled rejections. For
methods whose declared return type is `void` (for example
`$fireCommandActivationEvent`, `$logExtensionHostMessage`, `$publicLog`,
`$onDidActivateExtension`, `$setPerformanceMarks`), an unimplemented actor
should return `ReplyOKEmpty`. Only promise-returning methods should reject.
The generated method manifest records which is which.

The upstream
`assertRegistered(Object.keys(MainContext))` check in
`mainThreadExtensionService.ts:58` and `extensionHostManager.ts:315` is not
ported, because the baseline intentionally registers a subset. The generated
table still lets us detect an id that is out of range or has the wrong name.

## 8. Declarative extensions

Ported to
`src/vs/platform/extensionManagement/common/extensionsScannerService.zig`,
`src/vs/platform/extensions/common/extensionValidator.zig`, and
`src/vs/workbench/services/extensions/common/{extensionsRegistry,extensionDescriptionRegistry}.zig`.

Scan roots: bundled extensions, the user extensions directory
(`~/.local/share/zig-editor/extensions/<publisher>.<name>-<version>/`), and
every `--extension-development-path`. For each directory we read
`package.json`, normalise the identifier, apply defaults, validate with
`extensionValidator`, and keep the manifest JSON arena for the process
lifetime because contribution values borrow from it.

Deliberate deviations: no profile scanning, no `extensions.*.cache` files, no
mtime bookkeeping. Upstream is 1111 lines mostly because of that machinery;
we rescan at startup. The scanner still has to populate every field the host
uses: `identifier` (with `uuid`), `name`, `publisher`, `version`,
`extensionLocation`, `isBuiltin`, `extensionKind`, `targetPlatform`,
`preRelease`, `packageJSON`, `main`/`browser`, `engines`, `activationEvents`,
`contributes`, `extensionDependencies`, `extensionPack`, and
`enabledApiProposals`. A manifest missing these fields will fail activation
on the host even if the TUI can display it.

### 8.1 JSON, JSONC, semver and NLS

- `package.json`, `language-configuration.json` and theme files are JSONC.
  `std.json` rejects comments and trailing commas. Port a minimal JSONC
  subset from `base/common/json.ts`: line/block comments, trailing commas,
  string escapes, and parse errors with byte offsets. Test it against the
  bundled extensions in `../vscode/extensions`.
- `extensionValidator` needs `semver.valid`; the scanner's profile dedup uses
  `semver.gt`/`eq`. Port a small semver subset (parse, valid, compare,
  prerelease) unless the scanner drops profile dedup entirely, in which case
  `valid` and `compare` are enough. Name this in S3, not as an afterthought.
- Manifest localization (`package.nls.json`, `%key%` placeholders via
  `localizeManifest`) is skipped initially. Display names and descriptions
  stay in their default language; document this in `README.md`.

### 8.2 Contribution points

Ported first: `commands`, `languages` (including the `configuration` field
that points at `language-configuration.json`), `grammars`, `themes`,
`configuration`, `keybindings`. Each is an `ExtensionPoint(T)` with a handler
that receives `(users, delta)` and applies additions, removals and changes.
Validate the fields the TUI actually consumes; on an invalid contribution,
log the extension and drop that contribution instead of aborting the scan.

`ImplicitActivationEvents` turns contributions into activation events, but
the generators live with the contribution points:

- `commands` → `onCommand:<id>` for every valid command.
- `languages` → `onLanguage:<id>` **only when the language declares a
  `configuration`** (`languageService.ts:115-119`).
- `grammars` → **no implicit activation event**; grammars are declarative
  data and are loaded without activating the extension.
- `onUri` is rewritten to `onUri:<extension id>`.

Activation triggers on the workbench side:

| Event | Fired when |
|---|---|
| `*` | host is ready |
| `onStartupFinished` | after the first frame is painted |
| `onLanguage:<id>` | a model with that language opens |
| `onCommand:<id>` | a contributed command is about to run |
| `workspaceContains:<glob>` | the workspace root matches, via `$checkExists` |
| `onDebug`, `onView`, `onUri`, `onFileSystem` | never (unsupported, documented); `onUri` is rewritten to `onUri:<id>` but no URI handler event is fired |

## 9. Documents and editors

This is the largest subsystem after RPC and needs its own data flow, not one
table row.

- **Open/close.** The workbench pushes
  `ExtHostDocumentsAndEditors.$acceptDocumentsAndEditorsDelta` with
  `addedDocuments`/`removedDocuments` and `addedEditors`/`removedEditors`.
  Each `ITextEditorAddData` carries `id`, `documentUri`, `options`,
  `selections`, `visibleRanges`, `editorPosition`.
- **Active editor.** `newActiveEditor` on the same delta.
- **Content changes.** `ExtHostDocuments.$acceptModelChanged` carries
  `ISerializedModelContentChangedEvent` (deltas, not full text), `isDirty` and
  the version id. `$acceptModelSaved`, `$acceptDirtyStateChanged`,
  `$acceptEncodingChanged` and `$acceptModelLanguageChanged` cover the rest.
- **Host → workbench.** `$tryOpenDocument`, `$tryCreateDocument` and
  `$trySaveDocument` open/create/save the underlying TUI document.
  `$tryShowTextDocument` maps to the existing tab/group model and returns the
  editor id. `$tryShowEditor`/`$tryHideEditor` activate or hide it.
- **Edits.** `$tryApplyEdits` and `$tryInsertSnippet` must go through the
  editor's command/edit stack with the model version check, undo stops and
  selection restoration, not direct model mutation. `$trySetSelections`,
  `$trySetOptions`, `$tryRevealRange` and `$getDiffInformation` are the rest.
- **Decorations.** `$registerTextEditorDecorationType`,
  `$removeTextEditorDecorationType`, `$trySetDecorations` and
  `$trySetDecorationsFast` feed the existing line-decoration pipeline, not a
  parallel overlay.
- **Dirty/encoding.** The TUI owns the dirty bit and file encoding; push both
  to the host on change and answer save/encoding RPCs consistently.

The editor id is the host's identity for an editor instance; the TUI's tab id
can be used as that id as long as it is stable across focus changes. A host
editor that is hidden (not closed) must remain resolvable.

## 10. Language features

`MainThreadLanguageFeatures` is handle-based: the host registers a provider
and gets a numeric handle; later requests carry that handle. The baseline
subset is:

- hover (`$registerHoverProvider`)
- completion (`$registerCompletionsProvider`)
- definition (`$registerDefinitionSupport`)
- document symbols (`$registerDocumentSymbolProvider`)
- code actions (`$registerCodeActionSupport`)
- formatting (`$registerDocumentFormattingSupport`,
  `$registerRangeFormattingSupport`, `$registerOnTypeFormattingSupport`)

Each registration carries an `IDocumentFilterDto[]` selector. The workbench
stores the provider by handle, resolves the selector against the model's
language and scheme, invokes the provider, converts the result to the
editor's existing hover/suggest/symbol types, and returns it over RPC. The
existing `hoverProvider.zig`, `suggestController.zig` and hover participants
are the consumers; do not invent a parallel feature path.

Cancellation, resolve (`CompletionItem.resolve`, code action resolve) and
provider disposal (`$unregister`) are part of the contract. Semantic tokens,
inlay hints, code lens, links, colors, folding, selection ranges, call/type
hierarchy, inline completions, paste/drop edits and notebook-related features
are deferred; the method manifest marks them unsupported so the host sees a
clear rejection rather than a hang.

## 11. TUI integration

| Feature | Where |
|---|---|
| Command palette (`Ctrl+Shift+P`) | new `src/tui/palette.zig`, TUI-only |
| Quick pick / input box | new `src/tui/quickInput.zig`, backs `MainThreadQuickOpen.$show`/`$input` |
| Status bar | bottom row in `src/tui/view.zig` (not `render.zig`; that file does not exist) |
| Diagnostics | markers stored on the model, painted as gutter marks + status count |
| Contributed languages | ported language service; keep `src/tui/language.zig` only as the no-host fallback |
| Contributed grammars | grammar registry feeding `textMateTokenizer.zig` |
| Contributed themes | `tokenColors` through the existing theme trie; map foregrounds to the ANSI palette |
| Contributed keybindings | `src/vs/platform/keybinding/common/keybindingsRegistry.zig` + terminal key mapping |
| Configuration | defaults from `contributes.configuration`, user settings file, `getConfiguration()`, `$acceptConfigurationChanged` |
| Documents | model open/change/close events pushed to the host as deltas (§9) |

`src/tui/extensions.zig` is a thin adapter: it owns the host process and the
TUI session, and delegates scan/registry/activation/contribution logic to the
ported `src/vs/...` services. `app.zig` gains a `pump()` call in the main
loop and an extra file descriptor in the input poll. The current
`tui.pollInput` only polls stdin (`src/tui/tui.zig:221-229`); it needs a
two-fd form (or a new `pollFds`) so `pump()` runs when the self-pipe fires.
The reader thread must use ordinary `read(2)`/`poll(2)` on the RPC fd, not the
single-threaded `std.Io` instance used elsewhere.

### 11.1 Languages

Ported language service (upstream `workbench/services/language/common/languageService.ts`)
owns the id/alias/extension/filename tables and emits `onLanguage:<id>`.
`src/tui/language.zig` keeps the TUI-local fallback only when no host is
available. The `languages` contribution's `configuration` field must be
loaded and parsed: the current `commentRuleFor` and bracket tables are
hard-coded subsets of `language-configuration.json`, and contributed
languages will otherwise get IDs without working comments/brackets.

### 11.2 Grammars and themes

`textMateTokenizer.zig` currently uses a hard-coded `grammarScope` map and a
`metadataForScope` classifier. Contributed grammars need a registry from
`contributes.grammars` (language, `scopeName`, `path`, `injectTo`,
`embeddedLanguages`, `tokenTypes`) and `GrammarLibrary.addGrammar(path)`.
Contributed themes need the theme file loaded (JSONC), the existing
`TokenTheme` trie fed with `tokenColors`, and the tokenizer to pass enough
scope information for theme matching. The textmate parser exposes capture
scope names but the current tokenizer flattens them to a token type; validate
the required scope stack against the library's theme support before promising
arbitrary `tokenColors`. Until then, map the resolved token style to the
nearest ANSI colour and document the approximation.

### 11.3 Keybindings and commands

The keybinding registry and `when`-clause evaluator are portable. The
browser-specific resolver (`usLayoutResolvedKeybinding`) is not: the TUI
already has decoded key events in `ui.input`. Implement a terminal key
normalisation (ctrl/alt/shift/meta, named keys, chords) and match it against
the registry. Start with single-chord bindings and a small `when` subset
(`editorTextFocus`, `editorLangId`, `resourceExtname`, `inQuickOpen`, ...);
document the rest. Command execution is a round trip: `onCommand:<id>` →
activate (if needed) → `$executeCommand`, with the result returned to the
palette. Built-in TUI commands and contributed commands share one registry.

### 11.4 Configuration, status bar, messages and diagnostics

- Configuration: `contributes.configuration` populates the default schema;
  the user settings file provides values; `$updateConfigurationOption` /
  `$removeConfigurationOption` write global or workspace settings. Push
  `ExtHostConfiguration.$acceptConfigurationChanged(data, change)` whenever
  the effective configuration changes. Language overrides and
  `ConfigurationTarget` are part of the contract.
- Status bar: `$setEntry` takes text, tooltip, command, colour, alignment and
  priority; the TUI renders a left/right split on the bottom row. Tooltips
  and `accessibilityInformation` may be simplified, but the entry id and
  disposal semantics must be exact.
- Messages: `$showMessage` is modal in the TUI; map severity to the prompt
  style and return the chosen item handle (or `undefined` on dismiss).
- Diagnostics: store markers per owner, merge them into the model's marker
  set, paint gutter marks and the status count, and clear on `$clear`.

### 11.5 Clipboard, window, dialogs and files

- Clipboard: `$readText`/`$writeText` via OSC 52 when available, otherwise an
  external command; document the terminal dependency.
- Window: `$openUri` uses the platform opener; `$asExternalUri` returns the
  same URI for local use; `$getInitialState` reports focus.
- Dialogs: `$showOpenDialog`/`$showSaveDialog` use the TUI path prompt or the
  existing file picker and return `UriComponents`.
- Files: `MainThreadFileSystem` implements local `file:` operations for
  `workspace.fs`; provider registration (`$registerFileSystemProvider`) is
  deferred.

## 12. Security and trust

Extensions are arbitrary code in the host process. The TUI must decide, per
workspace, whether to run them. The minimum policy:

- The workspace trust state is explicit (trusted, restricted, or unknown) and
  is passed to `$initializeWorkspace`. `vscode.workspace.isTrusted` reflects
  it; do not hard-code `true`.
- In restricted mode, the host still loads extensions; the API reports
  `isTrusted = false`, and extensions that declare
  `capabilities.untrustedWorkspaces` can restrict themselves. The TUI shows a
  warning and offers `$requestWorkspaceTrust` through the
  `MainThreadWorkspace` trust methods.
- `--extension-development-path` is trusted only when the user passes it on
  the command line; document that this runs unreviewed code.
- Secrets are stored in a `0600` file under the data directory initially, not
  an OS keychain; document this limitation.

This is a policy decision, not a sandbox. Nothing in this design isolates an
extension from the editor's files or from the host process.

## 13. Lifecycle, restart and shutdown

- **Spawn.** The launcher is spawned with fd 3/4 pipes, stderr piped for
  logs, stdin either inherited or `/dev/null`. The editor keeps the child pid.
- **Read.** The reader thread reads frames, validates the length cap, copies
  the payload into the frame queue, and signals the self-pipe. Partial reads
  and multiple frames per read are both normal.
- **Write.** The main thread queues frames; the writer handles partial writes
  and backpressure. Request IDs are assigned on send; a reply that arrives
  after cancellation is dropped or resolved as canceled.
- **Crash.** EOF on fd 3 means the host is gone. Reject all pending replies as
  canceled, mark the host unavailable, and attempt one restart after
  re-reading the extension list. On restart: send init data again, re-send
  `$initializeWorkspace`, `$initializeConfiguration`, `$startExtensionHost`
  with the full delta, re-open the documents/editors the host knew about, and
  re-fire the activation events that were already requested. Disable the host
  after a second crash within a short window and show the error.
- **Quit.** Send `Terminate`, drain, close fd 4, wait for exit with a timeout,
  then kill. Deactivate extensions host-side before the transport closes.
- **Logs.** Host stderr and `MainThreadConsole` messages go to the editor log
  file/status line, not the ANSI frame stream.

## 14. Roadmap

Each stage lands green (`zig build`, `zig build test --summary all`,
`zig fmt --check <changed>`, clean `git diff --check`) and updates this
document and `README.md`.

**S0 — spike.** Build the host (`pnpm install --frozen-lockfile && pnpm run
compile`), write `host/extensionHost.js` with fd 3/4 framing and the trimmed
service list, and boot the real `ExtensionHostMain` with a fixture extension
that reaches `activate()`. Assert: no stdout pollution, `Ready`/`Initialized`
order, workspace/config calls, `$startExtensionHost`,
`$activateByEvent("*", ActivationKind.Normal)`, console forwarding, clean
`Terminate`. Record the boot call list and raw frames here.

**S1 — foundation codecs.** `buffer.zig` (`VSBuffer`), `uri.zig`
(`UriComponents`, parse, `joinPath`, `$mid`, `revive`), `marshalling.zig`,
`marshallingIds.zig`, extend `errors.zig` (`SerializedError`,
`transformErrorForSerialization`), `json.zig` (minimal JSONC), and the semver
subset. Port the complete `buffer.test.ts`, the URI tests for the implemented
surface, and the JSONC tests. Do not create a second `errors.zig`; extend
`src/vs/base/common/errors.zig`.

**S2 — RPC and interop smoke test.** `proxyIdentifier.zig`,
`rpcProtocol.zig`, `extensionHostProtocol.zig`, `ipc.zig`,
`ipc.pipe.zig`, generated `extHost.protocol.zig` plus the method manifest.
Port the full `rpcProtocol.test.ts` and add golden hex vectors captured from
the real host. Add a thin Zig↔host smoke test now: initialize workspace and
configuration, start the host, activate the fixture, execute one command.
This front-loads the risk that the actor table or transport is wrong.

**S3 — manifest and scan.** `platform/extensions/common/extensions.zig`,
`extensionValidator.zig`, `extensionsScannerService.zig`,
`implicitActivationEvents.zig`, `extensionDescriptionRegistry.zig`. Port
`extensionValidator.test.ts`, `extensions.test.ts`,
`extensionDescriptionRegistry.test.ts`.

**S4 — contributions and TUI.** `extensionsRegistry.zig`, `commands.zig`,
`contextkey.zig` + `scanner.zig`, `keybindingsRegistry.zig`, the contribution
points from §8, palette, quick input, status bar, diagnostics. Port
`commands.test.ts` and the contextkey suites.

**S5 — manager and actors.** `extensionHostManager.zig`,
`extensionHostProxy.zig`, and the baseline `mainThread*.zig` set from §7,
boot-critical first. Restart and shutdown from §13.

**S6 — documents, editors and features.** §9 and §10: document/editor deltas,
text-editor RPCs, language features, filesystem, output, progress, secrets,
editor tabs, languages/grammars/themes.

**S7 — end to end and docs.** `src/tui/extensions.zig` wiring, `app.zig`
pump, README scope and limitations, this document's status, and the
`zig build test-e2e` target.

## 15. Testing

- **Ported upstream suites** for everything ported to Zig, in the upstream
  folder structure and with the upstream `.test.ts` basename changed to
  `.test.zig`. Register each file in `src/tests.zig`.
- **Protocol golden vectors**: frames captured from the pinned host, stored
  as hex, asserted by the Zig codec and by the Node launcher. Regenerate them
  when the pinned host changes; a failing vector is a version-drift signal,
  not a test to loosen.
- **Interop smoke test**: a Zig test that spawns the real host (when
  `--vscode-host-path` is available) and asserts the S2 call sequence.
  `zig build test` stays hermetic; `zig build test-e2e` needs Node and the
  built host.
- **Integration**: fixture extensions for activate-once, dependency
  ordering, command round-trip, status bar, diagnostics, configuration
  changes, document deltas, language features, restart and clean
  deactivation.
- **TUI tests**: palette, quick input, status row, diagnostics gutter marks,
  keybinding dispatch, and the two-fd poll/pump path.
- **Regression tests** for every bug found while porting.

## 16. Deferred / explicit limitations

- Electron transport, `PersistentProtocol`, socket reconnection.
- Remote extension hosts, marketplace install and update, profiles.
- Proposed APIs and `engines.vscode` proposal checks.
- Webviews, terminals, debug, SCM, notebooks, chat, tasks, tree views, custom
  editors, authentication, tests API, comments, timeline, speech, MCP,
  GitHub, file decoration providers.
- Semantic tokens, inlay hints, code lens, document links/colors, folding,
  selection ranges, call/type hierarchy, inline completions, paste/drop
  edits: the host exposes them, calls reject.
- File system providers other than local `file:`; `workspace.fs` is local
  read/write only.
- Localization bundles (`nlsBaseUrl` is omitted) and manifest
  `package.nls.json` localization.
- Full JSONC/schema validation; only the subset the TUI consumes is
  validated.
- Full semver ranges; only the subset needed by extension validation and
  version comparison.
- Named-pipe transport and `PersistentProtocol`; the fd 3/4 pipe pair works
  on Windows and is the only transport.
- Arbitrary theme scopes/modifiers; the TUI maps resolved token styles to the
  ANSI palette and documents the approximation.

## 17. Open questions

1. **Node version floor.** The host build pins `.nvmrc` 24.22.1. Check the
   Node version at startup and fail closed with a clear message rather than
   discovering it during `pnpm run compile`.
2. **Host discovery.** Proposed order: `--vscode-host-path`,
   `VSCODE_HOST_PATH`, `../vscode/out`, then a downloaded release. Every hit
   is validated against the pinned version and commit; a mismatch is an
   error, not a fallback to the next candidate.
3. **Storage.** `MainThreadStorage` is required: mementos always go through
   `$initializeExtensionStorage`/`$setValue`. Host-side persistence would
   require modifying upstream and is not an option under decision 2.
4. **`onStartupFinished` timing.** Fire it after the first painted frame, not
   during startup, and document that extensions see the editor already
   rendered.
5. **Workspace trust default.** Decide whether an untrusted folder prompts,
   starts in restricted mode, or refuses to start the host. The TUI should
   match VS Code's restricted-mode semantics as far as the API surface goes.

## Appendix A — baseline method inventory (1.147.0)

Generated from `extHost.protocol.ts`. The generator emits the full inventory;
these are the methods the baseline actors must at least classify as
supported, stubbed, or rejected. The first usable implementation covers the
methods listed in §7 and §10; the rest of each actor is deferred but must
still answer, not hang.

```
MainThreadExtensionService: $getExtension, $activateExtension,
  $onWillActivateExtension, $onDidActivateExtension,
  $onExtensionActivationError, $onExtensionRuntimeError,
  $setPerformanceMarks, $asBrowserUri
MainThreadErrors: $onUnexpectedError
MainThreadConsole: $logExtensionHostMessage
MainThreadTelemetry: $publicLog, $publicLog2
MainThreadStorage: $initializeExtensionStorage, $setValue,
  $registerExtensionStorageKeysToSync
MainThreadWorkspace: $startFileSearch, $startTextSearch, $checkExists, $save,
  $saveAll, $updateWorkspaceFolders, $resolveProxy, $lookupAuthorization,
  $lookupKerberosAuthorization, $loadCertificates, $requestResourceTrust,
  $requestWorkspaceTrust, $isResourceTrusted,
  $registerEditSessionIdentityProvider, $unregisterEditSessionIdentityProvider,
  $registerCanonicalUriProvider, $unregisterCanonicalUriProvider,
  $resolveDecoding, $validateDetectedEncoding, $resolveEncoding
MainThreadConfiguration: $updateConfigurationOption, $removeConfigurationOption
MainThreadCommands: $registerCommand, $unregisterCommand,
  $fireCommandActivationEvent, $executeCommand, $getCommands
MainThreadDocuments: $tryCreateDocument, $tryOpenDocument, $trySaveDocument
MainThreadTextEditors: $tryShowTextDocument, $registerTextEditorDecorationType,
  $removeTextEditorDecorationType, $tryShowEditor, $tryHideEditor,
  $trySetOptions, $trySetDecorations, $trySetDecorationsFast,
  $tryRevealRange, $trySetSelections, $tryApplyEdits, $tryInsertSnippet,
  $getDiffInformation
MainThreadLanguages: $changeLanguage, $tokensAtPosition,
  $computeFullSyntaxHighlighting, $setLanguageStatus, $removeLanguageStatus
MainThreadLanguageFeatures (first cut): $unregister,
  $registerHoverProvider, $registerCompletionsProvider,
  $registerDefinitionSupport, $registerDocumentSymbolProvider,
  $registerCodeActionSupport, $registerDocumentFormattingSupport,
  $registerRangeFormattingSupport, $registerOnTypeFormattingSupport
MainThreadDiagnostics: $changeMany, $clear
MainThreadStatusBar: $setEntry, $disposeEntry
MainThreadMessageService: $showMessage
MainThreadWindow: $getInitialState, $openUri, $asExternalUri
MainThreadClipboard: $readText, $writeText
MainThreadQuickOpen: $show, $setItems, $setError, $input, $createOrUpdate,
  $dispose
MainThreadDialogs: $showOpenDialog, $showSaveDialog
MainThreadFileSystem: $registerFileSystemProvider, $unregisterProvider,
  $onFileSystemChange, $stat, $readdir, $readFile, $writeFile, $rename,
  $copy, $mkdir, $delete, $ensureActivation
MainThreadOutputService: $register, $update, $reveal, $close, $dispose
MainThreadProgress: $startProgress, $progressReport, $progressEnd
MainThreadSecretState: $getPassword, $setPassword, $deletePassword, $getKeys
MainThreadEditorTabs: $moveTab, $closeTab, $closeGroup
```

`MainThreadLanguageFeatures` has 47 methods in 1.147.0. The remaining 38
(`$registerCodeLensSupport`, `$registerDeclarationSupport`,
`$registerImplementationSupport`, `$registerTypeDefinitionSupport`,
`$registerReferenceSupport`, `$registerDocumentHighlightProvider`,
`$registerRenameSupport`, `$registerFoldingRangeProvider`,
`$registerSelectionRangeProvider`, `$registerInlayHintsProvider`,
`$registerDocumentLinkProvider`, `$registerDocumentColorProvider`,
`$registerSignatureHelpProvider`, `$registerSemanticTokens*`, inline
completions, call/type hierarchy, paste/drop edits, and the event emitters)
are deferred; see §10 and §16.
