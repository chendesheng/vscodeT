// Interop test with the pinned Node extension host. This is the S2 smoke
// test from docs/extensions.md: boot the host, initialize workspace and
// configuration, start the extension host, and observe VSCodeVim activation.
//
// It needs Node, the bundled launcher (host/dist/extensionHost.mjs) and the
// extracted VSCodeVim fixture, so it only runs when ZIG_E2E_EXTENSION_HOST=1
// and both paths exist. `zig build test` therefore stays hermetic.
const std = @import("std");
const time_compat = @import("../../../../../base/common/timeCompat.zig");
const manager = @import("../../common/extensionHostManager.zig");
const rpc = @import("../../common/rpcProtocol.zig");
const proxyIdentifier = @import("../../common/proxyIdentifier.zig");
const protocol = @import("../../../../api/common/extHost.protocol.zig");



const Activation = struct {
    activated: bool = false,
    identifier: ?[]u8 = null,
    runtime_error: ?[]u8 = null,

    fn deinit(self: *Activation, allocator: std.mem.Allocator) void {
        if (self.identifier) |text| allocator.free(text);
        if (self.runtime_error) |text| allocator.free(text);
    }
};

const ActorSlot = struct {
    nid: u8,
    activation: *Activation,
    allocator: std.mem.Allocator,

    fn handler(self: *ActorSlot) rpc.ActorHandler {
        return .{ .context = self, .invoke = invoke };
    }

    fn invoke(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../../../base/common/cancellation.zig").CancellationToken, arena: std.mem.Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        const self: *ActorSlot = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, method, "$getInitialState")) {
            var state: std.json.ObjectMap = .empty;
            try state.put(arena, "isFocused", .{ .bool = true });
            try state.put(arena, "isActive", .{ .bool = true });
            return .{ .json = .{ .object = state } };
        }
        if (std.mem.eql(u8, method, "$getTools")) {
            return .{ .json = .{ .array = std.json.Array.init(arena) } };
        }
        if (std.mem.eql(u8, method, "$ensureActivation")) {
            return .{ .json = .{ .bool = true } };
        }
        if (std.mem.eql(u8, method, "$onDidActivateExtension")) {
            if (args.len > 0 and args[0] == .json and args[0].json == .object) {
                if (args[0].json.object.get("value")) |value| {
                    if (value == .string) {
                        if (self.activation.identifier) |old| self.allocator.free(old);
                        self.activation.identifier = try self.allocator.dupe(u8, value.string);
                        self.activation.activated = true;
                    }
                }
            }
            return .empty;
        }
        if (std.mem.eql(u8, method, "$onExtensionActivationError")) {
            if (args.len > 1 and args[1] == .json and args[1].json == .object) {
                if (args[1].json.object.get("message")) |value| {
                    if (value == .string) {
                        if (self.activation.runtime_error) |old| self.allocator.free(old);
                        self.activation.runtime_error = try self.allocator.dupe(u8, value.string);
                    }
                }
            }
            return .empty;
        }
        if (std.mem.eql(u8, method, "$onExtensionRuntimeError") or std.mem.eql(u8, method, "$onUnexpectedError")) {
            if (args.len > 0 and args[0] == .json and args[0].json == .object) {
                if (args[0].json.object.get("message")) |value| {
                    if (value == .string) {
                        if (self.activation.runtime_error) |old| self.allocator.free(old);
                        self.activation.runtime_error = try self.allocator.dupe(u8, value.string);
                    }
                }
            }
            return .empty;
        }
        _ = self.nid;
        return .empty;
    }
};

const WaitFlag = struct {
    done: bool = false,

    fn callback(context: *anyopaque, reply: rpc.Reply) void {
        const self: *WaitFlag = @ptrCast(@alignCast(context));
        _ = reply;
        self.done = true;
    }
};

fn done(context: *anyopaque) bool {
    const flag: *WaitFlag = @ptrCast(@alignCast(context));
    return flag.done;
}

fn activated(context: *anyopaque) bool {
    const activation: *Activation = @ptrCast(@alignCast(context));
    return activation.activated or activation.runtime_error != null;
}

fn emptyConfig(arena: std.mem.Allocator) !std.json.Value {
    var root: std.json.ObjectMap = .empty;
    for ([_][]const u8{ "defaults", "policy", "application", "userLocal", "userRemote", "workspace" }) |key| {
        var model: std.json.ObjectMap = .empty;
        try model.put(arena, "contents", .{ .object = .empty });
        try model.put(arena, "keys", .{ .array = std.json.Array.init(arena) });
        try model.put(arena, "overrides", .{ .array = std.json.Array.init(arena) });
        try root.put(arena, key, .{ .object = model });
    }
    try root.put(arena, "folders", .{ .array = std.json.Array.init(arena) });
    try root.put(arena, "configurationScopes", .{ .array = std.json.Array.init(arena) });
    return .{ .object = root };
}

