const std = @import("std");
const ui = @import("ui");
const Color = ui.style.Color;
const Dimension = ui.style.Dimension;
const Pointer = ui.style.Pointer;
const Display = ui.style.Display;
const TextAlign = ui.style.TextAlign;
const Visibility = ui.style.Visibility;
const WhiteSpace = ui.style.WhiteSpace;
const Margin = ui.style.Margin;
const Gap = ui.style.Gap;
const Style = ui.style.Style;
const ComputedStyle = ui.style.ComputedStyle;
const Rect = ui.style.Rect;

test "Rect intersects and clamps" {
    const r = Rect.intersect(
        .{ .x = 0, .y = 0, .w = 10, .h = 5 },
        .{ .x = 5, .y = 3, .w = 10, .h = 5 },
    );
    try std.testing.expectEqual(@as(f64, 5), r.x);
    try std.testing.expectEqual(@as(f64, 3), r.y);
    try std.testing.expectEqual(@as(f64, 5), r.w);
    try std.testing.expectEqual(@as(f64, 2), r.h);
}

test "Margin and Gap helpers" {
    const margin = Margin.all(2);
    try std.testing.expectEqual(@as(f64, 4), margin.horizontal());
    try std.testing.expectEqual(@as(f64, 4), margin.vertical());
    try std.testing.expect(!margin.hasAuto());

    const auto_margin = Margin{ .left = .auto, .right = .auto };
    try std.testing.expect(auto_margin.hasAuto());
    try std.testing.expectEqual(@as(f64, 0), auto_margin.left.resolve());

    const gap = Gap.all(1);
    try std.testing.expectEqual(@as(f64, 1), gap.row);
    try std.testing.expectEqual(@as(f64, 1), gap.column);
}

test "Style.merge: later class wins and unset fields keep the base" {
    const base = Style{
        .color = .{ .r = 1, .g = 2, .b = 3 },
        .margin = .{ .left = .{ .cells = 2 } },
        .bold = true,
    };
    const over = Style{
        .color = .{ .r = 4, .g = 5, .b = 6 },
        .margin = .{ .top = .{ .cells = 1 } },
    };
    const merged = Style.merge(base, over);
    try std.testing.expect(merged.color.?.eql(.{ .r = 4, .g = 5, .b = 6 }));
    try std.testing.expectEqual(@as(f64, 2), merged.margin.?.left.?.resolve());
    try std.testing.expectEqual(@as(f64, 1), merged.margin.?.top.?.resolve());
    try std.testing.expectEqual(@as(?bool, true), merged.bold);
}

test "Style.resolve: inherited and initial values" {
    const parent = (Style{
        .text_align = .center,
        .visibility = .hidden,
        .white_space = .pre,
        .pointer = .pointer,
        .width = .{ .cells = 20 },
        .color = .{ .r = 9, .g = 8, .b = 7 },
    }).resolve(ComputedStyle.initial(.block), .block);

    const child = (Style{}).resolve(parent, .inline_);
    try std.testing.expectEqual(TextAlign.center, child.text_align);
    try std.testing.expectEqual(Visibility.hidden, child.visibility);
    try std.testing.expectEqual(WhiteSpace.pre, child.white_space);
    try std.testing.expectEqual(Pointer.pointer, child.pointer);
    // Non-inherited properties use their initial value.
    try std.testing.expectEqual(Dimension.auto, child.width);
    try std.testing.expectEqual(Display.inline_, child.display);
    // Paint stays a declaration for the painter.
    try std.testing.expectEqual(@as(?Color, null), child.color);

    const overridden = (Style{ .text_align = .left, .pointer = .default }).resolve(parent, .block);
    try std.testing.expectEqual(TextAlign.left, overridden.text_align);
    try std.testing.expectEqual(Pointer.default, overridden.pointer);
}

test "Style.resolve: per-side box declarations" {
    const child = (Style{
        .margin = .{ .left = .{ .cells = 2 } },
        .padding = .{ .top = 1 },
        .border = .{ .bottom = 3 },
        .gap = .{ .column = 4 },
    }).resolve(ComputedStyle.initial(.block), .block);
    try std.testing.expectEqual(@as(f64, 2), child.margin.left.resolve());
    try std.testing.expectEqual(@as(f64, 0), child.margin.top.resolve());
    try std.testing.expectEqual(@as(f64, 1), child.padding.top);
    try std.testing.expectEqual(@as(f64, 0), child.padding.left);
    try std.testing.expectEqual(@as(f64, 3), child.border.bottom);
    try std.testing.expectEqual(@as(f64, 4), child.gap.column);
    try std.testing.expectEqual(@as(f64, 0), child.gap.row);
}
