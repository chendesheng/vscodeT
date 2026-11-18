// Port of the editor-status contribution in
// `src/vs/workbench/browser/parts/editor/editorStatus.ts`.
//
// The browser class listens to editor groups, computes the selection,
// indentation, encoding, EOL and language labels, and registers the commands
// that open the corresponding quick picks. The terminal port keeps the same
// controller shape: It owns the status-bar entries and the picker actions, and
// the TUI supplies a narrow `IEditorStatusTarget` adapter for its active
// editor. DOM listeners, the editor service, notifications and language
// detection are replaced by explicit `update()` calls from the workbench.

const std = @import("std");
const Allocator = std.mem.Allocator;
const StatusbarService = @import("../statusbar/statusbarPart.zig").StatusbarService;
const EntryAccessor = @import("../statusbar/statusbarPart.zig").EntryAccessor;
const quick_input_service = @import("../../../../platform/quickinput/browser/quickInputService.zig");
const QuickInputService = quick_input_service.QuickInputService;
const QuickPickItem = @import("../../../../platform/quickinput/common/quickInput.zig").QuickPickItem;
const QuickPick = @import("../../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const encoding_mod = @import("../../../services/textfile/common/encoding.zig");
const EOL = @import("../../../../editor/common/core/misc/eolCounter.zig").EOL;
pub const LanguageNameIdPair = @import("../../../../editor/common/services/languageService.zig").LanguageNameIdPair;

pub const goto_line_command = "workbench.action.gotoLine";
pub const change_indentation_command = "workbench.action.editor.changeIndentation";
pub const change_encoding_command = "workbench.action.editor.changeEncoding";
pub const change_eol_command = "workbench.action.editor.changeEOL";
pub const change_language_mode_command = "workbench.action.editor.changeLanguageMode";

pub const SelectionStatus = struct {
    line: usize = 1,
    column: usize = 1,
    selections: usize = 0,
    characters: usize = 0,
};

pub const IndentationStatus = struct {
    tab_size: usize = 4,
    indent_size: usize = 4,
    insert_spaces: bool = true,
};

/// The portable editor surface used by the status controller. `src/tui/editor.zig`
/// implements this adapter; the controller never imports the terminal editor.
pub const IEditorStatusTarget = struct {
    context: *anyopaque,
    selection: *const fn (context: *anyopaque) SelectionStatus,
    indentation: *const fn (context: *anyopaque) IndentationStatus,
    eol: *const fn (context: *anyopaque) EOL,
    encoding: *const fn (context: *anyopaque) encoding_mod.Encoding,
    language_id: *const fn (context: *anyopaque) []const u8,
    language_name: *const fn (context: *anyopaque) []const u8,
    languages: *const fn (context: *anyopaque, allocator: Allocator) anyerror![]const LanguageNameIdPair,
    goto_line: *const fn (context: *anyopaque, line: usize, column: usize) anyerror!void,
    change_indentation: *const fn (context: *anyopaque, tab_size: usize, insert_spaces: bool, display_only: bool) void,
    detect_indentation: *const fn (context: *anyopaque) void,
    indentation_to_spaces: *const fn (context: *anyopaque) anyerror!void,
    indentation_to_tabs: *const fn (context: *anyopaque) anyerror!void,
    set_eol: *const fn (context: *anyopaque, eol: EOL) anyerror!void,
    set_encoding: *const fn (context: *anyopaque, encoding: encoding_mod.Encoding) void,
    set_language: *const fn (context: *anyopaque, language_id: []const u8) anyerror!void,
};

pub const Host = struct {
    context: *anyopaque,
    focus: *const fn (context: *anyopaque) void,
};

pub const EditorStatus = struct {
    allocator: Allocator,
    statusbar: *StatusbarService,
    quick_input: *QuickInputService,
    host: Host,
    target: ?IEditorStatusTarget = null,
    selection_accessor: ?EntryAccessor = null,
    indentation_accessor: ?EntryAccessor = null,
    encoding_accessor: ?EntryAccessor = null,
    eol_accessor: ?EntryAccessor = null,
    language_accessor: ?EntryAccessor = null,
    selection_buf: [128]u8 = undefined,
    indentation_buf: [64]u8 = undefined,
    picker_arena: std.heap.ArenaAllocator,
    pending_indent_insert_spaces: bool = true,
    pending_indent_display_only: bool = false,

    pub fn init(
        allocator: Allocator,
        statusbar: *StatusbarService,
        quick_input: *QuickInputService,
        host: Host,
    ) !*EditorStatus {
        const self = try allocator.create(EditorStatus);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .statusbar = statusbar,
            .quick_input = quick_input,
            .host = host,
            .picker_arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.picker_arena.deinit();

        self.selection_accessor = try statusbar.addEntry(.{
            .name = "Editor Selection",
            .text = "",
            .tooltip = "Go to Line/Column",
            .command = .{ .id = goto_line_command },
        }, "status.editor.selection", .right, .{ .number = 100.5 });
        self.indentation_accessor = try statusbar.addEntry(.{
            .name = "Editor Indentation",
            .text = "",
            .tooltip = "Select Indentation",
            .command = .{ .id = change_indentation_command },
        }, "status.editor.indentation", .right, .{ .number = 100.4 });
        self.encoding_accessor = try statusbar.addEntry(.{
            .name = "Editor Encoding",
            .text = "",
            .tooltip = "Select Encoding",
            .command = .{ .id = change_encoding_command },
        }, "status.editor.encoding", .right, .{ .number = 100.3 });
        self.eol_accessor = try statusbar.addEntry(.{
            .name = "Editor End of Line",
            .text = "",
            .tooltip = "Select End of Line Sequence",
            .command = .{ .id = change_eol_command },
        }, "status.editor.eol", .right, .{ .number = 100.2 });
        self.language_accessor = try statusbar.addEntry(.{
            .name = "Editor Language",
            .text = "",
            .tooltip = "Select Language Mode",
            .command = .{ .id = change_language_mode_command },
        }, "status.editor.mode", .right, .{ .number = 100.1 });
        return self;
    }

    pub fn deinit(self: *EditorStatus) void {
        self.picker_arena.deinit();
        self.allocator.destroy(self);
    }

    /// Updates the visible labels from the active editor. A null target hides
    /// the editor-status entries, matching upstream when no code editor is
    /// active.
    pub fn update(self: *EditorStatus, target: ?IEditorStatusTarget) !void {
        self.target = target;
        const value = target orelse {
            setText(self.selection_accessor, "");
            setText(self.indentation_accessor, "");
            setText(self.encoding_accessor, "");
            setText(self.eol_accessor, "");
            setText(self.language_accessor, "");
            return;
        };

        const selection = value.selection(value.context);
        updateEntry(
            self.selection_accessor,
            "Editor Selection",
            "Go to Line/Column",
            goto_line_command,
            self.selectionLabel(selection),
        );

        const indentation = value.indentation(value.context);
        updateEntry(
            self.indentation_accessor,
            "Editor Indentation",
            "Select Indentation",
            change_indentation_command,
            self.indentationLabel(indentation),
        );

        updateEntry(
            self.encoding_accessor,
            "Editor Encoding",
            "Select Encoding",
            change_encoding_command,
            encodingLabel(value.encoding(value.context)),
        );
        updateEntry(
            self.eol_accessor,
            "Editor End of Line",
            "Select End of Line Sequence",
            change_eol_command,
            eolLabel(value.eol(value.context)),
        );
        updateEntry(
            self.language_accessor,
            "Editor Language",
            "Select Language Mode",
            change_language_mode_command,
            value.language_name(value.context),
        );
    }

    fn selectionLabel(self: *EditorStatus, status: SelectionStatus) []const u8 {
        if (status.selections == 0) return "";
        if (status.selections == 1) {
            if (status.characters > 0) {
                return std.fmt.bufPrint(
                    &self.selection_buf,
                    "Ln {d}, Col {d} ({d} selected)",
                    .{ status.line, status.column, status.characters },
                ) catch "";
            }
            return std.fmt.bufPrint(
                &self.selection_buf,
                "Ln {d}, Col {d}",
                .{ status.line, status.column },
            ) catch "";
        }
        if (status.characters > 0) {
            return std.fmt.bufPrint(
                &self.selection_buf,
                "{d} selections ({d} selected)",
                .{ status.selections, status.characters },
            ) catch "";
        }
        return std.fmt.bufPrint(
            &self.selection_buf,
            "{d} selections",
            .{status.selections},
        ) catch "";
    }

    fn indentationLabel(self: *EditorStatus, status: IndentationStatus) []const u8 {
        if (!status.insert_spaces) {
            return std.fmt.bufPrint(
                &self.indentation_buf,
                "Tab Size: {d}",
                .{status.tab_size},
            ) catch "";
        }
        if (status.tab_size == status.indent_size) {
            return std.fmt.bufPrint(
                &self.indentation_buf,
                "Spaces: {d}",
                .{status.indent_size},
            ) catch "";
        }
        return std.fmt.bufPrint(
            &self.indentation_buf,
            "Spaces: {d} (Tab Size: {d})",
            .{ status.indent_size, status.tab_size },
        ) catch "";
    }

    fn updateEntry(
        accessor: ?EntryAccessor,
        name: []const u8,
        tooltip: []const u8,
        command: []const u8,
        text: []const u8,
    ) void {
        if (accessor) |value| {
            value.update(.{
                .name = name,
                .text = text,
                .aria_label = text,
                .tooltip = tooltip,
                .command = .{ .id = command },
            });
        }
    }

    fn setText(accessor: ?EntryAccessor, text: []const u8) void {
        if (accessor) |value| {
            value.update(.{ .name = "", .text = text, .aria_label = text });
        }
    }

    pub fn showGotoLinePicker(self: *EditorStatus) !void {
        try self.quick_input.showPick(
            &.{},
            .{ .placeholder = "Go to Line/Column", .allow_free_input = true },
            onGotoLineAccepted,
            self,
        );
    }

    pub fn showIndentationPicker(self: *EditorStatus) !void {
        const items = [_]QuickPickItem{
            .{ .item = .{ .id = "spaces", .label = "Indent Using Spaces" } },
            .{ .item = .{ .id = "tabs", .label = "Indent Using Tabs" } },
            .{ .item = .{ .id = "tab_size", .label = "Change Tab Display Size" } },
            .{ .item = .{ .id = "detect", .label = "Detect Indentation" } },
            .{ .item = .{ .id = "to_spaces", .label = "Convert Indentation to Spaces" } },
            .{ .item = .{ .id = "to_tabs", .label = "Convert Indentation to Tabs" } },
        };
        try self.quick_input.showPick(
            &items,
            .{ .placeholder = "Select Action" },
            onIndentationAction,
            self,
        );
    }

    fn showTabSizePicker(self: *EditorStatus) !void {
        const items = [_]QuickPickItem{
            .{ .item = .{ .id = "1", .label = "1" } },
            .{ .item = .{ .id = "2", .label = "2" } },
            .{ .item = .{ .id = "3", .label = "3" } },
            .{ .item = .{ .id = "4", .label = "4" } },
            .{ .item = .{ .id = "5", .label = "5" } },
            .{ .item = .{ .id = "6", .label = "6" } },
            .{ .item = .{ .id = "7", .label = "7" } },
            .{ .item = .{ .id = "8", .label = "8" } },
        };
        try self.quick_input.showPick(
            &items,
            .{ .placeholder = "Select Tab Size" },
            onTabSizeAccepted,
            self,
        );
    }

    pub fn showEOLPicker(self: *EditorStatus) !void {
        const current = if (self.target) |target| target.eol(target.context) else .LF;
        const items = [_]QuickPickItem{
            .{ .item = .{ .id = "lf", .label = "LF" } },
            .{ .item = .{ .id = "crlf", .label = "CRLF" } },
        };
        try self.quick_input.showPick(
            &items,
            .{
                .placeholder = "Select End of Line Sequence",
                .active_id = if (current == .CRLF) "crlf" else "lf",
            },
            onEOLAccepted,
            self,
        );
    }

    pub fn showLanguagePicker(self: *EditorStatus) !void {
        const target = self.target orelse return;
        _ = self.picker_arena.reset(.retain_capacity);
        const arena = self.picker_arena.allocator();
        const languages = try target.languages(target.context, arena);
        var items = std.array_list.Managed(QuickPickItem).init(arena);
        for (languages) |entry| {
            try items.append(.{ .item = .{
                .id = entry.languageId,
                .label = entry.languageName,
                .description = try std.fmt.allocPrint(arena, "({s})", .{entry.languageId}),
            } });
        }
        try self.quick_input.showPick(
            items.items,
            .{
                .placeholder = "Select Language Mode",
                .active_id = target.language_id(target.context),
                .no_results_label = "No matching languages",
            },
            onLanguageAccepted,
            self,
        );
    }

    pub fn showEncodingPicker(self: *EditorStatus) !void {
        const current = if (self.target) |target| target.encoding(target.context) else .utf8;
        const items = [_]QuickPickItem{
            // Only encodings that round-trip through BOM detection are offered;
            // the terminal encoding port has no heuristic charset detection.
            .{ .item = .{ .id = "utf8", .label = "UTF-8" } },
            .{ .item = .{ .id = "utf8_with_bom", .label = "UTF-8 with BOM" } },
            .{ .item = .{ .id = "utf16le_with_bom", .label = "UTF-16 LE with BOM" } },
            .{ .item = .{ .id = "utf16be_with_bom", .label = "UTF-16 BE with BOM" } },
        };
        try self.quick_input.showPick(
            &items,
            .{
                .placeholder = "Select Encoding",
                .active_id = @tagName(current),
            },
            onEncodingAccepted,
            self,
        );
    }

    fn refreshed(self: *EditorStatus) void {
        self.update(self.target) catch {};
        self.host.focus(self.host.context);
    }
};

pub fn commandGotoLine(context: *anyopaque) anyerror!void {
    const self: *EditorStatus = @ptrCast(@alignCast(context));
    try self.showGotoLinePicker();
}

pub fn commandChangeIndentation(context: *anyopaque) anyerror!void {
    const self: *EditorStatus = @ptrCast(@alignCast(context));
    try self.showIndentationPicker();
}

pub fn commandChangeEncoding(context: *anyopaque) anyerror!void {
    const self: *EditorStatus = @ptrCast(@alignCast(context));
    try self.showEncodingPicker();
}

pub fn commandChangeEOL(context: *anyopaque) anyerror!void {
    const self: *EditorStatus = @ptrCast(@alignCast(context));
    try self.showEOLPicker();
}

pub fn commandChangeLanguageMode(context: *anyopaque) anyerror!void {
    const self: *EditorStatus = @ptrCast(@alignCast(context));
    try self.showLanguagePicker();
}

fn onGotoLineAccepted(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *EditorStatus = @ptrCast(@alignCast(context));
    const target = self.target orelse return;
    const value = std.mem.trim(u8, picker.value.items, " \t");
    if (value.len == 0) return;

    var line_text = value;
    var column_text: ?[]const u8 = null;
    if (std.mem.indexOfAny(u8, value, ":,")) |separator| {
        line_text = value[0..separator];
        column_text = value[separator + 1 ..];
    }
    const requested_line = std.fmt.parseInt(
        usize,
        std.mem.trim(u8, line_text, " \t"),
        10,
    ) catch return;
    var column: usize = 1;
    if (column_text) |text| {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len > 0) {
            const requested_column = std.fmt.parseInt(usize, trimmed, 10) catch return;
            column = @max(requested_column, 1);
        }
    }
    try target.goto_line(target.context, requested_line, column);
    self.refreshed();
}

