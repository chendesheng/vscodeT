// Port of
// `src/vs/editor/common/languages/supports/indentationLineProcessor.ts`.
//
// `IVirtualModel` is declared here instead of in `autoIndent.zig` (where
// upstream declares it) so that the two modules form an acyclic import graph.
// `autoIndent.zig` re-exports it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const strings = @import("../../../../base/common/strings.zig");
const regexp = @import("../../../../../support/regexp.zig");

const line_tokens = @import("../../tokens/lineTokens.zig");
const LineTokens = line_tokens.LineTokens;
const SliceLineTokens = line_tokens.SliceLineTokens;
const TokenTextMetadata = line_tokens.TokenTextMetadata;

const supports = @import("../supports.zig");
const createScopedLineTokens = supports.createScopedLineTokens;
const ScopedLineTokens = supports.ScopedLineTokens;

const encoded = @import("../../encodedTokenAttributes.zig");
const StandardTokenType = encoded.StandardTokenType;

const range_module = @import("../../core/range.zig");
const Range = range_module.Range;
const Position = @import("../../core/position.zig").Position;

const text_model = @import("../../model/textModel.zig");
const TextModel = text_model.TextModel;
const LanguageIdCodec = @import("../../languages.zig").LanguageIdCodec;

const indent_rules = @import("./indentRules.zig");
const IndentRulesSupport = indent_rules.IndentRulesSupport;

const registry = @import("../languageConfigurationRegistry.zig");
const ILanguageConfigurationService = registry.ILanguageConfigurationService;

/// The minimal text model interface required for indentation computations.
/// Implementations return owned values; callers must free them with the
/// allocator they passed in.
pub const IVirtualModel = struct {
    context: *anyopaque,
    getLineTokensFn: *const fn (context: *anyopaque, allocator: Allocator, lineNumber: usize) anyerror!LineTokens,
    getLanguageIdFn: *const fn (context: *anyopaque) []const u8,
    getLanguageIdAtPositionFn: *const fn (context: *anyopaque, lineNumber: usize, column: usize) []const u8,
    forceTokenizationFn: ?*const fn (context: *anyopaque, lineNumber: usize) void = null,
    getLineContentFn: *const fn (context: *anyopaque, allocator: Allocator, lineNumber: usize) anyerror![]u8,

    pub fn getLineTokens(self: IVirtualModel, allocator: Allocator, line_number: usize) !LineTokens {
        return self.getLineTokensFn(self.context, allocator, line_number);
    }

    pub fn getLanguageId(self: IVirtualModel) []const u8 {
        return self.getLanguageIdFn(self.context);
    }

    pub fn getLanguageIdAtPosition(self: IVirtualModel, line_number: usize, column: usize) []const u8 {
        return self.getLanguageIdAtPositionFn(self.context, line_number, column);
    }

    pub fn forceTokenization(self: IVirtualModel, line_number: usize) void {
        if (self.forceTokenizationFn) |function| {
            function(self.context, line_number);
        }
    }

    /// Returns an owned copy of the line content.
    pub fn getLineContent(self: IVirtualModel, allocator: Allocator, line_number: usize) ![]u8 {
        return self.getLineContentFn(self.context, allocator, line_number);
    }
};

/// Adapts a `TextModel` to `IVirtualModel`.
pub fn fromTextModel(model: *TextModel) IVirtualModel {
    return .{
        .context = model,
        .getLineTokensFn = struct {
            fn get(context: *anyopaque, allocator: Allocator, line_number: usize) anyerror!LineTokens {
                _ = allocator;
                const model_: *TextModel = @ptrCast(@alignCast(context));
                return model_.tokenization().getLineTokens(line_number);
            }
        }.get,
        .getLanguageIdFn = struct {
            fn get(context: *anyopaque) []const u8 {
                const model_: *TextModel = @ptrCast(@alignCast(context));
                return model_.getLanguageId();
            }
        }.get,
        .getLanguageIdAtPositionFn = struct {
            fn get(context: *anyopaque, line_number: usize, column: usize) []const u8 {
                const model_: *TextModel = @ptrCast(@alignCast(context));
                return model_.getLanguageIdAtPosition(line_number, column);
            }
        }.get,
        .forceTokenizationFn = struct {
            fn force(context: *anyopaque, line_number: usize) void {
                const model_: *TextModel = @ptrCast(@alignCast(context));
                model_.tokenization().forceTokenization(line_number);
            }
        }.force,
        .getLineContentFn = struct {
            fn get(context: *anyopaque, allocator: Allocator, line_number: usize) anyerror![]u8 {
                _ = allocator;
                const model_: *TextModel = @ptrCast(@alignCast(context));
                var content = try model_.getLineContent(line_number);
                return content.toOwnedSlice();
            }
        }.get,
    };
}

