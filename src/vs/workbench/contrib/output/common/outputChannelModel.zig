// Port of FileOutputChannelModel's single-file source and reset behavior from
// `src/vs/workbench/contrib/output/common/outputChannelModel.ts`.
// The terminal retains the file slice for its read-only view; the editor text
// model, multifile models and asynchronous file-stream delayer remain gaps.
const std = @import("std");
const files = @import("../../../../platform/files/common/files.zig");
const Mode = @import("../../../services/output/common/output.zig").OutputChannelUpdateMode;
const Allocator = std.mem.Allocator;

pub const FileOutputChannelModel = struct {
    allocator: Allocator,
    files_service: files.IFileService,
    source: std.Uri,
    start_offset: usize = 0,
    content: []u8 = &.{},

    pub fn init(allocator: Allocator, service: files.IFileService, source: std.Uri) FileOutputChannelModel {
        return .{ .allocator = allocator, .files_service = service, .source = source };
    }

    pub fn deinit(self: *FileOutputChannelModel) void {
        self.allocator.free(self.content);
    }

    pub fn update(self: *FileOutputChannelModel, mode: Mode, till: ?usize) !void {
        if (mode != .Append) {
            self.start_offset = till orelse blk: {
                const stat = self.files_service.stat(self.source) catch |err| switch (err) {
                    error.FileNotFound => break :blk 0,
                    else => return err,
                };
                break :blk std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
            };
        }
        if (mode == .Clear) {
            self.allocator.free(self.content);
            self.content = &.{};
            return;
        }
        const bytes = self.files_service.readFile(self.allocator, self.source) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        // Rotation can make the file shorter than a previously cleared range.
        if (bytes.len < self.start_offset) self.start_offset = 0;
        const content = try self.allocator.dupe(u8, bytes[self.start_offset..]);
        self.allocator.free(self.content);
        self.content = content;
    }
};
