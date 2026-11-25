const std = @import("std");

const shell = "src/vs/workbench/browser/workbench.zig";
const line_budget = 14056;
const exceptions = @embedFile("workbench-imports.txt");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var allowed: std.StringHashMapUnmanaged(bool) = .empty;
    defer allowed.deinit(allocator);
    var lines = std.mem.tokenizeAny(u8, exceptions, "\r\n");
    while (lines.next()) |edge| try allowed.put(allocator, edge, false);

    var ok = true;
    var saw_shell = false;
    var root = try std.Io.Dir.cwd().openDir(init.io, ".", .{ .iterate = true });
    defer root.close(init.io);
    var walker = try root.walkSelectively(allocator);
    defer walker.deinit();
    while (try walker.next(init.io)) |entry| {
        if (entry.kind == .directory) {
            if (entry.basename[0] == '.') continue;
            for ([_][]const u8{ "vscode", "vscode-textmate", "third_party", "node_modules", "zig-out", "zig-pkg" }) |skip| {
                if (std.mem.eql(u8, entry.basename, skip)) break;
            } else try walker.enter(init.io, entry);
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temp = arena.allocator();
        const source = try entry.dir.readFileAllocOptions(init.io, entry.basename, temp, .unlimited, .of(u8), 0);
        const path = try temp.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');
        if (std.mem.eql(u8, path, shell)) {
            saw_shell = true;
            const count = std.mem.countScalar(u8, source, '\n') + @intFromBool(source.len > 0 and source[source.len - 1] != '\n');
            if (count > line_budget) {
                std.log.err("{s} has {d} lines, budget {d}", .{ path, count, line_budget });
                ok = false;
            }
        }

        var tokens = std.zig.Tokenizer.init(source);
        while (true) {
            const token = tokens.next();
            if (token.tag == .eof) break;
            if (token.tag != .builtin or !std.mem.eql(u8, source[token.loc.start..token.loc.end], "@import")) continue;
            if (tokens.next().tag != .l_paren) continue;
            const name = tokens.next();
            if (name.tag != .string_literal) continue;
            const imported = try std.zig.string_literal.parseAlloc(temp, source[name.loc.start..name.loc.end]);
            if (!std.mem.endsWith(u8, imported, ".zig")) continue;
            std.mem.replaceScalar(u8, imported, '\\', '/');
            const target = try std.fs.path.resolveAllocPosix(temp, &.{ std.fs.path.dirnamePosix(path) orelse ".", imported });
            if (!std.mem.eql(u8, target, shell) and
                !(std.mem.startsWith(u8, path, "src/vs/") and std.mem.startsWith(u8, target, "src/tui/"))) continue;
            const edge = try std.fmt.allocPrint(temp, "{s} -> {s}", .{ path, target });
            if (allowed.getPtr(edge)) |found| {
                found.* = true;
            } else {
                std.log.err("unexpected import: {s}", .{edge});
                ok = false;
            }
        }
    }
    var it = allowed.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*) continue;
        std.log.err("remove obsolete exception: {s}", .{entry.key_ptr.*});
        ok = false;
    }
    if (!ok or !saw_shell) return error.WorkbenchBoundary;
}
