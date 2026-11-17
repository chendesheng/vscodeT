// Port of the color-map/token/storage subset of
// `src/vs/workbench/services/themes/common/colorThemeData.ts`.
//
// Terminal adaptations and current scope:
// - File/extension theme loading (`ensureLoaded`, plist/tmTheme parsing,
//   extension resource loader, watch) is not ported yet; only the in-memory
//   theme data, custom/transient colors and storage round-trip are.
// - The global color registry is passed explicitly, and maps are keyed by the
//   original hex strings so token backgrounds keep their authored casing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Color = @import("../../../../base/common/color.zig").Color;
const color_utils = @import("../../../../platform/theme/common/colorUtils.zig");
const theme_service = @import("../../../../platform/theme/common/themeService.zig");
const theme_mod = @import("../../../../platform/theme/common/theme.zig");
const storage_mod = @import("../../../../platform/storage/common/storage.zig");

const ColorRegistry = color_utils.ColorRegistry;
const ColorValue = color_utils.ColorValue;
const IColorTheme = theme_service.IColorTheme;
const ColorScheme = theme_mod.ColorScheme;
const InMemoryStorageService = storage_mod.InMemoryStorageService;

pub const TokenStyleSettings = struct {
    foreground: ?[]const u8 = null,
    background: ?[]const u8 = null,
    font_style: ?[]const u8 = null,
};

pub const TokenColor = struct {
    settings: TokenStyleSettings,
    scope: ?[]const []const u8 = null,
};

