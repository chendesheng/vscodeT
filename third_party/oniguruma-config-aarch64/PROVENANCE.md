# Oniguruma aarch64 musl config

The Oniguruma source is the `third_party/oniguruma` submodule. This directory
only supplies the build-time `config.h` for cross-compiling the library for
`aarch64-linux-musl` (LP64, 64-bit `time_t`). The wasm ILP32 config lives in
`../oniguruma-config/`.
