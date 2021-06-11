//! Abstract Syntax Tree of wat.
//! `Tree` contains the actual nodes as a slice.

const std = @import("std");
const lexer = @import("lexer.zig");
const Token = lexer.Token;
const Allocator = std.mem.Allocator;

pub const TokenIndex = u32;

/// Struct of arrays containing a field for `Token.Tag`
/// and a field for its start index into the source.
pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: u32,
});

/// Struct of arrays of `Node`.
pub const NodeList = std.MultiArrayList(Node);

/// `Tree` holds all information of the AST.
pub const Tree = struct {
    /// Non-owned reference to the source code.
    source: []const u8,
    /// SOA containing token tags and its start index into the source.
    tokens: TokenList.Slice,
    /// SOA of `Node` where index 0 is the root noot, any other references
    /// to '0' are toe treated as null.
    nodes: NodeList.Slice,
    /// Mutable slice of node indices. Used to hold references to other nodes
    /// from within a `Node`. So rather than holding a pointer to a `Node`,
    /// it only needs a 4-byte index into the Node slice.
    data: []Node.Index,

    /// Frees all, but `source`, memory and unreferences itself.
    /// Any usage of `Tree` or its members is illegal.
    pub fn deinit(self: *Tree, gpa: *Allocator) void {
        self.tokens.deinit(gpa);
        self.nodes.deinit(gpa);
        gpa.free(self.data);
        self.* = undefined;
    }

    /// Prints the content of the `Tree` into a given `writer`.
    pub fn print(self: Tree, writer: anytype) @TypeOf(writer).Error!void {
        @panic("TODO - Implement 'Tree.print()'");
    }

    /// Returns a token's value as a slice using given index of `TokenIndex`
    pub fn tokenSlice(self: Tree, token_index: TokenIndex) []const u8 {
        const token_tags = tree.tokens.items(.tag);
        const token_tag = token_tags[token_index];

        // some tags can be determined by their tag, such as keywords or parenthesis.
        if (token_tag.lexeme()) |lexeme| return lexeme;

        // re-lexer find the end of the token.
        const token_starts = tree.tokens.items(.start);
        var lexer = lexer.Lexer{
            .buffer = self.source,
            .index = token_starts[token_index],
        };
        const token = lexer.next().?;
        std.debug.assert(token.tag == token_tag);
        return tree.source[token.loc.start..token.loc.end];
    }
};

pub const Node = struct {
    /// Tag of the node to represent the kind of expression
    tag: Tag,
    /// The index into the token list
    /// Represents the main token
    token: TokenIndex,
    /// Information to any other nodes it may hold information to.
    data: Data,

    /// Represents an index into a node list
    pub const Index = u32;

    /// Data can contain indexes into the node list itself,
    /// or into a seperate `extra_data` list where it represents
    /// the start and end index of the slice into the list.
    pub const Data = struct {
        lhs: Index,
        rhs: Index,
    };

    pub const Tag = enum {
        /// list of tokens: [lhs...rhs]
        root,
        /// Represents a module section
        /// (module [lhs...rhs]
        module,
        /// Type section
        /// (type lhs
        type,
        /// Singular opcode such as (drop)
        /// Both lhs and rhs are 'empty'
        opcode,
        /// (opcode lhs)
        opcode_one,
        /// (opcode [lhs...rhs])
        opcode_multi,
    };
};
