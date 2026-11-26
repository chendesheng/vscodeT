// Port of `src/vs/editor/contrib/hover/browser/glyphHoverComputer.ts`.
// The editor model exposes the Markdown source strings; the terminal widget
// renders them through the shared Markdown renderer. The caller owns the
// result and the copied strings (normally in the operation's arena).
const std = @import("std");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const GlyphMarginLane = @import("../../../common/model.zig").GlyphMarginLane;

pub const LaneOrLineNumber = union(enum) { lane: GlyphMarginLane, line_no };
pub const GlyphHoverComputerOptions = struct {
    lineNumber: usize,
    laneOrLine: LaneOrLineNumber,
};
pub const IHoverMessage = struct { value: []const u8 };

pub const GlyphHoverComputer = struct {
    pub fn computeSync(allocator: std.mem.Allocator, model: *TextModel, options: GlyphHoverComputerOptions) ![]const IHoverMessage {
        const decorations = try model.getLineDecorations(options.lineNumber, 0, false);
        defer model.getAllocator().free(decorations);
        var result: std.ArrayList(IHoverMessage) = .empty;
        errdefer {
            for (result.items) |message| allocator.free(message.value);
            result.deinit(allocator);
        }
        for (decorations) |decoration| {
            const lane = if (decoration.options.glyphMargin) |margin| margin.position else GlyphMarginLane.Center;
            if (options.laneOrLine == .lane and lane != options.laneOrLine.lane) continue;
            const messages = if (options.laneOrLine == .line_no) decoration.options.lineNumberHoverMessage else decoration.options.glyphMarginHoverMessage;
            const values = messages orelse continue;
            // Upstream checks the entire markdown array for emptiness first;
            // a nonempty array preserves every authored row and its order.
            var nonempty = false;
            for (values) |value| if (value.len != 0) {
                nonempty = true;
                break;
            };
            if (!nonempty) continue;
            for (values) |value| {
                const owned = try allocator.dupe(u8, value);
                errdefer allocator.free(owned);
                try result.append(allocator, .{ .value = owned });
            }
        }
        return result.toOwnedSlice(allocator);
    }
};
