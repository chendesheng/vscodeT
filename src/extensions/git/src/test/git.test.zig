// Port of the parser cases from `vscode/extensions/git/src/test/git.test.ts`
// that cover the terminal ported subset: version, commit log records, raw
// diff records and branch parsing. Clone/remote/worktree suites are outside the
// ported `git.ts` behavior and are listed as omitted in the file header.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const git = @import("../git.zig");

fn fmtAlloc(allocator: Allocator, comptime format: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, format, args);
}

fn appendRecord(out: *std.array_list.Managed(u8), record: []const u8) !void {
    try out.appendSlice(record);
    try out.append(0);
}

fn buildLogFixture(allocator: Allocator) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    const first = try fmtAlloc(allocator, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "Ada Lovelace",
        "ada@example.com",
        "1700000000",
        "1700000100",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1",
        "subject line\nbody line\n",
    });
    defer allocator.free(first);
    try out.appendSlice(first);
    try out.append(0);
    try out.appendSlice("\n 4 files changed, 38 insertions(+), 31 deletions(-)\n");

    const second = try fmtAlloc(allocator, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "Grace Hopper",
        "grace@example.com",
        "1699990000",
        "1699990100",
        "",
        "",
        "root commit",
    });
    defer allocator.free(second);
    try out.appendSlice(second);
    // No shortstat for an empty diff; the next record (none here) would start
    // immediately after the NUL.
    try out.append(0);

    return out.toOwnedSlice();
}

test "parseGitVersion: parses major and minor" {
    const version = git.parseGitVersion("git version 2.50.1 (Apple Git-155)\n").?;
    try testing.expectEqual(@as(usize, 2), version.major);
    try testing.expectEqual(@as(usize, 50), version.minor);
    try testing.expect(git.parseGitVersion("nonsense") == null);
}

test "parseGitCommits: fields, decorations, messages and shortstat" {
    const allocator = testing.allocator;
    const fixture = try buildLogFixture(allocator);
    defer allocator.free(fixture);

    const commits = try git.parseGitCommits(allocator, fixture);
    defer commonFree(allocator, commits);

    try testing.expectEqual(@as(usize, 2), commits.len);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", commits[0].hash);
    try testing.expectEqualStrings("Ada Lovelace", commits[0].author_name);
    try testing.expectEqualStrings("ada@example.com", commits[0].author_email);
    try testing.expectEqual(@as(i64, 1700000000), commits[0].author_date.?);
    try testing.expectEqual(@as(i64, 1700000100), commits[0].commit_date.?);
    try testing.expectEqual(@as(usize, 1), commits[0].parents.len);
    try testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", commits[0].parents[0]);
    try testing.expectEqual(@as(usize, 3), commits[0].ref_names.len);
    try testing.expectEqualStrings("HEAD -> refs/heads/main", commits[0].ref_names[0]);
    try testing.expectEqualStrings("subject line\nbody line", commits[0].message);
    try testing.expectEqual(@as(usize, 4), commits[0].short_stat.?.files);
    try testing.expectEqual(@as(usize, 38), commits[0].short_stat.?.insertions);
    try testing.expectEqual(@as(usize, 31), commits[0].short_stat.?.deletions);

    try testing.expectEqual(@as(usize, 0), commits[1].parents.len);
    try testing.expectEqual(@as(usize, 0), commits[1].ref_names.len);
    try testing.expectEqualStrings("root commit", commits[1].message);
    try testing.expect(commits[1].short_stat == null);
}

fn commonFree(allocator: Allocator, commits: []git.GitCommit) void {
    git.freeGitCommits(allocator, commits);
}

fn buildDiffFixture(allocator: Allocator) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(":100644 100644 aaaaaaa bbbbbbb M");
    try out.append(0);
    try out.appendSlice("README.md");
    try out.append(0);
    try out.appendSlice(":100644 100644 aaaaaaa bbbbbbb A");
    try out.append(0);
    try out.appendSlice("added.txt");
    try out.append(0);
    try out.appendSlice(":100644 100644 aaaaaaa bbbbbbb D");
    try out.append(0);
    try out.appendSlice("deleted.txt");
    try out.append(0);
    try out.appendSlice(":100644 100644 aaaaaaa bbbbbbb R100");
    try out.append(0);
    try out.appendSlice("old.txt");
    try out.append(0);
    try out.appendSlice("new.txt");
    try out.append(0);
    try out.appendSlice("1\t2\tREADME.md");
    try out.append(0);
    try out.appendSlice("10\t0\tadded.txt");
    try out.append(0);
    try out.appendSlice("0\t5\tdeleted.txt");
    try out.append(0);
    try out.appendSlice("3\t4\t");
    try out.append(0);
    try out.appendSlice("old.txt");
    try out.append(0);
    try out.appendSlice("new.txt");
    try out.append(0);
    return out.toOwnedSlice();
}

