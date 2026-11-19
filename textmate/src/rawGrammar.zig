// Port of `vscode-textmate/src/rawGrammar.ts` (microsoft/vscode-textmate
// v9.3.2).
//
// Adaptation notes:
//  * TypeScript's dynamic `any` grammar values become `Value`, a JSON-like
//    tagged union. This is what the plist/JSON parsers produce and what the
//    rule factory walks. Objects carry the internal `id` assigned while
//    compiling rules, exactly like `IRawRule.id`.
//  * `$vscodeTextmateLocation` is kept on the object instead of being inserted
//    as a property, so callers iterating a repository do not have to special
//    case the metadata key.
//  * A parsed grammar owns an arena. `RawGrammar.clone` deep-copies into a new
//    arena, mirroring the upstream `clone(grammar)` before a grammar is
//    initialized for compilation.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Location = struct {
    filename: ?[]const u8 = null,
    line: u32 = 0,
    char: u32 = 0,
};

/// Mirrors the TypeScript `RuleId` brand; it is only meaningful inside a
/// compiled grammar.
pub const RuleId = i32;

pub const Value = union(enum) {
    null,
    boolean: bool,
    number: f64,
    string: []const u8,
    array: []Value,
    object: *Object,
    /// Plist `<date>`; the raw text is preserved instead of creating a JS Date.
    date: []const u8,
    /// Plist `<data>`; vscode-textmate accepts data as a string.
    data: []const u8,
};

pub const Object = struct {
    map: std.StringArrayHashMapUnmanaged(Value) = .empty,
    location: ?Location = null,
    /// `IRawRule.id`, assigned by the rule factory.
    id: ?RuleId = null,

    pub fn create(allocator: Allocator) !*Object {
        const object = try allocator.create(Object);
        object.* = .{};
        return object;
    }

    pub fn get(self: *const Object, key: []const u8) ?Value {
        return self.map.get(key);
    }

    pub fn getObject(self: *const Object, key: []const u8) ?*Object {
        const value = self.get(key) orelse return null;
        return switch (value) {
            .object => |object| object,
            else => null,
        };
    }

    pub fn getString(self: *const Object, key: []const u8) ?[]const u8 {
        const value = self.get(key) orelse return null;
        return switch (value) {
            .string => |string| string,
            else => null,
        };
    }

    pub fn getBool(self: *const Object, key: []const u8) ?bool {
        const value = self.get(key) orelse return null;
        return switch (value) {
            .boolean => |boolean| boolean,
            else => null,
        };
    }

    pub fn getNumber(self: *const Object, key: []const u8) ?f64 {
        const value = self.get(key) orelse return null;
        return switch (value) {
            .number => |number| number,
            else => null,
        };
    }

    pub fn getArray(self: *const Object, key: []const u8) ?[]Value {
        const value = self.get(key) orelse return null;
        return switch (value) {
            .array => |array| array,
            else => null,
        };
    }

    /// Insert or replace. `key` is copied into `allocator`.
    pub fn put(self: *Object, allocator: Allocator, key: []const u8, value: Value) !void {
        const result = try self.map.getOrPut(allocator, key);
        if (!result.found_existing) {
            result.key_ptr.* = try allocator.dupe(u8, key);
        }
        result.value_ptr.* = value;
    }

    /// Insert without copying `key`; the caller guarantees its lifetime.
    pub fn putOwnedKey(self: *Object, allocator: Allocator, key: []const u8, value: Value) !void {
        try self.map.put(allocator, key, value);
    }

    /// All string keys in insertion order.
    pub fn keys(self: *const Object) []const []const u8 {
        return self.map.keys();
    }

    pub fn values(self: *const Object) []const Value {
        return self.map.values();
    }
};

/// Deep clone of a `Value` into `allocator`.
pub fn cloneValue(allocator: Allocator, value: Value) Allocator.Error!Value {
    return switch (value) {
        .null => .null,
        .boolean => |boolean| .{ .boolean = boolean },
        .number => |number| .{ .number = number },
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
        .array => |array| blk: {
            const copy = try allocator.alloc(Value, array.len);
            for (array, 0..) |item, i| copy[i] = try cloneValue(allocator, item);
            break :blk .{ .array = copy };
        },
        .object => |object| .{ .object = try cloneObject(allocator, object) },
        .date => |date| .{ .date = try allocator.dupe(u8, date) },
        .data => |data| .{ .data = try allocator.dupe(u8, data) },
    };
}

pub fn cloneObject(allocator: Allocator, source: *const Object) Allocator.Error!*Object {
    const result = try allocator.create(Object);
    result.* = .{
        .location = if (source.location) |location| .{
            .filename = if (location.filename) |filename| try allocator.dupe(u8, filename) else null,
            .line = location.line,
            .char = location.char,
        } else null,
        .id = source.id,
    };
    for (source.map.keys(), source.map.values()) |key, value| {
        try result.map.put(allocator, try allocator.dupe(u8, key), try cloneValue(allocator, value));
    }
    return result;
}

