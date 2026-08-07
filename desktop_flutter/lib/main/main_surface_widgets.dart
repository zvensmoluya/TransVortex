part of '../main.dart';

class _RunningStatusSlip extends StatelessWidget {
  const _RunningStatusSlip({
    required this.title,
    required this.counter,
    required this.detail,
    required this.progress,
    required this.canceling,
  });

  final String title;
  final String counter;
  final String detail;
  final double progress;
  final bool canceling;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 390,
      height: 58,
      child: CustomPaint(
        painter: _RunningStatusSlipPainter(
          progress: progress,
          canceling: canceling,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(T.s16, 9, T.s16, 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.tSection.copyWith(
                        color: canceling ? T.danger : T.accentStrong,
                        fontWeight: T.wBold,
                      ),
                    ),
                  ),
                  if (counter.isNotEmpty) ...[
                    const SizedBox(width: T.s12),
                    Text(counter, style: T.tCaption),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RunningStatusSlipPainter extends CustomPainter {
  const _RunningStatusSlipPainter({
    required this.progress,
    required this.canceling,
  });

  final double progress;
  final bool canceling;

  @override
  void paint(Canvas canvas, Size size) {
    final paper = Path()
      ..moveTo(5, 2)
      ..lineTo(size.width - 9, 0)
      ..lineTo(size.width, 7)
      ..lineTo(size.width - 3, size.height - 4)
      ..lineTo(8, size.height)
      ..lineTo(0, size.height - 7)
      ..close();
    canvas.drawPath(paper, Paint()..color = T.surface);
    canvas.drawPath(
      paper,
      Paint()
        ..color = T.inkLine.withValues(alpha: 0.42)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..strokeJoin = StrokeJoin.round,
    );

    final tape = Path()
      ..moveTo(18, 0)
      ..lineTo(68, 0)
      ..lineTo(64, 7)
      ..lineTo(15, 8)
      ..close();
    canvas.drawPath(tape, Paint()..color = T.skySoft);
    canvas.drawLine(
      Offset(18, 7.5),
      Offset(64, 6.5),
      Paint()
        ..color = T.sky.withValues(alpha: 0.62)
        ..strokeWidth = 1,
    );

    final left = 14.0;
    final right = size.width - 14;
    final y = size.height - 6;
    canvas.drawLine(
      Offset(left, y),
      Offset(right, y),
      Paint()
        ..color = T.line
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    final fraction = progress.clamp(0.0, 1.0);
    canvas.drawLine(
      Offset(left, y),
      Offset(left + (right - left) * fraction, y),
      Paint()
        ..color = canceling ? T.danger : T.accent
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RunningStatusSlipPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.canceling != canceling;
  }
}

enum _MenuAction { footer, moreTranslationModels, reasoningEffort }

const Object _menuFooter = _MenuAction.footer;
const Object _menuMoreTranslationModels = _MenuAction.moreTranslationModels;
const Object _menuReasoningEffort = _MenuAction.reasoningEffort;

class _TypeTag extends StatelessWidget {
  const _TypeTag({required this.kind});
  final SourceKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 3),
      decoration: BoxDecoration(
        color: T.accentSoft,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.accent, width: 1),
      ),
      child: Text(
        kind.zh,
        style: T.tCaption.copyWith(
          color: T.accentStrong,
          fontWeight: T.wMedium,
        ),
      ),
    );
  }
}

class _DropPickTarget extends StatefulWidget {
  const _DropPickTarget({
    required this.child,
    required this.onTap,
    required this.onHoverChanged,
    required this.onDownChanged,
  });

  final Widget child;
  final VoidCallback onTap;
  final ValueChanged<bool> onHoverChanged;
  final ValueChanged<bool> onDownChanged;

  @override
  State<_DropPickTarget> createState() => _DropPickTargetState();
}

class _DropPickTargetState extends State<_DropPickTarget> {
  bool _hover = false;
  bool _down = false;

  void _setHover(bool value) {
    if (_hover == value) return;
    _hover = value;
    widget.onHoverChanged(value);
  }

