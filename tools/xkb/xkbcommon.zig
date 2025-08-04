const std = @import("std");

pub const Keycode = u32;
pub const Keysym = @import("xkbcommon-keysyms.zig").Keysym;
pub const KeyDirection = enum(c_int) {
    up,
    down,
};
pub const names = @import("xkbcommon-names.zig");

pub const LayoutIndex = u32;
pub const LayoutMask = u32;

pub const LevelIndex = u32;

pub const ModIndex = u32;
pub const ModMask = u32;

pub const LED_Index = u32;
pub const LED_Mask = u32;

pub const keycode_invalid = 0xffff_ffff;
pub const layout_invalid = 0xffff_ffff;
pub const level_invalid = 0xffff_ffff;
pub const mod_invalid = 0xffff_ffff;
pub const led_invalid = 0xffff_ffff;
pub const keycode_max = 0xffff_ffff - 1;

pub const RuleNames = extern struct {
    rules: ?[*:0]const u8,
    model: ?[*:0]const u8,
    layout: ?[*:0]const u8,
    variant: ?[*:0]const u8,
    options: ?[*:0]const u8,
};

pub const LogLevel = enum(c_int) {
    crit = 10,
    err = 20,
    warn = 30,
    info = 40,
    debug = 50,
};

pub const Context = opaque {};
pub const ContextFlags = enum(c_int) {
    no_flags = 0,
    no_default_includes = 1 << 0,
    no_environment_names = 1 << 1,
};

pub const Keymap = opaque {};
pub const KeymapCompileFlags = enum(c_int) { no_flags = 0, };
pub const KeymapFormat = enum(c_int) { text_v1 = 1, };
pub const PfnKeymapKeyIter = *const fn (*Keymap, Keycode, *anyopaque) void;

pub const ConsumedMode = enum(c_int) { xkb, gtk, };

pub const State = opaque {};
pub const StateComponent = enum(c_int) {
    _,
    pub const mods_depressed = 1 << 0;
    pub const mods_latched = 1 << 1;
    pub const mods_locked = 1 << 2;
    pub const mods_effective = 1 << 3;
    pub const layout_depressed = 1 << 4;
    pub const layout_latched = 1 << 5;
    pub const layout_locked = 1 << 6;
    pub const layout_effective = 1 << 7;
    pub const leds = 1 << 8;
};

pub const StateMatch = enum(c_int) {
    _,
    pub const any = 1 << 0;
    pub const all = 1 << 1;
    pub const non_exclusive = 1 << 16;
};

pub const ComposeTable = opaque {};
pub const ComposeCompileFlags = enum(c_int) { no_flags = 0, };

pub const ComposeState = opaque {}; 
pub const ComposeStateFlags = enum(c_int) { no_flags = 0, };

pub const ComposeStatus = enum(c_int) { nothing, composing, composed, cancelled, };
pub const ComposeFeedResult = enum(c_int) { ignored, accepted, };

pub const LibXkbCommon = struct {
    handle: std.DynLib,
    xkb_context_new: *const fn (ContextFlags) callconv(.C) ?*Context,
    xkb_context_unref: *const fn(*Context) callconv(.C) void,
    xkb_keymap_new_from_string: *const fn(*Context, [*:0]const u8, KeymapFormat, KeymapCompileFlags) callconv(.C) ?*Keymap,
    xkb_keymap_unref: *const fn(*Keymap) callconv(.C) void,
    xkb_keymap_mod_get_index: *const fn(*Keymap, [*:0]const u8) callconv(.C) ModIndex,
    xkb_keymap_key_repeats: *const fn(*Keymap, Keycode) callconv(.C) c_int,
    xkb_keymap_key_for_each: *const fn(*Keymap, PfnKeymapKeyIter, *anyopaque) callconv(.C) void,
    xkb_keymap_key_get_syms_by_level: *const fn(*Keymap, Keycode, LayoutIndex, LevelIndex, *?[*]const Keysym) callconv(.C) c_int,
    xkb_keymap_layout_get_name: *const fn(*Keymap, LayoutIndex) callconv(.C) ?[*:0]const u8,
    xkb_keysym_to_utf8: *const fn(Keysym, [*]u8, usize) callconv(.C) c_int,
    xkb_keysym_to_utf32: *const fn(Keysym) callconv(.C) u32,
    xkb_state_new: *const fn(*Keymap) callconv(.C) ?*State,
    xkb_state_unref: *const fn(*State) callconv(.C) void,
    xkb_state_key_get_syms: *const fn(*State, Keycode, *?[*]const Keysym) callconv(.C) c_int,
    xkb_state_key_get_layout: *const fn(*State, Keycode) callconv(.C) LayoutIndex,
    xkb_state_mod_index_is_active: *const fn(*State, ModIndex, StateComponent) callconv(.C) void,
    xkb_state_update_mask: *const fn(*State, ModMask, ModMask, ModMask, LayoutIndex, LayoutIndex, LayoutIndex) callconv(.C) StateComponent,
    xkb_compose_table_new_from_locale: *const fn(*Context, [*:0]const u8, ComposeCompileFlags) callconv(.C) ?*ComposeTable,
    xkb_compose_table_unref: *const fn(*ComposeTable) callconv(.C) void,
    xkb_compose_state_new: *const fn(*ComposeTable, ComposeStateFlags) callconv(.C) ?*ComposeState,
    xkb_compose_state_reset: *const fn(*ComposeState) callconv(.C) void,
    xkb_compose_state_unref: *const fn(*ComposeState) callconv(.C) void,
    xkb_compose_state_feed: *const fn(*ComposeState, Keysym) callconv(.C) ComposeFeedResult,
    xkb_compose_state_get_status: *const fn(*ComposeState) callconv(.C) ComposeStatus,
    xkb_compose_state_get_one_sym: *const fn(*ComposeState) callconv(.C) Keysym,

    pub fn load() !LibXkbCommon {
        var lib: LibXkbCommon = undefined;
        lib.handle = std.dynLib.open("libxkbcommon.so.0") catch return error.LibraryNotFound;
        inline for (@typeInfo(LibXkbCommon).Struct.fields[1..]) |field| {
            const name = std.fmt.comptimePrint("{s}\x00", .{field.name});
            const name_z: [:0]const u8 = @ptrCast(name[0 .. name.len - 1]);
            @field(lib, field.name) = lib.handle.lookup(field.type, name_z) orelse {
                std.log.err("Symbol lookup failed for {s}", .{name});
                return error.SymbolLookup;
            };
        }
        return lib;
    }
};
