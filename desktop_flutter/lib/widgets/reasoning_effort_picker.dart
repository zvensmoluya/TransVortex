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
      final usesServiceDefault =
          support.currentValue == reasoningEffortServiceDefault;
      final panelHeight = support.manualChoices.isEmpty
          ? (usesServiceDefault ? 210.0 : 170.0)
          : (usesServiceDefault ? 270.0 : 230.0);
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
        ? widget.support.displayLabel
        : '$prefix · ${widget.support.displayLabel}';
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
  late String _sliderValue = widget.support.effectiveManualValue;
  late bool _advancedExpanded =
      widget.support.currentValue == reasoningEffortServiceDefault;

  void _select(String value) =>
      Navigator.of(context, rootNavigator: true).pop(value);

  @override
  Widget build(BuildContext context) {
    final support = widget.support;
    final manual = support.manualChoices;
    final selectedIndex = manual.indexWhere(
      (choice) => choice.value == _sliderValue,
    );
    final sliderIndex = selectedIndex < 0 ? 0 : selectedIndex;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final motionDuration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final usesModelDefault = support.currentValue == reasoningEffortAuto;
    final usesServiceDefault =
        support.currentValue == reasoningEffortServiceDefault;
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
            const SizedBox(height: T.s12),
            if (manual.isNotEmpty)
              _EffortSliderControl(
                choices: manual,
                selectedIndex: sliderIndex,
                automaticEffort: support.automaticEffort,
                usesModelDefault: usesModelDefault,
                usesServiceDefault: usesServiceDefault,
                onChanged: (index) {
                  setState(() => _sliderValue = manual[index].value);
                },
                onChangeEnd: (index) => _select(manual[index].value),
                onResetDefault: usesModelDefault
                    ? null
                    : () => _select(reasoningEffortAuto),
              )
            else
              _DefaultOnlyControl(
                label: support.detailLabel,
                usesModelDefault: usesModelDefault,
                onResetDefault: usesModelDefault
                    ? null
                    : () => _select(reasoningEffortAuto),
              ),
            const SizedBox(height: T.s8),
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
                        selected: usesServiceDefault,
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

class _PolicyRow extends StatelessWidget {
  const _PolicyRow({
    super.key,
    required this.label,
    required this.selected,
    required this.duration,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Duration duration;
  final VoidCallback onTap;

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

class _EffortSliderControl extends StatelessWidget {
  const _EffortSliderControl({
    required this.choices,
    required this.selectedIndex,
    required this.automaticEffort,
    required this.usesModelDefault,
    required this.usesServiceDefault,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onResetDefault,
  });

  final List<ReasoningEffortChoice> choices;
  final int selectedIndex;
  final String automaticEffort;
  final bool usesModelDefault;
  final bool usesServiceDefault;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;
  final VoidCallback? onResetDefault;

  @override
  Widget build(BuildContext context) {
    final currentLabel = choices[selectedIndex].label;
    final normalizedAutomatic = automaticEffort.trim().isEmpty
        ? ''
        : normalizeReasoningEffort(automaticEffort);
    final automaticChoice = choices.where(
      (choice) => choice.value == normalizedAutomatic,
    );
    final automaticLabel = automaticChoice.isEmpty
        ? ''
        : automaticChoice.first.label;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: T.s4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(usesServiceDefault ? '选择明确档位' : '当前档位', style: T.tCaption),
              const Spacer(),
              if (usesServiceDefault)
                Text(
                  '当前由服务决定',
                  key: const ValueKey('reasoning-current-effort'),
                  style: T.tCaption.copyWith(color: T.muted),
                )
              else ...[
                Text(
                  currentLabel,
                  key: const ValueKey('reasoning-current-effort'),
                  style: T.tCaption.copyWith(
                    color: T.accentStrong,
                    fontWeight: T.wBold,
                  ),
                ),
                if (usesModelDefault) ...[
                  const SizedBox(width: T.s8),
                  const _ModelDefaultBadge(),
                ],
              ],
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
                key: const ValueKey('reasoning-effort-slider'),
                value: selectedIndex.toDouble(),
                min: 0,
                max: (choices.length - 1).toDouble(),
                divisions: choices.length - 1,
                semanticFormatterCallback: (value) =>
                    choices[value.round()].label,
                onChanged: (value) => onChanged(value.round()),
                onChangeEnd: (value) => onChangeEnd(value.round()),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(choices.first.label, style: T.tCaption),
                Text(choices.last.label, style: T.tCaption),
              ],
            ),
          ] else ...[
            const SizedBox(height: T.s8),
            InkWell(
              key: const ValueKey('reasoning-effort-single-choice'),
              borderRadius: BorderRadius.circular(T.rSm),
              onTap: () => onChangeEnd(0),
              child: Container(
                width: double.infinity,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: T.accentSoft.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(T.rSm),
                  border: Border.all(color: T.accent),
                ),
                child: Text('使用$currentLabel档', style: T.tCaption),
              ),
            ),
          ],
          const SizedBox(height: T.s8),
          Row(
            children: [
              Expanded(
                child: Text(
                  automaticLabel.isEmpty ? '模型默认档位未标注' : '模型默认：$automaticLabel',
                  key: const ValueKey('reasoning-model-default'),
                  style: T.tCaption.copyWith(
                    color: usesModelDefault ? T.accentStrong : T.muted,
                  ),
                ),
              ),
              if (onResetDefault case final reset?)
                _ResetDefaultAction(onTap: reset),
            ],
          ),
        ],
      ),
    );
  }
}

class _DefaultOnlyControl extends StatelessWidget {
  const _DefaultOnlyControl({
    required this.label,
    required this.usesModelDefault,
    required this.onResetDefault,
  });

  final String label;
  final bool usesModelDefault;
  final VoidCallback? onResetDefault;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(T.s8),
      decoration: BoxDecoration(
        color: T.accentSoft.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line),
      ),
      child: Row(
        children: [
          Expanded(child: Text(label, style: T.tCaption)),
          if (usesModelDefault)
            const _ModelDefaultBadge()
          else if (onResetDefault case final reset?)
            _ResetDefaultAction(onTap: reset),
        ],
      ),
    );
  }
}

class _ModelDefaultBadge extends StatelessWidget {
  const _ModelDefaultBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('reasoning-default-badge'),
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 2),
      decoration: BoxDecoration(
        color: T.accentSoft,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: T.accent.withValues(alpha: 0.72)),
      ),
      child: Text(
        '模型默认',
        style: T.tCaption.copyWith(
          color: T.accentStrong,
          fontWeight: T.wMedium,
        ),
      ),
    );
  }
}

class _ResetDefaultAction extends StatelessWidget {
  const _ResetDefaultAction({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('reasoning-reset-default'),
      borderRadius: BorderRadius.circular(T.rSm),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: T.s4),
        child: Text(
          '恢复模型默认',
          style: T.tCaption.copyWith(
            color: T.accentStrong,
            fontWeight: T.wMedium,
          ),
        ),
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
