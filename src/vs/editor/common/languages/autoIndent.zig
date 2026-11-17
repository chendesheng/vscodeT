// Port of `src/vs/editor/common/languages/autoIndent.ts`.
//
// Because there is no garbage collector, every function that produces strings
// takes an allocator and returns owned slices; callers free them with the same
// allocator.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const strings = @import("../../../base/common/strings.zig");

const range_module = @import("../core/range.zig");
const Range = range_module.Range;
const Position = @import("../core/position.zig").Position;

const language_configuration = @import("./languageConfiguration.zig");
const IndentAction = language_configuration.IndentAction;
const EnterAction = language_configuration.EnterAction;
const StandardAutoClosingPairConditional = language_configuration.StandardAutoClosingPairConditional;

const editor_options = @import("../config/editorOptions.zig");
const EditorAutoIndentStrategy = editor_options.EditorAutoIndentStrategy;

const registry = @import("./languageConfigurationRegistry.zig");
const ILanguageConfigurationService = registry.ILanguageConfigurationService;
const ResolvedLanguageConfiguration = registry.ResolvedLanguageConfiguration;

const line_tokens = @import("../tokens/lineTokens.zig");
const LineTokens = line_tokens.LineTokens;

const indentation_line_processor = @import("./supports/indentationLineProcessor.zig");
pub const IVirtualModel = indentation_line_processor.IVirtualModel;
const IndentationContextProcessor = indentation_line_processor.IndentationContextProcessor;
const ProcessedIndentRulesSupport = indentation_line_processor.ProcessedIndentRulesSupport;
const isLanguageDifferentFromLineStart = indentation_line_processor.isLanguageDifferentFromLineStart;
const fromTextModel = indentation_line_processor.fromTextModel;

const indent_rules = @import("./supports/indentRules.zig");
const IndentRulesSupport = indent_rules.IndentRulesSupport;
const IndentMetadata = indent_rules.IndentMetadata;

const text_model = @import("../model/textModel.zig");
const TextModel = text_model.TextModel;

pub const IIndentConverter = struct {
    context: *anyopaque,
    shiftIndentFn: *const fn (context: *anyopaque, allocator: Allocator, indentation: []const u8) anyerror![]u8,
    unshiftIndentFn: *const fn (context: *anyopaque, allocator: Allocator, indentation: []const u8) anyerror![]u8,
    normalizeIndentationFn: ?*const fn (context: *anyopaque, allocator: Allocator, indentation: []const u8) anyerror![]u8 = null,

    pub fn shiftIndent(self: IIndentConverter, allocator: Allocator, indentation: []const u8) ![]u8 {
        return self.shiftIndentFn(self.context, allocator, indentation);
    }

    pub fn unshiftIndent(self: IIndentConverter, allocator: Allocator, indentation: []const u8) ![]u8 {
        return self.unshiftIndentFn(self.context, allocator, indentation);
    }
};

/// The result of `getInheritIndentForLine`.
pub const IndentResult = struct {
    indentation: []u8,
    action: ?IndentAction,
    line: ?usize,

    pub fn deinit(self: *IndentResult, allocator: Allocator) void {
        allocator.free(self.indentation);
        self.indentation = &.{};
    }
};

pub const BeforeAfterIndent = struct {
    beforeEnter: []u8,
    afterEnter: []u8,

    pub fn deinit(self: *BeforeAfterIndent, allocator: Allocator) void {
        allocator.free(self.beforeEnter);
        allocator.free(self.afterEnter);
    }
};

fn isWhitespaceOnly(text: []const u8) bool {
    for (text) |character| {
        if (!std.ascii.isWhitespace(character)) {
            return false;
        }
    }
    return true;
}

/// Matches `/^\s+$/`, i.e. non-empty and only whitespace.
fn isNonEmptyWhitespace(text: []const u8) bool {
    return text.len > 0 and isWhitespaceOnly(text);
}

fn leadingWhitespaceDup(allocator: Allocator, text: []const u8) ![]u8 {
    return allocator.dupe(u8, strings.getLeadingWhitespace(text));
}

