// Port of the active-theme subset of
// `src/vs/workbench/services/themes/browser/workbenchThemeService.ts`.
//
// Terminal adaptations: themes are registered explicitly (no extension point),
// file icon definitions use terminal glyphs. The
// active color theme is persisted by id in the storage service.
//
// Async terminal adaptation: `prepareTheme` reads/parses a theme and its
// `include` chain on a worker Io; `applyPreparedTheme` swaps the active theme,
// persists the id and fires `onDidColorThemeChange` on the TUI thread. The
// synchronous `activate` path remains for startup and tests.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const color_utils = @import("../../../../platform/theme/common/colorUtils.zig");
const theme_service = @import("../../../../platform/theme/common/themeService.zig");
const theme_mod = @import("../../../../platform/theme/common/theme.zig");
const storage_mod = @import("../../../../platform/storage/common/storage.zig");
const color_theme = @import("../common/colorThemeData.zig");
const configuration_mod = @import("../../../../platform/configuration/common/configuration.zig");
const scheme_service = @import("../common/hostColorSchemeService.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const WindowQueue = dispatch.Queue;
const time_compat = @import("../../../../base/common/timeCompat.zig");

const FileIconThemeData = @import("fileIconThemeData.zig").FileIconThemeData;
const ConfigurationService = @import("../../configuration/browser/configurationService.zig").ConfigurationService;
const ExtensionRegistry = @import("../../extensions/common/extensionsRegistry.zig").Registry;
const ThemeColors = @import("../../../browser/themeColors.zig").ThemeColors;

const Value = configuration_mod.Value;

const ColorThemeData = color_theme.ColorThemeData;
const ResourceReader = color_theme.ResourceReader;
const IColorTheme = theme_service.IColorTheme;
const ColorScheme = theme_mod.ColorScheme;
const InMemoryStorageService = storage_mod.InMemoryStorageService;

pub const STORAGE_KEY = "workbench.theme.activeId";

pub const ThemeEntry = struct {
    label: []const u8,
    theme_type: ColorScheme,
    /// Extension/tree root for file-backed themes; null for the built-in
    /// empty fallback entries used by tests and the no-submodule path.
    root: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

/// Maps a contributed `uiTheme` to the ported color scheme enum.
pub fn colorSchemeForUiTheme(ui_theme: []const u8) ColorScheme {
    if (std.mem.eql(u8, ui_theme, "vs")) return .LIGHT;
    if (std.mem.eql(u8, ui_theme, "hc-black")) return .HIGH_CONTRAST_DARK;
    if (std.mem.eql(u8, ui_theme, "hc-light")) return .HIGH_CONTRAST_LIGHT;
    return .DARK;
}

/// Reads theme files and their `include` targets relative to an extension or
/// built-in theme root.
const FileResourceReader = struct {
    root: []const u8,
    io: Io,
    arena: std.heap.ArenaAllocator,

    fn read(context: *anyopaque, path: []const u8) anyerror![]const u8 {
        const self: *FileResourceReader = @ptrCast(@alignCast(context));
        const full_path = try std.fs.path.join(self.arena.allocator(), &.{ self.root, path });
        return std.Io.Dir.cwd().readFileAlloc(self.io, full_path, self.arena.allocator(), .unlimited);
    }

    fn interface(self: *FileResourceReader) ResourceReader {
        return .{ .context = self, .read = read };
    }
};

const ThemeLoadOutcome = union(enum) {
    theme: *ColorThemeData,
    err: anyerror,
};

/// One worker-thread color-theme load. The prepared theme is installed on the
/// TUI thread when the window receives its completion.
const ThemeLoadJob = struct {
    allocator: Allocator,
    io: Io,
    service: *ThemeService,
    future: Io.Future(ThemeLoadOutcome),
    completion: @import("../../../../base/common/windowDispatch.zig").Task,
    request: ThemeService.PrepareRequest,
};

fn runThemeLoadJob(job: *ThemeLoadJob) ThemeLoadOutcome {
    defer job.completion.post();
    const theme = dispatch.workerCall(job.io, ThemeService.prepareTheme, .{
        job.allocator, job.service.colors, &job.request, dispatch.backingIo(job.io),
    }) catch |err| return .{ .err = err };
    return .{ .theme = theme };
}

pub const ThemeService = struct {
    allocator: Allocator,
    colors: *color_utils.ColorRegistry,
    owns_colors: bool = false,
    storage: ?*InMemoryStorageService,
    themes: std.StringHashMap(ThemeEntry),
    active_id: []const u8,
    active: *ColorThemeData,
    onDidColorThemeChange: Emitter(void),
    current_file_icon_theme: FileIconThemeData = .{},
    onDidFileIconThemeChange: Emitter(FileIconThemeData),
    file_icon_registry: ?*const ExtensionRegistry = null,
    configuration: ?*ConfigurationService = null,
    configuration_listener: ?usize = null,
    theme_runtime: ?Runtime = null,
    theme_job: ?*ThemeLoadJob = null,
    theme_candidates: [3]?[]u8 = .{ null, null, null },
    theme_candidate_index: usize = 0,

    pub const Runtime = struct {
        io: Io,
        window: *WindowQueue,
        scheme: scheme_service.IHostColorSchemeService,
    };

    pub fn attachWindow(self: *ThemeService, runtime: Runtime) void {
        self.theme_runtime = runtime;
    }

    /// Native workbench registry owns the default colors. Standalone users
    /// that already have a registry continue to use init with a borrowed one.
    pub fn createDefault(allocator: Allocator, storage: ?*InMemoryStorageService) !*ThemeService {
        const registry = try allocator.create(color_utils.ColorRegistry);
        registry.* = color_utils.ColorRegistry.init(allocator);
        errdefer {
            registry.deinit();
            allocator.destroy(registry);
        }
        // VS Code's baseColors.ts and editorColors.ts supply these even for
        // themes such as Light High Contrast that omit editor colors.
        _ = try registry.registerColor("foreground", .{
            .dark = .{ .string = "#CCCCCC" },
            .light = .{ .string = "#616161" },
            .hc_dark = .{ .string = "#FFFFFF" },
            .hc_light = .{ .string = "#292929" },
        }, null, "Overall foreground color", false);
        _ = try registry.registerColor("editor.background", .{
            .dark = .{ .string = "#1E1E1E" },
            .light = .{ .string = "#FFFFFF" },
            .hc_dark = .{ .string = "#000000" },
            .hc_light = .{ .string = "#FFFFFF" },
        }, null, "Editor background color", false);
        _ = try registry.registerColor("editor.foreground", .{
            .dark = .{ .string = "#BBBBBB" },
            .light = .{ .string = "#333333" },
            .hc_dark = .{ .string = "#FFFFFF" },
            .hc_light = .{ .string = "foreground" },
        }, null, "Editor foreground color", false);
        const service = try init(allocator, registry, storage);
        service.owns_colors = true;
        return service;
    }

    pub fn init(allocator: Allocator, colors: *color_utils.ColorRegistry, storage: ?*InMemoryStorageService) !*ThemeService {
        const self = try allocator.create(ThemeService);
        errdefer allocator.destroy(self);
        const active = try ColorThemeData.createUnloadedTheme(allocator, colors, "vs-dark", &.{});
        self.* = .{
            .allocator = allocator,
            .colors = colors,
            .storage = storage,
            .themes = std.StringHashMap(ThemeEntry).init(allocator),
            .active_id = try allocator.dupe(u8, "vs-dark"),
            .active = active,
            .onDidColorThemeChange = Emitter(void).init(allocator),
            .onDidFileIconThemeChange = .init(allocator),
        };
        try self.registerTheme("vs-dark", "Dark (Visual Studio)", .DARK);
        return self;
    }

    /// Restores the persisted active theme. Call after registering themes so
    /// the stored id can be resolved.
    pub fn restore(self: *ThemeService) !void {
        const storage = self.storage orelse return;
        const id = storage.get(STORAGE_KEY, .profile, null) orelse return;
        if (!self.themes.contains(id)) return;
        try self.applyThemeId(id);
    }

    pub fn deinit(self: *ThemeService) void {
        self.cancelColorThemeLoad();
        self.active.deinit();
        self.themes.deinit();
        self.allocator.free(self.active_id);
        self.detachConfiguration();
        self.onDidFileIconThemeChange.deinit();
        self.onDidColorThemeChange.deinit();
        if (self.owns_colors) {
            self.colors.deinit();
            self.allocator.destroy(self.colors);
        }
        self.allocator.destroy(self);
    }

    pub fn getFileIconTheme(self: *const ThemeService) FileIconThemeData {
        return self.current_file_icon_theme;
    }

    pub fn setFileIconThemeRegistry(self: *ThemeService, registry: ?*const ExtensionRegistry) void {
        if (self.file_icon_registry == registry) return;
        self.file_icon_registry = registry;
        self.restoreFileIconTheme();
    }

    pub fn setConfiguration(self: *ThemeService, configuration: *ConfigurationService) !void {
        if (self.configuration == configuration) return;
        const listener = try configuration.listenConfigurationChange(self, onConfigurationChanged);
        self.detachConfiguration();
        self.configuration = configuration;
        self.configuration_listener = listener;
        self.restoreFileIconTheme();
    }

    pub fn detachConfiguration(self: *ThemeService) void {
        self.cancelColorThemeLoad();
        if (self.configuration_listener) |listener| self.configuration.?.unlistenConfigurationChange(listener);
        self.configuration_listener = null;
        self.configuration = null;
    }

    // Upstream installConfigurationListener: settings selection restores the
    // color theme; customization changes update the current theme directly.
    fn onConfigurationChanged(change: configuration_mod.Change, self: *ThemeService) !void {
        for ([_][]const u8{
            ThemeSettings.COLOR_THEME,
            ThemeSettings.PREFERRED_DARK_THEME,
            ThemeSettings.PREFERRED_LIGHT_THEME,
            ThemeSettings.PREFERRED_HC_DARK_THEME,
            ThemeSettings.PREFERRED_HC_LIGHT_THEME,
            ThemeSettings.DETECT_COLOR_SCHEME,
            ThemeSettings.DETECT_HC,
            ThemeSettings.SYSTEM_COLOR_THEME,
        }) |key| {
            if (configuration_mod.affectsConfiguration(change, key)) {
                self.restoreColorThemeAsync();
                break;
            }
        }
        if (configuration_mod.affectsConfiguration(change, ThemeSettings.FILE_ICON_THEME)) self.restoreFileIconTheme();
        const config = self.configuration orelse return;
        var changed = false;
        if (configuration_mod.affectsConfiguration(change, ThemeSettings.COLOR_CUSTOMIZATIONS)) {
            try self.applyColorCustomizations(self.allocator, config.getValue(ThemeSettings.COLOR_CUSTOMIZATIONS, .{}));
            changed = true;
        }
        if (configuration_mod.affectsConfiguration(change, ThemeSettings.TOKEN_COLOR_CUSTOMIZATIONS)) {
            try self.applyTokenColorCustomizations(self.allocator, config.getValue(ThemeSettings.TOKEN_COLOR_CUSTOMIZATIONS, .{}));
            changed = true;
        }
        if (configuration_mod.affectsConfiguration(change, ThemeSettings.SEMANTIC_TOKEN_COLOR_CUSTOMIZATIONS)) {
            try self.applySemanticTokenColorCustomizations(self.allocator, config.getValue(ThemeSettings.SEMANTIC_TOKEN_COLOR_CUSTOMIZATIONS, .{}));
            changed = true;
        }
        if (changed) {
            self.updateFileIconColors();
            try self.onDidColorThemeChange.fire({});
        }
    }

    fn restoreFileIconTheme(self: *ThemeService) void {
        var id: ?[]const u8 = "vs-seti";
        if (self.configuration) |config| {
            if (config.getValue(ThemeSettings.FILE_ICON_THEME, .{})) |value| {
                switch (value.*) {
                    .null => id = null,
                    .string => id = value.string,
                    else => {},
                }
            }
        }
        const previous = self.current_file_icon_theme;
        var data = FileIconThemeData.init(self.file_icon_registry, id, previous.variant, previous.foreground);
        if (id != null and data.settings_id == null) {
            data = FileIconThemeData.init(self.file_icon_registry, "vs-seti", previous.variant, previous.foreground);
        }
        self.current_file_icon_theme = data;
        self.updateFileIconColors();
        if (previous.catalog != data.catalog or previous.disabled != data.disabled or !std.mem.eql(u8, previous.settings_id orelse "", data.settings_id orelse "")) {
            self.onDidFileIconThemeChange.fire(self.current_file_icon_theme) catch {};
        }
    }

    /// Browser CSS selects scheme variants and inherits foreground from the
    /// active color theme. The terminal resolves those values to cell colors.
    pub fn updateFileIconColors(self: *ThemeService) void {
        self.current_file_icon_theme.variant = switch (self.active.theme_type) {
            .LIGHT => "light",
            .HIGH_CONTRAST_LIGHT => "highContrastLight",
            .HIGH_CONTRAST_DARK => "highContrast",
            .DARK => "",
        };
        self.current_file_icon_theme.foreground = ThemeColors.init(self.active).color("foreground", .{ 204, 204, 204 });
    }

    pub fn registerTheme(self: *ThemeService, id: []const u8, label: []const u8, theme_type: ColorScheme) !void {
        try self.themes.put(id, .{ .label = label, .theme_type = theme_type });
    }

    /// Registers a file-backed theme keyed by its `settings_id` (the value
    /// `workbench.colorTheme` stores). Later registrations win, so the TUI
    /// scan roots can override profile and built-in themes with the same id.
    pub fn registerThemeFile(
        self: *ThemeService,
        settings_id: []const u8,
        label: []const u8,
        theme_type: ColorScheme,
        root: []const u8,
        path: []const u8,
    ) !void {
        try self.themes.put(settings_id, .{
            .label = label,
            .theme_type = theme_type,
            .root = root,
            .path = path,
        });
    }

    pub fn getActiveTheme(self: *ThemeService) *ColorThemeData {
        return self.active;
    }

    pub fn getColorTheme(self: *ThemeService) IColorTheme {
        return self.active.interface();
    }

    pub fn interface(self: *ThemeService) theme_service.IThemeService {
        return .{ .context = self, .get_color_theme = getColorThemeContext };
    }

    fn getColorThemeContext(context: *anyopaque) IColorTheme {
        const self: *ThemeService = @ptrCast(@alignCast(context));
        return self.active.interface();
    }

    pub fn getActiveThemeId(self: *const ThemeService) []const u8 {
        return self.active_id;
    }

    /// Resolves a `workbench.colorTheme` value (legacy ids migrated) to a
    /// registered entry key. Falls back to matching the contributed label,
    /// which is what extensions without an explicit `id` store.
    pub fn findThemeSettingsId(self: *const ThemeService, value: []const u8) ?[]const u8 {
        const migrated = migrateThemeSettingsId(value);
        if (self.themes.contains(migrated)) return migrated;
        var iterator = self.themes.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.label, migrated)) return entry.key_ptr.*;
        }
        return null;
    }

    /// Loads and applies a registered theme. A missing/broken file leaves the
    /// previous theme active.
    pub fn activate(self: *ThemeService, id: []const u8) !void {
        const entry = self.themes.get(id) orelse return error.UnknownTheme;
        const theme = try ColorThemeData.createUnloadedTheme(self.allocator, self.colors, id, &.{});
        errdefer theme.deinit();
        theme.theme_type = entry.theme_type;
        theme.label = try theme.arena.allocator().dupe(u8, entry.label);
        if (entry.path) |location| {
            theme.location = location;
            const root = entry.root orelse return error.MissingThemeRoot;
            var reader = FileResourceReader{
                .root = root,
                .io = time_compat.io,
                .arena = std.heap.ArenaAllocator.init(self.allocator),
            };
            defer reader.arena.deinit();
            try theme.ensureLoaded(reader.interface());
        }

        self.active.deinit();
        self.active = theme;
        try self.applyThemeId(id);
    }

    /// Copied registration data for a worker-thread theme load. The request
    /// owns its strings and can outlive the caller's stack frame.
    pub const PrepareRequest = struct {
        allocator: Allocator,
        id: []u8,
        label: []u8,
        theme_type: ColorScheme,
        root: ?[]u8,
        path: ?[]u8,

        pub fn init(self: *ThemeService, id: []const u8, allocator: Allocator) !PrepareRequest {
            const entry = self.themes.get(id) orelse return error.UnknownTheme;
            const id_copy = try allocator.dupe(u8, id);
            errdefer allocator.free(id_copy);
            const label_copy = try allocator.dupe(u8, entry.label);
            errdefer allocator.free(label_copy);
            const root_copy = if (entry.root) |root| try allocator.dupe(u8, root) else null;
            errdefer if (root_copy) |root| allocator.free(root);
            const path_copy = if (entry.path) |path| try allocator.dupe(u8, path) else null;
            return .{
                .allocator = allocator,
                .id = id_copy,
                .label = label_copy,
                .theme_type = entry.theme_type,
                .root = root_copy,
                .path = path_copy,
            };
        }

        pub fn deinit(self: *PrepareRequest) void {
            if (self.path) |path| self.allocator.free(path);
            if (self.root) |root| self.allocator.free(root);
            self.allocator.free(self.label);
            self.allocator.free(self.id);
            self.* = undefined;
        }
    };

    /// Loads a theme (including its `include` chain) on the supplied Io. This
    /// mirrors upstream's asynchronous theme-data creation: parsing and file
    /// reads happen off the TUI thread, while `applyPreparedTheme` swaps the
    /// active theme and fires `onDidColorThemeChange` on the event loop.
    pub fn prepareTheme(
        allocator: Allocator,
        colors: *color_utils.ColorRegistry,
        request: *const PrepareRequest,
        io: Io,
    ) !*ColorThemeData {
        const theme = try ColorThemeData.createUnloadedTheme(allocator, colors, request.id, &.{});
        errdefer theme.deinit();
        theme.theme_type = request.theme_type;
        theme.label = try theme.arena.allocator().dupe(u8, request.label);
        if (request.path) |location| {
            theme.location = try theme.arena.allocator().dupe(u8, location);
            const root = request.root orelse return error.MissingThemeRoot;
            var reader = FileResourceReader{
                .root = root,
                .io = io,
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
            defer reader.arena.deinit();
            try theme.ensureLoaded(reader.interface());
        }
        return theme;
    }

    /// Installs a theme produced by `prepareTheme` on the TUI thread. Only the
    /// id allocation can fail; once the active theme is swapped, storage and
    /// the change event are non-fatal (like upstream's fire-and-forget event).
    pub fn applyPreparedTheme(self: *ThemeService, id: []const u8, theme: *ColorThemeData) !void {
        try self.installPreparedTheme(id, theme);
        self.updateFileIconColors();
        self.onDidColorThemeChange.fire({}) catch {};
    }

    fn installPreparedTheme(self: *ThemeService, id: []const u8, theme: *ColorThemeData) !void {
        const id_copy = try self.allocator.dupe(u8, id);
        self.allocator.free(self.active_id);
        self.active_id = id_copy;
        self.active.deinit();
        self.active = theme;
        if (self.storage) |service| {
            service.store(STORAGE_KEY, .{ .string = id }, .profile, .user) catch {};
        }
    }

    pub fn registerThemeSources(self: *ThemeService, themes: []const @import("../../extensions/common/extensionsRegistry.zig").Theme) !void {
        for (themes) |theme| {
            try self.registerThemeFile(theme.settings_id, theme.label, colorSchemeForUiTheme(theme.ui_theme), theme.root, theme.path);
        }
    }

    fn configuredThemeValues(self: *ThemeService) ?[3][]const u8 {
        const config = self.configuration orelse return null;
        const runtime = self.theme_runtime orelse return null;
        const settings = @import("../common/themeConfiguration.zig").ThemeConfiguration.init(config.interface(), runtime.scheme);
        return .{ settings.getColorTheme() orelse ThemeSettingDefaults.COLOR_THEME_DARK, ThemeSettingDefaults.COLOR_THEME_DARK, "vs-dark" };
    }

    /// Startup applies the same configured theme and fallback sequence before
    /// the first rendered frame. Subsequent changes use the window queue.
    pub fn restoreColorTheme(self: *ThemeService) void {
        self.cancelColorThemeLoad();
        const values = self.configuredThemeValues() orelse return;
        for (values) |value| {
            const id = self.findThemeSettingsId(value) orelse continue;
            var request = PrepareRequest.init(self, id, self.allocator) catch continue;
            defer request.deinit();
            const theme = prepareTheme(self.allocator, self.colors, &request, time_compat.io) catch continue;
            self.installPreparedTheme(id, theme) catch {
                theme.deinit();
                continue;
            };
            break;
        }
        self.finishConfiguredTheme();
    }

    pub fn restoreColorThemeAsync(self: *ThemeService) void {
        self.cancelColorThemeLoad();
        const values = self.configuredThemeValues() orelse return;
        var count: usize = 0;
        for (values) |value| {
            const id = self.findThemeSettingsId(value) orelse continue;
            var duplicate = false;
            for (self.theme_candidates[0..count]) |existing| {
                if (existing) |candidate| {
                    if (std.mem.eql(u8, candidate, id)) duplicate = true;
                }
            }
            if (duplicate) continue;
            self.theme_candidates[count] = self.allocator.dupe(u8, id) catch continue;
            count += 1;
        }
        self.startThemeCandidate();
    }

    fn startThemeCandidate(self: *ThemeService) void {
        const runtime = self.theme_runtime orelse return;
        while (self.theme_candidate_index < self.theme_candidates.len) {
            const maybe_id = self.theme_candidates[self.theme_candidate_index];
            self.theme_candidate_index += 1;
            const id = maybe_id orelse continue;
            var request = PrepareRequest.init(self, id, self.allocator) catch continue;
            const job = self.allocator.create(ThemeLoadJob) catch {
                request.deinit();
                continue;
            };
            job.* = .{
                .allocator = self.allocator,
                .io = runtime.io,
                .service = self,
                .completion = .{ .queue = runtime.window, .context = self, .run = applyLoadedTheme, .progress = true },
                .future = undefined,
                .request = request,
            };
            job.future = runtime.io.async(runThemeLoadJob, .{job});
            self.theme_job = job;
            return;
        }
        self.freeThemeCandidates();
        self.finishConfiguredTheme();
    }

    fn applyLoadedTheme(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ThemeService = @ptrCast(@alignCast(context));
        const job = self.theme_job orelse return false;
        const result = job.future.await(job.io);
        self.theme_job = null;
        switch (result) {
            .theme => |theme| {
                self.installPreparedTheme(job.request.id, theme) catch theme.deinit();
                job.request.deinit();
                self.allocator.destroy(job);
                self.freeThemeCandidates();
                self.finishConfiguredTheme();
            },
            .err => {
                job.request.deinit();
                self.allocator.destroy(job);
                self.startThemeCandidate();
            },
        }
        return true;
    }

    pub fn cancelColorThemeLoad(self: *ThemeService) void {
        if (self.theme_job) |job| {
            self.theme_job = null;
            const result = job.future.cancel(job.io);
            job.completion.schedule(null);
            switch (result) {
                .theme => |theme| theme.deinit(),
                .err => {},
            }
            job.request.deinit();
            self.allocator.destroy(job);
        }
        self.freeThemeCandidates();
        self.theme_candidate_index = 0;
    }

    fn freeThemeCandidates(self: *ThemeService) void {
        for (&self.theme_candidates) |*id| {
            if (id.*) |value| self.allocator.free(value);
            id.* = null;
        }
    }

    fn finishConfiguredTheme(self: *ThemeService) void {
        const config = self.configuration orelse return;
        self.applyColorCustomizations(self.allocator, config.getValue(ThemeSettings.COLOR_CUSTOMIZATIONS, .{})) catch {};
        self.applyTokenColorCustomizations(self.allocator, config.getValue(ThemeSettings.TOKEN_COLOR_CUSTOMIZATIONS, .{})) catch {};
        self.applySemanticTokenColorCustomizations(self.allocator, config.getValue(ThemeSettings.SEMANTIC_TOKEN_COLOR_CUSTOMIZATIONS, .{})) catch {};
        self.updateFileIconColors();
        self.onDidColorThemeChange.fire({}) catch {};
    }

    /// Applies the configured theme value. Returns false when the value is not
    /// a registered theme (the caller falls back to the default theme).
    pub fn activateSettingsId(self: *ThemeService, value: []const u8) !bool {
        const id = self.findThemeSettingsId(value) orelse return false;
        try self.activate(id);
        return true;
    }

    /// Applies `workbench.colorCustomizations`: flat entries plus the
    /// `["<theme settings id>"]` scoped block, later entries winning.
    pub fn applyColorCustomizations(self: *ThemeService, allocator: Allocator, value: ?*const Value) !void {
        var pairs = std.array_list.Managed([2][]const u8).init(allocator);
        defer pairs.deinit();
        if (value) |colors| {
            if (colors.* == .object) {
                try appendColorEntries(&pairs, colors.object);
                const scoped_key = try std.fmt.allocPrint(allocator, "[{s}]", .{self.active_id});
                defer allocator.free(scoped_key);
                if (colors.object.get(scoped_key)) |scoped| {
                    if (scoped == .object) try appendColorEntries(&pairs, scoped.object);
                }
            }
        }
        try self.active.setCustomColors(pairs.items);
    }

    fn appendColorEntries(
        pairs: *std.array_list.Managed([2][]const u8),
        object: std.json.ObjectMap,
    ) !void {
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.len > 0 and key[0] == '[') continue;
            const text = switch (entry.value_ptr.*) {
                .string => |inner| inner,
                else => continue,
            };
            try pairs.append(.{ key, text });
        }
    }

    /// Applies `editor.tokenColorCustomizations` (flat + theme-scoped
    /// `textMateRules`) and the flat semantic token rules.
    pub fn applyTokenColorCustomizations(self: *ThemeService, allocator: Allocator, value: ?*const Value) !void {
        if (try mergeTextMateRules(allocator, value, self.active_id)) |text| {
            defer allocator.free(text);
            try self.active.setCustomTokenColorsJson(text);
        }
    }

    pub fn applySemanticTokenColorCustomizations(self: *ThemeService, allocator: Allocator, value: ?*const Value) !void {
        const semantic = value orelse return;
        if (semantic.* != .object) return;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try std.json.Stringify.value(semantic.*, .{}, &out.writer);
        try self.active.setCustomSemanticTokenColorsJson(out.written());
    }

    /// Applies a registered theme, optionally loading its file first. Kept for
    /// the standalone syntax-theme loader and tests.
    pub fn setTheme(self: *ThemeService, id: []const u8, reader: ?ResourceReader, path: ?[]const u8) !void {
        const entry = self.themes.get(id) orelse return error.UnknownTheme;
        const theme = try ColorThemeData.createUnloadedTheme(self.allocator, self.colors, id, &.{});
        errdefer theme.deinit();
        theme.theme_type = entry.theme_type;
        if (path) |location| theme.location = location;
        if (reader) |resource_reader| try theme.ensureLoaded(resource_reader);

        self.active.deinit();
        self.active = theme;
        try self.applyThemeId(id);
    }

    fn applyThemeId(self: *ThemeService, id: []const u8) !void {
        const entry = self.themes.get(id) orelse return error.UnknownTheme;
        self.allocator.free(self.active_id);
        self.active_id = try self.allocator.dupe(u8, id);
        self.active.theme_type = entry.theme_type;
        if (self.storage) |service| {
            try service.store(STORAGE_KEY, .{ .string = id }, .profile, .user);
        }
        self.updateFileIconColors();
        try self.onDidColorThemeChange.fire({});
    }
};

