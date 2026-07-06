import 'dart:async';

import 'package:flutter/material.dart';

import '../model/task_labels.dart';
import '../services/app_service_client.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';

class ResultReviewWorkspace extends StatefulWidget {
  const ResultReviewWorkspace({
    super.key,
    required this.taskId,
    required this.bridge,
    this.transportOverride,
  });

  final String? taskId;
  final WindowStateBridge bridge;
  final AppServiceTransport? transportOverride;

  @override
  State<ResultReviewWorkspace> createState() => _ResultReviewWorkspaceState();
}

class _ResultReviewWorkspaceState extends State<ResultReviewWorkspace> {
  late final AppServiceClient _client;
  final TextEditingController _searchController = TextEditingController();
  final Map<int, TextEditingController> _segmentControllers = {};
  TaskResultWorkspace? _result;
  String? _error;
  bool _loading = false;
  bool _saving = false;
  bool _reexporting = false;
  bool _dirty = false;
  String _notice = '';
  String? _selectedOutputFormat;
  bool? _selectedBilingual;
  _SegmentFilter _filter = _SegmentFilter.all;

  String get _taskId => widget.taskId?.trim() ?? '';

  @override
  void initState() {
    super.initState();
    _client = AppServiceClient(_resultTransport());
    _searchController.addListener(() {
      if (mounted) setState(() {});
    });
    unawaited(widget.bridge.initializeChild());
    unawaited(_loadResult());
  }

