const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zig-anthropic", .{
        .root_source_file = b.path("src/llm.zig"),
    });

    const streaming_example = b.addExecutable(.{
        .name = "streaming",
        .root_source_file = b.path("examples/streaming.zig"),
        .target = target,
        .optimize = optimize,
    });
    streaming_example.root_module.addImport("zig-anthropic", module);
    b.installArtifact(streaming_example);

    const non_streaming_example = b.addExecutable(.{
        .name = "non-streaming",
        .root_source_file = b.path("examples/non-streaming.zig"),
        .target = target,
        .optimize = optimize,
    });
    non_streaming_example.root_module.addImport("zig-anthropic", module);
    b.installArtifact(non_streaming_example);
}
