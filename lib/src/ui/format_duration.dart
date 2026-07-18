/// Formats a [Duration] as `M:SS`, or `H:MM:SS` once past an hour. Used for
/// the player's elapsed/total readout and the timeline markers' tooltips —
/// split out of `player_screen.dart` (which still re-exports it) so
/// `widgets/timeline_markers.dart` can share it without importing the
/// screen that imports the widget.
String formatDuration(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  final seconds = d.inSeconds.remainder(60);
  final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}
