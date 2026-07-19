/*
 * rewind_obs.c — Rewind's C shim over libobs: shared API layer + stub.
 *
 * Two implementations are selected at compile time:
 *
 *   - REWIND_USE_LIBOBS defined: the real libobs-backed implementation.
 *     This file holds only the platform-agnostic parts (the public API
 *     dispatch, shared mutable state, and shared helpers); every
 *     operation that actually differs per platform is declared in
 *     rewind_obs_internal.h as an `rw_plat_*` function and implemented
 *     once per backend file — rewind_obs_macos.c (macOS) and
 *     rewind_obs_windows.c (Windows), each compiled only for its own
 *     platform (see hook/build.dart). See native/shim/README.md for how
 *     the SDK is located and the pinned tag it targets, and
 *     rewind_obs_internal.h for the backend-seam design (a future
 *     rewind_obs_linux.c drops in as a third backend with zero changes
 *     needed here).
 *   - REWIND_USE_LIBOBS undefined: a self-contained STUB (the `#else`
 *     branch below) so the Flutter app links and runs before libobs is
 *     wired in / on platforms without a built SDK yet. `rewind_save_clip`
 *     returns a synthesized path so the Dart pipeline can be exercised
 *     end-to-end in "dev mode".
 *
 * Build, e.g. macOS real mode:
 *   clang -shared -fPIC rewind_obs.c rewind_obs_macos.c \
 *       -o librewind_obs.dylib \
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
int  g_initialized = 0;

void set_error(const char *msg) {
    strncpy(g_last_error, msg ? msg : "", sizeof(g_last_error) - 1);
    g_last_error[sizeof(g_last_error) - 1] = '\0';
}

const char *rewind_last_error(void) {
    return g_last_error;
}

/* ---- process CPU/RSS sampling (backs rewind_perf_stats_json) -------------
 *
 * Pure OS process-introspection, no libobs dependency, so it's usable from
 * BOTH the real and stub builds below (only the libobs frame counters
 * differ between them — this process's own resource usage is not a
 * function of whether a capture pipeline exists). Each platform's native
 * mechanism is used directly here via a plain host-OS #ifdef, rather than
 * through the rw_plat_* backend seam (rewind_obs_internal.h): that seam is
 * scoped to things that need obs.h and only exist in REWIND_USE_LIBOBS mode,
 * but this needs to run in stub builds too.
 */
#ifdef _WIN32
#include <windows.h>
#include <psapi.h>
#elif defined(__APPLE__)
#include <mach/mach.h>
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>
#else
#include <sys/resource.h>
#include <unistd.h>
#endif

/* Fills user/system CPU seconds accumulated by this process since it
 * started, and its current (not peak) resident set size in bytes.
 * Best-effort: any platform-API failure just leaves the corresponding
 * out-param at 0 rather than propagating an error — rewind_perf_stats_json
 * never fails hard, per its own doc comment. */
static void perf_process_stats(double *cpu_user_s, double *cpu_sys_s, long long *rss_bytes) {
    *cpu_user_s = 0;
    *cpu_sys_s = 0;
    *rss_bytes = 0;

#ifdef _WIN32
    FILETIME creation, exit_time, kernel, user;
    if (GetProcessTimes(GetCurrentProcess(), &creation, &exit_time, &kernel, &user)) {
        ULARGE_INTEGER k, u;
        k.LowPart = kernel.dwLowDateTime; k.HighPart = kernel.dwHighDateTime;
        u.LowPart = user.dwLowDateTime; u.HighPart = user.dwHighDateTime;
        /* FILETIME ticks are 100ns. */
        *cpu_sys_s = (double)k.QuadPart / 10000000.0;
        *cpu_user_s = (double)u.QuadPart / 10000000.0;
    }
    PROCESS_MEMORY_COUNTERS pmc;
    if (GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) {
        *rss_bytes = (long long)pmc.WorkingSetSize;
    }
#else
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) == 0) {
        /* ru_utime/ru_stime (timeval, cumulative user+sys CPU time) are
         * portable across macOS/Linux; ru_maxrss is deliberately NOT used
         * for RSS below — it's a peak (not current) value, and its unit
         * differs by platform (bytes on Darwin, KB on Linux). */
        *cpu_user_s = (double)ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6;
        *cpu_sys_s = (double)ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
    }
#ifdef __APPLE__
    struct rusage_info_v2 rui;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&rui) == 0) {
        *rss_bytes = (long long)rui.ri_resident_size;
    }
#else
    FILE *statm = fopen("/proc/self/statm", "r");
    if (statm) {
        long long size_pages = 0, resident_pages = 0;
        if (fscanf(statm, "%lld %lld", &size_pages, &resident_pages) == 2) {
            *rss_bytes = resident_pages * (long long)sysconf(_SC_PAGESIZE);
        }
        fclose(statm);
    }
#endif
#endif
}

#ifdef REWIND_USE_LIBOBS

/* The internal seam header is only meaningful in real (libobs) mode — its
 * extern state and rw_plat_* declarations are all obs-typed. Include it only
 * here so the stub build (and clangd's default stub-config analysis) doesn't
 * pull in a header it can't use. */
#include "rewind_obs_internal.h"

/* path_exists() below is the one place this shared file needs an OS file-
 * existence check; pull in just enough of a platform header for that (not
 * the platform's full capture/audio/encoder API surface, which stays
 * inside rewind_obs_<platform>.c). Pure OS-portability, not a backend-
 * selection wall — the same carve-out PATH_MAX uses in
 * rewind_obs_internal.h. */
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

/* ---- shared mutable state (declared extern in rewind_obs_internal.h;
 * read/written by both the API layer below and whichever platform backend
 * file is compiled in) ---- */

obs_source_t  *g_capture   = NULL;
obs_encoder_t *g_venc      = NULL;
obs_encoder_t *g_aenc      = NULL;
obs_output_t  *g_replay    = NULL;
int             g_seconds  = 30;

/* Internal scene wrapping g_capture on channel 0 — see rw_attach_capture()'s
 * doc comment below for why this exists (channel-0 sources on an obs_view
 * draw with no scale-to-fit at all, so once the canvas can be smaller than
 * the source's native captured size, a bare obs_set_output_source(0,
 * g_capture) would crop instead of scale). g_capture_scene is created lazily
 * on first attach and lives for the rest of the process; g_capture_item is
 * its one-and-only sceneitem, replaced (not mutated) every time the platform
 * backend swaps which source is being captured. */
