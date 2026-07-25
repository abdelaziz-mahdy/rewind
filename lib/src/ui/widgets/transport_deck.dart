import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../coordinator/clip_coordinator.dart';
import '../../obs/app_info.dart';
import '../../obs/display_info.dart';
import '../../settings/app_settings.dart';
import '../capture_app_match.dart';
import '../icns.dart';
import '../theme.dart';
import 'game_tile_avatar.dart';

/// Height of the deck. Fixed: it is chrome, and content below it must not
/// reflow when the tally changes width.
const double transportDeckHeight = 44;

const double _controlHeight = 28;
const double _controlIconSize = 14;
const double _controlPaddingH = 10;

/// Square size of the real-app-icon / monogram leading a source-menu row.
const double _menuIconSize = 20;

/// The transport deck: a full-width bar above the rail and content, present
/// on EVERY destination including Settings.
///
/// This replaces `RecorderCluster`, which lived at the bottom of the nav rail
/// (see docs/superpowers/specs/2026-07-25-broadcast-deck-design-system.md §2).
/// Two defects drove the move, both from the 2026-07-25 audit:
///
/// * The buffer state — the single thing a user wants to know mid-game — was
///   10px muted text at the bottom of a sidebar, under three stacked buttons.
/// * `Shell` renders the Settings destination full-page with no rail, so
///   opening Settings mid-match hid the REC state, the elapsed timer AND the
///   Save clip button until the user navigated back.
///
/// An earlier full-width deck (`StatusStrip`, 2026-07-13 spec §3.2) was
/// removed as redundant, and correctly so: it restated the active game's
/// name and icon, which the rail and every hub header already show. This
/// deck deliberately carries only what nothing else in the app can say —
/// tally state, how full the rolling buffer is, the timecode, what capture
/// is actually pointed at, and the two verbs.
///
/// Left to right: tally light, buffer ring + timecode (tap to change buffer
/// length), capture-source picker, then the hotkey cap, Save clip and Record.
class TransportDeck extends StatefulWidget {
  final ClipCoordinator coordinator;
  final String? captureError;

  /// Live buffer state; null means "running iff no capture error".
  final ValueListenable<bool>? bufferActive;

  /// True while a STOPPED buffer is paused by the `captureOnlyInGame` policy
  /// (no game detected), as opposed to a manual tray pause — see
  /// `main.dart`'s `applyBufferPolicy`. Drives the tally's idle wording:
  /// "WAITING FOR A GAME" instead of "PAUSED". Null (the common case in
  /// tests) always reads as a plain manual pause.
  final ValueListenable<bool>? bufferAutoPaused;

  /// The label of the global save hotkey, shown as a keycap beside the Save
  /// clip button so the two read as the same action.
  final String hotkeyLabel;

  /// Connected displays the source picker can switch between (startup
  /// snapshot). Not the sole gate on the picker's visibility — see the
  /// comment in [_DeckBody.build]; a live [listApps] keeps it up even when
  /// this snapshot came back empty.
  final List<DisplayInfo> displays;

  /// Applications the source picker can switch to, alongside displays — the
  /// startup snapshot, used when [listApps] is absent (tests, stub engine).
  final List<AppInfo> capturableApps;

  /// Live app enumeration, called each time the source menu opens so a game
  /// launched AFTER Rewind still shows up (the snapshot never would).
  final List<AppInfo> Function()? listApps;

  /// Called (mirroring [coordinator.settings], mutated in place) whenever the
  /// source picker or the buffer quick-set changes a setting.
  final Future<void> Function(AppSettings) onSettingsChanged;

  /// Opens the full Settings screen — used by the buffer quick-set's
  /// "Custom…" entry, which needs the free-text field Settings has.
  final VoidCallback onOpenSettings;

  /// Bumped by the caller at the end of every [onSettingsChanged] call, so an
  /// in-place settings mutation the widget tree has no other reason to notice
  /// still refreshes the readouts.
  final ValueListenable<int>? settingsRevision;

  const TransportDeck({
    required this.coordinator,
    required this.hotkeyLabel,
    required this.onSettingsChanged,
    required this.onOpenSettings,
    this.captureError,
    this.bufferActive,
    this.bufferAutoPaused,
    this.displays = const [],
    this.capturableApps = const [],
    this.listApps,
    this.settingsRevision,
    super.key,
  });

