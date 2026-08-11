part of '../task_processing_window.dart';

class _WorkbenchSectionNav extends StatelessWidget {
  const _WorkbenchSectionNav({required this.selected, required this.onChanged});

  final _WorkbenchSection selected;
  final ValueChanged<_WorkbenchSection> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<_WorkbenchSection>(
        key: const ValueKey('workbench-section-nav'),
        segments: const [
          ButtonSegment(
            value: _WorkbenchSection.tasks,
            icon: Icon(Icons.subtitles_outlined, size: 18),
            label: Text('任务与字幕'),
          ),
          ButtonSegment(
            value: _WorkbenchSection.terminology,
            icon: Icon(Icons.menu_book_outlined, size: 18),
            label: Text('术语库'),
          ),
        ],
        selected: {selected},
        showSelectedIcon: false,
        onSelectionChanged: (values) {
          if (values.isNotEmpty) onChanged(values.first);
        },
      ),
    );
  }
}

class _TaskProcessingBody extends StatelessWidget {
  const _TaskProcessingBody({
    required this.tasks,
    required this.totalTaskCount,
    required this.filter,
    required this.filterCounts,
    required this.searchController,
    required this.selected,
    required this.events,
    required this.eventSearchController,
    required this.editingTaskId,
    required this.resultEditorDirty,
    required this.bridge,
    required this.resultTransportOverride,
    required this.message,
    required this.error,
    required this.loadingTasks,
    required this.loadingEvents,
    required this.loadingMoreEvents,
    required this.eventsHasMore,
    required this.resuming,
    required this.retranslatingTaskId,
    required this.reexportingTaskId,
    required this.cancellingTaskId,
    required this.checkingOutputDirectory,
    required this.onRefresh,
    required this.onFilterChanged,
    required this.onClearSearch,
    required this.onSelectTask,
    required this.onLoadMoreEvents,
    required this.onClearEventSearch,
    required this.onOpenResult,
    required this.onCloseEditor,
    required this.onResultDirtyChanged,
    required this.onResultChanged,
    required this.onResume,
    required this.onRetranslate,
    required this.onCancel,
    required this.onOpenFailureRecovery,
    required this.onReexport,
    required this.onChooseOutputDirectory,
    required this.onOpenTaskDirectory,
    required this.onOpenOutputDirectory,
    required this.onCheckOutputDirectory,
  });

  final List<TaskSummary> tasks;
  final int totalTaskCount;
  final _TaskFilter filter;
  final Map<_TaskFilter, int> filterCounts;
  final TextEditingController searchController;
  final TaskSummary? selected;
  final List<Object?> events;
  final TextEditingController eventSearchController;
  final String? editingTaskId;
  final bool resultEditorDirty;
  final WindowStateBridge bridge;
  final AppServiceTransport resultTransportOverride;
  final String? message;
  final String? error;
  final bool loadingTasks;
  final bool loadingEvents;
  final bool loadingMoreEvents;
  final bool eventsHasMore;
  final bool resuming;
  final String? retranslatingTaskId;
  final String? reexportingTaskId;
  final String? cancellingTaskId;
  final bool checkingOutputDirectory;
  final VoidCallback onRefresh;
  final ValueChanged<_TaskFilter> onFilterChanged;
  final VoidCallback onClearSearch;
  final ValueChanged<TaskSummary> onSelectTask;
  final VoidCallback? onLoadMoreEvents;
  final VoidCallback onClearEventSearch;
  final ValueChanged<TaskSummary> onOpenResult;
  final VoidCallback onCloseEditor;
  final ValueChanged<bool> onResultDirtyChanged;
  final VoidCallback onResultChanged;
  final ValueChanged<TaskSummary> onResume;
  final ValueChanged<TaskSummary> onRetranslate;
  final ValueChanged<TaskSummary> onCancel;
  final ValueChanged<TaskSummary> onOpenFailureRecovery;
  final ValueChanged<TaskSummary> onReexport;
  final ValueChanged<TaskSummary> onChooseOutputDirectory;
  final ValueChanged<TaskSummary> onOpenTaskDirectory;
  final ValueChanged<TaskSummary> onOpenOutputDirectory;
  final ValueChanged<TaskSummary> onCheckOutputDirectory;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 292,
          child: _TaskStripList(
            tasks: tasks,
            totalTaskCount: totalTaskCount,
            filter: filter,
            filterCounts: filterCounts,
            searchController: searchController,
            selectedTaskId: selected?.taskId,
            loading: loadingTasks,
            passiveControlsEnabled: !resultEditorDirty,
            onRefresh: onRefresh,
            onFilterChanged: onFilterChanged,
            onClearSearch: onClearSearch,
            onSelect: onSelectTask,
          ),
        ),
        const SizedBox(width: T.s8),
        Container(width: 1, color: T.line),
        const SizedBox(width: T.s8),
        Expanded(
          child: _TaskPreview(
            task: selected,
            events: events,
            eventSearchController: eventSearchController,
            editingTaskId: editingTaskId,
            bridge: bridge,
            resultTransportOverride: resultTransportOverride,
            message: message,
            error: error,
            loadingTasks: loadingTasks,
            loadingEvents: loadingEvents,
            loadingMoreEvents: loadingMoreEvents,
            eventsHasMore: eventsHasMore,
            resuming: resuming,
            retranslatingTaskId: retranslatingTaskId,
            reexportingTaskId: reexportingTaskId,
            cancellingTaskId: cancellingTaskId,
            checkingOutputDirectory: checkingOutputDirectory,
            onLoadMoreEvents: onLoadMoreEvents,
            onClearEventSearch: onClearEventSearch,
            onOpenResult: onOpenResult,
            onCloseEditor: onCloseEditor,
            onResultDirtyChanged: onResultDirtyChanged,
            onResultChanged: onResultChanged,
            onResume: onResume,
            onRetranslate: onRetranslate,
            onCancel: onCancel,
            onOpenFailureRecovery: onOpenFailureRecovery,
            onReexport: onReexport,
            onChooseOutputDirectory: onChooseOutputDirectory,
            onOpenTaskDirectory: onOpenTaskDirectory,
            onOpenOutputDirectory: onOpenOutputDirectory,
            onCheckOutputDirectory: onCheckOutputDirectory,
          ),
        ),
      ],
    );
  }
}

