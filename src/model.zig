const std = @import("std");
const io = std.io;
const Uri = std.Uri;
const Allocator = std.mem.Allocator;
const Range = @import("range.zig").Range;
const TextChange = @import("textChange.zig").TextChange;
const ArrayList = @import("std").ArrayList;
const default_max_load_percentage = @import("std").hash_map.default_max_load_percentage;

pub const EOL = enum(u8) {
    CRLF,
    LF,
};

pub const EndOfLinePreference = enum {
    TextDefined,
    LF,
    CRLF,
};

pub const SingleEditOperationIdentifier = struct {
    major: i64,
    minor: i64,
};

// A single edit operation, that has an identifier.
pub const IdentifiedSingleEditOperation = struct {
    // An identifier associated with this single edit operation.
    identifier: ?SingleEditOperationIdentifier,
    // This indicates that this operation is inserting automatic whitespace
    // that can be removed on next model edit operation if `config.trimAutoWhitespace` is true.
    // @internal
    isAutoWhitespaceEdit: ?bool,
    // This indicates that this operation is in a set of operations that are tracked and should not be "simplified".
    // @internal
    _isTracked: ?bool,
};

pub const ValidEditOperation = struct {
    // An identifier associated with this single edit operation.
    // @internal
    identifier: ?SingleEditOperationIdentifier,
    // The range to replace. This can be empty to emulate a simple insert.
    range: Range,
    // The text to replace with. This can be empty to emulate a simple delete.
    text: ?[]const u8,
    // @internal
    textChange: TextChange,
};

pub const ValidAnnotatedEditOperation = struct {
    identifier: ?SingleEditOperationIdentifier,
    range: Range,
    text: ?[]const u8,
    forceMoveMarkers: bool,
    isAutoWhitespaceEdit: bool,
    _isTracked: bool,

    pub fn fromRange(range: Range) ValidAnnotatedEditOperation {
        return ValidAnnotatedEditOperation{
            .identifier = null,
            .range = range,
            .text = null,
            .forceMoveMarkers = false,
            .isAutoWhitespaceEdit = false,
            ._isTracked = false,
        };
    }
    pub fn fromRangeAndText(range: Range, text: []const u8) ValidAnnotatedEditOperation {
        return ValidAnnotatedEditOperation{
            .identifier = null,
            .range = range,
            .text = text,
            .forceMoveMarkers = false,
            .isAutoWhitespaceEdit = false,
            ._isTracked = false,
        };
    }
};

pub const InternalModelContentChange = struct {
    range: Range,
    rangeOffset: usize,
    rangeLength: usize,
    text: []const u8,
    forceMoveMarkers: bool,
};

pub const ReverseSingleEditOperation = struct {
    sortIndex: i64,
    identifier: ?SingleEditOperationIdentifier,
    range: Range,
    text: []const u8,
    textChange: TextChange,
};

pub const ApplyEditsResult = struct {
    reverseEdits: ?ArrayList(ReverseSingleEditOperation),
    changes: ArrayList(InternalModelContentChange),
    trimAutoWhitespaceLineNumbers: ?ArrayList(usize),

    pub fn deinit(self: *const ApplyEditsResult) void {
        if (self.reverseEdits) |edits| {
            for (edits.items) |edit| {
                edits.allocator.free(edit.text);
                edits.allocator.free(edit.textChange.oldText);
                edits.allocator.free(edit.textChange.newText);
            }
            edits.deinit();
        }
        for (self.changes.items) |change| {
            self.changes.allocator.free(change.text);
        }
        self.changes.deinit();
        if (self.trimAutoWhitespaceLineNumbers) |lines| {
            lines.deinit();
        }
    }
};

pub const IndentSize = union(enum) {
    number: u8,
    tabSize: u1,
};

pub const TextModelCreationOptions = struct {
    tabSize: usize,
    indentSize: IndentSize,
    insertSpaces: bool,
    detectIndentation: bool,
    trimAutoWhitespace: bool,
    defaultEOL: EOL,
    isForSimpleWidget: bool,
    largeFileOptimizations: bool,
    bracketPairColorizationOptions: BracketPairColorizationOptions,
};

