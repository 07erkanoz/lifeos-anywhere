import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:anyware/core/theme.dart';

/// Focus indicator widget for TV D-pad navigation.
///
/// Applies a neon glow effect and a subtle scale animation when focused.
/// Matches the premium glow effect in the reference TV design.
class TvFocusWrapper extends StatefulWidget {
  const TvFocusWrapper({
    super.key,
    required this.child,
    this.focusNode,
    this.autofocus = false,
    this.onSelect,
    this.glowColor,
    this.borderRadius = 14.0,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onSelect;
  final Color? glowColor;
  final double borderRadius;
  final EdgeInsets padding;

  @override
  State<TvFocusWrapper> createState() => _TvFocusWrapperState();
}

class _TvFocusWrapperState extends State<TvFocusWrapper>
    with SingleTickerProviderStateMixin {
  late FocusNode _focusNode;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
  }

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.select ||
          event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter ||
          event.logicalKey == LogicalKeyboardKey.gameButtonA) {
        widget.onSelect?.call();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glow = widget.glowColor ??
        (isDark ? AppColors.neonBlue : AppColors.lightPrimary);

    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      onKeyEvent: _handleKeyEvent,
      child: AnimatedScale(
        scale: _isFocused ? 1.02 : 1.0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          padding: widget.padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: _isFocused
                ? Border.all(
                    color: glow.withValues(alpha: 0.6),
                    width: 2,
                  )
                : Border.all(
                    color: Colors.transparent,
                    width: 2,
                  ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: glow.withValues(alpha: 0.35),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                    BoxShadow(
                      color: glow.withValues(alpha: 0.12),
                      blurRadius: 24,
                      spreadRadius: 4,
                    ),
                  ]
                : [],
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
