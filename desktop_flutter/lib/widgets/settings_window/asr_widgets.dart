part of '../settings_window.dart';

class _AsrFeedbackBar extends StatelessWidget {
  const _AsrFeedbackBar({
    required this.busy,
    required this.busyText,
    required this.error,
    required this.message,
  });

  final bool busy;
  final String busyText;
  final String? error;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final text = busy
        ? busyText
        : error?.trim().isNotEmpty == true
        ? error!.trim()
        : message?.trim() ?? '';
    final color = !busy && error?.trim().isNotEmpty == true
        ? T.danger
        : T.accentStrong;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(T.rSm),
      ),
      child: Row(
        children: [
          if (busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            )
          else
            Icon(
              error?.trim().isNotEmpty == true
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              size: 16,
              color: color,
            ),
          const SizedBox(width: T.s8),
          Expanded(
            child: Text(
              text,
              style: T.tCaption.copyWith(color: color),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _SegmentedEngines extends StatelessWidget {
  const _SegmentedEngines({
    required this.selected,
    required this.active,
    required this.activeReady,
    required this.onPick,
  });

  final String selected;
  final String active;
  final bool activeReady;
  final ValueChanged<String>? onPick;

  @override
  Widget build(BuildContext context) {
    const items = [
      ('faster_whisper_large_v3', '本机 Whisper', '本机运行'),
      ('openai_whisper', 'OpenAI Whisper', '云端识别'),
      ('openrouter_asr', 'OpenRouter', 'Whisper / Grok'),
      ('funasr_sensevoice_local', 'FunASR', '本地服务'),
    ];
    return Row(
      children: [
        for (var index = 0; index < items.length; index++) ...[
          if (index > 0) const SizedBox(width: T.s8),
          Expanded(
            child: SegmentButton(
              width: double.infinity,
              label: items[index].$2,
              detail: items[index].$3,
              selected: selected == items[index].$1,
              statusLabel: active == items[index].$1
                  ? activeReady
                        ? '当前默认'
                        : '默认未配置'
                  : null,
              statusColor: activeReady ? T.ok : T.warn,
              onTap: onPick == null ? null : () => onPick!(items[index].$1),
            ),
          ),
        ],
      ],
    );
  }
}

class _AsrSelect extends StatelessWidget {
  const _AsrSelect({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String value;
  final Map<String, String> items;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = items.containsKey(value) ? value : items.keys.first;
    return DropdownButtonFormField<String>(
      key: ValueKey('$label:$selected'),
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
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
      ),
      items: [
        for (final entry in items.entries)
          DropdownMenuItem<String>(
            value: entry.key,
            child: Text(entry.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged == null
          ? null
          : (next) {
              if (next != null) onChanged!(next);
            },
    );
  }
}

class _AsrOverview extends StatelessWidget {
  const _AsrOverview({
    required this.label,
    required this.readiness,
    required this.draftDirty,
  });

  final String label;
  final AsrReadiness? readiness;
  final bool draftDirty;

  @override
  Widget build(BuildContext context) {
    final state = readiness?.state ?? 'unavailable';
    final color = draftDirty ? T.accentStrong : _asrStateColor(state);
    final status = draftDirty ? '尚未保存' : _asrStatusChipLabel(readiness);
    final hint = draftDirty
        ? '保存后会重新检查这套本地识别方案。'
        : _asrReadinessHint(readiness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rMd),
        border: Border.all(color: T.line),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 40,
            height: 40,
            child: CustomPaint(painter: _WhisperBuddyPainter()),
          ),
          const SizedBox(width: T.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: T.tBody.copyWith(fontWeight: T.wBold)),
                const SizedBox(height: 2),
                Text(hint, style: T.tCaption, maxLines: 1),
              ],
            ),
          ),
          const SizedBox(width: T.s12),
          _AsrStatusChip(label: status, color: color),
        ],
      ),
    );
  }
}

class _AsrExecutionSummary extends StatelessWidget {
  const _AsrExecutionSummary({required this.provider});

  final AsrProviderOption provider;

