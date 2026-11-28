const std = @import("std");

/// The package tests can run either from the repository root (`zig build
/// test`) or from `textmate/` (`cd textmate && zig build test`).
pub fn findTestCasesDir(allocator: std.mem.Allocator) ![]u8 {
    const io = std.testing.io;
    const candidates = [_][]const u8{ "test-cases", "textmate/test-cases" };
    for (candidates) |candidate| {
        if (std.Io.Dir.cwd().openDir(io, candidate, .{})) |dir| {
            dir.close(io);
            return allocator.dupe(u8, candidate);
        } else |_| {}
    }
    return error.TestCasesNotFound;
}
