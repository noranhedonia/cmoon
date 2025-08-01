//! Dummy file to export docs for this project's modules

pub const @"cmoon-encore" = @import("cmoon-encore");
// TODO engine modules

pub const @"cmoon-dev-wayland" = @import("cmoon-dev-wayland");
pub const @"cmoon-dev-vulkan" = @import("cmoon-dev-vulkan");

comptime {
    _ = @"cmoon-encore";
    // TODO engine modules
    _ = @"cmoon-dev-wayland";
    _ = @"cmoon-dev-vulkan";
}
