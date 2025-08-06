/// Defines a framework that is a hard dependency for everything outside of this module.
/// Generally everything that wants a pointer to this struct as an argument requires
/// the functionality that is available only within the context of a running framework.
///
/// Most of the submodules here is self contained, Sorceress is used as a namespace for them. 
const Sorceress = @This();

host: Host,
hints: Hints,
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
    /// What page size to use for internal mapping. If 0, default is @max(Host.hugepage_size, Host.page_size).
    page_size_in_use: u32,
    /// How many system threads to run jobs on. If 0, default is Host.cpu_thread_count. Clamped to a range of 1..Host.cpu_thread_count.
    thread_count: u32,
    /// The number of fibers running is known at initialization time. If 0, default is 64.
    fiber_count: u16,
    /// External systems may use this hint for buffering per-frame data. Clamped to a range of 2..
    frames_in_flight: u8,
    /// The work queue must have a size that is a power of two: (1 << log2_work_queue_size).
    log2_work_queue_size: u8,
    /// How many preallocated regions for drifter allocators. If 0, default is log2(nextPow2(memory_ram))-1.
    log2_region_buffer_size: u8,
    /// Update the fiber count to use a minimum of N fibers per worker thread. If 0, default is 4.
    minimum_fibers_per_thread: u8,
};
/// Framework provided information about the host system.
pub const Host = struct {
    timer_start: u64,
    memory_ram: usize,
    page_size: u32,
    hugepage_size: u32,
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
) FrameworkError!void {
    const sorceress: *Sorceress = try Internal.initFramework(hints);
    const application: Internal.Application = .{
        .procedure = procedure,
        .userdata = userdata,
        .sorceress = sorceress,
    };
    const work: WorkSubmit = .{
        .procedure = Internal.runApplicationMain,
        .argument = &application,
        .stack = stack_size,
        .name = "sorceress::main",
    };
    sorceress.submit(1, &work, null);
    Internal.dirtyDeedsDoneDirtCheap(@ptrCast(&sorceress.internal.tls[0]));
    // won't resume until application returns from main
    switch (builtin.os.tag) {
        .windows => _ = std.os.windows.kernel32.VirtualFree(@ptrCast(sorceress), 0, std.os.windows.MEM_RELEASE),
        else => std.posix.munmap(sorceress),
    }
}

/// Submits work into the system and yields. This will not return until submitted work is done.
pub inline fn commit(sorceress: *@This(), count: u32, work: *const WorkSubmit, stack_size: u32) void {
    var chain: WorkChain = null;
    sorceress.submit(count, work, stack_size, &chain);
    sorceress.yield(chain);
}

pub fn submit(
    sorceress: *@This(), 
    count: u32, 
    work: *const WorkSubmit, 
    stack_size: u32,
    out_chain: ?*WorkChain,
) void {
    if (out_chain) |out| out.* = sorceress.acquireChain(count);
    for (0..count) |idx| {
        const job: Internal.Job = .{
            .submit = work[idx],
            .stack_size = @intCast(stack_size),
            .chain = out_chain.?.* orelse null,
        };
        const success = sorceress.internal.work_queue.enqueue(&job);
        std.debug.assert(success);
    }
}

pub fn yield(sorceress: *@This(), chain: ?WorkChain) void {
    var wait_value: usize = 0;
    if (chain) |wait| {
        wait_value = @atomicLoad(usize, wait, AtomicOrder.acquire);
        std.debug.assert(wait_value != Internal.Fiber.INVALID);
    }
    if (wait_value) {
        const tls: *Internal.Tls = &sorceress.internal.tls[Internal.worker_thread_index];
        const fiber: *Internal.Fiber = &sorceress.internal.fibers[tls.fiber_in_use];
        fiber.chain = chain;
        tls.fiber_old = tls.fiber_in_use | tls.Flags.ToWait;
        tls = Internal.yieldFiber(tls, &fiber.context);
        Internal.updateFreeAndWaiting(tls);
    }
    if (chain) |wait| @atomicStore(usize, wait, Internal.Fiber.INVALID, AtomicOrder.release);
}

