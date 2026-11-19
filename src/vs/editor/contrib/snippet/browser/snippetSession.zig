// Port of `src/vs/editor/contrib/snippet/browser/snippetSession.ts`.
//
// OneSnippet owns the placeholder decorations and moves through the
// placeholder groups. SnippetSession builds one snippet per selection, inserts
// the resolved text, and can merge nested snippets into active placeholders.
//
// Terminal adaptation: `applyTextEditsWithPositions` supplies the position
// where each edit landed, replacing the undo-edit callback that upstream's
// `executeEdits` uses. Decorations are model decorations with the upstream
// class names; the terminal view renders them through the generic decoration
// path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_mod = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
const Editor = editor_mod.Editor;
const TextEdit = editor_mod.TextEdit;
const AppliedTextEdit = editor_mod.AppliedTextEdit;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const SelectionDirection = @import("../../../common/core/selection.zig").SelectionDirection;
const createSelectionWithDirection = @import("../../../common/core/selection.zig").createWithDirection;
const selectionFromRange = @import("../../../common/core/selection.zig").fromRange;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const TrackedRangeStickiness = @import("../../../common/model.zig").TrackedRangeStickiness;
const ModelDecorationOptions = @import("../../../common/model.zig").ModelDecorationOptions;
const cursor_type_operations = @import("../../../common/cursor/cursorTypeOperations.zig");
const compareRangesUsingStarts = @import("../../../common/core/range.zig").compareRangesUsingStarts;
const strings = @import("../../../../base/common/strings.zig");
const parser = @import("./snippetParser.zig");
const variables = @import("./snippetVariables.zig");

const Marker = parser.Marker;
const TextmateSnippet = parser.TextmateSnippet;

var decor_active: ModelDecorationOptions = makeDecorOptions("snippet-placeholder-1", "snippet-placeholder", .AlwaysGrowsWhenTypingAtEdges);
var decor_inactive: ModelDecorationOptions = makeDecorOptions("snippet-placeholder-2", "snippet-placeholder", .NeverGrowsWhenTypingAtEdges);
var decor_active_final: ModelDecorationOptions = makeDecorOptions("snippet-placeholder-3", "finish-snippet-placeholder", .NeverGrowsWhenTypingAtEdges);
var decor_inactive_final: ModelDecorationOptions = makeDecorOptions("snippet-placeholder-4", "finish-snippet-placeholder", .NeverGrowsWhenTypingAtEdges);

fn makeDecorOptions(description: []const u8, class_name: []const u8, stickiness: TrackedRangeStickiness) ModelDecorationOptions {
    var options = ModelDecorationOptions.init(description, stickiness);
    options.className = class_name;
    return options;
}

fn decorationFor(placeholder: *const Marker, active: bool) *ModelDecorationOptions {
    if (active) {
        return if (placeholder.isFinalTabstop()) &decor_active_final else &decor_active;
    }
    return if (placeholder.isFinalTabstop()) &decor_inactive_final else &decor_inactive;
}

pub const ActiveChoice = struct {
    choice: *Marker,
    range: Range,
};

