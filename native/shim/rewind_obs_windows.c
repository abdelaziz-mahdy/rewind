/*
 * rewind_obs_windows.c — Windows libobs backend for Rewind's C shim.
 *
 * Implements every `rw_plat_*` function declared in rewind_obs_internal.h
 * for Windows: monitor_capture/window_capture display+window/app capture,
 * WASAPI audio, NVENC/AMF/QSV/x264 encoder fallback ladder, and the
 * shim-directory-relative SDK/module path discovery. Compiled only when
 * REWIND_USE_LIBOBS is defined and on _WIN32 (see hook/build.dart); the
 * whole body is guarded so an accidental compile on any other
 * configuration is a harmless empty translation unit.
 *
 * Moved out of the single rewind_obs.c (see that file and
 * rewind_obs_internal.h for the shared layer / backend-seam design) as a
 * behavior-preserving refactor — every function here is the same logic,
 * same libobs calls, same order, same error strings as before the split,
 * with one deliberate exception: build_window_token()'s intermediate/
 * output buffers have been enlarged to fix review finding #6 (see the
 * comment at RW_WIN_ET_CAP below) while relocating the code.
 *
 * See native/shim/README.md's Windows section for exactly what's verified
 * against the pinned libobs 32.1.2 source vs. still an assumption (this
 * backend is implemented and CI-compiled but not yet run on real Windows
 * hardware).
 *
 * License: GPLv3.
 */
#if defined(REWIND_USE_LIBOBS) && defined(_WIN32)

#include "rewind_obs.h"
#include "rewind_obs_internal.h"

/* No POSIX headers here (no dlfcn.h/unistd.h/mach-o) — Win32 equivalents
 * are used throughout: GetModuleHandleEx+GetModuleFileName instead of
 * dladdr, GetFileAttributes instead of access(), _fullpath instead of
 * realpath(), EnumWindows/EnumDisplayMonitors instead of CoreGraphics. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h> /* DwmGetWindowAttribute(DWMWA_CLOAKED) */
#include <string.h>
#include <stdio.h>

/* ---- display + window helpers (Windows) -------------------------------
 *
 * Verified against the pinned obs-studio 32.1.2 win-capture/win-wasapi
 * plugin source (see native/shim/README.md's Windows section for exact
 * file/line references) rather than assumed from memory:
 *   - The modern "monitor_capture" source (registered as struct
 *     `duplicator_capture_info` in plugins/win-capture/duplicator-monitor-capture.c
 *     — used on Windows 8+ with a D3D11 render device, which is what this
 *     shim always requests via graphics_module below) keys its target
 *     display on a STRING setting "monitor_id", resolved by walking
 *     EnumDisplayMonitors() and matching GetMonitorInfo(...)->szDevice
 *     through EnumDisplayDevicesA(..., EDD_GET_DEVICE_INTERFACE_NAME) to a
 *     stable device interface path, falling back to the raw szDevice
 *     (e.g. "\\.\DISPLAY1") if that call fails. get_monitor_device_id()
 *     below reproduces that exact derivation so the strings this shim
 *     hands back from rewind_list_displays() match what "monitor_id" can
 *     consume unchanged.
 *   - "window_capture" and "wasapi_process_output_capture" both key their
 *     target window on a STRING setting "window" encoded as
 *     "<title>:<class>:<exe>" with '#' -> "#22" and ':' -> "#3A" escaped
 *     (in that order) in each component — verified against
 *     libobs/util/windows/window-helpers.c's encode_dstr()/add_window().
 *     build_window_token() below reproduces that exact encoding.
 *   - The legacy GDI "monitor_capture" (plugins/win-capture/monitor-capture.c,
 *     used pre-Windows-8 or without a D3D11 device) instead takes an int
 *     "monitor" index — NOT targeted here; this shim always forces a D3D11
 *     graphics_module (needed anyway for NVENC/AMF hardware texture
 *     encoding), so win-capture's obs_module_load() always registers the
 *     duplicator/"monitor_id" variant under the same "monitor_capture" id.
 */

/* Resolves a stable device-id string for `handle`, matching exactly what
 * duplicator-monitor-capture.c's own enum_monitor()/enum_monitor_props()
 * compute (EnumDisplayDevicesA's DeviceID, falling back to the raw
 * MONITORINFOEX::szDevice string e.g. "\\.\DISPLAY1" if that call fails —
 * happens for some virtual/RDP display adapters). */
static void get_monitor_device_id(HMONITOR handle, char *out, size_t out_size) {
    out[0] = '\0';
    MONITORINFOEXA mi;
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoA(handle, (LPMONITORINFO)&mi)) return;

    DISPLAY_DEVICEA device;
    device.cb = sizeof(device);
    if (EnumDisplayDevicesA(mi.szDevice, 0, &device, EDD_GET_DEVICE_INTERFACE_NAME) && device.DeviceID[0]) {
        snprintf(out, out_size, "%s", device.DeviceID);
    } else {
        snprintf(out, out_size, "%s", mi.szDevice);
    }
}

struct win_monitor_query {
    char device_id[128]; /* out: device id of the primary monitor */
};

