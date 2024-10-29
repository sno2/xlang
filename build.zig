const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const maybe_java_source: ?[]const u8 = b.option([]const u8, "java_source", "Java source path") orelse null;
    const java_compat = b.option(bool, "java_compat", "Use Java-compatible formatting (only for testing)") orelse false;

    const xlang_mod = b.addModule("xlang", .{
        .root_source_file = b.path("src/xlang.zig"),
        .target = target,
        .optimize = optimize,
    });
    {
        const build_options = b.addOptions();
        build_options.addOption(bool, "java_compat", java_compat);
        xlang_mod.addImport("build_options", build_options.createModule());
    }

    const exe = b.addExecutable(.{
        .name = "xlang",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("xlang", xlang_mod);
    b.installArtifact(exe);

    const example_tests = b.addTest(.{
        .root_source_file = b.path("examples/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_tests.root_module.addImport("xlang", xlang_mod);

    const build_options = b.addOptions();
    build_options.addOptionPath("root", b.path("."));
    build_options.addOption(?[]const u8, "java_source", maybe_java_source);
    example_tests.root_module.addImport("build_options", build_options.createModule());

    const run_example_tests = b.addRunArtifact(example_tests);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run the example tests");
    test_step.dependOn(&run_example_tests.step);

    const playground_step = b.step("playground", "Build the playground");

    const playground_lib = b.addExecutable(.{
        .name = "xlang",
        .root_source_file = b.path("playground/wasm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = optimize,
    });
    playground_lib.rdynamic = true;
    playground_lib.entry = .disabled;
    playground_lib.root_module.addImport("xlang", xlang_mod);

    const install_playground_lib = b.addInstallArtifact(playground_lib, .{
        .dest_dir = .{ .override = .{ .custom = "playground" } },
    });
    playground_step.dependOn(&install_playground_lib.step);

    const install_html = b.addInstallFile(b.path("playground/index.html"), "playground/index.html");
    playground_step.dependOn(&install_html.step);

    const install_logo = b.addInstallFile(b.path("playground/github-mark-white.png"), "playground/github-mark-white.png");
    playground_step.dependOn(&install_logo.step);

    const install_worker = b.addInstallFile(b.path("playground/worker.js"), "playground/worker.js");
    playground_step.dependOn(&install_worker.step);

    const pack_examples = b.addExecutable(.{
        .name = "pack_examples",
        .root_source_file = b.path("playground/pack_examples.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_pack_examples = b.addRunArtifact(pack_examples);
    run_pack_examples.addFileArg(b.path("examples"));
    run_pack_examples.addArg(b.getInstallPath(.{ .custom = "playground" }, "examples.json"));
    playground_step.dependOn(&run_pack_examples.step);
}
