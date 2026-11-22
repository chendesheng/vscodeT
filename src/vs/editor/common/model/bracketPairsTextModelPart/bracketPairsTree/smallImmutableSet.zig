// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/smallImmutableSet.ts`.
//
// The port's inline set covers ids 0..255 and reports overflow as
// `BracketSetOverflow`; upstream spills into `additionalItems`.

const std = @import("std");

/// A small immutable set used for dense opening-bracket ids.
pub const SmallImmutableSet = struct {
    words: [4]u64 = .{ 0, 0, 0, 0 },

    pub fn empty() SmallImmutableSet {
        return .{};
    }

    /// The inline set covers ids 0..255. Upstream spills into a dynamically
    /// sized array; the port reports the (extremely rare) overflow as an error
    /// instead of silently dropping the id.
    pub fn add(self: SmallImmutableSet, id: usize) !SmallImmutableSet {
        var result = self;
        const word = id / 64;
        if (word >= result.words.len) return error.BracketSetOverflow;
        result.words[word] |= @as(u64, 1) << @intCast(id % 64);
        return result;
    }

    pub fn addAll(self: SmallImmutableSet, other: SmallImmutableSet) SmallImmutableSet {
        var result = self;
        for (&result.words, other.words) |*a, b| a.* |= b;
        return result;
    }

    pub fn has(self: SmallImmutableSet, id: usize) bool {
        const word = id / 64;
        if (word >= self.words.len) return false;
        return (self.words[word] & (@as(u64, 1) << @intCast(id % 64))) != 0;
    }

    pub fn intersects(self: SmallImmutableSet, other: SmallImmutableSet) bool {
        for (self.words, other.words) |a, b| if ((a & b) != 0) return true;
        return false;
    }

    pub fn merge(self: SmallImmutableSet, other: SmallImmutableSet) SmallImmutableSet {
        return self.addAll(other);
    }

    pub fn isEmpty(self: SmallImmutableSet) bool {
        for (self.words) |word| if (word != 0) return false;
        return true;
    }

    pub fn eql(self: SmallImmutableSet, other: SmallImmutableSet) bool {
        return std.mem.eql(u64, &self.words, &other.words);
    }

    pub fn first(self: SmallImmutableSet) ?usize {
        for (self.words, 0..) |word, i| {
            if (word != 0) return i * 64 + @ctz(word);
        }
        return null;
    }
};
