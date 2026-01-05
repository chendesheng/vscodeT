const std = @import("std");
const TextModel = @import("textModel.zig").TextModel;
const Allocator = std.mem.Allocator;
const EOL = @import("../basics/eolCounter.zig").EOL;
const ArrayList = std.array_list.Managed;
const UndoRedoService = @import("undoRedoService.zig").UndoRedoService;
const TextModelCreationOptions = @import("model.zig").TextModelCreationOptions;
const IndentSize = @import("model.zig").IndentSize;
const BracketPairColorizationOptions = @import("model.zig").BracketPairColorizationOptions;
const EDITOR_MODEL_DEFAULTS = @import("textModelDefaults.zig");
const LanguageService = @import("../languages/languageService.zig").LanguageService;
const ILanguageConfigurationService = @import("../languages/languageConfigurationRegistry.zig").ILanguageConfigurationService;

pub const RelaxedTextModelCreationOptions = struct {
    tabSize: ?usize = null,
    indentSize: ?IndentSize = null,
    insertSpaces: ?bool = null,
    detectIndentation: ?bool = null,
    trimAutoWhitespace: ?bool = null,
    defaultEOL: ?EOL = null,
    isForSimpleWidget: ?bool = null,
    largeFileOptimizations: ?bool = null,
    bracketColorizationOptions: ?BracketPairColorizationOptions = null,
};

fn resolveOptions(_options: ?RelaxedTextModelCreationOptions) TextModelCreationOptions {
    const options: RelaxedTextModelCreationOptions = _options orelse .{};
    const defaultOptions = TextModel.DEFAULT_CREATION_OPTIONS;

    return TextModelCreationOptions{
        .isForSimpleWidget = options.isForSimpleWidget orelse defaultOptions.isForSimpleWidget,
        .tabSize = options.tabSize orelse defaultOptions.tabSize,
        .indentSize = options.indentSize orelse defaultOptions.indentSize,
        .insertSpaces = options.insertSpaces orelse defaultOptions.insertSpaces,
        .detectIndentation = options.detectIndentation orelse defaultOptions.detectIndentation,
        .defaultEOL = options.defaultEOL orelse defaultOptions.defaultEOL,
        .trimAutoWhitespace = options.trimAutoWhitespace orelse defaultOptions.trimAutoWhitespace,
        .largeFileOptimizations = options.largeFileOptimizations orelse defaultOptions.largeFileOptimizations,
        .bracketPairColorizationOptions = options.bracketColorizationOptions orelse defaultOptions.bracketPairColorizationOptions,
    };
}

const PLAINTEXT_LANGUAGE_ID = "plaintext";

pub fn createTextModel(allocator: Allocator, text: []const u8, _languageId: ?[]const u8, options: ?RelaxedTextModelCreationOptions) !*TextModel {
    const languageId = _languageId orelse PLAINTEXT_LANGUAGE_ID;
    const undoRedoService = try UndoRedoService.create(allocator);
    var source = std.Io.Reader.fixed(text);
    const languageService = try allocator.create(LanguageService);
    languageService.* = try LanguageService.init(allocator);
    const languageConfigurationService = try allocator.create(ILanguageConfigurationService);
    const textModel = try TextModel.init(
        allocator,
        &source,
        languageId,
        resolveOptions(options),
        null,
        undoRedoService,
        languageService,
        languageConfigurationService,
    );
    return textModel;
}

pub fn disposeTextModel(textModel: *TextModel) void {
    const allocator = textModel.getAllocator();
    textModel.tokenization()._languageService.deinit();
    textModel._undoRedoService.deinit();
    allocator.destroy(textModel._undoRedoService);
    allocator.destroy(textModel.tokenization()._languageService);
    allocator.destroy(textModel.tokenization()._languageConfigurationService);
    textModel.deinit();
    allocator.destroy(textModel);
}
