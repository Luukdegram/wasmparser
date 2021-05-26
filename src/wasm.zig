const std = @import("std");
const wasm = std.wasm;

/// Wasm value that lives in the global section.
/// Cannot be modified when `mutable` is set to false.
pub const Global = struct {
    mutable: bool = false,
    value: Value,
};

/// Wasm value that lives on the stack.
pub const Local = Value;

/// Wasm union that contains the value of each possible `ValueType`
pub const Value = union(ValueType) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    /// Reference to another function regardless of their function type
    funcref: indices.Func,
    /// Reference to an al object (object from the embedder)
    ref: u32,
};

/// Value types for locals and globals
pub const NumType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0xfD,
    f64 = 0xfE,
};

/// Reference types, where the funcref references to a function regardless of its type
/// and ref references an object from the embedder.
pub const RefType = enum(u8) {
    funcref = 0x70,
    ref = 0x6F,
};

/// Represents the several types a wasm value can have
pub const ValueType = enum(u8) {
    i32 = @enumToInt(NumType.i32),
    i64 = @enumToInt(NumType.i64),
    f32 = @enumToInt(NumType.f32),
    f64 = @enumToInt(NumType.f64),
    funcref = @enumToInt(RefType.funcref),
    ref = @enumToInt(RefType.ref),
};

/// Wasm module sections
pub const Section = wasm.Section;
/// External types that can be imported or exported between to/from the host
pub const ExternalType = wasm.ExternalKind;

/// Limits classify the size range of resizeable storage associated with memory types and table types.
pub const Limits = struct {
    min: u32,
    max: ?u32,
};

/// The type of block types, similarly to `ValueType` with the difference being
/// that it adds an additional type 'empty' which is used for blocks with no return value.
pub const BlockType = enum(u8) {
    i32 = @enumToInt(ValueType.i32),
    i64 = @enumToInt(ValueType.i64),
    f32 = @enumToInt(ValueType.f32),
    f64 = @enumToInt(ValueType.f64),
    funcref = @enumToInt(RefType.funcref),
    ref = @enumToInt(RefType.ref),
    empty = wasm.block_empty,
};

pub const InitExpression = union(enum) {
    i32_const: i32,
    i64_const: i64,
    f32_const: f32,
    f64_const: f64,
    /// Uses the value of a global at index `global_get`
    global_get: u32,
};

pub const indices = struct {
    pub const Type = enum(u32) { _ };
    pub const Func = enum(u32) { _ };
    pub const Table = enum(u32) { _ };
    pub const Mem = enum(u32) { _ };
    pub const global = enum(u32) { _ };
    pub const Elem = enum(u32) { _ };
    pub const Data = enum(u32) { _ };
    pub const Local = enum(u32) { _ };
    pub const Label = enum(u32) { _ };
};

pub const sections = struct {
    pub const Custom = struct {
        name: []const u8,
        data: []const u8,
    };

    pub const Type = struct {
        params: []const ValueType,
        returns: []const ValueType,
    };

    pub const Import = struct {
        module: []const u8,
        name: []const u8,
        kind: Kind,

        pub const Kind = union(ExternalType) {
            function: indices.Type,
            table: struct {
                reftype: RefType,
                limits: Limits,
            },
            memory: Limits,
            global: struct {
                valtype: ValueType,
                mutable: bool,
            },
        };
    };

    pub const Func = struct {
        type_idx: indices.Type,
    };

    pub const Table = struct {
        limits: Limits,
        reftype: RefType,
    };

    pub const Memory = struct {
        limits: Limits,
    };

    pub const Global = struct {
        valtype: ValueType,
        mutable: bool,
        init: InitExpression,
    };

    pub const Export = struct {
        name: []const u8,
        kind: ExternalType,
    };

    pub const Element = struct {
        index: indices.Table,
        offset: InitExpression,
        /// Element can be of different types so simply use u32 here rather than a
        /// non-exhaustive enum
        elements: []const u32,

        pub const Kind = union(enum) {
            func: struct {
                init: InitExpression,
            },
        };
    };

    pub const Code = struct {
        pub const Local = struct {
            valtype: ValueType,
            count: u32,
        };
        locals: []const Local,
        body: []const wasm.Opcode,
    };

    pub const Data = struct {
        index: indices.Mem,
        offset: InitExpression,
        data: []const u8,
    };
};

pub const Module = struct {
    custom: []const sections.Custom = .{},
    types: []const sections.Type = .{},
    imports: []const sections.Import = .{},
    functions: []const sections.Func = .{},
    tables: []const sections.Table = .{},
    memories: []const sections.Memory = .{},
    globals: []const sections.Global = .{},
    exports: []const sections.Export = .{},
    start: ?indices.Func = null,
    elements: []const sections.Element = .{},
    code: []const sections.Code = .{},
    data: []const sections.Data = .{},
};

pub const Instruction = struct {
    opcode: wasm.Opcode,
    secondary: ?SecondaryOpcode = null,
    value: union {
        none: void,
        u32: u32,
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,
        valtype: ValueType,
        blocktype: BlockType,
        multi_valtype: struct {
            valtype: [*]ValueType,
            len: u32,
        },
        multi: struct {
            x: u32,
            y: u32,
        },
        list: struct {
            data: [*]u32,
            len: u32,
        },
    },
};

/// Secondary opcode belonging to primary opcodes
/// that have as opcode 0xFC
pub const SecondaryOpcode = enum(u8) {
    i32_trunc_sat_f32_s = 0,
    i32_trunc_sat_f32_u = 1,
    i32_trunc_sat_f64_s = 2,
    i32_trunc_sat_f64_u = 3,
    i64_trunc_sat_f32_s = 4,
    i64_trunc_sat_f32_u = 5,
    i64_trunc_sat_f64_s = 6,
    i64_trunc_sat_f64_u = 7,
    memory_init = 8,
    data_drop = 9,
    memory_copy = 10,
    memory_fill = 11,
    table_init = 12,
    table_drop = 13,
    table_copy = 14,
    table_grow = 15,
    table_size = 16,
    table_fill = 17,
    _,
};

pub const need_secondary = @intToEnum(wasm.Opcode, 0xFC);

/// Temporary enum until std.wasm.Opcode contains those
pub const Table = enum(u8) {
    get = 0x25,
    set = 0x26,

    pub fn opcode(self: Table) wasm.Opcode {
        return @intToEnum(wasm.Opcode, @enumToInt(self));
    }
};
