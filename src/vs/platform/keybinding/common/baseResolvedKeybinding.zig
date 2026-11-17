// Port of `src/vs/platform/keybinding/common/baseResolvedKeybinding.ts`.
//
// Terminal adaptation: the abstract `_getLabel`/`_getAriaLabel`/...
// implementations are a `Methods` vtable, and the resolved strings are
// computed once in `init` instead of on every getter. The caller owns the
// object lifetime with `deinit`; getters return slices into its storage.
const std = @import("std");
const Allocator = std.mem.Allocator;
const key_bindings = @import("../../../base/common/keybindings.zig");
const labels = @import("../../../base/common/keybindingLabels.zig");
const platform = @import("../../../base/common/platform.zig");
const ResolvedChord = key_bindings.ResolvedChord;
const ResolvedKeybinding = key_bindings.ResolvedKeybinding;
const SingleModifierChord = key_bindings.SingleModifierChord;
const OperatingSystem = platform.OperatingSystem;

pub fn BaseResolvedKeybinding(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Methods = struct {
            context: *anyopaque,
            /// The returned label is owned by the base.
            get_label: *const fn (context: *anyopaque, allocator: Allocator, os: OperatingSystem, chord: T) anyerror![]u8,
            get_aria_label: *const fn (context: *anyopaque, allocator: Allocator, chord: T) anyerror![]u8,
            get_electron_accelerator: *const fn (context: *anyopaque, allocator: Allocator, chord: T) anyerror!?[]u8,
            get_user_settings_label: *const fn (context: *anyopaque, allocator: Allocator, chord: T) anyerror![]u8,
            is_wysiwyg: *const fn (context: *anyopaque, chord: T) bool,
            is_duplicate_modifier_case: *const fn (chord: T) bool,
            /// The returned dispatch string is owned by the base.
            get_chord_dispatch: *const fn (context: *anyopaque, allocator: Allocator, chord: T) anyerror!?[]u8,
            get_single_modifier_chord_dispatch: *const fn (context: *anyopaque, chord: T) ?SingleModifierChord,
        };

        allocator: Allocator,
        os: OperatingSystem,
        chords: []const T,
        methods: Methods,

        label: ?[]u8 = null,
        aria_label: ?[]u8 = null,
        electron_accelerator: ?[]u8 = null,
        user_settings_label: ?[]u8 = null,
        resolved_chords: []ResolvedChord = &.{},
        dispatch_chords: []?[]const u8 = &.{},
        single_modifier_dispatch: []?SingleModifierChord = &.{},
        ui_labels: []?[]u8 = &.{},
        aria_labels: []?[]u8 = &.{},
        electron_labels: []?[]u8 = &.{},
        user_settings_labels: []?[]u8 = &.{},

        pub fn init(allocator: Allocator, os: OperatingSystem, chords: []const T, methods: Methods) !Self {
            if (chords.len == 0) return error.InvalidArgument;
            var self = Self{
                .allocator = allocator,
                .os = os,
                .chords = chords,
                .methods = methods,
            };
            errdefer self.deinit();
            try self.resolve();
            return self;
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            freeLabels(allocator, self.ui_labels);
            freeLabels(allocator, self.aria_labels);
            freeLabels(allocator, self.electron_labels);
            freeLabels(allocator, self.user_settings_labels);

            if (self.label) |value| allocator.free(value);
            if (self.aria_label) |value| allocator.free(value);
            if (self.electron_accelerator) |value| allocator.free(value);
            if (self.user_settings_label) |value| allocator.free(value);

            for (self.dispatch_chords) |dispatch| {
                if (dispatch) |value| allocator.free(value);
            }
            if (self.dispatch_chords.len > 0) allocator.free(self.dispatch_chords);
            if (self.resolved_chords.len > 0) allocator.free(self.resolved_chords);
            if (self.single_modifier_dispatch.len > 0) allocator.free(self.single_modifier_dispatch);

            self.label = null;
            self.aria_label = null;
            self.electron_accelerator = null;
            self.user_settings_label = null;
            self.dispatch_chords = &.{};
            self.resolved_chords = &.{};
            self.single_modifier_dispatch = &.{};
            self.ui_labels = &.{};
            self.aria_labels = &.{};
            self.electron_labels = &.{};
            self.user_settings_labels = &.{};
        }

        pub fn getLabel(self: *const Self) ?[]const u8 {
            return self.label;
        }

        pub fn getAriaLabel(self: *const Self) ?[]const u8 {
            return self.aria_label;
        }

        pub fn getElectronAccelerator(self: *const Self) ?[]const u8 {
            return self.electron_accelerator;
        }

        pub fn getUserSettingsLabel(self: *const Self) ?[]const u8 {
            return self.user_settings_label;
        }

        pub fn hasMultipleChords(self: *const Self) bool {
            return self.chords.len > 1;
        }

        pub fn getChords(self: *const Self) []const ResolvedChord {
            return self.resolved_chords;
        }

        pub fn getDispatchChords(self: *const Self) []const ?[]const u8 {
            return self.dispatch_chords;
        }

        pub fn getSingleModifierDispatchChords(self: *const Self) []const ?SingleModifierChord {
            return self.single_modifier_dispatch;
        }

        fn resolve(self: *Self) !void {
            const allocator = self.allocator;
            const count = self.chords.len;

            self.ui_labels = try allocator.alloc(?[]u8, count);
            @memset(self.ui_labels, null);
            self.aria_labels = try allocator.alloc(?[]u8, count);
            @memset(self.aria_labels, null);
            self.electron_labels = try allocator.alloc(?[]u8, count);
            @memset(self.electron_labels, null);
            self.user_settings_labels = try allocator.alloc(?[]u8, count);
            @memset(self.user_settings_labels, null);

            for (self.chords, 0..) |chord, index| {
                self.ui_labels[index] = try self.methods.get_label(self.methods.context, allocator, self.os, chord);
                self.aria_labels[index] = try self.methods.get_aria_label(self.methods.context, allocator, chord);
                self.electron_labels[index] = try self.methods.get_electron_accelerator(self.methods.context, allocator, chord);
                self.user_settings_labels[index] = try self.methods.get_user_settings_label(self.methods.context, allocator, chord);
            }

            self.label = try labels.UILabelProvider.toLabel(allocator, self.os, self.chords, self.ui_labels);
            self.aria_label = try labels.AriaLabelProvider.toLabel(allocator, self.os, self.chords, self.aria_labels);
            self.user_settings_label = try labels.UserSettingsLabelProvider.toLabel(allocator, self.os, self.chords, self.user_settings_labels);

            if (self.chords.len > 1 or self.methods.is_duplicate_modifier_case(self.chords[0])) {
                // Electron cannot handle chords or modifier-only keybindings.
                self.electron_accelerator = null;
            } else {
                self.electron_accelerator = try labels.ElectronAcceleratorLabelProvider.toLabel(allocator, self.os, self.chords, self.electron_labels);
            }

            self.resolved_chords = try allocator.alloc(ResolvedChord, count);
            for (self.chords, 0..) |chord, index| {
                self.resolved_chords[index] = .{
                    .ctrl_key = chord.ctrl_key,
                    .shift_key = chord.shift_key,
                    .alt_key = chord.alt_key,
                    .meta_key = chord.meta_key,
                    .key_label = self.ui_labels[index],
                    .key_aria_label = self.aria_labels[index],
                };
            }

            self.dispatch_chords = try allocator.alloc(?[]const u8, count);
            @memset(self.dispatch_chords, null);
            for (self.chords, 0..) |chord, index| {
                self.dispatch_chords[index] = try self.methods.get_chord_dispatch(self.methods.context, allocator, chord);
            }

            self.single_modifier_dispatch = try allocator.alloc(?SingleModifierChord, count);
            for (self.chords, 0..) |chord, index| {
                self.single_modifier_dispatch[index] = self.methods.get_single_modifier_chord_dispatch(self.methods.context, chord);
            }
        }

        fn freeLabels(allocator: Allocator, entries: []?[]u8) void {
            for (entries) |entry| {
                if (entry) |value| allocator.free(value);
            }
            if (entries.len > 0) allocator.free(entries);
        }

        pub fn isWYSIWYG(self: *const Self) bool {
            for (self.chords) |chord| {
                if (!self.methods.is_wysiwyg(self.methods.context, chord)) return false;
            }
            return true;
        }
    };
}