/// Replaces every match of `regex` with `replacement`.
fn replaceMatches(allocator: Allocator, regex: *const regexp.RegExp, text: []const u8, replacement: []const u8) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var last_index: usize = 0;
    var iterator = regex.searchIterator(text, 0);
    while (iterator.next()) |search_result| {
        defer search_result.deinit();
        const index = search_result.index();
        const length = search_result.length();
        try result.appendSlice(text[last_index..index]);
        try result.appendSlice(replacement);
        last_index = index + length;
        if (length == 0) {
            // Empty matches cannot advance the iterator; stop here like a
            // global replace that refuses to loop forever.
            if (index >= text.len) {
                break;
            }
            try result.append(text[index]);
            last_index = index + 1;
        }
    }
    try result.appendSlice(text[last_index..]);
    return result.toOwnedSlice();
}

fn shouldRemoveBracketsFromTokenType(token_type: StandardTokenType) bool {
    return token_type == .String or token_type == .RegEx or token_type == .Comment;
}

/// This class performs the actual processing of the indentation lines. The
/// brackets of the language configuration are removed from the regex, string
/// and comment tokens.
pub const IndentationLineProcessor = struct {
    allocator: Allocator,
    model: IVirtualModel,
    languageConfigurationService: ILanguageConfigurationService,

    pub fn init(allocator: Allocator, model: IVirtualModel, language_configuration_service: ILanguageConfigurationService) IndentationLineProcessor {
        return .{
            .allocator = allocator,
            .model = model,
            .languageConfigurationService = language_configuration_service,
        };
    }

    /// Gets the processed line for the given line number and potentially
    /// adjusts the indentation level. The returned slice is owned by the
    /// caller.
    pub fn getProcessedLine(self: *IndentationLineProcessor, line_number: usize, new_indentation: ?[]const u8) ![]u8 {
        self.model.forceTokenization(line_number);
        var tokens = try self.model.getLineTokens(self.allocator, line_number);
        defer tokens.deinit();

        var processed_tokens = try self.getProcessedTokens(&tokens);
        defer processed_tokens.deinit();

        const processed_line = processed_tokens.getLineContent();
        if (new_indentation) |indentation| {
            var result = ArrayList(u8).init(self.allocator);
            errdefer result.deinit();
            try result.appendSlice(indentation);
            const current_indentation = strings.getLeadingWhitespace(processed_line);
            try result.appendSlice(processed_line[current_indentation.len..]);
            return result.toOwnedSlice();
        }

        return self.allocator.dupe(u8, processed_line);
    }

    /// Processes the line with the given tokens, removing the language
    /// configuration brackets from regex, string and comment tokens.
    pub fn getProcessedTokens(self: *IndentationLineProcessor, tokens: anytype) !LineTokens {
        const language_id = tokens.getLanguageId(0);
        var configuration = self.languageConfigurationService.getLanguageConfiguration(language_id);

        // Languages without bracket configuration have nothing to strip.
        // (Upstream builds an empty `()` regexp in that case.)
        var brackets_regexp: ?regexp.RegExp = if (configuration.bracketsNew.openingBracketCount() > 0)
            try configuration.bracketsNew.getBracketRegExp(null)
        else
            null;
        defer if (brackets_regexp) |*regex| regex.deinit();

        // Temporary storage for the bracket-stripped token texts; the results
        // are copied into the created `LineTokens`.
        var temp = std.heap.ArenaAllocator.init(self.allocator);
        defer temp.deinit();

        var text_and_metadata = ArrayList(TokenTextMetadata).init(temp.allocator());
        const token_count = tokens.getCount();
        try text_and_metadata.ensureTotalCapacity(token_count);
        for (0..token_count) |token_index| {
            const token_type = tokens.getStandardTokenType(token_index);
            const text = tokens.getTokenText(token_index);
            const processed_text = if (brackets_regexp != null and shouldRemoveBracketsFromTokenType(token_type))
                try replaceMatches(temp.allocator(), &brackets_regexp.?, text, "")
            else
                text;
            text_and_metadata.appendAssumeCapacity(.{
                .text = processed_text,
                .metadata = tokens.getMetadata(token_index),
            });
        }

        return LineTokens.createFromTextAndMetadata(self.allocator, text_and_metadata.items, tokens.languageIdCodec);
    }
};

