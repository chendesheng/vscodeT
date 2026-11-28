# Open VSX extensions and slim releases

**Status:** implemented for the four qualified language-feature extensions.

## Decision

Use the existing Extensions workbench and Open VSX gallery, not a separate
Minecode gallery, repackaged VSIXs, release bundle, or version-specific index.
The pinned VS Code 1.147.0 tree remains the specification for the editor, host
and deterministic development integration tests. A downloaded extension is a
normal user installation; its version need not equal the host's version.

## Intentional difference from upstream VS Code

The registry transport is a product-specific adaptation, not a change to the
extension-management architecture. Open VSX's VS Code-compatible
`extensionquery` does not expose the qualified `vscode.*` extensions, whereas
its [native API](https://open-vsx.org/swagger-ui/index.html) does. Minecode
uses native `/api/-/search` for ordinary searches and `/api/v2/-/query` for
exact identifiers and version metadata. Native responses are normalized to
the same gallery models, version selection, asset and installer contracts.
Search summaries are resolved to full version metadata before installation.
The compatible query transport is retained for custom compatible galleries
and criteria not provided by native search (exact tags, multiple categories,
and sorting by name, publisher or publication date).

## Product isolation

Minecode defaults to `~/.minecode/extensions`. The existing directory
resolution order is `--extensions-dir`, `MINECODE_EXTENSIONS`,
`MINECODE_PORTABLE/extensions`, then the product default. Portable mode also
uses `MINECODE_PORTABLE/user-data`. The old VS Code extension and portable
variables are ignored. Existing VS Code extensions and their `extensions.json`
profile are not migrated, updated or removed. Explicit overrides can still
select another directory. VS Code user and workspace settings remain compatible.

## Release inventory

`src/vs/platform/product/common/galleryExtensions.txt` is the shared inventory of omitted packages.
Open Extensions (`Ctrl-Shift-X`) and search for the exact extension ID using
`@id:<id>`, then Install the compatible release from Open VSX.

| Extension | Qualified Open VSX version | Release disposition |
| --- | --- | --- |
| [`vscode.typescript-language-features`](https://open-vsx.org/extension/vscode/typescript-language-features) | 1.95.3 | Download on demand; VSIX includes `deps/typescript` |
| [`vscode.html-language-features`](https://open-vsx.org/extension/vscode/html-language-features) | 1.95.3 | Download on demand; VSIX includes the HTML server's TypeScript SDK |
| [`vscode.css-language-features`](https://open-vsx.org/extension/vscode/css-language-features) | 1.95.3 | Download on demand |
| [`vscode.emmet`](https://open-vsx.org/extension/vscode/emmet) | 1.95.3 | Download on demand |
| `vscode.php-language-features` | 1.95.3 | Keep the pinned bundle: the gallery package declares `engines.vscode: 0.10.0` and fails the normal compatibility check |
| Terminal Suggest, auth, Git Base, task providers, configuration/extension editing, Merge Conflict, Search Result, Simple Browser, custom Copilot adapter | — | Keep current bundled integration; not part of this qualification |

The gallery selects compatible versions using its existing engine, target
platform and channel checks. The values above describe the tested packages,
not a hard-coded version restriction. New versions still need runtime
compatibility testing; older packages need not expose every feature of the
pinned tree. Do not bypass API proposal or engine validation to make an
incompatible package install.

The JSON language server remains core. Declarative language basics, grammars,
language configurations, snippets, themes and icons remain bundled, so normal
syntax highlighting and editing work before any gallery downloads. The omitted
language-feature manifests must also be absent from the system catalog: a
newer pinned system manifest with the same ID would shadow an older downloaded
user extension. All four are npm/Node-based user extensions, not native ports.

## Build and package

- Full development `zig build`, `zig build host` and CI retain the pinned
  fixtures in `host/dist/extensions` and their TypeScript SDK. CI does not
  depend on a live registry to run the native interoperability suite.
- Releases use `-Dgallery-extensions=true` for both the native install and
  `zig build host json-server`. The manifest catalog omits the inventory;
  `node host/build-builtin-extensions.js --gallery-extensions` builds only
  retained runtime extensions into a separate `host/dist/gallery-release-extensions`
  tree. The ordinary development output is untouched.
- `scripts/package-release.sh` excludes those directories and the shared
  TypeScript SDK from release staging even if an older full install is used.
  `host/runtime/package.json` no longer includes TypeScript. The TypeScript
  and HTML gallery packages own their SDKs independently.
- The release workflow checks that the omitted manifests, bundles and shared
  SDK are absent before packaging. Retained runtime features, the pinned Node
  host and JSON server remain in `lib/minecode`. All release targets use the
  same policy.

For a local slim install, use a fresh prefix to avoid stale artifacts:

```sh
zig build -Dgallery-extensions=true --prefix /tmp/minecode-slim
zig build host json-server -Dgallery-extensions=true --prefix /tmp/minecode-slim
MINECODE_INSTALL_ROOT=/tmp/minecode-slim scripts/package-release.sh 0.0.0-dev macos-arm64
```

## Verification

- Normal native CI continues to exercise the complete pinned development
  fixture suite on Linux, macOS and Windows.
- Optional gallery qualification uses the existing E2E fixture assertions
  rather than new mocks. Download the selected VSIXs, extract each `extension/`
  payload into a directory named after the extension (without the publisher),
  and run:

  ```sh
  MINECODE_E2E_GALLERY_EXTENSIONS=/path/to/unpacked/extensions \
    zig build test-e2e -De2e-progress=true --summary all
  ```

  The selected four packages are activated as user extensions; other tests
  still use pinned fixtures. Missing selected manifests fail the tests.
- On macOS, native registry searches found both `vscode.emmet` and
  `ms-python.python`; all four Open VSX 1.95.3 packages installed directly
  through the gallery with signature verification enabled in an isolated
  profile. The full qualification E2E run passed
  31 tests (two opt-in real ZLS tests skipped), including TypeScript diagnostics,
  completion, hover and formatting, JavaScript diagnostics, CSS and HTML
  completion, and Emmet expansion. The Open VSX payloads themselves have not
  yet been qualified on Linux or Windows.
- The macOS arm64 ReleaseSmall package was approximately 16.94 MiB, with
  the four optional features and shared TypeScript SDK absent and the
  retained system extensions, Node host and JSON server present.

No custom VSIX builder, publishing workflow, gallery index, or alternate
extension-management service is needed.
