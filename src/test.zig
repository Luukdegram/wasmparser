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
    var reader = std.io.fixedBufferStream(content).reader();
    var result = try parse(ally, reader);
    defer result.deinit(ally);

    const module = result.module;
    if (options.code_len) |len| {
        try testing.expectEqual(len, module.code.len);
    }

    if (options.functions_len) |len| {
        try testing.expectEqual(len, module.functions.len);
    }

    for (options.export_names) |name, i| {
        try testing.expectEqualStrings(name, module.exports[i].name);
    }

    for (options.locals) |local, i| {
        for (module.code[i].locals) |code_local| {
            if (local.local == code_local.valtype) {
                try testing.expectEqual(local.count, code_local.count);
            }
        }
    }
}

test "tests/add.wasm" {
    const file = @embedFile("../tests/add.wasm");
    try testForOptions(file, .{
        .code_len = 1,
        .functions_len = 1,
        .export_names = &.{"addTwo"},
    });
}

test "tests/call_indirect.wasm" {
    const file = @embedFile("../tests/call_indirect.wasm");
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
