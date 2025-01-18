const std = @import("std");
const fs = std.fs;
const io = std.io;
const math = std.math;
const mem = std.mem;
const process = std.process;
const sort = std.sort;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Mo = @import("gettext").Mo;
const Po = @import("gettext").Po;

pub fn main() !void {
    var arena = ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    if (args.len != 2) {
        // TODO: proper help and stuff
        return error.BadArgs;
    }

    var input_file = try fs.cwd().openFile(args[1], .{});
    defer input_file.close();
    var input_buf = io.bufferedReader(input_file.reader());
    var po = try Po.read(allocator, input_buf.reader());
    defer po.deinit();

    const entries = try allocator.dupe(Po.Entry, po.entries);
    sort.heap(Po.Entry, entries, {}, entryLessThan);

    // TODO: configurable output path
    var output_buf = io.bufferedWriter(std.io.getStdOut().writer());
    const writer = output_buf.writer();

    // The endianness doesn't matter. We just use native endianness.
    const native_endian = @import("builtin").cpu.arch.endian();
    try writer.writeInt(u32, Mo.magic, native_endian);
    try writer.writeInt(u32, 0, native_endian);
    const n_strings: u32 = @intCast(entries.len);
    try writer.writeInt(u32, n_strings, native_endian);
    const header_end: u32 = @intCast(@sizeOf(Mo.Header));
    try writer.writeInt(u32, header_end, native_endian); // originals offset
    try writer.writeInt(u32, header_end + 8 * n_strings, native_endian); // translations offset
    try writer.writeInt(u32, 0, native_endian); // hash table size
    try writer.writeInt(u32, 0, native_endian); // hash table offset

    var strings_pos = header_end + 16 * n_strings;
    for (entries) |entry| {
        const original_len = originalLen(entry);
        try writer.writeInt(u32, original_len, native_endian);
        try writer.writeInt(u32, strings_pos, native_endian);
        strings_pos += original_len + 1;
    }
    for (entries) |entry| {
        const translation_len = translationLen(entry);
        try writer.writeInt(u32, translation_len, native_endian);
        try writer.writeInt(u32, strings_pos, native_endian);
        strings_pos += translation_len + 1;
    }

    for (entries) |entry| {
        if (entry.msgctxt) |msgctxt| {
            try writer.writeAll(msgctxt);
            try writer.writeByte(Mo.msgctxt_sep);
        }
        try writer.writeAll(entry.msgid);
        try writer.writeByte(0);
        if (entry.msgid_plural) |msgid_plural| {
            try writer.writeAll(msgid_plural);
            try writer.writeByte(0);
        }
    }
    for (entries) |entry| {
        try writer.writeAll(entry.msgstr);
        try writer.writeByte(0);
        for (entry.plural_msgstrs) |msgstr| {
            try writer.writeAll(msgstr);
            try writer.writeByte(0);
        }
    }

    try output_buf.flush();
}

fn entryLessThan(_: void, lhs: Po.Entry, rhs: Po.Entry) bool {
    var lhs_iter = Mo.IdIterator.init(lhs.msgctxt, lhs.msgid, lhs.msgid_plural);
    var rhs_iter = Mo.IdIterator.init(rhs.msgctxt, rhs.msgid, rhs.msgid_plural);
    while (lhs_iter.next()) |lhs_b| {
        const rhs_b = rhs_iter.next() orelse return false;
        switch (math.order(lhs_b, rhs_b)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
    return rhs_iter.next() != null;
}

fn originalLen(entry: Po.Entry) u32 {
    var len: u32 = @intCast(entry.msgid.len);
    if (entry.msgctxt) |msgctxt| {
        len += @intCast(msgctxt.len);
        len += 1;
    }
    if (entry.msgid_plural) |msgid_plural| {
        len += @intCast(msgid_plural.len);
        len += 1;
    }
    return len;
}

fn translationLen(entry: Po.Entry) u32 {
    var len: u32 = @intCast(entry.msgstr.len);
    for (entry.plural_msgstrs) |msgstr| {
        len += @intCast(msgstr.len);
        len += 1;
    }
    return len;
}
