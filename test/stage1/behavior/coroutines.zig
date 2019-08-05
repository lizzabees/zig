const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

var global_x: i32 = 1;

test "simple coroutine suspend and resume" {
    const frame = async simpleAsyncFn();
    expect(global_x == 2);
    resume frame;
    expect(global_x == 3);
    const af: anyframe->void = &frame;
    resume frame;
    expect(global_x == 4);
}
fn simpleAsyncFn() void {
    global_x += 1;
    suspend;
    global_x += 1;
    suspend;
    global_x += 1;
}

var global_y: i32 = 1;

test "pass parameter to coroutine" {
    const p = async simpleAsyncFnWithArg(2);
    expect(global_y == 3);
    resume p;
    expect(global_y == 5);
}
fn simpleAsyncFnWithArg(delta: i32) void {
    global_y += delta;
    suspend;
    global_y += delta;
}

test "suspend at end of function" {
    const S = struct {
        var x: i32 = 1;

        fn doTheTest() void {
            expect(x == 1);
            const p = async suspendAtEnd();
            expect(x == 2);
        }

        fn suspendAtEnd() void {
            x += 1;
            suspend;
        }
    };
    S.doTheTest();
}

test "local variable in async function" {
    const S = struct {
        var x: i32 = 0;

        fn doTheTest() void {
            expect(x == 0);
            const p = async add(1, 2);
            expect(x == 0);
            resume p;
            expect(x == 0);
            resume p;
            expect(x == 0);
            resume p;
            expect(x == 3);
        }

        fn add(a: i32, b: i32) void {
            var accum: i32 = 0;
            suspend;
            accum += a;
            suspend;
            accum += b;
            suspend;
            x = accum;
        }
    };
    S.doTheTest();
}

test "calling an inferred async function" {
    const S = struct {
        var x: i32 = 1;
        var other_frame: *@Frame(other) = undefined;

        fn doTheTest() void {
            _ = async first();
            expect(x == 1);
            resume other_frame.*;
            expect(x == 2);
        }

        fn first() void {
            other();
        }
        fn other() void {
            other_frame = @frame();
            suspend;
            x += 1;
        }
    };
    S.doTheTest();
}

test "@frameSize" {
    const S = struct {
        fn doTheTest() void {
            {
                var ptr = @ptrCast(async fn(i32) void, other);
                const size = @frameSize(ptr);
                expect(size == @sizeOf(@Frame(other)));
            }
            {
                var ptr = @ptrCast(async fn() void, first);
                const size = @frameSize(ptr);
                expect(size == @sizeOf(@Frame(first)));
            }
        }

        fn first() void {
            other(1);
        }
        fn other(param: i32) void {
            var local: i32 = undefined;
            suspend;
        }
    };
    S.doTheTest();
}

test "coroutine suspend, resume" {
    seq('a');
    const p = async testAsyncSeq();
    seq('c');
    resume p;
    seq('f');
    // `cancel` is now a suspend point so it cannot be done here
    seq('g');

    expect(std.mem.eql(u8, points, "abcdefg"));
}
async fn testAsyncSeq() void {
    defer seq('e');

    seq('b');
    suspend;
    seq('d');
}
var points = [_]u8{0} ** "abcdefg".len;
var index: usize = 0;

fn seq(c: u8) void {
    points[index] = c;
    index += 1;
}

test "coroutine suspend with block" {
    const p = async testSuspendBlock();
    expect(!global_result);
    resume a_promise;
    expect(global_result);
}

var a_promise: anyframe = undefined;
var global_result = false;
async fn testSuspendBlock() void {
    suspend {
        comptime expect(@typeOf(@frame()) == *@Frame(testSuspendBlock));
        a_promise = @frame();
    }

    // Test to make sure that @frame() works as advertised (issue #1296)
    // var our_handle: anyframe = @frame();
    expect(a_promise == anyframe(@frame()));

    global_result = true;
}

var await_a_promise: anyframe = undefined;
var await_final_result: i32 = 0;

test "coroutine await" {
    await_seq('a');
    const p = async await_amain();
    await_seq('f');
    resume await_a_promise;
    await_seq('i');
    expect(await_final_result == 1234);
    expect(std.mem.eql(u8, await_points, "abcdefghi"));
}
async fn await_amain() void {
    await_seq('b');
    const p = async await_another();
    await_seq('e');
    await_final_result = await p;
    await_seq('h');
}
async fn await_another() i32 {
    await_seq('c');
    suspend {
        await_seq('d');
        await_a_promise = @frame();
    }
    await_seq('g');
    return 1234;
}

var await_points = [_]u8{0} ** "abcdefghi".len;
var await_seq_index: usize = 0;

fn await_seq(c: u8) void {
    await_points[await_seq_index] = c;
    await_seq_index += 1;
}

var early_final_result: i32 = 0;

test "coroutine await early return" {
    early_seq('a');
    const p = async early_amain();
    early_seq('f');
    expect(early_final_result == 1234);
    expect(std.mem.eql(u8, early_points, "abcdef"));
}
async fn early_amain() void {
    early_seq('b');
    const p = async early_another();
    early_seq('d');
    early_final_result = await p;
    early_seq('e');
}
async fn early_another() i32 {
    early_seq('c');
    return 1234;
}

var early_points = [_]u8{0} ** "abcdef".len;
var early_seq_index: usize = 0;

fn early_seq(c: u8) void {
    early_points[early_seq_index] = c;
    early_seq_index += 1;
}

