import 'package:flutter/material.dart';

import '../services/settings_service.dart';

/// Builds the text style reflowed reading text is set in, from the reader's
/// own typography settings: family, weight (driven through the bundled
/// variable fonts' weight axis) and ink contrast against the page.
///
/// One place for all of it, so the compact view, the plain-text view and
/// the settings preview can't drift apart — the preview has to show exactly
/// what reading will look like, or it isn't worth having.
TextStyle readingTextStyle({
  required SettingsService settings,
  required double fontSize,
  double sizeFactor = 1.0,
  double heightFactor = 1.0,
  bool bold = false,
}) {
  final font = settings.readingFont;
  final weight = bold
      ? (settings.readingWeight + 250).clamp(300, 900)
      : settings.readingWeight;
  return TextStyle(
    fontFamily: font.family,
    fontSize: fontSize * sizeFactor,
    height: 1.55 * heightFactor,
    color: settings.readingTheme.inkAt(settings.readingContrast),
    fontWeight: _nearestWeight(weight),
    // A variable font takes the exact weight through its axis; a static
    // family can only pick from the weights it ships, which fontWeight
    // above already handles.
    fontVariations: font.hasVariableWeight
        ? [FontVariation('wght', weight.toDouble())]
        : null,
  );
}

FontWeight _nearestWeight(int weight) {
  final index = ((weight / 100).round() - 1).clamp(0, 8);
  return FontWeight.values[index];
}
