# Extension gallery plan: current self-contained language servers

**Status:** proposed, not implemented.

## Are Theia / Open VSX built-ins current?

No, not relative to this repository.

| Source | Version | Date | Relation to minecode |
|---|---|---|---|
| minecode `vscode/` pin | **1.147.0** | commit `e31c2e52`, Nov 2026 | The source of truth |
| Theia GitHub release | **1.108.2** | Mar 2026 | Older VS Code tree |
| Open VSX `vscode.*` | **1.95.3** | Dec 2024 | Older still |

The Theia project does exactly the packaging work we want:

- It builds the MIT-licensed VS Code built-ins as standalone VSIXs.
- It includes the TypeScript SDK inside the TypeScript VSIX (`extension/deps/typescript`)
  and the HTML server's SDK inside the HTML VSIX
  (`extension/server/node_modules/typescript`).
- It patches the TypeScript extension's hard-coded `../node_modules` lookup, so
  the package is self-contained.
- It publishes the results to Open VSX under the `vscode` namespace.

But its newest published binary is **1.108.2**, not the 1.147.0 tree this repo
pins. Installing it would be convenient, but it would ship older language
servers and older extension implementations. It is useful as a **packaging
reference and compatibility fallback**, not as the default release source.

## Decision

Build the five self-contained VSIXs from the pinned `vscode/` tree using the
same packaging approach Theia uses. Then publish them as one gallery bundle.
This keeps the language servers exactly in sync with the extension host and
does not depend on Theia, Open VSX, or Marketplace versions.

Marketplace publishing is not needed for the panel. If a separate VS Code
Marketplace distribution is wanted later, it still requires an Extension Pack,
five child extensions, a publisher account/OIDC, and a distinct publisher; a
single VSIX containing five extensions is not supported.

## Goal and success criteria

- Default release contains no TS/HTML/CSS/Emmet/PHP language servers or SDK.
- Extensions panel shows **one** "Minecode Language Servers" item.
- Installing it downloads one bundle of five VSIXs built from the pinned tree.
- After restart, all five language servers work as they do today.
- Core archive target: **~18–21 MB** (from 29.3 MB).
- `lib/minecode` shrinks to ~47 MB extracted, but is not eliminated.
- Full development builds/tests remain full.

## What this does to `lib`

`lib/minecode` remains because it contains the Node extension host and core
extensions:

| Remaining component | Approx. extracted |
|---|---:|
| `extensionHost.mjs` | 6.0 MB |
| Core extensions (auth, terminal-suggest, merge-conflict, config/extension editing, npm, tasks, simple-browser, search-result, copilot) | 13.1 MB |
| `jsonServer.mjs` | 0.8 MB |
| Runtime `node_modules` (ripgrep, spdlog, proxy-agent, elkjs, katex, beautiful-mermaid, undici, …) | ~27.7 MB |
| **Total** | **~47.6 MB** |

Zero `lib` would require deleting the Node extension host, which also deletes
gallery and user-extension support.

## Packaging the current VSIXs

Add `host/package-vsix.js` (our own implementation; Theia's EPL-licensed
scripts are a behavioral reference, not copied code):

- Input: `host/dist/language-servers`.
- Output: `host/dist/vsix/` with five VSIXs:
  - `vscode.typescript-language-features.vsix`
  - `vscode.html-language-features.vsix`
  - `vscode.css-language-features.vsix`
  - `vscode.emmet.vsix`
  - `vscode.php-language-features.vsix`
- Each VSIX uses the standard layout:
  - `extension/` payload
  - `extension.vsixmanifest`
  - `[Content_Types].xml`
- TypeScript VSIX:
  - Add `extension/deps/typescript` from `host/node_modules/typescript`.
  - Patch the bundled SDK lookup from
    `getContributedVersion("bundled", "vscode.typescript-language-features", ["..", "node_modules"])`
    to the self-contained `[".", "deps"]` form used by Theia. Apply this as a
    documented build-time adaptation in `host/build-builtin-extensions.js`
    (esbuild `onLoad` transform), not by editing upstream files.
