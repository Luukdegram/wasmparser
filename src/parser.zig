const std = @import("std");
const wasm = @import("wasm.zig");
const Allocator = std.mem.Allocator;
const leb = std.leb;
const meta = std.meta;

pub const Result = extern struct {
    module: wasm.Module,
    arena: std.heap.ArenaAllocator.State,

    /// Frees all memory that was allocated when parsing.
    /// Usage of `module` or `Result` itself is therefore illegal.
    pub fn deinit(self: *Result, gpa: *Allocator) void {
        self.arena.promote(gpa).deinit();
        self.* = undefined;
    }
};

/// Parses a wasm stream into a `Result` containing both the `wasm.Module` as well
/// as an arena state that contains all allocated memory for easy cleanup.
pub fn parse(gpa: *Allocator, reader: anytype) Parser(@TypeOf(reader)).Error!Result {
    var parser = Parser(@TypeOf(reader)).init(reader);
    return parser.parseWasm(gpa);
}

/// Error set containing parsing errors.
/// Merged with reader's errorset by `Parser`
pub const ParseError = error{
    /// The magic byte is either missing or does not contain \0Asm
    InvalidMagicByte,
    /// The wasm version is either missing or does not match the supported version.
    InvalidWasmVersion,
    /// Expected the functype byte while parsing the Type section but did not find it.
    ExpectedFuncType,
};

fn Parser(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        const Error = ReaderType.Error || ParseError;

        reader: ReaderType,

        fn init(gpa: *Allocator, reader: ReaderType) Self {
            return .{ .reader = reader };
        }

        fn parseWasm(self: *Self, gpa: *Allocator) Error!Result {
            var arena = std.heap.ArenaAllocator.init(gpa);
            return Result{
                .module = parseModule(&arena.allocater),
                .arena = arena.state,
            };
        }

        /// Verifies that the first 4 bytes contains \0Asm and the following 4 bytes the wasm version we support.
        fn verifyMagicBytes(self: *Self) Error!void {
            var magic_bytes: [4]u8 = undefined;
            var wasm_version: [4]u8 = undefined;

            try self.reader.readNoEof(&magic_bytes);
            if (!std.mem.eql(u8, &magic_bytes, std.wasm.magic)) return error.InvalidMagicByte;

            try self.reader.readNoEof(&wasm_version);
            if (!std.mem.eql(u8, &wasm_version, std.wasm.version)) return error.InvalidWasmVersion;
        }

        fn parseModule(self: *Self, gpa: *Allocator) Error!wasm.Module {
            try self.verifyMagicBytes();

            var module: wasm.Module = .{};

            while (self.reader.readByte()) |byte| {
                const len = try readLeb(u32, self.reader);
                var reader = std.io.limitedReader(self.reader, len).reader();

                switch (@intToEnum(wasm.Section, byte)) {
                    .custom => {
                        for (try readVec(&module.custom, reader, gpa)) |*custom| {
                            // for custom section we read name and data section at once rather
                            // than read every byte individually as that's slow.
                            const name_len = try readLeb(u32, reader);
                            const name = try gpa.alloc(u8, name_len);
                            custom.name = .{ .data = name.ptr, .len = name_len };
                            try reader.readNoEof(name);

                            const data_len = len - name_len;
                            const data = try gpa.alloc(u8, data_len);
                            custom.data = .{ .data = data.ptr, .len = data_len };
                            try reader.readNoEof(data);
                        }
                    },
                    .type => {
                        for (try readVec(&module.types, reader, gpa)) |*type_val| {
                            if (try reader.readByte() != std.wasm.function_type) return error.ExpectedFuncType;

                            for (try readVec(&type_val.params, reader, gpa)) |*param| {
                                param.* = try readEnum(wasm.ValueType, reader);
                            }

                            for (try readVec(&type_val.results, reader, gpa)) |*result| {
                                result.* = try readEnum(wasm.ValueType, reader);
                            }
                        }
                    },
                    .import => {
                        for (try readVec(&module.imports, reader, gpa)) |*import| {
                            const module_len = try readLeb(u32, reader);
                            const module_name = try gpa.alloc(u8, module_len);
                            import.module = .{ .data = module_name.ptr, .len = module_len };
                            try reader.readNoEof(module_name);

                            const name_len = try readLeb(u32, reader);
                            const name = try gpa.alloc(u8, name_len);
                            import.name = .{ .data = name.ptr, .len = name_len };
                            try reader.readNoEof(module_name);

                            const kind = try readEnum(wasm.sections.Import.Kind, reader);
                            import.kind = switch (kind) {
                                .function => .{ .function = try readEnum(wasm.ValueType, reader) },
                                .memory => .{ .limits = try readLimits(reader) },
                                .global => .{ .global = .{
                                    .valtype = try readEnum(wasm.ValueType, reader),
                                    .mutable = (try reader.readByte() == 0x01),
                                } },
                                .table => .{
                                    .reftype = try readEnum(wasm.RefType, reader),
                                    .limits = try readLimits(reader),
                                },
                            };
                        }
                    },
                    .function => {
                        for (try readVec(&module.functions, reader, gpa)) |*func| {
                            func.* = try readEnum(wasm.indices.Type, reader);
                        }
                    },
                    .table => {
                        for (try readVec(&module.tables, reader, gpa)) |*table| {
                            table.* = .{
                                .reftype = try readEnum(wasm.RefType, reader),
                                .limits = try readLimits(reader),
                            };
                        }
                    },
                    .memory => {
                        for (try readVec(&module.memories, reader, gpa)) |*memory| {
                            memory.* = .{ .limits = try readLimits(reader) };
                        }
                    },
                    .global => {
                        for (try readVec(&module.globals, reader, gpa)) |*global| {
                            global.* = .{
                                .valtype = try readEnum(wasm.ValueType, reader),
                                .mutable = (try reader.readByte() == 0x01),
                                .init = try readInit(reader),
                            };
                        }
                    },
                    .@"export" => {
                        for (try readVec(&module.exports, reader, gpa)) |*exp| {
                            const name_len = try readLeb(u32, reader);
                            const name = try gpa.alloc(u8, name_len);
                            exp.name = .{ .data = name.ptr, .len = name_len };
                            try reader.readNoEof(name);
                            exp.kind = try readEnum(wasm.ExternalType, reader);
                        }
                    },
                }
            } else |err| switch (err) {
                error.EndOfStream => {},
                else => |e| return e,
            }

            return module;
        }
    };
}

