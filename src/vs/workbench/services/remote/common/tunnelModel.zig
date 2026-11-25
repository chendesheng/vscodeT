// Port of parseAddress in src/vs/workbench/services/remote/common/tunnelModel.ts.
const std = @import("std");

pub const Address = struct { host: []const u8, port: u64 };

pub fn parseAddress(value: []const u8) ?Address {
    var host: []const u8 = "localhost";
    var digits = value;
    if (std.mem.indexOfScalar(u8, value, ':')) |separator| {
        host = value[0..separator];
        var labels = std.mem.splitScalar(u8, host, '.');
        while (labels.next()) |label| {
            if (label.len == 0) return null;
            for (label) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;
            }
        }
        digits = value[separator + 1 ..];
    }
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return .{ .host = host, .port = std.fmt.parseUnsigned(u64, digits, 10) catch std.math.maxInt(u64) };
}
