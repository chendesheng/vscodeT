const std = @import("std");
const Range = @import("../basics/range.zig").Range;
const Position = @import("../basics/position.zig").Position;
const TestModel = @import("../tokenizer/testSupport.zig").TestModel;
const ModelDecorationOptions = @import("../model.zig").ModelDecorationOptions;
const ModelDecoration = @import("../model.zig").ModelDecoration;
const InjectedTextOptions = @import("../model.zig").InjectedTextOptions;
const TrackedRangeStickiness = @import("../model.zig").TrackedRangeStickiness;
const IdentityCoordinatesConverter = @import("../coordinatesConverter.zig").IdentityCoordinatesConverter;
const IInlineModelDecorationsComputerContext = @import("inlineDecorations.zig").IInlineModelDecorationsComputerContext;
const IInjectedTextInlineDecorationsComputerContext = @import("inlineDecorations.zig").IInjectedTextInlineDecorationsComputerContext;
const InlineModelDecorationsComputer = @import("inlineDecorations.zig").InlineModelDecorationsComputer;
const InjectedTextInlineDecorationsComputer = @import("inlineDecorations.zig").InjectedTextInlineDecorationsComputer;
const InlineDecorationType = @import("inlineDecorations.zig").InlineDecorationType;
const isModelDecorationVisible = @import("viewModelDecoration.zig").isModelDecorationVisible;

const DecorationContext = struct {
    decorations: []const ModelDecoration,

    fn get(context: *anyopaque, _: Range, _: bool, _: bool) []const ModelDecoration {
        const self: *DecorationContext = @ptrCast(@alignCast(context));
        return self.decorations;
    }
};

fn makeOptions(description: []const u8) ModelDecorationOptions {
    return ModelDecorationOptions.init(description, TrackedRangeStickiness.AlwaysGrowsWhenTypingAtEdges);
}

test "view model: identity coordinates converter" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "hello world", "nullLanguage");
    defer ctx.deinit();

    var converter = IdentityCoordinatesConverter.init(ctx.model);
    const interface = converter.toInterface();

    const position = interface.convertViewPositionToModelPosition(interface.context, Position.init(1, 3));
    try std.testing.expectEqual(@as(usize, 1), position.lineNumber);
    try std.testing.expectEqual(@as(usize, 3), position.column);

    const model_position = interface.convertModelPositionToViewPosition(interface.context, Position.init(1, 3), .None, false, false);
    try std.testing.expectEqual(@as(usize, 1), model_position.lineNumber);
    try std.testing.expectEqual(@as(usize, 3), model_position.column);

    const range = interface.convertModelRangeToViewRange(interface.context, Range.init(1, 2, 1, 4), .None);
    try std.testing.expectEqual(@as(usize, 2), range.startColumn);
    try std.testing.expectEqual(@as(usize, 4), range.endColumn);
    try std.testing.expect(converter.modelRangeIsVisible(Range.init(1, 1, 1, 2)));
    try std.testing.expect(!converter.modelRangeIsVisible(Range.init(2, 1, 2, 2)));
}

test "view model: decoration visibility hides comment and string tokens" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "// comment\n\"string\"", "zig");
    defer ctx.deinit();
    ctx.model.tokenization().forceTokenization(1);
    ctx.model.tokenization().forceTokenization(2);

    var comment_options = makeOptions("comment");
    comment_options.hideInCommentTokens = true;
    const comment_decoration = ModelDecoration{
        .id = 1,
        .ownerId = 0,
        .range = Range.init(1, 1, 1, 5),
        .options = &comment_options,
    };
    try std.testing.expect(!try isModelDecorationVisible(ctx.model, comment_decoration));

    var string_options = makeOptions("string");
    string_options.hideInStringTokens = true;
    const string_decoration = ModelDecoration{
        .id = 2,
        .ownerId = 0,
        .range = Range.init(2, 1, 2, 4),
        .options = &string_options,
    };
    try std.testing.expect(!try isModelDecorationVisible(ctx.model, string_decoration));

    const string_with_comment_options = ModelDecoration{
        .id = 3,
        .ownerId = 0,
        .range = Range.init(2, 1, 2, 4),
        .options = &comment_options,
    };
    try std.testing.expect(try isModelDecorationVisible(ctx.model, string_with_comment_options));
}

