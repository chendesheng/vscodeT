//! Resolves the `editor.*` settings the terminal renderer can express into
//! the ported `ComputedEditorOptions` and text-model options.
//!
//! Upstream `browser/config/editorConfiguration.ts` reads the configuration
//! service through the `EditorOptions` descriptor registry. The terminal can
//! only express a subset of those options (cells, no fonts, pixels, minimap or
//! smooth scrolling), so this module maps that subset explicitly instead of
//! porting every descriptor. `README.md` lists the options that stay
//! terminal defaults.
//!
//! The reader returns values borrowed from the configuration service. Values
//! are consumed immediately; the returned pointer may be invalidated by the
//! next read (language overrides are merged in the service's scratch arena).
const std = @import("std");
const configuration = @import("../../../platform/configuration/common/configuration.zig");
const editorOptions = @import("../../common/config/editorOptions.zig");
const browser_config = @import("./editorConfiguration.zig");
const text_model_mod = @import("../../common/model/textModel.zig");

const Value = configuration.Value;
const EditorOption = editorOptions.EditorOption;
const MatchBrackets = editorOptions.MatchBrackets;
const RenderLineHighlight = editorOptions.RenderLineHighlight;
const RenderWhitespace = editorOptions.RenderWhitespace;
const RenderFinalNewline = editorOptions.RenderFinalNewline;
const RenderLineNumbersType = editorOptions.RenderLineNumbersType;
const MultiCursorModifier = editorOptions.MultiCursorModifier;
const TextEditorCursorBlinkingStyle = editorOptions.TextEditorCursorBlinkingStyle;
const TextEditorCursorStyle = editorOptions.TextEditorCursorStyle;
const ComputedEditorOptions = browser_config.ComputedEditorOptions;

/// Number of `EditorOption` values, used for the `ConfigurationChangedEvent`
/// flags array.
pub const option_count = @typeInfo(EditorOption).@"enum".field_names.len;
pub const ChangeSet = [option_count]bool;

/// A configuration-service view. `language_id` selects `[language]` override
/// blocks; `resource` selects the workspace-folder scope for the open file.
pub const Reader = struct {
    context: *anyopaque,
    get_value: *const fn (
        context: *anyopaque,
        key: []const u8,
        language_id: ?[]const u8,
        resource: ?[]const u8,
    ) ?*const Value,
};

fn readBool(reader: Reader, key: []const u8, language_id: ?[]const u8, resource: ?[]const u8) ?bool {
    const value = reader.get_value(reader.context, key, language_id, resource) orelse return null;
    return switch (value.*) {
        .bool => |inner| inner,
        else => null,
    };
}

fn readInt(reader: Reader, key: []const u8, language_id: ?[]const u8, resource: ?[]const u8) ?i64 {
    const value = reader.get_value(reader.context, key, language_id, resource) orelse return null;
    return switch (value.*) {
        .integer => |inner| inner,
        else => null,
    };
}

fn readString(reader: Reader, key: []const u8, language_id: ?[]const u8, resource: ?[]const u8) ?[]const u8 {
    const value = reader.get_value(reader.context, key, language_id, resource) orelse return null;
    return switch (value.*) {
        .string => |inner| inner,
        else => null,
    };
}

fn mark(changed: *ChangeSet, comptime option: EditorOption, is_changed: bool) void {
    if (is_changed) changed[@backingInt(option)] = true;
}

