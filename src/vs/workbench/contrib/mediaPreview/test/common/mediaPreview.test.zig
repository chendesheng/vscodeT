// Tests for the portable parts of
// `src/vs/workbench/contrib/mediaPreview/common/mediaPreview.ts`.

const std = @import("std");
const media_preview = @import("../../common/mediaPreview.zig");
const isImagePath = media_preview.isImagePath;
const isSvgPath = media_preview.isSvgPath;
const opensInImagePreview = media_preview.opensInImagePreview;
const extension = media_preview.extension;
const isGitLfsPointer = media_preview.isGitLfsPointer;
const git_lfs_pointer_max_size = media_preview.git_lfs_pointer_max_size;

test "mediaPreview: image pattern is case insensitive and excludes SVG preview" {
    try std.testing.expect(isImagePath("photo.PNG"));
    try std.testing.expect(isImagePath("/tmp/a.jpeg"));
    try std.testing.expect(isImagePath("icon.svg"));
    try std.testing.expect(!isImagePath("notes.md"));
    try std.testing.expect(!isImagePath("png"));
    try std.testing.expect(opensInImagePreview("photo.png"));
    try std.testing.expect(!opensInImagePreview("icon.svg"));
    try std.testing.expectEqualStrings("PNG", extension("photo.PNG"));
}

test "mediaPreview: LFS pointer detection matches the upstream prefix" {
    const pointer = "version https://git-lfs.github.com/spec/v1\n" ++
        "oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393\n" ++
        "size 12345\n";
    try std.testing.expect(isGitLfsPointer(pointer));
    try std.testing.expect(!isGitLfsPointer("not a pointer"));
    const prefix = "version https://git-lfs.github.com/spec/v1";
    const huge = try std.testing.allocator.alloc(u8, prefix.len + git_lfs_pointer_max_size);
    defer std.testing.allocator.free(huge);
    @memcpy(huge[0..prefix.len], prefix);
    @memset(huge[prefix.len..], 'x');
    try std.testing.expect(!isGitLfsPointer(huge));
}
