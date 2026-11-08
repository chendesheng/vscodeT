const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const CharCode = @import("../../../base/common/charCode.zig").CharCode;
const Range = @import("../core/range.zig").Range;
const CharacterClassifier = @import("../core/characterClassifier.zig").CharacterClassifier;

/// A link found in a document.
pub const ILink = struct {
    range: Range,
    url: []const u8,
};

/// A target for the link computer: something that can provide lines.
pub const ILinkComputerTarget = struct {
    context: *anyopaque,
    getLineCount: *const fn (context: *anyopaque) usize,
    getLineContent: *const fn (context: *anyopaque, lineNumber: usize) []const u8,

    pub fn lineCount(self: ILinkComputerTarget) usize {
        return self.getLineCount(self.context);
    }

    pub fn lineContent(self: ILinkComputerTarget, line_number: usize) []const u8 {
        return self.getLineContent(self.context, line_number);
    }
};

pub const State = enum(u8) {
    Invalid = 0,
    Start = 1,
    H = 2,
    HT = 3,
    HTT = 4,
    HTTP = 5,
    F = 6,
    FI = 7,
    FIL = 8,
    BeforeColon = 9,
    AfterColon = 10,
    AlmostThere = 11,
    End = 12,
    Accept = 13,
    LastKnownState = 14, // marker, custom states may follow
};

pub const Edge = struct {
    from: State,
    ch_code: u32,
    to: State,
};

/// A state machine that maps (state, character code) to a new state.
pub const StateMachine = struct {
    allocator: Allocator,
    states: []u8,
    rows: usize,
    cols: usize,

    pub fn init(allocator: Allocator, edges: []const Edge) !StateMachine {
        var max_char_code: u32 = 0;
        var max_state: u8 = @backingInt(State.Invalid);
        for (edges) |edge| {
            if (edge.ch_code > max_char_code) {
                max_char_code = edge.ch_code;
            }
            if (@backingInt(edge.from) > max_state) {
                max_state = @backingInt(edge.from);
            }
            if (@backingInt(edge.to) > max_state) {
                max_state = @backingInt(edge.to);
            }
        }

        const cols = max_char_code + 1;
        const rows = max_state + 1;
        const states = try allocator.alloc(u8, rows * cols);
        @memset(states, @backingInt(State.Invalid));

        var result = StateMachine{
            .allocator = allocator,
            .states = states,
            .rows = rows,
            .cols = cols,
        };
        for (edges) |edge| {
            result.set(edge.from, edge.ch_code, edge.to);
        }
        return result;
    }

    pub fn deinit(self: *StateMachine) void {
        self.allocator.free(self.states);
    }

    fn set(self: *StateMachine, from: State, ch_code: u32, to: State) void {
        self.states[@as(usize, @backingInt(from)) * self.cols + ch_code] = @backingInt(to);
    }

    pub fn nextState(self: *const StateMachine, current_state: State, ch_code: u32) State {
        if (ch_code >= self.cols) {
            return .Invalid;
        }
        return @fromBackingInt(@intCast(self.states[@as(usize, @backingInt(current_state)) * self.cols + ch_code]));
    }
};

pub fn defaultEdges() [21]Edge {
    return .{
        .{ .from = .Start, .ch_code = CharCode.h, .to = .H },
        .{ .from = .Start, .ch_code = CharCode.H, .to = .H },
        .{ .from = .Start, .ch_code = CharCode.f, .to = .F },
        .{ .from = .Start, .ch_code = CharCode.F, .to = .F },
        .{ .from = .H, .ch_code = CharCode.t, .to = .HT },
        .{ .from = .H, .ch_code = CharCode.T, .to = .HT },
        .{ .from = .HT, .ch_code = CharCode.t, .to = .HTT },
        .{ .from = .HT, .ch_code = CharCode.T, .to = .HTT },
        .{ .from = .HTT, .ch_code = CharCode.p, .to = .HTTP },
        .{ .from = .HTT, .ch_code = CharCode.P, .to = .HTTP },
        .{ .from = .HTTP, .ch_code = CharCode.s, .to = .BeforeColon },
        .{ .from = .HTTP, .ch_code = CharCode.S, .to = .BeforeColon },
        .{ .from = .HTTP, .ch_code = CharCode.Colon, .to = .AfterColon },
        .{ .from = .F, .ch_code = CharCode.i, .to = .FI },
        .{ .from = .F, .ch_code = CharCode.I, .to = .FI },
        .{ .from = .FI, .ch_code = CharCode.l, .to = .FIL },
        .{ .from = .FI, .ch_code = CharCode.L, .to = .FIL },
        .{ .from = .FIL, .ch_code = CharCode.e, .to = .BeforeColon },
        .{ .from = .FIL, .ch_code = CharCode.E, .to = .BeforeColon },
        .{ .from = .BeforeColon, .ch_code = CharCode.Colon, .to = .AfterColon },
        .{ .from = .AfterColon, .ch_code = CharCode.Slash, .to = .AlmostThere },
    };
}

