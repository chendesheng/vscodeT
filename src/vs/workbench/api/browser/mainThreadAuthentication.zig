// Bridge for the upstream Accounts menu and vscode.authentication.getAccounts.
const std = @import("std");
const Allocator = std.mem.Allocator;
const CommandRegistry = @import("../../browser/commands.zig").CommandRegistry;
const QuickInputService = @import("../../../platform/quickinput/browser/quickInputService.zig").QuickInputService;
const ManageAccountsAction = @import("../../contrib/authentication/browser/actions/manageAccountsAction.zig").ManageAccountsAction;
const auth = @import("../../services/authentication/common/authentication.zig");
const service = @import("../../services/authentication/browser/authenticationService.zig");
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const proxy = @import("../../services/extensions/common/proxyIdentifier.zig").identifierFromEnum;
const actor = proxy(protocol.ExtHostContext.ExtHostAuthentication);
const command = "workbench.action.accounts.manage";

const Grant = struct {
    key: []const u8,
    provider: []const u8,
    session: []const u8,

    fn free(self: Grant, a: Allocator) void {
        a.free(self.key);
        a.free(self.provider);
        a.free(self.session);
    }
};

pub const Accounts = struct {
    allocator: Allocator,
    commands: *CommandRegistry,
    quick_input: *QuickInputService,
    status: Status,
    action: ManageAccountsAction,
    host: *manager.HostManager,
    extensions: []const manager.ExtensionDescription,
    pending: ?*@import("authenticationRequest.zig").Request = null,
    changed: bool = false,
    signing_in: ?u32 = null,
    grants: std.ArrayList(Grant) = .empty,
    registered: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub const Status = struct { context: *anyopaque, show: *const fn (*anyopaque, []const u8) void };

    pub fn init(self: *Accounts, allocator: Allocator, commands: *CommandRegistry, quick_input: *QuickInputService, status: Status, host: *manager.HostManager, extensions: []const manager.ExtensionDescription) !void {
        self.* = .{ .allocator = allocator, .commands = commands, .quick_input = quick_input, .status = status, .host = host, .extensions = extensions, .action = .{
            .authentication = self.interface(),
            .quick_input = quick_input,
            .extensions = extensions,
            .choices = .init(allocator),
        } };
        try commands.register(.{ .id = command, .label = "Manage Accounts", .category = "Accounts", .context = &self.action, .run = ManageAccountsAction.chooseProvider });
    }

    pub fn deinit(self: *Accounts) void {
        if (self.signing_in) |id| self.host.rpc.cancel(id);
        if (self.pending) |request| {
            if (request.creating == null) self.quick_input.hide();
            if (self.pending) |remaining| remaining.destroy();
        }
        for (self.grants.items) |grant| grant.free(self.allocator);
        self.grants.deinit(self.allocator);
        self.commands.unregister(command);
        var it = self.registered.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.registered.deinit(self.allocator);
        self.action.deinit();
    }

    pub fn granted(self: *Accounts, key: []const u8, forget: bool) bool {
        for (self.grants.items, 0..) |grant, i| {
            if (std.mem.eql(u8, grant.key, key)) {
                if (forget) self.grants.swapRemove(i).free(self.allocator);
                return !forget;
            }
        }
        return false;
    }

    pub fn allow(self: *Accounts, key: []const u8, provider: []const u8, session: []const u8) !void {
        if (self.granted(key, false)) return;
        const a = self.allocator;
        const id = try a.dupe(u8, key);
        errdefer a.free(id);
        const owner = try a.dupe(u8, provider);
        errdefer a.free(owner);
        const sid = try a.dupe(u8, session);
        errdefer a.free(sid);
        try self.grants.append(a, .{ .key = id, .provider = owner, .session = sid });
    }

    fn revoke(self: *Accounts, provider: []const u8, session: ?[]const u8) void {
        var i = self.grants.items.len;
        while (i != 0) {
            i -= 1;
            const grant = self.grants.items[i];
            if (!std.mem.eql(u8, grant.provider, provider)) continue;
            if (session) |id| if (!std.mem.eql(u8, grant.session, id)) continue;
            self.grants.swapRemove(i).free(self.allocator);
        }
    }

    pub fn invoke(self: *Accounts, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (args.len == 0 or args[0] != .json) return error.InvalidArguments;
        const first = args[0].json;
        if (std.mem.eql(u8, method, "$registerAuthenticationProvider")) {
            const id = field(first, "id") orelse return error.InvalidProvider;
            if (!self.registered.contains(id)) {
                const key = try self.allocator.dupe(u8, id);
                errdefer self.allocator.free(key);
                const label = try self.allocator.dupe(u8, field(first, "label") orelse id);
                errdefer self.allocator.free(label);
                try self.registered.put(self.allocator, key, label);
            }
            return .empty;
        }
        if (first != .string) return error.InvalidProvider;
        const id = first.string;
        if (std.mem.eql(u8, method, "$unregisterAuthenticationProvider")) {
            self.revoke(id, null);
            if (self.registered.fetchRemove(id)) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value);
            }
        } else if (std.mem.eql(u8, method, "$getAccounts")) {
            return .{ .json = try self.accounts(arena, id) };
        } else if (std.mem.eql(u8, method, "$ensureProvider")) {
            try self.activate(arena, id);
        } else if (std.mem.eql(u8, method, "$getSession")) {
            return @import("authenticationRequest.zig").Request.begin(self, args, arena);
        } else if (std.mem.eql(u8, method, "$sendDidChangeSessions")) {
            if (args.len > 1 and args[1] == .json and args[1].json == .object) {
                if (args[1].json.object.get("removed")) |removed| {
                    if (removed == .array) for (removed.array.items) |session| {
                        self.revoke(id, field(session, "id") orelse continue);
                    };
                }
            }
            if (self.registered.get(id)) |label| try self.host.notify(actor, "$onDidChangeAuthenticationSessions", &.{ .{ .json = first }, .{ .json = .{ .string = label } } });
        } else return error.UnsupportedAuthenticationOperation;
        return .empty;
    }

    pub fn activate(self: *Accounts, arena: Allocator, id: []const u8) !void {
        if (self.registered.contains(id)) return;
        const event = try std.mem.concat(arena, u8, &.{ "onAuthenticationRequest:", id });
        _ = try self.host.requestSync(arena, proxy(protocol.ExtHostContext.ExtHostExtensionService), "$activateByEvent", &.{ .{ .json = .{ .string = event } }, .{ .json = .{ .integer = 0 } } }, null, 5000);
    }

    pub fn interface(self: *Accounts) auth.IAuthenticationService {
        return .{ .context = self, .get_accounts = getAccounts, .create_session = createSession, .sign_out = signOut };
    }

    pub fn accounts(self: *Accounts, arena: Allocator, id: []const u8) !std.json.Value {
        const entries = try getAccounts(self, arena, id);
        var result = std.json.Array.init(arena);
        for (entries) |account| {
            var data: std.json.ObjectMap = .empty;
            try data.put(arena, "id", .{ .string = account.id });
            try data.put(arena, "label", .{ .string = account.label });
            try result.append(.{ .object = data });
        }
        return .{ .array = result };
    }

    fn getAccounts(context: *anyopaque, arena: Allocator, id: []const u8) ![]const auth.AuthenticationSessionAccount {
        const self: *Accounts = @ptrCast(@alignCast(context));
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        try self.activate(a, id);
        const sessions = try self.host.requestSync(a, actor, "$getSessions", &.{ .{ .json = .{ .string = id } }, .undefined, .{ .json = .{ .object = .empty } } }, null, 5000);
        if (sessions != .array) return error.AuthenticationProviderUnavailable;
        var entries: std.ArrayList(auth.AuthenticationSessionAccount) = .empty;
        for (sessions.array.items) |session| {
            if (session != .object) continue;
            const account = session.object.get("account") orelse continue;
            const account_id = field(account, "id") orelse continue;
            const label = field(account, "label") orelse continue;
            try entries.append(a, .{ .id = try arena.dupe(u8, account_id), .label = try arena.dupe(u8, label) });
        }
        return service.getAccounts(arena, entries.items);
    }

    fn createSession(context: *anyopaque, provider: []const u8, requested_scopes: []const []const u8) !void {
        const self: *Accounts = @ptrCast(@alignCast(context));
        if (self.signing_in != null) return;
        var scopes = std.json.Array.init(self.allocator);
        defer scopes.deinit();
        for (requested_scopes) |scope| try scopes.append(.{ .string = scope });
        self.signing_in = try self.host.call(actor, "$createSession", &.{ .{ .json = .{ .string = provider } }, .{ .json = .{ .array = scopes } }, .{ .json = .{ .object = .empty } } }, null, .{ .context = self, .callback = signedIn });
    }

    fn signedIn(context: *anyopaque, reply: rpc.Reply) void {
        const self: *Accounts = @ptrCast(@alignCast(context));
        self.signing_in = null;
        self.status.show(self.status.context, if (reply == .json and field(reply.json, "id") != null) "Signed in" else "Account sign-in did not complete");
        self.changed = true;
    }

    fn signOut(context: *anyopaque, provider_id: []const u8, account_label: []const u8) !void {
        const self: *Accounts = @ptrCast(@alignCast(context));
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const provider: rpc.Arg = .{ .json = .{ .string = provider_id } };
        const sessions = try self.host.requestSync(a, actor, "$getSessions", &.{ provider, .undefined, .{ .json = .{ .object = .empty } } }, null, 5000);
        if (sessions != .array) return error.AuthenticationProviderUnavailable;
        for (sessions.array.items) |session| {
            const id = field(session, "id") orelse continue;
            if (!std.mem.eql(u8, account_label, field(session.object.get("account") orelse continue, "label") orelse continue)) continue;
            _ = try self.host.requestSync(a, actor, "$removeSession", &.{ provider, .{ .json = .{ .string = id } } }, null, 5000);
            self.revoke(provider_id, id);
        }
        self.status.show(self.status.context, "Signed out");
        self.changed = true;
    }

    pub fn field(value: std.json.Value, name: []const u8) ?[]const u8 {
        if (value != .object) return null;
        const item = value.object.get(name) orelse return null;
        return if (item == .string) item.string else null;
    }
};