static obs_scene_t     *g_capture_scene = NULL;
static obs_sceneitem_t *g_capture_item  = NULL;

/* Canvas size the capture scene item's bounds are stretched to fill — set
 * once in rewind_obs_init() right after out_w/out_h are computed (see the
 * obs_video_info setup below), read by every rw_attach_capture() call for
 * the lifetime of the pipeline (fixed until a fresh init). */
static uint32_t g_canvas_w = 0, g_canvas_h = 0;

/* Manual-recording output (see rewind_start_recording). Created lazily on
 * first use, shares g_venc/g_aenc with g_replay, and is reused across
 * subsequent start/stop cycles rather than recreated each time. */
obs_output_t  *g_recording      = NULL;
char            g_recording_path[1024] = "";

/* User's preferred capture display, as a "display_uuid" string (see
 * rewind_set_capture_display). Empty means "use the main display" — the
 * long-standing default computed by rw_plat_main_display_uuid() at init
 * time. Can be set before rewind_obs_init(); applied at init and, if the
 * capture source already exists, applied immediately. */
char g_display_uuid[128] = "";

/* User's preferred capture application, as a bundle id string (see
 * rewind_set_capture_app). Empty means "no app override" — fall back to
 * g_display_uuid / the main display, same as g_display_uuid's own default.
 * An app target takes precedence over a display target when both are set.
 * Can be set before rewind_obs_init(); applied at init and, if the capture
 * source already exists, applied immediately. */
char g_app_bundle_id[256] = "";

/* Specific window to capture (a CGWindowID from the app enumeration's
 * "window_id" field; see rewind_set_capture_window). 0 means "no window
 * override". Ephemeral by design — window ids die with their process, so
 * callers re-resolve via enumeration rather than persisting one. Takes
 * precedence over g_app_bundle_id, which itself beats plain display
 * capture. The ONLY way to capture a CrossOver/Wine game specifically:
 * those processes have no bundle id for application capture, but their
 * windows are ordinary CGWindows. */
uint32_t g_window_id = 0;

/* Capture quality (see rewind_set_capture_quality). Applied at init —
 * changing them needs a fresh init (the video pipeline + encoders are
 * built around them), so the setter only stores when already initialised;
 * the UI applies the change on next launch. g_fps: capture framerate.
 * g_max_height: output is downscaled to this height (aspect preserved)
 * when the display is taller; 0 = source resolution. */
int g_fps = 60;
int g_max_height = 0;

/* Audio sources. Channel 0 carries the (video-only) screen capture;
 * without explicit audio SOURCES every clip's AAC track encodes silence.
 * Channel 1: system/desktop audio — always created at init (see
 * rw_plat_rebuild_system_audio). Channel 2: the microphone, toggled by
 * rewind_set_mic_enabled. */
obs_source_t *g_sysaudio = NULL;
obs_source_t *g_mic = NULL;
int g_mic_enabled = 0; /* preference; applied at init if set early */

/* Preferred microphone device uid (see rewind_set_mic_device), "" = system
 * default ("default" device_id, per platform). */
char g_mic_device_uid[256] = "";

/* Microphone recording-level multiplier (see rewind_set_mic_volume), applied
 * via obs_source_set_volume; 1.0 = unity gain (100%). */
float g_mic_volume = 1.0f;

/* Live mic-monitoring on/off (see rewind_set_mic_monitoring's doc — stored
 * and re-applied to every mic source (re)create like g_mic_volume, but
 * force-cleared at every point a mic source is released as a safety net). */
int g_mic_monitoring = 0;

/* Set once obs_set_audio_monitoring_device has been called (rewind_set_mic_
 * monitoring's first-ever enable) — a process-wide libobs setting, not
 * per-source, so it only needs setting once. */
int g_monitoring_device_set = 0;

/* System/app audio mode (see rewind_set_audio_mode): 0 = off, 1 = all
 * desktop audio (every app), 2 = only the captured app's audio. Default 1. */
int g_audio_mode = AUDIO_MODE_ALL;

/* Game/desktop-audio recording-level multiplier (see rewind_set_game_
 * volume), applied via obs_source_set_volume to g_sysaudio; 1.0 = unity
 * gain (100%), mirroring g_mic_volume's own doc above. Unlike g_mic_volume
 * this needs no extern seam in rewind_obs_internal.h: every (re)create of
 * g_sysaudio goes through rw_plat_rebuild_system_audio(), but every CALLER
 * of that function already lives in this same file (rewind_obs_init,
 * rewind_set_audio_mode, rewind_set_capture_app's app-mode branch) — see
 * rw_apply_game_volume(), called right after each of those three call
 * sites, the same discipline rw_apply_mic_prefs uses for the mic. */
static float g_game_volume = 1.0f;

/* Mic auto-leveling (see rewind_set_mic_leveling): a compressor->limiter
 * filter chain attached to the mic source, default ON. g_mic_compressor/
 * g_mic_limiter are non-owning pointers once attached: obs_source_filter_
 * add() takes its own ref (see rw_attach_mic_leveling below), so ownership
 * lives with the mic source's filter list from that point on, and
 * obs_source_filter_remove() (rw_release_mic_leveling) is what actually
 * drops that ref — this file must never obs_source_release() them again.
 * Both NULL whenever nothing is currently attached (leveling off, or no mic
 * source exists yet); rw_attach_mic_leveling/rw_release_mic_leveling are
 * idempotent on that state, so every call site can call them
 * unconditionally. */
static int g_mic_leveling = 1;
static obs_source_t *g_mic_compressor = NULL;
static obs_source_t *g_mic_limiter = NULL;

int fail(const char *msg) { set_error(msg); return 1; }

/* ---- SDK / module path discovery -----------------------------------
 *
 * The fetched SDK (tools/fetch_libobs.sh, see native/third_party/obs/)
 * lays out:
 *   <sdk>/include, <sdk>/lib (libobs.framework + libobs-opengl.dylib +
 *   FFmpeg/x264/mbedTLS runtime dylibs), <sdk>/obs-plugins (*.plugin
 *   bundles), <sdk>/data (libobs/ effects + obs-plugins/<name>/ locale).
 *
 * At runtime we need to find that <sdk> directory so we can point
 * obs_add_module_path() at obs-plugins/ + data/obs-plugins/, and load the
 * graphics module by absolute path (see rw_plat_find_graphics_module_path).
 * We never know <sdk> at compile time unless the build defines
 * REWIND_OBS_SDK_DIR, so we also fall back to locating it relative to
 * wherever this shared library itself was loaded from
 * (rw_plat_own_dir()).
 */