static BOOL CALLBACK find_primary_monitor_cb(HMONITOR handle, HDC hdc, LPRECT rect, LPARAM param) {
    (void)hdc;
    struct win_monitor_query *q = (struct win_monitor_query *)param;
    MONITORINFO mi;
    mi.cbSize = sizeof(mi);
    if (GetMonitorInfo(handle, &mi) && (mi.dwFlags & MONITORINFOF_PRIMARY)) {
        get_monitor_device_id(handle, q->device_id, sizeof(q->device_id));
        *rect = mi.rcMonitor; /* unused by caller, silences LPRECT warnings */
        return FALSE; /* found it, stop enumerating */
    }
    return TRUE;
}

void rw_plat_query_main_display_size(uint32_t *width, uint32_t *height) {
    RECT r = {0, 0, 1920, 1080};
    HMONITOR primary = MonitorFromPoint((POINT){0, 0}, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO mi;
    mi.cbSize = sizeof(mi);
    if (primary && GetMonitorInfo(primary, &mi)) {
        r = mi.rcMonitor;
    } else {
        r.right = GetSystemMetrics(SM_CXSCREEN);
        r.bottom = GetSystemMetrics(SM_CYSCREEN);
    }
    long w = r.right - r.left, h = r.bottom - r.top;
    *width = w > 0 ? (uint32_t)w : 1920;
    *height = h > 0 ? (uint32_t)h : 1080;
}

/* Windows analogue of macOS's main_display_uuid(): the primary monitor's
 * "monitor_id" device-id string (see get_monitor_device_id above). */
void rw_plat_main_display_uuid(char *out, size_t out_size) {
    out[0] = '\0';
    struct win_monitor_query q = {{0}};
    EnumDisplayMonitors(NULL, NULL, find_primary_monitor_cb, (LPARAM)&q);
    snprintf(out, out_size, "%s", q.device_id);
}

struct win_monitor_list_ctx {
    char *json_out;
    int json_cap;
    size_t pos;
    int index;
    int failed;
};

static BOOL CALLBACK enum_monitor_list_cb(HMONITOR handle, HDC hdc, LPRECT rect, LPARAM param) {
    (void)hdc;
    (void)rect;
    struct win_monitor_list_ctx *ctx = (struct win_monitor_list_ctx *)param;
    if (ctx->failed) return FALSE;

    MONITORINFO mi;
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfo(handle, &mi)) return TRUE;

    char device_id[128];
    get_monitor_device_id(handle, device_id, sizeof(device_id));
    long w = mi.rcMonitor.right - mi.rcMonitor.left;
    long h = mi.rcMonitor.bottom - mi.rcMonitor.top;

    int n = snprintf(ctx->json_out + ctx->pos, (size_t)ctx->json_cap - ctx->pos,
                      "%s{\"uuid\":\"%s\",\"width\":%ld,\"height\":%ld,\"main\":%s}",
                      ctx->index == 0 ? "" : ",", device_id, w, h,
                      (mi.dwFlags & MONITORINFOF_PRIMARY) ? "true" : "false");
    if (n < 0 || (size_t)n >= (size_t)ctx->json_cap - ctx->pos) { ctx->failed = 1; return FALSE; }
    ctx->pos += (size_t)n;
    ctx->index++;
    return TRUE;
}

int rw_plat_list_displays_json(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) return fail("invalid buffer");
    struct win_monitor_list_ctx ctx = {json_out, json_cap, 0, 0, 0};
    ctx.json_out[0] = '\0';
    size_t n = (size_t)snprintf(json_out, (size_t)json_cap, "[");
    if (n >= (size_t)json_cap) return fail("display list truncated");
    ctx.pos = n;
    EnumDisplayMonitors(NULL, NULL, enum_monitor_list_cb, (LPARAM)&ctx);
    if (ctx.failed) return fail("display list truncated");
    int m = snprintf(json_out + ctx.pos, (size_t)json_cap - ctx.pos, "]");
    if (m < 0 || (size_t)m >= (size_t)json_cap - ctx.pos) return fail("display list truncated");
    set_error("");
    return 0;
}

/* Escapes/joins (title, class, exe) into the "title:class:exe" token
 * win-capture/win-wasapi's "window" setting expects, matching
 * libobs/util/windows/window-helpers.c's encode_dstr()/add_window() byte
 * for byte: '#' -> "#22" then ':' -> "#3A" (order matters — encoding ':'
 * first would corrupt the "#3A" marker's own colon). */
static void encode_window_component(const char *in, char *out, size_t out_size) {
    size_t oi = 0;
    out[0] = '\0';
    for (size_t i = 0; in && in[i] && oi + 4 < out_size; i++) {
        unsigned char c = (unsigned char)in[i];
        if (c == '#') {
            if (oi + 4 >= out_size) break;
            memcpy(out + oi, "#22", 3); oi += 3;
        } else if (c == ':') {
            if (oi + 4 >= out_size) break;
            memcpy(out + oi, "#3A", 3); oi += 3;
        } else {
            out[oi++] = (char)c;
        }
    }
    out[oi] = '\0';
}

