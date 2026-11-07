/// A string along with the mapping of each individual byte in the string
/// to the point in the screen.
const StringMap = @This();

const std = @import("std");
const build_options = @import("terminal_options");
const oni = @import("oniguruma");
const point = @import("point.zig");
const PinMap = @import("formatter.zig").PinMap;
const Selection = @import("Selection.zig");
const Screen = @import("Screen.zig");
const Pin = @import("PageList.zig").Pin;
const Allocator = std.mem.Allocator;

// Retry budget for StringMap regex searches.
//
// Units are Oniguruma retry steps (internal backtracking/retry counter),
// not bytes/characters/time.
const oni_search_retry_limit = 100_000;

string: [:0]const u8,

/// Mapping of string byte offsets to pins. See PinMap for the
/// storage details.
map: PinMap.Map,

pub fn deinit(self: StringMap, alloc: Allocator) void {
    alloc.free(self.string);
    var map = self.map;
    map.deinit(alloc);
}

/// A range of UTF-8 bytes in the flattened screen text.
pub const ByteRange = struct {
    start: usize,
    len: usize,
};

/// Returns the full byte range covered by the selection's endpoint cells.
/// Multiple UTF-8 bytes may map to the same cell, so include all bytes of
/// both endpoints. Reversed selections produce the same range.
pub fn rangeForSelection(self: StringMap, screen: *const Screen, sel: Selection) ?ByteRange {
    const start_pin = sel.topLeft(screen);
    const end_pin = sel.bottomRight(screen);
    var start_idx: ?usize = null;
    var end_idx: ?usize = null;
    for (0..self.map.count()) |idx| {
        const pin = self.map.get(idx).?;
        if (start_idx == null and pin.node == start_pin.node and pin.x == start_pin.x and pin.y == start_pin.y) {
            start_idx = idx;
        }
        if (pin.node == end_pin.node and pin.x == end_pin.x and pin.y == end_pin.y) {
            end_idx = idx;
        }
    }
    const start = start_idx orelse return null;
    const end = end_idx orelse return null;
    if (end < start) return null;
    return .{ .start = start, .len = end - start + 1 };
}

/// Maps a nonempty byte range to its endpoint cells. Clamp a range that
/// extends past the map, and reject an empty range or an invalid start.
pub fn selectionForRange(self: StringMap, start: usize, len: usize) ?Selection {
    const count = self.map.count();
    if (len == 0 or start >= count) return null;
    const end = start + @min(len, count - start) - 1;
    return Selection.init(self.map.get(start).?, self.map.get(end).?, false);
}

/// Where a byte of the string is drawn in the viewport. A newline sits on
/// the row it ends, just after that row's last cell, with zero width.
pub const ViewportCell = extern struct {
    row: u16,
    col: u16,
    width: u16,
};

/// The cursor's offset and the viewport cells of a map built over the
/// whole screen with soft wraps joined (see Screen.selectionStringMap).
pub const Layout = struct {
    /// Byte offset of the cursor: the first byte at or after its cell. A
    /// cursor past the end of its row's text sits on the row's newline.
    cursor: usize,

    /// Byte offset of the first byte drawn in the viewport.
    viewport_start: usize,

    /// The cell of each byte from viewport_start on, up to the last byte
    /// drawn in the viewport.
    viewport: []ViewportCell,

    pub fn deinit(self: Layout, alloc: Allocator) void {
        alloc.free(self.viewport);
    }
};

