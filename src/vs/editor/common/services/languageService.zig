const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const Uri = std.Uri;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const LanguageConfiguration = @import("../languages/languageConfiguration.zig").LanguageConfiguration;
const LanguageConfigurationServiceChangeEvent = @import("../languages/languageConfigurationRegistry.zig").LanguageConfigurationServiceChangeEvent;

const language = @import("../languages/language.zig");
const languages_associations = @import("./languagesAssociations.zig");
const PLAINTEXT_LANGUAGE_ID = "plaintext";

const LanguageRegistryEntry = struct {
    id: []const u8,
    aliases: ?[]const []const u8 = null,
    extensions: ?[]const []const u8 = null,
    filenames: ?[]const []const u8 = null,
    filename_patterns: ?[]const []const u8 = null,
    mimetypes: ?[]const []const u8 = null,
    first_line: ?[]const u8 = null,
    icon: ?LanguageIcon = null,
    configuration: ?Uri = null,
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
    arena: std.heap.ArenaAllocator,
    languages: std.StringHashMap(LanguageRegistryEntry),
    mime_types: std.StringHashMap([]const u8),
    language_names: std.StringHashMap([]const u8),
    changed: Emitter(void),
    selections: std.array_list.Managed(*Selection),
    /// Path/first-line language associations, created on the first language
    /// registration (upstream keeps a module-level registry).
    associations: ?*languages_associations.LanguageAssociations,

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

    // Upstream `ILanguageConfigurationService.onDidChange`: fired when a
    // language configuration is registered or replaced.
    onDidChangeLanguageConfiguration: Emitter(LanguageConfigurationServiceChangeEvent),

    pub fn init(allocator: Allocator, languageIdCodec: *LanguageIdCodec) LanguageService {
        return LanguageService{
            .languageIdCodec = languageIdCodec,
            ._languageConfigurations = std.StringHashMap(LanguageConfiguration).init(allocator),
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .languages = std.StringHashMap(LanguageRegistryEntry).init(allocator),
            .mime_types = std.StringHashMap([]const u8).init(allocator),
            .language_names = std.StringHashMap([]const u8).init(allocator),
            .changed = Emitter(void).init(allocator),
            .selections = std.array_list.Managed(*Selection).init(allocator),
            .associations = null,
            .onDidRequestBasicLanguageFeatures = Emitter([]const u8).init(allocator),
            .onDidRequestRichLanguageFeatures = Emitter([]const u8).init(allocator),
            .onDidChange = Emitter(void).init(allocator),
            .onDidChangeLanguageConfiguration = Emitter(LanguageConfigurationServiceChangeEvent).init(allocator),
        };
    }

    pub fn registerLanguage(self: *LanguageService, def: ILanguageExtensionPoint) !void {
        const arena = self.arena.allocator();
        if (self.languages.getPtr(def.id)) |existing| {
            if (def.extensions) |extensions| existing.extensions = try appendSlices(arena, existing.extensions, extensions);
            if (def.filenames) |filenames| existing.filenames = try appendSlices(arena, existing.filenames, filenames);
            if (def.aliases) |aliases| {
                if (aliases.len > 0) {
                    existing.aliases = aliases;
                    for (aliases) |alias| try self.language_names.put(try arena.dupe(u8, alias), existing.id);
                }
            }
            if (def.firstLine) |first_line| {
                if (existing.first_line == null) existing.first_line = first_line;
            }
            if (def.icon) |icon| existing.icon = icon;
            if (def.configuration) |configuration| existing.configuration = configuration;
            try self.registerAssociations(def);
            try self.changed.fire({});
            for (self.selections.items) |selection| try selection.refresh();
            return;
        }

        const id = try arena.dupe(u8, def.id);
        var aliases = def.aliases orelse &.{};
        if (aliases.len == 0) {
            const fallback = try arena.alloc([]const u8, 1);
            fallback[0] = id;
            aliases = fallback;
        }
        var mime_types = def.mimetypes orelse &.{};
        if (mime_types.len == 0) {
            const fallback = try arena.alloc([]const u8, 1);
            fallback[0] = try std.fmt.allocPrint(arena, "text/x-{s}", .{id});
            mime_types = fallback;
        }
        try self.languages.put(id, .{
            .id = id,
            .aliases = aliases,
            .extensions = def.extensions,
            .filenames = def.filenames,
            .filename_patterns = def.filenamePatterns,
            .mimetypes = mime_types,
            .first_line = def.firstLine,
            .icon = def.icon,
            .configuration = def.configuration,
        });
        for (mime_types) |mime| try self.mime_types.put(try arena.dupe(u8, mime), id);
        for (aliases) |alias| try self.language_names.put(try arena.dupe(u8, alias), id);
        try self.registerAssociations(def);
        try self.changed.fire({});
        for (self.selections.items) |selection| try selection.refresh();
    }

    fn appendSlices(arena: Allocator, existing: ?[]const []const u8, extra: []const []const u8) ![]const []const u8 {
        const old = existing orelse &.{};
        const result = try arena.alloc([]const u8, old.len + extra.len);
        @memcpy(result[0..old.len], old);
        @memcpy(result[old.len..], extra);
        return result;
    }

    fn ensureAssociations(self: *LanguageService) !*languages_associations.LanguageAssociations {
        if (self.associations) |associations| return associations;
        const associations = try languages_associations.LanguageAssociations.init(self.allocator);
        self.associations = associations;
        return associations;
    }

    /// Registers the path/first-line associations of a language contribution.
    /// `firstLine` stays in the language registry: upstream stores a `RegExp`,
    /// the terminal matcher keeps the simple prefix/suffix form.
    fn registerAssociations(self: *LanguageService, def: ILanguageExtensionPoint) !void {
        if (def.extensions == null and def.filenames == null and def.filenamePatterns == null) return;
        const associations = try self.ensureAssociations();
        const mime = self.getMimeType(def.id) orelse try std.fmt.allocPrint(self.arena.allocator(), "text/x-{s}", .{def.id});
        if (def.extensions) |extensions| {
            for (extensions) |extension| {
                try associations.registerPlatform(.{ .id = def.id, .mime = mime, .extension = extension });
            }
        }
        if (def.filenames) |filenames| {
            for (filenames) |filename| {
                try associations.registerPlatform(.{ .id = def.id, .mime = mime, .filename = filename });
            }
        }
        if (def.filenamePatterns) |patterns| {
            for (patterns) |pattern| {
                try associations.registerPlatform(.{ .id = def.id, .mime = mime, .filepattern = pattern });
            }
        }
    }

    /// Registers a configured (user) language association; it wins over the
    /// platform associations derived from registered languages.
    pub fn registerConfiguredLanguageAssociation(self: *LanguageService, association: languages_associations.ILanguageAssociation) !void {
        const associations = try self.ensureAssociations();
        try associations.registerConfigured(association);
    }

    pub fn clearConfiguredLanguageAssociations(self: *LanguageService) void {
        if (self.associations) |associations| associations.clearConfigured();
    }

    /// Notifies selections after association changes (upstream fires
    /// `_onDidChange` and refreshes the registered language selections).
    pub fn notifyLanguageChange(self: *LanguageService) void {
        self.changed.fire({}) catch {};
        for (self.selections.items) |selection| selection.refresh() catch {};
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
            return entry.id;
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

    pub fn getLanguageIdByLanguageName(self: *LanguageService, language_name: []const u8) ?[]const u8 {
        if (self.language_names.get(language_name)) |id| return id;
        var iterator = self.language_names.iterator();
        while (iterator.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, language_name)) return entry.value_ptr.*;
        }
        return null;
    }

    pub fn getSortedRegisteredLanguageNames(self: *LanguageService, allocator: Allocator) ![]LanguageNameIdPair {
        var result = std.array_list.Managed(LanguageNameIdPair).init(allocator);
        var iterator = self.languages.valueIterator();
        while (iterator.next()) |entry| {
            if (entry.aliases) |aliases| {
                if (aliases.len > 0) try result.append(.{ .languageName = aliases[0], .languageId = entry.id });
            }
        }
        std.mem.sort(LanguageNameIdPair, result.items, {}, struct {
            fn lessThan(_: void, a: LanguageNameIdPair, b: LanguageNameIdPair) bool {
                const length = @min(a.languageName.len, b.languageName.len);
                var index: usize = 0;
                while (index < length) : (index += 1) {
                    const ca = std.ascii.toLower(a.languageName[index]);
                    const cb = std.ascii.toLower(b.languageName[index]);
                    if (ca != cb) return ca < cb;
                }
                return a.languageName.len < b.languageName.len;
            }
        }.lessThan);
        return result.toOwnedSlice();
    }

    pub fn getIcon(self: *LanguageService, language_id: []const u8) ?LanguageIcon {
        if (self.languages.get(language_id)) |entry| return entry.icon;
        return null;
    }

    pub fn getConfigurationFiles(self: *LanguageService, language_id: []const u8, allocator: Allocator) ![]const Uri {
        if (self.languages.get(language_id)) |entry| {
            if (entry.configuration) |configuration| {
                const result = try allocator.alloc(Uri, 1);
                result[0] = configuration;
                return result;
            }
        }
        return allocator.alloc(Uri, 0);
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

    pub fn createByFilepathOrFirstLine(self: *LanguageService, path: ?[]const u8, first_line: ?[]const u8) !*Selection {
        const selection = try self.allocator.create(Selection);
        selection.* = .{
            .service = self,
            .requested_id = null,
            .path = path,
            .first_line = first_line,
            .emitter = Emitter([]const u8).init(self.allocator),
        };
        try self.selections.append(selection);
        return selection;
    }

    /// Guesses a language id from a path extension/filename/pattern or a first
    /// line. Path matching goes through the ported language associations
    /// (filename > pattern > longest extension, later registrations win).
    pub fn guessLanguageIdByFilepathOrFirstLine(self: *LanguageService, path: ?[]const u8, first_line: ?[]const u8) ?[]const u8 {
        if (self.associations) |associations| {
            if (path) |value| {
                const result = associations.getAssociationsForPath(value, null);
                const id = result.items[0].id;
                if (!std.mem.eql(u8, id, languages_associations.UNKNOWN_ID)) return id;
            }
        }

        // First line has the lowest priority.
        if (first_line) |line| {
            var iterator = self.languages.iterator();
            while (iterator.next()) |entry| {
                const registry_entry = entry.value_ptr;
                if (registry_entry.first_line) |pattern| {
                    var prefix = pattern;
                    if (prefix.len > 0 and prefix[0] == '^') prefix = prefix[1..];
                    if (prefix.len > 0 and prefix[prefix.len - 1] == '$') {
                        if (std.mem.eql(u8, line, prefix[0 .. prefix.len - 1])) return registry_entry.id;
                    } else if (std.mem.startsWith(u8, line, prefix)) {
                        return registry_entry.id;
                    }
                }
            }
        }
        return null;
    }

    pub fn requestBasicLanguageFeatures(self: *LanguageService, language_id: []const u8) void {
        self.onDidRequestBasicLanguageFeatures.fire(language_id) catch {};
    }

    pub fn requestRichLanguageFeatures(self: *LanguageService, language_id: []const u8) void {
        self.requestBasicLanguageFeatures(language_id);
        self.onDidRequestRichLanguageFeatures.fire(language_id) catch {};
    }

    /// Registers a language configuration. The service takes ownership of the
    /// compiled regexes in `configuration` and frees them on replacement or
    /// `deinit`.
    pub fn registerLanguageConfiguration(self: *LanguageService, languageId: []const u8, configuration: LanguageConfiguration) !void {
        if (self._languageConfigurations.getEntry(languageId)) |entry| {
            entry.value_ptr.deinit();
            entry.value_ptr.* = configuration;
            self.onDidChangeLanguageConfiguration.fire(.{ .languageId = languageId }) catch {};
            return;
        }
        const key = try self._languageConfigurations.allocator.dupe(u8, languageId);
        errdefer self._languageConfigurations.allocator.free(key);
        try self._languageConfigurations.put(key, configuration);
        self.onDidChangeLanguageConfiguration.fire(.{ .languageId = languageId }) catch {};
    }

    pub fn getLanguageConfiguration(self: *LanguageService, languageId: []const u8) ?LanguageConfiguration {
        return self._languageConfigurations.get(languageId);
    }

    pub fn deinit(self: *LanguageService) void {
        var configIter = self._languageConfigurations.valueIterator();
        while (configIter.next()) |configuration| configuration.deinit();
        var keyIter = self._languageConfigurations.keyIterator();
        while (keyIter.next()) |key| self._languageConfigurations.allocator.free(key.*);
        for (self.selections.items) |selection| {
            selection.emitter.deinit();
            self.allocator.destroy(selection);
        }
        self.selections.deinit();
        if (self.associations) |associations| associations.deinit();
        self.languages.deinit();
        self.mime_types.deinit();
        self.language_names.deinit();
        self.arena.deinit();
        self.changed.deinit();
        self._languageConfigurations.deinit();
        self.onDidRequestBasicLanguageFeatures.deinit();
        self.onDidRequestRichLanguageFeatures.deinit();
        self.onDidChange.deinit();
        self.onDidChangeLanguageConfiguration.deinit();
    }
};

pub const Selection = struct {
    service: *LanguageService,
    requested_id: ?[]const u8,
    path: ?[]const u8 = null,
    first_line: ?[]const u8 = null,
    emitter: Emitter([]const u8),

    pub fn interface(self: *Selection) language.ILanguageSelection {
        return .{ .context = self, .get_language_id = getLanguageId, .onDidChange = &self.emitter };
    }

    fn getLanguageId(context: *anyopaque) []const u8 {
        const self: *Selection = @ptrCast(@alignCast(context));
        if (self.requested_id) |id| {
            if (self.service.isRegisteredLanguageId(id)) return id;
            return PLAINTEXT_LANGUAGE_ID;
        }
        if (self.service.guessLanguageIdByFilepathOrFirstLine(self.path, self.first_line)) |id| return id;
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
