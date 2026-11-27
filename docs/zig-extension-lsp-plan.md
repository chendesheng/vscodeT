# Faithful port of the Zig VS Code extension and ZLS LSP support

Status: implementation in progress. Initial real Zig/ZLS activation and hover are verified on macOS; the full advertised-capability matrix is not complete.
Upstream specification: VS Code 1.147.0 at `e31c2e52f563620846caab877103f630ea361b9c`.

## Fidelity contract

Every new feature is a literal port from the pinned `vscode/` checkout, not a terminal-shaped reimplementation:

- Mirror the upstream owner file and folder. Keep upstream types, names, method decomposition, defaults, option values, error paths and event ordering. Use Zig naming for fields/functions only where the surrounding port already does.
- Port the **view layer** as well as the model/controller: widgets, decoration classes/kinds, hover/hit testing, focus/key handling, `View`/`ViewPart` render flow, `shouldRender`/`prepareRender`/`render`, and upstream CSS rules where the widget uses class rules.
- Preserve upstream async behavior: `ProviderResult`, cancellation, request ordering, debounce/delay and disposal. Results complete on the existing window dispatcher/deadline queue; no blocking provider calls and no polling/revision counters.
- Preserve ownership/lifetimes: services, registrations, caches, result ids, subscriptions and pending requests are released by their upstream owner.
- Port the upstream tests for each ported file, including edge cases and event/order assertions. Do not weaken tests because the terminal UI differs.
- Terminal substitutions are allowed only at the DOM/CSS/input/IO boundary: `ui` nodes/styles instead of DOM, cell-grid paint instead of CSS layout, terminal key decoding/focus instead of browser events, native file IO instead of browser FS. Every substitution is stated in the file header, `README.md` and `docs/terminal-ui.md`.
- Do not add a shortcut controller, sync polling, revision-based cache, custom quick-pick-only action menu or other parallel mechanism when upstream has a model/controller/registry for it.
- Do not edit `vscode/` and do not change the submodule pin. `src/vs/` must not import `src/tui/`; run `zig build check-workbench`.

## Corrections to the previous draft

- **No custom extension-directory fallback.** Automatic pickup uses the ported upstream `IEnvironmentService.extensionsPath` resolution (default `~/.vscode/extensions`; explicit `--extensions-dir`/`VSCODE_EXTENSIONS`/`VSCODE_PORTABLE` still win). The previous plan's `.vscode-server`/Insiders/OSS fallback is removed as non-upstream behavior.
- **No executable-only host inventory in the UI service.** Align the host extension set with upstream `AbstractExtensionService`/`ExtensionHostManager`: all enabled, deduped installed extensions (system + user) are handed to the host; the host's activation events decide what runs. The port's split install layout (catalog manifests vs. runtime bundles) is handled at path resolution only and documented.
- **No ad hoc save hook, bulk-edit callback or host inventory in the TUI adapter.** Port the upstream `ITextFileService` working-copy/save-participant flow, `IBulkEditService` and `MainThreadBulkEdits`; the actor calls the portable service exactly as upstream.
- **No skipped portable behavior.** Rename preview, inlay-hint hover/click locations, code-action lightbulb/menu, workspace-symbol query/cancel/resolve, signature-help overloads, semantic token range requests and provider-change events are all in scope.
- **Do not build on the existing simplified layers where they deviate from upstream.** The touched `smartSelect.zig`, `wordHighlighter.zig`, `folding.zig`, `modelLineProjection.zig`, theme token-color path and provider-invocation bridge are corrected to the upstream structure as part of this work.
- **The sync provider adaptation is replaced.** Native extension-provider requests use deferred responses or owner-scoped WindowIo fibers; `requestSync` remains a direct-call test harness only. Keep new provider contracts on that asynchronous path to preserve upstream `ProviderResult`/cancellation semantics. ZLS requests must not block terminal input, and cancellation/order must match upstream.

## Scope

Target: `ziglang.vscode-zig` installed in the effective VS Code extensions directory, running in the real Node extension host, launching ZLS. The reference combination is Zig extension **0.7.0**, Zig **0.17.0** and ZLS **0.17.0**, as installed locally during review. The extension bundles `vscode-languageclient` 10.0.0-next.15; the host's mock-client dependency (10.1.1) is not a substitute for exercising that bundled client. Record the version, client capabilities and negotiated server capabilities for each reference run; a version change requires rechecking the matrix, not silently changing the acceptance scope.

