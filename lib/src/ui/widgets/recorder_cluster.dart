import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../coordinator/clip_coordinator.dart';
import '../../obs/app_info.dart';
import '../../obs/display_info.dart';
import '../../settings/app_settings.dart';
import '../capture_app_match.dart';
import '../theme.dart';

/// Shared sizing for the cluster's full-width controls, mirroring the old
/// deck's `_controlHeight`/`_controlIconSize` (see docs/superpowers/specs/
/// 2026-07-13-game-centric-redesign.md §3.2).
const double _controlHeight = 36;
const double _controlIconSize = 14;
const double _controlPaddingH = 12;

/// The Discord-style recorder cluster pinned to the BOTTOM of the left rail
/// (`NavRail`), replacing the old full-width top deck the maintainer called
/// "redundant" — the rail's own selection highlight and each hub's header
/// already say which game is live, so this cluster drops the old deck's
/// active-game chip entirely and keeps only what it can't say: is the
/// buffer running, and where is it capturing from.
///
/// Top to bottom: the capture-source picker (a bordered control — it decides
/// what the buttons below it will capture, so it reads source → actions),
/// then the primary "Save clip" button, the Record toggle, and a compact
/// status readout — REC/idle dot + the buffering quick-set. The picker and
/// the quick-set open the same popups the old deck's chips offered. All
/// existing props (`settingsRevision`, `bufferActive`, `onSettingsChanged`,
/// `onOpenSettings`) keep their contracts from the old `StatusStrip`.
class RecorderCluster extends StatelessWidget {
  final ClipCoordinator coordinator;
  final String? captureError;

  /// Live buffer state; null means "running iff no capture error".
  final ValueListenable<bool>? bufferActive;

  /// Connected displays the source line can switch between. The line is
  /// hidden entirely when this is empty (e.g. capture failed to start).
  final List<DisplayInfo> displays;

  /// Applications the source line can switch to, alongside displays.
  final List<AppInfo> capturableApps;

  /// Called (mirroring [coordinator.settings], mutated in place) whenever
  /// the source line or the buffer quick-set changes a setting.
  final Future<void> Function(AppSettings) onSettingsChanged;

  /// Opens the full Settings screen — used by the buffer quick-set's
  /// "Custom…" entry, which needs the free-text field Settings has.
  final VoidCallback onOpenSettings;

  /// Bumped by the caller at the end of every [onSettingsChanged] call —
  /// see the identical doc on the old `StatusStrip.settingsRevision`.
  final ValueListenable<int>? settingsRevision;

  const RecorderCluster({
    required this.coordinator,
    this.captureError,
    this.bufferActive,
    this.displays = const [],
    this.capturableApps = const [],
    required this.onSettingsChanged,
    required this.onOpenSettings,
    this.settingsRevision,
    super.key,
  });

  /// Pulsing dot + "Buffering · N s" while running; grey dot + reason
  /// otherwise. [Flexible] + single-line ellipsis so a long localized string
  /// truncates instead of overflowing the 220 px rail.
  Widget _statusLine(BuildContext context, bool running) {
    final theme = Theme.of(context);
    if (!running) {
      return Row(children: [
        const _IdleDot(),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            captureError != null ? 'Capture unavailable' : 'Paused',
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: theme.textTheme.body
                .copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ]);
    }
    return Row(children: [
      const _PulseDot(),
      const SizedBox(width: 10),
      Flexible(
        child: ValueListenableBuilder<String?>(
          valueListenable: coordinator.activeGame,
          builder: (context, gameId, _) => _BufferQuickSet(
            label:
                'Buffering · ${coordinator.settings.bufferSecondsFor(gameId)} s',
            style: theme.textTheme.body,
            onPick: (seconds) {
              // Mirrors exactly what `bufferSecondsFor` reads: with a game
              // active, `configFor` lazily creates (or reuses) that game's
              // per-game row, which is what `bufferSecondsFor` — and the
              // engine's own buffer-length calls — check FIRST. Writing only
              // `defaultBufferSeconds` here would be a silent no-op once any
              // game has ever been detected: the label and the engine would
              // keep reading the (unrelated) per-game value forever after.
              if (gameId != null) {
                final cfg = coordinator.settings.configFor(gameId);
                cfg.bufferSeconds = seconds;
                coordinator.settings.setConfig(cfg);
              } else {
                coordinator.settings.defaultBufferSeconds = seconds;
              }
              onSettingsChanged(coordinator.settings);
            },
            onOpenSettings: onOpenSettings,
          ),
        ),
      ),
    ]);
  }

