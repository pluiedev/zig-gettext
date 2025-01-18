const std = @import("std");
const fs = std.fs;
const io = std.io;
const log = std.log;
const math = std.math;
const mem = std.mem;
const process = std.process;
const zig = std.zig;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Ast = zig.Ast;
const HashMapUnmanaged = std.HashMapUnmanaged;
const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
const Po = @import("gettext").Po;

pub fn main() !void {
    var arena = ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);
    const cwd = try process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    var wip = Wip.init(allocator);
    defer wip.deinit();

    for (args[1..]) |arg| {
        const path = try fs.path.relative(allocator, cwd, arg);
        defer allocator.free(path);
        const source = try fs.cwd().readFileAllocOptions(allocator, arg, math.maxInt(usize), null, @alignOf(u8), 0);
        defer allocator.free(source);

        try extractZig(allocator, &wip, .{
            .path = path,
            .source = source,
            .keywords = default_keywords,
        });
    }

    var po = try wip.build();
    defer po.deinit();

    var stdout_buf = io.bufferedWriter(io.getStdOut().writer());
    try po.write(stdout_buf.writer());
    try stdout_buf.flush();
}

/// A description of a keyword (function name) to process as a gettext function.
///
/// The argument numbers start from 0, unlike in GNU xgettext's `-k` option.
pub const Keyword = struct {
    identifier: []const u8,
    msgctxt_arg: ?usize = null,
    msgid_arg: usize = 0,
    msgid_plural_arg: ?usize = null,
};

pub const default_keywords = &[_]Keyword{
    .{ .identifier = "_" },
    .{ .identifier = "gettext" },
    .{ .identifier = "dgettext", .msgid_arg = 1 },
    .{ .identifier = "dcgettext", .msgid_arg = 1 },
    .{ .identifier = "ngettext", .msgid_plural_arg = 1 },
    .{ .identifier = "dngettext", .msgid_arg = 1, .msgid_plural_arg = 2 },
    .{ .identifier = "dcngettext", .msgid_arg = 1, .msgid_plural_arg = 2 },
    .{ .identifier = "pgettext", .msgctxt_arg = 0, .msgid_arg = 1 },
    .{ .identifier = "dpgettext", .msgctxt_arg = 1, .msgid_arg = 2 },
    .{ .identifier = "dcpgettext", .msgctxt_arg = 1, .msgid_arg = 2 },
    .{ .identifier = "npgettext", .msgctxt_arg = 0, .msgid_arg = 1, .msgid_plural_arg = 2 },
    .{ .identifier = "dnpgettext", .msgctxt_arg = 1, .msgid_arg = 2, .msgid_plural_arg = 3 },
    .{ .identifier = "dcnpgettext", .msgctxt_arg = 1, .msgid_arg = 2, .msgid_plural_arg = 3 },
};

pub const ExtractOptions = struct {
    path: []const u8,
    source: [:0]const u8,
    keywords: []const Keyword,
};