int path_exists(const char *path) {
#ifdef _WIN32
    DWORD attr = GetFileAttributesA(path);
    return attr != INVALID_FILE_ATTRIBUTES;
#else
    return access(path, F_OK) == 0;
#endif
}

int has_sdk_layout(const char *dir) {
    char probe[PATH_MAX];
    snprintf(probe, sizeof(probe), "%s/obs-plugins", dir);
    return path_exists(probe);
}

/* Appends `in` to `out` (caller-owned, `out_size` bytes, already
 * NUL-terminated), escaping the handful of characters that would break a
 * JSON string literal (quote, backslash, control chars — the latter
 * dropped rather than \u-escaped). Not a general-purpose JSON encoder;
 * sufficient for the app/bundle-id names this shim emits. Shared across
 * platforms (used by both the macOS and Windows enumeration branches). */
void json_escape_append(const char *in, char *out, size_t out_size) {
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

/* Locates the libobs SDK directory. Tries, in order:
 *   1. REWIND_OBS_SDK_DIR, if the build defined it.
 *   2. The platform's own packaged-app candidate location(s) — see
 *      rw_plat_sdk_dir_candidate()'s doc comment in each backend file
 *      (macOS: one or two Resources/obs candidates relative to the shim's
 *      own nested-framework or flat placement; Windows: the shim's own
 *      directory, since bundling drops the SDK flat beside it).
 *   3. Walking up from the shim's own directory looking for
 *      "native/third_party/obs" — covers `flutter run`/`flutter build
 *      {macos,windows}` dev builds, whose build products stay nested under
 *      the repo root.
 * Returns 1 on success (out holds the SDK dir, no trailing slash). */
int find_obs_sdk_dir(char *out, size_t out_size) {
#ifdef REWIND_OBS_SDK_DIR
    if (has_sdk_layout(REWIND_OBS_SDK_DIR)) {
        snprintf(out, out_size, "%s", REWIND_OBS_SDK_DIR);
        return 1;
    }
#endif
    char dir[PATH_MAX];
    if (!rw_plat_own_dir(dir, sizeof(dir))) return 0;

    if (rw_plat_sdk_dir_candidate(dir, out, out_size)) return 1;

    char ancestor[PATH_MAX];
    char candidate[PATH_MAX];
    snprintf(ancestor, sizeof(ancestor), "%s", dir);
    for (int i = 0; i < 12; i++) {
        snprintf(candidate, sizeof(candidate), "%s/native/third_party/obs", ancestor);
        if (has_sdk_layout(candidate)) {
            snprintf(out, out_size, "%s", candidate);
            return 1;
        }
        char *slash = strrchr(ancestor, '/');
#ifdef _WIN32
        /* rw_plat_own_dir() returns a backslash-separated Windows path;
         * accept either separator when walking up ancestors. */
        char *bslash = strrchr(ancestor, '\\');
        if (bslash && (!slash || bslash > slash)) slash = bslash;
#endif
        if (!slash || slash == ancestor) break;
        *slash = '\0';
    }
    return 0;
}

/* Creates and attaches the mic auto-leveling filter chain — a compressor
 * (evens out the envelope) followed by a limiter (catches whatever peaks
 * through) — to `mic`, if g_mic_leveling is on and nothing is attached yet.
 * Filter ids/setting keys verified against the vendored source: compressor_
 * filter's ratio/threshold/attack_time/release_time/output_gain
 * (native/third_party/work/obs-studio/plugins/obs-filters/compressor-
 * filter.c) and limiter_filter's threshold/release_time (limiter-filter.c
 * in the same directory).
 *
 * ADD ORDER MATTERS: obs_source_filter_add() inserts each new filter at
 * index 0 of source->filters (see obs-source.c), but audio actually runs
 * from the HIGHEST index down to 0 (filter_async_audio's `for (i =
 * source->filters.num; i > 0; i--)`), so the filter added FIRST ends up
 * with the highest index and therefore runs FIRST. Adding the compressor
 * before the limiter (as done below) is what makes the signal hit the
 * compressor, then the limiter — not the reverse.
 *
 * Private sources (obs_source_create_private): these are pipeline-internal
 * and never meant to be user-visible/enumerable, the same reasoning
 * obs_source_duplicate's own duplicate_filter() helper uses for
 * programmatically-attached filters.
 *
 * Idempotent: a second call with filters already attached (e.g. from both
 * rewind_set_mic_leveling(1) and rw_apply_mic_prefs on the same mic source)
 * is a no-op — g_mic_compressor/g_mic_limiter are always cleared by
 * rw_release_mic_leveling before a new mic source is built (see every
 * mic-teardown call site below), so this only ever fires once per live mic
 * source. */
static void rw_attach_mic_leveling(obs_source_t *mic) {
    if (!mic || !g_mic_leveling) return;
    if (g_mic_compressor || g_mic_limiter) return;

    obs_data_t *cs = obs_data_create();
    obs_data_set_double(cs, "ratio", 4.0);
    obs_data_set_double(cs, "threshold", -18.0);
    obs_data_set_int(cs, "attack_time", 6);
    obs_data_set_int(cs, "release_time", 60);
    /* No makeup gain: with any boost here the mic sits above the game mix
     * regardless of the user's mic slider (measured +6 dB pushed clips to
     * 0.1 dBFS true peak). The chain only tames peaks; the slider sets level. */
    obs_data_set_double(cs, "output_gain", 0.0);
    g_mic_compressor = obs_source_create_private("compressor_filter", "rewind-mic-compressor", cs);
    obs_data_release(cs);
    if (g_mic_compressor) {
        obs_source_filter_add(mic, g_mic_compressor);
        /* filter_add() took its own ref (obs_source_get_ref internally) —
         * release the creation ref the same way obs_source_duplicate's
         * duplicate_filter() does. g_mic_compressor stays a valid pointer,
         * now kept alive by the filter-list ref until rw_release_mic_
         * leveling's obs_source_filter_remove() drops it — this file must
         * not release it again. */
        obs_source_release(g_mic_compressor);
    } else {
        blog(LOG_WARNING, "rewind: compressor_filter unavailable; mic auto-leveling skipped");
    }

    obs_data_t *ls = obs_data_create();
    obs_data_set_double(ls, "threshold", -6.0);
    obs_data_set_int(ls, "release_time", 60);
    g_mic_limiter = obs_source_create_private("limiter_filter", "rewind-mic-limiter", ls);
    obs_data_release(ls);
    if (g_mic_limiter) {
        obs_source_filter_add(mic, g_mic_limiter);
        obs_source_release(g_mic_limiter);
    } else {
        blog(LOG_WARNING, "rewind: limiter_filter unavailable; mic auto-leveling incomplete");
    }
}

/* Removes+releases whatever of the auto-leveling filter chain is currently
 * attached to `mic` (see rw_attach_mic_leveling above) and clears the
 * stored pointers. MUST run before `mic` itself is released on every
 * teardown path: obs_source_filter_remove() needs its filter's parent
 * source still alive (native/third_party/work/obs-studio/libobs/obs-
 * source.c) — it looks the filter up in the source's own filter list before
 * dropping the ref obs_source_filter_add() took, so calling this AFTER
 * obs_source_release(mic) would operate on a source already torn down.
 * Called from every rewind_obs.c site that releases g_mic
 * (rewind_obs_init's failure cleanup, rewind_obs_shutdown,
 * rewind_set_mic_enabled's disable path, rewind_set_mic_device's rebuild),
 * mirroring the existing "stop monitoring on the outgoing source" safety
 * net at those same sites. Safe to call with `mic` NULL or with nothing
 * attached (both branches are individually NULL-guarded). */
static void rw_release_mic_leveling(obs_source_t *mic) {
    if (mic && g_mic_limiter) obs_source_filter_remove(mic, g_mic_limiter);
    g_mic_limiter = NULL;
    if (mic && g_mic_compressor) obs_source_filter_remove(mic, g_mic_compressor);
    g_mic_compressor = NULL;
}

/* Applies g_game_volume to g_sysaudio if it currently exists — called right
 * after every rw_plat_rebuild_system_audio() call (rewind_obs_init,
 * rewind_set_audio_mode, rewind_set_capture_app's app-mode branch), mirroring
 * rw_apply_mic_prefs's discipline for the mic. A no-op when g_sysaudio is
 * NULL (audio mode off, or app mode with no capture target set yet) —
 * nothing to apply to; rewind_set_game_volume itself still stores the
 * preference for whenever a desktop-audio source next exists. */
static void rw_apply_game_volume(void) {
    if (g_sysaudio) obs_source_set_volume(g_sysaudio, g_game_volume);
}

/* Applies the current mic-volume/monitoring/leveling preferences to `mic` —
 * called right after every (re)creation of the mic source (rewind_obs_init's
 * best-effort mic setup, rewind_set_mic_enabled's create path, and
 * rewind_set_mic_device's rebuild path), the same three call sites
 * rw_plat_create_mic_source() itself is called from. Mirrors how
 * g_mic_device_uid is threaded through that function; volume/monitoring
 * don't need a per-platform rw_plat_* seam of their own since
 * obs_source_set_volume/obs_source_set_monitoring_type are plain obs.h
 * calls, not platform-specific. */
static void rw_apply_mic_prefs(obs_source_t *mic) {
    if (!mic) return;
    obs_source_set_volume(mic, g_mic_volume);
    if (g_mic_monitoring) {
        if (!g_monitoring_device_set) {
            /* "Default"/"default" are the exact literal name/id obs_startup
             * itself seeds audio.monitoring_device_name/_id with (see
             * init_audio() in native/third_party/work/obs-studio/libobs/
             * obs.c) — asserting them explicitly here rather than relying on
             * that default is what rewind_set_mic_monitoring's doc promises
             * ("call obs_set_audio_monitoring_device for the default device
             * once before first enable"). "default" is also the literal
             * audio-monitoring/osx/coreaudio-output.c's audio_monitor_init
             * special-cases to mean "the OS's current default output
             * device" (skips setting an explicit CFString device on the
             * AudioQueue) rather than a specific device id. */
            obs_set_audio_monitoring_device("Default", "default");
            g_monitoring_device_set = 1;
        }
        obs_source_set_monitoring_type(mic, OBS_MONITORING_TYPE_MONITOR_ONLY);
    }
    rw_attach_mic_leveling(mic);
}

/* Attaches `capture` (the platform's current g_capture, or NULL to detach)
 * as the sole item of an internal scene kept permanently on channel 0.
 *
 * WHY A SCENE AT ALL: a source placed directly on an obs_view channel (the
 * pre-task-19 design — obs_set_output_source(0, g_capture)) draws with NO
 * scale-to-fit. obs_view_render()/render_main_texture() (libobs/obs-view.c,
 * libobs/obs-video.c) apply no transform whatsoever before calling
 * obs_source_video_render(); a capture source builds its draw quad from its
 * own native captured pixel size (e.g. mac-capture's
 * dc->frame.size in mac-display-capture.m) regardless of the canvas size.
 * So once base_width/base_height can be smaller than the source's native
 * size (see this task's change to the obs_video_info below), a bare
 * channel-0 attach would CROP the frame to the canvas's top-left corner,
 * not scale it down. A scene item has its own draw_transform/bounds and can
 * be told to fill a smaller canvas properly (verified by reading
 * libobs/obs-scene.c's render_item/update_item_transform).
 *
 * WHY scale_filter STAYS OBS_SCALE_DISABLE (the default — do not "improve"
 * this to BICUBIC/LANCZOS): obs-scene.c's render_item() only takes the
 * multi-tap kernel path when item_texture_enabled() is true for the item,
 * which happens for any non-DISABLE scale_filter. That forces libobs to
 * first render the source into an intermediate `item_render` texture sized
 * via calc_cx/calc_cy — which only subtracts crop, i.e. the texture is
 * allocated at the source's FULL NATIVE RESOLUTION — and only then runs the
 * multi-tap downscale from that intermediate texture onto the canvas. That
 * reintroduces exactly the full-native-resolution render this task exists
 * to eliminate (see CHANGELOG), canceling the perf win. Leaving
 * scale_filter DISABLE instead draws the source straight into the (already
 * small) canvas viewport in one pass, geometrically scaled via the item's
 * draw_transform and sampled with the source's own filter (bilinear, no
 * mipmaps) — a single cheap pass, no intermediate texture. Accepted
 * tradeoff: bilinear minification instead of a genuine multi-tap bicubic
 * downscale; mild at the ~1.8x reduction ratios g_max_height typically
 * produces in practice.
 *
 * Bounds are OBS_BOUNDS_STRETCH sized to g_canvas_w/g_canvas_h (== out_w/
 * out_h, the canvas — see rewind_obs_init). When the display is uncapped,
 * g_canvas_w/h equal the source's own native size, so STRETCH is an
 * identity scale (harmless no-op), matching the "nothing changes when
 * g_max_height doesn't cap" requirement.
 */
void rw_attach_capture(obs_source_t *capture) {
    if (!g_capture_scene) {
        g_capture_scene = obs_scene_create("rewind-capture-scene");
        if (!g_capture_scene) return;
        obs_set_output_source(0, obs_scene_get_source(g_capture_scene));
    }
    if (g_capture_item) {
        obs_sceneitem_remove(g_capture_item);
        g_capture_item = NULL;
    }
    if (!capture) return;

    g_capture_item = obs_scene_add(g_capture_scene, capture);
    if (!g_capture_item) return;
    obs_sceneitem_set_bounds_type(g_capture_item, OBS_BOUNDS_STRETCH);
    struct vec2 bounds = { (float)g_canvas_w, (float)g_canvas_h };
    obs_sceneitem_set_bounds(g_capture_item, &bounds);
    /* scale_filter left at its OBS_SCALE_DISABLE default — see doc comment
     * above; do not set it to BICUBIC/LANCZOS/AREA. */
}

/* Tears down the capture scene entirely: detaches channel 0, drops the
 * sceneitem (releasing the scene's own ref on whatever g_capture currently
 * is), and releases the scene handle itself. Mirrors — and must run before —
 * the existing obs_source_release(g_capture) teardown at both call sites
 * (rewind_obs_init's failure cleanup and rewind_obs_shutdown), since g_capture
 * and the scene item hold independent refs on the same source (obs_scene_add
 * takes its own ref; it does not adopt the caller's). */
static void rw_release_capture_scene(void) {
    obs_set_output_source(0, NULL);
    if (!g_capture_scene) return;
    if (g_capture_item) {
        obs_sceneitem_remove(g_capture_item);
        g_capture_item = NULL;
    }
    obs_scene_release(g_capture_scene);
    g_capture_scene = NULL;
}

int rewind_obs_init(const char *out_dir, int seconds) {
    if (g_initialized) return 0;
    g_seconds = seconds > 0 ? seconds : 30;

    /* Platform capture-permission gate (Screen Recording TCC on macOS;
     * no-op on Windows, which has no equivalent runtime prompt). */
    int perm = rw_plat_check_permission();
    if (perm != 0) return perm;

    char sdk_dir[PATH_MAX];
    if (!find_obs_sdk_dir(sdk_dir, sizeof(sdk_dir)))
        return fail("could not locate the libobs SDK (obs-plugins/data) relative to the shim; "
                     "see native/shim/README.md");

    if (!obs_startup("en-US", NULL, NULL)) return fail("obs_startup failed");

    /* Windows needs its own data path registered before obs_reset_video()
     * loads libobs' core effects; macOS needs nothing here (its data
     * resolves via the libobs.framework's own bundled Resources/). See
     * rw_plat_pre_video_setup()'s doc comment in each backend file. */
    rw_plat_pre_video_setup(sdk_dir);

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
    rw_plat_query_main_display_size(&width, &height);

    /* graphics_module is passed straight to os_dlopen(), which for a bare
     * name (no path separators) relies on dyld's/the loader's default
     * search paths — our lib/ dir isn't on those. Pass an absolute path
     * instead so it resolves unambiguously regardless of environment.
     * Must outlive this function (obs_reset_video may not copy it), hence
     * static. */
    char shim_dir[PATH_MAX];
    if (!rw_plat_own_dir(shim_dir, sizeof(shim_dir))) shim_dir[0] = '\0';

    static char graphics_module[PATH_MAX];
    if (!rw_plat_find_graphics_module_path(sdk_dir, shim_dir, graphics_module, sizeof(graphics_module))) {
        /* rw_plat_find_graphics_module_path() already set a detailed error
         * naming every path it tried; don't clobber it with a generic one. */
        goto cleanup;
    }

    /* Output resolution: source unless g_max_height caps it, in which case
     * scale down preserving aspect ratio. Width is rounded down to a
     * multiple of 4, not just 2: obs_reset_video() (libobs/obs.c) always
     * masks ovi->output_width with 0xFFFFFFFC ("align to multiple-of-two and
     * SSE alignment sizes") internally, unconditionally, regardless of what
     * we pass — but it does NOT mask ovi->base_width. Rounding out_w to a
     * multiple of 4 here ourselves means base_width (unmasked) and the
     * output_width libobs actually ends up using (masked) come out
     * identical, so base==output below is a genuine exact 1:1 with no
     * residual scale — round to just an even number and the two would
     * silently drift apart by up to 2px post-mask (verified live: a
     * 3024-wide source capped to 1080h computed out_w=1662 when rounded to
     * even, but libobs's own "video settings reset" log then showed output
     * resolution 1660x1080 — a 2px mismatch against base_width=1662). */
    uint32_t out_w = width, out_h = height;
    if (g_max_height > 0 && height > (uint32_t)g_max_height) {
        out_h = (uint32_t)g_max_height;
        out_w = (uint32_t)((double)width * out_h / height + 0.5);
        out_w &= ~3u;
        if (out_w == 0) out_w = 4;
    }
    int fps = g_fps > 0 ? g_fps : 60;

    /* base_width/height (the canvas) == output_width/height, not the
     * source's native size: every frame at `fps` gets rendered onto the
     * canvas once per frame (render_main_texture), so a canvas sized to the
     * full Retina-native display when the output is capped smaller wastes
     * GPU bandwidth/thermal headroom rendering ~out_h/height² more pixels
     * than the encoder will ever see — pure per-frame waste competing with
     * whatever game is running, since the encoder was already hardware
     * (VideoToolbox H.264). Rendering the canvas AT output resolution
     * eliminates that full-res render target entirely; the canvas->output
     * stage (render_output_texture, still governed by scale_type below)
     * becomes a 1:1 no-op copy when base==output. The capture SOURCE keeps
     * delivering native-resolution frames unchanged (SCK/monitor/window
     * capture config is untouched — see rw_attach_capture()'s doc comment
     * for how the resulting source-bigger-than-canvas case is now scaled to
     * fit rather than cropped). When g_max_height doesn't cap (out_w/out_h
     * == width/height already), this is a no-op, same as before. */
    g_canvas_w = out_w;
    g_canvas_h = out_h;

    struct obs_video_info ovi = {
        .graphics_module = graphics_module,
        .fps_num = (uint32_t)fps, .fps_den = 1,
        .base_width = out_w, .base_height = out_h,
        .output_width = out_w, .output_height = out_h,
        .output_format = VIDEO_FORMAT_NV12,
        .colorspace = VIDEO_CS_709, .range = VIDEO_RANGE_PARTIAL,
        .adapter = 0, .gpu_conversion = true, .scale_type = OBS_SCALE_BICUBIC,
    };
    blog(LOG_INFO, "rewind: capture %ux%u @%dfps (canvas == output, source %ux%u)",
         out_w, out_h, fps, width, height);
    if (obs_reset_video(&ovi) != OBS_VIDEO_SUCCESS) { set_error("obs_reset_video failed"); goto cleanup; }

    struct obs_audio_info oai = { .samples_per_sec = 48000, .speakers = SPEAKERS_STEREO };
    if (!obs_reset_audio(&oai)) { set_error("obs_reset_audio failed"); goto cleanup; }

    rw_plat_setup_module_paths(sdk_dir);
    obs_load_all_modules();
    obs_post_load_modules();

    /* Video capture source (display/app/window, per platform — see
     * rw_plat_init_capture_source()'s doc comment in each backend file). */
    if (rw_plat_init_capture_source() != 0) goto cleanup;

    /* System/app audio on channel 1 (the video capture source on channel 0
     * carries video only — without an audio source a clip's AAC track is
     * silence). Built per g_audio_mode; see rw_plat_rebuild_system_audio(). */
    rw_plat_rebuild_system_audio();
    rw_apply_game_volume();

    /* Microphone, if the preference was set before init. */
    if (g_mic_enabled) {
        g_mic = rw_plat_create_mic_source();
        if (g_mic) { obs_set_output_source(2, g_mic); rw_apply_mic_prefs(g_mic); }
        else rw_plat_log_mic_unavailable();
    }

    /* Encoders: hardware H.264 (with a software fallback) + AAC — see
     * rw_plat_create_encoders()'s doc comment in each backend file. */
    if (rw_plat_create_encoders() != 0) goto cleanup;

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
        rw_release_mic_leveling(g_mic);
        obs_set_output_source(2, NULL);
        obs_source_release(g_mic);
        g_mic = NULL;
    }
    if (g_sysaudio) {
        obs_set_output_source(1, NULL);
        obs_source_release(g_sysaudio);
        g_sysaudio = NULL;
    }
    rw_release_capture_scene();
    if (g_capture) {
        obs_source_release(g_capture);
        g_capture = NULL;
    }
    rw_plat_reset_capture_state();
    obs_shutdown();
    return 1;
}

