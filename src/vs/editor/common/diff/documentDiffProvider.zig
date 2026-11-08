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