/// Applies the view-level settings to `options` and fills `changed` with the
/// `EditorOption` entries that differ from the previous values. Returns true
/// when at least one mapped option changed.
pub fn applyViewSettings(
    options: *ComputedEditorOptions,
    reader: Reader,
    language_id: ?[]const u8,
    resource: ?[]const u8,
    changed: *ChangeSet,
) bool {
    @memset(changed, false);
    var any = false;

    if (readString(reader, "editor.lineNumbers", language_id, resource)) |text| {
        if (parseLineNumbers(text)) |value| {
            const previous = options.get(.lineNumbers).render_type;
            mark(changed, .lineNumbers, previous != value);
            any = any or previous != value;
            options.set(.lineNumbers, .{ .render_type = value, .render_fn = null });
        }
    }
    if (readString(reader, "editor.renderWhitespace", language_id, resource)) |text| {
        if (parseRenderWhitespace(text)) |value| {
            const previous = options.get(.renderWhitespace);
            mark(changed, .renderWhitespace, previous != value);
            any = any or previous != value;
            options.set(.renderWhitespace, value);
        }
    }
    if (readBool(reader, "editor.renderControlCharacters", language_id, resource)) |value| {
        const previous = options.get(.renderControlCharacters);
        mark(changed, .renderControlCharacters, previous != value);
        any = any or previous != value;
        options.set(.renderControlCharacters, value);
    }
    if (readString(reader, "editor.renderFinalNewline", language_id, resource)) |text| {
        if (parseRenderFinalNewline(text)) |value| {
            const previous = options.get(.renderFinalNewline);
            mark(changed, .renderFinalNewline, previous != value);
            any = any or previous != value;
            options.set(.renderFinalNewline, value);
        }
    }
    if (readString(reader, "editor.renderLineHighlight", language_id, resource)) |text| {
        if (parseRenderLineHighlight(text)) |value| {
            const previous = options.get(.renderLineHighlight);
            mark(changed, .renderLineHighlight, previous != value);
            any = any or previous != value;
            options.set(.renderLineHighlight, value);
        }
    }
    if (readBool(reader, "editor.renderLineHighlightOnlyWhenFocus", language_id, resource)) |value| {
        const previous = options.get(.renderLineHighlightOnlyWhenFocus);
        mark(changed, .renderLineHighlightOnlyWhenFocus, previous != value);
        any = any or previous != value;
        options.set(.renderLineHighlightOnlyWhenFocus, value);
    }
    if (readBool(reader, "editor.roundedSelection", language_id, resource)) |value| {
        const previous = options.get(.roundedSelection);
        mark(changed, .roundedSelection, previous != value);
        any = any or previous != value;
        options.set(.roundedSelection, value);
    }
    if (readString(reader, "editor.cursorBlinking", language_id, resource)) |text| {
        if (parseCursorBlinking(text)) |value| {
            const previous = options.get(.cursorBlinking);
            mark(changed, .cursorBlinking, previous != value);
            any = any or previous != value;
            options.set(.cursorBlinking, value);
        }
    }
    if (readString(reader, "editor.cursorStyle", language_id, resource)) |text| {
        if (parseCursorStyle(text)) |value| {
            const previous = options.get(.cursorStyle);
            mark(changed, .cursorStyle, previous != value);
            any = any or previous != value;
            options.set(.cursorStyle, value);
            // The terminal has no platform cursor override; the effective
            // style follows the configured one.
            const previous_effective = options.get(.effectiveCursorStyle);
            mark(changed, .effectiveCursorStyle, previous_effective != value);
            options.set(.effectiveCursorStyle, value);
        }
    }
    if (readString(reader, "editor.multiCursorModifier", language_id, resource)) |text| {
        if (parseMultiCursorModifier(text)) |value| {
            const previous = options.get(.multiCursorModifier);
            mark(changed, .multiCursorModifier, previous != value);
            any = any or previous != value;
            options.set(.multiCursorModifier, value);
        }
    }
    if (readString(reader, "editor.matchBrackets", language_id, resource)) |text| {
        if (parseMatchBrackets(text)) |value| {
            const previous = options.get(.matchBrackets);
            mark(changed, .matchBrackets, previous != value);
            any = any or previous != value;
            options.set(.matchBrackets, value);
        }
    }

    var sticky = options.get(.stickyScroll);
    var sticky_changed = false;
    if (readBool(reader, "editor.stickyScroll.enabled", language_id, resource)) |value| {
        if (sticky.enabled != value) {
            sticky.enabled = value;
            sticky_changed = true;
        }
    }
    if (readInt(reader, "editor.stickyScroll.maxLineCount", language_id, resource)) |value| {
        const clamped: f64 = @floatFromInt(std.math.clamp(value, 1, 20));
        if (sticky.max_line_count != clamped) {
            sticky.max_line_count = clamped;
            sticky_changed = true;
        }
    }
    if (readString(reader, "editor.stickyScroll.defaultModel", language_id, resource)) |text| {
        if (parseStickyDefaultModel(text)) |value| {
            if (sticky.default_model != value) {
                sticky.default_model = value;
                sticky_changed = true;
            }
        }
    }
    if (readBool(reader, "editor.stickyScroll.scrollWithEditor", language_id, resource)) |value| {
        if (sticky.scroll_with_editor != value) {
            sticky.scroll_with_editor = value;
            sticky_changed = true;
        }
    }
    if (sticky_changed) {
        options.set(.stickyScroll, sticky);
        mark(changed, .stickyScroll, true);
        any = true;
    }

    return any;
}

