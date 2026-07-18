import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../clip/clips_dir.dart';
import '../events/game_event.dart';
import '../hotkey/key_capture.dart';
import '../log/log.dart';
import '../obs/app_info.dart';
import '../obs/audio_input_info.dart';
import '../obs/display_info.dart';
import '../settings/app_settings.dart';
import '../settings/game_config.dart';
import '../settings/video_preset.dart';
import 'game_directory.dart';
import 'onboarding_screen.dart';
import 'system_settings.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart' show formatSize;
import 'widgets/event_matrix.dart';
import 'widgets/game_tile_avatar.dart';

/// Full-page Settings (the research-locked "variant G" design, see
/// docs/superpowers/specs — settings covers the whole window; its own left
/// sidebar (§`_SettingsSidebar`) is the ONLY navigation while it's open, the
/// app rail is hidden by the caller (`shell.dart`)). One GENERAL section
/// (Capture / Hotkeys / Storage / About), plus one MY GAMES page per
/// [gameEntries] entry ([_GameSettingsPage]) — overrides for that game only,
/// everything else falling back to the GENERAL Capture page's defaults.
///
/// `onChanged` is called with the (mutated in place) [AppSettings] whenever
/// a field commits a valid value — the caller persists it and rebinds the
/// hotkey / re-targets the capture engine.
class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  final Future<void> Function(AppSettings) onChanged;

  /// Connected displays the user can pick as the capture source. The
  /// "Capture display" row is hidden entirely when this is empty.
  final List<DisplayInfo> displays;

  /// Applications with at least one on-screen window, as an alternative
  /// capture target to a whole display. The "Capture application" dropdown
  /// is hidden entirely when this is empty. Defaults to empty so existing
  /// callers/tests that don't care about app capture don't need to wire it.
  final List<AppInfo> capturableApps;

  /// Audio INPUT devices (microphones) the user can pick as the mic source.
  /// The "Microphone" sub-row under "Record my microphone" is hidden
  /// entirely when this is empty (honest degradation on platforms where
  /// enumeration isn't implemented yet — see `CaptureEngine.listAudioInputs`).
  /// Defaults to empty so existing callers/tests that don't care about mic
  /// device picking don't need to wire it.
  final List<AudioInputInfo> audioInputs;

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

  /// Runs the retention policy over the library NOW (the same enforcement
  /// the app runs after saves and on its periodic sweep) and returns the
  /// clips it removed, so the Storage page can report what a "Clean up now"
  /// actually freed. Optional — the row is absent when not wired (tests,
  /// callers without a StorageManager).
  final Future<List<Clip>> Function()? onCleanUpStorage;

  /// The round ✕ button's action: returns to whatever destination was
  /// showing before Settings was opened. Optional so existing callers/tests
  /// that don't care about closing don't need to wire it — the button still
  /// renders (it's a fixed part of the full-page chrome) but no-ops.
  final VoidCallback? onClose;

  /// The MY GAMES sidebar section's rows, one per entry, in the exact order
  /// shown — build with `buildGameDirectory(...)` the same way the rail
  /// does (see `game_directory.dart`'s doc on the League two-gameId merge)
  /// so the two navs never disagree on naming/icons/ordering. Empty (the
  /// default) hides the MY GAMES header entirely rather than showing it
  /// with nothing under it.
  final List<GameEntry> gameEntries;

  /// When set to a [gameEntries] id, Settings opens directly on that game's
  /// page instead of the default Capture page — used by the game hub's
  /// summary card to jump straight to "this game's overrides". Ignored (falls
  /// back to Capture) if it doesn't match any [gameEntries] entry.
  final String? initialGameId;

  const SettingsScreen({
    required this.settings,
    required this.onChanged,
    required this.displays,
    this.capturableApps = const [],
    this.audioInputs = const [],
    this.onHotkeyRecording,
    this.library,
    this.onCleanUpStorage,
    this.onClose,
    this.gameEntries = const [],
    this.initialGameId,
    super.key,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// The sidebar's GENERAL section ids — also the `settingsTab:<id>` key
/// suffix, kept as "Hotkey" (singular) even though its label is "Hotkeys" to
/// minimize churn against the pre-redesign key.
enum _SettingsPage { capture, hotkey, storage, about }

class _SettingsScreenState extends State<SettingsScreen> {
  late int _bufferSeconds;
  late bool _customBuffer;
  late final TextEditingController _customBufferController;
  late final TextEditingController _maxStorageController;
  late final TextEditingController _maxAgeController;
  late final FocusNode _maxStorageFocus;
  late final FocusNode _maxAgeFocus;

  /// The current GENERAL page, or null while a MY GAMES page
  /// ([_selectedGameId]) is showing — exactly one of the two is non-null at
  /// any time (see [_selectGeneralPage]/[_selectGame]).
  _SettingsPage? _selectedGeneralPage = _SettingsPage.capture;
  String? _selectedGameId;

  /// Whether the Custom video-preset card has been tapped this session —
  /// reveals the Resolution/Framerate rows without writing to [AppSettings]
  /// (see [_selectVideoPreset]). Independent of [_currentVideoPreset]: once
  /// the user actually edits Resolution/Framerate away from every named
  /// tier, [_currentVideoPreset] itself derives to [VideoPreset.custom] and
  /// keeps the rows open on its own.
  bool _customVideoExpanded = false;

  /// The Capture page's single "› Advanced options" disclosure.
  bool _advancedOpen = false;

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
    // Blur commits — see _commitLimit's doc for why never per keystroke.
    _maxStorageFocus = FocusNode()
      ..addListener(() {
        if (!_maxStorageFocus.hasFocus) _commitMaxStorage();
      });
    _maxAgeFocus = FocusNode()
      ..addListener(() {
        if (!_maxAgeFocus.hasFocus) _commitMaxAge();
      });
    final initial = widget.initialGameId;
    if (initial != null && widget.gameEntries.any((e) => e.gameId == initial)) {
      _selectedGeneralPage = null;
      _selectedGameId = initial;
    }
  }

  void _selectGeneralPage(_SettingsPage page) => setState(() {
        _selectedGeneralPage = page;
        _selectedGameId = null;
      });

  void _selectGame(String gameId) => setState(() {
        _selectedGameId = gameId;
        _selectedGeneralPage = null;
      });

  @override
  void dispose() {
    // Closing Settings (✕) while a limit field still has focus never fires
    // the blur listeners — commit any pending edit here so leaving the
    // screen counts as "moving out of the field", not as discarding it.
    _commitMaxStorage();
    _commitMaxAge();
    _maxStorageFocus.dispose();
    _maxAgeFocus.dispose();
    _customBufferController.dispose();
    _maxStorageController.dispose();
    _maxAgeController.dispose();
    super.dispose();
  }

  /// True only while a "Clean up now" run is in flight; disables the
  /// button so a double-click can't run two overlapping enforcement passes.
  bool _cleaningUp = false;

  /// The last run's outcome, shown as the row's footnote until the page is
  /// rebuilt. Null before the first run.
  String? _cleanupResult;

  Future<void> _cleanUpStorage() async {
    final run = widget.onCleanUpStorage;
    if (run == null || _cleaningUp) return;
    setState(() {
      _cleaningUp = true;
      _cleanupResult = null;
    });
    final removed = await run();
    if (!mounted) return;
    final freed = removed.fold(0, (sum, c) => sum + c.sizeBytes);
    setState(() {
      _cleaningUp = false;
      _cleanupResult = removed.isEmpty
          ? 'Nothing to remove — everything is within the limits above.'
          : 'Removed ${removed.length} '
              'clip${removed.length == 1 ? '' : 's'} · '
              'freed ${formatSize(freed)}.';
    });
  }

  /// Commits a storage-limit field ON BLUR/SUBMIT, never per keystroke.
  ///
  /// Per-keystroke commit was a data-loss bug: typing "15" passes through
  /// "1", and every settings change runs a retention sweep — so the sweep
  /// fired on a transient "1 GB" limit and deleted real clips before the
  /// user finished typing. A limit now only takes effect when the user
  /// leaves the field (their "wait until I move out"), and the explicit
  /// Clean up button remains the immediate path.
  ///
  /// Invalid text at commit time (garbage, zero, negative) restores the
  /// field to the last committed value instead of writing anything.
  void _commitLimit(
    TextEditingController controller,
    int? current,
    void Function(int?) write,
  ) {
    final t = controller.text.trim();
    int? next;
    if (t.isNotEmpty) {
      final parsed = int.tryParse(t);
      if (parsed == null || parsed < 1) {
        controller.text = current?.toString() ?? '';
        return;
      }
      next = parsed;
    }
    if (next == current) return;
    write(next);
    widget.onChanged(widget.settings);
  }

  void _commitMaxStorage() => _commitLimit(_maxStorageController,
      widget.settings.maxStorageGb, (gb) => widget.settings.maxStorageGb = gb);

  void _commitMaxAge() => _commitLimit(
      _maxAgeController,
      widget.settings.maxClipAgeDays,
      (days) => widget.settings.maxClipAgeDays = days);

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
    // Audit line: a hotkey silently reverted once (Ctrl+7 → Ctrl+6,
    // 2026-07-18, most likely a stale instance's whole-file settings
    // write) — logging every change makes the next revert traceable.
    talker.info('Save hotkey changed: "${widget.settings.hotkey}" → "$value"');
    // setState, not a bare mutation: the recorder field renders the value
    // its PARENT passed it, so without a parent rebuild the field kept
    // showing the old combo after a successful capture (the maintainer
    // recorded Ctrl+7, the app correctly bound Ctrl+7 — and the UI showed
    // Ctrl+6 until they navigated away and back).
    setState(() => widget.settings.hotkey = value);
    widget.onChanged(widget.settings);
  }

  /// Same as [_handleHotkeyChanged], for the independent record-toggle
  /// hotkey field.
  void _handleRecordHotkeyChanged(String value) {
    talker.info(
        'Record hotkey changed: "${widget.settings.recordHotkey}" → "$value"');
    setState(() => widget.settings.recordHotkey = value);
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

  /// The tier the current raw settings correspond to — drives which preset
  /// card shows selected, its cost line, and whether Resolution/Framerate
  /// are visible.
  VideoPreset get _currentVideoPreset => VideoPreset.of(
      widget.settings.captureFps, widget.settings.captureMaxHeight);

  /// A named preset applies its values immediately; Custom only reveals the
  /// per-axis rows without writing anything — picking Custom then walking
  /// away must not silently change the user's quality.
  void _selectVideoPreset(VideoPreset preset) {
    if (preset == VideoPreset.custom) {
      setState(() => _customVideoExpanded = true);
      return;
    }
    setState(() => _customVideoExpanded = false);
    preset.applyTo(widget.settings);
    widget.onChanged(widget.settings);
  }

  bool _isVideoPresetSelected(VideoPreset preset) =>
      preset == VideoPreset.custom
          ? (_currentVideoPreset == VideoPreset.custom || _customVideoExpanded)
          : (_currentVideoPreset == preset && !_customVideoExpanded);

  bool get _showCustomVideoRows => _isVideoPresetSelected(VideoPreset.custom);

  /// The honest disk-cost line each preset card prints — for a named tier,
  /// from its own bundled fps/maxHeight; for Custom, from the CURRENT
  /// settings (there's no bundled recipe to show instead).
  String _videoPresetCostLine(VideoPreset preset) {
    final buffer = widget.settings.defaultBufferSeconds;
    if (preset == VideoPreset.custom) {
      final mb = estimatedBufferMegabytes(buffer,
          fps: widget.settings.captureFps,
          maxHeight: widget.settings.captureMaxHeight);
      return 'your recipe · ≈ $mb MB';
    }
    final mb = estimatedBufferMegabytes(buffer,
        fps: preset.fps!, maxHeight: preset.maxHeight);
    final resLabel =
        preset.maxHeight == null ? 'Source' : '${preset.maxHeight}p';
    return '$resLabel · ${preset.fps} fps · $buffer s buffer ≈ $mb MB';
  }

  /// See §3.6's "Follow the game" toggle: writes
  /// [AppSettings.autoSwitchCapture] straight through, same as every other
  /// field on this screen.
  void _handleAutoSwitchChanged(bool value) {
    widget.settings.autoSwitchCapture = value;
    setState(() {});
    widget.onChanged(widget.settings);
  }

  /// Writes [AppSettings.captureOnlyInGame] straight through, same as every
  /// other field on this screen; `main.dart`'s `onSettingsChanged` re-runs
  /// `applyBufferPolicy` afterward so a toggle here takes effect
  /// immediately, not just on the next game transition.
  void _handleCaptureOnlyInGameChanged(bool value) {
    widget.settings.captureOnlyInGame = value;
    setState(() {});
    widget.onChanged(widget.settings);
  }

  void _handleMicrophoneChanged(bool value) {
    widget.settings.captureMicrophone = value;
    setState(() {});
    widget.onChanged(widget.settings);
  }

  /// The uid the microphone dropdown should show as selected: the saved
  /// choice only if it's one of the currently-listed [widget.audioInputs] —
  /// mirrors [_selectedAppBundleId]: null ("System default") is always a
  /// valid menu item, so a saved uid for a device that's since been
  /// unplugged just shows as "System default" without touching the
  /// persisted setting.
  String? _selectedMicDeviceUid() {
    final saved = widget.settings.micDeviceUid;
    return saved != null && widget.audioInputs.any((d) => d.uid == saved)
        ? saved
        : null;
  }

  void _handleMicDeviceChanged(String? uid) {
    widget.settings.micDeviceUid = uid;
    widget.onChanged(widget.settings);
  }

  /// The "Record game & system sound" toggle: OFF maps to [AudioMode.off];
  /// turning it back ON restores [AudioMode.all] (not whatever narrower
  /// mode was last active) — the toggle's own hint promises "game and app
  /// sound", i.e. everything, and the "From" sub-row is how a user narrows
  /// it back down to game-only.
  void _handleAudioToggleChanged(bool on) {
    widget.settings.audioMode = on ? AudioMode.all : AudioMode.off;
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

  Widget _selectedBody(BuildContext context) {
    final gameId = _selectedGameId;
    if (gameId != null) {
      final entry = widget.gameEntries.firstWhere(
        (e) => e.gameId == gameId,
        // Defensive only: [_selectGame] is only ever called with an id drawn
        // from widget.gameEntries, and initState guards initialGameId the
        // same way — this fallback exists so a gameEntries list that shrinks
        // out from under an already-open page (a config removed elsewhere)
        // degrades to a blank page instead of throwing.
        orElse: () => GameEntry(
          gameId: gameId,
          displayName: gameId,
          detection: const {},
          active: false,
          clipCount: 0,
          totalSizeBytes: 0,
        ),
      );
      return _GameSettingsPage(
        key: ValueKey('gameSettingsPage:$gameId'),
        entry: entry,
        settings: widget.settings,
        onChanged: widget.onChanged,
      );
    }
    return switch (_selectedGeneralPage!) {
      _SettingsPage.capture => _capturePage(context),
      _SettingsPage.hotkey => _hotkeysPage(context),
      _SettingsPage.storage => _storagePage(context),
      _SettingsPage.about => _aboutPage(context),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SettingsSidebar(
            selectedGeneralPage: _selectedGeneralPage,
            selectedGameId: _selectedGameId,
            gameEntries: widget.gameEntries,
            onSelectGeneral: _selectGeneralPage,
            onSelectGame: _selectGame,
          ),
          Expanded(
            child: Stack(
              children: [
                _selectedBody(context),
                Positioned(
                  top: 18,
                  right: 22,
                  child: _CloseButton(onClose: widget.onClose),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _capturePage(BuildContext context) {
    return _settingsPage(context, 'Capture', [
      _SettingsSection(
        title: 'Instant replay',
        description: 'How far back a saved clip reaches.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<String>(
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
            if (_customBuffer) ...[
              const SizedBox(height: 12),
              _TextFieldRow(
                label: 'Custom buffer',
                field: SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _customBufferController,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(hintText: 'Seconds (5-300)'),
                    onChanged: _handleCustomBufferChanged,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            _ToggleRow(
              label: 'Only record while playing',
              hint: 'Pause the replay buffer when no game is detected — '
                  'saves CPU and battery at the desktop.',
              value: widget.settings.captureOnlyInGame,
              switchKey: const ValueKey('onlyInGameSwitch'),
              onChanged: _handleCaptureOnlyInGameChanged,
            ),
          ],
        ),
      ),
      _sectionDivider(context),
      _SettingsSection(
        title: 'Video',
        description: 'One choice — resolution, framerate and disk cost '
            'follow it.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _videoPresetGrid(context),
            if (_showCustomVideoRows) ...[
              const SizedBox(height: 12),
              _FieldRow(
                label: 'Resolution',
                control: DropdownButtonFormField<int>(
                  key: const ValueKey('videoResolutionDropdown'),
                  initialValue: widget.settings.captureMaxHeight ?? 0,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Source')),
                    DropdownMenuItem(value: 1440, child: Text('1440p')),
                    DropdownMenuItem(value: 1080, child: Text('1080p')),
                    DropdownMenuItem(value: 720, child: Text('720p')),
                  ],
                  onChanged: (v) {
                    if (v != null) _handleResolutionChanged(v == 0 ? null : v);
                  },
                ),
              ),
              _FieldRow(
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
            ],
          ],
        ),
      ),
      _sectionDivider(context),
      _SettingsSection(
        title: 'Audio',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ToggleRow(
              label: 'Record game & system sound',
              hint: 'Game and app sound in your clips',
              value: widget.settings.audioMode != AudioMode.off,
              switchKey: const ValueKey('recordSystemAudioSwitch'),
              onChanged: _handleAudioToggleChanged,
            ),
            if (widget.settings.audioMode != AudioMode.off)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.only(left: 16),
                decoration: BoxDecoration(
                  border: Border(
                      left: BorderSide(
                          color: context.rewindTokens.hairline, width: 2)),
                ),
                child: _FieldRow(
                  label: 'From',
                  control: DropdownButtonFormField<AudioMode>(
                    key: const ValueKey('audioSourceDropdown'),
                    initialValue: widget.settings.audioMode == AudioMode.app
                        ? AudioMode.app
                        : AudioMode.all,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(
                          value: AudioMode.all, child: Text('All apps')),
                      DropdownMenuItem(
                          value: AudioMode.app, child: Text('Game only')),
                    ],
                    onChanged: (m) {
                      if (m != null) _handleAudioModeChanged(m);
                    },
                  ),
                ),
              ),
            _ToggleRow(
              label: 'Record my microphone',
              hint: 'Your commentary is included in clips',
              value: widget.settings.captureMicrophone,
              switchKey: const ValueKey('captureMicrophoneSwitch'),
              onChanged: _handleMicrophoneChanged,
            ),
            if (widget.settings.captureMicrophone &&
                widget.audioInputs.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.only(left: 16),
                decoration: BoxDecoration(
                  border: Border(
                      left: BorderSide(
                          color: context.rewindTokens.hairline, width: 2)),
                ),
                child: _FieldRow(
                  label: 'Microphone',
                  control: DropdownButtonFormField<String?>(
                    key: const ValueKey('micDeviceDropdown'),
                    initialValue: _selectedMicDeviceUid(),
                    isExpanded: true,
                    items: [
                      // Name what "default" resolves to RIGHT NOW —
                      // "System default" alone made the maintainer ask what
                      // it meant. It follows macOS's Sound → Input choice;
                      // a named device pins that device instead.
                      DropdownMenuItem<String?>(
                        child: Text(switch (widget.audioInputs
                            .where((i) => i.isDefault)
                            .toList()) {
                          [final d, ...] => 'System default (${d.name})',
                          _ => 'System default',
                        }),
                      ),
                      for (final input in widget.audioInputs)
                        DropdownMenuItem<String?>(
                          value: input.uid,
                          child: Text(input.name),
                        ),
                    ],
                    onChanged: _handleMicDeviceChanged,
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 4),
      _AdvancedDisclosure(
        open: _advancedOpen,
        onToggle: () => setState(() => _advancedOpen = !_advancedOpen),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.displays.isNotEmpty)
              _FieldRow(
                label: 'Capture display',
                control: DropdownButtonFormField<String>(
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
            if (widget.capturableApps.isNotEmpty)
              _FieldRow(
                label: 'Capture application',
                control: DropdownButtonFormField<String?>(
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
            _ToggleRow(
              label: 'Follow the game',
              hint: "Switch capture to a game's window when it launches",
              value: widget.settings.autoSwitchCapture,
              switchKey: const ValueKey('autoSwitchCaptureSwitch'),
              onChanged: _handleAutoSwitchChanged,
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _videoPresetGrid(BuildContext context) {
    Widget cardFor(VideoPreset preset) {
      final (title, description) = switch (preset) {
        VideoPreset.performance => (
            'Performance',
            'Lightest on your system and disk — great for quick moments.'
          ),
        VideoPreset.balanced => (
            'Balanced',
            'Smooth 60 fps at a sensible file size — right for most clips.'
          ),
        VideoPreset.high => (
            'High',
            'Sharper and smoother for big plays — uses noticeably more '
                'disk.'
          ),
        VideoPreset.custom => (
            'Custom',
            'Pick resolution and framerate yourself — including native res.'
          ),
      };
      return _PresetCard(
        key: ValueKey('videoPreset:${preset.name}'),
        title: title,
        description: description,
        costLine: _videoPresetCostLine(preset),
        selected: _isVideoPresetSelected(preset),
        recommended: preset == VideoPreset.balanced,
        onTap: () => _selectVideoPreset(preset),
      );
    }

    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: cardFor(VideoPreset.performance)),
              const SizedBox(width: 10),
              Expanded(child: cardFor(VideoPreset.balanced)),
            ],
          ),
        ),
        const SizedBox(height: 10),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: cardFor(VideoPreset.high)),
              const SizedBox(width: 10),
              Expanded(child: cardFor(VideoPreset.custom)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _hotkeysPage(BuildContext context) {
    return _settingsPage(context, 'Hotkeys', [
      _FieldRow(
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
      _FieldRow(
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
    ]);
  }

  Widget _storagePage(BuildContext context) {
    return _settingsPage(context, 'Storage', [
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
      _TextFieldRow(
        label: 'Max storage (GB)',
        field: SizedBox(
          width: 200,
          child: TextField(
            key: const ValueKey('maxStorageField'),
            controller: _maxStorageController,
            focusNode: _maxStorageFocus,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(hintText: 'Blank = unlimited'),
            // Commit on blur/submit ONLY — see _commitLimit's doc for the
            // typing-"15"-passes-through-"1" data-loss bug this prevents.
            onSubmitted: (_) => _maxStorageFocus.unfocus(),
          ),
        ),
      ),
      const SizedBox(height: 8),
      _TextFieldRow(
        label: 'Delete clips older than (days)',
        field: SizedBox(
          width: 200,
          child: TextField(
            key: const ValueKey('maxAgeField'),
            controller: _maxAgeController,
            focusNode: _maxAgeFocus,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(hintText: 'Blank = never'),
            onSubmitted: (_) => _maxAgeFocus.unfocus(),
          ),
        ),
        footnote: 'Limits apply when you leave the field. Oldest clips are '
            'removed first when a limit is hit. Protected clips are never '
            'auto-deleted.',
      ),
      if (widget.onCleanUpStorage != null)
        _TrailingRow(
          label: 'Clean up now',
          hint: 'Apply the limits above immediately instead of waiting '
              'for the automatic sweep.',
          trailing: OutlinedButton(
            key: const ValueKey('cleanUpStorageButton'),
            onPressed: _cleaningUp ? null : _cleanUpStorage,
            child: Text(_cleaningUp ? 'Cleaning…' : 'Clean up'),
          ),
          footnote: _cleanupResult,
        ),
      _TrailingRow(
        label: 'Recordings folder',
        hint: resolveClipsDirPath(widget.settings.clipsDirPath),
        hintKey: const ValueKey('clipsDirLabel'),
        // OutlinedButton, matching Clean up above: ONE style for row
        // actions on this page — a bordered button next to a bare text link
        // doing the same kind of job read as two different controls.
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton(
              key: const ValueKey('chooseClipsDirButton'),
              onPressed: _pickClipsDir,
              child: const Text('Choose…'),
            ),
            if (widget.settings.clipsDirPath != null) ...[
              const SizedBox(width: 8),
              OutlinedButton(
                key: const ValueKey('resetClipsDirButton'),
                onPressed: _resetClipsDir,
                child: const Text('Reset'),
              ),
            ],
          ],
        ),
        footnote: 'Applies on next launch. Existing clips stay where they '
            'are.',
      ),
    ]);
  }

  /// About is prose + buttons + the legal disclaimer, not label→control
  /// pairs, so it deliberately doesn't use the field-row grammar — a normal
  /// column, same shape as before the redesign.
  Widget _aboutPage(BuildContext context) {
    return _settingsPage(context, 'About', [
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
    ]);
  }

  static String _displayLabel(int index, DisplayInfo d) =>
      'Display ${index + 1} — ${d.width}×${d.height}'
      '${d.isMain ? ' (Main)' : ''}';
}

/// Wraps a page's content in its own scroll view, CENTERED in the pane and
/// capped at [settingsPageContentWidth] — the "variant G" column, narrower
/// than the shared [settingsMaxContentWidth] a game hub's panel still uses.
///
/// Centered, not left-anchored, on purpose: in a wide window a left-anchored
/// capped column dumps ALL the leftover width on the right, and that
/// lopsided void reads as unfinished (the exact complaint that started the
/// settings redesign, remade at page level). Centering splits the leftover
/// space into symmetric framing — the capped-column convention Discord and
/// macOS System Settings both follow.
///
/// Shared by every GENERAL page and each MY GAMES page ([_GameSettingsPage])
/// so they read as one design, not two. [description], when given, is a
/// muted one-line sub-head right under the title — only [_GameSettingsPage]
/// uses it ("Overrides for this game…").
Widget _settingsPage(
  BuildContext context,
  String title,
  List<Widget> children, {
  String? description,
}) {
  final theme = Theme.of(context);
  return SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(40, 30, 40, 40),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: settingsPageContentWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.display),
            if (description case final d?) ...[
              const SizedBox(height: 4),
              Text(d, style: theme.textTheme.bodyMuted),
            ],
            const SizedBox(height: 28),
            ...children,
          ],
        ),
      ),
    ),
  );
}

Widget _sectionDivider(BuildContext context) => Padding(
      // Whitespace-first grouping: the air between sections must clearly
      // exceed the air within them, or the page reads as one undifferentiated
      // wall (the "bland, don't know where to look" feedback).
      padding: const EdgeInsets.symmetric(vertical: 26),
      child: Divider(
          height: 1, thickness: 1, color: context.rewindTokens.hairline),
    );

/// The full-page's left sidebar — the ONLY navigation while Settings is
/// open (the app rail is hidden by the caller). A "GENERAL" section, then —
/// when [gameEntries] is non-empty — a "MY GAMES" section listing one row
/// per entry (same order as the rail; see [SettingsScreen.gameEntries]'s
/// doc). Row selection mirrors the app rail's own `_NavItem` treatment
/// (raised bg + a left accent bar) so the two navs read as one visual
/// language.
class _SettingsSidebar extends StatelessWidget {
  final _SettingsPage? selectedGeneralPage;
  final String? selectedGameId;
  final List<GameEntry> gameEntries;
  final ValueChanged<_SettingsPage> onSelectGeneral;
  final ValueChanged<String> onSelectGame;

  const _SettingsSidebar({
    required this.selectedGeneralPage,
    required this.selectedGameId,
    required this.gameEntries,
    required this.onSelectGeneral,
    required this.onSelectGame,
  });

  static const _items = [
    (
      _SettingsPage.capture,
      'settingsTab:Capture',
      'Capture',
      Icons.videocam_outlined
    ),
    (
      _SettingsPage.hotkey,
      'settingsTab:Hotkey',
      'Hotkeys',
      Icons.keyboard_outlined
    ),
    (
      _SettingsPage.storage,
      'settingsTab:Storage',
      'Storage',
      Icons.folder_outlined
    ),
    (_SettingsPage.about, 'settingsTab:About', 'About', Icons.info_outline),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Container(
      width: 200,
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(right: hairlineBorder()),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                'GENERAL',
                style: theme.textTheme.micro.copyWith(color: tokens.textMuted),
              ),
            ),
            for (final (page, keyStr, label, icon) in _items)
              _SidebarItem(
                key: ValueKey(keyStr),
                icon: icon,
                label: label,
                selected: page == selectedGeneralPage,
                onTap: () => onSelectGeneral(page),
              ),
            if (gameEntries.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Text(
                  'MY GAMES',
                  style:
                      theme.textTheme.micro.copyWith(color: tokens.textMuted),
                ),
              ),
              for (final entry in gameEntries)
                _SidebarGameItem(
                  key: ValueKey('settingsGame:${entry.gameId}'),
                  entry: entry,
                  selected: entry.gameId == selectedGameId,
                  onTap: () => onSelectGame(entry.gameId),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One MY GAMES sidebar row: [GameTileAvatar] + display name — the same
/// raised-bg/left-accent-bar selection cue as [_SidebarItem], just with a
/// game icon in place of a fixed [Icon].
class _SidebarGameItem extends StatelessWidget {
  final GameEntry entry;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarGameItem({
    required this.entry,
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
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? tokens.surfaceRaised : null,
            border: Border(
              left: BorderSide(
                color: selected ? tokens.accent : Colors.transparent,
                width: tokens.radiusRailIndicator,
              ),
            ),
          ),
          child: Row(
            children: [
              GameTileAvatar(
                gameId: entry.gameId,
                displayName: entry.displayName,
                iconPath: entry.iconPath,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.displayName,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: (selected
                          ? theme.textTheme.title
                          : theme.textTheme.body)
                      .copyWith(color: selected ? tokens.accent : tokens.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One MY GAMES page: this game's capture mode (manual-only vs. highlights,
/// plus — for a game with a live vendor API, currently only League — the
/// event chip matrix), its buffer-length override, and a read-only
/// "Detection" line. Everything not touched here falls back to the GENERAL
/// Capture page (see the title-row description). A separate [StatefulWidget]
/// (not folded into [_SettingsScreenState]) so the caller can key it per
/// game id (`_SettingsScreenState._selectedBody`) and get fresh local state
/// on every game switch — the same reason the game hub is its own screen
/// rather than a case inside some larger state class.
class _GameSettingsPage extends StatefulWidget {
  final GameEntry entry;
  final AppSettings settings;
  final Future<void> Function(AppSettings) onChanged;

  const _GameSettingsPage({
    required this.entry,
    required this.settings,
    required this.onChanged,
    super.key,
  });

  @override
  State<_GameSettingsPage> createState() => _GameSettingsPageState();
}

class _GameSettingsPageState extends State<_GameSettingsPage> {
  late int _bufferSeconds;
  late int _postEventSeconds;
  late bool _autoClip;
  late Set<GameEventKind> _enabledEvents;
  bool _advancedOpen = false;

  /// Seeds local editable state from any existing [GameConfig] — read-only
  /// (unlike [AppSettings.configFor], this never creates/persists a row just
  /// because the page was opened), mirroring the game hub's own
  /// `_initLocalConfigState`.
  GameConfig get _snapshot {
    final existing = widget.settings.allConfigs
        .where((c) => c.gameId == widget.entry.gameId);
    return existing.isNotEmpty
        ? existing.first
        : GameConfig(
            gameId: widget.entry.gameId,
            bufferSeconds:
                widget.settings.bufferSecondsFor(widget.entry.gameId),
          );
  }

  @override
  void initState() {
    super.initState();
    final snapshot = _snapshot;
    _bufferSeconds = snapshot.bufferSeconds;
    _postEventSeconds = snapshot.postEventSeconds;
    _autoClip = snapshot.autoClip;
    _enabledEvents = Set.of(snapshot.enabledEvents);
  }

  /// Every write goes through this same read-mutate-persist-notify path —
  /// identical to the game hub's own setting handlers.
  GameConfig _commit(void Function(GameConfig cfg) mutate) {
    final cfg = widget.settings.configFor(widget.entry.gameId);
    mutate(cfg);
    widget.settings.setConfig(cfg);
    widget.onChanged(widget.settings);
    return cfg;
  }

  void _setAutoClip(bool value) {
    setState(() => _autoClip = value);
    _commit((cfg) => cfg.autoClip = value);
  }

  void _setBuffer(int seconds) {
    setState(() => _bufferSeconds = seconds);
    _commit((cfg) => cfg.bufferSeconds = seconds);
  }

  void _setPostEventSeconds(int seconds) {
    setState(() => _postEventSeconds = seconds);
    _commit((cfg) => cfg.postEventSeconds = seconds);
  }

  void _toggleEvent(GameEventKind kind, bool value) {
    setState(() {
      if (value) {
        _enabledEvents.add(kind);
      } else {
        _enabledEvents.remove(kind);
      }
    });
    _commit((cfg) => cfg.enabledEvents = Set.of(_enabledEvents));
  }

  String _detectionLabel(GameEntry entry) {
    if (entry.detection.contains(DetectionMethod.liveClientApi)) {
      return 'Live Client API (automatic)';
    }
    if (entry.detection.contains(DetectionMethod.processWatch)) {
      return 'Process: ${entry.processMatch}';
    }
    return 'Manual — no automatic detection';
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final groups = eventGroupsFor(entry);
    final defaultSeconds = widget.settings.defaultBufferSeconds;
    // Collapses "explicitly set to the same number as the global default"
    // into the same dropdown state as "never overridden" — GameConfig.
    // bufferSeconds is a plain non-nullable int (see its doc), so there is
    // no separate bit recording "this is following the default" distinct
    // from the value happening to match it; that's fine, the two are
    // behaviourally identical either way.
    final followsDefault = _bufferSeconds == defaultSeconds;

    return _settingsPage(
      context,
      entry.displayName,
      description: 'Overrides for this game — everything not set here '
          'follows your Capture defaults.',
      [
        // Games with NO auto-clip event source (process-detected, desktop)
        // get no Capture-mode choice at all: offering "Highlights — auto-clip
        // the moments you pick below" for a game that can never produce an
        // event was a lie (and Highlights even rendered pre-selected, since
        // autoClip defaults true). A plain statement of how the game IS
        // captured replaces it.
        if (groups.isEmpty)
          Text(
            'Clips for this game are saved with your hotkey — no in-game '
            'event feed exists to auto-clip from yet.',
            key: const ValueKey('noAutoClipEventsNote'),
            style: Theme.of(context).textTheme.bodyMuted,
          )
        else
          _SettingsSection(
            title: 'Capture mode',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _captureModeCards(context),
                if (_autoClip) ...[
                  const SizedBox(height: 12),
                  Column(
                    key: const ValueKey('gameSettingsEventMatrix'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < groups.length; i++) ...[
                        if (i > 0) const SizedBox(height: 12),
                        EventGroup(
                          label: groups[i].label,
                          kinds: groups[i].kinds,
                          selected: _enabledEvents,
                          onChanged: _toggleEvent,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),
                  _postEventDelayRow(context),
                ],
              ],
            ),
          ),
        _sectionDivider(context),
        _FieldRow(
          label: 'Buffer length',
          control: DropdownButtonFormField<int?>(
            key: const ValueKey('gameBufferDropdown'),
            initialValue: followsDefault ? null : _bufferSeconds,
            isExpanded: true,
            items: [
              DropdownMenuItem(
                child: Text('Use default ($defaultSeconds s)'),
              ),
              const DropdownMenuItem(value: 15, child: Text('15 s')),
              const DropdownMenuItem(value: 30, child: Text('30 s')),
              const DropdownMenuItem(value: 60, child: Text('60 s')),
              // Only added when the current value isn't already one of the
              // items above — a DropdownButtonFormField's items must have
              // unique values, and its `initialValue` must match one of them.
              if (!followsDefault &&
                  _bufferSeconds != 15 &&
                  _bufferSeconds != 30 &&
                  _bufferSeconds != 60)
                DropdownMenuItem(
                    value: _bufferSeconds, child: Text('$_bufferSeconds s')),
            ],
            onChanged: (value) => _setBuffer(value ?? defaultSeconds),
          ),
        ),
        const SizedBox(height: 4),
        _AdvancedDisclosure(
          open: _advancedOpen,
          onToggle: () => setState(() => _advancedOpen = !_advancedOpen),
          child: _FieldRow(
            label: 'Detection',
            control: Text(_detectionLabel(entry),
                style: Theme.of(context).textTheme.bodyMuted),
          ),
        ),
      ],
    );
  }

  /// Under the event chips: how long to keep the burst debounce "quiet
  /// window" open after the last auto-clip event before saving (see
  /// `ClipCoordinator.burstQuiet`'s doc — a follow-up event inside this
  /// window extends the same clip). Only rendered when there's an event
  /// matrix to have a delay for; see this page's `build`.
  Widget _postEventDelayRow(BuildContext context) {
    const presets = [3, 5, 8, 10];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldRow(
          label: 'Keep recording after the last event',
          control: DropdownButtonFormField<int>(
            key: const ValueKey('postEventDelayDropdown'),
            initialValue: _postEventSeconds,
            isExpanded: true,
            items: [
              for (final s in presets)
                DropdownMenuItem(value: s, child: Text('$s s')),
              // Only added when the current value isn't already one of the
              // presets above — a DropdownButtonFormField's items must have
              // unique values, and its `initialValue` must match one of
              // them (same constraint as the buffer-length dropdown).
              if (!presets.contains(_postEventSeconds))
                DropdownMenuItem(
                  value: _postEventSeconds,
                  child: Text('$_postEventSeconds s'),
                ),
            ],
            onChanged: (value) {
              if (value != null) _setPostEventSeconds(value);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'A follow-up kill during this window extends the same clip.',
            style: Theme.of(context).textTheme.bodyMuted,
          ),
        ),
      ],
    );
  }

  Widget _captureModeCards(BuildContext context) {
    Widget cardFor(bool highlights) {
      final (title, description) = highlights
          ? ('Highlights', 'Auto-clip the moments you pick below')
          : ('Manual only', 'Hotkey saves only — nothing automatic');
      return _PresetCard(
        key: ValueKey('captureMode:${highlights ? 'highlights' : 'manual'}'),
        title: title,
        description: description,
        costLine: null,
        selected: _autoClip == highlights,
        recommended: false,
        onTap: () => _setAutoClip(highlights),
      );
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: cardFor(false)),
          const SizedBox(width: 10),
          Expanded(child: cardFor(true)),
        ],
      ),
    );
  }
}

/// One sidebar row: icon + label, a 2px accent left bar and raised-surface
/// fill when selected — the same non-colour selection cue as the app rail's
/// `_NavItem` (`widgets/nav_rail.dart`), not just a text-colour change.
class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final color = selected ? tokens.accent : tokens.textMuted;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? tokens.surfaceRaised : null,
            border: Border(
              left: BorderSide(
                color: selected ? tokens.accent : Colors.transparent,
                width: tokens.radiusRailIndicator,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 10),
              Text(
                label,
                style: (selected ? theme.textTheme.title : theme.textTheme.body)
                    .copyWith(color: selected ? tokens.accent : tokens.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The round ✕ that returns to whatever destination was showing before
/// Settings was opened — always rendered (it's the only way out of a
/// full-page screen with no rail), a no-op when [onClose] isn't wired.
class _CloseButton extends StatelessWidget {
  final VoidCallback? onClose;

  const _CloseButton({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        key: const ValueKey('settingsCloseButton'),
        tooltip: 'Close settings',
        onPressed: () => onClose?.call(),
        icon: const Icon(Icons.close, size: 16),
        style: IconButton.styleFrom(
          foregroundColor: tokens.textMuted,
          shape: CircleBorder(side: BorderSide(color: tokens.hairline)),
        ),
      ),
    );
  }
}

/// A page section: an h3-size header + optional muted one-line description,
/// then [child] — the whitespace-grouping grammar that replaces the old
/// bordered [SettingRows] card look inside Settings (see CLAUDE.md's UI
/// layer rules: no card borders around groups here).
class _SettingsSection extends StatelessWidget {
  final String title;
  final String? description;
  final Widget child;

  const _SettingsSection({
    required this.title,
    this.description,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A small accent tick anchors each section header — the same visual
        // language as the rail's selection indicator, giving the eye a
        // scannable landmark per section ("where do I look" feedback on the
        // first full-page build: title, headers and body were too close in
        // weight for any of them to lead).
        Row(children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: tokens.accent,
              borderRadius: BorderRadius.circular(tokens.radiusRailIndicator),
            ),
          ),
          const SizedBox(width: 8),
          Text(title, style: theme.textTheme.title),
        ]),
        if (description case final d?) ...[
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 11),
            child: Text(d, style: theme.textTheme.bodyMuted),
          ),
        ],
        const SizedBox(height: 14),
        child,
      ],
    );
  }
}

/// A field row: a short (~150px) left-aligned label, then [control]
/// immediately after at a shared left edge — for dropdowns/segmented
/// controls, as opposed to [_ToggleRow] (trailing switch) or
/// [_TextFieldRow] (label above a text-entry field).
class _FieldRow extends StatelessWidget {
  final String label;
  final Widget control;

  const _FieldRow({required this.label, required this.control});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: 150, child: Text(label, style: theme.textTheme.body)),
          const SizedBox(width: 18),
          Expanded(child: control),
        ],
      ),
    );
  }
}

/// A toggle row: label (+ muted hint beneath it) on the left, a [Switch] at
/// the trailing edge of the column.
class _ToggleRow extends StatelessWidget {
  final String label;
  final String? hint;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Key? switchKey;

  const _ToggleRow({
    required this.label,
    this.hint,
    required this.value,
    required this.onChanged,
    this.switchKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: theme.textTheme.body
                        .copyWith(fontWeight: FontWeight.w600)),
                if (hint case final h?) ...[
                  const SizedBox(height: 2),
                  Text(h, style: theme.textTheme.bodyMuted),
                ],
              ],
            ),
          ),
          const SizedBox(width: 18),
          Switch(key: switchKey, value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// A text-entry field row: label ABOVE [field] — the one place the
/// eyetracking research (see CLAUDE.md/the redesign spec) calls for
/// top-aligned labels instead of [_FieldRow]'s left-aligned ones, since a
/// field the user types into (not just picks from) is genuine data entry.
class _TextFieldRow extends StatelessWidget {
  final String label;
  final Widget field;
  final String? footnote;

  const _TextFieldRow(
      {required this.label, required this.field, this.footnote});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.body),
          const SizedBox(height: 6),
          field,
          if (footnote case final f?) ...[
            const SizedBox(height: 8),
            Text(f, style: theme.textTheme.bodyMuted),
          ],
        ],
      ),
    );
  }
}

