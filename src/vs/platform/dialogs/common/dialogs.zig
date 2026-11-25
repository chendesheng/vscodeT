// Port of the dialog result and save-confirmation prompt used by the editor
// part.
//
// `ConfirmResult` is `src/vs/platform/dialogs/common/dialogs.ts`. The message,
// detail and button labels mirror `doShowSaveConfirm` in
// `src/vs/workbench/services/dialogs/browser/abstractFileDialogService.ts`:
// one file asks about that file, several ask about the numbered set, and the
// primary action becomes "Save All". The prompt is a plain value so the TUI
// dialog widget can own rendering and input; the browser method's
// `IDialogService.prompt` call is the terminal dialog host's job.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ConfirmResult = enum { SAVE, DONT_SAVE, CANCEL };

const Emitter = @import("../../../base/common/event.zig").Emitter;

/// Portable terminal projection of IPrompt/IDialogArgs. Native button
/// activation returns the index, while dismissal returns null.
pub const DialogPrompt = struct {
    message: []const u8,
    detail: []const u8 = "",
    buttons: []const []const u8,
    initial_focus: usize = 0,
    severity: @import("../../../base/common/severity.zig").Severity = .Warning,
};

pub const IConfirmation = struct {
    message: []const u8,
    detail: []const u8 = "",
    primary_button: []const u8 = "Yes",
    cancel_button: []const u8 = cancel_label,
    initial_focus: usize = 0,
};

pub const IConfirmationResult = struct { confirmed: bool };

pub const PromptHandler = struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, ?usize) void,
    dispose: ?*const fn (*anyopaque) void = null,
};

pub const ConfirmationHandler = struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, IConfirmationResult) void,
    dispose: ?*const fn (*anyopaque) void = null,
};

pub const DialogCallback = union(enum) {
    prompt: PromptHandler,
    confirm: ConfirmationHandler,

    pub fn complete(self: DialogCallback, selected: ?usize) void {
        switch (self) {
            .prompt => |handler| handler.complete(handler.context, selected),
            .confirm => |handler| handler.complete(handler.context, .{ .confirmed = selected != null and selected.? == 0 }),
        }
    }

    pub fn dispose(self: DialogCallback) void {
        switch (self) {
            inline else => |handler| if (handler.dispose) |cleanup| cleanup(handler.context),
        }
    }
};

/// The owner may dismiss a pending dialog on disposal. The model owns the
/// result callback until the item is closed.
pub const IDialogHandle = struct {
    context: *anyopaque,
    id: usize,
    cancel_fn: *const fn (*anyopaque, usize) void,

    pub fn cancel(self: IDialogHandle) void {
        self.cancel_fn(self.context, self.id);
    }
};

pub const dialog_service_id = @import("../../instantiation/common/instantiation.zig").ServiceIdentifier(IDialogService, "dialogService");

pub const IDialogService = struct {
    context: *anyopaque,
    has_dialog: *const fn (*anyopaque) bool,
    prompt_fn: *const fn (*anyopaque, DialogPrompt, PromptHandler) anyerror!IDialogHandle,
    confirm_fn: *const fn (*anyopaque, IConfirmation, ConfirmationHandler) anyerror!IDialogHandle,
    on_will_show_dialog: *Emitter(void),
    on_did_show_dialog: *Emitter(void),

    pub fn hasDialog(self: IDialogService) bool {
        return self.has_dialog(self.context);
    }

    pub fn prompt(self: IDialogService, args: DialogPrompt, handler: PromptHandler) !IDialogHandle {
        return self.prompt_fn(self.context, args, handler);
    }

    pub fn confirm(self: IDialogService, args: IConfirmation, handler: ConfirmationHandler) !IDialogHandle {
        return self.confirm_fn(self.context, args, handler);
    }
};

/// Upstream `MAX_CONFIRM_FILES`: the detail lists at most this many names and
/// summarizes the remainder.
pub const max_confirm_files: usize = 10;

pub const save_label = "Save";
pub const save_all_label = "Save All";
pub const dont_save_label = "Don't Save";
pub const cancel_label = "Cancel";

