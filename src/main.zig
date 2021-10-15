const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const eql = mem.eql;
const ascii = std.ascii;

pub fn traverseBraces(data: []const u8, comptime up: []const u8, comptime down: []const u8, comptime until: []const u8) usize {
    var level: usize = 0;
    var i: usize = 0;
    blk: while (i < data.len) : (i += 1) {
        const cur = data[i];
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
    return i;
}

test "traverse braces" {
    testing.log_level = .debug;
    try testing.expect(traverseBraces(" ", "{", "}", "") == 1);
    const str = "some: \"hello\", stuff: [{ in: \"here\" }, { a: true }]";
    try testing.expect(traverseBraces(str, "[{", "]}", "") == str.len);
    try testing.expect(traverseBraces(str, "[{", "[}", ",") == 13);
    const slice = str[14..];
    try testing.expect(traverseBraces(slice, "[{", "]}", ",") == slice.len);
}

pub const JsonTextIterator = struct {
    data: []const u8,
    pos: usize = 0,

    const Self = @This();
    pub fn next(self: *Self) ?[]const u8 {
        if (self.pos >= self.data.len) {
            return null;
        }
        const next_pos = traverseBraces(self.data[self.pos..], "[{", "]}", ",") + self.pos;
        const item_slice = mem.trim(u8, self.data[self.pos..next_pos], ascii.spaces[0..]);
        self.pos = next_pos + 1;
        return item_slice;
    }
    pub fn reset(self: *Self) void {
        self.pos = 0;
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
    try testing.expect(eql(u8, inner_iter.next() orelse unreachable, "some: [\"stuff\"]"));
    try testing.expect(eql(u8, inner_iter.next() orelse unreachable, "here: null"));
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
        const colon_pos = traverseBraces(text, "[{", "]}", ":");
        const key_str = mem.trim(u8, text[0..colon_pos], ascii.spaces[0..]);
        const value_str = mem.trim(u8, text[colon_pos + 1 ..], ascii.spaces[0..]);
        return JsonObjectKeyValuePair{
            .key = parseJson(key_str),
            .value = parseJson(value_str),
        };
    }
    pub fn reset(self: *Self) void {
        self.data.reset();
    }
};

test "object iterator" {
    var iter = JsonObjectIterator{
        .data = JsonTextIterator{ .data = "\"hello\": \"there\", \"test\": [\"value\"]" },
    };
    try testing.expect(if (iter.next()) |pair| pair.key == JsonValue.String and eql(u8, pair.key.String, "hello") and pair.value == JsonValue.String and eql(u8, pair.value.String, "there") else unreachable);
    try testing.expect(if (iter.next()) |pair| pair.key == JsonValue.String and eql(u8, pair.key.String, "test") and pair.value == JsonValue.Array else unreachable);
    try testing.expect(iter.next() == null);
}

pub const JsonValue = union(enum) {
    Null: void,
    Bool: bool,
    String: []const u8,
    Number: f64,
    Array: JsonArrayIterator,
    Object: JsonObjectIterator,
};

fn parseJson(json_str: []const u8) JsonValue {
    if (eql(u8, json_str, "null")) {
        return .Null;
    } else if (eql(u8, json_str, "true")) {
        return .{ .Bool = true };
    } else if (eql(u8, json_str, "false")) {
        return .{ .Bool = false };
    } else if (json_str[0] == '"') {
        return .{ .String = json_str[1 .. json_str.len - 1] };
    } else if (json_str[0] == '[') {
        return .{ .Array = JsonArrayIterator{ .data = JsonTextIterator{ .data = json_str[1 .. json_str.len - 1] } } };
    } else if (json_str[0] == '{') {
        return .{ .Object = JsonObjectIterator{ .data = JsonTextIterator{ .data = json_str[1 .. json_str.len - 1] } } };
    } else {
        const parsed_int = std.fmt.parseInt(i64, json_str, 0) catch {
            const parsed_float = std.fmt.parseFloat(f64, json_str) catch return .Null;
            return .{ .Number = parsed_float };
        };
        return .{ .Number = @intToFloat(f64, parsed_int) };
    }
    return .Null;
}
