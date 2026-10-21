import 'package:flutter/material.dart';

const Color _seed = Color(0xFF006A6A);

/// The app theme for [brightness]: Material 3 from one seed colour.
///
/// Visual density stays standard on desktop as well, so every control keeps
/// a touch-sized hit target.
ThemeData watchmeTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
    ),
    cardTheme: const CardThemeData(margin: EdgeInsets.zero),
  );
}