const detail_text = "Your changes will be lost if you don't save them.";

/// Owns the allocated message/detail strings; the button labels are static.
pub const SaveConfirmPrompt = struct {
    allocator: Allocator,
    message: []u8,
    detail: []u8,
    save_label: []const u8,

    pub fn deinit(self: *SaveConfirmPrompt) void {
        self.allocator.free(self.message);
        self.allocator.free(self.detail);
        self.* = undefined;
    }
};

/// Builds upstream's save confirmation for `file_names`. Returns null when
/// the list is empty, matching `doShowSaveConfirm` returning `DONT_SAVE`
/// without showing a prompt.
pub fn saveConfirmPrompt(allocator: Allocator, file_names: []const []const u8) !?SaveConfirmPrompt {
    if (file_names.len == 0) return null;

    if (file_names.len == 1) {
        const message = try std.fmt.allocPrint(
            allocator,
            "Do you want to save the changes you made to {s}?",
            .{file_names[0]},
        );
        errdefer allocator.free(message);
        return .{
            .allocator = allocator,
            .message = message,
            .detail = try allocator.dupe(u8, detail_text),
            .save_label = save_label,
        };
    }

    const message = try std.fmt.allocPrint(
        allocator,
        "Do you want to save the changes to the following {d} files?",
        .{file_names.len},
    );
    errdefer allocator.free(message);
    return .{
        .allocator = allocator,
        .message = message,
        .detail = try buildFileNamesDetail(allocator, file_names),
        .save_label = save_all_label,
    };
}

fn buildFileNamesDetail(allocator: Allocator, file_names: []const []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    const shown = @min(file_names.len, max_confirm_files);
    for (file_names[0..shown]) |name| {
        try out.appendSlice(name);
        try out.append('\n');
    }

    if (file_names.len > max_confirm_files) {
        const hidden = file_names.len - max_confirm_files;
        if (hidden == 1) {
            try out.appendSlice("...1 additional file not shown");
        } else {
            try out.print("...{d} additional files not shown", .{hidden});
        }
        try out.append('\n');
    }

    // Upstream appends an empty name, so the detail has a blank line between
    // the file list and the save description.
    try out.append('\n');
    try out.appendSlice(detail_text);
    return out.toOwnedSlice();
}

test "saveConfirmPrompt: empty list shows no dialog" {
    try std.testing.expect((try saveConfirmPrompt(std.testing.allocator, &.{})) == null);
}

test "saveConfirmPrompt: one file uses the file-specific wording" {
    var prompt = (try saveConfirmPrompt(std.testing.allocator, &.{"http-proxy.js"})).?;
    defer prompt.deinit();

    try std.testing.expectEqualStrings(
        "Do you want to save the changes you made to http-proxy.js?",
        prompt.message,
    );
    try std.testing.expectEqualStrings(detail_text, prompt.detail);
    try std.testing.expectEqualStrings(save_label, prompt.save_label);
}

test "saveConfirmPrompt: several files list names and use Save All" {
    const names = [_][]const u8{
        "a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.txt",
        "g.txt", "h.txt", "i.txt", "j.txt", "k.txt", "l.txt",
    };
    var prompt = (try saveConfirmPrompt(std.testing.allocator, &names)).?;
    defer prompt.deinit();

    try std.testing.expectEqualStrings(
        "Do you want to save the changes to the following 12 files?",
        prompt.message,
    );
    try std.testing.expectEqualStrings(
        "a.txt\nb.txt\nc.txt\nd.txt\ne.txt\nf.txt\ng.txt\nh.txt\ni.txt\nj.txt\n" ++
            "...2 additional files not shown\n\n" ++ detail_text,
        prompt.detail,
    );
    try std.testing.expectEqualStrings(save_all_label, prompt.save_label);
}

test "saveConfirmPrompt: one hidden file uses the singular summary" {
    const names = [_][]const u8{
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11",
    };
    var prompt = (try saveConfirmPrompt(std.testing.allocator, &names)).?;
    defer prompt.deinit();

    try std.testing.expect(std.mem.indexOf(u8, prompt.detail, "...1 additional file not shown\n\n") != null);
}
