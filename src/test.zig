const wasmparser = @import("wasmparser");
const std = @import("std");
const testing = std.testing;
const parse = wasmparser.parse;

const ally = testing.allocator;

test "tests/add.wasm" {
    const file = @embedFile("../tests/add.wasm");
    var reader = std.io.fixedBufferStream(file).reader();
    var result = try parse(ally, reader);
    defer result.deinit(ally);
}
