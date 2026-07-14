import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../coordinator/clip_coordinator.dart';
import '../../events/game_catalog.dart';
import '../../obs/app_info.dart';
import '../../obs/display_info.dart';
import '../../settings/app_settings.dart';
import '../theme.dart';

/// The persistent "recorder deck": a single 48 px row — buffering indicator,
/// active-game chip, the capture-source chip, the "Save clip" action — pinned
/// above the content area on every Shell destination (see docs/superpowers/
/// specs/2026-07-13-game-centric-redesign.md §3.2). When capture failed to
/// start, an [_ErrorBanner] renders as a second row underneath. This is the
/// visual anchor of the whole app — the one place a glance should tell you
/// "is it recording, what game, and from where."
class StatusStrip extends StatelessWidget {
  final ClipCoordinator coordinator;
  final String? captureError;

  /// Live buffer state; null means "running iff no capture error".
  final ValueListenable<bool>? bufferActive;

  /// Connected displays the capture-source chip can switch between. The chip
  /// is hidden entirely when this is empty (e.g. capture failed to start).
  final List<DisplayInfo> displays;

  /// Applications the capture-source chip can switch to, alongside displays.
  final List<AppInfo> capturableApps;

  /// Called (mirroring [coordinator.settings], mutated in place) whenever the
  /// capture-source chip or the buffer quick-set changes a setting.
  final Future<void> Function(AppSettings) onSettingsChanged;

  /// Opens the full Settings screen — used by the buffer quick-set's
  /// "Custom…" entry, which needs the free-text field Settings has.
  final VoidCallback onOpenSettings;

  /// Bumped by the caller at the end of every [onSettingsChanged] call.
  /// `StatusStrip` is otherwise stateless, and the capture-source chip /
  /// buffer quick-set mutate `coordinator.settings` in place rather than
  /// replacing it — without something to listen to, the settings-derived
  /// labels (the buffer readout, the source chip) would only refresh on the
  /// next unrelated rebuild (e.g. `activeGame` changing), not immediately
  /// after the user's own pick. Optional: existing callers/tests that don't
  /// exercise the chip/quick-set don't need to wire it.
  final ValueListenable<int>? settingsRevision;

  const StatusStrip({
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

  /// Pulsing "Buffering · N s" while running; grey dot + reason otherwise.
  /// The label is [Flexible] + single-line ellipsis so a narrow window or a
  /// long localized string truncates instead of overflowing the hero row.
  Widget _indicator(BuildContext context, bool running) {
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
            style: theme.textTheme.numeral
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
            style: theme.textTheme.numeral,
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

  Widget _liveIndicator(BuildContext context) {
    if (bufferActive case final active?) {
      return ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (context, running, _) => _indicator(context, running),
      );
    }
    return _indicator(context, captureError == null);
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
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(bottom: hairlineBorder()),
          ),
          child: Row(
            children: [
              Expanded(child: _liveIndicator(context)),
              const SizedBox(width: 12),
              Flexible(
                child: ValueListenableBuilder<String?>(
                  valueListenable: coordinator.activeGame,
                  builder: (context, gameId, _) => _GameChip(
                    key: const ValueKey('activeGameChip'),
                    label: displayNameFor(gameId),
                  ),
                ),
              ),
              if (displays.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: ValueListenableBuilder<String?>(
                    valueListenable: coordinator.autoSwitchedAppName,
                    builder: (context, autoName, _) => _SourceChip(
                      displays: displays,
                      capturableApps: capturableApps,
                      settings: coordinator.settings,
                      onSettingsChanged: onSettingsChanged,
                      autoSwitchedAppName: autoName,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
                onPressed:
                    captureError == null ? () => coordinator.onHotkey() : null,
                icon: const Icon(Icons.videocam_outlined, size: 16),
                label: const Text('Save clip'),
              ),
            ],
          ),
        ),
        if (captureError != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: _ErrorBanner(message: captureError!),
          ),
      ],
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

/// Rectangular chip showing the active game (or "Desktop" when none is
/// detected).
class _GameChip extends StatelessWidget {
  final String label;

  const _GameChip({required this.label, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(context.rewindTokens.radiusChip),
          border: Border.fromBorderSide(hairlineBorder()),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sports_esports_outlined,
                size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: theme.textTheme.label,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rectangular chip showing the current capture source (a whole display, or
/// a single app) — mirrors [_GameChip]'s shape. Tapping it opens a single unified
/// menu (displays, then a divider, then apps) to switch targets; the choice
/// is written straight through [onSettingsChanged] via the same path
/// Settings uses. This is the direct answer to "where is my recording coming
/// from" without a trip to Settings.
class _SourceChip extends StatelessWidget {
  final List<DisplayInfo> displays;
  final List<AppInfo> capturableApps;
  final AppSettings settings;
  final Future<void> Function(AppSettings) onSettingsChanged;

  /// [ClipCoordinator.autoSwitchedAppName]'s current value: non-null while a
  /// "follow the game" auto-switch is live, in which case it takes priority
  /// over the persisted source — the chip should show what's actually being
  /// captured right now, not the preference auto-switch is temporarily
  /// overriding.
  final String? autoSwitchedAppName;

  const _SourceChip({
    required this.displays,
    required this.capturableApps,
    required this.settings,
    required this.onSettingsChanged,
    this.autoSwitchedAppName,
  });

  /// Index into [displays] the chip should describe: the explicit saved
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

  void _pickApp(AppInfo a) {
    settings.captureAppBundleId = a.bundleId;
    onSettingsChanged(settings);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon =
        autoSwitchedAppName != null || settings.captureAppBundleId != null
            ? Icons.apps_outlined
            : Icons.desktop_windows_outlined;
    return PopupMenuButton<Object>(
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 200),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius:
                BorderRadius.circular(context.rewindTokens.radiusChip),
            border: Border.fromBorderSide(hairlineBorder()),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Capturing: $_label',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: theme.textTheme.label,
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.expand_more,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;

  const _ErrorBanner({required this.message});

  bool get _isPermissionError =>
      Platform.isMacOS && message.toLowerCase().contains('permission');

  static Future<void> _openScreenRecordingSettings() async {
    try {
      await Process.run('open', [
        'x-apple.systempreferences:com.apple.preference.security'
            '?Privacy_ScreenCapture'
      ]);
    } catch (_) {
      // Best-effort: no OS handler available is not fatal.
    }
  }

  @override
  Widget build(BuildContext context) {
    final amber = context.rewindTokens.warn;
    // Only coach the user toward the permission pane when the failure is
    // actually about permission — the shim reports that case explicitly.
    // Any other error must stand on its own instead of misdirecting.
    final text = Platform.isMacOS &&
            message.toLowerCase().contains('permission') &&
            !message.contains('System Settings')
        ? '$message\nSystem Settings → Privacy & Security → Screen Recording'
        : message;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(context.rewindTokens.radiusCard),
        border: Border.all(color: amber),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: amber),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: Theme.of(context).textTheme.body),
                if (_isPermissionError) ...[
                  const SizedBox(height: 8),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: _openScreenRecordingSettings,
                      child: Text('Open Screen Recording Settings'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
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
