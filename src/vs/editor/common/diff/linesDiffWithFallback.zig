// Port of `src/vs/editor/common/diff/linesDiffWithFallback.ts`.
//
// The TypeScript version is asynchronous because a diff backend may have to be
// loaded first. This port resolves the backend synchronously and therefore
// exposes a synchronous `computeDiff`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const document_diff_provider = @import("documentDiffProvider.zig");
const lines_diff_computer = @import("linesDiffComputer.zig");
const lines_diff_computers = @import("linesDiffComputers.zig");
const verify_lines_diff = @import("verifyLinesDiff.zig");

pub const DiffFallbackReason = document_diff_provider.DiffFallbackReason;
pub const LinesDiffValidity = verify_lines_diff.LinesDiffValidity;
pub const DiffAlgorithmName = lines_diff_computers.DiffAlgorithmName;
pub const ILinesDiffComputer = lines_diff_computer.ILinesDiffComputer;
pub const ILinesDiffComputerOptions = lines_diff_computer.ILinesDiffComputerOptions;
pub const LinesDiff = lines_diff_computer.LinesDiff;
pub const verifyLinesDiff = verify_lines_diff.verifyLinesDiff;

pub const ILinesDiffWithFallback = struct {
    result: LinesDiff,
    validity: ?LinesDiffValidity,
    fallback: ?DiffFallbackReason,

    pub fn deinit(self: *ILinesDiffWithFallback) void {
        self.result.deinit();
    }
};

pub const LinesDiffWithFallbackComputer = struct {
    context: *anyopaque,
    computeFn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        options: ILinesDiffComputerOptions,
        verify: bool,
    ) anyerror!ILinesDiffWithFallback,

    /// Computes a diff, falling back to the built-in algorithm when the
    /// requested (package based) algorithm fails or produces an invalid diff.
    pub fn computeDiff(
        self: LinesDiffWithFallbackComputer,
        allocator: Allocator,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        options: ILinesDiffComputerOptions,
        verify: bool,
    ) !ILinesDiffWithFallback {
        return self.computeFn(self.context, allocator, original_lines, modified_lines, options, verify);
    }
};

/// Resolves a diff algorithm to an `ILinesDiffComputer`.
pub const LinesDiffComputerResolver = struct {
    context: *anyopaque,
    resolveFn: *const fn (context: *anyopaque, algorithm: DiffAlgorithmName) anyerror!ILinesDiffComputer,

    pub fn resolve(self: LinesDiffComputerResolver, algorithm: DiffAlgorithmName) !ILinesDiffComputer {
        return self.resolveFn(self.context, algorithm);
    }
};

fn computeBuiltin(
    allocator: Allocator,
    original_lines: []const []const u8,
    modified_lines: []const []const u8,
    options: ILinesDiffComputerOptions,
    verify: bool,
    fallback: DiffFallbackReason,
) !ILinesDiffWithFallback {
    var default_computer = lines_diff_computers.getDefault();
    const interface = default_computer.asLinesDiffComputer();
    var result = try interface.computeDiff(allocator, original_lines, modified_lines, options);
    errdefer result.deinit();

    const validity: ?LinesDiffValidity = if (verify)
        verifyLinesDiff(allocator, result, original_lines, modified_lines, options.ignoreTrimWhitespace)
    else
        null;

    return .{ .result = result, .validity = validity, .fallback = fallback };
}

