#!/usr/bin/env bash
# Remove build-only and already-bundled Node packages from a staged release.
#
# The extension host and built-in extensions are esbuild bundles. Their
# build-time dependencies (esbuild, the telemetry/auth source trees, TypeScript
# tooling) do not need to ship in lib/minecode/node_modules. This script runs
# only on the staged release copy, never on host/node_modules itself.
set -euo pipefail

prefix=${1:?usage: prune-release-runtime.sh <prefix>}
modules="$prefix/lib/minecode/node_modules"
if [ ! -d "$modules" ]; then
    echo "missing Node runtime: $modules" >&2
    exit 1
fi

case "$modules" in
    */lib/minecode/node_modules) ;;
    *)
        echo "refusing to prune unexpected path: $modules" >&2
        exit 2
        ;;
esac

remove=(
    # esbuild is only the bundler for host/dist and host/dist/extensions.
    esbuild
    @esbuild
    # Bundled into the extension host/extensions; only used while bundling.
    @microsoft
    @azure
    @nevware21
    @vscode/extension-telemetry
    @vscode/emmet-helper
    emmet
    @emmetio
    tas-client
    vscode-tas-client
    # Type declarations and npm bin shims are not loaded at runtime.
    @types
    .bin
)
for package in "${remove[@]}"; do
    rm -rf "$modules/$package"
done

# Fail the release rather than ship a runtime that is missing something the
# extension host, JSON server, renderers or built-in extensions load by name.
required=(
    @vscode/proxy-agent
    @vscode/ripgrep
    @vscode/spdlog
    beautiful-mermaid
    elkjs
    esprima
    katex
    parse5
    socks-proxy-agent
    typescript
    undici
)
for package in "${required[@]}"; do
    if [ ! -e "$modules/$package" ]; then
        echo "pruned runtime is missing required package: $package" >&2
        exit 1
    fi
done
