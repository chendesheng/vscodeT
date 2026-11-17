// Port of `src/vs/workbench/test/browser/parts/statusbar/statusbarModel.test.ts`.
//
// Adapted to the terminal model: entries carry a stable handle and a
// StatusbarItem instead of DOM containers, and hidden state is in memory.

const std = @import("std");
const model_mod = @import("../../../../browser/parts/statusbar/statusbarModel.zig");
const statusbar = @import("../../../../services/statusbar/browser/statusbar.zig");
const StatusbarModel = model_mod.StatusbarModel;
const EntryHandle = model_mod.EntryHandle;
const StatusbarAlignment = statusbar.StatusbarAlignment;

fn addNumber(
    model: *StatusbarModel,
    id: []const u8,
    alignment: StatusbarAlignment,
    primary: f64,
    secondary: f64,
) !EntryHandle {
    return model.add(.{ .name = id, .text = id }, id, alignment, .{
        .primary = .{ .number = primary },
        .secondary = secondary,
    });
}

fn addRelative(
    model: *StatusbarModel,
    id: []const u8,
    alignment: StatusbarAlignment,
    reference: []const u8,
    reference_priority: f64,
    reference_alignment: StatusbarAlignment,
    secondary: f64,
) !EntryHandle {
    return model.add(.{ .name = id, .text = id }, id, alignment, .{
        .primary = .{ .location = .{
            .location = .{ .id = reference, .priority = reference_priority },
            .alignment = reference_alignment,
        } },
        .secondary = secondary,
    });
}

fn removeById(model: *StatusbarModel, id: []const u8) void {
    if (model.findHandle(id)) |handle| _ = model.remove(handle);
}

test "StatusbarModel: basics" {
    var model = StatusbarModel.init(std.testing.allocator);
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 0), model.entries().len);

    _ = try addNumber(&model, "3", .left, 3, 1);
    _ = try addNumber(&model, "2", .left, 2, 1);
    _ = try addNumber(&model, "1", .left, 1, 1);
    _ = try addNumber(&model, "1-right", .right, 1, 1);

    try std.testing.expectEqual(@as(usize, 4), model.entries().len);
    const left = try model.getEntries(std.testing.allocator, .left);
    defer std.testing.allocator.free(left);
    const right = try model.getEntries(std.testing.allocator, .right);
    defer std.testing.allocator.free(right);
    try std.testing.expectEqual(@as(usize, 3), left.len);
    try std.testing.expectEqual(@as(usize, 1), right.len);
    try std.testing.expectEqualStrings("3", left[0].id);
    try std.testing.expectEqualStrings("2", left[1].id);
    try std.testing.expectEqualStrings("1", left[2].id);
    try std.testing.expectEqualStrings("3", model.entries()[0].id);
    try std.testing.expectEqualStrings("1-right", model.entries()[3].id);
    try std.testing.expect(model.findEntry("3") != null);

    var changed = model_mod.VisibilityChange{ .id = "", .visible = false };
    try model.on_did_change_entry_visibility.event(&changed, struct {
        fn callback(event: model_mod.VisibilityChange, context: *model_mod.VisibilityChange) !void {
            context.* = event;
        }
    }.callback);

    try std.testing.expect(!model.isHidden("1"));
    model.hide("1");
    try std.testing.expectEqualStrings("1", changed.id);
    try std.testing.expect(!changed.visible);
    try std.testing.expect(model.isHidden("1"));

    changed = .{ .id = "", .visible = false };
    model.show("1");
    try std.testing.expectEqualStrings("1", changed.id);
    try std.testing.expect(changed.visible);
    try std.testing.expect(!model.isHidden("1"));

    removeById(&model, "3");
    removeById(&model, "1-right");
    try std.testing.expectEqual(@as(usize, 2), model.entries().len);
    removeById(&model, "2");
    removeById(&model, "1");
    try std.testing.expectEqual(@as(usize, 0), model.entries().len);
}

