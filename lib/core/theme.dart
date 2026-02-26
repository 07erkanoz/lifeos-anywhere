import 'package:flutter/material.dart';

/// Modern minimalist color palette — Indigo accent, clean whites/deep blacks.
class AppColors {
  AppColors._();

  // — Main dark backgrounds (Zinc scale) —
  static const Color darkBg = Color(0xFF09090B);
  static const Color darkSurface = Color(0xFF18181B);
  static const Color darkCard = Color(0xFF1C1C22);
  static const Color darkSidebar = Color(0xFF111114);

  // — Light theme backgrounds (Clean white) —
  static const Color lightBg = Color(0xFFFFFFFF);
  static const Color lightSurface = Color(0xFFFAFAFA);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightSidebar = Color(0xFFF5F5F7);

  // — Indigo accent (dark theme — lighter for contrast) —
  static const Color neonBlue = Color(0xFF818CF8);     // Indigo-400
  static const Color neonGreen = Color(0xFF34D399);     // Emerald-400
  static const Color neonPurple = Color(0xFFA78BFA);    // Violet-400
  static const Color neonCyan = Color(0xFF818CF8);      // Indigo-400

  // — Light theme accents (Indigo base) —
  static const Color lightPrimary = Color(0xFF6366F1);       // Indigo-500
  static const Color lightAccentGreen = Color(0xFF10B981);   // Emerald-500
  static const Color lightAccentPurple = Color(0xFF6366F1);  // Indigo-500

  // — Status colors —
  static const Color statusConnected = Color(0xFF10B981);  // Emerald-500
  static const Color statusActive = Color(0xFF6366F1);     // Indigo-500
  static const Color statusPaired = Color(0xFF818CF8);     // Indigo-400

  // — Glass effect (dark theme card borders) —
  static const Color glassBorder = Color(0xFF27272A);     // Zinc-800
  static const Color glassBg = Color(0xFF1C1C22);         // Dark card
  static const Color glassBorderFocused = Color(0xFF3F3F46); // Zinc-700

  // — Light card borders & shadows —
  static const Color lightCardBorder = Color(0xFFE5E7EB);
  static const Color lightCardBorderHover = Color(0xFFD1D5DB);
  static const Color lightDivider = Color(0xFFF3F4F6);

  // — Text colors (dark) —
  static const Color textPrimary = Color(0xFFFAFAFA);     // Zinc-50
  static const Color textSecondary = Color(0xFFA1A1AA);   // Zinc-400
  static const Color textTertiary = Color(0xFF71717A);    // Zinc-500

  // — Text colors (light) —
  static const Color lightTextPrimary = Color(0xFF111827);   // Gray-900
  static const Color lightTextSecondary = Color(0xFF6B7280); // Gray-500
  static const Color lightTextTertiary = Color(0xFF9CA3AF);  // Gray-400
}

/// Explicit text theme for cross-platform consistency (Inter font).
const _appTextTheme = TextTheme(
  displayLarge: TextStyle(
      fontSize: 32, fontWeight: FontWeight.w700, height: 1.2, letterSpacing: -0.5),
  displayMedium: TextStyle(
      fontSize: 28, fontWeight: FontWeight.w600, height: 1.2, letterSpacing: -0.5),
  headlineLarge: TextStyle(
      fontSize: 24, fontWeight: FontWeight.w600, height: 1.3),
  headlineMedium: TextStyle(
      fontSize: 20, fontWeight: FontWeight.w600, height: 1.3),
  titleLarge: TextStyle(
      fontSize: 18, fontWeight: FontWeight.w600, height: 1.4),
  titleMedium: TextStyle(
      fontSize: 16, fontWeight: FontWeight.w500, height: 1.4),
  titleSmall: TextStyle(
      fontSize: 14, fontWeight: FontWeight.w500, height: 1.4),
  bodyLarge: TextStyle(
      fontSize: 16, fontWeight: FontWeight.w400, height: 1.5),
  bodyMedium: TextStyle(
      fontSize: 14, fontWeight: FontWeight.w400, height: 1.5),
  bodySmall: TextStyle(
      fontSize: 12, fontWeight: FontWeight.w400, height: 1.5),
  labelLarge: TextStyle(
      fontSize: 14, fontWeight: FontWeight.w500, height: 1.4),
  labelMedium: TextStyle(
      fontSize: 12, fontWeight: FontWeight.w500, height: 1.4),
  labelSmall: TextStyle(
      fontSize: 11, fontWeight: FontWeight.w500, height: 1.4),
);