fn mergeTextMateRules(allocator: Allocator, value: ?*const Value, settings_id: []const u8) !?[]u8 {
    const customizations = value orelse return null;
    if (customizations.* != .object) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var merged = std.json.Array.init(scratch);
    var found = false;
    try appendRuleArray(&merged, customizations.object, &found);
    const scoped_key = try std.fmt.allocPrint(scratch, "[{s}]", .{settings_id});
    if (customizations.object.get(scoped_key)) |scoped| {
        if (scoped == .object) try appendRuleArray(&merged, scoped.object, &found);
    }
    if (!found) return null;

    var root: std.json.ObjectMap = .empty;
    try root.put(scratch, "textMateRules", .{ .array = merged });
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(Value{ .object = root }, .{}, &out.writer);
    return try out.toOwnedSlice();
}

fn appendRuleArray(
    merged: *std.json.Array,
    object: std.json.ObjectMap,
    found: *bool,
) !void {
    const rules = object.get("textMateRules") orelse return;
    if (rules != .array) return;
    for (rules.array.items) |rule| try merged.append(rule);
    found.* = true;
}

test "theme service applies and restores the active theme" {
    const allocator = std.testing.allocator;
    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();

    const service = try ThemeService.init(allocator, &registry, &storage);
    defer service.deinit();
    try std.testing.expectEqualStrings("vs-dark", service.getActiveThemeId());

    try service.registerTheme("vs-light", "Light (Visual Studio)", .LIGHT);
    try service.setTheme("vs-light", null, null);
    try std.testing.expectEqualStrings("vs-light", service.getActiveThemeId());
    try std.testing.expectEqual(ColorScheme.LIGHT, service.getActiveTheme().theme_type);
    try std.testing.expectEqual(ColorScheme.LIGHT, service.interface().colorTheme().theme_type);
    try std.testing.expectEqualStrings("vs-light", storage.get(STORAGE_KEY, .profile, null).?);

    const restored = try ThemeService.init(allocator, &registry, &storage);
    defer restored.deinit();
    try restored.registerTheme("vs-light", "Light (Visual Studio)", .LIGHT);
    try restored.restore();
    try std.testing.expectEqualStrings("vs-light", restored.getActiveThemeId());
}

