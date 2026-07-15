import 'package:flutter/material.dart';

import 'system_settings.dart';
import 'theme.dart';

/// One getting-started step.
class _Step {
  final IconData icon;
  final String title;
  final String body;

  /// Optional inline action (e.g. "Open Screen Recording Settings").
  final String? actionLabel;
  final VoidCallback? onAction;

  const _Step({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });
}

/// First-run getting-started guide (also re-openable from Settings): a short
/// swipeable walkthrough of what Rewind does, the one permission it needs,
/// the hotkeys, and how games are captured — so a new user isn't dropped
/// into the app with no idea what to do or which settings matter.
///
/// Pure UI: the save/record hotkey labels are passed in, and [onDone] is
/// what both "Skip" and the final "Get started" invoke — first-run wiring
/// persists `onboardingComplete`; the Settings re-open just pops the route.
class OnboardingScreen extends StatefulWidget {
  final String hotkey;
  final String recordHotkey;
  final VoidCallback onDone;

  /// Opens macOS Screen Recording settings; null uses the real opener,
  /// overridable in tests.
  final Future<void> Function()? onOpenScreenRecording;

  const OnboardingScreen({
    required this.hotkey,
    required this.recordHotkey,
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
          icon: Icons.keyboard_outlined,
          title: 'Your controls',
          body: 'Save the last few seconds: ${widget.hotkey}.\n'
              'Start / stop a full recording: ${widget.recordHotkey}.\n\n'
              'Pick what to capture — a display or a specific app — from the '
              'source menu at the bottom-left. Turn on your microphone in '
              'Settings → Capture.',
        ),
        const _Step(
          icon: Icons.sports_esports_outlined,
          title: 'Games clip themselves',
          body: 'Rewind auto-detects popular games. For League of Legends it '
              'clips your kills automatically and tracks each match\'s K/D. '
              'Any other app can be added from the source menu — its clips '
              'get their own place in the sidebar.',
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(step.icon, size: 64, color: tokens.accent),
              const SizedBox(height: 24),
              Text(step.title,
                  textAlign: TextAlign.center, style: theme.textTheme.display),
              const SizedBox(height: 16),
              Text(
                step.body,
                textAlign: TextAlign.center,
                style: theme.textTheme.body.copyWith(
                    color: theme.colorScheme.onSurfaceVariant, height: 1.5),
              ),
              if (step.actionLabel != null) ...[
                const SizedBox(height: 24),
                OutlinedButton(
                  key: const ValueKey('onboardingStepAction'),
                  onPressed: step.onAction,
                  child: Text(step.actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
