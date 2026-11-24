# VS Code built-in extension status

The native TUI targets **87 of the 94 shipped desktop extensions** in VS Code 1.147.0. Seven packages are deferred. Copilot inline completions are in scope. Debugging, profiling, notebooks and chat are deferred, including those contributions inside otherwise in-scope packages. [Desktop packaging rules][packaging] · [Product package list][product]

Source review on 2026-11-24 at workbench commit `9caf348b8844` and VS Code pin `e31c2e52f563620846caab877103f630ea361b9c`. The initial statuses reflect implementation and test-source inspection. Installed-TUI verification is pending on macOS, Linux and Windows.

| Status | Packages | Meaning |
| --- | ---: | --- |
| Verified | 0 | All scoped workflows passed in the installed TUI on the target platforms, with recorded evidence. |
| Partial | 29 | An identifiable portion is wired. The row gives the working path and the remaining integration or verification. |
| Planned | 58 | The package is in scope and a required integration is missing. |
| Unverified | 0 | Evidence is insufficient to classify current behavior. |
| Deferred | 7 | The entire package is outside the current scope. |

Each ID links to its upstream manifest or product entry. The default startup scan reads the Markdown basics and default themes manifests. The Node host is provisioned separately and currently receives only the TypeScript extension. Windows host startup is pending. [Startup wiring][startup] · [Host transport][transport]

## Language basics and file formats (48)

Language basics cover file recognition, highlighting and editing rules. For each planned package, register its manifest and check that opening the example file selects the language and highlights its syntax. [Language registry][langs]

