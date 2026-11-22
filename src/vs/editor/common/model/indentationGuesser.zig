const std = @import("std");
const PieceTreeTextBuffer = @import("./pieceTreeTextBuffer/pieceTreeTextBuffer.zig").PieceTreeTextBuffer;
const StringBuffer = @import("./pieceTreeTextBuffer/pieceTreeBase.zig").StringBuffer;
const usizeSub = @import("../../../base/common/utils.zig").usizeSub;

const SpacesDiffResult = struct {
    spacesDiff: usize,
    looksLikeAlignment: bool,
    fn init() SpacesDiffResult {
        return SpacesDiffResult{
            .spacesDiff = 0,
            .looksLikeAlignment = false,
        };
    }
};

// Compute the diff in spaces between two line's indentation.
fn spacesDiff(a: []const u8, aLength: usize, b: []const u8, bLength: usize, result: *SpacesDiffResult) void {
    result.spacesDiff = 0;
    result.looksLikeAlignment = false;

    // This can go both ways (e.g.):
    //  - a: "\t"
    //  - b: "\t    "
    //  => This should count 1 tab and 4 spaces

    var i: usize = 0;

    while (i < aLength and i < bLength) : (i += 1) {
        const aCharCode = a[i];
        const bCharCode = b[i];

        if (aCharCode != bCharCode) {
            break;
        }
    }

    var aSpacesCnt: usize = 0;
    var aTabsCount: usize = 0;
    for (i..aLength) |j| {
        const aCharCode = a[j];
        if (aCharCode == ' ') {
            aSpacesCnt += 1;
        } else {
            aTabsCount += 1;
        }
    }

    var bSpacesCnt: usize = 0;
    var bTabsCount: usize = 0;
    for (i..bLength) |j| {
        const bCharCode = b[j];
        if (bCharCode == ' ') {
            bSpacesCnt += 1;
        } else {
            bTabsCount += 1;
        }
    }

    if (aSpacesCnt > 0 and aTabsCount > 0) {
        return;
    }
    if (bSpacesCnt > 0 and bTabsCount > 0) {
        return;
    }

    const tabsDiff: usize = @intCast(@abs(usizeSub(aTabsCount, bTabsCount)));
    const spacesDiff_: usize = @intCast(@abs(usizeSub(aSpacesCnt, bSpacesCnt)));

    if (tabsDiff == 0) {
        // check if the indentation difference might be caused by alignment reasons
        // sometime folks like to align their code, but this should not be used as a hint
        result.spacesDiff = spacesDiff_;

        if (spacesDiff_ > 0 and bSpacesCnt > 0 and bSpacesCnt - 1 < a.len and bSpacesCnt < b.len) {
            if (b[bSpacesCnt] != ' ' and a[bSpacesCnt - 1] == ' ') {
                if (a[a.len - 1] == ',') {
                    // This looks like an alignment desire: e.g.
                    // const a = b + c,
                    //       d = b - c;
                    result.looksLikeAlignment = true;
                }
            }
        }
        return;
    }
    if (spacesDiff_ % tabsDiff == 0) {
        result.spacesDiff = spacesDiff_ / tabsDiff;
        return;
    }
}

pub const GuessedIndentation = struct {
    tabSize: usize,
    insertSpaces: bool,
};

