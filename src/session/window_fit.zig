//! Keep floating windows reachable after an RDP output changes size or scale.
const std = @import("std");
const hypr = @import("hypr.zig");
const multimon = @import("multimon.zig");

const log = std.log.scoped(.window_fit);

pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };
pub const Phase = enum { resize, position };

/// Hyprland reports pixel modes, but window geometry and reserved zones are logical.
pub fn workArea(m: hypr.MonitorState) ?Rect {
    if (m.disabled or !std.math.isFinite(m.scale) or m.scale <= 0) return null;
    const rotated = m.transform % 2 == 1;
    const w = @floor(@as(f64, @floatFromInt(if (rotated) m.height else m.width)) / m.scale);
    const h = @floor(@as(f64, @floatFromInt(if (rotated) m.width else m.height)) / m.scale);
    if (w < 1 or h < 1 or w > std.math.maxInt(i32) or h > std.math.maxInt(i32)) return null;
    const left = @max(0, m.reserved[0]);
    const top = @max(0, m.reserved[1]);
    const width = @as(i32, @intFromFloat(w)) -| left -| @max(0, m.reserved[2]);
    const height = @as(i32, @intFromFloat(h)) -| top -| @max(0, m.reserved[3]);
    if (width <= 0 or height <= 0) return null;
    return .{ .x = m.x +| left, .y = m.y +| top, .width = width, .height = height };
}

/// No enlargement or saved geometry: growing a display leaves the user's layout alone.
pub fn fit(w: hypr.ClientState, area: Rect, phase: Phase) ?Rect {
    if (area.width <= 0 or area.height <= 0 or !w.mapped or w.hidden or !w.floating or w.fullscreen != 0 or
        std.mem.startsWith(u8, w.workspace, "special:") or w.width <= 0 or w.height <= 0)
        return null;
    const width = if (phase == .resize) @min(w.width, area.width) else w.width;
    const height = if (phase == .resize) @min(w.height, area.height) else w.height;
    const result: Rect = .{
        .x = std.math.clamp(w.x, area.x, area.x +| @max(0, area.width - width)),
        .y = std.math.clamp(w.y, area.y, area.y +| @max(0, area.height - height)),
        .width = width,
        .height = height,
    };
    if (result.x == w.x and result.y == w.y and width == w.width and height == w.height) return null;
    return result;
}

/// One pass after a settled layout. All workspaces on the RDP outputs are included;
/// physical monitors, focus, fullscreen state and tiling are never changed.
pub fn apply(ipc: *const hypr.Ipc, gpa: std.mem.Allocator, plan: *const multimon.SessionPlan, phase: Phase) (hypr.Error || error{OutputNotReady})!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const monitors = try hypr.monitors(ipc, a);
    // Monitor rules are asynchronous. Never fit against a superseded pixel mode or scale.
    for (plan.outputs[0..plan.count]) |*o| {
        const m = for (monitors) |m| {
            if (std.mem.eql(u8, m.name, o.name()) and !m.disabled) break m;
        } else return error.OutputNotReady;
        const scale = @as(f64, @floatFromInt(o.scale_k)) / 120.0;
        if (m.width != o.width or m.height != o.height or m.x != o.x or m.y != o.y or
            @abs(m.scale - scale) > 0.001) return error.OutputNotReady;
    }
    const windows = try hypr.clients(ipc, a);
    var changed: usize = 0;
    for (windows) |w| {
        const m = for (monitors) |m| {
            if (m.id == w.monitor) break m;
        } else continue;
        const remote = for (plan.outputs[0..plan.count]) |*o| {
            if (std.mem.eql(u8, m.name, o.name())) break true;
        } else false;
        if (!remote) continue;
        const target = fit(w, workArea(m) orelse continue, phase) orelse continue;
        applyWindow(ipc, gpa, w, target) catch |err| {
            // A window may close while IPC is in flight; still rescue the others.
            log.warn("could not fit a floating window: {t}", .{err});
            continue;
        };
        changed += 1;
    }
    if (changed != 0) log.info("fit {d} floating window(s) to the RDP work area", .{changed});
}

fn applyWindow(ipc: *const hypr.Ipc, gpa: std.mem.Allocator, w: hypr.ClientState, target: Rect) (hypr.Error || error{NoSpaceLeft})!void {
    var buf: [512]u8 = undefined;
    // Resizing floats is centered. Move afterwards, even if only size changed.
    // An app may enforce a larger minimum: the top-left remains reachable.
    if (w.width != target.width or w.height != target.height) {
        try ipc.command(gpa, try hypr.formatResizeWindowPixel(&buf, w.address, target.width, target.height));
    }
    try ipc.command(gpa, try hypr.formatMoveWindowPixel(&buf, w.address, target.x, target.y));
}

