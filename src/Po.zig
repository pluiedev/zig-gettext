//! A representation of a PO file.
//!
//! Format reference:
//! https://www.gnu.org/software/gettext/manual/html_node/PO-Files.html

entries: []const Entry,
arena: ArenaAllocator,

const std = @import("std");
const mem = std.mem;
const ArenaAllocator = std.heap.ArenaAllocator;

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
    pub fn writeTo(self: Entry, w: anytype) !void {
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
                try reference.writeTo(w);
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

    fn writeTo(self: Reference, w: anytype) !void {
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

/// Writes a `Po` to a `std.io.Writer`.
pub fn writeTo(self: Po, w: anytype) @TypeOf(w).Error!void {
    for (self.entries, 0..) |entry, i| {
        if (i > 0) {
            try w.writeByte('\n');
        }
        try entry.writeTo(w);
    }
}

fn writeString(w: anytype, s: []const u8, line_prefix: []const u8) !void {
    var next_newline = mem.indexOfScalar(u8, s, '\n');
    if (next_newline) |first_newline| {
        try w.writeAll("\"\"");
        try w.writeByte('\n');
        try w.writeAll(line_prefix);
        try writeStringLine(w, s[0 .. first_newline + 1]);
        var start = first_newline + 1;
        next_newline = mem.indexOfScalarPos(u8, s, start, '\n');
        while (next_newline) |end| : (next_newline = mem.indexOfScalarPos(u8, s, end + 1, '\n')) {
            try w.writeByte('\n');
            try w.writeAll(line_prefix);
            try writeStringLine(w, s[start .. end + 1]);
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
                try w.print("{X:0>2}", .{b});
            } else {
                try w.writeByte(b);
            },
        }
    }
    try w.writeByte('"');
}
