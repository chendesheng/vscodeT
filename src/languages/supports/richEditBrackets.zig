const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const RegExp = @import("../../basics/RegExp.zig").RegExp;
const RegExpOptions = @import("../../basics/regExp.zig").Options;
const escapeRegExp = @import("../../basics/RegExp.zig").escapeRegExp;

fn prepareBracketForRegExp(allocator: Allocator, str: []const u8) !ArrayList(u8) {
    // This bracket pair uses letters like e.g. "begin" - "end"
    var wordReg = try RegExp.init("^[\\w ]+$", .{});
    defer wordReg.deinit();
    const insertWordBoundaries = wordReg.isMatch(str);
    var escaped = try escapeRegExp(allocator, str);
    if (insertWordBoundaries) {
        try escaped.insert(0, 8); // \b
        try escaped.append(8); // \b
    }
    return escaped;
}

pub fn createBracketOrRegExp(allocator: Allocator, pieces: []const []const u8, options: RegExpOptions) !RegExp {
    var regexStr = ArrayList(u8).init(allocator);
    defer regexStr.deinit();

    try regexStr.append('(');
    for (pieces) |piece| {
        var escaped = try prepareBracketForRegExp(allocator, piece);
        defer escaped.deinit();
        try regexStr.appendSlice(escaped.items);
        try regexStr.appendSlice(")|(");
    }
    try regexStr.append(')');

    return try RegExp.init(regexStr.items, options);
}
