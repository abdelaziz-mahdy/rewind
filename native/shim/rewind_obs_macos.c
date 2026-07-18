/*
 * rewind_obs_macos.c — macOS libobs backend for Rewind's C shim.
 *
 * Implements every `rw_plat_*` function declared in rewind_obs_internal.h
 * for macOS: ScreenCaptureKit display/application/window capture, mac
 * audio (sck_audio_capture / coreaudio_input_capture), VideoToolbox H.264 +
 * CoreAudio AAC encoding, and the .app-bundle-relative SDK/module path
 * discovery. Compiled only when REWIND_USE_LIBOBS is defined and on
 * __APPLE__ (see hook/build.dart); the whole body is guarded so an
 * accidental compile on any other configuration is a harmless empty
 * translation unit.
 *
 * Moved out of the single rewind_obs.c (see that file and
 * rewind_obs_internal.h for the shared layer / backend-seam design) as a
 * behavior-preserving refactor — every function here is the same logic,
 * same libobs calls, same order, same error strings as before the split.
 *
 * License: GPLv3.
 */
#if defined(REWIND_USE_LIBOBS) && defined(__APPLE__)

#include "rewind_obs.h"
#include "rewind_obs_internal.h"

#include <dlfcn.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <ApplicationServices/ApplicationServices.h>
#include <CoreAudio/CoreAudio.h> /* audio-input (microphone) enumeration */
#include <libproc.h>
#include <strings.h> /* strcasecmp */
#include <string.h>
#include <stdio.h>

/* ---- SDK / module path discovery -------------------------------------- */

/* Resolves the absolute directory containing this shared library: dladdr
 * on one of its own exported symbols, then realpath(). */
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

/* Packaged-app SDK candidates, tried in order:
 *   1. "<shim dir>/../Resources/obs" — packaged .app layout if the shim
 *      ships as a flat dylib directly in Contents/Frameworks/, SDK bundled
 *      alongside under Contents/Resources/obs.
 *   2. "<shim dir>/../../../../Resources/obs" — same packaged .app layout,
 *      but for how Flutter's macOS toolchain actually wraps a compiled
 *      dart:ffi code asset: as a *nested* framework bundle
 *      (Contents/Frameworks/rewind_obs.framework/Versions/A/rewind_obs),
 *      not a flat dylib. From Versions/A, Contents is four levels up
 *      (A -> Versions -> rewind_obs.framework -> Frameworks -> Contents),
 *      so candidate 1 above resolves two levels short of Resources/obs.
 *      Discovered during Task 10's real `flutter build macos` bundling —
 *      see native/shim/README.md and .superpowers/sdd/task-10-report.md.
 *      Kept candidate 1 as well (costs nothing, covers a flat-layout
 *      toolchain change).
 * Returns 1 on success (out holds the SDK dir, no trailing slash). */
int rw_plat_sdk_dir_candidate(const char *shim_dir, char *out, size_t out_size) {
    char candidate[PATH_MAX];

    snprintf(candidate, sizeof(candidate), "%s/../Resources/obs", shim_dir);
    if (has_sdk_layout(candidate)) {
        if (!rw_plat_realpath(candidate, out)) snprintf(out, out_size, "%s", candidate);
        return 1;
    }

    snprintf(candidate, sizeof(candidate), "%s/../../../../Resources/obs", shim_dir);
    if (has_sdk_layout(candidate)) {
        if (!rw_plat_realpath(candidate, out)) snprintf(out, out_size, "%s", candidate);
        return 1;
    }

    return 0;
}

/* %module% is substituted by libobs per discovered module. bin must mirror
 * the real .plugin bundle layout (Contents/MacOS/<name>), data uses the
 * flat "data/obs-plugins/<name>/" layout fetch_libobs.sh actually produces
 * (independent template, not nested in the bundle). */
void rw_plat_setup_module_paths(const char *sdk_dir) {
    char plugins_bin[PATH_MAX];
    char plugins_data[PATH_MAX];
    snprintf(plugins_bin, sizeof(plugins_bin), "%s/obs-plugins/%%module%%.plugin/Contents/MacOS", sdk_dir);
    snprintf(plugins_data, sizeof(plugins_data), "%s/data/obs-plugins/%%module%%", sdk_dir);
    obs_add_module_path(plugins_bin, plugins_data);
}