pub const OneSnippet = struct {
    allocator: Allocator,
    editor: *Editor,
    snippet: *TextmateSnippet,
    snippet_line_leading_whitespace: []u8,
    placeholder_decorations: ?std.AutoHashMap(*Marker, u64) = null,
    placeholder_groups: std.ArrayListUnmanaged(std.ArrayListUnmanaged(*Marker)) = .empty,
    offset: isize = -1,
    placeholder_groups_idx: isize = -1,
    nesting_level: f64 = 1,

    pub fn init(
        allocator: Allocator,
        editor: *Editor,
        snippet: *TextmateSnippet,
        snippet_line_leading_whitespace: []const u8,
    ) !*OneSnippet {
        const self = try allocator.create(OneSnippet);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .snippet = snippet,
            .snippet_line_leading_whitespace = try allocator.dupe(u8, snippet_line_leading_whitespace),
        };
        errdefer allocator.free(self.snippet_line_leading_whitespace);
        try self.rebuildGroups();
        return self;
    }

    pub fn deinit(self: *OneSnippet) void {
        self.dispose();
        self.snippet.deinit();
        self.allocator.free(self.snippet_line_leading_whitespace);
        self.allocator.destroy(self);
    }

    pub fn dispose(self: *OneSnippet) void {
        if (self.placeholder_decorations) |map| {
            var ids = std.ArrayListUnmanaged(u64).empty;
            defer ids.deinit(self.allocator);
            var iterator = map.valueIterator();
            while (iterator.next()) |id| ids.append(self.allocator, id.*) catch {};
            if (ids.items.len > 0) {
                const removed = self.editor.model.deltaDecorations(ids.items, &.{}, self.ownerId()) catch &.{};
                if (removed.len > 0) self.editor.model.getAllocator().free(removed);
            }
            var mut_map = map;
            mut_map.deinit();
            self.placeholder_decorations = null;
        }
        self.clearGroups();
    }

    pub fn initialize(self: *OneSnippet, position: Position) void {
        self.offset = @intCast(self.editor.model.getOffsetAt(position));
    }

    fn ownerId(self: *OneSnippet) usize {
        return @intFromPtr(self);
    }

    fn initDecorations(self: *OneSnippet) !void {
        if (self.placeholder_decorations != null) return;
        std.debug.assert(self.offset >= 0);
        var map = std.AutoHashMap(*Marker, u64).init(self.allocator);
        errdefer map.deinit();

        const placeholders = try self.snippet.placeholders();
        var decorations = std.ArrayListUnmanaged(@import("../../../common/model.zig").ModelDeltaDecoration).empty;
        defer decorations.deinit(self.allocator);
        var placeholder_list = std.ArrayListUnmanaged(*Marker).empty;
        defer placeholder_list.deinit(self.allocator);

        for (placeholders) |placeholder| {
            const placeholder_offset = self.snippet.offset(placeholder);
            const placeholder_len = self.snippet.fullLen(placeholder);
            const start = self.editor.model.getPositionAt(@intCast(self.offset + placeholder_offset));
            const end = self.editor.model.getPositionAt(@intCast(self.offset + placeholder_offset + @as(isize, @intCast(placeholder_len))));
            const range = Range.init(start.lineNumber, start.column, end.lineNumber, end.column);
            try decorations.append(self.allocator, .{
                .range = range,
                .options = decorationFor(placeholder, false),
            });
            try placeholder_list.append(self.allocator, placeholder);
        }

        const ids = try self.editor.model.deltaDecorations(&.{}, decorations.items, self.ownerId());
        defer self.editor.model.getAllocator().free(ids);
        for (ids, 0..) |id, index| {
            if (index >= placeholder_list.items.len) break;
            try map.put(placeholder_list.items[index], id);
        }
        self.placeholder_decorations = map;
    }

    pub fn move(self: *OneSnippet, fwd: ?bool) ![]Selection {
        try self.initDecorations();
        const model = self.editor.model;

        if (self.placeholder_groups_idx >= 0) {
            var operations = std.ArrayListUnmanaged(TextEdit).empty;
            defer operations.deinit(self.allocator);
            var owned_texts = std.ArrayListUnmanaged([]u8).empty;
            defer {
                for (owned_texts.items) |text| self.allocator.free(text);
                owned_texts.deinit(self.allocator);
            }
            const group = self.placeholder_groups.items[@intCast(self.placeholder_groups_idx)];
            for (group.items) |placeholder| {
                if (placeholder.transform) |transform| {
                    const id = self.placeholder_decorations.?.get(placeholder);
                    const range = if (id) |decoration_id| model.getDecorationRange(decoration_id) else null;
                    if (range) |decoration_range| {
                        const current_value = try model.getValueInRange(decoration_range, .TextDefined);
                        defer current_value.deinit();
                        const transformed = try transform.resolve(self.allocator, current_value.items);
                        defer self.allocator.free(transformed);
                        const transformed_value = try self.fixTransformedIndentation(transformed);
                        try owned_texts.append(self.allocator, transformed_value);
                        try operations.append(self.allocator, .{ .range = decoration_range, .text = transformed_value });
                    }
                }
            }
            if (operations.items.len > 0) {
                try self.editor.applyTextEdits(operations.items, &.{});
            }
        }

        var could_skip = false;
        if (fwd == true and self.placeholder_groups_idx < @as(isize, @intCast(self.placeholder_groups.items.len)) - 1) {
            self.placeholder_groups_idx += 1;
            could_skip = true;
        } else if (fwd == false and self.placeholder_groups_idx > 0) {
            self.placeholder_groups_idx -= 1;
            could_skip = true;
        }

        var active = std.AutoHashMap(*Marker, void).init(self.allocator);
        defer active.deinit();
        var selections = std.ArrayListUnmanaged(Selection).empty;
        defer selections.deinit(self.allocator);

        const group = self.placeholder_groups.items[@intCast(self.placeholder_groups_idx)];
        for (group.items) |placeholder| {
            const id = self.placeholder_decorations.?.get(placeholder);
            const range = if (id) |decoration_id| model.getDecorationRange(decoration_id) else null;
            could_skip = could_skip and try self.hasPlaceholderBeenCollapsed(placeholder);
            if (id == null or range == null) continue;
            const value = range.?;
            try selections.append(self.allocator, Selection.init(value.startLineNumber, value.startColumn, value.endLineNumber, value.endColumn));
            model.changeDecorationOptionsById(id.?, decorationFor(placeholder, true));
            try active.put(placeholder, {});

            const enclosing = try self.snippet.enclosingPlaceholders(placeholder);
            for (enclosing) |enclosing_placeholder| {
                const enclosing_id = self.placeholder_decorations.?.get(enclosing_placeholder);
                if (enclosing_id) |decoration_id| {
                    model.changeDecorationOptionsById(decoration_id, decorationFor(enclosing_placeholder, true));
                    try active.put(enclosing_placeholder, {});
                }
            }
        }

        var iterator = self.placeholder_decorations.?.iterator();
        while (iterator.next()) |entry| {
            if (active.contains(entry.key_ptr.*)) continue;
            model.changeDecorationOptionsById(entry.value_ptr.*, decorationFor(entry.key_ptr.*, false));
        }

        if (!could_skip) return selections.toOwnedSlice(self.allocator);
        return self.move(fwd);
    }

    fn fixTransformedIndentation(self: *OneSnippet, value: []const u8) ![]u8 {
        var lines = std.ArrayListUnmanaged([]const u8).empty;
        defer lines.deinit(self.allocator);
        try splitLines(self.allocator, value, &lines);
        if (lines.items.len <= 1) return self.allocator.dupe(u8, value);

        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, lines.items[0]);
        const eol = eolString(self.editor.model.getEOL());
        for (lines.items[1..]) |line| {
            try out.appendSlice(self.allocator, eol);
            const joined = try std.mem.concat(self.allocator, u8, &.{ self.snippet_line_leading_whitespace, line });
            defer self.allocator.free(joined);
            const normalized = try cursor_type_operations.normalizeIndentation(
                self.allocator,
                joined,
                self.editor.indentSize(),
                self.editor.model.getOptions().insertSpaces,
            );
            defer self.allocator.free(normalized);
            try out.appendSlice(self.allocator, normalized);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn hasPlaceholderBeenCollapsed(self: *OneSnippet, placeholder: *Marker) !bool {
        var marker: ?*Marker = placeholder;
        while (marker) |current| {
            if (current.kind == .placeholder) {
                const id = self.placeholder_decorations.?.get(current);
                const range = if (id) |decoration_id| self.editor.model.getDecorationRange(decoration_id) else null;
                if ((range == null or range.?.isEmpty())) {
                    const text = try current.toString(self.allocator);
                    defer self.allocator.free(text);
                    if (text.len > 0) return true;
                }
            }
            marker = current.parent;
        }
        return false;
    }

    pub fn isAtFirstPlaceholder(self: *const OneSnippet) bool {
        return self.placeholder_groups_idx <= 0 or self.placeholder_groups.items.len == 0;
    }

    pub fn isAtLastPlaceholder(self: *const OneSnippet) bool {
        return self.placeholder_groups_idx == @as(isize, @intCast(self.placeholder_groups.items.len)) - 1;
    }

    pub fn hasPlaceholder(self: *OneSnippet) bool {
        const placeholders = self.snippet.placeholders() catch return false;
        return placeholders.len > 0;
    }

    pub fn isTrivialSnippet(self: *OneSnippet) !bool {
        const placeholders = try self.snippet.placeholders();
        if (placeholders.len == 0) return true;
        if (placeholders.len == 1) {
            const placeholder = placeholders[0];
            if (placeholder.isFinalTabstop()) {
                if (self.snippet.root.rightMostDescendant() == placeholder) return true;
            }
        }
        return false;
    }

    pub const PossibleSelections = struct {
        index: f64,
        ranges: []Range,
    };

    pub fn computePossibleSelections(self: *OneSnippet, allocator: Allocator) ![]PossibleSelections {
        var result = std.ArrayListUnmanaged(PossibleSelections).empty;
        errdefer result.deinit(allocator);
        for (self.placeholder_groups.items) |group| {
            var ranges = std.ArrayListUnmanaged(Range).empty;
            errdefer ranges.deinit(allocator);
            var valid = true;
            var index: f64 = 0;
            var first = true;
            for (group.items) |placeholder| {
                if (placeholder.isFinalTabstop()) {
                    valid = false;
                    break;
                }
                if (first) {
                    index = placeholder.index;
                    first = false;
                }
                const id = self.placeholder_decorations.?.get(placeholder) orelse {
                    valid = false;
                    break;
                };
                const range = self.editor.model.getDecorationRange(id) orelse {
                    valid = false;
                    break;
                };
                try ranges.append(allocator, range);
            }
            if (valid and ranges.items.len > 0) {
                try result.append(allocator, .{ .index = index, .ranges = try ranges.toOwnedSlice(allocator) });
            } else {
                ranges.deinit(allocator);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn activeChoice(self: *OneSnippet) ?ActiveChoice {
        const decorations = self.placeholder_decorations orelse return null;
        if (self.placeholder_groups_idx < 0) return null;
        const group = self.placeholder_groups.items[@intCast(self.placeholder_groups_idx)];
        if (group.items.len == 0) return null;
        const placeholder = group.items[0];
        const choice = placeholder.choice() orelse return null;
        const id = decorations.get(placeholder) orelse return null;
        const range = self.editor.model.getDecorationRange(id) orelse return null;
        return .{ .choice = choice, .range = range };
    }

    pub fn hasChoice(self: *OneSnippet) bool {
        for (self.snippet.walkArena() catch return false) |marker| {
            if (marker.kind == .choice) return true;
        }
        return false;
    }

    pub fn activePlaceholderCount(self: *const OneSnippet) usize {
        if (self.placeholder_groups_idx < 0) return 0;
        return self.placeholder_groups.items[@intCast(self.placeholder_groups_idx)].items.len;
    }

    pub fn merge(self: *OneSnippet, others: *std.ArrayListUnmanaged(*OneSnippet)) !void {
        self.nesting_level *= 10;
        const group = self.placeholder_groups.items[@intCast(self.placeholder_groups_idx)];

        for (group.items) |placeholder| {
            if (others.items.len == 0) break;
            const nested = others.orderedRemove(0);
            const index_last_placeholder = (try nested.snippet.placeholderInfo()).last.?.index;

            for (try nested.snippet.placeholders()) |nested_placeholder| {
                if (nested_placeholder.isFinalTabstop()) {
                    nested_placeholder.index = placeholder.index + ((index_last_placeholder + 1) / self.nesting_level);
                } else {
                    nested_placeholder.index = placeholder.index + (nested_placeholder.index / self.nesting_level);
                }
            }

            var clones = std.ArrayListUnmanaged(*Marker).empty;
            defer clones.deinit(self.allocator);
            for (nested.snippet.children()) |child| {
                try clones.append(self.allocator, try child.cloneInto(self.snippet));
            }
            try self.snippet.replace(placeholder, clones.items);

            if (self.placeholder_decorations) |*decorations| {
                if (decorations.get(placeholder)) |id| {
                    const removed = self.editor.model.deltaDecorations(&.{id}, &.{}, self.ownerId()) catch &.{};
                    if (removed.len > 0) self.editor.model.getAllocator().free(removed);
                    _ = decorations.remove(placeholder);
                }
            }

            const nested_placeholders = try nested.snippet.placeholders();
            const cloned_placeholders = try collectPlaceholders(self.snippet, clones.items, self.allocator);
            defer self.allocator.free(cloned_placeholders);
            var decorations = std.ArrayListUnmanaged(@import("../../../common/model.zig").ModelDeltaDecoration).empty;
            defer decorations.deinit(self.allocator);
            var keys = std.ArrayListUnmanaged(*Marker).empty;
            defer keys.deinit(self.allocator);
            for (nested_placeholders, 0..) |original, nested_index| {
                if (nested_index >= cloned_placeholders.len) break;
                const cloned = cloned_placeholders[nested_index];
                const placeholder_offset = nested.snippet.offset(original);
                const placeholder_len = nested.snippet.fullLen(original);
                const start = self.editor.model.getPositionAt(@intCast(nested.offset + placeholder_offset));
                const end = self.editor.model.getPositionAt(@intCast(nested.offset + placeholder_offset + @as(isize, @intCast(placeholder_len))));
                try decorations.append(self.allocator, .{
                    .range = Range.init(start.lineNumber, start.column, end.lineNumber, end.column),
                    .options = decorationFor(cloned, false),
                });
                try keys.append(self.allocator, cloned);
            }
            if (decorations.items.len > 0) {
                const ids = try self.editor.model.deltaDecorations(&.{}, decorations.items, self.ownerId());
                defer self.editor.model.getAllocator().free(ids);
                for (ids, 0..) |id, index| {
                    if (index < keys.items.len) try self.placeholder_decorations.?.put(keys.items[index], id);
                }
            }
        }

        try self.renormalizePlaceholderIndices();
        try self.rebuildGroups();
    }

    fn renormalizePlaceholderIndices(self: *OneSnippet) !void {
        var unique = std.ArrayListUnmanaged(f64).empty;
        defer unique.deinit(self.allocator);
        for (try self.snippet.placeholders()) |placeholder| {
            if (placeholder.isFinalTabstop()) continue;
            var found = false;
            for (unique.items) |value| {
                if (value == placeholder.index) {
                    found = true;
                    break;
                }
            }
            if (!found) try unique.append(self.allocator, placeholder.index);
        }
        std.mem.sort(f64, unique.items, {}, struct {
            fn lessThan(_: void, a: f64, b: f64) bool {
                return a < b;
            }
        }.lessThan);
        var remap = std.AutoHashMap(u64, f64).init(self.allocator);
        defer remap.deinit();
        for (unique.items, 0..) |value, index| {
            try remap.put(@bitCast(value), @floatFromInt(index + 1));
        }
        for (try self.snippet.placeholders()) |placeholder| {
            if (placeholder.isFinalTabstop()) continue;
            if (remap.get(@bitCast(placeholder.index))) |new_index| placeholder.index = new_index;
        }
        self.nesting_level = 1;
    }

    pub fn getEnclosingRange(self: *OneSnippet) ?Range {
        var result: ?Range = null;
        const decorations = self.placeholder_decorations orelse return null;
        var iterator = decorations.valueIterator();
        while (iterator.next()) |id| {
            const range = self.editor.model.getDecorationRange(id.*) orelse continue;
            result = if (result) |existing| existing.plusRange(&range) else range;
        }
        return result;
    }

    fn rebuildGroups(self: *OneSnippet) !void {
        self.clearGroups();
        const placeholders = try self.snippet.placeholders();
        for (placeholders) |placeholder| {
            var group_index: ?usize = null;
            for (self.placeholder_groups.items, 0..) |group, index| {
                if (group.items.len == 0) continue;
                if (comparePlaceholders(group.items[0], placeholder) == 0) {
                    group_index = index;
                    break;
                }
            }
            if (group_index) |index| {
                try self.placeholder_groups.items[index].append(self.allocator, placeholder);
            } else {
                var group = std.ArrayListUnmanaged(*Marker).empty;
                errdefer group.deinit(self.allocator);
                try group.append(self.allocator, placeholder);
                try self.placeholder_groups.append(self.allocator, group);
            }
        }
        std.mem.sort(std.ArrayListUnmanaged(*Marker), self.placeholder_groups.items, {}, struct {
            fn lessThan(_: void, a: std.ArrayListUnmanaged(*Marker), b: std.ArrayListUnmanaged(*Marker)) bool {
                return comparePlaceholders(a.items[0], b.items[0]) < 0;
            }
        }.lessThan);
        self.placeholder_groups_idx = @min(self.placeholder_groups_idx, @as(isize, @intCast(self.placeholder_groups.items.len)) - 1);
    }

    fn clearGroups(self: *OneSnippet) void {
        for (self.placeholder_groups.items) |*group| group.deinit(self.allocator);
        self.placeholder_groups.deinit(self.allocator);
        self.placeholder_groups = .empty;
    }
};

fn collectPlaceholders(snippet: *TextmateSnippet, roots: []const *Marker, allocator: Allocator) ![]*Marker {
    var result = std.ArrayListUnmanaged(*Marker).empty;
    var index: usize = 0;
    for (roots) |root| try result.append(allocator, root);
    while (index < result.items.len) : (index += 1) {
        const marker = result.items[index];
        for (marker.children.items) |child| try result.append(allocator, child);
    }
    var placeholders = std.ArrayListUnmanaged(*Marker).empty;
    for (result.items) |marker| {
        if (marker.kind == .placeholder) try placeholders.append(allocator, marker);
    }
    result.deinit(allocator);
    _ = snippet;
    return placeholders.toOwnedSlice(allocator);
}

fn comparePlaceholders(a: *const Marker, b: *const Marker) isize {
    if (a.index == b.index) return 0;
    if (a.isFinalTabstop()) return 1;
    if (b.isFinalTabstop()) return -1;
    if (a.index < b.index) return -1;
    if (a.index > b.index) return 1;
    return 0;
}

pub const InsertOptions = struct {
    overwrite_before: usize = 0,
    overwrite_after: usize = 0,
    adjust_whitespace: bool = true,
    clipboard_text: ?[]const u8 = null,
    overtyping_capturer: ?variables.OvertypingCapturer = null,
};

pub const SnippetEdit = struct {
    range: Range,
    template: []const u8,
    keep_whitespace: ?bool = null,
};

const MergeLog = struct {
    nesting_level: f64,
    placeholder_groups_idx: isize,
    template: []u8,
};

pub const SnippetSession = struct {
    allocator: Allocator,
    editor: *Editor,
    template_text: []u8,
    template_edits: ?[]SnippetEdit = null,
    options: InsertOptions,
    snippets: std.ArrayListUnmanaged(*OneSnippet) = .empty,
    template_merges: std.ArrayListUnmanaged(MergeLog) = .empty,
    inserted: bool = false,

    pub fn init(allocator: Allocator, editor: *Editor, template: []const u8, options: InsertOptions) !*SnippetSession {
        const self = try allocator.create(SnippetSession);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .template_text = try allocator.dupe(u8, template),
            .options = options,
        };
        return self;
    }

    pub fn initWithEdits(allocator: Allocator, editor: *Editor, edits: []const SnippetEdit, options: InsertOptions) !*SnippetSession {
        const self = try allocator.create(SnippetSession);
        errdefer allocator.destroy(self);
        const owned = try allocator.alloc(SnippetEdit, edits.len);
        errdefer allocator.free(owned);
        var copied: usize = 0;
        errdefer for (owned[0..copied]) |edit| allocator.free(edit.template);
        for (edits, 0..) |edit, index| {
            owned[index] = .{
                .range = edit.range,
                .template = try allocator.dupe(u8, edit.template),
                .keep_whitespace = edit.keep_whitespace,
            };
            copied += 1;
        }
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .template_text = try allocator.dupe(u8, ""),
            .template_edits = owned,
            .options = options,
        };
        return self;
    }

    pub fn deinit(self: *SnippetSession) void {
        for (self.snippets.items) |snippet| snippet.deinit();
        self.snippets.deinit(self.allocator);
        for (self.template_merges.items) |log| self.allocator.free(log.template);
        self.template_merges.deinit(self.allocator);
        self.allocator.free(self.template_text);
        if (self.template_edits) |edits| {
            for (edits) |edit| self.allocator.free(edit.template);
            self.allocator.free(edits);
        }
        self.allocator.destroy(self);
    }

    pub fn logInfo(self: *SnippetSession, allocator: Allocator) ![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "template=\"");
        try out.appendSlice(allocator, self.template_text);
        try out.appendSlice(allocator, "\", merged_templates=\"");
        for (self.template_merges.items, 0..) |log, index| {
            if (index > 0) try out.appendSlice(allocator, " -> ");
            try out.appendSlice(allocator, log.template);
        }
        try out.appendSlice(allocator, "\"");
        return out.toOwnedSlice(allocator);
    }

    pub fn insert(self: *SnippetSession) !void {
        if (self.inserted) return;
        var built = if (self.template_edits) |edits|
            try createEditsAndSnippetsFromEdits(
                self.allocator,
                self.editor,
                edits,
                false,
                self.options.adjust_whitespace,
                self.options,
            )
        else
            try createEditsAndSnippetsFromSelections(
                self.allocator,
                self.editor,
                self.template_text,
                self.options,
                false,
            );
        self.snippets = built.snippets;
        built.snippets = .empty;
        defer {
            for (built.edits) |edit| self.allocator.free(edit.text);
            self.allocator.free(built.edits);
        }

        const applied = try self.editor.applyTextEditsWithPositions(built.edits);
        defer self.allocator.free(applied);
        self.inserted = true;

        for (self.snippets.items, 0..) |snippet, index| {
            snippet.initialize(applied[index].start);
        }

        if (self.snippets.items.len > 0 and self.snippets.items[0].hasPlaceholder()) {
            const selections = try self.move(true);
            defer self.allocator.free(selections);
            if (selections.len > 0) try self.editor.setSelections(selections);
        } else {
            const selections = try collapseAtEnds(self.allocator, applied);
            defer self.allocator.free(selections);
            if (selections.len > 0) try self.editor.setSelections(selections);
        }
        self.editor.ensureCursorVisible();
    }

    pub fn merge(self: *SnippetSession, template: []const u8, options: InsertOptions) !void {
        if (self.snippets.items.len == 0) return;
        const first = self.snippets.items[0];
        try self.template_merges.append(self.allocator, .{
            .nesting_level = first.nesting_level,
            .placeholder_groups_idx = first.placeholder_groups_idx,
            .template = try self.allocator.dupe(u8, template),
        });
        var built = try createEditsAndSnippetsFromSelections(
            self.allocator,
            self.editor,
            template,
            options,
            true,
        );
        defer {
            for (built.edits) |edit| self.allocator.free(edit.text);
            self.allocator.free(built.edits);
        }

        const applied = try self.editor.applyTextEditsWithPositions(built.edits);
        defer self.allocator.free(applied);
        for (built.snippets.items, 0..) |snippet, index| {
            snippet.initialize(applied[index].start);
        }

        var is_trivial = true;
        if (built.snippets.items.len > 0) is_trivial = try built.snippets.items[0].isTrivialSnippet();
        var active_count: usize = 0;
        for (self.snippets.items) |snippet| active_count += snippet.activePlaceholderCount();
        const can_merge = built.snippets.items.len == active_count;

        if (!is_trivial and can_merge) {
            var nested = std.ArrayListUnmanaged(*OneSnippet).empty;
            defer nested.deinit(self.allocator);
            try nested.appendSlice(self.allocator, built.snippets.items);
            for (self.snippets.items) |snippet| {
                try snippet.merge(&nested);
            }
            for (built.snippets.items) |snippet| snippet.deinit();
            built.snippets.deinit(self.allocator);
            if (self.snippets.items.len > 0 and self.snippets.items[0].hasPlaceholder()) {
                const selections = try self.move(null);
                defer self.allocator.free(selections);
                if (selections.len > 0) try self.editor.setSelections(selections);
            }
        } else {
            for (built.snippets.items) |snippet| snippet.deinit();
            built.snippets.deinit(self.allocator);
            const selections = try collapseAtEnds(self.allocator, applied);
            defer self.allocator.free(selections);
            if (selections.len > 0) try self.editor.setSelections(selections);
        }
        self.editor.ensureCursorVisible();
    }

    pub fn next(self: *SnippetSession) !bool {
        const selections = try self.move(true);
        defer self.allocator.free(selections);
        if (selections.len == 0) return false;
        try self.editor.setSelections(selections);
        self.editor.ensureCursorVisible();
        return true;
    }

    pub fn previous(self: *SnippetSession) !bool {
        return self.prev();
    }

    pub fn prev(self: *SnippetSession) !bool {
        const selections = try self.move(false);
        defer self.allocator.free(selections);
        if (selections.len == 0) return false;
        try self.editor.setSelections(selections);
        self.editor.ensureCursorVisible();
        return true;
    }

    fn move(self: *SnippetSession, fwd: ?bool) ![]Selection {
        var selections = std.ArrayListUnmanaged(Selection).empty;
        errdefer selections.deinit(self.allocator);
        for (self.snippets.items) |snippet| {
            const one = try snippet.move(fwd);
            defer self.allocator.free(one);
            try selections.appendSlice(self.allocator, one);
        }
        return selections.toOwnedSlice(self.allocator);
    }

    pub fn cancel(self: *SnippetSession) void {
        for (self.snippets.items) |snippet| snippet.deinit();
        self.snippets.clearRetainingCapacity();
    }

    pub fn isAtFirstPlaceholder(self: *const SnippetSession) bool {
        if (self.snippets.items.len == 0) return true;
        return self.snippets.items[0].isAtFirstPlaceholder();
    }

    pub fn isAtLastPlaceholder(self: *const SnippetSession) bool {
        if (self.snippets.items.len == 0) return true;
        return self.snippets.items[0].isAtLastPlaceholder();
    }

    pub fn hasPlaceholder(self: *SnippetSession) bool {
        if (self.snippets.items.len == 0) return false;
        return self.snippets.items[0].hasPlaceholder();
    }

    pub fn hasChoice(self: *SnippetSession) bool {
        if (self.snippets.items.len == 0) return false;
        return self.snippets.items[0].hasChoice();
    }

    pub fn activeChoice(self: *SnippetSession) ?ActiveChoice {
        if (self.snippets.items.len == 0) return null;
        return self.snippets.items[0].activeChoice();
    }

    pub fn isSelectionWithinPlaceholders(self: *SnippetSession) !bool {
        if (!self.hasPlaceholder()) return false;
        const selections_owned = try self.editor.getModelSelections();
        defer self.allocator.free(selections_owned);

        if (selections_owned.len < self.snippets.items.len) return false;

        var all_possible = std.AutoHashMap(u64, std.ArrayListUnmanaged(Range)).init(self.allocator);
        defer {
            var iterator = all_possible.valueIterator();
            while (iterator.next()) |ranges| ranges.deinit(self.allocator);
            all_possible.deinit();
        }

        for (self.snippets.items) |snippet| {
            const possible = try snippet.computePossibleSelections(self.allocator);
            defer {
                for (possible) |entry| self.allocator.free(entry.ranges);
                self.allocator.free(possible);
            }

            if (all_possible.count() == 0) {
                for (possible) |entry| {
                    if (entry.ranges.len == 0) continue;
                    var sorted = try self.allocator.dupe(Range, entry.ranges);
                    defer self.allocator.free(sorted);
                    std.mem.sort(Range, sorted, {}, rangeLessThan);
                    for (selections_owned) |selection| {
                        const selection_range = rangeOfSelection(selection);
                        if (sorted[0].containsRange(&selection_range)) {
                            try all_possible.put(@bitCast(entry.index), std.ArrayListUnmanaged(Range).empty);
                            break;
                        }
                    }
                }
            }

            if (all_possible.count() == 0) return false;

            for (possible) |entry| {
                if (all_possible.getPtr(@bitCast(entry.index))) |ranges| {
                    try ranges.appendSlice(self.allocator, entry.ranges);
                }
            }
        }

        const selections = try self.allocator.dupe(Selection, selections_owned);
        defer self.allocator.free(selections);
        std.mem.sort(Selection, selections, {}, selectionLessThan);

        var remove_keys = std.ArrayListUnmanaged(u64).empty;
        defer remove_keys.deinit(self.allocator);
        var iterator = all_possible.iterator();
        while (iterator.next()) |entry| {
            const ranges = entry.value_ptr;
            if (ranges.items.len != selections.len) {
                try remove_keys.append(self.allocator, entry.key_ptr.*);
                continue;
            }
            std.mem.sort(Range, ranges.items, {}, rangeLessThan);
            var valid = true;
            for (ranges.items, 0..) |range, index| {
                const selection_range = rangeOfSelection(selections[index]);
                if (!range.containsRange(&selection_range)) {
                    valid = false;
                    break;
                }
            }
            if (!valid) try remove_keys.append(self.allocator, entry.key_ptr.*);
        }
        for (remove_keys.items) |key| {
            if (all_possible.fetchRemove(key)) |removed| {
                var ranges = removed.value;
                ranges.deinit(self.allocator);
            }
        }
        return all_possible.count() > 0;
    }

    pub fn getEnclosingRange(self: *SnippetSession) ?Range {
        var result: ?Range = null;
        for (self.snippets.items) |snippet| {
            const snippet_range = snippet.getEnclosingRange() orelse continue;
            result = if (result) |existing| existing.plusRange(&snippet_range) else snippet_range;
        }
        return result;
    }
};

