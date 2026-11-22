// Port of selected cases from
// `src/vs/editor/test/common/model/annotations.test.ts`.
//
// Visual notation: `[id:text]` marks/sets an annotation, `<id:text>` deletes
// one in an update. IDs are ASCII strings duplicated for the test lifetime.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const annotations_mod = @import("../../../common/model/tokens/annotations.zig");
const AnnotatedString = annotations_mod.AnnotatedString([]const u8);
const AnnotationsUpdate = annotations_mod.AnnotationsUpdate([]const u8);
const OffsetRange = @import("../../../common/core/ranges/offsetRange.zig").OffsetRange;
const string_edit = @import("../../../common/core/edits/stringEdit.zig");
const StringEdit = string_edit.StringEdit;

const Visual = struct {
    allocator: Allocator,
    annotated: AnnotatedString,
    base: ArrayList(u8),
    ids: ArrayList([]u8),

    fn init(allocator: Allocator) Visual {
        return .{
            .allocator = allocator,
            .annotated = AnnotatedString.init(allocator),
            .base = ArrayList(u8).init(allocator),
            .ids = ArrayList([]u8).init(allocator),
        };
    }

    fn deinit(self: *Visual) void {
        self.annotated.deinit();
        self.base.deinit();
        for (self.ids.items) |id| self.allocator.free(id);
        self.ids.deinit();
    }

    fn ownId(self: *Visual, text: []const u8) ![]const u8 {
        const id = try self.allocator.dupe(u8, text);
        try self.ids.append(id);
        return id;
    }
};

fn parseVisual(allocator: Allocator, visual: []const u8) !struct { annotations: ArrayList(AnnotatedString.IAnnotationUpdate), base: ArrayList(u8), ids: ArrayList([]u8) } {
    var list = ArrayList(AnnotatedString.IAnnotationUpdate).init(allocator);
    errdefer list.deinit();
    var base = ArrayList(u8).init(allocator);
    errdefer base.deinit();
    var ids = ArrayList([]u8).init(allocator);
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit();
    }

    var i: usize = 0;
    while (i < visual.len) {
        if (visual[i] == '[') {
            const colon = std.mem.indexOfScalarPos(u8, visual, i + 1, ':') orelse return error.InvalidVisual;
            const close = std.mem.indexOfScalarPos(u8, visual, colon + 1, ']') orelse return error.InvalidVisual;
            const id = try allocator.dupe(u8, visual[i + 1 .. colon]);
            try ids.append(id);
            const start = base.items.len;
            try base.appendSlice(visual[colon + 1 .. close]);
            try list.append(.{ .range = OffsetRange.init(start, base.items.len), .annotation = id });
            i = close + 1;
        } else {
            try base.append(visual[i]);
            i += 1;
        }
    }
    return .{ .annotations = list, .base = base, .ids = ids };
}

fn fromVisual(allocator: Allocator, visual: []const u8) !Visual {
    var parsed = try parseVisual(allocator, visual);
    var result = Visual.init(allocator);
    errdefer result.deinit();
    try result.annotated.setAnnotations(parsed.annotations.items);
    parsed.annotations.deinit();
    result.ids = parsed.ids;
    result.base = parsed.base;
    parsed.ids = ArrayList([]u8).init(allocator);
    parsed.base = ArrayList(u8).init(allocator);
    return result;
}

fn toVisual(allocator: Allocator, view: *Visual) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();
    const annotations = try view.annotated.getAllAnnotations();
    defer allocator.free(annotations);
    var pos: usize = 0;
    for (annotations) |annotation| {
        try result.appendSlice(view.base.items[pos..annotation.range.start]);
        try result.append('[');
        try result.appendSlice(annotation.annotation);
        try result.append(':');
        try result.appendSlice(view.base.items[annotation.range.start..annotation.range.endExclusive]);
        try result.append(']');
        pos = annotation.range.endExclusive;
    }
    try result.appendSlice(view.base.items[pos..]);
    return result.toOwnedSlice();
}

fn assertVisual(allocator: Allocator, view: *Visual, expected_visual: []const u8) !void {
    const actual = try toVisual(allocator, view);
    defer allocator.free(actual);
    const expected = try parseVisual(allocator, expected_visual);
    defer {
        expected.annotations.deinit();
        expected.base.deinit();
        for (expected.ids.items) |id| allocator.free(id);
        expected.ids.deinit();
    }
    try std.testing.expectEqualStrings(expected_visual, actual);

    const actual_annotations = try view.annotated.getAllAnnotations();
    defer allocator.free(actual_annotations);
    try std.testing.expectEqual(expected.annotations.items.len, actual_annotations.len);
    for (expected.annotations.items, actual_annotations) |want, got| {
        try std.testing.expectEqualDeep(want.range, got.range);
        try std.testing.expectEqualStrings(want.annotation.?, got.annotation);
    }
}

