// Port of the layout and working-copy bindings in
// `src/vs/workbench/browser/contextkeys.ts`. A terminal has one main window.
const contextkeys = @import("../../platform/contextkey/common/contextkey.zig");
const services = @import("../services/layout/browser/layoutService.zig");
const WorkingCopyService = @import("../services/workingCopy/common/workingCopyService.zig").WorkingCopyService;
const IWorkingCopy = @import("../services/workingCopy/common/workingCopy.zig").IWorkingCopy;

pub const WorkbenchContextKeysHandler = struct {
    layout_service: services.IWorkbenchLayoutService,
    working_copy_service: *WorkingCopyService,
    dirty_working_copies: contextkeys.IContextKey,
    in_zen_mode: contextkeys.IContextKey,
    main_editor_centered: contextkeys.IContextKey,
    main_editor_visible: contextkeys.IContextKey,
    sidebar_visible: contextkeys.IContextKey,
    panel_visible: contextkeys.IContextKey,
    dirty_listener: usize,
    zen_listener: usize,
    centered_listener: usize,
    visibility_listener: usize,

    pub fn init(self: *@This(), keys: contextkeys.IContextKeyService, layout: services.IWorkbenchLayoutService, copies: *WorkingCopyService) !void {
        self.* = .{
            .layout_service = layout,
            .working_copy_service = copies,
            .dirty_working_copies = try keys.createKey("dirtyWorkingCopies", .{ .boolean = false }),
            .in_zen_mode = try keys.createKey("inZenMode", .{ .boolean = false }),
            .main_editor_centered = try keys.createKey("isCenteredLayout", .{ .boolean = false }),
            .main_editor_visible = try keys.createKey("mainEditorAreaVisible", .{ .boolean = true }),
            .sidebar_visible = try keys.createKey("sideBarVisible", .{ .boolean = false }),
            .panel_visible = try keys.createKey("panelVisible", .{ .boolean = false }),
            .dirty_listener = undefined,
            .zen_listener = undefined,
            .centered_listener = undefined,
            .visibility_listener = undefined,
        };
        self.dirty_working_copies.set(.{ .boolean = copies.hasDirty() });
        self.in_zen_mode.set(.{ .boolean = layout.is_zen_mode_active(layout.context) });
        self.main_editor_centered.set(.{ .boolean = layout.is_main_editor_centered(layout.context) });
        self.updatePartVisibility();
        self.zen_listener = try layout.on_did_change_zen_mode.listen(self, onZenMode);
        errdefer layout.on_did_change_zen_mode.unlisten(self.zen_listener);
        self.centered_listener = try layout.on_did_change_main_editor_centered.listen(self, onCenteredLayout);
        errdefer layout.on_did_change_main_editor_centered.unlisten(self.centered_listener);
        self.visibility_listener = try layout.on_did_change_part_visibility.listen(self, onPartVisibility);
        errdefer layout.on_did_change_part_visibility.unlisten(self.visibility_listener);
        self.dirty_listener = try copies.on_did_change_dirty.listen(self, onDidChangeDirty);
    }

    pub fn deinit(self: *@This()) void {
        self.working_copy_service.on_did_change_dirty.unlisten(self.dirty_listener);
        self.layout_service.on_did_change_part_visibility.unlisten(self.visibility_listener);
        self.layout_service.on_did_change_main_editor_centered.unlisten(self.centered_listener);
        self.layout_service.on_did_change_zen_mode.unlisten(self.zen_listener);
    }

    fn updatePartVisibility(self: *@This()) void {
        self.main_editor_visible.set(.{ .boolean = self.layout_service.isVisible(.editor) });
        self.panel_visible.set(.{ .boolean = self.layout_service.isVisible(.panel) });
        self.sidebar_visible.set(.{ .boolean = self.layout_service.isVisible(.sidebar) });
    }

    fn onPartVisibility(_: services.IPartVisibilityChangeEvent, self: *@This()) !void {
        self.updatePartVisibility();
    }

    fn onZenMode(active: bool, self: *@This()) !void {
        self.in_zen_mode.set(.{ .boolean = active });
    }

    fn onCenteredLayout(centered: bool, self: *@This()) !void {
        self.main_editor_centered.set(.{ .boolean = centered });
    }

    fn onDidChangeDirty(copy: *const IWorkingCopy, self: *@This()) !void {
        self.dirty_working_copies.set(.{ .boolean = copy.getDirty() or self.working_copy_service.hasDirty() });
    }
};
