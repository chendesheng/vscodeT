# Faithful port of the Zig VS Code extension and ZLS LSP support

Status: proposed plan; not yet implemented.
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
- **No executable-only host inventory in the UI service.** Align the host extension set with upstream `ExtensionService`/`ExtensionHostManager`: all enabled, deduped installed extensions (system + user) are handed to the host; the host's activation events decide what runs. The port's split install layout (catalog manifests vs. runtime bundles) is handled at path resolution only and documented.
- **No ad hoc save hook, bulk-edit callback or host inventory in the TUI adapter.** Port the upstream `ITextFileService` working-copy/save-participant flow, `IBulkEditService` and `MainThreadBulkEdits`; the actor calls the portable service exactly as upstream.
- **No skipped portable behavior.** Rename preview, inlay-hint hover/click locations, code-action lightbulb/menu, workspace-symbol query/cancel/resolve, signature-help overloads, semantic token range requests and provider-change events are all in scope.
- **Do not build on the existing simplified layers where they deviate from upstream.** The touched `smartSelect.zig`, `wordHighlighter.zig`, `folding.zig`, `modelLineProjection.zig`, theme token-color path and provider-invocation bridge are corrected to the upstream structure as part of this work.
- **The sync provider adaptation is replaced.** The existing bounded synchronous `requestSync` provider calls are a documented terminal deviation that conflicts with literal LSP behavior; this work ports the upstream `ProviderResult`/cancellation flow once and migrates the language-feature registries and consumers onto it. ZLS requests must not block terminal input, and cancellation/order must match upstream.

## Scope

Target: `ziglang.vscode-zig` installed in the effective VS Code extensions directory, running in the real Node extension host, launching ZLS.

"All LSP features" means every client-side capability in ZLS's `initialize` result:

| ZLS capability | Registration/provider path | Upstream owner |
|---|---|---|
| publishDiagnostics | `languages.createDiagnosticCollection` / MainThreadDiagnostics | existing |
| completion | `$registerCompletionsProvider` / `$provideCompletionItems` | existing, verify snippets/label details |
| hover | `$registerHoverProvider` / `$provideHover` | existing |
| signatureHelp | `$registerSignatureHelpProvider` / `$provideSignatureHelp` | `contrib/parameterHints/**` |
| definition/declaration/typeDefinition | existing location registrations | existing |
| references | `$registerReferenceSupport` | existing |
| documentHighlight | `$registerDocumentHighlightProvider` / `$provideDocumentHighlights` | `contrib/wordHighlighter/**` + actor |
| documentSymbol | existing registration | existing |
| workspaceSymbol | `$registerNavigateTypeSupport` / `$provideWorkspaceSymbols` | `contrib/search/common/search.ts`, `symbolsQuickAccess.ts` |
| codeAction | `$registerCodeActionSupport` / `$provideCodeActions`, resolve | `contrib/codeAction/**` |
| formatting | existing document/range formatting | existing |
| rename/prepareRename | `$registerRenameSupport` / `$provideRenameEdits`, `$resolveRenameLocation` | `contrib/rename/**` |
| foldingRange | `$registerFoldingRangeProvider` / `$provideFoldingRanges` | `contrib/folding/**` |
| selectionRange | `$registerSelectionRangeProvider` / `$provideSelectionRanges` | `contrib/smartSelect/**` |
| semanticTokens | full/range registrations + encoded DTO | `contrib/semanticTokens/**`, `common/services/semanticTokens*` |
| inlayHint | `$registerInlayHintsProvider` / `$provideInlayHints` | `contrib/inlayHints/**` |
| willSaveWaitUntil | `workspace.onWillSaveTextDocument` → bulk edit | `mainThreadSaveParticipant.ts`, text-file save |
| workspace/applyEdit | `$tryApplyWorkspaceEdit` | `mainThreadBulkEdits.ts`, bulk-edit service |
| workspace/configuration | existing | existing |
| watched files | `$watch`/`$unwatch`/`$onFileEvent` | `mainThreadFileSystemEventService.ts` |
| progress | `$startProgress`/`$progressReport`/`$progressEnd` | `mainThreadProgress.ts` |

Not included: LSP capabilities ZLS does not advertise (code lens, document links/colors, call/type hierarchy, linked editing, inline values, notebooks), and the extension's non-LSP UI (its test runner, debug, tasks/build-on-save, terminal integration, code lens). No marketplace, remote extension host, workspace trust/sandbox, or Windows host transport.

## Assumptions

