//! Read fast-path input during GPU waits without reentering graphics/control handlers.
const std = @import("std");
const transport = @import("../net/transport.zig");
const Pdu = transport.Pdu;

pub const Pump = struct {
    data: std.ArrayList(u8) = .empty,
    kind: ?@FieldType(Pdu, "kind") = null,

    pub fn deinit(p: *Pump, gpa: std.mem.Allocator) void {
        p.data.deinit(gpa);
        p.* = .{};
    }

    pub fn pending(p: *const Pump) bool {
        return p.kind != null;
    }

    /// The deferred PDU precedes any later input. Its bytes survive transport compaction.
    pub fn next(p: *Pump, reader: anytype) !?Pdu {
        if (p.kind) |kind| {
            p.kind = null;
            return .{ .kind = kind, .data = p.data.items };
        }
        return reader.tryNext();
    }

    /// Stop at the first control PDU; moving input across it could change its meaning.
    /// A bounded batch lets an input flood yield back to the GPU completion check.
    pub fn duringEncode(p: *Pump, gpa: std.mem.Allocator, reader: anytype, ctx: anytype, comptime handle: anytype) !void {
        if (p.pending()) return;
        for (0..8) |_| {
            const msg = (try reader.tryNext()) orelse return;
            if (msg.kind != .fastpath) {
                p.data.clearRetainingCapacity();
                try p.data.appendSlice(gpa, msg.data);
                p.kind = msg.kind;
                return;
            }
            try handle(ctx, msg);
        }
    }
};

const FakeReader = struct {
    packets: []const Pdu,
    index: usize = 0,
    scratch: [16]u8 = undefined,

    fn tryNext(r: *FakeReader) !?Pdu {
        if (r.index == r.packets.len) return null;
        const msg = r.packets[r.index];
        r.index += 1;
        @memset(&r.scratch, 0);
        @memcpy(r.scratch[0..msg.data.len], msg.data);
        return .{ .kind = msg.kind, .data = r.scratch[0..msg.data.len] };
    }
};

const Seen = struct {
    bytes: [32]u8 = undefined,
    len: usize = 0,

    fn handle(s: *Seen, msg: Pdu) !void {
        @memcpy(s.bytes[s.len..][0..msg.data.len], msg.data);
        s.len += msg.data.len;
    }
};

test "GPU input pumping preserves modifiers and control ordering across borrowed PDUs" {
    const t = std.testing;
    var pump: Pump = .{};
    defer pump.deinit(t.allocator);
    // Modifier down, control barrier, key press/release, modifier up.
    var reader: FakeReader = .{ .packets = &.{
        .{ .kind = .fastpath, .data = "D" },
        .{ .kind = .tpkt, .data = "control" },
        .{ .kind = .fastpath, .data = "KkU" },
    } };
    var seen: Seen = .{};
    try pump.duringEncode(t.allocator, &reader, &seen, Seen.handle);
    try t.expectEqualStrings("D", seen.bytes[0..seen.len]);
    try t.expect(pump.pending());
    try pump.duringEncode(t.allocator, &reader, &seen, Seen.handle);
    try t.expectEqual(@as(usize, 2), reader.index);
    @memset(&reader.scratch, 0xff);
    const control = (try pump.next(&reader)).?;
    try t.expectEqual(.tpkt, control.kind);
    try t.expectEqualStrings("control", control.data);
    const keys = (try pump.next(&reader)).?;
    try seen.handle(keys);
    try t.expectEqualStrings("DKkU", seen.bytes[0..seen.len]);
    try t.expect(!pump.pending());
}

test "GPU input pumping yields under a continuous input flood" {
    const t = std.testing;
    var pump: Pump = .{};
    defer pump.deinit(t.allocator);
    const messages: [20]Pdu = @splat(.{ .kind = .fastpath, .data = "x" });
    var reader: FakeReader = .{ .packets = &messages };
    var seen: Seen = .{};
    try pump.duringEncode(t.allocator, &reader, &seen, Seen.handle);
    try t.expectEqual(@as(usize, 8), seen.len);
    try pump.duringEncode(t.allocator, &reader, &seen, Seen.handle);
    try pump.duringEncode(t.allocator, &reader, &seen, Seen.handle);
    try t.expectEqual(@as(usize, 20), seen.len);
}
