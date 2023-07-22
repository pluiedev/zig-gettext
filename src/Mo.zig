//! A representation of an MO file.
//!
//! Format reference:
//! https://www.gnu.org/software/gettext/manual/html_node/MO-Files.html

needs_byte_swap: bool,
data: []const u8,

const std = @import("std");
const math = std.math;
const mem = std.mem;
const meta = std.meta;

const Mo = @This();

pub const magic: u32 = 0x950412DE;
pub const msgctxt_sep: u8 = 4; // EOT

pub const Header = extern struct {
    magic: u32,
    revision: packed struct(u32) { minor: u16, major: u16 },
    n_strings: u32,
    originals_offset: u32,
    translations_offset: u32,
    hash_size: u32,
    hash_offset: u32,
};

/// Initializes an `Mo` from its underlying bytes. `data` is only borrowed by
/// `Mo`, not copied, so it is not valid to modify or free `data` while the
/// returned `Mo` is still in use.
///
/// The contents of `data` are not validated beyond the most basic checks
/// required to parse an MO file:
///
/// 1. `data` must be at least long enough to store a complete MO file header.
/// 2. The MO format magic number must be correct.
/// 3. The MO format major revision must be either 0 or 1; other format
///    revisions are unsupported (at the time of writing, 0 and 1 are the only
///    major revisions in existence, and they are equivalent).
///
/// In particular, this means that using the returned `Mo` could result in
/// safety-checked illegal behavior if the underlying MO data has improper
/// offsets or lengths for string data, and translation lookups may not be
/// reliable if the original strings are not properly sorted.
pub fn initUnchecked(data: []const u8) error{ InvalidMoFormat, UnsupportedMoRevision }!Mo {
    if (data.len < @sizeOf(Header)) {
        return error.InvalidMoFormat;
    }
    var mo = Mo{ .needs_byte_swap = false, .data = data };
    mo.needs_byte_swap = switch (mo.headerField(.magic)) {
        magic => false,
        @byteSwap(magic) => true,
        else => return error.InvalidMoFormat,
    };
    if (mo.headerField(.revision).major > 1) {
        return error.UnsupportedMoRevision;
    }
    return mo;
}

/// Returns a value from the MO file header.
pub fn headerField(self: Mo, comptime field: meta.FieldEnum(Header)) meta.FieldType(Header, field) {
    const raw: u32 = @bitCast(self.data[@offsetOf(Header, @tagName(field))..][0..4].*);
    return @bitCast(self.toNative(raw));
}

/// Returns the nth original string.
pub fn originalString(self: *const Mo, n: u32) [:0]const u8 {
    return self.string(self.headerField(.originals_offset), n);
}

/// Returns the nth translation string.
pub fn translationString(self: *const Mo, n: u32) [:0]const u8 {
    return self.string(self.headerField(.translations_offset), n);
}

/// Looks up the translation (if any) for the given string.
pub fn findTranslation(self: *const Mo, original: []const u8) ?[:0]const u8 {
    var left: u32 = 0;
    var right: u32 = self.headerField(.n_strings);

    while (left < right) {
        const mid = left + (right - left) / 2;
        switch (mem.order(u8, original, self.originalString(mid))) {
            .eq => return self.translationString(mid),
            .gt => left = mid + 1,
            .lt => right = mid,
        }
    }

    return null;
}

fn string(self: *const Mo, table_offset: u32, n: u32) [:0]const u8 {
    const desc = self.data[table_offset + 8 * n ..][0..8];
    const len = self.toNative(@bitCast(desc[0..4].*));
    const off = self.toNative(@bitCast(desc[4..8].*));
    return self.data[off..][0..len :0];
}

fn toNative(self: Mo, v: u32) u32 {
    return if (self.needs_byte_swap) @byteSwap(v) else v;
}

/// An iterator over the parts of a full message ID which returns the bytes
/// which will be stored in MO format (msgctxt + EOT + msgid + NUL + plurals...).
pub const IdIterator = struct {
    state: union(enum) {
        ctxt: usize,
        id: usize,
        plural_id: usize,
    },
    ctxt: ?[]const u8,
    id: []const u8,
    plural_id: ?[]const u8,

    pub fn init(ctxt: ?[]const u8, id: []const u8, plural_id: ?[]const u8) IdIterator {
        return .{
            .state = if (ctxt != null) .{ .ctxt = 0 } else .{ .id = 0 },
            .ctxt = ctxt,
            .id = id,
            .plural_id = plural_id,
        };
    }

    pub fn next(self: *IdIterator) ?u8 {
        switch (self.state) {
            .ctxt => |pos| if (pos == self.ctxt.?.len) {
                self.state = .{ .id = 0 };
                return msgctxt_sep;
            } else {
                self.state = .{ .ctxt = pos + 1 };
                return self.ctxt.?[pos];
            },
            .id => |pos| if (pos == self.id.len) {
                if (self.plural_id != null) {
                    self.state = .{ .plural_id = 0 };
                    return 0;
                } else {
                    return null;
                }
            } else {
                self.state = .{ .id = pos + 1 };
                return self.id[pos];
            },
            .plural_id => |pos| if (pos == self.plural_id.?.len) {
                return null;
            } else {
                self.state = .{ .plural_id = pos + 1 };
                return self.plural_id.?[pos];
            },
        }
    }
};
