const Range = @import("range.zig").Range;
const TextChange = @import("textChange.zig").TextChange;

pub const EOL = enum {
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

pub const ReverseSingleEditOperation = struct {
    sortIndex: i64,
    identifier: ?SingleEditOperationIdentifier,
    range: Range,
    text: []const u8,
    textChange: TextChange,
};

pub const ApplyEditsResult = struct {
    reverseEdits: ?[]const ReverseSingleEditOperation,
    changes: []const InternalModelContentChange,
    trimAutoWhitespaceLineNumbers: ?[]const usize,
};