test "VSCodeVim activates in the pinned extension host" {
    if (std.c.getenv("ZIG_E2E_EXTENSION_HOST") == null) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const repo_root = try std.Io.Dir.cwd().realPathFileAlloc(time_compat.io, ".", allocator);
    defer allocator.free(repo_root);
    const host_script = try std.fs.path.join(allocator, &.{ repo_root, "host/dist/extensionHost.mjs" });
    defer allocator.free(host_script);
    std.Io.Dir.cwd().access(time_compat.io, host_script, .{}) catch return error.SkipZigTest;

    const extension_path = try std.fs.path.join(allocator, &.{ repo_root, ".cache-ext/vim/extension" });
    defer allocator.free(extension_path);
    std.Io.Dir.cwd().access(time_compat.io, extension_path, .{}) catch return error.SkipZigTest;

    var description = try manager.readExtensionDescription(allocator, extension_path);
    defer description.deinit(allocator);

    const data_path = try std.fs.path.join(allocator, &.{ repo_root, ".cache-ext/data-e2e" });
    defer allocator.free(data_path);
    std.Io.Dir.cwd().createDirPath(time_compat.io, data_path) catch {};
    const workspace = try std.fs.path.join(allocator, &.{ repo_root, ".cache-ext/workspace" });
    defer allocator.free(workspace);
    std.Io.Dir.cwd().createDirPath(time_compat.io, workspace) catch {};

    var activation = Activation{};
    defer activation.deinit(allocator);

    const host = try manager.HostManager.start(allocator, .{
        .host_script = host_script,
        .extension = &description,
        .workspace_path = workspace,
        .workspace_name = "workspace",
        .data_path = data_path,
        .app_root = repo_root,
        .parent_pid = @intCast(std.os.linux.getpid()),
    });
    defer host.deinit();

    var slots: [protocol.max_nid + 1]ActorSlot = undefined;
    var nid: u8 = 1;
    while (nid <= protocol.max_nid) : (nid += 1) {
        slots[nid] = .{ .nid = nid, .activation = &activation, .allocator = allocator };
        const entry = protocol.identifier(nid).?;
        host.setActor(.{ .nid = nid, .sid = entry.sid }, slots[nid].handler());
    }

    try host.expectControl(2, 10_000);
    var arena_instance = std.heap.ArenaAllocator.init(allocator);
    defer arena_instance.deinit();
    const init_data = try manager.buildInitData(arena_instance.allocator(), .{
        .host_script = host_script,
        .extension = &description,
        .workspace_path = workspace,
        .workspace_name = "workspace",
        .data_path = data_path,
        .app_root = repo_root,
        .parent_pid = @intCast(std.os.linux.getpid()),
    });
    try host.sendInitData(init_data);
    try host.expectControl(1, 10_000);

    var wait = WaitFlag{};
    const reply_callback = rpc.ReplyCallback{ .context = &wait, .callback = WaitFlag.callback };

    var workspace_args = std.array_list.Managed(rpc.Arg).init(allocator);
    defer workspace_args.deinit();
    var workspace_data: std.json.ObjectMap = .empty;
    try workspace_data.put(arena_instance.allocator(), "id", .{ .string = "workspace" });
    try workspace_data.put(arena_instance.allocator(), "name", .{ .string = "workspace" });
    try workspace_data.put(arena_instance.allocator(), "transient", .{ .bool = false });
    try workspace_data.put(arena_instance.allocator(), "configuration", .null);
    try workspace_data.put(arena_instance.allocator(), "isUntitled", .null);
    var folders = std.json.Array.init(arena_instance.allocator());
    var folder: std.json.ObjectMap = .empty;
    try folder.put(arena_instance.allocator(), "uri", try manager.fileUri(arena_instance.allocator(), workspace));
    try folder.put(arena_instance.allocator(), "name", .{ .string = "workspace" });
    try folder.put(arena_instance.allocator(), "index", .{ .integer = 0 });
    try folders.append(.{ .object = folder });
    try workspace_data.put(arena_instance.allocator(), "folders", .{ .array = folders });
    try workspace_args.append(.{ .json = .{ .object = workspace_data } });
    try workspace_args.append(.{ .json = .{ .bool = true } });
    _ = try host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostWorkspace), "$initializeWorkspace", workspace_args.items, null, reply_callback);
    try host.waitUntil(&wait, done, 10_000);

    wait.done = false;
    var config_args = [_]rpc.Arg{.{ .json = try emptyConfig(arena_instance.allocator()) }};
    _ = try host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostConfiguration), "$initializeConfiguration", &config_args, null, reply_callback);
    try host.waitUntil(&wait, done, 10_000);

    var delta: std.json.ObjectMap = .empty;
    const arena = arena_instance.allocator();
    try delta.put(arena, "versionId", .{ .integer = 1 });
    try delta.put(arena, "toRemove", .{ .array = std.json.Array.init(arena) });
    try delta.put(arena, "toAdd", .{ .array = std.json.Array.init(arena) });
    try delta.put(arena, "addActivationEvents", .{ .object = .empty });
    try delta.put(arena, "myToRemove", .{ .array = std.json.Array.init(arena) });
    try delta.put(arena, "myToAdd", .{ .array = std.json.Array.init(arena) });
    var start_args = [_]rpc.Arg{.{ .json = .{ .object = delta } }};
    _ = try host.call(proxyIdentifier.identifierFromEnum(protocol.ExtHostContext.ExtHostExtensionService), "$startExtensionHost", &start_args, null, manager.noop_callback);

    try host.waitUntil(&activation, activated, 20_000);
    try std.testing.expect(activation.activated);
    try std.testing.expectEqualStrings("vscodevim.vim", activation.identifier.?);
    try std.testing.expect(activation.runtime_error == null);
}
