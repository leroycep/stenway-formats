//! https://dev.stenway.com/ReliableTXT/Specification.html

pub const Encoding = enum {
    utf8,
    /// Big Endian
    utf16,
    /// Little Endian
    utf16_reverse,
    /// Big Endian
    utf32,
};

pub fn detectEncoding(contents: []const u8) !Encoding {
    if (std.mem.startsWith(u8, contents, "\xEF\xBB\xBF")) {
        return Encoding.utf8;
    } else if (std.mem.startsWith(u8, contents, "\xFE\xFF")) {
        return Encoding.utf16;
    } else if (std.mem.startsWith(u8, contents, "\xFF\xFE")) {
        return Encoding.utf16_reverse;
    } else if (std.mem.startsWith(u8, contents, "\x00\x00\xFE\xFF")) {
        return Encoding.utf32;
    }
    return error.InvalidEncoding;
}

test detectEncoding {
    try testing.expectEqual(Encoding.utf8, detectEncoding("\xEF\xBB\xBFaaa!"));
    try testing.expectEqual(Encoding.utf16_reverse, detectEncoding(std.mem.sliceAsBytes(&[_]u16{
        std.mem.nativeToLittle(u16, 0xFE_FF),
        std.mem.nativeToLittle(u16, 'a'),
        std.mem.nativeToLittle(u16, 'a'),
        std.mem.nativeToLittle(u16, 'a'),
        std.mem.nativeToLittle(u16, '!'),
    })));

    try testing.expectEqual(Encoding.utf16, detectEncoding(std.mem.sliceAsBytes(&[_]u16{
        std.mem.nativeToBig(u16, 0xFE_FF),
        std.mem.nativeToBig(u16, 'a'),
        std.mem.nativeToBig(u16, 'a'),
        std.mem.nativeToBig(u16, 'a'),
        std.mem.nativeToBig(u16, '!'),
    })));

    try testing.expectEqual(Encoding.utf32, detectEncoding(std.mem.sliceAsBytes(&[_]u32{
        std.mem.nativeToBig(u32, 0x00_00_FE_FF),
        std.mem.nativeToBig(u32, 'a'),
        std.mem.nativeToBig(u32, 'a'),
        std.mem.nativeToBig(u32, 'a'),
        std.mem.nativeToBig(u32, '!'),
    })));
}

pub const File = union(Encoding) {
    utf8: []const u8,
    utf16: []const u16,
    utf16_reverse: []const u16,
    utf32: []const u32,
};

pub fn parse(contents: []const u8) !File {
    switch (try detectEncoding(contents)) {
        .utf8 => return .{ .utf8 = contents[3..] },
        .utf16 => return .{ .utf16 = @as([*]const u16, @ptrCast(@alignCast(contents[2..])))[0 .. contents[2..].len / @sizeOf(u16)] },
        .utf16_reverse => return .{ .utf16_reverse = @as([*]const u16, @ptrCast(@alignCast(contents[2..])))[0 .. contents[2..].len / @sizeOf(u16)] },
        .utf32 => return .{ .utf32 = @as([*]const u32, @ptrCast(@alignCast(contents[4..])))[0 .. contents[4..].len / @sizeOf(u32)] },
    }
}

const testing = std.testing;
const std = @import("std");