fn rangeLessThan(_: void, a: Range, b: Range) bool {
    return compareRangesUsingStarts(&a, &b) < 0;
}

fn selectionLessThan(_: void, a: Selection, b: Selection) bool {
    if (a.selectionStartLineNumber != b.selectionStartLineNumber) {
        return a.selectionStartLineNumber < b.selectionStartLineNumber;
    }
    return a.selectionStartColumn < b.selectionStartColumn;
}

fn collapseAtEnds(allocator: Allocator, applied: []const AppliedTextEdit) ![]Selection {
    const selections = try allocator.alloc(Selection, applied.len);
    errdefer allocator.free(selections);
    for (applied, 0..) |edit, index| {
        const position = edit.end;
        selections[index] = Selection.init(position.lineNumber, position.column, position.lineNumber, position.column);
    }
    return selections;
}

const BuiltSession = struct {
    edits: []TextEdit,
    snippets: std.ArrayListUnmanaged(*OneSnippet),
};

fn createEditsAndSnippetsFromEdits(
    allocator: Allocator,
    editor: *Editor,
    snippet_edits: []const SnippetEdit,
    enforce_final_tabstop: bool,
    adjust_whitespace: bool,
    options: InsertOptions,
) !BuiltSession {
    if (snippet_edits.len == 0) {
        return .{ .edits = try allocator.alloc(TextEdit, 0), .snippets = .empty };
    }
    const model = editor.model;
    const snippet = try TextmateSnippet.init(allocator);
    errdefer snippet.deinit();

    const indexed = try allocator.alloc(usize, snippet_edits.len);
    defer allocator.free(indexed);
    for (indexed, 0..) |*slot, index| slot.* = index;
    const SortContext = struct {
        edits: []const SnippetEdit,
        pub fn lessThan(context: @This(), a: usize, b: usize) bool {
            return compareRangesUsingStarts(&context.edits[a].range, &context.edits[b].range) < 0;
        }
    };
    std.mem.sort(usize, indexed, SortContext{ .edits = snippet_edits }, SortContext.lessThan);

    const edits = try allocator.alloc(TextEdit, snippet_edits.len);
    errdefer {
        for (edits) |edit| allocator.free(edit.text);
        allocator.free(edits);
    }
    @memset(edits, .{ .range = Range.init(1, 1, 1, 1), .text = &.{} });

    var parser_state = parser.SnippetParser{};
    var offset: usize = 0;
    var preexisting = std.AutoHashMap(*Marker, void).init(allocator);
    defer preexisting.deinit();

    for (indexed, 0..) |original_index, sorted_index| {
        const edit = snippet_edits[original_index];

        if (sorted_index > 0) {
            const previous = snippet_edits[indexed[sorted_index - 1]];
            const gap_start = previous.range.endPosition();
            const gap_end = edit.range.startPosition();
            const gap_range = Range.init(gap_start.lineNumber, gap_start.column, gap_end.lineNumber, gap_end.column);
            var gap = try model.getValueInRange(gap_range, .TextDefined);
            defer gap.deinit();
            if (gap.items.len > 0) {
                try snippet.appendChild(try snippet.newText(gap.items));
                offset += gap.items.len;
            }
        }

        preexisting.clearRetainingCapacity();
        for (try snippet.walkArena()) |marker| {
            if (marker.kind == .variable) try preexisting.put(marker, {});
        }

        const new_nodes = try parser_state.parseFragment(snippet, edit.template);
        var filter = std.AutoHashMap(*Marker, void).init(allocator);
        defer filter.deinit();
        for (new_nodes) |node| try filter.put(node, {});

        const adjust = if (edit.keep_whitespace) |keep_whitespace| !keep_whitespace else adjust_whitespace;
        const leading = try adjustWhitespace(
            allocator,
            model,
            edit.range.startPosition(),
            adjust,
            snippet,
            &filter,
        );
        allocator.free(leading);

        const edit_selection = selectionFromRange(edit.range, .LTR);
        var resolver_contexts = ResolverContexts.init(editor, edit_selection, original_index, snippet_edits.len, options);
        resolver_contexts.wire();
        var composite = variables.CompositeSnippetVariableResolver{ .resolvers = resolver_contexts.resolvers() };
        for (try snippet.walkArena()) |marker| {
            if (marker.kind == .variable and !preexisting.contains(marker)) {
                _ = try marker.resolveVariable(composite.interface());
            }
        }

        const snippet_text = try snippet.toString(allocator);
        defer allocator.free(snippet_text);
        const fragment = try allocator.dupe(u8, snippet_text[offset..]);
        edits[sorted_index] = .{ .range = edit.range, .text = fragment };
        offset = snippet_text.len;
    }

    try parser_state.ensureFinalTabstop(snippet, enforce_final_tabstop, true);

    var snippets = std.ArrayListUnmanaged(*OneSnippet).empty;
    errdefer snippets.deinit(allocator);
    const one = try OneSnippet.init(allocator, editor, snippet, "");
    try snippets.append(allocator, one);
    return .{ .edits = edits, .snippets = snippets };
}

