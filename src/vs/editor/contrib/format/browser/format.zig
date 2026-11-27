// Port of getOnTypeFormattingEdits in
// `src/vs/editor/contrib/format/browser/format.ts`.
// Provider calls can suspend a window fiber. The minimal-edit worker receives
// only immutable text, and the window converts its byte offsets to model ranges.
const std = @import("std");
const Allocator = std.mem.Allocator;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const languages = @import("../../../common/languages.zig");
const LanguageFeaturesService = @import("../../../common/services/languageFeaturesService.zig").LanguageFeaturesService;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const worker = @import("../../../common/services/editorWebWorker.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");

pub fn getOnTypeFormattingEdits(
    allocator: Allocator,
    features: *LanguageFeaturesService,
    model: *TextModel,
    position: Position,
    ch: []const u8,
    options: languages.FormattingOptions,
    token: CancellationToken,
    executor: ?std.Io,
) ![]const languages.TextEdit {
    try token.throwIfCancellationRequested();
    const providers = try features.on_type_formatting_edit_provider.ordered(allocator, model, false);
    defer allocator.free(providers);
    if (providers.len == 0) return &.{};
    const provider = providers[0];
    for (provider.auto_format_trigger_characters) |trigger| {
        if (std.mem.eql(u8, ch, trigger)) break;
    } else return &.{};
    const raw = provider.provide_on_type_formatting_edits(provider.context, allocator, model, position, ch, options, token) catch return &.{};
    try token.throwIfCancellationRequested();
    var result: std.ArrayList(languages.TextEdit) = .empty;
    const version = model.getVersionId();
    for (raw) |edit| {
        const range = model.validateRange(edit.range);
        const start = model.getOffsetAt(range.getStartPosition());
        const eol = model.getEOL();
        const original = try model.getValueInRange(range, null);
        defer original.deinit();
        const minimal = if (executor) |io|
            try dispatch.workerCall(io, worker.computeMoreMinimalEdits, .{ allocator, original.items, edit.text, eol, false })
        else
            try worker.computeMoreMinimalEdits(allocator, original.items, edit.text, eol, false);
        defer minimal.deinit(allocator);
        try token.throwIfCancellationRequested();
        // A detached diff may outlive its exact byte snapshot. Do not
        // reinterpret its offsets against a newer native text model.
        if (model.getVersionId() != version) return error.CancellationError;
        for (minimal.changes) |change| {
            const from = model.getPositionAt(start + @as(usize, @intCast(change.originalStart)));
            const to = model.getPositionAt(start + @as(usize, @intCast(change.getOriginalEnd())));
            try result.append(allocator, .{
                .range = Range.fromPositions(from, to),
                .text = try allocator.dupe(u8, minimal.text[@intCast(change.modifiedStart)..@intCast(change.getModifiedEnd())]),
            });
        }
    }
    return result.items;
}
