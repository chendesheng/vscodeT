const std = @import("std");
const WrappingIndent = @import("./config/editorOptions.zig").WrappingIndent;
const FontInfo = @import("./config/fontInfo.zig").FontInfo;
const Position = @import("./core/position.zig").Position;
const InjectedTextCursorStops = @import("./model.zig").InjectedTextCursorStops;
const InjectedTextOptions = @import("./model.zig").InjectedTextOptions;
const PositionAffinity = @import("./model.zig").PositionAffinity;
const LineInjectedText = @import("./textModelEvents.zig").LineInjectedText;

/// Describes how a model line was wrapped into output lines, including the
/// effects of injected text and the indentation of wrapped lines.
pub const ModelLineProjectionData = struct {
    injectionOffsets: ?[]const usize,
    /// `injectionOptions.len` must equal `injectionOffsets.len`.
    injectionOptions: ?[]const InjectedTextOptions,
    /// Refers to offsets after applying injections to the source.
    /// The last break offset indicates the length of the source after applying injections.
    breakOffsets: []const usize,
    /// Refers to offsets after applying injections.
    breakOffsetsVisibleColumn: []const usize,
    wrappedTextIndentLength: usize,

    pub fn init(
        injectionOffsets: ?[]const usize,
        injectionOptions: ?[]const InjectedTextOptions,
        breakOffsets: []const usize,
        breakOffsetsVisibleColumn: []const usize,
        wrappedTextIndentLength: usize,
    ) ModelLineProjectionData {
        return .{
            .injectionOffsets = injectionOffsets,
            .injectionOptions = injectionOptions,
            .breakOffsets = breakOffsets,
            .breakOffsetsVisibleColumn = breakOffsetsVisibleColumn,
            .wrappedTextIndentLength = wrappedTextIndentLength,
        };
    }

    pub fn getOutputLineCount(self: *const ModelLineProjectionData) usize {
        return self.breakOffsets.len;
    }

    pub fn getMinOutputOffset(self: *const ModelLineProjectionData, outputLineIndex: usize) usize {
        if (outputLineIndex > 0) {
            return self.wrappedTextIndentLength;
        }
        return 0;
    }

    pub fn getLineLength(self: *const ModelLineProjectionData, outputLineIndex: usize) usize {
        // These offsets refer to model text with injected text.
        const startOffset = if (outputLineIndex > 0) self.breakOffsets[outputLineIndex - 1] else 0;
        const endOffset = self.breakOffsets[outputLineIndex];

        var lineLength = endOffset - startOffset;
        if (outputLineIndex > 0) {
            lineLength += self.wrappedTextIndentLength;
        }
        return lineLength;
    }

    pub fn getMaxOutputOffset(self: *const ModelLineProjectionData, outputLineIndex: usize) usize {
        return self.getLineLength(outputLineIndex);
    }

    pub fn translateToInputOffset(self: *const ModelLineProjectionData, outputLineIndex: usize, outputOffset_: usize) usize {
        var outputOffset = outputOffset_;
        if (outputLineIndex > 0) {
            outputOffset = if (outputOffset > self.wrappedTextIndentLength) outputOffset - self.wrappedTextIndentLength else 0;
        }

        const offsetInInputWithInjection = if (outputLineIndex == 0) outputOffset else self.breakOffsets[outputLineIndex - 1] + outputOffset;
        var offsetInInput = offsetInInputWithInjection;

        if (self.injectionOffsets) |injection_offsets| {
            for (injection_offsets, 0..) |injection_offset, i| {
                if (offsetInInput > injection_offset) {
                    const content_length = self.injectionOptions.?[i].content.len;
                    if (offsetInInput < injection_offset + content_length) {
                        // `inputOffset` is within injected text.
                        offsetInInput = injection_offset;
                    } else {
                        offsetInInput -= content_length;
                    }
                } else {
                    break;
                }
            }
        }

        return offsetInInput;
    }

    pub fn translateToOutputPosition(self: *const ModelLineProjectionData, inputOffset: usize, affinity: PositionAffinity) OutputPosition {
        var inputOffsetInInputWithInjection = inputOffset;
        if (self.injectionOffsets) |injection_offsets| {
            for (injection_offsets, 0..) |injection_offset, i| {
                if (inputOffset < injection_offset) {
                    break;
                }

                if (affinity != .Right and inputOffset == injection_offset) {
                    break;
                }

                inputOffsetInInputWithInjection += self.injectionOptions.?[i].content.len;
            }
        }

        return self.offsetInInputWithInjectionsToOutputPosition(inputOffsetInInputWithInjection, affinity);
    }

    fn offsetInInputWithInjectionsToOutputPosition(
        self: *const ModelLineProjectionData,
        offsetInInputWithInjections: usize,
        affinity: PositionAffinity,
    ) OutputPosition {
        if (self.breakOffsets.len == 0) {
            return .{ .outputLineIndex = 0, .outputOffset = offsetInInputWithInjections };
        }

        var low: isize = 0;
        var high: isize = @intCast(self.breakOffsets.len - 1);
        var mid: isize = 0;
        var midStart: usize = 0;

        while (low <= high) {
            mid = low + @divTrunc(high - low, 2);

            const midStop = self.breakOffsets[@intCast(mid)];
            midStart = if (mid > 0) self.breakOffsets[@intCast(mid - 1)] else 0;

            if (affinity == .Left) {
                if (offsetInInputWithInjections <= midStart) {
                    high = mid - 1;
                } else if (offsetInInputWithInjections > midStop) {
                    low = mid + 1;
                } else {
                    break;
                }
            } else {
                if (offsetInInputWithInjections < midStart) {
                    high = mid - 1;
                } else if (offsetInInputWithInjections >= midStop) {
                    low = mid + 1;
                } else {
                    break;
                }
            }
        }

        var outputOffset = offsetInInputWithInjections - midStart;
        if (mid > 0) {
            outputOffset += self.wrappedTextIndentLength;
        }

        return .{ .outputLineIndex = @intCast(mid), .outputOffset = outputOffset };
    }

    pub fn normalizeOutputPosition(
        self: *const ModelLineProjectionData,
        outputLineIndex: usize,
        outputOffset: usize,
        affinity: PositionAffinity,
    ) OutputPosition {
        if (self.injectionOffsets != null) {
            const offsetInInputWithInjections = self.outputPositionToOffsetInInputWithInjections(outputLineIndex, outputOffset);
            const normalizedOffsetInUnwrappedLine = self.normalizeOffsetInInputWithInjectionsAroundInjections(offsetInInputWithInjections, affinity);
            if (normalizedOffsetInUnwrappedLine != offsetInInputWithInjections) {
                // Injected text caused a change.
                return self.offsetInInputWithInjectionsToOutputPosition(normalizedOffsetInUnwrappedLine, affinity);
            }
        }

        if (affinity == .Left) {
            if (outputLineIndex > 0 and outputOffset == self.getMinOutputOffset(outputLineIndex)) {
                return .{ .outputLineIndex = outputLineIndex - 1, .outputOffset = self.getMaxOutputOffset(outputLineIndex - 1) };
            }
        } else if (affinity == .Right) {
            const maxOutputLineIndex = self.getOutputLineCount() - 1;
            if (outputLineIndex < maxOutputLineIndex and outputOffset == self.getMaxOutputOffset(outputLineIndex)) {
                return .{ .outputLineIndex = outputLineIndex + 1, .outputOffset = self.getMinOutputOffset(outputLineIndex + 1) };
            }
        }

        return .{ .outputLineIndex = outputLineIndex, .outputOffset = outputOffset };
    }

    fn outputPositionToOffsetInInputWithInjections(self: *const ModelLineProjectionData, outputLineIndex: usize, outputOffset_: usize) usize {
        var outputOffset = outputOffset_;
        if (outputLineIndex > 0) {
            outputOffset = if (outputOffset > self.wrappedTextIndentLength) outputOffset - self.wrappedTextIndentLength else 0;
        }
        return (if (outputLineIndex > 0) self.breakOffsets[outputLineIndex - 1] else 0) + outputOffset;
    }

    fn normalizeOffsetInInputWithInjectionsAroundInjections(
        self: *const ModelLineProjectionData,
        offsetInInputWithInjections: usize,
        affinity: PositionAffinity,
    ) usize {
        const injectedText = self.getInjectedTextAtOffset(offsetInInputWithInjections) orelse return offsetInInputWithInjections;
        const injectionOptions = self.injectionOptions.?;
        const injectionOffsets = self.injectionOffsets.?;

        if (affinity == .None) {
            if (offsetInInputWithInjections == injectedText.offsetInInputWithInjections + injectedText.length and
                hasRightCursorStop(injectionOptions[injectedText.injectedTextIndex].cursorStops))
            {
                return injectedText.offsetInInputWithInjections + injectedText.length;
            }
            var result = injectedText.offsetInInputWithInjections;
            if (hasLeftCursorStop(injectionOptions[injectedText.injectedTextIndex].cursorStops)) {
                return result;
            }

            var index = @as(isize, @intCast(injectedText.injectedTextIndex)) - 1;
            while (index >= 0 and injectionOffsets[@intCast(index)] == injectionOffsets[injectedText.injectedTextIndex]) {
                if (hasRightCursorStop(injectionOptions[@intCast(index)].cursorStops)) {
                    break;
                }
                result -= injectionOptions[@intCast(index)].content.len;
                if (hasLeftCursorStop(injectionOptions[@intCast(index)].cursorStops)) {
                    break;
                }
                index -= 1;
            }

            return result;
        } else if (affinity == .Right or affinity == .RightOfInjectedText) {
            var result = injectedText.offsetInInputWithInjections + injectedText.length;
            var index = injectedText.injectedTextIndex;
            // Traverse all injected text that touch each other.
            while (index + 1 < injectionOffsets.len and injectionOffsets[index + 1] == injectionOffsets[index]) {
                result += injectionOptions[index + 1].content.len;
                index += 1;
            }
            return result;
        } else if (affinity == .Left or affinity == .LeftOfInjectedText) {
            var result = injectedText.offsetInInputWithInjections;
            var index = injectedText.injectedTextIndex;
            // Traverse all injected text that touch each other.
            while (index >= 1 and injectionOffsets[index - 1] == injectionOffsets[index]) {
                result -= injectionOptions[index - 1].content.len;
                index -= 1;
            }
            return result;
        }

        unreachable;
    }

    pub fn getInjectedText(self: *const ModelLineProjectionData, outputLineIndex: usize, outputOffset: usize) ?InjectedText {
        const offset = self.outputPositionToOffsetInInputWithInjections(outputLineIndex, outputOffset);
        const injectedText = self.getInjectedTextAtOffset(offset) orelse return null;
        return .{ .options = self.injectionOptions.?[injectedText.injectedTextIndex] };
    }

    fn getInjectedTextAtOffset(self: *const ModelLineProjectionData, offsetInInputWithInjections: usize) ?InjectedTextAtOffset {
        const injectionOffsets = self.injectionOffsets orelse return null;
        const injectionOptions = self.injectionOptions.?;

        var totalInjectedTextLengthBefore: usize = 0;
        for (injectionOffsets, 0..) |injection_offset, i| {
            const length = injectionOptions[i].content.len;
            const injectedTextStartOffsetInInputWithInjections = injection_offset + totalInjectedTextLengthBefore;
            const injectedTextEndOffsetInInputWithInjections = injection_offset + totalInjectedTextLengthBefore + length;

            if (injectedTextStartOffsetInInputWithInjections > offsetInInputWithInjections) {
                // Injected text starts later.
                break; // All later injected texts have an even larger offset.
            }

            if (offsetInInputWithInjections <= injectedTextEndOffsetInInputWithInjections) {
                // Injected text ends after or with the given position (but also starts with or before it).
                return .{
                    .injectedTextIndex = i,
                    .offsetInInputWithInjections = injectedTextStartOffsetInInputWithInjections,
                    .length = length,
                };
            }

            totalInjectedTextLengthBefore += length;
        }

        return null;
    }
};

