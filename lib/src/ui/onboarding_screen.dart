import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import 'system_settings.dart';
import 'theme.dart';

/// One getting-started step: an icon + headline + body, plus an optional
/// inline action button and/or an interactive control (a setup choice).
class _Step {
  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// An interactive control rendered under the body — the setup choices
  /// (buffer length, mic, follow-the-game) that make onboarding configure
  /// the app, not just describe it.
  final Widget? control;

  const _Step({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
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

  const OnboardingScreen({
    required this.settings,
    required this.onChanged,
    required this.onDone,
    this.onOpenScreenRecording,
    super.key,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  AppSettings get _s => widget.settings;

  void _persist() {
    setState(() {}); // reflect the new value in the control
    widget.onChanged(_s);
  }

  List<_Step> get _steps => [
        const _Step(
          icon: Icons.replay_circle_filled_outlined,
          title: 'Never miss a play',
          body: 'Rewind is always recording the last several seconds in the '
              'background. When something great happens, save it instantly — '
              'no need to hit record beforehand.',
        ),
        _Step(
          icon: Icons.screenshot_monitor_outlined,
          title: 'Grant Screen Recording',
          body: 'Rewind needs macOS Screen Recording permission to capture '
              'your screen. If your clips come out black, this is why — grant '
              'it, then relaunch Rewind.',
          actionLabel: 'Open Screen Recording Settings',
          onAction: () =>
              (widget.onOpenScreenRecording ?? openScreenRecordingSettings)(),
        ),
        _Step(
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
        ),
        _Step(
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
        ),
        _Step(
          icon: Icons.keyboard_outlined,
          title: 'Controls & games',
          body: 'Save the last few seconds: ${_s.hotkey}.\n'
              'Start / stop a full recording: ${_s.recordHotkey}.\n\n'
              'Rewind auto-detects popular games — League clips your kills '
              'automatically. Pick what to capture from the source menu at '
              'the bottom-left.',
        ),
      ];

  void _next() {
    if (_page >= _steps.length - 1) {
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
    final steps = _steps;
    final isLast = _page == steps.length - 1;

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
                onPageChanged: (i) => setState(() => _page = i),
                itemCount: steps.length,
                itemBuilder: (context, i) => _StepView(step: steps[i]),
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
                        for (var i = 0; i < steps.length; i++)
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
                if (step.actionLabel != null) ...[
                  const SizedBox(height: 20),
                  OutlinedButton(
                    key: const ValueKey('onboardingStepAction'),
                    onPressed: step.onAction,
                    child: Text(step.actionLabel!),
                  ),
                ],
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