/// Adapts a `BaseResolvedKeybinding(T)` to the `ResolvedKeybinding` vtable.
pub fn resolvedKeybindingInterface(comptime T: type, self: *BaseResolvedKeybinding(T)) ResolvedKeybinding {
    const Adapter = struct {
        fn getLabel(context: *anyopaque) ?[]const u8 {
            const base: *BaseResolvedKeybinding(T) = @ptrCast(@alignCast(context));
            return base.getLabel();
        }

        fn getAriaLabel(context: *anyopaque) ?[]const u8 {
            const base: *BaseResolvedKeybinding(T) = @ptrCast(@alignCast(context));
            return base.getAriaLabel();
        }

        fn getElectronAccelerator(context: *anyopaque) ?[]const u8 {
            const base: *BaseResolvedKeybinding(T) = @ptrCast(@alignCast(context));
            return base.getElectronAccelerator();
        }

        fn getUserSettingsLabel(context: *anyopaque) ?[]const u8 {
            const base: *BaseResolvedKeybinding(T) = @ptrCast(@alignCast(context));
            return base.getUserSettingsLabel();
        }

        fn isWYSIWYG(context: *anyopaque) bool {
            const base: *BaseResolvedKeybinding(T) = @ptrCast(@alignCast(context));
            return base.isWYSIWYG();
        }

        fn hasMultipleChords(context: *anyopaque) bool {
            const base: *BaseResolvedKeybinding(T) = @ptrCast(@alignCast(context));
            return base.hasMultipleChords();
        }

        fn getChords(context: *anyopaque) []const ResolvedChord {
            const base: *BaseResolvedKeybinding(T) = @ptrCast(@alignCast(context));
            return base.getChords();
        }

        fn getDispatchChords(context: *anyopaque) []const ?[]const u8 {
            const base: *BaseResolvedKeybinding(T) = @ptrCast(@alignCast(context));
            return base.getDispatchChords();
        }

        fn getSingleModifierDispatchChords(context: *anyopaque) []const ?SingleModifierChord {
            const base: *BaseResolvedKeybinding(T) = @ptrCast(@alignCast(context));
            return base.getSingleModifierDispatchChords();
        }
    };

    return .{
        .context = self,
        .get_label_fn = Adapter.getLabel,
        .get_aria_label_fn = Adapter.getAriaLabel,
        .get_electron_accelerator_fn = Adapter.getElectronAccelerator,
        .get_user_settings_label_fn = Adapter.getUserSettingsLabel,
        .is_wysiwyg_fn = Adapter.isWYSIWYG,
        .has_multiple_chords_fn = Adapter.hasMultipleChords,
        .get_chords_fn = Adapter.getChords,
        .get_dispatch_chords_fn = Adapter.getDispatchChords,
        .get_single_modifier_dispatch_chords_fn = Adapter.getSingleModifierDispatchChords,
    };
}
