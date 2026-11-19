# Extension system: reuse VS Code's host, port the editor side

Status: the S0/S2 foundation and a first S7 slice are working. `host/` boots
the real Node host over a Unix socket, `rpcProtocol.zig` implements the wire
codec, the generated `extHost.protocol.zig` table has all 171 identifiers,
and `src/tui/extensions.zig` mirrors the active tab, routes text through
`type`/`default:type`, applies edits and selections, publishes status bar
entries, and discovers `vscodevim.vim-*` under the usual VS Code extension
directories. Declarative scanning now loads the bundled `theme-defaults` and
`markdown-basics` contributions: the theme files (including the
`dark_plus.json` → `dark_vs.json` include chain), the markdown language and
grammar, and its JSONC language configuration. `zig build test-e2e` activates VSCodeVim 1.32.4 and asserts insert
mode, a normal-mode `x`, and the resulting TUI editor text. Declarative
scanning now loads `theme-defaults` and `markdown-basics`. The remaining
`MainThread*` actors, the general contribution scanner, configuration writes,
`tabGroups`, extension keybindings and the built-in command set are still
incomplete. The prerequisite workbench services are ported (§3.3).

Upstream reference: `../vscode` at **1.147.0**, commit
`e31c2e52f563620846caab877103f630ea361b9c`. The actor table, method
inventory, init-data shape and line counts below were taken from that tree.
They are version-specific: upgrading the host invalidates the generated
protocol table, so the host version is pinned and checked at startup (see
§2.5 and §6.4). This document replaces an earlier draft that referenced
1.108.0.

Local snapshot: HEAD `e98be57`. The services the extension system consumes
(language, configuration, files, working copies, editor groups, status bar,
themes, keybindings, logging) are already ported; §3.3 maps them. No RPC,
scanner, contribution, or `MainThread*` module exists yet.

How to read paths and numbers in this document:

- An upstream path without a prefix is relative to `../vscode/src/vs/`, so
  `api/node/extensionHostProcess.ts` means
  `../vscode/src/vs/workbench/api/node/extensionHostProcess.ts`.
- A Zig path without a prefix is relative to this repository's `src/`.
- `.ts` becomes `.zig` one-for-one, including the otherwise unusual names
  (`extHost.protocol.ts` → `extHost.protocol.zig`; the extra dot is
  intentional). A test keeps the upstream `test/...` folder and the upstream
  basename: `.../test/common/rpcProtocol.test.ts` becomes
  `.../test/common/rpcProtocol.test.zig` and is registered in
  `src/tests.zig`.
- Line numbers are for the pinned commit. Counts marked *generated* are
  checked by the build, not maintained by hand.
- "Host" is the reused Node program; "workbench" is the Zig side; "TUI" is
  the terminal adapter in `src/tui/`.

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

   Implementation note: the Zig manager creates a Unix socket and passes
   `--socket <path>` to the launcher, which supports the same framed stream.
   Zig 0.17's `std.process.spawn` has no arbitrary-fd mapping, so this keeps
   stdout isolation without a manual fork/exec. fd 3/4 remains the launcher
   default for other callers and for the Node harness.

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
   a frame queue and writes one byte to a self-pipe; `app.zig` polls stdin,
   the existing file-watcher source and the self-pipe together and calls
   `pump()`. Replies are callbacks, not promises; requests that need user
   input (quick pick, input box) stay pending until the TUI answers. `pump()`
   must also run on host-death and timer events, not only when a frame
   arrives.

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

### 2.5 Host pinning and generated contracts

The pin is not only a version string. Three artifacts are derived from the
pinned tree and committed to this repository, and they must be regenerated
together:

1. the ordered proxy-identifier table and per-actor method manifest from
   `api/common/extHost.protocol.ts` (§5.2, §7.1);
2. the init-data and extension-snapshot JSON shapes from
   `services/extensions/common/extensionHostProtocol.ts` (§6.3);
3. the RPC message enums and byte encodings from
   `services/extensions/common/rpcProtocol.ts` (§5).

A host build is accepted only when all of the following hold:

- its `package.json` `version` is exactly `1.147.0`;
- when the build defines `product.commit`, it equals
  `e31c2e52f563620846caab877103f630ea361b9c`;
- the modules the launcher imports exist
  (`out/vs/workbench/api/common/extensionHostMain.js` and the trimmed
  service modules from §6.1);
- the host's own commit check agrees: `initData.commit` carries the expected
  commit, so `extensionHostProcess.ts:341-349` rejects a mismatched tree even
  if the launcher was pointed at it directly.

Discovery order is an open question (§17, item 2), but the failure rule is not:
the first candidate that exists is validated, and a mismatch is a hard error.
Do not silently fall through to the next candidate, and do not downgrade a
version-mismatch failure to "extensions disabled for an unrelated reason".
The editor still starts; the status/log line names the rejected host path and
the expected/got versions.

A source checkout (`../vscode`) has `version` from `package.json` but may not
define `product.commit`. In that case only the version check and the host's
own `initData.commit` check (when its `product.commit` is defined) apply.
Node's floor is `.nvmrc` 24.22.1; check it at startup and fail closed before
spawning rather than failing inside `pnpm run compile` (§17, item 1).

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
| `base/common/json.ts` | 1344 | JSONC scanner/parser subset ported to Zig |
| `base/common/semver/semver.js` | 52 (minified UMD) | small semver subset ported to Zig |

### 3.1 Port map

Upstream file structure is the Zig file structure (AGENTS.md). The table
separates the reused host from the workbench port and names the upstream test
that must come with each file. "Generated" files are produced from the pinned
tree by a development-time script and committed; they are not edited by hand.
Stage numbers refer to §14.

| Upstream (relative to `../vscode/src/vs/`) | Lines | Zig (relative to `src/vs/`) | Upstream test | Stage |
|---|---|---|---|---|
| `base/common/buffer.ts` | 582 | `base/common/buffer.zig` | `base/test/common/buffer.test.ts` (649) | S1 |
| `base/common/uri.ts` | 765 | `base/common/uri.zig` | `base/test/common/uri.test.ts` (727) | S1 |
| `base/common/marshalling.ts`, `marshallingIds.ts` | 84 + 33 | `base/common/marshalling.zig`, `marshallingIds.zig` | `base/test/common/marshalling.test.ts` (41) | S1 |
| `base/common/uriIpc.ts` | 163 | `base/common/uriIpc.zig` | no dedicated test; add transformer round-trip tests | S2 |
| `base/common/errors.ts` | 357 | extend `base/common/errors.zig` | `base/test/common/errors.test.ts` (98) | S1 |
| `base/common/cancellation.ts` | 239 | extend `base/common/cancellation.zig` | `base/test/common/cancellation.test.ts` (361) | S1 |
| `base/common/json.ts` | 1344 | `base/common/json.zig` | `base/test/common/json.test.ts` (338; parser cases) | S1 |
| `base/common/semver/semver.js` | 52 (minified UMD) | `base/common/semver/semver.zig` | no upstream test in tree (bundled npm); add focused tests | S1 |
| `base/parts/ipc/common/ipc.ts` | 1360 (only `IMessagePassingProtocol`, `BufferWriter`) | `base/parts/ipc/common/ipc.zig` | exercised by `rpcProtocol.test.ts` | S2 |
| `platform/extensions/common/extensions.ts` | 627 | `platform/extensions/common/extensions.zig` | `platform/extensions/test/common/extensions.test.ts` (99) | S3 |
| `platform/extensions/common/extensionValidator.ts` | 391 | `.../extensionValidator.zig` | `.../extensionValidator.test.ts` (441) | S3 |
| `platform/extensionManagement/common/extensionsScannerService.ts` | 1111 | `.../extensionsScannerService.zig` | `platform/extensionManagement/test/node/extensionsScannerService.test.ts` (630) | S3 |
| `platform/extensionManagement/common/implicitActivationEvents.ts` | 87 | `.../implicitActivationEvents.zig` | none; add generator tests | S3 |
| `workbench/services/extensions/common/extensions.ts` | 620 | `workbench/services/extensions/common/extensions.zig` | `.../test/common/extensions.test.ts` (69, Proposed API only) | S2 |
| `workbench/services/extensions/common/proxyIdentifier.ts` | 85 | `.../proxyIdentifier.zig` | covered by `rpcProtocol.test.ts` | S2 |
| `workbench/services/extensions/common/rpcProtocol.ts` | 968 | `.../rpcProtocol.zig` | `.../test/common/rpcProtocol.test.ts` (285) | S2 |
| `workbench/services/extensions/common/extensionHostProtocol.ts` | 157 | `.../extensionHostProtocol.zig` | `api/test/common/extensionHostMain.test.ts` (261) is host-side; add init-data tests | S2 |
| `workbench/services/extensions/common/extensionHostProxy.ts` | 45 | `.../extensionHostProxy.zig` | none; add fake-host tests | S5 |
| `workbench/services/extensions/common/extensionHostManager.ts` | 661 | `.../extensionHostManager.zig` | `.../test/browser/extensionService.test.ts` (428) | S5 |
| `workbench/services/extensions/common/extensionDescriptionRegistry.ts` | 423 | `.../extensionDescriptionRegistry.zig` | `.../test/common/extensionDescriptionRegistry.test.ts` (54) | S3 |
| `workbench/services/extensions/common/extensionsRegistry.ts` | 729 | `.../extensionsRegistry.zig` | none direct; add extension-point tests | S4 |
| `workbench/api/common/extHost.protocol.ts` | 4434 | **generated** `workbench/api/common/extHost.protocol.zig` + `extHost.protocol.manifest.zig` | generator assertions (§5.2) | S2 |
| `workbench/api/browser/mainThread*.ts` | — | `workbench/api/browser/mainThread*.zig` (baseline in §7) | `workbench/api/test/browser/mainThread*.test.ts` | S5/S6 |
| `workbench/services/language/common/languageService.ts` | 372 | `.../languageService.zig` (registration and `files.associations` ported) | no dedicated workbench test; add contribution/activation tests | S4 (port exists; activation hook remains) |
| `editor/common/languageFeatureRegistry.ts` | 236 | `editor/common/languageFeatureRegistry.zig` | no direct test; add selector/scoring tests | S6 (missing; required by `MainThreadLanguageFeatures`) |
| `workbench/services/actions/common/menusExtensionPoint.ts` | 1297 | `.../menusExtensionPoint.zig` (`commands`) | none direct | S4 |
| `workbench/services/textMate/common/TMGrammars.ts` | 90 | `.../TMGrammars.zig` (`grammars`) | textMate suites | S6 |
| `workbench/services/themes/common/themeExtensionPoints.ts` | 306 | `.../themeExtensionPoints.zig` (`themes`) | theme suites | S6 |
| `workbench/api/common/configurationExtensionPoint.ts` | 583 | `.../configurationExtensionPoint.zig` | none direct; add schema tests | S4 |
| `platform/keybinding/common/keybindingsRegistry.ts` | 301 | `.../keybindingsRegistry.zig` | `platform/keybinding/test/common/*` | S4 (ported; reuse the suite) |
| `platform/contextkey/common/contextkey.ts`, `scanner.ts` | 2199 + 384 | `.../contextkey.zig`, `.../scanner.zig` | `platform/contextkey/test/common/*` | S4 (ported; flat context service only) |
| `workbench/services/keybinding/browser/keybindingService.ts` | 1021 | `src/tui/keybindingService.zig` (terminal host over the ported registry/resolver; browser layout stays in `src/tui/`) | `.../test/browser/keybindingIO.test.ts` etc. | S4/S6 (host exists; extension rules remain) |

Several prerequisite rows are already implemented at HEAD `e98be57`
(§3.3); the table remains the target layout, and the stage column names the
remaining work. Three entries need a note. `host/extensionHost.js` has no
upstream counterpart: it is new launcher code (§6), not a port.
`base/parts/ipc/common/ipc.pipe.zig` is the fd transport, also new code,
which is why `ipc.net.ts` appears only in the reuse map as replaced. The generated actor table is produced from
`extHost.protocol.ts` at development time and committed; it is not a
hand-maintained port of a runtime module.

