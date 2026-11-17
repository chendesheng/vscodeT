// Port of `src/vs/editor/browser/view/viewController.ts`.
//
// Terminal adaptation: upstream runs `CoreNavigationCommands` against the view
// model. The port takes an explicit `INavigationCommands` sink instead, so the
// TUI can route the commands to its cursor collection while the decision logic
// (multi-cursor modifiers, line/gutter clicks, double-click block selection)
// stays upstream-shaped. The line-content helpers are literal ports.
const std = @import("std");
const Allocator = std.mem.Allocator;

const editor_configuration = @import("../../common/config/editorConfiguration.zig");
const editor_options = @import("../../common/config/editorOptions.zig");
const view_model_mod = @import("../../common/viewModel.zig");
const text_model_mod = @import("../../common/model/textModel.zig");
const strings = @import("../../../base/common/strings.zig");
const Position = @import("../../common/core/position.zig").Position;
const Range = @import("../../common/core/range.zig").Range;
const Selection = @import("../../common/core/selection.zig").Selection;
const standard_token_type = @import("../../common/encodedTokenAttributes.zig").StandardTokenType;

const IEditorConfiguration = editor_configuration.IEditorConfiguration;
const IViewModel = view_model_mod.IViewModel;
const TextModel = text_model_mod.TextModel;
const EditorOption = editor_options.EditorOption;

pub const NavigationCommandRevealType = enum(u8) { regular, minimal, none };

pub const IMouseDispatchData = struct {
    position: Position,
    /// Desired mouse column (e.g. when the position is clamped to the line length).
    mouseColumn: usize,
    revealType: NavigationCommandRevealType,
    startedOnLineNumbers: bool,

    inSelectionMode: bool,
    mouseDownCount: usize,
    altKey: bool,
    ctrlKey: bool,
    metaKey: bool,
    shiftKey: bool,

    leftButton: bool,
    middleButton: bool,
    onInjectedText: bool,
};

/// The navigation commands `dispatchMouse` needs. The TUI supplies an adapter
/// over its cursor collection; tests use a recording sink.
pub const INavigationCommands = struct {
    context: *anyopaque,
    set_selection: *const fn (context: *anyopaque, selection: Selection) void,
    move_to: *const fn (context: *anyopaque, position: Position) void,
    move_to_select: *const fn (context: *anyopaque, position: Position) void,
    column_select: *const fn (context: *anyopaque, position: Position, mouse_column: usize, do_column_select: bool) void,
    create_cursor: *const fn (context: *anyopaque, position: Position, whole_line: bool) void,
    last_cursor_move_to_select: *const fn (context: *anyopaque, position: Position) void,
    word_select: *const fn (context: *anyopaque, position: Position) void,
    word_select_drag: *const fn (context: *anyopaque, position: Position) void,
    last_cursor_word_select: *const fn (context: *anyopaque, position: Position) void,
    line_select: *const fn (context: *anyopaque, position: Position) void,
    line_select_drag: *const fn (context: *anyopaque, position: Position) void,
    last_cursor_line_select: *const fn (context: *anyopaque, position: Position) void,
    last_cursor_line_select_drag: *const fn (context: *anyopaque, position: Position) void,
    select_all: *const fn (context: *anyopaque) void,

    pub fn setSelection(self: INavigationCommands, selection: Selection) void {
        self.set_selection(self.context, selection);
    }
    pub fn moveTo(self: INavigationCommands, position: Position) void {
        self.move_to(self.context, position);
    }
    pub fn moveToSelect(self: INavigationCommands, position: Position) void {
        self.move_to_select(self.context, position);
    }
    pub fn columnSelect(self: INavigationCommands, position: Position, mouse_column: usize, do_column_select: bool) void {
        self.column_select(self.context, position, mouse_column, do_column_select);
    }
    pub fn createCursor(self: INavigationCommands, position: Position, whole_line: bool) void {
        self.create_cursor(self.context, position, whole_line);
    }
    pub fn lastCursorMoveToSelect(self: INavigationCommands, position: Position) void {
        self.last_cursor_move_to_select(self.context, position);
    }
    pub fn wordSelect(self: INavigationCommands, position: Position) void {
        self.word_select(self.context, position);
    }
    pub fn wordSelectDrag(self: INavigationCommands, position: Position) void {
        self.word_select_drag(self.context, position);
    }
    pub fn lastCursorWordSelect(self: INavigationCommands, position: Position) void {
        self.last_cursor_word_select(self.context, position);
    }
    pub fn lineSelect(self: INavigationCommands, position: Position) void {
        self.line_select(self.context, position);
    }
    pub fn lineSelectDrag(self: INavigationCommands, position: Position) void {
        self.line_select_drag(self.context, position);
    }
    pub fn lastCursorLineSelect(self: INavigationCommands, position: Position) void {
        self.last_cursor_line_select(self.context, position);
    }
    pub fn lastCursorLineSelectDrag(self: INavigationCommands, position: Position) void {
        self.last_cursor_line_select_drag(self.context, position);
    }
    pub fn selectAll(self: INavigationCommands) void {
        self.select_all(self.context);
    }
};

