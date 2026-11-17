// Port of `src/vs/platform/keybinding/test/common/keybindingResolver.test.ts`.
//
// Ported in full: resolution basics, the removal matrix (including the
// issue-regression cases), `contextIsEntirelyIncluded`, the alias suite and the
// resolve-command/chord suites.
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

    fn init(self: *TestItem, allocator: Allocator, input: ?key_bindings.KeybindingInput, command: ?[]const u8, args: ?*const anyopaque, when: ?*const contextkey.Expr, is_default: bool) !void {
        if (input) |value| {
            const decoded = (try key_bindings.decodeKeybinding(allocator, value, platform.OS)) orelse return error.MissingKeybinding;
            defer key_bindings.freeChords(allocator, decoded);
            self.resolved = (try USLayoutResolvedKeybinding.resolveKeybinding(allocator, decoded, platform.OS)) orelse return error.MissingKeybinding;
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

    fn kbInput(self: *Harness, input: ?key_bindings.KeybindingInput, command: ?[]const u8, args: ?*const anyopaque, when: ?*const contextkey.Expr, is_default: bool) !*TestItem {
        const item = try self.allocator.create(TestItem);
        errdefer self.allocator.destroy(item);
        try item.init(self.allocator, input, command, args, when, is_default);
        try self.items.append(item);
        return item;
    }

    fn kb(self: *Harness, encoded: ?u32, command: ?[]const u8, args: ?*const anyopaque, when: ?*const contextkey.Expr, is_default: bool) !*TestItem {
        return self.kbInput(if (encoded) |value| .{ .single = value } else null, command, args, when, is_default);
    }

    fn kbChords(self: *Harness, chords: []const u32, command: ?[]const u8, args: ?*const anyopaque, when: ?*const contextkey.Expr, is_default: bool) !*TestItem {
        return self.kbInput(.{ .multiple = chords }, command, args, when, is_default);
    }

    fn eq(self: *Harness, key: []const u8, value: []const u8) !*const contextkey.Expr {
        return self.factory.equals(key, .{ .string = value });
    }

    fn parse(self: *Harness, input: []const u8) !?*const contextkey.Expr {
        var parser = contextkey.Parser.init(self.factory.arenaAllocator(), .{ .regex_parsing_with_error_recovery = false });
        defer parser.deinit();
        return parser.parse(input);
    }

    fn parseRequired(self: *Harness, input: []const u8) !*const contextkey.Expr {
        return (try self.parse(input)) orelse error.InvalidExpression;
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

const Input = union(enum) {
    single: u32,
    chords: []const u32,
};

fn inputKeybinding(input: Input) ?key_bindings.KeybindingInput {
    return switch (input) {
        .single => |value| .{ .single = value },
        .chords => |values| .{ .multiple = values },
    };
}

fn buildResolveCommandItems(h: *Harness) ![16]*TestItem {
    return .{
        try h.kb(@backingInt(key_codes.KeyCode.KeyX), "first", null, try h.factory.andExpr(&.{
            try h.factory.equals("key1", .{ .boolean = true }),
            try h.factory.notEquals("key2", .{ .boolean = false }),
        }), true),
        try h.kb(@backingInt(key_codes.KeyCode.KeyX), "second", null, try h.factory.equals("key2", .{ .boolean = true }), true),
        try h.kb(@backingInt(key_codes.KeyCode.KeyZ), "second", null, null, true),
        try h.kb(@backingInt(key_codes.KeyCode.KeyX), "third", null, try h.factory.equals("key3", .{ .boolean = true }), true),
        try h.kb(key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyY), "fourth", null, try h.factory.equals("key4", .{ .boolean = true }), true),
        try h.kbChords(&.{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyY), @backingInt(key_codes.KeyCode.KeyZ) }, "fifth", null, null, true),
        try h.kb(null, "sixth", null, null, true),
        try h.kbChords(&.{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyU) }, "seventh", null, null, true),
        try h.kbChords(&.{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK) }, "seventh", null, null, true),
        try h.kbChords(&.{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyU) }, "uncomment lines", null, null, true),
        try h.kbChords(&.{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyC) }, "comment lines", null, null, true),
        try h.kbChords(&.{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyG), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyC) }, "unreachablechord", null, null, true),
        try h.kb(key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyG), "eleven", null, null, true),
        try h.kbChords(&.{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), @backingInt(key_codes.KeyCode.KeyA), @backingInt(key_codes.KeyCode.KeyB) }, "long multi chord", null, null, true),
        try h.kbChords(&.{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyB), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyC) }, "shadowed by long-multi-chord-2", null, null, true),
        try h.kbChords(&.{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyB), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyC), @backingInt(key_codes.KeyCode.KeyI) }, "long-multi-chord-2", null, null, true),
    };
}

