# Runtime Node dependencies

`host/package.json` installs everything needed to **build** the pinned Node
extension host and its bundled extensions. `host/runtime/package.json` is the
smaller set that the released binary installs beside `lib/minecode/extensionHost.mjs`.

Release packaging runs:

```sh
npm ci --omit=dev --ignore-scripts
```

from this directory into the staged `lib/minecode`. Packages that only exist to
bundle `host/dist` or `host/dist/extensions` are deliberately absent:

- `esbuild` and `@esbuild/*` are the bundler.
- `@microsoft/*`, `@azure/*`, `@nevware21/*`, `@vscode/extension-telemetry` and
  `vscode-tas-client` are build inputs for bundled telemetry/authentication
  code. The native MSAL binaries are copied into the authentication extension.
- `@vscode/emmet-helper`, `emmet` and `@emmetio/*` are bundled into the pinned
  development Emmet fixture.
- `typescript` is a development build input; the released TypeScript and
  HTML language-feature packages are user downloads from Open VSX with their
  own SDKs. The shared TypeScript SDK is not installed in the archive.

Keep the runtime package versions in sync with the corresponding versions in
`host/package.json`, then regenerate this directory's `package-lock.json` with
`npm install --package-lock-only --ignore-scripts`.