/// Get the nearest preceding line which doesn't match the unindent pattern or
/// contains only whitespace.
/// Result:
///   -1: ran into the boundary of embedded languages
///    0: every line above is invalid
///  else: nearest preceding line of the same language
fn getPrecedingValidLine(
    allocator: Allocator,
    model: IVirtualModel,
    line_number: usize,
    processed_indent_rules_support: *ProcessedIndentRulesSupport,
) !isize {
    const language_id = model.getLanguageIdAtPosition(line_number, 0);
    if (line_number > 1) {
        var result_line_number: isize = -1;
        var last_line_number = line_number - 1;
        while (last_line_number > 0) : (last_line_number -= 1) {
            if (!std.mem.eql(u8, model.getLanguageIdAtPosition(last_line_number, 0), language_id)) {
                return result_line_number;
            }
            const text = try model.getLineContent(allocator, last_line_number);
            defer allocator.free(text);
            if (try processed_indent_rules_support.shouldIgnore(last_line_number, null) or isNonEmptyWhitespace(text) or text.len == 0) {
                result_line_number = @intCast(last_line_number);
                continue;
            }

            return @intCast(last_line_number);
        }
    }

    return -1;
}

/// Get inherited indentation from above lines.
///
/// 1. Find the nearest preceding line which doesn't match `unIndentedLinePattern`.
/// 2. If this line matches `indentNextLinePattern` or `increaseIndentPattern`,
///    the indent level of `lineNumber` should be one greater than this line.
/// 3. If this line doesn't match any indent rules, check whether the line above
///    it matches `indentNextLinePattern`; if so, go upward until a line whose
///    indent is not temporary is found.
/// 4. Otherwise return null and leave the indentation of `lineNumber` alone.
pub fn getInheritIndentForLine(
    allocator: Allocator,
    auto_indent: EditorAutoIndentStrategy,
    model: IVirtualModel,
    line_number: usize,
    honor_intentional_indent: bool,
    language_configuration_service: ILanguageConfigurationService,
) !?IndentResult {
    if (@backingInt(auto_indent) < @backingInt(EditorAutoIndentStrategy.Full)) {
        return null;
    }

    var configuration = language_configuration_service.getLanguageConfiguration(model.getLanguageId());
    const indent_rules_support = if (configuration.indentRulesSupport) |*support| support else return null;

    var processed_indent_rules_support = ProcessedIndentRulesSupport.init(
        allocator,
        model,
        indent_rules_support,
        language_configuration_service,
    );

    if (line_number <= 1) {
        return IndentResult{ .indentation = try allocator.dupe(u8, ""), .action = null, .line = null };
    }

    // Use no indent if this is the first non-blank line
    var prior_line_number = line_number - 1;
    while (prior_line_number > 0) : (prior_line_number -= 1) {
        const content = try model.getLineContent(allocator, prior_line_number);
        defer allocator.free(content);
        if (content.len != 0) {
            break;
        }
        if (prior_line_number == 1) {
            return IndentResult{ .indentation = try allocator.dupe(u8, ""), .action = null, .line = null };
        }
    }

    const preceding_un_ignored_line = try getPrecedingValidLine(allocator, model, line_number, &processed_indent_rules_support);
    if (preceding_un_ignored_line < 0) {
        return null;
    } else if (preceding_un_ignored_line < 1) {
        return IndentResult{ .indentation = try allocator.dupe(u8, ""), .action = null, .line = null };
    }
    const preceding_line: usize = @intCast(preceding_un_ignored_line);

    if (try processed_indent_rules_support.shouldIncrease(preceding_line, null) or
        try processed_indent_rules_support.shouldIndentNextLine(preceding_line, null))
    {
        const content = try model.getLineContent(allocator, preceding_line);
        defer allocator.free(content);
        return IndentResult{
            .indentation = try leadingWhitespaceDup(allocator, content),
            .action = .Indent,
            .line = preceding_line,
        };
    } else if (try processed_indent_rules_support.shouldDecrease(preceding_line, null)) {
        const content = try model.getLineContent(allocator, preceding_line);
        defer allocator.free(content);
        return IndentResult{
            .indentation = try leadingWhitespaceDup(allocator, content),
            .action = null,
            .line = preceding_line,
        };
    }

    // `preceding_line` cannot be ignored, doesn't increase the indent of the
    // following lines and doesn't increase just the next line, so the current
    // line is not affected by it and we have to look further up.
    if (preceding_line == 1) {
        const content = try model.getLineContent(allocator, preceding_line);
        defer allocator.free(content);
        return IndentResult{
            .indentation = try leadingWhitespaceDup(allocator, content),
            .action = null,
            .line = preceding_line,
        };
    }

    const previous_line = preceding_line - 1;
    const previous_line_content = try model.getLineContent(allocator, previous_line);
    defer allocator.free(previous_line_content);
    const previous_line_indent_metadata = indent_rules_support.getIndentMetadata(previous_line_content);

    if (!previous_line_indent_metadata.increase and !previous_line_indent_metadata.decrease and
        previous_line_indent_metadata.indentNextLine)
    {
        var stop_line: usize = 0;
        var i = previous_line - 1;
        while (i > 0) : (i -= 1) {
            if (try processed_indent_rules_support.shouldIndentNextLine(i, null)) {
                continue;
            }
            stop_line = i;
            break;
        }

        const content = try model.getLineContent(allocator, stop_line + 1);
        defer allocator.free(content);
        return IndentResult{
            .indentation = try leadingWhitespaceDup(allocator, content),
            .action = null,
            .line = stop_line + 1,
        };
    }

    if (honor_intentional_indent) {
        const content = try model.getLineContent(allocator, preceding_line);
        defer allocator.free(content);
        return IndentResult{
            .indentation = try leadingWhitespaceDup(allocator, content),
            .action = null,
            .line = preceding_line,
        };
    }

    // Search from preceding_line until we find a line whose indent is not
    // temporary.
    var i = preceding_line;
    while (i > 0) : (i -= 1) {
        if (try processed_indent_rules_support.shouldIncrease(i, null)) {
            const content = try model.getLineContent(allocator, i);
            defer allocator.free(content);
            return IndentResult{
                .indentation = try leadingWhitespaceDup(allocator, content),
                .action = .Indent,
                .line = i,
            };
        } else if (try processed_indent_rules_support.shouldIndentNextLine(i, null)) {
            var stop_line: usize = 0;
            var j = i - 1;
            while (j > 0) : (j -= 1) {
                if (try processed_indent_rules_support.shouldIndentNextLine(i, null)) {
                    continue;
                }
                stop_line = j;
                break;
            }

            const content = try model.getLineContent(allocator, stop_line + 1);
            defer allocator.free(content);
            return IndentResult{
                .indentation = try leadingWhitespaceDup(allocator, content),
                .action = null,
                .line = stop_line + 1,
            };
        } else if (try processed_indent_rules_support.shouldDecrease(i, null)) {
            const content = try model.getLineContent(allocator, i);
            defer allocator.free(content);
            return IndentResult{
                .indentation = try leadingWhitespaceDup(allocator, content),
                .action = null,
                .line = i,
            };
        }
    }

    const first_line_content = try model.getLineContent(allocator, 1);
    defer allocator.free(first_line_content);
    return IndentResult{
        .indentation = try leadingWhitespaceDup(allocator, first_line_content),
        .action = null,
        .line = 1,
    };
}

