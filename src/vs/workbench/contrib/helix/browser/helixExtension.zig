// Built-in Helix extension adapter.
//
// This is the only layer that knows both the Helix engine and the built-in
// extension API. The workbench core never imports it; the product composition
// root registers the descriptor.
const std = @import("std");
const Allocator = std.mem.Allocator;
const extension_api = @import("../../../api/common/extensionApi.zig");
const helix_engine = @import("../../../../editor/contrib/helix/browser/helixEngine.zig");
const HelixEngine = helix_engine.HelixEngine;
const Registers = helix_engine.Registers;
const IExtensionContext = extension_api.IExtensionContext;
const ITextEditor = extension_api.ITextEditor;

const HelixExtensionState = struct {
    allocator: Allocator,
    context: IExtensionContext,
    status: ?extension_api.IStatusEntry = null,
    engines: std.AutoHashMap(*const anyopaque, *HelixEngine),
    registers: Registers,
    active: bool = false,

    fn init(allocator: Allocator) HelixExtensionState {
        return .{
            .allocator = allocator,
            .context = undefined,
            .engines = std.AutoHashMap(*const anyopaque, *HelixEngine).init(allocator),
            .registers = Registers.init(allocator),
        };
    }

    fn deinit(self: *HelixExtensionState) void {
        var iterator = self.engines.valueIterator();
        while (iterator.next()) |engine| engine.*.deinit();
        self.engines.deinit();
        self.registers.deinit();
        self.status = null;
        self.active = false;
    }

    fn engineFor(self: *HelixExtensionState, editor: ITextEditor) !*HelixEngine {
        const key: *const anyopaque = @ptrCast(editor.model);
        if (self.engines.get(key)) |engine| {
            engine.editor = editor;
            return engine;
        }
        const engine = try HelixEngine.init(self.allocator, editor, self.context.window, self.context.commands, &self.registers);
        errdefer engine.deinit();
        engine.setHistoryService(self.context.history);
        try self.engines.put(key, engine);
        return engine;
    }

    fn updateStatus(self: *HelixExtensionState) void {
        const status = self.status orelse return;
        const editor = self.context.editors.activeTextEditor() orelse {
            status.setText("");
            return;
        };
        const engine = self.engineFor(editor) catch return;
        const text = engine.statusText();
        status.setText(if (text.len == 0) "-- NORMAL --" else text);
    }
};

pub fn create(allocator: Allocator) !extension_api.IBuiltinExtension {
    const state = try allocator.create(HelixExtensionState);
    state.* = HelixExtensionState.init(allocator);
    return .{
        .context = state,
        .id = "vscode-textbuffer.helix",
        .display_name = "Helix",
        .version = "0.1.0",
        .activate_fn = activate,
        .deactivate_fn = deactivate,
    };
}

fn stateFrom(context: *anyopaque) *HelixExtensionState {
    return @ptrCast(@alignCast(context));
}

fn activate(context: *anyopaque, api: *const IExtensionContext) anyerror!void {
    const state = stateFrom(context);
    state.context = api.*;
    state.active = true;
    const status = try api.window.createStatusEntry("helix.status", "Helix");
    state.status = status;
    api.disposables.add(status.disposable());
    api.disposables.add(try api.key_input.register(.{
        .context = state,
        .priority = .builtin_extension,
        .is_enabled = isEnabled,
        .handle = handleKey,
        .reset = resetInteraction,
    }));
    state.updateStatus();
}

fn deactivate(context: *anyopaque) void {
    const state = stateFrom(context);
    state.deinit();
    state.allocator.destroy(state);
}

fn isEnabled(context: *anyopaque) bool {
    const state = stateFrom(context);
    return state.active and state.context.editors.activeTextEditor() != null;
}

fn resetInteraction(context: *anyopaque) void {
    const state = stateFrom(context);
    const editor = state.context.editors.activeTextEditor() orelse return;
    const engine = state.engineFor(editor) catch return;
    engine.resetInteractionState();
    state.updateStatus();
}

fn handleKey(context: *anyopaque, event: *const extension_api.KeyInputEvent) anyerror!bool {
    const state = stateFrom(context);
    const editor = state.context.editors.activeTextEditor() orelse return false;
    const engine = try state.engineFor(editor);
    const consumed = engine.handleKey(event) catch |err| {
        var buffer: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "Helix: {s}", .{@errorName(err)}) catch "Helix error";
        state.context.window.setMessage(text);
        return false;
    };
    state.updateStatus();
    return consumed;
}