pub const ThemeSettingDefaults = struct {
    pub const COLOR_THEME_DARK = "Dark 2026";
    pub const COLOR_THEME_LIGHT = "Light 2026";
    pub const COLOR_THEME_HC_DARK = "Default High Contrast";
    pub const COLOR_THEME_HC_LIGHT = "Default High Contrast Light";
};

pub const ThemeSettings = struct {
    pub const COLOR_THEME = "workbench.colorTheme";
    pub const FILE_ICON_THEME = "workbench.iconTheme";
    pub const PRODUCT_ICON_THEME = "workbench.productIconTheme";
    pub const COLOR_CUSTOMIZATIONS = "workbench.colorCustomizations";
    pub const TOKEN_COLOR_CUSTOMIZATIONS = "editor.tokenColorCustomizations";
    pub const SEMANTIC_TOKEN_COLOR_CUSTOMIZATIONS = "editor.semanticTokenColorCustomizations";

    pub const PREFERRED_DARK_THEME = "workbench.preferredDarkColorTheme";
    pub const PREFERRED_LIGHT_THEME = "workbench.preferredLightColorTheme";
    pub const PREFERRED_HC_DARK_THEME = "workbench.preferredHighContrastColorTheme"; // id kept for compatibility
    pub const PREFERRED_HC_LIGHT_THEME = "workbench.preferredHighContrastLightColorTheme";
    pub const DETECT_COLOR_SCHEME = "window.autoDetectColorScheme";
    pub const DETECT_HC = "window.autoDetectHighContrast";

    pub const SYSTEM_COLOR_THEME = "window.systemColorTheme";
};

