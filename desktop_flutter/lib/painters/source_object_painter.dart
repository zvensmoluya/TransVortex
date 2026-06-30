import 'dart:math' as math;
import 'package:flutter/widgets.dart';

import '../model/session.dart';
import '../theme/tokens.dart';

/// 单主体「片源封套」的自绘世界对象（design spec §4.2 / §9）。
///
/// 一个连贯的 media/film 隐喻：一只带胶片齿孔的封套，片源放进来后它
/// 「收成封套」，制作时就地显进度，完成时长出字幕带，失败时贴上修理贴。
/// 平涂赛璐珞 + 统一墨色描边、圆头线帽（§9.1 register B / §9.3）。
///
/// 只画物件；文件名 / 类型签 / 状态短句由上层文本组件叠加，保证 CJK 清晰。
class SourceObjectPainter extends CustomPainter {
  SourceObjectPainter({
    required this.state,
    required this.progress,
    required this.breathe,
    required this.dragOver,
  });

  final MainState state;
  final double progress; // 0..1 真实进度
  final double breathe; // 0..1 连续呼吸相位
  final double dragOver; // 0..1 拖入强反馈

  static const _strokeBase = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // 呼吸 + 拖入轻微放大（GPU 友好的纯变换，无 layout）。
    final scale =
        1 + 0.012 * math.sin(breathe * 2 * math.pi) + 0.05 * dragOver;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(scale);
    canvas.translate(-center.dx, -center.dy);

    final w = math.min(size.width * 0.56, 248.0);
    final h = w * 0.62;
    final body = Rect.fromCenter(center: center, width: w, height: h);

    _drawShadow(canvas, body);
    if (dragOver > 0.01) _drawDropHalo(canvas, body);

    switch (state) {
      case MainState.empty:
        _drawOpenSlot(canvas, body);
        break;
      case MainState.ready:
      case MainState.blocked:
        _drawEnvelope(canvas, body, tint: T.accentSoft);
        break;
      case MainState.running:
        _drawEnvelope(canvas, body, tint: T.accentSoft);
        _drawProgress(canvas, body);
        break;
      case MainState.completed:
        _drawEnvelope(canvas, body, tint: T.accentSoft);
        _drawSubtitleBand(canvas, body);
        _drawCheckBadge(canvas, body);
        break;
      case MainState.failed:
        _drawEnvelope(canvas, body, tint: const Color(0xFFF1EAEC), dim: true);
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
      for (final dx in [body.left + body.width * 0.06, body.right - body.width * 0.06 - hw]) {
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
    final rrect = RRect.fromRectAndRadius(body, const Radius.circular(16));
    canvas.drawRRect(rrect, _fill(T.surface));
    canvas.drawRRect(rrect, _ink);
    _sprockets(canvas, body);

    // 掀开的盖子（梯形，浮在投递口上方）。
    final flapH = body.height * 0.42;
    final flap = Path()
      ..moveTo(body.left + 10, body.top + 6)
      ..lineTo(body.right - 10, body.top + 6)
      ..lineTo(body.right - 30, body.top - flapH)
      ..lineTo(body.left + 30, body.top - flapH)
      ..close();
    canvas.drawPath(flap, _fill(T.accentSoft));
    canvas.drawPath(flap, _ink);

    // 投递口内的下行提示箭头。
    final cx = body.center.dx;
    final ay = body.center.dy;
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
        ..strokeWidth = 3.2,
    );
  }

  // —— 已放入 / 受阻 / 运行 / 完成 的封套主体 ——
  void _drawEnvelope(Canvas canvas, Rect body, {required Color tint, bool dim = false}) {
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
      Rect.fromLTWH(
        body.left + body.width * 0.16,
        body.center.dy + body.height * 0.04,
        body.width * 0.68,
        body.height * 0.22,
      ),
      const Radius.circular(T.rSm),
    );
    canvas.drawRRect(band, _fill(dim ? const Color(0xFFEDE6E9) : tint));
    canvas.drawRRect(band, _ink..strokeWidth = 1.8);
  }

  // —— 制作中：物件上就地显进度环（G6：只反映真实进度）——
  void _drawProgress(Canvas canvas, Rect body) {
    final c = Offset(body.center.dx, body.top + body.height * 0.30);
    const r = 17.0;
    canvas.drawCircle(c, r, _fill(T.bg));
    canvas.drawCircle(c, r, _ink..strokeWidth = 2.4..color = T.line);
    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..color = T.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.4
        ..strokeCap = StrokeCap.round,
    );
  }

  // —— 完成：长出字幕带 ——
  void _drawSubtitleBand(Canvas canvas, Rect body) {
    final p = _fill(T.ink);
    for (final f in [0.52, 0.66]) {
      final lineWidth = body.width * (f == 0.52 ? 0.5 : 0.36);
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          body.center.dx - lineWidth / 2,
          body.top + body.height * f,
          lineWidth,
          4,
        ),
        const Radius.circular(2),
      );
      canvas.drawRRect(r, p);
    }
  }

  void _drawCheckBadge(Canvas canvas, Rect body) {
    final c = Offset(body.right - 6, body.top + 2);
    canvas.drawCircle(c, 15, _fill(T.accent));
    canvas.drawCircle(c, 15, _ink..strokeWidth = 2..color = T.inkLine);
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
      Rect.fromCenter(center: c, width: body.width * 0.42, height: body.height * 0.3),
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
      old.breathe != breathe ||
      old.dragOver != dragOver;
}