pub const ProcessedTokenContextAroundRange = struct {
    beforeRangeProcessedTokens: LineTokens,
    afterRangeProcessedTokens: LineTokens,
    previousLineProcessedTokens: LineTokens,

    pub fn deinit(self: *ProcessedTokenContextAroundRange) void {
        self.beforeRangeProcessedTokens.deinit();
        self.afterRangeProcessedTokens.deinit();
        self.previousLineProcessedTokens.deinit();
    }
};

/// Fetches the processed text around a range which can be used for indentation
/// evaluation.
pub const IndentationContextProcessor = struct {
    allocator: Allocator,
    model: *TextModel,
    indentationLineProcessor: IndentationLineProcessor,

    pub fn init(allocator: Allocator, model: *TextModel, language_configuration_service: ILanguageConfigurationService) IndentationContextProcessor {
        return .{
            .allocator = allocator,
            .model = model,
            .indentationLineProcessor = IndentationLineProcessor.init(allocator, fromTextModel(model), language_configuration_service),
        };
    }

    /// Returns the processed text, stripped from the language configuration
    /// brackets within the string, comment and regex tokens, around the given
    /// range.
    pub fn getProcessedTokenContextAroundRange(self: *IndentationContextProcessor, range: Range) !ProcessedTokenContextAroundRange {
        return .{
            .beforeRangeProcessedTokens = try self.getProcessedTokensBeforeRange(range),
            .afterRangeProcessedTokens = try self.getProcessedTokensAfterRange(range),
            .previousLineProcessedTokens = try self.getProcessedPreviousLineTokens(range),
        };
    }

    fn getProcessedTokensBeforeRange(self: *IndentationContextProcessor, range: Range) !LineTokens {
        self.model.tokenization().forceTokenization(range.startLineNumber);
        var tokens_of_line = try self.model.tokenization().getLineTokens(range.startLineNumber);
        defer tokens_of_line.deinit();

        const scoped_line_tokens = createScopedLineTokens(&tokens_of_line, range.startColumn - 1);
        var sliced_tokens: SliceLineTokens = undefined;
        if (try isLanguageDifferentFromLineStart(self.model, range.startPosition())) {
            const column_index_within_scope = (range.startColumn - 1) - scoped_line_tokens.firstCharOffset;
            const first_character_offset = scoped_line_tokens.firstCharOffset;
            const last_character_offset = first_character_offset + column_index_within_scope;
            sliced_tokens = tokens_of_line.sliceAndInflate(first_character_offset, last_character_offset, 0);
        } else {
            const column_within_line = range.startColumn - 1;
            sliced_tokens = tokens_of_line.sliceAndInflate(0, column_within_line, 0);
        }
        return self.indentationLineProcessor.getProcessedTokens(&sliced_tokens);
    }

    fn getProcessedTokensAfterRange(self: *IndentationContextProcessor, range: Range) !LineTokens {
        const position: Position = if (range.isEmpty()) range.startPosition() else range.endPosition();
        self.model.tokenization().forceTokenization(position.lineNumber);
        var tokens_of_line = try self.model.tokenization().getLineTokens(position.lineNumber);
        defer tokens_of_line.deinit();

        const scoped_line_tokens = createScopedLineTokens(&tokens_of_line, position.column - 1);
        const column_index_within_scope = (position.column - 1) - scoped_line_tokens.firstCharOffset;
        const first_character_offset = scoped_line_tokens.firstCharOffset + column_index_within_scope;
        const last_character_offset = scoped_line_tokens.firstCharOffset + scoped_line_tokens.getLineLength();
        const sliced_tokens = tokens_of_line.sliceAndInflate(first_character_offset, last_character_offset, 0);
        return self.indentationLineProcessor.getProcessedTokens(&sliced_tokens);
    }

    fn createEmptyLineTokens(self: *IndentationContextProcessor, decoder: *LanguageIdCodec) !LineTokens {
        return LineTokens.createEmpty(self.allocator, ArrayList(u8).init(self.allocator), decoder);
    }

    fn getProcessedPreviousLineTokens(self: *IndentationContextProcessor, range: Range) !LineTokens {
        self.model.tokenization().forceTokenization(range.startLineNumber);
        var tokens_of_line = try self.model.tokenization().getLineTokens(range.startLineNumber);
        defer tokens_of_line.deinit();

        const scoped_line_tokens = createScopedLineTokens(&tokens_of_line, range.startColumn - 1);
        const decoder = tokens_of_line.languageIdCodec;

        if (range.startLineNumber == 1) {
            return self.createEmptyLineTokens(decoder);
        }
        const previous_line_number = range.startLineNumber - 1;

        const can_scope_extend_on_previous_line = scoped_line_tokens.firstCharOffset == 0;
        if (!can_scope_extend_on_previous_line) {
            return self.createEmptyLineTokens(decoder);
        }

        var previous_line_tokens = try self.model.tokenization().getLineTokens(previous_line_number);
        defer previous_line_tokens.deinit();
        const end_column_of_line = self.model.getLineMaxColumn(previous_line_number) - 1;
        const scoped_previous = createScopedLineTokens(&previous_line_tokens, end_column_of_line);

        const does_language_continue_on_previous_line = std.mem.eql(u8, scoped_line_tokens.languageId, scoped_previous.languageId);
        if (!does_language_continue_on_previous_line) {
            return self.createEmptyLineTokens(decoder);
        }

        const previous_sliced_line_tokens = scoped_previous.toSliceLineTokens();
        return self.indentationLineProcessor.getProcessedTokens(&previous_sliced_line_tokens);
    }
};

