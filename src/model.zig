const Range = @import("range.zig").Range;

pub const EndOfLinePreference = enum {
    TextDefined,
    LF,
    CRLF,
};

pub const SingleEditOperationIdentifier = struct {
    major: i64,
    minor: i64,
};

pub const ValidAnnotatedEditOperation = struct {
    identifier: ?SingleEditOperationIdentifier,
    range: Range,
    text: ?[]const u8,
    forceMoveMarkers: bool,
    isAutoWhitespaceEdit: bool,
    _isTracked: bool,
};

pub const InternalModelContentChange = struct {
    range: Range,
    rangeOffset: usize,
    rangeLength: usize,
    text: []const u8,
    forceMoveMarkers: bool,
};

pub const ApplyEditsResult = struct {
    reverseEdits: ?[]const ValidAnnotatedEditOperation,
    changes: []const InternalModelContentChange,
    trimAutoWhitespaceLineNumbers: ?[]const usize,
};
