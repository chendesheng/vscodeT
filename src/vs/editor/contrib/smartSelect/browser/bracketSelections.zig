// Port of `src/vs/editor/contrib/smartSelect/browser/bracketSelections.ts`.
//
// The upstream provider yields to the event loop every 30 ms and continues in
// another round. This port is synchronous and uses an iteration safety cap
// instead; the yielded ranges are unchanged.
//
// `BracketInfo` in the ported bracket-pair model does not carry
// `isOpeningBracket`, so bracket direction is inferred from the language
// configuration. A symmetric bracket that is both an opening and a closing
// bracket is treated as opening, matching the parser's left-to-right bias.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const language_configuration = @import("../../../common/languages/languageConfiguration.zig");
const LanguageService = @import("../../../common/services/languageService.zig").LanguageService;
const languages = @import("../../../common/languages.zig");
const SelectionRange = languages.SelectionRange;
const SelectionRangeProvider = languages.SelectionRangeProvider;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;

const max_scans: usize = 100_000;

pub const BracketSelectionRangeProvider = struct {
    pub fn interface(self: *BracketSelectionRangeProvider) SelectionRangeProvider {
        return .{
            .context = self,
            .provide_selection_ranges = provide,
        };
    }

    fn provide(
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        positions: []const Position,
        token: CancellationToken,
    ) anyerror![]const []const SelectionRange {
        const self: *BracketSelectionRangeProvider = @ptrCast(@alignCast(context));
        return self.provideSelectionRanges(allocator, model, positions, token);
    }

    pub fn provideSelectionRanges(
        self: *BracketSelectionRangeProvider,
        allocator: Allocator,
        model: *TextModel,
        positions: []const Position,
        token: CancellationToken,
    ) ![]const []const SelectionRange {
        _ = self;
        ensureTokenized(model);
        const service = model.bracketPairs().languageService;

        const result = try allocator.alloc([]SelectionRange, positions.len);
        errdefer allocator.free(result);
        var initialized: usize = 0;
        errdefer for (result[0..initialized]) |bucket| allocator.free(bucket);

        for (positions, 0..) |position, index| {
            var bucket = ArrayList(SelectionRange).init(allocator);
            errdefer bucket.deinit();

            var ranges = std.StringHashMap(ArrayList(Range)).init(allocator);
            defer {
                var values = ranges.valueIterator();
                while (values.next()) |list| list.deinit();
                ranges.deinit();
            }

            try bracketsRight(allocator, model, service, position, &ranges, token);
            try bracketsLeft(allocator, model, service, position, &ranges, &bucket, token);

            result[index] = try bucket.toOwnedSlice();
            initialized += 1;
        }

        return result;
    }
};

fn ensureTokenized(model: *TextModel) void {
    var line_number: usize = 1;
    while (line_number <= model.getLineCount()) : (line_number += 1) {
        if (!model.hasAccurateTokensForLine(line_number)) {
            model.forceTokenization(line_number);
        }
    }
}

fn bracketsRight(
    allocator: Allocator,
    model: *TextModel,
    service: *LanguageService,
    start_position: Position,
    ranges: *std.StringHashMap(ArrayList(Range)),
    token: CancellationToken,
) !void {
    var counts = std.StringHashMap(i32).init(allocator);
    defer counts.deinit();

    var pos = start_position;
    var scans: usize = 0;
    while (scans < max_scans) : (scans += 1) {
        if (token.isCancellationRequested()) return;
        const bracket = model.bracketPairs().findNextBracket(pos) orelse break;
        const text = bracket.bracketText;

        if (isOpeningBracket(service, bracket.languageId, text)) {
            const key = text;
            const value = (counts.get(key) orelse 0) + 1;
            try counts.put(key, value);
        } else {
            const key = openingBracketText(service, bracket.languageId, text) orelse text;
            const value = (counts.get(key) orelse 0) - 1;
            try counts.put(key, @max(0, value));
            if (value < 0) {
                const entry = try ranges.getOrPut(key);
                if (!entry.found_existing) entry.value_ptr.* = ArrayList(Range).init(allocator);
                try entry.value_ptr.append(bracket.range);
            }
        }

        pos = bracket.range.getEndPosition();
    }
}

