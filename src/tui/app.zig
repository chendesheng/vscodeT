const std = @import("std");
const Allocator = std.mem.Allocator;
const UndoRedoGroup = @import("../textModel/undoRedo.zig").UndoRedoGroup;
const IdentifiedSingleEditOperation = @import("../textModel/model.zig").IdentifiedSingleEditOperation;
const UndoRedoService = @import("../textModel/undoRedoService.zig").UndoRedoService;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const TextModelCreationOptions = @import("../textModel/model.zig").TextModelCreationOptions;
const io = std.io;
const fs = std.fs;
const File = fs.File;
const posix = std.posix;
const tui = @import("tui.zig");
const Size = tui.Size;
const ArrayList = std.array_list.Managed;
const logger = @import("logger.zig");
const PieceTreeBufferBuilder = @import("../pieceTreeTextBuffer/pieceTreeBufferBuilder.zig").PieceTreeBufferBuilder;
const PieceTreeTextBuffer = @import("../pieceTreeTextBuffer/pieceTreeTextBuffer.zig").PieceTreeTextBuffer;
const ValidAnnotatedEditOperation = @import("../textModel/model.zig").ValidAnnotatedEditOperation;
const Range = @import("../basics/range.zig").Range;
const Utf8StreamIterator = @import("../basics/utf8Helper.zig").Utf8StreamIterator;
const utils = @import("../basics/utils.zig");
const Screen = tui.Screen;
const SGRAttribute = tui.SGRAttribute;
const Position = @import("../basics/position.zig").Position;
const View = @import("View.zig");
const ts = @import("tree-sitter");
const ts_languages = @import("../treeSitter/languages.zig");
const PLAINTEXT_LANGUAGE_ID = @import("../services/languageRegistry.zig").PLAINTEXT_LANGUAGE_ID;
const LanguageService = @import("../languages/languageService.zig").LanguageService;
const LanguageConfigurationService = @import("../languages/languageConfigurationRegistry.zig").LanguageConfigurationService;
const TreeSitterLibraryService = @import("../services/TreeSitterLibraryService.zig");
const TreeSitterThemeService = @import("../services/TreeSitterThemeService.zig");
const GlobalServices = @import("../services/GlobalServices.zig");

fn getFirstArg() !ArrayList(u8) {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        return error.NoPathProvided;
    }
    var firstArg = ArrayList(u8).init(allocator);
    try firstArg.appendSlice(args[1]);
    return firstArg;
}

fn loadFile(
    allocator: Allocator,
    path: []const u8,
    globalServices: *GlobalServices,
) !*TextModel {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buf: [1024]u8 = undefined;
    var reader = file.readerStreaming(&buf);
    return try TextModel.init(
        allocator,
        &reader.interface,
        PLAINTEXT_LANGUAGE_ID,
        TextModelCreationOptions{
            .tabSize = 4,
            .indentSize = .{ .number = 4 },
            .insertSpaces = true,
            .detectIndentation = false,
            .trimAutoWhitespace = true,
            .defaultEOL = .LF,
            .isForSimpleWidget = false,
            .largeFileOptimizations = false,
            .bracketPairColorizationOptions = .{
                .enabled = false,
                .independentColorPoolPerBracketType = false,
            },
        },
        null,
        globalServices.undoRedoService(),
        globalServices.languageService(),
        globalServices.languageConfigurationService(),
        globalServices.treeSitterLibraryService(),
        globalServices.treeSitterThemeService(),
    );
}

pub fn testTreeSitterZig() !void {
    // Create a parser for the zig language
    const language: *const ts.Language = ts_languages.createLanguage(.zig);
    defer language.destroy();

    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(language);

    // Parse some source code and get the root node
    const tree = parser.parseString("pub fn main() !void {}", null).?;
    defer tree.destroy();

    const node = tree.rootNode();
    std.debug.assert(std.mem.eql(u8, node.kind(), "source_file"));
    std.debug.assert(node.endPoint().cmp(.{ .row = 0, .column = 22 }) == .eq);

    // Create a query and execute it
    var error_offset: u32 = 0;
    const query = try ts.Query.create(language, "name: (identifier) @name", &error_offset);
    defer query.destroy();

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(query, node);

    // Get the captured node of the first match
    const match = cursor.nextMatch().?;
    const capture = match.captures[0].node;
    std.debug.assert(std.mem.eql(u8, capture.kind(), "identifier"));
}

pub fn main() !void {
    try testTreeSitterZig();

    try logger.init("debug.log");
    defer logger.deinit();

    const stdout = std.fs.File.stdout();
    const stdin = std.fs.File.stdin();

    const orig_termios = try tui.enableRawMode();
    tui.rememberOrigTermios(orig_termios);
    defer tui.disableRawMode(orig_termios) catch unreachable;

    try tui.enableBracketedPaste(stdout);
    defer tui.disableBracketedPaste(stdout) catch {};

    try tui.enterAltScreen(stdout);
    defer tui.exitAltScreen(stdout) catch {};

    try tui.disableLineWrap(stdout);
    defer tui.enableLineWrap(stdout) catch {};

    const pathArg = try getFirstArg();
    defer pathArg.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var globalServices: GlobalServices = undefined;
    try GlobalServices.init(&globalServices, allocator);
    var textModel = try loadFile(
        allocator,
        pathArg.items,
        &globalServices,
    );
    defer textModel.deinit();

    var screen = try Screen.init(stdin, stdout, allocator);
    defer screen.deinit();
    var view = View.init(textModel);
    try view.resize(try screen.getSize());
    try view.draw(&screen);

    while (true) {
        const events = try screen.pollEvents();
        defer events.deinit();

        for (events.items) |event| {
            switch (event) {
                .key => |*key| {
                    try view.handleKeyPress(key);
                },
                .resize => |newSize| {
                    try view.resize(newSize);
                },
            }
        }

        if (events.items.len > 0) {
            try view.draw(&screen);
        }
    }
}