  @override
  State<TransportDeck> createState() => _TransportDeckState();
}

class _TransportDeckState extends State<TransportDeck> {
  /// Ticks the elapsed-recording readout, and (separately) the buffer ring
  /// while it is still filling. Never runs otherwise.
  ///
  /// This is the ONE place the app is allowed a repeating timer, and it is
  /// bounded on both sides: it stops the moment a recording ends, and the
  /// ring's fill reaches 1.0 after at most `bufferSeconds`. A forever-ticking
  /// UI is a real cost for a tool that runs in the background while you game
  /// — see `_PulseDot`'s history: a never-ending animation kept Flutter
  /// submitting frames every vsync and measured ~45% app + ~45% WindowServer
  /// CPU while otherwise idle.
  Timer? _ticker;

  /// Whole seconds elapsed in the current recording. Seeded once from
  /// [ClipCoordinator.recordingStartedAt] and then incremented by the ticker
  /// rather than re-read from `DateTime.now()`, so the readout advances
  /// exactly once per timer fire under `flutter_test`'s fake time (which
  /// fast-forwards `Timer`s but not the unfakeable `DateTime.now()`).
  int _elapsedSeconds = 0;

  /// When the replay buffer most recently started running, or null while it
  /// is stopped. Tracked here rather than in the coordinator: the buffer is
  /// started and stopped by `main.dart`'s `applyBufferPolicy`, and deriving
  /// the fill from the `bufferActive` transition keeps this entirely
  /// UI-local — no new engine call, and nothing per-frame.
  DateTime? _bufferRunningSince;

  /// Seconds of buffer already held, advanced by the ticker for the same
  /// fake-time reason as [_elapsedSeconds].
  int _bufferHeldSeconds = 0;

