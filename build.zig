const std = @import("std");

const binaries = &[_][]const u8{
    "msgfmt",
    "xgettext",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gettext = b.addModule("gettext", .{
        .source_file = .{ .path = "src/gettext.zig" },
    });

    for (binaries) |bin| {
        addBin(b, bin, target, optimize, gettext);
    }
}

fn addBin(
    b: *std.Build,
    name: []const u8,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
    gettext: *std.Build.Module,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .target = target,
        .optimize = optimize,
        .root_source_file = .{
            .path = b.pathJoin(&.{ "src", "bin", b.fmt("{s}.zig", .{name}) }),
        },
    });
    exe.addModule("gettext", gettext);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| {
        run.addArgs(args);
    }

    const run_step = b.step(name, b.fmt("Run {s}", .{name}));
    run_step.dependOn(&run.step);
}
