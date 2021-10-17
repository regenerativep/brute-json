const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const eql = mem.eql;
const ascii = std.ascii;

/// Finds the end index of the first section of the provided array
/// ex: input "1, 2, 3" with until = ",", it will find index 2 since that is where the first comma is
/// specifying up and down will make it so that until values are ignored at nested levels, or
/// if we reach a level lower than where we started
pub fn traverseBraces(data: []const u8, comptime up: []const u8, comptime down: []const u8, comptime until: []const u8, comptime alt: []const u8, comptime alt_escape: u8) usize {
    var level: usize = 0;
    var i: usize = 0;
    var in_alt: ?u8 = null;
    var last_c: ?u8 = null;
    blk: while (i < data.len) : (i += 1) {
        const cur = data[i];
        if (in_alt) |current_alt| {
            if (cur == current_alt and if (last_c) |last_c_val| last_c_val != alt_escape else true) {
                in_alt = null;
            }
        } else {
            inline for (alt) |c| {
                if (cur == c) {
                    in_alt = c;
                }
            }
            inline for (up) |c| {
                if (cur == c) {
                    level += 1;
                }
            }
            inline for (down) |c| {
                if (cur == c) {
                    if (level == 0) {
                        break :blk;
                    } else {
                        level -= 1;
                    }
                }
            }
            if (level == 0) {
                inline for (until) |c| {
                    if (cur == c) {
                        break :blk;
                    }
                }
            }
        }
        last_c = cur;
    }
    return i;
}

test "traverse braces" {
    testing.log_level = .debug;
    try testing.expect(traverseBraces(" ", "{", "}", "", "\"'", '\\') == 1);
    const str = "some: \"hello\", stuff: [{ in: \"here\" }, { a: true }]";
    try testing.expect(traverseBraces(str, "[{", "]}", "", "\"'", '\\') == str.len);
    try testing.expect(traverseBraces(str, "[{", "]}", ",", "\"'", '\\') == 13);
    const slice = str[14..];
    try testing.expect(traverseBraces(slice, "[{", "]}", ",", "\"'", '\\') == slice.len);

    try testing.expect(traverseBraces("\"hello\": \"ther,e}\", \"person\": null", "[{", "]}", ",", "\"'", '\\') == 18);
}

pub const JsonTextIterator = struct {
    data: []const u8,
    pos: usize = 0,

    const Self = @This();
    pub fn next(self: *Self) ?[]const u8 {
        if (self.pos >= self.data.len) {
            return null;
        }
        const next_pos = traverseBraces(self.data[self.pos..], "[{", "]}", ",", "\"'", '\\') + self.pos;
        const item_slice = self.data[self.pos..next_pos];
        self.pos = next_pos + 1;
        return item_slice;
    }
    pub fn reset(self: *Self) void {
        self.pos = 0;
    }
    pub fn size(self: *const Self) usize {
        var temp_iter = JsonTextIterator{
            .data = self.data,
            .pos = 0,
        };
        var count: usize = 0;
        while (temp_iter.next() != null) {
            count += 1;
        }
        return count;
    }
};

test "text iterator" {
    testing.log_level = .debug;
    var iter = JsonTextIterator{
        .data = "{}",
        .pos = 0,
    };
    var next_item = iter.next();
    try testing.expect(next_item != null);
    if (next_item) |item| {
        try testing.expect(eql(u8, item, "{}"));
    }
    iter = JsonTextIterator{
        .data = "{ some: [\"stuff\"], here: null }",
        .pos = 0,
    };
    try testing.expect(eql(u8, iter.next() orelse unreachable, "{ some: [\"stuff\"], here: null }"));
    iter.reset();
    const next = iter.next() orelse unreachable;
    var inner_iter = JsonTextIterator{ .data = next[1 .. next.len - 1], .pos = 0 };
    try testing.expect(eql(u8, inner_iter.next() orelse unreachable, " some: [\"stuff\"]"));
    try testing.expect(eql(u8, inner_iter.next() orelse unreachable, " here: null "));
}