/* Resolves an absolute, existing path to libobs-opengl.dylib, the
 * graphics_module libobs should load for its render device. Tries, in
 * order (matching rw_plat_sdk_dir_candidate's dev-tree-then-packaged
 * shape):
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
 *       (insurance against a future toolchain change back to flat). */
int rw_plat_find_graphics_module_path(const char *sdk_dir, const char *shim_dir, char *out, size_t out_size) {
    char a[PATH_MAX], b[PATH_MAX] = "", c[PATH_MAX] = "";

    snprintf(a, sizeof(a), "%s/lib/libobs-opengl.dylib", sdk_dir);
    if (path_exists(a)) { snprintf(out, out_size, "%s", a); return 1; }

    if (shim_dir && shim_dir[0]) {
        snprintf(b, sizeof(b), "%s/../../../libobs-opengl.dylib", shim_dir);
        if (path_exists(b)) {
            if (!rw_plat_realpath(b, out)) snprintf(out, out_size, "%s", b);
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
}

/* ---- display + application/window enumeration ------------------------- */

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

void rw_plat_query_main_display_size(uint32_t *width, uint32_t *height) {
    query_main_display_size(width, height);
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

void rw_plat_main_display_uuid(char *out, size_t out_size) {
    main_display_uuid(out, out_size);
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
int rw_plat_list_displays_json(char *json_out, int json_cap) {
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
 * Pure CoreFoundation/libproc route (no ObjC, keeps this a single plain-C
 * translation unit): CGWindowListCopyWindowInfo gives every on-screen
 * window's owning pid (kCGWindowOwnerPID); proc_pidpath() (libproc, part of
 * libSystem — no extra framework) resolves that pid to its executable's
 * absolute path; walking up from the executable to the nearest ancestor
 * directory ending in ".app" gives the bundle root, which
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
int rw_plat_list_capturable_apps_json(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) return fail("invalid buffer");

    /* kCGWindowListOptionAll, NOT ...OnScreenOnly: macOS gives a fullscreen
     * app its OWN Space, and "on screen only" means "on the ACTIVE Space".
     * A game is almost always fullscreen (its own Space) or on a different
     * Space than Rewind, so the instant the user switches to Rewind to pick
     * it, the game's window is off the active Space and vanishes from the
     * list — the exact "my running game isn't in the picker" bug. Enumerating
     * ALL Spaces is what a capture-source picker needs; the layer==0 + >=64px
     * + bundle-id filters below still drop the extra off-screen/background
     * windows this option lets through. */
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
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

        /* Whether this window is on a display right now. With all-Spaces
         * enumeration (see the kCGWindowListOptionAll note above) the list
         * mixes visible and hidden/other-Space windows; the "follow the game"
         * auto-switch uses this to prefer the VISIBLE match — e.g. native
         * League's in-match window over its hidden client/lobby window, both
         * of which are named "League of Legends". */
        CFBooleanRef onscreen_ref =
            (CFBooleanRef)CFDictionaryGetValue(entry, kCGWindowIsOnscreen);
        int on_screen = onscreen_ref && CFBooleanGetValue(onscreen_ref);

        char escaped_id[256] = "";
        char escaped_name[512] = "";
        char escaped_icon[PATH_MAX * 2] = "";
        json_escape_append(bundle_id, escaped_id, sizeof(escaped_id));
        json_escape_append(name, escaped_name, sizeof(escaped_name));
        json_escape_append(icon, escaped_icon, sizeof(escaped_icon));

        APPEND("%s{\"bundle_id\":\"%s\",\"name\":\"%s\",\"pid\":%d,\"icon\":\"%s\","
               "\"window_id\":%u,\"on_screen\":%s}",
               first ? "" : ",", escaped_id, escaped_name, (int)pid, escaped_icon,
               (unsigned)window_id, on_screen ? "true" : "false");
        first = 0;
    }
    APPEND("]");
#undef APPEND

    CFRelease(windows);
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
 * sck_audio_capture (ScreenCaptureKit audio streams — desktop or a specific
 * application by bundle id). */
void rw_plat_rebuild_system_audio(void) {
    if (g_sysaudio) {
        obs_set_output_source(1, NULL);
        obs_source_release(g_sysaudio);
        g_sysaudio = NULL;
    }
    if (g_audio_mode == AUDIO_MODE_OFF) return;

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
}

/* Ask TCC directly instead of letting capture fail with a misleading
 * generic error later. CGRequestScreenCaptureAccess() shows the system
 * prompt the first time (subsequent calls are no-ops), so the user gets
 * the native dialog AND our banner explains the state precisely. */
int rw_plat_check_permission(void) {
    if (!CGPreflightScreenCaptureAccess()) {
        CGRequestScreenCaptureAccess();
        return fail("Screen Recording permission is not granted to this app. "
                    "Enable it under System Settings > Privacy & Security > "
                    "Screen Recording, then relaunch Rewind.");
    }
    return 0;
}

/* Pollable/on-demand variants for onboarding UI (see rewind_obs.h) — unlike
 * rw_plat_check_permission() above, these never fail the call; they just
 * report or request the grant state so the UI can poll it live. */
int rw_plat_preflight_screen_permission(void) {
    return CGPreflightScreenCaptureAccess() ? 1 : 0;
}

int rw_plat_request_screen_permission(void) {
    return CGRequestScreenCaptureAccess() ? 1 : 0;
}

/* Windows needs an explicit obs_add_data_path() call here (see the Windows
 * backend); macOS's find_libobs_data_file() always resolves against the
 * libobs.framework's own bundled Resources/, so nothing is needed. */
void rw_plat_pre_video_setup(const char *sdk_dir) {
    (void)sdk_dir;
}

/* ScreenCaptureKit display/application capture (mac-capture module,
 * "screen_capture" source id — registered when ScreenCaptureKit is
 * available, which it is on the macOS versions Rewind targets). */
int rw_plat_init_capture_source(void) {
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
        return fail("screen_capture source failed (Screen Recording permission not granted?)");
    }
    obs_set_output_source(0, g_capture);
    return 0;
}

/* Encoders: VideoToolbox H.264 + CoreAudio AAC. NOTE: the VideoToolbox
 * encoder id is registered by the mac-videotoolbox plugin, which is a
 * SEPARATE module from mac-capture/obs-ffmpeg/coreaudio-encoder — see
 * native/shim/README.md and the task-9 report for why this currently
 * fails until that module is added to the fetched SDK. */
int rw_plat_create_encoders(void) {
    obs_data_t *ve = obs_data_create();
    obs_data_set_int(ve, "bitrate", 12000);
    g_venc = obs_video_encoder_create(
        "com.apple.videotoolbox.videoencoder.ave.avc", "rewind-venc", ve, NULL);
    obs_data_release(ve);
    if (!g_venc) {
        return fail("VideoToolbox H.264 encoder unavailable (mac-videotoolbox module not loaded)");
    }
    obs_encoder_set_video(g_venc, obs_get_video());

    g_aenc = obs_audio_encoder_create("CoreAudio_AAC", "rewind-aenc", NULL, 0, NULL);
    if (!g_aenc) { return fail("CoreAudio AAC encoder unavailable"); }
    obs_encoder_set_audio(g_aenc, obs_get_audio());
    return 0;
}

/* "device_id" is coreaudio_input_capture's own settings key — verified
 * against the vendored plugin source
 * (native/third_party/work/obs-studio/plugins/mac-capture/mac-audio.c):
 * coreaudio_create()/coreaudio_update() read it via
 * obs_data_get_string(settings, "device_id"), coreaudio_defaults() defaults
 * it to the literal string "default", and find_device_id_by_uid() treats
 * "default" (case-insensitively) as "use kAudioHardwarePropertyDefault
 * InputDevice" — anything else is looked up by CoreAudio device UID via
 * coreaudio_get_device_id() (audio-device-enum.c), the exact same UID
 * rw_plat_list_audio_inputs_json below reads via
 * kAudioDevicePropertyDeviceUID. g_mic_device_uid empty means "use the
 * default" — pass the literal string only when a device was actually
 * chosen. */
obs_source_t *rw_plat_create_mic_source(void) {
    obs_data_t *ms = obs_data_create();
    obs_data_set_string(ms, "device_id",
                         g_mic_device_uid[0] ? g_mic_device_uid : "default");
    obs_source_t *mic = obs_source_create("coreaudio_input_capture", "rewind-mic", ms, NULL);
    obs_data_release(ms);
    return mic;
}

void rw_plat_log_mic_unavailable(void) {
    blog(LOG_WARNING, "rewind: coreaudio_input_capture unavailable (mic permission?)");
}

/* ---- microphone (audio input) enumeration (macOS) -----------------------
 *
 * Mirrors coreaudio_enum_devices()/coreaudio_properties() in the vendored
 * audio-device-enum.c/mac-audio.c: walk every id from
 * kAudioHardwarePropertyDevices, keep only those with at least one INPUT
 * stream (kAudioDevicePropertyStreams, scope Input — a non-zero size means
 * "has input streams", same test coreaudio_enum_device() uses), then read
 * each one's UID (kAudioDevicePropertyDeviceUID — the exact string
 * coreaudio_input_capture's "device_id" setting expects back) and display
 * name (kAudioDevicePropertyDeviceNameCFString). The system's current
 * default input device (kAudioHardwarePropertyDefaultInputDevice) is marked
 * with "default":true so the UI can pre-select it — separate from (but
 * consistent with) the shim's own g_mic_device_uid=="" meaning the same
 * thing to coreaudio_input_capture. */
int rw_plat_list_audio_inputs_json(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) return fail("invalid buffer");

    AudioObjectPropertyAddress devices_addr = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devices_addr, 0, NULL, &size) != noErr)
        return fail("AudioObjectGetPropertyDataSize failed");

    /* 128 comfortably covers any real machine's audio device count (built-in
     * + a handful of USB/Bluetooth/virtual devices); like the display/app
     * enumerations above, this is a soft cap, not a hard requirement. */
    AudioDeviceID ids[128];
    UInt32 count = size / sizeof(AudioDeviceID);
    if (count > 128) count = 128;
    size = count * sizeof(AudioDeviceID);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &devices_addr, 0, NULL, &size, ids) != noErr)
        return fail("AudioObjectGetPropertyData failed");

    /* Best-effort: a failure here just means no entry gets marked default,
     * not a failed enumeration overall. */
    AudioDeviceID default_id = kAudioObjectUnknown;
    AudioObjectPropertyAddress default_addr = {
        kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    UInt32 default_size = sizeof(default_id);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &default_addr, 0, NULL, &default_size, &default_id);

    size_t pos = 0;
    json_out[0] = '\0';
