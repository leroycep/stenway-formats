const Table = union(reliabletxt.Encoding) {
    utf8: [][]?[]u8,
    utf16: [][]?[]u16,
    utf16_reverse: [][]?[]u16,
    utf32: [][]?[]u32,

    pub fn free(this: @This(), gpa: std.mem.Allocator) void {
        switch (this) {
            .utf8 => |table| {
                for (table) |row| {
                    for (row) |value_opt| {
                        if (value_opt) |value| {
                            gpa.free(value);
                        }
                    }
                    gpa.free(row);
                }
                gpa.free(table);
            },
            else => std.debug.panic("unimplemented", .{}),
        }
    }
};

const ParseState = enum { default, string, string_double_quote, string_line_break_escape, comment };

pub fn parseAlloc(gpa: std.mem.Allocator, contents_any: []const u8) !Table {
    switch (try reliabletxt.parse(contents_any)) {
        .utf8 => |contents_utf8| {
            var table = std.ArrayList([]?[]u8).init(gpa);
            defer table.deinit();

            const utf8_view = try std.unicode.Utf8View.init(contents_utf8);
            var utf8_iter = utf8_view.iterator();

            var line_buf = std.ArrayList(?[]u8).init(gpa);
            defer line_buf.deinit();

            var value_buf = std.ArrayList(u8).init(gpa);
            defer value_buf.deinit();

            var state = ParseState.default;
            while (utf8_iter.nextCodepoint()) |codepoint| {
                switch (state) {
                    .default => switch (codepoint) {
                        '\n' => {
                            try table.ensureUnusedCapacity(1);
                            if (value_buf.items.len > 0) {
                                try line_buf.ensureUnusedCapacity(1);
                                const value = try value_buf.toOwnedSlice();
                                line_buf.appendAssumeCapacity(value);
                            }
                            const line = try line_buf.toOwnedSlice();
                            table.appendAssumeCapacity(line);
                        },
                        '"' => state = .string,
                        ' ',
                        '\t',
                        => {
                            if (value_buf.items.len > 0) {
                                try line_buf.ensureUnusedCapacity(1);
                                const value = try value_buf.toOwnedSlice();
                                line_buf.appendAssumeCapacity(value);
                            }
                        },
                        '#' => {
                            try table.ensureUnusedCapacity(1);
                            if (value_buf.items.len > 0) {
                                try line_buf.ensureUnusedCapacity(1);
                                const value = try value_buf.toOwnedSlice();
                                line_buf.appendAssumeCapacity(value);
                            }
                            const line = try line_buf.toOwnedSlice();
                            table.appendAssumeCapacity(line);
                            state = .comment;
                        },
                        else => |character| {
                            const codepoint_len = try std.unicode.utf8CodepointSequenceLength(character);

                            try value_buf.ensureUnusedCapacity(codepoint_len);
                            const buf = value_buf.unusedCapacitySlice()[0..codepoint_len];

                            _ = try std.unicode.utf8Encode(character, buf);

                            value_buf.items.len += codepoint_len;
                        },
                    },
                    .string => switch (codepoint) {
                        '\n' => {
                            // TODO: diagnostic: string not closed
                            return error.StringNotClosed;
                        },
                        '"' => state = .string_double_quote,
                        else => |character| {
                            const codepoint_len = try std.unicode.utf8CodepointSequenceLength(character);

                            try value_buf.ensureUnusedCapacity(codepoint_len);
                            const buf = value_buf.unusedCapacitySlice()[0..codepoint_len];

                            _ = try std.unicode.utf8Encode(character, buf);

                            value_buf.items.len += codepoint_len;
                        },
                    },
                    .string_double_quote => switch (codepoint) {
                        '"' => {
                            try value_buf.append('"');
                            state = .string;
                        },
                        '/' => state = .string_line_break_escape,
                        '\n' => {
                            try table.ensureUnusedCapacity(1);
                            if (value_buf.items.len > 0) {
                                try line_buf.ensureUnusedCapacity(1);
                                const value = try value_buf.toOwnedSlice();
                                line_buf.appendAssumeCapacity(value);
                            }
                            const line = try line_buf.toOwnedSlice();
                            table.appendAssumeCapacity(line);
                        },
                        '#' => {
                            try table.ensureUnusedCapacity(1);
                            if (value_buf.items.len > 0) {
                                try line_buf.ensureUnusedCapacity(1);
                                const value = try value_buf.toOwnedSlice();
                                line_buf.appendAssumeCapacity(value);
                            }
                            const line = try line_buf.toOwnedSlice();
                            table.appendAssumeCapacity(line);
                            state = .comment;
                        },
                        ' ',
                        '\t',
                        => {
                            try line_buf.ensureUnusedCapacity(1);
                            const value = try value_buf.toOwnedSlice();
                            line_buf.appendAssumeCapacity(value);
                            state = .default;
                        },
                        else => |character| {
                            const codepoint_len = try std.unicode.utf8CodepointSequenceLength(character);

                            try value_buf.ensureUnusedCapacity(codepoint_len);
                            const buf = value_buf.unusedCapacitySlice()[0..codepoint_len];

                            _ = try std.unicode.utf8Encode(character, buf);

                            value_buf.items.len += codepoint_len;
                        },
                    },
                    .string_line_break_escape => switch (codepoint) {
                        '"' => {
                            try value_buf.append('\n');
                            state = .string;
                        },
                        else => {
                            // TODO: diagnostic: invalid string line break
                            return error.InvalidStringLineBreak;
                        },
                    },
                    .comment => switch (codepoint) {
                        '\n' => state = .default,
                        else => {},
                    },
                }
            }

            {
                try table.ensureUnusedCapacity(1);
                if (value_buf.items.len > 0) {
                    try line_buf.ensureUnusedCapacity(1);
                    const value = try value_buf.toOwnedSlice();
                    line_buf.appendAssumeCapacity(value);
                }
                const line = try line_buf.toOwnedSlice();
                table.appendAssumeCapacity(line);
            }

            const utf8_table = try table.toOwnedSlice();
            return .{ .utf8 = utf8_table };
        },
        else => return error.Unimplemented,
    }
}

