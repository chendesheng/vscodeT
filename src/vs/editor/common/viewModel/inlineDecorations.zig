const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const AutoHashMap = std.AutoHashMap;
const Range = @import("../core/range.zig").Range;
const Position = @import("../core/position.zig").Position;
const TextModel = @import("../model/textModel.zig").TextModel;
const ModelDecoration = @import("../model.zig").ModelDecoration;
const ModelDecorationOptions = @import("../model.zig").ModelDecorationOptions;
const InjectedTextOptions = @import("../model.zig").InjectedTextOptions;
const PositionAffinity = @import("../model.zig").PositionAffinity;
const ICoordinatesConverter = @import("../coordinatesConverter.zig").ICoordinatesConverter;
const ViewModelDecoration = @import("./viewModelDecoration.zig").ViewModelDecoration;
const isModelDecorationVisible = @import("./viewModelDecoration.zig").isModelDecorationVisible;

pub const InlineDecorationType = enum(u3) {
    Regular = 0,
    Before = 1,
    After = 2,
    RegularAffectingLetterSpacing = 3,
    WidthOnly = 4,
};

pub const InlineDecoration = struct {
    range: Range,
    inlineClassName: []const u8,
    type: InlineDecorationType,

    pub fn init(range: Range, inlineClassName: []const u8, decoration_type: InlineDecorationType) InlineDecoration {
        return .{ .range = range, .inlineClassName = inlineClassName, .type = decoration_type };
    }
};

pub const ViewDecorationsCollection = struct {
    allocator: Allocator,
    decorations: []ViewModelDecoration,
    inlineDecorations: [][]InlineDecoration,
    hasVariableFonts: []bool,

    pub fn deinit(self: *ViewDecorationsCollection) void {
        for (self.inlineDecorations) |line| {
            if (line.len > 0) self.allocator.free(line);
        }
        if (self.inlineDecorations.len > 0) self.allocator.free(self.inlineDecorations);
        if (self.decorations.len > 0) self.allocator.free(self.decorations);
        if (self.hasVariableFonts.len > 0) self.allocator.free(self.hasVariableFonts);
    }
};

pub const InlineDecorations = struct {
    allocator: Allocator,
    lines: [][]InlineDecoration,

    pub fn deinit(self: *InlineDecorations) void {
        for (self.lines) |line| {
            if (line.len > 0) self.allocator.free(line);
        }
        if (self.lines.len > 0) self.allocator.free(self.lines);
    }
};

pub const IInlineModelDecorationsComputerContext = struct {
    context: *anyopaque,
    getModelDecorations: *const fn (context: *anyopaque, viewRange: Range, onlyMinimapDecorations: bool, onlyMarginDecorations: bool) []const ModelDecoration,
};

