part of '../result_review_workspace.dart';

class _ResultReviewBody extends StatelessWidget {
  const _ResultReviewBody({
    required this.result,
    required this.loading,
    required this.dirty,
    required this.saving,
    required this.reexporting,
    required this.selectedOutputFormat,
    required this.selectedBilingual,
    required this.selectedBilingualOrder,
    required this.selectedPreferSingleLine,
    required this.flowState,
    required this.flowMessage,
    required this.failedAction,
    required this.filter,
    required this.selectedSegmentId,
    required this.searchController,
    required this.segmentScrollController,
    required this.draftFor,
    required this.focusNodeFor,
    required this.keyFor,
    required this.expandedTimingSegmentIds,
    required this.onRefresh,
    required this.onSave,
    required this.onOutputFormatChanged,
    required this.onBilingualChanged,
    required this.onBilingualOrderChanged,
    required this.onPreferSingleLineChanged,
    required this.onFilterChanged,
    required this.onClearSearch,
    required this.onDiscardEdits,
    required this.onRestoreSegment,
    required this.onSelectSegment,
    required this.onToggleTiming,
    required this.onNudgeTiming,
    required this.onNormalizeTiming,
    required this.onPreviousIssue,
    required this.onNextIssue,
    required this.onReexport,
  });

  final TaskResultWorkspace result;
  final bool loading;
  final bool dirty;
  final bool saving;
  final bool reexporting;
  final String selectedOutputFormat;
  final bool selectedBilingual;
  final String selectedBilingualOrder;
  final bool selectedPreferSingleLine;
  final _ReviewFlowState flowState;
  final String flowMessage;
  final _FailedReviewAction? failedAction;
  final _SegmentFilter filter;
  final int? selectedSegmentId;
  final TextEditingController searchController;
  final ScrollController segmentScrollController;
  final _SegmentDraft Function(ResultSegment segment) draftFor;
  final FocusNode Function(ResultSegment segment) focusNodeFor;
  final GlobalKey Function(ResultSegment segment) keyFor;
  final Set<int> expandedTimingSegmentIds;
  final VoidCallback onRefresh;
  final Future<TaskResultWorkspace?> Function() onSave;
  final ValueChanged<String> onOutputFormatChanged;
  final ValueChanged<bool> onBilingualChanged;
  final ValueChanged<String> onBilingualOrderChanged;
  final ValueChanged<bool> onPreferSingleLineChanged;
  final ValueChanged<_SegmentFilter> onFilterChanged;
  final VoidCallback onClearSearch;
  final VoidCallback onDiscardEdits;
  final ValueChanged<ResultSegment> onRestoreSegment;
  final ValueChanged<ResultSegment> onSelectSegment;
  final ValueChanged<ResultSegment> onToggleTiming;
  final void Function(
    ResultSegment segment,
    _TimingField field,
    int milliseconds,
  )
  onNudgeTiming;
  final void Function(ResultSegment segment, _TimingField field)
  onNormalizeTiming;
  final VoidCallback onPreviousIssue;
  final VoidCallback onNextIssue;
  final VoidCallback onReexport;

