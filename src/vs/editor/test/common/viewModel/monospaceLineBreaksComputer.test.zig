// Port of the incremental wrapping cases from `src/vs/editor/test/common/viewModel/monospaceLineBreaksComputer.test.ts`.
// UTF-8 byte offsets and fixed cell widths replace browser UTF-16 and font metrics.
const std = @import("std");
const breaks = @import("../../../common/viewModel/monospaceLineBreaksComputer.zig");
const Projection = @import("../../../common/viewModel/modelLineProjection.zig").ModelLineProjection;
const WrappingIndent = @import("../../../common/config/editorOptions.zig").WrappingIndent;

fn expectAnnotated(text: []const u8, expected: []const u8, projection: Projection) !void {
    const data = projection.data orelse return std.testing.expectEqualStrings(expected, text);
    var segments = std.mem.splitScalar(u8, expected, '|');
    var start: usize = 0;
    for (data.breakOffsets) |end| {
        try std.testing.expectEqualStrings(segments.next() orelse return error.MissingSegment, text[start..end]);
        start = end;
    }
    try std.testing.expectEqual(text.len, start);
    try std.testing.expect(segments.next() == null);
}

fn incremental(text: []const u8, tab_size: usize, widths: [2]usize, expected: [2][]const u8, indent: WrappingIndent) !void {
    const allocator = std.testing.allocator;
    var classifier = try breaks.WrappingCharacterClassifier.init(allocator, breaks.default_break_before_characters, breaks.default_break_after_characters);
    defer classifier.deinit();
    for (widths, 0..) |width, index| {
        var old = Projection.init(allocator, try breaks.computeLineBreaks(allocator, &classifier, text, tab_size, widths[1 - index], indent, .normal));
        defer old.deinit();
        var direct = Projection.init(allocator, try breaks.computeLineBreaks(allocator, &classifier, text, tab_size, width, indent, .normal));
        defer direct.deinit();
        var resized = Projection.init(allocator, try breaks.computeLineBreaksWithPrevious(old.data, allocator, &classifier, text, tab_size, width, indent, .normal));
        defer resized.deinit();
        try expectAnnotated(text, expected[index], direct);
        try expectAnnotated(text, expected[index], resized);
        try std.testing.expectEqualDeep(direct.data, resized.data);
    }
}

test "MonospaceLineBreaksComputer incremental 1" {
    try incremental("just some text and more", 4, .{ 10, 15 }, .{ "just some |text and |more", "just some text |and more" }, .None);
    try incremental("Cu scripserit suscipiantur eos, in affert pericula contentiones sed, cetero sanctus et pro. Ius vidit magna regione te, sit ei elaboraret liberavisse. Mundi verear eu mea, eam vero scriptorem in, vix in menandri assueverit. Natum definiebas cu vim. Vim doming vocibus efficiantur id. In indoctum deseruisse voluptatum vim, ad debitis verterem sed.", 4, .{ 47, 142 }, .{ "Cu scripserit suscipiantur eos, in affert |pericula contentiones sed, cetero sanctus et |pro. Ius vidit magna regione te, sit ei |elaboraret liberavisse. Mundi verear eu mea, |eam vero scriptorem in, vix in menandri |assueverit. Natum definiebas cu vim. Vim |doming vocibus efficiantur id. In indoctum |deseruisse voluptatum vim, ad debitis verterem |sed.", "Cu scripserit suscipiantur eos, in affert pericula contentiones sed, cetero sanctus et pro. Ius vidit magna regione te, sit ei elaboraret |liberavisse. Mundi verear eu mea, eam vero scriptorem in, vix in menandri assueverit. Natum definiebas cu vim. Vim doming vocibus efficiantur |id. In indoctum deseruisse voluptatum vim, ad debitis verterem sed." }, .None);
    try incremental("An his legere persecuti, oblique delicata efficiantur ex vix, vel at graecis officiis maluisset. Et per impedit voluptua, usu discere maiorum at. Ut assum ornatus temporibus vis, an sea melius pericula. Ea dicunt oblique phaedrum nam, eu duo movet nobis. His melius facilis eu, vim malorum temporibus ne. Nec no sale regione, meliore civibus placerat id eam. Mea alii fabulas definitionem te, agam volutpat ad vis, et per bonorum nonumes repudiandae.", 4, .{ 57, 58 }, .{ "An his legere persecuti, oblique delicata efficiantur ex |vix, vel at graecis officiis maluisset. Et per impedit |voluptua, usu discere maiorum at. Ut assum ornatus |temporibus vis, an sea melius pericula. Ea dicunt |oblique phaedrum nam, eu duo movet nobis. His melius |facilis eu, vim malorum temporibus ne. Nec no sale |regione, meliore civibus placerat id eam. Mea alii |fabulas definitionem te, agam volutpat ad vis, et per |bonorum nonumes repudiandae.", "An his legere persecuti, oblique delicata efficiantur ex |vix, vel at graecis officiis maluisset. Et per impedit |voluptua, usu discere maiorum at. Ut assum ornatus |temporibus vis, an sea melius pericula. Ea dicunt oblique |phaedrum nam, eu duo movet nobis. His melius facilis eu, |vim malorum temporibus ne. Nec no sale regione, meliore |civibus placerat id eam. Mea alii fabulas definitionem |te, agam volutpat ad vis, et per bonorum nonumes |repudiandae." }, .None);
    try incremental("\t\t\"owner\": \"vscode\",", 4, .{ 14, 16 }, .{ "\t\t\"owner|\": |\"vscod|e\",", "\t\t\"owner\":| |\"vscode\"|," }, .Same);
    try incremental("🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇&👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬", 4, .{ 51, 50 }, .{ "🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇&|👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬", "🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇|&|👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬🌖🌞🏇🍼🐇👬" }, .Same);
    try incremental("🐇👬&🌞🌖", 4, .{ 5, 4 }, .{ "🐇👬&|🌞🌖", "🐇👬|&|🌞🌖" }, .Same);
    try incremental("\t\tfunc('🌞🏇🍼🌞🏇🍼🐇&👬🌖🌞👬🌖🌞🏇🍼🐇👬', WrappingIndent.Same);", 4, .{ 26, 27 }, .{ "\t\tfunc|('🌞🏇🍼🌞🏇🍼🐇&|👬🌖🌞👬🌖🌞🏇🍼🐇|👬', |WrappingIndent.|Same);", "\t\tfunc|('🌞🏇🍼🌞🏇🍼🐇&|👬🌖🌞👬🌖🌞🏇🍼🐇|👬', |WrappingIndent.|Same);" }, .Same);
    try incremental("factory, \"xtxtfunc(x\"🌞🏇🍼🌞🏇🍼🐇&👬🌖🌞👬🌖🌞🏇🍼🐇👬x\"", 4, .{ 16, 17 }, .{ "factory, |\"xtxtfunc|(x\"🌞🏇🍼🌞🏇🍼|🐇&|👬🌖🌞👬🌖🌞🏇🍼|🐇👬x\"", "factory, |\"xtxtfunc|(x\"🌞🏇🍼🌞🏇🍼🐇|&👬🌖🌞👬🌖🌞🏇🍼|🐇👬x\"" }, .Same);
}

