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

#include <dlfcn.h>
#include <unistd.h>
#include <limits.h>
#include <stdint.h>
#include <mach-o/dyld.h>

#ifdef __APPLE__
#include <ApplicationServices/ApplicationServices.h>
#endif

static obs_source_t  *g_capture = NULL;
static obs_encoder_t *g_venc    = NULL;
static obs_encoder_t *g_aenc    = NULL;
static obs_output_t  *g_replay  = NULL;
static int             g_seconds = 30;

/* User's preferred capture display, as a "display_uuid" string (see
 * rewind_set_capture_display). Empty means "use the main display" — the
 * long-standing default computed by main_display_uuid() at init time. Can
 * be set before rewind_obs_init(); applied at init and, if the capture
 * source already exists, applied immediately via obs_source_update(). */
static char g_display_uuid[128] = "";

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
    return access(path, F_OK) == 0;
}

static int has_sdk_layout(const char *dir) {
    char probe[PATH_MAX];
    snprintf(probe, sizeof(probe), "%s/obs-plugins", dir);
    return path_exists(probe);
}

/* Resolves the absolute directory containing this shared library, via
 * dladdr on one of its own exported symbols. */
static int shim_own_dir(char *out, size_t out_size) {
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

/* Locates the libobs SDK directory. Tries, in order:
 *   1. REWIND_OBS_SDK_DIR, if the build defined it.
 *   2. "<shim dir>/../Resources/obs" — packaged .app layout if the shim
 *      ships as a flat dylib directly in Contents/Frameworks/, SDK bundled
 *      alongside under Contents/Resources/obs.
 *   3. "<shim dir>/../../../../Resources/obs" — same packaged .app layout,
 *      but for how Flutter's macOS toolchain actually wraps a compiled
 *      dart:ffi code asset: as a *nested* framework bundle
 *      (Contents/Frameworks/rewind_obs.framework/Versions/A/rewind_obs),
 *      not a flat dylib. From Versions/A, Contents is four levels up
 *      (A -> Versions -> rewind_obs.framework -> Frameworks -> Contents),
 *      so candidate 2 above resolves two levels short of Resources/obs.
 *      Discovered during Task 10's real `flutter build macos` bundling —
 *      see native/shim/README.md and .superpowers/sdd/task-10-report.md.
 *      Kept candidate 2 as well (costs nothing, covers a flat-layout
 *      toolchain change).
 *   4. Walking up from the shim's own directory looking for
 *      "native/third_party/obs" — covers `flutter run`/`flutter build
 *      macos` dev builds, whose build products stay nested under the repo
 *      root.
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
    snprintf(candidate, sizeof(candidate), "%s/../Resources/obs", dir);
    if (has_sdk_layout(candidate)) {
        if (!realpath(candidate, out)) snprintf(out, out_size, "%s", candidate);
        return 1;
    }

    snprintf(candidate, sizeof(candidate), "%s/../../../../Resources/obs", dir);
    if (has_sdk_layout(candidate)) {
        if (!realpath(candidate, out)) snprintf(out, out_size, "%s", candidate);
        return 1;
    }

    char ancestor[PATH_MAX];
    snprintf(ancestor, sizeof(ancestor), "%s", dir);
    for (int i = 0; i < 12; i++) {
        snprintf(candidate, sizeof(candidate), "%s/native/third_party/obs", ancestor);
        if (has_sdk_layout(candidate)) {
            snprintf(out, out_size, "%s", candidate);
            return 1;
        }
        char *slash = strrchr(ancestor, '/');
        if (!slash || slash == ancestor) break;
        *slash = '\0';
    }
    return 0;
}

/* ---- display helpers (macOS) ----------------------------------------- */

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
#endif

static void setup_module_paths(const char *sdk_dir) {
    char plugins_bin[PATH_MAX];
    char plugins_data[PATH_MAX];
    /* %module% is substituted by libobs per discovered module; bin must
     * mirror the real .plugin bundle layout (Contents/MacOS/<name>), data
     * uses the flat "data/obs-plugins/<name>/" layout fetch_libobs.sh
     * actually produces (independent template, not nested in the bundle). */
    snprintf(plugins_bin, sizeof(plugins_bin), "%s/obs-plugins/%%module%%.plugin/Contents/MacOS", sdk_dir);
    snprintf(plugins_data, sizeof(plugins_data), "%s/data/obs-plugins/%%module%%", sdk_dir);
    obs_add_module_path(plugins_bin, plugins_data);
}

/* Resolves an absolute, existing path to libobs-opengl.dylib. Tries, in
 * order (matching find_obs_sdk_dir()'s dev-tree-then-packaged shape):
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
 * `shim_dir` is the caller's already-resolved shim_own_dir() result (not
 * recomputed here). Returns 1 on success; on failure, sets a descriptive
 * error naming every path tried (does not overwrite it with a generic
 * message — the caller should just propagate the failure). */
static int find_graphics_module_path(const char *sdk_dir, const char *shim_dir, char *out, size_t out_size) {
    char a[PATH_MAX], b[PATH_MAX] = "", c[PATH_MAX] = "";

    snprintf(a, sizeof(a), "%s/lib/libobs-opengl.dylib", sdk_dir);
    if (path_exists(a)) { snprintf(out, out_size, "%s", a); return 1; }

    if (shim_dir && shim_dir[0]) {
        snprintf(b, sizeof(b), "%s/../../../libobs-opengl.dylib", shim_dir);
        if (path_exists(b)) {
            if (!realpath(b, out)) snprintf(out, out_size, "%s", b);
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

int rewind_obs_init(const char *out_dir, int seconds) {
    if (g_initialized) return 0;
    g_seconds = seconds > 0 ? seconds : 30;

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

    char sdk_dir[PATH_MAX];
    if (!find_obs_sdk_dir(sdk_dir, sizeof(sdk_dir)))
        return fail("could not locate the libobs SDK (obs-plugins/data) relative to the shim; "
                     "see native/shim/README.md");

    if (!obs_startup("en-US", NULL, NULL)) return fail("obs_startup failed");

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

    struct obs_video_info ovi = {
        .graphics_module = graphics_module,
        .fps_num = 60, .fps_den = 1,
        .base_width = width, .base_height = height,
        .output_width = width, .output_height = height,
        .output_format = VIDEO_FORMAT_NV12,
        .colorspace = VIDEO_CS_709, .range = VIDEO_RANGE_PARTIAL,
        .adapter = 0, .gpu_conversion = true, .scale_type = OBS_SCALE_BICUBIC,
    };
    if (obs_reset_video(&ovi) != OBS_VIDEO_SUCCESS) { set_error("obs_reset_video failed"); goto cleanup; }

    struct obs_audio_info oai = { .samples_per_sec = 48000, .speakers = SPEAKERS_STEREO };
    if (!obs_reset_audio(&oai)) { set_error("obs_reset_audio failed"); goto cleanup; }

    setup_module_paths(sdk_dir);
    obs_load_all_modules();
    obs_post_load_modules();

    /* ScreenCaptureKit display capture (mac-capture module, "screen_capture"
     * source id — registered when ScreenCaptureKit is available, which it
     * is on the macOS versions Rewind targets). */
    obs_data_t *cs = obs_data_create();
    obs_data_set_int(cs, "type", 0); /* ScreenCaptureDisplayStream */
    obs_data_set_bool(cs, "show_cursor", true);
    char uuid[128];
    if (g_display_uuid[0]) {
        snprintf(uuid, sizeof(uuid), "%s", g_display_uuid);
    } else {
        main_display_uuid(uuid, sizeof(uuid));
    }
    if (uuid[0]) obs_data_set_string(cs, "display_uuid", uuid);
    g_capture = obs_source_create("screen_capture", "rewind-display", cs, NULL);
    obs_data_release(cs);
    if (!g_capture) {
        set_error("screen_capture source failed (Screen Recording permission not granted?)");
        goto cleanup;
    }
    obs_set_output_source(0, g_capture);

    /* Encoders: VideoToolbox H.264 + CoreAudio AAC. NOTE: the VideoToolbox
     * encoder id is registered by the mac-videotoolbox plugin, which is a
     * SEPARATE module from mac-capture/obs-ffmpeg/coreaudio-encoder — see
     * native/shim/README.md and the task-9 report for why this currently
     * fails until that module is added to the fetched SDK. */
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
    if (g_capture) {
        obs_set_output_source(0, NULL);
        obs_source_release(g_capture);
        g_capture = NULL;
    }
    obs_shutdown();
    return 1;
}

/* obs-ffmpeg's replay buffer spawns the obs-ffmpeg-mux helper from the
 * directory of the MAIN executable; if it's absent, obs_output_start fails
 * with no last_error set. Check for it so the failure names its cause. */
static int mux_helper_present(void) {
    char path[PATH_MAX];
    uint32_t cap = sizeof(path);
    if (_NSGetExecutablePath(path, &cap) != 0) return -1;
    char *slash = strrchr(path, '/');
    if (!slash) return -1;
    snprintf(slash + 1, sizeof(path) - (size_t)(slash + 1 - path),
             "obs-ffmpeg-mux");
    return access(path, X_OK) == 0;
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
    obs_output_release(g_replay);   g_replay = NULL;
    obs_encoder_release(g_venc);    g_venc = NULL;
    obs_encoder_release(g_aenc);    g_aenc = NULL;
    obs_set_output_source(0, NULL);
    obs_source_release(g_capture);  g_capture = NULL;
    obs_shutdown();
    g_initialized = 0;
    return 0;
}

int rewind_list_displays(char *json_out, int json_cap) {
    return list_displays_json(json_out, json_cap);
}

int rewind_set_capture_display(const char *display_uuid) {
    if (!display_uuid) return fail("display_uuid is NULL");

    snprintf(g_display_uuid, sizeof(g_display_uuid), "%s", display_uuid);

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

int rewind_obs_shutdown(void) {
    /* TODO(libobs): release sources/encoders/outputs; obs_shutdown(); */
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

#endif /* REWIND_USE_LIBOBS */
