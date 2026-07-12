# Rewind native shim (`rewind_obs`)

A tiny C shim over **libobs** — the only native code in Rewind. It exposes a
handful of C functions (see `rewind_obs.h`) that the Dart side calls via
`dart:ffi`. All libobs complexity is hidden here.

## Current state

`rewind_obs.c` ships as a **stub** so the Flutter app links and runs before
libobs is integrated. Every function documents the real libobs calls to add
(look for `TODO(libobs)`), and `rewind_save_clip` returns a synthesized path so
the Dart pipeline can be exercised end-to-end in "dev mode".

## Wiring up real libobs

1. Obtain a libobs build/SDK (build OBS Studio, or use a packaged SDK). Do not
   commit it — it belongs in `native/third_party/obs/` (gitignored).
2. Implement the `TODO(libobs)` sections:
   - startup / video / audio reset
   - platform capture source (ScreenCaptureKit on macOS, Windows Graphics
     Capture on Windows)
   - hardware encoder + replay-buffer output
   - save + last-replay-path readback
3. Build the shared library:

   **macOS**
   ```bash
   clang -shared -fPIC rewind_obs.c -o librewind_obs.dylib \
     -DREWIND_USE_LIBOBS -I<obs>/libobs -L<obs-build>/libobs -lobs
   ```

   **Windows (MSVC)**
   ```bat
   cl /LD rewind_obs.c /DREWIND_USE_LIBOBS /I <obs>\libobs obs.lib
   ```

4. Place the resulting library where the app can `DynamicLibrary.open` it
   (next to the executable / inside the `.app` bundle). Ship libobs' runtime
   `data/` and `obs-plugins/` alongside — see ARCHITECTURE.md → Packaging.

## Licensing

Linking libobs makes the whole app GPLv3. Keep this shim GPLv3 and free of
GPL-incompatible dependencies.
