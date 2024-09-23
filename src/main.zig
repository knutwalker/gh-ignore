const std = @import("std");
const Dir = std.fs.Dir;
const kf = @import("known-folders");

pub const known_folders_config = .{ .xdg_on_mac = true };

const MiB = 1024 * 1024;

pub fn main() !void {
    var ally = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = ally.deinit();

    const alloc = ally.allocator();

    // TODO: arg to specify cache dir
    var cache_root_dir = try kf.open(alloc, .cache, .{}) orelse return error.NoCacheDirAvailable;
    defer cache_root_dir.close();

    var cache_dir = try cache_root_dir.makeOpenPath("gh-ignorer", .{});
    defer cache_dir.close();

    // TODO: arg to specify expiration time
    var checkout_dir = try ensure_repo(alloc, cache_dir, 86_400);
    defer checkout_dir.close();

    const selected = try try_select_ignore_files(alloc, &checkout_dir) orelse return;
    defer alloc.free(selected);

    const file_hashes = try ignore_file_hashes(alloc, &checkout_dir, selected);
    defer alloc.free(file_hashes);

    const stdout = std.io.getStdOut();
    try stdout.lock(.exclusive);

    try copy_ignore_files(&checkout_dir, selected, file_hashes, stdout.writer());
}

fn ensure_repo(alloc: std.mem.Allocator, cache_dir: Dir, expire_secs: u64) !Dir {
    update_repo(alloc, cache_dir, expire_secs) catch |err| switch (err) {
        error.FileNotFound => try clone_repo(alloc, cache_dir),
        else => return err,
    };

    const checkout_dir = try cache_dir.openDir("checkout", .{ .iterate = true });
    return checkout_dir;
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

    try write_metadata(metadata_file);
}

fn write_metadata(file: std.fs.File) !void {
    const now = std.time.timestamp();
    const metadata =
        \\Version: 1
        \\Last-Update: {d}
        \\
    ;
    try std.fmt.format(file.writer(), metadata, .{now});
}

fn update_repo(alloc: std.mem.Allocator, cache_dir: Dir, expire_secs: u64) !void {
    var buf: [64]u8 = undefined;
    const metadata_content = try cache_dir.readFile("metadata", &buf);
    var meta_lines = std.mem.splitSequence(u8, metadata_content, "\n");

    var version = meta_lines.next() orelse return error.EmptyMetadata;
    version = strip_prefix(u8, version, "Version: ") orelse return error.InvalidMetadata;
    if (std.mem.eql(u8, version, "1") == false) return error.InvalidMetadataVersion;

    var last_update = meta_lines.next() orelse return error.InvalidMetadata;
    last_update = strip_prefix(u8, last_update, "Last-Update: ") orelse return error.InvalidMetadata;
    const last_update_time = std.fmt.parseInt(i64, last_update, 10) catch return error.InvalidMetadataTimestamp;

    if (std.time.timestamp() - last_update_time > expire_secs) {
        var repo = try cache_dir.openDir("checkout", .{});
        defer repo.close();

        const git_pull_cmd = [_][]const u8{ "git", "pull" };
        var git_pull = std.process.Child.init(&git_pull_cmd, alloc);
        git_pull.stdin_behavior = .Ignore;
        git_pull.cwd_dir = repo;

        const term = try git_pull.spawnAndWait();
        switch (term) {
            .Exited => |res| {
                if (res != 0) return error.CommandFailed;
            },
            else => return error.CommandFailed,
        }

        const metadata_file = try cache_dir.openFile("metadata", .{ .mode = .write_only });
        defer metadata_file.close();

        try write_metadata(metadata_file);
    }
}

fn try_select_ignore_files(alloc: std.mem.Allocator, repo: *Dir) !?[]const u8 {
    return select_ignore_files(alloc, repo) catch |err| switch (err) {
        error.CommandFailed => return null,
        error.BrokenPipe => {
            std.log.err("Could now call `fzf`. Is it installed?", .{});
            return null;
        },
        else => return err,
    };
}

