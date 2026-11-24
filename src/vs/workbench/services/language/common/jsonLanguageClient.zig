// TUI adaptation of the JSON client/server contract from
// `vscode/extensions/json-language-features/client/src/jsonClient.ts`.
//
// The reader owns framing and JSON decoding. Provider promises complete on the
// terminal event loop. Explicit commands can also await their own response
// without running unrelated provider callbacks inside the calling command.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const time_compat = @import("../../../../base/common/timeCompat.zig");

/// The client creates its own `Io` for the server process. `std.process.spawn`
/// resolves the bare `node` executable name against that `Io`'s environment,
/// not the calling process's, so the instance must carry the process
/// environment or every start fails with `FileNotFound`.
fn processEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => if (builtin.link_libc)
            .{ .block = .{ .slice = @ptrCast(@as([:null]?[*:0]u8, std.mem.span(std.c.environ))) } }
        else
            .empty,
    };
}

/// `std.os.linux.getpid` type-checks on every target but issues a Linux
/// syscall, which traps with SIGSYS on other kernels. The LSP `processId` is
/// sent during the initialize handshake on every platform.
fn currentProcessId() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .plan9 => std.os.plan9.getpid(),
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
}

pub const Diagnostic = struct {
    start_line: u32,
    start_character: u32,
    end_line: u32,
    end_character: u32,
    severity: u8,
    message: []u8,
};

pub const CompletionItem = struct {
    label: []u8,
    kind: u8,
    insert_text: ?[]u8,
};

pub const Hover = struct {
    text: []u8,
};

pub const FormattingEdit = struct {
    start_line: u32,
    start_character: u32,
    end_line: u32,
    end_character: u32,
    new_text: []u8,
};

/// Zero-based LSP range. The caller converts it to the editor's 1-based UTF-8
/// columns with the target document's lines.
pub const LspRange = struct {
    start_line: u32,
    start_character: u32,
    end_line: u32,
    end_character: u32,
};

pub const JsonDocumentSymbol = struct {
    name: []u8,
    detail: []u8 = &.{},
    kind: u32 = 0,
    tags: []const u32 = &.{},
    container_name: ?[]u8 = null,
    range: LspRange,
    selection_range: LspRange,
    children: []JsonDocumentSymbol = &.{},
};

pub const Error = error{
    ServerUnavailable,
    InvalidMessage,
    RequestFailed,
};

pub const Document = struct {
    client: ?*Client = null,
    uri: ?[]const u8 = null,
};

const Message = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,

    fn result(self: *const Message) std.json.Value {
        return self.value.object.get("result") orelse .null;
    }
};

pub const ResponseHandler = struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, std.json.Value) void,
};

