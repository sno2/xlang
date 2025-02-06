const std = @import("std");

const Executable = @import("Executable.zig");
const Tokenizer = @import("Tokenizer.zig");
const Vm = @import("Vm.zig");

const Instruction = Executable.Instruction;
const SourceRange = Tokenizer.SourceRange;
const Token = Tokenizer.Token;
const Value = Vm.Value;

const CodeGen = @This();

gpa: std.mem.Allocator,
tokenizer: Tokenizer,
flavor: Flavor,
results: usize = 0,
result_endings: std.ArrayListUnmanaged(u32) = .empty,
constants: std.ArrayListUnmanaged(Value) = .empty,
defines: std.StringArrayHashMapUnmanaged(u16) = .empty,
define_types: std.ArrayListUnmanaged(Type) = .empty,
captures_count: u16 = 0,
captures: std.HashMapUnmanaged(Capture, u16, struct {
    pub fn hash(_: @This(), capture: Capture) u64 {
        var digest = std.hash.XxHash64.init(0);
        digest.update(&std.mem.toBytes(@intFromPtr(capture.exe)));
        digest.update(capture.name);
        return digest.final();
    }
    pub fn eql(_: @This(), a: Capture, b: Capture) bool {
        return a.exe == b.exe and std.mem.eql(u8, a.name, b.name);
    }
}, std.hash_map.default_max_load_percentage) = .empty,
lambdas: std.ArrayListUnmanaged(Executable) = .empty,
error_info: ?ErrorInfo = null,
let_stack: std.ArrayListUnmanaged(Let) = .empty,
shadow_stack: std.ArrayListUnmanaged(Shadow) = .empty,
save_stack: std.ArrayListUnmanaged(u8) = .empty,
type_extras: std.ArrayListUnmanaged(Type) = .empty,
type_scratch: std.ArrayListUnmanaged(Type) = .empty,
lazy_define: ?LazyDefine = null,

pub const Flavor = enum(u8) {
    arithlang,
    varlang,
    definelang,
    funclang,
    reflang,
    typelang,

    pub const Map = std.StaticStringMap(Flavor).initComptime(.{
        .{ "ArithLang", .arithlang },
        .{ "VarLang", .varlang },
        .{ "DefineLang", .definelang },
        .{ "FuncLang", .funclang },
        .{ "RefLang", .reflang },
        .{ "TypeLang", .typelang },
    });

    pub fn isBefore(a: Flavor, b: Flavor) bool {
        return @intFromEnum(a) < @intFromEnum(b);
    }
};

pub fn init(gpa: std.mem.Allocator, source: [:0]const u8, flavor: Flavor) CodeGen {
    return .{
        .gpa = gpa,
        .tokenizer = .{ .source = source },
        .flavor = flavor,
    };
}

pub fn reset(cg: *CodeGen, source: [:0]const u8, flavor: Flavor) void {
    cg.result_endings.clearRetainingCapacity();
    cg.constants.clearRetainingCapacity();
    cg.captures.clearRetainingCapacity();
    cg.defines.clearRetainingCapacity();
    cg.define_types.clearRetainingCapacity();
    for (cg.lambdas.items) |*lambda| {
        lambda.deinit();
    }
    cg.lambdas.clearRetainingCapacity();
    cg.let_stack.clearRetainingCapacity();
    cg.shadow_stack.clearRetainingCapacity();
    cg.save_stack.clearRetainingCapacity();
    cg.type_extras.clearRetainingCapacity();
    cg.type_scratch.clearRetainingCapacity();
    cg.* = .{
        .gpa = cg.gpa,
        .tokenizer = .{ .source = source },
        .flavor = flavor,
        .result_endings = cg.result_endings,
        .constants = cg.constants,
        .captures = cg.captures,
        .defines = cg.defines,
        .lambdas = cg.lambdas,
        .let_stack = cg.let_stack,
        .shadow_stack = cg.shadow_stack,
        .save_stack = cg.save_stack,
        .type_extras = cg.type_extras,
        .type_scratch = cg.type_scratch,
    };
}

pub fn deinit(cg: *CodeGen) void {
    cg.result_endings.deinit(cg.gpa);
    cg.constants.deinit(cg.gpa);
    cg.captures.deinit(cg.gpa);
    cg.defines.deinit(cg.gpa);
    cg.define_types.deinit(cg.gpa);
    for (cg.lambdas.items) |*lambda| {
        lambda.deinit();
    }
    cg.lambdas.deinit(cg.gpa);
    cg.let_stack.deinit(cg.gpa);
    cg.shadow_stack.deinit(cg.gpa);
    cg.save_stack.deinit(cg.gpa);
    cg.type_extras.deinit(cg.gpa);
    cg.type_scratch.deinit(cg.gpa);
}

const Shadow = struct {
    name: []const u8,
    old_local: ?u16,
};

pub const Capture = struct {
    exe: *Executable,
    name: []const u8,
};

const Let = struct {
    identifier: []const u8,
    type: Type, // undefined if not TypeLang
};

const LazyDefine = struct {
    name: []const u8,
    index: u16,
};