pub fn extractZig(allocator: Allocator, wip: *Wip, options: ExtractOptions) Allocator.Error!void {
    var keywords = StringHashMapUnmanaged(Keyword){};
    defer keywords.deinit(allocator);
    try keywords.ensureTotalCapacity(allocator, @intCast(options.keywords.len));
    for (options.keywords) |keyword| {
        keywords.putAssumeCapacity(keyword.identifier, keyword);
    }

    var ast = try zig.Ast.parse(allocator, options.source, .zig);
    defer ast.deinit(allocator);

    const token_starts = ast.tokens.items(.start);
    if (ast.errors.len > 0) {
        for (ast.errors) |err| {
            const loc = zig.findLineColumn(ast.source, token_starts[err.token]);
            var buf: [1024]u8 = undefined;
            var buf_stream = io.fixedBufferStream(&buf);
            const buf_writer = buf_stream.writer();
            ast.renderError(err, buf_writer) catch {};
            log.err("{s}:{}:{}: {s}", .{ options.path, loc.line + 1, loc.column + 1, buf[0..buf_stream.pos] });
        }
        return;
    }

    const tags = ast.nodes.items(.tag);
    const main_tokens = ast.nodes.items(.main_token);
    var buf: [1]Ast.Node.Index = undefined;
    var i: Ast.Node.Index = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const call = ast.fullCall(&buf, i) orelse continue;
        const callee = switch (tags[call.ast.fn_expr]) {
            .field_access => ast.tokenSlice(ast.nodes.get(call.ast.fn_expr).data.rhs),
            .identifier => ast.tokenSlice(main_tokens[call.ast.fn_expr]),
            else => continue,
        };
        const keyword = keywords.get(callee) orelse continue;

        const msgctxt = if (keyword.msgctxt_arg) |arg|
            (try getStringArg(allocator, options.path, ast, call, arg)) orelse continue
        else
            null;
        defer if (msgctxt) |m| allocator.free(m);
        const msgid = (try getStringArg(allocator, options.path, ast, call, keyword.msgid_arg)) orelse continue;
        defer allocator.free(msgid);
        const msgid_plural = if (keyword.msgid_plural_arg) |arg|
            (try getStringArg(allocator, options.path, ast, call, arg)) orelse continue
        else
            null;
        defer if (msgid_plural) |m| allocator.free(m);
        const loc = zig.findLineColumn(ast.source, token_starts[main_tokens[i]]);

        try wip.addEntry(.{
            .msgctxt = msgctxt,
            .msgid = msgid,
            .msgid_plural = msgid_plural,
            .reference = .{
                .path = options.path,
                .line = loc.line,
            },
        });
    }
}

fn getStringArg(
    allocator: Allocator,
    path: []const u8,
    ast: Ast,
    call: Ast.full.Call,
    arg: usize,
) !?[]u8 {
    if (arg >= call.ast.params.len) return null;
    const idx = call.ast.params[arg];

    switch (ast.nodes.items(.tag)[idx]) {
        .string_literal => {
            const token = ast.nodes.items(.main_token)[idx];

            return zig.string_literal.parseAlloc(allocator, ast.tokenSlice(token)) catch |e| switch (e) {
                error.InvalidLiteral => {
                    const loc = zig.findLineColumn(ast.source, ast.tokens.items(.start)[token]);
                    log.err("{s}:{}:{}: invalid string literal", .{ path, loc.line + 1, loc.column + 1 });
                    return null;
                },
                error.OutOfMemory => error.OutOfMemory,
            };
        },
        .multiline_string_literal => {
            var buf = std.ArrayList(u8).init(allocator);

            const data = ast.nodes.items(.data)[idx];
            std.debug.print("{}\n", .{ast.tokens.items(.tag)[ast.nodes.items(.main_token)[idx]]});

            var tok = data.lhs;
            while (tok <= data.rhs) : (tok += 1) {
                // This should always be true, but checking won't hurt
                var s = ast.tokenSlice(tok);
                if (std.mem.startsWith(u8, s, "\\\\")) s = s[2..];

                try buf.appendSlice(s);
            }
            std.debug.print("{s}\n", .{buf.items});

            return try buf.toOwnedSlice();
        },
        else => return null,
    }
}