test "issue #95686: CRITICAL: loop forever on the monospaceLineBreaksComputer" {
    try incremental("\t\t\t\t\t\t<tr dmx-class:table-danger=\"(alt <= 50)\" dmx-class:table-warning=\"(alt <= 200)\" dmx-class:table-primary=\"(alt <= 400)\" dmx-class:table-info=\"(alt <= 800)\" dmx-class:table-success=\"(alt >= 400)\">", 4, .{ 179, 1 }, .{ "\t\t\t\t\t\t<tr dmx-class:table-danger=\"(alt <= 50)\" dmx-class:table-warning=\"(alt <= 200)\" dmx-class:table-primary=\"(alt <= 400)\" dmx-class:table-info=\"(alt <= 800)\" |dmx-class:table-success=\"(alt >= 400)\">", "\t|\t|\t|\t|\t|\t|<|t|r| |d|m|x|-|c|l|a|s|s|:|t|a|b|l|e|-|d|a|n|g|e|r|=|\"|(|a|l|t| |<|=| |5|0|)|\"| |d|m|x|-|c|l|a|s|s|:|t|a|b|l|e|-|w|a|r|n|i|n|g|=|\"|(|a|l|t| |<|=| |2|0|0|)|\"| |d|m|x|-|c|l|a|s|s|:|t|a|b|l|e|-|p|r|i|m|a|r|y|=|\"|(|a|l|t| |<|=| |4|0|0|)|\"| |d|m|x|-|c|l|a|s|s|:|t|a|b|l|e|-|i|n|f|o|=|\"|(|a|l|t| |<|=| |8|0|0|)|\"| |d|m|x|-|c|l|a|s|s|:|t|a|b|l|e|-|s|u|c|c|e|s|s|=|\"|(|a|l|t| |>|=| |4|0|0|)|\"|>" }, .Same);
}

test "issue #110392: Occasional crash when resize with panel on the right" {
    try incremental("你好 **hello** **hello** **hello-world** hey there!", 4, .{ 15, 1 }, .{ "你好 **hello** |**hello** |**hello-world**| hey there!", "你|好| |*|*|h|e|l|l|o|*|*| |*|*|h|e|l|l|o|*|*| |*|*|h|e|l|l|o|-|w|o|r|l|d|*|*| |h|e|y| |t|h|e|r|e|!" }, .Same);
}

test "MonospaceLineBreaksComputer - two-cell width supports incremental line breaks" {
    try incremental("ああああああ", 4, .{ 5, 7 }, .{ "ああ|ああ|ああ", "あああ|あああ" }, .None);
    try incremental("    ああああ", 4, .{ 8, 10 }, .{ "    ああ|ああ", "    あああ|あ" }, .Same);
    try incremental("你好 **hello** **hello** **hello-world** hey there!", 4, .{ 15, 1 }, .{ "你好 **hello** |**hello** |**hello-world**| hey there!", "你|好| |*|*|h|e|l|l|o|*|*| |*|*|h|e|l|l|o|*|*| |*|*|h|e|l|l|o|-|w|o|r|l|d|*|*| |h|e|y| |t|h|e|r|e|!" }, .Same);
}
