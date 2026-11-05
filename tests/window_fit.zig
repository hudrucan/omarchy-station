//! Run only on an isolated headless compositor with the synthetic fit-* windows.
const std = @import("std");
const oma = @import("omastation");
const hypr = oma.session.hypr;
const window_fit = oma.session.window_fit;

fn pause() void {
    const t: std.c.timespec = .{ .sec = 0, .nsec = 350 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&t, null);
}

fn geometry(w: hypr.ClientState) window_fit.Rect {
    return .{ .x = w.x, .y = w.y, .width = w.width, .height = w.height };
}

fn find(windows: []const hypr.ClientState, title: []const u8) !hypr.ClientState {
    for (windows) |w| if (std.mem.eql(u8, w.title, title)) return w;
    return error.MissingFixtureWindow;
}

pub fn main(init: std.process.Init) !void {
    const runtime = init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.UnsafeTestEnvironment;
    if (!std.mem.startsWith(u8, runtime, "/tmp/of-")) return error.UnsafeTestEnvironment;
    const gpa = init.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ipc = try hypr.Ipc.fromEnv(init.environ_map);
    const before = try hypr.clients(&ipc, a);
    var buf: [512]u8 = undefined;
    const offscreen = try find(before, "fit-offscreen");
    const oversized = try find(before, "fit-oversized");
    const minimum = try find(before, "fit-minimum");
    const unchanged = try find(before, "fit-unchanged");
    const physical = try find(before, "fit-physical");
    for ([_]hypr.ClientState{ offscreen, oversized, minimum, unchanged }) |w| {
        try ipc.command(gpa, try hypr.formatMoveWindowToWorkspace(&buf, w.address, "1"));
        try ipc.command(gpa, try hypr.formatFloatWindow(&buf, w.address, true));
    }
    try ipc.command(gpa, try hypr.formatMoveWindowToWorkspace(&buf, physical.address, "3"));
    try ipc.command(gpa, try hypr.formatFloatWindow(&buf, physical.address, true));
    try ipc.command(gpa, try hypr.formatResizeWindowPixel(&buf, offscreen.address, 400, 500));
    try ipc.command(gpa, try hypr.formatMoveWindowPixel(&buf, offscreen.address, 3900, 700));
    try ipc.command(gpa, try hypr.formatResizeWindowPixel(&buf, oversized.address, 1400, 1350));
    try ipc.command(gpa, try hypr.formatMoveWindowPixel(&buf, oversized.address, 2000, 100));
    try ipc.command(gpa, try hypr.formatMoveWindowPixel(&buf, minimum.address, 3900, 300));
    try ipc.command(gpa, try hypr.formatResizeWindowPixel(&buf, unchanged.address, 300, 300));
    try ipc.command(gpa, try hypr.formatMoveWindowPixel(&buf, unchanged.address, 1960, 80));
    // Move a fixture onto an inactive workspace before the monitor shrinks.
    try ipc.command(gpa, try hypr.formatMoveWindowToWorkspace(&buf, offscreen.address, "2"));
    pause();
    const original = try hypr.clients(&ipc, a);
    const physical_before = geometry(try find(original, "fit-physical"));
    const unchanged_before = geometry(try find(original, "fit-unchanged"));
    try ipc.command(gpa, try hypr.formatMonitorRule(&buf, "RDP-1", 656, 1280, 60, 1920, 0, 1, 0));
    pause();
    var plan = oma.session.desktop.singlePlan(hypr.fitDesktop(656, 1280, 100), 1920);
    try window_fit.apply(&ipc, gpa, &plan, .resize);
    pause();
    try window_fit.apply(&ipc, gpa, &plan, .position);
    pause();
    const monitors = try hypr.monitors(&ipc, a);
    const m = for (monitors) |m| {
        if (std.mem.eql(u8, m.name, "RDP-1")) break m;
    } else return error.MissingOutput;
    const area = window_fit.workArea(m) orelse return error.InvalidWorkArea;
    const after = try hypr.clients(&ipc, a);
    for ([_][]const u8{ "fit-offscreen", "fit-oversized", "fit-unchanged" }) |title| {
        const w = try find(after, title);
        if (w.x < area.x or w.y < area.y or w.x + w.width > area.x + area.width or w.y + w.height > area.y + area.height) return error.WindowOutsideWorkArea;
    }
    if ((try find(after, "fit-offscreen")).workspace_id != 2) return error.WorkspaceChanged;
    try std.testing.expectEqualDeep(unchanged_before, geometry(try find(after, "fit-unchanged")));
    try std.testing.expectEqualDeep(physical_before, geometry(try find(after, "fit-physical")));
    const min_after = try find(after, "fit-minimum");
    if (min_after.width < 900 or min_after.height < 1400 or min_after.x != area.x or min_after.y != area.y) return error.MinimumWindowNotReachable;
    // No re-expansion when returning to a bigger monitor.
    try ipc.command(gpa, try hypr.formatMonitorRule(&buf, "RDP-1", 2560, 1440, 60, 1920, 0, 1, 0));
    pause();
    plan = oma.session.desktop.singlePlan(hypr.fitDesktop(2560, 1440, 100), 1920);
    const expanded = try hypr.clients(&ipc, a);
    try window_fit.apply(&ipc, gpa, &plan, .resize);
    pause();
    try window_fit.apply(&ipc, gpa, &plan, .position);
    pause();
    const final = try hypr.clients(&ipc, a);
    try std.testing.expectEqualDeep(geometry(try find(expanded, "fit-oversized")), geometry(try find(final, "fit-oversized")));
    std.debug.print("Window fit integration passed: portrait resize, inactive workspace, app minimum, unchanged/physical windows and no enlargement\n", .{});
}