/// Applies the model-level indentation and bracket settings. Detection stays a
/// creation-time decision like upstream: when `editor.detectIndentation` is
/// true the text model keeps the indentation it guessed on open (or was
/// changed to explicitly by the user).
pub fn applyModelSettings(model: *text_model_mod.TextModel, reader: Reader, language_id: ?[]const u8, resource: ?[]const u8) bool {
    var changed = false;
    const detect_indentation = readBool(reader, "editor.detectIndentation", language_id, resource) orelse true;
    if (!detect_indentation) {
        const tab_size = readInt(reader, "editor.tabSize", language_id, resource) orelse 4;
        const indent_size = readInt(reader, "editor.indentSize", language_id, resource) orelse tab_size;
        const insert_spaces = readBool(reader, "editor.insertSpaces", language_id, resource) orelse true;
        const resolved = model.getOptions();
        const next_tab: usize = @intCast(@max(tab_size, 1));
        const next_indent: usize = @intCast(@max(indent_size, 1));
        if (next_tab != resolved.tabSize or next_indent != resolved.indentSize or insert_spaces != resolved.insertSpaces) {
            model.updateOptions(.{
                .tabSize = next_tab,
                .indentSize = .{ .number = @intCast(@min(next_indent, 255)) },
                .insertSpaces = insert_spaces,
                .trimAutoWhitespace = null,
                .bracketColorizationOptions = null,
            });
            changed = true;
        }
    }

    const colorization = model.getOptions().bracketPairColorizationOptions;
    const colorization_enabled = readBool(reader, "editor.bracketPairColorization.enabled", language_id, resource) orelse colorization.enabled;
    const independent_pool = readBool(reader, "editor.bracketPairColorization.independentColorPoolPerBracketType", language_id, resource) orelse colorization.independentColorPoolPerBracketType;
    if (colorization.enabled != colorization_enabled or colorization.independentColorPoolPerBracketType != independent_pool) {
        model.updateOptions(.{
            .tabSize = null,
            .indentSize = null,
            .insertSpaces = null,
            .trimAutoWhitespace = null,
            .bracketColorizationOptions = .{
                .enabled = colorization_enabled,
                .independentColorPoolPerBracketType = independent_pool,
            },
        });
        changed = true;
    }

    return changed;
}

fn parseLineNumbers(text: []const u8) ?RenderLineNumbersType {
    if (std.mem.eql(u8, text, "on")) return .On;
    if (std.mem.eql(u8, text, "off")) return .Off;
    if (std.mem.eql(u8, text, "relative")) return .Relative;
    if (std.mem.eql(u8, text, "interval")) return .Interval;
    return null;
}

fn parseRenderWhitespace(text: []const u8) ?RenderWhitespace {
    if (std.mem.eql(u8, text, "none")) return .none;
    if (std.mem.eql(u8, text, "boundary")) return .boundary;
    if (std.mem.eql(u8, text, "selection")) return .selection;
    if (std.mem.eql(u8, text, "trailing")) return .trailing;
    if (std.mem.eql(u8, text, "all")) return .all;
    return null;
}

fn parseRenderFinalNewline(text: []const u8) ?RenderFinalNewline {
    if (std.mem.eql(u8, text, "off")) return .off;
    if (std.mem.eql(u8, text, "on")) return .on;
    if (std.mem.eql(u8, text, "dimmed")) return .dimmed;
    return null;
}

fn parseRenderLineHighlight(text: []const u8) ?RenderLineHighlight {
    if (std.mem.eql(u8, text, "none")) return .none;
    if (std.mem.eql(u8, text, "gutter")) return .gutter;
    if (std.mem.eql(u8, text, "line")) return .line;
    if (std.mem.eql(u8, text, "all")) return .all;
    return null;
}

fn parseCursorBlinking(text: []const u8) ?TextEditorCursorBlinkingStyle {
    if (std.mem.eql(u8, text, "blink")) return .Blink;
    if (std.mem.eql(u8, text, "smooth")) return .Smooth;
    if (std.mem.eql(u8, text, "phase")) return .Phase;
    if (std.mem.eql(u8, text, "expand")) return .Expand;
    if (std.mem.eql(u8, text, "solid")) return .Solid;
    return null;
}

fn parseCursorStyle(text: []const u8) ?TextEditorCursorStyle {
    if (std.mem.eql(u8, text, "line")) return .Line;
    if (std.mem.eql(u8, text, "block")) return .Block;
    if (std.mem.eql(u8, text, "underline")) return .Underline;
    if (std.mem.eql(u8, text, "line-thin")) return .LineThin;
    if (std.mem.eql(u8, text, "block-outline")) return .BlockOutline;
    if (std.mem.eql(u8, text, "underline-thin")) return .UnderlineThin;
    return null;
}

