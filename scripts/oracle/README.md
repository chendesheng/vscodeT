# Reference cassette recordings

The native Vim and Helix engines are replayed against recordings made from
reference editors. The recordings are committed JSON; replay needs no
reference binary and runs in `zig build test`.

## Vim lane (Neovim)

Recorded locally from Neovim over `--embed`:

```sh
scripts/oracle/setup.sh
scripts/oracle/.venv/bin/python scripts/oracle/record_nvim.py --all
scripts/oracle/.venv/bin/python scripts/oracle/record_nvim.py --check --all
```

`setup.sh` creates a developer-only virtualenv and installs `pynvim`; it does
not install or build Helix. Use `--nvim <path>` to select a specific Neovim
binary. The pinned release is in `nvim/PIN` (`v0.10.4`). `--out <dir>` writes
recorded files elsewhere; `--force` re-records even when states already exist.

CI also records/checks this lane with the same pinned Neovim:
`.github/workflows/record-cassettes.yml`.

## Helix lane (GitHub Actions only)

Helix has no embeddable RPC. The `helix/` submodule is pinned to `25.07.1`
(`helix/PIN`); the workflow applies the test-only `helix/record.patch` to a
disposable checkout and runs a `record_cassettes` integration test from
Helix's own harness. **Do not build Helix locally.**

```sh
gh workflow run record-cassettes.yml -f mode=check -f target=helix
gh workflow run record-cassettes.yml -f mode=record -f target=helix
```

`record` uploads a `helix-cassettes` artifact. Download it, copy the JSON into
`src/vs/editor/contrib/helix/test/data/oracle/`, then run:

```sh
python3 scripts/oracle/generate_cassette_index.py
zig build test-oracle
```

`check` compares a fresh recording with the committed files and fails on
drift. Pushes touching `scripts/oracle/**`, the cassette data, or the `helix`
submodule run `check` automatically.

## Cassette format

One JSON file per case (see either `test/data/oracle/README.md`):
seed text/cursor, key tokens, and reference states. The Zig replay tests live
in the engines' `test/browser/*Cassette.test.zig` files; the shared parser is
`src/vs/editor/test/common/oracleCassette.zig`.

Adding or removing a cassette requires regenerating the embedded index:

```sh
python3 scripts/oracle/generate_cassette_index.py
```

v1 compares text, cursor, final mode, and (Helix) selection count. A cassette
may set `"assert_cursor": false` with a `"cursor_gap"` explanation when the
reference cursor representation does not map onto the native engine yet; text,
mode and selection count are still asserted. Vim visual ranges, Helix selection
ranges, and registers are recorded where easy but are not asserted yet.
Unicode, tabs, soft wrap, prompts, and tree-sitter text objects are outside the
first corpus.

## CI cost and limits

The Helix job is a manual/background GitHub Actions build of the pinned
submodule. It caches cargo and Helix `target/`; cold builds are the expensive
case. Standard runners are free for public repositories, subject to GitHub's
concurrency, 6-hour job, 10 GB cache, and artifact-storage limits. Artifacts
are kept for seven days. Cassettes are committed to the repository; the CI
cache is only a build accelerator, never the source of truth.