#define APPEND(...) do { \
        int n = snprintf(json_out + pos, (size_t)json_cap - pos, __VA_ARGS__); \
        if (n < 0 || (size_t)n >= (size_t)json_cap - pos) return fail("audio input list truncated"); \
        pos += (size_t)n; \
    } while (0)

    APPEND("[");
    int first = 1;
    for (UInt32 i = 0; i < count; i++) {
        AudioObjectPropertyAddress streams_addr = {
            kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput,
            kAudioObjectPropertyElementMain};
        UInt32 streams_size = 0;
        AudioObjectGetPropertyDataSize(ids[i], &streams_addr, 0, NULL, &streams_size);
        if (!streams_size) continue; /* no input streams -> not a mic */

        CFStringRef cf_uid = NULL;
        UInt32 uid_size = sizeof(cf_uid);
        AudioObjectPropertyAddress uid_addr = {
            kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};
        if (AudioObjectGetPropertyData(ids[i], &uid_addr, 0, NULL, &uid_size, &cf_uid) != noErr || !cf_uid)
            continue;

        char uid[256] = "";
        bool got_uid = CFStringGetCString(cf_uid, uid, sizeof(uid), kCFStringEncodingUTF8);
        CFRelease(cf_uid);
        if (!got_uid || !uid[0]) continue;

        CFStringRef cf_name = NULL;
        UInt32 name_size = sizeof(cf_name);
        AudioObjectPropertyAddress name_addr = {
            kAudioDevicePropertyDeviceNameCFString, kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};
        OSStatus name_stat = AudioObjectGetPropertyData(ids[i], &name_addr, 0, NULL, &name_size, &cf_name);

        char name[256] = "";
        if (name_stat == noErr && cf_name) {
            CFStringGetCString(cf_name, name, sizeof(name), kCFStringEncodingUTF8);
            CFRelease(cf_name);
        }
        if (!name[0]) snprintf(name, sizeof(name), "%s", uid);

        char esc_uid[512] = "";
        json_escape_append(uid, esc_uid, sizeof(esc_uid));
        char esc_name[512] = "";
        json_escape_append(name, esc_name, sizeof(esc_name));

        APPEND("%s{\"uid\":\"%s\",\"name\":\"%s\",\"default\":%s}",
               first ? "" : ",", esc_uid, esc_name,
               (ids[i] == default_id) ? "true" : "false");
        first = 0;
    }
    APPEND("]");
