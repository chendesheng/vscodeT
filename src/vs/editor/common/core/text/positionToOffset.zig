// Port of `src/vs/editor/common/core/text/positionToOffset.ts`.
//
// Upstream uses this module to re-export `PositionOffsetTransformer` from
// `positionToOffsetImpl.ts` and to break a circular dependency. Zig resolves
// the import graph statically, so the re-export is all that remains here.

pub const PositionOffsetTransformer = @import("positionToOffsetImpl.zig").PositionOffsetTransformer;
pub const PositionOffsetTransformerBase = @import("positionToOffsetImpl.zig").PositionOffsetTransformerBase;

/// Upstream calls this to install `Deps`; Zig imports the modules directly.
pub fn ensureDependenciesAreSet() void {}

test "positionToOffset re-exports the implementation" {
    try std.testing.expect(PositionOffsetTransformer == @import("positionToOffsetImpl.zig").PositionOffsetTransformer);
}

const std = @import("std");