/// Maps the cursor to a byte offset and the viewport's bytes to cells.
/// Newline bytes are placed by counting rows rather than by their map
/// entries, which point at the next page's first row at page boundaries.
pub fn layout(
    self: StringMap,
    alloc: Allocator,
    screen: *const Screen,
    cursor: Pin,
) Allocator.Error!Layout {
    const pages = &screen.pages;
    const cursor_pt: point.Coordinate = if (pages.pointFromPin(.screen, cursor)) |pt|
        pt.coord()
    else
        .{ .x = 0, .y = std.math.maxInt(u32) };
    const vp_top: i64 = if (pages.pointFromPin(.screen, pages.getTopLeft(.viewport))) |pt|
        pt.coord().y
    else
        0;
    const vp_end = vp_top + pages.rows;

    var cells: std.ArrayList(ViewportCell) = .empty;
    errdefer cells.deinit(alloc);
    var cursor_offset: ?usize = null;
    var viewport_start: ?usize = null;

    // Walk the page list alongside the map's node runs so each byte's
    // screen row is its page's first screen row plus its page row.
    const tl = pages.getTopLeft(.screen);
    var node = tl.node;
    var node_row: i64 = -@as(i64, tl.y);
    var run: usize = 0;

    // The previous byte's position. Start as if a newline ended the row
    // above the screen, so leading newlines land on rows 0, 1, ...
    var row: i64 = -1;
    var col: u32 = 0;
    var width: u32 = 0;
    var after_newline = true;

    for (self.string, 0..) |byte, i| {
        if (byte == '\n') {
            if (after_newline) {
                row += 1;
                col = 0;
            } else col += width;
            width = 0;
            after_newline = true;
        } else {
            const runs = self.map.nodes.items;
            while (run + 1 < runs.len and runs[run + 1].offset <= i) run += 1;
            while (node != runs[run].node) {
                node_row += node.rows();
                node = node.next orelse break;
            }
            const coord = self.map.points.items[i];
            row = node_row + coord.y;
            col = coord.x;
            width = 1;
            if (row >= vp_top and row < vp_end) {
                const cell = node.page().getRowAndCell(coord.x, coord.y).cell;
                if (cell.wide == .wide) width = 2;
            }
            after_newline = false;
        }

        if (cursor_offset == null) {
            const before = row < cursor_pt.y or
                (byte != '\n' and row == cursor_pt.y and col < cursor_pt.x);
            if (!before) cursor_offset = i;
        }

        if (row >= vp_end) {
            if (cursor_offset != null) break;
            continue;
        }
        if (row < vp_top) continue;
        if (viewport_start == null) viewport_start = i;
        try cells.append(alloc, .{
            .row = @intCast(row - vp_top),
            .col = @intCast(col),
            .width = @intCast(width),
        });
    }

    return .{
        .cursor = cursor_offset orelse self.string.len,
        .viewport_start = viewport_start orelse self.string.len,
        .viewport = try cells.toOwnedSlice(alloc),
    };
}

/// Returns an iterator that yields the next match of the given regex.
/// Requires Ghostty to be compiled with regex support.
pub const searchIterator = if (build_options.oniguruma)
    searchIteratorOni
else
    void;

fn searchIteratorOni(
    self: StringMap,
    regex: oni.Regex,
) SearchIterator {
    return .{ .map = self, .regex = regex };
}

/// Iterates over the regular expression matches of the string.
pub const SearchIterator = struct {
    map: StringMap,
    regex: oni.Regex,
    offset: usize = 0,

    /// Returns the next regular expression match or null if there are
    /// no more matches.
    pub fn next(self: *SearchIterator) !?Match {
        if (self.offset >= self.map.string.len) return null;

        // Use per-search match params so we can bound regex retry steps
        // (Oniguruma's internal backtracking work counter).
        var match_param = try oni.MatchParam.init();
        defer match_param.deinit();
        try match_param.setRetryLimitInSearch(oni_search_retry_limit);

        var region = self.regex.searchWithParam(
            self.map.string[self.offset..],
            .{},
            &match_param,
        ) catch |err| switch (err) {
            // Retry/stack-limit errors mean we hit our work budget and
            // aborted matching.
            // For iterator callers this is equivalent to "no further matches".
            error.Mismatch,
            error.RetryLimitInMatchOver,
            error.RetryLimitInSearchOver,
            error.MatchStackLimitOver,
            error.SubexpCallLimitInSearchOver,
            => {
                self.offset = self.map.string.len;
                return null;
            },

            else => return err,
        };
        errdefer region.deinit();

        // Increment our offset by the number of bytes in the match.
        // We defer this so that we can return the match before
        // modifying the offset.
        const end_idx: usize = @intCast(region.ends()[0]);
        defer self.offset += end_idx;

        return .{
            .map = self.map,
            .offset = self.offset,
            .region = region,
        };
    }
};