fn itemsOf(items: [16]*TestItem) [16]*const ResolvedKeybindingItem {
    var result: [16]*const ResolvedKeybindingItem = undefined;
    for (items, 0..) |item, index| result[index] = &item.item;
    return result;
}

fn expectLookup(h: *Harness, resolver: *KeybindingResolver, command: []const u8, expected: []const Input) !void {
    const allocator = h.allocator;
    const result = try resolver.lookupKeybindings(allocator, command);
    defer allocator.free(result);

    try std.testing.expectEqual(expected.len, result.len);
    for (expected, result) |input, item| {
        const expected_item = try h.kbInput(inputKeybinding(input), "expected", null, null, true);
        const actual_label = item.resolvedKeybinding.?.getUserSettingsLabel();
        const expected_label = expected_item.resolved.?.interface().getUserSettingsLabel();
        if (expected_label) |value| {
            try std.testing.expect(actual_label != null);
            try std.testing.expectEqualStrings(value, actual_label.?);
        } else {
            try std.testing.expect(actual_label == null);
        }
    }
}

fn expectResolve(
    h: *Harness,
    resolver: *KeybindingResolver,
    context: contextkey.IContext,
    input: Input,
    command: []const u8,
) !void {
    const expected = try h.kbInput(inputKeybinding(input), command, null, null, true);
    var previous = std.array_list.Managed([]const u8).init(h.allocator);
    defer previous.deinit();

    for (expected.item.chords, 0..) |chord, index| {
        const result = try resolver.resolve(context, previous.items, chord);
        if (index == expected.item.chords.len - 1) {
            try std.testing.expectEqual(ResultKind.KbFound, result.kind);
            try std.testing.expectEqualStrings(command, result.commandId.?);
        } else {
            try std.testing.expectEqual(ResultKind.MoreChordsNeeded, result.kind);
        }
        try previous.append(chord);
    }
}

const ResolveCommandFixture = struct {
    harness: Harness,
    items: [16]*TestItem,
    resolver: KeybindingResolver,

    fn init(allocator: Allocator) !ResolveCommandFixture {
        var harness = Harness.init(allocator);
        errdefer harness.deinit();
        const items = try buildResolveCommandItems(&harness);
        const pointers = itemsOf(items);
        var resolver = try KeybindingResolver.init(allocator, &pointers, &.{});
        errdefer resolver.deinit();
        return .{ .harness = harness, .items = items, .resolver = resolver };
    }

    fn deinit(self: *ResolveCommandFixture) void {
        self.resolver.deinit();
        self.harness.deinit();
    }
};

test "resolve command - 1" {
    const allocator = std.testing.allocator;
    var fixture = try ResolveCommandFixture.init(allocator);
    defer fixture.deinit();
    try expectLookup(&fixture.harness, &fixture.resolver, "first", &.{});
}

test "resolve command - 2" {
    const allocator = std.testing.allocator;
    var fixture = try ResolveCommandFixture.init(allocator);
    defer fixture.deinit();

    try expectLookup(&fixture.harness, &fixture.resolver, "second", &.{
        .{ .single = @backingInt(key_codes.KeyCode.KeyZ) },
        .{ .single = @backingInt(key_codes.KeyCode.KeyX) },
    });

    var context = TestContext.init(allocator);
    defer context.deinit();
    try context.values.put("key2", .{ .boolean = true });
    try expectResolve(&fixture.harness, &fixture.resolver, context.context(), .{ .single = @backingInt(key_codes.KeyCode.KeyX) }, "second");

    var empty = TestContext.init(allocator);
    defer empty.deinit();
    try expectResolve(&fixture.harness, &fixture.resolver, empty.context(), .{ .single = @backingInt(key_codes.KeyCode.KeyZ) }, "second");
}

