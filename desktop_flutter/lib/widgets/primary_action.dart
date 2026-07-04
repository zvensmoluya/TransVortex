import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';

/// 主动作焦点 CTA（design spec §4.4）。样子 = 当前状态，承载全部六态。
/// 三种观感：filled（主焦点，选择片源 / 开始 / 重试）、outline（次级，停止任务）、
/// disabled（保留给不可执行的未来状态）。hover / active / disabled 四态可读（G7）。
enum CtaVariant { filled, outline, disabled }

class PrimaryAction extends StatefulWidget {
  const PrimaryAction({
    super.key,
    required this.label,
    required this.variant,
    this.onTap,
  });

  final String label;
  final CtaVariant variant;
  final VoidCallback? onTap;

  @override
  State<PrimaryAction> createState() => _PrimaryActionState();
}

class _PrimaryActionState extends State<PrimaryAction> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.variant == CtaVariant.disabled;
    final filled = widget.variant == CtaVariant.filled;

    late final Color bg;
    late final Color fg;
    late final Color border;
    if (disabled) {
      bg = T.line;
      fg = T.muted;
      border = T.line;
    } else if (filled) {
      bg = _down ? T.accentStrong : (_hover ? T.accentStrong : T.accent);
      fg = const Color(0xFFFFFFFF);
      border = bg;
    } else {
      // outline
      bg = _hover ? T.accentSoft : const Color(0x00000000);
      fg = T.accentStrong;
      border = T.accent;
    }

    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        onTapDown: disabled ? null : (_) => setState(() => _down = true),
        onTapUp: disabled ? null : (_) => setState(() => _down = false),
        onTapCancel: disabled ? null : () => setState(() => _down = false),
        onTap: disabled ? null : widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOut,
          height: 46,
          constraints: const BoxConstraints(minWidth: 180),
          padding: const EdgeInsets.symmetric(horizontal: T.s32),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(color: border, width: 1.6),
            boxShadow: filled && !disabled
                ? [
                    BoxShadow(
                      color: T.accent.withValues(alpha: 0.30),
                      blurRadius: _hover ? 16 : 10,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: Text(widget.label, style: T.tCta.copyWith(color: fg)),
        ),
      ),
    );
  }
}
