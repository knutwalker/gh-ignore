const std = @import("std");
const mem = std.mem;
const Dir = std.fs.Dir;

pub fn select_ignore_files(alloc: mem.Allocator, repo: Dir) !?[][:0]const u8 {
    return run_select_ignore_files(alloc, repo) catch |err| switch (err) {
        error.CommandFailed => return null,
        error.BrokenPipe => {
            std.log.err("Could now call `fzf`. Is it installed?", .{});
            return null;
        },
        else => return err,
    };
}

pub fn copy_ignore_files(
    repo: Dir,
    selected_items: [][:0]const u8,
    out: std.fs.File,
) !void {
    const vec = std.posix.iovec_const;

    var meta_buf: [1024]u8 = undefined;

    for (selected_items) |file_path| {
        const ignore_file = try repo.openFileZ(file_path, .{});
        defer ignore_file.close();

        const metadata = try std.fmt.bufPrint(
            &meta_buf,
            \\## Source: {s}
            \\
            \\
        ,
            .{file_path},
        );

        const trailer_start = metadata.len - 1;
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

fn run_select_ignore_files(alloc: mem.Allocator, repo: Dir) !?[][:0]const u8 {
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
