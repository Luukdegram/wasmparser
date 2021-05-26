const std = @import("std");
const wasm = @import("wasm.zig");
const Allocator = std.mem.Allocator;
const leb = std.leb;
const meta = std.meta;
const log = std.log.scoped(.parser);

pub const Result = struct {
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
    /// Missing an 'end' opcode when defining a constant expression.
    MissingEndForExpression,
    /// Missing an 'end' opcode at the end of a body expression.
    MissingEndForBody,
    /// The size defined in the section code mismatches with the actual payload size.
    MalformedSection,
    /// Stream has reached the end. Unreachable for caller and must be handled internally
    /// by the parser.
    EndOfStream,
    /// Ran out of memory when allocating.
    OutOfMemory,
};

const LebError = error{Overflow};

fn Parser(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        const Error = ReaderType.Error || ParseError || LebError;

        reader: ReaderType,

        fn init(reader: ReaderType) Self {
            return .{ .reader = reader };
        }

        fn parseWasm(self: *Self, gpa: *Allocator) Error!Result {
            var arena = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            return Result{
                .module = try self.parseModule(&arena.allocator),
                .arena = arena.state,
            };
        }

        /// Verifies that the first 4 bytes contains \0Asm and the following 4 bytes the wasm version we support.
        fn verifyMagicBytes(self: *Self) Error!void {
            var magic_bytes: [4]u8 = undefined;
            var wasm_version: [4]u8 = undefined;

            try self.reader.readNoEof(&magic_bytes);
            if (!std.mem.eql(u8, &magic_bytes, &std.wasm.magic)) return error.InvalidMagicByte;

            try self.reader.readNoEof(&wasm_version);
            if (!std.mem.eql(u8, &wasm_version, &std.wasm.version)) return error.InvalidWasmVersion;
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
                            const name_len = try readLeb(u8, reader);
                            const name = try gpa.alloc(u8, name_len);
                            custom.name = name;
                            try reader.readNoEof(name);

                            const data_len = len - name_len - @sizeOf(u32);
                            const data = try gpa.alloc(u8, data_len);
                            custom.data = data;
                            try reader.readNoEof(data);
                        }
                        try assertEnd(reader);
                    },
                    .type => {
                        for (try readVec(&module.types, reader, gpa)) |*type_val| {
                            if ((try reader.readByte()) != std.wasm.function_type) return error.ExpectedFuncType;

                            for (try readVec(&type_val.params, reader, gpa)) |*param| {
                                param.* = try readEnum(wasm.ValueType, reader);
                            }

                            for (try readVec(&type_val.returns, reader, gpa)) |*result| {
                                result.* = try readEnum(wasm.ValueType, reader);
                            }
                        }
                        try assertEnd(reader);
                    },
                    .import => {
                        for (try readVec(&module.imports, reader, gpa)) |*import| {
                            const module_len = try readLeb(u32, reader);
                            const module_name = try gpa.alloc(u8, module_len);
                            import.module = module_name;
                            try reader.readNoEof(module_name);

                            const name_len = try readLeb(u32, reader);
                            const name = try gpa.alloc(u8, name_len);
                            import.name = name;
                            try reader.readNoEof(module_name);

                            const kind = try readEnum(wasm.ExternalType, reader);
                            import.kind = switch (kind) {
                                .function => .{ .function = try readEnum(wasm.indices.Type, reader) },
                                .memory => .{ .memory = try readLimits(reader) },
                                .global => .{ .global = .{
                                    .valtype = try readEnum(wasm.ValueType, reader),
                                    .mutable = (try reader.readByte()) == 0x01,
                                } },
                                .table => .{ .table = .{
                                    .reftype = try readEnum(wasm.RefType, reader),
                                    .limits = try readLimits(reader),
                                } },
                            };
                        }
                        try assertEnd(reader);
                    },
                    .function => {
                        for (try readVec(&module.functions, reader, gpa)) |*func| {
                            func.type_idx = try readEnum(wasm.indices.Type, reader);
                        }
                        try assertEnd(reader);
                    },
                    .table => {
                        for (try readVec(&module.tables, reader, gpa)) |*table| {
                            table.* = .{
                                .reftype = try readEnum(wasm.RefType, reader),
                                .limits = try readLimits(reader),
                            };
                        }
                        try assertEnd(reader);
                    },
                    .memory => {
                        for (try readVec(&module.memories, reader, gpa)) |*memory| {
                            memory.* = .{ .limits = try readLimits(reader) };
                        }
                        try assertEnd(reader);
                    },
                    .global => {
                        for (try readVec(&module.globals, reader, gpa)) |*global| {
                            global.* = .{
                                .valtype = try readEnum(wasm.ValueType, reader),
                                .mutable = (try reader.readByte()) == 0x01,
                                .init = try readInit(reader),
                            };
                        }
                        try assertEnd(reader);
                    },
                    .@"export" => {
                        for (try readVec(&module.exports, reader, gpa)) |*exp| {
                            const name_len = try readLeb(u32, reader);
                            const name = try gpa.alloc(u8, name_len);
                            try reader.readNoEof(name);
                            exp.* = .{
                                .name = name,
                                .kind = try readEnum(wasm.ExternalType, reader),
                                .index = try readLeb(u32, reader),
                            };
                        }
                        try assertEnd(reader);
                    },
                    .start => {
                        module.start = try readEnum(wasm.indices.Func, reader);
                        try assertEnd(reader);
                    },
                    .element => @panic("TODO - Implement parsing element section"),
                    .code => {
                        for (try readVec(&module.code, reader, gpa)) |*code| {
                            const body_len = try readLeb(u32, reader);
                            if (body_len != reader.context.bytes_left) return error.MalformedSection;

                            // first parse the local declarations
                            {
                                // we compress the locals and save per valtype the count
                                var locals = std.AutoArrayHashMap(wasm.ValueType, u32).init(gpa);
                                defer locals.deinit();

                                const locals_len = try readLeb(u32, reader);
                                var i: u32 = 0;
                                while (i < locals_len) : (i += 1) {
                                    const count = try readLeb(u32, reader);
                                    const valtype = try readEnum(wasm.ValueType, reader);

                                    var result = try locals.getOrPut(valtype);
                                    if (result.found_existing) {
                                        result.entry.value += count;
                                    } else {
                                        result.entry.value = count;
                                    }
                                }
                                const local_slice = try gpa.alloc(wasm.sections.Code.Local, locals.count());
                                for (locals.items()) |entry, index| {
                                    local_slice[index] = .{ .valtype = entry.key, .count = entry.value };
                                }
                            }

                            {
                                var instructions = std.ArrayList(wasm.Instruction).init(gpa);
                                defer instructions.deinit();

                                while (readEnum(std.wasm.Opcode, reader)) |opcode| {
                                    const instr = try buildInstruction(opcode, gpa, reader);
                                    try instructions.append(instr);
                                } else |err| switch (err) {
                                    error.EndOfStream => {
                                        const maybe_end = instructions.popOrNull() orelse return error.MissingEndForBody;
                                        if (maybe_end.opcode != .end) return error.MissingEndForBody;
                                    },
                                    else => |e| return e,
                                }

                                code.body = instructions.toOwnedSlice();
                            }
                        }
                        try assertEnd(reader);
                    },
                    .data => {
                        for (try readVec(&module.data, reader, gpa)) |*data| {
                            data.index = try readEnum(wasm.indices.Mem, reader);
                            data.offset = try readInit(reader);

                            const init_len = try readLeb(u32, reader);
                            const init_data = try gpa.alloc(u8, init_len);
                            data.data = init_data;

                            try reader.readNoEof(init_data);
                        }
                        try assertEnd(reader);
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
fn readVec(ptr: anytype, reader: anytype, gpa: *Allocator) ![]ElementType(@TypeOf(ptr)) {
    const len = try readLeb(u32, reader);
    const slice = try gpa.alloc(ElementType(@TypeOf(ptr)), len);
    ptr.* = slice;
    return slice;
}

fn ElementType(comptime ptr: type) type {
    return meta.Child(meta.Child(ptr));
}

/// Uses either `readILEB128` or `readULEB128` depending on the
/// signedness of the given type `T`.
/// Asserts `T` is an integer.
fn readLeb(comptime T: type, reader: anytype) !T {
    if (comptime std.meta.trait.isSignedInt(T)) {
        return try leb.readILEB128(T, reader);
    } else {
        return try leb.readULEB128(T, reader);
    }
}

/// Reads an enum type from the given reader.
/// Asserts `T` is an enum
fn readEnum(comptime T: type, reader: anytype) !T {
    switch (@typeInfo(T)) {
        .Enum => |enum_type| return @intToEnum(T, try readLeb(enum_type.tag_type, reader)),
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
    const init: wasm.InitExpression = switch (@intToEnum(std.wasm.Opcode, opcode)) {
        .i32_const => .{ .i32_const = try readLeb(i32, reader) },
        .i64_const => .{ .i64_const = try readLeb(i64, reader) },
        .f32_const => .{ .f32_const = @bitCast(f32, try readLeb(u32, reader)) },
        .f64_const => .{ .f64_const = @bitCast(f64, try readLeb(u64, reader)) },
        .global_get => .{ .global_get = try readLeb(u32, reader) },
        else => unreachable,
    };

    if ((try readEnum(std.wasm.Opcode, reader)) != .end) return error.MissingEndForExpression;
    return init;
}

fn assertEnd(reader: anytype) !void {
    var buf: [1]u8 = undefined;
    const len = try reader.read(&buf);
    if (len != 0) return error.MalformedSection;
    if (reader.context.bytes_left != 0) return error.MalformedSection;
}

fn buildInstruction(opcode: std.wasm.Opcode, gpa: *Allocator, reader: anytype) !wasm.Instruction {
    var instr: wasm.Instruction = .{
        .opcode = opcode,
        .value = undefined,
    };

    instr.value = switch (opcode) {
        .block,
        .loop,
        .@"if",
        => .{ .blocktype = try readEnum(wasm.BlockType, reader) },
        .br,
        .br_if,
        .call,
        // ref.func 'x'
        @intToEnum(std.wasm.Opcode, 0xD2),
        .local_get,
        .local_set,
        .local_tee,
        .global_get,
        .global_set,
        wasm.table_get,
        wasm.table_set,
        .memory_size,
        .memory_grow,
        => .{ .u32 = try readLeb(u32, reader) },
        .call_indirect,
        .i32_load,
        .i64_load,
        .f32_load,
        .f64_load,
        .i32_load8_s,
        .i32_load8_u,
        .i32_load16_s,
        .i32_load16_u,
        .i64_load8_s,
        .i64_load8_u,
        .i64_load16_s,
        .i64_load16_u,
        .i64_load32_s,
        .i64_load32_u,
        .i32_store,
        .i64_store,
        .f32_store,
        .f64_store,
        .i32_store8,
        .i32_store16,
        .i64_store8,
        .i64_store16,
        .i64_store32,
        => .{ .multi = .{
            .x = try readLeb(u32, reader),
            .y = try readLeb(u32, reader),
        } },
        .br_table => blk: {
            const len = try readLeb(u32, reader);
            const list = try gpa.alloc(u32, len);

            for (list) |*item| {
                item.* = try readLeb(u32, reader);
            }
            break :blk .{ .list = .{ .data = list.ptr, .len = len } };
        },
        // ref.null 't'
        @intToEnum(std.wasm.Opcode, 0xD0) => .{ .reftype = try readEnum(wasm.RefType, reader) },
        // select 'vec(t)'
        @intToEnum(std.wasm.Opcode, 0x1C) => blk: {
            const len = try readLeb(u32, reader);
            const list = try gpa.alloc(wasm.ValueType, len);
            errdefer gpa.free(list);

            for (list) |*item| {
                item.* = try readEnum(wasm.ValueType, reader);
            }
            break :blk .{ .multi_valtype = .{ .data = list.ptr, .len = len } };
        },
        wasm.need_secondary => @as(wasm.Instruction.InstrValue, blk: {
            const secondary = try readEnum(wasm.SecondaryOpcode, reader);
            instr.secondary = secondary;
            switch (secondary) {
                .i32_trunc_sat_f32_s,
                .i32_trunc_sat_f32_u,
                .i32_trunc_sat_f64_s,
                .i32_trunc_sat_f64_u,
                .i64_trunc_sat_f32_s,
                .i64_trunc_sat_f32_u,
                .i64_trunc_sat_f64_s,
                .i64_trunc_sat_f64_u,
                => break :blk .{ .none = {} },
                .table_init,
                .table_copy,
                .memory_init,
                .data_drop,
                .memory_copy,
                => break :blk .{ .multi = .{
                    .x = try readLeb(u32, reader),
                    .y = try readLeb(u32, reader),
                } },
                else => break :blk .{ .u32 = try readLeb(u32, reader) },
            }
        }),
        .i32_const => .{ .i32 = try readLeb(i32, reader) },
        .i64_const => .{ .i64 = try readLeb(i64, reader) },
        .f32_const => .{ .f32 = @bitCast(f32, try readLeb(u32, reader)) },
        .f64_const => .{ .f64 = @bitCast(f64, try readLeb(u64, reader)) },
        else => .{ .none = {} },
    };

    return instr;
}