pub fn getGoodIndentForLine(
    allocator: Allocator,
    auto_indent: EditorAutoIndentStrategy,
    virtual_model: IVirtualModel,
    language_id: []const u8,
    line_number: usize,
    indent_converter: IIndentConverter,
    language_configuration_service: ILanguageConfigurationService,
) !?[]u8 {
    if (@backingInt(auto_indent) < @backingInt(EditorAutoIndentStrategy.Full)) {
        return null;
    }

    var rich_edit_support = language_configuration_service.getLanguageConfiguration(language_id);
    if (rich_edit_support.indentRulesSupport == null) {
        return null;
    }
    const indent_rules_support = &rich_edit_support.indentRulesSupport.?;

    var processed_indent_rules_support = ProcessedIndentRulesSupport.init(
        allocator,
        virtual_model,
        indent_rules_support,
        language_configuration_service,
    );

    var indent = try getInheritIndentForLine(allocator, auto_indent, virtual_model, line_number, true, language_configuration_service);
    if (indent == null) {
        return null;
    }
    defer indent.?.deinit(allocator);

    // Apply enter action as long as there are only whitespace lines between the
    // inherited line and this line.
    if (indent.?.line) |inherit_line| {
        var should_apply_enter_rules = true;
        var in_between_line = inherit_line;
        while (in_between_line + 1 < line_number) : (in_between_line += 1) {
            const content = try virtual_model.getLineContent(allocator, in_between_line);
            defer allocator.free(content);
            if (!isWhitespaceOnly(content)) {
                should_apply_enter_rules = false;
                break;
            }
        }

        if (should_apply_enter_rules) {
            const inherit_line_content = try virtual_model.getLineContent(allocator, inherit_line);
            defer allocator.free(inherit_line_content);
            if (ResolvedLanguageConfiguration.onEnter(auto_indent, "", inherit_line_content, "")) |enter_result| {
                var indentation = ArrayList(u8).init(allocator);
                defer indentation.deinit();
                try indentation.appendSlice(strings.getLeadingWhitespace(inherit_line_content));

                if (enter_result.removeText) |remove_text| {
                    indentation.shrinkRetainingCapacity(indentation.items.len -| remove_text);
                }

                if (enter_result.indentAction == .Indent or enter_result.indentAction == .IndentOutdent) {
                    const shifted = try indent_converter.shiftIndent(allocator, indentation.items);
                    defer allocator.free(shifted);
                    indentation.clearRetainingCapacity();
                    try indentation.appendSlice(shifted);
                } else if (enter_result.indentAction == .Outdent) {
                    const unshifted = try indent_converter.unshiftIndent(allocator, indentation.items);
                    defer allocator.free(unshifted);
                    indentation.clearRetainingCapacity();
                    try indentation.appendSlice(unshifted);
                }

                if (try processed_indent_rules_support.shouldDecrease(line_number, null)) {
                    const unshifted = try indent_converter.unshiftIndent(allocator, indentation.items);
                    defer allocator.free(unshifted);
                    indentation.clearRetainingCapacity();
                    try indentation.appendSlice(unshifted);
                }

                if (enter_result.appendText) |append_text| {
                    try indentation.appendSlice(append_text);
                }

                return try leadingWhitespaceDup(allocator, indentation.items);
            }
        }
    }

    if (try processed_indent_rules_support.shouldDecrease(line_number, null)) {
        if (indent.?.action == .Indent) {
            return try allocator.dupe(u8, indent.?.indentation);
        }
        return try indent_converter.unshiftIndent(allocator, indent.?.indentation);
    }

    if (indent.?.action == .Indent) {
        return try indent_converter.shiftIndent(allocator, indent.?.indentation);
    }
    return try allocator.dupe(u8, indent.?.indentation);
}