test "StatusbarModel: sorting with infinity and max number" {
    var model = StatusbarModel.init(std.testing.allocator);
    defer model.deinit();

    _ = try addNumber(&model, "3", .left, std.math.floatMax(f64), 1);
    _ = try addNumber(&model, "2", .left, std.math.floatMin(f64), 1);
    _ = try addNumber(&model, "1", .left, std.math.inf(f64), 1);
    _ = try addNumber(&model, "0", .left, -std.math.inf(f64), 1);
    _ = try addNumber(&model, "4", .left, 100, 1);

    const entries = model.entries();
    try std.testing.expectEqualStrings("1", entries[0].id);
    try std.testing.expectEqualStrings("3", entries[1].id);
    try std.testing.expectEqualStrings("4", entries[2].id);
    try std.testing.expectEqualStrings("2", entries[3].id);
    try std.testing.expectEqualStrings("0", entries[4].id);
}

test "StatusbarModel: secondary priority used when primary is same" {
    var model = StatusbarModel.init(std.testing.allocator);
    defer model.deinit();

    _ = try addNumber(&model, "1", .left, 1, 1);
    _ = try addNumber(&model, "2", .left, 1, 2);
    _ = try addNumber(&model, "3", .left, 1, 3);

    const entries = model.entries();
    try std.testing.expectEqualStrings("3", entries[0].id);
    try std.testing.expectEqualStrings("2", entries[1].id);
    try std.testing.expectEqualStrings("1", entries[2].id);
}

test "StatusbarModel: insertion order preserved when priorities are the same" {
    var model = StatusbarModel.init(std.testing.allocator);
    defer model.deinit();

    _ = try addNumber(&model, "1", .left, 1, 1);
    _ = try addNumber(&model, "2", .left, 1, 1);
    _ = try addNumber(&model, "3", .left, 1, 1);

    const entries = model.entries();
    try std.testing.expectEqualStrings("1", entries[0].id);
    try std.testing.expectEqualStrings("2", entries[1].id);
    try std.testing.expectEqualStrings("3", entries[2].id);
}

test "StatusbarModel: entry with reference to existing entry" {
    var model = StatusbarModel.init(std.testing.allocator);
    defer model.deinit();

    _ = try addNumber(&model, "a", .left, 2, 1);
    _ = try addNumber(&model, "b", .left, 1, 1);
    _ = try addRelative(&model, "c", .left, "a", 2, .left, 1);

    var entries = model.entries();
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("c", entries[0].id);
    try std.testing.expectEqualStrings("a", entries[1].id);
    try std.testing.expectEqualStrings("b", entries[2].id);

    removeById(&model, "c");
    _ = try addRelative(&model, "c", .right, "a", 2, .right, 1);
    entries = model.entries();
    try std.testing.expectEqualStrings("a", entries[0].id);
    try std.testing.expectEqualStrings("c", entries[1].id);
    try std.testing.expectEqualStrings("b", entries[2].id);
}

test "StatusbarModel: entry with reference to nonexistent entry" {
    var model = StatusbarModel.init(std.testing.allocator);
    defer model.deinit();

    _ = try addNumber(&model, "a", .left, 2, 1);
    _ = try addNumber(&model, "b", .left, 1, 1);
    _ = try addRelative(&model, "c", .left, "not-existing", 0, .left, 1);

    var entries = model.entries();
    try std.testing.expectEqualStrings("a", entries[0].id);
    try std.testing.expectEqualStrings("b", entries[1].id);
    try std.testing.expectEqualStrings("c", entries[2].id);

    removeById(&model, "c");
    _ = try addRelative(&model, "c", .left, "not-existing", 3, .left, 1);
    entries = model.entries();
    try std.testing.expectEqualStrings("c", entries[0].id);
    try std.testing.expectEqualStrings("a", entries[1].id);
    try std.testing.expectEqualStrings("b", entries[2].id);

    removeById(&model, "c");
    _ = try addRelative(&model, "c", .right, "not-existing", 3, .right, 1);
    entries = model.entries();
    try std.testing.expectEqualStrings("a", entries[0].id);
    try std.testing.expectEqualStrings("b", entries[1].id);
    try std.testing.expectEqualStrings("c", entries[2].id);
}