pub const Client = struct {
    allocator: Allocator,
    io_state: std.Io.Threaded,
    io: Io,
    child: std.process.Child,
    next_id: u32 = 1,
    buffer: std.array_list.Managed(u8),
    root_uri: []u8,
    initialized: bool = false,
    reader: ?std.Thread = null,
    queue: std.ArrayList(Message) = .empty,
    lock: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,
    eof: bool = false,
    handlers: std.AutoHashMapUnmanaged(u32, ResponseHandler) = .empty,

    pub fn start(allocator: Allocator, node_path: []const u8, server_script: []const u8) !*Client {
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io_state = undefined,
            .io = undefined,
            .child = undefined,
            .buffer = .init(allocator),
            .root_uri = try allocator.dupe(u8, "file:///"),
        };
        errdefer allocator.free(self.root_uri);
        self.io_state = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = processEnviron() });
        self.io = self.io_state.io();

        errdefer self.io_state.deinit();
        self.child = std.process.spawn(self.io, .{
            .argv = &.{ node_path, server_script, "--stdio" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return Error.ServerUnavailable;
        errdefer self.stopTransport();
        if (self.child.stdin == null or self.child.stdout == null) return Error.ServerUnavailable;

        self.reader = try std.Thread.spawn(.{}, readerLoop, .{ self, self.child.stdout.? });
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var params: std.json.ObjectMap = .empty;
        try params.put(arena.allocator(), "processId", .{ .integer = @intCast(currentProcessId()) });
        try params.put(arena.allocator(), "rootUri", .{ .string = self.root_uri });
        try params.put(arena.allocator(), "workspaceFolders", blk: {
            var folders = std.json.Array.init(arena.allocator());
            var folder: std.json.ObjectMap = .empty;
            try folder.put(arena.allocator(), "uri", .{ .string = self.root_uri });
            try folder.put(arena.allocator(), "name", .{ .string = "workspace" });
            try folders.append(.{ .object = folder });
            break :blk .{ .array = folders };
        });
        var capabilities: std.json.ObjectMap = .empty;
        var text_document: std.json.ObjectMap = .empty;
        try text_document.put(arena.allocator(), "diagnostic", .{ .object = .empty });
        var completion_capability: std.json.ObjectMap = .empty;
        var completion_item: std.json.ObjectMap = .empty;
        try completion_item.put(arena.allocator(), "snippetSupport", .{ .bool = false });
        try completion_capability.put(arena.allocator(), "completionItem", .{ .object = completion_item });
        try text_document.put(arena.allocator(), "completion", .{ .object = completion_capability });
        var document_symbol_capability: std.json.ObjectMap = .empty;
        try document_symbol_capability.put(arena.allocator(), "hierarchicalDocumentSymbolSupport", .{ .bool = true });
        try text_document.put(arena.allocator(), "documentSymbol", .{ .object = document_symbol_capability });
        try capabilities.put(arena.allocator(), "textDocument", .{ .object = text_document });
        try params.put(arena.allocator(), "capabilities", .{ .object = capabilities });
        var init_options: std.json.ObjectMap = .empty;
        try init_options.put(arena.allocator(), "provideFormatter", .{ .bool = true });
        try params.put(arena.allocator(), "initializationOptions", .{ .object = init_options });
        var response = try self.request(arena.allocator(), "initialize", .{ .object = params });
        defer response.arena.deinit();
        const result = response.result();
        if (result != .object or result.object.get("capabilities") == null) return Error.InvalidMessage;
        self.notify(arena.allocator(), "initialized", .{ .object = .empty }) catch {};

        try self.configure(arena.allocator(), null);
        self.initialized = true;
        return self;
    }

    /// Sends the settings the JSON server consumes. `schemas` is the raw
    /// `json.schemas` setting value, borrowed only for this call.
    pub fn configure(self: *Client, arena: Allocator, schemas: ?std.json.Value) !void {
        return self.configureWithLimit(arena, schemas, 5000);
    }

    pub fn configureWithLimit(self: *Client, arena: Allocator, schemas: ?std.json.Value, limit: i64) !void {
        var json_settings: std.json.ObjectMap = .empty;
        try json_settings.put(arena, "resultLimit", .{ .integer = (if (limit > 0) limit else @as(i64, 5000)) +| 1 });
        var validate: std.json.ObjectMap = .empty;
        try validate.put(arena, "enable", .{ .bool = true });
        try json_settings.put(arena, "validate", .{ .object = validate });
        if (schemas) |value| try json_settings.put(arena, "schemas", value);
        var settings: std.json.ObjectMap = .empty;
        try settings.put(arena, "json", .{ .object = json_settings });
        var settings_root: std.json.ObjectMap = .empty;
        try settings_root.put(arena, "settings", .{ .object = settings });
        try self.notify(arena, "workspace/didChangeConfiguration", .{ .object = settings_root });
    }

    pub fn deinit(self: *Client) void {
        if (self.child.id != null) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            self.notify(arena.allocator(), "shutdown", .null) catch {};
            self.notify(arena.allocator(), "exit", .null) catch {};
        }
        self.stopTransport();
        self.io_state.deinit();
        self.allocator.free(self.root_uri);
        self.allocator.destroy(self);
    }

    pub fn didOpen(self: *Client, arena: Allocator, uri: []const u8, language_id: []const u8, text: []const u8) !void {
        try self.didOpenVersion(arena, uri, language_id, 1, text);
    }

    pub fn didOpenVersion(self: *Client, arena: Allocator, uri: []const u8, language_id: []const u8, version: u32, text: []const u8) !void {
        var doc: std.json.ObjectMap = .empty;
        try doc.put(arena, "uri", .{ .string = try arena.dupe(u8, uri) });
        try doc.put(arena, "languageId", .{ .string = try arena.dupe(u8, language_id) });
        try doc.put(arena, "version", .{ .integer = version });
        try doc.put(arena, "text", .{ .string = try arena.dupe(u8, text) });
        var params: std.json.ObjectMap = .empty;
        try params.put(arena, "textDocument", .{ .object = doc });
        try self.notify(arena, "textDocument/didOpen", .{ .object = params });
    }

    pub fn didClose(self: *Client, arena: Allocator, uri: []const u8) !void {
        var doc: std.json.ObjectMap = .empty;
        try doc.put(arena, "uri", .{ .string = uri });
        var params: std.json.ObjectMap = .empty;
        try params.put(arena, "textDocument", .{ .object = doc });
        try self.notify(arena, "textDocument/didClose", .{ .object = params });
    }

    pub fn didChange(self: *Client, arena: Allocator, uri: []const u8, version: u32, text: []const u8) !void {
        return self.didChangeContent(arena, uri, version, &.{.{ .text = text }});
    }

    pub const ContentChange = struct {
        range: ?LspRange = null,
        text: []const u8,
    };

    pub fn didChangeContent(self: *Client, arena: Allocator, uri: []const u8, version: u32, edits: []const ContentChange) !void {
        var doc: std.json.ObjectMap = .empty;
        try doc.put(arena, "uri", .{ .string = uri });
        try doc.put(arena, "version", .{ .integer = version });
        var changes = std.json.Array.init(arena);
        for (edits) |edit| {
            var change: std.json.ObjectMap = .empty;
            if (edit.range) |r| {
                var range: std.json.ObjectMap = .empty;
                try range.put(arena, "start", try lspPosition(arena, r.start_line, r.start_character));
                try range.put(arena, "end", try lspPosition(arena, r.end_line, r.end_character));
                try change.put(arena, "range", .{ .object = range });
            }
            try change.put(arena, "text", .{ .string = edit.text });
            try changes.append(.{ .object = change });
        }
        var params: std.json.ObjectMap = .empty;
        try params.put(arena, "textDocument", .{ .object = doc });
        try params.put(arena, "contentChanges", .{ .array = changes });
        try self.notify(arena, "textDocument/didChange", .{ .object = params });
    }

    pub fn pullDiagnostics(self: *Client, arena: Allocator, uri: []const u8) ![]Diagnostic {
        var doc: std.json.ObjectMap = .empty;
        try doc.put(arena, "uri", .{ .string = try arena.dupe(u8, uri) });
        var params: std.json.ObjectMap = .empty;
        try params.put(arena, "textDocument", .{ .object = doc });
        var response = try self.request(arena, "textDocument/diagnostic", .{ .object = params });
        defer response.arena.deinit();
        const result = response.result();
        return parseDiagnostics(arena, result);
    }

    pub fn parseDiagnostics(arena: Allocator, result: std.json.Value) ![]Diagnostic {
        if (result != .object) return &.{};
        const items_value = result.object.get("items") orelse return &.{};
        if (items_value != .array) return &.{};
        var diagnostics = std.array_list.Managed(Diagnostic).init(arena);
        for (items_value.array.items) |item| {
            if (item != .object) continue;
            const object = item.object;
            const range = object.get("range") orelse continue;
            if (range != .object) continue;
            const start_position = range.object.get("start") orelse continue;
            const end_position = range.object.get("end") orelse continue;
            if (start_position != .object or end_position != .object) continue;
            const message = object.get("message") orelse continue;
            if (message != .string) continue;
            const severity = object.get("severity");
            try diagnostics.append(.{
                .start_line = integerField(start_position.object, "line"),
                .start_character = integerField(start_position.object, "character"),
                .end_line = integerField(end_position.object, "line"),
                .end_character = integerField(end_position.object, "character"),
                .severity = if (severity != null and severity.? == .integer) @intCast(severity.?.integer) else 1,
                .message = try arena.dupe(u8, message.string),
            });
        }
        return diagnostics.toOwnedSlice();
    }

    pub fn completion(self: *Client, arena: Allocator, uri: []const u8, line: u32, character: u32) ![]CompletionItem {
        var doc: std.json.ObjectMap = .empty;
        try doc.put(arena, "uri", .{ .string = try arena.dupe(u8, uri) });
        var position: std.json.ObjectMap = .empty;
        try position.put(arena, "line", .{ .integer = @intCast(line) });
        try position.put(arena, "character", .{ .integer = @intCast(character) });
        var params: std.json.ObjectMap = .empty;
        try params.put(arena, "textDocument", .{ .object = doc });
        try params.put(arena, "position", .{ .object = position });
        var response = try self.request(arena, "textDocument/completion", .{ .object = params });
        defer response.arena.deinit();
        const result = response.result();
        const items_value = if (result == .array)
            result
        else if (result == .object and result.object.get("items") != null)
            result.object.get("items").?
        else
            return &.{};
        if (items_value != .array) return &.{};
        var items = std.array_list.Managed(CompletionItem).init(arena);
        for (items_value.array.items) |item| {
            if (item != .object) continue;
            const object = item.object;
            const label = object.get("label") orelse continue;
            if (label != .string) continue;
            const kind = object.get("kind");
            const insert_text = object.get("insertText");
            try items.append(.{
                .label = try arena.dupe(u8, label.string),
                .kind = if (kind != null and kind.? == .integer) @intCast(kind.?.integer) else 0,
                .insert_text = if (insert_text != null and insert_text.? == .string) try arena.dupe(u8, insert_text.?.string) else null,
            });
        }
        return items.toOwnedSlice();
    }

    pub fn hover(self: *Client, arena: Allocator, uri: []const u8, line: u32, character: u32) !?Hover {
        var doc: std.json.ObjectMap = .empty;
        try doc.put(arena, "uri", .{ .string = try arena.dupe(u8, uri) });
        var position: std.json.ObjectMap = .empty;
        try position.put(arena, "line", .{ .integer = @intCast(line) });
        try position.put(arena, "character", .{ .integer = @intCast(character) });
        var params: std.json.ObjectMap = .empty;
        try params.put(arena, "textDocument", .{ .object = doc });
        try params.put(arena, "position", .{ .object = position });
        var response = try self.request(arena, "textDocument/hover", .{ .object = params });
        defer response.arena.deinit();
        const result = response.result();
        if (result != .object) return null;
        const contents = result.object.get("contents") orelse return null;
        const text = try hoverText(arena, contents);
        return .{ .text = text };
    }

    pub fn documentSymbols(self: *Client, arena: Allocator, uri: []const u8) ![]JsonDocumentSymbol {
        var doc: std.json.ObjectMap = .empty;
        try doc.put(arena, "uri", .{ .string = try arena.dupe(u8, uri) });
        var params: std.json.ObjectMap = .empty;
        try params.put(arena, "textDocument", .{ .object = doc });
        var response = try self.request(arena, "textDocument/documentSymbol", .{ .object = params });
        defer response.arena.deinit();
        const result = response.result();
        return parseDocumentSymbols(arena, result);
    }

    pub fn formatting(self: *Client, arena: Allocator, uri: []const u8, tab_size: u32, insert_spaces: bool) ![]FormattingEdit {
        var doc: std.json.ObjectMap = .empty;
        try doc.put(arena, "uri", .{ .string = try arena.dupe(u8, uri) });
        var options: std.json.ObjectMap = .empty;
        try options.put(arena, "tabSize", .{ .integer = @intCast(tab_size) });
        try options.put(arena, "insertSpaces", .{ .bool = insert_spaces });
        var params: std.json.ObjectMap = .empty;
        try params.put(arena, "textDocument", .{ .object = doc });
        try params.put(arena, "options", .{ .object = options });
        var response = try self.request(arena, "textDocument/formatting", .{ .object = params });
        defer response.arena.deinit();
        const result = response.result();
        if (result != .array) return &.{};
        var edits = std.array_list.Managed(FormattingEdit).init(arena);
        for (result.array.items) |item| {
            if (item != .object) continue;
            const range = item.object.get("range") orelse continue;
            if (range != .object) continue;
            const start_position = range.object.get("start") orelse continue;
            const end_position = range.object.get("end") orelse continue;
            if (start_position != .object or end_position != .object) continue;
            const new_text = item.object.get("newText") orelse continue;
            if (new_text != .string) continue;
            try edits.append(.{
                .start_line = integerField(start_position.object, "line"),
                .start_character = integerField(start_position.object, "character"),
                .end_line = integerField(end_position.object, "line"),
                .end_character = integerField(end_position.object, "character"),
                .new_text = try arena.dupe(u8, new_text.string),
            });
        }
        return edits.toOwnedSlice();
    }

    fn notify(self: *Client, arena: Allocator, method: []const u8, params: std.json.Value) !void {
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "jsonrpc", .{ .string = "2.0" });
        try object.put(arena, "method", .{ .string = try arena.dupe(u8, method) });
        try object.put(arena, "params", params);
        try self.writeMessage(arena, .{ .object = object });
    }

    fn sendRequest(self: *Client, arena: Allocator, method: []const u8, params: std.json.Value) !u32 {
        const id = self.next_id;
        self.next_id +%= 1;
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "jsonrpc", .{ .string = "2.0" });
        try object.put(arena, "id", .{ .integer = @intCast(id) });
        try object.put(arena, "method", .{ .string = try arena.dupe(u8, method) });
        try object.put(arena, "params", params);
        try self.writeMessage(arena, .{ .object = object });

        return id;
    }

    pub fn requestDocument(self: *Client, arena: Allocator, method: []const u8, uri: []const u8, handler: ResponseHandler) !u32 {
        var doc: std.json.ObjectMap = .empty;
        try doc.put(arena, "uri", .{ .string = uri });
        var params: std.json.ObjectMap = .empty;
        try params.put(arena, "textDocument", .{ .object = doc });
        try self.handlers.ensureUnusedCapacity(self.allocator, 1);
        const id = try self.sendRequest(arena, method, .{ .object = params });
        self.handlers.putAssumeCapacity(id, handler);
        return id;
    }

    pub fn cancel(self: *Client, id: u32) void {
        if (!self.handlers.remove(id)) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var params: std.json.ObjectMap = .empty;
        params.put(arena.allocator(), "id", .{ .integer = id }) catch return;
        self.notify(arena.allocator(), "$/cancelRequest", .{ .object = params }) catch {};
    }

    fn stopTransport(self: *Client) void {
        // Closing the server releases a blocked pipe read. The reader uses
        // its own file value and never accesses the mutable Child.
        if (self.child.id != null) self.child.kill(self.io);
        if (self.reader) |thread| thread.join();
        for (self.queue.items) |*message| message.arena.deinit();
        self.queue.deinit(self.allocator);
        self.handlers.deinit(self.allocator);
        self.buffer.deinit();
    }

    fn readerLoop(self: *Client, file: std.Io.File) void {
        defer {
            self.lock.lockUncancelable(self.io);
            self.eof = true;
            self.available.broadcast(self.io);
            self.lock.unlock(self.io);
        }
        while (true) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            const message = self.readMessage(arena.allocator(), file) catch {
                arena.deinit();
                return;
            };
            if (message != .object) {
                arena.deinit();
                continue;
            }
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            self.queue.append(self.allocator, .{ .arena = arena, .value = message }) catch {
                arena.deinit();
                return;
            };
            self.available.signal(self.io);
        }
    }

    fn nextMessage(self: *Client, id: ?u32, wait: bool) !?Message {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        while (true) {
            for (self.queue.items, 0..) |*message, i| {
                if (id) |target| {
                    const obj = message.value.object;
                    if (!obj.contains("method")) {
                        const response_id = obj.get("id") orelse continue;
                        if (response_id != .integer or response_id.integer != target) continue;
                    }
                }
                return self.queue.orderedRemove(i);
            }
            if (self.eof) return Error.ServerUnavailable;
            if (!wait) return null;
            self.available.waitUncancelable(self.io, &self.lock);
        }
    }

    fn handleMethod(self: *Client, message: *Message) !bool {
        const object = message.value.object;
        const method = object.get("method") orelse return false;
        if (object.get("id")) |id| try self.answerServerRequest(message.arena.allocator(), object, id, method);
        return true;
    }

    // Dispatch actual incoming messages, including server-initiated requests.
    pub fn dispatchResponses(self: *Client, wait: bool) bool {
        var completed = false;
        while (true) {
            var message = (self.nextMessage(null, wait and !completed and self.handlers.count() != 0) catch {
                while (self.handlers.count() != 0) {
                    var keys = self.handlers.keyIterator();
                    const key = keys.next().?.*;
                    const removed = self.handlers.fetchRemove(key).?;
                    removed.value.complete(removed.value.context, .null);
                    completed = true;
                }
                return completed;
            }) orelse return completed;
            defer message.arena.deinit();
            if (self.handleMethod(&message) catch true) continue;
            const id = message.value.object.get("id") orelse continue;
            if (id != .integer) continue;
            const key = std.math.cast(u32, id.integer) orelse continue;
            const pending = self.handlers.fetchRemove(key) orelse continue;
            pending.value.complete(pending.value.context, message.result());
            completed = true;
        }
    }

    fn request(self: *Client, arena: Allocator, method: []const u8, params: std.json.Value) !Message {
        const id = try self.sendRequest(arena, method, params);
        while (true) {
            var message = (try self.nextMessage(id, true)).?;
            errdefer message.arena.deinit();
            if (try self.handleMethod(&message)) {
                message.arena.deinit();
                continue;
            }
            if (message.value.object.contains("error")) return Error.RequestFailed;
            return message;
        }
    }

    fn answerServerRequest(self: *Client, arena: Allocator, object: std.json.ObjectMap, id: std.json.Value, method_value: std.json.Value) !void {
        if (method_value != .string) return;
        const method = method_value.string;
        var response: std.json.ObjectMap = .empty;
        try response.put(arena, "jsonrpc", .{ .string = "2.0" });
        try response.put(arena, "id", id);
        if (std.mem.eql(u8, method, "workspace/configuration")) {
            var result = std.json.Array.init(arena);
            const items = if (object.get("params")) |params| if (params == .object) params.object.get("items") else null else null;
            if (items != null and items.? == .array) {
                for (items.?.array.items) |_| try result.append(.{ .object = .empty });
            }
            try response.put(arena, "result", .{ .array = result });
        } else if (std.mem.eql(u8, method, "workspace/workspaceFolders")) {
            var folders = std.json.Array.init(arena);
            var folder: std.json.ObjectMap = .empty;
            try folder.put(arena, "uri", .{ .string = "file:///" });
            try folder.put(arena, "name", .{ .string = "workspace" });
            try folders.append(.{ .object = folder });
            try response.put(arena, "result", .{ .array = folders });
        } else {
            try response.put(arena, "result", .null);
        }
        try self.writeMessage(arena, .{ .object = response });
    }

    fn writeMessage(self: *Client, arena: Allocator, value: std.json.Value) !void {
        var output: std.Io.Writer.Allocating = .init(arena);
        defer output.deinit();
        try std.json.Stringify.value(value, .{}, &output.writer);
        const body = output.written();
        var header_buffer: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buffer, "Content-Length: {d}\r\n\r\n", .{body.len});
        const file = self.child.stdin orelse return Error.ServerUnavailable;
        try file.writeStreamingAll(self.io, header);
        try file.writeStreamingAll(self.io, body);
    }

    fn readMessage(self: *Client, arena: Allocator, file: std.Io.File) !std.json.Value {
        while (true) {
            if (std.mem.indexOf(u8, self.buffer.items, "\r\n\r\n")) |header_end| {
                const header = self.buffer.items[0..header_end];
                const length = contentLength(header) orelse return Error.InvalidMessage;
                const total = header_end + 4 + length;
                if (self.buffer.items.len >= total) {
                    const body = self.buffer.items[header_end + 4 .. total];
                    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .allocate = .alloc_always });
                    const consumed = total;
                    std.mem.copyForwards(u8, self.buffer.items[0 .. self.buffer.items.len - consumed], self.buffer.items[consumed..]);
                    self.buffer.shrinkRetainingCapacity(self.buffer.items.len - consumed);
                    return value;
                }
            }
            var chunk: [64 * 1024]u8 = undefined;
            const count = file.readStreaming(self.io, &.{&chunk}) catch return Error.ServerUnavailable;
            if (count == 0) return Error.ServerUnavailable;
            try self.buffer.appendSlice(chunk[0..count]);
        }
    }
};