fn expectEqualUTF8Tables(expected_table: []const []const ?[]const u8, actual_table: []const []const ?[]const u8) !void {
    var is_errors = false;
    if (expected_table.len != actual_table.len) {
        std.debug.print("Expected table to have {} rows, found {} rows\n", .{ expected_table.len, actual_table.len });
        return error.TestExpectedEqual;
    }
    for (expected_table, actual_table, 0..) |expected_row, actual_row, row| {
        for (expected_row, actual_row, 0..) |expected_value, actual_value, col| {
            if (expected_value == null and actual_value != null) {
                std.debug.print(
                    \\at row {}, column {}
                    \\    expected null
                    \\       found "{}"
                    \\
                , .{ row, col, std.zig.fmtEscapes(actual_value.?) });
                is_errors = true;
            }
            if (expected_value != null and actual_value == null) {
                std.debug.print(
                    \\at row {}, column {}
                    \\    expected "{}"
                    \\       found null
                    \\
                , .{ row, col, std.zig.fmtEscapes(expected_value.?) });
                is_errors = true;
            }
            if (!std.mem.eql(u8, expected_value.?, actual_value.?)) {
                std.debug.print(
                    \\at row {}, column {}
                    \\    expected "{}"
                    \\       found "{}"
                    \\
                , .{ row, col, std.zig.fmtEscapes(expected_value.?), std.zig.fmtEscapes(actual_value.?) });
                is_errors = true;
            }
        }
    }

    if (is_errors) {
        return error.TestExpectedEqual;
    }
}

