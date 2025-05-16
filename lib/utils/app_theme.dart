import 'package:flutter/material.dart';
// Removed Google Fonts import
// import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Define colors inspired by Google's aesthetic (from your provided theme)
  static const Color primaryColor = Color(0xFF4285F4); // Google Blue
  static const Color accentColor = Color(0xFF34A853); // Google Green
  static const Color errorColor = Color(0xFFEA4335); // Google Red
  static const Color warningColor = Color(0xFFFBBC05); // Google Yellow

  // Text colors for light backgrounds
  static const Color textColorPrimary = Colors.black87;
  static const Color textColorSecondary = Colors.black54;
  static const Color textColorOnPrimary = Colors.white; // Text color on primary (Blue)
  static const Color textColorOnAccent = Colors.white; // Text color on accent (Green)
  static const Color textColorOnError = Colors.white; // Text color on error (Red)
  static const Color textColorOnWarning = Colors.white; // Text color on warning (Yellow)

  // Background colors
  static const Color backgroundColor = Colors.white; // Light background
  static const Color cardColor = Colors.white; // Card background in light theme


  // Define colors for dark theme (from your provided theme)
  static const Color darkPrimaryColor = Color(0xFF8AB4F8); // Lighter Google Blue for dark mode
  static const Color darkAccentColor = Color(0xFF5CD07B); // Lighter Google Green
  static const Color darkErrorColor = Color(0xFFEA4335); // Google Red
  static const Color darkWarningColor = Color(0xFFFBBC05); // Google Yellow

  // Text colors for dark backgrounds
  static const Color darkTextColorPrimary = Colors.white;
  static const Color darkTextColorSecondary = Colors.white70;
  static const Color darkTextColorOnPrimary = Colors.white; // Text color on primary in dark mode
  static const Color darkTextColorOnAccent = Colors.white; // Text color on secondary in dark mode
  static const Color darkTextColorOnError = Colors.white; // Text color on error in dark mode
  static const Color darkTextColorOnWarning = Colors.white; // Text color on warning in dark mode


  // Dark background color
  static const Color darkBackgroundColor = Color(0xFF202124); // Dark background
  static const Color darkCardColor = Color(0xFF303134); // Dark card background


  // Define the main theme data - Light Theme
  static ThemeData lightTheme = ThemeData(
    brightness: Brightness.light,
    primaryColor: primaryColor,
    colorScheme: const ColorScheme.light(
      primary: primaryColor,
      secondary: accentColor,
      error: errorColor,
      surface: cardColor, // Card background
      background: backgroundColor, // Scaffold background
      onPrimary: textColorOnPrimary,
      onSecondary: textColorOnAccent,
      onSurface: textColorPrimary,
      onBackground: textColorPrimary,
      onError: textColorOnError,
      // Add onColor for warning if needed, but often used directly
    ),
    scaffoldBackgroundColor: backgroundColor,
    // *** FIX: Apply the custom "ProductSans" font family to the text theme ***
    // Manually define text styles using the declared font family
    textTheme: const TextTheme(
      // Display styles
      displayLarge: TextStyle(fontFamily: 'ProductSans', fontSize: 57, fontWeight: FontWeight.w400),
      displayMedium: TextStyle(fontFamily: 'ProductSans', fontSize: 45, fontWeight: FontWeight.w400),
      displaySmall: TextStyle(fontFamily: 'ProductSans', fontSize: 36, fontWeight: FontWeight.w400),

      // Headline styles
      headlineLarge: TextStyle(fontFamily: 'ProductSans', fontSize: 32, fontWeight: FontWeight.w400),
      headlineMedium: TextStyle(fontFamily: 'ProductSans', fontSize: 28, fontWeight: FontWeight.w400),
      headlineSmall: TextStyle(fontFamily: 'ProductSans', fontSize: 24, fontWeight: FontWeight.w400),

      // Title styles
      titleLarge: TextStyle(fontFamily: 'ProductSans', fontSize: 22, fontWeight: FontWeight.w500), // Medium weight for titles
      titleMedium: TextStyle(fontFamily: 'ProductSans', fontSize: 16, fontWeight: FontWeight.w500),
      titleSmall: TextStyle(fontFamily: 'ProductSans', fontSize: 14, fontWeight: FontWeight.w500),

      // Body styles
      bodyLarge: TextStyle(fontFamily: 'ProductSans', fontSize: 16, fontWeight: FontWeight.w400), // Regular weight for body text
      bodyMedium: TextStyle(fontFamily: 'ProductSans', fontSize: 14, fontWeight: FontWeight.w400),
      bodySmall: TextStyle(fontFamily: 'ProductSans', fontSize: 12, fontWeight: FontWeight.w400),

      // Label styles (for buttons, captions, etc.)
      labelLarge: TextStyle(fontFamily: 'ProductSans', fontSize: 16, fontWeight: FontWeight.w500), // Medium weight for labels
      labelMedium: TextStyle(fontFamily: 'ProductSans', fontSize: 14, fontWeight: FontWeight.w500),
      labelSmall: TextStyle(fontFamily: 'ProductSans', fontSize: 12, fontWeight: FontWeight.w500),
    ).apply( // Apply base colors to the defined text styles
      bodyColor: textColorPrimary,
      displayColor: textColorPrimary,
      // Add other color applies if needed
    ),
    cardTheme: const CardTheme(
      color: cardColor,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
    appBarTheme: AppBarTheme( // Cannot be const as titleTextStyle is created here
      backgroundColor: primaryColor,
      foregroundColor: textColorOnPrimary, // Text color on AppBar
      titleTextStyle: const TextStyle( // *** FIX: Use custom font here too ***
        fontFamily: 'ProductSans',
        color: textColorOnPrimary,
        fontSize: 20,
        fontWeight: FontWeight.bold, // Consider if Product Sans Bold is registered
      ),
    ),
    buttonTheme: const ButtonThemeData( // This is the older button theme, ElevatedButtonTheme is preferred
      buttonColor: primaryColor,
      textTheme: ButtonTextTheme.primary, // This applies default text style/color
    ),
    elevatedButtonTheme: ElevatedButtonThemeData( // Cannot be const
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryColor,
        foregroundColor: textColorOnPrimary, // Text color on button
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        textStyle: const TextStyle( // *** FIX: Use custom font here too ***
          fontFamily: 'ProductSans',
          fontSize: 16,
          fontWeight: FontWeight.w500, // Adjust weight as needed for button text
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData( // Cannot be const
      style: TextButton.styleFrom(
        foregroundColor: primaryColor,
        textStyle: const TextStyle( // *** FIX: Use custom font here too ***
          fontFamily: 'ProductSans',
          fontSize: 16,
          fontWeight: FontWeight.w500, // Adjust weight as needed
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme( // Cannot be const
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      filled: true,
      fillColor: Colors.grey[200],
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      // Apply font family to input text style (optional, textTheme often covers this)
      // labelStyle: TextStyle(fontFamily: 'ProductSans'),
      // hintStyle: TextStyle(fontFamily: 'ProductSans'),
      // helperStyle: TextStyle(fontFamily: 'ProductSans'),
      // errorStyle: TextStyle(fontFamily: 'ProductSans'),
    ),
    // Add other theme properties as needed
  );

  // Define the main theme data - Dark Theme
  static ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    primaryColor: darkPrimaryColor,
    colorScheme: const ColorScheme.dark(
      primary: darkPrimaryColor,
      secondary: darkAccentColor,
      error: darkErrorColor,
      surface: darkCardColor, // Card background
      background: darkBackgroundColor, // Scaffold background
      onPrimary: darkTextColorOnPrimary,
      onSecondary: darkTextColorOnAccent,
      onSurface: darkTextColorPrimary,
      onBackground: darkTextColorPrimary,
      onError: darkTextColorOnError,
      // Add onColor for warning if needed
    ),
    scaffoldBackgroundColor: darkBackgroundColor,
    // *** FIX: Apply the custom "ProductSans" font family to the dark theme text theme ***
    textTheme: const TextTheme(
      // Display styles
      displayLarge: TextStyle(fontFamily: 'ProductSans', fontSize: 57, fontWeight: FontWeight.w400),
      displayMedium: TextStyle(fontFamily: 'ProductSans', fontSize: 45, fontWeight: FontWeight.w400),
      displaySmall: TextStyle(fontFamily: 'ProductSans', fontSize: 36, fontWeight: FontWeight.w400),

      // Headline styles
      headlineLarge: TextStyle(fontFamily: 'ProductSans', fontSize: 32, fontWeight: FontWeight.w400),
      headlineMedium: TextStyle(fontFamily: 'ProductSans', fontSize: 28, fontWeight: FontWeight.w400),
      headlineSmall: TextStyle(fontFamily: 'ProductSans', fontSize: 24, fontWeight: FontWeight.w400),

      // Title styles
      titleLarge: TextStyle(fontFamily: 'ProductSans', fontSize: 22, fontWeight: FontWeight.w500), // Medium weight for titles
      titleMedium: TextStyle(fontFamily: 'ProductSans', fontSize: 16, fontWeight: FontWeight.w500),
      titleSmall: TextStyle(fontFamily: 'ProductSans', fontSize: 14, fontWeight: FontWeight.w500),

      // Body styles
      bodyLarge: TextStyle(fontFamily: 'ProductSans', fontSize: 16, fontWeight: FontWeight.w400), // Regular weight for body text
      bodyMedium: TextStyle(fontFamily: 'ProductSans', fontSize: 14, fontWeight: FontWeight.w400),
      bodySmall: TextStyle(fontFamily: 'ProductSans', fontSize: 12, fontWeight: FontWeight.w400),

      // Label styles (for buttons, captions, etc.)
      labelLarge: TextStyle(fontFamily: 'ProductSans', fontSize: 16, fontWeight: FontWeight.w500), // Medium weight for labels
      labelMedium: TextStyle(fontFamily: 'ProductSans', fontSize: 14, fontWeight: FontWeight.w500),
      labelSmall: TextStyle(fontFamily: 'ProductSans', fontSize: 12, fontWeight: FontWeight.w500),
    ).apply( // Apply base colors to the defined text styles
      bodyColor: darkTextColorPrimary,
      displayColor: darkTextColorPrimary,
      // Add other color applies if needed
    ),
    cardTheme: const CardTheme(
      color: darkCardColor,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
    appBarTheme: AppBarTheme( // Cannot be const
      backgroundColor: darkBackgroundColor, // AppBar background in dark mode
      foregroundColor: darkTextColorPrimary, // Text color on AppBar in dark mode
      titleTextStyle: const TextStyle( // *** FIX: Use custom font here too ***
        fontFamily: 'ProductSans',
        color: darkTextColorPrimary,
        fontSize: 20,
        fontWeight: FontWeight.bold, // Consider if Product Sans Bold is registered
      ),
    ),
    buttonTheme: const ButtonThemeData( // Older button theme
      buttonColor: darkPrimaryColor,
      textTheme: ButtonTextTheme.primary,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData( // Cannot be const
      style: ElevatedButton.styleFrom(
        backgroundColor: darkPrimaryColor,
        foregroundColor: darkTextColorOnPrimary, // Text color on button in dark mode
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        textStyle: const TextStyle( // *** FIX: Use custom font here too ***
          fontFamily: 'ProductSans',
          fontSize: 16,
          fontWeight: FontWeight.w500, // Adjust weight as needed for button text
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData( // Cannot be const
      style: TextButton.styleFrom(
        foregroundColor: darkPrimaryColor,
        textStyle: const TextStyle( // *** FIX: Use custom font here too ***
          fontFamily: 'ProductSans',
          fontSize: 16,
          fontWeight: FontWeight.w500, // Adjust weight as needed
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme( // Cannot be const
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      filled: true,
      fillColor: Colors.white10, // Darker fill color for dark mode inputs
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      // Apply font family to input text style (optional)
      // labelStyle: TextStyle(fontFamily: 'ProductSans'),
      // hintStyle: TextStyle(fontFamily: 'ProductSans'),
      // helperStyle: TextStyle(fontFamily: 'ProductSans'),
      // errorStyle: TextStyle(fontFamily: 'ProductSans'),
    ),
    // Add other dark theme properties as needed
  );
}