#undef APPEND
    set_error("");
    return 0;
}

/* obs-ffmpeg's replay buffer spawns the obs-ffmpeg-mux helper from the
 * directory of the MAIN executable; if it's absent, obs_output_start fails
 * with no last_error set. Check for it so the failure names its cause. */
int rw_plat_mux_helper_present(void) {
    char path[PATH_MAX];
    uint32_t cap = sizeof(path);
    if (_NSGetExecutablePath(path, &cap) != 0) return -1;
    char *slash = strrchr(path, '/');
    if (!slash) return -1;
    snprintf(slash + 1, sizeof(path) - (size_t)(slash + 1 - path),
             "obs-ffmpeg-mux");
    return access(path, X_OK) == 0;
}

/* If the capture source already exists, reconfigure it in place —
 * screen_capture's own .update callback (sck_video_capture_update,
 * plugins/mac-capture/mac-sck-video-capture.m) tears down and
 * re-initialises its stream for the new display_uuid, so
 * obs_source_update() is enough; the source does not need to be
 * recreated. */
void rw_plat_on_capture_display_changed(void) {
    if (g_capture) {
        obs_data_t *cs = obs_data_create();
        obs_data_set_string(cs, "display_uuid", g_display_uuid);
        obs_source_update(g_capture, cs);
        obs_data_release(cs);
    }
}