test parseAlloc {
    const table = try parseAlloc(testing.allocator, @embedFile("./testdata/Example01_Table_UTF8.txt"));
    defer table.free(testing.allocator);

    try testing.expectEqual(reliabletxt.Encoding.utf8, @as(reliabletxt.Encoding, table));
    const utf8_table = table.utf8;

    try expectEqualUTF8Tables(
        &.{
            &.{ "a", "U+0061", "61", "0061", "Latin Small Letter A" },
            &.{ "~", "U+007E", "7E", "007E", "Tilde" },
            &.{ "¥", "U+00A5", "C2_A5", "00A5", "Yen Sign" },
            &.{ "»", "U+00BB", "C2_BB", "00BB", "Right-Pointing Double Angle Quotation Mark" },
            &.{ "½", "U+00BD", "C2_BD", "00BD", "Vulgar Fraction One Half" },
            &.{ "¿", "U+00BF", "C2_BF", "00BF", "Inverted Question Mark" },
            &.{ "ß", "U+00DF", "C3_9F", "00DF", "Latin Small Letter Sharp S" },
            &.{ "ä", "U+00E4", "C3_A4", "00E4", "Latin Small Letter A with Diaeresis" },
            &.{ "ï", "U+00EF", "C3_AF", "00EF", "Latin Small Letter I with Diaeresis" },
            &.{ "œ", "U+0153", "C5_93", "0153", "Latin Small Ligature Oe" },
            &.{ "€", "U+20AC", "E2_82_AC", "20AC", "Euro Sign" },
            &.{ "東", "U+6771", "E6_9D_B1", "6771", "CJK Unified Ideograph-6771" },
            &.{ "𝄞", "U+1D11E", "F0_9D_84_9E", "D834_DD1E", "Musical Symbol G Clef" },
            &.{ "𠀇", "U+20007", "F0_A0_80_87", "D840_DC07", "CJK Unified Ideograph-20007" },
        },
        utf8_table,
    );
}

pub fn decodeString(encoded_string: []const u8, buffer: []u8) ![]const u8 {
    const State = enum {
        default,
        double_quote,
        double_quote_slash,
    };
    if (encoded_string.len < 1 or encoded_string[0] != '"' or encoded_string[encoded_string.len - 1] != '"') return error.InvalidFormat;
    var state = State.default;
    var write_pos: usize = 0;
    for (encoded_string[1 .. encoded_string.len - 1]) |encoded_character| {
        switch (state) {
            .default => switch (encoded_character) {
                '\n' => return error.InvalidFormat,
                '"' => state = .double_quote,
                else => {
                    if (write_pos >= buffer.len) return error.OutOfMemory;
                    buffer[write_pos] = encoded_character;
                    write_pos += 1;
                },
            },
            .double_quote => switch (encoded_character) {
                '"' => {
                    if (write_pos >= buffer.len) return error.OutOfMemory;
                    buffer[write_pos] = encoded_character;
                    write_pos += 1;
                    state = .default;
                },
                '/' => state = .double_quote_slash,
                else => return error.InvalidFormat,
            },
            .double_quote_slash => switch (encoded_character) {
                '"' => {
                    if (write_pos >= buffer.len) return error.OutOfMemory;
                    buffer[write_pos] = '\n';
                    write_pos += 1;
                    state = .default;
                },
                else => return error.InvalidFormat,
            },
        }
    }
    return buffer[0..write_pos];
}

test decodeString {
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("", try decodeString("\"\"", &buffer));
    try testing.expectEqualStrings("Latin Small Letter A", try decodeString("\"Latin Small Letter A\"", &buffer));
    try testing.expectEqualStrings("See these \"quotes\" I'm making with my claw hands? It means I don't belive you.", try decodeString("\"See these \"\"quotes\"\" I'm making with my claw hands? It means I don't belive you.\"", &buffer));
    try testing.expectEqualStrings("Line 1\nLine 2", try decodeString("\"Line 1\"/\"Line 2\"", &buffer));
}

pub fn parseIter(contents_any: []const u8) !Iterator {
    switch (try reliabletxt.parse(contents_any)) {
        .utf8 => |contents_utf8| {
            const utf8_view = try std.unicode.Utf8View.init(contents_utf8);
            return Iterator{ .utf8 = .{
                .utf8_iter = utf8_view.iterator(),
            } };
        },
        else => return error.Unimplemented,
    }
}