pub const InlineModelDecorationsComputer = struct {
    allocator: Allocator,
    context: IInlineModelDecorationsComputerContext,
    model: *TextModel,
    coordinates_converter: ICoordinatesConverter,
    _decorationsCache: AutoHashMap(u64, ViewModelDecoration),

    pub fn init(
        allocator: Allocator,
        context: IInlineModelDecorationsComputerContext,
        model: *TextModel,
        coordinatesConverter: ICoordinatesConverter,
    ) InlineModelDecorationsComputer {
        return .{
            .allocator = allocator,
            .context = context,
            .model = model,
            .coordinates_converter = coordinatesConverter,
            ._decorationsCache = AutoHashMap(u64, ViewModelDecoration).init(allocator),
        };
    }

    pub fn deinit(self: *InlineModelDecorationsComputer) void {
        self._decorationsCache.deinit();
    }

    pub fn reset(self: *InlineModelDecorationsComputer) void {
        self._decorationsCache.clearRetainingCapacity();
    }

    pub fn getInlineDecorations(self: *InlineModelDecorationsComputer, modelLineNumber: usize) !InlineDecorations {
        const modelRange = Range.init(modelLineNumber, 1, modelLineNumber, self.model.getLineMaxColumn(modelLineNumber));
        const viewRange = self.coordinates_converter.convertModelRangeToViewRange(self.coordinates_converter.context, modelRange, .None);
        var collection = try self.getDecorations(viewRange, false, false);
        const lines = collection.inlineDecorations;
        collection.inlineDecorations = collection.inlineDecorations[0..0];
        collection.deinit();
        return .{ .allocator = self.allocator, .lines = lines };
    }

    pub fn getDecorations(
        self: *InlineModelDecorationsComputer,
        viewRange: Range,
        onlyMinimapDecorations: bool,
        onlyMarginDecorations: bool,
    ) !ViewDecorationsCollection {
        const modelDecorations = self.context.getModelDecorations(
            self.context.context,
            viewRange,
            onlyMinimapDecorations,
            onlyMarginDecorations,
        );

        const startLineNumber = viewRange.startLineNumber;
        const endLineNumber = viewRange.endLineNumber;
        const line_count = endLineNumber - startLineNumber + 1;

        var decorations = ArrayList(ViewModelDecoration).init(self.allocator);
        errdefer decorations.deinit();

        const inline_lists = try self.allocator.alloc(ArrayList(InlineDecoration), line_count);
        var initialized_lists: usize = 0;
        errdefer {
            for (inline_lists[0..initialized_lists]) |*list| list.deinit();
            self.allocator.free(inline_lists);
        }
        for (inline_lists) |*list| {
            list.* = ArrayList(InlineDecoration).init(self.allocator);
            initialized_lists += 1;
        }

        const hasVariableFonts = try self.allocator.alloc(bool, line_count);
        errdefer self.allocator.free(hasVariableFonts);
        @memset(hasVariableFonts, false);

        for (modelDecorations) |modelDecoration| {
            if (!try isModelDecorationVisible(self.model, modelDecoration)) continue;

            const viewModelDecoration = try self.getOrCreateViewModelDecoration(modelDecoration);
            try decorations.append(viewModelDecoration);

            const options = modelDecoration.options;
            const decoration_view_range = viewModelDecoration.range;

            if (options.inlineClassName) |inlineClassName| {
                const inline_decoration = InlineDecoration.init(
                    decoration_view_range,
                    inlineClassName,
                    if (options.inlineClassNameAffectsLetterSpacing orelse false)
                        .RegularAffectingLetterSpacing
                    else
                        .Regular,
                );
                const intersectedStart = @max(startLineNumber, decoration_view_range.startLineNumber);
                const intersectedEnd = @min(endLineNumber, decoration_view_range.endLineNumber);
                if (intersectedStart <= intersectedEnd) {
                    for (intersectedStart..intersectedEnd + 1) |line| {
                        try inline_lists[line - startLineNumber].append(inline_decoration);
                        if (options.affectsFont orelse false) {
                            hasVariableFonts[line - startLineNumber] = true;
                        }
                    }
                }
            }

            if (options.beforeContentClassName) |beforeContentClassName| {
                if (startLineNumber <= decoration_view_range.startLineNumber and decoration_view_range.startLineNumber <= endLineNumber) {
                    const inline_decoration = InlineDecoration.init(
                        Range.init(decoration_view_range.startLineNumber, decoration_view_range.startColumn, decoration_view_range.startLineNumber, decoration_view_range.startColumn),
                        beforeContentClassName,
                        .Before,
                    );
                    try inline_lists[decoration_view_range.startLineNumber - startLineNumber].append(inline_decoration);
                    if (options.affectsFont orelse false) {
                        hasVariableFonts[decoration_view_range.startLineNumber - startLineNumber] = true;
                    }
                }
            }

            if (options.afterContentClassName) |afterContentClassName| {
                if (startLineNumber <= decoration_view_range.endLineNumber and decoration_view_range.endLineNumber <= endLineNumber) {
                    const inline_decoration = InlineDecoration.init(
                        Range.init(decoration_view_range.endLineNumber, decoration_view_range.endColumn, decoration_view_range.endLineNumber, decoration_view_range.endColumn),
                        afterContentClassName,
                        .After,
                    );
                    try inline_lists[decoration_view_range.endLineNumber - startLineNumber].append(inline_decoration);
                    if (options.affectsFont orelse false) {
                        hasVariableFonts[decoration_view_range.endLineNumber - startLineNumber] = true;
                    }
                }
            }
        }

        const inlineDecorations = try self.allocator.alloc([]InlineDecoration, line_count);
        var converted_lists: usize = 0;
        errdefer {
            for (inlineDecorations[0..converted_lists]) |line| {
                if (line.len > 0) self.allocator.free(line);
            }
            self.allocator.free(inlineDecorations);
        }
        for (inline_lists, 0..) |*list, i| {
            inlineDecorations[i] = try list.toOwnedSlice();
            converted_lists += 1;
        }
        const owned_decorations = try decorations.toOwnedSlice();
        for (inline_lists) |*list| list.deinit();
        self.allocator.free(inline_lists);

        return .{
            .allocator = self.allocator,
            .decorations = owned_decorations,
            .inlineDecorations = inlineDecorations,
            .hasVariableFonts = hasVariableFonts,
        };
    }

    fn getOrCreateViewModelDecoration(self: *InlineModelDecorationsComputer, modelDecoration: ModelDecoration) !ViewModelDecoration {
        if (self._decorationsCache.get(modelDecoration.id)) |cached| {
            return cached;
        }

        const modelRange = modelDecoration.range;
        const options = modelDecoration.options;
        var viewRange: Range = undefined;

        if (options.isWholeLine orelse false) {
            const start = self.coordinates_converter.convertModelPositionToViewPosition(
                self.coordinates_converter.context,
                Position.init(modelRange.startLineNumber, 1),
                .Left,
                false,
                true,
            );
            const end = self.coordinates_converter.convertModelPositionToViewPosition(
                self.coordinates_converter.context,
                Position.init(modelRange.endLineNumber, self.model.getLineMaxColumn(modelRange.endLineNumber)),
                .Right,
                false,
                false,
            );
            viewRange = Range.init(start.lineNumber, start.column, end.lineNumber, end.column);
        } else {
            viewRange = self.coordinates_converter.convertModelRangeToViewRange(
                self.coordinates_converter.context,
                modelRange,
                .Right,
            );
        }

        const result = ViewModelDecoration.init(viewRange, options);
        try self._decorationsCache.put(modelDecoration.id, result);
        return result;
    }
};