pub const Type = union(enum) {
    unit,
    num,
    bool,
    string,
    /// extras[function=arg_count, arg0, arg1, ..., argn, return]
    function: ExtraIndex,
    /// extras[a]
    ref: ExtraIndex,
    /// extras[a, b]
    pair: ExtraIndex,
    /// extras[a]
    list: ExtraIndex,

    const ExtraIndex = u32;

    pub const Tag = std.meta.Tag(Type);

    pub fn equal(extras: []const Type, a: Type, b: Type) bool {
        const a_tag: Type.Tag = a;
        const b_tag: Type.Tag = b;

        if (a_tag != b_tag) {
            return false;
        }

        switch (a_tag) {
            .unit, .num, .bool, .string => {},
            .function => {
                const a_args = extras[a.function].function;
                const b_args = extras[b.function].function;
                if (a_args != b_args) {
                    return false;
                }
                for (
                    extras[a.function + 1 ..][0 .. a_args + 1],
                    extras[b.function + 1 ..][0 .. b_args + 1],
                ) |a_el, b_el| {
                    if (!Type.equal(extras, a_el, b_el)) {
                        return false;
                    }
                }
            },
            .ref => {
                const x = extras[a.ref];
                const y = extras[b.ref];
                return Type.equal(extras, x, y);
            },
            .pair => {
                const x = extras[a.pair..][0..2];
                const y = extras[b.pair..][0..2];
                return Type.equal(extras, x[0], y[0]) and Type.equal(extras, x[1], y[1]);
            },
            .list => {
                const x = extras[a.list];
                const y = extras[b.list];
                return Type.equal(extras, x, y);
            },
        }
        return true;
    }
};

pub const Error = std.mem.Allocator.Error || error{InvalidSyntax};
pub const ErrorInfo = struct {
    source_range: SourceRange,
    data: Data,

    pub const Data = union(enum) {
        expected_token: struct { expected: Token, got: Token },
        expected_expression: Token,
        invalid_function_call,
        invalid_define,
        invalid_number,
        unsupported: Feature,
        expected_type: struct { expected: Type, got: Type },
        expected_reference: Type,
        expected_list: Type,
        expected_list_or_pair: Type,
        expected_function: Type,
        expected_n_arguments: struct { callee: Type, expected: u32, got: u32 },
        expected_type_expression: Token,
        undeclared_identifier: []const u8,

        pub const Feature = enum {
            bool,
            define,
            variable,
            conditional,
            comparison,
            lambda,
            call,
            list_or_pair,
            reference,
        };
    };
};

fn fail(cg: *CodeGen, error_info: ErrorInfo) !noreturn {
    cg.error_info = error_info;
    return error.InvalidSyntax;
}

fn failUnsupported(cg: *CodeGen, feature: ErrorInfo.Data.Feature) !noreturn {
    try cg.fail(.{ .data = .{ .unsupported = feature }, .source_range = cg.tokenizer.tokenRange() });
}

pub fn formatError(cg: *CodeGen, config: std.io.tty.Config, writer: anytype) !void {
    const error_info = cg.error_info.?;
    try config.setColor(writer, .bold);
    try config.setColor(writer, .red);
    try writer.writeAll("error: ");
    try config.setColor(writer, .reset);
    try config.setColor(writer, .bold);
    switch (error_info.data) {
        .expected_token => |data| try writer.print("expected {s}, got {s}", .{ data.expected.description(), data.got.description() }),
        .expected_expression => |data| try writer.print("expected expression, got {s}", .{data.description()}),
        .invalid_function_call => try writer.writeAll("invalid function call"),
        .invalid_define => try writer.writeAll("define must be top-level"),
        .invalid_number => try writer.writeAll("failed to parse number literal"),
        .unsupported => |feature| try writer.print("{s} are not supported in {s}", .{ switch (feature) {
            .bool => "boolean literals",
            .define => "defines",
            .variable => "variables",
            .conditional => "conditionals",
            .comparison => "comparisons",
            .lambda => "lambdas",
            .call => "calls",
            .list_or_pair => "lists and pairs",
            .reference => "references",
        }, switch (cg.flavor) {
            .arithlang => "ArithLang",
            .varlang => "VarLang",
            .definelang => "DefineLang",
            .funclang => "FuncLang",
            .reflang => "RefLang",
            .typelang => "TypeLang",
        } }),
        .expected_type => |data| {
            try writer.writeAll("expected '");
            try cg.formatType(data.expected, writer);
            try writer.writeAll("', got '");
            try cg.formatType(data.got, writer);
            try writer.writeByte('\'');
        },
        inline .expected_reference, .expected_list, .expected_list_or_pair, .expected_function => |data, tag| {
            try writer.writeAll("expected " ++ switch (tag) {
                .expected_reference => "reference",
                .expected_list => "list",
                .expected_list_or_pair => "list or pair",
                .expected_function => "function",
                else => unreachable,
            } ++ " type, got '");
            try cg.formatType(data, writer);
            try writer.writeByte('\'');
        },
        .expected_n_arguments => |data| {
            try writer.writeAll("function type '");
            try cg.formatType(data.callee, writer);
            try writer.print("' expects {} arguments, got {}", .{ data.expected, data.got });
        },
        .expected_type_expression => |data| try writer.print("expected type, got {s}", .{data.description()}),
        .undeclared_identifier => |data| try writer.print("variable '{s}' has not been declared", .{data}),
    }
    try config.setColor(writer, .reset);
}