pub const BracketPairColorizationOptions = struct {
    enabled: bool,
    independentColorPoolPerBracketType: bool,

    pub fn equals(self: *const BracketPairColorizationOptions, other: BracketPairColorizationOptions) bool {
        return self.enabled == other.enabled and self.independentColorPoolPerBracketType == other.independentColorPoolPerBracketType;
    }
};

pub const TextModelUpdateOptions = struct {
    tabSize: ?usize,
    indentSize: ?IndentSize,
    insertSpaces: ?bool,
    trimAutoWhitespace: ?bool,
    bracketColorizationOptions: ?BracketPairColorizationOptions,
};

pub const TextModelResolvedOptions = struct {
    // _textModelResolvedOptionsBrand:
    tabSize: usize,
    indentSize: usize,
    _indentSizeIsTabSize: bool,
    insertSpaces: bool,
    defaultEOL: EOL,
    trimAutoWhitespace: bool,
    bracketPairColorizationOptions: BracketPairColorizationOptions,

    pub fn originalIndentSize(self: *const TextModelResolvedOptions) IndentSize {
        return if (self._indentSizeIsTabSize) IndentSize.tabSize else IndentSize.number(self.indentSize);
    }

    // @internal
    pub fn init(
        tabSize: usize,
        indentSize: IndentSize,
        insertSpaces: bool,
        defaultEOL: EOL,
        trimAutoWhitespace: bool,
        bracketPairColorizationOptions: BracketPairColorizationOptions,
    ) TextModelResolvedOptions {
        var options = TextModelResolvedOptions{
            .tabSize = @max(1, tabSize),
            .insertSpaces = insertSpaces,
            .defaultEOL = defaultEOL,
            .trimAutoWhitespace = trimAutoWhitespace,
            .bracketPairColorizationOptions = bracketPairColorizationOptions,
        };

        switch (indentSize) {
            .tabSize => {
                options.indentSize = options.tabSize;
                options._indentSizeIsTabSize = true;
            },
            .number => {
                options.indentSize = @max(1, indentSize);
                options._indentSizeIsTabSize = false;
            },
        }

        return options;
    }

    // @internal
    pub fn equals(self: *const TextModelResolvedOptions, other: TextModelResolvedOptions) bool {
        return (self.tabSize == other.tabSize and self._indentSizeIsTabSize == other._indentSizeIsTabSize and self.indentSize == other.indentSize and self.insertSpaces == other.insertSpaces and self.defaultEOL == other.defaultEOL and self.trimAutoWhitespace == other.trimAutoWhitespace and self.bracketPairColorizationOptions.equals(other.bracketPairColorizationOptions));
    }

    // @internal
    pub fn createChangeEvent(self: *const TextModelResolvedOptions, newOpts: TextModelResolvedOptions) ModelOptionsChangedEvent {
        return ModelOptionsChangedEvent{
            .tabSize = self.tabSize != newOpts.tabSize,
            .indentSize = self.indentSize != newOpts.indentSize,
            .insertSpaces = self.insertSpaces != newOpts.insertSpaces,
            .trimAutoWhitespace = self.trimAutoWhitespace != newOpts.trimAutoWhitespace,
            .bracketPairColorizationOptions = self.bracketPairColorizationOptions,
        };
    }
};

const ModelOptionsChangedEvent = struct {
    tabSize: bool,
    indentSize: bool,
    insertSpaces: bool,
    trimAutoWhitespace: bool,
    bracketPairColorizationOptions: bool,
};

// Describes the behavior of decorations when typing/editing near their edges.
// Note: Please do not edit the values, as they very carefully match `DecorationRangeBehavior`
pub const TrackedRangeStickiness = enum(u2) {
    AlwaysGrowsWhenTypingAtEdges = 0,
    NeverGrowsWhenTypingAtEdges = 1,
    GrowsOnlyWhenTypingBefore = 2,
    GrowsOnlyWhenTypingAfter = 3,
};

