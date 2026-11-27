// Replays Vim cassettes recorded from Neovim.
//
// The cassettes live in `test/data/oracle`; see `scripts/oracle/README.md`.
const std = @import("std");
const oracle = @import("../../../../test/common/oracleCassette.zig");
const cassettes = @import("./vimCassettes.generated.zig");
const Harness = @import("./vimTestHarness.zig").Harness;
const Mode = @import("../../browser/vimEngine.zig").Mode;
const Position = @import("../../../../common/core/position.zig").Position;

test "Vim cassette: reference corpus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    if (cassettes.files.len == 0) {
        std.debug.print("\nno embedded cassettes; run scripts/oracle/generate_cassette_index.py\n", .{});
        return error.SkipZigTest;
    }

    var ran: usize = 0;
    var failures: usize = 0;
    for (cassettes.files) |file| {
        const item = oracle.parseCase(arena.allocator(), file.name, file.data) catch |err| {
            std.debug.print("cassette {s}: parse failed: {s}\n", .{ file.name, @errorName(err) });
            return err;
        };
        const case = item.case;
        if (!std.mem.eql(u8, case.engine, "vim")) {
            std.debug.print("cassette {s}: expected engine \"vim\", found \"{s}\"\n", .{ item.name, case.engine });
            return error.InvalidCassette;
        }
        if (!std.mem.eql(u8, case.reference, "neovim")) {
            std.debug.print("cassette {s}: expected reference \"neovim\", found \"{s}\"\n", .{ item.name, case.reference });
            return error.InvalidCassette;
        }
        if (case.states.len == 0) {
            std.debug.print("CASSETTE_FAILED {s} {s}: no recorded state\n", .{ "Vim", case.case });
            failures += 1;
            continue;
        }
        ran += 1;
        runCase(case) catch |err| {
            std.debug.print("CASSETTE_FAILED {s} {s}: {s}\n", .{ "Vim", case.case, @errorName(err) });
            failures += 1;
            continue;
        };
    }
    if (failures > 0) {
        std.debug.print("\n{d} cassette failures ({s} lane, {d} run)\n", .{ failures, "Vim", ran });
        return error.CassetteFailures;
    }
    if (ran == 0) {
        std.debug.print("\nVim cassette: cassettes have no recorded states.\n", .{});
        return error.SkipZigTest;
    }
}

fn runCase(case: oracle.Case) !void {
    // Reproduce the reference recorder's seed protocol: Neovim starts from its
    // default one-line buffer, writes the seed through the API, and feeds the
    // whole key list as one `:normal!` batch. The seed change therefore stays
    // in the same undo block as the replayed commands, and the batch stops at
    // the first failed motion (`j`/`k` past the buffer edge).
    const harness = try Harness.initWithWidth(std.testing.allocator, "", case.width);
    defer harness.deinit();

    harness.editor.beginUndoGroup();
    try harness.editor.replaceRange(harness.editor.model.getFullModelRange(), case.seed.text);
    try harness.editor.setCursorPosition(Position.init(case.seed.cursor[0], case.seed.cursor[1]));

    for (case.keys) |token| {
        const event = oracle.keyEvent(token) catch |err| {
            printContext(case, null, "invalid key token");
            return err;
        };
        harness.sendEvent(event) catch |err| {
            printContext(case, null, "key handling failed");
            return err;
        };
        if (harness.engine.motion_failed) break;
    }

    const state = case.states[case.states.len - 1];
    const expected_mode = vimMode(state.mode) catch {
        printContext(case, null, "unsupported recorded mode");
        return error.UnsupportedCassetteMode;
    };

    const actual_text = try harness.value();
    defer std.testing.allocator.free(actual_text);
    const actual_cursor = harness.cursor();
    const actual_mode = harness.mode();

    if (!std.mem.eql(u8, actual_text, state.text) or
        actual_cursor.lineNumber != state.cursor[0] or
        actual_cursor.column != state.cursor[1] or
        actual_mode != expected_mode)
    {
        std.debug.print(
            \\
            \\Vim cassette mismatch: {s}
            \\  reference: {s}
            \\  seed: {s}
            \\  expected: text={s} cursor={d}:{d} mode={s}
            \\  actual:   text={s} cursor={d}:{d} mode={s}
            \\
        , .{
            case.case,
            case.reference_version,
            case.seed.text,
            state.text,
            state.cursor[0],
            state.cursor[1],
            state.mode,
            actual_text,
            actual_cursor.lineNumber,
            actual_cursor.column,
            @tagName(actual_mode),
        });
        std.debug.print("  keys:", .{});
        for (case.keys) |token| std.debug.print(" {s}", .{token});
        std.debug.print("\n", .{});
        return error.CassetteMismatch;
    }
}

fn vimMode(name: []const u8) !Mode {
    if (std.mem.eql(u8, name, "normal")) return .normal;
    if (std.mem.eql(u8, name, "insert")) return .insert;
    if (std.mem.eql(u8, name, "replace")) return .replace;
    return error.UnsupportedCassetteMode;
}

fn printContext(case: oracle.Case, state: ?oracle.State, message: []const u8) void {
    std.debug.print(
        "Vim cassette {s}: {s} (reference {s}, seed {s})\n",
        .{ case.case, message, case.reference_version, case.seed.text },
    );
    std.debug.print("  keys:", .{});
    for (case.keys) |token| std.debug.print(" {s}", .{token});
    std.debug.print("\n", .{});
    if (state) |s| {
        std.debug.print("  recorded state: text={s} cursor={d}:{d}\n", .{ s.text, s.cursor[0], s.cursor[1] });
    }
}