fn onIndentationAction(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *EditorStatus = @ptrCast(@alignCast(context));
    const target = self.target orelse return;
    const item = picker.selectedItem() orelse return;
    const options = target.indentation(target.context);

    if (std.mem.eql(u8, item.id, "spaces")) {
        self.pending_indent_insert_spaces = true;
        self.pending_indent_display_only = false;
        try self.showTabSizePicker();
        return;
    }
    if (std.mem.eql(u8, item.id, "tabs")) {
        target.change_indentation(target.context, options.tab_size, false, false);
    } else if (std.mem.eql(u8, item.id, "tab_size")) {
        self.pending_indent_insert_spaces = options.insert_spaces;
        self.pending_indent_display_only = true;
        try self.showTabSizePicker();
        return;
    } else if (std.mem.eql(u8, item.id, "detect")) {
        target.detect_indentation(target.context);
    } else if (std.mem.eql(u8, item.id, "to_spaces")) {
        try target.indentation_to_spaces(target.context);
    } else if (std.mem.eql(u8, item.id, "to_tabs")) {
        try target.indentation_to_tabs(target.context);
    } else {
        return;
    }
    self.refreshed();
}

fn onTabSizeAccepted(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *EditorStatus = @ptrCast(@alignCast(context));
    const target = self.target orelse return;
    const item = picker.selectedItem() orelse return;
    const size = std.fmt.parseInt(usize, item.id, 10) catch return;
    target.change_indentation(
        target.context,
        size,
        self.pending_indent_insert_spaces,
        self.pending_indent_display_only,
    );
    self.refreshed();
}