pub fn parseDocumentSymbols(arena: Allocator, result: std.json.Value) ![]JsonDocumentSymbol {
    if (result != .array) return &.{};
    var symbols = std.array_list.Managed(JsonDocumentSymbol).init(arena);
    for (result.array.items) |item| {
        if (item != .object) continue;
        const symbol = try parseDocumentSymbol(arena, item.object);
        if (symbol) |value| try symbols.append(value);
    }
    return symbols.toOwnedSlice();
}

fn lspPosition(arena: Allocator, line: u32, character: u32) !std.json.Value {
    var pos: std.json.ObjectMap = .empty;
    try pos.put(arena, "line", .{ .integer = line });
    try pos.put(arena, "character", .{ .integer = character });
    return .{ .object = pos };
}

fn parseDocumentSymbol(arena: Allocator, object: std.json.ObjectMap) !?JsonDocumentSymbol {
    const name_value = object.get("name") orelse return null;
    if (name_value != .string) return null;
    const kind: u32 = if (object.get("kind")) |value|
        if (value == .integer and value.integer >= 0) @intCast(value.integer) else 0
    else
        0;

    var range: LspRange = undefined;
    var selection_range: LspRange = undefined;
    var children: []JsonDocumentSymbol = &.{};
    var container_name: ?[]u8 = null;
    var detail: []u8 = &.{};

    if (object.get("location")) |location| {
        // Flat `SymbolInformation` shape.
        if (location != .object) return null;
        range = parseLspRange(location.object.get("range")) orelse return null;
        selection_range = range;
        container_name = try optionalString(arena, object.get("containerName"));
    } else {
        range = parseLspRange(object.get("range")) orelse return null;
        selection_range = parseLspRange(object.get("selectionRange")) orelse range;
        container_name = try optionalString(arena, object.get("containerName"));
        detail = if (object.get("detail")) |value|
            if (value == .string) try arena.dupe(u8, value.string) else &.{}
        else
            &.{};
        if (object.get("children")) |value| {
            if (value == .array) {
                var list = std.array_list.Managed(JsonDocumentSymbol).init(arena);
                for (value.array.items) |child| {
                    if (child != .object) continue;
                    if (try parseDocumentSymbol(arena, child.object)) |symbol| try list.append(symbol);
                }
                children = try list.toOwnedSlice();
            }
        }
    }

    var tags: []const u32 = &.{};
    if (object.get("tags")) |value| {
        if (value == .array) {
            var list = std.array_list.Managed(u32).init(arena);
            for (value.array.items) |tag| {
                if (tag == .integer and tag.integer >= 0) try list.append(@intCast(tag.integer));
            }
            tags = try list.toOwnedSlice();
        }
    }

    return JsonDocumentSymbol{
        .name = try arena.dupe(u8, name_value.string),
        .detail = detail,
        .kind = kind,
        .tags = tags,
        .container_name = container_name,
        .range = range,
        .selection_range = selection_range,
        .children = children,
    };
}

