/*
 * rewind_obs.h — tiny C shim over libobs for Rewind.
 *
 * This is the ENTIRE native surface the Dart side sees. Keep it small and
 * stable. No C++ here (keeps dart:ffi binding trivial — no name mangling).
 *
 * License: GPLv3 (Rewind embeds libobs, which is GPL).
 */
#ifndef REWIND_OBS_H
#define REWIND_OBS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Initialise libobs, create the video/audio pipeline, select the platform
 * capture source, and configure a replay buffer of `seconds` length writing to
 * `out_dir`. Returns 0 on success, non-zero on error (see rewind_last_error). */
int rewind_obs_init(const char *out_dir, int seconds);

/* Start the rolling replay buffer. Returns 0 on success. */
int rewind_start_buffer(void);

/* Flush the last N seconds to a file inside `out_dir`.
 * Returns a pointer to a NUL-terminated path string owned by the shim
 * (valid until the next call to rewind_save_clip), or NULL on failure. */
const char *rewind_save_clip(const char *out_dir);

/* Stop the replay buffer. Returns 0 on success. */
int rewind_stop_buffer(void);

/* Begin a manual, continuous recording session into `out_dir`, independent
 * of the rolling replay buffer (which keeps running unaffected). Writes to
 * "<out_dir>/rewind-rec-<timestamp>.mp4", mirroring the replay buffer's own
 * filename style. The underlying output is created once on first use and
 * reused on subsequent calls; it shares the same video/audio encoders as
 * the replay buffer (standard practice for libobs outputs — see
 * native/shim/README.md). Returns 0 on success, non-zero if a recording is
 * already in progress or the output fails to start (see rewind_last_error). */
int rewind_start_recording(const char *out_dir);

/* End the recording session started by rewind_start_recording. Blocks
 * (bounded, ~5s) until the output has fully stopped so the file is
 * finalised before returning. Returns a pointer to a NUL-terminated path
 * string owned by the shim (valid until the next call to
 * rewind_start_recording or rewind_stop_recording), or NULL if no recording
 * was in progress (see rewind_last_error). */
const char *rewind_stop_recording(void);

/* Tear down libobs. Returns 0 on success. */
int rewind_obs_shutdown(void);

/* Human-readable description of the last error, or "" if none. */
const char *rewind_last_error(void);


/* Change the replay-buffer length at runtime (used when the active game
 * changes and a per-game buffer length applies). Returns 0 on success. */
int rewind_set_buffer_seconds(int seconds);

/* Enumerate the connected displays as a compact JSON array written into
 * `json_out` (a caller-owned buffer of `json_cap` bytes), e.g.
 *   [{"uuid":"...","width":1920,"height":1080,"main":true}, ...]
 * Returns 0 on success, non-zero if enumeration failed or the buffer was too
 * small (see rewind_last_error). Safe to call before rewind_obs_init. */
int rewind_list_displays(char *json_out, int json_cap);

/* Select which display the capture source should record, identified by the
 * uuid string returned from rewind_list_displays. Safe to call before
 * rewind_obs_init (the preference is remembered and applied at init); if
 * the capture source already exists, it is reconfigured immediately.
 * Returns 0 on success. */
int rewind_set_capture_display(const char *display_uuid);

/* Enumerate applications that currently have at least one capturable
 * on-screen window (normal layer, ≥64px), as a compact JSON array written
 * into `json_out` (a caller-owned buffer of `json_cap` bytes), e.g.
 *   [{"bundle_id":"com.apple.Safari","name":"Safari","pid":1234,
 *     "icon":"/Applications/Safari.app/Contents/Resources/AppIcon.icns",
 *     "window_id":42}, ...]
 * Deduplicated by bundle id; this process itself is omitted. Windows-exe
 * (Wine/CrossOver) processes are emitted with an EMPTY bundle_id and their
 * exe name (see rewind_set_capture_window for how to capture those);
 * "icon" is "" when the bundle declares no .icns file; "window_id" is the
 * app's frontmost window (0 if unknown). Returns 0 on success, non-zero if
 * enumeration failed or the buffer was too small (see rewind_last_error).
 * Safe to call before rewind_obs_init. */
int rewind_list_capturable_apps(char *json_out, int json_cap);

/* Select a specific application to capture instead of a whole display,
 * identified by the bundle id string returned from
 * rewind_list_capturable_apps. Passing NULL or "" reverts to display
 * capture (see rewind_set_capture_display) using whichever display was
 * last selected. Safe to call before rewind_obs_init (the preference is
 * remembered and applied at init — an app target takes precedence over a
 * display target if both are set); if the capture source already exists,
 * it is reconfigured immediately. Returns 0 on success. */
int rewind_set_capture_app(const char *bundle_id);

/* Select a specific window to capture, identified by the "window_id"
 * (CGWindowID) from rewind_list_capturable_apps. The ONLY way to capture a
 * CrossOver/Wine game specifically — those processes have no bundle id for
 * rewind_set_capture_app to match. Window ids are EPHEMERAL (they die with
 * their window): persist the app's NAME and re-resolve a fresh id from
 * enumeration instead of storing one. Passing 0 reverts to the remaining
 * app/display preference; any later rewind_set_capture_app call also
 * clears the window target. Returns 0 on success. */
int rewind_set_capture_window(uint32_t window_id);

/* Enable/disable microphone capture (CoreAudio default input device),
 * mixed into every clip and recording alongside the always-on system
 * audio. Safe to call before rewind_obs_init (the preference is applied at
 * init); after init the mic source is created/torn down live. First use
 * triggers the macOS microphone permission prompt (the app bundle must
 * declare NSMicrophoneUsageDescription). Returns 0 on success. */
int rewind_set_mic_enabled(int enabled);

#ifdef __cplusplus
}
#endif

#endif /* REWIND_OBS_H */