pub const IInjectedTextInlineDecorationsComputerContext = struct {
    context: *anyopaque,
    getInjectionOptions: *const fn (context: *anyopaque, modelLineNumber: usize) ?[]const InjectedTextOptions,
    getInjectionOffsets: *const fn (context: *anyopaque, modelLineNumber: usize) ?[]const usize,
    getBreakOffsets: *const fn (context: *anyopaque, modelLineNumber: usize) []const usize,
    getWrappedTextIndentLength: *const fn (context: *anyopaque, modelLineNumber: usize) usize,
    getBaseViewLineNumber: *const fn (context: *anyopaque, modelLineNumber: usize) usize,
};

pub const InjectedTextInlineDecorationsComputer = struct {
    allocator: Allocator,
    context: IInjectedTextInlineDecorationsComputerContext,

    pub fn init(allocator: Allocator, context: IInjectedTextInlineDecorationsComputerContext) InjectedTextInlineDecorationsComputer {
        return .{ .allocator = allocator, .context = context };
    }

    pub fn getInlineDecorations(self: *InjectedTextInlineDecorationsComputer, modelLineNumber: usize) !InlineDecorations {
        const injectionOffsets = self.context.getInjectionOffsets(self.context.context, modelLineNumber) orelse
            return .{ .allocator = self.allocator, .lines = try self.allocator.alloc([]InlineDecoration, 0) };

        const injectionOptions = self.context.getInjectionOptions(self.context.context, modelLineNumber) orelse
            return .{ .allocator = self.allocator, .lines = try self.allocator.alloc([]InlineDecoration, 0) };

        const breakOffsets = self.context.getBreakOffsets(self.context.context, modelLineNumber);
        const lineInlineDecorations = try self.allocator.alloc(ArrayList(InlineDecoration), breakOffsets.len);
        var initialized: usize = 0;
        errdefer {
            for (lineInlineDecorations[0..initialized]) |*list| list.deinit();
            self.allocator.free(lineInlineDecorations);
        }
        for (lineInlineDecorations) |*list| {
            list.* = ArrayList(InlineDecoration).init(self.allocator);
            initialized += 1;
        }

        var totalInjectedTextLengthBefore: usize = 0;
        var currentInjectedOffset: usize = 0;
        const wrappedIndentLength = self.context.getWrappedTextIndentLength(self.context.context, modelLineNumber);

        for (0..breakOffsets.len) |outputLineIndex| {
            const lineStartOffset = if (outputLineIndex > 0) breakOffsets[outputLineIndex - 1] else 0;
            const lineEndOffset = breakOffsets[outputLineIndex];

            while (currentInjectedOffset < injectionOffsets.len) {
                const options = injectionOptions[currentInjectedOffset];
                const length = options.content.len;
                const injectedTextStartOffset = injectionOffsets[currentInjectedOffset] + totalInjectedTextLengthBefore;
                const injectedTextEndOffset = injectedTextStartOffset + length;
                const isWidthOnly = length == 0 and options.widthInEm != null;
                const isLastOutputLine = outputLineIndex == breakOffsets.len - 1;
                const isAtInternalWrapBoundary = injectedTextStartOffset == lineEndOffset and !isLastOutputLine;

                if (injectedTextStartOffset > lineEndOffset or (isWidthOnly and isAtInternalWrapBoundary)) {
                    break;
                }

                const isInLine = if (isWidthOnly)
                    lineStartOffset <= injectedTextStartOffset and
                        (injectedTextStartOffset < lineEndOffset or isLastOutputLine)
                else
                    lineStartOffset < injectedTextEndOffset;

                if (isInLine) {
                    if (options.inlineClassName) |inlineClassName| {
                        const indent = if (outputLineIndex > 0) wrappedIndentLength else 0;
                        const start = indent + (injectedTextStartOffset -| lineStartOffset);
                        const end = indent + @min(injectedTextEndOffset -| lineStartOffset, lineEndOffset - lineStartOffset);
                        if (start != end or isWidthOnly) {
                            const viewLineNumber = self.context.getBaseViewLineNumber(self.context.context, modelLineNumber) + outputLineIndex;
                            const range = Range.init(viewLineNumber, start + 1, viewLineNumber, end + 1);
                            const decoration_type: InlineDecorationType = if (isWidthOnly)
                                .WidthOnly
                            else if (options.inlineClassNameAffectsLetterSpacing)
                                .RegularAffectingLetterSpacing
                            else
                                .Regular;
                            try lineInlineDecorations[outputLineIndex].append(InlineDecoration.init(range, inlineClassName, decoration_type));
                        }
                    }
                }

                if (injectedTextEndOffset <= lineEndOffset) {
                    totalInjectedTextLengthBefore += length;
                    currentInjectedOffset += 1;
                } else {
                    break;
                }
            }
        }

        const lines = try self.allocator.alloc([]InlineDecoration, breakOffsets.len);
        var converted: usize = 0;
        errdefer {
            for (lines[0..converted]) |line| {
                if (line.len > 0) self.allocator.free(line);
            }
            self.allocator.free(lines);
        }
        for (lineInlineDecorations, 0..) |*list, i| {
            lines[i] = try list.toOwnedSlice();
            converted += 1;
        }
        for (lineInlineDecorations) |*list| list.deinit();
        self.allocator.free(lineInlineDecorations);

        return .{ .allocator = self.allocator, .lines = lines };
    }
};
