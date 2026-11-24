// Bridge for the upstream Accounts menu and vscode.authentication.getAccounts.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Workbench = @import("../../browser/workbench.zig").Workbench;
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const proxy = @import("../../services/extensions/common/proxyIdentifier.zig").identifierFromEnum;
const QuickPick = @import("../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const Item = @import("../../../platform/quickinput/common/quickInput.zig").QuickPickItem;
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
    workbench: *Workbench,
    host: *manager.HostManager,
    extensions: []const manager.ExtensionDescription,
    choices: std.heap.ArenaAllocator,
    pending: ?*@import("authenticationRequest.zig").Request = null,
    changed: bool = false,
    selected_provider: []const u8 = "",
    selected_account: []const u8 = "",
    signing_in: ?u32 = null,
    grants: std.ArrayList(Grant) = .empty,
    registered: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(self: *Accounts, w: *Workbench, host: *manager.HostManager, extensions: []const manager.ExtensionDescription) !void {
        self.* = .{ .workbench = w, .host = host, .extensions = extensions, .choices = .init(w.allocator) };
        try w.commands.register(.{ .id = command, .label = "Manage Accounts", .category = "Accounts", .context = self, .run = chooseProvider });
    }

    pub fn deinit(self: *Accounts) void {
        if (self.signing_in) |id| self.host.rpc.cancel(id);
        if (self.pending) |request| {
            if (request.creating == null) self.workbench.quick_access.inputService().hide();
            if (self.pending) |remaining| remaining.destroy();
        }
        for (self.grants.items) |grant| grant.free(self.workbench.allocator);
        self.grants.deinit(self.workbench.allocator);
        self.workbench.commands.unregister(command);
        var it = self.registered.iterator();
        while (it.next()) |entry| {
            self.workbench.allocator.free(entry.key_ptr.*);
            self.workbench.allocator.free(entry.value_ptr.*);
        }
        self.registered.deinit(self.workbench.allocator);
        self.choices.deinit();
    }

    pub fn granted(self: *Accounts, key: []const u8, forget: bool) bool {
        for (self.grants.items, 0..) |grant, i| {
            if (std.mem.eql(u8, grant.key, key)) {
                if (forget) self.grants.swapRemove(i).free(self.workbench.allocator);
                return !forget;
            }
        }
        return false;
    }

    pub fn allow(self: *Accounts, key: []const u8, provider: []const u8, session: []const u8) !void {
        if (self.granted(key, false)) return;
        const a = self.workbench.allocator;
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
            self.grants.swapRemove(i).free(self.workbench.allocator);
        }
    }

    pub fn invoke(self: *Accounts, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (args.len == 0 or args[0] != .json) return error.InvalidArguments;
        const first = args[0].json;
        if (std.mem.eql(u8, method, "$registerAuthenticationProvider")) {
            const id = field(first, "id") orelse return error.InvalidProvider;
            if (!self.registered.contains(id)) {
                const key = try self.workbench.allocator.dupe(u8, id);
                errdefer self.workbench.allocator.free(key);
                const label = try self.workbench.allocator.dupe(u8, field(first, "label") orelse id);
                errdefer self.workbench.allocator.free(label);
                try self.registered.put(self.workbench.allocator, key, label);
            }
            return .empty;
        }
        if (first != .string) return error.InvalidProvider;
        const id = first.string;
        if (std.mem.eql(u8, method, "$unregisterAuthenticationProvider")) {
            self.revoke(id, null);
            if (self.registered.fetchRemove(id)) |entry| {
                self.workbench.allocator.free(entry.key);
                self.workbench.allocator.free(entry.value);
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

    pub fn accounts(self: *Accounts, arena: Allocator, id: []const u8) !std.json.Value {
        var scratch = std.heap.ArenaAllocator.init(self.workbench.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        try self.activate(a, id);
        const sessions = try self.host.requestSync(a, actor, "$getSessions", &.{ .{ .json = .{ .string = id } }, .undefined, .{ .json = .{ .object = .empty } } }, null, 5000);
        if (sessions != .array) return error.AuthenticationProviderUnavailable;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var list = std.json.Array.init(arena);
        for (sessions.array.items) |session| {
            if (session != .object) continue;
            const account = session.object.get("account") orelse continue;
            const account_id = field(account, "id") orelse continue;
            const label = field(account, "label") orelse continue;
            if ((try seen.getOrPut(a, account_id)).found_existing) continue;
            var data: std.json.ObjectMap = .empty;
            try data.put(arena, "id", .{ .string = try arena.dupe(u8, account_id) });
            try data.put(arena, "label", .{ .string = try arena.dupe(u8, label) });
            try list.append(.{ .object = data });
        }
        return .{ .array = list };
    }

    fn chooseProvider(context: *anyopaque) !void {
        const self: *Accounts = @ptrCast(@alignCast(context));
        _ = self.choices.reset(.retain_capacity);
        const a = self.choices.allocator();
        var items: std.ArrayList(Item) = .empty;
        for (self.extensions) |ext| {
            const contributes = ext.manifest.object.get("contributes") orelse continue;
            if (contributes != .object) continue;
            const providers = contributes.object.get("authentication") orelse continue;
            if (providers != .array) continue;
            for (providers.array.items) |provider| {
                try items.append(a, .{ .item = .{ .id = field(provider, "id") orelse continue, .label = field(provider, "label") orelse continue } });
            }
        }
        try self.workbench.quick_access.inputService().showPick(items.items, .{ .placeholder = "Select an account provider", .no_results_label = "No account providers installed" }, showAccounts, self);
    }

    fn showAccounts(context: *anyopaque, picker: *QuickPick) !void {
        const self: *Accounts = @ptrCast(@alignCast(context));
        const selected = picker.selectedItem() orelse return;
        const a = self.choices.allocator();
        const list = try self.accounts(a, selected.id);
        self.selected_provider = selected.id;
        var items: std.ArrayList(Item) = .empty;
        for (list.array.items) |account| try items.append(a, .{ .item = .{
            .id = try std.mem.concat(a, u8, &.{ "account:", field(account, "id").? }),
            .label = field(account, "label").?,
        } });
        const supports_sign_in = std.mem.eql(u8, selected.id, "github") or std.mem.eql(u8, selected.id, "microsoft");
        if (supports_sign_in) try items.append(a, .{ .item = .{ .id = "signin", .label = "Sign in…" } });
        const title = try std.fmt.allocPrint(a, "{s} accounts", .{selected.label});
        try self.workbench.quick_access.inputService().showPick(items.items, .{ .placeholder = title, .no_results_label = "No signed-in accounts" }, manage, self);
    }

    fn manage(context: *anyopaque, picker: *QuickPick) !void {
        const self: *Accounts = @ptrCast(@alignCast(context));
        const selected = picker.selectedItem() orelse return;
        const a = self.choices.allocator();
        if (std.mem.eql(u8, selected.id, "signin")) {
            if (self.signing_in != null) return;
            var scopes = std.json.Array.init(a);
            try scopes.append(.{ .string = if (std.mem.eql(u8, self.selected_provider, "github")) "read:user" else "User.Read" });
            self.signing_in = try self.host.call(actor, "$createSession", &.{ .{ .json = .{ .string = self.selected_provider } }, .{ .json = .{ .array = scopes } }, .{ .json = .{ .object = .empty } } }, null, .{ .context = self, .callback = signedIn });
            return;
        }
        if (!std.mem.startsWith(u8, selected.id, "account:")) return;
        self.selected_account = selected.id["account:".len..];
        const title = try std.fmt.allocPrint(a, "Sign out of {s}?", .{selected.label});
        try self.workbench.quick_access.inputService().showPick(&.{ .{ .item = .{ .id = "cancel", .label = "Cancel" } }, .{ .item = .{ .id = "signout", .label = "Sign out" } } }, .{ .placeholder = title }, signOut, self);
    }

    fn signedIn(context: *anyopaque, reply: rpc.Reply) void {
        const self: *Accounts = @ptrCast(@alignCast(context));
        self.signing_in = null;
        self.workbench.setStatusHint("{s}", .{if (reply == .json and field(reply.json, "id") != null) "Signed in" else "Account sign-in did not complete"});
        self.changed = true;
    }

    fn signOut(context: *anyopaque, picker: *QuickPick) !void {
        const self: *Accounts = @ptrCast(@alignCast(context));
        const item = picker.selectedItem() orelse return;
        if (!std.mem.eql(u8, item.id, "signout")) return;
        var scratch = std.heap.ArenaAllocator.init(self.workbench.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const provider: rpc.Arg = .{ .json = .{ .string = self.selected_provider } };
        const sessions = try self.host.requestSync(a, actor, "$getSessions", &.{ provider, .undefined, .{ .json = .{ .object = .empty } } }, null, 5000);
        if (sessions != .array) return error.AuthenticationProviderUnavailable;
        for (sessions.array.items) |session| {
            const id = field(session, "id") orelse continue;
            if (!std.mem.eql(u8, self.selected_account, field(session.object.get("account") orelse continue, "id") orelse continue)) continue;
            _ = try self.host.requestSync(a, actor, "$removeSession", &.{ provider, .{ .json = .{ .string = id } } }, null, 5000);
            self.revoke(self.selected_provider, id);
        }
        self.workbench.setStatusHint("Signed out", .{});
        self.changed = true;
    }

    pub fn field(value: std.json.Value, name: []const u8) ?[]const u8 {
        if (value != .object) return null;
        const item = value.object.get(name) orelse return null;
        return if (item == .string) item.string else null;
    }
};