test "resolve command - 3" {
    const allocator = std.testing.allocator;
    var fixture = try ResolveCommandFixture.init(allocator);
    defer fixture.deinit();

    try expectLookup(&fixture.harness, &fixture.resolver, "third", &.{.{ .single = @backingInt(key_codes.KeyCode.KeyX) }});
    var context = TestContext.init(allocator);
    defer context.deinit();
    try context.values.put("key3", .{ .boolean = true });
    try expectResolve(&fixture.harness, &fixture.resolver, context.context(), .{ .single = @backingInt(key_codes.KeyCode.KeyX) }, "third");
}

test "resolve command - 4" {
    const allocator = std.testing.allocator;
    var fixture = try ResolveCommandFixture.init(allocator);
    defer fixture.deinit();
    try expectLookup(&fixture.harness, &fixture.resolver, "fourth", &.{});
}

test "resolve command - 5" {
    const allocator = std.testing.allocator;
    var fixture = try ResolveCommandFixture.init(allocator);
    defer fixture.deinit();

    const chords = [_]u32{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyY), @backingInt(key_codes.KeyCode.KeyZ) };
    try expectLookup(&fixture.harness, &fixture.resolver, "fifth", &.{.{ .chords = &chords }});

    var empty = TestContext.init(allocator);
    defer empty.deinit();
    try expectResolve(&fixture.harness, &fixture.resolver, empty.context(), .{ .chords = &chords }, "fifth");
}

test "resolve command - 6" {
    const allocator = std.testing.allocator;
    var fixture = try ResolveCommandFixture.init(allocator);
    defer fixture.deinit();

    const chords = [_]u32{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK) };
    try expectLookup(&fixture.harness, &fixture.resolver, "seventh", &.{.{ .chords = &chords }});

    var empty = TestContext.init(allocator);
    defer empty.deinit();
    try expectResolve(&fixture.harness, &fixture.resolver, empty.context(), .{ .chords = &chords }, "seventh");
}

test "resolve command - 7" {
    const allocator = std.testing.allocator;
    var fixture = try ResolveCommandFixture.init(allocator);
    defer fixture.deinit();

    const chords = [_]u32{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyU) };
    try expectLookup(&fixture.harness, &fixture.resolver, "uncomment lines", &.{.{ .chords = &chords }});

    var empty = TestContext.init(allocator);
    defer empty.deinit();
    try expectResolve(&fixture.harness, &fixture.resolver, empty.context(), .{ .chords = &chords }, "uncomment lines");
}

test "resolve command - 8" {
    const allocator = std.testing.allocator;
    var fixture = try ResolveCommandFixture.init(allocator);
    defer fixture.deinit();

    const chords = [_]u32{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyC) };
    try expectLookup(&fixture.harness, &fixture.resolver, "comment lines", &.{.{ .chords = &chords }});

    var empty = TestContext.init(allocator);
    defer empty.deinit();
    try expectResolve(&fixture.harness, &fixture.resolver, empty.context(), .{ .chords = &chords }, "comment lines");
}

test "resolve command - 9" {
    const allocator = std.testing.allocator;
    var fixture = try ResolveCommandFixture.init(allocator);
    defer fixture.deinit();
    try expectLookup(&fixture.harness, &fixture.resolver, "unreachablechord", &.{});
}

test "resolve command - 10" {
    const allocator = std.testing.allocator;
    var fixture = try ResolveCommandFixture.init(allocator);
    defer fixture.deinit();

    try expectLookup(&fixture.harness, &fixture.resolver, "eleven", &.{.{ .single = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyG) }});

    var empty = TestContext.init(allocator);
    defer empty.deinit();
    try expectResolve(&fixture.harness, &fixture.resolver, empty.context(), .{ .single = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyG) }, "eleven");
}

test "resolve command - 11" {
    const allocator = std.testing.allocator;
    var fixture = try ResolveCommandFixture.init(allocator);
    defer fixture.deinit();
    try expectLookup(&fixture.harness, &fixture.resolver, "sixth", &.{});
}

test "resolve command - 12" {
    const allocator = std.testing.allocator;
    var fixture = try ResolveCommandFixture.init(allocator);
    defer fixture.deinit();

    const chords = [_]u32{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), @backingInt(key_codes.KeyCode.KeyA), @backingInt(key_codes.KeyCode.KeyB) };
    try expectLookup(&fixture.harness, &fixture.resolver, "long multi chord", &.{.{ .chords = &chords }});

    var empty = TestContext.init(allocator);
    defer empty.deinit();
    try expectResolve(&fixture.harness, &fixture.resolver, empty.context(), .{ .chords = &chords }, "long multi chord");
}