  @override
  Widget build(BuildContext context) {
    final segments = result.segments;
    final searchQuery = searchController.text;
    final filteredSegments = segments
        .where((segment) => _matchesFilter(segment, filter, draftFor))
        .where((segment) => _matchesSearch(segment, searchQuery, draftFor))
        .toList();
    final issueSegments = segments
        .where(
          (segment) =>
              segment.issues.isNotEmpty || segment.qualityIssues.isNotEmpty,
        )
        .toList(growable: false);
    final selectedIssueIndex = issueSegments.indexWhere(
      (segment) => segment.id == selectedSegmentId,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ResultHeader(
          result: result,
          loading: loading,
          dirty: dirty,
          saving: saving,
          reexporting: reexporting,
          selectedOutputFormat: selectedOutputFormat,
          selectedBilingual: selectedBilingual,
          selectedBilingualOrder: selectedBilingualOrder,
          selectedPreferSingleLine: selectedPreferSingleLine,
          flowState: flowState,
          flowMessage: flowMessage,
          failedAction: failedAction,
          filter: filter,
          searchController: searchController,
          issueCount: issueSegments.length,
          selectedIssueIndex: selectedIssueIndex,
          onRefresh: onRefresh,
          onSave: onSave,
          onOutputFormatChanged: onOutputFormatChanged,
          onBilingualChanged: onBilingualChanged,
          onBilingualOrderChanged: onBilingualOrderChanged,
          onPreferSingleLineChanged: onPreferSingleLineChanged,
          onFilterChanged: onFilterChanged,
          onClearSearch: onClearSearch,
          onDiscardEdits: onDiscardEdits,
          onPreviousIssue: onPreviousIssue,
          onNextIssue: onNextIssue,
          onReexport: onReexport,
        ),
        const SizedBox(height: T.s16),
        Expanded(
          child: segments.isEmpty
              ? const Center(child: Text('结果里没有字幕片段。', style: T.tBody))
              : filteredSegments.isEmpty
              ? Center(
                  child: Text(
                    _emptyFilterText(filter, searchQuery),
                    style: T.tBody,
                  ),
                )
              : ListView.separated(
                  controller: segmentScrollController,
                  padding: EdgeInsets.zero,
                  itemCount: filteredSegments.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: T.s24, color: T.line),
                  itemBuilder: (context, index) => _SegmentRow(
                    key: keyFor(filteredSegments[index]),
                    segment: filteredSegments[index],
                    draft: draftFor(filteredSegments[index]),
                    focusNode: focusNodeFor(filteredSegments[index]),
                    selected: filteredSegments[index].id == selectedSegmentId,
                    timingExpanded: expandedTimingSegmentIds.contains(
                      filteredSegments[index].id,
                    ),
                    enabled: !saving && !reexporting,
                    onSelect: () => onSelectSegment(filteredSegments[index]),
                    onRestore: () => onRestoreSegment(filteredSegments[index]),
                    onToggleTiming: () =>
                        onToggleTiming(filteredSegments[index]),
                    onNudgeTiming: (field, milliseconds) => onNudgeTiming(
                      filteredSegments[index],
                      field,
                      milliseconds,
                    ),
                    onNormalizeTiming: (field) =>
                        onNormalizeTiming(filteredSegments[index], field),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ResultHeader extends StatelessWidget {
  const _ResultHeader({
    required this.result,
    required this.loading,
    required this.dirty,
    required this.saving,
    required this.reexporting,
    required this.selectedOutputFormat,
    required this.selectedBilingual,
    required this.selectedBilingualOrder,
    required this.selectedPreferSingleLine,
    required this.flowState,
    required this.flowMessage,
    required this.failedAction,
    required this.filter,
    required this.searchController,
    required this.issueCount,
    required this.selectedIssueIndex,
    required this.onRefresh,
    required this.onSave,
    required this.onOutputFormatChanged,
    required this.onBilingualChanged,
    required this.onBilingualOrderChanged,
    required this.onPreferSingleLineChanged,
    required this.onFilterChanged,
    required this.onClearSearch,
    required this.onDiscardEdits,
    required this.onPreviousIssue,
    required this.onNextIssue,
    required this.onReexport,
  });

  final TaskResultWorkspace result;
  final bool loading;
  final bool dirty;
  final bool saving;
  final bool reexporting;
  final String selectedOutputFormat;
  final bool selectedBilingual;
  final String selectedBilingualOrder;
  final bool selectedPreferSingleLine;
  final _ReviewFlowState flowState;
  final String flowMessage;
  final _FailedReviewAction? failedAction;
  final _SegmentFilter filter;
  final TextEditingController searchController;
  final int issueCount;
  final int selectedIssueIndex;
  final VoidCallback onRefresh;
  final Future<TaskResultWorkspace?> Function() onSave;
  final ValueChanged<String> onOutputFormatChanged;
  final ValueChanged<bool> onBilingualChanged;
  final ValueChanged<String> onBilingualOrderChanged;
  final ValueChanged<bool> onPreferSingleLineChanged;
  final ValueChanged<_SegmentFilter> onFilterChanged;
  final VoidCallback onClearSearch;
  final VoidCallback onDiscardEdits;
  final VoidCallback onPreviousIssue;
  final VoidCallback onNextIssue;
  final VoidCallback onReexport;

  @override
  Widget build(BuildContext context) {
    final task = result.task;
    final filename = _basename(task.inputFile);
    final formats = subtitleFormatListLabel(result.outputPaths.keys);
    final refreshEnabled =
        flowState == _ReviewFlowState.synced ||
        flowState == _ReviewFlowState.exported;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Tooltip(
                    message: fileTooltipLabel(
                      task.inputFile,
                      fallbackName: filename,
                    ),
                    child: Text(
                      filename.isEmpty ? _shortTaskId(task.taskId) : filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.tFilename,
                    ),
                  ),
                  const SizedBox(height: T.s8),
                  Text(
                    '源语 ${languageLabel(task.sourceLang)} · 目标 ${languageLabel(task.targetLang)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: T.tCaption,
                  ),
                ],
              ),
            ),
            Wrap(
              spacing: T.s8,
              runSpacing: T.s8,
              alignment: WrapAlignment.end,
              children: [
                _ReviewButton(
                  label: loading ? '刷新中' : '刷新',
                  icon: Icons.refresh,
                  onTap: onRefresh,
                  enabled:
                      refreshEnabled && !loading && !saving && !reexporting,
                ),
                _ReviewButton(
                  label: saving ? '保存中' : '保存修改',
                  icon: Icons.save_outlined,
                  onTap: () => unawaited(onSave()),
                  enabled: dirty && !saving && !reexporting,
                ),
                _ReviewButton(
                  label: '放弃修改',
                  icon: Icons.undo,
                  onTap: onDiscardEdits,
                  enabled: dirty && !saving && !reexporting,
                ),
                _ReviewButton(
                  label: reexporting ? '导出中' : '重新导出',
                  icon: Icons.ios_share,
                  onTap: onReexport,
                  enabled: !saving && !reexporting,
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: T.s12),
        _ReviewStatusStrip(
          state: flowState,
          message: flowMessage,
          failedAction: failedAction,
          onRetryRefresh: onRefresh,
          onRetrySave: () => unawaited(onSave()),
          onRetryExport: onReexport,
        ),
        const SizedBox(height: T.s16),
        _ResultSummaryLine(
          segmentCount: result.segments.length,
          issueCount: result.issueCount,
          formats: formats,
        ),
        const SizedBox(height: T.s12),
        _ExportControls(
          selectedOutputFormat: selectedOutputFormat,
          selectedBilingual: selectedBilingual,
          selectedBilingualOrder: selectedBilingualOrder,
          selectedPreferSingleLine: selectedPreferSingleLine,
          enabled: !saving && !reexporting,
          onOutputFormatChanged: onOutputFormatChanged,
          onBilingualChanged: onBilingualChanged,
          onBilingualOrderChanged: onBilingualOrderChanged,
          onPreferSingleLineChanged: onPreferSingleLineChanged,
        ),
        const SizedBox(height: T.s8),
        _ExportReview(
          result: result,
          selectedOutputFormat: selectedOutputFormat,
          selectedBilingual: selectedBilingual,
          selectedBilingualOrder: selectedBilingualOrder,
          selectedPreferSingleLine: selectedPreferSingleLine,
        ),
        const SizedBox(height: T.s8),
        _FilterControls(
          selected: filter,
          searchController: searchController,
          enabled: !saving && !reexporting,
          issueCount: issueCount,
          selectedIssueIndex: selectedIssueIndex,
          onChanged: onFilterChanged,
          onClearSearch: onClearSearch,
          onPreviousIssue: onPreviousIssue,
          onNextIssue: onNextIssue,
        ),
      ],
    );
  }
}

class _ReviewStatusStrip extends StatelessWidget {
  const _ReviewStatusStrip({
    required this.state,
    required this.message,
    required this.failedAction,
    required this.onRetryRefresh,
    required this.onRetrySave,
    required this.onRetryExport,
  });

  final _ReviewFlowState state;
  final String message;
  final _FailedReviewAction? failedAction;
  final VoidCallback onRetryRefresh;
  final VoidCallback onRetrySave;
  final VoidCallback onRetryExport;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      _ReviewFlowState.dirty || _ReviewFlowState.savedPendingExport => T.warn,
      _ReviewFlowState.exported => T.ok,
      _ReviewFlowState.invalid || _ReviewFlowState.failed => T.danger,
      _ => T.sky,
    };
    final icon = switch (state) {
      _ReviewFlowState.synced => Icons.check_circle_outline_rounded,
      _ReviewFlowState.dirty => Icons.edit_note_rounded,
      _ReviewFlowState.invalid => Icons.schedule_rounded,
      _ReviewFlowState.saving => Icons.sync_rounded,
      _ReviewFlowState.savedPendingExport => Icons.inventory_2_outlined,
      _ReviewFlowState.exporting => Icons.ios_share_rounded,
      _ReviewFlowState.exported => Icons.task_alt_rounded,
      _ReviewFlowState.failed => Icons.error_outline_rounded,
    };
    final retry = switch (failedAction) {
      _FailedReviewAction.refresh => (label: '重试读取', callback: onRetryRefresh),
      _FailedReviewAction.save => (label: '重试保存', callback: onRetrySave),
      _FailedReviewAction.reexport => (label: '重试导出', callback: onRetryExport),
      null => null,
    };
    return Stack(
      clipBehavior: Clip.none,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(
            horizontal: T.s12,
            vertical: T.s8,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(color: color.withValues(alpha: 0.58)),
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 24,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: T.s8),
              Icon(icon, size: 17, color: color),
              const SizedBox(width: T.s8),
              Expanded(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption.copyWith(
                    color: T.ink,
                    fontWeight: T.wMedium,
                  ),
                ),
              ),
              if (retry != null) ...[
                const SizedBox(width: T.s8),
                _MiniActionButton(
                  label: retry.label,
                  icon: Icons.refresh_rounded,
                  onTap: retry.callback,
                ),
              ],
            ],
          ),
        ),
        if (state == _ReviewFlowState.savedPendingExport)
          Positioned(
            top: -3,
            right: T.s24,
            child: IgnorePointer(
              child: Container(
                width: 42,
                height: 7,
                decoration: BoxDecoration(
                  color: T.skySoft,
                  border: Border.all(color: T.sky.withValues(alpha: 0.38)),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SegmentRow extends StatelessWidget {
  const _SegmentRow({
    super.key,
    required this.segment,
    required this.draft,
    required this.focusNode,
    required this.selected,
    required this.timingExpanded,
    required this.enabled,
    required this.onSelect,
    required this.onRestore,
    required this.onToggleTiming,
    required this.onNudgeTiming,
    required this.onNormalizeTiming,
  });

  final ResultSegment segment;
  final _SegmentDraft draft;
  final FocusNode focusNode;
  final bool selected;
  final bool timingExpanded;
  final bool enabled;
  final VoidCallback onSelect;
  final VoidCallback onRestore;
  final VoidCallback onToggleTiming;
  final void Function(_TimingField field, int milliseconds) onNudgeTiming;
  final ValueChanged<_TimingField> onNormalizeTiming;

  @override
  Widget build(BuildContext context) {
    final issueLabels = <String>{
      ...segment.issues,
      for (final issue in segment.qualityIssues) _qualityIssueLabel(issue),
    }.toList(growable: false);
    final engine = [
      segment.provider,
      segment.model,
    ].where((part) => part.trim().isNotEmpty).join(' · ');
    return AnimatedBuilder(
      animation: draft.listenable,
      builder: (context, _) {
        final timing = _timingDraftValues(draft);
        final modified = draft.isModified(segment);
        final timingModified = draft.hasTimingChanges(segment);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.fromLTRB(T.s8, T.s8, T.s8, T.s8),
          decoration: BoxDecoration(
            color: selected
                ? T.warn.withValues(alpha: 0.08)
                : const Color(0x00000000),
            border: Border(
              left: BorderSide(
                color: selected ? T.warn : const Color(0x00000000),
                width: 3,
              ),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (selected) ...[
                          const Icon(
                            Icons.bookmark_rounded,
                            size: 14,
                            color: T.warn,
                          ),
                          const SizedBox(width: T.s4),
                        ],
                        Expanded(
                          child: Text('#${segment.id}', style: T.tSection),
                        ),
                        _CompactIconButton(
                          tooltip: timingExpanded ? '收起时间码' : '编辑时间码',
                          icon: timingExpanded
                              ? Icons.schedule_rounded
                              : Icons.more_time_rounded,
                          onTap: enabled ? onToggleTiming : null,
                        ),
                      ],
                    ),
                    Text(
                      '${draft.startController.text}\n${draft.endController.text}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: T.tCaption.copyWith(
                        color: timing.message != null
                            ? T.danger
                            : timingModified
                            ? T.accentStrong
                            : T.muted,
                        fontWeight: timingModified ? T.wMedium : T.wRegular,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: T.s16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (segment.sourceText.isNotEmpty) ...[
                      Text(
                        segment.sourceText,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: T.tBody,
                      ),
                      const SizedBox(height: T.s8),
                    ],
                    if (timingExpanded) ...[
                      _TimingEditor(
                        segmentId: segment.id,
                        draft: draft,
                        timing: timing,
                        enabled: enabled,
                        onTap: onSelect,
                        onNudge: onNudgeTiming,
                        onNormalize: onNormalizeTiming,
                      ),
                      const SizedBox(height: T.s8),
                    ],
                    TextField(
                      controller: draft.targetController,
                      focusNode: focusNode,
                      onTap: onSelect,
                      enabled: enabled,
                      minLines: 1,
                      maxLines: 4,
                      style: T.tBody.copyWith(fontWeight: T.wMedium),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '输入译文',
                        filled: true,
                        fillColor: T.surface,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: T.s12,
                          vertical: T.s8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(T.rSm),
                          borderSide: const BorderSide(color: T.line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(T.rSm),
                          borderSide: const BorderSide(color: T.line),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(T.rSm),
                          borderSide: const BorderSide(
                            color: T.accentStrong,
                            width: 1.4,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: T.s8),
                    Wrap(
                      spacing: T.s8,
                      runSpacing: T.s4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (modified)
                          _MiniActionButton(
                            label: '还原片段',
                            icon: Icons.undo,
                            onTap: enabled ? onRestore : null,
                          ),
                        if (engine.isNotEmpty) _SoftLabel(label: engine),
                        for (final issue in issueLabels.take(3))
                          _SoftLabel(label: issue, warning: true),
                        if (issueLabels.length > 3)
                          _SoftLabel(label: '+${issueLabels.length - 3}'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TimingEditor extends StatelessWidget {
  const _TimingEditor({
    required this.segmentId,
    required this.draft,
    required this.timing,
    required this.enabled,
    required this.onTap,
    required this.onNudge,
    required this.onNormalize,
  });

  final int segmentId;
  final _SegmentDraft draft;
  final _TimingDraftValues timing;
  final bool enabled;
  final VoidCallback onTap;
  final void Function(_TimingField field, int milliseconds) onNudge;
  final ValueChanged<_TimingField> onNormalize;

  @override
  Widget build(BuildContext context) {
    final hasError = timing.message != null;
    final color = hasError ? T.danger : T.sky;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: T.s8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: hasError ? 0.06 : 0.08),
        border: Border(
          left: BorderSide(color: color, width: 2),
          top: BorderSide(color: color.withValues(alpha: 0.3)),
          bottom: BorderSide(color: color.withValues(alpha: 0.3)),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final groupWidth = constraints.maxWidth >= 468
              ? (constraints.maxWidth - T.s12) / 2
              : constraints.maxWidth;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: T.s12,
                runSpacing: T.s8,
                children: [
                  SizedBox(
                    width: groupWidth,
                    child: _TimecodeGroup(
                      fieldKey: ValueKey('result-time-start-$segmentId'),
                      label: '开始',
                      controller: draft.startController,
                      enabled: enabled,
                      hasError: timing.errorField == _TimingField.start,
                      onTap: onTap,
                      onDecrease: () => onNudge(_TimingField.start, -100),
                      onIncrease: () => onNudge(_TimingField.start, 100),
                      onNormalize: () => onNormalize(_TimingField.start),
                    ),
                  ),
                  SizedBox(
                    width: groupWidth,
                    child: _TimecodeGroup(
                      fieldKey: ValueKey('result-time-end-$segmentId'),
                      label: '结束',
                      controller: draft.endController,
                      enabled: enabled,
                      hasError: timing.errorField == _TimingField.end,
                      onTap: onTap,
                      onDecrease: () => onNudge(_TimingField.end, -100),
                      onIncrease: () => onNudge(_TimingField.end, 100),
                      onNormalize: () => onNormalize(_TimingField.end),
                    ),
                  ),
                ],
              ),
              if (timing.message != null) ...[
                const SizedBox(height: T.s4),
                Row(
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      size: 14,
                      color: T.danger,
                    ),
                    const SizedBox(width: T.s4),
                    Expanded(
                      child: Text(
                        timing.message!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: T.tCaption.copyWith(
                          color: T.danger,
                          fontWeight: T.wMedium,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _TimecodeGroup extends StatelessWidget {
  const _TimecodeGroup({
    required this.fieldKey,
    required this.label,
    required this.controller,
    required this.enabled,
    required this.hasError,
    required this.onTap,
    required this.onDecrease,
    required this.onIncrease,
    required this.onNormalize,
  });

  final Key fieldKey;
  final String label;
  final TextEditingController controller;
  final bool enabled;
  final bool hasError;
  final VoidCallback onTap;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final VoidCallback onNormalize;

  @override
  Widget build(BuildContext context) {
    final borderColor = hasError ? T.danger : T.line;
    return Row(
      children: [
        SizedBox(
          width: 34,
          child: Text(label, style: T.tCaption.copyWith(color: T.ink)),
        ),
        Expanded(
          child: SizedBox(
            height: 34,
            child: TextField(
              key: fieldKey,
              controller: controller,
              enabled: enabled,
              onTap: onTap,
              onEditingComplete: () {
                onNormalize();
                FocusScope.of(context).unfocus();
              },
              keyboardType: TextInputType.datetime,
              textInputAction: TextInputAction.done,
              textAlign: TextAlign.center,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9:.,-]')),
                LengthLimitingTextInputFormatter(13),
              ],
              style: T.tCaption.copyWith(
                color: T.ink,
                fontWeight: T.wMedium,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: T.surface,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: T.s8,
                  vertical: T.s8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(T.rSm),
                  borderSide: BorderSide(color: borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(T.rSm),
                  borderSide: BorderSide(color: borderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(T.rSm),
                  borderSide: BorderSide(
                    color: hasError ? T.danger : T.accentStrong,
                    width: 1.4,
                  ),
                ),
              ),
            ),
          ),
        ),
        _CompactIconButton(
          tooltip: '$label提前 0.1 秒',
          icon: Icons.remove_rounded,
          onTap: enabled ? onDecrease : null,
        ),
        _CompactIconButton(
          tooltip: '$label延后 0.1 秒',
          icon: Icons.add_rounded,
          onTap: enabled ? onIncrease : null,
        ),
      ],
    );
  }
}

class _ExportControls extends StatelessWidget {
  const _ExportControls({
    required this.selectedOutputFormat,
    required this.selectedBilingual,
    required this.selectedBilingualOrder,
    required this.selectedPreferSingleLine,
    required this.enabled,
    required this.onOutputFormatChanged,
    required this.onBilingualChanged,
    required this.onBilingualOrderChanged,
    required this.onPreferSingleLineChanged,
  });

  final String selectedOutputFormat;
  final bool selectedBilingual;
  final String selectedBilingualOrder;
  final bool selectedPreferSingleLine;
  final bool enabled;
  final ValueChanged<String> onOutputFormatChanged;
  final ValueChanged<bool> onBilingualChanged;
  final ValueChanged<String> onBilingualOrderChanged;
  final ValueChanged<bool> onPreferSingleLineChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: T.s16,
      runSpacing: T.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _ExportFormatSelector(
          selected: selectedOutputFormat,
          enabled: enabled,
          onChanged: onOutputFormatChanged,
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('双语字幕', style: T.tCaption),
            const SizedBox(width: T.s4),
            Switch(
              value: selectedBilingual,
              onChanged: enabled ? onBilingualChanged : null,
              activeThumbColor: T.accentStrong,
            ),
          ],
        ),
        if (selectedBilingual)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('双语顺序', style: T.tCaption),
              const SizedBox(width: T.s8),
              SegmentedButton<String>(
                showSelectedIcon: false,
                selected: {selectedBilingualOrder},
                segments: const [
                  ButtonSegment(value: 'target_source', label: Text('译文在前')),
                  ButtonSegment(value: 'source_target', label: Text('源文在前')),
                ],
                onSelectionChanged: enabled
                    ? (selection) {
                        final next = selection.isEmpty ? null : selection.first;
                        if (next != null) onBilingualOrderChanged(next);
                      }
                    : null,
                style: _compactSegmentedStyle(),
              ),
            ],
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('尽量单行', style: T.tCaption),
            const SizedBox(width: T.s4),
            Switch(
              value: selectedPreferSingleLine,
              onChanged: enabled ? onPreferSingleLineChanged : null,
              activeThumbColor: T.accentStrong,
            ),
          ],
        ),
      ],
    );
  }
}

class _ExportFormatSelector extends StatelessWidget {
  const _ExportFormatSelector({
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final String selected;
  final bool enabled;
  final ValueChanged<String> onChanged;

  static const _primarySegments = [
    ButtonSegment(value: 'srt', label: Text('SRT')),
    ButtonSegment(value: 'ass', label: Text('ASS')),
    ButtonSegment(value: 'both', label: Text('SRT+ASS')),
  ];
  static const _secondarySegments = [
    ButtonSegment(value: 'vtt', label: Text('VTT')),
    ButtonSegment(value: 'lrc', label: Text('LRC')),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 680) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('导出格式', style: T.tCaption),
              const SizedBox(width: T.s8),
              _selector([..._primarySegments, ..._secondarySegments]),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('导出格式', style: T.tCaption),
            const SizedBox(height: T.s4),
            Wrap(
              spacing: T.s8,
              runSpacing: T.s4,
              children: [
                _selector(_primarySegments),
                _selector(_secondarySegments),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _selector(List<ButtonSegment<String>> segments) {
    final values = segments.map((segment) => segment.value).toSet();
    return SegmentedButton<String>(
      showSelectedIcon: false,
      emptySelectionAllowed: true,
      selected: values.contains(selected) ? {selected} : const <String>{},
      segments: segments,
      onSelectionChanged: enabled
          ? (selection) {
              final next = selection.isEmpty ? null : selection.first;
              if (next != null) onChanged(next);
            }
          : null,
      style: _compactSegmentedStyle(),
    );
  }
}

class _ExportReview extends StatelessWidget {
  const _ExportReview({
    required this.result,
    required this.selectedOutputFormat,
    required this.selectedBilingual,
    required this.selectedBilingualOrder,
    required this.selectedPreferSingleLine,
  });

  final TaskResultWorkspace result;
  final String selectedOutputFormat;
  final bool selectedBilingual;
  final String selectedBilingualOrder;
  final bool selectedPreferSingleLine;

  @override
  Widget build(BuildContext context) {
    final plannedFormats = _plannedExportFormats(selectedOutputFormat);
    final plannedLabel = subtitleFormatListLabel(plannedFormats);
    final outputEntries =
        result.outputPaths.entries
            .where((entry) => entry.value.trim().isNotEmpty)
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    return Wrap(
      spacing: T.s8,
      runSpacing: T.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('导出复核', style: T.tCaption),
        _SoftLabel(
          label:
              '将导出 ${plannedLabel.isEmpty ? '未知格式' : plannedLabel} · '
              '${selectedBilingual ? '双语字幕' : '单语字幕'} · '
              '${selectedBilingual ? '${_bilingualOrderLabel(selectedBilingualOrder)} · ' : ''}'
              '${selectedPreferSingleLine ? '尽量单行' : '自然换行'}',
        ),
        if (outputEntries.isEmpty)
          const _SoftLabel(label: '已有输出 无记录')
        else
          for (final entry in outputEntries.take(3))
            _OutputPathLabel(format: entry.key, path: entry.value),
        if (outputEntries.length > 3)
          _SoftLabel(label: '+${outputEntries.length - 3}'),
      ],
    );
  }
}

class _OutputPathLabel extends StatelessWidget {
  const _OutputPathLabel({required this.format, required this.path});

  final String format;
  final String path;

  @override
  Widget build(BuildContext context) {
    final filename = _basename(path);
    final label = [
      '已有输出',
      subtitleFormatLabel(format),
      if (filename.isNotEmpty) compactMiddleLabel(filename, maxLength: 28),
    ].join(' ');
    return Tooltip(
      message: fileTooltipLabel(path, fallbackName: filename),
      child: _SoftLabel(label: label),
    );
  }
}

class _FilterControls extends StatelessWidget {
  const _FilterControls({
    required this.selected,
    required this.searchController,
    required this.enabled,
    required this.issueCount,
    required this.selectedIssueIndex,
    required this.onChanged,
    required this.onClearSearch,
    required this.onPreviousIssue,
    required this.onNextIssue,
  });

  final _SegmentFilter selected;
  final TextEditingController searchController;
  final bool enabled;
  final int issueCount;
  final int selectedIssueIndex;
  final ValueChanged<_SegmentFilter> onChanged;
  final VoidCallback onClearSearch;
  final VoidCallback onPreviousIssue;
  final VoidCallback onNextIssue;

  @override
  Widget build(BuildContext context) {
    final hasSearch = searchController.text.trim().isNotEmpty;
    return Wrap(
      spacing: T.s8,
      runSpacing: T.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('片段筛查', style: T.tCaption),
        SegmentedButton<_SegmentFilter>(
          showSelectedIcon: false,
          selected: {selected},
          segments: const [
            ButtonSegment(value: _SegmentFilter.all, label: Text('全部')),
            ButtonSegment(value: _SegmentFilter.issues, label: Text('有问题')),
            ButtonSegment(
              value: _SegmentFilter.emptyTarget,
              label: Text('空译文'),
            ),
            ButtonSegment(value: _SegmentFilter.modified, label: Text('已修改')),
          ],
          onSelectionChanged: enabled
              ? (selection) {
                  final next = selection.isEmpty ? null : selection.first;
                  if (next != null) onChanged(next);
                }
              : null,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) return T.muted;
              if (states.contains(WidgetState.selected)) return T.accentStrong;
              return T.ink;
            }),
            side: WidgetStateProperty.resolveWith((states) {
              final color = states.contains(WidgetState.selected)
                  ? T.accentStrong
                  : T.line;
              return BorderSide(color: color, width: 1.2);
            }),
          ),
        ),
        _IssueNavigator(
          issueCount: issueCount,
          selectedIssueIndex: selectedIssueIndex,
          enabled: enabled,
          onPrevious: onPreviousIssue,
          onNext: onNextIssue,
        ),
        SizedBox(
          width: 180,
          child: TextField(
            controller: searchController,
            enabled: enabled,
            minLines: 1,
            maxLines: 1,
            style: T.tCaption,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索源文或译文',
              prefixIcon: const Icon(Icons.search, size: 16),
              suffixIcon: hasSearch
                  ? IconButton(
                      tooltip: '清除搜索',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: enabled ? onClearSearch : null,
                    )
                  : null,
              filled: true,
              fillColor: T.surface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: T.s8,
                vertical: T.s8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(T.rSm),
                borderSide: const BorderSide(color: T.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(T.rSm),
                borderSide: const BorderSide(color: T.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(T.rSm),
                borderSide: const BorderSide(color: T.accentStrong, width: 1.4),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _IssueNavigator extends StatelessWidget {
  const _IssueNavigator({
    required this.issueCount,
    required this.selectedIssueIndex,
    required this.enabled,
    required this.onPrevious,
    required this.onNext,
  });

  final int issueCount;
  final int selectedIssueIndex;
  final bool enabled;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final canNavigate = enabled && issueCount > 0;
    final position = selectedIssueIndex >= 0
        ? '${selectedIssueIndex + 1} / $issueCount'
        : '$issueCount 条';
    return Container(
      height: 36,
      padding: const EdgeInsets.only(left: T.s8, right: 2),
      decoration: BoxDecoration(
        color: issueCount > 0 ? T.warn.withValues(alpha: 0.1) : T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(
          color: issueCount > 0 ? T.warn.withValues(alpha: 0.68) : T.line,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.rate_review_rounded,
            size: 15,
            color: issueCount > 0 ? T.warn : T.muted,
          ),
          const SizedBox(width: T.s4),
          SizedBox(
            width: 62,
            child: Text(
              '问题 $position',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: T.tCaption.copyWith(
                color: T.ink,
                fontWeight: issueCount > 0 ? T.wMedium : T.wRegular,
              ),
            ),
          ),
          _CompactIconButton(
            tooltip: '上一条问题',
            icon: Icons.keyboard_arrow_up_rounded,
            onTap: canNavigate ? onPrevious : null,
          ),
          _CompactIconButton(
            tooltip: '下一条问题',
            icon: Icons.keyboard_arrow_down_rounded,
            onTap: canNavigate ? onNext : null,
          ),
        ],
      ),
    );
  }
}

class _CompactIconButton extends StatelessWidget {
  const _CompactIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 17),
      color: T.accentStrong,
      disabledColor: T.muted.withValues(alpha: 0.56),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 28, height: 32),
      splashRadius: 16,
    );
  }
}

class _ResultSummaryLine extends StatelessWidget {
  const _ResultSummaryLine({
    required this.segmentCount,
    required this.issueCount,
    required this.formats,
  });

  final int segmentCount;
  final int issueCount;
  final String formats;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: T.s16,
      runSpacing: T.s4,
      children: [
        _SummaryValue(
          icon: Icons.subtitles_outlined,
          label: '$segmentCount 个片段',
        ),
        _SummaryValue(
          icon: Icons.rate_review_outlined,
          label: '$issueCount 条提示',
          color: issueCount > 0 ? T.warn : T.muted,
        ),
        _SummaryValue(
          icon: Icons.inventory_2_outlined,
          label: formats.isEmpty ? '暂无输出记录' : '已有 $formats',
          color: T.sky,
        ),
      ],
    );
  }
}

class _SummaryValue extends StatelessWidget {
  const _SummaryValue({
    required this.icon,
    required this.label,
    this.color = T.muted,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: T.s4),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: T.tCaption.copyWith(color: T.ink),
        ),
      ],
    );
  }
}

class _MiniActionButton extends StatefulWidget {
  const _MiniActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  State<_MiniActionButton> createState() => _MiniActionButtonState();
}

class _MiniActionButtonState extends State<_MiniActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final color = enabled ? T.accentStrong : T.muted;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (enabled) setState(() => _hover = true);
      },
      onExit: (_) {
        if (enabled) setState(() => _hover = false);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 3),
          decoration: BoxDecoration(
            color: _hover && enabled
                ? T.accentSoft
                : T.accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(color: color.withValues(alpha: 0.8)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 13, color: color),
              const SizedBox(width: T.s4),
              Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.tCaption.copyWith(color: T.ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SoftLabel extends StatelessWidget {
  const _SoftLabel({required this.label, this.warning = false});

  final String label;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final color = warning ? T.warn : T.sky;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: color.withValues(alpha: 0.8)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: T.tCaption.copyWith(color: T.ink),
      ),
    );
  }
}

class _EmptyResult extends StatelessWidget {
  const _EmptyResult({
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: T.tFilename, textAlign: TextAlign.center),
            const SizedBox(height: T.s8),
            Text(message, style: T.tBody, textAlign: TextAlign.center),
            const SizedBox(height: T.s16),
            _ReviewButton(label: actionLabel, onTap: onAction),
          ],
        ),
      ),
    );
  }
}