fn parseMultiCursorModifier(text: []const u8) ?MultiCursorModifier {
    if (std.mem.eql(u8, text, "alt")) return .alt_key;
    if (std.mem.eql(u8, text, "ctrlCmd") or std.mem.eql(u8, text, "ctrl")) return .ctrl_key;
    if (std.mem.eql(u8, text, "meta")) return .meta_key;
    return null;
}

fn parseStickyDefaultModel(text: []const u8) ?editorOptions.StickyScrollDefaultModel {
    if (std.mem.eql(u8, text, "outlineModel")) return .outline_model;
    if (std.mem.eql(u8, text, "foldingProviderModel")) return .folding_provider_model;
    if (std.mem.eql(u8, text, "indentationModel")) return .indentation_model;
    return null;
}

fn parseMatchBrackets(text: []const u8) ?MatchBrackets {
    if (std.mem.eql(u8, text, "always")) return .always;
    if (std.mem.eql(u8, text, "near")) return .near;
    if (std.mem.eql(u8, text, "never")) return .never;
    return null;
}

const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;

const FakeSettings = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMap(*Value),

    fn init(allocator: std.mem.Allocator) FakeSettings {
        return .{ .allocator = allocator, .values = std.StringHashMap(*Value).init(allocator) };
    }

    fn deinit(self: *FakeSettings) void {
        var iterator = self.values.valueIterator();
        while (iterator.next()) |entry| {
            self.allocator.destroy(entry.*);
        }
        self.values.deinit();
    }

    fn set(self: *FakeSettings, key: []const u8, value: Value) !void {
        if (self.values.get(key)) |stored| {
            stored.* = value;
            return;
        }
        const stored = try self.allocator.create(Value);
        stored.* = value;
        try self.values.put(key, stored);
    }

    fn get(context: *anyopaque, key: []const u8, _: ?[]const u8, _: ?[]const u8) ?*const Value {
        const self: *FakeSettings = @ptrCast(@alignCast(context));
        return self.values.get(key);
    }

    fn reader(self: *FakeSettings) Reader {
        return .{ .context = self, .get_value = get };
    }
};

test "terminalEditorConfiguration: view settings map onto computed options" {
    const allocator = std.testing.allocator;
    var settings = FakeSettings.init(allocator);
    defer settings.deinit();
    try settings.set("editor.lineNumbers", .{ .string = "relative" });
    try settings.set("editor.renderWhitespace", .{ .string = "trailing" });
    try settings.set("editor.renderControlCharacters", .{ .bool = false });
    try settings.set("editor.renderFinalNewline", .{ .string = "off" });
    try settings.set("editor.renderLineHighlight", .{ .string = "none" });
    try settings.set("editor.roundedSelection", .{ .bool = false });
    try settings.set("editor.cursorStyle", .{ .string = "underline" });
    try settings.set("editor.multiCursorModifier", .{ .string = "ctrlCmd" });
    try settings.set("editor.matchBrackets", .{ .string = "never" });

    var options = ComputedEditorOptions.init();
    var changed: ChangeSet = undefined;
    const any = applyViewSettings(&options, settings.reader(), null, null, &changed);
    try std.testing.expect(any);
    try std.testing.expectEqual(RenderLineNumbersType.Relative, options.get(.lineNumbers).render_type);
    try std.testing.expectEqual(RenderWhitespace.trailing, options.get(.renderWhitespace));
    try std.testing.expect(!options.get(.renderControlCharacters));
    try std.testing.expectEqual(RenderFinalNewline.off, options.get(.renderFinalNewline));
    try std.testing.expectEqual(RenderLineHighlight.none, options.get(.renderLineHighlight));
    try std.testing.expect(!options.get(.roundedSelection));
    try std.testing.expectEqual(TextEditorCursorStyle.Underline, options.get(.cursorStyle));
    try std.testing.expectEqual(TextEditorCursorStyle.Underline, options.get(.effectiveCursorStyle));
    try std.testing.expectEqual(MultiCursorModifier.ctrl_key, options.get(.multiCursorModifier));
    try std.testing.expectEqual(MatchBrackets.never, options.get(.matchBrackets));
    try std.testing.expect(changed[@backingInt(EditorOption.lineNumbers)]);
    try std.testing.expect(changed[@backingInt(EditorOption.matchBrackets)]);

    // Re-applying the same values reports no change, so a settings reload does
    // not force a pointless view rebuild.
    var unchanged: ChangeSet = undefined;
    try std.testing.expect(!applyViewSettings(&options, settings.reader(), null, null, &unchanged));
    try std.testing.expect(!unchanged[@backingInt(EditorOption.lineNumbers)]);
}

