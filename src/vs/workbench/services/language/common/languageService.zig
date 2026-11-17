// Port of the portable subset of
// `src/vs/workbench/services/language/common/languageService.ts`.
//
// Terminal adaptations: contributions are registered explicitly (there is no
// extension host or extension-point collector), most `isValidLanguageExtensionPoint`
// checks are enforced by the typed `ILanguageExtensionPoint`, and configuration
// changes are not subscribed: the host calls `updateMime` after reloading the
// settings. `configuration` paths/icon URIs are carried through when present.
const std = @import("std");
const Allocator = std.mem.Allocator;

const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const editor_language = @import("../../../../editor/common/languages/language.zig");
const language_service_module = @import("../../../../editor/common/services/languageService.zig");

const IConfigurationService = configuration.IConfigurationService;
const ILanguageExtensionPoint = editor_language.ILanguageExtensionPoint;
const LanguageService = language_service_module.LanguageService;

/// Upstream `FILES_ASSOCIATIONS_CONFIG`.
pub const FILES_ASSOCIATIONS_CONFIG = "files.associations";

/// Port of `WorkbenchLanguageService` (registration and `files.associations`).
pub const WorkbenchLanguageService = struct {
    language_service: *LanguageService,
    configuration_service: ?IConfigurationService,

    pub fn init(
        language_service: *LanguageService,
        configuration_service: ?IConfigurationService,
    ) WorkbenchLanguageService {
        return .{
            .language_service = language_service,
            .configuration_service = configuration_service,
        };
    }

    /// Validates a contribution. The typed Zig representation already enforces
    /// the array/string types; the remaining upstream checks are the required
    /// id and the rule that `firstLine` is not empty when present.
    pub fn isValidLanguageExtensionPoint(self: *const WorkbenchLanguageService, contribution: ILanguageExtensionPoint) bool {
        _ = self;
        if (contribution.id.len == 0) return false;
        if (contribution.firstLine) |pattern| {
            if (pattern.len == 0) return false;
        }
        return true;
    }

    /// Registers one language contribution; returns false when it is invalid.
    pub fn registerLanguageContribution(self: *WorkbenchLanguageService, contribution: ILanguageExtensionPoint) !bool {
        if (!self.isValidLanguageExtensionPoint(contribution)) return false;
        try self.language_service.registerLanguage(contribution);
        return true;
    }

    /// Registers every valid contribution and returns the number registered.
    pub fn registerExtensionPoint(self: *WorkbenchLanguageService, contributions: []const ILanguageExtensionPoint) !usize {
        var registered: usize = 0;
        for (contributions) |contribution| {
            if (try self.registerLanguageContribution(contribution)) registered += 1;
        }
        return registered;
    }

    /// Port of `updateMime`: clears the configured associations and registers
    /// the `files.associations` patterns from the configuration.
    pub fn updateMime(self: *WorkbenchLanguageService) !void {
        self.language_service.clearConfiguredLanguageAssociations();

        const configuration_service = self.configuration_service orelse {
            self.language_service.notifyLanguageChange();
            return;
        };
        const associations_value = configuration_service.getValue(FILES_ASSOCIATIONS_CONFIG) orelse {
            self.language_service.notifyLanguageChange();
            return;
        };
        if (associations_value.* != .object) {
            self.language_service.notifyLanguageChange();
            return;
        }

        var iterator = associations_value.object.iterator();
        while (iterator.next()) |entry| {
            const language_id = switch (entry.value_ptr.*) {
                .string => |value| value,
                // Ignore non-string associations (upstream logs a warning).
                else => continue,
            };
            var mime_buffer: [256]u8 = undefined;
            const mime = self.language_service.getMimeType(language_id) orelse
                std.fmt.bufPrint(&mime_buffer, "text/x-{s}", .{language_id}) catch continue;

            try self.language_service.registerConfiguredLanguageAssociation(.{
                .id = language_id,
                .mime = mime,
                .filepattern = entry.key_ptr.*,
            });
        }

        self.language_service.notifyLanguageChange();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Value = configuration.Value;
const languages = @import("../../../../editor/common/languages.zig");
const LanguageIdCodec = languages.LanguageIdCodec;

const TestConfigurationService = struct {
    allocator: Allocator,
    values: std.StringHashMap(*Value),

    fn init(allocator: Allocator) TestConfigurationService {
        return .{ .allocator = allocator, .values = std.StringHashMap(*Value).init(allocator) };
    }

    fn deinit(self: *TestConfigurationService) void {
        var iterator = self.values.valueIterator();
        while (iterator.next()) |value| self.allocator.destroy(value.*);
        self.values.deinit();
    }

    fn setValue(self: *TestConfigurationService, key: []const u8, value: Value) !void {
        if (self.values.get(key)) |existing| {
            existing.* = value;
            return;
        }
        const stored = try self.allocator.create(Value);
        stored.* = value;
        try self.values.put(key, stored);
    }

    fn getValue(context: *anyopaque, key: []const u8) ?*const Value {
        const self: *TestConfigurationService = @ptrCast(@alignCast(context));
        return self.values.get(key);
    }

    fn interface(self: *TestConfigurationService) IConfigurationService {
        return .{ .context = self, .get_value = getValue };
    }
};

const TestHarness = struct {
    codec: LanguageIdCodec,
    language_service: LanguageService,
    workbench_service: WorkbenchLanguageService,

    fn init(self: *TestHarness, allocator: Allocator) !void {
        self.codec = try LanguageIdCodec.init(allocator);
        errdefer self.codec.deinit();
        self.language_service = LanguageService.init(allocator, &self.codec);
        errdefer self.language_service.deinit();
        self.workbench_service = WorkbenchLanguageService.init(&self.language_service, null);
    }

    fn deinit(self: *TestHarness) void {
        self.language_service.deinit();
        self.codec.deinit();
    }
};

test "workbench language service: validates and registers contributions" {
    const allocator = testing.allocator;
    var service: TestHarness = undefined;
    try service.init(allocator);
    defer service.deinit();

    try testing.expect(!try service.workbench_service.registerLanguageContribution(.{ .id = "" }));
    try testing.expect(try service.workbench_service.registerLanguageContribution(.{
        .id = "foo",
        .extensions = &.{".foo"},
        .aliases = &.{"Foo"},
    }));
    try testing.expectEqualStrings("foo", service.language_service.guessLanguageIdByFilepathOrFirstLine("x.foo", null).?);

    // Multi-contribution registration skips invalid entries.
    const contributions = [_]ILanguageExtensionPoint{
        .{ .id = "bar", .extensions = &.{".bar"} },
        .{ .id = "" },
        .{ .id = "baz", .firstLine = "^#!baz" },
    };
    try testing.expectEqual(@as(usize, 2), try service.workbench_service.registerExtensionPoint(&contributions));
    try testing.expectEqualStrings("bar", service.language_service.guessLanguageIdByFilepathOrFirstLine("x.bar", null).?);
    try testing.expectEqualStrings("baz", service.language_service.guessLanguageIdByFilepathOrFirstLine("script", "#!baz").?);
}

test "workbench language service: configured associations from files.associations" {
    const allocator = testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var language_service = LanguageService.init(allocator, &codec);
    defer language_service.deinit();

    try language_service.registerLanguage(.{ .id = "foo", .extensions = &.{".foo"} });
    try language_service.registerLanguage(.{ .id = "bar", .filenames = &.{"Makefile"} });
    try language_service.registerLanguage(.{ .id = "qux", .extensions = &.{".qux"} });

    var configuration_service = TestConfigurationService.init(allocator);
    defer configuration_service.deinit();
    var associations: std.json.ObjectMap = .empty;
    defer associations.deinit(allocator);
    try associations.put(allocator, "*.foo", .{ .string = "bar" });
    try associations.put(allocator, "Makefile", .{ .string = "qux" });
    try associations.put(allocator, "*.qux", .{ .integer = 42 });
    try configuration_service.setValue(FILES_ASSOCIATIONS_CONFIG, .{ .object = associations });

    var workbench_service = WorkbenchLanguageService.init(&language_service, configuration_service.interface());
    try workbench_service.updateMime();

    // Configured patterns win over the platform associations.
    try testing.expectEqualStrings("bar", language_service.guessLanguageIdByFilepathOrFirstLine("x.foo", null).?);
    try testing.expectEqualStrings("qux", language_service.guessLanguageIdByFilepathOrFirstLine("Makefile", null).?);
    // Non-string association values are ignored.
    try testing.expectEqualStrings("qux", language_service.guessLanguageIdByFilepathOrFirstLine("x.qux", null).?);

    // Clearing the configured patterns restores the platform associations.
    var empty_associations: std.json.ObjectMap = .empty;
    defer empty_associations.deinit(allocator);
    try configuration_service.setValue(FILES_ASSOCIATIONS_CONFIG, .{ .object = empty_associations });
    try workbench_service.updateMime();
    try testing.expectEqualStrings("foo", language_service.guessLanguageIdByFilepathOrFirstLine("x.foo", null).?);
}
