const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const strip = b.option(bool, "strip", "Enable to strip the binary");

    const known_folders = b.dependency("known-folders", .{}).module("known-folders");
    const args_lex = b.dependency("args-lex", .{}).module("args-lex");

    const exe = b.addExecutable(.{
        .name = "gh-ignorer",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .single_threaded = true,
    });

    exe.root_module.addImport("known-folders", known_folders);
    exe.root_module.addImport("args-lex", args_lex);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the program");
    run_step.dependOn(&run_cmd.step);

    const check_exe = b.addExecutable(.{
        .name = "gh-ignorer",
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
        .strip = false,
        .single_threaded = true,
    });
    check_exe.root_module.addImport("known-folders", known_folders);
    check_exe.root_module.addImport("args-lex", args_lex);

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

    const targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
        .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .msvc },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .macos, .abi = .none },
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    };

    const cross_step = b.step("cross", "Cross compile the binary");

    for (targets) |t| {
        const cross_exe = b.addExecutable(.{
            .name = "gh-ignorer",
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(t),
            .optimize = optimize,
            .strip = strip,
            .single_threaded = true,
        });
        cross_exe.root_module.addImport("known-folders", known_folders);
        cross_exe.root_module.addImport("args-lex", args_lex);

        const target_suffix = try t.zigTriple(b.allocator);
        const target_file = try std.mem.concat(b.allocator, u8, &.{ "gh-ignorer-", target_suffix });

        const target_out = b.addInstallArtifact(cross_exe, .{
            .dest_sub_path = target_file,
        });
        cross_step.dependOn(&target_out.step);
    }
}
