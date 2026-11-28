# minecode browser workbench

Live: <https://chendesheng.github.io/minecode/>

The demo boots a real Linux kernel using unkernel and runs the **native**
aarch64 minecode executable on a pty. Ghostty (`ghostty-web`) renders the
terminal in the browser. No editor-only WebAssembly build is needed.

The Pages workflow builds minecode with:

```sh
git submodule update --init --depth 1 vscode vscode-textmate third_party/oniguruma
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall -Donig-static=true
```

It prepares `zig-out/pages` with the static page, native executable, pinned
Ghostty bundle, unkernel SDK and Alpine image, and the IosevkaTerm Nerd Font.
See [the Pages workflow](../.github/workflows/pages.yml) for the asset staging
commands. Serve that complete directory over HTTP to run the demo locally:

```sh
python3 -m http.server -d zig-out/pages 8000
```

The Ghostty browser bundle is not checked in. The fetch script verifies the
pinned npm tarball and every extracted file against
[`ghostty-web.lock.json`](ghostty-web.lock.json). All page URLs are relative,
so the same assets work under a GitHub Pages project path.

The demo includes the native workbench shell, tabs, quick open, file watcher,
threading and integrated terminal. Git and the Node extension host are not
included in the browser image. The former `/unkernel/` URL redirects to the
Pages root.
