// Port of the `keybindingIO.test.ts` cases that cover reading a
// `keybindings.json` item. The serializer/editor cases are not portable because
// the terminal has no Keyboard Shortcuts editor.

const std = @import("std");
const keybinding_io = @import("../../common/keybindingIO.zig");

test "keybindingIO.test: invalid command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{ "key": "ctrl+k ctrl+f", "command": ["firstcommand", "seccondcommand"] }
    , .{});
    const item = try keybinding_io.readUserKeybindingItem(allocator, allocator, value);
    try std.testing.expect(item.command == null);
}

test "keybindingIO.test: invalid when" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{ "key": "ctrl+k ctrl+f", "command": "firstcommand", "when": [] }
    , .{});
    const item = try keybinding_io.readUserKeybindingItem(allocator, allocator, value);
    try std.testing.expect(item.when == null);
}

test "keybindingIO.test: invalid key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{ "key": [], "command": "firstcommand" }
    , .{});
    const item = try keybinding_io.readUserKeybindingItem(allocator, allocator, value);
    try std.testing.expect(item.keybinding == null);
}

test "keybindingIO.test: commands args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{ "key": "ctrl+k ctrl+f", "command": "firstcommand", "when": [], "args": { "text": "theText" } }
    , .{});
    const item = try keybinding_io.readUserKeybindingItem(allocator, allocator, value);
    try std.testing.expect(item.command_args != null);
    const args: *const std.json.Value = @ptrCast(@alignCast(item.command_args.?));
    try std.testing.expectEqualStrings("theText", args.object.get("text").?.string);
}

test "keybindingIO.test: systemWide defaults to false when absent or invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const absent = try keybinding_io.readUserKeybindingItem(allocator, allocator, try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{ "key": "ctrl+cmd+a", "command": "firstcommand" }
    , .{}));
    try std.testing.expect(!absent.system_wide);
    const invalid = try keybinding_io.readUserKeybindingItem(allocator, allocator, try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{ "key": "ctrl+cmd+a", "command": "firstcommand", "systemWide": "yes" }
    , .{}));
    try std.testing.expect(!invalid.system_wide);
}

test "keybindingIO.test: systemWide parses a boolean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const item = try keybinding_io.readUserKeybindingItem(allocator, allocator, try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{ "key": "ctrl+cmd+a", "command": "firstcommand", "systemWide": true }
    , .{}));
    try std.testing.expect(item.system_wide);
}
