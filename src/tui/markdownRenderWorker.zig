// Renders Markdown preview content in a worker. Cached text belongs to one
// document version. Each renderer has its own job and executable.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Renderer = struct {
    allocator: Allocator,
    script_name: []const u8,
    io: ?Io = null,
    executable_checked: bool = false,
    script: ?[]u8 = null,
    version: ?u32 = null,
    cache: std.StringHashMapUnmanaged(?[]u8) = .empty,
    job: ?*Job = null,

    const Job = struct {
        source: []u8,
        script: []const u8,
        allocator: Allocator,
        io: Io,
        done: std.atomic.Value(bool) = .init(false),
        future: Io.Future(?[]u8) = undefined,
    };

    pub fn reset(self: *Renderer, version: u32) void {
        if (self.version == version) return;
        self.clear();
        self.version = version;
    }

    fn clear(self: *Renderer) void {
        if (self.job) |job| {
            if (job.future.cancel(job.io)) |output| self.allocator.free(output);
            self.allocator.free(job.source);
            self.allocator.destroy(job);
            self.job = null;
        }
        var entries = self.cache.iterator();
        while (entries.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |diagram| self.allocator.free(diagram);
        }
        self.cache.clearRetainingCapacity();
    }

    pub fn deinit(self: *Renderer) void {
        self.clear();
        self.cache.deinit(self.allocator);
        if (self.script) |script| self.allocator.free(script);
    }

    pub fn lookup(context: *anyopaque, source: []const u8) ?[]const u8 {
        const self: *Renderer = @ptrCast(@alignCast(context));
        if (self.cache.get(source)) |diagram| return diagram;
        if (self.job != null or source.len > 32 * 1024) return null;
        const io = self.io orelse return null;
        if (!self.executable_checked) {
            self.executable_checked = true;
            const dir = std.process.executableDirPathAlloc(io, self.allocator) catch return null;
            defer self.allocator.free(dir);
            const script = std.fs.path.resolveAlloc(self.allocator, &.{ dir, "../lib/vscode-textbuffer", self.script_name }) catch return null;
            Io.Dir.cwd().access(io, script, .{}) catch {
                self.allocator.free(script);
                return null;
            };
            self.script = script;
        }
        const script = self.script orelse return null;
        const job = self.allocator.create(Job) catch return null;
        const owned = self.allocator.dupe(u8, source) catch {
            self.allocator.destroy(job);
            return null;
        };
        job.* = .{ .source = owned, .script = script, .allocator = self.allocator, .io = io };
        job.future = io.concurrent(render, .{job}) catch {
            self.allocator.free(owned);
            self.allocator.destroy(job);
            return null;
        };
        self.job = job;
        return null;
    }

    pub fn poll(self: *Renderer) bool {
        const job = self.job orelse return false;
        if (!job.done.load(.acquire)) return false;
        const output = job.future.await(job.io);
        self.cache.put(self.allocator, job.source, output) catch {
            self.allocator.free(job.source);
            if (output) |text| self.allocator.free(text);
        };
        self.allocator.destroy(job);
        self.job = null;
        return true;
    }

    fn render(job: *Job) ?[]u8 {
        defer job.done.store(true, .release);
        return run(job) catch null;
    }

    fn run(job: *Job) !?[]u8 {
        const io = job.io;
        var child = try std.process.spawn(io, .{
            .argv = &.{ "node", job.script },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        defer child.kill(io);
        try child.stdin.?.writeStreamingAll(io, job.source);
        child.stdin.?.close(io);
        child.stdin = null;
        var buffer: Io.File.MultiReader.Buffer(1) = undefined;
        var reader: Io.File.MultiReader = undefined;
        reader.init(job.allocator, io, buffer.toStreams(), &.{child.stdout.?});
        defer reader.deinit();
        const timeout = (Io.Timeout{ .duration = .{ .raw = .fromSeconds(4), .clock = .awake } }).toDeadline(io);
        while (reader.fill(4096, timeout)) |_| {
            if (reader.reader(0).buffered().len > 256 * 1024) return null;
        } else |err| if (err != error.EndOfStream) return err;
        try reader.checkAnyError();
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0 or reader.reader(0).buffered().len == 0) return null;
        return try reader.toOwnedSlice(0);
    }
};