class _ReviewButton extends StatefulWidget {
  const _ReviewButton({
    required this.label,
    required this.onTap,
    this.icon,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool enabled;

  @override
  State<_ReviewButton> createState() => _ReviewButtonState();
}

class _ReviewButtonState extends State<_ReviewButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final foreground = enabled ? T.accentStrong : T.muted;
    final border = enabled ? T.accentStrong : T.line;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (enabled) setState(() => _hover = true);
      },
      onExit: (_) {
        if (enabled) setState(() => _hover = false);
      },
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: T.s16, vertical: 10),
          decoration: BoxDecoration(
            color: _hover && enabled ? T.accentSoft : const Color(0x00000000),
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(color: border, width: 1.4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 16, color: foreground),
                const SizedBox(width: T.s4),
              ],
              Text(
                widget.label,
                style: T.tBody.copyWith(color: foreground, fontWeight: T.wBold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _friendlyResultError(Object error) {
  if (error is RpcRemoteException) {
    final message = error.message.trim();
    if (message.isNotEmpty && RegExp(r'[\u3400-\u9fff]').hasMatch(message)) {
      return message;
    }
    return switch (error.code.trim().toLowerCase()) {
      'output_not_writable' => '字幕文件无法写入，请检查输出目录后重试。',
      'not_found' || 'task_not_found' => '这项任务的字幕结果已经不在原位置。',
      'invalid_request' => '字幕数据不完整，暂时无法完成这项操作。',
      'method_not_found' => '当前版本暂不支持这项结果操作。',
      _ => '字幕操作没有完成，请稍后重试。',
    };
  }
  return '字幕操作没有完成，请稍后重试。';
}

String _basename(String path) {
  if (path.trim().isEmpty) return '';
  return path.split(RegExp(r'[\\/]')).last;
}

String _shortTaskId(String taskId) {
  return shortTaskIdLabel(taskId);
}

String? _stringValue(Object? value) {
  if (value == null) return null;
  final text = '$value';
  return text.isEmpty ? null : text;
}

Map<String, Object?> _stringMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return const <String, Object?>{};
}

bool? _boolValue(Object? value) {
  if (value is bool) return value;
  return switch ('$value'.trim().toLowerCase()) {
    'true' || '1' || 'yes' || 'on' => true,
    'false' || '0' || 'no' || 'off' => false,
    _ => null,
  };
}

String? _normalizeBilingualOrder(String? value) {
  return switch (value?.trim().toLowerCase()) {
    'source_target' => 'source_target',
    'target_source' => 'target_source',
    _ => null,
  };
}

String _bilingualOrderLabel(String value) {
  return _normalizeBilingualOrder(value) == 'source_target' ? '源文在前' : '译文在前';
}

String _qualityIssueLabel(Map<String, Object?> issue) {
  for (final key in const ['hint_zh', 'message_zh', 'label_zh']) {
    final label = _stringValue(issue[key])?.trim();
    if (label != null && label.isNotEmpty) return label;
  }
  final code = (_stringValue(issue['code']) ?? '').trim().toLowerCase();
  final mapped = switch (code) {
    'duration_too_short' => '显示时间太短',
    'cps_too_high' || 'over_hard_cps' => '字幕阅读速度偏快',
    'too_many_lines' => '字幕行数过多',
    'line_too_wide' || 'line_too_long' => '字幕单行过长',
    'empty_target' => '译文为空',
    'invalid_timing' => '时间码区间无效',
    'overlap' || 'timeline_overlap' => '时间轴发生重叠',
    _ => '',
  };
  if (mapped.isNotEmpty) return mapped;
  for (final key in const ['message', 'hint']) {
    final label = _stringValue(issue[key])?.trim();
    if (label != null && RegExp(r'[\u3400-\u9fff]').hasMatch(label)) {
      return label;
    }
  }
  return '质量提示';
}

ButtonStyle _compactSegmentedStyle() {
  return ButtonStyle(
    visualDensity: VisualDensity.compact,
    foregroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return T.muted;
      if (states.contains(WidgetState.selected)) return T.accentStrong;
      return T.ink;
    }),
    side: WidgetStateProperty.resolveWith((states) {
      final color = states.contains(WidgetState.selected)
          ? T.accentStrong
          : T.line;
      return BorderSide(color: color, width: 1.2);
    }),
  );
}

