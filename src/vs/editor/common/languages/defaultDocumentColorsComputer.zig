// Port of `src/vs/editor/common/languages/defaultDocumentColorsComputer.ts`.
//
// Divergences from the TypeScript module:
//
//  * The target is a "struct of function pointers" with an explicit `context`
//    instead of an interface. `findMatches` is not part of it: the computer
//    scans `getValue()` itself, because this port has no shared
//    `findMatches(regex)` helper on text models.
//  * `_parseCaptureGroups` returns numbers as `f64`, since CSS Level 4 allows
//    fractional hue/saturation/alpha values.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const color_module = @import("../../../base/common/color.zig");
const Color = color_module.Color;
const HSLA = color_module.HSLA;

const position_module = @import("../core/position.zig");
const Position = position_module.Position;
const range_module = @import("../core/range.zig");
const Range = range_module.Range;

const languages = @import("../languages.zig");
const IColor = languages.IColor;
const IColorInformation = languages.IColorInformation;

const regexp = @import("../../../../support/regexp.zig");
const RegExp = regexp.RegExp;

/// The document the colors are computed for.
pub const IDocumentColorComputerTarget = struct {
    context: *anyopaque,
    /// Returns the full document text. Owned by the caller.
    getValue: *const fn (context: *anyopaque, allocator: Allocator) anyerror![]u8,
    /// Returns the position of `offset` (a byte offset) in the document.
    positionAt: *const fn (context: *anyopaque, offset: usize) Position,
};

fn toIColor(r: f64, g: f64, b: f64, a: f64) IColor {
    return .{
        .red = @floatCast(r / 255),
        .green = @floatCast(g / 255),
        .blue = @floatCast(b / 255),
        .alpha = @floatCast(a),
    };
}

fn findRange(model: IDocumentColorComputerTarget, index: usize, length: usize) Range {
    const start_position = model.positionAt(model.context, index);
    return Range.init(
        start_position.lineNumber,
        start_position.column,
        start_position.lineNumber,
        start_position.column + length,
    );
}

fn findHexColorInformation(range: Range, hex_value: []const u8) ?IColorInformation {
    const parsed_hex_color = Color.fromHex(hex_value) catch return null;
    return .{
        .range = range,
        .color = toIColor(
            @floatFromInt(parsed_hex_color.r),
            @floatFromInt(parsed_hex_color.g),
            @floatFromInt(parsed_hex_color.b),
            parsed_hex_color.a,
        ),
    };
}

/// Parses the capture groups of `match` into numbers, skipping the groups that
/// are not numbers (e.g. the full match). A group that parses to zero is kept
/// unless it is only whitespace.
fn parseCaptureGroups(allocator: Allocator, match: regexp.SearchResult) !ArrayList(f64) {
    var values = ArrayList(f64).init(allocator);
    errdefer values.deinit();

    var group_index: usize = 0;
    while (group_index < match.numberOfGroups()) : (group_index += 1) {
        const group = match.groupNOrNull(group_index) orelse continue;
        const parsed_number = std.fmt.parseFloat(f64, std.mem.trim(u8, group, " \t\r\n")) catch continue;
        var without_whitespace = ArrayList(u8).init(allocator);
        defer without_whitespace.deinit();
        for (group) |character| {
            if (!std.ascii.isWhitespace(character)) {
                try without_whitespace.append(character);
            }
        }
        const is_truthy = parsed_number != 0 or (parsed_number == 0 and without_whitespace.items.len != 0);
        if (is_truthy) {
            try values.append(parsed_number);
        }
    }
    return values;
}

fn findRGBColorInformation(
    allocator: Allocator,
    range: Range,
    parameters: []const u8,
    parameters_regex: *const RegExp,
    is_alpha: bool,
) !?IColorInformation {
    var iterator = parameters_regex.searchIterator(parameters, 0);
    const first_match = iterator.next() orelse return null;
    defer first_match.deinit();
    if (iterator.next() != null) {
        return null;
    }

    var parsed_regex = try parseCaptureGroups(allocator, first_match);
    defer parsed_regex.deinit();
    if (parsed_regex.items.len < (if (is_alpha) @as(usize, 4) else @as(usize, 3))) {
        return null;
    }

    return .{
        .range = range,
        .color = toIColor(
            parsed_regex.items[0],
            parsed_regex.items[1],
            parsed_regex.items[2],
            if (is_alpha) parsed_regex.items[3] else 1,
        ),
    };
}

fn findHSLColorInformation(
    allocator: Allocator,
    range: Range,
    parameters: []const u8,
    parameters_regex: *const RegExp,
    is_alpha: bool,
) !?IColorInformation {
    var iterator = parameters_regex.searchIterator(parameters, 0);
    const first_match = iterator.next() orelse return null;
    defer first_match.deinit();
    if (iterator.next() != null) {
        return null;
    }

    var parsed_regex = try parseCaptureGroups(allocator, first_match);
    defer parsed_regex.deinit();
    if (parsed_regex.items.len < (if (is_alpha) @as(usize, 4) else @as(usize, 3))) {
        return null;
    }

    const color_equivalent = HSLA.init(
        @floatCast(parsed_regex.items[0]),
        @floatCast(parsed_regex.items[1] / 100),
        @floatCast(parsed_regex.items[2] / 100),
        if (is_alpha) @floatCast(parsed_regex.items[3]) else 1,
    ).toRGBA();

    return .{
        .range = range,
        .color = toIColor(
            @floatFromInt(color_equivalent.r),
            @floatFromInt(color_equivalent.g),
            @floatFromInt(color_equivalent.b),
            color_equivalent.a,
        ),
    };
}

