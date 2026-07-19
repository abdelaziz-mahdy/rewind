/*
 * rewind_obs_internal.h — internal seam between rewind_obs.c (the shared API
 * layer + no-libobs stub) and the per-platform libobs backends
 * (rewind_obs_macos.c, rewind_obs_windows.c, and — eventually — a
 * rewind_obs_linux.c).
 *
 * NOT the public API: Dart only ever sees rewind_obs.h. This header exists
 * so the shared layer and the platform backends can talk to each other
 * without a single #ifdef __APPLE__/_WIN32 "backend selection" wall
 * anywhere in rewind_obs.c: every operation that differs by platform is
 * declared once here as an `rw_plat_*` function, implemented once per
 * backend file, and called unconditionally from the shared layer. Dropping
 * in a third backend (e.g. Linux) means writing a new rewind_obs_linux.c
 * that implements every `rw_plat_*` function below and adding it to
 * hook/build.dart's Linux branch — no changes needed to rewind_obs.c
 * itself.
 *
 * Everything in this file is only meaningful when REWIND_USE_LIBOBS is
 * defined; the no-libobs stub in rewind_obs.c doesn't touch any of it.
 *
 * License: GPLv3.
 */
#ifndef REWIND_OBS_INTERNAL_H
#define REWIND_OBS_INTERNAL_H

#ifdef REWIND_USE_LIBOBS

#include <obs.h>
#include <util/platform.h>
#include <stddef.h>
#include <stdint.h>

/* Portable PATH_MAX. The shared layer (this header + rewind_obs.c) never
 * includes <windows.h> directly — that stays inside rewind_obs_windows.c —
 * so on Windows PATH_MAX is hardcoded here to MAX_PATH's actual value (260)
 * instead of being pulled in transitively; rewind_obs_windows.c also
 * includes <windows.h> itself for its own use, whose own MAX_PATH is the
 * same numeric value, so nothing here changes behavior. */
#ifndef PATH_MAX
#ifdef _WIN32
#define PATH_MAX 260
#else
#include <limits.h>
#endif
#endif

/* ---- shared mutable state -----------------------------------------------
 *
 * Defined once in rewind_obs.c; read/written by both the API layer there
 * and by whichever platform backend file is compiled in. Same names, types
 * and initial values as the pre-split single-file version — this is purely
 * an extern seam, not a design change.
 */

extern obs_source_t  *g_capture;
extern obs_encoder_t *g_venc;
extern obs_encoder_t *g_aenc;
extern obs_output_t  *g_replay;
extern int             g_seconds;

/* Manual-recording output (see rewind_start_recording). */
extern obs_output_t  *g_recording;
extern char            g_recording_path[1024];

/* User's preferred capture display/app/window (see the rewind_set_capture_*
 * setters in rewind_obs.h). */
extern char g_display_uuid[128];
extern char g_app_bundle_id[256];
extern uint32_t g_window_id;

/* Capture quality (see rewind_set_capture_quality). */
extern int g_fps;
extern int g_max_height;

/* Audio sources + preferences (see rewind_set_mic_enabled/rewind_set_audio_mode). */
extern obs_source_t *g_sysaudio;
extern obs_source_t *g_mic;
extern int g_mic_enabled;

/* Preferred microphone device uid (see rewind_set_mic_device), "" = system
 * default. Consulted by rw_plat_create_mic_source, same way g_app_bundle_id
 * is consulted by the capture-source builders. */
extern char g_mic_device_uid[256];

#define AUDIO_MODE_OFF 0
#define AUDIO_MODE_ALL 1
#define AUDIO_MODE_APP 2
extern int g_audio_mode;

/* Set once rewind_obs_init() fully succeeds; cleared by
 * rewind_obs_shutdown() and by the init failure cleanup path. A few
 * platform setters (see rw_plat_on_capture_*_changed below) branch on this
 * directly, mirroring the pre-split code's own `if (g_initialized) ...`
 * checks verbatim. */
extern int g_initialized;

/* ---- shared helpers (defined in rewind_obs.c) ----------------------------
 */

/* Sets the message rewind_last_error() returns. */
void set_error(const char *msg);

/* set_error(msg) then return 1 — the "fail this call" idiom used
 * throughout both the shared layer and the platform backends. */
int fail(const char *msg);

int path_exists(const char *path);
int has_sdk_layout(const char *dir);

/* Appends `in`, JSON-string-escaped, to the NUL-terminated buffer `out`
 * (`out_size` bytes total, already NUL-terminated on entry). Shared by both
 * platforms' enumeration JSON builders. */
