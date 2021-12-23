const std = @import("std");
const testing = std.testing;

pub const JsonCharacterIterator = struct {
    text: []const u8,
    pos: usize = 0,
    closer: u8 = '"',

    pub const JsonCharacterIteratorError = error{
        InvalidEscapeSequence,
        InvalidCloser,
    };

    const Self = @This();
    pub fn next(self: *Self) JsonCharacterIteratorError!?u8 {
        if (self.pos == 0 and self.text.len > 0) {
            if (self.text[self.pos] == '\'') {
                self.closer = '\'';
            } else if (self.text[self.pos] != '"') {
                return JsonCharacterIteratorError.InvalidCloser;
            }
            self.pos += 1;
        }
        if (self.pos >= self.text.len) {
            return null;
        }
        if (self.text[self.pos] == '\\') {
            if (self.pos + 1 <= self.text.len) {
                self.pos += 1;
                const c = self.text[self.pos];
                self.pos += 1;
                switch (c) {
                    'b' => return 0x8,
                    'f' => return 0xC,
                    'n' => return '\n',
                    'r' => return '\r',
                    't' => return '\t',
                    '\'' => return '\'',
                    '"' => return '"',
                    '\\' => return '\\',
                    '\n' => {},
                    //'u' => {
                    //},
                    else => return JsonCharacterIteratorError.InvalidEscapeSequence,
                }
                if (self.pos + 1 >= self.text.len) {
                    return null;
                }
            } else {
                return null;
            }
        }
        const c = self.text[self.pos];
        self.pos += 1;
        if (c == self.closer) {
            return null;
        }
        return c;
    }
};

test "json character iterator" {
    var iter = JsonCharacterIterator{ .text = "\"hi\\nt\\\"\"a" };
    try testing.expect((try iter.next()).? == 'h');
    try testing.expect((try iter.next()).? == 'i');
    try testing.expect((try iter.next()).? == '\n');
    try testing.expect((try iter.next()).? == 't');
    try testing.expect((try iter.next()).? == '"');
    try testing.expect((try iter.next()) == null);
}

pub const JsonToken = union(enum) {
    OpenCurly,
    CloseCurly,
    OpenBracket,
    CloseBracket,
    String: []const u8,
    Colon,
    Comma,
    Number: f64,
    Boolean: bool,
    Null,
};

pub fn partStrEql(text: []const u8, test_str: []const u8) bool {
    if (text.len >= test_str.len) {
        return std.mem.eql(u8, text[0..test_str.len], test_str);
    }
    return false;
}

