import 'package:flutter/material.dart';

import '../model/spike_state.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';
import 'title_bar.dart';

class SettingsWindow extends StatefulWidget {
  const SettingsWindow({
    super.key,
    required this.type,
    required this.store,
    required this.bridge,
  });

  final SpikeWindowType type;
  final WindowStateStore store;
  final WindowStateBridge bridge;

  @override
  State<SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<SettingsWindow> {
  final _baseUrl = TextEditingController(text: 'https://api.example.com/v1');
  final _model = TextEditingController(text: 'opus-translation-latest');
  final _key = TextEditingController(text: 'example-token');
  final _note = TextEditingController(text: '中文输入验证：候选窗位置、组合输入、复制粘贴。');

  @override
  void initState() {
    super.initState();
    widget.bridge.initializeChild();
    widget.store.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.store.removeListener(_refresh);
    _baseUrl.dispose();
    _model.dispose();
    _key.dispose();
    _note.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final isTranslation = widget.type == SpikeWindowType.translationSettings;
    final title = isTranslation ? '翻译模型设置' : '语音识别设置';
    final status = isTranslation ? '多窗口 + 中文 IME 验证' : '引擎选择 + 中文 IME 验证';
    return Scaffold(
      backgroundColor: T.bg,
      body: Column(
        children: [
          TitleBar(title: title, status: status),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(T.s32, T.s16, T.s32, T.s24),
              child: isTranslation
                  ? _translationBody()
                  : _asrBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _translationBody() {
    final value = widget.store.value;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 190,
          child: _FlatChoiceList(
            title: '供应商',
            selected: value.translationDefaultLabel,
            items: const ['Opus', 'Haiku', 'GPT-4o', '需配置'],
            onPick: (label) => widget.bridge.setTranslationDefault(
              label,
              configured: label != '需配置',
            ),
          ),
        ),
        const SizedBox(width: T.s32),
        Expanded(
          child: _FormColumn(
            header: '默认翻译：${value.translationDefaultLabel}',
            fields: [
              _FieldSpec('Base URL', _baseUrl),
              _FieldSpec('模型名', _model),
              _FieldSpec('API key（占位，不保存）', _key, obscure: true),
              _FieldSpec('中文备注 / IME 验证', _note, maxLines: 3),
            ],
          ),
        ),
      ],
    );
  }

  Widget _asrBody() {
    final value = widget.store.value;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 210,
          child: _FlatChoiceList(
            title: '识别引擎',
            selected: value.asrDefaultLabel,
            items: const ['本机', 'FunASR', '云端', '需配置'],
            onPick: (label) => widget.bridge.setAsrDefault(
              label,
              configured: label != '需配置',
            ),
          ),
        ),
        const SizedBox(width: T.s32),
        Expanded(
          child: _FormColumn(
            header: '当前识别：${value.asrDefaultLabel}',
            fields: [
              _FieldSpec('Base URL / 本地服务地址', _baseUrl),
              _FieldSpec('模型名', _model),
              _FieldSpec('访问 key（云端占位）', _key, obscure: true),
              _FieldSpec('中文备注 / IME 验证', _note, maxLines: 3),
            ],
          ),
        ),
      ],
    );
  }
}

class _FlatChoiceList extends StatelessWidget {
  const _FlatChoiceList({
    required this.title,
    required this.selected,
    required this.items,
    required this.onPick,
  });

  final String title;
  final String selected;
  final List<String> items;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: T.tSection),
        const SizedBox(height: T.s12),
        for (final item in items)
          _ChoiceRow(
            label: item,
            selected: item == selected,
            warn: item == '需配置',
            onTap: () => onPick(item),
          ),
      ],
    );
  }
}

class _ChoiceRow extends StatefulWidget {
  const _ChoiceRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.warn = false,
  });

  final String label;
  final bool selected;
  final bool warn;
  final VoidCallback onTap;

  @override
  State<_ChoiceRow> createState() => _ChoiceRowState();
}

class _ChoiceRowState extends State<_ChoiceRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.warn ? T.warn : T.accentStrong;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 40,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: widget.selected ? color : const Color(0x00000000),
                width: 3,
              ),
              bottom: const BorderSide(color: T.line, width: 1),
            ),
            color: _hover || widget.selected ? T.accentSoft : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: T.s12),
          alignment: Alignment.centerLeft,
          child: Text(
            widget.warn ? '${widget.label} ●' : widget.label,
            style: T.tBody.copyWith(
              color: widget.warn ? T.warn : T.ink,
              fontWeight: widget.selected ? T.wBold : T.wRegular,
            ),
          ),
        ),
      ),
    );
  }
}

class _FormColumn extends StatelessWidget {
  const _FormColumn({required this.header, required this.fields});

  final String header;
  final List<_FieldSpec> fields;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(header, style: T.tSection),
        const SizedBox(height: T.s16),
        for (final field in fields) ...[
          Text(field.label, style: T.tCaption),
          const SizedBox(height: T.s4),
          TextField(
            controller: field.controller,
            obscureText: field.obscure,
            maxLines: field.obscure ? 1 : field.maxLines,
            style: T.tBody,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: T.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(T.rMd),
                borderSide: const BorderSide(color: T.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(T.rMd),
                borderSide: const BorderSide(color: T.accent, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: T.s16),
        ],
        Text(
          'Phase A 只验证跨窗状态和中文输入；这里的表单控件是 spike 占位，不是最终配置窗设计。',
          style: T.tCaption,
        ),
      ],
    );
  }
}

class _FieldSpec {
  _FieldSpec(
    this.label,
    this.controller, {
    this.obscure = false,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final bool obscure;
  final int maxLines;
}