  @override
  void didUpdateWidget(ResultReviewWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.taskId ?? '').trim() == _taskId) return;
    for (final controller in _segmentControllers.values) {
      controller.dispose();
    }
    _segmentControllers.clear();
    if (_searchController.text.isNotEmpty) {
      _searchController.clear();
    }
    setState(() {
      _result = null;
      _error = null;
      _loading = false;
      _saving = false;
      _reexporting = false;
      _dirty = false;
      _notice = '';
      _selectedOutputFormat = null;
      _selectedBilingual = null;
      _filter = _SegmentFilter.all;
    });
    unawaited(_loadResult());
  }

  @override
  void dispose() {
    _searchController.dispose();
    for (final controller in _segmentControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  AppServiceTransport _resultTransport() {
    final override = widget.transportOverride;
    if (override != null) return override;
    return WindowBridgeTransport(widget.bridge);
  }

  Future<void> _loadResult() async {
    final taskId = _taskId;
    if (taskId.isEmpty) {
      setState(() {
        _error = '没有传入任务 ID，无法读取结果。';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _client.openTaskResult(taskId);
      if (!mounted) return;
      _syncSegmentControllers(result);
      setState(() {
        _result = result;
        _selectedOutputFormat ??= _outputFormatFor(result);
        _selectedBilingual ??= result.task.bilingual;
        _loading = false;
        _dirty = false;
        _notice = '';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyResultError(error);
        _loading = false;
      });
    }
  }

  void _syncSegmentControllers(TaskResultWorkspace result) {
    final seen = <int>{};
    for (final segment in result.segments) {
      seen.add(segment.id);
      final existing = _segmentControllers[segment.id];
      if (existing == null) {
        final controller = TextEditingController(text: segment.targetText);
        controller.addListener(() {
          if (!_dirty && mounted) {
            setState(() {
              _dirty = true;
              _notice = '';
            });
          }
        });
        _segmentControllers[segment.id] = controller;
      } else if (!_dirty && existing.text != segment.targetText) {
        existing.text = segment.targetText;
      }
    }
    final stale = _segmentControllers.keys
        .where((id) => !seen.contains(id))
        .toList();
    for (final id in stale) {
      _segmentControllers.remove(id)?.dispose();
    }
  }

  TextEditingController _controllerFor(ResultSegment segment) {
    return _segmentControllers.putIfAbsent(segment.id, () {
      final controller = TextEditingController(text: segment.targetText);
      controller.addListener(() {
        if (!_dirty && mounted) {
          setState(() {
            _dirty = true;
            _notice = '';
          });
        }
      });
      return controller;
    });
  }

  Future<TaskResultWorkspace?> _saveEdits() async {
    final result = _result;
    if (result == null || _saving) return result;
    setState(() {
      _saving = true;
      _error = null;
      _notice = '';
    });
    try {
      final payload = result.segments
          .map(
            (segment) => <String, Object?>{
              ...segment.raw,
              'id': segment.id,
              'start': segment.start,
              'end': segment.end,
              'text_src': segment.sourceText,
              'text_tgt': _controllerFor(segment).text,
            },
          )
          .toList();
      final saved = await _client.resultSegmentsSave(_taskId, payload);
      if (!mounted) return saved;
      _syncSegmentControllers(saved);
      setState(() {
        _result = saved;
        _dirty = false;
        _saving = false;
        _notice = '已保存修改';
      });
      return saved;
    } on Object catch (error) {
      if (!mounted) return null;
      setState(() {
        _error = _friendlyResultError(error);
        _saving = false;
      });
      return null;
    }
  }

  Future<Map<String, Object?>?> _reexport() async {
    var result = _result;
    if (result == null || _reexporting) return null;
    setState(() {
      _reexporting = true;
      _error = null;
      _notice = '';
    });
    try {
      if (_dirty) {
        final saved = await _saveEdits();
        if (saved == null) {
          if (mounted) {
            setState(() => _reexporting = false);
          }
          return null;
        }
        result = saved;
      }
      final reexported = await _client.resultReexport(
        _taskId,
        outputFormat: _exportFormatFor(result),
        bilingual: _exportBilingualFor(result),
      );
      final refreshed = await _client.openTaskResult(_taskId);
      if (!mounted) return reexported;
      _syncSegmentControllers(refreshed);
      setState(() {
        _result = refreshed;
        _dirty = false;
        _reexporting = false;
        _notice = '已重新导出字幕';
      });
      return reexported;
    } on Object catch (error) {
      if (!mounted) return null;
      setState(() {
        _error = _friendlyResultError(error);
        _reexporting = false;
      });
      return null;
    }
  }

  String _outputFormatFor(TaskResultWorkspace result) {
    final formats = result.outputPaths.keys
        .map((format) => format.toLowerCase())
        .toSet();
    if (formats.contains('srt') && formats.contains('ass')) return 'both';
    if (formats.contains('srt')) return 'srt';
    if (formats.contains('ass')) return 'ass';
    if (formats.contains('vtt')) return 'vtt';
    return 'both';
  }

  String _exportFormatFor(TaskResultWorkspace result) {
    return _normalizeOutputFormat(_selectedOutputFormat) ??
        _outputFormatFor(result);
  }

  bool _exportBilingualFor(TaskResultWorkspace result) {
    return _selectedBilingual ?? result.task.bilingual;
  }

  void _setOutputFormat(String format) {
    setState(() {
      _selectedOutputFormat = _normalizeOutputFormat(format);
      _notice = '';
    });
  }

  void _setBilingual(bool value) {
    setState(() {
      _selectedBilingual = value;
      _notice = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return _body();
  }

  Widget _body() {
    if (_loading && _result == null) {
      return const Center(child: Text('读取结果中…', style: T.tBody));
    }
    final error = _error;
    if (error != null) {
      return _EmptyResult(
        title: '结果暂不可用',
        message: error,
        actionLabel: '重试读取',
        onAction: _loadResult,
      );
    }
    final result = _result;
    if (result == null) {
      return _EmptyResult(
        title: '还没有结果',
        message: '完成任务后才能审看字幕结果。',
        actionLabel: '重试读取',
        onAction: _loadResult,
      );
    }
    return _ResultReviewBody(
      result: result,
      loading: _loading,
      dirty: _dirty,
      saving: _saving,
      reexporting: _reexporting,
      notice: _notice,
      selectedOutputFormat: _exportFormatFor(result),
      selectedBilingual: _exportBilingualFor(result),
      filter: _filter,
      searchController: _searchController,
      controllerFor: _controllerFor,
      onRefresh: _loadResult,
      onSave: _saveEdits,
      onOutputFormatChanged: _setOutputFormat,
      onBilingualChanged: _setBilingual,
      onFilterChanged: (filter) => setState(() => _filter = filter),
      onClearSearch: _searchController.clear,
      onReexport: () => unawaited(_reexport()),
    );
  }
}

enum _SegmentFilter { all, issues, emptyTarget }

class _ResultReviewBody extends StatelessWidget {
  const _ResultReviewBody({
    required this.result,
    required this.loading,
    required this.dirty,
    required this.saving,
    required this.reexporting,
    required this.notice,
    required this.selectedOutputFormat,
    required this.selectedBilingual,
    required this.filter,
    required this.searchController,
    required this.controllerFor,
    required this.onRefresh,
    required this.onSave,
    required this.onOutputFormatChanged,
    required this.onBilingualChanged,
    required this.onFilterChanged,
    required this.onClearSearch,
    required this.onReexport,
  });

  final TaskResultWorkspace result;
  final bool loading;
  final bool dirty;
  final bool saving;
  final bool reexporting;
  final String notice;
  final String selectedOutputFormat;
  final bool selectedBilingual;
  final _SegmentFilter filter;
  final TextEditingController searchController;
  final TextEditingController Function(ResultSegment segment) controllerFor;
  final VoidCallback onRefresh;
  final Future<TaskResultWorkspace?> Function() onSave;
  final ValueChanged<String> onOutputFormatChanged;
  final ValueChanged<bool> onBilingualChanged;
  final ValueChanged<_SegmentFilter> onFilterChanged;
  final VoidCallback onClearSearch;
  final VoidCallback onReexport;

  @override
  Widget build(BuildContext context) {
    final segments = result.segments;
    final searchQuery = searchController.text;
    final filteredSegments = segments
        .where((segment) => _matchesFilter(segment, filter, controllerFor))
        .where((segment) => _matchesSearch(segment, searchQuery, controllerFor))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ResultHeader(
          result: result,
          loading: loading,
          dirty: dirty,
          saving: saving,
          reexporting: reexporting,
          notice: notice,
          selectedOutputFormat: selectedOutputFormat,
          selectedBilingual: selectedBilingual,
          filter: filter,
          searchController: searchController,
          onRefresh: onRefresh,
          onSave: onSave,
          onOutputFormatChanged: onOutputFormatChanged,
          onBilingualChanged: onBilingualChanged,
          onFilterChanged: onFilterChanged,
          onClearSearch: onClearSearch,
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
                  padding: EdgeInsets.zero,
                  itemCount: filteredSegments.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: T.s24, color: T.line),
                  itemBuilder: (context, index) => _SegmentRow(
                    segment: filteredSegments[index],
                    controller: controllerFor(filteredSegments[index]),
                    enabled: !saving && !reexporting,
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
    required this.notice,
    required this.selectedOutputFormat,
    required this.selectedBilingual,
    required this.filter,
    required this.searchController,
    required this.onRefresh,
    required this.onSave,
    required this.onOutputFormatChanged,
    required this.onBilingualChanged,
    required this.onFilterChanged,
    required this.onClearSearch,
    required this.onReexport,
  });

  final TaskResultWorkspace result;
  final bool loading;
  final bool dirty;
  final bool saving;
  final bool reexporting;
  final String notice;
  final String selectedOutputFormat;
  final bool selectedBilingual;
  final _SegmentFilter filter;
  final TextEditingController searchController;
  final VoidCallback onRefresh;
  final Future<TaskResultWorkspace?> Function() onSave;
  final ValueChanged<String> onOutputFormatChanged;
  final ValueChanged<bool> onBilingualChanged;
  final ValueChanged<_SegmentFilter> onFilterChanged;
  final VoidCallback onClearSearch;
  final VoidCallback onReexport;

  @override
  Widget build(BuildContext context) {
    final task = result.task;
    final filename = _basename(task.inputFile);
    final formats = subtitleFormatListLabel(result.outputPaths.keys);
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
                  enabled: !loading && !saving && !reexporting,
                ),
                _ReviewButton(
                  label: saving ? '保存中' : '保存修改',
                  icon: Icons.save_outlined,
                  onTap: () => unawaited(onSave()),
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
        const SizedBox(height: T.s16),
        Wrap(
          spacing: T.s8,
          runSpacing: T.s8,
          children: [
            _MetricPill(label: '片段', value: '${result.segments.length}'),
            _MetricPill(label: '问题', value: '${result.issueCount}'),
            _MetricPill(label: '输出', value: formats.isEmpty ? '无记录' : formats),
          ],
        ),
        const SizedBox(height: T.s12),
        _ExportControls(
          selectedOutputFormat: selectedOutputFormat,
          selectedBilingual: selectedBilingual,
          enabled: !saving && !reexporting,
          onOutputFormatChanged: onOutputFormatChanged,
          onBilingualChanged: onBilingualChanged,
        ),
        const SizedBox(height: T.s8),
        _FilterControls(
          selected: filter,
          searchController: searchController,
          enabled: !saving && !reexporting,
          onChanged: onFilterChanged,
          onClearSearch: onClearSearch,
        ),
        if (dirty || notice.isNotEmpty) ...[
          const SizedBox(height: T.s8),
          Text(
            notice.isNotEmpty ? notice : '有未保存修改',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.tCaption.copyWith(
              color: notice.isNotEmpty ? T.ok : T.warn,
              fontWeight: T.wMedium,
            ),
          ),
        ],
      ],
    );
  }
}

class _SegmentRow extends StatelessWidget {
  const _SegmentRow({
    required this.segment,
    required this.controller,
    required this.enabled,
  });

  final ResultSegment segment;
  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final issueLabels = [
      ...segment.issues,
      for (final issue in segment.qualityIssues)
        _stringValue(issue['code']) ?? _stringValue(issue['message']) ?? '质量提示',
    ];
    final engine = [
      segment.provider,
      segment.model,
    ].where((part) => part.trim().isNotEmpty).join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('#${segment.id}', style: T.tSection),
              const SizedBox(height: T.s4),
              Text(segment.timeRangeLabel, style: T.tCaption),
            ],
          ),
        ),
        const SizedBox(width: T.s16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (segment.sourceText.isNotEmpty) ...[
                Text(segment.sourceText, style: T.tBody),
                const SizedBox(height: T.s8),
              ],
              TextField(
                controller: controller,
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
                children: [
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
    );
  }
}

class _ExportControls extends StatelessWidget {
  const _ExportControls({
    required this.selectedOutputFormat,
    required this.selectedBilingual,
    required this.enabled,
    required this.onOutputFormatChanged,
    required this.onBilingualChanged,
  });

  final String selectedOutputFormat;
  final bool selectedBilingual;
  final bool enabled;
  final ValueChanged<String> onOutputFormatChanged;
  final ValueChanged<bool> onBilingualChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: T.s16,
      runSpacing: T.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('导出格式', style: T.tCaption),
            const SizedBox(width: T.s8),
            SegmentedButton<String>(
              showSelectedIcon: false,
              selected: {selectedOutputFormat},
              segments: const [
                ButtonSegment(value: 'srt', label: Text('SRT')),
                ButtonSegment(value: 'ass', label: Text('ASS')),
                ButtonSegment(value: 'both', label: Text('SRT+ASS')),
                ButtonSegment(value: 'vtt', label: Text('VTT')),
              ],
              onSelectionChanged: enabled
                  ? (selection) {
                      final next = selection.isEmpty ? null : selection.first;
                      if (next != null) onOutputFormatChanged(next);
                    }
                  : null,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                foregroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.disabled)) return T.muted;
                  if (states.contains(WidgetState.selected)) {
                    return T.accentStrong;
                  }
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
          ],
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
      ],
    );
  }
}

