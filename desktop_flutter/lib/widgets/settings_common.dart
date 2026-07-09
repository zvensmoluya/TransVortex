import 'package:flutter/material.dart';

import '../services/app_service_client.dart';
import '../theme/tokens.dart';

/// Shared, presentation-only leaf widgets used across the settings windows
/// (translation model settings, ASR settings, diagnostics). These carry no
/// business logic — they only render and forward callbacks — so they can be
/// reused by both `settings_window.dart` and `translation_settings_view.dart`.

String providerTemplateLabel(ProviderTemplateOption template) {
  final label = template.label.trim();
  if (label.isNotEmpty) return label;
  return template.id;
}

class DefaultBar extends StatelessWidget {
  const DefaultBar({
    super.key,
    required this.text,
    required this.busy,
    this.error,
    this.message,
  });

  final String text;
  final bool busy;
  final String? error;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: T.line, width: 1)),
      ),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Expanded(child: Text(text, style: T.tSection)),
          if (busy) Text('同步中…', style: T.tCaption),
          if (!busy && error != null)
            Flexible(
              child: Text(
                error!,
                style: T.tCaption.copyWith(color: T.danger),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (!busy && error == null && message != null)
            Flexible(
              child: Text(
                message!,
                style: T.tCaption.copyWith(color: T.accentStrong),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.divider = true,
  });

  final String title;
  final List<Widget> children;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: T.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: T.tCaption.copyWith(fontWeight: T.wBold)),
          const SizedBox(height: T.s8),
          ...children,
          if (divider) ...[
            const SizedBox(height: T.s12),
            const Divider(height: 1, color: T.line),
          ],
        ],
      ),
    );
  }
}

class ProviderList extends StatelessWidget {
  const ProviderList({
    super.key,
    required this.providers,
    required this.selected,
    required this.defaultProvider,
    required this.creating,
    required this.onPick,
    required this.onCreate,
  });

  final List<ProviderOption> providers;
  final String? selected;
  final String? defaultProvider;
  final bool creating;
  final ValueChanged<String> onPick;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('已配置连接', style: T.tSection),
        const SizedBox(height: T.s12),
        ActionButton(label: '添加连接', strong: creating, onTap: onCreate),
        const SizedBox(height: T.s12),
        if (providers.isEmpty)
          const Text('还没有连接', style: T.tCaption)
        else
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final provider in providers)
                  ChoiceRow(
                    label: provider.name,
                    detail: [
                      provider.models.isEmpty
                          ? '未保存模型'
                          : '${provider.models.length} 个模型',
                      provider.hasKey ? '密钥已配置' : '未配置密钥',
                    ].join(' · '),
                    selected: provider.name == selected,
                    warn: provider.name == defaultProvider && !provider.hasKey,
                    onTap: () => onPick(provider.name),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class TemplateSelect extends StatelessWidget {
  const TemplateSelect({
    super.key,
    required this.templates,
    required this.selected,
    required this.onPick,
  });

  final List<ProviderTemplateOption> templates;
  final String? selected;
  final ValueChanged<ProviderTemplateOption> onPick;

  @override
  Widget build(BuildContext context) {
    if (templates.isEmpty) {
      return const Text('没有可用协议', style: T.tCaption);
    }
    final selectedTemplate = templates.firstWhere(
      (template) => template.id == selected,
      orElse: () => templates.first,
    );
    return SizedBox(
      width: 360,
      child: DropdownButtonFormField<String>(
        initialValue: selectedTemplate.id,
        isExpanded: true,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: T.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: T.s12,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rMd),
            borderSide: const BorderSide(color: T.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rMd),
            borderSide: const BorderSide(color: T.accent, width: 1.4),
          ),
        ),
        style: T.tBody.copyWith(color: T.ink),
        items: [
          for (final template in templates)
            DropdownMenuItem<String>(
              value: template.id,
              child: Text(
                providerTemplateLabel(template),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (value) {
          if (value == null) return;
          for (final template in templates) {
            if (template.id == value) {
              onPick(template);
              return;
            }
          }
        },
      ),
    );
  }
}

class ToolPanel extends StatelessWidget {
  const ToolPanel({
    super.key,
    required this.children,
    required this.footer,
    this.footnote,
  });
  final List<Widget> children;
  final List<Widget> footer;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ListView(padding: EdgeInsets.zero, children: children),
        ),
        const SizedBox(height: T.s12),
        Wrap(spacing: T.s12, runSpacing: T.s8, children: footer),
        if (footnote != null && footnote!.isNotEmpty) ...[
          const SizedBox(height: T.s8),
          Text(
            footnote!,
            style: T.tCaption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

class FallbackRouteRow extends StatelessWidget {
  const FallbackRouteRow({
    super.key,
    required this.provider,
    required this.model,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemove,
  });

  final String provider;
  final String model;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 42),
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line, width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                style: T.tCaption.copyWith(
                  color: T.ink,
                  fontFamily: T.fontFamily,
                ),
                children: [
                  TextSpan(
                    text: provider,
                    style: const TextStyle(fontWeight: T.wBold),
                  ),
                  const TextSpan(
                    text: ' · ',
                    style: TextStyle(color: T.muted),
                  ),
                  TextSpan(text: model),
                ],
              ),
            ),
          ),
          const SizedBox(width: T.s8),
          IconToolButton(
            icon: Icons.arrow_upward_rounded,
            tooltip: '上移备用模型',
            onTap: canMoveUp ? onMoveUp : null,
          ),
          IconToolButton(
            icon: Icons.arrow_downward_rounded,
            tooltip: '下移备用模型',
            onTap: canMoveDown ? onMoveDown : null,
          ),
          IconToolButton(
            icon: Icons.close_rounded,
            tooltip: '移除备用模型',
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}