test "KBs having common prefix - the one defined later is returned" {
    const allocator = std.testing.allocator;
    var fixture = try ResolveCommandFixture.init(allocator);
    defer fixture.deinit();

    const chords = [_]u32{ key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyB), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyC), @backingInt(key_codes.KeyCode.KeyI) };
    var empty = TestContext.init(allocator);
    defer empty.deinit();
    try expectResolve(&fixture.harness, &fixture.resolver, empty.context(), .{ .chords = &chords }, "long-multi-chord-2");
}

const WhenArg = union(enum) {
    text: []const u8,
    expression: ?*const contextkey.Expr,
};

fn whenArg(h: *Harness, arg: WhenArg) !?*const contextkey.Expr {
    return switch (arg) {
        .expression => |expression| expression,
        .text => |text| if (text.len == 0) null else h.parse(text),
    };
}

fn expectWhen(h: *Harness, a: WhenArg, b: WhenArg, expected: bool) !void {
    const a_expr = try whenArg(h, a);
    const b_expr = try whenArg(h, b);
    try std.testing.expectEqual(expected, KeybindingResolver.whenIsEntirelyIncluded(a_expr, b_expr));
}

test "handleRemovals - issue #612 cannot remove keybindings for commands with ^" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator);
    defer h.deinit();

    const a = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "^yes1", null, try h.eq("1", "a"), true);
    const b = try h.kb(@backingInt(key_codes.KeyCode.KeyB), "yes2", null, try h.eq("2", "b"), true);
    const removal = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "-yes1", null, null, false);
    const rules = [_]*const ResolvedKeybindingItem{ &a.item, &b.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try expectCommands(result, &.{"yes2"});
}

test "handleRemovals - issue #140884 reassign F1" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator);
    defer h.deinit();

    const a = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "command1", null, null, true);
    const removal = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "-command1", null, null, false);
    const replacement = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "command1", null, null, false);
    const rules = [_]*const ResolvedKeybindingItem{ &a.item, &removal.item, &replacement.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try expectCommands(result, &.{"command1"});
    try std.testing.expect(!result[0].isDefault);
}

test "handleRemovals - issue #141638 change when expression" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator);
    defer h.deinit();

    const a = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "command1", null, null, true);
    const override = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "command1", null, try h.eq("a", "1"), false);
    const removal = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "-command1", null, null, false);
    const rules = [_]*const ResolvedKeybindingItem{ &a.item, &override.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try expectCommands(result, &.{"command1"});
    try std.testing.expect(!result[0].isDefault);
}

test "handleRemovals - issue #157751 auto-quoting of context keys" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator);
    defer h.deinit();

    const defaults = try h.kb(
        @backingInt(key_codes.KeyCode.KeyA),
        "command1",
        null,
        try h.parseRequired("editorTextFocus && activeEditor != workbench.editor.notebook && editorLangId in julia.supportedLanguageIds"),
        true,
    );
    const removal = try h.kb(
        @backingInt(key_codes.KeyCode.KeyA),
        "-command1",
        null,
        try h.parseRequired("editorTextFocus && activeEditor != 'workbench.editor.notebook' && editorLangId in 'julia.supportedLanguageIds'"),
        false,
    );
    const rules = [_]*const ResolvedKeybindingItem{ &defaults.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "handleRemovals - issue #293802 more specific default when" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator);
    defer h.deinit();

    const default_when = try h.factory.andExpr(&.{
        try h.factory.has("inChatInput"),
        try h.factory.not("withinEditSessionDiff"),
    });
    const defaults = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "command1", null, default_when, true);
    const removal = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "-command1", null, try h.factory.has("inChatInput"), false);
    const rules = [_]*const ResolvedKeybindingItem{ &defaults.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "handleRemovals - more specific removal does not match broader default" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator);
    defer h.deinit();

    const defaults = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "command1", null, try h.factory.has("inChatInput"), true);
    const removal_when = try h.factory.andExpr(&.{
        try h.factory.has("inChatInput"),
        try h.factory.not("withinEditSessionDiff"),
    });
    const removal = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "-command1", null, removal_when, false);
    const rules = [_]*const ResolvedKeybindingItem{ &defaults.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try expectCommands(result, &.{"command1"});
}

