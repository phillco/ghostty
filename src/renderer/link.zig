const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const inputpkg = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const point = terminal.point;
const Screen = terminal.Screen;
const Terminal = terminal.Terminal;

const log = std.log.scoped(.renderer_link);

/// Link decoration tracks hover separately from persistent visibility.
pub const Highlight = enum {
    normal,
    hover,

    pub fn underline(
        self: Highlight,
        base: terminal.Attribute.Underline,
        always: bool,
    ) terminal.Attribute.Underline {
        if (self == .hover and (always or base == .single)) return .double;
        return if (base == .none) .single else base;
    }
};

pub const CellMap = std.AutoArrayHashMapUnmanaged(point.Coordinate, Highlight);

/// Invalidate cached GPU rows when link decoration changes, including wrapped
/// matches whose continuation rows were not changed by terminal output.
pub fn updateDirtyRows(
    alloc: Allocator,
    previous: *CellMap,
    current: *const CellMap,
    state: *terminal.RenderState,
) !void {
    var changed = false;
    for (previous.keys(), previous.values()) |pt, value| {
        if (current.get(pt) == value) continue;
        if (pt.y < state.rows) state.row_data.items(.dirty)[state.viewportStart() + pt.y] = true;
        changed = true;
    }
    for (current.keys(), current.values()) |pt, value| {
        if (previous.get(pt) == value) continue;
        if (pt.y < state.rows) state.row_data.items(.dirty)[state.viewportStart() + pt.y] = true;
        changed = true;
    }
    if (!changed) return;
    if (state.dirty == .false) state.dirty = .partial;
    const copy = try current.clone(alloc);
    previous.deinit(alloc);
    previous.* = copy;
}

/// Must run before the terminal can mutate, just like RenderState.linkCells.
pub fn osc8CellMap(
    alloc: Allocator,
    state: *const terminal.RenderState,
    mouse_viewport: ?point.Coordinate,
    always: bool,
    enabled: bool,
) !CellMap {
    var result: CellMap = .empty;
    errdefer result.deinit(alloc);
    if (!enabled) return result;

    if (mouse_viewport) |vp| {
        var hovered = try state.linkCells(alloc, vp);
        defer hovered.deinit(alloc);
        for (hovered.keys()) |pt| try result.put(alloc, pt, .hover);
    }

    if (always) {
        const rows = state.row_data.slice().items(.cells)[state.viewportStart()..][0..state.rows];
        for (rows, 0..) |cells, y| {
            for (cells.items(.raw), 0..) |cell, x| {
                if (!cell.hyperlink) continue;
                const entry = try result.getOrPut(alloc, .{ .x = @intCast(x), .y = @intCast(y) });
                if (!entry.found_existing) entry.value_ptr.* = .normal;
            }
        }
    }
    return result;
}

/// The link configuration needed for renderers.
pub const Link = struct {
    /// The regular expression to match the link against.
    regex: oni.Regex,

    /// The situations in which the link should be highlighted.
    highlight: inputpkg.Link.Highlight,

    pub fn deinit(self: *Link) void {
        self.regex.deinit();
    }

    /// Returns true if this link's highlight condition matches the given mouse state.
    fn active(
        self: *const Link,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
        always: bool,
    ) bool {
        return switch (self.highlight) {
            .always => true,
            .always_mods => |v| mouse_mods.equal(v),
            .hover => always or mouse_viewport != null,
            .hover_mods => |v| (always or mouse_viewport != null) and mouse_mods.equal(v),
        };
    }
};

