const std = @import("std");
const tree = @import("./tree.zig");
const Manager = @import("../fs/Manager.zig");
const tui = @import("../tui.zig");
const utils = @import("../utils.zig");

const fs = std.fs;
const mem = std.mem;
const os = std.os;
const io = std.io;

const print = std.debug.print;
const bS = tui.style.bufStyle;
const terminal = tui.terminal;

allocator: mem.Allocator,
manager: *Manager,

const State = {};

const Self = @This();

pub fn init(allocator: mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .manager = try Manager.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.manager.deinit();
}

pub const Viewport = struct {
    // Terminal related fields
    size: terminal.Size, // terminal dims
    position: terminal.Position, // cursor position

    // Display related fields
    rows: u16 = 1, // max rows
    start_row: u16 = 0,

    pub fn init() !Viewport {
        try terminal.enableRawMode();
        return .{
            .rows = 0,
            .start_row = 0,
            .size = terminal.Size{ .cols = 0, .rows = 0 },
            .position = terminal.Position{ .col = 0, .row = 0 },
        };
    }

    pub fn deinit(_: *Viewport) void {
        terminal.disableRawMode() catch {};
    }

    pub fn setBounds(self: *Viewport) !void {
        self.size = terminal.getTerminalSize();
        self.position = try Viewport.getAdjustedPosition(self.size);
        self.rows = self.size.rows - self.position.row;
        self.start_row = Viewport.getStartRow(
            self.rows,
            self.position,
        );
        std.debug.print(
            "vp.setBounds size={any}, position={any}, rows={any}, start_row={any}\n",
            .{ self.size, self.position, self.rows, self.start_row },
        );
    }

    fn getAdjustedPosition(size: terminal.Size) !terminal.Position {
        var position = try terminal.getCursorPosition();
        const min_rows = size.rows / 2;

        const rows_below = size.rows - position.row;
        if (rows_below > min_rows) {
            return position;
        }

        // Adjust Position: shift prompt (and cursor) up with newlines
        var obuf: [1024]u8 = undefined;
        var shift = min_rows - rows_below + 1;
        var newlines = utils.repeat(&obuf, "\n", shift);
        _ = try os.write(os.STDOUT_FILENO, newlines);

        return terminal.Position{
            .row = size.rows - shift,
            .col = position.col,
        };
    }

    fn getStartRow(rows: u16, pos: terminal.Position) u16 {
        if (pos.row > rows) {
            // unreachable after adjusted position
            return pos.row - rows;
        }

        return pos.row;
    }
};

const Entry = Manager.Iterator.Entry;
pub fn run(self: *Self) !void {
    var vp = try Viewport.init();
    defer vp.deinit();

    try vp.setBounds();

    _ = try self.manager.root.children();

    // Buffer iterated elements to allow backtracking
    var view_buffer = std.ArrayList(Entry).init(self.allocator);
    defer view_buffer.deinit();

    // Tree View to format output
    var tv = tree.TreeView.init(self.allocator);
    defer tv.deinit();

    // Stdout writer and buffer
    const writer = io.getStdOut().writer();
    var obuf: [2048]u8 = undefined; // content buffer
    var sbuf: [2048]u8 = undefined; // style buffer
    var draw = tui.Draw{ .writer = writer };

    // Stdin reader and buffer
    const reader = io.getStdIn().reader();
    var rbuf: [2048]u8 = undefined;
    var input = tui.Input{ .reader = reader };

    // Cursor and view boundaries
    var cursor: usize = 0;
    var vb_first: usize = 0; // First Index
    var vb_last: usize = 0; // Last Index

    // Iterates over fs tree
    var iter = try self.manager.iterate(-2);
    defer iter.deinit();

    // Reiterates
    var reiterate = false;

    // Pre-fill iter buffer
    for (0..vp.rows) |i| {
        const _e = iter.next();
        if (_e == null) {
            break;
        }

        const e = _e.?;
        try view_buffer.append(e);
        vb_last = i;
    }

    try draw.hideCursor();
    defer draw.showCursor() catch {};

    while (true) {
        // If manager tree changes in any way
        if (reiterate) {
            defer reiterate = false;

            view_buffer.clearAndFree();
            iter.deinit();

            iter = try self.manager.iterate(-2);

            for (0..vp.rows) |i| {
                const _e = iter.next();
                if (_e == null) {
                    break;
                }

                const e = _e.?;
                try view_buffer.append(e);
                vb_last = i;
            }
        }

        // Cursor exceeds bottom boundary
        if (cursor > vb_last) {
            // View buffer in range, no need to append
            if (vb_last < (view_buffer.items.len - 1)) {
                vb_first += 1;
                vb_last += 1;
            }

            // View buffer out of range, need to append
            else if (iter.next()) |e| {
                try view_buffer.append(e);
                vb_first += 1;
                vb_last += 1;
            }

            // No more items, reset cursor
            else {
                cursor = vb_last;
            }
        }

        // Cursor exceeds top boundary
        else if (cursor < vb_first) {
            vb_first -= 1;
            vb_last -= 1;
        }

        // Print contents of view buffer in range
        try draw.moveCursor(vp.start_row, 0);
        for (vb_first..(vb_last + 1)) |i| {
            const e = view_buffer.items[i];

            const fg = if (cursor == i) tui.style.Color.cyan else tui.style.Color.default;
            const cursor_style = try bS(&sbuf, .{ .fg = fg });

            var line = try tv.line(e, &obuf);
            try draw.println(line, cursor_style);
        }
        std.debug.print("post print {any}\n", .{try terminal.getCursorPosition()});

        // Wait for input
        while (true) {
            const action = try input.readAction(&rbuf);
            switch (action) {
                .quit => return,
                .down => cursor += 1,
                .up => cursor -|= 1,
                .select => {
                    const item = view_buffer.items[cursor].item;
                    if (item.hasChildren()) {
                        item.freeChildren(null);
                    } else {
                        _ = try item.children();
                    }
                    reiterate = true;
                },
                // Implement others
                .unknown => continue,
                else => continue,
            }

            break;
        }

        // try draw.clearNLines(@intCast(self.rows));
        // try draw.clearLinesBelow(pos.row);
        try draw.clearLinesBelow(vp.start_row);
    }
}

test "test" {}
