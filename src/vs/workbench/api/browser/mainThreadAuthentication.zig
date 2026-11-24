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

pub const Accounts = struct {
    workbench: *Workbench,
    host: *manager.HostManager,
    extensions: []const manager.ExtensionDescription,
    choices: std.heap.ArenaAllocator,
    registered: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(self: *Accounts, w: *Workbench, host: *manager.HostManager, extensions: []const manager.ExtensionDescription) !void {
        self.* = .{ .workbench = w, .host = host, .extensions = extensions, .choices = .init(w.allocator) };
        try w.commands.register(.{ .id = command, .label = "Manage Accounts", .category = "Accounts", .context = self, .run = chooseProvider });
    }

    pub fn deinit(self: *Accounts) void {
        self.workbench.commands.unregister(command);
        var it = self.registered.keyIterator();
        while (it.next()) |key| self.workbench.allocator.free(key.*);
        self.registered.deinit(self.workbench.allocator);
        self.choices.deinit();
    }

    pub fn invoke(self: *Accounts, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (args.len == 0 or args[0] != .json) return error.InvalidArguments;
        const first = args[0].json;
        if (std.mem.eql(u8, method, "$registerAuthenticationProvider")) {
            const id = field(first, "id") orelse return error.InvalidProvider;
            if (!self.registered.contains(id)) {
                const key = try self.workbench.allocator.dupe(u8, id);
                errdefer self.workbench.allocator.free(key);
                try self.registered.put(self.workbench.allocator, key, {});
            }
            return .empty;
        }
        if (first != .string) return error.InvalidProvider;
        const id = first.string;
        if (std.mem.eql(u8, method, "$unregisterAuthenticationProvider")) {
            if (self.registered.fetchRemove(id)) |entry| self.workbench.allocator.free(entry.key);
        } else if (std.mem.eql(u8, method, "$getAccounts")) {
            return .{ .json = try self.accounts(arena, id) };
        } else if (std.mem.eql(u8, method, "$ensureProvider")) {
            try self.activate(arena, id);
        } else if (std.mem.eql(u8, method, "$getSession")) {
            // A consumer must have an explicit account and scope grant before
            // receiving credentials. Signed-out and silent queries return no session.
            if (args.len > 4 and args[4] == .json and args[4].json == .object) {
                for ([_][]const u8{ "createIfNone", "forceNewSession" }) |key| {
                    if (args[4].json.object.get(key)) |value| {
                        if (value == .object or (value == .bool and value.bool)) return error.InteractiveAuthorizationUnavailable;
                    }
                }
            }
        } else if (!std.mem.eql(u8, method, "$sendDidChangeSessions")) return error.UnsupportedAuthenticationOperation;
        return .empty;
    }

    fn activate(self: *Accounts, arena: Allocator, id: []const u8) !void {
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
        const items = try a.alloc(Item, list.array.items.len);
        for (list.array.items, items) |account, *item| {
            item.* = .{ .item = .{ .id = field(account, "id").?, .label = field(account, "label").? } };
        }
        const title = try std.fmt.allocPrint(a, "{s} accounts", .{selected.label});
        try self.workbench.quick_access.inputService().showPick(items, .{ .placeholder = title, .no_results_label = "No signed-in accounts" }, done, self);
    }

    fn done(_: *anyopaque, _: *QuickPick) !void {}

    fn field(value: std.json.Value, name: []const u8) ?[]const u8 {
        if (value != .object) return null;
        const item = value.object.get(name) orelse return null;
        return if (item == .string) item.string else null;
    }
};
