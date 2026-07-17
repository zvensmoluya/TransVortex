import 'package:flutter/material.dart';

import '../model/reasoning_effort.dart';
import '../theme/tokens.dart';
import 'designed_tooltip.dart';

Future<String?> showReasoningEffortPicker(
  BuildContext context, {
  required ReasoningEffortSupport support,
  Rect? anchorRect,
}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭思考程度选择',
    barrierColor: const Color(0x14000000),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (context, animation, secondaryAnimation) {
      final panel = _ReasoningEffortPanel(support: support);
      if (anchorRect == null) return Center(child: panel);
      final size = MediaQuery.sizeOf(context);
      const margin = 8.0;
      const gap = 6.0;
      const panelWidth = 320.0;
      final panelHeight = support.manualChoices.isEmpty ? 210.0 : 316.0;
      final maxLeft = size.width - panelWidth - margin;
      final left = anchorRect.left.clamp(
        margin,
        maxLeft < margin ? margin : maxLeft,
      );
      final below = anchorRect.bottom + gap;
      final maxTop = size.height - panelHeight - margin;
      final top = below + panelHeight <= size.height - margin
          ? below
          : (anchorRect.top - panelHeight - gap).clamp(
              margin,
              maxTop < margin ? margin : maxTop,
            );
      return Stack(
        children: [
          Positioned(
            left: left.toDouble(),
            top: top.toDouble(),
            width: panelWidth,
            child: panel,
          ),
        ],
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class ReasoningEffortButton extends StatefulWidget {
  const ReasoningEffortButton({
    super.key,
    required this.support,
    required this.onChanged,
    this.buttonKey,
    this.labelPrefix,
    this.tooltip = '思考程度',
  });

  final ReasoningEffortSupport support;
  final ValueChanged<String>? onChanged;
  final Key? buttonKey;
  final String? labelPrefix;
  final String tooltip;

  @override
  State<ReasoningEffortButton> createState() => _ReasoningEffortButtonState();
}

class _ReasoningEffortButtonState extends State<ReasoningEffortButton> {
  bool _hover = false;

  Future<void> _pick() async {
    final onChanged = widget.onChanged;
    if (onChanged == null) return;
    final renderObject = context.findRenderObject();
    final anchorRect = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
    final selected = await showReasoningEffortPicker(
      context,
      support: widget.support,
      anchorRect: anchorRect,
    );
    if (selected != null && mounted) onChanged(selected);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    final prefix = widget.labelPrefix?.trim() ?? '';
    final label = prefix.isEmpty
        ? widget.support.compactLabel
        : '$prefix · ${widget.support.compactLabel}';
    final child = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled ? _pick : null,
        child: Container(
          key: widget.buttonKey,
          constraints: const BoxConstraints(minHeight: 30, maxWidth: 190),
          padding: const EdgeInsets.symmetric(horizontal: T.s8),
          decoration: BoxDecoration(
            color: _hover && enabled ? T.accentSoft : T.surface,
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(
              color: _hover && enabled ? T.accent : T.line,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.bolt_rounded,
                size: 15,
                color: enabled ? T.accentStrong : T.muted,
              ),
              const SizedBox(width: T.s4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption.copyWith(
                    color: enabled ? T.ink : T.muted,
                    fontWeight: T.wMedium,
                  ),
                ),
              ),
              const SizedBox(width: T.s4),
              const Icon(
                Icons.keyboard_arrow_right_rounded,
                size: 16,
                color: T.muted,
              ),
            ],
          ),
        ),
      ),
    );
    return DesignedTooltip(
      message: '${widget.tooltip}：${widget.support.detailLabel}',
      height: 70,
      child: child,
    );
  }
}

class _ReasoningEffortPanel extends StatefulWidget {
  const _ReasoningEffortPanel({required this.support});

  final ReasoningEffortSupport support;

  @override
  State<_ReasoningEffortPanel> createState() => _ReasoningEffortPanelState();
}

class _ReasoningEffortPanelState extends State<_ReasoningEffortPanel> {
  late String _manualValue = widget.support.effectiveManualValue;
  late _ReasoningPolicy _policy = switch (widget.support.currentValue) {
    reasoningEffortAuto => _ReasoningPolicy.automatic,
    reasoningEffortServiceDefault => _ReasoningPolicy.serviceDefault,
    _ => _ReasoningPolicy.manual,
  };
  late bool _advancedExpanded = _policy == _ReasoningPolicy.serviceDefault;

  void _select(String value) => Navigator.of(context).pop(value);

