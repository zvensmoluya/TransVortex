import 'dart:math' as math;

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
    this.onRetry,
  });

  final String text;
  final bool busy;
  final String? error;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: T.s12),
      decoration: BoxDecoration(
        color: T.surface.withValues(alpha: 0.68),
        border: const Border(bottom: BorderSide(color: T.line, width: 1)),
      ),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          const _TapeMarker(width: 16, height: 18),
          const SizedBox(width: T.s12),
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
          if (!busy && error != null && onRetry != null) ...[
            const SizedBox(width: T.s8),
            ActionButton(label: '重试', onTap: onRetry),
          ],
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
          Row(
            children: [
              const _TapeMarker(width: 10, height: 15),
              const SizedBox(width: T.s8),
              Text(title, style: T.tSection),
              const SizedBox(width: T.s12),
              Expanded(
                child: Container(
                  height: 1,
                  color: T.line.withValues(alpha: 0.78),
                ),
              ),
            ],
          ),
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

class SettingsTabOption<V> {
  const SettingsTabOption({required this.value, required this.label});

  final V value;
  final String label;
}

class SettingsTabs<V> extends StatelessWidget {
  const SettingsTabs({
    super.key,
    required this.options,
    required this.selected,
    required this.onPick,
    this.tabWidth = 96,
  });

  final List<SettingsTabOption<V>> options;
  final V selected;
  final ValueChanged<V> onPick;
  final double tabWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line, width: 1),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in options)
              _SettingsTabButton(
                label: option.label,
                selected: option.value == selected,
                onTap: () => onPick(option.value),
                width: tabWidth,
              ),
          ],
        ),
      ),
    );
  }
}

class _SettingsTabButton extends StatefulWidget {
  const _SettingsTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.width,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double width;

  @override
  State<_SettingsTabButton> createState() => _SettingsTabButtonState();
}

class _SettingsTabButtonState extends State<_SettingsTabButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          width: widget.width,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.selected
                ? T.accentSoft
                : _hover
                ? T.accentSoft.withValues(alpha: 0.42)
                : const Color(0x00000000),
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(
              color: widget.selected ? T.accent : const Color(0x00000000),
              width: 1,
            ),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.tBody.copyWith(
              color: widget.selected ? T.accentStrong : T.ink,
              fontWeight: widget.selected ? T.wBold : T.wMedium,
            ),
          ),
        ),
      ),
    );
  }
}

class _TapeMarker extends StatelessWidget {
  const _TapeMarker({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: const CustomPaint(painter: _TapeMarkerPainter()),
    );
  }
}

