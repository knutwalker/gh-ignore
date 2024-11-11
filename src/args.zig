const std = @import("std");
const mem = std.mem;
const kf = @import("known-folders");

pub const Opts = struct {
    update: bool,
    output: [:0]const u8,
    cache: [:0]const u8,

    pub fn deinit(self: Opts, alloc: mem.Allocator) void {
        alloc.free(self.output);
        alloc.free(self.cache);
    }
};

pub fn parse(alloc: mem.Allocator) !Opts {
    const default_cache = default_cache_dir(alloc);
    var free_default = default_cache != null;
    defer if (free_default) alloc.free(default_cache.?);

    const opts = parse_args_from_env(alloc) catch |err| switch (err) {
        error.Help => {
            var stdout = std.io.getStdOut();
            const cfg = std.io.tty.detectConfig(stdout);

            try stdout.writer().print(HELP, .{
                APP,
                DEFAULT_OUTPUT,
                default_cache orelse "UNKNOWN",
                fmt_color(cfg, .bold),
                fmt_color(cfg, .reset),
            });
            return error.ExitSuccess;
        },
        error.Version => {
            try std.io.getStdOut().writer().print("{s} {s}\n", .{ APP, VER });
            return error.ExitSuccess;
        },
        error.DuplicateArg, error.UnknownFlag, error.UnexpectedArg, error.MissingArg => {
            return error.ExitArgs;
        },
        else => return err,
    };

    const output = opts.output orelse try alloc.dupeZ(u8, DEFAULT_OUTPUT);
    errdefer alloc.free(output);

    const cache_dir = opts.cache orelse cache: {
        free_default = false;
        break :cache default_cache;
    };
    if (cache_dir == null) {
        std.debug.print("Missing required argument --cache\n", .{});
        return error.ExitArgs;
    }

    return .{ .update = opts.update, .output = output, .cache = cache_dir.? };
}

const DEFAULT_OUTPUT = ".gitignore";

const APP = "gh-ignorer";
const VER = "0.1.0";
const HELP =
    \\Creates a gitignore file from templates from github.com/github/gitignore
    \\
    \\{3s}Usage:{4s}
    \\    $ {0s} [OPTIONS]
    \\
    \\{3s}Options:{4s}
    \\  -o, --output <FILE>  Output to <FILE>. Can use `-` for stdout.
    \\                       - Defaults to `{1s}`.
    \\                       - An existing file will be overwritten (this might change in the future).
    \\  -c, --cache <DIR>    Use <DIR> as the cache directory.
    \\                       - This directory contains a checked out clone of the gitignore repository.
    \\                       - If there are any weird git issues during the usage, consider deleting the cache.
    \\                       - Defaults to `{2s}`.
    \\  -u, --update         Force an update of the cache (git pull of the repo).
    \\                       - By default the cache is updated once a day.
    \\
    \\  -h, --help           Show this help.
    \\  -V, --version        Print the version.
    \\
;

fn default_cache_dir(alloc: mem.Allocator) ?[:0]const u8 {
    const kf_cache = (kf.getPath(alloc, .cache) catch return null) orelse return null;
    defer alloc.free(kf_cache);
    return std.fs.path.joinZ(alloc, &.{ kf_cache, APP }) catch return null;
}

fn fmt_color(config: std.io.tty.Config, color: std.io.tty.Color) std.fmt.Formatter(format_color) {
    return .{ .data = .{ config, color } };
}

fn format_color(
    config: struct { std.io.tty.Config, std.io.tty.Color },
    comptime fmt: []const u8,
    opts: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = .{ fmt, opts };
    return config[0].setColor(writer, config[1]);
}

const Args = struct {
    update: bool = false,
    output: ?[:0]const u8 = null,
    cache: ?[:0]const u8 = null,

    fn deinit(self: Args, alloc: mem.Allocator) void {
        if (self.output) |o| alloc.free(o);
        if (self.cache) |o| alloc.free(o);
    }
};

fn parse_args_from_env(alloc: mem.Allocator) !Args {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    return try parse_args(alloc, args[1..]);
}

fn parse_args(alloc: mem.Allocator, args: anytype) !Args {
    var help_requested = false;
    var version_requested = false;

    for (args) |arg| {
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h"))
            help_requested = true;
        if (mem.eql(u8, arg, "--version") or mem.eql(u8, arg, "-V"))
            version_requested = true;
    }

    if (help_requested) return error.Help;
    if (version_requested) return error.Version;

    var raw_args = false;

    var cache_arg: enum { allow, expect, forbid } = .allow;
    var file_arg: enum { allow, expect, forbid } = .allow;

    var opts: Args = .{};
    errdefer opts.deinit(alloc);

    for (args) |arg| {
        if (raw_args == false and mem.eql(u8, arg, "--")) {
            raw_args = true;
            continue;
        }

        if (cache_arg == .expect) {
            cache_arg = .forbid;
            opts.cache = try alloc.dupeZ(u8, arg);
            continue;
        }

        if (file_arg == .expect) {
            file_arg = .forbid;
            opts.output = try alloc.dupeZ(u8, arg);
            continue;
        }

        if (raw_args == false) {
            if (mem.eql(u8, arg, "--update") or mem.eql(u8, arg, "-u")) {
                opts.update = true;
            } else if (mem.eql(u8, arg, "--cache") or mem.eql(u8, arg, "-c")) {
                if (cache_arg == .forbid) {
                    std.debug.print("Duplicate argument: --cache\n", .{});
                    return error.DuplicateArg;
                }
                cache_arg = .expect;
            } else if (mem.eql(u8, arg, "--output") or mem.eql(u8, arg, "-o")) {
                if (file_arg == .forbid) {
                    std.debug.print("Duplicate argument: --output\n", .{});
                    return error.DuplicateArg;
                }
                file_arg = .expect;
            } else if (mem.startsWith(u8, arg, "-o")) {
                if (file_arg == .forbid) {
                    std.debug.print("Duplicate argument: --output\n", .{});
                    return error.DuplicateArg;
                }
                file_arg = .forbid;
                opts.output = try alloc.dupeZ(u8, arg[2..]);
            } else {
                std.debug.print("Unknown flag: {s}\n", .{arg});
                return error.UnknownFlag;
            }
        } else {
            std.debug.print("Unexpected argument: {s}\n", .{arg});
            return error.UnexpectedArg;
        }
    }

    if (cache_arg == .expect) {
        std.debug.print("Missing argument for --cache\n", .{});
        return error.MissingArg;
    }

    if (file_arg == .expect) {
        std.debug.print("Missing argument for --output\n", .{});
        return error.MissingArg;
    }

    return opts;
}
