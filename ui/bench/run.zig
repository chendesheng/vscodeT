//! UI benchmark runner.
//!
//!   zig build bench -- --runs 5 --markdown
//!   zig build bench -Doptimize=ReleaseFast -- --allocated --runs 3
//!   zig build bench -- --only scroll,editor --profile editor --seconds 10
//!
//! Every iteration is recorded: there is no warmup and no discarded sample.
//! The first sample (which carries one-time page faults and allocator growth)
//! is reported separately from the distribution.

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui");
const harness = @import("harness.zig");

const scenarios = [_]harness.Scenario{
    @import("scenarios/startup.zig").scenario,
    @import("scenarios/dom_ops.zig").scenario,
    @import("scenarios/toggle.zig").scenario,
    @import("scenarios/scroll.zig").scenario,
    @import("scenarios/editor.zig").scenario,
    @import("scenarios/wrap.zig").scenario,
    @import("scenarios/flex.zig").scenario,
    @import("scenarios/borders.zig").scenario,
    @import("scenarios/ansi.zig").scenario,
    @import("scenarios/interaction.zig").scenario,
};

const BaselineEntry = struct {
    label: []const u8,
    first_ns: i64,
    median_ns: i64,
    alloc_bytes: i64,
};

const Config = struct {
    runs: usize = 5,
    iterations: usize = 20,
    only: ?[]const u8 = null,
    markdown: bool = false,
    json: bool = false,
    allocated: bool = false,
    stress: bool = false,
    profile: ?[]const u8 = null,
    seconds: u64 = 5,
    baseline: ?[]const u8 = null,
    write_baseline: ?[]const u8 = null,
    report: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    const config = parseArgs(arena, args) catch |err| {
        try printUsage(out);
        std.debug.print("argument error: {s}\n", .{@errorName(err)});
        return;
    };
    if (config.profile) |name| {
        try runProfile(io, arena, gpa, out, config, name);
        return;
    }

    var selected = std.ArrayList(*const harness.Scenario).empty;
    defer selected.deinit(arena);
    for (&scenarios) |*scenario| {
        if (config.only) |only| {
            if (!containsCsv(only, scenario.name)) continue;
        }
        try selected.append(arena, scenario);
    }
    if (selected.items.len == 0) {
        try out.print("no scenarios selected\n", .{});
        return;
    }

    var baseline_map = std.StringHashMapUnmanaged(BaselineEntry){};
    defer baseline_map.deinit(arena);
    if (config.baseline) |path| {
        try loadBaseline(io, arena, path, &baseline_map);
    }

    const all_entries = try arena.alloc(std.ArrayList(harness.Aggregator.Entry), selected.items.len);
    const all_aggregators = try arena.alloc(harness.Aggregator, selected.items.len);
    var aggregate_count: usize = 0;
    defer {
        for (all_aggregators[0..aggregate_count]) |*aggregator| aggregator.deinit();
    }

    const start_ns = harness.nowNs(io);
    for (selected.items, 0..) |scenario, scenario_index| {
        var aggregator = harness.Aggregator.init(arena, scenario.name);
        var run_index: usize = 0;
        while (run_index < config.runs) : (run_index += 1) {
            const work_allocator = std.heap.page_allocator;
            var counting = harness.CountingAllocator{ .child = work_allocator };
            const scenario_allocator = if (config.allocated) counting.allocator() else work_allocator;
            var context = harness.Context{
                .allocator = scenario_allocator,
                .harness_allocator = gpa,
                .io = io,
                .iterations = config.iterations,
                .stress = config.stress,
                .allocated = config.allocated,
                .counting = if (config.allocated) &counting else null,
            };
            defer context.deinit();
            try scenario.run(&context);
            try aggregator.addRun(context.measurements.items);
        }
        all_aggregators[scenario_index] = aggregator;
        all_entries[scenario_index] = aggregator.entries;
        aggregate_count += 1;
    }

    const elapsed_ns = harness.nowNs(io) - start_ns;

    if (config.write_baseline) |path| {
        try writeBaseline(io, arena, path, all_entries[0..selected.items.len]);
    }

    if (config.json) {
        for (selected.items, 0..) |scenario, index| {
            for (all_entries[index].items) |*entry| {
                const stats = try all_aggregators[index].stats(entry, gpa);
                const byte_stats = try harness.Stats.fromSamples(gpa, entry.byte_samples.items);
                try printJson(out, scenario.name, entry, stats, byte_stats);
            }
        }
    } else if (config.markdown) {
        try printMarkdown(io, out, selected.items, all_entries[0..selected.items.len], &baseline_map, gpa);
    } else {
        try printText(io, out, selected.items, all_entries[0..selected.items.len], &baseline_map, gpa);
    }
    if (config.report) |path| {
        try writeReport(
            io,
            gpa,
            path,
            selected.items,
            all_entries[0..selected.items.len],
            &baseline_map,
            config,
            elapsed_ns,
        );
    }
    try out.print("\n[{d} scenario(s), {d} run(s), {d} iteration(s)/run, {d:.1} ms total]\n", .{
        selected.items.len,
        config.runs,
        config.iterations,
        @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
    });
    try out.flush();
}