class _FilterControls extends StatelessWidget {
  const _FilterControls({
    required this.selected,
    required this.searchController,
    required this.enabled,
    required this.onChanged,
    required this.onClearSearch,
  });

  final _SegmentFilter selected;
  final TextEditingController searchController;
  final bool enabled;
  final ValueChanged<_SegmentFilter> onChanged;
  final VoidCallback onClearSearch;

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
        SizedBox(
          width: 220,
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

class _MetricPill extends StatelessWidget {
  const _MetricPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 86),
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: T.tCaption),
          const SizedBox(height: T.s4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.tSection,
          ),
        ],
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
    if (message.isNotEmpty) return message;
    return '读取结果失败：${error.code}';
  }
  return '读取结果失败：$error';
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

String? _normalizeOutputFormat(String? value) {
  final normalized = value?.trim().toLowerCase();
  return switch (normalized) {
    'srt' || 'ass' || 'both' || 'vtt' => normalized,
    'webvtt' => 'vtt',
    _ => null,
  };
}

bool _matchesFilter(
  ResultSegment segment,
  _SegmentFilter filter,
  TextEditingController Function(ResultSegment segment) controllerFor,
) {
  return switch (filter) {
    _SegmentFilter.all => true,
    _SegmentFilter.issues =>
      segment.issues.isNotEmpty || segment.qualityIssues.isNotEmpty,
    _SegmentFilter.emptyTarget => controllerFor(segment).text.trim().isEmpty,
  };
}

bool _matchesSearch(
  ResultSegment segment,
  String query,
  TextEditingController Function(ResultSegment segment) controllerFor,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return true;
  final haystack = [
    segment.sourceText,
    controllerFor(segment).text,
    segment.provider,
    segment.model,
    ...segment.issues,
    for (final issue in segment.qualityIssues) ..._issueSearchTerms(issue),
  ].join('\n').toLowerCase();
  return haystack.contains(needle);
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
  };
}
