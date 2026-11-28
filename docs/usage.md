# Using minecode

This is the feature guide for minecode: install layout, command line, key
reference and the optional extension-backed features. The README is the
project overview, [design.md](design.md) is the architecture and porting
ledger, and the porting rules are in [AGENTS.md](../AGENTS.md).

The editor is usable with no extension host installed. TypeScript, JSON,
Git, Emmet, tasks and Copilot need the optional Node host described below.

## Contents

- [Command line](#command-line)
- [Install layout](#install-layout)
- [Building and testing](#building-and-testing)
- [Key reference](#key-reference)
- [Integrated terminal](#integrated-terminal)
- [Settings, themes, and keybindings](#settings-themes-and-keybindings)
- [Node extension host](#node-extension-host)
- [Extensions side panel](#extensions-side-panel)
- [Zig and ZLS](#zig-and-zls)
- [Extension accounts](#extension-accounts)
- [Extension tasks](#extension-tasks)
- [Simple Browser](#simple-browser)
- [Copilot inline completions](#copilot-inline-completions)
- [Vim](#vim)
- [Helix](#helix)
- [JSON, JSONC, TypeScript, and JavaScript](#json-jsonc-typescript-and-javascript)
- [Logs and diagnostics](#logs-and-diagnostics)

## Command line

```text
minecode [<folder>] [<file>...]
minecode --session <file> [<folder>] [<file>...]
minecode --preview <file>
minecode [--user-data-dir <dir>] [--extensions-dir <dir>] [--logsPath <dir>] [<file>...]
```

A directory argument opens a workspace folder; files open as tabs. Passing
only files opens an empty workspace, matching upstream VS Code. `--session`
restores the saved tab/group session and writes it back on exit; `--preview`
opens a single file read-only.

The TUI user-data directory is selected in upstream order: `MINECODE_PORTABLE`
(`<portable>/user-data`), `VSCODE_APPDATA` (`<appdata>/minecode`),
`--user-data-dir <dir>`, then the platform application-data directory
(`~/Library/Application Support/minecode`, `$XDG_CONFIG_HOME/minecode`,
`%APPDATA%\minecode`). The extensions directory follows `--extensions-dir`,
`MINECODE_EXTENSIONS`, `MINECODE_PORTABLE`, then `~/.minecode/extensions`.
The default is independent of VS Code; extensions already installed in
`~/.vscode/extensions` are left untouched and are not automatically loaded
or migrated. Explicit overrides can still select a different directory.
`VSCODE_EXTENSIONS` and `VSCODE_PORTABLE` are not read by Minecode; use the
`MINECODE_` equivalents instead.

`--logsPath` overrides the log directory. `--extensions-dir` also controls
which declarative extensions and themes are scanned at startup.

## Install layout

Tagged releases publish archives for Linux (x86_64 and aarch64 musl), macOS
(Apple Silicon) and Windows (x86_64). Extract an archive and run
`bin/minecode` from it.

The executable itself is a single native binary: the editor, workbench, UI,
terminal engine, Oniguruma and the main syntax grammars are linked or embedded
at build time. It is **not a single-file installation**. It resolves two
sibling directories relative to its own location:

- `share/minecode/extensions` — the pinned built-in extension catalog
  (manifests, language configurations, grammars, snippets, themes, icons).
  Without it the editor still opens files with the embedded fallbacks, but the
  full built-in language/theme catalog and its contributions are missing.
- `lib/minecode` — the optional Node extension host, JSON language server,
  and retained executable extensions. Default releases omit TypeScript, HTML,
  CSS and Emmet language-feature packages and their shared SDK; install them
  from Open VSX as user extensions. Full development builds retain the pinned
  fixtures. Without the host, Node-backed features stay disabled; Node must
  also be on `PATH` when this directory is present.

`share/minecode/extensions` and `lib/minecode/extensions` are not duplicates of
the same layer. The workbench scans `share` for declarative contributions
(manifests, language configurations, grammars, snippets, themes and icons). For
a built-in whose basename also exists under `lib/minecode/extensions`, the
implementation passes that `lib` directory to the Node extension host instead,
because it contains the bundled executable `main` and native assets. `share`
therefore supplies the catalog and editor-facing metadata; `lib` supplies only
the executable extension code. Keeping both lets a minimal install ship the
catalog while leaving the Node-backed features optional.

Keep the `bin/`, `share/` and `lib/` directories together when installing or
moving the editor. A release archive already has this layout.

## Building and testing

```sh
zig build                                      # Debug build with the system libonig
zig build -Donig-static=true                   # link the vendored Oniguruma
zig build -Doptimize=ReleaseSmall -Donig-static=true
zig build run -- <folder> [<file>...]          # open a workspace folder and files
zig build run -- <file>...                     # open files in an empty workspace
zig build run -- --session <file> [<folder>] [<file>...]
zig build run -- --preview <file>              # read-only terminal preview
zig build test                                 # editor and ui library tests
zig build test-terminal                        # terminal tests without the editor
zig build test-oracle                          # strict Neovim/Helix conformance
zig build test-oracle-vim                      # strict Vim lane (gated in CI)
zig build test-oracle-helix                    # strict Helix lane (gated in CI)
zig build test-watcher -Dwatcher-only=true     # watcher tests without the TUI
zig build bench-open                           # Debug open/edit benchmarks
zig build bench-ui -Dbench-args="--runs 5 --markdown"
```

The Node host, JSON server and extension-host interoperability commands are in
[Node extension host](#node-extension-host). Release builds and the CI matrix
are described in [design.md](design.md#build-packaging-and-ci).

## Key reference

The command palette (F1, or Alt-P in terminals that cannot report the chord)
lists every registered command. All of these can be rebound in
`keybindings.json`.

| Action | Keys |
| --- | --- |
| Quit / save | `Ctrl-Q` / `Ctrl-S` |
| Quick open (type `>` for commands) | `Ctrl-P` |
| Command palette | `F1`, `Alt-P` |
| Find / replace in editor | `Ctrl-F` / `Ctrl-R` |
| Find in files | `Ctrl-Shift-F`, `Alt-F` |
| Toggle side bar / panel | `Ctrl-B` / `Ctrl-J` |
| Focus side bar / status bar | `Ctrl-0` / `Ctrl-Alt-S` |
| Next / previous tab | `Ctrl-PgDn` / `Ctrl-PgUp`, `Alt-1..9` by position |
| Close tab | `Ctrl-W` |
| Split editor right / down | `Alt-\` / `Alt-Shift-\` |
| Switch editor group | `Ctrl-Alt-Left` / `Ctrl-Alt-Right` |
| Toggle terminal | `Alt-Shift-T` |
| Problems | `Ctrl-Shift-M` |
| Zen mode | `Ctrl-K Z` |
| Markdown preview to the side / toggle | `Ctrl-K V` / `Ctrl-Shift-V` |
| Hover / suggest | `gh` / `Ctrl-Space` |
| Rename / go to definition | `F2` / `F12` |
| Go to symbol / workspace symbol | `Ctrl-Shift-O` / `Ctrl-T` |
| Next / previous problem | `F8` / `Shift-F8` |
| Add cursor below / select next occurrence | `Ctrl-Alt-Down` / `Ctrl-D` |
| Move / copy line | `Alt-Up`/`Alt-Down` / `Shift-Alt-Up`/`Shift-Alt-Down` |
| Toggle line / block comment | `Ctrl-/` / `Alt-/` |

The integrated terminal and the modal editors have additional keys; see
their sections below and [vim.md](vim.md) / [helix.md](helix.md).

## Integrated terminal

The TUI has a bottom terminal panel backed by a real POSIX pty and the
[libghostty-vt](https://libghostty.tip.ghostty.org/vt/) terminal engine
(pinned in `build.zig.zon`). It is the terminal counterpart of VS Code's
xterm.js instance: VS Code's portable profile/environment/title/service code is
ported under `src/vs/{platform,workbench}/.../terminal/`, the pty replaces
node-pty, and libghostty-vt replaces xterm.js. Process exit wakes the host while
idle. The terminal flushes its last output before notifying listeners and closing its tab.

| Action | Shortcut |
| --- | --- |
| Toggle terminal panel | `Alt+Shift+T` (also "Terminal: Toggle Terminal" in the command palette) |
| New terminal | `Alt+Shift+N` |
| Kill active terminal | `Alt+Shift+W` |
| Previous / next panel terminal group | `Ctrl+PageUp` / `Ctrl+PageDown` while the terminal has focus |
| Resize panel | `Alt+Shift+Up` / `Alt+Shift+Down` (mouse drag is a follow-up) |

The panel handles interactive programs (alternate screen, colors, cursor
addressing), UTF-8 and grapheme clusters, scrollback, resize (pty `TIOCSWINSZ`),
mouse and focus reporting, and bracketed paste. `Ctrl+Q` remains the TUI quit
shortcut.

Terminal tabs form a resizable list beside the shell. By default the list is on
the right and hides with one terminal. The `terminal.integrated.tabs` settings
control visibility, side, click-to-focus mode, and the active title and actions
in the panel toolbar. The toolbar opens new terminals and offers profile and terminal-switch dropdown menus.
Split groups share the terminal area; each pane has its own PTY size, and the
list shows branch markers for group members.

**Terminal: Create New Terminal in Editor Area** opens a shell in an editor tab.
The side command opens one in an adjacent group. The terminal editor title's
`+` opens a terminal in the same group. Its dropdown selects a profile, and
Alt-click splits to the side. The
terminal tab context menus and command palette move an existing shell between
the panel and the editor area while keeping its PTY and scrollback.
`terminal.integrated.defaultLocation` can make editor tabs the default for
**Terminal: New Terminal**.

- The POSIX host runs local terminals. Windows ConPTY, remote terminals, and
  restoring terminal processes after closing the workbench are outside this port.
- The TUI represents browser codicons and split geometry with terminal cells.
  The side-list width is saved per profile.
- Terminal text selection/copy, find, link opening, and shell-integration
  decorations remain outside this slice.

- The integrated terminal panel does not forward kitty images; the workbench
  editor uses them for image previews (see **Image preview**). WebGL/ligature/
  unicode addons, persistent/remote terminals and accessibility mode are not
  ported.
- The terminal cursor uses the outer terminal's cursor shape; bar/underline
  cursor settings are approximated.

The full rationale and the phased scope are in
[terminal-ui.md](terminal-ui.md). `zig build test-terminal` runs the
terminal-specific tests without compiling the editor.

## Settings, themes, and keybindings

The configuration service resolves defaults, the VS Code stable profile user
settings, the TUI profile user settings, the workspace-file settings and each
folder's `.vscode/settings.json`, in that order. JSONC comments and trailing
commas are accepted. The TUI profile lives at
`<user-data-dir>/User/settings.json`; the VS Code profile layer is the normal
`Code/User` directory (`~/Library/Application Support/Code/User` on macOS,
`~/.config/Code/User` on Linux, `%APPDATA%\Code\User` on Windows).

There is no Settings editor yet: run **Preferences: Open User Settings (JSON)**
from the command palette, or edit the files directly. All settings files are
watched and reload automatically.

Color themes are discovered from the enabled declarative extension catalog;
`workbench.colorTheme` defaults to `Dark 2026`. Syntax colors, `workbench.colorCustomizations`,
`editor.tokenColorCustomizations` and semantic token rules are applied live
when the theme or settings change. Icon themes and the Color Theme picker are
not ported.

User keybindings are read from the VS Code profile `keybindings.json` and then
`<user-data-dir>/User/keybindings.json` (later entries win). The upstream
JSONC array format is supported: platform `key` variants, chords, `when`,
`args`, `systemWide` and `-command` removals. **Preferences: Open Keyboard
Shortcuts (JSON)** opens the TUI file. User bindings resolve before defaults;
bindings whose command is not registered in the terminal are ignored with a log
entry rather than swallowing the key. Extension-contributed keybindings and the
Keyboard Shortcuts editor are not ported.

The full configuration, theming and keybinding implementation record is in
[design.md](design.md#settings-themes-and-keybindings).

## Node extension host

The workbench half of VS Code's extension system is ported under
`src/vs/workbench/services/extensions/` and `src/vs/workbench/api/`. The Node
host itself is reused from the pinned tree, bundled with esbuild. This is
optional: the editor and workbench run without it, with the embedded grammars
and grammar fallbacks.

```sh
cd host && npm ci                          # esbuild, @vscode/ripgrep, @vscode/spdlog
cd .. && zig build host                    # bundles from the pinned vscode/ submodule
zig build json-server                      # optional JSON language server bundle
zig build run -- [--user-data-dir <dir>] [--extensions-dir <dir>] [--logsPath <dir>] [<file>...]
zig build test-e2e                        # boots the Node host and runs TypeScript extension interop
```

The native binary resolves executable extensions from its install prefix.
The full development `zig build host` builds the launcher and executable
extensions from the pinned checkout. These provide TypeScript/JavaScript, HTML, CSS/Less/SCSS, Emmet,
PHP, Git Base, Search Result, configuration and manifest authoring, Merge Conflict,
Simple Browser, Terminal Suggest, GitHub and Microsoft authentication, and the
npm, Grunt, Gulp and Jake task providers. The build installs their bundles, language
servers and TypeScript SDK under `lib/minecode` in the same prefix
as `zig build` (including `--prefix`). Default releases use `-Dgallery-extensions=true` to omit the four optional
language-feature packages and shared SDK. The ordinary native build requires
no Node installation. The host receives the same enabled, deduplicated installed
inventory as the declarative registry, including user and declarative-only
extensions. Bundled system extensions use the installed runtime bundle when
present; otherwise the catalog location is used.

Windows CI includes a pinned Node-host startup and extension activation/RPC
interop test. The integrated terminal's PTY support remains a separate
Windows gap. Host stderr is written to `<data dir>/extension-host.log`, normally
`<user-data-dir>/logs/extension-host.log`, so it cannot corrupt the TUI frame.
`zig build test-e2e` is skipped unless `host/dist/extensionHost.mjs` and the
TypeScript extension fixture are present.

See [design.md](design.md#node-extension-host-experimental) for the transport,
RPC table pin and remaining host work, and [extensions.md](extensions.md) for
the port status.

## Extensions side panel

The Extensions activity (`Ctrl-Shift-X`, `View: Show Extensions`) has a shared
search header and registered query-specific views. Installed extensions are
shown by default; a fresh user inventory also shows Popular results, while
workspace recommendations come from `.vscode/extensions.json` or a workspace
configuration file, respecting unwanted recommendations. `@builtin` separates Features, Themes and Programming
Languages. `@installed`, `@enabled`, `@disabled`, `@updates`, `@outdated`,
`@recentlyUpdated`, `@recentlyPublished`, `@restartRequired`, `@recommended`,
`@popular`, `@contribute:<feature>`, category, tag, file-extension and ID
filters select local or gallery views. A sort-only search sorts the installed
view; exact IDs resolve installed extensions before querying Marketplace. Ctrl+Space or the search filter control completes query tokens.
The gallery is Open VSX by default, using its native search and identifier
APIs. `MINECODE_EXTENSION_GALLERY_URL` can override the gallery endpoint.
The compatible query transport remains available for other compatible
providers and search criteria the native API does not support. This registry
adaptation is an intentional difference from upstream VS Code. In a default release, install optional language
features by searching for `@id:vscode.typescript-language-features`,
`@id:vscode.html-language-features`, `@id:vscode.css-language-features` or
`@id:vscode.emmet`, then choosing Install. Syntax highlighting and basic
editing are available without these downloads. See the
[release inventory and qualification](extension-gallery-plan.md). Searches are delayed, cancellable and paged
on scroll; publisher, install counts, ratings, channel and update metadata
appear in list rows and the editor. The extension icon remains unchanged when
a pre-release bookmark is shown.

Clicking a row or pressing Enter opens a read-only, singleton extension editor
preview tab, not `package.json`. Its tabs display README, registered Features,
changelog, dependencies and extension pack when available. Dependency and pack
links open the corresponding extension detail editor. Features include
commands, settings/defaults, languages, themes, activation events, API
proposals, JSON validation, debugger declarations, colors, views and view
containers, custom editors, language packs, authentication providers,
notebooks and notebook renderers, plus actual local host activation status.
The contribution tables describe manifests; they do not imply that all of
those contribution runtimes are implemented. The responsive additional
details pane shows installation information, Marketplace dates, categories and
resource links. The terminal uses shared Markdown layout rather than browser
webviews, fetching gallery documentation asynchronously. Arrow keys switch tabs
or scroll; Tab moves between content, actions and navigation. List and editor
actions expose Enable/Disable (global and workspace), Install/Update,
Uninstall, release/pre-release switching, and specific version selection. The
shared management menu (the detail editor gear and row context menu) includes
checked extension/publisher Auto Update preferences.
Dependency and pack relationships are resolved for installation and checked for
uninstall and enablement; confirmation is requested when other members change.

Gallery installation stages downloaded VSIX packages in the effective user
extensions directory (`--extensions-dir`, `MINECODE_EXTENSIONS`,
`MINECODE_PORTABLE`, or `~/.minecode/extensions`), validates identity, version,
engine and archive entries, and publishes the selected versions together.
The active version is recorded in the extension profile; cached versions can
be selected again. Open VSX Ed25519 signatures are verified natively when
available; unsupported signatures are not treated as verified. The command
`Extensions: Install from VSIX...` accepts a local package path. Built-ins
cannot be uninstalled. Global enablement is persisted in
`<user-data-dir>/User/globalStorage/extensions.state.json` under
`extensionsIdentifiers/disabled`; workspace overrides are persisted separately.

Update checks are independent of sidebar searches. The configuration controls
`extensions.autoCheckUpdates`, `extensions.autoUpdate`,
`extensions.autoUpdateDelay` and `extensions.verifySignature` govern checks
and delayed unattended installation; unattended updates require verification
and the upstream automatic-update eligibility policy (enabled and unpinned by
default, with explicit selection when global automatic updates are off). Host inventory changes use
extension-host deltas where supported; activated extensions that cannot be
removed live expose Restart Extensions. Changes to startup-owned declarative
contributions (languages, grammars, themes, configuration and snippets) still
require restarting the editor.

Remaining portable parity gaps include full profile/server management,
additional recommendation sources, chat/MCP-specific feature renderers and
runtime error/access telemetry, dynamic declarative contribution
registration, and the complete trust and extension-policy services. The
terminal uses text/glyphs instead of gallery artwork and browser webviews;
remote/web extension hosts and browser file-picker multi-selection are not
implemented. See [the extension system documentation](extensions.md).

## Zig and ZLS

Install `ziglang.vscode-zig` in the effective extensions directory and build the
Node host (`zig build host` installs the current runtime; a native-only rebuild
leaves the installed Node bundle unchanged). With Zig and ZLS installed
locally, enable `"zig.zls.enabled": "on"` in the VS Code settings used by the
editor. The extension can discover Zig on PATH; set `"zig.path"` or
`"zig.zls.path"` explicitly to select a particular executable. The real Zig extension 0.7.0 with Zig/ZLS 0.17.0 has been
verified to activate from a standalone Zig file and a workspace containing
`build.zig`, return hover content from ZLS, and publish both Zig language
status items to the status bar. Incremental document edits are reflected in
subsequent ZLS hover responses. The Zig extension’s ZLS output command opens
the real file-backed Output panel. Go to Symbol in Workspace (`Ctrl-T` or
type `#` in Quick Access) queries real ZLS workspace symbols and opens their
source locations. Expand/Shrink Selection also consumes language-server
selection ranges, syntax folding uses the server’s folding ranges, and
Trigger Parameter Hints displays server-provided signatures and active
parameters in an editor content widget. Rich documentation and scrolling
remain outstanding. Rename Symbol (`F2`) prepares the symbol with its provider
and applies workspace edits or opens the existing refactoring preview. Semantic
tokens are applied to the normal syntax-token pipeline with document and
viewport-range providers, including theme rules and incremental result IDs.
Inlay hints display themed, tracked injected text, support provider resolution
and hover, and navigate on modifier-click without modifying document text. The
negotiated capabilities are recorded in
[the reference capture](zig-zls-reference-capabilities.json). The full LSP capability matrix
is still in progress; see [the integration plan](zig-extension-lsp-plan.md). The default end-to-end suite also
runs a real `vscode-languageclient` against a deterministic mock LSP server,
including nested save and workspace edits. The opt-in real-Zig suite also opens this repository as a workspace and
checks its actual `range.zig`/`position.zig` sources, including a semantic-color
change in the default Dark 2026 theme's terminal cells, cross-file navigation,
workspace symbols, inlay hints and rename preparation without writing source
files. It also paints and scrolls `src/tui/wakeSignal.zig` while real ZLS
semantic and inlay updates arrive.

`zig build json-server` builds and installs the optional standalone JSON server.
The intermediate bundles under `host/dist` are also used by the repository's
interop tests. The host transports use Unix sockets on macOS/Linux and Windows
named pipes, with a shared Node launcher.

Markdown preview uses KaTeX from the optional host to render Greek symbols,
roots, fractions and scripts in inline, display and fenced math. Unsupported
expressions keep their TeX source. Set `markdown.math.enabled` to `false` to
turn off equation rendering.

Markdown preview uses the optional host’s Mermaid renderer for supported
fenced diagrams. It lays them out in the background and keeps the original
fence visible if parsing fails. [Terminal Mermaid renderer](https://github.com/lukilabs/beautiful-mermaid)

With shell integration enabled, **Ctrl+Space** opens completion suggestions for
the current command in Bash, Zsh, fish or PowerShell. Select a suggestion to
insert it at the prompt. Running the command takes a separate Enter.
The terminal reads prompt boundaries from OSC 133 and the directory from OSC 7.

**GitHub: Publish to GitHub** opens the GitHub CLI repository creation wizard
in the current repository or workspace. **Ports: Forward a Port** accepts a
port number or a local address such as `localhost:3000`. The tunnel view
asks the registered provider to run the Microsoft Dev Tunnels CLI in an
integrated terminal.
The temporary tunnel uses private access. Stop it from the Ports commands or
with Ctrl+C in that terminal. These commands require `gh` and `devtunnel`,
respectively, on PATH. [Dev Tunnels CLI](https://learn.microsoft.com/azure/developer/dev-tunnels/cli-commands)

## Extension accounts

Open **Accounts: Manage Accounts** and choose GitHub or Microsoft to list
accounts, start sign-in or sign out of a selected account. When an extension
requests a session, the editor shows its ID, provider and requested scopes for
approval. The native secret store and grants last for the current editor
session. GitHub device-code sign-in can be selected with
`"github-authentication.preferDeviceCodeFlow": true`. Terminals that support
OSC 52 can copy the displayed code. Copilot uses its own sign-in command below.

## Extension tasks

Run **Tasks: Run Task** in the command palette. Select the provider, then a
detected task. Its process starts in the integrated terminal using the working
directory supplied by the extension. For Grunt, Gulp and Jake, enable the
corresponding `grunt.autoDetect`, `gulp.autoDetect` or `jake.autoDetect`
setting with the value `"on"` and install the project’s task runner.

## Simple Browser

Install Lynx on the terminal host and put `lynx` on `PATH`. Open the command
palette, select **Simple Browser: Show** and enter an HTTP or HTTPS URL. The
page opens in an editor tab. Press Enter on a link to follow it and Left to go
back. Pages that require a graphical browser or client-side JavaScript need a
different renderer. [Lynx](https://lynx.invisible-island.net/)

## Copilot inline completions

Build the native editor and host, install GitHub’s language server, then start
the editor with the server executable selected. The adapter reads its executable
from the process environment. Model content and cursor events schedule inline completion requests; changing editors or opening Suggest cancels them. [GitHub Copilot Language Server](https://github.com/github/copilot-language-server-release)

```sh
npm --prefix host ci
zig build
zig build host
npm install -g @github/copilot-language-server@1.574.1
MINECODE_COPILOT_SERVER=copilot-language-server zig-out/bin/minecode example.py
```

Open the command palette and run **GitHub Copilot: Sign In**. The status bar
shows a device code. Run the same command again to open GitHub and enter the
code. After signing in, type in a supported file. Inline suggestions can insert
text at the cursor or replace text that follows it. Strikethrough marks the
characters a suggestion would remove. Tab accepts the suggestion,
Escape dismisses it, and Undo restores the previous text. Multiline suggestions
show their first line with a return marker and insert the full text on acceptance.
Use **GitHub Copilot: Sign Out** to end the session. The adapter honors
`github.copilot.enable` per language and `editor.inlineSuggest.enabled`.

## Vim

Vim is a compiled-in built-in extension (`minecode.vim`), enabled
with `"vim.enabled": true` in the user settings or after startup with the
`Vim: Enable` / `Vim: Disable` commands; both persist the user-level
`vim.enabled` setting. It does not use the Node extension
host. The editor core knows only the generic built-in extension and
key-input interfaces; the Vim extension registers its own key handler through
them. The normal/insert/replace/visual character/line/block modes, counts, motions
(`{`/`}`, `(`, `)`, `H`/`M`/`L`, `gj`/`gk`, `f`/`t`), operators, text objects, marks, macros,
registers, undo/redo (`u`/`U`/`Ctrl-R`), visual-block `I`/`A`, dot-repeat,
incremental regular-expression search (`/`, `?`, `n`, `N`) that previews the
match while the prompt is typed and highlights every match with the Ctrl+F
find-match colors, the workbench editor navigation history (`Ctrl-O`/`Ctrl-I`),
viewport commands (`zz`/`zt`/`zb`, `Ctrl-D`/`U`) and the
basic `:` commands (`:w`, `:q`, `:q!`, `:wq`, `:e`, `:bn`, `:bp`, `:bd`, `:sp`,
`:vsp`, `:noh`/`:nohlsearch`) are implemented in Zig.

Vim uses the editor's own state instead of a parallel history:

- `u`/`Ctrl-R` call `Editor.undo()`/`Editor.redo()`. One insert session or
  operator change is one editor undo group; no diff tracker is kept.
- Insert mode uses the regular editor key dispatch for typing, completion,
  snippet navigation, automatic closing pairs, and indentation.
- `j`/`k` use the editor's `leftoverVisibleColumns`, so the visible column is
  preserved across tabs, wide characters and short lines; at the first and last
  line the motion is a no-op that keeps the remembered column.
- Visual selections and cursor positions live in the editor's selection state.
  Vim keeps only command state (pending count/operator, registers, search).

The status bar shows `-- NORMAL --`, `-- INSERT --`, `-- VISUAL --`, pending
keys and the `:`/`/` prompt. See [vim.md](vim.md) for the supported feature list
and the deliberate non-goals (Vimscript, plugins and `.vimrc`).

## Helix

Helix is the second compiled-in modal editor (`minecode.helix`),
enabled with `"helix.enabled": true` or with the `Helix: Enable` /
`Helix: Disable` commands; both persist the user-level `helix.enabled`
setting. It uses the same editor-state ownership and raw key-input contract as
Vim, but follows Helix's selection-first model: `w` selects a word, `d` acts on
the selection, `x` selects a line, `%` selects the file, `s` selects regex
matches, and editing commands work on every selection. The normal/insert/select
modes, multiple selections, registers, macros, `.` repeat, incremental search
with find-match highlighting, command line,
goto/match/view/window/space minor modes, linewise, surround and text-object
operations (`mi`/`ma`), and the `:` commands (`:w`, `:q`, `:q!`, `:wq`, `:e`,
`:reload`, `:bn`, `:bp`, `:bd`, `:sp`, `:vsp`, `:noh`, `:set`) are implemented
in Zig. Vim and Helix are mutually exclusive: enabling one disables and
persists the other off. Helix Insert mode uses the regular editor key dispatch
for suggestions, snippets, auto-closing pairs, and indentation.
Bracket matching and bracket text objects in both engines use the ported VS
Code bracket-pair AST, so they honor the language's configured bracket pairs
and skip brackets inside comments and strings; `< >` text objects require a
language configuration that declares them.
See [helix.md](helix.md) for the supported surface and
deliberate gaps.

## JSON, JSONC, TypeScript, and JavaScript

JSON and JSONC editors use the bundled VS Code JSON language server when
`lib/minecode/jsonServer.mjs` is installed. Diagnostics appear as severity-
colored squiggles, overview-ruler marks, Problems entries and status-bar
counts; `Ctrl-Space` completion, hover, formatting, document symbols and
breadcrumbs come from the same server. The `json.schemas` setting drives
validation, completion and hover. Without the bundle the editor keeps the
bundled grammar and reports no diagnostics.

TypeScript and JavaScript use the real `typescript-language-features`
extension through the Node host: tsserver diagnostics, completion, hover,
go-to-definition/implementation/references, go-to-symbol, formatting and
breadcrumb symbols. Without the host bundle, TS/JS tabs keep the bundled
grammar and indentation behavior. CodeLens, semantic tokens, inlay hints and
the remaining language features are forwarded through the ported
language-feature bridge.

The editor core is UTF-8. Position-bearing RPCs convert between the host's
UTF-16 code units and the editor's UTF-8 byte columns at the extension-host
and TextMate boundaries. See
[design.md](design.md#language-features-and-built-in-extensions) for the full
feature and RPC status.

## Logs and diagnostics

The TUI writes one synchronous `main.log` in the terminal user data directory:

- macOS: `~/Library/Application Support/minecode/logs/main.log`
- Linux: `$XDG_CONFIG_HOME/minecode/logs/main.log`
- Windows: `%APPDATA%\minecode\logs\main.log`

`--logsPath <dir>` overrides the directory. Timestamps are UTC. Startup stage
timings (`workbench-init`, `themes`, `workspace-git`, `first-frame`,
`after-restored`) are logged for diagnosing slow starts. `std.log` output,
including libghostty-vt parser diagnostics, goes through the same ported
logger; nothing writes to stderr while the alternate screen is active.

Crash reports are the exception: the panic handler leaves the alternate screen,
restores raw mode and prints the Zig stack trace on the normal screen.
Extension-host stderr goes to `<user-data-dir>/logs/extension-host.log`. To
diagnose a runtime leak with allocation stack traces, run
`zig build run -Dallocator-stack-traces=true -- <folder> [<file>...]`.

See [design.md](design.md#logging) for the ported logging services and the
console/URI-keyed logger omissions.
