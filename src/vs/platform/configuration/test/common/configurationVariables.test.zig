// Port of `src/vs/platform/configuration/test/common/configurationVariables.test.ts`.
// The performance cases assert correctness for 64 KiB inputs; the wall-clock
// budget is not asserted in Zig.
const std = @import("std");
const variables = @import("../../common/configurationVariables.zig");

fn expectAll(values: []const []const u8, expected: bool) !void {
    for (values) |value| {
        try std.testing.expectEqual(expected, variables.hasConfigurationVariable(value));
    }
}

test "recognizes complete variables, including empty expressions" {
    try expectAll(&.{
        "${name}",
        "${env:PATH}",
        "${}",
        "${:}",
        "${input:}",
        "${command:name:argument}",
        "before ${name} after",
        "${one}${two}",
        "$${name}",
        "\\${name}",
    }, true);
}

test "recognizes nested ordinary braces and variables" {
    try expectAll(&.{
        "${{}}",
        "${{{name}}}",
        "${command:name{argument}tail}",
        "${outer:${inner}}",
        "${outer:{${inner:{argument}}}}",
    }, true);
}

test "leaves incomplete markers and ordinary braces literal" {
    try expectAll(&.{
        "",
        "literal",
        "$",
        "{name}",
        "$ {name}",
        "${",
        "${name",
        "${name{}",
        "${{name}",
        "${{{}}",
        "${outer:{inner}{tail}",
        "}${",
        "}${{name}",
    }, false);
}

test "finds complete inner variables after incomplete outer expressions" {
    try expectAll(&.{
        "${outer ${inner}",
        "${outer:{${inner}",
        "${${}",
        "${${name{}}",
        "${outer ${incomplete ${env:PATH} trailing ${",
    }, true);
}

test "ignores unmatched braces outside complete variables" {
    try expectAll(&.{
        "}${name}",
        "${name}{",
        "${name}}",
        "{${name}{",
        "${name} trailing ${",
    }, true);
}

fn checkAgreement(value: []const u8, remaining: usize, mismatches: *std.array_list.Managed([]const u8), allocator: std.mem.Allocator) !void {
    var expected = false;
    var offset: usize = 0;
    while (offset < value.len) : (offset += 1) {
        if (variables.parseConfigurationVariable(value, offset) != null) {
            expected = true;
            break;
        }
    }
    if (variables.hasConfigurationVariable(value) != expected) {
        try mismatches.append(try allocator.dupe(u8, value));
    }
    if (remaining > 0) {
        for ("${}a:") |character| {
            const extended = try std.fmt.allocPrint(allocator, "{s}{c}", .{ value, character });
            defer allocator.free(extended);
            try checkAgreement(extended, remaining - 1, mismatches, allocator);
        }
    }
}

test "agrees with the parser on all short brace expressions" {
    const allocator = std.testing.allocator;
    var mismatches = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (mismatches.items) |value| allocator.free(value);
        mismatches.deinit();
    }
    try checkAgreement("", 6, &mismatches, allocator);
    try std.testing.expectEqual(@as(usize, 0), mismatches.items.len);
}

test "scans 64 KiB of incomplete markers" {
    const allocator = std.testing.allocator;
    const value = try allocator.alloc(u8, 2 * 32 * 1024);
    defer allocator.free(value);
    for (0..32 * 1024) |index| {
        value[index * 2] = '$';
        value[index * 2 + 1] = '{';
    }
    try std.testing.expect(!variables.hasConfigurationVariable(value));

    const with_suffix = try std.mem.concat(allocator, u8, &.{ value, "${env:PATH}" });
    defer allocator.free(with_suffix);
    try std.testing.expect(variables.hasConfigurationVariable(with_suffix));
}