int rewind_start_buffer(void) {
    if (!g_initialized) return fail("not initialized");
    if (!obs_output_start(g_replay)) {
        const char *err = obs_output_get_last_error(g_replay);
        if (err && *err) return fail(err);
        if (rw_plat_mux_helper_present() == 0)
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

/* Idempotent by construction: after a successful rewind_obs_init(), g_capture
 * is always non-NULL until either this function or rewind_obs_shutdown()
 * clears it (rw_plat_init_capture_source() fails init outright otherwise —
 * see rewind_obs_init's `goto cleanup` on its non-zero return), so "already
 * suspended" is exactly "g_capture == NULL" — no separate flag needed.
 *
 * mac-capture's screen_capture source tears down its SCStream from its
 * .destroy callback: sck_video_capture_destroy() (mac-sck-video-capture.m)
 * calls destroy_screen_stream(), which does
 * `[sc->disp stopCaptureWithCompletionHandler:...]` — verified against the
 * vendored source at native/third_party/work/obs-studio/plugins/
 * mac-capture/mac-sck-video-capture.m. obs_source_release() below drives
 * that destroy once the scene's own ref (dropped by rw_attach_capture(NULL)
 * just above it) and this file's ref both reach zero, so releasing
 * g_capture is what actually stops the stream — not merely detaching it
 * from the scene. */
int rewind_capture_suspend(void) {
    if (!g_initialized || !g_capture) { set_error(""); return 0; }
    rw_attach_capture(NULL);
    obs_source_release(g_capture);
    g_capture = NULL;
    rw_plat_reset_capture_state();
    set_error("");
    return 0;
}

/* Idempotent by the same g_capture-NULL test as rewind_capture_suspend()
 * above. rw_plat_init_capture_source() is the exact function
 * rewind_obs_init() itself calls to create the capture source the first
 * time, so this recreates it from whatever g_display_uuid/g_app_bundle_id/
 * g_window_id currently hold — the existing platform rebuild path, not a
 * parallel one. */
int rewind_capture_resume(void) {
    if (!g_initialized || g_capture) { set_error(""); return 0; }
    return rw_plat_init_capture_source();
}

int rewind_start_recording(const char *out_dir) {
    if (!g_initialized) return fail("not initialized");
    if (!out_dir || !out_dir[0]) return fail("out_dir is required");
    if (g_recording && obs_output_active(g_recording))
        return fail("recording already in progress");

    /* A manual recording with the capture session suspended (see
     * rewind_capture_suspend) would record a black/empty source — resume it
     * implicitly first, the same "resume before recording starts" ordering
     * applyBufferPolicy already applies to the replay buffer. */
    if (!g_capture) {
        int rc = rewind_capture_resume();
        if (rc != 0) return rc;
    }

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
        if (rw_plat_mux_helper_present() == 0)
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
    /* A leaked "listen" toggle must not outlive the session — stop
     * monitoring on the outgoing mic source before release AND clear the
     * stored preference, so a later rewind_obs_init doesn't silently resume
     * monitoring on the next mic source built without a fresh explicit
     * rewind_set_mic_monitoring(1) call. */
    if (g_mic) obs_source_set_monitoring_type(g_mic, OBS_MONITORING_TYPE_NONE);
    g_mic_monitoring = 0;
    /* Same "must run before the source itself is released" rule as the
     * monitoring safety net above — see rw_release_mic_leveling's doc. */
    rw_release_mic_leveling(g_mic);
    obs_set_output_source(2, NULL);
    obs_source_release(g_mic);      g_mic = NULL;
    obs_set_output_source(1, NULL);
    obs_source_release(g_sysaudio); g_sysaudio = NULL;
    rw_release_capture_scene();
    obs_source_release(g_capture);  g_capture = NULL;
    rw_plat_reset_capture_state();
    obs_shutdown();
    g_initialized = 0;
    return 0;
}

int rewind_set_audio_mode(int mode) {
    /* 0 = off (silence, unless the mic is on), 1 = all desktop audio, 2 =
     * only the captured app's audio. Live on channel 1
     * (rw_plat_rebuild_system_audio tears down/recreates); before init it
     * just stores for the pipeline. */
    g_audio_mode = (mode == AUDIO_MODE_APP || mode == AUDIO_MODE_ALL)
                       ? mode
                       : AUDIO_MODE_OFF;
    if (g_initialized) {
        rw_plat_rebuild_system_audio();
        rw_apply_game_volume();
    }
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
        g_mic = rw_plat_create_mic_source();
        if (!g_mic) return fail("microphone source failed (permission not granted?)");
        obs_set_output_source(2, g_mic);
        rw_apply_mic_prefs(g_mic);
    } else if (!g_mic_enabled && g_mic) {
        /* Stop monitoring on the outgoing source before release — see
         * rewind_set_mic_monitoring's doc on this being a safety net
         * independent of whatever g_mic_monitoring itself is currently set
         * to (the Dart caller is expected to have already turned it off
         * explicitly, but this makes it unconditional). Same discipline for
         * the leveling filter chain — see rw_release_mic_leveling's doc on
         * why it must run before the release below. */
        obs_source_set_monitoring_type(g_mic, OBS_MONITORING_TYPE_NONE);
        rw_release_mic_leveling(g_mic);
        obs_set_output_source(2, NULL);
        obs_source_release(g_mic);
        g_mic = NULL;
    }
    set_error("");
    return 0;
}

int rewind_list_audio_inputs_json(char *json_out, int json_cap) {
    return rw_plat_list_audio_inputs_json(json_out, json_cap);
}

void rewind_set_mic_device(const char *uid_or_null) {
    snprintf(g_mic_device_uid, sizeof(g_mic_device_uid), "%s",
             (uid_or_null && uid_or_null[0]) ? uid_or_null : "");

    /* Before init, or while the mic is off, this is just a stored
     * preference — applied whenever rw_plat_create_mic_source is next
     * called (rewind_obs_init's best-effort mic setup, or
     * rewind_set_mic_enabled's create path). With the mic already live,
     * rebuild it on the new device now, mirroring rewind_set_mic_enabled's
     * own create path. */
    if (!g_mic) return;

    /* Safety net, same as rewind_set_mic_enabled's disable branch — stop
     * monitoring on the OUTGOING source, and release its leveling filters,
     * before it's released. */
    obs_source_set_monitoring_type(g_mic, OBS_MONITORING_TYPE_NONE);
    rw_release_mic_leveling(g_mic);
    obs_set_output_source(2, NULL);
    obs_source_release(g_mic);
    g_mic = rw_plat_create_mic_source();
    if (g_mic) { obs_set_output_source(2, g_mic); rw_apply_mic_prefs(g_mic); }
    else rw_plat_log_mic_unavailable();
    set_error("");
}

int rewind_set_mic_volume(float volume) {
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 2.0f) volume = 2.0f;
    g_mic_volume = volume;
    if (g_mic) obs_source_set_volume(g_mic, g_mic_volume);
    set_error("");
    return 0;
}

