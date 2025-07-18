pub fn usizeSub(a: usize, b: usize) isize {
    return @as(isize, @intCast(a)) - @as(isize, @intCast(b));
}

pub fn usizeAdd(a: usize, b: isize) usize {
    return @intCast(@as(isize, @intCast(a)) + b);
}