test "handleRemovals - issue #160604 remove keybindings with when clause" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator);
    defer h.deinit();

    const defaults = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "command1", null, null, true);
    const removal = try h.kb(@backingInt(key_codes.KeyCode.KeyA), "-command1", null, try h.factory.trueExpr(), false);
    const rules = [_]*const ResolvedKeybindingItem{ &defaults.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "handleRemovals - issue #338834 chat steer and queue Enter" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator);
    defer h.deinit();

    const editing_queue = try h.factory.equals("chatEditingSentRequest", .{ .string = "q" });
    const editing_steer = try h.factory.equals("chatEditingSentRequest", .{ .string = "st" });
    const editing_queue_or_steer = (try h.factory.orExpr(&.{ editing_queue, editing_steer })).?;
    const queuing_actions_present = (try h.factory.andExpr(&.{
        try h.factory.not("chatTranscriptProgressActive"),
        (try h.factory.orExpr(&.{ try h.factory.has("chatSessionRequestInProgress"), editing_queue_or_steer })).?,
        try h.factory.notEquals("chatEditingSentRequest", .{ .string = "s" }),
    })).?;
    const steer_is_default = try h.factory.equals("config.chat.requestQueuing.defaultAction", .{ .string = "steer" });
    const effective_default_is_steer = (try h.factory.orExpr(&.{
        (try h.factory.andExpr(&.{ steer_is_default, try editing_queue_or_steer.negate(h.factory.arenaAllocator()) })).?,
        editing_steer,
    })).?;
    const precondition = (try h.factory.andExpr(&.{
        try h.factory.has("chatInputHasText"),
        try h.factory.not("chatTranscriptProgressActive"),
        try h.factory.not("chatInputBlocked"),
    })).?;

    const steer = try h.kb(@backingInt(key_codes.KeyCode.Enter), "steer", null, (try h.factory.andExpr(&.{
        precondition,
        (try h.factory.andExpr(&.{ try h.factory.has("inChatInput"), queuing_actions_present, effective_default_is_steer })).?,
    })).?, true);

    const serialized = try steer.item.when.?.serialize(allocator);
    defer allocator.free(serialized);
    const removal_when = try h.parseRequired(serialized);
    const removal = try h.kb(@backingInt(key_codes.KeyCode.Enter), "-steer", null, removal_when, false);

    const rules = [_]*const ResolvedKeybindingItem{ &steer.item, &removal.item };
    const result = try removals(allocator, &rules);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "contextIsEntirelyIncluded" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator);
    defer h.deinit();

    try expectWhen(&h, .{ .expression = null }, .{ .expression = null }, true);
    try expectWhen(&h, .{ .expression = null }, .{ .expression = try h.factory.trueExpr() }, true);
    try expectWhen(&h, .{ .expression = try h.factory.trueExpr() }, .{ .expression = null }, true);
    try expectWhen(&h, .{ .expression = try h.factory.trueExpr() }, .{ .expression = try h.factory.trueExpr() }, true);

    try expectWhen(&h, .{ .text = "key1" }, .{ .expression = null }, true);
    try expectWhen(&h, .{ .text = "key1" }, .{ .text = "" }, true);
    try expectWhen(&h, .{ .text = "key1" }, .{ .text = "key1" }, true);
    try expectWhen(&h, .{ .text = "key1" }, .{ .expression = try h.factory.trueExpr() }, true);
    try expectWhen(&h, .{ .text = "!key1" }, .{ .text = "" }, true);
    try expectWhen(&h, .{ .text = "!key1" }, .{ .text = "!key1" }, true);
    try expectWhen(&h, .{ .text = "key2" }, .{ .text = "" }, true);
    try expectWhen(&h, .{ .text = "key2" }, .{ .text = "key2" }, true);
    try expectWhen(&h, .{ .text = "key1 && key1 && key2 && key2" }, .{ .text = "key2" }, true);
    try expectWhen(&h, .{ .text = "key1 && key2" }, .{ .text = "key2" }, true);
    try expectWhen(&h, .{ .text = "key1 && key2" }, .{ .text = "key1" }, true);
    try expectWhen(&h, .{ .text = "key1 && key2" }, .{ .text = "" }, true);
    try expectWhen(&h, .{ .text = "key1" }, .{ .text = "key1 || key2" }, true);
    try expectWhen(&h, .{ .text = "key1 || !key1" }, .{ .text = "key2 || !key2" }, true);
    try expectWhen(&h, .{ .text = "key1" }, .{ .text = "key1 || key2 && key3" }, true);

    try expectWhen(&h, .{ .text = "key1" }, .{ .text = "!key1" }, false);
    try expectWhen(&h, .{ .text = "!key1" }, .{ .text = "key1" }, false);
    try expectWhen(&h, .{ .text = "key1 && key2" }, .{ .text = "key3" }, false);
    try expectWhen(&h, .{ .text = "key1 && key2" }, .{ .text = "key4" }, false);
    try expectWhen(&h, .{ .text = "key1" }, .{ .text = "key2" }, false);
    try expectWhen(&h, .{ .text = "key1 || key2" }, .{ .text = "key2" }, false);
    try expectWhen(&h, .{ .text = "" }, .{ .text = "key2" }, false);
    try expectWhen(&h, .{ .expression = null }, .{ .text = "key2" }, false);
}