int rewind_set_mic_monitoring(int enabled) {
    g_mic_monitoring = enabled ? 1 : 0;
    if (!g_mic) { set_error(""); return 0; }
    if (g_mic_monitoring) {
        if (!g_monitoring_device_set) {
            obs_set_audio_monitoring_device("Default", "default");
            g_monitoring_device_set = 1;
        }
        obs_source_set_monitoring_type(g_mic, OBS_MONITORING_TYPE_MONITOR_ONLY);
    } else {
        obs_source_set_monitoring_type(g_mic, OBS_MONITORING_TYPE_NONE);
    }
    set_error("");
    return 0;
}

int rewind_set_game_volume(float volume) {
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 2.0f) volume = 2.0f;
    g_game_volume = volume;
    rw_apply_game_volume();
    set_error("");
    return 0;
}

int rewind_set_mic_leveling(int enabled) {
    g_mic_leveling = enabled ? 1 : 0;
    if (g_mic) {
        if (g_mic_leveling) rw_attach_mic_leveling(g_mic);
        else rw_release_mic_leveling(g_mic);
    }
    set_error("");
    return 0;
}

int rewind_list_displays(char *json_out, int json_cap) {
    return rw_plat_list_displays_json(json_out, json_cap);
}

int rewind_set_capture_display(const char *display_uuid) {
    if (!display_uuid) return fail("display_uuid is NULL");

    /* Windows stores a "monitor_id" device-id string here instead of a
     * ScreenCaptureKit display UUID — same buffer, different string
     * contents per platform, no Dart-visible difference (still opaque to
     * callers). */
    snprintf(g_display_uuid, sizeof(g_display_uuid), "%s", display_uuid);
    rw_plat_on_capture_display_changed();
    set_error("");
    return 0;
}

