import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../clip/clip_library.dart';
import '../clip/clips_dir.dart';
import '../hotkey/key_capture.dart';
import '../obs/app_info.dart';
import '../obs/display_info.dart';
import '../settings/app_settings.dart';
import 'onboarding_screen.dart';
import 'system_settings.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart' show formatSize;
import 'widgets/setting_row.dart';

/// Hotkey, default buffer length, capture display/app, and the follow-the-
/// game toggle — grouped into tabbed sections (Capture / Hotkey / Quality /
/// Storage / About), one built at a time. Per-game overrides now live inline
/// in each game's hub (`game_hub_screen.dart`) instead of a tab here.
/// `onChanged` is called with the (mutated in place) [AppSettings] whenever
/// a field commits a valid value — the caller persists it and rebinds the
/// hotkey / re-targets the capture engine.
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

  /// The clip library, for the Storage section's live usage readout
  /// ("31 clips · 1.2 GB"). Optional — tests and callers that don't care
  /// about storage just lose the readout, not the section.
  final ClipLibrary? library;

  const SettingsScreen({
    required this.settings,
    required this.onChanged,
    required this.displays,
    this.capturableApps = const [],
    this.onHotkeyRecording,
    this.library,
    super.key,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late int _bufferSeconds;
  late bool _customBuffer;
  late final TextEditingController _customBufferController;
  late final TextEditingController _maxStorageController;
  late final TextEditingController _maxAgeController;

  // Real tabs, one section built at a time — replaces the old sticky
  // jump-nav over one long scroll. Only [_selectedTab]'s section widget is
  // constructed; switching tabs is a plain setState, not a scroll animation.
  static const _tabs = ['Capture', 'Hotkey', 'Quality', 'Storage', 'About'];
  String _selectedTab = _tabs.first;

  @override
  void initState() {
    super.initState();
    _bufferSeconds = widget.settings.defaultBufferSeconds;
    // Must list every preset segment above, or a saved value that HAS a
    // segment (15) falls through to "Custom" and no segment ever highlights.
    _customBuffer =
        _bufferSeconds != 15 && _bufferSeconds != 30 && _bufferSeconds != 60;
    _customBufferController = TextEditingController(text: '$_bufferSeconds');
    _maxStorageController = TextEditingController(
        text: widget.settings.maxStorageGb?.toString() ?? '');
    _maxAgeController = TextEditingController(
        text: widget.settings.maxClipAgeDays?.toString() ?? '');
  }

  @override
  void dispose() {
    _customBufferController.dispose();
    _maxStorageController.dispose();
    _maxAgeController.dispose();
    super.dispose();
  }

  /// Blank commits null (that limit off); only valid positive integers
  /// commit otherwise — mid-typing garbage neither persists nor fights the
  /// caret by rewriting the field.
  void _handleLimitChanged(String value, void Function(int?) write) {
    final t = value.trim();
    if (t.isEmpty) {
      write(null);
    } else {
      final parsed = int.tryParse(t);
      if (parsed == null || parsed < 1) return;
      write(parsed);
    }
    widget.onChanged(widget.settings);
  }

  Future<void> _pickClipsDir() async {
    final path = await getDirectoryPath();
    if (path == null) return; // cancelled
    setState(() => widget.settings.clipsDirPath = path);
    await widget.onChanged(widget.settings);
  }

  void _resetClipsDir() {
    setState(() => widget.settings.clipsDirPath = null);
    widget.onChanged(widget.settings);
  }

  /// Called by [_HotkeyRecorderField] once a combo is captured (or the
  /// field is cleared, [value] == ''). The recorder only ever produces
  /// combos [HotkeyDescriptor] already accepts, so no validation needed
  /// here — unlike the old free-text field.
  void _handleHotkeyChanged(String value) {
    widget.settings.hotkey = value;
    widget.onChanged(widget.settings);
  }

  /// Same as [_handleHotkeyChanged], for the independent record-toggle
  /// hotkey field.
  void _handleRecordHotkeyChanged(String value) {
    widget.settings.recordHotkey = value;
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

  /// See §3.6's "Follow the game" toggle: writes
  /// [AppSettings.autoSwitchCapture] straight through, same as every other
  /// field on this screen.
  void _handleAutoSwitchChanged(bool value) {
    widget.settings.autoSwitchCapture = value;
    setState(() {});
    widget.onChanged(widget.settings);
  }

  void _handleMicrophoneChanged(bool value) {
    widget.settings.captureMicrophone = value;
    setState(() {});
    widget.onChanged(widget.settings);
  }

  void _handleAudioModeChanged(AudioMode mode) {
    widget.settings.audioMode = mode;
    setState(() {});
    widget.onChanged(widget.settings);
  }

  void _handleFpsChanged(int fps) {
    widget.settings.captureFps = fps;
    setState(() {});
    widget.onChanged(widget.settings);
  }

  /// [maxHeight] null = source resolution.
  void _handleResolutionChanged(int? maxHeight) {
    widget.settings.captureMaxHeight = maxHeight;
    setState(() {});
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
    return Scaffold(
      // Left-aligned, not centred: everything below it (tabs, labels, rows)
      // reads off the left edge, so a centred title puts a second, competing
      // axis on the screen and there's no single edge to scan from.
      appBar: AppBar(title: const Text('Settings'), centerTitle: false),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(border: Border(bottom: hairlineBorder())),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final t in _tabs)
                    _SettingsTabButton(
                      key: ValueKey('settingsTab:$t'),
                      label: t,
                      selected: t == _selectedTab,
                      onTap: () => setState(() => _selectedTab = t),
                    ),
                ],
              ),
            ),
          ),
          // Only the selected tab's section is built — switching tabs is a
          // plain setState, not a scroll animation, and the other four
          // sections' widgets (and their controllers/state) simply don't
          // exist until selected.
          Expanded(
            child: switch (_selectedTab) {
              'Capture' => _captureTab(context),
              'Hotkey' => _hotkeyTab(context),
              'Quality' => _qualityTab(context),
              'Storage' => _storageTab(context),
              'About' => _aboutTab(context),
              _ => const SizedBox.shrink(),
            },
          ),
        ],
      ),
    );
  }

  /// Wraps a tab's content in its own scroll view (so a small window still
  /// works even though each section is now short enough not to need one on a
  /// normal window) and caps + left-aligns the column beside the rail,
  /// instead of centering it in the leftover window width.
  Widget _tabContent(Widget child) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: settingsMaxContentWidth),
          child: child,
        ),
      ),
    );
  }

  Widget _captureTab(BuildContext context) {
    return _tabContent(SettingRows([
      SettingRow(
        label: 'Default buffer',
        // Same choices as a game hub's per-game override (game_hub_screen.
        // dart): the global default offered no 15 s while a per-game
        // override did, so the shortest buffer the app advertises ("the
        // last 15-60 s") couldn't be set as the default.
        control: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: '15', label: Text('15 s')),
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
      ),
      if (_customBuffer)
        SettingRow(
          label: 'Custom buffer',
          control: SizedBox(
            width: 200,
            child: TextField(
              controller: _customBufferController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Seconds (5-300)'),
              onChanged: _handleCustomBufferChanged,
            ),
          ),
        ),
      if (widget.displays.isNotEmpty)
        SettingRow(
          label: 'Capture display',
          control: SizedBox(
            width: 300,
            child: DropdownButtonFormField<String>(
              initialValue: _selectedDisplayUuid(),
              isExpanded: true,
              items: [
                for (var i = 0; i < widget.displays.length; i++)
                  DropdownMenuItem(
                    value: widget.displays[i].uuid,
                    child: Text(_displayLabel(i, widget.displays[i])),
                  ),
              ],
              onChanged: _handleDisplayChanged,
            ),
          ),
        ),
      if (widget.capturableApps.isNotEmpty)
        SettingRow(
          label: 'Capture application',
          control: SizedBox(
            width: 300,
            child: DropdownButtonFormField<String?>(
              initialValue: _selectedAppBundleId(),
              isExpanded: true,
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
          ),
        ),
      SettingRow(
        label: 'Follow the game',
        hint: Text(
          "Switch capture to a game's window when it launches",
          style: Theme.of(context).textTheme.bodyMuted,
        ),
        control: Switch(
          key: const ValueKey('autoSwitchCaptureSwitch'),
          value: widget.settings.autoSwitchCapture,
          onChanged: _handleAutoSwitchChanged,
        ),
      ),
      SettingRow(
        label: 'Capture microphone',
        hint: Text(
          'Mix your mic into clips and recordings, alongside system audio',
          style: Theme.of(context).textTheme.bodyMuted,
        ),
        control: Switch(
          key: const ValueKey('captureMicrophoneSwitch'),
          value: widget.settings.captureMicrophone,
          onChanged: _handleMicrophoneChanged,
        ),
      ),
    ]));
  }

  Widget _hotkeyTab(BuildContext context) {
    return _tabContent(SettingRows([
      SettingRow(
        label: 'Save clip',
        control: SizedBox(
          width: 300,
          child: _HotkeyRecorderField(
            key: const ValueKey('saveHotkeyField'),
            value: widget.settings.hotkey,
            onChanged: _handleHotkeyChanged,
            onRecording: widget.onHotkeyRecording,
          ),
        ),
      ),
      SettingRow(
        label: 'Record',
        control: SizedBox(
          width: 300,
          child: _HotkeyRecorderField(
            key: const ValueKey('recordHotkeyField'),
            value: widget.settings.recordHotkey,
            onChanged: _handleRecordHotkeyChanged,
            onRecording: widget.onHotkeyRecording,
          ),
        ),
      ),
    ]));
  }

  Widget _qualityTab(BuildContext context) {
    return _tabContent(SettingRows([
      SettingRow(
        label: 'Framerate',
        control: SegmentedButton<int>(
          key: const ValueKey('fpsSegments'),
          segments: const [
            ButtonSegment(value: 30, label: Text('30 fps')),
            ButtonSegment(value: 60, label: Text('60 fps')),
          ],
          selected: {widget.settings.captureFps},
          onSelectionChanged: (s) => _handleFpsChanged(s.first),
        ),
      ),
      SettingRow(
        label: 'Resolution',
        control: SegmentedButton<int>(
          key: const ValueKey('resolutionSegments'),
          // 0 stands for "source" (null maxHeight); the segments map to the
          // output-height cap.
          segments: const [
            ButtonSegment(value: 0, label: Text('Source')),
            ButtonSegment(value: 1440, label: Text('1440p')),
            ButtonSegment(value: 1080, label: Text('1080p')),
            ButtonSegment(value: 720, label: Text('720p')),
          ],
          selected: {widget.settings.captureMaxHeight ?? 0},
          onSelectionChanged: (s) =>
              _handleResolutionChanged(s.first == 0 ? null : s.first),
        ),
        footnote: 'Higher framerate and resolution mean smoother, sharper '
            'clips but more CPU and disk. Applies on next launch.',
      ),
      SettingRow(
        label: 'Game / system audio',
        control: SegmentedButton<AudioMode>(
          key: const ValueKey('audioModeSegments'),
          segments: const [
            ButtonSegment(value: AudioMode.off, label: Text('None')),
            ButtonSegment(value: AudioMode.app, label: Text('Game only')),
            ButtonSegment(value: AudioMode.all, label: Text('All apps')),
          ],
          selected: {widget.settings.audioMode},
          onSelectionChanged: (s) => _handleAudioModeChanged(s.first),
        ),
        footnote: switch (widget.settings.audioMode) {
          AudioMode.off =>
            'No system audio. Clips are silent unless the mic is on.',
          AudioMode.app =>
            "Only the captured game/app's sound (no Discord, music, etc.). "
                'Requires a specific app as the capture source.',
          AudioMode.all => "Every app's sound (desktop audio).",
        },
      ),
    ]));
  }

  Widget _storageTab(BuildContext context) {
    return _tabContent(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.library case final lib?) ...[
          ListenableBuilder(
            listenable: lib,
            builder: (context, _) => Text(
              '${lib.all.length} clips · ${formatSize(lib.totalBytes)}',
              style: Theme.of(context).textTheme.bodyMuted,
            ),
          ),
          const SizedBox(height: 16),
        ],
        SettingRows([
          SettingRow(
            label: 'Max storage (GB)',
            control: SizedBox(
              width: 200,
              child: TextField(
                key: const ValueKey('maxStorageField'),
                controller: _maxStorageController,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(hintText: 'Blank = unlimited'),
                onChanged: (v) => _handleLimitChanged(
                    v, (gb) => widget.settings.maxStorageGb = gb),
              ),
            ),
          ),
          SettingRow(
            label: 'Delete clips older than (days)',
            control: SizedBox(
              width: 200,
              child: TextField(
                key: const ValueKey('maxAgeField'),
                controller: _maxAgeController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: 'Blank = never'),
                onChanged: (v) => _handleLimitChanged(
                    v, (days) => widget.settings.maxClipAgeDays = days),
              ),
            ),
            footnote: 'Oldest clips are removed first when a limit is hit. '
                'Protected clips are never auto-deleted.',
          ),
          SettingRow(
            label: 'Recordings folder',
            hint: Text(
              resolveClipsDirPath(widget.settings.clipsDirPath),
              key: const ValueKey('clipsDirLabel'),
              style: Theme.of(context).textTheme.bodyMuted,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
            control: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: const ValueKey('chooseClipsDirButton'),
                  onPressed: _pickClipsDir,
                  child: const Text('Choose…'),
                ),
                if (widget.settings.clipsDirPath != null)
                  TextButton(
                    key: const ValueKey('resetClipsDirButton'),
                    onPressed: _resetClipsDir,
                    child: const Text('Reset'),
                  ),
              ],
            ),
            footnote:
                'Applies on next launch. Existing clips stay where they are.',
          ),
        ]),
      ],
    ));
  }

  /// About is prose + buttons + the legal disclaimer, not label→control
  /// pairs, so it deliberately does NOT use [_SettingRow] — a normal column,
  /// same shape as before.
  Widget _aboutTab(BuildContext context) {
    return _tabContent(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Rewind — open-source instant replay for macOS & Windows. GPLv3.',
          style: Theme.of(context).textTheme.bodyMuted,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('showOnboardingButton'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => OnboardingScreen(
                    settings: widget.settings,
                    onChanged: widget.onChanged,
                    onDone: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
              icon: const Icon(Icons.school_outlined, size: 18),
              label: const Text('Getting-started guide'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('githubRepoButton'),
              onPressed: () => openUrl(kRepoUrl),
              icon: const Icon(Icons.code_outlined, size: 18),
              label: const Text('GitHub repo'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('reportIssueButton'),
              onPressed: () => openUrl('$kRepoUrl/issues'),
              icon: const Icon(Icons.bug_report_outlined, size: 18),
              label: const Text('Report an issue'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Required, verbatim, by Riot's Developer API Policy ("You must post
        // the following legal boilerplate to your product in a location
        // that is readily visible to players") because Rewind reads
        // League's Live Client Data API and shows Data Dragon art. Do not
        // reword or hide this. See docs/COMPLIANCE.md.
        Text(
          kRiotDisclaimer,
          key: const ValueKey('riotDisclaimer'),
          style: Theme.of(context).textTheme.bodyMuted,
        ),
      ],
    ));
  }

  static String _displayLabel(int index, DisplayInfo d) =>
      'Display ${index + 1} — ${d.width}×${d.height}'
      '${d.isMain ? ' (Main)' : ''}';
}

/// One tab button in the top strip. Selection is signalled by more than
/// colour: a bottom indicator bar (present/absent — a real shape cue, not
/// just a hue change) plus a bolder weight, mirroring the rail's own
/// selected-row treatment (`nav_rail.dart`'s `_NavItem`/`_GameRow`) and the
/// event-matrix chips' "add a check, don't just recolour" fix.
class _SettingsTabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SettingsTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
          margin: const EdgeInsets.only(right: 24),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? tokens.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.label.copyWith(
              color: selected ? tokens.accent : tokens.textMuted,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
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
    super.key,
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
            borderRadius:
                BorderRadius.circular(context.rewindTokens.radiusControl),
            child: InkWell(
              borderRadius:
                  BorderRadius.circular(context.rewindTokens.radiusControl),
              onTap: _startListening,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius:
                      BorderRadius.circular(context.rewindTokens.radiusControl),
                  border: Border.all(
                    color: _listening
                        ? theme.colorScheme.primary
                        : context.rewindTokens.hairline,
                    width: _listening ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        display,
                        style: theme.textTheme.body.copyWith(
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
              style: theme.textTheme.label
                  .copyWith(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}
