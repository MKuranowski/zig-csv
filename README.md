zig-csv
=======

Library for CSV (as per [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180)) reading and writing in Zig


Installation
------------

These instructions assume a standard build.zig-based project.

1. Fetch the library: `zig fetch --save https://github.com/MKuranowski/zig-csv/archive/refs/heads/main.tar.gz`
2. Add a dependency to `build.zig`:
    ```zig
    const csv_module = b.dependency("csv", .{ .target = target, .optimize = optimize }).module("csv");
    ```
3. Add import to all Compile steps which import the library:
    ```zig
    compile_step_like_exe.root_module.addImport("csv", csv_module);
    ```
4. Use the library in your code with:
    ```zig
    const csv = @import("csv");
    ```

Usage
-----

### Basic reading

```zig
const std = @import("std");
const csv = @import("csv");

pub fn main() !void {
    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout_writer = stdout_buffer.writer();

    const file = try std.fs.cwd().openFileZ("file.csv", .{});
    defer file.close();
    var file_buffer = std.io.bufferedReader(file.reader());

    var reader = csv.reader(file_buffer.reader(), .{});
    var record = csv.Record.init(std.heap.c_allocator);
    defer record.deinit();

    while (try reader.next(&record)) {
        try stdout_writer.print("Record at line {d} with {d} fields:\n", .{ record.line_no, record.len() });
        for (0..record.len()) |i| {
            try stdout_writer.print("\t{d}: {s}\n", .{ i, record.get(i) });
        }
    }

    try stdout_buffer.flush();
}
```

### Basic writing

```zig
const std = @import("std");
const csv = @import("csv");

pub fn main() !void {
    const file = try std.fs.cwd().createFileZ("file.csv", .{});
    defer file.close();
    var buffer = std.io.bufferedReader(file.reader());

    var writer = csv.writer(buffer.writer(), .{});

    // Write a record from a tuple
    try writer.writeRecord(.{ "constant", "value" });

    // Write a record from a slice
    const record: []const []const u8 = &.{ "pi", "3.1416" };
    try writer.writeRecord(record);

    // Write a record field-by-field
    try writer.writeField("e");
    try writer.writeField("2.7183");
    try writer.terminateRecord();

    try buffer.flush();
}
```

### Advanced

This library supports custom dialects, and is suitable for pipe-delimited or tab-delimited
files as well. See the documentation for details.

License
-------

This library available under the [MIT License](LICENSE).