The port map also fixes where contribution points live. They are not one
`contributionRegistry.zig`: upstream registers each point next to the feature
that consumes it, and the Zig port follows that split (§8.3).

### 3.2 Faithful-port rules for this subsystem

The repository-wide rules in AGENTS.md apply with three extra constraints
specific to the extension system:

- **Mirror the upstream layout, including tests.** The generated protocol
  files live under `src/vs/workbench/api/common/`, not in a private `proto/`
  folder. Actor files keep the upstream `mainThread<Actor>.zig` basename.
- **Port the contract, not the happy path.** A method that the host calls
  must be present even when its feature is not wired: it returns a typed
  "not supported" rejection (promise methods) or empty success (void
  notifications), never a hang or a panic. An invalid contribution is
  reported and that contribution is dropped; a missing mandatory manifest
  field invalidates the extension, not the whole scan.
- **Do not build a parallel pipeline.** Contributed commands, decorations,
  hover/completion/suggest, quick input, status entries, diagnostics and
  configuration all feed the existing ported layers named in §9-§11. A new
  overlay that bypasses `lineDecorations`, `hoverProvider.zig`,
  `suggestController.zig`, `statusbarPart.zig` or `quickInput.zig` is a port
  bug even if it renders correctly.

Each stage in §14 is done only when its ported tests are registered in
`src/tests.zig` and the standard checks from AGENTS.md pass:
`zig build`, `zig build test --summary all`, `zig fmt --check <changed>`,
`git diff --check`.

The rejected alternative is running `extensionHostProcess.js` itself over its
Unix-socket `IPCExtHostConnection`. That keeps the bootstrap, but requires
porting `PersistentProtocol` (frame types, flow control, keep-alive,
reconnection) just to avoid our launcher.

### 3.3 Ported prerequisites at HEAD `e98be57`

The earlier draft treated the editor-side services as future work. They now
exist under their upstream paths. Consume them through their interfaces; do
not grow a parallel copy inside the extension layer.

| Capability | Ported Zig surface | Used by the extension system |
|---|---|---|
| URI and buffers | `base/common/uri.zig`, `base/common/buffer.zig` | URI components in arguments/init data, document text, `workspace.fs` |
| Errors and cancellation | `base/common/errors.zig`, `base/common/cancellation.zig` | serialized RPC errors, request cancellation, canceled replies |
| Language registry and configuration | `workbench/services/language/common/languageService.zig`, `editor/common/services/languageService.zig`, `editor/common/languages/languageConfigurationRegistry.zig`, `src/tui/languageConfiguration.zig` | `languages` contribution, `onLanguage:<id>`, `$acceptModelLanguageChanged`, comments/brackets/on-enter |
| Configuration | `workbench/services/configuration/browser/configurationService.zig`, `platform/configuration/common/*` | `contributes.configuration`, `$initializeConfiguration`, `$acceptConfigurationChanged`, settings defaults |
| Commands, actions, menus | `platform/commands/common/commands.zig`, `platform/actions/common/{actions,menuService}.zig`, `src/tui/commands.zig` | `contributes.commands`, `$executeCommand`, palette labels and enablement |
| Keybindings and context keys | `platform/keybinding/common/*`, `platform/contextkey/common/{contextkey,scanner}.zig`, `src/tui/keybindingService.zig` | `contributes.keybindings`, `when` clauses, command dispatch |
| File system and text files | `platform/files/common/fileService.zig` (`DiskFileService`, `ProviderFileService`), `platform/files/node/diskFileSystemProvider.zig`, `workbench/services/textfile/common/{textFileService,textFileEditorModel,encoding}.zig` | `$tryOpenDocument`, `$trySaveDocument`, `workspace.fs`, encoding, save participants |
| Working copies | `workbench/services/workingCopy/common/{workingCopy,workingCopyService,workingCopyEditorService,workingCopyBackupService,workingCopyHistoryService}.zig`, `src/tui/workingCopy.zig` | dirty/content/save deltas, editor lookup, restart backups |
| Editor groups | `workbench/services/editor/common/editorGroupsService.zig`, `workbench/browser/parts/editor/` | `$tryShowTextDocument`, `$tryShowEditor`, active editor, tab identity |
| Status bar | `workbench/services/statusbar/browser/statusbar.zig`, `workbench/browser/parts/statusbar/` | `MainThreadStatusBar.$setEntry` / `$disposeEntry` |
| Themes | `workbench/services/themes/browser/workbenchThemeService.zig`, `workbench/services/themes/common/colorThemeData.zig`, `src/tui/syntaxTheme.zig` | `contributes.themes`, token color resolution |
| Quick input | `platform/quickinput/**`, `src/tui/quickInput.zig`, `src/tui/quickAccess.zig` | `MainThreadQuickOpen.$show` / `$input` |
| Logging | `platform/log/common/{log,logService,bufferLog}.zig`, `src/tui/logger.zig` | `MainThreadConsole`, host stderr, launcher diagnostics |
| Storage | `platform/storage/common/storage.zig` (in-memory) | `MainThreadStorage` mementos |
| Notifications and progress | `platform/notification/common/*`, `platform/progress/common/progress.zig` | `$showMessage`, `withProgress` |
| Workspace and untitled inputs | `workbench/services/workspaces/common/workspaceContextService.zig`, `workbench/services/untitled/common/untitledTextEditorInput.zig` | `$initializeWorkspace`, `$tryCreateDocument` |

Still absent at this snapshot: `base/common/{marshalling,json}.zig`,
`base/common/uriIpc.zig`, the semver subset,
`editor/common/languageFeatureRegistry.zig`, everything under
`workbench/services/extensions/`, `workbench/api/`, `platform/extensions/`,
and `platform/extensionManagement/`. The context-key expression and scanner
are ported, but there is no scoped `ContextKeyService`; the TUI currently
resolves against a flat set. Configuration is read-only and has no language
overrides yet. Storage and working-copy backup/history are in-memory. These
gaps are called out where they affect an actor in §9-§13 and in §16.

## 4. Architecture

```
┌───────────────────── zig editor (one process) ──────────────────────┐
│ src/tui/app.zig ──poll(stdin, watcher, wakeup)──► ExtensionService   │
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

### 5.1 Byte layouts

The transport frame is `[u32 big-endian length][payload]`, where `payload` is
exactly one RPC message. The RPC message itself always starts with
`[u8 messageType][u32 requestId]`, so even an empty control message has a
5-byte body. All integers are big-endian.

The 12 message types, after the common 5-byte header:

| Type | Name | Rest of the body |
|---|---|---|
| 1 | `RequestJSONArgs` | `u8 rpcId`, short method, long JSON args |
| 2 | `RequestJSONArgsWithCancellation` | same as 1 |
| 3 | `RequestMixedArgs` | `u8 rpcId`, short method, mixed array |
| 4 | `RequestMixedArgsWithCancellation` | same as 3 |
| 5 | `Acknowledged` | empty |
| 6 | `Cancel` | empty |
| 7 | `ReplyOKEmpty` | empty |
| 8 | `ReplyOKVSBuffer` | buffer |
| 9 | `ReplyOKJSON` | long JSON |
| 10 | `ReplyOKJSONWithBuffers` | `u32 bufferCount`, long JSON, `bufferCount` buffers |
| 11 | `ReplyErrError` | long JSON error |
| 12 | `ReplyErrEmpty` | empty |

Encoding primitives:

- `u8` is one byte; actor ids (`rpcId`) must fit in it.
- short string: `u8 byteLength` + UTF-8 bytes. Used only for method names.
- long string: `u32 byteLength` + UTF-8 bytes. Used for JSON text.
- buffer: `u32 byteLength` + raw bytes.
- mixed array: `u8 argCount`, then per argument `u8 argType` and payload:
  - `1` string: long string, parsed as JSON on receipt;
  - `2` buffer: raw `VSBuffer`;
  - `3` serialized object with buffers: `u32 bufferCount`, long JSON,
    `bufferCount` buffers;
  - `4` undefined: no payload.

Worked example: a host-side request to `MainThreadCommands.$executeCommand`
(nid 10) with request id 1, method `$executeCommand`, and JSON args
`["my.command",[],false]`. The payload length is 49 bytes:

```text
00 00 00 31                          outer frame length 49
01                                   RequestJSONArgs
00 00 00 01                          request id 1
0a                                   rpcId 10 (MainThreadCommands)
0f                                   method length 15
24 65 78 65 63 75 74 65 43 6f 6d 6d 61 6e 64   "$executeCommand"
00 00 00 17                          JSON length 23
5b 22 6d 79 2e 63 6f 6d 6d 61 6e 64 22 2c 5b 5d 2c 66 61 6c 73 65 5d
                                     ["my.command",[],false]
