// One interactive request. A grant belongs to the exact extension, provider,
// session and set of requested scopes. Grants expire with the extension host.
const std = @import("std");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const p = @import("../common/extHost.protocol.zig");
const proxy = @import("../../services/extensions/common/proxyIdentifier.zig").identifierFromEnum;
const Accounts = @import("mainThreadAuthentication.zig").Accounts;
const QuickPick = @import("../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const Item = @import("../../../platform/quickinput/common/quickInput.zig").QuickPickItem;
const V = std.json.Value;
const actor = proxy(p.ExtHostContext.ExtHostAuthentication);
const A = std.mem.Allocator;
const Window = @import("../../../base/common/windowDispatch.zig");

pub const Request = struct {
    accounts: *Accounts,
    arena: std.heap.ArenaAllocator,
    provider: []const u8,
    extension: []const u8,
    scopes: V,
    options: V,
    request_options: V = .null,
    future: ?std.Io.Future(anyerror!?rpc.HandlerReply) = null,
    completion: Window.Task = .{},
    items: []const Item = &.{},
    prompt: []const u8 = "",
    response_id: u32 = 0,
    creating: ?u32 = null,
    accepted: bool = false,
    invalidated: bool = false,

    pub fn begin(accounts: *Accounts, args: []const rpc.Arg, scratch: A) !rpc.HandlerReply {
        if (args.len != 5 or args[0] != .json or args[1] != .json or args[2] != .json or args[4] != .json) return error.InvalidArguments;
        const provider = args[0].json;
        const scopes = args[1].json;
        const extension = args[2].json;
        const opts = args[4].json;
        if (provider != .string or extension != .string or scopes != .array or opts != .object) return error.UnsupportedAuthenticationRequest;
        var unique: std.StringHashMapUnmanaged(void) = .empty;
        for (scopes.array.items) |scope| {
            if (scope != .string or (try unique.getOrPut(scratch, scope.string)).found_existing) return error.InvalidScope;
        }
        for (accounts.extensions) |ext| {
            if (std.ascii.eqlIgnoreCase(ext.identifier, extension.string)) break;
        } else return error.UnknownRequestingExtension;
        // Challenge and custom authorization endpoints have separate consent requirements.
        for ([_][]const u8{ "authorizationServer", "clientId", "resource" }) |key| if (opts.object.get(key)) |_| return error.UnsupportedAuthenticationRequest;
        const force = flag(opts, "forceNewSession");
        const create = flag(opts, "createIfNone") or force;
        if (accounts.pending != null) return if (create) error.AuthenticationInProgress else .empty;

        const a = accounts.allocator;
        const self = try a.create(Request);
        self.* = .{ .accounts = accounts, .arena = .init(a), .provider = "", .extension = "", .scopes = .null, .options = .null };
        var retain = false;
        defer if (!retain) self.destroy();
        const owned = self.arena.allocator();
        self.provider = try owned.dupe(u8, provider.string);
        self.extension = try owned.dupe(u8, extension.string);
        self.scopes = try rpc.cloneJsonValue(owned, scopes);
        self.options = .{ .object = .empty };
        if (opts.object.get("account")) |account| try self.options.object.put(owned, "account", try rpc.cloneJsonValue(owned, account));
        self.request_options = try rpc.cloneJsonValue(owned, opts);
        self.completion = .{ .queue = accounts.window, .context = self, .run = completed, .progress = true };
        retain = true;
        accounts.pending = self;
        return .{ .deferred = .{ .context = self, .start = start } };
    }

    fn prepare(self: *Request) anyerror!?rpc.HandlerReply {
        defer self.completion.post();
        const accounts = self.accounts;
        const owned = self.arena.allocator();
        const scratch = owned;
        const opts = self.request_options;
        const force = flag(opts, "forceNewSession");
        const create = flag(opts, "createIfNone") or force;
        try accounts.activate(scratch, self.provider);
        const sessions = try self.query(scratch);
        if (self.invalidated) return error.AuthenticationProviderChanged;
        var items: std.ArrayList(Item) = .empty;
        if (!force) for (sessions.array.items) |session| {
            if (!self.matches(session)) continue;
            const id = Accounts.field(session, "id").?;
            const key = try self.grantKey(scratch, session);
            if (accounts.granted(key, flag(opts, "clearSessionPreference"))) return rpc.HandlerReply{ .json = session };
            const label = Accounts.field(session.object.get("account").?, "label") orelse continue;
            try items.append(owned, .{ .item = .{ .id = try std.mem.concat(owned, u8, &.{ "session:", id }), .label = try std.fmt.allocPrint(owned, "Allow with {s}", .{label}) } });
        };
        if (!create or flag(opts, "silent")) return rpc.HandlerReply.empty;
        try items.insert(owned, 0, .{ .item = .{ .id = "deny", .label = "Cancel" } });
        try items.append(owned, .{ .item = .{ .id = "new", .label = "Sign in and allow" } });
        var names: std.ArrayList([]const u8) = .empty;
        for (self.scopes.array.items) |scope| try names.append(owned, scope.string);
        self.prompt = try std.fmt.allocPrint(owned, "Allow {s} to use {s} ({s})?", .{ self.extension, self.provider, try std.mem.join(owned, ", ", names.items) });
        self.items = items.items;
        return null;
    }

    fn flag(o: V, key: []const u8) bool {
        const v = o.object.get(key) orelse return false;
        return v == .object or (v == .bool and v.bool);
    }

    fn matches(self: *Request, session: V) bool {
        if (Accounts.field(session, "id") == null or Accounts.field(session, "accessToken") == null) return false;
        const account = session.object.get("account") orelse return false;
        const id = Accounts.field(account, "id") orelse return false;
        if (self.options.object.get("account")) |wanted| {
            if (!std.mem.eql(u8, id, Accounts.field(wanted, "id") orelse return false)) return false;
        }
        const actual = session.object.get("scopes") orelse return false;
        if (actual != .array or actual.array.items.len != self.scopes.array.items.len) return false;
        for (self.scopes.array.items) |wanted| {
            for (actual.array.items) |scope| {
                if (scope == .string and std.mem.eql(u8, scope.string, wanted.string)) break;
            } else return false;
        }
        return true;
    }

    fn grantKey(self: *Request, a: A, session: V) ![]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        for (self.scopes.array.items) |scope| try names.append(a, scope.string);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        return std.json.Stringify.valueAlloc(a, .{ self.extension, self.provider, Accounts.field(session, "id").?, Accounts.field(session.object.get("account").?, "id").?, names.items }, .{});
    }

    fn query(self: *Request, a: A) !V {
        const result = try self.accounts.requestRpc(a, actor, "$getSessions", &.{ .{ .json = .{ .string = self.provider } }, .{ .json = self.scopes }, .{ .json = self.options } }, null, 5000);
        if (result != .array) return error.AuthenticationProviderUnavailable;
        return result;
    }

    fn start(context: *anyopaque, _: *rpc.RpcProtocol, id: u32) void {
        const self: *Request = @ptrCast(@alignCast(context));
        self.response_id = id;
        self.future = self.accounts.window.io.concurrent(prepare, .{self}) catch |err| {
            self.finish(.{ .err = .{ .name = "Error", .message = @errorName(err) } });
            return;
        };
    }

    fn completed(context: *anyopaque, _: i64, _: bool) bool {
        const self: *Request = @ptrCast(@alignCast(context));
        const reply = self.future.?.await(self.accounts.window.io) catch |err| {
            self.future = null;
            self.finish(.{ .err = .{ .name = "Error", .message = @errorName(err) } });
            return true;
        };
        self.future = null;
        if (reply) |value| {
            self.finish(value);
            return true;
        }
        self.accounts.changed = true;
        self.accounts.quick_input.showPick(self.items, .{
            .placeholder = self.prompt,
            .cleanup = dismissed,
            .cleanup_context = self,
        }, accept, self) catch {
            self.finish(.{ .err = .{ .name = "Error", .message = "Unable to display account permissions" } });
        };
        return true;
    }

    fn accept(context: *anyopaque, picker: *QuickPick) !void {
        const self: *Request = @ptrCast(@alignCast(context));
        const item = picker.selectedItem() orelse return;
        if (std.mem.eql(u8, item.id, "new")) {
            self.creating = try self.accounts.host.call(actor, "$createSession", &.{ .{ .json = .{ .string = self.provider } }, .{ .json = self.scopes }, .{ .json = self.options } }, null, .{ .context = self, .callback = created });
            self.accepted = true;
        } else if (std.mem.startsWith(u8, item.id, "session:")) {
            const id = try self.arena.allocator().dupe(u8, item.id["session:".len..]);
            self.future = try self.accounts.window.io.concurrent(selectSession, .{ self, id });
        }
    }

    fn selectSession(self: *Request, id: []const u8) anyerror!?rpc.HandlerReply {
        defer self.completion.post();
        const sessions = try self.query(self.arena.allocator());
        if (self.invalidated) return error.AuthenticationProviderChanged;
        // Consent applies to the selected exact session and scopes, not a
        // stale picker result. Revalidate after the asynchronous lookup.
        for (sessions.array.items) |session| {
            if (self.matches(session) and std.mem.eql(u8, Accounts.field(session, "id").?, id)) {
                try self.recordGrant(session);
                return rpc.HandlerReply{ .json = session };
            }
        }
        return rpc.HandlerReply{ .err = .{ .name = "Error", .message = "Selected account is no longer available" } };
    }

    fn dismissed(context: *anyopaque) void {
        const self: *Request = @ptrCast(@alignCast(context));
        if (self.creating != null or self.future != null) return;
        if (!self.accepted) self.finish(.{ .err = .{ .name = "Canceled", .message = "Account access was not granted" } }) else self.destroy();
    }

    fn created(context: *anyopaque, reply: rpc.Reply) void {
        const self: *Request = @ptrCast(@alignCast(context));
        self.creating = null;
        if (!self.invalidated and reply == .json and self.matches(reply.json)) {
            self.recordGrant(reply.json) catch {
                self.finish(.{ .err = .{ .name = "Error", .message = "Could not authorize account" } });
                return;
            };
            self.finish(.{ .json = reply.json });
        } else self.finish(.{ .err = .{ .name = "Error", .message = "Sign-in did not return a session with the requested permissions" } });
    }

    fn recordGrant(self: *Request, session: V) !void {
        if (self.invalidated or !self.accounts.registered.contains(self.provider)) return error.AuthenticationProviderChanged;
        const key = try self.grantKey(self.arena.allocator(), session);
        try self.accounts.allow(key, self.provider, Accounts.field(session, "id").?);
    }

    fn finish(self: *Request, reply: rpc.HandlerReply) void {
        self.accounts.host.rpc.sendReply(self.response_id, reply);
        self.destroy();
    }

    pub fn destroy(self: *Request) void {
        if (self.future) |*future| _ = future.cancel(self.accounts.window.io) catch null;
        self.future = null;
        self.completion.schedule(null);
        if (self.creating) |id| self.accounts.host.rpc.cancel(id);
        if (self.accounts.pending == self) self.accounts.pending = null;
        self.arena.deinit();
        self.accounts.allocator.destroy(self);
    }
};
