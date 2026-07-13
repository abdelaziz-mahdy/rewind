import 'package:flutter/material.dart';

import '../hotkey/hotkey_descriptor.dart';
import '../obs/display_info.dart';
import '../settings/app_settings.dart';
import '../settings/game_config.dart';
import 'theme.dart';

/// Hotkey, default buffer length, capture display, and per-game overrides —
/// grouped into labeled sections (Capture / Hotkey / Per-game). `onChanged`
/// is called with the (mutated in place) [AppSettings] whenever a field
/// commits a valid value — the caller persists it and rebinds the hotkey /
/// re-targets the capture engine.
class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  final Future<void> Function(AppSettings) onChanged;

  /// Connected displays the user can pick as the capture source. The
  /// "Capture display" section is hidden entirely when this is empty.
  final List<DisplayInfo> displays;

  const SettingsScreen({
    required this.settings,
    required this.onChanged,
    required this.displays,
    super.key,
  });

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
    setState(() => _bufferSeconds = clamped);
    // Only rewrite the field when the clamp actually changed the value —
    // otherwise re-setting matching text mid-typing jumps the caret to the
    // end on every keystroke.
    if (_customBufferController.text != '$clamped') {
      _customBufferController.text = '$clamped';
    }
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

  /// The uuid the dropdown should show as selected: the explicit choice if
  /// one was saved, else whichever display libobs reports as main, else the
  /// first display — never null while [widget.displays] is non-empty, since
  /// [DropdownButtonFormField] requires its value to match an item.
  String _selectedDisplayUuid() {
    final saved = widget.settings.captureDisplayUuid;
    if (saved != null && widget.displays.any((d) => d.uuid == saved)) {
      return saved;
    }
    final main = widget.displays.where((d) => d.isMain);
    return (main.isNotEmpty ? main.first : widget.displays.first).uuid;
  }

  void _handleDisplayChanged(String? uuid) {
    if (uuid == null) return;
    widget.settings.captureDisplayUuid = uuid;
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
          _Section(
            title: 'Capture',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Default buffer',
                    style: Theme.of(context).textTheme.bodyMedium),
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
                    decoration:
                        const InputDecoration(labelText: 'Seconds (5-300)'),
                    onChanged: _handleCustomBufferChanged,
                  ),
                ],
                if (widget.displays.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text('Capture display',
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedDisplayUuid(),
                    items: [
                      for (var i = 0; i < widget.displays.length; i++)
                        DropdownMenuItem(
                          value: widget.displays[i].uuid,
                          child: Text(_displayLabel(i, widget.displays[i])),
                        ),
                    ],
                    onChanged: _handleDisplayChanged,
                  ),
                ],
              ],
            ),
          ),
          _Section(
            title: 'Hotkey',
            child: TextField(
              controller: _hotkeyController,
              decoration: InputDecoration(
                hintText: 'Alt+F10',
                errorText: _hotkeyError,
              ),
              onChanged: _handleHotkeyChanged,
            ),
          ),
          if (configs.isNotEmpty)
            _Section(
              title: 'Per-game',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                              decoration: const InputDecoration(
                                  labelText: 'Buffer (s)'),
                              onChanged: (value) =>
                                  _handleGameBufferChanged(cfg, value),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _displayLabel(int index, DisplayInfo d) =>
      'Display ${index + 1} — ${d.width}×${d.height}'
      '${d.isMain ? ' (Main)' : ''}';
}

/// A labeled, bordered grouping card — the settings screen's unit of
/// structure so "Capture / Hotkey / Per-game" read as distinct, scannable
/// sections instead of one long form.
class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.fromBorderSide(hairlineBorder()),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title.toUpperCase(),
            style: theme.textTheme.microLabel
                .copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
