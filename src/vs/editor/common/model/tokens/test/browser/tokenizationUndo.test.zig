// Regression: undo/redo must leave grammar token boundaries stable.
const std = @import("std");
const Editor = @import("../../../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TerminalViewHost = @import("../../../../../browser/widget/codeEditor/terminalViewHost.zig").TerminalViewHost;

fn tokenSignature(allocator: std.mem.Allocator, editor: *Editor) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    editor.model.forceTokenization(1);
    var tokens = try editor.model.tokenization().getLineTokens(1);
    defer tokens.deinit();
    for (0..tokens.getCount()) |index| {
        try out.append('[');
        try out.appendSlice(tokens.getTokenText(index));
        try out.append(']');
    }
    return out.toOwnedSlice();
}

fn drainBackground(editor: *Editor) void {
    var guard: usize = 0;
    while (editor.backgroundTokenizationPending() and guard < 1000) : (guard += 1) {
        _ = editor.pollBackgroundTokenization();
    }
}

fn renderedSignature(allocator: std.mem.Allocator, host: *TerminalViewHost) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try host.renderRange(1, 1);
    const rendered = host.getRenderedLine(1) orelse return out.toOwnedSlice();
    for (rendered.rendered.parts) |part| {
        try out.append('[');
        try out.appendSlice(part.text);
        try out.append(':');
        var buffer: [16]u8 = undefined;
        try out.appendSlice(try std.fmt.bufPrint(&buffer, "{d}", .{part.foreground}));
        try out.append(']');
    }
    return out.toOwnedSlice();
}

test "TokenizationUndo: grammar tokens survive edit and undo" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = "const x = `${testWebLocation}`;";
    const editor = try Editor.createFromText(allocator, io, source, "token-undo.ts", 80, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const before = try tokenSignature(allocator, editor);
    defer allocator.free(before);

    try editor.setCursorPosition(.{ .lineNumber = 1, .column = 1 });
    try editor.insertText("X");
    try editor.undo();

    const after = try tokenSignature(allocator, editor);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "TokenizationUndo: rendered token colors survive edit and undo" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = "const x = `${testWebLocation}`;";
    const editor = try Editor.createFromText(allocator, io, source, "token-undo-view.ts", 80, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const host = try TerminalViewHost.init(allocator, editor);
    defer host.deinit();

    drainBackground(editor);
    const before = try renderedSignature(allocator, host);
    defer allocator.free(before);
    const at = std.mem.indexOf(u8, source, "testWebLocation").? + 1;
    try editor.setCursorPosition(.{ .lineNumber = 1, .column = at });
    try editor.insertText("X");
    drainBackground(editor);
    const edited = try renderedSignature(allocator, host);
    defer allocator.free(edited);
    try editor.undo();
    const after = try renderedSignature(allocator, host);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try editor.redo();
    const redone = try renderedSignature(allocator, host);
    defer allocator.free(redone);
    try std.testing.expectEqualStrings(edited, redone);
}