test "window fit: 2K to portrait rescues offscreen windows and shrinks only overflowing dimensions" {
    const area: Rect = .{ .x = 1920, .y = 32, .width = 656, .height = 1248 };
    const offscreen: hypr.ClientState = .{ .address = 1, .floating = true, .x = 3900, .y = 900, .width = 600, .height = 500 };
    try std.testing.expectEqualDeep(Rect{ .x = 1976, .y = 780, .width = 600, .height = 500 }, fit(offscreen, area, .resize).?);
    var oversized = offscreen;
    oversized.x = 2000;
    oversized.y = 100;
    oversized.width = 1600;
    oversized.height = 1500;
    try std.testing.expectEqualDeep(area, fit(oversized, area, .resize).?);
    oversized.height = 400;
    try std.testing.expectEqualDeep(Rect{ .x = 1920, .y = 100, .width = 656, .height = 400 }, fit(oversized, area, .resize).?);
    oversized.width = 400;
    oversized.height = 1500;
    try std.testing.expectEqualDeep(Rect{ .x = 2000, .y = 32, .width = 400, .height = 1248 }, fit(oversized, area, .resize).?);
}

test "window fit: logical work area respects fractional scale, rotation and reserved bar/dock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const monitors = try hypr.parseMonitors(arena.allocator(),
        \\[{"name":"RDP-1","width":1280,"height":2560,"refreshRate":60,
        \\"x":-1024,"y":-20,"scale":1.25,"reserved":[10,32,14,48]}]
    );
    var m = monitors[0];
    try std.testing.expectEqualDeep(Rect{ .x = -1014, .y = 12, .width = 1000, .height = 1968 }, workArea(m).?);
    m.transform = 1;
    try std.testing.expectEqualDeep(Rect{ .x = -1014, .y = 12, .width = 2024, .height = 944 }, workArea(m).?);
    m.reserved[0] = 3000;
    try std.testing.expect(workArea(m) == null);
    m.scale = 0;
    try std.testing.expect(workArea(m) == null);
}

test "window fit: fitting windows stay put, including after the screen grows" {
    const w: hypr.ClientState = .{ .address = 1, .floating = true, .x = -950, .y = -40, .width = 400, .height = 500 };
    try std.testing.expect(fit(w, .{ .x = -1000, .y = -50, .width = 656, .height = 1280 }, .resize) == null);
    try std.testing.expect(fit(w, .{ .x = -1000, .y = -50, .width = 2560, .height = 1440 }, .resize) == null);
    var left = w;
    left.x = -1200;
    left.y = -100;
    try std.testing.expectEqualDeep(Rect{ .x = -1000, .y = -50, .width = 400, .height = 500 }, fit(left, .{ .x = -1000, .y = -50, .width = 656, .height = 1280 }, .resize).?);
}

test "window fit: tiled, fullscreen, maximized, hidden and scratchpad windows are left to Hyprland" {
    const area: Rect = .{ .x = 0, .y = 0, .width = 400, .height = 800 };
    const w: hypr.ClientState = .{ .address = 1, .floating = true, .x = 1500, .y = 100, .width = 1000, .height = 1000 };
    var skipped = w;
    skipped.floating = false;
    try std.testing.expect(fit(skipped, area, .resize) == null);
    skipped = w;
    skipped.fullscreen = 1;
    try std.testing.expect(fit(skipped, area, .resize) == null);
    skipped.fullscreen = 2;
    try std.testing.expect(fit(skipped, area, .resize) == null);
    skipped = w;
    skipped.hidden = true;
    try std.testing.expect(fit(skipped, area, .resize) == null);
    skipped = w;
    skipped.mapped = false;
    try std.testing.expect(fit(skipped, area, .resize) == null);
    skipped = w;
    skipped.workspace = "special:stash";
    try std.testing.expect(fit(skipped, area, .resize) == null);
}

test "window fit: position pass respects the app minimum and anchors an oversized window at the top-left" {
    const area: Rect = .{ .x = 1920, .y = 32, .width = 656, .height = 1248 };
    var w: hypr.ClientState = .{ .address = 1, .floating = true, .x = 1798, .y = -60, .width = 900, .height = 1400 };
    try std.testing.expectEqualDeep(Rect{ .x = 1920, .y = 32, .width = 900, .height = 1400 }, fit(w, area, .position).?);
    w.x = area.x;
    w.y = area.y;
    try std.testing.expect(fit(w, area, .position) == null);
}
