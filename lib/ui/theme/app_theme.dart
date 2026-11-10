import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const Color scaffoldBg = Color(0xFF0F141C);
  static const Color surfaceColor = Color(0xFF181F2C);
  static const Color cardColor = Color(0xFF1E2638);
  static const Color accentColor = Color(0xFF388BFD);
  static const Color successColor = Color(0xFF2EA043);
  static const Color warningColor = Color(0xFFD29922);
  static const Color errorColor = Color(0xFFF85149);

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: scaffoldBg,
      colorScheme: const ColorScheme.dark(
        primary: accentColor,
        secondary: Color(0xFF58A6FF),
        surface: surfaceColor,
        error: errorColor,
        onPrimary: Colors.white,
        onSurface: Color(0xFFE6EDF3),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: surfaceColor,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Color(0xFFE6EDF3),
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: Color(0xFFE6EDF3)),
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF30363D), width: 1),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF30363D),
        thickness: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFF30363D)),
        ),
      ),
    );
  }
}
