#!/bin/sh
# Create the developer-only virtualenv used by the Neovim recorder.
# This does not build Helix; the Helix recorder runs in GitHub Actions.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
venv="$root/scripts/oracle/.venv"
if ! command -v "${NVIM:-nvim}" >/dev/null 2>&1; then
    echo "warning: ${NVIM:-nvim} is not on PATH; the recorder will need --nvim or a pinned install" >&2
fi
if [ ! -x "$venv/bin/python" ]; then
    python3 -m venv --without-pip "$venv"
fi
if [ ! -x "$venv/bin/pip" ]; then
    curl -sSL -o "$venv/get-pip.py" https://bootstrap.pypa.io/get-pip.py
    "$venv/bin/python" "$venv/get-pip.py"
    rm -f "$venv/get-pip.py"
fi
"$venv/bin/pip" install -q -r "$root/scripts/oracle/requirements.txt"
echo "ready: $venv/bin/python scripts/oracle/record_nvim.py --all"