  Widget _liveStatusLine(BuildContext context) {
    if (bufferActive case final active?) {
      return ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (context, running, _) => _statusLine(context, running),
      );
    }
    return _statusLine(context, captureError == null);
  }

  @override
  Widget build(BuildContext context) {
    final revision = settingsRevision;
    if (revision == null) return _buildContent(context);
    // See [settingsRevision]'s doc: forces a rebuild after an in-place
    // settings mutation the widget tree otherwise has no other reason to
    // notice.
    return ValueListenableBuilder<int>(
      valueListenable: revision,
      builder: (context, _, __) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    return Container(
      key: const ValueKey('recorderCluster'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        border: Border(top: hairlineBorder()),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (displays.isNotEmpty) ...[
            ValueListenableBuilder<String?>(
              valueListenable: coordinator.autoSwitchedAppName,
              builder: (context, autoName, _) => _SourceLine(
                displays: displays,
                capturableApps: capturableApps,
                settings: coordinator.settings,
                onSettingsChanged: onSettingsChanged,
                autoSwitchedAppName: autoName,
              ),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            height: _controlHeight,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: _controlPaddingH),
              ),
              onPressed:
                  captureError == null ? () => coordinator.onHotkey() : null,
              icon: const Icon(Icons.videocam_outlined, size: _controlIconSize),
              label: const Text('Save clip'),
            ),
          ),
          const SizedBox(height: 8),
          _RecordButton(
            coordinator: coordinator,
            disabled: captureError != null,
          ),
          const SizedBox(height: 12),
          _liveStatusLine(context),
        ],
      ),
    );
  }
}

/// Wraps the "Buffering · N s" readout so tapping it offers a quick way to
/// change the default buffer length without a trip to Settings — 15/30/60,
/// or "Custom…" which hands off to the full Settings screen for the
/// free-text field.
class _BufferQuickSet extends StatelessWidget {
  final String label;
  final TextStyle? style;
  final ValueChanged<int> onPick;
  final VoidCallback onOpenSettings;

  const _BufferQuickSet({
    required this.label,
    required this.style,
    required this.onPick,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Object>(
      tooltip: '',
      padding: EdgeInsets.zero,
      onSelected: (value) {
        if (value == 'custom') {
          onOpenSettings();
          return;
        }
        onPick(value as int);
      },
      itemBuilder: (context) => const [
        PopupMenuItem(value: 15, child: Text('15 s')),
        PopupMenuItem(value: 30, child: Text('30 s')),
        PopupMenuItem(value: 60, child: Text('60 s')),
        PopupMenuItem(value: 'custom', child: Text('Custom…')),
      ],
      child: Text(
        label,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: style,
      ),
    );
  }
}

/// The cluster's capture-source picker, at the TOP of the cluster: what a
/// save/record will capture (a whole display, or a single app). Styled as a
/// bordered rectangular control with a trailing chevron (§2 shape language)
/// — it used to be a naked icon + text line at the cluster's bottom and the
/// maintainer couldn't find it. Tapping it opens the same unified menu
/// (displays, then a divider, then apps) the old `_SourceChip` used, writing
/// the choice straight through [onSettingsChanged] via the same path
/// Settings uses.
class _SourceLine extends StatelessWidget {
  final List<DisplayInfo> displays;
  final List<AppInfo> capturableApps;
  final AppSettings settings;
  final Future<void> Function(AppSettings) onSettingsChanged;

  /// [ClipCoordinator.autoSwitchedAppName]'s current value: non-null while a
  /// "follow the game" auto-switch is live, in which case it takes priority
  /// over the persisted source — the line should show what's actually being
  /// captured right now, not the preference auto-switch is temporarily
  /// overriding.
  final String? autoSwitchedAppName;

  const _SourceLine({
    required this.displays,
    required this.capturableApps,
    required this.settings,
    required this.onSettingsChanged,
    this.autoSwitchedAppName,
  });

  /// Index into [displays] the line should describe: the explicit saved
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
    settings.captureAppBundleId = a.bundleId;
    final gameId = gameIdForApp(a);
    final cfg = settings.configFor(gameId);
    cfg.processMatch ??= a.name;
    settings.setConfig(cfg);
    onSettingsChanged(settings);
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
      // the same text — see recorder_cluster_test.dart.
      key: const ValueKey('recorderSourceLine'),
      tooltip: '',
      padding: EdgeInsets.zero,
      onSelected: (value) {
        if (value is DisplayInfo) {
          _pickDisplay(value);
        } else if (value is AppInfo) {
          _pickApp(value);
        }
      },
      itemBuilder: (context) => [
        for (var i = 0; i < displays.length; i++)
          PopupMenuItem(
            value: displays[i],
            child: Text(_displayMenuLabel(i, displays[i])),
          ),
        if (displays.isNotEmpty && capturableApps.isNotEmpty)
          const PopupMenuDivider(),
        for (final app in capturableApps)
          PopupMenuItem(value: app, child: Text(app.name)),
      ],
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
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _label,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: theme.textTheme.body
                    .copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.expand_more,
                size: _controlIconSize, color: tokens.textMuted),
          ],
        ),
      ),
    );
  }
}