fn formatType(cg: *CodeGen, t: Type, writer: anytype) !void {
    switch (t) {
        .bool => try writer.writeAll("bool"),
        .num => try writer.writeAll("num"),
        .unit => try writer.writeAll("unit"),
        .ref => |ref_i| {
            try writer.writeAll("Ref ");
            try cg.formatType(cg.type_extras.items[ref_i], writer);
        },
        .list => |list_i| {
            try writer.writeAll("List<");
            try cg.formatType(cg.type_extras.items[list_i], writer);
            try writer.writeAll(">");
        },
        .pair => |pair_i| {
            try writer.writeByte('(');
            try cg.formatType(cg.type_extras.items[pair_i..][0], writer);
            // The Java implementation does not include a comma between the left
            // and right. However, it is required one when typing out the type
            // itself so we're going to put it there anyways.
            try writer.writeAll(", ");
            try cg.formatType(cg.type_extras.items[pair_i..][1], writer);
            try writer.writeByte(')');
        },
        .function => |function_i| {
            try writer.writeByte('(');
            const args = cg.type_extras.items[function_i].function;
            for (cg.type_extras.items[function_i + 1 ..][0..args], 0..) |arg, i| {
                if (i != 0) {
                    try writer.writeByte(' ');
                }
                try cg.formatType(arg, writer);
            }
            try writer.writeAll(" -> ");
            try cg.formatType(cg.type_extras.items[function_i + 1 + args], writer);
            try writer.writeByte(')');
        },
        .string => unreachable,
    }
}

fn eatToken(cg: *CodeGen, token: Token) ?[]const u8 {
    if (cg.tokenizer.token != token) {
        return null;
    }
    defer cg.tokenizer.next();
    return cg.tokenizer.tokenSource();
}

fn expectToken(cg: *CodeGen, token: Token) ![]const u8 {
    return cg.eatToken(token) orelse {
        try cg.fail(.{
            .source_range = cg.tokenizer.tokenRange(),
            .data = .{ .expected_token = .{ .expected = token, .got = cg.tokenizer.token } },
        });
    };
}

fn allocCapture(cg: *CodeGen) !u16 {
    defer cg.captures_count += 1;
    return cg.captures_count;
}

fn genIdentifier(cg: *CodeGen, exe: *Executable, identifier: []const u8, comptime is_typed: bool) !if (is_typed) Type else void {
    if (exe.locals.get(identifier)) |local| {
        try exe.emit(.load_local, @intCast(local), null);
        if (is_typed) return exe.local_types.items[local];
    } else {
        var maybe_parent = exe.parent;
        while (maybe_parent) |parent| {
            if (parent.locals.get(identifier)) |local| {
                const gop = try cg.captures.getOrPut(cg.gpa, .{
                    .exe = parent,
                    .name = identifier,
                });
                if (!gop.found_existing) {
                    gop.value_ptr.* = try cg.allocCapture();
                }
                try parent.emit(.move_capture, .{
                    .local = local,
                    .capture = @intCast(gop.value_ptr.*),
                }, null);
                try exe.emit(.load_capture, @intCast(exe.captures.items.len), null);
                try exe.captures.append(cg.gpa, gop.value_ptr.*);
                if (is_typed) return parent.local_types.items[local];
                return;
            }
            maybe_parent = parent.parent;
        }

        const gop = try cg.defines.getOrPut(cg.gpa, identifier);
        if (gop.found_existing) {
            try exe.emit(.load_define, if (is_typed) gop.value_ptr.* else @intCast(gop.index), null);
            if (is_typed) return cg.define_types.items[gop.value_ptr.*];
        } else {
            if (is_typed) {
                try cg.fail(.{
                    .data = .{ .undeclared_identifier = identifier },
                    .source_range = cg.tokenizer.tokenRange(),
                });
            }
            try exe.emit(.load_define_checked, @intCast(gop.index), null);
        }
    }
}

fn parseType(cg: *CodeGen) !Type {
    switch (cg.tokenizer.token) {
        .num => {
            cg.tokenizer.next();
            return .num;
        },
        .bool => {
            cg.tokenizer.next();
            return .bool;
        },
        .unit => {
            cg.tokenizer.next();
            return .unit;
        },
        .Ref => {
            cg.tokenizer.next();
            const inner = try cg.parseType();
            const inner_i = cg.type_extras.items.len;
            try cg.type_extras.append(cg.gpa, inner);
            return .{ .ref = @intCast(inner_i) };
        },
        .List => {
            cg.tokenizer.next();
            _ = try cg.expectToken(.@"<");
            const inner = try cg.parseType();
            _ = try cg.expectToken(.@">");
            const inner_i = cg.type_extras.items.len;
            try cg.type_extras.append(cg.gpa, inner);
            return .{ .list = @intCast(inner_i) };
        },
        .@"(" => {
            cg.tokenizer.next();

            if (cg.tokenizer.token == .@"->") {
                cg.tokenizer.next();
                const return_type = try cg.parseType();
                _ = try cg.expectToken(.@")");
                const function_i = cg.type_extras.items.len;
                try cg.type_extras.appendSlice(cg.gpa, &.{ .{ .function = 0 }, return_type });
                return .{ .function = @intCast(function_i) };
            }

            const first = try cg.parseType();
            if (cg.tokenizer.token == .@",") {
                cg.tokenizer.next();
                const second = try cg.parseType();
                _ = try cg.expectToken(.@")");
                const pair_i = cg.type_extras.items.len;
                try cg.type_extras.appendSlice(cg.gpa, &.{ first, second });
                return .{ .pair = @intCast(pair_i) };
            }

            const type_scratch_len = cg.type_scratch.items.len;
            while (cg.eatToken(.@"->") == null) {
                try cg.type_scratch.append(cg.gpa, try cg.parseType());
            }

            const return_type = try cg.parseType();
            _ = try cg.expectToken(.@")");

            const function_i = cg.type_extras.items.len;
            try cg.type_extras.ensureUnusedCapacity(cg.gpa, 3 + cg.type_scratch.items.len - type_scratch_len);
            cg.type_extras.appendSliceAssumeCapacity(&.{ .{ .function = @intCast(1 + cg.type_scratch.items.len - type_scratch_len) }, first });
            cg.type_extras.appendSliceAssumeCapacity(cg.type_scratch.items[type_scratch_len..]);
            cg.type_extras.appendAssumeCapacity(return_type);
            cg.type_scratch.shrinkRetainingCapacity(type_scratch_len);
            return .{ .function = @intCast(function_i) };
        },
        else => {
            try cg.fail(.{
                .source_range = cg.tokenizer.tokenRange(),
                .data = .{ .expected_type_expression = cg.tokenizer.token },
            });
        },
    }
}