test "view model: computes regular, before, and after inline decorations" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "hello world", "nullLanguage");
    defer ctx.deinit();

    var options = makeOptions("test");
    options.inlineClassName = "inline-class";
    options.beforeContentClassName = "before-class";
    options.afterContentClassName = "after-class";
    options.affectsFont = true;

    const decorations = [_]ModelDecoration{.{
        .id = 1,
        .ownerId = 0,
        .range = Range.init(1, 2, 1, 6),
        .options = &options,
    }};
    var decoration_context = DecorationContext{ .decorations = &decorations };
    const context = IInlineModelDecorationsComputerContext{
        .context = &decoration_context,
        .getModelDecorations = DecorationContext.get,
    };

    var converter = IdentityCoordinatesConverter.init(ctx.model);
    var computer = InlineModelDecorationsComputer.init(allocator, context, ctx.model, converter.toInterface());
    defer computer.deinit();

    var result = try computer.getDecorations(Range.init(1, 1, 1, 12), false, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.decorations.len);
    try std.testing.expectEqual(@as(usize, 1), result.inlineDecorations.len);
    try std.testing.expectEqual(@as(usize, 3), result.inlineDecorations[0].len);
    try std.testing.expectEqual(InlineDecorationType.Regular, result.inlineDecorations[0][0].type);
    try std.testing.expectEqual(InlineDecorationType.Before, result.inlineDecorations[0][1].type);
    try std.testing.expectEqual(InlineDecorationType.After, result.inlineDecorations[0][2].type);
    try std.testing.expectEqualStrings("inline-class", result.inlineDecorations[0][0].inlineClassName);
    try std.testing.expect(result.hasVariableFonts[0]);

    try std.testing.expectEqual(@as(usize, 1), @as(usize, computer._decorationsCache.count()));
    var second = try computer.getDecorations(Range.init(1, 1, 1, 12), false, false);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), @as(usize, computer._decorationsCache.count()));
    computer.reset();
    try std.testing.expectEqual(@as(usize, 0), @as(usize, computer._decorationsCache.count()));
}

test "view model: only whole-line layouts affect all intersecting lines" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "line one\nline two\nline three", "nullLanguage");
    defer ctx.deinit();

    var options = makeOptions("multi");
    options.inlineClassName = "multi-line";
    options.isWholeLine = true;
    const decorations = [_]ModelDecoration{.{
        .id = 1,
        .ownerId = 0,
        .range = Range.init(1, 3, 3, 5),
        .options = &options,
    }};
    var decoration_context = DecorationContext{ .decorations = &decorations };
    const context = IInlineModelDecorationsComputerContext{
        .context = &decoration_context,
        .getModelDecorations = DecorationContext.get,
    };
    var converter = IdentityCoordinatesConverter.init(ctx.model);
    var computer = InlineModelDecorationsComputer.init(allocator, context, ctx.model, converter.toInterface());
    defer computer.deinit();

    var result = try computer.getDecorations(Range.init(1, 1, 3, 11), false, false);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.inlineDecorations.len);
    for (result.inlineDecorations) |line| {
        try std.testing.expectEqual(@as(usize, 1), line.len);
    }

    var inline_result = try computer.getInlineDecorations(1);
    defer inline_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), inline_result.lines.len);
    try std.testing.expectEqual(@as(usize, 1), inline_result.lines[0].len);
}

