// Port of `src/vs/platform/keybinding/test/common/keybindingResolver.test.ts`.
//
// Current subset: resolution basics and the core removal matrix. The upstream
// issue-regression cases, the alias suite and the resolve-command suite are
// ported incrementally (see `docs/porting-inventory.md`, P3).
//
// Terminal adaptation: items and their resolved keybindings are heap-owned by
// the harness so the interface context stays stable; expected item lists are
// compared by command (the upstream `deepStrictEqual` also compares chords and
// `when`, which are covered by the construction helpers).
const std = @import("std");
const Allocator = std.mem.Allocator;
const key_codes = @import("../../../../base/common/keyCodes.zig");
const key_bindings = @import("../../../../base/common/keybindings.zig");
const platform = @import("../../../../base/common/platform.zig");
const contextkey = @import("../../../contextkey/common/contextkey.zig");
const item_module = @import("../../common/resolvedKeybindingItem.zig");
const resolver_module = @import("../../common/keybindingResolver.zig");
const us_module = @import("../../common/usLayoutResolvedKeybinding.zig");

const ResolvedKeybindingItem = item_module.ResolvedKeybindingItem;
const KeybindingResolver = resolver_module.KeybindingResolver;
const ResultKind = resolver_module.ResultKind;
const USLayoutResolvedKeybinding = us_module.USLayoutResolvedKeybinding;

const TestItem = struct {
    resolved: ?USLayoutResolvedKeybinding,
    item: ResolvedKeybindingItem,

    fn init(self: *TestItem, allocator: Allocator, encoded: ?u32, command: ?[]const u8, args: ?*const anyopaque, when: ?*const contextkey.Expr, is_default: bool) !void {
        if (encoded) |value| {
            const decoded = (try key_bindings.decodeKeybinding(allocator, .{ .single = value }, platform.OS)).?;
            defer key_bindings.freeChords(allocator, decoded);
            self.resolved = (try USLayoutResolvedKeybinding.resolveKeybinding(allocator, decoded, platform.OS)).?;
            self.item = try ResolvedKeybindingItem.init(allocator, self.resolved.?.interface(), command, args, when, is_default, null, false, false);
        } else {
            self.resolved = null;
            self.item = try ResolvedKeybindingItem.init(allocator, null, command, args, when, is_default, null, false, false);
        }
    }

    fn deinit(self: *TestItem, allocator: Allocator) void {
        self.item.deinit(allocator);
        if (self.resolved) |*resolved| resolved.deinit();
    }
};

const Harness = struct {
    allocator: Allocator,
    factory: contextkey.ContextKeyExpr,
    items: std.array_list.Managed(*TestItem),

    fn init(allocator: Allocator) Harness {
        return .{
            .allocator = allocator,
            .factory = contextkey.ContextKeyExpr.init(allocator),
            .items = std.array_list.Managed(*TestItem).init(allocator),
        };
    }

    fn deinit(self: *Harness) void {
        for (self.items.items) |item| {
            item.deinit(self.allocator);
            self.allocator.destroy(item);
        }
        self.items.deinit();
        self.factory.deinit();
    }

    fn kb(self: *Harness, encoded: ?u32, command: ?[]const u8, args: ?*const anyopaque, when: ?*const contextkey.Expr, is_default: bool) !*TestItem {
        const item = try self.allocator.create(TestItem);
        errdefer self.allocator.destroy(item);
        try item.init(self.allocator, encoded, command, args, when, is_default);
        try self.items.append(item);
        return item;
    }

    fn eq(self: *Harness, key: []const u8, value: []const u8) !*const contextkey.Expr {
        return self.factory.equals(key, .{ .string = value });
    }
};

const TestContext = struct {
    values: std.StringHashMap(contextkey.ContextKeyValue),

    fn init(allocator: Allocator) TestContext {
        return .{ .values = std.StringHashMap(contextkey.ContextKeyValue).init(allocator) };
    }

    fn deinit(self: *TestContext) void {
        self.values.deinit();
    }

    fn context(self: *TestContext) contextkey.IContext {
        return .{ .context = self, .get_value = getValue };
    }

    fn getValue(context_ptr: *anyopaque, key: []const u8) contextkey.ContextKeyValue {
        const self: *TestContext = @ptrCast(@alignCast(context_ptr));
        return self.values.get(key) orelse .undefined_value;
    }
};