fn resolveWithAliases(
    allocator: Allocator,
    h: *Harness,
    defaults: []const *const ResolvedKeybindingItem,
    overrides: []const *const ResolvedKeybindingItem,
    aliases: []const resolver_module.KeybindingAlias,
    encoded: ?u32,
    context_key: []const u8,
) !?[]const u8 {
    var aliased = try KeybindingResolver.applyAliases(allocator, defaults, overrides, aliases);
    defer aliased.deinit(allocator);
    var resolver = try KeybindingResolver.init(allocator, aliased.defaults, aliased.overrides);
    defer resolver.deinit();

    var context = TestContext.init(allocator);
    defer context.deinit();
    try context.values.put(context_key, .{ .boolean = true });

    const item = try h.kb(encoded, "probe", null, null, true);
    const result = try resolver.resolve(context.context(), &.{}, item.item.chords[0]);
    return if (result.kind == .KbFound) result.commandId else null;
}

test "keybinding aliases - binds the alias to the keybindings of its source" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator);
    defer h.deinit();

    const toggle_when = try h.factory.has("chatViewVisible");
    const alias_when = try h.factory.has("agentsWindow");
    const aliases = [_]resolver_module.KeybindingAlias{.{
        .command = "sessions",
        .source = "toggleChat",
        .when = alias_when,
    }};

    const defaults = [_]*const ResolvedKeybindingItem{&(try h.kb(@backingInt(key_codes.KeyCode.KeyA), "toggleChat", null, toggle_when, true)).item};
    const overrides = [_]*const ResolvedKeybindingItem{&(try h.kb(@backingInt(key_codes.KeyCode.KeyB), "toggleChat", null, null, false)).item};

    const agents_key_a = try resolveWithAliases(allocator, &h, &defaults, &overrides, &aliases, @backingInt(key_codes.KeyCode.KeyA), "agentsWindow");
    const agents_key_b = try resolveWithAliases(allocator, &h, &defaults, &overrides, &aliases, @backingInt(key_codes.KeyCode.KeyB), "agentsWindow");
    try std.testing.expectEqualStrings("sessions", agents_key_a.?);
    try std.testing.expectEqualStrings("sessions", agents_key_b.?);

    const editor_key_a = try resolveWithAliases(allocator, &h, &defaults, &overrides, &aliases, @backingInt(key_codes.KeyCode.KeyA), "chatViewVisible");
    const editor_key_b = try resolveWithAliases(allocator, &h, &defaults, &overrides, &aliases, @backingInt(key_codes.KeyCode.KeyB), "chatViewVisible");
    try std.testing.expectEqualStrings("toggleChat", editor_key_a.?);
    try std.testing.expectEqualStrings("toggleChat", editor_key_b.?);
}