pub const Iterator = union(enum) {
    utf8: Utf8Iterator,
    _,
};

pub const Utf8Iterator = struct {
    utf8_iter: std.unicode.Utf8Iterator,

    pub const Item = union(enum) {
        newline,
        /// A value not surrounded by quotes. Can't include any whitespace.
        value: []const u8,
        /// A value surrounded by quotes. May include escaped double quotes or escaped newlines.
        string: []const u8,
        null,
    };

    const ParseState = enum { default, value, string, string_double_quote, string_line_break_escape, null, comment };

    pub fn next(this: *@This()) !?Item {
        var state = Utf8Iterator.ParseState.default;
        var value_start: usize = this.utf8_iter.i;
        while (this.utf8_iter.nextCodepoint()) |codepoint| {
            switch (state) {
                .default => switch (codepoint) {
                    '\n' => return Item.newline,
                    '"' => state = .string,

                    ' ',
                    '\t',
                    => value_start = this.utf8_iter.i,

                    '-' => state = .null,

                    '#' => state = .comment,
                    else => state = .value,
                },
                .value => switch (codepoint) {
                    // TODO: Add other whitespace characters
                    '\n',
                    ' ',
                    '\t',
                    => {
                        this.utf8_iter.i -= std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
                        return Item{ .value = this.utf8_iter.bytes[value_start..this.utf8_iter.i] };
                    },

                    '"' => return error.DoubleQuoteInValue,

                    else => {},
                },
                .string => switch (codepoint) {
                    '\n' => {
                        // TODO: diagnostic: string not closed
                        return error.StringNotClosed;
                    },
                    '"' => state = .string_double_quote,
                    else => {},
                },
                .string_double_quote => switch (codepoint) {
                    '"' => state = .string,
                    '/' => state = .string_line_break_escape,

                    // TODO: Add other whitespace characters
                    '\n',
                    '#',
                    ' ',
                    '\t',
                    => {
                        // we roll back here so it can be handled in the next iteration of the loop
                        this.utf8_iter.i -= std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
                        return Item{ .string = this.utf8_iter.bytes[value_start..this.utf8_iter.i] };
                    },

                    else => {},
                },
                .string_line_break_escape => switch (codepoint) {
                    '"' => state = .string,
                    else => {
                        // TODO: diagnostic: invalid string line break
                        return error.InvalidStringLineBreak;
                    },
                },
                .null => switch (codepoint) {
                    // TODO: Add other whitespace characters
                    '\n',
                    '#',
                    ' ',
                    '\t',
                    => {
                        // we roll back here so it can be handled in the next iteration of the loop
                        this.utf8_iter.i -= std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
                        return Item.null;
                    },
                    else => {
                        state = .value;
                    },
                },
                .comment => switch (codepoint) {
                    '\n' => state = .default,
                    else => {},
                },
            }
        }

        return null;
    }
};