class _TaskStripList extends StatelessWidget {
  const _TaskStripList({
    required this.tasks,
    required this.totalTaskCount,
    required this.filter,
    required this.filterCounts,
    required this.searchController,
    required this.selectedTaskId,
    required this.loading,
    required this.passiveControlsEnabled,
    required this.onRefresh,
    required this.onFilterChanged,
    required this.onClearSearch,
    required this.onSelect,
  });

  final List<TaskSummary> tasks;
  final int totalTaskCount;
  final _TaskFilter filter;
  final Map<_TaskFilter, int> filterCounts;
  final TextEditingController searchController;
  final String? selectedTaskId;
  final bool loading;
  final bool passiveControlsEnabled;
  final VoidCallback onRefresh;
  final ValueChanged<_TaskFilter> onFilterChanged;
  final VoidCallback onClearSearch;
  final ValueChanged<TaskSummary> onSelect;

  @override
  Widget build(BuildContext context) {
    final searchQuery = searchController.text.trim();
    final hasSearch = searchQuery.isNotEmpty;
    final hasListControls = totalTaskCount > 0;
    final summary = totalTaskCount == 0
        ? '完成、失败和制作中的任务会出现在这里。'
        : filter == _TaskFilter.all && !hasSearch
        ? '最近 $totalTaskCount 个任务'
        : '显示 ${tasks.length} / $totalTaskCount 个任务';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('任务片列', style: T.tFilename)),
            _TaskActionButton(
              label: loading ? '刷新中' : '刷新',
              onTap: loading || !passiveControlsEnabled ? null : onRefresh,
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        Text(summary, style: T.tCaption),
        if (hasListControls) ...[
          const SizedBox(height: T.s12),
          if (totalTaskCount > 0)
            _TaskFilterControls(
              selected: filter,
              counts: filterCounts,
              onChanged: onFilterChanged,
            ),
          if (totalTaskCount > 0) ...[
            const SizedBox(height: T.s12),
            _TaskSearchField(
              controller: searchController,
              enabled: !loading && passiveControlsEnabled,
              onClear: onClearSearch,
            ),
          ],
        ],
        const SizedBox(height: T.s16),
        Expanded(
          child: loading && tasks.isEmpty
              ? const Center(child: Text('读取任务中…', style: T.tBody))
              : tasks.isEmpty
              ? Center(
                  child: Text(
                    totalTaskCount == 0
                        ? '还没有任务记录。'
                        : _taskListEmptyText(filter, searchQuery),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: T.tBody,
                  ),
                )
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: T.s8),
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    return _TaskStripTile(
                      task: task,
                      selected: task.taskId == selectedTaskId,
                      onTap: () => onSelect(task),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _TaskSearchField extends StatelessWidget {
  const _TaskSearchField({
    required this.controller,
    required this.enabled,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final hasSearch = controller.text.trim().isNotEmpty;
    return TextField(
      controller: controller,
      enabled: enabled,
      minLines: 1,
      maxLines: 1,
      style: T.tCaption,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索任务',
        prefixIcon: const Icon(Icons.search, size: 16),
        suffixIcon: hasSearch
            ? IconButton(
                tooltip: '清除任务搜索',
                icon: const Icon(Icons.close, size: 16),
                onPressed: enabled ? onClear : null,
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
    );
  }
}

class _EventSearchField extends StatelessWidget {
  const _EventSearchField({
    required this.controller,
    required this.enabled,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final hasSearch = controller.text.trim().isNotEmpty;
    return TextField(
      controller: controller,
      enabled: enabled,
      minLines: 1,
      maxLines: 1,
      style: T.tCaption,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索事件',
        prefixIcon: const Icon(Icons.search, size: 16),
        suffixIcon: hasSearch
            ? IconButton(
                tooltip: '清除事件搜索',
                icon: const Icon(Icons.close, size: 16),
                onPressed: enabled ? onClear : null,
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
    );
  }
}

class _TaskFilterControls extends StatelessWidget {
  const _TaskFilterControls({
    required this.selected,
    required this.counts,
    required this.onChanged,
  });

  final _TaskFilter selected;
  final Map<_TaskFilter, int> counts;
  final ValueChanged<_TaskFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: T.s8,
      runSpacing: T.s8,
      children: [
        for (final filter in _TaskFilter.values)
          _TaskFilterButton(
            label: '${_taskFilterLabel(filter)} ${counts[filter] ?? 0}',
            selected: selected == filter,
            onTap: () => onChanged(filter),
          ),
      ],
    );
  }
}

class _TaskFilterButton extends StatefulWidget {
  const _TaskFilterButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TaskFilterButton> createState() => _TaskFilterButtonState();
}

class _TaskFilterButtonState extends State<_TaskFilterButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return Semantics(
      button: true,
      selected: selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 142,
            constraints: const BoxConstraints(minHeight: 32),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 7),
            decoration: BoxDecoration(
              color: selected
                  ? T.accentSoft
                  : _hover
                  ? T.surface
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(T.rSm),
              border: Border.all(
                color: selected ? T.accentStrong : T.line,
                width: 1.2,
              ),
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: T.tCaption.copyWith(
                color: selected ? T.accentStrong : T.ink,
                fontWeight: selected ? T.wBold : T.wMedium,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskStripTile extends StatelessWidget {
  const _TaskStripTile({
    required this.task,
    required this.selected,
    required this.onTap,
  });

  final TaskSummary task;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _taskStatusColor(task);
    final name = task.displayName;
    final outputs = subtitleFormatListLabel(task.outputPaths.keys);
    final reviewSummary = task.needsReview ? _taskReviewSummary(task) : '';
    final subtitle = [
      taskStatusLabel(task.status),
      if (task.targetLang.isNotEmpty) languageLabel(task.targetLang),
      if (outputs.isNotEmpty) outputs,
    ].join(' · ');
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 82),
          decoration: BoxDecoration(
            color: selected ? T.accentSoft.withValues(alpha: 0.5) : T.surface,
            border: Border.all(color: selected ? T.accentStrong : T.line),
            borderRadius: BorderRadius.circular(T.rSm),
          ),
          child: Row(
            children: [
              SizedBox(width: 5, height: 82, child: ColoredBox(color: color)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(T.s12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? shortTaskIdLabel(task.taskId) : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.tBody.copyWith(fontWeight: T.wMedium),
                      ),
                      const SizedBox(height: T.s4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.tCaption,
                      ),
                      if ((task.error ?? '').isNotEmpty) ...[
                        const SizedBox(height: T.s4),
                        Text(
                          taskErrorLabel(task.error, task.errorInfo),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: T.tCaption.copyWith(color: T.danger),
                        ),
                      ] else if (reviewSummary.isNotEmpty) ...[
                        const SizedBox(height: T.s4),
                        Row(
                          children: [
                            const Icon(
                              Icons.rate_review_rounded,
                              size: 14,
                              color: T.warn,
                            ),
                            const SizedBox(width: T.s4),
                            Expanded(
                              child: Text(
                                reviewSummary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: T.tCaption.copyWith(
                                  color: T.warn,
                                  fontWeight: T.wMedium,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
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

class _TaskPreview extends StatelessWidget {
  const _TaskPreview({
    required this.task,
    required this.events,
    required this.eventSearchController,
    required this.editingTaskId,
    required this.bridge,
    required this.resultTransportOverride,
    required this.message,
    required this.error,
    required this.loadingTasks,
    required this.loadingEvents,
    required this.loadingMoreEvents,
    required this.eventsHasMore,
    required this.resuming,
    required this.retranslatingTaskId,
    required this.reexportingTaskId,
    required this.cancellingTaskId,
    required this.checkingOutputDirectory,
    required this.onLoadMoreEvents,
    required this.onClearEventSearch,
    required this.onOpenResult,
    required this.onCloseEditor,
    required this.onResultDirtyChanged,
    required this.onResultChanged,
    required this.onResume,
    required this.onRetranslate,
    required this.onCancel,
    required this.onOpenFailureRecovery,
    required this.onReexport,
    required this.onChooseOutputDirectory,
    required this.onOpenTaskDirectory,
    required this.onOpenOutputDirectory,
    required this.onCheckOutputDirectory,
  });

  final TaskSummary? task;
  final List<Object?> events;
  final TextEditingController eventSearchController;
  final String? editingTaskId;
  final WindowStateBridge bridge;
  final AppServiceTransport resultTransportOverride;
  final String? message;
  final String? error;
  final bool loadingTasks;
  final bool loadingEvents;
  final bool loadingMoreEvents;
  final bool eventsHasMore;
  final bool resuming;
  final String? retranslatingTaskId;
  final String? reexportingTaskId;
  final String? cancellingTaskId;
  final bool checkingOutputDirectory;
  final VoidCallback? onLoadMoreEvents;
  final VoidCallback onClearEventSearch;
  final ValueChanged<TaskSummary> onOpenResult;
  final VoidCallback onCloseEditor;
  final ValueChanged<bool> onResultDirtyChanged;
  final VoidCallback onResultChanged;
  final ValueChanged<TaskSummary> onResume;
  final ValueChanged<TaskSummary> onRetranslate;
  final ValueChanged<TaskSummary> onCancel;
  final ValueChanged<TaskSummary> onOpenFailureRecovery;
  final ValueChanged<TaskSummary> onReexport;
  final ValueChanged<TaskSummary> onChooseOutputDirectory;
  final ValueChanged<TaskSummary> onOpenTaskDirectory;
  final ValueChanged<TaskSummary> onOpenOutputDirectory;
  final ValueChanged<TaskSummary> onCheckOutputDirectory;

  @override
  Widget build(BuildContext context) {
    final task = this.task;
    if (task == null) {
      return Center(
        child: Text(loadingTasks ? '读取任务中…' : '选择一个任务后查看处理动作。', style: T.tBody),
      );
    }
    if (editingTaskId == task.taskId && task.isDone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '字幕编辑',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tFilename,
                ),
              ),
              _TaskActionButton(label: '返回概览', onTap: onCloseEditor),
            ],
          ),
          const SizedBox(height: T.s12),
          Expanded(
            child: ResultReviewWorkspace(
              taskId: task.taskId,
              bridge: bridge,
              transportOverride: resultTransportOverride,
              focusIssuesInitially: task.needsReview,
              onDirtyChanged: onResultDirtyChanged,
              onResultChanged: onResultChanged,
            ),
          ),
        ],
      );
    }
    final outputDir = _outputDirectoryFor(task);
    final cancelling = cancellingTaskId == task.taskId;
    final retranslating = retranslatingTaskId == task.taskId;
    final reexporting = reexportingTaskId == task.taskId;
    final eventSearchQuery = eventSearchController.text.trim();
    final visibleEvents = events
        .where(
          (event) => _eventMatchesSearch(_eventMap(event), eventSearchQuery),
        )
        .toList(growable: false);
    final diagnosticClues = _taskDiagnosticClues(task);
    final recovery = taskFailurePresentation(
      error: task.error,
      errorInfo: task.errorInfo,
      canResume: task.canResume,
    );
    final hasSettingsRecovery =
        (task.isFailed || task.isRuntimeStale) &&
        (recovery.target == TaskFailureRecoveryTarget.translationSettings ||
            recovery.target == TaskFailureRecoveryTarget.asrSettings);
    final hasOutputRecovery =
        (task.isFailed || task.isRuntimeStale) &&
        (recovery.target == TaskFailureRecoveryTarget.outputDirectory ||
            recovery.target == TaskFailureRecoveryTarget.reexport);
    final hasPrimaryFailureRecovery = hasSettingsRecovery || hasOutputRecovery;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _basename(task.inputFile).isEmpty
              ? shortTaskIdLabel(task.taskId)
              : _basename(task.inputFile),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: T.tFilename,
        ),
        const SizedBox(height: T.s8),
        Text(
          _taskSubtitle(task),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: T.tCaption,
        ),
        const SizedBox(height: T.s12),
        Wrap(
          spacing: T.s8,
          runSpacing: T.s8,
          children: [
            if (task.isDone)
              _TaskActionButton(
                label: '编辑字幕',
                strong: true,
                onTap: () => onOpenResult(task),
              ),
            if (task.isDone)
              _TaskActionButton(
                label: retranslating ? '创建中' : '重新翻译',
                onTap: retranslatingTaskId == null
                    ? () => onRetranslate(task)
                    : null,
              ),
            if (hasSettingsRecovery)
              _TaskActionButton(
                label: recovery.actionLabel,
                strong: true,
                onTap: () => onOpenFailureRecovery(task),
              ),
            if (hasOutputRecovery)
              _TaskActionButton(
                label: reexporting ? '导出中' : recovery.actionLabel,
                strong: true,
                onTap: reexportingTaskId != null
                    ? null
                    : recovery.target ==
                          TaskFailureRecoveryTarget.outputDirectory
                    ? () => onChooseOutputDirectory(task)
                    : () => onReexport(task),
              ),
            if (task.canResume)
              _TaskActionButton(
                label: resuming ? '继续中' : '继续任务',
                strong: !hasPrimaryFailureRecovery,
                onTap: resuming ? null : () => onResume(task),
              ),
            if (task.canCancel)
              _TaskActionButton(
                label: cancelling ? '取消中' : '取消任务',
                danger: true,
                onTap: cancellingTaskId == null ? () => onCancel(task) : null,
              ),
            if (task.isDone && outputDir != null)
              _TaskActionButton(
                label: '结果目录',
                onTap: () => onOpenOutputDirectory(task),
              ),
            if (hasOutputRecovery && outputDir != null)
              _TaskActionButton(
                label: checkingOutputDirectory ? '检查中' : '检查结果目录',
                onTap: checkingOutputDirectory
                    ? null
                    : () => onCheckOutputDirectory(task),
              ),
            if (task.taskDir.trim().isNotEmpty)
              _TaskActionButton(
                label: '任务目录',
                onTap: () => onOpenTaskDirectory(task),
              ),
          ],
        ),
        const SizedBox(height: T.s12),
        if (error != null)
          Text(error!, style: T.tBody.copyWith(color: T.danger))
        else if (message != null)
          Text(message!, style: T.tCaption)
        else
          Text(_taskActionHint(task), style: T.tCaption),
        const SizedBox(height: T.s16),
        _TaskSummaryPanel(task: task),
        if (task.needsReview) ...[
          const SizedBox(height: T.s12),
          _TaskReviewNote(task: task),
        ],
        if (diagnosticClues.isNotEmpty) ...[
          const SizedBox(height: T.s12),
          _TaskDiagnosticsPanel(
            title: _taskDiagnosticTitle(task),
            clues: diagnosticClues,
          ),
        ],
        const SizedBox(height: T.s16),
        Row(
          children: [
            Expanded(child: Text('最近事件', style: T.tSection)),
            const SizedBox(width: T.s8),
            Flexible(
              child: Align(
                alignment: Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: _EventSearchField(
                    controller: eventSearchController,
                    enabled: !loadingEvents && events.isNotEmpty,
                    onClear: onClearEventSearch,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        Expanded(
          child: loadingEvents && events.isEmpty
              ? const Center(child: Text('读取事件中…', style: T.tBody))
              : events.isEmpty
              ? const Center(child: Text('还没有事件记录。', style: T.tBody))
              : visibleEvents.isEmpty && eventSearchQuery.isNotEmpty
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '没有匹配“$eventSearchQuery”的事件。',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: T.tBody,
                    ),
                    if (eventsHasMore) ...[
                      const SizedBox(height: T.s12),
                      _TaskActionButton(
                        label: loadingMoreEvents ? '读取中' : '加载更多事件',
                        onTap: loadingMoreEvents ? null : onLoadMoreEvents,
                      ),
                    ],
                  ],
                )
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: visibleEvents.length + (eventsHasMore ? 1 : 0),
                  separatorBuilder: (_, _) =>
                      const Divider(height: T.s24, color: T.line),
                  itemBuilder: (context, index) {
                    if (index >= visibleEvents.length) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: _TaskActionButton(
                          label: loadingMoreEvents ? '读取中' : '加载更多事件',
                          onTap: loadingMoreEvents ? null : onLoadMoreEvents,
                        ),
                      );
                    }
                    return _EventPreviewRow(
                      event: _eventMap(visibleEvents[index]),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _TaskSummaryPanel extends StatelessWidget {
  const _TaskSummaryPanel({required this.task});

  final TaskSummary task;

  @override
  Widget build(BuildContext context) {
    final outputs = subtitleFormatListLabel(task.outputPaths.keys);
    final createdAt = taskTimestampLabel(task.createdAt);
    final updatedAt = taskTimestampLabel(task.updatedAt);
    final runtimeState = _runtimeStateLabel(task.runtimeState);
    final requestCounts = task.modelRequestCounts;
    final translationRequests = _requestModeTotal(
      requestCounts,
      (mode) => mode == 'translate',
    );
    final protocolRequests = _requestModeTotal(
      requestCounts,
      (mode) => mode == 'protocol_recovery',
    );
    final batchRecoveryRequests = _requestModeTotal(
      requestCounts,
      (mode) => mode == 'batch_recovery',
    );
    final repairRequests = _requestModeTotal(
      requestCounts,
      (mode) => mode == 'repair',
    );
    final memoryRequests = _requestModeTotal(
      requestCounts,
      (mode) => mode.startsWith('memory_'),
    );
    final qualityRequests = _requestModeTotal(
      requestCounts,
      (mode) => mode.startsWith('quality_'),
    );
    final openRouterUsage = _openRouterAsrUsageLabel(task);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: T.s12),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: T.line),
          bottom: BorderSide(color: T.line),
        ),
      ),
      child: Wrap(
        spacing: T.s24,
        runSpacing: T.s12,
        children: [
          _InfoPill(label: '状态', value: taskStatusLabel(task.status)),
          _InfoPill(label: '源语', value: languageLabel(task.sourceLang)),
          _InfoPill(label: '目标', value: languageLabel(task.targetLang)),
          _InfoPill(label: '字幕', value: task.bilingual ? '双语' : '单语'),
          if (outputs.isNotEmpty) _InfoPill(label: '输出', value: outputs),
          if (createdAt.isNotEmpty) _InfoPill(label: '创建', value: createdAt),
          if (updatedAt.isNotEmpty) _InfoPill(label: '更新', value: updatedAt),
          if (runtimeState.isNotEmpty)
            _InfoPill(
              label: '运行记录',
              value: runtimeState,
              danger: task.isRuntimeStale,
            ),
          if (task.asrTotalSegments > 0)
            _InfoPill(
              label: '语音分窗',
              value: '${task.asrDoneCount}/${task.asrTotalSegments}',
            ),
          if (task.hasOpenRouterAsrUsage)
            _InfoPill(
              label: task.hasCompleteOpenRouterAsrUsage
                  ? 'OpenRouter 用量'
                  : 'OpenRouter 已报告用量',
              value: openRouterUsage,
            ),
          if (task.translationTotalChunks > 0)
            _InfoPill(
              label: '翻译分片',
              value:
                  '${task.translationDoneCount}/${task.translationTotalChunks}',
            ),
          if (task.modelRequestCount > 0)
            _InfoPill(label: '模型请求', value: '${task.modelRequestCount} 次'),
          if (translationRequests > 0)
            _InfoPill(label: '分片翻译', value: '$translationRequests 次'),
          if (protocolRequests > 0)
            _InfoPill(label: '格式重试', value: '$protocolRequests 次'),
          if (batchRecoveryRequests > 0)
            _InfoPill(label: '批量补回', value: '$batchRecoveryRequests 次'),
          if (repairRequests > 0)
            _InfoPill(
              label: '单行修复',
              value: '$repairRequests 次',
              danger: repairRequests > 8,
            ),
          if (memoryRequests > 0)
            _InfoPill(label: '术语请求', value: '$memoryRequests 次'),
          if (qualityRequests > 0)
            _InfoPill(label: '质量请求', value: '$qualityRequests 次'),
          if (task.qualityStatus.isNotEmpty)
            _InfoPill(
              label: '质量检查',
              value: _reviewCheckStatusLabel(task.qualityStatus),
              warn: task.needsReview,
            ),
          if (task.deliveryStatus.isNotEmpty)
            _InfoPill(
              label: '交付检查',
              value: _reviewCheckStatusLabel(task.deliveryStatus),
              warn: task.needsReview,
            ),
          if (task.reviewIssueCount > 0)
            _InfoPill(
              label: '待校对',
              value: '${task.reviewIssueCount} 条',
              warn: true,
            ),
          if (task.hasSavedResultPendingExport)
            const _InfoPill(label: '字幕文件', value: '等待更新', warn: true),
        ],
      ),
    );
  }
}

class _TaskReviewNote extends StatelessWidget {
  const _TaskReviewNote({required this.task});

  final TaskSummary task;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: T.s4),
          padding: const EdgeInsets.all(T.s12),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF8E3),
            border: Border.all(color: T.warn.withValues(alpha: 0.48)),
            borderRadius: BorderRadius.circular(T.rSm),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                height: 42,
                decoration: BoxDecoration(
                  color: T.warn,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: T.s12),
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.rate_review_rounded, size: 18, color: T.warn),
              ),
              const SizedBox(width: T.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('还有字幕值得再看一眼', style: T.tSection),
                    const SizedBox(height: T.s4),
                    Text(_taskReviewDetail(task), style: T.tCaption),
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: 0,
          right: T.s24,
          child: IgnorePointer(
            child: Container(
              width: 46,
              height: 8,
              decoration: BoxDecoration(
                color: T.skySoft,
                border: Border.all(color: T.sky.withValues(alpha: 0.42)),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

int _requestModeTotal(
  Map<String, int> counts,
  bool Function(String mode) matches,
) {
  return counts.entries
      .where((entry) => matches(entry.key))
      .fold(0, (total, entry) => total + entry.value);
}

String _openRouterAsrUsageLabel(TaskSummary task) {
  final parts = <String>[];
  final cost = task.asrUsageCostUsd;
  if (cost != null) parts.add(_usdUsageLabel(cost));
  final seconds = task.asrUsageAudioSeconds;
  if (seconds != null) parts.add('${seconds.toStringAsFixed(2)} 秒');
  if (parts.isNotEmpty) return parts.join(' · ');
  return '${task.asrUsageRequestCount} 次';
}

String _usdUsageLabel(double amount) {
  if (amount > 0 && amount < 0.000001) {
    return '\$${amount.toStringAsExponential(2)}';
  }
  if (amount < 1) return '\$${amount.toStringAsFixed(6)}';
  return '\$${amount.toStringAsFixed(4)}';
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.label,
    required this.value,
    this.danger = false,
    this.warn = false,
    this.maxLines = 1,
  });

  final String label;
  final String value;
  final bool danger;
  final bool warn;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Text(
        '$label ${value.isEmpty ? '未知' : value}',
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: T.tCaption.copyWith(
          color: danger
              ? T.danger
              : warn
              ? T.warn
              : T.ink,
          fontWeight: danger || warn ? T.wMedium : T.wRegular,
        ),
      ),
    );
  }
}

class _TaskDiagnosticsPanel extends StatelessWidget {
  const _TaskDiagnosticsPanel({required this.title, required this.clues});

  final String title;
  final List<_TaskDiagnosticClue> clues;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: T.s4),
          padding: const EdgeInsets.all(T.s12),
          decoration: BoxDecoration(
            color: T.lilacSoft.withValues(alpha: 0.62),
            border: Border.all(color: T.line),
            borderRadius: BorderRadius.circular(T.rSm),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                height: 44,
                decoration: BoxDecoration(
                  color: T.danger,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: T.s12),
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.handyman_rounded, size: 18, color: T.danger),
              ),
              const SizedBox(width: T.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: T.tSection),
                    const SizedBox(height: T.s8),
                    Wrap(
                      spacing: T.s24,
                      runSpacing: T.s8,
                      children: [
                        for (final clue in clues)
                          _InfoPill(
                            label: clue.label,
                            value: clue.value,
                            danger: clue.danger,
                            maxLines: clue.maxLines,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: 0,
          left: T.s24,
          child: IgnorePointer(
            child: Container(
              width: 46,
              height: 8,
              decoration: BoxDecoration(
                color: T.accentSoft,
                border: Border.all(color: T.accent.withValues(alpha: 0.42)),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TaskDiagnosticClue {
  const _TaskDiagnosticClue({
    required this.label,
    required this.value,
    this.danger = false,
    this.maxLines = 1,
  });

  final String label;
  final String value;
  final bool danger;
  final int maxLines;
}

class _EventPreviewRow extends StatelessWidget {
  const _EventPreviewRow({required this.event});

  final Map<String, Object?> event;

  @override
  Widget build(BuildContext context) {
    final type = _eventText(event, 'type', fallback: 'event');
    final stage = _eventText(event, 'stage');
    final status = _eventText(event, 'status');
    final message = _eventText(event, 'message');
    final createdAt = taskTimestampLabel(_eventText(event, 'created_at'));
    final progress = taskProgressLabel(event['progress']);
    final label = taskEventTypeLabel(type);
    final stageLabel = taskStageLabel(stage);
    final messageLabel = taskEventMessageLabel(
      type: type,
      stage: stage,
      status: status,
      message: message,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: _EventTag(label: label, type: type),
        ),
        const SizedBox(width: T.s12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  if (stageLabel.isNotEmpty) stageLabel,
                  if (createdAt.isNotEmpty) createdAt,
                  if (progress.isNotEmpty) '进度 $progress',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.tCaption,
              ),
              const SizedBox(height: T.s4),
              Text(
                messageLabel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: T.tBody,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EventTag extends StatelessWidget {
  const _EventTag({required this.label, required this.type});

  final String label;
  final String type;

  @override
  Widget build(BuildContext context) {
    final color = type.toLowerCase() == 'error' ? T.danger : T.sky;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.8)),
        borderRadius: BorderRadius.circular(T.rSm),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: T.tCaption,
      ),
    );
  }
}

class _TaskActionButton extends StatefulWidget {
  const _TaskActionButton({
    required this.label,
    required this.onTap,
    this.strong = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool strong;
  final bool danger;

  @override
  State<_TaskActionButton> createState() => _TaskActionButtonState();
}

class _TaskActionButtonState extends State<_TaskActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final actionColor = widget.danger ? T.danger : T.accentStrong;
    final background = !enabled
        ? const Color(0x00000000)
        : widget.strong
        ? (_hover ? T.accentStrong : T.accent)
        : _hover
        ? (widget.danger ? T.danger.withValues(alpha: 0.08) : T.accentSoft)
        : const Color(0x00000000);
    final foreground = !enabled
        ? T.muted
        : widget.strong
        ? const Color(0xFFFFFFFF)
        : actionColor;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: enabled ? (_) => setState(() => _hover = true) : null,
      onExit: enabled ? (_) => setState(() => _hover = false) : null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 76),
          padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: 7),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(
              color: enabled
                  ? (widget.strong ? background : actionColor)
                  : T.line,
              width: 1.2,
            ),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: T.tCaption.copyWith(color: foreground, fontWeight: T.wBold),
          ),
        ),
      ),
    );
  }
}

Color _taskStatusColor(TaskSummary task) {
  if (task.needsReview) return T.warn;
  if (task.isDone) return T.ok;
  if (task.isFailed) return T.danger;
  if (task.isActive) return T.sky;
  return T.muted;
}

bool _taskMatchesFilter(TaskSummary task, _TaskFilter filter) {
  return switch (filter) {
    _TaskFilter.all => true,
    _TaskFilter.active =>
      task.isActive || task.isRuntimeActive || task.canCancel,
    _TaskFilter.needsAction =>
      task.canResume ||
          task.isFailed ||
          task.status == 'INTERRUPTED' ||
          task.isRuntimeStale,
    _TaskFilter.review => task.needsReview,
    _TaskFilter.done => task.isDone,
    _TaskFilter.cancelled => task.status == 'CANCELLED',
  };
}

bool _taskMatchesSearch(TaskSummary task, String searchQuery) {
  final terms = searchQuery
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
  if (terms.isEmpty) return true;
  final outputDir = _outputDirectoryFor(task);
  final searchText = [
    task.taskId,
    shortTaskIdLabel(task.taskId),
    task.status,
    taskStatusLabel(task.status),
    task.displayStatus,
    taskStatusLabel(task.displayStatus),
    _runtimeStateLabel(task.runtimeState),
    _taskActionabilityLabel(task),
    if (task.needsReview) '待校对',
    if (task.needsReview) _taskReviewSummary(task),
    _reviewCheckStatusLabel(task.qualityStatus),
    _reviewCheckStatusLabel(task.deliveryStatus),
    task.sourceLang,
    task.targetLang,
    languageLabel(task.sourceLang),
    languageLabel(task.targetLang),
    task.inputFile,
    task.displayName,
    task.inputType,
    _basename(task.inputFile),
    task.taskDir,
    ?task.outputPath,
    ?outputDir,
    ...task.outputPaths.keys,
    ...task.outputPaths.values,
    subtitleFormatListLabel(task.outputPaths.keys),
    ?task.error,
    taskErrorLabel(task.error, task.errorInfo),
    ...task.errorInfo.values.map((value) => '$value'),
    for (final clue in _taskDiagnosticClues(task)) ...[clue.label, clue.value],
    task.createdAt,
    task.updatedAt,
  ].join('\n').toLowerCase();
  return terms.every((term) => searchText.contains(term));
}

String _runtimeStateLabel(String state) {
  return switch (state.trim().toLowerCase()) {
    '' => '',
    'running' => '运行中',
    'claimed' => '正在处理',
    'queued' => '排队中',
    'stale' => '记录过期',
    'interrupted' => '已中断',
    'terminal' => '已结束',
    'idle' => '空闲',
    _ => state.trim(),
  };
}

String _taskActionabilityLabel(TaskSummary task) {
  final recovery = taskFailurePresentation(
    error: task.error,
    errorInfo: task.errorInfo,
    canResume: task.canResume,
  );
  if (recovery.target == TaskFailureRecoveryTarget.translationSettings ||
      recovery.target == TaskFailureRecoveryTarget.asrSettings) {
    return recovery.actionLabel;
  }
  if (recovery.target == TaskFailureRecoveryTarget.outputDirectory ||
      recovery.target == TaskFailureRecoveryTarget.reexport) {
    return recovery.actionLabel;
  }
  if (task.canResume) return '可继续任务';
  if (task.canCancel) return '可取消任务';
  if (task.hasSavedResultPendingExport) return '修改待导出';
  if (task.needsReview) return '待校对';
  if (task.isDone) return '可编辑结果';
  if (task.isFailed || task.isRuntimeStale) return '无可用恢复动作';
  if (task.isCancelled) return '已结束';
  if (task.isActive || task.isRuntimeActive) return '等待处理';
  return '只读查看';
}

String _taskActionHint(TaskSummary task) {
  if (task.needsReview) {
    return '结果已经生成，但质量或交付检查仍有提醒，建议先校对再交付。';
  }
  if (task.isDone) return '结果已经生成，可以进入字幕编辑或打开结果目录。';
  final recovery = taskFailurePresentation(
    error: task.error,
    errorInfo: task.errorInfo,
    canResume: task.canResume,
  );
  if (recovery.target == TaskFailureRecoveryTarget.translationSettings ||
      recovery.target == TaskFailureRecoveryTarget.asrSettings) {
    return task.canResume
        ? '先${recovery.actionLabel}，修好后可以继续已有进度。'
        : recovery.reason;
  }
  if (recovery.target == TaskFailureRecoveryTarget.outputDirectory) {
    return '选择一个可写目录后，会直接重新导出已有字幕结果。';
  }
  if (recovery.target == TaskFailureRecoveryTarget.reexport) {
    return '字幕结果需要重新写出，不必重新制作整项任务。';
  }
  if (task.canResume) return '这个任务可以从已有进度继续。';
  if (task.canCancel) return '任务仍在制作中，需要时可以取消。';
  if (task.isFailed || task.isRuntimeStale) {
    return '请根据下方失败线索调整配置或片源后重试。';
  }
  if (task.isCancelled) return '这个任务已经结束，没有待执行操作。';
  return '当前任务只提供记录查看。';
}

String _taskDiagnosticTitle(TaskSummary task) {
  if (task.isFailed) return '失败线索';
  if (task.status == 'INTERRUPTED') return '中断线索';
  if (task.isRuntimeStale) return '运行线索';
  return '处理线索';
}

List<_TaskDiagnosticClue> _taskDiagnosticClues(TaskSummary task) {
  final hasError = (task.error ?? '').trim().isNotEmpty;
  final hasDiagnosticInfo = task.errorInfo.isNotEmpty;
  final shouldShow =
      task.isFailed ||
      task.isCancelled ||
      task.isRuntimeStale ||
      hasError ||
      hasDiagnosticInfo;
  if (!shouldShow) return const [];

  final clues = <_TaskDiagnosticClue>[];
  final summary = hasError || hasDiagnosticInfo
      ? taskErrorLabel(task.error, task.errorInfo)
      : '';
  if (summary.trim().isNotEmpty) {
    clues.add(
      _TaskDiagnosticClue(
        label: '提示',
        value: summary,
        danger: task.isFailed || task.isRuntimeStale,
        maxLines: 2,
      ),
    );
  }

  final stage = _firstDiagnosticText(task.errorInfo, const [
    'stage',
    'failed_stage',
    'last_stage',
  ]);
  if (stage != null) {
    clues.add(_TaskDiagnosticClue(label: '阶段', value: taskStageLabel(stage)));
  }

  return clues;
}

Map<String, Object?> _taskDiagnosticSmokeFields(TaskSummary? task) {
  if (task == null) {
    return const <String, Object?>{
      'task_processing_diagnostic_title': '',
      'task_processing_diagnostic_clue_count': 0,
      'task_processing_diagnostic_prompt': '',
      'task_processing_diagnostic_code': '',
      'task_processing_diagnostic_stage': '',
      'task_processing_diagnostic_stage_label': '',
      'task_processing_diagnostic_retryable': null,
      'task_processing_diagnostic_runtime_state': '',
      'task_processing_diagnostic_runtime_state_label': '',
      'task_processing_diagnostic_can_resume': false,
      'task_processing_diagnostic_recovery': '',
      'task_processing_recovery_target': '',
      'task_processing_recovery_action': '',
    };
  }
  final visibleClues = _taskDiagnosticClues(task);
  final stage = _firstDiagnosticText(task.errorInfo, const [
    'stage',
    'failed_stage',
    'last_stage',
  ]);
  final runtimeState = task.runtimeState;
  final recovery = taskFailurePresentation(
    error: task.error,
    errorInfo: task.errorInfo,
    canResume: task.canResume,
  );
  return <String, Object?>{
    'task_processing_diagnostic_title': visibleClues.isEmpty
        ? ''
        : _taskDiagnosticTitle(task),
    'task_processing_diagnostic_clue_count': visibleClues.length,
    'task_processing_diagnostic_prompt': _diagnosticClueValue(
      visibleClues,
      '提示',
    ),
    'task_processing_diagnostic_code':
        _firstDiagnosticText(task.errorInfo, const [
          'code',
          'error_code',
          'kind',
        ]) ??
        '',
    'task_processing_diagnostic_stage': stage ?? '',
    'task_processing_diagnostic_stage_label': stage == null
        ? ''
        : taskStageLabel(stage),
    'task_processing_diagnostic_retryable': _firstDiagnosticBool(
      task.errorInfo,
      const ['retryable', 'recoverable', 'can_retry'],
    ),
    'task_processing_diagnostic_runtime_state': runtimeState,
    'task_processing_diagnostic_runtime_state_label': _runtimeStateLabel(
      runtimeState,
    ),
    'task_processing_diagnostic_can_resume': task.canResume,
    'task_processing_diagnostic_recovery': recovery.actionLabel,
    'task_processing_recovery_target': recovery.target.name,
    'task_processing_recovery_action': recovery.actionLabel,
  };
}

String _diagnosticClueValue(List<_TaskDiagnosticClue> clues, String label) {
  for (final clue in clues) {
    if (clue.label == label) return clue.value;
  }
  return '';
}

String? _firstDiagnosticText(
  Map<String, Object?> values,
  Iterable<String> keys,
) {
  for (final key in keys) {
    final value = _stringValue(values[key]);
    if (value != null) return value;
  }
  return null;
}

bool? _firstDiagnosticBool(Map<String, Object?> values, Iterable<String> keys) {
  for (final key in keys) {
    final value = values[key];
    if (value is bool) return value;
    final text = _stringValue(value)?.toLowerCase();
    if (text == null) continue;
    if (text == 'true' || text == 'yes' || text == '1') return true;
    if (text == 'false' || text == 'no' || text == '0') return false;
  }
  return null;
}

String _taskFilterLabel(_TaskFilter filter) {
  return switch (filter) {
    _TaskFilter.all => '全部',
    _TaskFilter.active => '制作中',
    _TaskFilter.needsAction => '待处理',
    _TaskFilter.review => '待校对',
    _TaskFilter.done => '已完成',
    _TaskFilter.cancelled => '已取消',
  };
}

String _taskFilterEmptyText(_TaskFilter filter) {
  return switch (filter) {
    _TaskFilter.all => '还没有任务记录。',
    _TaskFilter.active => '没有正在制作的任务。',
    _TaskFilter.needsAction => '没有需要处理的失败或中断任务。',
    _TaskFilter.review => '没有需要继续校对的完成任务。',
    _TaskFilter.done => '还没有完成的任务。',
    _TaskFilter.cancelled => '还没有已取消的任务。',
  };
}

String _taskListEmptyText(_TaskFilter filter, String searchQuery) {
  final query = searchQuery.trim();
  if (query.isNotEmpty) return '没有匹配“$query”的任务。';
  return _taskFilterEmptyText(filter);
}

String _taskSubtitle(TaskSummary task) {
  final outputs = subtitleFormatListLabel(task.outputPaths.keys);
  return [
    taskStatusLabel(task.status),
    if (task.sourceLang.isNotEmpty || task.targetLang.isNotEmpty)
      '${languageLabel(task.sourceLang)} → ${languageLabel(task.targetLang)}',
    task.bilingual ? '双语字幕' : '单语字幕',
    if (outputs.isNotEmpty) outputs,
  ].join(' · ');
}

String _taskReviewSummary(TaskSummary task) {
  if (task.hasSavedResultPendingExport) return '待导出 · 修改已保存';
  final count = task.reviewIssueCount;
  return count > 0 ? '待校对 · $count 条提示' : '待校对 · 有检查提醒';
}

String _taskReviewDetail(TaskSummary task) {
  if (task.hasSavedResultPendingExport) {
    return '字幕修改已经保存，但成品文件仍是旧版本；打开字幕后重新导出即可更新。';
  }
  final count = task.reviewIssueCount;
  if (count > 0) {
    return '还有 $count 条质量或交付提示，打开字幕会先显示有问题的片段。';
  }
  return '质量或交付检查留下了提醒，打开字幕后建议逐条确认。';
}

String _reviewCheckStatusLabel(String status) {
  return switch (status.trim().toUpperCase()) {
    'PASS' => '已通过',
    'WARN' => '有提醒',
    'FAIL' => '需校对',
    _ => '',
  };
}

String _basename(String path) {
  if (path.trim().isEmpty) return '';
  return path.split(RegExp(r'[\\/]')).last;
}

String? _outputDirectoryFor(TaskSummary task) {
  final path = _primaryOutputPath(task);
  if (path == null || path.trim().isEmpty) return null;
  return _dirname(path);
}

String? _primaryOutputPath(TaskSummary task) {
  final direct = task.outputPath?.trim();
  if (direct != null && direct.isNotEmpty) return direct;
  for (final key in const ['srt', 'ass', 'vtt', 'lrc']) {
    final value = task.outputPaths[key]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  if (task.outputPaths.isNotEmpty) {
    final value = task.outputPaths.values.first.trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}

String _dirname(String path) {
  final trimmed = path.trim();
  final lastSlash = trimmed.lastIndexOf(RegExp(r'[\\/]'));
  if (lastSlash <= 0) return '';
  return trimmed.substring(0, lastSlash);
}

String _taskOutputFormat(TaskSummary task) {
  final saved = (_stringValue(task.settings['output_format']) ?? '')
      .toLowerCase();
  if (saved == 'webvtt') return 'vtt';
  if (const {'srt', 'ass', 'vtt', 'lrc', 'both'}.contains(saved)) return saved;

  final formats = task.outputPaths.keys
      .map((value) => value.trim().toLowerCase())
      .toSet();
  if (formats.contains('srt') && formats.contains('ass')) return 'both';
  for (final format in const ['srt', 'ass', 'vtt', 'lrc']) {
    if (formats.contains(format)) return format;
  }
  return 'srt';
}

String _normalizedSmokeScenario(String? value) {
  return switch ((value ?? '').trim().toLowerCase()) {
    'edit' => 'edit',
    'failure' => 'failure',
    'outputfailure' => 'outputFailure',
    'review' => 'review',
    'resume' => 'resume',
    'cancel' => 'cancel',
    _ => 'browse',
  };
}

Map<String, Object?> _stringMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return const <String, Object?>{};
}

String? _stringValue(Object? value) {
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

Map<String, Object?> _eventMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return {'type': 'event', 'message': '$value'};
}

String _eventText(
  Map<String, Object?> event,
  String key, {
  String fallback = '',
}) {
  final value = event[key];
  if (value == null) return fallback;
  final text = '$value'.trim();
  return text.isEmpty ? fallback : text;
}

bool _eventMatchesSearch(Map<String, Object?> event, String searchQuery) {
  final terms = searchQuery
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
  if (terms.isEmpty) return true;
  final type = _eventText(event, 'type', fallback: 'event');
  final stage = _eventText(event, 'stage');
  final status = _eventText(event, 'status');
  final message = _eventText(event, 'message');
  final createdAt = taskTimestampLabel(_eventText(event, 'created_at'));
  final progress = taskProgressLabel(event['progress']);
  final searchText = [
    type,
    taskEventTypeLabel(type),
    stage,
    taskStageLabel(stage),
    status,
    taskStatusLabel(status),
    message,
    taskEventMessageLabel(
      type: type,
      stage: stage,
      status: status,
      message: message,
    ),
    createdAt,
    progress,
    ...event.values.map((value) => '$value'),
  ].join('\n').toLowerCase();
  return terms.every((term) => searchText.contains(term));
}

String _friendlyTaskProcessingError(Object error) {
  if (error is RpcRemoteException) {
    final details = _stringMap(error.details);
    final errorInfo = _stringMap(details['error_info']);
    return taskFailurePresentation(
      error: error.message,
      errorInfo: {
        ...errorInfo,
        if ((_stringValue(errorInfo['code']) ?? '').isEmpty) 'code': error.code,
      },
    ).reason;
  }
  return taskFailurePresentation(error: '$error').reason;
}