fn updateFromVisual(allocator: Allocator, visual: []const u8) !struct { update: AnnotationsUpdate, ids: ArrayList([]u8) } {
    var updates = ArrayList(AnnotatedString.IAnnotationUpdate).init(allocator);
    defer updates.deinit();
    var ids = ArrayList([]u8).init(allocator);
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit();
    }
    var text = ArrayList(u8).init(allocator);
    defer text.deinit();

    var i: usize = 0;
    while (i < visual.len) {
        const is_set = visual[i] == '[';
        const is_delete = visual[i] == '<';
        if (is_set or is_delete) {
            const colon = std.mem.indexOfScalarPos(u8, visual, i + 1, ':') orelse return error.InvalidVisual;
            const close_char: u8 = if (is_set) ']' else '>';
            const close = std.mem.indexOfScalarPos(u8, visual, colon + 1, close_char) orelse return error.InvalidVisual;
            const id = try allocator.dupe(u8, visual[i + 1 .. colon]);
            try ids.append(id);
            const start = text.items.len;
            try text.appendSlice(visual[colon + 1 .. close]);
            try updates.append(.{
                .range = OffsetRange.init(start, text.items.len),
                .annotation = if (is_set) id else null,
            });
            i = close + 1;
        } else {
            try text.append(visual[i]);
            i += 1;
        }
    }
    return .{ .update = try AnnotationsUpdate.create(allocator, updates.items), .ids = ids };
}

fn applyVisualUpdate(allocator: Allocator, view: *Visual, visual: []const u8) !void {
    var parsed = try updateFromVisual(allocator, visual);
    defer {
        parsed.update.deinit();
        for (parsed.ids.items) |id| allocator.free(id);
        parsed.ids.deinit();
    }
    try view.annotated.setAnnotations(parsed.update.annotations());
    for (parsed.ids.items) |id| try view.ids.append(id);
    parsed.ids.clearRetainingCapacity();
}

fn applyEditToView(allocator: Allocator, view: *Visual, edit: *const StringEdit) !void {
    const deleted = try view.annotated.applyEdit(edit);
    allocator.free(deleted);
    const new_base = try string_edit.apply(edit, allocator, view.base.items);
    view.base.deinit();
    view.base = ArrayList(u8).fromOwnedSlice(allocator, new_base);
}

test "annotations: setAnnotations 1" {
    const allocator = std.testing.allocator;
    var view = try fromVisual(allocator, "[1:Lorem] ipsum [2:dolor] sit [3:amet]");
    defer view.deinit();
    try applyVisualUpdate(allocator, &view, "[4:Lorem i]");
    try assertVisual(allocator, &view, "[4:Lorem i]psum [2:dolor] sit [3:amet]");
    try applyVisualUpdate(allocator, &view, "Lorem ip[5:s]");
    try assertVisual(allocator, &view, "[4:Lorem i]p[5:s]um [2:dolor] sit [3:amet]");
}

test "annotations: setAnnotations 2" {
    const allocator = std.testing.allocator;
    var view = try fromVisual(allocator, "[1:Lorem] ipsum [2:dolor] sit [3:amet]");
    defer view.deinit();
    try applyVisualUpdate(allocator, &view, "L<_:orem ipsum d>");
    try applyVisualUpdate(allocator, &view, "[4:Lorem ]");
    try assertVisual(allocator, &view, "[4:Lorem ]ipsum dolor sit [3:amet]");
    try applyVisualUpdate(allocator, &view, "Lorem <_:ipsum dolor sit amet>");
    try applyVisualUpdate(allocator, &view, "[5:Lor]");
    try assertVisual(allocator, &view, "[5:Lor]em ipsum dolor sit amet");
}

test "annotations: setAnnotations 3" {
    const allocator = std.testing.allocator;
    var view = try fromVisual(allocator, "[1:Lorem] ipsum [2:dolor] sit [3:amet]");
    defer view.deinit();
    try applyVisualUpdate(allocator, &view, "Lore[4:m ipsum dolor ]");
    try assertVisual(allocator, &view, "Lore[4:m ipsum dolor ]sit [3:amet]");
    try applyVisualUpdate(allocator, &view, "Lorem ipsum dolor sit [5:a]");
    try assertVisual(allocator, &view, "Lore[4:m ipsum dolor ]sit [5:a]met");
}

