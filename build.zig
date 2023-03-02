const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    b.addModule(.{
        .name = "wasmparser",
        .source_file = .{ .path = "src/lib.zig" },
    });

    var tests = b.addTest(.{
        .root_source_file = .{ .path = "tests/test.zig" },
    });
    tests.addModule("wasmparser", b.modules.get("wasmparser").?);
    b.step("test", "Run library tests").dependOn(&tests.step);
}
