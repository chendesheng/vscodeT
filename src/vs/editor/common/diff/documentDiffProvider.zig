// Port of the type declarations of
// `src/vs/editor/common/diff/documentDiffProvider.ts`.
//
// The provider is modelled with the same "struct of function pointers" approach
// used for `ILinesDiffComputer`. `computeDiff` is synchronous: this port has no
// event loop, so the `Promise` of the TypeScript implementation is dropped.
const std = @import("std");
const Allocator = std.mem.Allocator;

const cancellation = @import("../../../base/common/cancellation.zig");
const lines_diff_computer = @import("linesDiffComputer.zig");
const verify_lines_diff = @import("verifyLinesDiff.zig");
const text_model = @import("../model/textModel.zig");

pub const CancellationToken = cancellation.CancellationToken;
pub const MovedText = lines_diff_computer.MovedText;
pub const DetailedLineRangeMapping = @import("rangeMapping.zig").DetailedLineRangeMapping;
pub const LinesDiffValidity = verify_lines_diff.LinesDiffValidity;
pub const TextModel = text_model.TextModel;

/// Options for the diff computation.
pub const IDocumentDiffProviderOptions = lines_diff_computer.ILinesDiffComputerOptions;

/// Why a diff from `@vscode/diff` was replaced by one from the built-in
/// algorithm: the package threw, or a sampled verification found its diff
/// invalid.
pub const DiffFallbackReason = enum { @"error", invalid };

/// Represents a diff between two text models.
pub const IDocumentDiff = struct {
    /// If true, both text models are identical (byte-wise).
    identical: bool,
    /// If true, the diff computation timed out and the diff might not be
    /// accurate.
    quitEarly: bool,
    /// Maps all modified line ranges in the original to the corresponding line
    /// ranges in the modified text model.
    changes: []const DetailedLineRangeMapping,
    /// Sorted by original line ranges. The original line ranges and the
    /// modified line ranges must be disjoint (but can be touching).
    moves: []const MovedText,
    /// Whether applying the changes to the original reproduces the modified
    /// text. Only set if verification was requested, which happens for a
    /// sample of diffs.
    validity: ?LinesDiffValidity = null,
    /// Why the requested algorithm's result was replaced by the built-in
    /// algorithm's result, if it was.
    fallback: ?DiffFallbackReason = null,
};

pub const empty_changes: [0]DetailedLineRangeMapping = .{};
pub const empty_moves: [0]MovedText = .{};

/// The diff of two identical documents.
pub const nullDocumentDiff = IDocumentDiff{
    .identical = true,
    .quitEarly = false,
    .changes = &empty_changes,
    .moves = &empty_moves,
};

/// A document diff provider computes the diff between two text models.
pub const IDocumentDiffProvider = struct {
    context: *anyopaque,
    compute_diff: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        original: *const TextModel,
        modified: *const TextModel,
        options: IDocumentDiffProviderOptions,
        cancellation_token: CancellationToken,
    ) anyerror!IDocumentDiff,

    /// Computes the diff between the text models `original` and `modified`.
    pub fn computeDiff(
        self: IDocumentDiffProvider,
        allocator: Allocator,
        original: *const TextModel,
        modified: *const TextModel,
        options: IDocumentDiffProviderOptions,
        cancellation_token: CancellationToken,
    ) !IDocumentDiff {
        return self.compute_diff(self.context, allocator, original, modified, options, cancellation_token);
    }
};

test "nullDocumentDiff" {
    try std.testing.expect(nullDocumentDiff.identical);
    try std.testing.expect(!nullDocumentDiff.quitEarly);
    try std.testing.expectEqual(@as(usize, 0), nullDocumentDiff.changes.len);
    try std.testing.expectEqual(@as(usize, 0), nullDocumentDiff.moves.len);
    try std.testing.expectEqual(@as(?LinesDiffValidity, null), nullDocumentDiff.validity);
    try std.testing.expectEqual(@as(?DiffFallbackReason, null), nullDocumentDiff.fallback);
}

// ---------------------------------------------------------------------------
// Concrete line-based provider
// ---------------------------------------------------------------------------

const lines_diff_computers = @import("linesDiffComputers.zig");

pub const DiffAlgorithmName = lines_diff_computers.DiffAlgorithmName;

/// Frees the owned changes/moves of a computed diff. `nullDocumentDiff` and
/// other empty results use static empty slices and need no cleanup.
pub fn deinitDiff(allocator: Allocator, diff: *IDocumentDiff) void {
    for (@constCast(diff.changes)) |*change| change.deinit(allocator);
    if (diff.changes.len > 0) allocator.free(diff.changes);
    for (@constCast(diff.moves)) |*moved| moved.deinit(allocator);
    if (diff.moves.len > 0) allocator.free(diff.moves);
    diff.changes = &empty_changes;
    diff.moves = &empty_moves;
}

