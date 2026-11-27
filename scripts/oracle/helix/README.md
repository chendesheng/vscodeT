# Helix cassette recording

The Helix cassettes are generated in GitHub Actions from the pinned `helix/`
submodule plus `record.patch`. Do not build Helix locally.

- `PIN` — tag/commit the workflow verifies before applying the patch.
- `record.patch` — test-only patch: adds `mod record;` to the integration test
  and a `record_cassettes` test that reads `HELIX_ORACLE_IN` and writes
  reference states to `HELIX_ORACLE_OUT`.
- `.github/workflows/record-cassettes.yml` — applies the patch, runs the
  recorder, and uploads or checks the JSON.

To refresh the committed cassettes, run the workflow with `mode=record`,
download the `helix-cassettes` artifact, copy the JSON files into
`src/vs/editor/contrib/helix/test/data/oracle/`, regenerate the embedded index,
and run `zig build test-oracle`.