const InjectedTextAtOffset = struct {
    injectedTextIndex: usize,
    offsetInInputWithInjections: usize,
    length: usize,
};

fn hasRightCursorStop(cursorStop: ?InjectedTextCursorStops) bool {
    const stop = cursorStop orelse return true;
    return stop == .Right or stop == .Both;
}

fn hasLeftCursorStop(cursorStop: ?InjectedTextCursorStops) bool {
    const stop = cursorStop orelse return true;
    return stop == .Left or stop == .Both;
}

pub const InjectedText = struct {
    options: InjectedTextOptions,
};

pub const OutputPosition = struct {
    outputLineIndex: usize,
    outputOffset: usize,

    pub fn toString(self: *const OutputPosition, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{d}:{d}", .{ self.outputLineIndex, self.outputOffset });
    }

    pub fn toPosition(self: *const OutputPosition, baseLineNumber: usize) Position {
        return Position.init(baseLineNumber + self.outputLineIndex, self.outputOffset + 1);
    }
};

pub const ILineBreaksComputerContext = struct {
    context: *anyopaque,
    getLineContent: *const fn (context: *anyopaque, lineNumber: usize) []const u8,
    getLineInjectedText: *const fn (context: *anyopaque, lineNumber: usize) ?[]LineInjectedText,
};

