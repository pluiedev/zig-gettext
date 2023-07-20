const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xgettext = b.addExecutable(.{
        .name = "xgettext",
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/xgettext.zig" },
    });
    b.installArtifact(xgettext);

    const run_xgettext = b.addRunArtifact(xgettext);
    if (b.args) |args| {
        run_xgettext.addArgs(args);
    }

    const run_xgettext_step = b.step("xgettext", "Run xgettext");
    run_xgettext_step.dependOn(&run_xgettext.step);
}
