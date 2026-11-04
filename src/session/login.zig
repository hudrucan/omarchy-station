//! Single-user, on-demand desktop startup. Authentication must finish before prepare().
//! systemd owns the PAM session and compositor; this unprivileged listener survives logout.
const std = @import("std");
const c = @import("c");
const hypr = @import("hypr.zig");

extern "c" var environ: [*:null]?[*:0]u8;

pub const Error = error{ SessionStartFailed, SessionStartTimeout, InvalidSession, WrongSessionUser } || hypr.Error;
pub const Endpoint = struct {
    ipc: hypr.Ipc,
    display_buf: [256]u8 = undefined,
    display_len: usize,

    pub fn display(e: *const Endpoint) []const u8 {
        return e.display_buf[0..e.display_len];
    }
};

pub const Login = struct {
    user: []const u8,
    runtime_dir: []const u8,
    starter: [:0]const u8 = "/usr/lib/omastation/omastation-session-start",
    timeout_ms: i64 = 40_000,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn authorize(l: *const Login, user: []const u8) Error!void {
        if (!std.mem.eql(u8, l.user, user)) return error.WrongSessionUser;
    }

    pub fn prepare(l: *Login, gpa: std.mem.Allocator, user: []const u8) Error!Endpoint {
        try l.authorize(user);
        const until = nowMs() + l.timeout_ms;
        while (!l.mutex.tryLock()) {
            if (nowMs() >= until) return error.SessionStartTimeout;
            pause();
        }
        defer l.mutex.unlock();
        var output: [1024]u8 = undefined;
        const n = try run(l.starter, &output, until);
        const endpoint = try parse(l.runtime_dir, output[0..n]);
        // Reject stale instance files before touching plugins or taking the desktop.
        const reply = try endpoint.ipc.request(gpa, "j/version");
        defer gpa.free(reply);
        return endpoint;
    }
};

fn component(s: []const u8) bool {
    if (s.len == 0 or s.len > 160 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    for (s) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    return true;
}

pub fn parse(runtime: []const u8, output: []const u8) Error!Endpoint {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output, "\n"), '\n');
    const instance = lines.next() orelse return error.InvalidSession;
    const socket = lines.next() orelse return error.InvalidSession;
    if (lines.next() != null or !component(instance) or !component(socket)) return error.InvalidSession;
    var e: Endpoint = .{ .ipc = .{}, .display_len = 0 };
    const p = std.fmt.bufPrint(&e.ipc.path_buf, "{s}/hypr/{s}/.socket.sock", .{ runtime, instance }) catch return error.InvalidSession;
    if (p.len >= 108) return error.InvalidSession;
    e.ipc.path_len = p.len;
    const d = std.fmt.bufPrint(&e.display_buf, "{s}/{s}", .{ runtime, socket }) catch return error.InvalidSession;
    if (d.len >= 108) return error.InvalidSession;
    e.display_len = d.len;
    return e;
}

// Bounded child lifetime and output; no passwords or client-controlled arguments are passed.
fn run(path: [:0]const u8, output: []u8, until: i64) Error!usize {
    var pipe: [2]c_int = undefined;
    if (c.pipe2(&pipe, c.O_CLOEXEC) != 0) return error.SessionStartFailed;
    defer _ = c.close(pipe[0]);
    var write_open = true;
    defer if (write_open) {
        _ = c.close(pipe[1]);
    };
    if (c.fcntl(pipe[0], c.F_SETFL, c.O_NONBLOCK) != 0) return error.SessionStartFailed;
    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return error.SessionStartFailed;
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    if (c.posix_spawn_file_actions_adddup2(&actions, pipe[1], 1) != 0 or
        c.posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", c.O_RDONLY, 0) != 0) return error.SessionStartFailed;
    var attr: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attr) != 0) return error.SessionStartFailed;
    defer _ = c.posix_spawnattr_destroy(&attr);
    var mask: c.sigset_t = undefined;
    _ = c.sigemptyset(&mask);
    if (c.posix_spawnattr_setflags(&attr, c.POSIX_SPAWN_SETPGROUP | c.POSIX_SPAWN_SETSIGMASK) != 0 or
        c.posix_spawnattr_setpgroup(&attr, 0) != 0 or c.posix_spawnattr_setsigmask(&attr, &mask) != 0) return error.SessionStartFailed;
    const argv = [_:null]?[*:0]const u8{path};
    var pid: c.pid_t = 0;
    if (c.posix_spawn(&pid, path.ptr, &actions, &attr, @ptrCast(@constCast(&argv)), @ptrCast(environ)) != 0) return error.SessionStartFailed;
    _ = c.close(pipe[1]);
    write_open = false;
    var reaped = false;
    defer if (!reaped) {
        _ = c.kill(-pid, c.SIGKILL);
        _ = c.waitpid(pid, null, 0);
    };
    var len: usize = 0;
    var eof = false;
    while (nowMs() < until) {
        if (!eof) {
            var extra: [1]u8 = undefined;
            const dst = if (len < output.len) output[len..] else &extra;
            const n = c.read(pipe[0], dst.ptr, dst.len);
            if (n > 0) {
                if (len == output.len) return error.InvalidSession;
                len += @intCast(n);
            } else if (n == 0) {
                eof = true;
            } else if (c.__errno_location().* != c.EAGAIN and c.__errno_location().* != c.EINTR) return error.SessionStartFailed;
        }
        if (eof) {
            var status: c_int = 0;
            const r = c.waitpid(pid, &status, c.WNOHANG);
            if (r == pid) {
                reaped = true;
                if (status != 0) return error.SessionStartFailed;
                return len;
            }
            if (r < 0) return error.SessionStartFailed;
        }
        pause();
    }
    return error.SessionStartTimeout;
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

