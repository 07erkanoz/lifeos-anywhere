import 'package:flutter/material.dart';

/// Shared width breakpoints for resized desktop windows, tablets, and phones.
abstract final class AppBreakpoints {
  static const double compact = 600;
  static const double expanded = 900;
}

abstract final class AppSpacing {
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}

abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration standard = Duration(milliseconds: 180);
  static const Duration emphasized = Duration(milliseconds: 240);
  static const Duration progress = Duration(milliseconds: 320);
}

enum AppWindowClass { compact, medium, expanded }

extension ResponsiveContext on BuildContext {
  AppWindowClass get windowClass {
    final width = MediaQuery.sizeOf(this).width;
    if (width < AppBreakpoints.compact) return AppWindowClass.compact;
    if (width < AppBreakpoints.expanded) return AppWindowClass.medium;
    return AppWindowClass.expanded;
  }

  bool get isCompact => windowClass == AppWindowClass.compact;
  bool get isExpanded => windowClass == AppWindowClass.expanded;
  double get adaptivePagePadding => isCompact ? AppSpacing.md : AppSpacing.lg;

  Duration motionDuration(Duration duration) {
    final reduceMotion = MediaQuery.maybeOf(this)?.disableAnimations ?? false;
    return reduceMotion ? Duration.zero : duration;
  }
}
