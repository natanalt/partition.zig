const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("example", "example/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackagePath("partition", "src/partition.zig");
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    
    const run_step = b.step("run", "Run the example program");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest("test/tests.zig");
    tests.addPackagePath("partition", "src/partition.zig");
    tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&tests.step);
}
