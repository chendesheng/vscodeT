const std = @import("std");
const ui = @import("ui");
const box = ui.box;
const dom = ui.dom;
const linebreak = ui.linebreak;
const style = ui.style;
const Leaf = ui.text_layout.Leaf;
const Wrapped = ui.text_layout.Wrapped;
const layoutRun = ui.text_layout.layoutRun;

test "text_layout: normal wraps at UAX14 opportunities" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 8 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();

    const root = try doc.createElement(.div);
    doc.setRoot(root);
    const text_node = try doc.createText("one two three");
    _ = try root.appendChild(text_node);

    var tree = try box.BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    const text_box = tree.find(text_node).?;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const leaves = [_]Leaf{.{ .text = .{
        .box = text_box,
        .data = text_box.text.?,
        .text_style = .{},
    } }};
    const wrapped = try layoutRun(.{
        .allocator = arena.allocator(),
        .doc = &doc,
        .tables = &tables,
        .text_style = .{},
        .text_align = .left,
        .max_width = 5,
        .tab_size = 4,
        .origin_x = 0,
        .origin_y = 0,
    }, &leaves);
    try std.testing.expectEqual(@as(usize, 3), wrapped.lines.len);
    try std.testing.expectEqualStrings("one", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("two", wrapped.lines[1].segments[0].text);
    try std.testing.expectEqualStrings("three", wrapped.lines[2].segments[0].text);
}

fn testWrap(
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    tables: *const linebreak.LineBreakTables,
    data: []const u8,
    ts: style.TextStyle,
    width: f64,
    text_align: style.TextAlign,
) !Wrapped {
    var dummy = box.LayoutBox{ .kind = .text };
    const leaves = [_]Leaf{.{ .text = .{
        .box = &dummy,
        .data = data,
        .text_style = ts,
    } }};
    return layoutRun(.{
        .allocator = allocator,
        .doc = doc,
        .tables = tables,
        .text_style = ts,
        .text_align = text_align,
        .max_width = width,
        .tab_size = 4,
        .origin_x = 0,
        .origin_y = 0,
    }, &leaves);
}

test "text_layout: nowrap and pre do not soft wrap" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const nowrap = try testWrap(arena.allocator(), &doc, &tables, "one two three", .{
        .white_space = .nowrap,
    }, 5, .left);
    try std.testing.expectEqual(@as(usize, 1), nowrap.lines.len);
    try std.testing.expectEqualStrings("one two three", nowrap.lines[0].segments[0].text);

    const pre = try testWrap(arena.allocator(), &doc, &tables, "  a  b", .{
        .white_space = .pre,
    }, 3, .left);
    try std.testing.expectEqual(@as(usize, 1), pre.lines.len);
    try std.testing.expectEqualStrings("  a  b", pre.lines[0].segments[0].text);
}

test "text_layout: normal collapses spaces and trims line edges" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "  a   b  ", .{}, 20, .left);
    try std.testing.expectEqual(@as(usize, 1), wrapped.lines.len);
    try std.testing.expectEqualStrings("a b", wrapped.lines[0].segments[0].text);
}

test "text_layout: last fitting break, otherwise the unbreakable word overflows" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "abcdef ghi", .{}, 3, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("abcdef", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 6), wrapped.lines[0].width);
    try std.testing.expectEqualStrings("ghi", wrapped.lines[1].segments[0].text);
}

test "text_layout: overflow-wrap breaks a long word" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "abcdef", .{
        .overflow_wrap = .break_word,
    }, 3, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("abc", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("def", wrapped.lines[1].segments[0].text);
}

test "text_layout: text-align offsets every line" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "a bb", .{}, 3, .center);
    try std.testing.expectEqual(@as(f64, 1), wrapped.lines[0].segments[0].x);
    try std.testing.expectEqual(@as(f64, 0.5), wrapped.lines[1].segments[0].x);
}

test "text_layout: pre-line keeps newlines but collapses spaces" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "a   b\nc", .{
        .white_space = .pre_line,
    }, 20, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("a b", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("c", wrapped.lines[1].segments[0].text);
}

fn wideMeasurer(cp: u21) u2 {
    return if (cp == 0x4e2d) 2 else 1;
}

