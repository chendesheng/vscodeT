const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const Uri = std.Uri;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const LanguageConfiguration = @import("../languages/languageConfiguration.zig").LanguageConfiguration;

const language = @import("../languages/language.zig");
const PLAINTEXT_LANGUAGE_ID = "plaintext";

const LanguageRegistryEntry = struct {
    id: []const u8,
    aliases: ?[]const []const u8 = null,
    extensions: ?[]const []const u8 = null,
    filenames: ?[]const []const u8 = null,
    mimetypes: ?[]const []const u8 = null,
    first_line: ?[]const u8 = null,
};

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
    allocator: Allocator,
    languages: std.StringHashMap(LanguageRegistryEntry),
    mime_types: std.StringHashMap([]const u8),
    language_names: std.StringHashMap([]const u8),
    changed: Emitter(void),
    selections: std.array_list.Managed(*Selection),

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

    pub fn init(allocator: Allocator, languageIdCodec: *LanguageIdCodec) LanguageService {
        return LanguageService{
            .languageIdCodec = languageIdCodec,
            ._languageConfigurations = std.StringHashMap(LanguageConfiguration).init(allocator),
            .allocator = allocator,
            .languages = std.StringHashMap(LanguageRegistryEntry).init(allocator),
            .mime_types = std.StringHashMap([]const u8).init(allocator),
            .language_names = std.StringHashMap([]const u8).init(allocator),
            .changed = Emitter(void).init(allocator),
            .selections = std.array_list.Managed(*Selection).init(allocator),
            .onDidRequestBasicLanguageFeatures = Emitter([]const u8).init(allocator),
            .onDidRequestRichLanguageFeatures = Emitter([]const u8).init(allocator),
            .onDidChange = Emitter(void).init(allocator),
        };
    }

    pub fn registerLanguage(self: *LanguageService, def: ILanguageExtensionPoint) !void {
        const id = try self.allocator.dupe(u8, def.id);
        try self.languages.put(id, .{
            .id = id,
            .aliases = def.aliases,
            .extensions = def.extensions,
            .filenames = def.filenames,
            .mimetypes = def.mimetypes,
            .first_line = def.firstLine,
        });
        if (def.mimetypes) |mime_types| {
            for (mime_types) |mime| try self.mime_types.put(try self.allocator.dupe(u8, mime), id);
        }
        if (def.aliases) |aliases| {
            for (aliases) |alias| try self.language_names.put(try self.allocator.dupe(u8, alias), id);
        }
        try self.changed.fire({});
        for (self.selections.items) |selection| try selection.refresh();
    }

    pub fn isRegisteredLanguageId(self: *LanguageService, language_id: []const u8) bool {
        return self.languages.contains(language_id);
    }

    pub fn getRegisteredLanguageIds(self: *LanguageService, allocator: Allocator) ![]const []const u8 {
        var result = std.array_list.Managed([]const u8).init(allocator);
        var iterator = self.languages.keyIterator();
        while (iterator.next()) |key| try result.append(key.*);
        return result.toOwnedSlice();
    }

    pub fn getLanguageName(self: *LanguageService, language_id: []const u8) ?[]const u8 {
        if (self.languages.get(language_id)) |entry| {
            if (entry.aliases) |aliases| {
                if (aliases.len > 0) return aliases[0];
            }
        }
        return null;
    }

    pub fn getMimeType(self: *LanguageService, language_id: []const u8) ?[]const u8 {
        if (self.languages.get(language_id)) |entry| {
            if (entry.mimetypes) |mime_types| {
                if (mime_types.len > 0) return mime_types[0];
            }
        }
        return null;
    }

    pub fn getLanguageIdByMimeType(self: *LanguageService, mime_type: []const u8) ?[]const u8 {
        return self.mime_types.get(mime_type);
    }

    pub fn getExtensions(self: *LanguageService, language_id: []const u8) []const []const u8 {
        if (self.languages.get(language_id)) |entry| return entry.extensions orelse &.{};
        return &.{};
    }

    pub fn getFilenames(self: *LanguageService, language_id: []const u8) []const []const u8 {
        if (self.languages.get(language_id)) |entry| return entry.filenames orelse &.{};
        return &.{};
    }

    pub fn createById(self: *LanguageService, language_id: ?[]const u8) !*Selection {
        const selection = try self.allocator.create(Selection);
        selection.* = .{ .service = self, .requested_id = language_id, .emitter = Emitter([]const u8).init(self.allocator) };
        try self.selections.append(selection);
        return selection;
    }

    pub fn createByMimeType(self: *LanguageService, mime_type: ?[]const u8) !*Selection {
        const language_id = if (mime_type) |mime| self.getLanguageIdByMimeType(mime) else null;
        return self.createById(language_id);
    }

    pub fn requestBasicLanguageFeatures(self: *LanguageService, language_id: []const u8) void {
        self.onDidRequestBasicLanguageFeatures.fire(language_id) catch {};
    }

    pub fn requestRichLanguageFeatures(self: *LanguageService, language_id: []const u8) void {
        self.requestBasicLanguageFeatures(language_id);
        self.onDidRequestRichLanguageFeatures.fire(language_id) catch {};
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
        for (self.selections.items) |selection| {
            selection.emitter.deinit();
            self.allocator.destroy(selection);
        }
        self.selections.deinit();
        var language_keys = self.languages.keyIterator();
        while (language_keys.next()) |key| self.allocator.free(key.*);
        self.languages.deinit();
        var mime_keys = self.mime_types.keyIterator();
        while (mime_keys.next()) |key| self.allocator.free(key.*);
        self.mime_types.deinit();
        var name_keys = self.language_names.keyIterator();
        while (name_keys.next()) |key| self.allocator.free(key.*);
        self.language_names.deinit();
        self.changed.deinit();
        self._languageConfigurations.deinit();
        self.onDidRequestBasicLanguageFeatures.deinit();
        self.onDidRequestRichLanguageFeatures.deinit();
        self.onDidChange.deinit();
    }
};

pub const Selection = struct {
    service: *LanguageService,
    requested_id: ?[]const u8,
    emitter: Emitter([]const u8),

    pub fn interface(self: *Selection) language.ILanguageSelection {
        return .{ .context = self, .get_language_id = getLanguageId, .onDidChange = &self.emitter };
    }

    fn getLanguageId(context: *anyopaque) []const u8 {
        const self: *Selection = @ptrCast(@alignCast(context));
        if (self.requested_id) |id| {
            if (self.service.isRegisteredLanguageId(id)) return id;
        }
        return PLAINTEXT_LANGUAGE_ID;
    }

    pub fn refresh(self: *Selection) !void {
        try self.emitter.fire(getLanguageId(self));
    }

    pub fn deinit(self: *Selection) void {
        const allocator = self.service.allocator;
        for (self.service.selections.items, 0..) |candidate, index| {
            if (candidate == self) {
                _ = self.service.selections.orderedRemove(index);
                break;
            }
        }
        self.emitter.deinit();
        allocator.destroy(self);
    }
};
