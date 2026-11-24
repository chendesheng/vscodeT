// Port of src/vs/workbench/contrib/webviewPanel/browser/webviewEditorInput.ts.
// A terminal panel has the upstream singleton input identity and tab title.
// Its editor pane paints terminal content in place of a browser webview.
const std = @import("std");
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const Caps = @import("../../../common/editor.zig").EditorInputCapabilities;

pub const WebviewInput = struct {
    base: EditorInput,
    resource: []u8,
    title: []u8,

    pub fn init(allocator: std.mem.Allocator, view_type: []const u8, title: []const u8) !*WebviewInput {
        const self = try allocator.create(WebviewInput);
        errdefer allocator.destroy(self);
        const resource = try std.fmt.allocPrint(allocator, "webview-panel:/webview-{s}-{x}", .{ view_type, @intFromPtr(self) });
        errdefer allocator.free(resource);
        self.* = .{
            .base = EditorInput.init(allocator, "workbench.editors.webviewInput"),
            .resource = resource,
            .title = try allocator.dupe(u8, title),
        };
        self.base.editor_id = view_type;
        self.base.resource = resource;
        self.base.name = self.title;
        self.base.capabilities = Caps.Readonly | Caps.Singleton | Caps.CanDropIntoEditor;
        // Closed-file history can only reopen filesystem resources.
        self.base.can_reopen_fn = canReopen;
        return self;
    }

    fn canReopen(_: *const EditorInput) bool {
        return false;
    }

    pub fn setWebviewTitle(self: *WebviewInput, value: []const u8) !void {
        const title = try self.base.allocator.dupe(u8, value);
        self.base.allocator.free(self.title);
        self.title = title;
        self.base.name = title;
        try self.base.fireLabel();
    }

    pub fn deinit(self: *WebviewInput) void {
        const allocator = self.base.allocator;
        self.base.dispose();
        self.base.deinit();
        allocator.free(self.resource);
        allocator.free(self.title);
        allocator.destroy(self);
    }
};