pub fn getIndentForEnter(
    allocator: Allocator,
    auto_indent: EditorAutoIndentStrategy,
    model: *TextModel,
    range: Range,
    indent_converter: IIndentConverter,
    language_configuration_service: ILanguageConfigurationService,
) !?BeforeAfterIndent {
    if (@backingInt(auto_indent) < @backingInt(EditorAutoIndentStrategy.Full)) {
        return null;
    }
    const language_id = model.getLanguageIdAtPosition(range.startLineNumber, range.startColumn);
    var configuration = language_configuration_service.getLanguageConfiguration(language_id);
    const indent_rules_support = if (configuration.indentRulesSupport) |*support| support else return null;

    model.tokenization().forceTokenization(range.startLineNumber);
    var indentation_context_processor = IndentationContextProcessor.init(allocator, model, language_configuration_service);
    var processed_context_tokens = try indentation_context_processor.getProcessedTokenContextAroundRange(range);
    defer processed_context_tokens.deinit();

    const after_enter_processed_tokens = &processed_context_tokens.afterRangeProcessedTokens;
    const before_enter_processed_tokens = &processed_context_tokens.beforeRangeProcessedTokens;
    const before_enter_indent = strings.getLeadingWhitespace(before_enter_processed_tokens.getLineContent());

    var virtual_model = createVirtualModelWithModifiedTokensAtLine(
        allocator,
        model,
        range.startLineNumber,
        before_enter_processed_tokens,
    );

    const language_is_different_from_line_start = try isLanguageDifferentFromLineStart(model, range.startPosition());
    var current_line = try model.getLineContent(range.startLineNumber);
    defer current_line.deinit();
    const current_line_indent = strings.getLeadingWhitespace(current_line.items);

    var after_enter_action = try getInheritIndentForLine(
        allocator,
        auto_indent,
        virtual_model.virtualModel(),
        range.startLineNumber + 1,
        true,
        language_configuration_service,
    );
    if (after_enter_action == null) {
        return BeforeAfterIndent{
            .beforeEnter = try allocator.dupe(u8, if (language_is_different_from_line_start) current_line_indent else before_enter_indent),
            .afterEnter = try allocator.dupe(u8, if (language_is_different_from_line_start) current_line_indent else before_enter_indent),
        };
    }
    defer after_enter_action.?.deinit(allocator);

    var after_enter_indent: []u8 = undefined;
    const base_indent = if (language_is_different_from_line_start) current_line_indent else after_enter_action.?.indentation;
    if (after_enter_action.?.action == .Indent) {
        after_enter_indent = try indent_converter.shiftIndent(allocator, base_indent);
    } else {
        after_enter_indent = try allocator.dupe(u8, base_indent);
    }
    errdefer allocator.free(after_enter_indent);

    if (indent_rules_support.shouldDecrease(after_enter_processed_tokens.getLineContent())) {
        const unshifted = try indent_converter.unshiftIndent(allocator, after_enter_indent);
        allocator.free(after_enter_indent);
        after_enter_indent = unshifted;
    }

    return BeforeAfterIndent{
        .beforeEnter = try allocator.dupe(u8, if (language_is_different_from_line_start) current_line_indent else before_enter_indent),
        .afterEnter = after_enter_indent,
    };
}

