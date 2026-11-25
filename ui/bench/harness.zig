//! Benchmark harness for the standalone UI library.
//!
//! Follows the scenario/median/allocation shape of TermDOM's `bench/harness.ts`,
//! adapted to native Zig: there is no JIT tier-up, so no iteration is called a
//! warmup and no sample is discarded. Every iteration is reported; the first
//! sample is kept separately because it carries one-time page-fault, allocator
//! growth and page-cache costs.
//!
//! Timing is wall-clock monotonic time. The allocation mode swaps in a counting
//! allocator and reports the bytes a step requested, independent of the timing
//! samples.

const std = @import("std");
const Io = std.Io;

pub const Allocator = std.mem.Allocator;

pub fn nowNs(io: Io) i64 {
    return @intCast(Io.Timestamp.now(io, .awake).toNanoseconds());
}

pub const Stats = struct {
    first: i64,
    min: i64,
    p50: i64,
    p90: i64,
    p99: i64,
    max: i64,

    pub fn fromSamples(allocator: Allocator, samples: []const i64) !Stats {
        std.debug.assert(samples.len > 0);
        const sorted = try allocator.dupe(i64, samples);
        defer allocator.free(sorted);
        std.mem.sort(i64, sorted, {}, struct {
            fn lessThan(_: void, a: i64, b: i64) bool {
                return a < b;
            }
        }.lessThan);

        return .{
            .first = samples[0],
            .min = sorted[0],
            .p50 = percentile(sorted, 50),
            .p90 = percentile(sorted, 90),
            .p99 = percentile(sorted, 99),
            .max = sorted[sorted.len - 1],
        };
    }

    fn percentile(sorted: []const i64, percent: usize) i64 {
        if (sorted.len == 1) return sorted[0];
        const index = (sorted.len - 1) * percent / 100;
        return sorted[index];
    }
};

pub const Measurement = struct {
    scenario: []const u8,
    label: []const u8,
    ns: Stats,
    bytes: Stats,
    iterations: usize,

    pub fn deinit(self: *Measurement, allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Tracks requested bytes without changing the allocation path. `total` is the
/// number of bytes requested since the last reset; `live` is the outstanding
/// requested bytes. It is deliberately a thin wrapper: the benchmark reports
/// what the scenario asked the allocator for, not what the OS did.
pub const CountingAllocator = struct {
    child: Allocator,
    total: usize = 0,
    live: usize = 0,

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn reset(self: *CountingAllocator) void {
        self.total = 0;
    }

    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
        if (result != null) {
            self.total += len;
            self.live += len;
        }
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
        if (ok) self.accountResize(memory.len, new_len);
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
        if (result != null) self.accountResize(memory.len, new_len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.live = self.live -| memory.len;
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
    }

    fn accountResize(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            const delta = new_len - old_len;
            self.total += delta;
            self.live += delta;
        } else {
            self.live = self.live -| (old_len - new_len);
        }
    }
};

pub const Scenario = struct {
    name: []const u8,
    description: []const u8,
    run: *const fn (*Context) anyerror!void,
};

pub const Context = struct {
    /// Allocator the scenario should use for its documents and surfaces.
    allocator: Allocator,
    /// Page allocator for harness bookkeeping; never counted.
    harness_allocator: Allocator,
    io: Io,
    iterations: usize,
    stress: bool,
    allocated: bool,
    counting: ?*CountingAllocator = null,
    measurements: std.ArrayList(Measurement) = .empty,

    pub fn deinit(self: *Context) void {
        for (self.measurements.items) |*measurement| measurement.deinit(self.harness_allocator);
        self.measurements.deinit(self.harness_allocator);
    }

    /// Runs `step` `iterations` times and records the time and requested bytes.
    /// No iteration is discarded. The step receives its iteration index so a
    /// scenario can alternate operations without allocating per-step closures.
    pub fn measure(
        self: *Context,
        label: []const u8,
        context: anytype,
        comptime step: fn (@TypeOf(context), usize) anyerror!void,
    ) !void {
        const iterations = @max(self.iterations, 1);
        const samples = try self.harness_allocator.alloc(i64, iterations);
        defer self.harness_allocator.free(samples);
        const byte_samples = try self.harness_allocator.alloc(i64, iterations);
        defer self.harness_allocator.free(byte_samples);

        for (0..iterations) |index| {
            if (self.counting) |counting| counting.reset();
            const start = nowNs(self.io);
            try step(context, index);
            const elapsed = nowNs(self.io) - start;
            samples[index] = elapsed;
            byte_samples[index] = if (self.counting) |counting|
                @intCast(counting.total)
            else
                0;
        }

        const ns_stats = try Stats.fromSamples(self.harness_allocator, samples);
        const byte_stats = try Stats.fromSamples(self.harness_allocator, byte_samples);
        try self.measurements.append(self.harness_allocator, .{
            .scenario = "",
            .label = label,
            .ns = ns_stats,
            .bytes = byte_stats,
            .iterations = iterations,
        });
    }
};

/// Merges a scenario run into an aggregate keyed by label. The scenario name is
/// fixed for every measurement in the run.
pub const Aggregator = struct {
    allocator: Allocator,
    scenario: []const u8,
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        label: []const u8,
        first_ns: i64,
        samples: std.ArrayList(i64) = .empty,
        byte_samples: std.ArrayList(i64) = .empty,
    };

    pub fn init(allocator: Allocator, scenario: []const u8) Aggregator {
        return .{ .allocator = allocator, .scenario = scenario };
    }

    pub fn deinit(self: *Aggregator) void {
        for (self.entries.items) |*entry| {
            entry.samples.deinit(self.allocator);
            entry.byte_samples.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn addRun(self: *Aggregator, measurements: []const Measurement) !void {
        for (measurements) |measurement| {
            var entry = self.find(measurement.label) orelse blk: {
                try self.entries.append(self.allocator, .{
                    .label = measurement.label,
                    .first_ns = measurement.ns.first,
                });
                break :blk &self.entries.items[self.entries.items.len - 1];
            };
            try entry.samples.append(self.allocator, measurement.ns.p50);
            try entry.byte_samples.append(self.allocator, measurement.bytes.p50);
        }
    }

    fn find(self: *Aggregator, label: []const u8) ?*Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.label, label)) return entry;
        }
        return null;
    }

    pub fn stats(self: *const Aggregator, entry: *const Entry, allocator: Allocator) !Stats {
        _ = self;
        return Stats.fromSamples(allocator, entry.samples.items);
    }
};
