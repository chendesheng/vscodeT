// Built-in Helix extension integration tests.

const std = @import("std");
const ui = @import("ui");
const BuiltinExtensionHost = @import("../../../../api/browser/builtinExtensionHost.zig").BuiltinExtensionHost;
const helix_extension = @import("../../browser/helixExtension.zig");
const time_compat = @import("../../../../../base/common/timeCompat.zig");
const CancellationToken = @import("../../../../../base/common/cancellation.zig").CancellationToken;
const Position = @import("../../../../../editor/common/core/position.zig").Position;
const TextModel = @import("../../../../../editor/common/model/textModel.zig").TextModel;
const completion = @import("../../../../../editor/common/languages/completion.zig");

pub fn Tests(comptime terminal_window_type: type, comptime factory: anytype) type {
    return struct {
        const TestWindow = @import("../../../../test/browser/workbenchTestServices.zig").TestWindow(terminal_window_type, factory);
        test "Helix extension: registers a key handler and edits through the host" {
            const allocator = std.testing.allocator;
            const io = time_compat.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "helix.txt", .data = "hello\n" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const relative_len = try tmp.dir.realPathFile(io, "helix.txt", &path_buffer);
            const relative = path_buffer[0..relative_len];

            const workbench_window = try TestWindow.init(allocator, io, &.{relative}, 80, 24);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();

            var host = try BuiltinExtensionHost.init(allocator, workbench.builtinExtensionServices());
            defer host.deinit();
            try host.registerBuiltin(try helix_extension.create(allocator));
            host.activate();

            const insert = ui.KeyEvent{ .key = .{ .char = 'i' } };
            try std.testing.expect(host.dispatchKey(&insert));
            const text = ui.KeyEvent{ .key = .{ .text = "abc" } };
            try std.testing.expect(host.dispatchKey(&text));
            const escape = ui.KeyEvent{ .key = .escape };
            try std.testing.expect(host.dispatchKey(&escape));

            var value = try workbench.activeTab().?.editor.model.getValue(.LF, false);
            defer value.deinit();
            try std.testing.expectEqualStrings("abchello\n", value.items);

            const undo = ui.KeyEvent{ .key = .{ .char = 'u' } };
            try std.testing.expect(host.dispatchKey(&undo));
            var undone = try workbench.activeTab().?.editor.model.getValue(.LF, false);
            defer undone.deinit();
            try std.testing.expectEqualStrings("hello\n", undone.items);
        }

        test "Helix extension: deactivation removes its key handler" {
            const allocator = std.testing.allocator;
            const io = time_compat.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "helix.txt", .data = "hello\n" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const relative_len = try tmp.dir.realPathFile(io, "helix.txt", &path_buffer);
            const relative = path_buffer[0..relative_len];

            const workbench_window = try TestWindow.init(allocator, io, &.{relative}, 80, 24);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();

            var host = try BuiltinExtensionHost.init(allocator, workbench.builtinExtensionServices());
            defer host.deinit();
            try host.registerBuiltin(try helix_extension.create(allocator));
            host.activate();
            host.extensions.deactivateAll();

            const insert = ui.KeyEvent{ .key = .{ .char = 'i' } };
            try std.testing.expect(!host.dispatchKey(&insert));
        }

        test "Helix extension: Insert mode pairs braces, accepts completion and repeats the inserted text" {
            const allocator = std.testing.allocator;
            const io = time_compat.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "insert.zig", .data = "" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path_len = try tmp.dir.realPathFile(io, "insert.zig", &path_buffer);
            const workbench_window = try TestWindow.init(allocator, io, &.{path_buffer[0..path_len]}, 80, 24);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();
            try workbench.enableLanguageFeatures();

            const Completion = struct {
                fn provide(_: *anyopaque, _: std.mem.Allocator, _: *TextModel, _: Position, _: completion.CompletionContext, _: CancellationToken) !completion.CompletionList {
                    return .{ .items = &.{.{ .label = "alphabet", .insert_text = "alphabet" }} };
                }
            };
            const registration = try workbench.language_features.?.completion_provider.register(.{ .language = "*" }, .{
                .context = workbench,
                .provide_completion_items = Completion.provide,
            });
            defer registration.dispose();

            const host = try BuiltinExtensionHost.init(allocator, workbench.builtinExtensionServices());
            defer host.deinit();
            try host.registerBuiltin(try helix_extension.create(allocator));
            host.activate();

            const tab = workbench.activeTab().?;
            try tab.ensureControllers();
            try std.testing.expect(host.dispatchKey(&.{ .key = .{ .text = "i{" } }));
            var pair = try tab.editor.model.getLineContent(1);
            defer pair.deinit();
            try std.testing.expectEqualStrings("{}", pair.items);
            try std.testing.expectEqual(@as(usize, 2), tab.editor.modelCursorPosition().column);

            try std.testing.expect(host.dispatchKey(&.{ .key = .{ .char = 'a' } }));
            const suggest = tab.controllers.?.suggest.?;
            try std.testing.expect(suggest.model.hasPendingTrigger());
            try std.testing.expect(try suggest.onTick(time_compat.milliTimestamp() + 1000));
            try std.testing.expect(suggest.isOpen());
            try std.testing.expect(host.dispatchKey(&.{ .key = .tab }));
            try std.testing.expect(host.dispatchKey(&.{ .key = .{ .text = "}" } }));
            var inserted = try tab.editor.model.getLineContent(1);
            defer inserted.deinit();
            try std.testing.expectEqualStrings("{alphabet}", inserted.items);

            try std.testing.expect(host.dispatchKey(&.{ .key = .escape }));
            try std.testing.expect(host.dispatchKey(&.{ .key = .{ .char = 'u' } }));
            var undone = try tab.editor.model.getLineContent(1);
            defer undone.deinit();
            try std.testing.expectEqualStrings("", undone.items);

            try std.testing.expect(host.dispatchKey(&.{ .key = .{ .char = '.' } }));
            var repeated = try tab.editor.model.getLineContent(1);
            defer repeated.deinit();
            try std.testing.expectEqualStrings("{alphabet}", repeated.items);

            try std.testing.expect(host.dispatchKey(&.{ .key = .{ .char = 'u' } }));
            try std.testing.expect(host.dispatchKey(&.{ .key = .{ .text = "ia" } }));
            try std.testing.expect(host.dispatchKey(&.{ .key = .{ .char = ' ' }, .mods = .{ .ctrl = true } }));
            try std.testing.expect(suggest.isOpen());
            try std.testing.expect(host.dispatchKey(&.{ .key = .escape }));
            try std.testing.expect(!suggest.isOpen());
            try std.testing.expect(!suggest.model.hasPendingTrigger());
        }

        test "Helix extension: helix.enabled is read from user settings" {
            const allocator = std.testing.allocator;
            const io = time_compat.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "helix.txt", .data = "hello\n" });
            try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{\"helix.enabled\": true}" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const relative_len = try tmp.dir.realPathFile(io, "helix.txt", &path_buffer);
            const relative = path_buffer[0..relative_len];
            var settings_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const settings_len = try tmp.dir.realPathFile(io, "settings.json", &settings_buffer);
            const settings_path = settings_buffer[0..settings_len];

            const workbench_window = try TestWindow.init(allocator, io, &.{relative}, 80, 24);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();
            try std.testing.expect(!(workbench.configuration orelse return error.MissingConfiguration).getBool("helix.enabled", false));
            try workbench.setUserSettingsPaths(&.{settings_path});
            try std.testing.expect((workbench.configuration orelse return error.MissingConfiguration).getBool("helix.enabled", false));
        }

        test "Helix extension: read-only edits report an error and do not crash" {
            const allocator = std.testing.allocator;
            const io = time_compat.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "helix.txt", .data = "hello\n" });
            var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const relative_len = try tmp.dir.realPathFile(io, "helix.txt", &path_buffer);
            const relative = path_buffer[0..relative_len];

            const workbench_window = try TestWindow.init(allocator, io, &.{relative}, 80, 24);
            const workbench = workbench_window.workbench;
            defer workbench_window.deinit();

            var host = try BuiltinExtensionHost.init(allocator, workbench.builtinExtensionServices());
            defer host.deinit();
            try host.registerBuiltin(try helix_extension.create(allocator));
            host.activate();

            const editor = workbench.activeTab().?.editor;
            editor.setReadOnly(true);
            const delete = ui.KeyEvent{ .key = .{ .char = 'd' } };
            try std.testing.expect(!host.dispatchKey(&delete));
            try std.testing.expect(std.mem.startsWith(u8, editor.message(), "Helix:"));

            var value = try editor.model.getValue(.LF, false);
            defer value.deinit();
            try std.testing.expectEqualStrings("hello\n", value.items);
        }
    };
}