class IconToolButton extends StatefulWidget {
  const IconToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.buttonKey,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Key? buttonKey;

  @override
  State<IconToolButton> createState() => _IconToolButtonState();
}

class _IconToolButtonState extends State<IconToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final color = enabled ? T.accentStrong : T.muted;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            key: widget.buttonKey,
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover && enabled ? T.accentSoft : T.surface,
              borderRadius: BorderRadius.circular(T.rSm),
              border: Border.all(
                color: _hover && enabled ? T.accent : T.line,
                width: 1,
              ),
            ),
            child: Icon(widget.icon, size: 16, color: color),
          ),
        ),
      ),
    );
  }
}

class Input extends StatelessWidget {
  const Input({
    super.key,
    required this.label,
    required this.controller,
    this.obscure = false,
    this.onChanged,
  });
  final String label;
  final TextEditingController controller;
  final bool obscure;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: T.tCaption),
        const SizedBox(height: T.s4),
        TextField(
          controller: controller,
          obscureText: obscure,
          onChanged: onChanged,
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
      ],
    );
  }
}

class InlineTextField extends StatelessWidget {
  const InlineTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.onSubmitted,
    this.onChanged,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      height: 32,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        style: T.tCaption.copyWith(color: T.ink),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: T.tCaption,
          isDense: true,
          filled: true,
          fillColor: T.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: T.s8,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rSm),
            borderSide: const BorderSide(color: T.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rSm),
            borderSide: const BorderSide(color: T.accent, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class ReadonlyRow extends StatelessWidget {
  const ReadonlyRow({super.key, required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 96, child: Text(label, style: T.tCaption)),
        Expanded(
          child: Text(value, style: T.tBody, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

class ActionButton extends StatefulWidget {
  const ActionButton({
    super.key,
    required this.label,
    required this.onTap,
    this.strong = false,
  });
  final String label;
  final VoidCallback? onTap;
  final bool strong;

  @override
  State<ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<ActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final bg = widget.strong
        ? (enabled ? (_hover ? T.accentStrong : T.accent) : T.line)
        : (_hover && enabled ? T.accentSoft : T.surface);
    final fg = widget.strong
        ? const Color(0xFFFFFFFF)
        : (enabled ? T.accentStrong : T.muted);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(
              color: widget.strong ? bg : (enabled ? T.accent : T.line),
              width: 1.2,
            ),
          ),
          child: Text(
            widget.label,
            style: T.tBody.copyWith(color: fg, fontWeight: T.wMedium),
          ),
        ),
      ),
    );
  }
}

class ChoicePill extends StatefulWidget {
  const ChoicePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<ChoicePill> createState() => _ChoicePillState();
}

class _ChoicePillState extends State<ChoicePill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 180),
          padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 6),
          decoration: BoxDecoration(
            color: widget.selected || _hover ? T.accentSoft : T.surface,
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(
              color: widget.selected ? T.accent : T.line,
              width: 1,
            ),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.tCaption.copyWith(
              color: widget.selected ? T.accentStrong : T.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class ChoiceRow extends StatefulWidget {
  const ChoiceRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.detail,
    this.warn = false,
  });

  final String label;
  final String? detail;
  final bool selected;
  final bool warn;
  final VoidCallback onTap;

  @override
  State<ChoiceRow> createState() => _ChoiceRowState();
}

class _ChoiceRowState extends State<ChoiceRow> {
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
          height: 44,
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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.warn ? '${widget.label} ●' : widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.tBody.copyWith(
                  color: widget.warn ? T.warn : T.ink,
                  fontWeight: widget.selected ? T.wBold : T.wRegular,
                ),
              ),
              if (widget.detail != null && widget.detail!.isNotEmpty)
                Text(
                  widget.detail!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class SegmentButton extends StatefulWidget {
  const SegmentButton({
    super.key,
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<SegmentButton> createState() => _SegmentButtonState();
}

class _SegmentButtonState extends State<SegmentButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 150,
          padding: const EdgeInsets.symmetric(
            horizontal: T.s12,
            vertical: T.s8,
          ),
          decoration: BoxDecoration(
            color: widget.selected || _hover ? T.accentSoft : T.surface,
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(
              color: widget.selected ? T.accent : T.line,
              width: 1.2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.label,
                style: T.tBody.copyWith(
                  fontWeight: widget.selected ? T.wBold : T.wRegular,
                ),
              ),
              const SizedBox(height: 2),
              Text(widget.detail, style: T.tCaption),
            ],
          ),
        ),
      ),
    );
  }
}