/// A single regular expression match.
pub const Match = struct {
    map: StringMap,
    offset: usize,
    region: oni.Region,

    pub fn deinit(self: *Match) void {
        self.region.deinit();
    }

    /// Returns the selection containing the full match.
    pub fn selection(self: Match) Selection {
        const start_idx: usize = @intCast(self.region.starts()[0]);
        const end_idx: usize = @intCast(self.region.ends()[0] - 1);
        const start_pt = self.map.map.get(self.offset + start_idx).?;
        const end_pt = self.map.map.get(self.offset + end_idx).?;
        return .init(start_pt, end_pt, false);
    }
};

test "StringMap searchIterator" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // Initialize our regex
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        "[A-B]{2}",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // Initialize our screen
    var s = try Screen.init(io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);
    const line = s.selectLine(.{
        .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).?,
    }).?;
    const map = try s.selectionStringMap(alloc, .{
        .sel = line,
        .trim = false,
    });
    defer map.deinit(alloc);

    // Get our iterator
    var it = map.searchIterator(re);
    {
        var match = (try it.next()).?;
        defer match.deinit();

        const sel = match.selection();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    try testing.expect(try it.next() == null);
}

test "StringMap searchIterator URL detection" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const url = @import("../config/url.zig");

    // Initialize URL regex
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        url.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // Initialize our screen with text containing a URL
    var s = try Screen.init(io, alloc, .{ .cols = 40, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("hello https://example.com/path world");

    // Get the line
    const line = s.selectLine(.{
        .pin = s.pages.pin(.{ .active = .{
            .x = 10,
            .y = 0,
        } }).?,
    }).?;
    const map = try s.selectionStringMap(alloc, .{
        .sel = line,
        .trim = false,
    });
    defer map.deinit(alloc);

    // Search for URL match
    var it = map.searchIterator(re);
    {
        var match = (try it.next()).?;
        defer match.deinit();

        const sel = match.selection();
        // URL should start at x=6 ("https://example.com/path" starts after "hello ")
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 6,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        // URL should end at x=29 (end of "/path")
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 29,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    try testing.expect(try it.next() == null);
}

test "StringMap searchIterator URL with click position" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const url = @import("../config/url.zig");

    // Initialize URL regex
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        url.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // Initialize our screen with text containing a URL
    var s = try Screen.init(io, alloc, .{ .cols = 40, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("hello https://example.com world");

    // Simulate clicking on "example" (x=14)
    const click_pin = s.pages.pin(.{ .active = .{
        .x = 14,
        .y = 0,
    } }).?;

    // Get the line
    const line = s.selectLine(.{
        .pin = click_pin,
    }).?;
    const map = try s.selectionStringMap(alloc, .{
        .sel = line,
        .trim = false,
    });
    defer map.deinit(alloc);

    // Search for URL match and verify click position is within URL
    var it = map.searchIterator(re);
    var found_url = false;
    while (true) {
        var match = (try it.next()) orelse break;
        defer match.deinit();

        const sel = match.selection();
        if (sel.contains(&s, click_pin)) {
            found_url = true;
            // Verify URL bounds
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 6,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 24,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
            break;
        }
    }
    try testing.expect(found_url);
}

test "StringMap accessibility ranges across wrapped lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var screen = try Screen.init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback_bytes = 0,
    });
    defer screen.deinit();
    try screen.testWriteString("abcdeFGHIJ");
    const map = try screen.selectionStringMap(alloc, .{
        .sel = .init(screen.pages.getTopLeft(.screen), screen.pages.getBottomRight(.screen).?, false),
        .trim = false,
    });
    defer map.deinit(alloc);

    const sel = map.selectionForRange(3, 5).?;
    try testing.expectEqual(point.Point{ .active = .{ .x = 3, .y = 0 } }, screen.pages.pointFromPin(.active, sel.start()).?);
    try testing.expectEqual(point.Point{ .active = .{ .x = 2, .y = 1 } }, screen.pages.pointFromPin(.active, sel.end()).?);
    try testing.expectEqual(ByteRange{ .start = 3, .len = 5 }, map.rangeForSelection(&screen, sel).?);
    const reversed = Selection.init(sel.end(), sel.start(), false);
    try testing.expectEqual(ByteRange{ .start = 3, .len = 5 }, map.rangeForSelection(&screen, reversed).?);
}

