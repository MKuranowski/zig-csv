// © Copyright 2024 Mikołaj Kuranowski
// SPDX-License-Identifier: MIT

//! Library for CSV (as per [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180)) reading and writing.
//!
//! Links: [GitHub](https://github.com/mkuranowski/zig-csv) | [Documentation](https://mkuranowski.github.io/zig-csv/)

const std = @import("std");
const io = std.io;

/// Terminator represents a record delimiter - either a specific octet, or the CR LF sequence.
pub const Terminator = union(enum) {
    octet: u8,
    crlf,
};

/// Dialect controls special characters used by `Reader` and `Writer`.
///
/// A default Dialect (`.{}`) is fully compatible with [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180#section-2).
pub const Dialect = struct {
    /// delimiter is the octet used to delimit fields within a single record.
    ///
    /// This corresponds to the [COMMA rule from RFC 4180](https://www.rfc-editor.org/rfc/rfc4180#section-2).
    delimiter: u8 = ',',

    /// quote is an octet used to enclose fields containing other special characters.
    /// Quotes within a quoted field must be escaped by another quote character.
    ///
    /// When set to `null`, quotes will not be treated specially by `Reader`,
    /// but `Writer` will use `"` when necessary.
    ///
    /// This corresponds to the [DQUOTE rule from RFC 4180](https://www.rfc-editor.org/rfc/rfc4180#section-2).
    quote: ?u8 = '"',

    /// terminator is an octet (or the CR LF sequence) used to terminate records.
    ///
    /// When set to `Terminator.crlf`, `Writer` will always terminate records by the CR LF sequence,
    /// but `Reader` will also accept sole CR or LF octets as record terminators.
    ///
    /// This corresponds to the [COMMA rule from RFC 4180](https://www.rfc-editor.org/rfc/rfc4180#section-2).
    terminator: Terminator = .crlf,

    /// bom controls the behavior for dealing with [UTF-8 Byte Order Mark](https://en.wikipedia.org/wiki/Byte_order_mark)
    /// (0xEF 0xBB 0xBF octet sequence) at the beginning of a file.
    ///
    /// When set to `null` (default), BOM (if it exists) will be discarded by `Reader`
    /// and not added by `Writer`.
    ///
    /// When set to `true`, BOM (if it exists) will be discarded by `Reader` and added by `Writer`.
    ///
    /// When set to `false`, BOM (if it exists) will be treated as part of the very first field
    /// of the file by `Reader`, and will not be added by `Writer`.
    bom: ?bool = null,
};

const State = enum {
    before_record,
    before_field,
    in_field,
    in_quoted_field,
    quote_in_quoted,
    eat_lf,
    eat_bom_1,
    eat_bom_2,
    eat_bom_3,
};