pub fn guessIndentation(source: *PieceTreeTextBuffer, defaultTabSize: usize, defaultInsertSpaces: bool) !GuessedIndentation {
    // Look at most at the first 10k lines
    const linesCount = @min(source.getLineCount(), 10000);

    var linesIndentedWithTabsCount: usize = 0; // number of lines that contain at least one tab in indentation
    var linesIndentedWithSpacesCount: usize = 0; // number of lines that contain only spaces in indentation

    var previousLineStorage = std.array_list.Managed(u8).init(source.getAllocator());
    defer previousLineStorage.deinit();
    var previousLineText: []const u8 = ""; // content of latest line that contained non-whitespace chars
    var previousLineIndentation: usize = 0; // index at which latest line contained the first non-whitespace char

    const ALLOWED_TAB_SIZE_GUESSES = [_]usize{ 2, 4, 6, 8, 3, 5, 7 }; // prefer even guesses for `tabSize`, limit to [2, 8].
    const MAX_ALLOWED_TAB_SIZE_GUESS = 8; // max(ALLOWED_TAB_SIZE_GUESSES) = 8

    var spacesDiffCount = [_]usize{ 0, 0, 0, 0, 0, 0, 0, 0, 0 }; // `tabSize` scores
    var tmp = SpacesDiffResult.init();

    for (1..linesCount + 1) |lineNumber| {
        const currentLineText = try source.getLineContent(lineNumber);
        defer currentLineText.deinit();
        const currentLineLength = currentLineText.items.len;

        var currentLineHasContent = false; // does `currentLineText` contain non-whitespace chars
        var currentLineIndentation: usize = 0; // index at which `currentLineText` contains the first non-whitespace char
        var currentLineSpacesCount: usize = 0; // count of spaces found in `currentLineText` indentation
        var currentLineTabsCount: usize = 0; // count of tabs found in `currentLineText` indentation
        for (0..currentLineLength) |j| {
            const charCode = currentLineText.items[j];

            if (charCode == '\t') {
                currentLineTabsCount += 1;
            } else if (charCode == ' ') {
                currentLineSpacesCount += 1;
            } else {
                // Hit non whitespace character on this line
                currentLineHasContent = true;
                currentLineIndentation = j;
                break;
            }
        }

        // Ignore empty or only whitespace lines
        if (!currentLineHasContent) {
            continue;
        }

        if (currentLineTabsCount > 0) {
            linesIndentedWithTabsCount += 1;
        } else if (currentLineSpacesCount > 1) {
            linesIndentedWithSpacesCount += 1;
        }

        spacesDiff(previousLineText, previousLineIndentation, currentLineText.items, currentLineIndentation, &tmp);

        if (tmp.looksLikeAlignment) {
            // if defaultInsertSpaces === true && the spaces count == tabSize, we may want to count it as valid indentation
            //
            // - item1
            //   - item2
            //
            // otherwise skip this line entirely
            //
            // const a = 1,
            //       b = 2;

            if (!(defaultInsertSpaces and defaultTabSize == tmp.spacesDiff)) {
                continue;
            }
        }

        const currentSpacesDiff = tmp.spacesDiff;
        if (currentSpacesDiff <= MAX_ALLOWED_TAB_SIZE_GUESS) {
            spacesDiffCount[currentSpacesDiff] += 1;
        }

        previousLineStorage.clearRetainingCapacity();
        try previousLineStorage.appendSlice(currentLineText.items);
        previousLineText = previousLineStorage.items;
        previousLineIndentation = currentLineIndentation;
    }

    var insertSpaces = defaultInsertSpaces;
    if (linesIndentedWithTabsCount != linesIndentedWithSpacesCount) {
        insertSpaces = linesIndentedWithTabsCount < linesIndentedWithSpacesCount;
    }

    var tabSize = defaultTabSize;

    // Guess tabSize only if inserting spaces...
    if (insertSpaces) {
        var tabSizeScore: f64 = if (insertSpaces) 0 else 0.1 * @as(f64, @floatFromInt(linesCount));

        // std.debug.print("score threshold: {d}\n", .{ tabSizeScore });

        for (ALLOWED_TAB_SIZE_GUESSES) |possibleTabSize| {
            const possibleTabSizeScore: f64 = @floatFromInt(spacesDiffCount[possibleTabSize]);
            if (possibleTabSizeScore > tabSizeScore) {
                tabSizeScore = possibleTabSizeScore;
                tabSize = possibleTabSize;
            }
        }

        // Let a tabSize of 2 win even if it is not the maximum
        // (only in case 4 was guessed)
        if (tabSize == 4 and spacesDiffCount[4] > 0 and spacesDiffCount[2] > 0 and spacesDiffCount[2] * 3 >= spacesDiffCount[4] * 2) {
            tabSize = 2;
        }
    }

    // std.debug.print("--------------------------\n", .{});
    // std.debug.print("linesIndentedWithTabsCount: {d}, linesIndentedWithSpacesCount: {d}\n", .{ linesIndentedWithTabsCount, linesIndentedWithSpacesCount });
    // std.debug.print("spacesDiffCount: {d}\n", .{ spacesDiffCount });
    // std.debug.print("tabSize: {d}, tabSizeScore: {d}\n", .{ tabSize, tabSizeScore });

    return GuessedIndentation{
        .insertSpaces = insertSpaces,
        .tabSize = tabSize,
    };
}

test "guessIndentation" {
    const allocator = std.testing.allocator;
    var source = try PieceTreeTextBuffer.init(allocator, &[_]StringBuffer{
        try .init(allocator, "fn main() {\n    std.debug.print(\"Hello, world!\\n\", .{});\n}"),
    }, "", .LF, false, false, false, false);
    defer source.deinit();

    const defaultTabSize = 2;
    const defaultInsertSpaces = true;
    const guessedIndentation = try guessIndentation(&source, defaultTabSize, defaultInsertSpaces);
    try std.testing.expectEqual(GuessedIndentation{
        .insertSpaces = true,
        .tabSize = 4,
    }, guessedIndentation);
}

test "guessIndentation handles lines without indentation after an indented line" {
    const allocator = std.testing.allocator;
    var source = try PieceTreeTextBuffer.init(allocator, &[_]StringBuffer{
        try .init(allocator, "if (x) {\n    foo();\nbar();\n  baz();\n}"),
    }, "", .LF, false, false, false, false);
    defer source.deinit();

    const guessed = try guessIndentation(&source, 4, true);
    try std.testing.expect(guessed.tabSize >= 2 and guessed.tabSize <= 8);
}

test "guessIndentation: 2 wins only with two thirds of the 4-space diffs" {
    const allocator = std.testing.allocator;
    var buffers = [_]StringBuffer{
        try StringBuffer.init(allocator, "A\n" ++
            "    A\n" ++
            "        A\n" ++
            "            A\n" ++
            "                A\n" ++
            "                    A\n" ++
            "                      A\n" ++
            "                        A\n" ++
            "                            A\n"),
    };
    var buffer = try PieceTreeTextBuffer.init(allocator, &buffers, "", .LF, false, false, true, false);
    defer buffer.deinit();

    const guessed = try guessIndentation(&buffer, 4, true);
    // Five 4-space diffs and two 2-space diffs: 2/5 is below the upstream 2/3
    // threshold, so 4 must win.
    try std.testing.expectEqual(@as(usize, 4), guessed.tabSize);
}