### Advertised ZLS server capabilities

The following matrix is based on a direct `initialize` response from local ZLS 0.17.0 during review (not yet an initialize exchange through the editor). Reproduce it through the real extension in Stage 1. "All LSP features" means the advertised behavior plus the supporting protocol interactions in the next table. A provider’s optional methods must follow the upstream VS Code contract even when this particular server does not advertise them.

| ZLS capability | Observed value | Registration/provider path and upstream owner |
|---|---|---|
| Position encoding | `utf-16` | Document and provider DTO boundaries; editor offsets are UTF-8 bytes |
| Text document synchronization | open/close, incremental changes (`2`), save, willSaveWaitUntil | `MainThreadDocuments`, `MainThreadDocumentsAndEditors`, text-file save participants |
| Completion | trigger characters, label details; no resolve | `$registerCompletionsProvider` / `$provideCompletionItems`; verify snippets/label details |
| Hover | supported | `$registerHoverProvider` / `$provideHover` |
| Signature help | triggers/retriggers | `$registerSignatureHelpProvider` / `$provideSignatureHelp`; `contrib/parameterHints/**` |
| Definition/declaration/type definition | supported | Existing location registrations |
| References | supported | `$registerReferenceSupport` |
| Document highlight | supported | `$registerDocumentHighlightProvider` / `$provideDocumentHighlights`; `contrib/wordHighlighter/**` |
| Document symbol | supported | Existing registration |
| Workspace symbol | supported (no resolve advertised) | `$registerNavigateTypeSupport` / `$provideWorkspaceSymbols`; `contrib/search/common/search.ts`, `symbolsQuickAccess.ts` |
| Code action | `quickfix`, `refactor`, `source`, `source.organizeImports`, `source.fixAll`; no resolve advertised | `$registerCodeActionSupport` / `$provideCodeActions`; `contrib/codeAction/**` |
| Formatting | document only; range formatting false | `$registerDocumentFormattingSupport`; preserve existing range-formatting providers for other extensions |
| Rename/prepare rename | supported, prepareProvider true | `$registerRenameSupport` / `$provideRenameEdits`, `$resolveRenameLocation`; `contrib/rename/**` |
| Folding range | supported | `$registerFoldingRangeProvider` / `$provideFoldingRanges`; `contrib/folding/**` |
| Selection range | supported | `$registerSelectionRangeProvider` / `$provideSelectionRanges`; `contrib/smartSelect/**` |
| Semantic tokens | full and range; no delta advertised; server legend | Full/range registrations + encoded DTO; `contrib/semanticTokens/**`, `common/services/semanticTokens*` |
| Inlay hints | supported (no resolve advertised) | `$registerInlayHintsProvider` / `$provideInlayHints`; `contrib/inlayHints/**` |
| Workspace folders | supported, change notifications true | `MainThreadWorkspace` / `ExtHostWorkspace` workspace data and folder change flow |

### Required protocol interactions and VS Code extension APIs

These are not all entries in the server's `initialize` response, but they support the actual language-client and extension lifecycle:

| Interaction/API | Registration/provider path | Upstream owner |
|---|---|---|
| Diagnostics | `languages.createDiagnosticCollection` | `MainThreadDiagnostics` |
| Will-save edits | `workspace.onWillSaveTextDocument` | `mainThreadSaveParticipant.ts`, text-file save and bulk-edit service |
| Workspace edits | `$tryApplyWorkspaceEdit` | `mainThreadBulkEdits.ts`, bulk-edit service |
| Workspace configuration | `getConfiguration`, configuration change events | `MainThreadConfiguration` |
| Watched files | `$watch`/`$unwatch`/`$onFileEvent` | `mainThreadFileSystemEventService.ts` |
| Progress | `$startProgress`/`$progressReport`/`$progressEnd` | `mainThreadProgress.ts` |
| Language status | `$setLanguageStatus`/`$removeLanguageStatus` | `mainThreadLanguages.ts`, language status service and contribution |
| Output and logging | output-channel create/append/show/hide/dispose, log channels | `MainThreadOutputService`, `MainThreadLogService`, output service and view |
| Filesystem/storage | `workspace.fs`, extension storage and configuration | `MainThreadFileSystem`, storage/configuration services |

