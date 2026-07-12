import 'dart:io';

import 'package:flutter/material.dart';

import '../../coordinator/clip_coordinator.dart';

/// Top-of-home status bar: buffering indicator, active-game chip, the
/// "Save clip" action, and (when capture failed to start) an error banner.
class StatusStrip extends StatelessWidget {
  final ClipCoordinator coordinator;
  final String? captureError;

  const StatusStrip({required this.coordinator, this.captureError, super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (captureError != null) ...[
            _ErrorBanner(message: captureError!),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              const _PulseDot(),
              const SizedBox(width: 8),
              ValueListenableBuilder<String?>(
                valueListenable: coordinator.activeGame,
                builder: (context, gameId, _) {
                  final seconds = coordinator.settings
                      .configFor(gameId ?? 'desktop')
                      .bufferSeconds;
                  return Text('Buffering · $seconds s');
                },
              ),
              const SizedBox(width: 16),
              ValueListenableBuilder<String?>(
                valueListenable: coordinator.activeGame,
                builder: (context, gameId, _) =>
                    Chip(label: Text(gameId ?? 'Desktop')),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed:
                    captureError == null ? () => coordinator.onHotkey() : null,
                icon: const Icon(Icons.videocam_outlined),
                label: const Text('Save clip'),
              ),
            ],
          ),
        ],
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
    final text = Platform.isMacOS
        ? '$message\nGrant Screen Recording permission in System Settings → '
            'Privacy & Security'
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

/// A small pulsing red dot signaling that the replay buffer is live.
class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
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
      child: const DecoratedBox(
        decoration:
            BoxDecoration(color: Color(0xFFFF5470), shape: BoxShape.circle),
        child: SizedBox(width: 10, height: 10),
      ),
    );
  }
}
