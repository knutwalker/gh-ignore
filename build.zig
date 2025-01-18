const std = @import("std");

const APP = "gh-ignore";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const strip = b.option(bool, "strip", "Enable to strip the binary");

    // build vars {{{
    const build_vars, const version = build_vars: {
        const version = b.option([]const u8, "version", "Set the version of the binary");
        const sha = sha: {
            var git_ec: u8 = 0;
            const git_out = b.runAllowFail(&.{ "git", "rev-parse", "--short=11", "HEAD" }, &git_ec, .Ignore) catch "";
            const git_sha = std.mem.trimRight(u8, git_out, &std.ascii.whitespace);
            break :sha if (git_sha.len > 0) git_sha else null;
        };
        const today = today: {
            const secs = std.time.epoch.EpochSeconds{ .secs = std.math.lossyCast(u64, std.time.timestamp()) };
            const date = secs.getEpochDay();
            const year = date.calculateYearDay();
            const month = year.calculateMonthDay();

            break :today b.fmt("{}-{}-{}", .{
                year.year,
                month.month.numeric(),
                month.day_index,
            });
        };

        const build_vars = b.addOptions();
        build_vars.addOption(struct { app: []const u8, version: []const u8, sha: []const u8, build_at: []const u8 }, "vars", .{
            .app = APP,
            .version = version orelse "dev",
            .sha = sha orelse "HEAD",
            .build_at = today,
        });
        break :build_vars .{ build_vars, version };
    };
    // }}}

    const known_folders = b.dependency("known-folders", .{}).module("known-folders");
    const args_lex = b.dependency("args-lex", .{}).module("args-lex");

    const exe = b.addExecutable(.{
        .name = APP,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .single_threaded = true,
    });

    exe.root_module.addImport("known-folders", known_folders);
    exe.root_module.addImport("args-lex", args_lex);
    exe.root_module.addOptions("build_vars", build_vars);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the program");
    run_step.dependOn(&run_cmd.step);

    const check_exe = b.addExecutable(.{
        .name = APP,
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
        .strip = false,
        .single_threaded = true,
    });
    check_exe.root_module.addImport("known-folders", known_folders);
    check_exe.root_module.addImport("args-lex", args_lex);
    check_exe.root_module.addOptions("build_vars", build_vars);

    const check_step = b.step("check", "Check if the project compiles");
    check_step.dependOn(&check_exe.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // dist {{{
    const dist_step = b.step("dist", "Build release distribution");

    const clean_dist = b.addRemoveDirTree("dist");
    dist_step.dependOn(&clean_dist.step);

    for (&[_]std.Target.Os.Tag{ .macos, .windows, .linux }) |os| {
        for (&[_]std.Target.Cpu.Arch{ .aarch64, .x86_64 }) |arch| {
            var target_query = target.query;
            target_query.cpu_arch = arch;
            target_query.cpu_model = .baseline;
            target_query.os_tag = os;
            target_query.abi = switch (os) {
                .macos => .none,
                .windows => .msvc,
                .linux => .gnu,
                else => unreachable,
            };

            const cross_exe = b.addExecutable(.{
                .name = APP,
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(target_query),
                .optimize = .ReleaseSafe,
                .strip = true,
                .single_threaded = true,
            });
            cross_exe.root_module.addImport("known-folders", known_folders);
            cross_exe.root_module.addImport("args-lex", args_lex);
            cross_exe.root_module.addOptions("build_vars", build_vars);

            // see `go tool dist list` and
            // https://github.com/cli/gh-extension-precompile/blob/561b19/README.md#extensions-written-in-other-compiled-languages
            const go_os, const ext = switch (os) {
                .macos => .{ "darwin", "" },
                .linux => .{ "linux", "" },
                .windows => .{ "windows", ".exe" },
                else => unreachable,
            };
            const go_arch = switch (arch) {
                .aarch64 => "arm64",
                .x86_64 => "amd64",
                else => unreachable,
            };
            const vers = if (version) |v| b.fmt("-v{s}", .{v}) else "";
            const target_file = b.fmt("{s}{s}-{s}-{s}{s}", .{ APP, vers, go_os, go_arch, ext });

            const target_out = b.addInstallArtifact(cross_exe, .{
                .dest_dir = .{ .override = .{ .custom = "../dist" } },
                .dest_sub_path = target_file,
            });
            dist_step.dependOn(&target_out.step);
        }
    }
    // }}}
}
