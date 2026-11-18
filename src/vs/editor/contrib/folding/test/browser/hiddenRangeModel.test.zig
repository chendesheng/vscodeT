// Port of `src/vs/editor/contrib/folding/test/browser/hiddenRangeModel.test.ts`.
const std = @import("std");
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const indent = @import("../../browser/indentRangeProvider.zig");
const FoldingModel = @import("../../browser/foldingModel.zig").FoldingModel;
const HiddenRangeModel = @import("../../browser/hiddenRangeModel.zig").HiddenRangeModel;

test "hiddenRangeModel: computes collapsed ranges" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "class A {\n  void f() {\n    x();\n  }\n}", "nullLanguage");
    defer ctx.deinit();
    var reporter = indent.FoldingLimitReporter{ .limit = 1000 };
    const ranges = try indent.computeRanges(allocator, ctx.model, false, null, &reporter);
    var folding_model = FoldingModel.init(allocator, ctx.model);
    defer folding_model.deinit();
    try folding_model.update(ranges);
    var hidden = HiddenRangeModel.init(allocator, &folding_model);
    defer hidden.deinit();
    hidden.listen();

    try std.testing.expect(!hidden.hasRanges());
    folding_model.toggleCollapseState(&[_]usize{0});
    try std.testing.expect(hidden.hasRanges());
    try std.testing.expect(!hidden.isHidden(1));
    try std.testing.expect(hidden.isHidden(2));
}
