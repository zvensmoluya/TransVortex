import 'package:flutter/material.dart';

import '../model/session.dart';
import '../theme/tokens.dart';

/// job 描述 = 任务配置（design spec §4.3）。主体下方两行可点词：
///   识别〈本机〉· 翻译〈Opus〉
///   将做成〈双语〉〈SRT·ASS〉字幕
/// 点词即选，改即生效，无「保存」；翻译需配置时该词变 `需配置 ●`（warn）gate 主动作。
/// 空态没片源时这两行不存在——这正是它「不是导航」的证据。
class JobLine extends StatelessWidget {
  const JobLine({
    super.key,
    required this.session,
    required this.onChanged,
    required this.onConfigureTranslation,
    required this.onConfigureAsr,
  });

  final Session session;
  final ValueChanged<Session> onChanged;
  final VoidCallback onConfigureTranslation;
  final VoidCallback onConfigureAsr;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 第一行：引擎
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('识别', style: T.tBody),
            _Word(
              label: session.asrConfigured ? session.engineRecognize : '需配置',
              warn: !session.asrConfigured,
              onPick: () async {
                if (!session.asrConfigured) {
                  onConfigureAsr();
                  return;
                }
                final v = await _pick(context, '语音识别引擎', const [
                  '本机',
                  'FunASR',
                  '云端',
                ]);
                if (v != null) onChanged(session.copyWith(engineRecognize: v));
              },
            ),
            const Text(' · 翻译', style: T.tBody),
            _Word(
              label: session.translateConfigured
                  ? session.engineTranslate
                  : '需配置',
              warn: !session.translateConfigured,
              onPick: () async {
                if (!session.translateConfigured) {
                  // 受阻：picker 没有可选项 → 引到准备配置工具窗。
                  onConfigureTranslation();
                  return;
                }
                final v = await _pick(context, '翻译模型', const [
                  'Opus',
                  'Haiku',
                  'GPT-4o',
                ]);
                if (v != null) onChanged(session.copyWith(engineTranslate: v));
              },
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        // 第二行：输出
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('将做成', style: T.tBody),
            _Word(
              label: session.bilingual ? '双语' : '单语',
              onPick: () =>
                  onChanged(session.copyWith(bilingual: !session.bilingual)),
            ),
            _Word(
              label: session.formats.join('·'),
              onPick: () async {
                final v = await _pickFormats(context, session.formats);
                if (v != null && v.isNotEmpty) {
                  onChanged(session.copyWith(formats: v));
                }
              },
            ),
            const Text('字幕', style: T.tBody),
          ],
        ),
      ],
    );
  }

  Future<String?> _pick(
    BuildContext context,
    String title,
    List<String> options,
  ) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: T.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(T.rLg)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(T.s24, T.s16, T.s24, T.s8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(title, style: T.tSection),
              ),
            ),
            for (final o in options)
              ListTile(
                title: Text(o, style: T.tBody),
                onTap: () => Navigator.pop(ctx, o),
              ),
            const SizedBox(height: T.s8),
          ],
        ),
      ),
    );
  }

  Future<List<String>?> _pickFormats(
    BuildContext context,
    List<String> current,
  ) {
    return showModalBottomSheet<List<String>>(
      context: context,
      backgroundColor: T.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(T.rLg)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(T.s24, T.s16, T.s24, T.s8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('输出格式', style: T.tSection),
              ),
            ),
            for (final option in const [
              ['SRT'],
              ['ASS'],
              ['VTT'],
              ['SRT', 'ASS'],
            ])
              ListTile(
                title: Text(option.join('·'), style: T.tBody),
                selected: _sameFormats(current, option),
                selectedColor: T.accentStrong,
                onTap: () => Navigator.pop(ctx, option),
              ),
            const SizedBox(height: T.s8),
          ],
        ),
      ),
    );
  }
}

bool _sameFormats(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 可点词：`〈label〉`，accent 着色 + hover 下划线；warn 变体带 ● 点。
class _Word extends StatefulWidget {
  const _Word({required this.label, required this.onPick, this.warn = false});

  final String label;
  final VoidCallback onPick;
  final bool warn;

  @override
  State<_Word> createState() => _WordState();
}

class _WordState extends State<_Word> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.warn ? T.warn : T.accentStrong;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPick,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text.rich(
            TextSpan(
              children: [
                const TextSpan(
                  text: '〈',
                  style: TextStyle(color: T.muted),
                ),
                TextSpan(text: widget.label),
                if (widget.warn) const TextSpan(text: ' ●'),
                const TextSpan(
                  text: '〉',
                  style: TextStyle(color: T.muted),
                ),
              ],
              style: TextStyle(
                fontSize: 13,
                fontWeight: T.wMedium,
                color: color,
                decoration: _hover
                    ? TextDecoration.underline
                    : TextDecoration.none,
                decorationColor: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
