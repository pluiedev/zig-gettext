//! A bundle of MO files suitable for embedding into a binary.
//!
//! The format of the bundle is very similar to that of an MO file.
//!
//! TODO: document the format.

needs_byte_swap: bool,
data: []const u8,

const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const Category = @import("gettext.zig").Category;
const Mo = @import("Mo.zig");

const MoBundle = @This();

pub const magic: u32 = 0x439133EE;

pub const Header = extern struct {
    magic: u32,
    revision: packed struct(u32) { minor: u16, major: u16 },
    n_files: u32,
    paths_offset: u32,
    contents_offset: u32,
};

/// Initializes an `MoBundle` from its underlying bytes. `data` is only borrowed
/// by `MoBundle`, not copied, so it is not valid to modify or free `data` while
/// the returned `MoBundle` is still in use.
///
/// The contents of `data` are not validated beyond the most basic checks
/// required to parse the bundle data. These simple checks are analogous to
/// those performed by `Mo.initUnchecked`, as are the consequences of using
/// invalid data as the input.
pub fn initUnchecked(data: []const u8) error{ InvalidMoBundleFormat, UnsupportedMoBundleRevision }!MoBundle {
    if (data.len < @sizeOf(Header)) {
        return error.InvalidMoBundleFormat;
    }
    var bundle = MoBundle{ .needs_byte_swap = false, .data = data };
    bundle.needs_byte_swap = switch (bundle.headerField(.magic)) {
        magic => false,
        @byteSwap(magic) => true,
        else => return error.InvalidMoBundleFormat,
    };
    if (bundle.headerField(.revision).major > 0) {
        return error.UnsupportedMoBundleRevision;
    }
    return bundle;
}

pub fn headerField(self: MoBundle, comptime field: meta.FieldEnum(Header)) meta.FieldType(Header, field) {
    const raw: u32 = @bitCast(self.data[@offsetOf(Header, @tagName(field))..][0..4].*);
    return @bitCast(self.toNative(raw));
}

pub fn get(self: *const MoBundle, locale: []const u8, category: Category, domain: []const u8) ?Mo {
    var buf: [fs.MAX_PATH_BYTES]u8 = undefined;
    const path = fmt.bufPrint(&buf, "{s}/{s}/{s}.mo", .{ locale, category.name(), domain }) catch return null;
    const data = self.findFile(path) orelse return null;
    return .{ .needs_byte_swap = self.needs_byte_swap, .data = data };
}

fn findFile(self: *const MoBundle, path: []const u8) ?[:0]const u8 {
    var left: u32 = 0;
    var right = self.headerField(.n_files);

    while (left < right) {
        const mid = left + (right - left) / 2;
        switch (pathOrder(path, self.pathAt(mid))) {
            .eq => return self.contentsAt(mid),
            .gt => left = mid + 1,
            .lt => right = mid,
        }
    }

    return null;
}

fn pathOrder(lhs: []const u8, rhs: []const u8) math.Order {
    var lhs_iter = mem.splitScalar(u8, lhs, '/');
    var rhs_iter = mem.splitScalar(u8, rhs, '/');

    while (lhs_iter.next()) |lhs_name| {
        const rhs_name = rhs_iter.next() orelse return .gt;
        switch (math.order(u8, lhs_name, rhs_name)) {
            .lt, .gt => |order| return order,
            .eq => {},
        }
    }
    return if (rhs_iter.next() == null) .eq else .lt;
}

fn pathAt(self: *const MoBundle, n: u32) [:0]const u8 {
    return self.dataAt(self.headerField(.paths_offset), n);
}

fn contentsAt(self: *const MoBundle, n: u32) [:0]const u8 {
    return self.dataAt(self.headerField(.contents_offset), n);
}

fn dataAt(self: *const MoBundle, table_offset: u32, n: u32) [:0]const u8 {
    const desc = self.data[table_offset + 8 * n ..][0..8];
    const len = self.toNative(@bitCast(desc[0..4].*));
    const off = self.toNative(@bitCast(desc[4..8].*));
    return self.data[off..][0..len :0];
}