/// Writes a self-contained markdown report for CI. The report deliberately
/// states the machine/build and that the numbers are diagnostics rather than
/// gates; CI timing noise must not read as a regression.
fn writeReport(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    selected: []const *const harness.Scenario,
    entries: []const std.ArrayList(harness.Aggregator.Entry),
    baseline: *const std.StringHashMapUnmanaged(BaselineEntry),
    config: Config,
    elapsed_ns: i64,
) !void {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.writer.print(
        "# UI stress benchmark report\n\n" ++
            "- build: `{s}`\n" ++
            "- host: `{s}-{s}`\n" ++
            "- scenarios: {d}\n" ++
            "- runs: {d}, iterations/run: {d}\n" ++
            "- allocation mode: {s}\n" ++
            "- baseline: {s}\n" ++
            "- elapsed: {d:.1} ms\n\n" ++
            "Every iteration is reported; there is no JIT warmup or discarded sample. " ++
            "The first column is the first iteration, which carries one-time page faults and allocator growth. " ++
            "Timings are diagnostics; CI runner noise is not a pass/fail gate.\n\n",
        .{
            @tagName(builtin.mode),
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
            selected.len,
            config.runs,
            config.iterations,
            if (config.allocated) "yes (bytes requested per step)" else "no",
            if (config.baseline) |value| value else "none",
            @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
        },
    );
    try printMarkdown(io, &body.writer, selected, entries, baseline, allocator);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.written() });
}

fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !Config {
    var config = Config{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--runs")) {
            index += 1;
            config.runs = try parseUsize(args, index);
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            index += 1;
            config.iterations = try parseUsize(args, index);
        } else if (std.mem.eql(u8, arg, "--only")) {
            index += 1;
            config.only = try nextArg(allocator, args, index);
        } else if (std.mem.eql(u8, arg, "--markdown")) {
            config.markdown = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.json = true;
        } else if (std.mem.eql(u8, arg, "--allocated")) {
            config.allocated = true;
        } else if (std.mem.eql(u8, arg, "--stress")) {
            config.stress = true;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            index += 1;
            config.profile = try nextArg(allocator, args, index);
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            index += 1;
            config.seconds = try parseUsize(args, index);
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            index += 1;
            config.baseline = try nextArg(allocator, args, index);
        } else if (std.mem.eql(u8, arg, "--write-baseline")) {
            index += 1;
            config.write_baseline = try nextArg(allocator, args, index);
        } else if (std.mem.eql(u8, arg, "--report")) {
            index += 1;
            config.report = try nextArg(allocator, args, index);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.Help;
        } else {
            return error.UnknownArgument;
        }
    }
    if (config.runs == 0 or config.iterations == 0) return error.InvalidCount;
    return config;
}