test "text_layout: CJK opportunities break before a wide glyph" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{
        .cols = 20,
        .rows = 4,
        .measure_width = wideMeasurer,
    });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "中中", .{}, 2, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("中", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 2), wrapped.lines[0].width);
}

test "text_layout: pre keeps newlines and expands tabs" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "a\tb\nc", .{
        .white_space = .pre,
    }, 20, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("a   b", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 5), wrapped.lines[0].width);
    try std.testing.expectEqualStrings("c", wrapped.lines[1].segments[0].text);
}

test "text_layout: keep-all suppresses soft wrapping across spaces" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "one two three", .{
        .word_break = .keep_all,
    }, 5, .left);
    try std.testing.expectEqual(@as(usize, 1), wrapped.lines.len);
    try std.testing.expectEqualStrings("one two three", wrapped.lines[0].segments[0].text);
}

test "text_layout: overflow-wrap anywhere splits a long word" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "abcd", .{
        .overflow_wrap = .anywhere,
    }, 2, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("ab", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("cd", wrapped.lines[1].segments[0].text);
}

test "text_layout: a text leaf override adds break-anywhere candidates" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var first = box.LayoutBox{ .kind = .text };
    var second = box.LayoutBox{ .kind = .text };
    const leaves = [_]Leaf{
        .{ .text = .{ .box = &first, .data = "ab ", .text_style = .{} } },
        .{ .text = .{ .box = &second, .data = "cdef", .text_style = .{ .overflow_wrap = .break_word } } },
    };
    const wrapped = try layoutRun(.{
        .allocator = arena.allocator(),
        .doc = &doc,
        .tables = &tables,
        .text_style = .{},
        .text_align = .left,
        .max_width = 3,
        .tab_size = 4,
        .origin_x = 0,
        .origin_y = 0,
    }, &leaves);
    try std.testing.expectEqual(@as(usize, 3), wrapped.lines.len);
    try std.testing.expectEqualStrings("ab", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("cde", wrapped.lines[1].segments[0].text);
    try std.testing.expectEqualStrings("f", wrapped.lines[2].segments[0].text);
}

test "text_layout: break-spaces keeps trailing spaces in the line width" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "a  ", .{
        .white_space = .break_spaces,
    }, 10, .left);
    try std.testing.expectEqual(@as(usize, 1), wrapped.lines.len);
    try std.testing.expectEqual(@as(f64, 3), wrapped.lines[0].width);
    try std.testing.expectEqualStrings("a  ", wrapped.lines[0].segments[0].text);
}

test "text_layout: pre-wrap preserves spaces and still wraps" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "aa  bb", .{
        .white_space = .pre_wrap,
    }, 4, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("aa", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("bb", wrapped.lines[1].segments[0].text);
}

test "text_layout: tabs collapse and participate in normal wrapping" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wrapped = try testWrap(arena.allocator(), &doc, &tables, "a\tb", .{}, 2, .left);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines.len);
    try std.testing.expectEqualStrings("a", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqualStrings("b", wrapped.lines[1].segments[0].text);
}

fn testRun(
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    tables: *const linebreak.LineBreakTables,
    leaves: []const Leaf,
    ts: style.TextStyle,
    width: f64,
    text_align: style.TextAlign,
) !Wrapped {
    return layoutRun(.{
        .allocator = allocator,
        .doc = doc,
        .tables = tables,
        .text_style = ts,
        .text_align = text_align,
        .max_width = width,
        .tab_size = 4,
        .origin_x = 0,
        .origin_y = 0,
    }, leaves);
}

test "text_layout: single pre line bypasses wrapping with one segment" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 40, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var dummy = box.LayoutBox{ .kind = .text };
    const leaves = [_]Leaf{.{ .text = .{
        .box = &dummy,
        .data = "hello world",
        .text_style = .{ .white_space = .pre },
    } }};
    // The width is below the text width on purpose: `pre` never wraps.
    const wrapped = try testRun(
        arena.allocator(),
        &doc,
        &tables,
        &leaves,
        .{ .white_space = .pre },
        5,
        .left,
    );
    try std.testing.expectEqual(@as(usize, 1), wrapped.lines.len);
    try std.testing.expectEqual(@as(usize, 1), wrapped.lines[0].segments.len);
    try std.testing.expectEqualStrings("hello world", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 11), wrapped.lines[0].segments[0].width);
    try std.testing.expectEqual(@as(f64, 11), wrapped.lines[0].width);
    try std.testing.expectEqual(@as(f64, 11), wrapped.max_line_width);
    try std.testing.expectEqual(@as(f64, 0), wrapped.lines[0].segments[0].x);
    try std.testing.expectEqual(@as(f64, 0), wrapped.lines[0].segments[0].y);
    try std.testing.expectEqual(@as(f64, 0), wrapped.lines[0].text_top);
    try std.testing.expectEqual(@as(f64, 1), wrapped.height);
    try std.testing.expect(!wrapped.wrapped);
}

