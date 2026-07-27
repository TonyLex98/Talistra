import 'package:flutter/material.dart';

import '../services/settings_service.dart';

/// The whole app's look, derived from the *reading* settings.
///
/// The library, settings and statistics screens used to be styled from a
/// Material colour scheme of their own, so the app changed character the
/// moment you opened a book: a tinted grey-blue interface around a warm
/// paper-coloured page, in a different typeface. There is only one
/// appearance choice now — the reading background (and the reading font) —
/// and every screen is built from it, so the app reads as one continuous
/// surface with the page you're reading.
class AppTheme {
  const AppTheme._();

  /// The app's own accent, kept independent of the reading palette: the
  /// reading accent is tuned to stand out *on a page* (a strong blue on
  /// white), which is far too loud for buttons and chrome.
  static const _seed = Color(0xFF2E6F6B);

  static ThemeData from(SettingsService settings) {
    final reading = settings.readingTheme;
    final ink = reading.inkAt(settings.readingContrast);
    final isDark = reading == ReadingTheme.dark;

    // Shades of the paper itself, for the surfaces that need to sit *on*
    // it (cards, sheets, chips) — mixed towards the ink rather than
    // towards grey, so nothing looks pasted on from another palette.
    Color layer(double amount) => Color.lerp(reading.background, ink, amount)!;

    final scheme =
        ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: isDark ? Brightness.dark : Brightness.light,
        ).copyWith(
          surface: reading.background,
          surfaceContainerLowest: reading.background,
          surfaceContainerLow: reading.secondaryBackground,
          surfaceContainer: layer(0.055),
          surfaceContainerHigh: layer(0.085),
          surfaceContainerHighest: layer(0.12),
          onSurface: ink,
          onSurfaceVariant: layer(0.55),
          outlineVariant: reading.readingDivider,
          outline: layer(0.35),
          // No tonal elevation overlay: it would wash the paper colour with
          // the accent hue on anything raised.
          surfaceTint: const Color(0x00000000),
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // The reading typeface everywhere, so the interface is set in the
      // same voice as the text.
      fontFamily: settings.readingFont.family,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: const Color(0x00000000),
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 1,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: BorderSide.none,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
