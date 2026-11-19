// Port of `src/vs/editor/common/languageFeatureRegistry.ts`.
//
// Terminal adaptations:
// - selectors are compiled into a per-entry arena at registration time;
// - result arrays are allocated with the caller's allocator;
// - registration disposables carry an explicit token instead of a JS closure.
//
// The scoring/ordering/exclusivity rules are the upstream rules: score
// descending, non-builtin before builtin, newer registration first, and the
// first matching exclusive selector taking over non-recursive queries.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lifecycle = @import("../../base/common/lifecycle.zig");
const IDisposable = lifecycle.IDisposable;
const Emitter = @import("../../base/common/event.zig").Emitter;
const TextModel = @import("model/textModel.zig").TextModel;
const std_uri = @import("../../base/common/stdUri.zig");
const selector_mod = @import("languageSelector.zig");

pub fn LanguageFeatureRegistry(comptime T: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            arena: std.heap.ArenaAllocator,
            selector: selector_mod.CompiledSelector,
            provider: T,
            score: i32 = -1,
            time: u64,
        };

        const Registration = struct {
            registry: *Self,
            entry: *Entry,
            active: bool = true,
        };

        allocator: Allocator,
        entries: std.array_list.Managed(*Entry),
        registrations: std.array_list.Managed(*Registration),
        clock: u64 = 0,
        on_did_change: Emitter(usize),
        last_key: ?[]u8 = null,
        last_language: ?[]u8 = null,
        last_recursive: bool = false,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .entries = std.array_list.Managed(*Entry).init(allocator),
                .registrations = std.array_list.Managed(*Registration).init(allocator),
                .on_did_change = Emitter(usize).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.entries.items) |entry| {
                entry.arena.deinit();
                self.allocator.destroy(entry);
            }
            self.entries.deinit();
            for (self.registrations.items) |registration| self.allocator.destroy(registration);
            self.registrations.deinit();
            if (self.last_key) |key| self.allocator.free(key);
            if (self.last_language) |language| self.allocator.free(language);
            self.on_did_change.deinit();
        }

        pub fn register(self: *Self, selector: selector_mod.Selector, provider: T) !IDisposable {
            const entry = try self.allocator.create(Entry);
            errdefer self.allocator.destroy(entry);
            entry.arena = std.heap.ArenaAllocator.init(self.allocator);
            errdefer entry.arena.deinit();
            entry.selector = try selector_mod.compileSelector(entry.arena.allocator(), selector);
            entry.provider = provider;
            entry.time = self.clock;
            self.clock += 1;
            try self.entries.append(entry);
            self.invalidateCandidate();

            const registration = try self.allocator.create(Registration);
            errdefer self.allocator.destroy(registration);
            registration.* = .{ .registry = self, .entry = entry };
            try self.registrations.append(registration);
            self.on_did_change.fire(self.entries.items.len) catch {};
            return .{ .context = registration, .disposeFn = disposeRegistration };
        }

        fn disposeRegistration(context: *anyopaque) void {
            const registration: *Registration = @ptrCast(@alignCast(context));
            const registry = registration.registry;
            if (registration.active) {
                registration.active = false;
                registry.removeEntry(registration.entry);
            }
        }

        fn removeEntry(self: *Self, target: *Entry) void {
            if (std.mem.indexOfScalar(*Entry, self.entries.items, target)) |index| {
                _ = self.entries.orderedRemove(index);
                target.arena.deinit();
                self.allocator.destroy(target);
                self.invalidateCandidate();
                self.on_did_change.fire(self.entries.items.len) catch {};
            }
        }

        fn invalidateCandidate(self: *Self) void {
            if (self.last_key) |key| {
                self.allocator.free(key);
                self.last_key = null;
            }
            if (self.last_language) |language| {
                self.allocator.free(language);
                self.last_language = null;
            }
        }

        fn shouldSynchronizeModel(model: *const TextModel) bool {
            return model.shouldSynchronizeModel();
        }

        fn updateScores(self: *Self, model: *TextModel, recursive: bool) !void {
            const key = try std_uri.resourceKey(self.allocator, model.uri());
            defer self.allocator.free(key);
            const language = model.getLanguageId();

            if (self.last_key) |last_key| {
                if (self.last_language) |last_language| {
                    if (self.last_recursive == recursive and
                        std.mem.eql(u8, last_key, key) and
                        std.mem.eql(u8, last_language, language))
                    {
                        return;
                    }
                }
            }

            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            const candidate = try selector_mod.candidateFromUri(
                scratch.allocator(),
                model.uri(),
                language,
                shouldSynchronizeModel(model),
            );

            for (self.entries.items) |entry| {
                entry.score = selector_mod.scoreCompiled(entry.selector, candidate);
                if (selector_mod.isExclusive(entry.selector) and entry.score > 0) {
                    if (recursive) {
                        entry.score = 0;
                    } else {
                        for (self.entries.items) |other| other.score = 0;
                        entry.score = 1000;
                        break;
                    }
                }
            }

            std.mem.sort(*Entry, self.entries.items, {}, struct {
                fn lessThan(_: void, a: *Entry, b: *Entry) bool {
                    if (a.score != b.score) return a.score > b.score;
                    const a_builtin = selector_mod.isBuiltin(a.selector);
                    const b_builtin = selector_mod.isBuiltin(b.selector);
                    if (a_builtin != b_builtin) return !a_builtin;
                    return a.time > b.time;
                }
            }.lessThan);

            self.invalidateCandidate();
            self.last_key = try self.allocator.dupe(u8, key);
            self.last_language = try self.allocator.dupe(u8, language);
            self.last_recursive = recursive;
        }

        pub fn has(self: *Self, model: *TextModel) bool {
            self.updateScores(model, false) catch return false;
            for (self.entries.items) |entry| {
                if (entry.score > 0) return true;
            }
            return false;
        }

        pub fn all(self: *Self, allocator: Allocator, model: *TextModel) ![]T {
            return self.collect(allocator, model, false);
        }

        pub fn ordered(self: *Self, allocator: Allocator, model: *TextModel, recursive: bool) ![]T {
            return self.collect(allocator, model, recursive);
        }

        fn collect(self: *Self, allocator: Allocator, model: *TextModel, recursive: bool) ![]T {
            try self.updateScores(model, recursive);
            var result = std.array_list.Managed(T).init(allocator);
            errdefer result.deinit();
            for (self.entries.items) |entry| {
                if (entry.score > 0) try result.append(entry.provider);
            }
            return try result.toOwnedSlice();
        }

        pub fn allNoModel(self: *const Self, allocator: Allocator) ![]T {
            const result = try allocator.alloc(T, self.entries.items.len);
            for (self.entries.items, 0..) |entry, index| result[index] = entry.provider;
            return result;
        }

        pub fn orderedGroups(self: *Self, allocator: Allocator, model: *TextModel) ![][]T {
            try self.updateScores(model, false);
            var groups = std.array_list.Managed([]T).init(allocator);
            errdefer {
                for (groups.items) |group| allocator.free(group);
                groups.deinit();
            }
            var current = std.array_list.Managed(T).init(allocator);
            defer current.deinit();
            var last_score: ?i32 = null;
            for (self.entries.items) |entry| {
                if (entry.score <= 0) continue;
                if (last_score != null and last_score.? != entry.score) {
                    try groups.append(try current.toOwnedSlice());
                    current = std.array_list.Managed(T).init(allocator);
                }
                last_score = entry.score;
                try current.append(entry.provider);
            }
            if (current.items.len > 0) try groups.append(try current.toOwnedSlice());
            return try groups.toOwnedSlice();
        }

        pub fn registeredLanguageIds(self: *const Self, allocator: Allocator) !std.StringHashMap(void) {
            var result = std.StringHashMap(void).init(allocator);
            errdefer result.deinit();
            for (self.entries.items) |entry| {
                try selector_mod.selectLanguageIds(entry.selector, &result);
            }
            return result;
        }
    };
}
