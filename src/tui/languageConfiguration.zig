// Terminal `ILanguageConfigurationService` host over the ported
// `LanguageConfigurationRegistry`.
//
// The TUI keeps the global `active_service` selection because the shared
// interface uses function pointers without a context; it is single-threaded
// and activates the service immediately before executing commands that need
// it. Language configurations registered in the editor `LanguageService` are
// promoted into the registry on first use, where priority merging and
// invalidation are the upstream-shaped `LanguageConfigurationRegistry` rules.
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
const OnEnterSupport = @import("../vs/editor/common/languages/supports/onEnter.zig").OnEnterSupport;
const RichEditBrackets = @import("../vs/editor/common/languages/supports/richEditBrackets.zig").RichEditBrackets;
const BracketElectricCharacterSupport = @import("../vs/editor/common/languages/supports/electricCharacter.zig").BracketElectricCharacterSupport;
const defaultWordRegExp = @import("../vs/editor/common/core/wordHelper.zig").defaultWordRegExp;
const LanguageService = @import("../vs/editor/common/services/languageService.zig").LanguageService;

var active_service: ?*Service = null;

pub const Service = struct {
    language_service: *LanguageService,
    registry: registry.LanguageConfigurationRegistry,
    arena: std.heap.ArenaAllocator,
    blank: ResolvedLanguageConfiguration,

    pub fn init(allocator: Allocator, language_service: *LanguageService) !Service {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const blank = try buildResolved(arena.allocator(), "plaintext", language_configuration.empty());
        return .{
            .language_service = language_service,
            .registry = try registry.LanguageConfigurationRegistry.init(allocator),
            .arena = arena,
            .blank = blank,
        };
    }

    pub fn deinit(self: *Service) void {
        if (active_service == self) active_service = null;
        self.blank.deinit();
        self.registry.deinit();
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
        if (self.registry.getLanguageConfiguration(language_id)) |resolved| {
            return resolved.*;
        }

        // Promote the editor language service's configuration into the
        // registry so priority merging and invalidation use the upstream path.
        if (self.language_service.getLanguageConfiguration(language_id)) |config| {
            var registration = self.registry.register(language_id, config, 0) catch return self.blank;
            registration.disposed = true;
            if (self.registry.getLanguageConfiguration(language_id)) |resolved| {
                return resolved.*;
            }
        }
        return self.blank;
    }
};

fn onDidChange(_: LanguageConfigurationServiceChangeEvent) void {}

fn register(language_id: []const u8, config: language_configuration.LanguageConfiguration, priority: ?usize) void {
    const service = active_service orelse @panic("TUI language configuration service is not active");
    var registration = service.registry.register(language_id, config, if (priority) |value| @intCast(value) else 0) catch return;
    registration.disposed = true;
}

fn getLanguageConfiguration(language_id: []const u8) ResolvedLanguageConfiguration {
    const service = active_service orelse @panic("TUI language configuration service is not active");
    return service.get(language_id);
}

fn buildResolved(
    allocator: Allocator,
    language_id: []const u8,
    config: language_configuration.LanguageConfiguration,
) !ResolvedLanguageConfiguration {
    const rich_brackets: ?RichEditBrackets = if (config.brackets) |raw_brackets|
        (RichEditBrackets.init(allocator, language_id, raw_brackets) catch null)
    else
        null;
    const electric_character: ?BracketElectricCharacterSupport = if (rich_brackets) |*brackets|
        BracketElectricCharacterSupport.init(brackets)
    else
        null;

    const on_enter_support: ?OnEnterSupport = if (config.brackets != null or
        config.indentationRules != null or
        config.onEnterRules != null)
        (OnEnterSupport.init(allocator, .{
            .brackets = config.brackets,
            .onEnterRules = config.onEnterRules,
        }) catch null)
    else
        null;

    return .{
        .allocator = allocator,
        .brackets = rich_brackets,
        .electric_character = electric_character,
        .languageId = language_id,
        .on_enter_support = on_enter_support,
        .comments = ResolvedLanguageConfiguration._handleComments(config),
        .characterPair = try CharacterPairSupport.init(config),
        .wordDefinition = config.wordPattern orelse defaultWordRegExp(),
        .indentationRules = config.indentationRules,
        .indentRulesSupport = if (config.indentationRules) |rules| IndentRulesSupport.init(rules) else null,
        .foldingRules = config.folding orelse .{ .offSide = null, .markers = null },
        .bracketsNew = LanguageBracketsConfiguration{
            .id = 0,
            .allocator = allocator,
            ._openingBrackets = std.StringHashMap(OpeningBracketKind).init(allocator),
            ._closingBrackets = std.StringHashMap(ClosingBracketKind).init(allocator),
            .languageId = language_id,
            .config = config,
        },
        .underlyingConfig = config,
    };
}