void json_escape_append(const char *in, char *out, size_t out_size);

/* Locates the libobs SDK directory. See rewind_obs.c's doc comment on the
 * function this wraps for the full candidate list; the REWIND_OBS_SDK_DIR
 * override and the "walk up looking for native/third_party/obs" dev-tree
 * fallback are platform-agnostic and stay there. The packaged-app
 * candidate check is delegated to rw_plat_sdk_dir_candidate() below. */
int find_obs_sdk_dir(char *out, size_t out_size);

/* Attaches `capture` (a platform backend's current g_capture, or NULL to
 * detach) as the sole item of an internal scene kept on channel 0, scaled to
 * fill the canvas (see rw_attach_capture()'s doc comment in rewind_obs.c for
 * why a scene is needed at all — a bare channel-0 source draws with no
 * scale-to-fit, cropping instead of scaling once the canvas can be smaller
 * than the source's native size). Every platform backend's
 * obs_set_output_source(0, ...) call site (both the initial attach and any
 * later re-attach when the backend recreates g_capture on a capture-kind
 * switch) goes through this instead of touching channel 0 directly — the
 * scene mechanics stay entirely in rewind_obs.c, so backend files carry no
 * scene-specific logic. */
void rw_attach_capture(obs_source_t *capture);

/* ---- platform backend interface ------------------------------------------
 *
 * One implementation of every function below lives in each
 * rewind_obs_<platform>.c. rewind_obs.c calls these unconditionally; it
 * never checks __APPLE__/_WIN32 itself.
 */

/* -- SDK / module / graphics-module path discovery -- */

/* Resolves the absolute directory containing this shared library (dladdr
 * on macOS, GetModuleHandleEx+GetModuleFileName on Windows). Returns 1 on
 * success. */
int rw_plat_own_dir(char *out, size_t out_size);

/* Portable realpath(): the real thing on macOS, _fullpath() on Windows. */
char *rw_plat_realpath(const char *path, char *resolved);

/* Checks the platform's own packaged-app SDK candidate location(s) (see
 * find_obs_sdk_dir's doc comment in rewind_obs.c for exactly which paths
 * each platform tries). Returns 1 and writes an existing SDK dir to `out`
 * on success, 0 to fall through to the generic dev-tree ancestor walk. */
int rw_plat_sdk_dir_candidate(const char *shim_dir, char *out, size_t out_size);

/* Registers the module bin/data path templates for obs_add_module_path(). */
void rw_plat_setup_module_paths(const char *sdk_dir);

/* Resolves an absolute, existing path to the graphics_module libobs should
 * load for its render device (libobs-opengl.dylib on macOS,
 * libobs-d3d11.dll on Windows). Returns 1 on success; on failure calls
 * set_error() naming every path tried and returns 0. */
int rw_plat_find_graphics_module_path(const char *sdk_dir, const char *shim_dir,
                                       char *out, size_t out_size);

/* -- rewind_obs_init helpers -- */

/* Platform capture-permission gate (macOS: Screen Recording TCC prompt via
 * CGPreflightScreenCaptureAccess/CGRequestScreenCaptureAccess; Windows: no
 * equivalent runtime prompt). Returns 0 if capture may proceed; on denial,
 * calls fail() (which sets the error message) and returns its non-zero
 * result — rewind_obs_init should return that value immediately. */
int rw_plat_check_permission(void);

/* Backs rewind_preflight_screen_permission()/rewind_request_screen_
 * permission() (see rewind_obs.h for the exact contract each follows).
 * Distinct from rw_plat_check_permission() above: that one is init-time
 * only (fails the call on denial); these two are pollable/on-demand and
 * never fail — they just report/request the current grant state, for
 * onboarding UI to drive live. */
int rw_plat_preflight_screen_permission(void);
int rw_plat_request_screen_permission(void);

/* Anything a platform needs wired up before obs_reset_video() — currently
 * only Windows' obs_add_data_path() call for libobs' own core data/effects
 * (see rewind_obs.c's doc comment on why macOS needs no equivalent). No-op
 * on platforms that don't need it. */
void rw_plat_pre_video_setup(const char *sdk_dir);

/* Creates and attaches the initial video capture source (g_capture) per
 * the current g_window_id/g_app_bundle_id/g_display_uuid preference.
 * Returns 0 on success; on failure calls set_error() and returns non-zero
 * (rewind_obs_init `goto cleanup`s on non-zero). */
int rw_plat_init_capture_source(void);

/* Creates and attaches g_venc/g_aenc (video + audio encoders). Returns 0 on
 * success; on failure calls set_error() and returns non-zero
 * (rewind_obs_init `goto cleanup`s on non-zero). */