pub const WordBreak = enum {
    normal,
    keepAll,
};

pub const ILineBreaksComputerFactory = struct {
    context: *anyopaque,
    createLineBreaksComputer: *const fn (
        context: *anyopaque,
        lineBreaksComputerContext: ILineBreaksComputerContext,
        fontInfo: *const FontInfo,
        tabSize: usize,
        wrappingColumn: usize,
        wrappingIndent: WrappingIndent,
        wordBreak: WordBreak,
        wrapOnEscapedLineFeeds: bool,
        useTwoCellFullwidthCharacters: bool,
    ) ILineBreaksComputer,
};

pub const ILineBreaksComputer = struct {
    context: *anyopaque,
    addRequest: *const fn (context: *anyopaque, lineNumber: usize, previousLineBreakData: ?*const ModelLineProjectionData) void,
    finalize: *const fn (context: *anyopaque) []?ModelLineProjectionData,
};

fn injectedTextOptions(content: []const u8, cursorStops: ?InjectedTextCursorStops) InjectedTextOptions {
    return .{
        .content = content,
        .inlineClassName = null,
        .inlineClassNameAffectsLetterSpacing = false,
        .attachedData = null,
        .cursorStops = cursorStops,
    };
}

test "modelLineProjectionData: output offsets without injections" {
    const break_offsets = [_]usize{ 10, 20 };
    const break_columns = [_]usize{ 10, 10 };
    const data = ModelLineProjectionData.init(null, null, &break_offsets, &break_columns, 4);

    try std.testing.expectEqual(@as(usize, 2), data.getOutputLineCount());
    try std.testing.expectEqual(@as(usize, 0), data.getMinOutputOffset(0));
    try std.testing.expectEqual(@as(usize, 4), data.getMinOutputOffset(1));
    try std.testing.expectEqual(@as(usize, 10), data.getLineLength(0));
    try std.testing.expectEqual(@as(usize, 14), data.getLineLength(1));
    try std.testing.expectEqual(@as(usize, 14), data.getMaxOutputOffset(1));

    try std.testing.expectEqual(@as(usize, 10), data.translateToInputOffset(1, 4));
    try std.testing.expectEqual(@as(usize, 16), data.translateToInputOffset(1, 10));
    try std.testing.expectEqual(@as(usize, 10), data.translateToInputOffset(1, 0));

    const output = data.translateToOutputPosition(10, .None);
    try std.testing.expectEqual(@as(usize, 1), output.outputLineIndex);
    try std.testing.expectEqual(@as(usize, 4), output.outputOffset);

    const normalized = data.normalizeOutputPosition(1, 4, .Left);
    try std.testing.expectEqual(@as(usize, 0), normalized.outputLineIndex);
    try std.testing.expectEqual(@as(usize, 10), normalized.outputOffset);
}

