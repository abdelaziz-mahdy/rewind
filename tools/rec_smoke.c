/*
 * rec_smoke.c — standalone smoke test for the manual-recording native path
 * (rewind_start_recording / rewind_stop_recording), independent of the
 * Flutter UI (which doesn't wire up a recording trigger yet — see
 * lib/src/coordinator/clip_coordinator.dart). Links directly against the
 * shim built into the debug app bundle (see tools/rec_smoke.sh) and drives
 * it through: init -> start the replay buffer -> start a manual recording
 * -> sleep 5s -> stop the recording -> shutdown, then asserts the recorded
 * file exists and is a plausible size.
 *
 * Usage: rec_smoke <out_dir>
 *
 * License: GPLv3 (links against the GPL-licensed shim/libobs).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

/* Declared directly rather than #include "rewind_obs.h" so this file has no
 * dependency on the shim's own header location relative to wherever it's
 * compiled from — just the small slice of the C ABI this smoke test uses. */
extern int rewind_obs_init(const char *out_dir, int seconds);
extern int rewind_start_buffer(void);
extern int rewind_start_recording(const char *out_dir);
extern const char *rewind_stop_recording(void);
extern int rewind_obs_shutdown(void);
extern const char *rewind_last_error(void);

int main(int argc, char **argv) {
    const char *out_dir = argc > 1 ? argv[1] : "/tmp";

    printf("==> rewind_obs_init(\"%s\", 30)\n", out_dir);
    if (rewind_obs_init(out_dir, 30) != 0) {
        fprintf(stderr, "FAIL: rewind_obs_init: %s\n", rewind_last_error());
        return 1;
    }

    printf("==> rewind_start_buffer()\n");
    if (rewind_start_buffer() != 0) {
        fprintf(stderr, "FAIL: rewind_start_buffer: %s\n", rewind_last_error());
        rewind_obs_shutdown();
        return 1;
    }

    printf("==> rewind_start_recording(\"%s\")\n", out_dir);
    if (rewind_start_recording(out_dir) != 0) {
        fprintf(stderr, "FAIL: rewind_start_recording: %s\n", rewind_last_error());
        rewind_obs_shutdown();
        return 1;
    }

    printf("==> recording for 5s...\n");
    sleep(5);

    printf("==> rewind_stop_recording()\n");
    const char *path = rewind_stop_recording();
    if (!path) {
        fprintf(stderr, "FAIL: rewind_stop_recording: %s\n", rewind_last_error());
        rewind_obs_shutdown();
        return 1;
    }
    /* Copy before shutdown: the shim owns this string's storage and may
     * reuse/clear it once torn down. */
    char path_copy[1024];
    snprintf(path_copy, sizeof(path_copy), "%s", path);
    printf("==> recorded path: %s\n", path_copy);

    rewind_obs_shutdown();

    struct stat st;
    if (stat(path_copy, &st) != 0) {
        fprintf(stderr, "FAIL: recorded file does not exist: %s\n", path_copy);
        return 1;
    }
    printf("==> file size: %lld bytes\n", (long long)st.st_size);
    if (st.st_size < 100 * 1024) {
        fprintf(stderr, "FAIL: recorded file too small (<100KB): %lld bytes\n", (long long)st.st_size);
        return 1;
    }

    printf("PASS: %s (%lld bytes)\n", path_copy, (long long)st.st_size);
    return 0;
}
