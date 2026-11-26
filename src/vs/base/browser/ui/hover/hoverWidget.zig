// Port of `src/vs/base/browser/ui/hover/hoverWidget.ts`.
// Native cell geometry replaces the browser's DomScrollableElement and pixel
// scrollbars. Both editor hover widgets use this shared container and content.
const ui = @import("ui");
const css = @import("hoverWidget_css.zig");

pub const Theme = struct {
    background: ui.Color = .{ .r = 37, .g = 37, .b = 38 },
    border: ui.Color = .{ .r = 69, .g = 69, .b = 69 },
    foreground: ui.Color = .{ .r = 204, .g = 204, .b = 204 },
    scrollbar: ui.Color = .{ .r = 90, .g = 90, .b = 90 },
    scrollbar_thumb: ui.Color = .{ .r = 160, .g = 160, .b = 160 },
    focused_border: ui.Color = .{ .r = 96, .g = 130, .b = 200 },
};

pub const Geometry = struct {
    root_width: usize,
    root_height: usize,
    border: usize,
    content_width: usize,
    content_rows: usize,
    visible_rows: usize,
    scroll_top: usize,
    scrollbar: bool,
};

pub const HoverWidget = struct {
    containerDomNode: *ui.Node,
    contentsDomNode: *ui.Node,

    pub fn build(doc: *ui.Document, geometry: Geometry, theme: Theme) !HoverWidget {
        const root = try doc.createElement(.div);
        errdefer doc.destroy(root);
        try root.addClass(css.Class.monaco_hover);
        root.setStyle(.{
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(geometry.root_width) },
            .height = .{ .cells = @floatFromInt(geometry.root_height) },
            .border = .all(@floatFromInt(geometry.border)),
        });
        const clip = try doc.createElement(.div);
        _ = try root.appendChild(clip);
        try clip.addClass(css.Class.monaco_hover_content);
        clip.setStyle(.{
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(geometry.content_width) },
            .height = .{ .cells = @floatFromInt(geometry.visible_rows) },
        });
        const contents = try doc.createElement(.div);
        _ = try clip.appendChild(contents);
        contents.setStyle(.{
            .position = .absolute,
            .left = .{ .cells = 0 },
            .top = .{ .cells = 0 },
            .width = .{ .cells = @floatFromInt(geometry.content_width) },
            .height = .{ .cells = @floatFromInt(@max(geometry.content_rows, geometry.visible_rows)) },
            .translate_y = -@as(f64, @floatFromInt(geometry.scroll_top)),
        });
        if (geometry.scrollbar) try buildScrollbar(doc, root, geometry, theme);
        return .{ .containerDomNode = root, .contentsDomNode = contents };
    }

    fn buildScrollbar(doc: *ui.Document, root: *ui.Node, geometry: Geometry, theme: Theme) !void {
        const track_height = geometry.visible_rows;
        if (track_height == 0) return;
        const thumb_height = @max(@as(usize, 1), track_height * track_height / @max(track_height, geometry.content_rows));
        const thumb_top = geometry.scroll_top * (track_height - thumb_height) / @max(1, geometry.content_rows -| track_height);
        for (0..track_height) |row| {
            const cell = try doc.createElement(.div);
            _ = try root.appendChild(cell);
            cell.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = @floatFromInt(geometry.content_width) },
                .top = .{ .cells = @floatFromInt(row) },
                .width = .{ .cells = 1 },
                .height = .{ .cells = 1 },
                .white_space = .pre,
            });
            const is_thumb = row >= thumb_top and row < thumb_top + thumb_height;
            const label = try doc.createText(if (is_thumb) "█" else "│");
            label.setStyle(.{ .color = if (is_thumb) theme.scrollbar_thumb else theme.scrollbar });
            _ = try cell.appendChild(label);
        }
    }
};
