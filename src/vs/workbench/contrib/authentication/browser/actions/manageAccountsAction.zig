// Terminal adaptation of the account-management picker in
// `src/vs/workbench/contrib/authentication/browser/actions/manageAccountsAction.ts`.
// The existing terminal command also lets users select an installed provider to sign in.
const std = @import("std");
const IAuthenticationService = @import("../../../../services/authentication/common/authentication.zig").IAuthenticationService;
const Description = @import("../../../../services/extensions/common/extensionHostManager.zig").ExtensionDescription;
const QuickInputService = @import("../../../../../platform/quickinput/browser/quickInputService.zig").QuickInputService;
const QuickPick = @import("../../../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const Item = @import("../../../../../platform/quickinput/common/quickInput.zig").QuickPickItem;
const Window = @import("../../../../../base/common/windowDispatch.zig");

pub const ManageAccountsAction = struct {
    authentication: IAuthenticationService,
    quick_input: *QuickInputService,
    window: ?*Window.Queue = null,
    pending: ?std.Io.Future(anyerror!void) = null,
    completion: Window.Task = .{},
    extensions: []const Description,
    choices: std.heap.ArenaAllocator,
    selected_provider: []const u8 = "",
    selected_account: []const u8 = "",

    pub fn deinit(self: *ManageAccountsAction) void {
        self.cancelPending();
        if (self.quick_input.isVisible() and self.quick_input.handler_context == @as(*anyopaque, self)) self.quick_input.hide();
        self.choices.deinit();
    }

    pub fn chooseProvider(context: *anyopaque) !void {
        const self: *ManageAccountsAction = @ptrCast(@alignCast(context));
        self.cancelPending();
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
        try self.quick_input.showPick(items.items, .{ .placeholder = "Select an account provider", .no_results_label = "No account providers installed" }, showAccounts, self);
    }

    fn showAccounts(context: *anyopaque, picker: *QuickPick) !void {
        const self: *ManageAccountsAction = @ptrCast(@alignCast(context));
        const selected = picker.selectedItem() orelse return;
        self.cancelPending();
        const a = self.choices.allocator();
        const provider = try a.dupe(u8, selected.id);
        const label = try a.dupe(u8, selected.label);
        if (self.window) |window| {
            if (window.scheduler != null) {
                self.completion = .{ .queue = window, .context = self, .run = completed, .progress = true };
                self.pending = try window.io.concurrent(loadAccounts, .{ self, provider, label });
                return;
            }
        }
        try self.collectAccounts(provider, label);
    }

    fn loadAccounts(self: *ManageAccountsAction, provider: []const u8, label: []const u8) anyerror!void {
        defer self.completion.post();
        try self.collectAccounts(provider, label);
    }

    fn cancelPending(self: *ManageAccountsAction) void {
        if (self.pending) |*future| future.cancel(self.window.?.io) catch {};
        self.pending = null;
        self.completion.schedule(null);
    }

    fn completed(context: *anyopaque, _: i64, _: bool) bool {
        const self: *ManageAccountsAction = @ptrCast(@alignCast(context));
        if (self.pending) |*future| future.await(self.window.?.io) catch |err| {
            if (err != error.Canceled) {
                if (self.quick_input.on_error) |report| report(self.quick_input.error_context orelse undefined, @errorName(err));
            }
        };
        self.pending = null;
        return true;
    }

    fn collectAccounts(self: *ManageAccountsAction, provider: []const u8, label: []const u8) !void {
        const a = self.choices.allocator();
        const list = try self.authentication.get_accounts(self.authentication.context, a, provider);
        if (self.window) |window| {
            try window.io.checkCancel();
            if (window.scheduler != null and self.quick_input.isVisible()) return;
        }
        self.selected_provider = provider;
        var items: std.ArrayList(Item) = .empty;
        for (list) |account| try items.append(a, .{ .item = .{
            .id = try std.mem.concat(a, u8, &.{ "account:", account.id }),
            .label = account.label,
        } });
        const supports_sign_in = std.mem.eql(u8, provider, "github") or std.mem.eql(u8, provider, "microsoft");
        if (supports_sign_in) try items.append(a, .{ .item = .{ .id = "signin", .label = "Sign in…" } });
        const title = try std.fmt.allocPrint(a, "{s} accounts", .{label});
        try self.quick_input.showPick(items.items, .{ .placeholder = title, .no_results_label = "No signed-in accounts" }, manage, self);
    }

    fn manage(context: *anyopaque, picker: *QuickPick) !void {
        const self: *ManageAccountsAction = @ptrCast(@alignCast(context));
        const selected = picker.selectedItem() orelse return;
        const a = self.choices.allocator();
        if (std.mem.eql(u8, selected.id, "signin")) {
            const scope = if (std.mem.eql(u8, self.selected_provider, "github")) "read:user" else "User.Read";
            try self.authentication.create_session(self.authentication.context, self.selected_provider, &.{scope});
            return;
        }
        if (!std.mem.startsWith(u8, selected.id, "account:")) return;
        self.selected_account = selected.label;
        const title = try std.fmt.allocPrint(a, "Sign out of {s}?", .{selected.label});
        try self.quick_input.showPick(&.{ .{ .item = .{ .id = "cancel", .label = "Cancel" } }, .{ .item = .{ .id = "signout", .label = "Sign out" } } }, .{ .placeholder = title }, signOut, self);
    }

    fn signOut(context: *anyopaque, picker: *QuickPick) !void {
        const self: *ManageAccountsAction = @ptrCast(@alignCast(context));
        const item = picker.selectedItem() orelse return;
        if (!std.mem.eql(u8, item.id, "signout")) return;
        self.cancelPending();
        if (self.window) |window| {
            if (window.scheduler != null) {
                self.completion = .{ .queue = window, .context = self, .run = completed, .progress = true };
                self.pending = try window.io.concurrent(signOutAwait, .{self});
                return;
            }
        }
        try self.authentication.sign_out(self.authentication.context, self.selected_provider, self.selected_account);
    }

    fn signOutAwait(self: *ManageAccountsAction) anyerror!void {
        defer self.completion.post();
        try self.authentication.sign_out(self.authentication.context, self.selected_provider, self.selected_account);
    }

    fn field(value: std.json.Value, name: []const u8) ?[]const u8 {
        if (value != .object) return null;
        const item = value.object.get(name) orelse return null;
        return if (item == .string) item.string else null;
    }
};
