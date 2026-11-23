# Oniguruma wasm configuration and provenance

The Oniguruma regular-expression library used by the WebAssembly editor build
is the git submodule at `third_party/oniguruma`, not a vendored copy.

- Upstream: https://github.com/kkos/oniguruma
- Pin: tag `v6.9.10`, commit `4ef89209a239c1aea328cf13c05a2807e5c146d1`
- License: BSD-2-Clause (see `third_party/oniguruma/COPYING`)
- Initialization: `git submodule update --init --depth 1 third_party/oniguruma`
  (also included in `git submodule update --init --depth 1`)

The native TUI build is unchanged: it still uses the system `libonig` (or the
`-Donig-include`/`-Donig-lib` paths). Only the wasm build compiles the
submodule sources. The source list is in `build.zig` (`onig_wasm_sources`);
helper/tool sources such as `mktable.c` and the POSIX/Windows shims are not
compiled.

## Why a separate config directory

The submodule is kept exactly at upstream and is not modified. Oniguruma's C
sources include `"config.h"`, which upstream generates with CMake/autotools and
does not commit. This directory supplies the hand-written wasm32-wasi
`config.h`:

- ILP32: `int`, `long` and `void*` are 4 bytes.
- `time_t` is 8 bytes.
- The `HAVE_*` probes match wasi-libc.

`build.zig` adds `third_party/oniguruma-config` to the include path before the
submodule directories, so the wasm build picks this file and the submodule
stays clean.

`src/support/onigurumaBindings.zig` is the checked-in `zig translate-c` output
used by the wasm build, so a cold build does not need a system `oniguruma.h` or
a slow translator run. It is ABI-compatible with the 6.9.10 library.

## Updating the pin

1. Update the submodule to the new tag/commit.
2. Recheck `onig_wasm_sources` in `build.zig` if upstream added a source.
3. Regenerate `src/support/onigurumaBindings.zig` if the public header changed.
4. Run `zig build wasm -Doptimize=ReleaseSmall -Dwasm-only=true` and
   `zig build wasm-smoke`.