/// Parser parses [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180#section-2) CSV files.
///
/// The parser deviates from the standard in the following ways:
/// 1. Fields (TEXTDATA) may contain any bytes, as long as they are not COMMA, DQUOTE or CRLF.
/// 2. Fields can also be a concatenation of `escaped` and `non-escaped` data. This is done for
///    handling simplicity. Fields like `"foo"bar` are not treated as an error, but are parsed
///    as `foobar`.
/// 3. DQUOTE present in a `non-escaped` field is not treated as an error, rather the DQUOTE octet
///    is appended to the field. Encodings `"Foo ""Bar"" Baz"` and `Foo "Bar" Baz` are equivalent
///    and parse the same as the string literal `"Foo \"Bar\" Baz"`.
/// 4. Initial 0xEF 0xBB 0xBF (UTF-8 encoding of U+FEFF, the "byte order mark") may be consumed,
///    depending on the value of `Dialect.bom`.
/// 5. The values for COMMA, DQUOTE or CRLF rules can be customized; see `Dialect` for details.
///
/// `IoReader` can by any type with a `fn readByte(self) Error || error{EndOfStream} ! u8`
/// method. However, it is highly recommended to use a io.BufferedReader.
pub fn Reader(comptime IoReader: type) type {
    return struct {
        const Self = @This();

        r: IoReader,
        d: Dialect,

        state: State,
        line_no: u32 = 1,
        line_no_seen_cr: bool = false,

        pub inline fn init(io_reader: IoReader, dialect: Dialect) Self {
            return Self{
                .r = io_reader,
                .d = dialect,
                .state = if (dialect.bom == false) .before_record else .eat_bom_1,
            };
        }

        pub fn next(self: *Self, record: *Record) !bool {
            record.line_no = self.line_no;
            record.clear();

            while (true) {
                const b = self.getByte() catch |err| {
                    if (err == error.EndOfStream) {
                        switch (self.state) {
                            .before_record, .eat_lf => {
                                return false;
                            },

                            else => {
                                self.state = .before_record;
                                try record.pushField();
                                return true;
                            },
                        }
                    } else {
                        return err;
                    }
                };

                if (self.state == .eat_bom_1) {
                    if (b == 0xEF) {
                        self.state = .eat_bom_2;
                        continue;
                    } else {
                        self.state = .before_record;
                        // fallthrough
                    }
                }

                if (self.state == .eat_bom_2) {
                    if (b == 0xBB) {
                        self.state = .eat_bom_3;
                    } else {
                        try record.pushByte(0xEF);
                        self.state = .in_field;
                    }
                    continue;
                }

                if (self.state == .eat_bom_3) {
                    if (b == 0xBF) {
                        self.state = .before_record;
                    } else {
                        try record.pushBytes("\xEF\xBB");
                        self.state = .in_field;
                    }
                    continue;
                }

                if (self.state == .eat_lf) {
                    if (b == '\n') {
                        continue;
                    } else {
                        self.state = .before_record;
                        // fallthrough
                    }
                }

                if (self.state == .before_field or self.state == .before_record) {
                    if (b == self.d.quote) {
                        self.state = .in_quoted_field;
                        continue;
                    } else {
                        self.state = .in_field;
                        // fallthrough
                    }
                }

                if (self.state == .quote_in_quoted) {
                    if (b == self.d.quote) {
                        try record.pushByte(b);
                        self.state = .in_quoted_field;
                        continue;
                    } else {
                        self.state = .in_field;
                        // fallthrough
                    }
                }

                if (self.state == .in_field) {
                    // Try to match with delimiter
                    if (b == self.d.delimiter) {
                        try record.pushField();
                        self.state = .before_field;
                        continue;
                    }

                    // Try to match with terminator
                    switch (self.d.terminator) {
                        .octet => |terminator| {
                            if (b == terminator) {
                                self.state = .before_record;
                                try record.pushField();
                                return true;
                            }
                        },

                        .crlf => {
                            if (b == '\r' or b == '\n') {
                                self.state = if (b == '\r') .eat_lf else .before_record;
                                try record.pushField();
                                return true;
                            }
                        },
                    }

                    try record.pushByte(b);
                    continue;
                }

                if (self.state == .in_quoted_field) {
                    if (b == self.d.quote) {
                        self.state = .quote_in_quoted;
                    } else {
                        try record.pushByte(b);
                    }
                    continue;
                }
            }
        }

        fn getByte(self: *Self) !u8 {
            const b = try self.r.readByte();
            if (b == '\r') {
                self.line_no += 1;
                self.line_no_seen_cr = true;
            } else if (b == '\n' and !self.line_no_seen_cr) {
                self.line_no += 1;
            } else {
                self.line_no_seen_cr = false;
            }
            return b;
        }
    };
}

/// reader returns an initialized `Reader` over a given io.Reader instance.
/// See `Reader` documentation for details.
pub fn reader(io_reader: anytype, dialect: Dialect) Reader(@TypeOf(io_reader)) {
    return Reader(@TypeOf(io_reader)).init(io_reader, dialect);
}