/* Review finding #6 (fixed here while relocating this code): the window
 * title/class/exe buffers this shim reads a live window's identity into
 * are `title[1024]`/`win_class[512]`/`exe[260]` (see
 * enum_windows_list_cb/rebuild_video_capture below) — i.e. up to 1023/511/
 * 259 real characters. encode_window_component() can expand every single
 * character 3x (worst case: a title made entirely of '#'/':'), so the
 * *previous* intermediate buffers here (`et[512]`, `ec[256]`, `ee[256]`)
 * could truncate a title well under 200 real characters long, well short
 * of what a real window title buffer can hold. A truncated token no
 * longer matches libobs's own untruncated "title:class:exe" encoding of
 * the same window when it re-resolves the capture target internally, so
 * capture silently finds nothing for any sufficiently long-titled window.
 * Sized generously (3x each source buffer, i.e. a full worst-case title
 * round-trips intact) rather than tightly, since a stack buffer here costs
 * nothing at this call frequency (enumeration/re-derivation, not a hot
 * per-frame path). */
#define RW_WIN_ET_CAP 3100 /* > 3 * sizeof(title[1024]) */
#define RW_WIN_EC_CAP 1600 /* > 3 * sizeof(win_class[512]) */
#define RW_WIN_EE_CAP 800  /* > 3 * sizeof(exe[260]) */
/* Final "et:ec:ee" token: sum of the three components (each already sized
 * for its own worst case above) plus two ':' separators and a NUL. */
#define RW_WIN_TOKEN_CAP (RW_WIN_ET_CAP + RW_WIN_EC_CAP + RW_WIN_EE_CAP + 8)

static void build_window_token(const char *title, const char *win_class, const char *exe, char *out, size_t out_size) {
    char et[RW_WIN_ET_CAP], ec[RW_WIN_EC_CAP], ee[RW_WIN_EE_CAP];
    encode_window_component(title, et, sizeof(et));
    encode_window_component(win_class, ec, sizeof(ec));
    encode_window_component(exe, ee, sizeof(ee));
    snprintf(out, out_size, "%s:%s:%s", et, ec, ee);
}

/* Resolves `hwnd`'s owning process's executable basename (no directory, no
 * ".exe"-stripping — win-capture matches the full "name.exe" form). Empty
 * string on failure (e.g. a protected system process this app can't query
 * even with PROCESS_QUERY_LIMITED_INFORMATION). */
static void get_window_exe(HWND hwnd, char *out, size_t out_size) {
    out[0] = '\0';
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == 0 || pid == GetCurrentProcessId()) return;

    HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!proc) return;
    wchar_t wpath[MAX_PATH];
    DWORD cap = MAX_PATH;
    char path[MAX_PATH * 2] = "";
    if (QueryFullProcessImageNameW(proc, 0, wpath, &cap)) {
        WideCharToMultiByte(CP_UTF8, 0, wpath, (int)cap, path, (int)sizeof(path) - 1, NULL, NULL);
    }
    CloseHandle(proc);
    if (!path[0]) return;
    const char *base = strrchr(path, '\\');
    base = base ? base + 1 : path;
    snprintf(out, out_size, "%s", base);
}

static int is_cloaked(HWND hwnd) {
    DWORD cloaked = 0;
    HRESULT hr = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
    return SUCCEEDED(hr) && cloaked != 0;
}

/* Same visibility/ownership filters as check_window_valid() in
 * libobs/util/windows/window-helpers.c: visible top-level windows only, no
 * tool windows, no child windows, not DWM-cloaked (UWP suspended/hidden
 * frames report as "visible" but are cloaked), and a non-empty client
 * rect. */
static int is_capturable_window(HWND hwnd) {
    if (!IsWindowVisible(hwnd) || IsIconic(hwnd) || is_cloaked(hwnd)) return 0;
    LONG_PTR ex_styles = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    if (ex_styles & WS_EX_TOOLWINDOW) return 0;
    LONG_PTR styles = GetWindowLongPtr(hwnd, GWL_STYLE);
    if (styles & WS_CHILD) return 0;
    RECT rect;
    if (!GetClientRect(hwnd, &rect) || rect.right == 0 || rect.bottom == 0) return 0;
    return 1;
}

struct win_app_list_ctx {
    char *json_out;
    int json_cap;
    size_t pos;
    int count;
    int failed;
    char seen_exe[256][260]; /* dedup: one row per exe, topmost window wins */
    int seen_count;
};

