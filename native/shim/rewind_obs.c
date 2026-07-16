/*
 * rewind_obs.c — Rewind's C shim over libobs.
 *
 * Two implementations live in this file, selected at compile time:
 *
 *   - REWIND_USE_LIBOBS defined: the real libobs-backed implementation
 *     (macOS only for now). See native/shim/README.md for how the SDK is
 *     located and the pinned tag it targets.
 *   - REWIND_USE_LIBOBS undefined: a self-contained STUB so the Flutter app
 *     links and runs before libobs is wired in / on platforms without a
 *     built SDK yet. `rewind_save_clip` returns a synthesized path so the
 *     Dart pipeline can be exercised end-to-end in "dev mode".
 *
 * Build, e.g. macOS real mode:
 *   clang -shared -fPIC rewind_obs.c -o librewind_obs.dylib \
 *       -DREWIND_USE_LIBOBS -Inative/third_party/obs/include \
 *       -Fnative/third_party/obs/lib -framework libobs \
 *       -framework ApplicationServices
 *
 * License: GPLv3.
 */
#include "rewind_obs.h"
#include <string.h>
#include <stdio.h>
#include <time.h>

static char g_last_error[256] = "";
static char g_last_clip[1024] = "";
static int  g_initialized = 0;

static void set_error(const char *msg) {
    strncpy(g_last_error, msg ? msg : "", sizeof(g_last_error) - 1);
    g_last_error[sizeof(g_last_error) - 1] = '\0';
}

const char *rewind_last_error(void) {
    return g_last_error;
}

#ifdef REWIND_USE_LIBOBS

#include <obs.h>
#include <util/platform.h>

#include <stdint.h>

#ifdef __APPLE__
#include <dlfcn.h>
#include <unistd.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <ApplicationServices/ApplicationServices.h>
#include <libproc.h>
#include <strings.h> /* strcasecmp */
#elif defined(_WIN32)
/* Windows real path (see native/shim/README.md's Windows section). No POSIX
 * headers here (no dlfcn.h/unistd.h/mach-o) — Win32 equivalents are used
 * throughout: GetModuleHandleEx+GetModuleFileName instead of dladdr,
 * GetFileAttributes instead of access(), _fullpath instead of realpath(),
 * EnumWindows/EnumDisplayMonitors instead of CoreGraphics. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h> /* DwmGetWindowAttribute(DWMWA_CLOAKED) */
#ifndef PATH_MAX
#define PATH_MAX MAX_PATH
#endif
#endif

static obs_source_t  *g_capture   = NULL;
static obs_encoder_t *g_venc      = NULL;
static obs_encoder_t *g_aenc      = NULL;
static obs_output_t  *g_replay    = NULL;
static int             g_seconds  = 30;

/* Manual-recording output (see rewind_start_recording). Created lazily on
 * first use, shares g_venc/g_aenc with g_replay, and is reused across
 * subsequent start/stop cycles rather than recreated each time. */
static obs_output_t  *g_recording      = NULL;
static char            g_recording_path[1024] = "";

/* User's preferred capture display, as a "display_uuid" string (see
 * rewind_set_capture_display). Empty means "use the main display" — the
 * long-standing default computed by main_display_uuid() at init time. Can
 * be set before rewind_obs_init(); applied at init and, if the capture
 * source already exists, applied immediately via obs_source_update(). */
static char g_display_uuid[128] = "";

/* User's preferred capture application, as a bundle id string (see
 * rewind_set_capture_app). Empty means "no app override" — fall back to
 * g_display_uuid / the main display, same as g_display_uuid's own default.
 * An app target takes precedence over a display target when both are set
 * (see rewind_obs_init and rewind_set_capture_app). Can be set before
 * rewind_obs_init(); applied at init and, if the capture source already
 * exists, applied immediately via obs_source_update(). */
static char g_app_bundle_id[256] = "";

/* Specific window to capture (a CGWindowID from the app enumeration's
 * "window_id" field; see rewind_set_capture_window). 0 means "no window
 * override". Ephemeral by design — window ids die with their process, so
 * callers re-resolve via enumeration rather than persisting one. Takes
 * precedence over g_app_bundle_id, which itself beats plain display
 * capture. The ONLY way to capture a CrossOver/Wine game specifically:
 * those processes have no bundle id for application capture (see the
 * enumeration doc), but their windows are ordinary CGWindows. */
static uint32_t g_window_id = 0;

/* Capture quality (see rewind_set_capture_quality). Applied at init via
 * obs_reset_video — changing them needs a fresh init (the video pipeline +
 * encoders are built around them), so the setter only stores when already
 * initialised; the UI applies the change on next launch. g_fps: capture
 * framerate. g_max_height: output is downscaled to this height (aspect
 * preserved) when the display is taller; 0 = source resolution. */
static int g_fps = 60;
static int g_max_height = 0;

/* Audio sources. Channel 0 carries the (video-only) screen capture;
 * without explicit audio SOURCES every clip's AAC track encodes silence.
 * Channel 1: system/desktop audio (sck_audio_capture, macOS 13+) — always
 * created at init. Channel 2: the microphone (coreaudio_input_capture),
 * toggled by rewind_set_mic_enabled (user preference; also needs the
 * NSMicrophoneUsageDescription TCC prompt on first use). */
static obs_source_t *g_sysaudio = NULL;
static obs_source_t *g_mic = NULL;
static int g_mic_enabled = 0; /* preference; applied at init if set early */

/* System/app audio mode (see rewind_set_audio_mode): 0 = off, 1 = all
 * desktop audio (every app), 2 = only the captured app's audio (SCK
 * application audio stream targeting g_app_bundle_id — needs an app capture
 * source; falls back to off when none). Default 1. */
#define AUDIO_MODE_OFF 0
#define AUDIO_MODE_ALL 1
#define AUDIO_MODE_APP 2
static int g_audio_mode = AUDIO_MODE_ALL;

static int fail(const char *msg) { set_error(msg); return 1; }

/* ---- SDK / module path discovery -----------------------------------
 *
 * The fetched SDK (tools/fetch_libobs.sh, see native/third_party/obs/)
 * lays out:
 *   <sdk>/include, <sdk>/lib (libobs.framework + libobs-opengl.dylib +
 *   FFmpeg/x264/mbedTLS runtime dylibs), <sdk>/obs-plugins (*.plugin
 *   bundles), <sdk>/data (libobs/ effects + obs-plugins/<name>/ locale).
 *
 * At runtime we need to find that <sdk> directory so we can point
 * obs_add_module_path() at obs-plugins/ + data/obs-plugins/, and load
 * libobs-opengl.dylib by absolute path (see graphics_module note below).
 * We never know <sdk> at compile time unless the build defines
 * REWIND_OBS_SDK_DIR (Task 10's job once app bundling exists), so we also
 * fall back to locating it relative to wherever this shared library
 * itself was loaded from.
 */

static int path_exists(const char *path) {
#ifdef _WIN32
    DWORD attr = GetFileAttributesA(path);
    return attr != INVALID_FILE_ATTRIBUTES;
#else
    return access(path, F_OK) == 0;
#endif
}

static int has_sdk_layout(const char *dir) {
    char probe[PATH_MAX];
    snprintf(probe, sizeof(probe), "%s/obs-plugins", dir);
    return path_exists(probe);
}

/* Resolves the absolute directory containing this shared library.
 * macOS: dladdr on one of its own exported symbols, then realpath().
 * Windows: GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS) on the
 * same kind of self-reference, then GetModuleFileNameW — the Win32
 * equivalents of "which loaded module owns this address" and "what's its
 * path", narrowed via WideCharToMultiByte since the rest of the shim is
 * plain (non-wide) char*. */
static int shim_own_dir(char *out, size_t out_size) {
#ifdef __APPLE__
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
#elif defined(_WIN32)
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
#else
    return 0;
#endif
}

/* Portable realpath(): macOS uses the POSIX call directly; Windows has no
 * realpath(), so _fullpath() (msvcrt, same "resolve to an absolute,
 * canonical path" contract minus symlink resolution, which none of our
 * candidates rely on) stands in for it. */
static char *portable_realpath(const char *path, char *resolved) {
#ifdef __APPLE__
    return realpath(path, resolved);
#elif defined(_WIN32)
    return _fullpath(resolved, path, PATH_MAX);
#else
    (void)path; (void)resolved;
    return NULL;
#endif
}

/* Locates the libobs SDK directory. Tries, in order:
 *   1. REWIND_OBS_SDK_DIR, if the build defined it.
 *   2. macOS: "<shim dir>/../Resources/obs" — packaged .app layout if the
 *      shim ships as a flat dylib directly in Contents/Frameworks/, SDK
 *      bundled alongside under Contents/Resources/obs.
 *   3. macOS: "<shim dir>/../../../../Resources/obs" — same packaged .app
 *      layout, but for how Flutter's macOS toolchain actually wraps a
 *      compiled dart:ffi code asset: as a *nested* framework bundle
 *      (Contents/Frameworks/rewind_obs.framework/Versions/A/rewind_obs),
 *      not a flat dylib. From Versions/A, Contents is four levels up
 *      (A -> Versions -> rewind_obs.framework -> Frameworks -> Contents),
 *      so candidate 2 above resolves two levels short of Resources/obs.
 *      Discovered during Task 10's real `flutter build macos` bundling —
 *      see native/shim/README.md and .superpowers/sdd/task-10-report.md.
 *      Kept candidate 2 as well (costs nothing, covers a flat-layout
 *      toolchain change).
 *   2'. Windows: "<shim dir>" itself — Flutter's Windows toolchain places a
 *      compiled dart:ffi code asset as a flat DLL directly next to the
 *      built .exe (no nested-framework indirection like macOS), and
 *      tools/bundle_obs_windows.ps1 drops obs-plugins/+data/ directly
 *      beside it (see that script and native/shim/README.md) — so the SDK
 *      dir in the packaged layout is just the shim's own directory, no
 *      relative hop needed.
 *   4. Walking up from the shim's own directory looking for
 *      "native/third_party/obs" — covers `flutter run`/`flutter build
 *      {macos,windows}` dev builds, whose build products stay nested under
 *      the repo root.
 * Returns 1 on success (out holds the SDK dir, no trailing slash). */