int rewind_list_capturable_apps(char *json_out, int json_cap) {
    return rw_plat_list_capturable_apps_json(json_out, json_cap);
}

int rewind_set_capture_app(const char *bundle_id) {
    /* Windows stores the opaque "title:class:exe" window token here instead
     * of a bundle id (Windows has none); still just an opaque round-tripped
     * string as far as this setter and the Dart side are concerned. */
    snprintf(g_app_bundle_id, sizeof(g_app_bundle_id), "%s", bundle_id ? bundle_id : "");
    /* Any app/display choice supersedes a one-off window target — the
     * revert path (auto-switch ending, user re-picking a source) calls
     * this, and a stale dead window id must not keep winning. */
    g_window_id = 0;

    rw_plat_on_capture_app_changed();

    /* App-audio mode targets the captured app — follow the new app (or fall
     * back to silence if this cleared it). */
    if (g_initialized && g_audio_mode == AUDIO_MODE_APP) {
        rw_plat_rebuild_system_audio();
        rw_apply_game_volume();
    }
    set_error("");
    return 0;
}

int rewind_set_capture_window(uint32_t window_id) {
    g_window_id = window_id;
    rw_plat_on_capture_window_changed();
    set_error("");
    return 0;
}

int rewind_preflight_screen_permission(void) {
    return rw_plat_preflight_screen_permission();
}

