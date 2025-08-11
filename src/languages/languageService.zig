const std = @import("std");
const Emitter = @import("../basics/event.zig").Emitter;
const Uri = std.Uri;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;

pub const ILanguageExtensionPoint = struct {
    id: []const u8,
    extensions: ?[]const []const u8,
    filenames: ?[]const []const u8,
    filenamePatterns: ?[]const []const u8,
    firstLine: ?[]const u8,
    aliases: ?[]const []const u8,
    mimetypes: ?[]const []const u8,
    configuration: ?Uri,
    // @internal
    icon: ?LanguageIcon,
};

pub const LanguageSelection = struct {
    languageId: []const u8,
    onDidChange: Emitter(void),
};

pub const LanguageNameIdPair = struct {
    languageName: []const u8,
    languageId: []const u8,
};

pub const LanguageIcon = struct {
    light: Uri,
    dark: Uri,
};

pub const LanguageService = struct {
    // A codec which can encode and decode a string `languageId` as a number.
    languageIdCodec: LanguageIdCodec,

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
    registerLanguage: fn (def: ILanguageExtensionPoint) void,

    // Check if `languageId` is registered.
    isRegisteredLanguageId: fn (languageId: []const u8) bool,

    // Get a list of all registered languages.
    getRegisteredLanguageIds: fn () []const []const u8,

    // Get a list of all registered languages with a name.
    // If a language is explicitly registered without a name, it will not be part of the result.
    // The result is sorted using by name case insensitive.
    getSortedRegisteredLanguageNames: fn () []LanguageNameIdPair,

    // Get the preferred language name for a language.
    getLanguageName: fn (languageId: []const u8) ?[]const u8,

    // Get the mimetype for a language.
    getMimeType: fn (languageId: []const u8) ?[]const u8,

    // Get the default icon for the language.
    getIcon: fn (languageId: []const u8) ?LanguageIcon,

    // Get all file extensions for a language.
    getExtensions: fn (languageId: []const u8) []const []const u8,

    // Get all file names for a language.
    getFilenames: fn (languageId: []const u8) []const []const u8,

    // Get all language configuration files for a language.
    getConfigurationFiles: fn (languageId: []const u8) []const Uri,

    // Look up a language by its name case insensitive.
    getLanguageIdByLanguageName: fn (languageName: []const u8) ?[]const u8,

    // Look up a language by its mime type.
    getLanguageIdByMimeType: fn (mimeType: ?[]const u8) ?[]const u8,

    // Guess the language id for a resource.
    guessLanguageIdByFilepathOrFirstLine: fn (resource: Uri, firstLine: ?[]const u8) ?[]const u8,

    // Will fall back to 'plaintext' if `languageId` is unknown.
    createById: fn (languageId: ?[]const u8) LanguageSelection,

    // Will fall back to 'plaintext' if `mimeType` is unknown.
    createByMimeType: fn (mimeType: ?[]const u8) LanguageSelection,

    // Will fall back to 'plaintext' if the `languageId` cannot be determined.
    createByFilepathOrFirstLine: fn (resource: ?Uri, firstLine: ?[]const u8) LanguageSelection,

    // Request basic language features for a language.
    requestBasicLanguageFeatures: fn (languageId: []const u8) void,

    // Request rich language features for a language.
    requestRichLanguageFeatures: fn (languageId: []const u8) void,
};
