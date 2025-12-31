const std = @import("std");
const strings = @import("../../basics/strings.zig");
const PieceTreeBufferBuilder = @import("../../pieceTreeTextBuffer/pieceTreeBufferBuilder.zig").PieceTreeBufferBuilder;
const String = @import("../../basics/strings.zig").String;
const EOL = @import("../../basics/eolCounter.zig").EOL;
const createTextBufferFactory = @import("../../textModel/textModel.zig").createTextBufferFactory;
const Allocator = std.mem.Allocator;

fn testTextBufferFactory(allocator: Allocator, text: String, eol: EOL, mightContainNonBasicASCII: bool, mightContainRTL: bool) !void {
    var reader = text.reader();
    var factory = try createTextBufferFactory(allocator, &reader);
    defer factory.deinit();

    var textBuffer = try factory.create(.LF);
    defer textBuffer.deinit();

    try std.testing.expectEqual(mightContainNonBasicASCII, textBuffer.getMightContainNonBasicASCII());
    try std.testing.expectEqual(mightContainRTL, textBuffer.getMightContainRTL());
    try std.testing.expectEqual(eol, textBuffer.getEOL());
}

const ModelBuilderTests = struct {
    const allocator = std.testing.allocator;

    test "t1" {
        try testTextBufferFactory(allocator, String.Empty, .LF, false, false);
    }

    test "t2" {
        try testTextBufferFactory(allocator, String.initBorrowed("Hello world"), .LF, false, false);
    }

    test "t3" {
        try testTextBufferFactory(allocator, String.initBorrowed("Hello world\nHow are you?"), .LF, false, false);
    }

    test "t4" {
        try testTextBufferFactory(allocator, String.initBorrowed("Hello world\nHow are you?\nIs everything good today?\nDo you enjoy the weather?"), .LF, false, false);
    }

    test "carriage return detection (1 \\r\\n 2 \\n)" {
        try testTextBufferFactory(allocator, String.initBorrowed("Hello world\r\nHow are you?\nIs everything good today?\nDo you enjoy the weather?"), .LF, false, false);
    }

    test "carriage return detection (2 \\r\\n 1 \\n)" {
        try testTextBufferFactory(allocator, String.initBorrowed("Hello world\r\nHow are you?\r\nIs everything good today?\nDo you enjoy the weather?"), .CRLF, false, false);
    }

    test "carriage return detection (3 \\r\\n 0 \\n)" {
        try testTextBufferFactory(allocator, String.initBorrowed("Hello world\r\nHow are you?\r\nIs everything good today?\r\nDo you enjoy the weather?"), .CRLF, false, false);
    }

    test "BOM handling" {
        try testTextBufferFactory(allocator, String.initBorrowed(strings.UTF8_BOM_CHARACTER ++ "Hello world!"), .LF, false, false);
    }

    test "RTL handling 2" {
        try testTextBufferFactory(allocator, String.initBorrowed("Hello world!זוהי עובדה מבוססת שדעתו"), .LF, true, true);
    }

    test "RTL handling 3" {
        try testTextBufferFactory(allocator, String.initBorrowed("Hello world!זוהי \nעובדה מבוססת שדעתו"), .LF, true, true);
    }

    test "ASCII handling 1" {
        try testTextBufferFactory(allocator, String.initBorrowed("Hello world!!\nHow do you do?"), .LF, false, false);
    }

    test "ASCII handling 2" {
        try testTextBufferFactory(allocator, String.initBorrowed("Hello world!!\nHow do you do?Züricha📚📚b"), .LF, true, false);
    }
};

test "linesTextBufferBuilder" {
    _ = ModelBuilderTests;
}
