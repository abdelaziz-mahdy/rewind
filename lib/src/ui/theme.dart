import 'package:flutter/material.dart';

/// Broadcast-deck dark theme: near-black surfaces, ACHROMATIC chrome, and
/// hue reserved entirely for machine state — see docs/superpowers/specs/
/// 2026-07-25-broadcast-deck-design-system.md §0.
///
/// The one rule: if something on screen carries a hue, it means the machine
/// is doing something. Selection, primary fills, focus rings and every other
/// interaction affordance use [RewindTokens.interactive], a neutral steel.
/// [RewindTokens.armed] (buffer running), [RewindTokens.onAir] (recording),
/// [RewindTokens.positive] (a good outcome) and [RewindTokens.danger]
/// (destructive/failed) are the only hues in the system, and each means
/// exactly one thing. This replaces the single `accent` mint, which had
/// accumulated seven unrelated meanings — selection, primary action, live
/// dot, focus ring, kill count, WIN badge and auto-clip state all read
/// identically, so a glance could not separate "where you are" from "what
/// the machine is doing".
///
/// Shape language is unchanged from the 2026-07-13 redesign (see
/// [RewindTokens]'s radii): rectangular and sharp, no pills, no gradients,
/// no glow/BoxShadow halos anywhere. Hierarchy comes from hairlines, weight
/// and tracking, never from decoration.
ThemeData rewindTheme() {
  const tokens = RewindTokens.dark;

  final colorScheme = ColorScheme.fromSeed(
    seedColor: tokens.interactive,
    brightness: Brightness.dark,
    surface: tokens.surface,
    error: tokens.danger,
  ).copyWith(
    surfaceContainer: tokens.surface,
    surfaceContainerHighest: tokens.surfaceRaised,
    // Material's own widgets (Slider, Switch, TextField cursor) paint with
    // `primary`; pointing it at the achromatic `interactive` keeps them
    // inside the one rule without per-widget overrides.
    primary: tokens.interactive,
    onPrimary: tokens.bg,
    onSurface: tokens.text,
    onSurfaceVariant: tokens.textMuted,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: tokens.bg,
    colorScheme: colorScheme,
    visualDensity: VisualDensity.compact,
    // No ripple spread anywhere — pressed states are a fill change instead
    // (see each widget's `overlayColor`/pressed styling).
    splashFactory: NoSplash.splashFactory,
    // Flat surfaces: no tonal-elevation tint as content stacks, no shadows.
    // Borders (see [hairlineBorder]) carry hierarchy instead.
    canvasColor: tokens.bg,
    dividerColor: tokens.hairline,
    focusColor: tokens.interactive.withValues(alpha: 0.4),
    // Hover/press must LIGHTEN on a dark UI: the previous surfaceRaised-based
    // hover was dark-on-dark — mathematically present, visually invisible
    // (menu items showed no tint at all on hover). Low-alpha white reads on
    // every surface in the app.
    hoverColor: Colors.white.withValues(alpha: 0.06),
    highlightColor: Colors.white.withValues(alpha: 0.10),
    splashColor: Colors.transparent,
    cardTheme: CardThemeData(
      color: tokens.surfaceRaised,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusCard),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        color: tokens.text,
      ),
    ),
    // The app's one primary fill is a near-white steel on near-black — a
    // hardware-button read, and deliberately hue-free so "Save clip" never
    // competes with the tally light beside it for meaning.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.interactive,
        foregroundColor: tokens.bg,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle:
            const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusControl),
        ),
      ).copyWith(
        overlayColor: WidgetStatePropertyAll(
            tokens.interactivePressed.withValues(alpha: 0.3)),
      ),
    ),
    // Material 3's default shape for these is a full StadiumBorder (a pill) —
    // exactly what the redesign bans (§2: "kill every ... pill"). Without
    // this override every OutlinedButton/TextButton in the app (Add game,
    // the permission-banner deep-link, dialog/empty-state actions) would
    // still render pill-shaped despite filledButtonTheme's radiusControl.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusControl),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusControl),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: tokens.textMuted,
      ).copyWith(
        overlayColor:
            WidgetStatePropertyAll(tokens.interactive.withValues(alpha: 0.12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: tokens.surfaceRaised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radiusControl),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radiusControl),
        borderSide: BorderSide(color: tokens.interactive, width: 1.5),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: tokens.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusChip),
      ),
      side: BorderSide(color: tokens.hairline),
      labelPadding: const EdgeInsets.symmetric(horizontal: 10),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusCard),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: tokens.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusCard),
        side: BorderSide(color: tokens.hairline),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusCard),
      ),
      iconColor: tokens.textMuted,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusControl),
        ),
      ),
    ),
    extensions: const [tokens],
  );
}

