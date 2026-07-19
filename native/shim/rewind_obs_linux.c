/*
 * rewind_obs_linux.c — Linux libobs backend for Rewind's C shim.
 *
 * Implements every `rw_plat_*` function declared in rewind_obs_internal.h
 * for Linux: X11 (xshm_input_v2 display capture / xcomposite_input window
 * capture) and Wayland (linux-pipewire's xdg-desktop-portal-backed capture
 * source) video, PulseAudio audio, a VAAPI/NVENC/x264 encoder fallback
 * ladder, and the shim-directory-relative SDK/module path discovery.
 * Compiled only when REWIND_USE_LIBOBS is defined and on __linux__ (see
 * hook/build.dart); the whole body is guarded so an accidental compile on
 * any other configuration is a harmless empty translation unit.
 *
 * See native/shim/README.md's Linux section for exactly what's verified
 * against the pinned libobs 32.1.2 source vs. still an assumption. Unlike
 * the macOS backend (real-world exercised) and the Windows backend
 * (CI-compiled against the real SDK), this backend is implemented and
 * CI-compiled on a real Linux runner, but has NEVER been run — no real
 * Linux desktop, X server, or Wayland compositor has executed this code.
 * Treat every runtime claim here as "should work per the source", not
 * "confirmed working".
 *
 * License: GPLv3.
 */
#if defined(REWIND_USE_LIBOBS) && defined(__linux__)

#include "rewind_obs.h"
#include "rewind_obs_internal.h"

#include <obs-nix-platform.h>

#include <dlfcn.h>
#include <unistd.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/types.h>

/* Xlib-xcb.h needs Xlib.h's Display type in scope first. */
#include <X11/Xlib.h>
#include <X11/Xlib-xcb.h>
#include <xcb/xcb.h>
#include <xcb/randr.h>

/* ---- session type: X11 vs Wayland --------------------------------------
 *
 * libobs itself has no auto-detection: obs_nix_platform defaults to
 * OBS_NIX_PLATFORM_X11_EGL (libobs/obs-nix-platform.c) and the official
 * frontend only ever calls obs_set_nix_platform() itself, driven by Qt's
 * own QApplication::platformName() (frontend/OBSApp.cpp, at the pinned tag
 * — "xcb" vs a "wayland*"-prefixed name). This shim has no Qt, so session
 * type is detected the same way most non-Qt Linux tooling does: a
 * WAYLAND_DISPLAY environment variable means a Wayland session is running
 * (set by every compositor for clients that want it); its absence falls
 * back to X11, matching obs_nix_platform's own built-in default. This is
 * called once, early, from rw_plat_pre_video_setup() — BEFORE
 * obs_reset_video() creates the graphics device, since libobs-opengl's own
 * gl-nix.c dispatches between its X11/EGL and Wayland/EGL backends by
 * calling obs_get_nix_platform() the first time a GL context is created
 * (init_winsys() in gl-nix.c) — too late to change afterwards.
 */
enum rw_linux_session { RW_SESSION_X11, RW_SESSION_WAYLAND };
static enum rw_linux_session g_lnx_session = RW_SESSION_X11;

static enum rw_linux_session detect_session(void) {
    const char *wayland = getenv("WAYLAND_DISPLAY");
    return (wayland && wayland[0]) ? RW_SESSION_WAYLAND : RW_SESSION_X11;
}

/* ---- SDK / module path discovery (mirrors the macOS backend: dladdr +
 * realpath, both POSIX, identical on Linux) ------------------------------ */

int rw_plat_own_dir(char *out, size_t out_size) {
    Dl_info info;
    if (!dladdr((void *)&rewind_obs_init, &info) || !info.dli_fname) return 0;
    char resolved[PATH_MAX];
    if (!realpath(info.dli_fname, resolved)) return 0;
    char *slash = strrchr(resolved, '/');
    if (!slash) return 0;
    size_t len = (size_t)(slash - resolved);
    if (len >= out_size) return 0;
    memcpy(out, resolved, len);
    out[len] = '\0';
    return 1;
}

char *rw_plat_realpath(const char *path, char *resolved) {
    return realpath(path, resolved);
}

/* Packaged-app SDK candidate: "<shim dir>" itself, same flat-colocation
 * assumption as the Windows backend (tools/bundle_obs_windows.ps1 drops
 * obs-plugins/+data/ directly beside the compiled DLL). NOTE: unlike
 * macOS/Windows, there is currently no tools/bundle_obs_linux.sh — this
 * task scoped packaging out (see native/shim/README.md and the Flutter
 * Linux desktop plugin-support gaps it documents). This candidate exists
 * so a future bundler script has an obvious, already-wired place to land:
 * "flat, next to the shim .so" mirrors Windows exactly. Entirely
 * unexercised until that script exists. */
int rw_plat_sdk_dir_candidate(const char *shim_dir, char *out, size_t out_size) {
    if (has_sdk_layout(shim_dir)) {
        snprintf(out, out_size, "%s", shim_dir);
        return 1;
    }
    return 0;
}

/* %module% is substituted by libobs per discovered module. Linux plugin
 * modules build as flat "<name>.so" files (every plugin's own CMakeLists
 * sets `PREFIX ""` — e.g. plugins/linux-capture/CMakeLists.txt's
 * set_target_properties_obs(linux-capture PROPERTIES ... PREFIX ""), so
 * get_module_extension() in libobs/obs-nix.c returning ".so" combines with
 * that empty prefix to give exactly "<name>.so", no "lib" prefix — same
 * flat-templates shape as the Windows backend's ".dll" layout, not macOS's
 * ".plugin" bundle nesting. */
