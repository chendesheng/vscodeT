const strings = @import("strings.zig");

fn _normalizeIndentationFromWhitespace(str: []const u8, indentSize: usize, insertSpaces: bool) []const u8 {
    var spacesCnt: usize = 0;
    for (0..str.len) |i| {
        if (str[i] == '\t') {
            spacesCnt = nextIndentTabStop(spacesCnt, indentSize);
        } else {
            spacesCnt += 1;
        }
    }

    var result = "";
    if (!insertSpaces) {
        const tabsCnt = spacesCnt / indentSize;
        spacesCnt = spacesCnt % indentSize;
        for (0..tabsCnt) |_| {
            result += '\t';
        }
    }

    for (0..spacesCnt) |_| {
        result += ' ';
    }

    return result;
}

pub fn normalizeIndentation(str: []const u8, indentSize: usize, insertSpaces: bool) []const u8 {
    const firstNonWhitespaceIndex = strings.firstNonWhitespaceIndex(str);
    if (firstNonWhitespaceIndex) |index| {
        return _normalizeIndentationFromWhitespace(str[0..index], indentSize, insertSpaces) ++ str[index..];
    }
    return str;
}

fn nextIndentTabStop(visibleColumn: usize, tabSize: usize) usize {
    return visibleColumn + tabSize - (visibleColumn % tabSize);
}