fn parseLspRange(value: ?std.json.Value) ?LspRange {
    const raw = value orelse return null;
    if (raw != .object) return null;
    const start = raw.object.get("start") orelse return null;
    const end = raw.object.get("end") orelse return null;
    if (start != .object or end != .object) return null;
    return .{
        .start_line = integerField(start.object, "line"),
        .start_character = integerField(start.object, "character"),
        .end_line = integerField(end.object, "line"),
        .end_character = integerField(end.object, "character"),
    };
}

fn optionalString(arena: Allocator, value: ?std.json.Value) !?[]u8 {
    const raw = value orelse return null;
    if (raw != .string) return null;
    return try arena.dupe(u8, raw.string);
}

fn contentLength(header: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Content-Length:")) continue;
        const value = std.mem.trim(u8, line["Content-Length:".len..], " ");
        return std.fmt.parseInt(usize, value, 10) catch null;
    }
    return null;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) u32 {
    const value = object.get(name) orelse return 0;
    if (value != .integer or value.integer < 0) return 0;
    return @intCast(value.integer);
}

fn hoverText(arena: Allocator, contents: std.json.Value) ![]u8 {
    if (contents == .string) return arena.dupe(u8, contents.string);
    if (contents == .object) {
        if (contents.object.get("value")) |value| {
            if (value == .string) return arena.dupe(u8, value.string);
        }
    }
    if (contents == .array) {
        var output = std.array_list.Managed(u8).init(arena);
        for (contents.array.items) |item| {
            const text = try hoverText(arena, item);
            if (output.items.len > 0) try output.appendSlice("\n");
            try output.appendSlice(text);
        }
        return output.toOwnedSlice();
    }
    return arena.dupe(u8, "");
}