void rw_plat_setup_module_paths(const char *sdk_dir) {
    char plugins_bin[PATH_MAX];
    char plugins_data[PATH_MAX];
    snprintf(plugins_bin, sizeof(plugins_bin), "%s/obs-plugins/%%module%%.so", sdk_dir);
    snprintf(plugins_data, sizeof(plugins_data), "%s/data/obs-plugins/%%module%%", sdk_dir);
    obs_add_module_path(plugins_bin, plugins_data);
}

/* Resolves an absolute, existing path to libobs-opengl.so (there is no
 * libobs-d3d11 equivalent choice to make on Linux — OpenGL/EGL is the only
 * render device libobs-opengl builds for this platform; see
 * libobs-opengl/CMakeLists.txt at the pinned tag). Its build output name is
 * exactly "libobs-opengl.so" — set_target_properties_obs(libobs-opengl
 * PROPERTIES ... PREFIX "" ...) combined with the CMake target name
 * "libobs-opengl" itself (not "obs-opengl") already contains the "lib"
 * substring, so PREFIX "" does not strip it (unlike a target literally
 * named "opengl", which PREFIX "" would leave as "opengl.so" with no "lib").
 * A real build also produces a SOVERSION-suffixed file (e.g.
 * "libobs-opengl.so.32") with "libobs-opengl.so" as a symlink to it —
 * tools/fetch_libobs_linux.sh copies both together (rsync -a preserves the
 * symlink) so the bare name always resolves. Tries, in order (mirrors the
 * macOS/Windows backends' dev-tree-then-packaged shape):
 *   (a) "<sdk dir>/lib/libobs-opengl.so" — the dev-tree layout
 *       tools/fetch_libobs_linux.sh assembles.
 *   (b) "<shim dir>/libobs-opengl.so" — packaged layout, flat colocation
 *       (see rw_plat_sdk_dir_candidate's doc comment — aspirational, no
 *       bundler script exists yet). */
int rw_plat_find_graphics_module_path(const char *sdk_dir, const char *shim_dir, char *out, size_t out_size) {
    char a[PATH_MAX], b[PATH_MAX] = "";

    snprintf(a, sizeof(a), "%s/lib/libobs-opengl.so", sdk_dir);
    if (path_exists(a)) { snprintf(out, out_size, "%s", a); return 1; }

    if (shim_dir && shim_dir[0]) {
        snprintf(b, sizeof(b), "%s/libobs-opengl.so", shim_dir);
        if (path_exists(b)) { snprintf(out, out_size, "%s", b); return 1; }
    }

    char msg[768];
    int len = snprintf(msg, sizeof(msg), "could not locate libobs-opengl.so; tried \"%s\"", a);
    if (b[0] && len > 0 && (size_t)len < sizeof(msg))
        len += snprintf(msg + len, sizeof(msg) - (size_t)len, ", \"%s\"", b);
    if (len > 0 && (size_t)len < sizeof(msg))
        snprintf(msg + len, sizeof(msg) - (size_t)len, " (see native/shim/README.md)");
    set_error(msg);
    return 0;
}

/* No OS-level runtime permission prompt for screen capture on Linux
 * (X11 has none at all; Wayland's consent flow is the xdg-desktop-portal
 * dialog shown when the PipeWire capture source itself starts, not
 * something this shim can preflight or trigger early — see
 * rw_plat_init_capture_source's Wayland branch). */
int rw_plat_check_permission(void) {
    return 0;
}

/* No preflightable/requestable screen-capture permission on Linux (see
 * above) — always report/return granted. */
int rw_plat_preflight_screen_permission(void) {
    return 1;
}

int rw_plat_request_screen_permission(void) {
    return 1;
}

/* libobs' own core data (default.effect and friends) resolution
 * (find_libobs_data_file() in libobs/obs-nix.c) is hardcoded to paths
 * derived from the CMake-configure-time OBS_DATA_PATH / a relative
 * "../data/libobs" walk from the executable — neither of which matches
 * this shim's own SDK layout (tools/fetch_libobs_linux.sh's <sdk>/data/).
 * Same fix as Windows: register the real data dir explicitly via the
 * public obs_add_data_path() API before obs_reset_video() (the first thing
 * that loads these effects) — obs_find_data_file() falls back to every
 * path added this way. Also where nix-platform / X11-vs-Wayland session
 * detection happens (see detect_session()'s doc comment for why it must
 * run before obs_reset_video()). */
void rw_plat_pre_video_setup(const char *sdk_dir) {
    g_lnx_session = detect_session();
    obs_set_nix_platform(g_lnx_session == RW_SESSION_WAYLAND ? OBS_NIX_PLATFORM_WAYLAND : OBS_NIX_PLATFORM_X11_EGL);
    blog(LOG_INFO, "rewind: Linux session detected as %s", g_lnx_session == RW_SESSION_WAYLAND ? "Wayland" : "X11");
    /* Deliberately NOT calling obs_set_nix_platform_display(): gl-x11-egl.c's
     * open_windowless_display() (libobs-opengl/gl-x11-egl.c at the pinned
     * tag) already falls back to its own XOpenDisplay(NULL) when
     * obs_get_nix_platform_display() returns NULL, exactly what this shim
     * would otherwise do by hand — no need to duplicate it. */

    char data_path[PATH_MAX];
    snprintf(data_path, sizeof(data_path), "%s/data/libobs/", sdk_dir);
    obs_add_data_path(data_path);
}

/* ---- X11 connection + RandR monitor enumeration -------------------------
 *
 * Opened lazily, once, and reused for every enumeration/capture-source call
 * — matches xcomposite-input.c's own single-shared-Display pattern
 * (xcomposite_load() opens one Display for the whole plugin's lifetime).
 * On Wayland this is never called.
 */

