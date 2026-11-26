// Portable subset of
// `src/vs/workbench/contrib/codeEditor/browser/quickaccess/gotoSymbolQuickAccess.ts`.
//
// Terminal adaptations: fuzzy scoring and the browser quick-access registry are
// not ported (the TUI quick pick filters labels); the outline tree is flattened
// into depth-tagged entries and rendered with the same terminal glyphs used by
// the breadcrumb bar.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Range = @import("../../../../../editor/common/core/range.zig").Range;
const Position = @import("../../../../../editor/common/core/position.zig").Position;
const outline_model = @import("../../../../../editor/contrib/documentSymbols/browser/outlineModel.zig");
const OutlineElement = outline_model.OutlineElement;
const OutlineModel = outline_model.OutlineModel;

pub const command_id = "workbench.action.gotoSymbol";
pub const command_label = "Go to Symbol in Editor...";
pub const placeholder = "Go to Symbol in Editor";
pub const no_provider_message = "The active text editor does not provide symbol information.";
pub const no_symbols_message = "No editor symbols";
pub const no_matching_message = "No matching editor symbols";

pub const Entry = struct {
    symbol: *const OutlineElement,
    depth: usize,
};

pub fn collect(allocator: Allocator, model: *const OutlineModel) ![]Entry {
    var result = std.array_list.Managed(Entry).init(allocator);
    errdefer result.deinit();
    for (model.roots) |root| try appendElement(&result, root, 0);
    return result.toOwnedSlice();
}

fn appendElement(result: *std.array_list.Managed(Entry), element: *const OutlineElement, depth: usize) !void {
    try result.append(.{ .symbol = element, .depth = depth });
    for (element.children) |child| try appendElement(result, child, depth + 1);
}

pub fn label(allocator: Allocator, entry: Entry) ![]u8 {
    const indent_len = entry.depth * 2;
    const indent = try allocator.alloc(u8, indent_len);
    defer allocator.free(indent);
    @memset(indent, ' ');
    return std.fmt.allocPrint(allocator, "{s}{s} {s}", .{
        indent,
        glyph(entry.symbol.symbol.kind),
        entry.symbol.symbol.name,
    });
}

pub fn glyph(kind: u32) []const u8 {
    return @import("../../../../../editor/common/languages.zig").SymbolKinds.terminalGlyph(kind);
}

pub fn kindLabel(kind: u32) []const u8 {
    return switch (kind) {
        1 => "file",
        2 => "module",
        3 => "namespace",
        4 => "package",
        5 => "class",
        6 => "method",
        7 => "property",
        8 => "field",
        9 => "constructor",
        10 => "enum",
        11 => "interface",
        12 => "function",
        13 => "variable",
        14 => "constant",
        15 => "string",
        16 => "number",
        17 => "boolean",
        18 => "array",
        19 => "object",
        20 => "key",
        21 => "null",
        22 => "enum member",
        23 => "struct",
        24 => "event",
        25 => "operator",
        26 => "type parameter",
        else => "symbol",
    };
}

/// Returns the last entry whose symbol range contains `position`, matching the
/// upstream "enclosing symbol" active-item selection.
pub fn activeIndex(entries: []const Entry, position: Position) ?usize {
    var owned_position = position;
    var active: ?usize = null;
    for (entries, 0..) |entry, index| {
        var range = entry.symbol.symbol.range;
        if (range.containsPosition(&owned_position)) active = index;
    }
    return active;
}

