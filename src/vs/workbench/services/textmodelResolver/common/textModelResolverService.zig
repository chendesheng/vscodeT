// Port of the file-resource resolution boundary of
// `src/vs/workbench/services/textmodelResolver/common/textModelResolverService.ts`.
// Native reads are immutable worker requests; the editor service retains the
// existing file input/model reference once the provider has returned its data.
const std = @import("std");
const Allocator = std.mem.Allocator;
const SnapshotSource = @import("../../../../editor/browser/widget/diffEditor/diffProviderFactoryService.zig").SnapshotSource;
const text_file = @import("../../textfile/common/textFileService.zig");
const encoding = @import("../../textfile/common/encoding.zig");
const uri_util = @import("../../../../base/common/stdUri.zig");
const DiskFileService = @import("../../../../platform/files/common/fileService.zig").DiskFileService;

pub const FileSnapshotRequest = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    original: ?Entry,
    modified: ?Entry,

    pub const WorkingText = struct { text: []const u8, encoding: encoding.Encoding };
    const Entry = struct {
        path: []const u8,
        uri: []const u8,
        working: ?WorkingText = null,
    };
    pub fn supports(uri: ?std.Uri) bool {
        return if (uri) |value| std.mem.eql(u8, value.scheme, "file") else true;
    }
    fn captureEntry(a: Allocator, io: std.Io, uri: ?std.Uri, working: ?WorkingText) !?Entry {
        const value = uri orelse return null;
        if (!supports(value)) return error.UnsupportedResourceScheme;
        const path = try text_file.absolutePath(a, io, try uri_util.fsPath(value, a));
        return .{
            .path = path,
            .uri = try uri_util.encodedResource(a, value),
            .working = if (working) |text| .{ .text = try a.dupe(u8, text.text), .encoding = text.encoding } else null,
        };
    }
    pub fn capture(io: std.Io, original: ?std.Uri, modified: ?std.Uri, original_working: ?WorkingText, modified_working: ?WorkingText) !SnapshotSource {
        const self = try std.heap.page_allocator.create(FileSnapshotRequest);
        errdefer std.heap.page_allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const original_entry = try captureEntry(a, io, original, original_working);
        const modified_entry = try captureEntry(a, io, modified, modified_working);
        self.* = .{ .arena = arena, .io = io, .original = original_entry, .modified = modified_entry };
        return self.interface();
    }
    const Result = struct { resource: ?SnapshotSource.Resource = null, text: ?[]const u8 = null };
    fn readEntry(self: *FileSnapshotRequest, allocator: Allocator, entry: ?Entry) !Result {
        const value = entry orelse return .{};
        var resource: SnapshotSource.Resource = .{
            .path = try allocator.dupe(u8, value.path),
            .uri = try std.Uri.parse(try allocator.dupe(u8, value.uri)),
        };
        if (value.working) |working| {
            resource.encoding = working.encoding;
            resource.is_working_file = true;
            return .{ .resource = resource, .text = try allocator.dupe(u8, working.text) };
        }
        var files = DiskFileService.init(allocator, self.io);
        defer files.deinit();
        var data = files.readFile(value.path) catch |err| {
            if (err == error.OutOfMemory) return err;
            resource.failure = err;
            return .{ .resource = resource };
        };
        defer data.deinit(allocator);
        const detected = if (encoding.detectBOM(data.bytes)) |bom| bom.encoding else encoding.Encoding.utf8;
        if (!encoding.isUTF16(detected) and std.mem.indexOfScalar(u8, data.bytes, 0) != null) return .{ .resource = resource };
        resource.is_working_file = true;
        resource.encoding = detected;
        return .{ .resource = resource, .text = try encoding.decode(allocator, data.bytes, detected) };
    }
    fn read(context: *anyopaque, allocator: Allocator) !SnapshotSource.Texts {
        const self: *FileSnapshotRequest = @ptrCast(@alignCast(context));
        const original = try self.readEntry(allocator, self.original);
        const modified = try self.readEntry(allocator, self.modified);
        return .{
            .original = original.text orelse "",
            .modified = modified.text orelse "",
            .original_resource = original.resource,
            .modified_resource = modified.resource,
            .original_available = original.text != null,
            .modified_available = modified.text != null,
        };
    }
    fn destroy(context: *anyopaque) void {
        const self: *FileSnapshotRequest = @ptrCast(@alignCast(context));
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
    pub fn interface(self: *FileSnapshotRequest) SnapshotSource {
        return .{ .context = self, .read = read, .destroy = destroy };
    }
};
