// Strict reference-cassette conformance tests.
//
// This is a separate test binary from `src/tests.zig`: the cassette suite is
// expected to expose engine divergences, and its CI job is allowed to fail
// until those are fixed. Normal editor tests stay green.
comptime {
    _ = @import("./vs/editor/test/common/oracleCassette.zig");
    _ = @import("./vs/editor/contrib/vim/test/browser/vimCassette.test.zig");
    _ = @import("./vs/editor/contrib/helix/test/browser/helixCassette.test.zig");
}
