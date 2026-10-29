import 'package:flutter/material.dart';

import 'tokens.dart';

ThemeData buildAerTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: AerColors.accent,
        brightness: Brightness.light,
      ).copyWith(
        primary: AerColors.accent,
        onPrimary: AerColors.surface,
        secondary: AerColors.sage,
        surface: AerColors.surface,
        onSurface: AerColors.ink,
        onSurfaceVariant: AerColors.inkMuted,
        surfaceContainerHighest: AerColors.surfaceMuted,
        outline: AerColors.border,
        outlineVariant: AerColors.border,
        error: AerColors.terracotta,
      );

  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AerRadii.medium),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AerColors.background,
    textTheme: Typography.blackMountainView.apply(
      bodyColor: AerColors.ink,
      displayColor: AerColors.ink,
    ),
    cardTheme: CardThemeData(
      color: AerColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: rounded.copyWith(side: const BorderSide(color: AerColors.border)),
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: AerColors.surfaceMuted,
      indicatorColor: AerColors.accentSoft,
      selectedIconTheme: IconThemeData(color: AerColors.ink),
      unselectedIconTheme: IconThemeData(color: AerColors.inkMuted),
      selectedLabelTextStyle: TextStyle(
        color: AerColors.ink,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: TextStyle(color: AerColors.inkMuted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: rounded),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: rounded,
        foregroundColor: AerColors.ink,
        side: const BorderSide(color: AerColors.border),
      ),
    ),
    dividerTheme: const DividerThemeData(color: AerColors.border),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AerColors.background,
      labelStyle: const TextStyle(color: AerColors.inkMuted),
      floatingLabelStyle: const TextStyle(color: AerColors.accent),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AerRadii.small),
        borderSide: const BorderSide(color: AerColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AerRadii.small),
        borderSide: const BorderSide(color: AerColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AerRadii.small),
        borderSide: const BorderSide(color: AerColors.accent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AerRadii.small),
        borderSide: const BorderSide(color: AerColors.terracotta),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AerColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AerRadii.large),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AerColors.ink,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AerRadii.small),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AerColors.ink,
        borderRadius: BorderRadius.circular(AerRadii.small),
      ),
    ),
  );
}