const InjectedContext = struct {
    options: []const InjectedTextOptions,
    offsets: ?[]const usize,
    breaks: []const usize,
    wrapped_indent: usize = 0,
    base_view_line: usize = 1,

    fn getOptions(context: *anyopaque, _: usize) ?[]const InjectedTextOptions {
        const self: *InjectedContext = @ptrCast(@alignCast(context));
        return self.options;
    }
    fn getOffsets(context: *anyopaque, _: usize) ?[]const usize {
        const self: *InjectedContext = @ptrCast(@alignCast(context));
        return self.offsets;
    }
    fn getBreaks(context: *anyopaque, _: usize) []const usize {
        const self: *InjectedContext = @ptrCast(@alignCast(context));
        return self.breaks;
    }
    fn getIndent(context: *anyopaque, _: usize) usize {
        const self: *InjectedContext = @ptrCast(@alignCast(context));
        return self.wrapped_indent;
    }
    fn getBaseViewLine(context: *anyopaque, _: usize) usize {
        const self: *InjectedContext = @ptrCast(@alignCast(context));
        return self.base_view_line;
    }
};

test "view model: injected text inline decorations" {
    const allocator = std.testing.allocator;
    const injection_options = [_]InjectedTextOptions{.{
        .content = "injected",
        .inlineClassName = "injected-class",
        .inlineClassNameAffectsLetterSpacing = false,
        .attachedData = null,
        .cursorStops = null,
    }};
    const offsets = [_]usize{5};
    const breaks = [_]usize{18};
    var context_data = InjectedContext{
        .options = &injection_options,
        .offsets = &offsets,
        .breaks = &breaks,
    };
    const context = IInjectedTextInlineDecorationsComputerContext{
        .context = &context_data,
        .getInjectionOptions = InjectedContext.getOptions,
        .getInjectionOffsets = InjectedContext.getOffsets,
        .getBreakOffsets = InjectedContext.getBreaks,
        .getWrappedTextIndentLength = InjectedContext.getIndent,
        .getBaseViewLineNumber = InjectedContext.getBaseViewLine,
    };
    var computer = InjectedTextInlineDecorationsComputer.init(allocator, context);
    var result = try computer.getInlineDecorations(1);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.lines.len);
    try std.testing.expectEqual(@as(usize, 1), result.lines[0].len);
    try std.testing.expectEqual(@as(usize, 6), result.lines[0][0].range.startColumn);
    try std.testing.expectEqual(@as(usize, 14), result.lines[0][0].range.endColumn);
    try std.testing.expectEqual(InlineDecorationType.Regular, result.lines[0][0].type);

    var empty_context_data = InjectedContext{
        .options = &injection_options,
        .offsets = null,
        .breaks = &breaks,
    };
    const empty_context = IInjectedTextInlineDecorationsComputerContext{
        .context = &empty_context_data,
        .getInjectionOptions = InjectedContext.getOptions,
        .getInjectionOffsets = InjectedContext.getOffsets,
        .getBreakOffsets = InjectedContext.getBreaks,
        .getWrappedTextIndentLength = InjectedContext.getIndent,
        .getBaseViewLineNumber = InjectedContext.getBaseViewLine,
    };
    var empty_computer = InjectedTextInlineDecorationsComputer.init(allocator, empty_context);
    var empty_result = try empty_computer.getInlineDecorations(1);
    defer empty_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_result.lines.len);
}