pub const JsonTokenIterator = struct {
    text: []const u8,
    pos: usize = 0,
    peeked_value: ?(JsonTokenIteratorError!?JsonToken) = null,

    pub const JsonTokenIteratorError = JsonCharacterIterator.JsonCharacterIteratorError || error{
        InvalidToken,
    };

    const Self = @This();
    pub fn next(self: *Self) JsonTokenIteratorError!?JsonToken {
        if (self.peeked_value) |val| {
            self.peeked_value = null;
            return (try val) orelse return null; // for some reason zig wont let me just return val
        }
        while (self.pos < self.text.len and std.ascii.isSpace(self.text[self.pos])) : (self.pos += 1) {}
        if (self.pos >= self.text.len) {
            return null;
        }
        switch (self.text[self.pos]) {
            '{' => {
                self.pos += 1;
                return .OpenCurly;
            },
            '}' => {
                self.pos += 1;
                return .CloseCurly;
            },
            '[' => {
                self.pos += 1;
                return .OpenBracket;
            },
            ']' => {
                self.pos += 1;
                return .CloseBracket;
            },
            ':' => {
                self.pos += 1;
                return .Colon;
            },
            ',' => {
                self.pos += 1;
                return .Comma;
            },
            '"', '\'' => {
                var iter = JsonCharacterIterator{ .text = self.text[self.pos..] };
                while ((try iter.next()) != null) {}
                const start = self.pos;
                self.pos += iter.pos;
                return JsonToken{ .String = self.text[start..self.pos] };
            },
            else => {
                if (partStrEql(self.text[self.pos..], "false")) {
                    self.pos += ("false").len;
                    return JsonToken{ .Boolean = false };
                } else if (partStrEql(self.text[self.pos..], "true")) {
                    self.pos += ("true").len;
                    return JsonToken{ .Boolean = true };
                } else if (partStrEql(self.text[self.pos..], "null")) {
                    self.pos += ("null").len;
                    return JsonToken.Null;
                } else {
                    const start = self.pos;
                    while (self.pos < self.text.len and (std.ascii.isDigit(self.text[self.pos]) or self.text[self.pos] == '.' or self.text[self.pos] == '-')) : (self.pos += 1) {}
                    return JsonToken{ .Number = std.fmt.parseFloat(f64, self.text[start..self.pos]) catch return JsonTokenIteratorError.InvalidToken };
                }
            },
        }
    }
    pub fn peek(self: *Self) JsonTokenIteratorError!?JsonToken {
        const val = self.peeked_value orelse self.next();
        self.peeked_value = val;
        return val;
    }

    // assumse that first opening bracket/curly has already been read
    pub fn untilSameLevel(self: *Self) !void {
        var level: usize = 0;
        while (try self.next()) |token| {
            switch (token) {
                .OpenCurly, .OpenBracket => level += 1,
                .CloseCurly, .CloseBracket => {
                    if (level == 0) {
                        return;
                    } else {
                        level -= 1;
                    }
                },
                else => {},
            }
        }
    }
    pub fn clone(self: *Self) JsonTokenIterator {
        return .{ .text = self.text, .pos = self.pos };
    }
};

test "token iterator" {
    var iter = JsonTokenIterator{ .text = 
    \\{
    \\  "hi": [
    \\    "there",
    \\    "person",
    \\    false
    \\  ]
    \\}
    };
    try testing.expect((try iter.next()).? == .OpenCurly);
    try testing.expect(std.mem.eql(u8, (try iter.next()).?.String, "\"hi\""));
    try testing.expect((try iter.next()).? == .Colon);
    try testing.expect((try iter.next()).? == .OpenBracket);
    try testing.expect(std.mem.eql(u8, (try iter.next()).?.String, "\"there\""));
    try testing.expect((try iter.next()).? == .Comma);
    try testing.expect(std.mem.eql(u8, (try iter.next()).?.String, "\"person\""));
    try testing.expect((try iter.next()).? == .Comma);
    try testing.expect((try iter.next()).?.Boolean == false);
    try testing.expect((try iter.next()).? == .CloseBracket);
    try testing.expect((try iter.next()).? == .CloseCurly);
    try testing.expect((try iter.next()) == null);
}

pub const JsonObjectIterator = struct {
    tokens: JsonTokenIterator,
    first: bool = true,

    pub const JsonObjectPair = struct {
        key: JsonValue,
        value: JsonValue,
    };
    const Self = @This();
    pub fn next(self: *Self) !?JsonObjectPair {
        const token = (try self.tokens.peek()) orelse return null;
        if (token == .CloseCurly) {
            return null;
        }
        if (self.first) {
            self.first = false;
        } else {
            if (token == .Comma) {
                _ = try self.tokens.next();
            }
        }
        const key = (try JsonValue.parseFromIterator(&self.tokens)) orelse return null;
        if (key != .String) {
            return JsonValue.JsonValueParseError.UnexpectedToken;
        }
        const mid_token = (try self.tokens.next()) orelse return null;
        if (mid_token != .Colon) {
            return JsonValue.JsonValueParseError.UnexpectedToken;
        }
        const value = (try JsonValue.parseFromIterator(&self.tokens)) orelse return null;
        return JsonObjectPair{
            .key = key,
            .value = value,
        };
    }
};