/// The cluster's manual-recording toggle: idle it's an outlined "Record"
/// button with a dot icon; while [ClipCoordinator.isRecording] is true it
/// becomes a filled, `rec`-red "■ 0:42" button with a 1 s-ticking elapsed
/// readout (tabular numerals) computed from
/// [ClipCoordinator.recordingStartedAt]. Clicking either state calls
/// [ClipCoordinator.toggleRecording] — starting, then stopping, the same
/// session. Full rail-width via the parent Column's `CrossAxisAlignment.
/// stretch`, same logic as the old deck's `_RecordButton`.
class _RecordButton extends StatefulWidget {
  final ClipCoordinator coordinator;

  /// Mirrors the Save clip button: true whenever there's a capture error.
  final bool disabled;

  const _RecordButton({required this.coordinator, required this.disabled});

  @override
  State<_RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<_RecordButton> {
  Timer? _ticker;

  /// Whole seconds elapsed since the recording started. Seeded once from
  /// [ClipCoordinator.recordingStartedAt] when a session begins, then
  /// incremented by the ticker itself rather than re-read from
  /// `DateTime.now()` on every tick — so the readout advances exactly once
  /// per `Timer.periodic` fire under `flutter_test`'s fake-time `pump()`,
  /// which fast-forwards `Timer`s but not the unfakeable `DateTime.now()`.
  int _elapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    widget.coordinator.isRecording.addListener(_onRecordingChanged);
  }

  @override
  void didUpdateWidget(covariant _RecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coordinator != widget.coordinator) {
      oldWidget.coordinator.isRecording.removeListener(_onRecordingChanged);
      widget.coordinator.isRecording.addListener(_onRecordingChanged);
      _onRecordingChanged();
    }
  }

  @override
  void dispose() {
    widget.coordinator.isRecording.removeListener(_onRecordingChanged);
    _ticker?.cancel();
    super.dispose();
  }

  /// Starts/stops the 1 s ticker alongside [ClipCoordinator.isRecording]
  /// flipping, and rebuilds so the button's state (outlined vs filled-red)
  /// and its elapsed readout stay in sync.
  void _onRecordingChanged() {
    final recording = widget.coordinator.isRecording.value;
    if (recording && _ticker == null) {
      final start = widget.coordinator.recordingStartedAt.value;
      _elapsedSeconds =
          start != null ? DateTime.now().difference(start).inSeconds : 0;
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        _elapsedSeconds++;
        if (mounted) setState(() {});
      });
    } else if (!recording && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
    if (mounted) setState(() {});
  }

  String get _elapsed {
    final minutes = _elapsedSeconds ~/ 60;
    final seconds = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final onPressed =
        widget.disabled ? null : () => widget.coordinator.toggleRecording();
    if (widget.coordinator.isRecording.value) {
      return SizedBox(
        height: _controlHeight,
        child: FilledButton.icon(
          key: const ValueKey('recordButton'),
          style: FilledButton.styleFrom(
            backgroundColor: context.rewindTokens.rec,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: _controlPaddingH),
          ),
          onPressed: onPressed,
          icon: const Icon(Icons.stop_rounded, size: _controlIconSize),
          label: Text(
            _elapsed,
            style: Theme.of(context)
                .textTheme
                .label
                .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
      );
    }
    return SizedBox(
      height: _controlHeight,
      child: OutlinedButton.icon(
        key: const ValueKey('recordButton'),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: _controlPaddingH),
        ),
        onPressed: onPressed,
        icon: const Icon(Icons.fiber_manual_record, size: _controlIconSize),
        label: const Text('Record'),
      ),
    );
  }
}

/// A static grey dot for the paused / capture-unavailable states.
class _IdleDot extends StatelessWidget {
  const _IdleDot();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.rewindTokens.textMuted,
        shape: BoxShape.circle,
      ),
      child: const SizedBox(width: 10, height: 10),
    );
  }
}

/// A small solid dot signaling that the replay buffer is live: a slow,
/// subtle opacity pulse (0.45 → 1.0 over 1.2 s) earns it motion without any
/// glow — no BoxShadow, per the redesign's "no halos anywhere" rule.
class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_controller),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.rewindTokens.rec,
          shape: BoxShape.circle,
        ),
        child: const SizedBox(width: 10, height: 10),
      ),
    );
  }
}