fn expectCommands(actual: []const *const ResolvedKeybindingItem, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |item, command| {
        try std.testing.expect(item.command != null);
        try std.testing.expectEqualStrings(command, item.command.?);
    }
}

fn removals(allocator: Allocator, rules: []const *const ResolvedKeybindingItem) ![]const *const ResolvedKeybindingItem {
    return KeybindingResolver.handleRemovals(allocator, rules);
}

test "resolve key" {
    const allocator = std.testing.allocator;
    var harness = Harness.init(allocator);
    defer harness.deinit();

    const when = try harness.eq("bar", "baz");
    const item = try harness.kb(key_codes.KeyMod.CtrlCmd | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyZ), "yes", null, when, true);

    const defaults = [_]*const ResolvedKeybindingItem{&item.item};
    var resolver = try KeybindingResolver.init(allocator, &defaults, &.{});
    defer resolver.deinit();

    var context = TestContext.init(allocator);
    defer context.deinit();
    try context.values.put("bar", .{ .string = "baz" });

    const found = try resolver.resolve(context.context(), &.{}, item.item.chords[0]);
    try std.testing.expectEqual(ResultKind.KbFound, found.kind);
    try std.testing.expectEqualStrings("yes", found.commandId.?);

    try context.values.put("bar", .{ .string = "bz" });
    const missing = try resolver.resolve(context.context(), &.{}, item.item.chords[0]);
    try std.testing.expectEqual(ResultKind.NoMatchingKb, missing.kind);
}

test "resolve key with arguments" {
    const allocator = std.testing.allocator;
    var harness = Harness.init(allocator);
    defer harness.deinit();

    const when = try harness.eq("bar", "baz");
    const args: u8 = 42;
    const item = try harness.kb(@backingInt(key_codes.KeyCode.KeyZ), "yes", &args, when, true);

    const defaults = [_]*const ResolvedKeybindingItem{&item.item};
    var resolver = try KeybindingResolver.init(allocator, &defaults, &.{});
    defer resolver.deinit();

    var context = TestContext.init(allocator);
    defer context.deinit();
    try context.values.put("bar", .{ .string = "baz" });

    const found = try resolver.resolve(context.context(), &.{}, item.item.chords[0]);
    try std.testing.expectEqual(ResultKind.KbFound, found.kind);
    try std.testing.expect(found.commandArgs == @as(?*const anyopaque, &args));
}

