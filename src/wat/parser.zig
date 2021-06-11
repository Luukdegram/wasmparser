//! Parses a list of tokens into an AST.
//! Ensures the correctness of the AST and allows
//! for error reporting.

const std = @import("std");
const ast = @import("ast.zig");
const lex = @import("lexer.zig");
const Token = lex.Token;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const ParseError = error{
    /// Not enough memory to allocate more
    OutOfMemory,
    /// An error occured during parsing the current token,
    /// access the diagnostics to find the details regarding the error.
    ParseError,
};

/// Parses wat source into an abstract syntax tree `ast.Tree`.
/// When invalid tokens are found, an error will be appended to diagnostics
/// and parsing will continue at the next expression, allowing for multiple errors
/// to be found while parsing.
pub fn parse(gpa: *Allocator, source: []const u8) ParseError!ast.Tree {
    var lexer = lex.Lexer.init(source);
    var token_list = ast.TokenList{};
    var node_list = ast.NodeList{};

    while (lexer.next()) |token| {
        try token_list.append(gpa, .{
            .tag = token.tag,
            .start = token.loc.start,
        });
    }
}

/// `Parser` holds all data to construct the `ast.Tree`
/// Any errors that occur will be stored in `errors` so the user
/// can retrieve more information about an error than only a `ParseError`.
const Parser = struct {
    gpa: *Allocator,
    source: []const u8,
    token_tags: []const Token.Tag,
    token_starts: []const u32,
    token_index: ast.TokenIndex,
    nodes: ast.NodeList,
    extra_data: std.ArrayListUnmanaged(ast.Node.Index),

    /// Inserts a new `ast.Node` at the end of the tree.
    fn insert(self: *Parser, node: ast.Node) !ast.Node.Index {
        const index = @intCast(u32, self.nodes.len);
        try self.nodes.append(self.gpa, node);
        return index;
    }

    /// Sets the node at a given `index`. Asserts index is smaller than current `nodes` len.
    fn setAt(self: *Parser, index: u32, node: ast.Node) void {
        self.nodes.set(index, node);
        return index;
    }

    /// Appends both 'lhs' and 'rhs' fields into the `extra_data` array list,
    /// returning the index of the first element it inserted.
    fn appendExtra(self: *Parser, extra: ast.Node.Data) !ast.Node.Index {
        try self.extra_data.ensureCapacity(self.gpa, self.extra_data.items.len + 2);
        const index = @intCast(u32, self.extra_data.items.len);
        self.extra_data.appendAssumeCapacity(extra.lhs);
        self.extra_data.appendAssumeCapacity(extra.rhs);
        return index;
    }

    /// Increases the `token_index` by 1 and returns the `Token.Tag` at its position.
    /// Returns `null` when reached the end of `token_tags`
    fn nextTag(self: *Parser) ?Token.Tag {
        if (self.token_index + 1 >= self.token_tags.len) return null;
        self.token_index += 1;
        return self.token_tags[self.token_tags];
    }

    /// Returns the `Token.Tag` at the index of `token_index`.
    fn curTag(self: Parser) Token.Tag {
        return self.token_tags[self.token_index];
    }

    /// Parses all the tokens in `token_tags` and constructs an `ast.Tree`
    fn parseTokens(self: *Parser) ParseError!void {
        while (self.token_index < self.token_starts.len) : (self.token_index += 1) {
            const tag = self.token_starts[self.token_index];
            switch (tag) {
                // Comments are not preserved in the AST
                .block_comment, .line_comment => {},
                .l_paren => try self.parseExpression(),
                // TODO
                else => {},
            }
        }
    }

    /// Parses the current tag as an expression. Results in `ParseError`
    /// if the given token tag is not an expression.
    fn parseExpression(self: *Parser) ParseError!void {
        assert(self.curTag() == .l_paren);
        const tag = self.nextTag() orelse @panic("TODO: Handle errors");

        switch (tag) {
            .keyword_module => try self.parseModule(),
        }
    }

    /// Parses the current token at `token_index` as a module.
    fn parseModule(self: *Parser) ParseError!void {
        const tok_idx = self.token_index;
        const node: ast.Node = .{
            .tag = .module,
            .token_index = tok_idx,
            .data = .{ .lhs = 0, .rhs = 0 },
        };
    }
};
