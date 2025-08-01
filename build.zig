const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // TODO add `test` step and `docs` step, pass them as arguments so other modules can emit their tests/documentation
    // TODO if host has a LaTeX distribution installed, emit the technical documentation too via `docs`

    // Used to assemble different engine submodules into a library
    const cmoon_module = b.addModule("cmoon", .{ 
        .root_source_file = b.path("source/cmoon.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cmoon_encore_module = makeCMoonEncoreModule(b, target, optimize);
    cmoon_module.addImport("cmoon-encore", cmoon_encore_module);

    const cmoon_display_module = makeCMoonDisplayModule(b, target, optimize, cmoon_encore_module);
    cmoon_module.addImport("cmoon-display", cmoon_display_module);

    const cmoon_audio_module = makeCMoonAudioModule(b, target, optimize, cmoon_encore_module);
    cmoon_module.addImport("cmoon-audio", cmoon_audio_module);

    const cmoon_gfx_module = makeCMoonGfxModule(b, target, optimize, cmoon_encore_module);
    cmoon_module.addImport("cmoon-gfx", cmoon_gfx_module);

    const cmoon_lib = b.addLibrary(.{
        .name = "cmoon", 
        .linkage = .static,
        .root_module = cmoon_module,
    });
    b.installArtifact(cmoon_lib);

    // the game application
    const main_exe = b.addExecutable(.{
        .name = "cmoon",
        .root_source_file = b.path("source/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_exe.root_module.addImport("cmoon", cmoon_module);
    b.installArtifact(main_exe);

    const main_run_cmd = b.addRunArtifact(main_exe);
    main_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| { main_run_cmd.addArgs(args); }

    const main_run_step = b.step("run", "Run Cynic Moon");
    main_run_step.dependOn(&main_run_cmd.step);
}

fn makeCMoonEncoreModule(b: *std.Build) *std.Build.Module 
{
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const asm_cpu = switch (target.result.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "aarch64",
        .riscv64 => "rv64gc",
        .wasm32, .wasm64 => "wasm",
        else => std.debug.panic("Unsupported CPU: {s}", .{ @tagName(target.result.cpu.arch) }),
    };
    const asm_os = switch (target.result.cpu.arch) {
        .aarch64 => "_aapcs_", else => switch(target.result.os.tag) {
            .windows => "_ms_", 
            .freestanding => "",
            else => "_sysv_",
        },
    };
    const asm_abi = switch (target.result.os.tag) {
        .macos, .ios, => "macho",
        .windows, => "pe",
        .freestanding, => "wasi",
        else => "elf",
    };
    var asm_path_buf: [100]u8 = undefined; 
    const asm_path = std.fmt.bufPrint(&asm_path_buf, "source/encore/asm/fcontext_{s}{s}{s}.s", .{ asm_cpu, asm_os, asm_abi })
        catch |err| std.debug.panic("Path formatting for assembly failed: {}", .{err});

    const encore_module = b.addModule("cmoon-encore", .{
        .root_source_file = b.path("source/encore/impl.zig"),
        .target = target, .optimize = optimize,
    });
    encore_module.addAssemblyFile(b.path(asm_path));
    return encore_module;
}

fn makeCMoonDisplayModule(
    b: *std.Build,
    encore_module: *std.Build.Module)
    *std.Build.Module 
{
    const display_module = b.addModule("cmoon-display", .{
        .root_source_file = b.path("source/display/impl.zig"),
        .target = b.standardTargetOptions(.{}), 
        .optimize = b.standardOptimizeOption(.{}),
        .imports = &.{.{ .name = "cmoon-encore", .module = encore_module }},
    });
    display_module.addImport("wayland", makeWaylandModule(b, encore_module));
    return display_module;
}

const GenerateProtocolsOptions = struct {
    output_directory_name: ?[]const u8,
    output_compat_name: ?[]const u8 = null,
    source_files: []const std.Build.LazyPath,
};
const GenerateProtocolsResult = struct {
    output_directory: ?std.Build.LazyPath,
    output_compat_file: ?std.Build.LazyPath,
};

fn makeWaylandModule(
    b: *std.Build,
    encore_module: *std.Build.Module)
    ?*std.Build.Module 
{
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wayland_wire_module = b.createModule(.{ .root_source_file = b.path("tools/wayland/wire.zig") });
    const scanner_exe = b.addExecutable(.{
        .name = "wayland-zig-scanner",
        .root_source_file = b.path("tools/wayland/scanner.zig"),
        .target = b.graph.host,
    });
    scanner_exe.root_module.addImport("cmoon-encore", encore_module);
    b.installArtifact(scanner_exe);
    const scanner_generate_cmd = b.addRunArtifact(scanner_exe);

    const wayland_protocols_generate_options = GenerateProtocolsOptions{
        .output_directory_name = "wayland-protocols",
        .output_compat_name = "wayland-protocols-compat.zig",
        .source_files = &.{
            b.path("protocols/wayland.xml"),
            b.path("protocols/color-management-v1.xml"),
            b.path("protocols/cursor-shape-v1.xml"),
            b.path("protocols/fractional-scale-v1.xml"),
            b.path("protocols/idle-inhibit-unstable-v1.xml"),
            b.path("protocols/input-timestamps-unstable-v1.xml"),
            b.path("protocols/keyboard-shortcuts-inhibit-unstable-v1.xml"),
            b.path("protocols/pointer-constraints-unstable-v1.xml"),
            b.path("protocols/pointer-gestures-unstable-v1.xml"),
            b.path("protocols/relative-pointer-unstable-v1.xml"),
            b.path("protocols/tablet-unstable-v2.xml"),
            b.path("protocols/text-input-unstable-v3.xml"),
            b.path("protocols/viewporter.xml"),
            b.path("protocols/xdg-activation-v1.xml"),
            b.path("protocols/xdg-decoration-unstable-v1.xml"),
            b.path("protocols/xdg-dialog-v1.xml"),
            b.path("protocols/xdg-foreign-unstable-v2.xml"),
            b.path("protocols/xdg-output-unstable-v1.xml"),
            b.path("protocols/xdg-shell.xml"),
            b.path("protocols/xdg-toplevel-icon-v1.xml"),
        },
    };
    for (wayland_protocols_generate_options.source_files) |source_file| { scanner_generate_cmd.addFileArg(source_file); }
    var wayland_protocols_generate_result: GenerateProtocolsResult = .{ null, null };

    if (wayland_protocols_generate_options.output_directory_name) |dir_name| {
        scanner_generate_cmd.addArg("--output");
        wayland_protocols_generate_result.output_directory = scanner_generate_cmd.addOutputDirectoryArg(dir_name);
    }
    if (wayland_protocols_generate_options.output_compat_name) |file_name| {
        scanner_generate_cmd.addArg("--output-compat");
        wayland_protocols_generate_result.output_compat_file = scanner_generate_cmd.addOutputDirectoryArg(file_name);
    }
    const wayland_protocols_module = b.createModule(.{
        .root_source_file = wayland_protocols_generate_result.output_directory.?.path(b, "wayland-protocols.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayland-wire", .module = wayland_wire_module }},
    });
    const wayland_protocols_compat_module = b.createModule(.{
        .root_source_file = wayland_protocols_generate_result.output_directory.?,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayland-wire", .module = wayland_wire_module }},
    });
    return b.addModule("wayland", .{
        .root_source_file = b.path("tools/wayland/wayland.zig"),
        .imports = &.{
            .{ .name = "wayland-wire", .module = wayland_wire_module },
            .{ .name = "wayland-protocols", .module = wayland_protocols_module },
            .{ .name = "wayland-protocols-compat", .module = wayland_protocols_compat_module },
        },
    });
}

fn makeCMoonAudioModule(
    b: *std.Build,
    encore_module: *std.Build.Module)
    *std.Build.Module 
{
    const audio_module = b.addModule("cmoon-audio", .{
        .root_source_file = b.path("source/audio/impl.zig"),
        .target = b.standardTargetOptions(.{}), 
        .optimize = b.standardOptimizeOption(.{}),
        .imports = &.{.{ .name = "cmoon-encore", .module = encore_module }},
    });
    return audio_module;
}

fn makeCMoonGfxModule(
    b: *std.Build,
    encore_module: *std.Build.Module)
    *std.Build.Module 
{
    const cmoon_gfx_module = b.addModule("cmoon-gfx", .{
        .root_source_file = b.path("source/graphics/impl.zig"),
        .target = b.standardTargetOptions(.{}), 
        .optimize = b.standardOptimizeOption(.{}),
        .imports = &.{.{ .name = "cmoon-encore", .module = encore_module }},
    });
    cmoon_gfx_module.addImport("vulkan", makeVulkanModule(b, encore_module));
}

fn makeVulkanModule(
    b: *std.Build,
    encore_module: *std.Build.Module)
    ?*std.Build.Module 
{
    const registry_path = b.path("vk.xml");
    const video_path = b.path("video.xml");

    const generator_module = b.createModule(.{
        .root_source_file = b.path("tools/vulkan/main.zig"),
        .target = b.standardTargetOptions(.{}), 
        .optimize = b.standardOptimizeOption(.{}),
        .imports = &.{.{ .name = "cmoon-encore", .module = encore_module }},
    });
    const generator_exe = b.addExecutable(.{
        .name = "vulkan-zig-generator",
        .root_module = generator_module,
    });
    b.installArtifact(generator_exe);

    const vk_generate_cmd = b.addRunArtifact(generator_exe);
    vk_generate_cmd.addArg("--video");
    vk_generate_cmd.addFileArg(video_path);
    vk_generate_cmd.addFileArg(registry_path);

    const vk_zig = vk_generate_cmd.addOutputFileArg("vulkan.zig");
    const vk_zig_install_step = b.addInstallFile(vk_zig, "source/vulkan.zig");
    b.getInstallStep().dependOn(&vk_zig_install_step.step);
    return b.addModule("vulkan", .{ .root_source_file = vk_zig });
}
