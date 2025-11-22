zig-csv
=======

[GitHub](https://github.com/mkuranowski/zig-csv) | [Documentation](https://mkuranowski.github.io/zig-csv/)

Library for CSV (as per [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180)) reading and writing in Zig.


Installation
------------

These instructions assume a standard build.zig-based project.

1. Fetch the library: `zig fetch --save https://github.com/MKuranowski/zig-csv/archive/refs/tags/v2.0.0.tar.gz`
2. Add a dependency to `build.zig`:
    ```zig
    const csv_module = b.dependency("csv", .{ .target = target, .optimize = optimize }).module("csv");
    ```
3. Add import to all of your modules which import the library:
    ```zig
    your_module.addImport("csv", csv_module);
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
    // Initialize stdout for printing stats
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Open a file for reading
    var file_buffer: [4096]u8 = undefined;
    const file_handle = try std.fs.cwd().openFileZ("file.csv", .{});
    defer file_handle.close();
    var file_reader = file_handle.reader(&file_buffer);
    const file = &file_reader.interface;

    // Prepare the csv.Reader and csv.Record objects
    var reader = csv.Reader.init(file, .{});
    var record = csv.Record.init(std.heap.smp_allocator);
    defer record.deinit();

    // Read records from the CSV file and print its fields
    while (try reader.next(&record)) {
        try stdout.print("Record at line {d} with {d} fields:\n", .{ record.line_no, record.len() });
        for (0..record.len()) |i| {
            try stdout.print("\t{d}: {s}\n", .{ i, record.get(i) });
        }
    }

    try stdout.flush();
}

```

### Basic writing

```zig
const std = @import("std");
const csv = @import("csv");

pub fn main() !void {
    // Open a file for writing
    var file_buffer: [4096]u8 = undefined;
    const file_handle = try std.fs.cwd().createFileZ("file.csv", .{});
    defer file_handle.close();
    var file_writer = file_handle.writer(&file_buffer);
    const file = &file_writer.interface;

    // Prepare the csv.Writer object
    var writer = csv.Writer.init(file, .{});

    // Write a record from a tuple
    try writer.writeRecord(.{ "constant", "value" });

    // Write a record from a slice
    const record: []const []const u8 = &.{ "pi", "3.1416" };
    try writer.writeRecord(record);

    // Write a record field-by-field
    try writer.writeField("e");
    try writer.writeField("2.7183");
    try writer.terminateRecord();

    // Don't forget to flush buffered data to the actual file
    try file.flush();
}

```

### Advanced

This library supports custom dialects, and is suitable for pipe-delimited or tab-delimited
files as well. See [the documentation](https://mkuranowski.github.io/zig-csv/) for details.


Documentation
-------------

Automatically built documentation is available under <https://mkuranowski.github.io/zig-csv/>.
Due to GitHub pages limitation, this documentation is for the latest release of the library.
To obtain docs of an older version, clone the repository, checkout to the desired commit/tag,
and run `zig build docs`.

License
-------

This library available under the [MIT License](LICENSE).