  void _showManual() {
    setState(() {
      _policy = _ReasoningPolicy.manual;
      _advancedExpanded = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final support = widget.support;
    final manual = support.manualChoices;
    final selectedIndex = manual.indexWhere(
      (choice) => choice.value == _manualValue,
    );
    final sliderIndex = selectedIndex < 0 ? 0 : selectedIndex;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final motionDuration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final automaticLabel = support.automaticEffort.isEmpty
        ? ''
        : '当前：${reasoningEffortLabel(support.automaticEffort)}';
    return Material(
      color: T.surface,
      elevation: 12,
      shadowColor: const Color(0x30000000),
      borderRadius: BorderRadius.circular(T.rSm),
      child: Container(
        key: const ValueKey('reasoning-effort-picker'),
        width: 320,
        padding: const EdgeInsets.all(T.s12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(T.rSm),
          border: Border.all(color: T.line),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bolt_rounded, size: 18, color: T.accentStrong),
                const SizedBox(width: T.s8),
                Text('思考程度', style: T.tSection),
              ],
            ),
            const SizedBox(height: T.s8),
            _PolicyRow(
              key: const ValueKey('reasoning-mode-auto'),
              label: '自动',
              selected: _policy == _ReasoningPolicy.automatic,
              trailing: automaticLabel.isEmpty
                  ? null
                  : _AnimatedEffortLabel(
                      label: automaticLabel,
                      duration: motionDuration,
                    ),
              duration: motionDuration,
              onTap: () => _select(reasoningEffortAuto),
            ),
            if (manual.isNotEmpty)
              _PolicyRow(
                key: const ValueKey('reasoning-mode-manual'),
                label: '手动',
                selected: _policy == _ReasoningPolicy.manual,
                trailing: _policy == _ReasoningPolicy.manual
                    ? _AnimatedEffortLabel(
                        label: manual[sliderIndex].label,
                        duration: motionDuration,
                        accent: true,
                      )
                    : null,
                duration: motionDuration,
                onTap: _showManual,
              ),
            AnimatedSwitcher(
              duration: motionDuration,
              reverseDuration: motionDuration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return SizeTransition(
                  sizeFactor: animation,
                  alignment: Alignment.topCenter,
                  child: FadeTransition(opacity: animation, child: child),
                );
              },
              child: _policy == _ReasoningPolicy.manual && manual.isNotEmpty
                  ? _ManualEffortControl(
                      key: const ValueKey('reasoning-manual-controls'),
                      choices: manual,
                      selectedIndex: sliderIndex,
                      onChanged: (index) {
                        setState(() => _manualValue = manual[index].value);
                      },
                      onApply: (index) => _select(manual[index].value),
                    )
                  : const SizedBox(
                      key: ValueKey('reasoning-manual-controls-hidden'),
                    ),
            ),
            const SizedBox(height: T.s4),
            const Divider(height: 1, color: T.line),
            const SizedBox(height: T.s4),
            _AdvancedToggle(
              key: const ValueKey('reasoning-advanced-toggle'),
              expanded: _advancedExpanded,
              duration: motionDuration,
              onTap: () =>
                  setState(() => _advancedExpanded = !_advancedExpanded),
            ),
            AnimatedSwitcher(
              duration: motionDuration,
              reverseDuration: motionDuration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return SizeTransition(
                  sizeFactor: animation,
                  alignment: Alignment.topCenter,
                  child: FadeTransition(opacity: animation, child: child),
                );
              },
              child: _advancedExpanded
                  ? DesignedTooltip(
                      key: const ValueKey('reasoning-service-default-wrap'),
                      message: '请求中不指定思考程度，由上游模型服务决定。',
                      height: 70,
                      child: _PolicyRow(
                        key: const ValueKey('reasoning-mode-service-default'),
                        label: '由模型服务决定',
                        selected: _policy == _ReasoningPolicy.serviceDefault,
                        duration: motionDuration,
                        onTap: () => _select(reasoningEffortServiceDefault),
                      ),
                    )
                  : const SizedBox(
                      key: ValueKey('reasoning-service-default-hidden'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _ReasoningPolicy { automatic, manual, serviceDefault }

class _PolicyRow extends StatelessWidget {
  const _PolicyRow({
    super.key,
    required this.label,
    required this.selected,
    required this.duration,
    required this.onTap,
    this.trailing,
  });

  final String label;
  final bool selected;
  final Duration duration;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: BorderRadius.circular(T.rSm),
        onTap: onTap,
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: T.s8),
          decoration: BoxDecoration(
            color: selected
                ? T.accentSoft.withValues(alpha: 0.62)
                : const Color(0x00000000),
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(
              color: selected
                  ? T.accent.withValues(alpha: 0.72)
                  : const Color(0x00000000),
            ),
          ),
          child: Row(
            children: [
              _PolicyIndicator(selected: selected, duration: duration),
              const SizedBox(width: T.s8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tBody.copyWith(
                    color: selected ? T.accentStrong : T.ink,
                    fontWeight: selected ? T.wMedium : T.wRegular,
                  ),
                ),
              ),
              if (trailing case final value?) ...[
                const SizedBox(width: T.s8),
                value,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PolicyIndicator extends StatelessWidget {
  const _PolicyIndicator({required this.selected, required this.duration});

  final bool selected;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeOutCubic,
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: T.surface,
        border: Border.all(
          color: selected ? T.accentStrong : T.line,
          width: selected ? 1.6 : 1,
        ),
      ),
      child: Center(
        child: AnimatedScale(
          scale: selected ? 1 : 0,
          duration: duration,
          curve: Curves.easeOutBack,
          child: Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: T.accentStrong,
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatedEffortLabel extends StatelessWidget {
  const _AnimatedEffortLabel({
    required this.label,
    required this.duration,
    this.accent = false,
  });

  final String label;
  final Duration duration;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      transitionBuilder: (child, animation) {
        final offset = Tween<Offset>(
          begin: const Offset(0, 0.18),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut));
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offset, child: child),
        );
      },
      child: Text(
        label,
        key: ValueKey(label),
        style: T.tCaption.copyWith(
          color: accent ? T.accentStrong : T.muted,
          fontWeight: accent ? T.wBold : T.wRegular,
        ),
      ),
    );
  }
}

class _ManualEffortControl extends StatelessWidget {
  const _ManualEffortControl({
    super.key,
    required this.choices,
    required this.selectedIndex,
    required this.onChanged,
    required this.onApply,
  });

  final List<ReasoningEffortChoice> choices;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onApply;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(T.s4, T.s4, T.s4, T.s8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('具体档位', style: T.tCaption),
              const Spacer(),
              DesignedTooltip(
                message: '使用${choices[selectedIndex].label}档',
                width: 150,
                height: 62,
                child: InkWell(
                  key: const ValueKey('reasoning-manual-apply'),
                  borderRadius: BorderRadius.circular(T.rSm),
                  onTap: () => onApply(selectedIndex),
                  child: Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: T.accentSoft,
                      borderRadius: BorderRadius.circular(T.rSm),
                      border: Border.all(color: T.accent),
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 17,
                      color: T.accentStrong,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (choices.length > 1) ...[
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: T.accentStrong,
                inactiveTrackColor: T.line,
                disabledActiveTrackColor: T.muted,
                disabledInactiveTrackColor: T.line,
                thumbColor: T.surface,
                overlayColor: T.accentSoft.withValues(alpha: 0.7),
                trackHeight: 6,
                trackShape: const RoundedRectSliderTrackShape(),
                thumbShape: const _EffortThumbShape(),
                tickMarkShape: const _EffortTickMarkShape(),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                key: const ValueKey('reasoning-manual-slider'),
                value: selectedIndex.toDouble(),
                min: 0,
                max: (choices.length - 1).toDouble(),
                divisions: choices.length - 1,
                semanticFormatterCallback: (value) =>
                    choices[value.round()].label,
                onChanged: (value) => onChanged(value.round()),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(choices.first.label, style: T.tCaption),
                Text(choices.last.label, style: T.tCaption),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AdvancedToggle extends StatelessWidget {
  const _AdvancedToggle({
    super.key,
    required this.expanded,
    required this.duration,
    required this.onTap,
  });

  final bool expanded;
  final Duration duration;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(T.rSm),
      onTap: onTap,
      child: SizedBox(
        height: 34,
        child: Row(
          children: [
            const SizedBox(width: T.s8),
            Text('高级', style: T.tCaption.copyWith(color: T.ink)),
            const Spacer(),
            AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: duration,
              curve: Curves.easeOutCubic,
              child: const Icon(
                Icons.keyboard_arrow_right_rounded,
                size: 18,
                color: T.muted,
              ),
            ),
            const SizedBox(width: T.s4),
          ],
        ),
      ),
    );
  }
}

class _EffortThumbShape extends SliderComponentShape {
  const _EffortThumbShape();

  static const double _radius = 9;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(_radius + 2);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final pressed = activationAnimation.value;
    final radius = _radius + pressed;
    final path = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    canvas.drawShadow(path, const Color(0x44000000), 2.5 + pressed, true);
    canvas.drawCircle(center, radius, Paint()..color = T.surface);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = T.accent.withValues(alpha: 0.72 + 0.28 * pressed)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }
}

class _EffortTickMarkShape extends SliderTickMarkShape {
  const _EffortTickMarkShape();

  @override
  Size getPreferredSize({
    required SliderThemeData sliderTheme,
    required bool isEnabled,
  }) => const Size.fromRadius(2);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    required bool isEnabled,
    required TextDirection textDirection,
  }) {
    final active = textDirection == TextDirection.ltr
        ? center.dx <= thumbCenter.dx
        : center.dx >= thumbCenter.dx;
    context.canvas.drawCircle(
      center,
      1.8,
      Paint()
        ..color = active
            ? T.surface.withValues(alpha: 0.92)
            : T.muted.withValues(alpha: 0.32),
    );
  }
}
