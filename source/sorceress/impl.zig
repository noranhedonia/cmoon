/// Defines a framework that is a hard dependency for everything outside of this module.
/// Generally everything that wants a pointer to this struct as an argument requires
/// the functionality that is available only within the context of a running framework.
///
/// Most of the submodules here is self contained, Sorceress is used as a namespace for them. 
const Sorceress = @This();

host: Host,
internal: Internal,

// ./assets/
pub const xml = @import("./xml.zig");
// ./compute/
pub const bits = @import("./bits.zig");
// ./datastructures/
pub const Mpmc = @import("./mpmc.zig").Mpmc;

const std = @import("std");
const builtin = @import("builtin");
const AtomicRmwOp = std.builtin.AtomicRmwOp;
const AtomicOrder = std.builtin.AtomicOrder;

/// User provided information to assemble the framework. After hints are processed, 
/// defaults or limits are provided and Sorceress.hints reflects the actual state
/// of the framework during application runtime.
pub const Hints = struct {
    engine_name: []const u8,
    main_name: []const u8,
    build_engine_ver: u32,
    build_main_ver: u32,
    memory_budget: usize, // limit for the memory mapping
    drifter_region_array_size: u32, // region structs for drifters is preallocated
    target_thread_count: u16, // clamped 1..Host.cpu.thread_count
    log2_fiber_count: u8, // fiber count must be a power of 2
    log2_work_queue_size: u8, // work queue size must be a power of 2
};
/// Framework provided information about the host system, after hints are processed.
pub const Host = struct {
    engine_name: []const u8,
    app_name: []const u8,
    build_engine_ver: u32,
    build_main_ver: u32,
    timer_start: u64,
    thread_count: u32,
    fiber_count: u32,
    fiber_mask: u32,
    fiber_query_hint: u32,
    memory_budget: usize,
    memory_roots: usize,
    memory_total_ram: usize,
    memory_page_size_in_use: u32,
    memory_page_size: u32,
    memory_hugepage_size: u32,
    cpu_thread_count: u32,
    cpu_core_count: u32,
    cpu_package_count: u32,
};

pub const PfnWork = *const fn (work: ?*anyopaque) void;

pub const WorkSubmit = struct {
    procedure: PfnWork,
    argument: ?*anyopaque,
    name: []const u8,
};
pub const WorkChain = *usize;

pub const FrameworkError = error {
    InitializationFailed,
    OutOfMemory,
};

/// We represent mapped memory using blocks of 2MiB in size (one hugepage on most platforms).
pub const BLOCK_SIZE = (2*1024*1024);

pub fn main(
    hints: *const Hints, 
    procedure: *const fn (*Sorceress, ?*anyopaque) void, 
    userdata: ?*anyopaque,
    stack_size: u32,
) !void {
    const sorceress: *Sorceress = try Internal.initFramework(hints);
    defer switch (builtin.os.tag) {
        .windows => _ = std.os.windows.kernel32.VirtualFree(@ptrCast(sorceress), 0, std.os.windows.MEM_RELEASE),
        else => std.posix.munmap(@alignCast(sorceress.internal.map)),
    };
    const application: Internal.Application = .{
        .procedure = procedure,
        .userdata = userdata,
        .sorceress = sorceress,
    };
    const work: WorkSubmit = .{
        .procedure = Internal.runApplicationMain,
        .argument = @constCast(&application),
        .name = "sorceress::main",
    };
    sorceress.submit(1, @ptrCast(&work), stack_size, null);
    _ = Internal.dirtyDeedsDoneDirtCheap(@ptrCast(&sorceress.internal.tls[0]));
}

/// Submits work into the system and yields. This will not return until submitted work is done.
pub inline fn commit(sorceress: *@This(), count: u32, work: [*]const WorkSubmit, stack_size: u32) void {
    var chain: ?WorkChain = null;
    sorceress.submit(count, work, stack_size, &chain);
    sorceress.yield(chain);
}

