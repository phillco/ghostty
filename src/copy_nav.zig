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

/// First `ghostty-phil://msg` URI on the row at `p`, borrowed from the page.
fn rowMsgUri(p: Pin) ?[]const u8 {
    const rac = p.rowAndCell();
    if (!rac.row.hyperlink) return null;
    const page = p.node.page();
    for (page.getCells(rac.row)) |*cell| {
        if (!cell.hyperlink) continue;
        const id = page.lookupHyperlink(cell) orelse continue;
        const uri = page.hyperlink_set.get(page.memory, id).uri.slice(page.memory);
        if (isMsgUri(uri)) return uri;
    }
    return null;
}

pub const Found = struct { pin: Pin, uri: []const u8 };

/// Nearest msg anchor on `from`'s row or above, within the copy budget.
pub fn anchorAbove(from: Pin) ?Found {
    var it = from.rowIterator(.left_up, null);
    var rows: usize = 0;
    var pages: usize = 0;
    var node: ?*terminal.PageList.List.Node = null;
    while (it.next()) |p| : (rows += 1) {
        if (rows >= scan_max_rows) return null;
        if (p.node != node) {
            pages += 1;
            if (pages > scan_max_pages) return null;
            node = p.node;
        }
        if (rowMsgUri(p)) |uri| return .{ .pin = .{ .node = p.node, .y = p.y }, .uri = uri };
    }
    return null;
}

/// Which anchor navigation should find: `gen`+`seg`, else `sid`+`rec`.
pub const Query = union(enum) {
    seg: struct { gen: []const u8, seg: []const u8 },
    rec: struct { sid: []const u8, rec: []const u8 },

    pub fn parse(uri: []const u8) ?Query {
        if (!isMsgUri(uri)) return null;
        if (queryValue(uri, "gen")) |gen| if (queryValue(uri, "seg")) |seg|
            return .{ .seg = .{ .gen = gen, .seg = seg } };
        if (queryValue(uri, "sid")) |sid| if (queryValue(uri, "rec")) |rec|
            return .{ .rec = .{ .sid = sid, .rec = rec } };
        return null;
    }

    pub fn matches(self: Query, uri: []const u8) bool {
        const eq = struct {
            fn f(u: []const u8, name: []const u8, want: []const u8) bool {
                const v = queryValue(u, name) orelse return false;
                return std.mem.eql(u8, v, want);
            }
        }.f;
        return switch (self) {
            .seg => |q| eq(uri, "gen", q.gen) and eq(uri, "seg", q.seg),
            .rec => |q| eq(uri, "sid", q.sid) and eq(uri, "rec", q.rec),
        };
    }
};

/// Newest row carrying an anchor matching `q`, scanning up from the bottom
/// of the screen within `nav_max_pages`.
pub fn findAnchor(screen: *Screen, q: Query) ?Pin {
    const bottom = screen.pages.getBottomRight(.screen) orelse return null;
    var it = bottom.rowIterator(.left_up, null);
    var pages: usize = 0;
    var node: ?*terminal.PageList.List.Node = null;
    while (it.next()) |p| {
        if (p.node != node) {
            pages += 1;
            if (pages > nav_max_pages) return null;
            node = p.node;
        }
        const rac = p.rowAndCell();
        if (!rac.row.hyperlink) continue;
        const page = p.node.page();
        for (page.getCells(rac.row)) |*cell| {
            if (!cell.hyperlink) continue;
            const id = page.lookupHyperlink(cell) orelse continue;
            const uri = page.hyperlink_set.get(page.memory, id).uri.slice(page.memory);
            if (isMsgUri(uri) and q.matches(uri)) return .{ .node = p.node, .y = p.y };
        }
    }
    return null;
}