static BOOL CALLBACK enum_windows_list_cb(HWND hwnd, LPARAM param) {
    struct win_app_list_ctx *ctx = (struct win_app_list_ctx *)param;
    if (ctx->failed) return TRUE;
    if (!is_capturable_window(hwnd)) return TRUE;

    char exe[260];
    get_window_exe(hwnd, exe, sizeof(exe));
    if (!exe[0]) return TRUE; /* couldn't resolve an owning exe; skip */

    for (int i = 0; i < ctx->seen_count; i++) {
        if (_stricmp(ctx->seen_exe[i], exe) == 0) return TRUE; /* dedup */
    }

    wchar_t wtitle[512] = {0};
    int tlen = GetWindowTextW(hwnd, wtitle, 512);
    char title[1024] = "";
    if (tlen > 0) WideCharToMultiByte(CP_UTF8, 0, wtitle, tlen, title, (int)sizeof(title) - 1, NULL, NULL);

    /* explorer.exe with no title is the desktop/shell itself, not a capturable
     * app window — mirrors add_window()'s own explorer.exe special case. */
    if (!title[0] && _stricmp(exe, "explorer.exe") == 0) return TRUE;

    wchar_t wclass[256] = {0};
    char win_class[512] = "";
    if (GetClassNameW(hwnd, wclass, 256))
        WideCharToMultiByte(CP_UTF8, 0, wclass, -1, win_class, (int)sizeof(win_class) - 1, NULL, NULL);

    char token[RW_WIN_TOKEN_CAP];
    build_window_token(title, win_class, exe, token, sizeof(token));

    char display_name[512];
    if (title[0]) {
        snprintf(display_name, sizeof(display_name), "%s", title);
    } else {
        /* Fall back to the exe name minus ".exe", mirroring the macOS
         * bundle-less-name fallback. */
        size_t elen = strlen(exe);
        if (elen > 4 && _stricmp(exe + elen - 4, ".exe") == 0) {
            snprintf(display_name, sizeof(display_name), "%.*s", (int)(elen - 4), exe);
        } else {
            snprintf(display_name, sizeof(display_name), "%s", exe);
        }
    }

    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);

    char escaped_id[1600] = "", escaped_name[1024] = "";
    json_escape_append(token, escaped_id, sizeof(escaped_id));
    json_escape_append(display_name, escaped_name, sizeof(escaped_name));

    int n = snprintf(ctx->json_out + ctx->pos, (size_t)ctx->json_cap - ctx->pos,
                      "%s{\"bundle_id\":\"%s\",\"name\":\"%s\",\"pid\":%d,\"icon\":\"\",\"window_id\":%u}",
                      ctx->count == 0 ? "" : ",", escaped_id, escaped_name, (int)pid,
                      (unsigned)(uintptr_t)hwnd);
    if (n < 0 || (size_t)n >= (size_t)ctx->json_cap - ctx->pos) { ctx->failed = 1; return FALSE; }
    ctx->pos += (size_t)n;
    ctx->count++;
    if (ctx->seen_count < 256) snprintf(ctx->seen_exe[ctx->seen_count++], 260, "%s", exe);
    return TRUE;
}

/* Enumerate top-level capturable windows into the same compact JSON shape
 * rewind_obs.h documents (bundle_id/name/pid/icon/window_id) — see
 * rewind_list_capturable_apps()'s doc comment. On Windows, "bundle_id" is
 * NOT a bundle id (Windows has none): it is the opaque "title:class:exe"
 * token win-capture/win-wasapi's own "window" setting expects (see
 * build_window_token above), round-tripped unchanged by
 * rewind_set_capture_app(). "icon" is always "" — Windows icon extraction
 * (ExtractIconEx + encoding to a file the Dart side can load) was scoped
 * out of this task; see native/shim/README.md. "window_id" is the HWND
 * truncated to 32 bits, which is lossless on 64-bit Windows: Microsoft
 * documents that HWNDs (like all Win32 handles) are 32-bit-interop-safe —
 * the top 32 bits of a 64-bit HWND are always zero. */
int rw_plat_list_capturable_apps_json(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) return fail("invalid buffer");
    struct win_app_list_ctx ctx = {json_out, json_cap, 0, 0, 0, {{0}}, 0};
    size_t n = (size_t)snprintf(json_out, (size_t)json_cap, "[");
    if (n >= (size_t)json_cap) return fail("app list truncated");
    ctx.pos = n;
    EnumWindows(enum_windows_list_cb, (LPARAM)&ctx);
    if (ctx.failed) return fail("app list truncated");
    int m = snprintf(json_out + ctx.pos, (size_t)json_cap - ctx.pos, "]");
    if (m < 0 || (size_t)m >= (size_t)json_cap - ctx.pos) return fail("app list truncated");
    set_error("");
    return 0;
}

/* (Re)builds the channel-1 audio source to match g_audio_mode:
 *   OFF -> no source.
 *   ALL -> every app's desktop audio.
 *   APP -> only the captured app's audio; if no app capture target is set,
 *          there's nothing to target, so it falls back to silence (logged)
 *          rather than leaking all desktop audio the user opted out of.
 * Safe to call before or after the pipeline exists.
 *
 * wasapi_output_capture (desktop, device_id="default") for ALL;
 * wasapi_process_output_capture (per-process WASAPI loopback, Windows 10
 * 20H1+ — see native/shim/README.md) targeting g_app_bundle_id's "window"
 * token for APP. Verified against plugins/win-wasapi/win-wasapi.cpp at the
 * pinned 32.1.2 tag: both source ids and their "device_id"/"window"/
 * "priority" settings keys. If ActivateAudioInterfaceAsync's process-loopback
 * mode isn't available (older Windows), obs_source_create still succeeds
 * (the failure surfaces later as a silent/empty audio track from the
 * source's own capture thread, not a NULL return here) — a residual gap
 * flagged in the task report; there is no cheap synchronous "is this
 * supported" probe exposed to callers. */
