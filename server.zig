const std = @import("std");
const httpz = @import("httpz");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const jetquery = @import("jetquery");
const Schema = @import("Schema.zig");
const postgres = @import("postgres.zig");
const string = []const u8;
const zts = @import("zts");

//TODO dedup all allocators
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const print = std.log.info;
const port = 3000;

pub const wasm_app_name = "main";
pub const server_name = "main";

pub const file_names = struct {
    const wasm = wasm_app_name ++ ".wasm";
    pub const css = "main.css";
};

fn resource(name: string) type {
    return struct {
        const index = "/" ++ name;
    };
}

const paths = struct {
    const files = resource("files");
    const root = "/";
    const wasm = "/wasm";
    const wasm_file = "/" ++ file_names.wasm;
    const css_file = "/" ++ file_names.css;
};

pub fn main() !void {
    const allocator = gpa.allocator();

    // TODO somehow use arena allocator ? repo per request ???
    var repo = try Repo.init(allocator, .{
        .adapter = .{
            .database = postgres.db_name,
            .username = postgres.db_user,
            .password = "",
            .hostname = "127.0.0.1",
            .port = 5432,
        },
    });

    schemaPlusSeeds(&repo) catch {};

    var server = try httpz.Server(@TypeOf(&repo)).init(allocator, .{ .port = port }, &repo);
    defer {
        print("shutting down httpz", .{});
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get(paths.files.index, makeHandler("Files/index"), .{});
    router.get(paths.root, makeHandler("handlers/home"), .{});
    router.get(paths.wasm, makeHandler("handlers/wasm"), .{});
    router.get(paths.wasm_file, wasmFile, .{});
    router.get(paths.css_file, cssFile, .{});

    print("processor model: {s}", .{builtin.cpu.model.name});
    print("listening on :{d}", .{port});
    try server.listen();
}

const httpzHandler = fn (*Repo, *httpz.Request, *httpz.Response) anyerror!void;

fn responseType(name: string) type {
    var lower: [name.len]u8 = undefined;
    for (name, 0..) |char, index| {
        if (index == 0) {
            lower[index] = std.ascii.toLower(char);
        } else {
            lower[index] = char;
        }
    }
    const template = @embedFile("views/" ++ lower ++ ".html");

    return struct {
        out: std.ArrayList(u8).Writer,
        repo: *Repo,
        fn print(self: @This(), comptime section: string, args: anytype) !void {
            try zts.print(template, section, args, self.out);
        }

        fn printHeader(self: @This(), args: anytype) !void {
            try zts.printHeader(template, args, self.out);
        }

        fn writeHeader(self: @This()) !void {
            try zts.writeHeader(template, self.out);
        }

        fn write(self: @This(), section: string) !void {
            try zts.write(template, section, self.out);
        }
    };
}

fn makeHandler(name: string) httpzHandler {
    var it = std.mem.splitScalar(u8, name, '/');
    const space = it.next().?;
    const field = it.next().?;

    const func = @field(@field(@This(), space), field);
    return struct {
        fn handler(repo: *Repo, _: *httpz.Request, response: *httpz.Response) !void {
            var buffer = std.ArrayList(u8).init(response.arena);
            const out = buffer.writer();
            const layout = @embedFile("views/layout.html");

            try zts.writeHeader(layout, out);
            try zts.print(layout, "title", .{ .title = space, .css = paths.css_file }, out);
            try func(responseType(name){ .out = out, .repo = repo });
            try zts.write(layout, "close-body", out);
            response.body = buffer.items;
        }
    }.handler;
}

const Repo = jetquery.Repo(.postgresql, Schema);

fn table(writer: std.ArrayList(u8).Writer, title: string, records: anytype) !void {
    const resultRowType = @typeInfo(@TypeOf(records)).pointer.child;
    const template = @embedFile("views/table.html");
    try zts.printHeader(template, .{ .title = title }, writer);
    const query_fields = @typeInfo(resultRowType).@"struct".fields;

    inline for (query_fields) |field| {
        if (!std.mem.startsWith(u8, field.name, "_")) {
            try zts.print(template, "th", .{ .value = field.name }, writer);
        }
    }
    try zts.write(template, "th-close", writer);

    for (records) |file| {
        try zts.write(template, "tr", writer);
        inline for (query_fields) |field| {
            if (!std.mem.startsWith(u8, field.name, "_")) {
                const value = @field(file, field.name);
                switch (@TypeOf(value)) {
                    i32 => try zts.print(template, "td-number", .{ .value = value }, writer),
                    string => try zts.print(template, "td-string", .{ .value = value }, writer),
                    else => try zts.print(template, "td", .{ .value = value }, writer),
                }
            }
        }

        try zts.write(template, "tr-close", writer);
    }

    try zts.write(template, "tbody-close", writer);
}

const Files = struct {
    fn index(response: anytype) !void {
        const files = try jetquery.Query(.postgresql, Schema, .File).all(response.repo);
        try table(response.out, @typeName(@This()), files);
    }
};

const handlers = struct {
    fn home(response: anytype) !void {
        try response.printHeader(.{ .wasm = paths.wasm, .files = paths.files.index });
    }

    fn wasm(response: anytype) !void {
        try response.writeHeader();
        try response.print("streaming", .{ .wasm_file = paths.wasm_file });
        try response.write("rest");
    }
};

fn schemaPlusSeeds(repo: *Repo) !void {
    const t = jetquery.schema.table;
    try repo.createTable(
        "files",
        &.{
            t.primaryKey("id", .{}),
            t.column("filename", .string, .{ .unique = true }),
            t.timestamps(.{}),
        },
        .{ .if_not_exists = true },
    );
    try repo.insert(.File, .{ .filename = "bar" });
    try repo.insert(.File, .{ .filename = "foo" });
}

fn sendFile(allocator: Allocator, comptime name: string) !string {
    const dir = try std.fs.selfExeDirPathAlloc(allocator);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/" ++ name, .{dir});
    const wasm_file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
    defer wasm_file.close();

    const file_size = try wasm_file.getEndPos();
    const buffer = try allocator.alloc(u8, file_size);
    const bytesRead = try wasm_file.readAll(buffer);

    if (bytesRead != file_size) {
        return error.UnexpectedEndOfFile;
    }
    return buffer;
}

fn wasmFile(_: *Repo, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .WASM;
    res.body = try sendFile(res.arena, file_names.wasm);
}
fn cssFile(_: *Repo, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .CSS;
    res.body = try sendFile(res.arena, file_names.css);
}
