import 'dart:math' as math;
import 'package:flutter/widgets.dart';

import '../model/session.dart';
import '../theme/tokens.dart';

/// 单主体「片源封套」的自绘世界对象（design spec §4.2 / §9）。
///
/// 一个连贯的 media/film 隐喻：一只带胶片齿孔的封套，片源放进来后它
/// 「收成封套」，制作时卷动字幕纸带，完成时推出交付件，失败时贴上修理贴。
/// 平涂赛璐珞 + 统一墨色描边、圆头线帽（§9.1 register B / §9.3）。
///
/// 只画物件；文件名 / 类型签 / 状态短句由上层文本组件叠加，保证 CJK 清晰。
class SourceObjectPainter extends CustomPainter {
  SourceObjectPainter({
    required this.state,
    required this.progress,
    required this.phaseIndex,
    required this.phaseCount,
    required this.phaseProgress,
    required this.breathe,
    required this.dragOver,
    required this.pickHover,
    required this.pickDown,
  });

  final MainState state;
  final double progress; // 0..1 真实进度
  final int phaseIndex;
  final int phaseCount;
  final double phaseProgress;
  final double breathe; // 0..1 连续呼吸相位
  final double dragOver; // 0..1 拖入强反馈
  final bool pickHover; // 空态点击投递区的 hover 反馈
  final bool pickDown; // 空态点击投递区的按下反馈

  static const _strokeBase = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // 呼吸 + 拖入轻微放大（GPU 友好的纯变换，无 layout）。
    final scale = 1 + 0.012 * math.sin(breathe * 2 * math.pi) + 0.05 * dragOver;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(scale);
    canvas.translate(-center.dx, -center.dy);

    final w = math.min(size.width * 0.56, 248.0);
    final h = w * 0.62;
    final body = Rect.fromCenter(center: center, width: w, height: h);

    if (state != MainState.empty) {
      _drawShadow(canvas, body);
    }
    if (dragOver > 0.01) _drawDropHalo(canvas, body);

    switch (state) {
      case MainState.empty:
        _drawOpenSlot(canvas, body);
        break;
      case MainState.ready:
      case MainState.blocked:
        _drawEnvelope(canvas, body, tint: T.accentSoft);
        _drawBindingTab(canvas, body, warning: state == MainState.blocked);
        break;
      case MainState.running:
        _drawEnvelope(canvas, body, tint: T.accentSoft);
        _drawReels(canvas, body);
        _drawProductionTape(canvas, body);
        break;
      case MainState.completed:
        _drawEnvelope(canvas, body, tint: T.accentSoft);
        _drawDeliveryStrip(canvas, body);
        _drawCheckBadge(canvas, body);
        break;
      case MainState.failed:
        _drawEnvelope(canvas, body, tint: T.lilacSoft, dim: true);
        _drawJammedTape(canvas, body);
        _drawRepairPatch(canvas, body);
        break;
    }

