// Port of the cancellation parts of `src/vs/base/common/errors.ts`.
const std = @import("std");

/// Error returned when an operation observes that it has been cancelled.
pub const CancellationError = error{CancellationError};

/// Returns whether the given error indicates cancellation.
pub fn isCancellationError(err: anyerror) bool {
    return err == error.CancellationError;
}

test "CancellationError" {
    const result: CancellationError!u8 = error.CancellationError;
    try std.testing.expectError(error.CancellationError, result);
    try std.testing.expect(isCancellationError(error.CancellationError));
    try std.testing.expect(!isCancellationError(error.OutOfMemory));
}