static Display *g_x11_display = NULL;
static xcb_connection_t *g_x11_conn = NULL;

static xcb_connection_t *rw_x11_ensure_conn(void) {
    if (g_x11_conn && !xcb_connection_has_error(g_x11_conn)) return g_x11_conn;
    g_x11_conn = NULL;
    if (g_x11_display) { XCloseDisplay(g_x11_display); g_x11_display = NULL; }
    g_x11_display = XOpenDisplay(NULL);
    if (!g_x11_display) return NULL;
    xcb_connection_t *conn = XGetXCBConnection(g_x11_display);
    if (!conn || xcb_connection_has_error(conn)) {
        XCloseDisplay(g_x11_display);
        g_x11_display = NULL;
        return NULL;
    }
    g_x11_conn = conn;
    return g_x11_conn;
}

static xcb_atom_t rw_get_atom(xcb_connection_t *c, const char *name) {
    xcb_intern_atom_cookie_t ck = xcb_intern_atom(c, 1, (uint16_t)strlen(name), name);
    xcb_intern_atom_reply_t *r = xcb_intern_atom_reply(c, ck, NULL);
    xcb_atom_t a = r ? r->atom : XCB_ATOM_NONE;
    free(r);
    return a;
}

/* Matches xcomp_property_sync() in plugins/linux-capture/xcomposite-input.c
 * (type XCB_ATOM_ANY / 0, up to 4096*4 bytes) — that function is static to
 * the plugin (not part of libobs' public API), so this reproduces its
 * shape rather than calling it. */
static xcb_get_property_reply_t *rw_get_property(xcb_connection_t *c, xcb_window_t win, xcb_atom_t atom) {
    if (atom == XCB_ATOM_NONE) return NULL;
    xcb_get_property_cookie_t ck = xcb_get_property(c, 0, win, atom, 0, 0, 4096);
    xcb_generic_error_t *err = NULL;
    xcb_get_property_reply_t *r = xcb_get_property_reply(c, ck, &err);
    free(err);
    if (!r || xcb_get_property_value_length(r) == 0) { free(r); return NULL; }
    return r;
}

struct rw_monitor { int16_t x, y; uint16_t w, h; uint8_t primary; };

/* Reproduces randr_screen_geo()/randr_screen_count()'s "has monitors" path
 * (plugins/linux-capture/xhelpers.c at the pinned tag) — i.e. RandR >= 1.5's
 * xcb_randr_get_monitors, which every X server in real-world use since
 * ~2015 (Xorg 1.16+/xrandr 1.5) supports. Deliberately does NOT reproduce
 * xhelpers.c's further fallbacks (legacy per-CRTC RandR for <1.5, or
 * Xinerama) — those paths are effectively dead on any current desktop and
 * xshm_input_v2 itself only takes them when a server that old is in use, a
 * scope trim documented here rather than silently guessed. If RandR
 * monitors aren't available, callers fall back to xcb_setup_roots_iterator
 * (plain per-X11-screen geometry, matching xhelpers.c's OWN final fallback
 * x11_screen_geo() rather than the two paths skipped above). Returns the
 * monitor count (0 if RandR monitors are unavailable). */
static int rw_x11_randr_has_monitors(xcb_connection_t *c) {
    if (!xcb_get_extension_data(c, &xcb_randr_id)->present) return 0;
    xcb_randr_query_version_cookie_t vc = xcb_randr_query_version(c, XCB_RANDR_MAJOR_VERSION, XCB_RANDR_MINOR_VERSION);
    xcb_randr_query_version_reply_t *vr = xcb_randr_query_version_reply(c, vc, NULL);
    if (!vr) return 0;
    /* Reproduces xhelpers.c's randr_has_monitors() condition verbatim,
     * including its own looseness (checks minor_version >= 5 regardless of
     * major_version, not "major>1 OR (major==1 AND minor>=5)") — matching
     * upstream's actual behavior exactly rather than a "corrected" version
     * that could disagree with what the real xshm_input_v2 source decides. */
    int ok = vr->major_version > 1 || vr->minor_version >= 5;
    free(vr);
    return ok;
}

static int rw_x11_list_monitors(xcb_connection_t *c, xcb_screen_t *screen, struct rw_monitor *out, int cap) {
    if (!rw_x11_randr_has_monitors(c)) return 0;
    xcb_randr_get_monitors_cookie_t mc = xcb_randr_get_monitors(c, screen->root, 1);
    xcb_randr_get_monitors_reply_t *mr = xcb_randr_get_monitors_reply(c, mc, NULL);
    if (!mr) return 0;
    int count = 0;
    xcb_randr_monitor_info_iterator_t it = xcb_randr_get_monitors_monitors_iterator(mr);
    for (; it.rem && count < cap; xcb_randr_monitor_info_next(&it)) {
        xcb_randr_monitor_info_t *m = it.data;
        out[count].x = m->x;
        out[count].y = m->y;
        out[count].w = m->width;
        out[count].h = m->height;
        out[count].primary = m->primary;
        count++;
    }
    free(mr);
    return count;
}

/* Index of the primary RandR monitor, or 0 (the server's/list's first
 * entry) if none is flagged primary or RandR monitors aren't available —
 * same "index 0 as a reasonable default" fallback the macOS/Windows
 * backends use for their own main-display resolution. */
static int rw_x11_primary_monitor_index(void) {
    xcb_connection_t *c = rw_x11_ensure_conn();
    if (!c) return 0;
    xcb_screen_t *screen = xcb_setup_roots_iterator(xcb_get_setup(c)).data;
    if (!screen) return 0;
    struct rw_monitor mons[32];
    int n = rw_x11_list_monitors(c, screen, mons, 32);
    for (int i = 0; i < n; i++) {
        if (mons[i].primary) return i;
    }
    return 0;
}

