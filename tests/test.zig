const wasmparser = @import("wasmparser");
const std = @import("std");
const testing = std.testing;
const parse = wasmparser.parse;
const wasm = wasmparser.wasm;

const ally = testing.allocator;

const Options = struct {
    code_len: ?usize = null,
    functions_len: ?usize = null,
    export_names: []const []const u8 = &.{},
    locals: []const struct {
        local: wasm.ValueType,
        count: usize,
    } = &.{},
};

fn testForOptions(content: []const u8, options: Options) !void {
    var stream = std.io.fixedBufferStream(content);
    var reader = stream.reader();
    var result = try parse(ally, reader);
    defer result.deinit(ally);

    const module = result.module;
    if (options.code_len) |len| {
        try testing.expectEqual(len, module.code.data.len);
    }

    if (options.functions_len) |len| {
        try testing.expectEqual(len, module.functions.data.len);
    }

    for (options.export_names, 0..) |name, i| {
        try testing.expectEqualStrings(name, module.exports.data[i].name);
    }

    for (options.locals, 0..) |local, i| {
        for (module.code.data[i].locals) |code_local| {
            if (local.local == code_local.valtype) {
                try testing.expectEqual(local.count, code_local.count);
            }
        }
    }
}

test "tests/add.wasm" {
    const file = @embedFile("add.wasm");
    try testForOptions(file, .{
        .code_len = 1,
        .functions_len = 1,
        .export_names = &.{"addTwo"},
    });
}

test "tests/call_indirect.wasm" {
    const file = @embedFile("call_indirect.wasm");
    try testForOptions(file, .{
        .code_len = 3,
        .functions_len = 3,
        .export_names = &.{
            "memory",
            "dispatch",
            "multiply",
            "main",
        },
    });
}

test "tests/wasi_hello_world.wasm except code" {
    const file = @embedFile("wasi_hello_world.wasm");
    var stream = std.io.fixedBufferStream(file);
    var options: wasmparser.parser.Options = .{};
    // skip code section
    options.skip_section[@enumToInt(std.wasm.Section.code)] = true;
    var result = try wasmparser.parser.parseWithOptions(ally, stream.reader(), options);
    defer result.deinit(ally);
}

test "tests/wasi_hello_world.wasm" {
    // This is not working, seems something not supported by parser in code section
    const file = @embedFile("wasi_hello_world.wasm");
    try testForOptions(file, .{});
}