| Extension ID | What it provides | Status | Current coverage or next workflow |
| --- | --- | --- | --- |
| [`vscode.bat`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/bat/package.json) | Windows batch syntax and editing | Planned | Open `*.bat` and expand a contributed snippet. |
| [`vscode.clojure`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/clojure/package.json) | Clojure syntax and editing | Planned | Open `*.clj`. |
| [`vscode.coffeescript`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/coffeescript/package.json) | CoffeeScript syntax and editing | Planned | Open `*.coffee` and expand a contributed snippet. Breakpoints are deferred. |
| [`vscode.cpp`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/cpp/package.json) | C, C++ and CUDA C++ syntax and editing | Partial | C and C++ grammars and editing rules are embedded. CUDA file recognition, snippets and compiler problem matchers still need integration. [Bundled assets][assets] |
| [`vscode.csharp`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/csharp/package.json) | C# syntax and editing | Planned | Open `*.cs` and expand a contributed snippet. |
| [`vscode.css`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/css/package.json) | CSS syntax and editing | Partial | The CSS grammar and editing rules are embedded. Check the full manifest’s file associations and bracket behavior in the installed TUI. [Bundled assets][assets] |
| [`vscode.dart`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/dart/package.json) | Dart syntax and editing | Planned | Open `*.dart`. |
| [`vscode.diff`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/diff/package.json) | Unified diff syntax and editing | Planned | Open `*.diff`. |
| [`vscode.docker`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/docker/package.json) | Dockerfile syntax and editing | Planned | Open `Dockerfile`. |
| [`vscode.dotenv`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/dotenv/package.json) | Dotenv syntax and editing | Planned | Open `*.env`. |
| [`vscode.fsharp`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/fsharp/package.json) | F# syntax and editing | Planned | Open `*.fs` and expand a contributed snippet. |
| [`vscode.go`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/go/package.json) | Go syntax and editing | Partial | The Go grammar and editing rules are embedded. Verify the language-specific settings defaults. [Bundled assets][assets] |
| [`vscode.groovy`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/groovy/package.json) | Groovy syntax and editing | Planned | Open `Jenkinsfile` and expand a contributed snippet. |
| [`vscode.handlebars`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/handlebars/package.json) | Handlebars syntax and editing | Planned | Open `*.handlebars`. |
| [`vscode.hlsl`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/hlsl/package.json) | HLSL syntax and editing | Planned | Open `*.hlsl`. |
| [`vscode.html`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/html/package.json) | HTML syntax and editing | Partial | HTML grammar and editing rules are embedded. Extend file associations and verify contributed snippets. [Bundled assets][assets] |
| [`vscode.ini`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/ini/package.json) | INI and properties syntax and editing | Planned | Open `*.ini`. |
| [`vscode.java`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/java/package.json) | Java syntax and editing | Partial | Java grammar and editing rules are embedded. Check the additional file associations and contributed snippets. [Bundled assets][assets] |
| [`vscode.javascript`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/javascript/package.json) | JavaScript and JSX syntax and editing | Partial | JS and JSX grammars and editing rules are embedded. Check contributed snippets, filename associations and semantic-token mappings. [Bundled assets][assets] |
| [`vscode.json`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/json/package.json) | Syntax and editing for JSON, JSONC, JSON Lines and snippet files | Partial | JSON and JSONC grammars and indentation rules are embedded. JSON Lines and snippet-file language modes remain to be integrated. [Bundled assets][assets] |
| [`vscode.julia`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/julia/package.json) | Julia and Julia Markdown syntax and editing | Planned | Open `*.jl`. |
| [`vscode.latex`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/latex/package.json) | LaTeX, TeX and BibTeX syntax and editing | Planned | Open `*.sty`. |
| [`vscode.less`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/less/package.json) | Less syntax and editing | Planned | Open `*.less`. |
| [`vscode.log`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/log/package.json) | Log file syntax | Planned | Open `*.log`. |
| [`vscode.lua`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/lua/package.json) | Lua syntax and editing | Planned | Open `*.lua`. |
| [`vscode.make`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/make/package.json) | Makefile syntax and editing | Planned | Open `Makefile`. |
| [`vscode.markdown`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/markdown-basics/package.json) | Markdown syntax and editing | Partial | Startup scans the language manifest. Comment, bracket and folding rules are wired. Verify snippet expansion and language defaults. [Scanner tests][scan] |
| [`vscode.objective-c`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/objective-c/package.json) | Objective-C and Objective-C++ syntax and editing | Planned | Open `*.m`. |
| [`vscode.perl`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/perl/package.json) | Perl and Raku syntax and editing | Planned | Open `*.pl`. |
| [`vscode.php`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/php/package.json) | PHP syntax and editing | Planned | Open `*.php` and expand a contributed snippet. |
| [`vscode.powershell`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/powershell/package.json) | PowerShell syntax and editing | Planned | Open `*.ps1`. |
| [`vscode.prompt`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/prompt-basics/package.json) | Syntax for prompt and instruction files | Planned | Open `*.prompt.md`. Only file editing is in scope. |
| [`vscode.pug`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/pug/package.json) | Pug syntax and editing | Planned | Open `*.pug`. |
| [`vscode.python`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/python/package.json) | Python syntax and editing | Partial | Python grammar and editing rules are embedded. Check additional associations such as `.pyi` and `SConstruct`, and language defaults. [Bundled assets][assets] |
| [`vscode.r`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/r/package.json) | R syntax and editing | Planned | Open `*.R`. |
| [`vscode.razor`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/razor/package.json) | Razor syntax and editing | Planned | Open `*.cshtml`. |
| [`vscode.restructuredtext`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/restructuredtext/package.json) | reStructuredText syntax and editing | Planned | Open `*.rst`. |
| [`vscode.ruby`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/ruby/package.json) | Ruby syntax and editing | Planned | Open `rakefile`. |
| [`vscode.rust`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/rust/package.json) | Rust syntax and editing | Partial | The Rust grammar and editing rules are embedded. Verify manifest associations and editing behavior in the installed TUI. [Bundled assets][assets] |
| [`vscode.scss`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/scss/package.json) | SCSS syntax and editing | Partial | SCSS grammar and editing rules are embedded. The contributed compiler problem matcher still needs task integration. [Bundled assets][assets] |
| [`vscode.shaderlab`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/shaderlab/package.json) | ShaderLab syntax and editing | Planned | Open `*.shader`. |
| [`vscode.shellscript`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/shellscript/package.json) | Shell script syntax and editing | Partial | Shell grammar and editing rules are embedded. Check startup-file associations and first-line detection. [Bundled assets][assets] |
| [`vscode.sql`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/sql/package.json) | SQL syntax and editing | Planned | Open `*.sql`. |
| [`vscode.swift`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/swift/package.json) | Swift syntax and editing | Planned | Open `*.swift` and expand a contributed snippet. |
| [`vscode.typescript`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/typescript-basics/package.json) | TypeScript and TSX syntax and editing | Partial | TS and TSX grammars and editing rules are embedded. Check snippets, semantic-token scopes and special JSON filenames. [Bundled assets][assets] |
| [`vscode.vb`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/vb/package.json) | Visual Basic syntax and editing | Planned | Open `*.vb` and expand a contributed snippet. |
| [`vscode.xml`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/xml/package.json) | XML and XSL syntax and editing | Planned | Open `*.xml`. |
| [`vscode.yaml`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/yaml/package.json) | YAML and Docker Compose syntax and editing | Partial | The upstream configuration is embedded. Highlighting uses the vendored YAML grammar. Docker Compose and full manifest associations remain to be integrated. [Bundled assets][assets] |