pub fn submit(
    sorceress: *@This(), 
    count: u32, 
    work: [*]const WorkSubmit, 
    stack_size: u32,
    out_chain: ?*?WorkChain,
) void {
    var chain: ?WorkChain = null;
    if (out_chain != null) chain = sorceress.acquireChain(count);

    for (0..count) |idx| {
        const job: Internal.Job = .{
            .submit = work[idx],
            .stack_size = @intCast(stack_size),
            .chain = chain,
        };
        const success = sorceress.internal.work_queue.enqueue(&job);
        std.debug.assert(success);
    }
    if (out_chain) |out| out.* = chain.?;
}

pub fn yield(sorceress: *@This(), chain: ?WorkChain) void {
    var wait_value: usize = 0;
    if (chain) |wait| {
        wait_value = @atomicLoad(usize, wait, AtomicOrder.acquire);
        std.debug.assert(wait_value != Internal.Fiber.INVALID);
    }
    if (wait_value != 0) {
        var tls: *Internal.Tls = &sorceress.internal.tls[Internal.worker_thread_index];
        const fiber: *Internal.Fiber = &sorceress.internal.fibers[tls.fiber_in_use];
        fiber.chain = chain;
        tls.fiber_old = tls.fiber_in_use | Internal.Tls.Flags.ToWait;
        tls = Internal.yieldFiber(sorceress, tls, &fiber.context);
        Internal.updateFreeAndWaiting(tls);
    }
    if (chain) |wait| @atomicStore(usize, wait, Internal.Fiber.INVALID, AtomicOrder.release);
}

pub fn acquireChain(sorceress: *@This(), initial_value: usize) WorkChain {
    while (true) {
        for (0..sorceress.host.fiber_count) |at| {
            const index: u32 = (Internal.worker_thread_index * sorceress.host.fiber_query_hint + @as(u32, @intCast(at))) & sorceress.host.fiber_mask;
            const lock: *usize = &sorceress.internal.locks[index];

            if (@atomicLoad(usize, lock, AtomicOrder.unordered) == Internal.Fiber.INVALID) {
                if (@cmpxchgWeak(usize, lock, Internal.Fiber.INVALID, initial_value, 
                    AtomicOrder.monotonic, AtomicOrder.monotonic) == null)
                {
                    return @ptrCast(lock);
                }
            }
        }
    }
    unreachable;
}

pub inline fn signalChain(chain: WorkChain) usize {
    return @atomicRmw(usize, chain, AtomicRmwOp.Sub, 1, AtomicOrder.release);
}

pub inline fn releaseChain(chain: WorkChain) void {
    @atomicStore(usize, chain, 0, AtomicOrder.unordered);
}

pub fn getThreadIndex() u32 {
    return Internal.worker_thread_index;
}

pub fn getSp() usize {
    var dummy: u8 = 0;
    return @intFromPtr(&dummy);
}

pub fn driftAlloc(sorceress: *@This(), stride: usize, n: u32, alignment: u32) !*anyopaque {
    const tls: *Internal.Tls = sorceress.internal.tls[Internal.worker_thread_index];
    const fiber: *Internal.Fiber = sorceress.internal.fibers[tls.fiber_in_use];
    const drifter: *Internal.Drifter = fiber.drifter;

    const memory: *anyopaque = drifter.allocate(sorceress, stride, n, alignment) catch |err| {
        std.log.err("Could not allocate {} bytes using drifter for {s}: {s}.", .{ 
            stride * n, fiber.work.submit.name, @errorName(err),
        });
        return err;
    };
    return memory;
}

pub fn driftUnshift(sorceress: *@This()) void {
    const tls: *Internal.Tls = sorceress.internal.tls[Internal.worker_thread_index];
    const fiber: *Internal.Fiber = sorceress.internal.fibers[tls.fiber_in_use];
    const drifter: *Internal.Drifter = fiber.drifter;

    drifter.tail_cursor = drifter.allocate(
        sorceress, @sizeOf(Internal.Drifter.Cursor), 1, @alignOf(Internal.Drifter.Cursor),
    ) catch |err| {
        std.log.err("Could not allocate a drifter cursor for {s}: {s}", .{ fiber.work.submit.name, @errorName(err) });
        std.process.abort();
    };
    drifter.tail_cursor.?.* = .{
        .prev = drifter.tail_cursor,
        .tail_region = drifter.tail_region,
        .offset = drifter.tail_region.offset,
        .stack = drifter.tail_region.stack,
    };
}

