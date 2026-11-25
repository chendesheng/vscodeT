// Port of the explicitly invoked completion path of
// src/vs/workbench/contrib/terminalContrib/suggest/browser/terminalCompletionService.ts.
// The provider completes on the terminal event loop. Reply items are borrowed
// for the duration of the callback. cancel drops any outstanding reply.
const TerminalInstance = @import("../../../terminal/browser/terminalInstance.zig").TerminalInstance;

pub const Completion = struct {
    label: []const u8,
    replacement_range: [2]usize,
};

pub const Results = struct {
    context: *anyopaque,
    accept: *const fn (*anyopaque, []const Completion) void,
};

pub const ITerminalCompletionService = struct {
    context: *anyopaque,
    provide: *const fn (*anyopaque, *TerminalInstance, []const u8, usize, Results) anyerror!void,
    cancel_fn: *const fn (*anyopaque) void,

    pub fn provideCompletions(self: ITerminalCompletionService, terminal: *TerminalInstance, line: []const u8, cursor_index: usize, results: Results) !void {
        try self.provide(self.context, terminal, line, cursor_index, results);
    }

    pub fn cancel(self: ITerminalCompletionService) void {
        self.cancel_fn(self.context);
    }
};