Optional provider resolution, semantic-token delta updates and range formatting are not required to demonstrate this ZLS version's advertised behavior. Preserve existing support and port the upstream lifecycle of the provider contracts touched by this work, including optional resolution, release and change events; cover those paths with the mock client without misrepresenting them as negotiated ZLS features.

Not included: LSP features ZLS does not advertise (code lens, document links/colors, call/type hierarchy, linked editing, inline values, notebooks), and independent non-LSP features of the Zig extension (its test runner, debug, tasks/build-on-save, terminal integration, code lens). Startup APIs used by the actual extension remain in scope even if they also support an excluded feature. No marketplace, remote extension host, or workspace trust/sandbox. The local Windows named-pipe host transport is shared infrastructure; Windows LSP provider behavior requires its own interoperability validation.

## Assumptions

- The Node extension host remains optional (`zig build host`) on Linux, macOS and Windows. Missing host/Node is diagnosed and the editor continues with declarative extensions.
- ZLS is supplied by the extension (or `zig.zls.path`). The extension's `workspace.fs` installer is supported by the ported local `MainThreadFileSystem`; network access remains external.
- Configuration writes from extensions stay session-memory only (existing limitation); users persist `zig.path`, `zig.zls.path` and `zig.zls.enabled` (string `"on"`, not boolean; extension default is `"ask"`) in settings if they must survive restart.
- User-installed extension JavaScript executes with user privileges when enabled; no sandbox is added.

## Implementation record (2026-11-27)

| Owner | Current status |
|---|---|
| `abstractExtensionService`, scanner and activation tracker | Effective enabled merged inventory, system bundle path resolution, declarative-only entries and user overrides implemented; live hot rescan/enablement is still next-launch only. |
| `MainThreadWorkspace` | Real empty/multi-folder startup data and folder-change notification implemented; local glob check uses the existing file walker. Full cancellation during a running search, workspace editing and configuration-change propagation still need reconciliation. |
| `MainThreadFileSystem` | Local stat/readdir/read/write/mkdir/delete/rename/copy and provider info implemented through IFileService; custom scheme provider registration, asynchronous disk mutations and installer-specific verification remain outstanding. |
| `MainThreadLanguageFeatures` | Existing hover, completion, definition/declaration/type definition, references, symbols, highlights, code actions and formatting registrations retained; signature help, rename, workspace symbols, folding, selection range, semantic tokens and inlay hints remain unported. |
| `MainThreadLanguages` and language status | Owned status registrations, selector filtering, severity/source/id ordering, replacement/removal, and an active-editor combined status-bar entry implemented. Dedicated pinning, clickable tooltip details/commands, and the other language actor APIs remain gaps. |
| Other host support and consumer views | Save/bulk-edit foundation already present; output/logging, file-watcher RPC, progress, and full portable feature consumers still outstanding. |

Reference run: real installed Zig extension **0.7.0**, Zig **0.17.0**, ZLS **0.17.0**, pinned Node extension host on macOS. The opt-in end-to-end test passed in two modes: standalone `sample.zig` (implicit `onLanguage`) and a workspace containing `build.zig` with no initially open document (workspace activation); both returned hover containing `answer` through the actual ZLS provider and exposed the real `zig.status` and `zig.zls.status` items in the active-editor status bar. The negotiated initialize response, complete provider matrix and Windows/Linux real-Zig runs have not yet been captured. Run:

```sh
VSCODE_T_ZIG_EXTENSION="$HOME/.vscode/extensions/ziglang.vscode-zig-0.7.0" \
VSCODE_T_ZIG_PATH="$(command -v zig)" \
VSCODE_T_ZLS_PATH="$(command -v zls)" \
zig build test-e2e '-De2e-filter=Extensions: real Zig extension'
```

The environment variables are explicit opt-in reference assets, not special production extension-resolution rules. The test uses temporary settings and workspaces. Normal CI continues to run the same native suites on all three platforms; only the optional real-Zig test skips without those assets.

## Stage 0 — Reconcile the implementation and upstream contracts

