# Helix reference cassettes

Generated in GitHub Actions by the `record-cassettes` workflow from the pinned
`helix/` submodule plus `scripts/oracle/helix/record.patch`. The recording is
not built on developer machines.

Replay with:

```sh
zig build test-oracle-helix
```

The corpus covers ASCII documents, one or more seeded cursors, and final
`normal` or `insert` mode. Each cassette has a `height` (visible text rows,
default 12) and records the viewport as `scroll.top_line`/`scroll.left`. The
replay asserts text, mode, selection count, every raw anchor/head selection,
the cursor set and the scroll position. Cases cover text objects (brackets,
quotes, word/paragraph), surround add/delete/replace, multiple cursors,
scrolling (`Ctrl-d`/`Ctrl-u`, `Ctrl-f`/`Ctrl-b`, `z` view commands) and the
basic edit/motion surface.
