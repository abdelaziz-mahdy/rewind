import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../clip/clip_library.dart';
import '../coordinator/clip_coordinator.dart';
import '../log/log.dart';
import 'widgets/clip_tile.dart';
import 'widgets/status_strip.dart';

/// The main window: status strip up top, clip library below.
class HomeScreen extends StatefulWidget {
  final ClipCoordinator coordinator;
  final ClipLibrary library;
  final String? captureError;

  /// Live buffer state (toggled by the tray's pause/resume). When null the
  /// strip assumes the buffer is running iff capture came up without error.
  final ValueListenable<bool>? bufferActive;
  final String hotkeyLabel;
  final VoidCallback onOpenSettings;

  const HomeScreen({
    required this.coordinator,
    required this.library,
    this.captureError,
    this.bufferActive,
    required this.hotkeyLabel,
    required this.onOpenSettings,
    super.key,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    widget.coordinator.lastSaveError.addListener(_showSaveErrorIfAny);
  }

  @override
  void dispose() {
    widget.coordinator.lastSaveError.removeListener(_showSaveErrorIfAny);
    super.dispose();
  }

  void _showSaveErrorIfAny() {
    final message = widget.coordinator.lastSaveError.value;
    if (message == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Theme.of(context).colorScheme.error,
      content: Text("Couldn't save clip: $message"),
    ));
  }

  void _openLogs() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => TalkerScreen(
        talker: talker,
        theme: TalkerScreenTheme.fromTheme(Theme.of(context)),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rewind'),
        actions: [
          IconButton(
            tooltip: 'Logs',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: _openLogs,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          StatusStrip(
            coordinator: widget.coordinator,
            captureError: widget.captureError,
            bufferActive: widget.bufferActive,
          ),
          const Divider(height: 1),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.library,
              builder: (context, _) {
                if (widget.library.all.isEmpty) {
                  return _EmptyLibrary(hotkeyLabel: widget.hotkeyLabel);
                }
                final clips = List.of(widget.library.all)
                  ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
                return ListView.builder(
                  itemCount: clips.length,
                  itemBuilder: (context, i) =>
                      ClipTile(clip: clips[i], library: widget.library),
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
