const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const Uri = std.Uri;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const LanguageConfiguration = @import("../languages/languageConfiguration.zig").LanguageConfiguration;

const language = @import("../languages/language.zig");

// The payload types are declared by the interface module (`language.zig`);
// they are re-exported here so existing callers keep their import path.
pub const ILanguageExtensionPoint = language.ILanguageExtensionPoint;
pub const LanguageSelection = language.ILanguageSelection;
pub const LanguageNameIdPair = language.ILanguageNameIdPair;
pub const LanguageIcon = language.ILanguageIcon;

fn defaultRequestBasicLanguageFeatures(_: []const u8) void {}
fn defaultRequestRichLanguageFeatures(_: []const u8) void {}

pub const LanguageService = struct {
    // A codec which can encode and decode a string `languageId` as a number.
    languageIdCodec: *LanguageIdCodec,

    _languageConfigurations: std.StringHashMap(LanguageConfiguration),

    // An event emitted when basic language features are requested for the first time.
    // This event is emitted when embedded languages are encountered (e.g. JS code block inside Markdown)
    // or when a language is associated to a text model.
    //
    // **Note**: Basic language features refers to language configuration related features.
    // **Note**: This event is a superset of `onDidRequestRichLanguageFeatures`
    onDidRequestBasicLanguageFeatures: Emitter([]const u8),

    // An event emitted when rich language features are requested for the first time.
    // This event is emitted when a language is associated to a text model.
    //
    // **Note**: Rich language features refers to tokenizers, language features based on providers, etc.
    // **Note**: This event is a subset of `onDidRequestRichLanguageFeatures`
    onDidRequestRichLanguageFeatures: Emitter([]const u8),

    // An event emitted when languages have changed.
    onDidChange: Emitter(void),

    // Register a language.
    registerLanguage: *const fn (def: ILanguageExtensionPoint) void,

    // Check if `languageId` is registered.
    isRegisteredLanguageId: *const fn (languageId: []const u8) bool,

    // Get a list of all registered languages.
    getRegisteredLanguageIds: *const fn () []const []const u8,

    // Get a list of all registered languages with a name.
    // If a language is explicitly registered without a name, it will not be part of the result.
    // The result is sorted using by name case insensitive.
    getSortedRegisteredLanguageNames: *const fn () []LanguageNameIdPair,

    // Get the preferred language name for a language.
    getLanguageName: *const fn (languageId: []const u8) ?[]const u8,

    // Get the mimetype for a language.
    getMimeType: *const fn (languageId: []const u8) ?[]const u8,

    // Get the default icon for the language.
    getIcon: *const fn (languageId: []const u8) ?LanguageIcon,

    // Get all file extensions for a language.
    getExtensions: *const fn (languageId: []const u8) []const []const u8,

    // Get all file names for a language.
    getFilenames: *const fn (languageId: []const u8) []const []const u8,

    // Get all language configuration files for a language.
    getConfigurationFiles: *const fn (languageId: []const u8) []const Uri,

    // Look up a language by its name case insensitive.
    getLanguageIdByLanguageName: *const fn (languageName: []const u8) ?[]const u8,

    // Look up a language by its mime type.
    getLanguageIdByMimeType: *const fn (mimeType: ?[]const u8) ?[]const u8,

    // Guess the language id for a resource.
    guessLanguageIdByFilepathOrFirstLine: *const fn (resource: Uri, firstLine: ?[]const u8) ?[]const u8,

    // Will fall back to 'plaintext' if `languageId` is unknown.
    createById: *const fn (languageId: ?[]const u8) LanguageSelection,

    // Will fall back to 'plaintext' if `mimeType` is unknown.
    createByMimeType: *const fn (mimeType: ?[]const u8) LanguageSelection,

    // Will fall back to 'plaintext' if the `languageId` cannot be determined.
    createByFilepathOrFirstLine: *const fn (resource: ?Uri, firstLine: ?[]const u8) LanguageSelection,

    // Request basic language features for a language.
    requestBasicLanguageFeatures: *const fn (languageId: []const u8) void,

    // Request rich language features for a language.
    requestRichLanguageFeatures: *const fn (languageId: []const u8) void,

    pub fn init(allocator: Allocator, languageIdCodec: *LanguageIdCodec) LanguageService {
        return LanguageService{
            .languageIdCodec = languageIdCodec,
            ._languageConfigurations = std.StringHashMap(LanguageConfiguration).init(allocator),
            .onDidRequestBasicLanguageFeatures = Emitter([]const u8).init(allocator),
            .onDidRequestRichLanguageFeatures = Emitter([]const u8).init(allocator),
            .onDidChange = Emitter(void).init(allocator),
            .registerLanguage = undefined,
            .isRegisteredLanguageId = undefined,
            .getRegisteredLanguageIds = undefined,
            .getSortedRegisteredLanguageNames = undefined,
            .getLanguageName = undefined,
            .getMimeType = undefined,
            .getIcon = undefined,
            .getExtensions = undefined,
            .getFilenames = undefined,
            .getConfigurationFiles = undefined,
            .getLanguageIdByLanguageName = undefined,
            .getLanguageIdByMimeType = undefined,
            .guessLanguageIdByFilepathOrFirstLine = undefined,
            .createById = undefined,
            .createByMimeType = undefined,
            .createByFilepathOrFirstLine = undefined,
            .requestBasicLanguageFeatures = defaultRequestBasicLanguageFeatures,
            .requestRichLanguageFeatures = defaultRequestRichLanguageFeatures,
        };
    }

    pub fn registerLanguageConfiguration(self: *LanguageService, languageId: []const u8, configuration: LanguageConfiguration) !void {
        if (self._languageConfigurations.getEntry(languageId)) |entry| {
            entry.value_ptr.* = configuration;
            return;
        }
        const key = try self._languageConfigurations.allocator.dupe(u8, languageId);
        errdefer self._languageConfigurations.allocator.free(key);
        try self._languageConfigurations.put(key, configuration);
    }

    pub fn getLanguageConfiguration(self: *LanguageService, languageId: []const u8) ?LanguageConfiguration {
        return self._languageConfigurations.get(languageId);
    }

    pub fn deinit(self: *LanguageService) void {
        var keyIter = self._languageConfigurations.keyIterator();
        while (keyIter.next()) |key| self._languageConfigurations.allocator.free(key.*);
        self._languageConfigurations.deinit();
        self.onDidRequestBasicLanguageFeatures.deinit();
        self.onDidRequestRichLanguageFeatures.deinit();
        self.onDidChange.deinit();
    }
};