/* ---- display size/uuid + enumeration ------------------------------------
 *
 * "uuid" here is NOT a stable hardware identifier the way macOS's
 * CFUUID-backed display_uuid or Windows' EDID-derived monitor_id are — X11
 * RandR monitors have no persistent id in the protocol itself, only a
 * per-connection index. This shim uses that RandR monitor INDEX, formatted
 * as a decimal string, as the opaque "uuid" — valid because
 * rewind_obs.h's own contract only promises it round-trips unchanged
 * through rewind_set_capture_display, never that it's stable across
 * monitor hotplug/reconnect (same caveat already true in spirit for
 * Windows' own device-id string, which can also change if a monitor is
 * unplugged and replugged into a different port). xshm_input_v2's own
 * "screen" setting (plugins/linux-capture/xshm-input.c) is exactly this
 * same RandR-monitor-index int, so the string parses straight back with
 * atoi() with no translation layer needed.
 */

void rw_plat_query_main_display_size(uint32_t *width, uint32_t *height) {
    *width = 1920;
    *height = 1080;
    if (g_lnx_session == RW_SESSION_WAYLAND) {
        /* No synchronous "query the compositor's output size" available
         * without a Wayland client connection of our own (out of scope —
         * see native/shim/README.md); the portal-backed capture source
         * reports its own width/height once a stream is actually selected
         * and connected (screencast_portal_capture_get_width/height in
         * plugins/linux-pipewire/screencast-portal.c), so this default only
         * affects the initial OBS canvas, not the eventual capture
         * resolution. */
        return;
    }
    xcb_connection_t *c = rw_x11_ensure_conn();
    if (!c) return;
    xcb_screen_t *screen = xcb_setup_roots_iterator(xcb_get_setup(c)).data;
    if (!screen) return;
    struct rw_monitor mons[32];
    int n = rw_x11_list_monitors(c, screen, mons, 32);
    if (n > 0) {
        int idx = 0;
        for (int i = 0; i < n; i++) {
            if (mons[i].primary) { idx = i; break; }
        }
        *width = mons[idx].w;
        *height = mons[idx].h;
        return;
    }
    *width = screen->width_in_pixels;
    *height = screen->height_in_pixels;
}

void rw_plat_main_display_uuid(char *out, size_t out_size) {
    out[0] = '\0';
    if (g_lnx_session == RW_SESSION_WAYLAND) return;
    snprintf(out, out_size, "%d", rw_x11_primary_monitor_index());
}

int rw_plat_list_displays_json(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) return fail("invalid buffer");
    json_out[0] = '\0';

    if (g_lnx_session == RW_SESSION_WAYLAND) {
        /* No synchronous display enumeration is available on Wayland — the
         * xdg-desktop-portal's own picker dialog is the only way to choose
         * a monitor/window, shown interactively when capture starts (see
         * rw_plat_init_capture_source). An empty list (not an error) tells
         * callers there is nothing to preselect from. */
        snprintf(json_out, (size_t)json_cap, "[]");
        set_error("");
        return 0;
    }

    xcb_connection_t *c = rw_x11_ensure_conn();
    if (!c) return fail("could not connect to the X server (is DISPLAY set?)");
    xcb_screen_t *screen = xcb_setup_roots_iterator(xcb_get_setup(c)).data;
    if (!screen) return fail("no X11 screen available");

    struct rw_monitor mons[32];
    int n = rw_x11_list_monitors(c, screen, mons, 32);

    size_t pos = 0;
#define APPEND(...) do { \
        int _n = snprintf(json_out + pos, (size_t)json_cap - pos, __VA_ARGS__); \
        if (_n < 0 || (size_t)_n >= (size_t)json_cap - pos) return fail("display list truncated"); \
        pos += (size_t)_n; \
    } while (0)

    APPEND("[");
    if (n > 0) {
        for (int i = 0; i < n; i++) {
            APPEND("%s{\"uuid\":\"%d\",\"width\":%u,\"height\":%u,\"main\":%s}",
                   i == 0 ? "" : ",", i, (unsigned)mons[i].w, (unsigned)mons[i].h,
                   mons[i].primary ? "true" : "false");
        }
    } else {
        /* RandR monitors unavailable — fall back to the bare X11 screen
         * (matches xhelpers.c's own x11_screen_geo() final fallback). */
        APPEND("{\"uuid\":\"0\",\"width\":%u,\"height\":%u,\"main\":true}",
               (unsigned)screen->width_in_pixels, (unsigned)screen->height_in_pixels);
    }
    APPEND("]");
#undef APPEND
    set_error("");
    return 0;
}

/* ---- application/window enumeration (X11) -------------------------------
 *
 * Pure XCB/EWMH: _NET_CLIENT_LIST on the root window gives every top-level
 * window in creation order; _NET_WM_PID (a window manager-populated hint,
 * near-universal on modern EWMH-compliant desktops) resolves the owning
 * process, then /proc/<pid>/comm resolves a display-friendly process name
 * (Linux-native, no libproc/proc_pidpath equivalent needed). Deduplicated
 * by process name, one row per running app — same dedup granularity as the
 * Windows backend's per-exe dedup (see enum_windows_list_cb in
 * rewind_obs_windows.c), and for the same reason: a real game usually owns
 * exactly one capturable top-level window, but some apps (browsers,
 * launchers) can own several.
 *
 * The identity token emitted as "bundle_id" (and reused for
 * rewind_set_capture_app) is the window's XID as a plain decimal string —
 * NOT the "<xid>\r\n<name>\r\n<class>" form xcomposite_input's own
 * "capture_window" property UI writes (see xcompcap_props() in
 * xcomposite-input.c). Verified against convert_encoded_window_id() in the
 * same file: a string with no "\r\n" divider is treated as JUST the
 * decimal xid (`return (xcb_window_t)atol(str)`), and xcomp_find_window()
 * tries an exact id match against the current top-level window list FIRST,
 * only falling through to name/class matching when that id no longer
 * exists — so a plain decimal xid is a fully valid, simpler "capture_window"
 * value on its own, and this shim never needs the name/class fallback path
 * (an already-closed window's xid just fails to match anything, which
 * mirrors the "ephemeral window id" contract rewind_set_capture_window
 * already documents).
 */

