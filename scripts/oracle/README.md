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

Filenames must be lowercase ASCII (`a-z`, `0-9`, `_`, plus `.json`) so they
work on case-insensitive macOS and Windows filesystems. Distinguish uppercase
key cases with names such as `append_upper_a.json`, while keeping the original
case-sensitive `case` ID (`append_A`) and key tokens (`A`) unchanged.
The Neovim recorder accepts the original ID or the portable filename stem;
both recorders preserve the input filename in their output.

Adding or removing a cassette requires regenerating the embedded index:

```sh
python3 scripts/oracle/generate_cassette_index.py
python3 scripts/oracle/generate_cassette_index.py --check
```

The index check validates the Git index as well as the directory, so it rejects
case aliases even if a case-insensitive checkout hides one of them.

The corpus is a curated set plus generated coverage variants (343 Vim and 207
Helix cassettes). `zig build test-oracle-helix` and
`zig build test-oracle-vim` run the per-engine lanes; `zig build test-oracle`
runs both. The replay asserts every recorded field: text, mode, selection
count, the raw anchor/head `selections` ranges, the cursor set and the viewport
`scroll.top_line`/`scroll.left` (plus `height`, the visible text rows). The
cursor is the reference's `Range::cursor()` value (previous grapheme of a
forward head, otherwise the head), and seeds use the reference's one-grapheme
ranges. The Neovim recorder sizes its window from `height`/`width` and captures
`winsaveview()` after a redraw; the Helix recorder sizes its inner viewport
from `height`. Both lanes are green (343 Vim and 207 Helix) and gate CI in
their own jobs. Cases are not removed or weakened to make either lane green.

## CI cost and limits

The Helix job is a manual/background GitHub Actions build of the pinned
submodule. It caches cargo and Helix `target/`; cold builds are the expensive
case. Standard runners are free for public repositories, subject to GitHub's
concurrency, 6-hour job, 10 GB cache, and artifact-storage limits. Artifacts
are kept for seven days. Cassettes are committed to the repository; the CI
cache is only a build accelerator, never the source of truth.
