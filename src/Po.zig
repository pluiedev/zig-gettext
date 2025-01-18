//! A representation of a PO file.
//!
//! Format reference:
//! https://www.gnu.org/software/gettext/manual/html_node/PO-Files.html

entries: []const Entry,
arena: ArenaAllocator,

const std = @import("std");
const ascii = std.ascii;
const fmt = std.fmt;
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const Po = @This();

pub const Entry = struct {
    translator_comments: []const []const u8 = &.{},
    extracted_comments: []const []const u8 = &.{},
    references: []const Reference = &.{},
    flags: []const []const u8 = &.{},
    previous_msgctxt: ?[]const u8 = null,
    previous_msgid: ?[]const u8 = null,
    previous_msgid_plural: ?[]const u8 = null,
    msgctxt: ?[]const u8 = null,
    msgid: []const u8,
    msgid_plural: ?[]const u8 = null,
    msgstr: []const u8,
    plural_msgstrs: []const []const u8 = &.{},

    /// Writes an `Entry` to a `std.io.Writer`.
    pub fn write(self: Entry, w: anytype) !void {
        for (self.translator_comments) |comment| {
            try w.writeAll("#  ");
            try w.writeAll(comment);
            try w.writeByte('\n');
        }
        for (self.extracted_comments) |comment| {
            try w.writeAll("#. ");
            try w.writeAll(comment);
            try w.writeByte('\n');
        }
        if (self.references.len > 0) {
            try w.writeAll("#: ");
            for (self.references, 0..) |reference, i| {
                if (i > 0) {
                    try w.writeByte(' ');
                }
                try reference.write(w);
            }
            try w.writeByte('\n');
        }
        if (self.flags.len > 0) {
            try w.writeAll("#, ");
            for (self.flags, 0..) |flag, i| {
                if (i > 0) {
                    try w.writeAll(", ");
                }
                try w.writeAll(flag);
            }
            try w.writeByte('\n');
        }
        if (self.previous_msgctxt) |msgctxt| {
            try w.writeAll("#| msgctxt ");
            try writeString(w, msgctxt, "#| ");
            try w.writeByte('\n');
        }
        if (self.previous_msgid) |msgid| {
            try w.writeAll("#| msgid ");
            try writeString(w, msgid, "#| ");
            try w.writeByte('\n');
        }
        if (self.previous_msgid_plural) |msgid_plural| {
            try w.writeAll("#| msgid_plural ");
            try writeString(w, msgid_plural, "#| ");
            try w.writeByte('\n');
        }
        if (self.msgctxt) |msgctxt| {
            try w.writeAll("msgctxt ");
            try writeString(w, msgctxt, "");
            try w.writeByte('\n');
        }
        try w.writeAll("msgid ");
        try writeString(w, self.msgid, "");
        try w.writeByte('\n');
        if (self.msgid_plural) |msgid_plural| {
            try w.writeAll("msgid_plural ");
            try writeString(w, msgid_plural, "");
            try w.writeByte('\n');
        }
        if (self.plural_msgstrs.len > 0) {
            try w.writeAll("msgstr[0] ");
        } else {
            try w.writeAll("msgstr ");
        }
        try writeString(w, self.msgstr, "");
        try w.writeByte('\n');
        for (self.plural_msgstrs, 1..) |msgstr, i| {
            try w.print("msgstr[{}] ", .{i});
            try writeString(w, msgstr, "");
            try w.writeByte('\n');
        }
    }
};

pub const Reference = struct {
    path: []const u8,
    line: ?usize = null,

    fn write(self: Reference, w: anytype) !void {
        if (mem.indexOfScalar(u8, self.path, ' ') != null) {
            try w.writeAll("\u{2068}");
            try w.writeAll(self.path);
            try w.writeAll("\u{2069}");
        } else {
            try w.writeAll(self.path);
        }
        if (self.line) |line| {
            try w.print(":{}", .{line});
        }
    }
};