String? _normalizeOutputFormat(String? value) {
  final normalized = value?.trim().toLowerCase();
  return switch (normalized) {
    'srt' || 'ass' || 'both' || 'vtt' || 'lrc' => normalized,
    'webvtt' => 'vtt',
    _ => null,
  };
}

List<String> _plannedExportFormats(String value) {
  return switch (_normalizeOutputFormat(value)) {
    'srt' => const ['srt'],
    'ass' => const ['ass'],
    'vtt' => const ['vtt'],
    'lrc' => const ['lrc'],
    'both' || null => const ['srt', 'ass'],
    _ => const ['srt', 'ass'],
  };
}

bool _matchesFilter(
  ResultSegment segment,
  _SegmentFilter filter,
  _SegmentDraft Function(ResultSegment segment) draftFor,
) {
  final draft = draftFor(segment);
  return switch (filter) {
    _SegmentFilter.all => true,
    _SegmentFilter.issues =>
      segment.issues.isNotEmpty || segment.qualityIssues.isNotEmpty,
    _SegmentFilter.emptyTarget =>
      draft.targetController.text.trim().isEmpty || draft.isModified(segment),
    _SegmentFilter.modified => draft.isModified(segment),
  };
}

bool _matchesSearch(
  ResultSegment segment,
  String query,
  _SegmentDraft Function(ResultSegment segment) draftFor,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return true;
  final draft = draftFor(segment);
  final haystack = [
    segment.sourceText,
    draft.targetController.text,
    draft.startController.text,
    draft.endController.text,
    segment.provider,
    segment.model,
    ...segment.issues,
    for (final issue in segment.qualityIssues) ..._issueSearchTerms(issue),
  ].join('\n').toLowerCase();
  return haystack.contains(needle);
}

