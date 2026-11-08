const std = @import("std");
pub const InputModeValue = enum { insert, overtype };

pub const InputMode = struct {
    var value: InputModeValue = .insert;

    pub fn get() InputModeValue {
        return value;
    }

    pub fn set(mode: InputModeValue) void {
        value = mode;
    }
};

test "inputMode: get and set" {
    InputMode.set(.overtype);
    try std.testing.expectEqual(InputModeValue.overtype, InputMode.get());
    InputMode.set(.insert);
    try std.testing.expectEqual(InputModeValue.insert, InputMode.get());
}
