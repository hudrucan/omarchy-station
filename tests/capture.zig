//! Run against a static, isolated compositor. Captured pixels never leave memory.
const std = @import("std");
const oma = @import("omastation");
extern "c" fn system(command: [*:0]const u8) c_int;

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const client = try oma.wl.Client.connect(gpa, .{});
    defer client.deinit();
    const output = for (client.output_list.items) |o| {
        if (!o.removed and std.mem.eql(u8, o.name(), "BASE")) break o;
    } else return error.TestOutputMissing;
    var reference: []u8 = &.{};
    defer gpa.free(reference);
    for ([_]bool{ false, true }) |use_dma| {
        const capture = try oma.wl.Capture.init(client, output, .{ .dmabuf = use_dma, .backend = .ext });
        defer capture.deinit();
        const frame = try capture.nextFrame(5000);
        var shadow = oma.server.encoder.Encoder.init(gpa);
        defer shadow.deinit();
        try shadow.reset(frame.width, frame.height);
        _ = try shadow.diff(frame.data, frame.stride);
        const diff_start = nowNs();
        for (0..30) |_| _ = try shadow.diff(frame.data, frame.stride);
        std.debug.print("Static-frame {s} diff: {d:.2} ms/frame\n", .{ if (use_dma) "DMA-BUF" else "SHM", @as(f64, @floatFromInt(nowNs() - diff_start)) / 30e6 });
        const rgb = try gpa.alloc(u8, @as(usize, frame.width) * frame.height * 3);
        defer gpa.free(rgb);
        for (0..frame.height) |y| for (0..frame.width) |x| {
            const src = y * frame.stride + x * 4;
            const dst = (y * frame.width + x) * 3;
            @memcpy(rgb[dst..][0..3], frame.data[src..][0..3]);
        };
        if (!use_dma) {
            reference = try gpa.dupe(u8, rgb);
        } else {
            if (frame.dma == null) return error.DmaBufNotSelected;
            if (!std.mem.eql(u8, reference, rgb)) return error.DmaBufPixelMismatch;
            try frame.dma.?.endRead();
            var encoder = try oma.codec.vaapi_h264.Encoder.init(gpa, .{ .width = frame.width, .height = frame.height, .crop = frame.width % 2 == 0 and frame.height % 2 == 0 });
            defer encoder.deinit();
            var bitstream: std.ArrayList(u8) = .empty;
            defer bitstream.deinit(gpa);
            const info = try encoder.encodeDmaBuf(frame.dma.?.descriptor(), true, &bitstream);
            if (bitstream.items.len == 0 or !info.idr) return error.EmptyDmaBufFrame;
            std.debug.print("DMA-BUF pixels match SHM; AVC420 import encoded {d}x{d}, {d} bytes\n", .{ frame.width, frame.height, bitstream.items.len });
            for ([_]bool{ false, true }) |direct| {
                if (!direct) try frame.dma.?.beginRead() else try frame.dma.?.endRead();
                const start = nowNs();
                for (0..30) |_| {
                    bitstream.clearRetainingCapacity();
                    if (direct) {
                        _ = try encoder.encodeDmaBuf(frame.dma.?.descriptor(), false, &bitstream);
                    } else {
                        _ = try encoder.encode(frame.data, frame.stride, false, &bitstream);
                    }
                }
                std.debug.print("Static-frame {s}: {d:.2} ms/frame\n", .{ if (direct) "DMA-BUF import" else "CPU upload", @as(f64, @floatFromInt(nowNs() - start)) / 30e6 });
            }
            if (init.environ_map.get("OMASTATION_CAPTURE_TEST_ALLOW_RESIZE") != null) {
                const runtime = init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.UnsafeTestEnvironment;
                if (!std.mem.startsWith(u8, runtime, "/tmp/")) return error.UnsafeTestEnvironment;
                const held = frame.*;
                const held_set = capture.front_set.?;
                if (system("hyprctl eval 'hl.monitor({output=\"BASE\",mode=\"960x641@60\",position=\"auto\",scale=1})' >/dev/null") != 0) return error.ResizeFailed;
                const deadline = nowNs() + 5 * std.time.ns_per_s;
                while (capture.constraints == null or capture.constraints.?.width != 960 or capture.constraints.?.height != 641) {
                    if (nowNs() >= deadline) return error.ResizeTimeout;
                    _ = try client.dispatchTimeout(100);
                }
                try capture.requestFrame();
                while (capture.ready_idx == null) {
                    if (nowNs() >= deadline) return error.ResizeTimeout;
                    _ = try client.dispatchTimeout(100);
                }
                if (capture.retired != held_set) return error.CaptureBufferNotRetained;
                try held.dma.?.beginRead();
                for (0..held.height) |y| for (0..held.width) |x| {
                    const src = y * held.stride + x * 4;
                    const dst = (y * held.width + x) * 3;
                    if (!std.mem.eql(u8, held.data[src..][0..3], rgb[dst..][0..3])) return error.HeldFrameChanged;
                };
                try held.dma.?.endRead();
                const resized = capture.takeFrame() orelse return error.ResizedFrameMissing;
                if (resized.width != 960 or resized.height != 641 or resized.dma == null or capture.retired != null) return error.BadResizedFrame;
                try resized.dma.?.endRead();
                var resized_encoder = try oma.codec.vaapi_h264.Encoder.init(gpa, .{ .width = resized.width, .height = resized.height, .crop = false });
                defer resized_encoder.deinit();
                bitstream.clearRetainingCapacity();
                _ = try resized_encoder.encodeDmaBuf(resized.dma.?.descriptor(), true, &bitstream);
                std.debug.print("DMA-BUF resize retained the held frame, released it on take, and encoded 960x641\n", .{});
            }
        }
    }
}