pub const JsonArrayIterator = struct {
    data: JsonTextIterator,
    const Self = @This();

    pub fn next(self: *Self) ?JsonValue {
        return parseJson(self.data.next() orelse return null);
    }
    pub fn reset(self: *Self) void {
        self.data.reset();
    }
    pub fn size(self: *const Self) usize {
        return self.data.size();
    }
};

test "array iterator" {
    var iter = JsonArrayIterator{
        .data = JsonTextIterator{ .data = "1, 2, 3, 4" },
    };
    try testing.expect(if (iter.next()) |val| val == JsonValue.Number and val.Number == 1 else unreachable);
    try testing.expect(if (iter.next()) |val| val == JsonValue.Number and val.Number == 2 else unreachable);
    try testing.expect(if (iter.next()) |val| val == JsonValue.Number and val.Number == 3 else unreachable);
    try testing.expect(if (iter.next()) |val| val == JsonValue.Number and val.Number == 4 else unreachable);
    try testing.expect(iter.next() == null);
    try testing.expect(iter.size() == 4);
}

pub const JsonObjectKeyValuePair = struct {
    key: JsonValue,
    value: JsonValue,
};
pub const JsonObjectIterator = struct {
    data: JsonTextIterator,
    const Self = @This();

    pub fn next(self: *Self) ?JsonObjectKeyValuePair {
        const text = self.data.next() orelse return null;
        const colon_pos = traverseBraces(text, "[{", "]}", ":", "\"'", '\\');
        if (colon_pos >= text.len) {
            return null;
        }
        const key_str = text[0..colon_pos];
        const value_str = text[colon_pos + 1 ..];
        return JsonObjectKeyValuePair{
            .key = parseJson(key_str),
            .value = parseJson(value_str),
        };
    }
    pub fn reset(self: *Self) void {
        self.data.reset();
    }
    pub fn size(self: *const Self) usize {
        return self.data.size();
    }
};

test "object iterator" {
    var iter = JsonObjectIterator{
        .data = JsonTextIterator{ .data = "\"hello\": \"there\", \"test\": [\"value\"]" },
    };
    try testing.expect(if (iter.next()) |pair| pair.key == JsonValue.String and eql(u8, pair.key.String, "hello") and pair.value == JsonValue.String and eql(u8, pair.value.String, "there") else unreachable);
    try testing.expect(if (iter.next()) |pair| pair.key == JsonValue.String and eql(u8, pair.key.String, "test") and pair.value == JsonValue.Array else unreachable);
    try testing.expect(iter.next() == null);
    var iter2 = JsonObjectIterator{
        .data = JsonTextIterator{ .data = " " },
    };
    try testing.expect(iter2.next() == null);
}

pub const JsonValue = union(enum) {
    Null: void,
    Bool: bool,
    String: []const u8,
    Number: f64,
    Array: JsonArrayIterator,
    Object: JsonObjectIterator,
};

/// given the provided text, parse json into a JsonValue
pub fn parseJson(json_str: []const u8) JsonValue {
    var trimmed_str = mem.trim(u8, json_str, ascii.spaces[0..]);
    if (eql(u8, trimmed_str, "null")) {
        return .Null;
    } else if (eql(u8, trimmed_str, "true")) {
        return .{ .Bool = true };
    } else if (eql(u8, trimmed_str, "false")) {
        return .{ .Bool = false };
    } else if (trimmed_str[0] == '"') {
        return .{ .String = trimmed_str[1 .. trimmed_str.len - 1] };
    } else if (trimmed_str[0] == '[') {
        return .{ .Array = JsonArrayIterator{ .data = JsonTextIterator{ .data = trimmed_str[1 .. trimmed_str.len - 1] } } };
    } else if (trimmed_str[0] == '{') {
        return .{ .Object = JsonObjectIterator{ .data = JsonTextIterator{ .data = trimmed_str[1 .. trimmed_str.len - 1] } } };
    } else {
        const parsed_int = std.fmt.parseInt(i64, trimmed_str, 0) catch {
            const parsed_float = std.fmt.parseFloat(f64, trimmed_str) catch return .Null;
            return .{ .Number = parsed_float };
        };
        return .{ .Number = @intToFloat(f64, parsed_int) };
    }
    return .Null;
}