fn createEditsAndSnippetsFromSelections(
    allocator: Allocator,
    editor: *Editor,
    template: []const u8,
    options: InsertOptions,
    enforce_final_tabstop: bool,
) !BuiltSession {
    const model = editor.model;
    const selections_owned = try editor.getModelSelections();
    defer allocator.free(selections_owned);
    if (selections_owned.len == 0) {
        return .{ .edits = try allocator.alloc(TextEdit, 0), .snippets = .empty };
    }

    const primary = editor.modelSelection();
    const before_selection = try adjustSelection(allocator, model, primary, options.overwrite_before, 0);
    const after_selection = try adjustSelection(allocator, model, primary, 0, options.overwrite_after);
    var first_before = try model.getValueInRange(rangeOfSelection(before_selection), .TextDefined);
    defer first_before.deinit();
    var first_after = try model.getValueInRange(rangeOfSelection(after_selection), .TextDefined);
    defer first_after.deinit();
    const first_line_first_non_whitespace = try model.getLineFirstNonWhitespaceColumn(primary.positionLineNumber);

    const indexed = try allocator.alloc(usize, selections_owned.len);
    defer allocator.free(indexed);
    for (indexed, 0..) |*slot, index| slot.* = index;
    const SortContext = struct {
        selections: []const Selection,
        pub fn lessThan(context: @This(), a: usize, b: usize) bool {
            const left = context.selections[a];
            const right = context.selections[b];
            if (left.selectionStartLineNumber != right.selectionStartLineNumber) {
                return left.selectionStartLineNumber < right.selectionStartLineNumber;
            }
            return left.selectionStartColumn < right.selectionStartColumn;
        }
    };
    std.mem.sort(usize, indexed, SortContext{ .selections = selections_owned }, SortContext.lessThan);

    var edits = try allocator.alloc(TextEdit, selections_owned.len);
    errdefer {
        for (edits) |edit| allocator.free(edit.text);
        allocator.free(edits);
    }
    var snippets = std.ArrayListUnmanaged(*OneSnippet).empty;
    errdefer {
        for (snippets.items) |snippet| snippet.deinit();
        snippets.deinit(allocator);
    }
    const snippet_slots = try allocator.alloc(?*OneSnippet, selections_owned.len);
    defer allocator.free(snippet_slots);
    @memset(snippet_slots, null);
    errdefer for (snippet_slots) |slot| {
        if (slot) |snippet| snippet.deinit();
    };

    for (indexed) |selection_index| {
        const selection = selections_owned[selection_index];
        var extension_before = try adjustSelection(allocator, model, selection, options.overwrite_before, 0);
        var extension_after = try adjustSelection(allocator, model, selection, 0, options.overwrite_after);
        var before_value = try model.getValueInRange(rangeOfSelection(extension_before), .TextDefined);
        defer before_value.deinit();
        if (!std.mem.eql(u8, first_before.items, before_value.items)) {
            extension_before = selection;
        }
        var after_value = try model.getValueInRange(rangeOfSelection(extension_after), .TextDefined);
        defer after_value.deinit();
        if (!std.mem.eql(u8, first_after.items, after_value.items)) {
            extension_after = selection;
        }

        const snippet_selection = Selection.init(
            extension_before.selectionStartLineNumber,
            extension_before.selectionStartColumn,
            extension_after.positionLineNumber,
            extension_after.positionColumn,
        );

        const snippet = try parser.parse(allocator, template, true, enforce_final_tabstop);
        errdefer snippet.deinit();

        const start = snippet_selection.getStartPosition();
        const leading_whitespace = try adjustWhitespace(
            allocator,
            model,
            start,
            options.adjust_whitespace or (selection_index > 0 and first_line_first_non_whitespace != try model.getLineFirstNonWhitespaceColumn(selection.positionLineNumber)),
            snippet,
            null,
        );
        errdefer allocator.free(leading_whitespace);

        var resolver_contexts = ResolverContexts.init(editor, selection, selection_index, selections_owned.len, options);
        resolver_contexts.wire();
        var composite = variables.CompositeSnippetVariableResolver{ .resolvers = resolver_contexts.resolvers() };
        try snippet.resolveVariables(composite.interface());

        const text = try snippet.toString(allocator);
        errdefer allocator.free(text);
        edits[selection_index] = .{ .range = rangeOfSelection(snippet_selection), .text = text };
        const one = try OneSnippet.init(allocator, editor, snippet, leading_whitespace);
        allocator.free(leading_whitespace);
        snippet_slots[selection_index] = one;
    }

    for (snippet_slots, 0..) |slot, index| {
        const one = slot orelse return error.OutOfMemory;
        snippet_slots[index] = null;
        try snippets.append(allocator, one);
    }

    return .{ .edits = edits, .snippets = snippets };
}