pub fn deinit(self: *Po) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn read(allocator: Allocator, r: anytype) (@TypeOf(r).Error || Allocator.Error || error{InvalidPoFormat})!Po {
    var arena = ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    var entries = ArrayListUnmanaged(Entry){};

    const WipEntry = struct {
        state: union(enum) {
            comments,
            msgctxt: struct { str: ArrayListUnmanaged(u8) },
            msgid: struct { str: ArrayListUnmanaged(u8) },
            msgid_plural: struct { str: ArrayListUnmanaged(u8) },
            msgstr: struct { str: ArrayListUnmanaged(u8) },
            msgstr_plural: struct { n: usize, str: ArrayListUnmanaged(u8) },
        } = .comments,
        translator_comments: ArrayListUnmanaged([]const u8) = .{},
        extracted_comments: ArrayListUnmanaged([]const u8) = .{},
        references: ArrayListUnmanaged(Reference) = .{},
        previous_msgctxt: ?[]const u8 = null,
        previous_msgid: ?[]const u8 = null,
        previous_msgid_plural: ?[]const u8 = null,
        msgctxt: ?[]const u8 = null,
        msgid: ?[]const u8 = null,
        msgid_plural: ?[]const u8 = null,
        msgstr: ?[]const u8 = null,
        plural_msgstrs: ArrayListUnmanaged([]const u8) = .{},

        const WipEntry = @This();

        fn build(self: *WipEntry, a: Allocator) !Entry {
            self.state = undefined;
            return .{
                .translator_comments = try self.translator_comments.toOwnedSlice(a),
                .extracted_comments = try self.extracted_comments.toOwnedSlice(a),
                .references = try self.references.toOwnedSlice(a),
                .previous_msgctxt = clearAndReturn(&self.previous_msgctxt),
                .previous_msgid = clearAndReturn(&self.previous_msgid),
                .previous_msgid_plural = clearAndReturn(&self.previous_msgid_plural),
                .msgctxt = clearAndReturn(&self.msgctxt),
                .msgid = clearAndReturn(&self.msgid) orelse return error.InvalidPoFormat,
                .msgstr = clearAndReturn(&self.msgstr) orelse return error.InvalidPoFormat,
                .plural_msgstrs = try self.plural_msgstrs.toOwnedSlice(a),
            };
        }

        fn clearAndReturn(ptr: *?[]const u8) ?[]const u8 {
            const val = ptr.*;
            ptr.* = null;
            return val;
        }
    };

    var wip_entry = WipEntry{};

    var line = ArrayListUnmanaged(u8){};
    defer line.deinit(allocator);
    var reprocess_line = false;
    var done = false;
    while (!done or reprocess_line) {
        if (!reprocess_line) {
            line.clearRetainingCapacity();
            r.streamUntilDelimiter(line.writer(allocator), '\n', null) catch |e| switch (e) {
                error.EndOfStream => done = true,
                error.StreamTooLong => unreachable,
                else => |other_e| return other_e,
            };
        }
        reprocess_line = false;

        if (mem.indexOfNone(u8, line.items, &ascii.whitespace) == null) continue;

        switch (wip_entry.state) {
            .comments => if (mem.startsWith(u8, line.items, "# ")) {
                const comment = try arena_allocator.dupe(u8, line.items["# ".len..]);
                try wip_entry.translator_comments.append(arena_allocator, comment);
            } else if (mem.startsWith(u8, line.items, "#.")) {
                const comment = try arena_allocator.dupe(u8, line.items["#.".len..]);
                try wip_entry.extracted_comments.append(arena_allocator, comment);
            } else if (mem.startsWith(u8, line.items, "#:")) {
                // TODO: parse references
            } else if (mem.startsWith(u8, line.items, "#,")) {
                // TODO: parse flags
            } else if (mem.startsWith(u8, line.items, "#|")) {
                // TODO: handle previous msg stuff
            } else if (mem.startsWith(u8, line.items, "#")) {
                // Unrecognized comment type
                continue;
            } else if (mem.startsWith(u8, line.items, "msgctxt ")) {
                var str = ArrayListUnmanaged(u8){};
                try appendString(arena_allocator, &str, line.items["msgctxt ".len..]);
                wip_entry.state = .{ .msgctxt = .{ .str = str } };
            } else if (mem.startsWith(u8, line.items, "msgid ")) {
                var str = ArrayListUnmanaged(u8){};
                try appendString(arena_allocator, &str, line.items["msgid ".len..]);
                wip_entry.state = .{ .msgid = .{ .str = str } };
            } else {
                return error.InvalidPoFormat;
            },

            .msgctxt => |*state_ptr| if (mem.startsWith(u8, line.items, "\"")) {
                try appendString(arena_allocator, &state_ptr.str, line.items);
            } else if (mem.startsWith(u8, line.items, "msgid ")) {
                wip_entry.msgctxt = try state_ptr.str.toOwnedSlice(arena_allocator);
                var str = ArrayListUnmanaged(u8){};
                try appendString(arena_allocator, &str, line.items["msgid ".len..]);
                wip_entry.state = .{ .msgid = .{ .str = str } };
            } else {
                return error.InvalidPoFormat;
            },

            .msgid => |*state_ptr| if (mem.startsWith(u8, line.items, "\"")) {
                try appendString(arena_allocator, &state_ptr.str, line.items);
            } else if (mem.startsWith(u8, line.items, "msgid_plural ")) {
                wip_entry.msgid = try state_ptr.str.toOwnedSlice(arena_allocator);
                var str = ArrayListUnmanaged(u8){};
                try appendString(arena_allocator, &str, line.items["msgid_plural ".len..]);
                wip_entry.state = .{ .msgid_plural = .{ .str = str } };
            } else if (mem.startsWith(u8, line.items, "msgstr ")) {
                wip_entry.msgid = try state_ptr.str.toOwnedSlice(arena_allocator);
                var str = ArrayListUnmanaged(u8){};
                try appendString(arena_allocator, &str, line.items["msgstr ".len..]);
                wip_entry.state = .{ .msgstr = .{ .str = str } };
            } else {
                return error.InvalidPoFormat;
            },

            .msgid_plural => |*state_ptr| if (mem.startsWith(u8, line.items, "\"")) {
                try appendString(arena_allocator, &state_ptr.str, line.items);
            } else if (mem.startsWith(u8, line.items, "msgstr[0] ")) {
                wip_entry.msgid_plural = try state_ptr.str.toOwnedSlice(arena_allocator);
                var str = ArrayListUnmanaged(u8){};
                try appendString(arena_allocator, &str, line.items["msgstr[0] ".len..]);
                wip_entry.state = .{ .msgstr_plural = .{ .n = 0, .str = str } };
            } else {
                return error.InvalidPoFormat;
            },

            .msgstr => |*state_ptr| if (mem.startsWith(u8, line.items, "\"")) {
                try appendString(arena_allocator, &state_ptr.str, line.items);
            } else if (mem.startsWith(u8, line.items, "#")) {
                wip_entry.msgstr = try state_ptr.str.toOwnedSlice(arena_allocator);
                try entries.append(arena_allocator, try wip_entry.build(arena_allocator));
                wip_entry.state = .comments;
                reprocess_line = true;
            } else if (mem.startsWith(u8, line.items, "msgctxt ")) {
                wip_entry.msgstr = try state_ptr.str.toOwnedSlice(arena_allocator);
                try entries.append(arena_allocator, try wip_entry.build(arena_allocator));
                var str = ArrayListUnmanaged(u8){};
                try appendString(arena_allocator, &str, line.items["msgctxt ".len..]);
                wip_entry.state = .{ .msgctxt = .{ .str = str } };
            } else if (mem.startsWith(u8, line.items, "msgid ")) {
                wip_entry.msgstr = try state_ptr.str.toOwnedSlice(arena_allocator);
                try entries.append(arena_allocator, try wip_entry.build(arena_allocator));
                var str = ArrayListUnmanaged(u8){};
                try appendString(arena_allocator, &str, line.items["msgid ".len..]);
                wip_entry.state = .{ .msgid = .{ .str = str } };
            } else {
                return error.InvalidPoFormat;
            },

            .msgstr_plural => |*state_ptr| if (mem.startsWith(u8, line.items, "\"")) {
                try appendString(arena_allocator, &state_ptr.str, line.items);
            } else if (mem.startsWith(u8, line.items, "msgstr[")) {
                if (state_ptr.n == 0) {
                    wip_entry.msgstr = try state_ptr.str.toOwnedSlice(arena_allocator);
                } else {
                    try wip_entry.plural_msgstrs.append(arena_allocator, try state_ptr.str.toOwnedSlice(arena_allocator));
                }
                const n_start = "msgstr[".len;
                const n_end = mem.indexOfPos(u8, line.items, n_start, "] ") orelse return error.InvalidPoFormat;
                const n = fmt.parseInt(usize, line.items[n_start..n_end], 10) catch return error.InvalidPoFormat;
                if (n != state_ptr.n + 1) return error.InvalidPoFormat;
                var str = ArrayListUnmanaged(u8){};
                try appendString(arena_allocator, &str, line.items[n_end + "] ".len ..]);
                wip_entry.state = .{ .msgstr_plural = .{ .n = n, .str = str } };
            } else if (mem.startsWith(u8, line.items, "#")) {
                if (state_ptr.n == 0) {
                    wip_entry.msgstr = try state_ptr.str.toOwnedSlice(arena_allocator);
                } else {
                    try wip_entry.plural_msgstrs.append(arena_allocator, try state_ptr.str.toOwnedSlice(arena_allocator));
                }
                wip_entry.state = .comments;
                reprocess_line = true;
            } else if (mem.startsWith(u8, line.items, "msgctxt ")) {
                if (state_ptr.n == 0) {
                    wip_entry.msgstr = try state_ptr.str.toOwnedSlice(arena_allocator);
                } else {
                    try wip_entry.plural_msgstrs.append(arena_allocator, try state_ptr.str.toOwnedSlice(arena_allocator));
                }
                try entries.append(arena_allocator, try wip_entry.build(arena_allocator));
                var str = ArrayListUnmanaged(u8){};
                try appendString(arena_allocator, &str, line.items["msgctxt ".len..]);
                wip_entry.state = .{ .msgctxt = .{ .str = str } };
            } else if (mem.startsWith(u8, line.items, "msgid ")) {
                if (state_ptr.n == 0) {
                    wip_entry.msgstr = try state_ptr.str.toOwnedSlice(arena_allocator);
                } else {
                    try wip_entry.plural_msgstrs.append(arena_allocator, try state_ptr.str.toOwnedSlice(arena_allocator));
                }
                try entries.append(arena_allocator, try wip_entry.build(arena_allocator));
                var str = ArrayListUnmanaged(u8){};
                try appendString(arena_allocator, &str, line.items["msgid ".len..]);
                wip_entry.state = .{ .msgid = .{ .str = str } };
            } else {
                return error.InvalidPoFormat;
            },
        }
    }

    switch (wip_entry.state) {
        .comments => {},
        .msgctxt, .msgid, .msgid_plural => return error.InvalidPoFormat,
        .msgstr => |*state_ptr| {
            wip_entry.msgstr = try state_ptr.str.toOwnedSlice(arena_allocator);
            try entries.append(arena_allocator, try wip_entry.build(arena_allocator));
        },
        .msgstr_plural => |*state_ptr| {
            if (state_ptr.n == 0) {
                wip_entry.msgstr = try state_ptr.str.toOwnedSlice(arena_allocator);
            } else {
                try wip_entry.plural_msgstrs.append(arena_allocator, try state_ptr.str.toOwnedSlice(arena_allocator));
            }
            try entries.append(arena_allocator, try wip_entry.build(arena_allocator));
        },
    }

    return .{
        .entries = try entries.toOwnedSlice(arena_allocator),
        .arena = arena,
    };
}