/// Configuration needed by `getIndentActionForType` that upstream reads from
/// `CursorConfiguration`.
pub const IndentActionTypeConfig = struct {
    autoIndent: EditorAutoIndentStrategy,
    autoClosingPairsOpenByEnd: ?*const std.StringHashMap([]StandardAutoClosingPairConditional) = null,
};

/// We should always allow intentional indentation. It means, if users change
/// the indentation of `line_number` and the content of this line doesn't match
/// `decreaseIndentPattern`, we should not adjust the indentation.
pub fn getIndentActionForType(
    allocator: Allocator,
    config: IndentActionTypeConfig,
    model: *TextModel,
    range: Range,
    ch: []const u8,
    indent_converter: IIndentConverter,
    language_configuration_service: ILanguageConfigurationService,
) !?[]u8 {
    const auto_indent = config.autoIndent;
    if (@backingInt(auto_indent) < @backingInt(EditorAutoIndentStrategy.Full)) {
        return null;
    }
    const language_is_different_from_line_start = try isLanguageDifferentFromLineStart(model, range.startPosition());
    if (language_is_different_from_line_start) {
        // this line has mixed languages and indentation rules will not work
        return null;
    }

    const language_id = model.getLanguageIdAtPosition(range.startLineNumber, range.startColumn);
    var configuration = language_configuration_service.getLanguageConfiguration(language_id);
    const indent_rules_support = if (configuration.indentRulesSupport) |*support| support else return null;

    var indentation_context_processor = IndentationContextProcessor.init(allocator, model, language_configuration_service);
    var processed_context_tokens = try indentation_context_processor.getProcessedTokenContextAroundRange(range);
    defer processed_context_tokens.deinit();

    const before_range_text = processed_context_tokens.beforeRangeProcessedTokens.getLineContent();
    const after_range_text = processed_context_tokens.afterRangeProcessedTokens.getLineContent();

    var text_around_range = ArrayList(u8).init(allocator);
    defer text_around_range.deinit();
    try text_around_range.appendSlice(before_range_text);
    try text_around_range.appendSlice(after_range_text);

    var text_around_range_with_character = ArrayList(u8).init(allocator);
    defer text_around_range_with_character.deinit();
    try text_around_range_with_character.appendSlice(before_range_text);
    try text_around_range_with_character.appendSlice(ch);
    try text_around_range_with_character.appendSlice(after_range_text);

    // If the previous content already matches the decreaseIndentPattern, the
    // indentation of this line should already be adjusted; users might have
    // changed the indentation by purpose and we honor that.
    if (!indent_rules_support.shouldDecrease(text_around_range.items) and
        indent_rules_support.shouldDecrease(text_around_range_with_character.items))
    {
        var r = try getInheritIndentForLine(allocator, auto_indent, fromTextModel(model), range.startLineNumber, false, language_configuration_service);
        if (r == null) {
            return null;
        }
        defer r.?.deinit(allocator);

        if (r.?.action != .Indent) {
            return try indent_converter.unshiftIndent(allocator, r.?.indentation);
        }
        return try allocator.dupe(u8, r.?.indentation);
    }

    if (range.isEmpty() and range.startLineNumber > 1) {
        const previous_line = try model.getLineContent(range.startLineNumber - 1);
        defer previous_line.deinit();
        if (indent_rules_support.shouldIndentNextLine(previous_line.items) and
            indent_rules_support.shouldIncrease(text_around_range_with_character.items))
        {
            var inherited_indentation_data = try getInheritIndentForLine(
                allocator,
                auto_indent,
                fromTextModel(model),
                range.startLineNumber,
                false,
                language_configuration_service,
            );
            if (inherited_indentation_data != null) {
                defer inherited_indentation_data.?.deinit(allocator);
                const inherited_indentation = inherited_indentation_data.?.indentation;

                var current_line = try model.getLineContent(range.startLineNumber);
                defer current_line.deinit();
                const actual_current_indentation = strings.getLeadingWhitespace(current_line.items);
                const inferred_current_indentation = try indent_converter.shiftIndent(allocator, inherited_indentation);
                defer allocator.free(inferred_current_indentation);

                // If the inferred current indentation is not equal to the
                // actual one, the indentation was intentionally changed.
                const inferred_indentation_equals_actual = std.mem.eql(u8, inferred_current_indentation, actual_current_indentation);
                const text_around_range_contains_only_whitespace = isWhitespaceOnly(text_around_range.items);

                var auto_closing_pair_exists = false;
                if (config.autoClosingPairsOpenByEnd) |pairs| {
                    if (pairs.get(ch)) |auto_closing_pairs| {
                        auto_closing_pair_exists = auto_closing_pairs.len > 0;
                    }
                }
                const is_ch_first_non_whitespace_character_and_in_auto_closing_pair = auto_closing_pair_exists and text_around_range_contains_only_whitespace;
                if (inferred_indentation_equals_actual and is_ch_first_non_whitespace_character_and_in_auto_closing_pair) {
                    return try allocator.dupe(u8, inherited_indentation);
                }
            }
        }
    }

    return null;
}