test "JSON language client reports syntax diagnostics" {
    std.Io.Dir.cwd().access(time_compat.io, "host/dist/jsonServer.mjs", .{}) catch return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const client = try Client.start(allocator, "node", "host/dist/jsonServer.mjs");
    defer client.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    try client.didOpen(scratch, "file:///tmp/test.json", "json", "{\n  \"a\": 1\n");
    const diagnostics = try client.pullDiagnostics(scratch, "file:///tmp/test.json");
    try std.testing.expect(diagnostics.len > 0);
    try std.testing.expect(diagnostics[0].message.len > 0);

    try client.didChange(scratch, "file:///tmp/test.json", 2, "{\n  \"name\": 1,\n  \"");
    const completion = try client.completion(scratch, "file:///tmp/test.json", 2, 3);
    try std.testing.expect(completion.len > 0);

    try client.didChange(scratch, "file:///tmp/test.json", 3, "{\"a\":1}");
    const edits = try client.formatting(scratch, "file:///tmp/test.json", 4, true);
    try std.testing.expect(edits.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, edits[0].new_text, "\n") != null);
}

test "JSON language client hover uses a local schema" {
    std.Io.Dir.cwd().access(time_compat.io, "host/dist/jsonServer.mjs", .{}) catch return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const client = try Client.start(allocator, "node", "host/dist/jsonServer.mjs");
    defer client.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(time_compat.io, .{ .sub_path = "schema.json", .data =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string", "description": "The name field" }
        \\  }
        \\}
    });
    var schema_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const schema_path_length = try tmp.dir.realPathFile(time_compat.io, "schema.json", &schema_path_buffer);
    const schema_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{schema_path_buffer[0..schema_path_length]});
    defer allocator.free(schema_uri);

    const text = try std.fmt.allocPrint(allocator, "{{\n  \"$schema\": \"{s}\",\n  \"name\": \"demo\"\n}}\n", .{schema_uri});
    defer allocator.free(text);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const document_uri = "file:///tmp/json-hover-test.json";
    try client.didOpen(scratch, document_uri, "json", text);
    const hover = try client.hover(scratch, document_uri, 2, 4);
    try std.testing.expect(hover != null);
    try std.testing.expect(std.mem.indexOf(u8, hover.?.text, "The name field") != null);
}

