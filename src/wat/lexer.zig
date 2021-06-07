//! Turns wat source bytes into an AST.

const std = @import("std");

pub const Token = struct {
    /// Tag representing this token
    tag: Tag,
    /// The location in the source code
    loc: Loc,

    const Loc = struct {
        /// Index in the source where the token starts
        start: u32,
        /// Index in the source where the token ends
        end: u32,
    };

    pub const Tag = enum {
        block_comment,
        eof,
        float,
        identifier,
        integer,
        keyword_data,
        keyword_elem,
        keyword_export,
        keyword_func,
        keyword_global,
        keyword_import,
        keyword_local,
        keyword_module,
        keyword_offset,
        keyword_param,
        keyword_result,
        keyword_start,
        keyword_table,
        keyword_type,
        line_comment,
        l_paren,
        opcode,
        r_paren,

        /// Lexes the tag into a string, returns null if not
        /// a keyword or grammar token.
        pub fn lexeme(self: Tag) ?[]const u8 {
            return switch (self) {
                .block_comment,
                .eof,
                .float,
                .identifier,
                .integer,
                .line_comment,
                .opcode,
                => null,
                .keyword_data => "data",
                .keyword_elem => "elem",
                .keyword_export => "export",
                .keyword_func => "func",
                .keyword_global => "global",
                .keyword_import => "import",
                .keyword_local => "local",
                .keyword_module => "module",
                .keyword_offset => "offset",
                .keyword_param => "param",
                .keyword_result => "result",
                .keyword_start => "start",
                .keyword_table => "table",
                .keyword_type => "type",
                .l_paren => "(",
                .r_paren => "}",
            };
        }

        /// Returns the tag as a symbol
        pub fn symbol(self: Tag) []const u8 {
            return self.lexeme() orelse @tagName(self);
        }
    };

    pub const keywords = std.ComptimeStringMap(Tag, .{
        .{ "data", .keyword_data },
        .{ "elem", .keyword_elem },
        .{ "export", .keyword_export },
        .{ "func", .keyword_func },
        .{ "global", .keyword_global },
        .{ "import", .keyword_import },
        .{ "local", .keyword_local },
        .{ "module", .keyword_module },
        .{ "offset", .keyword_offset },
        .{ "param", .keyword_param },
        .{ "result", .keyword_result },
        .{ "start", .keyword_start },
        .{ "table", .keyword_table },
        .{ "type", .keyword_type },
    });

    /// Looks in `keywords` and returns the corresponding `Tag` when found.
    /// Returns `null` when not found.
    pub fn findKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }
};

pub const Lexer = struct {
    /// The source we're iterating over
    buffer: []const u8,
    /// The current index into `buffer`
    index: u32,

    pub const State = enum {
        block_comment,
        block_comment_end,
        eof,
        float_literal,
        hex_literal,
        identifier,
        integer_literal,
        invalid,
        l_paren,
        r_paren,
        start,
    };

    /// Initializes a new `Lexer` and sets the `index` while correctly
    /// skipping the UTF-8 BOM.
    pub fn init(buffer: []const u8) Lexer {
        // skip the UTF-8 BOM
        const index = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else @as(u32, 0);
        return .{ .buffer = buffer, .index = index };
    }

    /// Reads the next bytes and returns a `Token` when successful
    pub fn next(self: *Lexer) ?Token {
        var state: State = .start;
        var result: Token = .{
            .tag = .eof,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };

        while (self.index < self.buffer.len) : (self.index += 1) {
            const c = self.buffer[self.index];
            switch (state) {
                .start => switch (c) {
                    ' ', '\n', 't', '\r' => {
                        result.loc.start = self.index + 1;
                    },
                    '(' => state = .l_paren,
                    else => @panic("TODO"),
                },
                .l_paren => switch (c) {
                    'a'...'z' => {
                        state = .identifier;
                        result.tag = .identifier;
                        result.loc.start = self.index;
                    },
                    ';' => {
                        state = .block_comment;
                        result.tag = .block_comment;
                    },
                    '(' => {},
                    else => @panic("TODO"),
                },
                .identifier => switch (c) {
                    'a'...'z' => {},
                    else => {
                        std.debug.print("Ident: {s}\n", .{self.buffer[result.loc.start..self.index]});
                        if (Token.findKeyword(self.buffer[result.loc.start..self.index])) |tag| {
                            result.tag = tag;
                        }
                        break;
                    },
                },
                .block_comment => switch (c) {
                    ';' => state = .block_comment_end,
                    else => {},
                },
                .block_comment_end => switch (c) {
                    ')' => break,
                    else => @panic("TODO"),
                },
                else => @panic("TODO"),
            }
        }

        result.loc.end = self.index;
        return result;
    }

    /// Returns true when given `char` is part of 7-bit ASCII subset of Unicode.
    fn isLetter(char: u8) bool {
        return std.ascii.isASCII(char);
    }

    /// Returns true when given `char` is digit and therefore possible an integer_literal
    fn isDigit(char: u8) bool {
        return std.ascii.isDigit(char);
    }

    fn skipWhitespace(self: *Lexer) void {
        while (true) {
            const c = self.buffer[self.index];
            if (!std.ascii.isSpace(c)) break;
            self.index += 1;
        }
    }

    /// Parses an identifier and returns a `Token.Loc` for its location
    fn parseIdentifier(self: *Lexer) Token.Loc {
        const old_pos = self.index;
        while (true) {
            const c = self.buffer[self.index];
            if (!isLetter(c)) break;
            self.index += 1;
        }

        return .{
            .start = old_pos,
            .end = self.index,
        };
    }
};

fn runTestInput(input: []const u8, expected_token_tags: []const Token.Tag) !void {
    const testing = std.testing;
    var lexer = Lexer.init(input);

    for (expected_token_tags) |tag, index| {
        const token = lexer.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(tag, token.tag);
    }
}

test "Basic module" {
    const input =
        \\(module)
    ;

    try runTestInput(input, &.{.keyword_module});
}