fn linesEqual(original: []const []const u8, modified: []const []const u8) bool {
    if (original.len != modified.len) return false;
    for (original, modified) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

/// Terminal `IDocumentDiffProvider` over line arrays. It backs the diff editor
/// model and quick diff. The external/wasm algorithms fall back to the built-in
/// advanced computer, which is the browser worker fallback in upstream.
pub const LineDiffProvider = struct {
    algorithm: DiffAlgorithmName = .advanced,
    /// Set when a requested package algorithm was unavailable; exposed for
    /// diagnostics and tests.
    fell_back: bool = false,

    pub fn init(algorithm: DiffAlgorithmName) LineDiffProvider {
        return .{
            .algorithm = algorithm,
            .fell_back = algorithm.isPackage(),
        };
    }

    /// Computes the diff between two arrays of lines. The caller owns the
    /// returned changes/moves and must call `deinitDiff`.
    pub fn computeDiffFromLines(
        self: *LineDiffProvider,
        allocator: Allocator,
        original: []const []const u8,
        modified: []const []const u8,
        options: IDocumentDiffProviderOptions,
    ) !IDocumentDiff {
        if (linesEqual(original, modified)) {
            return IDocumentDiff{
                .identical = true,
                .quitEarly = false,
                .changes = &empty_changes,
                .moves = &empty_moves,
            };
        }

        const computer = lines_diff_computers.getBuiltin(self.algorithm) orelse blk: {
            self.fell_back = true;
            break :blk lines_diff_computers.getBuiltin(.advanced).?;
        };
        const result = try computer.computeDiff(allocator, original, modified, .{
            .ignoreTrimWhitespace = options.ignoreTrimWhitespace,
            .maxComputationTimeMs = options.maxComputationTimeMs,
            .computeMoves = options.computeMoves,
            .extendToSubwords = options.extendToSubwords,
        });
        // Transfer ownership of the change/move slices to the caller; do not
        // call `result.deinit`.
        const changes = result.changes;
        const moves = result.moves;
        return .{
            .identical = false,
            .quitEarly = result.hit_timeout,
            .changes = changes,
            .moves = moves,
        };
    }

    /// `IDocumentDiffProvider` adapter over two text models.
    pub fn interface(self: *LineDiffProvider) IDocumentDiffProvider {
        return .{
            .context = self,
            .compute_diff = computeDiffThunk,
        };
    }

    fn computeDiffThunk(
        context: *anyopaque,
        allocator: Allocator,
        original: *const TextModel,
        modified: *const TextModel,
        options: IDocumentDiffProviderOptions,
        _: CancellationToken,
    ) anyerror!IDocumentDiff {
        const self: *LineDiffProvider = @ptrCast(@alignCast(context));

        var original_lines = try original.getLinesContent();
        defer {
            for (original_lines.items) |*line| line.deinit();
            original_lines.deinit();
        }
        var modified_lines = try modified.getLinesContent();
        defer {
            for (modified_lines.items) |*line| line.deinit();
            modified_lines.deinit();
        }

        const original_views = try allocator.alloc([]const u8, original_lines.items.len);
        defer allocator.free(original_views);
        for (original_lines.items, 0..) |line, index| original_views[index] = line.items;

        const modified_views = try allocator.alloc([]const u8, modified_lines.items.len);
        defer allocator.free(modified_views);
        for (modified_lines.items, 0..) |line, index| modified_views[index] = line.items;

        return self.computeDiffFromLines(allocator, original_views, modified_views, options);
    }
};

test "LineDiffProvider: identical, insert, delete and modify" {
    const allocator = std.testing.allocator;
    var provider = LineDiffProvider.init(.advanced);
    const options = IDocumentDiffProviderOptions{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    };

    var identical = try provider.computeDiffFromLines(allocator, &.{ "a", "b" }, &.{ "a", "b" }, options);
    defer deinitDiff(allocator, &identical);
    try std.testing.expect(identical.identical);
    try std.testing.expectEqual(@as(usize, 0), identical.changes.len);

    var added = try provider.computeDiffFromLines(allocator, &.{ "a", "b" }, &.{ "a", "x", "b" }, options);
    defer deinitDiff(allocator, &added);
    try std.testing.expect(!added.identical);
    try std.testing.expectEqual(@as(usize, 1), added.changes.len);
    // A pure insertion has an empty original range and one modified line.
    try std.testing.expectEqual(@as(usize, 0), added.changes[0].original.length());
    try std.testing.expectEqual(@as(usize, 1), added.changes[0].modified.length());

    var modified = try provider.computeDiffFromLines(allocator, &.{ "a", "b", "c" }, &.{ "a", "B", "c" }, options);
    defer deinitDiff(allocator, &modified);
    try std.testing.expectEqual(@as(usize, 1), modified.changes.len);
    try std.testing.expect(modified.changes[0].inner_changes != null);
}

test "LineDiffProvider: package algorithms fall back to advanced" {
    const allocator = std.testing.allocator;
    var provider = LineDiffProvider.init(.advanced_external);
    try std.testing.expect(provider.fell_back);
    var diff = try provider.computeDiffFromLines(allocator, &.{"a"}, &.{ "a", "b" }, .{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    });
    defer deinitDiff(allocator, &diff);
    try std.testing.expectEqual(@as(usize, 1), diff.changes.len);

    var legacy = LineDiffProvider.init(.legacy);
    try std.testing.expect(!legacy.fell_back);
    var legacy_diff = try legacy.computeDiffFromLines(allocator, &.{"a"}, &.{"b"}, .{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    });
    defer deinitDiff(allocator, &legacy_diff);
    try std.testing.expectEqual(@as(usize, 1), legacy_diff.changes.len);
}
