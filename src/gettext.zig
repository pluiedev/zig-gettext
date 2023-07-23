const std = @import("std");
const ascii = std.ascii;
const testing = std.testing;

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

    /// Returns the name of the category as used in POSIX/C, such as
    /// `LC_MESSAGES`.
    pub fn name(category: Category) []const u8 {
        switch (category) {
            inline else => |c| return comptime blk: {
                var buf: [@tagName(c).len]u8 = undefined;
                break :blk "LC_" ++ ascii.upperString(&buf, @tagName(c));
            },
        }
    }

    test name {
        try testing.expectEqualStrings("LC_MESSAGES", Category.messages.cName());
    }
};

pub const Po = @import("Po.zig");
pub const Mo = @import("Mo.zig");
pub const MoBundle = @import("MoBundle.zig");

test {
    testing.refAllDecls(@This());
}