test "parseGitChangesRaw: statuses, renames and numstat pairing" {
    const allocator = testing.allocator;
    const fixture = try buildDiffFixture(allocator);
    defer allocator.free(fixture);

    const changes = try git.parseGitChangesRaw(allocator, fixture);
    defer freeChanges(allocator, changes);

    try testing.expectEqual(@as(usize, 4), changes.len);
    try testing.expectEqual(@as(u8, 'M'), changes[0].change.status);
    try testing.expectEqualStrings("README.md", changes[0].change.path);
    try testing.expectEqual(@as(usize, 1), changes[0].insertions);
    try testing.expectEqual(@as(usize, 2), changes[0].deletions);

    try testing.expectEqual(@as(u8, 'A'), changes[1].change.status);
    try testing.expectEqual(@as(usize, 10), changes[1].insertions);

    try testing.expectEqual(@as(u8, 'D'), changes[2].change.status);
    try testing.expectEqual(@as(usize, 5), changes[2].deletions);

    try testing.expectEqual(@as(u8, 'R'), changes[3].change.status);
    try testing.expectEqualStrings("new.txt", changes[3].change.path);
    try testing.expectEqualStrings("old.txt", changes[3].change.original_path.?);
    try testing.expectEqual(@as(usize, 3), changes[3].insertions);
    try testing.expectEqual(@as(usize, 4), changes[3].deletions);
}

fn freeChanges(allocator: Allocator, changes: []git.GitDiffChange) void {
    for (changes) |*change| {
        allocator.free(change.change.path);
        if (change.change.original_path) |path| allocator.free(path);
    }
    if (changes.len > 0) allocator.free(changes);
}

test "parseBranch: local upstream and remote names" {
    const allocator = testing.allocator;
    const local = "refs/heads/main\x00origin/main\x00abcdef\x00origin\x00refs/heads/main\x00";
    var branch = (try git.parseBranch(allocator, local)).?;
    defer branch.deinit(allocator);
    try testing.expectEqual(git.GitRefType.head, branch.ref.ref_type);
    try testing.expectEqualStrings("main", branch.ref.name.?);
    try testing.expectEqualStrings("abcdef", branch.ref.commit.?);
    try testing.expectEqualStrings("origin", branch.upstream.?.remote);
    try testing.expectEqualStrings("main", branch.upstream.?.name);

    const remote = "refs/remotes/origin/topic\x00\x00fedcba\x00\x00\x00";
    var remote_branch = (try git.parseBranch(allocator, remote)).?;
    defer remote_branch.deinit(allocator);
    try testing.expectEqual(git.GitRefType.remote_head, remote_branch.ref.ref_type);
    try testing.expectEqualStrings("topic", remote_branch.ref.name.?);
    try testing.expectEqualStrings("origin", remote_branch.ref.remote.?);

    try testing.expect((try git.parseBranch(allocator, "refs/tags/v1\x00\x00abc\x00\x00\x00")) == null);
}

test "parseGitDiffShortStat: singular and missing parts" {
    const all = git.parseGitDiffShortStat(" 1 file changed, 1 insertion(+), 1 deletion(-)");
    try testing.expectEqual(@as(usize, 1), all.files);
    try testing.expectEqual(@as(usize, 1), all.insertions);
    try testing.expectEqual(@as(usize, 1), all.deletions);

    const insert_only = git.parseGitDiffShortStat(" 2 files changed, 7 insertions(+)");
    try testing.expectEqual(@as(usize, 2), insert_only.files);
    try testing.expectEqual(@as(usize, 7), insert_only.insertions);
    try testing.expectEqual(@as(usize, 0), insert_only.deletions);
}
