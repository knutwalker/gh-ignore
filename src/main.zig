const std = @import("std");
const args = @import("args.zig");
const cache = @import("cache.zig");
const ignore = @import("ignore.zig");

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

fn run(alloc: std.mem.Allocator, opts: args.Opts) !void {
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

    const selected = try ignore.select_ignore_files(alloc, checkout_dir) orelse return;

    const output = opts.output;
    var outfile, const close_out =
        if (std.mem.eql(u8, output, "-")) .{ std.io.getStdOut(), false } else out: {
        const file = try std.fs.cwd().createFileZ(output, .{
            .truncate = true,
            .exclusive = false,
            .lock = .exclusive,
        });
        break :out .{ file, true };
    };
    defer if (close_out) outfile.close();

    try ignore.copy_ignore_files(checkout_dir, selected, outfile);
}