pub fn uriToString(uri: Uri, allocator: Allocator) ![]const u8 {
    var list = std.ArrayList(u8).init(allocator);
    const writer = list.writer();

    try writer.print("{s}:", .{uri.scheme});

    try writer.writeAll("//");

    if (uri.user) |user| {
        switch (user) {
            .raw => |_user| {
                try writer.writeAll(_user);
            },
            .percent_encoded => |_user| {
                try writer.writeAll(_user);
            },
        }
    }

    if (uri.password) |password| {
        switch (password) {
            .raw => |_password| {
                try writer.writeAll(":");
                try writer.writeAll(_password);
            },
            .percent_encoded => |_password| {
                try writer.writeAll(":");
                try writer.writeAll(_password);
            },
        }
    }

    if (uri.user != null or uri.password != null) {
        try writer.writeAll("@");
    }

    if (uri.host) |host| {
        switch (host) {
            .raw => |_host| {
                try writer.writeAll(_host);
            },
            .percent_encoded => |_host| {
                try writer.writeAll(_host);
            },
        }
    }

    if (uri.port) |port| {
        try writer.print(":{d}", .{port});
    }

    switch (uri.path) {
        .raw => |path| {
            try writer.writeAll(path);
        },
        .percent_encoded => |path| {
            try writer.writeAll(path);
        },
    }

    if (uri.query) |query| {
        switch (query) {
            .raw => |_query| {
                try writer.print("?{s}", .{_query});
            },
            .percent_encoded => |_query| {
                try writer.print("?{s}", .{_query});
            },
        }
    }

    if (uri.fragment) |fragment| {
        switch (fragment) {
            .raw => |_fragment| {
                try writer.print("#{s}", .{_fragment});
            },
            .percent_encoded => |_fragment| {
                try writer.print("#{s}", .{_fragment});
            },
        }
    }

    return list.toOwnedSlice();
}

test "uriToString" {
    const urls = [_][]const u8{
        "file:///Users/jason/Desktop/test.txt",
        "https://www.google.com",
        "https://www.google.com/search?q=zig",
        "ftp://user:password@ftp.mozilla.org/pub/firefox/releases/",
        "https://www.google.com/search?q=zig&oq=zig#fragment",
    };

    const allocator = std.testing.allocator;
    for (urls) |url| {
        const uri = try Uri.parse(url);
        const result = try uriToString(uri, allocator);
        defer allocator.free(result);
        try std.testing.expectEqualStrings(result, url);
    }
}

fn uriComponentEql(a: Uri.Component, b: Uri.Component) bool {
    switch (a) {
        .raw => |raw| {
            switch (b) {
                .raw => |b_raw| {
                    return std.mem.eql(u8, raw, b_raw);
                },
                .percent_encoded => return false,
            }
        },
        .percent_encoded => |raw| {
            switch (b) {
                .raw => return false,
                .percent_encoded => |b_raw| {
                    return std.mem.eql(u8, raw, b_raw);
                },
            }
        },
    }
}

fn uriComponentNullEql(a: ?Uri.Component, b: ?Uri.Component) bool {
    if (a == null and b == null) return true;
    if (a == null and b != null) return false;
    if (a != null and b == null) return false;
    return uriComponentEql(a.?, b.?);
}

pub fn uriEql(a: Uri, b: Uri) bool {
    if (!std.mem.eql(u8, a.scheme, b.scheme)) return false;
    if (!uriComponentNullEql(a.host, b.host)) return false;
    if (!uriComponentNullEql(a.user, b.user)) return false;
    if (!uriComponentNullEql(a.password, b.password)) return false;

    if (a.port == null and b.port != null) return false;
    if (a.port != null and b.port == null) return false;
    if (a.port != null and b.port != null and a.port.? != b.port.?) return false;

    if (!uriComponentEql(a.path, b.path)) return false;
    if (!uriComponentNullEql(a.query, b.query)) return false;
    if (!uriComponentNullEql(a.fragment, b.fragment)) return false;
    return true;
}

