//! Unicode line breaking (UAX #14, rules LB1-LB31).
//!
//! Port of TermDOM's `src/internal/linebreak.ts` (MIT), which is the
//! terminal/CSS reference for this library. The algorithm runs over UTF-8
//! bytes and reports byte offsets, and the generated property tables live in
//! `linebreak_tables.zig`. It is deliberately table-driven: the text engine
//! must not fall back to splitting on spaces.
//!
//! The tables are a Zig port of the packed Unicode 17.0.0 data. The decoder
//! shape follows TermDOM so the two implementations can be compared case by
//! case. The packed data is decoded once at compile time; `LineBreakTables` is
//! a cheap view over those constants, so a layout pass no longer allocates and
//! re-parses every property range.

const std = @import("std");
const data = @import("linebreak_tables.zig");

pub const BK: u8 = 0;
pub const CR: u8 = 1;
pub const LF: u8 = 2;
pub const NL: u8 = 3;
pub const SP: u8 = 4;
pub const ZW: u8 = 5;
pub const ZWJ: u8 = 6;
pub const CM: u8 = 7;
pub const WJ: u8 = 8;
pub const GL: u8 = 9;
pub const CB: u8 = 10;
pub const CL: u8 = 11;
pub const CP: u8 = 12;
pub const EX: u8 = 13;
pub const SY: u8 = 14;
pub const OP: u8 = 15;
pub const QU: u8 = 16;
pub const QU_PI: u8 = 17;
pub const QU_PF: u8 = 18;
pub const IS: u8 = 19;
pub const NS: u8 = 20;
pub const B2: u8 = 21;
pub const BA: u8 = 22;
pub const HH: u8 = 23;
pub const HY: u8 = 24;
pub const BB: u8 = 25;
pub const IN: u8 = 26;
pub const NU: u8 = 27;
pub const PR: u8 = 28;
pub const PO: u8 = 29;
pub const AL: u8 = 30;
pub const HL: u8 = 31;
pub const ID: u8 = 32;
pub const EB: u8 = 33;
pub const EM: u8 = 34;
pub const JL: u8 = 35;
pub const JV: u8 = 36;
pub const JT: u8 = 37;
pub const H2: u8 = 38;
pub const H3: u8 = 39;
pub const RI: u8 = 40;
pub const AK: u8 = 41;
pub const AP: u8 = 42;
pub const AS: u8 = 43;
pub const VF: u8 = 44;
pub const VI: u8 = 45;
pub const SOT: u8 = 62;
pub const EOT: u8 = 63;

const CLASS: u8 = 63;
const WIDE: u8 = 64;
const PICTOGRAPHIC: u8 = 128;
const DOTTED_CIRCLE: u21 = 0x25cc;

const NONE: u8 = 0;
const BREAK: u8 = 1;
const REQUIRED: u8 = 2;

pub const Break = struct {
    /// Byte offset into the source text.
    position: usize,
    required: bool,
};

const run_count = data.linebreak_run_kinds.len;
const block_count = (@as(usize, 0x110000) >> 10) + 1;

const Tables = struct {
    run_starts: [run_count]u32,
    run_kinds: [run_count]u8,
    latin1: [256]u8,
    block_runs: [block_count]u16,
};

/// The packed Unicode property data decoded once at compile time. Building it
/// at runtime used to allocate three arrays and re-scan every kind name for
/// all 2,812 ranges on every layout pass.
const static_tables: Tables = buildTables();

fn buildTables() Tables {
    @setEvalBranchQuota(5_000_000);
    var result: Tables = undefined;

    var next: u32 = 0;
    var at: usize = 0;
    for (0..run_count) |i| {
        result.run_starts[i] = next;
        const letter = data.linebreak_run_kinds[i];
        const kind_index: usize = if (letter >= 'a')
            letter - 'a' + 26
        else if (letter >= 'A')
            letter - 'A'
        else
            letter - '0' + 52;
        result.run_kinds[i] = kindAt(kind_index);
        var length: u32 = 0;
        while (at < data.linebreak_run_lengths.len) : (at += 1) {
            const digit = data.linebreak_run_lengths[at];
            if (digit == ',') {
                at += 1;
                break;
            }
            length = length * 36 + base36(digit);
        }
        next += length;
    }
    std.debug.assert(at >= data.linebreak_run_lengths.len);
    std.debug.assert(next == 0x110000);

    var run: usize = 0;
    for (0..256) |code| {
        while (run + 1 < run_count and result.run_starts[run + 1] <= code) run += 1;
        result.latin1[code] = result.run_kinds[run];
    }

    run = 0;
    for (0..block_count) |block| {
        while (run + 1 < run_count and result.run_starts[run + 1] <= block << 10) run += 1;
        result.block_runs[block] = @intCast(run);
    }

    return result;
}

