// A real application-owned SHM cursor, with padding and both channel orders.
#define _GNU_SOURCE
#include <assert.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_pointer *pointer;
static struct xdg_wm_base *wm;
static struct wl_surface *window, *cursor;
static struct wl_buffer *window_buffer, *argb, *abgr, *xrgb, *selected;
static uint32_t enter_serial;

static struct wl_buffer *buffer(int w, int h, int stride, uint32_t format, uint32_t color) {
    int fd = memfd_create("cursor-shm-test", MFD_CLOEXEC);
    assert(fd >= 0 && ftruncate(fd, stride * h) == 0);
    uint8_t *pixels = mmap(NULL, stride * h, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);
    memset(pixels, 0x5a, stride * h);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
            ((uint32_t *)(pixels + y * stride))[x] = color;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, stride * h);
    struct wl_buffer *result = wl_shm_pool_create_buffer(pool, 0, w, h, stride, format);
    wl_shm_pool_destroy(pool);
    munmap(pixels, stride * h);
    close(fd);
    return result;
}

static void set_cursor(void) {
    if (!enter_serial) return;
    wl_pointer_set_cursor(pointer, enter_serial, selected ? cursor : NULL, 3, 5);
    if (selected) {
        wl_surface_attach(cursor, selected, 0, 0);
        wl_surface_damage(cursor, 0, 0, 24, 24);
        wl_surface_commit(cursor);
    }
}

static void enter(void *data, struct wl_pointer *p, uint32_t serial,
                  struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y) {
    (void)data; (void)p; (void)surface; (void)x; (void)y;
    enter_serial = serial;
    set_cursor();
}
static void leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *surface) {
    (void)d; (void)p; (void)s; (void)surface; enter_serial = 0;
}
static void motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p; (void)t; (void)x; (void)y;
}
static void button(void *d, struct wl_pointer *p, uint32_t s, uint32_t t, uint32_t b, uint32_t state) {
    (void)d; (void)p; (void)s; (void)t; (void)b; (void)state;
}
static void axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v) {
    (void)d; (void)p; (void)t; (void)a; (void)v;
}
static const struct wl_pointer_listener pointer_listener = {
    .enter = enter, .leave = leave, .motion = motion, .button = button, .axis = axis,
};
static void capabilities(void *data, struct wl_seat *s, uint32_t caps) {
    (void)data;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !pointer) {
        pointer = wl_seat_get_pointer(s);
        wl_pointer_add_listener(pointer, &pointer_listener, NULL);
    }
}
static const struct wl_seat_listener seat_listener = {.capabilities = capabilities};
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
    (void)data; xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {.ping = ping};
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "wl_compositor"))
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    else if (!strcmp(interface, "wl_shm"))
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "wl_seat")) {
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
        wl_seat_add_listener(seat, &seat_listener, NULL);
    } else if (!strcmp(interface, "xdg_wm_base")) {
        wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    }
}
static void removed(void *d, struct wl_registry *r, uint32_t n) {(void)d; (void)r; (void)n;}
static const struct wl_registry_listener registry_listener = {.global = global, .global_remove = removed};
static void configure(void *data, struct xdg_surface *surface, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(surface, serial);
    wl_surface_attach(window, window_buffer, 0, 0);
    wl_surface_damage(window, 0, 0, 320, 240);
    wl_surface_commit(window);
}
static const struct xdg_surface_listener surface_listener = {.configure = configure};
static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s) {
    (void)d; (void)t; (void)w; (void)h; (void)s;
}
static void close_window(void *d, struct xdg_toplevel *t) {(void)d; (void)t; exit(0);}
static const struct xdg_toplevel_listener top_listener = {.configure = top_configure, .close = close_window};

int main(void) {
    display = wl_display_connect(NULL);
    assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(compositor && shm && wm && seat);
    window_buffer = buffer(320, 240, 320 * 4, WL_SHM_FORMAT_XRGB8888, 0xff303030);
    argb = buffer(24, 24, 28 * 4, WL_SHM_FORMAT_ARGB8888, 0xff2266aa);
    abgr = buffer(24, 24, 28 * 4, WL_SHM_FORMAT_ABGR8888, 0xffaa6622);
    xrgb = buffer(24, 24, 28 * 4, WL_SHM_FORMAT_XRGB8888, 0xff2266aa);
    selected = argb;
    cursor = wl_compositor_create_surface(compositor);
    window = wl_compositor_create_surface(compositor);
    struct xdg_surface *surface = xdg_wm_base_get_xdg_surface(wm, window);
    xdg_surface_add_listener(surface, &surface_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(surface);
    xdg_toplevel_add_listener(top, &top_listener, NULL);
    xdg_toplevel_set_title(top, "cursor-shm-fixture");
    xdg_toplevel_set_app_id(top, "cursor-shm-fixture");
    wl_surface_commit(window);
    for (;;) {
        assert(wl_display_dispatch_pending(display) >= 0);
        assert(wl_display_flush(display) >= 0);
        struct pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        assert(poll(fds, 2, -1) >= 0);
        if (fds[0].revents & (POLLERR | POLLHUP)) break;
        if (fds[0].revents & POLLIN)
            if (wl_display_dispatch(display) < 0) break;
        if (fds[1].revents & POLLIN) {
            char line[32];
            if (!fgets(line, sizeof(line), stdin)) break;
            if (!strcmp(line, "argb\n")) selected = argb;
            else if (!strcmp(line, "abgr\n")) selected = abgr;
            else if (!strcmp(line, "xrgb\n")) selected = xrgb;
            else if (!strcmp(line, "hidden\n")) selected = NULL;
            else return 2;
            set_cursor();
        }
        if (fds[1].revents & POLLHUP) break;
    }
    wl_display_disconnect(display);
    return 0;
}