pub fn getStateMachine(allocator: Allocator) !StateMachine {
    const edges = defaultEdges();
    // The original has a final edge for AlmostThere -> End on '/'.
    const full_edges = edges ++ [_]Edge{.{ .from = .AlmostThere, .ch_code = CharCode.Slash, .to = .End }};
    return StateMachine.init(allocator, &full_edges);
}

const CharacterClass = enum(u8) {
    None = 0,
    ForceTermination = 1,
    CannotEndIn = 2,
};

fn getClassifier(allocator: Allocator) !CharacterClassifier(CharacterClass) {
    var classifier = CharacterClassifier(CharacterClass).init(allocator, .None);

    const force_termination_characters = " \t<>'\"、。｡､，．：；‘〈「『〔（［｛｢｣｝］）〕』」〉’｀～…|";
    for (force_termination_characters) |byte| {
        try classifier.set(byte, .ForceTermination);
    }

    const cannot_end_with_characters = ".,;:";
    for (cannot_end_with_characters) |byte| {
        try classifier.set(byte, .CannotEndIn);
    }
    return classifier;
}

pub const LinkComputer = struct {
    fn createLink(
        classifier: *const CharacterClassifier(CharacterClass),
        line: []const u8,
        line_number: usize,
        link_begin_index: usize,
        link_end_index: usize,
    ) ILink {
        // Do not allow to end link in certain characters.
        var last_included_char_index = link_end_index - 1;
        while (true) {
            const ch_class = classifier.get(line[last_included_char_index]);
            if (ch_class != .CannotEndIn) {
                break;
            }
            if (last_included_char_index == link_begin_index) {
                break;
            }
            last_included_char_index -= 1;
        }

        // Handle links enclosed in parens, square brackets and curlys.
        if (link_begin_index > 0) {
            const char_code_before_link = line[link_begin_index - 1];
            const last_char_code_in_link = line[last_included_char_index];

            if ((char_code_before_link == CharCode.OpenParen and last_char_code_in_link == CharCode.CloseParen) or
                (char_code_before_link == CharCode.OpenSquareBracket and last_char_code_in_link == CharCode.CloseSquareBracket) or
                (char_code_before_link == CharCode.OpenCurlyBrace and last_char_code_in_link == CharCode.CloseCurlyBrace))
            {
                last_included_char_index -= 1;
            }
        }

        return .{
            .range = Range.init(
                line_number,
                link_begin_index + 1,
                line_number,
                last_included_char_index + 2,
            ),
            .url = line[link_begin_index .. last_included_char_index + 1],
        };
    }

    pub fn computeLinks(
        allocator: Allocator,
        model: ILinkComputerTarget,
        state_machine: *const StateMachine,
    ) ![]ILink {
        var classifier = try getClassifier(allocator);
        defer classifier.deinit();

        var result = ArrayList(ILink).init(allocator);
        errdefer result.deinit();

        var line_number: usize = 1;
        while (line_number <= model.lineCount()) : (line_number += 1) {
            const line = model.lineContent(line_number);
            const len = line.len;

            var j: usize = 0;
            var link_begin_index: usize = 0;
            var link_begin_ch_code: u32 = 0;
            var state: State = .Start;
            var has_open_parens = false;
            var has_open_square_bracket = false;
            var in_square_brackets = false;
            var has_open_curly_bracket = false;

            while (j < len) {
                var reset_state_machine = false;
                const ch_code: u32 = line[j];

                if (state == .Accept) {
                    var ch_class: CharacterClass = undefined;
                    switch (ch_code) {
                        CharCode.OpenParen => {
                            has_open_parens = true;
                            ch_class = .None;
                        },
                        CharCode.CloseParen => {
                            ch_class = if (has_open_parens) .None else .ForceTermination;
                        },
                        CharCode.OpenSquareBracket => {
                            in_square_brackets = true;
                            has_open_square_bracket = true;
                            ch_class = .None;
                        },
                        CharCode.CloseSquareBracket => {
                            in_square_brackets = false;
                            ch_class = if (has_open_square_bracket) .None else .ForceTermination;
                        },
                        CharCode.OpenCurlyBrace => {
                            has_open_curly_bracket = true;
                            ch_class = .None;
                        },
                        CharCode.CloseCurlyBrace => {
                            ch_class = if (has_open_curly_bracket) .None else .ForceTermination;
                        },
                        // The following rules make it so that ' or " or ` are
                        // allowed inside links only if the link is wrapped by
                        // some other quote character.
                        CharCode.SingleQuote, CharCode.DoubleQuote, CharCode.BackTick => {
                            if (link_begin_ch_code == ch_code) {
                                ch_class = .ForceTermination;
                            } else if (link_begin_ch_code == CharCode.SingleQuote or
                                link_begin_ch_code == CharCode.DoubleQuote or
                                link_begin_ch_code == CharCode.BackTick)
                            {
                                ch_class = .None;
                            } else {
                                ch_class = .ForceTermination;
                            }
                        },
                        CharCode.Asterisk => {
                            // `*` terminates a link if the link began with `*`.
                            ch_class = if (link_begin_ch_code == CharCode.Asterisk) .ForceTermination else .None;
                        },
                        CharCode.Space => {
                            // ` ` allows space in between [ and ].
                            ch_class = if (in_square_brackets) .None else .ForceTermination;
                        },
                        else => {
                            ch_class = classifier.get(@intCast(ch_code));
                        },
                    }

                    // Check if character terminates link.
                    if (ch_class == .ForceTermination) {
                        try result.append(createLink(&classifier, line, line_number, link_begin_index, j));
                        reset_state_machine = true;
                    }
                } else if (state == .End) {
                    var ch_class: CharacterClass = undefined;
                    if (ch_code == CharCode.OpenSquareBracket) {
                        // Allow for the authority part to contain ipv6
                        // addresses which contain [ and ].
                        has_open_square_bracket = true;
                        ch_class = .None;
                    } else {
                        ch_class = classifier.get(@intCast(ch_code));
                    }

                    // Check if character terminates link.
                    if (ch_class == .ForceTermination) {
                        reset_state_machine = true;
                    } else {
                        state = .Accept;
                    }
                } else {
                    state = state_machine.nextState(state, ch_code);
                    if (state == .Invalid) {
                        reset_state_machine = true;
                    }
                }

                if (reset_state_machine) {
                    state = .Start;
                    has_open_parens = false;
                    has_open_square_bracket = false;
                    has_open_curly_bracket = false;

                    // Record where the link started.
                    link_begin_index = j + 1;
                    link_begin_ch_code = ch_code;
                }

                j += 1;
            }

            if (state == .Accept) {
                try result.append(createLink(&classifier, line, line_number, link_begin_index, len));
            }
        }

        return result.toOwnedSlice();
    }
};

