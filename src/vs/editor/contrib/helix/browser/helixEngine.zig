// Native Helix editing engine.
//
// Deliberate Zig addition, not a VS Code upstream port. The engine owns only
// Helix command state: pending prefixes, count, registers, search, macros and
// the last inserted text. Selections, cursor state, viewport and undo/redo stay
// in the editor (`ITextEditor`). Helix is selection-first: movements build a
// selection, and `d`/`c`/`y` act on that selection.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const helixSelection = @import("./helixSelection.zig");
const bracket_text_objects = @import("../../../common/model/bracketPairsTextModelPart/bracketTextObjects.zig");
const InternalModelContentChangeEvent = @import("../../../common/textModelEvents.zig").InternalModelContentChangeEvent;
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
    select,
    insert,
    goto_mode,
    match_mode,
    view_mode,
    window_mode,
    space_mode,
    command_line,
    search_forward,
    search_backward,
    select_regex,
    split_regex,
    surround_add,
    surround_delete,
    surround_replace,
};

const CaseMode = enum { smart, ignore, sensitive };

const Find = struct { char: u21, forward: bool, till: bool };
const RecordedKey = struct { key: ui.Key, mods: ui.Modifiers };

const RegisterEntry = struct {
    text: []u8,
    linewise: bool,
};

const Register = struct {
    entries: ArrayList(RegisterEntry),

    fn init(allocator: Allocator) Register {
        return .{ .entries = ArrayList(RegisterEntry).init(allocator) };
    }

    fn deinit(self: *Register, allocator: Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.text);
        self.entries.deinit();
    }

    fn clear(self: *Register, allocator: Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.text);
        self.entries.clearRetainingCapacity();
    }

    fn set(self: *Register, allocator: Allocator, entries: []const RegisterEntry) !void {
        self.clear(allocator);
        for (entries) |entry| {
            const copy = try allocator.dupe(u8, entry.text);
            errdefer allocator.free(copy);
            try self.entries.append(.{ .text = copy, .linewise = entry.linewise });
        }
    }
};

pub const Registers = struct {
    allocator: Allocator,
    unnamed: Register,
    named: std.AutoHashMap(u8, Register),

    pub fn init(allocator: Allocator) Registers {
        return .{
            .allocator = allocator,
            .unnamed = Register.init(allocator),
            .named = std.AutoHashMap(u8, Register).init(allocator),
        };
    }

    pub fn deinit(self: *Registers) void {
        self.unnamed.deinit(self.allocator);
        var iterator = self.named.valueIterator();
        while (iterator.next()) |register| register.deinit(self.allocator);
        self.named.deinit();
    }

    fn set(self: *Registers, name: u8, entries: []const RegisterEntry) !void {
        if (name == '_') return;
        if (name == 0 or name == '"') {
            try self.unnamed.set(self.allocator, entries);
            return;
        }
        const entry = try self.named.getOrPut(name);
        if (!entry.found_existing) entry.value_ptr.* = Register.init(self.allocator);
        try entry.value_ptr.set(self.allocator, entries);
    }

    fn get(self: *Registers, name: u8) ?*const Register {
        if (name == '_') return null;
        if (name == 0 or name == '"') return &self.unnamed;
        if (self.named.getPtr(name)) |register| return register;
        return null;
    }
};

const SurroundKind = enum { add, delete, replace };
const SurroundState = struct {
    kind: SurroundKind,
    stage: u2 = 0,
    first: ?u8 = null,
};

const PendingEdit = struct {
    range: Range,
    text: []const u8,
};

const EditOutcome = enum { cursor_start, cursor_end, inserted_range };