fn expectEqualUTF8TablesIter(expected_table: []const []const ?[]const u8, actual_table: Utf8Iterator) !void {
    var actual_table_iter = actual_table;

    var is_errors = false;
    var expected_row_index: usize = 0;
    var expected_value_index: usize = 0;
    while (try actual_table_iter.next()) |actual_parse_event| {
        if (expected_row_index > expected_table.len) {
            std.debug.print("Expected table to have at most {} rows, found more rows\n", .{expected_row_index});
            is_errors = true;
            break;
        }

        switch (actual_parse_event) {
            .newline => {
                expected_row_index += 1;
                expected_value_index = 0;
            },
            .value => |actual_value_str| {
                const expected_value = expected_table[expected_row_index][expected_value_index];
                if (expected_value == null) {
                    std.debug.print(
                        \\at row {}, column {}
                        \\    expected null
                        \\       found "{}"
                        \\
                    , .{ expected_row_index, expected_value_index, std.zig.fmtEscapes(actual_value_str) });
                    is_errors = true;
                } else if (!std.mem.eql(u8, expected_value.?, actual_value_str)) {
                    std.debug.print(
                        \\at row {}, column {}
                        \\    expected "{}"
                        \\       found "{}"
                        \\
                    , .{ expected_row_index, expected_value_index, std.zig.fmtEscapes(expected_value.?), std.zig.fmtEscapes(actual_value_str) });
                    is_errors = true;
                }
                expected_value_index += 1;
            },
            .string => |actual_string_encoded| {
                var decode_buf: [128]u8 = undefined;
                const actual_value_str = try decodeString(actual_string_encoded, &decode_buf);

                const expected_value = expected_table[expected_row_index][expected_value_index];

                if (expected_value == null) {
                    std.debug.print(
                        \\at row {}, column {}
                        \\    expected null
                        \\       found "{}"
                        \\
                    , .{ expected_row_index, expected_value_index, std.zig.fmtEscapes(actual_value_str) });
                    is_errors = true;
                } else if (!std.mem.eql(u8, expected_value.?, actual_value_str)) {
                    std.debug.print(
                        \\at row {}, column {}
                        \\    expected "{}"
                        \\       found "{}"
                        \\
                    , .{ expected_row_index, expected_value_index, std.zig.fmtEscapes(expected_value.?), std.zig.fmtEscapes(actual_value_str) });
                    is_errors = true;
                }
                expected_value_index += 1;
            },
            .null => {
                const expected_value = expected_table[expected_row_index][expected_value_index];
                if (expected_value != null) {
                    std.debug.print(
                        \\at row {}, column {}
                        \\    expected "{}"
                        \\       found null
                        \\
                    , .{ expected_row_index, expected_value_index, std.zig.fmtEscapes(expected_value.?) });
                    is_errors = true;
                }
            },
        }
    }

    if (is_errors) {
        return error.TestExpectedEqual;
    }
}

test parseIter {
    try expectEqualUTF8TablesIter(
        &.{
            &.{ "a", "U+0061", "61", "0061", "Latin Small Letter A" },
            &.{ "~", "U+007E", "7E", "007E", "Tilde" },
            &.{ "¥", "U+00A5", "C2_A5", "00A5", "Yen Sign" },
            &.{ "»", "U+00BB", "C2_BB", "00BB", "Right-Pointing Double Angle Quotation Mark" },
            &.{ "½", "U+00BD", "C2_BD", "00BD", "Vulgar Fraction One Half" },
            &.{ "¿", "U+00BF", "C2_BF", "00BF", "Inverted Question Mark" },
            &.{ "ß", "U+00DF", "C3_9F", "00DF", "Latin Small Letter Sharp S" },
            &.{ "ä", "U+00E4", "C3_A4", "00E4", "Latin Small Letter A with Diaeresis" },
            &.{ "ï", "U+00EF", "C3_AF", "00EF", "Latin Small Letter I with Diaeresis" },
            &.{ "œ", "U+0153", "C5_93", "0153", "Latin Small Ligature Oe" },
            &.{ "€", "U+20AC", "E2_82_AC", "20AC", "Euro Sign" },
            &.{ "東", "U+6771", "E6_9D_B1", "6771", "CJK Unified Ideograph-6771" },
            &.{ "𝄞", "U+1D11E", "F0_9D_84_9E", "D834_DD1E", "Musical Symbol G Clef" },
            &.{ "𠀇", "U+20007", "F0_A0_80_87", "D840_DC07", "CJK Unified Ideograph-20007" },
        },
        (try parseIter(@embedFile("./testdata/Example01_Table_UTF8.txt"))).utf8,
    );

    try expectEqualUTF8TablesIter(
        &.{
            &.{ "Hello,", "world!" },
            &.{ null, "!" },
        },
        (try parseIter("\xEF\xBB\xBF" ++
            \\Hello, world!
            \\- !
        )).utf8,
    );
}

const reliabletxt = @import("./reliabletxt.zig");
const testing = std.testing;
const std = @import("std");
