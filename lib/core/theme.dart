import 'package:flutter/material.dart';

/// Premium color constants matching the reference TV design.
class AppColors {
  AppColors._();

  // — Main dark backgrounds —
  static const Color darkBg = Color(0xFF0A0A0F);
  static const Color darkSurface = Color(0xFF12121A);
  static const Color darkCard = Color(0xFF161622);
  static const Color darkSidebar = Color(0xFF0E0E18);

  // — Light theme backgrounds —
  static const Color lightBg = Color(0xFFF5F7FA);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightSidebar = Color(0xFFF0F2F8);

  // — Neon accents (dark theme) —
  static const Color neonBlue = Color(0xFF00B4FF);
  static const Color neonGreen = Color(0xFF00FF88);
  static const Color neonPurple = Color(0xFF9D4EDD);
  static const Color neonCyan = Color(0xFF00E5FF);

  // — Light theme accents (slightly deeper for contrast on white) —
  static const Color lightPrimary = Color(0xFF0A84FF);
  static const Color lightAccentGreen = Color(0xFF30D158);
  static const Color lightAccentPurple = Color(0xFF8944D6);

  // — Status colors —
  static const Color statusConnected = Color(0xFF34C759);
  static const Color statusActive = Color(0xFF9D4EDD);
  static const Color statusPaired = Color(0xFF00B4FF);

  // — Glass effect (glassmorphism) —
  static const Color glassBorder = Color(0x14FFFFFF); // 8% white
  static const Color glassBg = Color(0x0DFFFFFF);     // 5% white
  static const Color glassBorderFocused = Color(0x33FFFFFF); // 20% white

  // — Light card borders & shadows —
  static const Color lightCardBorder = Color(0xFFE5E5EA);
  static const Color lightCardBorderHover = Color(0xFFD1D1D6);
  static const Color lightDivider = Color(0xFFE5E5EA);

  // — Text colors (dark) —
  static const Color textPrimary = Color(0xFFE8E8ED);
  static const Color textSecondary = Color(0xFF8E8E93);
  static const Color textTertiary = Color(0xFF636366);

  // — Text colors (light) —
  static const Color lightTextPrimary = Color(0xFF1C1C1E);
  static const Color lightTextSecondary = Color(0xFF636366);
  static const Color lightTextTertiary = Color(0xFF8E8E93);
}

class AppTheme {
  static const Color _seedColor = Color(0xFF007AFF);

  static ThemeData get light {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: Brightness.light,
    );

    return ThemeData(
      useMaterial3: true,
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
          return const Color(0xFFE5E5EA);
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

  /// Premium dark theme — matching the reference TV design.
  static ThemeData get dark {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: Brightness.dark,
    );

    return ThemeData(
      useMaterial3: true,
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
          return const Color(0xFF38383A);
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
        color: Color(0xFF1E1E2A),
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
