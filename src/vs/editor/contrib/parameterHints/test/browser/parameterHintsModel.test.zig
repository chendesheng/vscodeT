// Port of trigger, retrigger, cancellation and coalescing cases in
// `src/vs/editor/contrib/parameterHints/test/browser/parameterHintsModel.test.ts`.
const std = @import("std");
const Editor = @import("../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const languages = @import("../../../../common/languages.zig");
const TextModel = @import("../../../../common/model/textModel.zig").TextModel;
const Position = @import("../../../../common/core/position.zig").Position;
const Registry = @import("../../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.SignatureHelpProvider);
const CancellationToken = @import("../../../../../base/common/cancellation.zig").CancellationToken;
const IDisposable = @import("../../../../../base/common/lifecycle.zig").IDisposable;
const Queue = @import("../../../../../base/common/windowDispatch.zig").Queue;
const Model = @import("../../browser/parameterHintsModel.zig").ParameterHintsModel;
const Widget = @import("../../browser/parameterHintsWidget.zig");

const Probe = struct {
    calls: usize = 0,
    releases: usize = 0,
    last_kind: languages.SignatureHelpTriggerKind = .Invoke,
    last_character: ?[]const u8 = null,
    retriggered: bool = false,
    previous_signature: ?usize = null,
    const signatures = [_]languages.SignatureInformation{ .{ .label = "one", .parameters = &.{} }, .{ .label = "two", .parameters = &.{} } };

    fn provide(context: *anyopaque, _: std.mem.Allocator, _: *TextModel, _: Position, trigger: languages.SignatureHelpContext, _: CancellationToken) !?languages.SignatureHelpResult {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.last_kind = trigger.trigger_kind;
        self.last_character = trigger.trigger_character;
        self.retriggered = trigger.is_retrigger;
        self.previous_signature = if (trigger.active_signature_help) |help| help.active_signature else null;
        return .{ .value = .{ .signatures = &signatures, .active_signature = 0, .active_parameter = 0 }, .release = .{ .context = self, .disposeFn = release } };
    }
    fn release(context: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.releases += 1;
    }
    fn interface(self: *Probe) languages.SignatureHelpProvider {
        return .{ .context = self, .trigger_characters = &.{ "(", "[" }, .retrigger_characters = &.{","}, .provide_signature_help = provide };
    }
};

test "ParameterHintsModel: typed triggers coalesce, retrigger with previous signature, and cancel" {
    const a = std.testing.allocator;
    const editor = try Editor.createFromText(a, std.testing.io, "", "test.txt", 40, 8);
    defer {
        editor.deinit();
        a.destroy(editor);
    }
    var registry = Registry.init(a);
    defer registry.deinit();
    var probe: Probe = .{};
    const registration = try registry.register(.{ .language = "*" }, probe.interface());
    defer registration.dispose();
    var queue: Queue = .{ .io = std.testing.io };
    var model = Model.init(a, editor);
    defer model.deinit();
    try model.attach(&registry, &queue);
    try editor.typeCharacter("(");
    try editor.typeCharacter("x");
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    _ = queue.dispatch(std.math.maxInt(i64));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(languages.SignatureHelpTriggerKind.TriggerCharacter, probe.last_kind);
    try std.testing.expectEqualStrings("(", probe.last_character.?);
    try std.testing.expect(!probe.retriggered);
    model.move(true);
    try std.testing.expectEqual(@as(usize, 1), model.hints().?.active_signature);
    try editor.typeCharacter(",");
    _ = queue.dispatch(std.math.maxInt(i64));
    try std.testing.expect(probe.retriggered);
    try std.testing.expectEqualStrings(",", probe.last_character.?);
    try std.testing.expectEqual(@as(?usize, 1), probe.previous_signature);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
    model.cancel();
    try std.testing.expectEqual(@as(usize, 2), probe.releases);
    try std.testing.expect(model.hints() == null);
    try editor.typeCharacter(",");
    _ = queue.dispatch(std.math.maxInt(i64));
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try editor.typeCharacter("(");
    try editor.typeCharacter("[");
    _ = queue.dispatch(std.math.maxInt(i64));
    try std.testing.expectEqual(@as(usize, 3), probe.calls);
    try std.testing.expectEqualStrings("[", probe.last_character.?);
    try std.testing.expect(!probe.retriggered);
    model.configure(true, false);
    model.move(false);
    try std.testing.expect(model.hints() == null);
    try std.testing.expectEqual(@as(usize, 3), probe.releases);
}

test "ParameterHintsWidget: string and offset labels highlight exactly the active parameter" {
    const signature: languages.SignatureInformation = .{ .label = "f(é, b)", .parameters = &.{ .{ .label = .{ .offsets = .{ 2, 4 } } }, .{ .label = .{ .text = "b" } } } };
    try std.testing.expectEqual(@as(?[2]usize, .{ 2, 4 }), Widget.activeParameterLabel(signature, 0));
    try std.testing.expectEqual(@as(?[2]usize, .{ 6, 7 }), Widget.activeParameterLabel(signature, 1));
    try std.testing.expect(Widget.activeParameterLabel(signature, 2) == null);
}
