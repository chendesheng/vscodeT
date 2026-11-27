# Helix reference cassettes

Generated in GitHub Actions by the `record-cassettes` workflow from the pinned
`helix/` submodule plus `scripts/oracle/helix/record.patch`. The recording is
not built on developer machines.

Replay with:

```sh
zig build test-oracle
```

v1 covers ASCII documents, a single starting cursor, final `normal` mode, and
the selection count. Selection ranges and registers are recorded raw for a
follow-up but are not asserted yet.