fn pause() void {
    const ts: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 10_000_000 };
    _ = c.nanosleep(&ts, null);
}

test "login endpoint uses explicit per-session sockets and rejects malformed paths" {
    const e = try parse("/run/user/1000", "abc_123\nwayland-1\n");
    try std.testing.expectEqualStrings("/run/user/1000/wayland-1", e.display());
    try std.testing.expectEqualStrings("/run/user/1000/hypr/abc_123/.socket.sock", e.ipc.path_buf[0..e.ipc.path_len]);
    for ([_][]const u8{ "../abc\nwayland-1\n", "abc\n/tmp/socket\n", "abc\n..\n", "abc\n", "abc\nwayland-1\nextra\n" }) |s|
        try std.testing.expectError(error.InvalidSession, parse("/run/user/1000", s));
}

test "login: another NLA user cannot start or take over the listener owner's desktop" {
    var l: Login = .{ .user = "desk", .runtime_dir = "/run/user/1000", .starter = "/must-not-be-executed" };
    try std.testing.expectError(error.WrongSessionUser, l.prepare(std.testing.allocator, "other"));
}

test "login: starter failures and timeouts cannot become a desktop" {
    var output: [128]u8 = undefined;
    try std.testing.expectError(error.SessionStartFailed, run("/bin/false", &output, nowMs() + 1000));
    try std.testing.expectError(error.SessionStartTimeout, run("/bin/true", &output, nowMs() - 1));
}

test "login: authenticated startup discovers a live IPC endpoint and rejects it after exit" {
    var template = "/tmp/oma-login-XXXXXX".*;
    const root = c.mkdtemp(&template) orelse return error.TestUnexpectedResult;
    defer _ = c.rmdir(root);
    const gpa = std.testing.allocator;
    const runtime = std.mem.span(root);
    const hypr_dir = try std.fmt.allocPrintSentinel(gpa, "{s}/hypr", .{runtime}, 0);
    defer gpa.free(hypr_dir);
    _ = c.mkdir(hypr_dir.ptr, 0o700);
    defer _ = c.rmdir(hypr_dir.ptr);
    const instance_dir = try std.fmt.allocPrintSentinel(gpa, "{s}/hypr/abc", .{runtime}, 0);
    defer gpa.free(instance_dir);
    _ = c.mkdir(instance_dir.ptr, 0o700);
    defer _ = c.rmdir(instance_dir.ptr);
    const starter = try std.fmt.allocPrintSentinel(gpa, "{s}/start", .{runtime}, 0);
    defer gpa.free(starter);
    const script = "#!/bin/sh\nprintf 'abc\\nwayland-1\\n'\n";
    const file = c.open(starter.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o700));
    try std.testing.expect(file >= 0);
    try std.testing.expectEqual(@as(isize, script.len), c.write(file, script.ptr, script.len));
    _ = c.close(file);
    defer _ = c.unlink(starter.ptr);

    const socket_path = try std.fmt.allocPrintSentinel(gpa, "{s}/.socket.sock", .{instance_dir}, 0);
    defer gpa.free(socket_path);
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    @memcpy(addr.sun_path[0..socket_path.len], socket_path);
    try std.testing.expectEqual(@as(c_int, 0), c.bind(fd, .{ .__sockaddr__ = @ptrCast(&addr) }, @sizeOf(c.struct_sockaddr_un)));
    defer _ = c.unlink(socket_path.ptr);
    try std.testing.expectEqual(@as(c_int, 0), c.listen(fd, 1));
    const timeout: c.struct_timeval = .{ .tv_sec = 2, .tv_usec = 0 };
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(c.struct_timeval));
    const Fake = struct {
        fn answer(listen: c_int) void {
            const client = c.accept4(listen, .{ .__sockaddr__ = null }, null, c.SOCK_CLOEXEC);
            if (client < 0) return;
            defer _ = c.close(client);
            var buf: [64]u8 = undefined;
            const n = c.recv(client, &buf, buf.len, 0);
            if (n <= 0 or !std.mem.eql(u8, buf[0..@intCast(n)], "j/version")) return;
            const reply = "{\"version\":\"test\"}";
            _ = c.send(client, reply.ptr, reply.len, c.MSG_NOSIGNAL);
        }
    };
    var l: Login = .{ .user = "desk", .runtime_dir = runtime, .starter = starter };
    const thread = try std.Thread.spawn(.{}, Fake.answer, .{fd});
    {
        defer thread.join();
        const endpoint = try l.prepare(gpa, "desk");
        const display = try std.fmt.allocPrint(gpa, "{s}/wayland-1", .{runtime});
        defer gpa.free(display);
        try std.testing.expectEqualStrings(display, endpoint.display());
    }
    _ = c.unlink(socket_path.ptr);
    try std.testing.expectError(error.IpcFailed, l.prepare(gpa, "desk"));
}