test "annotations: getAnnotationsIntersecting" {
    const allocator = std.testing.allocator;
    var view = try fromVisual(allocator, "[1:Lorem] ipsum [2:dolor] sit [3:amet]");
    defer view.deinit();
    const first = try view.annotated.getAnnotationsIntersecting(OffsetRange.init(0, 13));
    defer allocator.free(first);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectEqualStrings("1", first[0].annotation);
    try std.testing.expectEqualStrings("2", first[1].annotation);

    const second = try view.annotated.getAnnotationsIntersecting(OffsetRange.init(0, 22));
    defer allocator.free(second);
    try std.testing.expectEqual(@as(usize, 3), second.len);
    try std.testing.expectEqualStrings("3", second[2].annotation);
}

test "annotations: applyEdit deletion and insertion" {
    const allocator = std.testing.allocator;
    {
        var view = try fromVisual(allocator, "[1:Lorem] ipsum [2:dolor] sit [3:amet]");
        defer view.deinit();
        var edit = try string_edit.replace(allocator, OffsetRange.init(0, 3), "");
        defer edit.deinit();
        try applyEditToView(allocator, &view, &edit);
        try assertVisual(allocator, &view, "[1:em] ipsum [2:dolor] sit [3:amet]");
    }
    {
        var view = try fromVisual(allocator, "[1:Lorem] ipsum [2:dolor] sit [3:amet]");
        defer view.deinit();
        var edit = try string_edit.replace(allocator, OffsetRange.init(1, 3), "XXXXX");
        defer edit.deinit();
        try applyEditToView(allocator, &view, &edit);
        try assertVisual(allocator, &view, "[1:LXXXXXem] ipsum [2:dolor] sit [3:amet]");
    }
}

test "annotations: applyEdit across/covering annotations" {
    const allocator = std.testing.allocator;
    {
        var view = try fromVisual(allocator, "[1:Lorem] ipsum [2:dolor] sit [3:amet]");
        defer view.deinit();
        var edit = try string_edit.replace(allocator, OffsetRange.init(0, 5), "");
        defer edit.deinit();
        try applyEditToView(allocator, &view, &edit);
        try assertVisual(allocator, &view, " ipsum [2:dolor] sit [3:amet]");
    }
    {
        var view = try fromVisual(allocator, "[1:Lorem] ipsum [2:dolor] sit [3:amet]");
        defer view.deinit();
        var edit = try string_edit.replace(allocator, OffsetRange.init(4, 22), "XXXXX");
        defer edit.deinit();
        try applyEditToView(allocator, &view, &edit);
        try assertVisual(allocator, &view, "[1:LoreXXXXX][3:amet]");
    }
}

test "annotations: applyEdit insertion positions" {
    const allocator = std.testing.allocator;
    {
        var view = try fromVisual(allocator, "[1:Lorem] ipsum [2:dolor] sit [3:amet]");
        defer view.deinit();
        var edit = try string_edit.replace(allocator, OffsetRange.init(17, 17), "XXX");
        defer edit.deinit();
        try applyEditToView(allocator, &view, &edit);
        try assertVisual(allocator, &view, "[1:Lorem] ipsum [2:dolor]XXX sit [3:amet]");
    }
    {
        var view = try fromVisual(allocator, "[1:Lorem] ipsum [2:dolor] sit [3:amet]");
        defer view.deinit();
        var edit = try string_edit.replace(allocator, OffsetRange.init(14, 14), "XXX");
        defer edit.deinit();
        try applyEditToView(allocator, &view, &edit);
        try assertVisual(allocator, &view, "[1:Lorem] ipsum [2:doXXXlor] sit [3:amet]");
    }
}

test "annotations: rebase" {
    const allocator = std.testing.allocator;
    var a = try fromVisual(allocator, "si[1:tam]et");
    defer a.deinit();
    var b = try fromVisual(allocator, "si[1:tam]et");
    defer b.deinit();

    const id2 = try allocator.dupe(u8, "2");
    defer allocator.free(id2);
    var updates = [_]AnnotatedString.IAnnotationUpdate{
        .{ .range = OffsetRange.init(4, 5), .annotation = id2 },
    };
    var update = try AnnotationsUpdate.create(allocator, &updates);
    defer update.deinit();
    try b.annotated.setAnnotations(update.annotations());

    var edit = try string_edit.replace(allocator, OffsetRange.init(1, 6), "XXX");
    defer edit.deinit();
    try applyEditToView(allocator, &a, &edit);
    try applyEditToView(allocator, &b, &edit);
    try update.rebase(&edit);

    try a.annotated.setAnnotations(update.annotations());
    const a_annotations = try a.annotated.getAllAnnotations();
    defer allocator.free(a_annotations);
    const b_annotations = try b.annotated.getAllAnnotations();
    defer allocator.free(b_annotations);
    try std.testing.expectEqual(a_annotations.len, b_annotations.len);
    for (a_annotations, b_annotations) |left, right| {
        try std.testing.expectEqualDeep(left.range, right.range);
        try std.testing.expectEqualStrings(left.annotation, right.annotation);
    }
}
