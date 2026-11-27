// Port of `src/vs/editor/contrib/codeAction/test/browser/codeActionModel.test.ts`.
const std = @import("std");
const a = std.testing.allocator;
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TextModel = @import("../../../../common/model/textModel.zig").TextModel;
const Range = @import("../../../../common/core/range.zig").Range;
const Position = @import("../../../../common/core/position.zig").Position;
const languages = @import("../../../../common/languages.zig");
const Registry = @import("../../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.CodeActionProvider);
const MarkerService = @import("../../../../../platform/markers/common/markerService.zig").MarkerService;
const MarkerResource = @import("../../../../../platform/markers/common/markers.zig").Resource;
const Queue = @import("../../../../../base/common/windowDispatch.zig").Queue;
const CancellationToken = @import("../../../../../base/common/cancellation.zig").CancellationToken;
const Disposable = @import("../../../../../base/common/lifecycle.zig").IDisposable;
const ResourceConfiguration = @import("../../../../common/services/textResourceConfiguration.zig").ITextResourceConfigurationService;
const config = @import("../../../../../platform/configuration/common/configuration.zig");
const codeAction = @import("../../browser/codeAction.zig");
const codeActionModel = @import("../../browser/codeActionModel.zig");
const CodeActionModel = codeActionModel.CodeActionModel;

const Provider = struct {
    invoked: usize = 0,
    manual_disposed: usize = 0,
    only_manual: bool = false,
    delay_first: bool = false,
    nearby: bool = false,
    automatic: ?languages.CodeActionCallback = null,
    canceled: bool = false,
    const actions = [_]languages.CodeAction{.{ .title = "test", .kind = "quickfix", .command = .{ .id = "test-command", .title = "test" } }};
    fn provide(context: *anyopaque, allocator: std.mem.Allocator, _: *TextModel, range: Range, call: languages.CodeActionContext, _: CancellationToken) !languages.CodeActionList {
        const self: *Provider = @ptrCast(@alignCast(context));
        self.invoked += 1;
        if (self.nearby) {
            if (call.trigger_kind != 1 or (range.endColumn != 6 and range.endColumn != 11)) return .{};
            const items = try allocator.alloc(languages.CodeAction, 1);
            items[0] = .{ .title = if (range.endColumn == 6) "nearest" else "farther", .kind = "quickfix" };
            return .{ .actions = items };
        }
        if (call.trigger_kind == 2) return if (self.only_manual) .{} else .{ .actions = &actions };
        return .{ .actions = &actions, .disposable = Disposable.from(Provider, self, disposeManual) };
    }
    fn request(context: *anyopaque, allocator: std.mem.Allocator, model: *TextModel, range: Range, call: languages.CodeActionContext, token: CancellationToken, callback: languages.CodeActionCallback) !?Disposable {
        const self: *Provider = @ptrCast(@alignCast(context));
        if (self.delay_first and self.invoked == 0) {
            self.invoked += 1;
            self.automatic = callback;
            return Disposable.from(Provider, self, cancelAutomatic);
        }
        callback.complete(callback.context, provide(context, allocator, model, range, call, token));
        return null;
    }
    fn cancelAutomatic(self: *Provider) void {
        self.canceled = true;
        self.automatic = null;
    }
    fn disposeManual(self: *Provider) void {
        self.manual_disposed += 1;
    }
    fn resolveAutomatic(self: *Provider) void {
        if (self.automatic) |callback| callback.complete(callback.context, .{});
    }
};

const Fixture = struct {
    editor: *Editor,
    registry: Registry,
    markers: MarkerService,
    queue: Queue,
    model: ?*CodeActionModel = null,
    registration: ?Disposable = null,
    provider: Provider,
    triggered: usize = 0,
    result: ?*codeAction.ManagedCodeActionSet = null,
    trigger_type: ?languages.CodeActionTriggerType = null,
    include_nearby: bool = false,
    const nearby_enabled: config.Value = .{ .bool = true };
    fn getConfig(_: *anyopaque, _: *TextModel, key: []const u8) ?*const config.Value {
        return if (std.mem.eql(u8, key, "editor.codeActionWidget.includeNearbyQuickFixes")) &nearby_enabled else null;
    }
    fn updateConfig(_: *anyopaque, _: *TextModel, _: []const u8, _: ?config.Value, _: ?config.ConfigurationTarget) !void {}
    fn configuration(self: *Fixture) ResourceConfiguration {
        return .{ .context = self, .get_value = getConfig, .update_value = updateConfig };
    }
    fn init(self: *Fixture, provider: Provider) !void {
        self.* = .{ .editor = try Editor.createFromText(a, std.testing.io, "foobar  foo bar\nfarboo far boo", "path.txt", 80, 12), .registry = .init(a), .markers = .init(a), .queue = .{ .io = std.testing.io }, .provider = provider };
        errdefer self.deinit();
        self.registration = try self.registry.register(.{ .language = "*" }, .{ .context = &self.provider, .provide_code_actions = Provider.provide, .request_code_actions = Provider.request });
    }
    fn attach(self: *Fixture) !void {
        self.model = try CodeActionModel.create(a, self.editor, &self.registry, &self.markers, if (self.include_nearby) self.configuration() else null, &self.queue, self, changed);
    }
    fn deinit(self: *Fixture) void {
        if (self.model) |model| model.dispose();
        if (self.registration) |registration| registration.dispose();
        self.registry.deinit();
        self.markers.deinit();
        self.editor.deinit();
        a.destroy(self.editor);
        self.queue.deinitWindowEvents();
    }
    fn changed(context: *anyopaque, state: codeActionModel.CodeActionsState) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (state == .Triggered) {
            self.trigger_type = state.Triggered.trigger.type;
            if (state.Triggered.actions) |result| {
                self.result = result;
            } else self.triggered += 1;
        } else self.result = null;
    }
    fn flush(self: *Fixture) void {
        for (0..8) |_| _ = self.queue.dispatch(std.math.maxInt(i64));
    }
    fn marker(self: *Fixture) !void {
        var resource = try MarkerResource.fromUri(a, self.editor.model.uri());
        defer resource.deinit(a);
        try self.markers.changeOne("fake", resource, &.{.{ .start_line_number = 1, .start_column = 1, .end_line_number = 1, .end_column = 6, .message = "error", .severity = 1, .code = "", .source = "" }}, null);
    }
    fn expectAuto(self: *Fixture) !void {
        try std.testing.expectEqual(languages.CodeActionTriggerType.Auto, self.trigger_type.?);
        try std.testing.expectEqual(@as(usize, 1), self.result.?.valid_actions.len);
        try std.testing.expectEqual(@as(usize, 1), self.triggered);
    }
};

