# Workbench port audit

The reference is `vscode/src/vs/workbench/browser/workbench.ts` at
`e31c2e52`. It composes services and parts. The current Zig composition
root still owns terminal painting, input routing and feature implementations.

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

The browser shell is 13,701 lines and has no inline tests. It has no direct imports from `src/tui`. Nine files import the shell. All 151 baseline
tests remain registered. Of those, 150 exercise the terminal host and one
exercises the tabs control at its owner path. The command-palette fixture
records 256 command IDs with labels, categories and visibility for empty and
populated editor groups. The live palette reads CommandPalette menu contributions.
The seven line copy, move, sort and duplicate actions resolve the focused or active
code editor through ICodeEditorService. A diff exposes its modified control as
the active editor and its focused side for commands.
Show All Commands resolves the quick input service through its Action2 handler.

* Fresh and restored windows supply their initial service collection. Startup resolves
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
* HistoryService merges stored and already-open files in MRU order. The terminal
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
  on shutdown. Document symbols use one shared outline-model service.
* Task providers, authentication account choices, file-icon theme data and
  sidebar moves have service owners. Simple Browser uses its bundled command
  handler and launches Lynx in a terminal editor. The bundled references view
  uses the extension command API to query reference and implementation providers
  and the window API to reveal a result.
* TerminalSuggestAddon requests completions through ITerminalCompletionService.
  The RPC reply wakes the terminal view directly. The terminal host currently
  supports explicit requests to the bundled terminal-suggest provider and
  appending a suffix at the prompt cursor.
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
  and frame composition. It paints group and part borders, paints sashes, emits image
  and ANSI updates, and positions the hardware cursor. Breadcrumb and outline updates request a frame from their
  model listeners. The command table, editor and terminal menu construction, feature
  wiring and several state-scanning methods still live in the browser shell.
  The native CLI still schedules background work and performs startup wiring.

The startup sequence below describes the pinned target. The composition port,
notification center and toasts, full layout restoration and event-driven
background services are still in progress.

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
