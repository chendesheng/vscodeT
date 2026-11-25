// Test window for the terminal adaptation of workbench.ts. It owns the
// document and cell surface for the entire lifetime of the mounted workbench.
const std = @import("std");
const ui = @import("ui");
const CursorColumns = @import("../../../editor/common/core/cursorColumns.zig").CursorColumns;

const shell = @import("../../browser/workbench.zig");
const Workbench = shell.Workbench;

pub const TestWindow = struct {
    const Self = @This();
    workbench: *Workbench,
    surface: *ui.Surface,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, paths: []const []const u8, cols: usize, rows: usize) !Self {
        return initWithOptions(allocator, io, paths, cols, rows, .{}, null);
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, io: std.Io, paths: []const []const u8, cols: usize, rows: usize, options: shell.IWorkbenchOptions, previous: ?Workbench.PreviousState) !Self {
        const surface = try allocator.create(ui.Surface);
        errdefer allocator.destroy(surface);
        surface.* = try ui.Surface.init(allocator, .{ .cols = @max(cols, 1), .rows = @max(rows, 1), .measure_width = measureWidth });
        errdefer surface.deinit();
        const doc = surface.document();
        doc.setRoot(try doc.createElement(.div));
        var services = try @import("../../workbench.common.main.zig").createServices(allocator);
        defer services.deinit();
        const workbench = try Workbench.init(allocator, io, surface, &services, options, previous);
        errdefer workbench.deinit();
        _ = try workbench.startup();
        for (paths) |path| try workbench.openPath(path);
        return .{ .surface = surface, .workbench = workbench };
    }

    fn measureWidth(cp: u21) u2 {
        return @intCast(CursorColumns.nextVisibleColumn(cp, 0, 1));
    }

    pub fn deinit(self: Self) void {
        const allocator = self.surface.allocator;
        self.workbench.deinit();
        self.surface.deinit();
        allocator.destroy(self.surface);
    }
};
