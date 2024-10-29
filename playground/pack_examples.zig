const std = @import("std");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    var json = std.ArrayList(u8).init(gpa);
    defer json.deinit();
    try json.append('{');

    var examples_dir = try std.fs.openDirAbsolute(args[1], .{ .iterate = true });
    defer examples_dir.close();
    var iter = examples_dir.iterate();
    var has_before: bool = false;
    while (try iter.next()) |entry| {
        const extension = std.fs.path.extension(entry.name);
        if (!std.mem.endsWith(u8, entry.name, ".zig") and extension.len == 3) {
            if (has_before) {
                try json.append(',');
            }
            has_before = true;
            const file = try examples_dir.openFile(entry.name, .{});
            const bytes = try file.readToEndAlloc(gpa, 4096);
            var enc = std.base64.standard.Encoder;
            try json.writer().print("\"{s}\":\"{c}LP", .{ entry.name, std.ascii.toUpper(extension[1]) });
            const len = enc.calcSize(bytes.len);
            try json.ensureUnusedCapacity(len);
            json.items.len += len;
            _ = enc.encode(json.items[json.items.len - len ..], bytes);
            try json.append('"');
        }
    }
    try json.append('}');

    var examples = try std.fs.createFileAbsolute(args[2], .{});
    defer examples.close();
    try examples.writeAll(json.items);
}