/// Migrates legacy theme setting ids to their current equivalents.
pub fn migrateThemeSettingsId(settings_id: []const u8) []const u8 {
    const mappings = [_][2][]const u8{
        .{ "Default Dark Modern", "Dark Modern" },
        .{ "Default Light Modern", "Light Modern" },
        .{ "Default Dark+", "Dark+" },
        .{ "Default Light+", "Light+" },
        .{ "Experimental Dark", ThemeSettingDefaults.COLOR_THEME_DARK },
        .{ "VS Code Dark", ThemeSettingDefaults.COLOR_THEME_DARK },
        .{ "Experimental Light", ThemeSettingDefaults.COLOR_THEME_LIGHT },
        .{ "VS Code Light", ThemeSettingDefaults.COLOR_THEME_LIGHT },
    };
    for (mappings) |mapping| {
        if (std.mem.eql(u8, settings_id, mapping[0])) return mapping[1];
    }
    return settings_id;
}

test "migrateThemeSettingsId migrates Default-prefixed ids" {
    try std.testing.expectEqualStrings("Dark Modern", migrateThemeSettingsId("Default Dark Modern"));
    try std.testing.expectEqualStrings("Light Modern", migrateThemeSettingsId("Default Light Modern"));
    try std.testing.expectEqualStrings("Dark+", migrateThemeSettingsId("Default Dark+"));
    try std.testing.expectEqualStrings("Light+", migrateThemeSettingsId("Default Light+"));
}

