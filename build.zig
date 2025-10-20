const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_curl = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
    });
    const mod = b.addModule("multitool", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "curl", .module = dep_curl.module("curl") },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "multitool", .module = mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = "multitool",
        .root_module = exe_mod,
    });
    exe.linkLibC();

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_check = b.addExecutable(.{
        .name = "check",
        .root_module = exe_mod,
    });
    const check = b.step("check", "Check if code compiles");
    check.dependOn(&exe_check.step);
}
