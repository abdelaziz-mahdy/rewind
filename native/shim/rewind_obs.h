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

/* Suspends the capture session: detaches and releases the underlying
 * screen/window capture source (the platform's current capture source —
 * display, app, or window, whichever is targeted), while keeping every
 * stored target preference (display uuid / app bundle id / window id) so
 * rewind_capture_resume() can recreate the identical source afterward. On
 * macOS this is what actually stops the ScreenCaptureKit stream (releasing
 * the mac-capture source runs its destroy callback, which stops the SCStream
 * — see native/shim/rewind_obs.c's rewind_capture_suspend doc for the
 * vendored-source citation), which is what clears the macOS screen-recording
 * indicator, lets DRM-protected video (Netflix, Crave, etc.) resume playing
 * while Rewind idles, and drops the idle GPU/CPU cost the live-but-hidden
 * source was still paying. Meant to be called right after the replay buffer
 * is stopped (auto-pause OR a manual tray pause) — capturing with nothing
 * consuming the frames serves no purpose.
 * Idempotent: suspending an already-suspended (or not-yet-initialized)
 * pipeline is a no-op. No-op in stub mode. Returns 0 on success. */
int rewind_capture_suspend(void);

/* Reverses rewind_capture_suspend(): recreates the capture source from the
 * remembered display/app/window preference — the SAME platform rebuild path
 * rewind_obs_init() itself uses to create it the first time — and
 * re-attaches it. Meant to be called BEFORE rewind_start_buffer() whenever
 * the buffer is about to resume, so the buffer never starts against a
 * torn-down source. rewind_start_recording() also calls this implicitly
 * when the capture session is currently suspended (a manual recording with
 * no capture source would record nothing).
 * Idempotent: resuming an already-live (or not-yet-initialized) pipeline is
 * a no-op. No-op in stub mode. Returns 0 on success. */
int rewind_capture_resume(void);

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
 * ("uuid" is a ScreenCaptureKit display UUID on macOS, a monitor device-id
 * string on Windows — an opaque identifier either way; round-trip it
 * through rewind_set_capture_display unchanged.)
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
 * Safe to call before rewind_obs_init.
 * On Windows there are no bundle ids: "bundle_id" instead holds an opaque
 * "title:class:exe" window-identity token (win-capture's own "window"
 * setting format), one row per top-level capturable window deduplicated by
 * exe name; "icon" is always "" (icon extraction isn't implemented on
 * Windows); "window_id" is the window's HWND truncated to 32 bits
 * (lossless on 64-bit Windows — see rewind_set_capture_window). Still an
 * opaque identifier as far as callers are concerned — round-trip it
 * through rewind_set_capture_app unchanged either way. */
int rewind_list_capturable_apps(char *json_out, int json_cap);

/* Select a specific application to capture instead of a whole display,
 * identified by the bundle id string returned from
 * rewind_list_capturable_apps (on Windows, the opaque window-identity token
 * described above — same call, same semantics, different string shape).
 * Passing NULL or "" reverts to display capture (see
 * rewind_set_capture_display) using whichever display was last selected.
 * Safe to call before rewind_obs_init (the preference is remembered and
 * applied at init — an app target takes precedence over a display target
 * if both are set); if the capture source already exists, it is
 * reconfigured immediately. Returns 0 on success. */
int rewind_set_capture_app(const char *bundle_id);

/* Select a specific window to capture, identified by the "window_id" from
 * rewind_list_capturable_apps (a CGWindowID on macOS, an HWND truncated to
 * 32 bits on Windows). The ONLY way to capture a CrossOver/Wine game
 * specifically on macOS — those processes have no bundle id for
 * rewind_set_capture_app to match; on Windows, an equivalent direct pick by
 * window rather than by (deduplicated) app. Window ids are EPHEMERAL (they
 * die with their window): persist the app's NAME and re-resolve a fresh id
 * from enumeration instead of storing one. Passing 0 reverts to the
 * remaining app/display preference; any later rewind_set_capture_app call
 * also clears the window target. Returns 0 on success. */
int rewind_set_capture_window(uint32_t window_id);

/* Enable/disable microphone capture (the default input device — CoreAudio
 * on macOS, WASAPI on Windows), mixed into every clip and recording
 * alongside the always-on system audio. Safe to call before
 * rewind_obs_init (the preference is applied at init); after init the mic
 * source is created/torn down live. On macOS, first use triggers the
 * microphone permission prompt (the app bundle must declare
 * NSMicrophoneUsageDescription); Windows has no equivalent runtime prompt.
 * Returns 0 on success. */
int rewind_set_mic_enabled(int enabled);