test "text_layout: single line fast path covers nowrap and keep-all" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 40, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var dummy = box.LayoutBox{ .kind = .text };
    const nowrap_leaves = [_]Leaf{.{ .text = .{
        .box = &dummy,
        .data = "one two three",
        .text_style = .{ .white_space = .nowrap },
    } }};
    const nowrap = try testRun(
        arena.allocator(),
        &doc,
        &tables,
        &nowrap_leaves,
        .{ .white_space = .nowrap },
        3,
        .left,
    );
    try std.testing.expectEqual(@as(usize, 1), nowrap.lines.len);
    try std.testing.expectEqualStrings("one two three", nowrap.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 13), nowrap.lines[0].width);

    const keep_all_leaves = [_]Leaf{.{ .text = .{
        .box = &dummy,
        .data = "one two three",
        .text_style = .{ .word_break = .keep_all },
    } }};
    const keep_all = try testRun(
        arena.allocator(),
        &doc,
        &tables,
        &keep_all_leaves,
        .{ .word_break = .keep_all },
        3,
        .left,
    );
    try std.testing.expectEqual(@as(usize, 1), keep_all.lines.len);
    try std.testing.expectEqualStrings("one two three", keep_all.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 13), keep_all.lines[0].width);
}

test "text_layout: single line fast path measures wide glyphs from captured widths" {
    const allocator = std.testing.allocator;
    var wide_doc = try dom.Document.init(allocator, .{
        .cols = 20,
        .rows = 4,
        .measure_width = wideMeasurer,
    });
    defer wide_doc.deinit();
    var default_doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer default_doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var dummy = box.LayoutBox{ .kind = .text };
    const leaves = [_]Leaf{.{ .text = .{
        .box = &dummy,
        .data = "中中",
        .text_style = .{ .white_space = .pre },
    } }};

    const wide = try testRun(
        arena.allocator(),
        &wide_doc,
        &tables,
        &leaves,
        .{ .white_space = .pre },
        2,
        .left,
    );
    try std.testing.expectEqual(@as(usize, 1), wide.lines.len);
    try std.testing.expectEqualStrings("中中", wide.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 4), wide.lines[0].segments[0].width);
    try std.testing.expectEqual(@as(f64, 4), wide.lines[0].width);

    // The default measurer sees the same bytes as two one-cell codepoints.
    const narrow = try testRun(
        arena.allocator(),
        &default_doc,
        &tables,
        &leaves,
        .{ .white_space = .pre },
        2,
        .left,
    );
    try std.testing.expectEqual(@as(usize, 1), narrow.lines.len);
    try std.testing.expectEqual(@as(f64, 2), narrow.lines[0].width);
}

test "text_layout: preserving tabs expand and keep the run column across leaves" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 40, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var first = box.LayoutBox{ .kind = .text };
    var second = box.LayoutBox{ .kind = .text };
    const leaves = [_]Leaf{
        .{ .text = .{ .box = &first, .data = "a\tb", .text_style = .{ .white_space = .pre } } },
        .{ .text = .{ .box = &second, .data = "\tc", .text_style = .{ .white_space = .pre } } },
    };
    const wrapped = try testRun(
        arena.allocator(),
        &doc,
        &tables,
        &leaves,
        .{ .white_space = .pre },
        40,
        .left,
    );
    try std.testing.expectEqual(@as(usize, 1), wrapped.lines.len);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines[0].segments.len);
    try std.testing.expectEqualStrings("a   b", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 5), wrapped.lines[0].segments[0].width);
    // Column 5 after the first leaf, so the second tab advances to stop 8.
    try std.testing.expectEqualStrings("   c", wrapped.lines[0].segments[1].text);
    try std.testing.expectEqual(@as(f64, 5), wrapped.lines[0].segments[1].x);
    try std.testing.expectEqual(@as(f64, 4), wrapped.lines[0].segments[1].width);
    try std.testing.expectEqual(@as(f64, 9), wrapped.lines[0].width);
}