pub fn getIndentMetadata(
    model: *TextModel,
    line_number: usize,
    language_configuration_service: ILanguageConfigurationService,
) ?IndentMetadata {
    var configuration = language_configuration_service.getLanguageConfiguration(model.getLanguageId());
    const indent_rules_support = if (configuration.indentRulesSupport) |*support| support else return null;
    if (line_number < 1 or line_number > model.getLineCount()) {
        return null;
    }
    const content = model.getLineContent(line_number) catch return null;
    defer content.deinit();
    return indent_rules_support.getIndentMetadata(content.items);
}

/// Virtual model that returns the processed tokens for one modified line.
const ModifiedTokensVirtualModel = struct {
    allocator: Allocator,
    model: *TextModel,
    modified_line_number: usize,
    modified_tokens: *const LineTokens,

    fn virtualModel(self: *ModifiedTokensVirtualModel) IVirtualModel {
        return .{
            .context = self,
            .getLineTokensFn = struct {
                fn get(context: *anyopaque, allocator: Allocator, line_number: usize) anyerror!LineTokens {
                    const self_: *ModifiedTokensVirtualModel = @ptrCast(@alignCast(context));
                    if (line_number == self_.modified_line_number) {
                        return self_.modified_tokens.clone(allocator);
                    }
                    return self_.model.tokenization().getLineTokens(line_number);
                }
            }.get,
            .getLanguageIdFn = struct {
                fn get(context: *anyopaque) []const u8 {
                    const self_: *ModifiedTokensVirtualModel = @ptrCast(@alignCast(context));
                    return self_.model.getLanguageId();
                }
            }.get,
            .getLanguageIdAtPositionFn = struct {
                fn get(context: *anyopaque, line_number: usize, column: usize) []const u8 {
                    const self_: *ModifiedTokensVirtualModel = @ptrCast(@alignCast(context));
                    return self_.model.getLanguageIdAtPosition(line_number, column);
                }
            }.get,
            .forceTokenizationFn = struct {
                fn force(context: *anyopaque, line_number: usize) void {
                    const self_: *ModifiedTokensVirtualModel = @ptrCast(@alignCast(context));
                    self_.model.tokenization().forceTokenization(line_number);
                }
            }.force,
            .getLineContentFn = struct {
                fn get(context: *anyopaque, allocator: Allocator, line_number: usize) anyerror![]u8 {
                    const self_: *ModifiedTokensVirtualModel = @ptrCast(@alignCast(context));
                    if (line_number == self_.modified_line_number) {
                        return allocator.dupe(u8, self_.modified_tokens.getLineContent());
                    }
                    var content = try self_.model.getLineContent(line_number);
                    defer content.deinit();
                    return allocator.dupe(u8, content.items);
                }
            }.get,
        };
    }
};