- The Node extension host remains optional (`zig build host`) and Linux/macOS-only. Missing host/Node is diagnosed and the editor continues with declarative extensions.
- ZLS is supplied by the extension (or `zig.zls.path`). The extension's `workspace.fs` installer is supported by the ported local `MainThreadFileSystem`; network access remains external.
- Configuration writes from extensions stay session-memory only (existing limitation); users persist `zig.zls.path`/`enabled` in settings if it must survive restart.
- User-installed extension JavaScript executes with user privileges when enabled; no sandbox is added.

## Stage 0 — Fidelity foundation

Port the upstream contracts the feature ports must use, rather than extending the current simplified ones:

- `src/vs/editor/common/languageFeatures*` / provider interfaces: port the upstream `ProviderResult`/thenable semantics using the existing `windowDispatch` callback/deadline mechanism (no polling). Migrate `LanguageFeatureRegistry` consumers and `MainThreadLanguageFeatures` from bounded `requestSync` to deferred provider results with cancellation and ordered completion. Add out-of-order/cancel/dispose tests.
- `src/vs/editor/browser/services/bulkEditService.zig` + `src/vs/workbench/contrib/bulkEdit/browser/{bulkEditService,bulkTextEdits,bulkFileEdits}.zig`: port the portable bulk-edit service and text/file edit operations used by workspace edits; preserve grouping, version checks, undo metadata and ordering.
- `src/vs/workbench/services/textfile/common/textFileService.zig` / `textFileEditorModel.zig`: port the working-copy save flow (async participants, will-save, dirty/version transitions) instead of `Editor.save` writing directly. The TUI save command completes through the window dispatcher; `FileEditorInput.save` delegates to this service contract.
- Theme/semantic-token color path: port the upstream `ColorThemeData` token-color index and `standaloneThemeService` token-theme relationship used by semantic tokens; the terminal renderer must resolve the same map that semantic styling encodes. No invented shared color map.
- Smart-select/word-highlighter/folding foundations: port `smartSelect.ts` (registry + async + selection/model event cache invalidation), `wordHighlighter.ts` (registry + async + multi-model behavior as far as the port supports), and `folding.ts`/`syntaxRangeProvider.ts` (controller + delayed syntax provider) rather than keeping the simplified terminal cores.
- `modelLineProjection.zig`: port the upstream injected-text projection (currently a no-injection stub), including `getViewLineContent`/`getViewLineData`, injected token fallback and cursor mapping, so inlay hints can be a literal port later.

## Stage 1 — Effective extension set and automatic pickup

- `src/vs/workbench/services/extensions/common/extensionService.zig` + `extensionHostManager.zig`: build the host extension set from the same effective installed/merged/deduped inventory and enablement state as the upstream extension service: all enabled system + user extensions, `isBuiltin`/`isUnderDevelopment` flags, no `main` filtering. For system extensions use the runtime bundle location when the executable install exists, otherwise the installed catalog location (terminal installation split; documented). User extensions use their scanned location. Pass all descriptions to the host; activation events govern execution.
- `src/tui/app.zig` / `vscodeProfile.zig`: keep upstream `extensionsPath` resolution, no alternate-root fallback; call the portable inventory builder. The default VS Code directory is already scanned and is the automatic source.
- `src/vs/workbench/api/browser/extensionHostAdapter.zig`: no new activation shortcut; keep/verify the implicit `onLanguage` events, document mirroring and `$acceptModelSaved`.
- Tests: temp system/user roots; user extension listing, enablement, override merge, declarative-only extension passed but not activated, executable user fixture activated; existing panel tests remain.

## Stage 2 — Host support required by the extension/LSP flow

Port these upstream owners literally, with terminal service implementations only at the adapter boundary:

- `mainThreadFileSystem.ts` → local `file:` subset over `ProviderFileService`/`DiskFileSystemProvider`; stat/readdir/readFile/writeFile/mkdir/delete/rename/copy/ensureActivation. Custom-scheme provider registration is a documented terminal gap.
- `mainThreadFileSystemEventService.ts` → `$watch`/`$unwatch`/`$onFileEvent` over the existing file-watcher service.
- `mainThreadBulkEdits.ts` + the Stage 0 bulk-edit service; `$tryApplyWorkspaceEdit` returns the upstream boolean result.
- `mainThreadSaveParticipant.ts` + `ExtHostDocumentSaveParticipant`; invoke on the TUI save path through the text-file service, preserve timeout/error handling and apply edits before the write.
- `mainThreadProgress.ts` + a terminal progress scheduler/status-bar adapter.
- `mainThreadOutputService.ts`/`mainThreadLogService.ts` + a terminal file-backed output/log service (no output-panel UI); keep channel lifecycle faithful so languageclient/Zig logging works.
- Register the actors in `extensionHostAdapter.zig`; add both upstream-shaped actor tests and RPC buffer-frame tests.

## Stage 3 — LSP bridge and feature ports