pub const ColorThemeData = struct {
    pub const STORAGE_KEY = "workbench.colorTheme";

    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    registry: *ColorRegistry,
    id: []const u8,
    label: []const u8,
    settings_id: []const u8,
    theme_type: ColorScheme,
    color_map: std.StringHashMap([]const u8),
    custom_colors: std.StringHashMap([]const u8),
    transient_colors: ?std.StringHashMap(Color),
    token_colors: []TokenColor,

    pub fn createUnloadedTheme(allocator: Allocator, registry: *ColorRegistry, id: []const u8, color_map: []const [2][]const u8) !*ColorThemeData {
        const self = try allocator.create(ColorThemeData);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        self.* = .{
            .allocator = allocator,
            .arena = arena,
            .registry = registry,
            .id = undefined,
            .label = undefined,
            .settings_id = undefined,
            .theme_type = themeTypeFromId(id),
            .color_map = undefined,
            .custom_colors = undefined,
            .transient_colors = null,
            .token_colors = &.{},
        };
        const arena_allocator = self.arena.allocator();
        self.id = try arena_allocator.dupe(u8, id);
        self.label = try arena_allocator.dupe(u8, "");
        self.settings_id = try prefixedId(arena_allocator, id);
        self.color_map = std.StringHashMap([]const u8).init(arena_allocator);
        self.custom_colors = std.StringHashMap([]const u8).init(arena_allocator);
        for (color_map) |entry| {
            try self.color_map.put(try arena_allocator.dupe(u8, entry[0]), try arena_allocator.dupe(u8, entry[1]));
        }
        self.token_colors = try buildTokenColors(arena_allocator, self.color_map, null);
        return self;
    }

    pub fn deinit(self: *ColorThemeData) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn getColor(self: *ColorThemeData, color_id: []const u8, use_default: bool) ?Color {
        if (self.transient_colors) |transient| {
            if (transient.get(color_id)) |color| return color;
        }
        if (self.custom_colors.get(color_id)) |raw| return Color.fromHex(raw) catch null;
        if (self.color_map.get(color_id)) |raw| return Color.fromHex(raw) catch null;
        if (!use_default) return null;
        const iface = self.interface();
        return self.registry.resolveDefaultColor(color_id, &iface);
    }

    pub fn defines(self: *ColorThemeData, color_id: []const u8) bool {
        if (self.transient_colors) |transient| {
            if (transient.contains(color_id)) return true;
        }
        return self.custom_colors.contains(color_id) or self.color_map.contains(color_id);
    }

    pub fn getColorCustomization(self: *ColorThemeData, color_id: []const u8) ?Color {
        const raw = self.custom_colors.get(color_id) orelse return null;
        return Color.fromHex(raw) catch null;
    }

    pub fn setCustomColors(self: *ColorThemeData, colors: []const [2][]const u8) !void {
        self.custom_colors.clearRetainingCapacity();
        for (colors) |entry| {
            try self.custom_colors.put(
                try self.arena.allocator().dupe(u8, entry[0]),
                try self.arena.allocator().dupe(u8, entry[1]),
            );
        }
        try self.refreshTokenColors();
    }

    /// Replaces runtime-only colors; they are deliberately excluded from
    /// theme storage.
    pub fn setTransientColors(self: *ColorThemeData, colors: ?[]const [2][]const u8) !void {
        self.transient_colors = null;
        if (colors) |entries| {
            var transient = std.StringHashMap(Color).init(self.arena.allocator());
            for (entries) |entry| {
                try transient.put(
                    try self.arena.allocator().dupe(u8, entry[0]),
                    Color.fromHex(entry[1]) catch continue,
                );
            }
            self.transient_colors = transient;
        }
        try self.refreshTokenColors();
    }

    pub fn getBaseTheme(self: *ColorThemeData) !*ColorThemeData {
        if (self.transient_colors == null) return self;
        const theme = try self.allocator.create(ColorThemeData);
        errdefer self.allocator.destroy(theme);
        theme.* = .{
            .allocator = self.allocator,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .registry = self.registry,
            .id = undefined,
            .label = undefined,
            .settings_id = undefined,
            .theme_type = self.theme_type,
            .color_map = undefined,
            .custom_colors = undefined,
            .transient_colors = null,
            .token_colors = &.{},
        };
        const allocator = theme.arena.allocator();
        theme.id = try allocator.dupe(u8, self.id);
        theme.label = try allocator.dupe(u8, self.label);
        theme.settings_id = try allocator.dupe(u8, self.settings_id);
        theme.color_map = std.StringHashMap([]const u8).init(allocator);
        var colors = self.color_map.iterator();
        while (colors.next()) |entry| {
            try theme.color_map.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
        }
        theme.custom_colors = std.StringHashMap([]const u8).init(allocator);
        var custom = self.custom_colors.iterator();
        while (custom.next()) |entry| {
            try theme.custom_colors.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
        }
        theme.token_colors = try buildTokenColors(allocator, theme.color_map, null);
        return theme;
    }

    pub fn getTokenColors(self: *const ColorThemeData) []const TokenColor {
        return self.token_colors;
    }

    fn refreshTokenColors(self: *ColorThemeData) !void {
        self.token_colors = try buildTokenColors(self.arena.allocator(), self.color_map, self.transient_colors);
    }

    pub fn interface(self: *ColorThemeData) IColorTheme {
        return .{
            .theme_type = self.theme_type,
            .label = self.label,
            .context = self,
            .vtable = &vtable,
        };
    }

    const vtable = IColorTheme.VTable{
        .getColor = interfaceGetColor,
        .defines = interfaceDefines,
        .getTokenStyleMetadata = interfaceGetTokenStyleMetadata,
    };

    fn interfaceGetColor(context: *anyopaque, color_id: []const u8, use_default: bool) ?Color {
        const self: *ColorThemeData = @ptrCast(@alignCast(context));
        return self.getColor(color_id, use_default);
    }

    fn interfaceDefines(context: *anyopaque, color_id: []const u8) bool {
        const self: *ColorThemeData = @ptrCast(@alignCast(context));
        return self.defines(color_id);
    }

    fn interfaceGetTokenStyleMetadata(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const u8) ?theme_service.ITokenStyle {
        return null;
    }

    pub fn toStorage(self: *ColorThemeData, storage: *InMemoryStorageService) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var root = std.json.ObjectMap{};
        try root.put(allocator, "id", .{ .string = self.id });
        try root.put(allocator, "label", .{ .string = self.label });
        try root.put(allocator, "settingsId", .{ .string = self.settings_id });
        try root.put(allocator, "themeTokenColors", .{ .array = std.array_list.Managed(std.json.Value).init(allocator) });
        var colors = std.json.ObjectMap{};
        var iterator = self.color_map.iterator();
        while (iterator.next()) |entry| {
            try colors.put(allocator, entry.key_ptr.*, .{ .string = entry.value_ptr.* });
        }
        try root.put(allocator, "colorMap", .{ .object = colors });

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try std.json.Stringify.value(std.json.Value{ .object = root }, .{}, &out.writer);
        try storage.store(STORAGE_KEY, .{ .string = out.written() }, .profile, .user);
    }

    pub fn fromStorageData(allocator: Allocator, registry: *ColorRegistry, storage: *InMemoryStorageService) !?*ColorThemeData {
        const raw = storage.get(STORAGE_KEY, .profile, null) orelse return null;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return null,
        };
        const id = switch (object.get("id") orelse return null) {
            .string => |value| value,
            else => return null,
        };
        const theme = try ColorThemeData.createUnloadedTheme(allocator, registry, id, &.{});
        if (object.get("label")) |label| {
            if (label == .string) theme.label = try theme.arena.allocator().dupe(u8, label.string);
        }
        if (object.get("settingsId")) |settings_id| {
            if (settings_id == .string) theme.settings_id = try theme.arena.allocator().dupe(u8, settings_id.string);
        }
        if (object.get("colorMap")) |color_map| {
            if (color_map == .object) {
                var iterator = color_map.object.iterator();
                while (iterator.next()) |entry| {
                    const hex = switch (entry.value_ptr.*) {
                        .string => |value| value,
                        else => continue,
                    };
                    try theme.color_map.put(
                        try theme.arena.allocator().dupe(u8, entry.key_ptr.*),
                        try theme.arena.allocator().dupe(u8, hex),
                    );
                }
            }
        }
        try theme.refreshTokenColors();
        return theme;
    }
};

