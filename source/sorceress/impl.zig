/// Defines a framework that is a hard dependency for everything outside of self module.
/// Generally everything that wants a pointer to self struct as an argument requires
/// the functionality that is available only within the context of a running framework.
///
/// Most of the submodules here is self contained, Sorceress is used as a namespace for them. 
const Sorceress = @This();

host: Host,
impl: Impl,

pub const xml = @import("./xml.zig");
pub const bits = @import("./bits.zig");

const mpmc = @import("./mpmc.zig");
pub const MpmcNode = mpmc.MpmcNode;
pub const Mpmc = mpmc.Mpmc;

const std = @import("std");
const builtin = @import("builtin");
const AtomicRmwOp = std.builtin.AtomicRmwOp;
const AtomicOrder = std.builtin.AtomicOrder;

pub const PfnWork = *const fn (work: ?*anyopaque) void;

pub const WorkSubmit = struct {
    procedure: PfnWork,
    argument: ?*anyopaque,
    name: [:0]const u8,
};
pub const WorkChain = *usize; // atomic

pub const FrameworkError = error {
    InitializationFailed,
    OutOfMemory,
};

/// We represent mapped memory using blocks of 2MiB in size (one hugepage on most platforms).
pub const BLOCK_SIZE = (2*1024*1024);

/// User provided information to assemble the framework. After hints are processed, 
/// defaults or limits are provided and Sorceress.hints reflects the actual state
/// of the framework during application runtime.
pub const Hints = struct {
    engine_name: [:0]const u8, 
    app_name: [:0]const u8,
    build_engine_ver: u32,
    build_app_ver: u32,
    main_stack_size: u32,
    /// How many worker threads should run, including the main thread. Value 0 will default to Host.cpu_core_count.
    target_thread_count: u32, 
    /// Log2 of how many jobs can be submitted (1 << log2_work_queue_size).
    log2_work_queue_size: u32,
    /// Log2 of how many fibers to run (1 << log2_fiber_count).
    log2_fiber_count: u32,
    /// A target limit for the dynamic memory allocators. 
    target_memory_budget: u64,
    /// Preallocated space for a drifter allocator, there are 2*Host.thread_count-1 drifters.
    target_drifter_head_size: usize,
    /// The drifter head size will be aligned at minimum to this value, clamped to 4096..BLOCK_SIZE.
    target_drifter_head_alignment: usize,
};

/// Framework provided information about the host system, after hints are processed.
pub const Host = struct {
    engine_name: [:0]const u8,
    app_name: [:0]const u8,
    build_engine_ver: u32,
    build_app_ver: u32,
    /// How many fibers are running, mask can be calculated from fiber_count-1 (it's a power of 2).
    fiber_count: u32,
    /// How many worker threads are running, including the main thread.
    thread_count: u32,
    /// How many CPUs are available in the host system.
    cpu_core_count: u32,
    /// Space for preallocated data, BLOCK_SIZE aligned.
    memory_roots: usize,
    /// Strong cap to the frameworks memory allocators
    memory_budget: u64,
    /// How much random access memory is available in the host system.
    memory_total_ram: u64,
    /// The actual size used by drifter head allocations, after alignment. One drifter per worker thread.
    memory_drifter_head: usize,
    /// The page size currently in use.
    memory_page_size_in_use: usize,
    /// A target page size of the host (in most cases it's 4096).
    memory_page_size: usize,
    /// A target hugetbl entry size of the host (in most cases it's 2MiB, we don't care about 1GiB).
    memory_hugepage_size: usize,
};