void rw_plat_rebuild_system_audio(void) {
    if (g_sysaudio) {
        obs_set_output_source(1, NULL);
        obs_source_release(g_sysaudio);
        g_sysaudio = NULL;
    }
    if (g_audio_mode == AUDIO_MODE_OFF) return;

    obs_data_t *s = obs_data_create();
    const char *source_id;
    if (g_audio_mode == AUDIO_MODE_APP) {
        if (!g_app_bundle_id[0]) {
            blog(LOG_WARNING, "rewind: app audio selected but no app capture "
                              "source is set; capturing no audio");
            obs_data_release(s);
            return;
        }
        source_id = "wasapi_process_output_capture";
        obs_data_set_string(s, "window", g_app_bundle_id);
        obs_data_set_int(s, "priority", 2 /* WINDOW_PRIORITY_EXE */);
    } else {
        source_id = "wasapi_output_capture";
        obs_data_set_string(s, "device_id", "default");
    }
    g_sysaudio = obs_source_create(source_id, "rewind-sysaudio", s, NULL);
    obs_data_release(s);
    if (g_sysaudio) {
        obs_set_output_source(1, g_sysaudio);
    } else {
        blog(LOG_WARNING, "rewind: %s unavailable; no system audio", source_id);
    }
}

/* Windows-only: which kind of source currently backs g_capture. Unlike
 * macOS's single "screen_capture" source (whose "type" setting switches
 * between display/window/app in place via obs_source_update()), Windows
 * uses TWO DIFFERENT source ids — "monitor_capture" for a display, and
 * "window_capture" for a specific window/app — so switching between the
 * two categories needs the source destroyed and recreated, not just
 * updated. Switching WITHIN a category (e.g. one monitor to another, or one
 * app window to another) stays a plain obs_source_update(). */
enum win_capture_kind { WIN_CAPTURE_NONE, WIN_CAPTURE_MONITOR, WIN_CAPTURE_WINDOW };
static enum win_capture_kind g_win_capture_kind = WIN_CAPTURE_NONE;

/* (Re)builds g_capture to match the current g_window_id/g_app_bundle_id/
 * g_display_uuid preference, in the same precedence order as macOS's
 * capture-source code: window beats app beats plain display. Safe to call
 * before g_capture exists (rw_plat_init_capture_source's first call) or
 * with it already live (the three rw_plat_on_capture_*_changed hooks
 * below). */
static void rebuild_video_capture(void) {
    int want_window = (g_window_id != 0) || g_app_bundle_id[0];
    enum win_capture_kind want_kind = want_window ? WIN_CAPTURE_WINDOW : WIN_CAPTURE_MONITOR;

    /* Re-derive a live "title:class:exe" token from the HWND every time —
     * window ids are ephemeral (see rewind_set_capture_window's doc) but as
     * long as the window is still open (the expected case: this is called
     * immediately after a fresh pick, or the window just didn't close),
     * GetWindowText/GetClassName/get_window_exe on it are still valid. */
    char window_token[RW_WIN_TOKEN_CAP] = "";
    if (g_window_id != 0) {
        HWND hwnd = (HWND)(uintptr_t)g_window_id;
        if (IsWindow(hwnd)) {
            wchar_t wtitle[512] = {0};
            int tlen = GetWindowTextW(hwnd, wtitle, 512);
            char title[1024] = "";
            if (tlen > 0) WideCharToMultiByte(CP_UTF8, 0, wtitle, tlen, title, (int)sizeof(title) - 1, NULL, NULL);
            wchar_t wclass[256] = {0};
            char win_class[512] = "";
            if (GetClassNameW(hwnd, wclass, 256))
                WideCharToMultiByte(CP_UTF8, 0, wclass, -1, win_class, (int)sizeof(win_class) - 1, NULL, NULL);
            char exe[260] = "";
            get_window_exe(hwnd, exe, sizeof(exe));
            build_window_token(title, win_class, exe, window_token, sizeof(window_token));
        } else {
            blog(LOG_WARNING, "rewind: capture window no longer exists; falling back");
        }
    }
    const char *effective_window = window_token[0] ? window_token : g_app_bundle_id;

    if (want_kind == WIN_CAPTURE_WINDOW && !effective_window[0]) {
        /* Window died and there's no app fallback either — revert to
         * display capture rather than leaving a dangling target. */
        want_kind = WIN_CAPTURE_MONITOR;
    }

    if (!g_capture || g_win_capture_kind != want_kind) {
        if (g_capture) {
            rw_attach_capture(NULL);
            obs_source_release(g_capture);
            g_capture = NULL;
        }
        obs_data_t *cs = obs_data_create();
        if (want_kind == WIN_CAPTURE_WINDOW) {
            obs_data_set_string(cs, "window", effective_window);
            obs_data_set_int(cs, "priority", 2 /* WINDOW_PRIORITY_EXE */);
            obs_data_set_bool(cs, "cursor", true);
            g_capture = obs_source_create("window_capture", "rewind-display", cs, NULL);
        } else {
            char monitor_id[128];
            if (g_display_uuid[0]) {
                snprintf(monitor_id, sizeof(monitor_id), "%s", g_display_uuid);
            } else {
                rw_plat_main_display_uuid(monitor_id, sizeof(monitor_id));
            }
            if (monitor_id[0]) obs_data_set_string(cs, "monitor_id", monitor_id);
            obs_data_set_bool(cs, "capture_cursor", true);
            g_capture = obs_source_create("monitor_capture", "rewind-display", cs, NULL);
        }
        obs_data_release(cs);
        if (g_capture) {
            rw_attach_capture(g_capture);
            g_win_capture_kind = want_kind;
        } else {
            g_win_capture_kind = WIN_CAPTURE_NONE;
            blog(LOG_WARNING, "rewind: %s capture source failed to create",
                 want_kind == WIN_CAPTURE_WINDOW ? "window_capture" : "monitor_capture");
        }
        return;
    }

    /* Same category as before — update the existing source in place. */
    obs_data_t *cs = obs_data_create();
    if (want_kind == WIN_CAPTURE_WINDOW) {
        obs_data_set_string(cs, "window", effective_window);
    } else {
        char monitor_id[128];
        if (g_display_uuid[0]) {
            snprintf(monitor_id, sizeof(monitor_id), "%s", g_display_uuid);
        } else {
            rw_plat_main_display_uuid(monitor_id, sizeof(monitor_id));
        }
        if (monitor_id[0]) obs_data_set_string(cs, "monitor_id", monitor_id);
    }
    obs_source_update(g_capture, cs);
    obs_data_release(cs);
}