fn select_ignore_files(alloc: std.mem.Allocator, repo: *Dir) !?[]const u8 {
    const fzf_command = [_][]const u8{
        "fzf",
        "--multi",
        "--bind",
        "enter:accept-non-empty",
        "--bind",
        "double-click:accept-non-empty",
        "--bind",
        "esc:cancel",
        "--preview",
        "cat {}",
        "--preview-window",
        "right:sharp:hidden",
        "--bind",
        "?:toggle-preview",
    };

    var fzf_proc = std.process.Child.init(&fzf_command, alloc);
    fzf_proc.cwd_dir = repo.*;
    fzf_proc.stdin_behavior = .Pipe;
    fzf_proc.stdout_behavior = .Pipe;
    fzf_proc.stderr_behavior = .Inherit;

    try fzf_proc.spawn();

    const fzf_input = fzf_proc.stdin.?;

    var max_bytes: usize = 0;
    {
        var checkout_files = try repo.walk(alloc);
        defer checkout_files.deinit();

        const fzf_in = fzf_input.writer();

        while (try checkout_files.next()) |entry| {
            if (entry.kind == .file) {
                const extension = std.fs.path.extension(entry.path);
                if (std.mem.eql(u8, extension, ".gitignore")) {
                    try std.fmt.format(fzf_in, "{s}\n", .{entry.path});
                    max_bytes += entry.path.len + 2;
                }
            }
        }
    }

    const fzf_out = try fzf_proc.stdout.?.readToEndAlloc(alloc, max_bytes);

    const term = try fzf_proc.wait();
    switch (term) {
        .Exited => |res| switch (res) {
            // Normal exit
            0 => return fzf_out,
            // No match
            1 => return null,
            // Interrupted with CTRL-C or ESC
            130 => return null,
            else => return error.CommandFailed,
        },
        else => return error.CommandFailed,
    }
}

fn ignore_file_hashes(alloc: std.mem.Allocator, repo: *Dir, all_items: []const u8) ![]const u8 {
    var git_hash_cmd = std.ArrayList([]const u8).init(alloc);
    defer git_hash_cmd.deinit();

    try git_hash_cmd.appendSlice(&[_][]const u8{ "git", "hash-object", "-t", "blob" });
    var split_items = std.mem.splitSequence(u8, all_items, "\n");
    while (split_items.next()) |item| {
        try git_hash_cmd.append(item);
    }

    const hash_out = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = git_hash_cmd.items,
        .cwd_dir = repo.*,
    });
    alloc.free(hash_out.stderr);
    return hash_out.stdout;
}

fn copy_ignore_files(repo: *Dir, ignore_files: []const u8, file_hashes: []const u8, out: anytype) !void {
    var buf: [4096]u8 = undefined;

    var selected_items = std.mem.splitSequence(u8, ignore_files, "\n");
    var file_hash_iter = std.mem.splitSequence(u8, file_hashes, "\n");

    while (selected_items.next()) |item| {
        const file_path = std.mem.trim(u8, item, &std.ascii.whitespace);
        if (file_path.len > 0) {
            var ignore_file = try repo.openFile(file_path, .{});
            var ignore_meta = try ignore_file.metadata();
            const file_hash = file_hash_iter.next() orelse "";

            try std.fmt.format(out, "### ~*~*~ Source: {s}\n", .{file_path});
            try std.fmt.format(out, "### ~*~*~ Size: {d}\n", .{ignore_meta.size()});
            try std.fmt.format(out, "### ~*~*~ Hash: {s}\n", .{file_hash});

            var bytes_written: u64 = 0;

            while (true) {
                const buf_size = try ignore_file.read(&buf);
                if (buf_size == 0) break;
                try out.writeAll(buf[0..buf_size]);
                bytes_written += buf_size;
            }

            std.debug.assert(bytes_written == ignore_meta.size());
        }
    }
}

fn strip_prefix(comptime T: type, haystack: []const T, prefix: []const T) ?[]const T {
    if (std.mem.startsWith(T, haystack, prefix)) {
        return haystack[prefix.len..];
    } else {
        return null;
    }
}
