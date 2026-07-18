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

/* System/app audio mode (see rewind_set_audio_mode): 0 = off, 1 = all
 * desktop audio (every app), 2 = only the captured app's audio. Default 1. */
int g_audio_mode = AUDIO_MODE_ALL;

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

    /* Microphone, if the preference was set before init. */
    if (g_mic_enabled) {
        g_mic = rw_plat_create_mic_source();
        if (g_mic) obs_set_output_source(2, g_mic);
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
    obs_set_output_source(2, NULL);
    obs_source_release(g_mic);      g_mic = NULL;
    obs_set_output_source(1, NULL);
    obs_source_release(g_sysaudio); g_sysaudio = NULL;
    obs_set_output_source(0, NULL);
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
    if (g_initialized) rw_plat_rebuild_system_audio();
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
    } else if (!g_mic_enabled && g_mic) {
        obs_set_output_source(2, NULL);
        obs_source_release(g_mic);
        g_mic = NULL;
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
    if (g_initialized && g_audio_mode == AUDIO_MODE_APP) rw_plat_rebuild_system_audio();
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

/* No platform gate in stub mode (no libobs backend to ask) — always report
 * granted so dev builds without a fetched SDK still exercise the onboarding
 * "granted" path rather than getting stuck. */
int rewind_preflight_screen_permission(void) {
    return 1;
}

int rewind_request_screen_permission(void) {
    return 1;
}

#endif /* REWIND_USE_LIBOBS */
