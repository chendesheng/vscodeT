// Port of `src/vs/editor/common/services/completionsEnablement.ts`.
//
// Upstream has three entry points: one reads an `IConfigurationService`, one an
// `ITextResourceConfigurationService`, and both funnel into
// `isCompletionsEnabledFromObject`. Without the configuration services there is
// only the pure object lookup, and the setting name has to be supplied by the
// caller instead of being read from `product.defaultChatAgent`.
const std = @import("std");

/// Checks if completions (e.g. Copilot) are enabled for a given language ID using
/// a pre-fetched completions enablement object.
///
/// `mode_id` defaults to `"*"` which checks the global setting.
pub fn isCompletionsEnabledFromObject(
    completions_enablement_object: ?*const std.StringHashMap(bool),
    mode_id: []const u8,
) bool {
    const object = completions_enablement_object orelse return false; // default to disabled if setting is not available
    if (object.get(mode_id)) |value| {
        return value; // go with setting if explicitly defined
    }
    // fallback to global setting otherwise
    return object.get("*") orelse false;
}

test "isCompletionsEnabledFromObject" {
    var object = std.StringHashMap(bool).init(std.testing.allocator);
    defer object.deinit();
    try object.put("typescript", true);
    try object.put("python", false);
    try object.put("*", false);

    // An explicit per-language setting wins.
    try std.testing.expect(isCompletionsEnabledFromObject(&object, "typescript"));
    try std.testing.expect(!isCompletionsEnabledFromObject(&object, "python"));
    // Unknown languages fall back to the global setting.
    try std.testing.expect(!isCompletionsEnabledFromObject(&object, "zig"));
    // `"*"` itself reads the global setting.
    try std.testing.expect(!isCompletionsEnabledFromObject(&object, "*"));

    // Without a setting the feature is disabled.
    try std.testing.expect(!isCompletionsEnabledFromObject(null, "*"));
}

test "isCompletionsEnabledFromObject: global setting on" {
    var object = std.StringHashMap(bool).init(std.testing.allocator);
    defer object.deinit();
    try object.put("*", true);

    try std.testing.expect(isCompletionsEnabledFromObject(&object, "zig"));
    try std.testing.expect(isCompletionsEnabledFromObject(&object, "*"));

    // A `false` entry still overrides the global setting.
    try object.put("markdown", false);
    try std.testing.expect(!isCompletionsEnabledFromObject(&object, "markdown"));
    try std.testing.expect(isCompletionsEnabledFromObject(&object, "zig"));
}
