/*
 * rewind_obs.c — Rewind's C shim over libobs.
 *
 * SCAFFOLD: this file currently implements a self-contained STUB so the app
 * links and runs before libobs is wired in. Each function documents the real
 * libobs calls to make. Replace the stub bodies with the calls marked TODO.
 *
 * Build (once libobs is available), e.g. macOS:
 *   clang -shared -fPIC rewind_obs.c -o librewind_obs.dylib \
 *       -I<obs-studio>/libobs -L<obs-build>/libobs -lobs
 *
 * License: GPLv3.
 */
#include "rewind_obs.h"
#include <string.h>
#include <stdio.h>
#include <time.h>

/* When REWIND_USE_LIBOBS is defined at build time, include the real headers.
 *   #include <obs.h>
 *   #include <obs-frontend-api.h>   // or drive the replay output directly
 */

static char g_last_error[256] = "";
static char g_last_clip[1024] = "";
static int  g_initialized = 0;

static void set_error(const char *msg) {
    strncpy(g_last_error, msg ? msg : "", sizeof(g_last_error) - 1);
    g_last_error[sizeof(g_last_error) - 1] = '\0';
}

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

const char *rewind_last_error(void) {
    return g_last_error;
}
