// Port of `src/vs/editor/contrib/indentation/common/indentation.ts`.
//
// All strings in the returned edit operations are allocated with `arena`;
// callers keep the arena alive until they have applied the edits.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const strings = @import("../../../../base/common/strings.zig");
const EditOperation = @import("../../../common/core/editOperation.zig").EditOperation;
const ISingleEditOperation = @import("../../../common/core/editOperation.zig").ISingleEditOperation;
const normalizeIndentation = @import("../../../common/core/misc/indentation.zig").normalizeIndentation;
const Range = @import("../../../common/core/range.zig").Range;
const StandardTokenType = @import("../../../common/encodedTokenAttributes.zig").StandardTokenType;

const registry = @import("../../../common/languages/languageConfigurationRegistry.zig");
const ILanguageConfigurationService = registry.ILanguageConfigurationService;
const indentation_line_processor = @import("../../../common/languages/supports/indentationLineProcessor.zig");
const ProcessedIndentRulesSupport = indentation_line_processor.ProcessedIndentRulesSupport;
const fromTextModel = indentation_line_processor.fromTextModel;

const shift_command = @import("../../../common/commands/shiftCommand.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;

pub fn getReindentEditOperations(
    arena: Allocator,
    model: *TextModel,
    language_configuration_service: ILanguageConfigurationService,
    start_line_number_: usize,
    end_line_number_: usize,
) !ArrayList(ISingleEditOperation) {
    var edits = ArrayList(ISingleEditOperation).init(arena);
    errdefer edits.deinit();

    if (model.getLineCount() == 1 and model.getLineMaxColumn(1) == 1) {
        return edits;
    }

    const configuration = language_configuration_service.getLanguageConfiguration(model.getLanguageId());
    const indent_rules_support = &(configuration.indentRulesSupport orelse return edits);

    var processed = ProcessedIndentRulesSupport.init(
        arena,
        fromTextModel(model),
        indent_rules_support,
        language_configuration_service,
    );

    var start_line_number = start_line_number_;
    const end_line_number = @min(end_line_number_, model.getLineCount());

    while (start_line_number <= end_line_number) {
        const ignore = try processed.shouldIgnore(start_line_number, null);
        if (!ignore) break;
        start_line_number += 1;
    }

    if (start_line_number > end_line_number -| 1) {
        return edits;
    }

    const options = model.getOptions();
    const tab_size = options.tabSize;
    const indent_size = options.indentSize;
    const insert_spaces = options.insertSpaces;

    const shiftIndent = struct {
        fn call(
            allocator: Allocator,
            indentation: []const u8,
            count: usize,
            tabs: usize,
            indent: usize,
            spaces: bool,
        ) ![]const u8 {
            const effective_count = if (count == 0) 1 else count;
            return shift_command.shiftIndent(allocator, indentation, indentation.len + effective_count, tabs, indent, spaces);
        }
    }.call;

    const unshiftIndent = struct {
        fn call(
            allocator: Allocator,
            indentation: []const u8,
            count: usize,
            tabs: usize,
            indent: usize,
            spaces: bool,
        ) ![]const u8 {
            const effective_count = if (count == 0) 1 else count;
            return shift_command.unshiftIndent(allocator, indentation, indentation.len + effective_count, tabs, indent, spaces);
        }
    }.call;

    const first_line = try model.getLineContent(start_line_number);
    defer first_line.deinit();
    var global_indent = strings.getLeadingWhitespace(first_line.items);
    var ideal_indent_for_next_line = global_indent;

    if (try processed.shouldIncrease(start_line_number, null)) {
        ideal_indent_for_next_line = try shiftIndent(arena, ideal_indent_for_next_line, 1, tab_size, indent_size, insert_spaces);
        global_indent = try shiftIndent(arena, global_indent, 1, tab_size, indent_size, insert_spaces);
    } else if (try processed.shouldIndentNextLine(start_line_number, null)) {
        ideal_indent_for_next_line = try shiftIndent(arena, ideal_indent_for_next_line, 1, tab_size, indent_size, insert_spaces);
    }

    start_line_number += 1;

    var line_number = start_line_number;
    while (line_number <= end_line_number) : (line_number += 1) {
        if (try doesLineStartWithString(model, line_number)) continue;

        const line = try model.getLineContent(line_number);
        defer line.deinit();
        const old_indentation = strings.getLeadingWhitespace(line.items);
        const current_ideal_indent = ideal_indent_for_next_line;

        if (try processed.shouldDecrease(line_number, current_ideal_indent)) {
            ideal_indent_for_next_line = try unshiftIndent(arena, ideal_indent_for_next_line, 1, tab_size, indent_size, insert_spaces);
            global_indent = try unshiftIndent(arena, global_indent, 1, tab_size, indent_size, insert_spaces);
        }

        if (!std.mem.eql(u8, old_indentation, ideal_indent_for_next_line)) {
            const normalized = try normalizeIndentation(arena, ideal_indent_for_next_line, indent_size, insert_spaces);
            try edits.append(EditOperation.replaceMove(
                Range.init(line_number, 1, line_number, old_indentation.len + 1),
                normalized,
            ));
        }

        if (try processed.shouldIgnore(line_number, null)) {
            continue;
        } else if (try processed.shouldIncrease(line_number, current_ideal_indent)) {
            global_indent = try shiftIndent(arena, global_indent, 1, tab_size, indent_size, insert_spaces);
            ideal_indent_for_next_line = global_indent;
        } else if (try processed.shouldIndentNextLine(line_number, current_ideal_indent)) {
            ideal_indent_for_next_line = try shiftIndent(arena, ideal_indent_for_next_line, 1, tab_size, indent_size, insert_spaces);
        } else {
            ideal_indent_for_next_line = global_indent;
        }
    }

    return edits;
}

fn doesLineStartWithString(model: *TextModel, line_number: usize) !bool {
    if (!model.tokenization().isCheapToTokenize(line_number)) return false;
    var line_tokens = try model.tokenization().getLineTokens(line_number);
    defer line_tokens.deinit();
    return line_tokens.getStandardTokenType(0) == StandardTokenType.String;
}
