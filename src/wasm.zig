const std = @import("std");
const wasm = std.wasm;

/// Wasm value that lives in the global section.
/// Cannot be modified when `mutable` is set to false.
pub const Global = extern struct {
    mutable: bool = false,
    value: Value,
};

/// Wasm value that lives on the stack.
pub const Local = Value;

/// Wasm union that contains the value of each possible `ValueType`
pub const Value = extern union(ValueType) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    /// Reference to another function regardless of their function type
    funcref: indices.Func,
    /// Reference to an external object (object from the embedder)
    externref: u32,
};

/// Value types for locals and globals
pub const NumType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0xfD,
    f64 = 0xfE,
};

/// Reference types, where the funcref references to a function regardless of its type
/// and externref references an object from the embedder.
pub const RefType = enum(u8) {
    funcref = 0x70,
    externref = 0x6F,
};

/// Represents the several types a wasm value can have
pub const ValueType = enum(u8) {
    i32 = @enumToInt(NumType.i32),
    i64 = @enumToInt(NumType.i64),
    f32 = @enumToInt(NumType.f32),
    f64 = @enumToInt(NumType.f64),
    funcref = @enumToInt(RefType.funcref),
    externref = @enumToInt(RefType.externref),
};

/// Wasm module sections
pub const Section = wasm.Section;
/// External types that can be imported or exported between to/from the host
pub const ExternalType = wasm.ExternalKind;

/// Limits classify the size range of resizeable storage associated with memory types and table types.
pub const Limits = extern struct {
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
    empty = wasm.block_empty,
};

/// Creates a vector over given type `T`. Allows for both mutable and immutable slices.
pub fn Vec(comptime T: type) type {
    return extern struct {
        const Self = @This();

        data: [*]const T = undefined,
        len: usize = 0,

        /// Returns a slice with constant elements from a `Vec(T)`
        pub fn slice(self: Self) []const T {
            return self.data[0..self.len];
        }

        /// Initializes a new `Vec(T)` from a given slice
        pub fn fromSlice(buffer: [*]const T) Self {
            return .{ .data = buffer.ptr, .len = buffer.len };
        }
    };
}

pub const InitExpression = extern union(enum) {
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
    pub const Custom = extern struct {
        name: Vec(u8),
        data: Vec(u8),
    };

    pub const Type = extern struct {
        params: Vec(ValueType),
        returns: Vec(ValueType),
    };

    pub const Import = extern struct {
        pub const Kind = union(ExternalType) {
			function: indices.Type,
			table: extern struct {
				reftype: RefType,
				limits: Limits,
			},
			memory: Limits,
			global: extern struct {
				valtype: ValueType,
				mutable: bool,
			};

        };
        module: Vec(u8),
        name: Vec(u8),
        kind: Kind,
    };

    pub const Func = extern struct {
        type_idx: indices.Type,
    };

    pub const Table = extern struct {
        limits: Limits,
        reftype: RefType,
    };

    pub const Memory = extern struct {
        limits: Limits,
    };

    pub const Global = extern struct {
        valtype: ValueType,
        mutable: bool,
        init: InitExpression,
    };

    pub const Export = extern struct {
        name: Vec(u8),
        kind: ExternalType,
    };

    pub const Element = extern struct {
        index: indices.Table,
        offset: InitExpression,
        /// Element can be of different types so simply use u32 here rather than a
        /// non-exhaustive enum
        elements: Vec(u32),
    };

    pub const Code = extern struct {
        pub const Local = extern struct {
            valtype: ValueType,
            count: u32,
        };
        locals: Vec(Local),
        body: Vec(wasm.Opcode),
    };

    pub const Data = extern struct {
        index: indices.Mem,
        offset: InitExpression,
        data: Vec(u8),
    };
};

pub const Module = extern struct {
    custom: Vec(sections.Custom) = .{},
    types: Vec(sections.Type) = .{},
    imports: Vec(sections.Import) = .{},
    functions: Vec(sections.Func) = .{},
    tables: Vec(sections.Table) = .{},
    memories: Vec(sections.Memory) = .{},
    globals: Vec(sections.Global) = .{},
    exports: Vec(sections.Export) = .{},
    start: ?indices.Func = null,
    elements: Vec(sections.Element) = .{},
    code: Vec(sections.Code) = .{},
    data: Vec(sections.Data) = .{},
};