  @override
  Widget build(BuildContext context) {
    final policy = _stringMap(provider.policyResolution['policy']);
    final chunking = _stringMap(policy['chunking']);
    final execution = _stringMap(policy['execution']);
    final timeline = _stringMap(provider.capabilities['timeline']);
    final granularities = (timeline['granularities'] as List? ?? const [])
        .map((item) => '$item')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final parts = <String>[
      if (chunking['window_target_seconds'] case final num seconds)
        '分窗 ${_compactNumber(seconds)} 秒',
      if (chunking['overlap_seconds'] case final num seconds)
        '重叠 ${_compactNumber(seconds)} 秒',
      if (execution['target_concurrency'] case final num concurrency)
        '并发目标 ${concurrency.toInt()} 路',
      if (granularities.contains('word'))
        '逐词时间戳'
      else if (granularities.contains('segment'))
        '分段时间戳',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        const Icon(Icons.tune_rounded, size: 16, color: T.muted),
        const SizedBox(width: T.s8),
        Expanded(
          child: Text(
            '自动运行策略 · ${parts.join(' · ')}',
            style: T.tCaption.copyWith(color: T.muted),
          ),
        ),
      ],
    );
  }

  static String _compactNumber(num value) {
    final number = value.toDouble();
    return number == number.roundToDouble()
        ? number.toInt().toString()
        : number.toStringAsFixed(1);
  }
}

class _LocalWhisperCurrent {
  const _LocalWhisperCurrent({
    required this.configured,
    required this.isDefault,
    required this.ready,
    required this.modelId,
    required this.modelSource,
    required this.modelPath,
    required this.executionDetail,
  });

  final bool configured;
  final bool isDefault;
  final bool ready;
  final String modelId;
  final String modelSource;
  final String modelPath;
  final String executionDetail;
}

class _AsrChange {
  const _AsrChange({
    required this.label,
    required this.before,
    required this.after,
  });

  final String label;
  final String before;
  final String after;
}

class _AsrApplySummary extends StatelessWidget {
  const _AsrApplySummary({
    required this.changes,
    required this.downloadItems,
    required this.requiredDownloadBytes,
    required this.storage,
  });

  final List<_AsrChange> changes;
  final List<String> downloadItems;
  final int requiredDownloadBytes;
  final AsrStorageOption storage;

