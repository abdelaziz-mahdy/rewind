/// The replay-buffer auto-pause policy behind `AppSettings.
/// captureOnlyInGame` ("Only record while playing") — the pure decision
/// logic wired into `main.dart`'s single buffer-control point,
/// `applyBufferPolicy`. Kept free of Flutter/engine/coordinator types so the
/// tray-pause / tray-resume precedence rule can be unit-tested directly,
/// same "pure Dart, testable" shape CLAUDE.md asks of event watchers.
library;

/// The tray's manual Pause/Resume override, threaded through every policy
/// evaluation:
///
/// - `null` — no override: the buffer state is decided purely by
///   [captureOnlyInGame] and whether a game is active.
/// - `false` — the user PAUSED via the tray. Sticky: wins over the policy
///   even while a game is (or becomes) active, and is cleared ONLY by an
///   explicit Resume — never by a game activating or exiting. "Pause always
///   wins."
/// - `true` — the user RESUMED via the tray. Temporary: forces the buffer on
///   regardless of [captureOnlyInGame], but is cleared at the very next game
///   activation/deactivation (see [clearedOverrideAfterTransition]) so the
///   policy reclaims control instead of staying stuck "always on" and
///   defeating the setting for the rest of the session.
typedef BufferManualOverride = bool?;

/// Whether the replay buffer should be running right now, given the current
/// setting, live game activity, and any manual tray override. This is the
/// one formula `main.dart`'s `applyBufferPolicy` starts/stops the engine
/// buffer (and updates `bufferActive`/the tray) from.
bool desiredBufferActive({
  required bool captureOnlyInGame,
  required bool anyGameActive,
  required BufferManualOverride manualOverride,
}) {
  if (manualOverride == false) return false; // pause always wins
  final forcedOn = manualOverride == true;
  return !captureOnlyInGame || anyGameActive || forcedOn;
}

/// Whether a stopped buffer is paused BY THE POLICY (captureOnlyInGame with
/// no game active) rather than by a manual tray pause — the signal
/// `RecorderCluster`'s status line uses to show "Waiting for a game" instead
/// of "Paused". False whenever the buffer is (or should be) running, and
/// false for a manual pause — that case already reads "Paused", which is
/// the honest label for something the user explicitly asked for.
bool isAutoPaused({
  required bool captureOnlyInGame,
  required bool anyGameActive,
  required BufferManualOverride manualOverride,
}) =>
    manualOverride != false &&
    !desiredBufferActive(
      captureOnlyInGame: captureOnlyInGame,
      anyGameActive: anyGameActive,
      manualOverride: manualOverride,
    );

/// The override to carry into the NEXT policy evaluation after a game
/// activation/deactivation (an "any game active" transition): clears a
/// temporary Resume override (`true`) so the policy can reclaim control, but
/// leaves a manual Pause (`false`) sticky, and leaves "no override" (`null`)
/// alone. See [BufferManualOverride]'s doc for the full precedence rule.
BufferManualOverride clearedOverrideAfterTransition(
        BufferManualOverride current) =>
    current == true ? null : current;