pub const UriContext = struct {
    fn hashComponent(writer: *io.AnyWriter, component: ?Uri.Component) void {
        if (component) |comp| {
            switch (comp) {
                .raw => |raw| {
                    writer.writeInt(u64, std.hash.Wyhash.hash(0, raw), .big) catch unreachable;
                },
                .percent_encoded => |raw| {
                    writer.writeInt(u64, std.hash.Wyhash.hash(0, raw), .big) catch unreachable;
                },
            }
        }
    }

    pub fn hash(self: @This(), s: Uri) u64 {
        _ = self;
        var buf: [64]u8 = .{0} ** 64;
        var stream = std.io.fixedBufferStream(&buf);
        var writer = stream.writer().any();
        hashComponent(&writer, s.user);
        hashComponent(&writer, s.password);
        hashComponent(&writer, s.host);
        hashComponent(&writer, s.path);
        hashComponent(&writer, s.query);
        hashComponent(&writer, s.fragment);
        return std.hash.Wyhash.hash(0, &buf);
    }
    pub fn eql(self: @This(), a: Uri, b: Uri) bool {
        _ = self;
        return uriEql(a, b);
    }
};

pub fn UriHashMap(comptime V: type) type {
    return std.HashMap(Uri, V, UriContext, default_max_load_percentage);
}

test "UriHashMap" {
    var map = UriHashMap(i32).init(std.testing.allocator);
    defer map.deinit();

    const uri = try Uri.parse("https://google.com/search?q=zig#fragment");
    try map.put(uri, 1);
    try std.testing.expectEqual(map.get(uri), 1);

    const uri1 = try Uri.parse("https://google.com/search?q=zig#fragment");
    try std.testing.expectEqual(map.get(uri1), 1);

    const uri2 = try Uri.parse("https://google.com/search?q=rust#fragment");
    try map.put(uri2, 2);
    try std.testing.expectEqual(map.get(uri2), 2);
}

// Configures text that is injected into the view without changing the underlying document.
pub const InjectedTextOptions = struct {
    // Sets the text to inject. Must be a single line.
    content: []const u8,

    // @internal
    // tokens: ?[]TokenArray,

    // If set, the decoration will be rendered inline with the text with this CSS class name.
    inlineClassName: ?[]const u8,

    // If there is an `inlineClassName` which affects letter spacing.
    inlineClassNameAffectsLetterSpacing: bool,

    // This field allows to attach data to this injected text.
    // The data can be read when injected texts at a given position are queried.
    attachedData: ?*anyopaque,

    // Configures cursor stops around injected text.
    // Defaults to {@link InjectedTextCursorStops.Both}.
    cursorStops: ?InjectedTextCursorStops,
};

pub const InjectedTextCursorStops = enum {
    Both,
    Right,
    Left,
    None,
};

// Vertical Lane in the overview ruler of the editor.
pub const OverviewRulerLane = enum(u3) {
    Left = 1,
    Center = 2,
    Right = 4,
    Full = 7,
};

// Vertical Lane in the glyph margin of the editor.
pub const GlyphMarginLane = enum(u2) {
    Left = 1,
    Center = 2,
    Right = 3,
};

// Position in the minimap to render the decoration.
pub const MinimapPosition = enum(u2) {
    Inline = 1,
    Gutter = 2,
};

// Section header style.
pub const MinimapSectionHeaderStyle = enum(u2) {
    Normal = 1,
    Underlined = 2,
};

// Options for rendering a model decoration in the overview ruler.
pub const ModelDecorationOverviewRulerOptions = struct {
    // The position in the overview ruler.
    position: OverviewRulerLane,
};

// Options for rendering a model decoration in the minimap.
pub const ModelDecorationMinimapOptions = struct {
    // The position in the minimap.
    position: MinimapPosition,
    // If the decoration is for a section header, which header style.
    sectionHeaderStyle: ?MinimapSectionHeaderStyle,
    // If the decoration is for a section header, the header text.
    sectionHeaderText: ?[]u8,
};

pub const ModelDecorationGlyphMarginOptions = struct {
    // The position in the glyph margin.
    position: GlyphMarginLane,

    // Whether the glyph margin lane in {@link position} should be rendered even
    // outside of this decoration's range.
    persistLane: ?bool,
};