test "keybinding aliases - removes keybindings removed from its source" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator);
    defer h.deinit();

    const alias_when = try h.factory.has("agentsWindow");
    const toggle_when = try h.factory.has("chatViewVisible");
    const aliases = [_]resolver_module.KeybindingAlias{.{ .command = "sessions", .source = "toggleChat", .when = alias_when }};

    const defaults = [_]*const ResolvedKeybindingItem{
        &(try h.kb(@backingInt(key_codes.KeyCode.KeyA), "openChat", null, null, true)).item,
        &(try h.kb(@backingInt(key_codes.KeyCode.KeyA), "sessions", null, alias_when, true)).item,
    };
    const overrides = [_]*const ResolvedKeybindingItem{
        &(try h.kb(@backingInt(key_codes.KeyCode.KeyA), "-toggleChat", null, toggle_when, false)).item,
        &(try h.kb(@backingInt(key_codes.KeyCode.KeyB), "toggleChat", null, toggle_when, false)).item,
        &(try h.kb(@backingInt(key_codes.KeyCode.KeyC), "toggleChat", null, toggle_when, false)).item,
        &(try h.kb(@backingInt(key_codes.KeyCode.KeyC), "-sessions", null, null, false)).item,
    };

    const agents_a = try resolveWithAliases(allocator, &h, &defaults, &overrides, &aliases, @backingInt(key_codes.KeyCode.KeyA), "agentsWindow");
    const agents_b = try resolveWithAliases(allocator, &h, &defaults, &overrides, &aliases, @backingInt(key_codes.KeyCode.KeyB), "agentsWindow");
    const agents_c = try resolveWithAliases(allocator, &h, &defaults, &overrides, &aliases, @backingInt(key_codes.KeyCode.KeyC), "agentsWindow");
    try std.testing.expectEqualStrings("openChat", agents_a.?);
    try std.testing.expectEqualStrings("sessions", agents_b.?);
    try std.testing.expect(agents_c == null);

    const editor_a = try resolveWithAliases(allocator, &h, &defaults, &overrides, &aliases, @backingInt(key_codes.KeyCode.KeyA), "chatViewVisible");
    const editor_b = try resolveWithAliases(allocator, &h, &defaults, &overrides, &aliases, @backingInt(key_codes.KeyCode.KeyB), "chatViewVisible");
    const editor_c = try resolveWithAliases(allocator, &h, &defaults, &overrides, &aliases, @backingInt(key_codes.KeyCode.KeyC), "chatViewVisible");
    try std.testing.expectEqualStrings("openChat", editor_a.?);
    try std.testing.expectEqualStrings("toggleChat", editor_b.?);
    try std.testing.expectEqualStrings("toggleChat", editor_c.?);
}

test "keybinding aliases - keeps inherited user keybindings when source removals share their key" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator);
    defer h.deinit();

    const alias_when = try h.factory.has("agentsWindow");
    const toggle_when = try h.factory.has("chatViewVisible");
    const aliases = [_]resolver_module.KeybindingAlias{.{ .command = "sessions", .source = "toggleChat", .when = alias_when }};

    const defaults = [_]*const ResolvedKeybindingItem{
        &(try h.kb(@backingInt(key_codes.KeyCode.KeyA), "sessions", null, alias_when, true)).item,
    };

    const same_key = [_]*const ResolvedKeybindingItem{
        &(try h.kb(@backingInt(key_codes.KeyCode.KeyA), "toggleChat", null, try h.factory.has("other"), false)).item,
        &(try h.kb(@backingInt(key_codes.KeyCode.KeyA), "-toggleChat", null, toggle_when, false)).item,
    };
    const any_key = [_]*const ResolvedKeybindingItem{
        &(try h.kb(@backingInt(key_codes.KeyCode.KeyB), "toggleChat", null, null, false)).item,
        &(try h.kb(null, "-toggleChat", null, null, false)).item,
    };

    const same_key_result = try resolveWithAliases(allocator, &h, &defaults, &same_key, &aliases, @backingInt(key_codes.KeyCode.KeyA), "agentsWindow");
    try std.testing.expectEqualStrings("sessions", same_key_result.?);

    const any_key_a = try resolveWithAliases(allocator, &h, &defaults, &any_key, &aliases, @backingInt(key_codes.KeyCode.KeyA), "agentsWindow");
    const any_key_b = try resolveWithAliases(allocator, &h, &defaults, &any_key, &aliases, @backingInt(key_codes.KeyCode.KeyB), "agentsWindow");
    try std.testing.expect(any_key_a == null);
    try std.testing.expectEqualStrings("sessions", any_key_b.?);
}
