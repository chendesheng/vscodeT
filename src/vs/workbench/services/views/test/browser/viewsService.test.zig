// Terminal coverage for the view lookup/open/close subset of
// src/vs/workbench/services/views/test/browser/viewsService.test.ts.
// The upstream container-open keybinding test uses an auxiliary bar and
// alternate window layout modes, neither of which exists in the single
// terminal workbench. The mounted view and visibility contracts are tested
// through the actual native factory rather than mock DOM panes.
const std = @import("std");
const OutlinePane = @import("../../../../contrib/outline/browser/outlinePane.zig").OutlinePane;
const SearchView = @import("../../../../contrib/search/browser/searchViewTerminal.zig").SearchView;
const TestWindow = @import("../../../../test/browser/workbenchTestServices.zig").TestWindow;

pub fn Tests(comptime Window: type, comptime factory: @import("../../../../browser/parts/editor/editorPane.zig").EditorViewFactory) type {
    return struct {
        test "ViewsService: open and close a view body independently of the container" {
            const window = try TestWindow(Window, factory).init(std.testing.allocator, std.Io.Threaded.global_single_threaded.io(), &.{}, 60, 12);
            defer window.deinit();
            const service = window.workbench.views_api;
            try std.testing.expect(!service.isViewVisible(OutlinePane.ID));
            const view = (try service.openView(OutlinePane, true)).?;
            try std.testing.expectEqual(view, service.getViewWithId(OutlinePane).?);
            try std.testing.expectEqual(view, service.getActiveViewWithId(OutlinePane).?);
            try std.testing.expect(service.isViewVisible(OutlinePane.ID));
            try service.closeView(OutlinePane.ID);
            try std.testing.expect(!service.isViewVisible(OutlinePane.ID));
            try std.testing.expect(window.workbench.layout.isVisible(.sidebar));
            try std.testing.expectEqual(view, service.getActiveViewWithId(OutlinePane).?);
            _ = (try service.openView(OutlinePane, false)).?;
            try std.testing.expect(service.isViewVisible(OutlinePane.ID));
            const search = (try service.openView(SearchView, true)).?;
            try std.testing.expectEqual(search, service.getActiveViewWithId(SearchView).?);
            try std.testing.expect(service.isViewVisible(SearchView.ID));
            try std.testing.expect(service.getActiveViewWithId(OutlinePane) == null);
            try std.testing.expectEqual(view, service.getViewWithId(OutlinePane).?);
            try service.closeView(SearchView.ID);
            try std.testing.expect(!window.workbench.layout.isVisible(.sidebar));
            try std.testing.expect(!service.isViewVisible(SearchView.ID));
        }
    };
}
