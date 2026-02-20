import 'package:flutter/material.dart';

import 'package:anyware/core/theme.dart';

/// Referans TV tasarımındaki cam efektli (glassmorphism) kart widget'ı.
///
/// Yarı-saydam arka plan + ince kenarlık ile premium görünüm sağlar.
/// [BackdropFilter] yerine performans-dostu yaklaşım kullanır.
class GlassmorphismCard extends StatelessWidget {
  const GlassmorphismCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = 16.0,
    this.borderColor,
    this.backgroundColor,
    this.onTap,
    this.width,
    this.height,
    this.autofocus = false,
    this.onFocusChange,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Color? borderColor;
  final Color? backgroundColor;
  final VoidCallback? onTap;
  final double? width;
  final double? height;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = backgroundColor ??
        (isDark ? AppColors.darkCard : Colors.white);
    final bColor = borderColor ??
        (isDark ? AppColors.glassBorder : Colors.grey.shade200);

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: bColor, width: 1),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          autofocus: autofocus,
          onFocusChange: onFocusChange,
          onTap: onTap,
          borderRadius: BorderRadius.circular(borderRadius),
          child: Padding(
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Neon parıltı efektli kapsayıcı — TV focus durumlarında kullanılır.
///
/// [glowColor] renginde yumuşak gölge efekti oluşturur.
class NeonGlowContainer extends StatelessWidget {
  const NeonGlowContainer({
    super.key,
    required this.child,
    this.glowColor = AppColors.neonBlue,
    this.isGlowing = false,
    this.borderRadius = 16.0,
    this.glowIntensity = 0.4,
    this.spreadRadius = 2.0,
    this.blurRadius = 12.0,
  });

  final Widget child;
  final Color glowColor;
  final bool isGlowing;
  final double borderRadius;
  final double glowIntensity;
  final double spreadRadius;
  final double blurRadius;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      decoration: isGlowing
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              boxShadow: [
                BoxShadow(
                  color: glowColor.withValues(alpha: glowIntensity),
                  spreadRadius: spreadRadius,
                  blurRadius: blurRadius,
                ),
                BoxShadow(
                  color: glowColor.withValues(alpha: glowIntensity * 0.3),
                  spreadRadius: spreadRadius * 2,
                  blurRadius: blurRadius * 2,
                ),
              ],
            )
          : BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
            ),
      child: child,
    );
  }
}

/// Cihaz durum etiketi — Connected / Active / Paired
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    required this.color,
  });

  /// Hazır fabrika yöntemleri
  factory StatusBadge.connected({String? label}) => StatusBadge(
        label: label ?? 'Connected',
        color: AppColors.statusConnected,
      );

  factory StatusBadge.active({String? label}) => StatusBadge(
        label: label ?? 'Active',
        color: AppColors.statusActive,
      );

  factory StatusBadge.paired({String? label}) => StatusBadge(
        label: label ?? 'Paired',
        color: AppColors.statusPaired,
      );

  factory StatusBadge.online({String? label}) => StatusBadge(
        label: label ?? 'Online',
        color: AppColors.statusConnected,
      );

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: color.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// Neon parıltılı ilerleme çubuğu — transfer ekranında kullanılır.
class NeonProgressBar extends StatelessWidget {
  const NeonProgressBar({
    super.key,
    required this.progress,
    this.color = AppColors.neonBlue,
    this.height = 6,
    this.borderRadius = 3,
  });

  final double progress;
  final Color color;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                width: constraints.maxWidth * progress.clamp(0.0, 1.0),
                height: height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(borderRadius),
                  gradient: LinearGradient(
                    colors: [
                      color,
                      color.withValues(alpha: 0.7),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.5),
                      blurRadius: 8,
                      spreadRadius: 0,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
