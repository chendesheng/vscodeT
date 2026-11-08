// Configuration options for auto indentation in the editor
pub const EditorAutoIndentStrategy = enum(u8) { None = 0, Keep = 1, Brackets = 2, Advanced = 3, Full = 4 };

// Configuration options for auto-surround behavior.
pub const EditorAutoSurroundStrategy = enum(u8) { never = 0, languageDefined = 1, quotes = 2, brackets = 3 };