test "StringMap accessibility ranges preserve Unicode endpoint cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var screen = try Screen.init(testing.io, alloc, .{
        .cols = 20,
        .rows = 2,
        .max_scrollback_bytes = 0,
    });
    defer screen.deinit();
    try screen.testWriteString("aé界e\u{301}😀z");
    const map = try screen.selectionStringMap(alloc, .{
        .sel = .init(screen.pages.getTopLeft(.screen), screen.pages.getBottomRight(.screen).?, false),
        .trim = false,
    });
    defer map.deinit(alloc);

    // é, CJK, a combining grapheme, and emoji occupy 12 UTF-8 bytes.
    const sel = map.selectionForRange(1, 12).?;
    try testing.expectEqual(ByteRange{ .start = 1, .len = 12 }, map.rangeForSelection(&screen, sel).?);
    const text = try screen.selectionString(alloc, .{ .sel = sel, .trim = false });
    defer alloc.free(text);
    try testing.expectEqualStrings("é界e\u{301}😀", text);

    // A byte within a multibyte scalar still selects its entire cell.
    const partial = map.selectionForRange(2, 1).?;
    try testing.expectEqual(ByteRange{ .start = 1, .len = 2 }, map.rangeForSelection(&screen, partial).?);
}

test "StringMap accessibility ranges reject invalid starts and clamp length" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var screen = try Screen.init(testing.io, alloc, .{
        .cols = 3,
        .rows = 2,
        .max_scrollback_bytes = 0,
    });
    defer screen.deinit();
    try screen.testWriteString("abc");
    const line = screen.selectLine(.{ .pin = screen.pages.getTopLeft(.active) }).?;
    const map = try screen.selectionStringMap(alloc, .{ .sel = line, .trim = false });
    defer map.deinit(alloc);

    try testing.expect(map.selectionForRange(0, 0) == null);
    try testing.expect(map.selectionForRange(map.map.count(), 1) == null);
    try testing.expect(map.selectionForRange(std.math.maxInt(usize), 1) == null);
    const clamped = map.selectionForRange(1, std.math.maxInt(usize)).?;
    try testing.expectEqual(ByteRange{ .start = 1, .len = 2 }, map.rangeForSelection(&screen, clamped).?);

    // A selection outside this map has no byte range in it.
    const outside_pin = screen.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?;
    try testing.expect(map.rangeForSelection(&screen, .init(outside_pin, outside_pin, false)) == null);
    const empty: StringMap = .{ .string = "", .map = .empty };
    try testing.expect(empty.selectionForRange(0, 1) == null);
}

fn testLayout(s: *Screen, cursor_x: u16, cursor_y: u32) !struct { StringMap, Layout } {
    const alloc = std.testing.allocator;
    const map = try s.selectionStringMap(alloc, .{
        .sel = Selection.init(
            s.pages.getTopLeft(.screen),
            s.pages.getBottomRight(.screen).?,
            false,
        ),
        .trim = false,
    });
    errdefer map.deinit(alloc);
    const cursor = s.pages.pin(.{ .active = .{ .x = cursor_x, .y = cursor_y } }).?;
    return .{ map, try map.layout(alloc, s, cursor) };
}

