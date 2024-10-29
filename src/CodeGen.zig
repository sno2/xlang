const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");
const Vm = @import("Vm.zig");
const Executable = @import("Executable.zig");

const SourceRange = Tokenizer.SourceRange;
const Token = Tokenizer.Token;
const Value = Vm.Value;
const Instruction = Executable.Instruction;

const CodeGen = @This();

gpa: std.mem.Allocator,
tokenizer: Tokenizer,
flavor: Flavor,
results: usize = 0,
result_endings: std.ArrayListUnmanaged(u32) = .empty,
constants: std.ArrayListUnmanaged(Value) = .empty,
defines: std.StringArrayHashMapUnmanaged(void) = .empty,
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
identifier_stack: std.ArrayListUnmanaged([]const u8) = .empty,
shadow_stack: std.ArrayListUnmanaged(Shadow) = .empty,
save_stack: std.ArrayListUnmanaged(u8) = .empty,

pub const Flavor = enum(u8) {
    arithlang,
    varlang,
    definelang,
    funclang,
    reflang,

    pub const Map = std.StaticStringMap(Flavor).initComptime(.{
        .{ "ArithLang", .arithlang },
        .{ "VarLang", .varlang },
        .{ "DefineLang", .definelang },
        .{ "FuncLang", .funclang },
        .{ "RefLang", .reflang },
    });

    fn isBefore(a: Flavor, b: Flavor) bool {
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
    for (cg.lambdas.items) |*lambda| {
        lambda.deinit();
    }
    cg.lambdas.clearRetainingCapacity();
    cg.identifier_stack.clearRetainingCapacity();
    cg.shadow_stack.clearRetainingCapacity();
    cg.save_stack.clearRetainingCapacity();
    cg.* = .{
        .gpa = cg.gpa,
        .tokenizer = .{ .source = source },
        .flavor = flavor,
        .result_endings = cg.result_endings,
        .constants = cg.constants,
        .captures = cg.captures,
        .defines = cg.defines,
        .lambdas = cg.lambdas,
        .identifier_stack = cg.identifier_stack,
        .shadow_stack = cg.shadow_stack,
        .save_stack = cg.save_stack,
    };
}

pub fn deinit(cg: *CodeGen) void {
    cg.result_endings.deinit(cg.gpa);
    cg.constants.deinit(cg.gpa);
    cg.captures.deinit(cg.gpa);
    cg.defines.deinit(cg.gpa);
    for (cg.lambdas.items) |*lambda| {
        lambda.deinit();
    }
    cg.lambdas.deinit(cg.gpa);
    cg.identifier_stack.deinit(cg.gpa);
    cg.shadow_stack.deinit(cg.gpa);
    cg.save_stack.deinit(cg.gpa);
}

const Shadow = struct {
    name: []const u8,
    old_local: ?u16,
};

pub const Capture = struct {
    exe: *Executable,
    name: []const u8,
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
        unsupported,
    };
};

fn fail(cg: *CodeGen, error_info: ErrorInfo) !noreturn {
    cg.error_info = error_info;
    return error.InvalidSyntax;
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
        .unsupported => try writer.print("syntax is not supported in {s}", .{switch (cg.flavor) {
            .arithlang => "ArithLang",
            .varlang => "VarLang",
            .definelang => "DefineLang",
            .funclang => "FuncLang",
            .reflang => "RefLang",
        }}),
    }
    try config.setColor(writer, .reset);
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

fn genIdentifier(cg: *CodeGen, exe: *Executable, identifier: []const u8) !void {
    if (exe.locals.get(identifier)) |local| {
        try exe.emit(.load_local, @intCast(local), null);
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
                    try parent.emit(.move_capture, .{
                        .local = local,
                        .capture = @intCast(gop.value_ptr.*),
                    }, null);
                }
                try exe.emit(.load_capture, @intCast(exe.captures.items.len), null);
                try exe.captures.append(cg.gpa, gop.value_ptr.*);
                return;
            }
            maybe_parent = parent.parent;
        }

        const gop = try cg.defines.getOrPut(cg.gpa, identifier);
        if (gop.found_existing) {
            try exe.emit(.load_define, @intCast(gop.index), null);
        } else {
            try exe.emit(.load_define_checked, @intCast(gop.index), null);
        }
    }
}

