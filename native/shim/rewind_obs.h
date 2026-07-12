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

#ifdef __cplusplus
}
#endif

#endif /* REWIND_OBS_H */