/// A generic label(+hint)-left / arbitrary-control-right row, for rows whose
/// trailing control isn't a [Switch] (a button, a row of buttons) — "Clean
/// up now" and "Recordings folder".
class _TrailingRow extends StatelessWidget {
  final String label;
  final String? hint;
  final Key? hintKey;
  final Widget trailing;
  final String? footnote;

  const _TrailingRow({
    required this.label,
    this.hint,
    this.hintKey,
    required this.trailing,
    this.footnote,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: theme.textTheme.body
                            .copyWith(fontWeight: FontWeight.w600)),
                    if (hint case final h?) ...[
                      const SizedBox(height: 2),
                      Text(
                        h,
                        key: hintKey,
                        style: theme.textTheme.bodyMuted,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 18),
              trailing,
            ],
          ),
          if (footnote case final f?) ...[
            const SizedBox(height: 8),
            Text(f, style: theme.textTheme.bodyMuted),
          ],
        ],
      ),
    );
  }
}

/// One video-quality preset card: a radio dot, name (+ a small
/// "RECOMMENDED" badge on Balanced), an outcome-worded description, and a
/// mono disk-cost line — see `settings/video_preset.dart`'s design
/// provenance doc for why outcome cards + Custom beat raw fps/resolution
/// knobs as the default choice.
class _PresetCard extends StatelessWidget {
  final String title;
  final String description;

