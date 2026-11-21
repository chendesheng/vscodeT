// Terminal host for the user-keybindings half of
// `src/vs/workbench/services/keybinding/browser/keybindingService.ts`.
//
// Upstream `UserKeybindings` watches the user data profile file through the
// file service. The terminal reads the same JSONC array from the discovered
// paths (VS Code profile first, TUI override last) and rebuilds the items when
// the settings watcher reports a change.
//
// `Workbench` loads this object on the async Io for watcher-triggered reloads
// and installs the parsed items on the TUI thread; the synchronous path is
// kept for startup.
//
// Parsed items are `ResolvedKeybindingItem`s with `isDefault = false`:
// - non-removal entries become user bindings (resolved against the terminal's
//   Ctrl-only key map, exactly like the default rules);
// - `-command` entries are removals. Passing them as resolver overrides lets
//   the ported `KeybindingResolver.handleRemovals` subtract the matching
//   default bindings from every host.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const time_compat = @import("../../../../base/common/timeCompat.zig");
const configuration_models = @import("../../../../platform/configuration/common/configurationModels.zig");
const key_bindings = @import("../../../../base/common/keybindings.zig");
const resolved_item = @import("../../../../platform/keybinding/common/resolvedKeybindingItem.zig");
const us_layout = @import("../../../../platform/keybinding/common/usLayoutResolvedKeybinding.zig");
const keybinding_io = @import("../common/keybindingIO.zig");
const keybinding_service = @import("./keybindingService.zig");

const ResolvedKeybindingItem = resolved_item.ResolvedKeybindingItem;
const USLayoutResolvedKeybinding = us_layout.USLayoutResolvedKeybinding;

pub const max_keybindings_file_size: usize = 10 * 1024 * 1024;

pub const UserKeybindings = struct {
    allocator: Allocator,
    json_arena: std.heap.ArenaAllocator,
    key_arena: std.heap.ArenaAllocator,
    items: std.array_list.Managed(*const ResolvedKeybindingItem),
    removal_items: std.array_list.Managed(*const ResolvedKeybindingItem),
    error_count: usize = 0,

    pub fn load(allocator: Allocator, io: Io, paths: []const []const u8) !*UserKeybindings {
        const self = try allocator.create(UserKeybindings);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .json_arena = std.heap.ArenaAllocator.init(allocator),
            .key_arena = std.heap.ArenaAllocator.init(allocator),
            .items = std.array_list.Managed(*const ResolvedKeybindingItem).init(allocator),
            .removal_items = std.array_list.Managed(*const ResolvedKeybindingItem).init(allocator),
        };
        errdefer self.deinit();

        for (paths) |path| {
            self.loadFile(io, path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => self.error_count += 1,
            };
        }
        return self;
    }

    pub fn deinit(self: *UserKeybindings) void {
        self.items.deinit();
        self.removal_items.deinit();
        self.key_arena.deinit();
        self.json_arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn userItems(self: *const UserKeybindings) []const *const ResolvedKeybindingItem {
        return self.items.items;
    }

    /// Removal entries for `KeybindingResolver.handleRemovals`.
    pub fn removals(self: *const UserKeybindings) []const *const ResolvedKeybindingItem {
        return self.removal_items.items;
    }

    fn loadFile(self: *UserKeybindings, io: Io, path: []const u8) !void {
        const text = Io.Dir.cwd().readFileAlloc(
            io,
            path,
            self.allocator,
            .limited(max_keybindings_file_size),
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(text);

        const sanitized = configuration_models.stripJsonc(self.json_arena.allocator(), text) catch {
            self.error_count += 1;
            return;
        };
        const value = std.json.parseFromSliceLeaky(
            std.json.Value,
            self.json_arena.allocator(),
            sanitized,
            .{ .duplicate_field_behavior = .use_last },
        ) catch {
            self.error_count += 1;
            return;
        };
        if (value != .array) {
            self.error_count += 1;
            return;
        }
        for (value.array.items) |entry| {
            if (entry != .object) continue;
            const parsed = keybinding_io.readUserKeybindingItem(
                self.key_arena.allocator(),
                self.json_arena.allocator(),
                entry,
            ) catch {
                self.error_count += 1;
                continue;
            };
            const is_removal = if (parsed.command) |command|
                command.len > 0 and command[0] == '-'
            else
                false;
            self.append(parsed, is_removal) catch {
                self.error_count += 1;
            };
        }
    }

    fn append(self: *UserKeybindings, parsed: keybinding_io.UserKeybindingItem, is_removal: bool) !void {
        const allocator = self.key_arena.allocator();
        var resolved_interface: ?key_bindings.ResolvedKeybinding = null;
        if (parsed.keybinding) |keybinding| {
            if (try USLayoutResolvedKeybinding.resolveKeybinding(allocator, keybinding, keybinding_service.bindingOS())) |resolved| {
                const held = try allocator.create(USLayoutResolvedKeybinding);
                held.* = resolved;
                resolved_interface = held.interface();
            }
        }
        const item = try allocator.create(ResolvedKeybindingItem);
        item.* = try ResolvedKeybindingItem.init(
            allocator,
            resolved_interface,
            parsed.command,
            parsed.command_args,
            parsed.when,
            false,
            null,
            false,
            parsed.system_wide,
        );
        if (is_removal) {
            try self.removal_items.append(item);
        } else {
            try self.items.append(item);
        }
    }
};

test "UserKeybindings: reads later-layer overrides and removals" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmp(&tmp, io, "vscode.json",
        \\[
        \\  { "key": "ctrl+alt+g", "command": "workbench.action.showCommands", "when": "editorTextFocus" },
        \\  { "command": "-workbench.action.toggleSidebarVisibility" }
        \\]
    );
    try writeTmp(&tmp, io, "tui.json",
        \\[
        \\  { "key": "g g", "command": "list.focusFirst", "when": "listFocus" }
        \\]
    );

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const vscode_path = try std.fmt.allocPrint(allocator, "{s}/vscode.json", .{buffer[0..root_len]});
    defer allocator.free(vscode_path);
    const tui_path = try std.fmt.allocPrint(allocator, "{s}/tui.json", .{buffer[0..root_len]});
    defer allocator.free(tui_path);
    const missing_path = try std.fmt.allocPrint(allocator, "{s}/missing.json", .{buffer[0..root_len]});
    defer allocator.free(missing_path);

    const bindings = try UserKeybindings.load(allocator, io, &.{ vscode_path, tui_path, missing_path });
    defer bindings.deinit();
    try std.testing.expectEqual(@as(usize, 2), bindings.userItems().len);
    try std.testing.expectEqual(@as(usize, 1), bindings.removals().len);
    try std.testing.expectEqual(@as(usize, 0), bindings.error_count);

    const first = bindings.userItems()[0];
    try std.testing.expectEqualStrings("workbench.action.showCommands", first.command.?);
    try std.testing.expect(first.when != null);
    try std.testing.expect(!first.isDefault);
    const second = bindings.userItems()[1];
    try std.testing.expectEqualStrings("list.focusFirst", second.command.?);
    try std.testing.expectEqual(@as(usize, 2), second.chords.len);
    try std.testing.expectEqualStrings("-workbench.action.toggleSidebarVisibility", bindings.removals()[0].command.?);
}

fn writeTmp(tmp: *std.testing.TmpDir, io: Io, name: []const u8, contents: []const u8) !void {
    var file = try tmp.dir.createFile(io, name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}
