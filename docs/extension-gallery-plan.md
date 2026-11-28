# Extension gallery plan: Theia/Open VSX language servers

**Status:** proposed, not implemented.

## What we found

[`eclipse-theia/vscode-builtin-extensions`](https://github.com/eclipse-theia/vscode-builtin-extensions)
already builds and publishes standalone VSIXs for VS Code's built-in
extensions:

- It builds from the MIT-licensed VS Code tree and makes the packages
  self-contained for use outside the VS Code family.
- It patches the TypeScript extension's hard-coded `../node_modules` lookup and
  ships the SDK inside the VSIX (`deps/typescript`); the HTML VSIX likewise
  contains its `server/node_modules/typescript`.
- It publishes the built-ins to Open VSX under the `vscode` namespace:
  <https://www.open-vsx.org/namespace/vscode>.
- It also publishes GitHub release assets. The latest GitHub release at the
  time of writing is **1.108.2**; the latest Open VSX versions of these five
  extensions are **1.95.3**.

This means the gallery does **not** need to build, bundle, or publish its own
language-server packages. The Extensions panel can download the existing
`vscode.*` VSIXs and install them into the user extensions directory.

## Marketplace answer

Theia already publishes these extensions to **Open VSX**, so uploading them to
the VS Code Marketplace is unnecessary for minecode's panel.

Publishing to the **VS Code Marketplace** would still not be possible as one
VSIX containing five extensions:

- A VSIX installs one extension directory.
- The supported "one listing installs several extensions" mechanism is an
  Extension Pack, which references five separately published child extensions.
- The `vscode` publisher cannot be reused. Republishing under a new publisher
  requires patching the TypeScript extension's ID/SDK path, Marketplace
  publisher setup, and carries a duplicate/impersonation policy risk.
- PAT-based Marketplace publishing is retiring on 2026-12-01; GitHub Actions
  Trusted Publishing/OIDC is the replacement.

Not needed for this plan unless a separate Marketplace distribution is
requested later.

## Goal and success criteria

- Default release has no TS/HTML/CSS/Emmet/PHP bundles and no TypeScript SDK.
- Extensions panel shows **one** "Minecode Language Servers" item.
- Installing it downloads the five standalone VSIXs from Open VSX, verifies
  them, and installs them into the user extensions directory.
- After restart, TypeScript/HTML/CSS/Emmet/PHP work as they do today.
- Core archive target: **~18–21 MB** (from 29.3 MB).
- `lib/minecode` shrinks to ~47 MB extracted, but is not eliminated.
- Full dev builds/tests remain full.

## Compatibility gate (critical)

Open VSX's latest versions are **1.95.3**, and Theia's newest GitHub release is
**1.108.2**; the minecode VS Code pin is **1.147.0**. The extension engines are
older (`^1.30`, `^1.77`, etc.), so backward compatibility is expected, but this
must be proven before adopting the plan.

Add a CI compatibility lane:

1. Download the five `vscode.*` VSIXs from Open VSX **1.95.3**.
2. Install them into a temporary extensions directory.
3. Run the existing TypeScript diagnostics, CSS/HTML completion and Emmet
   tests against those installed extensions.
4. If they pass, use Open VSX 1.95.3 as the default gallery source.
5. If they fail, repeat with Theia's GitHub release **1.108.2** assets.
6. If both fail, build Theia's packaging from the minecode `vscode` pin
   (`1.147.0`) and host the resulting five VSIXs as a pinned release asset.
   That is the fallback, not the default.

A version mismatch or unsupported extension API must be reported as a
compatibility failure, not silently installed.

## Phase 1: Open VSX gallery

### Source

Use the Open VSX APIs for these five extension IDs:

- `vscode.typescript-language-features`
- `vscode.html-language-features`
- `vscode.css-language-features`
- `vscode.emmet`
- `vscode.php-language-features`

Metadata endpoint:

```text
https://open-vsx.org/api/vscode/<name>
```

Relevant fields: `version`, `displayName`, `description`, `engines`,
`files.download`, `files.sha256`, `files.signature`, `timestamp`.

Pin the accepted version range (initial: `1.95.3`) so a registry-side update
cannot silently change behavior. Cache metadata for the session.

### Gallery service

Add a gallery service under the Extensions contribution:

- `common/extensionGallery.zig`: Open VSX metadata schema, validation,
  `GalleryEntry`, `IGallery` interface.
- `browser/extensionGalleryService.zig` (or `node/`): concrete service with
  `RequestService`, async install jobs, and `on_change`.

Responsibilities:

- Fetch the five extension metadata records asynchronously.
- Expose one bundle-like row "Minecode Language Servers" with the combined
  size/version.
- Download each VSIX, verify the SHA-256 from Open VSX, reject oversized
  bodies.
- Extract each VSIX with `std.zip.extract` into a dot-prefixed temp directory.
  VSIXs place the extension under `extension/`; move that payload to
  `<extensions>/<publisher>.<name>-<version>`.
- Validate `package.json` ID/version and the expected extension ID.
- Preflight all five destinations; fail on partial/conflicting installs rather
  than mixing versions.
- Move all five into place and roll back already-moved directories if a later
  move fails.
- Call `ExtensionsWorkbenchService.refresh()` and emit a restart notice.
- Cancel jobs and clean temp dirs on deinit.

No shared TypeScript SDK dependency is needed: the Theia VSIXs include it
inside the TypeScript and HTML packages.

`ExtensionsWorkbenchService` gets a `userLocation()` getter. Reuse the existing
`markdownPreview.zig` worker/`dispatch.Task` pattern for async completion.

### Panel UI

Add an installed/available mode to `ExtensionsListView`:

- Title actions: **Browse Extensions** and **Installed**, plus Refresh.
- Register matching commands
  (`workbench.extensions.action.showAvailableExtensions`,
  `workbench.extensions.action.showInstalledExtensions`); update the
  command-palette snapshot fixture.
- Browse mode fetches the Open VSX metadata on first entry/Refresh; placeholder
  "Search Available Extensions".
- One row: "Minecode Language Servers", detail `Available · <size>` or
  `Installing…` or `Installed`.
- Installed state is true when all five `vscode.*` IDs are found in the local
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
  output.
- `MINECODE_EXTENSIONS_GALLERY` overrides the Open VSX base URL for forks/tests.
- If no user extensions directory or no async Io, browse reports unavailable;
  installed list still works.

## Core slimming

- Split `host/build-builtin-extensions.js` into:
  - `host/dist/extensions` (core)
  - `host/dist/language-servers` (kept for full dev/tests)
- Add `--core-only` / `--language-servers-only` and clean each output
  directory.
- Add `-Doptional-language-servers=true` to `build.zig`:
  - skip the five manifests from `share/minecode/extensions`;
  - install only core extensions into `lib/minecode/extensions`;
  - skip language-server dirs and SDK.
- `zig build host` uses `--core-only` in slim mode.
- Remove `typescript` from `host/runtime/package.json` and regenerate its
  lockfile; the gallery VSIXs carry their own SDK.
- Default dev builds remain full.

## Tests and CI

- Open VSX metadata parse/validation tests: version pin, missing fields,
  invalid hash, network errors.
- Install-flow test with a fake transport and small fixture VSIXs:
  - installs five fake VSIX payloads into a temp extensions dir;
  - verifies `extension/` prefix handling, package.json validation, rollback,
    temp cleanup;
  - verifies scanner visibility.
- VSIX path validation test (absolute/`..` entries).
- View test: one row, available/installing/installed states, install action,
  error/loading.
- Update `src/tui/fixtures/workbench-palette.jsonl` for new commands.
- Compatibility lane described above, using real Open VSX 1.95.3 VSIXs.
- Update `extensionHostAdapter.zig` and `ci.yml` paths from
  `host/dist/extensions/<language>` to `host/dist/language-servers/<language>`.
- Linux CI slim step: build slim core, assert five manifests/bundles absent.
- Keep full `zig build test` and `zig build test-e2e` green.

## Documentation

- `README.md`: default release omits language servers; Extensions → Browse
  installs one "Minecode Language Servers" item from Open VSX; restart;
  compatibility note; `lib` remains.
- `docs/extensions.md`: the gallery consumes Theia's standalone Open VSX
  built-ins; no minecode-published language packages.
- `docs/vscode-builtin-extension-status.md`: five language features are
  gallery-installed from Open VSX.
- `host/runtime/README.md`: TypeScript SDK comes from the gallery VSIXs.
- Release notes: v0.2.0 assets, one-row install, JSON core, Open VSX source and
  version pin.

## Edge cases and failure modes

- Open VSX offline/404/version mismatch: error state; installed extensions
  still work.
- Hash/corrupt VSIX: abort before extraction; clean temp.
- VSIX `extension/` prefix missing or multiple top-level roots: reject.
- Path traversal/symlink entries: reject.
- Partial existing install: fail with a clear "repair/remove" message; do not
  mix versions.
- App exit/crash mid-install: dot-prefixed temp dirs ignored by the scanner;
  cleaned on next gallery init.
- Restart required before activation.
- Windows zip/path handling tested in CI.
- Node missing: install succeeds, servers cannot run; existing host-disabled
  behavior.
- No user extensions dir: gallery unavailable.
- Older Open VSX versions incompatible with the 1.147.0 host: fall back to
  Theia 1.108.2, then to a locally built 1.147.0 VSIX set.

## Acceptance criteria

1. Default slim release contains no five language bundles or SDK.
2. Extensions panel Browse shows **one** "Minecode Language Servers" item and
   fetches Open VSX metadata.
3. Installing downloads five VSIXs, installs them, and after restart provides
   TypeScript/HTML/CSS/Emmet/PHP features.
4. Compatibility lane passes with the pinned Open VSX version (or the chosen
   fallback).
5. Hash/path/version validation and rollback tests fail closed.
6. Full dev build/test suite remains green; palette snapshot updated.
7. Core archive ≤22 MB; `lib` extracted ≤50 MB.

## Non-goals

- No minecode-built or minecode-published language-server bundle.
- No Marketplace publishing; Theia already publishes to Open VSX.
- No multi-extension VSIX; no wrapper merge of the five implementations.
- No auto-update, uninstall, ratings, recommendations, or hot reload.
- No zero-`lib` build.
- JSON remains core.