  void _setDown(bool value) {
    if (_down == value) return;
    _down = value;
    widget.onDownChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHover(true),
      onExit: (_) {
        _setHover(false);
        _setDown(false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setDown(true),
        onTapUp: (_) => _setDown(false),
        onTapCancel: () => _setDown(false),
        onTap: widget.onTap,
        child: Semantics(
          key: const ValueKey('main-empty-pick-target'),
          button: true,
          label: '浏览文件',
          child: widget.child,
        ),
      ),
    );
  }
}

class _HeroPrompt extends StatelessWidget {
  const _HeroPrompt({required this.text, required this.active});

  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 140),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: SizedBox(
        key: ValueKey(text),
        width: 390,
        height: 46,
        child: CustomPaint(
          painter: _HeroPromptPainter(active: active),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: T.displayFontFamily,
                  fontSize: 23,
                  fontWeight: T.wMedium,
                  height: 1.0,
                  letterSpacing: 0,
                ).copyWith(color: active ? T.accentStrong : T.ink),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroPromptPainter extends CustomPainter {
  const _HeroPromptPainter({required this.active});

  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height * 0.58;
    final fillPath = Path()
      ..moveTo(22, 10)
      ..quadraticBezierTo(size.width * 0.38, 5.5, size.width - 34, 9)
      ..lineTo(size.width - 20, centerY + 9)
      ..quadraticBezierTo(size.width * 0.52, centerY + 15, 26, centerY + 10)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..color = active
            ? T.accentSoft.withValues(alpha: 0.46)
            : T.surface.withValues(alpha: 0.56),
    );

    final underline = Paint()
      ..color = active
          ? T.accent.withValues(alpha: 0.76)
          : T.accent.withValues(alpha: 0.34)
      ..style = PaintingStyle.stroke
      ..strokeWidth = active ? 2.0 : 1.4
      ..strokeCap = StrokeCap.round;

    final underlineY = size.height - 7;
    final segments = active
        ? <(double, double)>[(73, 219)]
        : <(double, double)>[(78, 102), (112, 139), (150, 178), (188, 214)];
    for (final segment in segments) {
      canvas.drawLine(
        Offset(segment.$1, underlineY),
        Offset(segment.$2, underlineY),
        underline,
      );
    }

    final dotPaint = Paint()
      ..color = active
          ? T.sky.withValues(alpha: 0.8)
          : T.sky.withValues(alpha: 0.46)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(48, 15), active ? 2.2 : 1.7, dotPaint);
    canvas.drawCircle(
      Offset(size.width - 51, 14),
      active ? 2.0 : 1.5,
      dotPaint,
    );

    final spark = Paint()
      ..color = T.accent.withValues(alpha: active ? 0.78 : 0.38)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(36, 25), const Offset(42, 25), spark);
    canvas.drawLine(const Offset(39, 22), const Offset(39, 28), spark);
    canvas.drawLine(
      Offset(size.width - 36, 25),
      Offset(size.width - 30, 25),
      spark,
    );
    canvas.drawLine(
      Offset(size.width - 33, 22),
      Offset(size.width - 33, 28),
      spark,
    );
  }

  @override
  bool shouldRepaint(covariant _HeroPromptPainter oldDelegate) =>
      oldDelegate.active != active;
}

class _PendingTaskSlip extends StatelessWidget {
  const _PendingTaskSlip({
    required this.reminder,
    required this.onResume,
    required this.onOpen,
    required this.onDismiss,
  });

  final HomeTaskReminder reminder;
  final VoidCallback onResume;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final hasMany = reminder.resumableCount > 1;
    final title = hasMany
        ? '有 ${reminder.resumableCount} 个未完成制作'
        : '有 1 个未完成制作';
    final source = reminder.sourceName.trim();
    final sourceLabel = source.isEmpty
        ? '上次制作还没完成'
        : hasMany
        ? '最近：$source'
        : source;
    return SizedBox(
      width: 430,
      height: 78,
      child: CustomPaint(
        painter: _PendingTaskSlipPainter(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(T.s24, T.s12, T.s16, T.s8),
          child: Row(
            children: [
              SizedBox(
                width: 58,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '待续',
                      style: T.tSection.copyWith(color: T.accentStrong),
                    ),
                    const SizedBox(height: 2),
                    Text('制作', style: T.tCaption.copyWith(fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: T.s12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.tBody.copyWith(fontWeight: T.wMedium),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      sourceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.tCaption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: T.s12),
              _SlipAction(
                label: hasMany ? '继续最近' : '继续',
                onTap: onResume,
                primary: true,
              ),
              const SizedBox(width: T.s8),
              _SlipAction(label: hasMany ? '查看全部' : '查看', onTap: onOpen),
              const SizedBox(width: T.s4),
              _SlipAction(label: '稍后', onTap: onDismiss),
            ],
          ),
        ),
      ),
    );
  }
}