pub const HelixEngine = struct {
    allocator: Allocator,
    editor: ITextEditor,
    window: IWindowService,
    commands: ICommandService,
    history: ?extension_api.IHistoryService = null,
    mode: Mode = .normal,
    /// The mode a minor mode returns to; set when a minor mode is entered.
    minor_select: bool = false,
    /// Whether a prompt was entered from select mode.
    prompt_select: bool = false,
    count: usize = 0,
    count_active: bool = false,
    waiting_register: bool = false,
    selected_register: ?u8 = null,
    pending_replace: bool = false,
    pending_insert_register: bool = false,
    pending_find: ?Find = null,
    pending_text_object: ?bool = null,
    surround: ?SurroundState = null,
    last_find: ?Find = null,
    last_macro: ?usize = null,
    command_buffer: ArrayList(u8),
    search_buffer: ArrayList(u8),
    regex_buffer: ArrayList(u8),
    last_search: ArrayList(u8),
    search_forward: bool = true,
    search_is_regex: bool = true,
    case_mode: CaseMode = .smart,
    last_search_match: ?Range = null,
    /// Remembered target column for repeated vertical moves. Mirrors Helix's
    /// per-range `old_visual_position`: crossing a shorter line clamps the
    /// caret but keeps the column for the next vertical move.
    desired_column: ?usize = null,
    /// Selections when the `/` or `?` prompt opened. Incremental previews
    /// always search from this head, and Escape restores these selections.
    search_origin: ?[]Selection = null,
    last_selections: ArrayList(Selection),
    last_insert_text: ArrayList(u8),
    insert_buffer: ArrayList(u8),
    insert_segment: ?InsertSegment = null,
    /// Helix insert-mode ranges while an insert session is active. They are
    /// mapped through the typed edits so Esc can produce the same selection
    /// the reference produces (Helix `Document::selections`).
    insert_ranges: ArrayList(helixSelection.Range),
    /// Whether Esc restores the cursor one grapheme to the left. Only
    /// Helix's `append_mode` (`a`) does that.
    insert_restore_cursor: bool = false,
    insert_group: bool = false,
    registers: *Registers,
    owns_registers: bool = false,
    macros: [26]?ArrayList(RecordedKey) = std.mem.zeroes([26]?ArrayList(RecordedKey)),
    macro_recording: ?usize = null,
    macro_depth: usize = 0,
    replaying: bool = false,
    status_buf: [256]u8 = undefined,

    const InsertSegment = struct {
        model_start: usize,
        buffer_start: usize,
    };

    pub fn init(
        allocator: Allocator,
        editor: ITextEditor,
        window: IWindowService,
        commands: ICommandService,
        shared_registers: ?*Registers,
    ) !*HelixEngine {
        const self = try allocator.create(HelixEngine);
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
            .regex_buffer = ArrayList(u8).init(allocator),
            .last_search = ArrayList(u8).init(allocator),
            .last_selections = ArrayList(Selection).init(allocator),
            .last_insert_text = ArrayList(u8).init(allocator),
            .insert_buffer = ArrayList(u8).init(allocator),
            .insert_ranges = ArrayList(helixSelection.Range).init(allocator),
            .registers = registers,
            .owns_registers = shared_registers == null,
        };
        return self;
    }

    pub fn deinit(self: *HelixEngine) void {
        // The owner closes any open editor undo group before destroying the
        // editor; deinit must not touch an editor that may already be gone.
        self.command_buffer.deinit();
        self.search_buffer.deinit();
        self.regex_buffer.deinit();
        self.last_search.deinit();
        self.freeSearchOrigin();
        self.last_selections.deinit();
        self.last_insert_text.deinit();
        self.insert_buffer.deinit();
        self.insert_ranges.deinit();
        for (&self.macros) |*macro| {
            if (macro.*) |*list| {
                clearRecordedKeys(self.allocator, list);
                list.deinit();
                macro.* = null;
            }
        }
        if (self.owns_registers) {
            self.registers.deinit();
            self.allocator.destroy(self.registers);
        }
        self.allocator.destroy(self);
    }

    pub fn setHistoryService(self: *HelixEngine, history: extension_api.IHistoryService) void {
        self.history = history;
    }

    /// Helix-visible selections. While an insert session is active the editor
    /// only holds the insertion points; the recorded Helix ranges are the
    /// mapped insert ranges.
    pub fn activeSelections(self: *HelixEngine, allocator: Allocator) ![]Selection {
        if (self.mode == .insert and self.insert_ranges.items.len > 0) {
            const result = try allocator.alloc(Selection, self.insert_ranges.items.len);
            for (self.insert_ranges.items, 0..) |range, index| {
                result[index] = self.selectionFromRange(range);
            }
            return result;
        }
        return self.editor.getSelections(allocator);
    }

    /// Primary Helix-visible selection (index 0, matching the editor's primary
    /// cursor ordering).
    pub fn activePrimarySelection(self: *HelixEngine) Selection {
        if (self.mode == .insert and self.insert_ranges.items.len > 0) {
            return self.selectionFromRange(self.insert_ranges.items[0]);
        }
        const selections = self.editor.getSelections(self.allocator) catch
            return Selection.init(1, 1, 1, 1);
        defer self.allocator.free(selections);
        if (selections.len == 0) return Selection.init(1, 1, 1, 1);
        return selections[0];
    }

    pub fn statusText(self: *HelixEngine) []const u8 {
        return switch (self.mode) {
            .insert => "-- INSERT --",
            .select => "-- SELECT --",
            .normal => self.pendingStatus(),
            .goto_mode => "g",
            .match_mode => if (self.pending_text_object) |around|
                (if (around) "ma" else "mi")
            else
                "m",
            .view_mode => "z",
            .window_mode => "<C-w>",
            .space_mode => " ",
            .command_line => std.fmt.bufPrint(&self.status_buf, ":{s}", .{self.command_buffer.items}) catch ":",
            .search_forward => std.fmt.bufPrint(&self.status_buf, "/{s}", .{self.search_buffer.items}) catch "/",
            .search_backward => std.fmt.bufPrint(&self.status_buf, "?{s}", .{self.search_buffer.items}) catch "?",
            .select_regex => std.fmt.bufPrint(&self.status_buf, "s/{s}", .{self.regex_buffer.items}) catch "s/",
            .split_regex => std.fmt.bufPrint(&self.status_buf, "S/{s}", .{self.regex_buffer.items}) catch "S/",
            .surround_add => "ms",
            .surround_delete => "md",
            .surround_replace => "mr",
        };
    }

    fn pendingStatus(self: *HelixEngine) []const u8 {
        if (self.count_active or self.waiting_register or self.selected_register != null or self.pending_replace or self.pending_find != null) {
            var name_buf: [4]u8 = undefined;
            const register_text = if (self.selected_register) |name|
                (std.fmt.bufPrint(&name_buf, "\"{c}", .{name}) catch "\"")
            else
                "";
            return std.fmt.bufPrint(
                &self.status_buf,
                "{s}{s}{s}{s}",
                .{
                    if (self.count_active) "count " else "",
                    if (self.waiting_register) "\"" else "",
                    register_text,
                    if (self.pending_replace) "r" else if (self.pending_find != null) "f" else "",
                },
            ) catch "";
        }
        return "";
    }

    pub fn resetInteractionState(self: *HelixEngine) void {
        self.resetPending();
        if (self.mode == .search_forward or self.mode == .search_backward) {
            self.restoreSearchOrigin() catch {};
            self.freeSearchOrigin();
        }
        if (self.mode == .insert) {
            self.finishInsert() catch {};
        }
        self.surround = null;
        self.minor_select = false;
        if (self.mode != .insert) self.mode = .normal;
    }

    pub fn handleKey(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        if (!self.replaying) {
            if (self.macro_recording != null and !isMacroStopKey(event)) {
                try self.recordMacroKey(event);
            }
        }
        const consumed = try self.dispatchKey(event);
        // The reference commits pending changes to history after each
        // non-insert key event; this is what makes `d u` undo the seeded edit
        // together with the delete while `x d u` undoes only the delete.
        if (self.mode != .insert) self.editor.commitUndoGroup();
        return consumed;
    }

    fn dispatchKey(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        return switch (self.mode) {
            .insert => self.handleInsert(event),
            .command_line => self.handleCommandLine(event),
            .search_forward, .search_backward => self.handleSearchInput(event),
            .select_regex, .split_regex => self.handleRegexInput(event),
            .surround_add, .surround_delete, .surround_replace => self.handleSurroundInput(event),
            else => self.handleNormalKey(event),
        };
    }

    // ------------------------------------------------------------------
    // Selections and positions
    // ------------------------------------------------------------------

    fn getSelections(self: *HelixEngine) ![]Selection {
        return self.editor.getSelections(self.allocator);
    }

    fn setSelections(self: *HelixEngine, selections: []const Selection) !void {
        if (selections.len == 0) return;
        try self.editor.setSelections(selections);
    }

    fn rememberSelections(self: *HelixEngine, selections: []const Selection) !void {
        self.last_selections.clearRetainingCapacity();
        try self.last_selections.appendSlice(selections);
    }

    /// Byte length of the model text used by the Helix offset helpers.
    fn modelLength(self: *HelixEngine) usize {
        return self.editor.model.getValueLength(.LF, false);
    }

    fn selectionRange(self: *HelixEngine, selection: Selection) helixSelection.Range {
        return .{
            .anchor = self.editor.model.getOffsetAt(selection.getSelectionStart()),
            .head = self.editor.model.getOffsetAt(selection.getPosition()),
        };
    }

    fn selectionFromRange(self: *HelixEngine, range: helixSelection.Range) Selection {
        const length = self.modelLength();
        const anchor = self.editor.model.getPositionAt(@min(range.anchor, length));
        const head = self.editor.model.getPositionAt(@min(range.head, length));
        return Selection.init(anchor.lineNumber, anchor.column, head.lineNumber, head.column);
    }

    fn ensureSelection(self: *HelixEngine, text: []const u8, selection: Selection) Selection {
        return self.selectionFromRange(helixSelection.ensureInvariants(text, self.selectionRange(selection)));
    }

    /// Helix `Range::cursor()`: the block-cursor position of a selection.
    fn selectionCursor(self: *HelixEngine, selection: Selection) Position {
        var text = self.modelValue() catch return selection.getPosition();
        defer text.deinit();
        return self.editor.model.getPositionAt(self.selectionRange(selection).cursor(text.items));
    }

    fn clampPosition(self: *HelixEngine, position: Position) Position {
        const line_count = self.editor.model.getLineCount();
        const line = @min(@max(position.lineNumber, 1), line_count);
        const max_column = self.editor.model.getLineMaxColumn(line);
        return Position.init(line, @min(@max(position.column, 1), max_column));
    }

    fn lineMaxColumn(self: *HelixEngine, line: usize) usize {
        const line_count = self.editor.model.getLineCount();
        return self.editor.model.getLineMaxColumn(@min(@max(line, 1), line_count));
    }

    fn firstNonBlank(self: *HelixEngine, line: usize) Position {
        const column = self.editor.model.getLineFirstNonWhitespaceColumn(line) catch 1;
        return Position.init(line, column);
    }

    fn lineEndPosition(self: *HelixEngine, line: usize) Position {
        return Position.init(line, self.lineMaxColumn(line));
    }

    fn lastCharPosition(self: *HelixEngine, line: usize) Position {
        const content = self.editor.model.getLineContent(line) catch return Position.init(line, 1);
        var mutable = content;
        defer mutable.deinit();
        if (mutable.items.len == 0) return Position.init(line, 1);
        var last: usize = 1;
        var index: usize = 0;
        while (index < mutable.items.len) {
            last = index + 1;
            index += std.unicode.utf8ByteSequenceLength(mutable.items[index]) catch 1;
        }
        return Position.init(line, last);
    }

    fn nextColumn(self: *HelixEngine, line: usize, column: usize) !usize {
        const content = try self.editor.model.getLineContent(line);
        defer content.deinit();
        if (column > content.items.len) return column;
        const len = std.unicode.utf8ByteSequenceLength(content.items[column - 1]) catch 1;
        return @min(column + len, content.items.len + 1);
    }

    fn prevColumn(self: *HelixEngine, line: usize, column: usize) !usize {
        if (column <= 1) return 1;
        const content = try self.editor.model.getLineContent(line);
        defer content.deinit();
        var last: usize = 1;
        var index: usize = 0;
        while (index < content.items.len and index + 1 < column) {
            last = index + 1;
            index += std.unicode.utf8ByteSequenceLength(content.items[index]) catch 1;
        }
        return last;
    }

    fn rightPosition(self: *HelixEngine, position: Position, count: usize) !Position {
        var line = position.lineNumber;
        var column = position.column;
        var remaining = @max(count, 1);
        while (remaining > 0) : (remaining -= 1) {
            const max_column = self.lineMaxColumn(line);
            if (column < max_column) {
                column = try self.nextColumn(line, column);
            } else if (line < self.editor.model.getLineCount()) {
                line += 1;
                column = 1;
            } else break;
        }
        return Position.init(line, column);
    }

    fn leftPosition(self: *HelixEngine, position: Position, count: usize) !Position {
        var line = position.lineNumber;
        var column = position.column;
        var remaining = @max(count, 1);
        while (remaining > 0) : (remaining -= 1) {
            if (column > 1) {
                column = try self.prevColumn(line, column);
            } else if (line > 1) {
                line -= 1;
                column = try self.prevColumn(line, self.lineMaxColumn(line) + 1);
            } else break;
        }
        return Position.init(line, column);
    }

    fn positionBefore(self: *HelixEngine, position: Position) !Position {
        return self.leftPosition(position, 1);
    }

    fn positionAfter(self: *HelixEngine, position: Position) !Position {
        return self.rightPosition(position, 1);
    }

    fn charRangeAt(self: *HelixEngine, position: Position) !Range {
        const clamped = self.clampPosition(position);
        const content = try self.editor.model.getLineContent(clamped.lineNumber);
        defer content.deinit();
        if (clamped.column <= content.items.len) {
            const len = std.unicode.utf8ByteSequenceLength(content.items[clamped.column - 1]) catch 1;
            return Range.init(clamped.lineNumber, clamped.column, clamped.lineNumber, @min(clamped.column + len, content.items.len + 1));
        }
        if (clamped.lineNumber < self.editor.model.getLineCount()) {
            return Range.init(clamped.lineNumber, self.lineMaxColumn(clamped.lineNumber), clamped.lineNumber + 1, 1);
        }
        return Range.init(clamped.lineNumber, self.lineMaxColumn(clamped.lineNumber), clamped.lineNumber, self.lineMaxColumn(clamped.lineNumber));
    }

    fn effectiveRange(self: *HelixEngine, selection: Selection) !Range {
        if (!selection.isEmpty()) {
            return Range.init(
                selection.startLineNumber,
                selection.startColumn,
                selection.endLineNumber,
                selection.endColumn,
            );
        }
        return self.charRangeAt(selection.getPosition());
    }

    fn isLinewiseSelection(self: *HelixEngine, selection: Selection) bool {
        if (selection.isEmpty() or selection.startColumn != 1) return false;
        if (selection.endLineNumber > selection.startLineNumber and selection.endColumn == 1) return true;
        return selection.endLineNumber == self.editor.model.getLineCount() and
            selection.endColumn == self.lineMaxColumn(selection.endLineNumber);
    }

    fn linewiseRange(self: *HelixEngine, line: usize, count: usize) !Range {
        const line_count = self.editor.model.getLineCount();
        const start = @min(@max(line, 1), line_count);
        const boundary = start + @max(count, 1);
        if (boundary <= line_count) {
            return Range.init(start, 1, boundary, 1);
        }
        if (start > 1) {
            return Range.init(start - 1, self.lineMaxColumn(start - 1), line_count, self.lineMaxColumn(line_count));
        }
        return Range.init(1, 1, line_count, self.lineMaxColumn(line_count));
    }

    fn lineBoundsRange(self: *HelixEngine, selection: Selection, include_break: bool) !Range {
        const start_line = @min(selection.startLineNumber, selection.endLineNumber);
        var end_line = @max(selection.startLineNumber, selection.endLineNumber);
        if (end_line > start_line and selection.endColumn == 1) end_line -= 1;
        if (include_break and end_line < self.editor.model.getLineCount()) {
            return Range.init(start_line, 1, end_line + 1, 1);
        }
        return Range.init(start_line, 1, end_line, self.lineMaxColumn(end_line));
    }

    fn normalizeSelections(self: *HelixEngine, selections: []const Selection) ![]Selection {
        var text = try self.modelValue();
        defer text.deinit();

        const copy = try self.allocator.alloc(Selection, selections.len);
        defer self.allocator.free(copy);
        for (selections, 0..) |selection, index| {
            copy[index] = self.ensureSelection(text.items, selection);
        }

        const Context = struct {
            engine: *HelixEngine,
            fn lessThan(context: @This(), a: Selection, b: Selection) bool {
                const a_range = context.engine.selectionRange(a);
                const b_range = context.engine.selectionRange(b);
                if (a_range.from() != b_range.from()) return a_range.from() < b_range.from();
                if (a_range.upper() != b_range.upper()) return a_range.upper() < b_range.upper();
                return a_range.anchor < b_range.anchor;
            }
        };
        std.mem.sort(Selection, copy, Context{ .engine = self }, Context.lessThan);

        var output = ArrayList(Selection).init(self.allocator);
        errdefer output.deinit();
        for (copy) |selection| {
            if (output.items.len > 0) {
                const previous = &output.items[output.items.len - 1];
                const previous_range = self.selectionRange(previous.*);
                const range = self.selectionRange(selection);
                if (helixSelection.overlaps(previous_range, range)) {
                    previous.* = self.selectionFromRange(helixSelection.merge(previous_range, range));
                    continue;
                }
            }
            try output.append(selection);
        }
        if (output.items.len == 0) {
            try output.append(Selection.init(1, 1, 1, 1));
        }
        return output.toOwnedSlice();
    }

    fn setNormalizedSelections(self: *HelixEngine, selections: []const Selection) !void {
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.setSelections(normalized);
    }

    fn rangeText(self: *HelixEngine, range: Range) ![]u8 {
        var value = try self.editor.model.getValueInRange(range, .LF);
        defer value.deinit();
        return self.allocator.dupe(u8, value.items);
    }

    fn modelValue(self: *HelixEngine) !ArrayList(u8) {
        return self.editor.model.getValue(.LF, false);
    }

    // ------------------------------------------------------------------
    // Word and character motions
    // ------------------------------------------------------------------

    fn wordClassAt(text: []const u8, offset: usize) u8 {
        if (offset >= text.len) return 0;
        const byte = text[offset];
        if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') return 0;
        if (byte < 128) {
            if (std.ascii.isAlphanumeric(byte) or byte == '_') return 1;
            return 2;
        }
        return 1;
    }

    fn nextCodepointOffset(text: []const u8, offset: usize) usize {
        if (offset >= text.len) return text.len;
        const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
        return @min(offset + len, text.len);
    }

    fn prevCodepointOffset(text: []const u8, offset: usize) usize {
        if (offset == 0) return 0;
        var index = offset - 1;
        while (index > 0 and (text[index] & 0xC0) == 0x80) index -= 1;
        return index;
    }

    const CharCategory = enum { eol, whitespace, word, punctuation, unknown };

    fn isLineEndingCp(ch: u21) bool {
        return ch == '\n' or ch == '\r';
    }

    fn isWhitespaceCp(ch: u21) bool {
        return switch (ch) {
            ' ', '\t', 0x0B, 0x0C, 0x00A0, 0x1680 => true,
            else => false,
        };
    }

    fn isWordCp(ch: u21) bool {
        if (ch < 128) return std.ascii.isAlphanumeric(@intCast(ch)) or ch == '_';
        return true;
    }

    fn categoryOf(ch: u21) CharCategory {
        if (isLineEndingCp(ch)) return .eol;
        if (isWhitespaceCp(ch)) return .whitespace;
        if (isWordCp(ch)) return .word;
        if (ch < 128) return .punctuation;
        return .unknown;
    }

    fn codepointAt(text: []const u8, offset: usize) ?u21 {
        if (offset >= text.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
        if (offset + len > text.len) return null;
        return std.unicode.utf8Decode(text[offset .. offset + len]) catch null;
    }

    fn nextCharOffset(text: []const u8, offset: usize) usize {
        if (offset >= text.len) return text.len;
        return @min(offset + (std.unicode.utf8ByteSequenceLength(text[offset]) catch 1), text.len);
    }

    fn isWordBoundaryCp(a: u21, b: u21) bool {
        return categoryOf(a) != categoryOf(b);
    }

    fn isLongWordBoundaryCp(a: u21, b: u21) bool {
        const a_cat = categoryOf(a);
        const b_cat = categoryOf(b);
        return switch (a_cat) {
            .word => b_cat == .punctuation or b_cat == .whitespace or b_cat == .eol,
            .punctuation => b_cat == .whitespace or b_cat == .eol,
            else => a_cat != b_cat,
        };
    }

    fn reachedWordTarget(target: WordMotion, big: bool, prev_ch: u21, next_ch: u21) bool {
        const boundary = if (big) isLongWordBoundaryCp(prev_ch, next_ch) else isWordBoundaryCp(prev_ch, next_ch);
        return switch (target) {
            .next_start, .prev_end => boundary and (isLineEndingCp(next_ch) or !isWhitespaceCp(next_ch)),
            .next_end, .prev_start => boundary and (!isWhitespaceCp(prev_ch) or isLineEndingCp(next_ch)),
        };
    }

    /// Helix `movement::word_move` / `range_to_target`.
    fn wordMove(text: []const u8, range: helixSelection.Range, count: usize, target: WordMotion, big: bool) helixSelection.Range {
        const is_prev = target == .prev_start or target == .prev_end;
        if (is_prev and range.head == 0) return range;
        if (!is_prev and range.head == text.len) return range;

        var current = if (is_prev)
            (if (range.anchor < range.head)
                helixSelection.Range{ .anchor = range.head, .head = helixSelection.prevGraphemeBoundary(text, range.head) }
            else
                helixSelection.Range{ .anchor = helixSelection.nextGraphemeBoundary(text, range.head), .head = range.head })
        else
            (if (range.anchor < range.head)
                helixSelection.Range{ .anchor = helixSelection.prevGraphemeBoundary(text, range.head), .head = range.head }
            else
                helixSelection.Range{ .anchor = range.head, .head = helixSelection.nextGraphemeBoundary(text, range.head) });

        var remaining = @max(count, 1);
        while (remaining > 0) : (remaining -= 1) {
            const next = wordRangeToTarget(text, current, target, big);
            if (next.anchor == current.anchor and next.head == current.head) break;
            current = next;
        }
        return current;
    }

    fn wordRangeToTarget(text: []const u8, origin: helixSelection.Range, target: WordMotion, big: bool) helixSelection.Range {
        const is_prev = target == .prev_start or target == .prev_end;
        var anchor = origin.anchor;
        var head = origin.head;

        if (!is_prev) {
            var prev_ch: ?u21 = if (head > 0) codepointAt(text, prevCodepointOffset(text, head)) else null;
            while (head < text.len) {
                const ch = codepointAt(text, head) orelse break;
                if (!isLineEndingCp(ch)) break;
                prev_ch = ch;
                head = nextCharOffset(text, head);
            }
            if (prev_ch) |ch| {
                if (isLineEndingCp(ch)) anchor = head;
            }
            const head_start = head;
            while (head < text.len) {
                const next_ch = codepointAt(text, head) orelse break;
                const reached = if (prev_ch) |prev| reachedWordTarget(target, big, prev, next_ch) else true;
                if (reached) {
                    if (head == head_start) {
                        anchor = head;
                    } else break;
                }
                prev_ch = next_ch;
                head = nextCharOffset(text, head);
            }
        } else {
            var prev_ch: ?u21 = if (head < text.len) codepointAt(text, head) else null;
            while (head > 0) {
                const start = prevCodepointOffset(text, head);
                const ch = codepointAt(text, start) orelse break;
                if (!isLineEndingCp(ch)) break;
                prev_ch = ch;
                head = start;
            }
            if (prev_ch) |ch| {
                if (isLineEndingCp(ch)) anchor = head;
            }
            const head_start = head;
            while (head > 0) {
                const start = prevCodepointOffset(text, head);
                const next_ch = codepointAt(text, start) orelse break;
                const reached = if (prev_ch) |prev| reachedWordTarget(target, big, prev, next_ch) else true;
                if (reached) {
                    if (head == head_start) {
                        anchor = head;
                    } else break;
                }
                prev_ch = next_ch;
                head = start;
            }
        }
        return .{ .anchor = anchor, .head = head };
    }

    fn findCharOffset(text: []const u8, start: usize, needle: []const u8, forward: bool) ?usize {
        if (needle.len == 0) return null;
        if (forward) {
            if (start >= text.len) return null;
            return std.mem.indexOfPos(u8, text, start, needle);
        }
        if (text.len < needle.len) return null;
        const end = @min(start, text.len - needle.len + 1);
        var index = end;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, text[index .. index + needle.len], needle)) return index;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Batched edits
    // ------------------------------------------------------------------

    fn finalPosition(text: []const u8, offset: usize) Position {
        var line: usize = 1;
        var line_start: usize = 0;
        const limit = @min(offset, text.len);
        var index: usize = 0;
        while (index < limit) : (index += 1) {
            if (text[index] == '\n') {
                line += 1;
                line_start = index + 1;
            }
        }
        return Position.init(line, limit - line_start + 1);
    }

    fn applyEditBatch(self: *HelixEngine, edits: []const PendingEdit, outcome: EditOutcome) !void {
        if (edits.len == 0) return;

        const Order = struct {
            start: usize,
            end: usize,
            index: usize,
        };
        const order = try self.allocator.alloc(Order, edits.len);
        defer self.allocator.free(order);
        for (edits, 0..) |edit, index| {
            order[index] = .{
                .start = self.editor.model.getOffsetAt(edit.range.startPosition()),
                .end = self.editor.model.getOffsetAt(edit.range.endPosition()),
                .index = index,
            };
        }
        const lessThan = struct {
            fn call(_: void, a: Order, b: Order) bool {
                return a.start < b.start or (a.start == b.start and a.end < b.end);
            }
        }.call;
        std.mem.sort(Order, order, {}, lessThan);

        var old = try self.modelValue();
        defer old.deinit();

        var output = ArrayList(u8).init(self.allocator);
        defer output.deinit();

        const final_starts = try self.allocator.alloc(usize, edits.len);
        defer self.allocator.free(final_starts);
        const final_ends = try self.allocator.alloc(usize, edits.len);
        defer self.allocator.free(final_ends);

        var cursor: usize = 0;
        for (order) |item| {
            if (item.start < cursor) return error.OverlappingEdits;
            try output.appendSlice(old.items[cursor..item.start]);
            final_starts[item.index] = output.items.len;
            try output.appendSlice(edits[item.index].text);
            final_ends[item.index] = output.items.len;
            cursor = item.end;
        }
        try output.appendSlice(old.items[cursor..]);

        const starts = try self.allocator.alloc(Position, edits.len);
        defer self.allocator.free(starts);
        const ends = try self.allocator.alloc(Position, edits.len);
        defer self.allocator.free(ends);
        for (edits, 0..) |_, index| {
            starts[index] = finalPosition(output.items, final_starts[index]);
            ends[index] = finalPosition(output.items, final_ends[index]);
        }

        const translated = try self.allocator.alloc(extension_api.ITextEdit, edits.len);
        defer self.allocator.free(translated);
        for (edits, 0..) |edit, index| {
            translated[index] = .{ .range = edit.range, .text = edit.text };
        }

        const cursors = if (outcome == .cursor_end) ends else starts;
        try self.editor.applyEdits(translated, cursors);

        if (outcome == .inserted_range) {
            const selections = try self.allocator.alloc(Selection, edits.len);
            defer self.allocator.free(selections);
            for (selections, 0..) |*selection, index| {
                selection.* = Selection.init(
                    starts[index].lineNumber,
                    starts[index].column,
                    ends[index].lineNumber,
                    ends[index].column,
                );
            }
            try self.setSelections(selections);
        }
    }

    fn beginUndoGroup(self: *HelixEngine) void {
        self.editor.beginUndoGroup();
    }

    fn endUndoGroup(self: *HelixEngine) void {
        self.editor.endUndoGroup();
    }

    // ------------------------------------------------------------------
    // Normal-mode dispatch
    // ------------------------------------------------------------------

    fn handleNormalKey(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        if (self.waiting_register) {
            self.waiting_register = false;
            switch (event.key) {
                .char => |char| {
                    self.selected_register = if (char <= 0xFF) @intCast(char) else 0;
                    return true;
                },
                .text => |text| {
                    if (text.len > 0) self.selected_register = text[0];
                    return true;
                },
                .escape => return true,
                else => return true,
            }
        }
        if (self.pending_find) |find| {
            self.pending_find = null;
            switch (event.key) {
                .char => |char| {
                    try self.findChar(char, find.forward, find.till, self.takeCount(), self.extendMode());
                    return true;
                },
                .text => |text| {
                    if (text.len > 0) {
                        var view = std.unicode.Utf8View.init(text) catch return true;
                        var iterator = view.iterator();
                        if (iterator.nextCodepoint()) |char| {
                            try self.findChar(char, find.forward, find.till, self.takeCount(), self.extendMode());
                        }
                    }
                    return true;
                },
                else => return true,
            }
        }
        if (self.pending_replace) {
            self.pending_replace = false;
            switch (event.key) {
                .char => |char| {
                    try self.replaceChars(char);
                    return true;
                },
                .text => |text| {
                    var view = std.unicode.Utf8View.init(text) catch return true;
                    var iterator = view.iterator();
                    if (iterator.nextCodepoint()) |char| try self.replaceChars(char);
                    return true;
                },
                .escape => {
                    self.mode = if (self.minor_select) .select else .normal;
                    return true;
                },
                else => return true,
            }
        }
        if (self.pending_insert_register) {
            self.pending_insert_register = false;
            switch (event.key) {
                .char => |char| {
                    if (char <= 0xFF) try self.insertRegisterAt(@intCast(char));
                    return true;
                },
                .text => |text| {
                    if (text.len > 0) try self.insertRegisterAt(text[0]);
                    return true;
                },
                else => return true,
            }
        }

        switch (self.mode) {
            .goto_mode => return self.handleGotoKey(event),
            .match_mode => return self.handleMatchKey(event),
            .view_mode => return self.handleViewKey(event),
            .window_mode => return self.handleWindowKey(event),
            .space_mode => return self.handleSpaceKey(event),
            .surround_add, .surround_delete, .surround_replace => return self.handleSurroundInput(event),
            else => {},
        }

        switch (event.key) {
            .char => |char| {
                if (event.mods.ctrl) return self.handleCtrl(char);
                if (event.mods.alt) return self.handleAlt(char);
                return self.handleNormalChar(char);
            },
            .text => |text| {
                var view = std.unicode.Utf8View.init(text) catch return false;
                var iterator = view.iterator();
                var consumed = false;
                while (iterator.i < text.len) {
                    if (self.mode == .insert) {
                        var remaining = event.*;
                        remaining.key = .{ .text = text[iterator.i..] };
                        return (try self.handleInsert(&remaining)) or consumed;
                    }
                    var single = KeyInputEvent{ .key = .{ .char = iterator.nextCodepoint().? }, .mods = event.mods };
                    consumed = (try self.handleNormalKey(&single)) or consumed;
                }
                return consumed;
            },
            .escape => {
                try self.cancelTransient();
                return true;
            },
            .enter => {
                try self.lineDown(false, 1);
                return true;
            },
            .backspace => {
                try self.moveChar(false, false, 1);
                return true;
            },
            .delete => {
                try self.deleteSelections(true);
                return true;
            },
            .left => {
                try self.moveChar(false, self.extendMode(), self.takeCount());
                return true;
            },
            .right => {
                try self.moveChar(true, self.extendMode(), self.takeCount());
                return true;
            },
            .up => {
                try self.lineUp(self.extendMode(), self.takeCount());
                return true;
            },
            .down => {
                try self.lineDown(self.extendMode(), self.takeCount());
                return true;
            },
            .home => {
                try self.gotoPosition(Position.init(self.primaryHead().lineNumber, 1), self.extendMode());
                return true;
            },
            .end => {
                try self.gotoPosition(self.lineEndPosition(self.primaryHead().lineNumber), self.extendMode());
                return true;
            },
            .page_up => {
                try self.page(false, self.extendMode());
                return true;
            },
            .page_down => {
                try self.page(true, self.extendMode());
                return true;
            },
            .insert, .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12, .tab, .backtab, .paste_start, .paste_end => return false,
        }
    }

    fn handleNormalChar(self: *HelixEngine, char: u21) !bool {
        if (char >= '1' and char <= '9') {
            self.count = self.count * 10 + (char - '0');
            self.count_active = true;
            return true;
        }
        if (char == '0' and self.count_active) {
            self.count = self.count * 10;
            return true;
        }
        // Helix only preserves the vertical desired column across a run of
        // vertical moves.
        if (char != 'j' and char != 'k') self.desired_column = null;

        switch (char) {
            'v' => {
                self.mode = if (self.mode == .select) .normal else .select;
                self.minor_select = false;
                return true;
            },
            'h' => try self.moveChar(false, self.extendMode(), self.takeCount()),
            'l' => try self.moveChar(true, self.extendMode(), self.takeCount()),
            'j' => try self.visualLine(true, self.extendMode(), self.takeCount()),
            'k' => try self.visualLine(false, self.extendMode(), self.takeCount()),
            'w' => try self.wordMotion(.next_start, false, self.extendMode(), self.takeCount()),
            'W' => try self.wordMotion(.next_start, true, self.extendMode(), self.takeCount()),
            'b' => try self.wordMotion(.prev_start, false, self.extendMode(), self.takeCount()),
            'B' => try self.wordMotion(.prev_start, true, self.extendMode(), self.takeCount()),
            'e' => try self.wordMotion(.next_end, false, self.extendMode(), self.takeCount()),
            'E' => try self.wordMotion(.next_end, true, self.extendMode(), self.takeCount()),
            'f' => self.pending_find = .{ .char = 0, .forward = true, .till = false },
            'F' => self.pending_find = .{ .char = 0, .forward = false, .till = false },
            't' => self.pending_find = .{ .char = 0, .forward = true, .till = true },
            'T' => self.pending_find = .{ .char = 0, .forward = false, .till = true },
            '0' => try self.gotoPosition(Position.init(self.primaryHead().lineNumber, 1), self.extendMode()),
            '^' => try self.gotoPosition(self.firstNonBlank(self.primaryHead().lineNumber), self.extendMode()),
            '$' => try self.gotoPosition(self.lineEndPosition(self.primaryHead().lineNumber), self.extendMode()),
            'G' => {
                const line = if (self.count_active) self.takeCount() else self.editor.model.getLineCount();
                try self.gotoPosition(Position.init(@min(line, self.editor.model.getLineCount()), 1), self.extendMode());
            },
            'g' => {
                self.minor_select = self.extendMode();
                self.mode = .goto_mode;
            },
            'm' => {
                self.minor_select = self.extendMode();
                self.mode = .match_mode;
            },
            ' ' => {
                self.minor_select = self.extendMode();
                self.mode = .space_mode;
            },
            'z' => {
                self.minor_select = self.extendMode();
                self.mode = .view_mode;
            },
            'Z' => {
                self.minor_select = self.extendMode();
                self.mode = .view_mode;
            },
            ':' => {
                self.command_buffer.clearRetainingCapacity();
                self.prompt_select = self.extendMode();
                self.mode = .command_line;
            },
            '/' => try self.beginSearch(true),
            '?' => try self.beginSearch(false),
            'n' => try self.searchAgain(self.takeCount(), self.search_forward),
            'N' => try self.searchAgain(self.takeCount(), !self.search_forward),
            '*' => try self.searchSelection(true, false, true),
            's' => {
                self.regex_buffer.clearRetainingCapacity();
                self.prompt_select = self.extendMode();
                self.mode = .select_regex;
            },
            'S' => {
                self.regex_buffer.clearRetainingCapacity();
                self.prompt_select = self.extendMode();
                self.mode = .split_regex;
            },
            'x' => try self.selectLines(self.takeCount()),
            'X' => try self.extendToLineBounds(true),
            'V' => try self.extendToLineBounds(true),
            '%' => try self.selectAll(),
            ';' => try self.collapseSelection(),
            '_' => try self.trimSelections(),
            ',' => try self.keepPrimary(),
            'C' => try self.copySelection(true),
            '(' => try self.rotatePrimary(false),
            ')' => try self.rotatePrimary(true),
            'd' => try self.deleteSelections(true),
            'c' => try self.changeSelections(true),
            'y' => try self.yankSelections(),
            'p' => try self.paste(true),
            'P' => try self.paste(false),
            'R' => try self.replaceWithYanked(),
            'r' => self.pending_replace = true,
            '~' => try self.switchCase(.toggle),
            '`' => try self.switchCase(.lower),
            'i' => try self.enterInsert(.before),
            'a' => try self.enterInsert(.after),
            'I' => try self.enterInsert(.line_start),
            'A' => try self.enterInsert(.line_end),
            'o' => try self.openLine(false),
            'O' => try self.openLine(true),
            '.' => try self.repeatInsert(self.takeCount()),
            'u' => try self.editor.undo(),
            'U' => try self.editor.redo(),
            '>' => {
                try self.indentSelections(true, self.takeCount());
            },
            '<' => {
                try self.indentSelections(false, self.takeCount());
            },
            '=' => try self.formatSelections(),
            'J' => try self.joinSelections(false),
            'q' => try self.replayMacro(self.takeCount()),
            'Q' => try self.toggleMacroRecording(),
            '"' => self.waiting_register = true,
            else => {},
        }
        return true;
    }

    fn handleCtrl(self: *HelixEngine, char: u21) !bool {
        switch (char) {
            'w' => {
                self.minor_select = self.extendMode();
                self.mode = .window_mode;
            },
            's' => self.recordJump(),
            'c' => try self.toggleComments(),
            'r' => try self.editor.redo(),
            'o' => {
                if (self.history) |history| {
                    _ = try history.goBack();
                }
            },
            'i' => {
                if (self.history) |history| {
                    _ = try history.goForward();
                }
            },
            'a' => try self.incrementNumbers(1, self.takeCount()),
            'x' => try self.incrementNumbers(-1, self.takeCount()),
            'd' => try self.halfPage(true, self.extendMode()),
            'u' => try self.halfPage(false, self.extendMode()),
            'f' => try self.page(true, self.extendMode()),
            'b' => try self.page(false, self.extendMode()),
            else => {},
        }
        return true;
    }

    fn handleAlt(self: *HelixEngine, char: u21) !bool {
        switch (char) {
            '.' => {
                if (self.last_find) |find| try self.findChar(find.char, find.forward, find.till, self.takeCount(), self.extendMode());
            },
            ';' => try self.flipSelections(),
            ':' => try self.ensureSelectionsForward(),
            ',' => try self.removePrimary(),
            'C' => try self.copySelection(false),
            'J' => try self.joinSelections(true),
            'd' => try self.deleteSelections(false),
            'c' => try self.changeSelections(false),
            'x' => try self.extendToLineBounds(false),
            's' => try self.splitSelectionsOnNewlines(),
            '-' => try self.mergeSelections(false),
            '_' => try self.mergeSelections(true),
            '*' => try self.searchSelection(false, true, true),
            '`' => try self.switchCase(.upper),
            else => {},
        }
        return true;
    }

    // ------------------------------------------------------------------
    // Movement primitives
    // ------------------------------------------------------------------

    fn extendMode(self: *HelixEngine) bool {
        return self.mode == .select or self.minor_select;
    }

    fn primaryHead(self: *HelixEngine) Position {
        const selections = self.getSelections() catch return Position.init(1, 1);
        defer self.allocator.free(selections);
        if (selections.len == 0) return Position.init(1, 1);
        return selections[0].getPosition();
    }

    fn moveChar(self: *HelixEngine, forward: bool, extend: bool, count: usize) !void {
        var text = try self.modelValue();
        defer text.deinit();
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const updated = try self.allocator.alloc(Selection, selections.len);
        defer self.allocator.free(updated);
        const steps = @max(count, 1);
        for (selections, 0..) |selection, index| {
            const range = self.selectionRange(selection);
            // Helix `move_horizontally` starts from the block cursor, not the
            // selection head.
            var target = range.cursor(text.items);
            for (0..steps) |_| {
                target = if (forward)
                    helixSelection.nextGraphemeBoundary(text.items, target)
                else
                    helixSelection.prevGraphemeBoundary(text.items, target);
            }
            if (extend) {
                updated[index] = self.selectionFromRange(helixSelection.putCursor(text.items, range, target, true));
            } else {
                updated[index] = self.selectionFromRange(helixSelection.ensureInvariants(text.items, helixSelection.Range.point(target)));
            }
        }
        try self.setNormalizedSelections(updated);
    }

    /// Helix `j`/`k`: one visual line at a time. The editor's wrapped-line
    /// movement already collapses the selection when not extending and keeps
    /// the cursor's desired column in `leftoverVisibleColumns`. Collapsing the
    /// selection again from the model selections here would rebuild each
    /// cursor state with a zero desired column, so crossing a short line would
    /// lose the column and pin the following `j`/`k` to that short line.
    /// Upstream recomputes the new position from `old_visual_position` when a
    /// vertical motion cannot change the line, so it is a no-op there; calling
    /// the editor's wrapped-line move instead clamps to the first/last column
    /// and clears the remembered column.
    /// Helix `move_vertically` for j/k (visual lines with soft wrap) and
    /// gj/gk (logical lines). The cassette documents do not wrap, so both
    /// forms move by model lines; the remembered desired column matches
    /// Helix's `old_visual_position` behavior.
    fn verticalMove(self: *HelixEngine, down: bool, extend: bool, count: usize) !void {
        var text = try self.modelValue();
        defer text.deinit();
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const updated = try self.allocator.alloc(Selection, selections.len);
        defer self.allocator.free(updated);
        const line_count = self.editor.model.getLineCount();
        const steps = @max(count, 1);
        var next_desired: ?usize = null;
        for (selections, 0..) |selection, index| {
            const range = self.selectionRange(selection);
            const cursor = self.editor.model.getPositionAt(range.cursor(text.items));
            const current_column = self.desired_column orelse cursor.column;
            const target_line = if (down)
                @min(cursor.lineNumber + steps, line_count)
            else
                @max(cursor.lineNumber -| steps, 1);
            if (target_line == cursor.lineNumber) {
                updated[index] = selection;
            } else {
                const target_column = @min(current_column, self.lineMaxColumn(target_line));
                const target = self.editor.model.getOffsetAt(Position.init(target_line, target_column));
                if (extend) {
                    updated[index] = self.selectionFromRange(helixSelection.putCursor(text.items, range, target, true));
                } else {
                    updated[index] = self.selectionFromRange(helixSelection.ensureInvariants(text.items, helixSelection.Range.point(target)));
                }
            }
            next_desired = if (selections.len == 1) current_column else null;
        }
        self.desired_column = next_desired;
        try self.setNormalizedSelections(updated);
    }

    fn visualLine(self: *HelixEngine, down: bool, extend: bool, count: usize) !void {
        const line_count = self.editor.model.getLineCount();
        if (self.editor.viewLineCount() <= line_count) {
            // No soft wrapping: model lines are visual lines.
            try self.verticalMove(down, extend, count);
            return;
        }
        // A wrapped document needs the editor's visual-line movement. Start it
        // from the Helix block cursors and normalize the result.
        if (!extend) {
            const selections = try self.getSelections();
            defer self.allocator.free(selections);
            const points = try self.allocator.alloc(Selection, selections.len);
            defer self.allocator.free(points);
            for (selections, 0..) |selection, index| {
                const cursor = self.selectionCursor(selection);
                points[index] = Selection.init(cursor.lineNumber, cursor.column, cursor.lineNumber, cursor.column);
            }
            try self.setSelections(points);
        }
        try self.editor.moveWrappedLine(down, extend, count);
        if (!extend) {
            const moved = try self.getSelections();
            defer self.allocator.free(moved);
            try self.setNormalizedSelections(moved);
        }
    }

    fn lineUp(self: *HelixEngine, extend: bool, count: usize) !void {
        try self.verticalMove(false, extend, count);
    }

    fn lineDown(self: *HelixEngine, extend: bool, count: usize) !void {
        try self.verticalMove(true, extend, count);
    }

    const WordMotion = enum { next_start, prev_start, next_end, prev_end };

    fn wordMotion(self: *HelixEngine, motion: WordMotion, big: bool, extend: bool, count: usize) !void {
        var text = try self.modelValue();
        defer text.deinit();
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const updated = try self.allocator.alloc(Selection, selections.len);
        defer self.allocator.free(updated);
        for (selections, 0..) |selection, index| {
            const range = self.selectionRange(selection);
            const target = wordMove(text.items, range, @max(count, 1), motion, big);
            if (extend) {
                // Select-mode word motions extend to the result's cursor
                // (Helix `extend_word_impl`).
                const cursor = target.cursor(text.items);
                updated[index] = self.selectionFromRange(helixSelection.putCursor(text.items, range, cursor, true));
            } else {
                updated[index] = self.selectionFromRange(target);
            }
        }
        try self.setNormalizedSelections(updated);
    }

    fn gotoPosition(self: *HelixEngine, position: Position, extend: bool) !void {
        const clamped = self.clampPosition(position);
        if (extend) {
            const selections = try self.getSelections();
            defer self.allocator.free(selections);
            if (selections.len == 0) return;
            const anchor = selections[0].getSelectionStart();
            try self.editor.setSelections(&[_]Selection{Selection.init(anchor.lineNumber, anchor.column, clamped.lineNumber, clamped.column)});
        } else {
            try self.editor.setSelections(&[_]Selection{Selection.init(clamped.lineNumber, clamped.column, clamped.lineNumber, clamped.column)});
        }
    }

    fn findChar(self: *HelixEngine, char: u21, forward: bool, till: bool, count: usize, extend: bool) !void {
        if (char == 0) return;
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(char, &encoded) catch return;
        var text = try self.modelValue();
        defer text.deinit();
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const updated = try self.allocator.alloc(Selection, selections.len);
        defer self.allocator.free(updated);
        for (selections, 0..) |selection, index| {
            const anchor = selection.getSelectionStart();
            const head = selection.getPosition();
            const head_offset = self.editor.model.getOffsetAt(head);
            var search_start = if (forward) head_offset +| 1 else head_offset;
            var found: ?usize = null;
            var remaining = @max(count, 1);
            while (remaining > 0) : (remaining -= 1) {
                found = findCharOffset(text.items, search_start, encoded[0..len], forward) orelse break;
                search_start = found.? + (if (forward) len else 0);
            }
            const target_offset = found orelse {
                updated[index] = selection;
                continue;
            };
            const target = self.editor.model.getPositionAt(target_offset);
            const until = if (till)
                if (forward) target else self.editor.model.getPositionAt(@min(target_offset + len, text.items.len))
            else if (forward)
                self.editor.model.getPositionAt(@min(target_offset + len, text.items.len))
            else
                target;
            if (extend) {
                updated[index] = Selection.init(anchor.lineNumber, anchor.column, until.lineNumber, until.column);
            } else {
                updated[index] = Selection.init(head.lineNumber, head.column, until.lineNumber, until.column);
            }
            self.last_find = .{ .char = char, .forward = forward, .till = till };
        }
        try self.setNormalizedSelections(updated);
    }

    fn halfPage(self: *HelixEngine, down: bool, extend: bool) !void {
        const delta: usize = @max(self.editor.textHeight() / 2, 1);
        const top = self.editor.topViewLine();
        const max_top = @max(1, self.editor.viewLineCount() -| self.editor.textHeight() + 1);
        _ = self.editor.setTopViewLine(if (down) @min(top + delta, max_top) else top -| delta);
        try self.editor.moveWrappedLine(down, extend, delta);
        self.editor.ensureCursorVisible();
    }

    fn page(self: *HelixEngine, down: bool, extend: bool) !void {
        const delta: usize = @max(self.editor.textHeight() -| 1, 1);
        const top = self.editor.topViewLine();
        const max_top = @max(1, self.editor.viewLineCount() -| self.editor.textHeight() + 1);
        _ = self.editor.setTopViewLine(if (down) @min(top + delta, max_top) else top -| delta);
        try self.editor.moveWrappedLine(down, extend, delta);
        self.editor.ensureCursorVisible();
    }

    fn recordJump(self: *HelixEngine) void {
        if (self.history) |history| history.recordNavigation();
    }

    // ------------------------------------------------------------------
    // Selection manipulation
    // ------------------------------------------------------------------

    fn takeRegister(self: *HelixEngine) u8 {
        const name = self.selected_register orelse 0;
        self.selected_register = null;
        return name;
    }

    fn selectLines(self: *HelixEngine, count: usize) !void {
        var text = try self.modelValue();
        defer text.deinit();
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const updated = try self.allocator.alloc(Selection, selections.len);
        defer self.allocator.free(updated);
        const steps = @max(count, 1);
        for (selections, 0..) |selection, index| {
            const range = self.selectionRange(selection);
            const from_line = self.lineOfOffset(text.items, range.from());
            const to_offset = if (range.isEmpty()) range.upper() else helixSelection.prevGraphemeBoundary(text.items, range.upper());
            const to_line = self.lineOfOffset(text.items, to_offset);
            const start = self.lineStartOffset(from_line);
            const end = self.lineStartOffset(to_line + 1);
            const bounds: [2]usize = if (range.from() == start and range.upper() == end)
                .{ start, self.lineStartOffset(to_line + steps + 1) }
            else
                .{ start, self.lineStartOffset(to_line + steps) };
            updated[index] = self.selectionFromRange(helixSelection.ensureInvariants(text.items, .{ .anchor = bounds[0], .head = bounds[1] }));
        }
        try self.setNormalizedSelections(updated);
    }

    fn lineOfOffset(self: *HelixEngine, text: []const u8, offset: usize) usize {
        return self.editor.model.getPositionAt(@min(offset, text.len)).lineNumber;
    }

    /// Offset of the start of a 1-based model line; one past the last line is
    /// the end of the document (Helix `line_to_char`).
    fn lineStartOffset(self: *HelixEngine, line: usize) usize {
        const line_count = self.editor.model.getLineCount();
        if (line > line_count) return self.modelLength();
        return self.editor.model.getOffsetAt(Position.init(line, 1));
    }

    fn extendToLineBounds(self: *HelixEngine, include_break: bool) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const updated = try self.allocator.alloc(Selection, selections.len);
        defer self.allocator.free(updated);
        for (selections, 0..) |selection, index| {
            const range = try self.lineBoundsRange(selection, include_break);
            updated[index] = Selection.init(range.startLineNumber, range.startColumn, range.endLineNumber, range.endColumn);
        }
        try self.setNormalizedSelections(updated);
    }

    fn selectAll(self: *HelixEngine) !void {
        const line_count = self.editor.model.getLineCount();
        try self.editor.setSelections(&[_]Selection{Selection.init(1, 1, line_count, self.lineMaxColumn(line_count))});
    }

    fn collapseSelection(self: *HelixEngine) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const updated = try self.allocator.alloc(Selection, selections.len);
        defer self.allocator.free(updated);
        for (selections, 0..) |selection, index| {
            // Helix `collapse_selection` collapses to the block cursor.
            const position = self.selectionCursor(selection);
            updated[index] = Selection.init(position.lineNumber, position.column, position.lineNumber, position.column);
        }
        try self.setNormalizedSelections(updated);
    }

    fn flipSelections(self: *HelixEngine) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const updated = try self.allocator.alloc(Selection, selections.len);
        defer self.allocator.free(updated);
        for (selections, 0..) |selection, index| {
            const anchor = selection.getSelectionStart();
            const head = selection.getPosition();
            updated[index] = Selection.init(head.lineNumber, head.column, anchor.lineNumber, anchor.column);
        }
        try self.setNormalizedSelections(updated);
    }

    fn ensureSelectionsForward(self: *HelixEngine) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const updated = try self.allocator.alloc(Selection, selections.len);
        defer self.allocator.free(updated);
        for (selections, 0..) |selection, index| {
            updated[index] = Selection.init(
                selection.startLineNumber,
                selection.startColumn,
                selection.endLineNumber,
                selection.endColumn,
            );
        }
        try self.setNormalizedSelections(updated);
    }

    fn keepPrimary(self: *HelixEngine) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        if (selections.len == 0) return;
        try self.setNormalizedSelections(selections[0..1]);
    }

    fn removePrimary(self: *HelixEngine) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        if (selections.len <= 1) {
            if (selections.len == 1) {
                const position = selections[0].getPosition();
                try self.setNormalizedSelections(&[_]Selection{Selection.init(position.lineNumber, position.column, position.lineNumber, position.column)});
            }
            return;
        }
        try self.setNormalizedSelections(selections[1..]);
    }

    fn rotatePrimary(self: *HelixEngine, forward: bool) !void {
        // Selection order carries Helix's primary selection, so this command
        // must not sort the selections the way normalization does.
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        if (selections.len <= 1) return;
        const rotated = try self.allocator.alloc(Selection, selections.len);
        defer self.allocator.free(rotated);
        if (forward) {
            rotated[selections.len - 1] = selections[0];
            for (selections[1..], 0..) |selection, index| rotated[index] = selection;
        } else {
            rotated[0] = selections[selections.len - 1];
            for (selections[0 .. selections.len - 1], 0..) |selection, index| rotated[index + 1] = selection;
        }
        try self.setSelections(rotated);
    }

    fn isLinewiseRange(self: *HelixEngine, selection: Selection) bool {
        return self.isLinewiseSelection(selection);
    }

    // ------------------------------------------------------------------
    // Registers and editing
    // ------------------------------------------------------------------

    fn setRegisterFromRanges(self: *HelixEngine, selections: []const Selection, ranges: []const Range, texts: *ArrayList([]u8)) !bool {
        if (selections.len != ranges.len) return false;
        var entries = ArrayList(RegisterEntry).init(self.allocator);
        defer entries.deinit();
        for (selections, 0..) |selection, index| {
            const range = ranges[index];
            if (range.isEmpty()) continue;
            const text = try self.rangeText(range);
            errdefer self.allocator.free(text);
            try texts.append(text);
            try entries.append(.{ .text = text, .linewise = self.isLinewiseSelection(selection) });
        }
        if (entries.items.len == 0) return false;
        try self.registers.set(self.takeRegister(), entries.items);
        return true;
    }

    fn deleteSelections(self: *HelixEngine, yank: bool) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);

        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        var ranges = ArrayList(Range).init(self.allocator);
        defer ranges.deinit();
        var range_selections = ArrayList(Selection).init(self.allocator);
        defer range_selections.deinit();
        var texts = ArrayList([]u8).init(self.allocator);
        defer {
            for (texts.items) |text| self.allocator.free(text);
            texts.deinit();
        }

        for (normalized) |selection| {
            const range = try self.effectiveRange(selection);
            if (range.isEmpty()) continue;
            try ranges.append(range);
            try range_selections.append(selection);
            try edits.append(.{ .range = range, .text = "" });
        }
        if (yank) {
            _ = try self.setRegisterFromRanges(range_selections.items, ranges.items, &texts);
        }
        if (edits.items.len > 0) {
            self.beginUndoGroup();
            defer self.endUndoGroup();
            try self.applyEditBatch(edits.items, .cursor_start);
        }
        // Helix maps the deleted selection through the change and normalizes
        // it; the block cursor becomes a one-grapheme selection.
        const updated = try self.getSelections();
        defer self.allocator.free(updated);
        try self.setNormalizedSelections(updated);
        if (self.mode == .select) self.mode = .normal;
        self.minor_select = false;
    }

    fn changeSelections(self: *HelixEngine, yank: bool) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);

        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        var ranges = ArrayList(Range).init(self.allocator);
        defer ranges.deinit();
        var range_selections = ArrayList(Selection).init(self.allocator);
        defer range_selections.deinit();
        var texts = ArrayList([]u8).init(self.allocator);
        defer {
            for (texts.items) |text| self.allocator.free(text);
            texts.deinit();
        }

        for (normalized) |selection| {
            const range = try self.effectiveRange(selection);
            if (range.isEmpty()) continue;
            try ranges.append(range);
            try range_selections.append(selection);
            try edits.append(.{ .range = range, .text = "" });
        }
        if (yank) {
            _ = try self.setRegisterFromRanges(range_selections.items, ranges.items, &texts);
        }

        var all_linewise = normalized.len > 0;
        for (normalized) |selection| {
            if (!self.isLinewiseSelection(selection)) all_linewise = false;
        }

        self.beginUndoGroup();
        var keep = false;
        defer if (!keep) self.endUndoGroup();
        if (edits.items.len > 0) try self.applyEditBatch(edits.items, .cursor_start);

        // Helix `change_selection` on whole lines replaces the lines with a
        // new empty line above the following content (`open(Above)`); other
        // changes enter insert mode at the collapsed deletion point.
        if (all_linewise) {
            var open_edits = ArrayList(PendingEdit).init(self.allocator);
            defer open_edits.deinit();
            const after_delete = try self.getSelections();
            defer self.allocator.free(after_delete);
            for (after_delete) |selection| {
                const position = Position.init(selection.getPosition().lineNumber, 1);
                try open_edits.append(.{ .range = Range.fromPositions(position, position), .text = "\n" });
            }
            if (open_edits.items.len > 0) try self.applyEditBatch(open_edits.items, .cursor_start);
        }

        const opened = try self.getSelections();
        defer self.allocator.free(opened);
        var after_text = try self.modelValue();
        defer after_text.deinit();
        const insert_ranges = try self.allocator.alloc(helixSelection.Range, opened.len);
        defer self.allocator.free(insert_ranges);
        for (opened, 0..) |selection, index| {
            const offset = self.editor.model.getOffsetAt(selection.getPosition());
            insert_ranges[index] = helixSelection.ensureInvariants(after_text.items, helixSelection.Range.point(offset));
        }
        try self.beginInsertRanges(insert_ranges);
        self.insert_restore_cursor = false;
        self.mode = .insert;
        self.insert_group = true;
        self.resetInsertRecording();
        self.resetPending();
        keep = true;
    }

    fn yankSelections(self: *HelixEngine) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);

        var ranges = ArrayList(Range).init(self.allocator);
        defer ranges.deinit();
        for (normalized) |selection| {
            try ranges.append(try self.effectiveRange(selection));
        }
        var texts = ArrayList([]u8).init(self.allocator);
        defer {
            for (texts.items) |text| self.allocator.free(text);
            texts.deinit();
        }
        _ = try self.setRegisterFromRanges(normalized, ranges.items, &texts);
    }

    fn paste(self: *HelixEngine, after: bool) !void {
        const register = self.registers.get(self.takeRegister()) orelse return;
        if (register.entries.items.len == 0) return;
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);

        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        var owned = ArrayList([]u8).init(self.allocator);
        defer {
            for (owned.items) |text| self.allocator.free(text);
            owned.deinit();
        }

        for (normalized, 0..) |selection, index| {
            const entry = register.entries.items[if (register.entries.items.len == 1) 0 else @min(index, register.entries.items.len - 1)];
            const range = try self.effectiveRange(selection);
            if (entry.linewise) {
                const start_line = selection.startLineNumber;
                var end_line = selection.endLineNumber;
                if (end_line > start_line and selection.endColumn == 1) end_line -= 1;
                if (after) {
                    if (end_line < self.editor.model.getLineCount()) {
                        const text = try self.withTrailingNewline(entry.text, true, false);
                        try owned.append(text);
                        try edits.append(.{ .range = Range.init(end_line + 1, 1, end_line + 1, 1), .text = text });
                    } else {
                        const text = try self.withTrailingNewline(entry.text, true, true);
                        try owned.append(text);
                        try edits.append(.{ .range = Range.init(end_line, self.lineMaxColumn(end_line), end_line, self.lineMaxColumn(end_line)), .text = text });
                    }
                } else {
                    const text = try self.withTrailingNewline(entry.text, true, false);
                    try owned.append(text);
                    try edits.append(.{ .range = Range.init(start_line, 1, start_line, 1), .text = text });
                }
            } else {
                const position = if (after)
                    (if (range.isEmpty()) try self.positionAfter(selection.getPosition()) else range.endPosition())
                else
                    selection.getStartPosition();
                try edits.append(.{ .range = Range.fromPositions(position, position), .text = entry.text });
            }
        }
        if (edits.items.len == 0) return;
        self.beginUndoGroup();
        defer self.endUndoGroup();
        try self.applyEditBatch(edits.items, .inserted_range);
    }

    fn withTrailingNewline(self: *HelixEngine, text: []const u8, trailing: bool, leading: bool) ![]u8 {
        var output = ArrayList(u8).init(self.allocator);
        errdefer output.deinit();
        if (leading) try output.append('\n');
        try output.appendSlice(text);
        if (trailing and (output.items.len == 0 or output.items[output.items.len - 1] != '\n')) {
            try output.append('\n');
        }
        return output.toOwnedSlice();
    }

    fn replaceWithYanked(self: *HelixEngine) !void {
        const register = self.registers.get(self.takeRegister()) orelse return;
        if (register.entries.items.len == 0) return;
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);

        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        var owned = ArrayList([]u8).init(self.allocator);
        defer {
            for (owned.items) |text| self.allocator.free(text);
            owned.deinit();
        }
        for (normalized, 0..) |selection, index| {
            const entry = register.entries.items[if (register.entries.items.len == 1) 0 else @min(index, register.entries.items.len - 1)];
            var range = try self.effectiveRange(selection);
            if (entry.linewise) {
                var end_line = selection.endLineNumber;
                if (end_line > selection.startLineNumber and selection.endColumn == 1) end_line -= 1;
                range = try self.linewiseRange(selection.startLineNumber, end_line - selection.startLineNumber + 1);
            }
            const text = try self.withTrailingNewline(entry.text, entry.linewise, false);
            try owned.append(text);
            try edits.append(.{ .range = range, .text = text });
        }
        if (edits.items.len == 0) return;
        self.beginUndoGroup();
        defer self.endUndoGroup();
        try self.applyEditBatch(edits.items, .inserted_range);
    }

    fn replaceChars(self: *HelixEngine, char: u21) !void {
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(char, &encoded) catch return;
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);

        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        var owned = ArrayList([]u8).init(self.allocator);
        defer {
            for (owned.items) |text| self.allocator.free(text);
            owned.deinit();
        }
        for (normalized) |selection| {
            const range = try self.effectiveRange(selection);
            const text = try self.rangeText(range);
            defer self.allocator.free(text);
            var replacement = ArrayList(u8).init(self.allocator);
            errdefer replacement.deinit();
            var index: usize = 0;
            while (index < text.len) {
                if (text[index] == '\n') {
                    try replacement.append('\n');
                    index += 1;
                    continue;
                }
                try replacement.appendSlice(encoded[0..len]);
                index += std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
            }
            if (replacement.items.len == 0) try replacement.appendSlice(encoded[0..len]);
            const slice = try replacement.toOwnedSlice();
            try owned.append(slice);
            try edits.append(.{ .range = range, .text = slice });
        }
        if (edits.items.len == 0) return;
        self.beginUndoGroup();
        defer self.endUndoGroup();
        try self.applyEditBatch(edits.items, .inserted_range);
    }

    const CaseChange = enum { toggle, lower, upper };

    fn switchCase(self: *HelixEngine, change: CaseChange) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);

        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        var owned = ArrayList([]u8).init(self.allocator);
        defer {
            for (owned.items) |text| self.allocator.free(text);
            owned.deinit();
        }
        for (normalized) |selection| {
            const range = try self.effectiveRange(selection);
            const text = try self.rangeText(range);
            defer self.allocator.free(text);
            for (text) |*byte| {
                switch (change) {
                    .toggle => {
                        if (std.ascii.isLower(byte.*)) {
                            byte.* = std.ascii.toUpper(byte.*);
                        } else if (std.ascii.isUpper(byte.*)) {
                            byte.* = std.ascii.toLower(byte.*);
                        }
                    },
                    .lower => byte.* = std.ascii.toLower(byte.*),
                    .upper => byte.* = std.ascii.toUpper(byte.*),
                }
            }
            const copy = try self.allocator.dupe(u8, text);
            try owned.append(copy);
            try edits.append(.{ .range = range, .text = copy });
        }
        if (edits.items.len == 0) return;
        self.beginUndoGroup();
        defer self.endUndoGroup();
        try self.applyEditBatch(edits.items, .inserted_range);
    }

    // ------------------------------------------------------------------
    // Insert mode
    // ------------------------------------------------------------------

    const InsertKind = enum { before, after, line_start, line_end };

    /// Enter insert mode with the given Helix insert-mode ranges: remember
    /// them for the Esc transition and project the insert cursor to the editor
    /// as point selections.
    fn beginInsertRanges(self: *HelixEngine, ranges: []const helixSelection.Range) !void {
        var text = try self.modelValue();
        defer text.deinit();
        self.insert_ranges.clearRetainingCapacity();
        try self.insert_ranges.ensureTotalCapacity(ranges.len);
        const points = try self.allocator.alloc(Selection, ranges.len);
        defer self.allocator.free(points);
        for (ranges, 0..) |range, index| {
            const ensured = helixSelection.ensureInvariants(text.items, range);
            self.insert_ranges.appendAssumeCapacity(ensured);
            const cursor = self.editor.model.getPositionAt(ensured.cursor(text.items));
            points[index] = Selection.init(cursor.lineNumber, cursor.column, cursor.lineNumber, cursor.column);
        }
        try self.setSelections(points);
    }

    fn enterInsert(self: *HelixEngine, kind: InsertKind) !void {
        var text = try self.modelValue();
        defer text.deinit();
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        const ranges = try self.allocator.alloc(helixSelection.Range, normalized.len);
        defer self.allocator.free(ranges);
        for (normalized, 0..) |selection, index| {
            const range = self.selectionRange(selection);
            ranges[index] = switch (kind) {
                // Helix `insert_mode` reverses the selection.
                .before => .{ .anchor = range.upper(), .head = range.from() },
                // Helix `append_mode` extends the selection one grapheme
                // forward; Esc later restores the cursor.
                .after => .{ .anchor = range.from(), .head = helixSelection.nextGraphemeBoundary(text.items, range.upper()) },
                // Helix `insert_with_indent` moves to the first non-blank
                // (line start) or line end, then ensures invariants.
                .line_start => blk: {
                    const cursor = self.editor.model.getPositionAt(range.cursor(text.items));
                    const offset = self.editor.model.getOffsetAt(self.firstNonBlank(cursor.lineNumber));
                    break :blk helixSelection.ensureInvariants(text.items, helixSelection.Range.point(offset));
                },
                .line_end => blk: {
                    const cursor = self.editor.model.getPositionAt(range.cursor(text.items));
                    const offset = self.editor.model.getOffsetAt(self.lineEndPosition(cursor.lineNumber));
                    break :blk helixSelection.ensureInvariants(text.items, helixSelection.Range.point(offset));
                },
            };
        }
        self.beginUndoGroup();
        errdefer self.endUndoGroup();
        try self.beginInsertRanges(ranges);
        self.insert_restore_cursor = kind == .after;
        self.mode = .insert;
        self.insert_group = true;
        self.resetInsertRecording();
        self.resetPending();
    }

    fn openLine(self: *HelixEngine, above: bool) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        const targets = try self.allocator.alloc(Position, normalized.len);
        defer self.allocator.free(targets);
        for (normalized, 0..) |selection, index| {
            targets[index] = if (above)
                Position.init(selection.startLineNumber, 1)
            else
                Position.init(selection.endLineNumber, self.lineMaxColumn(selection.endLineNumber));
        }
        self.beginUndoGroup();
        errdefer self.endUndoGroup();
        if (above) {
            var edits = ArrayList(PendingEdit).init(self.allocator);
            defer edits.deinit();
            for (targets) |target| {
                const position = Position.init(target.lineNumber, 1);
                try edits.append(.{ .range = Range.fromPositions(position, position), .text = "\n" });
            }
            try self.applyEditBatch(edits.items, .cursor_start);
        } else {
            const empty = try self.allocator.alloc(Selection, targets.len);
            defer self.allocator.free(empty);
            for (targets, 0..) |target, index| {
                empty[index] = Selection.init(target.lineNumber, target.column, target.lineNumber, target.column);
            }
            try self.setSelections(empty);
            try self.editor.newline();
        }
        // Helix `open` places a point selection on the new line; the insert
        // range is that point's one-grapheme range.
        const opened = try self.getSelections();
        defer self.allocator.free(opened);
        var after_text = try self.modelValue();
        defer after_text.deinit();
        const ranges = try self.allocator.alloc(helixSelection.Range, opened.len);
        defer self.allocator.free(ranges);
        for (opened, 0..) |selection, index| {
            const offset = self.editor.model.getOffsetAt(selection.getPosition());
            ranges[index] = helixSelection.ensureInvariants(after_text.items, helixSelection.Range.point(offset));
        }
        try self.beginInsertRanges(ranges);
        self.insert_restore_cursor = false;
        self.mode = .insert;
        self.insert_group = true;
        self.resetInsertRecording();
        self.resetPending();
    }

    fn finishInsert(self: *HelixEngine) !void {
        self.editor.cancelEditorSuggestions();
        if (self.insert_group) {
            self.endUndoGroup();
            self.insert_group = false;
        }
        if (self.insert_buffer.items.len > 0) {
            self.last_insert_text.clearRetainingCapacity();
            try self.last_insert_text.appendSlice(self.insert_buffer.items);
        }
        self.resetInsertRecording();
        self.mode = .normal;
        self.minor_select = false;
        self.resetPending();

        if (self.insert_ranges.items.len > 0) {
            var text = try self.modelValue();
            defer text.deinit();
            const updated = try self.allocator.alloc(Selection, self.insert_ranges.items.len);
            defer self.allocator.free(updated);
            for (self.insert_ranges.items, 0..) |range, index| {
                var final = range;
                // Helix `enter_normal_mode`: only append mode (`restore_cursor`)
                // moves the head one grapheme back.
                if (self.insert_restore_cursor and range.head > range.anchor) {
                    final = .{
                        .anchor = range.from(),
                        .head = helixSelection.prevGraphemeBoundary(text.items, range.upper()),
                    };
                }
                updated[index] = self.selectionFromRange(helixSelection.ensureInvariants(text.items, final));
            }
            self.insert_ranges.clearRetainingCapacity();
            self.insert_restore_cursor = false;
            try self.setNormalizedSelections(updated);
            return;
        }

        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const collapsed = try self.allocator.alloc(Selection, selections.len);
        defer self.allocator.free(collapsed);
        for (selections, 0..) |selection, index| {
            const head = selection.getPosition();
            var column = head.column;
            if (column > 1) column = self.prevColumn(head.lineNumber, column) catch column;
            collapsed[index] = Selection.init(head.lineNumber, column, head.lineNumber, column);
        }
        try self.setNormalizedSelections(collapsed);
    }

    fn handleInsert(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        const model = self.editor.model;
        const offset = model.getOffsetAt(self.editor.cursorPosition());
        const next_segment = InsertSegment{
            .model_start = offset,
            .buffer_start = self.insert_buffer.items.len,
        };
        const segment = self.insert_segment orelse next_segment;
        const length = self.insert_buffer.items.len - segment.buffer_start;
        self.insert_segment = if (offset >= segment.model_start and offset <= segment.model_start + length)
            segment
        else
            next_segment;

        const listener = try model.onDidChangeContentWithContextId(self, recordInsertChanges);
        defer model.removeDidChangeContentListener(listener);
        return self.dispatchInsertKey(event);
    }

    // Keep the primary insertion in document order, including auto-closed
    // pairs and completion replacements. Edits before it shift the segment
    // without adding text from secondary cursors or completion imports.
    fn recordInsertChanges(event: InternalModelContentChangeEvent, self: *HelixEngine) !void {
        // Map the remembered insert-mode Helix ranges through the edit with
        // the same sticky associations Helix uses.
        if (self.insert_ranges.items.len > 0 and event.contentChangedEvent.changes.items.len > 0) {
            const events = event.contentChangedEvent.changes.items;
            const changes = try self.allocator.alloc(helixSelection.Change, events.len);
            defer self.allocator.free(changes);
            for (events, 0..) |change, index| {
                // The event lists changes from the end of the document to the
                // beginning; `mapOffset` wants ascending document order.
                changes[events.len - 1 - index] = .{
                    .start = change.rangeOffset,
                    .end = change.rangeOffset + change.rangeLength,
                    .inserted_len = change.text.items().len,
                };
            }
            for (self.insert_ranges.items) |*range| {
                range.* = helixSelection.mapRange(changes, range.*);
            }
        }

        var segment = self.insert_segment orelse return;
        defer self.insert_segment = segment;
        for (event.contentChangedEvent.changes.items) |change| {
            const start = change.rangeOffset;
            const end = start + change.rangeLength;
            const text = change.text.items();
            if (end < segment.model_start) {
                segment.model_start = segment.model_start - change.rangeLength + text.len;
                continue;
            }
            const length = self.insert_buffer.items.len - segment.buffer_start;
            if (start > segment.model_start + length) continue;
            const first = start -| segment.model_start;
            const last = @min(end -| segment.model_start, length);
            try self.insert_buffer.replaceRange(segment.buffer_start + first, last - first, text);
            segment.model_start = @min(segment.model_start, start);
        }
    }

    fn resetInsertRecording(self: *HelixEngine) void {
        self.insert_buffer.clearRetainingCapacity();
        self.insert_segment = null;
    }

    fn dispatchInsertKey(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        if (self.pending_insert_register) {
            self.pending_insert_register = false;
            switch (event.key) {
                .char => |char| {
                    if (char <= 0xFF) try self.insertRegisterAt(@intCast(char));
                    return true;
                },
                .text => |text| {
                    if (text.len > 0) try self.insertRegisterAt(text[0]);
                    return true;
                },
                else => return true,
            }
        }
        switch (event.key) {
            .char => |char| {
                if (event.mods.ctrl and char != ' ' and char != '@') return self.handleInsertCtrl(char);
                if (event.mods.alt) return self.handleInsertAlt(char);
            },
            .escape => {
                try self.finishInsert();
                return true;
            },
            .backtab => {
                self.editor.dispatchEditorKeyWithFallback(event, .{ .key = .{ .text = "\t" } });
                return true;
            },
            .backspace => if (event.mods.alt) {
                try self.deleteWordBefore();
                return true;
            },
            .delete => if (event.mods.alt) {
                try self.deleteWordForward();
                return true;
            },
            .insert, .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12, .paste_start, .paste_end => return false,
            else => {},
        }
        self.editor.dispatchEditorKey(event);
        return true;
    }

    fn handleInsertCtrl(self: *HelixEngine, char: u21) !bool {
        switch (char) {
            'w' => try self.deleteWordBefore(),
            'u' => try self.deleteToLineStart(),
            'k' => try self.deleteToLineEnd(),
            'r' => self.pending_insert_register = true,
            's' => try self.commitUndoCheckpoint(),
            'd' => self.editor.dispatchEditorKey(&.{ .key = .delete }),
            'h' => self.editor.dispatchEditorKey(&.{ .key = .backspace }),
            'j' => self.editor.dispatchEditorKey(&.{ .key = .enter }),
            'c' => try self.finishInsert(),
            else => return false,
        }
        return true;
    }

    fn handleInsertAlt(self: *HelixEngine, char: u21) !bool {
        switch (char) {
            'd' => try self.deleteWordForward(),
            '`' => {},
            else => return false,
        }
        return true;
    }

    fn commitUndoCheckpoint(self: *HelixEngine) !void {
        if (!self.insert_group) return;
        self.endUndoGroup();
        self.beginUndoGroup();
    }

    fn deleteWordBefore(self: *HelixEngine) !void {
        var text = try self.modelValue();
        defer text.deinit();
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        for (normalized) |selection| {
            const head = self.selectionCursor(selection);
            const offset = self.editor.model.getOffsetAt(head);
            const target_offset = wordMove(text.items, .{ .anchor = offset, .head = offset }, 1, .prev_start, false).from();
            const target = self.editor.model.getPositionAt(target_offset);
            if (target.equals(head)) continue;
            try edits.append(.{ .range = Range.fromPositions(target, head), .text = "" });
        }
        if (edits.items.len == 0) return;
        try self.applyEditBatch(edits.items, .cursor_start);
    }

    fn deleteWordForward(self: *HelixEngine) !void {
        var text = try self.modelValue();
        defer text.deinit();
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        for (normalized) |selection| {
            const head = self.selectionCursor(selection);
            const offset = self.editor.model.getOffsetAt(head);
            const target_offset = wordMove(text.items, .{ .anchor = offset, .head = offset }, 1, .next_end, false).upper();
            const target = self.editor.model.getPositionAt(target_offset);
            if (target.equals(head)) continue;
            try edits.append(.{ .range = Range.fromPositions(head, target), .text = "" });
        }
        if (edits.items.len == 0) return;
        try self.applyEditBatch(edits.items, .cursor_start);
    }

    fn deleteToLineStart(self: *HelixEngine) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        for (normalized) |selection| {
            const head = self.selectionCursor(selection);
            const start = Position.init(head.lineNumber, 1);
            if (start.equals(head)) continue;
            try edits.append(.{ .range = Range.fromPositions(start, head), .text = "" });
        }
        if (edits.items.len == 0) return;
        try self.applyEditBatch(edits.items, .cursor_start);
    }

    fn deleteToLineEnd(self: *HelixEngine) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        for (normalized) |selection| {
            const head = self.selectionCursor(selection);
            const end = self.lineEndPosition(head.lineNumber);
            if (end.equals(head)) continue;
            try edits.append(.{ .range = Range.fromPositions(head, end), .text = "" });
        }
        if (edits.items.len == 0) return;
        try self.applyEditBatch(edits.items, .cursor_start);
    }

    fn insertRegisterAt(self: *HelixEngine, name: u8) !void {
        const register = self.registers.get(name) orelse return;
        if (register.entries.items.len == 0) return;
        var text = ArrayList(u8).init(self.allocator);
        defer text.deinit();
        for (register.entries.items, 0..) |entry, index| {
            if (index > 0) try text.append('\n');
            try text.appendSlice(entry.text);
        }
        try self.editor.insertText(text.items);
    }

    fn repeatInsert(self: *HelixEngine, count: usize) !void {
        if (self.last_insert_text.items.len == 0) return;
        var text = ArrayList(u8).init(self.allocator);
        defer text.deinit();
        var remaining = @max(count, 1);
        while (remaining > 0) : (remaining -= 1) try text.appendSlice(self.last_insert_text.items);
        if (text.items.len == 0) return;

        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        for (normalized) |selection| {
            const position = self.selectionCursor(selection);
            try edits.append(.{ .range = Range.fromPositions(position, position), .text = text.items });
        }
        self.beginUndoGroup();
        defer self.endUndoGroup();
        try self.applyEditBatch(edits.items, .cursor_end);
    }

    // ------------------------------------------------------------------
    // Macros
    // ------------------------------------------------------------------

    fn toggleMacroRecording(self: *HelixEngine) !void {
        if (self.macro_recording) |_| {
            self.macro_recording = null;
            return;
        }
        const name = self.selected_register orelse self.last_macro orelse 0;
        self.selected_register = null;
        const index: usize = if (name >= 'a' and name <= 'z') name - 'a' else 0;
        if (self.macros[index]) |*list| {
            clearRecordedKeys(self.allocator, list);
        } else {
            self.macros[index] = ArrayList(RecordedKey).init(self.allocator);
        }
        self.macro_recording = index;
        self.last_macro = index;
    }

    fn replayMacro(self: *HelixEngine, count: usize) !void {
        const name = self.selected_register orelse self.last_macro orelse 0;
        self.selected_register = null;
        const index: usize = if (name >= 'a' and name <= 'z') name - 'a' else 0;
        const list = self.macros[index] orelse return;
        if (self.macro_depth >= 100) return;
        self.macro_depth += 1;
        defer self.macro_depth -= 1;
        self.replaying = true;
        defer self.replaying = false;
        var remaining = @max(count, 1);
        while (remaining > 0) : (remaining -= 1) {
            for (list.items) |recorded| {
                var event = KeyInputEvent{ .key = recorded.key, .mods = recorded.mods };
                _ = try self.dispatchKey(&event);
            }
        }
        self.last_macro = index;
    }

    fn recordMacroKey(self: *HelixEngine, event: *const KeyInputEvent) !void {
        const index = self.macro_recording orelse return;
        if (self.macros[index] == null) self.macros[index] = ArrayList(RecordedKey).init(self.allocator);
        var recorded = RecordedKey{ .key = event.key, .mods = event.mods };
        if (event.key == .text) {
            const copy = try self.allocator.dupe(u8, event.key.text);
            errdefer self.allocator.free(copy);
            recorded.key = .{ .text = copy };
        }
        try self.macros[index].?.append(recorded);
    }

    // ------------------------------------------------------------------
    // Search
    // ------------------------------------------------------------------

    fn matchCase(self: *HelixEngine, pattern: []const u8) bool {
        return switch (self.case_mode) {
            .sensitive => true,
            .ignore => false,
            .smart => containsUppercase(pattern),
        };
    }

    fn searchSelection(self: *HelixEngine, word_boundary: bool, raw_regex: bool, forward: bool) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        var pattern = ArrayList(u8).init(self.allocator);
        defer pattern.deinit();

        var selected_text: ?[]u8 = null;
        defer if (selected_text) |text| self.allocator.free(text);
        if (selections.len > 0 and !selections[0].isEmpty()) {
            selected_text = try self.rangeText(Range.init(
                selections[0].startLineNumber,
                selections[0].startColumn,
                selections[0].endLineNumber,
                selections[0].endColumn,
            ));
        }
        if (selected_text == null or selected_text.?.len == 0) {
            const head = if (selections.len > 0) selections[0].getPosition() else Position.init(1, 1);
            const content = try self.editor.model.getLineContent(head.lineNumber);
            defer content.deinit();
            const column = @min(head.column - 1, content.items.len);
            if (column >= content.items.len) return;
            const current = wordClassAt(content.items, column);
            if (current == 0) return;
            var start = column;
            while (start > 0 and wordClassAt(content.items, start - 1) == current) start -= 1;
            var end = column;
            while (end < content.items.len and wordClassAt(content.items, end) == current) end += 1;
            if (selected_text) |old| self.allocator.free(old);
            selected_text = try self.allocator.dupe(u8, content.items[start..end]);
        }
        const text = selected_text orelse return;
        if (raw_regex) {
            try pattern.appendSlice(text);
        } else if (word_boundary and text.len > 0 and isWordByte(text[0]) and isWordByte(text[text.len - 1])) {
            try pattern.appendSlice("\\b");
            try appendRegexEscaped(&pattern, text);
            try pattern.appendSlice("\\b");
        } else {
            try appendRegexEscaped(&pattern, text);
        }
        self.last_search.clearRetainingCapacity();
        try self.last_search.appendSlice(pattern.items);
        self.search_is_regex = true;
        self.search_forward = forward;
        self.last_search_match = null;
        try self.searchAgain(1, forward);
    }

    fn searchAgain(self: *HelixEngine, count: usize, forward: bool) !void {
        if (self.last_search.items.len == 0) return;
        const model = self.editor.model;
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const head = if (selections.len > 0) selections[0].getPosition() else Position.init(1, 1);
        var from = head;
        if (self.last_search_match) |last| {
            if (last.containsPosition(&head) or self.extendMode()) {
                from = if (forward) try self.positionAfter(last.endPosition()) else try self.positionBefore(last.startPosition());
            }
        }
        const match_case = self.matchCase(self.last_search.items);
        var found: ?Range = null;
        var remaining = @max(count, 1);
        while (remaining > 0) : (remaining -= 1) {
            var match = if (forward)
                try model.findNextMatch(self.last_search.items, from, self.search_is_regex, match_case, null, false)
            else
                try model.findPreviousMatch(self.last_search.items, from, self.search_is_regex, match_case, null, false);
            if (match == null) {
                const wrap = if (forward)
                    Position.init(1, 1)
                else
                    Position.init(model.getLineCount(), model.getLineMaxColumn(model.getLineCount()));
                match = if (forward)
                    try model.findNextMatch(self.last_search.items, wrap, self.search_is_regex, match_case, null, false)
                else
                    try model.findPreviousMatch(self.last_search.items, wrap, self.search_is_regex, match_case, null, false);
            }
            const found_match = match orelse return;
            found = found_match.range;
            if (forward) {
                const end = found_match.range.endPosition();
                const next = try self.positionAfter(end);
                from = if (next.equals(end)) Position.init(end.lineNumber, @min(end.column + 1, model.getLineMaxColumn(end.lineNumber))) else next;
            } else {
                const start = found_match.range.startPosition();
                const previous = try self.positionBefore(start);
                from = if (previous.equals(start)) start else previous;
            }
        }
        const range = found orelse return;
        self.last_search_match = range;
        if (self.extendMode()) {
            var combined = ArrayList(Selection).init(self.allocator);
            defer combined.deinit();
            try combined.appendSlice(selections);
            try combined.append(Selection.init(
                range.startLineNumber,
                range.startColumn,
                range.endLineNumber,
                range.endColumn,
            ));
            try self.setNormalizedSelections(combined.items);
        } else {
            try self.editor.setSelections(&[_]Selection{Selection.init(
                range.startLineNumber,
                range.startColumn,
                range.endLineNumber,
                range.endColumn,
            )});
        }
        self.editor.revealRange(range);
        try self.refreshSearchHighlights(self.last_search.items, range);
    }

    fn regexSelection(self: *HelixEngine, pattern: []const u8, split: bool) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        var result = ArrayList(Selection).init(self.allocator);
        defer result.deinit();
        const match_case = self.matchCase(pattern);
        const cap: usize = 10000;

        for (normalized) |selection| {
            const selection_start = selection.getStartPosition();
            const selection_end = selection.getEndPosition();
            const end_offset = self.editor.model.getOffsetAt(selection_end);
            var from = selection_start;
            var piece_offset = self.editor.model.getOffsetAt(selection_start);
            var found_any = false;
            while (result.items.len < cap) {
                const match = self.editor.model.findNextMatch(pattern, from, true, match_case, null, false) catch |err| {
                    var message_buffer: [128]u8 = undefined;
                    const message = std.fmt.bufPrint(&message_buffer, "Helix: {s}", .{@errorName(err)}) catch "Helix: error";
                    self.window.setMessage(message);
                    return;
                };
                const found_match = match orelse break;
                const match_start = self.editor.model.getOffsetAt(found_match.range.startPosition());
                const match_end = self.editor.model.getOffsetAt(found_match.range.endPosition());
                if (match_start > end_offset) break;
                if (match_end > end_offset) break;
                found_any = true;
                if (split) {
                    if (match_start > piece_offset) {
                        try result.append(Selection.init(
                            self.editor.model.getPositionAt(piece_offset).lineNumber,
                            self.editor.model.getPositionAt(piece_offset).column,
                            self.editor.model.getPositionAt(match_start).lineNumber,
                            self.editor.model.getPositionAt(match_start).column,
                        ));
                    }
                    piece_offset = match_end;
                } else {
                    try result.append(Selection.init(
                        found_match.range.startLineNumber,
                        found_match.range.startColumn,
                        found_match.range.endLineNumber,
                        found_match.range.endColumn,
                    ));
                }
                if (match_end == match_start) {
                    const next = try self.positionAfter(found_match.range.endPosition());
                    if (next.equals(found_match.range.endPosition())) break;
                    from = next;
                } else {
                    from = found_match.range.endPosition();
                }
                if (result.items.len >= cap) break;
            }
            if (split) {
                if (found_any and piece_offset < end_offset) {
                    const start_position = self.editor.model.getPositionAt(piece_offset);
                    try result.append(Selection.init(
                        start_position.lineNumber,
                        start_position.column,
                        selection_end.lineNumber,
                        selection_end.column,
                    ));
                }
                if (!found_any) try result.append(selection);
            }
        }

        if (result.items.len == 0) {
            self.window.setMessage("Helix: no matches");
            return;
        }
        try self.setNormalizedSelections(result.items);
    }

    // ------------------------------------------------------------------
    // Prompts and command line
    // ------------------------------------------------------------------

    fn finishPrompt(self: *HelixEngine) void {
        self.mode = if (self.prompt_select) .select else .normal;
        self.prompt_select = false;
        self.minor_select = false;
        self.count = 0;
        self.count_active = false;
    }

    fn handleCommandLine(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        switch (event.key) {
            .escape => {
                self.command_buffer.clearRetainingCapacity();
                self.finishPrompt();
            },
            .enter => {
                self.finishPrompt();
                try self.executeCommandLine();
            },
            .backspace => removeLastCodepoint(&self.command_buffer),
            .char => |char| {
                if (event.mods.ctrl) {
                    switch (char) {
                        'u' => self.command_buffer.clearRetainingCapacity(),
                        'w' => removeLastWord(&self.command_buffer),
                        else => {},
                    }
                    return true;
                }
                if (event.mods.alt) return true;
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(char, &buffer) catch return false;
                try self.command_buffer.appendSlice(buffer[0..len]);
            },
            .text => |text| try self.command_buffer.appendSlice(text),
            else => return false,
        }
        return true;
    }

    fn handleSearchInput(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        switch (event.key) {
            .escape => {
                self.search_buffer.clearRetainingCapacity();
                try self.restoreSearchOrigin();
                self.freeSearchOrigin();
                self.finishPrompt();
                // Helix restores the previous pattern's highlights; the
                // abandoned preview must not keep them.
                try self.refreshCommittedHighlight();
            },
            .enter => {
                const forward = self.mode == .search_forward;
                if (self.search_buffer.items.len > 0) {
                    self.last_search.clearRetainingCapacity();
                    try self.last_search.appendSlice(self.search_buffer.items);
                }
                self.finishPrompt();
                self.recordJump();
                self.last_search_match = null;
                // Commit from the prompt-start selections so searchAgain does
                // not skip the previewed match.
                try self.restoreSearchOrigin();
                self.freeSearchOrigin();
                try self.searchAgain(1, forward);
            },
            .backspace => {
                removeLastCodepoint(&self.search_buffer);
                try self.updateSearchPreview();
            },
            .char => |char| {
                if (event.mods.ctrl) {
                    switch (char) {
                        'u' => self.search_buffer.clearRetainingCapacity(),
                        'w' => removeLastWord(&self.search_buffer),
                        else => {},
                    }
                    try self.updateSearchPreview();
                    return true;
                }
                if (event.mods.alt) return true;
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(char, &buffer) catch return false;
                try self.search_buffer.appendSlice(buffer[0..len]);
                try self.updateSearchPreview();
            },
            .text => |text| {
                try self.search_buffer.appendSlice(text);
                try self.updateSearchPreview();
            },
            else => return false,
        }
        return true;
    }

    fn beginSearch(self: *HelixEngine, forward: bool) !void {
        self.freeSearchOrigin();
        self.search_origin = try self.getSelections();
        self.search_buffer.clearRetainingCapacity();
        self.prompt_select = self.extendMode();
        self.search_forward = forward;
        self.mode = if (forward) .search_forward else .search_backward;
    }

    fn freeSearchOrigin(self: *HelixEngine) void {
        if (self.search_origin) |origin| self.allocator.free(origin);
        self.search_origin = null;
    }

    fn restoreSearchOrigin(self: *HelixEngine) !void {
        const origin = self.search_origin orelse return;
        try self.setSelections(origin);
    }

    /// Helix previews search results live: every prompt edit moves the
    /// selection to the match (or, in select mode, extends to it) and
    /// highlights all matches with the find-match colors.
    fn updateSearchPreview(self: *HelixEngine) !void {
        const origin = self.search_origin orelse return;
        if (self.search_buffer.items.len == 0) {
            try self.setSelections(origin);
            try self.refreshCommittedHighlight();
            return;
        }

        const model = self.editor.model;
        const forward = self.mode == .search_forward;
        const pattern = self.search_buffer.items;
        const match_case = self.matchCase(pattern);
        const head = if (origin.len > 0) origin[0].getPosition() else Position.init(1, 1);

        var match = if (forward)
            try model.findNextMatch(pattern, head, self.search_is_regex, match_case, null, false)
        else
            try model.findPreviousMatch(pattern, head, self.search_is_regex, match_case, null, false);
        if (match == null) {
            const wrap = if (forward)
                Position.init(1, 1)
            else
                Position.init(model.getLineCount(), model.getLineMaxColumn(model.getLineCount()));
            match = if (forward)
                try model.findNextMatch(pattern, wrap, self.search_is_regex, match_case, null, false)
            else
                try model.findPreviousMatch(pattern, wrap, self.search_is_regex, match_case, null, false);
        }

        const found = match orelse {
            try self.setSelections(origin);
            self.editor.setSearchHighlights(&.{}, null);
            return;
        };

        const selection = Selection.init(
            found.range.startLineNumber,
            found.range.startColumn,
            found.range.endLineNumber,
            found.range.endColumn,
        );
        if (self.prompt_select) {
            var combined = ArrayList(Selection).init(self.allocator);
            defer combined.deinit();
            try combined.appendSlice(origin);
            try combined.append(selection);
            try self.setNormalizedSelections(combined.items);
        } else {
            try self.setSelections(&[_]Selection{selection});
        }
        self.editor.revealRange(found.range);
        try self.refreshSearchHighlights(pattern, found.range);
    }

    /// Repaints the highlights for the committed pattern and current match.
    fn refreshCommittedHighlight(self: *HelixEngine) !void {
        try self.refreshSearchHighlights(self.last_search.items, self.last_search_match);
    }

    /// Highlights every match of `pattern` with the find-match colors and
    /// `current` with the current-find-match color, exactly like Ctrl+F.
    fn refreshSearchHighlights(self: *HelixEngine, pattern: []const u8, current: ?Range) !void {
        if (pattern.len == 0) {
            self.editor.setSearchHighlights(&.{}, null);
            return;
        }

        var matches = try self.editor.model.findMatches(
            pattern,
            null,
            self.search_is_regex,
            self.matchCase(pattern),
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

    fn handleRegexInput(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        switch (event.key) {
            .escape => {
                self.regex_buffer.clearRetainingCapacity();
                self.finishPrompt();
            },
            .enter => {
                const split = self.mode == .split_regex;
                const pattern_copy = try self.allocator.dupe(u8, self.regex_buffer.items);
                defer self.allocator.free(pattern_copy);
                self.finishPrompt();
                if (pattern_copy.len > 0) try self.regexSelection(pattern_copy, split);
            },
            .backspace => removeLastCodepoint(&self.regex_buffer),
            .char => |char| {
                if (event.mods.ctrl) {
                    switch (char) {
                        'u' => self.regex_buffer.clearRetainingCapacity(),
                        'w' => removeLastWord(&self.regex_buffer),
                        else => {},
                    }
                    return true;
                }
                if (event.mods.alt) return true;
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(char, &buffer) catch return false;
                try self.regex_buffer.appendSlice(buffer[0..len]);
            },
            .text => |text| try self.regex_buffer.appendSlice(text),
            else => return false,
        }
        return true;
    }

    fn handleSurroundInput(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        switch (event.key) {
            .escape => {
                self.surround = null;
                self.finishMinor();
                return true;
            },
            .char => |char| {
                if (char > 0xFF) return true;
                try self.surroundChar(@intCast(char));
                return true;
            },
            .text => |text| {
                if (text.len > 0) try self.surroundChar(text[0]);
                return true;
            },
            else => return true,
        }
    }

    fn surroundChar(self: *HelixEngine, char: u8) !void {
        var state = self.surround orelse {
            self.finishMinor();
            return;
        };
        switch (state.kind) {
            .add, .delete => {
                self.surround = null;
                try self.applySurround(state.kind, char, 0);
                self.finishMinor();
            },
            .replace => {
                if (state.stage == 0) {
                    state.first = char;
                    state.stage = 1;
                    self.surround = state;
                } else {
                    self.surround = null;
                    try self.applySurround(.replace, state.first orelse char, char);
                    self.finishMinor();
                }
            },
        }
    }

    fn executeCommandLine(self: *HelixEngine) !void {
        const command = std.mem.trim(u8, self.command_buffer.items, " \t");
        if (command.len == 0) return;
        if (std.mem.eql(u8, command, "w")) {
            _ = try self.commands.execute("workbench.action.files.save");
        } else if (std.mem.eql(u8, command, "q")) {
            _ = try self.commands.execute("workbench.action.closeActiveEditor");
        } else if (std.mem.eql(u8, command, "q!")) {
            try self.window.forceCloseActive();
        } else if (std.mem.eql(u8, command, "wq") or std.mem.eql(u8, command, "x")) {
            _ = try self.commands.execute("workbench.action.files.save");
            _ = try self.commands.execute("workbench.action.closeActiveEditor");
        } else if (std.mem.eql(u8, command, "reload")) {
            _ = try self.commands.execute("workbench.action.files.revert");
        } else if (std.mem.eql(u8, command, "format")) {
            _ = try self.commands.execute("editor.action.formatDocument");
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
        } else if (std.mem.eql(u8, command, "noh")) {
            self.last_search.clearRetainingCapacity();
            self.last_search_match = null;
            self.editor.setSearchHighlights(&.{}, null);
        } else if (std.mem.eql(u8, command, "$")) {
            try self.gotoPosition(self.firstNonBlank(self.editor.model.getLineCount()), self.extendMode());
        } else if (std.mem.eql(u8, command, "set ignorecase")) {
            self.case_mode = .ignore;
        } else if (std.mem.eql(u8, command, "set noignorecase")) {
            self.case_mode = .sensitive;
        } else if (std.mem.eql(u8, command, "set smartcase")) {
            self.case_mode = .smart;
        } else if (std.mem.eql(u8, command, "set regex")) {
            self.search_is_regex = true;
        } else if (std.mem.eql(u8, command, "set noregex")) {
            self.search_is_regex = false;
        } else if (std.mem.startsWith(u8, command, "e ")) {
            try self.window.openPath(std.mem.trim(u8, command[2..], " "));
        } else if (std.fmt.parseInt(usize, command, 10)) |line| {
            try self.gotoPosition(self.firstNonBlank(@min(line, self.editor.model.getLineCount())), self.extendMode());
        } else |_| {
            self.window.setMessage("Helix: unsupported command");
        }
    }

    // ------------------------------------------------------------------
    // Minor modes
    // ------------------------------------------------------------------

    fn finishMinor(self: *HelixEngine) void {
        self.mode = if (self.minor_select) .select else .normal;
        self.minor_select = false;
        self.pending_text_object = null;
        self.count = 0;
        self.count_active = false;
    }

    fn handleGotoKey(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        switch (event.key) {
            .escape => self.finishMinor(),
            .char => |char| try self.handleGotoChar(char),
            .text => |text| {
                var view = std.unicode.Utf8View.init(text) catch return true;
                var iterator = view.iterator();
                if (iterator.nextCodepoint()) |char| try self.handleGotoChar(char);
            },
            else => self.finishMinor(),
        }
        return true;
    }

    fn handleGotoChar(self: *HelixEngine, char: u21) !void {
        const extend = self.extendMode();
        const head = self.primaryHead();
        switch (char) {
            'g' => {
                if (self.count_active) {
                    const line = @min(self.takeCount(), self.editor.model.getLineCount());
                    try self.gotoPosition(Position.init(line, 1), extend);
                } else {
                    self.recordJump();
                    try self.gotoPosition(Position.init(1, 1), extend);
                }
            },
            'e' => {
                self.recordJump();
                try self.gotoPosition(Position.init(self.editor.model.getLineCount(), 1), extend);
            },
            'h' => try self.gotoPosition(Position.init(head.lineNumber, 1), extend),
            'l' => try self.gotoPosition(self.lineEndPosition(head.lineNumber), extend),
            's' => try self.gotoPosition(self.firstNonBlank(head.lineNumber), extend),
            't' => try self.gotoPosition(try self.viewportTarget(.top), extend),
            'c' => try self.gotoPosition(try self.viewportTarget(.middle), extend),
            'b' => try self.gotoPosition(try self.viewportTarget(.bottom), extend),
            'j' => try self.lineDown(extend, self.takeCount()),
            'k' => try self.lineUp(extend, self.takeCount()),
            'd' => try self.execute("editor.action.revealDefinition"),
            'D' => try self.execute("editor.action.revealDeclaration"),
            'y' => try self.execute("editor.action.goToTypeDefinition"),
            'r' => try self.execute("editor.action.goToReferences"),
            'i' => try self.execute("editor.action.goToImplementation"),
            'f' => try self.gotoFileUnderCursor(),
            'n' => try self.window.switchTab(1),
            'p' => try self.window.switchTab(-1),
            'v' => {
                if (self.last_selections.items.len > 0) try self.setNormalizedSelections(self.last_selections.items);
            },
            '|' => {
                const column = self.takeCount();
                try self.gotoPosition(Position.init(head.lineNumber, @min(column, self.lineMaxColumn(head.lineNumber))), extend);
            },
            else => {},
        }
        self.finishMinor();
    }

    fn handleMatchKey(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        if (self.pending_text_object) |around| {
            switch (event.key) {
                .escape => {
                    self.pending_text_object = null;
                    self.finishMinor();
                },
                .char => |char| {
                    self.pending_text_object = null;
                    try self.selectTextObject(around, char);
                    self.finishMinor();
                },
                .text => |text| {
                    self.pending_text_object = null;
                    var view = std.unicode.Utf8View.init(text) catch return true;
                    var iterator = view.iterator();
                    if (iterator.nextCodepoint()) |char| try self.selectTextObject(around, char);
                    self.finishMinor();
                },
                else => {
                    self.pending_text_object = null;
                    self.finishMinor();
                },
            }
            return true;
        }

        switch (event.key) {
            .escape => self.finishMinor(),
            .char => |char| {
                switch (char) {
                    'm' => {
                        try self.matchBracket();
                        self.finishMinor();
                    },
                    's', 'd', 'r' => {
                        const kind: SurroundKind = if (char == 's') .add else if (char == 'd') .delete else .replace;
                        self.surround = .{ .kind = kind };
                        self.mode = switch (kind) {
                            .add => .surround_add,
                            .delete => .surround_delete,
                            .replace => .surround_replace,
                        };
                    },
                    'a' => self.pending_text_object = true,
                    'i' => self.pending_text_object = false,
                    else => self.finishMinor(),
                }
            },
            .text => |text| {
                var view = std.unicode.Utf8View.init(text) catch return true;
                var iterator = view.iterator();
                // `ma`/`mi` and the object key can arrive in one text run.
                var remaining: usize = 2;
                while (remaining > 0 and self.mode == .match_mode) : (remaining -= 1) {
                    const char = iterator.nextCodepoint() orelse break;
                    var char_event = KeyInputEvent{ .key = .{ .char = char } };
                    _ = try self.handleMatchKey(&char_event);
                }
            },
            else => self.finishMinor(),
        }
        return true;
    }

    fn selectTextObject(self: *HelixEngine, around: bool, char: u21) !void {
        switch (char) {
            'w', 'W', 'p', 'm', '(', ')', '[', ']', '{', '}', '<', '>', '"', '\'', '`' => {},
            'f', 't', 'a', 'c', 'T', 'g', 'x' => {
                self.window.setMessage("Helix: tree-sitter text object unavailable");
                return;
            },
            else => return,
        }

        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);

        const updated = try self.allocator.alloc(Selection, normalized.len);
        defer self.allocator.free(updated);
        var found = false;
        for (normalized, 0..) |selection, index| {
            const cursor = self.selectionCursor(selection);
            const range = try self.textObjectRange(around, char, cursor) orelse {
                updated[index] = selection;
                continue;
            };
            updated[index] = Selection.init(range.startLineNumber, range.startColumn, range.endLineNumber, range.endColumn);
            found = true;
        }
        if (found) try self.setNormalizedSelections(updated);
    }

    fn textObjectRange(self: *HelixEngine, around: bool, char: u21, cursor: Position) !?Range {
        return switch (char) {
            'w' => try self.wordObject(around, false, cursor),
            'W' => try self.wordObject(around, true, cursor),
            'p' => try self.paragraphObject(around, cursor),
            '(' => try self.bracketObject(around, "(", ")", cursor),
            ')' => try self.bracketObject(around, "(", ")", cursor),
            '[' => try self.bracketObject(around, "[", "]", cursor),
            ']' => try self.bracketObject(around, "[", "]", cursor),
            '{' => try self.bracketObject(around, "{", "}", cursor),
            '}' => try self.bracketObject(around, "{", "}", cursor),
            '<' => try self.bracketObject(around, "<", ">", cursor),
            '>' => try self.bracketObject(around, "<", ">", cursor),
            '"', '\'', '`' => try self.quoteObject(around, @intCast(char), cursor),
            'm' => try self.closestSurround(around, cursor),
            else => null,
        };
    }

    fn wordObject(self: *HelixEngine, around: bool, big: bool, cursor: Position) !?Range {
        var value = try self.modelValue();
        defer value.deinit();
        const text = value.items;
        if (text.len == 0) return null;
        const pos = @min(self.editor.model.getOffsetAt(cursor), text.len);

        // Port of helix-core `textobject::textobject_word`.
        const word_start = findWordBoundary(text, pos, .backward, big);
        const word_end = blk: {
            if (pos >= text.len) break :blk pos;
            const ch = codepointAt(text, pos) orelse break :blk pos;
            const category = categoryOf(ch);
            if (category == .whitespace or category == .eol) break :blk pos;
            break :blk findWordBoundary(text, nextCharOffset(text, pos), .forward, big);
        };
        if (word_start == word_end) {
            return Range.fromPositions(self.editor.model.getPositionAt(word_start), self.editor.model.getPositionAt(word_end));
        }
        if (!around) {
            return Range.fromPositions(self.editor.model.getPositionAt(word_start), self.editor.model.getPositionAt(word_end));
        }

        var trailing: usize = word_end;
        while (trailing < text.len) {
            const ch = codepointAt(text, trailing) orelse break;
            if (isLineEndingCp(ch) or !isWhitespaceCp(ch)) break;
            trailing = nextCharOffset(text, trailing);
        }
        if (trailing > word_end) {
            return Range.fromPositions(self.editor.model.getPositionAt(word_start), self.editor.model.getPositionAt(trailing));
        }
        var leading = word_start;
        while (leading > 0) {
            const start = prevCodepointOffset(text, leading);
            const ch = codepointAt(text, start) orelse break;
            if (isLineEndingCp(ch) or !isWhitespaceCp(ch)) break;
            leading = start;
        }
        return Range.fromPositions(self.editor.model.getPositionAt(leading), self.editor.model.getPositionAt(word_end));
    }

    const BoundaryDirection = enum { forward, backward };

    /// Port of helix-core `textobject::find_word_boundary`.
    fn findWordBoundary(text: []const u8, start: usize, direction: BoundaryDirection, big: bool) usize {
        var pos = @min(start, text.len);
        var previous_category: CharCategory = switch (direction) {
            .forward => if (pos == 0) .whitespace else blk: {
                const ch = codepointAt(text, prevCodepointOffset(text, pos)) orelse break :blk .whitespace;
                break :blk categoryOf(ch);
            },
            .backward => if (pos == text.len) .whitespace else blk: {
                const ch = codepointAt(text, pos) orelse break :blk .whitespace;
                break :blk categoryOf(ch);
            },
        };
        while (true) {
            if (direction == .forward) {
                if (pos >= text.len) return pos;
                const ch = codepointAt(text, pos) orelse return pos;
                const category = categoryOf(ch);
                if (category == .eol or category == .whitespace) return pos;
                if (!big and category != previous_category and pos != 0 and pos != text.len) return pos;
                pos = nextCharOffset(text, pos);
                previous_category = category;
            } else {
                if (pos == 0) return pos;
                const next_pos = prevCodepointOffset(text, pos);
                const ch = codepointAt(text, next_pos) orelse return pos;
                const category = categoryOf(ch);
                if (category == .eol or category == .whitespace) return pos;
                if (!big and category != previous_category and pos != 0 and pos != text.len) return pos;
                pos = next_pos;
                previous_category = category;
            }
        }
    }

    fn paragraphObject(self: *HelixEngine, around: bool, cursor: Position) !?Range {
        const line_count = self.editor.model.getLineCount();
        const current = @min(cursor.lineNumber, line_count);
        const blank = try self.isBlankLine(current);
        var start = current;
        while (start > 1 and (try self.isBlankLine(start - 1)) == blank) start -= 1;
        var end = current;
        while (end < line_count and (try self.isBlankLine(end + 1)) == blank) end += 1;

        if (around and !blank) {
            var extra = end;
            while (extra < line_count and (try self.isBlankLine(extra + 1))) extra += 1;
            if (extra > end) {
                end = extra;
            } else {
                while (start > 1 and (try self.isBlankLine(start - 1))) start -= 1;
            }
        }

        if (around and end < line_count) {
            return Range.init(start, 1, end + 1, 1);
        }
        return Range.init(start, 1, end, self.lineMaxColumn(end));
    }

    fn isBlankLine(self: *HelixEngine, line: usize) !bool {
        const content = try self.editor.model.getLineContent(line);
        defer content.deinit();
        for (content.items) |byte| {
            if (byte != ' ' and byte != '\t') return false;
        }
        return true;
    }

    fn bracketObject(self: *HelixEngine, around: bool, open_text: []const u8, close_text: []const u8, cursor: Position) !?Range {
        const pair = try bracket_text_objects.ofType(self.editor.model, cursor, open_text, close_text) orelse return null;
        return if (around) pair.around() else pair.inside();
    }

    fn quoteObject(self: *HelixEngine, around: bool, quote: u8, cursor: Position) !?Range {
        const content = try self.editor.model.getLineContent(cursor.lineNumber);
        defer content.deinit();
        if (content.items.len == 0) return null;
        const position = @min(cursor.column -| 1, content.items.len - 1);

        var open_index: ?usize = null;
        var close_index: ?usize = null;
        if (content.items[position] == quote and !isEscaped(content.items, position)) {
            var index = position;
            while (index > 0) {
                index -= 1;
                if (content.items[index] == quote and !isEscaped(content.items, index)) {
                    open_index = index;
                    close_index = position;
                    break;
                }
            }
            if (open_index == null) {
                index = position + 1;
                while (index < content.items.len) : (index += 1) {
                    if (content.items[index] == quote and !isEscaped(content.items, index)) {
                        open_index = position;
                        close_index = index;
                        break;
                    }
                }
            }
        } else {
            var index = position;
            while (index > 0) {
                index -= 1;
                if (content.items[index] == quote and !isEscaped(content.items, index)) {
                    open_index = index;
                    break;
                }
            }
            const start = open_index orelse return null;
            index = start + 1;
            while (index < content.items.len) : (index += 1) {
                if (content.items[index] == quote and !isEscaped(content.items, index)) {
                    close_index = index;
                    break;
                }
            }
        }
        const start = open_index orelse return null;
        const end = close_index orelse return null;
        const start_offset = if (around) start else start + 1;
        const end_offset = if (around) end + 1 else end;
        return Range.fromPositions(
            Position.init(cursor.lineNumber, start_offset + 1),
            Position.init(cursor.lineNumber, end_offset + 1),
        );
    }

    fn closestSurround(self: *HelixEngine, around: bool, cursor: Position) !?Range {
        var best_outer: ?Range = null;
        var best_inner: ?Range = null;
        var best_span: usize = std.math.maxInt(usize);

        if (bracket_text_objects.closest(self.editor.model, cursor)) |pair| {
            const outer_range = pair.around();
            if (outer_range.containsPosition(&cursor)) {
                best_outer = outer_range;
                best_inner = pair.inside();
                best_span = self.editor.model.getOffsetAt(outer_range.getEndPosition()) -
                    self.editor.model.getOffsetAt(outer_range.getStartPosition());
            }
        }

        const quote_chars = [_]u8{ '"', '\'', '`' };
        for (quote_chars) |quote| {
            const outer_range = try self.quoteObject(true, quote, cursor) orelse continue;
            if (!outer_range.containsPosition(&cursor)) continue;
            const span = self.editor.model.getOffsetAt(outer_range.getEndPosition()) -
                self.editor.model.getOffsetAt(outer_range.getStartPosition());
            if (span >= best_span) continue;
            const inner = try self.quoteObject(false, quote, cursor) orelse continue;
            best_outer = outer_range;
            best_inner = inner;
            best_span = span;
        }
        return if (around) best_outer else best_inner;
    }

    fn handleViewKey(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        switch (event.key) {
            .escape => self.finishMinor(),
            .char => |char| {
                if (event.mods.ctrl) {
                    switch (char) {
                        'd' => try self.halfPage(true, self.extendMode()),
                        'u' => try self.halfPage(false, self.extendMode()),
                        'f' => try self.page(true, self.extendMode()),
                        'b' => try self.page(false, self.extendMode()),
                        else => {},
                    }
                } else {
                    switch (char) {
                        'z', 'c' => self.alignView(.center),
                        't' => self.alignView(.top),
                        'b' => self.alignView(.bottom),
                        'j' => _ = self.editor.scrollViewLines(1),
                        'k' => _ = self.editor.scrollViewLines(-1),
                        'm' => {},
                        else => {},
                    }
                }
                self.finishMinor();
            },
            .text => |text| {
                if (text.len > 0) {
                    var char_event = KeyInputEvent{ .key = .{ .char = text[0] } };
                    _ = try self.handleViewKey(&char_event);
                }
            },
            else => self.finishMinor(),
        }
        return true;
    }

    fn handleWindowKey(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        switch (event.key) {
            .escape => self.finishMinor(),
            .char => |char| {
                switch (char) {
                    'w', 'W' => _ = try self.commands.execute("workbench.action.navigateEditorGroups"),
                    'v' => _ = try self.commands.execute("workbench.action.splitEditorOrthogonal"),
                    's' => _ = try self.commands.execute("workbench.action.splitEditor"),
                    'h' => _ = try self.commands.execute("workbench.action.navigateLeft"),
                    'l' => _ = try self.commands.execute("workbench.action.navigateRight"),
                    'j' => _ = try self.commands.execute("workbench.action.navigateDown"),
                    'k' => _ = try self.commands.execute("workbench.action.navigateUp"),
                    'q', 'c' => _ = try self.commands.execute("workbench.action.closeActiveEditor"),
                    'o' => _ = try self.commands.execute("workbench.action.closeOtherEditors"),
                    '=' => _ = try self.commands.execute("workbench.action.evenEditorWidths"),
                    else => {},
                }
                self.finishMinor();
            },
            .text => |text| {
                if (text.len > 0) {
                    var char_event = KeyInputEvent{ .key = .{ .char = text[0] } };
                    _ = try self.handleWindowKey(&char_event);
                }
            },
            else => self.finishMinor(),
        }
        return true;
    }

    fn handleSpaceKey(self: *HelixEngine, event: *const KeyInputEvent) !bool {
        switch (event.key) {
            .escape => self.finishMinor(),
            .char => |char| {
                switch (char) {
                    'f', 'F' => _ = try self.commands.execute("workbench.action.quickOpen"),
                    'b' => _ = try self.commands.execute("workbench.action.quickOpen"),
                    'e' => _ = try self.commands.execute("workbench.view.explorer"),
                    's', 'S' => _ = try self.commands.execute("workbench.action.gotoSymbol"),
                    '/' => _ = try self.commands.execute("workbench.action.findInFiles"),
                    'd' => _ = try self.commands.execute("workbench.panel.markers"),
                    'k' => _ = try self.commands.execute("editor.action.showHover"),
                    'h' => _ = try self.commands.execute("editor.action.findReferences"),
                    'c' => try self.toggleComments(),
                    'C' => try self.toggleBlockComments(),
                    '?' => _ = try self.commands.execute("workbench.action.showCommands"),
                    'w' => {
                        self.minor_select = self.extendMode();
                        self.mode = .window_mode;
                        return true;
                    },
                    else => {},
                }
                self.finishMinor();
            },
            .text => |text| {
                if (text.len > 0) {
                    var char_event = KeyInputEvent{ .key = .{ .char = text[0] } };
                    _ = try self.handleSpaceKey(&char_event);
                }
            },
            else => self.finishMinor(),
        }
        return true;
    }

    fn execute(self: *HelixEngine, id: []const u8) !void {
        self.recordJump();
        _ = try self.commands.execute(id);
    }

    fn alignView(self: *HelixEngine, where: enum { center, top, bottom }) void {
        const height = self.editor.textHeight();
        const cursor_view = self.editor.cursorViewLine();
        const max_top = @max(1, self.editor.viewLineCount() -| height + 1);
        const top = switch (where) {
            .center => if (cursor_view > height / 2) cursor_view - height / 2 else 1,
            .top => cursor_view,
            .bottom => cursor_view -| (height -| 1),
        };
        _ = self.editor.setTopViewLine(@min(top, max_top));
    }

    fn viewportTarget(self: *HelixEngine, where: enum { top, middle, bottom }) !Position {
        const height = self.editor.textHeight();
        const top = self.editor.topViewLine();
        const target_view = switch (where) {
            .top => top,
            .middle => @min(top + height / 2, self.editor.viewLineCount()),
            .bottom => @min(top + height -| 1, self.editor.viewLineCount()),
        };
        const line = @min(self.editor.modelLineNumber(target_view), self.editor.model.getLineCount());
        return self.firstNonBlank(line);
    }

    // ------------------------------------------------------------------
    // Line-oriented edits and selection filters
    // ------------------------------------------------------------------

    fn lineSelections(self: *HelixEngine, selections: []const Selection) ![]Selection {
        const result = try self.allocator.alloc(Selection, selections.len);
        errdefer self.allocator.free(result);
        for (selections, 0..) |selection, index| {
            const range = try self.lineBoundsRange(selection, false);
            result[index] = Selection.init(range.startLineNumber, range.startColumn, range.endLineNumber, range.endColumn);
        }
        return result;
    }

    fn indentSelections(self: *HelixEngine, indent: bool, count: usize) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);
        const line_selections = try self.lineSelections(normalized);
        defer self.allocator.free(line_selections);

        self.beginUndoGroup();
        defer self.endUndoGroup();
        try self.setSelections(line_selections);
        var remaining = @max(count, 1);
        while (remaining > 0) : (remaining -= 1) {
            if (indent) try self.editor.indentLines() else try self.editor.outdentLines();
        }
        const updated = try self.allocator.alloc(Selection, normalized.len);
        defer self.allocator.free(updated);
        for (normalized, 0..) |selection, index| {
            const start_line = selection.startLineNumber;
            const end_line = selection.endLineNumber;
            updated[index] = Selection.init(start_line, 1, end_line, self.lineMaxColumn(end_line));
        }
        try self.setNormalizedSelections(updated);
    }

    fn formatSelections(self: *HelixEngine) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);
        const line_selections = try self.lineSelections(normalized);
        defer self.allocator.free(line_selections);

        self.beginUndoGroup();
        defer self.endUndoGroup();
        try self.setSelections(line_selections);
        const ok = try self.commands.execute("editor.action.formatSelection");
        if (!ok) {
            _ = try self.commands.execute("editor.action.formatDocument");
        }
        const updated = try self.allocator.alloc(Selection, normalized.len);
        defer self.allocator.free(updated);
        for (normalized, 0..) |selection, index| {
            const start_line = selection.startLineNumber;
            const end_line = selection.endLineNumber;
            updated[index] = Selection.init(start_line, 1, end_line, self.lineMaxColumn(end_line));
        }
        try self.setNormalizedSelections(updated);
    }

    fn toggleComments(self: *HelixEngine) !void {
        try self.applyLineCommand("editor.action.commentLine");
    }

    fn toggleBlockComments(self: *HelixEngine) !void {
        try self.applyLineCommand("editor.action.blockComment");
    }

    fn applyLineCommand(self: *HelixEngine, command: []const u8) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);
        const line_selections = try self.lineSelections(normalized);
        defer self.allocator.free(line_selections);

        self.beginUndoGroup();
        defer self.endUndoGroup();
        try self.setSelections(line_selections);
        _ = try self.commands.execute(command);
        const updated = try self.allocator.alloc(Selection, normalized.len);
        defer self.allocator.free(updated);
        for (normalized, 0..) |selection, index| {
            const start_line = selection.startLineNumber;
            const end_line = selection.endLineNumber;
            updated[index] = Selection.init(start_line, 1, end_line, self.lineMaxColumn(end_line));
        }
        try self.setNormalizedSelections(updated);
    }

    fn joinSelections(self: *HelixEngine, select_space: bool) !void {
        var text_value = try self.modelValue();
        defer text_value.deinit();
        const text = text_value.items;
        const line_count = self.editor.model.getLineCount();
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);

        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        var changes = ArrayList(helixSelection.Change).init(self.allocator);
        defer changes.deinit();
        for (normalized) |selection| {
            const range = self.selectionRange(selection);
            const start_line = self.lineOfOffset(text, range.from());
            var end_line = self.lineOfOffset(text, if (range.isEmpty()) range.upper() else helixSelection.prevGraphemeBoundary(text, range.upper()));
            if (start_line == end_line) {
                end_line = @min(end_line + 1, line_count);
            }
            var line = start_line;
            while (line < end_line) : (line += 1) {
                const seg_start = self.lineEndOffset(line);
                var seg_end = self.lineStartOffset(line + 1);
                while (seg_end < text.len and (text[seg_end] == ' ' or text[seg_end] == '\t')) seg_end += 1;
                const separator: []const u8 = if (seg_end == self.lineEndOffset(line + 1)) "" else " ";
                try edits.append(.{
                    .range = Range.fromPositions(
                        self.editor.model.getPositionAt(seg_start),
                        self.editor.model.getPositionAt(seg_end),
                    ),
                    .text = separator,
                });
                try changes.append(.{ .start = seg_start, .end = seg_end, .inserted_len = separator.len });
            }
        }
        if (edits.items.len == 0) return;

        self.beginUndoGroup();
        defer self.endUndoGroup();
        try self.applyEditBatch(edits.items, .cursor_start);

        // Map the join selection through the changes like Helix's `doc.apply`.
        var after = try self.modelValue();
        defer after.deinit();
        const mapped = try self.allocator.alloc(Selection, normalized.len);
        defer self.allocator.free(mapped);
        for (normalized, 0..) |selection, index| {
            var mapped_range = helixSelection.mapRange(changes.items, self.selectionRange(selection));
            if (select_space) {
                // Helix `join_selections_space` selects the inserted spaces.
                for (changes.items) |change| {
                    if (change.inserted_len == 1 and change.start >= mapped_range.from() and change.start < mapped_range.upper()) {
                        mapped_range = .{ .anchor = change.start, .head = change.start + 1 };
                        break;
                    }
                }
            }
            mapped[index] = self.selectionFromRange(helixSelection.ensureInvariants(after.items, mapped_range));
        }
        try self.setNormalizedSelections(mapped);
    }

    /// Offset of the newline ending a 1-based line (or the content end for the
    /// last line without a line ending); Helix `line_end_char_index`.
    fn lineEndOffset(self: *HelixEngine, line: usize) usize {
        return self.lineStartOffset(line) + (self.lineMaxColumn(line) - 1);
    }

    const Number = struct { start: usize, end: usize, value: i64 };

    fn findNumber(text: []const u8, start: usize) ?Number {
        var index = start;
        while (index < text.len) : (index += 1) {
            const byte = text[index];
            const begins_number = if (byte == '-')
                index + 1 < text.len and std.ascii.isDigit(text[index + 1])
            else
                std.ascii.isDigit(byte);
            if (!begins_number) continue;
            const begin = index;
            if (byte == '-') index += 1;
            while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
            const value = std.fmt.parseInt(i64, text[begin..index], 10) catch return null;
            return .{ .start = begin, .end = index, .value = value };
        }
        return null;
    }

    fn incrementNumbers(self: *HelixEngine, delta: i64, count: usize) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);

        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        var owned = ArrayList([]u8).init(self.allocator);
        defer {
            for (owned.items) |text| self.allocator.free(text);
            owned.deinit();
        }
        const amount = delta * @as(i64, @intCast(@max(count, 1)));
        for (normalized) |selection| {
            var range = try self.effectiveRange(selection);
            var number: ?Number = null;
            if (!range.isEmpty()) {
                const text = try self.rangeText(range);
                defer self.allocator.free(text);
                number = findNumber(text, 0);
            }
            if (number == null) {
                const head = selection.getPosition();
                const content = try self.editor.model.getLineContent(head.lineNumber);
                defer content.deinit();
                if (findNumber(content.items, @min(head.column - 1, content.items.len))) |found| {
                    number = found;
                    range = Range.init(
                        head.lineNumber,
                        found.start + 1,
                        head.lineNumber,
                        found.end + 1,
                    );
                }
            }
            const found = number orelse continue;
            var buffer: [64]u8 = undefined;
            const replacement = std.fmt.bufPrint(&buffer, "{d}", .{found.value + amount}) catch continue;
            const copy = try self.allocator.dupe(u8, replacement);
            try owned.append(copy);
            try edits.append(.{ .range = range, .text = copy });
        }
        if (edits.items.len == 0) return;
        self.beginUndoGroup();
        defer self.endUndoGroup();
        try self.applyEditBatch(edits.items, .inserted_range);
    }

    fn copySelection(self: *HelixEngine, down: bool) !void {
        // Helix `copy_selection_on_line`: add selections on adjacent lines at
        // the same visual columns. It never edits text.
        var text_value = try self.modelValue();
        defer text_value.deinit();
        const text = text_value.items;
        const line_count = self.editor.model.getLineCount();
        const count = @max(self.takeCount(), 1);
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);

        var result = ArrayList(Selection).init(self.allocator);
        defer result.deinit();
        try result.ensureTotalCapacity(normalized.len * (count + 1));
        try result.appendSlice(normalized);
        var primary_index: usize = 0;
        var primary_selection: Selection = if (normalized.len > 0) normalized[0] else Selection.init(1, 1, 1, 1);
        for (normalized, 0..) |selection, selection_index| {
            const range = self.selectionRange(selection);
            // Helix treats the range head as exclusive for this command.
            const head = if (range.anchor < range.head)
                helixSelection.prevGraphemeBoundary(text, range.head)
            else
                range.head;
            const anchor = if (range.anchor < range.head)
                range.anchor
            else
                helixSelection.prevGraphemeBoundary(text, range.anchor);
            const head_position = self.editor.model.getPositionAt(head);
            const anchor_position = self.editor.model.getPositionAt(anchor);
            const height = @max(head_position.lineNumber, anchor_position.lineNumber) -
                @min(head_position.lineNumber, anchor_position.lineNumber) + 1;
            if (selection_index == 0) primary_index = result.items.len;
            try result.append(selection);

            var copies: usize = 0;
            var i: usize = 0;
            while (copies < count and i < line_count * 2 + 1) : (i += 1) {
                const offset = (i + 1) * height;
                const anchor_line = if (down)
                    anchor_position.lineNumber + offset
                else
                    anchor_position.lineNumber -| offset;
                const head_line = if (down)
                    head_position.lineNumber + offset
                else
                    head_position.lineNumber -| offset;
                if (anchor_line == 0 or head_line == 0) break;
                if (anchor_line > line_count or head_line > line_count) break;
                // Helix skips lines that are too short.
                if (anchor_position.column > self.lineMaxColumn(anchor_line) or
                    head_position.column > self.lineMaxColumn(head_line))
                {
                    continue;
                }
                const anchor_offset = self.editor.model.getOffsetAt(Position.init(anchor_line, anchor_position.column));
                const head_offset = self.editor.model.getOffsetAt(Position.init(head_line, head_position.column));
                const copied = helixSelection.putCursor(text, helixSelection.Range.point(anchor_offset), head_offset, true);
                if (selection_index == 0) {
                    primary_index = result.items.len;
                    primary_selection = self.selectionFromRange(helixSelection.ensureInvariants(text, copied));
                }
                try result.append(self.selectionFromRange(helixSelection.ensureInvariants(text, copied)));
                copies += 1;
            }
        }
        // Helix normalizes the new selection set (the duplicated originals
        // merge) and keeps the copy of the primary range primary.
        const normalized_result = try self.normalizeSelections(result.items);
        defer self.allocator.free(normalized_result);
        if (normalized_result.len > 1) {
            for (normalized_result, 0..) |candidate, index| {
                if (index == 0) continue;
                if (candidate.selectionStartLineNumber == primary_selection.selectionStartLineNumber and
                    candidate.selectionStartColumn == primary_selection.selectionStartColumn and
                    candidate.positionLineNumber == primary_selection.positionLineNumber and
                    candidate.positionColumn == primary_selection.positionColumn)
                {
                    const primary = normalized_result[index];
                    std.mem.copyBackwards(Selection, normalized_result[1 .. index + 1], normalized_result[0..index]);
                    normalized_result[0] = primary;
                    break;
                }
            }
        }
        try self.setSelections(normalized_result);
    }

    fn splitSelectionsOnNewlines(self: *HelixEngine) !void {
        var text_value = try self.modelValue();
        defer text_value.deinit();
        const text = text_value.items;
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);

        var result = ArrayList(Selection).init(self.allocator);
        defer result.deinit();
        for (normalized) |selection| {
            const range = self.selectionRange(selection);
            if (range.isEmpty()) {
                try result.append(selection);
                continue;
            }
            const sel_start = range.from();
            const sel_end = range.upper();
            var start = sel_start;
            while (start < sel_end) {
                const newline = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse break;
                if (newline >= sel_end) break;
                try result.append(self.selectionFromRange(.{ .anchor = start, .head = newline }));
                start = newline + 1;
            }
            if (start < sel_end) {
                try result.append(self.selectionFromRange(.{ .anchor = start, .head = sel_end }));
            }
        }
        try self.setNormalizedSelections(result.items);
    }

    fn trimSelections(self: *HelixEngine) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        var owned = ArrayList([]u8).init(self.allocator);
        defer {
            for (owned.items) |text| self.allocator.free(text);
            owned.deinit();
        }
        for (normalized) |selection| {
            const range = try self.effectiveRange(selection);
            const text = try self.rangeText(range);
            defer self.allocator.free(text);
            const trimmed = try trimSelectionText(self.allocator, text);
            defer self.allocator.free(trimmed);
            if (std.mem.eql(u8, trimmed, text)) continue;
            const copy = try self.allocator.dupe(u8, trimmed);
            try owned.append(copy);
            try edits.append(.{ .range = range, .text = copy });
        }
        if (edits.items.len == 0) return;
        self.beginUndoGroup();
        defer self.endUndoGroup();
        try self.applyEditBatch(edits.items, .inserted_range);
    }

    fn mergeSelections(self: *HelixEngine, consecutive_only: bool) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        if (normalized.len <= 1) return;
        if (!consecutive_only) {
            var start = normalized[0].getStartPosition();
            var end = normalized[0].getEndPosition();
            for (normalized[1..]) |selection| {
                if (selection.getStartPosition().isBefore(start)) start = selection.getStartPosition();
                if (end.isBefore(selection.getEndPosition())) end = selection.getEndPosition();
            }
            try self.setNormalizedSelections(&[_]Selection{Selection.init(start.lineNumber, start.column, end.lineNumber, end.column)});
            return;
        }
        var result = ArrayList(Selection).init(self.allocator);
        defer result.deinit();
        var current = normalized[0];
        for (normalized[1..]) |selection| {
            const current_end = self.editor.model.getOffsetAt(current.getEndPosition());
            const next_start = self.editor.model.getOffsetAt(selection.getStartPosition());
            if (next_start <= current_end) {
                const end = if (current.getEndPosition().isBefore(selection.getEndPosition())) selection.getEndPosition() else current.getEndPosition();
                current = Selection.init(current.getStartPosition().lineNumber, current.getStartPosition().column, end.lineNumber, end.column);
            } else {
                try result.append(current);
                current = selection;
            }
        }
        try result.append(current);
        try self.setNormalizedSelections(result.items);
    }

    fn matchBracket(self: *HelixEngine) !void {
        const head = self.primaryHead();
        const pair = self.editor.model.bracketPairs().matchBracket(head, null) orelse return;
        const opening = pair[0];
        const closing = pair[1];
        const target = if (opening.containsPosition(&head)) closing.startPosition() else opening.startPosition();
        self.recordJump();
        try self.gotoPosition(target, self.extendMode());
    }

    fn gotoFileUnderCursor(self: *HelixEngine) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        if (selections.len > 0 and !selections[0].isEmpty()) {
            const text = try self.rangeText(Range.init(
                selections[0].startLineNumber,
                selections[0].startColumn,
                selections[0].endLineNumber,
                selections[0].endColumn,
            ));
            defer self.allocator.free(text);
            if (text.len > 0 and std.mem.indexOfAny(u8, text, " \t\r\n") == null) {
                self.recordJump();
                try self.window.openPath(text);
                return;
            }
        }
        const head = if (selections.len > 0) selections[0].getPosition() else self.primaryHead();
        const content = try self.editor.model.getLineContent(head.lineNumber);
        defer content.deinit();
        var start = @min(head.column - 1, content.items.len);
        while (start > 0 and isWordByte(content.items[start - 1])) start -= 1;
        var end = @min(head.column - 1, content.items.len);
        while (end < content.items.len and isWordByte(content.items[end])) end += 1;
        if (end <= start) return;
        self.recordJump();
        try self.window.openPath(content.items[start..end]);
    }

    fn applySurround(self: *HelixEngine, kind: SurroundKind, from: u8, to: u8) !void {
        const selections = try self.getSelections();
        defer self.allocator.free(selections);
        const normalized = try self.normalizeSelections(selections);
        defer self.allocator.free(normalized);
        try self.rememberSelections(normalized);

        var edits = ArrayList(PendingEdit).init(self.allocator);
        defer edits.deinit();
        var owned = ArrayList([]u8).init(self.allocator);
        defer {
            for (owned.items) |text| self.allocator.free(text);
            owned.deinit();
        }
        for (normalized) |selection| {
            const range = try self.effectiveRange(selection);
            switch (kind) {
                .add => {
                    const pair = surroundPair(from);
                    var text = ArrayList(u8).init(self.allocator);
                    errdefer text.deinit();
                    try text.append(pair.open);
                    const inner = try self.rangeText(range);
                    defer self.allocator.free(inner);
                    try text.appendSlice(inner);
                    try text.append(pair.close);
                    const slice = try text.toOwnedSlice();
                    try owned.append(slice);
                    try edits.append(.{ .range = range, .text = slice });
                },
                .delete, .replace => {
                    var value = try self.modelValue();
                    defer value.deinit();
                    const text = value.items;
                    const sel_from = self.editor.model.getOffsetAt(range.startPosition());
                    const sel_to = self.editor.model.getOffsetAt(range.endPosition());
                    var open_offset: ?usize = null;
                    var close_offset: ?usize = null;

                    // The selection may already include the pair characters
                    // (for example after `ms(`), or the pair may surround it.
                    const first = codepointAt(text, sel_from);
                    const last_start = prevCodepointOffset(text, sel_to);
                    const last = codepointAt(text, last_start);
                    if (first != null and last != null and first.? <= 0xFF and last.? <= 0xFF and
                        isPair(@intCast(first.?), @intCast(last.?)))
                    {
                        open_offset = sel_from;
                        close_offset = last_start;
                    } else {
                        const before_offset = prevCodepointOffset(text, sel_from);
                        const before = codepointAt(text, before_offset);
                        const after = codepointAt(text, sel_to);
                        if (before != null and after != null and before.? <= 0xFF and after.? <= 0xFF and
                            isPair(@intCast(before.?), @intCast(after.?)))
                        {
                            open_offset = before_offset;
                            close_offset = sel_to;
                        }
                    }
                    const open_at = open_offset orelse continue;
                    const close_at = close_offset orelse continue;
                    if (open_at + 1 > close_at or close_at + 1 > text.len) continue;

                    const inner = text[open_at + 1 .. close_at];
                    var replacement = ArrayList(u8).init(self.allocator);
                    errdefer replacement.deinit();
                    if (kind == .replace) {
                        const pair = surroundPair(to);
                        try replacement.append(pair.open);
                        try replacement.appendSlice(inner);
                        try replacement.append(pair.close);
                    } else {
                        try replacement.appendSlice(inner);
                    }
                    const slice = try replacement.toOwnedSlice();
                    try owned.append(slice);
                    try edits.append(.{
                        .range = Range.fromPositions(
                            self.editor.model.getPositionAt(open_at),
                            self.editor.model.getPositionAt(close_at + 1),
                        ),
                        .text = slice,
                    });
                },
            }
        }
        if (edits.items.len == 0) return;
        self.beginUndoGroup();
        defer self.endUndoGroup();
        // `inserted_range` selects the replacement, which is exactly Helix's
        // range for `surround_add` (the previously selected text plus both
        // pair characters) and for `surround_delete` (the inner text).
        try self.applyEditBatch(edits.items, .inserted_range);
    }

    fn charAt(self: *HelixEngine, position: Position) ?u21 {
        const content = self.editor.model.getLineContent(position.lineNumber) catch return null;
        var mutable = content;
        defer mutable.deinit();
        if (position.column > mutable.items.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(mutable.items[position.column - 1]) catch return null;
        if (position.column - 1 + len > mutable.items.len) return null;
        const codepoint = std.unicode.utf8Decode(mutable.items[position.column - 1 .. position.column - 1 + len]) catch return null;
        return codepoint;
    }

    // ------------------------------------------------------------------
    // Pending state and buffers
    // ------------------------------------------------------------------

    fn takeCount(self: *HelixEngine) usize {
        const count = if (self.count_active) @max(self.count, 1) else 1;
        self.count = 0;
        self.count_active = false;
        return count;
    }

    fn resetPending(self: *HelixEngine) void {
        self.count = 0;
        self.count_active = false;
        self.waiting_register = false;
        self.selected_register = null;
        self.pending_replace = false;
        self.pending_insert_register = false;
        self.pending_find = null;
        self.pending_text_object = null;
        self.surround = null;
    }

    fn cancelTransient(self: *HelixEngine) !void {
        self.command_buffer.clearRetainingCapacity();
        self.search_buffer.clearRetainingCapacity();
        self.regex_buffer.clearRetainingCapacity();
        try self.restoreSearchOrigin();
        self.freeSearchOrigin();
        self.prompt_select = false;
        self.minor_select = false;
        self.resetPending();
        self.mode = .normal;
    }
};

