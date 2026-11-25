# Workbench port audit

The reference is `vscode/src/vs/workbench/browser/workbench.ts` at
`e31c2e52`. It composes services and parts. The portable Zig Workbench now occupies that path. The native window and
terminal event loop live in src/tui; the native window still has remaining
feature wiring and service adapters to extract.

## Baseline at 47925902

| Measurement | Count |
| --- | ---: |
| Shell lines | 23,356 |
| Lines before the first test / remainder, including helpers | 15,703 / 7,653 |
| Workbench declaration, including closing brace | 12,402 |
| Workbench methods / file-scope functions including test helpers | 607 / 377 |
| Inline tests | 151 |
| Distinct files directly importing the shell | 18 |
| Files in src/vs directly importing src/tui | 12 |
| Zig layout / pinned layout.ts / pinned workbench.ts lines | 228 / 3,269 / 442 |

`zig build check-workbench` checks the shell budget and resolves relative Zig
imports. Each existing exception in `scripts/workbench-imports.txt` names both
ends of the edge. Delete an exception in the commit that removes its import.
The original test names and platform skip conditions are recorded by the baseline
commit. Preserve discovery through `src/tests.zig` when moving cases.

## Implemented since the baseline

Configuration reloads now compare the old and new scope contents and language
overrides before emitting changes, including removed settings. The search and
Markdown preview owners subscribe directly to configuration events and rebind
their listeners when the native workspace configuration service is replaced.
The native settings-watcher callback no longer dispatches feature reloads.
JSON preferences now use IPreferencesService, TextFileService and the
IEditorService resource-opening method. The Preferences contribution owns
the Action2 registrations. Command quick access uses the mounted FindController
to reveal a command ID in the textual keybindings editor. Panel and activity-bar
switch actions now use the shared SwitchCompositeViewAction and
IPaneCompositePartService. Layout owns hiding the active panel composite and
reopening the last/default panel, and persistence uses the last active ID even
while hidden. Native window callbacks mount views and route focus only.
The five existing view-container registrations now live at their contribution
paths; PaneCompositePartService populates the registered parts in the same
order. Problems commands resolve IViewsService and MarkersView owns
the focused-marker range highlighting rule.

The portable Workbench now owns its shutdown emitters, subscribes to the
host focus and dialog visibility events, and creates notifications before
attaching the workbench container. Git and notifications subscribe to the
same host focus event; storage flush saves layout, history and session on
focus loss. Search toolbar state updates on query and tree/result events,
not on frame painting. The portable budget grew by 12 lines solely to
restore missing upstream composition behavior; the native budget shrank
by 14, so the combined ratchet still decreases.
Close All/Close Other Editors now use the AbstractCloseAllAction owner:
collect editors in reverse grid appearance, exclude sticky editors for command
operations, confirm all dirty editors together, retain cancel semantics and
record one closed-editor history batch. The terminal quit uses the same
confirmation flow while including sticky editors.
IEditorGroup now exposes sequential editor lookup and openEditor. The
navigation/close/reopen actions use their editor owners: Previous/Next Editor
cross group boundaries in grid order, and terminal-specific tab navigation
remains within the current group. Revert-and-Close uses the input revert
contract and the upstream failure fallback.

The portable browser Workbench is 270 lines and has no inline tests. The native TerminalWorkbench window is 5,793 lines in `src/tui/workbenchWindow.zig`; the event loop and rendering are in `src/tui/workbench.zig`. Both sizes are ratcheted. Two files import the portable Workbench: the native window and the generic test fixture. No production feature module imports either window. No `src/vs` or `src/extensions` file imports `src/tui`. All 151 baseline
tests remain registered. Of those, 150 exercise the terminal host and one
exercises the tabs control at its owner path. The command-palette fixture
records the original 256 command IDs plus the newly ported notification commands with labels, categories and visibility for empty and
populated editor groups. The live palette reads CommandPalette menu contributions.
The line copy, move, sort, duplicate and indentation actions, comment, multicursor, bracket matching, smart selection, formatting, insert-final-newline, in-place replace and folding registrations now live in their editor contribution owners. They resolve the focused or active code editor through ICodeEditorService. The extraction preserves the pre-existing palette labels/categories and alias visibility; full upstream action metadata is still incomplete. A diff exposes its modified control as
the active editor and its focused side for commands.
Show All Commands resolves the quick input service through its Action2 handler.