/// An owned raw grammar. The parsed object graph lives in `arena`.
pub const RawGrammar = struct {
    arena: std.heap.ArenaAllocator,
    root: *Object,

    pub fn deinit(self: *RawGrammar) void {
        self.arena.deinit();
    }

    pub fn scopeName(self: *const RawGrammar) []const u8 {
        return self.root.getString("scopeName") orelse "";
    }

    /// Deep clone of the grammar root into a caller-supplied arena.
    pub fn cloneInto(self: *const RawGrammar, allocator: Allocator) !*Object {
        return cloneObject(allocator, self.root);
    }

    pub fn clone(self: *const RawGrammar, child_allocator: Allocator) !RawGrammar {
        var arena = std.heap.ArenaAllocator.init(child_allocator);
        errdefer arena.deinit();
        const root = try cloneObject(arena.allocator(), self.root);
        return .{ .arena = arena, .root = root };
    }
};

pub fn grammarRepository(self: *const RawGrammar) ?*Object {
    return self.root.getObject("repository");
}

pub fn grammarPatterns(self: *const RawGrammar) ?[]Value {
    return self.root.getArray("patterns");
}

pub fn grammarInjections(self: *const RawGrammar) ?*Object {
    return self.root.getObject("injections");
}

pub fn grammarInjectionSelector(self: *const RawGrammar) ?[]const u8 {
    return self.root.getString("injectionSelector");
}

pub fn grammarScopeName(self: *const RawGrammar) []const u8 {
    return self.root.getString("scopeName") orelse "";
}

/// Helpers used by rules and grammar code. These mirror the optional fields of
/// `IRawRule`; absent fields return null.
pub const RuleView = struct {
    object: *Object,

    pub fn include(self: RuleView) ?[]const u8 {
        return self.object.getString("include");
    }
    pub fn name(self: RuleView) ?[]const u8 {
        return self.object.getString("name");
    }
    pub fn contentName(self: RuleView) ?[]const u8 {
        return self.object.getString("contentName");
    }
    pub fn match(self: RuleView) ?[]const u8 {
        return self.object.getString("match");
    }
    pub fn begin(self: RuleView) ?[]const u8 {
        return self.object.getString("begin");
    }
    pub fn end(self: RuleView) ?[]const u8 {
        return self.object.getString("end");
    }
    pub fn whileSource(self: RuleView) ?[]const u8 {
        return self.object.getString("while");
    }
    pub fn captures(self: RuleView) ?*Object {
        return self.object.getObject("captures");
    }
    pub fn beginCaptures(self: RuleView) ?*Object {
        return self.object.getObject("beginCaptures");
    }
    pub fn endCaptures(self: RuleView) ?*Object {
        return self.object.getObject("endCaptures");
    }
    pub fn whileCaptures(self: RuleView) ?*Object {
        return self.object.getObject("whileCaptures");
    }
    pub fn patterns(self: RuleView) ?[]Value {
        return self.object.getArray("patterns");
    }
    pub fn repository(self: RuleView) ?*Object {
        return self.object.getObject("repository");
    }
    pub fn applyEndPatternLast(self: RuleView) bool {
        return self.object.getBool("applyEndPatternLast") orelse false;
    }
};

test "raw grammar clone is deep" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try Object.create(allocator);
    try root.put(allocator, "scopeName", .{ .string = "source.test" });
    const patterns = try allocator.alloc(Value, 1);
    const child = try Object.create(allocator);
    try child.put(allocator, "match", .{ .string = "foo" });
    patterns[0] = .{ .object = child };
    try root.put(allocator, "patterns", .{ .array = patterns });
    var raw = RawGrammar{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .root = root };
    defer raw.deinit();

    var cloned = try raw.clone(std.testing.allocator);
    defer cloned.deinit();
    try std.testing.expect(cloned.root != raw.root);
    try std.testing.expectEqualStrings("foo", cloned.root.getArray("patterns").?[0].object.getString("match").?);
}

/// Shallow merge used by `initGrammar` and rule include resolution. Values and
/// keys are borrowed from the source objects, which share the grammar arena.
pub fn mergeObjects(
    allocator: Allocator,
    base: ?*const Object,
    overlay: *const Object,
) Allocator.Error!*Object {
    const result = try Object.create(allocator);
    if (base) |object| {
        for (object.map.keys(), object.map.values()) |key, value| {
            try result.map.put(allocator, key, value);
        }
    }
    for (overlay.map.keys(), overlay.map.values()) |key, value| {
        try result.map.put(allocator, key, value);
    }
    return result;
}