/// Low-alpha hairline border used throughout instead of elevation/shadows —
/// visible enough to separate surfaces, quiet enough to stay out of the way.
BorderSide hairlineBorder([double alpha = 0.08]) =>
    BorderSide(color: Colors.white.withValues(alpha: alpha));

/// The design tokens (see docs/superpowers/specs/
/// 2026-07-25-broadcast-deck-design-system.md §1): the palette and the four
/// radii custom widgets should build from instead of hard-coding
/// `Colors.white.withValues(...)` or a one-off `BorderRadius.circular(...)`.
/// There is only ever one instance ([dark]) — no light theme is planned.
///
/// The colors split into two groups, and the split is the point:
///
/// * **Chrome** ([interactive], [interactivePressed], [text], [textMuted],
///   [textDim], the surfaces, [hairline]) is achromatic. It says where you
///   are and what you can click.
/// * **State** ([armed], [onAir], [positive], [danger], [warn],
///   [eventSeed]) is the only hue in the app. It says what the machine or
///   the game is doing.
///
/// Reaching for a state color to paint a selection (or vice versa) is the
/// defect this split exists to prevent — see the class-level note on
/// [rewindTheme].
///
/// Accessibility: every foreground token below clears WCAG AA (4.5:1)
/// against every surface token. That used to be a comment; it is now
/// enforced by `test/theme_contrast_test.dart`, so a retune that goes
/// sub-AA fails the suite instead of shipping.
@immutable
class RewindTokens extends ThemeExtension<RewindTokens> {
  /// Window background.
  final Color bg;

  /// Rail, cards, the transport deck.
  final Color surface;

  /// Hover rows, inputs, the selected rail row.
  final Color surfaceRaised;

  /// ALL separation — borders, dividers. Never used for shadows.
  final Color hairline;

  /// Primary text.
  final Color text;

  /// Secondary text, icons at rest.
  final Color textMuted;

  /// Micro-labels and other tertiary type. A third step below [textMuted]
  /// so an 11px tracked section label stops competing with body copy for the
  /// same grey.
  final Color textDim;

  /// Selection, primary fills, focus rings — every interaction affordance.
  /// ACHROMATIC by contract (asserted in `theme_contrast_test.dart`): chrome
  /// carries no hue, so it can never be mistaken for a state signal.
  final Color interactive;

  /// Pressed fills.
  final Color interactivePressed;

  /// The replay buffer is running / a game is live / auto-clip is on. The
  /// broadcast standby tally. Nothing else.
  final Color armed;

  /// A manual recording is actively running. Nothing else — deliberately not
  /// shared with [danger], because "you are recording" and "this will delete
  /// a file" must not read as the same red.
  final Color onAir;

  /// A good outcome: a match WIN, a kill count, a granted permission, a
  /// healthy mic level.
  final Color positive;

  /// Destructive actions and failures — delete confirmations, capture
  /// errors, a LOSS, the enemy team.
  final Color danger;

  /// Warning / permission banner. Same value as [armed] today (both are the
  /// "attention, not failure" amber) but a separate name, because they are
  /// separate concepts and may diverge.
  final Color warn;

  /// The saturated base hue every event-badge color is rotated from (see
  /// `eventColor` in `widgets/clip_tile.dart`). Badges cannot derive from
  /// [interactive] any more — rotating an achromatic color's hue just
  /// produces grey.
  final Color eventSeed;

