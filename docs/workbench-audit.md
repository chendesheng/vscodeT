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

The browser shell is 14,950 lines and has no inline tests. All 151 baseline
tests remain registered. Of those, 150 exercise the terminal host and one
exercises the tabs control at its owner path. The command-palette fixture
records 256 command IDs with labels, categories and visibility for empty and
populated editor groups. The live palette reads CommandPalette menu contributions.
Show All Commands resolves the quick input service through its Action2 handler.

* Fresh and restored workbenches share service construction. The editor part
  constructs group views from the registered group models. Each group restores
  its panes in model order and selects its active input. Restored inputs
  participate in the same active-editor events as newly opened inputs. Sessions
  save the active group ID and recent activation order. Closing the active
  group selects the previously active group. EditorPart saves and restores the
  SerializableGrid, including nested splits, proportions and the maximized leaf.
* The layout service registers live parts and emits visibility, zen-mode and
  centering events. Layout owns zen entry, configuration changes and exit. The
  zen action and exit binding resolve the layout service. Centering considers the number of columns, the maximized
  group and the capabilities of visible editors. Stacked groups share one
  column. Workbench context keys subscribe to layout and working-copy events.
* The service collection and instantiation service support explicit lazy
  factories. Contributions observe lifecycle phases and session saving runs
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
  window terminal API. Thirteen files still import the shell.
* The SCM changes and history panes read settings through IConfigurationService.
  Configuration change events apply settings to open panes, including edits
  made through the configuration API. The graph restores its workspace view mode
  before applying the configured default.
* The terminal host owns its input buffer, descriptor waits, resize handling
  and frame output. Breadcrumb and outline updates request a frame from their
  model listeners. The command table, native menu construction, feature
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