* The upstream NotificationsModel and NotificationViewItem now own deduplication, normalized message content, progress, visibility and filter events, and status-message replacement. The portable tests run at their original owner path; Layout now honors zenMode.silentNotifications with the upstream exit-info ownership rule, and the notification parts react to position configuration changes. NotificationService owns source and global filters (using the storage service), prompt choices and status handles. The workbench registers its service interface; undo/redo warnings use it once the editor is mounted. NotificationsToasts now ports deferred creation, deduplication before the next frame, spam limiting, visibility, window-focus behavior and purge deadlines. The center, status, toast list and their commands are composed during workbench startup. Toast creation waits until Restored; input and cell painting go through the host. The extension message bridge now uses INotificationService for non-modal messages, with VS Code severity, source, action identities and deferred replies. DialogsModel and DialogService now own the portable confirmation/prompt queue, callback results and visibility events. BrowserDialogHandler adapts the queued item to the terminal widget; the host consumes input and paints it. Modal extension messages use the same service with the upstream cancel affordance, severity and choice ordering. The terminal widget accepts arbitrary choice counts and brings the focused button into view on narrow terminals. Dialog input, checkboxes and Markdown details are not ported.
* The Node extension-host adapter consumes the shared typed window services, editor service, view service, notification, terminal and configuration contracts. Only a Zig composition factory adapts the remaining cross-part host callbacks; the runtime no longer depends on Workbench or imports its shell. The shared preferred split direction and editor count now come from editor groups/editor services.
* Built-in extensions now consume explicit editor/command/status/quick-input services and typed callbacks for the remaining window actions; the built-in adapter no longer imports Workbench and delivers active text editor changes from mounted-pane events. Extension-host active-document mirrors follow editor/group events, and tab/selection/scroll changes are delivered on the window queue. The tab disposal event detaches listeners while the editor is alive. History listens to editor changes instead of mutating state on activeTab queries.
* Terminal pointer routing, tab/title hit testing, sash input routing, quick-input key/mouse dispatch and image capability/metrics now live in src/tui/workbench.zig. EditorPart resolves the maximized group in its own viewAt geometry. TerminalTabbedView owns tab-list interaction, drag/reorder, pane focus, sash resizing, hover and hit decisions. TerminalActions builds the switch/profile/tab menus and picker; picker labels have their own lifetime rather than using breadcrumbs scratch storage. Cross-part transfer and PTY routing still cross the terminal host adapter.
* The portable IEditorService mounted-pane contract now exposes the active input/control and actual editor events. IQuickInputService exposes pick results and visibility events. Image zoom and zoom selection are registered as Action2 in mediaPreviewActions and resolve those services, not Workbench. Existing palette metadata remains unchanged; reopening an image as text still crosses the shell’s resource-opening path.
* The Changes and Graph view-mode, sort, refresh, reveal and reference-picker commands are Action2 contributions in their SCM view owners. ViewAction resolves them through IViewsService; existing terminal palette metadata and commands that operate on a registered hidden view are retained during extraction, pending full upstream metadata/visibility parity. The Graph owns its reference picker, copies provider IDs and labels and cancels it on disposal.
* Decoded editor key/command and contribution dispatch now lives in the terminal CodeEditorWidget input adapter. The TUI view exposes a narrow IEditorKeyTarget; the built-in extension adapter and editor pane no longer import the terminal host’s input dispatcher. Raw decoding and quit handling remain at the host boundary.
* DiffEditorWidget and the snapshot diff pane accept the editor view adapter as an explicit Zig type parameter; neither imports the terminal renderer. Their existing tests live at the owner test paths. Find, Suggest and Sticky Scroll tests also receive the real terminal View from the test root, retaining every assertion without importing src/tui. EditorPane now receives an explicit EditorViewFactory from the terminal composition root. IEditorView exposes the mounted control and view-model host with a borrowed lifetime; actual cell painting stays in src/tui/editorView.zig. Model-decoration writes no longer depend on a concrete view. The extension host and Vim/Helix integration suites are instantiated with the real native factory by src/tests.zig.
* SearchEditorInput now owns upstream getMatchRanges/setMatchRanges and the previous decoration IDs. Generated results apply one TextModel delta and the terminal paints the existing searchEditorFindMatch class. The search editor no longer imports the terminal view; the rerun regression checks the actual alpha and beta match ranges.
* Sticky scroll now owns its editor/view-model and controller adapter; the terminal view supplies only resolved colors, cell painting, focus and frame callbacks. Six terminal renderer integration cases (including ANSI syntax painting and scrollbar projection) moved unchanged from the editor/widget and theme-service source files into src/tui/editorView.test.zig. The reverse import allowlist shrinks by four.
* Focus is now delivered at active editor/group changes, quick input show/hide, explicit part focus, modal dialog transitions, search input focus changes, and terminal active-instance/tab-list focus events. EditorPart updates the editor views; TerminalInstance emits its PTY focus sequence. The host no longer calls a focus synchronization method before rendering. A regression opens and switches editors, quick input and the status bar without painting a frame.
* Git Model resolves working/index/commit snapshot resources and Repository chooses the original/modified refs for each SCM resource. EditorService now owns diff pane reuse and opening, including group activation, model registration and error cleanup. Regression coverage reopens the partially staged file from SCM and verifies the existing index-to-working diff is reused.
* Native Git Commands owns stage/unstage (including renamed paths and unborn HEAD), resource/diff opening and the discard dialog result. It resolves the current repository after confirmation and emits file-change notifications through an explicit host adapter. The Graph owns its copied multi-change picker data and delegates diff opening to Git. The single-file discard/cancel, stage and unstage regression uses a temporary repository. Bulk clean, trash and checkout-conflict dialogs remain unported.
* The SCM contribution owns the SCM service, Changes and Graph views, and quick-diff storage, service and editor controller. It receives generic SCM/quick-diff providers rather than importing the Git repository or Workbench; sidebar registration and the remaining Git command handlers still cross the shell. The native Git repository owns its combined checkout/sync status command, and SCMActiveRepositoryController consumes provider statusBarCommands. SCMService retains live provider references instead of stale copied metadata. The native Git Repository owns input visibility, placeholder and branch-action projection; SCMContribution applies provider/configuration events to the views. The Git extension Commands owns the existing smart-commit subset, commit validation, deduplicating selected paths and post-commit remote action ordering. The smart-commit confirmation, signing and branch-protection prompts are not yet ported. The SCMActiveRepositoryController now owns the count badge and listens directly to provider resource and configuration events. With one active repository, focused badge mode retains the count when the sidebar is hidden, matching the upstream active-repository selection rather than sidebar focus.
* Git discovery, CLI initialization, repository and Git-service delegate ownership now live in the native extension Model (extensions/git/src/model.zig); the single-root discovery behavior is preserved. Parent-repository consent, ignored/unsafe repository tracking and multiple open repositories remain unported.
* Markdown and image preview view controllers and their asynchronous rendering/image ownership now live in their contribution directories. The terminal host supplies the ui image runtime and cell geometry. These features no longer require editorPane to import src/tui.
* TextDiffEditor reads its diff configuration through IConfigurationService rather than the shell.
* Layout owns terminal grid geometry, part constraints, sidebar/panel sizing and the application of centered/maximized editor layout. The geometry adapter receives only the registered part instances and terminal dimensions. Sash hit testing and pointer feedback are in the native host; EditorPart owns mounting and laying out visible editor panes on its surface.
* HistoryService owns active-editor subscriptions, pane selection/edit event recording, navigation restore suppression, back/forward and recently-closed editor batches. It opens resources through an explicit editor-service host adapter. The regression changes the active editor and edits it before drawing a frame, then verifies the inactive editor is detached.
* BreadcrumbsControlFactory now owns a persistent control for each editor group. The collection listens to group lifetimes, mounted active editor changes and breadcrumb configuration; it unbinds models before workspace/configuration replacement. Painting only reads the existing controls. The regression verifies same-control identity and new model resource before rendering, as well as inactive-group persistence.
* EditorDropTarget owns the drag session, selection anchor, preview overlay, transfer validation, drag image and hover/animation deadlines. Its owner receives EditorPart and the terminal frame/pointer adapters; the root provides only the remaining tab/group disposal, transfer and focus hooks. The existing drag/copy/merge and timed-hover integration tests exercise the same behavior.
* Keyboard and pointer routing for terminal tabs, editor tabs, global keybindings, sash gestures, sidebar/activity bar, status bar, panel, search editor, breadcrumb controls, dialogs and watermark now lives in `src/tui/workbench.zig`. This includes PTY paste/mouse encoding and cell-to-editor hit targeting. The application and host integration tests invoke these native adapters directly; portable extension lifecycle tests dispatch the corresponding close-editor command.
* All 19 terminal command IDs now register through TerminalActions Action2 and explicit terminal service/view dependencies. Their existing palette order, label, category and native availability semantics are retained. TerminalContextKeys binds terminal counts, editor location, panel visibility and split state directly to instance/group and editor/view events. The palette snapshot now includes Action2 context expressions, including 22 previously unrecorded conditions. All 272 IDs, order, labels, categories and visibility were compared unchanged. The terminal split and move regressions check availability changes before rendering.
* TerminalEditorService opens terminal inputs in the chosen editor group. TerminalService owns side-by-side placement, error-safe instance transfers between panel and editor, and selected-tab split/join/kill operations. TerminalActions resolves native menu IDs and rename-picker lifetimes; the shell supplies cell layout, focus and panel visibility.
* EditorGroupView owns dirty-close detection, duplicate-group checks, reveal and save/revert veto decisions through EditorInput and the file dialog service. The window-close action uses the same file confirmation, reveals the first dirty editor per group, and saves/reverts before disposing the groups. The async custom-close callback, autosave confirmation buckets and progress service remain unported.
* EditorGroupView owns persistent editor copying and opening the destination before closing the source for cross-group moves. Only terminal creation, external registration cleanup, drag cancellation and focus are supplied by the host.
* EditorPart owns the group grid layout, maximized geometry and group chrome settings. Each EditorGroupView updates breadcrumb visibility with its active pane.
* Creating and moving groups now use Action2 through IEditorGroupsService, with the upstream directional fallback and focus-preserving behavior when creating an empty group from a sidebar. Focus Status Bar resolves IWorkbenchLayoutService.focusPart.
* Centered layout, group cycling and resetting group sizes use Action2 and their layout/editor-group services.
* Directional editor-group commands ask EditorPart for the most recently active group
  sharing the requested grid edge. Wrapping preserves the row or column span.
  The nine group focus actions resolve IEditorGroupsService and focus the returned
  group. EditorPart emits its focus event after updating the active group.