fn parseUsize(args: []const [:0]const u8, index: usize) !usize {
    if (index >= args.len) return error.MissingValue;
    return std.fmt.parseUnsigned(usize, args[index], 10) catch error.InvalidNumber;
}

fn nextArg(allocator: std.mem.Allocator, args: []const [:0]const u8, index: usize) ![]const u8 {
    if (index >= args.len) return error.MissingValue;
    return allocator.dupe(u8, args[index]);
}

fn containsCsv(haystack: []const u8, needle: []const u8) bool {
    var iterator = std.mem.tokenizeScalar(u8, haystack, ',');
    while (iterator.next()) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn runProfile(
    io: std.Io,
    allocator: std.mem.Allocator,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    config: Config,
    name: []const u8,
) !void {
    var chosen: ?*const harness.Scenario = null;
    for (&scenarios) |*scenario| {
        if (std.mem.eql(u8, scenario.name, name)) chosen = scenario;
    }
    const scenario = chosen orelse {
        try out.print("unknown profile scenario: {s}\n", .{name});
        try out.flush();
        return error.UnknownScenario;
    };
    const deadline = harness.nowNs(io) + @as(i64, @intCast(config.seconds)) * std.time.ns_per_s;
    try out.print("[profile] scenario={s} seconds={d} pid={d}\n", .{
        scenario.name,
        config.seconds,
        processId(),
    });
    try out.flush();

    var runs: usize = 0;
    while (harness.nowNs(io) < deadline) {
        var counting = harness.CountingAllocator{ .child = std.heap.page_allocator };
        const scenario_allocator = if (config.allocated) counting.allocator() else std.heap.page_allocator;
        var context = harness.Context{
            .allocator = scenario_allocator,
            .harness_allocator = gpa,
            .io = io,
            // Reuse one scenario setup for as many steps as requested; a
            // profiler must sample the timed operation, not repeated fixture
            // construction.
            .iterations = config.iterations,
            .stress = config.stress,
            .allocated = config.allocated,
            .counting = if (config.allocated) &counting else null,
        };
        defer context.deinit();
        try scenario.run(&context);
        runs += 1;
    }
    try out.print("[profile] completed {d} scenario runs\n", .{runs});
    try out.flush();
    _ = allocator;
}

fn processId() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => @intCast(std.c.getpid()),
        else => 0,
    };
}

fn loadBaseline(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    map: *std.StringHashMapUnmanaged(BaselineEntry),
) !void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 << 20)) catch |err| {
        std.debug.print("baseline not read ({s}): {s}\n", .{ path, @errorName(err) });
        return;
    };
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const entry = std.json.parseFromSliceLeaky(BaselineEntry, allocator, line, .{}) catch continue;
        try map.put(allocator, entry.label, entry);
    }
}

fn writeBaseline(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    entries: []const std.ArrayList(harness.Aggregator.Entry),
) !void {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    for (entries) |scenario_entries| {
        for (scenario_entries.items) |*entry| {
            const stats = try harness.Stats.fromSamples(allocator, entry.samples.items);
            const bytes = try harness.Stats.fromSamples(allocator, entry.byte_samples.items);
            try body.writer.print(
                "{{\"label\":\"{s}\",\"first_ns\":{d},\"median_ns\":{d},\"alloc_bytes\":{d}}}\n",
                .{ entry.label, entry.first_ns, stats.p50, bytes.p50 },
            );
        }
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body.written() });
}

fn printJson(
    out: *std.Io.Writer,
    scenario: []const u8,
    entry: *const harness.Aggregator.Entry,
    stats: harness.Stats,
    byte_stats: harness.Stats,
) !void {
    try out.print(
        "{{\"scenario\":\"{s}\",\"label\":\"{s}\",\"first_ns\":{d},\"min_ns\":{d},\"p50_ns\":{d},\"p90_ns\":{d},\"p99_ns\":{d},\"max_ns\":{d},\"alloc_bytes\":{d}}}\n",
        .{ scenario, entry.label, stats.first, stats.min, stats.p50, stats.p90, stats.p99, stats.max, byte_stats.p50 },
    );
}