/// The `ICommandDelegate` typing/cut callbacks (kept for the view wiring).
pub const ICommandDelegate = struct {
    context: *anyopaque,
    paste: *const fn (context: *anyopaque, text: []const u8, paste_on_new_line: bool, multicursor_text: ?[]const []const u8, mode: ?[]const u8, is_block: bool) void,
    type_text: *const fn (context: *anyopaque, text: []const u8) void,
    composition_type: *const fn (context: *anyopaque, text: []const u8, replace_prev_char_count: usize, replace_next_char_count: usize, position_delta: isize) void,
    start_composition: *const fn (context: *anyopaque) void,
    end_composition: *const fn (context: *anyopaque) void,
    cut: *const fn (context: *anyopaque) void,
};

pub const ViewController = struct {
    configuration: *const IEditorConfiguration,
    view_model: IViewModel,
    model: *TextModel,
    commands: INavigationCommands,

    pub fn init(
        configuration: *const IEditorConfiguration,
        view_model: IViewModel,
        model: *TextModel,
        commands: INavigationCommands,
    ) ViewController {
        return .{
            .configuration = configuration,
            .view_model = view_model,
            .model = model,
            .commands = commands,
        };
    }

    fn optionBool(self: *const ViewController, comptime option: EditorOption) bool {
        const options = self.configuration.options orelse return false;
        return options.get(option);
    }

    fn multiCursorModifier(self: *const ViewController) editor_options.MultiCursorModifier {
        const options = self.configuration.options orelse return .alt_key;
        return options.get(.multiCursorModifier);
    }

    fn hasMulticursorModifier(self: *const ViewController, data: IMouseDispatchData) bool {
        return switch (self.multiCursorModifier()) {
            .alt_key => data.altKey,
            .ctrl_key => data.ctrlKey,
            .meta_key => data.metaKey,
        };
    }

    fn hasNonMulticursorModifier(self: *const ViewController, data: IMouseDispatchData) bool {
        return switch (self.multiCursorModifier()) {
            .alt_key => data.ctrlKey or data.metaKey,
            .ctrl_key => data.altKey or data.metaKey,
            .meta_key => data.ctrlKey or data.altKey,
        };
    }

    fn convertViewToModelPosition(self: *const ViewController, view_position: Position) Position {
        const converter = self.view_model.coordinates_converter;
        return converter.convertViewPositionToModelPosition(converter.context, view_position);
    }

    fn validateViewColumn(self: *const ViewController, view_position: Position) Position {
        const min_column = self.view_model.getLineMinColumn(self.view_model.context, view_position.lineNumber);
        if (view_position.column < min_column) {
            return Position.init(view_position.lineNumber, min_column);
        }
        return view_position;
    }

    /// Selects content inside brackets if the position is right after an
    /// opening bracket or right before a closing bracket.
    pub fn trySelectBracketContent(model: *TextModel, pos: Position) ?Selection {
        // The bracket-pair tree reads the model's tokens; ensure the line has
        // been tokenized when the controller runs outside a view-model render
        // (the browser view model tokenizes the viewport beforehand).
        model.forceTokenization(pos.lineNumber);

        // Right after an opening bracket.
        if (pos.column > 1) {
            const pair = model.bracketPairs().matchBracket(
                Position.init(pos.lineNumber, pos.column - 1),
                null,
            );
            if (pair) |brackets| {
                if (brackets[0].getEndPosition().equals(pos)) {
                    return Selection.fromPositions(brackets[0].getEndPosition(), brackets[1].getStartPosition());
                }
            }
        }

        // Right before a closing bracket.
        const max_column = model.getLineMaxColumn(pos.lineNumber);
        if (pos.column <= max_column) {
            const pair = model.bracketPairs().matchBracket(pos, null);
            if (pair) |brackets| {
                if (brackets[1].getStartPosition().equals(pos)) {
                    return Selection.fromPositions(brackets[0].getEndPosition(), brackets[1].getStartPosition());
                }
            }
        }
        return null;
    }

    /// Selects content inside a string if the position is right after an
    /// opening quote or right before a closing quote.
    pub fn trySelectStringContent(model: *TextModel, pos: Position) ?Selection {
        const line_number = pos.lineNumber;
        const column = pos.column;
        const tokens = model.tokenization();
        if (!tokens.hasAccurateTokensForLine(line_number)) {
            if (tokens.isCheapToTokenize(line_number)) {
                model.forceTokenization(line_number);
            } else {
                return null;
            }
        }

        var line_tokens = tokens.getLineTokens(line_number) catch return null;
        defer line_tokens.deinit();

        var start_index = line_tokens.findTokenIndexAtOffset(column - 1);
        var end_index = start_index;
        while (start_index > 0 and line_tokens.getStandardTokenType(start_index - 1) == .String) {
            start_index -= 1;
        }
        while (end_index + 1 < line_tokens.getCount() and line_tokens.getStandardTokenType(end_index + 1) == .String) {
            end_index += 1;
        }

        // Verify the click is after the starting or before the closing quote.
        const token_start = line_tokens.getStartOffset(start_index);
        const token_end = line_tokens.getEndOffset(end_index);
        if (column != token_start + 2 and column != token_end) {
            return null;
        }

        var line_content = model.getLineContent(line_number) catch return null;
        defer line_content.deinit();
        const content = line_content.items;
        if (token_start >= content.len or token_end > content.len or token_end == 0) return null;

        const first_char = content[token_start];
        if (first_char != '"' and first_char != '\'' and first_char != '`') return null;
        if (content[token_end - 1] != first_char) return null;

        const inner = content[token_start + 1 .. token_end - 1];
        if (strings.containsRTL(inner)) return null;

        return Selection.init(line_number, token_start + 2, line_number, token_end);
    }

    pub fn dispatchMouse(self: *const ViewController, data: IMouseDispatchData) void {
        const selection_clipboard_is_on = @import("builtin").os.tag == .linux and self.optionBool(.selectionClipboard);
        const column_selection = self.optionBool(.columnSelection);
        const scroll_on_middle_click = self.optionBool(.scrollOnMiddleClick);

        if (data.middleButton and !selection_clipboard_is_on) {
            if (!scroll_on_middle_click) {
                self.commands.columnSelect(data.position, data.mouseColumn, data.inSelectionMode);
            }
        } else if (data.startedOnLineNumbers) {
            if (self.hasMulticursorModifier(data)) {
                if (data.inSelectionMode) {
                    self.commands.lastCursorLineSelect(data.position);
                } else {
                    self.commands.createCursor(data.position, true);
                }
            } else {
                if (data.inSelectionMode) {
                    self.commands.lineSelectDrag(data.position);
                } else {
                    self.commands.lineSelect(data.position);
                }
            }
        } else if (data.mouseDownCount >= 4) {
            self.commands.selectAll();
        } else if (data.mouseDownCount == 3) {
            if (self.hasMulticursorModifier(data)) {
                if (data.inSelectionMode) {
                    self.commands.lastCursorLineSelectDrag(data.position);
                } else {
                    self.commands.lastCursorLineSelect(data.position);
                }
            } else {
                if (data.inSelectionMode) {
                    self.commands.lineSelectDrag(data.position);
                } else {
                    self.commands.lineSelect(data.position);
                }
            }
        } else if (data.mouseDownCount == 2) {
            if (!data.onInjectedText) {
                if (self.hasMulticursorModifier(data)) {
                    self.commands.lastCursorWordSelect(data.position);
                } else if (data.inSelectionMode) {
                    self.commands.wordSelectDrag(data.position);
                } else {
                    var selection: ?Selection = null;
                    if (self.optionBool(.doubleClickSelectsBlock)) {
                        const model_position = self.convertViewToModelPosition(data.position);
                        selection = trySelectBracketContent(self.model, model_position) orelse
                            trySelectStringContent(self.model, model_position);
                    }
                    if (selection) |value| {
                        self.commands.setSelection(value);
                    } else {
                        self.commands.wordSelect(data.position);
                    }
                }
            }
        } else {
            if (self.hasMulticursorModifier(data)) {
                if (!self.hasNonMulticursorModifier(data)) {
                    if (data.shiftKey) {
                        self.commands.columnSelect(data.position, data.mouseColumn, true);
                    } else if (data.inSelectionMode) {
                        self.commands.lastCursorMoveToSelect(data.position);
                    } else {
                        self.commands.createCursor(data.position, false);
                    }
                }
            } else if (data.inSelectionMode) {
                if (data.altKey or column_selection) {
                    self.commands.columnSelect(data.position, data.mouseColumn, true);
                } else {
                    self.commands.moveToSelect(data.position);
                }
            } else {
                self.commands.moveTo(self.validateViewColumn(data.position));
            }
        }
    }
};