test "modelLineProjectionData: injected text offsets" {
    const injection_offsets = [_]usize{2};
    const injection_options = [_]InjectedTextOptions{injectedTextOptions("XY", .Both)};
    const break_offsets = [_]usize{6};
    const break_columns = [_]usize{6};
    const data = ModelLineProjectionData.init(&injection_offsets, &injection_options, &break_offsets, &break_columns, 0);

    try std.testing.expectEqual(@as(usize, 2), data.translateToInputOffset(0, 3));
    try std.testing.expectEqual(@as(usize, 2), data.translateToInputOffset(0, 2));
    try std.testing.expectEqual(@as(usize, 3), data.translateToInputOffset(0, 5));

    const output = data.translateToOutputPosition(2, .Right);
    try std.testing.expectEqual(@as(usize, 0), output.outputLineIndex);
    try std.testing.expectEqual(@as(usize, 4), output.outputOffset);

    const output_none = data.translateToOutputPosition(2, .None);
    try std.testing.expectEqual(@as(usize, 2), output_none.outputOffset);

    const injected = data.getInjectedText(0, 3).?;
    try std.testing.expectEqualStrings("XY", injected.options.content);
    try std.testing.expect(data.getInjectedText(0, 5) == null);
}

test "modelLineProjectionData: output position" {
    const position = OutputPosition{ .outputLineIndex = 2, .outputOffset = 5 };
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2:5", try position.toString(&buffer));

    const model_position = position.toPosition(10);
    try std.testing.expectEqual(@as(usize, 12), model_position.lineNumber);
    try std.testing.expectEqual(@as(usize, 6), model_position.column);
}
