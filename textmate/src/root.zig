//! Zig port of `microsoft/vscode-textmate` 9.3.2.
//!
//! The reference checkout lives at `../vscode-textmate`. Each module keeps the
//! upstream file name and the behavioral contract of its TypeScript source;
//! deliberate Zig adaptations are documented in the module header.
//!
//! This package is standalone: it must not import from `src/`. The editor keeps
//! using the pinned `textmate.zig` dependency until the port is complete.
pub const matcher = @import("matcher.zig");

test {
    _ = matcher;
    _ = @import("matcher.test.zig");
}
