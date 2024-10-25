const std = @import("std");

const build_options = @import("build_options");

const Vm = @import("Vm.zig");
const Executable = @import("Executable.zig");

const Value = Vm.Value;

const Heap = @This();

gpa: std.mem.Allocator,
pages: std.ArrayListUnmanaged(*Page),
free_head: ?*FreeRange,

const page_len = std.mem.page_size / @sizeOf(Object);
const Page = [page_len]Object;

pub const Object = extern union {
    free_range: FreeRange,
    list: List,
    pair: Pair,
    reference: Reference,
    lambda: Lambda,

    pub const Head = packed struct(u64) {
        tag: Tag,
        _: std.meta.Int(.unsigned, 64 - 8 - 1) = undefined,
        is_marked: bool,

        pub const Tag = enum(u8) {
            free_range,
            pair,
            list,
            reference,
            lambda,

            pub fn Payload(comptime tag: Tag) type {
                return switch (tag) {
                    .free_range => FreeRange,
                    .pair => Pair,
                    .list => List,
                    .reference => Reference,
                    .lambda => Lambda,
                };
            }
        };
    };

    pub fn head(object: *Object) *Head {
        return &object.free_range.head;
    }
};

pub const FreeRange = extern struct {
    head: Object.Head align(@sizeOf(Object.Head)) = .{ .tag = .free_range, .is_marked = false },
    len: usize,
    next: ?*FreeRange,

    pub fn object(free_range: *FreeRange) *Object {
        return @ptrCast(free_range);
    }
};

pub const Pair = extern struct {
    head: Object.Head align(@sizeOf(Object.Head)) = .{ .tag = .pair, .is_marked = false },
    left: Value,
    right: Value,

    pub fn object(pair: *Pair) *Object {
        return @ptrCast(pair);
    }
};

pub const List = extern struct {
    head: Object.Head align(@sizeOf(Object.Head)) = .{ .tag = .list, .is_marked = false },
    value: Value,
    next: *List,

    pub const empty = &struct {
        pub var object: Object = .{
            .list = .{ .value = .empty, .next = undefined },
        };
    }.object.list;

    pub fn object(list: *List) *Object {
        return @ptrCast(list);
    }
};

pub const Reference = extern struct {
    head: Object.Head align(@sizeOf(Object.Head)) = .{ .tag = .reference, .is_marked = false },
    value: Value,
    is_free: bool = false,
};

pub const Lambda = extern struct {
    head: Object.Head align(@sizeOf(Object.Head)) = .{ .tag = .lambda, .is_marked = false },
    executable: *const Executable,
    captures: ?[*]Value,
};

pub fn init(gpa: std.mem.Allocator) !Heap {
    const page = try gpa.create(Page);
    page[0] = .{
        .free_range = .{ .len = page.len, .next = null },
    };
    errdefer gpa.destroy(page);

    var pages: std.ArrayListUnmanaged(*Page) = .empty;
    errdefer pages.deinit(gpa);
    try pages.append(gpa, page);

    return .{
        .gpa = gpa,
        .pages = pages,
        .free_head = &page[0].free_range,
    };
}

pub fn deinit(heap: *Heap) void {
    for (heap.pages.items) |page| {
        for (page) |*object| {
            if (object.head().tag == .lambda) {
                if (object.lambda.captures) |captures| {
                    heap.currentVm().gpa.free(captures[0..object.lambda.executable.captures.items.len]);
                }
            }
        }
        heap.gpa.destroy(page);
    }
    heap.pages.deinit(heap.gpa);
}

fn currentVm(heap: *Heap) *Vm {
    return @fieldParentPtr("heap", heap);
}

fn growPages(heap: *Heap, initial_free_tail: ?*FreeRange, n: usize) !void {
    var free_tail = initial_free_tail;
    try heap.pages.ensureUnusedCapacity(heap.gpa, n);
    for (0..n) |_| {
        const page = try heap.gpa.create(Page);
        page[0] = .{
            .free_range = .{ .len = page.len, .next = null },
        };
        if (free_tail) |tail| {
            tail.next = &page[0].free_range;
        } else {
            heap.free_head = &page[0].free_range;
        }
        free_tail = &page[0].free_range;
        heap.pages.appendAssumeCapacity(page);
    }
}

