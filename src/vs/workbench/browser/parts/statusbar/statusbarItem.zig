// Port of the portable presentation in
// `src/vs/workbench/browser/parts/statusbar/statusbarItem.ts`.
//
// The browser item owns a DOM container, an icon label, hover listeners and a
// managed hover. The terminal item builds the equivalent `ui` subtree: an item
// container, a flex label and its text. Hover/pinning/command listeners remain
// in the part because the TUI has no managed hover service.
//
// Terminal adaptation: codicon syntax is not interpreted, progress/beak icons
// become a leading glyph, CSS `text-overflow: ellipsis` becomes pre-truncation
// with `…`, and the focus outline becomes an underline. The label's padding and
// margins are cell approximations of the upstream pixel values. Item-kind and
// hover colors come from the terminal `Theme` resolved by the part from the
// `statusBarItem.*` ids.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const statusbar = @import("../../../services/statusbar/browser/statusbar.zig");
const StatusbarEntry = statusbar.StatusbarEntry;
const StatusbarEntryKind = statusbar.StatusbarEntryKind;
const StatusbarProgress = statusbar.StatusbarProgress;

pub const KindColors = struct {
    background: ui.Color,
    foreground: ui.Color,
    hover_background: ui.Color,
    hover_foreground: ui.Color,
};

/// Terminal colors for the status-bar item kinds. The workbench resolves the
/// `statusBarItem.*` ids and passes this bundle; the defaults keep the item
/// usable in isolation and in tests.
pub const Theme = struct {
    standard_hover_background: ui.Color = .{ .r = 55, .g = 55, .b = 55 },
    compact_hover_background: ui.Color = .{ .r = 75, .g = 75, .b = 75 },
    prominent: KindColors = .{
        .background = .{ .r = 0, .g = 61, .b = 102 },
        .foreground = .{ .r = 255, .g = 255, .b = 255 },
        .hover_background = .{ .r = 0, .g = 91, .b = 132 },
        .hover_foreground = .{ .r = 255, .g = 255, .b = 255 },
    },
    warning: KindColors = .{
        .background = .{ .r = 90, .g = 74, .b = 0 },
        .foreground = .{ .r = 255, .g = 255, .b = 255 },
        .hover_background = .{ .r = 120, .g = 104, .b = 30 },
        .hover_foreground = .{ .r = 255, .g = 255, .b = 255 },
    },
    @"error": KindColors = .{
        .background = .{ .r = 90, .g = 29, .b = 29 },
        .foreground = .{ .r = 255, .g = 255, .b = 255 },
        .hover_background = .{ .r = 120, .g = 59, .b = 59 },
        .hover_foreground = .{ .r = 255, .g = 255, .b = 255 },
    },
    remote: KindColors = .{
        .background = .{ .r = 0, .g = 122, .b = 204 },
        .foreground = .{ .r = 255, .g = 255, .b = 255 },
        .hover_background = .{ .r = 30, .g = 152, .b = 234 },
        .hover_foreground = .{ .r = 255, .g = 255, .b = 255 },
    },
    offline: KindColors = .{
        .background = .{ .r = 108, .g = 23, .b = 23 },
        .foreground = .{ .r = 255, .g = 255, .b = 255 },
        .hover_background = .{ .r = 138, .g = 53, .b = 53 },
        .hover_foreground = .{ .r = 255, .g = 255, .b = 255 },
    },

    pub fn colors(self: Theme, kind: StatusbarEntryKind) KindColors {
        return switch (kind) {
            .standard => self.remote,
            .prominent => self.prominent,
            .warning => self.warning,
            .@"error" => self.@"error",
            .remote => self.remote,
            .offline => self.offline,
        };
    }

    pub fn dark() Theme {
        return .{};
    }
};

pub const ItemOptions = struct {
    /// Terminal equivalent of `max-width: 40vw`, computed from the status bar
    /// width. Zero means no bound.
    max_width_cells: usize = 0,
    first_visible: bool = false,
    last_visible: bool = false,
    compact_left: bool = false,
    compact_right: bool = false,
    has_background: bool = false,
};

pub const ItemState = struct {
    hovered: bool = false,
    /// A compact-group partner of the hovered entry.
    compact_hovered: bool = false,
    focused: bool = false,
};

pub const ItemNodes = struct {
    container: *ui.Node,
    label: *ui.Node,
    text: *ui.Node,
};

