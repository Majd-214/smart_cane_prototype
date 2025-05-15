import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Define a primary color inspired by Google's aesthetic
  static const Color primaryColor = Color(0xFF4285F4); // Google Blue
  static const Color accentColor = Color(0xFF34A853); // Google Green
  static const Color errorColor = Color(0xFFEA4335); // Google Red
  static const Color warningColor = Color(0xFFFBBC05); // Google Yellow
  static const Color textColorPrimary = Colors.black87;
  static const Color textColorSecondary = Colors.black54;
  static const Color backgroundColor = Colors.white;

  // Define a dark theme inspired by Google Safety app's dark mode
  static const Color darkPrimaryColor = Color(0xFF8AB4F8); // Lighter Google Blue for dark mode
  static const Color darkAccentColor = Color(0xFF81C995); // Lighter Google Green
  static const Color darkErrorColor = Color(0xFFF28B82); // Lighter Google Red
  static const Color darkWarningColor = Color(0xFFFCD663); // Lighter Google Yellow
  static const Color darkTextColorPrimary = Colors.white;
  static const Color darkTextColorSecondary = Colors.white70;
  static const Color darkBackgroundColor = Color(0xFF202124); // Dark background

  static ThemeData lightTheme = ThemeData(
    brightness: Brightness.light,
    primaryColor: primaryColor,
    colorScheme: const ColorScheme.light(
      primary: primaryColor,
      secondary: accentColor,
      error: errorColor,
      surface: backgroundColor,
      background: backgroundColor,
      onPrimary: Colors.white, // Text color on primary
      onSecondary: Colors.white, // Text color on secondary
      onSurface: textColorPrimary, // Text color on surface
      onBackground: textColorPrimary, // Text color on background
      onError: Colors.white, // Text color on error
    ),
    scaffoldBackgroundColor: backgroundColor,
    textTheme: GoogleFonts.outfitTextTheme().apply(
      bodyColor: textColorPrimary,
      displayColor: textColorPrimary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: primaryColor,
      foregroundColor: Colors.white, // Text color on AppBar
      titleTextStyle: GoogleFonts.outfit(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.bold,
      ),
    ),
    buttonTheme: const ButtonThemeData(
      buttonColor: primaryColor,
      textTheme: ButtonTextTheme.primary,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white, // Text color on button
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        textStyle: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      filled: true,
      fillColor: Colors.grey[200],
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    // Add other theme properties as needed
  );

  static ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    primaryColor: darkPrimaryColor,
    colorScheme: const ColorScheme.dark(
      primary: darkPrimaryColor,
      secondary: darkAccentColor,
      error: darkErrorColor,
      surface: darkBackgroundColor,
      background: darkBackgroundColor,
      onPrimary: Colors.black, // Text color on primary in dark mode
      onSecondary: Colors.black, // Text color on secondary in dark mode
      onSurface: darkTextColorPrimary, // Text color on surface in dark mode
      onBackground: darkTextColorPrimary, // Text color on background in dark mode
      onError: Colors.black, // Text color on error in dark mode
    ),
    scaffoldBackgroundColor: darkBackgroundColor,
    textTheme: GoogleFonts.outfitTextTheme().apply(
      bodyColor: darkTextColorPrimary,
      displayColor: darkTextColorPrimary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: darkBackgroundColor, // AppBar background in dark mode
      foregroundColor: darkTextColorPrimary, // Text color on AppBar in dark mode
      titleTextStyle: GoogleFonts.outfit(
        color: darkTextColorPrimary,
        fontSize: 20,
        fontWeight: FontWeight.bold,
      ),
    ),
    buttonTheme: const ButtonThemeData(
      buttonColor: darkPrimaryColor,
      textTheme: ButtonTextTheme.primary,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: darkPrimaryColor,
        foregroundColor: Colors.black, // Text color on button in dark mode
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        textStyle: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      filled: true,
      fillColor: Colors.white10, // Darker fill color for dark mode inputs
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    // Add other dark theme properties as needed
  );
}