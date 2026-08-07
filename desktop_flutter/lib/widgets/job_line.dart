import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/main_window_controller.dart';
import '../model/task_labels.dart';
import '../theme/tokens.dart';
import 'designed_tooltip.dart';
import 'language_picker.dart';

class JobLine extends StatelessWidget {
  const JobLine({
    super.key,
    required this.view,
    required this.onPickTranslation,
    required this.onPickAsr,
    required this.onPickReasoning,
    required this.onSelectSourceLanguage,
    required this.onSelectTargetLanguage,
    required this.onPickBilingual,
    required this.onPickFormats,
    required this.onToggleTerms,
    required this.onPickMemoryCollections,
    required this.onConfigureTranslation,
    required this.onConfigureAsr,
  });

  final MainWindowViewModel view;
  final VoidCallback onPickTranslation;
  final VoidCallback onPickAsr;
  final VoidCallback onPickReasoning;
  final ValueChanged<String> onSelectSourceLanguage;
  final ValueChanged<String> onSelectTargetLanguage;
  final VoidCallback onPickBilingual;
  final VoidCallback onPickFormats;
  final VoidCallback onToggleTerms;
  final VoidCallback onPickMemoryCollections;
  final VoidCallback onConfigureTranslation;
  final VoidCallback onConfigureAsr;

  @override
  Widget build(BuildContext context) {
    final asrLabel = view.asrConfigured
        ? view.asrLabel
        : view.asrLabel == '需配置'
        ? '先配置识别'
        : '${view.asrLabel}（需配置）';
    final translationLabel = view.translationConfigured
        ? _compactEngineLabel(view.translationLabel)
        : '先配置翻译';
    final memoryLabel = view.termsEnabled ? '自动发现术语候选' : '不自动发现候选';
    final collectionCount = view.memoryCollectionIds.length;
    final collectionLabel = collectionCount == 0
        ? '不使用术语库'
        : '使用 $collectionCount 个术语库';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(view.hasSource ? '会按' : '新任务会按', style: T.tBody),
            LanguagePickerAnchor(
              title: '源语言',
              description: '选择片源中使用的原始语言',
              current: view.sourceLang,
              options: sourceLanguageOptions,
              keyPrefix: 'source-language',
              showAutoDetect: true,
              autoDetectDescription: view.requiresAsr
                  ? '由识别引擎判断原始语言'
                  : '根据字幕内容判断原始语言',
              onSelected: onSelectSourceLanguage,
              triggerBuilder: (openMenu) => _Word(
                label: languageLabel(view.sourceLang),
                tooltip: '源语：${languageLabel(view.sourceLang)}',
                onPick: openMenu,
              ),
            ),
            if (view.requiresAsr) ...[
              const Text('源语，语音用', style: T.tBody),
              _Word(
                label: asrLabel,
                fullLabel: view.asrConfigured
                    ? view.asrLabel
                    : view.asrDetail.isEmpty
                    ? view.asrLabel
                    : '${view.asrLabel} · ${view.asrDetail}',
                warn: !view.asrConfigured,
                onPick: view.asrOptions.isEmpty ? onConfigureAsr : onPickAsr,
              ),
              const Text('识别，交给', style: T.tBody),
            ] else
              const Text('源语，直接交给', style: T.tBody),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                if (view.reasoningConfigurable) ...[
                  const SizedBox(width: 2),
                  _Word(
                    key: const ValueKey('job-reasoning-effort'),
                    label: view.reasoningLabel,
                    leadingIcon: Icons.bolt_rounded,
                    tooltip: '本次思考程度：${view.reasoningDetail}',
                    onPick: onPickReasoning,
                  ),
                ],
              ],
            ),
            const Text('翻译成', style: T.tBody),
            LanguagePickerAnchor(
              title: '目标语言',
              description: '选择字幕需要翻译成的语言',
              current: view.targetLang,
              options: targetLanguageOptions,
              keyPrefix: 'target-language',
              onSelected: onSelectTargetLanguage,
              triggerBuilder: (openMenu) => _Word(
                label: languageLabel(view.targetLang),
                tooltip: '目标语：${languageLabel(view.targetLang)}',
                onPick: openMenu,
              ),
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
            const Text('字幕，并', style: T.tBody),
            _Word(
              label: memoryLabel,
              tooltip: view.termsEnabled
                  ? '本次允许系统动态发现候选，用于增强当次翻译；不会自动写入持久术语库。'
                  : '本次不动态发现新候选；是否使用持久术语库由旁边的选择单独决定。',
              onPick: onToggleTerms,
            ),
            const Text('，并', style: T.tBody),
            _Word(
              key: const ValueKey('job-memory-collections'),
              label: collectionLabel,
              tooltip: collectionCount == 0
                  ? '选择本任务要使用的持久术语库。任务开始后会冻结快照，不会被后续修改影响。'
                  : '本任务将使用所选术语库的快照；点击可选择或维护术语库。',
              onPick: onPickMemoryCollections,
            ),
          ],
        ),
      ],
    );
  }
}

class _Word extends StatefulWidget {
  const _Word({
    super.key,
    required this.label,
    required this.onPick,
    this.fullLabel,
    this.tooltip,
    this.leadingIcon,
    this.warn = false,
  });

  final String label;
  final String? fullLabel;
  final String? tooltip;
  final IconData? leadingIcon;
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.leadingIcon != null) ...[
                    Icon(widget.leadingIcon, size: 14, color: color),
                    const SizedBox(width: 1),
                  ],
                  Flexible(
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
                ],
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
