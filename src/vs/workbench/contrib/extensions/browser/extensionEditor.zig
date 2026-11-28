// Port of `src/vs/workbench/contrib/extensions/browser/extensionEditor.ts`.
// Terminal adaptation: header, action bar and navbar use cell geometry; the
// shared Markdown document layout replaces the README/changelog webviews.
// Local manifest/README/changelog data is displayed without executing HTML.
const std = @import("std");
const ui = @import("ui");
const model = @import("../common/extensions.zig");
const service_mod = @import("extensionsWorkbenchService.zig");
const input_mod = @import("../common/extensionsInput.zig");
const widgets = @import("extensionsWidgets.zig");
const features = @import("extensionFeaturesTab.zig");
const list = @import("extensionsList.zig");
const markdown = @import("../../../../editor/common/markdown/markdownTerminalRenderer.zig");
const document = @import("../../markdown/browser/markdownPreviewDocument.zig");
const theme = @import("../../../browser/themeColors.zig");
const SignalSubscription = @import("../../../../base/common/event.zig").SignalSubscription;

pub const Tab = enum {
    readme,
    features,
    changelog,
    dependencies,
    extensionPack,

    pub fn label(self: Tab) []const u8 {
        return switch (self) {
            .readme => "Details",
            .features => "Features",
            .changelog => "Changelog",
            .dependencies => "Dependencies",
            .extensionPack => "Extension Pack",
        };
    }
};

const dispatch = @import("../../../../base/common/windowDispatch.zig");
const gallery = @import("../../../../platform/extensionManagement/common/extensionGalleryService.zig");
const RemoteAssets = struct {
    allocator: std.mem.Allocator,
    manifest: ?[]u8 = null,
    readme: ?[]u8 = null,
    changelog: ?[]u8 = null,

    fn deinit(self: *RemoteAssets) void {
        if (self.manifest) |value| self.allocator.free(value);
        if (self.readme) |value| self.allocator.free(value);
        if (self.changelog) |value| self.allocator.free(value);
    }
};
const AssetJob = struct {
    pane: *ExtensionEditor,
    completion: dispatch.Task,
    future: std.Io.Future(RemoteAssets),
};
fn loadRemote(allocator: std.mem.Allocator, io: std.Io, extension: model.IExtension) RemoteAssets {
    var result: RemoteAssets = .{ .allocator = allocator };
    if (extension.manifest_url) |url| result.manifest = gallery.getAsset(allocator, io, url) catch null;
    if (extension.readme_url) |url| result.readme = gallery.getAsset(allocator, io, url) catch null;
    if (extension.changelog_url) |url| result.changelog = gallery.getAsset(allocator, io, url) catch null;
    return result;
}
fn runAssets(job: *AssetJob) RemoteAssets {
    defer job.completion.post();
    const pane = job.pane;
    const io = pane.window.?.io;
    return dispatch.workerCall(io, loadRemote, .{ pane.allocator, dispatch.backingIo(io), pane.input.snapshot });
}

