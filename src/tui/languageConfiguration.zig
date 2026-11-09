// Minimal `ILanguageConfigurationService` implementation for the TUI.
//
// The shared interface uses function pointers without a context, so the active
// service is selected explicitly through `activate()`. The TUI is
// single-threaded and activates the service immediately before executing
// commands that need it.
const std = @import("std");
const Allocator = std.mem.Allocator;

const language_configuration = @import("../vs/editor/common/languages/languageConfiguration.zig");
const registry = @import("../vs/editor/common/languages/languageConfigurationRegistry.zig");
const ILanguageConfigurationService = registry.ILanguageConfigurationService;
const ResolvedLanguageConfiguration = registry.ResolvedLanguageConfiguration;
const LanguageConfigurationServiceChangeEvent = registry.LanguageConfigurationServiceChangeEvent;
const CharacterPairSupport = @import("../vs/editor/common/languages/supports/characterPair.zig");
const LanguageBracketsConfiguration = @import("../vs/editor/common/languages/supports/languageBracketsConfiguration.zig").LanguageBracketsConfiguration;
const OpeningBracketKind = @import("../vs/editor/common/languages/supports/languageBracketsConfiguration.zig").OpeningBracketKind;
const ClosingBracketKind = @import("../vs/editor/common/languages/supports/languageBracketsConfiguration.zig").ClosingBracketKind;
const IndentRulesSupport = @import("../vs/editor/common/languages/supports/indentRules.zig").IndentRulesSupport;
const defaultWordRegExp = @import("../vs/editor/common/core/wordHelper.zig").defaultWordRegExp;
const LanguageService = @import("../vs/editor/common/services/languageService.zig").LanguageService;

var active_service: ?*Service = null;

pub const Service = struct {
    language_service: *LanguageService,
    arena: std.heap.ArenaAllocator,
    blank: ResolvedLanguageConfiguration,
    cached_language_id: ?[]const u8 = null,
    cached_config: ?ResolvedLanguageConfiguration = null,

    pub fn init(allocator: Allocator, language_service: *LanguageService) !Service {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const blank = try buildResolved(arena.allocator(), "plaintext", language_configuration.empty());
        return .{
            .language_service = language_service,
            .arena = arena,
            .blank = blank,
        };
    }

    pub fn deinit(self: *Service) void {
        if (active_service == self) active_service = null;
        self.arena.deinit();
    }

    pub fn activate(self: *Service) void {
        active_service = self;
    }

    pub fn interface(self: *Service) ILanguageConfigurationService {
        self.activate();
        return .{
            .onDidChange = onDidChange,
            .register = register,
            .getLanguageConfiguration = getLanguageConfiguration,
        };
    }

    fn get(self: *Service, language_id: []const u8) ResolvedLanguageConfiguration {
        if (self.cached_language_id) |cached_id| {
            if (std.mem.eql(u8, cached_id, language_id)) return self.cached_config.?;
        }

        const config = self.language_service.getLanguageConfiguration(language_id) orelse language_configuration.empty();
        const resolved = buildResolved(self.arena.allocator(), language_id, config) catch return self.blank;
        self.cached_language_id = self.arena.allocator().dupe(u8, language_id) catch return resolved;
        self.cached_config = resolved;
        return resolved;
    }
};

fn onDidChange(_: LanguageConfigurationServiceChangeEvent) void {}
fn register(_: []const u8, _: language_configuration.LanguageConfiguration, _: ?usize) void {}

fn getLanguageConfiguration(language_id: []const u8) ResolvedLanguageConfiguration {
    const service = active_service orelse @panic("TUI language configuration service is not active");
    return service.get(language_id);
}

fn buildResolved(
    allocator: Allocator,
    language_id: []const u8,
    config: language_configuration.LanguageConfiguration,
) !ResolvedLanguageConfiguration {
    return .{
        .languageId = language_id,
        .comments = ResolvedLanguageConfiguration._handleComments(config),
        .characterPair = try CharacterPairSupport.init(config),
        .wordDefinition = config.wordPattern orelse defaultWordRegExp(),
        .indentationRules = config.indentationRules,
        .indentRulesSupport = if (config.indentationRules) |rules| IndentRulesSupport.init(rules) else null,
        .foldingRules = config.folding orelse .{ .offSide = null, .markers = null },
        .bracketsNew = LanguageBracketsConfiguration{
            .id = 0,
            ._openingBrackets = std.StringHashMap(OpeningBracketKind).init(allocator),
            ._closingBrackets = std.StringHashMap(ClosingBracketKind).init(allocator),
            .languageId = language_id,
            .config = config,
        },
        .underlyingConfig = config,
    };
}