const ResolverContexts = struct {
    model: variables.ModelBasedVariableResolver,
    clipboard: variables.ClipboardBasedVariableResolver,
    selection: variables.SelectionBasedVariableResolver,
    comment: variables.CommentBasedVariableResolver,
    time: variables.TimeBasedVariableResolver,
    workspace: variables.WorkspaceBasedVariableResolver,
    random: variables.RandomBasedVariableResolver,
    array: [7]parser.VariableResolver = undefined,

    fn init(
        editor: *Editor,
        selection: Selection,
        selection_index: usize,
        selection_count: usize,
        options: InsertOptions,
    ) ResolverContexts {
        const self: ResolverContexts = .{
            .model = .{ .model_path = editor.path },
            .clipboard = .{
                .clipboard_text = options.clipboard_text,
                .selection_idx = selection_index,
                .selection_count = selection_count,
                .spread = editor.multi_cursor_paste_spread,
            },
            .selection = .{
                .model = editor.model,
                .selection = selection,
                .selection_idx = selection_index,
                .overtyping_capturer = options.overtyping_capturer,
            },
            .comment = .{
                .model = editor.model,
                .selection = selection,
                .language_service = editor.language_service,
            },
            .time = variables.TimeBasedVariableResolver.init(),
            .workspace = .{ .workspace_folder = std.fs.path.dirname(editor.path) },
            .random = .{},
        };
        return self;
    }

    fn wire(self: *ResolverContexts) void {
        self.array = .{
            self.model.interface(),
            self.clipboard.interface(),
            self.selection.interface(),
            self.comment.interface(),
            self.time.interface(),
            self.workspace.interface(),
            self.random.interface(),
        };
    }

    fn resolvers(self: *ResolverContexts) []const parser.VariableResolver {
        return self.array[0..];
    }
};