/// The resolved fallback computer; owns the selected `ILinesDiffComputer`
/// handle and therefore must outlive the computer returned by
/// `asComputer`.
pub const ResolvedLinesDiffComputer = struct {
    allocator: Allocator,
    isPackage: bool,
    computer: ?ILinesDiffComputer,

    /// Resolves the requested diff algorithm. Diffs from `@vscode/diff` are
    /// replaced by the built-in algorithm's diff if the package fails to load
    /// or throws, or if `verify` is set and the diff turns out to be invalid.
    pub fn init(
        allocator: Allocator,
        algorithm: DiffAlgorithmName,
        resolver: LinesDiffComputerResolver,
    ) !ResolvedLinesDiffComputer {
        const is_package = algorithm.isPackage();
        var computer: ?ILinesDiffComputer = null;
        if (resolver.resolve(algorithm)) |resolved| {
            computer = resolved;
        } else |err| {
            if (!is_package) {
                return err;
            }
            // The package failed to load; fall back to the built-in algorithm.
        }

        return .{ .allocator = allocator, .isPackage = is_package, .computer = computer };
    }

    pub fn deinit(self: *ResolvedLinesDiffComputer) void {
        _ = self;
    }

    pub fn asComputer(self: *ResolvedLinesDiffComputer) LinesDiffWithFallbackComputer {
        return .{ .context = self, .computeFn = computeDiffFallback };
    }

    fn computeDiffFallback(
        context: *anyopaque,
        allocator: Allocator,
        original_lines: []const []const u8,
        modified_lines: []const []const u8,
        options: ILinesDiffComputerOptions,
        verify: bool,
    ) anyerror!ILinesDiffWithFallback {
        const self: *ResolvedLinesDiffComputer = @ptrCast(@alignCast(context));

        const computer = self.computer orelse {
            return computeBuiltin(allocator, original_lines, modified_lines, options, verify, .@"error");
        };

        var result = computer.computeDiff(allocator, original_lines, modified_lines, options) catch |err| {
            if (!self.isPackage) {
                return err;
            }
            return computeBuiltin(allocator, original_lines, modified_lines, options, verify, .@"error");
        };
        errdefer result.deinit();

        const validity: ?LinesDiffValidity = if (verify)
            verifyLinesDiff(allocator, result, original_lines, modified_lines, options.ignoreTrimWhitespace)
        else
            null;

        if (self.isPackage and validity != null and validity.? == .invalid) {
            result.deinit();
            return computeBuiltin(allocator, original_lines, modified_lines, options, verify, .invalid);
        }

        return .{ .result = result, .validity = validity, .fallback = null };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestResolver = struct {
    var fail: bool = false;

    fn resolve(_: *anyopaque, algorithm: DiffAlgorithmName) anyerror!ILinesDiffComputer {
        if (fail) {
            return error.LoadFailed;
        }
        return lines_diff_computers.getBuiltin(algorithm) orelse error.NotAvailable;
    }
};

fn testResolver() LinesDiffComputerResolver {
    return .{ .context = @ptrCast(&TestResolver.fail), .resolveFn = TestResolver.resolve };
}

test "resolves the default computer" {
    const allocator = std.testing.allocator;

    TestResolver.fail = false;
    var resolved = try ResolvedLinesDiffComputer.init(allocator, .advanced, testResolver());
    defer resolved.deinit();

    const with_fallback = resolved.asComputer();
    const original = [_][]const u8{ "a", "b", "c" };
    const modified = [_][]const u8{ "a", "x", "c" };
    var result = try with_fallback.computeDiff(allocator, &original, &modified, .{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    }, true);
    defer result.deinit();

    try std.testing.expectEqual(@as(?DiffFallbackReason, null), result.fallback);
    try std.testing.expect(result.validity != null);
    try std.testing.expectEqual(@as(usize, 1), result.result.changes.len);
}

test "falls back to the built-in computer when the package fails to load" {
    const allocator = std.testing.allocator;

    TestResolver.fail = true;
    defer TestResolver.fail = false;

    var resolved = try ResolvedLinesDiffComputer.init(allocator, .advanced_wasm, testResolver());
    defer resolved.deinit();

    const with_fallback = resolved.asComputer();
    const original = [_][]const u8{ "a", "b" };
    const modified = [_][]const u8{ "a", "b", "c" };
    var result = try with_fallback.computeDiff(allocator, &original, &modified, .{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    }, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(?DiffFallbackReason, .@"error"), result.fallback);
    try std.testing.expectEqual(@as(?LinesDiffValidity, null), result.validity);
    try std.testing.expectEqual(@as(usize, 1), result.result.changes.len);
}

test "propagates errors for built-in algorithms" {
    const allocator = std.testing.allocator;

    TestResolver.fail = true;
    defer TestResolver.fail = false;

    try std.testing.expectError(
        error.LoadFailed,
        ResolvedLinesDiffComputer.init(allocator, .legacy, testResolver()),
    );
}