test "migrateThemeSettingsId migrates Experimental ids" {
    try std.testing.expectEqualStrings(ThemeSettingDefaults.COLOR_THEME_DARK, migrateThemeSettingsId("Experimental Dark"));
    try std.testing.expectEqualStrings(ThemeSettingDefaults.COLOR_THEME_LIGHT, migrateThemeSettingsId("Experimental Light"));
    try std.testing.expectEqualStrings(ThemeSettingDefaults.COLOR_THEME_DARK, migrateThemeSettingsId("VS Code Dark"));
    try std.testing.expectEqualStrings(ThemeSettingDefaults.COLOR_THEME_LIGHT, migrateThemeSettingsId("VS Code Light"));
}

test "migrateThemeSettingsId returns unknown ids unchanged" {
    try std.testing.expectEqualStrings("Dark Modern", migrateThemeSettingsId("Dark Modern"));
    try std.testing.expectEqualStrings("Dark 2026", migrateThemeSettingsId("Dark 2026"));
    try std.testing.expectEqualStrings("Some Custom Theme", migrateThemeSettingsId("Some Custom Theme"));
    try std.testing.expectEqualStrings("", migrateThemeSettingsId(""));
}

pub const ColorSchemeHost = struct {
    dark: bool = false,
    high_contrast: bool = false,
};

