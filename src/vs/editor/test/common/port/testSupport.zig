const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const TextModelCreationOptions = @import("../../../common/model.zig").TextModelCreationOptions;
const UndoRedoService = @import("../../../../platform/undoRedo/common/undoRedoService.zig").UndoRedoService;
const LanguageService = @import("../../../common/services/languageService.zig").LanguageService;
const LanguageConfigurationService = @import("../../../common/languages/languageConfigurationRegistry.zig").LanguageConfigurationService;
const LanguageIdCodec = @import("../../../common/languages.zig").LanguageIdCodec;
const SparseToken = @import("../../../common/tokens/sparseMultilineTokens.zig").SparseToken;
const SparseMultilineTokens = @import("../../../common/tokens/sparseMultilineTokens.zig").SparseMultilineTokens;
const TokenMetadata = @import("../../../common/encodedTokenAttributes.zig").TokenMetadata;
const Range = @import("../../../common/core/range.zig").Range;
const IdentifiedSingleEditOperation = @import("../../../common/model.zig").IdentifiedSingleEditOperation;
const String = @import("../../../../base/common/strings.zig").String;

pub const TestModel = struct {
    allocator: Allocator,
    codec: *LanguageIdCodec,
    languageService: *LanguageService,
    languageConfigurationService: *LanguageConfigurationService,
    undoRedoService: *UndoRedoService,
    model: *TextModel,

    pub fn init(allocator: Allocator, text: []const u8, languageId: []const u8) !TestModel {
        const codec = try allocator.create(LanguageIdCodec);
        errdefer allocator.destroy(codec);
        codec.* = try LanguageIdCodec.init(allocator);
        errdefer codec.deinit();
        try codec.register(languageId);

        const languageService = try allocator.create(LanguageService);
        errdefer allocator.destroy(languageService);
        languageService.* = LanguageService.init(allocator, codec);
        errdefer languageService.deinit();

        const languageConfigurationService = try allocator.create(LanguageConfigurationService);
        errdefer allocator.destroy(languageConfigurationService);
        languageConfigurationService.* = try LanguageConfigurationService.init(allocator, languageService);
        errdefer languageConfigurationService.deinit();

        const undoRedoService = try allocator.create(UndoRedoService);
        errdefer allocator.destroy(undoRedoService);
        undoRedoService.* = UndoRedoService.init(allocator);
        errdefer undoRedoService.deinit();

        var reader = Io.Reader.fixed(text);
        const model = try TextModel.init(allocator, &reader, languageId, .{
            .tabSize = 4,
            .indentSize = .{ .number = 4 },
            .insertSpaces = true,
            .detectIndentation = false,
            .trimAutoWhitespace = true,
            .defaultEOL = .LF,
            .isForSimpleWidget = false,
            .largeFileOptimizations = false,
            .bracketPairColorizationOptions = .{
                .enabled = true,
                .independentColorPoolPerBracketType = false,
            },
        }, null, undoRedoService, languageService, languageConfigurationService);
        errdefer {
            model.deinit();
            allocator.destroy(model);
        }

        return .{
            .allocator = allocator,
            .codec = codec,
            .languageService = languageService,
            .languageConfigurationService = languageConfigurationService,
            .undoRedoService = undoRedoService,
            .model = model,
        };
    }

    pub fn deinit(self: *TestModel) void {
        self.model.deinit();
        self.allocator.destroy(self.model);
        self.undoRedoService.deinit();
        self.allocator.destroy(self.undoRedoService);
        self.languageConfigurationService.deinit();
        self.allocator.destroy(self.languageConfigurationService);
        self.languageService.deinit();
        self.allocator.destroy(self.languageService);
        self.codec.deinit();
        self.allocator.destroy(self.codec);
    }

    pub fn applyEdit(self: *TestModel, range: Range, text: []const u8) !void {
        var ops = [_]IdentifiedSingleEditOperation{.init(range, if (text.len == 0) null else String.initBorrowed(text))};
        _ = try self.model.applyEdits(&ops, false);
    }

    pub fn applyEdits(self: *TestModel, edits: []const Edit) !void {
        var ops = ArrayList(IdentifiedSingleEditOperation).init(self.allocator);
        defer ops.deinit();
        for (edits) |edit| {
            try ops.append(IdentifiedSingleEditOperation.init(edit.range, if (edit.text.len == 0) null else String.initBorrowed(edit.text)));
        }
        _ = try self.model.applyEdits(ops.items, false);
    }
};

pub const Edit = struct { range: Range, text: []const u8 };

pub fn createSparseTokens(allocator: Allocator, startLineNumber: usize, values: []const u32) !SparseMultilineTokens {
    std.debug.assert(values.len % 4 == 0);
    var tokens = ArrayList(SparseToken).init(allocator);
    errdefer tokens.deinit();
    var i: usize = 0;
    while (i < values.len) : (i += 4) {
        try tokens.append(SparseToken.init(values[i], values[i + 1], values[i + 2], @bitCast(values[i + 3])));
    }
    return SparseMultilineTokens.create(startLineNumber, tokens);
}
