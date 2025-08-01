const std = @import("std");
const builtin = @import("builtin");

pub const parsers = struct {
    pub const xml = @import("./parsers/xml.zig");
};
pub const work = @import("./work.zig");

pub fn dynLibOpen(lib_name: []const u8) !std.DynLib {
    return std.DynLib.open(lib_name) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.log.err("Missing system library: `{s}`.", .{lib_name});
                return error.LibraryNotFound;
            }, else => return err,
        }
    };
}

pub const BedrockHints = struct {
    engine_name: [*:0]const u8,
    main_name: [*:0]const u8,
    engine_build_ver: u32,
    main_build_ver: u32,

    memory_budget: usize,
    memory_page_size: u32,
    default_stack_size: u32,
    main_stack_size: u32,
    worker_thread_count: u32,
    fiber_count: u32,
    log2_work_queue_size: u32,
    limit_worker_threads_to_cpu_count: bool,
    debug_instruments: bool,
    hugetlb_entries: bool,
};

pub const BedrockHost = struct {
    hints: BedrockHints,
    timer_start: u64,
    total_ram: usize,
    page_size: u32,
    hugepage_size: u32,
    cpu_thread_count: u32,
    cpu_cores_count: u32,
    cpu_package_count: u32,
};

pub const BedrockFrameworkFn = fn (host: *const BedrockHost, userdata: ?*anyopaque) void;

pub fn initFramework(hints: *const BedrockHints, entrypoint: BedrockFrameworkFn, userdata: ?*anyopaque) void {
    _ = hints;
    _ = entrypoint;
    _ = userdata;
}