/* Same update-not-recreate approach as rw_plat_on_capture_display_changed()
 * above: sck_video_capture_update() (mac-sck-video-capture.m) tears down
 * and re-initialises its SCStream whenever "type" differs from the
 * source's current type (or "application" differs while already in
 * application mode), so obs_source_update() is enough — no need to
 * recreate g_capture. obs_source_update() merges (obs_data_apply) the
 * keys given here into the source's PERSISTENT settings rather than
 * replacing them wholesale (see libobs/obs-source.c), so display_uuid set
 * by a previous rewind_set_capture_display — or the main-display default
 * rewind_obs_init() baked in at source creation — is retained even though
 * this call doesn't resend it; that's required for
 * ScreenCaptureApplicationStream to resolve a target display (see
 * rw_plat_init_capture_source's comment on the same point). */
void rw_plat_on_capture_app_changed(void) {
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
}

/* Same update-not-recreate approach as the display/app setters above:
 * sck_video_capture_update() re-initialises the SCStream when "type"
 * changes, or when "window" changes while already in window mode.
 * window_id == 0 reverts to whatever the remaining app/display state
 * selects. */
void rw_plat_on_capture_window_changed(void) {
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
}

/* macOS keeps no capture-source state machine of its own (unlike Windows'
 * g_win_capture_kind) — nothing to reset. */
void rw_plat_reset_capture_state(void) {
}

#endif /* defined(REWIND_USE_LIBOBS) && defined(__APPLE__) */
