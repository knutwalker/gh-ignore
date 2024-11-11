const std = @import("std");
const mem = std.mem;
const Dir = std.fs.Dir;
const args = @import("args.zig");
const cache = @import("cache.zig");

pub const known_folders_config = .{ .xdg_on_mac = true };

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const opts = args.parse(alloc) catch |err| switch (err) {
        error.ExitSuccess => return 0,
        error.ExitArgs => return 2,
        else => return err,
    };
    defer opts.deinit(alloc);

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
    defer {
        for (selected) |sel| alloc.free(sel);
        alloc.free(selected);
    }

    const file_hashes = try ignore_file_hashes(alloc, checkout_dir, selected);
    defer {
        for (file_hashes) |hash| alloc.free(hash);
        alloc.free(file_hashes);
    }

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

    try copy_ignore_files(alloc, checkout_dir, selected, file_hashes, outfile.writer());
}

fn try_select_ignore_files(alloc: mem.Allocator, repo: Dir) !?[][]const u8 {
    return select_ignore_files(alloc, repo) catch |err| switch (err) {
        error.CommandFailed => return null,
        error.BrokenPipe => {
            std.log.err("Could now call `fzf`. Is it installed?", .{});
            return null;
        },
        else => return err,
    };
}

fn select_ignore_files(alloc: mem.Allocator, repo: Dir) !?[][]const u8 {
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
    defer alloc.free(fzf_input_bytes);

    try fzf_input.writeAll(fzf_input_bytes);

    const fzf_out = try fzf_proc.stdout.?.readToEndAlloc(alloc, fzf_input_bytes.len);
    defer alloc.free(fzf_out);

    const term = try fzf_proc.wait();
    switch (term) {
        .Exited => |res| switch (res) {
            // Normal exit
            0 => {
                var items = std.ArrayList([]const u8).init(alloc);
                errdefer {
                    for (items.items) |item| alloc.free(item);
                    items.deinit();
                }

                var lines = mem.splitScalar(u8, mem.trim(u8, fzf_out, &std.ascii.whitespace), '\n');
                while (lines.next()) |line| {
                    const delimiter = mem.indexOfScalar(u8, line, 0x1f).?;
                    const file_path = line[delimiter + 1 ..];
                    std.debug.assert(file_path.len > 0);
                    const item = try alloc.dupe(u8, file_path);
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
    defer checkout_files.deinit();

    var fzf_in = std.ArrayList([]const u8).init(alloc);
    defer {
        for (fzf_in.items) |in| if (in.len > 0) alloc.free(in);
        fzf_in.deinit();
    }

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
    defer git_hash_cmd.deinit();

    try git_hash_cmd.appendSlice(&.{ "git", "hash-object", "-t", "blob" });
    try git_hash_cmd.appendSlice(all_items);

    const hash_out = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = git_hash_cmd.items,
        .cwd_dir = repo,
    });

    alloc.free(hash_out.stderr);
    defer alloc.free(hash_out.stdout);

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
    alloc: mem.Allocator,
    repo: Dir,
    selected_items: [][]const u8,
    file_hashes: [][]const u8,
    out: anytype,
) !void {
    var buf = try alloc.alloc(u8, 64 * mem.page_size);
    defer alloc.free(buf);

    const app = "GH-IGNORER";

    for (selected_items, file_hashes) |item, file_hash| {
        const file_path = mem.trim(u8, item, &std.ascii.whitespace);
        var ignore_file = try repo.openFile(file_path, .{});
        var ignore_meta = try ignore_file.metadata();

        try out.print(
            \\#### {0s} start, do not remote vvvvvvv ####
            \\#### source: {1s}
            \\#### size: {2d}
            \\#### hash: {3s}
            \\
        , .{
            app,
            file_path,
            ignore_meta.size(),
            file_hash,
        });

        var bytes_written: u64 = 0;

        while (true) {
            const buf_size = try ignore_file.read(buf);
            if (buf_size == 0) break;
            try out.writeAll(buf[0..buf_size]);
            bytes_written += buf_size;
        }

        try out.print("#### {0s} end, do not remove ^^^^^^^^^ ####\n", .{app});

        std.debug.assert(bytes_written == ignore_meta.size());
    }
}