test "text_layout: mixed pre and normal leaves keep the boundary collapse" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 40, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var pre_box = box.LayoutBox{ .kind = .text };
    var normal_box = box.LayoutBox{ .kind = .text };
    const leaves = [_]Leaf{
        .{ .text = .{ .box = &pre_box, .data = "a ", .text_style = .{ .white_space = .pre } } },
        .{ .text = .{ .box = &normal_box, .data = " b", .text_style = .{} } },
    };
    // The run is not fully suppressed (`normal` can wrap), so this exercises
    // the general pipeline with the captured widths.
    const wrapped = try testRun(arena.allocator(), &doc, &tables, &leaves, .{}, 20, .left);
    try std.testing.expectEqual(@as(usize, 1), wrapped.lines.len);
    try std.testing.expectEqual(@as(usize, 2), wrapped.lines[0].segments.len);
    try std.testing.expectEqualStrings("a ", wrapped.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 2), wrapped.lines[0].segments[0].width);
    try std.testing.expectEqual(@as(f64, 0), wrapped.lines[0].segments[0].x);
    // The normal leaf's leading space collapses against the pre leaf's space.
    try std.testing.expectEqualStrings("b", wrapped.lines[0].segments[1].text);
    try std.testing.expectEqual(@as(f64, 1), wrapped.lines[0].segments[1].width);
    try std.testing.expectEqual(@as(f64, 2), wrapped.lines[0].segments[1].x);
    try std.testing.expectEqual(@as(f64, 3), wrapped.lines[0].width);
    try std.testing.expect(!wrapped.wrapped);
}

test "text_layout: trailing spaces follow white-space at the run end" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 40, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // `pre` keeps its trailing spaces and their width.
    const pre = try testWrap(arena.allocator(), &doc, &tables, "a  ", .{
        .white_space = .pre,
    }, 10, .left);
    try std.testing.expectEqual(@as(usize, 1), pre.lines.len);
    try std.testing.expectEqualStrings("a  ", pre.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 3), pre.lines[0].width);

    // `pre-wrap` hangs them from the line width but paints them.
    const pre_wrap = try testWrap(arena.allocator(), &doc, &tables, "a  ", .{
        .white_space = .pre_wrap,
    }, 10, .left);
    try std.testing.expectEqual(@as(usize, 1), pre_wrap.lines.len);
    try std.testing.expectEqual(@as(f64, 1), pre_wrap.lines[0].width);

    // `break-spaces` keeps them like `pre`.
    const break_spaces = try testWrap(arena.allocator(), &doc, &tables, "a  ", .{
        .white_space = .break_spaces,
    }, 10, .left);
    try std.testing.expectEqual(@as(usize, 1), break_spaces.lines.len);
    try std.testing.expectEqualStrings("a  ", break_spaces.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 3), break_spaces.lines[0].width);

    // Collapsing white-space trims the run-edge space entirely.
    const nowrap = try testWrap(arena.allocator(), &doc, &tables, "a  ", .{
        .white_space = .nowrap,
    }, 10, .left);
    try std.testing.expectEqual(@as(usize, 1), nowrap.lines.len);
    try std.testing.expectEqualStrings("a", nowrap.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(f64, 1), nowrap.lines[0].width);
}