/* Picks the best available H.264 video encoder, trying hardware first and
 * falling back to software — same fail-safe spirit as macOS's single
 * VideoToolbox call, just with more rungs on the ladder since Windows has no
 * single universal hardware encoder. Verified encoder ids against the
 * pinned 32.1.2 tag's actual registrations (see native/shim/README.md):
 *   1. "obs_nvenc_h264_tex" (plugins/obs-nvenc/nvenc.c) — NVIDIA, texture-
 *      based, needs a D3D11 (or CUDA/OpenGL) device and driver support;
 *      the module itself no-ops (obs_module_load returns false) if
 *      nvenc_supported() is false, so this id is simply never registered on
 *      a non-NVIDIA machine and obs_video_encoder_create() returns NULL —
 *      no probing needed here beyond trying it.
 *   2. "h264_texture_amf" (plugins/obs-ffmpeg/texture-amf.cpp) — AMD,
 *      texture-based; registered by obs-ffmpeg.dll itself on Windows x64
 *      (not folded into a separate obs-amf module in this tree).
 *   3. "obs_qsv11_v2" then "obs_qsv11" (plugins/obs-qsv11/obs-qsv11.c) —
 *      Intel Quick Sync; _v2 is the newer texture-sharing implementation,
 *      tried first, falling back to the legacy variant.
 *   4. "obs_x264" (plugins/obs-x264/obs-x264.c) — software, always
 *      available, the universal fallback.
 * All four accept "bitrate" (int, kbps) as their CBR rate-control setting —
 * a long-standing convention across every OBS video encoder, same key macOS
 * already uses for VideoToolbox. */
static obs_encoder_t *create_video_encoder(void) {
    static const char *candidates[] = {
        "obs_nvenc_h264_tex",
        "h264_texture_amf",
        "obs_qsv11_v2",
        "obs_qsv11",
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

/* ---- SDK / module path discovery -------------------------------------- */

/* Resolves the absolute directory containing this shared library:
 * GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS) on one of its
 * own exported symbols, then GetModuleFileNameW — the Win32 equivalents of
 * "which loaded module owns this address" and "what's its path", narrowed
 * via WideCharToMultiByte since the rest of the shim is plain (non-wide)
 * char*. */
int rw_plat_own_dir(char *out, size_t out_size) {
    HMODULE mod = NULL;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCWSTR)&rewind_obs_init, &mod))
        return 0;
    wchar_t wpath[MAX_PATH];
    DWORD n = GetModuleFileNameW(mod, wpath, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return 0;
    char resolved[PATH_MAX];
    int len8 = WideCharToMultiByte(CP_UTF8, 0, wpath, (int)n, resolved, (int)sizeof(resolved) - 1, NULL, NULL);
    if (len8 <= 0) return 0;
    resolved[len8] = '\0';
    char *slash = strrchr(resolved, '\\');
    if (!slash) slash = strrchr(resolved, '/');
    if (!slash) return 0;
    size_t len = (size_t)(slash - resolved);
    if (len >= out_size) return 0;
    memcpy(out, resolved, len);
    out[len] = '\0';
    return 1;
}

/* Windows has no realpath(); _fullpath() (msvcrt, same "resolve to an
 * absolute, canonical path" contract minus symlink resolution, which none
 * of our candidates rely on) stands in for it. */
char *rw_plat_realpath(const char *path, char *resolved) {
    return _fullpath(resolved, path, PATH_MAX);
}

