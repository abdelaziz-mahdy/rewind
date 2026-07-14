import 'package:flutter/material.dart';

/// Gaming-confident dark theme: near-black surfaces, a single electric-mint
/// accent, hairline borders instead of elevation, and a tightened type scale
/// (uppercase micro-labels, tabular numerals). Deliberately restrained (one
/// accent only) so per-event badge hues elsewhere — derived from this same
/// accent — stay legible rather than turning into a rainbow.
///
/// Shape language is rectangular and sharp on purpose (see [RewindTokens]'s
/// radii): no pills, no gradients, no glow/BoxShadow halos anywhere. The
/// gaming personality comes from structure and treatment (weight, tracking,
/// hairlines), not from decoration — see docs/superpowers/specs/
/// 2026-07-13-game-centric-redesign.md §2 for the source of these values.
ThemeData rewindTheme() {
  const tokens = RewindTokens.dark;

  final colorScheme = ColorScheme.fromSeed(
    seedColor: tokens.accent,
    brightness: Brightness.dark,
    surface: tokens.surface,
    error: tokens.rec,
  ).copyWith(
    surfaceContainer: tokens.surface,
    surfaceContainerHighest: tokens.surfaceRaised,
    primary: tokens.accent,
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
    focusColor: tokens.accent.withValues(alpha: 0.4),
    hoverColor: tokens.surfaceRaised.withValues(alpha: 0.6),
    highlightColor: tokens.accentPressed.withValues(alpha: 0.18),
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
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.accent,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle:
            const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radiusControl),
        ),
      ).copyWith(
        overlayColor:
            WidgetStatePropertyAll(tokens.accentPressed.withValues(alpha: 0.3)),
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
            WidgetStatePropertyAll(tokens.accent.withValues(alpha: 0.12)),
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
        borderSide: BorderSide(color: tokens.accent, width: 1.5),
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

/// The redesign's design tokens (see docs/superpowers/specs/
/// 2026-07-13-game-centric-redesign.md §2): the palette and the four radii
/// custom widgets should build from instead of hard-coding
/// `Colors.white.withValues(...)` or a one-off `BorderRadius.circular(...)`.
/// There is only ever one instance ([dark]) — no light theme is planned.
@immutable
class RewindTokens extends ThemeExtension<RewindTokens> {
  /// Window background.
  final Color bg;

  /// Rail, cards.
  final Color surface;

  /// Hover rows, inputs, the selected rail row.
  final Color surfaceRaised;

  /// ALL separation — borders, dividers. Never used for shadows.
  final Color hairline;

  /// Primary text.
  final Color text;

  /// Secondary text, icons at rest.
  final Color textMuted;

  /// Selection, primary action, live dots, focus ring.
  final Color accent;

  /// Pressed fills.
  final Color accentPressed;

  /// Recording dot + destructive. Nothing else.
  final Color rec;

  /// Error / permission banner.
  final Color warn;

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
    required this.accent,
    required this.accentPressed,
    required this.rec,
    required this.warn,
    this.radiusCard = 8,
    this.radiusControl = 6,
    this.radiusChip = 4,
    this.radiusRailIndicator = 2,
  });

  static const dark = RewindTokens(
    bg: Color(0xFF0C0E11),
    surface: Color(0xFF14171C),
    surfaceRaised: Color(0xFF1A1E24),
    hairline: Color(0x14FFFFFF),
    text: Color(0xFFE6EAEF),
    textMuted: Color(0xFF8B94A1),
    accent: Color(0xFF3DDC97),
    accentPressed: Color(0xFF2FB37C),
    rec: Color(0xFFFF4757),
    warn: Color(0xFFFFB74D),
  );

  @override
  RewindTokens copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceRaised,
    Color? hairline,
    Color? text,
    Color? textMuted,
    Color? accent,
    Color? accentPressed,
    Color? rec,
    Color? warn,
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
      accent: accent ?? this.accent,
      accentPressed: accentPressed ?? this.accentPressed,
      rec: rec ?? this.rec,
      warn: warn ?? this.warn,
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
      accent: Color.lerp(accent, other.accent, t)!,
      accentPressed: Color.lerp(accentPressed, other.accentPressed, t)!,
      rec: Color.lerp(rec, other.rec, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
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

/// Type treatments layered on top of the base [TextTheme], matching the §2
/// scale: uppercase letter-spaced micro-labels (badges, section headers,
/// "GAMES", "LIVE") and large tabular-figure numerals (the buffer-length
/// hero readout, hotkey chips, counts).
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

  /// The buffer-length hero readout: large, tabular-figure digits.
  TextStyle get numeral => (titleLarge ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}