/// Work-in-progress (WIP) state of a PO file.
///
/// This handles deduplication of messages within and across files.
pub const Wip = struct {
    entries: HashMapUnmanaged(
        EntryKey,
        EntryData,
        EntryKey.Context,
        std.hash_map.default_max_load_percentage,
    ) = .{},
    arena: ArenaAllocator,

    pub fn init(allocator: Allocator) Wip {
        return .{ .arena = ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Wip) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Builds a `Po` from the current state.
    ///
    /// The `Wip` is reset to empty, and the caller takes ownership of the
    /// returned `Po`.
    pub fn build(self: *Wip) !Po {
        const allocator = self.arena.allocator();
        var entries = ArrayListUnmanaged(Po.Entry){};
        try entries.ensureTotalCapacityPrecise(allocator, self.entries.count());
        var wip_entry_iter = self.entries.iterator();
        while (wip_entry_iter.next()) |wip_entry| {
            entries.appendAssumeCapacity(.{
                .extracted_comments = try wip_entry.value_ptr.extracted_comments.toOwnedSlice(allocator),
                .references = try wip_entry.value_ptr.references.toOwnedSlice(allocator),
                .msgctxt = wip_entry.key_ptr.msgctxt,
                .msgid = wip_entry.key_ptr.msgid,
                .msgid_plural = wip_entry.value_ptr.msgid_plural,
                .msgstr = wip_entry.key_ptr.msgid,
                .plural_msgstrs = plural_msgstrs: {
                    if (wip_entry.value_ptr.msgid_plural) |msgid_plural| {
                        var slice = try allocator.alloc([]const u8, 1);
                        slice[0] = msgid_plural;
                        break :plural_msgstrs slice;
                    } else {
                        break :plural_msgstrs &.{};
                    }
                },
            });
        }
        self.entries.deinit(allocator);

        std.sort.heap(Po.Entry, entries.items, {}, entryLessThan);
        const po = Po{
            .entries = try entries.toOwnedSlice(allocator),
            .arena = self.arena,
        };
        self.* = .{ .arena = ArenaAllocator.init(self.arena.child_allocator) };
        return po;
    }

    fn entryLessThan(_: void, lhs: Po.Entry, rhs: Po.Entry) bool {
        if (lhs.msgctxt) |lhs_ctxt| {
            if (rhs.msgctxt) |rhs_ctxt| {
                switch (mem.order(u8, lhs_ctxt, rhs_ctxt)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {},
                }
            } else {
                return false;
            }
        } else if (rhs.msgctxt != null) {
            return true;
        }
        return mem.lessThan(u8, lhs.msgid, rhs.msgid);
    }

    pub const ParsedEntry = struct {
        extracted_comments: []const []const u8 = &.{},
        reference: Po.Reference,
        msgctxt: ?[]const u8 = null,
        msgid: []const u8,
        msgid_plural: ?[]const u8 = null,
    };

    /// Adds PO entry information parsed from a single call to `gettext` or a
    /// related function.
    pub fn addEntry(self: *Wip, entry: ParsedEntry) Allocator.Error!void {
        const allocator = self.arena.allocator();
        var wip_entry = try self.entries.getOrPut(allocator, .{
            .msgctxt = entry.msgctxt,
            .msgid = entry.msgid,
        });
        if (!wip_entry.found_existing) {
            if (entry.msgctxt) |msgctxt| {
                wip_entry.key_ptr.msgctxt = try allocator.dupe(u8, msgctxt);
            }
            wip_entry.key_ptr.msgid = try allocator.dupe(u8, entry.msgid);
            wip_entry.value_ptr.* = .{};
            if (entry.msgid_plural) |msgid_plural| {
                wip_entry.value_ptr.msgid_plural = try allocator.dupe(u8, msgid_plural);
            }
        }
        try wip_entry.value_ptr.extracted_comments.ensureUnusedCapacity(
            allocator,
            entry.extracted_comments.len,
        );
        for (entry.extracted_comments) |comment| {
            wip_entry.value_ptr.extracted_comments.appendAssumeCapacity(
                try allocator.dupe(u8, comment),
            );
        }
        try wip_entry.value_ptr.references.append(allocator, .{
            .path = try allocator.dupe(u8, entry.reference.path),
            .line = entry.reference.line,
        });
    }

    const EntryKey = struct {
        msgctxt: ?[]const u8,
        msgid: []const u8,

        const Context = struct {
            pub fn hash(_: @This(), key: EntryKey) u64 {
                var h = std.hash.Wyhash.init(0);
                if (key.msgctxt) |msgctxt| {
                    h.update(msgctxt);
                    h.update("\x04");
                }
                h.update(key.msgid);
                return h.final();
            }

            pub fn eql(_: @This(), k1: EntryKey, k2: EntryKey) bool {
                return streq(k1.msgctxt, k2.msgctxt) and mem.eql(u8, k1.msgid, k2.msgid);
            }

            fn streq(s1: ?[]const u8, s2: ?[]const u8) bool {
                if (s1) |v1| {
                    return if (s2) |v2| mem.eql(u8, v1, v2) else false;
                } else {
                    return s2 == null;
                }
            }
        };
    };

    const EntryData = struct {
        extracted_comments: ArrayListUnmanaged([]const u8) = .{},
        references: ArrayListUnmanaged(Po.Reference) = .{},
        msgid_plural: ?[]const u8 = null,
    };
};