* Search progress wakes the window and dispatches a batch to the sidebar or Search Editor that requested it. Debouncing uses an explicit deadline. New file matches prefer the live text model to raw search results; undisposed zero-match files remain bound so edits can restore matches. Edits to a bound model schedule its FileMatch update after 250 ms. Go to File updates the active picker when its worker finishes ranking, and uses deadlines for its progress bar. Git Repository subscribes directly to working-tree and metadata file events, scheduling status refresh itself. Each Quick Diff model schedules its own computation and receives worker replies through the window. Workspace watcher batches, settings reloads and completed Explorer listings wake the window. Folding schedules each editor’s update; tokenization workers deliver results to the window, and fallback tokenizers schedule model-specific idle work. Bracket queries build the AST as upstream does. Markdown preview timers and asynchronous renders also have window callbacks. The shell has no `poll*` or `tick*` methods; drag hover/overlay animation also runs only on registered window deadlines. Hover, word highlight, sticky scroll, in-place replace, outline-model and quick-suggest timers are registered with the window queue rather than scanned in the application loop. Deferred suggestion providers deliver completion callbacks on the window thread and cancel them when their session closes. Word highlighting listens to real model content, model cursor position and editor focus events; view-only projection/attachment events do not masquerade as cursor moves. Find uses the model content and explicit cursor events and a 100 ms update-decorations scheduler. EditorGroupView handles EDITOR_DIRTY to pin previews before the next frame instead of scanning dirty state. EditorStatus subscribes to the active code editor’s cursor, model content, options, language and encoding events; MediaPreviewStatus subscribes to active preview metadata and zoom changes. Search result events update the terminal-specific activity badge. The host no longer refreshes status or search badge state on every frame. Suggest listens to public cursor-selection, model-content, language, focus and type events, with the same quick-trigger deadline queue; OvertypingCapturer listens to onWillType. No Tab.onEditorChanged or contribution scan remains in the application loop.
* Twenty Search commands are registered as Action2 contributions by the search action
  modules. Find and result navigation open Search by view ID. Toggles and toolbar
  actions use the active view through IViewsService. The palette keeps its
  existing command IDs, labels and visibility.