const initial_validation_regex_pattern =
    "\\b(rgb|rgba|hsl|hsla)(\\([0-9\\s,.\\%\\/]*\\))" ++
    "|^(#)([A-Fa-f0-9]{3})\\b|^(#)([A-Fa-f0-9]{4})\\b|^(#)([A-Fa-f0-9]{6})\\b|^(#)([A-Fa-f0-9]{8})\\b" ++
    "|(?<=['\"\\s])(#)([A-Fa-f0-9]{3})\\b|(?<=['\"\\s])(#)([A-Fa-f0-9]{4})\\b" ++
    "|(?<=['\"\\s])(#)([A-Fa-f0-9]{6})\\b|(?<=['\"\\s])(#)([A-Fa-f0-9]{8})\\b";

const rgb_parameters_pattern =
    "^\\(\\s*(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\\s*[\\s,]\\s*(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\\s*[\\s,]\\s*(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\\s*\\)$";

const rgba_parameters_pattern =
    "^\\(\\s*(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\\s*[\\s,]\\s*(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\\s*[\\s,]\\s*(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\\s*(?:[\\s,]|[\\s]*\\/)\\s*(0[.][0-9]+|[.][0-9]+|[01][.]|[01])\\s*\\)$";

const hsl_parameters_pattern =
    "^\\(\\s*((?:360(?:\\.0+)?|(?:36[0]|3[0-5][0-9]|[12][0-9][0-9]|[1-9]?[0-9])(?:\\.\\d+)?))\\s*[\\s,]\\s*(100(?:\\.0+)?|\\d{1,2}[.]\\d*|\\d{1,2})%\\s*[\\s,]\\s*(100(?:\\.0+)?|\\d{1,2}[.]\\d*|\\d{1,2})%\\s*\\)$";

const hsla_parameters_pattern =
    "^\\(\\s*((?:360(?:\\.0+)?|(?:36[0]|3[0-5][0-9]|[12][0-9][0-9]|[1-9]?[0-9])(?:\\.\\d+)?))\\s*[\\s,]\\s*(100(?:\\.0+)?|\\d{1,2}[.]\\d*|\\d{1,2})%\\s*[\\s,]\\s*(100(?:\\.0+)?|\\d{1,2}[.]\\d*|\\d{1,2})%\\s*(?:[\\s,]|[\\s]*\\/)\\s*(0[.][0-9]+|[.][0-9]+|[01][.]0*|[01])\\s*\\)$";

fn computeColors(allocator: Allocator, model: IDocumentColorComputerTarget) !ArrayList(IColorInformation) {
    var result = ArrayList(IColorInformation).init(allocator);
    errdefer result.deinit();

    const value = try model.getValue(model.context, allocator);
    defer allocator.free(value);

    const initial_validation_regex = try RegExp.init(initial_validation_regex_pattern, .{});
    defer initial_validation_regex.deinit();

    const rgb_parameters_regex = try RegExp.init(rgb_parameters_pattern, .{});
    defer rgb_parameters_regex.deinit();
    const rgba_parameters_regex = try RegExp.init(rgba_parameters_pattern, .{});
    defer rgba_parameters_regex.deinit();
    const hsl_parameters_regex = try RegExp.init(hsl_parameters_pattern, .{});
    defer hsl_parameters_regex.deinit();
    const hsla_parameters_regex = try RegExp.init(hsla_parameters_pattern, .{});
    defer hsla_parameters_regex.deinit();

    var iterator = initial_validation_regex.searchIterator(value, 0);
    while (iterator.next()) |initial_match| {
        defer initial_match.deinit();

        // `initialMatch.filter(captureGroup => captureGroup !== undefined)` drops
        // the groups that did not participate in the match, so the remaining
        // ones are read in order.
        var defined_groups = ArrayList([]const u8).init(allocator);
        defer defined_groups.deinit();
        var group_index: usize = 0;
        while (group_index < initial_match.numberOfGroups()) : (group_index += 1) {
            if (initial_match.groupNOrNull(group_index)) |group| {
                try defined_groups.append(group);
            }
        }
        if (defined_groups.items.len < 3) {
            continue;
        }

        const color_scheme = defined_groups.items[1];
        const color_parameters = defined_groups.items[2];

        const range = findRange(model, initial_match.index(), initial_match.length());

        var color_information: ?IColorInformation = null;
        if (std.mem.eql(u8, color_scheme, "rgb")) {
            color_information = try findRGBColorInformation(allocator, range, color_parameters, &rgb_parameters_regex, false);
        } else if (std.mem.eql(u8, color_scheme, "rgba")) {
            color_information = try findRGBColorInformation(allocator, range, color_parameters, &rgba_parameters_regex, true);
        } else if (std.mem.eql(u8, color_scheme, "hsl")) {
            color_information = try findHSLColorInformation(allocator, range, color_parameters, &hsl_parameters_regex, false);
        } else if (std.mem.eql(u8, color_scheme, "hsla")) {
            color_information = try findHSLColorInformation(allocator, range, color_parameters, &hsla_parameters_regex, true);
        } else if (std.mem.eql(u8, color_scheme, "#")) {
            const hex_value = try std.mem.concat(allocator, u8, &.{ color_scheme, color_parameters });
            defer allocator.free(hex_value);
            color_information = findHexColorInformation(range, hex_value);
        }

        if (color_information) |information| {
            try result.append(information);
        }
    }

    return result;
}

