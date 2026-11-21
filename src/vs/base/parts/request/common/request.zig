// Port of `src/vs/base/parts/request/common/request.ts`.
//
// Terminal adaptation: response bodies are fully buffered into a `VSBuffer`
// (upstream exposes a `VSBufferReadableStream`), headers are an owned ordered
// list instead of a string-keyed object, and the Node/Electron transport is
// replaced by `std.http` in `platform/request/node/requestService.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const buffer_mod = @import("../../../common/buffer.zig");
const VSBuffer = buffer_mod.VSBuffer;

const offline_name = "Offline";

/// Checks if the given error is an offline error.
pub fn isOfflineError(err: anyerror) bool {
    return err == error.Offline;
}

/// Upstream `OfflineError`; the terminal backend reports it when the platform
/// says there is no network connection.
pub const OfflineError = error{Offline};

/// One header value. Duplicate header names are preserved in order.
pub const Header = struct {
    name: []u8,
    value: []u8,
};

pub const Headers = struct {
    allocator: Allocator,
    items: std.array_list.Managed(Header),

    pub fn init(allocator: Allocator) Headers {
        return .{ .allocator = allocator, .items = std.array_list.Managed(Header).init(allocator) };
    }

    pub fn deinit(self: *Headers) void {
        for (self.items.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.items.deinit();
    }

    pub fn append(self: *Headers, name: []const u8, value: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.items.append(.{ .name = name_copy, .value = value_copy });
    }

    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        for (self.items.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
        }
        return null;
    }
};

pub const IHeaders = Headers;

pub const IRequestTimings = struct {
    /// Client wait until response headers arrive, including connection setup
    /// and redirects.
    response_headers_ms: f64,
    /// Time spent consuming the response after receiving headers.
    response_body_ms: f64,
    /// Decoded response size.
    decoded_body_bytes: usize,
};

pub const IRequestOptions = struct {
    /// HTTP method. Defaults to GET, or POST when `data` is set.
    type: ?[]const u8 = null,
    url: []const u8,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    headers: ?*const IHeaders = null,
    /// Disables caching where the transport supports it.
    timeout: ?u32 = null,
    data: ?[]const u8 = null,
    /// Number of redirects to follow. `.none` keeps `Client`/upstream defaults.
    follow_redirects: ?u16 = null,
    proxy_authorization: ?[]const u8 = null,
    disable_cache: bool = false,
    /// `false` logs only this request's host, status and error name or code,
    /// never the URL, headers or error message.
    log_url: bool = true,
    /// Identifies the call site making this request.
    call_site: []const u8 = "",
    diagnostic_id: ?[]const u8 = null,
};

pub const IRequestContext = struct {
    allocator: Allocator,
    headers: IHeaders,
    status_code: ?u16,
    /// Fully buffered response body. Empty on transport errors.
    body: VSBuffer,
    timings: ?IRequestTimings = null,

    pub fn init(allocator: Allocator, headers: IHeaders, status_code: ?u16, body: VSBuffer) IRequestContext {
        return .{ .allocator = allocator, .headers = headers, .status_code = status_code, .body = body };
    }

    pub fn deinit(self: *IRequestContext) void {
        self.headers.deinit();
        self.body.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn header(self: *const IRequestContext, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }
};

test "request: headers preserve duplicates and lookup case-insensitively" {
    const allocator = std.testing.allocator;
    var headers = IHeaders.init(allocator);
    defer headers.deinit();
    try headers.append("Content-Type", "text/plain");
    try headers.append("Set-Cookie", "a=1");
    try headers.append("Set-Cookie", "b=2");

    try std.testing.expectEqualStrings("text/plain", headers.get("content-type").?);
    try std.testing.expectEqual(@as(usize, 3), headers.items.items.len);
}