test "CodeActionModel: Oracle -> marker added" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.attach();
    f.flush();
    f.triggered = 0;
    try f.marker();
    f.flush();
    try f.expectAuto();
}

test "CodeActionModel: Oracle -> position changed" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.marker();
    try f.editor.setPosition(Position.init(2, 1));
    try f.attach();
    f.flush();
    f.triggered = 0;
    try f.editor.setPosition(Position.init(1, 1));
    f.flush();
    try f.expectAuto();
}

test "CodeActionModel: Oracle -> should only auto trigger once for cursor and marker update right after each other" {
    var f: Fixture = undefined;
    try f.init(.{});
    defer f.deinit();
    try f.attach();
    f.flush();
    f.triggered = 0;
    try f.marker();
    try f.editor.setSelection(Range.init(1, 1, 2, 1));
    f.flush();
    try f.expectAuto();
}

test "CodeActionModel: disposes manually triggered code actions when the editor model is cleared" {
    var f: Fixture = undefined;
    try f.init(.{ .only_manual = true });
    defer f.deinit();
    try f.attach();
    f.model.?.trigger(.{ .type = .Invoke, .trigger_action = .Default });
    f.flush();
    try std.testing.expectEqual(languages.CodeActionTriggerType.Invoke, f.trigger_type.?);
    try std.testing.expectEqual(@as(usize, 1), f.result.?.valid_actions.len);
    try f.editor.setModel(null);
    try std.testing.expectEqual(@as(usize, 1), f.provider.manual_disposed);
}

fn assertClaimedManualActionsSurvive(claim_before_automatic: bool) !void {
    var f: Fixture = undefined;
    try f.init(.{ .delay_first = true });
    defer f.deinit();
    f.include_nearby = true;
    try f.attach();
    try std.testing.expect(f.provider.automatic != null);
    f.model.?.trigger(.{ .type = .Invoke, .trigger_action = .QuickFix });
    f.flush();
    try std.testing.expectEqual(languages.CodeActionTriggerType.Invoke, f.trigger_type.?);
    const result = f.result.?;
    var claimed = if (claim_before_automatic) f.model.?.takeCodeActions(result) else null;
    try std.testing.expect(f.provider.canceled);
    f.provider.resolveAutomatic();
    f.flush();
    if (claimed == null) claimed = f.model.?.takeCodeActions(result);
    try std.testing.expect(claimed != null);
    try std.testing.expectEqual(@as(usize, 0), f.provider.manual_disposed);
    claimed.?.dispose();
    try std.testing.expectEqual(@as(usize, 1), f.provider.manual_disposed);
}

test "CodeActionModel: does not dispose claimed manual code actions when a canceled automatic request completes" {
    try assertClaimedManualActionsSurvive(true);
}

test "CodeActionModel: does not replace manual code actions when a canceled automatic request completes before claim" {
    try assertClaimedManualActionsSurvive(false);
}

test "CodeActionModel: nearest manual quick fixes query diagnostic ends on the current line" {
    var f: Fixture = undefined;
    try f.init(.{ .nearby = true });
    defer f.deinit();
    f.include_nearby = true;
    try f.marker();
    var resource = try MarkerResource.fromUri(a, f.editor.model.uri());
    defer resource.deinit(a);
    try f.markers.changeOne("another", resource, &.{ .{ .start_line_number = 1, .start_column = 9, .end_line_number = 1, .end_column = 11, .message = "second" }, .{ .start_line_number = 2, .start_column = 1, .end_line_number = 2, .end_column = 6, .message = "other line" } }, null);
    try f.editor.setPosition(Position.init(1, 4));
    try f.attach();
    f.model.?.trigger(.{ .type = .Invoke, .trigger_action = .QuickFix });
    f.flush();
    const result = f.result.?;
    try std.testing.expectEqual(@as(usize, 2), result.valid_actions.len);
    try std.testing.expectEqualStrings("nearest", result.valid_actions[0].action.title);
    try std.testing.expectEqualStrings("farther", result.valid_actions[1].action.title);
    try std.testing.expectEqual(@as(usize, 2), result.all_actions.len);
}
