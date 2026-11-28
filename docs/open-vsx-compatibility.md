# Open VSX extension compatibility — 25 extensions

**Status:** planned; manifest and current implementation audit on 2026-11-28.
None of the 25 third-party packages has been qualified by this audit. A
manifest contribution or an implemented RPC actor is not proof of a working
extension workflow.

## Scope and selection

Qualify the selected 20 most downloaded in-scope Open VSX extensions, plus
five requested language extensions (C#, Haskell, Swift, Elm and Gleam), on
Linux, macOS and Windows. The selection is frozen from the
[2026-11-28 download ranking](https://open-vsx.org/api/-/search?size=40&offset=0&sortBy=downloadCount&sortOrder=desc)
reported during planning. Do not recompute the target IDs on every test run.

Interactive debugging, chat, notebooks, GitLens, containers, PHP Profiler and
IntelliPHP are not qualification targets. Browser-dependent interfaces are
deferred; ordinary tree views, menus, dialogs, test explorers, editor widgets,
virtual documents and other portable UI remain in scope. Do not add a browser
engine. Run-without-debugging infrastructure is in scope where necessary for
normal execution or tests. Excluded packages may still be installed by normal
dependency/pack resolution; exclusion is not a change to their manifests or
the extension manager's semantics.

Use the genuine, unmodified user VSIXs from Open VSX and the pinned VS Code
1.147.0 Node extension host (`e31c2e52f563620846caab877103f630ea361b9c`).
Apply fixes to the corresponding upstream-shaped workbench services, actors,
registries, contributions and view parts. Do not hard-code extension IDs into
the application's feature logic, change upstream files, bypass API proposal
authorization, weaken engine or signature validation, or substitute mock
language servers for final qualification. Native terminal adaptations belong
at the host/UI boundary.

## Current implementation and shared work items

The following work items refer to concrete port boundaries. **Gap** means the
required implementation is absent or partial in the current tree; **Verify**
means a substantial implementation exists and the actual package must first
demonstrate a failure before expanding it. The per-extension rows below refer
to these items to avoid implementing the same service repeatedly.

| ID | Status | Required feature and upstream owner |
| --- | --- | --- |
| `GALLERY` | Verify | Search, compatible-version/platform selection, signatures, dependencies/packs, install/restart/uninstall through `platform/extensionManagement`. Test platform-specific native VSIXs, optional pack members, engine ranges and restart-required contribution changes. Retain normal registry behavior; do not rewrite manifests. |
| `DECL` | Verify / gap | `services/extensions/common/extensionsRegistry`, `services/actions/common/menusExtensionPoint` and the upstream contribution registries: actual language associations, TextMate grammars/injections, snippets, theme and semantic-token metadata, configuration, commands, keybindings, menu placement/`when` expressions and activation. Existing scanner handles languages, grammars, themes, icon themes, snippets and defaults; verify precedence/override and missing runtime registries rather than confusing the Features-tab tables with registrations. |
| `ACT` | Verify / gap | `services/extensions/common/abstractExtensionService`, `extensionHostManager` and the window host: explicit and implicit language/command/view activation, startup, recursive `workspaceContains` patterns, enabled extension dependency ordering, host restart and disposal. Verify broad `onLanguage` and wildcard/glob patterns used by the real packages. |
| `RPC` | Gap | `api/browser/extensionHostAdapter` registers real handlers for only a subset of the generated `extHost.protocol` actors; absent actors use a generic fallback that often returns an empty reply. Add diagnostics identifying actor, method and extension/workflow where known; port invoked portable contracts and return honest unsupported errors for missing requests according to the protocol. No success-shaped no-ops in qualified workflows. |
| `LANG` | Verify / gap | `api/browser/mainThreadLanguageFeatures`, editor language registries and the owning editor contributions. Already implemented: completion, hover, diagnostics, signature help, definitions/declarations/implementations/type definitions, references, symbols, folding, selection ranges, highlights, rename, code actions, CodeLens, semantic tokens, inlay hints, inline suggestions and document/range/on-type formatting. Prove provider selection, UI rendering, resolve/change events, cancellation, edits, UTF-16 conversion and format-on-save; port missing call/type hierarchy, document links, document colors and linked-editing providers/views when exercised. Verify semantic token scope/theme mapping and embedded-language selectors. |
| `WORKSPACE` | Verify / gap | `api/browser/mainThreadWorkspace`, `mainThreadFileSystem`, `mainThreadFileSystemEventService`, documents, bulk edits and the workspace/file services: real glob/ignore semantics, relative patterns, workspace folders, file create/rename/delete and will/did events, virtual files, resource URIs, workspace edits and configuration change events. Local file queries and persistent settings are already present; complete missing portable paths that the runners use. |
| `INPUT` | Gap | `api/browser/mainThreadQuickOpen`, upstream quick-input and dialog services. The native palette/picker exists, but the extension RPC actor is not registered. Port `showQuickPick`, `showInputBox`, stateful `createQuickPick`/`createInputBox`, item buttons, validation, selection, accept/hide/cancel, and terminal file/folder selection where upstream requests it. Preserve one pending owner per input and dispose listeners. |
| `TREE` | Gap | `api/browser/viewsExtensionPoint`, `mainThreadTreeViews`, view descriptor/container services and `browser/parts/views`: real contributed views/containers, `TreeDataProvider`/`TreeView`, lazy children, refresh/reveal/selection/visibility, expansion, badges, item commands, inline actions and menus. Current manifest feature tables are descriptive, not active extension tree views. Use the existing terminal view/list/focus architecture. |
| `TERM` | Gap | `api/browser/mainThreadTerminalService`, `mainThreadTerminalShellIntegration`, terminal contribution and platform PTY boundary: extension-owned terminals, env/cwd/shell, lifecycle/data events, show/hide/sendText, shell execution and environment collections, profiles and pseudoterminals as required. Native POSIX terminal exists; Windows ConPTY is missing. Port Windows support and shared event semantics, not per-extension process-launch branches. |
| `TASK` | Gap | `api/browser/mainThreadTask` and `contrib/tasks`: the current actor registers providers and calls `$provideTasks`, but remaining execution requests return `Unsupported`. Port task resolution, fetch/execute/terminate, shell/process/custom execution as exercised, problem matchers, task/terminal lifecycle, output and cancellation. |
| `TEST` | Gap | `api/browser/mainThreadTesting`, `contrib/testing/common` and `contrib/testing/browser`: test controllers/items, discovery and refresh, test profiles, run requests, results/output/messages, source locations, coverage when provided, cancellation and a terminal Testing view with editor decorations. No registered MainThreadTesting handler today. |
| `RUN` | Gap | `api/browser/mainThreadDebugService` and upstream debug/launch services, only for non-debug execution and the minimum real adapter/session lifecycle required for `noDebug` launches; retain dependency activation/registration without claiming interactive breakpoint/step/variable support. Ordinary task/terminal execution is covered by `TASK`/`TERM`. |
| `GIT` | Gap | `vscode/extensions/git/src/api/{extension,api1}.ts` and `api/browser/mainThreadSCM`: expose the upstream `vscode.git` API and repository/event semantics to dependent Node extensions using the actual Git service. The native Git CLI/SCM UI exists; the upstream Node Git exports are not yet integrated. Keep one coherent repository/model lifecycle. |
| `PROPOSAL` | Gap | `services/extensions/common/extensionsProposedApi.ts`: validate known proposals and resolve explicit product/environment authorization before descriptions reach the pinned host. Current Zig file renders proposal metadata; host description builder clones the original manifest. Use the upstream policy and real proposal implementations, not an unrestricted allowlist or fake return values. Excluded-feature proposals need not gain their runtime functionality. |
| `EDITOR` | Gap | `api/browser/mainThreadCustomEditors`, editor resolver/input and document services: terminal-compatible custom editor/document lifecycle, registration, read-only derived content, save/revert/dispose and virtual text documents where used. Do not implement arbitrary HTML/JS webview execution. If a specific custom editor requires browser content, record the exact limitation and retain the portable document/navigation capability. |

Implementation evidence: [actor registration and fallback](../src/vs/workbench/api/browser/extensionHostAdapter.zig),
[language provider bridge](../src/vs/workbench/api/browser/mainThreadLanguageFeatures.zig),
[task bridge](../src/vs/workbench/api/browser/mainThreadTask.zig),
[workspace bridge](../src/vs/workbench/api/browser/mainThreadWorkspace.zig),
[configuration bridge](../src/vs/workbench/api/browser/mainThreadConfiguration.zig),
[declarative scanner](../src/vs/workbench/services/extensions/common/extensionsRegistry.zig),
[extension host descriptions](../src/vs/workbench/services/extensions/common/extensionHostManager.zig),
[current extension-system status](extensions.md), and
[terminal, Git and language-provider limitations](design.md).

## Per-extension qualification and feature backlog

The versions below are **observed registry metadata**, not qualified or locked
versions. `preview` means the queried latest entry is a pre-release; platform
selection and compatible stable release selection must use Minecode's normal
gallery resolver. The exact extension manifest, including dependencies,
activation events and contribution points, was queried from the linked
Open VSX entry on 2026-11-28. Where a workflow implies an API but the manifest
cannot prove its use, it is listed as a verification/port candidate rather than
a confirmed extension runtime failure.

### Python

#### 1. [meta.pyrefly](https://open-vsx.org/extension/meta/pyrefly) — rank 1, 1.5.9001 (preview)

- Runtime: Python and the native Pyrefly language-server binary matching the target OS/architecture. Activation: `onLanguage:python`; notebook activation excluded.
- **New/remaining:** `PROPOSAL` for `editorHoverVerbosityLevel` (including genuine verbose hover behavior); `DECL` semantic scope/configuration registration; `TERM`/`TASK` for the extension's run-main/run-test commands; `LANG`/`WORKSPACE` for file-usage navigation, docstring folding and inference edits. Most ordinary language providers already have a bridge.
- **Prove:** open a typed Python project, observe a type mismatch and completion, navigate to definitions/usages, request hover verbosity, apply an inference edit, fold/unfold docstrings, run main and tests, restart the server. Check conflicting Python language-provider configuration with the Python extension installed.

#### 2. [ms-python.python](https://open-vsx.org/extension/ms-python/python) — rank 3, 2026.10.0

- Runtime: Python with venv, unittest and pytest; works with Python Environments and Pyrefly. Pack declares Pylance, debugpy and Python Environments. Pylance returned 404 from Open VSX; existing installer treats unavailable pack members as optional. Do not emulate Pylance or change the pack.
- **New/remaining:** `INPUT` interpreter selection, test configuration and environment setup; `TERM` execution of file, selection and terminal REPL; `TEST` discovery/result UI and rerun failures; `PROPOSAL` for applicable `testObserver`, `quickPickSortByLabel`, `quickPickItemTooltip`, `terminalDataWriteEvent`, `terminalExecuteCommandEvent` and editor-content menu behavior. Verify `ACT` project glob activation, `WORKSPACE` settings and `DECL` problem matchers/menus. AI/debug/notebook REPL and notebook-variable proposals are outside scope.
- **Prove:** create/select a venv, persist interpreter, run file/selection in the correct terminal environment, run passing/failing unittest and pytest tests, inspect results and rerun/cancel; verify Python and Pyrefly coexist without duplicate enabled providers.

#### 3. [ms-python.vscode-python-envs](https://open-vsx.org/extension/ms-python/vscode-python-envs) — rank 6, 1.44.0

- Runtime: Python, venv and supported environment/package managers. Manifest contributes `python-projects` and `env-managers` in the Python activity container and task definitions.
- **New/remaining:** `TREE` for both environment views and item actions; `INPUT` manager/interpreter selection; `TERM` environment discovery, activation and `terminalShellEnv`/`terminalDataWriteEvent`; `TASK` execution and `taskExecutionTerminal`; `PROPOSAL` authorization for those APIs; `WORKSPACE` per-project environment settings and change events.
- **Prove:** discover two environments, create/select one, install/list a test package, display and refresh both trees, run a script/task with the chosen interpreter, switch environments and verify the terminal and Python extension receive the change; remove a disposable environment.

#### 4. [magicstack.MagicPython](https://open-vsx.org/extension/magicstack/MagicPython) — rank 22, 1.1.1

- Declarative-only: languages and TextMate grammars; no entry point and no new RPC actors expected.
- **New/remaining:** `DECL` verify grammar precedence against bundled Python syntax, scope/injection behavior, language configuration and restart on install/uninstall. Port any missing registry precedence behavior if observed.
- **Prove:** install, restart, open Python with decorators, annotations, f-strings and embedded regex; assert actual token scopes/colors from MagicPython, then disable/uninstall and verify built-in fallback.

#### 5. [EricSia.pythonsnippets3](https://open-vsx.org/extension/EricSia/pythonsnippets3) — rank 23, 3.3.18

- Declarative-only: snippets; no entry point and no new RPC actors expected.
- **New/remaining:** `DECL` verify contributed snippet loading, Python language scope, completion ranking, placeholders/mirrors and disable/restart behavior using the existing snippet controller.
- **Prove:** expand a real contributed Python snippet, navigate tab stops, edit a mirrored placeholder, cancel/undo, and confirm disabled snippets disappear.

### Java

#### 6. [redhat.java](https://open-vsx.org/extension/redhat/java) — rank 5, 1.59.2026112708 (preview)

- Runtime: JDK appropriate for the selected Eclipse JDT Language Server package, plus project JDKs and Maven/Gradle fixtures. Manifest contributes Java-specific build integration, semantic token types/modifiers/scopes and the `decompiled.javaClass` custom editor.
- **New/remaining:** `ACT` workspace project discovery and companion activation; `DECL` portable Java extension-point/command metadata and semantic tokens; `LANG` call/type hierarchy, links, refactors, source attachments, CodeLens/inlay/semantic updates; `WORKSPACE` project file changes, resource edit and virtual source documents; `EDITOR` read-only class/decompiled source navigation; `INPUT`, `TASK`, `TERM` for project import, source-path actions, compilation and build output. Determine which custom-editor/dashboard rendering is genuinely browser-only; core Java language tooling must not depend on it.
- **Prove:** import a multi-module project, complete and navigate across modules/dependencies, rename/refactor with file edits, format, show diagnostics and CodeLens, compile, inspect dependency source/decompiled content, restart/clean the server, change a build file and observe project updates.

#### 7. [vscjava.vscode-java-dependency](https://open-vsx.org/extension/vscjava/vscode-java-dependency) — rank 12, 0.27.7

- Runtime: Red Hat Java project service and a sample Maven/Gradle project. Manifest contributes `javaProjectExplorer`, task definitions and shared Java extension metadata.
- **New/remaining:** `TREE` Java Projects view with hierarchy, selection/reveal, refresh, commands and contextual actions; `ACT` companion extension coordination; `INPUT` create project/add library dialogs; `TASK` build/rebuild/clean; `WORKSPACE` create files and refresh project/classpath changes.
- **Prove:** browse source/packages/libraries, switch flat/hierarchical view, reveal a source file, add/remove a local library, refresh/reload and build the project; close/reopen the view without losing legitimate state.

#### 8. [vscjava.vscode-maven](https://open-vsx.org/extension/vscjava/vscode-maven) — rank 15, 0.45.3

- Runtime: JDK, Maven or project wrapper, reproducible POM/project and cached dependencies. Manifest contributes `mavenProjects`, commands and submenus; activation `workspaceContains:**/pom.xml`.
- **New/remaining:** `TREE` Maven projects/goals/dependencies, contextual actions and refresh; `INPUT` archetype/goal/argument choice; `TERM`/`TASK` shell execution with working directory/environment and result output; `WORKSPACE` POM edits and discovery; `ACT` multi-project workspace activation.
- **Prove:** discover root/child POMs, run clean/compile/test/package and a custom goal, inspect effective POM/history, generate a disposable project from an archetype, observe tree refresh after POM edits and cancel a running goal.

#### 9. [vscjava.vscode-java-test](https://open-vsx.org/extension/vscjava/vscode-java-test) — rank 16, 0.47.0

- Runtime: Java/JUnit/TestNG, Red Hat Java and **required** `vscjava.vscode-java-debug`. Keep the dependency installed even though interactive debugging is excluded.
- **New/remaining:** `TEST` controller/profile/result lifecycle, discover test classes/methods, inline run actions and Testing view; `RUN` actual run-without-debugging adapter lifecycle if the extension uses the Java debug server to launch tests; `ACT` companion exports; `LANG`/`WORKSPACE` source/test navigation and results. Do not replace the Java Test runner with an unrelated shell command.
- **Prove:** discover JUnit and TestNG methods, run individual/class/all tests, show pass/fail/output/source location, rerun a failure, cancel an active run, and navigate to test/subject. No breakpoint/step/debug test qualification.

#### 10. [vscjava.vscode-gradle](https://open-vsx.org/extension/vscjava/vscode-gradle) — rank 17, 3.18.0

- Runtime: JDK, Gradle wrapper, project build files and cached dependencies. Views: `gradleTasksView`, `gradleDefaultProjectsView`, `recentTasksView`, `gradleDaemonsView` in the Gradle container.
- **New/remaining:** `TREE` all four views, task pinning/history, daemon actions and expansion; `TASK`/`TERM` resolve/run/cancel Gradle tasks with arguments, output/reveal/close terminals, problem matchers; `ACT` recursive wrapper/build-file activation and Java importer coordination; `INPUT` task arguments; `WORKSPACE` build-file watching and refresh.
- **Prove:** import a wrapper-based project, list tasks/daemons, run build/test, run with arguments, pin/re-run recent task, inspect terminal output and cancel a long task; edit Gradle files and refresh the model, stop only the fixture daemon.

#### 11. [vscjava.vscode-java-pack](https://open-vsx.org/extension/vscjava/vscode-java-pack) — rank 18, 0.31.2

- Runtime: the six declared pack members, including Java Debugger (dependency only). Manifest contributes Java shortcuts, walkthroughs and `java.formatterSettingsEditor` for XML.
- **New/remaining:** `GALLERY` install/enable compatible members in normal pack order and `ACT` coordinate commands/providers; `DECL` Java shortcut/menu registration; `INPUT` and `WORKSPACE` for portable settings/classpath/runtime operations exposed through ordinary commands. Browser-rendered help/overview, project settings and formatter-preview webviews are explicitly deferred; the ordinary text/XML settings and independent Maven/Gradle/project workflows must remain usable.
- **Prove:** install the pack in a new profile, verify members and Java companion workflows, restart, select a configured project runtime and edit settings through available portable paths. Record each deferred browser-only interface separately.

### PHP, Ruby, Go and C/C++

#### 12. [devsense.composer-php-vscode](https://open-vsx.org/extension/devsense/composer-php-vscode) — rank 8, 1.76.19579

- Runtime: PHP and Composer, local fixture package/repository and `composer.json`. Manifest contributes JSON validation, tasks, commands and keybindings.
- **New/remaining:** `TASK`/`TERM` Composer discovery, install/update/require/remove/run-script with cwd, output and cancellation; `INPUT` arguments/package choices; `WORKSPACE` file updates/watchers; `LANG`/`DECL` composer schema diagnostics, completion, CodeLens and precise menu/configuration handling. Verify integration with the existing JSON language service instead of adding a Composer-specific schema path.
- **Prove:** validate/complete `composer.json`, run install and a script, add/remove a local test dependency, inspect output and file/lock changes, handle missing Composer and cancel a task. Use local fixtures, not an external publication workflow.

#### 13. [devsense.phptools-vscode](https://open-vsx.org/extension/devsense/phptools-vscode) — rank 10, 1.76.19579

- Runtime: PHP, PHPUnit and the package's native language server for the OS/architecture. Pack includes Composer, IntelliPHP and PHP Profiler; the last two are excluded qualification targets, not modified dependencies.
- **New/remaining:** `LANG`/`DECL` PHP and Blade completion, diagnostics, semantic tokens, formatting, CodeLens and refactoring; verify provider arbitration with bundled PHP support; `TEST` PHPUnit discovery/run/results and `TERM`/`TASK` normal scripts/builds/server workflows; `INPUT` PHP version/tool selection; `WORKSPACE` file-wide edits, project indexing and config changes; `RUN` if normal run-script requires a `noDebug` launch. Chat/MCP, profiling UI and interactive debug are out of scope. Confirm licensed feature availability without bypassing vendor restrictions; report unavailable licensed workflows as blocked.
- **Prove:** open a Composer project with an error and completion, format and apply a class-import/refactor action, navigate project symbols, run script and PHPUnit tests, switch PHP version, cancel a run and check diagnostics update. Test free/authorized features and record any license-dependent gaps.

#### 14. [Shopify.ruby-lsp](https://open-vsx.org/extension/Shopify/ruby-lsp) — rank 7, 0.10.8

- Runtime: Ruby, Bundler, Ruby LSP and a Gemfile.lock project. Required dependency: `vscode.git`. Manifest contributes the `dependencies` view.
- **New/remaining:** `GIT` actual Git extension exports and repository-change events; `TREE` gem/dependency view; `INPUT` version-manager selection; `TERM` environment resolution and run-in-terminal; `LANG` Ruby providers and virtual/syntax-tree content; `WORKSPACE` addon/project/Gemfile changes; `TEST`/`TASK` as used by run-test and project workflows. No chat/debug qualification.
- **Prove:** activate in a Git-backed Bundler project, select Ruby, start/restart LSP, navigate/format/rename, inspect dependencies/addons, run a fixture test, change a gem dependency and observe refresh, verify Git API access and disposal.

#### 15. [golang.Go](https://open-vsx.org/extension/golang/Go) — rank 11, 0.58.0

- Runtime: Go and `gopls`; required Node version is at least 22.22.0, compatible with CI's Node 24. Views: `go.explorer`, `go.package.outline`, `go.test.profile`.
- **New/remaining:** `TREE` Go explorer/package outline and non-web test-profile view; `TEST` Go test discovery/results/coverage, `TERM`/`TASK` builds, tests, benchmarks and tool installs; `INPUT` environment/tool selection; `LANG` call/type hierarchy, inlay hints, CodeLens, formatting and refactors; `WORKSPACE` Go module changes. Browser welcome panel and browser-only profile visualization deferred; interactive debugging excluded.
- **Prove:** open a module, complete and navigate, organize imports/format, apply a refactor, inspect outlined packages, run build/tests/benchmarks and coverage, cancel a test, restart `gopls` and observe module changes.

#### 16. [llvm-vs-code-extensions.vscode-clangd](https://open-vsx.org/extension/llvm-vs-code-extensions/vscode-clangd) — rank 13, 0.6.0

- Runtime: clangd and a C/C++ project with compilation database. Three actual views: `clangd.typeHierarchyView`, `clangd.memoryUsage`, `clangd.ast`.
- **New/remaining:** `TREE` for type hierarchy, AST and memory-use views; `LANG` type hierarchy, call hierarchy, links, semantic highlighting/inlay hints and header/source navigation; `INPUT`/`TERM` install/update/restart server prompts and tool resolution; `WORKSPACE` compile database and config changes.
- **Prove:** use `compile_commands.json`, get a diagnostic and completion, navigate/rename, switch between declaration/source, inspect hierarchy, AST and memory views, format, restart and check behavior on updated compile flags.

### Vue, formatting, YAML and Rust

#### 17. [Vue.volar](https://open-vsx.org/extension/Vue/volar) — rank 25, 3.3.14

- Runtime: Node, Vue/TypeScript project and the Vue extension's language server/TypeScript plugin integration. Manifest contributes `.vue` language/grammars, semantic scopes and broad `onLanguage` activation.
- **New/remaining:** `ACT` broad language activation and companion TS extension coordination; `LANG` embedded Vue template/script/style language selectors, navigation, completion, diagnostics, formatting, semantic highlighting, and plugin-provided multi-language features; `DECL` grammar injection and settings; `WORKSPACE` cross-file edits and project updates. No welcome webview requirement for normal editing.
- **Prove:** open an SFC containing template, TS and CSS; complete props/components, diagnose a TS error, navigate a component across files, rename, format and restart the server. Test actual pinned or compatible gallery TypeScript provider alongside Vue.

#### 18. [esbenp.prettier-vscode](https://open-vsx.org/extension/esbenp/prettier-vscode) — rank 28, 12.4.0

- Runtime: Node, bundled Prettier plus a workspace-local pinned Prettier fixture. Manifest activation `onStartupFinished`.
- **New/remaining:** verification-first `LANG` document/range formatting, default formatter selection, format-on-save, provider registration/resolve and cancellation; `DECL` configuration, settings precedence, supported language associations/commands; `WORKSPACE` workspace trust/local module selection and config discovery/events. Port missing trust/configuration or formatter UI behavior only where the actual package requires it.
- **Prove:** format JS/TS/JSON/CSS/Vue documents and selection, honor `.prettierrc`, `.prettierignore`, local Prettier version and default formatter selection, create a config file, verify ignore/force format/save behavior and undo. No browser UI expected.

#### 19. [redhat.vscode-yaml](https://open-vsx.org/extension/redhat/vscode-yaml) — rank 30, 2.1.2026112008 (preview)

- Runtime: bundled Node YAML language server, local JSON schemas and YAML documents. Manifest contributes YAML language variants, grammars and defaults.
- **New/remaining:** `DECL` language associations/defaults and grammar precedence, `LANG` schema-aware diagnostics/completion/hover/format/symbols/links and actions, `WORKSPACE` schema resolution and dynamic per-workspace configuration, file watcher and multi-document YAML semantics. Verify standard language bridge first; no new tree or webview requirement evident.
- **Prove:** associate a local schema with a YAML file, show missing/invalid property diagnostics and schema completion/hover, format and navigate symbols, change schema/settings and verify updated results including a multi-document YAML fixture.

#### 20. [rust-lang.rust-analyzer](https://open-vsx.org/extension/rust-lang/rust-analyzer) — rank 33, 0.4.3135 (preview)

- Runtime: rustup/Cargo/rustc and matching rust-analyzer server; manifest minimum VS Code `^1.144.0`; use compatible stable release by default. Views: `rustDependencies` and `rustSyntaxTree` under its container.
- **New/remaining:** `TREE` dependencies/syntax tree and context actions; `LANG` inlay hints, call hierarchy, semantic tokens, macros, CodeLens, code actions/refactor and virtual generated text; `EDITOR`/`WORKSPACE` macro expansion/HIR/MIR and file notifications; `TASK`/`TERM` Cargo runnable/test/check tasks and problems; `INPUT` runnable selection and server initialization prompts; `ACT` Cargo project activation. Interactive debug and browser-only crate-graph visuals deferred.
- **Prove:** open a Cargo workspace with a library dependency, diagnose and fix, complete, navigate and rename, show inlay hints/semantic tokens, expand a macro, inspect syntax tree/dependencies, run Cargo check/test and cancel, reload workspace and restart the server.

### Five additional requested languages

#### 21. [muhammad-sammy.csharp](https://open-vsx.org/extension/muhammad-sammy/csharp) — C#, 2.160.9-g01198ecc1f

- Runtime: .NET SDK and Roslyn/OmniSharp for the target OS/architecture, plus required `ms-dotnettools.vscode-dotnet-runtime`. Use this libre C# package rather than Microsoft-only licensed debugger functionality; [publisher README](https://open-vsx.org/extension/muhammad-sammy/csharp) documents its compatible-editor purpose.
- **New/remaining:** `GALLERY` native platform VSIX and runtime-acquisition dependency; `ACT` solution/workspace discovery and runtime extension exports; `INPUT` project/solution and context selection; `LANG` completion, CodeLens, semantic tokens, navigation, refactoring/rename, format and source-generator data; `EDITOR`/`WORKSPACE` metadata-as-source, generated documents, project and file changes; `TASK`/`TERM` restore/build/run and normal tests; `TEST` if the real extension registers test providers. Non-debug execution only; verify runtime acquisition without assuming debugger registration is needed.
- **Prove:** load an SDK-style multi-project solution, acquire/select runtime, restore, navigate across projects and into metadata source, complete, diagnose, apply a refactor and format, build/run/test the fixture with `dotnet`, change project context and restart the server.

#### 22. [haskell.haskell](https://open-vsx.org/extension/haskell/haskell) — Haskell, 2.8.3

- Runtime: GHC, Cabal/Stack and a matching Haskell Language Server; pack includes `haskell.language-haskell`. Activation languages: Haskell, literate Haskell and Cabal.
- **New/remaining:** `GALLERY` install and load the syntax pack; `INPUT` toolchain/server installation/version prompts, `TERM`/`TASK` toolchain/build commands where exposed; `LANG` hover/type information, completion, signature help, actions, CodeLens, formatting, symbols and links; `WORKSPACE` Cabal/Stack project resolution, file edits and server restarts; `DECL` `.hs`, `.lhs` and `.cabal` modes. Do not assume manual binaries constitute extension compatibility: verify its configured toolchain path and normal restart commands.
- **Prove:** open a Cabal project using a compatible GHC/HLS pair, diagnose a type error, complete and navigate a symbol, show inferred types, apply a suggested edit, format and restart HLS, open literate/Cabal files and build the sample project.

#### 23. [swiftlang.swift-vscode](https://open-vsx.org/extension/swiftlang/swift-vscode) — Swift, 2.19.20261118 (preview)

- Runtime: Swift toolchain, SourceKit-LSP and SwiftPM. Required dependency: `llvm-vs-code-extensions.lldb-dap`; install dependency normally, but do not qualify interactive debug. Manifest contributes `projectPanel`, terminal and task definitions, problem matchers and Swift language contributions.
- **New/remaining:** `TREE` Swift project/dependency view, item actions and refresh; `TASK`/`TERM` SwiftPM build/run/test, task terminals, toolchain env and terminal profile contribution; `TEST` discovery/results of Swift package tests; `INPUT` project creation/toolchain selection; `LANG` completion, diagnostics, symbols, source navigation/action/semantic/inlay providers; `WORKSPACE` package resolution, generated/virtual files and package manifest events; `RUN` if ordinary Swift run goes through a non-debug adapter launch. Documentation preview/browser-only walkthroughs deferred.
- **Prove:** create/import a SwiftPM library/executable with tests, resolve dependencies, browse project view, complete/navigate/diagnose/format, build/run/test and inspect output/results, cancel a task, edit `Package.swift` and verify change handling. Use portable SwiftPM fixtures on all three OSes, not Xcode/iOS simulator projects.

#### 24. [Elmtooling.elm-ls-vscode](https://open-vsx.org/extension/Elmtooling/elm-ls-vscode) — Elm, 2.10.0

- Runtime: Elm compiler, Elm Language Server, Elm formatter and reproducible packages. Manifest contributes language grammars, schema, tasks and commands; activation `workspaceContains:**/elm.json`.
- **New/remaining:** `ACT` workspace discovery, `INPUT`/`TERM` tool installation prompts and executable selection; `LANG` linked editing (type annotation/function rename), document links, CodeLens, completion, type-aware hover, diagnostics, refactoring and formatting; `WORKSPACE` file create/rename events and multi-file edits for module names and imports; `TASK` for Elm make/test tasks; `DECL` grammar and `elm.json` schema/configuration. Browse-package command may open the user's external browser through the existing window URI service, not an embedded webview.
- **Prove:** open a multi-module Elm project, report a type mismatch and completion, show inferred types, rename a file/module and update imports, apply a refactor, format, run build/test tasks and restart on `elm.json` changes.

#### 25. [gleam.gleam](https://open-vsx.org/extension/gleam/gleam) — Gleam, 2.13.1

- Runtime: Gleam compiler (built-in language server) and Erlang or JavaScript runtime as appropriate for the fixture. Manifest contributes languages, grammars, snippets and configuration; activation is implicit from the language contribution.
- **New/remaining:** verification-first `ACT` implicit language activation, `DECL` language configuration/grammar/snippets/defaults, `LANG` completion, diagnostics, hover, navigation, refactors/actions and formatting, `WORKSPACE` changes and package resolution. `INPUT`/`TERM` only if needed for actual tool-path selection/error recovery. No new tree/testing actors or webview requirements evident from the manifest.
- **Prove:** open a small `gleam.toml` project, recognize `.gleam` files and expand a snippet, complete/navigate and format, show compiler/type diagnostics, apply an action, build/test with the toolchain, restart language server and verify cleanup.

## Execution order

1. **Baseline and reproducible harness:** capture all 25 selected packages'
   exact stable-compatible versions/platform assets, checksums, dependency
   closure, toolchain versions and licenses. Use a fresh user-data directory,
   extensions directory and fixture workspace per test; keep real profiles
   untouched. Install via the same gallery transaction as the workbench.
   Install dependencies normally; do not silently exclude a failed target.
   Start with a read-only account/license status where applicable. Check
   filesystem capacity before large builds/downloads and clean only verified
   disposable build caches if necessary.
2. **Verification-first integrations:** MagicPython, Python Snippets,
   Prettier, YAML, Pyrefly, Gleam and Elm; exercise the actual package and
   stabilize `GALLERY`/`RPC`/`DECL`/`ACT`/`LANG`/`WORKSPACE`. Test known
   language-provider behavior before expanding the bridge.
3. **Shared user interaction:** port `INPUT`, `TREE`, `TERM`, `TASK`,
   `PROPOSAL` and `GIT` against the pinned implementation; integrate Python
   Environments, Ruby, Go, Clangd, Composer, Rust, Vue, Haskell and C#.
4. **Test and project integrations:** port `TEST`, `RUN` and portable
   `EDITOR` contracts; qualify PHP Tools, Python, Java and all Java companions,
   and Swift. Repeat earlier qualification with representative companion sets
   installed, not just isolated packages.
5. **Cross-platform closure:** run identical qualification on Linux, macOS and
   Windows, including Windows PTY/process and native VSIX platform selection.
   Fix shared services in their upstream owners; preserve existing unit and
   extension-host tests. Document unavoidable browser-only differences in the
   relevant file headers, `design.md` and `terminal-ui.md` as applicable.

## Test architecture and acceptance

Add a `zig build test-gallery-extensions` target for the new qualification.
Use real packages and toolchains; reuse the Node host's integration harness in
`src/vs/workbench/api/browser/extensionHostAdapter.zig` and add tests at their
upstream-shaped owners. Test manifest registration/installation, actual host
activation, provider/service results **and** the terminal view/interaction.
Mock/focused upstream tests are necessary for lifecycle edge cases but are not
substitutes for downloaded-package qualification.

- Keep ordinary `zig build test` and `zig build test-e2e` deterministic and
  complete. Add the gallery qualification to the existing shared three-OS CI
  matrix with the same assertions and toolchains on every OS; provision only
  platform-specific installation paths/binaries differently. Pin reproducible
  versions and verify downloads, without baking locks into normal user gallery
  selection or letting a moving ranking change CI.
- Exercise separate fresh installs and companion sets (Python, Java, PHP,
  Vue + TS); verify enable/disable/restart and provider precedence. Cover
  paths with spaces and non-ASCII text, cancellation, host shutdown, owner
  cleanup, file changes and settings persistence. Use event-driven assertions
  rather than polling editor/workbench model state or waiting for a render to
  trigger feature updates.
- Record exact failing RPC actor/method and observed user-facing behavior;
  distinguish missing portable port, external toolchain/license failure,
  unavailable package/version and genuinely browser-only feature. Fix the
  owner and add upstream-path regression tests before marking a gap resolved.
- Every row above must have tests using the actual package on each OS. Record
  tested version, platform, feature results, logs/artifact references and
  explicitly deferred features in the qualification matrix below. Installation,
  registration or activation alone is not a pass. Do not treat a skipped
  dependency, missing license, unprovided binary or unsupported portable API
  as success. Licensed workflows must have legitimate access to be verified.
- Final validation: `zig build`, `zig build test --summary all`,
  `zig build test-e2e`, `zig build test-gallery-extensions`,
  `zig build check-workbench`, `zig fmt --check <changed Zig files>`,
  `git diff --check` and passing native CI runs for the qualification commit.

Initial matrix (no downloaded-package runtime tests performed in this audit):

| Extension | Linux | macOS | Windows |
| --- | --- | --- | --- |
| `meta.pyrefly` | Pending | Pending | Pending |
| `ms-python.python` | Pending | Pending | Pending |
| `ms-python.vscode-python-envs` | Pending | Pending | Pending |
| `magicstack.MagicPython` | Pending | Pending | Pending |
| `EricSia.pythonsnippets3` | Pending | Pending | Pending |
| `redhat.java` | Pending | Pending | Pending |
| `vscjava.vscode-java-dependency` | Pending | Pending | Pending |
| `vscjava.vscode-maven` | Pending | Pending | Pending |
| `vscjava.vscode-java-test` | Pending | Pending | Pending |
| `vscjava.vscode-gradle` | Pending | Pending | Pending |
| `vscjava.vscode-java-pack` | Pending | Pending | Pending |
| `devsense.composer-php-vscode` | Pending | Pending | Pending |
| `devsense.phptools-vscode` | Pending | Pending | Pending |
| `Shopify.ruby-lsp` | Pending | Pending | Pending |
| `golang.Go` | Pending | Pending | Pending |
| `llvm-vs-code-extensions.vscode-clangd` | Pending | Pending | Pending |
| `Vue.volar` | Pending | Pending | Pending |
| `esbenp.prettier-vscode` | Pending | Pending | Pending |
| `redhat.vscode-yaml` | Pending | Pending | Pending |
| `rust-lang.rust-analyzer` | Pending | Pending | Pending |
| `muhammad-sammy.csharp` | Pending | Pending | Pending |
| `haskell.haskell` | Pending | Pending | Pending |
| `swiftlang.swift-vscode` | Pending | Pending | Pending |
| `Elmtooling.elm-ls-vscode` | Pending | Pending | Pending |
| `gleam.gleam` | Pending | Pending | Pending |