fn appendString(allocator: Allocator, buf: *ArrayListUnmanaged(u8), str: []const u8) !void {
    if (str.len < 2 or str[0] != '"' or str[str.len - 1] != '"') {
        return error.InvalidPoFormat;
    }

    var state: union(enum) {
        normal,
        escape,
        octal_escape: struct { val: u8, len: u2 },
        hex_escape: struct { val: u8 },
        // Unicode escapes are not allowed in PO strings
    } = .normal;
    for (str[1 .. str.len - 1]) |b| {
        switch (state) {
            .normal => switch (b) {
                '\\' => state = .escape,
                '"', '\n' => return error.InvalidPoFormat,
                else => try buf.append(allocator, b),
            },
            // See https://en.cppreference.com/w/c/language/escape
            .escape => switch (b) {
                '\'', '"', '?' => {
                    try buf.append(allocator, b);
                    state = .normal;
                },
                'a' => {
                    try buf.append(allocator, 0x07);
                    state = .normal;
                },
                'b' => {
                    try buf.append(allocator, 0x08);
                    state = .normal;
                },
                'f' => {
                    try buf.append(allocator, 0x0c);
                    state = .normal;
                },
                'n' => {
                    try buf.append(allocator, '\n');
                    state = .normal;
                },
                'r' => {
                    try buf.append(allocator, '\r');
                    state = .normal;
                },
                't' => {
                    try buf.append(allocator, '\t');
                    state = .normal;
                },
                'v' => {
                    try buf.append(allocator, 0x0b);
                    state = .normal;
                },
                '0'...'7' => {
                    state = .{ .octal_escape = .{ .val = @intCast(b - '0'), .len = 1 } };
                },
                'x' => {
                    state = .{ .hex_escape = .{ .val = 0 } };
                },
                else => return error.InvalidPoFormat,
            },
            .octal_escape => |escape| switch (b) {
                '0'...'7' => {
                    var val = math.mul(u8, 8, escape.val) catch return error.InvalidPoFormat;
                    val = math.add(u8, val, fmt.charToDigit(b, 8) catch unreachable) catch return error.InvalidPoFormat;
                    if (escape.len == 2) {
                        try buf.append(allocator, val);
                        state = .normal;
                    } else {
                        state = .{ .octal_escape = .{ .val = val, .len = escape.len + 1 } };
                    }
                },
                '"', '\n' => return error.InvalidPoFormat,
                '\\' => {
                    try buf.append(allocator, escape.val);
                    state = .escape;
                },
                else => {
                    try buf.append(allocator, escape.val);
                    try buf.append(allocator, b);
                    state = .normal;
                },
            },
            .hex_escape => |escape| switch (b) {
                '0'...'9', 'a'...'f', 'A'...'F' => {
                    const digit = fmt.charToDigit(b, 16) catch unreachable;
                    var val = math.mul(u8, 16, escape.val) catch return error.InvalidPoFormat;
                    val = math.add(u8, val, digit) catch return error.InvalidPoFormat;
                    state = .{ .hex_escape = .{ .val = val } };
                },
                '"', '\n' => return error.InvalidPoFormat,
                '\\' => {
                    try buf.append(allocator, escape.val);
                    state = .escape;
                },
                else => {
                    try buf.append(allocator, escape.val);
                    try buf.append(allocator, b);
                    state = .normal;
                },
            },
        }
    }
}

/// Writes a `Po` to a `std.io.Writer`.
pub fn write(self: Po, w: anytype) @TypeOf(w).Error!void {
    for (self.entries, 0..) |entry, i| {
        if (i > 0) {
            try w.writeByte('\n');
        }
        try entry.write(w);
    }
}

fn writeString(w: anytype, s: []const u8, line_prefix: []const u8) !void {
    if (mem.indexOfScalar(u8, s, '\n')) |first_newline| {
        try w.writeAll("\"\"");
        try w.writeByte('\n');
        try w.writeAll(line_prefix);
        try writeStringLine(w, s[0 .. first_newline + 1]);

        var start = first_newline;
        while (true) {
            const end = mem.indexOfScalarPos(u8, s, start + 1, '\n') orelse break;
            try w.writeByte('\n');
            try w.writeAll(line_prefix);
            try writeStringLine(w, s[start + 1 .. end + 1]);
            start = end;
        }
    } else {
        try writeStringLine(w, s);
    }
}

fn writeStringLine(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |b| {
        switch (b) {
            '"' => try w.writeAll("\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (b < 0x20) {
                try w.print("\\x{X:0>2}", .{b});
            } else {
                try w.writeByte(b);
            },
        }
    }
    try w.writeByte('"');
}