test "view model: injected width-only and wrapped decorations" {
    const allocator = std.testing.allocator;

    const width_options = [_]InjectedTextOptions{.{
        .content = "",
        .inlineClassName = "width-only",
        .inlineClassNameAffectsLetterSpacing = false,
        .attachedData = null,
        .cursorStops = null,
        .widthInEm = 3,
    }};
    const width_offsets = [_]usize{5};
    const width_breaks = [_]usize{6};
    var width_context_data = InjectedContext{
        .options = &width_options,
        .offsets = &width_offsets,
        .breaks = &width_breaks,
    };
    const width_context = IInjectedTextInlineDecorationsComputerContext{
        .context = &width_context_data,
        .getInjectionOptions = InjectedContext.getOptions,
        .getInjectionOffsets = InjectedContext.getOffsets,
        .getBreakOffsets = InjectedContext.getBreaks,
        .getWrappedTextIndentLength = InjectedContext.getIndent,
        .getBaseViewLineNumber = InjectedContext.getBaseViewLine,
    };
    var width_computer = InjectedTextInlineDecorationsComputer.init(allocator, width_context);
    var width_result = try width_computer.getInlineDecorations(1);
    defer width_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), width_result.lines[0].len);
    try std.testing.expectEqual(InlineDecorationType.WidthOnly, width_result.lines[0][0].type);
    try std.testing.expectEqual(@as(usize, 6), width_result.lines[0][0].range.startColumn);
    try std.testing.expectEqual(@as(usize, 6), width_result.lines[0][0].range.endColumn);

    const wrapped_options = [_]InjectedTextOptions{.{
        .content = "injected",
        .inlineClassName = "wrapped-class",
        .inlineClassNameAffectsLetterSpacing = true,
        .attachedData = null,
        .cursorStops = null,
    }};
    const wrapped_offsets = [_]usize{5};
    const wrapped_breaks = [_]usize{ 8, 15 };
    var wrapped_context_data = InjectedContext{
        .options = &wrapped_options,
        .offsets = &wrapped_offsets,
        .breaks = &wrapped_breaks,
        .wrapped_indent = 2,
    };
    const wrapped_context = IInjectedTextInlineDecorationsComputerContext{
        .context = &wrapped_context_data,
        .getInjectionOptions = InjectedContext.getOptions,
        .getInjectionOffsets = InjectedContext.getOffsets,
        .getBreakOffsets = InjectedContext.getBreaks,
        .getWrappedTextIndentLength = InjectedContext.getIndent,
        .getBaseViewLineNumber = InjectedContext.getBaseViewLine,
    };
    var wrapped_computer = InjectedTextInlineDecorationsComputer.init(allocator, wrapped_context);
    var wrapped_result = try wrapped_computer.getInlineDecorations(1);
    defer wrapped_result.deinit();

    try std.testing.expectEqual(@as(usize, 2), wrapped_result.lines.len);
    try std.testing.expectEqual(@as(usize, 1), wrapped_result.lines[0].len);
    try std.testing.expectEqual(@as(usize, 1), wrapped_result.lines[1].len);
    try std.testing.expectEqual(InlineDecorationType.RegularAffectingLetterSpacing, wrapped_result.lines[0][0].type);
    try std.testing.expectEqual(@as(usize, 6), wrapped_result.lines[0][0].range.startColumn);
    try std.testing.expectEqual(@as(usize, 9), wrapped_result.lines[0][0].range.endColumn);
    try std.testing.expectEqual(@as(usize, 3), wrapped_result.lines[1][0].range.startColumn);
    try std.testing.expectEqual(@as(usize, 8), wrapped_result.lines[1][0].range.endColumn);
}

test "view model: no decorations yields empty lines" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "hello world", "nullLanguage");
    defer ctx.deinit();

    const decorations = [_]ModelDecoration{};
    var decoration_context = DecorationContext{ .decorations = &decorations };
    const context = IInlineModelDecorationsComputerContext{
        .context = &decoration_context,
        .getModelDecorations = DecorationContext.get,
    };
    var converter = IdentityCoordinatesConverter.init(ctx.model);
    var computer = InlineModelDecorationsComputer.init(allocator, context, ctx.model, converter.toInterface());
    defer computer.deinit();

    var result = try computer.getDecorations(Range.init(1, 1, 1, 12), false, false);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.decorations.len);
    try std.testing.expectEqual(@as(usize, 1), result.inlineDecorations.len);
    try std.testing.expectEqual(@as(usize, 0), result.inlineDecorations[0].len);
    try std.testing.expect(!result.hasVariableFonts[0]);
}