pub const LineBreakTables = struct {
    run_starts: []const u32,
    run_kinds: []const u8,
    latin1: *const [256]u8,
    block_runs: []const u16,

    /// Compatibility wrapper for the previous allocator-based constructor.
    /// The decoded tables are compile-time constants now.
    pub fn init(allocator: std.mem.Allocator) !LineBreakTables {
        _ = allocator;
        return value();
    }

    pub fn value() LineBreakTables {
        return .{
            .run_starts = &static_tables.run_starts,
            .run_kinds = &static_tables.run_kinds,
            .latin1 = &static_tables.latin1,
            .block_runs = &static_tables.block_runs,
        };
    }

    pub fn deinit(self: *LineBreakTables) void {
        _ = self;
    }

    pub fn kindOf(self: *const LineBreakTables, cp: u21) u8 {
        if (cp < 256) return self.latin1[cp];
        const starts = self.run_starts;
        const code: usize = cp;
        var low: usize = self.block_runs[code >> 10];
        var high: usize = self.block_runs[(code >> 10) + 1];
        while (low < high) {
            const mid = (low + high + 1) >> 1;
            if (starts[mid] <= code) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return self.run_kinds[low];
    }
};

fn base36(digit: u8) u32 {
    return if (digit >= 'a') digit - 'a' + 10 else if (digit >= '0' and digit <= '9')
        digit - '0'
    else
        @as(u32, 0);
}

fn kindAt(kind_index: usize) u8 {
    var index: usize = 0;
    var it = std.mem.splitScalar(u8, data.linebreak_kinds, ' ');
    while (it.next()) |token| {
        if (index != kind_index) {
            index += 1;
            continue;
        }
        var name = token;
        var flags: u8 = 0;
        if (std.mem.indexOfScalar(u8, token, '+')) |plus| {
            name = token[0..plus];
            if (std.mem.indexOfScalar(u8, token[plus + 1 ..], 'W') != null) flags |= WIDE;
            if (std.mem.indexOfScalar(u8, token[plus + 1 ..], 'P') != null) flags |= PICTOGRAPHIC;
        }
        return classValue(name) | flags;
    }
    return AL;
}

fn classValue(name: []const u8) u8 {
    const names = [_][]const u8{
        "BK", "CR", "LF", "NL", "SP", "ZW", "ZWJ", "CM",    "WJ",    "GL",
        "CB", "CL", "CP", "EX", "SY", "OP", "QU",  "QU_Pi", "QU_Pf", "IS",
        "NS", "B2", "BA", "HH", "HY", "BB", "IN",  "NU",    "PR",    "PO",
        "AL", "HL", "ID", "EB", "EM", "JL", "JV",  "JT",    "H2",    "H3",
        "RI", "AK", "AP", "AS", "VF", "VI",
    };
    for (names, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) return @intCast(index);
    }
    return AL;
}

const Decoded = struct {
    cp: u21,
    len: usize,
};

fn decodeAt(text: []const u8, at: usize) Decoded {
    if (at >= text.len) return .{ .cp = 0, .len = 0 };
    const length = std.unicode.utf8ByteSequenceLength(text[at]) catch return .{ .cp = 0xfffd, .len = 1 };
    if (at + length > text.len) return .{ .cp = 0xfffd, .len = 1 };
    const cp = std.unicode.utf8Decode(text[at .. at + length]) catch return .{ .cp = 0xfffd, .len = 1 };
    return .{ .cp = cp, .len = length };
}

fn isQuote(cls: u8) bool {
    return cls >= QU and cls <= QU_PF;
}

fn isHangul(cls: u8) bool {
    return cls >= JL and cls <= H3;
}

