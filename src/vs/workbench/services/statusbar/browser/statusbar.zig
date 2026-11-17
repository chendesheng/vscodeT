// Port of the portable contract in
// `src/vs/workbench/services/statusbar/browser/statusbar.ts`.
//
// The browser service exposes DOM containers, theme colors and markdown/HTML
// tooltip content. The terminal contract keeps the portable entry shape:
// alignment, priority/location, command metadata, kind, progress/beak flags and
// plain-text tooltip/aria labels. Direct `color`/`backgroundColor` theme values,
// `content` nodes, `showInAllWindows`, markdown/HTML tooltips and the scoped or
// auxiliary service variants are not representable without the workbench theme,
// DOM and multi-window services; they are documented omissions, not invented
// behaviour.
//
// Terminal adaptation: RGB style overrides are terminal cell colors rather than
// `ColorIdentifier` theme ids, and tooltip content is plain text.

const std = @import("std");

pub const StatusbarAlignment = enum { left, right };

/// Upstream `IStatusbarEntryLocation`.
pub const StatusbarEntryLocation = struct {
    location: struct {
        id: []const u8,
        priority: f64,
    },
    alignment: StatusbarAlignment,
    /// Move the entry close to the referenced entry.
    compact: bool = false,
};

/// Upstream `IStatusbarEntryPriority.primary`.
pub const PrimaryPriority = union(enum) {
    number: f64,
    location: StatusbarEntryLocation,
};

/// Upstream `IStatusbarEntryPriority`.
pub const StatusbarEntryPriority = struct {
    primary: PrimaryPriority,
    secondary: f64,
};

pub fn isStatusbarEntryLocation(value: PrimaryPriority) bool {
    return switch (value) {
        .location => true,
        .number => false,
    };
}

pub fn isStatusbarEntryPriority(priority: StatusbarEntryPriority) bool {
    return switch (priority.primary) {
        .number => true,
        .location => |location| location.location.id.len > 0,
    };
}

pub const StatusbarEntryKind = enum {
    standard,
    warning,
    @"error",
    prominent,
    remote,
    offline,
};

/// Upstream `showProgress: boolean | 'loading' | 'syncing'`.
pub const StatusbarProgress = enum { off, loading, syncing };

/// Upstream `Command` subset used by status-bar entries. The terminal command
/// registry currently ignores arguments, but they stay in the contract so
/// callers keep upstream metadata.
pub const StatusbarCommand = struct {
    id: []const u8,
    arguments: []const []const u8 = &.{},
};

pub const show_tooltip_command_id = "statusBar.entry.showTooltip";
pub const toggle_tooltip_command_id = "statusBar.entry.toggleTooltip";

pub fn isTooltipCommand(command: StatusbarCommand) bool {
    return std.mem.eql(u8, command.id, show_tooltip_command_id) or
        std.mem.eql(u8, command.id, toggle_tooltip_command_id);
}

/// Upstream `IStatusbarEntry`, with terminal-only substitutions documented in
/// the file header.
pub const StatusbarEntry = struct {
    name: []const u8,
    text: []const u8,
    aria_label: []const u8 = "",
    role: ?[]const u8 = null,
    /// Plain text. Markdown is rendered as its source text; HTML/command
    /// tooltips are not represented.
    tooltip: ?[]const u8 = null,
    command: ?StatusbarCommand = null,
    show_beak: bool = false,
    show_progress: StatusbarProgress = .off,
    kind: StatusbarEntryKind = .standard,
    extension_id: ?[]const u8 = null,
};

/// Upstream `Partial<IStatusbarEntry>` for `overrideEntry`. `command_set`
/// distinguishes "leave unchanged" from "clear the command".
pub const StatusbarEntryOverride = struct {
    name: ?[]const u8 = null,
    text: ?[]const u8 = null,
    aria_label: ?[]const u8 = null,
    role: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
    command_set: bool = false,
    command: ?StatusbarCommand = null,
    show_beak: ?bool = null,
    show_progress: ?StatusbarProgress = null,
    kind: ?StatusbarEntryKind = null,
    extension_id: ?[]const u8 = null,
};

pub fn applyEntryOverride(base: StatusbarEntry, override: StatusbarEntryOverride) StatusbarEntry {
    var entry = base;
    if (override.name) |value| entry.name = value;
    if (override.text) |value| entry.text = value;
    if (override.aria_label) |value| entry.aria_label = value;
    if (override.role) |value| entry.role = value;
    if (override.tooltip) |value| entry.tooltip = value;
    if (override.command_set) entry.command = override.command;
    if (override.show_beak) |value| entry.show_beak = value;
    if (override.show_progress) |value| entry.show_progress = value;
    if (override.kind) |value| entry.kind = value;
    if (override.extension_id) |value| entry.extension_id = value;
    return entry;
}

/// Upstream `IStatusbarStyleOverride`. Terminal adaptation: colors are concrete
/// cell RGB values because the workbench color registry is not ported.
pub const StatusbarStyleOverride = struct {
    /// Lower has higher priority.
    priority: f64,
    foreground: ?[3]u8 = null,
    background: ?[3]u8 = null,
    border: ?[3]u8 = null,
};

/// Terminal command executor. The browser item calls `ICommandService`; the
/// part accepts an explicit callback so it does not depend on a TUI registry.
pub const StatusbarCommandExecutor = struct {
    context: *anyopaque,
    execute: *const fn (context: *anyopaque, command: StatusbarCommand) anyerror!void,
};

test "statusbar contract: location and override semantics" {
    const location = StatusbarEntryLocation{
        .location = .{ .id = "status.editor.mode", .priority = 10 },
        .alignment = .right,
        .compact = true,
    };
    try std.testing.expect(isStatusbarEntryLocation(.{ .location = location }));
    try std.testing.expect(!isStatusbarEntryLocation(.{ .number = 1 }));

    const base = StatusbarEntry{
        .name = "Mode",
        .text = "zig",
        .command = .{ .id = "old.command" },
    };
    const overridden = applyEntryOverride(base, .{
        .text = "Zig",
        .command_set = true,
    });
    try std.testing.expectEqualStrings("Zig", overridden.text);
    try std.testing.expect(overridden.command == null);

    const unchanged = applyEntryOverride(base, .{ .kind = .prominent });
    try std.testing.expectEqualStrings("old.command", unchanged.command.?.id);
    try std.testing.expectEqual(StatusbarEntryKind.prominent, unchanged.kind);
    try std.testing.expect(isTooltipCommand(.{ .id = toggle_tooltip_command_id }));
}
