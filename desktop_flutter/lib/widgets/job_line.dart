import 'package:flutter/material.dart';

import '../model/main_window_controller.dart';
import '../theme/tokens.dart';

class JobLine extends StatelessWidget {
  const JobLine({
    super.key,
    required this.view,
    required this.onPickTranslation,
    required this.onPickAsr,
    required this.onPickBilingual,
    required this.onPickFormats,
    required this.onToggleTerms,
    required this.onConfigureTranslation,
    required this.onConfigureAsr,
  });

  final MainWindowViewModel view;
  final VoidCallback onPickTranslation;
  final VoidCallback onPickAsr;
  final VoidCallback onPickBilingual;
  final VoidCallback onPickFormats;
  final VoidCallback onToggleTerms;
  final VoidCallback onConfigureTranslation;
  final VoidCallback onConfigureAsr;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('识别', style: T.tBody),
            _Word(
              label: view.asrConfigured ? view.asrLabel : '需配置',
              warn: !view.asrConfigured,
              onPick: view.asrConfigured ? onPickAsr : onConfigureAsr,
            ),
            const Text(' · 翻译', style: T.tBody),
            _Word(
              label: view.translationConfigured
                  ? view.translationLabel
                  : '需配置',
              warn: !view.translationConfigured,
              onPick: view.translationConfigured
                  ? onPickTranslation
                  : onConfigureTranslation,
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('将做成', style: T.tBody),
            _Word(
              label: view.bilingual ? '双语' : '单语',
              onPick: onPickBilingual,
            ),
            _Word(label: view.formats.join('·'), onPick: onPickFormats),
            const Text('字幕', style: T.tBody),
            const Text(' · 术语', style: T.tBody),
            _Word(
              label: view.termsEnabled ? '自动生成' : '不生成',
              onPick: onToggleTerms,
            ),
          ],
        ),
      ],
    );
  }
}

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
