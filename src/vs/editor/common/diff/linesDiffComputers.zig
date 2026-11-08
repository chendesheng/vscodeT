// Port of `src/vs/editor/common/diff/linesDiffComputers.ts`.
//
// The external (`@vscode/diff`) computers are not ported; `getAdvancedExternal`
// and `getAdvancedWasm` would require a WebAssembly build of that package.
const std = @import("std");
const Allocator = std.mem.Allocator;

const legacy = @import("legacyLinesDiffComputer.zig");
const default_computer = @import("defaultLinesDiffComputer/defaultLinesDiffComputer.zig");
const lines_diff_computer = @import("linesDiffComputer.zig");

pub const LegacyLinesDiffComputer = legacy.LegacyLinesDiffComputer;
pub const DefaultLinesDiffComputer = default_computer.DefaultLinesDiffComputer;
pub const ILinesDiffComputer = lines_diff_computer.ILinesDiffComputer;
pub const ILinesDiffComputerOptions = lines_diff_computer.ILinesDiffComputerOptions;
pub const LinesDiff = lines_diff_computer.LinesDiff;

/// The name of a diff algorithm. Upstream declares this type in
/// `services/editorWorker.ts`; it lives here until that module is ported.
pub const DiffAlgorithmName = enum {
    legacy,
    advanced,
    advanced_external,
    advanced_wasm,

    pub fn isPackage(self: DiffAlgorithmName) bool {
        return self == .advanced_external or self == .advanced_wasm;
    }

    /// Parses the upstream spelling, e.g. `"advanced-external"`.
    pub fn fromName(name: []const u8) ?DiffAlgorithmName {
        if (std.mem.eql(u8, name, "legacy")) return .legacy;
        if (std.mem.eql(u8, name, "advanced")) return .advanced;
        if (std.mem.eql(u8, name, "advanced-external")) return .advanced_external;
        if (std.mem.eql(u8, name, "advanced-wasm")) return .advanced_wasm;
        return null;
    }
};

pub fn getLegacy() LegacyLinesDiffComputer {
    return .{};
}

pub fn getDefault() DefaultLinesDiffComputer {
    return DefaultLinesDiffComputer.init();
}

/// Returns the built-in computer for an algorithm, or `null` when the
/// algorithm is provided by the external `@vscode/diff` package.
pub fn getBuiltin(algorithm: DiffAlgorithmName) ?ILinesDiffComputer {
    switch (algorithm) {
        .legacy => return legacy_builtin.asLinesDiffComputer(),
        .advanced => return default_builtin.asLinesDiffComputer(),
        .advanced_external, .advanced_wasm => return null,
    }
}

/// Stateless instances backing `getBuiltin`. They exist so that the returned
/// interface has a stable context pointer.
var legacy_builtin = LegacyLinesDiffComputer{};
var default_builtin = DefaultLinesDiffComputer{};

test "DiffAlgorithmName" {
    try std.testing.expect(DiffAlgorithmName.advanced_external.isPackage());
    try std.testing.expect(DiffAlgorithmName.advanced_wasm.isPackage());
    try std.testing.expect(!DiffAlgorithmName.legacy.isPackage());
    try std.testing.expectEqual(DiffAlgorithmName.legacy, DiffAlgorithmName.fromName("legacy").?);
    try std.testing.expectEqual(@as(?DiffAlgorithmName, null), DiffAlgorithmName.fromName("nope"));
}

test "getBuiltin computes a diff" {
    const allocator = std.testing.allocator;
    var builtin_computer = getDefault();
    const computer = builtin_computer.asLinesDiffComputer();
    const original = [_][]const u8{ "a", "b" };
    const modified = [_][]const u8{ "a", "c", "b" };
    var result = try computer.computeDiff(allocator, &original, &modified, .{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.changes.len);
}
