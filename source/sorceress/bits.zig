const std = @import("std");

/// Asserts at compile time that `T` is an integer, returns `T`.
pub fn requireInt(comptime T: type) type {
    comptime std.debug.assert(@typeInfo(T) == .int);
    return T;
}

/// Asserts at compile time that `T` is a nsigned integer, returns `T`
pub fn requireSignedInt(comptime T: type) type {
    _ = requireInt(T);
    comptime std.debug.assert(@typeInfo(T).int.signedness == .signed);
    return T;
}

/// Asserts at compile time that `T` is an unsigned integer, returns `T`
pub fn requireUnsignedInt(comptime T: type) type {
    _ = requireInt(T);
    comptime std.debug.assert(@typeInfo(T).int.signedness == .unsigned);
    return T;
}

/// Compute the sign of an integer
/// Returns true if the sign bit of `val` is set, otherwise false
/// https://github.com/cryptocode/bithacks#CopyIntegerSign
pub fn isSignBitSet(val: anytype) bool {
    const T = requireSignedInt(@TypeOf(val));
    return -(@as(T, @intCast(@intFromBool(val < 0)))) == -1;
}

/// Detect if two integers have opposite signs
/// Returns true if the `first` and `second` signed integers have opposite signs
/// https://github.com/cryptocode/bithacks#detect-if-two-integers-have-opposite-signs
pub fn isOppositeSign(first: anytype, second: @TypeOf(first)) bool {
    _ = requireSignedInt(@TypeOf(first));
    return (first ^ second) < 0;
}

/// Compute the integer absolute value (abs) without branching
/// https://github.com/cryptocode/bithacks#compute-the-integer-absolute-value-abs-without-branching
pub fn absFast(val: anytype) @TypeOf(val) {
    const T = requireSignedInt(@TypeOf(val));
    const bits = @typeInfo(T).int.bits;

    const mask: T = val >> (bits - 1);
    return (val + mask) ^ mask;
}

/// Find the minimum of two integers without branching
/// https://github.com/cryptocode/bithacks#compute-the-minimum-min-or-maximum-max-of-two-integers-without-branching
pub fn minFast(x: anytype, y: @TypeOf(x)) @TypeOf(x) {
    _ = requireSignedInt(@TypeOf(x));
    return y ^ ((x ^ y) & -@as(@TypeOf(x), @intCast(@intFromBool((x < y)))));
}

/// Find the maximum of two signed integers without branching
/// https://github.com/cryptocode/bithacks#compute-the-minimum-min-or-maximum-max-of-two-integers-without-branching
pub fn maxFast(x: anytype, y: @TypeOf(x)) @TypeOf(x) {
    _ = requireSignedInt(@TypeOf(x));
    return x ^ ((x ^ y) & -@as(@TypeOf(x), @intCast(@intFromBool((x < y)))));
}

/// Determining if an integer is a power of 2
/// Generic function that checks if the input integer is a power of 2. If the input
/// is a signed integer, the generated function will include a call to absFast()
/// https://github.com/cryptocode/bithacks#determining-if-an-integer-is-a-power-of-2
pub fn isPowerOf2(val: anytype) bool {
    const T = @TypeOf(val);
    const abs = if (@typeInfo(T) == .int and @typeInfo(T).int.signedness == .signed) absFast(val) else val;
    return abs != 0 and (abs & (abs - 1)) == 0;
}

const ffs_table: [256]u8 = .{
    0,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,5,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,
    6,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,5,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,
    7,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,5,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,
    6,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,5,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,
    8,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,5,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,
    6,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,5,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,
    7,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,5,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,
    6,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,5,1,2,1,3,1,2,1,4,1,2,1,3,1,2,1,
};

/// Find first bit set, returns a 1-based value or 0 if no bits are set.
pub fn ffs(comptime T: type, value: T) u32 {
    _ = requireInt(T);
    if (value == 0) return 0;

    for (0..@sizeOf(T)) |at| {
        const pos: u32 = at << 3;
        const byte: u8 = (value >> pos) & 0xff;
        if (byte == 0) continue;
        return pos + ffs_table[byte];
    }
    unreachable;
}

/// Find first bit set in a range of bytes, returns a 1-based value or 0 if no bits are set.
pub fn ffsBitmap(data: [*]const u8, n: usize) u64 {
    // TODO simd
    for (0..n) |at| if (data[at] != 0) 
        return (at << 3) + ffs_table[data[at]];
    return 0;
}

const popcnt_table: [256]u8 = .{
    0,1,1,2,1,2,2,3,1,2,2,3,2,3,3,4,1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,
    1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,
    1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,
    2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,
    1,2,2,3,2,3,3,4,2,3,3,4,3,4,4,5,2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,
    2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,
    2,3,3,4,3,4,4,5,3,4,4,5,4,5,5,6,3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,
    3,4,4,5,4,5,5,6,4,5,5,6,5,6,6,7,4,5,5,6,5,6,6,7,5,6,6,7,6,7,7,8,
};

/// Count how many bits are set in an integer.
pub fn popcnt(comptime T: type, value: T) u32 {
    _ = requireInt(T);
    if (value == 0) return 0;

    var cnt: u32 = 0;
    for (0..@sizeOf(T)) |at| {
        const byte: u8 = (value >> (at << 3)) & 0xff;
        if (byte != 0) 
            cnt += popcnt_table[byte];
    }
    return cnt;
}

/// Returns how many bits in range of bytes are set to 1.
pub fn popcntBitmap(data: [*]const u8, n: usize) u64 {
    // TODO simd
    var bits: u64 = 0;
    var at = 0;
    while (at + 4 <= n) {
        bits += popcnt_table[data[at]];
        bits += popcnt_table[data[at + 1]];
        bits += popcnt_table[data[at + 2]];
        bits += popcnt_table[data[at + 3]]; 
        at += 4;
    }
    while (at < n) { 
        bits += popcnt_table[data[at]]; 
        at += 1;
    }
    return bits;
}

/// Round up to the next highest power of 2.
pub fn roundToPow2By(val: u32) u32 {
    std.debug.assert(val < (1 << 31));
    var v = val -% 1;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v +%= 1;
    v +%= @intFromBool(v == 0);
    return v;
}
