// Terminal port of the network request service.
//
// Upstream `src/vs/platform/request/node/requestService.ts` wraps Node's
// `http`/`https` modules and returns a `Promise<IRequestContext>`. The terminal
// implementation uses `std.http.Client` with the `Io` it is given; callers that
// need the request off the TUI thread wrap `request` in `Io.async` (see
// `tui/markdownPreview.zig`). Response bodies are buffered because the port has
// no stream/back-pressure abstraction yet.
//
// Deliberate omissions (documented in README): the Node proxy agent, shell-env
// proxy discovery, Kerberos, certificate lookup and streaming bodies. TLS uses
// Zig's system CA bundle via `std.http`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;
const request_types = @import("../../../base/parts/request/common/request.zig");
const IHeaders = request_types.IHeaders;
const IRequestContext = request_types.IRequestContext;
const IRequestOptions = request_types.IRequestOptions;
const VSBuffer = @import("../../../base/common/buffer.zig").VSBuffer;

/// Hard cap for a buffered response body. Remote Markdown images are additionally
/// capped by the media-preview decoder.
pub const max_body_bytes: usize = 64 * 1024 * 1024;

pub const RequestError = error{
    InvalidUrl,
    UnsupportedScheme,
    UnsupportedMethod,
    BodyTooLarge,
    InvalidHeader,
    Timeout,
    Offline,
};