fn equal(cg: *CodeGen, a: Type, b: Type) bool {
    return Type.equal(cg.type_extras.items, a, b);
}

fn genExpression(cg: *CodeGen, exe: *Executable, is_tail: bool, comptime is_typed: bool) !if (is_typed) Type else void {
    switch (cg.tokenizer.token) {
        inline .@"#f", .@"#t" => |tag| {
            if (cg.flavor.isBefore(.funclang)) {
                try cg.failUnsupported(.bool);
            }
            try exe.emitConstant(Value.from(tag == .@"#t"), null);
            cg.tokenizer.next();
            if (is_typed) return .bool;
        },
        .number_i32 => {
            if (std.fmt.parseInt(i32, cg.tokenizer.tokenSource(), 10)) |number_i32| {
                try exe.emitConstant(Value.from(number_i32), null);
                cg.tokenizer.next();
            } else |_| {
                @branchHint(.unlikely);
                const number_f64 = std.fmt.parseFloat(f64, cg.tokenizer.tokenSource()) catch {
                    try cg.fail(.{
                        .source_range = cg.tokenizer.tokenRange(),
                        .data = .invalid_number,
                    });
                };
                try exe.emitConstant(Value.from(number_f64), null);
                cg.tokenizer.next();
            }
            if (is_typed) return .num;
        },
        .number_f64 => {
            const number_f64 = std.fmt.parseFloat(f64, cg.tokenizer.tokenSource()) catch {
                try cg.fail(.{
                    .source_range = cg.tokenizer.tokenRange(),
                    .data = .invalid_number,
                });
            };
            try exe.emitConstant(Value.from(number_f64), null);
            cg.tokenizer.next();
            if (is_typed) return .num;
        },
        .identifier => {
            if (cg.flavor.isBefore(.varlang)) {
                try cg.failUnsupported(.variable);
            }
            const resolved_type = try cg.genIdentifier(exe, cg.tokenizer.tokenSource(), is_typed);
            cg.tokenizer.next();
            if (is_typed) return resolved_type;
        },
        .@"(" => {
            const open_range = cg.tokenizer.tokenRange();
            cg.tokenizer.next();
            switch (cg.tokenizer.token) {
                .define => {
                    try cg.fail(.{
                        .source_range = cg.tokenizer.tokenRange(),
                        .data = .invalid_define,
                    });
                },
                .let => {
                    if (cg.flavor.isBefore(.varlang)) {
                        try cg.failUnsupported(.variable);
                    }
                    cg.tokenizer.next();

                    const let_stack_len = cg.let_stack.items.len;
                    const shadow_stack_len = cg.shadow_stack.items.len;

                    _ = try cg.expectToken(.@"(");
                    while (cg.eatToken(.@"(") != null) {
                        const identifier = try cg.expectToken(.identifier);
                        if (is_typed) _ = try cg.expectToken(.@":");
                        const expected_type = if (is_typed) try cg.parseType() else {};
                        const start = cg.tokenizer.start;
                        const actual_type = try cg.genExpression(exe, false, is_typed);
                        if (is_typed and !cg.equal(expected_type, actual_type)) {
                            try cg.fail(.{
                                .data = .{ .expected_type = .{ .expected = expected_type, .got = actual_type } },
                                .source_range = .{ .start = @intCast(start), .end = @intCast(cg.tokenizer.last_end) },
                            });
                        }
                        try cg.let_stack.append(cg.gpa, .{
                            .identifier = identifier,
                            .type = if (is_typed) expected_type else undefined,
                        });
                        _ = try cg.expectToken(.@")");
                    }
                    _ = try cg.expectToken(.@")");

                    var i: usize = cg.let_stack.items.len;
                    while (i > let_stack_len) {
                        i -= 1;
                        const let = cg.let_stack.items[i];
                        const gop = try exe.locals.getOrPut(cg.gpa, let.identifier);
                        const old = if (gop.found_existing) gop.value_ptr.* else undefined;
                        gop.value_ptr.* = try exe.allocLocal(if (is_typed) let.type else {});
                        try exe.emit(.move_local, gop.value_ptr.*, null);
                        try cg.shadow_stack.append(cg.gpa, .{
                            .name = let.identifier,
                            .old_local = if (gop.found_existing) old else null,
                        });
                    }
                    cg.let_stack.shrinkRetainingCapacity(let_stack_len);

                    const result_type = try cg.genExpression(exe, is_tail, is_typed);

                    for (cg.shadow_stack.items[shadow_stack_len..]) |shadow| {
                        if (shadow.old_local) |old_local| {
                            exe.locals.putAssumeCapacity(shadow.name, old_local);
                        } else {
                            std.debug.assert(exe.locals.remove(shadow.name));
                        }
                    }
                    cg.shadow_stack.shrinkRetainingCapacity(shadow_stack_len);
                    _ = try cg.expectToken(.@")");
                    if (is_typed) return result_type;
                },
                .@"if" => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.failUnsupported(.conditional);
                    }
                    const hint = cg.tokenizer.start;
                    cg.tokenizer.next();
                    const condition_start = cg.tokenizer.start;
                    const condition_type = try cg.genExpression(exe, false, is_typed);
                    if (is_typed and condition_type != .bool) {
                        try cg.fail(.{
                            .data = .{ .expected_type = .{ .expected = .bool, .got = condition_type } },
                            .source_range = .{ .start = @intCast(condition_start), .end = @intCast(cg.tokenizer.last_end) },
                        });
                    }
                    const deferred_jump_if_not = try exe.emitDeferred(.jump_if_not, hint);
                    const first_type = try cg.genExpression(exe, is_tail, is_typed);
                    const deferred_jump = try exe.emitDeferred(.jump, null);
                    deferred_jump_if_not.setOffset();
                    const start = cg.tokenizer.start;
                    const second_type = try cg.genExpression(exe, is_tail, is_typed);
                    deferred_jump.setOffset();
                    if (is_typed and !cg.equal(first_type, second_type)) {
                        try cg.fail(.{
                            .data = .{ .expected_type = .{ .expected = first_type, .got = second_type } },
                            .source_range = .{ .start = @intCast(start), .end = @intCast(cg.tokenizer.last_end) },
                        });
                    }
                    _ = try cg.expectToken(.@")");
                    if (is_typed) return first_type;
                },
                inline .@"+", .@"-", .@"*", .@"/", .@"<", .@">", .@"=" => |tag| binary: {
                    const hint = cg.tokenizer.start;

                    switch (tag) {
                        .@"<", .@">", .@"=" => {
                            if (cg.flavor.isBefore(.funclang)) {
                                try cg.failUnsupported(.comparison);
                            }
                        },
                        else => {},
                    }
                    cg.tokenizer.next();
                    const left_start = cg.tokenizer.start;
                    const left_type = try cg.genExpression(exe, false, is_typed);
                    if (is_typed and left_type != .num) {
                        try cg.fail(.{
                            .data = .{ .expected_type = .{ .expected = .num, .got = left_type } },
                            .source_range = .{ .start = @intCast(left_start), .end = @intCast(cg.tokenizer.last_end) },
                        });
                    }

                    const right_start = cg.tokenizer.start;
                    const right_type = try cg.genExpression(exe, false, is_typed);
                    if (is_typed and right_type != .num) {
                        try cg.fail(.{
                            .data = .{ .expected_type = .{ .expected = .num, .got = right_type } },
                            .source_range = .{ .start = @intCast(right_start), .end = @intCast(cg.tokenizer.last_end) },
                        });
                    }

                    const instruction = switch (tag) {
                        .@"+" => .addition,
                        .@"-" => .subtraction,
                        .@"*" => .multiplication,
                        .@"/" => .division,
                        .@"<" => .less,
                        .@">" => .greater,
                        .@"=" => .equal,
                        else => @compileError("unreachable"),
                    };
                    try exe.emit(instruction, {}, hint);

                    const is_many_instruction = switch (tag) {
                        .@"+", .@"-", .@"*", .@"/" => true,
                        else => false,
                    };
                    if (is_many_instruction and cg.tokenizer.token != .@")") {
                        while (cg.eatToken(.@")") == null) {
                            _ = try cg.genExpression(exe, false, is_typed);
                            try exe.emit(instruction, {}, hint);
                        }
                        if (is_typed) return if (is_many_instruction) .num else .bool;
                        break :binary;
                    }

                    _ = try cg.expectToken(.@")");
                    if (is_typed) return if (is_many_instruction) .num else .bool;
                },
                .lambda => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.failUnsupported(.lambda);
                    }
                    cg.tokenizer.next();

                    const LazyInfo = struct {
                        define: LazyDefine,
                        old: ?u16,
                    };

                    const lazy_info: ?LazyInfo = if (is_typed and cg.lazy_define != null) blk: {
                        const gop = try cg.defines.getOrPut(cg.gpa, cg.lazy_define.?.name);
                        defer {
                            gop.value_ptr.* = cg.lazy_define.?.index;
                            cg.lazy_define = null;
                        }
                        break :blk LazyInfo{
                            .define = cg.lazy_define.?,
                            .old = if (gop.found_existing) gop.value_ptr.* else null,
                        };
                    } else null;

                    var exe2: Executable = .{
                        .cg = cg,
                        .arguments = 0,
                        .source = "unknown",
                        .parent = exe,
                    };
                    errdefer exe2.deinit();

                    _ = try cg.expectToken(.@"(");
                    const type_scratch_len = cg.type_scratch.items.len;
                    while (cg.eatToken(.identifier)) |identifier| {
                        const gop = try exe2.locals.getOrPut(cg.gpa, identifier);
                        if (is_typed) {
                            _ = try cg.expectToken(.@":");
                            const argument_type = try cg.parseType();
                            try cg.type_scratch.append(cg.gpa, argument_type);
                            gop.value_ptr.* = try exe2.allocLocal(argument_type);
                        } else {
                            gop.value_ptr.* = try exe2.allocLocal({});
                        }
                        exe2.arguments += 1;
                    }
                    _ = try cg.expectToken(.@")");

                    const return_type = try cg.genExpression(&exe2, true, is_typed);

                    const end = cg.tokenizer.index;
                    _ = try cg.expectToken(.@")");

                    try exe2.emit(.@"return", {}, null);
                    exe2.source = cg.tokenizer.source[open_range.start..end];
                    try exe.emit(.push_lambda, @intCast(cg.lambdas.items.len), null);
                    try cg.lambdas.append(cg.gpa, exe2);

                    if (is_typed) {
                        if (lazy_info != null) {
                            if (lazy_info.?.old) |old| {
                                cg.defines.putAssumeCapacity(lazy_info.?.define.name, old);
                            } else {
                                std.debug.assert(cg.defines.swapRemove(lazy_info.?.define.name));
                            }
                        }

                        const function_i = cg.type_extras.items.len;
                        try cg.type_extras.ensureUnusedCapacity(cg.gpa, 1 + exe2.arguments + 1);
                        cg.type_extras.appendAssumeCapacity(.{ .function = exe2.arguments });
                        cg.type_extras.appendSliceAssumeCapacity(cg.type_scratch.items[type_scratch_len..]);
                        cg.type_extras.appendAssumeCapacity(return_type);
                        cg.type_scratch.shrinkRetainingCapacity(type_scratch_len);
                        return .{ .function = @intCast(function_i) };
                    }
                },
                .identifier, .@"(" => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.failUnsupported(.call);
                    }
                    const hint = cg.tokenizer.start;
                    const callee_type = try cg.genExpression(exe, false, is_typed);
                    const end = cg.tokenizer.last_end;

                    if (is_typed and callee_type != .function) {
                        try cg.fail(.{
                            .data = .{ .expected_function = callee_type },
                            .source_range = .{ .start = @intCast(hint), .end = @intCast(end) },
                        });
                    }
                    const callee_len = if (is_typed) cg.type_extras.items[callee_type.function].function else {};

                    var argument_count: u16 = 0;
                    while (cg.eatToken(.@")") == null) {
                        const value_start = cg.tokenizer.start;
                        const value_type = try cg.genExpression(exe, false, is_typed);
                        if (is_typed and argument_count < callee_len) {
                            const expected_type = cg.type_extras.items[callee_type.function + 1 ..][argument_count];
                            if (!cg.equal(expected_type, value_type)) {
                                try cg.fail(.{
                                    .data = .{ .expected_type = .{ .expected = expected_type, .got = value_type } },
                                    .source_range = .{ .start = @intCast(value_start), .end = @intCast(cg.tokenizer.last_end) },
                                });
                            }
                        }
                        argument_count += 1;
                    }

                    if (is_typed and argument_count != callee_len) {
                        try cg.fail(.{
                            .data = .{ .expected_n_arguments = .{ .callee = callee_type, .expected = callee_len, .got = argument_count } },
                            .source_range = .{ .start = @intCast(hint), .end = @intCast(cg.tokenizer.last_end) },
                        });
                    }

                    if (is_tail) {
                        try exe.emit(.tail_call, argument_count, hint);
                    } else {
                        try exe.emit(.call, argument_count, hint);
                    }

                    if (is_typed) {
                        return cg.type_extras.items[callee_type.function + 1 + callee_len];
                    }
                },
                .list => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.failUnsupported(.list_or_pair);
                    }
                    cg.tokenizer.next();
                    if (is_typed) _ = try cg.expectToken(.@":");
                    const item_type = if (is_typed) try cg.parseType() else {};
                    var item_count: u16 = 0;
                    while (cg.eatToken(.@")") == null) {
                        const start = cg.tokenizer.start;
                        const value_type = try cg.genExpression(exe, false, is_typed);
                        if (is_typed and !cg.equal(item_type, value_type)) {
                            try cg.fail(.{
                                .data = .{ .expected_type = .{ .expected = item_type, .got = value_type } },
                                .source_range = .{ .start = @intCast(start), .end = @intCast(cg.tokenizer.last_end) },
                            });
                        }
                        item_count += 1;
                    }
                    try exe.emit(.push_list, item_count, null);
                    if (is_typed) {
                        const type_i = cg.type_extras.items.len;
                        try cg.type_extras.append(cg.gpa, item_type);
                        return .{ .list = @intCast(type_i) };
                    }
                },
                .cons => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.failUnsupported(.list_or_pair);
                    }
                    cg.tokenizer.next();
                    const hint = cg.tokenizer.start;
                    const left_type = try cg.genExpression(exe, false, is_typed);
                    const right_type = try cg.genExpression(exe, false, is_typed);
                    try exe.emit(.cons, {}, hint);
                    _ = try cg.expectToken(.@")");
                    if (is_typed) {
                        if (right_type == .list and cg.equal(left_type, cg.type_extras.items[right_type.list])) {
                            const list_i = cg.type_extras.items.len;
                            try cg.type_extras.append(cg.gpa, left_type);
                            return .{ .list = @intCast(list_i) };
                        } else {
                            const pair_i = cg.type_extras.items.len;
                            try cg.type_extras.appendSlice(cg.gpa, &.{ left_type, right_type });
                            return .{ .pair = @intCast(pair_i) };
                        }
                    }
                },
                .car => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.failUnsupported(.list_or_pair);
                    }
                    const hint = cg.tokenizer.start;
                    cg.tokenizer.next();
                    const start = cg.tokenizer.start;
                    const value_type = try cg.genExpression(exe, false, is_typed);
                    if (is_typed and value_type != .list and value_type != .pair) {
                        try cg.fail(.{
                            .data = .{ .expected_list_or_pair = value_type },
                            .source_range = .{ .start = @intCast(start), .end = @intCast(cg.tokenizer.last_end) },
                        });
                    }
                    try exe.emit(.car, {}, hint);
                    _ = try cg.expectToken(.@")");
                    if (is_typed) return cg.type_extras.items[if (value_type == .list) value_type.list else value_type.pair];
                },
                .cdr => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.failUnsupported(.list_or_pair);
                    }
                    const hint = cg.tokenizer.start;
                    cg.tokenizer.next();
                    const start = cg.tokenizer.start;
                    const value_type = try cg.genExpression(exe, false, is_typed);
                    if (is_typed and value_type != .list and value_type != .pair) {
                        try cg.fail(.{
                            .data = .{ .expected_list_or_pair = value_type },
                            .source_range = .{ .start = @intCast(start), .end = @intCast(cg.tokenizer.last_end) },
                        });
                    }
                    try exe.emit(.cdr, {}, hint);
                    _ = try cg.expectToken(.@")");
                    if (is_typed) return if (value_type == .list) value_type else cg.type_extras.items[value_type.pair + 1];
                },
                .@"null?" => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.failUnsupported(.list_or_pair);
                    }
                    const hint = cg.tokenizer.start;
                    cg.tokenizer.next();
                    const start = cg.tokenizer.start;
                    const list_type = try cg.genExpression(exe, false, is_typed);
                    if (is_typed and list_type != .list) {
                        try cg.fail(.{
                            .data = .{ .expected_list = list_type },
                            .source_range = .{ .start = @intCast(start), .end = @intCast(cg.tokenizer.last_end) },
                        });
                    }
                    try exe.emit(.null, {}, hint);
                    _ = try cg.expectToken(.@")");
                    if (is_typed) return .bool;
                },
                inline .ref, .free, .deref => |tag| {
                    if (cg.flavor.isBefore(.reflang)) {
                        try cg.failUnsupported(.reference);
                    }
                    const hint = cg.tokenizer.start;
                    cg.tokenizer.next();
                    const expected_type = if (is_typed and tag == .ref) blk: {
                        _ = try cg.expectToken(.@":");
                        break :blk try cg.parseType();
                    } else {};
                    const start = cg.tokenizer.start;
                    const value_type = try cg.genExpression(exe, false, is_typed);
                    const end = cg.tokenizer.last_end;
                    try exe.emit(switch (tag) {
                        .ref => .ref,
                        .free => .free,
                        .deref => .deref,
                        else => @compileError("unreachable"),
                    }, {}, hint);
                    _ = try cg.expectToken(.@")");
                    if (is_typed) switch (tag) {
                        .ref => {
                            if (!cg.equal(expected_type, value_type)) {
                                try cg.fail(.{
                                    .data = .{ .expected_type = .{ .expected = expected_type, .got = value_type } },
                                    .source_range = .{ .start = @intCast(start), .end = @intCast(end) },
                                });
                            }

                            const type_i = cg.type_extras.items.len;
                            try cg.type_extras.append(cg.gpa, expected_type);
                            return .{ .ref = @intCast(type_i) };
                        },
                        .free => {
                            if (value_type != .ref) {
                                try cg.fail(.{
                                    .data = .{ .expected_reference = value_type },
                                    .source_range = .{ .start = @intCast(start), .end = @intCast(end) },
                                });
                            }
                            return .unit;
                        },
                        .deref => {
                            if (value_type != .ref) {
                                try cg.fail(.{
                                    .data = .{ .expected_reference = value_type },
                                    .source_range = .{ .start = @intCast(start), .end = @intCast(end) },
                                });
                            }
                            return cg.type_extras.items[value_type.ref];
                        },
                        else => @compileError("unreachable"),
                    };
                },
                .@"set!" => {
                    if (cg.flavor.isBefore(.reflang)) {
                        try cg.failUnsupported(.reference);
                    }
                    // rhs is evaluated before lhs
                    const hint = cg.tokenizer.start;
                    cg.tokenizer.next();

                    const bytecode_len = exe.bytecode.items.len;
                    const reference_start = cg.tokenizer.start;
                    const reference_type = try cg.genExpression(exe, false, is_typed);
                    if (is_typed and reference_type != .ref) {
                        try cg.fail(.{
                            .data = .{ .expected_reference = reference_type },
                            .source_range = .{ .start = @intCast(reference_start), .end = @intCast(cg.tokenizer.last_end) },
                        });
                    }

                    const save_stack_len = cg.save_stack.items.len;
                    try cg.save_stack.appendSlice(cg.gpa, exe.bytecode.items[bytecode_len..]);
                    exe.bytecode.shrinkRetainingCapacity(bytecode_len);

                    const value_start = cg.tokenizer.start;
                    const value_type = try cg.genExpression(exe, false, is_typed);
                    if (is_typed) {
                        const expected_type = cg.type_extras.items[reference_type.ref];
                        if (!cg.equal(expected_type, value_type)) {
                            try cg.fail(.{
                                .data = .{ .expected_type = .{ .expected = expected_type, .got = value_type } },
                                .source_range = .{ .start = @intCast(value_start), .end = @intCast(cg.tokenizer.last_end) },
                            });
                        }
                    }

                    try exe.bytecode.appendSlice(cg.gpa, cg.save_stack.items[save_stack_len..]);
                    cg.save_stack.shrinkRetainingCapacity(save_stack_len);

                    try exe.emit(.set, {}, hint);
                    _ = try cg.expectToken(.@")");
                    if (is_typed) return value_type;
                },
                else => {
                    try cg.fail(.{
                        .source_range = cg.tokenizer.tokenRange(),
                        .data = .invalid_function_call,
                    });
                },
            }
        },
        else => {
            try cg.fail(.{
                .source_range = cg.tokenizer.tokenRange(),
                .data = .{ .expected_expression = cg.tokenizer.token },
            });
        },
    }
}

