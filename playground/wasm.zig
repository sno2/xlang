const std = @import("std");
const builtin = @import("builtin");

const xlang = @import("xlang");

const CodeGen = xlang.CodeGen;
const Executable = xlang.Executable;
const Vm = xlang.Vm;

const gpa = std.heap.wasm_allocator;

var source: std.ArrayListUnmanaged(u8) = .empty;
export fn allocSource(len: usize) [*]u8 {
    source.resize(gpa, len + 1) catch unreachable;
    source.items[len] = 0;
    return source.items.ptr;
}

const CgInfo = extern struct {
    error_ptr: [*]u8,
    error_len: usize,
    start: usize,
    end: usize,
};
var cg_info: CgInfo = undefined;

var cg_before = false;
var cg: CodeGen = undefined;
var exe_before = false;
var exe: Executable = undefined;
var error_message: std.ArrayListUnmanaged(u8) = .empty;

export fn codeGen() ?*CgInfo {
    if (cg_before) {
        cg.deinit();
        error_message.clearRetainingCapacity();
    }
    cg_before = true;

    cg = CodeGen.init(gpa, source.items[0 .. source.items.len - 1 :0]);
    exe = cg.genProgram() catch |e| switch (e) {
        error.OutOfMemory => unreachable,
        error.InvalidSyntax => {
            exe_before = false;
            const config: std.io.tty.Config = .escape_codes;
            const writer = error_message.writer(cg.gpa);
            config.setColor(writer, .reset) catch unreachable;
            config.setColor(writer, .bold) catch unreachable;
            const line = std.mem.count(u8, source.items[0..cg.error_info.?.source_range.start], &.{'\n'}) + 1;
            const line_start = if (std.mem.lastIndexOfScalar(u8, source.items[0..cg.error_info.?.source_range.start], '\n')) |nl_index| nl_index + 1 else 0;
            writer.print("main.x:{}:{}: ", .{ line, cg.error_info.?.source_range.start - line_start + 1 }) catch unreachable;
            config.setColor(writer, .reset) catch unreachable;
            cg.formatError(config, writer) catch unreachable;
            const line_end = if (std.mem.indexOfScalarPos(u8, source.items, cg.error_info.?.source_range.end, '\n')) |nl_index| nl_index else source.items.len;
            writer.print("\r\n{s}\r\n", .{source.items[line_start..line_end]}) catch unreachable;
            writer.writeByteNTimes(' ', cg.error_info.?.source_range.start - line_start) catch unreachable;
            config.setColor(writer, .bold) catch unreachable;
            config.setColor(writer, .green) catch unreachable;
            writer.writeByte('^') catch unreachable;
            writer.writeByteNTimes('~', cg.error_info.?.source_range.end - cg.error_info.?.source_range.start -| 1) catch unreachable;
            writer.writeAll("\r\n") catch unreachable;
            config.setColor(writer, .reset) catch unreachable;
            cg_info = .{
                .error_ptr = error_message.items.ptr,
                .error_len = error_message.items.len,
                .start = cg.tokenizer.start,
                .end = cg.tokenizer.index,
            };
            return &cg_info;
        },
    };
    exe_before = true;
    return null;
}

const ExecutionInfo = extern struct {
    failed: bool align(@sizeOf(usize)),
    message_ptr: [*]const u8,
    message_len: usize,
    start: isize,
    end: isize,
};
var execution_info: ExecutionInfo = undefined;
var vm: Vm = undefined;
var vm_ran: bool = false;
var stdout: std.ArrayListUnmanaged(u8) = .empty;

export fn execute() *ExecutionInfo {
    return executeFallible() catch {
        const message = "error: Out of memory";
        execution_info = .{
            .failed = true,
            .message_ptr = message,
            .message_len = message.len,
            .start = -1,
            .end = -1,
        };
        return &execution_info;
    };
}

fn executeFallible() !*ExecutionInfo {
    std.debug.assert(cg_before);

    if (!exe_before) {
        execution_info = .{
            .failed = true,
            .message_ptr = error_message.items.ptr,
            .message_len = error_message.items.len,
            .start = -1,
            .end = -1,
        };
        return &execution_info;
    }

    if (vm_ran) {
        vm.deinit();
        stdout.clearRetainingCapacity();
    }
    vm_ran = true;

    vm = try Vm.init(cg);
    const result = vm.execute(&exe) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ExceptionThrown => {
            error_message.clearRetainingCapacity();
            const writer = error_message.writer(gpa);
            const config: std.io.tty.Config = .escape_codes;
            try config.setColor(writer, .bold);
            try config.setColor(writer, .red);
            try writer.writeAll("error: ");
            try config.setColor(writer, .reset);
            try config.setColor(writer, .bold);
            try writer.print("{s}\r\n", .{vm.exception.?});
            try config.setColor(writer, .reset);
            var start: isize = undefined;
            var end: isize = undefined;
            for (vm.stack_trace.items, 0..) |index, i| {
                const is_lambda = i != vm.stack_trace.items.len - 1;
                var tokenizer: xlang.Tokenizer = .{ .source = source.items[0 .. source.items.len - 1 :0], .index = index };
                tokenizer.next();
                if (tokenizer.token == .@"(") {
                    var open: usize = 1;
                    while (open > 0) {
                        tokenizer.next();
                        switch (tokenizer.token) {
                            .@"(" => open += 1,
                            .@")" => open -= 1,
                            else => {},
                        }
                    }
                }
                start = @intCast(tokenizer.start);
                end = @intCast(tokenizer.index);
                const line = std.mem.count(u8, source.items[0..tokenizer.start], &.{'\n'}) + 1;
                const line_start = if (std.mem.lastIndexOfScalar(u8, source.items[0..index], '\n')) |nl_index| nl_index + 1 else 0;
                try config.setColor(writer, .bold);
                try writer.print("main.x:{}:{}", .{ line, index - line_start + 1 });
                try config.setColor(writer, .reset);
                try writer.writeAll(if (is_lambda) " in lambda:\r\n" else " in main:\r\n");
                const line_end = if (std.mem.indexOfScalarPos(u8, source.items, tokenizer.index, '\n')) |nl_index| nl_index else source.items.len;
                try writer.print("{s}\r\n", .{source.items[line_start..line_end]});
                try writer.writeByteNTimes(' ', index - line_start);
                try config.setColor(writer, .bold);
                try config.setColor(writer, .green);
                try writer.writeByte('^');
                try writer.writeByteNTimes('~', tokenizer.index - index -| 1);
                try writer.writeAll("\r\n");
                try config.setColor(writer, .reset);
            }
            execution_info = .{
                .failed = true,
                .message_ptr = error_message.items.ptr,
                .message_len = error_message.items.len,
                .start = start,
                .end = end,
            };
            return &execution_info;
        },
    };

    try stdout.writer(gpa).print("{}\n", .{result});

    execution_info = .{
        .failed = false,
        .message_ptr = stdout.items.ptr,
        .message_len = stdout.items.len,
        .start = undefined,
        .end = undefined,
    };
    return &execution_info;
}