_TimingDraftValues _timingDraftValues(_SegmentDraft draft) {
  final startText = draft.startController.text.trim();
  final endText = draft.endController.text.trim();
  final start = _parseTimecode(startText);
  final end = _parseTimecode(endText);
  if (startText.isEmpty) {
    return _TimingDraftValues(
      start: start,
      end: end,
      message: '开始时间不能为空',
      errorField: _TimingField.start,
    );
  }
  if (startText.startsWith('-')) {
    return _TimingDraftValues(
      start: start,
      end: end,
      message: '开始时间不能小于 0',
      errorField: _TimingField.start,
    );
  }
  if (start == null) {
    return _TimingDraftValues(
      start: start,
      end: end,
      message: '开始时间格式不正确',
      errorField: _TimingField.start,
    );
  }
  if (endText.isEmpty) {
    return _TimingDraftValues(
      start: start,
      end: end,
      message: '结束时间不能为空',
      errorField: _TimingField.end,
    );
  }
  if (endText.startsWith('-')) {
    return _TimingDraftValues(
      start: start,
      end: end,
      message: '结束时间不能小于 0',
      errorField: _TimingField.end,
    );
  }
  if (end == null) {
    return _TimingDraftValues(
      start: start,
      end: end,
      message: '结束时间格式不正确',
      errorField: _TimingField.end,
    );
  }
  if (end <= start) {
    return _TimingDraftValues(
      start: start,
      end: end,
      message: '结束时间需要晚于开始时间',
      errorField: _TimingField.end,
    );
  }
  return _TimingDraftValues(start: start, end: end);
}