pub fn adjustWhitespace(
    allocator: Allocator,
    model: *TextModel,
    position: Position,
    adjust_indentation: bool,
    snippet: *TextmateSnippet,
    filter: ?*const std.AutoHashMap(*Marker, void),
) ![]u8 {
    var line = try model.getLineContent(position.lineNumber);
    defer line.deinit();
    const prefix = line.items[0..@min(position.column - 1, line.items.len)];
    const line_leading_whitespace = strings.getLeadingWhitespace(prefix);
    const snippet_allocator = snippet.arenaAllocator();
    var snippet_text_string: ?[]u8 = null;
    defer if (snippet_text_string) |value| allocator.free(value);

    for (try snippet.walkArena()) |marker| {
        if (marker.kind != .text) continue;
        if (marker.parent) |parent| {
            if (parent.kind == .choice) continue;
        }
        if (filter) |active_filter| {
            if (!active_filter.contains(marker)) continue;
        }

        var lines = std.ArrayListUnmanaged([]const u8).empty;
        defer lines.deinit(snippet_allocator);
        try splitLines(snippet_allocator, marker.value, &lines);

        if (adjust_indentation) {
            const offset = snippet.offset(marker);
            if (offset == 0) {
                lines.items[0] = try cursor_type_operations.normalizeIndentation(snippet_allocator, lines.items[0], model.getOptions().indentSize, model.getOptions().insertSpaces);
            } else {
                if (snippet_text_string == null) snippet_text_string = try snippet.toString(allocator);
                const previous = snippet_text_string.?[@intCast(offset - 1)];
                if (previous == '\n' or previous == '\r') {
                    const joined = try std.mem.concat(snippet_allocator, u8, &.{ line_leading_whitespace, lines.items[0] });
                    lines.items[0] = try cursor_type_operations.normalizeIndentation(snippet_allocator, joined, model.getOptions().indentSize, model.getOptions().insertSpaces);
                }
            }
            if (lines.items.len > 1) {
                for (lines.items[1..]) |*line_value| {
                    const joined = try std.mem.concat(snippet_allocator, u8, &.{ line_leading_whitespace, line_value.* });
                    line_value.* = try cursor_type_operations.normalizeIndentation(snippet_allocator, joined, model.getOptions().indentSize, model.getOptions().insertSpaces);
                }
            }
        }

        var new_value = std.ArrayListUnmanaged(u8).empty;
        defer new_value.deinit(snippet_allocator);
        const eol = eolString(model.getEOL());
        for (lines.items, 0..) |line_value, index| {
            if (index > 0) try new_value.appendSlice(snippet_allocator, eol);
            try new_value.appendSlice(snippet_allocator, line_value);
        }

        if (!std.mem.eql(u8, new_value.items, marker.value)) {
            if (marker.parent) |parent| {
                const text = try snippet.newText(new_value.items);
                try parent.replace(marker, &.{text});
                if (snippet_text_string) |value| {
                    allocator.free(value);
                    snippet_text_string = null;
                }
            }
        }
    }
    return allocator.dupe(u8, line_leading_whitespace);
}

