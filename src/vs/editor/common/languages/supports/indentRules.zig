const IndentationRule = @import("../languageConfiguration.zig").IndentationRule;
const RegExp = @import("../../../../../support/regexp.zig").RegExp;

const IndentMetadata = packed struct(u8) {
    increase: bool,
    decrease: bool,
    indentNextLine: bool,
    unindent: bool,
};

pub const IndentRulesSupport = struct {
    _indentationRules: ?IndentationRule,

    pub fn init(indentationRules: IndentationRule) IndentRulesSupport {
        return IndentRulesSupport{
            ._indentationRules = indentationRules,
        };
    }

    pub fn shouldIncrease(self: *IndentRulesSupport, text: []const u8) bool {
        if (self._indentationRules) |rules| {
            if (rules.increaseIndentPattern) |pattern| {
                if (pattern.isMatch(text)) {
                    return true;
                }
            }
            // if (this._indentationRules.indentNextLinePattern && this._indentationRules.indentNextLinePattern.test(text)) {
            //    return true;
            // }
        }
        return false;
    }

    pub fn shouldDecrease(self: *IndentRulesSupport, text: []const u8) bool {
        if (self._indentationRules) |rules| {
            if (rules.decreaseIndentPattern) |pattern| {
                if (pattern.isMatch(text)) {
                    return true;
                }
            }
        }
        return false;
    }

    pub fn shouldIndentNextLine(self: *IndentRulesSupport, text: []const u8) bool {
        if (self._indentationRules) |rules| {
            if (rules.indentNextLinePattern) |pattern| {
                if (pattern.isMatch(text)) {
                    return true;
                }
            }
        }

        return false;
    }

    pub fn shouldIgnore(self: *IndentRulesSupport, text: []const u8) bool {
        // the text matches `unIndentedLinePattern`
        if (self._indentationRules) |rules| {
            if (rules.unIndentedLinePattern) |pattern| {
                if (pattern.isMatch(text)) {
                    return true;
                }
            }
        }

        return false;
    }

    pub fn getIndentMetadata(self: *IndentRulesSupport, text: []const u8) IndentMetadata {
        var ret: IndentMetadata = @bitCast(0);
        if (self.shouldIncrease(text)) {
            ret.increase = true;
        }
        if (self.shouldDecrease(text)) {
            ret.decrease = true;
        }
        if (self.shouldIndentNextLine(text)) {
            ret.indentNextLine = true;
        }
        if (self.shouldIgnore(text)) {
            ret.unindent = true;
        }
        return ret;
    }
};