static int find_obs_sdk_dir(char *out, size_t out_size) {
#ifdef REWIND_OBS_SDK_DIR
    if (has_sdk_layout(REWIND_OBS_SDK_DIR)) {
        snprintf(out, out_size, "%s", REWIND_OBS_SDK_DIR);
        return 1;
    }
#endif
    char dir[PATH_MAX];
    if (!shim_own_dir(dir, sizeof(dir))) return 0;

    char candidate[PATH_MAX];
#ifdef __APPLE__
    snprintf(candidate, sizeof(candidate), "%s/../Resources/obs", dir);
    if (has_sdk_layout(candidate)) {
        if (!portable_realpath(candidate, out)) snprintf(out, out_size, "%s", candidate);
        return 1;
    }

    snprintf(candidate, sizeof(candidate), "%s/../../../../Resources/obs", dir);
    if (has_sdk_layout(candidate)) {
        if (!portable_realpath(candidate, out)) snprintf(out, out_size, "%s", candidate);
        return 1;
    }
#elif defined(_WIN32)
    if (has_sdk_layout(dir)) {
        snprintf(out, out_size, "%s", dir);
        return 1;
    }
#endif

    char ancestor[PATH_MAX];
    snprintf(ancestor, sizeof(ancestor), "%s", dir);
    for (int i = 0; i < 12; i++) {
        snprintf(candidate, sizeof(candidate), "%s/native/third_party/obs", ancestor);
        if (has_sdk_layout(candidate)) {
            snprintf(out, out_size, "%s", candidate);
            return 1;
        }
        char *slash = strrchr(ancestor, '/');
#ifdef _WIN32
        /* shim_own_dir() returns a backslash-separated Windows path; accept
         * either separator when walking up ancestors. */
        char *bslash = strrchr(ancestor, '\\');
        if (bslash && (!slash || bslash > slash)) slash = bslash;
#endif
        if (!slash || slash == ancestor) break;
        *slash = '\0';
    }
    return 0;
}

/* Appends `in` to `out` (caller-owned, `out_size` bytes, already
 * NUL-terminated), escaping the handful of characters that would break a
 * JSON string literal (quote, backslash, control chars — the latter
 * dropped rather than \u-escaped). Not a general-purpose JSON encoder;
 * sufficient for the app/bundle-id names this shim emits. Shared across
 * platforms (used by both the macOS and Windows enumeration branches
 * below). */
static void json_escape_append(const char *in, char *out, size_t out_size) {
    size_t oi = strlen(out);
    for (size_t i = 0; in && in[i] && oi + 2 < out_size; i++) {
        unsigned char c = (unsigned char)in[i];
        if (c == '"' || c == '\\') {
            if (oi + 3 >= out_size) break;
            out[oi++] = '\\';
            out[oi++] = (char)c;
        } else if (c < 0x20) {
            continue; /* drop control chars */
        } else {
            out[oi++] = (char)c;
        }
    }
    out[oi] = '\0';
}

/* ---- display + application/window enumeration ------------------------- */

#ifdef __APPLE__
static void query_main_display_size(uint32_t *width, uint32_t *height) {
    CGDirectDisplayID display = CGMainDisplayID();
    /* ScreenCaptureKit delivers frames in PHYSICAL pixels, but
     * CGDisplayPixelsWide/High return POINTS on Retina displays (half the
     * pixel size). Sizing the canvas in points leaves the capture rendered
     * 1:1 with only its top-left quarter visible. CGDisplayModeGetPixelWidth
     * gives the true pixel dimensions. */
    size_t w = 0, h = 0;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (mode) {
        w = CGDisplayModeGetPixelWidth(mode);
        h = CGDisplayModeGetPixelHeight(mode);
        CGDisplayModeRelease(mode);
    }
    if (w == 0 || h == 0) {
        w = CGDisplayPixelsWide(display);
        h = CGDisplayPixelsHigh(display);
    }
    *width = w > 0 ? (uint32_t)w : 1920;
    *height = h > 0 ? (uint32_t)h : 1080;
}

/* mac-capture's "screen_capture" (ScreenCaptureKit) source resolves which
 * physical display to capture from a "display_uuid" string setting; if
 * left unset it resolves to display id 0 (no display). Compute the main
 * display's UUID the same way OBS's own display-picker property does. */
static void main_display_uuid(char *out, size_t out_size) {
    out[0] = '\0';
    CGDirectDisplayID display = CGMainDisplayID();
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (!uuid) return;
    CFStringRef str = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    if (str) {
        CFStringGetCString(str, out, (CFIndex)out_size, kCFStringEncodingUTF8);
        CFRelease(str);
    }
    CFRelease(uuid);
}

/* Look up a display's UUID string given its CGDirectDisplayID. Same
 * approach as main_display_uuid(), for an arbitrary display. */
static void display_uuid_for_id(CGDirectDisplayID display, char *out, size_t out_size) {
    out[0] = '\0';
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (!uuid) return;
    CFStringRef str = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    if (str) {
        CFStringGetCString(str, out, (CFIndex)out_size, kCFStringEncodingUTF8);
        CFRelease(str);
    }
    CFRelease(uuid);
}

/* Enumerate active displays into a compact JSON array. Returns 0 on
 * success, non-zero (with set_error) if enumeration fails or `json_out` is
 * too small to hold the result. */
static int list_displays_json(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) return fail("invalid buffer");

    CGDirectDisplayID ids[32];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(32, ids, &count) != kCGErrorSuccess)
        return fail("CGGetActiveDisplayList failed");

    size_t pos = 0;
    json_out[0] = '\0';
#define APPEND(...) do { \
        int n = snprintf(json_out + pos, (size_t)json_cap - pos, __VA_ARGS__); \
        if (n < 0 || (size_t)n >= (size_t)json_cap - pos) return fail("display list truncated"); \
        pos += (size_t)n; \
    } while (0)

    APPEND("[");
    for (uint32_t i = 0; i < count; i++) {
        char uuid[128];
        display_uuid_for_id(ids[i], uuid, sizeof(uuid));
        size_t w = CGDisplayPixelsWide(ids[i]);
        size_t h = CGDisplayPixelsHigh(ids[i]);
        APPEND("%s{\"uuid\":\"%s\",\"width\":%u,\"height\":%u,\"main\":%s}",
               i == 0 ? "" : ",", uuid, (unsigned)w, (unsigned)h,
               CGDisplayIsMain(ids[i]) ? "true" : "false");
    }
    APPEND("]");
#undef APPEND
    set_error("");
    return 0;
}

/* ---- application enumeration (macOS) ---------------------------------
 *
 * Pure CoreFoundation/libproc route (no ObjC, keeps rewind_obs.c a single
 * plain-C translation unit): CGWindowListCopyWindowInfo gives every
 * on-screen window's owning pid (kCGWindowOwnerPID); proc_pidpath()
 * (libproc, part of libSystem — no extra framework) resolves that pid to
 * its executable's absolute path; walking up from the executable to the
 * nearest ancestor directory ending in ".app" gives the bundle root, which
 * CFBundleCreate()/CFBundleGetIdentifier() then reads for the bundle id.
 * This is the same identifier mac-sck-video-capture.m's
 * ScreenCaptureApplicationStream case matches "application" settings
 * against (SCRunningApplication.bundleIdentifier — populated from the
 * running process's own containing bundle, the same relationship this
 * code walks in the other direction). Verified CGWindowListCopyWindowInfo/
 * CFBundleCreate/proc_pidpath all compile, link and run against just
 * "-framework ApplicationServices" (already linked below) — CoreGraphics's
 * CGWindow.h and CoreFoundation's CFBundle.h both come in transitively via
 * ApplicationServices -> CoreServices, and proc_pidpath via libSystem.
 */

/* Walks `exe_path` up its directory components looking for the nearest
 * ancestor ending in ".app". Returns 1 and writes it to `out` on success,
 * 0 if none is found within a bounded number of hops (e.g. a bundle-less
 * command-line tool). */
static int find_app_bundle_path(const char *exe_path, char *out, size_t out_size) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s", exe_path);
    for (int i = 0; i < 16; i++) {
        char *slash = strrchr(path, '/');
        if (!slash || slash == path) return 0;
        *slash = '\0';
        size_t len = strlen(path);
        if (len > 4 && strcmp(path + len - 4, ".app") == 0) {
            snprintf(out, out_size, "%s", path);
            return 1;
        }
    }
    return 0;
}

/* Resolves `pid`'s bundle id + display name via its executable's containing
 * .app bundle, plus (best-effort) the absolute path of the bundle's .icns
 * icon — "" when the bundle declares no CFBundleIconFile (e.g. asset-
 * catalog-only apps); callers must tolerate the file not existing. Returns
 * 1 on success (bundle id resolved); `name_out` falls back to the bundle
 * directory's own name (minus ".app") if the bundle has no CFBundleName in
 * its Info.plist. All CF objects created here are released before
 * returning, on every path. */