test "JSON language client applies json.schemas associations" {
    std.Io.Dir.cwd().access(time_compat.io, "host/dist/jsonServer.mjs", .{}) catch return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const client = try Client.start(allocator, "node", "host/dist/jsonServer.mjs");
    defer client.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(time_compat.io, .{ .sub_path = "schema.json", .data =
        \\{
        \\  "type": "object",
        \\  "properties": { "name": { "type": "string" } },
        \\  "required": ["name"]
        \\}
    });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try tmp.dir.realPathFile(time_compat.io, "schema.json", &path_buffer);
    const schema_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{path_buffer[0..path_length]});
    defer allocator.free(schema_uri);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var schema_entry: std.json.ObjectMap = .empty;
    var file_match = std.json.Array.init(scratch);
    try file_match.append(.{ .string = "*.json" });
    try schema_entry.put(scratch, "fileMatch", .{ .array = file_match });
    try schema_entry.put(scratch, "url", .{ .string = schema_uri });
    var schemas = std.json.Array.init(scratch);
    try schemas.append(.{ .object = schema_entry });
    try client.configure(scratch, .{ .array = schemas });

    const uri = "file:///tmp/schema-validation.json";
    try client.didOpen(scratch, uri, "json", "{\n  \"name\": 1\n}\n");
    const diagnostics = try client.pullDiagnostics(scratch, uri);
    try std.testing.expect(diagnostics.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics[0].message, "string") != null);
}

