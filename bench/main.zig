const std = @import("std");
const csv = @import("csv");

const Stats = struct {
    total: usize = 0,
    request: usize = 0,
};

const expected: Stats = .{ .total = 7430273, .request = 1909469 };

fn compute() !Stats {
    var file_buffer: [4096]u8 = undefined;
    var file_handle = std.fs.cwd().openFileZ("bench/example.csv", .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.log.err("bench/example.csv not found - did you unpack it with `bunzip2 -k bench/example.csv.bz2`?", .{});
        }
        return err;
    };
    defer file_handle.close();
    var file_reader = file_handle.reader(&file_buffer);

    var reader = csv.Reader.init(&file_reader.interface, .{});
    var record = csv.Record.init(std.heap.c_allocator);
    defer record.deinit();

    // Skip the header row
    _ = try reader.next(&record);

    // Read the rows
    var stats: Stats = .{};
    while (try reader.next(&record)) {
        stats.total += 1;
        if (std.mem.eql(u8, record.getSafe(5) orelse "", "3")) {
            stats.request += 1;
        }
    }

    return stats;
}

fn time_one_run(timer: *std.time.Timer) !u64 {
    timer.reset();
    const stats = try compute();
    const elapsed_ns = timer.read();

    if (stats.total != expected.total or stats.request != expected.request) {
        std.log.err("got: total={d} request={d}, expected: total={d}, request={d}", .{
            stats.total,
            stats.request,
            expected.total,
            expected.request,
        });
        return error.UnexpectedResult;
    }
    return elapsed_ns;
}

fn sum(comptime T: type, slice: []const T) T {
    var total = @as(T, 0);
    for (slice) |element| total += element;
    return total;
}

fn avg(comptime T: type, slice: []const T) T {
    return sum(T, slice) / @as(T, slice.len);
}

pub fn main() !void {
    var timer = try std.time.Timer.start();

    const runs = 10;
    var timings_ns: [runs]u64 = undefined;

    for (0..runs) |i| {
        timings_ns[i] = try time_one_run(&timer);
        std.log.info("run {d}: {d} ms", .{ i, timings_ns[i] / std.time.ns_per_ms });
    }

    const min_max_ns = std.mem.minMax(u64, &timings_ns);
    const avg_ns = avg(u64, &timings_ns);

    std.log.info("total ({d}) runs: min={d} ms, max={d} ms, avg={d} ms", .{
        runs,
        min_max_ns[0] / std.time.ns_per_ms,
        min_max_ns[1] / std.time.ns_per_ms,
        avg_ns / std.time.ns_per_ms,
    });
}