```

The example is a golden-vector template, not a hand-written fixture to copy
blindly: capture the bytes from the pinned host before committing them
(§15.1).

### 5.2 Actor identifiers and the method manifest

`ProxyIdentifier` assigns `nid = ++ProxyIdentifier.count` at *evaluation*
time. The two object literals in `extHost.protocol.ts` are evaluated in
property order, so the first entry of `MainContext` is nid 1 and the first
entry of `ExtHostContext` is nid 90. In 1.147.0 that is **89 + 82 = 171**
identifiers. The count is one-based: nid 0 does not exist, and
`getStringIdentifierForProxy(0)` must never be called.

The generator, run by developers when the pin changes, does four things:

1. Parses the `MainContext` and `ExtHostContext` object literals in source
   order and emits `nid`, property key and `sid` for every entry.
2. Asserts the exact counts (`89`, `82`, `171`) and that every `sid` is
   unique and non-empty. These assertions are part of the pin, not a
   convenience.
3. Parses every `MainThread*Shape`/`ExtHost*Shape` interface and emits a
   method manifest: actor key, `sid`, `nid`, wire method name, and whether the
   declared return type is `void` or a promise. The void/promise split drives
   the notification policy in §7; do not infer it at runtime.
4. Writes `extHost.protocol.zig` and `extHost.protocol.manifest.zig` under
   `src/vs/workbench/api/common/`, with a header naming the pinned commit.

The property key and the wire `sid` are not always the same string. At
1.147.0 these differ, and the Zig table must use the `sid` for lookup and
logging:

| nid | key | `sid` |
|---|---|---|
| 7 | `MainThreadLanguageModelTools` | `MainThreadChatSkills` |
| 17 | `MainThreadDialogs` | `MainThreadDiaglogs` (upstream typo, preserve it) |
| 39 | `MainThreadSpeech` | `MainThreadSpeechProvider` |
| 64 | `MainThreadNotebookDocuments` | `MainThreadNotebookDocumentsShape` |
| 65 | `MainThreadNotebookEditors` | `MainThreadNotebookEditorsShape` |
| 76 | `MainThreadLocalization` | `MainThreadLocalizationShape` |
| 77 | `MainThreadMcp` | `MainThreadMcpShape` |
| 145 | `ExtHostChatAgents2` | `ExtHostChatAgents` |
| 146 | `ExtHostLanguageModelTools` | `ExtHostChatSkills` |

For a stable Zig representation, keep a `u16`/`u8` `nid` field and a `[]const
u8` `sid` slice; index a `[172]?ProxyIdentifier` table with nid so index 0 is
the sentinel. The build should fail if the table is shorter than the
generated `MaxNid`, and a request for an nid whose entry is null is a
protocol error, never an index-out-of-bounds.

### 5.3 Codec rules the implementation must keep

These are easy to lose when rewriting the protocol in Zig:

- **Cancellation token is an argument, popped before encoding.**
  `_remoteCall` checks only whether the *last* argument is a
  `CancellationToken`; a token in an earlier position is serialized as a
  normal object and is not turned into a `WithCancellation` message. An
  already-canceled token rejects locally with a canceled error and sends
  nothing.
- **Ack after invocation, once.** `_receiveRequest` calls the handler, then
  sends `Acknowledged`; it does not wait for the returned promise. A handler
  that throws synchronously still produces the ack and then a `ReplyErr`.
  Re-invoking a request with the same `req` is not deduplicated upstream; do
  not add a cache.
- **Cancel is consumed once.** The receiver stores per-request cancel
  callbacks only for `WithCancellation` requests, calls and removes the
  callback on `Cancel`, and removes it again on reply. A second `Cancel` is a
  no-op, and a `Cancel` for an unknown or completed request is ignored.
- **Reply selection.** `undefined` → type 7, `VSBuffer` → type 8,
  `SerializableObjectWithBuffers` → type 10, everything else → type 9. The
  JSON for 9 and 10 uses `safeStringify`; a cycle becomes the literal
  `null`. Type 8 is a raw buffer, not a JSON value.
- **Errors.** `ReplyErrError` contains
  `transformErrorForSerialization(value)` when `value` is truthy. The object
  is `{ "$isError": true, name, message, stack, noTelemetry, code?, cause? }`;
  a falsy error (including `undefined` from `Promise.reject(undefined)`) is
  `ReplyErrEmpty`. Non-`Error` thrown values are passed through unchanged.
  `noTelemetry` is always present on a serialized `Error` and is `false` for
  ordinary errors.
- **Mixed vs simple.** Presence of a `VSBuffer`, a
  `SerializableObjectWithBuffers`, or a top-level `undefined` selects the
  mixed encoding; otherwise the simple encoding is used. Mixed arguments are
  individually JSON-stringified, so a cyclic non-buffer argument throws
  *before* the message is sent. A cyclic argument in the simple encoding also
  throws locally. Preserve that asymmetry instead of routing everything
  through the safe stringifier.
- **`$$ref$$` is contextual.** Inside a `SerializableObjectWithBuffers`
  value, every `VSBuffer` becomes `{"$$ref$$": n}` and every `undefined`
  (array element or object property) becomes `{"$$ref$$": -1}`; references
  are resolved against that message's buffer table only. A plain JSON reply
  containing `$$ref$$` is data, not a reference.
- **Extension commands are not `ExtHostCommands.$executeCommand`.** In
  1.147.0 `ExtHostCommands` has `$executeContributedCommand(id, ...args)` and
  `$getContributedCommandMetadata`; `$executeCommand` belongs to
  `MainThreadCommands` and is how the host invokes a *workbench* command.
  Calling `$executeCommand` on `ExtHostCommands` fails with "Unknown method".
- **Replies to unknown requests are dropped.** `_receiveReply` and
  `_receiveReplyErr` check the pending map and return silently when the id is
  gone (canceled, disposed, or already answered). Do not treat this as a
  protocol error; a cancellation race produces it routinely.
- **Dispose is terminal for this direction.** `dispose()` rejects every
  pending reply with the canceled error, drops further incoming messages, and
  makes new outgoing calls return canceled. `drain()` is delegated to the
  transport and is not "wait for all replies".
- **Unresponsive is advisory.** The 3-second deadline starts when the first
  unacknowledged request is sent, resets to `now + 3s` on every ack, and is
  checked by a one-second scheduler only while at least one request is
  unacknowledged. It never cancels or fails a request by itself.
- **Ownership.** A decoded frame's JSON values must be owned by an arena tied
  to the request/reply lifetime, not by the reader thread and not by the
  actor slot. The reader copies bytes out of the fd buffer; the main thread
  parses and dispatches. Never hand a slice of the read buffer to an actor
  that may retain it.

The Zig codec should be tested against golden frames captured from the real
host and against a reimplementation of `rpcProtocol.test.ts`; see §15.

## 6. Boot sequence and launcher

### 6.1 What the launcher must replace

Replacing `extensionHostProcess.ts` is more than opening two pipes. The
launcher must provide:

- Node `require` blocklist for the `natives` module and the
  `process.exit`/`process.crash` patches, or an explicit decision to omit
  them and document the divergence. Upstream's `patchProcess(allowExit)`
  allows `process.exit` only when `environment.extensionTestsLocationURI` is
  set; otherwise it logs and blocks the call. `process.crash` is always
  blocked, and `ELECTRON_RUN_AS_NODE=1` is set for child processes.
- `navigator` shadowing on Node versions where it is a global, unless
  `supportGlobalNavigator` is set. The shadow reports a
  `PendingMigrationError` instead of returning Node's `navigator`.
- The argv switches the real bootstrap parses: `transformURIs`,
  `skipWorkspaceStorageLock`, `supportGlobalNavigator`, and
  `useHostProxy` (`true`/`false`/absent). URI transformation is installed
  only when `remote.authority` is present and `transformURIs` is set.
- `unhandledRejection`, `rejectionHandled` and `uncaughtException` handlers.
  The rejection handler waits one second before reporting, so a late
  `catch` does not produce noise.
- The init-data first-message handshake, `Ready`/`Initialized` bytes, the
  commit check, and `Terminate` filtering.
- Framing, partial reads/writes, backpressure, and fd lifecycle.
- Console/stdout isolation: the host's bootstrap logging must not reach the
  RPC channel, and the upstream `ExtHostConsoleForwarder` only takes over
  after the node extension service is constructed.
- A `NodeHost` for `IHostUtils` (`pid` is `process.pid`, plus `exit`,
  `fsExists`, `fsRealpath`); the parent-pid watchdog sends `Terminate` if the
  editor disappears. It tolerates three consecutive
  `EPERM` failures before terminating and uses `@vscode/native-watchdog`
  when available, with the JS interval as the fallback.
- On shutdown, EOF/fd close detection on both directions. The watchdog above
  covers the case where the host outlives the editor.

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
7. host → activates `*` itself (eager), then its startup-finished extensions;
   the workbench sends `$activateByEvent(..., ActivationKind.Normal)` only
   for events it fires later (`onLanguage:<id>`, `onCommand:<id>`, ...).
   See §6.6.

Steps 4 and 5 are mandatory before activation. `ExtHostExtensionService`
awaits `_extHostWorkspace.waitForInitializeCall()`, so skipping step 4 leaves
the host waiting forever. `ExtHostConfiguration` opens its barrier only in
`$initializeConfiguration`, and extensions that call
`workspace.getConfiguration()` / `getConfigProvider()` wait on it; skipping
step 5 makes those activations hang instead of failing cleanly.

Upstream triggers steps 4 and 5 from the constructors of
`MainThreadWorkspace` and `MainThreadConfiguration`. In Zig, call the ExtHost
proxies explicitly after the `Initialized` frame and before
`$startExtensionHost`, and keep the same ordering.

A workbench-initiated `$activateByEvent` takes a second `ActivationKind`
argument (normally `Normal`; `Immediate` is used for eager paths). The host
does not wait for that call to return to start its own `*` activation. The
host's internal startup-finished path calls `$setPerformanceMarks` on
`MainThreadExtensionService`; that actor method must exist even if the TUI
does nothing with the marks.

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
| `remote` | `{ isRemote: false, connectionData: null }`; `authority` is omitted, not `null` |
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

### 6.5 Handshake trace

The launcher writes and reads the outer frame; the RPC codec sees only the
payload. The boot sequence therefore looks like this on the wire (lengths are
hex, `len` is the payload length):

```text
host  →  00 00 00 01 02                         Ready (payload type 2)
editor→  00 00 00 <len> <init-data JSON>        no type byte, raw UTF-8 JSON
host  →  00 00 00 01 01                         Initialized (payload type 1)
editor→  ... RequestJSONArgs ExtHostWorkspace.$initializeWorkspace ...
editor→  ... RequestJSONArgs ExtHostConfiguration.$initializeConfiguration ...
editor→  ... RequestJSONArgs ExtHostExtensionService.$startExtensionHost ...
host  →  ... ExtHost's replies ...
host  →  ... MainThreadExtensionService.$setPerformanceMarks ...
host  →  ... ExtHostLanguageFeatures / ExtHost* activation traffic ...
```

Details that the trace hides:

- The init-data frame has **no RPC message type**. `connectToRenderer` reads
  the first raw frame and calls `JSON.parse` on it
  (`extensionHostProcess.ts:332-397`). Sending a normal RPC frame first
  corrupts startup; sending init data twice is a protocol error.
- `Ready` is sent before the init data is received, and `Initialized` is
  sent after it is parsed. Do not reorder these two: the host's first
  listener is installed before `Ready`, so a fast workbench cannot race it.
- The commit check and the parent-pid watchdog run between parsing the init
  data and sending `Initialized`. A commit mismatch calls
  `nativeExit(VersionMismatch)` (55) without ever becoming an RPC error.
- Steps 4 and 5 are requests with `void` replies (`ReplyOKEmpty`), not
  notifications in the RPC sense. The host resolves
  `waitForInitializeCall()` when `$initializeWorkspace` is *called*, not when
  its reply is sent.
- `$startExtensionHost` returns a promise that resolves after the host's eager
  `*` activation. The startup-finished pass is scheduled after the eager race
  (up to ten seconds) and may complete after that reply. The TUI must not block
  its main loop on the promise; it pumps frames while the host works.
- `Terminate` is filtered by the host's protocol wrapper
  (`extensionHostProcess.ts:297-330`), so it never produces a reply. It is
  still framed like every other payload: `00 00 00 01 03`.

### 6.6 What the host drives itself

This is the most commonly misread part of the upstream flow. The workbench
does **not** send `$activateByEvent("*")` during boot, and it does not send
`onStartupFinished` either. `$startExtensionHost` starts
`_startExtensionHost()` host-side, which:

1. waits for `readyToStartExtensionHost` (set once workspace initialization
   completed),
2. opens `readyToRunExtensions`,
3. waits up to one second for activation events that arrived while the
   workbench was starting (`waitForActivatingExtensions` vs `timeout(1000)`),
4. calls `_handleEagerExtensions()`, which activates `*`, runs eager
   `workspaceContains:*` checks (`$checkExists` / `$startFileSearch` on
   `MainThreadWorkspace`), and the remote-resolver activation,
5. races that work against a 10-second timeout, then calls
   `_activateAllStartupFinished()`, which sends
   `$setPerformanceMarks` and activates `onStartupFinished` extensions.

Consequences for the Zig side:

- Send `$activateByEvent` only for events the workbench actually observes:
  a document opening with a language, a contributed command about to run, or
  an event that was queued before the host started (the manager's
  `initialActivationEvents`). Firing `*` again is not harmful because the
  host caches activation, but it is not upstream behavior and it obscures a
  real ordering bug.
- The first painted frame cannot delay `onStartupFinished` on its own. The
  only host-unmodified control point is *when the workbench sends
  `$startExtensionHost`*. If the TUI wants extensions to see a rendered
  editor, delay that call until after the first frame; then `*` and
  `onStartupFinished` both move later. This trade-off is §17, item 4.
- The 10-second race means a bad `*` extension can delay `onStartupFinished`
  by up to ten seconds. Do not add a second workbench-side timeout that
  reports all extensions as failed; the host still completes.

## 7. Main-thread actors

Ported to `src/vs/workbench/api/browser/mainThread*.zig` (upstream location),
registered on the Zig `RpcProtocol` by actor id. The table below is the
**baseline** for the first usable extension system, not the whole API. Counts
are from 1.147.0.

| Actor (`MainContext` key) | nid | Methods | Stage | Notes |
|---|---|---|---|---|
| `MainThreadExtensionService` | 54 | 8 | S5 | boot-critical named customer; includes `$setPerformanceMarks`, `$asBrowserUri` |
| `MainThreadErrors` | 23 | 1 | S5 | `$onUnexpectedError` |
| `MainThreadConsole` | 13 | 1 | S5 | console forwarding; fire-and-forget |
| `MainThreadTelemetry` | 40 | 2 | S5 | `$publicLog`, `$publicLog2` (drop) |
| `MainThreadStorage` | 38 | 3 | S5 | mementos; `$registerExtensionStorageKeysToSync` |
| `MainThreadWorkspace` | 51 | 20 | S5 | first cut: save/saveAll/checkExists/updateWorkspaceFolders/startFileSearch/startTextSearch/isResourceTrusted/requestWorkspaceTrust/resolveEncoding/validateDetectedEncoding/resolveDecoding |
| `MainThreadConfiguration` | 12 | 2 | S5 | `$updateConfigurationOption`, `$removeConfigurationOption`; push `$acceptConfigurationChanged` |
| `MainThreadCommands` | 10 | 5 | S5 | includes `$fireCommandActivationEvent`, `$getCommands` |
| `MainThreadDocuments` | 18 | 3 | S5 | `$tryOpenDocument`, `$tryCreateDocument`, `$trySaveDocument` |
| `MainThreadTextEditors` | 20 | 13 | S5 | show/options/selections/decorations/edits/snippets/diff |
| `MainThreadLanguages` | 27 | 5 | S5 | no `$getLanguages`; `$setLanguageStatus`/`$removeLanguageStatus` |
| `MainThreadLanguageFeatures` | 26 | 47 | S6 | first cut: hover, completion, definition, document symbols, code actions, formatting/range/on-type |
| `MainThreadDiagnostics` | 16 | 2 | S5 | `$changeMany`, `$clear` |
| `MainThreadStatusBar` | 36 | 2 | S5 | `$setEntry`, `$disposeEntry` |
| `MainThreadMessageService` | 29 | 1 | S5 | `$showMessage` |
| `MainThreadWindow` | 59 | 3 | S5 | `$getInitialState`, `$openUri`, `$asExternalUri` |
| `MainThreadClipboard` | 9 | 2 | S5 | `$readText`, `$writeText` |
| `MainThreadQuickOpen` | 35 | 6 | S3/S5 | backs `showQuickPick`/`showInputBox`; not `MainThreadWindow` |
| `MainThreadDialogs` | 17 | 2 | S5 | `$showOpenDialog`, `$showSaveDialog`; wire sid is `MainThreadDiaglogs` |
| `MainThreadFileSystem` | 52 | 12 | S6 | `workspace.fs` for local files; provider registration deferred |
| `MainThreadOutputService` | 30 | 5 | S6 | output channels |
| `MainThreadProgress` | 31 | 3 | S6 | `withProgress` |
| `MainThreadSecretState` | 37 | 4 | S6 | `context.secrets` |
| `MainThreadEditorTabs` | 22 | 3 | S6 | `window.tabGroups` |

These actors are adapters over the ported services in §3.3, not new state:
`MainThreadWorkspace` uses `WorkspaceContextService`/`ConfigurationService`,
`MainThreadConfiguration` uses `ConfigurationService`,
`MainThreadStorage` uses `InMemoryStorageService`,
`MainThreadStatusBar` uses `StatusbarService`, `MainThreadQuickOpen` uses the
ported `QuickPick`/`QuickAccess`, `MainThreadDocuments`/
`MainThreadTextEditors` use `WorkingCopyService`/`TextFileService`/
`EditorGroupsService`, `MainThreadFileSystem` uses `ProviderFileService`,
`MainThreadLanguageFeatures` uses the language service/configuration
registry plus a new provider registry (§10), and `MainThreadEditorTabs` uses
`EditorGroupsService`. Do not copy their state into an actor.

Easy-to-miss methods in the baseline actors:

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
`$onDidActivateExtension`, `$onExtensionRuntimeError`), an unimplemented actor
should return `ReplyOKEmpty`. Only promise-returning methods should reject.
The generated method manifest records which is which. Do not classify by call
site: `$setPerformanceMarks` returns `Promise<void>` and the host calls it
without awaiting, so the baseline must implement it as a no-op rather than
reject it and create an unhandled rejection.

The upstream registration check has two halves.
`MainThreadExtensionService` passes the full `Object.keys(MainContext)` set to
`_setAllMainProxyIdentifiers` (`mainThreadExtensionService.ts:58`), and
`ExtensionHostManager._createExtensionHostCustomers` calls
`assertRegistered(mainProxyIdentifiers)` (`extensionHostManager.ts:315`).
The baseline deliberately does not port the full assertion, because it
registers a subset; asserting every `MainContext` key would always fail. It
does assert the 24 baseline actors, and the generated table still detects an
out-of-range nid or a mismatched name.

### 7.1 Dispatch contract

Zig has no dynamic property lookup, so the RPC layer cannot call
`actor[method](...)` the way `rpcProtocol.ts` does. The port needs one
generated dispatch table per actor (or one table keyed by `nid` and method
name) with this contract:

- **Registration is explicit.** Each actor struct is registered with
  `rpc.set(MainContext.MainThreadCommands, commands.interface())` before the
  first `$startExtensionHost`. Unregistered baseline actors must not be
  silently omitted: the build asserts the baseline list.
- **Lookup is by wire name.** The dispatch table maps the upstream string
  (`"$tryShowTextDocument"`) to the Zig function. Zig functions may use
  `snake_case`; the wire name never changes.
- **Unknown actor or method** produces the upstream-shaped rejection:
  `Unknown actor <sid>` or `Unknown method <method> on actor <sid>`.
  For a method the manifest marks `void`, an unregistered actor returns
  `ReplyOKEmpty` instead (§7 notification policy).
- **Actor handlers run on the main thread**, inside `pump()`. The reader
  thread only copies frames into the queue. This keeps the observable order
  "handler, then ack, then other frames" identical to upstream and avoids
  locking actor state.
- **Errors are values.** A handler returns a typed error or a JSON value;
  it does not throw through C-style callbacks. The dispatcher serializes the
  error with `transformErrorForSerialization`-equivalent data.
- **Lifetime.** Actor registration outlives the host process; teardown
  cancels pending replies, then disposes actors in reverse registration
  order. Restart creates new actor instances; handles from the previous host
  are never reused (§13).

## 8. Declarative extensions

Ported (subset) to
`src/vs/workbench/services/extensions/common/extensionsRegistry.zig` and
`src/vs/workbench/services/language/common/languageConfigurationExtensionPoint.zig`.
The current scanner covers the `theme-defaults` and `markdown-basics` fixtures:
manifest JSONC, NLS placeholders skipped, and the `languages`, `grammars`,
`themes` and `snippets` contribution records are parsed. Snippet files are not
consumed by the editor yet. Full `extensionValidator`, profile scanning and
NLS resolution remain deferred.

Scan roots: bundled extensions, the user extensions directory
(`~/.local/share/zig-editor/extensions/<publisher>.<name>-<version>/`), and
every `--extension-development-path`. For each directory we read
`package.json`, normalise the identifier, apply defaults, validate with
`extensionValidator`, and keep the manifest JSON arena for the process
lifetime because contribution values borrow from it.

The description the host receives is `IRelaxedExtensionManifest` plus the
resolved identity: `identifier` (`ExtensionIdentifier` with optional `uuid`),
`uuid`, `publisherDisplayName`, `targetPlatform`, `isBuiltin`,
`isUserBuiltin`, `isUnderDevelopment`, `extensionLocation` and `preRelease`.
`ExtensionIdentifier` equality is case-insensitive (`toKey` lowercases); do
not compare raw publisher/name strings. The registry also resolves by `uuid`
(`getExtensionDescriptionByUUID`), so keep that field populated even though
`ExtensionIdentifier.equals` does not consult it.
A manifest must at least carry `name`, `version` and `engines.vscode`;
`publisher` defaults when absent (upstream uses a placeholder publisher so
authoring without one stays possible). The scanner's own validation is not a
substitute for `extensionValidator`.

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
  `std.json` rejects comments and trailing commas. Port the JSONC
  scanner/parser behavior from `base/common/json.ts`: line/block comments,
  trailing commas, string escapes, and parse errors with byte offsets. Test
  it against the bundled extensions in `../vscode/extensions`.
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
that receives `(users, delta)` and applies additions and removals. It cannot
see an in-place value change for an extension that is already present
(§8.3); a rescan that changes a manifest must remove and re-add that
extension. Validate the fields the TUI actually consumes; on an invalid
contribution, log the extension and drop that contribution instead of
aborting the scan.

`ImplicitActivationEvents` turns contributions into activation events, but
the generators live with the contribution points:

- `commands` → `onCommand:<id>` for every contribution with a truthy
  `command` string; validation and registration happen separately.
- `languages` → `onLanguage:<id>` **only when the language declares a
  `configuration`** (`languageService.ts:115-119`).
- `grammars` → **no implicit activation event**; grammars are declarative
  data and are loaded without activating the extension.
- `onUri` is rewritten to `onUri:<extension id>`.

Activation triggers, split by who fires them:

| Event | Fired when |
|---|---|
| `*` | host-side, when `_startExtensionHost` runs its eager pass (§6.6) |
| `onStartupFinished` | host-side, after eager activation or its 10-second cap (§6.6); the workbench can trigger it earlier with `$activateByEvent('onStartupFinished')` once the host is running, but cannot delay it |
| `onLanguage:<id>` | workbench, when a model with that language opens |
| `onCommand:<id>` | workbench, when a contributed command is about to run |
| `workspaceContains:<glob>` | host-side eager check during `_handleEagerExtensions`, using `$checkExists` / `$startFileSearch` |
| `onDebug`, `onView`, `onUri`, `onFileSystem` | never (unsupported, documented); `onUri` is rewritten to `onUri:<id>` but no URI handler event is fired |

The `workspaceContains` check is not a workbench activation event. The host
reads the glob from the manifest, asks `MainThreadWorkspace` whether it
matches, and activates the extension itself. A workbench-side
`activateByEvent("workspaceContains:...")` would be a duplicate path.

### 8.3 Contribution point shapes

The points live next to their upstream consumers, not in a single registry
file. The table names the Zig destination and the fields the TUI actually
consumes; the full JSON schema stays upstream and is not re-created as a
separate schema language.

| Point | Zig file | Consumed fields | Implicit activation |
|---|---|---|---|
| `commands` | `workbench/services/actions/common/menusExtensionPoint.zig` | `command`, `title`, `shortTitle`, `enablement`, `category`, `icon` | `onCommand:<command>` |
| `languages` | `workbench/services/language/common/languageService.zig` | `id`, `aliases`, `extensions`, `filenames`, `filenamePatterns`, `mimetypes`, `firstLine`, `configuration`, `icon` | `onLanguage:<id>` only when `id` and `configuration` are present (`languageService.ts:115-119`) |
| `grammars` | `workbench/services/textMate/common/TMGrammars.zig` | `language`, `scopeName`, `path`, `embeddedLanguages`, `tokenTypes`, `injectTo`, `balancedBracketScopes`, `unbalancedBracketScopes` | none |
| `themes` | `workbench/services/themes/common/themeExtensionPoints.zig` | `id`, `label`, `uiTheme`, `path` | none |
| `configuration` | `workbench/api/common/configurationExtensionPoint.zig` | `id`, `title`, `order`, `properties` (schema, defaults, scope, enum) | none |
| `keybindings` | `workbench/services/keybinding/browser/keybindingService.zig` | `command`, `key`, `args`, `mac`, `linux`, `win`, `when` | none |

Shape and validation notes:

- `commands` and `keybindings` accept either one object or an array.
  `commands` requires a non-empty `command` and a `title` (string or
  localized string). A duplicate command id is logged but still registered;
  `MenuRegistry.addCommand` overwrites the map entry, so the later extension
  wins. Do not silently drop the duplicate.
- `languages` has no required fields in the schema, but an entry without
  `id` cannot drive a language id or an activation event. `configuration` is
  a path relative to the extension root; the activation generator checks the
  raw contribution, not the file's existence.
- `grammars` declares `deps: [languages]`, so the languages point must be
  accepted first. `path` is resolved against `extensionLocation`;
  `injectTo` is a list of scope names, not language ids.
- `themes` requires both `path` and `uiTheme`; `uiTheme` is one of `vs`,
  `vs-dark`, `hc-black`, `hc-light`. `id` and `label` are not required by
  the schema, so a theme can be unnamed and is then not selectable by id.
- `configuration` accepts one node or an array of nodes. `properties` is a
  map from setting key to a JSON schema object. Duplicate keys across
  extensions are dropped with a warning; `configuration.id` defaults to the
  extension id; `restrictedProperties` is derived from
  `capabilities.untrustedWorkspaces`. `canHandleResolver: true` must be
  carried through.
- `keybindings` requires both `command` and `key`; `mac`, `linux` and `win`
  replace `key` on that platform, they are not additional chords. `when` is
  parsed by the same `contextkey.zig` parser as the resolver; do not
  substitute a looser terminal-only expression parser, or a contributed
  binding can become active under conditions the TUI cannot evaluate.
- `ExtensionPoint.setHandler` may be called exactly once; a second call is an
  error. The handler fires once all three inputs exist (handler, users,
  delta) and runs again when `acceptUsers` is called.
- The delta contains only **added and removed extensions**, computed by
  extension identifier. If the same extension's contribution value changes
  in place, the delta is empty and the handler does not see the new value.
  The scanner must therefore remove and re-add an extension whose manifest
  changed, or rebuild the user list, instead of assuming the handler will
  observe an update.
- Implicit activation events are generated only for extensions that have a
  `main` or `browser` entry. A declarative-only extension contributes
  languages, grammars and themes without ever being activatable.
  `onUri` is rewritten with `ExtensionIdentifier.toKey` (lowercase), not with
  the display casing of the id.

## 9. Documents and editors

This is the largest subsystem after RPC and needs its own data flow, not one
table row.

- **Open/close.** The workbench pushes
  `ExtHostDocumentsAndEditors.$acceptDocumentsAndEditorsDelta` with
  `addedDocuments`/`removedDocuments` and `addedEditors`/`removedEditors`.
  Each `ITextEditorAddData` carries `id`, `documentUri`, `options`,
  `selections`, `visibleRanges`, `editorPosition`. Use
  `EditorGroupsService`/`EditorGroupModel` for groups and tabs and
  `WorkingCopyService`/`WorkingCopyEditorService` for document identity; the
  host editor id can be the stable workbench editor input id.
- **Active editor.** `newActiveEditor` on the same delta; derive it from the
  active editor of `EditorGroupsService`, not from a TUI-only focus flag.
- **Content changes.** `ExtHostDocuments.$acceptModelChanged` carries
  `ISerializedModelContentChangedEvent` (deltas, not full text), `isDirty` and
  the version id. `$acceptModelSaved`, `$acceptDirtyStateChanged`,
  `$acceptEncodingChanged` and `$acceptModelLanguageChanged` cover the rest.
- **Host → workbench.** `$tryOpenDocument` loads through `TextFileService`
  (BOM encoding included) and opens through the existing
  `Workbench.openPath`/`EditorGroupsService` path; `$tryCreateDocument`
  creates an `UntitledTextEditorInput`; `$trySaveDocument` uses the editor's
  save path (`FileEditorInput.save`, backed by `Editor` today and by
  `TextFileEditorModel` once the editor is migrated).
  `$tryShowTextDocument` uses `EditorGroupsService` and returns the editor
  id; `$tryShowEditor`/`$tryHideEditor` activate or hide that editor.
- **Edits.** `$tryApplyEdits` and `$tryInsertSnippet` must go through the
  editor's command/edit stack with the model version check, undo stops and
  selection restoration, not direct model mutation. `$trySetSelections`,
  `$trySetOptions`, `$tryRevealRange` and `$getDiffInformation` are the rest.
- **Decorations.** `$registerTextEditorDecorationType`,
  `$removeTextEditorDecorationType`, `$trySetDecorations` and
  `$trySetDecorationsFast` feed the existing line-decoration pipeline, not a
  parallel overlay.
- **Dirty/encoding.** At HEAD the TUI `Editor`/`FileEditorInput` still owns
  the live dirty bit and save operation; `TextFileService`/`TextFileEditorModel`
  provide the ported load/save/encoding model (BOM detection and save
  participants) and `WorkingCopyService` tracks open copies through
  `src/tui/workingCopy.zig`. Bridge `$acceptDirtyStateChanged` from the
  working-copy dirty event and `$acceptEncodingChanged` from the model/input
  encoding, and do not introduce a second host-side dirty bit. When the TUI
  editor is migrated onto `TextFileEditorModel`, take those events directly
  from it.

The editor id is the host's identity for an editor instance; the TUI's tab id
can be used as that id as long as it is stable across focus changes. A host
editor that is hidden (not closed) must remain resolvable.

### 9.1 DTOs and method signatures

The deltas are typed, not ad-hoc JSON. The Zig structs must serialize with
these exact field names, because both sides read them without negotiation.

`IModelAddedData` (workbench → host, called `addedDocuments`):

| Field | Type |
|---|---|
| `uri` | `UriComponents` |
| `versionId` | number |
| `lines` | string[] (the full text split by the model's EOL) |
| `EOL` | string (`"\n"` or `"\r\n"`) |
| `languageId` | string |
| `isDirty` | boolean |
| `encoding` | string |

`ITextEditorAddData` (called `addedEditors`):

| Field | Type |
|---|---|
| `id` | string, stable editor identity |
| `documentUri` | `UriComponents` |
| `options` | `IResolvedTextEditorConfiguration` (`tabSize`, `indentSize`, `originalIndentSize`, `insertSpaces`, `cursorStyle`, `lineNumbers`) |
| `selections` | `ISelection[]` (`selectionStartLineNumber`, `selectionStartColumn`, `positionLineNumber`, `positionColumn`) |
| `visibleRanges` | `IRange[]` (`startLineNumber`, `startColumn`, `endLineNumber`, `endColumn`) |
| `editorPosition` | `EditorGroupColumn` or absent/undefined |

`IDocumentsAndEditorsDelta` itself:

```text
{ removedDocuments?: UriComponents[],
  addedDocuments?:  IModelAddedData[],
  removedEditors?:  string[],
  addedEditors?:    ITextEditorAddData[],
  newActiveEditor?: string | null }