1. `mainThreadLanguageFeatures.ts` → `mainThreadLanguageFeatures.zig`: add every registration/provider call in the capability table, DTO conversion, selector matching, result-id/chained-cache release, code-action diagnostics context, rename rejection, semantic-token DTO decode/encode, and `$emit…` provider-change events. Port the relevant cases from `extHostLanguageFeatures.test.ts` and upstream actor tests.
2. Workspace symbols: port `contrib/search/common/search.ts` registry/`getWorkspaceSymbols` and `symbolsQuickAccess.ts`/`searchActionsSymbol.ts` with query, debounce/cancellation, resolve and open behavior; terminal quick-input adaptation only at the view boundary.
3. Signature help: port `contrib/parameterHints/browser/{provideSignatureHelp,parameterHintsModel,parameterHints,parameterHintsWidget}.zig` and `parameterHints.css`; keep the widget/controller structure, overload cycling, trigger/retrigger and focus/key handling; terminal content-widget paint only at the DOM boundary. Port `parameterHintsModel.test.ts`.
4. Rename: port `contrib/rename/browser/{rename,renameWidget}.zig` and `renameWidget.css`, including prepareRename, validation, preview mode, accept/reject, input state and cancellation; terminal overlay/input adaptation only. Add model/controller tests and e2e.
5. Code actions: port `contrib/codeAction/browser/{codeAction,codeActionModel,codeActionController,codeActionCommands,codeActionMenu,lightBulbWidget}.zig` and CSS; keep the model/controller, lightbulb states, menu ordering and command application; apply workspace edits through Stage 0. Port the three upstream code-action test files.
6. Semantic tokens: port `common/services/{semanticTokensProviderStyling,semanticTokensStyling,semanticTokensStylingService}.zig` and `contrib/semanticTokens/browser/{getSemanticTokens,documentSemanticTokens,viewportSemanticTokens}.zig`; full/range request flow, debounce, version/result ids and provider-change refresh; port the upstream styling/controller tests and add a terminal paint assertion.
7. Inlay hints: port `contrib/inlayHints/browser/{inlayHintsController,inlayHintsHover,inlayHintsLocations,inlayHintsContribution}.zig` over the Stage 0 injected-text projection; preserve hint parts, padding, resolve, hover and click navigation; no deferred view extras. Add injected-text and e2e tests.
8. Folding/selection/highlights: finish the Stage 0 literal ports and wire the LSP registries through the upstream providers; port `syntaxFold.test.ts`, `smartSelect.test.ts` and `wordHighlighter.test.ts` cases.

## Stage 4 — End-to-end, CI and docs

- Add `host/test-fixtures/lsp-language-features/`: a fixture extension using the host's real `vscode-languageclient` dependency and a mock LSP server advertising the full ZLS capability set. Add `Extensions:` e2e tests for every capability, including save/will-save, rename, code actions, semantic tokens and inlay hints.
- Add a gated real-Zig test (skipped unless a `ziglang.vscode-zig` install and ZLS are discoverable) that opens `.zig`, awaits activation/ZLS initialize and asserts the observable feature matrix.
- Add the Linux CI e2e step after the existing `npm ci`: build `host/dist/extensionHost.mjs` and run `zig build test-e2e`. TypeScript/real-Zig tests continue to skip when their optional assets are absent.
- Update `README.md` (remove the user-extension-activation exclusion; document host build, auto pickup, Zig/ZLS setup and keybindings), `docs/extensions.md` (§10/§16/§18 plus a new Zig/LSP section with the capability matrix and terminal adaptations), `docs/terminal-ui.md` (widgets, injected text, keys), `docs/css.md` (new ported sheets), and palette fixtures.

## Tests and acceptance

- Port the upstream tests named above, plus `extHostBulkEdits.test.ts`, `mainThreadBulkEdits.test.ts`, `extHostDocumentSaveParticipant.test.ts`, `extHostFileSystemEventService.test.ts`, `parameterHintsModel.test.ts`, the code-action tests, semantic-token tests, folding tests, smart-select and word-highlighter tests.
- Add TUI integration tests for every widget/controller and e2e tests via the mock languageclient; assert behavior, event order and disposal, not just registration counts.
- Acceptance: a standard `~/.vscode/extensions` install of `ziglang.vscode-zig` is listed automatically and passed to the host; opening a `.zig` file activates it and starts ZLS; every ZLS capability works; will-save edits and rename/code-action workspace edits apply; no request blocks input or leaks caches; all build/test/check-workbench/format/diff checks pass; CI e2e passes.

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

Gated real ZLS run: install/unzip the VSIX under the effective VS Code extensions dir, provide matching `zls`/`zig`, set `zig.zls.path`, launch the editor on a `.zig` file, and verify the capability matrix, extension activation and host logs.
