// Port of `vscode-textmate/src/debug.ts`
// (microsoft/vscode-textmate v9.3.2).
//
// The upstream flags are read from `process.env.VSCODE_TEXTMATE_DEBUG` at
// module load. This package exposes the flags as ordinary Zig variables so
// hosts/tests can set them without process environment globals.
pub const DebugFlags = struct {
    pub var in_debug_mode: bool = false;
};

/// Kept for parity with the upstream option constant. The Zig port always
/// resolves anchors itself (`compileAG`), like upstream's default path.
pub const use_oniguruma_find_options: bool = false;