fn isHardBreak(cls: u8) bool {
    return cls <= NL;
}

const State = struct {
    prev: u8 = SOT,
    prev_code: u21 = 0,
    prev_zwj: bool = false,
    before: u8 = SOT,
    before_code: u21 = 0,
    base: u8 = SOT,
    base_before: u8 = SOT,
    regional: u16 = 0,
    numeric: bool = false,
    numeric_close: bool = false,
};

const Item = struct {
    kind: u8 = EOT,
    end: usize = 0,
};

fn peekItem(tables: *const LineBreakTables, text: []const u8, at: usize) Item {
    if (at >= text.len) return .{ .kind = EOT, .end = text.len };
    const first = decodeAt(text, at);
    var next = at + first.len;
    var kind = tables.kindOf(first.cp);
    const cls = kind & CLASS;
    if (cls == CM or cls == ZWJ) kind = AL;
    if (cls > ZW) {
        while (next < text.len) {
            const mark = decodeAt(text, next);
            const mark_cls = tables.kindOf(mark.cp) & CLASS;
            if (mark_cls != CM and mark_cls != ZWJ) break;
            next += mark.len;
        }
    }
    return .{ .kind = kind, .end = next };
}

fn advance(state: *State, kind: u8, code: u21, zwj: bool) void {
    const cls = kind & CLASS;
    if (cls != SP) {
        state.base = kind;
        state.base_before = state.prev;
    }
    state.regional = if (cls == RI) state.regional + 1 else 0;
    state.numeric_close = (cls == CL or cls == CP) and state.numeric;
    state.numeric = cls == NU or ((cls == SY or cls == IS) and state.numeric);
    state.before = state.prev;
    state.before_code = state.prev_code;
    state.prev = kind;
    state.prev_code = code;
    state.prev_zwj = zwj;
}

/// Calls `visit` for every line-break opportunity, in order, and for the end
/// of the text. Positions are UTF-8 byte offsets.
pub fn forEach(
    tables: *const LineBreakTables,
    text: []const u8,
    context: anytype,
    comptime visit: fn (@TypeOf(context), usize, bool) void,
) void {
    if (text.len == 0) return;
    var state = State{};
    var at: usize = 0;
    while (at < text.len) {
        const start = at;
        const decoded = decodeAt(text, at);
        var item = tables.kindOf(decoded.cp);
        var cls = item & CLASS;
        var zwj = cls == ZWJ;
        if (cls == CM or cls == ZWJ) {
            item = AL;
            cls = AL;
        }
        at += decoded.len;
        while (at < text.len) {
            const mark = decodeAt(text, at);
            const mark_kind = tables.kindOf(mark.cp);
            const mark_cls = mark_kind & CLASS;
            if (cls <= ZW or (mark_cls != CM and mark_cls != ZWJ)) break;
            zwj = mark_cls == ZWJ;
            at += mark.len;
        }
        if (start > 0) {
            const previous_class = state.prev & CLASS;
            if (!((previous_class == AL or previous_class == HL) and
                (cls == AL or cls == HL)))
            {
                const decision = decide(tables, &state, text, item, decoded.cp, at);
                if (decision != NONE) visit(context, start, decision == REQUIRED);
            }
        }
        advance(&state, item, decoded.cp, zwj);
    }
    visit(context, text.len, isHardBreak(state.prev & CLASS));
}

/// Appends every break opportunity, including the end, to `out`.
pub fn collect(
    allocator: std.mem.Allocator,
    tables: *const LineBreakTables,
    text: []const u8,
    out: *std.ArrayList(Break),
) std.mem.Allocator.Error!void {
    const Context = struct {
        allocator: std.mem.Allocator,
        out: *std.ArrayList(Break),
        err: ?std.mem.Allocator.Error = null,

        fn visit(self: *@This(), position: usize, required: bool) void {
            self.out.append(self.allocator, .{ .position = position, .required = required }) catch |err| {
                if (self.err == null) self.err = err;
            };
        }
    };
    var context = Context{ .allocator = allocator, .out = out };
    forEach(tables, text, &context, Context.visit);
    if (context.err) |err| return err;
}

