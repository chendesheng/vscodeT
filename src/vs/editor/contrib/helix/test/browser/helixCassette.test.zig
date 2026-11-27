// Replays Helix cassettes recorded from the pinned Helix submodule.
//
// The cassettes live in `test/data/oracle`; see `scripts/oracle/README.md`.
const std = @import("std");
const oracle = @import("../../../../test/common/oracleCassette.zig");
const cassettes = @import("./helixCassettes.generated.zig");
const Harness = @import("./helixTestHarness.zig").Harness;
const Mode = @import("../../browser/helixEngine.zig").Mode;
const Position = @import("../../../../common/core/position.zig").Position;
const Selection = @import("../../../../common/core/selection.zig").Selection;

test "Helix cassette: reference corpus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    if (cassettes.files.len == 0) {
        std.debug.print("\nno embedded cassettes; run scripts/oracle/generate_cassette_index.py\n", .{});
        return error.SkipZigTest;
    }

    var ran: usize = 0;
    for (cassettes.files) |file| {
        const item = oracle.parseCase(arena.allocator(), file.name, file.data) catch |err| {
            std.debug.print("cassette {s}: parse failed: {s}\n", .{ file.name, @errorName(err) });
            return err;
        };
        const case = item.case;
        if (!std.mem.eql(u8, case.engine, "helix")) {
            std.debug.print("cassette {s}: expected engine \"helix\", found \"{s}\"\n", .{ item.name, case.engine });
            return error.InvalidCassette;
        }
        if (!std.mem.eql(u8, case.reference, "helix")) {
            std.debug.print("cassette {s}: expected reference \"helix\", found \"{s}\"\n", .{ item.name, case.reference });
            return error.InvalidCassette;
        }
        if (case.states.len == 0) continue;
        ran += 1;
        try runCase(case);
    }
    if (ran == 0) {
        std.debug.print("\nHelix cassette: cassettes have no recorded states.\n", .{});
        return error.SkipZigTest;
    }
}

fn runCase(case: oracle.Case) !void {
    const harness = try Harness.initWithWidth(std.testing.allocator, case.seed.text, case.width);
    defer harness.deinit();

    if (case.seed.cursors) |cursors| {
        const selections = try std.testing.allocator.alloc(Selection, cursors.len);
        defer std.testing.allocator.free(selections);
        for (cursors, 0..) |cursor, index| {
            selections[index] = Selection.init(cursor[0], cursor[1], cursor[0], cursor[1]);
        }
        try harness.editor.setSelections(selections);
    } else {
        try harness.editor.setCursorPosition(Position.init(case.seed.cursor[0], case.seed.cursor[1]));
    }

    for (case.keys) |token| {
        const event = oracle.keyEvent(token) catch |err| {
            printContext(case, "invalid key token");
            return err;
        };
        harness.sendEvent(event) catch |err| {
            printContext(case, "key handling failed");
            return err;
        };
    }

    const state = case.states[case.states.len - 1];
    const expected_mode = helixMode(state.mode) catch {
        printContext(case, "unsupported recorded mode");
        return error.UnsupportedCassetteMode;
    };

    const actual_text = try harness.value();
    defer std.testing.allocator.free(actual_text);
    const actual_cursor = harness.cursor();
    const actual_mode = harness.mode();
    const actual_count = try harness.selectionCount();
    const expected_count = state.selection_count orelse 1;
    var cursors_match = true;
    if (state.cursors) |expected_cursors| {
        const actual_cursors = try harness.cursors(std.testing.allocator);
        defer std.testing.allocator.free(actual_cursors);
        const expected_sorted = try std.testing.allocator.dupe(oracle.Cursor, expected_cursors);
        defer std.testing.allocator.free(expected_sorted);
        std.mem.sort(oracle.Cursor, expected_sorted, {}, cursorLessThan);
        const actual_sorted = try std.testing.allocator.dupe(Position, actual_cursors);
        defer std.testing.allocator.free(actual_sorted);
        std.mem.sort(Position, actual_sorted, {}, positionLessThan);
        if (expected_sorted.len != actual_sorted.len) {
            cursors_match = false;
        } else {
            for (expected_sorted, actual_sorted) |expected, actual| {
                if (expected[0] != actual.lineNumber or expected[1] != actual.column) {
                    cursors_match = false;
                    break;
                }
            }
        }
    }

    if (!std.mem.eql(u8, actual_text, state.text) or
        actual_cursor.lineNumber != state.cursor[0] or
        actual_cursor.column != state.cursor[1] or
        actual_mode != expected_mode or
        actual_count != expected_count or
        !cursors_match)
    {
        std.debug.print(
            \\
            \\Helix cassette mismatch: {s}
            \\  reference: {s}
            \\  seed: {s}
            \\  keys: {s}
            \\  expected: text={s} cursor={d}:{d} mode={s} selections={d} cursors={d}
            \\  actual:   text={s} cursor={d}:{d} mode={s} selections={d} cursors={d}
            \\
        , .{
            case.case,
            case.reference_version,
            case.seed.text,
            "<see cassette keys>",
            state.text,
            state.cursor[0],
            state.cursor[1],
            state.mode,
            expected_count,
            if (state.cursors) |c| c.len else 0,
            actual_text,
            actual_cursor.lineNumber,
            actual_cursor.column,
            @tagName(actual_mode),
            actual_count,
            actual_count,
        });
        return error.CassetteMismatch;
    }
}

fn helixMode(name: []const u8) !Mode {
    if (std.mem.eql(u8, name, "normal")) return .normal;
    if (std.mem.eql(u8, name, "select")) return .select;
    if (std.mem.eql(u8, name, "insert")) return .insert;
    return error.UnsupportedCassetteMode;
}

fn printContext(case: oracle.Case, message: []const u8) void {
    std.debug.print(
        "Helix cassette {s}: {s} (reference {s}, seed {s})\n",
        .{ case.case, message, case.reference_version, case.seed.text },
    );
    std.debug.print("  keys:", .{});
    for (case.keys) |token| std.debug.print(" {s}", .{token});
    std.debug.print("\n", .{});
}

fn cursorLessThan(_: void, a: oracle.Cursor, b: oracle.Cursor) bool {
    if (a[0] != b[0]) return a[0] < b[0];
    return a[1] < b[1];
}

fn positionLessThan(_: void, a: Position, b: Position) bool {
    if (a.lineNumber != b.lineNumber) return a.lineNumber < b.lineNumber;
    return a.column < b.column;
}