pub const RequestService = struct {
    allocator: Allocator,
    io: Io,
    /// Shared across worker threads; `std.http.Client` opens connections
    /// thread-safely and each request owns its own `Request`.
    client: http.Client,
    /// `http.proxy` configuration value; parsed into the client's proxy fields
    /// when non-null.
    proxy_url: ?[]u8 = null,
    proxy_authorization: ?[]u8 = null,
    /// `std.http.Client` stores externally-owned proxy pointers.
    proxy_storage: ?*http.Client.Proxy = null,
    proxy_host: ?[]u8 = null,

    pub fn init(allocator: Allocator, io: Io) RequestService {
        return .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *RequestService) void {
        self.client.deinit();
        if (self.proxy_storage) |value| self.allocator.destroy(value);
        if (self.proxy_host) |value| self.allocator.free(value);
        if (self.proxy_url) |value| self.allocator.free(value);
        if (self.proxy_authorization) |value| self.allocator.free(value);
        self.* = undefined;
    }

    /// Applies the `http.*` settings used by upstream's `configure()`.
    pub fn configure(self: *RequestService, proxy_url: ?[]const u8, proxy_authorization: ?[]const u8) !void {
        if (self.proxy_url) |value| {
            self.allocator.free(value);
            self.proxy_url = null;
        }
        if (self.proxy_authorization) |value| {
            self.allocator.free(value);
            self.proxy_authorization = null;
        }
        if (proxy_url) |value| self.proxy_url = try self.allocator.dupe(u8, value);
        if (proxy_authorization) |value| self.proxy_authorization = try self.allocator.dupe(u8, value);
        self.applyProxy();
    }

    fn applyProxy(self: *RequestService) void {
        // `std.http.Client` takes externally-owned proxy memory. The service
        // keeps the URL/host/authorization alive until deinit.
        self.client.http_proxy = null;
        self.client.https_proxy = null;
        if (self.proxy_storage) |value| {
            self.allocator.destroy(value);
            self.proxy_storage = null;
        }
        if (self.proxy_host) |value| {
            self.allocator.free(value);
            self.proxy_host = null;
        }
        const url = self.proxy_url orelse return;
        const parsed = std.Uri.parse(url) catch return;
        const protocol: http.Client.Protocol = if (parsed.scheme.len > 0 and std.ascii.eqlIgnoreCase(parsed.scheme, "https"))
            .tls
        else
            .plain;
        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = std.Io.net.HostName.fromUri(parsed, &host_buffer) catch return;
        const host_copy = self.allocator.dupe(u8, host.bytes) catch return;
        const proxy = self.allocator.create(http.Client.Proxy) catch {
            self.allocator.free(host_copy);
            return;
        };
        proxy.* = .{
            .protocol = protocol,
            .host = .{ .bytes = host_copy },
            .authorization = self.proxy_authorization,
            .port = parsed.port orelse if (protocol == .tls) 443 else 80,
            .supports_connect = true,
        };
        self.proxy_storage = proxy;
        self.proxy_host = host_copy;
        self.client.http_proxy = proxy;
        self.client.https_proxy = proxy;
    }

    /// Performs the request synchronously on the calling thread. The caller is
    /// responsible for scheduling this on `Io.async` when the TUI must remain
    /// responsive, and for enforcing `options.timeout` (the async job deadline
    /// cancels the future; `std.http` has no timeout knob).
    pub fn request(self: *RequestService, options: IRequestOptions) !IRequestContext {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const url = std.mem.trim(u8, options.url, " \t\r\n");
        if (url.len == 0) return error.InvalidUrl;
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        if (!(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https"))) {
            return error.UnsupportedScheme;
        }

        const method = try parseMethod(options);
        const redirect_behavior: http.Client.Request.RedirectBehavior = if (options.follow_redirects) |count|
            if (count == 0) .unhandled else .init(count)
        else if (options.data == null) .init(3) else .unhandled;

        var extra = std.array_list.Managed(http.Header).init(arena_alloc);
        var privileged = std.array_list.Managed(http.Header).init(arena_alloc);
        if (options.headers) |headers| {
            for (headers.items.items) |header| {
                if (isUnsafeHeader(header.name)) continue;
                const entry = http.Header{ .name = header.name, .value = header.value };
                if (isSensitiveHeader(header.name)) {
                    try privileged.append(entry);
                } else {
                    try extra.append(entry);
                }
            }
        }
        if (options.user != null or options.password != null) {
            const user = options.user orelse "";
            const password = options.password orelse "";
            const raw = try std.fmt.allocPrint(arena_alloc, "{s}:{s}", .{ user, password });
            const encoded = try arena_alloc.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
            _ = std.base64.standard.Encoder.encode(encoded, raw);
            try privileged.append(.{ .name = "authorization", .value = try std.fmt.allocPrint(arena_alloc, "Basic {s}", .{encoded}) });
        }
        if (options.proxy_authorization orelse self.proxy_authorization) |value| {
            try privileged.append(.{ .name = "proxy-authorization", .value = value });
        }
        if (options.disable_cache) {
            try extra.append(.{ .name = "cache-control", .value = "no-cache" });
        }

        var req = self.client.request(method, uri, .{
            .redirect_behavior = redirect_behavior,
            .extra_headers = extra.items,
            .privileged_headers = privileged.items,
            .headers = .{ .accept_encoding = .omit },
        }) catch |err| return err;
        defer req.deinit();

        if (options.data) |data| {
            req.transfer_encoding = .{ .content_length = data.len };
            var body = try req.sendBodyUnflushed(&.{});
            body.writer.writeAll(data) catch |err| return err;
            body.end() catch |err| return err;
            if (req.connection) |connection| connection.flush() catch |err| return err;
        } else {
            try req.sendBodiless();
        }

        var redirect_buffer: [16 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        var headers = IHeaders.init(self.allocator);
        errdefer headers.deinit();
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| {
            headers.append(header.name, header.value) catch |err| return err;
        }

        const body_bytes = if (response.request.method.responseHasBody()) blk: {
            const reader = response.reader(&.{});
            const bytes = reader.allocRemaining(self.allocator, .limited(max_body_bytes)) catch |err| switch (err) {
                error.StreamTooLong => return error.BodyTooLarge,
                error.OutOfMemory => return error.OutOfMemory,
                error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            };
            break :blk bytes;
        } else try self.allocator.alloc(u8, 0);

        return IRequestContext.init(
            self.allocator,
            headers,
            @intCast(@backingInt(response.head.status)),
            VSBuffer{ .bytes = body_bytes },
        );
    }
};

fn parseMethod(options: IRequestOptions) !http.Method {
    if (options.type) |raw| {
        var buffer: [16]u8 = undefined;
        if (raw.len > buffer.len) return error.UnsupportedMethod;
        const upper = std.ascii.upperString(buffer[0..raw.len], raw);
        return std.meta.stringToEnum(http.Method, upper) orelse error.UnsupportedMethod;
    }
    return if (options.data != null) .POST else .GET;
}

fn isUnsafeHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "user-agent") or
        std.ascii.eqlIgnoreCase(name, "accept-encoding") or
        std.ascii.eqlIgnoreCase(name, "content-length");
}

fn isSensitiveHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "cookie") or
        std.ascii.eqlIgnoreCase(name, "cookie2") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization");
}

test "request service parses methods and filters unsafe headers" {
    try std.testing.expectEqual(http.Method.GET, try parseMethod(.{ .url = "http://example.com" }));
    try std.testing.expectEqual(http.Method.POST, try parseMethod(.{ .url = "http://example.com", .data = "x" }));
    try std.testing.expectEqual(http.Method.PUT, try parseMethod(.{ .url = "http://example.com", .type = "put" }));
    try std.testing.expectError(error.UnsupportedMethod, parseMethod(.{ .url = "http://example.com", .type = "BREW" }));
    try std.testing.expect(isUnsafeHeader("User-Agent"));
    try std.testing.expect(!isUnsafeHeader("content-type"));
    try std.testing.expect(isSensitiveHeader("Authorization"));
}