fn genDefine(cg: *CodeGen, exe: *Executable, comptime is_typed: bool) !void {
    // assumes "(define"
    // defines are mutable pre-TypeLang, immutable in TypeLang and up
    const identifier = try cg.expectToken(.identifier);
    if (is_typed) _ = try cg.expectToken(.@":");
    const expected_type = if (is_typed) try cg.parseType() else {};
    const next_define = if (is_typed) @as(u16, @intCast(cg.define_types.items.len)) else {};
    if (is_typed) {
        try cg.define_types.append(cg.gpa, expected_type);
        cg.lazy_define = .{
            .name = identifier,
            .index = next_define,
        };
    }
    const start = cg.tokenizer.start;
    const value_type = try cg.genExpression(exe, false, is_typed);
    const gop = try cg.defines.getOrPut(cg.gpa, identifier);
    if (is_typed) {
        if (!cg.equal(expected_type, value_type)) {
            try cg.fail(.{
                .data = .{ .expected_type = .{ .expected = expected_type, .got = value_type } },
                .source_range = .{ .start = @intCast(start), .end = @intCast(cg.tokenizer.last_end) },
            });
        }
        cg.lazy_define = null;
        gop.value_ptr.* = next_define;
    }
    exe.locals.clearRetainingCapacity();
    try exe.emit(.move_define, if (is_typed) gop.value_ptr.* else @intCast(gop.index), null);
    _ = try cg.expectToken(.@")");
}

