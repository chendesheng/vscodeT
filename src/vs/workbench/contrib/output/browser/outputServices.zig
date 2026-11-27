// Port of the single-file OutputChannel and OutputService ownership in
// `src/vs/workbench/contrib/output/browser/outputServices.ts`.
// The native view is a separate contribution. File-backed descriptors are
// owned here and file/log registration events update the active model.
const std = @import("std");
const output = @import("../../../services/output/common/output.zig");
const files = @import("../../../../platform/files/common/files.zig");
const FileLoggerService = @import("../../../../platform/log/common/fileLog.zig").FileLoggerService;
const FileOutputChannelModel = @import("../common/outputChannelModel.zig").FileOutputChannelModel;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const std_uri = @import("../../../../base/common/stdUri.zig");
const Allocator = std.mem.Allocator;

pub const OutputChannel = struct {
    arena: std.heap.ArenaAllocator,
    descriptor: output.IOutputChannelDescriptor,
    model: FileOutputChannelModel,
};

pub const OutputService = struct {
    allocator: Allocator,
    files_service: files.IFileService,
    loggers: *FileLoggerService,
    channels: std.ArrayList(*OutputChannel) = .empty,
    active: ?*OutputChannel = null,
    visible: bool = false,
    on_did_change: Emitter(void),
    on_active_output_channel: Emitter(void),
    on_visible_channel: Emitter(void),
    file_listener: ?usize = null,
    logger_listener: ?usize = null,

    pub fn init(allocator: Allocator, service: files.IFileService, loggers: *FileLoggerService) OutputService {
        return .{ .allocator = allocator, .files_service = service, .loggers = loggers, .on_did_change = .init(allocator), .on_active_output_channel = .init(allocator), .on_visible_channel = .init(allocator) };
    }

    pub fn attach(self: *OutputService) !void {
        self.file_listener = try self.files_service.on_did_files_change.listen(self, onFilesChanged);
        errdefer self.files_service.on_did_files_change.unlisten(self.file_listener.?);
        self.logger_listener = try self.loggers.on_did_change_loggers.listen(self, onLoggersChanged);
        errdefer self.loggers.on_did_change_loggers.unlisten(self.logger_listener.?);
        try self.syncLoggers();
    }

    pub fn deinit(self: *OutputService) void {
        if (self.file_listener) |id| self.files_service.on_did_files_change.unlisten(id);
        if (self.logger_listener) |id| self.loggers.on_did_change_loggers.unlisten(id);
        for (self.channels.items) |channel| self.destroy(channel);
        self.channels.deinit(self.allocator);
        self.on_did_change.deinit();
        self.on_active_output_channel.deinit();
        self.on_visible_channel.deinit();
    }

    fn destroy(self: *OutputService, channel: *OutputChannel) void {
        channel.model.deinit();
        channel.arena.deinit();
        self.allocator.destroy(channel);
    }

    pub fn getChannel(self: *OutputService, id: []const u8) ?*OutputChannel {
        for (self.channels.items) |channel| if (std.mem.eql(u8, channel.descriptor.id, id)) return channel;
        return null;
    }

    pub fn registerChannel(self: *OutputService, descriptor: output.IOutputChannelDescriptor) !*OutputChannel {
        if (self.getChannel(descriptor.id)) |channel| return channel;
        const channel = try self.allocator.create(OutputChannel);
        errdefer self.allocator.destroy(channel);
        channel.arena = .init(self.allocator);
        errdefer channel.arena.deinit();
        const a = channel.arena.allocator();
        channel.descriptor = .{
            .id = try a.dupe(u8, descriptor.id),
            .label = try a.dupe(u8, descriptor.label),
            .source = try std_uri.clone(a, descriptor.source),
            .log = descriptor.log,
            .language_id = if (descriptor.language_id) |id| try a.dupe(u8, id) else null,
            .extension_id = if (descriptor.extension_id) |id| try a.dupe(u8, id) else null,
        };
        channel.model = .init(self.allocator, self.files_service, channel.descriptor.source);
        try self.channels.append(self.allocator, channel);
        if (self.active == null) {
            self.active = channel;
            if (self.visible) channel.model.update(.Append, null) catch {};
            self.on_active_output_channel.fire({}) catch {};
            self.on_visible_channel.fire({}) catch {};
        }
        self.on_did_change.fire({}) catch {};
        return channel;
    }

    pub fn removeChannel(self: *OutputService, id: []const u8) void {
        for (self.channels.items, 0..) |channel, index| {
            if (!std.mem.eql(u8, channel.descriptor.id, id)) continue;
            _ = self.channels.orderedRemove(index);
            const changed = self.active == channel;
            if (changed) self.active = if (self.channels.items.len > 0) self.channels.items[0] else null;
            self.destroy(channel);
            if (changed) {
                if (self.visible) if (self.active) |active| active.model.update(.Append, null) catch {};
                self.on_active_output_channel.fire({}) catch {};
                self.on_visible_channel.fire({}) catch {};
            }
            self.on_did_change.fire({}) catch {};
            return;
        }
    }

    pub fn showChannel(self: *OutputService, id: []const u8) !bool {
        const channel = self.getChannel(id) orelse return false;
        const changed = self.active != channel;
        self.active = channel;
        try channel.model.update(.Append, null);
        if (changed) {
            self.on_active_output_channel.fire({}) catch {};
            self.on_visible_channel.fire({}) catch {};
        }
        try self.on_did_change.fire({});
        return true;
    }

    pub fn setVisible(self: *OutputService, visible: bool) void {
        if (self.visible == visible) return;
        self.visible = visible;
        if (visible) if (self.active) |active| active.model.update(.Append, null) catch {};
        self.on_visible_channel.fire({}) catch {};
        self.on_did_change.fire({}) catch {};
    }

    pub fn update(self: *OutputService, channel_id: []const u8, mode: output.OutputChannelUpdateMode, till: ?usize) !void {
        const channel = self.getChannel(channel_id) orelse return;
        try channel.model.update(mode, till);
        if (channel == self.active) try self.on_did_change.fire({});
    }

    pub fn cycleChannels(self: *OutputService, backwards: bool) !void {
        const active = self.active orelse return;
        const index = std.mem.indexOfScalar(*OutputChannel, self.channels.items, active) orelse return;
        const len = self.channels.items.len;
        _ = try self.showChannel(self.channels.items[if (backwards) (index + len - 1) % len else (index + 1) % len].descriptor.id);
    }

    fn onFilesChanged(event: files.FileChangesEvent, self: *OutputService) !void {
        if (!self.visible) return;
        const active = self.active orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const path = try std_uri.fsPath(active.descriptor.source, a);
        const legacy_key = try std.fmt.allocPrint(a, "{s}:{s}", .{ active.descriptor.source.scheme, path });
        if (!event.contains(legacy_key, &.{}) and !event.contains(try std_uri.encodedResource(a, active.descriptor.source), &.{})) return;
        try self.update(active.descriptor.id, .Append, null);
    }

    fn onLoggersChanged(_: void, self: *OutputService) !void {
        try self.syncLoggers();
    }

    fn syncLoggers(self: *OutputService) !void {
        var index: usize = 0;
        while (index < self.channels.items.len) {
            const channel = self.channels.items[index];
            if (channel.descriptor.log) {
                const logger = try self.loggers.getLogger(channel.descriptor.source);
                if (logger == null or logger.?.options.hidden) {
                    self.removeChannel(channel.descriptor.id);
                    continue;
                }
            }
            index += 1;
        }
        var entries = self.loggers.loggers.valueIterator();
        while (entries.next()) |entry| {
            const logger = entry.*;
            const id = logger.options.id orelse continue;
            if (logger.options.hidden) continue;
            _ = try self.registerChannel(.{ .id = id, .label = logger.options.name orelse id, .source = logger.resource, .log = true, .extension_id = logger.options.extension_id });
        }
    }
};