fn createVirtualModelWithModifiedTokensAtLine(
    allocator: Allocator,
    model: *TextModel,
    modified_line_number: usize,
    modified_tokens: *const LineTokens,
) ModifiedTokensVirtualModel {
    return .{
        .allocator = allocator,
        .model = model,
        .modified_line_number = modified_line_number,
        .modified_tokens = modified_tokens,
    };
}

test "autoIndent decls are analyzed" {
    _ = &getIndentForEnter;
    _ = &getIndentActionForType;
    _ = &getIndentMetadata;
    _ = &getGoodIndentForLine;
    _ = &getInheritIndentForLine;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const regexp = @import("../../../../support/regexp.zig");
const RegExp = regexp.RegExp;
const LanguageConfiguration = language_configuration.LanguageConfiguration;
const IndentationRule = language_configuration.IndentationRule;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const LanguageConfigurationServiceChangeEvent = registry.LanguageConfigurationServiceChangeEvent;

const TestLanguage = struct {
    var decoder: LanguageIdCodec = undefined;
    var configuration: ResolvedLanguageConfiguration = undefined;
    var lines: []const []const u8 = &.{};
};

fn testGetLanguageConfiguration(_: []const u8) ResolvedLanguageConfiguration {
    return TestLanguage.configuration;
}

fn testOnDidChange(_: LanguageConfigurationServiceChangeEvent) void {}

fn testRegister(_: []const u8, _: LanguageConfiguration, _: ?usize) void {}

fn testService() ILanguageConfigurationService {
    return .{
        .onDidChange = testOnDidChange,
        .register = testRegister,
        .getLanguageConfiguration = testGetLanguageConfiguration,
    };
}

fn testLineTokens(_: *anyopaque, allocator: Allocator, line_number: usize) anyerror!LineTokens {
    var content = ArrayList(u8).init(allocator);
    errdefer content.deinit();
    try content.appendSlice(TestLanguage.lines[line_number - 1]);
    return LineTokens.createEmpty(allocator, content, &TestLanguage.decoder);
}

fn testLineContent(_: *anyopaque, allocator: Allocator, line_number: usize) anyerror![]u8 {
    return allocator.dupe(u8, TestLanguage.lines[line_number - 1]);
}

fn testForceTokenization(_: *anyopaque, _: usize) void {}

fn testGetLanguageId(_: *anyopaque) []const u8 {
    return "test";
}

fn testGetLanguageIdAtPosition(_: *anyopaque, _: usize, _: usize) []const u8 {
    return "test";
}

fn testVirtualModel() IVirtualModel {
    return .{
        .context = @ptrFromInt(@alignOf(usize)),
        .getLineTokensFn = testLineTokens,
        .getLanguageIdFn = testGetLanguageId,
        .getLanguageIdAtPositionFn = testGetLanguageIdAtPosition,
        .forceTokenizationFn = testForceTokenization,
        .getLineContentFn = testLineContent,
    };
}

const SpacesConverter = struct {
    fn shift(_: *anyopaque, allocator: Allocator, indentation: []const u8) anyerror![]u8 {
        var result = ArrayList(u8).init(allocator);
        errdefer result.deinit();
        try result.appendSlice(indentation);
        try result.appendSlice("    ");
        return result.toOwnedSlice();
    }

    fn unshift(_: *anyopaque, allocator: Allocator, indentation: []const u8) anyerror![]u8 {
        var removed: usize = 0;
        while (removed < 4 and removed < indentation.len and indentation[removed] == ' ') {
            removed += 1;
        }
        return allocator.dupe(u8, indentation[removed..]);
    }
};

fn testConverter() IIndentConverter {
    return .{
        .context = @ptrFromInt(@alignOf(usize)),
        .shiftIndentFn = SpacesConverter.shift,
        .unshiftIndentFn = SpacesConverter.unshift,
    };
}

const CharacterPairSupport = @import("./supports/characterPair.zig");
const LanguageBracketsConfiguration = @import("./supports/languageBracketsConfiguration.zig").LanguageBracketsConfiguration;
const OpeningBracketKind = @import("./supports/languageBracketsConfiguration.zig").OpeningBracketKind;
const ClosingBracketKind = @import("./supports/languageBracketsConfiguration.zig").ClosingBracketKind;
const defaultWordRegExp = @import("../core/wordHelper.zig").defaultWordRegExp;

fn setupBracketLanguage(allocator: Allocator) !void {
    TestLanguage.decoder = try LanguageIdCodec.init(allocator);
    TestLanguage.lines = &[_][]const u8{ "if (a) {", "    b", "}" };

    var configuration = language_configuration.empty();
    const rules = IndentationRule{
        .decreaseIndentPattern = try RegExp.init("^\\s*\\}", .{}),
        .increaseIndentPattern = try RegExp.init("\\{$", .{}),
        .indentNextLinePattern = null,
        .unIndentedLinePattern = null,
    };
    configuration.indentationRules = rules;

    // `ResolvedLanguageConfiguration` is normally created by the language
    // configuration registry; the test builds one directly so that it does not
    // depend on a service implementation.
    TestLanguage.configuration = .{
        .languageId = "test",
        .comments = null,
        .characterPair = try CharacterPairSupport.init(configuration),
        .wordDefinition = defaultWordRegExp(),
        .indentationRules = rules,
        .indentRulesSupport = IndentRulesSupport.init(rules),
        .foldingRules = .{ .offSide = null, .markers = null },
        .bracketsNew = .{
            .id = 0,
            .allocator = allocator,
            ._openingBrackets = std.StringHashMap(OpeningBracketKind).init(allocator),
            ._closingBrackets = std.StringHashMap(ClosingBracketKind).init(allocator),
            .languageId = "test",
            .config = configuration,
        },
        .underlyingConfig = configuration,
    };
}

test "getInheritIndentForLine inherits after an opening bracket" {
    const allocator = std.testing.allocator;
    try setupBracketLanguage(allocator);
    defer TestLanguage.decoder.deinit();

    var result = (try getInheritIndentForLine(allocator, .Full, testVirtualModel(), 2, true, testService())).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("", result.indentation);
    try std.testing.expectEqual(@as(?IndentAction, .Indent), result.action);
    try std.testing.expectEqual(@as(?usize, 1), result.line);
}

test "getGoodIndentForLine indents inside brackets" {
    const allocator = std.testing.allocator;
    try setupBracketLanguage(allocator);
    defer TestLanguage.decoder.deinit();

    const indentation = (try getGoodIndentForLine(allocator, .Full, testVirtualModel(), "test", 2, testConverter(), testService())).?;
    defer allocator.free(indentation);
    try std.testing.expectEqualStrings("    ", indentation);
}

test "getGoodIndentForLine outdents a closing bracket" {
    const allocator = std.testing.allocator;
    try setupBracketLanguage(allocator);
    defer TestLanguage.decoder.deinit();

    const indentation = (try getGoodIndentForLine(allocator, .Full, testVirtualModel(), "test", 3, testConverter(), testService())).?;
    defer allocator.free(indentation);
    try std.testing.expectEqualStrings("", indentation);
}

test "getInheritIndentForLine is disabled below the full strategy" {
    const allocator = std.testing.allocator;
    try setupBracketLanguage(allocator);
    defer TestLanguage.decoder.deinit();

    try std.testing.expectEqual(
        @as(?IndentResult, null),
        try getInheritIndentForLine(allocator, .Brackets, testVirtualModel(), 2, true, testService()),
    );
}