/// First reads the count from the reader and then allocate
/// a slice of ptr child's element type.
fn readVec(ptr: anytype, reader: anytype, gpa: *Allocator) ![]ElementType(ptr) {
    const len = try readLeb(u32, reader);
    const slice = try gpa.alloc(ElementType(ptr), len);
    ptr.* = .{ .data = slice.ptr, .len = slice.len };
    return slice;
}

fn ElementType(ptr: anytype) type {
    return meta.Child(meta.Child(@TypeOf(ptr)));
}

/// Uses either `readILEB128` or `readULEB128` depending on the
/// signedness of the given type `T`.
/// Asserts `T` is an integer.
fn readLeb(comptime T: type, reader: anytype) T {
    if (std.meta.trait.isSignedInt(T)) {
        return leb.readILEB128(T, reader);
    } else {
        return leb.readULEB128(T, reader);
    }
}

/// Reads an enum type from the given reader.
/// Asserts `T` is an enum
fn readEnum(comptime T: type, reader: anytype) T {
    switch (@typeInfo(T)) {
        .Enum => |enum_type| return readLeb(enum_type.tag_type, reader),
        else => @compileError("T must be an enum. Instead was given type " ++ @typeName(T)),
    }
}

fn readLimits(reader: anytype) !wasm.Limits {
    const min = try readLeb(u32, reader);
    return wasm.Limits{
        .min = min,
        .max = if (min == 0) null else try readLeb(u32, reader),
    };
}

fn readInit(reader: anytype) !wasm.InitExpression {
    const opcode = try reader.readByte();
    return @as(wasm.InitExpression, switch (@intToEnum(std.wasm.Opcode, opcode)) {
        .i32_const => .{ .i32_const = try readLeb(u32, reader) },
        .i64_const => .{ .i64_const = try readLeb(u64, reader) },
        .f32_const => .{ .fr32_const = @bitCast(f32, try readLeb(u32, reader)) },
        .f64_const => .{ .f64_const = @bitCast(f64, try readLeb(u64, reader)) },
        .global_get => .{ .global_get = try readLeb(u32, reader) },
    });
}