test "StatusbarModel: entry resorts when referenced entry appears or disappears" {
    var model = StatusbarModel.init(std.testing.allocator);
    defer model.deinit();

    _ = try addNumber(&model, "a", .left, 2, 1);
    _ = try addNumber(&model, "b", .left, 1, 1);
    _ = try addRelative(&model, "c", .left, "not-existing", 0, .left, 1);

    var entries = model.entries();
    try std.testing.expectEqualStrings("a", entries[0].id);
    try std.testing.expectEqualStrings("b", entries[1].id);
    try std.testing.expectEqualStrings("c", entries[2].id);

    _ = try addNumber(&model, "not-existing", .left, 3, 1);
    entries = model.entries();
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqualStrings("c", entries[0].id);
    try std.testing.expectEqualStrings("not-existing", entries[1].id);
    try std.testing.expectEqualStrings("a", entries[2].id);
    try std.testing.expectEqualStrings("b", entries[3].id);

    removeById(&model, "not-existing");
    entries = model.entries();
    try std.testing.expectEqualStrings("a", entries[0].id);
    try std.testing.expectEqualStrings("b", entries[1].id);
    try std.testing.expectEqualStrings("c", entries[2].id);
}

test "StatusbarModel: relative entry alignment does not explode" {
    var model = StatusbarModel.init(std.testing.allocator);
    defer model.deinit();

    _ = try addNumber(&model, "1-left", .left, 2, 1);
    _ = try addNumber(&model, "2-left", .left, 1, 1);
    _ = try addNumber(&model, "1-right", .right, 2, 1);
    _ = try addNumber(&model, "2-right", .right, 1, 1);

    {
        const left_before = try model.getEntries(std.testing.allocator, .left);
        defer std.testing.allocator.free(left_before);
        try std.testing.expectEqual(@as(usize, 2), left_before.len);
    }
    _ = try addRelative(&model, "relative", .left, "1-right", 2, .left, 1);

    {
        const left_after = try model.getEntries(std.testing.allocator, .left);
        defer std.testing.allocator.free(left_after);
        const right_after = try model.getEntries(std.testing.allocator, .right);
        defer std.testing.allocator.free(right_after);
        try std.testing.expectEqual(@as(usize, 3), left_after.len);
        try std.testing.expectEqualStrings("relative", left_after[2].id);
        try std.testing.expectEqual(@as(usize, 2), right_after.len);
    }

    removeById(&model, "relative");
    _ = try addRelative(&model, "relative", .right, "1-right", 2, .left, 1);
    const left_end = try model.getEntries(std.testing.allocator, .left);
    defer std.testing.allocator.free(left_end);
    const right_end = try model.getEntries(std.testing.allocator, .right);
    defer std.testing.allocator.free(right_end);
    try std.testing.expectEqual(@as(usize, 2), left_end.len);
    try std.testing.expectEqual(@as(usize, 3), right_end.len);
}

test "StatusbarModel: relative entries respect secondary sorting" {
    var model = StatusbarModel.init(std.testing.allocator);
    defer model.deinit();

    _ = try addNumber(&model, "ref", .left, 0, 0);
    _ = try addRelative(&model, "entry2", .right, "ref", 0, .right, 2);
    _ = try addRelative(&model, "entry1", .right, "ref", 0, .right, 1);
    _ = try addRelative(&model, "entry3", .right, "ref", 0, .right, 3);

    const entries = model.entries();
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqualStrings("ref", entries[0].id);
    try std.testing.expectEqualStrings("entry3", entries[1].id);
    try std.testing.expectEqualStrings("entry2", entries[2].id);
    try std.testing.expectEqualStrings("entry1", entries[3].id);
}

test "StatusbarModel: hidden and first/last visible flags" {
    var model = StatusbarModel.init(std.testing.allocator);
    defer model.deinit();

    _ = try addNumber(&model, "a", .left, 3, 1);
    _ = try addNumber(&model, "b", .left, 2, 1);
    _ = try addNumber(&model, "c", .right, 1, 1);
    try std.testing.expect(model.entries()[0].first_visible);
    try std.testing.expect(model.entries()[1].last_visible);

    model.hide("a");
    try std.testing.expect(!model.entries()[0].first_visible);
    try std.testing.expect(model.entries()[1].first_visible);
    try std.testing.expect(model.entries()[1].last_visible);

    model.show("a");
    try std.testing.expect(model.entries()[0].first_visible);
}