  /// Cards, dialogs, popups.
  final double radiusCard;

  /// Buttons, inputs.
  final double radiusControl;

  /// Chips, badges, thumbnails.
  final double radiusChip;

  /// The left rail's active-selection indicator bar.
  final double radiusRailIndicator;

  const RewindTokens({
    required this.bg,
    required this.surface,
    required this.surfaceRaised,
    required this.hairline,
    required this.text,
    required this.textMuted,
    required this.textDim,
    required this.interactive,
    required this.interactivePressed,
    required this.armed,
    required this.onAir,
    required this.positive,
    required this.danger,
    required this.warn,
    required this.eventSeed,
    this.radiusCard = 8,
    this.radiusControl = 6,
    this.radiusChip = 4,
    this.radiusRailIndicator = 2,
  });

  static const dark = RewindTokens(
    bg: Color(0xFF08090B),
    surface: Color(0xFF101216),
    surfaceRaised: Color(0xFF181B21),
    hairline: Color(0x14FFFFFF),
    text: Color(0xFFE8EBEF),
    // The three-step text ladder is deliberately shallow: AA (4.5:1) against
    // `surfaceRaised` is the binding constraint, and anything dimmer than
    // `textDim` fails it. `textMuted` was lifted from the old #8B94A1 to open
    // a visible gap between the two rather than dropping `textDim` below AA.
    textMuted: Color(0xFF9AA3B0),
    textDim: Color(0xFF7E8794),
    interactive: Color(0xFFDCE3EC),
    interactivePressed: Color(0xFFB9C4D2),
    armed: Color(0xFFF5A524),
    onAir: Color(0xFFFF4D4F),
    positive: Color(0xFF37D39B),
    danger: Color(0xFFEA5257),
    warn: Color(0xFFF5A524),
    eventSeed: Color(0xFFF0B429),
  );

