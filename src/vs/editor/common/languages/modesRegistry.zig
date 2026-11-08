// Port of `src/vs/editor/common/languages/modesRegistry.ts`.
//
// Divergences from the TypeScript module:
//
//  * There is no `platform/registry` in this port, so `ModesRegistry` is a
//    module-level instance instead of an entry added to `Registry`.
//  * There is no configuration registry either. The `[language]` default
//    overrides that upstream registers through it are kept as data in
//    `default_configuration_overrides`, and the `'Plain Text'` alias is a plain
//    string (no `nls.localize`).
//  * Module level code does not run on import, so the `plaintext` language is
//    registered by `registerPlaintextLanguage` rather than at load time.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const event = @import("../../../base/common/event.zig");
const Emitter = event.Emitter;
const lifecycle = @import("../../../base/common/lifecycle.zig");
const IDisposable = lifecycle.IDisposable;

const language = @import("./language.zig");
const ILanguageExtensionPoint = language.ILanguageExtensionPoint;

// Define extension point ids
pub const Extensions = struct {
    pub const ModesRegistry = "editor.modesRegistry";
};

pub const PLAINTEXT_LANGUAGE_ID = "plaintext";
pub const PLAINTEXT_EXTENSION = ".txt";

/// The `Mimes.text` value of `base/common/mime.ts`; there is no mime module in
/// this port yet.
pub const PLAINTEXT_MIMETYPE = "text/plain";

pub const PLAINTEXT_ALIASES = [_][]const u8{ "Plain Text", "text" };

const Registration = struct {
    registry: *EditorModesRegistry,
    id: u64,
    disposed: bool = false,

    fn dispose(context: *anyopaque) void {
        const self: *Registration = @ptrCast(@alignCast(context));
        if (self.disposed) {
            return;
        }
        self.disposed = true;
        self.registry.removeLanguage(self.id);
    }
};

/// Holds the language extension points contributed by extensions.
pub const EditorModesRegistry = struct {
    allocator: Allocator,
    _languages: ArrayList(ILanguageExtensionPoint),
    _ids: ArrayList(u64),
    _registrations: ArrayList(*Registration),
    _onDidChangeLanguages: Emitter(void),
    _next_id: u64,

    pub fn init(allocator: Allocator) EditorModesRegistry {
        return .{
            .allocator = allocator,
            ._languages = ArrayList(ILanguageExtensionPoint).init(allocator),
            ._ids = ArrayList(u64).init(allocator),
            ._registrations = ArrayList(*Registration).init(allocator),
            ._onDidChangeLanguages = Emitter(void).init(allocator),
            ._next_id = 0,
        };
    }

    pub fn deinit(self: *EditorModesRegistry) void {
        for (self._registrations.items) |registration| {
            self.allocator.destroy(registration);
        }
        self._registrations.deinit();
        self._ids.deinit();
        self._languages.deinit();
        self._onDidChangeLanguages.deinit();
    }

    pub fn onDidChangeLanguages(self: *EditorModesRegistry) *Emitter(void) {
        return &self._onDidChangeLanguages;
    }

    /// Registers `def` and returns a disposable that removes it again.
    ///
    /// The returned disposable owns a small heap allocation which is released
    /// either when it is disposed or when the registry is deinitialized.
    pub fn registerLanguage(self: *EditorModesRegistry, def: ILanguageExtensionPoint) !IDisposable {
        const registration = try self.allocator.create(Registration);
        errdefer self.allocator.destroy(registration);

        self._next_id += 1;
        try self._languages.append(def);
        errdefer _ = self._languages.pop();
        try self._ids.append(self._next_id);
        errdefer _ = self._ids.pop();
        try self._registrations.append(registration);
        errdefer _ = self._registrations.pop();

        registration.* = .{ .registry = self, .id = self._next_id };

        try self._onDidChangeLanguages.fire({});
        return .{ .context = registration, .disposeFn = Registration.dispose };
    }

    pub fn getLanguages(self: *const EditorModesRegistry) []const ILanguageExtensionPoint {
        return self._languages.items;
    }

    fn removeLanguage(self: *EditorModesRegistry, id: u64) void {
        for (self._ids.items, 0..) |registered_id, index| {
            if (registered_id == id) {
                _ = self._ids.orderedRemove(index);
                _ = self._languages.orderedRemove(index);
                self._onDidChangeLanguages.fire({}) catch {};
                return;
            }
        }
    }
};

/// The process-wide registry of language extension points.
pub var ModesRegistry: EditorModesRegistry = EditorModesRegistry.init(std.heap.page_allocator);