// Options for a model decoration.
pub const ModelDecorationOptions = struct {
    // A debug description that can be used for inspecting model decorations.
    // @internal
    description: []const u8,
    // Customize the growing behavior of the decoration when typing at the edges of the decoration.
    // Defaults to TrackedRangeStickiness.AlwaysGrowsWhenTypingAtEdges
    stickiness: ?TrackedRangeStickiness,
    // CSS class name describing the decoration.
    className: ?[]const u8,
    // Indicates whether the decoration should span across the entire line when it continues onto the next line.
    shouldFillLineOnLineBreak: ?bool,
    blockClassName: ?[]const u8,
    // Indicates if this block should be rendered after the last line.
    // In this case, the range must be empty and set to the last line.
    blockIsAfterEnd: ?bool,
    blockDoesNotCollapse: ?bool,
    blockPadding: ?[4]usize,
    // Message to be rendered when hovering over the glyph margin decoration.
    glyphMarginHoverMessage: ?[]const u8,
    // Array of MarkdownString to render as the decoration message.
    hoverMessage: ?[]const u8,
    // Array of MarkdownString to render as the line number message.
    lineNumberHoverMessage: ?[]const u8,
    // Should the decoration expand to encompass a whole line.
    isWholeLine: ?bool,
    // Always render the decoration (even when the range it encompasses is collapsed).
    showIfCollapsed: ?bool,
    // Collapse the decoration if its entire range is being replaced via an edit.
    // @internal
    collapseOnReplaceEdit: ?bool,
    // Specifies the stack order of a decoration.
    // A decoration with greater stack order is always in front of a decoration with
    // a lower stack order when the decorations are on the same line.
    zIndex: ?usize,
    // If set, render this decoration in the overview ruler.
    overviewRuler: ?ModelDecorationOverviewRulerOptions,
    // If set, render this decoration in the minimap.
    minimap: ?ModelDecorationMinimapOptions,
    // If set, the decoration will be rendered in the glyph margin with this CSS class name.
    glyphMarginClassName: ?[]const u8,
    // If set and the decoration has {@link glyphMarginClassName} set, render this decoration
    // with the specified {@link IModelDecorationGlyphMarginOptions} in the glyph margin.
    glyphMargin: ?ModelDecorationGlyphMarginOptions,
    // If set, the decoration will override the line height of the lines it spans. Maximum value is 300px.
    lineHeight: ?usize,
    // If set, the decoration will be rendered in the lines decorations with this CSS class name.
    linesDecorationsClassName: ?[]const u8,
    // Controls the tooltip text of the line decoration.
    linesDecorationsTooltip: ?[]const u8,
    // If set, the decoration will be rendered on the line number.
    lineNumberClassName: ?[]const u8,
    // If set, the decoration will be rendered in the lines decorations with
    firstLineDecorationClassName: ?[]const u8,
    // If set, the decoration will be rendered in the margin (covering its full width) with this CSS class name.
    marginClassName: ?[]const u8,
    // If set, the decoration will be rendered inline with the text with this CSS class name.
    // Please use this only for CSS rules that must impact the text. For example, use `className`
    // to have a background color decoration.
    inlineClassName: ?[]const u8,
    // If there is an `inlineClassName` which affects letter spacing.
    inlineClassNameAffectsLetterSpacing: ?bool,
    // If set, the decoration will be rendered before the text with this CSS class name.
    beforeContentClassName: ?[]const u8,
    // If set, the decoration will be rendered after the text with this CSS class name.
    afterContentClassName: ?[]const u8,
    // If set, text will be injected in the view after the range.
    after: ?InjectedTextOptions,
    // If set, text will be injected in the view before the range.
    before: ?InjectedTextOptions,
    // If set, this decoration will not be rendered for comment tokens.
    // @internal
    hideInCommentTokens: ?bool,
    // If set, this decoration will not be rendered for string tokens.
    // @internal
    hideInStringTokens: ?bool,
};

// A decoration in the model.
pub const ModelDecoration = struct {
    // Identifier for a decoration.
    id: []const u8,
    // Identifier for a decoration's owner.
    ownerId: usize,
    // Range that this decoration covers.
    range: Range,
    // Options associated with this decoration.
    options: ModelDecorationOptions,
};

// New model decorations.
pub const ModelDeltaDecoration = struct {
    // Range that this decoration covers.
    range: Range,
    // Options associated with this decoration.
    options: ModelDecorationOptions,
};