int rw_plat_create_encoders(void);

/* Creates (but does not attach to a channel) a microphone source, targeting
 * g_mic_device_uid (empty string = platform's "default" device_id). Pure
 * creation, no logging/error-setting side effects — the pre-split call
 * sites (rewind_obs_init, rewind_set_mic_enabled, rewind_set_mic_device)
 * already handle a failed create differently (some log a warning and
 * continue, others fail the call), so that decision stays with the caller;
 * see rw_plat_log_mic_unavailable() for the platform-specific log line. */
obs_source_t *rw_plat_create_mic_source(void);

/* Logs the platform-specific "mic source unavailable" warning (exact
 * message differs: "coreaudio_input_capture unavailable (mic permission?)"
 * on macOS vs. "wasapi_input_capture unavailable" on Windows) — called only
 * from rewind_obs_init's best-effort mic setup, matching the pre-split
 * code's own inline blog() calls there. */
void rw_plat_log_mic_unavailable(void);

/* Checks whether the obs-ffmpeg-mux helper executable is present next to
 * the app's main executable. Returns 1 present, 0 confirmed absent, -1
 * unknown/uncheckable. */
int rw_plat_mux_helper_present(void);

/* -- display size/uuid + enumeration -- */

void rw_plat_query_main_display_size(uint32_t *width, uint32_t *height);
void rw_plat_main_display_uuid(char *out, size_t out_size);
int rw_plat_list_displays_json(char *json_out, int json_cap);
int rw_plat_list_capturable_apps_json(char *json_out, int json_cap);

/* Enumerates audio INPUT devices (microphones) — see
 * rewind_list_audio_inputs_json's doc comment in rewind_obs.h for the exact
 * JSON shape and per-platform status (macOS: real CoreAudio enumeration;
 * Windows/Linux: "[]", not yet implemented — see each backend's own TODO
 * comment). Returns 0 on success, non-zero (with set_error) on failure or a
 * too-small buffer. */
int rw_plat_list_audio_inputs_json(char *json_out, int json_cap);

/* -- audio -- */

/* (Re)builds the channel-1 system/app audio source to match g_audio_mode.
 * Safe to call before or after the pipeline exists. */
void rw_plat_rebuild_system_audio(void);

/* -- capture-target setters --
 *
 * Reconfigure the already-existing g_capture (or, on Windows, rebuild it
 * entirely) after rewind_set_capture_display/_app/_window updates the
 * corresponding g_* preference. Each mirrors exactly the pre-split
 * platform branch of its namesake setter, including that branch's own
 * guard — macOS only acts `if (g_capture)` (an existing source to update),
 * Windows only acts `if (g_initialized)` (rebuild_video_capture() itself
 * handles a not-yet-existing g_capture). That asymmetry is pre-existing
 * platform behavior, preserved as-is rather than unified.
 */

void rw_plat_on_capture_display_changed(void);
void rw_plat_on_capture_app_changed(void);
void rw_plat_on_capture_window_changed(void);

/* Resets any platform-private capture state machine to its initial value
 * (Windows: g_win_capture_kind = WIN_CAPTURE_NONE; no-op on macOS, which
 * keeps no such state). Called from both rewind_obs_init's failure cleanup
 * path and rewind_obs_shutdown(). */
void rw_plat_reset_capture_state(void);

/* -- perf telemetry (backs rewind_perf_stats_json's obs_render_avg_ms is
 * NOT here — obs_get_average_frame_time_ns() is a plain libobs.h call, no
 * platform seam needed; only the two OS-specific readings below are) -- */

/* GPU device utilization percent (0-100). macOS: IOKit's IOAccelerator
 * service, "Device Utilization %" from its PerformanceStatistics dict —
 * see
 * rewind_obs_macos.c's implementation doc comment for the exact registry
 * shape (verified live via `ioreg -r -c IOAccelerator -d 2`) and its
 * service-handle caching. Windows/Linux: always -1 (not implemented). -1 on
 * any read failure. */
int rw_plat_gpu_util_pct(void);

/* Thermal pressure state: macOS NSProcessInfo.thermalState, numeric
 * 0 nominal / 1 fair / 2 serious / 3 critical (see rewind_obs_macos.c's
 * implementation doc comment for how a C11 translation unit calls this
 * Cocoa API with no Objective-C syntax). Windows/Linux: always -1 (no
 * equivalent OS API targeted by this task). */
int rw_plat_thermal_state(void);

#endif /* REWIND_USE_LIBOBS */

#endif /* REWIND_OBS_INTERNAL_H */
