//! Cold-path helpers for `ag` semantic copy and message navigation.
//!
//! `ag` prints `ghostty-phil://msg?…` OSC 8 anchors on each committed message.
//! On an explicit copy we snapshot the selection's geometry plus the anchors
//! around it so the macOS app can ask `ag` for the Markdown behind it; on
//! navigation we find an anchor and scroll to it. Everything here reads the
//! screen through public `terminal` APIs; callers must hold the renderer
//! mutex. See ~/bin/docs/ghostty-ag-copy-nav.md.
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("terminal/main.zig");
const Pin = terminal.Pin;
const Screen = terminal.Screen;

/// MIME type of the snapshot handed to the apprt alongside `text/plain`.
pub const snapshot_mime = "application/vnd.ghostty-phil.copy-snapshot+json";

/// Upward anchor scans stop after this many rows or distinct pages, so a
/// copy never decompresses much cold scrollback under the lock.
pub const scan_max_rows = 1500;
pub const scan_max_pages = 8;

/// Navigation may reach further back, but is still bounded.
pub const nav_max_pages = 64;

/// Extra anchors recorded inside one selection.
pub const max_spanned = 256;

const scheme = "ghostty-phil://";

/// True for `ghostty-phil://msg?…` (scheme case-insensitive).
pub fn isMsgUri(uri: []const u8) bool {
    if (uri.len < scheme.len or !std.ascii.eqlIgnoreCase(uri[0..scheme.len], scheme)) return false;
    return std.mem.startsWith(u8, uri[scheme.len..], "msg?");
}

/// Value of query item `name` in `uri`, undecoded. Producers emit hex, ints
/// and UUIDs, so raw comparison is exact.
pub fn queryValue(uri: []const u8, name: []const u8) ?[]const u8 {
    const q = uri[(std.mem.indexOfScalar(u8, uri, '?') orelse return null) + 1 ..];
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |item| {
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
        if (std.mem.eql(u8, item[0..eq], name)) return item[eq + 1 ..];
    }
    return null;
}

const Node = terminal.PageList.List.Node;
const Page = terminal.Page;

/// Accepts any msg anchor.
const any_msg: struct {
    fn matches(_: @This(), _: []const u8) bool {
        return true;
    }
} = .{};

/// First msg URI on row `y` of `page` that `filter` accepts, borrowed from the page.
fn rowMsgUri(page: *const Page, y: usize, filter: anytype) ?[]const u8 {
    const row = page.getRow(y);
    if (!row.hyperlink) return null;
    for (page.getCells(row)) |*cell| {
        if (!cell.hyperlink) continue;
        const id = page.lookupHyperlink(cell) orelse continue;
        const uri = page.hyperlink_set.get(page.memory, id).uri.slice(page.memory);
        if (isMsgUri(uri) and filter.matches(uri)) return uri;
    }
    return null;
}

/// A found anchor. `uri` is owned by the allocator passed to the search.
pub const Found = struct {
    pin: Pin,
    uri: []const u8,

    pub fn deinit(self: Found, alloc: Allocator) void {
        alloc.free(self.uri);
    }
};

/// Scans rows upward from row `y` of `node` (inclusive; null = its last row) for an
/// anchor `filter` accepts, within `max_pages` pages and `max_rows` rows. Pages are read
/// without changing their storage, so a miss leaves compressed history compressed.
fn searchUp(
    alloc: Allocator,
    start: *Node,
    y: ?usize,
    max_pages: usize,
    max_rows: ?usize,
    filter: anytype,
) Allocator.Error!?Found {
    var node_: ?*Node = start;
    var first_y = y;
    var pages: usize = 0;
    var rows: usize = 0;
    while (node_) |node| : (node_ = node.prev) {
        pages += 1;
        if (pages > max_pages) return null;
        var preserved = try node.pagePreservingState(alloc);
        defer preserved.deinit();
        const page = preserved.page();
        var row = (first_y orelse page.size.rows - 1) + 1;
        first_y = null;
        while (row > 0) {
            row -= 1;
            if (max_rows) |max| if (rows >= max) return null;
            rows += 1;
            if (rowMsgUri(page, row, filter)) |uri| return .{
                .pin = .{ .node = node, .y = @intCast(row) },
                .uri = try alloc.dupe(u8, uri),
            };
        }
    }
    return null;
}