test "text_layout: single line fast path places atomic items" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 40, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var before = box.LayoutBox{ .kind = .text };
    var atomic_box = box.LayoutBox{ .kind = .element };
    var after = box.LayoutBox{ .kind = .text };
    const leaves = [_]Leaf{
        .{ .text = .{ .box = &before, .data = "a", .text_style = .{ .white_space = .pre } } },
        .{ .atomic = .{
            .box = &atomic_box,
            .width = 2,
            .height = 1,
            .baseline = 1,
            .margin_left = 0,
            .margin_right = 0,
        } },
        .{ .text = .{ .box = &after, .data = "b", .text_style = .{ .white_space = .pre } } },
    };
    const wrapped = try testRun(
        arena.allocator(),
        &doc,
        &tables,
        &leaves,
        .{ .white_space = .pre },
        40,
        .left,
    );
    try std.testing.expectEqual(@as(usize, 1), wrapped.lines.len);
    const segments = wrapped.lines[0].segments;
    try std.testing.expectEqual(@as(usize, 3), segments.len);
    try std.testing.expectEqualStrings("a", segments[0].text);
    try std.testing.expectEqual(@as(f64, 0), segments[0].x);
    try std.testing.expectEqual(@as(f64, 2), segments[1].width);
    try std.testing.expectEqual(@as(f64, 1), segments[1].x);
    try std.testing.expectEqual(@as(f64, 2), segments[1].advance);
    try std.testing.expectEqualStrings("b", segments[2].text);
    try std.testing.expectEqual(@as(f64, 3), segments[2].x);
    try std.testing.expectEqual(@as(f64, 4), wrapped.lines[0].width);
    try std.testing.expectEqual(@as(f64, 1), wrapped.height);
}

test "text_layout: a many-line paragraph keeps line and segment output" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 20 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const words = [_][]const u8{
        "one", "two",   "three", "four", "five",
        "six", "seven", "eight", "nine", "ten",
    };
    const wrapped = try testWrap(
        arena.allocator(),
        &doc,
        &tables,
        "one two three four five six seven eight nine ten",
        .{},
        5,
        .left,
    );
    try std.testing.expectEqual(words.len, wrapped.lines.len);
    for (wrapped.lines, 0..) |line, line_index| {
        try std.testing.expectEqual(@as(usize, 1), line.segments.len);
        try std.testing.expectEqualStrings(words[line_index], line.segments[0].text);
        try std.testing.expectEqual(
            @as(f64, @floatFromInt(words[line_index].len)),
            line.segments[0].width,
        );
        try std.testing.expectEqual(@as(f64, 0), line.segments[0].x);
        try std.testing.expectEqual(@as(f64, @floatFromInt(line_index)), line.y);
        try std.testing.expectEqual(@as(f64, 1), line.height);
    }
    try std.testing.expectEqual(@as(f64, 5), wrapped.max_line_width);
    try std.testing.expectEqual(@as(f64, 10), wrapped.height);
    try std.testing.expect(wrapped.wrapped);
}

/// Counts `alloc` requests; resize/remap are forwarded untouched so shrinking
/// a list in place is not counted as a new allocation.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
    }
};

fn countPreLineAllocations(
    doc: *const dom.Document,
    tables: *const linebreak.LineBreakTables,
    buffer: []u8,
    data: []const u8,
) !usize {
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    var counting = CountingAllocator{ .child = fba.allocator() };
    var dummy = box.LayoutBox{ .kind = .text };
    const leaves = [_]Leaf{.{ .text = .{
        .box = &dummy,
        .data = data,
        .text_style = .{ .white_space = .pre },
    } }};
    const wrapped = try testRun(
        counting.allocator(),
        doc,
        tables,
        &leaves,
        .{ .white_space = .pre },
        80,
        .left,
    );
    try std.testing.expectEqual(@as(usize, 1), wrapped.lines.len);
    try std.testing.expectEqualStrings(data, wrapped.lines[0].segments[0].text);
    return counting.allocations;
}

test "text_layout: a single pre line has bounded allocations" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 80, .rows = 4 });
    defer doc.deinit();
    var tables = try linebreak.LineBreakTables.init(allocator);
    defer tables.deinit();

    var short_buffer: [64 * 1024]u8 = undefined;
    var long_buffer: [64 * 1024]u8 = undefined;
    const short = try countPreLineAllocations(&doc, &tables, &short_buffer, "hello");
    const long = try countPreLineAllocations(
        &doc,
        &tables,
        &long_buffer,
        "hello world, this pre line is much longer but must not allocate more",
    );
    // Exactly the run buffer (text + widths + items) plus the segment list and
    // the one line: no prefix, break or per-codepoint allocation is made.
    try std.testing.expectEqual(@as(usize, 5), short);
    // The count does not grow with the run length: buffers are sized up front
    // and the single line is placed without per-line break or prefix lists.
    try std.testing.expectEqual(short, long);
}