pub const StatusbarItem = struct {
    entry: StatusbarEntry,
    theme: Theme = Theme.dark(),

    pub fn init(entry: StatusbarEntry) StatusbarItem {
        return .{ .entry = entry };
    }

    pub fn setTheme(self: *StatusbarItem, theme: Theme) void {
        self.theme = theme;
    }

    pub fn update(self: *StatusbarItem, entry: StatusbarEntry) void {
        self.entry = entry;
    }

    pub fn name(self: *const StatusbarItem) []const u8 {
        return self.entry.name;
    }

    pub fn text(self: *const StatusbarItem) []const u8 {
        return self.entry.text;
    }

    pub fn hasCommand(self: *const StatusbarItem) bool {
        return self.entry.command != null;
    }

    pub fn command(self: *const StatusbarItem) ?statusbar.StatusbarCommand {
        return self.entry.command;
    }

    pub fn kind(self: *const StatusbarItem) StatusbarEntryKind {
        return self.entry.kind;
    }

    pub fn tooltip(self: *const StatusbarItem) ?[]const u8 {
        return self.entry.tooltip;
    }

    pub fn showBeak(self: *const StatusbarItem) bool {
        return self.entry.show_beak;
    }

    pub fn showProgress(self: *const StatusbarItem) StatusbarProgress {
        return self.entry.show_progress;
    }

    /// Terminal replacement for the progress codicon / notification beak. The
    /// beak is a prefix because an absolutely positioned beak above the
    /// one-row status surface would be clipped.
    pub fn leadingGlyph(self: *const StatusbarItem) ?[]const u8 {
        return switch (self.entry.show_progress) {
            .off => if (self.entry.show_beak) "\u{25B4} " else null,
            .loading => "\u{27F3} ",
            .syncing => "\u{21BB} ",
        };
    }

    pub fn labelBackground(self: *const StatusbarItem, hovered: bool) ui.Color {
        if (self.entry.kind == .standard) {
            return self.theme.standard_hover_background;
        }
        const colors = self.theme.colors(self.entry.kind);
        return if (hovered) colors.hover_background else colors.background;
    }

    pub fn foreground(self: *const StatusbarItem, hovered: bool) ui.Color {
        if (self.entry.kind == .standard) {
            return self.theme.standard_hover_background;
        }
        const colors = self.theme.colors(self.entry.kind);
        return if (hovered) colors.hover_foreground else colors.foreground;
    }

    /// Builds the terminal item container and label. `max_width_cells` bounds
    /// the item; text is truncated before the node is created so the label
    /// carries an ellipsis like the browser's `text-overflow`.
    pub fn build(
        self: *const StatusbarItem,
        doc: *ui.Document,
        options: ItemOptions,
        state: ItemState,
    ) !ItemNodes {
        const container = try doc.createElement(.div);
        container.setStyle(.{
            .display = .inline_block,
            .height = .{ .percent = 100 },
            .max_width = if (options.max_width_cells > 0)
                .{ .cells = @floatFromInt(options.max_width_cells) }
            else
                .auto,
            .flex_shrink = 0,
            .background = if (state.compact_hovered and !state.hovered)
                self.theme.compact_hover_background
            else if (self.entry.kind == .standard and !state.hovered)
                null
            else
                self.labelBackground(state.hovered),
            .color = if (self.entry.kind == .standard) null else self.foreground(state.hovered),
        });

        const padding = labelPadding(options);
        const prefix = self.leadingGlyph();
        const prefix_width = if (prefix) |value| doc.measureText(value) else 0;
        const max_width = if (options.max_width_cells > 0)
            options.max_width_cells
        else
            std.math.maxInt(usize);
        const inner_budget = max_width -| @as(usize, @intFromFloat(padding.left + padding.right)) -| prefix_width;

        const label = try doc.createElement(.span);
        label.setStyle(.{
            .display = .flex,
            .align_items = .center,
            .height = .{ .percent = 100 },
            .white_space = .pre,
            .overflow = .hidden,
            .padding = .{ .left = padding.left, .right = padding.right },
            .underline = state.focused,
        });

        if (prefix) |value| {
            const prefix_node = try doc.createText(value);
            _ = try label.appendChild(prefix_node);
        }

        const text_node = try doc.createText(try prepareText(doc, self.entry.text, inner_budget));
        _ = try label.appendChild(text_node);
        _ = try container.appendChild(label);

        return .{ .container = container, .label = label, .text = text_node };
    }
};

fn labelPadding(options: ItemOptions) ui.Edges {
    var left: f64 = 1;
    var right: f64 = 1;
    if (options.first_visible) left = 0;
    if (options.last_visible) right = 0;
    if (options.compact_left) right = 0;
    if (options.compact_right) left = 0;
    if (options.has_background) {
        if (left > 0) left = 1;
        if (right > 0) right = 1;
    }
    return .{ .left = left, .right = right };
}