```

`$acceptModelChanged` takes `(uri, event, isDirty)` where `event` is
`ISerializedModelContentChangedEvent`:

```text
{ changes: { range, rangeLength, text }[],
  eol, versionId,
  isUndoing, isRedoing, isFlush, isEolChange: boolean,
  detailedReason?: object }
```

`detailedReason` is metadata, not a call stack; the workbench sends one
reason per change and reports an unexpected error if
`detailedReasonsChangeLengths.length !== 1` (it still forwards the change).
The changes arrive ordered from the end of the document to the beginning, so
they can be applied sequentially without offset rebasing.

Method signatures for the actor pair (all `resource`/`uri` values are
`UriComponents`):

| Actor method | Result |
|---|---|
| `$tryOpenDocument(uri, options?: { encoding?: string })` | `UriComponents` of the opened document |
| `$tryCreateDocument(options?: { language?, content?, encoding? })` | `UriComponents` of the new untitled document |
| `$trySaveDocument(uri)` | boolean |
| `$tryShowTextDocument(resource, options: { position?, preserveFocus?, pinned?, selection? })` | editor `string` or `undefined` |
| `$tryShowEditor(id, position)` / `$tryHideEditor(id)` | `void` |
| `$trySetOptions(id, options)` | `void` |
| `$trySetSelections(id, selections)` | `void` |
| `$tryRevealRange(id, range, revealType)` | `void` |
| `$tryApplyEdits(id, modelVersionId, edits, opts)` | boolean |
| `$tryInsertSnippet(id, modelVersionId, template, selections, opts)` | boolean |
| `$getDiffInformation(id)` | `IChange[]` |
| `$registerTextEditorDecorationType(extensionId, key, options)` | `void` |
| `$removeTextEditorDecorationType(key)` | `void` |
| `$trySetDecorations(id, key, ranges)` | `void` |
| `$trySetDecorationsFast(id, key, ranges: number[])` | `void` |

`$tryApplyEdits` and `$tryInsertSnippet` take the model version the host
last saw and return `false` when it no longer matches; they do not reject for
a stale version. A nonexistent editor id does reject with an illegal-argument
error. `opts` carries `undoStopBefore`, `undoStopAfter`, and for apply-edits
an optional `setEndOfLine`.

`$trySetDecorationsFast` takes a flattened `number[]` interpreted as
4-tuples `[startLineNumber, startColumn, endLineNumber, endColumn]`; a
trailing partial tuple is ignored (`floor(length / 4)`). The type key is the
same key registered with `$registerTextEditorDecorationType`, prefixed on the
workbench side by the editor instance id.

Host-side editor property changes are pushed separately:
`ExtHostEditors.$acceptEditorPropertiesChanged(id, { options, selections,
visibleRanges })`, `$acceptEditorPositionData({ [id]: position })`, and
`$acceptEditorDiffInformation(id, diffInformation[])`. Do not fold these
into the documents-and-editors delta; the host expects the separate events.

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

### 10.1 Registrations and provider calls

The nine baseline registrations, with their exact argument lists:

| Workbench method | Arguments after `handle` |
|---|---|
| `$unregister` | none |
| `$registerHoverProvider` | `selector` |
| `$registerCompletionsProvider` | `selector`, `triggerCharacters`, `supportsResolveDetails`, `extensionId` |
| `$registerDefinitionSupport` | `selector` |
| `$registerDocumentSymbolProvider` | `selector`, `label` |
| `$registerCodeActionSupport` | `selector`, `metadata`, `displayName`, `extensionID`, `supportsResolve` |
| `$registerDocumentFormattingSupport` | `selector`, `extensionId`, `displayName` |
| `$registerRangeFormattingSupport` | `selector`, `extensionId`, `displayName`, `supportRanges` |
| `$registerOnTypeFormattingSupport` | `selector`, `autoFormatTriggerCharacters`, `extensionId` |

`selector` is `IDocumentFilterDto[]`; each item carries optional
`language`, `scheme`, `pattern` (`string` or `IRelativePattern`),
`exclusive` and `notebookType`. A missing selector field matches everything. `exclusive` means the provider
takes over from lower-scoring providers for that document; do not merge its
results with them.

Provider invocation is the reverse direction, on `ExtHostLanguageFeatures`:

| Call | Result |
|---|---|
| `$provideHover(handle, resource, position, context, token)` | `HoverWithId` |
| `$provideCompletionItems(handle, resource, position, context, token)` | `ISuggestResultDto` |
| `$resolveCompletionItem(handle, chainedCacheId, token)` | `ISuggestDataDto` |
| `$provideDefinition(handle, resource, position, token)` | `ILocationLinkDto[]` |
| `$provideDocumentSymbols(handle, resource, token)` | `DocumentSymbol[]` |
| `$provideCodeActions(handle, resource, range, context, token)` | `ICodeActionListDto` |
| `$resolveCodeAction(handle, chainedCacheId, token)` | `{ edit?, command? }` |
| `$provideDocumentFormattingEdits(handle, resource, options, token)` | `TextEdit[]` |
| `$provideDocumentRangeFormattingEdits(handle, resource, range, options, token)` | `TextEdit[]` |
| `$provideOnTypeFormattingEdits(handle, resource, position, ch, options, token)` | `TextEdit[]` |

Cache handles are not provider handles. Hover results carry an `id` that must
be released with `$releaseHover`; completion items and code actions use a
`ChainedCacheId` and are released with `$releaseCompletionItems` /
`$releaseCodeActions`. The host owns the cached results; the Zig workbench
must carry the ids back unchanged and release them when the provider is
unregistered or the document closes, and must not retain ids across a host
restart. The cancellation token is appended to these calls exactly as on any
other RPC request (§5.3); do not model it as an explicit JSON field.

## 11. TUI integration

| Feature | Where |
|---|---|
| Command palette (`Ctrl+Shift+P`) | extend `src/tui/quickAccess.zig`; there is no separate `palette.zig` |
| Quick pick / input box | extend `src/tui/quickInput.zig` (and `quickAccess.zig`) to back `MainThreadQuickOpen.$show`/`$input` |
| Status bar | ported `src/vs/workbench/browser/parts/statusbar/{statusbarPart,statusbarModel,statusbarItem,statusbarActions}.zig` over `src/vs/workbench/services/statusbar/browser/statusbar.zig`; painted by `src/tui/workbench.zig` on the bottom row |
| Diagnostics | markers stored on the model, painted as gutter marks + status count |
| Contributed languages | ported `workbench/services/language/common/languageService.zig`; keep `src/tui/language.zig` only as the no-host fallback |
| Contributed grammars | grammar registry feeding `textMateTokenizer.zig` |
| Contributed themes | `workbench/services/themes/browser/workbenchThemeService.zig` + `ColorThemeData`; map foregrounds to the ANSI palette |
| Contributed keybindings | `src/vs/platform/keybinding/common/keybindingsRegistry.zig`/`keybindingResolver.zig` + `src/tui/keybindingService.zig` and terminal key mapping |
| Configuration | `workbench/services/configuration/browser/configurationService.zig` defaults/user/workspace/folder reading, `getConfiguration()`, `$acceptConfigurationChanged` |
| Documents | `WorkingCopyService`/`TextFileService`/`EditorGroupsService` open/change/close events pushed to the host as deltas (§9) |

`src/tui/extensions.zig` is a thin adapter: it owns the host process and the
TUI session, and delegates scan/registry/activation/contribution logic to the
ported `src/vs/...` services. `app.zig` calls `pump()` once per main-loop
iteration instead of adding a second event loop.

The poll path needs care because the file watcher already owns the second
fd. Today `tui.pollInputWithFd(workbench.fileWatcherFd(), timeout)` on POSIX
and `tui.pollInputWithHandle(workbench.fileWatcherHandle(), timeout)` on
Windows poll stdin plus one extra source. The extension host's wakeup is a
third source. Two acceptable shapes:

1. share one self-pipe among the file watcher and the RPC reader (each
   producer writes one byte; `pump()` drains both queues), which keeps the
   two-fd poll untouched; or
2. generalize `PollResult` and the poll helpers to a small fd/handle array
   (POSIX `poll(2)`; Windows `WaitForMultipleObjects`, up to 64 handles).

Do not poll the RPC fd from the main loop without a wakeup: the reader thread
is there to turn blocking reads into a pollable event. The reader must use
ordinary `read(2)`/`poll(2)` on the RPC fd, not the single-threaded `std.Io`
instance used elsewhere.

### 11.1 Languages

The workbench language service is already ported
(`workbench/services/language/common/languageService.zig`): language
registration/validation, `files.associations`, and the id/alias/extension/
filename tables. It will be the source for `onLanguage:<id>` activation when
a model opens; the activation hook is still a no-op without an extension
host. Feed `contributes.languages` through
`registerLanguageContribution`/`registerExtensionPoint`, and register a
contributed `configuration` path with
`LanguageService.registerLanguageConfiguration` (the terminal
`src/tui/languageConfiguration.zig` host wraps the ported
`LanguageConfigurationRegistry`). `src/tui/language.zig` remains the
bundled-language table and the hard-coded `commentRuleFor`/bracket fallback;
it no longer owns path associations. Do not extend those fallback tables for
contributed languages: parse `language-configuration.json` (JSONC) and use
the registry so comments, brackets, on-enter rules and indentation follow
upstream priority merging.

### 11.2 Grammars and themes

Built-in languages already take their grammars from the upstream checkout's
`extensions/*/syntaxes` files (see `README.md`), and built-in colors come from
Dark+ through `TokenTheme`. Contributed grammars still need a `TMGrammars`
extension point from `contributes.grammars` (language, `scopeName`, `path`,
`injectTo`, `embeddedLanguages`, `tokenTypes`) feeding
`GrammarLibrary.addGrammar(path)`.
Contributed themes should go through the ported workbench theme service
(`workbenchThemeService.zig` and `ColorThemeData`), which already handles the
JSONC theme/include chain and active-theme restore; `syntaxTheme.initFromThemeService`
converts the active theme's `tokenColors` into `TokenTheme`. Do not add a
second theme registry or bypass `ColorThemeData`. The tokenizer applies theme
rules to the capture scope stack; descendant/exclusion selectors are reduced
to their target scope.

### 11.3 Keybindings and commands

The keybinding registry, resolver and context-key expression/scanner are
already ported (`platform/keybinding/common/*`,
`platform/contextkey/common/{contextkey,scanner}.zig`).
`src/tui/keybindingService.zig` hosts workbench-global, editor-tab,
status-bar, search and editor shortcuts through the abstract service, and
`src/tui/keybindings.zig` keeps the older shortcut table for keys not yet
moved. The browser-specific resolver (`usLayoutResolvedKeybinding`) is not
the terminal path: the TUI has decoded key events in `ui.input`. Implement
terminal key normalisation (ctrl/alt/shift/meta, named keys, chords) and feed
contributed rules into `KeybindingsRegistry.setExtensionKeybindings` (with
`BuiltinExtension`/`ExternalExtension` weight and the extension id); resolve
against the flat terminal context. Start with single-chord bindings and the
`when` keys the TUI exposes (`editorTextFocus`, `editorLangId`,
`resourceExtname`, `inQuickOpen`, ...); document the missing scoped context
keys. Command execution is a round trip: `onCommand:<id>` → activate (if
needed) → `$executeCommand`, with the result returned to the palette.
Built-in TUI commands and contributed commands share `CommandRegistry`/
`MenuRegistry`; `src/tui/commands.zig` remains the execution/palette table.

### 11.4 Configuration, status bar, messages and diagnostics

- Configuration: the file-backed
  `workbench/services/configuration/browser/configurationService.zig` is
  ported for defaults, one user settings file, workspace and folder settings
  (JSONC, correct precedence) and `trusted` filtering. Register
  `contributes.configuration` defaults/schemas on `ConfigurationRegistry`.
  Push `ExtHostConfiguration.$acceptConfigurationChanged(data, change)` from
  the service's change event. Pass the workspace trust flag through
  `ConfigurationService.updateWorkspaceTrust` when `$initializeWorkspace`
  receives it, so restricted settings are filtered. `updateValue`/setting
  writes, language overrides (`[typescript]` blocks) and `ConfigurationTarget`
  are not ported; until they are, `$updateConfigurationOption` /
  `$removeConfigurationOption` must reject rather than pretend to write.
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
- Files: `MainThreadFileSystem` should use the ported
  `ProviderFileService` plus `DiskFileSystemProvider` for local `file:`
  operations. `ProviderFileService.registerProvider` gives
  `$registerFileSystemProvider` a real target, but provider activation,
  change/watch forwarding and non-file schemes remain partial; keep them
  rejected until wired.

### 11.6 Current integration points

The adapter is not greenfield; these are the exact seams that change:

- `src/tui/app.zig` — main loop and `pollInputWithFd`/`pollInputWithHandle`
  call sites; add `pump()` before/after the poll and include the extension
  deadline in the timeout calculation.
- `src/tui/workbench.zig` — owns `fileWatcherFd()`/`fileWatcherHandle()`,
  the status-bar paint, the Quick Access overlay and the workbench command
  routing. The extension service hangs off the same `Workbench` session.
- `src/tui/commands.zig` — the TUI command table. Contributed commands
  register into `platform/commands/common/commands.zig` and the
  actions/`MenuRegistry` metadata layer, with `src/tui/commands.zig` as the
  execution/palette table; `onCommand:<id>` fires before dispatch.
- `src/tui/workingCopy.zig` and `workbench/services/workingCopy/` — the
  `IWorkingCopy` adapter, dirty/content/save events, editor lookup and
  backup/history. Document deltas and restart snapshots start here.
- `workbench/services/textfile/` — `TextFileService` and
  `TextFileEditorModel` for load/save/save participants/encoding. Do not
  write files directly from an actor.
- `workbench/services/editor/common/editorGroupsService.zig` and
  `workbench/browser/parts/editor/` — group/tab identity and reveal logic for
  `$tryShowTextDocument`.
- `workbench/services/language/common/languageService.zig` and
  `src/tui/languageConfiguration.zig` — language contribution registration,
  `files.associations`, and the language-configuration registry.
- `workbench/services/configuration/browser/configurationService.zig` — the
  single source for defaults/user/workspace/folder values; register
  contributed defaults there and listen for change events.
- `platform/log/common/logService.zig` and `src/tui/logger.zig` — host stderr
  and `MainThreadConsole` output; do not write around the log service.
- `platform/storage/common/storage.zig` — in-memory storage for mementos and
  status/menu state; persistence remains an open gap (§16).
- `src/tui/quickInput.zig`, `src/tui/quickAccess.zig` — the TUI views behind
  `MainThreadQuickOpen`. `$show`, `$setItems`, `$setError`, `$input`,
  `$createOrUpdate`, `$dispose` map to existing state transitions; do not
  create a second picker.
- `src/vs/workbench/browser/parts/statusbar/` — the ported status-bar model
  and part. `MainThreadStatusBar.$setEntry` adds an entry to the model, not to
  `src/tui/view.zig`.
- `src/vs/editor/common/model/tokens/textMateTokenizer.zig` and
  `src/tui/syntaxTheme.zig` — grammar and theme targets. A contributed
  grammar registers a tokenizer for a language id; a contributed theme
  publishes colors; neither creates a new tokenizer path.
- `src/vs/workbench/browser/parts/editor/` — the tab/group model used for
  `$tryShowTextDocument`, `$tryShowEditor`, `$tryHideEditor`.
- `src/vs/editor/contrib/...` — hover, suggest, decorations and commands are
  existing consumers; language-feature RPC results convert into their types.

If a new widget is needed, it is a view over an upstream-shaped model under
`src/vs/`, with only terminal rendering in `src/tui/`. That rule applies to
the extension manager UI itself as much as to contributed features.

### 11.7 VSCodeVim compatibility

VSCodeVim 1.32.4 is a useful stress target because it uses both the extension
API and editor behavior heavily: engines `^1.74.0`, activation on
`onStartupFinished` and `onCommand:type`, 75 contributed keybindings, 113
contributed settings, a Vimscript language (`.vim`/`.vimrc`) and grammar, a
`type` command override, and roughly 80 `executeCommand` call sites in
`src/`.

The §7-§10 baseline can activate it and support a basic
edit/selection/decoration loop. It is **not** enough for a usable Vim. The
following slice is required before claiming VSCodeVim support:

| Blocker | Baseline state | Required addition |
|---|---|---|
| Text input and `type` override | Ported in `src/tui/extensions.zig`: printable keys, coalesced text runs and Enter go through `$executeContributedCommand("type", …)`; `default:type` inserts into the TUI editor. `default:replacePreviousChar` is still a no-op. | Keep the IME replacement path and fire `onCommand:type` before dispatch when the contribution registry lands. |
| `window.tabGroups` | All TUI tabs are published in one active group; `:w`, `:bd`, `:bnext` and `gt` work. | Multiple groups, tab move operations, and preview updates; buffer numbers and split navigation. |
| Configuration writes | `$updateConfigurationOption` is accepted but only acknowledged; the value is not stored or re-pushed. | `Configuration.update` for `Global` (and `Workspace` where the TUI persists settings), including language overrides and persistence. VSCodeVim uses it for `:set`, `editor.*` options, status-bar color customizations and `vim.vimrc.path`. |
| Built-in command surface | `default:type`, `default:replacePreviousChar` (no-op), `_setContext`/`setContext`, `vscode.open`, `$tryOpenDocument`/`$trySaveDocument`, `$tryShowTextDocument`, `workbench.action.files.save`, `workbench.action.closeActiveEditor`, `nextEditorInGroup`/`previousEditorInGroup`, `splitEditorRight`/`Down`, and `insertLineBefore`/`After` are wired. | The rest: `cursorMove`, `editorScroll`, `moveActiveEditor`, `joinAllGroups`, `closeOtherEditors`, snippets, formatting, hover/definition/link, and snippet-placeholder navigation. |
| Extension keybindings | The adapter maps VSCodeVim's printable, Escape, Backspace/Delete, arrows, Home/End, Page keys and Ctrl+letter commands directly. | Feed all 75 contributed rules into `KeybindingsRegistry.setExtensionKeybindings`, resolve against the terminal context, and ensure the TUI does not swallow keys before the extension rule. |
| Debug breakpoints | Debug is deferred (§16); no `MainThreadDebugService`. | A breakpoint-only subset: `vscode.debug.breakpoints`, add/remove source and function breakpoints and the breakpoint change event. Without it the `:breakpoints` ex-commands fail; core editing still works. |
| Editor events | §9.1 defines the push shapes. | Implement `onDidChangeTextEditorSelection`, `onDidChangeActiveTextEditor`, `onDidChangeVisibleTextEditors` and `onDidChangeTextEditorVisibleRanges` from the workbench. VSCodeVim updates its mode state from these. |
| Storage | In-memory mementos and working-copy history (§16). | Session support is enough to activate; persistence is needed for VSCodeVim history/registers across restarts. `globalStorageUri` plus local `workspace.fs` already covers its file-backed register storage. |

`workspace.applyEdit` appears only in VSCodeVim's tests, not its runtime, so
`MainThreadBulkEdits` is not required for normal VSCodeVim use. LSP is also
not involved: VSCodeVim is not a language client.

Minimum compatibility slice, in order:

1. `type` / `default:type` / `default:replacePreviousChar` and the
   `onCommand:type` activation path.
2. Full `window.tabGroups` state.
3. Configuration writes for `Global` (and `Workspace` when supported).
4. The built-in command set above.
5. Extension keybinding routing.
6. Selection/visible/active editor event pushes.
7. Breakpoint subset for `:breakpoints`.

Until those exist, expect VSCodeVim to activate and handle simple insert/normal
editing, but fail on buffer/tab commands, `:set`/status-color updates,
snippets, formatting, split commands, breakpoints, and motions that delegate
to `cursorMove`/`editorScroll`. Treat VSCodeVim as an end-to-end compatibility
target, not as part of the first usable extension system.

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
- **Restart is not a reconnect.** The new host has new provider handles,
  decoration-type keys, status-entry ids, output channels, diagnostics owners
  and memento caches. Discard every host-owned handle before replaying
  state: re-register decoration types, re-push all open documents and
  editors, re-send diagnostics and status entries, and re-register language
  features. Workbench-side state survives and is the source for the replay:
  scanned manifests/contributions/settings, `WorkingCopyService` working
  copies, `WorkingCopyBackupService`/`WorkingCopyHistoryService`, editor
  groups and the open editor state (the `TextFileEditorModel` instances once
  the TUI editor is migrated). Rebuild the documents-and-editors delta from
  those services, not from a stale host map. A stale handle that is
  accidentally reused will hit an unrelated object or be rejected; do not
  keep a handle map across restarts. Backup and history are in-memory today,
  so a process crash still loses them (§16).
- **Quit.** Send `Terminate`, drain, close fd 4, wait for exit with a timeout,
  then kill. Deactivate extensions host-side before the transport closes.
- **Logs.** Host stderr is captured to `<data dir>/extension-host.log` and
  `MainThreadConsole` messages are currently dropped. Neither may reach the
  ANSI frame stream; do not keep a second logger in the extension adapter.

The manager state to mirror is small and should not be rebuilt ad hoc:

- `_cachedActivationEvents` maps an event string to one in-flight promise;
  repeated `activateByEvent` calls for the same event return the cached
  promise. `_resolvedActivationEvents` records completed events so the
  manager can answer `activationEventIsDone` without re-asking the host.
- `_proxy` is the promise for the host proxy; `_hasStarted` flips once the
  proxy resolves. `start()` sends the extension snapshot delta and
  `$startExtensionHost`; `deltaExtensions()` computes the outgoing delta and
  is a no-op when the host already has that version.
- `dispose()` disposes the extension host, then the RPC protocol (which
  rejects pending replies), then each customer; a customer that throws
  during disposal is reported as an unexpected error, not allowed to abort
  the rest.
- `activate()` and `activateByEvent()` both wait for `_proxy`, so a call made
  before the host starts queues instead of failing. Preserve that ordering:
  do not answer "not supported" merely because the proxy is still pending.

## 14. Roadmap

Each stage lands green (`zig build`, `zig build test --summary all`,
`zig fmt --check <changed>`, clean `git diff --check`) and updates this
document and `README.md`.

At HEAD `e98be57` the prerequisite services in §3.3 are present, but no
extension module, protocol or scanner exists. S1 is partial (`buffer`,
`uri`, `errors` and `cancellation` files exist; their complete upstream
suites are not all registered; marshalling/JSONC/semver are absent), and the
S4 host layers (keybindings, context keys, language, configuration, status
bar, quick input, commands/actions) are ported. The stages below describe the
remaining work.

**S0 — spike.** Build the host (`pnpm install --frozen-lockfile && pnpm run
compile`), write `host/extensionHost.js` with fd 3/4 framing and the trimmed
service list, and boot the real `ExtensionHostMain` with a fixture extension
that reaches `activate()`. Assert: no stdout pollution, `Ready`/`Initialized`
order, workspace/config calls, `$startExtensionHost`, the host's internal `*`
activation (there is no workbench `$activateByEvent("*")`), console
forwarding, clean `Terminate`. Record the boot call list and raw frames here.

**S1 — foundation codecs.** `buffer.zig` and `uri.zig` exist; extend
`errors.zig` (`SerializedError`, `transformErrorForSerialization`) and
`cancellation.zig` rather than creating second files. The remaining pieces
are `marshalling.zig`, `marshallingIds.zig`, `uriIpc.zig`, `json.zig`
(JSONC) and the semver subset. Port `buffer.test.ts`, `uri.test.ts`,
`marshalling.test.ts`, `errors.test.ts` and `cancellation.test.ts`
completely. For `json.test.ts`, port the scanner/parser cases for the JSONC
surface the manifests use; JSON editing/formatting/visitor behavior is out of
scope and is listed in §16. The semver subset gets focused tests for the
`valid`/compare/prerelease behavior the scanner and validator use.

**S2 — RPC and interop smoke test.** `proxyIdentifier.zig`,
`rpcProtocol.zig`, `extensionHostProtocol.zig`, `ipc.zig`,
`ipc.pipe.zig`, generated `extHost.protocol.zig` plus the method manifest.
Port the full `rpcProtocol.test.ts` and add golden hex vectors captured from
the real host. Add a thin Zig↔host smoke test now: initialize workspace and
configuration, start the host, activate the fixture, execute one command,
cancel one request, and send/receive a buffer. This front-loads the risk that
the actor table or transport is wrong.

**S3 — manifest and scan.** `platform/extensions/common/extensions.zig`,
`extensionValidator.zig`, `extensionsScannerService.zig`,
`implicitActivationEvents.zig`, `extensionDescriptionRegistry.zig`. Port
`platform/extensions/test/common/extensionValidator.test.ts`,
`platform/extensions/test/common/extensions.test.ts`, the node
`extensionsScannerService.test.ts` (adapt the Node fs harness to Zig temp
dirs), and `extensionDescriptionRegistry.test.ts`. The scanner's profile and
cache behavior is a documented deviation, not a reason to skip manifest
validation.

**S4 — contributions and TUI.** The keybinding registry/resolver, context-key
expression/scanner, workbench language service, configuration service,
status bar, quick input and commands/actions layers already exist. This stage
adds `extensionsRegistry.zig`, `menusExtensionPoint.zig`, `TMGrammars.zig`,
`themeExtensionPoints.zig`, `configurationExtensionPoint.zig`, the
contribution points from §8, and the palette/diagnostics wiring. Port
`mainThreadCommands.test.ts` and the applicable `mainThreadQuickOpen.test.ts`
harness cases; reuse the existing context-key/resolver suites and add focused
extension-point tests because upstream has no single registry suite.

**S5 — manager and actors.** `extensionHostManager.zig`,
`extensionHostProxy.zig`, and the baseline `mainThread*.zig` set from §7,
boot-critical first. Restart and shutdown from §13. Use the ported working
copy/text file/editor group/file/status/log services from §3.3 rather than
new state; use the browser `extensionService.test.ts` as the behavior
reference for the manager state machine, with a fake protocol instead of a
browser workbench.

**S6 — documents, editors and features.** §9 and §10: document/editor deltas,
text-editor RPCs, language features, filesystem, output, progress, secrets,
editor tabs, languages/grammars/themes. Port
`editor/common/languageFeatureRegistry.ts` (selector scoring, exclusivity,
ordering, release) before `MainThreadLanguageFeatures`; use the existing
working-copy/text-file/editor-group services from §3.3.

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
  deactivation; the bundled fixtures are selected in §15.2.
- **TUI tests**: palette, quick input, status row, diagnostics gutter marks,
  keybinding dispatch, and the multi-source poll/pump path.
- **Regression tests** for every bug found while porting.

### 15.1 What each suite must cover

Ported suites are not "the happy path with the upstream name". Several
prerequisite suites already exist and should be extended rather than
duplicated: keybinding/resolver and context-key scanner/parser, the
configuration service, working copy and text-file model, language service and
language configuration, status bar, and log. The extension-specific minimum
case list, taken from the upstream tests and the protocol rules above:

- **`rpcProtocol.test.ts`**: simple call; call whose handler returns
  `undefined`; buffer argument; buffer result; already-canceled token;
  `CancellationToken.None` as a trailing argument; cancellation while the
  handler is pending; cancel handler released when the call never settles;
  no cancel entry for an uncancellable call; thrown `Error`; rejected
  `undefined`; circular reply → `null`; thrown non-`Error` value; top-level
  `undefined` arg arrives as `undefined`; cyclic request argument throws
  before send; `SerializableObjectWithBuffers` round-trip. Add: ack before
  reply, ack after a synchronously sent request, handler throwing still
  acks, unknown reply id ignored, dispose rejects pending, unresponsive
  deadline/reset, and a golden vector for every message type.
- **`buffer.test.ts`, `uri.test.ts`, `marshalling.test.ts`, `errors.test.ts`,
  `cancellation.test.ts`**: complete ports, not subsets. `json.test.ts` is
  ported for the scanner/parser surface (comments, trailing commas, escapes,
  duplicate keys, errors with byte offsets) and is exercised against the
  bundled `../vscode/extensions` manifests; the JSON edit/format visitor
  suites are out of scope per §16. URI tests include `joinPath`, `$mid`,
  revival and the URI transformer.
- **`extensionValidator.test.ts`**: every manifest-shape error, semver
  version validity, `engines.vscode` caret/range/x/minimum forms, prerelease
  date gates, builtin and declarative exemptions, and dependency/array type
  checks. A range parser bug must fail here, not in activation.
- **Node `extensionsScannerService.test.ts`**: bundled/user/dev roots,
  identifier normalization, defaults, target platform, preRelease,
  `extensionPack`/`extensionDependencies`, invalid manifests, and duplicate
  versions. Adapt the Node fs setup to Zig temp directories; do not delete
  cases that are awkward to set up.
- **`extensionDescriptionRegistry.test.ts`**: add/remove/contains/
  activation-events, global vs local registry, and the "same extension,
  changed value" delta behavior from §8.3.
- **`languageFeatureRegistry` (new)**: selector scoring, language/scheme/
  pattern matching, exclusive-provider takeover, registration order,
  provider release and handle disposal. This registry is missing today; the
  actor tests are not meaningful until it exists.
- **Manager/actor tests**: boot order, `$initializeWorkspace` before
  `$startExtensionHost`, `*`/`onStartupFinished` host-driven activation,
  crash/restart handle invalidation, clean shutdown, and one test per
  baseline actor method family (`mainThreadCommands`, `mainThreadConfiguration`,
  `mainThreadDocuments`, `mainThreadEditors`, `mainThreadQuickOpen`).
- **VSCodeVim smoke (e2e)**: once the §11.7 slice exists, install VSCodeVim
  1.32.4 as a development extension and assert `onCommand:type`, insert/normal
  typing, `h`/`l`, `:q`, `:bd`, `:set`, a split command and `:breakpoints`.
  This is an end-to-end compatibility test, not part of the hermetic suite.

Golden vectors are generated by a Node script from the pinned host's own
`rpcProtocol.ts` and a captured `MessagePassingProtocol`; the script writes
hex plus a short description, and both the Zig encoder and decoder assert the
same bytes. Regenerate only when the pin changes; a diff is a version-drift
signal, not a test to loosen. Keep a comment in each fixture naming the host
commit.

### 15.2 Bundled extension fixtures

The pinned `../vscode/extensions` tree is a real fixture corpus: at 1.147.0 it
has 95 extension manifests, 61 declarative and 34 with `main`/`browser` code.
Do not vendor it; consume it when the checkout is present, as `build.zig`
already does for grammars and the Dark+ theme. Use this first set:

| Fixture | Path | Covers |
|---|---|---|
| `theme-defaults` | `../vscode/extensions/theme-defaults` | theme and icon-theme contribution points, JSONC comments, the `dark_plus` → `dark_vs` include chain, `package.nls.json` |
| `markdown-basics` | `../vscode/extensions/markdown-basics` | `languages` with a commented `language-configuration.json`, grammar, snippets, NLS manifest |
| `vscode-smoketest-ext-host` | `../vscode/test/smoke/extensions/vscode-smoketest-ext-host` | plain-JS extension, `onStartupFinished`, command registration, activation PID marker; `deactivate()` writes a marker set up by a command |
| `search-result` | `../vscode/extensions/search-result` | `onLanguage:search-result` activation, language + grammar contribution, document symbols/completion/definition/decorations; its document-link registration is deferred (§10), and the `void` RPC degrades to no links |
| `notebook-renderers` | `../vscode/extensions/notebook-renderers` | declarative extension whose only contribution is unsupported `notebookRenderer`; the scanner must keep it and ignore the point |
| `copilot` | `../vscode/extensions/copilot` | large real-world manifest with many unsupported contribution points; scanner stress test, not an activation target |

`theme-defaults` and `markdown-basics` are the first S3/S4/S6 fixtures: both scan
without a host, and both contain the JSONC (comments, includes) the parser and
contribution loaders must handle. `vscode-smoketest-ext-host` is the first
S2/S5 host fixture: its `extension.js` needs no compile step, activates on
`onStartupFinished`, and registers commands and a deactivation marker.
`search-result` is the first language-triggered activation fixture once the
extensions are compiled. It also registers a document-link provider; that
registration is deferred in §10, but its RPC method returns `void`, so
activation can continue and the provider simply never runs. Do not use it to
test link behavior. `notebook-renderers` and `copilot` exercise graceful
unknown-contribution handling; do not use them for a happy-path activation
test.

Constraints:

- **Code extensions need the upstream build.** `../vscode/out` and
  `extensions/*/out` are absent in the checkout. Run
  `pnpm install --frozen-lockfile && pnpm run compile` (gulp `compile`,
  which includes `compile-extensions`) before activating
  `search-result` or any other code extension. The smoke fixture is plain JS
  and needs no extension compile, but still needs the built host.
- **Builtin fixtures skip engine validation.** All bundled extensions report
  `isBuiltin: true`, and `isValidExtensionVersion` returns early for builtins
  and declarative extensions. They test manifest shape and `semver.valid`, not
  `engines.vscode` rejection. Use the upstream validator fixtures or a
  temporary manifest with `isBuiltin: false` for that. Loading a bundled
  extension through `--extension-development-path` also flips it out of the
  builtin path, so its old `0.10.x` engine may be rejected.
- **Keep the default test suite hermetic.** Gate `../vscode/extensions` scans
  on the checkout existing, or put them under `zig build test-e2e`, like the
  existing grammar/theme fallback in `build.zig`. A missing checkout must skip
  the fixture, not fail the unit suite.
- **Do not use `vscode-colorize-tests` yet.** It registers a semantic-tokens
  provider during activation, which is deferred in §10; it will exercise the
  unsupported-feature path, not a clean activation.
- **The extensions root is not an extension.**
  `../vscode/extensions/package.json` is the extensions workspace manifest;
  scan the child directories only.

### 15.6 JSON/JSONC language features

`json-language-features` is a code extension, not a declarative one, so it is
not activated through the extension host. Instead the pinned server is bundled
separately with `host/build-json-server.js` and driven by
`src/vs/workbench/services/language/common/jsonLanguageClient.zig`, a small
synchronous LSP client. The client initializes with pull-diagnostics
capabilities, opens JSON/JSONC documents, sends full-text changes, pulls
syntax diagnostics, and forwards completion requests.

The TUI polls only the active editor, publishes a `JSON Problems` status-bar
entry, registers the server completion provider on JSON/JSONC tabs, and forwards
mouse hover through `TuiHoverProvider` (schemas referenced by `$schema` are
resolved by the server). The server bundle is optional: without
`host/dist/jsonServer.mjs` the editor keeps the bundled grammar and no JSON
language features are attached. Formatting, code actions, configured
`json.schemas` associations and workspace diagnostics remain unwired.

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
- VSCodeVim 1.32.4 is not supported by the baseline: it needs text-input
  `type`/`default:type` dispatch, full `window.tabGroups`, configuration
  writes, extra built-in commands, extension keybinding routing and a
  breakpoint subset (§11.7).
- File system providers other than local `file:`; `workspace.fs` is local
  read/write only. `ProviderFileService.registerProvider` exists, but provider
  activation, change/watch forwarding and non-file schemes are not wired.
- Scoped `ContextKeyService`: only the expression/scanner plus the terminal's
  flat context are ported, so contributed `when` clauses that need scoped keys
  cannot be resolved yet.
- Configuration writes (`updateValue`), language overrides and
  `ConfigurationTarget`; `$updateConfigurationOption` /
  `$removeConfigurationOption` must reject until those exist.
- Persistent storage: `InMemoryStorageService`, in-memory working-copy
  backups/history, and no disk memento backend, so state does not survive a
  process restart.
- The console logger and URI-keyed logger registry; the terminal has one file
  logger (`src/tui/logger.zig`) and no per-channel log resources.
- Localization bundles (`nlsBaseUrl` is omitted) and manifest
  `package.nls.json` localization.
- Full JSONC/schema validation; only the subset the TUI consumes is
  validated. JSON editing, formatting and visitor services are not ported at all.
- Full semver ranges; only the subset needed by extension validation and
  version comparison.
- Named-pipe transport and `PersistentProtocol`; the launcher's private
  fd/handle pair is the only transport. On Windows the same frames travel
  over inherited handles rather than POSIX fd numbers.
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
3. **Storage persistence.** `MainThreadStorage` is required: mementos always
   go through `$initializeExtensionStorage`/`$setValue`. The current
   `InMemoryStorageService` is session-only and working-copy backups/history
   are in-memory, so decide on a workbench-side disk backend (or document
   per-session mementos). Host-side persistence would require modifying
   upstream and is not an option under decision 2.
4. **`onStartupFinished` timing.** The host fires it internally after eager
   `*` activation (or its 10-second cap); the workbench cannot make it fire
   later with `$activateByEvent`. Decide whether to delay
   `$startExtensionHost` until after the first painted frame — which delays
   `*` too but keeps the host unmodified — or start the host immediately and
   document that extensions may activate before the first frame. Either way,
   do not patch the host.
5. **Workspace trust default.** Decide whether an untrusted folder prompts,
   starts in restricted mode, or refuses to start the host. The TUI should
   match VS Code's restricted-mode semantics as far as the API surface goes.
6. **Golden-vector ownership.** Decide whether the capture script lives in
   `build/` or in a separate `tools/` folder. It uses the pinned host's own
   modules, so it must not become a runtime dependency of the editor.

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

`MainThreadLanguageFeatures` has 47 methods in 1.147.0. The nine supported
ones are listed above; the other 38 are deferred and must still reject or
return empty according to their declared return type. In source order they
are: `$registerCodeLensSupport`, `$emitCodeLensEvent`,
`$registerDeclarationSupport`, `$registerImplementationSupport`,
`$registerTypeDefinitionSupport`, `$registerEvaluatableExpressionProvider`,
`$registerInlineValuesProvider`, `$emitInlineValuesEvent`,
`$registerDocumentHighlightProvider`, `$registerMultiDocumentHighlightProvider`,
`$registerLinkedEditingRangeProvider`, `$registerReferenceSupport`,
`$registerPasteEditProvider`, `$registerNavigateTypeSupport`,
`$registerRenameSupport`, `$registerNewSymbolNamesProvider`,
`$registerDocumentSemanticTokensProvider`, `$emitDocumentSemanticTokensEvent`,
`$registerDocumentRangeSemanticTokensProvider`,
`$emitDocumentRangeSemanticTokensEvent`, `$registerInlineCompletionsSupport`,
`$emitInlineCompletionsChange`, `$emitInlineCompletionModelInfoChange`,
`$emitInlineCompletionProviderOptionsChange`, `$registerSignatureHelpProvider`,
`$registerInlayHintsProvider`, `$emitInlayHintsEvent`,
`$registerDocumentLinkProvider`, `$registerDocumentColorProvider`,
`$registerFoldingRangeProvider`, `$emitFoldingRangeEvent`,
`$registerSelectionRangeProvider`, `$registerCallHierarchyProvider`,
`$registerTypeHierarchyProvider`, `$registerDocumentOnDropEditProvider`,
`$resolvePasteFileData`, `$resolveDocumentOnDropFileData`,
`$setLanguageConfiguration`. See §10 and §16.

One naming trap in this inventory: the wire `sid` of `MainThreadDialogs` is
`MainThreadDiaglogs` (upstream typo, §5.2). The list above uses `MainContext`
keys, not `sid` strings; §5.2 lists every key/`sid` mismatch and the generated
table is authoritative.

## Appendix B — per-stage checklist

Before a stage is reported done, check each item:

- The upstream file and test paths exist in this repository with the upstream
  names and folder structure; the test is registered in `src/tests.zig`.
- The file header says `// Port of ...` (or states the deliberate
  adaptation), and any behavior that is not ported names the exact missing
  capability in `README.md` and, for UI limitations, `docs/terminal-ui.md`.
- Every returned frame, buffer and JSON value has an owner with a
  `deinit`/`free` path; actor registrations are torn down in reverse order.
- Interfaces use `.interface()`; editor `ICommand` adapters expose
  `interface()` and `getEditOperations`/`computeCursorState`; no
  `toInterface` variants.
- The generated table matches the current pin (nid/sid/method counts) and the
  build fails if it does not.
- `zig build`, `zig build test --summary all`,
  `zig fmt --check <changed files>` and `git diff --check` are clean.
- The test additions include the upstream cases named in §15.1 and a
  regression test for every bug fixed during the stage.