- HTML VSIX:
  - Add `extension/server/node_modules/typescript` from
    `host/node_modules/typescript`; the HTML server's external `typescript`
    import resolves there.
- CSS/Emmet/PHP VSIXs are self-contained without the SDK.
- Include `LICENSE-vscode.txt` and the existing `package.nls.json`,
  `schemas`, `server/lib`, etc.
- Use the extension package.json `publisher: "vscode"` and original IDs, so
  the host sees the same IDs it expects. Do not republish under a new publisher.

## One gallery bundle

Create one bundle asset per release:

```text
minecode-language-servers-<version>.zip
  bundle.json
  README.md
  licenses/
  vsix/
    vscode.typescript-language-features.vsix
    vscode.html-language-features.vsix
    vscode.css-language-features.vsix
    vscode.emmet.vsix
    vscode.php-language-features.vsix
```

`bundle.json`:

```json
{
  "schemaVersion": 1,
  "minecodeVersion": "0.2.0",
  "extensions": [
    {"id": "vscode.typescript-language-features", "vsix": "vsix/vscode.typescript-language-features.vsix"},
    {"id": "vscode.html-language-features", "vsix": "vsix/vscode.html-language-features.vsix"},
    {"id": "vscode.css-language-features", "vsix": "vsix/vscode.css-language-features.vsix"},
    {"id": "vscode.emmet", "vsix": "vsix/vscode.emmet.vsix"},
    {"id": "vscode.php-language-features", "vsix": "vsix/vscode.php-language-features.vsix"}
  ]
}
```

The release index has one entry:

```json
{
  "schemaVersion": 1,
  "minecodeVersion": "0.2.0",
  "bundles": [
    {
      "id": "minecode.language-servers",
      "version": "0.2.0",
      "displayName": "Minecode Language Servers",
      "description": "TypeScript, HTML, CSS, Emmet and PHP language features",
      "downloadUrl": "https://github.com/chendesheng/minecode/releases/download/v0.2.0/minecode-language-servers-0.2.0.zip",
      "sha256": "…",
      "size": 12345,
      "contains": [
        "vscode.typescript-language-features",
        "vscode.html-language-features",
        "vscode.css-language-features",
        "vscode.emmet",
        "vscode.php-language-features"
      ]
    }
  ]
}
```

The release workflow builds the bundle + index from the same tag. No external
registry is required.

## Gallery service and install

- `common/extensionGallery.zig`: bundle/index schema, validation,
  `IGallery` interface.
- `browser/extensionGalleryService.zig` (or `node/`): `RequestService`, async
  install jobs, `on_change`.
- Fetch the version-specific index; verify the bundle SHA-256 and size.
- Extract the bundle into a dot-prefixed temp directory under the user
  extensions directory.
- Read `bundle.json`; validate `minecodeVersion` and each VSIX path.
- For each VSIX:
  - Extract it into a temp directory.
  - Require exactly one top-level `extension/` payload.
  - Validate `extension/package.json` ID/version.
  - Move `extension/` to
    `<extensions>/<publisher>.<name>-<version>`.
- Preflight all five destinations; fail on partial/conflicting installs rather
  than mixing versions.
- Roll back already-moved extension directories if a later move fails.
- Call `ExtensionsWorkbenchService.refresh()`; emit a restart notice.
- Cancel jobs and clean temp dirs on deinit.
- No shared SDK dependency; each VSIX carries what it needs.

`ExtensionsWorkbenchService` gets a `userLocation()` getter. Reuse the
`markdownPreview.zig` worker/`dispatch.Task` pattern for async completion.

## Panel UI

Add an installed/available mode to `ExtensionsListView`:

- Title actions: **Browse Extensions** and **Installed**, plus Refresh.
- Register `workbench.extensions.action.showAvailableExtensions` and
  `workbench.extensions.action.showInstalledExtensions`; update the
  command-palette snapshot fixture.
- Browse mode fetches the index on first entry/Refresh; placeholder "Search
  Available Extensions".
- One row: "Minecode Language Servers", detail `Available · <size>`,
  `Installing…`, or `Installed`.
- Installed state is true when all five `contains` IDs are in the local
  inventory.
