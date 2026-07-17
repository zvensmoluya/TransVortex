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
      final panelHeight = support.manualChoices.isEmpty ? 116.0 : 196.0;
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

  void _select(String value) => Navigator.of(context).pop(value);

  @override
  Widget build(BuildContext context) {
    final support = widget.support;
    final manual = support.manualChoices;
    final selectedIndex = manual.indexWhere(
      (choice) => choice.value == _manualValue,
    );
    final sliderIndex = selectedIndex < 0 ? 0 : selectedIndex;
    return Material(
      color: T.surface,
      elevation: 12,
      shadowColor: const Color(0x30000000),
      borderRadius: BorderRadius.circular(T.rSm),
      child: Container(
        key: const ValueKey('reasoning-effort-picker'),
        width: 320,
        padding: const EdgeInsets.all(T.s16),
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
            Row(
              children: [
                Expanded(
                  child: _ModeButton(
                    key: const ValueKey('reasoning-mode-auto'),
                    label: '自动',
                    selected: support.currentValue == reasoningEffortAuto,
                    onTap: () => _select(reasoningEffortAuto),
                  ),
                ),
                const SizedBox(width: T.s8),
                Expanded(
                  child: _ModeButton(
                    key: const ValueKey('reasoning-mode-service-default'),
                    label: '服务默认',
                    selected:
                        support.currentValue == reasoningEffortServiceDefault,
                    onTap: () => _select(reasoningEffortServiceDefault),
                  ),
                ),
              ],
            ),
            if (manual.isNotEmpty) ...[
              const SizedBox(height: T.s16),
              Row(
                children: [
                  Text('手动', style: T.tCaption),
                  const Spacer(),
                  const Icon(
                    Icons.bolt_rounded,
                    size: 15,
                    color: T.accentStrong,
                  ),
                  const SizedBox(width: T.s4),
                  Text(manual[sliderIndex].label, style: T.tSection),
                ],
              ),
              const SizedBox(height: T.s4),
              if (manual.length == 1)
                _ModeButton(
                  label: manual.first.label,
                  selected: support.currentValue == manual.first.value,
                  onTap: () => _select(manual.first.value),
                )
              else
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: T.accentStrong,
                    inactiveTrackColor: T.line,
                    thumbColor: T.surface,
                    overlayColor: T.accentSoft,
                    trackHeight: 6,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 9,
                      elevation: 2,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 16,
                    ),
                  ),
                  child: Slider(
                    key: const ValueKey('reasoning-manual-slider'),
                    value: sliderIndex.toDouble(),
                    min: 0,
                    max: (manual.length - 1).toDouble(),
                    divisions: manual.length - 1,
                    semanticFormatterCallback: (value) =>
                        manual[value.round()].label,
                    onChanged: (value) {
                      setState(
                        () => _manualValue = manual[value.round()].value,
                      );
                    },
                    onChangeEnd: (value) =>
                        _select(manual[value.round()].value),
                  ),
                ),
              if (manual.length > 1)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(manual.first.label, style: T.tCaption),
                    Text(manual.last.label, style: T.tCaption),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? T.accentSoft : T.surface,
          borderRadius: BorderRadius.circular(T.rSm),
          border: Border.all(color: selected ? T.accent : T.line),
        ),
        child: Text(
          label,
          style: T.tCaption.copyWith(
            color: selected ? T.accentStrong : T.ink,
            fontWeight: selected ? T.wBold : T.wMedium,
          ),
        ),
      ),
    );
  }
}
