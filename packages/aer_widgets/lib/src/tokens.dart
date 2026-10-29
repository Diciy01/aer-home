import 'package:flutter/material.dart';

/// Cozy Beige Tech Home design tokens (docs/DESIGN_TOKENS.md).
///
/// Status colours are never the only signal: every status also has an icon
/// and a text label.
abstract final class AerColors {
  static const background = Color(0xFFF4EFE7);
  static const surface = Color(0xFFFFFCF7);
  static const surfaceMuted = Color(0xFFEDE5D8);
  static const border = Color(0xFFD8CCBE);
  static const ink = Color(0xFF40352E);
  static const inkMuted = Color(0xFF75675D);
  static const accent = Color(0xFFA77E5F);
  static const accentSoft = Color(0xFFE8CFB4);
  static const sage = Color(0xFF718E76);
  static const blue = Color(0xFF789CAA);
  static const amber = Color(0xFFBC8A43);
  static const terracotta = Color(0xFFBA6D5B);
  static const lavender = Color(0xFFA497B5);
}

abstract final class AerRadii {
  static const small = 12.0;
  static const medium = 16.0;
  static const large = 20.0;
}

abstract final class AerMotion {
  static const short = Duration(milliseconds: 150);
  static const medium = Duration(milliseconds: 220);
}

abstract final class AerSpacing {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 16.0;
  static const l = 24.0;
  static const xl = 32.0;
}