/* Packaged-app SDK candidate: "<shim dir>" itself — Flutter's Windows
 * toolchain places a compiled dart:ffi code asset as a flat DLL directly
 * next to the built .exe (no nested-framework indirection like macOS), and
 * tools/bundle_obs_windows.ps1 drops obs-plugins/+data/ directly beside it
 * (see that script and native/shim/README.md) — so the SDK dir in the
 * packaged layout is just the shim's own directory, no relative hop
 * needed. */
int rw_plat_sdk_dir_candidate(const char *shim_dir, char *out, size_t out_size) {
    if (has_sdk_layout(shim_dir)) {
        snprintf(out, out_size, "%s", shim_dir);
        return 1;
    }
    return 0;
}

/* %module% is substituted by libobs per discovered module. Both trees are
 * flat — "obs-plugins/64bit/<name>.dll" and "data/obs-plugins/<name>/",
 * matching both the official OBS Windows release layout and what
 * tools/fetch_libobs_windows.ps1 assembles under native/third_party/obs/
 * (see that script and native/shim/README.md). */
void rw_plat_setup_module_paths(const char *sdk_dir) {
    char plugins_bin[PATH_MAX];
    char plugins_data[PATH_MAX];
    snprintf(plugins_bin, sizeof(plugins_bin), "%s/obs-plugins/64bit/%%module%%.dll", sdk_dir);
    snprintf(plugins_data, sizeof(plugins_data), "%s/data/obs-plugins/%%module%%", sdk_dir);
    obs_add_module_path(plugins_bin, plugins_data);
}

/* Resolves an absolute, existing path to libobs-d3d11.dll (NOT
 * libobs-opengl.dll). Deliberately forcing the D3D11 render device rather
 * than OpenGL: (1) win-capture's own obs_module_load() only registers the
 * modern DXGI-duplication "monitor_capture" (the "monitor_id"-string-keyed
 * one this shim targets — see the display-helpers comment above) when
 * `gs_get_device_type() == GS_DEVICE_DIRECT3D_11`, falling back to the
 * legacy GDI/"monitor" int-index source otherwise; (2) NVENC/AMF hardware
 * encoding is texture-based (nvenc-d3d11.c / texture-amf.cpp) and needs a
 * D3D11 device to hand off zero-copy GPU textures — without it those
 * encoders fail to attach and this shim would always fall through to
 * software x264. Tries, in order (mirrors the macOS dev-tree-then-packaged
 * shape):
 *   (a) "<sdk dir>/bin/64bit/libobs-d3d11.dll" — the layout
 *       tools/fetch_libobs_windows.ps1 assembles.
 *   (b) "<shim dir>/libobs-d3d11.dll" — packaged layout: the shim DLL and
 *       the whole bin/64bit/ closure are bundled flat, side by side, next
 *       to rewind.exe (see tools/bundle_obs_windows.ps1 — no nested-
 *       framework indirection like macOS). */
int rw_plat_find_graphics_module_path(const char *sdk_dir, const char *shim_dir, char *out, size_t out_size) {
    char a[PATH_MAX], b[PATH_MAX] = "";

    snprintf(a, sizeof(a), "%s/bin/64bit/libobs-d3d11.dll", sdk_dir);
    if (path_exists(a)) { snprintf(out, out_size, "%s", a); return 1; }

    if (shim_dir && shim_dir[0]) {
        snprintf(b, sizeof(b), "%s/libobs-d3d11.dll", shim_dir);
        if (path_exists(b)) { snprintf(out, out_size, "%s", b); return 1; }
    }

    char msg[768];
    int len = snprintf(msg, sizeof(msg), "could not locate libobs-d3d11.dll; tried \"%s\"", a);
    if (b[0] && len > 0 && (size_t)len < sizeof(msg))
        len += snprintf(msg + len, sizeof(msg) - (size_t)len, ", \"%s\"", b);
    if (len > 0 && (size_t)len < sizeof(msg))
        snprintf(msg + len, sizeof(msg) - (size_t)len, " (see native/shim/README.md)");
    set_error(msg);
    return 0;
}

/* Windows has no equivalent runtime permission prompt for screen capture —
 * nothing gates capture besides the SDK/module setup. */
int rw_plat_check_permission(void) {
    return 0;
}

/* No OS-level screen-capture permission gate on Windows (see above) — always
 * report/return granted. */
int rw_plat_preflight_screen_permission(void) {
    return 1;
}

int rw_plat_request_screen_permission(void) {
    return 1;
}

/* libobs' own core data (default.effect and friends — needed by
 * obs_reset_video() to set up scaling/color-conversion shaders) is looked
 * up via obs_find_data_file(), which tries find_libobs_data_file() FIRST —
 * hardcoded in libobs/obs-windows.c to the RELATIVE path
 * "../../data/libobs/", resolved against the process's CURRENT WORKING
 * DIRECTORY (not the exe's own directory, not obs.dll's directory —
 * verified against the real source: it's a plain os_file_exists() check on
 * a relative path, standard C file-io CWD semantics). That assumes OBS
 * Studio's own installed layout (bin/64bit/obs64.exe launched with its own
 * directory as CWD, two levels below data/libobs/) — which does NOT match
 * how tools/bundle_obs_windows.ps1 lays things out next to rewind.exe
 * (flat, no bin/64bit nesting), and Rewind has no control over the
 * process's CWD at launch anyway (Explorer/shortcut-dependent). Rather
 * than fight that, register the real data dir explicitly via the public
 * obs_add_data_path() API — obs_find_data_file() falls back to every path
 * added this way when find_libobs_data_file() doesn't resolve, so this
 * doesn't need find_libobs_data_file() to succeed at all. MUST happen
 * before obs_reset_video() (the first thing that loads these effects). */
