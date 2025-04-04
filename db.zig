const std = @import("std");
const postgresq = @import("postgres.zig");
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    const allocator = gpa.allocator();
    postgresq.allocator = allocator;

    try postgresq.startPostgres();
    defer postgresq.stopPostgres();

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("PGHOST", "/tmp");
    var child = std.process.Child.init(&.{
        "psql",
        postgresq.db_name,
    }, allocator);
    child.env_map = &env_map;
    try child.spawn();
    _ = try child.wait();
}
