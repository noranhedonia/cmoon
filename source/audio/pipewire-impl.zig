const c = @cImport({
    @cInclude("pipewire/pipewire.h"); 
    @cInclude("spa/param/audio/format-utils.h");
});
const impl = @import("./impl.zig");

const default_sample_rate = 44_100; // Hz

// pub const LibPipewire = struct {
    
// };