/* Enumerate audio INPUT devices (microphones) as a compact JSON array
 * written into `json_out` (a caller-owned buffer of `json_cap` bytes), e.g.
 *   [{"uid":"...","name":"...","default":true|false}]
 * ("uid" is a CoreAudio device UID (kAudioDevicePropertyDeviceUID) on
 * macOS — round-trip it through rewind_set_mic_device unchanged; "default"
 * marks the system's current default input device.) Windows/Linux/stub
 * always report an empty array — device enumeration isn't implemented
 * there yet (not hardware-validated in this task); callers must treat an
 * empty list as "hide the picker", never synthesize fake devices. Returns
 * 0 on success, non-zero if enumeration failed or the buffer was too small
 * (see rewind_last_error). Safe to call before rewind_obs_init. */
int rewind_list_audio_inputs_json(char *json_out, int json_cap);

/* Selects the microphone input device by uid (from
 * rewind_list_audio_inputs_json), or NULL/"" for the system default. Safe
 * to call before rewind_obs_init (the preference is remembered and applied
 * whenever the mic source is next built — rewind_obs_init's best-effort mic
 * setup, or rewind_set_mic_enabled's create path); if the mic source is
 * already live, it is rebuilt on the new device immediately, the same way
 * rewind_set_mic_enabled builds it in the first place. No return value:
 * there's no failure mode a caller need act on — a bad/unplugged uid just
 * fails the rebuild, logged the same way an unavailable mic source always
 * is (see rw_plat_log_mic_unavailable). */
void rewind_set_mic_device(const char *uid_or_null);

/* Set the microphone recording-level multiplier (1.0 = 100%, i.e. unity
 * gain; clamped to 0.0-2.0). Safe to call before rewind_obs_init (the
 * preference is remembered and applied whenever the mic source is next
 * built, same as rewind_set_mic_device); if the mic source already exists,
 * applied immediately via obs_source_set_volume. No-op in stub mode.
 * Returns 0 on success. */
int rewind_set_mic_volume(float volume);

/* Enable/disable live mic monitoring — the mic plays through the system's
 * default output device (speakers/headphones) while it's on, so the user
 * can hear what rewind_set_mic_volume sets while adjusting it. Dart-side
 * this is deliberately transient/never persisted (see AppSettings), but the
 * shim stores the on/off state like any other mic preference and re-applies
 * it to every future mic source (re)create, mirroring rewind_set_mic_volume
 * — simpler than special-casing it, and safe because the Dart caller is
 * expected to explicitly turn monitoring off before anything that should
 * end a listen session (see SettingsScreen's doc: dispose, an explicit
 * toggle, or the mic being switched off). A no-op with no mic source live
 * (mic capture off, or rewind_obs_init not yet called): the preference is
 * still stored for next time. As an additional safety net independent of
 * that caller round-trip, the shim itself always stops monitoring on the
 * OUTGOING source first (obs_source_set_monitoring_type(..., NONE)) at
 * every point a mic source is released — rewind_obs_shutdown (which also
 * resets the stored preference to off), rewind_set_mic_enabled(0), and a
 * device-change rebuild — so a leaked toggle can never keep audio_monitor
 * playing past the source's own lifetime. Returns 0 on success. */
int rewind_set_mic_monitoring(int enabled);

/* Enable/disable mic auto-leveling: a compressor (evens out the recording
 * envelope) followed by a limiter (catches whatever peaks through) attached
 * to the mic source as private filters, default ON — the "set once, forget"
 * lever that keeps voice sitting consistently against game audio instead of
 * swinging between too quiet and too loud. Safe to call before
 * rewind_obs_init (the preference is remembered and applied whenever the
 * mic source is next built, same as rewind_set_mic_volume); if the mic
 * source already exists, the filters are attached/removed immediately.
 * No-op in stub mode. Returns 0 on success. */
int rewind_set_mic_leveling(int enabled);

/* Enable/disable mic noise suppression: an RNNoise noise_suppress_filter
 * attached to the mic source ahead of the auto-leveling chain (suppression
 * must see the raw signal BEFORE the compressor amplifies noise floor along
 * with voice), default ON. Same lifecycle contract as
 * rewind_set_mic_leveling: safe before init (preference remembered), live
 * attach/remove when the mic source exists, no-op in stub mode. Returns 0
 * on success. */
int rewind_set_mic_noise_suppression(int enabled);

/* Writes a JSON object with the current live audio levels, for the mic-test
 * meter UI:
 *   {"mic_peak_db":-18.2,"mic_mag_db":-24.0,
 *    "game_peak_db":-12.4,"game_mag_db":-20.1}
 * Values are dBFS as reported by an obs_volmeter attached to the mic /
 * desktop-audio sources (post-filter, post-volume-slider — i.e. what
 * actually lands in the recording mix). Sources that don't exist (mic off,
 * audio mode none) report -120.0, the same floor used for silence. Safe to
 * poll at UI rate (~10 Hz); values update on libobs' audio thread ~every
 * 50 ms. Stub mode: always the -120.0 floor. Returns 0 on success, 1 if
 * the buffer is too small. */
int rewind_audio_levels_json(char *json_out, int json_cap);

