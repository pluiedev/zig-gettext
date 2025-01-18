const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const process = std.process;
const sort = std.sort;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const StringArrayHashMapUnmanaged = std.StringArrayHashMapUnmanaged;
const MoBundle = @import("gettext").MoBundle;

pub fn main() !void {
    var arena = ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try process.argsAlloc(allocator);
    if (args.len != 2) {
        // TODO: proper help and arg parsing
        return error.BadArgs;
    }

    var input_dir = try fs.cwd().openDir(args[1], .{});
    defer input_dir.close();

    const input_paths = try getInputPaths(allocator, input_dir);

    // TODO: configurable output path
    var output_file = try fs.cwd().createFile("messages.mob", .{});
    defer output_file.close();
    var output_buf = io.bufferedWriter(output_file.writer());
    const writer = output_buf.writer();

    const endian = @import("builtin").cpu.arch.endian();
    try writer.writeInt(u32, MoBundle.magic, endian);
    try writer.writeInt(u32, 0, endian);
    const n_files: u32 = @intCast(input_paths.count());
    try writer.writeInt(u32, n_files, endian);
    const header_end: u32 = @intCast(@sizeOf(MoBundle.Header));
    try writer.writeInt(u32, header_end, endian); // paths offset
    try writer.writeInt(u32, header_end + 8 * n_files, endian); // contents offset

    var data_pos = header_end + 16 * n_files;
    for (input_paths.keys()) |path| {
        try writer.writeInt(u32, @as(u32, @intCast(path.len)) + 1, endian);
        try writer.writeInt(u32, data_pos, endian);
        data_pos += @as(u32, @intCast(path.len)) + 1;
    }
    for (input_paths.values()) |size| {
        try writer.writeInt(u32, size + 1, endian);
        try writer.writeInt(u32, data_pos, endian);
        data_pos += size + 1;
    }

    for (input_paths.keys()) |path| {
        try writer.writeAll(path);
        try writer.writeByte(0);
    }
    for (input_paths.keys(), input_paths.values()) |path, size| {
        const file = try input_dir.openFile(path, .{});
        defer file.close();

        var actual_size: u32 = 0;
        while (true) {
            var buf: [4096]u8 = undefined;
            const read = try file.read(&buf);
            if (read == 0) break;
            try writer.writeAll(buf[0..read]);
            actual_size += @intCast(read);
        }
        if (actual_size != size) {
            return error.FileChangedSize;
        }

        try writer.writeByte(0);
    }

    try output_buf.flush();
}

fn getInputPaths(allocator: Allocator, input_dir: fs.Dir) !StringArrayHashMapUnmanaged(u32) {
    var paths = StringArrayHashMapUnmanaged(u32){};

    var locales = ArrayListUnmanaged([]const u8){};
    var dir_iter = input_dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind == .directory) {
            try locales.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    sort.heap([]const u8, locales.items, {}, strLessThan);

    for (locales.items) |locale| {
        var locale_dir = try input_dir.openDir(locale, .{});
        defer locale_dir.close();
        try appendLocalePaths(allocator, &paths, locale_dir, locale);
    }

    return paths;
}

fn appendLocalePaths(
    allocator: Allocator,
    paths: *StringArrayHashMapUnmanaged(u32),
    locale_dir: fs.Dir,
    locale: []const u8,
) !void {
    var categories = ArrayListUnmanaged([]const u8){};
    var dir_iter = locale_dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind == .directory) {
            try categories.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    sort.heap([]const u8, categories.items, {}, strLessThan);

    for (categories.items) |category| {
        var category_dir = try locale_dir.openDir(category, .{});
        defer category_dir.close();
        try appendCategoryPaths(allocator, paths, category_dir, locale, category);
    }
}

fn appendCategoryPaths(
    allocator: Allocator,
    paths: *StringArrayHashMapUnmanaged(u32),
    category_dir: fs.Dir,
    locale: []const u8,
    category: []const u8,
) !void {
    var domains = ArrayListUnmanaged([]const u8){};
    var dir_iter = category_dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind == .file and mem.endsWith(u8, entry.name, ".mo")) {
            try domains.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    sort.heap([]const u8, domains.items, {}, strLessThan);

    for (domains.items) |domain| {
        const path = try fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ locale, category, domain });
        const stat = try category_dir.statFile(domain);
        try paths.put(allocator, path, @intCast(stat.size));
    }
}

fn strLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return mem.lessThan(u8, lhs, rhs);
}
