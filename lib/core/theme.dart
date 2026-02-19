import 'package:flutter/material.dart';

/// Referans TV tasarımına uygun premium renk sabitleri.
class AppColors {
  AppColors._();

  // — Ana koyu arka planlar —
  static const Color darkBg = Color(0xFF0A0A0F);
  static const Color darkSurface = Color(0xFF12121A);
  static const Color darkCard = Color(0xFF161622);
  static const Color darkSidebar = Color(0xFF0E0E18);

  // — Neon vurgular —
  static const Color neonBlue = Color(0xFF00B4FF);
  static const Color neonGreen = Color(0xFF00FF88);
  static const Color neonPurple = Color(0xFF9D4EDD);
  static const Color neonCyan = Color(0xFF00E5FF);

  // — Durum renkleri —
  static const Color statusConnected = Color(0xFF34C759);
  static const Color statusActive = Color(0xFF9D4EDD);
  static const Color statusPaired = Color(0xFF00B4FF);

  // — Cam efekti (glassmorphism) —
  static const Color glassBorder = Color(0x14FFFFFF); // %8 beyaz
  static const Color glassBg = Color(0x0DFFFFFF);     // %5 beyaz
  static const Color glassBorderFocused = Color(0x33FFFFFF); // %20 beyaz

  // — Metin renkleri —
  static const Color textPrimary = Color(0xFFE8E8ED);
  static const Color textSecondary = Color(0xFF8E8E93);
  static const Color textTertiary = Color(0xFF636366);
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
        surface: const Color(0xFFF2F2F7),
        primary: const Color(0xFF007AFF),
      ),
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF2F2F7),
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Color(0xFFF2F2F7),
        titleTextStyle: TextStyle(
          color: Colors.black,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 0),
        dense: true,
        visualDensity: VisualDensity.compact,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFE5E5EA).withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF007AFF), width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          backgroundColor: const Color(0xFF007AFF),
          foregroundColor: Colors.white,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: BorderSide(color: Colors.grey.shade300),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          foregroundColor: const Color(0xFF007AFF),
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
        backgroundColor: const Color(0xFFF8F8F8),
        surfaceTintColor: Colors.transparent,
        indicatorColor: const Color(0xFF007AFF).withValues(alpha: 0.1),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 10,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? const Color(0xFF007AFF) : const Color(0xFF8E8E93),
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? const Color(0xFF007AFF) : const Color(0xFF8E8E93),
          );
        }),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const Color(0xFF34C759);
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
        linearTrackColor: const Color(0xFF007AFF).withValues(alpha: 0.1),
        color: const Color(0xFF007AFF),
        borderRadius: BorderRadius.circular(4),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFC6C6C8),
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

  /// Premium koyu tema — referans TV tasarımına uygun.
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