class _TapeMarkerPainter extends CustomPainter {
  const _TapeMarkerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final tape = Path()
      ..moveTo(1, 1)
      ..lineTo(size.width, 0)
      ..lineTo(size.width - 1, size.height - 2)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(tape, Paint()..color = T.skySoft);
    canvas.drawPath(
      tape,
      Paint()
        ..color = T.sky.withValues(alpha: 0.72)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.drawLine(
      Offset(size.width * 0.56, 2),
      Offset(size.width * 0.44, size.height - 2),
      Paint()
        ..color = T.accent.withValues(alpha: 0.64)
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_TapeMarkerPainter oldDelegate) => false;
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
        if (footer.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.only(top: T.s12),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: T.line, width: 1)),
            ),
            child: Wrap(spacing: T.s12, runSpacing: T.s8, children: footer),
          ),
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
    this.reasoningControl,
  });

  final String provider;
  final String model;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback? onRemove;
  final Widget? reasoningControl;

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
          if (reasoningControl case final control?) ...[
            control,
            const SizedBox(width: T.s8),
          ],
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
    this.hintText,
    this.keyboardType,
  });
  final String label;
  final TextEditingController controller;
  final bool obscure;
  final ValueChanged<String>? onChanged;
  final String? hintText;
  final TextInputType? keyboardType;

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
          keyboardType: keyboardType,
          onChanged: onChanged,
          style: T.tBody,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: T.surface,
            hintText: hintText,
            hintStyle: T.tCaption,
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
    this.icon,
  });
  final String label;
  final VoidCallback? onTap;
  final bool strong;
  final IconData? icon;

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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon case final icon?) ...[
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: T.s4),
              ],
              Text(
                widget.label,
                style: T.tBody.copyWith(color: fg, fontWeight: T.wMedium),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FeedbackActionButton extends StatefulWidget {
  const FeedbackActionButton({
    super.key,
    required this.label,
    required this.onTap,
    this.strong = false,
    this.busy = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool strong;
  final bool busy;
  final bool danger;

  @override
  State<FeedbackActionButton> createState() => _FeedbackActionButtonState();
}

class _FeedbackActionButtonState extends State<FeedbackActionButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final active = enabled || widget.busy;
    final bg = widget.strong
        ? (active ? (_hover ? T.accentStrong : T.accent) : T.line)
        : widget.danger
        ? (_hover && enabled ? T.danger.withValues(alpha: 0.08) : T.surface)
        : (_hover && enabled
              ? T.accentSoft.withValues(alpha: 0.55)
              : T.surface);
    final fg = widget.strong
        ? const Color(0xFFFFFFFF)
        : !active
        ? T.muted
        : widget.danger
        ? T.danger
        : T.ink;
    final border = widget.strong
        ? bg
        : !active
        ? T.line
        : widget.danger
        ? T.danger.withValues(alpha: 0.76)
        : _hover
        ? T.accent.withValues(alpha: 0.76)
        : T.line;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: enabled ? (_) => setState(() => _hover = true) : null,
      onExit: enabled
          ? (_) => setState(() {
              _hover = false;
              _down = false;
            })
          : null,
      child: AnimatedScale(
        scale: _down ? 0.98 : 1,
        duration: const Duration(milliseconds: 90),
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTapCancel: enabled ? () => setState(() => _down = false) : null,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOut,
            height: 36,
            constraints: const BoxConstraints(minWidth: 116),
            padding: const EdgeInsets.symmetric(horizontal: T.s12),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(T.rMd),
              border: Border.all(color: border, width: 1.2),
              boxShadow: widget.strong && active
                  ? [
                      BoxShadow(
                        color: T.accentStrong.withValues(
                          alpha: _down ? 0.06 : 0.14,
                        ),
                        offset: Offset(0, _down ? 1 : 3),
                        blurRadius: _down ? 2 : 7,
                      ),
                    ]
                  : const [],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.label,
                  style: T.tBody.copyWith(color: fg, fontWeight: T.wMedium),
                ),
                if (widget.busy) ...[
                  const SizedBox(width: 7),
                  _WorkingDots(color: fg),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkingDots extends StatefulWidget {
  const _WorkingDots({required this.color});

  final Color color;

  @override
  State<_WorkingDots> createState() => _WorkingDotsState();
}

class _WorkingDotsState extends State<_WorkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 8,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _WorkingDotsPainter(
            phase: _controller.value,
            color: widget.color,
          ),
        ),
      ),
    );
  }
}

class _WorkingDotsPainter extends CustomPainter {
  const _WorkingDotsPainter({required this.phase, required this.color});

