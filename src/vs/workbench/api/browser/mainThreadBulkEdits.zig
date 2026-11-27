// Port of `src/vs/workbench/api/browser/mainThreadBulkEdits.ts`.
// The terminal wire boundary revives URI components and carries UTF-16 text
// edits until the model service resolves the actual document.
const std = @import("std");
const Allocator = std.mem.Allocator;
const languages = @import("../../../editor/common/languages.zig");
const Range = @import("../../../editor/common/core/range.zig").Range;
const uri_util = @import("../../../base/common/stdUri.zig");
const VSBuffer = @import("../../../base/common/buffer.zig").VSBuffer;
const bulk = @import("../../../editor/browser/services/bulkEditService.zig");
const Disposable = @import("../../../base/common/lifecycle.zig").IDisposable;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");

pub fn reviveWorkspaceEditDto(a: Allocator, value: std.json.Value) !?languages.WorkspaceEdit {
    if (value == .null) return null;
    if (value != .object) return error.InvalidWorkspaceEdit;
    const edits = value.object.get("edits") orelse return .{};
    if (edits != .array) return error.InvalidWorkspaceEdit;
    var result: std.ArrayList(languages.WorkspaceResourceEdit) = .empty;
    for (edits.array.items) |item| {
        if (item != .object) return error.InvalidWorkspaceEdit;
        const obj = item.object;
        const metadata = try parseMetadata(a, obj.get("metadata"));
        if (obj.get("textEdit")) |text| {
            if (text != .object) return error.InvalidWorkspaceEdit;
            const resource = try parseUri(a, obj.get("resource") orelse return error.InvalidWorkspaceEdit);
            const range = if (text.object.get("range")) |range| if (range == .null) null else try parseRange(range) else null;
            const content = try optionalString(a, text.object.get("text")) orelse "";
            const eol: ?@import("../../../editor/common/core/misc/eolCounter.zig").EOL = if (integer(text.object.get("eol"))) |number| switch (number) {
                0 => .LF,
                1 => .CRLF,
                else => return error.InvalidWorkspaceEdit,
            } else null;
            const raw_version = integer(obj.get("versionId"));
            const version: ?u32 = if (raw_version) |number| std.math.cast(u32, number) orelse return error.InvalidWorkspaceEdit else null;
            try result.append(a, .{ .text = .{ .resource = resource, .range = range, .text = content, .column_encoding = .utf16, .eol = eol, .insert_as_snippet = boolean(text.object.get("insertAsSnippet")), .keep_whitespace = boolean(text.object.get("keepWhitespace")), .version_id = version, .metadata = metadata } });
        } else if (obj.get("oldResource") != null or obj.get("newResource") != null) {
            var edit: languages.WorkspaceFileEdit = .{ .metadata = metadata };
            if (obj.get("oldResource")) |old| if (old != .null) {
                edit.old_resource = try parseUri(a, old);
            };
            if (obj.get("newResource")) |new| if (new != .null) {
                edit.new_resource = try parseUri(a, new);
            };
            if (edit.old_resource == null and edit.new_resource == null) return error.InvalidWorkspaceEdit;
            if (obj.get("options")) |options| if (options == .object) {
                const fields = options.object;
                edit.options = .{
                    .overwrite = optionalBoolean(fields.get("overwrite")),
                    .ignore_if_not_exists = boolean(fields.get("ignoreIfNotExists")),
                    .ignore_if_exists = boolean(fields.get("ignoreIfExists")),
                    .recursive = boolean(fields.get("recursive")),
                    .copy = boolean(fields.get("copy")),
                    .folder = boolean(fields.get("folder")),
                    .skip_trash_bin = boolean(fields.get("skipTrashBin")),
                    .max_size = integer(fields.get("maxSize")),
                };
                if (fields.get("contents")) |contents| if (contents == .object) {
                    const encoding = contents.object.get("type") orelse return error.InvalidWorkspaceEdit;
                    if (encoding != .string or !std.mem.eql(u8, encoding.string, "base64")) return error.UnsupportedDataTransferFile;
                    const data = contents.object.get("value") orelse return error.InvalidWorkspaceEdit;
                    if (data != .string) return error.InvalidWorkspaceEdit;
                    edit.options.contents = (try VSBuffer.fromBase64(a, data.string)).bytes;
                };
            };
            try result.append(a, .{ .file = edit });
        } else return error.UnsupportedResourceEdit;
    }
    return .{ .edits = result.items };
}

fn parseUri(a: Allocator, value: std.json.Value) !std.Uri {
    const components = try uri_util.componentsFromJson(value, a);
    return .{ .scheme = components.scheme, .host = if (components.authority.len > 0) .{ .raw = components.authority } else null, .path = .{ .raw = components.path }, .query = if (components.query.len > 0) .{ .raw = components.query } else null, .fragment = if (components.fragment.len > 0) .{ .raw = components.fragment } else null };
}

