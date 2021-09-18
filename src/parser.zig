const std = @import("std");
const wasm = @import("wasm.zig");
const Allocator = std.mem.Allocator;
const leb = std.leb;
const meta = std.meta;

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

        reader: std.io.CountingReader(ReaderType),

        fn init(reader: ReaderType) Self {
            return .{ .reader = std.io.countingReader(reader) };
        }

        fn parseWasm(self: *Self, gpa: *Allocator) Error!Result {
            var arena = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            return Result{
                .module = try self.parseModule(&arena.allocator),
                .arena = arena.state,
            };
        }

        /// Verifies that the first 4 bytes contains \0Asm
        fn verifyMagicBytes(self: *Self) Error!void {
            var magic_bytes: [4]u8 = undefined;

            try self.reader.reader().readNoEof(&magic_bytes);
            if (!std.mem.eql(u8, &magic_bytes, &std.wasm.magic)) return error.InvalidMagicByte;
        }

        fn parseModule(self: *Self, gpa: *Allocator) Error!wasm.Module {
            try self.verifyMagicBytes();
            const version = try self.reader.reader().readIntLittle(u32);

            var module: wasm.Module = .{ .version = version };

            // custom sections do not provide a count, as they are each their very own
            // section that simply share the same section ID. For this reason we use
            // an arraylist so we can append them individually.
            var custom_sections = std.ArrayList(wasm.sections.Custom).init(gpa);

            while (self.reader.reader().readByte()) |byte| {
                const len = try readLeb(u32, self.reader.reader());
                var reader = std.io.limitedReader(self.reader.reader(), len).reader();

                switch (@intToEnum(wasm.Section, byte)) {
                    .custom => {
                        const start = self.reader.bytes_read;
                        const custom = try custom_sections.addOne();
                        const name_len = try readLeb(u32, reader);
                        const name = try gpa.alloc(u8, name_len);
                        try reader.readNoEof(name);

                        const data = try gpa.alloc(u8, reader.context.bytes_left);
                        try reader.readNoEof(data);

                        custom.* = .{ .name = name, .data = data, .start = start, .end = self.reader.bytes_read };
                    },
                    .type => {
                        module.types.start = self.reader.bytes_read;
                        for (try readVec(&module.types.data, reader, gpa)) |*type_val| {
                            if ((try reader.readByte()) != std.wasm.function_type) return error.ExpectedFuncType;

                            for (try readVec(&type_val.params, reader, gpa)) |*param| {
                                param.* = try readEnum(wasm.ValueType, reader);
                            }

                            for (try readVec(&type_val.returns, reader, gpa)) |*result| {
                                result.* = try readEnum(wasm.ValueType, reader);
                            }
                        }
                        module.types.end = self.reader.bytes_read;
                        try assertEnd(reader);
                    },
                    .import => {
                        module.imports.start = self.reader.bytes_read;
                        for (try readVec(&module.imports.data, reader, gpa)) |*import| {
                            const module_len = try readLeb(u32, reader);
                            const module_name = try gpa.alloc(u8, module_len);
                            import.module = module_name;
                            try reader.readNoEof(module_name);

                            const name_len = try readLeb(u32, reader);
                            const name = try gpa.alloc(u8, name_len);
                            import.name = name;
                            try reader.readNoEof(name);

                            const kind = try readEnum(wasm.ExternalType, reader);
                            import.kind = switch (kind) {
                                .function => .{ .function = try readEnum(wasm.indexes.Type, reader) },
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
                        module.imports.end = self.reader.bytes_read;
                        try assertEnd(reader);
                    },
                    .function => {
                        module.functions.start = self.reader.bytes_read;
                        for (try readVec(&module.functions.data, reader, gpa)) |*func| {
                            func.type_idx = try readEnum(wasm.indexes.Type, reader);
                        }
                        module.functions.end = self.reader.bytes_read;
                        try assertEnd(reader);
                    },
                    .table => {
                        module.tables.start = self.reader.bytes_read;
                        for (try readVec(&module.tables.data, reader, gpa)) |*table| {
                            table.* = .{
                                .reftype = try readEnum(wasm.RefType, reader),
                                .limits = try readLimits(reader),
                            };
                        }
                        module.tables.end = self.reader.bytes_read;
                        try assertEnd(reader);
                    },
                    .memory => {
                        module.memories.start = self.reader.bytes_read;
                        for (try readVec(&module.memories.data, reader, gpa)) |*memory| {
                            memory.* = .{ .limits = try readLimits(reader) };
                        }
                        module.memories.end = self.reader.bytes_read;
                        try assertEnd(reader);
                    },
                    .global => {
                        module.globals.start = self.reader.bytes_read;
                        for (try readVec(&module.globals.data, reader, gpa)) |*global| {
                            global.* = .{
                                .valtype = try readEnum(wasm.ValueType, reader),
                                .mutable = (try reader.readByte()) == 0x01,
                                .init = try readInit(reader),
                            };
                        }
                        module.globals.end = self.reader.bytes_read;
                        try assertEnd(reader);
                    },
                    .@"export" => {
                        module.exports.start = self.reader.bytes_read;
                        for (try readVec(&module.exports.data, reader, gpa)) |*exp| {
                            const name_len = try readLeb(u32, reader);
                            const name = try gpa.alloc(u8, name_len);
                            try reader.readNoEof(name);
                            exp.* = .{
                                .name = name,
                                .kind = try readEnum(wasm.ExternalType, reader),
                                .index = try readLeb(u32, reader),
                            };
                        }
                        module.exports.end = self.reader.bytes_read;
                        try assertEnd(reader);
                    },
                    .start => {
                        module.start = try readEnum(wasm.indexes.Func, reader);
                        try assertEnd(reader);
                    },
                    .element => {
                        module.elements.start = self.reader.bytes_read;
                        for (try readVec(&module.elements.data, reader, gpa)) |*elem| {
                            elem.table_idx = try readEnum(wasm.indexes.Table, reader);
                            elem.offset = try readInit(reader);

                            for (try readVec(&elem.func_idxs, reader, gpa)) |*idx| {
                                idx.* = try readEnum(wasm.indexes.Func, reader);
                            }
                        }
                        module.elements.end = self.reader.bytes_read;
                        try assertEnd(reader);
                    },
                    .code => {
                        module.code.start = self.reader.bytes_read;
                        for (try readVec(&module.code.data, reader, gpa)) |*code| {
                            const body_len = try readLeb(u32, reader);

                            var code_reader = std.io.limitedReader(reader, body_len).reader();

                            // first parse the local declarations
                            {
                                const locals_len = try readLeb(u32, code_reader);
                                const locals = try gpa.alloc(wasm.sections.Code.Local, locals_len);
                                for (locals) |*local| {
                                    local.* = .{
                                        .count = try readLeb(u32, code_reader),
                                        .valtype = try readEnum(wasm.ValueType, code_reader),
                                    };
                                }

                                code.locals = locals;
                            }

                            {
                                var instructions = std.ArrayList(wasm.Instruction).init(gpa);
                                defer instructions.deinit();

                                while (readEnum(std.wasm.Opcode, code_reader)) |opcode| {
                                    const instr = try buildInstruction(opcode, gpa, code_reader);
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
                            try assertEnd(code_reader);
                        }
                        module.code.end = self.reader.bytes_read;
                        try assertEnd(reader);
                    },
                    .data => {
                        module.data.start = self.reader.bytes_read;
                        for (try readVec(&module.data.data, reader, gpa)) |*data| {
                            data.index = try readEnum(wasm.indexes.Mem, reader);
                            data.offset = try readInit(reader);

                            const init_len = try readLeb(u32, reader);
                            const init_data = try gpa.alloc(u8, init_len);
                            data.data = init_data;
                            try reader.readNoEof(init_data);
                        }
                        module.data.end = self.reader.bytes_read;
                        try assertEnd(reader);
                    },
                    .module => @panic("TODO: Implement 'module' section"),
                    .instance => @panic("TODO: Implement 'instance' section"),
                    .alias => @panic("TODO: Implement 'alias' section"),
                    _ => |id| std.log.scoped(.wasmparser).debug("Found unimplemented section with id '{d}'", .{id}),
                }
            } else |err| switch (err) {
                error.EndOfStream => {},
                else => |e| return e,
            }
            module.custom = custom_sections.toOwnedSlice();
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
    return meta.Elem(meta.Child(ptr));
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
    const flags = try readLeb(u1, reader);
    const min = try readLeb(u32, reader);
    return wasm.Limits{
        .min = min,
        .max = if (flags == 0) null else try readLeb(u32, reader),
    };
}

fn readInit(reader: anytype) !wasm.InitExpression {
    const opcode = try reader.readByte();
    const init: wasm.InitExpression = switch (@intToEnum(std.wasm.Opcode, opcode)) {
        .i32_const => .{ .i32_const = try readLeb(i32, reader) },
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
