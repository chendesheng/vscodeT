const std = @import("std");
const Allocator = std.mem.Allocator;
const TreeSitterLibraryService = @import("TreeSitterLibraryService.zig");
const UndoRedoService = @import("../textModel/undoRedoService.zig").UndoRedoService;
const TreeSitterThemeService = @import("./TreeSitterThemeService.zig");
const LanguageIdCodec = @import("./languageRegistry.zig").LanguageIdCodec;
const LanguageConfigurationService = @import("../languages/languageConfigurationRegistry.zig").LanguageConfigurationService;
const LanguageService = @import("../languages/languageService.zig").LanguageService;

const Self = @This();

_treeSitterLibraryService: TreeSitterLibraryService,
_treeSitterThemeService: TreeSitterThemeService,
_undoRedoService: UndoRedoService,
_languageIdCodec: LanguageIdCodec,
_languageService: LanguageService,
_languageConfigurationService: LanguageConfigurationService,

pub fn init(self: *Self, allocator: Allocator) !void {
    self._treeSitterLibraryService = TreeSitterLibraryService.init(allocator);
    self._treeSitterThemeService = TreeSitterThemeService.init(allocator);
    self._undoRedoService = UndoRedoService.init(allocator);
    self._languageIdCodec = try LanguageIdCodec.init(allocator);
    self._languageService = try LanguageService.init(allocator);
    self._languageConfigurationService = try LanguageConfigurationService.init(allocator, undefined, &self._languageService);
}

pub fn deinit(self: *Self) void {
    self._treeSitterLibraryService.deinit();
    self._treeSitterThemeService.deinit();
    self._undoRedoService.deinit();
    self._languageIdCodec.deinit();
}

pub fn treeSitterLibraryService(self: *Self) *TreeSitterLibraryService {
    return &self._treeSitterLibraryService;
}

pub fn treeSitterThemeService(self: *Self) *TreeSitterThemeService {
    return &self._treeSitterThemeService;
}

pub fn undoRedoService(self: *Self) *UndoRedoService {
    return &self._undoRedoService;
}

pub fn languageIdCodec(self: *Self) *LanguageIdCodec {
    return &self._languageIdCodec;
}

pub fn languageService(self: *Self) *LanguageService {
    return &self._languageService;
}

pub fn languageConfigurationService(self: *Self) *LanguageConfigurationService {
    return &self._languageConfigurationService;
}
