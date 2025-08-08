const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // TODO add `test` step and `docs` step, pass them as arguments so other modules can emit their tests/documentation
    // TODO if host has a LaTeX distribution installed, emit the technical documentation too via `docs`

    const cynicmoon_module = b.addModule("cynicmoon", .{ 
        .root_source_file = b.path("source/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sorceress_module = makeSorceressModule(b, target, optimize);
    cynicmoon_module.addImport("sorceress", sorceress_module);

    cynicmoon_module.addImport("pipewire", b.createModule(.{
        .root_source_file = b.path("tools/pipewire/pipewire.zig"),
        .target = target,
        .optimize = optimize,
    }));
    cynicmoon_module.addImport("xkbcommon", b.createModule(.{
        .root_source_file = b.path("tools/xkb/xkbcommon.zig"),
        .target = target,
        .optimize = optimize,
    }));
    //cynicmoon_module.addImport("wayland", makeWaylandModule(b, target, optimize, sorceress_module));
    cynicmoon_module.addImport("vulkan", makeVulkanModule(b, target, optimize, sorceress_module));

    // the game application
    const cynicmoon_exe = b.addExecutable(.{
        .name = "cynicmoon",
        .root_module = cynicmoon_module,
    });
    b.installArtifact(cynicmoon_exe);

    const cynicmoon_run_cmd = b.addRunArtifact(cynicmoon_exe);
    cynicmoon_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| { cynicmoon_run_cmd.addArgs(args); }

    const cynicmoon_run_step = b.step("run", "Run CynicMoon");
    cynicmoon_run_step.dependOn(&cynicmoon_run_cmd.step);
}

pub fn makeSorceressModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const asm_cpu = switch (target.result.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "aarch64",
        .riscv64 => "rv64gc",
        .wasm32, .wasm64 => "wasm",
        else => std.debug.panic("Unsupported CPU: {s}", .{ @tagName(target.result.cpu.arch) }),
    };
    const asm_os = switch (target.result.cpu.arch) {
        .aarch64 => "aapcs", else => switch(target.result.os.tag) {
            .windows => "ms", 
            .freestanding => "free",
            else => "sysv",
        },
    };
    const asm_abi = switch (target.result.os.tag) {
        .macos, .ios, => "macho",
        .windows, => "pe",
        .freestanding, => "wasi",
        else => "elf",
    };
    var asm_path_buf: [100]u8 = undefined; 
    const asm_path = std.fmt.bufPrint(&asm_path_buf, "source/sorceress/fcontext-{s}-{s}-{s}.s", .{ asm_cpu, asm_os, asm_abi })
        catch |err| std.debug.panic("Path formatting for assembly failed: {}", .{err});

    const sorceress_module = b.addModule("sorceress", .{
        .root_source_file = b.path("source/sorceress/impl.zig"),
        .target = target, .optimize = optimize,
    });
    sorceress_module.addAssemblyFile(b.path(asm_path));
    return sorceress_module;
}

pub const GenerateProtocolsOptions = struct {
    output_directory_name: ?[]const u8,
    output_compat_name: ?[]const u8 = null,
    source_files: []const std.Build.LazyPath,
    interface_versions: []const InterfaceVersion = &.{},
    imports: []const Import,

    pub const InterfaceVersion = struct {
        interface: []const u8,
        version: u32,
    };
    pub const Import = struct {
        file: std.Build.LazyPath,
        import_string: []const u8,
    };
};
pub const GenerateProtocolsResult = struct {
    output_directory: ?std.Build.LazyPath,
    output_compat_file: ?std.Build.LazyPath,
};

/// Implements the Wayland protocol scanner, parses xmls of protocols to create Zig 
/// bindings and defines compatibility layers for libwayland-client.so.0 as we need 
/// it for using the Vulkan surface and swapchain. The xml files of protocols used 
/// within this application is included in the repository.
///
/// This tool is a modified version of shimizu by geemili:
/// https://git.sr.ht/~geemili/shimizu
pub fn makeWaylandModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sorceress_module: *std.Build.Module,
) *std.Build.Module {
    const wayland_wire_module = b.createModule(.{ .root_source_file = b.path("tools/wayland/wire.zig") });
    const scanner_exe = b.addExecutable(.{
        .name = "wayland-zig-scanner",
        .root_source_file = b.path("tools/wayland/scanner.zig"),
        .target = b.graph.host,
    });
    scanner_exe.root_module.addImport("sorceress", sorceress_module);
    b.installArtifact(scanner_exe);
    const scanner_generate_cmd = b.addRunArtifact(scanner_exe);

    const wayland_protocols_generate_options = GenerateProtocolsOptions{
        .output_directory_name = "source/wayland-protocols",
        .output_compat_name = "source/wayland-protocols-compat.zig",
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
            b.path("protocols/river-control-unstable-v1.xml"),
            b.path("protocols/river-layout-v3.xml"),
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
        .interface_versions = &.{},
        .imports = &.{},
    };
    for (wayland_protocols_generate_options.source_files) |source_file| { scanner_generate_cmd.addFileArg(source_file); }
    var wayland_protocols_generate_result: GenerateProtocolsResult = .{ 
        .output_directory = null, 
        .output_compat_file = null 
    };
    for (wayland_protocols_generate_options.interface_versions) |interface_version|
        scanner_generate_cmd.addArgs(&.{ "-v", interface_version.interface, b.fmt("{d}", .{ interface_version.version }), });

    for (wayland_protocols_generate_options.imports) |import| {
        scanner_generate_cmd.addArg("-i");
        scanner_generate_cmd.addFileArg(import.file);
        scanner_generate_cmd.addArg(import.import_string);
    }
    if (wayland_protocols_generate_options.output_directory_name) |dir_name| {
        scanner_generate_cmd.addArg("-o");
        wayland_protocols_generate_result.output_directory = scanner_generate_cmd.addOutputDirectoryArg(dir_name);
    }
    if (wayland_protocols_generate_options.output_compat_name) |file_name| {
        scanner_generate_cmd.addArg("-c");
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

/// Generates Zig bindings of the Vulkan headers via vk.xml and video.xml. 
/// A copy of both vk.xml and video.xml are included in this repository.
///
/// This tool is a modified version of vulkan-zig by Snektron: 
/// https://github.com/Snektron/vulkan-zig
///
/// The most recent Vulkan XML API registry can be obtained from 
/// https://github.com/KhronosGroup/Vulkan-Docs/blob/master/xml/vk.xml,
/// and the most recent LunarG Vulkan SDK version can be found at
/// $VULKAN_SDK/x86_64/share/vulkan/registry/vk.xml.
pub fn makeVulkanModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sorceress_module: *std.Build.Module,
) *std.Build.Module {
    const output_source_path_name = "source/vulkan.zig";
    const output_full_path_name = "zig-out/" ++ "source/vulkan.zig";
    var already_exists = true;
    {
        var cwd = std.fs.cwd();
        cwd.access("zig-out/" ++ output_source_path_name, .{}) catch { already_exists = false; };
    }
    const vulkan_zig_file: std.Build.LazyPath = if (already_exists) blk: {
        break :blk b.path(output_full_path_name);
    } else blk: {
        const registry_path = b.path("vk.xml");
        const video_path = b.path("video.xml");

        const generator_module = b.createModule(.{
            .root_source_file = b.path("tools/vulkan/main.zig"),
            .target = target, 
            .optimize = optimize,
            .imports = &.{.{ .name = "sorceress", .module = sorceress_module }},
        });
        const generator_exe = b.addExecutable(.{
            .name = "vulkan-zig-generator",
            .root_module = generator_module,
        });
        b.installArtifact(generator_exe);

        const generate_cmd = b.addRunArtifact(generator_exe);
        generate_cmd.addArg("--video");
        generate_cmd.addFileArg(video_path);
        generate_cmd.addFileArg(registry_path);

        const vulkan_zig = generate_cmd.addOutputFileArg("vulkan.zig");
        const vulkan_zig_install_step = b.addInstallFile(vulkan_zig, output_source_path_name);
        b.getInstallStep().dependOn(&vulkan_zig_install_step.step);
        break :blk vulkan_zig;
    };
    return b.addModule("vulkan", .{ .root_source_file = vulkan_zig_file });
}
