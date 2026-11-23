#!/usr/bin/env sh
# Fetch IosevkaTerm Nerd Font for the unkernel demo.
# The release is a large zip; only the Regular face and its license are kept.
set -eu

dest=${1:-"$PWD/.cache-nerd-font"}
regular="$dest/IosevkaTermNerdFont-Regular.ttf"

if [ -f "$regular" ]; then
  printf 'using %s\n' "$regular"
  exit 0
fi

url="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/IosevkaTerm.zip"
zip=/tmp/IosevkaTerm-nerd-font.zip

curl -fsSL "$url" -o "$zip"
mkdir -p "$dest"
unzip -j -o "$zip" \
  'IosevkaTermNerdFont-Regular.ttf' \
  'LICENSE.md' \
  -d "$dest"
printf 'installed %s\n' "$regular"
