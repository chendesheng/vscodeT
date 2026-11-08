// Port of `src/vs/editor/common/languages/language.ts`.
//
// `ILanguageService` is declared as a "struct of function pointers" with an
// explicit `context`, the same pattern used by the other service interfaces of
// this port. The concrete implementation lives in
// `../../common/services/languageService.zig`; it re-exports the payload types
// below so there is a single definition of each.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Uri = std.Uri;

const event = @import("../../../base/common/event.zig");
const Emitter = event.Emitter;
const lifecycle = @import("../../../base/common/lifecycle.zig");
const IDisposable = lifecycle.IDisposable;

const languages = @import("../languages.zig");
const ILanguageIdCodec = languages.ILanguageIdCodec;

/// The id used by `createDecorator('languageService')` upstream.
pub const ILanguageServiceDecoratorId = "languageService";

pub const ILanguageExtensionPoint = struct {
    id: []const u8,
    extensions: ?[]const []const u8 = null,
    filenames: ?[]const []const u8 = null,
    filenamePatterns: ?[]const []const u8 = null,
    firstLine: ?[]const u8 = null,
    aliases: ?[]const []const u8 = null,
    mimetypes: ?[]const []const u8 = null,
    configuration: ?Uri = null,
    /// @internal
    icon: ?ILanguageIcon = null,
};

/// A language selection that tracks changes of the document.
pub const ILanguageSelection = struct {
    languageId: []const u8,
    /// Upstream this is an `Event<string>`; this port exposes the `Emitter`
    /// directly because it has no separate `Event` function type.
    onDidChange: *Emitter([]const u8),
};

pub const ILanguageNameIdPair = struct {
    languageName: []const u8,
    languageId: []const u8,
};

pub const ILanguageIcon = struct {
    light: Uri,
    dark: Uri,
};

/// The editor language service.
///
/// Slices returned by the accessors are owned by the caller and must be freed
/// with the allocator that was used for the call, unless documented otherwise.
pub const ILanguageService = struct {
    context: *anyopaque,

    /// A codec which can encode and decode a string `languageId` as a number.
    languageIdCodec: *const fn (context: *anyopaque) *ILanguageIdCodec,

    /// An event emitted when basic language features are requested for the
    /// first time. This event is emitted when embedded languages are
    /// encountered (e.g. JS code block inside Markdown) or when a language is
    /// associated to a text model.
    ///
    /// **Note**: Basic language features refers to language configuration
    /// related features.
    /// **Note**: This event is a superset of `onDidRequestRichLanguageFeatures`
    onDidRequestBasicLanguageFeatures: *Emitter([]const u8),

    /// An event emitted when rich language features are requested for the first
    /// time. This event is emitted when a language is associated to a text
    /// model.
    ///
    /// **Note**: Rich language features refers to tokenizers, language features
    /// based on providers, etc.
    /// **Note**: This event is a subset of `onDidRequestRichLanguageFeatures`
    onDidRequestRichLanguageFeatures: *Emitter([]const u8),

    /// An event emitted when languages have changed.
    onDidChange: *Emitter(void),

    /// Register a language.
    registerLanguage: *const fn (context: *anyopaque, def: ILanguageExtensionPoint) anyerror!IDisposable,

    /// Check if `languageId` is registered.
    isRegisteredLanguageId: *const fn (context: *anyopaque, languageId: []const u8) bool,

    /// Get a list of all registered languages.
    getRegisteredLanguageIds: *const fn (context: *anyopaque, allocator: Allocator) anyerror![][]const u8,

    /// Get a list of all registered languages with a name. If a language is
    /// explicitly registered without a name, it will not be part of the result.
    /// The result is sorted by name, case insensitive.
    getSortedRegisteredLanguageNames: *const fn (context: *anyopaque, allocator: Allocator) anyerror![]ILanguageNameIdPair,

    /// Get the preferred language name for a language.
    getLanguageName: *const fn (context: *anyopaque, languageId: []const u8) ?[]const u8,

    /// Get the mimetype for a language.
    getMimeType: *const fn (context: *anyopaque, languageId: []const u8) ?[]const u8,

    /// Get the default icon for the language.
    getIcon: *const fn (context: *anyopaque, languageId: []const u8) ?ILanguageIcon,

    /// Get all file extensions for a language.
    getExtensions: *const fn (context: *anyopaque, allocator: Allocator, languageId: []const u8) anyerror![][]const u8,

    /// Get all file names for a language.
    getFilenames: *const fn (context: *anyopaque, allocator: Allocator, languageId: []const u8) anyerror![][]const u8,

    /// Get all language configuration files for a language.
    getConfigurationFiles: *const fn (context: *anyopaque, allocator: Allocator, languageId: []const u8) anyerror![]Uri,

    /// Look up a language by its name, case insensitive.
    getLanguageIdByLanguageName: *const fn (context: *anyopaque, languageName: []const u8) ?[]const u8,

    /// Look up a language by its mime type.
    getLanguageIdByMimeType: *const fn (context: *anyopaque, mimeType: ?[]const u8) ?[]const u8,

    /// Guess the language id for a resource.
    guessLanguageIdByFilepathOrFirstLine: *const fn (context: *anyopaque, resource: Uri, firstLine: ?[]const u8) ?[]const u8,

    /// Will fall back to 'plaintext' if `languageId` is unknown.
    createById: *const fn (context: *anyopaque, languageId: ?[]const u8) ILanguageSelection,

    /// Will fall back to 'plaintext' if `mimeType` is unknown.
    createByMimeType: *const fn (context: *anyopaque, mimeType: ?[]const u8) ILanguageSelection,

    /// Will fall back to 'plaintext' if the `languageId` cannot be determined.
    createByFilepathOrFirstLine: *const fn (context: *anyopaque, resource: ?Uri, firstLine: ?[]const u8) ILanguageSelection,

    /// Request basic language features for a language.
    requestBasicLanguageFeatures: *const fn (context: *anyopaque, languageId: []const u8) void,

    /// Request rich language features for a language.
    requestRichLanguageFeatures: *const fn (context: *anyopaque, languageId: []const u8) void,

    pub fn getLanguageIdCodec(self: ILanguageService) *ILanguageIdCodec {
        return self.languageIdCodec(self.context);
    }
};

test "ILanguageExtensionPoint: only the id is required" {
    const def = ILanguageExtensionPoint{ .id = "zig" };
    try std.testing.expectEqualStrings("zig", def.id);
    try std.testing.expectEqual(@as(?[]const []const u8, null), def.extensions);
    try std.testing.expectEqual(@as(?Uri, null), def.configuration);
    try std.testing.expectEqual(@as(?ILanguageIcon, null), def.icon);
}

test "ILanguageNameIdPair and ILanguageIcon" {
    const pair = ILanguageNameIdPair{ .languageName = "Zig", .languageId = "zig" };
    try std.testing.expectEqualStrings("Zig", pair.languageName);

    const icon = ILanguageIcon{
        .light = std.Uri.parse("file:///light.svg") catch unreachable,
        .dark = std.Uri.parse("file:///dark.svg") catch unreachable,
    };
    try std.testing.expectEqualStrings("file", icon.light.scheme);
}

test "ILanguageService: exposes the decorator id" {
    try std.testing.expectEqualStrings("languageService", ILanguageServiceDecoratorId);
}
