import 'dart:async';

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

/// Shared sizing for the cluster's full-width controls, mirroring the old
/// deck's `_controlHeight`/`_controlIconSize` (see docs/superpowers/specs/
/// 2026-07-13-game-centric-redesign.md §3.2).
const double _controlHeight = 36;
const double _controlIconSize = 14;
const double _controlPaddingH = 12;

/// Square size of the real-app-icon / monogram leading a source-menu row.
const double _menuIconSize = 20;

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

  /// True while a STOPPED buffer is paused by the `captureOnlyInGame`
  /// policy (no game detected), as opposed to a manual tray pause — see
  /// `main.dart`'s `applyBufferPolicy`. Drives the idle status line's text:
  /// "Waiting for a game" instead of "Paused". Null (the common case in
  /// tests) always reads as a plain manual "Paused".
  final ValueListenable<bool>? bufferAutoPaused;

  /// Connected displays the source line can switch between (startup
  /// snapshot). No longer the sole gate on the line's visibility — see the
  /// visibility comment in [build]; a live [listApps] keeps the picker up
  /// even when this snapshot came back empty.
  final List<DisplayInfo> displays;

  /// Applications the source line can switch to, alongside displays — the
  /// startup snapshot, used when [listApps] is absent (tests, stub engine).
  final List<AppInfo> capturableApps;

  /// Live app enumeration, called each time the source menu opens so a game
  /// launched AFTER Rewind still shows up (the snapshot above never would).
  final List<AppInfo> Function()? listApps;

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
    this.listApps,
    required this.onSettingsChanged,
    required this.onOpenSettings,
    this.settingsRevision,
    this.bufferAutoPaused,
    super.key,
  });

  /// Pulsing dot + "Buffering · N s" while running; grey dot + reason
  /// otherwise. [Flexible] + single-line ellipsis so a long localized string
  /// truncates instead of overflowing the 220 px rail.
  Widget _statusLine(BuildContext context, bool running, bool autoPaused) {
    final theme = Theme.of(context);
    if (!running) {
      final label = captureError != null
          ? 'Capture unavailable'
          : (autoPaused ? 'Waiting for a game' : 'Paused');
      return Row(children: [
        const _IdleDot(),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            label,
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
    final active = bufferActive;
    final autoPaused = bufferAutoPaused;
    if (active == null) {
      return _statusLine(context, captureError == null, false);
    }
    // Merge both listenables so either changing (the buffer starting/
    // stopping, or the auto-pause reason flipping) refreshes the line — a
    // single ValueListenableBuilder would miss the other's changes.
    return ListenableBuilder(
      listenable:
          autoPaused != null ? Listenable.merge([active, autoPaused]) : active,
      builder: (context, _) =>
          _statusLine(context, active.value, autoPaused?.value ?? false),
    );
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
          // Show the picker whenever ANYTHING is pickable — not only when the
          // startup `displays` snapshot is non-empty. `displays`/
          // `capturableApps` are a one-shot snapshot (main.dart); a single
          // empty `listDisplays()` at launch (a display asleep/clamshell, the
          // screen locked, or a fullscreen game holding its own Space) used to
          // hide the ONLY app-picker in the main window for the whole session.
          // A live engine (`listApps != null`) re-enumerates on menu open, so
          // always show it and let it self-heal; tests with no live enumerator
          // fall back to the snapshot.
          if (displays.isNotEmpty ||
              capturableApps.isNotEmpty ||
              listApps != null) ...[
            ValueListenableBuilder<String?>(
              valueListenable: coordinator.autoSwitchedAppName,
              builder: (context, autoName, _) => _SourceLine(
                displays: displays,
                capturableApps: capturableApps,
                listApps: listApps,
                settings: coordinator.settings,
                onSettingsChanged: onSettingsChanged,
                onWinePick: (app, gameId) =>
                    coordinator.captureWineAppWindow(app, gameId: gameId),
                autoSwitchedAppName: autoName,
              ),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            height: _controlHeight,
            // Tooltip carries the WHY when the button is disabled — a bare
            // greyed control otherwise reads as broken (the status line
            // explaining it lives in a different corner of the deck).
            child: Tooltip(
              message: captureError == null
                  ? ''
                  : 'Capture unavailable — check Screen Recording permission',
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: _controlPaddingH),
                ),
                onPressed:
                    captureError == null ? () => coordinator.onHotkey() : null,
                icon:
                    const Icon(Icons.videocam_outlined, size: _controlIconSize),
                label: const Text('Save clip'),
              ),
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
/// deliberate look for Wine games, whose processes have no bundle to pull
/// an icon from.
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
  final List<AppInfo> Function()? listApps;
  final AppSettings settings;
  final Future<void> Function(AppSettings) onSettingsChanged;

  /// Invoked after picking a Wine app (empty bundleId, live window id) —
  /// wired to [ClipCoordinator.captureWineAppWindow] so the game's window
  /// gets captured immediately.
  final void Function(AppInfo app, String gameId)? onWinePick;

  /// [ClipCoordinator.autoSwitchedAppName]'s current value: non-null while a
  /// "follow the game" auto-switch is live, in which case it takes priority
  /// over the persisted source — the line should show what's actually being
  /// captured right now, not the preference auto-switch is temporarily
  /// overriding.
  final String? autoSwitchedAppName;

  const _SourceLine({
    required this.displays,
    required this.capturableApps,
    this.listApps,
    required this.settings,
    required this.onSettingsChanged,
    this.onWinePick,
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
    final gameId = gameIdForApp(a);
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
    final cfg = settings.configFor(gameId);
    cfg.processMatch ??= a.name;
    // Only for freshly-minted app:<slug> entries: catalog gameIds carry
    // their own (curated) displayName, which must not be shadowed.
    if (gameId.startsWith('app:') && matchingCatalogGame(a) == null) {
      cfg.displayName ??= a.name;
    }
    // Same "capture once, never overwrite" rule as processMatch/displayName
    // above: this is what lets the rail (`GameTileAvatar`) show the real
    // app icon even when the game isn't currently running (an `AppInfo`
    // only exists while its process is enumerable) — see `GameConfig.
    // iconPath`'s doc. Null for Wine apps (no bundle, so no icon) is a
    // correct, expected value here, not a bug — and so is skipping this for
    // Riot games: their app icon IS Riot's official logo, which Riot's
    // policy forbids using (see `usesOfficialLogo`'s doc); the monogram
    // stays for those.
    if (!usesOfficialLogo(gameId: gameId, bundleId: a.bundleId)) {
      cfg.iconPath ??= a.iconPath;
    }
    settings.setConfig(cfg);
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
                  style:
                      theme.textTheme.micro.copyWith(color: tokens.textMuted)),
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
      // Same disabled-state tooltip rationale as the Save clip button.
      child: Tooltip(
        message: widget.disabled
            ? 'Capture unavailable — check Screen Recording permission'
            : '',
        child: OutlinedButton.icon(
          key: const ValueKey('recordButton'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: _controlPaddingH),
          ),
          onPressed: onPressed,
          icon: const Icon(Icons.fiber_manual_record, size: _controlIconSize),
          label: const Text('Record'),
        ),
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

/// A small solid dot signaling that the replay buffer is live.
///
/// This used to pulse via a forever-repeating [AnimationController]. That is
/// a trap for a tool that runs in the BACKGROUND while you game: a
/// never-ending animation keeps Flutter submitting a fresh frame every
/// vsync, which forces the OS compositor to re-rasterize the whole (large,
/// Retina) window continuously — measured at ~45% app CPU + ~45%
/// WindowServer CPU while otherwise idle. A recorder must not steal that
/// from the game. It's now a STATIC dot, so the app renders only when
/// something actually changes and idles at ~0% CPU.
class _PulseDot extends StatelessWidget {
  const _PulseDot();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.rewindTokens.rec,
        shape: BoxShape.circle,
      ),
      child: const SizedBox(width: 10, height: 10),
    );
  }
}