pub const JsonArrayIterator = struct {
    tokens: JsonTokenIterator,
    first: bool = true,

    const Self = @This();
    pub fn next(self: *Self) !?JsonValue {
        const token = (try self.tokens.peek()) orelse return null;
        if (token == .CloseBracket) {
            return null;
        }
        if (self.first) {
            self.first = false;
        } else {
            if (token == .Comma) {
                _ = try self.tokens.next();
            } else {
                return JsonValue.JsonValueParseError.UnexpectedToken;
            }
        }
        return JsonValue.parseFromIterator(&self.tokens);
    }
};

pub const JsonValue = union(enum) {
    Object: JsonObjectIterator,
    Array: JsonArrayIterator,
    Number: f64,
    Boolean: bool,
    String: JsonCharacterIterator,
    Null,

    pub const JsonValueParseError = JsonTokenIterator.JsonTokenIteratorError || error{
        UnexpectedToken,
    };

    pub fn parseFromText(text: []const u8) !JsonValue {
        var iter = JsonTokenIterator{ .text = text };
        return (parseFromIterator(&iter) catch |e| return e) orelse unreachable;
    }
    pub fn parseFromIterator(tokens: *JsonTokenIterator) JsonValueParseError!?JsonValue {
        switch ((try tokens.next()) orelse return null) {
            .OpenCurly => {
                const val = JsonValue{ .Object = JsonObjectIterator{ .tokens = tokens.clone() } };
                try tokens.untilSameLevel();
                return val;
            },
            .OpenBracket => {
                const val = JsonValue{ .Array = JsonArrayIterator{ .tokens = tokens.clone() } };
                try tokens.untilSameLevel();
                return val;
            },
            .String => |text| return JsonValue{ .String = JsonCharacterIterator{ .text = text } },
            .Number => |num| return JsonValue{ .Number = num },
            .Boolean => |val| return JsonValue{ .Boolean = val },
            .Null => return JsonValue.Null,
            else => return JsonValueParseError.UnexpectedToken,
        }
    }
};

test "json value parse" {
    var parsed = try JsonValue.parseFromText(
        \\{
        \\  "hi": 5,
        \\  "there": 6,
        \\  "person": {
        \\    "happy": null,
        \\    "crappy": [
        \\      5, 4, true
        \\    ]
        \\  }
        \\}
    );
    try testing.expect(parsed == .Object);
    var pair = (try parsed.Object.next()).?;
    try testing.expect(pair.key == .String and partStrEql(pair.key.String.text, "\"hi\""));
    try testing.expect(pair.value == .Number and pair.value.Number == 5.0);
    pair = (try parsed.Object.next()).?;
    try testing.expect(pair.key == .String and partStrEql(pair.key.String.text, "\"there\""));
    try testing.expect(pair.value == .Number and pair.value.Number == 6.0);
    pair = (try parsed.Object.next()).?;
    try testing.expect(pair.key == .String and partStrEql(pair.key.String.text, "\"person\""));
    try testing.expect(pair.value == .Object);
    var obj = pair.value.Object;
    pair = (try obj.next()).?;
    try testing.expect(pair.key == .String and partStrEql(pair.key.String.text, "\"happy\""));
    try testing.expect(pair.value == .Null);
    pair = (try obj.next()).?;
    try testing.expect(pair.key == .String and partStrEql(pair.key.String.text, "\"crappy\""));
    try testing.expect(pair.value == .Array);
    try testing.expect((try obj.next()) == null);
    var elem = (try pair.value.Array.next()).?;
    try testing.expect(elem.Number == 5.0);
    elem = (try pair.value.Array.next()).?;
    try testing.expect(elem.Number == 4.0);
    elem = (try pair.value.Array.next()).?;
    try testing.expect(elem.Boolean == true);
    try testing.expect((try pair.value.Array.next()) == null);

    try testing.expect((try parsed.Object.next()) == null);
}
