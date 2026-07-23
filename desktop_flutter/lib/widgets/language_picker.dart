import 'package:flutter/material.dart';

import '../model/task_labels.dart';
import '../theme/tokens.dart';

const List<String> sourceLanguageOptions = [
  'auto',
  'ja',
  'en',
  'zh-CN',
  'zh-TW',
  'ko',
  'fr',
  'de',
  'es',
];

const List<String> targetLanguageOptions = [
  'zh-CN',
  'zh-TW',
  'en',
  'ja',
  'ko',
  'fr',
  'de',
  'es',
];

typedef LanguageTriggerBuilder = Widget Function(VoidCallback openMenu);

class LanguagePickerAnchor extends StatefulWidget {
  const LanguagePickerAnchor({
    super.key,
    required this.title,
    required this.description,
    required this.current,
    required this.options,
    required this.keyPrefix,
    required this.onSelected,
    required this.triggerBuilder,
    this.showAutoDetect = false,
    this.autoDetectDescription = '由识别引擎判断原始语言',
  });

  final String title;
  final String description;
  final String current;
  final List<String> options;
  final String keyPrefix;
  final ValueChanged<String> onSelected;
  final LanguageTriggerBuilder triggerBuilder;
  final bool showAutoDetect;
  final String autoDetectDescription;

  @override
  State<LanguagePickerAnchor> createState() => _LanguagePickerAnchorState();
}

class _LanguagePickerAnchorState extends State<LanguagePickerAnchor> {
  final MenuController _controller = MenuController();

  @override
  Widget build(BuildContext context) {
    final regularOptions = widget.options
        .where((option) => option.toLowerCase() != 'auto')
        .toList(growable: false);
    return MenuAnchor(
      controller: _controller,
      consumeOutsideTap: true,
      alignmentOffset: const Offset(-18, T.s8),
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(T.surface),
        surfaceTintColor: const WidgetStatePropertyAll(T.surface),
        elevation: const WidgetStatePropertyAll(10),
        shadowColor: WidgetStatePropertyAll(T.ink.withValues(alpha: 0.16)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.rLg),
            side: const BorderSide(color: T.line),
          ),
        ),
      ),
      menuChildren: [
        SizedBox(
          width: 316,
          child: Padding(
            padding: const EdgeInsets.all(T.s12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: T.skySoft,
                        borderRadius: BorderRadius.circular(T.rSm),
                      ),
                      child: const Icon(
                        Icons.translate_rounded,
                        size: 17,
                        color: T.ink,
                      ),
                    ),
                    const SizedBox(width: T.s8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.title, style: T.tSection),
                          const SizedBox(height: 2),
                          Text(widget.description, style: T.tCaption),
                        ],
                      ),
                    ),
                  ],
                ),
                if (widget.showAutoDetect) ...[
                  const SizedBox(height: T.s12),
                  _AutoDetectChoice(
                    selected: _sameLanguage(widget.current, 'auto'),
                    keyPrefix: widget.keyPrefix,
                    description: widget.autoDetectDescription,
                    onTap: () => _select('auto'),
                  ),
                ],
                const SizedBox(height: T.s12),
                Row(
                  children: [
                    Text('常用语言', style: T.tCaption),
                    const SizedBox(width: T.s8),
                    const Expanded(child: Divider(height: 1, color: T.line)),
                  ],
                ),
                const SizedBox(height: T.s8),
                Wrap(
                  spacing: T.s8,
                  runSpacing: T.s8,
                  children: [
                    for (final option in regularOptions)
                      _LanguageChoice(
                        key: ValueKey('${widget.keyPrefix}-$option'),
                        code: option,
                        selected: _sameLanguage(widget.current, option),
                        onTap: () => _select(option),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, child) =>
          widget.triggerBuilder(controller.open),
    );
  }

  void _select(String value) {
    _controller.close();
    widget.onSelected(value);
  }
}

class _AutoDetectChoice extends StatelessWidget {
  const _AutoDetectChoice({
    required this.selected,
    required this.keyPrefix,
    required this.description,
    required this.onTap,
  });

  final bool selected;
  final String keyPrefix;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? T.accentSoft : T.skySoft.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(T.rMd),
      child: InkWell(
        key: ValueKey('$keyPrefix-auto'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(T.rMd),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: T.s12,
            vertical: T.s8,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: selected ? T.accent : T.line),
            borderRadius: BorderRadius.circular(T.rMd),
          ),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome_rounded, size: 18, color: T.sky),
              const SizedBox(width: T.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '自动识别',
                      style: T.tBody.copyWith(fontWeight: T.wMedium),
                    ),
                    Text(description, style: T.tCaption),
                  ],
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: T.accentStrong,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LanguageChoice extends StatelessWidget {
  const _LanguageChoice({
    super.key,
    required this.code,
    required this.selected,
    required this.onTap,
  });

  final String code;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? T.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(T.rSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(T.rSm),
        child: Container(
          width: 142,
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: T.s8),
          decoration: BoxDecoration(
            border: Border.all(color: selected ? T.accent : T.line),
            borderRadius: BorderRadius.circular(T.rSm),
          ),
          child: Row(
            children: [
              Container(
                width: 27,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? T.surface : T.lilacSoft,
                  borderRadius: BorderRadius.circular(T.s4),
                ),
                child: Text(
                  _languageMark(code),
                  style: T.tCaption.copyWith(
                    color: selected ? T.accentStrong : T.muted,
                    fontWeight: T.wBold,
                  ),
                ),
              ),
              const SizedBox(width: T.s8),
              Expanded(
                child: Text(
                  languageLabel(code),
                  style: T.tBody.copyWith(
                    fontWeight: selected ? T.wMedium : T.wRegular,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: T.accentStrong,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _languageMark(String code) {
  return switch (code.toLowerCase()) {
    'zh-cn' => '简',
    'zh-tw' => '繁',
    'ja' => '日',
    'ko' => '韩',
    'en' => 'EN',
    'fr' => 'FR',
    'de' => 'DE',
    'es' => 'ES',
    _ => code.toUpperCase(),
  };
}

bool _sameLanguage(String first, String second) =>
    first.trim().toLowerCase().replaceAll('_', '-') ==
    second.trim().toLowerCase().replaceAll('_', '-');