fn genExpression(cg: *CodeGen, exe: *Executable, is_tail: bool) !void {
    switch (cg.tokenizer.token) {
        inline .@"#f", .@"#t" => |tag| {
            if (cg.flavor.isBefore(.funclang)) {
                try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
            }
            try exe.emitConstant(Value.from(tag == .@"#t"), null);
            cg.tokenizer.next();
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
        },
        .identifier => {
            if (cg.flavor.isBefore(.varlang)) {
                try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
            }
            try cg.genIdentifier(exe, cg.tokenizer.tokenSource());
            cg.tokenizer.next();
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
                        try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
                    }
                    cg.tokenizer.next();

                    const identifier_stack_len = cg.identifier_stack.items.len;
                    const shadow_stack_len = cg.shadow_stack.items.len;

                    _ = try cg.expectToken(.@"(");
                    while (cg.eatToken(.@"(") != null) {
                        const identifier = try cg.expectToken(.identifier);
                        try cg.genExpression(exe, false);
                        try cg.identifier_stack.append(cg.gpa, identifier);
                        _ = try cg.expectToken(.@")");
                    }
                    _ = try cg.expectToken(.@")");

                    var i: usize = cg.identifier_stack.items.len;
                    while (i > identifier_stack_len) {
                        i -= 1;
                        const identifier = cg.identifier_stack.items[i];
                        const gop = try exe.locals.getOrPut(cg.gpa, identifier);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = exe.allocLocal();
                        }
                        try exe.emit(.move_local, gop.value_ptr.*, null);
                        if (gop.found_existing or cg.defines.contains(identifier)) {
                            try cg.shadow_stack.append(cg.gpa, .{
                                .name = identifier,
                                .old_local = if (gop.found_existing) gop.value_ptr.* else null,
                            });
                        }
                    }
                    cg.identifier_stack.shrinkRetainingCapacity(identifier_stack_len);

                    try cg.genExpression(exe, is_tail);

                    for (cg.shadow_stack.items[shadow_stack_len..]) |shadow| {
                        if (shadow.old_local) |old_local| {
                            exe.locals.putAssumeCapacity(shadow.name, old_local);
                        } else {
                            std.debug.assert(exe.locals.remove(shadow.name));
                        }
                    }
                    cg.shadow_stack.shrinkRetainingCapacity(shadow_stack_len);
                    _ = try cg.expectToken(.@")");
                },
                .@"if" => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
                    }
                    const hint = cg.tokenizer.start;
                    cg.tokenizer.next();
                    try cg.genExpression(exe, false);
                    const deferred_jump_if_not = try exe.emitDeferred(.jump_if_not, hint);
                    try cg.genExpression(exe, is_tail);
                    const deferred_jump = try exe.emitDeferred(.jump, null);
                    deferred_jump_if_not.setOffset();
                    try cg.genExpression(exe, is_tail);
                    deferred_jump.setOffset();
                    _ = try cg.expectToken(.@")");
                },
                inline .@"+", .@"-", .@"*", .@"/", .@"<", .@">", .@"=" => |tag| binary: {
                    const hint = cg.tokenizer.start;

                    switch (tag) {
                        .@"<", .@">", .@"=" => {
                            if (cg.flavor.isBefore(.funclang)) {
                                try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
                            }
                        },
                        else => {},
                    }
                    cg.tokenizer.next();
                    try cg.genExpression(exe, false);
                    try cg.genExpression(exe, false);

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
                            try cg.genExpression(exe, false);
                            try exe.emit(instruction, {}, hint);
                        }
                        break :binary;
                    }

                    _ = try cg.expectToken(.@")");
                },
                .lambda => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
                    }
                    cg.tokenizer.next();

                    var exe2: Executable = .{
                        .cg = cg,
                        .arguments = 0,
                        .source = "unknown",
                        .parent = exe,
                    };
                    errdefer exe2.deinit();

                    _ = try cg.expectToken(.@"(");
                    while (cg.eatToken(.identifier)) |identifier| {
                        try exe2.locals.put(cg.gpa, identifier, exe2.allocLocal());
                        exe2.arguments += 1;
                    }
                    _ = try cg.expectToken(.@")");

                    try cg.genExpression(&exe2, true);

                    const end = cg.tokenizer.index;
                    _ = try cg.expectToken(.@")");

                    try exe2.emit(.@"return", {}, null);
                    exe2.source = cg.tokenizer.source[open_range.start..end];
                    try exe.emit(.push_lambda, @intCast(cg.lambdas.items.len), null);
                    try cg.lambdas.append(cg.gpa, exe2);
                },
                .identifier, .@"(" => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
                    }
                    const hint = cg.tokenizer.start;
                    try cg.genExpression(exe, false);

                    var argument_count: u16 = 0;
                    while (cg.eatToken(.@")") == null) {
                        try cg.genExpression(exe, false);
                        argument_count += 1;
                    }

                    if (is_tail) {
                        try exe.emit(.tail_call, argument_count, hint);
                    } else {
                        try exe.emit(.call, argument_count, hint);
                    }
                },
                .list => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
                    }
                    cg.tokenizer.next();
                    var item_count: u16 = 0;
                    while (cg.eatToken(.@")") == null) {
                        try cg.genExpression(exe, false);
                        item_count += 1;
                    }
                    try exe.emit(.push_list, item_count, null);
                },
                .cons => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
                    }
                    const hint = cg.tokenizer.start;
                    cg.tokenizer.next();
                    try cg.genExpression(exe, false);
                    try cg.genExpression(exe, false);
                    try exe.emit(.cons, {}, hint);
                    _ = try cg.expectToken(.@")");
                },
                .car => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
                    }
                    const hint = cg.tokenizer.start;
                    cg.tokenizer.next();
                    try cg.genExpression(exe, false);
                    try exe.emit(.car, {}, hint);
                    _ = try cg.expectToken(.@")");
                },
                .cdr => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
                    }
                    const hint = cg.tokenizer.start;
                    cg.tokenizer.next();
                    try cg.genExpression(exe, false);
                    try exe.emit(.cdr, {}, hint);
                    _ = try cg.expectToken(.@")");
                },
                .@"null?" => {
                    if (cg.flavor.isBefore(.funclang)) {
                        try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
                    }
                    const hint = cg.tokenizer.start;
                    cg.tokenizer.next();
                    try cg.genExpression(exe, false);
                    try exe.emit(.null, {}, hint);
                    _ = try cg.expectToken(.@")");
                },
                inline .ref, .free, .deref => |tag| {
                    if (cg.flavor.isBefore(.reflang)) {
                        try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
                    }
                    const hint = cg.tokenizer.start;
                    cg.tokenizer.next();
                    try cg.genExpression(exe, false);
                    try exe.emit(switch (tag) {
                        .ref => .ref,
                        .free => .free,
                        .deref => .deref,
                        else => @compileError("unreachable"),
                    }, {}, hint);
                    _ = try cg.expectToken(.@")");
                },
                .@"set!" => {
                    if (cg.flavor.isBefore(.reflang)) {
                        try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
                    }
                    // rhs is evaluated before lhs
                    const hint = cg.tokenizer.start;
                    cg.tokenizer.next();

                    const bytecode_len = exe.bytecode.items.len;
                    try cg.genExpression(exe, false);

                    const save_stack_len = cg.save_stack.items.len;
                    try cg.save_stack.appendSlice(cg.gpa, exe.bytecode.items[bytecode_len..]);
                    exe.bytecode.shrinkRetainingCapacity(bytecode_len);

                    try cg.genExpression(exe, false);

                    try exe.bytecode.appendSlice(cg.gpa, cg.save_stack.items[save_stack_len..]);
                    cg.save_stack.shrinkRetainingCapacity(save_stack_len);

                    try exe.emit(.set, {}, hint);
                    _ = try cg.expectToken(.@")");
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

fn genDefine(cg: *CodeGen, exe: *Executable) !void {
    // assumes "(define"
    const identifier = try cg.expectToken(.identifier);
    const gop = try cg.defines.getOrPut(cg.gpa, identifier);
    try cg.genExpression(exe, false);
    exe.locals.clearRetainingCapacity();
    try exe.emit(.move_define, @intCast(gop.index), null);
    _ = try cg.expectToken(.@")");
}

pub const Mode = enum(u8) {
    program,
    repl_like,
};

pub fn genProgram(cg: *CodeGen, mode: Mode) Error!Executable {
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
                try cg.fail(.{ .data = .unsupported, .source_range = cg.tokenizer.tokenRange() });
            }
            cg.tokenizer.next();

            try cg.genDefine(&exe);
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

        try cg.genExpression(&exe, false);
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