fn clearRecordedKeys(allocator: Allocator, list: *ArrayList(RecordedKey)) void {
    for (list.items) |recorded| {
        if (recorded.key == .text) allocator.free(recorded.key.text);
    }
    list.clearRetainingCapacity();
}

fn isMacroStopKey(event: *const KeyInputEvent) bool {
    return switch (event.key) {
        .char => |char| char == 'Q',
        .text => |text| text.len == 1 and text[0] == 'Q',
        else => false,
    };
}

fn removeLastCodepoint(buffer: *ArrayList(u8)) void {
    if (buffer.items.len == 0) return;
    var index = buffer.items.len - 1;
    while (index > 0 and (buffer.items[index] & 0xC0) == 0x80) index -= 1;
    buffer.items.len = index;
}

fn removeLastWord(buffer: *ArrayList(u8)) void {
    if (buffer.items.len == 0) return;
    var index = buffer.items.len;
    while (index > 0) {
        const previous = previousCodepointStart(buffer.items, index);
        if (!isWhitespaceByte(buffer.items[previous])) break;
        index = previous;
    }
    while (index > 0) {
        const previous = previousCodepointStart(buffer.items, index);
        if (isWhitespaceByte(buffer.items[previous])) break;
        index = previous;
    }
    buffer.items.len = index;
}

