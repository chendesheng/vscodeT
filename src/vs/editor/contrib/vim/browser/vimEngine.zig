// Native Vim editing engine.
//
// Deliberate Zig addition, not a VS Code upstream port. The engine receives the
// built-in extension interfaces and owns Vim's command state only: pending
// count/operator, registers, search pattern and mode. Cursor/selection, undo
// and column state stay in the editor (`ITextEditor`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const bracket_text_objects = @import("../../../common/model/bracketPairsTextModelPart/bracketTextObjects.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const extension_api = @import("../../../../workbench/api/common/extensionApi.zig");
const ui = @import("ui");

const ITextEditor = extension_api.ITextEditor;
const IWindowService = extension_api.IWindowService;
const ICommandService = extension_api.ICommandService;
const KeyInputEvent = extension_api.KeyInputEvent;

/// Matches highlighted while a search is active or previewed. Mirrors the find
/// contribution's result cap so a pathological pattern cannot build an
/// unbounded decoration list.
const SEARCH_HIGHLIGHT_LIMIT: usize = 999;

pub const Mode = enum {
    normal,
    insert,
    replace,
    visual,
    visual_line,
    visual_block,
    operator_pending,
    command_line,
    search_forward,
    search_backward,
};

const Operator = enum { none, delete, change, yank, indent, outdent };

const Find = struct { char: u21, forward: bool, till: bool };
const LastVisual = struct { range: Range, linewise: bool };
const BlockSelection = struct { anchor: Position, cursor: Position };
const RecordedKey = struct { key: ui.Key, mods: ui.Modifiers };
const LineUndo = struct { line: usize, text: []u8 };

const Register = struct {
    text: []u8,
    linewise: bool,
};

pub const Registers = struct {
    allocator: Allocator,
    unnamed: ?Register = null,
    named: std.AutoHashMap(u8, Register),

    pub fn init(allocator: Allocator) Registers {
        return .{ .allocator = allocator, .named = std.AutoHashMap(u8, Register).init(allocator) };
    }

    pub fn deinit(self: *Registers) void {
        if (self.unnamed) |*register| self.allocator.free(register.text);
        var iterator = self.named.valueIterator();
        while (iterator.next()) |register| self.allocator.free(register.text);
        self.named.deinit();
    }

    fn setUnnamed(self: *Registers, text: []const u8, linewise: bool) !void {
        if (self.unnamed) |*old| self.allocator.free(old.text);
        self.unnamed = .{ .text = try self.allocator.dupe(u8, text), .linewise = linewise };
    }

    fn set(self: *Registers, name: u8, text: []const u8, linewise: bool) !void {
        if (name == 0 or name == '"') return self.setUnnamed(text, linewise);
        const entry = try self.named.getOrPut(name);
        if (entry.found_existing) self.allocator.free(entry.value_ptr.text);
        entry.value_ptr.* = .{ .text = try self.allocator.dupe(u8, text), .linewise = linewise };
    }

    fn get(self: *Registers, name: u8) ?Register {
        if (name == 0 or name == '"') return self.unnamed;
        return self.named.get(name);
    }
};

