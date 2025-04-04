const std = @import("std");
const allocator = std.heap.wasm_allocator;

export fn alloc(len: usize) ?[*]u8 {
    return if (allocator.alloc(u8, len)) |slice|
        slice.ptr
    else |_|
        null;
}

const Handle = struct {
    obj: *anyopaque,
    func: *const fn (*anyopaque) void,
    fn handle(self: Handle) void {
        self.func(self.obj);
    }
};

const rowItem = struct {
    element: Value,
    selected: bool = false,
    fn new() !*@This() {
        const item = try allocator.create(@This());
        item.* = .{ .element = createElement("div") };
        item.*.onSelected();
        item.*.element.addEventListener("click", .{ .obj = item, .func = toggleSelect });
        return item;
    }

    fn toggleSelect(ptr: *anyopaque) void {
        const obj: *@This() = @ptrCast(@alignCast(ptr));
        obj.selected = !obj.selected;
        obj.onSelected();
    }
    fn onSelected(self: @This()) void {
        if (self.selected) {
            self.element.set("innerText", "selected");
        } else {
            self.element.set("innerText", "not selected");
        }
    }
};

export fn free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

fn printf(comptime fmt: []const u8, args: anytype) void {
    const string = std.fmt.allocPrint(std.heap.wasm_allocator, fmt, args) catch "failed to allocate string";
    print(string);
}

export fn callZig(id: usize) void {
    const handle = Value.func_array.items[id];
    @call(.auto, Handle.handle, .{handle});
}

fn createElement(element_name: []const u8) Value {
    return global.get("document").call("createElement", element_name);
}

fn print(str: []const u8) void {
    //TODO how to free any of these?
    // or some lazy way of stating that value is not needed
    _ = global.get("console").call("log", str);
}

const global = Value{ .id = 0 };

const Value = struct {
    id: i32,

    //TODO have some get that doesn't alloc new Value on js side
    fn get(value: Value, str: []const u8) Value {
        const object = jsGet(value.id, str.ptr, str.len);
        //TODO need to free
        return Value{ .id = object };
    }

    var next_function_id: usize = 0;
    var func_array: std.ArrayList(Handle) = std.ArrayList(Handle).init(allocator);

    fn addEventListener(value: Value, event_name: []const u8, function: Handle) void {
        _ = event_name;
        jsAddEventListener(value.id, next_function_id);
        _ = func_array.append(function) catch null;
        next_function_id += 1;
    }
    fn set(value: Value, property: []const u8, str: []const u8) void {
        jsSet(value.id, property.ptr, property.len, str.ptr, str.len);
    }

    fn call(value: Value, function_name: []const u8, arg1: anytype) Value {
        if (@TypeOf(arg1) == Value) {
            return Value{ .id = jsInvokeValue(value.id, function_name.ptr, function_name.len, arg1.id) };
        } else if (@TypeOf(arg1) == []const u8) {
            return Value{ .id = jsInvoke(value.id, function_name.ptr, function_name.len, arg1.ptr, arg1.len) };
        } else {
            @compileError("call only supports Value or []const u8");
        }
    }
};

export fn start() void {
    _ = _start() catch null;
}
fn _start() !void {
    const body = global.get("document").get("body");
    for (0..1000) |_| {
        //TODO deinit
        const handler = try rowItem.new();
        _ = body.call("appendChild", handler.element);
    }
}

extern "env" fn jsGet(id: i32, ptr: [*]const u8, len: usize) i32;
extern "env" fn jsSet(id: i32, ptr: [*]const u8, len: usize, ptr2: [*]const u8, len2: usize) void;
extern "env" fn jsInvoke(id: i32, ptr1: [*]const u8, len1: usize, ptr2: [*]const u8, len2: usize) i32;
extern "env" fn jsInvokeValue(self: i32, prt1: [*]const u8, len1: usize, arg1: i32) i32;
extern "env" fn jsAddEventListener(self: i32, func_pointer: usize) void;