double? _parseTimecode(String value) {
  final normalized = value.trim().replaceAll(',', '.');
  if (normalized.isEmpty) return null;
  final parts = normalized.split(':');
  if (parts.length > 3 || parts.any((part) => part.isEmpty)) return null;

  double? total;
  if (parts.length == 1) {
    total = double.tryParse(parts[0]);
  } else if (parts.length == 2) {
    final minutes = int.tryParse(parts[0]);
    final seconds = double.tryParse(parts[1]);
    if (minutes == null || seconds == null || seconds >= 60) return null;
    total = minutes * 60 + seconds;
  } else {
    final hours = int.tryParse(parts[0]);
    final minutes = int.tryParse(parts[1]);
    final seconds = double.tryParse(parts[2]);
    if (hours == null ||
        minutes == null ||
        minutes >= 60 ||
        seconds == null ||
        seconds >= 60) {
      return null;
    }
    total = hours * 3600 + minutes * 60 + seconds;
  }
  if (total == null || !total.isFinite || total < 0) return null;
  return (total * 1000).round() / 1000;
}

String _formatTimecode(double seconds) {
  final safeSeconds = seconds.isFinite
      ? seconds.clamp(0.0, double.infinity).toDouble()
      : 0.0;
  final millis = (safeSeconds * 1000).round();
  final duration = Duration(milliseconds: millis);
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final secs = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final ms = duration.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
  final hours = duration.inHours;
  return hours > 0
      ? '${hours.toString().padLeft(2, '0')}:$minutes:$secs.$ms'
      : '$minutes:$secs.$ms';
}

