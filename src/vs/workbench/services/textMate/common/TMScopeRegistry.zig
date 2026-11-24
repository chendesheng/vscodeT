// Port of src/vs/workbench/services/textMate/common/TMScopeRegistry.ts.
// The installed catalog owns these immutable definitions. Both TextMate
// registries resolve includes by scope even when a grammar has no language.
const std = @import("std");

pub const Grammar = struct {
    root: []const u8,
    language: []const u8,
    scope: []const u8,
    path: []const u8,
    location: []const u8,
    inject_to: []const []const u8,
    injections: []const []const u8 = &.{},
};

pub fn forScope(grammars: []const Grammar, scope: []const u8) ?Grammar {
    var it = std.mem.reverseIterator(grammars);
    while (it.next()) |grammar| {
        if (std.mem.eql(u8, grammar.scope, scope)) return grammar;
    }
    return null;
}

/// TMGrammarFactory collects injections for each successive dot-separated
/// prefix of the target scope, retaining declaration order within each prefix.
pub fn resolveInjections(allocator: std.mem.Allocator, grammars: []Grammar) !void {
    for (grammars) |*target| {
        var scopes = std.ArrayList([]const u8).empty;
        var start: usize = 0;
        while (true) {
            const end = std.mem.indexOfScalarPos(u8, target.scope, start, '.') orelse target.scope.len;
            const prefix = target.scope[0..end];
            for (grammars) |grammar| {
                for (grammar.inject_to) |inject_to| {
                    if (std.mem.eql(u8, prefix, inject_to)) try scopes.append(allocator, grammar.scope);
                }
            }
            if (end == target.scope.len) break;
            start = end + 1;
        }
        target.injections = try scopes.toOwnedSlice(allocator);
    }
}
