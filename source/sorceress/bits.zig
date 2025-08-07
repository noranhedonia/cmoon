const simd = @import("std").simd;

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

pub fn ffs(comptime T: type, value: T) u32 {
    if (value == 0) return 0;

    for (0..@sizeOf(T)) |at| {
        const pos: u32 = at << 3;
        const byte: u8 = (value >> pos) & 0xff;
        if (byte == 0) continue;
        return pos + ffs_table[byte];
    }
    unreachable;
}

/// Returns a 1-based value, or 0 if no bits are set.
pub fn ffsBitmap(data: [*]const u8, n: usize) u64 {
    // TODO simd
    for (0..n) |at| if (data[at] != 0) 
        return (at << 3) + ffs_table[data[at]];
    return 0;
}

pub fn popcnt(comptime T: type, value: T) u32 {
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

