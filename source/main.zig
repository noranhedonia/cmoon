const std = @import("std");
const builtin = @import("builtin");
const Sorceress = @import("sorceress");

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
        .page_size_in_use = 0,
        .thread_count = 0,
        .fiber_count = 256,
        .frames_in_flight = 3,
        .log2_work_queue_size = 11,
        .minimum_fibers_per_thread = 8,
    };
    std.debug.print("begin", .{});
    try Sorceress.main(&hints, mainCynicMoon, null, 256*1024);
    std.debug.print("end", .{});
}