## Language services and editor features (14)

| Extension ID | What it provides | Status | Current coverage or next workflow |
| --- | --- | --- | --- |
| [`GitHub.copilot-chat`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/copilot/package.json) | Copilot inline code completions | Planned | Connect GitHub sign-in and the completion provider. Verify ghost text while typing, Tab acceptance, Escape dismissal and undo. Chat, agents and next-edit suggestions are deferred. [Upstream provider][copilot] |
| [`vscode.configuration-editing`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/configuration-editing/package.json) | Completions and fixes for VS Code configuration files | Planned | Activate the configuration editor and verify suggestions in a settings file. |
| [`vscode.css-language-features`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/css-language-features/package.json) | CSS, Less and SCSS language services | Planned | Activate the CSS server and request a property completion. |
| [`vscode.emmet`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/emmet/package.json) | Markup and stylesheet abbreviation expansion | Planned | Expand an abbreviation in an HTML document. |
| [`vscode.extension-editing`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/extension-editing/package.json) | Extension manifest authoring | Planned | Activate the authoring tools and request a completion in an extension manifest. |
| [`vscode.html-language-features`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/html-language-features/package.json) | HTML language services | Planned | Activate the HTML server and request tag completion and hover. |
| [`vscode.json-language-features`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/json-language-features/package.json) | Schema-aware JSON editing | Partial | With the optional server bundle present, the standalone JSON server supplies diagnostics, completion, hover, formatting and symbols. Verify the extension’s commands and schema contributions. [JSON client][json-client] |
| [`vscode.markdown-language-features`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/markdown-language-features/package.json) | Markdown preview, navigation and editing | Partial | The native side preview renders Markdown and synchronizes scrolling. Extension-powered editing remains to be covered. Notebook rendering is deferred. [Preview port][preview] |
| [`vscode.markdown-math`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/markdown-math/package.json) | Math expressions in Markdown previews | Planned | Add and verify inline and block math in the terminal preview. Notebook output is deferred. |
| [`vscode.mermaid-markdown-features`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/mermaid-markdown-features/package.json) | Mermaid diagrams in Markdown | Planned | Render a fenced diagram in the terminal preview. Notebook and chat renderers and language-model tools are deferred. |
| [`vscode.php-language-features`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/php-language-features/package.json) | PHP completion, hover and validation | Planned | Activate the PHP features and verify completion and diagnostics in a PHP file. |
| [`vscode.references-view`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/references-view/package.json) | Persistent references and implementations view | Planned | The existing reference quick pick is a separate workflow. Integrate the extension’s tree and search history. |
| [`vscode.search-result`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/search-result/package.json) | Syntax and navigation in saved search results | Partial | The `.code-search` mode and grammar are bundled. Verify the extension’s result definitions, symbols and header completion. [Language registry][langs] |
| [`vscode.typescript-language-features`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/typescript-language-features/package.json) | JavaScript and TypeScript IntelliSense | Partial | When provisioned, the real extension supplies diagnostics, completion, hover, formatting and navigation. Inlay hints still lack a terminal renderer. Debugger contributions are deferred. [Host tests][ts-tests] |