/// Writers writes [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180#section-2) CSV files.
///
/// The writer deviates from the standard in the following ways:
/// 1. Field (TEXTDATA) may contain any bytes, as long as they are not COMMA, DQUOTE or CRLF.
/// 2. The values for COMMA, DQUOTE or CRLF rules can be customized; see `Dialect` for details.
///
/// `IoWriter` can be any type with `fn writeAll(self, []const u8) !void` and
/// `fn writeByte(self, u8) !void` methods. However, it is highly recommended to use
/// io.BufferedWriter.
pub fn Writer(comptime IoWriter: type) type {
    return struct {
        const Self = @This();

        w: IoWriter,
        d: Dialect,
        needs_bom: bool = false,
        needs_comma: bool = false,
        bytes_to_escape: [4]u8,

        pub inline fn init(io_writer: IoWriter, dialect: Dialect) Self {
            return Self{
                .w = io_writer,
                .d = dialect,
                .needs_bom = dialect.bom orelse false,
                .bytes_to_escape = getBytesToEscape(dialect),
            };
        }

        fn getBytesToEscape(dialect: Dialect) [4]u8 {
            var to_escape: [4]u8 = undefined;
            to_escape[0] = dialect.delimiter;
            to_escape[1] = dialect.quote orelse '"';
            switch (dialect.terminator) {
                .octet => |terminator| {
                    to_escape[2] = terminator;
                    to_escape[3] = terminator;
                },

                .crlf => {
                    to_escape[2] = '\r';
                    to_escape[3] = '\n';
                },
            }
            return to_escape;
        }

        /// writeRecord writes a CSV record to the underlying writer.
        ///
        /// `record` can be either a slice, pointer-to-many or a tuple of []const u8
        /// (or anything which can automatically be coerced to []const u8).
        ///
        /// It's forbidden to mix `writeRecord` and `writeField` calls to write a single record.
        /// If mixing both functions, a `writeRecord` can't follow a call to `writeField` -
        /// `terminateRecord` must be called first.
        pub fn writeRecord(self: *Self, record: anytype) !void {
            std.debug.assert(!self.needs_comma); // writeRecord called without terminating previous row.

            switch (@typeInfo(@TypeOf(record))) {
                // Slice of fields
                .pointer => |ptr| {
                    if (ptr.size == .Slice or ptr.size == .Many) {
                        for (record) |field| try self.writeField(field);
                        try self.terminateRecord();
                        return;
                    }
                },

                // Tuple of fields
                .@"struct" => |str| {
                    if (str.is_tuple) {
                        inline for (record) |field| try self.writeField(field);
                        try self.terminateRecord();
                        return;
                    }
                },

                else => {},
            }

            @compileError(@typeName(@TypeOf(record)) ++ " can't be interpreted as a CSV record");
        }

        /// writeField writes a CSV field to the underlying writer.
        ///
        /// The caller must also call `terminateRecord` once all fields
        /// of the record have been written.
        pub fn writeField(self: *Self, field: []const u8) !void {
            if (self.needs_bom) {
                try self.w.writeAll("\xEF\xBB\xBF");
                self.needs_bom = false;
            }

            if (self.needs_comma) try self.w.writeByte(self.d.delimiter);
            self.needs_comma = true;

            if (self.needsEscaping(field)) {
                const quote = self.d.quote orelse '"';
                try self.w.writeByte(quote);
                for (field) |octet| {
                    if (octet == quote) try self.w.writeByte(octet);
                    try self.w.writeByte(octet);
                }
                try self.w.writeByte(quote);
            } else {
                try self.w.writeAll(field);
            }
        }

        /// terminateRecord writes the record terminator to the underlying writer.
        pub fn terminateRecord(self: *Self) !void {
            self.needs_comma = false;
            switch (self.d.terminator) {
                .octet => |terminator| try self.w.writeByte(terminator),
                .crlf => try self.w.writeAll("\r\n"),
            }
        }

        fn needsEscaping(self: Self, field: []const u8) bool {
            return std.mem.indexOfAny(u8, field, &self.bytes_to_escape) != null;
        }
    };
}

/// writer returns an initialized `Writer` over a given io.Writer instance.
/// See `Writer` documentation for details.
pub fn writer(io_writer: anytype, dialect: Dialect) Writer(@TypeOf(io_writer)) {
    return Writer(@TypeOf(io_writer)).init(io_writer, dialect);
}

