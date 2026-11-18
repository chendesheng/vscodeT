// Port of the backup/replace/discard/delete subset of
// `src/vs/workbench/services/workingCopy/test/node/workingCopyBackupService.test.ts`.
const std = @import("std");
const testing = std.testing;
const service_mod = @import("../../common/workingCopyBackupService.zig");
const backup = @import("../../common/workingCopyBackup.zig");

test "working copy backup service: backup, replace, discard and delete" {
    const allocator = testing.allocator;
    var service = service_mod.WorkingCopyBackupService.init(allocator);
    defer service.deinit();

    var events: usize = 0;
    _ = try service.on_did_change_backup.listen(&events, struct {
        fn onChange(_: []const u8, count: *usize) anyerror!void {
            count.* += 1;
        }
    }.onChange);

    const identifier = backup.WorkingCopyBackupIdentifier{ .resource = "/file.txt", .type_id = "text" };
    try testing.expect(!service.hasBackup(identifier));
    try service.backup(identifier, "one", "meta");
    try testing.expect(service.hasBackup(identifier));
    try testing.expectEqual(@as(usize, 1), service.backupCount());
    try testing.expectEqualStrings("one", service.getBackup(identifier).?.content);
    try testing.expectEqualStrings("meta", service.getBackup(identifier).?.meta.?);
    try testing.expectEqual(@as(usize, 1), events);

    try service.backup(identifier, "two", null);
    try testing.expectEqualStrings("two", service.getBackup(identifier).?.content);
    try testing.expect(service.getBackup(identifier).?.meta == null);
    try testing.expectEqual(@as(usize, 2), events);

    service.discardBackup(identifier);
    try testing.expect(!service.hasBackup(identifier));
    try testing.expectEqual(@as(usize, 0), service.backupCount());
    try testing.expectEqual(@as(usize, 3), events);

    try service.backup(identifier, "a", null);
    try service.backup(.{ .resource = "/file.txt", .type_id = "other" }, "b", null);
    try testing.expectEqual(@as(usize, 2), service.backupCount());
    service.deleteBackups("/file.txt");
    try testing.expectEqual(@as(usize, 0), service.backupCount());
    try testing.expect(events >= 5);
}