const Impl = struct {
    /// Job submits for worker threads to execute.
    work_queue: Mpmc(Job),
    /// TODO waiting list
    /// List of indices to free fibers.
    free: Mpmc(usize),
    /// Thread local storage.
    tls: [*]Tls,
    /// Worker threads, index 0 (main thread) is undefined.
    threads: [*]std.Thread,
    /// An array of fibers.
    fibers: [*]Fiber,
    /// An array of atomic locks used for WorkChain's.
    locks: [*]usize,
    /// Atomic representation of the whole memory budget, 1 bit represents one block of BLOCK_SIZE.
    bitmap: [*]u8,
    /// Fiber-bound allocators for transient resources.
    drifters: [*]Drifter,
    /// Preallocated space for drifter regions, they are never recycled.
    regions: [*]Drifter.Region,
    /// Work submits for joining threads, used when the framework finishes.
    ends: [*]WorkSubmit,
    /// Os-specific memory mapping.
    map: MapOs,

    _pad0: [std.atomic.cache_line]u8,
    /// An atomic ever-incrementing counter into the regions array.
    region_tail: usize, 
    _pad1: [std.atomic.cache_line]u8,
    /// An atomic representation of the current RAM memory in use, will never be 
    /// larger than Host.memory_budget or smaller than Host.memory_roots.
    commitment: usize, 
    _pad2: [std.atomic.cache_line]u8,
    /// An atomic counter used for synchronizing access in unsafe tasks, like large (>BLOCK_SIZE) memory allocations.
    sync: usize,

    /// Every thread will set an unique 0..thread_count value during initialization.
    threadlocal var worker_thread_index: u32 = std.math.maxInt(u32);

    const Tls = struct {
        sorceress: *Sorceress,
        home_context: *anyopaque,
        fiber_in_use: u32,
        fiber_old: u32,
        chain_query_hint: u32,
        orphan: ?*Drifter,

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

    fn runApplicationMain(raw_work: ?*anyopaque) noreturn {
        const work: *const Application = @ptrCast(@alignCast(raw_work.?));
        std.debug.assert(blk: {
            const tls: *Tls = &work.sorceress.impl.tls[getThreadIndex()];
            const fiber: *Fiber = &work.sorceress.impl.fibers[tls.fiber_in_use];
            const drifter_is_roots: bool = fiber.drifter == &work.sorceress.impl.drifters[0];
            break :blk drifter_is_roots;
        });
        work.procedure(work.sorceress, work.userdata);
        // exit the application
        for (0..work.sorceress.host.thread_count) |idx| {
            const end: *WorkSubmit = &work.sorceress.impl.ends[idx];
            end.procedure = joinWorkerThread;
            end.argument = work.sorceress;
            end.name = "sorceress::ends";
        }
        work.sorceress.commit(work.sorceress.host.thread_count, work.sorceress.impl.ends, 2048);
        unreachable;
    }

    fn dirtyDeedsDoneDirtCheap(raw_tls: ?*anyopaque) void {
        var tls: *Tls = @ptrCast(@alignCast(raw_tls.?));
        const sorceress: *Sorceress = tls.sorceress;
        worker_thread_index = tls.fiber_in_use;

        // wait until all threads are ready
        while (@atomicLoad(usize, &sorceress.impl.sync, AtomicOrder.acquire) != 0) {}

        tls.fiber_in_use = Fiber.INVALID;
        tls.fiber_old = Fiber.INVALID;
        tls = yieldFiber(sorceress, tls, &tls.home_context);
        invokeHeirApparent(sorceress, tls);
    }

    fn joinWorkerThread(raw_sorceress: ?*anyopaque) noreturn {
        const sorceress: *Sorceress = @ptrCast(@alignCast(raw_sorceress.?));
        const tls: *Tls = &sorceress.impl.tls[worker_thread_index];
        const fiber: *Fiber = &sorceress.impl.fibers[tls.fiber_in_use];

        if (tls == &sorceress.impl.tls[0])
            for (1..sorceress.host.thread_count) |idx| std.Thread.join(sorceress.impl.threads[idx]);
        tls.fiber_old = tls.fiber_in_use | Tls.Flags.ToFree;

        std.debug.assert(fiber.context != tls.home_context);
        _ = jump_fcontext(&fiber.context, tls.home_context, @intCast(@intFromPtr(tls)), 1);
        unreachable;
    }

    fn invokeHeirApparent(sorceress: *Sorceress, tls: *Tls) void {
        // TODO
        _ = sorceress; _ = tls;
        // if (tls.orphan) |drifter| {
        //     std.debug.assert(drifter.tail_cursor == null);
        //     // if (drifter.tail_cursor) |cursor| {
        //     //     drifter.restoreFromCursor(sorceress, cursor);
        //     //     drifter.tail_cursor = cursor.prev;
        //     // }
        //     _ = sorceress.impl.heir_apparent.enqueue(&drifter.heir_apparent);
        //     tls.orphan = null;
        // }
        // if (tls.fiber_old == Fiber.INVALID) 
        //     return;
        // const fiber_idx: usize = tls.fiber_old & Tls.Flags.Mask;

        // if ((tls.fiber_old & Tls.Flags.ToFree) != 0)
        //     _ = sorceress.impl.free.enqueue(&fiber_idx);
        // if ((tls.fiber_old & Tls.Flags.ToWait) != 0)
        //     _ = sorceress.impl.waiting.enqueue(&fiber_idx);
        // tls.fiber_old = Fiber.INVALID;
        unreachable;
    }

    fn theWork(raw_tls: usize) noreturn {
        // TODO
        _ = raw_tls;
        // var tls: *Tls = @ptrFromInt(raw_tls);
        // const sorceress: *Sorceress = tls.sorceress;
        // const fiber: *Fiber = &sorceress.impl.fibers[tls.fiber_in_use];
        // invokeHeirApparent(sorceress, tls);

        // fiber.work.submit.procedure(fiber.work.submit.argument);
        // if (fiber.work.chain) |chain| _ = @atomicRmw(usize, chain, AtomicRmwOp.Sub, 1, AtomicOrder.release);
        // fiber.drifter.restoreFromCursor(sorceress, &fiber.cursor);
        // fiber.drifter.tail_cursor = fiber.cursor.prev;

        // // The thread may have changed between yields.
        // tls = &sorceress.impl.tls[worker_thread_index];
        // tls.fiber_old = tls.fiber_in_use | Tls.Flags.ToFree;
        // _ = yieldFiber(sorceress, tls, &fiber.context);
        unreachable;
    }

    fn yieldFiber(sorceress: *Sorceress, tls: *Tls, context: **anyopaque) *Tls {
        // TODO
        _ = sorceress; _ = tls; _ = context;
        // queryNextFiber:
        // var query_index: usize = Fiber.INVALID;
        // if (sorceress.impl.waiting.dequeue(&query_index)) {
        //     const fiber_index: u32 = @intCast(query_index);

        //     std.debug.assert(fiber_index <= sorceress.impl.waiting.buffer_mask);
        //     const fiber: *Fiber = &sorceress.impl.fibers[fiber_index];
        //     _ = fiber; // TODO resolve drifter
        //     return fiber_index;
        // }
        // var job: Job = undefined;
        // if (!sorceress.impl.work_queue.dequeue(&job)) 
        //     return Fiber.INVALID;

        // // try until successfull
        // while (!sorceress.impl.free.dequeue(&query_index)) {}

        // const fiber_index: u32 = @intCast(query_index);
        // std.debug.assert(fiber_index <= sorceress.impl.free.buffer_mask);
        // const fiber: *Fiber = &sorceress.impl.fibers[fiber_index];
        // //const drifter: ?*Drifter = null; // TODO resolve drifter inheritance
        // //if (!drifter) TODO resolve drifter
        // //fiber.drifter = drifter.?;

        // fiber.cursor.tail_region = fiber.drifter.tail_region;
        // fiber.cursor.offset = fiber.drifter.tail_region.offset;
        // fiber.cursor.stack = fiber.drifter.tail_region.stack;
        // fiber.cursor.prev = fiber.drifter.tail_cursor;
        // fiber.drifter.tail_cursor = &fiber.cursor;
        // fiber.work = job;

        // const stack: *anyopaque = fiber.drifter.createStack(sorceress, job.stack_size) catch |err| {
        //     std.log.err("Creating a fiber stack of size {} failed for job {s}: {s}.", .{ 
        //         job.stack_size, job.submit.name, @errorName(err),
        //     });
        //     std.process.abort();
        // };
        // fiber.context = spawn_fcontext(stack, job.stack_size, @intFromPtr(&theWork));
        // return fiber_index;

        // yieldFiber:
        // var wait_chain: ?WorkChain = null;
        // if (tls.fiber_old != Fiber.INVALID) {
        //     const fiber: *Fiber = &sorceress.impl.fibers[tls.fiber_old & Tls.Flags.Mask];

        //     if (tls.fiber_old & Tls.Flags.ToWait != 0) {
        //         wait_chain = fiber.chain;
        //         // TODO resolve drifter
        //     } else {
        //         // TODO resolve drifter
        //     }
        // }
        // while (true) {
        //     const fiber_index: u32 = queryNextFiber(sorceress); // TODO resolve drifter
        //     // The fiber will be invalid if there are no waiting fibers and there are no new jobs.
        //     if (fiber_index != Fiber.INVALID) {
        //         const fiber: *Fiber = &sorceress.impl.fibers[fiber_index];

        //         tls.fiber_in_use = fiber_index;
        //         std.debug.assert(context.* != fiber.context);
        //         return @ptrFromInt(jump_fcontext(context, fiber.context, @intFromPtr(tls), 1));
        //     }
        //     // Race condition fix. Context needs to wait until a set of jobs are done. 
        //     // The jobs finish before a new context to swap to is found - there's no new jobs. 
        //     // The context swap code deadlocks looking for a new job to swap to, when no new 
        //     // jobs may arrive. Meanwhile the "to be swapped" context is waiting to be ran,
        //     // but cannot as it hasn't been swapped out yet (to be picked up by the wait list).
        //     if (wait_chain) |chain| {
        //         const count = @atomicLoad(usize, chain, AtomicOrder.unordered);
        //         if (count == 0) {
        //             // tls.fiber_in_use still points to the "to waitlist" fiber
        //             tls.fiber_old = Fiber.INVALID;
        //             return tls;
        //         }
        //     }
        // }
        unreachable;
    }

    fn readHugetlbInfo() usize {
        switch (builtin.os.tag) {
            .windows => {
                return 2*1024*1024; // TODO windows stuff ?
            },
            .linux => {
                const candidates = [_]usize{ 1*1024, 2*1024, 4*1024 }; // 1..4 MiB
                for (candidates) |size| {
                    const subdir = blk: {
                        var buf: [64]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "/sys/kernel/mm/hugepages/hugepages-{}kB", .{ size }) 
                            catch continue;
                        break :blk str;
                    };
                    var dir: std.fs.Dir = std.fs.openDirAbsolute(subdir, .{}) 
                        catch continue;
                    dir.close();
                    return size;
                } 
            }, else => {
                // TODO idk if this will work, but i don't care for now
                var size: usize = undefined;
                var len: usize = @sizeOf(usize);
                std.posix.sysctlbynameZ("vm.nr_hugepages", &size, &len, null, 0) catch return 0;
                return size;
            }
        }
        return 0;
    }

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

        fn grow(
            drifter: *@This(), 
            sorceress: *Sorceress,
            request: usize,
            tail_region: *Region,
        ) !*Region {
            const block_aligned = std.mem.alignForward(usize, request, BLOCK_SIZE);
            const block_at = acquireBlocks(sorceress, block_aligned);
            if (block_at == 0) 
                return FrameworkError.OutOfMemory;

            var tail: *Region = tail_region;
            if (tail.next) |next| {
                tail = next; 
            } else {
                const new_region_index = @atomicRmw(usize, &sorceress.impl.region_tail, AtomicRmwOp.Add, 1, AtomicOrder.release);
                tail = &sorceress.impl.regions[new_region_index];
                drifter.tail_region.next = tail;
            }
            tail.at = block_at;
            tail.alloc = block_aligned;
            drifter.tail_region = tail;
            return tail;
        }

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
                tail = try drifter.grow(sorceress, size, tail);
            }
            tail.offset = aligned + size;
            return @ptrFromInt(@intFromPtr(sorceress) + tail.at + aligned);
        }

        fn createStack(
            drifter: *@This(),
            sorceress: *Sorceress, 
            // TODO 
        ) !*anyopaque {
            // TODO two things:
            // - Avoid overwriting the fiber context, will happen if we create a stack when the old_fiber is to be freed.
            //   We should use an additional padding of spawn_fcontext_padding size, to offset between contexts.
            //   So, there must be enough padding for two context slots, and for a single region we must rotate between them.
            // - We can only use the sp (stack pointer) to offset from top if we are the owner of the old fiber, 
            //   that's being added to the wait list. Otherwise we'll read the stack pointer from a completely unrelated context.
            _ = drifter; _ = sorceress;
            // var tail: *Region = drifter.tail_region;
            // // For existing stack spaces we can read the stack pointer and possibly fit it
            // // or expand upon the existing stack, self way avoiding any allocations.
            // const spawn_fcontext_padding = comptime switch (builtin.os.tag) {
            //     .windows => 512, else => 256, // check spawn_fcontext assembly per impl
            // };
            // const top_of_stack_alignment = comptime 16;
            // // spawn_fcontext requires the top of the stack space
            // var top_of_stack: usize = @intFromPtr(sorceress) + tail.at + tail.alloc;
            // var new_stack_space = std.mem.alignForward(usize, stack_size, top_of_stack_alignment);

            // if (tail.stack != 0) {
            //     const sp: usize = getStackPointer() - spawn_fcontext_padding;
            //     const offset_from_top = std.mem.alignForward(usize, top_of_stack - sp, top_of_stack_alignment);
            //     new_stack_space = @max(tail.stack, offset_from_top + stack_size);
            //     top_of_stack -= offset_from_top;
            // }
            // if (tail.offset + new_stack_space > tail.alloc) {
            //     tail = try drifter.expandRegions(sorceress, stack_size, tail);
            //     top_of_stack = @intFromPtr(sorceress) + tail.at + tail.alloc;
            //     new_stack_space = stack_size;
            // }
            // tail.stack = new_stack_space;
            // return @ptrFromInt(top_of_stack);
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
                releaseBitmapRange(sorceress.impl.bitmap, region.at, region.alloc);
                region.at = 0;
                region.alloc = 0;
                region.offset = 0;
                region.stack = 0;
                // the linked list of regions is preserved
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

    /// Atomically updates the bitmap for a given range of blocks.
    inline fn opBitmap(
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

        var bitmask: u8 = ~((@as(u8, 1) << @as(u3, @intCast(position))) -% 1);
        for (0..count) |at| {
            const index = head_index + at;
            // XOR'ing the bitmask will leave blocks outside the range untouched.
            if (index == tail_index) bitmask ^= ~((@as(u8, 1) << @as(u3, @intCast(position + count))) -% 1);
            // Set the blocks as in use (bits set to 0) or as free (bits set to 1).
            _ = @atomicRmw(u8, &bitmap[index], op, if (invert) ~bitmask else bitmask, order);
            bitmask = 0xff;
        }
    }
    /// Atomically sets a range of blocks in mapped memory as in use.
    fn acquireBitmapRange(bitmap: [*]u8, offset: usize, range: usize) void {
        opBitmap(bitmap, offset, range, true, AtomicRmwOp.And, AtomicOrder.acquire);
    }
    /// Atomically sets a range of blocks in mapped memory as free.
    fn releaseBitmapRange(bitmap: [*]u8, offset: usize, range: usize) void {
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

            const bitmask: u8 = @as(u8, 1) << @as(u3, @intCast(at));
            const prev: u8 = @atomicRmw(u8, &bitmap[atIndexFromPosition(at)], AtomicRmwOp.And, ~bitmask, AtomicOrder.acquire);
            if ((prev & bitmask) == bitmask) 
                return atBlockFromPosition(at);
        }
        unreachable;
    }

    /// Tries to find a range of contiguous memory blocks to fulfill a larger request.
    /// If self function was called, it is assumed the caller owns the sync counter.
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
    fn acquireBlocks(sorceress: *Sorceress, request: usize) usize {
        var commitment = @atomicLoad(usize, &sorceress.impl.commitment, AtomicOrder.unordered);
        const sync: *usize = &sorceress.impl.sync;

        while (true) {
            const sync_value = @atomicLoad(usize, sync, AtomicOrder.acquire);

            // The allocation process can be greatly simplified if only a single block of 
            // mapped memory was requested (2 MiB), that allows us to avoid locks too.
            if (request <= BLOCK_SIZE) {
                const ceiling = if (sync_value > 0) @min(sync_value, commitment) else commitment;
                const at = findFreeBlock(sorceress.impl.bitmap, sorceress.host.memory_roots, ceiling);
                if (at != 0) return at else if (sync_value != 0) continue;
            }
            if (@cmpxchgWeak(usize, sync, 0, sorceress.host.memory_roots, AtomicOrder.release, AtomicOrder.monotonic) == null)
                continue; // Another thread owns the sync counter. 

            var at: usize = 0;
            // Reload the value of commitment.
            commitment = @atomicLoad(usize, &sorceress.impl.commitment, AtomicOrder.unordered);
            // This step can be skipped if we came here from the implication that there is
            // not enough free commited memory to satisfy even a minimal allocation. 
            if (request > BLOCK_SIZE) {
                at = findFreeRange(sorceress.impl.bitmap, request, sorceress.host.memory_roots, commitment, sync);
                if (at != 0 and at + request <= commitment) {
                    acquireBitmapRange(sorceress.impl.bitmap, at, request);
                    @atomicStore(usize, sync, 0, AtomicOrder.release);
                    return at;
                }
            }
            if (at == 0) at = commitment;
            @atomicStore(usize, sync, at, AtomicOrder.release);
            const range = request - (commitment - at);

            var success: bool = true;
            // We must commit physical memory.
            if (range + commitment > sorceress.host.memory_budget) switch (builtin.os.tag) {
                .windows => try std.os.windows.VirtualProtect(), // TODO windows stuff
                else => { 
                    std.posix.mprotect(@alignCast(@constCast(sorceress.impl.map[commitment..range])), std.posix.PROT.READ | std.posix.PROT.WRITE) catch |err| {
                        std.log.err("mprotect(PROT_READ | PROT_WRITE) failed to commit new resources: {s}", .{ @errorName(err) });
                        success = false;
                    };
                }
            };
            if (!success) {
                std.log.err("Can't commit physical resources for request: {} at range {}: mapped range {}-{}.", .{ request, range, commitment, commitment+range });
                return 0;
            }
            acquireBitmapRange(sorceress.impl.bitmap, at, request);
            @atomicStore(usize, &sorceress.impl.commitment, commitment + range, AtomicOrder.release);
            @atomicStore(usize, sync, 0, AtomicOrder.release);
            return at;
        }
        unreachable;
    }

    fn initFramework(hints: *const Hints) !*Sorceress {
        // Info to populate Sorceress.Host.
        const cpu_core_count: u32 = @intCast(try std.Thread.getCpuCount());
        const memory_hugepage_size: usize = readHugetlbInfo();
        const memory_page_size: usize = std.heap.pageSize();
        const memory_page_size_in_use: usize = @max(memory_page_size, memory_hugepage_size);
        const memory_total_ram: u64 = try std.process.totalSystemMemory();
        const thread_spawn_stack_size: comptime_int = 4096;
        const thread_count: u32 = blk: {
            var count: u32 = hints.target_thread_count;
            if (count == 0) { count = cpu_core_count; }
            else count = @min(count, cpu_core_count);
            break :blk count;
        };
        const fiber_count: u32 = @max(@as(u32, 1) << @as(u5, @intCast(hints.log2_fiber_count)), bits.roundToPow2By((thread_count<<3)-1));
        const drifter_count: u32 = 2*thread_count-1;
        const drifter_head_alignment = try std.math.ceilPowerOfTwo(usize, @max(4096, hints.target_drifter_head_alignment));
        const drifter_head_size: usize = blk: {
            var size: usize = hints.target_drifter_head_size;
            if (size == 0) { size = BLOCK_SIZE; }
            else size = std.mem.alignForward(usize, size, drifter_head_alignment);
            break :blk size;
        };
        const _MpmcNodeJob = MpmcNode(Job);
        const _MpmcNodeUsize = MpmcNode(usize);
        // Info to populate Sorceress.Impl
        const sorceress_bytes = std.mem.alignForward(usize, @sizeOf(Sorceress), std.atomic.cache_line);
        const work_queue_node_count: u32 = @as(u32, 1) << @as(u5, @intCast(hints.log2_work_queue_size));
        const work_queue_nodes_bytes = std.mem.alignForward(usize, @as(usize, @intCast(work_queue_node_count)) * @sizeOf(_MpmcNodeJob), std.atomic.cache_line);
        const heir_apparent_node_count = bits.roundToPow2By(drifter_count); 
        const heir_apparent_nodes_bytes = std.mem.alignForward(usize, @as(usize, @intCast(heir_apparent_node_count)) * @sizeOf(_MpmcNodeUsize), std.atomic.cache_line);
        const waiting_nodes_bytes = std.mem.alignForward(usize, @as(usize, @intCast(fiber_count)) * @sizeOf(_MpmcNodeUsize), std.atomic.cache_line);
        const free_nodes_bytes = std.mem.alignForward(usize, @as(usize, @intCast(fiber_count)) * @sizeOf(_MpmcNodeUsize), std.atomic.cache_line);
        const tls_bytes = std.mem.alignForward(usize, @as(usize, @intCast(thread_count)) * @sizeOf(Tls), std.atomic.cache_line);
        const threads_bytes = std.mem.alignForward(usize, @as(usize, @intCast(thread_count)) * @sizeOf(std.Thread), std.atomic.cache_line);
        const fibers_bytes = std.mem.alignForward(usize, @as(usize, @intCast(fiber_count)) * @sizeOf(Fiber), std.atomic.cache_line);
        const locks_bytes = std.mem.alignForward(usize, @as(usize, @intCast(fiber_count)) * @sizeOf(usize), std.atomic.cache_line);
        const block_count_limit = atPositionFromBlock(std.mem.alignForward(usize, @as(usize, @intCast(memory_total_ram)), std.atomic.cache_line));
        const bitmap_bytes = std.mem.alignForward(usize, atIndexFromPosition(block_count_limit), std.atomic.cache_line);
        const drifter_heads_bytes: usize = drifter_head_size * @as(usize, @intCast(drifter_count));
        const drifters_bytes = std.mem.alignForward(usize, @as(usize, @intCast(drifter_count)) * @sizeOf(Drifter), std.atomic.cache_line);
        const region_count: usize = block_count_limit >> 1;
        const regions_bytes = std.mem.alignForward(usize, region_count * @sizeOf(Drifter.Region), std.atomic.cache_line);
        const ends_bytes = std.mem.alignForward(usize, @as(usize, @intCast(thread_count)) * @sizeOf(WorkSubmit), std.atomic.cache_line);
        // The exact size of all preallocated data needed to run the framework.
        const roots_size: usize = 
            sorceress_bytes +
            work_queue_nodes_bytes +
            heir_apparent_nodes_bytes +
            waiting_nodes_bytes +
            free_nodes_bytes +
            tls_bytes +
            threads_bytes +
            fibers_bytes +
            locks_bytes +
            bitmap_bytes +
            drifter_heads_bytes +
            drifters_bytes +
            regions_bytes +
            ends_bytes;
        // We align the roots_size to BLOCK_SIZE, this padding will be available through the drifter of the main fiber context.
        const roots_block_aligned = std.mem.alignForward(usize, roots_size + (thread_count-1)*thread_spawn_stack_size + hints.main_stack_size, BLOCK_SIZE);
        // We'll be managing memory by our own in most cases.
        const memory_budget: usize = blk: {
            var budget: usize = hints.target_memory_budget;
            if (budget == 0) { budget = memory_total_ram; } 
            else budget = @max(roots_block_aligned, std.mem.alignForward(usize, budget, BLOCK_SIZE));
            break :blk budget;
        };
        var map: MapOs = undefined;
        switch (builtin.os.tag) {
            .windows => { // TODO windows stuff
                map = try std.os.windows.VirtualAlloc(); // TODO
                try std.os.windows.VirtualProtect(); // TODO
            }, else => {
                const flags: std.posix.system.MAP = .{ 
                    .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true,
                    .HUGETLB = memory_page_size_in_use >= BLOCK_SIZE,
                };
                map = try std.posix.mmap(null, memory_budget, std.posix.PROT.NONE, flags, -1, 0);
                try std.posix.mprotect(@alignCast(@constCast(map[0..roots_block_aligned])), std.posix.PROT.READ | std.posix.PROT.WRITE);
            },
        }
        @memset(@constCast(map[0..roots_block_aligned]), 0);
        const sorceress: *Sorceress = @alignCast(@ptrCast(@constCast(map.ptr)));

        sorceress.host = Host{
            .engine_name = hints.engine_name,
            .app_name = hints.app_name,
            .build_engine_ver = hints.build_engine_ver,
            .build_app_ver = hints.build_app_ver,
            .fiber_count = fiber_count,
            .drifter_count = drifter_count,
            .thread_count = thread_count,
            .cpu_core_count = cpu_core_count,
            .memory_roots = roots_block_aligned,
            .memory_budget = memory_budget,
            .memory_total_ram = memory_total_ram,
            .memory_drifter_head_size = drifter_head_size,
            .memory_drifter_head_alignment = drifter_head_alignment,
            .memory_page_size_in_use = memory_page_size_in_use,
            .memory_page_size = memory_page_size,
            .memory_hugepage_size = memory_hugepage_size,
        };
        @atomicStore(usize, &sorceress.impl.commitment, roots_block_aligned, AtomicOrder.unordered);
        sorceress.impl.map = map;

        // Every variable here is aligned to std.atomic.cache_line.
        var o: usize = sorceress_bytes;
        const raw: [*]u8 = @ptrCast(sorceress);
        sorceress.impl.work_queue.init(@alignCast(@ptrCast(raw + o)), work_queue_node_count); 
        o += work_queue_nodes_bytes;
        sorceress.impl.heir_apparent.init(@alignCast(@ptrCast(raw + o)), heir_apparent_node_count); 
        o += heir_apparent_nodes_bytes;
        sorceress.impl.waiting.init(@alignCast(@ptrCast(raw + o)), fiber_count);
        o += waiting_nodes_bytes;
        sorceress.impl.free.init(@alignCast(@ptrCast(raw + o)), fiber_count);
        o += free_nodes_bytes;
        sorceress.impl.tls = @alignCast(@ptrCast(raw + o)); o += tls_bytes;
        sorceress.impl.threads = @alignCast(@ptrCast(raw + o)); o += threads_bytes;
        sorceress.impl.fibers = @alignCast(@ptrCast(raw + o)); o += fibers_bytes;
        sorceress.impl.drifters = @alignCast(@ptrCast(raw + o)); o += drifters_bytes;
        sorceress.impl.regions = @alignCast(@ptrCast(raw + o)); o += regions_bytes;
        sorceress.impl.ends = @alignCast(@ptrCast(raw + o)); o += ends_bytes;
        sorceress.impl.locks = @alignCast(@ptrCast(raw + o)); o += locks_bytes;
        sorceress.impl.bitmap = @alignCast(@ptrCast(raw + o)); o += bitmap_bytes;
        opBitmap(sorceress.impl.bitmap, 0, roots_block_aligned, true, AtomicRmwOp.And, AtomicOrder.monotonic);

        // The roots drifter is owned by the main fiber.
        const roots_drifter: *Drifter = &sorceress.impl.drifters[0];
        roots_drifter.head = Drifter.Region{
            .next = null,
            .at = 0,
            .offset = roots_size - drifter_heads_bytes,
            .alloc = roots_block_aligned - (drifter_heads_bytes - drifter_head_size),
            .stack = 0,
        };
        roots_drifter.tail_region = &roots_drifter.head;
        roots_drifter.tail_cursor = null;
        roots_drifter.heir_apparent = 0;
        _ = sorceress.impl.heir_apparent.enqueue(&roots_drifter.heir_apparent);

        // Setup drifters, fibers and main tls.
        for (1..drifter_count) |idx| {
            const drifter: *Drifter = &sorceress.impl.drifters[idx];
            // For `at` we need the offset to bottom of the drifter's head allocation;
            const at: usize = roots_block_aligned - idx * drifter_head_size;
            drifter.head = Drifter.Region{ .next = null, .at = at, .offset = 0, .alloc = drifter_head_size, .stack = 0, };
            drifter.tail_region = &roots_drifter.head;
            drifter.tail_cursor = null;
            drifter.heir_apparent = idx;
            _ = sorceress.impl.heir_apparent.enqueue(&drifter.heir_apparent);
        }
        for (0..fiber_count) |idx| {
            @atomicStore(usize, &sorceress.impl.locks[idx], Fiber.INVALID, AtomicOrder.unordered);
            // We push all fiber indices into the free list.
            _ = sorceress.impl.free.enqueue(&idx);
        }
        const main_tls: *Tls = &sorceress.impl.tls[0];
        main_tls.sorceress = sorceress;
        main_tls.fiber_in_use = 0;
        @atomicStore(usize, &sorceress.impl.sync, 1, AtomicOrder.release);

        // Spawn worker threads.
        for (1..sorceress.host.thread_count) |idx| {
            const tls: *Tls = &sorceress.impl.tls[idx];
            tls.sorceress = sorceress;
            // We use tls.fiber_in_use temporarily to overwrite the worker_thread_index, check Impl.dirtyDeedsDoneDirtCheap().
            tls.fiber_in_use = @intCast(idx);   
            sorceress.impl.threads[idx] = try std.Thread.spawn(.{ 
                .allocator = null, // TODO pass in the roots_drifter, we'll have to abstract std.mem.Allocator someday anyway
                .stack_size = thread_spawn_stack_size 
            }, dirtyDeedsDoneDirtCheap, .{ tls }); 
        }
        @atomicStore(usize, &sorceress.impl.sync, 0, AtomicOrder.release);
        return sorceress;
    }
};

