//! Bytecode virtual machine.

const std = @import("std");

const build_options = @import("build_options");

const CodeGen = @import("CodeGen.zig");
const Executable = @import("Executable.zig");
const Heap = @import("Heap.zig");

const Instruction = Executable.Instruction;
const Lambda = Heap.Lambda;
const List = Heap.List;
const Object = Heap.Object;
const Pair = Heap.Pair;
const Reference = Heap.Reference;

const Vm = @This();

gpa: std.mem.Allocator,
heap: Heap,
constants: []const Value,
lambdas: []const Executable,
stack: std.ArrayListUnmanaged(Value),
captures_start: usize,
results: usize,
results_pushed: usize = 0,
call_stack: std.ArrayListUnmanaged(StackInfo) = .empty,
cur: StackInfo = undefined,
exception: ?[]u8 = null,
stack_trace: std.ArrayListUnmanaged(u32) = .empty, // source indexes

pub const StackInfo = struct {
    exe: *const Executable,
    index: usize,
    stack_start: usize,
    lambda: ?*Lambda,
};

pub fn init(cg: CodeGen) !Vm {
    const defines_count = @max(cg.defines.count(), cg.define_types.items.len);
    var vm: Vm = .{
        .gpa = cg.gpa,
        .heap = try Heap.init(cg.gpa),
        .constants = cg.constants.items,
        .lambdas = cg.lambdas.items,
        .stack = .empty,
        .captures_start = defines_count,
        .results = cg.results,
    };
    try vm.resize(defines_count + cg.captures_count);
    return vm;
}

pub fn deinit(vm: *Vm) void {
    vm.heap.deinit();
    vm.stack.deinit(vm.gpa);
    vm.call_stack.deinit(vm.gpa);
    if (vm.exception) |exception| {
        vm.gpa.free(exception);
    }
    vm.stack_trace.deinit(vm.gpa);
}

fn resize(vm: *Vm, len: usize) !void {
    const old_len = vm.stack.items.len;
    try vm.stack.resize(vm.gpa, len);
    if (vm.stack.items.len > old_len) {
        // stop the gc from reading undefined memory
        @memset(vm.stack.items[old_len..], .empty);
    }
}

pub const Error = std.mem.Allocator.Error || error{ExceptionThrown};

