const std = @import("std");
const wasm_app_name = @import("server.zig").wasm_app_name;
const server_name = @import("server.zig").server_name;
const css_file = @import("server.zig").file_names.css;

pub fn build(b: *std.Build) !void {
    const start = try std.time.Instant.now();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const server_module = b.createModule(.{
        .root_source_file = b.path("server.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dependecies = [_][]const u8{ "httpz", "jetquery", "zts" };
    for (dependecies) |dependency_name| {
        const dependency = b.dependency(dependency_name, .{
            .target = target,
            .optimize = optimize,
        });
        server_module.addImport(dependency_name, dependency.module(dependency_name));
    }

    const use_llvm = false;
    const server = b.addExecutable(.{
        .name = server_name,
        .root_module = server_module,
        .use_llvm = use_llvm,
    });
    b.installArtifact(server);

    const wasm_module = b.createModule(.{
        .root_source_file = b.path("wasm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = optimize,
    });

    const dev_server = b.addExecutable(.{ .name = "dev_server", .root_source_file = b.path("dev_server.zig"), .target = target, .optimize = optimize, .use_llvm = use_llvm });
    const db_client = b.addExecutable(.{ .name = "db", .root_source_file = b.path("db.zig"), .target = target, .optimize = optimize, .use_llvm = use_llvm });

    const wasm_app = b.addExecutable(.{ .name = wasm_app_name, .root_module = wasm_module });
    wasm_app.entry = .disabled;
    wasm_app.rdynamic = true;
    b.installArtifact(wasm_app);
    b.installArtifact(dev_server);

    const tailwindcss = b.addSystemCommand(&.{
        "tailwindcss",
        "-i",
    });
    tailwindcss.addFileArg(b.path("main.css"));
    var dir = try std.fs.cwd().openDir("views/", .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            tailwindcss.addFileInput(b.path(b.fmt("views/{s}", .{entry.path})));
        }
    }

    tailwindcss.addArg("-o");
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(tailwindcss.addOutputFileArg(css_file), .bin, css_file).step);

    const run_server = b.addRunArtifact(dev_server);
    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_server.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_server.addArgs(args);
    }

    const db_step = b.step("db", "Run psql client");
    db_step.dependOn(&b.addRunArtifact(db_client).step);

    const run_step = b.step("run", "Run web server");
    run_step.dependOn(&run_server.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .root_source_file = b.path("server.zig"),
    })).step);

    const finish = try std.time.Instant.now();
    const duration: f64 = @floatFromInt(finish.since(start));
    std.debug.print("graph build duration {d:.3}ms \n", .{duration / std.time.ns_per_ms});
}