/// Nearest msg anchor on `from`'s row or above, within the copy budget.
pub fn anchorAbove(alloc: Allocator, from: Pin) Allocator.Error!?Found {
    return searchUp(alloc, from.node, from.y, scan_max_pages, scan_max_rows, any_msg);
}

/// Which anchor navigation should find: the display pair `gen`+`seg`, the
/// durable pair `sid`+`rec`, or both (permalinks carry both; `gen` changes on
/// every `ag` redraw, so the durable pair still finds the message after one).
pub const Query = struct {
    gen: ?[]const u8 = null,
    seg: ?[]const u8 = null,
    sid: ?[]const u8 = null,
    rec: ?[]const u8 = null,

    pub const Pair = enum { display, durable };

    pub fn parse(uri: []const u8) ?Query {
        if (!isMsgUri(uri)) return null;
        const q: Query = .{
            .gen = queryValue(uri, "gen"),
            .seg = queryValue(uri, "seg"),
            .sid = queryValue(uri, "sid"),
            .rec = queryValue(uri, "rec"),
        };
        if (!q.has(.display) and !q.has(.durable)) return null;
        return q;
    }

    pub fn has(self: Query, pair: Pair) bool {
        return switch (pair) {
            .display => self.gen != null and self.seg != null,
            .durable => self.sid != null and self.rec != null,
        };
    }

    pub fn matchesPair(self: Query, pair: Pair, uri: []const u8) bool {
        if (!self.has(pair)) return false;
        return switch (pair) {
            .display => eq(uri, "gen", self.gen.?) and eq(uri, "seg", self.seg.?),
            .durable => eq(uri, "sid", self.sid.?) and eq(uri, "rec", self.rec.?),
        };
    }

    /// Either available pair matches.
    pub fn matches(self: Query, uri: []const u8) bool {
        return self.matchesPair(.display, uri) or self.matchesPair(.durable, uri);
    }

    fn eq(uri: []const u8, name: []const u8, want: []const u8) bool {
        const v = queryValue(uri, name) orelse return false;
        return std.mem.eql(u8, v, want);
    }
};

const PairFilter = struct {
    q: Query,
    pair: Query.Pair,

    fn matches(self: PairFilter, uri: []const u8) bool {
        return self.q.matchesPair(self.pair, uri);
    }
};

/// Newest row carrying an anchor matching `q`, scanning up from the bottom
/// of the screen within `nav_max_pages`.
pub fn findAnchor(alloc: Allocator, screen: *Screen, q: Query) Allocator.Error!?Pin {
    const bottom = screen.pages.getBottomRight(.screen) orelse return null;
    // An exact display match first, then the durable message identity.
    for ([_]Query.Pair{ .display, .durable }) |pair| {
        if (!q.has(pair)) continue;
        const filter: PairFilter = .{ .q = q, .pair = pair };
        if (try searchUp(alloc, bottom.node, bottom.y, nav_max_pages, null, filter)) |found| {
            found.deinit(alloc);
            return found.pin;
        }
    }
    return null;
}

/// Scrolls the viewport so the anchor matching `uri` is at its top. Uses
/// `Screen.scroll` so Kitty placements are marked dirty. False when `uri`
/// isn't a navigable msg link or its anchor isn't within the budget.
pub fn scrollToAnchor(alloc: Allocator, screen: *Screen, uri: []const u8) Allocator.Error!bool {
    const q = Query.parse(uri) orelse return false;
    const pin = try findAnchor(alloc, screen, q) orelse return false;
    screen.scroll(.{ .pin = pin });
    return true;
}

const Spanned = struct { uri: []const u8, relRow: u32 };

