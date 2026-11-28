# Extension gallery plan: one language-servers bundle

**Status:** proposed, not implemented.

This document records the plan for making the default minecode release smaller
by moving the TypeScript, HTML, CSS, Emmet and PHP language servers into a
single downloadable bundle, and for adding a minimal Browse / Install flow to
the Extensions side panel.

## Short answer: Marketplace vs one extension

**Yes, you can publish to the VS Code Marketplace, but not as one VSIX
containing five extensions.**

- A VSIX installs **one** extension directory. It cannot contain five
  independent extensions.
- VS Code's supported "one listing installs several extensions" mechanism is an
  **Extension Pack** (`extensionPack` in `package.json`). The pack is one
  Marketplace listing, but it references five child extension IDs that must
  also be published.
- A true single VSIX containing merged TypeScript/HTML/CSS/Emmet/PHP
  implementations would be a rewrite of five extensions into one activation
  unit. It would not be a faithful port and is out of scope.
- For **minecode's own Extensions panel**, a single downloadable **bundle
  asset** is simpler than five packages: one row, one download, installs the
  five extension directories plus the shared TypeScript SDK.
- Marketplace publishing also requires a publisher account under your own
  publisher ID (not `vscode`), Marketplace policies, and packaging/publishing
  via `vsce`. PAT-based publishing is being retired on **2026-12-01**; use
  GitHub Actions Trusted Publishing/OIDC
  ([publishing docs](https://code.visualstudio.com/api/working-with-extensions/publishing-extension)).
  Republishing Microsoft's built-in extensions under a new publisher is
  MIT-licensed but carries a real duplicate/impersonation policy risk; use
  clearly distinct names and do not imply Microsoft ownership.

This plan implements the **single minecode gallery bundle**. It also prepares
the Marketplace/Open VSX extension-pack path as an optional follow-up, because
it requires a publisher account and five child listings.

## Goal and success criteria

- Default release no longer includes TS/HTML/CSS/Emmet/PHP language servers or
  the TypeScript SDK.
- Extensions panel shows **one** item, "Minecode Language Servers", which
  downloads and installs all five plus the SDK.
- After restart, all five servers work as they do today.
- Core archive target: **~18–21 MB** (from 29.3 MB).
- `lib/minecode` shrinks to ~47 MB extracted, but is not eliminated.
- Full development builds and existing tests keep working.

## What this does to `lib`

`lib/minecode` remains because it contains the Node extension host and core
Node extensions:

| Remaining component | Approx. extracted |
|---|---:|
| `extensionHost.mjs` | 6.0 MB |
| Core extensions (auth, terminal-suggest, merge-conflict, config/extension editing, npm, tasks, simple-browser, search-result, copilot) | 13.1 MB |
| `jsonServer.mjs` | 0.8 MB |
| Runtime `node_modules` (ripgrep, spdlog, proxy-agent, elkjs, katex, beautiful-mermaid, undici, …) | ~27.7 MB |
| **Total** | **~47.6 MB** |

Zero `lib` would require deleting the Node extension host, which also deletes
gallery and user-extension support.

## Decisions and assumptions

- Release version: **v0.2.0**.
- Phase 1 gallery hosting: GitHub Release assets + a version-specific index:
  `https://github.com/chendesheng/minecode/releases/download/v<version>/extensions-index.json`.
- One bundle asset: `minecode-language-servers-<version>.zip`.
- The bundle contains five extension directories and the shared TypeScript SDK.
- The panel installs the whole bundle atomically into the effective user
  extensions directory.
- JSON remains built in.
- Marketplace/Open VSX publishing is **Phase 2**, not required for the panel.
- No general marketplace, ratings, search backend, auto-update, uninstall UI,
  or hot reload.

## Phase 1: single bundle publishing

### Bundle layout

`minecode-language-servers-<version>.zip` contains at its root:

```text
bundle.json
README.md
licenses/
extensions/
  typescript-language-features/
  html-language-features/
  css-language-features/
  emmet/
  php-language-features/
node_modules/typescript/
```

`bundle.json`:

```json
{
  "schemaVersion": 1,
  "minecodeVersion": "0.2.0",
  "extensions": [
    {
      "id": "vscode.typescript-language-features",
      "version": "10.0.0",
      "path": "extensions/typescript-language-features"
    },
    {
      "id": "vscode.html-language-features",
      "version": "10.0.0",
      "path": "extensions/html-language-features"
    },
    {
      "id": "vscode.css-language-features",
      "version": "10.0.0",
      "path": "extensions/css-language-features"
    },
    {
      "id": "vscode.emmet",
      "version": "10.0.0",
      "path": "extensions/emmet"
    },
    {
      "id": "vscode.php-language-features",
      "version": "10.0.0",
      "path": "extensions/php-language-features"
    }
  ],
  "dependencies": [
    {
      "id": "minecode.typescript-sdk",
      "version": "6.0.3",
      "path": "node_modules/typescript",
      "installPath": "node_modules/typescript"
    }
  ]
}
```

### Index schema

`extensions-index.json` contains one bundle entry:

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

### Generator

Add `scripts/build_language_bundle.py`:

- Inputs: `--source host/dist/language-servers`, `--version`, `--base-url`,
  `--out`.
- Copies the five extension dirs and `node_modules/typescript` into a staging
  tree.
- Writes `bundle.json`, `README.md`, and license files.
- Zips the staging tree with `bundle.json` at the root.
- Computes SHA-256 and size; emits `extensions-index.json`.
- No external Python dependencies.

The release workflow's `language-bundle` job builds it on Ubuntu and uploads the
zip + index; `publish` attaches both to the GitHub Release.

## Phase 1: gallery service and install

### Service

Add a gallery service under the Extensions contribution:

- `common/extensionGallery.zig`: bundle/index schema, validation,
  `GalleryEntry`, `IGallery` interface.
- `browser/extensionGalleryService.zig` (or `node/`): concrete service with
  `RequestService`, async install jobs, and `on_change`.

Responsibilities:

- Fetch and validate the version-specific index asynchronously.
- Expose one bundle row, loading/error state, and install state.
- Download the bundle, verify SHA-256, reject oversized bodies.
- Extract with `std.zip.extract` into a dot-prefixed temp directory inside the
  extensions directory.
- Read and validate `bundle.json`; validate `minecodeVersion`, all five
  `package.json` IDs/versions, and the SDK version.
- Preflight all destination paths:
  - `<extensions>/vscode.typescript-language-features-10.0.0`
  - `<extensions>/vscode.html-language-features-10.0.0`
  - `<extensions>/vscode.css-language-features-10.0.0`
  - `<extensions>/vscode.emmet-10.0.0`
  - `<extensions>/vscode.php-language-features-10.0.0`
  - `<extensions>/node_modules/typescript`
- Move all payloads into place and roll back already-moved directories if a
  later move fails.
- Reject partial/conflicting installs with a clear message rather than mixing
  versions.
- Call `ExtensionsWorkbenchService.refresh()` and emit a restart notice.
- Cancel jobs and clean temp dirs on deinit.

`ExtensionsWorkbenchService` gets a `userLocation()` getter. Reuse the existing
`markdownPreview.zig` worker/`dispatch.Task` pattern for async completion.

### Panel UI

Add an installed/available mode to `ExtensionsListView`:

- Title actions: **Browse Extensions** and **Installed**, plus Refresh.
- Register matching commands
  (`workbench.extensions.action.showAvailableExtensions`,
  `workbench.extensions.action.showInstalledExtensions`); update the
  command-palette snapshot fixture.
- Browse mode fetches the index on first entry/Refresh; placeholder "Search
  Available Extensions".
- One row: "Minecode Language Servers", detail `Available · <size>` or
  `Installing…` or `Installed`.
- Installed state is true when all five `contains` IDs are found in the local
  inventory.
- Enter/left click installs; context menu adds Install for available,
  Open/Enable/Disable for installed.
- Empty/loading/error states: "Loading extensions…", "Unable to load the
  extension gallery." with Refresh retry.
- On success: "Installed Minecode Language Servers. Restart minecode to
  activate."; the five extensions appear in the installed list after refresh.

### Wiring and version

- `src/tui/extensionsViewHost.zig` creates the gallery service with
  `workbench.async_io`, `&workbench.window_events`, `extensions_service`, and
  `user_location`; deinit in `detach`.
- Add `-Dversion` (default `0.0.0-dev`) to app/test build options; `--version`
  output; release workflow passes the tag version.
- Default index URL is built from the compiled version;
  `MINECODE_EXTENSIONS_GALLERY` overrides it for forks/tests.
- If no user extensions directory or no async Io, browse reports unavailable;
  installed list still works.

## Core slimming

- Split `host/build-builtin-extensions.js` into:
  - `host/dist/extensions` (core)
  - `host/dist/language-servers` (five + SDK)
- Add `--core-only` / `--language-servers-only` and clean each output
  directory.
- Add `-Doptional-language-servers=true` to `build.zig`:
  - skip the five manifests from `share/minecode/extensions`;
  - install only core extensions into `lib/minecode/extensions`;
  - skip language-server dirs and SDK.
- `zig build host` uses `--core-only` in slim mode.
- Remove `typescript` from `host/runtime/package.json` and regenerate its
  lockfile; the SDK comes from the bundle and both TS and HTML resolve
  `extensions/node_modules/typescript`.
- Default dev builds remain full.

## Phase 2 (optional): Marketplace / Open VSX

Only if a publisher account is available:

- Build five child VSIXs under publisher `minecode`, not `vscode`:
  - `minecode.typescript-language-features`
  - `minecode.html-language-features`
  - `minecode.css-language-features`
  - `minecode.emmet`
  - `minecode.php-language-features`
- Patch the TypeScript extension's hardcoded
  `vscode.typescript-language-features` lookup and SDK path; place the SDK
  inside the VSIX (or bundle TypeScript into the HTML server so it does not need
  a sibling SDK).
- Include README, LICENSE, icon, repository metadata, and distinct display
  names.
- Build one **Extension Pack** `minecode.language-servers` with `extensionPack`
  listing the five child IDs and category `Extension Packs`. This is the only
  supported "one Marketplace listing installs several extensions" mechanism
  ([extension packs](https://code.visualstudio.com/api/references/extension-manifest#extension-pack)).
- Publish via GitHub Actions Trusted Publishing/OIDC with
  `npx @vscode/vsce publish --oidc`; do not rely on PATs after 2026-12-01.
- Marketplace policy risk: republishing Microsoft built-ins under a new
  publisher may be treated as duplicate/impersonation. Use clear fork
  names/licensing and do not imply Microsoft ownership.
- Open VSX is an alternative registry with a documented API and `ovsx`
  publishing
  ([docs](https://github.com/eclipse-openvsx/openvsx/wiki/Publishing-Extensions));
  it still uses extension packs, not a multi-extension VSIX.
- The minecode panel does **not** depend on Marketplace/Open VSX; it downloads
  the Phase 1 bundle. A registry-backed panel would be a separate integration.

## Tests and CI

- Bundle manifest/index parse and validation tests: version mismatch, missing
  payloads, duplicate IDs, invalid hashes.
- Install-flow test with a fake transport and a small fixture bundle zip:
  - installs all five fake extensions + SDK into a temp extensions dir;
  - verifies paths, rollback on failure, temp cleanup;
  - verifies scanner visibility.
- Zip path validation test (absolute/`..` entries).
- View test: one bundle row, available/installing/installed states, install
  action, error/loading.
- Update `src/tui/fixtures/workbench-palette.jsonl` for new commands.
- Python generator test with dummy extension dirs.
- Update `extensionHostAdapter.zig` and `ci.yml` paths from
  `host/dist/extensions/<language>` to `host/dist/language-servers/<language>`.
- Linux CI slim step: build slim core, assert five manifests/bundles absent,
  build bundle, validate index/zip hashes.
- Keep full `zig build test` and `zig build test-e2e` green.

## Documentation

- `README.md`: default release omits language servers; Extensions → Browse
  installs one "Minecode Language Servers" bundle; restart;
  `MINECODE_EXTENSIONS_GALLERY`; `lib` remains.
- New `docs/extension-gallery.md`: bundle/index schema, publishing,
  self-hosting, trust, install paths, limitations, Marketplace extension-pack
  appendix.
- `docs/extensions.md`: curated bundle, not a marketplace; no VSIX/marketplace
  in Phase 1.
- `docs/vscode-builtin-extension-status.md`: five language features are
  bundle-installed.
- `host/runtime/README.md`: TypeScript SDK comes from the bundle.
- Release notes: v0.2.0 assets, one bundle install, JSON core, size table,
  Marketplace caveats.

## Edge cases and failure modes

- Offline/404/version mismatch: error state; installed extensions still work.
- Hash/corrupt zip: abort before extraction; clean temp.
- Path traversal/symlink entries: reject.
- Partial existing install: fail with a clear "repair/remove" message; do not
  mix versions.
- SDK conflict: fail rather than overwrite a different
  `node_modules/typescript`.
- App exit/crash mid-install: dot-prefixed temp dirs ignored by the scanner;
  cleaned on next gallery init.
- Restart required before activation.
- Windows zip/path handling tested in CI.
- Node missing: install succeeds, servers cannot run; existing host-disabled
  behavior.
- No user extensions dir: gallery unavailable.
- Marketplace/Open VSX publishing is blocked until publisher credentials and
  policies exist.

## Acceptance criteria

1. Default slim release contains no five language bundles or SDK.
2. Extensions panel Browse shows **one** "Minecode Language Servers" item and
   fetches the version-specific index.
3. Installing downloads one bundle, installs five extension directories + SDK,
   and after restart provides TypeScript/HTML/CSS/Emmet/PHP features.
4. Hash/path/version validation and rollback tests fail closed.
5. Full dev build/test suite remains green; palette snapshot updated.
6. v0.2.0 publishes core archives plus the bundle/index; the index URL works.
7. Core archive ≤22 MB; `lib` extracted ≤50 MB.

## Non-goals

- No multi-extension VSIX; no wrapper merge of the five implementations.
- No general Marketplace/Open VSX integration in Phase 1; no Marketplace
  publishing without a publisher account and policy.
- No auto-update, uninstall, ratings, recommendations, or hot reload.
- No zero-`lib` build.
- JSON remains core.
