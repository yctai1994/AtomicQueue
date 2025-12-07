const AtomicCounter = struct {
    // Important: plain integer, but we ONLY touch it via atomic intrinsics.
    value: u32,

    const Self = @This();

    const AtomicOrder = enum {
        relax,
        monotonic,
        acquire,
        release,
    };

    pub fn init(initial: u32) Self {
        return .{ .value = initial };
    }

    pub inline fn load(self: *Self, comptime order: AtomicOrder) u32 {
        return switch (order) {
            .relax, .monotonic => @atomicLoad(u32, &self.value, .monotonic),
            .acquire => @atomicLoad(u32, &self.value, .acquire),
            else => @compileError(""),
        };
    }

    pub inline fn store(self: *Self, data: u32, comptime order: AtomicOrder) void {
        switch (order) {
            .relax, .monotonic => @atomicStore(u32, &self.value, data, .monotonic),
            .release => @atomicStore(u32, &self.value, data, .release),
            else => @compileError(""),
        }
    }

    pub inline fn fetchAdd(self: *Self, delta: u32) u32 {
        // Returns the *previous* value.
        return @atomicRmw(u32, &self.value, .Add, delta, .acq_rel);
    }

    pub fn compareExchange(self: *Self, expected: u32, desired: u32) bool {
        // Returns true if CAS succeeded.
        const old = @cmpxchgStrong(u32, &self.value, expected, desired, .acq_rel, .acquire);
        return old == null;
    }
};

test "AtomicCounter: basic load/store" {
    var c = AtomicCounter.init(0);

    c.store(10, .relax);
    try std.testing.expectEqual(@as(u32, 10), c.load(.relax));

    c.store(42, .release);
    try std.testing.expectEqual(@as(u32, 42), c.load(.acquire));
}

test "AtomicCounter: fetchAdd" {
    var c = AtomicCounter.init(0);

    const old = c.fetchAdd(5);
    try std.testing.expectEqual(@as(u32, 0), old);
    try std.testing.expectEqual(@as(u32, 5), c.load(.relax));

    _ = c.fetchAdd(7);
    try std.testing.expectEqual(@as(u32, 12), c.load(.relax));
}

test "AtomicCounter: compareExchange" {
    var c = AtomicCounter.init(10);

    // Attempt CAS 10 -> 20 (should succeed)
    const ok1 = c.compareExchange(10, 20);
    try std.testing.expect(ok1);
    try std.testing.expectEqual(@as(u32, 20), c.load(.relax));

    // Attempt CAS 10 -> 30 (should fail, current = 20)
    const ok2 = c.compareExchange(10, 30);
    try std.testing.expect(!ok2);
    try std.testing.expectEqual(@as(u32, 20), c.load(.relax));
}

fn workerIncrement(counter: *AtomicCounter, iters: u32, id: usize) void {
    _ = id; // currently unused; keep for future experiments.

    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        _ = counter.fetchAdd(1);
        // Optional: add a tiny sleep or spin to mix timing.
        // std.time.sleep(1); // in ns, if you want to play
    }
}

test "AtomicCounter: 2-thread increment stress" {
    var counter = AtomicCounter.init(0);

    const thread_count: comptime_int = 2;
    const iters_per_thread: comptime_int = 100_000;

    var threads: [thread_count]std.Thread = undefined;

    // Spawn N threads, each does `fetchAdd(1)` many times.
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, workerIncrement, .{ &counter, iters_per_thread, index });
    }

    // Join all threads.
    for (threads) |thread| thread.join();

    const expected: u32 = iters_per_thread * thread_count;
    const actual = counter.load(.relax);

    try std.testing.expectEqual(expected, actual);
}

const std = @import("std");
