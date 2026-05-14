import 'package:flutter/material.dart';

const Color _xbUmeTextPrimary = Color(0xFF111827);
const Color _xbUmeTextSecondary = Color(0xFF374151);
const Color _xbUmeBorder = Color(0xFFD1D5DB);
const Color _xbUmeSurfaceSoft = Color(0xFFF3F4F6);
const Color _xbUmeBrand = Color(0xFF0A84FF);

ThemeData buildXBUmeTheme() {
  final baseColorScheme = ColorScheme.fromSeed(
    seedColor: _xbUmeBrand,
    brightness: Brightness.light,
  );
  final colorScheme = baseColorScheme.copyWith(
    surface: Colors.white,
    onSurface: _xbUmeTextPrimary,
    onPrimary: Colors.white,
    onSecondary: _xbUmeTextPrimary,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: Colors.white,
    canvasColor: Colors.white,
    dividerColor: const Color(0xFFE5E7EB),
    splashColor: _xbUmeBrand.withValues(alpha: 0.10),
    highlightColor: _xbUmeBrand.withValues(alpha: 0.06),
    textTheme: const TextTheme(
      titleLarge: TextStyle(
        color: _xbUmeTextPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: TextStyle(
        color: _xbUmeTextPrimary,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
      titleSmall: TextStyle(
        color: _xbUmeTextPrimary,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(
        color: _xbUmeTextPrimary,
        fontSize: 14,
        height: 1.4,
      ),
      bodyMedium: TextStyle(
        color: _xbUmeTextPrimary,
        fontSize: 13,
        height: 1.4,
      ),
      bodySmall: TextStyle(
        color: _xbUmeTextSecondary,
        fontSize: 12,
        height: 1.4,
      ),
      labelLarge: TextStyle(
        color: _xbUmeTextPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: TextStyle(
        color: _xbUmeTextPrimary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: _xbUmeBrand,
      selectionColor: Color(0x330A84FF),
      selectionHandleColor: _xbUmeBrand,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      labelStyle: const TextStyle(color: _xbUmeTextSecondary, fontSize: 12),
      hintStyle: const TextStyle(color: _xbUmeTextSecondary, fontSize: 12),
      floatingLabelStyle: const TextStyle(color: _xbUmeBrand, fontSize: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _xbUmeBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _xbUmeBrand, width: 1.2),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _xbUmeBorder),
      ),
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: _xbUmeSurfaceSoft,
      selectedColor: Color(0xFFE8F2FF),
      secondarySelectedColor: Color(0xFFE8F2FF),
      disabledColor: Color(0xFFE5E7EB),
      side: BorderSide(color: _xbUmeBorder),
      shape: StadiumBorder(),
      showCheckmark: false,
      labelStyle: TextStyle(
        color: _xbUmeTextPrimary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      secondaryLabelStyle: TextStyle(
        color: _xbUmeTextPrimary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      brightness: Brightness.light,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: _xbUmeBrand,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: _xbUmeTextPrimary,
        side: const BorderSide(color: _xbUmeBorder),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: _xbUmeBrand,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    ),
    dialogTheme: const DialogTheme(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      titleTextStyle: TextStyle(
        color: _xbUmeTextPrimary,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
      contentTextStyle: TextStyle(
        color: _xbUmeTextPrimary,
        fontSize: 12,
        height: 1.45,
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: _xbUmeTextSecondary,
      textColor: _xbUmeTextPrimary,
    ),
    iconTheme: const IconThemeData(
      color: _xbUmeTextSecondary,
    ),
  );
}
