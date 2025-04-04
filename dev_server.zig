const std = @import("std");
const ChildProcess = std.process.Child;
const fs = std.fs;
const time = std.time;
const os = std.os;
// TODO reuse allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const Allocator = std.mem.Allocator;
const postgres = @import("postgres.zig");

const server_name = @import("server.zig").server_name;

//TODO dev server should start postgres
pub fn main() !void {
    const allocator = gpa.allocator();

    postgres.allocator = allocator;
    postgres.onSigIntStopPostgres();
    try postgres.startPostgres();
    defer postgres.stopPostgres();

    const dir = try std.fs.selfExeDirPathAlloc(allocator);
    const server_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, server_name });

    var last_mod_time: i128 = 0;

    const initial_file_info = try fs.cwd().statFile(server_path);
    last_mod_time = initial_file_info.mtime;
    var current_child_process = try startBinary(server_path, allocator);

    //TODO replace with inotify
    while (true) {
        time.sleep(1 * time.ns_per_ms);

        const stat_result = try fs.cwd().statFile(server_path);

        if (stat_result.mtime != last_mod_time) {
            std.debug.print("Detected change in '{s}'!\n", .{server_path});

            const result = current_child_process.kill();
            std.debug.print("kill change in '{any}'!\n", .{result});
            last_mod_time = stat_result.mtime;

            current_child_process = try startBinary(server_path, allocator);
            std.debug.print("Started new process\n", .{});
        }
    }
}

fn startBinary(binary_path: []const u8, allocator: Allocator) !ChildProcess {
    var child_process = ChildProcess.init(&.{binary_path}, allocator);
    try child_process.spawn();
    return child_process;
}