* WorkbenchThemeService owns theme registry initialization, configured color-theme fallback loading, async cancellation, and the upstream configuration listener. It installs customizations before the color-theme event; the host only consumes the resolved theme for terminal palettes and syntax. UserKeybindingsLoader owns the profile resource watcher, upstream 50 ms reload schedule, raw-keybinding change detection, snapshot lifetime and async completion. The host consumes its onDidChange event instead of reloading keybindings on unrelated settings changes. File opens, external reloads, image decodes, theme loads and keybindings loads wake the window on completion. Closing an owner cancels its future and retracts its queued callback.
* TextFileService reads and decodes editor inputs for synchronous opens, interactive opens
  and watcher reloads. A missing input opens empty. A missing watched file reports a
  failed reload and preserves the open model. Closing or superseding a request cancels
  its read before releasing the path.
* Fresh and restored windows supply their initial service collection and call startup
  explicitly. Startup returns the instantiation service. The terminal opens command-line
  files after startup. Startup resolves
  the lifecycle service and signals Ready before initializing layout and starting
  the contribution registries. The editor part
  constructs group views from the registered group models. Each group restores
  its panes in model order and selects its active input. Restored inputs
  participate in the same active-editor events as newly opened inputs. Sessions
  save the active group ID and recent activation order. Closing the active
  group selects the previously active group. EditorPart saves and restores the
  SerializableGrid, including nested splits, proportions and the maximized leaf.
