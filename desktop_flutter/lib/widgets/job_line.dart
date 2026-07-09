import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/main_window_controller.dart';
import '../model/task_labels.dart';
import '../theme/tokens.dart';
import 'designed_tooltip.dart';

class JobLine extends StatelessWidget {
  const JobLine({
    super.key,
    required this.view,
    required this.onPickTranslation,
    required this.onPickAsr,
    required this.onPickSourceLanguage,
    required this.onPickTargetLanguage,
    required this.onPickBilingual,
    required this.onPickFormats,
    required this.onToggleTerms,
    required this.onConfigureTranslation,
    required this.onConfigureAsr,
  });

  final MainWindowViewModel view;
  final VoidCallback onPickTranslation;
  final VoidCallback onPickAsr;
  final VoidCallback onPickSourceLanguage;
  final VoidCallback onPickTargetLanguage;
  final VoidCallback onPickBilingual;
  final VoidCallback onPickFormats;
  final VoidCallback onToggleTerms;
  final VoidCallback onConfigureTranslation;
  final VoidCallback onConfigureAsr;

  @override
  Widget build(BuildContext context) {
    final asrLabel = view.asrConfigured ? view.asrLabel : '先配置识别';
    final translationLabel = view.translationConfigured
        ? _compactEngineLabel(view.translationLabel)
        : '先配置翻译';
    final memoryLabel = view.termsEnabled ? '整理术语记忆' : '不整理术语记忆';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('会按', style: T.tBody),
            _Word(
              label: languageLabel(view.sourceLang),
              tooltip: '源语：${languageLabel(view.sourceLang)}',
              onPick: onPickSourceLanguage,
            ),
            const Text('源语，用', style: T.tBody),
            _Word(
              label: asrLabel,
              fullLabel: view.asrConfigured ? view.asrLabel : null,
              warn: !view.asrConfigured,
              onPick: view.asrConfigured ? onPickAsr : onConfigureAsr,
            ),
            const Text('识别，交给', style: T.tBody),
            _Word(
              label: translationLabel,
              fullLabel: view.translationConfigured
                  ? (view.translationDetail.isNotEmpty
                        ? view.translationDetail
                        : view.translationLabel)
                  : null,
              warn: !view.translationConfigured,
              onPick: view.translationConfigured
                  ? onPickTranslation
                  : onConfigureTranslation,
            ),
            const Text('翻译', style: T.tBody),
            const Text('成', style: T.tBody),
            _Word(
              label: languageLabel(view.targetLang),
              tooltip: '目标语：${languageLabel(view.targetLang)}',
              onPick: onPickTargetLanguage,
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('做成', style: T.tBody),
            _Word(label: view.bilingual ? '双语' : '单语', onPick: onPickBilingual),
            _Word(label: view.formats.join('·'), onPick: onPickFormats),
            const Text('字幕，也会', style: T.tBody),
            _Word(
              label: memoryLabel,
              tooltip: view.termsEnabled
                  ? '制作时自动整理术语记忆。不会改动人工术语表。'
                  : '本次不生成新的术语记忆。已有术语表不受影响。',
              onPick: onToggleTerms,
            ),
          ],
        ),
      ],
    );
  }
}

class _Word extends StatefulWidget {
  const _Word({
    required this.label,
    required this.onPick,
    this.fullLabel,
    this.tooltip,
    this.warn = false,
  });

  final String label;
  final String? fullLabel;
  final String? tooltip;
  final VoidCallback onPick;
  final bool warn;

  @override
  State<_Word> createState() => _WordState();
}

class _WordState extends State<_Word> with SingleTickerProviderStateMixin {
  late final AnimationController _wiggle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );
  bool _hover = false;

  @override
  void dispose() {
    _wiggle.dispose();
    super.dispose();
  }

  void _setHover(bool value) {
    if (_hover == value) return;
    setState(() => _hover = value);
    if (value) {
      _wiggle.forward(from: 0);
    } else {
      _wiggle.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.warn ? T.warn : T.accentStrong;
    final content = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      child: GestureDetector(
        onTap: widget.onPick,
        child: AnimatedBuilder(
          animation: _wiggle,
          builder: (context, child) {
            final decay = 1 - _wiggle.value;
            final wave = math.sin(_wiggle.value * math.pi * 4);
            final dx = wave * decay * 1.5;
            final angle = wave * decay * 0.018;
            return Transform.translate(
              offset: Offset(dx, _hover ? -1 : 0),
              child: Transform.rotate(angle: angle, child: child),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 190),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: widget.label),
                    if (widget.warn) const TextSpan(text: ' ●'),
                  ],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: T.wMedium,
                    color: color,
                  ),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
    final fullLabel = widget.tooltip ?? widget.fullLabel;
    return fullLabel == null || fullLabel == widget.label
        ? content
        : DesignedTooltip(message: fullLabel, child: content);
  }
}

String _compactEngineLabel(String label) {
  final parts = label.split(' · ');
  if (parts.length < 2) return label;
  final provider = parts.first;
  return _providerAlias(provider);
}

String _providerAlias(String provider) {
  final lower = provider.toLowerCase();
  if (lower.contains('deepseek')) return 'DeepSeek';
  if (lower.contains('vertex')) return 'Vertex';
  if (lower.contains('gemini')) return 'Gemini';
  if (lower.contains('anthropic')) return 'Anthropic';
  if (lower.contains('openai')) return 'OpenAI';
  return provider;
}
