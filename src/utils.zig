pub fn usizeSub(a: usize, b: usize) isize {
    return @as(isize, @intCast(a)) - @as(isize, @intCast(b));
}

pub fn usizeAdd(a: usize, b: isize) usize {
    return @intCast(@as(isize, @intCast(a)) + b);
}

pub fn Pair(comptime T1: type, comptime T2: type) type {
    return struct { first: T1, second: T2 };
}

pub fn pair(first: anytype, second: anytype) Pair(@TypeOf(first), @TypeOf(second)) {
    return Pair(@TypeOf(first), @TypeOf(second)){ .first = first, .second = second };
}