int rw_plat_list_capturable_apps_json(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) return fail("invalid buffer");
    json_out[0] = '\0';

    if (g_lnx_session == RW_SESSION_WAYLAND) {
        /* Same rationale as rw_plat_list_displays_json's Wayland branch:
         * no synchronous window enumeration exists under Wayland's
         * portal-mediated capture model. */
        snprintf(json_out, (size_t)json_cap, "[]");
        set_error("");
        return 0;
    }

    xcb_connection_t *c = rw_x11_ensure_conn();
    if (!c) return fail("could not connect to the X server (is DISPLAY set?)");
    xcb_screen_t *screen = xcb_setup_roots_iterator(xcb_get_setup(c)).data;
    if (!screen) return fail("no X11 screen available");

    xcb_atom_t atom_client_list = rw_get_atom(c, "_NET_CLIENT_LIST");
    if (atom_client_list == XCB_ATOM_NONE)
        return fail("window manager does not support _NET_CLIENT_LIST (EWMH)");
    xcb_atom_t atom_wm_pid = rw_get_atom(c, "_NET_WM_PID");
    xcb_atom_t atom_net_wm_name = rw_get_atom(c, "_NET_WM_NAME");
    xcb_atom_t atom_utf8 = rw_get_atom(c, "UTF8_STRING");

    xcb_get_property_reply_t *list = rw_get_property(c, screen->root, atom_client_list);
    if (!list) {
        snprintf(json_out, (size_t)json_cap, "[]");
        set_error("");
        return 0;
    }

    xcb_window_t *wins = (xcb_window_t *)xcb_get_property_value(list);
    int count = xcb_get_property_value_length(list) / (int)sizeof(xcb_window_t);
    pid_t self_pid = getpid();

    /* 256 apps comfortably covers any real desktop's window set — same
     * soft-limit dedup table size the macOS/Windows backends use. */
    char seen[256][64];
    int seen_count = 0;

    size_t pos = 0;
#define APPEND_OR_FAIL(...) do { \
        int _n = snprintf(json_out + pos, (size_t)json_cap - pos, __VA_ARGS__); \
        if (_n < 0 || (size_t)_n >= (size_t)json_cap - pos) { free(list); return fail("app list truncated"); } \
        pos += (size_t)_n; \
    } while (0)

    APPEND_OR_FAIL("[");
    int first = 1;
    for (int i = 0; i < count; i++) {
        xcb_window_t win = wins[i];

        /* Only reasonably-sized, currently-mapped windows — mirrors the
         * macOS backend's >=64px filter (menu-bar-extra-sized noise isn't a
         * capturable app window). A geometry request failing outright
         * (window destroyed between the client-list snapshot and now) skips
         * the entry rather than erroring the whole enumeration. */
        xcb_get_geometry_cookie_t gc = xcb_get_geometry(c, win);
        xcb_generic_error_t *gerr = NULL;
        xcb_get_geometry_reply_t *geo = xcb_get_geometry_reply(c, gc, &gerr);
        free(gerr);
        if (!geo) continue;
        int w = geo->width, h = geo->height;
        free(geo);
        if (w < 64 || h < 64) continue;

        pid_t pid = 0;
        xcb_get_property_reply_t *pidr = rw_get_property(c, win, atom_wm_pid);
        if (pidr && xcb_get_property_value_length(pidr) >= (int)sizeof(uint32_t))
            pid = (pid_t)(*(uint32_t *)xcb_get_property_value(pidr));
        free(pidr);
        if (pid <= 0 || pid == self_pid) continue;

        char procname[64] = "";
        char commpath[64];
        snprintf(commpath, sizeof(commpath), "/proc/%d/comm", (int)pid);
        FILE *f = fopen(commpath, "r");
        if (f) {
            if (fgets(procname, sizeof(procname), f)) {
                size_t l = strlen(procname);
                if (l && procname[l - 1] == '\n') procname[l - 1] = '\0';
            }
            fclose(f);
        }
        if (!procname[0]) continue; /* process gone / unreadable */

        int dup = 0;
        for (int s = 0; s < seen_count; s++) {
            if (strcmp(seen[s], procname) == 0) { dup = 1; break; }
        }
        if (dup) continue;
        if (seen_count < 256) snprintf(seen[seen_count++], sizeof(seen[0]), "%s", procname);

        /* Title: _NET_WM_NAME (UTF8_STRING) first, falling back to the
         * legacy core WM_NAME property (treated as raw bytes — a
         * simplification vs. xcomp_window_name()'s full ICCCM
         * STRING/COMPOUND_TEXT charset handling in xcomposite-input.c,
         * acceptable here since this is cosmetic display text only, never
         * used to re-match a window — see the doc comment above), then the
         * process name. */
        char title[512] = "";
        xcb_get_property_reply_t *namer = rw_get_property(c, win, atom_net_wm_name);
        if (namer && namer->type == atom_utf8) {
            int len = xcb_get_property_value_length(namer);
            if (len > 0 && len < (int)sizeof(title)) {
                memcpy(title, xcb_get_property_value(namer), (size_t)len);
                title[len] = '\0';
            }
        }
        free(namer);
        if (!title[0]) {
            xcb_get_property_reply_t *wmn = rw_get_property(c, win, XCB_ATOM_WM_NAME);
            if (wmn) {
                int len = xcb_get_property_value_length(wmn);
                if (len > 0 && len < (int)sizeof(title)) {
                    memcpy(title, xcb_get_property_value(wmn), (size_t)len);
                    title[len] = '\0';
                }
            }
            free(wmn);
        }
        if (!title[0]) snprintf(title, sizeof(title), "%s", procname);

        char token[32];
        snprintf(token, sizeof(token), "%u", (unsigned)win);

        char escaped_id[64] = "", escaped_name[1024] = "";
        json_escape_append(token, escaped_id, sizeof(escaped_id));
        json_escape_append(title, escaped_name, sizeof(escaped_name));

        APPEND_OR_FAIL("%s{\"bundle_id\":\"%s\",\"name\":\"%s\",\"pid\":%d,\"icon\":\"\",\"window_id\":%u}",
                       first ? "" : ",", escaped_id, escaped_name, (int)pid, (unsigned)win);
        first = 0;
    }
    APPEND_OR_FAIL("]");
