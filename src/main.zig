const std = @import("std");
const mem = std.mem;
const Dir = std.fs.Dir;
const args = @import("args.zig");
const cache = @import("cache.zig");

pub const known_folders_config = .{ .xdg_on_mac = true };

pub fn main() !u8 {
    var ally = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = ally.deinit();

    const alloc = ally.allocator();

    const opts = args.parse(alloc) catch |err| switch (err) {
        error.ExitSuccess => return 0,
        error.ExitArgs => return 2,
        else => return err,
    };

    try run(alloc, opts);
    return 0;
}

fn run(alloc: mem.Allocator, opts: args.Opts) !void {
    const cache_dir_path = opts.cache;
    var cache_dir = std.fs.cwd().openDirZ(cache_dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().makeOpenPath(cache_dir_path, .{}),
        else => return err,
    };
    defer cache_dir.close();

    var checkout_dir = try cache.ensure_repo_cache(
        cache_dir,
        alloc,
        if (opts.update) 0 else std.time.s_per_day,
    );
    defer checkout_dir.close();

    const selected = try try_select_ignore_files(alloc, checkout_dir) orelse return;

    const file_hashes = try ignore_file_hashes(alloc, checkout_dir, selected);

    const output = opts.output;
    var outfile, const close_out =
        if (mem.eql(u8, output, "-")) .{ std.io.getStdOut(), false } else out: {
        const file = try std.fs.cwd().createFileZ(output, .{
            .truncate = true,
            .exclusive = false,
            .lock = .exclusive,
        });
        break :out .{ file, true };
    };
    defer if (close_out) outfile.close();

    try copy_ignore_files(checkout_dir, selected, file_hashes, outfile);
}

fn try_select_ignore_files(alloc: mem.Allocator, repo: Dir) !?[][:0]const u8 {
    return select_ignore_files(alloc, repo) catch |err| switch (err) {
        error.CommandFailed => return null,
        error.BrokenPipe => {
            std.log.err("Could now call `fzf`. Is it installed?", .{});
            return null;
        },
        else => return err,
    };
}

fn select_ignore_files(alloc: mem.Allocator, repo: Dir) !?[][:0]const u8 {
    const fzf_command = [_][]const u8{
        "fzf",
        "--ignore-case",
        "--multi",
        "--delimiter",
        "\x1f",
        "--nth",
        "1",
        "--with-nth",
        "1",
        "--cycle",
        "--layout",
        "reverse",
        "--bind",
        "enter:accept-non-empty",
        "--bind",
        "double-click:accept-non-empty",
        "--bind",
        "esc:cancel",
        "--preview",
        "echo '{2}:\n' && cat {2}",
        "--preview-window",
        "right:sharp:hidden",
        "--bind",
        "?:toggle-preview",
    };

    var fzf_proc = std.process.Child.init(&fzf_command, alloc);
    fzf_proc.cwd_dir = repo;
    fzf_proc.stdin_behavior = .Pipe;
    fzf_proc.stdout_behavior = .Pipe;
    fzf_proc.stderr_behavior = .Inherit;

    try fzf_proc.spawn();

    const fzf_input = fzf_proc.stdin.?;
    const fzf_input_bytes = try get_fzf_input(alloc, repo);
    try fzf_input.writeAll(fzf_input_bytes);

    const fzf_out = try fzf_proc.stdout.?.readToEndAlloc(alloc, fzf_input_bytes.len);

    const term = try fzf_proc.wait();
    switch (term) {
        .Exited => |res| switch (res) {
            // Normal exit
            0 => {
                var items = std.ArrayList([:0]const u8).init(alloc);

                var lines = mem.splitScalar(u8, mem.trim(u8, fzf_out, &std.ascii.whitespace), '\n');
                while (lines.next()) |line| {
                    const delimiter = mem.indexOfScalar(u8, line, 0x1f).?;
                    const file_path = mem.trim(u8, line[delimiter + 1 ..], &std.ascii.whitespace);
                    std.debug.assert(file_path.len > 0);
                    const item = try alloc.dupeZ(u8, file_path);
                    try items.append(item);
                }

                return try items.toOwnedSlice();
            },
            // No match
            1 => return null,
            // Interrupted with CTRL-C or ESC
            130 => return null,
            else => return error.CommandFailed,
        },
        else => return error.CommandFailed,
    }
}

