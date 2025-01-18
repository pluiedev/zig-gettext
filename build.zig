const std = @import("std");

const binaries = &[_][]const u8{
    "msgbundle",
    "msgfmt",
    "xgettext",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gettext = b.addModule("gettext", .{
        .root_source_file = b.path("src/gettext.zig"),
    });

    const tests = b.addTest(.{
        .root_source_file = b.path("src/gettext.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.step("test", "Run project tests");
    run_tests.dependOn(&tests.step);

    for (binaries) |bin| {
        addBin(b, bin, target, optimize, gettext);
    }
}

fn addBin(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
    gettext: *std.Build.Module,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path(b.fmt("src/bin/{s}.zig", .{name})),
    });
    exe.root_module.addImport("gettext", gettext);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| {
        run.addArgs(args);
    }

    const run_step = b.step(name, b.fmt("Run {s}", .{name}));
    run_step.dependOn(&run.step);
}
