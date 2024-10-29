const std = @import("std");

const xlang = @import("xlang");

const CodeGen = xlang.CodeGen;
const Vm = xlang.Vm;

const extension_map = std.StaticStringMap(CodeGen.Flavor).initComptime(.{
    .{ ".al", .arithlang },
    .{ ".vl", .varlang },
    .{ ".dl", .definelang },
    .{ ".fl", .funclang },
    .{ ".rl", .reflang },
});

pub fn main() !u8 {
    var gpa_: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_.deinit();

    const gpa = gpa_.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len <= 1) {
        std.process.fatal("expected a file path argument", .{});
    }

    const is_program = if (args.len >= 3) !std.mem.eql(u8, args[2], "--repl-like") else true;

    const file_path = args[1];
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const flavor = extension_map.get(std.fs.path.extension(file_path)) orelse std.process.fatal("invalid program file extension", .{});

    const source = try file.readToEndAllocOptions(gpa, 4096, null, 1, 0);
    defer gpa.free(source);

    var cg = CodeGen.init(gpa, source, flavor);
    defer cg.deinit();

    var program = cg.genProgram(if (is_program) .program else .repl_like) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.InvalidSyntax => {
            const stderr = std.io.getStdErr();
            const writer = stderr.writer();
            const config = std.io.tty.detectConfig(stderr);
            try config.setColor(writer, .reset);
            try config.setColor(writer, .bold);
            const line = std.mem.count(u8, source[0..cg.error_info.?.source_range.start], &.{'\n'}) + 1;
            const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..cg.error_info.?.source_range.start], '\n')) |nl_index| nl_index + 1 else 0;
            try writer.print("{s}:{}:{}: ", .{ file_path, line, cg.error_info.?.source_range.start - line_start + 1 });
            try config.setColor(writer, .reset);
            try cg.formatError(config, writer);
            const line_end = if (std.mem.indexOfScalarPos(u8, source, cg.error_info.?.source_range.end, '\n')) |nl_index| nl_index else source.len;
            try writer.print("\n{s}\n", .{source[line_start..line_end]});
            try writer.writeByteNTimes(' ', cg.error_info.?.source_range.start - line_start);
            try config.setColor(writer, .bold);
            try config.setColor(writer, .green);
            try writer.writeByte('^');
            try writer.writeByteNTimes('~', cg.error_info.?.source_range.end - cg.error_info.?.source_range.start -| 1);
            try writer.writeByte('\n');
            try config.setColor(writer, .reset);
            return 1;
        },
    };
    defer program.deinit();

    var vm = try Vm.init(cg);
    defer vm.deinit();
    const results = try vm.execute(&program);

    const stdout = std.io.getStdOut();
    const config = std.io.tty.detectConfig(stdout);
    for (results) |result| {
        try result.formatPretty(config, stdout.writer());
        try stdout.writeAll("\n");
    }

    if (vm.exception) |exception| {
        const stderr = std.io.getStdErr();
        const writer = stderr.writer();
        try config.setColor(writer, .bold);
        try config.setColor(writer, .red);
        try writer.writeAll("error: ");
        try config.setColor(writer, .reset);
        try config.setColor(writer, .bold);
        try writer.print("{s}\n", .{exception});
        try config.setColor(writer, .reset);
        for (vm.stack_trace.items, 0..) |index, i| {
            const is_lambda = i != vm.stack_trace.items.len - 1;
            var tokenizer: xlang.Tokenizer = .{ .source = source, .index = index };
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
            const line = std.mem.count(u8, source[0..tokenizer.start], &.{'\n'}) + 1;
            const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..index], '\n')) |nl_index| nl_index + 1 else 0;
            try config.setColor(writer, .bold);
            try writer.print("{s}:{}:{}", .{ file_path, line, index - line_start + 1 });
            try config.setColor(writer, .reset);
            try writer.writeAll(if (is_lambda) " in lambda:\n" else " in main:\n");
            const line_end = if (std.mem.indexOfScalarPos(u8, source, tokenizer.index, '\n')) |nl_index| nl_index else source.len;
            try writer.print("{s}\n", .{source[line_start..line_end]});
            try writer.writeByteNTimes(' ', index - line_start);
            try config.setColor(writer, .bold);
            try config.setColor(writer, .green);
            try writer.writeByte('^');
            try writer.writeByteNTimes('~', tokenizer.index - index -| 1);
            try writer.writeByte('\n');
            try config.setColor(writer, .reset);
        }
        return 1;
    }
    return 0;
}
