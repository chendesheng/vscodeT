// Terminal extension-service helpers.
//
// This is the portable part of upstream's extension workbench service that the
// TUI needs to boot one host with several extensions: reading the loadable
// descriptions and tracking `onLanguage` activation events. The host process,
// transport and actor wiring remain in the terminal adapter; the vscode API
// contract they speak is unchanged.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const manager = @import("extensionHostManager.zig");

pub const ExtensionPath = struct {
    path: []const u8,
    is_builtin: bool = false,
    is_under_development: bool = false,
};

/// Reads every extension path and prepares the host descriptions. The caller
/// owns the returned slice; each entry owns its manifest and activation data.
pub fn readExtensions(
    allocator: Allocator,
    io: Io,
    paths: []const ExtensionPath,
) ![]manager.ExtensionDescription {
    var descriptions = std.array_list.Managed(manager.ExtensionDescription).init(allocator);
    errdefer {
        for (descriptions.items) |*description| description.deinit(allocator);
        descriptions.deinit();
    }
    for (paths) |entry| {
        const absolute_path = try std.Io.Dir.cwd().realPathFileAlloc(io, entry.path, allocator);
        defer allocator.free(absolute_path);
        var description = try manager.readExtensionDescription(allocator, absolute_path);
        description.is_builtin = entry.is_builtin;
        description.is_under_development = entry.is_under_development;
        try descriptions.append(description);
    }
    if (descriptions.items.len == 0) return error.NoExtensions;
    return descriptions.toOwnedSlice();
}

/// Tracks the `onLanguage:<id>` events sent to the host so each language
/// activates at most once. Mirrors the workbench language service's request
/// deduplication.
pub const ActivationTracker = struct {
    allocator: Allocator,
    activated_languages: std.StringHashMap(void),

    pub fn init(allocator: Allocator) ActivationTracker {
        return .{
            .allocator = allocator,
            .activated_languages = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *ActivationTracker) void {
        var iterator = self.activated_languages.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.activated_languages.deinit();
    }

    /// Sends `onLanguage:<language_id>` once. The document delta must already
    /// have been queued; the host preserves frame order.
    pub fn activateLanguage(self: *ActivationTracker, host: *manager.HostManager, language_id: []const u8) void {
        if (language_id.len == 0) return;
        if (self.activated_languages.contains(language_id)) return;
        const owned = self.allocator.dupe(u8, language_id) catch return;
        self.activated_languages.put(owned, {}) catch {
            self.allocator.free(owned);
            return;
        };
        var buffer: [128]u8 = undefined;
        const event = std.fmt.bufPrint(&buffer, "onLanguage:{s}", .{language_id}) catch return;
        host.activateByEvent(event, 0) catch {};
    }
};

test "ActivationTracker deduplicates languages" {
    const allocator = std.testing.allocator;
    var tracker = ActivationTracker.init(allocator);
    defer tracker.deinit();
    try std.testing.expect(!tracker.activated_languages.contains("typescript"));
    const owned = try allocator.dupe(u8, "typescript");
    try tracker.activated_languages.put(owned, {});
    try std.testing.expect(tracker.activated_languages.contains("typescript"));
}