  @override
  Widget build(BuildContext context) {
    final storageAvailable =
        storage.configError.isEmpty && storage.diskError.isEmpty;
    final hasSpace = storage.hasSpaceFor(requiredDownloadBytes);
    final requiredBytes = storage.requiredBytesFor(requiredDownloadBytes);
    final storageHint = !storageAvailable
        ? '识别资源位置不可用，请检查目标磁盘。'
        : !hasSpace
        ? '至少需要 ${_formatBytes(requiredBytes)} 可用空间。'
        : '';
    return Container(
      key: const ValueKey('asr-apply-summary'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.lilacSoft.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (changes.isNotEmpty) ...[
            Row(
              children: [
                const Icon(Icons.tune_rounded, size: 17, color: T.muted),
                const SizedBox(width: T.s8),
                Text(
                  '即将应用',
                  style: T.tCaption.copyWith(color: T.ink, fontWeight: T.wBold),
                ),
              ],
            ),
            for (final change in changes) ...[
              const SizedBox(height: T.s4),
              Padding(
                padding: const EdgeInsets.only(left: 25),
                child: Text(
                  '${change.label}：${change.before}  →  ${change.after}',
                  style: T.tCaption.copyWith(color: T.ink),
                ),
              ),
            ],
          ],
          if (downloadItems.isNotEmpty) ...[
            if (changes.isNotEmpty) const SizedBox(height: T.s8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.download_rounded, size: 17, color: T.warn),
                const SizedBox(width: T.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '需要下载 ${_formatBytes(requiredDownloadBytes)}',
                        style: T.tCaption.copyWith(
                          color: T.ink,
                          fontWeight: T.wBold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(downloadItems.join(' · '), style: T.tCaption),
                      const SizedBox(height: T.s4),
                      Row(
                        children: [
                          const Icon(
                            Icons.folder_outlined,
                            size: 15,
                            color: T.muted,
                          ),
                          const SizedBox(width: T.s4),
                          Expanded(
                            child: Tooltip(
                              message: storage.root,
                              child: Text(
                                storage.root.isEmpty
                                    ? '保存位置尚未就绪'
                                    : '保存到 ${storage.root}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: T.tCaption,
                              ),
                            ),
                          ),
                          if (storage.spaceKnown) ...[
                            const SizedBox(width: T.s8),
                            Text(
                              '可用 ${_formatBytes(storage.freeBytes)}',
                              style: T.tCaption,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
          if (storageHint.isNotEmpty) ...[
            const SizedBox(height: T.s8),
            Text(storageHint, style: T.tCaption.copyWith(color: T.danger)),
          ],
        ],
      ),
    );
  }
}

class _AsrExternalModelChoice {
  const _AsrExternalModelChoice.registered(this.externalRegistrationId)
    : browseExternal = false;

  const _AsrExternalModelChoice.browse()
    : externalRegistrationId = '',
      browseExternal = true;

  final String externalRegistrationId;
  final bool browseExternal;
}

class _AsrExternalModelDialog extends StatefulWidget {
  const _AsrExternalModelDialog({
    required this.registeredModels,
    required this.initialExternalRegistrationId,
  });

  final List<AsrRegisteredResourceOption> registeredModels;
  final String initialExternalRegistrationId;

  @override
  State<_AsrExternalModelDialog> createState() =>
      _AsrExternalModelDialogState();
}

class _AsrExternalModelDialogState extends State<_AsrExternalModelDialog> {
  late String _externalRegistrationId;

  @override
  void initState() {
    super.initState();
    _externalRegistrationId =
        widget.registeredModels.any(
          (item) => item.id == widget.initialExternalRegistrationId,
        )
        ? widget.initialExternalRegistrationId
        : widget.registeredModels.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final registeredLabels = {
      for (final item in widget.registeredModels)
        item.id: item.effectiveLabel.trim().isEmpty
            ? item.resourceId
            : item.effectiveLabel,
    };
    return AlertDialog(
      title: const Text('使用本地 Whisper 模型'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('选择已验证的模型，或登记其他模型文件夹。'),
            const SizedBox(height: T.s12),
            _AsrSelect(
              label: '已登记模型',
              value: _externalRegistrationId,
              items: registeredLabels,
              onChanged: (value) =>
                  setState(() => _externalRegistrationId = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('asr-external-choice-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton.icon(
          key: const ValueKey('asr-external-choice-browse'),
          onPressed: () =>
              Navigator.of(context).pop(const _AsrExternalModelChoice.browse()),
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: const Text('选择其他文件夹'),
        ),
        TextButton(
          key: const ValueKey('asr-external-choice-confirm'),
          onPressed: () => Navigator.of(
            context,
          ).pop(_AsrExternalModelChoice.registered(_externalRegistrationId)),
          child: const Text('使用此模型'),
        ),
      ],
    );
  }
}

class _AsrStatusChip extends StatelessWidget {
  const _AsrStatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: T.s4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: color.withValues(alpha: 0.52)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: T.s4),
          Text(
            label,
            style: T.tCaption.copyWith(color: color, fontWeight: T.wBold),
          ),
        ],
      ),
    );
  }
}

class _AsrModelRenameDialog extends StatefulWidget {
  const _AsrModelRenameDialog({
    required this.initialValue,
    required this.automaticLabel,
  });

  final String initialValue;
  final String automaticLabel;

  @override
  State<_AsrModelRenameDialog> createState() => _AsrModelRenameDialogState();
}

class _AsrModelRenameDialogState extends State<_AsrModelRenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue.trim(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改模型显示名称'),
      content: SizedBox(
        width: 360,
        child: TextField(
          key: const ValueKey('asr-model-user-label-input'),
          controller: _controller,
          autofocus: true,
          maxLength: 80,
          decoration: InputDecoration(
            labelText: '显示名称',
            hintText: widget.automaticLabel,
            helperText: '留空使用自动名称，不会改动模型文件夹。',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          key: const ValueKey('asr-model-user-label-save'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _AsrManagedModelChoice extends StatelessWidget {
  const _AsrManagedModelChoice({
    super.key,
    required this.label,
    required this.detail,
    required this.selected,
    required this.current,
    required this.onTap,
  });

  final String label;
  final String detail;
  final bool selected;
  final bool current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? T.accentSoft.withValues(alpha: 0.52) : T.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rSm),
          side: BorderSide(color: selected ? T.accent : T.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(T.rSm),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(T.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: T.tBody.copyWith(fontWeight: T.wBold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: selected ? T.accentStrong : T.muted,
                    ),
                  ],
                ),
                const SizedBox(height: T.s4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        detail,
                        style: T.tCaption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (current) ...[
                      const SizedBox(width: T.s4),
                      const _AsrInlineTag(label: '当前', color: T.ok),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AsrExternalModelChoiceRow extends StatelessWidget {
  const _AsrExternalModelChoiceRow({
    super.key,
    required this.title,
    required this.detail,
    required this.selected,
    required this.current,
    required this.onTap,
    this.onOpen,
    this.onRename,
  });

  final String title;
  final String detail;
  final bool selected;
  final bool current;
  final VoidCallback? onTap;
  final VoidCallback? onOpen;
  final VoidCallback? onRename;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? T.accentSoft.withValues(alpha: 0.44) : T.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rSm),
          side: BorderSide(color: selected ? T.accent : T.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(T.rSm),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: T.s12,
              vertical: T.s8,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.folder_open_rounded,
                  size: 20,
                  color: selected ? T.accentStrong : T.muted,
                ),
                const SizedBox(width: T.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: T.tBody.copyWith(fontWeight: T.wBold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: T.tCaption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (current) ...[
                  const SizedBox(width: T.s8),
                  const _AsrInlineTag(label: '当前', color: T.ok),
                ],
                if (onOpen != null)
                  IconButton(
                    key: const ValueKey('asr-model-open-location'),
                    tooltip: '打开模型文件夹',
                    onPressed: onOpen,
                    icon: const Icon(Icons.folder_outlined, size: 18),
                  ),
                if (onRename != null)
                  IconButton(
                    key: const ValueKey('asr-model-rename'),
                    tooltip: '修改显示名称',
                    onPressed: onRename,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                  ),
                const SizedBox(width: T.s4),
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.chevron_right_rounded,
                  size: 19,
                  color: selected ? T.accentStrong : T.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AsrInlineTag extends StatelessWidget {
  const _AsrInlineTag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(T.rSm),
      ),
      child: Text(
        label,
        style: T.tCaption.copyWith(color: color, fontWeight: T.wBold),
      ),
    );
  }
}

class _AsrSetupProgress extends StatelessWidget {
  const _AsrSetupProgress({required this.operation, this.onCancel});

  final AsrOperationStatus operation;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final progress = operation.progress;
    final title = _asrSetupTaskTitle(operation);
    final color = operation.state == 'failed'
        ? T.danger
        : operation.state == 'cancelled'
        ? T.warn
        : operation.state == 'completed'
        ? T.ok
        : T.accentStrong;
    return Semantics(
      label: title,
      value: progress == null ? '' : '${(progress * 100).round()}%',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(T.s16),
        decoration: BoxDecoration(
          color: T.surface,
          borderRadius: BorderRadius.circular(T.rMd),
          border: Border.all(color: color.withValues(alpha: 0.52)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.downloading_rounded, color: color, size: 22),
                const SizedBox(width: T.s8),
                Expanded(
                  child: Text(
                    title,
                    style: T.tSection,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onCancel != null)
                  ActionButton(
                    label: operation.state == 'cancelling' ? '正在取消…' : '取消下载',
                    onTap: operation.state == 'cancelling' ? null : onCancel,
                  ),
              ],
            ),
            if (operation.kind == 'setup') ...[
              const SizedBox(height: T.s16),
              _AsrSetupPhaseStrip(operation: operation),
            ],
            const SizedBox(height: T.s16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 8,
                value: progress,
                backgroundColor: T.line,
                color: color,
              ),
            ),
            const SizedBox(height: T.s8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _asrSetupPhaseLabel(operation),
                    style: T.tCaption,
                  ),
                ),
                if (operation.bytesTotal > 0)
                  Text(
                    '${_formatBytes(operation.bytesDone)} / ${_formatBytes(operation.bytesTotal)}',
                    style: T.tCaption,
                  ),
              ],
            ),
            if (operation.active) ...[
              const SizedBox(height: T.s12),
              Text('关闭此窗口后任务会继续，可从系统托盘重新打开。', style: T.tCaption),
            ] else if (operation.state == 'cancelled') ...[
              const SizedBox(height: T.s12),
              Text('下载已取消；已校验的部分会保留，继续下载时自动复用。', style: T.tBody),
            ] else if (operation.state == 'failed') ...[
              const SizedBox(height: T.s12),
              Text(
                _asrOperationFailureMessage(operation),
                style: T.tBody.copyWith(color: T.danger),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AsrBackgroundOperation extends StatelessWidget {
  const _AsrBackgroundOperation({
    required this.operation,
    required this.onCancel,
  });

  final AsrOperationStatus operation;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final progress = operation.progress;
    return Container(
      key: const ValueKey('asr-background-operation'),
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.accentSoft.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(T.rMd),
        border: Border.all(color: T.accent.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.downloading_rounded,
            size: 18,
            color: T.accentStrong,
          ),
          const SizedBox(width: T.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_asrSetupTaskTitle(operation)}，正在后台继续',
                  style: T.tCaption.copyWith(fontWeight: T.wBold),
                ),
                const SizedBox(height: T.s4),
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  color: T.accent,
                  backgroundColor: T.line,
                ),
              ],
            ),
          ),
          const SizedBox(width: T.s12),
          TextButton(
            onPressed: operation.state == 'cancelling' ? null : onCancel,
            child: Text(operation.state == 'cancelling' ? '正在取消' : '取消'),
          ),
        ],
      ),
    );
  }
}

class _AsrSetupPhaseStrip extends StatelessWidget {
  const _AsrSetupPhaseStrip({required this.operation});