static int bundle_info_for_pid(pid_t pid, char *bundle_id_out, size_t bundle_id_cap,
                                char *name_out, size_t name_cap,
                                char *icon_out, size_t icon_cap) {
    char exe_path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, exe_path, sizeof(exe_path)) <= 0) return 0;

    char app_path[PATH_MAX];
    if (!find_app_bundle_path(exe_path, app_path, sizeof(app_path))) return 0;

    CFStringRef path_str = CFStringCreateWithCString(kCFAllocatorDefault, app_path, kCFStringEncodingUTF8);
    if (!path_str) return 0;
    CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, path_str, kCFURLPOSIXPathStyle, true);
    CFRelease(path_str);
    if (!url) return 0;

    CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, url);
    CFRelease(url);
    if (!bundle) return 0;

    int ok = 0;
    CFStringRef bundle_id = CFBundleGetIdentifier(bundle);
    if (bundle_id && CFStringGetCString(bundle_id, bundle_id_out, (CFIndex)bundle_id_cap, kCFStringEncodingUTF8)) {
        ok = 1;
    }
    if (ok) {
        /* CFBundleGetValueForInfoDictionaryKey returns a bundle-owned
         * reference (not a copy) — no CFRelease for `name`. */
        CFStringRef name = CFBundleGetValueForInfoDictionaryKey(bundle, kCFBundleNameKey);
        if (!(name && CFGetTypeID(name) == CFStringGetTypeID() &&
              CFStringGetCString(name, name_out, (CFIndex)name_cap, kCFStringEncodingUTF8) && name_out[0])) {
            const char *slash = strrchr(app_path, '/');
            const char *base = slash ? slash + 1 : app_path;
            snprintf(name_out, name_cap, "%s", base);
            size_t len = strlen(name_out);
            if (len > 4 && strcmp(name_out + len - 4, ".app") == 0) name_out[len - 4] = '\0';
        }
    }
    if (ok && icon_out && icon_cap > 0) {
        icon_out[0] = '\0';
        CFStringRef icon = CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("CFBundleIconFile"));
        char icon_name[256] = "";
        if (icon && CFGetTypeID(icon) == CFStringGetTypeID() &&
            CFStringGetCString(icon, icon_name, sizeof(icon_name), kCFStringEncodingUTF8) &&
            icon_name[0]) {
            size_t ilen = strlen(icon_name);
            const char *suffix =
                (ilen > 5 && strcasecmp(icon_name + ilen - 5, ".icns") == 0) ? "" : ".icns";
            snprintf(icon_out, icon_cap, "%s/Contents/Resources/%s%s", app_path, icon_name, suffix);
        }
    }
    CFRelease(bundle);
    return ok;
}

/* True if `name` ends in ".exe" (case-insensitive) — a Windows program
 * running under a translation layer (CrossOver/Wine/Whisky). Wine sets both
 * the process comm and kCGWindowOwnerName to the Windows executable's name,
 * which is the only place the actual game's identity survives. Verified
 * live against CrossOver 2026-07-14:
 *   - proc_pidpath() for Wine pids either FAILS outright or resolves to a
 *     deleted winetemp-* stub with no .app ancestor, so the bundle route
 *     below silently drops every Wine window (the original bug: games
 *     never appeared in the picker at all);
 *   - NSRunningApplication.bundleIdentifier is nil for Wine processes, so
 *     ScreenCaptureKit application capture can NEVER target one — display
 *     capture is the only way to record a Wine game. */
static int is_windows_exe_name(const char *name) {
    size_t len = strlen(name);
    return len > 4 && strcasecmp(name + len - 4, ".exe") == 0;
}

/* Enumerate on-screen windows' owning applications into a compact JSON
 * array, deduplicated by bundle id. Windows-exe (Wine) processes are the
 * exception on every axis (see is_windows_exe_name): identified by
 * kCGWindowOwnerName instead of the (unresolvable) bundle route, named
 * after their exe minus ".exe", deduplicated by that name, and emitted
 * with an EMPTY bundle id — there is no bundle id ScreenCaptureKit could
 * match, and the Dart side treats "" as "keep capturing the display".
 * Returns 0 on success, non-zero (with set_error) if enumeration fails or
 * `json_out` is too small to hold the result. */
static int list_capturable_apps_json(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) return fail("invalid buffer");

    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!windows) return fail("CGWindowListCopyWindowInfo failed");

    pid_t self_pid = getpid();
    /* Dedup keys already emitted: "<bundle id>" for normal apps,
     * "<bundle id>\n<name>" for Wine exes (see doc above). 256 apps
     * comfortably covers any real desktop's on-screen window set; beyond
     * that, further duplicates of an already-seen key just aren't caught
     * against this table (soft limit — the entry was already emitted once,
     * so no incorrect output, just a missed dedup in a scenario that
     * shouldn't occur in practice). */
    char seen[256][384];
    int seen_count = 0;

    size_t pos = 0;
    json_out[0] = '\0';
#define APPEND(...) do { \
        int n = snprintf(json_out + pos, (size_t)json_cap - pos, __VA_ARGS__); \
        if (n < 0 || (size_t)n >= (size_t)json_cap - pos) { CFRelease(windows); return fail("app list truncated"); } \
        pos += (size_t)n; \
    } while (0)

    APPEND("[");
    int first = 1;
    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef entry = (CFDictionaryRef)CFArrayGetValueAtIndex(windows, i);
        CFNumberRef pid_num = (CFNumberRef)CFDictionaryGetValue(entry, kCGWindowOwnerPID);
        if (!pid_num) continue;
        pid_t pid = 0;
        if (!CFNumberGetValue(pid_num, kCFNumberIntType, &pid) || pid <= 0 || pid == self_pid) continue;

        /* Only normal windows of a real size. Menu-bar extras, the Dock,
         * Control Center, Notification Center etc. live on non-zero window
         * layers (or as tiny status windows) and are capture-picker noise,
         * not capturable applications. */
        CFNumberRef layer_num = (CFNumberRef)CFDictionaryGetValue(entry, kCGWindowLayer);
        int layer = 0;
        if (!layer_num || !CFNumberGetValue(layer_num, kCFNumberIntType, &layer) || layer != 0)
            continue;
        CFDictionaryRef bounds_dict = (CFDictionaryRef)CFDictionaryGetValue(entry, kCGWindowBounds);
        CGRect bounds = CGRectZero;
        if (!bounds_dict || !CGRectMakeWithDictionaryRepresentation(bounds_dict, &bounds) ||
            bounds.size.width < 64 || bounds.size.height < 64)
            continue;

        /* The owner name decides the route: Wine exes never resolve through
         * the bundle walk (proc_pidpath fails / winetemp stub), so it must
         * be consulted BEFORE bundle_info_for_pid gets a chance to drop the
         * window. */
        char owner[256] = "";
        CFStringRef owner_ref = (CFStringRef)CFDictionaryGetValue(entry, kCGWindowOwnerName);
        if (owner_ref) {
            if (!CFStringGetCString(owner_ref, owner, sizeof(owner), kCFStringEncodingUTF8))
                owner[0] = '\0';
        }
        int wine_exe = is_windows_exe_name(owner);

        char bundle_id[128] = "";
        char name[256] = "";
        char icon[PATH_MAX] = "";
        if (wine_exe) {
            snprintf(name, sizeof(name), "%s", owner);
            name[strlen(name) - 4] = '\0'; /* drop ".exe" */
        } else {
            if (!bundle_info_for_pid(pid, bundle_id, sizeof(bundle_id), name, sizeof(name),
                                     icon, sizeof(icon))) continue;
            if (!bundle_id[0]) continue;
        }

        char key[384];
        if (wine_exe) {
            snprintf(key, sizeof(key), "wine\n%s", name);
        } else {
            snprintf(key, sizeof(key), "%s", bundle_id);
        }
        int dup = 0;
        for (int s = 0; s < seen_count; s++) {
            if (strcmp(seen[s], key) == 0) { dup = 1; break; }
        }
        if (dup) continue;
        if (seen_count < 256) snprintf(seen[seen_count++], sizeof(seen[0]), "%s", key);

        /* CGWindowListCopyWindowInfo returns windows front-to-back, so the
         * first (only) window emitted per app is its frontmost — the one a
         * window-capture pick should target (see rewind_set_capture_window). */
        uint32_t window_id = 0;
        CFNumberRef win_num = (CFNumberRef)CFDictionaryGetValue(entry, kCGWindowNumber);
        if (win_num) {
            long long wid = 0;
            if (CFNumberGetValue(win_num, kCFNumberLongLongType, &wid) && wid > 0)
                window_id = (uint32_t)wid;
        }

        char escaped_id[256] = "";
        char escaped_name[512] = "";
        char escaped_icon[PATH_MAX * 2] = "";
        json_escape_append(bundle_id, escaped_id, sizeof(escaped_id));
        json_escape_append(name, escaped_name, sizeof(escaped_name));
        json_escape_append(icon, escaped_icon, sizeof(escaped_icon));

        APPEND("%s{\"bundle_id\":\"%s\",\"name\":\"%s\",\"pid\":%d,\"icon\":\"%s\",\"window_id\":%u}",
               first ? "" : ",", escaped_id, escaped_name, (int)pid, escaped_icon,
               (unsigned)window_id);
        first = 0;
    }
    APPEND("]");
#undef APPEND

    CFRelease(windows);
    set_error("");
    return 0;
}
#elif defined(_WIN32)

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