fn buildTokenColors(allocator: Allocator, color_map: std.StringHashMap([]const u8), transient: ?std.StringHashMap(Color)) ![]TokenColor {
    const result = try allocator.alloc(TokenColor, 1);
    var background: ?[]const u8 = null;
    if (transient) |colors| {
        if (colors.get("editor.background")) |color| {
            background = try formatHex(color, allocator);
        }
    }
    if (background == null) {
        background = color_map.get("editor.background");
    }
    result[0] = .{ .settings = .{ .background = background } };
    return result;
}

fn formatHex(color: Color, allocator: Allocator) ![]u8 {
    const digits = "0123456789ABCDEF";
    const result = try allocator.alloc(u8, 7);
    result[0] = '#';
    result[1] = digits[color.r >> 4];
    result[2] = digits[color.r & 0xF];
    result[3] = digits[color.g >> 4];
    result[4] = digits[color.g & 0xF];
    result[5] = digits[color.b >> 4];
    result[6] = digits[color.b & 0xF];
    return result;
}

fn prefixedId(allocator: Allocator, id: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, id.len + 2);
    result[0] = '_';
    result[1] = '_';
    @memcpy(result[2..], id);
    return result;
}

fn themeTypeFromId(id: []const u8) ColorScheme {
    if (std.mem.indexOf(u8, id, "hc-black") != null) return .HIGH_CONTRAST_DARK;
    if (std.mem.indexOf(u8, id, "hc-light") != null) return .HIGH_CONTRAST_LIGHT;
    if (std.mem.indexOf(u8, id, "light") != null) return .LIGHT;
    return .DARK;
}