Start with a source/test inventory at the implementation commit, not a new parallel implementation. The review found existing asynchronous provider/RPC paths in `extensionHostAdapter.zig` and `mainThreadLanguageFeatures.zig`, a `MainThreadBulkEdits` actor, bulk-edit service and preview, and a code-action model/controller/menu/lightbulb. These are existing implementations, not proof of complete upstream fidelity or real Zig support. Classify each relevant owner as complete, partially ported or missing against the pinned source and tests. Record the remaining synchronous call sites, missing actor registrations, service dependencies, events and view gaps. Preserve existing integration tests; extend or repair established owners in place.

Identify the shortest upstream-shaped path to Stage 1, including any host APIs required by the real extension's activation. Do not wait for all widgets or every provider consumer to be ported before exercising the actual extension.

## Stage 1 — Effective extension set and real Zig/ZLS startup

- Use `src/vs/workbench/services/extensions/common/abstractExtensionService.zig` (upstream shared owner) and `extensionHostManager.zig`, migrating the existing `common/extensionService.zig` helpers to their proper owners as appropriate. Build the host extension set with the same effective installed/merged/deduped inventory and enablement state as upstream: all enabled system + user extensions, `isBuiltin`/`isUnderDevelopment` flags, no `main` filtering. Respect the scanner and extension-description registry contracts. For system extensions use the runtime bundle location when the executable install exists, otherwise the installed catalog location (terminal installation split; documented). User extensions use their scanned location. Pass all descriptions to the host; activation events govern execution.
- `src/tui/app.zig` / `vscodeProfile.zig`: keep upstream `extensionsPath` resolution, no alternate-root fallback; call the portable inventory builder. The default VS Code directory is already scanned and is the automatic source.
- `src/vs/workbench/api/browser/extensionHostAdapter.zig`: preserve implicit `onLanguage` activation, document mirroring and startup ordering. The actual Zig 0.7.0 manifest also declares `workspaceContains:build.zig`, `workspaceContains:build.zig.zon` and `workspaceContains:./.zigversion`; verify the upstream host's existing exact-file activation path and workspace initialization rather than adding a Zig-specific trigger. Complete the upstream `workspaceContains.ts`/`MainThreadWorkspace` contracts where the host requires them (including `$checkExists` for glob search).
- Exercise the actual installed extension immediately, using a temporary Zig workspace and explicit `zig.path`, `zig.zls.path`, and `zig.zls.enabled: "on"` settings to avoid installer/network dependencies. Verify standalone `.zig` and workspace startup paths. Trace the real activation API usage, including filesystem/storage, file watchers, configuration, status items, output/logging and progress; port the prerequisite portions of Stage 2 as needed through their upstream owners. In particular, Zig 0.7.0 creates `zig.status` and `zig.zls.status` via `languages.createLanguageStatusItem`; the current adapter has no `MainThreadLanguages` actor. Do not let a generic empty RPC reply stand in for a required implementation. Further installer behavior is exercised once Stage 2 is complete.
- Verify the host logs and actual spawned ZLS process, negotiated `initialize` result, incremental document synchronization and registration of the advertised provider set. Missing provider registrations may be completed here using the existing registries/actor; full consumer and view behavior belongs to Stage 3. Prove at least one real provider response (for example hover or completion) reaches the editor. Record exact results and remaining gaps before expanding into all language contributions; a mock activation or registration count alone is not this milestone.
- Tests: temp system/user roots; user extension listing, enablement, override merge, declarative-only extension passed but not activated, executable user fixture activated; existing panel tests remain. Add real-extension startup and provider-registration assertions as the first end-to-end tests, gated on the reference assets locally.

## Stage 2 — Complete shared fidelity foundation and host support

Complete the contracts used in Stage 1 and by all language features; reuse the existing implementations audited in Stage 0. Port the upstream portable owners, with terminal service implementations only at the adapter boundary:

The native workbench uses `ui.WindowIo` as its `std.Io` async executor, with window-thread fibers, delegated worker I/O, and readiness wired into the existing dispatcher. The extension transport reader posts a readiness task rather than relying on the TUI loop to pump it periodically. `HostManager.requestAwait` suspends a window fiber until a reply, cancellation, timeout or transport exit; the dispatcher remains free to service nested RPCs. Completion and outline document-symbol requests use their existing deferred contracts. Definition/declaration/type definition/implementation/references actions, the compiled references-view provider commands, and document/range formatting use the window fiber path with model and registry lifetime checks.