bool _sameTimestamp(double left, double right) {
  return (left - right).abs() < 0.0005;
}

bool _sameTimingProblem(_TimingProblem? left, _TimingProblem? right) {
  return left?.segmentId == right?.segmentId &&
      left?.message == right?.message &&
      left?.field == right?.field;
}

ResultSegment? _segmentById(List<ResultSegment> segments, int? id) {
  if (id == null) return null;
  for (final segment in segments) {
    if (segment.id == id) return segment;
  }
  return null;
}

bool _segmentHasTimingIssue(ResultSegment segment) {
  for (final issue in segment.issues) {
    final normalized = issue.toLowerCase();
    if (normalized.contains('时间轴') ||
        normalized.contains('结束时间') ||
        normalized.contains('显示时间')) {
      return true;
    }
  }
  const timingCodes = {
    'invalid_timing',
    'timeline_overlap',
    'overlap',
    'duration_too_short',
    'under_min_duration',
    'over_max_duration',
  };
  for (final issue in segment.qualityIssues) {
    final code = _stringValue(issue['code'])?.trim().toLowerCase();
    if (code != null && timingCodes.contains(code)) return true;
  }
  return false;
}

Iterable<String> _issueSearchTerms(Map<String, Object?> issue) sync* {
  for (final key in const ['code', 'message', 'hint_zh', 'hint']) {
    final value = _stringValue(issue[key]);
    if (value != null) yield value;
  }
}

String _emptyFilterText(_SegmentFilter filter, String searchQuery) {
  final query = searchQuery.trim();
  if (query.isNotEmpty) return '没有匹配“$query”的片段。';
  return switch (filter) {
    _SegmentFilter.all => '结果里没有字幕片段。',
    _SegmentFilter.issues => '没有带问题提示的片段。',
    _SegmentFilter.emptyTarget => '没有空译文片段。',
    _SegmentFilter.modified => '没有已修改片段。',
  };
}