/// Terminal-adapted subset of `ThemeConfiguration` covering color-scheme
/// detection. The upstream configuration service is replaced by explicit flags.
pub const ThemeSchemeConfiguration = struct {
    detect_color_scheme: bool,
    detect_high_contrast: bool,
    host: *const ColorSchemeHost,

    pub fn isPreferredColorSchemeChange(self: *const ThemeSchemeConfiguration, previous: ColorSchemeHost) bool {
        const dark_changed = previous.dark != self.host.dark;
        if (self.detect_color_scheme and dark_changed) return true;
        if (self.detect_high_contrast) {
            return previous.high_contrast != self.host.high_contrast or (self.host.high_contrast and dark_changed);
        }
        return false;
    }
};

test "restores only for preferred color scheme changes" {
    var host = ColorSchemeHost{ .dark = true, .high_contrast = false };
    var configuration = ThemeSchemeConfiguration{ .detect_color_scheme = false, .detect_high_contrast = true, .host = &host };
    var results: [5]bool = undefined;
    results[0] = configuration.isPreferredColorSchemeChange(.{ .dark = false, .high_contrast = false });
    host.high_contrast = true;
    results[1] = configuration.isPreferredColorSchemeChange(.{ .dark = true, .high_contrast = false });
    host.dark = false;
    results[2] = configuration.isPreferredColorSchemeChange(.{ .dark = true, .high_contrast = true });
    host.high_contrast = false;
    results[3] = configuration.isPreferredColorSchemeChange(.{ .dark = false, .high_contrast = true });
    configuration.detect_color_scheme = true;
    host.dark = true;
    results[4] = configuration.isPreferredColorSchemeChange(.{ .dark = false, .high_contrast = false });
    try std.testing.expectEqual([5]bool{ false, true, true, true, true }, results);
}

