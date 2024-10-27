const std = @import("std");

const CodeGen = @import("CodeGen.zig");
const Vm = @import("Vm.zig");

const Value = Vm.Value;

const Executable = @This();

cg: *CodeGen,
arguments: u32,
bytecode: std.ArrayListUnmanaged(u8) = .empty,
// TODO: Optimize representation.
source_mapping: std.ArrayListUnmanaged(u32) = .empty,
local_count: u16 = 0,
locals: std.StringHashMapUnmanaged(u16) = .empty,
captures: std.ArrayListUnmanaged(u16) = .empty,
source: []const u8,
parent: ?*Executable = null,

pub fn deinit(exe: *Executable) void {
    exe.bytecode.deinit(exe.cg.gpa);
    exe.source_mapping.deinit(exe.cg.gpa);
    exe.locals.deinit(exe.cg.gpa);
    exe.captures.deinit(exe.cg.gpa);
}

pub fn allocLocal(exe: *Executable) u16 {
    defer exe.local_count += 1;
    return exe.local_count;
}

pub const Instruction = union(enum(u8)) {
    push_constant: u16,
    push_constant_u8: u8,
    addition,
    subtraction,
    multiplication,
    division,
    less,
    greater,
    equal,
    move_local: u16,
    move_local_u8: u8,
    move_define: u16,
    move_define_u8: u8,
    move_capture: struct {
        local: u16,
        capture: u16,
    },
    load_local: u16,
    load_local_u8: u8,
    load_define: u16,
    load_define_u8: u16,
    load_define_checked: u16,
    load_define_checked_u8: u16,
    load_capture: u16,
    load_capture_u8: u8,
    jump: u16,
    jump_if_not: u16,
    push_lambda: u16,
    push_list: u16,
    push_list_u8: u8,
    cons,
    car,
    cdr,
    null,
    call: u16,
    call_u8: u8,
    tail_call: u16,
    tail_call_u8: u8,
    ref,
    free,
    deref,
    set,
    @"return",
    push_result,

    pub const Tag = std.meta.Tag(Instruction);
};

pub fn emit(
    exe: *Executable,
    comptime tag: Instruction.Tag,
    payload: std.meta.TagPayload(Instruction, tag),
    source_hint: ?usize,
) !void {
    const Payload = @TypeOf(payload);

    if (tag == .load_local and payload <= std.math.maxInt(u8)) {
        return exe.emit(.load_local_u8, @intCast(payload), source_hint);
    } else if (tag == .load_define and payload <= std.math.maxInt(u8)) {
        return exe.emit(.load_define_u8, @intCast(payload), source_hint);
    } else if (tag == .load_define_checked and payload <= std.math.maxInt(u8)) {
        return exe.emit(.load_define_checked_u8, @intCast(payload), source_hint);
    } else if (tag == .load_capture and payload <= std.math.maxInt(u8)) {
        return exe.emit(.load_capture_u8, @intCast(payload), source_hint);
    } else if (tag == .move_local and payload <= std.math.maxInt(u8)) {
        return exe.emit(.move_local_u8, @intCast(payload), source_hint);
    } else if (tag == .move_define and payload <= std.math.maxInt(u8)) {
        return exe.emit(.move_define_u8, @intCast(payload), source_hint);
    } else if (tag == .push_list and payload <= std.math.maxInt(u8)) {
        return exe.emit(.push_list_u8, @intCast(payload), source_hint);
    } else if (tag == .call and payload <= std.math.maxInt(u8)) {
        return exe.emit(.call_u8, @intCast(payload), source_hint);
    } else if (tag == .tail_call and payload <= std.math.maxInt(u8)) {
        return exe.emit(.tail_call_u8, @intCast(payload), source_hint);
    }

    try exe.source_mapping.appendNTimes(exe.cg.gpa, @intCast(source_hint orelse exe.cg.tokenizer.start), 1 + @sizeOf(Payload));
    try exe.bytecode.ensureUnusedCapacity(exe.cg.gpa, 1 + @sizeOf(Payload));
    exe.bytecode.appendAssumeCapacity(@intFromEnum(tag));
    exe.bytecode.appendSliceAssumeCapacity(&std.mem.toBytes(payload));
}

fn DeferredEmit(comptime T: type) type {
    return struct {
        exe: *Executable,
        index: usize,

        pub fn set(self: @This(), value: T) void {
            self.exe.bytecode.items[self.index..][0..@sizeOf(T)].* = std.mem.toBytes(value);
        }

        pub fn setOffset(self: @This()) void {
            self.set(@intCast(self.exe.bytecode.items.len - self.index - @sizeOf(T)));
        }
    };
}

pub fn emitDeferred(
    exe: *Executable,
    comptime tag: Instruction.Tag,
    source_hint: ?usize,
) !DeferredEmit(std.meta.TagPayload(Instruction, tag)) {
    try exe.emit(tag, undefined, source_hint);
    return .{
        .exe = exe,
        .index = exe.bytecode.items.len - @sizeOf(std.meta.TagPayload(Instruction, tag)),
    };
}

pub fn emitConstant(
    exe: *Executable,
    value: Value,
    source_hint: ?usize,
) !void {
    const index = exe.cg.constants.items.len;
    try exe.cg.constants.append(exe.cg.gpa, value);
    if (index <= std.math.maxInt(u8)) {
        try exe.emit(.push_constant_u8, @intCast(index), source_hint);
    } else {
        try exe.emit(.push_constant, @intCast(index), source_hint);
    }
}