fn markStack(heap: *Heap) !void {
    const vm = heap.currentVm();

    const stack_len = vm.stack.items.len;
    defer vm.stack.shrinkRetainingCapacity(stack_len);

    try vm.stack.ensureUnusedCapacity(vm.gpa, vm.call_stack.items.len + 2);

    if (vm.call_stack.items.len > 0) {
        for (vm.call_stack.items[1..]) |item| {
            vm.stack.appendAssumeCapacity(Value.init(.lambda, item.lambda.?));
        }
        vm.stack.appendAssumeCapacity(Value.init(.lambda, vm.cur.lambda.?));
    }

    for (0..stack_len) |i| {
        const v = vm.stack.items[i];

        switch (v.getTag()) {
            .pair => {
                const pair = v.getPayload(.pair);
                if (pair.head.is_marked) continue;
                pair.head.is_marked = true;
                vm.stack.appendSliceAssumeCapacity(&.{ pair.left, pair.right });
            },
            .list => {
                const list = v.getPayload(.list);
                if (list == List.empty or list.head.is_marked) continue;
                list.head.is_marked = true;
                vm.stack.appendSliceAssumeCapacity(&.{ list.value, Value.init(.list, list.next) });
            },
            .reference => {
                const reference = v.getPayload(.reference);
                if (reference.head.is_marked) continue;
                reference.head.is_marked = true;
                vm.stack.appendAssumeCapacity(reference.value);
            },
            .lambda => {
                const lambda = v.getPayload(.lambda);
                if (lambda.head.is_marked) continue;
                lambda.head.is_marked = true;
                if (lambda.captures) |captures| {
                    for (captures[0..lambda.executable.captures.items.len]) |capture| {
                        try vm.stack.append(vm.gpa, capture);
                    }
                }
            },
            else => {},
        }

        while (vm.stack.items.len > stack_len) {
            const value = vm.stack.pop();
            switch (value.getTag()) {
                .pair => {
                    const pair = value.getPayload(.pair);
                    if (pair.head.is_marked) continue;
                    pair.head.is_marked = true;
                    vm.stack.appendAssumeCapacity(pair.left);
                    try vm.stack.append(vm.gpa, pair.right);
                },
                .list => {
                    const list = value.getPayload(.list);
                    if (list == List.empty or list.head.is_marked) continue;
                    list.head.is_marked = true;
                    vm.stack.appendAssumeCapacity(list.value);
                    try vm.stack.append(vm.gpa, Value.init(.list, list.next));
                },
                .reference => {
                    const reference = value.getPayload(.reference);
                    if (reference.head.is_marked) continue;
                    reference.head.is_marked = true;
                    vm.stack.appendAssumeCapacity(reference.value);
                },
                .lambda => {
                    const lambda = value.getPayload(.lambda);
                    if (lambda.head.is_marked) continue;
                    lambda.head.is_marked = true;
                    if (lambda.captures) |captures| {
                        for (captures[0..lambda.executable.captures.items.len]) |capture| {
                            try vm.stack.append(vm.gpa, capture);
                        }
                    }
                },
                else => {},
            }
        }
    }
}

pub fn createObject(
    heap: *Heap,
    comptime tag: Object.Head.Tag,
    data_: tag.Payload(),
) !*tag.Payload() {
    var data = data_;

    const free_head = heap.free_head orelse blk: {
        @branchHint(.unlikely);
        const vm = heap.currentVm();
        switch (tag) {
            .pair => {
                vm.stack.appendAssumeCapacity(data.left);
                vm.stack.appendAssumeCapacity(data.right);
            },
            .list => {
                vm.stack.appendAssumeCapacity(data.value);
                vm.stack.appendAssumeCapacity(Value.init(.list, data.next));
            },
            .reference => {
                vm.stack.appendAssumeCapacity(data.value);
            },
            .lambda => {}, // must manually make sure captures get marked
            else => @compileError("unreachable"),
        }
        try heap.collect();
        switch (tag) {
            .pair => {
                data.right = vm.stack.pop();
                data.left = vm.stack.pop();
            },
            .list => {
                data.next = vm.stack.pop().getPayload(.list);
                data.value = vm.stack.pop();
            },
            .reference => {
                vm.stack.appendAssumeCapacity(data.value);
            },
            .lambda => {},
            else => @compileError("unreachable"),
        }
        break :blk heap.free_head.?;
    };

    const new_object = free_head.object();
    if (free_head.len == 1) {
        heap.free_head = free_head.next;
    } else {
        free_head.len -= 1;
        const ptr: [*]Object = @ptrCast(new_object);
        ptr[1] = new_object.*;
        heap.free_head = &ptr[1].free_range;
    }
    new_object.* = @unionInit(Object, @tagName(tag), data);
    return &@field(new_object, @tagName(tag));
}

fn collect(heap: *Heap) !void {
    try heap.markStack();

    var lead: FreeRange = .{ .len = 0, .next = null };
    var free_tail: *FreeRange = &lead;

    for (heap.pages.items) |page| {
        var i: usize = 0;
        while (i < page.len) {
            if (!page[i].head().is_marked) {
                if (page[i].head().tag == .free_range) {
                    free_tail.next = &page[i].free_range;
                    free_tail = &page[i].free_range;
                    i += page[i].free_range.len;
                    continue;
                }

                if (page[i].head().tag == .lambda) {
                    if (page[i].lambda.captures) |captures| {
                        heap.currentVm().gpa.free(captures[0..page[i].lambda.executable.captures.items.len]);
                    }
                    page[i].lambda.captures = null;
                }

                const start = i;
                page[start] = .{
                    .free_range = .{ .len = 1, .next = null },
                };
                free_tail.next = &page[start].free_range;
                free_tail = &page[start].free_range;
                i += 1;
                while (i < page.len and !page[i].head().is_marked and page[i].head().tag != .free_range) {
                    i += 1;
                    page[start].free_range.len += 1;
                }
                continue;
            }

            page[i].head().is_marked = false;
            i += 1;
        }
    }

    heap.free_head = lead.next;
    if (heap.free_head == null) {
        // grow 80%
        try heap.growPages(if (lead.next == null) null else free_tail, @max(heap.pages.items.len / 5 * 4, 1));
    }
}