/// Wire form of a selection snapshot. Rows are relative to the anchor row;
/// columns are inclusive cells. `rowWraps[i]` is row i's
/// `wrap_continuation`, for rows 0...endRow.
pub const Flavor = enum { rich, markdown };

const Snapshot = struct {
    flavor: Flavor,
    anchor: []const u8,
    cols: u32,
    startRow: u32,
    startCol: u32,
    endRow: u32,
    endCol: u32,
    rowWraps: []const bool,
    spanned: []const Spanned,
    selectedPlain: []const u8,
};

/// The anchor an explicit copy of `sel` resolves against, or null when the
/// selection isn't eligible (rectangular, or no msg anchor within budget).
/// Cheap enough to check before formatting the selection.
pub fn selectionAnchor(alloc: Allocator, screen: *Screen, sel: terminal.Selection) Allocator.Error!?Found {
    if (sel.rectangle) return null;
    return anchorAbove(alloc, sel.ordered(screen, .forward).start());
}

/// JSON snapshot for an explicit copy of `sel` below `anchor` (from
/// `selectionAnchor`). `plain` is the plain-text copy from the same locked
/// state. The result is owned by `alloc` and holds no page-borrowed memory.
pub fn snapshotJson(
    alloc: Allocator,
    screen: *Screen,
    sel: terminal.Selection,
    anchor: Found,
    plain: []const u8,
    flavor: Flavor,
) Allocator.Error!?[]u8 {
    const ordered = sel.ordered(screen, .forward);
    const top = ordered.start();
    // Like the unwrapping plain formatter: an end on a spacer head includes
    // the wide char wrapped onto the next row.
    var bot = ordered.end();
    if (bot.rowAndCell().cell.wide == .spacer_head) bot = bot.rightWrap(1) orelse bot;

    const pages = &screen.pages;
    const anchor_y = (pages.pointFromPin(.screen, anchor.pin) orelse return null).coord().y;
    const top_pt = (pages.pointFromPin(.screen, top) orelse return null).coord();
    const bot_pt = (pages.pointFromPin(.screen, bot) orelse return null).coord();

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Rows from the anchor through the selection bottom; pages between the
    // anchor and the selection are read without restoring them.
    var wraps: std.ArrayList(bool) = .empty;
    var spanned: std.ArrayList(Spanned) = .empty;
    var node_: ?*Node = anchor.pin.node;
    var y: usize = anchor.pin.y;
    var rel: u32 = 0;
    outer: while (node_) |node| : ({
        node_ = node.next;
        y = 0;
    }) {
        var preserved = try node.pagePreservingState(alloc);
        defer preserved.deinit();
        const page = preserved.page();
        while (y < page.size.rows) : ({
            y += 1;
            rel += 1;
        }) {
            try wraps.append(a, page.getRow(y).wrap_continuation);
            if (rel > 0 and spanned.items.len < max_spanned) {
                if (rowMsgUri(page, y, any_msg)) |uri| try spanned.append(a, .{
                    .uri = try a.dupe(u8, uri),
                    .relRow = rel,
                });
            }
            if (node == bot.node and y == bot.y) break :outer;
        }
    }

    const snap: Snapshot = .{
        .flavor = flavor,
        .anchor = anchor.uri,
        .cols = pages.cols,
        .startRow = top_pt.y - anchor_y,
        .startCol = top_pt.x,
        .endRow = bot_pt.y - anchor_y,
        .endCol = bot_pt.x,
        .rowWraps = wraps.items,
        .spanned = spanned.items,
        .selectedPlain = plain,
    };
    return try std.json.Stringify.valueAlloc(alloc, snap, .{});
}

/// Test helper: anchor lookup plus snapshot.
fn testSnapshot(screen: *Screen, sel: terminal.Selection, plain: []const u8) !?[]u8 {
    const alloc = testing.allocator;
    const anchor = try selectionAnchor(alloc, screen, sel) orelse return null;
    defer anchor.deinit(alloc);
    return try snapshotJson(alloc, screen, sel, anchor, plain, .rich);
}