/// Adapted from Kiesel's implementation.
pub const Value = enum(u64) {
    const nan_mask: u64 = 0x7ff8000000000000;
    const payload_len = 48;

    boolean_false = initBits(.boolean, false),
    boolean_true = initBits(.boolean, true),
    number_nan = nan_mask,
    empty = initBits(.empty, {}),
    _,

    const Tag = enum(u3) {
        number_f64 = 0,
        number_i32,
        boolean,
        lambda,
        list,
        pair,
        reference,
        empty,

        fn Payload(comptime tag: Tag) type {
            return switch (tag) {
                .number_f64 => f64,
                .number_i32 => i32,
                .boolean => bool,
                .lambda => *Lambda,
                .list => *List,
                .pair => *Pair,
                .reference => *Reference,
                .empty => void,
            };
        }
    };

    fn initBits(comptime tag: Tag, payload: tag.Payload()) u64 {
        const T = @TypeOf(payload);
        const tag_bits: u64 = @as(u64, @intFromEnum(tag)) << payload_len;
        if (T == f64) {
            return @bitCast(payload);
        } else if (@typeInfo(T) == .pointer) {
            const ptr_bits = @intFromPtr(payload);
            return nan_mask | tag_bits | ptr_bits;
        } else if (@sizeOf(T) != 0) {
            // @bitCast() doesn't work on void
            const payload_bits: std.meta.Int(.unsigned, @bitSizeOf(T)) = @bitCast(payload);
            return nan_mask | tag_bits | payload_bits;
        } else {
            return nan_mask | tag_bits;
        }
    }

    pub fn init(comptime tag: Tag, payload: tag.Payload()) Value {
        return @enumFromInt(initBits(tag, payload));
    }

    pub fn getTag(value: Value) Tag {
        const bits: u64 = @intFromEnum(value);
        const tag_bits: u3 = @truncate(bits >> payload_len);
        return if (bits & nan_mask == nan_mask) @enumFromInt(tag_bits) else .number_f64;
    }

    pub fn getPayload(value: Value, comptime tag: Tag) tag.Payload() {
        std.debug.assert(value.getTag() == tag);
        const T = tag.Payload();
        const bits: u64 = @intFromEnum(value);
        if (@typeInfo(T) == .pointer) {
            const ptr_bits: if (@sizeOf(T) >= 8) u48 else usize = @truncate(bits);
            return @ptrFromInt(ptr_bits);
        } else {
            const payload_bits: std.meta.Int(.unsigned, @bitSizeOf(T)) = @truncate(bits);
            return @bitCast(payload_bits);
        }
    }

    pub fn getPayloadBits(value: Value) u48 {
        return @truncate(@intFromEnum(value));
    }

    pub fn format(value: Value, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (value.getTag()) {
            .boolean => try writer.writeAll(if (value.getPayload(.boolean)) "#t" else "#f"),
            .number_i32 => try writer.print(if (build_options.java_compat) "{}.0" else "{}", .{value.getPayload(.number_i32)}),
            .number_f64 => try writer.print("{d}", .{value.getPayload(.number_f64)}),
            .lambda => {
                var last_whitespace: bool = true;
                for (value.getPayload(.lambda).executable.source) |c| {
                    if (std.ascii.isWhitespace(c)) {
                        if (!last_whitespace) {
                            try writer.writeByte(' ');
                        }
                        last_whitespace = true;
                    } else {
                        try writer.writeByte(c);
                        last_whitespace = false;
                    }
                }
            },
            .list => {
                var cur = value.getPayload(.list);
                try writer.writeAll("(");
                var i: usize = 0;
                while (cur != List.empty) {
                    if (i != 0) {
                        try writer.writeAll(" ");
                    }
                    i += 1;
                    try writer.print("{}", .{cur.value});
                    cur = cur.next;
                }
                try writer.writeAll(")");
            },
            .pair => {
                const pair = value.getPayload(.pair);
                try writer.print("({} {})", .{ pair.left, pair.right });
            },
            .reference => {
                const reference = value.getPayload(.reference);
                if (reference.is_free) {
                    try writer.writeAll("<reference null>");
                } else {
                    try writer.print("<reference {x}>", .{@intFromPtr(reference)});
                }
            },
            .empty => try writer.writeAll(if (build_options.java_compat) "" else "<empty>"),
        }
    }

    pub fn formatPretty(value: Value, config: std.io.tty.Config, writer: anytype) !void {
        switch (value.getTag()) {
            .boolean => {
                try config.setColor(writer, .bright_blue);
                try writer.print("{}", .{value});
                try config.setColor(writer, .reset);
            },
            .number_i32, .number_f64 => {
                try config.setColor(writer, .bright_green);
                try writer.print("{}", .{value});
                try config.setColor(writer, .reset);
            },
            .lambda => try writer.print("{}", .{value}),
            .list => {
                var cur = value.getPayload(.list);
                try writer.writeAll("(");
                var i: usize = 0;
                while (cur != List.empty) {
                    if (i != 0) {
                        try writer.writeAll(" ");
                    }
                    i += 1;
                    try cur.value.formatPretty(config, writer);
                    cur = cur.next;
                }
                try writer.writeAll(")");
            },
            .pair => {
                const pair = value.getPayload(.pair);
                try writer.writeByte('(');
                try pair.left.formatPretty(config, writer);
                try writer.writeByte(' ');
                try pair.right.formatPretty(config, writer);
                try writer.writeByte(')');
            },
            .reference => {
                const reference = value.getPayload(.reference);
                try writer.writeByte('<');
                try config.setColor(writer, .yellow);
                try writer.writeAll("reference ");
                try config.setColor(writer, .reset);
                if (reference.is_free) {
                    try config.setColor(writer, .bright_blue);
                    try writer.writeAll("null");
                } else {
                    try config.setColor(writer, .bright_green);
                    try writer.print("0x{x}", .{@intFromPtr(reference)});
                }
                try config.setColor(writer, .reset);
                try writer.writeByte('>');
            },
            .empty => {
                if (!build_options.java_compat) {
                    try writer.writeByte('<');
                    try config.setColor(writer, .yellow);
                    try writer.writeAll("empty");
                    try config.setColor(writer, .reset);
                    try writer.writeByte('>');
                }
            },
        }
    }

    pub fn from(value: anytype) Value {
        switch (@TypeOf(value)) {
            bool => return if (value) Value.boolean_true else .boolean_false,
            i32, comptime_int => return Value.init(.number_i32, value),
            f64, comptime_float => return if (!std.math.isNan(value)) Value.init(.number_f64, value) else .number_nan,
            else => @compileError("invalid type"),
        }
    }

    pub fn asNumberF64(value: Value) ?f64 {
        return switch (value.getTag()) {
            .number_i32 => @floatFromInt(value.getPayload(.number_i32)),
            .number_f64 => value.getPayload(.number_f64),
            else => null,
        };
    }
};