pub const ExtensionEditor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    service: *service_mod.ExtensionsWorkbenchService,
    input: *input_mod.ExtensionsInput,
    listener: ?SignalSubscription = null,
    arena: std.heap.ArenaAllocator,
    extension: ?model.IExtension = null,
    manifest: std.json.Value = .null,
    feature_tab: features.ExtensionFeaturesTab,
    readme: []const u8 = "No README available.",
    changelog: ?[]const u8 = null,
    tabs: [5]Tab = undefined,
    tab_count: usize = 0,
    active_tab: Tab = .readme,
    content: ?markdown.Content = null,
    layout: ?document.Document = null,
    additional_content: ?markdown.Content = null,
    additional_layout: ?document.Document = null,
    additional_scroll: usize = 0,
    scroll: usize = 0,
    viewport: usize = 0,
    width: usize = 0,
    palette: ?*const theme.ThemeColors = null,
    status: []const u8 = "",
    focus_area: enum { body, actions, navbar, feature_list, additional } = .body,
    focused_action: usize = 0,
    action_origin_x: usize = 0,
    action_origin_y: usize = 0,
    window: ?*dispatch.Queue = null,
    asset_job: ?*AssetJob = null,
    remote_assets: ?RemoteAssets = null,
    opener: ?*@import("../../../../platform/opener/common/opener.zig").ExternalOpener = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, service: *service_mod.ExtensionsWorkbenchService, input: *input_mod.ExtensionsInput, window: ?*dispatch.Queue) !*ExtensionEditor {
        const self = try allocator.create(ExtensionEditor);
        self.* = .{ .allocator = allocator, .io = io, .service = service, .input = input, .arena = std.heap.ArenaAllocator.init(allocator), .window = window, .feature_tab = features.ExtensionFeaturesTab.init(allocator, &service.feature_registry) };
        errdefer self.deinit();
        if (input.snapshot.state == .Uninstalled and window != null) try self.requestRemote();
        try self.update();
        self.listener = try service.on_change.listenSignal(self, onChange);
        return self;
    }

    pub fn deinit(self: *ExtensionEditor) void {
        if (self.listener) |listener| listener.dispose();
        self.cancelRemote();
        if (self.remote_assets) |*assets| assets.deinit();
        self.clearContent();
        self.clearAdditionalDetails();
        self.feature_tab.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn requestRemote(self: *ExtensionEditor) !void {
        const window = self.window orelse return;
        const job = try self.allocator.create(AssetJob);
        job.* = .{ .pane = self, .completion = .{ .queue = window, .context = self, .run = applyAssets, .progress = true }, .future = undefined };
        self.asset_job = job;
        job.future = window.io.async(runAssets, .{job});
    }

    fn applyAssets(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ExtensionEditor = @ptrCast(@alignCast(context));
        const job = self.asset_job orelse return false;
        self.asset_job = null;
        if (self.remote_assets) |*assets| assets.deinit();
        self.remote_assets = job.future.await(self.window.?.io);
        self.allocator.destroy(job);
        self.update() catch {
            self.status = "Unable to load extension details.";
        };
        return true;
    }

    fn cancelRemote(self: *ExtensionEditor) void {
        const job = self.asset_job orelse return;
        self.asset_job = null;
        var assets = job.future.cancel(self.window.?.io);
        job.completion.schedule(null);
        assets.deinit();
        self.allocator.destroy(job);
    }

    fn onChange(self: *ExtensionEditor) !void {
        // A failed detail refresh must not prevent other inventory subscribers
        // from observing the new inventory.
        self.update() catch {
            self.status = "Unable to load extension details.";
        };
    }

    fn clearContent(self: *ExtensionEditor) void {
        if (self.layout) |*layout| layout.deinit();
        self.layout = null;
        if (self.content) |*content| content.deinit();
        self.content = null;
    }

    fn clearAdditionalDetails(self: *ExtensionEditor) void {
        if (self.additional_layout) |*layout| layout.deinit();
        self.additional_layout = null;
        if (self.additional_content) |*content| content.deinit();
        self.additional_content = null;
    }

    fn additionalWidth(self: *const ExtensionEditor) usize {
        // Upstream hides the sidebar below 500 CSS pixels and reserves a
        // quarter of the body otherwise. Use whole-cell geometry in the TUI.
        return if (self.width >= 80 and self.additional_content != null) @max(24, self.width / 4) else 0;
    }

    fn bodyWidth(self: *const ExtensionEditor) usize {
        const additional = self.additionalWidth();
        return self.width -| (if (additional > 0) additional + 1 else 0);
    }

    fn featureListWidth(self: *const ExtensionEditor) usize {
        return if (self.active_tab == .features and self.feature_tab.available.len > 0 and self.bodyWidth() >= 35) @min(24, @max(16, self.bodyWidth() / 3)) else 0;
    }

    fn documentWidth(self: *const ExtensionEditor) usize {
        const feature_width = self.featureListWidth();
        return self.bodyWidth() -| (if (feature_width > 0) feature_width + 1 else 0);
    }

    fn selectFeature(self: *ExtensionEditor, index: usize) !void {
        if (self.feature_tab.select(index)) {
            self.scroll = 0;
            try self.refreshContent();
        }
    }

    fn refreshAdditionalDetails(self: *ExtensionEditor) !void {
        self.clearAdditionalDetails();
        const extension = self.extension orelse return;
        const remote = self.service.galleryInfo(extension.identifier);
        const source = try renderAdditionalDetails(self.allocator, extension, remote, self.manifest, self.service.gallery_url);
        defer self.allocator.free(source);
        self.additional_content = try markdown.parseDocument(self.allocator, self.io, source, .{});
        const width = self.additionalWidth();
        if (width > 0) self.additional_layout = try document.build(self.allocator, &self.additional_content.?, width -| 2, .{});
    }

    fn readFile(self: *ExtensionEditor, location: []const u8, names: []const []const u8) ?[]const u8 {
        const allocator = self.arena.allocator();
        for (names) |name| {
            const path = std.fs.path.join(allocator, &.{ location, name }) catch continue;
            return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(16 * 1024 * 1024)) catch continue;
        }
        return null;
    }

    fn addTab(self: *ExtensionEditor, tab: Tab) void {
        self.tabs[self.tab_count] = tab;
        self.tab_count += 1;
    }

    fn hasItems(value: std.json.Value) bool {
        return value == .array and value.array.items.len > 0;
    }

    fn update(self: *ExtensionEditor) !void {
        self.clearContent();
        self.clearAdditionalDetails();
        self.arena.deinit();
        self.arena = .init(self.allocator);
        self.extension = null;
        self.manifest = .null;
        self.readme = "No README available.";
        self.changelog = null;
        self.tab_count = 0;
        self.addTab(.readme);
        const local = self.service.findLocal(self.input.identifier);
        const extension = local orelse if (self.input.snapshot.state == .Uninstalled) &self.input.snapshot else {
            self.readme = "Extension is no longer installed.";
            self.active_tab = .readme;
            return self.refreshContent();
        };
        const allocator = self.arena.allocator();
        self.extension = try extension.clone(allocator);
        if (local != null) if (self.service.galleryInfo(extension.identifier)) |remote| {
            self.extension.?.install_count = remote.install_count;
            self.extension.?.rating = remote.rating;
            self.extension.?.rating_count = remote.rating_count;
            self.extension.?.publisher_verified = remote.publisher_verified;
            self.extension.?.publisher = try allocator.dupe(u8, remote.publisher);
            self.extension.?.publisher_domain = if (remote.publisher_domain) |domain| try allocator.dupe(u8, domain) else null;
        };
        if (local != null) {
            if (self.readFile(extension.location, &.{"package.json"})) |raw| {
                self.manifest = std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{}) catch .null;
            }
            self.readme = self.readFile(extension.location, &.{ "README.md", "readme.md", "Readme.md", "README" }) orelse "No README available.";
            self.changelog = self.readFile(extension.location, &.{ "CHANGELOG.md", "changelog.md", "Changelog.md", "CHANGELOG" });
        } else if (self.remote_assets) |assets| {
            if (assets.manifest) |raw| self.manifest = std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{}) catch .null;
            self.readme = assets.readme orelse "No README available.";
            self.changelog = assets.changelog;
        } else if (self.asset_job != null) {
            self.readme = "Loading extension details…";
        }
        if (self.manifest != .null) self.addTab(.features);
        if (self.changelog != null) self.addTab(.changelog);
        if (hasItems(features.property(self.manifest, "extensionDependencies"))) self.addTab(.dependencies);
        if (hasItems(features.property(self.manifest, "extensionPack"))) self.addTab(.extensionPack);
        for (self.tabs[0..self.tab_count]) |tab| {
            if (tab == self.active_tab) break;
        } else self.active_tab = .readme;
        try self.feature_tab.setManifestWithRuntime(self.manifest, self.service.getRuntimeStatus(self.input.identifier) != null);
        try self.refreshAdditionalDetails();
        try self.refreshContent();
    }

    fn dependencyContent(self: *ExtensionEditor, key: []const u8) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const value = features.property(self.manifest, key);
        if (value == .array) for (value.array.items) |entry| {
            if (entry != .string) continue;
            const item = self.service.findLocal(entry.string);
            try output.writer.print("- [{s}](<minecode-extension-id:{s}>){s}\n", .{ if (item) |extension| extension.display_name else entry.string, entry.string, if (item != null) " (Installed)" else "" });
        };
        return output.toOwnedSlice();
    }

    fn refreshContent(self: *ExtensionEditor) !void {
        self.clearContent();
        const source = switch (self.active_tab) {
            .readme => try self.allocator.dupe(u8, self.readme),
            .changelog => try self.allocator.dupe(u8, self.changelog orelse "No changelog available."),
            .features => try self.feature_tab.renderSelectedWithRuntime(self.manifest, self.service.getRuntimeStatus(self.input.identifier)),
            .dependencies => try self.dependencyContent("extensionDependencies"),
            .extensionPack => try self.dependencyContent("extensionPack"),
        };
        defer self.allocator.free(source);
        self.content = try markdown.parseDocument(self.allocator, self.io, source, .{});
        if (self.width > 0) self.layout = try document.build(self.allocator, &self.content.?, self.documentWidth() -| 2, .{});
        self.clampScroll();
    }

    pub fn selectTab(self: *ExtensionEditor, tab: Tab) !void {
        for (self.tabs[0..self.tab_count]) |candidate| {
            if (candidate != tab) continue;
            if (self.active_tab == tab) return;
            self.active_tab = tab;
            if (tab != .features and self.focus_area == .feature_list) self.focus_area = .body;
            self.scroll = 0;
            try self.refreshContent();
            return;
        }
    }

    fn clampScroll(self: *ExtensionEditor) void {
        self.scroll = @min(self.scroll, if (self.layout) |*layout| layout.maxScroll(self.viewport, false) else 0);
        self.additional_scroll = @min(self.additional_scroll, if (self.additional_layout) |*layout| layout.maxScroll(self.viewport, false) else 0);
    }

    pub fn setThemeColors(self: *ExtensionEditor, palette: ?*const theme.ThemeColors) void {
        self.palette = palette;
    }

    fn cycleTab(self: *ExtensionEditor, reverse: bool) !void {
        for (self.tabs[0..self.tab_count], 0..) |tab, i| if (tab == self.active_tab) {
            const next = if (reverse) (i + self.tab_count - 1) % self.tab_count else (i + 1) % self.tab_count;
            return self.selectTab(self.tabs[next]);
        };
    }

    pub fn handleKey(self: *ExtensionEditor, event: *const ui.KeyEvent) !bool {
        switch (event.key) {
            .tab, .backtab => {
                const reverse = event.key == .backtab or event.mods.shift;
                const has_features = self.active_tab == .features and self.feature_tab.available.len > 0;
                self.focus_area = switch (self.focus_area) {
                    .body => if (reverse) (if (self.additionalWidth() > 0) .additional else if (has_features) .feature_list else .navbar) else .actions,
                    .actions => if (reverse) .body else .navbar,
                    .navbar => if (reverse) .actions else if (has_features) .feature_list else if (self.additionalWidth() > 0) .additional else .body,
                    .feature_list => if (reverse) .navbar else if (self.additionalWidth() > 0) .additional else .body,
                    .additional => if (reverse) (if (has_features) .feature_list else .navbar) else .body,
                };
                var available: [6]Action = undefined;
                if (self.focus_area == .actions and self.actions(&available).len == 0) self.focus_area = if (reverse) .body else .navbar;
            },
            .left, .right => {
                if (self.focus_area == .actions) {
                    var available: [6]Action = undefined;
                    const count = self.actions(&available).len;
                    if (count == 0) return false;
                    self.focused_action = @min(self.focused_action, count - 1);
                    self.focused_action = if (event.key == .left) (self.focused_action + count - 1) % count else (self.focused_action + 1) % count;
                } else if (self.focus_area == .feature_list and self.feature_tab.available.len > 0) {
                    const count = self.feature_tab.available.len;
                    try self.selectFeature(if (event.key == .left) (self.feature_tab.selected + count - 1) % count else (self.feature_tab.selected + 1) % count);
                } else try self.cycleTab(event.key == .left);
            },
            .enter => {
                if (self.focus_area != .actions) return false;
                var available: [6]Action = undefined;
                const actions_value = self.actions(&available);
                if (actions_value.len == 0) return false;
                self.runAction(actions_value[@min(self.focused_action, actions_value.len - 1)]) catch {
                    self.status = "Unable to manage extension.";
                };
            },
            .up, .down, .page_up, .page_down, .home, .end => {
                if (self.focus_area == .feature_list and self.feature_tab.available.len > 0) {
                    const selected = self.feature_tab.selected;
                    const index = switch (event.key) {
                        .up, .page_up => selected -| 1,
                        .down, .page_down => @min(selected + 1, self.feature_tab.available.len - 1),
                        .home => 0,
                        .end => self.feature_tab.available.len - 1,
                        else => selected,
                    };
                    try self.selectFeature(index);
                    return true;
                }
                const scroll = if (self.focus_area == .additional) &self.additional_scroll else &self.scroll;
                switch (event.key) {
                    .up => scroll.* -|= 1,
                    .down => scroll.* +|= 1,
                    .page_up => scroll.* -|= self.viewport,
                    .page_down => scroll.* +|= self.viewport,
                    .home => scroll.* = 0,
                    .end => scroll.* = std.math.maxInt(usize),
                    else => unreachable,
                }
            },
            else => return false,
        }
        self.clampScroll();
        return true;
    }

    const Action = enum {
        enable,
        disable,
        enable_workspace,
        disable_workspace,
        install,
        uninstall,
        update,
        versions,
        manage,
        restart_extensions,
        installing,
        uninstalling,
        fn label(self: Action) []const u8 {
            return switch (self) {
                .enable => "Enable",
                .disable => "Disable",
                .enable_workspace => "Enable (Workspace)",
                .disable_workspace => "Disable (Workspace)",
                .install => "Install",
                .uninstall => "Uninstall",
                .update => "Update",
                .versions => "Versions…",
                .manage => "⚙",
                .restart_extensions => "Restart Extensions",
                .installing => "Installing…",
                .uninstalling => "Uninstalling…",
            };
        }
    };

    fn actions(self: *ExtensionEditor, result: *[6]Action) []Action {
        const restart = self.service.runtimeState(self.input.identifier) == .RestartExtensions;
        const extension = self.extension orelse {
            if (restart) {
                result[0] = .restart_extensions;
                return result[0..1];
            }
            return result[0..0];
        };
        if (self.service.operationState(self.input.identifier)) |state| {
            result[0] = if (state == .Installing) .installing else .uninstalling;
            return result[0..1];
        }
        if (extension.state == .Uninstalled) {
            if (extension.vsix_url == null) {
                result[0] = .versions;
                return result[0..1];
            }
            result[0] = .install;
            result[1] = if (self.service.context_menu != null) .manage else .versions;
            return result[0..2];
        }
        var count: usize = 0;
        if (restart) {
            result[count] = .restart_extensions;
            count += 1;
        }
        if (self.service.availableUpdate(self.input.identifier) != null) {
            result[count] = .update;
            count += 1;
        }
        result[count] = if (extension.isEnabled()) .disable else .enable;
        count += 1;
        if (!extension.is_builtin) {
            result[count] = .uninstall;
            count += 1;
        }
        if (self.service.context_menu != null) {
            result[count] = .manage;
            count += 1;
        } else if (!extension.is_builtin) {
            result[count] = .versions;
            count += 1;
        }
        return result[0..count];
    }

    fn runAction(self: *ExtensionEditor, action: Action) !void {
        switch (action) {
            .install => if (self.extension) |extension| try self.service.install(extension),
            .update => if (self.service.availableUpdate(self.input.identifier)) |extension| try self.service.install(extension.*),
            .uninstall => try self.service.uninstall(self.input.identifier),
            .versions => try self.service.showVersions(self.input.identifier),
            .manage => {
                const context = self.service.context_menu orelse return;
                const extension = if (self.extension) |*entry| entry else return;
                const menu = try @import("../../../../platform/contextview/browser/contextMenuService.zig").Menu.init(self.allocator, @as(u8, 0), struct {
                    fn run(_: *u8, _: []const u8) !void {}
                }.run);
                errdefer menu.deinit();
                try @import("extensionsActions.zig").addManagementActions(menu, self.service, extension, null);
                var available: [6]Action = undefined;
                var column: usize = 1;
                for (self.actions(&available)) |item| {
                    if (item == .manage) break;
                    column += list.displayWidth(item.label()) + 3;
                }
                try context.showContextMenu(menu, .{ .x = self.action_origin_x + @min(column, self.width -| 1), .y = self.action_origin_y });
            },
            .restart_extensions => try self.service.restartExtensions(),
            .enable, .disable, .enable_workspace, .disable_workspace => {
                _ = try self.service.requestEnablement(self.input.identifier, switch (action) {
                    .enable => .EnabledGlobally,
                    .disable => .DisabledGlobally,
                    .enable_workspace => .EnabledWorkspace,
                    .disable_workspace => .DisabledWorkspace,
                    else => unreachable,
                });
                self.status = "";
            },
            .installing, .uninstalling => {},
        }
    }

    pub fn handleMouse(self: *ExtensionEditor, event: *const ui.MouseEvent) !bool {
        switch (event.kind) {
            .wheel => {
                const scroll = if (self.additionalWidth() > 0 and event.x > self.bodyWidth()) &self.additional_scroll else &self.scroll;
                if (event.delta_y < 0) scroll.* -|= @abs(event.delta_y) else scroll.* +|= @intCast(event.delta_y);
            },
            .down => {
                if (event.button != .left) return false;
                if (event.y == 3 and event.x >= 1) {
                    var available: [6]Action = undefined;
                    var col: usize = 1;
                    for (self.actions(&available), 0..) |action, i| {
                        const end = col + list.displayWidth(action.label()) + 2;
                        if (event.x >= col and event.x < end) {
                            self.focus_area = .actions;
                            self.focused_action = i;
                            self.runAction(action) catch {
                                self.status = "Unable to manage extension.";
                            };
                            return true;
                        }
                        col = end + 1;
                    }
                } else if (event.y == 5) {
                    self.focus_area = .navbar;
                    var x: usize = 1;
                    for (self.tabs[0..self.tab_count]) |tab| {
                        const end = x + tab.label().len + 2;
                        if (event.x >= x and event.x < end) return blk: {
                            try self.selectTab(tab);
                            break :blk true;
                        };
                        x = end;
                    }
                } else if (event.y >= 7 and event.x >= 1) {
                    if (self.additionalWidth() > 0 and event.x > self.bodyWidth()) {
                        self.focus_area = .additional;
                        if (self.additional_layout) |*layout| if (layout.linkAt(self.additional_scroll + event.y - 7, event.x -| (self.bodyWidth() + 2))) |href| {
                            if (std.mem.startsWith(u8, href, "minecode-extension-category:")) {
                                const category = href["minecode-extension-category:".len..];
                                const query = try std.fmt.allocPrint(self.allocator, "@category:\"{s}\"", .{category});
                                defer self.allocator.free(query);
                                try self.service.openSearch(query);
                            } else if (std.mem.startsWith(u8, href, "https://") or std.mem.startsWith(u8, href, "http://")) {
                                if (self.opener) |opener| opener.requestOpen(href) catch {};
                            }
                        };
                        return true;
                    }
                    const feature_width = self.featureListWidth();
                    if (feature_width > 0 and event.x < feature_width) {
                        self.focus_area = .feature_list;
                        try self.selectFeature(event.y - 7);
                        return true;
                    }
                    self.focus_area = .body;
                    const document_x = if (feature_width > 0) feature_width + 1 else 0;
                    if (self.layout) |*layout| if (layout.linkAt(self.scroll + event.y - 7, event.x -| (document_x + 1))) |href| {
                        if ((self.active_tab == .dependencies or self.active_tab == .extensionPack) and std.mem.startsWith(u8, href, "minecode-extension-id:")) {
                            const identifier = href["minecode-extension-id:".len..];
                            try self.service.open(identifier);
                        } else if (std.mem.startsWith(u8, href, "#")) {
                            if (layout.anchorElement(href)) |target| self.scroll = @intFromFloat(@max(0, target.top));
                        } else if (std.mem.startsWith(u8, href, "https://") or std.mem.startsWith(u8, href, "http://")) {
                            if (self.opener) |opener| opener.requestOpen(href) catch {};
                        }
                    };
                }
            },
            else => return false,
        }
        self.clampScroll();
        return true;
    }

    pub fn paint(self: *ExtensionEditor, frame: *ui.Frame, x: usize, y: usize, w: usize, h: usize) !void {
        if (w == 0 or h == 0) return;
        self.action_origin_x = x;
        self.action_origin_y = y + 3;
        const grid = &frame.next;
        const colors = list.colors(self.palette);
        const bg = if (self.palette) |p| p.colorOr("editor.background", colors.background) else colors.background;
        const fg = if (self.palette) |p| p.colorOr("editor.foreground", colors.foreground) else colors.foreground;
        const normal: ui.cell.PaintStyle = .{ .fg = ui.cell.packColor(fg), .bg = ui.cell.packColor(bg) };
        var strong = normal;
        strong.attrs = ui.cell.Attr.bold;
        const dim: ui.cell.PaintStyle = .{ .fg = ui.cell.packColor(colors.dim), .bg = normal.bg };
        grid.fillRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h), normal);
        if (self.extension) |extension| {
            grid.putCodepoint(x, y, list.extension_glyph, 1, strong);
            _ = list.drawTextEllipsis(grid, x + 2, y, w -| 2, extension.display_name, strong);
            var info_buffer: [512]u8 = undefined;
            var count_buffer: [32]u8 = undefined;
            var rating_buffer: [32]u8 = undefined;
            const installs = widgets.InstallCountWidget.getInstallLabel(extension, false, &count_buffer);
            const rating = widgets.RatingsWidget.getRatingLabel(extension, false, &rating_buffer);
            const info = std.fmt.bufPrint(&info_buffer, "{s}{s}  v{s}  {s}{s}{s}{s}{s}", .{ if (extension.publisher_verified) "✓ " else "", extension.publisher, extension.version, if (extension.is_pre_release) "Pre-Release" else if (extension.state == .Uninstalled) "Marketplace" else if (extension.is_builtin) "Built-in" else "Installed", if (installs != null) "  ↓" else "", installs orelse "", if (rating != null) "  " else "", rating orelse "" }) catch extension.publisher;
            if (h > 1) _ = list.drawTextEllipsis(grid, x + 1, y + 1, w -| 1, info, dim);
            if (h > 2) _ = list.drawTextEllipsis(grid, x + 1, y + 2, w -| 1, extension.description, normal);
        } else _ = list.drawTextEllipsis(grid, x, y, w, self.input.base.getName(), strong);
        if (h > 3) {
            var available: [6]Action = undefined;
            var col: usize = 1;
            for (self.actions(&available), 0..) |action, i| {
                if (col >= w) break;
                var label_buffer: [64]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buffer, " {s} ", .{action.label()}) catch action.label();
                _ = list.drawTextEllipsis(grid, x + col, y + 3, w - col, label, .{ .fg = ui.cell.packColor(colors.selection_foreground), .bg = ui.cell.packColor(colors.active_selection), .attrs = if (self.focus_area == .actions and self.focused_action == i) ui.cell.Attr.underline else 0 });
                col += list.displayWidth(label) + 1;
            }
        }
        if (h > 4) _ = list.drawTextEllipsis(grid, x + 1, y + 4, w -| 1, if (self.service.management_error != null) "Extension management operation failed." else if (self.service.runtimeState(self.input.identifier)) |action| switch (action) {
            .RestartExtensions => "Restart Extensions to apply the change.",
            .ReloadWindow => "Restart the editor to apply the change.",
        } else self.status, dim);
        if (h > 5) {
            var col: usize = 1;
            for (self.tabs[0..self.tab_count]) |tab| {
                if (col >= w) break;
                const style = if (tab == self.active_tab) strong else dim;
                _ = list.drawTextEllipsis(grid, x + col, y + 5, w - col, tab.label(), style);
                col += tab.label().len + 2;
            }
        }
        if (self.width != w) {
            if (self.layout) |*layout| layout.deinit();
            self.layout = null;
            self.width = w;
            if (self.content) |*content| self.layout = try document.build(self.allocator, content, self.documentWidth() -| 2, .{});
            if (self.additional_layout) |*layout| layout.deinit();
            self.additional_layout = null;
            if (self.additionalWidth() > 0) if (self.additional_content) |*content| {
                self.additional_layout = try document.build(self.allocator, content, self.additionalWidth() -| 2, .{});
            };
            if (self.additionalWidth() == 0 and self.focus_area == .additional) self.focus_area = .body;
        }
        self.viewport = h -| 7;
        self.clampScroll();
        const feature_width = self.featureListWidth();
        if (feature_width > 0) {
            for (self.feature_tab.available[0..@min(self.feature_tab.available.len, self.viewport)], 0..) |feature, index| {
                const selected = index == self.feature_tab.selected;
                const style: ui.cell.PaintStyle = if (selected) .{ .fg = ui.cell.packColor(colors.selection_foreground), .bg = ui.cell.packColor(colors.inactive_selection), .attrs = if (self.focus_area == .feature_list) ui.cell.Attr.underline else 0 } else normal;
                grid.fillRect(@floatFromInt(x), @floatFromInt(y + 7 + index), @floatFromInt(feature_width), 1, style);
                _ = list.drawTextEllipsis(grid, x + 1, y + 7 + index, feature_width -| 1, feature.label, style);
            }
            for (0..self.viewport) |row| grid.putCodepoint(x + feature_width, y + 7 + row, '│', 1, dim);
        }
        const document_x = x + if (feature_width > 0) feature_width + 1 else 0;
        if (self.layout) |*layout| paintDocument(grid, layout, self.scroll, self.viewport, document_x, y + 7, self.documentWidth(), normal, dim);
        if (self.additional_layout) |*layout| {
            const left = x + self.bodyWidth();
            grid.fillRect(@floatFromInt(left), @floatFromInt(y + 7), 1, @floatFromInt(self.viewport), dim);
            var row: usize = 0;
            while (row < self.viewport) : (row += 1) grid.putCodepoint(left, y + 7 + row, '│', 1, dim);
            paintDocument(grid, layout, self.additional_scroll, self.viewport, left + 1, y + 7, self.additionalWidth(), normal, dim);
        }
    }
};