test "StringMap layout soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try Screen.init(testing.io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD2EFGH\n3IJ");

    const cases = [_]struct { x: u16, y: u32, offset: usize }{
        .{ .x = 4, .y = 1, .offset = 9 }, // "H", the wrapped row's end
        .{ .x = 1, .y = 2, .offset = 12 }, // "I", the row after the wrap
        .{ .x = 4, .y = 2, .offset = 14 }, // past the text, at its end
    };
    for (cases) |c| {
        const map, const lay = try testLayout(&s, c.x, c.y);
        defer map.deinit(alloc);
        defer lay.deinit(alloc);
        try testing.expectEqualStrings("1ABCD2EFGH\n3IJ", map.string);
        try testing.expectEqual(c.offset, lay.cursor);
    }

    const map, const lay = try testLayout(&s, 0, 0);
    defer map.deinit(alloc);
    defer lay.deinit(alloc);
    try testing.expectEqual(0, lay.viewport_start);
    try testing.expectEqual(map.string.len, lay.viewport.len);
    try testing.expectEqual(ViewportCell{ .row = 0, .col = 4, .width = 1 }, lay.viewport[4]);
    try testing.expectEqual(ViewportCell{ .row = 1, .col = 0, .width = 1 }, lay.viewport[5]);
    try testing.expectEqual(ViewportCell{ .row = 1, .col = 5, .width = 0 }, lay.viewport[10]);
    try testing.expectEqual(ViewportCell{ .row = 2, .col = 1, .width = 1 }, lay.viewport[12]);
}

test "StringMap layout trailing blanks and blank rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try Screen.init(testing.io, alloc, .{ .cols = 5, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ab\n\ncd");

    const cases = [_]struct { x: u16, y: u32, offset: usize }{
        .{ .x = 4, .y = 0, .offset = 2 }, // past "ab": on its newline
        .{ .x = 0, .y = 1, .offset = 3 }, // the blank row's start
        .{ .x = 3, .y = 1, .offset = 3 },
        .{ .x = 1, .y = 2, .offset = 5 }, // "d"
    };
    for (cases) |c| {
        const map, const lay = try testLayout(&s, c.x, c.y);
        defer map.deinit(alloc);
        defer lay.deinit(alloc);
        try testing.expectEqualStrings("ab\n\ncd", map.string);
        try testing.expectEqual(c.offset, lay.cursor);
        try testing.expectEqual(ViewportCell{ .row = 0, .col = 2, .width = 0 }, lay.viewport[2]);
        try testing.expectEqual(ViewportCell{ .row = 1, .col = 0, .width = 0 }, lay.viewport[3]);
        try testing.expectEqual(ViewportCell{ .row = 2, .col = 0, .width = 1 }, lay.viewport[4]);
    }
}

test "StringMap layout wide character" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try Screen.init(testing.io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("a中b");

    const map, const lay = try testLayout(&s, 3, 0);
    defer map.deinit(alloc);
    defer lay.deinit(alloc);
    try testing.expectEqualStrings("a中b", map.string);
    try testing.expectEqual(4, lay.cursor); // "b" sits after two cells of 中
    for (1..4) |i| {
        try testing.expectEqual(ViewportCell{ .row = 0, .col = 1, .width = 2 }, lay.viewport[i]);
    }
    try testing.expectEqual(ViewportCell{ .row = 0, .col = 3, .width = 1 }, lay.viewport[4]);
}

test "StringMap layout scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try Screen.init(testing.io, alloc, .{ .cols = 5, .rows = 3, .max_scrollback_bytes = 10_000 });
    defer s.deinit();
    try s.testWriteString("l1\nl2\nl3\nl4\nl5");

    // Active rows are screen rows 2-4; the text starts at screen row 0.
    const map, const lay = try testLayout(&s, 1, 2);
    defer map.deinit(alloc);
    defer lay.deinit(alloc);
    try testing.expectEqualStrings("l1\nl2\nl3\nl4\nl5", map.string);
    try testing.expectEqual(13, lay.cursor); // "5"
    try testing.expectEqual(6, lay.viewport_start); // "l3"
    try testing.expectEqual(map.string.len - 6, lay.viewport.len);
    try testing.expectEqual(ViewportCell{ .row = 0, .col = 0, .width = 1 }, lay.viewport[0]);
    try testing.expectEqual(ViewportCell{ .row = 0, .col = 2, .width = 0 }, lay.viewport[2]);
    try testing.expectEqual(ViewportCell{ .row = 2, .col = 1, .width = 1 }, lay.viewport[7]);
}
