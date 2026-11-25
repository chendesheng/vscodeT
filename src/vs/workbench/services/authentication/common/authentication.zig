// Port of the account and provider contracts used by account management in
// `src/vs/workbench/services/authentication/common/authentication.ts`.
const std = @import("std");

pub const AuthenticationSessionAccount = struct { id: []const u8, label: []const u8 };

pub const IAuthenticationService = struct {
    context: *anyopaque,
    // Results and their strings belong to the caller's arena.
    get_accounts: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]const AuthenticationSessionAccount,
    create_session: *const fn (*anyopaque, []const u8, []const []const u8) anyerror!void,
    sign_out: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
};
