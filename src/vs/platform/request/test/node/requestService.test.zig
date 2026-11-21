// Port of the configuration-facing subset of
// `src/vs/platform/request/test/node/requestService.test.ts`.
//
// The Node suite mocks the `http`/`https` layer. The terminal service exposes
// no injectable transport, so this file covers the portable configuration
// surface (proxy parsing/clearing and lifecycle); the transport is exercised by
// the live editor smoke test rather than a loopback server owned by the test
// runner.

const std = @import("std");
const RequestService = @import("../../node/requestService.zig").RequestService;

test "request service: configures and clears an http proxy" {
    const allocator = std.testing.allocator;
    var service = RequestService.init(allocator, std.testing.io);
    defer service.deinit();

    try service.configure("http://127.0.0.1:8080", "Basic abc");
    try std.testing.expect(service.client.http_proxy != null);
    try std.testing.expect(service.client.https_proxy != null);
    try std.testing.expectEqual(@as(u16, 8080), service.client.http_proxy.?.port);
    try std.testing.expectEqualStrings("Basic abc", service.client.http_proxy.?.authorization.?);

    try service.configure(null, null);
    try std.testing.expect(service.client.http_proxy == null);
    try std.testing.expect(service.client.https_proxy == null);
}

test "request service: rejects malformed and non-http URLs" {
    const allocator = std.testing.allocator;
    var service = RequestService.init(allocator, std.testing.io);
    defer service.deinit();

    try std.testing.expectError(error.InvalidUrl, service.request(.{ .url = "" }));
    try std.testing.expectError(error.InvalidUrl, service.request(.{ .url = "not a url" }));
    try std.testing.expectError(error.UnsupportedScheme, service.request(.{ .url = "file:///tmp/hello" }));
}