#undef APPEND_OR_FAIL

    free(list);
    set_error("");
    return 0;
}

/* ---- audio ---------------------------------------------------------------
 *
 * pulse_output_capture (desktop) / pulse_input_capture (mic), both from
 * linux-pulseaudio (plugins/linux-pulseaudio/pulse-input.c at the pinned
 * tag), keyed on a "device_id" string setting ("default" = the system
 * default sink/source's monitor, per pulse_defaults()). Confirmed there is
 * NO per-application PulseAudio source anywhere in this SDK's plugin set —
 * grepped plugins/linux-pulseaudio/*.c for every obs_source_info this
 * module registers (linux-pulseaudio.c's obs_module_load(): exactly
 * pulse_input_capture + pulse_output_capture, nothing else) and neither
 * exposes per-owning-process filtering the way macOS's sck_audio_capture
 * "application" setting or Windows' wasapi_process_output_capture "window"
 * setting do. AUDIO_MODE_APP therefore has no way to be satisfied on Linux
 * with this SDK: rather than silently drop it into what looks like AUDIO_MODE_OFF
 * (surprising — the user asked for audio and got none) or silently
 * upgrading it to full desktop audio without saying so (the exact "leak
 * audio silently" macOS/Windows explicitly avoid via a logged warning in
 * their own no-target fallback), this falls back to full desktop audio
 * WITH a logged warning explaining why — the same "fail loud, not silent"
 * spirit as the other two backends, just resolving to a different concrete
 * behavior because the platform capability itself doesn't exist here. See
 * native/shim/README.md's Linux section for the same note.
 */
void rw_plat_rebuild_system_audio(void) {
    if (g_sysaudio) {
        obs_set_output_source(1, NULL);
        obs_source_release(g_sysaudio);
        g_sysaudio = NULL;
    }
    if (g_audio_mode == AUDIO_MODE_OFF) return;

    if (g_audio_mode == AUDIO_MODE_APP) {
        blog(LOG_WARNING, "rewind: per-application audio capture is not available on Linux "
                          "(linux-pulseaudio has no per-app source in this SDK); "
                          "falling back to full desktop audio");
    }

    obs_data_t *s = obs_data_create();
    obs_data_set_string(s, "device_id", "default");
    g_sysaudio = obs_source_create("pulse_output_capture", "rewind-sysaudio", s, NULL);
    obs_data_release(s);
    if (g_sysaudio) {
        obs_set_output_source(1, g_sysaudio);
    } else {
        blog(LOG_WARNING, "rewind: pulse_output_capture unavailable; no system audio");
    }
}

/* "device_id" is pulse_input_capture's own settings key, same shape as
 * pulse_output_capture's use of it in rw_plat_rebuild_system_audio above:
 * "default" selects the system default source; anything else is looked up
 * by PulseAudio source name. g_mic_device_uid empty means "use the
 * default". */
obs_source_t *rw_plat_create_mic_source(void) {
    obs_data_t *ms = obs_data_create();
    obs_data_set_string(ms, "device_id",
                         g_mic_device_uid[0] ? g_mic_device_uid : "default");
    obs_source_t *mic = obs_source_create("pulse_input_capture", "rewind-mic", ms, NULL);
    obs_data_release(ms);
    return mic;
}

void rw_plat_log_mic_unavailable(void) {
    blog(LOG_WARNING, "rewind: pulse_input_capture unavailable");
}

/* TODO(linux): enumerate PulseAudio source devices (pa_context_get_source_
 * info_list, filtering to actual input sources rather than monitor-of-
 * output sources) the way pulse_input_capture's own obs_properties callback
 * does, mapping each source's name to "uid" and its description to "name".
 * Not hardware-validated in this task (no real PulseAudio server in the
 * loop) — an honest empty list until then; the Dart picker hides itself
 * when this returns "[]" rather than showing a fake device. */
int rw_plat_list_audio_inputs_json(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) return fail("invalid buffer");
    static const char *empty = "[]";
    size_t needed = strlen(empty) + 1;
    if (needed > (size_t)json_cap) return fail("audio input list truncated");
    memcpy(json_out, empty, needed);
    set_error("");
    return 0;
}

/* Same rationale as the macOS/Windows backends: obs-ffmpeg's replay-buffer
 * and recording outputs spawn the standalone obs-ffmpeg-mux helper,
 * resolved next to the main executable — /proc/self/exe is the Linux-native
 * equivalent of macOS's _NSGetExecutablePath / Windows'
 * GetModuleFileNameA(NULL, ...). */
