// Port of ServiceIdentifier and ServicesAccessor from
// `src/vs/platform/instantiation/common/instantiation.ts`.
// Zig service identifiers carry their interface type at compile time.
pub fn ServiceIdentifier(comptime T: type, comptime name: []const u8) type {
    return struct {
        pub const Value = T;
        pub const id = name;
    };
}

pub const ServicesAccessor = struct {
    context: *anyopaque,
    scope: usize,
    resolve: *const fn (*anyopaque, usize, []const u8, []const u8) anyerror!*anyopaque,

    pub fn get(self: ServicesAccessor, comptime Id: type) !*Id.Value {
        return @ptrCast(@alignCast(try self.resolve(self.context, self.scope, Id.id, @typeName(Id.Value))));
    }
};