fn decide(
    tables: *const LineBreakTables,
    state: *const State,
    text: []const u8,
    next: u8,
    next_code: u21,
    next_end: usize,
) u8 {
    const prev = state.prev;
    const pc = prev & CLASS;
    const nc = next & CLASS;

    // LB4, LB5
    if (pc == BK or pc == LF or pc == NL) return REQUIRED;
    if (pc == CR) return if (nc == LF) NONE else REQUIRED;
    // LB6, LB7
    if (isHardBreak(nc) or nc == SP or nc == ZW) return NONE;
    // LB8
    if ((state.base & CLASS) == ZW) return BREAK;
    // LB8a
    if (state.prev_zwj) return NONE;
    // LB11, LB12, LB12a
    if (nc == WJ or pc == WJ or pc == GL) return NONE;
    if (nc == GL and pc != SP and pc != BA and pc != HY and pc != HH) return NONE;
    // LB13, LB14
    if (nc == CL or nc == CP or nc == EX or nc == SY or (state.base & CLASS) == OP) return NONE;

    // LB15a
    if ((state.base & CLASS) == QU_PI) {
        const bb = state.base_before & CLASS;
        if (bb == SOT or isHardBreak(bb) or bb == OP or isQuote(bb) or
            bb == GL or bb == SP or bb == ZW) return NONE;
    }
    // LB15b
    if (nc == QU_PF) {
        const after = peekItem(tables, text, next_end).kind & CLASS;
        if (after == EOT or after <= ZW or after == GL or after == WJ or
            after == CL or after == CP or after == EX or after == IS or
            after == SY or isQuote(after)) return NONE;
    }
    // LB15c, LB15d
    if (nc == IS) {
        return if (pc == SP and (peekItem(tables, text, next_end).kind & CLASS) == NU)
            BREAK
        else
            NONE;
    }
    // LB16, LB17
    if ((state.base & CLASS) == CL or (state.base & CLASS) == CP) {
        if (nc == NS) return NONE;
    }
    if ((state.base & CLASS) == B2 and nc == B2) return NONE;
    // LB18
    if (pc == SP) return BREAK;
    // LB19
    if (nc == QU or nc == QU_PF or pc == QU or pc == QU_PI) return NONE;
    // LB19a
    if (isQuote(nc) and (!((prev & WIDE) != 0) or !((peekItem(tables, text, next_end).kind & WIDE) != 0))) {
        return NONE;
    }
    if (isQuote(pc) and (!((next & WIDE) != 0) or !((state.before & WIDE) != 0))) return NONE;
    // LB20
    if (nc == CB or pc == CB) return BREAK;
    if (pc == HY or pc == HH) {
        const b = state.before & CLASS;
        if ((nc == AL or nc == HL) and
            (b == SOT or isHardBreak(b) or b == SP or b == ZW or b == CB or b == GL))
        {
            return NONE;
        }
        if (b == HL and nc != HL) return NONE;
    }
    // LB21
    if (nc == BA or nc == HH or nc == HY or nc == NS or pc == BB) return NONE;
    // LB21b, LB22
    if ((pc == SY and nc == HL) or nc == IN) return NONE;
    // LB23, LB23a, LB24
    if (pc == AL or pc == HL) {
        if (nc == NU or nc == PR or nc == PO) return NONE;
    } else if (pc == PR or pc == PO) {
        if (nc == AL or nc == HL) return NONE;
    }
    if (pc == NU and (nc == AL or nc == HL)) return NONE;
    if (pc == PR and (nc == ID or nc == EB or nc == EM)) return NONE;
    if ((pc == ID or pc == EB or pc == EM) and nc == PO) return NONE;
    // LB25
    if (nc == PO or nc == PR) {
        if (state.numeric or state.numeric_close) return NONE;
    } else if (nc == NU) {
        if (state.numeric or pc == PO or pc == PR or pc == HY or pc == IS) return NONE;
    } else if (nc == OP and (pc == PO or pc == PR)) {
        const after = peekItem(tables, text, next_end);
        if ((after.kind & CLASS) == NU or
            ((after.kind & CLASS) == IS and (peekItem(tables, text, after.end).kind & CLASS) == NU))
        {
            return NONE;
        }
    }
    // LB26, LB27
    if (isHangul(pc)) {
        if (nc == PO or
            (pc == JL and (nc == JL or nc == JV or nc == H2 or nc == H3)) or
            ((pc == JV or pc == H2) and (nc == JV or nc == JT)) or
            ((pc == JT or pc == H3) and nc == JT))
        {
            return NONE;
        }
    } else if (pc == PR and isHangul(nc)) return NONE;
    // LB28a
    const prev_aksara = pc == AK or pc == AS or state.prev_code == DOTTED_CIRCLE;
    const next_aksara = nc == AK or nc == AS or next_code == DOTTED_CIRCLE;
    if (pc == AP and next_aksara) return NONE;
    if (prev_aksara and (nc == VF or nc == VI)) return NONE;
    if (pc == VI and nc != AS and next_aksara and
        ((state.before & CLASS) == AK or (state.before & CLASS) == AS or
            state.before_code == DOTTED_CIRCLE))
    {
        return NONE;
    }
    if (prev_aksara and next_aksara and
        (peekItem(tables, text, next_end).kind & CLASS) == VF)
    {
        return NONE;
    }
    // LB29
    if (pc == IS and (nc == AL or nc == HL)) return NONE;
    // LB30
    if ((pc == AL or pc == HL or pc == NU) and nc == OP and !((next & WIDE) != 0)) {
        return NONE;
    }
    if (pc == CP and !((prev & WIDE) != 0) and (nc == AL or nc == HL or nc == NU)) {
        return NONE;
    }
    // LB30a
    if (pc == RI and nc == RI and state.regional % 2 == 1) return NONE;
    // LB30b
    if (nc == EM and (pc == EB or (prev & PICTOGRAPHIC) != 0)) return NONE;
    return BREAK;
}