/// Record represents a single record from a CSV file.
///
/// Record internally consists of an `ArrayList(ArrayList(u8))`. Not all elements hold
/// valid fields. Elements which do, are called "complete".
///
/// There recommended way to iterate over fields of a Record is:
///
/// ```zig
/// for (0..record.len()) |i| {
///     const field = record.get(i);
/// }
/// ```
pub const Record = struct {
    allocator: std.mem.Allocator,

    /// Line number of the record in the source file. If records spans multiple lines,
    /// it's the first line of the record.
    ///
    /// Line numbers are determined by the number of CRLF sequences (or sole CR/LF octets) seen
    /// in the provided reader, **not** the number of terminators.
    line_no: u32 = 0,

    /// Array of buffers for fields. Length has to be >= self.complete_fields.
    /// Extra elements preserve allocated buffers for next fields, to avoid reallocations.
    field_buffers: std.ArrayList(std.ArrayList(u8)) = .{},

    /// Number of complete fields in `field_buffers`.
    /// `field_buffers[0..complete_fields]` represents completely parsed fields.
    complete_fields: usize = 0,

    pub inline fn init(allocator: std.mem.Allocator) Record {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Record) void {
        for (self.field_buffers.items) |*field_buffer| {
            field_buffer.deinit(self.allocator);
        }
        self.field_buffers.deinit(self.allocator);
    }

    /// line returns the number of complete fields in this record
    pub inline fn len(self: Record) usize {
        std.debug.assert(self.field_buffers.items.len >= self.complete_fields); // invariant for complete fields
        return self.complete_fields;
    }

    /// get returns the ith complete field, asserting that it's a complete field.
    pub inline fn get(self: Record, i: usize) []u8 {
        std.debug.assert(i < self.complete_fields); // check if complete field is accessed
        std.debug.assert(self.field_buffers.items.len >= self.complete_fields); // invariant for complete fields
        return self.field_buffers.items[i].items;
    }

    /// get returns the ith complete field, or null if no valid field exists at the provided index.
    pub inline fn getSafe(self: Record, i: usize) ?[]u8 {
        std.debug.assert(self.field_buffers.items.len >= self.complete_fields); // invariant for complete fields
        return if (i < self.complete_fields) self.field_buffers.items[i].items else null;
    }

    /// slice returns a slice over arrays holding the complete fields.
    pub inline fn slice(self: Record) []std.ArrayList(u8) {
        return self.field_buffers.items[0..self.complete_fields];
    }

    /// clear clears the record, setting each field_buffer to zero length (without deallocation),
    /// and setting the number of complete fields to zero.
    pub fn clear(self: *Record) void {
        self.complete_fields = 0;
        for (self.field_buffers.items) |*field_buffer| {
            field_buffer.clearRetainingCapacity();
        }
    }

    /// pushField marks field-being-built as complete. If no field is being built, a ""
    /// is added as a complete field.
    fn pushField(self: *Record) !void {
        try self.ensureIncompleteField();
        self.complete_fields += 1;
    }

    /// Adds a byte to the field-being-built, allocating that field if necessary.
    fn pushByte(self: *Record, b: u8) !void {
        try self.ensureIncompleteField();
        try self.field_buffers.items[self.complete_fields].append(self.allocator, b);
    }

    /// Adds a byte to the field-being-built, allocating that field if necessary.
    fn pushBytes(self: *Record, b: []const u8) !void {
        try self.ensureIncompleteField();
        try self.field_buffers.items[self.complete_fields].appendSlice(self.allocator, b);
    }

    /// Ensures the field-being-build (field_buffers[complete_fields]) exists.
    fn ensureIncompleteField(self: *Record) !void {
        std.debug.assert(self.field_buffers.items.len >= self.complete_fields); // invariant for complete fields

        if (self.field_buffers.items.len == self.complete_fields) {
            try self.field_buffers.append(self.allocator, .{});
        }
    }
};

test "csv.reading.basic" {
    const data = "pi,3.1416\r\nsqrt2,1.4142\r\nphi,1.618\r\ne,2.7183\r\n";
    var stream = io.fixedBufferStream(data);
    var r = reader(stream.reader(), .{});

    var record = Record.init(std.testing.allocator);
    defer record.deinit();

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 1), record.line_no);
    try std.testing.expectEqual(@as(usize, 2), record.len());
    try std.testing.expectEqualStrings("pi", record.get(0));
    try std.testing.expectEqualStrings("3.1416", record.get(1));

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 2), record.line_no);
    try std.testing.expectEqual(@as(usize, 2), record.len());
    try std.testing.expectEqualStrings("sqrt2", record.get(0));
    try std.testing.expectEqualStrings("1.4142", record.get(1));

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 3), record.line_no);
    try std.testing.expectEqual(@as(usize, 2), record.len());
    try std.testing.expectEqualStrings("phi", record.get(0));
    try std.testing.expectEqualStrings("1.618", record.get(1));

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 4), record.line_no);
    try std.testing.expectEqual(@as(usize, 2), record.len());
    try std.testing.expectEqualStrings("e", record.get(0));
    try std.testing.expectEqualStrings("2.7183", record.get(1));

    try std.testing.expect(!try r.next(&record));
}