const testing = std.testing;

fn testTerm(cols: u16, rows: u16) !terminal.Terminal {
    return try .init(testing.io, testing.allocator, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = null });
}

test "copy_nav: msg uri and query parsing" {
    try testing.expect(isMsgUri("ghostty-phil://msg?pid=1&gen=ab&seg=3"));
    try testing.expect(isMsgUri("Ghostty-Phil://msg?seg=3"));
    try testing.expect(!isMsgUri("ghostty-phil://copy?seg=3"));
    try testing.expect(!isMsgUri("https://msg?seg=3"));
    try testing.expectEqualStrings("3", queryValue("ghostty-phil://msg?gen=ab&seg=3", "seg").?);
    try testing.expectEqual(null, queryValue("ghostty-phil://msg?gen=ab&segx=3", "seg"));

    const q = Query.parse("ghostty-phil://msg?pid=9&gen=ab&seg=3&scroll=1").?;
    try testing.expect(q.matches("ghostty-phil://msg?pid=1&seg=3&gen=ab"));
    try testing.expect(!q.matches("ghostty-phil://msg?gen=ab&seg=31"));
    try testing.expect(!q.matches("ghostty-phil://msg?gen=cd&seg=3"));
    const r = Query.parse("ghostty-phil://msg?sid=S&rec=R").?;
    try testing.expect(r.matches("ghostty-phil://msg?gen=x&seg=1&sid=S&rec=R"));
    // Both pairs kept: a stale gen still matches by sid+rec.
    const both = Query.parse("ghostty-phil://msg?gen=old&seg=3&sid=S&rec=R").?;
    try testing.expect(both.has(.display) and both.has(.durable));
    try testing.expect(both.matches("ghostty-phil://msg?gen=new&seg=7&sid=S&rec=R"));
    try testing.expect(!both.matchesPair(.display, "ghostty-phil://msg?gen=new&seg=7&sid=S&rec=R"));
    try testing.expectEqual(null, Query.parse("ghostty-phil://msg?pid=1"));
}

test "copy_nav: snapshot records anchor, rows, wraps and spanned anchors" {
    var t = try testTerm(10, 10);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    // row 0: anchor seg 1; row 1: soft-wrapped into row 2; row 3: anchor seg 2.
    s.nextSlice("\x1b]8;;ghostty-phil://msg?gen=ab&seg=1\x1b\\*\x1b]8;;\x1b\\ hi\r\n");
    s.nextSlice("abcdefghijKLM\r\n");
    s.nextSlice("\x1b]8;;ghostty-phil://msg?gen=ab&seg=2\x1b\\*\x1b]8;;\x1b\\ yo");

    const screen = t.screens.active;
    const tl = screen.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?;
    const br = screen.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?;
    // Reverse drag must normalize.
    const json = (try testSnapshot(screen, .init(br, tl, false), "plain")).?;
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{"flavor":"rich","anchor":"ghostty-phil://msg?gen=ab&seg=1","cols":10,"startRow":1,"startCol":2,"endRow":3,"endCol":3,"rowWraps":[false,false,true,false],"spanned":[{"uri":"ghostty-phil://msg?gen=ab&seg=2","relRow":3}],"selectedPlain":"plain"}
    , json);

    // Rectangular selections take the normal path.
    try testing.expectEqual(null, try testSnapshot(screen, .init(tl, br, true), "p"));
}

test "copy_nav: no anchor means no snapshot" {
    var t = try testTerm(10, 5);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;ghostty-phil://copy?seg=1\x1b\\c\x1b]8;;\x1b\\\r\nplain");
    const screen = t.screens.active;
    const p = screen.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?;
    try testing.expectEqual(null, try testSnapshot(screen, .init(p, p, false), "p"));
}

