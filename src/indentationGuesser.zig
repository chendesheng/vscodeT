const PieceTreeTextBuffer = @import("pieceTreeTextBuffer.zig").PieceTreeTextBuffer;

pub const GuessedIndentation = struct {
    tabSize: usize,
    insertSpaces: bool,
};

pub fn guessIndentation(source: PieceTreeTextBuffer, defaultTabSize: usize, defaultInsertSpaces: bool) GuessedIndentation {
    _ = source;

    return GuessedIndentation{
        .tabSize = defaultTabSize, // TODO@Alex: guess tabSize
        .insertSpaces = defaultInsertSpaces, // TODO@Alex: guess insertSpaces
    };
}