fn printText(
    io: std.Io,
    out: *std.Io.Writer,
    selected: []const *const harness.Scenario,
    entries: []const std.ArrayList(harness.Aggregator.Entry),
    baseline: *const std.StringHashMapUnmanaged(BaselineEntry),
    allocator: std.mem.Allocator,
) !void {
    _ = io;
    for (selected, 0..) |scenario, index| {
        try out.print("\n{s} — {s}\n", .{ scenario.name, scenario.description });
        for (entries[index].items) |*entry| {
            const stats = try harness.Stats.fromSamples(allocator, entry.samples.items);
            const bytes = try harness.Stats.fromSamples(allocator, entry.byte_samples.items);
            const delta = if (baseline.get(entry.label)) |base|
                @as(f64, @floatFromInt(stats.p50 - base.median_ns)) * 100.0 /
                    @as(f64, @floatFromInt(@max(base.median_ns, 1)))
            else
                null;
            try out.print(
                "  {s}  first={d}ns p50={d}ns p90={d}ns p99={d}ns alloc={d}B",
                .{ entry.label, stats.first, stats.p50, stats.p90, stats.p99, bytes.p50 },
            );
            if (delta) |value| try out.print("  {s}{d:.1}%", .{
                if (value <= 0) @as([]const u8, "") else @as([]const u8, "+"),
                value,
            });
            try out.print("\n", .{});
        }
    }
}

fn printMarkdown(
    io: std.Io,
    out: *std.Io.Writer,
    selected: []const *const harness.Scenario,
    entries: []const std.ArrayList(harness.Aggregator.Entry),
    baseline: *const std.StringHashMapUnmanaged(BaselineEntry),
    allocator: std.mem.Allocator,
) !void {
    _ = io;
    try out.print("| Scenario | Measurement | first | p50 | p90 | p99 | alloc/step | delta |\n", .{});
    try out.print("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |\n", .{});
    for (selected, 0..) |scenario, index| {
        for (entries[index].items) |*entry| {
            const stats = try harness.Stats.fromSamples(allocator, entry.samples.items);
            const bytes = try harness.Stats.fromSamples(allocator, entry.byte_samples.items);
            if (baseline.get(entry.label)) |base| {
                const delta = @as(f64, @floatFromInt(stats.p50 - base.median_ns)) * 100.0 /
                    @as(f64, @floatFromInt(@max(base.median_ns, 1)));
                try out.print(
                    "| {s} | {s} | {d} | {d} | {d} | {d} | {d} | {s}{d:.1}% |\n",
                    .{
                        scenario.name,
                        entry.label,
                        stats.first,
                        stats.p50,
                        stats.p90,
                        stats.p99,
                        bytes.p50,
                        if (delta <= 0) @as([]const u8, "") else @as([]const u8, "+"),
                        delta,
                    },
                );
            } else {
                try out.print(
                    "| {s} | {s} | {d} | {d} | {d} | {d} | {d} | — |\n",
                    .{ scenario.name, entry.label, stats.first, stats.p50, stats.p90, stats.p99, bytes.p50 },
                );
            }
        }
    }
}

fn printUsage(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\usage: ui-bench [options]
        \\  --runs N              repeat each scenario N times (default 5)
        \\  --iterations N        steps per run (default 20)
        \\  --only a,b            run only the named scenarios
        \\  --markdown            print a markdown table
        \\  --json                print one JSON object per measurement
        \\  --allocated           count requested bytes per step
        \\  --stress              run the heavy variant (longer/hotter scenes)
        \\  --baseline FILE       compare medians with a previous JSONL baseline
        \\  --write-baseline FILE write the current medians as JSONL
        \\  --report FILE         write a markdown CI report
        \\  --profile NAME        keep a scenario running for sampling
        \\  --seconds N           profile duration (default 5)
        \\
    );
}