test "terminalEditorConfiguration: sticky scroll settings map and clamp" {
    const allocator = std.testing.allocator;
    var settings = FakeSettings.init(allocator);
    defer settings.deinit();
    try settings.set("editor.stickyScroll.enabled", .{ .bool = false });
    try settings.set("editor.stickyScroll.maxLineCount", .{ .integer = 100 });
    try settings.set("editor.stickyScroll.defaultModel", .{ .string = "indentationModel" });
    try settings.set("editor.stickyScroll.scrollWithEditor", .{ .bool = false });

    var options = ComputedEditorOptions.init();
    var changed: ChangeSet = undefined;
    try std.testing.expect(applyViewSettings(&options, settings.reader(), null, null, &changed));
    const sticky = options.get(.stickyScroll);
    try std.testing.expect(!sticky.enabled);
    try std.testing.expectEqual(@as(f64, 20), sticky.max_line_count);
    try std.testing.expectEqual(editorOptions.StickyScrollDefaultModel.indentation_model, sticky.default_model);
    try std.testing.expect(!sticky.scroll_with_editor);
    try std.testing.expect(changed[@backingInt(EditorOption.stickyScroll)]);
}

test "terminalEditorConfiguration: absent settings keep upstream defaults" {
    const allocator = std.testing.allocator;
    var settings = FakeSettings.init(allocator);
    defer settings.deinit();

    var options = ComputedEditorOptions.init();
    var changed: ChangeSet = undefined;
    try std.testing.expect(!applyViewSettings(&options, settings.reader(), null, null, &changed));
    // `null` from the reader means "not configured": the computed default is
    // untouched, including the upstream `selection` whitespace mode.
    try std.testing.expectEqual(RenderWhitespace.selection, options.get(.renderWhitespace));
    try std.testing.expectEqual(RenderLineNumbersType.On, options.get(.lineNumbers).render_type);
}

test "terminalEditorConfiguration: model indentation and bracket colorization" {
    const allocator = std.testing.allocator;
    var settings = FakeSettings.init(allocator);
    defer settings.deinit();
    try settings.set("editor.detectIndentation", .{ .bool = false });
    try settings.set("editor.tabSize", .{ .integer = 2 });
    try settings.set("editor.insertSpaces", .{ .bool = false });
    try settings.set("editor.bracketPairColorization.enabled", .{ .bool = false });

    var model = try TestModel.init(allocator, "line\n", "plaintext");
    defer model.deinit();

    try std.testing.expect(applyModelSettings(model.model, settings.reader(), null, null));
    try std.testing.expectEqual(@as(usize, 2), model.model.getOptions().tabSize);
    try std.testing.expect(!model.model.getOptions().insertSpaces);
    try std.testing.expect(!model.model.getOptions().bracketPairColorizationOptions.enabled);

    // Idempotent: the same values no longer change the model.
    try std.testing.expect(!applyModelSettings(model.model, settings.reader(), null, null));

    // Detection enabled leaves the model's guessed indentation alone.
    try settings.set("editor.detectIndentation", .{ .bool = true });
    try settings.set("editor.tabSize", .{ .integer = 8 });
    try std.testing.expect(!applyModelSettings(model.model, settings.reader(), null, null));
    try std.testing.expectEqual(@as(usize, 2), model.model.getOptions().tabSize);

    // Both colorization options apply independently.
    try settings.set("editor.bracketPairColorization.enabled", .{ .bool = true });
    try settings.set("editor.bracketPairColorization.independentColorPoolPerBracketType", .{ .bool = true });
    try std.testing.expect(applyModelSettings(model.model, settings.reader(), null, null));
    try std.testing.expect(model.model.getOptions().bracketPairColorizationOptions.enabled);
    try std.testing.expect(model.model.getOptions().bracketPairColorizationOptions.independentColorPoolPerBracketType);

    // Removing the independent-pool setting keeps the model's last value.
    try settings.set("editor.bracketPairColorization.independentColorPoolPerBracketType", .{ .null = {} });
    try std.testing.expect(!applyModelSettings(model.model, settings.reader(), null, null));
    try std.testing.expect(model.model.getOptions().bracketPairColorizationOptions.independentColorPoolPerBracketType);
}
