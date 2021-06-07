//! Turns wat source bytes into an AST.

const std = @import("std");

pub const Token = struct {
    /// Tag representing this token
    tag: Tag,
    /// Index in the source where the token starts
    start: u32,
    /// Index in the source where the token ends
    end: u32,

    pub const Tag = enum {
        block_comment,
        eof,
        float,
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
    index: usize,

    /// Initializes a new `Lexer` and sets the `index` while correctly
    /// skipping the UTF-8 BOM.
    pub fn init(buffer: []const u8) Lexer {
        // skip the UTF-8 BOM
        const index = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else @as(usize, 0);
        return .{ .buffer = buffer, .index = index };
    }

    /// Reads the next bytes and returns a `Token` when successful
    pub fn next(self: *Lexer) ?Token {}

    /// Returns true when given `char` is part of 7-bit ASCII subset of Unicode.
    fn isChar(char: u8) bool {
        return std.ascii.isASCII(char);
    }

    /// Returns true when given `char` is digit and therefore possible an integer_literal
    fn isDigit(char: u8) bool {
        return std.ascii.isDigit(char);
    }
};
