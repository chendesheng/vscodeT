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

pub fn createTextModel(allocator: Allocator, text: []const u8, options: ?RelaxedTextModelCreationOptions) !*TextModel {
    const undoRedoService = try UndoRedoService.create(allocator);
    var source = std.Io.Reader.fixed(text);
    return try TextModel.init(allocator, &source, resolveOptions(options), null, undoRedoService);
}

pub fn disposeTextModel(textModel: *TextModel) void {
    textModel.deinit();
    textModel._undoRedoService.deinit();
    textModel.getAllocator().destroy(textModel._undoRedoService);
    textModel.getAllocator().destroy(textModel);
}