test "gotoSymbolQuickAccess: flatten, label and active symbol" {
    var child = OutlineElement{
        .symbol = .{
            .name = "child",
            .kind = 12,
            .range = Range.init(2, 1, 3, 2),
            .selection_range = Range.init(2, 1, 2, 6),
        },
    };
    var children = [_]*OutlineElement{&child};
    var root = OutlineElement{
        .symbol = .{
            .name = "root",
            .kind = 5,
            .range = Range.init(1, 1, 3, 2),
            .selection_range = Range.init(1, 7, 1, 11),
        },
        .children = children[0..],
    };
    var roots = [_]*OutlineElement{&root};
    const model = OutlineModel{
        .allocator = std.testing.allocator,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .roots = roots[0..],
    };
    defer model.arena.deinit();

    const entries = try collect(std.testing.allocator, &model);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(usize, 0), entries[0].depth);
    try std.testing.expectEqual(@as(usize, 1), entries[1].depth);

    const root_label = try label(std.testing.allocator, entries[0]);
    defer std.testing.allocator.free(root_label);
    try std.testing.expectEqualStrings("ƒ root", root_label);
    const child_label = try label(std.testing.allocator, entries[1]);
    defer std.testing.allocator.free(child_label);
    try std.testing.expectEqualStrings("  · child", child_label);
    try std.testing.expectEqualStrings("function", kindLabel(12));

    try std.testing.expectEqual(@as(?usize, 1), activeIndex(entries, Position.init(2, 3)));
    try std.testing.expectEqual(@as(?usize, 0), activeIndex(entries, Position.init(1, 2)));
    try std.testing.expectEqual(@as(?usize, null), activeIndex(entries, Position.init(4, 1)));
}

