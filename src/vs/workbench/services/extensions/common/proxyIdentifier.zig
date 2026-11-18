// Port of `src/vs/workbench/services/extensions/common/proxyIdentifier.ts`.
//
// The static identifier table is generated from the pinned host's
// `extHost.protocol.ts` (see host/generateProtocol.js); this module owns the
// runtime-facing wrapper and the lookup helpers.
const std = @import("std");
const protocol = @import("../../../api/common/extHost.protocol.zig");

pub const ProxyIdentifier = struct {
    nid: u8,
    sid: []const u8,
};

pub const SerializableObjectWithBuffers = struct {
    value: std.json.Value,
};

/// The upstream evaluation-order counter is replaced by the generated table.
/// `nid` is one-based and 0 is never a valid identifier.
pub fn createProxyIdentifier(nid: u8) ?ProxyIdentifier {
    const entry = protocol.identifier(nid) orelse return null;
    return .{ .nid = entry.nid, .sid = entry.sid };
}

pub fn identifierFromEnum(nid: anytype) ProxyIdentifier {
    const value: u8 = @intFromEnum(nid);
    return .{ .nid = value, .sid = protocol.identifier(value).?.sid };
}

pub fn getStringIdentifierForProxy(nid: u8) []const u8 {
    return if (protocol.identifier(nid)) |entry| entry.sid else "unknown";
}

test "generated identifier table is complete and unique" {
    try std.testing.expectEqual(@as(u8, 171), protocol.max_nid);
    try std.testing.expectEqual(@as(usize, 89), protocol.main_context_count);
    try std.testing.expectEqual(@as(usize, 82), protocol.ext_host_context_count);
    try std.testing.expect(protocol.identifier(0) == null);
    try std.testing.expect(protocol.identifier(1) != null);
    try std.testing.expect(protocol.identifier(171) != null);
    try std.testing.expect(protocol.identifier(172) == null);

    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    var nid: u16 = 1;
    while (nid <= protocol.max_nid) : (nid += 1) {
        const entry = protocol.identifier(@intCast(nid)).?;
        try std.testing.expect(entry.sid.len > 0);
        try std.testing.expect(!seen.contains(entry.sid));
        try seen.put(entry.sid, {});
    }

    // Spot-check the identifiers whose key and sid differ upstream.
    try std.testing.expectEqualStrings("MainThreadChatSkills", protocol.identifier(7).?.sid);
    try std.testing.expectEqualStrings("MainThreadDiaglogs", protocol.identifier(17).?.sid);
    try std.testing.expectEqualStrings("MainThreadSpeechProvider", protocol.identifier(39).?.sid);
    try std.testing.expectEqualStrings("MainThreadNotebookDocumentsShape", protocol.identifier(64).?.sid);
    try std.testing.expectEqualStrings("ExtHostChatAgents", protocol.identifier(145).?.sid);
}
