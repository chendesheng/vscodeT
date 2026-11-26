// Port of `src/vs/editor/contrib/codeAction/test/browser/codeAction.test.ts`.
const std = @import("std");
const a = std.testing.allocator;
const languages = @import("../../../../common/languages.zig");
const TextModel = @import("../../../../common/model/textModel.zig").TextModel;
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const Range = @import("../../../../common/core/range.zig").Range;
const Registry = @import("../../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.CodeActionProvider);
const Kind = @import("../../../../../base/common/hierarchicalKind.zig").HierarchicalKind;
const cancellation = @import("../../../../../base/common/cancellation.zig");
const Disposable = cancellation.IDisposable;
const types = @import("../../common/types.zig");
const codeAction = @import("../../browser/codeAction.zig");

const Provider = struct {
    actions: []const languages.CodeAction = &.{},
    kinds: ?[]const []const u8 = null,
    forward: bool = false,
    invoked: bool = false,
    asynchronous: bool = false,
    callback: ?languages.CodeActionCallback = null,
    token: cancellation.CancellationToken = .None,
    canceled: bool = false,
    releases: usize = 0,

    fn interface(self: *Provider) languages.CodeActionProvider {
        return .{ .context = self, .provided_kinds = self.kinds, .provide_code_actions = provide, .request_code_actions = if (self.asynchronous) request else null };
    }
    fn provide(context: *anyopaque, allocator: std.mem.Allocator, _: *TextModel, _: Range, call: languages.CodeActionContext, _: cancellation.CancellationToken) !languages.CodeActionList {
        const self: *Provider = @ptrCast(@alignCast(context));
        self.invoked = true;
        if (self.forward) {
            const actions = try allocator.alloc(languages.CodeAction, 1);
            actions[0] = .{ .title = call.only orelse "", .kind = call.only };
            return .{ .actions = actions };
        }
        return .{ .actions = self.actions, .disposable = Disposable.from(Provider, self, release) };
    }
    fn request(context: *anyopaque, _: std.mem.Allocator, _: *TextModel, _: Range, _: languages.CodeActionContext, token: cancellation.CancellationToken, callback: languages.CodeActionCallback) !?Disposable {
        const self: *Provider = @ptrCast(@alignCast(context));
        self.invoked = true;
        self.token = token;
        self.callback = callback;
        return Disposable.from(Provider, self, cancel);
    }
    fn cancel(self: *Provider) void {
        self.canceled = self.token.isCancellationRequested();
        self.callback = null;
    }
    fn release(self: *Provider) void {
        self.releases += 1;
    }
    fn resolve(self: *Provider) void {
        const callback = self.callback orelse return;
        self.callback = null;
        callback.complete(callback.context, .{ .actions = self.actions, .disposable = Disposable.from(Provider, self, release) });
    }
};

const Receiver = struct {
    result: ?*codeAction.ManagedCodeActionSet = null,
    failure: ?anyerror = null,
    fn ready(context: *anyopaque, value: anyerror!*codeAction.ManagedCodeActionSet) void {
        const self: *Receiver = @ptrCast(@alignCast(context));
        if (value) |result| self.result = result else |err| self.failure = err;
    }
    fn listener(self: *Receiver) codeAction.Listener {
        return .{ .context = self, .complete = ready };
    }
};

fn collect(registry: *Registry, model: *TextModel, filter: types.CodeActionFilter) !*codeAction.ManagedCodeActionSet {
    var receiver: Receiver = .{};
    const pending = try codeAction.getCodeActions(a, registry, model, Range.init(1, 1, 2, 1), .{ .type = .Auto, .trigger_action = .Default, .filter = filter }, .None, receiver.listener());
    try std.testing.expect(pending == null);
    return receiver.result orelse return receiver.failure orelse error.ExpectedActionSet;
}

fn expectTitles(result: *codeAction.ManagedCodeActionSet, titles: []const []const u8) !void {
    defer result.dispose();
    try std.testing.expectEqual(titles.len, result.valid_actions.len);
    for (titles, result.valid_actions) |expected, item| try std.testing.expectEqualStrings(expected, item.action.title);
}

test "CodeActions are sorted by type, #38623" {
    var model = try TestModel.init(a, "test1\ntest2\ntest3", "fooLang");
    defer model.deinit();
    var registry = Registry.init(a);
    defer registry.deinit();
    const marker = @import("../../../../../platform/markers/common/markers.zig").MarkerData{ .message = "abc" };
    var provider = Provider{ .actions = &.{
        .{ .title = "Extract to inner function in function \"test\"", .command = .{ .id = "1" } },
        .{ .title = "aTitle", .diagnostics = &.{marker} },
        .{ .title = "abc", .edit_json = .{ .null = {} } },
        .{ .title = "bcd", .command = .{ .id = "_internal_command_delegation" } },
        .{ .title = "abc", .command = .{ .id = "_internal_command_delegation" } },
        .{ .title = "bTitle", .diagnostics = &.{marker} },
    } };
    const registration = try registry.register(.{ .language = "fooLang" }, provider.interface());
    defer registration.dispose();
    try expectTitles(try collect(&registry, model.model, .{}), &.{ "aTitle", "bTitle", "Extract to inner function in function \"test\"", "abc", "bcd", "abc" });
    try std.testing.expectEqual(1, provider.releases);
}

test "getCodeActions should filter by scope" {
    var model = try TestModel.init(a, "test1\ntest2\ntest3", "fooLang");
    defer model.deinit();
    var registry = Registry.init(a);
    defer registry.deinit();
    var provider = Provider{ .actions = &.{ .{ .title = "a", .kind = "a" }, .{ .title = "b", .kind = "b" }, .{ .title = "a.b", .kind = "a.b" } } };
    const registration = try registry.register(.{ .language = "fooLang" }, provider.interface());
    defer registration.dispose();
    try expectTitles(try collect(&registry, model.model, .{ .include = .init("a") }), &.{ "a", "a.b" });
    try expectTitles(try collect(&registry, model.model, .{ .include = .init("a.b") }), &.{"a.b"});
    try expectTitles(try collect(&registry, model.model, .{ .include = .init("a.b.c") }), &.{});
}

test "getCodeActions should forward requested scope to providers" {
    var model = try TestModel.init(a, "test1\ntest2", "fooLang");
    defer model.deinit();
    var registry = Registry.init(a);
    defer registry.deinit();
    var provider = Provider{ .forward = true };
    const registration = try registry.register(.{ .language = "fooLang" }, provider.interface());
    defer registration.dispose();
    try expectTitles(try collect(&registry, model.model, .{ .include = .init("a") }), &.{"a"});
}

test "getCodeActions should not return source code action by default" {
    var model = try TestModel.init(a, "test1\ntest2", "fooLang");
    defer model.deinit();
    var registry = Registry.init(a);
    defer registry.deinit();
    var provider = Provider{ .actions = &.{ .{ .title = "a", .kind = "source" }, .{ .title = "b", .kind = "b" } } };
    const registration = try registry.register(.{ .language = "fooLang" }, provider.interface());
    defer registration.dispose();
    try expectTitles(try collect(&registry, model.model, .{}), &.{"b"});
    try expectTitles(try collect(&registry, model.model, .{ .include = types.CodeActionKind.Source, .include_source_actions = true }), &.{"a"});
}

test "getCodeActions should support filtering out some requested source code actions #84602" {
    var model = try TestModel.init(a, "test1\ntest2", "fooLang");
    defer model.deinit();
    var registry = Registry.init(a);
    defer registry.deinit();
    var provider = Provider{ .actions = &.{ .{ .title = "a", .kind = "source" }, .{ .title = "b", .kind = "source.test" }, .{ .title = "c", .kind = "c" } } };
    const registration = try registry.register(.{ .language = "fooLang" }, provider.interface());
    defer registration.dispose();
    try expectTitles(try collect(&registry, model.model, .{ .include = .init("source.test"), .excludes = &.{types.CodeActionKind.Source}, .include_source_actions = true }), &.{"b"});
}

test "getCodeActions no invoke a provider that has been excluded #84602" {
    var model = try TestModel.init(a, "test1\ntest2", "fooLang");
    defer model.deinit();
    var registry = Registry.init(a);
    defer registry.deinit();
    var first = Provider{ .actions = &.{.{ .title = "a", .kind = "refactor" }} };
    var excluded = Provider{ .actions = &.{.{ .title = "x", .kind = "refactor.sub" }}, .kinds = &.{"refactor.sub"} };
    const one = try registry.register(.{ .language = "fooLang" }, first.interface());
    defer one.dispose();
    const two = try registry.register(.{ .language = "fooLang" }, excluded.interface());
    defer two.dispose();
    try expectTitles(try collect(&registry, model.model, .{ .include = types.CodeActionKind.Refactor, .excludes = &.{Kind.init("refactor.sub")} }), &.{"a"});
    try std.testing.expect(!excluded.invoked);
}

test "getCodeActions should not invoke code action providers filtered out by providedCodeActionKinds" {
    var model = try TestModel.init(a, "test1\ntest2", "fooLang");
    defer model.deinit();
    var registry = Registry.init(a);
    defer registry.deinit();
    var provider = Provider{ .kinds = &.{"refactor"} };
    const registration = try registry.register(.{ .language = "fooLang" }, provider.interface());
    defer registration.dispose();
    try expectTitles(try collect(&registry, model.model, .{ .include = types.CodeActionKind.QuickFix }), &.{});
    try std.testing.expect(!provider.invoked);
}

test "getCodeActions: concurrent provider ordering and cancellation release cached results" {
    var model = try TestModel.init(a, "test1\ntest2", "fooLang");
    defer model.deinit();
    var registry = Registry.init(a);
    defer registry.deinit();
    var low = Provider{ .asynchronous = true, .actions = &.{.{ .title = "low" }} };
    var high = Provider{ .asynchronous = true, .actions = &.{.{ .title = "high" }} };
    const one = try registry.register(.{ .language = "*" }, low.interface());
    defer one.dispose();
    const two = try registry.register(.{ .language = "fooLang" }, high.interface());
    defer two.dispose();
    var receiver: Receiver = .{};
    var source = try cancellation.CancellationTokenSource.init(a);
    defer source.deinit();
    const trigger: types.CodeActionTrigger = .{ .type = .Invoke, .trigger_action = .Default };
    const token = try source.token();
    const first = try codeAction.getCodeActions(a, &registry, model.model, Range.init(1, 1, 2, 1), trigger, token, receiver.listener());
    try std.testing.expect(first != null and low.invoked and high.invoked);
    low.resolve();
    try std.testing.expect(receiver.result == null);
    high.resolve();
    try expectTitles(receiver.result.?, &.{ "high", "low" });
    receiver = .{};
    const second = try codeAction.getCodeActions(a, &registry, model.model, Range.init(1, 1, 2, 1), trigger, token, receiver.listener());
    try std.testing.expect(second != null);
    low.resolve();
    source.cancel();
    try std.testing.expect(receiver.failure.? == error.CancellationError);
    try std.testing.expect(high.canceled and high.callback == null);
    try std.testing.expectEqual(2, low.releases);
    try std.testing.expectEqual(1, high.releases);
}
