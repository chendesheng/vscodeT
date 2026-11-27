// Strict reference-cassette conformance tests.
//
// This is a separate test binary from `src/tests.zig` so the corpus runs as
// its own CI lane. Both engine lanes are expected to stay green.
comptime {
    _ = @import("./vs/editor/test/common/oracleCassette.zig");
    _ = @import("./vs/editor/contrib/vim/test/browser/vimCassette.test.zig");
    _ = @import("./vs/editor/contrib/helix/test/browser/helixCassette.test.zig");
}
