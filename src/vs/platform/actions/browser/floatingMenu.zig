// Port of `src/vs/platform/actions/browser/floatingMenu.ts`'s
// FloatingClickWidget. The terminal projects the browser's small button to
// one cell row with horizontal padding; there are no pixel radii or shadows.
const ui = @import("ui");

pub const FloatingClickWidget = struct {
    label: []const u8,
    context: *anyopaque,
    on_click: *const fn (*anyopaque) void,
    active: bool = false,

    pub fn build(self: *FloatingClickWidget, doc: *ui.Document, foreground: ui.Color, background: ui.Color, hover: ui.Color) !*ui.Node {
        const root = try doc.createElement(.div);
        errdefer doc.destroy(root);
        root.setStyle(.{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 }, .padding = .{ .left = 1, .right = 1 }, .background = background, .color = foreground, .pointer = .pointer, .overflow = .hidden });
        root.setHoverStyle(.{ .background = hover });
        try root.setAttribute("role", "button");
        try root.setAttribute("aria-label", self.label);
        try root.setAttribute("class", "floating-click-widget");
        try root.setTextContent(self.label);
        try root.addEventListener(.{ .context = self, .mouse_down = mouseDown });
        return root;
    }

    fn mouseDown(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *FloatingClickWidget = @ptrCast(@alignCast(context.?));
        if (!self.active or event.button != .left) return;
        event.preventDefault();
        event.stopPropagation();
        self.on_click(self.context);
    }
};
