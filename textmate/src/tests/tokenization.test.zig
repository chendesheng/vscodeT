// Port of `vscode-textmate/src/tests/tokenization.test.ts`
// (microsoft/vscode-textmate v9.3.2).
const std = @import("std");
const main = @import("../main.zig");
const rawGrammar = @import("../rawGrammar.zig");
const onigLib = @import("../onigLib.zig");
const diff = @import("../diffStateStacks.zig");
const testPaths = @import("testPaths.zig");
const Allocator = std.mem.Allocator;

const Loader = struct {
    grammars: *std.StringHashMap(*rawGrammar.RawGrammar),
    injections: ?[]const []const u8,
    initial_scope: []const u8,

    fn load(context: *anyopaque, scope_name: []const u8) anyerror!?*rawGrammar.RawGrammar {
        const self: *Loader = @ptrCast(@alignCast(context));
        return self.grammars.get(scope_name);
    }

    fn getInjections(context: *anyopaque, scope_name: []const u8) ?[]const []const u8 {
        const self: *Loader = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, scope_name, self.initial_scope)) return self.injections;
        return null;
    }
};

fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
}

fn assertTokenizationSuite(test_location: []const u8) !void {
    const allocator = std.testing.allocator;
    const content = try readFile(allocator, test_location);
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const tests = parsed.value.array.items;
    const suite_directory = std.fs.path.dirname(test_location) orelse ".";

    for (tests) |test_value| {
        const test_object = test_value.object;
        const desc = test_object.get("desc").?.string;
        const grammar_paths = test_object.get("grammars").?.array.items;
        const lines = test_object.get("lines").?.array.items;

        var grammars = std.StringHashMap(*rawGrammar.RawGrammar).init(allocator);
        var grammar_keys: std.ArrayList([]u8) = .empty;
        defer {
            var iterator = grammars.valueIterator();
            while (iterator.next()) |value| {
                value.*.deinit();
                allocator.destroy(value.*);
            }
            for (grammar_keys.items) |key| allocator.free(key);
            grammar_keys.deinit(allocator);
            grammars.deinit();
        }

        var grammar_scope_name: ?[]const u8 = null;
        const grammar_path_value: ?[]const u8 = if (test_object.get("grammarPath")) |value| value.string else null;
        const explicit_scope: ?[]const u8 = if (test_object.get("grammarScopeName")) |value| value.string else null;
        const injections: ?[]const []const u8 = if (test_object.get("grammarInjections")) |value| blk: {
            const items = value.array.items;
            const result = try allocator.alloc([]const u8, items.len);
            for (items, 0..) |item, i| result[i] = item.string;
            break :blk result;
        } else null;
        defer if (injections) |values| allocator.free(values);

        for (grammar_paths) |path_value| {
            const relative_path = path_value.string;
            const full_path = try std.fs.path.join(allocator, &.{ suite_directory, relative_path });
            defer allocator.free(full_path);
            const grammar_content = try readFile(allocator, full_path);
            defer allocator.free(grammar_content);

            const raw = try allocator.create(rawGrammar.RawGrammar);
            errdefer allocator.destroy(raw);
            raw.* = try @import("../parseRawGrammar.zig").parseRawGrammar(allocator, grammar_content, relative_path);
            errdefer raw.deinit();

            const scope_name = raw.scopeName();
            const owned_scope = try allocator.dupe(u8, scope_name);
            errdefer allocator.free(owned_scope);
            const gop = try grammars.getOrPut(owned_scope);
            if (gop.found_existing) {
                allocator.free(owned_scope);
                gop.value_ptr.*.deinit();
                allocator.destroy(gop.value_ptr.*);
            } else {
                try grammar_keys.append(allocator, owned_scope);
            }
            gop.value_ptr.* = raw;
            if (explicit_scope == null and grammar_scope_name == null and grammar_path_value != null and
                std.mem.eql(u8, relative_path, grammar_path_value.?))
            {
                grammar_scope_name = gop.key_ptr.*;
            }
        }

        if (explicit_scope) |scope| grammar_scope_name = scope;
        const initial_scope = grammar_scope_name orelse {
            std.debug.print("tokenization test has no grammar: {s}\n", .{desc});
            return error.TestUnexpectedResult;
        };
        const owned_initial_scope = try allocator.dupe(u8, initial_scope);
        defer allocator.free(owned_initial_scope);

        var loader = Loader{
            .grammars = &grammars,
            .injections = injections,
            .initial_scope = owned_initial_scope,
        };

        var onig_lib = onigLib.OnigLib.init(allocator);
        const registry = try main.Registry.init(allocator, .{
            .onig_lib = onig_lib.interface(),
            .context = &loader,
            .load_grammar = Loader.load,
            .get_injections = Loader.getInjections,
        });
        defer registry.dispose();

        const grammar = (try registry.loadGrammar(owned_initial_scope)) orelse {
            std.debug.print("could not load grammar for {s}\n", .{desc});
            return error.TestUnexpectedResult;
        };

        var prev_state: ?*main.StateStack = null;
        for (lines) |line_value| {
            const line_object = line_value.object;
            const line = line_object.get("line").?.string;
            const expected = line_object.get("tokens").?.array.items;

            const result = grammar.tokenizeLine(line, prev_state, 0) catch |err| {
                std.debug.print("tokenization failed for {s}: {s}: {s}\n", .{ desc, line, @errorName(err) });
                return err;
            };

            const line_string = try onigLib.OnigString.init(allocator, line);
            defer line_string.deinit();

            var actual_count: usize = 0;
            var expected_index: usize = 0;
            for (result.tokens) |token| {
                const value = line_string.sliceUtf16(token.start_index, token.end_index);
                if (line_string.utf16_len > 0 and value.len == 0) continue;

                while (expected_index < expected.len) {
                    const possible = expected[expected_index].object;
                    if (line_string.utf16_len > 0 and possible.get("value").?.string.len == 0) {
                        expected_index += 1;
                        continue;
                    }
                    break;
                }

                if (expected_index >= expected.len) {
                    std.debug.print("too many tokens for {s}: line '{s}' token '{s}'\n", .{ desc, line, value });
                    return error.TestUnexpectedResult;
                }
                const expected_token = expected[expected_index].object;
                const expected_value = expected_token.get("value").?.string;
                try std.testing.expectEqualStrings(expected_value, value);
                const expected_scopes = expected_token.get("scopes").?.array.items;
                if (expected_scopes.len != token.scopes.len) {
                    std.debug.print("scope count mismatch for {s}: line '{s}' token '{s}' expected {} actual {}\n", .{
                        desc, line, value, expected_scopes.len, token.scopes.len,
                    });
                    std.debug.print("expected scopes: ", .{});
                    for (expected_scopes) |scope| std.debug.print("'{s}' ", .{scope.string});
                    std.debug.print("\nactual scopes: ", .{});
                    for (token.scopes) |scope| std.debug.print("'{s}' ", .{scope});
                    std.debug.print("\n", .{});
                }
                try std.testing.expectEqual(expected_scopes.len, token.scopes.len);
                for (expected_scopes, token.scopes) |expected_scope, actual_scope| {
                    try std.testing.expectEqualStrings(expected_scope.string, actual_scope);
                }
                actual_count += 1;
                expected_index += 1;
            }

            while (expected_index < expected.len) {
                const possible = expected[expected_index].object;
                if (line_string.utf16_len > 0 and possible.get("value").?.string.len == 0) {
                    expected_index += 1;
                    continue;
                }
                break;
            }

            if (actual_count == 0 or expected_index != expected.len) {
                std.debug.print("token count mismatch for {s}: line '{s}' expected {} got {}\n", .{ desc, line, expected.len, actual_count });
                return error.TestUnexpectedResult;
            }

            if (prev_state) |previous| {
                var stack_diff = try diff.diffStateStacksRefEq(allocator, previous, result.rule_stack);
                defer stack_diff.deinit(allocator);
                prev_state = try diff.applyStateStackDiff(grammar.arena.allocator(), previous, stack_diff);
            } else {
                prev_state = result.rule_stack;
            }
        }
    }
}

test "tokenization: first-mate" {
    const allocator = std.testing.allocator;
    const test_cases = try testPaths.findTestCasesDir(allocator);
    defer allocator.free(test_cases);
    const path = try std.fs.path.join(allocator, &.{ test_cases, "first-mate/tests.json" });
    defer allocator.free(path);
    try assertTokenizationSuite(path);
}

test "tokenization: suite1" {
    const allocator = std.testing.allocator;
    const test_cases = try testPaths.findTestCasesDir(allocator);
    defer allocator.free(test_cases);
    const path = try std.fs.path.join(allocator, &.{ test_cases, "suite1/tests.json" });
    defer allocator.free(path);
    try assertTokenizationSuite(path);
}

test "tokenization: suite1 whileTests" {
    const allocator = std.testing.allocator;
    const test_cases = try testPaths.findTestCasesDir(allocator);
    defer allocator.free(test_cases);
    const path = try std.fs.path.join(allocator, &.{ test_cases, "suite1/whileTests.json" });
    defer allocator.free(path);
    try assertTokenizationSuite(path);
}