pub fn driftShift(sorceress: *@This()) void {
    const tls: *Internal.Tls = sorceress.internal.tls[Internal.worker_thread_index];
    const fiber: *Internal.Fiber = sorceress.internal.fibers[tls.fiber_in_use];
    const drifter: *Internal.Drifter = fiber.drifter;

    const tail_cursor: *Internal.Drifter.Cursor = drifter.tail_cursor.?;
    drifter.restoreFromCursor(sorceress, tail_cursor);
    drifter.tail_cursor = tail_cursor.prev;
}

const Internal = struct {
    /// Every thread will set an unique 0..thread_count value during initialization.
    threadlocal var worker_thread_index: u32 = std.math.maxInt(u32);

    work_queue: Mpmc(Job),
    ends: [*]WorkSubmit,
    tls: [*]Tls,
    threads: [*]std.Thread,
    fibers: [*]Fiber,
    waiting: [*]usize, // atomic
    locks: [*]usize, // atomic
    free: [*]usize, // atomic
    bitmap: [*]u8, // atomic
    commitment: usize, // atomic
    sync: usize, // atomic
    regions: [*]Drifter.Region,
    region_tail: usize, // atomic
    map: MapOs,

    const Tls = struct {
        sorceress: *Sorceress,
        home_context: *anyopaque,
        fiber_in_use: u32,
        fiber_old: u32,

        const Flags = struct {
            const InUse = 0;
            const ToFree = 0x40000000;
            const ToWait = 0x80000000;
            const Mask = 0xcfffffff;
        };
    };
    const MapOs: type = switch (builtin.os.tag) { .windows => ?std.os.windows.LPVOID, else => []const u8, };

    const Job = struct {
        submit: WorkSubmit,
        stack_size: usize, 
        chain: ?WorkChain,
    };

    const Fiber = struct {
        work: Job,
        chain: ?WorkChain,
        context: *anyopaque,
        drifter: *Drifter,
        cursor: Drifter.Cursor,
        const INVALID = std.math.maxInt(u32);
    };

    /// Implemented in assembly, ofc/nfc - original/new fiber context.
    extern fn jump_fcontext(ofc: **anyopaque, nfc: *anyopaque, vp: usize, preserve_fpu: c_int) usize;
    /// Implemented in assembly, sp - top of stack pointer.
    extern fn spawn_fcontext(sp: *anyopaque, stack_size: usize, procedure: usize) *anyopaque;

    const Application = struct {
        procedure: *const fn (*Sorceress, ?*anyopaque) void, 
        userdata: ?*anyopaque,
        sorceress: *Sorceress,
    };

    fn dirtyDeedsDoneDirtCheap(raw_tls: ?*anyopaque) ?*anyopaque {
        var tls: *Tls = @ptrCast(@alignCast(raw_tls.?));
        const sorceress: *Sorceress = tls.sorceress;
        worker_thread_index = @intCast(@atomicRmw(usize, &sorceress.internal.sync, AtomicRmwOp.Sub, 1, AtomicOrder.release) - 1);
        // wait until all threads are ready
        while (@atomicLoad(usize, &sorceress.internal.sync, AtomicOrder.acquire) > 0) {}
        tls.fiber_old = Fiber.INVALID;
        tls = yieldFiber(sorceress, tls, &tls.home_context);
        updateFreeAndWaiting(tls);
        return null;
    }

    fn runApplicationMain(raw_work: ?*anyopaque) void {
        const work: *const Application = @ptrCast(@alignCast(raw_work.?));
        work.procedure(work.sorceress, work.userdata);
        // won't return until the application exits
        for (0..work.sorceress.host.thread_count) |idx| {
            const end: *WorkSubmit = &work.sorceress.internal.ends[idx];
            end.procedure = joinWorkerThread;
            end.argument = work.sorceress;
            end.name = "sorceress::ends";
        }
        work.sorceress.commit(work.sorceress.host.thread_count, work.sorceress.internal.ends, 2048);
        unreachable;
    }

    fn joinWorkerThread(raw_sorceress: ?*anyopaque) void {
        const sorceress: *Sorceress = @ptrCast(@alignCast(raw_sorceress.?));
        const tls: *Tls = &sorceress.internal.tls[worker_thread_index];
        const fiber: *Fiber = &sorceress.internal.fibers[tls.fiber_in_use];

        if (tls == &sorceress.internal.tls[0])
            for (1..sorceress.host.thread_count) |idx| std.Thread.join(sorceress.internal.threads[idx]);
        tls.fiber_old = tls.fiber_in_use | Tls.Flags.ToFree;

        std.debug.assert(fiber.context != tls.home_context);
        _ = jump_fcontext(&fiber.context, tls.home_context, @intCast(@intFromPtr(tls)), 1);
        unreachable;
    }

    fn updateFreeAndWaiting(tls: *Tls) void {
        if (tls.fiber_old == Fiber.INVALID) return;
        const fiber_idx: u32 = tls.fiber_old & Tls.Flags.Mask;

        // A thread that added a fiber to the free list is the same as the one freeing it
        if ((tls.fiber_old & Tls.Flags.ToFree) != 0)
            @atomicStore(usize, &tls.sorceress.internal.free[fiber_idx], @intCast(fiber_idx), AtomicOrder.unordered);
        // Wait threshold needs to be thread synced, so a CPU fence is welcome
        if ((tls.fiber_old & Tls.Flags.ToWait) != 0)
            @atomicStore(usize, &tls.sorceress.internal.waiting[fiber_idx], @intCast(fiber_idx), AtomicOrder.release);
        tls.fiber_old = Fiber.INVALID;
    }

    fn theWork(raw_tls: usize) void {
        var tls: *Tls = @ptrFromInt(raw_tls);
        const sorceress: *Sorceress = tls.sorceress;
        const fiber: *Fiber = &sorceress.internal.fibers[tls.fiber_in_use];
        updateFreeAndWaiting(tls);

        fiber.work.submit.procedure(fiber.work.submit.argument);
        if (fiber.work.chain) |chain| _ = @atomicRmw(usize, chain, AtomicRmwOp.Sub, 1, AtomicOrder.release);
        fiber.drifter.restoreFromCursor(sorceress, &fiber.cursor);
        fiber.drifter.tail_cursor = fiber.cursor.prev;

        // The thread may have changed between yields.
        tls = &sorceress.internal.tls[worker_thread_index];
        tls.fiber_old = tls.fiber_in_use | Tls.Flags.ToFree;
        _ = yieldFiber(sorceress, tls, &fiber.context);
        unreachable;
    }

    fn findFreeFiber(sorceress: *Sorceress) u32 {
        for (0..sorceress.host.fiber_count) |at| {
            const index: u32 = (Internal.worker_thread_index * sorceress.host.fiber_query_hint + @as(u32, @intCast(at))) & sorceress.host.fiber_mask;
            const free: *usize = &sorceress.internal.free[index];

            // Double lock should help CPUs that have a weak memory model, like ARM.
            var fiber_free = @atomicLoad(usize, free, AtomicOrder.unordered);
            if (fiber_free >= Fiber.INVALID) continue;

            fiber_free = @atomicLoad(usize, free, AtomicOrder.acquire);
            if (fiber_free >= Fiber.INVALID) continue;

            if (@cmpxchgWeak(usize, free, fiber_free, Fiber.INVALID, AtomicOrder.release, AtomicOrder.monotonic) == null) 
                return @intCast(fiber_free);
        }
        return Fiber.INVALID;
    }

    fn queryThroughFibers(sorceress: *Sorceress) u32 { // TODO resolve drifter
        for (0..sorceress.host.fiber_count) |at| {
            const index: u32 = (Internal.worker_thread_index * sorceress.host.fiber_query_hint + @as(u32, @intCast(at))) & sorceress.host.fiber_mask;
            const waiting: *usize = &sorceress.internal.waiting[index];
            
            // Double lock should help CPUs that have a weak memory model, like ARM.
            var fiber_waiting: usize = @atomicLoad(usize, waiting, AtomicOrder.unordered);
            if (fiber_waiting >= Fiber.INVALID) continue;

            fiber_waiting = @atomicLoad(usize, waiting, AtomicOrder.acquire);
            if (fiber_waiting >= Fiber.INVALID) continue;

            const fiber: *Fiber = &sorceress.internal.fibers[fiber_waiting];
            if (fiber.chain) |chain| // check if finished
                if (@atomicLoad(usize, chain, AtomicOrder.unordered) != 0) continue;

            if (@cmpxchgWeak(usize, waiting, fiber_waiting, Fiber.INVALID, AtomicOrder.release, AtomicOrder.monotonic) == null) {
                // TODO resolve drifter
                return @intCast(fiber_waiting);
            }
        }
        var job: Job = undefined;
        var fiber_index: u32 = Fiber.INVALID;

        if (!sorceress.internal.work_queue.dequeue(&job)) 
            return fiber_index;
        while (fiber_index == Fiber.INVALID) fiber_index = findFreeFiber(sorceress);

        const fiber: *Fiber = &sorceress.internal.fibers[fiber_index];
        //const drifter: ?*Drifter = null; // TODO resolve drifter inheritance
        //if (!drifter) TODO resolve drifter
        //fiber.drifter = drifter.?;

        fiber.cursor.tail_region = fiber.drifter.tail_region;
        fiber.cursor.offset = fiber.drifter.tail_region.offset;
        fiber.cursor.stack = fiber.drifter.tail_region.stack;
        fiber.cursor.prev = fiber.drifter.tail_cursor;
        fiber.drifter.tail_cursor = &fiber.cursor;
        fiber.work = job;

        const stack: *anyopaque = fiber.drifter.createStack(sorceress, job.stack_size) catch |err| {
            std.log.err("Creating a fiber stack of size {} failed for job {s}: {s}.", .{ 
                job.stack_size, job.submit.name, @errorName(err),
            });
            std.process.abort();
        };
        fiber.context = spawn_fcontext(stack, job.stack_size, @intFromPtr(&theWork));
        return fiber_index;
    }

    fn yieldFiber(sorceress: *Sorceress, tls: *Tls, context: **anyopaque) *Tls {
        var wait_chain: ?WorkChain = null;

        if (tls.fiber_old != Fiber.INVALID) {
            const fiber: *Fiber = &sorceress.internal.fibers[tls.fiber_old & Tls.Flags.Mask];

            if (tls.fiber_old & Tls.Flags.ToWait != 0) {
                wait_chain = fiber.chain;
                // TODO resolve drifter
            } else {
                // TODO resolve drifter
            }
        }
        while (true) {
            const fiber_index: u32 = queryThroughFibers(sorceress); // TODO resolve drifter
            // The fiber will be invalid if there are no waiting fibers and there are no new jobs.
            if (fiber_index != Fiber.INVALID) {
                const fiber: *Fiber = &sorceress.internal.fibers[fiber_index];

                tls.fiber_in_use = fiber_index;
                std.debug.assert(context.* != fiber.context);
                return @ptrFromInt(jump_fcontext(context, fiber.context, @intFromPtr(tls), 1));
            }
            // Race condition fix. Context needs to wait until a set of jobs are done. 
            // The jobs finish before a new context to swap to is found - there's no new jobs. 
            // The context swap code deadlocks looking for a new job to swap to, when no new 
            // jobs may arrive. Meanwhile the "to be swapped" context is waiting to be ran,
            // but cannot as it hasn't been swapped out yet (to be picked up by the wait list).
            if (wait_chain) |chain| {
                const count = @atomicLoad(usize, chain, AtomicOrder.unordered);
                if (count == 0) {
                    // tls.fiber_in_use still points to the "to waitlist" fiber
                    tls.fiber_old = Fiber.INVALID;
                    return tls;
                }
            }
        }
        unreachable;
    }

    /// Holds state that can migrate between threads during yields.
    const Drifter = struct {
        head: Region,
        tail_region: *Region,
        tail_cursor: ?*Cursor,

        const Region = struct {
            next: ?*Region,
            at: usize,
            offset: usize,
            alloc: usize,
            stack: usize,
        };
        const Cursor = struct {
            prev: ?*Cursor,
            tail_region: ?*Region,
            offset: usize,
            stack: usize,
        };

        fn allocate(
            drifter: *@This(),
            sorceress: *Sorceress, 
            stride: usize,
            n: u32,
            alignment: u32,
        ) FrameworkError!*anyopaque {
            var tail: *Region = drifter.tail_region; 
            var aligned = std.mem.alignForward(usize, tail.offset, alignment);
            const size = stride * n;

            if (aligned + size > tail.alloc - tail.stack) {
                var next: ?*Region = &drifter.head;
                while (next) |region| {
                    if (region.next == tail) 
                        break;
                    aligned = std.mem.alignForward(usize, region.offset, alignment);
                    if (aligned + size <= region.alloc - region.stack) {
                        region.offset = aligned + size;
                        return @ptrFromInt(@intFromPtr(sorceress) + region.at + aligned);
                    }
                    next = region.next;
                }
                tail = try drifter.expandRegions(sorceress, size, tail);
            }
            tail.offset = aligned + size;
            return @ptrFromInt(@intFromPtr(sorceress) + tail.at + aligned);
        }

        fn createStack(
            drifter: *@This(),
            sorceress: *Sorceress, 
            stack_size: usize,
        ) !*anyopaque {
            var tail: *Region = drifter.tail_region;
            // For existing stack spaces we can read the stack pointer and possibly fit it
            // or expand upon the existing stack, this way avoiding any allocations.
            const spawn_fcontext_padding = comptime switch (builtin.os.tag) {
                .windows => 512, else => 256, // check spawn_fcontext assembly per impl
            };
            const top_of_stack_alignment = comptime 16;
            // spawn_fcontext requires the top of the stack space
            var top_of_stack: usize = @intFromPtr(sorceress) + tail.at + tail.alloc;
            var new_stack_space = std.mem.alignForward(usize, stack_size, top_of_stack_alignment);

            if (tail.stack != 0) {
                const sp: usize = getSp() - spawn_fcontext_padding;
                const offset_from_top = std.mem.alignForward(usize, top_of_stack - sp, top_of_stack_alignment);
                new_stack_space = @max(tail.stack, offset_from_top + stack_size);
                top_of_stack -= offset_from_top;
            }
            if (tail.offset + new_stack_space > tail.alloc) {
                tail = try drifter.expandRegions(sorceress, stack_size, tail);
                top_of_stack = @intFromPtr(sorceress) + tail.at + tail.alloc;
                new_stack_space = stack_size;
            }
            tail.stack = new_stack_space;
            return @ptrFromInt(top_of_stack);
        }

        fn expandRegions(
            drifter: *@This(), 
            sorceress: *Sorceress,
            request: usize,
            tail_region: *Region,
        ) !*Region {
            const block_aligned = std.mem.alignForward(usize, request, BLOCK_SIZE);
            const block_at = acquireBlocks(sorceress, block_aligned, sorceress.host.memory_roots);
            if (block_at == 0) 
                return FrameworkError.OutOfMemory;

            var tail: *Region = tail_region;
            if (tail.next) |next| {
                tail = next; 
            } else {
                const new_region_index = @atomicRmw(usize, &sorceress.internal.region_tail, AtomicRmwOp.Add, 1, AtomicOrder.release);
                tail = &sorceress.internal.regions[new_region_index];
                drifter.tail_region.next = tail;
            }
            tail.at = block_at;
            tail.alloc = block_aligned;
            drifter.tail_region = tail;
            return tail;
        }

        fn restoreFromCursor(
            drifter: *@This(), 
            sorceress: *Sorceress,
            cursor: *const Cursor,
        ) void {
            drifter.tail_region = cursor.tail_region orelse return;
            drifter.tail_region.offset = cursor.offset;
            drifter.tail_region.stack = cursor.stack;
            var next = drifter.tail_region.next;
            while (next) |region| {
                if (region.alloc == 0) 
                    break;
                releaseBitmapRange(sorceress.internal.bitmap, region.at, region.alloc);
                // the linked list of regions is preserved
                region.at = 0;
                region.alloc = 0;
                region.offset = 0;
                region.stack = 0;
                next = region.next;
            }
        }
    };

    // Translates an offset value, representing mapped memory, between spaces.
    inline fn atIndexFromPosition(at: usize) usize { return at >> 3; }
    inline fn atPositionFromIndex(at: usize) usize { return at << 3; }
    inline fn atBlockFromPosition(at: usize) usize { return at << 21; }
    inline fn atPositionFromBlock(at: usize) usize { return at >> 21; }
    inline fn atIndexFromRange(at: usize) usize { return at >> 24; }
    inline fn atRangeFromIndex(at: usize) usize { return at << 24; }

    /// Updates the bitmap for a given range of blocks.
    fn opBitmap(
        bitmap: [*]u8, 
        offset: usize, 
        range: usize, 
        comptime invert: bool,
        comptime op: AtomicRmwOp, 
        comptime order: AtomicOrder
    ) void {
        if (range == 0) return;
        const position = atPositionFromBlock(offset);
        const head_index = atIndexFromPosition(position);
        const count = 1 + atIndexFromRange(range);
        const tail_index = head_index + count - 1;

        var bitmask: u8 = ~((@as(u8, 1) << @as(u3, @intCast(position)) & 0x07) -% 1);
        for (0..count) |at| {
            const index = head_index + at;
            // XOR'ing the bitmask will leave blocks outside the range untouched.
            if (index == tail_index) bitmask ^= ~((@as(u8, 1) << (@as(u3, @intCast(position + count)) & 0x07)) - 1);
            // Set the blocks as in use (bits set to 0) or as free (bits set to 1).
            _ = @atomicRmw(u8, &bitmap[index], op, if (invert) ~bitmask else bitmask, order);
            bitmask = 0xff;
        }
    }
    /// Sets a range of blocks in mapped memory as in use.
    inline fn acquireBitmapRange(bitmap: [*]u8, offset: usize, range: usize) void {
        opBitmap(bitmap, offset, range, true, AtomicRmwOp.And, AtomicOrder.acquire);
    }
    /// Sets a range of blocks in mapped memory as free.
    inline fn releaseBitmapRange(bitmap: [*]u8, offset: usize, range: usize) void {
        opBitmap(bitmap, offset, range, false, AtomicRmwOp.Or, AtomicOrder.release);
    }

    /// A single block allocation. We don't own the memory syns and never wait on it,
    /// instead the value of sync is passed in as the ceiling for the bitmap query.
    /// If a free block is found, we write to the bitmap and double check for data races.
    fn findFreeBlock(bitmap: [*]u8, floor: usize, ceiling: usize) usize {
        // invalidate the request early
        if (floor >= ceiling) 
            return 0;

        const index = atIndexFromRange(floor);
        const range = 1 + atIndexFromRange(ceiling) - index;

        // Try until we either succeed or hit the ceiling.
        while (true) {
            var at: usize = bits.ffsBitmap(bitmap + index, range);
            
            // bits.ffs() returns a 1-based value, or 0 if no bits are set.
            // This is why later we must decrement the `at` value.
            if (at == 0) return 0;

            // The atPositionFromIndex() will align the value of `index` to byte positions.
            at += atPositionFromIndex(index) - 1;

            // We may have hit the ceiling.
            if (at >= atPositionFromBlock(ceiling)) return 0;

            const bitmask: u8 = (@as(u8, 1) << (@as(u3, @intCast(at)) & 0x07));
            const prev: u8 = @atomicRmw(u8, &bitmap[atIndexFromPosition(at)], AtomicRmwOp.And, ~bitmask, AtomicOrder.acquire);
            if ((prev & bitmask) == bitmask) 
                return atBlockFromPosition(at);
        }
        unreachable;
    }

    /// Tries to find a range of contiguous memory blocks to fulfill a larger request.
    /// If this function was called, it is assumed the caller owns the sync counter.
    /// The implementation is simple, we don't optimize for best fit or anything.
    fn findFreeRange(
        bitmap: [*]u8, 
        request: usize, 
        floor: usize, 
        ceiling: usize, 
        sync: *usize,
    ) usize {
        const range = atPositionFromBlock(request);    
        // invalidate the request early
        if (floor >= ceiling or range == 0 or (range < atPositionFromBlock((ceiling - floor)))) 
            return 0;

        const head_index = atPositionFromBlock(floor);
        const tail_index = 1 + atIndexFromRange(ceiling);

        var candidate: usize = 0;
        var current: usize = 0;

        for (head_index..tail_index) |at| {
            const byte: u8 = @atomicLoad(u8, &bitmap[at], AtomicOrder.unordered);

            if (byte == 0xff) {
                if (current == 0)
                    candidate = atPositionFromIndex(at);
                current += 8;
                if (current >= range) return atBlockFromPosition(candidate);
            } else if (byte != 0) {
                for (0..8) |bit| if (((byte >> @as(u3, @intCast(bit))) & 1) != 0) {
                    if (current == 0)
                        candidate = atPositionFromIndex(at) + bit;
                    current += 1;
                    if (current >= range) return atBlockFromPosition(candidate);
                } else {
                    @atomicStore(usize, sync, atRangeFromIndex(at), AtomicOrder.unordered);
                    current = 0;
                };
            } else {
                @atomicStore(usize, sync, atRangeFromIndex(at), AtomicOrder.unordered);
                current = 0;
            }
        }
        // Either out of memory in the budget's range, or the memory is fragmented...
        return 0;
    }

    /// Returns begin of the mapped range or 0 if no free memory is left.
    /// Will try to commit into physical memory if the initial request could not be satisfied.
    fn acquireBlocks(sorceress: *Sorceress, request: usize, roots: usize) usize {
        var commitment = @atomicLoad(usize, &sorceress.internal.commitment, AtomicOrder.unordered);
        const sync: *usize = &sorceress.internal.sync;

        while (true) {
            const sync_value = @atomicLoad(usize, sync, AtomicOrder.acquire);

            // The allocation process can be greatly simplified if only a single block of 
            // mapped memory was requested (2 MiB), that allows us to avoid locks too.
            if (request <= BLOCK_SIZE) {
                const ceiling = if (sync_value > 0) @min(sync_value, commitment) else commitment;
                const at = findFreeBlock(sorceress.internal.bitmap, roots, ceiling);
                if (at != 0) { return at; } else if (sync_value != 0) continue;
            }
            if (@cmpxchgWeak(usize, sync, 0, roots, AtomicOrder.release, AtomicOrder.monotonic) == null)
                continue; // Another thread owns the sync counter. 

            var at: usize = 0;
            // Reload the value of commitment.
            commitment = @atomicLoad(usize, &sorceress.internal.commitment, AtomicOrder.unordered);
            // This step can be skipped if we came here from the implication that there is
            // not enough free commited memory to satisfy even a minimal allocation. 
            if (request > BLOCK_SIZE) {
                at = findFreeRange(sorceress.internal.bitmap, request, roots, commitment, sync);
                if (at != 0 and at + request <= commitment) {
                    acquireBitmapRange(sorceress.internal.bitmap, at, request);
                    @atomicStore(usize, sync, 0, AtomicOrder.release);
                    return at;
                }
            }
            if (at == 0) at = commitment;
            @atomicStore(usize, sync, at, AtomicOrder.release);
            const range = request - (commitment - at);

            var success: bool = true;
            const map: MapOs = sorceress.internal.map[commitment..];
            // We must commit physical memory.
            if (range + commitment > sorceress.host.memory_budget) switch (builtin.os.tag) {
                .windows => std.os.windows.VirtualProtect(), // TODO windows stuff
                else => { 
                    std.posix.mprotect(@alignCast(@constCast(map[0..range])), std.posix.PROT.READ | std.posix.PROT.WRITE) catch |err| {
                        std.log.err("mprotect(PROT_READ | PROT_WRITE) failed to commit new resources: {s}", .{ @errorName(err) });
                        success = false;
                    };
                }
            };
            if (!success) {
                std.log.err("Can't commit physical resources for request: {} at range {}: mapped range {}-{}.", .{ request, range, commitment, commitment+range });
                return 0;
            }
            acquireBitmapRange(sorceress.internal.bitmap, at, request);
            @atomicStore(usize, &sorceress.internal.commitment, commitment + range, AtomicOrder.release);
            @atomicStore(usize, sync, 0, AtomicOrder.release);
            return at;
        }
        unreachable;
    }

    fn initFramework(hints: *const Hints) !*Sorceress {
        _ = hints;
        return FrameworkError.InitializationFailed;
    }
};