test "async function with dot syntax" {
    const S = struct {
        var y: i32 = 1;
        async fn foo() void {
            y += 1;
            suspend;
        }
    };
    const p = async S.foo();
    // can't cancel in tests because they are non-async functions
    expect(S.y == 2);
}

test "async fn pointer in a struct field" {
    var data: i32 = 1;
    const Foo = struct {
        bar: async fn (*i32) void,
    };
    var foo = Foo{ .bar = simpleAsyncFn2 };
    var bytes: [64]u8 = undefined;
    const p = @asyncCall(&bytes, {}, foo.bar, &data);
    comptime expect(@typeOf(p) == anyframe->void);
    expect(data == 2);
    resume p;
    expect(data == 4);
}
async fn simpleAsyncFn2(y: *i32) void {
    defer y.* += 2;
    y.* += 1;
    suspend;
}

test "@asyncCall with return type" {
    const Foo = struct {
        bar: async fn () i32,

        var global_frame: anyframe = undefined;

        async fn middle() i32 {
            return afunc();
        }

        fn afunc() i32 {
            global_frame = @frame();
            suspend;
            return 1234;
        }
    };
    var foo = Foo{ .bar = Foo.middle };
    var bytes: [100]u8 = undefined;
    var aresult: i32 = 0;
    _ = @asyncCall(&bytes, &aresult, foo.bar);
    expect(aresult == 0);
    resume Foo.global_frame;
    expect(aresult == 1234);
}

test "async fn with inferred error set" {
    const S = struct {
        var global_frame: anyframe = undefined;

        fn doTheTest() void {
            var frame: [1]@Frame(middle) = undefined;
            var result: anyerror!void = undefined;
            _ = @asyncCall(@sliceToBytes(frame[0..]), &result, middle);
            resume global_frame;
            std.testing.expectError(error.Fail, result);
        }

        async fn middle() !void {
            var f = async middle2();
            return await f;
        }

        fn middle2() !void {
            return failing();
        }

        fn failing() !void {
            global_frame = @frame();
            suspend;
            return error.Fail;
        }
    };
    S.doTheTest();
}

//test "error return trace across suspend points - early return" {
//    const p = nonFailing();
//    resume p;
//    const p2 = async printTrace(p);
//}
//
//test "error return trace across suspend points - async return" {
//    const p = nonFailing();
//    const p2 = async printTrace(p);
//    resume p;
//}
//
//fn nonFailing() (anyframe->anyerror!void) {
//    const Static = struct {
//        var frame: @Frame(suspendThenFail) = undefined;
//    };
//    Static.frame = async suspendThenFail();
//    return &Static.frame;
//}
//async fn suspendThenFail() anyerror!void {
//    suspend;
//    return error.Fail;
//}
//async fn printTrace(p: anyframe->(anyerror!void)) void {
//    (await p) catch |e| {
//        std.testing.expect(e == error.Fail);
//        if (@errorReturnTrace()) |trace| {
//            expect(trace.index == 1);
//        } else switch (builtin.mode) {
//            .Debug, .ReleaseSafe => @panic("expected return trace"),
//            .ReleaseFast, .ReleaseSmall => {},
//        }
//    };
//}

test "break from suspend" {
    var my_result: i32 = 1;
    const p = async testBreakFromSuspend(&my_result);
    // can't cancel here
    std.testing.expect(my_result == 2);
}
async fn testBreakFromSuspend(my_result: *i32) void {
    suspend {
        resume @frame();
    }
    my_result.* += 1;
    suspend;
    my_result.* += 1;
}

test "heap allocated async function frame" {
    const S = struct {
        var x: i32 = 42;

        fn doTheTest() !void {
            const frame = try std.heap.direct_allocator.create(@Frame(someFunc));
            defer std.heap.direct_allocator.destroy(frame);

            expect(x == 42);
            frame.* = async someFunc();
            expect(x == 43);
            resume frame;
            expect(x == 44);
        }

        fn someFunc() void {
            x += 1;
            suspend;
            x += 1;
        }
    };
    try S.doTheTest();
}

test "async function call return value" {
    const S = struct {
        var frame: anyframe = undefined;
        var pt = Point{.x = 10, .y = 11 };

        fn doTheTest() void {
            expectEqual(pt.x, 10);
            expectEqual(pt.y, 11);
            _ = async first();
            expectEqual(pt.x, 10);
            expectEqual(pt.y, 11);
            resume frame;
            expectEqual(pt.x, 1);
            expectEqual(pt.y, 2);
        }

        fn first() void {
            pt = second(1, 2);
        }

        fn second(x: i32, y: i32) Point {
            return other(x, y);
        }

        fn other(x: i32, y: i32) Point {
            frame = @frame();
            suspend;
            return Point{
                .x = x,
                .y = y,
            };
        }

        const Point = struct {
            x: i32,
            y: i32,
        };
    };
    S.doTheTest();
}

test "suspension points inside branching control flow" {
    const S = struct {
        var result: i32 = 10;

        fn doTheTest() void {
            expect(10 == result);
            var frame = async func(true);
            expect(10 == result);
            resume frame;
            expect(11 == result);
            resume frame;
            expect(12 == result);
            resume frame;
            expect(13 == result);
        }

        fn func(b: bool) void {
            while (b) {
                suspend;
                result += 1;
            }
        }
    };
    S.doTheTest();
}
