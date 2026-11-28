// Coverage of `src/vs/editor/contrib/diffEditorBreadcrumbs/browser/contribution.ts`.
const std = @import("std");
const testing = std.testing;
const source = @import("../../browser/contribution.zig");
const Features = @import("../../../../common/services/languageFeaturesService.zig").LanguageFeaturesService;
const OutlineService = @import("../../../documentSymbols/browser/outlineModel.zig").OutlineModelService;
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TextModel = @import("../../../../common/model/textModel.zig").TextModel;
const Range = @import("../../../../common/core/range.zig").Range;
const LineRange = @import("../../../../common/core/ranges/lineRange.zig").LineRange;
const languages = @import("../../../../common/languages.zig");
const CancellationToken = @import("../../../../../base/common/cancellation.zig").CancellationToken;
const queue_mod = @import("../../../../../base/common/windowDispatch.zig");
const Disposable = @import("../../../../../base/common/lifecycle.zig").IDisposable;

const Provider = struct {
    calls: usize = 0,
    cancels: usize = 0,
    callback: ?languages.DocumentSymbolCallback = null,

    fn provide(context: *anyopaque, arena: std.mem.Allocator, _: *TextModel, _: CancellationToken) ![]const languages.DocumentSymbol {
        const self: *Provider = @ptrCast(@alignCast(context));
        self.calls += 1;
        const children = try arena.dupe(languages.DocumentSymbol, &.{
            symbol("inner", 2, 7), symbol("contained", 3, 4),
        });
        var outer = symbol("outer", 1, 9);
        outer.children = children;
        return arena.dupe(languages.DocumentSymbol, &.{ outer, symbol("outside", 6, 9) });
    }

    fn symbol(name: []const u8, start: usize, end: usize) languages.DocumentSymbol {
        return .{ .name = name, .kind = 5, .range = Range.init(start, 1, end, 1), .selection_range = Range.init(start, 1, start, 1) };
    }

    fn request(context: *anyopaque, _: std.mem.Allocator, _: *TextModel, callback: languages.DocumentSymbolCallback) !?Disposable {
        const self: *Provider = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.callback = callback;
        return .{ .context = self, .disposeFn = cancel };
    }

    fn cancel(context: *anyopaque) void {
        const self: *Provider = @ptrCast(@alignCast(context));
        self.cancels += 1;
        self.callback = null;
    }

    fn changed(context: *anyopaque) void {
        const count: *usize = @ptrCast(@alignCast(context));
        count.* += 1;
    }
};

test "diffEditorBreadcrumbs: nested crossing symbols are sorted by span and refresh is debounced" {
    const a = testing.allocator;
    var features = Features.init(a);
    defer features.deinit();
    var queue: queue_mod.Queue = .{ .io = testing.io };
    defer queue.deinitWindowEvents();
    var models = OutlineService.init(a, std.testing.io);
    defer models.deinit();
    models.attachWindow(&queue);
    const editor = try Editor.createFromText(a, testing.io, "a\nb\nc\nd\ne\nf\ng\nh\ni", "source.txt", 60, 10);
    defer {
        editor.deinit();
        a.destroy(editor);
    }
    var provider: Provider = .{};
    const registration = try features.document_symbol_provider.register(.{ .language = "*" }, .{ .context = &provider, .provide_document_symbols = Provider.provide });
    defer registration.dispose();
    var changes: usize = 0;
    const instance = try source.DiffEditorBreadcrumbsSource.create(a, editor.model, features.interface(), &models, .{ .context = &changes, .changed = Provider.changed });
    const api = instance.interface();
    defer api.dispose();
    try testing.expectEqual(1, provider.calls);
    try testing.expectEqual(1, changes);
    const items = try api.get_breadcrumb_items(api.context, a, LineRange.init(1, 5));
    defer a.free(items);
    try testing.expectEqual(2, items.len);
    try testing.expectEqualStrings("outer", items[0].name);
    try testing.expectEqualStrings("inner", items[1].name);
    try testing.expectEqual(2, items[1].start_line_number);
    const at = try api.get_at(api.context, a, 4);
    defer a.free(at);
    try testing.expectEqual(2, at.len); // the end line is exclusive
    try testing.expectEqualStrings("outer", at[0].name);
    try testing.expectEqualStrings("inner", at[1].name);
    try editor.insertText("x");
    try editor.insertText("y");
    try testing.expectEqual(1, provider.calls);
    try testing.expectEqual(1, models.timers.items.len);
    _ = queue.dispatch(std.math.maxInt(i64));
    try testing.expectEqual(2, provider.calls);
    try testing.expectEqual(2, changes);
}

test "diffEditorBreadcrumbs: provider requests cancel on refresh and disposal" {
    const a = testing.allocator;
    var features = Features.init(a);
    defer features.deinit();
    var queue: queue_mod.Queue = .{ .io = testing.io };
    defer queue.deinitWindowEvents();
    var models = OutlineService.init(a, std.testing.io);
    defer models.deinit();
    models.attachWindow(&queue);
    const editor = try Editor.createFromText(a, testing.io, "a\nb", "source.txt", 60, 10);
    defer {
        editor.deinit();
        a.destroy(editor);
    }
    var provider: Provider = .{};
    const registration = try features.document_symbol_provider.register(.{ .language = "*" }, .{ .context = &provider, .provide_document_symbols = Provider.provide, .request_document_symbols = Provider.request });
    defer registration.dispose();
    var changes: usize = 0;
    const instance = try source.DiffEditorBreadcrumbsSource.create(a, editor.model, features.interface(), &models, .{ .context = &changes, .changed = Provider.changed });
    const api = instance.interface();
    var disposed = false;
    defer if (!disposed) api.dispose();
    try testing.expectEqual(1, provider.calls);
    try editor.insertText("x");
    _ = queue.dispatch(std.math.maxInt(i64));
    try testing.expectEqual(2, provider.calls);
    try testing.expectEqual(1, provider.cancels);
    try testing.expectEqual(0, changes);
    try editor.insertText("y");
    api.dispose();
    disposed = true;
    try testing.expectEqual(2, provider.cancels);
    try testing.expectEqual(0, models.timers.items.len);
    _ = queue.dispatch(std.math.maxInt(i64));
    try testing.expectEqual(2, provider.calls);
    try testing.expectEqual(0, changes);
}
