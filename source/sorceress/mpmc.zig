/// The MPMC data structure was implemented from the multiple-producer, 
/// multiple-consumer queue described by Dmitry Vyuko on 1024cores. 
///
/// [High Speed Atomic MPMC Queue]
/// http://www.1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue
///
/// Read and write operations on an atomic object are free from data races. 
/// However, if one thread writes to it, all cache lines occupied by the object 
/// are invalidated. If another thread is reading from an unrelated object that 
/// shares the same cache line, it incures unnecesary overhead. This is called 
/// false sharing, and we pad our MPMC ring buffer to avoid that. 
const std = @import("std");
const AtomicOrder = std.builtin.AtomicOrder;

/// The MPMC queue is limited to a fixed-size buffer with a size that is a power of two.
pub fn Mpmc(comptime T: type) type {
    return struct {
        pub const Node = struct {
            sequence: usize,
            data: T,
        };

        buffer: []Node,
        buffer_mask: usize,
        _pad0: [std.atomic.cache_line - @sizeOf(usize) - @sizeOf([]Node)]u8,

        enqueue_pos: usize,
        _pad1: [std.atomic.cache_line - @sizeOf(usize)]u8,

        dequeue_pos: usize,
        _pad2: [std.atomic.cache_line - @sizeOf(usize)]u8,

        pub fn init(this: @This(), buffer: []Node) void {
            std.debug.assert(std.math.isPowerOfTwo(buffer.len));
            this.buffer_mask = buffer.len - 1;
            this.buffer = buffer;

            for (buffer, 0..) |*node, i| @atomicStore(usize, &node.sequence, i, AtomicOrder.unordered);
            @atomicStore(usize, &this.enqueue_pos, 0, AtomicOrder.unordered);
            @atomicStore(usize, &this.dequeue_pos, 0, AtomicOrder.unordered);
        }

        pub fn enqueue(this: *@This(), submit: *T) bool {
            var pos = @atomicLoad(usize, &this.enqueue_pos, AtomicOrder.unordered);
            while (true) {
                const node: *Node = &this.buffer[pos & this.buffer_mask];
                const sequence = @atomicLoad(usize, node.sequence, AtomicOrder.acquire);
                const diff = sequence - pos;

                if (diff == 0) {
                    const delta = pos + 1;
                    if (@cmpxchgWeak(usize, &this.enqueue_pos, pos, delta, AtomicOrder.unordered, AtomicOrder.unordered)) {
                        @atomicStore(usize, &node.sequence, delta, AtomicOrder.release);
                        node.data = submit.*;
                        return true;
                    }
                } else if (diff < 0) {
                    // it's empty
                    return false;
                } else {
                    pos = @atomicLoad(usize, &this.enqueue_pos, AtomicOrder.unordered);
                }
            }
            unreachable;
        }

        pub fn dequeue(this: *@This(), out: *T) bool {
            var pos = @atomicLoad(usize, &this.dequeue_pos, AtomicOrder.unordered);
            while (true) {
                const node: *Node = &this.buffer[pos & this.buffer_mask];
                const sequence = @atomicLoad(usize, node.sequence, AtomicOrder.acquire);
                const diff = sequence - (pos + 1);

                if (diff == 0) {
                    const delta = pos + 1;
                    if (@cmpxchgWeak(usize, &this.dequeue_pos, pos, delta, AtomicOrder.unordered, AtomicOrder.unordered)) {
                        @atomicStore(usize, &node.sequence, delta + this.buffer_mask, AtomicOrder.release);
                        out.* = node.data;
                        return true;
                    }
                } else if (diff < 0) {
                    // it's empty
                    return false;
                } else {
                    pos = @atomicLoad(usize, &this.dequeue_pos, AtomicOrder.unordered);
                }
            }
            unreachable;
        }
    };
}