pub const VimEngine = struct {
    allocator: Allocator,
    editor: ITextEditor,
    window: IWindowService,
    commands: ICommandService,
    mode: Mode = .normal,
    count: usize = 0,
    count_active: bool = false,
    operator: Operator = .none,
    operator_count: usize = 1,
    pending_register: ?u8 = null,
    pending_text_object: ?bool = null,
    pending_visual_text_object: ?bool = null,
    pending_g: bool = false,
    pending_z: bool = false,
    pending_window: bool = false,
    pending_find: ?Find = null,
    pending_replace: bool = false,
    last_find: ?Find = null,
    insert_group: bool = false,
    insert_register: bool = false,
    command_buffer: ArrayList(u8),
    search_buffer: ArrayList(u8),
    last_search: ArrayList(u8),
    search_forward: bool = true,
    search_is_regex: bool = true,
    last_search_match: ?Range = null,
    /// Vim's `no_hlsearch`: `:noh` clears the painted highlight but keeps the
    /// pattern. A committed `/`/`?`, `*`/`#` or `n`/`N` resets the flag and
    /// paints the matches again.
    hlsearch_disabled: bool = false,
    /// Cursor position when the `/` or `?` prompt opened. Incremental previews
    /// always search from here, and Escape restores it.
    search_origin: ?Position = null,
    /// Count typed before `/` or `?` (`3/foo`), applied when the search is
    /// committed.
    search_count: usize = 1,
    last_visual: ?LastVisual = null,
    last_insert_position: ?Position = null,
    line_undo: ?LineUndo = null,
    visual_block: ?BlockSelection = null,
    block_insert: bool = false,
    marks: [26]?Position = std.mem.zeroes([26]?Position),
    pending_mark_set: bool = false,
    pending_mark_jump_exact: ?bool = null,
    pending_keys: ArrayList(RecordedKey),
    last_change: ArrayList(RecordedKey),
    replaying: bool = false,
    did_change: bool = false,
    registers: *Registers,
    owns_registers: bool = false,
    status_buf: [192]u8 = undefined,
    ignore_case: bool = false,
    history: ?extension_api.IHistoryService = null,
    macros: [26]?ArrayList(RecordedKey) = std.mem.zeroes([26]?ArrayList(RecordedKey)),
    macro_register: ?usize = null,
    pending_macro_record: bool = false,
    pending_macro_play: bool = false,
    last_macro: ?usize = null,
    macro_depth: usize = 0,

    pub fn init(
        allocator: Allocator,
        editor: ITextEditor,
        window: IWindowService,
        commands: ICommandService,
        shared_registers: ?*Registers,
    ) !*VimEngine {
        const self = try allocator.create(VimEngine);
        errdefer allocator.destroy(self);
        const registers = if (shared_registers) |shared| shared else blk: {
            const owned = try allocator.create(Registers);
            owned.* = Registers.init(allocator);
            break :blk owned;
        };
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .window = window,
            .commands = commands,
            .command_buffer = ArrayList(u8).init(allocator),
            .search_buffer = ArrayList(u8).init(allocator),
            .last_search = ArrayList(u8).init(allocator),
            .pending_keys = ArrayList(RecordedKey).init(allocator),
            .last_change = ArrayList(RecordedKey).init(allocator),
            .registers = registers,
            .owns_registers = shared_registers == null,
        };
        return self;
    }

    pub fn deinit(self: *VimEngine) void {
        // The owner closes any open editor undo group before destroying the
        // editor; deinit must not touch an editor that may already be gone.
        self.command_buffer.deinit();
        self.search_buffer.deinit();
        self.last_search.deinit();
        for (&self.macros) |*macro| {
            if (macro.*) |*list| {
                self.clearRecorded(list);
                list.deinit();
                macro.* = null;
            }
        }
        self.clearRecorded(&self.pending_keys);
        self.clearRecorded(&self.last_change);
        self.pending_keys.deinit();
        self.last_change.deinit();
        if (self.line_undo) |*undo| self.allocator.free(undo.text);
        if (self.owns_registers) {
            self.registers.deinit();
            self.allocator.destroy(self.registers);
        }
        self.allocator.destroy(self);
    }

    pub fn statusText(self: *VimEngine) []const u8 {
        return switch (self.mode) {
            .insert => "-- INSERT --",
            .replace => "-- REPLACE --",
            .visual => "-- VISUAL --",
            .visual_line => "-- VISUAL LINE --",
            .visual_block => "-- VISUAL BLOCK --",
            .command_line => std.fmt.bufPrint(&self.status_buf, ":{s}", .{self.command_buffer.items}) catch ":",
            .search_forward => std.fmt.bufPrint(&self.status_buf, "/{s}", .{self.search_buffer.items}) catch "/",
            .search_backward => std.fmt.bufPrint(&self.status_buf, "?{s}", .{self.search_buffer.items}) catch "?",
            .operator_pending => self.pendingStatus(),
            .normal => self.pendingStatus(),
        };
    }

    fn pendingStatus(self: *VimEngine) []const u8 {
        if (self.count_active or self.pending_g or self.pending_z or self.pending_window or self.pending_find != null) {
            return std.fmt.bufPrint(
                &self.status_buf,
                "{s}{s}{s}{s}{s}",
                .{
                    if (self.count_active) "count " else "",
                    if (self.operator == .delete) "d" else if (self.operator == .change) "c" else if (self.operator == .yank) "y" else "",
                    if (self.pending_g) "g" else "",
                    if (self.pending_z) "z" else "",
                    if (self.pending_window) "<C-w>" else "",
                },
            ) catch "";
        }
        return "";
    }

    pub fn setHistoryService(self: *VimEngine, history: extension_api.IHistoryService) void {
        self.history = history;
    }

    fn recordJump(self: *VimEngine) void {
        if (self.history) |history| history.recordNavigation();
    }

    pub fn handleKey(self: *VimEngine, event: *const KeyInputEvent) !bool {
        if (!self.replaying) {
            if (self.macro_register != null and !isMacroStopKey(event, self.mode)) {
                try self.recordMacroKey(event);
            }
            if (isDotCommand(event) and self.mode == .normal and self.operator == .none and
                self.pending_find == null and self.pending_register == null and !self.pending_g and
                !self.pending_z and !self.pending_window and !self.count_active)
            {
                return self.repeatLastChange();
            }
            try self.recordKey(event);
        }
        const consumed = try self.dispatchKey(event);
        if (!self.replaying) try self.finishRecording();
        return consumed;
    }

    fn dispatchKey(self: *VimEngine, event: *const KeyInputEvent) !bool {
        switch (self.mode) {
            .insert, .replace => return self.handleInsert(event),
            .command_line => return self.handleCommandLine(event),
            .search_forward, .search_backward => return self.handleSearchInput(event),
            else => return self.handleNormal(event),
        }
    }

    fn isMacroStopKey(event: *const KeyInputEvent, mode: Mode) bool {
        if (mode != .normal) return false;
        return switch (event.key) {
            .char => |char| char == 'q',
            .text => |text| text.len == 1 and text[0] == 'q',
            else => false,
        };
    }

    fn recordMacroKey(self: *VimEngine, event: *const KeyInputEvent) !void {
        const index = self.macro_register orelse return;
        if (self.macros[index] == null) self.macros[index] = ArrayList(RecordedKey).init(self.allocator);
        try self.recordKeyInto(&self.macros[index].?, event);
    }

    fn recordKeyInto(self: *VimEngine, list: *ArrayList(RecordedKey), event: *const KeyInputEvent) !void {
        var recorded = RecordedKey{ .key = event.key, .mods = event.mods };
        if (event.key == .text) {
            const copy = try self.allocator.dupe(u8, event.key.text);
            errdefer self.allocator.free(copy);
            recorded.key = .{ .text = copy };
        }
        try list.append(recorded);
    }

    fn startMacro(self: *VimEngine, index: usize) void {
        if (self.macros[index]) |*list| {
            self.clearRecorded(list);
        } else {
            self.macros[index] = ArrayList(RecordedKey).init(self.allocator);
        }
        self.macro_register = index;
        self.last_macro = index;
        self.pending_macro_record = false;
    }

    fn replayMacro(self: *VimEngine, index: usize, count: usize) !void {
        if (self.macro_depth >= 100) return;
        const list = self.macros[index] orelse return;
        self.macro_depth += 1;
        defer self.macro_depth -= 1;
        var remaining = @max(count, 1);
        while (remaining > 0) : (remaining -= 1) {
            for (list.items) |recorded| {
                var event = KeyInputEvent{ .key = recorded.key, .mods = recorded.mods };
                _ = try self.dispatchKey(&event);
            }
        }
        self.last_macro = index;
    }

    fn isDotCommand(event: *const KeyInputEvent) bool {
        return switch (event.key) {
            .char => |char| char == '.',
            .text => |text| text.len == 1 and text[0] == '.',
            else => false,
        };
    }

    fn recordKey(self: *VimEngine, event: *const KeyInputEvent) !void {
        var recorded = RecordedKey{ .key = event.key, .mods = event.mods };
        if (event.key == .text) {
            const copy = try self.allocator.dupe(u8, event.key.text);
            errdefer self.allocator.free(copy);
            recorded.key = .{ .text = copy };
        }
        try self.pending_keys.append(recorded);
    }

    fn clearRecorded(self: *VimEngine, keys: *ArrayList(RecordedKey)) void {
        for (keys.items) |recorded| {
            if (recorded.key == .text) self.allocator.free(recorded.key.text);
        }
        keys.clearRetainingCapacity();
    }

    fn finishRecording(self: *VimEngine) !void {
        if (self.did_change and self.mode == .normal and self.operator == .none and
            self.pending_find == null and self.pending_replace == false and
            self.pending_register == null and !self.pending_g and !self.pending_z and
            !self.pending_window and self.visual_block == null and !self.count_active and
            !self.pending_macro_record and !self.pending_macro_play)
        {
            self.clearRecorded(&self.last_change);
            const old_pending = self.pending_keys;
            self.pending_keys = self.last_change;
            self.last_change = old_pending;
            self.did_change = false;
            return;
        }
        if (self.mode == .normal and !self.did_change and self.operator == .none and
            self.pending_find == null and self.pending_replace == false and
            self.pending_register == null and !self.pending_g and !self.pending_z and
            !self.pending_window and self.visual_block == null and !self.count_active and
            !self.pending_macro_record and !self.pending_macro_play)
        {
            self.clearRecorded(&self.pending_keys);
        }
    }

    fn repeatLastChange(self: *VimEngine) !bool {
        if (self.last_change.items.len == 0) return true;
        self.replaying = true;
        defer self.replaying = false;
        self.did_change = false;
        self.clearRecorded(&self.pending_keys);
        for (self.last_change.items) |recorded| {
            var event = KeyInputEvent{ .key = recorded.key, .mods = recorded.mods };
            _ = try self.dispatchKey(&event);
        }
        self.did_change = false;
        return true;
    }

    fn handleNormal(self: *VimEngine, event: *const KeyInputEvent) !bool {
        if (self.mode == .visual_block) return self.handleVisualBlockKey(event);
        switch (event.key) {
            .text => |text| {
                // The terminal decoder emits printable runs as `.text` (not
                // one `.char` per key). Normal mode must interpret each
                // codepoint as a Vim key; bracketed paste bypasses Vim in the
                // app so it still inserts text.
                var view = std.unicode.Utf8View.init(text) catch return false;
                var iterator = view.iterator();
                var consumed = false;
                while (iterator.i < text.len) {
                    if (self.mode == .insert or self.mode == .replace) {
                        var remaining = event.*;
                        remaining.key = .{ .text = text[iterator.i..] };
                        return (try self.handleInsert(&remaining)) or consumed;
                    }
                    consumed = (try self.handleChar(iterator.nextCodepoint().?)) or consumed;
                }
                return consumed;
            },
            .char => |char| {
                if (event.mods.ctrl) return self.handleCtrl(char);
                if (event.mods.alt) return false;
                return self.handleChar(char);
            },
            .escape => {
                self.resetPending();
                if (self.mode == .visual or self.mode == .visual_line) {
                    try self.rememberVisual();
                    const position = self.editor.cursorPosition();
                    try self.editor.setSelections(&[_]Selection{Selection.init(position.lineNumber, position.column, position.lineNumber, position.column)});
                }
                self.mode = .normal;
                return true;
            },
            .enter => {
                self.resetPending();
                const position = self.editor.cursorPosition();
                if (position.lineNumber < self.editor.model.getLineCount()) {
                    try self.editor.setCursor(self.firstNonBlank(position.lineNumber + 1));
                }
                return true;
            },
            .backspace => {
                try self.moveLeft(1, false);
                return true;
            },
            .delete => return self.deleteChars(1, false),
            .left => {
                try self.moveLeft(self.takeCount(), self.mode == .visual or self.mode == .visual_line);
                return true;
            },
            .right => {
                try self.moveRight(self.takeCount(), self.mode == .visual or self.mode == .visual_line);
                return true;
            },
            .up => {
                try self.moveLogicalLine(false, self.mode == .visual or self.mode == .visual_line, self.takeCount());
                if (self.mode == .normal) try self.clampNormal();
                return true;
            },
            .down => {
                try self.moveLogicalLine(true, self.mode == .visual or self.mode == .visual_line, self.takeCount());
                if (self.mode == .normal) try self.clampNormal();
                return true;
            },
            .home => {
                try self.editor.setCursor(Position.init(self.editor.cursorPosition().lineNumber, 1));
                return true;
            },
            .end => {
                try self.editor.setCursor(self.lineEndPosition(self.editor.cursorPosition().lineNumber, true));
                return true;
            },
            .page_up => {
                _ = self.editor.scrollViewLines(-@as(isize, @intCast(self.editor.textHeight())));
                return true;
            },
            .page_down => {
                _ = self.editor.scrollViewLines(@intCast(self.editor.textHeight()));
                return true;
            },
            .insert => return false,
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => return false,
            .tab => return false,
            .backtab => return false,
            .paste_start, .paste_end => return false,
        }
    }

    fn handleChar(self: *VimEngine, char: u21) !bool {
        if (self.mode == .visual or self.mode == .visual_line) {
            if (self.pending_visual_text_object) |around| {
                self.pending_visual_text_object = null;
                if (try self.textObjectRange(around, char)) |range| {
                    const start = range.startPosition();
                    const end = range.endPosition();
                    try self.editor.setSelections(&[_]Selection{Selection.init(start.lineNumber, start.column, end.lineNumber, end.column)});
                }
                return true;
            }
            switch (char) {
                'd' => return self.applyVisualOperator(.delete),
                'c' => return self.applyVisualOperator(.change),
                'y' => return self.applyVisualOperator(.yank),
                '>' => return self.applyVisualOperator(.indent),
                '<' => return self.applyVisualOperator(.outdent),
                'i' => {
                    self.pending_visual_text_object = false;
                    return true;
                },
                'a' => {
                    self.pending_visual_text_object = true;
                    return true;
                },
                'o' => {
                    const selections = try self.editor.getSelections(self.allocator);
                    defer self.allocator.free(selections);
                    if (selections.len > 0) {
                        const anchor = selections[0].getSelectionStart();
                        const position = selections[0].getPosition();
                        try self.editor.setSelections(&[_]Selection{Selection.init(position.lineNumber, position.column, anchor.lineNumber, anchor.column)});
                    }
                    return true;
                },
                '%' => {
                    if (try self.matchBracketTarget()) |target| try self.extendSelection(target);
                    return true;
                },
                '0' => {
                    try self.extendSelection(Position.init(self.editor.cursorPosition().lineNumber, 1));
                    return true;
                },
                '^' => {
                    try self.extendSelection(self.firstNonBlank(self.editor.cursorPosition().lineNumber));
                    return true;
                },
                '$' => {
                    try self.extendSelection(self.lineEndPosition(self.editor.cursorPosition().lineNumber, true));
                    return true;
                },
                'G' => {
                    const line = if (self.count_active) self.takeCount() else self.editor.model.getLineCount();
                    const target = if (self.mode == .visual_line) Position.init(line, 1) else Position.init(line, self.lineMaxColumn(line));
                    try self.extendSelection(target);
                    return true;
                },
                else => {},
            }
        }
        if (self.pending_macro_record) {
            self.pending_macro_record = false;
            if (char >= 'a' and char <= 'z') self.startMacro(char - 'a');
            return true;
        }
        if (self.pending_macro_play) {
            self.pending_macro_play = false;
            const count = self.takeCount();
            if (char == '@') {
                if (self.last_macro) |index| try self.replayMacro(index, count);
            } else if (char >= 'a' and char <= 'z') {
                try self.replayMacro(char - 'a', count);
            }
            return true;
        }
        if (self.pending_register != null) {
            self.pending_register = @intCast(char);
            return true;
        }
        if (self.pending_replace) {
            self.pending_replace = false;
            try self.replaceChars(char, self.takeCount());
            return true;
        }
        if (self.pending_find) |find| {
            self.pending_find = null;
            self.last_find = .{ .char = char, .forward = find.forward, .till = find.till };
            const motion_count = self.takeCount();
            if (self.operator != .none) {
                const operator = self.operator;
                const count = self.operator_count * motion_count;
                self.operator = .none;
                self.operator_count = 1;
                self.mode = .normal;
                const found = try self.findCharPosition(char, find.forward, find.till, count) orelse return true;
                const cursor = self.editor.cursorPosition();
                const range = if (find.forward)
                    Range.fromPositions(cursor, try self.afterPosition(found))
                else if (find.till)
                    Range.fromPositions(try self.afterPosition(found), try self.afterPosition(cursor))
                else
                    Range.fromPositions(found, try self.afterPosition(cursor));
                try self.applyOperator(operator, range, false);
                return true;
            }
            try self.findChar(char, find.forward, find.till, motion_count);
            return true;
        }
        if (self.pending_text_object) |around| {
            self.pending_text_object = null;
            try self.applyTextObject(around, char);
            return true;
        }
        if (self.pending_g) {
            self.pending_g = false;
            if (char == 'g') {
                self.recordJump();
                const line = self.takeCount();
                if (self.mode == .visual or self.mode == .visual_line) {
                    try self.extendSelection(Position.init(line, 1));
                } else {
                    try self.gotoLine(line);
                }
            } else if (char == 'f') {
                self.recordJump();
                try self.gotoFileUnderCursor();
            } else if (char == 'd') {
                self.recordJump();
                _ = try self.commands.execute("editor.action.revealDefinition");
            } else if (char == 'h') {
                _ = try self.commands.execute("editor.action.showHover");
            } else if (char == 'O') {
                _ = try self.commands.execute("outline.focus");
            } else if (char == 't') {
                try self.window.switchTab(1);
            } else if (char == 'T') {
                try self.window.switchTab(-1);
            } else if (char == 'v') {
                try self.reselectVisual();
            } else if (char == 'i') {
                try self.gotoLastInsert();
            } else if (char == 'j') {
                try self.editor.moveWrappedLine(true, self.mode == .visual or self.mode == .visual_line, self.takeCount());
                if (self.mode == .normal) try self.clampNormal();
            } else if (char == 'k') {
                try self.editor.moveWrappedLine(false, self.mode == .visual or self.mode == .visual_line, self.takeCount());
                if (self.mode == .normal) try self.clampNormal();
            } else if (char == '_') {
                const line = self.editor.cursorPosition().lineNumber;
                try self.editor.setCursor(self.lastNonBlank(line));
            } else if (char == '0' or char == '^') {
                try self.editor.setCursor(self.firstNonBlank(self.editor.cursorPosition().lineNumber));
            } else if (char == '$') {
                try self.editor.setCursor(self.lineEndPosition(self.editor.cursorPosition().lineNumber, true));
            } else if (char == 'J') {
                try self.joinLines(self.takeCount(), "");
            }
            return true;
        }
        if (self.pending_z) {
            self.pending_z = false;
            return self.handleZ(char);
        }
        if (self.pending_window) {
            self.pending_window = false;
            return self.handleWindowCommand(char);
        }
        if (self.pending_mark_set or self.pending_mark_jump_exact != null) {
            if (char < 'a' or char > 'z') {
                self.pending_mark_set = false;
                self.pending_mark_jump_exact = null;
                return true;
            }
            const index: usize = char - 'a';
            if (self.pending_mark_set) {
                self.pending_mark_set = false;
                self.marks[index] = self.editor.cursorPosition();
                return true;
            }
            const exact = self.pending_mark_jump_exact.?;
            self.pending_mark_jump_exact = null;
            const mark = self.marks[index] orelse return true;
            self.recordJump();
            try self.editor.setCursor(if (exact) mark else self.firstNonBlank(mark.lineNumber));
            return true;
        }
        if (self.operator != .none) {
            return self.handleOperatorKey(char);
        }

        if (char >= '1' and char <= '9') {
            self.count = self.count * 10 + (char - '0');
            self.count_active = true;
            return true;
        }
        if (char == '0' and self.count_active) {
            self.count = self.count * 10;
            return true;
        }

        switch (char) {
            '0' => try self.editor.setCursor(Position.init(self.editor.cursorPosition().lineNumber, 1)),
            '^' => try self.editor.setCursor(self.firstNonBlank(self.editor.cursorPosition().lineNumber)),
            '$' => try self.editor.setCursor(self.lineEndPosition(self.editor.cursorPosition().lineNumber, true)),
            'h' => try self.moveLeftOnLine(self.takeCount(), self.mode == .visual or self.mode == .visual_line),
            'l' => try self.moveRightOnLine(self.takeCount(), self.mode == .visual or self.mode == .visual_line),
            'j' => {
                try self.moveLogicalLine(true, self.mode == .visual or self.mode == .visual_line, self.takeCount());
                if (self.mode == .normal) try self.clampNormal();
            },
            'k' => {
                try self.moveLogicalLine(false, self.mode == .visual or self.mode == .visual_line, self.takeCount());
                if (self.mode == .normal) try self.clampNormal();
            },
            'w', 'W' => try self.moveWord(char, self.takeCount(), self.mode == .visual or self.mode == .visual_line),
            'b', 'B' => try self.moveWordBack(char, self.takeCount(), self.mode == .visual or self.mode == .visual_line),
            'e', 'E' => try self.moveWordEnd(char, self.takeCount(), self.mode == .visual or self.mode == .visual_line),
            'f' => self.pending_find = .{ .char = 0, .forward = true, .till = false },
            'F' => self.pending_find = .{ .char = 0, .forward = false, .till = false },
            't' => self.pending_find = .{ .char = 0, .forward = true, .till = true },
            'T' => self.pending_find = .{ .char = 0, .forward = false, .till = true },
            ';' => {
                if (self.last_find) |find| try self.findChar(find.char, find.forward, find.till, self.takeCount());
            },
            ',' => {
                if (self.last_find) |find| try self.findChar(find.char, !find.forward, find.till, self.takeCount());
            },
            'g' => self.pending_g = true,
            'z' => self.pending_z = true,
            'G' => {
                self.recordJump();
                const line = if (self.count_active) self.takeCount() else self.editor.model.getLineCount();
                try self.gotoLine(line);
            },
            '%' => {
                self.recordJump();
                try self.matchBracketMotion();
            },
            '{' => {
                self.recordJump();
                try self.moveParagraph(false, self.takeCount(), self.mode == .visual or self.mode == .visual_line);
            },
            '}' => {
                self.recordJump();
                try self.moveParagraph(true, self.takeCount(), self.mode == .visual or self.mode == .visual_line);
            },
            '+' => try self.gotoLine(@min(self.editor.cursorPosition().lineNumber + self.takeCount(), self.editor.model.getLineCount())),
            '-' => try self.gotoLine(self.editor.cursorPosition().lineNumber -| self.takeCount()),
            '_' => try self.editor.setCursor(self.firstNonBlank(@min(self.editor.cursorPosition().lineNumber + self.takeCount() - 1, self.editor.model.getLineCount()))),
            'm' => self.pending_mark_set = true,
            '\'' => self.pending_mark_jump_exact = false,
            '`' => self.pending_mark_jump_exact = true,
            '(' => {
                self.recordJump();
                try self.moveSentence(false, self.takeCount(), self.mode == .visual or self.mode == .visual_line);
            },
            ')' => {
                self.recordJump();
                try self.moveSentence(true, self.takeCount(), self.mode == .visual or self.mode == .visual_line);
            },
            'H' => {
                self.recordJump();
                try self.moveToScreenLine(.top);
            },
            'M' => {
                self.recordJump();
                try self.moveToScreenLine(.middle);
            },
            'L' => {
                self.recordJump();
                try self.moveToScreenLine(.bottom);
            },
            '*' => {
                self.recordJump();
                try self.searchWord(true);
            },
            '#' => {
                self.recordJump();
                try self.searchWord(false);
            },
            'd' => try self.startOperator(.delete),
            'c' => try self.startOperator(.change),
            'y' => try self.startOperator(.yank),
            '>' => try self.startOperator(.indent),
            '<' => try self.startOperator(.outdent),
            'U' => try self.undoLine(),
            'x' => _ = try self.deleteChars(self.takeCount(), false),
            'X' => _ = try self.deleteChars(self.takeCount(), true),
            's' => try self.changeChars(self.takeCount()),
            'S' => try self.changeLines(self.editor.cursorPosition().lineNumber, 1),
            'D' => try self.deleteToLineEnd(),
            'C' => try self.changeToLineEnd(),
            'Y' => try self.yankLines(self.editor.cursorPosition().lineNumber, self.takeCount()),
            'p' => try self.put(false, self.takeCount()),
            'P' => try self.put(true, self.takeCount()),
            'i' => try self.enterInsert(false),
            'I' => {
                try self.editor.setCursor(self.firstNonBlank(self.editor.cursorPosition().lineNumber));
                try self.enterInsert(false);
            },
            'a' => try self.enterAppend(),
            'A' => {
                const line = self.editor.cursorPosition().lineNumber;
                try self.editor.setCursor(self.lineEndPosition(line, false));
                try self.enterInsert(false);
            },
            'o' => try self.openLine(false),
            'O' => try self.openLine(true),
            'u' => try self.editor.undo(),
            'r' => self.pending_replace = true,
            '~' => try self.toggleCase(self.takeCount()),
            'J' => try self.joinLines(self.takeCount(), " "),
            'v' => try self.startVisual(false),
            'V' => try self.startVisual(true),
            'R' => try self.startReplaceMode(),
            'q' => {
                if (self.macro_register != null) {
                    self.macro_register = null;
                } else {
                    self.pending_macro_record = true;
                }
            },
            '@' => self.pending_macro_play = true,
            ':' => {
                self.command_buffer.clearRetainingCapacity();
                self.mode = .command_line;
            },
            '/' => self.beginSearch(true),
            '?' => self.beginSearch(false),
            'n' => {
                self.recordJump();
                try self.searchAgain(self.takeCount(), self.search_forward);
            },
            'N' => {
                self.recordJump();
                try self.searchAgain(self.takeCount(), !self.search_forward);
            },
            '"' => self.pending_register = 0,
            else => return false,
        }
        return true;
    }

    fn handleCtrl(self: *VimEngine, char: u21) !bool {
        switch (char) {
            'r' => try self.editor.redo(),
            'w' => self.pending_window = true,
            'd' => try self.scrollHalfPage(true),
            'u' => try self.scrollHalfPage(false),
            'f' => try self.scrollPage(true),
            'b' => try self.scrollPage(false),
            'e' => _ = self.editor.scrollViewLines(1),
            'y' => _ = self.editor.scrollViewLines(-1),
            ']' => {
                self.recordJump();
                _ = try self.commands.execute("editor.action.revealDefinition");
            },
            'o' => {
                if (self.history) |history| {
                    _ = try history.goBack();
                } else return false;
            },
            'i' => {
                if (self.history) |history| {
                    _ = try history.goForward();
                } else return false;
            },
            'v' => try self.startVisualBlock(),
            'a' => try self.shiftNumber(1, self.takeCount()),
            'x' => try self.shiftNumber(-1, self.takeCount()),
            else => return false,
        }
        return true;
    }

    fn startOperator(self: *VimEngine, operator: Operator) !void {
        if (self.operator == operator and !self.count_active) {
            // `dd`/`cc`/`yy`: apply immediately as a linewise operator.
            const count = self.operator_count;
            const line = self.editor.cursorPosition().lineNumber;
            self.operator = .none;
            self.operator_count = 1;
            switch (operator) {
                .delete => try self.deleteLines(line, count),
                .change => try self.changeLines(line, count),
                .yank => try self.yankLines(line, count),
                .indent => try self.indentLines(line, count, true),
                .outdent => try self.indentLines(line, count, false),
                .none => {},
            }
            return;
        }
        self.operator = operator;
        self.operator_count = self.takeCount();
        self.mode = .operator_pending;
    }

    fn handleOperatorKey(self: *VimEngine, char: u21) !bool {
        if (char == 'f' or char == 'F' or char == 't' or char == 'T') {
            self.pending_find = .{
                .char = 0,
                .forward = char == 'f' or char == 't',
                .till = char == 't' or char == 'T',
            };
            return true;
        }
        if (char == 'i' or char == 'a') {
            self.pending_text_object = char == 'a';
            return true;
        }
        const motion_count = self.takeCount();
        const count = self.operator_count * motion_count;
        const operator = self.operator;
        self.operator = .none;
        self.operator_count = 1;
        self.mode = .normal;
        if (char == 'd' or char == 'c' or char == 'y' or char == '>' or char == '<') {
            const line = self.editor.cursorPosition().lineNumber;
            switch (operator) {
                .delete => try self.deleteLines(line, count),
                .change => try self.changeLines(line, count),
                .yank => try self.yankLines(line, count),
                .indent => try self.indentLines(line, count, true),
                .outdent => try self.indentLines(line, count, false),
                .none => {},
            }
            return true;
        }
        // Vim's `cw`/`cW` change to the end of the word, not through the
        // following whitespace like `dw`.
        const motion_char = if (operator == .change and (char == 'w' or char == 'W'))
            (if (char == 'w') @as(u21, 'e') else @as(u21, 'E'))
        else
            char;
        const target = try self.motionTarget(motion_char, count);
        if (target == null) return false;
        try self.applyOperator(operator, target.?, false);
        return true;
    }

    fn motionTarget(self: *VimEngine, char: u21, count: usize) !?Range {
        const cursor = self.editor.cursorPosition();
        switch (char) {
            'h' => {
                const position = try self.leftPositionOnLine(cursor, count);
                if (position.equals(cursor)) return null;
                return Range.fromPositions(position, cursor);
            },
            'l' => {
                const position = try self.rightPositionOnLine(cursor, count);
                if (position.equals(cursor)) return null;
                return Range.fromPositions(cursor, position);
            },
            'j', 'k' => {
                if (char == 'j') {
                    const target = @min(cursor.lineNumber + count, self.editor.model.getLineCount());
                    return @as(?Range, try self.linewiseRange(cursor.lineNumber, target - cursor.lineNumber + 1));
                }
                const target = cursor.lineNumber -| count;
                return @as(?Range, try self.linewiseRange(target, cursor.lineNumber - target + 1));
            },
            'w', 'W' => {
                const position = try self.wordPosition(cursor, count, char == 'W', .start);
                return Range.fromPositions(cursor, position);
            },
            'b', 'B' => {
                const position = try self.wordPosition(cursor, count, char == 'B', .back);
                return Range.fromPositions(position, cursor);
            },
            'e', 'E' => {
                const position = try self.wordPosition(cursor, count, char == 'E', .end);
                return Range.fromPositions(cursor, try self.afterPosition(position));
            },
            '(', ')' => {
                const target = try self.sentenceTarget(char == ')', count);
                return if (char == ')') Range.fromPositions(cursor, target) else Range.fromPositions(target, cursor);
            },
            '{', '}' => {
                const target_line = try self.paragraphTarget(char == '}', count);
                if (char == '}') return Range.fromPositions(Position.init(cursor.lineNumber, 1), Position.init(target_line, 1));
                return Range.fromPositions(Position.init(target_line, 1), Position.init(cursor.lineNumber, 1));
            },
            '%' => {
                const target = try self.matchBracketTarget() orelse return null;
                return Range.fromPositions(cursor, target);
            },
            '0' => return Range.fromPositions(Position.init(cursor.lineNumber, 1), cursor),
            '^' => return Range.fromPositions(self.firstNonBlank(cursor.lineNumber), cursor),
            '$' => return Range.fromPositions(cursor, Position.init(cursor.lineNumber, self.lineMaxColumn(cursor.lineNumber))),
            'f', 'F', 't', 'T' => {
                const found = try self.findCharPosition(char, char == 'f' or char == 't', char == 't' or char == 'T', count) orelse return null;
                if (char == 'f' or char == 't') return Range.fromPositions(cursor, try self.afterPosition(found));
                if (char == 'F') return Range.fromPositions(found, try self.afterPosition(cursor));
                return Range.fromPositions(try self.afterPosition(found), try self.afterPosition(cursor));
            },
            'G' => {
                const line = self.editor.model.getLineCount();
                return @as(?Range, try self.linewiseRange(cursor.lineNumber, line - cursor.lineNumber + 1));
            },
            else => return null,
        }
    }

    fn rememberLine(self: *VimEngine, line: usize) !void {
        if (self.line_undo) |undo| {
            if (undo.line == line) return;
            self.allocator.free(undo.text);
            self.line_undo = null;
        }
        var content = try self.editor.model.getLineContent(line);
        defer content.deinit();
        self.line_undo = .{ .line = line, .text = try self.allocator.dupe(u8, content.items) };
    }

    fn undoLine(self: *VimEngine) !void {
        const undo = self.line_undo orelse return;
        self.did_change = true;
        const line = undo.line;
        self.editor.beginUndoGroup();
        defer self.editor.endUndoGroup();
        try self.editor.setCursor(Position.init(line, 1));
        try self.editor.applyEdits(
            &[_]extension_api.ITextEdit{.{ .range = Range.init(line, 1, line, self.lineMaxColumn(line)), .text = undo.text }},
            &[_]Position{Position.init(line, 1)},
        );
        self.allocator.free(undo.text);
        self.line_undo = null;
        try self.editor.setCursor(self.firstNonBlank(line));
    }

    fn indentLines(self: *VimEngine, line: usize, count: usize, indent: bool) !void {
        const range = try self.linewiseRange(line, count);
        try self.applyOperator(if (indent) .indent else .outdent, range, true);
    }

    fn matchBracketTarget(self: *VimEngine) !?Position {
        const model = self.editor.model;
        const cursor = self.editor.cursorPosition();
        if (model.bracketPairs().matchBracket(cursor, null)) |pair| {
            return oppositeBracketPosition(pair, cursor);
        }
        // Vim's `%` searches forward on the cursor's line when it is not on a
        // bracket. `findNextBracket` supplies the next bracket token (skipping
        // brackets inside comments/strings and unexpected closers).
        const next = model.bracketPairs().findNextBracket(cursor) orelse return null;
        if (next.range.startLineNumber != cursor.lineNumber) return null;
        const bracket_position = next.range.getStartPosition();
        const pair = model.bracketPairs().matchBracket(bracket_position, null) orelse return null;
        return oppositeBracketPosition(pair, bracket_position);
    }

    fn matchBracketMotion(self: *VimEngine) !void {
        if (try self.matchBracketTarget()) |position| {
            try self.editor.setCursor(position);
            try self.clampNormal();
        }
    }

    fn sentenceTarget(self: *VimEngine, forward: bool, count: usize) !Position {
        const model = self.editor.model;
        var value = try model.getValue(.LF, false);
        defer value.deinit();
        var offset = model.getOffsetAt(self.editor.cursorPosition());
        var remaining = @max(count, 1);
        while (remaining > 0) : (remaining -= 1) {
            if (forward) {
                var index = @min(offset + 1, value.items.len);
                var found = false;
                while (index < value.items.len) : (index += 1) {
                    const byte = value.items[index];
                    if (byte == '.' or byte == '!' or byte == '?') {
                        const next = if (index + 1 < value.items.len) value.items[index + 1] else ' ';
                        if (std.ascii.isWhitespace(next)) {
                            var target = index + 1;
                            while (target < value.items.len and std.ascii.isWhitespace(value.items[target])) target += 1;
                            offset = @min(target, value.items.len -| 1);
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) offset = value.items.len -| 1;
            } else {
                const original = offset;
                var index = offset;
                while (index > 0) {
                    index -= 1;
                    const byte = value.items[index];
                    if (byte == '.' or byte == '!' or byte == '?') {
                        var target = index + 1;
                        while (target < value.items.len and std.ascii.isWhitespace(value.items[target])) target += 1;
                        if (target == original) continue;
                        offset = target;
                        break;
                    }
                }
            }
        }
        return model.getPositionAt(offset);
    }

    fn moveSentence(self: *VimEngine, forward: bool, count: usize, select: bool) !void {
        const target = try self.sentenceTarget(forward, count);
        if (select) try self.extendSelection(target) else try self.editor.setCursor(target);
        try self.clampNormal();
    }

    fn shiftNumber(self: *VimEngine, delta: i64, count: usize) !void {
        const cursor = self.editor.cursorPosition();
        var line = try self.editor.model.getLineContent(cursor.lineNumber);
        defer line.deinit();
        var start = cursor.column - 1;
        if (start >= line.items.len or !std.ascii.isDigit(line.items[start])) {
            while (start < line.items.len and !std.ascii.isDigit(line.items[start])) start += 1;
        }
        if (start >= line.items.len) return;
        var end = start;
        while (end < line.items.len and std.ascii.isDigit(line.items[end])) end += 1;
        const number = std.fmt.parseInt(i64, line.items[start..end], 10) catch return;
        const next = number + delta * @as(i64, @intCast(@max(count, 1)));
        var buffer: [32]u8 = undefined;
        const replacement = std.fmt.bufPrint(&buffer, "{d}", .{next}) catch return;
        try self.rememberLine(cursor.lineNumber);
        self.did_change = true;
        self.editor.beginUndoGroup();
        defer self.editor.endUndoGroup();
        const range = Range.init(cursor.lineNumber, start + 1, cursor.lineNumber, end + 1);
        try self.editor.applyEdits(&[_]extension_api.ITextEdit{.{ .range = range, .text = replacement }}, &[_]Position{Position.init(cursor.lineNumber, start + replacement.len)});
    }

    fn paragraphTarget(self: *VimEngine, forward: bool, count: usize) !usize {
        const line_count = self.editor.model.getLineCount();
        var line = self.editor.cursorPosition().lineNumber;
        var remaining = @max(count, 1);
        while (remaining > 0) : (remaining -= 1) {
            if (forward) {
                line += 1;
                while (line <= line_count and !try self.isBlankLine(line)) : (line += 1) {}
                if (line > line_count) return line_count;
            } else {
                line -|= 1;
                while (line > 1 and !try self.isBlankLine(line)) : (line -= 1) {}
                if (line == 0) return 1;
            }
        }
        return line;
    }

    fn isBlankLine(self: *VimEngine, line: usize) !bool {
        var content = try self.editor.model.getLineContent(line);
        defer content.deinit();
        for (content.items) |byte| {
            if (byte != ' ' and byte != '\t') return false;
        }
        return true;
    }

    fn moveParagraph(self: *VimEngine, forward: bool, count: usize, select: bool) !void {
        const target = Position.init(try self.paragraphTarget(forward, count), 1);
        if (select) try self.extendSelection(target) else try self.editor.setCursor(target);
    }

    fn moveToScreenLine(self: *VimEngine, where: enum { top, middle, bottom }) !void {
        const height = self.editor.textHeight();
        const top = self.editor.topViewLine();
        const max_view = self.editor.viewLineCount();
        const target_view = switch (where) {
            .top => top,
            .middle => @min(top + height / 2, max_view),
            .bottom => @min(top + height -| 1, max_view),
        };
        const line = @min(self.editor.modelLineNumber(target_view), self.editor.model.getLineCount());
        try self.editor.setCursor(self.firstNonBlank(line));
    }

    fn searchWord(self: *VimEngine, forward: bool) !void {
        const cursor = self.editor.cursorPosition();
        var line = try self.editor.model.getLineContent(cursor.lineNumber);
        defer line.deinit();
        var start = @min(cursor.column - 1, line.items.len);
        while (start > 0 and isWordByte(line.items[start - 1])) start -= 1;
        var end = @min(cursor.column - 1, line.items.len);
        while (end < line.items.len and isWordByte(line.items[end])) end += 1;
        if (end <= start) return;
        self.last_search.clearRetainingCapacity();
        try self.last_search.appendSlice(line.items[start..end]);
        self.last_search_match = null;
        const was_regex = self.search_is_regex;
        self.search_is_regex = false;
        defer self.search_is_regex = was_regex;
        try self.searchAgain(1, forward);
    }

    fn lastNonBlank(self: *VimEngine, line: usize) Position {
        const content = self.editor.model.getLineContent(line) catch return Position.init(line, 1);
        var mutable = content;
        defer mutable.deinit();
        var index = mutable.items.len;
        while (index > 0) : (index -= 1) {
            if (mutable.items[index - 1] != ' ' and mutable.items[index - 1] != '\t') break;
        }
        return Position.init(line, if (index == 0) 1 else index);
    }

    fn applyOperator(self: *VimEngine, operator: Operator, range: Range, linewise: bool) !void {
        if (operator == .indent or operator == .outdent) {
            try self.rememberLine(range.startLineNumber);
            self.did_change = true;
            const start_line = range.startLineNumber;
            var end_line = range.endLineNumber;
            if (end_line > start_line and range.endColumn == 1) end_line -= 1;
            self.editor.beginUndoGroup();
            defer self.editor.endUndoGroup();
            const selections = try self.allocator.alloc(Selection, 1);
            defer self.allocator.free(selections);
            selections[0] = Selection.init(start_line, 1, end_line, self.lineMaxColumn(end_line));
            try self.editor.setSelections(selections);
            if (operator == .indent) try self.editor.indentLines() else try self.editor.outdentLines();
            try self.editor.setCursor(self.firstNonBlank(start_line));
            return;
        }
        if (operator == .yank) {
            const register = self.selectedRegister();
            const text = try self.rangeText(range);
            defer self.allocator.free(text);
            try self.registers.set(register, text, linewise);
            try self.editor.setCursor(range.startPosition());
            return;
        }
        try self.rememberLine(range.startLineNumber);
        self.did_change = true;
        self.editor.beginUndoGroup();
        var keep_group = false;
        defer if (!keep_group) self.editor.endUndoGroup();
        const text = try self.rangeText(range);
        defer self.allocator.free(text);
        try self.registers.set(self.selectedRegister(), text, linewise);
        try self.editor.setCursor(range.startPosition());
        try self.editor.applyEdits(&[_]extension_api.ITextEdit{.{ .range = range, .text = "" }}, &[_]Position{range.startPosition()});
        if (operator == .change) {
            keep_group = true;
            try self.enterInsert(true);
        } else {
            try self.clampNormal();
        }
    }

    fn changeChars(self: *VimEngine, count: usize) !void {
        const cursor = self.editor.cursorPosition();
        const end = try self.rightPositionOnLine(cursor, count);
        if (cursor.equals(end)) return;
        self.editor.beginUndoGroup();
        try self.applyChangeRange(Range.fromPositions(cursor, end));
    }

    fn changeLines(self: *VimEngine, line: usize, count: usize) !void {
        const range = if (count <= 1)
            // `cc` clears the line content but keeps the line break.
            Range.init(line, 1, line, self.lineMaxColumn(line))
        else
            try self.linewiseRange(line, count);
        self.editor.beginUndoGroup();
        try self.applyChangeRange(range);
    }

    fn changeToLineEnd(self: *VimEngine) !void {
        const cursor = self.editor.cursorPosition();
        const end = Position.init(cursor.lineNumber, self.lineMaxColumn(cursor.lineNumber));
        if (cursor.equals(end)) return;
        self.editor.beginUndoGroup();
        try self.applyChangeRange(Range.fromPositions(cursor, end));
    }

    /// Deletes `range` and enters insert mode inside the already-open undo
    /// group. The group closes when insert mode is left.
    fn applyChangeRange(self: *VimEngine, range: Range) !void {
        try self.rememberLine(range.startLineNumber);
        self.did_change = true;
        const text = try self.rangeText(range);
        defer self.allocator.free(text);
        try self.registers.set(self.selectedRegister(), text, false);
        try self.editor.setCursor(range.startPosition());
        try self.editor.applyEdits(&[_]extension_api.ITextEdit{.{ .range = range, .text = "" }}, &[_]Position{range.startPosition()});
        self.insert_group = true;
        self.mode = .insert;
        self.resetPending();
    }

    fn deleteChars(self: *VimEngine, count: usize, backward: bool) !bool {
        const cursor = self.editor.cursorPosition();
        const start = if (backward) try self.leftPositionOnLine(cursor, count) else cursor;
        const end = if (backward) cursor else try self.rightPositionOnLine(cursor, count);
        if (start.equals(end)) return true;
        try self.applyOperator(.delete, Range.fromPositions(start, end), false);
        return true;
    }

    fn deleteToLineEnd(self: *VimEngine) !void {
        const cursor = self.editor.cursorPosition();
        const end = Position.init(cursor.lineNumber, self.lineMaxColumn(cursor.lineNumber));
        try self.applyOperator(.delete, Range.fromPositions(cursor, end), false);
    }

    fn deleteLines(self: *VimEngine, line: usize, count: usize) !void {
        const range = try self.linewiseRange(line, count);
        try self.applyOperator(.delete, range, true);
        try self.clampNormal();
    }

    fn yankLines(self: *VimEngine, line: usize, count: usize) !void {
        const range = try self.linewiseRange(line, count);
        try self.applyOperator(.yank, range, true);
    }

    fn linewiseRange(self: *VimEngine, line: usize, count: usize) !Range {
        const line_count = self.editor.model.getLineCount();
        const start = @min(@max(line, 1), line_count);
        const boundary = start + @max(count, 1);
        if (boundary <= line_count) {
            // Boundary is the start of the first line after the range, so the
            // newline of the last selected line is included.
            return Range.init(start, 1, boundary, 1);
        }
        const end_column = self.editor.model.getLineMaxColumn(line_count);
        if (start > 1) {
            // Deleting the last line also removes the preceding line break.
            const previous_end = self.editor.model.getLineMaxColumn(start - 1);
            return Range.init(start - 1, previous_end, line_count, end_column);
        }
        return Range.init(start, 1, line_count, end_column);
    }

    fn enterAppend(self: *VimEngine) !void {
        const cursor = self.editor.cursorPosition();
        const line = try self.editor.model.getLineContent(cursor.lineNumber);
        defer line.deinit();
        if (line.items.len > 0) {
            try self.editor.setCursor(try self.rightPosition(cursor, 1));
        }
        try self.enterInsert(false);
    }

    fn startReplaceMode(self: *VimEngine) !void {
        try self.enterInsert(false);
        self.mode = .replace;
    }

    fn replaceAtCursor(self: *VimEngine, char: u21) !void {
        self.did_change = true;
        const cursor = self.editor.cursorPosition();
        const line = try self.editor.model.getLineContent(cursor.lineNumber);
        defer line.deinit();
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(char, &buffer) catch return;
        if (cursor.column <= line.items.len) {
            const end_column = try self.nextColumn(cursor.lineNumber, cursor.column);
            try self.editor.applyEdits(
                &[_]extension_api.ITextEdit{.{ .range = Range.init(cursor.lineNumber, cursor.column, cursor.lineNumber, end_column), .text = buffer[0..len] }},
                &[_]Position{Position.init(cursor.lineNumber, cursor.column + len)},
            );
        } else {
            try self.editor.insertText(buffer[0..len]);
        }
    }

    fn enterInsert(self: *VimEngine, group_active: bool) !void {
        try self.rememberLine(self.editor.cursorPosition().lineNumber);
        self.last_insert_position = self.editor.cursorPosition();
        if (!group_active) self.editor.beginUndoGroup();
        self.insert_group = true;
        self.mode = .insert;
        self.resetPending();
    }

    fn openLine(self: *VimEngine, above: bool) !void {
        self.did_change = true;
        const cursor = self.editor.cursorPosition();
        try self.rememberLine(cursor.lineNumber);
        self.editor.beginUndoGroup();
        if (above) {
            try self.editor.setCursor(Position.init(cursor.lineNumber, 1));
        } else {
            try self.editor.setCursor(self.lineEndPosition(cursor.lineNumber, false));
        }
        try self.editor.newline();
        self.insert_group = true;
        self.mode = .insert;
        self.resetPending();
    }

    fn finishInsert(self: *VimEngine) !void {
        if (self.mode == .insert) self.editor.cancelEditorSuggestions();
        self.last_insert_position = self.editor.cursorPosition();
        if (self.block_insert) {
            self.block_insert = false;
            if (self.insert_group) {
                self.editor.endUndoGroup();
                self.insert_group = false;
            }
            self.mode = .normal;
            const selections = try self.editor.getSelections(self.allocator);
            defer self.allocator.free(selections);
            const first = if (selections.len > 0) selections[0].getPosition() else self.editor.cursorPosition();
            try self.editor.setSelections(&[_]Selection{Selection.init(first.lineNumber, first.column, first.lineNumber, first.column)});
            try self.moveLeft(1, false);
            return;
        }
        if (self.insert_group) {
            self.editor.endUndoGroup();
            self.insert_group = false;
        }
        self.mode = .normal;
        try self.moveLeft(1, false);
    }

    fn handleInsert(self: *VimEngine, event: *const KeyInputEvent) !bool {
        const editor_key = switch (event.key) {
            .text => !self.insert_register,
            .char => !event.mods.ctrl and !event.mods.alt and !self.insert_register,
            .enter, .tab, .backtab, .backspace, .delete, .up, .down, .left, .right, .home, .end, .page_up, .page_down => true,
            else => false,
        };
        if (self.mode == .insert and editor_key) {
            self.editor.dispatchEditorKey(event);
            switch (event.key) {
                .text, .char, .enter, .tab, .backtab, .backspace, .delete => self.did_change = true,
                else => {},
            }
            return true;
        }

        switch (event.key) {
            .text => |text| {
                if (self.insert_register) {
                    self.insert_register = false;
                    try self.insertRegister(text);
                    return true;
                }
                self.did_change = true;
                if (self.mode == .replace) {
                    var view = std.unicode.Utf8View.init(text) catch return false;
                    var iterator = view.iterator();
                    while (iterator.nextCodepoint()) |codepoint| try self.replaceAtCursor(codepoint);
                    return true;
                }
                try self.editor.insertText(text);
                return true;
            },
            .char => |char| {
                if (self.insert_register and !event.mods.alt) {
                    self.insert_register = false;
                    try self.insertRegisterAt(char);
                    return true;
                }
                if (event.mods.ctrl) {
                    switch (char) {
                        'w' => try self.deleteWordBefore(),
                        'u' => try self.deleteToLineStart(),
                        'r' => self.insert_register = true,
                        '[' => try self.finishInsert(),
                        else => return false,
                    }
                    return true;
                }
                if (event.mods.alt) return false;
                if (self.mode == .replace) {
                    try self.replaceAtCursor(char);
                    return true;
                }
                self.did_change = true;
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(char, &buffer) catch return false;
                try self.editor.insertText(buffer[0..len]);
                return true;
            },
            .escape => try self.finishInsert(),
            .enter => {
                self.did_change = true;
                try self.editor.newline();
            },
            .tab => {
                self.did_change = true;
                try self.editor.insertTab();
            },
            .backtab => {
                self.did_change = true;
                try self.editor.outdent();
            },
            .backspace => {
                self.did_change = true;
                try self.editor.deleteLeft();
            },
            .delete => {
                self.did_change = true;
                try self.editor.deleteRight();
            },
            .up => try self.moveLogicalLine(false, false, 1),
            .down => try self.moveLogicalLine(true, false, 1),
            .left => try self.moveLeft(1, false),
            .right => try self.moveRight(1, false),
            .home => try self.editor.setCursor(Position.init(self.editor.cursorPosition().lineNumber, 1)),
            .end => try self.editor.setCursor(self.lineEndPosition(self.editor.cursorPosition().lineNumber, false)),
            .insert => {},
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => return false,
            .page_up => _ = self.editor.scrollViewLines(-@as(isize, @intCast(self.editor.textHeight()))),
            .page_down => _ = self.editor.scrollViewLines(@intCast(self.editor.textHeight())),
            .paste_start, .paste_end => return false,
        }
        return true;
    }

    fn handleCommandLine(self: *VimEngine, event: *const KeyInputEvent) !bool {
        switch (event.key) {
            .escape => {
                self.mode = .normal;
                self.command_buffer.clearRetainingCapacity();
            },
            .enter => {
                self.mode = .normal;
                try self.executeCommandLine();
            },
            .backspace => {
                if (self.command_buffer.items.len > 0) self.command_buffer.items.len -= 1;
            },
            .text => |text| try self.command_buffer.appendSlice(text),
            .char => |char| {
                if (event.mods.ctrl) return false;
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(char, &buffer) catch return false;
                try self.command_buffer.appendSlice(buffer[0..len]);
            },
            else => return false,
        }
        return true;
    }

    fn handleSearchInput(self: *VimEngine, event: *const KeyInputEvent) !bool {
        switch (event.key) {
            .escape => {
                try self.cancelSearchPreview();
                self.mode = .normal;
                self.search_buffer.clearRetainingCapacity();
                // Vim restores the previous pattern's hlsearch, not the
                // abandoned preview.
                try self.refreshCommittedHighlight();
            },
            .enter => {
                const forward = self.mode == .search_forward;
                if (self.search_buffer.items.len > 0) {
                    self.last_search.clearRetainingCapacity();
                    try self.last_search.appendSlice(self.search_buffer.items);
                }
                self.mode = .normal;
                self.recordJump();
                // Search from the pre-prompt cursor so the committed match is
                // the one that was previewed (or the count-th one).
                try self.restoreSearchOrigin();
                self.search_origin = null;
                const count = self.search_count;
                self.search_count = 1;
                self.last_search_match = null;
                try self.searchAgain(count, forward);
            },
            .backspace => {
                if (self.search_buffer.items.len > 0) self.search_buffer.items.len -= 1;
                try self.updateSearchPreview();
            },
            .text => |text| {
                try self.search_buffer.appendSlice(text);
                try self.updateSearchPreview();
            },
            .char => |char| {
                if (event.mods.ctrl) return false;
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(char, &buffer) catch return false;
                try self.search_buffer.appendSlice(buffer[0..len]);
                try self.updateSearchPreview();
            },
            else => return false,
        }
        return true;
    }

    fn beginSearch(self: *VimEngine, forward: bool) void {
        self.search_origin = self.editor.cursorPosition();
        self.search_count = self.takeCount();
        self.search_buffer.clearRetainingCapacity();
        self.search_forward = forward;
        self.mode = if (forward) .search_forward else .search_backward;
    }

    fn restoreSearchOrigin(self: *VimEngine) !void {
        const origin = self.search_origin orelse return;
        try self.editor.setCursor(origin);
        try self.editor.clampNormal();
        self.editor.revealRange(Range.init(origin.lineNumber, origin.column, origin.lineNumber, origin.column));
    }

    fn cancelSearchPreview(self: *VimEngine) !void {
        try self.restoreSearchOrigin();
        self.search_origin = null;
        self.search_count = 1;
    }

    /// Vim's `incsearch`: while the prompt is edited, move the cursor to the
    /// first match after the pre-search cursor and highlight every match of
    /// the pattern being typed. An empty pattern or no match restores the
    /// cursor and the committed highlights.
    fn updateSearchPreview(self: *VimEngine) !void {
        const origin = self.search_origin orelse return;
        if (self.search_buffer.items.len == 0) {
            try self.restoreSearchOrigin();
            try self.refreshCommittedHighlight();
            return;
        }

        const model = self.editor.model;
        const forward = self.mode == .search_forward;
        const pattern = self.search_buffer.items;
        const match_case = !self.ignore_case;
        const from = if (forward) try self.afterPosition(origin) else try self.leftPosition(origin, 1);

        var match = if (forward)
            try model.findNextMatch(pattern, from, self.search_is_regex, match_case, null, false)
        else
            try model.findPreviousMatch(pattern, from, self.search_is_regex, match_case, null, false);
        if (match == null) {
            const wrap_position = if (forward)
                Position.init(1, 1)
            else
                Position.init(model.getLineCount(), model.getLineMaxColumn(model.getLineCount()));
            match = if (forward)
                try model.findNextMatch(pattern, wrap_position, self.search_is_regex, match_case, null, false)
            else
                try model.findPreviousMatch(pattern, wrap_position, self.search_is_regex, match_case, null, false);
        }

        const found = match orelse {
            try self.restoreSearchOrigin();
            self.editor.setSearchHighlights(&.{}, null);
            return;
        };

        try self.editor.setCursor(found.range.startPosition());
        try self.editor.clampNormal();
        self.editor.revealRange(found.range);
        try self.refreshSearchHighlights(pattern, self.search_is_regex, found.range);
    }

    /// Repaints the highlights for the committed pattern and current match.
    /// `:noh` keeps the pattern but suppresses the paint until a new search
    /// runs again, like Vim's `no_hlsearch`.
    fn refreshCommittedHighlight(self: *VimEngine) !void {
        if (self.hlsearch_disabled) {
            self.editor.setSearchHighlights(&.{}, null);
            return;
        }
        try self.refreshSearchHighlights(self.last_search.items, self.search_is_regex, self.last_search_match);
    }

    /// Highlights every match of `pattern` with the find-match colors and
    /// `current` with the current-find-match color, exactly like Ctrl+F.
    fn refreshSearchHighlights(self: *VimEngine, pattern: []const u8, is_regex: bool, current: ?Range) !void {
        if (pattern.len == 0) {
            self.editor.setSearchHighlights(&.{}, null);
            return;
        }

        var matches = try self.editor.model.findMatches(
            pattern,
            null,
            is_regex,
            !self.ignore_case,
            null,
            false,
            SEARCH_HIGHLIGHT_LIMIT,
        );
        defer {
            for (matches.items) |*match| match.free(self.allocator);
            matches.deinit();
        }

        var ranges = ArrayList(Range).init(self.allocator);
        defer ranges.deinit();
        for (matches.items) |match| try ranges.append(match.range);
        if (current) |range| {
            var included = false;
            for (ranges.items) |match| {
                if (Range.equalsRange(match, range)) {
                    included = true;
                    break;
                }
            }
            if (!included) try ranges.append(range);
        }
        self.editor.setSearchHighlights(ranges.items, current);
    }

    fn executeCommandLine(self: *VimEngine) !void {
        const command = std.mem.trim(u8, self.command_buffer.items, " \t");
        if (command.len == 0) return;
        if (std.mem.eql(u8, command, "w")) {
            _ = try self.commands.execute("workbench.action.files.save");
        } else if (std.mem.eql(u8, command, "q")) {
            _ = try self.commands.execute("workbench.action.closeActiveEditor");
        } else if (std.mem.eql(u8, command, "q!")) {
            try self.window.forceCloseActive();
        } else if (std.mem.eql(u8, command, "wq")) {
            _ = try self.commands.execute("workbench.action.files.save");
            _ = try self.commands.execute("workbench.action.closeActiveEditor");
        } else if (std.mem.eql(u8, command, "bn")) {
            try self.window.switchTab(1);
        } else if (std.mem.eql(u8, command, "bp")) {
            try self.window.switchTab(-1);
        } else if (std.mem.eql(u8, command, "bd")) {
            _ = try self.commands.execute("workbench.action.closeActiveEditor");
        } else if (std.mem.eql(u8, command, "sp")) {
            _ = try self.commands.execute("workbench.action.splitEditor");
        } else if (std.mem.eql(u8, command, "vsp")) {
            _ = try self.commands.execute("workbench.action.splitEditorOrthogonal");
        } else if (isNohlsearchCommand(command)) {
            // `:noh` is only the shortest abbreviation of `:nohlsearch`; Vim
            // keeps the pattern and clears the painted highlight until the
            // next search runs.
            self.hlsearch_disabled = true;
            self.editor.setSearchHighlights(&.{}, null);
        } else if (std.mem.eql(u8, command, "$")) {
            try self.editor.setCursor(self.firstNonBlank(self.editor.model.getLineCount()));
        } else if (std.mem.eql(u8, command, "set ignorecase")) {
            self.ignore_case = true;
        } else if (std.mem.eql(u8, command, "set noignorecase")) {
            self.ignore_case = false;
        } else if (std.mem.eql(u8, command, "set regex")) {
            self.search_is_regex = true;
        } else if (std.mem.eql(u8, command, "set noregex")) {
            self.search_is_regex = false;
        } else if (std.mem.startsWith(u8, command, "e ")) {
            try self.window.openPath(std.mem.trim(u8, command[2..], " "));
        } else if (std.fmt.parseInt(usize, command, 10)) |line| {
            try self.editor.setCursor(self.firstNonBlank(@min(line, self.editor.model.getLineCount())));
        } else |_| {
            self.window.setMessage("Vim: unsupported command");
        }
    }

    fn searchAgain(self: *VimEngine, count: usize, forward: bool) !void {
        if (self.last_search.items.len == 0) return;
        const model = self.editor.model;
        const cursor = self.editor.cursorPosition();
        var from = if (forward) try self.afterPosition(cursor) else try self.leftPosition(cursor, 1);
        if (self.last_search_match) |last| {
            if (last.containsPosition(&cursor)) {
                from = if (forward) blk: {
                    const end = Position.init(last.endLineNumber, last.endColumn + 1);
                    if (end.column > model.getLineMaxColumn(end.lineNumber)) {
                        if (end.lineNumber < model.getLineCount()) {
                            break :blk Position.init(end.lineNumber + 1, 1);
                        }
                        break :blk end;
                    }
                    break :blk end;
                } else try self.leftPosition(Position.init(last.startLineNumber, last.startColumn), 1);
            }
        }
        var found: ?Range = null;
        var remaining = @max(count, 1);
        while (remaining > 0) : (remaining -= 1) {
            var match = if (forward)
                try model.findNextMatch(self.last_search.items, from, self.search_is_regex, !self.ignore_case, null, false)
            else
                try model.findPreviousMatch(self.last_search.items, from, self.search_is_regex, !self.ignore_case, null, false);
            if (match == null) {
                const wrap_position = if (forward)
                    Position.init(1, 1)
                else
                    Position.init(model.getLineCount(), model.getLineMaxColumn(model.getLineCount()));
                match = if (forward)
                    try model.findNextMatch(self.last_search.items, wrap_position, self.search_is_regex, !self.ignore_case, null, false)
                else
                    try model.findPreviousMatch(self.last_search.items, wrap_position, self.search_is_regex, !self.ignore_case, null, false);
            }
            const found_match = match orelse return;
            found = found_match.range;
            // Advance past the match for the next count iteration.
            if (forward) {
                from = Position.init(found_match.range.endLineNumber, found_match.range.endColumn + 1);
                if (from.column > model.getLineMaxColumn(from.lineNumber)) {
                    if (from.lineNumber < model.getLineCount()) {
                        from = Position.init(from.lineNumber + 1, 1);
                    } else {
                        from = Position.init(from.lineNumber, model.getLineMaxColumn(from.lineNumber));
                    }
                }
            } else {
                from = Position.init(found_match.range.startLineNumber, found_match.range.startColumn);
                if (from.column > 1) {
                    from.column -= 1;
                } else if (from.lineNumber > 1) {
                    from = Position.init(from.lineNumber - 1, model.getLineMaxColumn(from.lineNumber - 1));
                }
            }
        }
        const range = found orelse return;
        self.last_search_match = range;
        self.hlsearch_disabled = false;
        try self.editor.setCursor(range.startPosition());
        try self.clampNormal();
        self.editor.revealRange(range);
        try self.refreshSearchHighlights(self.last_search.items, self.search_is_regex, range);
    }

    fn gotoLine(self: *VimEngine, line: usize) !void {
        try self.editor.setCursor(self.firstNonBlank(@min(line, self.editor.model.getLineCount())));
    }

    fn gotoFileUnderCursor(self: *VimEngine) !void {
        const position = self.editor.cursorPosition();
        const line = try self.editor.model.getLineContent(position.lineNumber);
        defer line.deinit();
        var start = @min(position.column - 1, line.items.len);
        while (start > 0 and isWordByte(line.items[start - 1])) start -= 1;
        var end = @min(position.column - 1, line.items.len);
        while (end < line.items.len and isWordByte(line.items[end])) end += 1;
        if (end <= start) return;
        try self.window.openPath(line.items[start..end]);
    }

    fn handleZ(self: *VimEngine, char: u21) !bool {
        const height = self.editor.textHeight();
        const cursor_view = self.editor.cursorViewLine();
        const max_top = @max(1, self.editor.viewLineCount() -| height + 1);
        switch (char) {
            'z' => {
                const top = if (cursor_view > height / 2) cursor_view - height / 2 else 1;
                _ = self.editor.setTopViewLine(@min(top, max_top));
            },
            't' => _ = self.editor.setTopViewLine(@min(cursor_view, max_top)),
            'b' => _ = self.editor.setTopViewLine(@min(cursor_view -| (height -| 1), max_top)),
            'a' => _ = try self.commands.execute("editor.toggleFold"),
            'c' => _ = try self.commands.execute("editor.fold"),
            'o' => _ = try self.commands.execute("editor.unfold"),
            'M' => _ = try self.commands.execute("editor.foldAll"),
            'R' => _ = try self.commands.execute("editor.unfoldAll"),
            else => return false,
        }
        return true;
    }

    fn scrollHalfPage(self: *VimEngine, down: bool) !void {
        const delta: usize = @max(self.editor.textHeight() / 2, 1);
        const top = self.editor.topViewLine();
        const max_top = @max(1, self.editor.viewLineCount() -| self.editor.textHeight() + 1);
        _ = self.editor.setTopViewLine(if (down) @min(top + delta, max_top) else top -| delta);
        try self.editor.moveWrappedLine(down, false, delta);
        self.editor.ensureCursorVisible();
    }

    fn scrollPage(self: *VimEngine, down: bool) !void {
        const delta: usize = @max(self.editor.textHeight() -| 1, 1);
        const top = self.editor.topViewLine();
        const max_top = @max(1, self.editor.viewLineCount() -| self.editor.textHeight() + 1);
        _ = self.editor.setTopViewLine(if (down) @min(top + delta, max_top) else top -| delta);
        try self.editor.moveWrappedLine(down, false, delta);
        self.editor.ensureCursorVisible();
    }

    fn handleWindowCommand(self: *VimEngine, char: u21) !bool {
        switch (char) {
            'h' => _ = try self.commands.execute("workbench.action.navigateLeft"),
            'l' => _ = try self.commands.execute("workbench.action.navigateRight"),
            'j' => _ = try self.commands.execute("workbench.action.navigateDown"),
            'k' => _ = try self.commands.execute("workbench.action.navigateUp"),
            'w' => _ = try self.commands.execute("workbench.action.navigateEditorGroups"),
            's' => _ = try self.commands.execute("workbench.action.splitEditor"),
            'v' => _ = try self.commands.execute("workbench.action.splitEditorOrthogonal"),
            'c' => _ = try self.commands.execute("workbench.action.closeActiveEditor"),
            'q' => _ = try self.commands.execute("workbench.action.closeActiveEditor"),
            else => return false,
        }
        return true;
    }

    fn rememberVisual(self: *VimEngine) !void {
        const selections = try self.editor.getSelections(self.allocator);
        defer self.allocator.free(selections);
        if (selections.len == 0) return;
        const selection = selections[0];
        self.last_visual = .{
            .range = Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn),
            .linewise = self.mode == .visual_line,
        };
    }

    fn reselectVisual(self: *VimEngine) !void {
        const visual = self.last_visual orelse return;
        self.mode = if (visual.linewise) .visual_line else .visual;
        try self.editor.setSelections(&[_]Selection{Selection.init(
            visual.range.startLineNumber,
            visual.range.startColumn,
            visual.range.endLineNumber,
            visual.range.endColumn,
        )});
    }

    fn gotoLastInsert(self: *VimEngine) !void {
        const position = self.last_insert_position orelse return;
        try self.editor.setCursor(position);
        try self.enterInsert(false);
    }

    fn applyVisualOperator(self: *VimEngine, operator: Operator) !bool {
        const selections = try self.editor.getSelections(self.allocator);
        defer self.allocator.free(selections);
        if (selections.len == 0) return true;
        const selection = selections[0];
        const linewise = self.mode == .visual_line;
        var end_line = selection.endLineNumber;
        if (linewise and end_line > selection.startLineNumber and selection.endColumn == 1) end_line -= 1;
        const range = if (linewise)
            try self.linewiseRange(selection.startLineNumber, end_line - selection.startLineNumber + 1)
        else
            Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn);
        self.last_visual = .{ .range = range, .linewise = linewise };
        self.mode = .normal;
        try self.applyOperator(operator, range, linewise);
        return true;
    }

    fn startVisualBlock(self: *VimEngine) !void {
        const cursor = self.editor.cursorPosition();
        self.visual_block = .{ .anchor = cursor, .cursor = cursor };
        self.mode = .visual_block;
        try self.applyBlockSelections();
    }

    fn applyBlockSelections(self: *VimEngine) !void {
        const block = self.visual_block orelse return;
        const start_line = @min(block.anchor.lineNumber, block.cursor.lineNumber);
        const end_line = @max(block.anchor.lineNumber, block.cursor.lineNumber);
        const start_col = @min(block.anchor.column, block.cursor.column);
        const end_col = @max(block.anchor.column, block.cursor.column) + 1;
        const selections = try self.allocator.alloc(Selection, end_line - start_line + 1);
        defer self.allocator.free(selections);
        var line = start_line;
        while (line <= end_line) : (line += 1) {
            const max_column = self.lineMaxColumn(line);
            const from = @min(start_col, max_column);
            const to = @min(end_col, max_column);
            selections[line - start_line] = Selection.init(line, from, line, @max(from, to));
        }
        try self.editor.setSelections(selections);
    }

    fn handleVisualBlockKey(self: *VimEngine, event: *const KeyInputEvent) !bool {
        const block = &(self.visual_block orelse return false);
        switch (event.key) {
            .escape => {
                self.mode = .normal;
                const position = block.cursor;
                self.visual_block = null;
                try self.editor.setSelections(&[_]Selection{Selection.init(position.lineNumber, position.column, position.lineNumber, position.column)});
                return true;
            },
            .left => {
                block.cursor = try self.leftPositionOnLine(block.cursor, 1);
                try self.applyBlockSelections();
                return true;
            },
            .right => {
                block.cursor = try self.rightPositionOnLine(block.cursor, 1);
                try self.applyBlockSelections();
                return true;
            },
            .up => {
                try self.editor.setCursor(block.cursor);
                try self.moveLogicalLine(false, false, 1);
                block.cursor = self.editor.cursorPosition();
                try self.applyBlockSelections();
                return true;
            },
            .down => {
                try self.editor.setCursor(block.cursor);
                try self.moveLogicalLine(true, false, 1);
                block.cursor = self.editor.cursorPosition();
                try self.applyBlockSelections();
                return true;
            },
            .char => |char| {
                if (event.mods.ctrl or event.mods.alt) return false;
                switch (char) {
                    'h' => block.cursor = try self.leftPositionOnLine(block.cursor, 1),
                    'l' => block.cursor = try self.rightPositionOnLine(block.cursor, 1),
                    '0' => block.cursor = Position.init(block.cursor.lineNumber, 1),
                    '$' => block.cursor = self.lineEndPosition(block.cursor.lineNumber, true),
                    'j' => {
                        try self.editor.setCursor(block.cursor);
                        try self.moveLogicalLine(true, false, 1);
                        block.cursor = self.editor.cursorPosition();
                    },
                    'k' => {
                        try self.editor.setCursor(block.cursor);
                        try self.moveLogicalLine(false, false, 1);
                        block.cursor = self.editor.cursorPosition();
                    },
                    'o' => {
                        const anchor = block.anchor;
                        block.anchor = block.cursor;
                        block.cursor = anchor;
                        try self.applyBlockSelections();
                        return true;
                    },
                    'd' => return self.applyBlockOperator(.delete),
                    'y' => return self.applyBlockOperator(.yank),
                    'c' => return self.applyBlockOperator(.change),
                    'I' => return self.startBlockInsert(false),
                    'A' => return self.startBlockInsert(true),
                    else => return false,
                }
                try self.applyBlockSelections();
                return true;
            },
            .text => |text| {
                var view = std.unicode.Utf8View.init(text) catch return false;
                var iterator = view.iterator();
                var consumed = false;
                while (iterator.nextCodepoint()) |codepoint| {
                    var key_event = KeyInputEvent{ .key = .{ .char = codepoint } };
                    consumed = (try self.handleVisualBlockKey(&key_event)) or consumed;
                }
                return consumed;
            },
            else => return false,
        }
    }

    fn blockBounds(self: *VimEngine) struct { start_line: usize, end_line: usize, start_col: usize, end_col: usize } {
        const block = self.visual_block.?;
        return .{
            .start_line = @min(block.anchor.lineNumber, block.cursor.lineNumber),
            .end_line = @max(block.anchor.lineNumber, block.cursor.lineNumber),
            .start_col = @min(block.anchor.column, block.cursor.column),
            .end_col = @max(block.anchor.column, block.cursor.column) + 1,
        };
    }

    fn startBlockInsert(self: *VimEngine, append: bool) !bool {
        const bounds = self.blockBounds();
        const selections = try self.allocator.alloc(Selection, bounds.end_line - bounds.start_line + 1);
        defer self.allocator.free(selections);
        var line = bounds.start_line;
        while (line <= bounds.end_line) : (line += 1) {
            const max_column = self.lineMaxColumn(line);
            const column = if (append) @min(bounds.end_col, max_column) else @min(bounds.start_col, max_column);
            selections[line - bounds.start_line] = Selection.init(line, column, line, column);
        }
        try self.rememberLine(bounds.start_line);
        self.editor.beginUndoGroup();
        try self.editor.setSelections(selections);
        self.insert_group = true;
        self.block_insert = true;
        self.last_insert_position = Position.init(bounds.start_line, selections[0].positionColumn);
        self.mode = .insert;
        self.visual_block = null;
        self.resetPending();
        return true;
    }

    fn applyBlockOperator(self: *VimEngine, operator: Operator) !bool {
        const bounds = self.blockBounds();
        const start = Position.init(bounds.start_line, bounds.start_col);
        if (operator == .yank) {
            var register_text = ArrayList(u8).init(self.allocator);
            defer register_text.deinit();
            var line = bounds.start_line;
            while (line <= bounds.end_line) : (line += 1) {
                const max_column = self.lineMaxColumn(line);
                const range = Range.init(line, @min(bounds.start_col, max_column), line, @min(bounds.end_col, max_column));
                const text = try self.rangeText(range);
                defer self.allocator.free(text);
                if (line != bounds.start_line) try register_text.append('\n');
                try register_text.appendSlice(text);
            }
            try self.registers.set(self.selectedRegister(), register_text.items, false);
            self.mode = .normal;
            self.visual_block = null;
            try self.editor.setCursor(start);
            return true;
        }

        var edits = ArrayList(extension_api.ITextEdit).init(self.allocator);
        defer edits.deinit();
        var line = bounds.start_line;
        while (line <= bounds.end_line) : (line += 1) {
            const max_column = self.lineMaxColumn(line);
            try edits.append(.{
                .range = Range.init(line, @min(bounds.start_col, max_column), line, @min(bounds.end_col, max_column)),
                .text = "",
            });
        }
        try self.rememberLine(bounds.start_line);
        self.did_change = true;
        self.editor.beginUndoGroup();
        var keep_group = false;
        defer if (!keep_group) self.editor.endUndoGroup();
        try self.editor.setCursor(start);
        try self.editor.applyEdits(edits.items, &[_]Position{start});
        self.mode = .normal;
        self.visual_block = null;
        if (operator == .change) {
            keep_group = true;
            try self.enterInsert(true);
        }
        return true;
    }

    fn startVisual(self: *VimEngine, linewise: bool) !void {
        const cursor = self.editor.cursorPosition();
        if (linewise) {
            const line = cursor.lineNumber;
            const end_line = @min(line + 1, self.editor.model.getLineCount());
            try self.editor.setSelections(&[_]Selection{Selection.init(line, 1, end_line, 1)});
            self.mode = .visual_line;
        } else {
            try self.editor.setSelections(&[_]Selection{Selection.init(cursor.lineNumber, cursor.column, cursor.lineNumber, cursor.column)});
            self.mode = .visual;
        }
    }

    fn applyTextObject(self: *VimEngine, around: bool, char: u21) !void {
        const range = try self.textObjectRange(around, char) orelse return;
        const operator = self.operator;
        self.operator = .none;
        self.operator_count = 1;
        self.mode = .normal;
        try self.applyOperator(operator, range, false);
    }

    fn textObjectRange(self: *VimEngine, around: bool, char: u21) !?Range {
        return switch (char) {
            'w' => try self.wordObject(around, false),
            'W' => try self.wordObject(around, true),
            'b', '(', ')' => try self.bracketObject(around, "(", ")"),
            '[', ']' => try self.bracketObject(around, "[", "]"),
            '{', '}' => try self.bracketObject(around, "{", "}"),
            '<', '>' => try self.bracketObject(around, "<", ">"),
            '"', '\'', '`' => try self.quoteObject(around, @intCast(char)),
            else => null,
        };
    }

    fn bracketObject(self: *VimEngine, around: bool, open_text: []const u8, close_text: []const u8) !?Range {
        const cursor = self.editor.cursorPosition();
        const pair = try bracket_text_objects.ofType(self.editor.model, cursor, open_text, close_text) orelse return null;
        return if (around) pair.around() else pair.inside();
    }

    fn quoteObject(self: *VimEngine, around: bool, quote: u8) !?Range {
        const cursor = self.editor.cursorPosition();
        var line = try self.editor.model.getLineContent(cursor.lineNumber);
        defer line.deinit();
        if (line.items.len == 0) return null;
        const position = @min(cursor.column - 1, line.items.len -| 1);
        var open_index: ?usize = null;
        var close_index: ?usize = null;

        if (line.items[position] == quote) {
            open_index = position;
        } else {
            var index = position;
            while (index > 0) {
                index -= 1;
                if (line.items[index] == quote and !isEscaped(line.items, index)) {
                    open_index = index;
                    break;
                }
            }
        }
        const start = open_index orelse return null;
        var index = start + 1;
        while (index < line.items.len) : (index += 1) {
            if (line.items[index] == quote and !isEscaped(line.items, index)) {
                close_index = index;
                break;
            }
        }
        const end = close_index orelse return null;
        const start_offset = if (around) start else start + 1;
        const end_offset = if (around) end + 1 else end;
        return Range.fromPositions(
            Position.init(cursor.lineNumber, start_offset + 1),
            Position.init(cursor.lineNumber, end_offset + 1),
        );
    }

    fn isEscaped(line: []const u8, index: usize) bool {
        var backslashes: usize = 0;
        var i = index;
        while (i > 0 and line[i - 1] == '\\') : (i -= 1) backslashes += 1;
        return backslashes % 2 == 1;
    }

    fn wordObject(self: *VimEngine, around: bool, big: bool) !Range {
        var value = try self.editor.model.getValue(.LF, false);
        defer value.deinit();
        var offset = self.editor.model.getOffsetAt(self.editor.cursorPosition());
        if (offset >= value.items.len) offset = value.items.len -| 1;
        const word: *const fn (u8) u8 = if (big) wordClassBig else wordClass;
        var start = offset;
        while (start > 0 and word(value.items[start - 1]) == word(value.items[offset])) start -= 1;
        var end = offset;
        while (end < value.items.len and word(value.items[end]) == word(value.items[offset])) end += 1;
        if (around) {
            while (end < value.items.len and word(value.items[end]) == 0) end += 1;
        }
        return Range.fromPositions(self.editor.model.getPositionAt(start), self.editor.model.getPositionAt(end));
    }

    fn put(self: *VimEngine, before: bool, count: usize) !void {
        const register = self.registers.get(self.pending_register orelse 0) orelse return;
        self.did_change = true;
        self.pending_register = null;
        var text = ArrayList(u8).init(self.allocator);
        defer text.deinit();
        var i: usize = 0;
        while (i < count) : (i += 1) try text.appendSlice(register.text);

        const cursor = self.editor.cursorPosition();
        try self.rememberLine(cursor.lineNumber);
        if (register.linewise) {
            const line = if (before) cursor.lineNumber else @min(cursor.lineNumber + 1, self.editor.model.getLineCount() + 1);
            const position = Position.init(line, 1);
            try self.editor.setCursor(position);
            self.editor.beginUndoGroup();
            defer self.editor.endUndoGroup();
            try self.editor.applyEdits(&[_]extension_api.ITextEdit{.{ .range = Range.fromPositions(position, position), .text = text.items }}, &[_]Position{Position.init(line, 1)});
        } else {
            const position = if (before) cursor else try self.rightPosition(cursor, 1);
            try self.editor.setCursor(position);
            self.editor.beginUndoGroup();
            defer self.editor.endUndoGroup();
            try self.editor.applyEdits(&[_]extension_api.ITextEdit{.{ .range = Range.fromPositions(position, position), .text = text.items }}, &[_]Position{position});
        }
    }

    fn joinLines(self: *VimEngine, count: usize, separator: []const u8) !void {
        self.did_change = true;
        const cursor = self.editor.cursorPosition();
        try self.rememberLine(cursor.lineNumber);
        const line_count = self.editor.model.getLineCount();
        if (cursor.lineNumber >= line_count) return;
        const lines = @min(count, line_count - cursor.lineNumber);
        const start = Position.init(cursor.lineNumber, self.editor.model.getLineMaxColumn(cursor.lineNumber));
        const end = Position.init(cursor.lineNumber + lines, 1);
        self.editor.beginUndoGroup();
        defer self.editor.endUndoGroup();
        try self.editor.applyEdits(&[_]extension_api.ITextEdit{.{ .range = Range.fromPositions(start, end), .text = separator }}, &[_]Position{start});
    }

    fn toggleCase(self: *VimEngine, count: usize) !void {
        self.did_change = true;
        const cursor = self.editor.cursorPosition();
        try self.rememberLine(cursor.lineNumber);
        const end = try self.rightPosition(cursor, count);
        const range = Range.fromPositions(cursor, end);
        const text = try self.rangeText(range);
        defer self.allocator.free(text);
        for (text) |*byte| {
            if (std.ascii.isLower(byte.*)) byte.* = std.ascii.toUpper(byte.*) else if (std.ascii.isUpper(byte.*)) byte.* = std.ascii.toLower(byte.*);
        }
        self.editor.beginUndoGroup();
        defer self.editor.endUndoGroup();
        try self.editor.applyEdits(&[_]extension_api.ITextEdit{.{ .range = range, .text = text }}, &[_]Position{cursor});
    }

    fn replaceChars(self: *VimEngine, char: u21, count: usize) !void {
        self.did_change = true;
        const cursor = self.editor.cursorPosition();
        const end = try self.rightPosition(cursor, count);
        if (cursor.equals(end)) return;
        try self.rememberLine(cursor.lineNumber);
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(char, &buffer) catch return;
        var replacement = ArrayList(u8).init(self.allocator);
        defer replacement.deinit();
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) try replacement.appendSlice(buffer[0..len]);
        self.editor.beginUndoGroup();
        defer self.editor.endUndoGroup();
        try self.editor.applyEdits(
            &[_]extension_api.ITextEdit{.{ .range = Range.fromPositions(cursor, end), .text = replacement.items }},
            &[_]Position{cursor},
        );
    }

    fn findCharPosition(self: *VimEngine, char: u21, forward: bool, till: bool, count: usize) !?Position {
        const cursor = self.editor.cursorPosition();
        var line = try self.editor.model.getLineContent(cursor.lineNumber);
        defer line.deinit();
        const needle: u8 = if (char <= 0xff) @intCast(char) else return null;
        var found: ?usize = null;
        var remaining = count;
        var index: usize = if (forward) cursor.column else cursor.column -| 2;
        while (remaining > 0) : (remaining -= 1) {
            if (forward) {
                while (index < line.items.len) : (index += 1) {
                    if (line.items[index] == needle) break;
                }
                if (index >= line.items.len) return null;
                found = index;
                index += 1;
            } else {
                while (true) {
                    if (line.items[index] == needle) break;
                    if (index == 0) return null;
                    index -= 1;
                }
                found = index;
                if (index == 0) break;
                index -= 1;
            }
        }
        var column = (found orelse return null) + 1;
        if (till) column = if (forward) column - 1 else column + 1;
        return Position.init(cursor.lineNumber, column);
    }

    fn findChar(self: *VimEngine, char: u21, forward: bool, till: bool, count: usize) !void {
        if (try self.findCharPosition(char, forward, till, count)) |position| {
            if (self.mode == .visual or self.mode == .visual_line) {
                try self.extendSelection(position);
            } else {
                try self.editor.setCursor(position);
            }
        }
    }

    fn deleteWordBefore(self: *VimEngine) !void {
        const cursor = self.editor.cursorPosition();
        const start = try self.wordPosition(cursor, 1, false, .back);
        try self.applyOperator(.delete, Range.fromPositions(start, cursor), false);
    }

    fn deleteToLineStart(self: *VimEngine) !void {
        const cursor = self.editor.cursorPosition();
        try self.applyOperator(.delete, Range.fromPositions(Position.init(cursor.lineNumber, 1), cursor), false);
    }

    fn insertRegister(self: *VimEngine, text: []const u8) !void {
        if (text.len == 0) return;
        self.did_change = true;
        const name = text[0];
        if (self.registers.get(name)) |register| try self.editor.insertText(register.text);
    }

    fn insertRegisterAt(self: *VimEngine, char: u21) !void {
        if (char > 0xff) return;
        self.did_change = true;
        if (self.registers.get(@intCast(char))) |register| try self.editor.insertText(register.text);
    }

    fn selectedRegister(self: *VimEngine) u8 {
        const register = self.pending_register orelse 0;
        self.pending_register = null;
        return register;
    }

    fn rangeText(self: *VimEngine, range: Range) ![]u8 {
        var value = try self.editor.model.getValueInRange(range, .LF);
        defer value.deinit();
        return self.allocator.dupe(u8, value.items);
    }

    fn moveLeft(self: *VimEngine, count: usize, select: bool) !void {
        const cursor = self.editor.cursorPosition();
        const target = try self.leftPosition(cursor, count);
        if (select) {
            try self.extendSelection(target);
        } else {
            try self.editor.setCursor(target);
        }
    }

    fn moveRight(self: *VimEngine, count: usize, select: bool) !void {
        const cursor = self.editor.cursorPosition();
        const target = try self.rightPosition(cursor, count);
        if (select) {
            try self.extendSelection(target);
        } else {
            try self.editor.setCursor(target);
        }
    }

    fn moveLeftOnLine(self: *VimEngine, count: usize, select: bool) !void {
        const cursor = self.editor.cursorPosition();
        const target = try self.leftPositionOnLine(cursor, count);
        if (select) try self.extendSelection(target) else try self.editor.setCursor(target);
    }

    fn moveRightOnLine(self: *VimEngine, count: usize, select: bool) !void {
        const cursor = self.editor.cursorPosition();
        const target = try self.rightPositionOnLine(cursor, count);
        if (select) try self.extendSelection(target) else try self.editor.setCursor(target);
    }

    fn leftPositionOnLine(self: *VimEngine, position: Position, count: usize) !Position {
        var column = position.column;
        var remaining = count;
        while (remaining > 0 and column > 1) : (remaining -= 1) {
            column = try self.prevColumn(position.lineNumber, column);
        }
        return Position.init(position.lineNumber, column);
    }

    fn rightPositionOnLine(self: *VimEngine, position: Position, count: usize) !Position {
        var column = position.column;
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            const line = try self.editor.model.getLineContent(position.lineNumber);
            defer line.deinit();
            if (column > line.items.len) break;
            const next = try self.nextColumn(position.lineNumber, column);
            if (next == column) break;
            column = next;
        }
        return Position.init(position.lineNumber, column);
    }

    fn extendSelection(self: *VimEngine, target: Position) !void {
        const selections = try self.editor.getSelections(self.allocator);
        defer self.allocator.free(selections);
        if (selections.len == 0) return;
        const anchor = selections[0].getSelectionStart();
        const end = if (self.mode == .visual) try self.afterPosition(target) else target;
        try self.editor.setSelections(&[_]Selection{Selection.init(anchor.lineNumber, anchor.column, end.lineNumber, end.column)});
    }

    fn moveWord(self: *VimEngine, char: u21, count: usize, select: bool) !void {
        const target = try self.wordPosition(self.editor.cursorPosition(), count, char == 'W', .start);
        if (select) try self.extendSelection(target) else try self.editor.setCursor(target);
    }

    fn moveWordBack(self: *VimEngine, char: u21, count: usize, select: bool) !void {
        const target = try self.wordPosition(self.editor.cursorPosition(), count, char == 'B', .back);
        if (select) try self.extendSelection(target) else try self.editor.setCursor(target);
    }

    fn moveWordEnd(self: *VimEngine, char: u21, count: usize, select: bool) !void {
        const target = try self.wordPosition(self.editor.cursorPosition(), count, char == 'E', .end);
        if (select) try self.extendSelection(target) else try self.editor.setCursor(target);
    }

    const WordDirection = enum { start, back, end };

    fn wordPosition(self: *VimEngine, start: Position, count: usize, big: bool, direction: WordDirection) !Position {
        var value = try self.editor.model.getValue(.LF, false);
        defer value.deinit();
        const classifier: *const fn (u8) u8 = if (big) wordClassBig else wordClass;
        var offset = self.editor.model.getOffsetAt(start);
        var remaining = @max(count, 1);
        while (remaining > 0) : (remaining -= 1) {
            switch (direction) {
                .start => {
                    if (offset >= value.items.len) break;
                    if (classifier(value.items[offset]) != 0) {
                        const cls = classifier(value.items[offset]);
                        while (offset < value.items.len and classifier(value.items[offset]) == cls) offset += 1;
                    }
                    while (offset < value.items.len and classifier(value.items[offset]) == 0) offset += 1;
                },
                .back => {
                    if (offset > 0) offset -= 1;
                    while (offset > 0 and classifier(value.items[offset]) == 0) offset -= 1;
                    const cls = classifier(value.items[offset]);
                    while (offset > 0 and classifier(value.items[offset - 1]) == cls) offset -= 1;
                },
                .end => {
                    if (offset < value.items.len) offset += 1;
                    while (offset < value.items.len and classifier(value.items[offset]) == 0) offset += 1;
                    const cls = classifier(value.items[offset]);
                    while (offset + 1 < value.items.len and classifier(value.items[offset + 1]) == cls) offset += 1;
                },
            }
        }
        return self.editor.model.getPositionAt(@min(offset, value.items.len));
    }

    fn leftPosition(self: *VimEngine, position: Position, count: usize) !Position {
        var line_number = position.lineNumber;
        var column = position.column;
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            if (column > 1) {
                column = try self.prevColumn(line_number, column);
            } else if (line_number > 1) {
                line_number -= 1;
                column = self.lineMaxColumn(line_number);
            } else break;
        }
        return Position.init(line_number, column);
    }

    fn rightPosition(self: *VimEngine, position: Position, count: usize) !Position {
        var line_number = position.lineNumber;
        var column = position.column;
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            const line = try self.editor.model.getLineContent(line_number);
            defer line.deinit();
            if (column <= line.items.len) {
                column = try self.nextColumn(line_number, column);
            } else if (line_number < self.editor.model.getLineCount()) {
                line_number += 1;
                column = 1;
            } else break;
        }
        return Position.init(line_number, column);
    }

    fn afterPosition(self: *VimEngine, position: Position) !Position {
        return self.rightPosition(position, 1);
    }

    fn prevColumn(self: *VimEngine, line_number: usize, column: usize) !usize {
        const line = try self.editor.model.getLineContent(line_number);
        defer line.deinit();
        var last: usize = 1;
        var index: usize = 0;
        while (index < line.items.len and index + 1 < column) {
            last = index + 1;
            index += std.unicode.utf8ByteSequenceLength(line.items[index]) catch 1;
        }
        return last;
    }

    fn nextColumn(self: *VimEngine, line_number: usize, column: usize) !usize {
        const line = try self.editor.model.getLineContent(line_number);
        defer line.deinit();
        if (column > line.items.len) return column;
        const len = std.unicode.utf8ByteSequenceLength(line.items[column - 1]) catch 1;
        return @min(column + len, line.items.len + 1);
    }

    fn lineMaxColumn(self: *VimEngine, line_number: usize) usize {
        return self.editor.model.getLineMaxColumn(@min(@max(line_number, 1), self.editor.model.getLineCount()));
    }

    fn lineEndPosition(self: *VimEngine, line_number: usize, normal: bool) Position {
        const line = self.editor.model.getLineContent(line_number) catch return Position.init(line_number, 1);
        defer line.deinit();
        if (line.items.len == 0) return Position.init(line_number, 1);
        if (!normal) return Position.init(line_number, line.items.len + 1);
        var last: usize = 1;
        var index: usize = 0;
        while (index < line.items.len) {
            last = index + 1;
            index += std.unicode.utf8ByteSequenceLength(line.items[index]) catch 1;
        }
        return Position.init(line_number, last);
    }

    fn firstNonBlank(self: *VimEngine, line_number: usize) Position {
        return Position.init(line_number, self.editor.model.getLineFirstNonWhitespaceColumn(line_number) catch 1);
    }

    /// Vim `j`/`k` and the `<Down>`/`<Up>` keys move one logical line.
    /// VSCodeVim's `MoveUp`/`MoveDown` return the current position when the
    /// line cannot change and clamp a count to the lines that are left, which
    /// keeps `vimState.desiredColumn` untouched. The editor's
    /// `moveLogicalLine` instead clamps to the first/last column and resets
    /// `leftoverVisibleColumns` there, losing the remembered column after `k`
    /// on the first line and pulling the caret to the line end after `j` on
    /// the last one.
    fn moveLogicalLine(self: *VimEngine, down: bool, select: bool, count: usize) !void {
        const line_number = self.editor.cursorPosition().lineNumber;
        const line_count = self.editor.model.getLineCount();
        if (down) {
            if (line_number >= line_count) return;
            try self.editor.moveLogicalLine(true, select, @min(count, line_count - line_number));
        } else {
            if (line_number <= 1) return;
            try self.editor.moveLogicalLine(false, select, @min(count, line_number - 1));
        }
    }

    fn clampNormal(self: *VimEngine) !void {
        try self.editor.clampNormal();
    }

    /// External actions (pointer click, tab switch) invalidate a pending
    /// operator/count and end visual mode without touching the selection the
    /// editor is about to apply.
    pub fn resetInteractionState(self: *VimEngine) void {
        self.resetPending();
        if (self.mode == .search_forward or self.mode == .search_backward) {
            self.search_origin = null;
            self.search_count = 1;
            self.search_buffer.clearRetainingCapacity();
        }
        if (self.mode == .visual or self.mode == .visual_line or self.mode == .visual_block) self.mode = .normal;
    }

    fn resetPending(self: *VimEngine) void {
        self.count = 0;
        self.count_active = false;
        self.operator = .none;
        self.operator_count = 1;
        self.pending_register = null;
        self.pending_text_object = null;
        self.pending_visual_text_object = null;
        self.pending_g = false;
        self.pending_z = false;
        self.pending_window = false;
        self.pending_find = null;
        self.pending_replace = false;
        self.pending_macro_record = false;
        self.pending_macro_play = false;
    }

    fn takeCount(self: *VimEngine) usize {
        const count = if (self.count_active) @max(self.count, 1) else 1;
        self.count = 0;
        self.count_active = false;
        return count;
    }
};