/// Returns all default document colors in the provided document.
pub fn computeDefaultDocumentColors(
    allocator: Allocator,
    model: IDocumentColorComputerTarget,
) !ArrayList(IColorInformation) {
    return computeColors(allocator, model);
}

const TestTarget = struct {
    value: []const u8,

    fn getValue(context: *anyopaque, allocator: Allocator) anyerror![]u8 {
        const self: *TestTarget = @ptrCast(@alignCast(context));
        return allocator.dupe(u8, self.value);
    }

    fn positionAt(context: *anyopaque, offset: usize) Position {
        const self: *TestTarget = @ptrCast(@alignCast(context));
        var line_number: usize = 1;
        var column: usize = 1;
        for (self.value[0..@min(offset, self.value.len)]) |character| {
            if (character == '\n') {
                line_number += 1;
                column = 1;
            } else {
                column += 1;
            }
        }
        return Position.init(line_number, column);
    }

    fn interface(self: *TestTarget) IDocumentColorComputerTarget {
        return .{
            .context = self,
            .getValue = getValue,
            .positionAt = positionAt,
        };
    }
};

test "computeDefaultDocumentColors: finds hex colors" {
    const allocator = std.testing.allocator;

    var target = TestTarget{ .value = "color: #ff0000;" };
    var colors = try computeDefaultDocumentColors(allocator, target.interface());
    defer colors.deinit();

    try std.testing.expectEqual(@as(usize, 1), colors.items.len);
    try std.testing.expectEqual(@as(f32, 1), colors.items[0].color.red);
    try std.testing.expectEqual(@as(f32, 0), colors.items[0].color.green);
    try std.testing.expectEqual(@as(usize, 8), colors.items[0].range.startColumn);
    try std.testing.expectEqual(@as(usize, 15), colors.items[0].range.endColumn);
}

test "computeDefaultDocumentColors: finds the short hex forms" {
    const allocator = std.testing.allocator;

    var target = TestTarget{ .value = "#f00\n#f008" };
    var colors = try computeDefaultDocumentColors(allocator, target.interface());
    defer colors.deinit();

    try std.testing.expectEqual(@as(usize, 2), colors.items.len);
    try std.testing.expectEqual(@as(f32, 1), colors.items[0].color.red);
    try std.testing.expectApproxEqAbs(@as(f32, 0x88.0 / 255.0), colors.items[1].color.alpha, 1e-6);
}

test "computeDefaultDocumentColors: finds rgb and rgba" {
    const allocator = std.testing.allocator;

    var target = TestTarget{ .value = "rgb(255, 0, 0) rgba(0, 0, 255, 0.5)" };
    var colors = try computeDefaultDocumentColors(allocator, target.interface());
    defer colors.deinit();

    try std.testing.expectEqual(@as(usize, 2), colors.items.len);
    try std.testing.expectEqual(@as(f32, 1), colors.items[0].color.red);
    try std.testing.expectEqual(@as(f32, 0), colors.items[0].color.green);
    try std.testing.expectEqual(@as(f32, 1), colors.items[1].color.blue);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), colors.items[1].color.alpha, 1e-6);
}

test "computeDefaultDocumentColors: rejects out of range rgb values" {
    const allocator = std.testing.allocator;

    var target = TestTarget{ .value = "rgb(256, 0, 0)" };
    var colors = try computeDefaultDocumentColors(allocator, target.interface());
    defer colors.deinit();
    try std.testing.expectEqual(@as(usize, 0), colors.items.len);
}

test "computeDefaultDocumentColors: finds hsl and hsla" {
    const allocator = std.testing.allocator;

    var target = TestTarget{ .value = "hsl(0, 100%, 50%) hsla(240, 100%, 50%, 0.5)" };
    var colors = try computeDefaultDocumentColors(allocator, target.interface());
    defer colors.deinit();

    try std.testing.expectEqual(@as(usize, 2), colors.items.len);
    try std.testing.expectEqual(@as(f32, 1), colors.items[0].color.red);
    try std.testing.expectEqual(@as(f32, 0), colors.items[0].color.green);
    try std.testing.expectEqual(@as(f32, 1), colors.items[1].color.blue);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), colors.items[1].color.alpha, 1e-6);
}
