const std = @import("std");

const Tokenizer = @This();

const keyword_map = std.StaticStringMap(Token).initComptime(.{
    .{ "if", .@"if" },
    .{ "let", .let },
    .{ "define", .define },
    .{ "lambda", .lambda },
    .{ "list", .list },
    .{ "cons", .cons },
    .{ "car", .car },
    .{ "cdr", .cdr },
    .{ "ref", .ref },
    .{ "free", .free },
    .{ "deref", .deref },
});

source: [:0]const u8,
token: Token = undefined,
start: usize = 0,
index: usize = 0,
last_end: usize = 0,

pub const ByteOffset = u32;

pub const SourceRange = struct {
    start: ByteOffset,
    end: ByteOffset,
};

pub const Token = enum(u8) {
    eof,
    invalid,
    @"(",
    @")",
    @"+",
    @"-",
    @"*",
    @"/",
    @"<",
    @"<=",
    @">",
    @">=",
    @"=",

    number_i32,
    number_f64,
    identifier,
    @"#f",
    @"#t",

    @"if",
    define,
    let,
    lambda,
    list,
    pair,
    cons,
    car,
    cdr,
    @"null?",
    ref,
    free,
    deref,
    @"set!",

    pub fn description(token: Token) []const u8 {
        return switch (token) {
            .eof => "the end of the file",
            .invalid => "unknown characters",
            .number_i32 => "a integer literal",
            .number_f64 => "a float literal",
            .identifier => "an identifier",
            inline else => |tag| "'" ++ @tagName(tag) ++ "'",
        };
    }
};

pub fn tokenSource(self: *Tokenizer) []const u8 {
    return self.source[self.start..self.index];
}

pub fn tokenRange(self: *Tokenizer) SourceRange {
    return .{ .start = @intCast(self.start), .end = @intCast(self.index) };
}

const State = enum {
    init,
    identifier_continue,
    number_i32_continue,
    number_f64_continue,
    @"#",
    @"<",
    @">",
    @"/",
    @"-",
    comment_continue,
};

pub fn next(self: *Tokenizer) void {
    self.last_end = self.index;
    self.token = state: switch (State.init) {
        .init => {
            self.start = self.index;
            switch (self.source[self.index]) {
                ' ', '\t', '\r', '\n' => {
                    self.index += 1;
                    continue :state .init;
                },
                inline '(', ')', '+', '*', '=' => |b| {
                    self.index += 1;
                    break :state @field(Token, &.{b});
                },
                'a'...'z', 'A'...'Z', '_', '$' => {
                    self.index += 1;
                    continue :state .identifier_continue;
                },
                '0'...'9' => {
                    self.index += 1;
                    continue :state .number_i32_continue;
                },
                '-' => {
                    self.index += 1;
                    continue :state .@"-";
                },
                '#' => {
                    self.index += 1;
                    continue :state .@"#";
                },
                '<' => {
                    self.index += 1;
                    continue :state .@"<";
                },
                '>' => {
                    self.index += 1;
                    continue :state .@">";
                },
                '/' => {
                    self.index += 1;
                    continue :state .@"/";
                },
                else => {
                    if (self.index == self.source.len) {
                        break :state .eof;
                    }

                    self.index += 1;
                    break :state .invalid;
                },
            }
        },
        .identifier_continue => switch (self.source[self.index]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '$' => {
                self.index += 1;
                continue :state .identifier_continue;
            },
            '?' => {
                if (std.mem.eql(u8, self.tokenSource(), "null")) {
                    self.index += 1;
                    break :state .@"null?";
                }
                break :state keyword_map.get(self.tokenSource()) orelse .identifier;
            },
            '!' => {
                if (std.mem.eql(u8, self.tokenSource(), "set")) {
                    self.index += 1;
                    break :state .@"set!";
                }
                break :state keyword_map.get(self.tokenSource()) orelse .identifier;
            },
            else => {
                break :state keyword_map.get(self.tokenSource()) orelse .identifier;
            },
        },
        .number_i32_continue => switch (self.source[self.index]) {
            '0'...'9' => {
                self.index += 1;
                continue :state .number_i32_continue;
            },
            '.' => {
                self.index += 1;
                continue :state .number_f64_continue;
            },
            else => break :state .number_i32,
        },
        .@"-" => switch (self.source[self.index]) {
            '0'...'9' => {
                self.index += 1;
                continue :state .number_i32_continue;
            },
            '.' => {
                self.index += 1;
                continue :state .number_f64_continue;
            },
            else => break :state .@"-",
        },
        .number_f64_continue => switch (self.source[self.index]) {
            '0'...'9' => {
                self.index += 1;
                continue :state .number_f64_continue;
            },
            else => break :state .number_f64,
        },
        .@"#" => switch (self.source[self.index]) {
            'f' => {
                self.index += 1;
                break :state .@"#f";
            },
            't' => {
                self.index += 1;
                break :state .@"#t";
            },
            else => break :state .invalid,
        },
        .@"<" => switch (self.source[self.index]) {
            '=' => {
                self.index += 1;
                break :state .@"<=";
            },
            else => break :state .@"<",
        },
        .@">" => switch (self.source[self.index]) {
            '=' => {
                self.index += 1;
                break :state .@">=";
            },
            else => break :state .@">",
        },
        .@"/" => switch (self.source[self.index]) {
            '/' => {
                self.index += 1;
                continue :state .comment_continue;
            },
            else => break :state .@"/",
        },
        .comment_continue => switch (self.source[self.index]) {
            0 => continue :state .init,
            '\n' => {
                self.index += 1;
                continue :state .init;
            },
            else => {
                self.index += 1;
                continue :state .comment_continue;
            },
        },
    };
}
