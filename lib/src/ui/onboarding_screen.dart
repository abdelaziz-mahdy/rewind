import 'dart:async';

import 'package:flutter/material.dart';

import '../clip/clip.dart';
import '../clip/clip_library.dart';
import '../obs/app_info.dart';
import '../obs/capture_engine.dart';
import '../settings/app_settings.dart';
import 'capture_app_match.dart';
import 'system_settings.dart';
import 'theme.dart';
import 'widgets/clip_tile.dart' show relativeAge, formatSize;

/// One getting-started step: an icon + headline + body, plus an optional
/// inline action button and/or an interactive control (a setup choice).
class _Step {
  final IconData icon;
  final String title;
  final String body;

  /// An interactive control rendered under the body — the setup choices
  /// (buffer length, mic, follow-the-game) that make onboarding configure
  /// the app, not just describe it.
  final Widget? control;

  const _Step({
    required this.icon,
    required this.title,
    required this.body,
    this.control,
  });
}

/// First-run getting-started guide (also re-openable from Settings): a short
/// swipeable walkthrough that both explains what Rewind does AND collects
/// the first-time setup choices — instant-replay length, microphone, and
/// follow-the-game — writing each straight to [settings] and persisting via
/// [onChanged], so a new user leaves it already configured.
///
/// [onDone] is what both "Skip" and the final "Get started" invoke —
/// first-run wiring persists `onboardingComplete`; the Settings re-open just
/// pops the route.
class OnboardingScreen extends StatefulWidget {
  final AppSettings settings;
  final Future<void> Function(AppSettings) onChanged;
  final VoidCallback onDone;

  /// Opens macOS Screen Recording settings; null uses the real opener,
  /// overridable in tests.
  final Future<void> Function()? onOpenScreenRecording;

  /// The live capture engine, for polling/requesting screen-recording
  /// permission. Null shows the permission step's compact "granted" state
  /// (nothing to gate onboarding on if there's no engine to ask).
  final CaptureEngine? engine;

  /// The running app's clip library, so the "Try it now" step can detect a
  /// clip landing while it's visible. Null disables that detection (the
  /// step just shows its call-to-action).
  final ClipLibrary? library;

  /// The capture engine's startup error, if any — null means capture came up
  /// healthy. Drives both the permission step's "granted mid-session" state
  /// and whether the final "Try it now" step is offered at all.
  final String? captureError;

  /// Relaunches the running app (spawns a fresh instance, then exits this
  /// one) — invoked by the permission step's "Relaunch Rewind" button when
  /// permission was granted after a degraded launch. Null disables the
  /// button. Wired in main.dart to the real OS relaunch; overridable/
  /// injected in tests, which must NEVER trigger a real relaunch.
  final VoidCallback? onRelaunch;

  /// Enumerates currently-capturable apps, for the "Controls & games" step's
  /// optional "we can see <game> running" line. Null omits that line.
  final List<AppInfo> Function()? listApps;

  /// The "Controls & games" step's secondary "Set up Steam achievements"
  /// button -- finishes onboarding (same as [onDone]) and then opens
  /// Settings directly on the Steam tab, since the API key it needs
  /// requires a web visit that doesn't belong mid-flow. Null hides the
  /// button (e.g. existing callers/tests that don't wire it).
  final VoidCallback? onSetUpSteam;

