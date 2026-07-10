import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/tokens.dart';

/// 自绘标题栏（design spec §4.1）：左=低调窗口身份；
/// 右=窗控簇 `≡ — ✕`，行为像原生（拖拽区、最小化 / 关闭）。
/// `≡` 是准备配置的门（单个 app 菜单），不是一排具名入口。
class TitleBar extends StatelessWidget {
  const TitleBar({
    super.key,
    this.title = 'TransVortex',
    this.status = '',
    this.onMenu,
    this.menuKey,
    this.canMaximize = false,
  });

  final String title;
  final String status;
  final VoidCallback? onMenu;
  final Key? menuKey;
  final bool canMaximize;

  @override
  Widget build(BuildContext context) {
    final statusText = status.trim();
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          // 左侧品牌区整体作为拖拽区。
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: T.s16),
                child: Row(
                  children: [
                    Text(
                      title,
                      style: T.tSection.copyWith(
                        color: T.ink.withValues(alpha: 0.86),
                      ),
                    ),
                    if (statusText.isNotEmpty) ...[
                      const SizedBox(width: T.s12),
                      Container(width: 1, height: 14, color: T.line),
                      const SizedBox(width: T.s12),
                      Flexible(
                        child: Text(
                          statusText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: T.tCaption,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (onMenu != null)
            _ChromeButton(key: menuKey, glyph: _Glyph.menu, onTap: onMenu!),
          _ChromeButton(glyph: _Glyph.min, onTap: windowManager.minimize),
          if (canMaximize)
            _ChromeButton(glyph: _Glyph.max, onTap: _toggleMaximized),
          _ChromeButton(
            glyph: _Glyph.close,
            danger: true,
            onTap: windowManager.close,
          ),
        ],
      ),
    );
  }

  Future<void> _toggleMaximized() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }
}

enum _Glyph { menu, min, max, close }

class _ChromeButton extends StatefulWidget {
  const _ChromeButton({
    super.key,
    required this.glyph,
    required this.onTap,
    this.danger = false,
  });

  final _Glyph glyph;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_ChromeButton> createState() => _ChromeButtonState();
}

class _ChromeButtonState extends State<_ChromeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final hoverBg = widget.danger ? T.danger : T.accentSoft;
    final glyphColor = _hover && widget.danger
        ? const Color(0xFFFFFFFF)
        : T.ink;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 44,
          height: 44,
          color: _hover
              ? (widget.danger ? hoverBg : hoverBg.withValues(alpha: 0.9))
              : const Color(0x00000000),
          child: Center(
            child: CustomPaint(
              size: const Size(14, 14),
              painter: _GlyphPainter(widget.glyph, glyphColor),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);
  final _Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final s = size.width;
    switch (glyph) {
      case _Glyph.menu:
        for (final y in [s * 0.28, s * 0.5, s * 0.72]) {
          canvas.drawLine(Offset(0, y), Offset(s, y), p);
        }
        break;
      case _Glyph.min:
        canvas.drawLine(Offset(0, s * 0.5), Offset(s, s * 0.5), p);
        break;
      case _Glyph.max:
        canvas.drawRect(
          Rect.fromLTWH(s * 0.16, s * 0.16, s * 0.68, s * 0.68),
          p,
        );
        break;
      case _Glyph.close:
        canvas.drawLine(Offset.zero, Offset(s, s), p);
        canvas.drawLine(Offset(s, 0), Offset(0, s), p);
        break;
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