int rewind_request_screen_permission(void) {
    return rw_plat_request_screen_permission();
}

int rewind_perf_stats_json(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) { set_error("invalid buffer"); return 1; }

    double cpu_user_s, cpu_sys_s;
    long long rss_bytes;
    perf_process_stats(&cpu_user_s, &cpu_sys_s, &rss_bytes);

    /* Frame-health counters only mean anything once the pipeline exists;
     * zero otherwise (matches the doc comment in rewind_obs.h). */
    uint32_t obs_total = 0, obs_lagged = 0, vo_total = 0, vo_skipped = 0;
    double obs_render_avg_ms = -1.0;
    if (g_initialized) {
        obs_total = obs_get_total_frames();
        obs_lagged = obs_get_lagged_frames();
        video_t *vid = obs_get_video();
        if (vid) {
            vo_total = video_output_get_total_frames(vid);
            vo_skipped = video_output_get_skipped_frames(vid);
        }
        /* obs_get_average_frame_time_ns() is the compositor's per-frame
         * render cost — the direct measure of render-pipeline changes (e.g.
         * canvas-at-output-resolution above), unlike cpu_user_s/cpu_sys_s
         * which don't move for a GPU-side win. Only meaningful once a video
         * pipeline exists (same gate as the frame counters above); -1
         * otherwise, matching gpu_util_pct/thermal_state's "-1 =
         * unavailable" sentinel below rather than a bare 0 that could be
         * misread as "zero-cost render". */
        obs_render_avg_ms = (double)obs_get_average_frame_time_ns() / 1000000.0;
    }

    /* GPU utilization / thermal state are OS readings, independent of
     * whether the capture pipeline is running — see rw_plat_gpu_util_pct/
     * rw_plat_thermal_state's doc comments in rewind_obs_internal.h. Both
     * already return -1 on any platform/failure where they're unavailable. */
    int gpu_util_pct = rw_plat_gpu_util_pct();
    int thermal_state = rw_plat_thermal_state();

    int n = snprintf(json_out, (size_t)json_cap,
        "{\"cpu_user_s\":%.3f,\"cpu_sys_s\":%.3f,\"rss_bytes\":%lld,"
        "\"obs_total_frames\":%u,\"obs_lagged_frames\":%u,"
        "\"vo_total_frames\":%u,\"vo_skipped_frames\":%u,"
        "\"obs_render_avg_ms\":%.2f,\"gpu_util_pct\":%d,\"thermal_state\":%d}",
        cpu_user_s, cpu_sys_s, rss_bytes, obs_total, obs_lagged, vo_total, vo_skipped,
        obs_render_avg_ms, gpu_util_pct, thermal_state);
    if (n < 0 || n >= json_cap) { set_error("perf stats truncated"); return 1; }
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