  const OnboardingScreen({
    required this.settings,
    required this.onChanged,
    required this.onDone,
    this.onOpenScreenRecording,
    this.engine,
    this.library,
    this.captureError,
    this.onRelaunch,
    this.listApps,
    this.onSetUpSteam,
    super.key,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const int _kPermissionIndex = 1;
  static const int _kControlsGamesIndex = 4;
  int get _tryItIndex => _kControlsGamesIndex + 1;

  /// The final "Try it now" step only appears when capture came up healthy
  /// — with no engine actually buffering, there's nothing to "try".
  bool get _showTryIt => widget.captureError == null;
  int get _pageCount => _showTryIt ? _tryItIndex + 1 : _kControlsGamesIndex + 1;

  late bool _screenGranted = widget.engine?.preflightScreenPermission() ?? true;
  Timer? _permissionPoll;

  Clip? _landedClip;
  int _tryItBaselineCount = 0;
  bool _listeningToLibrary = false;

  @override
  void dispose() {
    _permissionPoll?.cancel();
    if (_listeningToLibrary) widget.library?.removeListener(_onLibraryChanged);
    _controller.dispose();
    super.dispose();
  }

  AppSettings get _s => widget.settings;

  void _persist() {
    setState(() {}); // reflect the new value in the control
    widget.onChanged(_s);
  }

  void _onPageChanged(int i) {
    setState(() => _page = i);
    _syncPermissionPolling();
    _syncLibraryListening();
  }

  // ---- permission step: live poll while visible ---------------------------

  void _syncPermissionPolling() {
    final visible = _page == _kPermissionIndex;
    if (visible && _permissionPoll == null) {
      _pollPermission();
      _permissionPoll =
          Timer.periodic(const Duration(seconds: 1), (_) => _pollPermission());
    } else if (!visible && _permissionPoll != null) {
      _permissionPoll!.cancel();
      _permissionPoll = null;
    }
  }

  void _pollPermission() {
    final granted = widget.engine?.preflightScreenPermission() ?? true;
    if (granted != _screenGranted && mounted) {
      setState(() => _screenGranted = granted);
    }
  }

  void _grantScreenPermission() {
    final granted = widget.engine?.requestScreenPermission() ?? true;
    if (mounted) setState(() => _screenGranted = granted);
  }

  // ---- try-it-now step: listen to the library while visible ---------------

  void _syncLibraryListening() {
    final visible = _showTryIt && _page == _tryItIndex;
    final library = widget.library;
    if (visible && !_listeningToLibrary && library != null) {
      _tryItBaselineCount = library.all.length;
      library.addListener(_onLibraryChanged);
      _listeningToLibrary = true;
    } else if (!visible && _listeningToLibrary) {
      library?.removeListener(_onLibraryChanged);
      _listeningToLibrary = false;
    }
  }

  void _onLibraryChanged() {
    final all = widget.library?.all ?? const <Clip>[];
    if (_landedClip == null && all.length > _tryItBaselineCount) {
      setState(() => _landedClip = all.last);
    }
  }

  // ---- step content ---------------------------------------------------

  static const _welcomeStep = _Step(
    icon: Icons.replay_circle_filled_outlined,
    title: 'Never miss a play',
    body: 'Rewind is always recording the last several seconds in the '
        'background. When something great happens, save it instantly — '
        'no need to hit record beforehand.',
  );

  _Step get _bufferStep => _Step(
        icon: Icons.timer_outlined,
        title: 'How much to keep',
        body: 'When you save a clip, Rewind keeps the last few seconds. '
            'Pick the instant-replay length — you can change it any time.',
        control: _BufferChoice(
          seconds: _s.defaultBufferSeconds,
          onPick: (v) {
            _s.defaultBufferSeconds = v;
            _persist();
          },
        ),
      );

  _Step get _preferencesStep => _Step(
        icon: Icons.tune_outlined,
        title: 'Your preferences',
        body: 'A couple of choices to start with — both live in Settings '
            'later.',
        control: Column(
          children: [
            _ToggleRow(
              label: 'Capture microphone',
              sub: 'Mix your voice into clips (macOS asks for permission '
                  'the first time)',
              value: _s.captureMicrophone,
              onChanged: (v) {
                _s.captureMicrophone = v;
                _persist();
              },
            ),
            const SizedBox(height: 16),
            _ToggleRow(
              label: 'Follow the game',
              sub: "Switch capture to a game's window when it launches",
              value: _s.autoSwitchCapture,
              onChanged: (v) {
                _s.autoSwitchCapture = v;
                _persist();
              },
            ),
          ],
        ),
      );

  /// The catalog display name of a currently-running app, if [widget.
  /// listApps] is wired up and matches one — see `capture_app_match.dart`.
  String? get _matchedGameName {
    final apps = widget.listApps?.call();
    if (apps == null) return null;
    for (final app in apps) {
      final game = matchingCatalogGame(app);
      if (game != null) return game.displayName;
    }
    return null;
  }

  _Step get _controlsGamesStep {
    final matched = _matchedGameName;
    return _Step(
      icon: Icons.keyboard_outlined,
      title: 'Controls & games',
      body: 'Save the last few seconds: ${_s.hotkey}.\n'
          'Start / stop a full recording: ${_s.recordHotkey}.\n\n'
          'Rewind auto-detects popular games — League clips your kills '
          'automatically. Pick what to capture from the source menu at '
          'the bottom-left.\n\n'
          'Any Steam game: unlocking an achievement saves a clip labeled '
          'with its name.'
          '${matched == null ? '' : '\n\nWe can see $matched running — its '
              'highlights will clip automatically.'}',
      control: widget.onSetUpSteam == null
          ? null
          : TextButton(
              key: const ValueKey('steamSetupButton'),
              onPressed: widget.onSetUpSteam,
              child: const Text('Set up Steam achievements'),
            ),
    );
  }

  List<Widget> get _pages => [
        const _StepView(step: _welcomeStep),
        _PermissionStepView(
          granted: _screenGranted,
          hadCaptureErrorAtLaunch: widget.captureError != null,
          onGrant: _grantScreenPermission,
          onOpenSettings: () =>
              (widget.onOpenScreenRecording ?? openScreenRecordingSettings)(),
          onRelaunch: widget.onRelaunch,
        ),
        _StepView(step: _bufferStep),
        _StepView(step: _preferencesStep),
        _StepView(step: _controlsGamesStep),
        if (_showTryIt)
          _TryItStepView(hotkey: _s.hotkey, landedClip: _landedClip),
      ];

  void _next() {
    if (_page >= _pageCount - 1) {
      widget.onDone();
      return;
    }
    _controller.nextPage(
        duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
  }

  void _back() {
    if (_page == 0) return;
    _controller.previousPage(
        duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final pages = _pages;
    final isLast = _page == pages.length - 1;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: TextButton(
                  key: const ValueKey('onboardingSkip'),
                  onPressed: widget.onDone,
                  child: const Text('Skip'),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                onPageChanged: _onPageChanged,
                itemCount: pages.length,
                itemBuilder: (context, i) => pages[i],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Row(
                children: [
                  SizedBox(
                    width: 72,
                    child: _page == 0
                        ? const SizedBox.shrink()
                        : TextButton(
                            key: const ValueKey('onboardingBack'),
                            onPressed: _back,
                            child: const Text('Back'),
                          ),
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < pages.length; i++)
                          Container(
                            width: 7,
                            height: 7,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == _page
                                  ? tokens.accent
                                  : tokens.textMuted.withValues(alpha: 0.4),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 120,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        key: const ValueKey('onboardingNext'),
                        onPressed: _next,
                        child: Text(isLast ? 'Get started' : 'Next'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepView extends StatelessWidget {
  final _Step step;

  const _StepView({required this.step});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(step.icon, size: 60, color: tokens.accent),
                const SizedBox(height: 20),
                Text(step.title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.display),
                const SizedBox(height: 14),
                Text(
                  step.body,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.body.copyWith(
                      color: theme.colorScheme.onSurfaceVariant, height: 1.5),
                ),
                if (step.control != null) ...[
                  const SizedBox(height: 24),
                  step.control!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The permission step: live state (not a static [_Step]) — it polls the
/// engine's current grant state and switches between three presentations
/// (see `OnboardingScreen`'s doc / the task spec). No buttons in the
/// already-granted-at-launch case: there's nothing to do.
class _PermissionStepView extends StatelessWidget {
  final bool granted;
  final bool hadCaptureErrorAtLaunch;
  final VoidCallback onGrant;
  final VoidCallback onOpenSettings;
  final VoidCallback? onRelaunch;

  const _PermissionStepView({
    required this.granted,
    required this.hadCaptureErrorAtLaunch,
    required this.onGrant,
    required this.onOpenSettings,
    this.onRelaunch,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final bodyStyle = theme.textTheme.body
        .copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5);

    final Widget state;
    if (!granted) {
      state = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Rewind needs macOS Screen Recording permission to capture '
            'your screen. If your clips come out black, this is why.',
            textAlign: TextAlign.center,
            style: bodyStyle,
          ),
          const SizedBox(height: 20),
          FilledButton(
            key: const ValueKey('grantScreenPermissionButton'),
            onPressed: onGrant,
            child: const Text('Grant Screen Recording'),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const ValueKey('openScreenSettingsButton'),
            onPressed: onOpenSettings,
            child: const Text('Open System Settings'),
          ),
        ],
      );
    } else if (hadCaptureErrorAtLaunch) {
      state = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: tokens.warn.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(tokens.radiusCard),
              border: Border.all(color: tokens.warn),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.warning_amber_rounded, color: tokens.warn),
                const SizedBox(width: 8),
                Flexible(
                  child: Text('Granted. Relaunch Rewind to start capturing.',
                      style: theme.textTheme.body),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            key: const ValueKey('relaunchButton'),
            onPressed: onRelaunch,
            child: const Text('Relaunch Rewind'),
          ),
        ],
      );
    } else {
      state = Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: tokens.accent.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(tokens.radiusCard),
          border: Border.all(color: tokens.accent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check, color: tokens.accent),
            const SizedBox(width: 8),
            Flexible(
              child: Text("Screen Recording is granted — you're set.",
                  style: theme.textTheme.body),
            ),
          ],
        ),
      );
    }

    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.screenshot_monitor_outlined,
                    size: 60, color: tokens.accent),
                const SizedBox(height: 20),
                Text('Grant Screen Recording',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.display),
                const SizedBox(height: 14),
                state,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The final "try it" step: press the save hotkey and watch a real clip
/// land. Only ever built when capture came up healthy (see
/// `OnboardingScreen._showTryIt`) — there's a real buffer to save from.
class _TryItStepView extends StatelessWidget {
  final String hotkey;
  final Clip? landedClip;

  const _TryItStepView({required this.hotkey, required this.landedClip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.rewindTokens;
    final clip = landedClip;

    final Widget content = clip == null
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Press $hotkey right now — Rewind is already buffering.',
                textAlign: TextAlign.center,
                style: theme.textTheme.body.copyWith(
                    color: theme.colorScheme.onSurfaceVariant, height: 1.5),
              ),
              const SizedBox(height: 12),
              Text("or skip — it'll be there when you need it.",
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMuted),
            ],
          )
        : Column(
            key: const ValueKey('tryItSuccess'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: tokens.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(tokens.radiusCard),
                  border: Border.all(color: tokens.accent),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle, color: tokens.accent),
                    const SizedBox(width: 8),
                    Text('Clip saved!', style: theme.textTheme.body),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${relativeAge(clip.createdAt)} · ${formatSize(clip.sizeBytes)}',
                style: theme.textTheme.bodyMuted,
              ),
            ],
          );

    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.videocam_outlined, size: 60, color: tokens.accent),
                const SizedBox(height: 20),
                Text('Try it now',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.display),
                const SizedBox(height: 14),
                content,
                const SizedBox(height: 20),
                Text(
                  "After setup, Rewind records only while you're playing — "
                  "the replay buffer pauses at the desktop to save CPU, and "
                  "wakes automatically when a game starts (League: when a "
                  "match starts). For always-on desktop recording, turn off "
                  '"Only record while playing" in Settings → Capture.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The buffer-length choice: 15 / 30 / 60 seconds.
class _BufferChoice extends StatelessWidget {
  final int seconds;
  final ValueChanged<int> onPick;

  const _BufferChoice({required this.seconds, required this.onPick});

  @override
  Widget build(BuildContext context) {
    // Snap an off-list custom value to the nearest segment for display.
    final selected = const [15, 30, 60].contains(seconds) ? seconds : 30;
    return SegmentedButton<int>(
      segments: const [
        ButtonSegment(value: 15, label: Text('15 s')),
        ButtonSegment(value: 30, label: Text('30 s')),
        ButtonSegment(value: 60, label: Text('60 s')),
      ],
      selected: {selected},
      onSelectionChanged: (s) => onPick(s.first),
    );
  }
}

/// A labelled switch row used by the preferences step.
class _ToggleRow extends StatelessWidget {
  final String label;
  final String sub;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.label,
    required this.sub,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.body),
              const SizedBox(height: 2),
              Text(sub, style: theme.textTheme.bodyMuted),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}