/// Vim accepts any unambiguous prefix of `:nohlsearch`; `noh` is the
/// shortest form users type, while `:nohl`, `:nohlse` and the full name are
/// equally valid.
fn isNohlsearchCommand(command: []const u8) bool {
    const name = "nohlsearch";
    return command.len >= "noh".len and
        command.len <= name.len and
        std.mem.startsWith(u8, name, command);
}

fn oppositeBracketPosition(pair: [2]Range, position: Position) Position {
    return if (pair[0].containsPosition(&position)) pair[1].startPosition() else pair[0].startPosition();
}

fn wordClass(byte: u8) u8 {
    if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') return 0;
    if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 128) return 1;
    return 2;
}

fn wordClassBig(byte: u8) u8 {
    if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') return 0;
    return 1;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '/' or byte == '.' or byte == '-';
}

fn findForward(haystack: []const u8, start: usize, needle: []const u8, ignore_case: bool) ?usize {
    if (needle.len == 0 or start >= haystack.len) return null;
    if (!ignore_case) return std.mem.indexOfPos(u8, haystack, start, needle);
    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

fn findBackward(haystack: []const u8, start: usize, needle: []const u8, ignore_case: bool) ?usize {
    if (needle.len == 0 or haystack.len < needle.len or start == 0) return null;
    var index = @min(start, haystack.len - needle.len + 1);
    while (index > 0) {
        index -= 1;
        const candidate = haystack[index .. index + needle.len];
        if (if (ignore_case) std.ascii.eqlIgnoreCase(candidate, needle) else std.mem.eql(u8, candidate, needle)) return index;
    }
    return null;
}