* Sidebar position updates the rail, sidebar, editor and panel rectangles together. The sash uses SplitView snapping on the side of the pointer where the sidebar sits.
* SCMHistoryViewPane creates the Graph hover when a row is hovered and disposes it when the hover clears.
* QuickDiffWorkbenchController follows mounted editor and configuration changes. Closing or hiding a file removes its model listeners and gutter decorations.
* MarkersView owns the Problems rows, cell rendering and input. The panel
  forwards its content rectangle and keeps focus when a selection previews a marker.
* Find reads the computed editor options on creation and on configuration changes.
  Find settings and language overrides apply before the next frame.
* MultiEditorTabsControl builds labels from the group model and resolves file icons
  through the theme service. Duplicate tabs use the pinned shortest distinguishing
  path algorithm.
* The native window supplies its parent document and terminal cell surface. Startup mounts the main container under that parent and disposal removes just the workbench subtree.
* Startup creates the activity bar, sidebar, editor, panel and status bar containers
  through their registered Parts in pinned source order before laying out the grid. EditorPart creates the grid
  container and EditorGroupView mounts its pane and watermark. The other
  terminal parts still have independent paint surfaces.
* The workbench options accept extra stylesheet class IDs and a layout reset.
  A reset skips stored profile sizes and workspace layout state.
* EditorService owns the shared sync/async text-editor opening path and the existing-file/image input lookup. TextFileService owns canonical path identity; the created editor, FileEditorInput and pane transfer ownership once. HistoryService merges stored and already-open files in MRU order. The terminal
  persists the legacy navigation and closed-editor records on shutdown.
* The layout service registers live parts and emits visibility, zen-mode and
  centering events. Layout owns zen entry, configuration changes and exit. The
  zen action and exit binding resolve the layout service. Layout restores
  workspace zen mode, editor centering and visibility, and profile part sizes. Centering considers the number of columns, the maximized
  group and the capabilities of visible editors. Stacked groups share one
  column. Layout registers group listeners before contributions start and installs the
  active editor listener after groups restore. Workbench context keys subscribe to layout and working-copy events.
