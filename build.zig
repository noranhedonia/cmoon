const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allow the user running `zig build` to choose 
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options 
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    // apis/libraries we'll need below
    const wayland = makeWaylandModule(b);
    const vulkan = makeVulkanModule(b);

    _ = wayland;
    _ = vulkan;

    const cmoon_mod = b.createModule(.{
        .root_source_file = b.path("source/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cmoon = b.addExecutable(.{
        .name = "cmoon",
        .root_module = cmoon_mod,
    });
    b.installArtifact(cmoon);

    const run_cmd = b.addRunArtifact(cmoon);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run Cynic Moon");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = cmoon_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn makeVulkanModule(b: *std.Build) *std.Build.Module {
    _ = b;
}

fn makeWaylandModule(b: *std.Build) *std.Build.Module {
    _ = b;
}
