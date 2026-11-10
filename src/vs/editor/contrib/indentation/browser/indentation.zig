// Port of the portable parts of
// `src/vs/editor/contrib/indentation/browser/indentation.ts`.
//
// The quick-pick actions (`Indent Using Spaces/Tabs`, tab display size) are
// UI-only and not ported. The commands and reindent helpers are.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const edit_operation = @import("../../../common/core/editOperation.zig");
const ISingleEditOperation = edit_operation.ISingleEditOperation;
const Range = @import("../../../common/core/range.zig").Range;
const selection_mod = @import("../../../common/core/selection.zig");
const Selection = selection_mod.Selection;

const editor_common = @import("../../../common/editorCommon.zig");
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const ICommand = editor_common.ICommand;
const commandOf = editor_common.commandOf;

const registry = @import("../../../common/languages/languageConfigurationRegistry.zig");
const ILanguageConfigurationService = registry.ILanguageConfigurationService;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;

const common_indentation = @import("../common/indentation.zig");

fn appendOwnedText(builder: IEditOperationBuilder, range: Range, text: []const u8) !void {
    try builder.addEditOperation(range, text, false);
}

pub fn getIndentationEditOperations(
    arena: Allocator,
    model: *TextModel,
    builder: IEditOperationBuilder,
    tab_size: usize,
    tabs_to_spaces: bool,
) !void {
    if (model.getLineCount() == 1 and model.getLineMaxColumn(1) == 1) return;

    var line_number: usize = 1;
    while (line_number <= model.getLineCount()) : (line_number += 1) {
        var last_indentation_column = model.getLineFirstNonWhitespaceColumn(line_number) catch 0;
        if (last_indentation_column == 0) {
            last_indentation_column = model.getLineMaxColumn(line_number);
        }
        if (last_indentation_column == 1) continue;

        const original_range = Range.init(line_number, 1, line_number, last_indentation_column);
        const original = try model.getValueInRange(original_range, null);
        defer original.deinit();

        var converted = ArrayList(u8).init(arena);
        if (tabs_to_spaces) {
            for (original.items) |ch| {
                if (ch == '\t') {
                    try converted.appendNTimes(' ', tab_size);
                } else {
                    try converted.append(ch);
                }
            }
        } else {
            var spaces: usize = 0;
            for (original.items) |ch| {
                if (ch == ' ') {
                    spaces += 1;
                    if (spaces == tab_size) {
                        try converted.append('\t');
                        spaces = 0;
                    }
                } else {
                    while (spaces > 0) : (spaces -= 1) try converted.append(' ');
                    try converted.append(ch);
                }
            }
            while (spaces > 0) : (spaces -= 1) try converted.append(' ');
        }

        if (!std.mem.eql(u8, original.items, converted.items)) {
            try appendOwnedText(builder, original_range, converted.items);
        }
    }
}

pub const IndentationToSpacesCommand = struct {
    allocator: Allocator,
    selection: Selection,
    tab_size: usize,
    selection_id: ?u64 = null,

    pub fn init(allocator: Allocator, selection: Selection, tab_size: usize) IndentationToSpacesCommand {
        return .{ .allocator = allocator, .selection = selection, .tab_size = tab_size };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *IndentationToSpacesCommand) ICommand {
        return commandOf(IndentationToSpacesCommand).of(self);
    }

    pub fn getEditOperations(self: *IndentationToSpacesCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        self.selection_id = builder.trackSelection(self.selection);
        try getIndentationEditOperations(arena_state.allocator(), model, builder, self.tab_size, true);
    }

    pub fn computeCursorState(self: *IndentationToSpacesCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        return helper.getTrackedSelection(self.selection_id orelse return self.selection);
    }
};

pub const IndentationToTabsCommand = struct {
    allocator: Allocator,
    selection: Selection,
    tab_size: usize,
    selection_id: ?u64 = null,

    pub fn init(allocator: Allocator, selection: Selection, tab_size: usize) IndentationToTabsCommand {
        return .{ .allocator = allocator, .selection = selection, .tab_size = tab_size };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *IndentationToTabsCommand) ICommand {
        return commandOf(IndentationToTabsCommand).of(self);
    }

    pub fn getEditOperations(self: *IndentationToTabsCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        self.selection_id = builder.trackSelection(self.selection);
        try getIndentationEditOperations(arena_state.allocator(), model, builder, self.tab_size, false);
    }

    pub fn computeCursorState(self: *IndentationToTabsCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        return helper.getTrackedSelection(self.selection_id orelse return self.selection);
    }
};

pub fn reindentLines(
    arena: Allocator,
    model: *TextModel,
    language_configuration_service: ILanguageConfigurationService,
) !ArrayList(ISingleEditOperation) {
    return common_indentation.getReindentEditOperations(
        arena,
        model,
        language_configuration_service,
        1,
        model.getLineCount(),
    );
}

pub fn reindentSelectedLines(
    arena: Allocator,
    model: *TextModel,
    language_configuration_service: ILanguageConfigurationService,
    selections: []const Selection,
) !ArrayList(ISingleEditOperation) {
    var edits = ArrayList(ISingleEditOperation).init(arena);
    errdefer edits.deinit();

    for (selections) |selection| {
        var start_line_number = selection.startLineNumber;
        var end_line_number = selection.endLineNumber;

        if (start_line_number != end_line_number and selection.endColumn == 1) {
            end_line_number -= 1;
        }

        if (start_line_number == 1) {
            if (start_line_number == end_line_number) continue;
        } else {
            start_line_number -= 1;
        }

        var line_edits = try common_indentation.getReindentEditOperations(
            arena,
            model,
            language_configuration_service,
            start_line_number,
            end_line_number,
        );
        defer line_edits.deinit();
        try edits.appendSlice(line_edits.items);
    }

    return edits;
}

pub fn detectIndentation(model: *TextModel) void {
    const options = model.getOptions();
    model.detectIndentation(options.insertSpaces, options.tabSize);
}

pub fn changeIndentation(model: *TextModel, tab_size: usize, insert_spaces: bool, display_size_only: bool) void {
    if (display_size_only) {
        model.updateOptions(.{
            .tabSize = tab_size,
            .indentSize = null,
            .insertSpaces = null,
            .trimAutoWhitespace = null,
            .bracketColorizationOptions = null,
        });
    } else {
        model.updateOptions(.{
            .tabSize = tab_size,
            .indentSize = .{ .number = @intCast(tab_size) },
            .insertSpaces = insert_spaces,
            .trimAutoWhitespace = null,
            .bracketColorizationOptions = null,
        });
    }
}

comptime {
    _ = commandOf(IndentationToSpacesCommand).of;
    _ = commandOf(IndentationToTabsCommand).of;
}