test "JSON document symbol parser handles hierarchical and flat shapes" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, scratch,
        \\[
        \\  {
        \\    "name": "root",
        \\    "detail": "",
        \\    "kind": 19,
        \\    "range": {"start":{"line":0,"character":0},"end":{"line":2,"character":1}},
        \\    "selectionRange": {"start":{"line":0,"character":1},"end":{"line":0,"character":5}},
        \\    "children": [
        \\      {
        \\        "name": "a",
        \\        "kind": 7,
        \\        "range": {"start":{"line":1,"character":2},"end":{"line":1,"character":7}},
        \\        "selectionRange": {"start":{"line":1,"character":2},"end":{"line":1,"character":5}}
        \\      }
        \\    ]
        \\  },
        \\  {
        \\    "name": "flat",
        \\    "kind": 12,
        \\    "location": {
        \\      "uri": "file:///tmp/test.json",
        \\      "range": {"start":{"line":3,"character":0},"end":{"line":3,"character":4}}
        \\    }
        \\  }
        \\]
    , .{});
    const symbols = try parseDocumentSymbols(scratch, value);
    try std.testing.expectEqual(@as(usize, 2), symbols.len);
    try std.testing.expectEqualStrings("root", symbols[0].name);
    try std.testing.expectEqual(@as(usize, 1), symbols[0].children.len);
    try std.testing.expectEqualStrings("a", symbols[0].children[0].name);
    try std.testing.expectEqual(@as(u32, 1), symbols[0].children[0].range.start_line);
    try std.testing.expectEqualStrings("flat", symbols[1].name);
    try std.testing.expectEqual(@as(u32, 3), symbols[1].selection_range.start_line);
}

test "JSON language client returns document symbols" {
    std.Io.Dir.cwd().access(time_compat.io, "host/dist/jsonServer.mjs", .{}) catch return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const client = try Client.start(allocator, "node", "host/dist/jsonServer.mjs");
    defer client.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const uri = "file:///tmp/document-symbols.json";
    try client.didOpen(scratch, uri, "json", "{\n  \"a\": 1\n}\n");
    const symbols = try client.documentSymbols(scratch, uri);
    try std.testing.expect(symbols.len > 0);
}