test "handleRemovals - simple 1" {
    const allocator = std.testing.allocator;
    var harness = Harness.init(allocator);
    defer harness.deinit();

    const a = try harness.kb(@backingInt(key_codes.KeyCode.KeyA), "yes1", null, try harness.eq("1", "a"), true);
    const b = try harness.kb(@backingInt(key_codes.KeyCode.KeyB), "yes2", null, try harness.eq("2", "b"), false);
    const rules = [_]*const ResolvedKeybindingItem{ &a.item, &b.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try expectCommands(result, &.{ "yes1", "yes2" });
}

test "handleRemovals - simple 2" {
    const allocator = std.testing.allocator;
    var harness = Harness.init(allocator);
    defer harness.deinit();

    const a = try harness.kb(@backingInt(key_codes.KeyCode.KeyA), "yes1", null, try harness.eq("1", "a"), true);
    const b = try harness.kb(@backingInt(key_codes.KeyCode.KeyB), "yes2", null, try harness.eq("2", "b"), true);
    const c = try harness.kb(@backingInt(key_codes.KeyCode.KeyC), "yes3", null, try harness.eq("3", "c"), false);
    const rules = [_]*const ResolvedKeybindingItem{ &a.item, &b.item, &c.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try expectCommands(result, &.{ "yes1", "yes2", "yes3" });
}

test "handleRemovals - removal with not matching when" {
    const allocator = std.testing.allocator;
    var harness = Harness.init(allocator);
    defer harness.deinit();

    const a = try harness.kb(@backingInt(key_codes.KeyCode.KeyA), "yes1", null, try harness.eq("1", "a"), true);
    const b = try harness.kb(@backingInt(key_codes.KeyCode.KeyB), "yes2", null, try harness.eq("2", "b"), true);
    const removal = try harness.kb(@backingInt(key_codes.KeyCode.KeyA), "-yes1", null, try harness.eq("1", "b"), false);
    const rules = [_]*const ResolvedKeybindingItem{ &a.item, &b.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try expectCommands(result, &.{ "yes1", "yes2" });
}

test "handleRemovals - removal with not matching keybinding" {
    const allocator = std.testing.allocator;
    var harness = Harness.init(allocator);
    defer harness.deinit();

    const a = try harness.kb(@backingInt(key_codes.KeyCode.KeyA), "yes1", null, try harness.eq("1", "a"), true);
    const b = try harness.kb(@backingInt(key_codes.KeyCode.KeyB), "yes2", null, try harness.eq("2", "b"), true);
    const removal = try harness.kb(@backingInt(key_codes.KeyCode.KeyB), "-yes1", null, try harness.eq("1", "a"), false);
    const rules = [_]*const ResolvedKeybindingItem{ &a.item, &b.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try expectCommands(result, &.{ "yes1", "yes2" });
}

test "handleRemovals - removal with matching keybinding and when" {
    const allocator = std.testing.allocator;
    var harness = Harness.init(allocator);
    defer harness.deinit();

    const a = try harness.kb(@backingInt(key_codes.KeyCode.KeyA), "yes1", null, try harness.eq("1", "a"), true);
    const b = try harness.kb(@backingInt(key_codes.KeyCode.KeyB), "yes2", null, try harness.eq("2", "b"), true);
    const removal = try harness.kb(@backingInt(key_codes.KeyCode.KeyA), "-yes1", null, try harness.eq("1", "a"), false);
    const rules = [_]*const ResolvedKeybindingItem{ &a.item, &b.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try expectCommands(result, &.{"yes2"});
}

test "handleRemovals - removal with unspecified keybinding" {
    const allocator = std.testing.allocator;
    var harness = Harness.init(allocator);
    defer harness.deinit();

    const a = try harness.kb(@backingInt(key_codes.KeyCode.KeyA), "yes1", null, try harness.eq("1", "a"), true);
    const b = try harness.kb(@backingInt(key_codes.KeyCode.KeyB), "yes2", null, try harness.eq("2", "b"), true);
    const removal = try harness.kb(null, "-yes1", null, try harness.eq("1", "a"), false);
    const rules = [_]*const ResolvedKeybindingItem{ &a.item, &b.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try expectCommands(result, &.{"yes2"});
}

test "handleRemovals - removal with unspecified when" {
    const allocator = std.testing.allocator;
    var harness = Harness.init(allocator);
    defer harness.deinit();

    const a = try harness.kb(@backingInt(key_codes.KeyCode.KeyA), "yes1", null, try harness.eq("1", "a"), true);
    const b = try harness.kb(@backingInt(key_codes.KeyCode.KeyB), "yes2", null, try harness.eq("2", "b"), true);
    const removal = try harness.kb(@backingInt(key_codes.KeyCode.KeyA), "-yes1", null, null, false);
    const rules = [_]*const ResolvedKeybindingItem{ &a.item, &b.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try expectCommands(result, &.{"yes2"});
}

test "handleRemovals - removal with unspecified when and unspecified keybinding" {
    const allocator = std.testing.allocator;
    var harness = Harness.init(allocator);
    defer harness.deinit();

    const a = try harness.kb(@backingInt(key_codes.KeyCode.KeyA), "yes1", null, try harness.eq("1", "a"), true);
    const b = try harness.kb(@backingInt(key_codes.KeyCode.KeyB), "yes2", null, try harness.eq("2", "b"), true);
    const removal = try harness.kb(null, "-yes1", null, null, false);
    const rules = [_]*const ResolvedKeybindingItem{ &a.item, &b.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try expectCommands(result, &.{"yes2"});
}

test "handleRemovals - issue #138997 removal in default list" {
    const allocator = std.testing.allocator;
    var harness = Harness.init(allocator);
    defer harness.deinit();

    const a = try harness.kb(@backingInt(key_codes.KeyCode.KeyA), "yes1", null, null, true);
    const b = try harness.kb(@backingInt(key_codes.KeyCode.KeyB), "yes2", null, null, true);
    const removal = try harness.kb(null, "-yes1", null, null, false);
    const rules = [_]*const ResolvedKeybindingItem{ &a.item, &b.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try expectCommands(result, &.{"yes2"});
}