/// A set of links. This provides a higher level API for renderers
/// to match against a viewport and determine if cells are part of
/// a link.
pub const Set = struct {
    links: []Link,
    always: bool = false,

    /// Returns the slice of links from the configuration.
    pub fn fromConfig(
        alloc: Allocator,
        config: []const inputpkg.Link,
    ) !Set {
        var links: std.ArrayList(Link) = .empty;
        defer links.deinit(alloc);

        for (config) |link| {
            var regex = try link.oniRegex();
            errdefer regex.deinit();
            try links.append(alloc, .{
                .regex = regex,
                .highlight = link.highlight,
            });
        }

        return .{ .links = try links.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *Set, alloc: Allocator) void {
        for (self.links) |*link| link.deinit();
        alloc.free(self.links);
    }

    /// Fills matches with the matches from regex link matches.
    pub fn renderCellMap(
        self: *const Set,
        alloc: Allocator,
        result: *CellMap,
        render_state: *const terminal.RenderState,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) !void {
        // Fast path, not very likely since we have default links.
        if (self.links.len == 0) return;

        // Determine if any links are active before building the string and
        // byte-to-cell map. Those buffers scale with viewport size and this
        // function runs during frame updates, so avoid allocating them when
        // the current mouse/modifier state can't highlight any regex links.
        for (self.links) |*link| {
            if (link.active(mouse_viewport, mouse_mods, self.always)) break;
        } else return;

        // Convert our render state to a string + byte map.
        var builder: std.Io.Writer.Allocating = .init(alloc);
        defer builder.deinit();
        var map: terminal.RenderState.StringMap = .empty;
        defer map.deinit(alloc);
        try render_state.string(&builder.writer, .{
            .alloc = alloc,
            .map = &map,
        });

        const str = builder.writer.buffered();

        // Go through each link and see if we have any matches.
        for (self.links) |*link| {
            if (!link.active(mouse_viewport, mouse_mods, self.always)) continue;

            var offset: usize = 0;
            while (offset < str.len) {
                var region = link.regex.search(
                    str[offset..],
                    .{},
                ) catch |err| switch (err) {
                    error.Mismatch => break,
                    else => return err,
                };
                defer region.deinit();

                // We have a match!
                const offset_start: usize = @intCast(region.starts()[0]);
                const offset_end: usize = @intCast(region.ends()[0]);
                const start = offset + offset_start;
                const end = offset + offset_end;

                // Empty matches cannot decorate a cell and must still advance.
                // Skip UTF-8 continuation bytes before searching again.
                if (start == end) {
                    offset = end + 1;
                    while (offset < str.len and str[offset] & 0xC0 == 0x80) offset += 1;
                    continue;
                }

                // Increment our offset by the number of bytes in the match.
                // We defer this so that we can return the match before
                // modifying the offset.
                defer offset = end;

                const hovered = if (mouse_viewport) |vp| hovered: {
                    for (map.items[start..end]) |pt| {
                        if (pt.eql(vp)) break :hovered true;
                    }
                    break :hovered false;
                } else false;

                switch (link.highlight) {
                    .always, .always_mods => {},
                    .hover, .hover_mods => if (!self.always and !hovered) continue,
                }

                // Preserve hover emphasis if another matcher overlaps this one.
                for (map.items[start..end]) |pt| {
                    const entry = try result.getOrPut(alloc, pt);
                    if (!entry.found_existing or hovered) {
                        entry.value_ptr.* = if (hovered) .hover else .normal;
                    }
                }
            }
        }
    }
};

test "renderCellMap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: CellMap = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}

test "renderCellMap hover links" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Not hovering over the first link
    {
        var result: CellMap = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            null,
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }

    // Hovering over the first link
    {
        var result: CellMap = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            .{ .x = 1, .y = 0 },
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }
}

test "renderCellMap inactive links don't allocate" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t: terminal.Terminal = try .init(io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },

        .{
            .regex = "IJ",
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = .{ .shift = true } },
        },
    });
    defer set.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    const failing_alloc = failing.allocator();

    var result: CellMap = .empty;
    defer result.deinit(failing_alloc);
    try set.renderCellMap(
        failing_alloc,
        &result,
        &state,
        null,
        .{},
    );

    try testing.expectEqual(@as(usize, 0), result.count());
}

test "renderCellMap mods no match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: CellMap = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );

    // Test our matches
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}

test "link underline strength preserves application decorations" {
    const testing = std.testing;
    try testing.expectEqual(.single, Highlight.normal.underline(.none, true));
    try testing.expectEqual(.single, Highlight.hover.underline(.none, false));
    try testing.expectEqual(.double, Highlight.hover.underline(.none, true));
    try testing.expectEqual(.double, Highlight.hover.underline(.single, false));
    try testing.expectEqual(.double, Highlight.normal.underline(.double, true));
    try testing.expectEqual(.curly, Highlight.hover.underline(.curly, false));
}

test "renderCellMap always underlines with hover emphasis" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    // AB wraps across the first two rows.
    stream.nextSlice("1234AB xy");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var set = try Set.fromConfig(alloc, &.{
        .{ .regex = "AB", .action = .open, .highlight = .hover },
        .{ .regex = "xy", .action = .open, .highlight = .{ .hover_mods = .{ .ctrl = true } } },
    });
    defer set.deinit(alloc);
    set.always = true;

    var result: CellMap = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(alloc, &result, &state, null, .{});
    try testing.expectEqual(2, result.count());
    try testing.expectEqual(.normal, result.get(.{ .x = 4, .y = 0 }).?);
    try testing.expectEqual(.normal, result.get(.{ .x = 0, .y = 1 }).?);

    result.clearRetainingCapacity();
    try set.renderCellMap(alloc, &result, &state, .{ .x = 0, .y = 1 }, .{});
    try testing.expectEqual(.hover, result.get(.{ .x = 4, .y = 0 }).?);
    try testing.expectEqual(.hover, result.get(.{ .x = 0, .y = 1 }).?);

    result.clearRetainingCapacity();
    try set.renderCellMap(alloc, &result, &state, null, .{ .ctrl = true });
    try testing.expectEqual(4, result.count());
    try testing.expectEqual(.normal, result.get(.{ .x = 2, .y = 1 }).?);
}