fn previousCodepointStart(buffer: []const u8, index: usize) usize {
    if (index == 0) return 0;
    var result = index - 1;
    while (result > 0 and (buffer[result] & 0xC0) == 0x80) result -= 1;
    return result;
}

fn isWhitespaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn containsUppercase(text: []const u8) bool {
    for (text) |byte| {
        if (std.ascii.isUpper(byte)) return true;
    }
    return false;
}

fn appendRegexEscaped(buffer: *ArrayList(u8), text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '\\', '^', '$', '.', '|', '?', '*', '+', '(', ')', '[', ']', '{', '}' => try buffer.append('\\'),
            else => {},
        }
        try buffer.append(byte);
    }
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 128;
}

fn wordClassBigAt(text: []const u8, offset: usize) u8 {
    if (offset >= text.len) return 0;
    const byte = text[offset];
    if (isWhitespaceByte(byte)) return 0;
    return 1;
}

fn surroundPair(char: u8) struct { open: u8, close: u8 } {
    return switch (char) {
        '(' => .{ .open = '(', .close = ')' },
        '[' => .{ .open = '[', .close = ']' },
        '{' => .{ .open = '{', .close = '}' },
        '<' => .{ .open = '<', .close = '>' },
        ')' => .{ .open = '(', .close = ')' },
        ']' => .{ .open = '[', .close = ']' },
        '}' => .{ .open = '{', .close = '}' },
        '>' => .{ .open = '<', .close = '>' },
        else => .{ .open = char, .close = char },
    };
}

fn isPair(open: u8, close: u8) bool {
    if (open == close and (open == '"' or open == '\'' or open == '`')) return true;
    return switch (open) {
        '(' => close == ')',
        '[' => close == ']',
        '{' => close == '}',
        '<' => close == '>',
        else => false,
    };
}

fn trimSelectionText(allocator: Allocator, text: []const u8) ![]u8 {
    var output = ArrayList(u8).init(allocator);
    errdefer output.deinit();
    var iterator = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (iterator.next()) |line| {
        if (!first) try output.append('\n');
        first = false;
        try output.appendSlice(std.mem.trim(u8, line, " \t\r"));
    }
    return output.toOwnedSlice();
}

fn isEscaped(line: []const u8, index: usize) bool {
    var backslashes: usize = 0;
    var i = index;
    while (i > 0 and line[i - 1] == '\\') : (i -= 1) backslashes += 1;
    return backslashes % 2 == 1;
}