* The service collection and instantiation service support explicit lazy
  factories. Layout signals readiness after restoring part state and signals full
  restoration after editor groups finish. Workbench races full restoration against
  two seconds, then schedules Eventually after 2.5 seconds and a window idle
  callback capped at another 2.5 seconds. The terminal host supplies monotonic
  time and idle opportunities. Contributions observe lifecycle phases and session saving runs
  on the workbench will-shutdown event. The workbench forwards did-shutdown after
  persistence. The native host releases the window after event dispatch returns. Document symbols use one shared outline-model service.
* The inline completion adapter uses the active editor service, content and cursor events, and window deadlines for provider requests.
* The main-thread message adapter receives notification and dialog service interfaces; the native prompt queue replaces the previous modal quick picker.
* Task providers, authentication account choices, file-icon theme data and
  sidebar moves have service owners. Simple Browser uses its bundled command
  handler and launches Lynx in a terminal editor. The bundled references view
  uses the extension command API to query reference and implementation providers
  and the window API to reveal a result.
* TerminalSuggestAddon requests completions through ITerminalCompletionService.
  The RPC reply wakes the terminal view directly. The terminal host currently
  supports explicit requests to the bundled terminal-suggest provider and
  appending a suffix at the prompt cursor.
* The Vim and Helix runtimes register their commands and persist user settings through
  the built-in extension API. Each owns the key handlers for its activation.
* The tunnel view owns the two Ports palette actions. The compiled-in extension
  registers its private local provider with the workspace API and uses the
  window terminal API.
* ContextMenuService owns the terminal popup, input capture and hide-before-action
  ordering. Outline, SCM Changes and SCM History resolve their registered actions
  through MenuService with pane-scoped context keys. StatusbarPart builds actions
  for the clicked entry.
* The SCM changes and history panes read settings through IConfigurationService.
  Configuration change events apply settings to open panes, including edits
  made through the configuration API. The graph restores its workspace view mode
  before applying the configured default.
* POSIX process exit wakes the terminal host. TerminalInstance flushes its final
  output and emits onExit before the panel or editor removes the instance.
  Pending writes resume on writable descriptor events.
* The terminal host owns its input buffer, descriptor waits, resize handling
  and frame composition. It paints parts, active editor panes, terminal overlays, group and part borders, sashes, emits image
  and ANSI updates, and positions the hardware cursor. Breadcrumb and outline updates request a frame from their
  model listeners. The command table, editor and terminal menu construction, feature
  wiring and command implementations still live in the browser shell.
  The native CLI still schedules background work and performs startup wiring.

The startup sequence below describes the pinned target. The composition port,
notification center and toasts, full layout restoration and event-driven
background services are implemented in part; see the current scope described above.

## Implementation owners

| Current responsibility | Pinned owner or terminal adaptation |
| --- | --- |
| Startup, registries, context keys, listeners, part creation, notifications, restore | workbench.ts in declaration and invocation order |
| Part visibility, dimensions, zen/centered layout, persistence | Layout, Part and IWorkbenchLayoutService. Grid and SplitView own sash behavior |
| Group/session reconstruction | EditorPart, EditorGroupView and editor group model. The session file transports the storage memento |
| Menus, command metadata and keybindings | Contribution actions, Action2, MenuRegistry and MenuService. Terminal popup painting and pointer input use ui |
| File icons | Theme service and fileIconThemeData. Seti associations belong to the theme and Nerd Font translation belongs to terminal rendering |
| Task, authentication, message and completion RPC | Main-thread customers call their corresponding services |
| References, port forwarding and Simple Browser commands | Extension command handlers and extension API |
| Sidebar view moves | View descriptor service, ViewPaneContainer and SidebarPart |
| Symbol picker, breadcrumbs and outline | Shared editor OutlineModelService. DocumentSymbolsOutline creates outlines for OutlineService |
| Markdown preview open, follow and reveal | markdown-language-features preview manager, editor groups and webview inputs. Terminal rendering and image protocols adapt the view |
| Quick access | Quick input service and individual providers |
| Terminal, SCM, Git and search | Terminal actions/service/views, SCM views, Git provider and search actions/views |
| Editor status, markers and breadcrumbs | Statusbar and editor parts, markers contribution, outline service |
| Configuration, keybindings, history and file operations | Corresponding services, text file and working copy models |
| Input, terminal capabilities, OS readiness and deadlines | Terminal host. Worker completion must wake the host while idle |
| Tests | Upstream owner paths and terminal host integration tests |

