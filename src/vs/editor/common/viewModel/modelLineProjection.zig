// Port of
// `src/vs/editor/common/viewModel/modelLineProjection.ts`.
//
// A projected line owns break and injected-text arrays. Model decoration
// text remains borrowed; the model injected-text event replaces affected
// projections before disposing decoration data.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Position = @import("../core/position.zig").Position;
const PositionAffinity = @import("../model.zig").PositionAffinity;
const TextModel = @import("../model/textModel.zig").TextModel;
const ModelLineProjectionData = @import("../modelLineProjectionData.zig").ModelLineProjectionData;
const InjectedText = @import("../modelLineProjectionData.zig").InjectedText;
const ViewLineData = @import("../viewModel.zig").ViewLineData;
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const IViewLineTokens = @import("../tokens/lineTokens.zig").IViewLineTokens;

pub const ModelLineProjection = struct {
    allocator: Allocator,
    data: ?ModelLineProjectionData,
    /// Hidden model lines have no view lines. Folding ranges hide lines by
    /// changing this flag, mirroring `createModelLineProjection`/`setVisible`
    /// in the upstream projection.
    visible: bool = true,

    pub fn init(allocator: Allocator, data: ?ModelLineProjectionData) ModelLineProjection {
        return .{ .allocator = allocator, .data = data };
    }

    pub fn isVisible(self: *const ModelLineProjection) bool {
        return self.visible;
    }

    pub fn setVisible(self: *ModelLineProjection, visible: bool) void {
        self.visible = visible;
    }

    pub fn deinit(self: *ModelLineProjection) void {
        if (self.data) |data| {
            if (data.injectionOffsets) |offsets| self.allocator.free(offsets);
            if (data.injectionOptions) |options| self.allocator.free(options);
            if (data.breakOffsets.len > 0) self.allocator.free(data.breakOffsets);
            if (data.breakOffsetsVisibleColumn.len > 0) self.allocator.free(data.breakOffsetsVisibleColumn);
        }
        self.data = null;
    }

    pub fn getProjectionData(self: *const ModelLineProjection) ?*const ModelLineProjectionData {
        if (self.data == null) return null;
        return &self.data.?;
    }

    pub fn getViewLineCount(self: *const ModelLineProjection) usize {
        if (!self.visible) return 0;
        if (self.data) |data| return data.getOutputLineCount();
        return 1;
    }

    pub fn getViewLineLength(self: *const ModelLineProjection, model: *TextModel, model_line: usize, output_index: usize) usize {
        if (self.data) |data| return data.getLineLength(output_index);
        return model.getLineLength(model_line);
    }

    pub fn getViewLineMinColumn(self: *const ModelLineProjection, _: *TextModel, _: usize, output_index: usize) usize {
        if (self.data) |data| return data.getMinOutputOffset(output_index) + 1;
        return 1;
    }

    pub fn getViewLineMaxColumn(self: *const ModelLineProjection, model: *TextModel, model_line: usize, output_index: usize) usize {
        if (self.data) |data| return data.getMaxOutputOffset(output_index) + 1;
        return model.getLineMaxColumn(model_line);
    }

    pub fn getViewLineContinuesWithWrappedLine(self: *const ModelLineProjection, output_index: usize) bool {
        if (self.data) |data| return output_index + 1 < data.getOutputLineCount();
        return false;
    }

    /// Fills `buffer` with the content of the requested output line, including
    /// the synthetic indentation of continuation lines.
    pub fn fillViewLineContent(
        self: *const ModelLineProjection,
        model: *TextModel,
        model_line: usize,
        output_index: usize,
        buffer: *ArrayList(u8),
    ) !void {
        buffer.clearRetainingCapacity();
        const line = try model.getLineContent(model_line);
        defer line.deinit();

        if (self.data) |data| {
            const start = if (output_index > 0) data.breakOffsets[output_index - 1] else 0;
            const end = data.breakOffsets[output_index];
            if (output_index > 0) try buffer.appendNTimes(' ', data.wrappedTextIndentLength);
            if (data.injectionOffsets) |offsets| {
                const LineInjectedText = @import("../textModelEvents.zig").LineInjectedText;
                const injected = try self.allocator.alloc(LineInjectedText, offsets.len);
                defer self.allocator.free(injected);
                for (offsets, data.injectionOptions.?, injected) |offset, options, *item| item.* = .{ .ownerId = 0, .lineNumber = model_line, .column = offset + 1, .options = options, .order = 0 };
                const combined = try LineInjectedText.applyInjectedText(self.allocator, line.items, injected);
                defer self.allocator.free(combined);
                try buffer.appendSlice(combined[start..end]);
            } else try buffer.appendSlice(line.items[start..end]);
        } else {
            try buffer.appendSlice(line.items);
        }
    }

    pub fn getViewLineData(
        self: *const ModelLineProjection,
        model: *TextModel,
        model_line: usize,
        output_index: usize,
        tokens: *?LineTokens,
        content: *ArrayList(u8),
    ) !ViewLineData {
        if (tokens.*) |*old| {
            old.deinit();
            tokens.* = null;
        }

        const line_tokens = try model.tokenization().getLineTokens(model_line);
        tokens.* = line_tokens;
        if (self.data) |data| {
            if (data.injectionOffsets) |offsets| {
                const injections = try self.allocator.alloc(LineTokens.InsertedToken, offsets.len);
                defer self.allocator.free(injections);
                for (offsets, data.injectionOptions.?, injections) |offset, options, *token| token.* = .{ .offset = offset, .text = options.content, .tokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata.default };
                const result = try tokens.*.?.withInserted(injections);
                tokens.*.?.deinit();
                tokens.* = result;
            }
        }

        const stored = if (tokens.*) |*t| t else unreachable;
        content.clearRetainingCapacity();
        if (self.data) |data| {
            const start = if (output_index > 0) data.breakOffsets[output_index - 1] else 0;
            const end = data.breakOffsets[output_index];
            const indent = if (output_index > 0) data.wrappedTextIndentLength else 0;
            const slice = stored.sliceAndInflate(start, end, indent);
            if (indent > 0) try content.appendNTimes(' ', indent);
            try content.appendSlice(slice.getLineContent());
            return ViewLineData.init(
                content.items,
                output_index + 1 < data.getOutputLineCount(),
                data.getMinOutputOffset(output_index) + 1,
                content.items.len + 1,
                if (output_index == 0) 0 else data.breakOffsetsVisibleColumn[output_index - 1],
                IViewLineTokens.initSlice(slice),
                null,
            );
        }

        try content.appendSlice(stored.getLineContent());
        return ViewLineData.init(
            content.items,
            false,
            1,
            content.items.len + 1,
            0,
            IViewLineTokens.init(stored),
            null,
        );
    }

    pub fn getModelColumnOfViewPosition(self: *const ModelLineProjection, output_index: usize, view_column: usize) usize {
        if (self.data) |data| return data.translateToInputOffset(output_index, view_column - 1) + 1;
        return view_column;
    }

    pub fn getViewPositionOfModelPosition(self: *const ModelLineProjection, delta_line_number: usize, input_column: usize, affinity: PositionAffinity) Position {
        if (self.data) |data| {
            const result = data.translateToOutputPosition(input_column - 1, affinity);
            return result.toPosition(delta_line_number);
        }
        return Position.init(delta_line_number, input_column);
    }

    pub fn getViewLineNumberOfModelPosition(self: *const ModelLineProjection, delta_line_number: usize, input_column: usize) usize {
        if (self.data) |data| {
            const result = data.translateToOutputPosition(input_column - 1, .None);
            return delta_line_number + result.outputLineIndex;
        }
        return delta_line_number;
    }

    pub fn normalizePosition(self: *const ModelLineProjection, output_index: usize, output_position: Position, affinity: PositionAffinity) Position {
        if (self.data) |data| {
            const base_view_line_number = output_position.lineNumber - output_index;
            const normalized = data.normalizeOutputPosition(output_index, output_position.column - 1, affinity);
            return normalized.toPosition(base_view_line_number);
        }
        return output_position;
    }

    pub fn getInjectedTextAt(self: *const ModelLineProjection, _: usize, _: usize) ?InjectedText {
        _ = self;
        return null;
    }
};