class AppTheme {
  static const Color _seedColor = Color(0xFF6366F1); // Indigo-500

  static ThemeData get light {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: Brightness.light,
    );

    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Inter',
      textTheme: _appTextTheme,
      colorScheme: colorScheme.copyWith(
        surface: AppColors.lightBg,
        primary: AppColors.lightPrimary,
        onSurface: AppColors.lightTextPrimary,
        onSurfaceVariant: AppColors.lightTextSecondary,
      ),
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.lightBg,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: 'Inter',
          color: AppColors.lightTextPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: AppColors.lightCardBorder, width: 0.5),
        ),
        color: AppColors.lightCard,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
        dense: true,
        visualDensity: VisualDensity.compact,
        textColor: AppColors.lightTextPrimary,
        iconColor: AppColors.lightTextSecondary,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.lightCardBorder.withValues(alpha: 0.3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColors.lightCardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColors.lightCardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColors.lightPrimary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          backgroundColor: AppColors.lightPrimary,
          foregroundColor: Colors.white,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: BorderSide(color: AppColors.lightCardBorder),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          foregroundColor: AppColors.lightPrimary,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 56,
        backgroundColor: AppColors.lightSurface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.lightPrimary.withValues(alpha: 0.1),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontFamily: 'Inter',
            fontSize: 10,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected
                ? AppColors.lightPrimary
                : AppColors.lightTextTertiary,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected
                ? AppColors.lightPrimary
                : AppColors.lightTextTertiary,
          );
        }),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.lightAccentGreen;
          }
          return const Color(0xFFE5E7EB);
        }),
        thumbColor: WidgetStateProperty.all(Colors.white),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          visualDensity: VisualDensity.compact,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearTrackColor: AppColors.lightPrimary.withValues(alpha: 0.1),
        color: AppColors.lightPrimary,
        borderRadius: BorderRadius.circular(4),
      ),
      dividerTheme: DividerThemeData(
        color: AppColors.lightDivider,
        thickness: 0.5,
        space: 0.5,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  /// Premium dark theme — deep black with Indigo accents.
  static ThemeData get dark {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: Brightness.dark,
    );

    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Inter',
      textTheme: _appTextTheme,
      colorScheme: colorScheme.copyWith(
        surface: AppColors.darkSurface,
        primary: AppColors.neonBlue,
        onSurface: AppColors.textPrimary,
        onSurfaceVariant: AppColors.textSecondary,
      ),
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.darkBg,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: AppColors.darkBg,
        titleTextStyle: TextStyle(
          fontFamily: 'Inter',
          color: AppColors.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppColors.glassBorder),
        ),
        color: AppColors.darkCard,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
        dense: true,
        visualDensity: VisualDensity.compact,
        textColor: AppColors.textPrimary,
        iconColor: AppColors.textSecondary,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.darkCard,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.neonBlue, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          backgroundColor: AppColors.neonBlue,
          foregroundColor: Colors.white,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: BorderSide(color: AppColors.glassBorder),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          foregroundColor: AppColors.neonBlue,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 56,
        backgroundColor: AppColors.darkSurface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.neonBlue.withValues(alpha: 0.15),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontFamily: 'Inter',
            fontSize: 10,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? AppColors.neonBlue : AppColors.textSecondary,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? AppColors.neonBlue : AppColors.textSecondary,
          );
        }),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppColors.neonGreen;
          }
          return const Color(0xFF3F3F46); // Zinc-700
        }),
        thumbColor: WidgetStateProperty.all(Colors.white),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          visualDensity: VisualDensity.compact,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearTrackColor: AppColors.neonBlue.withValues(alpha: 0.15),
        color: AppColors.neonBlue,
        borderRadius: BorderRadius.circular(4),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF27272A), // Zinc-800
        thickness: 0.5,
        space: 0.5,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.darkCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}