test "csv.reading.with_quoted_fields" {
    const data =
        \\"hello","is it ""me""","you're
        \\looking for"
        \\"it's another
        \\record",with a newline inside,"but no ""trailing"" "one!
    ;

    var stream = io.fixedBufferStream(data);
    var r = reader(stream.reader(), .{});

    var record = Record.init(std.testing.allocator);
    defer record.deinit();

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 1), record.line_no);
    try std.testing.expectEqual(@as(usize, 3), record.len());
    try std.testing.expectEqualStrings("hello", record.get(0));
    try std.testing.expectEqualStrings("is it \"me\"", record.get(1));
    try std.testing.expectEqualStrings("you're\nlooking for", record.get(2));

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 3), record.line_no);
    try std.testing.expectEqual(@as(usize, 3), record.len());
    try std.testing.expectEqualStrings("it's another\nrecord", record.get(0));
    try std.testing.expectEqualStrings("with a newline inside", record.get(1));
    try std.testing.expectEqualStrings("but no \"trailing\" one!", record.get(2));

    try std.testing.expect(!try r.next(&record));
}

test "csv.reading.with_custom_dialect" {
    const data = "foo|bar#\"no quote handling|\"so this is another field#";
    var stream = io.fixedBufferStream(data);
    var r = reader(
        stream.reader(),
        .{
            .delimiter = '|',
            .quote = null,
            .terminator = .{ .octet = '#' },
        },
    );

    var record = Record.init(std.testing.allocator);
    defer record.deinit();

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 1), record.line_no);
    try std.testing.expectEqual(@as(usize, 2), record.len());
    try std.testing.expectEqualStrings("foo", record.get(0));
    try std.testing.expectEqualStrings("bar", record.get(1));

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqual(@as(u32, 1), record.line_no);
    try std.testing.expectEqual(@as(usize, 2), record.len());
    try std.testing.expectEqualStrings("\"no quote handling", record.get(0));
    try std.testing.expectEqualStrings("\"so this is another field", record.get(1));
}

test "csv.reading.bom_true" {
    const data = "\xEF\xBB\xBFname,value";
    var stream = io.fixedBufferStream(data);
    var r = reader(stream.reader(), .{ .bom = true });

    var record = Record.init(std.testing.allocator);
    defer record.deinit();

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqualStrings("name", record.get(0));
    try std.testing.expectEqualStrings("value", record.get(1));

    try std.testing.expect(!try r.next(&record));
}

test "csv.reading.bom_false" {
    const data = "\xEF\xBB\xBFname,value";
    var stream = io.fixedBufferStream(data);
    var r = reader(stream.reader(), .{ .bom = false });

    var record = Record.init(std.testing.allocator);
    defer record.deinit();

    try std.testing.expect(try r.next(&record));
    try std.testing.expectEqualStrings("\xEF\xBB\xBFname", record.get(0));
    try std.testing.expectEqualStrings("value", record.get(1));

    try std.testing.expect(!try r.next(&record));
}

test "csv.writing.basic" {
    var data: std.ArrayList(u8) = .{};
    defer data.deinit(std.testing.allocator);

    var w = writer(data.writer(std.testing.allocator), .{});
    try w.writeRecord(.{ "foo", "bar", "baz" });

    try w.writeField("this field needs to be \"escaped\"");
    try w.writeField("and, this one\ntoo?");
    try w.writeField("but this one - 'no'");
    try w.terminateRecord();

    try std.testing.expectEqualStrings(
        "foo,bar,baz\r\n\"this field needs to be \"\"escaped\"\"\",\"and, this one\ntoo?\",but this one - 'no'\r\n",
        data.items,
    );
}

test "csv.writing.bom" {
    var data: std.ArrayList(u8) = .{};
    defer data.deinit(std.testing.allocator);

    var w = writer(data.writer(std.testing.allocator), .{ .bom = true });
    try w.writeRecord(.{ "foo", "bar", "baz" });
    try w.writeRecord(.{ "spam", "eggs", "42" });

    try std.testing.expectEqualStrings(
        "\xEF\xBb\xBFfoo,bar,baz\r\nspam,eggs,42\r\n",
        data.items,
    );
}

test "csv.writing_with_custom_dialect" {
    var data: std.ArrayList(u8) = .{};
    defer data.deinit(std.testing.allocator);

    var w = writer(
        data.writer(std.testing.allocator),
        .{
            .delimiter = '|',
            .quote = '\'',
            .terminator = .{ .octet = '#' },
        },
    );
    try w.writeRecord(.{ "foo", "bar", "baz" });
    try w.writeRecord(.{ "needs|escaping", "and'this#too", "\"but this\" - no" });

    try std.testing.expectEqualStrings(
        "foo|bar|baz#'needs|escaping'|'and''this#too'|\"but this\" - no#",
        data.items,
    );
}
