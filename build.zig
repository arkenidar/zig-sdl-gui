const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Optional: build a socket-free, local-only binary by excluding net/.
    const enable_net = b.option(bool, "net", "Compile the TCP umbilical transport (net/)") orelse true;
    const options = b.addOptions();
    options.addOption(bool, "enable_net", enable_net);

    // C interop via translate-c (replaces @cImport in this Zig version).
    // The created module both translates the headers and links the system libs.
    const cdefs_tc = b.addTranslateC(.{
        .root_source_file = b.path("src/cdefs.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cdefs_tc.linkSystemLibrary("sdl3", .{});
    cdefs_tc.linkSystemLibrary("sdl3-ttf", .{});
    cdefs_tc.linkSystemLibrary("sdl3-image", .{});
    cdefs_tc.linkSystemLibrary("luajit", .{});
    const cdefs = cdefs_tc.createModule();

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "cdefs", .module = cdefs },
        },
    });
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "zigui",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — runs all `test` blocks (links SDL/Lua via the module).
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
