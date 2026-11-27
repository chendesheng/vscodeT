// Reference cassette format for the native Vim and Helix engines.
//
// A cassette is one JSON file describing a seed document, a key sequence and
// the states recorded from a reference implementation. The replay tests in
// `src/vs/editor/contrib/{vim,helix}/test/browser` execute the same seed and
// keys against the native engines and compare the recorded states.
//
// This is a test helper, not a port of an upstream file.

const std = @import("std");
const ui = @import("ui");

pub const schema_version: u32 = 1;

pub const Cursor = [2]usize; // [1-based line, 1-based UTF-8 byte column]

pub const Seed = struct {
    text: []const u8,
    /// Primary/only cursor. Multi-cursor seeds additionally list all cursor
    /// positions in `cursors`.
    cursor: Cursor,
    cursors: ?[]Cursor = null,
};

pub const State = struct {
    text: []const u8,
    cursor: Cursor,
    mode: []const u8,
    selection_count: ?usize = null,
    /// All selection/cursor positions, when the reference recorder emits them.
    cursors: ?[]Cursor = null,
};

pub const Case = struct {
    schema: u32,
    engine: []const u8,
    reference: []const u8,
    reference_version: []const u8,
    case: []const u8,
    width: usize = 60,
    seed: Seed,
    keys: []const []const u8,
    states: []const State,
};

pub const Loaded = struct {
    name: []const u8,
    case: Case,
};

pub const LoadError = error{
    EmptyCassetteDirectory,
    UnsupportedSchema,
    InvalidCassette,
};

/// Loads every `*.json` cassette in `dir_path`, sorted by filename.
///
/// All returned memory is allocated from `allocator`; callers normally pass an
/// arena allocator and release it after the test.
pub fn load(allocator: std.mem.Allocator, dir_path: []const u8) ![]Loaded {
    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.fs.openDirAbsolute(dir_path, .{ .iterate = true })
    else
        try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var names = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit();
    }
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(try allocator.dupe(u8, entry.name));
    }
    if (names.items.len == 0) return LoadError.EmptyCassetteDirectory;
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var result = std.array_list.Managed(Loaded).init(allocator);
    errdefer result.deinit();
    for (names.items) |name| {
        const bytes = try dir.readFileAlloc(allocator, name, 1 << 22);
        defer allocator.free(bytes);
        try result.append(try parseCase(allocator, name, bytes));
    }
    return result.toOwnedSlice();
}

/// Parses one cassette by name. The returned memory is owned by `allocator`.
pub fn parseCase(allocator: std.mem.Allocator, name: []const u8, bytes: []const u8) !Loaded {
    const case = std.json.parseFromSliceLeaky(Case, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return LoadError.InvalidCassette;
    if (case.schema != schema_version) return LoadError.UnsupportedSchema;
    if (case.keys.len == 0) return LoadError.InvalidCassette;
    return .{
        .name = try allocator.dupe(u8, name),
        .case = case,
    };
}

/// Converts one cassette key token into a UI key event.
///
/// A token is a single UTF-8 scalar or one of the bracketed names documented
/// in `scripts/oracle/README.md` (`<Esc>`, `<CR>`, `<C-x>`, `<A-x>`, ...).
pub fn keyEvent(token: []const u8) !ui.KeyEvent {
    if (token.len == 0) return error.EmptyKeyToken;
    if (token.len >= 3 and token[0] == '<' and token[token.len - 1] == '>') {
        const inner = token[1 .. token.len - 1];
        if (std.mem.eql(u8, inner, "Esc") or std.mem.eql(u8, inner, "Escape")) return .{ .key = .escape };
        if (std.mem.eql(u8, inner, "CR") or std.mem.eql(u8, inner, "Enter")) return .{ .key = .enter };
        if (std.mem.eql(u8, inner, "Tab")) return .{ .key = .tab };
        if (std.mem.eql(u8, inner, "BS") or std.mem.eql(u8, inner, "Backspace")) return .{ .key = .backspace };
        if (std.mem.eql(u8, inner, "Del") or std.mem.eql(u8, inner, "Delete")) return .{ .key = .delete };
        if (std.mem.eql(u8, inner, "Space")) return .{ .key = .{ .char = ' ' } };
        if (std.mem.eql(u8, inner, "Up")) return .{ .key = .up };
        if (std.mem.eql(u8, inner, "Down")) return .{ .key = .down };
        if (std.mem.eql(u8, inner, "Left")) return .{ .key = .left };
        if (std.mem.eql(u8, inner, "Right")) return .{ .key = .right };
        if (std.mem.eql(u8, inner, "Home")) return .{ .key = .home };
        if (std.mem.eql(u8, inner, "End")) return .{ .key = .end };
        if (std.mem.eql(u8, inner, "PageUp")) return .{ .key = .page_up };
        if (std.mem.eql(u8, inner, "PageDown")) return .{ .key = .page_down };
        if (std.mem.eql(u8, inner, "lt")) return .{ .key = .{ .char = '<' } };

        if (inner.len == 3 and (inner[0] == 'C' or inner[0] == 'A') and inner[1] == '-') {
            return .{
                .key = .{ .char = try singleScalar(inner[2..]) },
                .mods = .{
                    .ctrl = inner[0] == 'C',
                    .alt = inner[0] == 'A',
                },
            };
        }
        return error.UnknownKeyToken;
    }
    return .{ .key = .{ .char = try singleScalar(token) } };
}

fn singleScalar(token: []const u8) !u21 {
    const len = try std.unicode.utf8ByteSequenceLength(token[0]);
    if (len != token.len) return error.MultiCharacterKeyToken;
    return std.unicode.utf8Decode(token);
}

test "oracle cassette key tokens" {
    const expect = std.testing.expect;
    const event = try keyEvent("d");
    try expect(event.key == .char and event.key.char == 'd');
    try expect(!event.mods.ctrl and !event.mods.alt);

    const escape = try keyEvent("<Esc>");
    try expect(escape.key == .escape);

    const ctrl = try keyEvent("<C-r>");
    try expect(ctrl.key == .char and ctrl.key.char == 'r' and ctrl.mods.ctrl);

    const alt = try keyEvent("<A-x>");
    try expect(alt.key == .char and alt.key.char == 'x' and alt.mods.alt);

    const space = try keyEvent("<Space>");
    try expect(space.key == .char and space.key.char == ' ');

    const lt = try keyEvent("<lt>");
    try expect(lt.key == .char and lt.key.char == '<');

    try std.testing.expectError(error.UnknownKeyToken, keyEvent("<Nope>"));
    try std.testing.expectError(error.MultiCharacterKeyToken, keyEvent("ab"));
    try std.testing.expectError(error.EmptyKeyToken, keyEvent(""));
}

test "oracle cassette parses a case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const loaded = try parseCase(arena.allocator(), "normal_dw.json",
        \\{
        \\  "schema": 1,
        \\  "engine": "vim",
        \\  "reference": "neovim",
        \\  "reference_version": "test",
        \\  "case": "normal_dw",
        \\  "seed": { "text": "one two\n", "cursor": [1, 1] },
        \\  "keys": ["d", "w"],
        \\  "states": [{ "text": "two\n", "cursor": [1, 1], "mode": "normal" }]
        \\}
    );
    try std.testing.expectEqualStrings("normal_dw.json", loaded.name);
    try std.testing.expectEqualStrings("vim", loaded.case.engine);
    try std.testing.expectEqualStrings("dw", try std.mem.concat(arena.allocator(), u8, loaded.case.keys));
    try std.testing.expectEqual(@as(usize, 1), loaded.case.states.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.case.states[0].cursor[0]);
}