  @override
  void initState() {
    super.initState();
    widget.coordinator.isRecording.addListener(_onStateChanged);
    widget.bufferActive?.addListener(_onStateChanged);
    _syncBufferRunning();
    // Start the fill ticker for a buffer that is ALREADY running when the
    // deck mounts — the listener above only fires on later transitions.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onStateChanged();
    });
  }

  @override
  void didUpdateWidget(covariant TransportDeck old) {
    super.didUpdateWidget(old);
    if (old.coordinator != widget.coordinator) {
      old.coordinator.isRecording.removeListener(_onStateChanged);
      widget.coordinator.isRecording.addListener(_onStateChanged);
    }
    if (old.bufferActive != widget.bufferActive) {
      old.bufferActive?.removeListener(_onStateChanged);
      widget.bufferActive?.addListener(_onStateChanged);
    }
    _onStateChanged();
  }

  @override
  void dispose() {
    widget.coordinator.isRecording.removeListener(_onStateChanged);
    widget.bufferActive?.removeListener(_onStateChanged);
    _ticker?.cancel();
    super.dispose();
  }

  bool get _bufferRunning =>
      widget.bufferActive?.value ?? (widget.captureError == null);

  void _syncBufferRunning() {
    if (_bufferRunning) {
      if (_bufferRunningSince == null) {
        _bufferRunningSince = DateTime.now();
        _bufferHeldSeconds = 0;
      }
    } else {
      _bufferRunningSince = null;
      _bufferHeldSeconds = 0;
    }
  }

  /// How much of the rolling buffer is actually held right now, in [0,1].
  ///
  /// A buffer that has been running longer than its own length is full; one
  /// that just started holds nothing yet, and saying so is the difference
  /// between "armed" and "armed, but a save right now only reaches back four
  /// seconds".
  double get _bufferFill {
    if (!_bufferRunning) return 0;
    final length = widget.coordinator.settings
        .bufferSecondsFor(widget.coordinator.activeGame.value);
    if (length <= 0) return 1;
    return (_bufferHeldSeconds / length).clamp(0.0, 1.0);
  }

  bool get _needsTicker {
    if (widget.coordinator.isRecording.value) return true;
    return _bufferRunning && _bufferFill < 1.0;
  }

  void _onStateChanged() {
    if (!mounted) return;
    _syncBufferRunning();

    final recording = widget.coordinator.isRecording.value;
    if (recording && _ticker == null) {
      final start = widget.coordinator.recordingStartedAt.value;
      _elapsedSeconds =
          start != null ? DateTime.now().difference(start).inSeconds : 0;
    } else if (!recording) {
      _elapsedSeconds = 0;
    }

    if (_needsTicker) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {
          if (widget.coordinator.isRecording.value) _elapsedSeconds++;
          if (_bufferRunning) _bufferHeldSeconds++;
        });
        // Stop as soon as there is nothing left to advance — see [_ticker].
        if (!_needsTicker) {
          _ticker?.cancel();
          _ticker = null;
        }
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
    setState(() {});
  }

  String get _elapsed {
    final minutes = _elapsedSeconds ~/ 60;
    final seconds = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final revision = widget.settingsRevision;
    final autoPaused = widget.bufferAutoPaused;
    // Merge everything the deck reads so any of them changing refreshes it:
    // a single builder per notifier would miss the others.
    final listenable = Listenable.merge([
      widget.coordinator.isRecording,
      widget.coordinator.activeGame,
      widget.coordinator.autoSwitchedAppName,
      if (widget.bufferActive != null) widget.bufferActive!,
      if (autoPaused != null) autoPaused,
      if (revision != null) revision,
    ]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) => _buildDeck(context),
    );
  }

  Widget _buildDeck(BuildContext context) {
    final tokens = context.rewindTokens;
    final recording = widget.coordinator.isRecording.value;
    final bufferSeconds = widget.coordinator.settings
        .bufferSecondsFor(widget.coordinator.activeGame.value);

    return Container(
      key: const ValueKey('transportDeck'),
      height: transportDeckHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(bottom: hairlineBorder()),
      ),
      child: Row(
        children: [
          Flexible(
            child: TallyLight(
              state: _tallyState,
              elapsed: recording ? _elapsed : null,
            ),
          ),
          const SizedBox(width: 12),
          BufferReadout(
            fill: _bufferFill,
            seconds: bufferSeconds,
            running: _bufferRunning,
            onPick: _setBufferSeconds,
            onOpenSettings: widget.onOpenSettings,
          ),
          const SizedBox(width: 12),
          // Show the picker whenever ANYTHING is pickable — not only when the
          // startup `displays` snapshot is non-empty. That snapshot is
          // one-shot (main.dart); a single empty `listDisplays()` at launch (a
          // display asleep/clamshell, the screen locked, or a fullscreen game
          // holding its own Space) used to hide the only app picker in the
          // main window for the whole session. A live engine re-enumerates on
          // menu open, so always show it and let it self-heal; tests with no
          // live enumerator fall back to the snapshot.
          if (widget.displays.isNotEmpty ||
              widget.capturableApps.isNotEmpty ||
              widget.listApps != null)
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: SourcePicker(
                  displays: widget.displays,
                  capturableApps: widget.capturableApps,
                  listApps: widget.listApps,
                  settings: widget.coordinator.settings,
                  onSettingsChanged: widget.onSettingsChanged,
                  onWinePick: (app, gameId) => widget.coordinator
                      .captureWineAppWindow(app, gameId: gameId),
                  autoSwitchedAppName:
                      widget.coordinator.autoSwitchedAppName.value,
                ),
              ),
            ),
          const Spacer(),
          // First thing to go on a narrow window: it is a reminder, not a
          // control. Everything to its right is functional and stays.
          if (MediaQuery.sizeOf(context).width >= 860) ...[
            _KeyCap(label: widget.hotkeyLabel),
            const SizedBox(width: 8),
          ],
          SizedBox(
            height: _controlHeight,
            // The tooltip carries the WHY when the button is disabled — a
            // bare greyed control otherwise reads as broken.
            child: Tooltip(
              message: widget.captureError == null
                  ? 'Save the last $bufferSeconds seconds'
                  : 'Capture unavailable — check Screen Recording permission',
              child: FilledButton.icon(
                key: const ValueKey('deckSaveClip'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: _controlPaddingH),
                ),
                onPressed: widget.captureError == null
                    ? () => widget.coordinator.onHotkey()
                    : null,
                icon:
                    const Icon(Icons.videocam_outlined, size: _controlIconSize),
                label: const Text('Save clip'),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _RecordButton(
            coordinator: widget.coordinator,
            disabled: widget.captureError != null,
            recording: recording,
            elapsed: _elapsed,
          ),
        ],
      ),
    );
  }

  TallyState get _tallyState {
    if (widget.captureError != null) return TallyState.unavailable;
    if (widget.coordinator.isRecording.value) return TallyState.onAir;
    if (_bufferRunning) return TallyState.armed;
    if (widget.bufferAutoPaused?.value ?? false) return TallyState.waiting;
    return TallyState.paused;
  }

  /// Mirrors exactly what `bufferSecondsFor` reads: with a game active,
  /// `configFor` lazily creates (or reuses) that game's per-game row, which
  /// is what `bufferSecondsFor` — and the engine's own buffer-length calls —
  /// check FIRST. Writing only `defaultBufferSeconds` here would be a silent
  /// no-op once any game has ever been detected: the readout and the engine
  /// would keep reading the (unrelated) per-game value forever after.
  void _setBufferSeconds(int seconds) {
    final settings = widget.coordinator.settings;
    final gameId = widget.coordinator.activeGame.value;
    if (gameId != null) {
      final cfg = settings.configFor(gameId);
      cfg.bufferSeconds = seconds;
      settings.setConfig(cfg);
    } else {
      settings.defaultBufferSeconds = seconds;
    }
    widget.onSettingsChanged(settings);
  }
}