  @override
  RewindTokens copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceRaised,
    Color? hairline,
    Color? text,
    Color? textMuted,
    Color? textDim,
    Color? interactive,
    Color? interactivePressed,
    Color? armed,
    Color? onAir,
    Color? positive,
    Color? danger,
    Color? warn,
    Color? eventSeed,
    double? radiusCard,
    double? radiusControl,
    double? radiusChip,
    double? radiusRailIndicator,
  }) {
    return RewindTokens(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      hairline: hairline ?? this.hairline,
      text: text ?? this.text,
      textMuted: textMuted ?? this.textMuted,
      textDim: textDim ?? this.textDim,
      interactive: interactive ?? this.interactive,
      interactivePressed: interactivePressed ?? this.interactivePressed,
      armed: armed ?? this.armed,
      onAir: onAir ?? this.onAir,
      positive: positive ?? this.positive,
      danger: danger ?? this.danger,
      warn: warn ?? this.warn,
      eventSeed: eventSeed ?? this.eventSeed,
      radiusCard: radiusCard ?? this.radiusCard,
      radiusControl: radiusControl ?? this.radiusControl,
      radiusChip: radiusChip ?? this.radiusChip,
      radiusRailIndicator: radiusRailIndicator ?? this.radiusRailIndicator,
    );
  }

  @override
  RewindTokens lerp(ThemeExtension<RewindTokens>? other, double t) {
    if (other is! RewindTokens) return this;
    return RewindTokens(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      text: Color.lerp(text, other.text, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      interactive: Color.lerp(interactive, other.interactive, t)!,
      interactivePressed:
          Color.lerp(interactivePressed, other.interactivePressed, t)!,
      armed: Color.lerp(armed, other.armed, t)!,
      onAir: Color.lerp(onAir, other.onAir, t)!,
      positive: Color.lerp(positive, other.positive, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      eventSeed: Color.lerp(eventSeed, other.eventSeed, t)!,
      radiusCard: _lerpDouble(radiusCard, other.radiusCard, t),
      radiusControl: _lerpDouble(radiusControl, other.radiusControl, t),
      radiusChip: _lerpDouble(radiusChip, other.radiusChip, t),
      radiusRailIndicator:
          _lerpDouble(radiusRailIndicator, other.radiusRailIndicator, t),
    );
  }

  static double _lerpDouble(double a, double b, double t) => a + (b - a) * t;
}

/// Reaches [RewindTokens] off the current [Theme] — the only theme extension
/// registered, so this is always non-null once [rewindTheme] is in effect.
extension RewindTokensX on BuildContext {
  RewindTokens get rewindTokens => Theme.of(this).extension<RewindTokens>()!;
}

/// Type treatments layered on top of the base [TextTheme]: uppercase
/// letter-spaced micro-labels (badges, section headers, "GAMES", "LIVE") and
/// a dedicated NUMERAL role for every digit the app shows.
///
/// The numeral role is not decoration. Rewind's screens are mostly numbers —
/// timecodes, durations, buffer seconds, file sizes, K/D/A, clip counts —
/// and they need to be column-aligned and instantly separable from prose.
/// [numeral]/[numeralLarge] are the only styles digits should use; see
/// docs/superpowers/specs/2026-07-25-broadcast-deck-design-system.md §1.2.
extension RewindTypography on TextTheme {
  /// Screen titles, hub headers. 22/w800, tight tracking.
  TextStyle get display => (headlineSmall ?? const TextStyle()).copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
      );

  /// Card headers, the rail's selected row. 15/w700.
  TextStyle get title => (titleMedium ?? const TextStyle()).copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w700,
      );

  /// 13/w500.
  TextStyle get body => (bodyMedium ?? const TextStyle()).copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w500,
      );

  /// [body] in [RewindTokens.dark.textMuted] — secondary text.
  TextStyle get bodyMuted => body.copyWith(color: RewindTokens.dark.textMuted);

  /// Chips, buttons. 12/w600.
  TextStyle get label => (labelLarge ?? const TextStyle()).copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
      );

  /// Section labels, event badges ("GAMES", "LIVE"): 11/w700, tracked 1.2.
  /// Callers still uppercase the string themselves — this only sets the type
  /// treatment.
  TextStyle get micro => (labelSmall ?? const TextStyle()).copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      );

  /// EVERY digit in the app at body scale: timecodes, durations, sizes,
  /// K/D/A, buffer seconds, clip counts, hotkey caps. Tabular figures so
  /// values in a column never shift width as they tick.
  TextStyle get numeral => (bodyMedium ?? const TextStyle()).copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// The hero readouts — the deck's timecode, a match card's scoreboard.
  TextStyle get numeralLarge => (titleLarge ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}

/// Max width for a single column of settings (label → control pairs).
///
/// Settings-style columns must not track the window width. Unconstrained on a
/// wide display, a 4-way segmented control stretches past 1900px — a ~600px
/// "30 s" button — and a row's toggle ends up ~1800px from the label it
/// belongs to, so nothing visually says which control does what. Capping the
/// column also keeps help text near a readable line length.
///
/// Used by the Settings screen and by a game hub's capture-settings panel,
/// which has the same shape. Grids of cards (clips, matches) are deliberately
/// NOT capped — those genuinely want the whole window.
///
/// Sized so the column owns most of the pane rather than hugging one edge: at
/// 720 it left ~550px of dead space stacked entirely on the right, which read
/// as unfinished rather than as margin. The row grammar (label left, control
/// right, hairline between) is what keeps a label bound to its control at this
/// width — the hairline does the work narrowness used to.
const double settingsMaxContentWidth = 960;

/// Column width for the full-page Settings screen's sidebar content pane
/// (`settings_screen.dart`), narrower than [settingsMaxContentWidth]: with
/// its own dedicated 200px sidebar already separating nav from content (no
/// shared pane with a game hub), the research-locked "variant G" design caps
/// the column at 720 — matching the eyetracking-research finding that a
/// scannable settings list wants ~600-760px, not the wider 960 a
/// label-left/control-right hub panel can still get away with.
const double settingsPageContentWidth = 720;