fn paintDocument(grid: *ui.CellGrid, layout: *const document.Document, scroll: usize, viewport: usize, x: usize, y: usize, width: usize, normal: ui.cell.PaintStyle, dim: ui.cell.PaintStyle) void {
    for (layout.rows[scroll..@min(layout.rows.len, scroll + viewport)], 0..) |row, i| {
        var col: usize = 1 + row.indent;
        if (row.rule) {
            while (col < width -| 1) : (col += 1) grid.putCodepoint(x + col, y + i, '─', 1, dim);
            continue;
        }
        for (row.spans) |span| {
            if (col >= width) break;
            var style = normal;
            if (span.style.color) |color| style.fg = ui.cell.packColor(color);
            if (span.style.background) |color| style.bg = ui.cell.packColor(color);
            if (span.style.bold orelse false) style.attrs |= ui.cell.Attr.bold;
            if (span.style.italic orelse false) style.attrs |= ui.cell.Attr.italic;
            if (span.style.underline orelse false) style.attrs |= ui.cell.Attr.underline;
            col += list.drawTextEllipsis(grid, x + col, y + i, width - col, span.text, style).used;
        }
    }
}

/// AdditionalDetailsWidget in extensionEditor.ts. Values come from the same
/// local/gallery inventory as the header; resource links are offered only
/// when the manifest or configured gallery actually exposes them.
pub fn renderAdditionalDetails(allocator: std.mem.Allocator, extension: model.IExtension, remote: ?*const model.IExtension, manifest: std.json.Value, gallery_url: ?[]const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    if (extension.state == .Installed) {
        try writer.print("### Installation\n\nIdentifier\n`{s}`\n\n", .{extension.identifier});
        if (!extension.is_builtin) try writer.print("Version\n`{s}`\n\n", .{extension.version});
        if (extension.installed_timestamp) |timestamp| try writeDate(writer, "Last Updated", timestamp);
        if (extension.source) |source| {
            if (!std.mem.eql(u8, source, "gallery")) try writer.print("Source\n{s}\n\n", .{if (std.mem.eql(u8, source, "vsix")) "VSIX" else "Local"});
        }
        if (extension.pinned) try writer.writeAll("Auto Update\nPinned version\n\n");
    }
    if (remote != null or extension.state == .Uninstalled) {
        const gallery_extension = remote orelse &extension;
        try writer.writeAll("### Marketplace\n\n");
        if (extension.state == .Uninstalled) try writer.print("Identifier\n`{s}`\n\nVersion\n`{s}`\n\n", .{ extension.identifier, extension.version });
        if (gallery_extension.release_date) |timestamp| try writeDate(writer, "Published", timestamp);
        if (gallery_extension.last_updated) |timestamp| try writeDate(writer, "Last Released", timestamp);
    }
    if (extension.categories.len > 0) {
        try writer.writeAll("### Categories\n\n");
        for (extension.categories) |category| {
            if (std.mem.indexOfAny(u8, category, "<>\r\n\"") != null) continue;
            try writer.print("- [{s}](<minecode-extension-category:{s}>)\n", .{ category, category });
        }
        try writer.writeAll("\n");
    }
    try writer.writeAll("### Resources\n\n");
    const repository = features.property(manifest, "repository");
    const bugs = features.property(manifest, "bugs");
    try writeLink(writer, "Repository", if (repository == .object) features.property(repository, "url") else repository);
    try writeLink(writer, "Issues", if (bugs == .object) features.property(bugs, "url") else bugs);
    try writeLink(writer, "Homepage", features.property(manifest, "homepage"));
    if (extension.publisher_domain) |domain| try writeLink(writer, "Publisher", .{ .string = domain });
    if (gallery_url) |value| {
        const url = std.mem.trimEnd(u8, value, "/");
        if (std.mem.endsWith(u8, url, "/vscode/gallery")) if (std.mem.indexOfScalar(u8, extension.identifier, '.')) |dot| {
            const link = try std.fmt.allocPrint(allocator, "{s}/extension/{s}/{s}", .{ url[0 .. url.len - "/vscode/gallery".len], extension.identifier[0..dot], extension.identifier[dot + 1 ..] });
            defer allocator.free(link);
            try writeLink(writer, "Marketplace", .{ .string = link });
        };
    }
    return output.toOwnedSlice();
}

fn writeLink(writer: *std.Io.Writer, label: []const u8, value: std.json.Value) !void {
    if (value != .string) return;
    const url = value.string;
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return;
    if (std.mem.indexOfAny(u8, url, "<>\r\n ") != null) return;
    try writer.print("- [{s}](<{s}>)\n", .{ label, url });
}

fn writeDate(writer: *std.Io.Writer, label: []const u8, timestamp: i64) !void {
    if (timestamp <= 0 or timestamp > 253402300799999) return;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(timestamp, 1000)) };
    const year = epoch.getEpochDay().calculateYearDay();
    const month = year.calculateMonthDay();
    try writer.print("{s}\n{d}-{d:0>2}-{d:0>2}\n\n", .{ label, year.year, month.month.numeric(), @as(u8, month.day_index) + 1 });
}
