// TUI adaptation of the JSON client/server contract from
// `vscode/extensions/json-language-features/client/src/jsonClient.ts`.
//
// Minimal synchronous LSP client for the bundled VS Code JSON language
// server. It is deliberately not a general language-client implementation:
// the TUI owns one local Node process and drives it from the main thread.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const time_compat = @import("../../../../base/common/timeCompat.zig");

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

pub const Client = struct {
    allocator: Allocator,
    io_state: std.Io.Threaded,
    io: Io,
    child: std.process.Child,
    next_id: u32 = 1,
    buffer: std.array_list.Managed(u8),
    root_uri: []u8,
    initialized: bool = false,

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
        self.io_state = std.Io.Threaded.init(std.heap.page_allocator, .{});
        self.io = self.io_state.io();

        self.child = std.process.spawn(self.io, .{
            .argv = &.{ node_path, server_script, "--stdio" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return Error.ServerUnavailable;
        if (self.child.stdin == null or self.child.stdout == null) return Error.ServerUnavailable;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var params: std.json.ObjectMap = .empty;
        try params.put(arena.allocator(), "processId", .{ .integer = @intCast(std.os.linux.getpid()) });
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
        const result = try self.request(arena.allocator(), "initialize", .{ .object = params });
        if (result != .object or result.object.get("capabilities") == null) return Error.InvalidMessage;
        self.notify(arena.allocator(), "initialized", .{ .object = .empty }) catch {};

        try self.configure(arena.allocator(), null);
        self.initialized = true;
        return self;
    }

    /// Sends the settings the JSON server consumes. `schemas` is the raw
    /// `json.schemas` setting value, borrowed only for this call.
    pub fn configure(self: *Client, arena: Allocator, schemas: ?std.json.Value) !void {
        var json_settings: std.json.ObjectMap = .empty;
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
            self.child.kill(self.io);
        }
        self.buffer.deinit();
        self.allocator.free(self.root_uri);
        self.allocator.destroy(self);
    }

    pub fn didOpen(self: *Client, arena: Allocator, uri: []const u8, language_id: []const u8, text: []const u8) !void {
        var doc: std.json.ObjectMap = .empty;
        try doc.put(arena, "uri", .{ .string = try arena.dupe(u8, uri) });
        try doc.put(arena, "languageId", .{ .string = try arena.dupe(u8, language_id) });
        try doc.put(arena, "version", .{ .integer = 1 });
        try doc.put(arena, "text", .{ .string = try arena.dupe(u8, text) });
        var params: std.json.ObjectMap = .empty;
        try params.put(arena, "textDocument", .{ .object = doc });
        try self.notify(arena, "textDocument/didOpen", .{ .object = params });
    }

    pub fn didChange(self: *Client, arena: Allocator, uri: []const u8, version: u32, text: []const u8) !void {
        var doc: std.json.ObjectMap = .empty;
        try doc.put(arena, "uri", .{ .string = try arena.dupe(u8, uri) });
        try doc.put(arena, "version", .{ .integer = @intCast(version) });
        var change: std.json.ObjectMap = .empty;
        try change.put(arena, "text", .{ .string = try arena.dupe(u8, text) });
        var changes = std.json.Array.init(arena);
        try changes.append(.{ .object = change });
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
        const result = try self.request(arena, "textDocument/diagnostic", .{ .object = params });
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
        const result = try self.request(arena, "textDocument/completion", .{ .object = params });
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
        const result = try self.request(arena, "textDocument/hover", .{ .object = params });
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
        const result = try self.request(arena, "textDocument/documentSymbol", .{ .object = params });
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
        const result = try self.request(arena, "textDocument/formatting", .{ .object = params });
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

    fn request(self: *Client, arena: Allocator, method: []const u8, params: std.json.Value) !std.json.Value {
        const id = self.next_id;
        self.next_id +%= 1;
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "jsonrpc", .{ .string = "2.0" });
        try object.put(arena, "id", .{ .integer = @intCast(id) });
        try object.put(arena, "method", .{ .string = try arena.dupe(u8, method) });
        try object.put(arena, "params", params);
        try self.writeMessage(arena, .{ .object = object });

        while (true) {
            const message = self.readMessage(arena) catch return Error.ServerUnavailable;
            if (message != .object) continue;
            if (message.object.get("id")) |response_id| {
                if (response_id == .integer and response_id.integer == id) {
                    if (message.object.get("error") != null) return Error.RequestFailed;
                    return message.object.get("result") orelse .null;
                }
                if (message.object.get("method")) |server_method| {
                    try self.answerServerRequest(arena, message.object, response_id, server_method);
                }
            }
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

    fn readMessage(self: *Client, arena: Allocator) !std.json.Value {
        while (true) {
            if (std.mem.indexOf(u8, self.buffer.items, "\r\n\r\n")) |header_end| {
                const header = self.buffer.items[0..header_end];
                const length = contentLength(header) orelse return Error.InvalidMessage;
                const total = header_end + 4 + length;
                if (self.buffer.items.len >= total) {
                    const body = self.buffer.items[header_end + 4 .. total];
                    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
                    const consumed = total;
                    std.mem.copyForwards(u8, self.buffer.items[0 .. self.buffer.items.len - consumed], self.buffer.items[consumed..]);
                    self.buffer.shrinkRetainingCapacity(self.buffer.items.len - consumed);
                    return value;
                }
            }
            var chunk: [4096]u8 = undefined;
            const file = self.child.stdout orelse return Error.ServerUnavailable;
            const count = file.readStreaming(self.io, &.{&chunk}) catch return Error.ServerUnavailable;
            if (count == 0) return Error.ServerUnavailable;
            try self.buffer.appendSlice(chunk[0..count]);
        }
    }
};

fn parseDocumentSymbols(arena: Allocator, result: std.json.Value) ![]JsonDocumentSymbol {
    if (result != .array) return &.{};
    var symbols = std.array_list.Managed(JsonDocumentSymbol).init(arena);
    for (result.array.items) |item| {
        if (item != .object) continue;
        const symbol = try parseDocumentSymbol(arena, item.object);
        if (symbol) |value| try symbols.append(value);
    }
    return symbols.toOwnedSlice();
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