fn parseRange(value: std.json.Value) !Range {
    if (value != .object) return error.InvalidWorkspaceEdit;
    const obj = value.object;
    const line = integer(obj.get("startLineNumber")) orelse return error.InvalidWorkspaceEdit;
    const col = integer(obj.get("startColumn")) orelse return error.InvalidWorkspaceEdit;
    const end_line = integer(obj.get("endLineNumber")) orelse return error.InvalidWorkspaceEdit;
    const end_col = integer(obj.get("endColumn")) orelse return error.InvalidWorkspaceEdit;
    if (line == 0 or col == 0 or end_line == 0 or end_col == 0) return error.InvalidWorkspaceEdit;
    return .init(line, col, end_line, end_col);
}

fn integer(value: ?std.json.Value) ?usize {
    const v = value orelse return null;
    return if (v == .integer and v.integer >= 0) std.math.cast(usize, v.integer) else null;
}
fn optionalBoolean(value: ?std.json.Value) ?bool {
    const v = value orelse return null;
    return if (v == .bool) v.bool else null;
}
fn boolean(value: ?std.json.Value) bool {
    const v = value orelse return false;
    return v == .bool and v.bool;
}
fn optionalString(a: Allocator, value: ?std.json.Value) !?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) try a.dupe(u8, v.string) else null;
}
fn parseMetadata(a: Allocator, value: ?std.json.Value) !?languages.WorkspaceEditMetadata {
    const v = value orelse return null;
    if (v != .object) return null;
    return .{ .needs_confirmation = boolean(v.object.get("needsConfirmation")), .label = try optionalString(a, v.object.get("label")) orelse "", .description = try optionalString(a, v.object.get("description")) };
}

pub const MainThreadBulkEdits = struct {
    allocator: Allocator,
    service: bulk.IBulkEditService,
    requests: std.ArrayList(*Request) = .empty,

    const Request = struct {
        owner: *MainThreadBulkEdits,
        arena: std.heap.ArenaAllocator,
        edit: languages.WorkspaceEdit,
        undo_redo_group_id: ?u64 = null,
        respect_auto_save: bool,
        channel: ?*rpc.RpcProtocol = null,
        id: u32 = 0,
        pending: ?Disposable = null,
        starting: bool = false,
        done: bool = false,

        fn start(context: *anyopaque, channel: *rpc.RpcProtocol, id: u32) void {
            const self: *Request = @ptrCast(@alignCast(context));
            self.channel = channel;
            self.id = id;
            self.starting = true;
            self.pending = self.owner.service.apply(self.edit, .{ .respect_auto_save_config = self.respect_auto_save, .undo_redo_group_id = self.undo_redo_group_id }, .{ .context = self, .complete = ready }) catch |err| blk: {
                ready(self, err);
                break :blk null;
            };
            self.starting = false;
            if (self.done) self.dispose();
        }

        fn ready(context: *anyopaque, result: anyerror!bulk.IBulkEditResult) void {
            const self: *Request = @ptrCast(@alignCast(context));
            self.pending = null;
            self.done = true;
            if (self.channel) |channel| channel.sendReply(self.id, .{ .json = .{ .bool = if (result) |applied| applied.is_applied else |_| false } });
            self.channel = null;
            if (!self.starting) self.dispose();
        }

        fn dispose(self: *Request) void {
            if (self.pending) |pending| pending.dispose();
            const owner = self.owner;
            for (owner.requests.items, 0..) |candidate, i| if (candidate == self) {
                _ = owner.requests.swapRemove(i);
                break;
            };
            self.arena.deinit();
            owner.allocator.destroy(self);
        }
    };

    pub fn deinit(self: *MainThreadBulkEdits) void {
        while (self.requests.items.len > 0) self.requests.items[self.requests.items.len - 1].dispose();
        self.requests.deinit(self.allocator);
    }

    pub fn invoke(self: *MainThreadBulkEdits, method: []const u8, args: []const rpc.Arg) !rpc.HandlerReply {
        if (!std.mem.eql(u8, method, "$tryApplyWorkspaceEdit")) return .empty;
        if (args.len == 0 or args[0] != .json) return .{ .json = .{ .bool = false } };
        const request = try self.allocator.create(Request);
        errdefer self.allocator.destroy(request);
        request.* = .{ .owner = self, .arena = .init(self.allocator), .edit = undefined, .respect_auto_save = args.len > 2 and args[2] == .json and boolean(args[2].json), .undo_redo_group_id = if (args.len > 1 and args[1] == .json) integer(args[1].json) else null };
        errdefer request.arena.deinit();
        const value = args[0].json;
        const dto = if (value == .object) value.object.get("value") orelse value else value;
        request.edit = (try reviveWorkspaceEditDto(request.arena.allocator(), dto)) orelse .{};
        try self.requests.append(self.allocator, request);
        return .{ .deferred = .{ .context = request, .start = Request.start } };
    }
};