  final AsrOperationStatus operation;

  @override
  Widget build(BuildContext context) {
    const labels = ['识别引擎', '识别模型', '检查可用性'];
    final completed = operation.state == 'completed';
    return Row(
      children: [
        for (var index = 0; index < labels.length; index++) ...[
          Expanded(
            child: _AsrSetupPhase(
              label: labels[index],
              index: index,
              currentIndex: operation.phaseIndex.clamp(0, labels.length - 1),
              completed: completed,
            ),
          ),
          if (index < labels.length - 1)
            Container(
              width: 24,
              height: 1,
              color: index < operation.phaseIndex || completed ? T.ok : T.line,
            ),
        ],
      ],
    );
  }
}

class _AsrSetupPhase extends StatelessWidget {
  const _AsrSetupPhase({
    required this.label,
    required this.index,
    required this.currentIndex,
    required this.completed,
  });

  final String label;
  final int index;
  final int currentIndex;
  final bool completed;

  @override
  Widget build(BuildContext context) {
    final done = completed || index < currentIndex;
    final current = !completed && index == currentIndex;
    final color = done
        ? T.ok
        : current
        ? T.accentStrong
        : T.muted;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done ? color : T.surface,
            border: Border.all(color: color, width: current ? 1.6 : 1),
          ),
          child: done
              ? const Icon(
                  Icons.check_rounded,
                  size: 13,
                  color: Color(0xFFFFFFFF),
                )
              : Text('${index + 1}', style: T.tCaption.copyWith(color: color)),
        ),
        const SizedBox(width: T.s4),
        Flexible(
          child: Text(
            label,
            style: T.tCaption.copyWith(
              color: current || done ? T.ink : T.muted,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

Color _asrStateColor(String state) {
  return switch (state) {
    'ready' => T.ok,
    'checking' => T.accentStrong,
    'needs_action' => T.warn,
    _ => T.danger,
  };
}

String _asrStatusChipLabel(AsrReadiness? readiness) {
  if (readiness?.code == 'credential_missing') return '缺少密钥';
  return switch (readiness?.state) {
    'ready' => '可以开始',
    'checking' => '检查中',
    'needs_action' => '还差一步',
    _ => '暂未准备',
  };
}

String _asrReadinessHint(AsrReadiness? readiness) {
  final value = readiness;
  if (value == null) return '正在读取本机识别状态。';
  if (value.code == 'credential_missing') {
    return '还未配置 API key，添加后才能设为默认并开始识别。';
  }
  return switch (value.state) {
    'ready' => '本地识别方案已准备好，可以开始处理视频。',
    'checking' => '正在检查运行环境和模型。',
    'needs_action' => '还差一步准备，完成后即可开始识别。',
    _ => value.statusLabel.isEmpty ? '当前方案还不能运行。' : value.statusLabel,
  };
}

String _asrOperationLabel(String itemId) {
  return switch (itemId) {
    'managed:faster-whisper' => '本地识别引擎',
    'small' => 'Whisper Small',
    'medium' => 'Whisper Medium',
    'large-v3' => 'Whisper Large v3',
    'nvidia-cuda12' => 'NVIDIA 加速环境',
    _ => itemId,
  };
}

String _asrSetupTaskTitle(AsrOperationStatus operation) {
  return switch (operation.state) {
    'queued' => '本机识别设置即将开始',
    'cancelling' => '正在取消本机识别设置',
    'completed' =>
      operation.kind == 'setup'
          ? '${_asrOperationLabel(operation.itemId)} 已准备好'
          : '${_asrOperationLabel(operation.itemId)}下载完成',
    'cancelled' => '本机识别下载已取消',
    'failed' => '本机识别设置需要处理',
    _ => switch (operation.phase) {
      'runtime' => '正在下载本地识别引擎',
      'model' => '正在下载 ${_asrOperationLabel(operation.itemId)}',
      'activate' => '正在检查本机识别可用性',
      _ => '正在下载 ${_asrOperationLabel(operation.itemId)}',
    },
  };
}

String _asrSetupPhaseLabel(AsrOperationStatus operation) {
  if (operation.state == 'cancelling') return '等待当前步骤安全停止';
  if (operation.state == 'completed') return '运行组件和模型已校验完成';
  if (operation.state == 'cancelled') return '可继续下载并复用已校验数据';
  if (operation.state == 'failed') return '保留安全断点，修复后可以重试';
  return switch (operation.phase) {
    'runtime' => '第 1 步，共 3 步 · 下载并校验识别引擎',
    'model' => '第 2 步，共 3 步 · 下载并校验识别模型',
    'activate' => '第 3 步，共 3 步 · 检查当前方案可用性',
    _ => '正在准备本机识别环境',
  };
}

String _asrOperationFailureMessage(AsrOperationStatus operation) {
  return switch (operation.errorCode) {
    'insufficient_disk_space' => '磁盘空间不足，请清理空间后重试。',
    'component_unpublished' => '当前版本的识别引擎尚未开放下载。',
    'checksum_mismatch' => '下载文件未通过完整性校验，请重试。',
    'download_failed' || 'download_incomplete' => '下载没有完成，请检查网络设置后重试。',
    'operation_interrupted' => '上次下载意外中断，可以从已保留的安全断点继续。',
    _ => operation.message.trim().isEmpty ? '本机识别设置失败，请重试。' : operation.message,
  };
}

class _WhisperBuddyPainter extends CustomPainter {
  const _WhisperBuddyPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(5, 9, 34, 29),
      const Radius.circular(11),
    );
    final fill = Paint()..color = T.accentSoft;
    final line = Paint()
      ..color = T.accentStrong
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(body, fill);
    canvas.drawRRect(body, line);
    final tail = Path()
      ..moveTo(12, 35)
      ..lineTo(9, 43)
      ..lineTo(19, 37)
      ..close();
    canvas.drawPath(tail, fill);
    canvas.drawPath(tail, line);

    final eye = Paint()..color = T.ink;
    canvas.drawCircle(const Offset(16, 23), 2.1, eye);
    canvas.drawCircle(const Offset(28, 23), 2.1, eye);
    final blush = Paint()..color = T.accent.withValues(alpha: 0.56);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(12.5, 28), width: 6, height: 3),
      blush,
    );
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(31.5, 28), width: 6, height: 3),
      blush,
    );
    final smile = Paint()
      ..color = T.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCenter(center: const Offset(22, 26.5), width: 8, height: 7),
      0.2,
      2.7,
      false,
      smile,
    );
    _drawSparkle(canvas, const Offset(40, 7), 4, T.accentStrong);
  }

  @override
  bool shouldRepaint(covariant _WhisperBuddyPainter oldDelegate) => false;
}

void _drawSparkle(Canvas canvas, Offset center, double radius, Color color) {
  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2
    ..strokeCap = StrokeCap.round;
  canvas.drawLine(
    Offset(center.dx, center.dy - radius),
    Offset(center.dx, center.dy + radius),
    paint,
  );
  canvas.drawLine(
    Offset(center.dx - radius, center.dy),
    Offset(center.dx + radius, center.dy),
    paint,
  );
}

String _asrModelLabel(String modelId) {
  return whisperModelLabel(modelId);
}

String _asrExternalModelLabel(String modelId) {
  if (modelId.startsWith('custom-')) return '自定义 Whisper';
  return _asrModelLabel(modelId);
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '大小未知';
  const gib = 1024 * 1024 * 1024;
  const mib = 1024 * 1024;
  const kib = 1024;
  if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(1)} GB';
  if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(0)} MB';
  if (bytes >= kib) return '${(bytes / kib).toStringAsFixed(0)} KB';
  return '$bytes B';
}