## Workspace tools and accounts (13)

| Extension ID | What it provides | Status | Current coverage or next workflow |
| --- | --- | --- | --- |
| [`vscode.git`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/git/package.json) | Source control and file history | Partial | The native Git CLI integration reads changes and supports staging and commits. The upstream Node extension and its exported Git API still need integration. [Git port][git-port] |
| [`vscode.git-base`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/git-base/package.json) | Git file languages and remote-source API | Planned | Register commit and rebase modes and make remote sources available to dependent extensions. |
| [`vscode.github`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/github/package.json) | GitHub repository workflows | Planned | Connect Git and authentication, then verify publishing a repository. |
| [`vscode.github-authentication`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/github-authentication/package.json) | GitHub sign-in and sessions | Planned | Provide a session to a requesting extension and verify sign-out. |
| [`vscode.grunt`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/grunt/package.json) | Grunt task discovery | Planned | Discover a Gruntfile task and run it from the task picker. |
| [`vscode.gulp`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/gulp/package.json) | Gulp task discovery | Planned | Discover a gulpfile task and run it from the task picker. |
| [`vscode.jake`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/jake/package.json) | Jake task discovery | Planned | Discover a Jakefile task and run it from the task picker. |
| [`vscode.merge-conflict`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/merge-conflict/package.json) | Conflict markers and resolution commands | Planned | Expose the actions to accept the current, incoming or both versions of a conflict. |
| [`vscode.microsoft-authentication`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/microsoft-authentication/package.json) | Microsoft account sign-in and sessions | Planned | Provide a Microsoft account session to a requesting extension. |
| [`vscode.npm`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/npm/package.json) | Package scripts and npm tasks | Planned | Discover and run a `package.json` script. Script debugging is deferred. |
| [`vscode.simple-browser`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/simple-browser/package.json) | Open a URL in an editor tab | Planned | Upstream delegates to the Integrated Browser or embeds a page in a webview. The TUI has no wired URL view. Graphical page rendering remains a gap. [Upstream command][browser] |
| [`vscode.terminal-suggest`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/terminal-suggest/package.json) | Command-line completions in the terminal | Planned | Connect shell completion providers and accept a suggested argument. |
| [`vscode.tunnel-forwarding`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/tunnel-forwarding/package.json) | Forward a local port through a tunnel | Planned | Connect the tunnel provider and verify opening and closing a forwarded port. |

## Color themes and file icons (12)

For additional color themes, point `--extensions-dir` at the pinned `vscode/extensions` directory and select the theme by name with `workbench.colorTheme`. These packages still need default discovery and an installed-TUI palette check. [Theme loading][theme-loader]