fn prepareText(doc: *ui.Document, text: []const u8, budget: usize) ![]const u8 {
    const allocator = doc.arena.allocator();
    var sanitized = std.array_list.Managed(u8).init(allocator);
    errdefer sanitized.deinit();

    var offset: usize = 0;
    var buffer: [4]u8 = undefined;
    while (offset < text.len) {
        const decoded = ui.dom.decodeAt(text, offset);
        var cp = decoded.cp;
        if (cp < 0x20 or cp == 0x7f) cp = ' ';
        const len = std.unicode.utf8Encode(cp, &buffer) catch {
            offset += if (decoded.len == 0) 1 else decoded.len;
            continue;
        };
        try sanitized.appendSlice(buffer[0..len]);
        offset += if (decoded.len == 0) 1 else decoded.len;
    }

    const total = doc.measureText(sanitized.items);
    if (total <= budget) return sanitized.toOwnedSlice();

    // Reserve one cell for the ellipsis.
    const limit = budget -| 1;
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    var width: usize = 0;
    offset = 0;
    while (offset < sanitized.items.len) {
        const decoded = ui.dom.decodeAt(sanitized.items, offset);
        const cell_width = doc.measure_width(decoded.cp);
        if (width + cell_width > limit) break;
        result.appendSlice(sanitized.items[offset .. offset + decoded.len]) catch |err| {
            result.deinit();
            return err;
        };
        width += cell_width;
        offset += decoded.len;
    }
    if (budget > 0) try result.appendSlice("\u{2026}");
    return result.toOwnedSlice();
}

test "StatusbarItem: builds a label, truncates and renders progress" {
    const allocator = std.testing.allocator;
    var doc = try ui.Document.init(allocator, .{ .cols = 20, .rows = 1 });
    defer doc.deinit();

    var item = StatusbarItem.init(.{
        .name = "Language",
        .text = "a very long language name",
        .show_progress = .loading,
        .kind = .prominent,
    });
    const nodes = try item.build(&doc, .{ .max_width_cells = 12 }, .{ .hovered = true });
    try std.testing.expectEqualStrings("\u{27F3} ", item.leadingGlyph().?);
    try std.testing.expect(nodes.text.asText().data.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, nodes.text.asText().data, "\u{2026}"));
    try std.testing.expect(nodes.label.style().display == .flex);
    const max_width = switch (nodes.container.style().max_width.?) {
        .cells => |value| value,
        else => 0,
    };
    try std.testing.expectEqual(@as(f64, 12), max_width);

    item.update(.{ .name = "Language", .text = "zig" });
    const short = try item.build(&doc, .{}, .{});
    try std.testing.expectEqualStrings("zig", short.text.asText().data);
    try std.testing.expect(!item.hasCommand());
}

test "StatusbarItem: theme controls kind and hover colors" {
    var item = StatusbarItem.init(.{
        .name = "Problems",
        .text = "2",
        .kind = .warning,
    });
    const theme = Theme{
        .warning = .{
            .background = .{ .r = 10, .g = 20, .b = 30 },
            .foreground = .{ .r = 40, .g = 50, .b = 60 },
            .hover_background = .{ .r = 70, .g = 80, .b = 90 },
            .hover_foreground = .{ .r = 100, .g = 110, .b = 120 },
        },
        .standard_hover_background = .{ .r = 130, .g = 140, .b = 150 },
    };
    item.setTheme(theme);

    try std.testing.expect(item.labelBackground(false).eql(theme.warning.background));
    try std.testing.expect(item.foreground(false).eql(theme.warning.foreground));
    try std.testing.expect(item.labelBackground(true).eql(theme.warning.hover_background));
    try std.testing.expect(item.foreground(true).eql(theme.warning.hover_foreground));

    var standard = StatusbarItem.init(.{ .name = "Ready", .text = "" });
    standard.setTheme(theme);
    try std.testing.expect(standard.labelBackground(true).eql(theme.standard_hover_background));
}

test "StatusbarItem: compact hover uses the compact background" {
    const allocator = std.testing.allocator;
    var doc = try ui.Document.init(allocator, .{ .cols = 20, .rows = 1 });
    defer doc.deinit();

    var item = StatusbarItem.init(.{ .name = "Ready", .text = "ready" });
    item.setTheme(.{ .compact_hover_background = .{ .r = 9, .g = 8, .b = 7 } });
    const nodes = try item.build(&doc, .{}, .{ .compact_hovered = true });
    try std.testing.expect(nodes.container.style().background.?.eql(.{ .r = 9, .g = 8, .b = 7 }));
}