/// Returns an array of all links contained in the provided document.
pub fn computeLinks(
    allocator: Allocator,
    model: ?ILinkComputerTarget,
    state_machine: ?*const StateMachine,
) ![]ILink {
    const target = model orelse return try allocator.alloc(ILink, 0);
    if (state_machine) |machine| {
        return LinkComputer.computeLinks(allocator, target, machine);
    }
    var machine = try getStateMachine(allocator);
    defer machine.deinit();
    return LinkComputer.computeLinks(allocator, target, &machine);
}

const TestTarget = struct {
    lines: []const []const u8,

    fn getLineCount(context: *anyopaque) usize {
        const self: *TestTarget = @ptrCast(@alignCast(context));
        return self.lines.len;
    }

    fn getLineContent(context: *anyopaque, line_number: usize) []const u8 {
        const self: *TestTarget = @ptrCast(@alignCast(context));
        return self.lines[line_number - 1];
    }

    fn target(self: *TestTarget) ILinkComputerTarget {
        return .{ .context = self, .getLineCount = &getLineCount, .getLineContent = &getLineContent };
    }
};

test "LinkComputer: http links" {
    const allocator = std.testing.allocator;

    var target = TestTarget{ .lines = &.{
        "Visit http://example.com now",
        "or https://foo.bar/baz.",
        "file:///tmp/a.txt",
    } };

    const links = try computeLinks(allocator, target.target(), null);
    defer allocator.free(links);

    try std.testing.expectEqual(@as(usize, 3), links.len);
    try std.testing.expectEqualStrings("http://example.com", links[0].url);
    try std.testing.expectEqual(@as(usize, 1), links[0].range.startLineNumber);
    try std.testing.expectEqual(@as(usize, 7), links[0].range.startColumn);
    try std.testing.expectEqualStrings("https://foo.bar/baz", links[1].url);
    try std.testing.expectEqualStrings("file:///tmp/a.txt", links[2].url);
}

test "LinkComputer: links enclosed in parens" {
    const allocator = std.testing.allocator;

    var target = TestTarget{ .lines = &.{"see (https://foo.bar/baz)."} };

    const links = try computeLinks(allocator, target.target(), null);
    defer allocator.free(links);

    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqualStrings("https://foo.bar/baz", links[0].url);
}

test "LinkComputer: no links" {
    const allocator = std.testing.allocator;

    var target = TestTarget{ .lines = &.{ "hello world", "not a link: example.com" } };
    const links = try computeLinks(allocator, target.target(), null);
    defer allocator.free(links);
    try std.testing.expectEqual(@as(usize, 0), links.len);

    const empty = try computeLinks(allocator, null, null);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