int rw_plat_mux_helper_present(void) {
    char path[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", path, sizeof(path) - 1);
    if (n <= 0) return -1;
    path[n] = '\0';
    char *slash = strrchr(path, '/');
    if (!slash) return -1;
    snprintf(slash + 1, sizeof(path) - (size_t)(slash + 1 - path), "obs-ffmpeg-mux");
    return path_exists(path);
}

/* ---- video capture source (X11) -----------------------------------------
 *
 * Two distinct source ids, same structural split as Windows'
 * monitor_capture/window_capture (see rebuild_video_capture() in
 * rewind_obs_windows.c for the reference shape this mirrors): "xshm_input_v2"
 * for a display, "xcomposite_input" for a specific window. Unlike macOS
 * (whose single "screen_capture" source switches target via its own
 * "type" setting) or Windows (two source ids, but each independently
 * capable of "which display"/"which window"), Linux X11 has no concept of
 * "capture this application" distinct from "capture this window" — so
 * rewind_set_capture_app()'s g_app_bundle_id is treated here exactly like
 * rewind_set_capture_window()'s g_window_id: both are just an opaque
 * decimal-xid "capture_window" token, window beats app beats display,
 * mirroring the precedence order used everywhere else in this codebase
 * (see rewind_obs.h's rewind_set_capture_app doc comment).
 */

enum lnx_capture_kind { LNX_CAPTURE_NONE, LNX_CAPTURE_DISPLAY, LNX_CAPTURE_WINDOW };
static enum lnx_capture_kind g_lnx_capture_kind = LNX_CAPTURE_NONE;

static void rebuild_video_capture_x11(void) {
    char window_token[32] = "";
    if (g_window_id != 0) snprintf(window_token, sizeof(window_token), "%u", g_window_id);
    /* g_app_bundle_id is itself already a decimal-xid token (see
     * rw_plat_list_capturable_apps_json's doc comment) — round-tripped
     * unchanged, same "opaque string" treatment the Windows backend gives
     * its own "title:class:exe" token. */
    const char *effective_window = window_token[0] ? window_token : g_app_bundle_id;
    int want_window = effective_window && effective_window[0];
    enum lnx_capture_kind want_kind = want_window ? LNX_CAPTURE_WINDOW : LNX_CAPTURE_DISPLAY;

    if (!g_capture || g_lnx_capture_kind != want_kind) {
        if (g_capture) {
            rw_attach_capture(NULL);
            obs_source_release(g_capture);
            g_capture = NULL;
        }
        obs_data_t *cs = obs_data_create();
        if (want_kind == LNX_CAPTURE_WINDOW) {
            obs_data_set_string(cs, "capture_window", effective_window);
            obs_data_set_bool(cs, "show_cursor", true);
            g_capture = obs_source_create("xcomposite_input", "rewind-display", cs, NULL);
        } else {
            int screen = g_display_uuid[0] ? atoi(g_display_uuid) : rw_x11_primary_monitor_index();
            obs_data_set_int(cs, "screen", screen);
            obs_data_set_bool(cs, "show_cursor", true);
            g_capture = obs_source_create("xshm_input_v2", "rewind-display", cs, NULL);
        }
        obs_data_release(cs);
        if (g_capture) {
            rw_attach_capture(g_capture);
            g_lnx_capture_kind = want_kind;
        } else {
            g_lnx_capture_kind = LNX_CAPTURE_NONE;
            blog(LOG_WARNING, "rewind: %s capture source failed to create",
                 want_kind == LNX_CAPTURE_WINDOW ? "xcomposite_input" : "xshm_input_v2");
        }
        return;
    }

    /* Same category as before — update the existing source in place. */
    obs_data_t *cs = obs_data_create();
    if (want_kind == LNX_CAPTURE_WINDOW) {
        obs_data_set_string(cs, "capture_window", effective_window);
    } else {
        int screen = g_display_uuid[0] ? atoi(g_display_uuid) : rw_x11_primary_monitor_index();
        obs_data_set_int(cs, "screen", screen);
    }
    obs_source_update(g_capture, cs);
    obs_data_release(cs);
}

/* Wayland: a single unified portal-backed source (both monitor and window
 * picking are done through the SAME xdg-desktop-portal dialog, shown to
 * the user interactively when the source starts — see
 * screencast_portal_load()'s "pipewire-screen-capture-source" registration
 * in plugins/linux-pipewire/screencast-portal.c, OBS_PORTAL_CAPTURE_TYPE_UNIFIED).
 * There is no settings key to preselect a target the way display_uuid/
 * capture_window do on X11 — the portal itself is the picker. "ShowCursor"
 * (bool) is the only setting this shim configures; "RestoreToken" is left
 * unset, so the portal's remembered-selection feature (screencast protocol
 * version 4+) never activates and every capture start reprompts the user —
 * activating it would need this shim to persist the token the source's own
 * `.save` callback writes back into its settings across process restarts,
 * which this shim doesn't do for ANY source (no on-disk settings
 * persistence layer exists here) — documented as a known limitation rather
 * than implemented partially. */
static int init_capture_source_wayland(void) {
    obs_data_t *cs = obs_data_create();
    obs_data_set_bool(cs, "ShowCursor", true);
    g_capture = obs_source_create("pipewire-screen-capture-source", "rewind-display", cs, NULL);
    obs_data_release(cs);
    if (!g_capture) {
        return fail("pipewire-screen-capture-source unavailable "
                    "(requires xdg-desktop-portal + a PipeWire screencast backend)");
    }
    rw_attach_capture(g_capture);
    return 0;
}

int rw_plat_init_capture_source(void) {
    if (g_lnx_session == RW_SESSION_WAYLAND) return init_capture_source_wayland();

    if (!rw_x11_ensure_conn()) return fail("could not connect to the X server (is DISPLAY set?)");
    rebuild_video_capture_x11();
    if (!g_capture) return fail("capture source failed to create (see log)");
    return 0;
}

/* On Wayland there is nothing to reconfigure programmatically (see
 * init_capture_source_wayland's doc comment) — these are safe, logged
 * no-ops rather than silently doing nothing unexplained. */
void rw_plat_on_capture_display_changed(void) {
    if (!g_initialized) return;
    if (g_lnx_session == RW_SESSION_WAYLAND) {
        blog(LOG_WARNING, "rewind: capture display selection is not supported on Wayland "
                          "(portal-driven); ignoring");
        return;
    }
    rebuild_video_capture_x11();
}

void rw_plat_on_capture_app_changed(void) {
    if (!g_initialized) return;
    if (g_lnx_session == RW_SESSION_WAYLAND) {
        blog(LOG_WARNING, "rewind: capture app selection is not supported on Wayland "
                          "(portal-driven); ignoring");
        return;
    }
    rebuild_video_capture_x11();
}

void rw_plat_on_capture_window_changed(void) {
    if (!g_initialized) return;
    if (g_lnx_session == RW_SESSION_WAYLAND) {
        blog(LOG_WARNING, "rewind: capture window selection is not supported on Wayland "
                          "(portal-driven); ignoring");
        return;
    }
    rebuild_video_capture_x11();
}

void rw_plat_reset_capture_state(void) {
    g_lnx_capture_kind = LNX_CAPTURE_NONE;
}

/* ---- encoders --------------------------------------------------------
 *
 * Hardware-first ladder, same spirit as the Windows backend's NVENC/AMF/
 * QSV/x264 chain (create_video_encoder() in rewind_obs_windows.c) — try
 * each id via obs_video_encoder_create() and use whichever succeeds first,
 * relying on each encoder's own internal availability probing rather than
 * this shim re-implementing GPU/driver detection:
 *   1. "obs_nvenc_h264_tex" (plugins/obs-nvenc/nvenc.c) — NVIDIA. Cross-platform
 *      id, texture-based; on Linux the texture interop is OpenGL
 *      (nvenc-opengl.c, selected by `$<$<PLATFORM_ID:Linux>:nvenc-opengl.c>`
 *      in plugins/obs-nvenc/CMakeLists.txt), which lines up with this shim
 *      always requesting an OpenGL graphics_module (Linux has no D3D11 to
 *      choose between the way Windows does) — no extra device-type gate
 *      needed the way the Windows backend documents for its own D3D11
 *      requirement.
 *   2. "ffmpeg_vaapi_tex" (plugins/obs-ffmpeg/obs-ffmpeg-vaapi.c) — Intel/AMD
 *      via VA-API, texture-passing (OBS_ENCODER_CAP_PASS_TEXTURE).
 *   3. "ffmpeg_vaapi" — same plugin, the non-texture/CPU-copy variant
 *      (OBS_ENCODER_CAP_INTERNAL) — broader compatibility fallback if the
 *      texture-interop path fails to attach (e.g. DRM/EGL interop not
 *      available in a given environment) but VA-API itself works.
 *   4. "obs_x264" (plugins/obs-x264/obs-x264.c) — software, always available,
 *      the universal fallback (same id as Windows/macOS's x264 fallback).
 * None of these have a Linux equivalent of macOS's separate
 * mac-videotoolbox-module gap or Windows' AMF/QSV rungs — this SDK doesn't
 * fetch obs-qsv11 or a Linux AMD-specific plugin (AMD hardware encoding on
 * Linux goes through the same VA-API path as Intel, not a separate
 * plugin), so the ladder is shorter by construction, not by omission.
 * "bitrate" (int, kbps) is the one setting explicitly set here — the same
 * long-standing convention across every OBS video encoder the other two
 * backends already rely on; "vaapi_device" is deliberately left unset so
 * each VAAPI encoder's own get_defaults() (vaapi_default_device() in
 * obs-ffmpeg-vaapi.c) auto-picks a suitable /dev/dri/renderD1xx node rather
 * than this shim re-implementing that device-probing logic.
 */
static obs_encoder_t *create_video_encoder(void) {
    static const char *candidates[] = {
        "obs_nvenc_h264_tex",
        "ffmpeg_vaapi_tex",
        "ffmpeg_vaapi",
        "obs_x264",
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        obs_data_t *ve = obs_data_create();
        obs_data_set_int(ve, "bitrate", 12000);
        obs_encoder_t *enc = obs_video_encoder_create(candidates[i], "rewind-venc", ve, NULL);
        obs_data_release(ve);
        if (enc) {
            blog(LOG_INFO, "rewind: using video encoder \"%s\"", candidates[i]);
            return enc;
        }
    }
    return NULL;
}

/* Audio: ffmpeg_aac (libavcodec's built-in AAC encoder, part of obs-ffmpeg —
 * already bundled for the muxer), same choice and same reasoning as the
 * Windows backend (no CoreAudio_AAC equivalent to license/redistribute on
 * this platform either). */
int rw_plat_create_encoders(void) {
    g_venc = create_video_encoder();
    if (!g_venc) {
        return fail("no usable H.264 encoder found (tried NVENC, VAAPI, x264)");
    }
    obs_encoder_set_video(g_venc, obs_get_video());

    g_aenc = obs_audio_encoder_create("ffmpeg_aac", "rewind-aenc", NULL, 0, NULL);
    if (!g_aenc) { return fail("ffmpeg_aac encoder unavailable"); }
    obs_encoder_set_audio(g_aenc, obs_get_audio());
    return 0;
}

#endif /* defined(REWIND_USE_LIBOBS) && defined(__linux__) */
