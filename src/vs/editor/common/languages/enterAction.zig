// Port of `src/vs/editor/common/languages/enterAction.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const range_module = @import("../core/range.zig");
const Range = range_module.Range;

const language_configuration = @import("./languageConfiguration.zig");
const IndentAction = language_configuration.IndentAction;

const editor_options = @import("../config/editorOptions.zig");
const EditorAutoIndentStrategy = editor_options.EditorAutoIndentStrategy;

const registry = @import("./languageConfigurationRegistry.zig");
const getIndentationAtPosition = registry.getIndentationAtPosition;
const ILanguageConfigurationService = registry.ILanguageConfigurationService;
const ResolvedLanguageConfiguration = registry.ResolvedLanguageConfiguration;

const indentation_line_processor = @import("./supports/indentationLineProcessor.zig");
const IndentationContextProcessor = indentation_line_processor.IndentationContextProcessor;

const text_model = @import("../model/textModel.zig");
const TextModel = text_model.TextModel;

/// Describes what to do when the user pressed Enter. All strings are owned by
/// the caller.
pub const EnterActionResult = struct {
    indentAction: IndentAction,
    appendText: []u8,
    removeText: usize,
    indentation: []u8,

    pub fn deinit(self: *EnterActionResult, allocator: Allocator) void {
        allocator.free(self.appendText);
        allocator.free(self.indentation);
    }
};

pub fn getEnterAction(
    allocator: Allocator,
    auto_indent: EditorAutoIndentStrategy,
    model: *TextModel,
    range: Range,
    language_configuration_service: ILanguageConfigurationService,
) !?EnterActionResult {
    model.tokenization().forceTokenization(range.startLineNumber);

    var indentation_context_processor = IndentationContextProcessor.init(allocator, model, language_configuration_service);
    var processed_context_tokens = try indentation_context_processor.getProcessedTokenContextAroundRange(range);
    defer processed_context_tokens.deinit();

    const previous_line_text = processed_context_tokens.previousLineProcessedTokens.getLineContent();
    const before_enter_text = processed_context_tokens.beforeRangeProcessedTokens.getLineContent();
    const after_enter_text = processed_context_tokens.afterRangeProcessedTokens.getLineContent();

    const language_id = model.getLanguageIdAtPosition(range.startLineNumber, range.startColumn);
    var rich_edit_support = language_configuration_service.getLanguageConfiguration(language_id);
    const enter_result = rich_edit_support.onEnter(auto_indent, previous_line_text, before_enter_text, after_enter_text) orelse return null;

    const indent_action = enter_result.indentAction;
    const remove_text = enter_result.removeText orelse 0;

    var append_text = ArrayList(u8).init(allocator);
    errdefer append_text.deinit();

    // We first add `\t` to appendText because enterAction is leveraging
    // appendText and removeText to change indentation.
    if (enter_result.appendText) |text| {
        if (indent_action == .Indent) {
            try append_text.append('\t');
        }
        try append_text.appendSlice(text);
    } else if (indent_action == .Indent or indent_action == .IndentOutdent) {
        try append_text.append('\t');
    }

    var indentation = try getIndentationAtPosition(allocator, model, range.startLineNumber, range.startColumn);
    errdefer allocator.free(indentation);
    if (remove_text > 0) {
        indentation = try shrinkIndentation(allocator, indentation, remove_text);
    }

    return EnterActionResult{
        .indentAction = indent_action,
        .appendText = try append_text.toOwnedSlice(),
        .removeText = remove_text,
        .indentation = indentation,
    };
}

fn shrinkIndentation(allocator: Allocator, indentation: []u8, remove_text: usize) ![]u8 {
    const new_length = indentation.len -| remove_text;
    const result = try allocator.dupe(u8, indentation[0..new_length]);
    allocator.free(indentation);
    return result;
}

test "enterAction decls are analyzed" {
    _ = &getEnterAction;
}
