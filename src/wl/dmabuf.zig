//! Linear, CPU-readable capture buffers shared with Wayland and VA-API.
//! Async wl_buffer creation lets unsupported imports fall back without a protocol error.
const std = @import("std");
const c = @import("c");
const wire = @import("wire.zig");
const sys = @import("sys.zig");
const P = wire.proto;
const dma = @import("../core/dmabuf.zig");

pub const xrgb8888 = dma.xrgb8888;
pub const argb8888 = dma.argb8888;
pub const Hook = struct { ctx: *anyopaque, func: *const fn (*anyopaque) void };

pub const Buffer = struct {
    bo: *c.struct_gbm_bo,
    fd: c_int,
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
    data: []u8,
    proxy: ?P.WlBuffer = null,
    params: ?P.ZwpLinuxBufferParamsV1 = null,
    requested: bool = false,
    pool: *Pool,
    reading: bool = false,

    pub fn descriptor(b: *const Buffer) dma.Frame {
        return .{ .fd = b.fd, .width = b.width, .height = b.height, .stride = b.stride, .format = b.format, .size = @intCast(b.data.len) };
    }

    pub fn beginRead(b: *Buffer) wire.Error!void {
        if (b.reading) return;
        try sync(b.fd, c.DMA_BUF_SYNC_START | c.DMA_BUF_SYNC_READ);
        b.reading = true;
    }

    pub fn endRead(b: *Buffer) wire.Error!void {
        if (!b.reading) return;
        try sync(b.fd, c.DMA_BUF_SYNC_END | c.DMA_BUF_SYNC_READ);
        b.reading = false;
    }

    fn onParams(b: *Buffer, msg: *wire.Message) wire.Error!void {
        switch (try msg.decode(P.ZwpLinuxBufferParamsV1)) {
            .created => |v| b.proxy = v.buffer,
            .failed => b.pool.failed = true,
        }
        if (b.params) |p| try p.destroy(b.pool.conn);
        b.params = null;
        b.pool.pending -= 1;
        if (b.pool.pending == 0) b.pool.hook.func(b.pool.hook.ctx);
    }
};

pub const Pool = struct {
    gpa: std.mem.Allocator,
    conn: *wire.Connection,
    device: *c.struct_gbm_device,
    drm_fd: c_int,
    device_id: u64,
    buffers: [2]Buffer = undefined,
    count: usize = 0,
    pending: usize = 0,
    failed: bool = false,
    hook: Hook,

    pub fn create(gpa: std.mem.Allocator, conn: *wire.Connection, manager: P.ZwpLinuxDmabufV1, dev: u64, width: u32, height: u32, format: u32, hook: Hook) wire.Error!*Pool {
        if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidArgument;
        const fd = try openRenderNode(dev);
        errdefer sys.close(fd);
        const device = c.gbm_create_device(fd) orelse return error.Unsupported;
        errdefer c.gbm_device_destroy(device);
        const pool = try gpa.create(Pool);
        pool.* = .{ .gpa = gpa, .conn = conn, .device = device, .drm_fd = fd, .device_id = dev, .hook = hook };
        errdefer {
            pool.destroyBuffers();
            gpa.destroy(pool);
        }
        const aw = (width + 15) & ~@as(u32, 15);
        const ah = (height + 15) & ~@as(u32, 15);
        for (&pool.buffers) |*b| {
            const bo = c.gbm_bo_create(device, aw, ah, format, c.GBM_BO_USE_RENDERING | c.GBM_BO_USE_LINEAR) orelse return error.Unsupported;
            const dma_fd = c.gbm_bo_get_fd(bo);
            if (dma_fd < 0 or c.gbm_bo_get_modifier(bo) != 0 or c.gbm_bo_get_plane_count(bo) != 1 or c.gbm_bo_get_offset(bo, 0) != 0) {
                sys.close(dma_fd);
                c.gbm_bo_destroy(bo);
                return error.Unsupported;
            }
            const stride = c.gbm_bo_get_stride(bo);
            const len = @as(usize, stride) * ah;
            const mem = std.c.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, dma_fd, 0);
            if (mem == std.c.MAP_FAILED) {
                sys.close(dma_fd);
                c.gbm_bo_destroy(bo);
                return error.Unsupported;
            }
            b.* = .{ .bo = bo, .fd = dma_fd, .width = aw, .height = ah, .stride = stride, .format = format, .data = @as([*]u8, @ptrCast(mem))[0..len], .pool = pool };
            pool.count += 1;
            try sync(dma_fd, c.DMA_BUF_SYNC_START | c.DMA_BUF_SYNC_WRITE);
            @memset(b.data, 0);
            try sync(dma_fd, c.DMA_BUF_SYNC_END | c.DMA_BUF_SYNC_WRITE);
            const params = try manager.createParams(conn);
            b.params = params;
            conn.setHandler(params.id, wire.Handler.init(Buffer, b, Buffer.onParams));
            try params.add(conn, dma_fd, 0, 0, stride, 0, 0);
            try params.create(conn, @intCast(width), @intCast(height), format, 0);
            b.requested = true;
            pool.pending += 1;
        }
        return pool;
    }

    fn destroyBuffers(pool: *Pool) void {
        for (pool.buffers[0..pool.count]) |*b| {
            b.endRead() catch {};
            if (b.params) |p| {
                if (b.requested) {
                    // A resize can retire a pool before created/failed arrives. Keep
                    // only the connection as callback context, never the freed buffer.
                    pool.conn.setHandler(p.id, wire.Handler.init(wire.Connection, pool.conn, discardParams));
                } else p.destroy(pool.conn) catch {};
            }
            if (b.proxy) |p| p.destroy(pool.conn) catch {};
            _ = std.c.munmap(@ptrCast(@alignCast(b.data.ptr)), b.data.len);
            sys.close(b.fd);
            c.gbm_bo_destroy(b.bo);
        }
    }

    pub fn destroy(pool: *Pool) void {
        pool.destroyBuffers();
        c.gbm_device_destroy(pool.device);
        sys.close(pool.drm_fd);
        pool.gpa.destroy(pool);
    }
};

