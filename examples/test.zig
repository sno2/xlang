const std = @import("std");

const xlang = @import("xlang");
const build_options = @import("build_options");

const is_java = build_options.reflang_source != null or build_options.typelang_source != null;

fn expectResult(source: [:0]const u8, flavor: xlang.CodeGen.Flavor, expected: []const u8) !void {
    const gpa = std.testing.allocator;

    if (is_java) {
        var root = try std.fs.openDirAbsolute(build_options.root, .{});
        defer root.close();

        var examples = try root.openDir("examples", .{});
        defer examples.close();

        var java = try root.openDir(
            if (flavor.isBefore(.typelang)) build_options.reflang_source.? else build_options.typelang_source.?,
            .{},
        );
        defer java.close();

        var stdout = std.ArrayList(u8).init(gpa);
        defer stdout.deinit();
        var stderr = std.ArrayList(u8).init(gpa);
        defer stderr.deinit();

        var child = std.process.Child.init(&.{ "./gradlew", "run", "-q", "--console=plain" }, gpa);
        child.cwd_dir = java;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        for (source) |b| {
            if (std.ascii.isWhitespace(b)) {
                try child.stdin.?.writeAll(&.{' '});
            } else {
                try child.stdin.?.writeAll(&.{b});
            }
        }
        child.stdin.?.close();
        try child.collectOutput(&stdout, &stderr, 4096);

        const output_start = (std.mem.indexOf(u8, stdout.items, "$ ") orelse @panic("invalid")) + 2;
        const output_end = std.mem.indexOfPos(u8, stdout.items, output_start, "\n$") orelse @panic("invalid");
        try std.testing.expectEqualStrings(expected, stdout.items[output_start..output_end]);
        return;
    }

    var cg = xlang.CodeGen.init(gpa, source, flavor);
    defer cg.deinit();

    var program = try cg.genProgram(.program);
    defer program.deinit();

    var vm = try xlang.Vm.init(cg);
    defer vm.deinit();

    const results = try vm.execute(&program);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try out.writer(gpa).print("{}", .{results[0]});

    try std.testing.expectEqualStrings(expected, out.items);
}

test "append" {
    try expectResult(@embedFile("append1.fl"), .funclang, "(1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0 11.0 12.0 13.0 14.0 15.0 16.0 17.0 18.0)");
    try expectResult(@embedFile("append2.fl"), .funclang, "(1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0 11.0 12.0 13.0 14.0 15.0 16.0 17.0 18.0)");
}

test "captures" {
    try expectResult(@embedFile("captures1.fl"), .funclang, "19.0");
    try expectResult(@embedFile("captures2.fl"), .funclang, "19.0");
    try expectResult(@embedFile("captures3.fl"), .funclang, "28.0");
    try expectResult(@embedFile("captures4.fl"), .funclang, "44.0");
    try expectResult(@embedFile("captures5.fl"), .funclang, "6.0");
}

test "identity" {
    try expectResult(@embedFile("identity.fl"), .funclang, "42.0");
}

test "pair" {
    try expectResult(@embedFile("pair1.fl"), .funclang, "(1.0 2.0)");
    try expectResult(@embedFile("pair2.fl"), .funclang, "(1.0 2.0)");
    try expectResult(@embedFile("pair3.fl"), .funclang, "(5.0 7.0)");
}

test "ref" {
    try expectResult(@embedFile("ref1.rl"), .reflang, "23904.0");
    try expectResult(@embedFile("ref2.rl"), .reflang, "23.0");
    try expectResult(@embedFile("ref3.rl"), .reflang, "87.0");
    try expectResult(@embedFile("ref4.rl"), .reflang, "2.0");
}

test "roman" {
    try expectResult(@embedFile("roman.dl"), .definelang, "7.0");
}

test "overflow" {
    if (is_java) return error.SkipZigTest; // overflows when parsing
    try expectResult(@embedFile("overflow.dl"), .definelang, "-1");
}

test "let" {
    try expectResult(@embedFile("let1.vl"), .varlang, "342.0");
    try expectResult(@embedFile("let2.vl"), .varlang, "-9194325.805903576");
}

test "lambda" {
    if (is_java) return error.SkipZigTest; // different formatting
    try expectResult(@embedFile("lambda.fl"), .funclang, "(lambda (x) x)");
}