const platform_actions = @import("../../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const QuickInputService = @import("../../../../../platform/quickinput/browser/quickInputService.zig").QuickInputService;
const QuickPick = @import("../../../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const QuickPickItem = @import("../../../../../platform/quickinput/common/quickInput.zig").QuickPickItem;
const Editor = @import("../../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const LanguageFeaturesService = @import("../../../../../editor/common/services/languageFeaturesService.zig").LanguageFeaturesService;
const IDisposable = @import("../../../../../base/common/lifecycle.zig").IDisposable;

/// Terminal GotoSymbolQuickAccessProvider. The native input service owns
/// rendering/filtering, while the provider owns the outline subscription and
/// label lifetime. It verifies that the active editor still matches the
/// requested document when an asynchronous outline arrives.
pub const GotoSymbolQuickAccessProvider = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    quick_input: *QuickInputService,
    language_features: *const ?*LanguageFeaturesService,
    host: struct {
        context: *anyopaque,
        active_editor: *const fn (*anyopaque) ?*Editor,
        outline_models: *const fn (*anyopaque) ?*outline_model.OutlineModelService,
        reveal_editor: *const fn (*anyopaque) void,
    },
    symbol_picker: ?struct {
        editor: *Editor,
        subscription: ?IDisposable = null,
        outline: ?*OutlineModel = null,
    } = null,
    pending_symbols: ?[]Entry = null,

    pub fn deinit(self: *GotoSymbolQuickAccessProvider) void {
        if (self.quick_input.handler_context == @as(*anyopaque, self)) self.quick_input.hide();
        self.closeSymbolPicker();
        self.arena.deinit();
    }

    pub fn actionDescriptor(self: *GotoSymbolQuickAccessProvider) platform_actions.Action2 {
        return .{
            .command = .{ .id = command_id, .title = command_label, .category = "Go", .tooltip = "Go to a symbol in the active editor." },
            .f1 = true,
            .context = self,
            .run_fn = struct {
                fn run(context: *anyopaque, _: ServicesAccessor) !void {
                    const provider: *GotoSymbolQuickAccessProvider = @ptrCast(@alignCast(context));
                    _ = provider.provide() catch |err| {
                        if (provider.host.active_editor(provider.host.context)) |editor| editor.setMessage("Symbols failed: {s}", .{@errorName(err)});
                        return;
                    };
                }
            }.run,
        };
    }

    /// Opens the document-symbol picker for the active editor. Ports the
    /// portable behavior of `workbench.action.gotoSymbol`.
    pub fn provide(self: *GotoSymbolQuickAccessProvider) !bool {
        const editor = self.host.active_editor(self.host.context) orelse return false;
        const features = self.language_features.* orelse return false;
        if (self.quick_input.isVisible()) self.quick_input.hide();

        self.pending_symbols = null;
        _ = self.arena.reset(.retain_capacity);

        const models = self.host.outline_models(self.host.context) orelse return false;
        const providers = try features.document_symbol_provider.ordered(self.allocator, editor.model, false);
        defer self.allocator.free(providers);
        if (providers.len == 0) {
            editor.setMessage("{s}", .{no_provider_message});
            return false;
        }
        const input = self.quick_input;
        try input.showPick(&.{}, .{
            .placeholder = placeholder,
            .no_results_label = no_matching_message,
            .cleanup = cleanupSymbolPicker,
            .cleanup_context = self,
        }, onSymbolPick, self);
        input.pickerRef().setBusy(true);
        self.symbol_picker = .{ .editor = editor };
        errdefer input.hide();
        const subscription = try models.getOrCreate(editor.model, providers, self, symbolPickerReady);
        if (self.symbol_picker) |*picker| picker.subscription = subscription;
        return self.symbol_picker != null;
    }

    fn cleanupSymbolPicker(context: *anyopaque) void {
        const self: *GotoSymbolQuickAccessProvider = @ptrCast(@alignCast(context));
        self.closeSymbolPicker();
    }

    fn closeSymbolPicker(self: *GotoSymbolQuickAccessProvider) void {
        if (self.symbol_picker) |picker| {
            if (picker.subscription) |handle| handle.dispose();
            if (picker.outline) |outline| outline.deinit();
        }
        self.symbol_picker = null;
        self.pending_symbols = null;
    }

    fn symbolPickerReady(context: *anyopaque, outline: *OutlineModel) void {
        const self: *GotoSymbolQuickAccessProvider = @ptrCast(@alignCast(context));
        const editor = if (self.symbol_picker) |picker| picker.editor else {
            outline.deinit();
            return;
        };
        self.symbol_picker.?.subscription = null;
        self.symbol_picker.?.outline = outline;
        const input = self.quick_input;
        if (self.host.active_editor(self.host.context) != editor) {
            input.hide();
            return;
        }
        input.pickerRef().setBusy(false);
        self.setSymbolItems(editor, outline) catch |err| {
            editor.setMessage("Symbols failed: {s}", .{@errorName(err)});
            input.hide();
        };
    }

    fn setSymbolItems(self: *GotoSymbolQuickAccessProvider, editor: *Editor, outline: *OutlineModel) !void {
        const arena = self.arena.allocator();
        const entries = try collect(arena, outline);
        if (entries.len == 0) {
            editor.setMessage("{s}", .{no_symbols_message});
            self.quick_input.hide();
            return;
        }

        const active_index = activeIndex(entries, editor.modelCursorPosition());
        var items = std.array_list.Managed(QuickPickItem).init(arena);
        for (entries, 0..) |entry, index| {
            const id = try std.fmt.allocPrint(arena, "sym:{d}", .{index});
            const item_label = try label(arena, entry);
            try items.append(.{ .item = .{
                .id = id,
                .label = item_label,
                .description = kindLabel(entry.symbol.symbol.kind),
            } });
        }
        const active_id = if (active_index) |index| try std.fmt.allocPrint(arena, "sym:{d}", .{index}) else null;

        self.pending_symbols = entries;
        try self.quick_input.setPickItems(items.items, active_id);
    }

    fn onSymbolPick(context: *anyopaque, picker: *QuickPick) anyerror!void {
        const self: *GotoSymbolQuickAccessProvider = @ptrCast(@alignCast(context));
        const entries = self.pending_symbols orelse return;
        const item = picker.selectedItem() orelse picker.activeItem() orelse return;
        self.pending_symbols = null;
        const index = itemIndex(item.id, "sym:") orelse return;
        if (index >= entries.len) return;
        const editor = self.host.active_editor(self.host.context) orelse return;
        if (self.symbol_picker == null or self.symbol_picker.?.editor != editor) return;
        editor.setSelection(entries[index].symbol.symbol.selection_range) catch |err| {
            editor.setMessage("Navigation failed: {s}", .{@errorName(err)});
            return;
        };
        self.host.reveal_editor(self.host.context);
    }
};

fn itemIndex(id: []const u8, prefix: []const u8) ?usize {
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    return std.fmt.parseInt(usize, id[prefix.len..], 10) catch null;
}