pub fn throwException(vm: *Vm, comptime fmt: []const u8, args: anytype) Error!noreturn {
    if (vm.exception) |exception| {
        vm.gpa.free(exception);
    }
    vm.exception = try std.fmt.allocPrint(vm.gpa, fmt, args);
    return error.ExceptionThrown;
}

fn applyBinaryOperator(vm: *Vm, comptime operator: Instruction.Tag, left: Value, right: Value) !Value {
    fast: {
        if (left.getTag() == .number_i32 and right.getTag() == .number_i32) {
            const left_i32 = left.getPayload(.number_i32);
            const right_i32 = right.getPayload(.number_i32);
            return Value.from(switch (operator) {
                .addition => std.math.add(i32, left_i32, right_i32) catch break :fast,
                .subtraction => std.math.sub(i32, left_i32, right_i32) catch break :fast,
                .multiplication => std.math.mul(i32, left_i32, right_i32) catch break :fast,
                .division => std.math.divExact(i32, left_i32, right_i32) catch break :fast,
                .less => left_i32 < right_i32,
                .greater => left_i32 > right_i32,
                .equal => left_i32 == right_i32,
                else => @compileError("unreachable"),
            });
        }
    }

    const left_f64 = left.asNumberF64() orelse try vm.throwException("attempt to coerce '{}' to number", .{left});
    const right_f64 = right.asNumberF64() orelse try vm.throwException("attempt to coerce '{}' to number", .{right});
    return Value.from(switch (operator) {
        .addition => left_f64 + right_f64,
        .subtraction => left_f64 - right_f64,
        .multiplication => left_f64 * right_f64,
        .division => left_f64 / right_f64,
        .less => left_f64 < right_f64,
        .greater => left_f64 > right_f64,
        .equal => left_f64 == right_f64,
        else => @compileError("unreachable"),
    });
}

pub fn execute(vm: *Vm, program: *const Executable) std.mem.Allocator.Error![]Value {
    vm.cur = .{
        .exe = program,
        .index = 0,
        .stack_start = vm.stack.items.len,
        .lambda = null,
    };
    const start_results = vm.cur.stack_start + vm.cur.exe.local_count;
    return vm.executeInner(&vm.cur, program) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ExceptionThrown => {
            try vm.stack_trace.ensureUnusedCapacity(vm.gpa, 1 + vm.call_stack.items.len);
            vm.stack_trace.appendAssumeCapacity(vm.cur.exe.source_mapping.items[vm.cur.index -| 1]);
            while (vm.call_stack.popOrNull()) |entry| {
                vm.stack_trace.appendAssumeCapacity(entry.exe.source_mapping.items[entry.index -| 1]);
            }
            return vm.stack.items[start_results..][0..vm.results_pushed];
        },
    };
}