The terminal's actual shared `EditorDocument` now invokes the registered `MainThreadSaveParticipant` before taking its snapshot. Explicit save commands, extension `TextDocument.save()`, and single/multiple/whole-window close confirmations use asynchronous save completion. Mounted and resolver-owned offscreen working copies share the window save executor even without extensions; a pending save retains the document until its result is delivered, and the model resolver joins outstanding saves during teardown. The snapshot records the actual saved model version before delegating the atomic write; later edits remain dirty. The extension-host fixture exercises both nested workspace edits within a suspended RPC and a real `onWillSaveTextDocument.waitUntil` edit before disk write. The legacy standalone text-file model and direct synchronous provider test entry points remain compatibility paths; the native executable rejects recursive synchronous extension-host RPC pumping. Search replacement snapshots its edit batches before yielding, performs closed-file writes with detached I/O, and settles the working-copy saves before removing or refreshing search results. Account lookup/consent/sign-out, task activation/provider collection, and terminal-completion activation also use window-owned asynchronous continuations. Format-on-type now follows the registered first provider and the resource-aware `editor.formatOnType` setting, invokes it from a cancellable window fiber, and computes minimal edits on detached snapshots. Model/registry changes dispose pending requests. The optional native JSON language client also posts transport readiness to the same window dispatcher, uses deferred completions and awaits formatting in a cancellable window fiber. Its standalone startup/testing path is still synchronous. The full upstream text-file model/participant lifecycle (including autosave reasons and timeout regressions) and the remainder of the plan's unported LSP feature contracts remain to reconcile; these are not Windows or terminal limitations.