/* Set capture quality: `fps` is the capture framerate (e.g. 30 or 60);
 * `max_height` caps the output height (aspect preserved) when the display
 * is taller, or 0 for source resolution. Applied at rewind_obs_init — call
 * before init. After init it only stores the values (the UI applies the
 * change on next launch), since changing resolution/fps needs a full video
 * pipeline rebuild. Returns 0 on success. */
int rewind_set_capture_quality(int fps, int max_height);

/* Set the system/app audio mode: 0 = none (silence, unless the mic is on),
 * 1 = all desktop audio (every app), 2 = only the captured app's audio.
 * App mode needs an app capture source (see rewind_set_capture_app) — with
 * none it captures silence rather than leaking desktop audio. Safe before
 * init (stored) or after (rebuilds the source live). Returns 0. */
int rewind_set_audio_mode(int mode);

/* Set the game/desktop-audio recording-level multiplier (1.0 = 100%, i.e.
 * unity gain; clamped to 0.0-2.0) — the same lever as rewind_set_mic_volume
 * but against the desktop-audio source (channel 1) instead of the mic, so
 * game audio can be pulled down under voice. Safe to call before
 * rewind_obs_init (the preference is remembered and applied whenever the
 * desktop-audio source is next built — rewind_obs_init, rewind_set_audio_
 * mode, and rewind_set_capture_app's app-audio-mode rebuild all (re)create
 * it); if it already exists, applied immediately via
 * obs_source_set_volume. No-op in stub mode. Returns 0 on success. */
int rewind_set_game_volume(float volume);

/* Reports whether screen-capture permission is CURRENTLY granted, without
 * prompting — safe to poll repeatedly (e.g. once a second from onboarding
 * UI) to detect a grant that happened in System Settings while the app is
 * running. macOS: CGPreflightScreenCaptureAccess(). Windows/Linux/stub:
 * always 1 (no equivalent OS gate). Returns 1 if granted, 0 if not. */
int rewind_preflight_screen_permission(void);

/* Triggers the OS permission prompt where one exists (macOS:
 * CGRequestScreenCaptureAccess() — shows the system dialog the first time;
 * a no-op if already granted or already asked and denied, in which case the
 * user must be sent to System Settings instead). Returns the resulting
 * granted state, same as rewind_preflight_screen_permission(). Windows/
 * Linux/stub: always 1. */
int rewind_request_screen_permission(void);

/* Compact JSON snapshot of this process's own CPU/memory usage plus
 * libobs's frame-health/render-cost counters and OS-level GPU/thermal
 * readings, written into `json_out` (a caller-owned buffer of `json_cap`
 * bytes), e.g.
 *   {"cpu_user_s":12.3,"cpu_sys_s":1.2,"rss_bytes":314572800,
 *    "obs_total_frames":5992,"obs_lagged_frames":12,
 *    "vo_total_frames":5992,"vo_skipped_frames":0,
 *    "obs_render_avg_ms":4.21,"gpu_util_pct":37,"thermal_state":0}
 * cpu_user_s/cpu_sys_s are cumulative seconds of CPU time this process has
 * used (since process start — callers diff two samples for a per-interval
 * rate); rss_bytes is the CURRENT resident set size. The four frame
 * counters (obs_get_total_frames, obs_get_lagged_frames — renderer-side —
 * and video_output_get_total_frames, video_output_get_skipped_frames on
 * obs_get_video()'s video_t — encoder-side) are 0 whenever no capture
 * pipeline exists yet (stub mode, or before rewind_obs_init succeeds):
 * lagged/skipped frames are the signal that capture is straining the
 * machine.
 * obs_render_avg_ms (obs_get_average_frame_time_ns() / 1e6, 2 decimals) is
 * the compositor's average per-frame render cost — the direct measure of
 * render-pipeline changes (e.g. canvas resolution), since a GPU-side win
 * doesn't move cpu_user_s/cpu_sys_s at all; -1 whenever no pipeline exists
 * (same gate as the frame counters).
 * gpu_util_pct is GPU device utilization 0-100 (macOS: IOKit's
 * IOAccelerator "Device Utilization %"); -1 on Windows/Linux (not
 * implemented) or if the reading fails. Independent of pipeline state —
 * always attempted.
 * thermal_state is the OS's thermal-pressure level (macOS:
 * NSProcessInfo.thermalState) as 0 nominal / 1 fair / 2 serious /
 * 3 critical; -1 on Windows/Linux (no equivalent API targeted). Also
 * independent of pipeline state.
 * This is meant to be sampled unconditionally and often, and never fails
 * hard — any unavailable piece is reported as 0 or -1 (per field, see
 * above) rather than failing the call. Returns 0 on success, non-zero only
 * if `json_out`/`json_cap` are invalid or the buffer is too small (see
 * rewind_last_error). Safe to call at any time, before or after
 * rewind_obs_init. */
int rewind_perf_stats_json(char *json_out, int json_cap);

#ifdef __cplusplus
}
#endif

#endif /* REWIND_OBS_H */
