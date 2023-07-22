/// A locale category.
///
/// The values correspond to the locale categories defined by POSIX with GNU
/// extensions.
pub const Category = enum {
    messages,
    collate,
    ctype,
    monetary,
    numeric,
    time,
    // GNU extensions
    address,
    identification,
    measurement,
    name,
    paper,
    telephone,
};

pub const Po = @import("Po.zig");
pub const Mo = @import("Mo.zig");
