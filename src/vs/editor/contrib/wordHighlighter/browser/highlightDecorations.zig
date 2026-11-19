// Port of `src/vs/editor/contrib/wordHighlighter/browser/highlightDecorations.ts`.
//
// Upstream registers four `ModelDecorationOptions` instances with CSS classes
// (`wordHighlight`, `wordHighlightStrong`, `wordHighlightText`,
// `selectionHighlight`) and maps a `DocumentHighlightKind` to one of them. The
// terminal view paints ranges directly, so this file maps the kind to the
// portable decoration kind instead. The matching cell colors live in
// `src/tui/editorView.zig`; the classes keep the upstream names:
//  * `wordHighlight`      read access, translucent gray;
//  * `wordHighlightStrong` write access, translucent blue;
//  * `wordHighlightText`  textual occurrence (default), same gray as read.
//
// Upstream's overview-ruler and minimap contributions have no terminal
// counterpart and are omitted.
const std = @import("std");
const languages = @import("../../../common/languages.zig");
const DocumentHighlightKind = languages.DocumentHighlightKind;
const editorBrowser = @import("../../../browser/editorBrowser.zig");

pub fn getHighlightDecorationKind(kind: ?DocumentHighlightKind) editorBrowser.DecorationKind {
    if (kind) |value| {
        switch (value) {
            .Write => return .word_highlight_strong,
            .Text => return .word_highlight_text,
            .Read => return .word_highlight,
        }
    }
    return .word_highlight;
}

test "highlight decorations: maps document highlight kinds" {
    const testing = std.testing;
    try testing.expectEqual(editorBrowser.DecorationKind.word_highlight_strong, getHighlightDecorationKind(.Write));
    try testing.expectEqual(editorBrowser.DecorationKind.word_highlight_text, getHighlightDecorationKind(.Text));
    try testing.expectEqual(editorBrowser.DecorationKind.word_highlight, getHighlightDecorationKind(.Read));
    try testing.expectEqual(editorBrowser.DecorationKind.word_highlight, getHighlightDecorationKind(null));
}
