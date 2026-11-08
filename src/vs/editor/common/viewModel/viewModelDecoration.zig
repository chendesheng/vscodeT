const Range = @import("../core/range.zig").Range;
const TextModel = @import("../model/textModel.zig").TextModel;
const ModelDecoration = @import("../model.zig").ModelDecoration;
const ModelDecorationOptions = @import("../model.zig").ModelDecorationOptions;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;

pub const ViewModelDecoration = struct {
    range: Range,
    options: *const ModelDecorationOptions,

    pub fn init(range: Range, options: *const ModelDecorationOptions) ViewModelDecoration {
        return .{ .range = range, .options = options };
    }
};

pub fn isModelDecorationVisible(model: *TextModel, decoration: ModelDecoration) !bool {
    if (decoration.options.hideInCommentTokens orelse false) {
        if (try isModelDecorationInComment(model, decoration)) return false;
    }
    if (decoration.options.hideInStringTokens orelse false) {
        if (try isModelDecorationInString(model, decoration)) return false;
    }
    return true;
}

pub fn isModelDecorationInComment(model: *TextModel, decoration: ModelDecoration) !bool {
    return testTokensInRange(model, decoration.range, .Comment);
}

pub fn isModelDecorationInString(model: *TextModel, decoration: ModelDecoration) !bool {
    return testTokensInRange(model, decoration.range, .String);
}

fn testTokensInRange(model: *TextModel, range: Range, expected: StandardTokenType) !bool {
    var lineNumber = range.startLineNumber;
    while (lineNumber <= range.endLineNumber) : (lineNumber += 1) {
        var lineTokens = try model.tokenization().getLineTokens(lineNumber);
        defer lineTokens.deinit();

        const isFirstLine = lineNumber == range.startLineNumber;
        const isEndLine = lineNumber == range.endLineNumber;

        var tokenIndex: usize = if (isFirstLine)
            lineTokens.findTokenIndexAtOffset(range.startColumn - 1)
        else
            0;

        while (tokenIndex < lineTokens.getCount()) {
            if (isEndLine and lineTokens.getStartOffset(tokenIndex) > range.endColumn - 1) {
                break;
            }
            if (lineTokens.getStandardTokenType(tokenIndex) != expected) {
                return false;
            }
            tokenIndex += 1;
        }
    }
    return true;
}
