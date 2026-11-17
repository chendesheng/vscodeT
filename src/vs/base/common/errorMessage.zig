// Port of `src/vs/base/common/errorMessage.ts` (the error-message subset).
//
// Terminal adaptation: there is no JS `Error` prototype chain and no
// `unknown`. Callers pass an `ErrorLike` value; the object variant carries the
// `message`, `stack`, `stacktrace` and `code`/`errno`/`syscall` fields the
// upstream helpers read. A native `Error` is marked with `is_native_error`,
// which is the terminal equivalent of `instanceof Error` (used by the
// unexpected-error handler to keep native stacks for debugger source mapping).
// Upstream's `stack` may also be an array of lines; join it before passing it
// in. `nls.localize` strings use the English originals. Every returned string
// is owned by the caller.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const default_message = "An unknown error occurred. Please consult the log for more details.";

pub const ErrorObject = struct {
    message: []const u8 = "",
    stack: ?[]const u8 = null,
    stacktrace: ?[]const u8 = null,
    code: ?[]const u8 = null,
    errno: ?i64 = null,
    syscall: ?[]const u8 = null,
    detail: ?Detail = null,
    /// Terminal analogue of `error instanceof Error`.
    is_native_error: bool = false,

    pub const Detail = struct {
        error_value: ?*const ErrorObject = null,
        exception: ?*const ErrorObject = null,
    };
};

pub const ErrorLike = union(enum) {
    /// Upstream `null`/`undefined`/other falsy values.
    none,
    string: []const u8,
    object: *const ErrorObject,
    list: []const ErrorLike,
};

/// Upstream `toErrorMessage(error, verbose)`.
pub fn toErrorMessage(allocator: Allocator, value: ErrorLike, verbose: bool) Allocator.Error![]u8 {
    return switch (value) {
        .none => allocator.dupe(u8, default_message),
        .string => |text| allocator.dupe(u8, text),
        .list => |errors| listToErrorMessage(allocator, errors, verbose),
        .object => |object| objectToErrorMessage(allocator, object, verbose),
    };
}

/// Upstream `arrays.coalesce` drops the falsy entries before the first error is
/// formatted; the remaining count is what the "N errors in total" suffix uses.
fn listToErrorMessage(allocator: Allocator, errors: []const ErrorLike, verbose: bool) Allocator.Error![]u8 {
    var count: usize = 0;
    var first: ?ErrorLike = null;
    for (errors) |error_value| {
        if (error_value == .none) continue;
        if (first == null) first = error_value;
        count += 1;
    }

    const message = try toErrorMessage(allocator, first orelse .none, verbose);
    if (count > 1) {
        defer allocator.free(message);
        return std.fmt.allocPrint(allocator, "{s} ({d} errors in total)", .{ message, count });
    }
    return message;
}

fn objectToErrorMessage(allocator: Allocator, object: *const ErrorObject, verbose: bool) Allocator.Error![]u8 {
    if (object.detail) |detail| {
        if (detail.error_value) |inner| {
            return exceptionToErrorMessage(allocator, inner, verbose);
        }
        if (detail.exception) |inner| {
            return exceptionToErrorMessage(allocator, inner, verbose);
        }
    }

    if (object.stack != null) {
        return exceptionToErrorMessage(allocator, object, verbose);
    }

    if (object.message.len > 0) {
        return allocator.dupe(u8, object.message);
    }

    return allocator.dupe(u8, default_message);
}

fn exceptionToErrorMessage(allocator: Allocator, exception: *const ErrorObject, verbose: bool) Allocator.Error![]u8 {
    // Upstream uses `stackToString(exception.stack) || stackToString(exception.stacktrace)`,
    // so an empty stack falls through to the stacktrace.
    const stack = if (exception.stack) |value| (if (value.len > 0) value else null) else null;
    const stacktrace = if (exception.stacktrace) |value| (if (value.len > 0) value else null) else null;
    const chosen = stack orelse stacktrace;

    if (verbose and chosen != null) {
        const detected = try detectSystemErrorMessage(allocator, exception);
        defer allocator.free(detected);
        return std.fmt.allocPrint(allocator, "{s}: {s}", .{ detected, chosen.? });
    }

    return detectSystemErrorMessage(allocator, exception);
}

fn detectSystemErrorMessage(allocator: Allocator, exception: *const ErrorObject) Allocator.Error![]u8 {
    // Custom node.js error from us.
    if (exception.code) |code| {
        if (std.mem.eql(u8, code, "ERR_UNC_HOST_NOT_ALLOWED")) {
            return std.fmt.allocPrint(
                allocator,
                "{s}. Please update the 'security.allowedUNCHosts' setting if you want to allow this host.",
                .{exception.message},
            );
        }
    }

    // See https://nodejs.org/api/errors.html#errors_class_system_error
    if (exception.code != null and exception.errno != null and exception.syscall != null) {
        return std.fmt.allocPrint(allocator, "A system error occurred ({s})", .{exception.message});
    }

    if (exception.message.len > 0) {
        return allocator.dupe(u8, exception.message);
    }

    return allocator.dupe(u8, default_message);
}

test "toErrorMessage formats strings, stacks and system errors" {
    const allocator = std.testing.allocator;

    const empty = try toErrorMessage(allocator, .none, false);
    defer allocator.free(empty);
    try std.testing.expectEqualStrings(default_message, empty);

    const text = try toErrorMessage(allocator, .{ .string = "Error text" }, false);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Error text", text);

    const error_object = ErrorObject{
        .message = "Unexpected error",
        .stack = "Error: Unexpected error\n    at file.js:1:2",
        .is_native_error = true,
    };
    const plain = try toErrorMessage(allocator, .{ .object = &error_object }, false);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("Unexpected error", plain);

    const verbose = try toErrorMessage(allocator, .{ .object = &error_object }, true);
    defer allocator.free(verbose);
    try std.testing.expectEqualStrings("Unexpected error: Error: Unexpected error\n    at file.js:1:2", verbose);

    // `detectSystemErrorMessage` is reached through the stack/detail path; a
    // plain object without a stack just returns its message (as upstream).
    const system_error = ErrorObject{
        .message = "ENOENT: no such file",
        .stack = "Error: ENOENT: no such file",
        .code = "ENOENT",
        .errno = -2,
        .syscall = "open",
    };
    const system = try toErrorMessage(allocator, .{ .object = &system_error }, false);
    defer allocator.free(system);
    try std.testing.expectEqualStrings("A system error occurred (ENOENT: no such file)", system);
}

test "toErrorMessage coalesces lists and unwraps details" {
    const allocator = std.testing.allocator;

    const first = ErrorObject{ .message = "First error" };
    const second = ErrorObject{ .message = "Second error" };
    const list = try toErrorMessage(
        allocator,
        .{ .list = &.{ .{ .object = &first }, .none, .{ .object = &second } } },
        false,
    );
    defer allocator.free(list);
    try std.testing.expectEqualStrings("First error (2 errors in total)", list);

    const nested = ErrorObject{ .message = "Nested error" };
    const detail_object = ErrorObject{
        .detail = .{ .exception = &nested },
    };
    const detail = try toErrorMessage(allocator, .{ .object = &detail_object }, false);
    defer allocator.free(detail);
    try std.testing.expectEqualStrings("Nested error", detail);

    const single = try toErrorMessage(allocator, .{ .list = &.{.{ .object = &first }} }, false);
    defer allocator.free(single);
    try std.testing.expectEqualStrings("First error", single);
}