pub fn acquireChain(sorceress: *@This(), initial_value: usize) WorkChain {
    const tls: *Internal.Tls = &sorceress.internal.tls[Internal.worker_thread_index];
    const fiber_count = sorceress.hints.fiber_count;
    while (true) {
        for (0..fiber_count) |idx_hint| {
            const idx: u32 = (tls.query_hint + idx_hint) % fiber_count;
            const lock: *usize = &sorceress.internal.locks[idx];

            if (@atomicLoad(usize, lock, AtomicOrder.unordered) == Internal.Fiber.INVALID) {
                if (@cmpxchgWeak(usize, lock, Internal.Fiber.INVALID, initial_value, 
                    AtomicOrder.unordered, AtomicOrder.unordered))
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

pub fn driftAlloc(sorceress: *@This(), stride: usize, n: u32, alignment: u32) FrameworkError!*anyopaque {
    const tls: *Internal.Tls = sorceress.internal.tls[Internal.worker_thread_index];
    const fiber: *Internal.Fiber = sorceress.internal.fibers[tls.fiber_in_use];
    const drifter: *Internal.Drifter = fiber.drifter;

    const memory: *anyopaque = drifter.allocate(sorceress, stride, n, alignment) catch |err| {
        std.log.err("Could not allocate {} bytes using drifter for {s}: {}", .{ 
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
        std.log.err("Could not allocate a drifter cursor for {s}: {}", .{ fiber.work.submit.name, @errorName(err) });
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
    ends: *WorkSubmit,
    tls: *Tls,
    threads: *std.Thread,
    fibers: *Fiber,
    waiting: *usize, // atomic
    locks: *usize, // atomic
    free: *usize, // atomic
    bitmap: *u8, // atomic
    commitment: usize, // atomic
    sync: usize, // atomic
    roots: usize,
    regions: *Drifter.Region,
    region_tail: usize, // atomic

    const Tls = struct {
        sorceress: *Sorceress,
        home_context: *anyopaque,
        fiber_in_use: u16,
        fiber_old: u16,
        query_hint: u16,

        const Flags = enum(u16) {
            InUse = 0,
            ToFree = 0x4000,
            ToWait= 0x8000,
            Mask = ~(Flags.ToFree | Flags.ToWait),
        };
    };

    const Job = struct {
        submit: WorkSubmit,
        stack_size: usize, 
        chain: WorkChain,
    };

    const Fiber = struct {
        work: Job,
        chain: ?WorkChain,
        context: *anyopaque,
        drifter: *Drifter,
        cursor: Drifter.Cursor,
        const INVALID = std.math.maxInt(u16);
    };

    /// Implemented in assembly, ofc/nfc - original/new fiber context.
    extern fn jump_fcontext(ofc: *anyopaque, nfc: *anyopaque, vp: isize, preserve_fpu: c_int) callconv(.C) isize;
    /// Implemented in assembly, sp - top of stack pointer.
    extern fn spawn_fcontext(sp: *anyopaque, stack_size: usize, procedure: PfnWork) callconv(.C) *anyopaque;

    const Application = struct {
        procedure: *const fn (*Sorceress, ?*anyopaque) void, 
        userdata: ?*anyopaque,
        sorceress: *Sorceress,
    };

    fn dirtyDeedsDoneDirtCheap(raw_tls: ?*anyopaque) ?*anyopaque {
        const tls: *Tls = @ptrCast(raw_tls.?);
        worker_thread_index = @atomicRmw(usize, tls.sorceress.internal.sync, AtomicRmwOp.Sub, 1, AtomicOrder.release) - 1;
        tls.query_hint = worker_thread_index * (tls.sorceress.hints.fiber_count / tls.sorceress.hints.thread_count);
        // wait until all threads are ready
        while (@atomicLoad(usize, tls.sorceress.internal.sync, AtomicOrder.acquire) > 0) {}
        tls.fiber_old = Fiber.INVALID;
        tls = yieldFiber(tls, tls.home_context);
        updateFreeAndWaiting(tls);
        return null;
    }

    fn runApplicationMain(raw_work: ?*anyopaque) void {
        const work: *Application = @ptrCast(raw_work.?);
        work.procedure(work.sorceress, work.userdata);
        // won't return until the application exits
        for (work.sorceress.internal.ends[0..work.sorceress.hints.thread_count]) |end_data| {
            end_data.procedure = joinWorkerThread;
            end_data.argument = work.sorceress;
            end_data.name = "sorceress::ends";
        }
        work.sorceress.commit(work.sorceress.hints.thread_count, work.sorceress.framework.ends);
        unreachable;
    }

    fn joinWorkerThread(raw_sorceress: ?*anyopaque) void {
        const sorceress: *Sorceress = @ptrCast(raw_sorceress.?);
        const tls: *Tls = &sorceress.internal.tls[worker_thread_index];
        const fiber: *Fiber = &sorceress.internal.fibers[tls.fiber_in_use];

        if (tls == &sorceress.internal.tls[0])
            for (1..sorceress.hints.thread_count) |idx| std.Thread.join(sorceress.internal.threads[idx]);
        tls.fiber_old = tls.fiber_in_use | tls.Flags.ToFree;
        std.debug.assert(fiber.context != tls.home_context);
        _ = jump_fcontext(&fiber.context, tls.home_context, @bitCast(tls), 1);
        unreachable;
    }

    fn updateFreeAndWaiting(tls: *Tls) void {
        if (tls.fiber_old == Fiber.INVALID) return;
        const fiber_idx: u16 = tls.fiber_old & Tls.Flags.Mask;

        // A thread that added a fiber to the free list is the same as the one freeing it
        if (tls.fiber_old & Tls.Flags.ToFree)
            @atomicStore(usize, &tls.sorceress.internal.free[fiber_idx], @intCast(fiber_idx), AtomicOrder.unordered);
        // Wait threshold needs to be thread synced, so a CPU fence is welcome
        if (tls.fiber_old & Tls.Flags.ToWait)
            @atomicStore(usize, &tls.sorceress.internal.waiting[fiber_idx], @intCast(fiber_idx), AtomicOrder.release);
        tls.fiber_old = Fiber.INVALID;
    }

    fn theWork(raw_tls: ?*anyopaque) void {
        var tls: *Tls = @ptrCast(raw_tls.?);
        const sorceress: *Sorceress = tls.sorceress;
        const fiber: *Fiber = &sorceress.internal.fibers[tls.fiber_in_use];
        updateFreeAndWaiting(tls);

        fiber.work.submit.procedure(fiber.work.submit.argument);
        if (fiber.work.chain) |chain| 
            @atomicRmw(usize, chain, AtomicRmwOp.Sub, 1, AtomicOrder.release);
        fiber.drifter.restoreFromCursor(sorceress, &fiber.cursor);
        fiber.drifter.tail_cursor = fiber.cursor.prev;

        // The thread may have changed between yields.
        tls = &sorceress.internal.tls[worker_thread_index];
        tls.fiber_old = tls.fiber_in_use | Tls.Flags.ToFree;
        yieldFiber(tls, &fiber.context);
        unreachable;
    }

    fn findFreeFiber(sorceress: *Sorceress, hint: u16) u16 {
        for (0..sorceress.hints.fiber_count) |at| {
            const index: u16 = (hint +% at) % sorceress.hints.fiber_count;
            const free: *usize = &sorceress.internal.free[index];

            // Double lock should help CPUs that have a weak memory model, like ARM.
            var fiber_free = @atomicLoad(usize, free, AtomicOrder.unordered);
            if (fiber_free >= Fiber.INVALID) continue;

            fiber_free = @atomicLoad(usize, free, AtomicOrder.acquire);
            if (fiber_free >= Fiber.INVALID) continue;

            if (@cmpxchgWeak(usize, free, fiber_free, Fiber.INVALID, AtomicOrder.release, AtomicOrder.unordered)) return fiber_free;
        }
        return Fiber.INVALID;
    }

    fn queryThroughFibers(sorceress: *Sorceress, hint: u16) u16 {
        for (0..sorceress.hints.fiber_count) |at| {
            const index: u16 = (hint +% at) % sorceress.hints.fiber_count;
            const waiting: *usize = &sorceress.internal.waiting[index];
            
            // Double lock should help CPUs that have a weak memory model, like ARM.
            var fiber_waiting: usize = @atomicLoad(usize, waiting, AtomicOrder.unordered);
            if (fiber_waiting >= Fiber.INVALID) continue;

            fiber_waiting = @atomicLoad(usize, waiting, AtomicOrder.acquire);
            if (fiber_waiting >= Fiber.INVALID) continue;

            const fiber: *Fiber = &sorceress.internal.fibers[fiber_waiting];
            if (fiber.chain) |chain|
                if (@atomicLoad(usize, chain, AtomicOrder.unordered)) continue;

            if (@cmpxchgWeak(usize, waiting, fiber_waiting, Fiber.INVALID, AtomicOrder.release, AtomicOrder.unordered)) {
                return fiber_waiting;
            }
        }
        var job: Job = undefined;
        var fiber_index: u16 = Fiber.INVALID;

        if (!sorceress.internal.work_queue.dequeue(&job)) 
            return fiber_index;
        std.debug.assert(job.submit.procedure and job.stack_size > 0);
        while (fiber_index == Fiber.INVALID) fiber_index = findFreeFiber(sorceress, hint);

        const fiber: *Fiber = &sorceress.internal.fibers[fiber_index];
        const drifter: ?*Drifter = null; // TODO resolve drifter inheritance
        //if (!drifter) TODO resolve drifter
        fiber.drifter = drifter.?;
        std.debug.assert(drifter); // TODO
  
        fiber.cursor.tail_region = fiber.drifter.tail_region;
        fiber.cursor.offset = fiber.drifter.tail_region.offset;
        fiber.cursor.stack = fiber.drifter.tail_region.stack;
        fiber.cursor.prev = fiber.drifter.tail_cursor;
        fiber.drifter.tail_cursor = &fiber.cursor;
        fiber.work = job;

        const stack: *anyopaque = fiber.drifter.createStack(sorceress, job.stack_size);
        fiber.context = spawn_fcontext(stack, job.stack_size, theWork);
    }

    fn yieldFiber(tls: *Tls, context: *anyopaque) *Tls {
        const sorceress: *Sorceress = tls.sorceress;
        var wait_chain: ?*WorkChain = null;

        if ((tls.fiber_old != Fiber.INVALID) and (tls.fiber_old & Tls.Flags.ToWait)) {
            const fiber: *Fiber = &sorceress.internal.fibers[tls.fiber_old & Tls.Flags.Mask];
            wait_chain = fiber.chain;
            // TODO resolve drifter inheritance
        }
        while (true) {
            const fiber_index: u16 = queryThroughFibers(sorceress, tls.query_hint);
            // The fiber will be invalid if there are no waiting fibers and there are no new jobs.
            if (fiber_index != Fiber.INVALID) {
                const fiber: *Fiber = &sorceress.internal.fibers[fiber_index];
                tls.fiber_in_use = fiber_index;
                std.debug.assert(fiber.context != tls.home_context);
                return @ptrFromInt(jump_fcontext(context, &fiber.context, @bitCast(tls), 1));
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
        ) FrameworkError!*anyopaque {
            const tail: *Region = drifter.tail_region;
            // For existing stack spaces we can read the stack pointer and possibly fit it
            // or expand upon the existing stack, this way avoiding any allocations.
            const spawn_fcontext_padding = comptime switch (builtin.os.tag) {
                .windows => 512, else => 256, // check spawn_fcontext assembly per impl
            };
            const top_of_stack_alignment = comptime 16;
            // spawn_fcontext requires the top of the stack space
            var top_of_stack: usize = @intFromPtr(sorceress) + tail.at + tail.alloc;
            var new_stack_space = std.mem.alignForward(usize, stack_size, top_of_stack_alignment);

            if (tail.stack) {
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
        ) FrameworkError!*Region {
            const block_aligned = std.mem.alignForward(usize, request, BLOCK_SIZE);
            const block_at = acquireBlocks(sorceress, block_aligned, sorceress.internal.roots);
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
            drifter.tail_region = cursor.tail_region;
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
        bitmap: *u8, 
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

        var bitmask: u8 = ~((1 << (position & 0x07)) - 1);
        for (0..count) |at| {
            const index = head_index + at;
            // XOR'ing the bitmask will leave blocks outside the range untouched.
            if (index == tail_index) bitmask ^= ~((1 << ((position + count) & 0x07)) - 1);
            // Set the blocks as in use (bits set to 0) or as free (bits set to 1).
            _ = @atomicRmw(u8, &bitmap[index], op, if (invert) ~bitmask else bitmask, order);
            bitmask = 0xff;
        }
    }
    /// Sets a range of blocks in mapped memory as in use.
    inline fn acquireBitmapRange(bitmap: *u8, offset: usize, range: usize) void {
        opBitmap(bitmap, offset, range, true, AtomicRmwOp.And, AtomicOrder.acquire);
    }
    /// Sets a range of blocks in mapped memory as free.
    inline fn releaseBitmapRange(bitmap: *u8, offset: usize, range: usize) void {
        opBitmap(bitmap, offset, range, false, AtomicRmwOp.Or, AtomicOrder.release);
    }

    /// A single block allocation. We don't own the memory syns and never wait on it,
    /// instead the value of sync is passed in as the ceiling for the bitmap query.
    /// If a free block is found, we write to the bitmap and double check for data races.
    fn findFreeBlock(bitmap: *u8, floor: usize, ceiling: usize) usize {
        // invalidate the request early
        if (floor >= ceiling) return 0;

        const index = atIndexFromRange(floor);
        const range = 1 + atIndexFromRange(ceiling) - index;

        // Try until we either succeed or hit the ceiling.
        while (true) {
            var at: usize = bits.ffs(&bitmap[index], range);
            
            // bits.ffs() returns a 1-based value, or 0 if no bits are set.
            // This is why later we must decrement the `at` value.
            if (at == 0) return 0;

            // The atPositionFromIndex() will align the value of `index` to byte positions.
            at += atPositionFromIndex(index) - 1;

            // We may have hit the ceiling.
            if (at >= atPositionFromBlock(ceiling)) return 0;

            const bitmask: u8 = (1 << (at & 0x07));
            const prev: u8 = @atomicRmw(u8, &bitmap[atIndexFromPosition(at)], AtomicRmwOp.And, ~bitmask, AtomicOrder.acquire);
            if ((prev & bitmask) == bitmask) return atBlockFromPosition(at);
        }
        unreachable;
    }

    /// Returns begin of the mapped range or 0 if no free memory is left.
    /// Will try to commit into physical memory if the initial request could not be satisfied.
    fn acquireBlocks(sorceress: *Sorceress, request: usize, roots: usize) usize {
        var commitment = @atomicLoad(usize, &sorceress.internal.commitment, AtomicOrder.unordered);
        const sync: *usize = sorceress.internal.sync;

        while (true) {
            const sync_value = @atomicLoad(usize, sync, AtomicOrder.acquire);

            // The allocation process can be greatly simplified if only a single block of 
            // mapped memory was requested (2 MiB), that allows us to avoid locks too.
            if (request <= BLOCK_SIZE) {
                const ceiling = if (sync_value > 0) @min(sync_value, commitment) else commitment;
                const at = findFreeBlock(sorceress.internal.bitmap, roots, ceiling);
                if (at) { return at; } else if (sync_value) continue;
            }
            if (!@cmpxchgWeak(usize, sync, 0, roots, AtomicOrder.release, AtomicOrder.unordered))
                continue; // Another thread owns the sync counter. 

            var at: usize = 0;
            // Reload the value of commitment.
            commitment = @atomicLoad(usize, &sorceress.internal.commitment, AtomicOrder.unordered);
            // This step can be skipped if we came here from the implication that there is
            // not enough free commited memory to satisfy even a minimal allocation. 
            if (request > BLOCK_SIZE) {
                at = findFreeRange(sorceress.internal.bitmap, request, roots, commitment, sync);
                if (at and at + request <= commitment) {
                    acquireBitmapRange(sorceress.internal.bitmap, at, request);
                    @atomicStore(usize, sync, 0, AtomicOrder.release);
                    return at;
                }
            }
            if (!at) at = commitment;
            @atomicStore(usize, sync, at, AtomicOrder.release);
            const range = request - (commitment - at);

            var success: bool = true;
            const map: *anyopaque = @ptrCast(sorceress + commitment);
            // We must commit physical memory.
            if (range + commitment > sorceress.hints.memory_ram_budget) switch (builtin.os.tag) {
                .windows => std.os.windows.VirtualProtect(), // TODO windows stuff
                else => { 
                    std.posix.mprotect(map, range, std.posix.PROT.READ | std.posix.PROT.WRITE) catch |err| {
                        std.log.debug("mprotect(PROT_READ | PROT_WRITE) failed to commit new resources: {}", .{ @errorName(err) });
                        success = false;
                    };
                    if (success) std.posix.madvise(map, range, std.posix.MADV.WILLNEED) catch |err| {
                        std.log.debug("madvise(MADV_WILLNEED) failed to commit new resources: {}", .{ @errorName(err) });
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

    /// Tries to find a range of contiguous memory blocks to fulfill a larger request.
    /// If this function was called, it is assumed the caller owns the sync counter.
    /// The implementation is simple, we don't optimize for best fit or anything.
    fn findFreeRange(
        bitmap: *u8, 
        request: usize, 
        floor: usize, 
        ceiling: usize, 
        sync: *usize,
    ) usize {
        const range = atPositionFromBlock(request);    
        // invalidate the request early
        if ((floor > ceiling) || !range || (range < atPositionFromBlock((ceiling - floor)))) return 0;

        const head_index = atPositionFromBlock(floor);
        const tail_index = atIndexFromRange(ceiling);

        var candidate: usize = 0;
        var current: usize = 0;

        for (head_index..(tail_index+1)) |at| {
            const byte: u8 = @atomicLoad(u8, &bitmap[at], AtomicOrder.unordered);

            if (byte == 0xff) {
                if (current == 0)
                    candidate = atPositionFromIndex(at);
                current += 8;
                if (current >= range) return atBlockFromPosition(candidate);
            } else if (byte != 0) {
                for (0..8) |bit| if ((byte >> bit) & 1) {
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

    fn initFramework(hints: *const Hints) FrameworkError!*Sorceress {
        _ = hints;
        return FrameworkError.InitializationFailed;
    }
};
