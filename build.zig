const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const msgpack_dep = b.dependency("msgpack", .{
        .target = target,
        .optimize = optimize,
    });
    const msgpack_mod = msgpack_dep.module("msgpack");

    const websocket_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });
    const websocket_mod = websocket_dep.module("websocket");

    // Library module
    const pokerforbots_mod = b.addModule("pokerforbots", .{
        .root_source_file = b.path("src/lib.zig"),
    });
    pokerforbots_mod.addImport("msgpack", msgpack_mod);
    pokerforbots_mod.addImport("websocket", websocket_mod);

    // Tests
    const lib_tests_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_tests_module.addImport("msgpack", msgpack_mod);
    lib_tests_module.addImport("websocket", websocket_mod);

    const lib_tests = b.addTest(.{
        .root_module = lib_tests_module,
    });

    const run_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // Random bot example
    const random_bot_module = b.createModule(.{
        .root_source_file = b.path("examples/random_bot.zig"),
        .target = target,
        .optimize = optimize,
    });
    random_bot_module.addImport("pokerforbots", pokerforbots_mod);
    random_bot_module.addImport("msgpack", msgpack_mod);
    random_bot_module.addImport("websocket", websocket_mod);

    const random_bot = b.addExecutable(.{
        .name = "random-bot",
        .root_module = random_bot_module,
    });
    b.installArtifact(random_bot);

    // Calling station bot example
    const calling_station_module = b.createModule(.{
        .root_source_file = b.path("examples/calling_station_bot.zig"),
        .target = target,
        .optimize = optimize,
    });
    calling_station_module.addImport("pokerforbots", pokerforbots_mod);
    calling_station_module.addImport("msgpack", msgpack_mod);
    calling_station_module.addImport("websocket", websocket_mod);

    const calling_station_bot = b.addExecutable(.{
        .name = "calling-station-bot",
        .root_module = calling_station_module,
    });
    b.installArtifact(calling_station_bot);

    // Run commands for examples
    const run_random = b.addRunArtifact(random_bot);
    if (b.args) |args| {
        run_random.addArgs(args);
    }
    const run_random_step = b.step("run-random", "Run the random bot example");
    run_random_step.dependOn(&run_random.step);

    const run_calling = b.addRunArtifact(calling_station_bot);
    if (b.args) |args| {
        run_calling.addArgs(args);
    }
    const run_calling_step = b.step("run-calling", "Run the calling station bot example");
    run_calling_step.dependOn(&run_calling.step);
}