- `src/vs/editor/common/languageFeatures*` / provider interfaces: extend the existing async path to preserve upstream `ProviderResult`/thenable semantics using the window dispatcher and deadline mechanism (no polling). Keep newly ported `LanguageFeatureRegistry` consumers on deferred provider results or owner-scoped window fibers with cancellation and ordered completion; the production native RPC path no longer supports recursive `requestSync`. Test out-of-order replies, cancellation, disposal and late results without blocking terminal input.
- `src/vs/editor/browser/services/bulkEditService.zig` + `src/vs/workbench/contrib/bulkEdit/browser/{bulkEditService,bulkTextEdits,bulkFileEdits}.zig` and `preview/**`: complete the existing portable bulk-edit and preview services; preserve grouping, version checks, undo metadata, confirmation, cancellation and ordering across models and files. Reuse `MainThreadBulkEdits`; `$tryApplyWorkspaceEdit` must return the upstream boolean result and preserve undo/refactoring options.
- Text-file service/working-copy save flow: upstream `services/textfile/common/textfiles.ts` defines the contracts, `services/textfile/browser/textFileService.ts` owns `AbstractTextFileService`, and `services/textfile/common/{textFileEditorModel,textFileEditorModelManager,textFileSaveParticipant}.ts` own model/participant lifecycle. Reconcile the current `common/textFileService.zig` helper with these owners rather than extending direct `Editor.save` writes or creating a duplicate service. `FileEditorInput.save` delegates to the service; save commands complete through the window dispatcher with dirty/version transitions and saved events in upstream order.
- `mainThreadSaveParticipant.ts` + the real `ExtHostDocumentSaveParticipant`: invoke through that text-file service. The extension host may call `$tryApplyWorkspaceEdit` back into the main thread during `$participateInSave` and must receive its result before returning. Keep the dispatcher and RPC receive path live while awaiting the save participant, so nested requests and their model change events finish before the write and `$acceptModelSaved`. Preserve upstream timeout (1750 ms), error handling, cancellation, version checks, participant disposal and save serialization. Test the nested RPC sequence with a real host, timeout/failure, cancellation, intervening edits, ordered events and no write after cancellation where upstream cancels the save; ensure late replies do not mutate disposed owners.
- `mainThreadFileSystem.ts` → local `file:` support over `ProviderFileService`/`DiskFileSystemProvider`; stat/readdir/readFile/writeFile/mkdir/delete/rename/copy/ensureActivation. Document custom-scheme provider registration as a separate portable gap, not a terminal capability restriction. Verify the Zig extension's filesystem/storage installer path independently of the explicit-executable startup path.
- `mainThreadFileSystemEventService.ts` → `$watch`/`$unwatch`/`$onFileEvent` over the existing file-watcher service; preserve scope, lifecycle and file change ordering.
- `mainThreadWorkspace.ts` → workspace folder initialization and change propagation to `ExtHostWorkspace`; test language-client folder change notifications for workspaces supported by the editor. Verify UTF-16 positions, incremental open/change/save/close synchronization and ordered model versions across all providers, including non-ASCII text and surrogate pairs.
- `mainThreadProgress.ts` + a terminal progress scheduler/status-bar adapter.
- `mainThreadLanguages.ts` + `services/languageStatus/common/languageStatusService.ts` and `contrib/languageStatus/browser/languageStatus.ts`: port the language-status registration, updates, selector filtering, command/details, busy/severity state, removal and active-editor contribution; terminal view adapts the status presentation, not the service contract.
- `mainThreadOutputService.ts`/`mainThreadLogService.ts` + `services/output/common/output.ts` and `contrib/output/browser/{outputServices,outputView,output.contribution}.ts`: port the file-backed channel model/service, channel selection, lifecycle, show/hide, clearing and output panel contribution. `OutputChannel.show()` and the Zig extension's ZLS-output command must reveal the selected channel. Use the terminal view/panel boundary, not a log-only substitute.
- Register missing actors in `extensionHostAdapter.zig`; add upstream-shaped actor tests and RPC buffer-frame tests. Verify startup, shutdown, reconfiguration and extension disposal against real Zig/ZLS as well as the fixture.
- Theme/semantic-token color path: complete the upstream `ColorThemeData` token-color index and `standaloneThemeService` token-theme relationship; the terminal renderer must resolve the same map that semantic styling encodes. No invented shared color map.
- Smart-select/word-highlighter/folding foundations: reconcile existing `smartSelect.ts` (registry + async + selection/model event cache invalidation), `wordHighlighter.ts` (registry + async + multi-model behavior as far as the port supports), and `folding.ts`/`syntaxRangeProvider.ts` (controller + delayed syntax provider) against upstream rather than keeping simplified terminal cores.
- `modelLineProjection.zig`: complete upstream injected-text projection, including `getViewLineContent`/`getViewLineData`, injected token fallback and cursor mapping, so inlay hints can be a literal port later. Verify existing implementation against the upstream cases first.

## Stage 3 — LSP bridge and feature ports

1. `mainThreadLanguageFeatures.ts` → `mainThreadLanguageFeatures.zig`: complete remaining registration/provider calls in the capability table, DTO conversion, selector matching, result-id/chained-cache release, code-action diagnostics context, rename rejection, semantic-token DTO decode/encode, and `$emit…` provider-change events. Port the relevant cases from `extHostLanguageFeatures.test.ts` and upstream actor tests.
2. Workspace symbols: port `contrib/search/common/search.ts` registry/`getWorkspaceSymbols` and `symbolsQuickAccess.ts`/`searchActionsSymbol.ts` with query, debounce/cancellation, resolve and open behavior; terminal quick-input adaptation only at the view boundary.
3. Signature help: port `contrib/parameterHints/browser/{provideSignatureHelp,parameterHintsModel,parameterHints,parameterHintsWidget}.zig` and `parameterHints.css`; keep the widget/controller structure, overload cycling, trigger/retrigger and focus/key handling; terminal content-widget paint only at the DOM boundary. Port `parameterHintsModel.test.ts`.
4. Rename: port `contrib/rename/browser/{rename,renameWidget}.zig` and `renameWidget.css`, including prepareRename, validation, preview mode, accept/reject, input state and cancellation; terminal overlay/input adaptation only. Add model/controller tests and e2e.
5. Code actions: complete the existing `contrib/codeAction/browser/{codeAction,codeActionModel,codeActionController,codeActionCommands,codeActionMenu,lightBulbWidget}.zig` and CSS, plus missing upstream contributions/keybinding resolver as needed; keep the model/controller, lightbulb states, menu ordering and command application; apply workspace edits through Stage 2. Port the three upstream code-action test files.
6. Semantic tokens: port `common/services/{semanticTokensProviderStyling,semanticTokensStyling,semanticTokensStylingService}.zig`, `contrib/semanticTokens/common/getSemanticTokens.zig` and `contrib/semanticTokens/browser/{documentSemanticTokens,viewportSemanticTokens}.zig`; full/range request flow, debounce, version/result ids and provider-change refresh; port the upstream styling/controller tests and add a terminal paint assertion.
7. Inlay hints: port `contrib/inlayHints/browser/{inlayHintsController,inlayHintsHover,inlayHintsLocations,inlayHintsContribution}.zig` over the Stage 2 injected-text projection; preserve hint parts, padding, resolve, hover and click navigation; no deferred view extras. Add injected-text and e2e tests.
8. Folding/selection/highlights: finish the Stage 2 literal ports and wire the LSP registries through the upstream providers; port `syntaxFold.test.ts`, `smartSelect.test.ts` and `wordHighlighter.test.ts` cases.

