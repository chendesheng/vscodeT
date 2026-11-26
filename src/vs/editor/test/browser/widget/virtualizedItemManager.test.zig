// Port of `src/vs/editor/test/browser/widget/virtualizedItemManager.test.ts`.
// Zig's explicit binding destruction and testing allocator replace the
// JavaScript WeakRef/GC assertions.
const std = @import("std");
const testing = std.testing;
const vm = @import("../../../browser/widget/multiDiffEditor/virtualizedItemManager.zig");
const scroll = @import("../../../browser/widget/multiDiffEditor/compressedVirtualizedScrollView.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const OffsetRange = @import("../../../common/core/ranges/offsetRange.zig").OffsetRange;

const Item = struct {
    id: []const u8,
    height: usize,
    template_id: []const u8 = "test",
    change: Emitter(void) = .init(testing.allocator),
    bindings: usize = 0,
    keep_alive: bool = false,

    fn deinit(self: *Item) void {
        std.debug.assert(self.bindings == 0);
        self.change.deinit();
    }
};

const Binding = struct {
    item: *Item,
    owner: *Fixture,
    context: vm.IVirtualizedItemBindingContext,
    pub fn size(self: *Binding) usize {
        return self.item.height;
    }
    pub fn maxScroll(_: *Binding) usize {
        return 0;
    }
    pub fn shouldKeepAlive(self: *Binding) bool {
        return self.item.keep_alive;
    }
    pub fn render(_: *Binding, _: OffsetRange, _: usize, _: usize, _: OffsetRange) !void {}
    pub fn hide(_: *Binding) void {}
    pub fn destroy(self: *Binding) void {
        self.item.bindings -= 1;
        self.owner.destroyed_bindings += 1;
        testing.allocator.destroy(self);
    }
};

const Template = struct {
    owner: *Fixture,
    virtualized_template: vm.VirtualizedItemTemplate(Item, Binding),
    pub fn createBinding(self: *Template, item: *Item, context: vm.IVirtualizedItemBindingContext) !*Binding {
        self.owner.attempts[self.owner.attempt_count] = item.id;
        self.owner.attempt_count += 1;
        if (std.mem.eql(u8, self.owner.fail_item, item.id)) return error.FailedToBindA;
        const binding = try testing.allocator.create(Binding);
        binding.* = .{ .item = item, .owner = self.owner, .context = context };
        item.bindings += 1;
        return binding;
    }
    pub fn destroy(self: *Template) void {
        self.virtualized_template.deinit();
        self.owner.destroyed_templates += 1;
        testing.allocator.destroy(self);
    }
};

const Manager = vm.VirtualizedItemManager(Item, Binding, Template);
const Fixture = struct {
    queue: dispatch.Queue = .{ .io = testing.io },
    view: *scroll.CompressedVirtualizedScrollView = undefined,
    manager: *Manager = undefined,
    created_templates: usize = 0,
    destroyed_templates: usize = 0,
    destroyed_bindings: usize = 0,
    ids: [32][]const u8 = undefined,
    attempts: [32][]const u8 = undefined,
    attempt_count: usize = 0,
    errors: [8]anyerror = undefined,
    error_count: usize = 0,
    fail_item: []const u8 = "",

    fn self(context: *anyopaque) *Fixture {
        return @ptrCast(@alignCast(context));
    }
    fn id(_: *anyopaque, item: *Item) []const u8 {
        return item.id;
    }
    fn templateId(_: *anyopaque, item: *Item) []const u8 {
        return item.template_id;
    }
    fn unboundSize(_: *anyopaque, item: *Item) usize {
        return item.height;
    }
    fn unboundChange(_: *anyopaque, item: *Item) *Emitter(void) {
        return &item.change;
    }
    fn createTemplate(context: *anyopaque, template_id: []const u8) !*Template {
        const fixture = self(context);
        const template = try testing.allocator.create(Template);
        template.* = .{ .owner = fixture, .virtualized_template = .init(testing.allocator) };
        fixture.ids[fixture.created_templates] = template_id;
        fixture.created_templates += 1;
        return template;
    }
    fn reportError(context: *anyopaque, err: anyerror) void {
        const fixture = self(context);
        fixture.errors[fixture.error_count] = err;
        fixture.error_count += 1;
    }
    fn init(fixture: *Fixture, items: []const *Item) !void {
        fixture.view = try .create(testing.allocator, &fixture.queue, null);
        errdefer fixture.view.destroy();
        fixture.manager = try .create(testing.allocator, .{
            .context = fixture,
            .get_id = id,
            .get_template_id = templateId,
            .get_unbound_size = unboundSize,
            .on_unbound_change = unboundChange,
            .create_template = createTemplate,
            .on_unexpected_error = reportError,
        }, fixture.view);
        errdefer fixture.manager.destroy();
        try fixture.manager.setItems(items);
    }
    fn destroy(fixture: *Fixture) void {
        fixture.manager.destroy();
        fixture.view.destroy();
    }
};

const range = OffsetRange.init(0, 100);
fn noChange(_: *anyopaque) !void {}
fn bindingContext(fixture: *Fixture, height: usize) vm.IVirtualizedItemBindingContext {
    return .{ .initialSize = height, .render_context = null, .context = fixture, .on_did_change = noChange };
}

test "VirtualizedItemManager: strictly transfers a pooled template between typed bindings" {
    var a: Item = .{ .id = "a", .height = 100 };
    defer a.deinit();
    var b: Item = .{ .id = "b", .height = 200 };
    defer b.deinit();
    var f: Fixture = .{};
    try f.init(&.{ &a, &b });
    defer f.destroy();
    const va = f.manager.items[0];
    const vb = f.manager.items[1];
    va.render(range, 0, 800, range, null);
    const template = va.template.?;
    try testing.expectEqual(&a, va.binding().?.item);
    try testing.expectError(error.TemplateAlreadyBound, template.virtualized_template.bind(template, &b, bindingContext(&f, 200)));
    va.hide();
    vb.render(range, 0, 800, range, null);
    try testing.expectEqual(@as(usize, 1), f.created_templates);
    try testing.expectEqual(@as(usize, 1), f.destroyed_bindings);
    try testing.expectEqual(@as(usize, 0), a.bindings);
    try testing.expectEqual(template, vb.template.?);
    try testing.expectEqual(&b, template.virtualized_template.currentBinding.?.item);
    try testing.expectEqual(&b, vb.binding().?.item);
    try testing.expectEqual(@as(usize, 100), va.size());
    try testing.expectEqual(@as(usize, 200), vb.size());
}

test "VirtualizedItemManager: uses separate pools for different template IDs" {
    var a: Item = .{ .id = "a", .height = 100, .template_id = "text" };
    defer a.deinit();
    var b: Item = .{ .id = "b", .height = 200, .template_id = "image" };
    defer b.deinit();
    var f: Fixture = .{};
    try f.init(&.{ &a, &b });
    defer f.destroy();
    for (f.manager.items) |item| item.render(range, 0, 800, range, null);
    try testing.expectEqual(@as(usize, 2), f.created_templates);
    try testing.expectEqualStrings("text", f.ids[0]);
    try testing.expectEqualStrings("image", f.ids[1]);
}

test "VirtualizedItemManager: preserves a new binding when unbinding triggers synchronous template reuse" {
    var a: Item = .{ .id = "a", .height = 100 };
    defer a.deinit();
    var b: Item = .{ .id = "b", .height = 100 };
    defer b.deinit();
    var f: Fixture = .{};
    const template = try Fixture.createTemplate(&f, "test");
    defer template.destroy();
    const binding_a = try template.virtualized_template.bind(template, &a, bindingContext(&f, 100));
    const Observer = struct {
        template: *Template,
        fixture: *Fixture,
        item: *Item,
        binding: ?*Binding = null,
        fn changed(_: void, obs: *@This()) !void {
            if (obs.template.virtualized_template.currentBinding == null and obs.binding == null) {
                obs.binding = try obs.template.virtualized_template.bind(obs.template, obs.item, bindingContext(obs.fixture, 100));
            }
        }
    };
    var observer: Observer = .{ .template = template, .fixture = &f, .item = &b };
    const listener = try template.virtualized_template.on_did_change_binding.listen(&observer, Observer.changed);
    defer template.virtualized_template.on_did_change_binding.unlisten(listener);
    try template.virtualized_template.unbind(binding_a);
    try testing.expectEqual(&b, template.virtualized_template.currentBinding.?.item);
    try testing.expectEqual(@as(usize, 1), f.destroyed_bindings);
    try template.virtualized_template.unbind(observer.binding.?);
    try testing.expectEqual(@as(usize, 2), f.destroyed_bindings);
    try testing.expect(template.virtualized_template.currentBinding == null);
}

test "VirtualizedItemManager: manager disposal releases both active and idle templates" {
    var a: Item = .{ .id = "a", .height = 100 };
    defer a.deinit();
    var b: Item = .{ .id = "b", .height = 100 };
    defer b.deinit();
    var f: Fixture = .{};
    try f.init(&.{ &a, &b });
    for (f.manager.items) |item| item.render(range, 0, 800, range, null);
    f.manager.items[0].hide();
    f.destroy();
    try testing.expectEqual(@as(usize, 2), f.destroyed_bindings);
    try testing.expectEqual(@as(usize, 2), f.destroyed_templates);
    try testing.expectEqual(@as(usize, 0), a.bindings);
    try testing.expectEqual(@as(usize, 0), b.bindings);
}

test "VirtualizedItemManager: idle templates release previous bindings and items after repeated reuse" {
    var f: Fixture = .{};
    const template = try Fixture.createTemplate(&f, "test");
    defer template.destroy();
    for (0..20) |_| {
        var item: Item = .{ .id = "a", .height = 100 };
        defer item.deinit();
        const binding = try template.virtualized_template.bind(template, &item, bindingContext(&f, 100));
        try template.virtualized_template.unbind(binding);
        try testing.expect(template.virtualized_template.currentBinding == null);
        try testing.expectEqual(@as(usize, 0), item.bindings);
    }
    try testing.expectEqual(@as(usize, 20), f.destroyed_bindings);
}

test "VirtualizedItemManager: isolates a failed binding without changing cached layout state" {
    var a: Item = .{ .id = "a", .height = 100 };
    defer a.deinit();
    var b: Item = .{ .id = "b", .height = 200 };
    defer b.deinit();
    var f: Fixture = .{ .fail_item = "a" };
    try f.init(&.{ &a, &b });
    defer f.destroy();
    const va = f.manager.items[0];
    const vb = f.manager.items[1];
    va.render(range, 0, 800, range, null);
    va.render(range, 0, 800, range, null);
    vb.render(range, 0, 800, range, null);
    try testing.expectEqual(@as(usize, 2), f.attempt_count);
    try testing.expectEqualStrings("a", f.attempts[0]);
    try testing.expectEqualStrings("b", f.attempts[1]);
    try testing.expectEqualSlices(anyerror, &.{error.FailedToBindA}, f.errors[0..f.error_count]);
    try testing.expect(va.binding() == null);
    try testing.expectEqual(@as(usize, 100), va.size());
    try testing.expectEqual(&b, vb.binding().?.item);
}

test "VirtualizedItemManager: retained focused item releases on focus loss and preserves identity on reorder" {
    var a: Item = .{ .id = "a", .height = 100, .keep_alive = true };
    defer a.deinit();
    var b: Item = .{ .id = "b", .height = 100 };
    defer b.deinit();
    var f: Fixture = .{};
    try f.init(&.{ &a, &b });
    defer f.destroy();
    const va = f.manager.items[0];
    const vb = f.manager.items[1];
    va.render(range, 0, 800, range, null);
    va.hide();
    try testing.expect(va.binding() != null);
    a.keep_alive = false;
    const binding_context = va.binding().?.context;
    try binding_context.notifyChanged();
    try testing.expect(va.binding() == null);
    try f.manager.setItems(&.{ &b, &a });
    try testing.expectEqual(va, f.manager.items[1]);
    try testing.expectEqual(vb, f.manager.items[0]);
}