static void query_main_display_size(uint32_t *width, uint32_t *height) {
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
 * "monitor_id" device-id string (see get_monitor_device_id above). Kept the
 * same function name as the macOS branch since both are called from the
 * single shared call site in rewind_obs_init(). */
static void main_display_uuid(char *out, size_t out_size) {
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

static int list_displays_json(char *json_out, int json_cap) {
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

static void build_window_token(const char *title, const char *win_class, const char *exe, char *out, size_t out_size) {
    char et[512], ec[256], ee[256];
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

    char token[1600];
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
static int list_capturable_apps_json(char *json_out, int json_cap) {
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
#else
static void query_main_display_size(uint32_t *width, uint32_t *height) {
    *width = 1920;
    *height = 1080;
}
static void main_display_uuid(char *out, size_t out_size) {
    (void)out_size;
    out[0] = '\0';
}
static int list_displays_json(char *json_out, int json_cap) {
    (void)json_out; (void)json_cap;
    return fail("display enumeration not supported on this platform");
}
static int list_capturable_apps_json(char *json_out, int json_cap) {
    (void)json_out; (void)json_cap;
    return fail("application enumeration not supported on this platform");
}
#endif

/* (Re)builds the channel-1 audio source to match g_audio_mode:
 *   OFF -> no source.
 *   ALL -> every app's desktop audio.
 *   APP -> only the captured app's audio; if no app capture target is set,
 *          there's nothing to target, so it falls back to silence (logged)
 *          rather than leaking all desktop audio the user opted out of.
 * Safe to call before or after the pipeline exists.
 *
 * macOS: sck_audio_capture (ScreenCaptureKit audio streams — desktop or a
 * specific application by bundle id).
 * Windows: wasapi_output_capture (desktop, device_id="default") for ALL;
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
static void rebuild_system_audio(void) {
    if (g_sysaudio) {
        obs_set_output_source(1, NULL);
        obs_source_release(g_sysaudio);
        g_sysaudio = NULL;
    }
    if (g_audio_mode == AUDIO_MODE_OFF) return;

#ifdef __APPLE__
    obs_data_t *s = obs_data_create();
    if (g_audio_mode == AUDIO_MODE_APP) {
        if (!g_app_bundle_id[0]) {
            blog(LOG_WARNING, "rewind: app audio selected but no app capture "
                              "source is set; capturing no audio");
            obs_data_release(s);
            return;
        }
        obs_data_set_int(s, "type", 1); /* ScreenCaptureAudioApplicationStream */
        obs_data_set_string(s, "application", g_app_bundle_id);
    } else {
        obs_data_set_int(s, "type", 0); /* ScreenCaptureAudioDesktopStream */
    }
    g_sysaudio = obs_source_create("sck_audio_capture", "rewind-sysaudio", s, NULL);
    obs_data_release(s);
    if (g_sysaudio) {
        obs_set_output_source(1, g_sysaudio);
    } else {
        blog(LOG_WARNING, "rewind: sck_audio_capture unavailable; no system audio");
    }
#elif defined(_WIN32)
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
#endif
}

/* %module% is substituted by libobs per discovered module.
 * macOS: bin must mirror the real .plugin bundle layout (Contents/MacOS/
 * <name>), data uses the flat "data/obs-plugins/<name>/" layout
 * fetch_libobs.sh actually produces (independent template, not nested in
 * the bundle).
 * Windows: both trees are flat — "obs-plugins/64bit/<name>.dll" and
 * "data/obs-plugins/<name>/", matching both the official OBS Windows
 * release layout and what tools/fetch_libobs_windows.ps1 assembles under
 * native/third_party/obs/ (see that script and native/shim/README.md). */
static void setup_module_paths(const char *sdk_dir) {
    char plugins_bin[PATH_MAX];
    char plugins_data[PATH_MAX];
#ifdef __APPLE__
    snprintf(plugins_bin, sizeof(plugins_bin), "%s/obs-plugins/%%module%%.plugin/Contents/MacOS", sdk_dir);
    snprintf(plugins_data, sizeof(plugins_data), "%s/data/obs-plugins/%%module%%", sdk_dir);
#elif defined(_WIN32)
    snprintf(plugins_bin, sizeof(plugins_bin), "%s/obs-plugins/64bit/%%module%%.dll", sdk_dir);
    snprintf(plugins_data, sizeof(plugins_data), "%s/data/obs-plugins/%%module%%", sdk_dir);
#endif
    obs_add_module_path(plugins_bin, plugins_data);
}

/* Resolves an absolute, existing path to the graphics_module libobs should
 * load for its render device.
 *
 * macOS: libobs-opengl.dylib. Tries, in order (matching find_obs_sdk_dir()'s
 * dev-tree-then-packaged shape):
 *   (a) "<sdk dir>/lib/libobs-opengl.dylib" — the dev-tree / source-SDK
 *       layout tools/fetch_libobs.sh assembles (lib/ directly under the
 *       SDK root returned by find_obs_sdk_dir()).
 *   (b) "<shim dir>/../../../libobs-opengl.dylib" — packaged .app, shim
 *       nested in its own framework bundle, which is how Flutter's macOS
 *       toolchain actually wraps the compiled shim (see
 *       find_obs_sdk_dir()): Versions/A -> Versions -> rewind_obs.framework
 *       -> Frameworks is three levels, not one. tools/bundle_obs_macos.sh
 *       copies the whole lib/ closure (libobs.framework,
 *       libobs-opengl.dylib, the FFmpeg/x264/mbedTLS dylibs) straight
 *       into Contents/Frameworks/, *separate* from the obs-plugins/data
 *       tree it places under Contents/Resources/obs — so candidate (a)
 *       above doesn't find it in the packaged layout; there is no lib/
 *       under Resources/obs. See native/shim/README.md.
 *   (c) "<shim dir>/libobs-opengl.dylib" — same packaged layout, but for
 *       a flat-dylib shim placement directly in Contents/Frameworks/
 *       (insurance against a future toolchain change back to flat).
 *
 * Windows: libobs-d3d11.dll (NOT libobs-opengl.dll). Deliberately forcing
 * the D3D11 render device rather than OpenGL: (1) win-capture's own
 * obs_module_load() only registers the modern DXGI-duplication
 * "monitor_capture" (the "monitor_id"-string-keyed one this shim targets —
 * see the display-helpers comment above) when `gs_get_device_type() ==
 * GS_DEVICE_DIRECT3D_11`, falling back to the legacy GDI/"monitor" int-index
 * source otherwise; (2) NVENC/AMF hardware encoding is texture-based
 * (nvenc-d3d11.c / texture-amf.cpp) and needs a D3D11 device to hand off
 * zero-copy GPU textures — without it those encoders fail to attach and
 * this shim would always fall through to software x264. Tries, in order
 * (mirrors the macOS dev-tree-then-packaged shape):
 *   (a) "<sdk dir>/bin/64bit/libobs-d3d11.dll" — the layout
 *       tools/fetch_libobs_windows.ps1 assembles.
 *   (b) "<shim dir>/libobs-d3d11.dll" — packaged layout: the shim DLL and
 *       the whole bin/64bit/ closure are bundled flat, side by side, next
 *       to rewind.exe (see tools/bundle_obs_windows.ps1 — no nested-
 *       framework indirection like macOS). */
static int find_graphics_module_path(const char *sdk_dir, const char *shim_dir, char *out, size_t out_size) {
#ifdef __APPLE__
    char a[PATH_MAX], b[PATH_MAX] = "", c[PATH_MAX] = "";

    snprintf(a, sizeof(a), "%s/lib/libobs-opengl.dylib", sdk_dir);
    if (path_exists(a)) { snprintf(out, out_size, "%s", a); return 1; }

    if (shim_dir && shim_dir[0]) {
        snprintf(b, sizeof(b), "%s/../../../libobs-opengl.dylib", shim_dir);
        if (path_exists(b)) {
            if (!portable_realpath(b, out)) snprintf(out, out_size, "%s", b);
            return 1;
        }

        snprintf(c, sizeof(c), "%s/libobs-opengl.dylib", shim_dir);
        if (path_exists(c)) { snprintf(out, out_size, "%s", c); return 1; }
    }

    char msg[768];
    int len = snprintf(msg, sizeof(msg), "could not locate libobs-opengl.dylib; tried \"%s\"", a);
    if (b[0] && len > 0 && (size_t)len < sizeof(msg))
        len += snprintf(msg + len, sizeof(msg) - (size_t)len, ", \"%s\"", b);
    if (c[0] && len > 0 && (size_t)len < sizeof(msg))
        len += snprintf(msg + len, sizeof(msg) - (size_t)len, ", \"%s\"", c);
    if (len > 0 && (size_t)len < sizeof(msg))
        snprintf(msg + len, sizeof(msg) - (size_t)len, " (see native/shim/README.md)");
    set_error(msg);
    return 0;
#elif defined(_WIN32)
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
#endif
}

#ifdef _WIN32
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
 * rewind_obs_init/rewind_set_capture_* comments: window beats app beats
 * plain display. Safe to call before g_capture exists (rewind_obs_init's
 * first call) or with it already live (the three setters below). */
static void rebuild_video_capture(void) {
    int want_window = (g_window_id != 0) || g_app_bundle_id[0];
    enum win_capture_kind want_kind = want_window ? WIN_CAPTURE_WINDOW : WIN_CAPTURE_MONITOR;

    /* Re-derive a live "title:class:exe" token from the HWND every time —
     * window ids are ephemeral (see rewind_set_capture_window's doc) but as
     * long as the window is still open (the expected case: this is called
     * immediately after a fresh pick, or the window just didn't close),
     * GetWindowText/GetClassName/get_window_exe on it are still valid. */
    char window_token[1600] = "";
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
            obs_set_output_source(0, NULL);
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
                main_display_uuid(monitor_id, sizeof(monitor_id));
            }
            if (monitor_id[0]) obs_data_set_string(cs, "monitor_id", monitor_id);
            obs_data_set_bool(cs, "capture_cursor", true);
            g_capture = obs_source_create("monitor_capture", "rewind-display", cs, NULL);
        }
        obs_data_release(cs);
        if (g_capture) {
            obs_set_output_source(0, g_capture);
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
            main_display_uuid(monitor_id, sizeof(monitor_id));
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
#endif

int rewind_obs_init(const char *out_dir, int seconds) {
    if (g_initialized) return 0;
    g_seconds = seconds > 0 ? seconds : 30;

#ifdef __APPLE__
    /* Ask TCC directly instead of letting capture fail with a misleading
     * generic error later. CGRequestScreenCaptureAccess() shows the system
     * prompt the first time (subsequent calls are no-ops), so the user gets
     * the native dialog AND our banner explains the state precisely. */
    if (!CGPreflightScreenCaptureAccess()) {
        CGRequestScreenCaptureAccess();
        return fail("Screen Recording permission is not granted to this app. "
                    "Enable it under System Settings > Privacy & Security > "
                    "Screen Recording, then relaunch Rewind.");
    }
#endif
    /* Windows has no equivalent runtime permission prompt for screen
     * capture — nothing gates capture besides the SDK/module setup below. */

    char sdk_dir[PATH_MAX];
    if (!find_obs_sdk_dir(sdk_dir, sizeof(sdk_dir)))
        return fail("could not locate the libobs SDK (obs-plugins/data) relative to the shim; "
                     "see native/shim/README.md");

    if (!obs_startup("en-US", NULL, NULL)) return fail("obs_startup failed");

#ifdef _WIN32
    /* libobs' own core data (default.effect and friends — needed by
     * obs_reset_video() below to set up scaling/color-conversion shaders)
     * is looked up via obs_find_data_file(), which tries
     * find_libobs_data_file() FIRST — hardcoded in libobs/obs-windows.c to
     * the RELATIVE path "../../data/libobs/", resolved against the
     * process's CURRENT WORKING DIRECTORY (not the exe's own directory,
     * not obs.dll's directory — verified against the real source: it's a
     * plain os_file_exists() check on a relative path, standard C file-io
     * CWD semantics). That assumes OBS Studio's own installed layout
     * (bin/64bit/obs64.exe launched with its own directory as CWD, two
     * levels below data/libobs/) — which does NOT match how
     * tools/bundle_obs_windows.ps1 lays things out next to rewind.exe (flat,
     * no bin/64bit nesting), and Rewind has no control over the process's
     * CWD at launch anyway (Explorer/shortcut-dependent). Rather than
     * fight that, register the real data dir explicitly via the public
     * obs_add_data_path() API — obs_find_data_file() falls back to every
     * path added this way when find_libobs_data_file() doesn't resolve, so
     * this doesn't need find_libobs_data_file() to succeed at all. MUST
     * happen before obs_reset_video() below (the first thing that loads
     * these effects). */
    char win_data_path[PATH_MAX];
    snprintf(win_data_path, sizeof(win_data_path), "%s/data/libobs/", sdk_dir);
    obs_add_data_path(win_data_path);
#endif

    /* From this point on, obs_startup() has succeeded and obs_startup()
     * refuses to run a second time for the life of the process. Every
     * failure below MUST go through `cleanup` (which releases whatever
     * was created and calls obs_shutdown()) rather than returning
     * directly — otherwise g_initialized stays 0, rewind_obs_shutdown()
     * early-returns without calling obs_shutdown(), and every later
     * rewind_obs_init() retry fails forever. This is not hypothetical:
     * it fires on Screen Recording permission denial and (until the SDK
     * re-fetch adding mac-videotoolbox lands) on the missing
     * VideoToolbox encoder below. */

    uint32_t width = 1920, height = 1080;
    query_main_display_size(&width, &height);

    /* graphics_module is passed straight to os_dlopen(), which for a bare
     * name (no path separators) relies on dyld's default/fallback search
     * paths — our lib/ dir isn't on those. Pass an absolute path instead
     * so it resolves unambiguously regardless of environment. Must
     * outlive this function (obs_reset_video may not copy it), hence
     * static. Extension must be present (".dylib") or os_dlopen appends
     * ".so", which doesn't exist here.
     *
     * The packaged .app layout ships libobs-opengl.dylib in
     * Contents/Frameworks/, not under the Resources/obs SDK tree
     * find_obs_sdk_dir() resolved above (that tree only has
     * obs-plugins/data) — so this needs its own discovery, not just
     * "<sdk_dir>/lib/...". See find_graphics_module_path(). */
    char shim_dir[PATH_MAX];
    if (!shim_own_dir(shim_dir, sizeof(shim_dir))) shim_dir[0] = '\0';

    static char graphics_module[PATH_MAX];
    if (!find_graphics_module_path(sdk_dir, shim_dir, graphics_module, sizeof(graphics_module))) {
        /* find_graphics_module_path() already set a detailed error naming
         * every path it tried; don't clobber it with a generic one. */
        goto cleanup;
    }

    /* Output resolution: source unless g_max_height caps it, in which case
     * scale down preserving aspect ratio (round width to an even number —
     * H.264 chroma subsampling requires even dimensions). */
    uint32_t out_w = width, out_h = height;
    if (g_max_height > 0 && height > (uint32_t)g_max_height) {
        out_h = (uint32_t)g_max_height;
        out_w = (uint32_t)((double)width * out_h / height + 0.5);
        out_w &= ~1u;
        if (out_w == 0) out_w = 2;
    }
    int fps = g_fps > 0 ? g_fps : 60;

    struct obs_video_info ovi = {
        .graphics_module = graphics_module,
        .fps_num = (uint32_t)fps, .fps_den = 1,
        .base_width = width, .base_height = height,
        .output_width = out_w, .output_height = out_h,
        .output_format = VIDEO_FORMAT_NV12,
        .colorspace = VIDEO_CS_709, .range = VIDEO_RANGE_PARTIAL,
        .adapter = 0, .gpu_conversion = true, .scale_type = OBS_SCALE_BICUBIC,
    };
    blog(LOG_INFO, "rewind: capture %ux%u @%dfps (source %ux%u)",
         out_w, out_h, fps, width, height);
    if (obs_reset_video(&ovi) != OBS_VIDEO_SUCCESS) { set_error("obs_reset_video failed"); goto cleanup; }

    struct obs_audio_info oai = { .samples_per_sec = 48000, .speakers = SPEAKERS_STEREO };
    if (!obs_reset_audio(&oai)) { set_error("obs_reset_audio failed"); goto cleanup; }

    setup_module_paths(sdk_dir);
    obs_load_all_modules();
    obs_post_load_modules();

#ifdef __APPLE__
    /* ScreenCaptureKit display/application capture (mac-capture module,
     * "screen_capture" source id — registered when ScreenCaptureKit is
     * available, which it is on the macOS versions Rewind targets). */
    obs_data_t *cs = obs_data_create();
    obs_data_set_bool(cs, "show_cursor", true);
    /* display_uuid is set regardless of which "type" ends up selected
     * below: ScreenCaptureApplicationStream ALSO resolves a target display
     * from display_uuid (mac-sck-video-capture.m's ScreenCaptureApplicationStream
     * case calls get_target_display(), backed by get_display_migrate_settings()
     * reading "display_uuid" — window-utils.m), so an app target with no
     * display_uuid at all resolves to display id 0 and silently fails to
     * start the stream. Kept the same main-display-or-preferred-display
     * resolution either way. */
    char uuid[128];
    if (g_display_uuid[0]) {
        snprintf(uuid, sizeof(uuid), "%s", g_display_uuid);
    } else {
        main_display_uuid(uuid, sizeof(uuid));
    }
    if (uuid[0]) obs_data_set_string(cs, "display_uuid", uuid);
    if (g_window_id != 0) {
        /* Window target beats app target beats plain display capture. */
        obs_data_set_int(cs, "type", 1); /* ScreenCaptureWindowStream */
        obs_data_set_int(cs, "window", (long long)g_window_id);
    } else if (g_app_bundle_id[0]) {
        obs_data_set_int(cs, "type", 2); /* ScreenCaptureApplicationStream */
        obs_data_set_string(cs, "application", g_app_bundle_id);
    } else {
        obs_data_set_int(cs, "type", 0); /* ScreenCaptureDisplayStream */
    }
    g_capture = obs_source_create("screen_capture", "rewind-display", cs, NULL);
    obs_data_release(cs);
    if (!g_capture) {
        set_error("screen_capture source failed (Screen Recording permission not granted?)");
        goto cleanup;
    }
    obs_set_output_source(0, g_capture);
#elif defined(_WIN32)
    /* Windows: monitor_capture (display) or window_capture (window/app) —
     * two distinct source ids, unlike macOS's single "type"-switched
     * source. See rebuild_video_capture()'s doc comment. */
    rebuild_video_capture();
    if (!g_capture) {
        set_error("capture source failed to create (see log)");
        goto cleanup;
    }
#endif

    /* System/app audio on channel 1 (the video capture source on channel 0
     * carries video only — without an audio source a clip's AAC track is
     * silence). Built per g_audio_mode; see rebuild_system_audio(). */
    rebuild_system_audio();

    /* Microphone, if the preference was set before init. */
    if (g_mic_enabled) {
#ifdef __APPLE__
        g_mic = obs_source_create("coreaudio_input_capture", "rewind-mic", NULL, NULL);
        if (g_mic) obs_set_output_source(2, g_mic);
        else blog(LOG_WARNING, "rewind: coreaudio_input_capture unavailable (mic permission?)");
#elif defined(_WIN32)
        obs_data_t *ms = obs_data_create();
        obs_data_set_string(ms, "device_id", "default");
        g_mic = obs_source_create("wasapi_input_capture", "rewind-mic", ms, NULL);
        obs_data_release(ms);
        if (g_mic) obs_set_output_source(2, g_mic);
        else blog(LOG_WARNING, "rewind: wasapi_input_capture unavailable");
#endif
    }

    /* Encoders: hardware H.264 (with a software fallback) + AAC.
     * macOS: VideoToolbox H.264 + CoreAudio AAC. NOTE: the VideoToolbox
     * encoder id is registered by the mac-videotoolbox plugin, which is a
     * SEPARATE module from mac-capture/obs-ffmpeg/coreaudio-encoder — see
     * native/shim/README.md and the task-9 report for why this currently
     * fails until that module is added to the fetched SDK.
     * Windows: create_video_encoder()'s NVENC/AMF/QSV/x264 ladder + ffmpeg's
     * software "ffmpeg_aac" (NOT "CoreAudio_AAC" — coreaudio-encoder.dll
     * does build on Windows in this tree, but only by dynamically loading
     * Apple's proprietary CoreAudioToolbox.dll, which Rewind has no license
     * to redistribute and which isn't present on a stock Windows machine;
     * ffmpeg_aac needs nothing beyond what's already bundled for muxing). */
#ifdef __APPLE__
    obs_data_t *ve = obs_data_create();
    obs_data_set_int(ve, "bitrate", 12000);
    g_venc = obs_video_encoder_create(
        "com.apple.videotoolbox.videoencoder.ave.avc", "rewind-venc", ve, NULL);
    obs_data_release(ve);
    if (!g_venc) {
        set_error("VideoToolbox H.264 encoder unavailable (mac-videotoolbox module not loaded)");
        goto cleanup;
    }
    obs_encoder_set_video(g_venc, obs_get_video());

    g_aenc = obs_audio_encoder_create("CoreAudio_AAC", "rewind-aenc", NULL, 0, NULL);
    if (!g_aenc) { set_error("CoreAudio AAC encoder unavailable"); goto cleanup; }
    obs_encoder_set_audio(g_aenc, obs_get_audio());
#elif defined(_WIN32)
    g_venc = create_video_encoder();
    if (!g_venc) {
        set_error("no usable H.264 encoder found (tried NVENC, AMF, QSV, x264)");
        goto cleanup;
    }
    obs_encoder_set_video(g_venc, obs_get_video());

    g_aenc = obs_audio_encoder_create("ffmpeg_aac", "rewind-aenc", NULL, 0, NULL);
    if (!g_aenc) { set_error("ffmpeg_aac encoder unavailable"); goto cleanup; }
    obs_encoder_set_audio(g_aenc, obs_get_audio());
#endif

    /* Replay buffer output (obs-ffmpeg module). */
    obs_data_t *ro = obs_data_create();
    obs_data_set_string(ro, "directory", out_dir);
    obs_data_set_string(ro, "format", "rewind-%CCYY-%MM-%DD-%hh-%mm-%ss");
    obs_data_set_string(ro, "extension", "mp4");
    obs_data_set_int(ro, "max_time_sec", g_seconds);
    obs_data_set_int(ro, "max_size_mb", 0);
    g_replay = obs_output_create("replay_buffer", "rewind-replay", ro, NULL);
    obs_data_release(ro);
    if (!g_replay) { set_error("replay_buffer output unavailable"); goto cleanup; }
    obs_output_set_video_encoder(g_replay, g_venc);
    obs_output_set_audio_encoder(g_replay, g_aenc, 0);

    g_initialized = 1;
    set_error("");
    return 0;

cleanup:
    /* g_initialized is still 0 here, so rewind_obs_shutdown()'s own
     * early-return guard doesn't apply — release everything created so
     * far (in the same order rewind_obs_shutdown() uses) and tear down
     * obs_startup()'s global state ourselves, so a later
     * rewind_obs_init() retry starts from a clean slate instead of
     * obs_startup() refusing to run a second time forever. */
    if (g_replay) { obs_output_release(g_replay); g_replay = NULL; }
    if (g_venc) { obs_encoder_release(g_venc); g_venc = NULL; }
    if (g_aenc) { obs_encoder_release(g_aenc); g_aenc = NULL; }
    if (g_mic) {
        obs_set_output_source(2, NULL);
        obs_source_release(g_mic);
        g_mic = NULL;
    }
    if (g_sysaudio) {
        obs_set_output_source(1, NULL);
        obs_source_release(g_sysaudio);
        g_sysaudio = NULL;
    }
    if (g_capture) {
        obs_set_output_source(0, NULL);
        obs_source_release(g_capture);
        g_capture = NULL;
    }
#ifdef _WIN32
    g_win_capture_kind = WIN_CAPTURE_NONE;
#endif
    obs_shutdown();
    return 1;
}

/* obs-ffmpeg's replay buffer spawns the obs-ffmpeg-mux helper from the
 * directory of the MAIN executable; if it's absent, obs_output_start fails
 * with no last_error set. Check for it so the failure names its cause. */
static int mux_helper_present(void) {
#ifdef __APPLE__
    char path[PATH_MAX];
    uint32_t cap = sizeof(path);
    if (_NSGetExecutablePath(path, &cap) != 0) return -1;
    char *slash = strrchr(path, '/');
    if (!slash) return -1;
    snprintf(slash + 1, sizeof(path) - (size_t)(slash + 1 - path),
             "obs-ffmpeg-mux");
    return access(path, X_OK) == 0;
#elif defined(_WIN32)
    char path[PATH_MAX];
    DWORD n = GetModuleFileNameA(NULL, path, sizeof(path));
    if (n == 0 || n >= sizeof(path)) return -1;
    char *slash = strrchr(path, '\\');
    if (!slash) return -1;
    snprintf(slash + 1, sizeof(path) - (size_t)(slash + 1 - path),
             "obs-ffmpeg-mux.exe");
    return path_exists(path);
#else
    return -1;
#endif
}

int rewind_start_buffer(void) {
    if (!g_initialized) return fail("not initialized");
    if (!obs_output_start(g_replay)) {
        const char *err = obs_output_get_last_error(g_replay);
        if (err && *err) return fail(err);
        if (mux_helper_present() == 0)
            return fail("replay buffer failed to start: the obs-ffmpeg-mux "
                        "helper is missing next to the app executable "
                        "(rebuild, or re-run tools/bundle_obs_macos.sh)");
        return fail("replay buffer failed to start (no detail from libobs; "
                    "check the in-app Logs screen)");
    }
    return 0;
}

const char *rewind_save_clip(const char *out_dir) {
    (void)out_dir; /* directory fixed at init for the replay output */
    if (!g_initialized || !obs_output_active(g_replay)) {
        set_error("buffer not running");
        return NULL;
    }
    proc_handler_t *ph = obs_output_get_proc_handler(g_replay);

    /* Snapshot the replay path as libobs currently reports it *before*
     * triggering this save, and detect completion against that snapshot
     * rather than the shim's own g_last_clip. The replay-buffer's
     * filename format is second-resolution (see README), so comparing
     * against g_last_clip breaks when two saves land in the same
     * wall-clock second: the second save's completed path can be
     * identical to the g_last_clip already recorded from the first, the
     * change is never detected, and this call times out even though the
     * save did complete. Comparing against a fresh "before" snapshot
     * fixes that for the common case (saves in different seconds).
     * NOTE: two saves within the very same second still can't be told
     * apart from each other (both produce the same filename) — accepted
     * as a residual limitation for v0.1. */
    char before[sizeof(g_last_clip)] = "";
    {
        calldata_t snap = {0};
        proc_handler_call(ph, "get_last_replay", &snap);
        const char *p = calldata_string(&snap, "path");
        if (p) {
            strncpy(before, p, sizeof(before) - 1);
            before[sizeof(before) - 1] = '\0';
        }
        calldata_free(&snap);
    }

    calldata_t cd = {0};
    if (!proc_handler_call(ph, "save", &cd)) {
        set_error("save call failed");
        calldata_free(&cd);
        return NULL;
    }
    calldata_free(&cd);

    /* The save is async: poll get_last_replay until it changes (<=5 s). */
    for (int i = 0; i < 100; i++) {
        os_sleep_ms(50);
        calldata_t out = {0};
        proc_handler_call(ph, "get_last_replay", &out);
        const char *path = calldata_string(&out, "path");
        if (path && *path && strcmp(path, before) != 0) {
            strncpy(g_last_clip, path, sizeof(g_last_clip) - 1);
            g_last_clip[sizeof(g_last_clip) - 1] = '\0';
            calldata_free(&out);
            set_error("");
            return g_last_clip;
        }
        calldata_free(&out);
    }
    set_error("timed out waiting for replay save");
    return NULL;
}

int rewind_stop_buffer(void) {
    if (!g_initialized) return fail("not initialized");
    obs_output_stop(g_replay);
    set_error("");
    return 0;
}

int rewind_start_recording(const char *out_dir) {
    if (!g_initialized) return fail("not initialized");
    if (!out_dir || !out_dir[0]) return fail("out_dir is required");
    if (g_recording && obs_output_active(g_recording))
        return fail("recording already in progress");

    if (!g_recording) {
        /* Created once and reused for every subsequent start/stop cycle
         * (obs_output_update() below refreshes its "path" setting per
         * recording rather than recreating the output). Shares g_venc/
         * g_aenc with g_replay: obs_output_set_video_encoder/audio_encoder
         * only refuse to attach when the TARGET output is itself active
         * (see obs_output_set_video_encoder2 in libobs/obs-output.c), not
         * when the encoder is already attached to another output — so
         * g_replay and g_recording can both encode concurrently from the
         * same encoder pair, the same fan-out OBS Studio itself relies on
         * for simultaneous stream+recording+replay. */
        obs_data_t *ro = obs_data_create();
        g_recording = obs_output_create("ffmpeg_muxer", "rewind-recording", ro, NULL);
        obs_data_release(ro);
        if (!g_recording) return fail("ffmpeg_muxer output unavailable");
        obs_output_set_video_encoder(g_recording, g_venc);
        obs_output_set_audio_encoder(g_recording, g_aenc, 0);
    }

    /* Mirrors the replay buffer's own filename style: os_generate_formatted_
     * filename is the same helper libobs's own replay-buffer/recording
     * outputs use internally (see generate_filename() in obs-ffmpeg-mux.c)
     * for the %CCYY-%MM-%DD-... template. ffmpeg_muxer's "path" setting
     * wants a full file path, not a directory+format pair (see
     * ffmpeg_mux_start_internal() in obs-ffmpeg-mux.c), so the directory
     * join happens here rather than being left to libobs. */
    char *filename = os_generate_formatted_filename(
        "mp4", false, "rewind-rec-%CCYY-%MM-%DD-%hh-%mm-%ss");
    if (!filename) return fail("failed to generate recording filename");

    char path[1024];
    size_t dir_len = strlen(out_dir);
    int has_trailing_slash = dir_len > 0 && out_dir[dir_len - 1] == '/';
    snprintf(path, sizeof(path), "%s%s%s", out_dir,
             has_trailing_slash ? "" : "/", filename);
    bfree(filename);

    os_mkdirs(out_dir);

    obs_data_t *settings = obs_data_create();
    obs_data_set_string(settings, "path", path);
    obs_output_update(g_recording, settings);
    obs_data_release(settings);

    if (!obs_output_start(g_recording)) {
        const char *err = obs_output_get_last_error(g_recording);
        if (err && *err) return fail(err);
        if (mux_helper_present() == 0)
            return fail("recording failed to start: the obs-ffmpeg-mux "
                        "helper is missing next to the app executable "
                        "(rebuild, or re-run tools/bundle_obs_macos.sh)");
        return fail("recording failed to start (no detail from libobs; "
                    "check the in-app Logs screen)");
    }

    strncpy(g_recording_path, path, sizeof(g_recording_path) - 1);
    g_recording_path[sizeof(g_recording_path) - 1] = '\0';
    set_error("");
    return 0;
}

const char *rewind_stop_recording(void) {
    if (!g_initialized || !g_recording || !obs_output_active(g_recording)) {
        set_error("recording not in progress");
        return NULL;
    }
    obs_output_stop(g_recording);

    /* obs_output_stop() is a graceful async stop (flushes buffered frames,
     * finalises the file, exits the obs-ffmpeg-mux helper process) — poll
     * obs_output_active() until it clears, same bounded-wait pattern as
     * rewind_save_clip()'s poll on get_last_replay. */
    for (int i = 0; i < 100 && obs_output_active(g_recording); i++) {
        os_sleep_ms(50);
    }
    if (obs_output_active(g_recording)) {
        set_error("timed out waiting for recording to stop");
        return NULL;
    }
    set_error("");
    return g_recording_path;
}

int rewind_set_buffer_seconds(int seconds) {
    if (!g_initialized) return fail("not initialized");
    if (seconds <= 0) { set_error("invalid buffer length"); return 2; }
    g_seconds = seconds;
    obs_data_t *s = obs_data_create();
    obs_data_set_int(s, "max_time_sec", seconds);
    obs_output_update(g_replay, s);
    obs_data_release(s);
    set_error("");
    return 0;
}

int rewind_obs_shutdown(void) {
    if (!g_initialized) return 0;
    if (g_replay && obs_output_active(g_replay)) obs_output_stop(g_replay);
    if (g_recording && obs_output_active(g_recording)) {
        obs_output_stop(g_recording);
        /* Unlike the replay buffer (whose stop writes nothing), the
         * recording output is mid-file: the ffmpeg muxer must flush its
         * trailer/moov atom or the mp4 is corrupt and unplayable. Wait it
         * out, same bounded poll as rewind_stop_recording(). */
        for (int i = 0; i < 100 && obs_output_active(g_recording); i++)
            os_sleep_ms(50);
    }
    obs_output_release(g_replay);     g_replay = NULL;
    obs_output_release(g_recording);  g_recording = NULL;
    obs_encoder_release(g_venc);    g_venc = NULL;
    obs_encoder_release(g_aenc);    g_aenc = NULL;
    obs_set_output_source(2, NULL);
    obs_source_release(g_mic);      g_mic = NULL;
    obs_set_output_source(1, NULL);
    obs_source_release(g_sysaudio); g_sysaudio = NULL;
    obs_set_output_source(0, NULL);
    obs_source_release(g_capture);  g_capture = NULL;
#ifdef _WIN32
    g_win_capture_kind = WIN_CAPTURE_NONE;
#endif
    obs_shutdown();
    g_initialized = 0;
    return 0;
}

int rewind_set_audio_mode(int mode) {
    /* 0 = off (silence, unless the mic is on), 1 = all desktop audio, 2 =
     * only the captured app's audio. Live on channel 1 (rebuild_system_audio
     * tears down/recreates); before init it just stores for the pipeline. */
    g_audio_mode = (mode == AUDIO_MODE_APP || mode == AUDIO_MODE_ALL)
                       ? mode
                       : AUDIO_MODE_OFF;
    if (g_initialized) rebuild_system_audio();
    set_error("");
    return 0;
}

int rewind_set_capture_quality(int fps, int max_height) {
    /* Store for the next init; a running pipeline can't change resolution/
     * fps without a full obs_reset_video (which would tear down the live
     * encoders/outputs), so this deliberately does NOT re-apply live — the
     * UI tells the user it takes effect on next launch. */
    g_fps = fps > 0 ? fps : 60;
    g_max_height = max_height > 0 ? max_height : 0;
    set_error("");
    return 0;
}

int rewind_set_mic_enabled(int enabled) {
    g_mic_enabled = enabled ? 1 : 0;

    /* Before init the preference is just remembered (applied by
     * rewind_obs_init); after init, create/tear down the mic source live. */
    if (!g_initialized) {
        set_error("");
        return 0;
    }
    if (g_mic_enabled && !g_mic) {
#ifdef __APPLE__
        g_mic = obs_source_create("coreaudio_input_capture", "rewind-mic", NULL, NULL);
#elif defined(_WIN32)
        obs_data_t *ms = obs_data_create();
        obs_data_set_string(ms, "device_id", "default");
        g_mic = obs_source_create("wasapi_input_capture", "rewind-mic", ms, NULL);
        obs_data_release(ms);
#endif
        if (!g_mic) return fail("microphone source failed (permission not granted?)");
        obs_set_output_source(2, g_mic);
    } else if (!g_mic_enabled && g_mic) {
        obs_set_output_source(2, NULL);
        obs_source_release(g_mic);
        g_mic = NULL;
    }
    set_error("");
    return 0;
}

int rewind_list_displays(char *json_out, int json_cap) {
    return list_displays_json(json_out, json_cap);
}

int rewind_set_capture_display(const char *display_uuid) {
    if (!display_uuid) return fail("display_uuid is NULL");

    /* Windows stores a "monitor_id" device-id string here instead of a
     * ScreenCaptureKit display UUID (see the Windows display-helpers
     * comment above) — same buffer, different string contents per
     * platform, no Dart-visible difference (still opaque to callers). */
    snprintf(g_display_uuid, sizeof(g_display_uuid), "%s", display_uuid);

#ifdef __APPLE__
    /* If the capture source already exists, reconfigure it in place —
     * screen_capture's own .update callback (sck_video_capture_update,
     * plugins/mac-capture/mac-sck-video-capture.m) tears down and
     * re-initialises its stream for the new display_uuid, so
     * obs_source_update() is enough; the source does not need to be
     * recreated. */
    if (g_capture) {
        obs_data_t *cs = obs_data_create();
        obs_data_set_string(cs, "display_uuid", g_display_uuid);
        obs_source_update(g_capture, cs);
        obs_data_release(cs);
    }
#elif defined(_WIN32)
    if (g_initialized) rebuild_video_capture();
#endif
    set_error("");
    return 0;
}

int rewind_list_capturable_apps(char *json_out, int json_cap) {
    return list_capturable_apps_json(json_out, json_cap);
}

int rewind_set_capture_app(const char *bundle_id) {
    /* Windows stores the opaque "title:class:exe" window token here instead
     * of a bundle id (Windows has none — see the Windows display/window-
     * helpers comment above); still just an opaque round-tripped string as
     * far as this setter and the Dart side are concerned. */
    snprintf(g_app_bundle_id, sizeof(g_app_bundle_id), "%s", bundle_id ? bundle_id : "");
    /* Any app/display choice supersedes a one-off window target — the
     * revert path (auto-switch ending, user re-picking a source) calls
     * this, and a stale dead window id must not keep winning. */
    g_window_id = 0;

#ifdef __APPLE__
    /* Same update-not-recreate approach as rewind_set_capture_display()
     * above: sck_video_capture_update() (mac-sck-video-capture.m) tears
     * down and re-initialises its SCStream whenever "type" differs from
     * the source's current type (or "application" differs while already
     * in application mode), so obs_source_update() is enough — no need to
     * recreate g_capture. obs_source_update() merges (obs_data_apply) the
     * keys given here into the source's PERSISTENT settings rather than
     * replacing them wholesale (see libobs/obs-source.c), so display_uuid
     * set by a previous rewind_set_capture_display — or the main-display
     * default rewind_obs_init() baked in at source creation — is retained
     * even though this call doesn't resend it; that's required for
     * ScreenCaptureApplicationStream to resolve a target display (see
     * rewind_obs_init's comment on the same point). */
    if (g_capture) {
        obs_data_t *cs = obs_data_create();
        if (g_app_bundle_id[0]) {
            obs_data_set_int(cs, "type", 2); /* ScreenCaptureApplicationStream */
            obs_data_set_string(cs, "application", g_app_bundle_id);
        } else {
            obs_data_set_int(cs, "type", 0); /* ScreenCaptureDisplayStream */
        }
        obs_source_update(g_capture, cs);
        obs_data_release(cs);
    }
#elif defined(_WIN32)
    /* Switching to/from an app target may mean switching source ids
     * (monitor_capture <-> window_capture) — see rebuild_video_capture(). */
    if (g_initialized) rebuild_video_capture();
#endif
    /* App-audio mode targets the captured app — follow the new app (or fall
     * back to silence if this cleared it). */
    if (g_initialized && g_audio_mode == AUDIO_MODE_APP) rebuild_system_audio();
    set_error("");
    return 0;
}

int rewind_set_capture_window(uint32_t window_id) {
    g_window_id = window_id;

#ifdef __APPLE__
    /* Same update-not-recreate approach as the display/app setters above:
     * sck_video_capture_update() re-initialises the SCStream when "type"
     * changes, or when "window" changes while already in window mode.
     * window_id == 0 reverts to whatever the remaining app/display state
     * selects. */
    if (g_capture) {
        obs_data_t *cs = obs_data_create();
        if (g_window_id != 0) {
            obs_data_set_int(cs, "type", 1); /* ScreenCaptureWindowStream */
            obs_data_set_int(cs, "window", (long long)g_window_id);
        } else if (g_app_bundle_id[0]) {
            obs_data_set_int(cs, "type", 2);
            obs_data_set_string(cs, "application", g_app_bundle_id);
        } else {
            obs_data_set_int(cs, "type", 0);
        }
        obs_source_update(g_capture, cs);
        obs_data_release(cs);
    }
#elif defined(_WIN32)
    /* window_id is an HWND here (see rewind_obs.h's doc — "window_id" from
     * rewind_list_capturable_apps on Windows is the HWND truncated to 32
     * bits). rebuild_video_capture() re-derives a live "title:class:exe"
     * token from it and may switch source ids (monitor_capture <->
     * window_capture). */
    if (g_initialized) rebuild_video_capture();
#endif
    set_error("");
    return 0;
}

#else /* !REWIND_USE_LIBOBS: self-contained stub */

int rewind_obs_init(const char *out_dir, int seconds) {
    (void)out_dir; (void)seconds;
    /* TODO(libobs):
     *   obs_startup(locale, module_config_path, NULL);
     *   obs_reset_video(&ovi);   // set base/output resolution, fps
     *   obs_reset_audio(&oai);
     *   create a display/screen-capture source:
     *     macOS  -> "screen_capture" (ScreenCaptureKit)
     *     Windows-> "monitor_capture"/"game_capture" (Windows Graphics Capture)
     *   create a hardware encoder (VideoToolbox / NVENC / AMF / x264 fallback)
     *   create a replay-buffer output configured for `seconds`.
     */
    g_initialized = 1;
    set_error("");
    return 0; /* stub success */
}

int rewind_start_buffer(void) {
    if (!g_initialized) { set_error("not initialized"); return 1; }
    /* TODO(libobs): obs_output_start(replay_buffer_output); */
    return 0;
}

const char *rewind_save_clip(const char *out_dir) {
    if (!g_initialized) { set_error("not initialized"); return NULL; }
    /* TODO(libobs):
     *   trigger the replay-buffer save (proc handler "save" on the output),
     *   then read back the "last_replay" path.
     * For now, synthesize a plausible path so the Dart side has something. */
    time_t t = time(NULL);
    snprintf(g_last_clip, sizeof(g_last_clip), "%s/rewind-%ld.mp4",
             out_dir ? out_dir : ".", (long)t);
    /* NOTE: stub does not actually create a file. */
    set_error("stub: libobs not linked; no file written");
    return g_last_clip;
}

int rewind_stop_buffer(void) {
    if (!g_initialized) { set_error("not initialized"); return 1; }
    /* TODO(libobs): obs_output_stop(replay_buffer_output); */
    return 0;
}

/* Stub state for rewind_start_recording/rewind_stop_recording — mirrors
 * rewind_save_clip's stub behavior: synthesizes a plausible path but writes
 * no file, so the Dart pipeline can be exercised end-to-end before libobs
 * is linked. */
static int  g_stub_recording = 0;
static char g_stub_recording_path[1024] = "";

int rewind_start_recording(const char *out_dir) {
    if (!g_initialized) { set_error("not initialized"); return 1; }
    if (g_stub_recording) { set_error("recording already in progress"); return 1; }
    /* TODO(libobs): create/reuse a second "ffmpeg_muxer" output sharing the
     * replay buffer's encoders and obs_output_start() it. */
    time_t t = time(NULL);
    snprintf(g_stub_recording_path, sizeof(g_stub_recording_path),
             "%s/rewind-rec-%ld.mp4", out_dir ? out_dir : ".", (long)t);
    g_stub_recording = 1;
    set_error("stub: libobs not linked; no file written");
    return 0;
}

const char *rewind_stop_recording(void) {
    if (!g_initialized || !g_stub_recording) {
        set_error("recording not in progress");
        return NULL;
    }
    /* TODO(libobs): obs_output_stop() the recording output and wait for it
     * to fully deactivate. */
    g_stub_recording = 0;
    set_error("");
    return g_stub_recording_path;
}

int rewind_obs_shutdown(void) {
    /* TODO(libobs): release sources/encoders/outputs; obs_shutdown(); */
    g_stub_recording = 0;
    g_initialized = 0;
    return 0;
}

int rewind_set_buffer_seconds(int seconds) {
    if (!g_initialized) { set_error("not initialized"); return 1; }
    if (seconds <= 0) { set_error("invalid buffer length"); return 2; }
    /* TODO(libobs): update the replay-buffer output settings
     *   (obs_data_set_int(settings, "max_time_sec", seconds); then
     *    obs_output_update(replay_buffer_output, settings)). */
    return 0;
}

/* Dependency-free literal (no CoreGraphics/platform APIs) so the stub stays
 * buildable everywhere, including Windows. */
static const char *k_stub_displays_json =
    "[{\"uuid\":\"stub-display\",\"width\":1920,\"height\":1080,\"main\":true}]";

static char g_stub_display_uuid[128] = "";

int rewind_list_displays(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) { set_error("invalid buffer"); return 1; }
    size_t needed = strlen(k_stub_displays_json) + 1;
    if (needed > (size_t)json_cap) { set_error("display list truncated"); return 1; }
    memcpy(json_out, k_stub_displays_json, needed);
    set_error("");
    return 0;
}

int rewind_set_capture_display(const char *display_uuid) {
    if (!display_uuid) { set_error("display_uuid is NULL"); return 1; }
    /* TODO(libobs): obs_source_update() the capture source's display_uuid. */
    snprintf(g_stub_display_uuid, sizeof(g_stub_display_uuid), "%s", display_uuid);
    set_error("");
    return 0;
}

/* Two fake apps, dependency-free (no CoreGraphics/libproc/CoreFoundation),
 * so the stub stays buildable everywhere, including Windows. */
static const char *k_stub_apps_json =
    "[{\"bundle_id\":\"com.rewind.stub.one\",\"name\":\"Stub App One\",\"pid\":1001},"
    "{\"bundle_id\":\"com.rewind.stub.two\",\"name\":\"Stub App Two\",\"pid\":1002}]";

static char g_stub_app_bundle_id[256] = "";

int rewind_list_capturable_apps(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) { set_error("invalid buffer"); return 1; }
    size_t needed = strlen(k_stub_apps_json) + 1;
    if (needed > (size_t)json_cap) { set_error("app list truncated"); return 1; }
    memcpy(json_out, k_stub_apps_json, needed);
    set_error("");
    return 0;
}

int rewind_set_capture_app(const char *bundle_id) {
    /* TODO(libobs): obs_source_update() the capture source's type +
     * "application" (or revert to display capture on NULL/""). */
    snprintf(g_stub_app_bundle_id, sizeof(g_stub_app_bundle_id), "%s", bundle_id ? bundle_id : "");
    set_error("");
    return 0;
}

int rewind_set_capture_window(uint32_t window_id) {
    (void)window_id;
    set_error("");
    return 0;
}

int rewind_set_mic_enabled(int enabled) {
    (void)enabled;
    set_error("");
    return 0;
}

int rewind_set_capture_quality(int fps, int max_height) {
    (void)fps; (void)max_height;
    set_error("");
    return 0;
}

int rewind_set_audio_mode(int mode) {
    (void)mode;
    set_error("");
    return 0;
}

#endif /* REWIND_USE_LIBOBS */