fn executeInner(vm: *Vm, cur: *StackInfo, program: *const Executable) ![]Value {
    try vm.resize(vm.stack.items.len + program.local_count);
    insn: switch (@as(Instruction.Tag, @enumFromInt(cur.exe.bytecode.items[cur.index]))) {
        inline else => |tag| {
            cur.index += 1;
            @setEvalBranchQuota(10_000);
            const Payload = std.meta.TagPayload(Instruction, tag);
            const payload_ptr: *align(1) const Payload = @ptrCast(cur.exe.bytecode.items[cur.index..][0..@sizeOf(Payload)]);
            const payload = payload_ptr.*;
            cur.index += @sizeOf(Payload);

            switch (tag) {
                .@"return" => {
                    if (vm.call_stack.popOrNull()) |next| {
                        const result = vm.stack.pop();
                        vm.stack.items.len -= cur.exe.local_count;
                        std.debug.assert(vm.stack.items.len == cur.stack_start);
                        vm.stack.appendAssumeCapacity(result);
                        cur.* = next;
                    } else {
                        break :insn;
                    }
                },
                .push_constant, .push_constant_u8 => {
                    try vm.stack.append(vm.gpa, vm.constants[payload]);
                },
                .addition, .subtraction, .multiplication, .division, .less, .greater, .equal => {
                    const right = vm.stack.pop();
                    const left = vm.stack.pop();
                    vm.stack.appendAssumeCapacity(try vm.applyBinaryOperator(tag, left, right));
                },
                .load_local, .load_local_u8 => {
                    try vm.stack.append(vm.gpa, vm.stack.items[cur.stack_start + payload]);
                },
                .load_define_checked, .load_define_checked_u8 => {
                    const value = vm.stack.items[payload];
                    if (value == .empty) {
                        try vm.throwException("variable is not defined", .{});
                    }
                    try vm.stack.append(vm.gpa, value);
                },
                .load_define, .load_define_u8 => {
                    try vm.stack.append(vm.gpa, vm.stack.items[payload]);
                },
                .load_capture, .load_capture_u8 => {
                    std.debug.assert(payload < cur.exe.captures.items.len);
                    try vm.stack.append(vm.gpa, cur.lambda.?.captures.?[payload]);
                },
                .move_local, .move_local_u8 => {
                    vm.stack.items[cur.stack_start + payload] = vm.stack.pop();
                },
                .move_define, .move_define_u8 => {
                    vm.stack.items[payload] = vm.stack.pop();
                },
                .move_capture, .move_capture_u8 => {
                    vm.stack.items[vm.captures_start + payload.capture] = vm.stack.items[cur.stack_start + payload.local];
                },
                .jump => {
                    cur.index += payload;
                },
                .jump_if_not => {
                    const condition = vm.stack.pop();
                    if (condition == .boolean_false) {
                        cur.index += payload;
                    } else if (condition != .boolean_true) {
                        try vm.throwException("condition is not a boolean", .{});
                    }
                },
                .push_lambda => {
                    const exe = &vm.lambdas[payload];
                    if (exe.captures.items.len != 0) {
                        const lambda = try vm.heap.createObject(.lambda, .{
                            .executable = exe,
                            .captures = null,
                        });
                        const captures = try vm.gpa.alloc(Value, exe.captures.items.len);
                        for (captures, exe.captures.items) |*value, capture| {
                            value.* = vm.stack.items[vm.captures_start + capture];
                        }
                        lambda.captures = captures.ptr;
                        vm.stack.appendAssumeCapacity(Value.init(.lambda, lambda));
                    } else {
                        const lambda = try vm.heap.createObject(.lambda, .{
                            .executable = exe,
                            .captures = null,
                        });
                        try vm.stack.append(vm.gpa, Value.init(.lambda, lambda));
                    }
                },
                .push_list, .push_list_u8 => {
                    var last = List.empty;
                    var i = vm.stack.items.len;
                    while (i > vm.stack.items.len - payload) {
                        i -= 1;
                        last = try vm.heap.createObject(.list, .{
                            .value = vm.stack.items[i],
                            .next = last,
                        });
                    }
                    vm.stack.items.len -= payload;
                    try vm.stack.append(vm.gpa, Value.init(.list, last));
                },
                .cons => {
                    const right = vm.stack.pop();
                    const left = vm.stack.pop();

                    if (right.getTag() == .list) {
                        const list = try vm.heap.createObject(.list, .{
                            .value = left,
                            .next = right.getPayload(.list),
                        });
                        vm.stack.appendAssumeCapacity(Value.init(.list, list));
                    } else {
                        const pair = try vm.heap.createObject(.pair, .{
                            .left = left,
                            .right = right,
                        });
                        vm.stack.appendAssumeCapacity(Value.init(.pair, pair));
                    }
                },
                .car => {
                    const value = vm.stack.pop();
                    switch (value.getTag()) {
                        .list => {
                            const list = value.getPayload(.list);
                            vm.stack.appendAssumeCapacity(list.value);
                        },
                        .pair => {
                            const pair = value.getPayload(.pair);
                            vm.stack.appendAssumeCapacity(pair.left);
                        },
                        else => try vm.throwException("invalid car on non-list and non-pair value", .{}),
                    }
                },
                .cdr => {
                    const value = vm.stack.pop();
                    switch (value.getTag()) {
                        .list => {
                            const list = value.getPayload(.list);
                            if (list == List.empty) {
                                try vm.throwException("invalid cdr on empty list", .{});
                            }
                            vm.stack.appendAssumeCapacity(Value.init(.list, list.next));
                        },
                        .pair => {
                            const pair = value.getPayload(.pair);
                            vm.stack.appendAssumeCapacity(pair.right);
                        },
                        else => try vm.throwException("invalid cdr on non-list and non-pair value", .{}),
                    }
                },
                .null => {
                    const value = vm.stack.pop();
                    const is_null = value.getTag() == .list and value.getPayload(.list) == List.empty;
                    vm.stack.appendAssumeCapacity(Value.init(.boolean, is_null));
                },
                .ref => {
                    const value = vm.stack.pop();
                    const reference = try vm.heap.createObject(.reference, .{
                        .value = value,
                    });
                    vm.stack.appendAssumeCapacity(Value.init(.reference, reference));
                },
                .free => {
                    const reference_value = vm.stack.pop();
                    if (reference_value.getTag() != .reference) {
                        try vm.throwException("invalid free on non-reference value", .{});
                    }

                    const reference = reference_value.getPayload(.reference);
                    if (reference.is_free) {
                        try vm.throwException("double-free on reference", .{});
                    }
                    reference.is_free = true;
                    vm.stack.appendAssumeCapacity(.empty);
                },
                .deref => {
                    const reference_value = vm.stack.pop();
                    if (reference_value.getTag() != .reference) {
                        try vm.throwException("invalid deref on non-reference value", .{});
                    }

                    const reference = reference_value.getPayload(.reference);
                    if (reference.is_free) {
                        try vm.throwException("invalid deref on free reference", .{});
                    }
                    vm.stack.appendAssumeCapacity(reference.value);
                },
                .set => {
                    const reference_value = vm.stack.pop();
                    const value = vm.stack.pop();
                    if (reference_value.getTag() != .reference) {
                        try vm.throwException("invalid set on non-reference value", .{});
                    }

                    const reference = reference_value.getPayload(.reference);
                    if (reference.is_free) {
                        try vm.throwException("invalid set on free reference", .{});
                    }
                    reference.value = value;
                    vm.stack.appendAssumeCapacity(value);
                },
                .call, .call_u8, .tail_call, .tail_call_u8 => call: {
                    const callee = vm.stack.items[vm.stack.items.len - 1 - payload];
                    if (callee.getTag() != .lambda) {
                        try vm.throwException("callee is not a function", .{});
                    }

                    const lambda = callee.getPayload(.lambda);
                    if (payload != lambda.executable.arguments) {
                        try vm.throwException("expected {} arguments, got {}", .{ lambda.executable.arguments, payload });
                    }

                    if (tag == .tail_call or tag == .tail_call_u8) {
                        if (lambda.executable == cur.exe) {
                            @memcpy(
                                vm.stack.items[cur.stack_start..][0..payload],
                                vm.stack.items[vm.stack.items.len - payload ..],
                            );
                            vm.stack.items.len -= payload + 1;
                            cur.index = 0;
                            cur.lambda = lambda;
                            break :call;
                        }

                        if (payload != 0) {
                            std.mem.copyForwards(
                                Value,
                                vm.stack.items[cur.stack_start..][0..payload],
                                vm.stack.items[vm.stack.items.len - payload ..],
                            );
                        }
                        try vm.resize(cur.stack_start + lambda.executable.local_count);
                        cur.* = .{
                            .exe = lambda.executable,
                            .index = 0,
                            .stack_start = vm.stack.items.len - lambda.executable.local_count,
                            .lambda = lambda,
                        };
                        break :call;
                    }

                    try vm.call_stack.append(vm.gpa, cur.*);
                    cur.* = .{
                        .exe = lambda.executable,
                        .index = 0,
                        .stack_start = vm.stack.items.len - 1 - payload,
                        .lambda = lambda,
                    };

                    try vm.resize(vm.stack.items.len + cur.exe.local_count - payload);
                    std.mem.copyForwards(
                        Value,
                        vm.stack.items[cur.stack_start..][0..payload],
                        vm.stack.items[cur.stack_start + 1 ..][0..payload],
                    );
                    _ = vm.stack.pop();
                },
                .push_result => {
                    vm.results_pushed += 1;
                },
            }
            continue :insn @enumFromInt(cur.exe.bytecode.items[cur.index]);
        },
    }
    std.debug.assert(vm.stack.items.len == cur.stack_start + program.local_count + vm.results);
    return vm.stack.items[vm.stack.items.len - vm.results ..];
}
