# Third-party notices

minecode is a Zig port of Visual Studio Code's editor, platform and workbench.
Release archives include data and code from the projects below. The bundled
`licenses/` directory contains the upstream license texts where the source tree
provides them.

## Visual Studio Code

- Project: <https://github.com/microsoft/vscode>
- License: MIT (see `licenses/vscode-LICENSE.txt`)
- Use: pinned editor/workbench sources, built-in extension manifests,
  language grammars and theme assets. The `vscode/` submodule is not modified.

## vscode-textmate

- Project: <https://github.com/microsoft/vscode-textmate>
- License: MIT (see `licenses/vscode-textmate-LICENSE.md`)
- Use: upstream grammar/tokenization test fixtures and behavior reference.
  The Zig port itself lives in `textmate/`.

## Oniguruma

- Project: <https://github.com/kkos/oniguruma>
- License: BSD-2-Clause (see `licenses/oniguruma-COPYING`)
- Use: regular-expression engine linked statically into release binaries when
  they are built with `-Donig-static=true`.

## Ghostty / libghostty-vt

- Project: <https://github.com/ghostty-org/ghostty>
- License: MIT
- Use: terminal emulation engine in the integrated terminal and browser demo.
  The license text is in the fetched `ghostty` Zig dependency.

## Node extension host dependencies

Release archives that include `lib/minecode/node_modules` also include the npm
packages required by the pinned Node extension host. Their license files are
preserved in the installed packages under `node_modules`.
