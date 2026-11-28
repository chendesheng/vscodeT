#!/usr/bin/env bash
# Package an installed minecode tree for a release.
#
# Usage: scripts/package-release.sh <version> <target> [output-dir]
#
# The executable resolves its runtime assets relative to its own directory:
#   <prefix>/bin/minecode
#   <prefix>/share/minecode/extensions   (built-in declarative catalog)
#   <prefix>/lib/minecode                (optional Node extension host)
# Keeping those directories together is required for the full editor.
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <version> <target> [output-dir]" >&2
    exit 2
fi

version=${1#v}
target=$2
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${3:-"$root/dist"}

case "$version" in
    ""|*[!A-Za-z0-9._-]*)
        echo "invalid version: $version" >&2
        exit 2
        ;;
esac
case "$target" in
    ""|*[!A-Za-z0-9._-]*)
        echo "invalid target: $target" >&2
        exit 2
        ;;
esac

stage_name="minecode-$version-$target"
stage="$out/$stage_name"

# Refuse to remove anything outside the requested output directory.
case "$stage" in
    "$out"/?*) ;;
    *)
        echo "refusing to stage outside $out: $stage" >&2
        exit 2
        ;;
esac

binary=""
for candidate in "$root/zig-out/bin/minecode" "$root/zig-out/bin/minecode.exe"; do
    if [ -f "$candidate" ]; then
        binary=$candidate
        break
    fi
done
if [ -z "$binary" ]; then
    echo "missing installed binary; run 'zig build' first" >&2
    exit 1
fi
if [ ! -d "$root/zig-out/share/minecode/extensions" ]; then
    echo "missing built-in extension catalog; run 'zig build' first" >&2
    exit 1
fi

rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/share" "$stage/lib" "$stage/licenses"

cp "$binary" "$stage/bin/$(basename -- "$binary")"
chmod 0755 "$stage/bin/$(basename -- "$binary")" 2>/dev/null || true

cp -R "$root/zig-out/share/minecode" "$stage/share/minecode"

lib_src="$root/zig-out/lib/minecode"
if [ -d "$lib_src" ]; then
    mkdir -p "$stage/lib/minecode"
    for item in extensionHost.mjs jsonServer.mjs render-math.mjs render-mermaid.mjs product.json extensions; do
        if [ -e "$lib_src/$item" ]; then
            cp -R "$lib_src/$item" "$stage/lib/minecode/$item"
        fi
    done
    for required in extensionHost.mjs jsonServer.mjs product.json extensions; do
        if [ ! -e "$stage/lib/minecode/$required" ]; then
            echo "missing Node runtime asset: $required; run 'zig build host' first" >&2
            exit 1
        fi
    done
    # Install only the runtime manifest. Build-only packages stay in
    # host/package.json and never enter the archive. Select the target's
    # optional native packages even when this runs on a cross-compiling host.
    npm_os=""
    npm_cpu=""
    case "$target" in
        linux-x86_64) npm_os=linux; npm_cpu=x64 ;;
        linux-aarch64-musl) npm_os=linux; npm_cpu=arm64 ;;
        macos-arm64) npm_os=darwin; npm_cpu=arm64 ;;
        windows-x86_64) npm_os=win32; npm_cpu=x64 ;;
    esac
    npm_args=(ci --omit=dev --ignore-scripts --no-audit --no-fund)
    if [ -n "$npm_os" ]; then npm_args+=("--os=$npm_os"); fi
    if [ -n "$npm_cpu" ]; then npm_args+=("--cpu=$npm_cpu"); fi
    runtime_tmp=$(mktemp -d)
    cp "$root/host/runtime/package.json" "$root/host/runtime/package-lock.json" "$runtime_tmp/"
    (cd "$runtime_tmp" && npm "${npm_args[@]}")
    mv "$runtime_tmp/node_modules" "$stage/lib/minecode/node_modules"
    rm -rf "$runtime_tmp"
fi

cp "$root/README.md" "$stage/README.md"
if [ -f "$root/THIRD_PARTY_NOTICES.md" ]; then
    cp "$root/THIRD_PARTY_NOTICES.md" "$stage/THIRD_PARTY_NOTICES.md"
fi
printf '%s\n' "$version" > "$stage/VERSION"

copy_license() {
    source=$1
    destination=$2
    if [ -f "$source" ]; then
        cp "$source" "$stage/licenses/$destination"
    fi
}
copy_license "$root/vscode/LICENSE.txt" "vscode-LICENSE.txt"
copy_license "$root/vscode-textmate/LICENSE.md" "vscode-textmate-LICENSE.md"
copy_license "$root/third_party/oniguruma/COPYING" "oniguruma-COPYING"

mkdir -p "$out"
archive_name=""
archive_path=""
if [ "${OS:-}" = "Windows_NT" ] && command -v 7z >/dev/null 2>&1; then
    archive_name="$stage_name.zip"
    archive_path="$out/$archive_name"
    rm -f "$archive_path"
    (cd "$out" && 7z a -tzip -mx=9 "$archive_name" "$stage_name" >/dev/null)
else
    archive_name="$stage_name.tar.gz"
    archive_path="$out/$archive_name"
    rm -f "$archive_path"
    tar -C "$out" -czf "$archive_path" "$stage_name"
fi

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$out" && sha256sum "$archive_name" > "$archive_name.sha256")
else
    (cd "$out" && shasum -a 256 "$archive_name" > "$archive_name.sha256")
fi

echo "packaged $archive_path"
echo "checksum $out/$archive_name.sha256"
