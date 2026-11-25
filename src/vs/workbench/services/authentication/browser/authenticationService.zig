// Port of AuthenticationService.getAccounts in
// `src/vs/workbench/services/authentication/browser/authenticationService.ts`.
// RPC customers decode sessions into the portable account shape at their boundary.
const std = @import("std");
const Account = @import("../common/authentication.zig").AuthenticationSessionAccount;

pub fn getAccounts(arena: std.mem.Allocator, sessions: []const Account) ![]const Account {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);
    var accounts: std.ArrayList(Account) = .empty;
    errdefer accounts.deinit(arena);
    for (sessions) |account| {
        if ((try seen.getOrPut(arena, account.label)).found_existing) continue;
        try accounts.append(arena, account);
    }
    return accounts.toOwnedSlice(arena);
}