fn discardParams(conn: *wire.Connection, msg: *wire.Message) wire.Error!void {
    switch (try msg.decode(P.ZwpLinuxBufferParamsV1)) {
        .created => |v| try v.buffer.destroy(conn),
        .failed => {},
    }
    try (P.ZwpLinuxBufferParamsV1{ .id = msg.object }).destroy(conn);
}

fn sync(fd: c_int, flags: u64) wire.Error!void {
    var value: c.struct_dma_buf_sync = .{ .flags = flags };
    while (c.ioctl(fd, c.DMA_BUF_IOCTL_SYNC, &value) != 0) {
        switch (std.c.errno(-1)) {
            .INTR, .AGAIN => continue,
            else => return error.Unsupported,
        }
    }
}

fn openRenderNode(device: u64) wire.Error!c_int {
    // The compositor can announce either node of a GPU; resolve its render node.
    var dev: c.drmDevicePtr = null;
    if (c.drmGetDeviceFromDevId(device, 0, &dev) != 0) return error.Unsupported;
    defer c.drmFreeDevice(&dev);
    if (dev.*.available_nodes & (@as(c_int, 1) << c.DRM_NODE_RENDER) == 0) return error.Unsupported;
    const fd = c.open(dev.*.nodes[c.DRM_NODE_RENDER], c.O_RDWR | c.O_CLOEXEC);
    return if (fd < 0) error.Unsupported else fd;
}

test "retired DMA-BUF imports destroy late buffers and params without pool state" {
    const t = std.testing;
    for ([_]bool{ false, true }) |created| {
        const sockets = try sys.socketPair();
        const conn = try wire.Connection.initFd(t.allocator, sockets[0]);
        defer conn.deinit();
        const peer = try wire.Connection.initFd(t.allocator, sockets[1]);
        defer peer.deinit();
        const params = try conn.newIdVersioned(.zwp_linux_buffer_params_v1, 3);
        conn.setHandler(params, wire.Handler.init(wire.Connection, conn, discardParams));
        if (created) {
            try peer.request(params, 0, &.{.{ .new_id = wire.server_id_start }});
        } else {
            try peer.request(params, 1, &.{});
        }
        try peer.flush();
        _ = try conn.dispatchTimeout(1000);
        try conn.flush();
        var requests: [32]u8 = undefined;
        const n = (try sys.readNonBlock(sockets[1], &requests)) orelse return error.MissingCleanup;
        try t.expectEqual(@as(usize, if (created) 16 else 8), n);
        if (created) {
            try t.expectEqual(wire.server_id_start, std.mem.readInt(u32, requests[0..4], .little));
            try t.expectEqual(params, std.mem.readInt(u32, requests[8..12], .little));
        } else {
            try t.expectEqual(params, std.mem.readInt(u32, requests[0..4], .little));
        }
    }
}