class _PendingTaskSlipPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paper = Path()
      ..moveTo(13, 9)
      ..lineTo(size.width - 34, 5)
      ..lineTo(size.width - 12, 22)
      ..lineTo(size.width - 15, size.height - 12)
      ..lineTo(24, size.height - 6)
      ..lineTo(8, size.height - 22)
      ..close();
    canvas.drawPath(
      paper,
      Paint()
        ..color = T.surface
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      paper,
      Paint()
        ..color = T.line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round,
    );

    final fold = Path()
      ..moveTo(size.width - 34, 5)
      ..lineTo(size.width - 12, 22)
      ..lineTo(size.width - 35, 24)
      ..close();
    canvas.drawPath(
      fold,
      Paint()
        ..color = T.accentSoft.withValues(alpha: 0.65)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      fold,
      Paint()
        ..color = T.line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final tape = Path()
      ..moveTo(42, 0)
      ..lineTo(122, 0)
      ..lineTo(116, 14)
      ..lineTo(36, 14)
      ..close();
    canvas.drawPath(
      tape,
      Paint()
        ..color = T.sky.withValues(alpha: 0.18)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      tape,
      Paint()
        ..color = T.sky.withValues(alpha: 0.30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final divider = Paint()
      ..color = T.line
      ..strokeWidth = 1;
    canvas.drawLine(
      const Offset(92, 17),
      Offset(92, size.height - 17),
      divider,
    );

    final holePaint = Paint()
      ..color = T.bg
      ..style = PaintingStyle.fill;
    final holeStroke = Paint()
      ..color = T.inkLine.withValues(alpha: 0.62)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    for (final y in [25.0, 39.0, 53.0]) {
      final rect = Rect.fromCenter(center: Offset(22, y), width: 7, height: 8);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(2));
      canvas
        ..drawRRect(rrect, holePaint)
        ..drawRRect(rrect, holeStroke);
    }

    canvas.drawCircle(
      const Offset(390, 56),
      2.4,
      Paint()
        ..color = T.warn.withValues(alpha: 0.75)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _PendingTaskSlipPainter oldDelegate) => false;
}

class _SlipAction extends StatefulWidget {
  const _SlipAction({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  State<_SlipAction> createState() => _SlipActionState();
}

class _SlipActionState extends State<_SlipAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fg = widget.primary ? const Color(0xFFFFFFFF) : T.accentStrong;
    final bg = widget.primary
        ? (_hover ? T.accentStrong : T.accent)
        : (_hover ? T.accentSoft : const Color(0x00000000));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: T.s8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(color: T.accent, width: 1),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.tCaption.copyWith(color: fg, fontWeight: T.wMedium),
          ),
        ),
      ),
    );
  }
}

class _RepairStrip extends StatelessWidget {
  const _RepairStrip({required this.failure, required this.onTap});

  final MainFailureView? failure;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          constraints: const BoxConstraints(maxWidth: 440),
          margin: const EdgeInsets.only(top: T.s4),
          padding: const EdgeInsets.symmetric(
            horizontal: T.s12,
            vertical: T.s8,
          ),
          decoration: BoxDecoration(
            color: T.lilacSoft,
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(color: T.line, width: 1.2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 3,
                height: 30,
                decoration: BoxDecoration(
                  color: T.danger,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: T.s8),
              Icon(_repairIcon(failure?.target), size: 18, color: T.danger),
              const SizedBox(width: T.s8),
              Flexible(
                child: Text(
                  failure?.reason ?? '制作失败',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption.copyWith(color: T.ink),
                ),
              ),
              const SizedBox(width: T.s12),
              _Chip(label: failure?.actionLabel ?? '重试', onTap: onTap),
            ],
          ),
        ),
        Positioned(
          top: 0,
          left: T.s24,
          child: IgnorePointer(
            child: Container(
              width: 42,
              height: 8,
              decoration: BoxDecoration(
                color: T.accentSoft.withValues(alpha: 0.92),
                border: Border.all(color: T.accent.withValues(alpha: 0.42)),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

IconData _repairIcon(MainRecoveryTarget? target) => switch (target) {
  MainRecoveryTarget.translationSettings => Icons.translate_rounded,
  MainRecoveryTarget.asrSettings => Icons.graphic_eq_rounded,
  MainRecoveryTarget.pickSource => Icons.video_file_rounded,
  MainRecoveryTarget.outputDirectory ||
  MainRecoveryTarget.reexportDirectory ||
  MainRecoveryTarget.reexport => Icons.folder_copy_rounded,
  MainRecoveryTarget.resume => Icons.play_arrow_rounded,
  MainRecoveryTarget.cancel => Icons.stop_circle_outlined,
  MainRecoveryTarget.taskProcessing => Icons.receipt_long_rounded,
  MainRecoveryTarget.retry || null => Icons.refresh_rounded,
};

class _TextAction extends StatefulWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_TextAction> createState() => _TextActionState();
}

class _TextActionState extends State<_TextAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: 4),
          child: Text(
            widget.label,
            style: T.tCaption.copyWith(
              color: _hover ? T.accentStrong : T.muted,
              decoration: _hover
                  ? TextDecoration.underline
                  : TextDecoration.none,
              decorationColor: T.accentStrong,
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatefulWidget {
  const _Chip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    const color = T.accentStrong;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: 7),
          decoration: BoxDecoration(
            color: _hover ? T.accentSoft : const Color(0x00000000),
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(color: color, width: 1.4),
          ),
          child: Text(
            widget.label,
            style: T.tBody.copyWith(color: color, fontWeight: T.wMedium),
          ),
        ),
      ),
    );
  }
}