fn rangeOfSelection(selection: Selection) Range {
    return Range.init(
        selection.selectionStartLineNumber,
        selection.selectionStartColumn,
        selection.positionLineNumber,
        selection.positionColumn,
    );
}

fn adjustSelection(allocator: Allocator, model: *TextModel, selection: Selection, overwrite_before: usize, overwrite_after: usize) !Selection {
    _ = allocator;
    if (overwrite_before == 0 and overwrite_after == 0) return selection;
    const position_column_before = if (selection.positionColumn > overwrite_before) selection.positionColumn - overwrite_before else 1;
    const position_column_after = selection.positionColumn + overwrite_after;
    const range = model.validateRange(Range.init(
        selection.positionLineNumber,
        position_column_before,
        selection.positionLineNumber,
        position_column_after,
    ));
    return createSelectionWithDirection(
        range.startLineNumber,
        range.startColumn,
        range.endLineNumber,
        range.endColumn,
        selection.getDirection(),
    );
}

fn eolString(eol: anytype) []const u8 {
    return switch (eol) {
        .CRLF => "\r\n",
        else => "\n",
    };
}

fn splitLines(allocator: Allocator, value: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var start: usize = 0;
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] == '\r' or value[index] == '\n') {
            try out.append(allocator, value[start..index]);
            if (value[index] == '\r' and index + 1 < value.len and value[index + 1] == '\n') index += 1;
            start = index + 1;
        }
    }
    try out.append(allocator, value[start..]);
}
