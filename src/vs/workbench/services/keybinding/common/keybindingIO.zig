// Port of the user-file subset of
// `src/vs/workbench/services/keybinding/common/keybindingIO.ts`.
//
// The keybinding editor and its serializer (`writeKeybindingItem`,
// `OutputBuilder`) are not ported: the terminal has no Keyboard Shortcuts
// editor. Reading `keybindings.json` items is all the workbench needs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const key_bindings = @import("../../../../base/common/keybindings.zig");
const keybinding_parser = @import("../../../../base/common/keybindingParser.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");

pub const UserKeybindingItem = struct {
    keybinding: ?key_bindings.Keybinding,
    command: ?[]const u8,
    /// Borrows the parsed JSON document; commands in the terminal table do not
    /// consume arguments yet.
    command_args: ?*const anyopaque = null,
    when: ?*const contextkey.Expr = null,
    system_wide: bool = false,
    /// Captures the `key` field exactly as written; `keybinding != null`
    /// implies a source key.
    source_key: ?[]const u8 = null,
};

/// Reads one entry of a `keybindings.json` array. Invalid optional fields are
/// dropped exactly like upstream: a non-string `key`/`command`/`when` becomes
/// null instead of failing the whole item.
///
/// The caller owns the keybinding chords (use an arena when parsing a whole
/// file) and the arena backing the `when` expression.
pub fn readUserKeybindingItem(
    allocator: Allocator,
    expr_allocator: Allocator,
    value: std.json.Value,
) !UserKeybindingItem {
    const object = switch (value) {
        .object => |object| object,
        else => return .{ .keybinding = null, .command = null },
    };

    var item = UserKeybindingItem{ .keybinding = null, .command = null };

    if (object.get("key")) |key_value| {
        if (key_value == .string and key_value.string.len > 0) {
            item.source_key = key_value.string;
            item.keybinding = try keybinding_parser.KeybindingParser.parseKeybinding(allocator, key_value.string);
        }
    }
    if (object.get("command")) |command_value| {
        if (command_value == .string) item.command = command_value.string;
    }
    if (object.getPtr("args")) |args| {
        item.command_args = @ptrCast(args);
    }
    if (object.get("when")) |when_value| {
        if (when_value == .string and when_value.string.len > 0) {
            var parser = contextkey.Parser.init(expr_allocator, .{});
            defer parser.deinit();
            item.when = parser.parse(when_value.string) catch null;
        }
    }
    if (object.get("systemWide")) |system_wide| {
        if (system_wide == .bool) item.system_wide = system_wide.bool;
    }
    return item;
}

test "keybindingIO: reads key, command, when and args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json =
        \\{ "key": "ctrl+k ctrl+f", "command": "firstcommand", "when": "editorTextFocus", "args": { "text": "theText" } }
    ;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
    const item = try readUserKeybindingItem(allocator, allocator, value);
    try std.testing.expect(item.keybinding != null);
    try std.testing.expectEqual(@as(usize, 2), item.keybinding.?.chords.len);
    try std.testing.expectEqualStrings("firstcommand", item.command.?);
    try std.testing.expect(item.when != null);
    try std.testing.expect(!item.system_wide);
    try std.testing.expectEqualStrings("ctrl+k ctrl+f", item.source_key.?);
}

test "keybindingIO: invalid command is dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{ "key": "ctrl+k ctrl+f", "command": ["firstcommand", "secondcommand"] }
    , .{});
    const item = try readUserKeybindingItem(allocator, allocator, value);
    try std.testing.expect(item.command == null);
}

test "keybindingIO: invalid when and key are dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const when_value = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{ "key": "ctrl+k ctrl+f", "command": "firstcommand", "when": [] }
    , .{});
    const when_item = try readUserKeybindingItem(allocator, allocator, when_value);
    try std.testing.expect(when_item.when == null);

    const empty_key = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{ "key": "", "command": "firstcommand" }
    , .{});
    const key_item = try readUserKeybindingItem(allocator, allocator, empty_key);
    try std.testing.expect(key_item.keybinding == null);
    try std.testing.expect(key_item.source_key == null);
}

test "keybindingIO: systemWide defaults to false and accepts a boolean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const absent = try readUserKeybindingItem(allocator, allocator, try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{ "key": "ctrl+cmd+a", "command": "firstcommand" }
    , .{}));
    try std.testing.expect(!absent.system_wide);

    const invalid = try readUserKeybindingItem(allocator, allocator, try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{ "key": "ctrl+cmd+a", "command": "firstcommand", "systemWide": "yes" }
    , .{}));
    try std.testing.expect(!invalid.system_wide);

    const present = try readUserKeybindingItem(allocator, allocator, try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{ "key": "ctrl+cmd+a", "command": "firstcommand", "systemWide": true }
    , .{}));
    try std.testing.expect(present.system_wide);
}