pub fn isLanguageDifferentFromLineStart(model: *TextModel, position: Position) !bool {
    model.tokenization().forceTokenization(position.lineNumber);
    var tokens_of_line = try model.tokenization().getLineTokens(position.lineNumber);
    defer tokens_of_line.deinit();

    const scoped_line_tokens = createScopedLineTokens(&tokens_of_line, position.column - 1);
    const does_scope_start_at_offset_zero = scoped_line_tokens.firstCharOffset == 0;
    const is_scoped_language_equal_to_first_language_on_line = std.mem.eql(u8, tokens_of_line.getLanguageId(0), scoped_line_tokens.languageId);
    return !does_scope_start_at_offset_zero and !is_scoped_language_equal_to_first_language_on_line;
}

/// This class is a wrapper around `IndentRulesSupport`. It processes the lines
/// by removing the language configuration brackets from the regex, string and
/// comment tokens and then asks the `IndentRulesSupport` to validate the
/// indentation conditions.
pub const ProcessedIndentRulesSupport = struct {
    indentRulesSupport: *const IndentRulesSupport,
    indentationLineProcessor: IndentationLineProcessor,

    pub fn init(
        allocator: Allocator,
        model: IVirtualModel,
        indent_rules_support: *const IndentRulesSupport,
        language_configuration_service: ILanguageConfigurationService,
    ) ProcessedIndentRulesSupport {
        return .{
            .indentRulesSupport = indent_rules_support,
            .indentationLineProcessor = IndentationLineProcessor.init(allocator, model, language_configuration_service),
        };
    }

    /// Applies the new indentation and returns whether the indentation level
    /// should be increased after the given line number.
    pub fn shouldIncrease(self: *ProcessedIndentRulesSupport, line_number: usize, new_indentation: ?[]const u8) !bool {
        const processed_line = try self.indentationLineProcessor.getProcessedLine(line_number, new_indentation);
        defer self.indentationLineProcessor.allocator.free(processed_line);
        return self.indentRulesSupport.shouldIncrease(processed_line);
    }

    pub fn shouldDecrease(self: *ProcessedIndentRulesSupport, line_number: usize, new_indentation: ?[]const u8) !bool {
        const processed_line = try self.indentationLineProcessor.getProcessedLine(line_number, new_indentation);
        defer self.indentationLineProcessor.allocator.free(processed_line);
        return self.indentRulesSupport.shouldDecrease(processed_line);
    }

    pub fn shouldIgnore(self: *ProcessedIndentRulesSupport, line_number: usize, new_indentation: ?[]const u8) !bool {
        const processed_line = try self.indentationLineProcessor.getProcessedLine(line_number, new_indentation);
        defer self.indentationLineProcessor.allocator.free(processed_line);
        return self.indentRulesSupport.shouldIgnore(processed_line);
    }

    pub fn shouldIndentNextLine(self: *ProcessedIndentRulesSupport, line_number: usize, new_indentation: ?[]const u8) !bool {
        const processed_line = try self.indentationLineProcessor.getProcessedLine(line_number, new_indentation);
        defer self.indentationLineProcessor.allocator.free(processed_line);
        return self.indentRulesSupport.shouldIndentNextLine(processed_line);
    }
};

test "indentationLineProcessor decls are analyzed" {
    _ = &ProcessedIndentRulesSupport.shouldIncrease;
    _ = &ProcessedIndentRulesSupport.shouldDecrease;
    _ = &ProcessedIndentRulesSupport.shouldIgnore;
    _ = &ProcessedIndentRulesSupport.shouldIndentNextLine;
    _ = &IndentationContextProcessor.getProcessedTokenContextAroundRange;
    _ = &IndentationLineProcessor.getProcessedLine;
    _ = &isLanguageDifferentFromLineStart;
}