/* No capture-source concept exists in stub mode (see the file's top-of-file
 * doc) — both calls are pure no-ops, mirroring every other stub setter. */
int rewind_capture_suspend(void) {
    set_error("");
    return 0;
}

int rewind_capture_resume(void) {
    set_error("");
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

/* Dependency-free literal, mirroring k_stub_displays_json/k_stub_apps_json
 * above — an honest empty list (no libobs backend to enumerate against),
 * not a fake device. */
static const char *k_stub_audio_inputs_json = "[]";

int rewind_list_audio_inputs_json(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) { set_error("invalid buffer"); return 1; }
    size_t needed = strlen(k_stub_audio_inputs_json) + 1;
    if (needed > (size_t)json_cap) { set_error("audio input list truncated"); return 1; }
    memcpy(json_out, k_stub_audio_inputs_json, needed);
    set_error("");
    return 0;
}

void rewind_set_mic_device(const char *uid_or_null) {
    (void)uid_or_null;
    set_error("");
}

int rewind_set_mic_volume(float volume) {
    (void)volume;
    set_error("");
    return 0;
}

int rewind_set_mic_monitoring(int enabled) {
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

int rewind_set_game_volume(float volume) {
    (void)volume;
    set_error("");
    return 0;
}

int rewind_set_mic_leveling(int enabled) {
    (void)enabled;
    set_error("");
    return 0;
}

/* No platform gate in stub mode (no libobs backend to ask) — always report
 * granted so dev builds without a fetched SDK still exercise the onboarding
 * "granted" path rather than getting stuck. */
int rewind_preflight_screen_permission(void) {
    return 1;
}

int rewind_request_screen_permission(void) {
    return 1;
}

/* CPU/RSS still come from the real OS (perf_process_stats is plain OS
 * process-introspection, no libobs involved) — the frame-health counters
 * and obs_render_avg_ms are libobs-specific and so are zeroed/-1 here (no
 * pipeline to ask); gpu_util_pct/thermal_state are -1 too — the stub build
 * has no rw_plat_* seam at all (rewind_obs_internal.h, whose extern
 * declarations back that seam, is only included in REWIND_USE_LIBOBS mode
 * above), not just an unavailable platform reading. */
int rewind_perf_stats_json(char *json_out, int json_cap) {
    if (!json_out || json_cap <= 0) { set_error("invalid buffer"); return 1; }

    double cpu_user_s, cpu_sys_s;
    long long rss_bytes;
    perf_process_stats(&cpu_user_s, &cpu_sys_s, &rss_bytes);

    int n = snprintf(json_out, (size_t)json_cap,
        "{\"cpu_user_s\":%.3f,\"cpu_sys_s\":%.3f,\"rss_bytes\":%lld,"
        "\"obs_total_frames\":0,\"obs_lagged_frames\":0,"
        "\"vo_total_frames\":0,\"vo_skipped_frames\":0,"
        "\"obs_render_avg_ms\":-1.00,\"gpu_util_pct\":-1,\"thermal_state\":-1}",
        cpu_user_s, cpu_sys_s, rss_bytes);
    if (n < 0 || n >= json_cap) { set_error("perf stats truncated"); return 1; }
    set_error("");
    return 0;
}

#endif /* REWIND_USE_LIBOBS */