/// Registers the built-in `plaintext` language, as the TypeScript module does
/// at load time.
pub fn registerPlaintextLanguage(registry: *EditorModesRegistry) !IDisposable {
    return registry.registerLanguage(.{
        .id = PLAINTEXT_LANGUAGE_ID,
        .extensions = &[_][]const u8{PLAINTEXT_EXTENSION},
        .aliases = &PLAINTEXT_ALIASES,
        .mimetypes = &[_][]const u8{PLAINTEXT_MIMETYPE},
    });
}

pub const OverrideValue = union(enum) {
    boolean: bool,
    number: usize,
    string: []const u8,
};

pub const DefaultConfigurationOverride = struct {
    languageId: []const u8,
    key: []const u8,
    value: OverrideValue,
};

/// The `[language]` default configuration overrides that upstream registers
/// with the configuration registry.
pub const default_configuration_overrides = [_]DefaultConfigurationOverride{
    .{ .languageId = "[plaintext]", .key = "editor.unicodeHighlight.ambiguousCharacters", .value = .{ .boolean = false } },
    .{ .languageId = "[plaintext]", .key = "editor.unicodeHighlight.invisibleCharacters", .value = .{ .boolean = false } },
    // TODO: Below is a workaround for: https://github.com/microsoft/vscode/issues/240567
    .{ .languageId = "[go]", .key = "editor.insertSpaces", .value = .{ .boolean = false } },
    .{ .languageId = "[makefile]", .key = "editor.insertSpaces", .value = .{ .boolean = false } },
    .{ .languageId = "[shellscript]", .key = "files.eol", .value = .{ .string = "\n" } },
    .{ .languageId = "[yaml]", .key = "editor.insertSpaces", .value = .{ .boolean = true } },
    .{ .languageId = "[yaml]", .key = "editor.tabSize", .value = .{ .number = 2 } },
};

test "EditorModesRegistry: register and dispose a language" {
    const allocator = std.testing.allocator;
    var registry = EditorModesRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.getLanguages().len);

    var change_count: usize = 0;
    const Listener = struct {
        fn onDidChange(_: void, count: *usize) !void {
            count.* += 1;
        }
    };
    try registry.onDidChangeLanguages().event(&change_count, Listener.onDidChange);

    const disposable = try registry.registerLanguage(.{ .id = "zig", .extensions = &[_][]const u8{".zig"} });
    try std.testing.expectEqual(@as(usize, 1), registry.getLanguages().len);
    try std.testing.expectEqualStrings("zig", registry.getLanguages()[0].id);
    try std.testing.expectEqual(@as(usize, 1), change_count);

    disposable.dispose();
    try std.testing.expectEqual(@as(usize, 0), registry.getLanguages().len);
    try std.testing.expectEqual(@as(usize, 2), change_count);

    // Disposing twice must not remove another language.
    const second = try registry.registerLanguage(.{ .id = "other" });
    disposable.dispose();
    try std.testing.expectEqual(@as(usize, 1), registry.getLanguages().len);
    try std.testing.expectEqualStrings("other", registry.getLanguages()[0].id);
    second.dispose();
    try std.testing.expectEqual(@as(usize, 0), registry.getLanguages().len);
}

test "registerPlaintextLanguage: registers the plaintext extension point" {
    const allocator = std.testing.allocator;
    var registry = EditorModesRegistry.init(allocator);
    defer registry.deinit();

    const disposable = try registerPlaintextLanguage(&registry);
    defer disposable.dispose();

    const languages = registry.getLanguages();
    try std.testing.expectEqual(@as(usize, 1), languages.len);
    try std.testing.expectEqualStrings("plaintext", languages[0].id);
    try std.testing.expectEqualStrings(".txt", languages[0].extensions.?[0]);
    try std.testing.expectEqualStrings("Plain Text", languages[0].aliases.?[0]);
    try std.testing.expectEqualStrings("text/plain", languages[0].mimetypes.?[0]);
}

test "default_configuration_overrides: matches upstream" {
    try std.testing.expectEqual(@as(usize, 7), default_configuration_overrides.len);

    const yaml_tab_size = default_configuration_overrides[6];
    try std.testing.expectEqualStrings("[yaml]", yaml_tab_size.languageId);
    try std.testing.expectEqualStrings("editor.tabSize", yaml_tab_size.key);
    try std.testing.expectEqual(@as(usize, 2), yaml_tab_size.value.number);

    const shellscript_eol = default_configuration_overrides[4];
    try std.testing.expectEqualStrings("\n", shellscript_eol.value.string);
}

test "Extensions: modes registry id" {
    try std.testing.expectEqualStrings("editor.modesRegistry", Extensions.ModesRegistry);
}
