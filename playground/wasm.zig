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

var cg: CodeGen = CodeGen.init(gpa, undefined);
var maybe_exe: ?Executable = null;
var output: std.ArrayListUnmanaged(u8) = .empty;

export fn codeGen(is_program: bool) ?*CgInfo {
    output.clearRetainingCapacity();
    cg.reset(source.items[0 .. source.items.len - 1 :0]);

    if (maybe_exe) |*exe| {
        exe.deinit();
        maybe_exe = null;
    }

    maybe_exe = cg.genProgram(if (is_program) .program else .repl_like) catch |e| switch (e) {
        error.OutOfMemory => unreachable,
        error.InvalidSyntax => {
            const config: std.io.tty.Config = .escape_codes;
            const writer = output.writer(cg.gpa);
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
                .error_ptr = output.items.ptr,
                .error_len = output.items.len,
                .start = cg.tokenizer.start,
                .end = cg.tokenizer.index,
            };
            return &cg_info;
        },
    };
    return null;
}

const ExecutionInfo = extern struct {
    output_ptr: [*]const u8,
    output_len: usize,
    output_mappings_ptr: [*]OutputMappings,
    output_mappings_len: usize,
    exception_start: isize = -1,
    exception_end: usize = undefined,
    start: usize = undefined,
    end: usize = undefined,
};
var execution_info: ExecutionInfo = undefined;
var output_mappings: std.ArrayListUnmanaged(OutputMappings) = .empty;
var vm: Vm = undefined;
var vm_ran: bool = false;

const OutputMappings = extern struct {
    start: usize,
    end: usize,
    index: usize,

    comptime {
        if (@sizeOf(@This()) != @sizeOf(usize) * 3) {
            @compileError("invalid");
        }
    }
};

export fn execute() *ExecutionInfo {
    execution_info = executeFallible() catch blk: {
        const message = "error: Out of memory";
        break :blk .{
            .output_ptr = message,
            .output_len = message.len,
            .output_mappings_ptr = output_mappings.items.ptr,
            .output_mappings_len = 0,
        };
    };
    return &execution_info;
}

fn executeFallible() !ExecutionInfo {
    const exe = maybe_exe orelse return .{
        .output_ptr = output.items.ptr,
        .output_len = output.items.len,
        .output_mappings_ptr = output_mappings.items.ptr,
        .output_mappings_len = 0,
        .exception_start = 0,
        .exception_end = output.items.len,
        .start = @intCast(cg_info.start),
        .end = @intCast(cg_info.end),
    };

    if (vm_ran) {
        vm.deinit();
        output.clearRetainingCapacity();
        output_mappings.clearRetainingCapacity();
    }
    vm_ran = true;

    vm = try Vm.init(cg);
    const results = try vm.execute(&exe);

    for (results, cg.result_endings.items[0..results.len]) |result, index| {
        const start = output.items.len;
        try result.formatPretty(.escape_codes, output.writer(gpa));
        try output_mappings.append(gpa, .{
            .start = start,
            .end = output.items.len,
            .index = index,
        });
        try output.appendSlice(gpa, "\r\n");
    }

    if (vm.exception) |exception| {
        const writer = output.writer(gpa);
        const config: std.io.tty.Config = .escape_codes;
        try config.setColor(writer, .bold);
        try config.setColor(writer, .red);
        try writer.writeAll("error: ");
        try config.setColor(writer, .reset);
        try config.setColor(writer, .bold);
        const exception_start = output.items.len;
        try writer.print("{s}\r\n", .{exception});
        const exception_end = output.items.len;
        try config.setColor(writer, .reset);
        var start: ?usize = null;
        var end: usize = undefined;
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
            if (start == null) {
                start = tokenizer.start;
                end = tokenizer.index;
            }
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
        return .{
            .output_ptr = output.items.ptr,
            .output_len = output.items.len,
            .output_mappings_ptr = output_mappings.items.ptr,
            .output_mappings_len = output_mappings.items.len,
            .exception_start = @intCast(exception_start),
            .exception_end = exception_end,
            .start = start.?,
            .end = end,
        };
    }

    return .{
        .output_ptr = output.items.ptr,
        .output_len = output.items.len,
        .output_mappings_ptr = output_mappings.items.ptr,
        .output_mappings_len = output_mappings.items.len,
    };
}
