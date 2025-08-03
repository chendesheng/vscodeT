const std = @import("std");
pub const PromiseState = enum {
    pending,
    fulfilled,
    rejected,
};

pub fn Promise(comptime T: type) type {
    return struct {
        _lock: std.Thread.Mutex = std.Thread.Mutex.init(),
        _state: PromiseState = .pending,
        _value: ?T = null,

        pub fn init(executor: fn (resolve: *const fn (value: T) void, reject: *const fn (reason: anyerror) void) void) Promise(T) {
            std.Thread.spawn(.{}, struct {
                fn run() void {
                    const funcs = struct {
                        fn resolve(value: T) void {
                            _ = value;
                        }

                        fn reject(reason: anyerror) void {
                            _ = reason;
                        }
                    };
                    executor(&funcs.resolve, &funcs.reject);
                }
            }.run);
            return Promise(T){};
        }
    };
}