/// What the tally light is reporting. Named after broadcast practice, where
/// a camera's tally is amber on standby and red on air — which is exactly
/// the distinction Rewind needs and never used to draw: a running replay
/// buffer and an active recording are different things.
enum TallyState { armed, onAir, waiting, paused, unavailable }

/// The deck's leftmost element: a dot plus a tracked label, tinted by state.
/// Carries a `Semantics` label because the dot alone conveys state by color,
/// which is exactly what WCAG's "not by color alone" rule is about.
class TallyLight extends StatelessWidget {
  final TallyState state;

  /// Elapsed recording time, shown inside the label while on air.
  final String? elapsed;

  const TallyLight({required this.state, this.elapsed, super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final theme = Theme.of(context);
    final (color, label, spoken) = switch (state) {
      TallyState.onAir => (
          tokens.onAir,
          'REC ${elapsed ?? '0:00'}',
          'Recording, ${elapsed ?? '0:00'} elapsed',
        ),
      TallyState.armed => (
          tokens.armed,
          'ARMED',
          'Armed — the replay buffer is running',
        ),
      TallyState.waiting => (
          tokens.textDim,
          'WAITING FOR A GAME',
          'Waiting for a game — the buffer is paused until one starts',
        ),
      TallyState.paused => (
          tokens.textDim,
          'PAUSED',
          'Paused — the replay buffer is stopped',
        ),
      TallyState.unavailable => (
          tokens.danger,
          'UNAVAILABLE',
          'Capture unavailable — check Screen Recording permission',
        ),
    };
    final lit = state == TallyState.onAir || state == TallyState.armed;
    return Semantics(
      label: spoken,
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('deckTally'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: lit ? color.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(tokens.radiusChip),
            border: Border.all(
              color: lit ? color.withValues(alpha: 0.45) : tokens.hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Static, never pulsing — see `_PulseDot`'s history note.
              DecoratedBox(
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: const SizedBox(width: 7, height: 7),
              ),
              const SizedBox(width: 7),
              // Ellipsizes rather than overflowing: "WAITING FOR A GAME" is
              // the longest state, and the deck must survive a narrow window
              // without dropping a functional control to make room for it.
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  softWrap: false,
                  style: theme.textTheme.micro.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The buffer ring + timecode. Tapping either opens the buffer-length
/// quick-set (15/30/60/Custom…), the same menu the old status line offered.
///
/// Always reports the REPLAY BUFFER, never the elapsed recording time: the
/// two run independently (see `ClipCoordinator.isRecording`), so a save is
/// still reaching back through the buffer while a manual recording runs.
/// Elapsed time is the tally's and the stop button's job.
class BufferReadout extends StatelessWidget {
  final double fill;
  final int seconds;
  final bool running;
  final ValueChanged<int> onPick;
  final VoidCallback onOpenSettings;

  const BufferReadout({
    required this.fill,
    required this.seconds,
    required this.running,
    required this.onPick,
    required this.onOpenSettings,
    super.key,
  });

  static String _clock(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final value = _clock(seconds);
    final spoken = running
        ? 'Buffer $seconds seconds, ${(fill * 100).round()} percent held'
        : 'Buffer $seconds seconds, not running';
    return Semantics(
      label: spoken,
      button: true,
      child: ExcludeSemantics(
        child: PopupMenuButton<Object>(
          key: const ValueKey('deckBufferReadout'),
          tooltip: '',
          padding: EdgeInsets.zero,
          onSelected: (v) {
            if (v == 'custom') {
              onOpenSettings();
              return;
            }
            onPick(v as int);
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 15, child: Text('15 s')),
            PopupMenuItem(value: 30, child: Text('30 s')),
            PopupMenuItem(value: 60, child: Text('60 s')),
            PopupMenuItem(value: 'custom', child: Text('Custom…')),
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              BufferRing(
                fill: fill,
                color: tokens.armed,
                track: tokens.hairline,
                dimmed: !running,
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style: theme.textTheme.numeral
                          .copyWith(fontSize: 13, color: tokens.text)),
                  Text('BUFFER',
                      style: theme.textTheme.micro.copyWith(
                        fontSize: 8,
                        letterSpacing: 1.4,
                        color: tokens.textDim,
                      )),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A 20px ring that fills clockwise with how much rolling buffer is held.
///
/// Deliberately a ring and not a bar: the buffer is circular — it overwrites
/// its own oldest second forever — and a bar implies a beginning and an end
/// it does not have.
class BufferRing extends StatelessWidget {
  final double fill;
  final Color color;
  final Color track;
  final bool dimmed;

  const BufferRing({
    required this.fill,
    required this.color,
    required this.track,
    this.dimmed = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: CustomPaint(
        painter: _RingPainter(
          fill: fill.clamp(0.0, 1.0),
          color: dimmed ? color.withValues(alpha: 0.25) : color,
          track: track,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double fill;
  final Color color;
  final Color track;

  const _RingPainter(
      {required this.fill, required this.color, required this.track});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.5;
    final rect =
        Rect.fromLTWH(0, 0, size.width, size.height).deflate(stroke / 2 + 0.5);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);
    if (fill <= 0) return;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    // Starts at 12 o'clock and sweeps clockwise — the reading everyone
    // already has for a dial.
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * fill, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fill != fill || old.color != color || old.track != track;
}

/// A hotkey rendered as a physical keyboard key: bordered cap, numeral face.
/// No drop shadow — the "raised key" read comes from the border alone.
class _KeyCap extends StatelessWidget {
  final String label;

  const _KeyCap({required this.label});

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    return Semantics(
      label: 'Save hotkey $label',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(tokens.radiusChip),
            border: Border.all(color: tokens.hairline),
          ),
          child: Text(
            label,
            style: Theme.of(context)
                .textTheme
                .numeral
                .copyWith(fontSize: 11, color: tokens.textDim),
          ),
        ),
      ),
    );
  }
}

/// The manual-recording toggle: an outlined "Record" button at rest, an
/// `onAir`-filled "■ m:ss" while running. Both call
/// [ClipCoordinator.toggleRecording] — starting, then stopping, the same
/// session. The elapsed readout is owned by the deck (see
/// `_TransportDeckState._ticker`) so the tally and this button can never
/// disagree about it, and only one timer exists.
class _RecordButton extends StatelessWidget {
  final ClipCoordinator coordinator;
  final bool disabled;
  final bool recording;
  final String elapsed;

  const _RecordButton({
    required this.coordinator,
    required this.disabled,
    required this.recording,
    required this.elapsed,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final onPressed = disabled ? null : () => coordinator.toggleRecording();
    if (recording) {
      return SizedBox(
        height: _controlHeight,
        child: FilledButton.icon(
          key: const ValueKey('recordButton'),
          style: FilledButton.styleFrom(
            backgroundColor: tokens.onAir,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: _controlPaddingH),
          ),
          onPressed: onPressed,
          icon: const Icon(Icons.stop_outlined, size: _controlIconSize),
          label: Text(elapsed, style: Theme.of(context).textTheme.numeral),
        ),
      );
    }
    return SizedBox(
      height: _controlHeight,
      child: Tooltip(
        message: disabled
            ? 'Capture unavailable — check Screen Recording permission'
            : 'Start a full recording (not a buffer save)',
        child: OutlinedButton.icon(
          key: const ValueKey('recordButton'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: _controlPaddingH),
          ),
          onPressed: onPressed,
          icon: Icon(Icons.circle_outlined,
              size: _controlIconSize, color: tokens.onAir),
          label: const Text('Record'),
        ),
      ),
    );
  }
}

/// A source-menu row: a fixed-size leading icon + single-line label.
class _MenuRow extends StatelessWidget {
  final Widget icon;
  final String label;

  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(
        width: _menuIconSize,
        height: _menuIconSize,
        child: Center(child: icon),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text(label, overflow: TextOverflow.ellipsis, maxLines: 1),
      ),
    ]);
  }
}

/// An application row in the source menu: the app's REAL icon (extracted
/// from its bundle's .icns — see `icns.dart`) when available, else the same
/// FNV-monogram tile the rail uses (`GameTileAvatar`) — which is also the
/// deliberate look for Wine games, whose processes have no bundle to pull an
/// icon from.
class _AppMenuRow extends StatelessWidget {
  final AppInfo app;

  const _AppMenuRow({required this.app});

  @override
  Widget build(BuildContext context) {
    Widget icon;
    final png = app.iconPath != null ? loadAppIconPng(app.iconPath!) : null;
    if (png != null) {
      icon = ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.memory(
          png,
          width: _menuIconSize,
          height: _menuIconSize,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    } else {
      icon = GameTileAvatar(
        gameId: gameIdForApp(app),
        displayName: app.name,
        size: _menuIconSize,
      );
    }
    return _MenuRow(icon: icon, label: app.name);
  }
}

/// The capture-source picker: what a save or recording will actually
/// capture (a whole display, or a single app). A bordered rectangular
/// control with a trailing chevron; tapping it opens a unified menu
/// (displays, then a divider, then apps), writing the choice straight
/// through [onSettingsChanged] via the same path Settings uses.
class SourcePicker extends StatelessWidget {
  final List<DisplayInfo> displays;
  final List<AppInfo> capturableApps;
  final List<AppInfo> Function()? listApps;
  final AppSettings settings;
  final Future<void> Function(AppSettings) onSettingsChanged;

  /// Invoked after picking a Wine app (empty bundleId, live window id) —
  /// wired to [ClipCoordinator.captureWineAppWindow] so the game's window
  /// gets captured immediately.
  final void Function(AppInfo app, String gameId)? onWinePick;

  /// [ClipCoordinator.autoSwitchedAppName]'s current value: non-null while a
  /// "follow the game" auto-switch is live, in which case it takes priority
  /// over the persisted source — the picker should show what is actually
  /// being captured right now, not the preference auto-switch is temporarily
  /// overriding.
  final String? autoSwitchedAppName;

  const SourcePicker({
    required this.displays,
    required this.capturableApps,
    required this.settings,
    required this.onSettingsChanged,
    this.listApps,
    this.onWinePick,
    this.autoSwitchedAppName,
    super.key,
  });

  /// Index into [displays] the picker should describe: the explicit saved
  /// choice if it still identifies a connected display, else whichever
  /// display is main, else the first one.
  int _displayIndex() {
    final saved = settings.captureDisplayUuid;
    if (saved != null) {
      final i = displays.indexWhere((d) => d.uuid == saved);
      if (i != -1) return i;
    }
    final mainIdx = displays.indexWhere((d) => d.isMain);
    return mainIdx != -1 ? mainIdx : 0;
  }

  String get _label {
    if (autoSwitchedAppName case final auto?) return '$auto (auto)';
    final appId = settings.captureAppBundleId;
    if (appId != null) {
      // The stored name wins: a bundle-id lookup is ambiguous for Wine apps
      // (every CrossOver program shares the translator's bundle id, so
      // `capturableApps.first` could be any of them).
      if (settings.captureAppName case final name?) return name;
      final match = capturableApps.where((a) => a.bundleId == appId);
      return match.isNotEmpty ? match.first.name : appId;
    }
    if (displays.isEmpty) return 'Display 1';
    return 'Display ${_displayIndex() + 1}';
  }

  static String _displayMenuLabel(int index, DisplayInfo d) =>
      'Entire Display ${index + 1} — ${d.width}×${d.height}'
      '${d.isMain ? ' (Main)' : ''}';

  void _pickDisplay(DisplayInfo d) {
    settings.captureDisplayUuid = d.uuid;
    settings.captureAppBundleId = null;
    settings.captureAppName = null;
    onSettingsChanged(settings);
  }

  /// Picking an app is also how Rewind "learns" it: writes a [GameConfig] so
  /// the game shows up in the rail right away and is auto-detected/
  /// auto-followed the next time it's running (see `capture_app_match.dart`
  /// and `source_builder.dart`) — without this, a manually-picked app would
  /// be forgotten the moment the user picks something else or restarts.
  /// Reuses an existing catalog entry's gameId when [a] matches one (no
  /// duplicate row for a game the catalog already knows) and never
  /// overwrites an already-set `processMatch` on an existing config.
  void _pickApp(AppInfo a) {
    if (a.bundleId.isEmpty) {
      // Wine/CrossOver program (see AppInfo.bundleId): ScreenCaptureKit has
      // no bundle id to app-capture it by. The persisted preference stays
      // the display, and the ephemeral window capture starts immediately
      // below (after onSettingsChanged, whose engine.setCaptureApp call
      // would otherwise clobber the window target).
      settings.captureAppBundleId = null;
      settings.captureAppName = null;
    } else {
      settings.captureAppBundleId = a.bundleId;
      settings.captureAppName = a.name;
    }
    // The "learn this app as a game" half (GameConfig writes — see
    // learnAppAsGame's doc for the field rules) is shared with the
    // Supported Games screen's "Running now" Add button.
    final gameId = learnAppAsGame(settings, a);
    final persisted = onSettingsChanged(settings);
    if (a.bundleId.isEmpty && a.windowId != 0) {
      persisted.whenComplete(() => onWinePick?.call(a, gameId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final icon =
        autoSwitchedAppName != null || settings.captureAppBundleId != null
            ? Icons.apps_outlined
            : Icons.desktop_windows_outlined;
    return PopupMenuButton<Object>(
      // Scopes tests past the ambiguity of a picked app's name also
      // appearing (briefly, mid-close-animation) as a popup menu item with
      // the same text.
      key: const ValueKey('recorderSourceLine'),
      tooltip: 'What Rewind is capturing',
      padding: EdgeInsets.zero,
      onSelected: (value) {
        if (value is DisplayInfo) {
          _pickDisplay(value);
        } else if (value is AppInfo) {
          _pickApp(value);
        }
      },
      itemBuilder: (context) {
        // Fresh enumeration on open: a game launched after Rewind must
        // still appear (the startup snapshot alone never shows it).
        final apps = listApps?.call() ?? capturableApps;
        final grouped = partitionCapturableApps(apps);
        final theme = Theme.of(context);
        final tokens = context.rewindTokens;
        PopupMenuItem<Object> header(String label) => PopupMenuItem(
              enabled: false,
              height: 26,
              child: Text(label,
                  style: theme.textTheme.micro.copyWith(color: tokens.textDim)),
            );
        return [
          for (var i = 0; i < displays.length; i++)
            PopupMenuItem(
              value: displays[i],
              height: 36,
              child: _MenuRow(
                icon: const Icon(Icons.desktop_windows_outlined,
                    size: _menuIconSize),
                label: _displayMenuLabel(i, displays[i]),
              ),
            ),
          if (grouped.games.isNotEmpty) ...[
            const PopupMenuDivider(),
            header('DETECTED GAMES'),
            for (final app in grouped.games)
              PopupMenuItem(
                  value: app, height: 36, child: _AppMenuRow(app: app)),
          ],
          if (grouped.others.isNotEmpty) ...[
            const PopupMenuDivider(),
            header('APPLICATIONS'),
            for (final app in grouped.others)
              PopupMenuItem(
                  value: app, height: 36, child: _AppMenuRow(app: app)),
          ],
        ];
      },
      child: Container(
        height: _controlHeight,
        padding: const EdgeInsets.symmetric(horizontal: _controlPaddingH),
        decoration: BoxDecoration(
          border: Border.fromBorderSide(hairlineBorder()),
          borderRadius: BorderRadius.circular(tokens.radiusControl),
        ),
        child: Row(
          children: [
            Icon(icon, size: _controlIconSize, color: tokens.textMuted),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _label,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: theme.textTheme.body.copyWith(color: tokens.textMuted),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more,
                size: _controlIconSize, color: tokens.textMuted),
          ],
        ),
      ),
    );
  }
}
