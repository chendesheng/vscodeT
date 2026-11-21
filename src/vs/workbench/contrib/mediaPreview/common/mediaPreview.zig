// Port of `src/vs/workbench/contrib/mediaPreview/common/mediaPreview.ts`.
//
// The terminal adaptation keeps the editor/input ids and the image file
// pattern. Resources are canonical local paths instead of `URI`s, and the Git
// LFS check works on the file contents because the TUI has no file-scheme
// service to branch on. Audio/video previews and their file patterns are not
// ported: the terminal has no media decoder or playback surface.

const std = @import("std");

/// Upstream `IMAGE_PREVIEW_EDITOR_ID`.
pub const IMAGE_PREVIEW_EDITOR_ID = "imagePreview.previewEditor";

/// Upstream `IMAGE_PREVIEW_FILE_PATTERN`.
pub const IMAGE_PREVIEW_FILE_PATTERN = "*.{jpg,jpe,jpeg,png,bmp,gif,ico,webp,avif,svg}";

const git_lfs_pointer_prefix = "version https://git-lfs.github.com/spec/v1";
pub const git_lfs_pointer_max_size: usize = 1024;

const image_extensions = [_][]const u8{
    "jpg", "jpe", "jpeg", "png", "bmp", "gif", "ico", "webp", "avif", "svg",
};

/// Returns the lower-cased extension without the dot, or an empty slice.
pub fn extension(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    if (dot + 1 >= base.len) return "";
    return base[dot + 1 ..];
}

fn extensionMatches(path: []const u8, candidates: []const []const u8) bool {
    const ext = extension(path);
    for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

/// True for every extension upstream's image preview pattern matches.
pub fn isImagePath(path: []const u8) bool {
    return extensionMatches(path, &image_extensions);
}

/// SVG is a text format and the terminal has no SVG rasterizer, so it is opened
/// in the text editor rather than in the image pane.
pub fn isSvgPath(path: []const u8) bool {
    return extensionMatches(path, &.{"svg"});
}

/// True when the file can reach the image preview pane automatically. SVG is
/// deliberately excluded; see `isSvgPath`.
pub fn opensInImagePreview(path: []const u8) bool {
    return isImagePath(path) and !isSvgPath(path);
}

/// Port of upstream `isGitLfsPointer` for local files: an LFS pointer is a
/// small text file whose first line is the LFS spec URL. Upstream only applies
/// this to the git scheme, where unresolved pointers live; the TUI applies it
/// to any small local file because the content is the same.
pub fn isGitLfsPointer(content: []const u8) bool {
    if (content.len == 0 or content.len > git_lfs_pointer_max_size) return false;
    return std.mem.startsWith(u8, content, git_lfs_pointer_prefix);
}
