const std = @import("std");
const mem = std.mem;

const bv = @import("build_vars");
const kf = @import("known-folders");

pub const Opts = struct {
    update: bool,
    output: [:0]const u8,
    cache: [:0]const u8,
};

pub fn parse(alloc: mem.Allocator) !Opts {
    const default_cache = default_cache_dir(alloc);

    const opts = parse_args_from_env(alloc) catch |err| switch (err) {
        error.Help => {
            var stdout = std.io.getStdOut();
            const cfg = std.io.tty.detectConfig(stdout);

            try stdout.writer().print(HELP, .{
                .app = bv.app,
                .default_output = DEFAULT_OUTPUT,
                .default_cache = default_cache orelse "UNKNOWN",
                .bold = fmt_color(cfg, .bold),
                .reset = fmt_color(cfg, .reset),
            });
            return error.ExitSuccess;
        },
        error.ShortVersion => {
            try std.io.getStdOut().writer().print(SHORT_VERSION, .{
                .app = bv.app,
                .version = bv.version,
            });
            return error.ExitSuccess;
        },
        error.LongVersion => {
            try std.io.getStdOut().writer().print(LONG_VERSION, .{
                .app = bv.app,
                .version = bv.version,
                .sha = bv.sha,
                .build_at = bv.build_at,
            });
            return error.ExitSuccess;
        },
        error.DuplicateArg, error.UnknownFlag, error.UnexpectedArg, error.MissingArg => {
            return error.ExitArgs;
        },
        else => return err,
    };

    const output = opts.output orelse DEFAULT_OUTPUT;

    const cache_dir = opts.cache orelse default_cache;
    if (cache_dir == null) {
        std.debug.print("Missing required argument --cache\n", .{});
        return error.ExitArgs;
    }

    return .{ .update = opts.update, .output = output, .cache = cache_dir.? };
}

const HELP =
    \\Creates a gitignore file from templates from github.com/github/gitignore
    \\
    \\{[bold]s}Usage:{[reset]s}
    \\    $ {[app]s} [OPTIONS]
    \\
    \\{[bold]s}Options:{[reset]s}
    \\  -o, --output <FILE>  Output to <FILE>. Can use `-` for stdout.
    \\                       - Defaults to `{[default_output]s}`.
    \\                       - An existing file will be overwritten (this might change in the future).
    \\  -c, --cache <DIR>    Use <DIR> as the cache directory.
    \\                       - This directory contains a checked out clone of the gitignore repository.
    \\                       - If there are any weird git issues during the usage, consider deleting the cache.
    \\                       - Defaults to `{[default_cache]s}`.
    \\  -u, --update         Force an update of the cache (git pull of the repo).
    \\                       - By default the cache is updated once a day.
    \\
    \\  -h, --help           Show this help.
    \\  -V, --version        Print the version.
    \\
;

const SHORT_VERSION =
    \\{[app]s} {[version]s}
    \\
;

const LONG_VERSION =
    \\{[app]s}
    \\Version: {[version]s}
    \\Commit: {[sha]s}
    \\Build Date: {[build_at]s}
    \\
;

const DEFAULT_OUTPUT = ".gitignore";

fn default_cache_dir(alloc: mem.Allocator) ?[:0]const u8 {
    const kf_cache = (kf.getPath(alloc, .cache) catch return null) orelse return null;
    return std.fs.path.joinZ(alloc, &.{ kf_cache, bv.app }) catch return null;
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
};

fn parse_args_from_env(alloc: mem.Allocator) !Args {
    const args_slice = try std.process.argsAlloc(alloc);
    var args = @import("args-lex").SliceArgs.init(args_slice);

    const special_flags = enum {
        help,
        version,
        const HELP = @intFromEnum(@as(@This(), .help));
        const VERSION = @intFromEnum(@as(@This(), .version));
    };
    var special_requested = std.enums.directEnumArrayDefault(special_flags, enum { no, short, long }, .no, 0, .{});

    while (args.next()) |arg| {
        switch (arg.*) {
            .shorts => |*shots| while (shots.next()) |short| switch (short) {
                .flag => |s| {
                    if (s == 'h') special_requested[special_flags.HELP] = .short;
                    if (s == 'V') special_requested[special_flags.VERSION] = .short;
                },
                else => {},
            },
            .long => |l| {
                if (std.meta.stringToEnum(special_flags, l.flag)) |flag| {
                    special_requested[@intFromEnum(flag)] = .long;
                }
            },
            else => {},
        }
    }

    if (special_requested[special_flags.HELP] != .no) return error.Help;
    if (special_requested[special_flags.VERSION] == .short) return error.ShortVersion;
    if (special_requested[special_flags.VERSION] == .long) return error.LongVersion;

    args.reset();
    _ = args.skip();

    const once_flags = enum { cache, output };
    const allow_once = enum { allow, forbid };
    var once_state = std.enums.directEnumArrayDefault(
        once_flags,
        allow_once,
        .forbid,
        0,
        .{ .cache = .allow, .output = .allow },
    );

    var opts: Args = .{};

    while (args.next()) |arg| {
        switch (arg.*) {
            .shorts => |*shorts| shorts: while (shorts.nextFlag()) |flag| switch (flag) {
                'u' => opts.update = true,
                'o', 'c' => {
                    const raw_value = shorts.value();
                    const value = if (raw_value.len == 0) null else raw_value;
                    const flag_name = if (flag == 'o') "output" else "cache";
                    arg.* = .{ .long = @import("args-lex").Arg.Long{ .flag = flag_name, .value = value } };
                    break :shorts;
                },
                else => {
                    std.debug.print("Unknown flag: -s{u}\n", .{flag});
                    return error.UnknownFlag;
                },
            },
            .value => |value| {
                std.debug.print("Unexpected argument: {s}\n", .{value});
                return error.UnexpectedArg;
            },
            .escape => if (args.nextValue()) |value| {
                std.debug.print("Unexpected argument: {s}\n", .{value});
                return error.UnexpectedArg;
            },
            else => {},
        }

        switch (arg.*) {
            .long => |long| if (std.meta.stringToEnum(once_flags, long.flag)) |flag| switch (flag) {
                inline else => |f| {
                    const flag_idx = @intFromEnum(f);
                    if (once_state[flag_idx] == .forbid) {
                        std.debug.print("Duplicate argument: --{s}\n", .{long.flag});
                        return error.DuplicateArg;
                    }
                    if (long.value) |value| {
                        @field(opts, @tagName(f)) = value;
                    } else if (args.nextValue()) |value| {
                        @field(opts, @tagName(f)) = value;
                    } else {
                        std.debug.print("Missing argument for --{s}\n", .{long.flag});
                        return error.MissingArg;
                    }
                    once_state[flag_idx] = .forbid;
                },
            } else if (mem.eql(u8, long.flag, "update")) {
                opts.update = true;
            } else {
                std.debug.print("Unknown flag: --{s}\n", .{long.flag});
                return error.UnknownFlag;
            },
            else => {},
        }
    }

    return opts;
}