test "renderCellMap empty matches advance over UTF-8" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 5, .rows = 1 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("éAB");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var set = try Set.fromConfig(alloc, &.{
        .{ .regex = "(?=.)|$", .action = .open, .highlight = .always },
    });
    defer set.deinit(alloc);
    var result: CellMap = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(alloc, &result, &state, null, .{});
    try testing.expectEqual(0, result.count());
}

test "osc8CellMap always hover and disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b]8;;https://example.com\x1b\\ONE\x1b]8;;\x1b\\ ");
    stream.nextSlice("\x1b]8;;https://example.org\x1b\\TWO\x1b]8;;\x1b\\");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var idle = try osc8CellMap(alloc, &state, null, false, true);
    defer idle.deinit(alloc);
    try testing.expectEqual(0, idle.count());
    var hovered = try osc8CellMap(alloc, &state, .{ .x = 0, .y = 0 }, false, true);
    defer hovered.deinit(alloc);
    try testing.expectEqual(3, hovered.count());
    try testing.expectEqual(.hover, hovered.get(.{ .x = 0, .y = 0 }).?);
    var always = try osc8CellMap(alloc, &state, .{ .x = 0, .y = 0 }, true, true);
    defer always.deinit(alloc);
    try testing.expectEqual(6, always.count());
    try testing.expectEqual(.hover, always.get(.{ .x = 2, .y = 0 }).?);
    try testing.expectEqual(.normal, always.get(.{ .x = 4, .y = 0 }).?);
    var disabled = try osc8CellMap(alloc, &state, .{ .x = 0, .y = 0 }, true, false);
    defer disabled.deinit(alloc);
    try testing.expectEqual(0, disabled.count());
}

test "link decoration changes invalidate unchanged continuation rows" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 1 };
    try state.update(alloc, &t);
    state.clean();
    var previous: CellMap = .empty;
    defer previous.deinit(alloc);
    var current: CellMap = .empty;
    defer current.deinit(alloc);
    try current.put(alloc, .{ .x = 4, .y = 0 }, .normal);
    try current.put(alloc, .{ .x = 0, .y = 1 }, .normal);
    try updateDirtyRows(alloc, &previous, &current, &state);
    try testing.expectEqual(.partial, state.dirty);
    const dirty = state.row_data.items(.dirty)[state.viewportStart()..][0..state.rows];
    try testing.expect(dirty[0] and dirty[1] and !dirty[2]);
    state.clean();
    try updateDirtyRows(alloc, &previous, &current, &state);
    try testing.expectEqual(.false, state.dirty);
    // Breaking the URL must clear both rows, even if only its first row changed.
    current.clearRetainingCapacity();
    try updateDirtyRows(alloc, &previous, &current, &state);
    try testing.expect(dirty[0] and dirty[1] and !dirty[2]);
    state.clean();
    try current.put(alloc, .{ .x = 0, .y = 1 }, .hover);
    try updateDirtyRows(alloc, &previous, &current, &state);
    state.clean();
    try current.put(alloc, .{ .x = 0, .y = 1 }, .normal);
    try updateDirtyRows(alloc, &previous, &current, &state);
    try testing.expect(!dirty[0] and dirty[1] and !dirty[2]);
}

test "osc8CellMap excludes overscan and preserves viewport coordinates" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: Terminal = try .init(testing.io, alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback_bytes = 10000,
    });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b]8;;https://example.com\x1b\\OLD\x1b]8;;\x1b\\\r\n");
    stream.nextSlice("\x1b]8;;https://example.org\x1b\\NEW\x1b]8;;\x1b\\\r\n");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 1 };
    try state.update(alloc, &t);
    try testing.expectEqual(1, state.overscan.above);
    var result = try osc8CellMap(alloc, &state, .{ .x = 0, .y = 0 }, true, true);
    defer result.deinit(alloc);
    try testing.expectEqual(3, result.count());
    try testing.expectEqual(.hover, result.get(.{ .x = 0, .y = 0 }).?);
    try testing.expectEqual(null, result.get(.{ .x = 0, .y = 1 }));
}
