import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../hotkey/key_capture.dart';
import '../obs/app_info.dart';
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

  /// Applications with at least one on-screen window, as an alternative
  /// capture target to a whole display. The "Capture application" dropdown
  /// is hidden entirely when this is empty. Defaults to empty so existing
  /// callers/tests that don't care about app capture don't need to wire it.
  final List<AppInfo> capturableApps;

  /// Called with `true` when the hotkey recorder starts listening and
  /// `false` whenever it stops (a captured combo, Escape, clicking away, or
  /// the field being torn down mid-record) — so the caller can suspend the
  /// live system-wide hotkey while recording. Without this, the
  /// currently-bound combo stays live during recording: pressing it
  /// mid-record both fires a spurious save and, since the OS owns it at
  /// system scope, may never reach this widget at all — making it
  /// impossible to re-record the hotkey currently in use.
  ///
  /// On a successful capture, [onChanged] (which mutates `settings.hotkey`
  /// synchronously before doing anything async) is always called *before*
  /// this callback fires with `false`. A caller that re-binds off the live
  /// `settings` object — as `onChanged` itself typically also does — will
  /// therefore see the newly-captured value on both calls, not a stale one;
  /// the extra bind is redundant but harmless (re-registering the same
  /// combo twice), not a "rebind the old value over the new one" bug.
  /// Optional so existing callers/tests don't need to wire it.
  final Future<void> Function(bool recording)? onHotkeyRecording;

  const SettingsScreen({
    required this.settings,
    required this.onChanged,
    required this.displays,
    this.capturableApps = const [],
    this.onHotkeyRecording,
    super.key,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late int _bufferSeconds;
  late bool _customBuffer;
  late final TextEditingController _customBufferController;

  final Map<String, TextEditingController> _perGameControllers = {};

  @override
  void initState() {
    super.initState();
    _bufferSeconds = widget.settings.defaultBufferSeconds;
    _customBuffer = _bufferSeconds != 30 && _bufferSeconds != 60;
    _customBufferController = TextEditingController(text: '$_bufferSeconds');
  }

  @override
  void dispose() {
    _customBufferController.dispose();
    for (final c in _perGameControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(GameConfig cfg) =>
      _perGameControllers.putIfAbsent(cfg.gameId,
          () => TextEditingController(text: '${cfg.bufferSeconds}'));

  /// Called by [_HotkeyRecorderField] once a combo is captured (or the
  /// field is cleared, [value] == ''). The recorder only ever produces
  /// combos [HotkeyDescriptor] already accepts, so no validation needed
  /// here — unlike the old free-text field.
  void _handleHotkeyChanged(String value) {
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

  /// The bundle id the dropdown should show as selected: the saved choice
  /// only if it's one of the currently-listed [widget.capturableApps] —
  /// unlike [_selectedDisplayUuid], falling back to null ("Entire display")
  /// is always valid here (it's a real menu item, not a
  /// [DropdownButtonFormField] with no matching value), so a saved bundle
  /// id for an app that isn't currently running just shows as "Entire
  /// display" without touching the persisted setting.
  String? _selectedAppBundleId() {
    final saved = widget.settings.captureAppBundleId;
    return saved != null &&
            widget.capturableApps.any((a) => a.bundleId == saved)
        ? saved
        : null;
  }

  void _handleAppChanged(String? bundleId) {
    widget.settings.captureAppBundleId = bundleId;
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
                if (widget.capturableApps.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text('Capture application',
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String?>(
                    initialValue: _selectedAppBundleId(),
                    items: [
                      const DropdownMenuItem<String?>(
                        child: Text('Entire display'),
                      ),
                      for (final app in widget.capturableApps)
                        DropdownMenuItem<String?>(
                          value: app.bundleId,
                          child: Text(app.name),
                        ),
                    ],
                    onChanged: _handleAppChanged,
                  ),
                ],
              ],
            ),
          ),
          _Section(
            title: 'Hotkey',
            child: _HotkeyRecorderField(
              value: widget.settings.hotkey,
              onChanged: _handleHotkeyChanged,
              onRecording: widget.onHotkeyRecording,
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

/// A press-to-record hotkey field: click it, then press the combo — no
/// typing. Typing a hotkey doesn't make sense to a user who doesn't know
/// the descriptor grammar ("Alt+F10"); pressing the actual keys does.
///
/// There's deliberately no "edit as text" fallback: every combo the
/// recorder can produce is exactly the set [HotkeyDescriptor] accepts (same
/// physical-key map [HotkeyService] binds), so text entry couldn't reach
/// any state the recorder can't. The one thing text entry offered besides
/// setting a combo — clearing it — is a dedicated clear button here instead.
class _HotkeyRecorderField extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;

  /// See [SettingsScreen.onHotkeyRecording] — forwarded as-is.
  final Future<void> Function(bool recording)? onRecording;

  const _HotkeyRecorderField({
    required this.value,
    required this.onChanged,
    this.onRecording,
  });

  @override
  State<_HotkeyRecorderField> createState() => _HotkeyRecorderFieldState();
}

class _HotkeyRecorderFieldState extends State<_HotkeyRecorderField> {
  final _focusNode = FocusNode(debugLabel: 'hotkey-recorder');
  bool _listening = false;
  String? _hint;

  @override
  void dispose() {
    // Covers navigating away from Settings mid-record (e.g. back button) —
    // the same "recording ended without a capture" case as Escape/click-away,
    // just via widget teardown instead of a key/focus event.
    if (_listening) widget.onRecording?.call(false);
    _focusNode.dispose();
    super.dispose();
  }

  void _startListening() {
    setState(() {
      _listening = true;
      _hint = null;
    });
    _focusNode.requestFocus();
    widget.onRecording?.call(true);
  }

  /// Escape or clicking away — recording ends with nothing captured, so the
  /// previously-bound hotkey needs to come back.
  void _cancel() {
    if (!mounted) return;
    setState(() {
      _listening = false;
      _hint = null;
    });
    widget.onRecording?.call(false);
  }

  void _clear() {
    setState(() {
      _listening = false;
      _hint = null;
    });
    widget.onChanged('');
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_listening || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }

    final keyboard = HardwareKeyboard.instance;
    final capture = mapKeyDownToHotkey(
      event,
      alt: keyboard.isAltPressed,
      control: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      meta: keyboard.isMetaPressed,
    );
    switch (capture.status) {
      case HotkeyCaptureStatus.ignored:
        // Modifier held on its own, or an unsupported key — stay listening.
        return KeyEventResult.handled;
      case HotkeyCaptureStatus.rejectedNoModifier:
        setState(() => _hint = 'Hold a modifier too, e.g. Ctrl or Alt');
        return KeyEventResult.handled;
      case HotkeyCaptureStatus.accepted:
        final descriptor = capture.descriptor!.toString();
        setState(() {
          _listening = false;
          _hint = null;
        });
        // Only onChanged here: its handler already rebinds the (new) hotkey.
        // Also firing onRecording(false) would start a SECOND concurrent
        // unregisterAll+register cycle; if the two interleave, the hotkey
        // ends up registered twice and one press saves two clips. Cancel
        // paths (Escape/focus loss/dispose) still fire onRecording(false),
        // since no onChanged rebind happens there.
        widget.onChanged(descriptor);
        return KeyEventResult.handled;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = _listening
        ? 'Press keys…'
        : (widget.value.isEmpty ? 'Click to set a hotkey' : widget.value);
    final textColor =
        _listening ? theme.colorScheme.primary : theme.colorScheme.onSurface;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Focus(
          focusNode: _focusNode,
          onKeyEvent: _handleKeyEvent,
          onFocusChange: (hasFocus) {
            if (!hasFocus && _listening) _cancel();
          },
          child: Material(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _startListening,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _listening
                        ? theme.colorScheme.primary
                        : Colors.white.withValues(alpha: 0.08),
                    width: _listening ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        display,
                        style: TextStyle(
                            color: textColor, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (!_listening && widget.value.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear hotkey',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _clear,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_hint != null) ...[
          const SizedBox(height: 6),
          Text(_hint!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
        ],
      ],
    );
  }
}