pub fn acquireChain(sorceress: *@This(), initial_value: usize) WorkChain {
    const tls: *Impl.Tls = &sorceress.impl.tls[Impl.worker_thread_index];
    var at = tls.chain_query_hint;
    while (true) {
        const lock: WorkChain = &sorceress.impl.locks[at];
        at = (at + 1) & @as(u32, @intCast(sorceress.impl.free.buffer_mask));

        if (@atomicLoad(usize, lock, AtomicOrder.monotonic) == Impl.Fiber.INVALID) {
            if (@cmpxchgWeak(usize, lock, Impl.Fiber.INVALID, initial_value, 
                AtomicOrder.monotonic, AtomicOrder.monotonic) == null)
            {
                tls.chain_query_hint = at;
                return @ptrCast(lock);
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

pub inline fn getThreadIndex() u32 {
    return Impl.worker_thread_index;
}

pub inline fn getStackPointer() usize {
    var dummy: u8 = 0;
    return @intFromPtr(&dummy);
}

pub fn driftAlloc(sorceress: *@This(), stride: usize, n: u32, alignment: u32) !*anyopaque {
    const tls: *Impl.Tls = sorceress.impl.tls[Impl.worker_thread_index];
    const fiber: *Impl.Fiber = sorceress.impl.fibers[tls.fiber_in_use];
    const drifter: *Impl.Drifter = fiber.drifter;

    const memory: *anyopaque = drifter.allocate(sorceress, stride, n, alignment) catch |err| {
        std.log.err("Could not allocate {} bytes using drifter for {s}: {s}.", .{ 
            stride * n, fiber.work.submit.name, @errorName(err),
        });
        return err;
    };
    return memory;
}

pub fn driftUnshift(sorceress: *@This()) void {
    const tls: *Impl.Tls = sorceress.impl.tls[Impl.worker_thread_index];
    const fiber: *Impl.Fiber = sorceress.impl.fibers[tls.fiber_in_use];
    const drifter: *Impl.Drifter = fiber.drifter;

    drifter.tail_cursor = drifter.allocate(
        sorceress, @sizeOf(Impl.Drifter.Cursor), 1, @alignOf(Impl.Drifter.Cursor),
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
    const tls: *Impl.Tls = sorceress.impl.tls[Impl.worker_thread_index];
    const fiber: *Impl.Fiber = sorceress.impl.fibers[tls.fiber_in_use];
    const drifter: *Impl.Drifter = fiber.drifter;

    const tail_cursor: *Impl.Drifter.Cursor = drifter.tail_cursor.?;
    drifter.restoreFromCursor(sorceress, tail_cursor);
    drifter.tail_cursor = tail_cursor.prev;
}

/// Combines submit and yield, this will not return until submitted work is done.
pub inline fn commit(sorceress: *@This(), count: u32, work: [*]const WorkSubmit, stack_size: usize) void {
    var chain: ?WorkChain = null;
    sorceress.submit(count, work, stack_size, &chain);
    sorceress.yield(chain);
}

/// Submits work into the job system.
pub fn submit(
    sorceress: *@This(), 
    count: u32, 
    work: [*]const WorkSubmit, 
    stack_size: usize,
    out_chain: ?*?WorkChain,
) void {
    var chain: ?WorkChain = null;
    if (out_chain != null) chain = sorceress.acquireChain(count);

    for (0..count) |idx| {
        const job: Impl.Job = .{
            .submit = work[idx],
            .stack_size = stack_size,
            .chain = chain,
        };
        const success = sorceress.impl.work_queue.enqueue(&job);
        std.debug.assert(success);
    }
    if (out_chain) |out| out.* = chain.?;
}

/// Yields the fiber, it will be added to a wait list.
pub fn yield(sorceress: *@This(), chain: ?WorkChain) void {
    var wait_value: usize = 0;
    if (chain) |wait| {
        wait_value = @atomicLoad(usize, wait, AtomicOrder.acquire);
        std.debug.assert(wait_value != Impl.Fiber.INVALID);
    }
    if (wait_value != 0) {
        var tls: *Impl.Tls = &sorceress.impl.tls[Impl.worker_thread_index];
        const fiber: *Impl.Fiber = &sorceress.impl.fibers[tls.fiber_in_use];
        fiber.chain = chain;
        tls.fiber_old = tls.fiber_in_use | Impl.Tls.Flags.ToWait;
        tls = Impl.yieldFiber(sorceress, tls, &fiber.context);
        Impl.invokeHeirApparent(sorceress, tls);
    }
    if (chain) |wait| @atomicStore(usize, wait, Impl.Fiber.INVALID, AtomicOrder.release);
}

pub fn main(
    hints: *const Hints, 
    procedure: *const fn (*Sorceress, ?*anyopaque) void, 
    userdata: ?*anyopaque,
) !void {
    const sorceress: *Sorceress = try Impl.initFramework(hints);
    defer switch (builtin.os.tag) {
        .windows => _ = std.os.windows.kernel32.VirtualFree(@ptrCast(sorceress), 0, std.os.windows.MEM_RELEASE),
        else => std.posix.munmap(@alignCast(sorceress.impl.map)),
    };
    const application: Impl.Application = .{
        .procedure = procedure,
        .userdata = userdata,
        .sorceress = sorceress,
    };
    const work: WorkSubmit = .{
        .procedure = Impl.runApplicationMain,
        .argument = @constCast(&application),
        .name = "sorceress::main",
    };
    sorceress.submit(1, @ptrCast(&work), hints.main_stack_size, null);
    _ = Impl.dirtyDeedsDoneDirtCheap(@ptrCast(&sorceress.impl.tls[0]));
}
