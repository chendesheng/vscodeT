// Terminal view boundary for the workbench editor pane and diff widget.
// Zig adaptation of the editor control/view contract. The concrete retained
// cell view, input and painting live in src/tui; the host supplies its factory.
// The handle borrows the editor and view-model host for the lifetime of the view.
const std = @import("std");
const ui = @import("ui");
const Editor = @import("./codeEditorWidgetTerminal.zig").Editor;
const TerminalViewHost = @import("./terminalViewHost.zig").TerminalViewHost;
const editorBrowser = @import("../../editorBrowser.zig");
const ViewLine = @import("../../viewParts/viewLines/viewLine.zig").ViewLine;
const editor_options = @import("../../../common/config/editorOptions.zig");
const terminal_editor_config = @import("../../config/terminalEditorConfiguration.zig");
const Position = @import("../../../common/core/position.zig").Position;
const StickyScrollHost = @import("../../../contrib/stickyScroll/browser/stickyScrollHost.zig").StickyScrollHost;
const GhostText = @import("../../../contrib/inlineCompletions/browser/ghostText.zig").GhostText;
const theme_colors_mod = @import("../../../../workbench/browser/themeColors.zig");

/// Terminal contribution callback for `View.applyEditorSettings`.
pub const ConfigurationListener = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque, event: editor_options.ConfigurationChangedEvent) void,
};

/// A cell position, 0-based, ready for `tui.moveCursor` after adding one.
pub const Cell = struct {
    row: usize,
    col: usize,
};

pub const EditorViewFactory = *const fn (std.mem.Allocator, *Editor) anyerror!*IEditorView;

/// The mounted document and native origin used by an embedded editor.
pub const SurfaceContext = struct { surface: *ui.Surface, x: usize, y: usize };

