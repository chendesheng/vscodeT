// Terminal adaptation: stackful, thread-affine contexts for WindowIo. On POSIX
// use Zig's standard fiber context switch and a guarded stack; on Windows use
// native fibers, which also maintain the thread's stack bounds.
const std = @import("std");
const builtin = @import("builtin");
const windows = builtin.os.tag == .windows;
const Entry = *const fn (*anyopaque) noreturn;
// These fibers run the same editor/service call chains as native threads.
// In particular Windows' maximum-path buffers are much larger than POSIX
// ones. Reserve the standard Zig thread stack size (virtual memory; pages
// are committed as used), while retaining the OS guard page.
const stack_size = std.Thread.SpawnConfig.default_stack_size;
const fiber_flag_float_switch = 1;

extern "kernel32" fn ConvertThreadToFiberEx(?*anyopaque, u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn IsThreadAFiber() callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn ConvertFiberToThread() callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn CreateFiberEx(usize, usize, u32, *const fn (?*anyopaque) callconv(.winapi) void, ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SwitchToFiber(*anyopaque) callconv(.winapi) void;
extern "kernel32" fn DeleteFiber(*anyopaque) callconv(.winapi) void;

pub const Context = if (windows) *anyopaque else std.Io.fiber.Context;

pub fn initRoot() !Context {
    // Windows converts only around a dispatch, not for the entire window
    // lifetime. Multiple windows can therefore share a native thread.
    if (windows) return undefined;
    return std.mem.zeroes(Context);
}

pub fn deinitRoot(_: *Context) void {}

pub fn enterRoot(context: *Context) bool {
    if (!windows) return false;
    if (IsThreadAFiber() != .FALSE) {
        context.* = std.os.windows.teb().NtTib.DUMMYUNIONNAME.FiberData;
        return false;
    }
    context.* = ConvertThreadToFiberEx(null, fiber_flag_float_switch) orelse @panic("Could not convert the window thread to a fiber");
    return true;
}

pub fn leaveRoot(owns_conversion: bool) void {
    if (windows and owns_conversion) {
        if (ConvertFiberToThread() == .FALSE) @panic("Could not convert the window fiber back to a thread");
    }
}

// Keep the register-clobbering context switch behind an ABI call boundary.
// Inlining it into arbitrary optimized Zig code can allow caller values to
// remain in registers (notably AArch64 LR) that belong to the other fiber.
pub noinline fn switchTo(from: *Context, to: *Context) void {
    if (windows) {
        SwitchToFiber(to.*);
    } else {
        const message: std.Io.fiber.Switch = .{ .old = from, .new = to };
        _ = std.Io.fiber.contextSwitch(&message);
    }
}

pub const Fiber = struct {
    context: Context,
    entry: Entry,
    argument: *anyopaque,
    mapping: if (windows) void else []align(std.heap.page_size_min) u8,

    pub fn init(self: *Fiber, entry: Entry, argument: *anyopaque) !void {
        self.entry = entry;
        self.argument = argument;
        if (windows) {
            self.context = CreateFiberEx(0, stack_size, fiber_flag_float_switch, windowsEntry, self) orelse return error.FiberInitializationFailed;
            return;
        }
        const page = std.heap.pageSize();
        const mapping = try std.posix.mmap(null, stack_size + page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        errdefer std.posix.munmap(mapping);
        if (std.c.mprotect(@ptrCast(@alignCast(mapping.ptr)), page, .{}) != 0) return error.FiberInitializationFailed;
        self.mapping = mapping;
        const top = @intFromPtr(mapping.ptr) + mapping.len;
        self.context = switch (builtin.cpu.arch) {
            .aarch64, .riscv64 => .{ .sp = top, .fp = @intFromPtr(self), .pc = @intFromPtr(&posixEntry) },
            .x86_64 => .{ .rsp = top - 8, .rbp = @intFromPtr(self), .rip = @intFromPtr(&posixEntry) },
            else => @compileError("WindowIo fiber architecture is not implemented"),
        };
    }

    pub fn deinit(self: *Fiber) void {
        if (windows) DeleteFiber(self.context) else std.posix.munmap(self.mapping);
    }

    fn windowsEntry(argument: ?*anyopaque) callconv(.winapi) void {
        run(@ptrCast(@alignCast(argument.?)));
    }

    // A new fiber has no caller. Clear both the frame pointer and the
    // return address so debug allocators cannot unwind into the root stack.
    fn posixEntry() callconv(.naked) void {
        switch (builtin.cpu.arch) {
            .aarch64 => asm volatile ("mov x0, fp\nmov fp, #0\nmov lr, #0\nb %[entry]"
                :
                : [entry] "X" (&run),
            ),
            .x86_64 => asm volatile ("movq %%rbp, %%rdi\nxorq %%rbp, %%rbp\njmp %[entry:P]"
                :
                : [entry] "X" (&run),
            ),
            .riscv64 => asm volatile ("mv a0, fp\nli fp, 0\nli ra, 0\ntail %[entry]@plt"
                :
                : [entry] "X" (&run),
            ),
            else => unreachable,
        }
    }

    fn run(self: *Fiber) callconv(.c) noreturn {
        self.entry(self.argument);
    }
};
