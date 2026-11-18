// Port of `src/vs/workbench/services/configuration/test/common/experimentalSettings.test.ts`.
//
// Terminal adaptation: the upstream test awaits `timeout(0)`/a microtask for
// the scheduler to fire; the terminal service exposes `poll(now_ms)` and the
// ports call it instead.
const std = @import("std");
const testing = std.testing;
const ExperimentalSettingsService = @import("../../common/experimentalSettings.zig").ExperimentalSettingsService;

const AssignmentSink = struct {
    batches: usize = 0,
    last: [128]u8 = undefined,
    last_len: usize = 0,

    fn callback(keys: []const []const u8, self: *AssignmentSink) anyerror!void {
        self.batches += 1;
        self.last_len = 0;
        for (keys, 0..) |key, index| {
            if (index > 0 and self.last_len < self.last.len) {
                self.last[self.last_len] = ',';
                self.last_len += 1;
            }
            const count = @min(key.len, self.last.len - self.last_len);
            @memcpy(self.last[self.last_len .. self.last_len + count], key[0..count]);
            self.last_len += count;
        }
    }
};

test "experimental settings: batches changed settings while updating membership synchronously" {
    const allocator = testing.allocator;
    var service: ExperimentalSettingsService = undefined;
    service.init(allocator);
    defer service.deinit();

    var sink = AssignmentSink{};
    _ = try service.listenAssignments(&sink, AssignmentSink.callback);

    try service.setAssignment("test.first", false);
    try service.setAssignment("test.first", true);
    try service.setAssignment("test.first", true);
    try testing.expect(service.hasAssignment("test.first"));
    try testing.expectEqual(@as(usize, 0), sink.batches);

    try service.setAssignment("test.second", true);
    try service.setAssignment("test.first", false);
    try testing.expect(service.hasAssignment("test.second"));
    try testing.expectEqual(@as(usize, 0), sink.batches);

    _ = service.poll(1);
    try testing.expectEqual(@as(usize, 1), sink.batches);
    try testing.expectEqualStrings("test.first,test.second", sink.last[0..sink.last_len]);
    try testing.expect(!service.hasAssignment("test.first"));
    try testing.expect(service.hasAssignment("test.second"));
    try testing.expect(!service.hasAssignment("test.missing"));
}

test "experimental settings: does not notify for unchanged membership or after disposal" {
    const allocator = testing.allocator;
    var service: ExperimentalSettingsService = undefined;
    service.init(allocator);
    var sink = AssignmentSink{};
    _ = try service.listenAssignments(&sink, AssignmentSink.callback);

    try service.setAssignment("test.setting", false);
    try service.setAssignment("test.setting", true);
    service.deinit();

    try testing.expectEqual(@as(usize, 0), sink.batches);
}

test "experimental settings: requests keyed experiment keys once" {
    const allocator = testing.allocator;
    var service: ExperimentalSettingsService = undefined;
    service.init(allocator);
    defer service.deinit();

    const KeySink = struct {
        count: usize = 0,
        fn callback(_: []const u8, self: *@This()) anyerror!void {
            self.count += 1;
        }
    };
    var sink = KeySink{};
    _ = try service.listenRequestKeys(&sink, KeySink.callback);

    const first = [_][]const u8{ "a", "b" };
    try service.requestKeys("test.keyed", &first);
    try testing.expectEqual(@as(usize, 1), sink.count);
    try testing.expectEqual(@as(usize, 2), service.getRequestedKeys("test.keyed").len);

    const second = [_][]const u8{"a"};
    try service.requestKeys("test.keyed", &second);
    try testing.expectEqual(@as(usize, 1), sink.count);
}