test "copy_nav: upward anchor scan is bounded by rows" {
    var t = try testTerm(10, 5);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;ghostty-phil://msg?gen=ab&seg=1\x1b\\*\x1b]8;;\x1b\\\r\n");
    for (0..scan_max_rows) |_| s.nextSlice("x\r\n");
    const screen = t.screens.active;
    const near = screen.pages.pin(.{ .screen = .{ .y = scan_max_rows - 1 } }).?;
    const hit = (try anchorAbove(testing.allocator, near)).?;
    hit.deinit(testing.allocator);
    const far = screen.pages.pin(.{ .screen = .{ .y = scan_max_rows } }).?;
    try testing.expectEqual(null, try anchorAbove(testing.allocator, far));
}

test "copy_nav: scrollToAnchor scrolls viewport to the matching anchor" {
    var t = try testTerm(10, 3);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;ghostty-phil://msg?gen=ab&seg=1&sid=S&rec=R\x1b\\*\x1b]8;;\x1b\\\r\n");
    for (0..20) |_| s.nextSlice("x\r\n");
    s.nextSlice("\x1b]8;;ghostty-phil://msg?gen=ab&seg=2\x1b\\*\x1b]8;;\x1b\\");
    const screen = t.screens.active;

    try testing.expect(try scrollToAnchor(testing.allocator, screen, "ghostty-phil://msg?gen=ab&seg=1&scroll=1"));
    const vp = screen.pages.getTopLeft(.viewport);
    try testing.expectEqual(@as(u32, 0), screen.pages.pointFromPin(.screen, vp).?.coord().y);

    screen.scroll(.active);
    try testing.expect(try scrollToAnchor(testing.allocator, screen, "ghostty-phil://msg?sid=S&rec=R"));
    try testing.expectEqual(@as(u32, 0), screen.pages.pointFromPin(.screen, screen.pages.getTopLeft(.viewport)).?.coord().y);

    try testing.expect(!try scrollToAnchor(testing.allocator, screen, "ghostty-phil://msg?gen=ab&seg=9"));
    try testing.expect(!try scrollToAnchor(testing.allocator, screen, "ghostty-phil://copy?gen=ab&seg=1"));
}

test "copy_nav: anchor search misses leave compressed history compressed" {
    var t = try testTerm(80, 5);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;ghostty-phil://msg?gen=ab&seg=1\x1b\\*\x1b]8;;\x1b\\\r\n");
    for (0..5000) |_| s.nextSlice("filler line\r\n");
    const screen = t.screens.active;
    if (screen.pages.compress(.drain) == .unsupported) return error.SkipZigTest;

    var compressed: usize = 0;
    var it = screen.pages.pages.first;
    while (it) |node| : (it = node.next) {
        if (node.storage() == .compressed) compressed += 1;
    }
    try testing.expect(compressed > 0);

    try testing.expect(!try scrollToAnchor(testing.allocator, screen, "ghostty-phil://msg?gen=ab&seg=9"));
    var after: usize = 0;
    it = screen.pages.pages.first;
    while (it) |node| : (it = node.next) {
        if (node.storage() == .compressed) after += 1;
    }
    try testing.expectEqual(compressed, after);

    // A hit inside compressed history is still found.
    try testing.expect(try scrollToAnchor(testing.allocator, screen, "ghostty-phil://msg?gen=ab&seg=1"));
}

test "copy_nav: selection ending on a spacer head includes the wrapped wide char" {
    var t = try testTerm(3, 5);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;ghostty-phil://msg?gen=ab&seg=1\x1b\\*\x1b]8;;\x1b\\\r\n");
    // "1A" then a wide char that doesn't fit: spacer head at col 2, ⚡ wraps.
    s.nextSlice("1A\u{26A1}Z");
    const screen = t.screens.active;
    const tl = screen.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?;
    const br = screen.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?;
    try testing.expectEqual(terminal.Cell.Wide.spacer_head, br.rowAndCell().cell.wide);
    const json = (try testSnapshot(screen, .init(tl, br, false), "1A\u{26A1}")).?;
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"endRow\":2,\"endCol\":0,") != null);
}
