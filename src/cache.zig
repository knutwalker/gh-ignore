const std = @import("std");
const Dir = std.fs.Dir;

const Metadata = struct {
    last_update_at: i64,

    fn now() Metadata {
        return .{ .last_update_at = std.time.timestamp() };
    }
};

const ParseMetadataError = error{
    EmptyMetadata,
    InvalidMetadata,
    InvalidVersion,
    InvalidTimestamp,
};

pub fn ensure_repo_cache(cache: Dir, alloc: std.mem.Allocator, expire_secs: u64) !Dir {
    update_repo(alloc, cache, expire_secs) catch |err| switch (err) {
        error.FileNotFound => try clone_repo(alloc, cache),
        else => return err,
    };

    const checkout_dir = try cache.openDir("checkout", .{ .iterate = true });
    return checkout_dir;
}

fn update_repo(alloc: std.mem.Allocator, cache_dir: Dir, expire_secs: u64) !void {
    var buf: [64]u8 = undefined;
    const metadata_content = try cache_dir.readFile("metadata", &buf);
    const metadata = try parse_metadata(metadata_content);

    if (std.time.timestamp() - metadata.last_update_at > expire_secs) {
        var repo = try cache_dir.openDir("checkout", .{});
        defer repo.close();

        try pull_repo(alloc, repo);

        const metadata_file = try cache_dir.openFile("metadata", .{ .mode = .write_only });
        defer metadata_file.close();

        try write_metadata(metadata_file.writer(), Metadata.now());
    }
}

fn parse_metadata(content: []const u8) ParseMetadataError!Metadata {
    var meta_lines = std.mem.splitSequence(u8, content, "\n");

    var version = meta_lines.next() orelse return ParseMetadataError.EmptyMetadata;
    version = strip_prefix(version, "Version: ") orelse return ParseMetadataError.InvalidMetadata;
    if (std.mem.eql(u8, version, "1") == false) return ParseMetadataError.InvalidVersion;

    var last_update = meta_lines.next() orelse return ParseMetadataError.InvalidMetadata;
    last_update = strip_prefix(last_update, "Last-Update: ") orelse return ParseMetadataError.InvalidMetadata;
    const last_update_time = std.fmt.parseInt(i64, last_update, 10) catch return ParseMetadataError.InvalidTimestamp;

    return .{ .last_update_at = last_update_time };
}

fn strip_prefix(haystack: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, haystack, prefix)) {
        return haystack[prefix.len..];
    } else {
        return null;
    }
}

fn pull_repo(alloc: std.mem.Allocator, repo: Dir) !void {
    const git_pull_cmd = [_][]const u8{ "git", "pull" };
    var git_pull = std.process.Child.init(&git_pull_cmd, alloc);
    git_pull.stdin_behavior = .Ignore;
    git_pull.cwd_dir = repo;

    const term = try git_pull.spawnAndWait();
    switch (term) {
        .Exited => |res| if (res != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn write_metadata(writer: anytype, metadata: Metadata) !void {
    const md_content =
        \\Version: 1
        \\Last-Update: {d}
        \\
    ;
    try writer.print(md_content, .{metadata.last_update_at});
}

fn clone_repo(alloc: std.mem.Allocator, cache_dir: Dir) !void {
    const git_clone_cmd = [_][]const u8{ "git", "clone", "https://github.com/github/gitignore.git", "checkout" };
    var clone_dir = std.process.Child.init(&git_clone_cmd, alloc);
    clone_dir.stdin_behavior = .Ignore;
    clone_dir.cwd_dir = cache_dir;

    const term = try clone_dir.spawnAndWait();
    switch (term) {
        .Exited => |res| {
            if (res != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }

    const metadata_file = try cache_dir.createFile("metadata", .{ .exclusive = true });
    defer metadata_file.close();

    try write_metadata(metadata_file.writer(), Metadata.now());
}
