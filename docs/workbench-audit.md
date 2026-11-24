# Workbench port audit

The reference is `vscode/src/vs/workbench/browser/workbench.ts` at
`e31c2e52`. It composes services and parts. The current Zig composition
root also owns the terminal host, feature implementations and integration tests.

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

Startup registers the layout service and sets Ready, initializes layout, starts
both registries, installs context keys and listeners, renders parts, creates
the workbench layout, lays it out and starts restoration. After layout readiness,
Restored races editor restoration against two seconds. Eventually uses the
delayed idle callback. The terminal host supplies time and readiness events.

The pinned layout test exercises floating-panel sash endpoints. Keep terminal
tests for snapping, Alt-drag, visibility events and size restoration in addition
to the portable endpoint assertions. Record each remaining browser-only omission
with its owning port.
