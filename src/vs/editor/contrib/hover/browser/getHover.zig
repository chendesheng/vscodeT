// Port of the portable provider aggregation from
// `src/vs/editor/contrib/hover/browser/getHover.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Position = @import("../../../common/core/position.zig").Position;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const languages = @import("../../../common/languages.zig");
const Hover = languages.Hover;
const HoverProvider = languages.HoverProvider;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;

pub const HoverProviderResult = struct {
    provider: HoverProvider,
    hover: Hover,
    ordinal: usize,
};

/// Does not throw or reject; invalid provider results are skipped.
fn executeProvider(
    provider: HoverProvider,
    ordinal: usize,
    model: *TextModel,
    position: Position,
    token: CancellationToken,
    hover_context: ?*const languages.HoverContext,
) ?HoverProviderResult {
    const result = provider.provide_hover(provider.context, model, position, token, hover_context) catch return null;
    const hover = result orelse return null;
    if (!isValid(hover)) return null;
    return .{ .provider = provider, .hover = hover, .ordinal = ordinal };
}

pub fn getHoverProviderResults(
    allocator: Allocator,
    providers: []const HoverProvider,
    model: *TextModel,
    position: Position,
    token: CancellationToken,
    hover_context: ?*const languages.HoverContext,
) ![]HoverProviderResult {
    var result = ArrayList(HoverProviderResult).init(allocator);
    errdefer result.deinit();
    for (providers, 0..) |provider, index| {
        if (executeProvider(provider, index, model, position, token, hover_context)) |item| {
            try result.append(item);
        }
    }
    return try result.toOwnedSlice();
}

pub fn getHovers(
    allocator: Allocator,
    providers: []const HoverProvider,
    model: *TextModel,
    position: Position,
    token: CancellationToken,
    hover_context: ?*const languages.HoverContext,
) ![]Hover {
    const results = try getHoverProviderResults(allocator, providers, model, position, token, hover_context);
    defer allocator.free(results);

    var hovers = ArrayList(Hover).init(allocator);
    errdefer hovers.deinit();
    for (results) |result| try hovers.append(result.hover);
    return try hovers.toOwnedSlice();
}

pub fn isValid(hover: Hover) bool {
    if (hover.range == null) return false;
    for (hover.contents) |content| {
        if (content.value.len > 0) return true;
    }
    return false;
}

test "getHover: aggregates valid provider results" {
    const std_testing = std.testing;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;

    const ProviderState = struct {
        text: []const u8,
        fail: bool = false,
        contents: [1]languages.IMarkdownString = undefined,

        fn provide(context: *anyopaque, model: *TextModel, position: Position, token: CancellationToken, hover_context: ?*const languages.HoverContext) anyerror!?Hover {
            _ = model;
            _ = position;
            _ = token;
            _ = hover_context;
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail) return error.ProviderFailed;
            self.contents[0] = .{ .value = self.text };
            return Hover{ .contents = &self.contents, .range = @import("../../../common/core/range.zig").Range.init(1, 1, 1, 2) };
        }
    };

    const allocator = std_testing.allocator;
    var ctx = try TestModel.init(allocator, "hello", "nullLanguage");
    defer ctx.deinit();

    var first = ProviderState{ .text = "first" };
    var second = ProviderState{ .text = "second" };
    var failing = ProviderState{ .text = "ignored", .fail = true };
    const providers = [_]HoverProvider{
        .{ .context = &first, .provide_hover = ProviderState.provide },
        .{ .context = &failing, .provide_hover = ProviderState.provide },
        .{ .context = &second, .provide_hover = ProviderState.provide },
    };

    const results = try getHoverProviderResults(allocator, &providers, ctx.model, Position.init(1, 1), CancellationToken.None, null);
    defer allocator.free(results);
    try std_testing.expectEqual(@as(usize, 2), results.len);
    try std_testing.expectEqual(@as(usize, 0), results[0].ordinal);
    try std_testing.expectEqual(@as(usize, 2), results[1].ordinal);
}