  /// The mono disk-cost line, e.g. "1080p · 60 fps · 30 s buffer ≈ 220 MB".
  /// Null omits the line entirely — the Capture-mode cards ("Manual only" /
  /// "Highlights", `_GameSettingsPage`) have no disk cost of their own to
  /// print (auto-clip doesn't change the buffer's size), unlike the video
  /// quality presets this card was originally built for.
  final String? costLine;
  final bool selected;
  final bool recommended;
  final VoidCallback onTap;

  const _PresetCard({
    required this.title,
    required this.description,
    required this.costLine,
    required this.selected,
    required this.recommended,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Material(
      color: selected
          ? tokens.accent.withValues(alpha: 0.07)
          : tokens.surfaceRaised,
      borderRadius: BorderRadius.circular(tokens.radiusControl),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(tokens.radiusControl),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(tokens.radiusControl),
            border: Border.all(
                color: selected ? tokens.accent : Colors.transparent),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  selected ? Icons.radio_button_checked : Icons.circle_outlined,
                  size: 14,
                  color: selected ? tokens.accent : tokens.textMuted,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 2,
                      children: [
                        Text(title,
                            style: theme.textTheme.body
                                .copyWith(fontWeight: FontWeight.w700)),
                        if (recommended) const _RecommendedBadge(),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: theme.textTheme.bodyMuted
                          .copyWith(color: selected ? tokens.text : null),
                    ),
                    if (costLine case final line?) ...[
                      const SizedBox(height: 7),
                      Text(
                        line,
                        style: theme.textTheme.label.copyWith(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w500,
                          color: selected ? tokens.accent : tokens.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecommendedBadge extends StatelessWidget {
  const _RecommendedBadge();

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: tokens.accent),
        borderRadius: BorderRadius.circular(tokens.radiusChip),
      ),
      child: Text(
        'RECOMMENDED',
        style: theme.textTheme.micro
            .copyWith(color: tokens.accent, fontSize: 8.5, letterSpacing: 1),
      ),
    );
  }
}

/// One "› Advanced options" disclosure per page max: a rotating chevron
/// button that reveals [child] with an animated size change.
class _AdvancedDisclosure extends StatelessWidget {
  final bool open;
  final VoidCallback onToggle;
  final Widget child;

  const _AdvancedDisclosure({
    required this.open,
    required this.onToggle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('advancedOptionsToggle'),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedRotation(
                    turns: open ? 0.25 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.chevron_right,
                        size: 16, color: tokens.textMuted),
                  ),
                  const SizedBox(width: 6),
                  Text('Advanced options',
                      style: theme.textTheme.body
                          .copyWith(color: tokens.textMuted)),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topLeft,
          child: open
              ? Padding(padding: const EdgeInsets.only(top: 4), child: child)
              : const SizedBox(width: double.infinity),
        ),
      ],
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