pub const IEditorView = struct {
    context: *anyopaque,
    editor: *Editor,
    terminal_view_host: *TerminalViewHost,
    ghost_text: *GhostText,
    vtable: *const VTable,

    const VTable = struct {
        deinit: *const fn (*anyopaque) void,
        refresh: *const fn (*anyopaque) anyerror!void,
        paint: *const fn (*anyopaque) anyerror!void,
        mountInto: *const fn (*anyopaque, *ui.Surface, *ui.Node, usize, usize, usize) anyerror!void,
        detach: *const fn (*anyopaque) void,
        unmountSurface: *const fn (*anyopaque) void,
        surfaceContext: *const fn (*anyopaque) SurfaceContext,
        isMounted: *const fn (*anyopaque) bool,
        grid: *const fn (*anyopaque) *const ui.CellGrid,
        pointerAt: *const fn (*anyopaque, usize, usize) anyerror!ui.Pointer,
        cursorCell: *const fn (*anyopaque) ?Cell,
        setStatusBarVisible: *const fn (*anyopaque, bool) anyerror!void,
        invalidate: *const fn (*anyopaque) void,
        dispatchMouse: *const fn (*anyopaque, *ui.MouseEvent) anyerror!bool,
        dispatchKey: *const fn (*anyopaque, *ui.KeyEvent) bool,
        focusEditor: *const fn (*anyopaque) void,
        isFocused: *const fn (*anyopaque) bool,
        setFocused: *const fn (*anyopaque, bool) bool,
        hasEditorFocus: *const fn (*anyopaque) bool,
        addOverlayWidget: *const fn (*anyopaque, editorBrowser.IOverlayWidget) anyerror!void,
        addContentWidget: *const fn (*anyopaque, editorBrowser.IContentWidget) anyerror!void,
        removeOverlayWidget: *const fn (*anyopaque, []const u8) anyerror!void,
        removeContentWidget: *const fn (*anyopaque, []const u8) anyerror!void,
        mouseTargetAt: *const fn (*anyopaque, usize, usize) anyerror!editorBrowser.MouseTarget,
        setGlyphHover: *const fn (*anyopaque, editorBrowser.MouseTarget) void,
        clearGlyphHover: *const fn (*anyopaque) void,
        setTopInset: *const fn (*anyopaque, usize) void,
        applyEditorSettings: *const fn (*anyopaque, terminal_editor_config.Reader, ?[]const u8, ?[]const u8) anyerror!bool,
        applySubEditorOptionOverrides: *const fn (*anyopaque, ?bool, ?bool, ?bool) void,
        applyLineNumbersOverride: *const fn (*anyopaque, editor_options.RenderLineNumbersType) anyerror!void,
        setThemeColors: *const fn (*anyopaque, ?*const theme_colors_mod.ThemeColors) void,
        setMarkerSelectionHighlights: *const fn (*anyopaque, []const editorBrowser.Decoration) anyerror!void,
        setSearchHighlights: *const fn (*anyopaque, []const editorBrowser.Decoration) anyerror!void,
        addConfigurationListener: *const fn (*anyopaque, ConfigurationListener) anyerror!void,
        removeConfigurationListener: *const fn (*anyopaque, ConfigurationListener) void,
        visibleRowOf: *const fn (*anyopaque, Position) ?usize,
        stickyScrollHost: *const fn (*anyopaque) StickyScrollHost,
        interface: *const fn (*anyopaque) editorBrowser.IEditorKeyTarget,
        themeColors: *const fn (*anyopaque) ?*const theme_colors_mod.ThemeColors,
        lineStyleFunction: *const fn (*anyopaque) ViewLine.PartStyleFn,
        decorationBitsFunction: *const fn (*anyopaque) *const fn ([]const u8) u32,
    };

    pub fn deinit(self: *IEditorView) void {
        return self.vtable.deinit(self.context);
    }

    pub fn refresh(self: *IEditorView) anyerror!void {
        return self.vtable.refresh(self.context);
    }

    pub fn paint(self: *IEditorView) anyerror!void {
        return self.vtable.paint(self.context);
    }

    pub fn mountInto(self: *IEditorView, surface: *ui.Surface, parent: *ui.Node, x: usize, y: usize, left: usize) anyerror!void {
        return self.vtable.mountInto(self.context, surface, parent, x, y, left);
    }

    pub fn detach(self: *IEditorView) void {
        return self.vtable.detach(self.context);
    }

    pub fn unmountSurface(self: *IEditorView) void {
        self.vtable.unmountSurface(self.context);
    }

    pub fn surfaceContext(self: *IEditorView) SurfaceContext {
        return self.vtable.surfaceContext(self.context);
    }

    pub fn isMounted(self: *IEditorView) bool {
        return self.vtable.isMounted(self.context);
    }

    pub fn grid(self: *IEditorView) *const ui.CellGrid {
        return self.vtable.grid(self.context);
    }

    pub fn pointerAt(self: *IEditorView, x: usize, y: usize) anyerror!ui.Pointer {
        return self.vtable.pointerAt(self.context, x, y);
    }

    pub fn cursorCell(self: *IEditorView) ?Cell {
        return self.vtable.cursorCell(self.context);
    }

    pub fn setStatusBarVisible(self: *IEditorView, visible: bool) anyerror!void {
        return self.vtable.setStatusBarVisible(self.context, visible);
    }

    pub fn invalidate(self: *IEditorView) void {
        return self.vtable.invalidate(self.context);
    }

    pub fn dispatchMouse(self: *IEditorView, event: *ui.MouseEvent) anyerror!bool {
        return self.vtable.dispatchMouse(self.context, event);
    }

    pub fn dispatchKey(self: *IEditorView, event: *ui.KeyEvent) bool {
        return self.vtable.dispatchKey(self.context, event);
    }

    pub fn focusEditor(self: *IEditorView) void {
        return self.vtable.focusEditor(self.context);
    }

    pub fn isFocused(self: *IEditorView) bool {
        return self.vtable.isFocused(self.context);
    }

    pub fn setFocused(self: *IEditorView, focused: bool) bool {
        return self.vtable.setFocused(self.context, focused);
    }

    pub fn hasEditorFocus(self: *IEditorView) bool {
        return self.vtable.hasEditorFocus(self.context);
    }

    pub fn viewZones(self: *IEditorView) *@import("../../viewParts/viewZones/viewZones.zig").ViewZones {
        return &self.terminal_view_host.viewRef().view_zones;
    }

    pub fn addOverlayWidget(self: *IEditorView, widget: editorBrowser.IOverlayWidget) anyerror!void {
        return self.vtable.addOverlayWidget(self.context, widget);
    }

    pub fn addContentWidget(self: *IEditorView, widget: editorBrowser.IContentWidget) anyerror!void {
        return self.vtable.addContentWidget(self.context, widget);
    }

    pub fn removeOverlayWidget(self: *IEditorView, id: []const u8) !void {
        return self.vtable.removeOverlayWidget(self.context, id);
    }
    pub fn removeContentWidget(self: *IEditorView, id: []const u8) !void {
        return self.vtable.removeContentWidget(self.context, id);
    }
    pub fn mouseTargetAt(self: *IEditorView, x: usize, y: usize) !editorBrowser.MouseTarget {
        return self.vtable.mouseTargetAt(self.context, x, y);
    }
    pub fn setGlyphHover(self: *IEditorView, target: editorBrowser.MouseTarget) void {
        self.vtable.setGlyphHover(self.context, target);
    }
    pub fn clearGlyphHover(self: *IEditorView) void {
        self.vtable.clearGlyphHover(self.context);
    }

    pub fn setTopInset(self: *IEditorView, rows: usize) void {
        return self.vtable.setTopInset(self.context, rows);
    }

    pub fn applyEditorSettings(self: *IEditorView, reader: terminal_editor_config.Reader, language_id: ?[]const u8, resource: ?[]const u8) anyerror!bool {
        return self.vtable.applyEditorSettings(self.context, reader, language_id, resource);
    }

    pub fn applySubEditorOptionOverrides(self: *IEditorView, glyph_margin: ?bool, sticky_scroll: ?bool, code_lens: ?bool) void {
        self.vtable.applySubEditorOptionOverrides(self.context, glyph_margin, sticky_scroll, code_lens);
    }

    pub fn applyLineNumbersOverride(self: *IEditorView, render_type: editor_options.RenderLineNumbersType) anyerror!void {
        return self.vtable.applyLineNumbersOverride(self.context, render_type);
    }

    pub fn setThemeColors(self: *IEditorView, palette: ?*const theme_colors_mod.ThemeColors) void {
        return self.vtable.setThemeColors(self.context, palette);
    }

    pub fn setMarkerSelectionHighlights(self: *IEditorView, decorations: []const editorBrowser.Decoration) anyerror!void {
        return self.vtable.setMarkerSelectionHighlights(self.context, decorations);
    }

    pub fn setSearchHighlights(self: *IEditorView, decorations: []const editorBrowser.Decoration) anyerror!void {
        return self.vtable.setSearchHighlights(self.context, decorations);
    }

    pub fn addConfigurationListener(self: *IEditorView, listener: ConfigurationListener) anyerror!void {
        return self.vtable.addConfigurationListener(self.context, listener);
    }

    pub fn removeConfigurationListener(self: *IEditorView, listener: ConfigurationListener) void {
        return self.vtable.removeConfigurationListener(self.context, listener);
    }

    pub fn visibleRowOf(self: *IEditorView, position: Position) ?usize {
        return self.vtable.visibleRowOf(self.context, position);
    }

    pub fn stickyScrollHost(self: *IEditorView) StickyScrollHost {
        return self.vtable.stickyScrollHost(self.context);
    }

    pub fn interface(self: *IEditorView) editorBrowser.IEditorKeyTarget {
        return self.vtable.interface(self.context);
    }

    pub fn themeColors(self: *IEditorView) ?*const theme_colors_mod.ThemeColors {
        return self.vtable.themeColors(self.context);
    }

    pub fn lineStyleFunction(self: *IEditorView) ViewLine.PartStyleFn {
        return self.vtable.lineStyleFunction(self.context);
    }

    pub fn decorationBitsFunction(self: *IEditorView) *const fn ([]const u8) u32 {
        return self.vtable.decorationBitsFunction(self.context);
    }

    /// Constructs a borrowed handle. The native view owns this handle and
    /// all pointers remain valid until deinit destroys the native view.
    pub fn bind(native: anytype) IEditorView {
        const Native = @TypeOf(native.*);
        const Adapter = struct {
            fn deinit(context: *anyopaque) void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.deinit();
            }
            fn refresh(context: *anyopaque) anyerror!void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.refresh();
            }
            fn paint(context: *anyopaque) anyerror!void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.paint();
            }
            fn mountInto(context: *anyopaque, surface: *ui.Surface, parent: *ui.Node, x: usize, y: usize, left: usize) anyerror!void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.mountInto(surface, parent, x, y, left);
            }
            fn detach(context: *anyopaque) void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.detach();
            }
            fn unmountSurface(context: *anyopaque) void {
                const view: *Native = @ptrCast(@alignCast(context));
                view.unmountSurface();
            }
            fn surfaceContext(context: *anyopaque) SurfaceContext {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.surfaceContext();
            }
            fn isMounted(context: *anyopaque) bool {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.isMounted();
            }
            fn grid(context: *anyopaque) *const ui.CellGrid {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.grid();
            }
            fn pointerAt(context: *anyopaque, x: usize, y: usize) anyerror!ui.Pointer {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.pointerAt(x, y);
            }
            fn cursorCell(context: *anyopaque) ?Cell {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.cursorCell();
            }
            fn setStatusBarVisible(context: *anyopaque, visible: bool) anyerror!void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.setStatusBarVisible(visible);
            }
            fn invalidate(context: *anyopaque) void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.invalidate();
            }
            fn dispatchMouse(context: *anyopaque, event: *ui.MouseEvent) anyerror!bool {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.dispatchMouse(event);
            }
            fn dispatchKey(context: *anyopaque, event: *ui.KeyEvent) bool {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.dispatchKey(event);
            }
            fn focusEditor(context: *anyopaque) void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.focusEditor();
            }
            fn isFocused(context: *anyopaque) bool {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.isFocused();
            }
            fn setFocused(context: *anyopaque, focused: bool) bool {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.setFocused(focused);
            }
            fn hasEditorFocus(context: *anyopaque) bool {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.hasEditorFocus();
            }
            fn addOverlayWidget(context: *anyopaque, widget: editorBrowser.IOverlayWidget) anyerror!void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.addOverlayWidget(widget);
            }
            fn addContentWidget(context: *anyopaque, widget: editorBrowser.IContentWidget) anyerror!void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.addContentWidget(widget);
            }
            fn removeOverlayWidget(context: *anyopaque, id: []const u8) anyerror!void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.removeOverlayWidget(id);
            }
            fn removeContentWidget(context: *anyopaque, id: []const u8) anyerror!void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.removeContentWidget(id);
            }
            fn mouseTargetAt(context: *anyopaque, x: usize, y: usize) anyerror!editorBrowser.MouseTarget {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.mouseTargetAt(x, y);
            }
            fn setGlyphHover(context: *anyopaque, target: editorBrowser.MouseTarget) void {
                const view: *Native = @ptrCast(@alignCast(context));
                view.setGlyphHover(target);
            }
            fn clearGlyphHover(context: *anyopaque) void {
                const view: *Native = @ptrCast(@alignCast(context));
                view.clearGlyphHover();
            }
            fn setTopInset(context: *anyopaque, rows: usize) void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.setTopInset(rows);
            }
            fn applyEditorSettings(context: *anyopaque, reader: terminal_editor_config.Reader, language_id: ?[]const u8, resource: ?[]const u8) anyerror!bool {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.applyEditorSettings(reader, language_id, resource);
            }
            fn applySubEditorOptionOverrides(context: *anyopaque, glyph_margin: ?bool, sticky_scroll: ?bool, code_lens: ?bool) void {
                const view: *Native = @ptrCast(@alignCast(context));
                view.applySubEditorOptionOverrides(glyph_margin, sticky_scroll, code_lens);
            }
            fn applyLineNumbersOverride(context: *anyopaque, render_type: editor_options.RenderLineNumbersType) anyerror!void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.applyLineNumbersOverride(render_type);
            }
            fn setThemeColors(context: *anyopaque, palette: ?*const theme_colors_mod.ThemeColors) void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.setThemeColors(palette);
            }
            fn setMarkerSelectionHighlights(context: *anyopaque, decorations: []const editorBrowser.Decoration) anyerror!void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.setMarkerSelectionHighlights(decorations);
            }
            fn setSearchHighlights(context: *anyopaque, decorations: []const editorBrowser.Decoration) anyerror!void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.setSearchHighlights(decorations);
            }
            fn addConfigurationListener(context: *anyopaque, listener: ConfigurationListener) anyerror!void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.addConfigurationListener(listener);
            }
            fn removeConfigurationListener(context: *anyopaque, listener: ConfigurationListener) void {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.removeConfigurationListener(listener);
            }
            fn visibleRowOf(context: *anyopaque, position: Position) ?usize {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.visibleRowOf(position);
            }
            fn stickyScrollHost(context: *anyopaque) StickyScrollHost {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.stickyScrollHost();
            }
            fn interface(context: *anyopaque) editorBrowser.IEditorKeyTarget {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.interface();
            }
            fn themeColors(context: *anyopaque) ?*const theme_colors_mod.ThemeColors {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.theme_colors;
            }
            fn lineStyleFunction(context: *anyopaque) ViewLine.PartStyleFn {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.lineStyleFunction();
            }
            fn decorationBitsFunction(context: *anyopaque) *const fn ([]const u8) u32 {
                const view: *Native = @ptrCast(@alignCast(context));
                return view.decorationBitsFunction();
            }
            const vtable: VTable = .{
                .deinit = @This().deinit,
                .refresh = @This().refresh,
                .paint = @This().paint,
                .mountInto = @This().mountInto,
                .detach = @This().detach,
                .unmountSurface = @This().unmountSurface,
                .surfaceContext = @This().surfaceContext,
                .isMounted = @This().isMounted,
                .grid = @This().grid,
                .pointerAt = @This().pointerAt,
                .cursorCell = @This().cursorCell,
                .setStatusBarVisible = @This().setStatusBarVisible,
                .invalidate = @This().invalidate,
                .dispatchMouse = @This().dispatchMouse,
                .dispatchKey = @This().dispatchKey,
                .focusEditor = @This().focusEditor,
                .isFocused = @This().isFocused,
                .setFocused = @This().setFocused,
                .hasEditorFocus = @This().hasEditorFocus,
                .addOverlayWidget = @This().addOverlayWidget,
                .addContentWidget = @This().addContentWidget,
                .removeOverlayWidget = @This().removeOverlayWidget,
                .removeContentWidget = @This().removeContentWidget,
                .mouseTargetAt = @This().mouseTargetAt,
                .setGlyphHover = @This().setGlyphHover,
                .clearGlyphHover = @This().clearGlyphHover,
                .setTopInset = @This().setTopInset,
                .applyEditorSettings = @This().applyEditorSettings,
                .applySubEditorOptionOverrides = @This().applySubEditorOptionOverrides,
                .applyLineNumbersOverride = @This().applyLineNumbersOverride,
                .setThemeColors = @This().setThemeColors,
                .setMarkerSelectionHighlights = @This().setMarkerSelectionHighlights,
                .setSearchHighlights = @This().setSearchHighlights,
                .addConfigurationListener = @This().addConfigurationListener,
                .removeConfigurationListener = @This().removeConfigurationListener,
                .visibleRowOf = @This().visibleRowOf,
                .stickyScrollHost = @This().stickyScrollHost,
                .interface = @This().interface,
                .themeColors = @This().themeColors,
                .lineStyleFunction = @This().lineStyleFunction,
                .decorationBitsFunction = @This().decorationBitsFunction,
            };
        };
        return .{
            .context = native,
            .editor = native.editor,
            .terminal_view_host = native.terminal_view_host,
            .ghost_text = &native.ghost_text,
            .vtable = &Adapter.vtable,
        };
    }
};