fn onEOLAccepted(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *EditorStatus = @ptrCast(@alignCast(context));
    const target = self.target orelse return;
    const item = picker.selectedItem() orelse return;
    const eol: EOL = if (std.mem.eql(u8, item.id, "crlf")) .CRLF else .LF;
    try target.set_eol(target.context, eol);
    self.refreshed();
}

fn onLanguageAccepted(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *EditorStatus = @ptrCast(@alignCast(context));
    const target = self.target orelse return;
    const item = picker.selectedItem() orelse return;
    try target.set_language(target.context, item.id);
    self.refreshed();
}

fn onEncodingAccepted(context: *anyopaque, picker: *QuickPick) anyerror!void {
    const self: *EditorStatus = @ptrCast(@alignCast(context));
    const target = self.target orelse return;
    const item = picker.selectedItem() orelse return;
    const encoding = std.meta.stringToEnum(encoding_mod.Encoding, item.id) orelse return;
    target.set_encoding(target.context, encoding);
    self.refreshed();
}

fn eolLabel(eol: EOL) []const u8 {
    return if (eol == .CRLF) "CRLF" else "LF";
}

fn encodingLabel(encoding: encoding_mod.Encoding) []const u8 {
    return switch (encoding) {
        .utf8 => "UTF-8",
        .utf8_with_bom => "UTF-8 with BOM",
        .utf16le => "UTF-16 LE",
        .utf16be => "UTF-16 BE",
        .utf16le_with_bom => "UTF-16 LE with BOM",
        .utf16be_with_bom => "UTF-16 BE with BOM",
    };
}