Upstream startup registers the layout service and sets Ready, initializes layout, starts
both registries, installs context keys and listeners, renders parts, creates
the workbench layout, lays it out and starts restoration. After layout readiness,
Restored races editor restoration against two seconds. Eventually uses the
delayed idle callback. The terminal host supplies time and readiness events.

The pinned layout test exercises floating-panel sash endpoints. Keep terminal
tests for snapping, Alt-drag, visibility events and size restoration in addition
to the portable endpoint assertions. Record each remaining browser-only omission
with its owning port.

* Layout exposes the registered part containers and cell sizes through IWorkbenchLayoutService. Editor resize Action2 handlers use the upstream active-group-first rule, falling back to the outer editor part only in unchanged dimensions. Sash and terminal panel resize commands use the same layout service.

* Outline focus and ViewTitle commands are Action2 contributions in outlineActions, resolving the typed pane via IViewsService. The pane publishes title-action changes from its setters rather than commands updating the window toolbar. The previous terminal palette visibility is retained.

* The Markdown preview manager lives at the pinned extension previewManager owner path. It registers the existing commands and owns dynamic preview reveal/reuse, source navigation, refresh, configuration updates and the active editor subscription. The native editor pane remains the preview store/render boundary. Locked previews and webview restoration remain unported.

* EditorPart owns copying, merging, splitting and disposing groups using the existing EditorGroupView transfer contracts. EditorActions owns 29 split, duplicate, close/join and move/copy-to-group Action2 registrations with the original palette metadata. Only view disposal, terminal focus, PTY creation and drag cancellation remain window callbacks. The native transfer contract is still a subset of the full IEditorGroupsService.

* SymbolNavigationAction now owns provider results, native reference picks and Action2 registration in goToCommands. GotoSymbolQuickAccessProvider owns its outline subscription, result labels and async stale-editor check. The native window supplies resource opening and focus through explicit callbacks. The terminal list substitutes for the browser reference peek widget; full upstream alternative-command and peek behavior remains unported.

* EditorService owns the native editor-opening adapter, including synchronous and asynchronous text/image opening, pending read cancellation, external-change reload completion, and preview replacement cleanup. Image inputs now have one ownership-transfer path. The file-system change event reaches the service directly; the window only supplies status, view setup, reveal and focus hooks.

* SearchViewTerminal owns the native Search view/service lifetime and document queries. SearchEditorFactory in searchEditor.contribution creates and navigates Search Editor inputs and registers the two palette actions; ReplaceService owns the native open/closed file edit adapter. The window supplies only editor focus/configuration/layout hooks. The closed-file adapter still uses the terminal byte-offset path rather than the full upstream bulk-edit service.

* The Git extension owns eight command registrations, remote publish picker identity and labels, and resolving snapshot diff contents (including unsaved working editors). SCMContribution owns its registered view container and model; SidebarPart owns view-container mounting and unmounting. The workbench supplies the native editor and SCM selection callbacks.

* The portable WorkbenchCore now owns Layout, InstantiationService, the upstream startup/registry/context/listener/part order, the notification controller and restore deadlines. The transitional native shell supplies explicit service instances and window lifecycle/focus callbacks. The next structural step relocates the native shell to src/tui and renames the core to Workbench at the pinned upstream path.

* The portable Workbench now lives at the pinned browser/workbench.zig path and owns Layout, the service-instantiation lifecycle, registered part creation, notification handlers and restoration deadlines. TerminalWorkbench is the native window adapter, and TerminalHostLoop owns fd/input readiness and frame delivery. Generic integration suites receive the window type at the test root. Remaining native feature wiring is still debt, not part of the faithful portable Workbench.

* WorkbenchContextKeysHandler owns the window context key handles. The native focus, active editor, layout, activity and quick-input events refresh their state; editor language/read-only and Search result focus use their own change events. The input dispatcher no longer refreshes context by scanning state before every global key.

* CodeEditorWidget exposes the native equivalent of upstream getContribution by registered contribution ID. Find, Sticky Scroll and WordHighlighter register/unregister their mounted controllers and own their Action2 commands. File Save/Revert use EditorInput and the editor groups service; Go to File uses IQuickInputService. All existing palette entries retain their original visibility and labels.