- Enter/left click installs; context menu adds Install for available,
  Open/Enable/Disable for installed.
- Loading/error states: "Loading extensions…", "Unable to load the extension
  gallery." with Refresh retry.
- On success: "Installed Minecode Language Servers. Restart minecode to
  activate."; the five extensions appear in the installed list after refresh.

## Wiring and version

- `src/tui/extensionsViewHost.zig` creates the gallery service with
  `workbench.async_io`, `&workbench.window_events`, `extensions_service`, and
  `user_location`; deinit in `detach`.
- Add `-Dversion` (default `0.0.0-dev`) to app/test build options; `--version`
  output; the release workflow passes the tag version.
- Default index URL is built from the compiled version;
  `MINECODE_EXTENSIONS_GALLERY` overrides it for forks/tests.
- If no user extensions directory or no async Io, browse reports unavailable.

## Core slimming

- Split `host/build-builtin-extensions.js` into:
  - `host/dist/extensions` (core)
  - `host/dist/language-servers` (five; used for VSIX packaging and full dev)
- Add `--core-only` / `--language-servers-only` and clean each output.
- Add `-Doptional-language-servers=true` to `build.zig`:
  - skip the five manifests from `share/minecode/extensions`;
  - install only core extensions into `lib/minecode/extensions`;
  - skip language-server dirs and SDK.
- `zig build host` uses `--core-only` in slim mode.
- Remove `typescript` from `host/runtime/package.json` and regenerate its
  lockfile; the gallery VSIXs carry their own SDK.
- Default dev builds remain full.

## Tests and CI

- VSIX packaging test: build a VSIX from a fixture extension; assert
  `extension/package.json`, manifest, and payload.
- TypeScript VSIX test: assert `extension/deps/typescript` and the patched
  bundled lookup.
- HTML VSIX test: assert `extension/server/node_modules/typescript` and that
  the server resolves it.
- Install-flow test with fake bundle/VSIX fixtures:
  - installs five fake extensions into a temp extensions dir;
  - verifies VSIX prefix handling, ID/version validation, rollback, cleanup;
  - verifies scanner visibility.
- VSIX path validation test (absolute/`..` entries).
- View test: one row, available/installing/installed, install action, errors.
- Update `src/tui/fixtures/workbench-palette.jsonl`.
- Update `extensionHostAdapter.zig` and `ci.yml` paths to
  `host/dist/language-servers`.
- Linux CI slim step: build slim core, assert five manifests/bundles absent;
  build VSIXs + bundle; validate hashes.
- Keep full `zig build test` and `zig build test-e2e` green using the pinned
  language servers.

## Documentation

- `README.md`: default release omits language servers; Extensions → Browse
  installs one current bundle; restart; `lib` remains.
- `docs/extension-gallery.md`: VSIX packaging, bundle/index schema, publishing,
  self-hosting, trust, install paths.
- `docs/extensions.md`: current pinned VSIXs; Theia is a packaging reference,
  not the shipped version.
- `docs/vscode-builtin-extension-status.md`: five language features are
  bundle-installed from the pinned tree.
- `host/runtime/README.md`: SDK is inside the TS/HTML VSIXs.
- Release notes: v0.2.0 assets, one-row install, JSON core, version match.

## Fallback and compatibility

- Theia 1.108.2 prebuilt VSIXs may be used only as a **temporary compatibility
  experiment**; they are not the default because they are older than the
  1.147.0 pin.
- If building the current VSIXs uncovers an upstream limitation, the known
  Theia patch points (`deps/typescript`, HTML server SDK) are the reference for
  fixing it.
- Do not silently fall back to older Open VSX versions. A version mismatch must
  be visible.

## Non-goals

- No Theia/Open VSX dependency for the shipped language servers.
- No Marketplace publishing; Theia already publishes older Open VSX versions,
  and Marketplace would require an Extension Pack/publisher.
- No multi-extension VSIX; the bundle contains five VSIXs and installs them as
  five extensions.
- No auto-update, uninstall, ratings, recommendations, or hot reload.
- No zero-`lib` build.
- JSON remains core.