test "theme service loads a file-backed theme and applies customizations" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "custom.json", .{});
    try file.writeStreamingAll(io,
        \\{
        \\  "colors": { "editor.background": "#112233", "editor.foreground": "#ddeeff" },
        \\  "tokenColors": [{ "scope": "keyword", "settings": { "foreground": "#ff0000" } }]
        \\}
    );
    file.close(io);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = try allocator.dupe(u8, buffer[0..root_len]);
    defer allocator.free(root);

    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    const service = try ThemeService.init(allocator, &registry, null);
    defer service.deinit();

    try service.registerThemeFile("Custom Theme", "Custom Theme", .DARK, root, "custom.json");
    try std.testing.expectEqualStrings("Custom Theme", service.findThemeSettingsId("Custom Theme").?);
    try std.testing.expect(try service.activateSettingsId("Custom Theme"));
    const background = service.getActiveTheme().getColor("editor.background", false).?;
    try std.testing.expectEqual(@as(u8, 0x11), background.r);
    try std.testing.expectEqual(@as(u8, 0x22), background.g);
    try std.testing.expectEqual(@as(u8, 0x33), background.b);

    var colors = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{ "editor.background": "#445566", "[Custom Theme]": { "editor.background": "#010203" } }
    , .{});
    defer colors.deinit();
    try service.applyColorCustomizations(allocator, &colors.value);
    const customized = service.getActiveTheme().getColor("editor.background", false).?;
    try std.testing.expectEqual(@as(u8, 0x01), customized.r);
    try std.testing.expectEqual(@as(u8, 0x02), customized.g);
    try std.testing.expectEqual(@as(u8, 0x03), customized.b);

    var tokens = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{ "textMateRules": [{ "scope": "keyword", "settings": { "foreground": "#00ff00" } }] }
    , .{});
    defer tokens.deinit();
    try service.applyTokenColorCustomizations(allocator, &tokens.value);
}