## Stage 4 — End-to-end, CI and docs

- Add `host/test-fixtures/lsp-language-features/`: a fixture extension using the host's real `vscode-languageclient` dependency and a mock LSP server advertising the reference ZLS capability set. Add separate fixture coverage for optional provider contracts (resolve, token delta, change events) and `Extensions:` e2e tests for every capability and required interaction, including nested will-save, rename, code actions, semantic tokens and inlay hints.
- Expand the Stage 1 real-Zig startup test into the full observable feature matrix, including saved on-disk contents, workspace edits and output/status behavior. Gate ordinary local runs on the reference assets, but require an actual passing real-extension run on the reference combination before claiming complete Zig/ZLS integration; record the versions and results. Keep this test separate from mock coverage.
- The shared native Linux/macOS/Windows CI matrix already builds the pinned host, JSON server and TypeScript SDK and runs `zig build test-e2e`. Add the mandatory mock LSP fixture to that same suite; preserve TypeScript coverage and only skip the real-Zig test when its explicitly optional reference assets are absent.
- Update `README.md` (remove the user-extension-activation exclusion; document host build, auto pickup, Zig/ZLS setup and keybindings), `docs/extensions.md` (§10/§16/§18 plus a new Zig/LSP section with the capability matrix and terminal adaptations), `docs/terminal-ui.md` (widgets, injected text, keys), `docs/css.md` (new ported sheets), and palette fixtures.

## Tests and acceptance

- Port the upstream tests named above, plus `extHostBulkEdits.test.ts`, `mainThreadBulkEdits.test.ts`, `extHostDocumentSaveParticipant.test.ts`, `extHostFileSystemEventService.test.ts`, `parameterHintsModel.test.ts`, the code-action tests, semantic-token tests, folding tests, smart-select and word-highlighter tests.
- Add TUI integration tests for every widget/controller and e2e tests via the mock languageclient; assert behavior, event order and disposal, not just registration counts.
- Acceptance: a standard `~/.vscode/extensions` install of `ziglang.vscode-zig` is listed automatically and passed to the host; opening a `.zig` file activates it and starts ZLS with the reference settings; every advertised ZLS capability works; will-save edits and rename/code-action workspace edits apply; no request blocks input or leaks caches; all build/test/check-workbench/format/diff checks pass; the required mock CI e2e passes and the reference real-extension run passes with no unsupported advertised capability. Verify the output command, language status, workspace synchronization and nested save ordering; a skipped real run is not proof of real integration.

## Verification

```sh
zig build
zig build test --summary all
zig build check-workbench
zig fmt --check <changed files>
git diff --check
cd host && npm ci --ignore-scripts && node build.js && cd ..
zig build test-e2e
```

Real ZLS run (early Stage 1 startup, repeated with full feature coverage at Stage 4): install/unzip Zig extension 0.7.0 under the effective VS Code extensions dir; provide Zig 0.17.0 and ZLS 0.17.0; set `zig.path`, `zig.zls.path` and `zig.zls.enabled: "on"`; launch the editor on a `.zig` file and in a Zig workspace. Capture the actual extension activation, ZLS process and negotiated initialize response, then verify the capability matrix and host/output logs. If a reference asset is unavailable, record which test was skipped and do not report real integration as verified.