fn bracketsLeft(
    allocator: Allocator,
    model: *TextModel,
    service: *LanguageService,
    start_position: Position,
    ranges: *std.StringHashMap(ArrayList(Range)),
    bucket: *ArrayList(SelectionRange),
    token: CancellationToken,
) !void {
    var counts = std.StringHashMap(i32).init(allocator);
    defer counts.deinit();

    var pos = start_position;
    var scans: usize = 0;
    while (scans < max_scans) : (scans += 1) {
        if (token.isCancellationRequested()) return;
        const bracket = model.bracketPairs().findPrevBracket(pos) orelse break;
        const text = bracket.bracketText;

        if (!isOpeningBracket(service, bracket.languageId, text)) {
            const key = openingBracketText(service, bracket.languageId, text) orelse text;
            const value = (counts.get(key) orelse 0) + 1;
            try counts.put(key, value);
        } else {
            const key = text;
            const value = (counts.get(key) orelse 0) - 1;
            try counts.put(key, @max(0, value));
            if (value < 0) {
                const entry = ranges.getEntry(key) orelse {
                    pos = bracket.range.getStartPosition();
                    continue;
                };
                if (entry.value_ptr.items.len > 0) {
                    const closing = entry.value_ptr.orderedRemove(0);
                    const inner = Range.fromPositions(bracket.range.getEndPosition(), closing.getStartPosition());
                    const outer = Range.fromPositions(bracket.range.getStartPosition(), closing.getEndPosition());
                    try bucket.append(.{ .range = inner });
                    try bucket.append(.{ .range = outer });
                    try addBracketLeading(bucket, model, outer);
                }
            }
        }

        pos = bracket.range.getStartPosition();
    }
}

fn addBracketLeading(bucket: *ArrayList(SelectionRange), model: *TextModel, bracket: Range) !void {
    if (bracket.startLineNumber == bracket.endLineNumber) return;

    // xxxxxxxx {
    //
    // }
    const start_line = bracket.startLineNumber;
    const column = try model.getLineFirstNonWhitespaceColumn(start_line);
    if (column != 0 and column != bracket.startColumn) {
        try bucket.append(.{ .range = Range.fromPositions(
            Position.init(start_line, column),
            bracket.getEndPosition(),
        ) });
        try bucket.append(.{ .range = Range.fromPositions(
            Position.init(start_line, 1),
            bracket.getEndPosition(),
        ) });
    }

    // xxxxxxxx
    // {
    //
    // }
    if (start_line > 1) {
        const above_line = start_line - 1;
        const above_column = try model.getLineFirstNonWhitespaceColumn(above_line);
        if (above_column == bracket.startColumn and
            above_column != try model.getLineLastNonWhitespaceColumn(above_line))
        {
            try bucket.append(.{ .range = Range.fromPositions(
                Position.init(above_line, above_column),
                bracket.getEndPosition(),
            ) });
            try bucket.append(.{ .range = Range.fromPositions(
                Position.init(above_line, 1),
                bracket.getEndPosition(),
            ) });
        }
    }
}

fn configuration(service: *LanguageService, language_id: []const u8) ?language_configuration.LanguageConfiguration {
    return service.getLanguageConfiguration(language_id);
}

fn isOpeningBracket(service: *LanguageService, language_id: []const u8, text: []const u8) bool {
    const config = configuration(service, language_id) orelse return false;
    const brackets = config.brackets orelse return false;
    for (brackets) |pair| {
        if (std.mem.eql(u8, pair[0], text)) return true;
    }
    return false;
}

fn openingBracketText(service: *LanguageService, language_id: []const u8, text: []const u8) ?[]const u8 {
    const config = configuration(service, language_id) orelse return null;
    const brackets = config.brackets orelse return null;
    for (brackets) |pair| {
        if (std.mem.eql(u8, pair[1], text)) return pair[0];
    }
    return null;
}
