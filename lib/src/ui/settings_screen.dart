import 'package:flutter/material.dart';

import '../hotkey/hotkey_descriptor.dart';
import '../settings/app_settings.dart';
import '../settings/game_config.dart';

/// Hotkey, default buffer length, and per-game overrides. `onChanged` is
/// called with the (mutated in place) [AppSettings] whenever a field commits
/// a valid value — the caller persists it and rebinds the hotkey.
class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  final Future<void> Function(AppSettings) onChanged;

  const SettingsScreen(
      {required this.settings, required this.onChanged, super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _hotkeyController;
  String? _hotkeyError;

  late int _bufferSeconds;
  late bool _customBuffer;
  late final TextEditingController _customBufferController;

  final Map<String, TextEditingController> _perGameControllers = {};

  @override
  void initState() {
    super.initState();
    _hotkeyController = TextEditingController(text: widget.settings.hotkey);
    _bufferSeconds = widget.settings.defaultBufferSeconds;
    _customBuffer = _bufferSeconds != 30 && _bufferSeconds != 60;
    _customBufferController = TextEditingController(text: '$_bufferSeconds');
  }

  @override
  void dispose() {
    _hotkeyController.dispose();
    _customBufferController.dispose();
    for (final c in _perGameControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(GameConfig cfg) =>
      _perGameControllers.putIfAbsent(cfg.gameId,
          () => TextEditingController(text: '${cfg.bufferSeconds}'));

  void _handleHotkeyChanged(String value) {
    if (HotkeyDescriptor.parse(value) == null) {
      setState(() => _hotkeyError = 'Invalid hotkey, e.g. "Alt+F10"');
      return;
    }
    setState(() => _hotkeyError = null);
    widget.settings.hotkey = value;
    widget.onChanged(widget.settings);
  }

  void _selectBuffer(int seconds) {
    setState(() {
      _bufferSeconds = seconds;
      _customBuffer = false;
    });
    widget.settings.defaultBufferSeconds = seconds;
    widget.onChanged(widget.settings);
  }

  void _selectCustom() => setState(() => _customBuffer = true);

  void _handleCustomBufferChanged(String value) {
    final clamped =
        (int.tryParse(value) ?? _bufferSeconds).clamp(5, 300).toInt();
    setState(() {
      _bufferSeconds = clamped;
      _customBufferController.text = '$clamped';
    });
    widget.settings.defaultBufferSeconds = clamped;
    widget.onChanged(widget.settings);
  }

  void _handleGameBufferChanged(GameConfig cfg, String value) {
    final clamped =
        (int.tryParse(value) ?? cfg.bufferSeconds).clamp(5, 300).toInt();
    cfg.bufferSeconds = clamped;
    widget.settings.setConfig(cfg);
    widget.onChanged(widget.settings);
  }

  @override
  Widget build(BuildContext context) {
    final configs = widget.settings.allConfigs.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Hotkey', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _hotkeyController,
            decoration: InputDecoration(
              hintText: 'Alt+F10',
              errorText: _hotkeyError,
            ),
            onChanged: _handleHotkeyChanged,
          ),
          const SizedBox(height: 24),
          Text('Default buffer',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '30', label: Text('30 s')),
              ButtonSegment(value: '60', label: Text('60 s')),
              ButtonSegment(value: 'custom', label: Text('Custom')),
            ],
            selected: {_customBuffer ? 'custom' : '$_bufferSeconds'},
            onSelectionChanged: (selection) {
              final value = selection.first;
              if (value == 'custom') {
                _selectCustom();
              } else {
                _selectBuffer(int.parse(value));
              }
            },
          ),
          if (_customBuffer) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _customBufferController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Seconds (5-300)'),
              onChanged: _handleCustomBufferChanged,
            ),
          ],
          if (configs.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Per-game', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final cfg in configs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(cfg.gameId)),
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _controllerFor(cfg),
                        keyboardType: TextInputType.number,
                        decoration:
                            const InputDecoration(labelText: 'Buffer (s)'),
                        onChanged: (value) =>
                            _handleGameBufferChanged(cfg, value),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
