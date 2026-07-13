import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../coordinator/clip_coordinator.dart';
import '../theme.dart';

/// Top-of-home hero card: buffering indicator (large numerals), active-game
/// chip, the "Save clip" action, and (when capture failed to start) an error
/// banner. This is the visual anchor of the whole app — the one place a
/// glance should tell you "is it recording, and what."
class StatusStrip extends StatelessWidget {
  final ClipCoordinator coordinator;
  final String? captureError;

  /// Live buffer state; null means "running iff no capture error".
  final ValueListenable<bool>? bufferActive;

  const StatusStrip({
    required this.coordinator,
    this.captureError,
    this.bufferActive,
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
            style: theme.textTheme.heroNumeral
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
          builder: (context, gameId, _) => Text(
            'Buffering · ${coordinator.settings.bufferSecondsFor(gameId)} s',
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: theme.textTheme.heroNumeral,
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (captureError != null) ...[
            _ErrorBanner(message: captureError!),
            const SizedBox(height: 12),
          ],
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(20),
              border: Border.fromBorderSide(hairlineBorder()),
            ),
            child: Row(
              children: [
                Expanded(child: _liveIndicator(context)),
                const SizedBox(width: 16),
                ValueListenableBuilder<String?>(
                  valueListenable: coordinator.activeGame,
                  builder: (context, gameId, _) =>
                      _GameChip(label: gameId ?? 'Desktop'),
                ),
                const SizedBox(width: 16),
                FilledButton.icon(
                  onPressed: captureError == null
                      ? () => coordinator.onHotkey()
                      : null,
                  icon: const Icon(Icons.videocam_outlined),
                  label: const Text('Save clip'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pill showing the active game (or "Desktop" when none is detected).
class _GameChip extends StatelessWidget {
  final String label;

  const _GameChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
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
                style: theme.textTheme.labelMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;

  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    const amber = Color(0xFFFFB74D);
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
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: amber),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: amber),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
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
        color: Theme.of(context).colorScheme.outline,
        shape: BoxShape.circle,
      ),
      child: const SizedBox(width: 10, height: 10),
    );
  }
}

/// A small pulsing red dot (with a soft glow) signaling that the replay
/// buffer is live.
class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  static const _red = Color(0xFFFF5470);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_controller),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _red,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: _red.withValues(alpha: 0.5),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: const SizedBox(width: 10, height: 10),
      ),
    );
  }
}
