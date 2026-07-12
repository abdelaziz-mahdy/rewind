import 'package:flutter/material.dart';

import '../clip/clip_library.dart';
import '../coordinator/clip_coordinator.dart';
import 'widgets/clip_tile.dart';
import 'widgets/status_strip.dart';

/// The main window: status strip up top, clip library below.
class HomeScreen extends StatelessWidget {
  final ClipCoordinator coordinator;
  final ClipLibrary library;
  final String? captureError;
  final String hotkeyLabel;
  final VoidCallback onOpenSettings;

  const HomeScreen({
    required this.coordinator,
    required this.library,
    this.captureError,
    required this.hotkeyLabel,
    required this.onOpenSettings,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rewind'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: onOpenSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          StatusStrip(coordinator: coordinator, captureError: captureError),
          const Divider(height: 1),
          Expanded(
            child: ListenableBuilder(
              listenable: library,
              builder: (context, _) {
                if (library.all.isEmpty) {
                  return _EmptyLibrary(hotkeyLabel: hotkeyLabel);
                }
                final clips = List.of(library.all)
                  ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
                return ListView.builder(
                  itemCount: clips.length,
                  itemBuilder: (context, i) =>
                      ClipTile(clip: clips[i], library: library),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  final String hotkeyLabel;

  const _EmptyLibrary({required this.hotkeyLabel});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.video_library_outlined,
              size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text('No clips yet — press $hotkeyLabel'),
        ],
      ),
    );
  }
}