test "linebreak: hard line breaks are required, at the end too" {
    var tables = try LineBreakTables.init(std.testing.allocator);
    defer tables.deinit();
    var out: std.ArrayList(Break) = .empty;
    defer out.deinit(std.testing.allocator);
    try collect(std.testing.allocator, &tables, "a b\nc\r\n", &out);
    var found_buf: [64]u8 = undefined;
    var found_len: usize = 0;
    for (out.items) |item| {
        const part = try std.fmt.bufPrint(found_buf[found_len..], "{d}{s}", .{
            item.position,
            if (item.required) "!" else "",
        });
        found_len += part.len;
    }
    try std.testing.expectEqualStrings("24!7!", found_buf[0..found_len]);
}

test "linebreak: Unicode conformance subset" {
    const fixture = @embedFile("testdata/linebreak-test.txt");
    const allocator = std.testing.allocator;
    var tables = try LineBreakTables.init(allocator);
    defer tables.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var expected: std.ArrayList(usize) = .empty;
    defer expected.deinit(allocator);
    var actual: std.ArrayList(Break) = .empty;
    defer actual.deinit(allocator);

    var passed: usize = 0;
    var line_it = std.mem.splitScalar(u8, fixture, '\n');
    while (line_it.next()) |raw_line| {
        const comment = std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len;
        const line = std.mem.trim(u8, raw_line[0..comment], " \t\r");
        if (line.len == 0) continue;

        text.clearRetainingCapacity();
        expected.clearRetainingCapacity();
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷")) {
                expected.append(allocator, text.items.len) catch unreachable;
            } else if (!std.mem.eql(u8, token, "×")) {
                const cp = std.fmt.parseInt(u21, token, 16) catch unreachable;
                var buffer: [4]u8 = undefined;
                const encoded = std.unicode.utf8Encode(cp, &buffer) catch unreachable;
                text.appendSlice(allocator, buffer[0..encoded]) catch unreachable;
            }
        }

        actual.clearRetainingCapacity();
        collect(allocator, &tables, text.items, &actual) catch unreachable;

        var same = actual.items.len == expected.items.len;
        if (same) {
            for (actual.items, expected.items) |got, want| {
                if (got.position != want) {
                    same = false;
                    break;
                }
            }
        }
        if (!same) {
            std.debug.print("linebreak conformance failed: {s}\n", .{line});
            return error.TestExpectedEqual;
        }
        passed += 1;
    }
    try std.testing.expect(passed > 2500);
}