test "mutable" {
    try expectResult(@embedFile("mutable1.fl"), .funclang, "6.0");
    try expectResult(@embedFile("mutable2.fl"), .funclang, "143.0");
}

test "shadow" {
    try expectResult(@embedFile("shadow.vl"), .varlang, "45.0");
}

test "parity" {
    try expectResult(@embedFile("parity.fl"), .funclang, "#f");
}

test "empty" {
    try expectResult(@embedFile("empty.fl"), .funclang, "15.0");
}

test "fibonacci" {
    try expectResult(@embedFile("fibonacci1.fl"), .funclang, "(0.0 1.0 1.0 2.0 3.0 5.0 8.0 13.0 21.0 34.0 55.0 89.0 144.0 233.0 377.0 610.0 987.0 1597.0 2584.0 4181.0 6765.0 10946.0 17711.0 28657.0 46368.0 75025.0 121393.0 196418.0 317811.0 514229.0 832040.0 1346269.0 2178309.0 3524578.0 5702887.0 9227465.0)");
    if (!is_java) { // Java uses exponential number formatting for large numbers
        try expectResult(@embedFile("fibonacci2.fl"), .funclang, "(0.0 1.0 1.0 2.0 3.0 5.0 8.0 13.0 21.0 34.0 55.0 89.0 144.0 233.0 377.0 610.0 987.0 1597.0 2584.0 4181.0 6765.0 10946.0 17711.0 28657.0 46368.0 75025.0 121393.0 196418.0 317811.0 514229.0 832040.0 1346269.0 2178309.0 3524578.0 5702887.0 9227465.0 14930352.0 24157817.0 39088169.0 63245986.0 102334155.0 165580141.0 267914296.0 433494437.0 701408733.0 1134903170.0 1836311903.0 2971215073 4807526976 7778742049 12586269025 20365011074 32951280099 53316291173 86267571272 139583862445 225851433717 365435296162 591286729879 956722026041 1548008755920 2504730781961 4052739537881 6557470319842 10610209857723 17167680177565 27777890035288 44945570212853 72723460248141 117669030460994 190392490709135 308061521170129 498454011879264 806515533049393 1304969544928657 2111485077978050 3416454622906707 5527939700884757 8944394323791464 14472334024676220 23416728348467684 37889062373143900 61305790721611580 99194853094755490 160500643816367070 259695496911122560 420196140727489660 679891637638612200 1100087778366101900 1779979416004714000 2880067194370816000 4660046610375530000 7540113804746346000 12200160415121877000 19740274219868226000 31940434634990100000 51680708854858330000 83621143489848430000 135301852344706760000 218922995834555200000 354224848179262000000 573147844013817200000 927372692193079200000 1500520536206896300000 2427893228399975500000 3928413764606871700000 6356306993006848000000 10284720757613720000000 16641027750620568000000 26925748508234288000000 43566776258854860000000 70492524767089140000000 114059301025944000000000 184551825793033150000000 298611126818977150000000 483162952612010300000000 781774079430987500000000 1264937032042997800000000 2046711111473985100000000 3311648143516982700000000 5358359254990968000000000 8670007398507951000000000 14028366653498920000000000 22698374052006870000000000 36726740705505786000000000 59425114757512650000000000 96151855463018440000000000 155576970220531100000000000 251728825683549520000000000 407305795904080640000000000 659034621587630100000000000 1066340417491710700000000000 1725375039079340800000000000 2791715456571052000000000000 4517090495650392700000000000 7308805952221445000000000000 11825896447871837000000000000 19134702400093282000000000000 30960598847965120000000000000 50095301248058410000000000000 81055900096023530000000000000 131151201344081930000000000000 212207101440105450000000000000 343358302784187340000000000000 555565404224292760000000000000 898923707008480100000000000000 1454489111232773000000000000000 2353412818241253000000000000000 3807901929474026000000000000000 6161314747715279000000000000000 9969216677189305000000000000000 16130531424904583000000000000000 26099748102093888000000000000000 42230279526998470000000000000000 68330027629092365000000000000000 110560307156090850000000000000000 178890334785183200000000000000000 289450641941274060000000000000000 468340976726457300000000000000000 757791618667731300000000000000000 1226132595394188700000000000000000 1983924214061920000000000000000000 3210056809456108700000000000000000 5193981023518028000000000000000000 8404037832974137000000000000000000 13598018856492165000000000000000000 22002056689466300000000000000000000 35600075545958467000000000000000000 57602132235424770000000000000000000 93202207781383230000000000000000000 150804340016808000000000000000000000 244006547798191220000000000000000000 394810887814999250000000000000000000 638817435613190500000000000000000000 1033628323428189800000000000000000000 1672445759041380300000000000000000000 2706074082469570000000000000000000000 4378519841510950000000000000000000000 7084593923980520000000000000000000000 11463113765491470000000000000000000000 18547707689471990000000000000000000000 30010821454963460000000000000000000000 48558529144435440000000000000000000000 78569350599398900000000000000000000000 127127879743834340000000000000000000000 205697230343233240000000000000000000000 332825110087067600000000000000000000000 538522340430300900000000000000000000000 871347450517368400000000000000000000000 1409869790947669000000000000000000000000 2281217241465037500000000000000000000000 3691087032412707000000000000000000000000 5972304273877745000000000000000000000000 9663391306290452000000000000000000000000 15635695580168196000000000000000000000000 25299086886458650000000000000000000000000 40934782466626846000000000000000000000000 66233869353085490000000000000000000000000 107168651819712330000000000000000000000000 173402521172797830000000000000000000000000)");
    }
}

