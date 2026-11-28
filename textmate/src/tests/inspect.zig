// Port of `vscode-textmate/src/tests/inspect.ts`
// (microsoft/vscode-textmate v9.3.2).
//
// Usage:
//   zig build inspect -- <mainGrammarPath> [<additionalGrammarPath> ...] <filePath>
//
// Prints the live rule stack after every line, including each state's rule
// debug name, rule id and stack-instance id.
const std = @import("std");
const vscode_textmate = @import("vscode_textmate");
const textmate_main = vscode_textmate.main;
const parseRawGrammar = vscode_textmate.parseRawGrammar;
const rawGrammar = vscode_textmate.rawGrammar;
const onigLib = vscode_textmate.onigLib;
const debug = vscode_textmate.debug;
const grammar_module = vscode_textmate.grammar;
const Allocator = std.mem.Allocator;

fn noLoad(_: *anyopaque, _: std.Io, _: []const u8) anyerror!?*rawGrammar.RawGrammar {
    return null;
}

fn readFile(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
}

fn splitLines(allocator: Allocator, content: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var start: usize = 0;
    var index: usize = 0;
    while (index < content.len) {
        if (content[index] == '\r' or content[index] == '\n') {
            try lines.append(allocator, content[start..index]);
            if (content[index] == '\r' and index + 1 < content.len and content[index + 1] == '\n') index += 1;
            index += 1;
            start = index;
        } else {
            index += 1;
        }
    }
    try lines.append(allocator, content[start..]);
    return lines.toOwnedSlice(allocator);
}

fn joinScopes(allocator: Allocator, scopes_list: ?*const grammar_module.AttributedScopeStack) ![]u8 {
    const scopes = if (scopes_list) |list| list.getScopeNames() else &.{};
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (scopes, 0..) |scope, index| {
        if (index != 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, scope);
    }
    return out.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var args_iterator = try init.minimal.args.iterateAllocator(allocator);
    defer args_iterator.deinit();
    _ = args_iterator.next(); // program name

    var grammar_paths: std.ArrayList([]const u8) = .empty;
    var file_path: ?[]const u8 = null;
    while (args_iterator.next()) |arg| {
        const value = try allocator.dupe(u8, arg);
        if (file_path) |previous| {
            try grammar_paths.append(allocator, previous);
        }
        file_path = value;
    }
    if (file_path == null or grammar_paths.items.len == 0) {
        std.debug.print(
            "usage: zig build inspect -- <mainGrammarPath> [<additionalGrammarPath> ...] <filePath>\n",
            .{},
        );
        return;
    }

    debug.DebugFlags.in_debug_mode = true;

    var out_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var onig_lib = onigLib.OnigLib.init(allocator);
    const registry = try textmate_main.Registry.init(allocator, .{
        .onig_lib = onig_lib.interface(),
        .load_grammar = noLoad,
    });
    defer registry.dispose();

    var raw_grammars: std.ArrayList(*rawGrammar.RawGrammar) = .empty;
    defer {
        for (raw_grammars.items) |raw| {
            raw.deinit();
            allocator.destroy(raw);
        }
        raw_grammars.deinit(allocator);
    }

    var first_grammar: ?*textmate_main.IGrammar = null;
    for (grammar_paths.items) |grammar_path| {
        try out.print("LOADING GRAMMAR: {s}\n", .{grammar_path});
        const content = try readFile(allocator, io, grammar_path);
        const raw = try allocator.create(rawGrammar.RawGrammar);
        errdefer allocator.destroy(raw);
        raw.* = try parseRawGrammar.parseRawGrammar(allocator, content, grammar_path);
        try raw_grammars.append(allocator, raw);
        const loaded = try registry.addGrammar(raw, null, 0, &.{});
        if (first_grammar == null) first_grammar = loaded;
    }

    const grammar = first_grammar orelse {
        std.debug.print("no grammar loaded\n", .{});
        return;
    };
    const content = try readFile(allocator, io, file_path.?);
    const lines = try splitLines(allocator, content);

    var rule_stack: ?*textmate_main.StateStack = null;
    var instance_ids = std.AutoHashMap(*textmate_main.StateStack, u32).init(allocator);
    defer instance_ids.deinit();
    var last_instance_id: u32 = 0;

    for (lines, 0..) |line, line_index| {
        try out.print("\n\n===========================================\n", .{});
        try out.print("TOKENIZING LINE {d}: |{s}|\n\n", .{ line_index + 1, line });

        const result = try grammar.tokenizeLine(io, line, rule_stack, 0);
        rule_stack = result.rule_stack;

        var depth: usize = 0;
        var node: ?*textmate_main.StateStack = result.rule_stack;
        while (node) |current| : (node = current.parent) depth += 1;
        try out.print("@@LINE END RULE STACK CONTAINS {d} RULES:\n", .{depth});

        var stack_nodes: std.ArrayList(*textmate_main.StateStack) = .empty;
        defer stack_nodes.deinit(allocator);
        node = result.rule_stack;
        while (node) |current| : (node = current.parent) try stack_nodes.append(allocator, current);
        std.mem.reverse(*textmate_main.StateStack, stack_nodes.items);

        for (stack_nodes.items) |stack_node| {
            const instance_id = if (instance_ids.get(stack_node)) |existing|
                existing
            else blk: {
                last_instance_id += 1;
                try instance_ids.put(stack_node, last_instance_id);
                break :blk last_instance_id;
            };

            if (stack_node.getRuleMaybe(grammar)) |rule_value| {
                const debug_name = try rule_value.debugName(allocator);
                const name_scopes = try joinScopes(allocator, stack_node.name_scopes_list);
                const content_scopes = try joinScopes(allocator, stack_node.content_name_scopes_list);
                try out.print(
                    "  * {s}  -- [{d},{d}] \"{s}\", \"{s}\"\n",
                    .{ debug_name, rule_value.id(), instance_id, name_scopes, content_scopes },
                );
            } else {
                try out.print("  * no rule description found\n", .{});
            }
        }
    }
}