pub const Mode = enum(u8) {
    program,
    repl_like,
};

pub fn genProgram(cg: *CodeGen, mode: Mode) Error!Executable {
    if (cg.flavor.isBefore(.typelang)) {
        return cg.genProgramInner(mode, false);
    } else {
        return cg.genProgramInner(mode, true);
    }
}

fn genProgramInner(cg: *CodeGen, mode: Mode, comptime is_typed: bool) !Executable {
    var exe: Executable = .{
        .cg = cg,
        .arguments = 0,
        .local_count = 0,
        .source = cg.tokenizer.source,
    };
    errdefer exe.deinit();

    cg.tokenizer.next();
    while (true) {
        if (cg.tokenizer.token == .@"(") define: {
            const start = cg.tokenizer.start;
            cg.tokenizer.next();

            if (cg.tokenizer.token != .define) {
                cg.tokenizer.index = start;
                cg.tokenizer.next();
                break :define;
            }
            if (cg.flavor.isBefore(.definelang)) {
                try cg.failUnsupported(.define);
            }
            cg.tokenizer.next();

            try cg.genDefine(&exe, is_typed);
            continue;
        }

        if (cg.tokenizer.token == .eof) {
            if (mode == .program) {
                cg.results += 1;
                try exe.emitConstant(.empty, null);
                try cg.result_endings.append(cg.gpa, @intCast(cg.tokenizer.last_end));
            }
            break;
        }

        _ = try cg.genExpression(&exe, false, is_typed);
        try cg.result_endings.append(cg.gpa, @intCast(cg.tokenizer.last_end));
        switch (mode) {
            .program => {
                cg.results += 1;
                if (cg.tokenizer.token != .eof) {
                    try cg.fail(.{
                        .source_range = cg.tokenizer.tokenRange(),
                        .data = .{ .expected_token = .{ .expected = .eof, .got = cg.tokenizer.token } },
                    });
                }
                break;
            },
            .repl_like => {
                cg.results += 1;
                try exe.emit(.push_result, {}, null);
                if (cg.tokenizer.token == .eof) break;
            },
        }
    }
    try exe.emit(.@"return", {}, null);
    return exe;
}