fn get_fzf_input(alloc: mem.Allocator, repo: Dir) ![:0]const u8 {
    var checkout_files = try repo.walk(alloc);

    var fzf_in = std.ArrayList([]const u8).init(alloc);

    while (try checkout_files.next()) |entry| {
        if (entry.kind == .file) {
            const extension = std.fs.path.extension(entry.path);

            if (mem.eql(u8, extension, ".gitignore")) {
                var file_name = std.fs.path.basename(entry.path);
                file_name = file_name[0..(file_name.len - ".gitignore".len)];

                const path = try std.fmt.allocPrint(
                    alloc,
                    "{s}\x1f{s}",
                    .{ file_name, entry.path },
                );
                try fzf_in.append(path);
            }
        }
    }

    const lt = struct {
        fn lt(_: void, lhs: []const u8, rhs: []const u8) bool {
            const l = mem.indexOfScalar(u8, lhs, 0x1f).?;
            const r = mem.indexOfScalar(u8, rhs, 0x1f).?;
            return std.ascii.lessThanIgnoreCase(lhs[0..l], rhs[0..r]);
        }
    }.lt;

    mem.sort([]const u8, fzf_in.items, {}, lt);
    try fzf_in.append("");

    return mem.joinZ(alloc, "\n", fzf_in.items);
}

fn ignore_file_hashes(alloc: mem.Allocator, repo: Dir, all_items: [][]const u8) ![][]const u8 {
    var git_hash_cmd = std.ArrayList([]const u8).init(alloc);

    try git_hash_cmd.appendSlice(&.{ "git", "hash-object", "-t", "blob" });
    try git_hash_cmd.appendSlice(all_items);

    const hash_out = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = git_hash_cmd.items,
        .cwd_dir = repo,
    });

    const output = try alloc.alloc([]const u8, all_items.len);
    std.debug.assert(output.len == all_items.len);

    var idx: usize = 0;
    var lines = mem.splitScalar(u8, mem.trim(u8, hash_out.stdout, &std.ascii.whitespace), '\n');
    while (lines.next()) |line| {
        output[idx] = try alloc.dupe(u8, line);
        idx += 1;
    }

    std.debug.assert(idx == all_items.len);

    return output;
}

fn copy_ignore_files(
    repo: Dir,
    selected_items: [][:0]const u8,
    file_hashes: [][]const u8,
    out: std.fs.File,
) !void {
    const app = "GH-IGNORER";
    const vec = std.posix.iovec_const;

    var meta_buf: [1024]u8 = undefined;

    for (selected_items, file_hashes) |file_path, file_hash| {
        const ignore_file = try repo.openFileZ(file_path, .{});
        defer ignore_file.close();

        const ignore_stat = try ignore_file.stat();

        const metadata = try std.fmt.bufPrint(
            &meta_buf,
            \\# {0s} start, do not remote vvv
            \\# source: {1s}
            \\# size: {2d}
            \\# hash: {3s}
            \\
            \\# {0s} end, do not remove ^^^^^
            \\
        ,
            .{ app, file_path, ignore_stat.size, file_hash },
        );

        const trailer_start = mem.lastIndexOfScalar(u8, metadata, '#').? - 1;
        const header = metadata[0..trailer_start];
        const trailer = metadata[trailer_start..];

        const header_vec = vec{ .base = header.ptr, .len = header.len };
        const trailer_vec = vec{ .base = trailer.ptr, .len = trailer.len };
        var headers_and_trailers = [_]vec{ header_vec, trailer_vec };

        try out.writeFileAll(ignore_file, .{
            .headers_and_trailers = &headers_and_trailers,
            .header_count = 1,
        });
    }
}