    canvas.restore();
  }

  // —— 基础绘制工具 ——

  Paint get _ink => Paint()
    ..color = T.inkLine
    ..style = PaintingStyle.stroke
    ..strokeWidth = _strokeBase
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  Paint _fill(Color c) => Paint()
    ..color = c
    ..style = PaintingStyle.fill;

  void _drawShadow(Canvas canvas, Rect body) {
    final shadow = RRect.fromRectAndRadius(
      body.shift(const Offset(0, 10)),
      const Radius.circular(18),
    );
    canvas.drawRRect(
      shadow,
      Paint()
        ..color = const Color(0x14000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );
  }

  void _drawDropHalo(Canvas canvas, Rect body) {
    final halo = RRect.fromRectAndRadius(
      body.inflate(18 * dragOver),
      const Radius.circular(24),
    );
    canvas.drawRRect(
      halo,
      Paint()
        ..color = T.accent.withValues(alpha: 0.10 * dragOver)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      halo,
      Paint()
        ..color = T.accent.withValues(alpha: 0.55 * dragOver)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _sprockets(Canvas canvas, Rect body) {
    // 两侧胶片齿孔，点明 media/film 世界。
    final holePaint = _fill(T.bg);
    const rows = 4;
    final hw = body.width * 0.05;
    final hh = body.height * 0.11;
    for (var i = 0; i < rows; i++) {
      final dy = body.top + body.height * (0.18 + 0.21 * i);
      for (final dx in [
        body.left + body.width * 0.06,
        body.right - body.width * 0.06 - hw,
      ]) {
        final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(dx, dy, hw, hh),
          const Radius.circular(2),
        );
        canvas.drawRRect(r, holePaint);
        canvas.drawRRect(r, _ink..strokeWidth = 1.6);
      }
    }
  }

  // —— 空态：投递口开着 ——
  void _drawOpenSlot(Canvas canvas, Rect body) {
    final interaction = math.max(dragOver, pickHover ? 1.0 : 0.0);
    final rrect = RRect.fromRectAndRadius(body, const Radius.circular(16));
    canvas.drawRRect(
      rrect,
      _fill(pickDown ? T.accentSoft.withValues(alpha: 0.42) : T.surface),
    );
    canvas.drawRRect(
      rrect,
      _ink
        ..color = Color.lerp(T.inkLine, T.accent, interaction * 0.32)!
        ..strokeWidth = _strokeBase + 0.4 * interaction,
    );
    _sprockets(canvas, body);

    // 掀开的盖子（梯形，浮在投递口上方）。
    final flapH = body.height * 0.42;
    final flap = Path()
      ..moveTo(body.left + 10, body.top + 6)
      ..lineTo(body.right - 10, body.top + 6)
      ..lineTo(body.right - 30, body.top - flapH)
      ..lineTo(body.left + 30, body.top - flapH)
      ..close();
    canvas.drawPath(
      flap,
      _fill(
        Color.lerp(T.accentSoft, const Color(0xFFFFD8E5), interaction * 0.45)!,
      ),
    );
    canvas.drawPath(
      flap,
      _ink
        ..color = Color.lerp(T.inkLine, T.accent, interaction * 0.25)!
        ..strokeWidth = _strokeBase,
    );

    // 投递口内的下行提示箭头。
    final cx = body.center.dx;
    final ay = body.center.dy - 6 + (pickDown ? 2 : 0);
    final arrow = Path()
      ..moveTo(cx, ay - 18)
      ..lineTo(cx, ay + 14)
      ..moveTo(cx - 12, ay + 2)
      ..lineTo(cx, ay + 14)
      ..lineTo(cx + 12, ay + 2);
    canvas.drawPath(
      arrow,
      _ink
        ..color = T.accent
        ..strokeWidth = 3.2 + 0.6 * interaction,
    );

    _drawLandingMark(canvas, body, interaction);
  }

  void _drawLandingMark(Canvas canvas, Rect body, double interaction) {
    final y = body.bottom - body.height * 0.20 + (pickDown ? 1.5 : 0);
    final left = body.center.dx - body.width * 0.20;
    final right = body.center.dx + body.width * 0.20;
    final paint = Paint()
      ..color = T.accent.withValues(alpha: 0.34 + 0.36 * interaction)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 + 0.7 * interaction
      ..strokeCap = StrokeCap.round;

    if (interaction > 0.08) {
      canvas.drawLine(Offset(left, y), Offset(right, y), paint);
      canvas.drawLine(
        Offset(body.center.dx - 8, y + 6),
        Offset(body.center.dx + 8, y + 6),
        paint..strokeWidth = 1.1 + 0.4 * interaction,
      );
      return;
    }

    var x = left;
    while (x < right) {
      final segmentRight = math.min(x + 8, right);
      canvas.drawLine(Offset(x, y), Offset(segmentRight, y), paint);
      x += 14;
    }
  }

  // —— 已放入 / 受阻 / 运行 / 完成 的封套主体 ——
  void _drawEnvelope(
    Canvas canvas,
    Rect body, {
    required Color tint,
    bool dim = false,
  }) {
    final rrect = RRect.fromRectAndRadius(body, const Radius.circular(16));
    canvas.drawRRect(rrect, _fill(dim ? const Color(0xFFF7F1F3) : T.surface));
    canvas.drawRRect(rrect, _ink);
    _sprockets(canvas, body);

    // 顶部封盖压线（闭合）。
    final flapY = body.top + body.height * 0.30;
    final flap = Path()
      ..moveTo(body.left, flapY)
      ..lineTo(body.center.dx, flapY + body.height * 0.16)
      ..lineTo(body.right, flapY);
    canvas.drawPath(flap, _ink);

    // 中部标签带（放文件名的底，文字由组件叠加）。
    final band = RRect.fromRectAndRadius(
      _bandRect(body),
      const Radius.circular(T.rSm),
    );
    canvas.drawRRect(band, _fill(dim ? const Color(0xFFEDE6E9) : tint));
    canvas.drawRRect(band, _ink..strokeWidth = 1.8);
  }

  Rect _bandRect(Rect body) => Rect.fromLTWH(
    body.left + body.width * 0.16,
    body.center.dy + body.height * 0.04,
    body.width * 0.68,
    body.height * 0.22,
  );

  void _drawBindingTab(Canvas canvas, Rect body, {required bool warning}) {
    final center = Offset(
      body.left + body.width * 0.28,
      body.top + body.height * 0.06,
    );
    final tab = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center,
        width: body.width * 0.20,
        height: body.height * 0.16,
      ),
      const Radius.circular(3),
    );
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-0.07);
    canvas.translate(-center.dx, -center.dy);
    canvas.drawRRect(
      tab,
      _fill(warning ? T.warn.withValues(alpha: 0.34) : const Color(0xFFFFE6B8)),
    );
    canvas.drawLine(
      Offset(tab.left + 8, tab.center.dy),
      Offset(tab.right - 8, tab.center.dy),
      _ink
        ..color = T.inkLine.withValues(alpha: 0.46)
        ..strokeWidth = 1.2,
    );
    canvas.restore();
  }

  // —— 制作中：卷轴持续运动，字幕纸带长度只反映真实进度 ——
  void _drawReels(Canvas canvas, Rect body) {
    final y = body.top + body.height * 0.30;
    final left = Offset(body.center.dx - 15, y);
    final right = Offset(body.center.dx + 15, y);
    final line = _ink
      ..color = T.inkLine.withValues(alpha: 0.72)
      ..strokeWidth = 1.6;
    canvas.drawLine(left, right, line);
    for (final center in [left, right]) {
      canvas.drawCircle(center, 8, _fill(T.surface));
      canvas.drawCircle(center, 8, line);
      final angle = breathe * math.pi * 2 + (center == right ? 0.8 : 0);
      final spoke = Offset(math.cos(angle), math.sin(angle)) * 5;
      canvas.drawLine(center - spoke, center + spoke, line..strokeWidth = 1.2);
    }
  }

  void _drawProductionTape(Canvas canvas, Rect body) {
    final band = _bandRect(body).deflate(4);
    final tape = RRect.fromRectAndRadius(band, const Radius.circular(4));
    canvas.drawRRect(tape, _fill(T.surface.withValues(alpha: 0.92)));
    canvas.drawRRect(
      tape,
      _ink
        ..color = T.inkLine.withValues(alpha: 0.52)
        ..strokeWidth = 1,
    );

    final safePhaseCount = math.max(1, phaseCount);
    final gap = 2.0;
    final track = Rect.fromLTWH(
      band.left + 5,
      band.bottom - 8,
      band.width - 10,
      4,
    );
    final cellWidth =
        (track.width - gap * (safePhaseCount - 1)) / safePhaseCount;
    for (var index = 0; index < safePhaseCount; index += 1) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          track.left + index * (cellWidth + gap),
          track.top,
          cellWidth,
          track.height,
        ),
        const Radius.circular(2),
      );
      final completed = index < phaseIndex;
      final active = index == phaseIndex;
      final color = completed
          ? T.ok.withValues(alpha: 0.72)
          : active
          ? T.accent.withValues(alpha: 0.82)
          : T.line;
      canvas.drawRRect(rect, _fill(color));
      if (active && phaseProgress > 0 && phaseProgress < 1) {
        final fill = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            rect.left,
            rect.top,
            rect.width * phaseProgress.clamp(0.0, 1.0),
            rect.height,
          ),
          const Radius.circular(2),
        );
        canvas.drawRRect(fill, _fill(T.accentStrong));
      }
    }

    final perforationY = band.top + 4;
    for (var index = 0; index < safePhaseCount; index += 1) {
      final x = track.left + (index + 0.5) * track.width / safePhaseCount;
      canvas.drawCircle(
        Offset(x, perforationY),
        1.25,
        _fill(index <= phaseIndex ? T.warn : T.line),
      );
    }

    final subtitleY = band.center.dy - 1;
    final subtitlePaint = _ink
      ..color = T.inkLine.withValues(alpha: 0.62)
      ..strokeWidth = 1.1;
    canvas.drawLine(
      Offset(band.left + 12, subtitleY - 2),
      Offset(band.center.dx - 3, subtitleY - 2),
      subtitlePaint,
    );
    canvas.drawLine(
      Offset(band.center.dx + 3, subtitleY + 1.5),
      Offset(band.right - 12, subtitleY + 1.5),
      subtitlePaint..color = T.sky.withValues(alpha: 0.76),
    );

    final normalized = progress.clamp(0.0, 1.0);
    final signalX = normalized > 0
        ? track.left + track.width * normalized
        : track.left + (track.width - 8) * breathe;
    canvas.drawCircle(
      Offset(
        signalX.clamp(track.left + 2, track.right - 2).toDouble(),
        track.top - 1,
      ),
      2.4 + 0.5 * math.sin(breathe * math.pi * 2).abs(),
      _fill(T.accentStrong),
    );
  }

  // —— 完成：字幕纸带从封套中成为可交付结果 ——
  void _drawDeliveryStrip(Canvas canvas, Rect body) {
    final band = _bandRect(body);
    final strip = Path()
      ..moveTo(band.left + 8, band.top + 4)
      ..lineTo(body.right + 18, band.top + 4)
      ..lineTo(body.right + 12, band.center.dy)
      ..lineTo(body.right + 18, band.bottom - 4)
      ..lineTo(band.left + 8, band.bottom - 4)
      ..close();
    canvas.drawPath(strip, _fill(const Color(0xFFFFFCF7)));
    canvas.drawPath(
      strip,
      _ink
        ..color = T.inkLine
        ..strokeWidth = 1.7,
    );
    final linePaint = _ink
      ..color = T.inkLine.withValues(alpha: 0.86)
      ..strokeWidth = 2.6;
    canvas.drawLine(
      Offset(band.left + 20, band.center.dy - 4),
      Offset(body.right - 8, band.center.dy - 4),
      linePaint,
    );
    canvas.drawLine(
      Offset(band.left + 20, band.center.dy + 5),
      Offset(body.right - 28, band.center.dy + 5),
      linePaint..strokeWidth = 2,
    );
  }

  void _drawJammedTape(Canvas canvas, Rect body) {
    final band = _bandRect(body);
    final tape = Path()
      ..moveTo(band.right - 18, band.center.dy - 8)
      ..lineTo(body.right + 12, band.center.dy - 8)
      ..lineTo(body.right + 4, band.center.dy)
      ..lineTo(body.right + 12, band.center.dy + 8)
      ..lineTo(band.right - 18, band.center.dy + 8)
      ..close();
    canvas.drawPath(tape, _fill(const Color(0xFFFBE4E0)));
    canvas.drawPath(
      tape,
      _ink
        ..color = T.danger.withValues(alpha: 0.82)
        ..strokeWidth = 1.8,
    );
  }

  void _drawCheckBadge(Canvas canvas, Rect body) {
    final c = Offset(body.right - 6, body.top + 2);
    canvas.drawCircle(c, 15, _fill(T.accent));
    canvas.drawCircle(
      c,
      15,
      _ink
        ..strokeWidth = 2
        ..color = T.inkLine,
    );
    final tick = Path()
      ..moveTo(c.dx - 6, c.dy)
      ..lineTo(c.dx - 1.5, c.dy + 5)
      ..lineTo(c.dx + 7, c.dy - 6);
    canvas.drawPath(
      tick,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  // —— 失败：修理贴（形态与「接近完成」明确可分，不萌化）——
  void _drawRepairPatch(Canvas canvas, Rect body) {
    final c = Offset(body.center.dx, body.center.dy + body.height * 0.06);
    final patch = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: c,
        width: body.width * 0.42,
        height: body.height * 0.3,
      ),
      const Radius.circular(T.rSm),
    );
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-0.12);
    canvas.translate(-c.dx, -c.dy);
    canvas.drawRRect(patch, _fill(const Color(0xFFFBE4E0)));
    canvas.drawRRect(
      patch,
      Paint()
        ..color = T.danger
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
    // 缝合线交叉（区别于完成态的对勾）。
    final cross = Path()
      ..moveTo(c.dx - 9, c.dy - 8)
      ..lineTo(c.dx + 9, c.dy + 8)
      ..moveTo(c.dx + 9, c.dy - 8)
      ..lineTo(c.dx - 9, c.dy + 8);
    canvas.drawPath(
      cross,
      Paint()
        ..color = T.danger
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(SourceObjectPainter old) =>
      old.state != state ||
      old.progress != progress ||
      old.phaseIndex != phaseIndex ||
      old.phaseCount != phaseCount ||
      old.phaseProgress != phaseProgress ||
      old.breathe != breathe ||
      old.dragOver != dragOver ||
      old.pickHover != pickHover ||
      old.pickDown != pickDown;
}
