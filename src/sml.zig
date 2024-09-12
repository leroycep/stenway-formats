const Document = union(reliabletxt.Encoding) {
    utf8: Utf8Document,
    utf16: void,
    utf16_reverse: void,
    utf32: void,

    pub fn deinit(this: @This(), gpa: std.mem.Allocator) void {
        switch (this) {
            .utf8 => |document| document.free(gpa),
            else => std.debug.panic("unimplemented", .{}),
        }
    }
};

pub const Utf8Document = struct {
    arena: std.heap.ArenaAllocator,
    root: Element,

    pub fn deinit(this: *@This()) void {
        this.arena.deinit();
        this.root = undefined;
    }
};

pub const Element = struct {
    name: []const u8,
    attributes: []const Attribute,
    children: []const Element,
};

pub const Attribute = struct {
    name: []const u8,
    values: []const ?[]const u8,
};

pub fn parseAlloc(gpa: std.mem.Allocator, contents_any: []const u8) !Utf8Document {
    std.debug.assert(contents_any.len < std.math.maxInt(u32));

    var doc_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer doc_arena.deinit();

    // var state = ParseState.default;
    const wsv_iter_any = try wsv.parseIter(contents_any);
    var wsv_iter = wsv_iter_any.utf8;

    var root_element_name: ?[]const u8 = null;
    var root_element: ?Element = null;
    while (try wsv_iter.next()) |item| {
        switch (item) {
            .newline => {
                if (root_element_name) |name| {
                    root_element = try parseElementAlloc(gpa, doc_arena.allocator(), &wsv_iter, name);
                    root_element_name = null;
                }
            },
            .value => |value| {
                if (root_element != null) return error.InvalidFormat; // Value after root element ended
                if (root_element_name != null) return error.InvalidFormat; // Attribute before root element

                root_element_name = try doc_arena.allocator().dupe(u8, value);
            },
            .string => |encoded_string| {
                if (root_element != null) return error.InvalidFormat; // Value after root element ended
                if (root_element_name != null) return error.InvalidFormat; // Multiple root elements

                const decode_buffer = try gpa.alloc(u8, encoded_string.len);
                defer gpa.free(decode_buffer);

                const decoded_string = try wsv.decodeString(encoded_string, decode_buffer);
                root_element_name = try doc_arena.allocator().dupe(u8, decoded_string);
            },
            .null => return error.InvalidFormat, // Element ended before starting
        }
    }

    const root = root_element orelse return error.InvalidFormat; // No root element

    return Utf8Document{
        .arena = doc_arena,
        .root = root,
    };
}

pub fn parseElementAlloc(gpa: std.mem.Allocator, doc_arena: std.mem.Allocator, wsv_iter: *wsv.Utf8Iterator, name: []const u8) !Element {
    // values that will be returned
    var children = std.ArrayListUnmanaged(Element){};
    var attributes = std.ArrayListUnmanaged(Attribute){};
    var values = std.ArrayListUnmanaged(?[]const u8){};

    defer {
        children.deinit(gpa);
        attributes.deinit(gpa);
        values.deinit(gpa);
    }

    while (try wsv_iter.next()) |item| {
        switch (item) {
            .newline => {
                if (values.items.len == 0) continue;
                if (values.items.len == 1) {
                    // an element
                    const value = values.items[0];

                    if (value == null or std.ascii.eqlIgnoreCase(value.?, "end")) {
                        const arena_attributes = try doc_arena.dupe(Attribute, attributes.items);
                        const arena_children = try doc_arena.dupe(Element, children.items);
                        return Element{
                            .name = name,
                            .attributes = arena_attributes,
                            .children = arena_children,
                        };
                    } else {
                        values.shrinkRetainingCapacity(0);
                        const child = try parseElementAlloc(gpa, doc_arena, wsv_iter, value.?);
                        try children.append(gpa, child);
                        continue;
                    }
                }

                try attributes.append(gpa, .{
                    .name = values.items[0] orelse return error.InvalidFormat, // Attribute names cannot be null
                    .values = try doc_arena.dupe(?[]const u8, values.items[1..]),
                });
                values.shrinkRetainingCapacity(0);
            },
            .value => |value| try values.append(gpa, try doc_arena.dupe(u8, value)),
            .string => |encoded_string| {
                const decode_buffer = try gpa.alloc(u8, encoded_string.len);
                defer gpa.free(decode_buffer);

                const decoded_string = try wsv.decodeString(encoded_string, decode_buffer);
                try values.append(gpa, try doc_arena.dupe(u8, decoded_string));
            },
            .null => try values.append(gpa, null),
        }
    }

    if (values.items.len != 1) return error.InvalidFormat; // Missing end of element
    const value = values.items[0];

    if (value == null or std.ascii.eqlIgnoreCase(value.?, "end")) {
        const arena_attributes = try doc_arena.dupe(Attribute, attributes.items);
        const arena_children = try doc_arena.dupe(Element, children.items);
        return Element{
            .name = name,
            .attributes = arena_attributes,
            .children = arena_children,
        };
    } else {
        return error.InvalidFormat; // An element is starting... but we just reached the end of the source contents.
    }
}

