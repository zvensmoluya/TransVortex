import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/tokens.dart';

class DesignedTooltip extends StatefulWidget {
  const DesignedTooltip({
    super.key,
    required this.message,
    required this.child,
    this.width = 260,
    this.height = 82,
  });

  final String message;
  final Widget child;
  final double width;
  final double height;

  @override
  State<DesignedTooltip> createState() => _DesignedTooltipState();
}

class _DesignedTooltipState extends State<DesignedTooltip> {
  OverlayEntry? _entry;
  Timer? _showTimer;

  @override
  void dispose() {
    _showTimer?.cancel();
    _remove();
    super.dispose();
  }

  void _scheduleShow() {
    _showTimer?.cancel();
    _showTimer = Timer(const Duration(milliseconds: 320), _show);
  }

  void _show() {
    if (!mounted || _entry != null || widget.message.trim().isEmpty) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final target = context.findRenderObject();
    final overlayRender = overlay.context.findRenderObject();
    if (target is! RenderBox || overlayRender is! RenderBox) return;

    final targetOffset = target.localToGlobal(
      Offset.zero,
      ancestor: overlayRender,
    );
    final targetSize = target.size;
    final overlaySize = overlayRender.size;
    const edgeGap = 8.0;
    const targetGap = 7.0;
    final maxLeft = overlaySize.width - widget.width - edgeGap;
    final left = _clamp(
      targetOffset.dx + targetSize.width / 2 - widget.width / 2,
      edgeGap,
      maxLeft,
    );
    final aboveTop = targetOffset.dy - widget.height - targetGap;
    final belowTop = targetOffset.dy + targetSize.height + targetGap;
    final top = aboveTop >= edgeGap
        ? aboveTop
        : _clamp(
            belowTop,
            edgeGap,
            overlaySize.height - widget.height - edgeGap,
          );

    _entry = OverlayEntry(
      builder: (context) => Positioned(
        left: left,
        top: top,
        width: widget.width,
        height: widget.height,
        child: IgnorePointer(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOutCubic,
            builder: (context, value, child) => Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, (1 - value) * 4),
                child: child,
              ),
            ),
            child: _TooltipBubble(
              message: widget.message,
              width: widget.width,
              height: widget.height,
            ),
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  double _clamp(double value, double min, double max) {
    if (max < min) return min;
    return value.clamp(min, max).toDouble();
  }

  void _hide() {
    _showTimer?.cancel();
    _remove();
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _scheduleShow(),
      onExit: (_) => _hide(),
      child: Semantics(tooltip: widget.message, child: widget.child),
    );
  }
}

class _TooltipBubble extends StatelessWidget {
  const _TooltipBubble({
    required this.message,
    required this.width,
    required this.height,
  });

  final String message;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: SvgPicture.asset(
              'assets/ui/tooltip_panel.svg',
              fit: BoxFit.fill,
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 19, 26, 25),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption.copyWith(color: T.ink, height: 1.28),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
