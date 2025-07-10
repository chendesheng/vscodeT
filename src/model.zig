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

pub const IndentSizeKind = enum {
    number,
    tabSize,
};

pub const IndentSize = union(IndentSizeKind) {
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
