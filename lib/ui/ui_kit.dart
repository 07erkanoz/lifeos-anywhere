import 'package:flutter/material.dart';

/// The AnyWhere 2.0 look (design: the "AnyWhere 2.0 arayüz maketi" mock):
/// colours that are not in the Material scheme, and the small pieces every
/// new screen uses.
class Ui {
  const Ui._(this.dark);

  factory Ui.of(BuildContext context) =>
      Ui._(Theme.of(context).brightness == Brightness.dark);

  final bool dark;

  Color get bg => dark ? const Color(0xFF100E17) : const Color(0xFFF7F6FB);
  Color get surface => dark ? const Color(0xFF1A1724) : Colors.white;
  Color get surfaceSunk => dark ? const Color(0xFF141120) : const Color(0xFFF1EFF7);
  Color get border => dark ? const Color(0xFF2B2739) : const Color(0xFFE4E1EE);
  Color get text => dark ? const Color(0xFFF1EEF8) : const Color(0xFF17141F);
  Color get muted => dark ? const Color(0xFFA59FB8) : const Color(0xFF5F5A6E);
  Color get accent => const Color(0xFF7C3AED);
  Color get accentSoft => dark ? const Color(0xFF2E2548) : const Color(0xFFEDE9FE);
  Color get accentText => dark ? const Color(0xFFC4B5FD) : const Color(0xFF6D28D9);
  Color get selectedRow => dark ? const Color(0xFF1F1A2E) : const Color(0xFFEFEAFC);
  Color get danger => dark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C);
  Color get warning => dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);

  /// How a device is reached right now.
  RouteLook route(Reach reach) => switch (reach) {
        Reach.lan => RouteLook(
            dot: const Color(0xFF22C55E),
            fg: dark ? const Color(0xFF4ADE80) : const Color(0xFF15803D),
            bg: dark ? const Color(0x1F4ADE80) : const Color(0xFFDCFCE7),
          ),
        Reach.internet => RouteLook(
            dot: const Color(0xFF60A5FA),
            fg: dark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8),
            bg: dark ? const Color(0x2460A5FA) : const Color(0xFFDBEAFE),
          ),
        Reach.off => RouteLook(
            dot: const Color(0xFF6B6680),
            fg: muted,
            bg: dark ? const Color(0x1FA59FB8) : const Color(0xFFEEECF3),
          ),
      };

  /// A per-platform tint for device avatars.
  (Color, Color) tintFor(String platform) => switch (platform) {
        'android' || 'ios' => (dark ? const Color(0xFF2C2416) : const Color(0xFFFEF3C7), const Color(0xFFF59E0B)),
        'windows' => (dark ? const Color(0xFF1B2537) : const Color(0xFFDBEAFE), const Color(0xFF60A5FA)),
        'android_tv' => (dark ? const Color(0xFF15291D) : const Color(0xFFDCFCE7), const Color(0xFF4ADE80)),
        _ => (dark ? const Color(0xFF2A2140) : const Color(0xFFEDE9FE), const Color(0xFFA78BFA)),
      };
}

enum Reach { lan, internet, off }

class RouteLook {
  const RouteLook({required this.dot, required this.fg, required this.bg});
  final Color dot;
  final Color fg;
  final Color bg;
}

IconData platformIcon(String platform) => switch (platform) {
      'android' || 'ios' => Icons.smartphone_rounded,
      'android_tv' => Icons.tv_rounded,
      'linux' || 'windows' || 'macos' => Icons.desktop_windows_rounded,
      _ => Icons.devices_other_rounded,
    };

/// The rounded square with the device's icon and its reach dot.
class DeviceAvatar extends StatelessWidget {
  const DeviceAvatar({
    super.key,
    required this.platform,
    this.reach,
    this.size = 48,
    this.dashed = false,
  });

  final String platform;
  final Reach? reach;
  final double size;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    final (tint, iconColor) = ui.tintFor(platform);
    final dotSize = size * 0.29;
    return SizedBox(
      width: size + 4,
      height: size + 4,
      child: Stack(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: dashed ? Colors.transparent : tint,
              borderRadius: BorderRadius.circular(size * 0.29),
              border: dashed ? Border.all(color: ui.muted, width: 1.5) : null,
            ),
            child: Icon(
              platformIcon(platform),
              size: size * 0.46,
              color: dashed ? ui.muted : iconColor,
            ),
          ),
          if (reach != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: dotSize,
                height: dotSize,
                decoration: BoxDecoration(
                  color: ui.route(reach!).dot,
                  shape: BoxShape.circle,
                  border: Border.all(color: ui.bg, width: 3),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Aynı ağda", "İnternetten", "Ağda değil": a small coloured tag.
class RouteBadge extends StatelessWidget {
  const RouteBadge({super.key, required this.reach, required this.label});
  final Reach reach;
  final String label;

  @override
  Widget build(BuildContext context) {
    final look = Ui.of(context).route(reach);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: look.bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: look.fg),
      ),
    );
  }
}

/// Small caps header above a group ("EŞLİ CİHAZLAR").
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.trailing, this.padding});
  final String text;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.9,
                color: ui.muted,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A rounded group of rows on the surface colour.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.children, this.margin, this.padding});
  final List<Widget> children;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    // Material, not a decorated box: list tiles inside paint their ink on it
    return Padding(
      padding: margin ?? const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: ui.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: ui.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: padding ?? EdgeInsets.zero,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ),
    );
  }
}

/// A page title row: big title, then actions.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.actions = const [], this.leading});
  final String title;
  final List<Widget> actions;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.2),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// A square icon button with a border (header actions).
class SquareIconButton extends StatelessWidget {
  const SquareIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.filled = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final ui = Ui.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: filled ? ui.accent : ui.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: filled ? BorderSide.none : BorderSide(color: ui.border),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onPressed,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon, size: 20, color: filled ? Colors.white : ui.text),
            ),
          ),
        ),
      ),
    );
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} GB';
}

/// "10.42", "Dün", "Pzt" or "12.11": when, as a chat list shows it.
String shortWhen(DateTime when, {String locale = 'tr'}) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(when.year, when.month, when.day);
  final diff = today.difference(day).inDays;
  String two(int v) => v.toString().padLeft(2, '0');
  if (diff == 0) return '${two(when.hour)}.${two(when.minute)}';
  final tr = locale == 'tr';
  if (diff == 1) return tr ? 'Dün' : 'Yesterday';
  if (diff < 7) {
    const trDays = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];
    const enDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return (tr ? trDays : enDays)[when.weekday - 1];
  }
  return '${two(when.day)}.${two(when.month)}';
}

/// AnyWhere's logo (assets/icons/logo.png), filling [size]: the picture has a
/// transparent margin (its mark is 398×356 of 512×512), cut off here so the
/// mark itself is [size] wide.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: ClipRect(
        child: OverflowBox(
          maxWidth: size * 512 / 398,
          maxHeight: size * 512 / 398,
          child: Image.asset(
            'assets/icons/logo.png',
            width: size * 512 / 398,
            height: size * 512 / 398,
            filterQuality: FilterQuality.medium,
            semanticLabel: 'AnyWhere',
          ),
        ),
      ),
    );
  }
}
