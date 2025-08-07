const std = @import("std");
const builtin = @import("builtin");
const Sorceress = @import("sorceress");

pub const pw = @import("./pw-impl.zig"); // pipewire
pub const wl = @import("./wl-impl.zig"); // wayland
pub const vk = @import("./vk-impl.zig"); // vulkan

pub fn mainCynicMoon(sorceress: *Sorceress, userdata: ?*anyopaque) void {
    _ = sorceress;
    _ = userdata;
    std.debug.print("uwuwuw", .{});
}

pub fn main() !void {
    const hints: Sorceress.Hints = .{
        .engine_name = "sorceress",
        .main_name = "cynicmoon",
        .build_engine_ver = 0x01, // TODO
        .build_main_ver = 0x01, // TODO
        .memory_budget = 0, // read from host total ram
        .drifter_region_array_size = 0, // calculate from budget
        .target_thread_count = 0,
        .log2_fiber_count = 8, // 256
        .log2_work_queue_size = 11, // 2048
    };
    std.debug.print("begin", .{});
    try Sorceress.main(&hints, mainCynicMoon, null, 64*1024);
    std.debug.print("end", .{});
}