pub fn expectEqualElements(expected_element: Element, actual_element: Element) !void {
    try std.testing.expectEqualStrings(expected_element.name, actual_element.name);
    errdefer std.debug.print("in \"{}\"\n", .{std.zig.fmtEscapes(expected_element.name)});

    if (actual_element.attributes.len != expected_element.attributes.len) {
        std.debug.print("expected attributes:", .{});
        for (expected_element.attributes) |attribute| {
            std.debug.print(" \"{}\"", .{std.zig.fmtEscapes(attribute.name)});
        }
        std.debug.print("\n", .{});
        std.debug.print("  actual attributes:", .{});
        for (actual_element.attributes) |attribute| {
            std.debug.print(" \"{}\"", .{std.zig.fmtEscapes(attribute.name)});
        }
        std.debug.print("\n", .{});
        return error.ExpectedEqual;
    }

    if (actual_element.children.len != expected_element.children.len) {
        std.debug.print("expected children:", .{});
        for (expected_element.children) |element| {
            std.debug.print(" \"{}\"", .{std.zig.fmtEscapes(element.name)});
        }
        std.debug.print("\n", .{});
        std.debug.print("  actual children:", .{});
        for (actual_element.children) |element| {
            std.debug.print(" \"{}\"", .{std.zig.fmtEscapes(element.name)});
        }
        std.debug.print("\n", .{});
        return error.ExpectedEqual;
    }

    for (expected_element.attributes, actual_element.attributes) |expected_attribute, actual_attribute| {
        try expectEqualNullableStrings(expected_attribute.name, actual_attribute.name);
        if (actual_attribute.values.len != expected_attribute.values.len) {
            std.debug.print("attribute values lengths do not match: {} != {}\n", .{ expected_attribute.values.len, actual_attribute.values.len });
            std.debug.print("expected attributes:", .{});
            for (expected_attribute.values) |value_opt| {
                if (value_opt) |value| {
                    std.debug.print(" \"{}\"", .{std.zig.fmtEscapes(value)});
                } else {
                    std.debug.print(" null", .{});
                }
            }
            std.debug.print("\n", .{});
            std.debug.print("  actual attributes:", .{});
            for (actual_attribute.values) |value_opt| {
                if (value_opt) |value| {
                    std.debug.print(" \"{}\"", .{std.zig.fmtEscapes(value)});
                } else {
                    std.debug.print(" null", .{});
                }
            }
            std.debug.print("\n", .{});
            return error.ExpectedEqual;
        }

        for (expected_attribute.values, actual_attribute.values) |expected_value, actual_value| {
            try expectEqualNullableStrings(expected_value, actual_value);
        }
    }

    for (expected_element.children, actual_element.children) |expected_child, actual_child| {
        try expectEqualElements(expected_child, actual_child);
    }
}

fn expectEqualNullableStrings(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected == null and actual == null) return;
    if (expected == null or actual == null) {
        std.debug.print("values do not match: ", .{});
        if (expected) |s| {
            std.debug.print("{} != ", .{std.zig.fmtEscapes(s)});
        } else {
            std.debug.print("null != ", .{});
        }
        if (actual) |s| {
            std.debug.print("{} != ", .{std.zig.fmtEscapes(s)});
        } else {
            std.debug.print("null != ", .{});
        }
        return error.ExpectedEqual;
    }
    try std.testing.expectEqualStrings(expected.?, actual.?);
}

test "minimal document" {
    var parsed_document = try parseAlloc(std.testing.allocator, [3]u8{ 0xEF, 0xBB, 0xBF } ++
        \\R
        \\-
    );
    defer parsed_document.deinit();
    try expectEqualElements(Element{
        .name = "R",
        .attributes = &.{},
        .children = &.{},
    }, parsed_document.root);
}

test "special characters in element and attribute names" {
    var parsed_document = try parseAlloc(std.testing.allocator, [3]u8{ 0xEF, 0xBB, 0xBF } ++
        \\"My Root Element"
        \\  "My First Attribute" 123
        \\End
        \\
    );
    defer parsed_document.deinit();
    try expectEqualElements(Element{
        .name = "My Root Element",
        .attributes = &.{
            Attribute{ .name = "My First Attribute", .values = &.{"123"} },
        },
        .children = &.{},
    }, parsed_document.root);
}

test "Game Configuration" {
    var parsed_document = try parseAlloc(std.testing.allocator, @embedFile("./testdata_sml/Example01_Game_Config.sml"));
    defer parsed_document.deinit();
    try expectEqualElements(Element{
        .name = "Configuration",
        .attributes = &.{},
        .children = &.{
            Element{
                .name = "Video",
                .attributes = &.{
                    Attribute{ .name = "Resolution", .values = &.{ "1280", "720" } },
                    Attribute{ .name = "RefreshRate", .values = &.{"60"} },
                    Attribute{ .name = "Fullscreen", .values = &.{"true"} },
                },
                .children = &.{},
            },
            Element{
                .name = "Audio",
                .attributes = &.{
                    Attribute{ .name = "Volume", .values = &.{"100"} },
                    Attribute{ .name = "Music", .values = &.{"80"} },
                },
                .children = &.{},
            },
            Element{
                .name = "Player",
                .attributes = &.{
                    Attribute{ .name = "Name", .values = &.{"Hero 123"} },
                },
                .children = &.{},
            },
        },
    }, parsed_document.root);
}

const wsv = @import("./wsv.zig");
const reliabletxt = @import("./reliabletxt.zig");
const testing = std.testing;
const std = @import("std");