| Extension ID | What it provides | Status | Current coverage or next workflow |
| --- | --- | --- | --- |
| [`vscode.theme-abyss`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/theme-abyss/package.json) | Abyss color theme | Partial | Profile scan only. Verify the selected palette. |
| [`vscode.theme-defaults`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/theme-defaults/package.json) | Default color and icon themes | Partial | Startup registers the color themes and the editor uses Dark+ token colors. The contributed file icon theme still needs integration. [Scanner tests][scan] |
| [`vscode.theme-kimbie-dark`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/theme-kimbie-dark/package.json) | Kimbie Dark color theme | Partial | Profile scan only. Verify the selected palette. |
| [`vscode.theme-monokai`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/theme-monokai/package.json) | Monokai color theme | Partial | Profile scan only. Verify the selected palette. |
| [`vscode.theme-monokai-dimmed`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/theme-monokai-dimmed/package.json) | Monokai Dimmed color theme | Partial | Profile scan only. Verify the selected palette. |
| [`vscode.theme-quietlight`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/theme-quietlight/package.json) | Quiet Light color theme | Partial | Profile scan only. Verify the selected palette. |
| [`vscode.theme-red`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/theme-red/package.json) | Red color theme | Partial | Profile scan only. Verify the selected palette. |
| [`vscode.theme-solarized-dark`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/theme-solarized-dark/package.json) | Solarized Dark color theme | Partial | Profile scan only. Verify the selected palette. |
| [`vscode.theme-solarized-light`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/theme-solarized-light/package.json) | Solarized Light color theme | Partial | Profile scan only. Verify the selected palette. |
| [`vscode.theme-tomorrow-night-blue`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/theme-tomorrow-night-blue/package.json) | Tomorrow Night Blue color theme | Partial | Profile scan only. Verify the selected palette. |
| [`vscode.vscode-modern-icons`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/theme-modern-icons/package.json) | Modern file icons | Planned | Load the contributed icon associations into the Explorer and tabs. Both currently use a native glyph table. [File icons][icons] |
| [`vscode.vscode-theme-seti`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/theme-seti/package.json) | Seti file icons | Planned | Load the contributed icon associations into the Explorer and tabs. Both currently use a native glyph table. [File icons][icons] |

## Deferred packages (7)

| Extension ID | What it provides | Status | Current coverage or next workflow |
| --- | --- | --- | --- |
| [`ms-vscode.js-debug`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/product.json) | JavaScript debugger | Deferred | JavaScript debugging is deferred. |
| [`ms-vscode.js-debug-companion`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/product.json) | Companion for JavaScript debugging | Deferred | JavaScript debugging is deferred. |
| [`ms-vscode.vscode-js-profile-table`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/product.json) | Table view for JavaScript CPU profiles | Deferred | Profiling is deferred. |
| [`vscode.builtin-notebook-renderers`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/notebook-renderers/package.json) | Built-in notebook output renderers | Deferred | Notebook output rendering is deferred. |
| [`vscode.debug-auto-launch`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/debug-auto-launch/package.json) | Automatic Node debugger attachment | Deferred | Debugger integration is deferred. |
| [`vscode.debug-server-ready`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/debug-server-ready/package.json) | Server-ready actions during debugging | Deferred | Debugger launch actions are deferred. |
| [`vscode.ipynb`](https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/ipynb/package.json) | Open, edit and save Jupyter notebooks | Deferred | Notebook documents and cell editing are deferred. |

## Updating this tracker

When coverage changes, update the row and status count together. Record the tested workflow, OS, revision, and a link to the installed-TUI test or runtime result. Keep platform-specific results in the row until all target platforms pass. After an upstream pin change, reconcile full IDs against desktop packaging, including the separately packaged Copilot extension and product-listed packages. The catalog omits the four upstream test fixtures.

[assets]: ../build.zig#L185
[langs]: ../src/vs/workbench/services/language/common/bundledLanguages.zig
[packaging]: https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/build/lib/extensions.ts#L320
[product]: https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/product.json
[scan]: ../src/vs/workbench/services/extensions/common/extensionsRegistry.zig#L378
[startup]: ../src/tui/app.zig#L278
[transport]: ../src/vs/workbench/services/extensions/common/extensionHostManager.zig#L137
[theme-loader]: ../src/tui/app.zig#L518
[ts-tests]: ../src/vs/workbench/api/browser/extensionHostAdapter.zig#L1926
[json-client]: ../src/vs/workbench/services/language/common/jsonLanguageClient.zig
[git-port]: ../src/extensions/git/src/repository.zig
[preview]: ../src/vs/workbench/contrib/markdown/browser/markdownPreviewDocument.zig
[copilot]: https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/copilot/src/extension/completions/vscode-node/completionsCoreContribution.ts#L44
[browser]: https://github.com/microsoft/vscode/blob/e31c2e52f563620846caab877103f630ea361b9c/extensions/simple-browser/src/extension.ts
[icons]: ../src/vs/workbench/browser/fileIcon.zig