void rw_plat_pre_video_setup(const char *sdk_dir) {
    char win_data_path[PATH_MAX];
    snprintf(win_data_path, sizeof(win_data_path), "%s/data/libobs/", sdk_dir);
    obs_add_data_path(win_data_path);
}

/* Windows: monitor_capture (display) or window_capture (window/app) — two
 * distinct source ids, unlike macOS's single "type"-switched source. See
 * rebuild_video_capture()'s doc comment. */
int rw_plat_init_capture_source(void) {
    rebuild_video_capture();
    if (!g_capture) {
        return fail("capture source failed to create (see log)");
    }
    return 0;
}

/* Encoders: create_video_encoder()'s NVENC/AMF/QSV/x264 ladder + ffmpeg's
 * software "ffmpeg_aac" (NOT "CoreAudio_AAC" — coreaudio-encoder.dll does
 * build on Windows in this tree, but only by dynamically loading Apple's
 * proprietary CoreAudioToolbox.dll, which Rewind has no license to
 * redistribute and which isn't present on a stock Windows machine;
 * ffmpeg_aac needs nothing beyond what's already bundled for muxing). */
int rw_plat_create_encoders(void) {
    g_venc = create_video_encoder();
    if (!g_venc) {
        return fail("no usable H.264 encoder found (tried NVENC, AMF, QSV, x264)");
    }
    obs_encoder_set_video(g_venc, obs_get_video());

    g_aenc = obs_audio_encoder_create("ffmpeg_aac", "rewind-aenc", NULL, 0, NULL);
    if (!g_aenc) { return fail("ffmpeg_aac encoder unavailable"); }
    obs_encoder_set_audio(g_aenc, obs_get_audio());
    return 0;
}

/* "device_id" is wasapi_input_capture's own settings key, same shape as
 * wasapi_output_capture's use of it in rw_plat_rebuild_system_audio above:
 * "default" selects the system default input; anything else is looked up
 * by WASAPI endpoint id. g_mic_device_uid empty means "use the default". */
obs_source_t *rw_plat_create_mic_source(void) {
    obs_data_t *ms = obs_data_create();
    obs_data_set_string(ms, "device_id",
                         g_mic_device_uid[0] ? g_mic_device_uid : "default");
    obs_source_t *mic = obs_source_create("wasapi_input_capture", "rewind-mic", ms, NULL);
    obs_data_release(ms);
    return mic;
}

void rw_plat_log_mic_unavailable(void) {
    blog(LOG_WARNING, "rewind: wasapi_input_capture unavailable");
}

/* TODO(windows): enumerate WASAPI input endpoints (IMMDeviceEnumerator,
 * EDataFlow eCapture) the way wasapi_input_capture's own obs_properties
 * callback does, mapping each endpoint's id string to "uid" and its
 * friendly (PKEY_Device_FriendlyName) name to "name". Not hardware-
 * validated in this task (no Windows machine in the loop) — an honest
 * empty list until then; the Dart picker hides itself when this returns
 * "[]" rather than showing a fake device. */
int rw_plat_list_audio_inputs_json(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) return fail("invalid buffer");
    static const char *empty = "[]";
    size_t needed = strlen(empty) + 1;
    if (needed > (size_t)json_cap) return fail("audio input list truncated");
    memcpy(json_out, empty, needed);
    set_error("");
    return 0;
}

int rw_plat_mux_helper_present(void) {
    char path[PATH_MAX];
    DWORD n = GetModuleFileNameA(NULL, path, sizeof(path));
    if (n == 0 || n >= sizeof(path)) return -1;
    char *slash = strrchr(path, '\\');
    if (!slash) return -1;
    snprintf(slash + 1, sizeof(path) - (size_t)(slash + 1 - path),
             "obs-ffmpeg-mux.exe");
    return path_exists(path);
}

/* Switching to/from an app target may mean switching source ids
 * (monitor_capture <-> window_capture) — see rebuild_video_capture(). */
void rw_plat_on_capture_display_changed(void) {
    if (g_initialized) rebuild_video_capture();
}

void rw_plat_on_capture_app_changed(void) {
    if (g_initialized) rebuild_video_capture();
}

/* window_id is an HWND here (see rewind_obs.h's doc — "window_id" from
 * rewind_list_capturable_apps on Windows is the HWND truncated to 32
 * bits). rebuild_video_capture() re-derives a live "title:class:exe" token
 * from it and may switch source ids (monitor_capture <-> window_capture). */
void rw_plat_on_capture_window_changed(void) {
    if (g_initialized) rebuild_video_capture();
}

void rw_plat_reset_capture_state(void) {
    g_win_capture_kind = WIN_CAPTURE_NONE;
}

#endif /* defined(REWIND_USE_LIBOBS) && defined(_WIN32) */