test "gc" {
    if (is_java) return error.SkipZigTest; // Java stack overflows
    try expectResult(@embedFile("gc1.fl"), .funclang, "()");
    try expectResult(@embedFile("gc2.rl"), .reflang, "349.0");
}

test "tail" {
    if (is_java) return error.SkipZigTest; // stack overflows
    try expectResult(@embedFile("tail1.fl"), .funclang, "125446.0");
    try expectResult(@embedFile("tail2.fl"), .funclang, "125445.0");
    try expectResult(@embedFile("tail3.fl"), .funclang, "500013.0");
    try expectResult(@embedFile("tail4.fl"), .funclang, "500012.0");
}

test "set" {
    try expectResult(@embedFile("set.rl"), .reflang, "4.0");
}

test "math" {
    try expectResult(@embedFile("math1.al"), .arithlang, "-1.0");
    try expectResult(@embedFile("math2.al"), .arithlang, "11.5");
    try expectResult(@embedFile("math3.al"), .arithlang, "-25.666666666666668");
}

test "sum" {
    try expectResult(@embedFile("sum.tl"), .typelang, "5.0");
}

test "immutable" {
    try expectResult(@embedFile("immutable.tl"), .typelang, "23.0");
}

test "function type" {
    try expectResult(@embedFile("function_type.tl"), .typelang, "5.0");
}

test "curry" {
    try expectResult(@embedFile("curry.tl"), .typelang, "5.18518518518519");
}

test "size" {
    try expectResult(@embedFile("size.tl"), .typelang, "18.0");
}

test "capture define" {
    try expectResult(@embedFile("capturedef.tl"), .typelang, "0.0");
}

test "typed ref" {
    try expectResult(@embedFile("typed_ref.tl"), .typelang, "288.0");
}

test "identifiers" {
    try expectResult(@embedFile("identifiers.dl"), .definelang, "41.0");
}

test "capture cache regression" {
    try expectResult(@embedFile("regression/capture_cache1.tl"), .typelang, "41.0");
    try expectResult(@embedFile("regression/capture_cache2.tl"), .typelang, "20.0");
}

fn fuzzCodegen(initial_source: []const u8) !void {
    const source = std.testing.allocator.dupeZ(u8, initial_source) catch return;
    defer std.testing.allocator.free(source);
    const first = if (initial_source.len == 0) 0 else initial_source[0];
    var cg = xlang.CodeGen.init(std.testing.allocator, source, @enumFromInt(first % 5));
    defer cg.deinit();
    var program = cg.genProgram(if (first % 2 == 0) .program else .repl_like) catch return;
    program.deinit();
}

test "fuzz code generation" {
    if (is_java) return error.SkipZigTest;
    try std.testing.fuzz(fuzzCodegen, .{});
}
