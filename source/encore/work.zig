const std = @import("std");

/// Prototype for a job procedure.
pub const WorkFn = *const fn (work: ?*anyopaque) void;

/// Details of a work term to be executed by the job system.
pub const WorkSubmit = struct { 
    procedure: WorkFn, 
    argument: ?*anyopaque, 
    require_stack: usize = 0, 
    name: [*:0]const u8 = "unnamed", 
};

/// An atomic counter bound to a work submit. If used within a call to the job system, 
/// this chain is used to "wait" for the work to finish. A fiber that yields while waiting,
/// instead of blocking or busy-waiting, will implicitly perform a context switch.
pub const WorkChain = *usize;

/// Implemented in assembly, ofc/nfc - original/new fiber context.
extern fn jumpFiberContext(ofc: *anyopaque, nfc: *anyopaque, vp: isize, preserve_fpu: i32) callconv(.C) isize;

/// Implemented in assembly, sp - top of stack pointer.
extern fn spawnFiberContext(sp: *anyopaque, stack_size: usize, procedure: WorkFn) callconv(.C) *anyopaque;

pub fn acquireWorkChain(counter: usize) WorkChain {
    counter; // TODO
}

pub inline fn signalWorkChain(chain: WorkChain) void {
    return @atomicRmw(usize, chain, std.builtin.AtomicRmwOp.Sub, 1, std.builtin.AtomicOrder.release);
}

pub inline fn releaseWorkChain(chain: WorkChain) void { 
    @atomicStore(usize, chain, 0, std.builtin.AtomicOrder.release); 
}

pub fn getThreadIdx() u32 {
    return 0; // TODO
}

pub fn getFiberName() []const u8 {
    return null; // TODO
}

pub fn submit(work_count: u32, work: *const WorkSubmit, out_chain: ?*WorkChain) void {
    _ = work_count;
    _ = work;
    _ = out_chain;
}

pub fn yield(chain: WorkChain) void {
    _ = chain;
}

pub inline fn commit(work_count: u32, work: *const WorkSubmit) void {
    var chain: WorkChain = null;
    submit(work_count, work, &chain);
    yield(chain);
}
