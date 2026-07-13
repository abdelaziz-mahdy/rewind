import 'package:flutter/material.dart';

/// Modern gamer-dark theme: near-black surfaces, a single electric-mint
/// accent, low-alpha hairline borders instead of elevation, and a tightened
/// type scale (uppercase micro-labels, tabular hero numerals). Deliberately
/// restrained (one accent only) so per-event badge hues elsewhere — derived
/// from this same accent — stay legible rather than turning into a rainbow.
ThemeData rewindTheme() {
  const background = Color(0xFF0E1114);
  const surface = Color(0xFF171B21);
  const surfaceContainer = Color(0xFF1E242C);
  const accent = Color(0xFF3DDC97);
  const error = Color(0xFFFF5470);

  final colorScheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
    surface: surface,
    error: error,
  ).copyWith(
    surfaceContainer: surfaceContainer,
    surfaceContainerHighest: surfaceContainer,
    primary: accent,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: background,
    colorScheme: colorScheme,
    visualDensity: VisualDensity.comfortable,
    // Flat surfaces: no tonal-elevation tint as content stacks. Borders
    // (see [hairlineBorder]) carry hierarchy instead of shadows.
    canvasColor: background,
    dividerColor: Colors.white.withValues(alpha: 0.08),
    focusColor: accent.withValues(alpha: 0.4),
    hoverColor: Colors.white.withValues(alpha: 0.04),
    highlightColor: Colors.white.withValues(alpha: 0.03),
    splashColor: accent.withValues(alpha: 0.08),
    cardTheme: CardThemeData(
      color: surfaceContainer,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.3,
        color: colorScheme.onSurface,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle:
            const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ).copyWith(
        overlayColor:
            WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.08)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: colorScheme.onSurfaceVariant,
      ).copyWith(
        overlayColor: WidgetStatePropertyAll(accent.withValues(alpha: 0.12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceContainer,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: accent, width: 1.5),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      side: hairlineBorder(),
      labelPadding: const EdgeInsets.symmetric(horizontal: 10),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: hairlineBorder(),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      iconColor: colorScheme.onSurfaceVariant,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}

/// Low-alpha hairline border used throughout instead of elevation/shadows —
/// visible enough to separate surfaces, quiet enough to stay out of the way.
BorderSide hairlineBorder([double alpha = 0.08]) =>
    BorderSide(color: Colors.white.withValues(alpha: alpha));

/// Type treatments layered on top of the base [TextTheme]: uppercase
/// letter-spaced micro-labels (badges, section headers, status) and large
/// tabular-figure numerals (the buffer-length hero readout, hotkey chips).
extension RewindTypography on TextTheme {
  TextStyle get microLabel => labelSmall!.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      );

  TextStyle get heroNumeral => titleLarge!.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}