  final double phase;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    for (var index = 0; index < 3; index++) {
      final wave = (math.sin((phase - index * 0.18) * math.pi * 2) + 1) / 2;
      canvas.drawCircle(
        Offset(3 + index * 6, size.height / 2),
        1.5 + wave * 0.45,
        Paint()..color = color.withValues(alpha: 0.38 + wave * 0.62),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WorkingDotsPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.color != color;
}

class ChoicePill extends StatefulWidget {
  const ChoicePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.showCheck = false,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool showCheck;

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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.showCheck && widget.selected) ...[
                Icon(Icons.check_rounded, size: 14, color: T.accentStrong),
                const SizedBox(width: 3),
              ],
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption.copyWith(
                    color: widget.selected ? T.accentStrong : T.ink,
                  ),
                ),
              ),
            ],
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
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.warn ? T.warn : T.accentStrong;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          height: 48,
          transform: Matrix4.translationValues(
            widget.selected ? 3 : 0,
            _down ? 1 : 0,
            0,
          ),
          decoration: BoxDecoration(
            border: const Border(bottom: BorderSide(color: T.line, width: 1)),
            color: widget.selected
                ? T.accentSoft.withValues(alpha: 0.38)
                : _hover
                ? T.surface
                : const Color(0x00000000),
          ),
          padding: const EdgeInsets.only(right: T.s8),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              SizedBox(
                width: 14,
                height: 34,
                child: CustomPaint(
                  painter: _ChoiceTapePainter(
                    color: color,
                    selected: widget.selected,
                    active: _hover || widget.warn,
                  ),
                ),
              ),
              const SizedBox(width: T.s8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.tBody.copyWith(
                        color: T.ink,
                        fontWeight: widget.selected ? T.wBold : T.wRegular,
                      ),
                    ),
                    if (widget.detail != null && widget.detail!.isNotEmpty)
                      Text(
                        widget.detail!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.tCaption.copyWith(
                          color: widget.warn ? T.warn : T.muted,
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.warn)
                Text(
                  '需配置',
                  maxLines: 1,
                  style: T.tCaption.copyWith(color: T.warn),
                ),
              if (widget.selected) ...[
                const SizedBox(width: T.s8),
                SizedBox(
                  width: 14,
                  height: 24,
                  child: CustomPaint(painter: _ChoiceClipPainter(color: color)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoiceTapePainter extends CustomPainter {
  const _ChoiceTapePainter({
    required this.color,
    required this.selected,
    required this.active,
  });

  final Color color;
  final bool selected;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final opacity = selected
        ? 0.94
        : active
        ? 0.42
        : 0.12;
    final path = Path()
      ..moveTo(0, 2)
      ..lineTo(size.width - 2, 0)
      ..lineTo(size.width - 1, size.height - 5)
      ..lineTo(size.width * 0.55, size.height)
      ..lineTo(1, size.height - 3)
      ..close();
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: opacity));
    if (selected) {
      canvas.drawLine(
        Offset(size.width * 0.52, 7),
        Offset(size.width * 0.52, size.height - 9),
        Paint()
          ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.66)
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChoiceTapePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.selected != selected ||
      oldDelegate.active != active;
}

class _ChoiceClipPainter extends CustomPainter {
  const _ChoiceClipPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.82)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(size.width * 0.72, 3)
      ..quadraticBezierTo(size.width * 0.18, 3, size.width * 0.22, 10)
      ..lineTo(size.width * 0.22, size.height - 5)
      ..quadraticBezierTo(
        size.width * 0.24,
        size.height - 1,
        size.width * 0.56,
        size.height - 4,
      )
      ..lineTo(size.width * 0.56, 8);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ChoiceClipPainter oldDelegate) =>
      oldDelegate.color != color;
}

class SegmentButton extends StatefulWidget {
  const SegmentButton({
    super.key,
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
    this.width = 150,
  });
  final String label;
  final String detail;
  final bool selected;
  final VoidCallback? onTap;
  final double width;

  @override
  State<SegmentButton> createState() => _SegmentButtonState();
}

class _SegmentButtonState extends State<SegmentButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: widget.width,
          padding: const EdgeInsets.symmetric(
            horizontal: T.s12,
            vertical: T.s8,
          ),
          decoration: BoxDecoration(
            color: widget.selected || (_hover && widget.onTap != null)
                ? T.accentSoft
                : T.surface,
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
                  color: widget.onTap == null ? T.muted : T.ink,
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