/// Scrolls the viewport so the anchor matching `uri` is at its top. Uses
/// `Screen.scroll` so Kitty placements are marked dirty. False when `uri`
/// isn't a navigable msg link or its anchor isn't within the budget.
pub fn scrollToAnchor(screen: *Screen, uri: []const u8) bool {
    const q = Query.parse(uri) orelse return false;
    const pin = findAnchor(screen, q) orelse return false;
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

/// JSON snapshot for an explicit copy of `sel`, or null when it isn't
/// eligible (rectangular, or no msg anchor within budget). `plain` is the
/// plain-text copy from the same locked state. The result is owned by
/// `alloc` and holds no page-borrowed memory.
pub fn snapshotJson(
    alloc: Allocator,
    screen: *Screen,
    sel: terminal.Selection,
    plain: []const u8,
    flavor: Flavor,
) Allocator.Error!?[]u8 {
    if (sel.rectangle) return null;
    const ordered = sel.ordered(screen, .forward);
    const top = ordered.start();
    const bot = ordered.end();
    const found = anchorAbove(top) orelse return null;

    const pages = &screen.pages;
    const anchor_y = (pages.pointFromPin(.screen, found.pin) orelse return null).coord().y;
    const top_pt = (pages.pointFromPin(.screen, top) orelse return null).coord();
    const bot_pt = (pages.pointFromPin(.screen, bot) orelse return null).coord();

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var wraps: std.ArrayList(bool) = .empty;
    var spanned: std.ArrayList(Spanned) = .empty;
    var it = found.pin.rowIterator(.right_down, .{ .node = bot.node, .y = bot.y });
    var rel: u32 = 0;
    while (it.next()) |p| : (rel += 1) {
        try wraps.append(a, p.rowAndCell().row.wrap_continuation);
        if (rel == 0 or spanned.items.len >= max_spanned) continue;
        if (rowMsgUri(p)) |uri| try spanned.append(a, .{ .uri = uri, .relRow = rel });
    }

    const snap: Snapshot = .{
        .flavor = flavor,
        .anchor = found.uri,
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
    const json = (try snapshotJson(testing.allocator, screen, .init(br, tl, false), "plain", .rich)).?;
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{"flavor":"rich","anchor":"ghostty-phil://msg?gen=ab&seg=1","cols":10,"startRow":1,"startCol":2,"endRow":3,"endCol":3,"rowWraps":[false,false,true,false],"spanned":[{"uri":"ghostty-phil://msg?gen=ab&seg=2","relRow":3}],"selectedPlain":"plain"}
    , json);

    // Rectangular selections take the normal path.
    try testing.expectEqual(null, try snapshotJson(testing.allocator, screen, .init(tl, br, true), "p", .rich));
}

test "copy_nav: no anchor means no snapshot" {
    var t = try testTerm(10, 5);
    defer t.deinit(testing.allocator);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]8;;ghostty-phil://copy?seg=1\x1b\\c\x1b]8;;\x1b\\\r\nplain");
    const screen = t.screens.active;
    const p = screen.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?;
    try testing.expectEqual(null, try snapshotJson(testing.allocator, screen, .init(p, p, false), "p", .rich));
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
    try testing.expect(anchorAbove(near) != null);
    const far = screen.pages.pin(.{ .screen = .{ .y = scan_max_rows } }).?;
    try testing.expectEqual(null, anchorAbove(far));
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

    try testing.expect(scrollToAnchor(screen, "ghostty-phil://msg?gen=ab&seg=1&scroll=1"));
    const vp = screen.pages.getTopLeft(.viewport);
    try testing.expectEqual(@as(u32, 0), screen.pages.pointFromPin(.screen, vp).?.coord().y);

    screen.scroll(.active);
    try testing.expect(scrollToAnchor(screen, "ghostty-phil://msg?sid=S&rec=R"));
    try testing.expectEqual(@as(u32, 0), screen.pages.pointFromPin(.screen, screen.pages.getTopLeft(.viewport)).?.coord().y);

    try testing.expect(!scrollToAnchor(screen, "ghostty-phil://msg?gen=ab&seg=9"));
    try testing.expect(!scrollToAnchor(screen, "ghostty-phil://copy?gen=ab&seg=1"));
}
