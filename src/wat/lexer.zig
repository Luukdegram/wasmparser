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
        invalid,
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
        string,

        /// Lexes the tag into a string, returns null if not
        /// a keyword or grammar token.
        pub fn lexeme(self: Tag) ?[]const u8 {
            return switch (self) {
                .block_comment,
                .eof,
                .float,
                .identifier,
                .integer,
                .invalid,
                .line_comment,
                .opcode,
                .string,
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
        comment_start,
        eof,
        float_literal,
        hex_literal,
        identifier,
        integer_literal,
        invalid,
        line_comment,
        l_paren,
        r_paren,
        start,
        string_literal,
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
                    ' ', '\n', '\t', '\r' => {
                        result.loc.start = self.index + 1;
                    },
                    '(' => {
                        result.tag = .l_paren;
                        self.index += 1;
                        break;
                    },
                    ')' => {
                        result.tag = .r_paren;
                        self.index += 1;
                        break;
                    },
                    'a'...'z', '$' => {
                        state = .identifier;
                        result.tag = .identifier;
                    },
                    ';' => {
                        state = .comment_start;
                    },
                    '"' => {
                        state = .string_literal;
                        result.tag = .string;
                        result.loc.start = self.index + 1;
                    },
                    else => unreachable,
                },
                .comment_start => switch (c) {
                    ';' => {
                        result.tag = .line_comment;
                        result.loc.start = self.index + 1;
                        state = .line_comment;
                    },
                    else => {
                        result.tag = .block_comment;
                        result.loc.start = self.index + 1;
                        state = .block_comment;
                    },
                },
                .block_comment => if (c == ';') {
                    result.loc.end = self.index;
                    self.index += 1;
                    return result;
                },
                .line_comment => if (c == '\n') break,
                .identifier => switch (c) {
                    'a'...'z', '0'...'9', 'A'...'Z' => {},
                    else => {
                        if (Token.findKeyword(self.buffer[result.loc.start..self.index])) |tag| {
                            result.tag = tag;
                        }
                        break;
                    },
                },
                .string_literal => switch (c) {
                    'a'...'z', '\n', '\t', '\\', '\'' => {},
                    '"' => {
                        result.loc.end = self.index;
                        self.index += 1;
                        return result;
                    },
                    else => |maybe_hex| if (!std.ascii.isXDigit(maybe_hex)) {
                        result.tag = .invalid;
                        break;
                    },
                },
                else => unreachable,
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

test "Module" {
    try runTestInput("(module)", &.{
        .l_paren,
        .keyword_module,
        .r_paren,
    });
}

test "Type" {
    const cases = .{
        .{
            \\ (type)
            ,
            &.{ .l_paren, .keyword_type, .r_paren },
        },
        .{
            \\ (type (func))
            ,
            &.{ .l_paren, .keyword_type, .l_paren, .keyword_func, .r_paren, .r_paren },
        },
        .{
            \\ (type $t (func))
            ,
            &.{ .l_paren, .keyword_type, .identifier, .l_paren, .keyword_func, .r_paren, .r_paren },
        },
        .{
            \\ (type $t
            \\    (func)
            \\ )
            ,
            &.{ .l_paren, .keyword_type, .identifier, .l_paren, .keyword_func, .r_paren, .r_paren },
        },
    };

    inline for (cases) |case| {
        try runTestInput(case[0], case[1]);
    }
}

test "Func" {
    const cases = .{
        .{
            \\ (func)
            ,
            &.{ .l_paren, .keyword_func, .r_paren },
        },
        .{
            \\ (func (param))
            ,
            &.{ .l_paren, .keyword_func, .l_paren, .keyword_param, .r_paren, .r_paren },
        },
        .{
            \\ (func (param $x))
            ,
            &.{ .l_paren, .keyword_func, .l_paren, .keyword_param, .identifier, .r_paren, .r_paren },
        },
        .{
            \\ (func
            \\    (param $x i32)
            \\ )
            ,
            &.{ .l_paren, .keyword_func, .l_paren, .keyword_param, .identifier, .identifier, .r_paren, .r_paren },
        },
    };

    inline for (cases) |case| {
        try runTestInput(case[0], case[1]);
    }
}

test "Comment" {
    const cases = .{
        .{
            \\ ;;hello world
            ,
            &.{.line_comment},
            "hello world",
        },
        .{
            \\ (func ;;hello world
            ,
            &.{ .l_paren, .keyword_func, .line_comment },
            "hello world",
        },
        .{
            \\ (func ;;hello world
            \\ )
            ,
            &.{ .l_paren, .keyword_func, .line_comment, .r_paren },
            "hello world",
        },
        .{
            \\ (func ;;hello world $x
            \\ )
            ,
            &.{ .l_paren, .keyword_func, .line_comment, .r_paren },
            "hello world $x",
        },
        .{
            \\ ; test
            ,
            &.{.block_comment},
            "test",
        },
        .{
            \\ ; test ;
            ,
            &.{.block_comment},
            "test ",
        },
        .{
            \\ ; test ;
            \\ (
            ,
            &.{ .block_comment, .l_paren },
            "test ",
        },
        .{
            \\ ; test ; $i
            ,
            &.{ .block_comment, .identifier },
            "test ",
        },
        .{
            \\ (; test ;)(module)
            ,
            &.{ .l_paren, .block_comment, .r_paren, .l_paren, .keyword_module, .r_paren },
            "test ",
        },
    };

    const testing = std.testing;
    inline for (cases) |case| {
        var lexer = Lexer.init(case[0]);

        for (@as([]const Token.Tag, case[1])) |tag, index| {
            const token = lexer.next() orelse return error.TestUnexpectedResult;
            try testing.expectEqual(tag, token.tag);

            if (token.tag == .block_comment or token.tag == .line_comment) {
                try testing.expectEqualStrings(case[2], case[0][token.loc.start..token.loc.end]);
            }
        }
    }
}

test "String" {
    const cases = .{
        .{
            \\ (func "add")
            ,
            &.{ .l_paren, .keyword_func, .string, .r_paren },
            "add",
        },
        .{
            \\ (func "a\tdd")
            ,
            &.{ .l_paren, .keyword_func, .string, .r_paren },
            \\a\tdd
            ,
        },
    };

    const testing = std.testing;
    inline for (cases) |case| {
        var lexer = Lexer.init(case[0]);

        for (@as([]const Token.Tag, case[1])) |tag, index| {
            const token = lexer.next() orelse return error.TestUnexpectedResult;
            try testing.expectEqual(tag, token.tag);

            if (token.tag == .string) {
                try testing.expectEqualStrings(case[2], case[0][token.loc.start..token.loc.end]);
            }
        }
    }
}
