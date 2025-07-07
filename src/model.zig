const std = @import("std");
const Range = @import("range.zig").Range;
const TextChange = @import("textChange.zig").TextChange;
const ArrayList = @import("std").ArrayList;

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
