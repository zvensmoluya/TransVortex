import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    this.onDirtyChanged,
    this.onResultChanged,
    this.focusIssuesInitially = false,
  });

  final String? taskId;
  final WindowStateBridge bridge;
  final AppServiceTransport? transportOverride;
  final ValueChanged<bool>? onDirtyChanged;
  final VoidCallback? onResultChanged;
  final bool focusIssuesInitially;

  @override
  State<ResultReviewWorkspace> createState() => _ResultReviewWorkspaceState();
}

class _ResultReviewWorkspaceState extends State<ResultReviewWorkspace> {
  late final AppServiceClient _client;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _segmentScrollController = ScrollController();
  final Map<int, _SegmentDraft> _segmentDrafts = {};
  final Map<int, FocusNode> _segmentFocusNodes = {};
  final Map<int, GlobalKey> _segmentKeys = {};
  final Set<int> _expandedTimingSegmentIds = {};
  TaskResultWorkspace? _result;
  _TimingProblem? _timingProblem;
  String? _error;
  String? _actionError;
  _FailedReviewAction? _failedAction;
  bool _loading = false;
  bool _saving = false;
  bool _reexporting = false;
  bool _dirty = false;
  bool _exportedInSession = false;
  bool _syncingSegmentDrafts = false;
  String _notice = '';
  String? _selectedOutputFormat;
  bool? _selectedBilingual;
  String? _selectedBilingualOrder;
  bool? _selectedPreferSingleLine;
  _ExportSelection? _exportBaseline;
  _SegmentFilter _filter = _SegmentFilter.all;
  bool _filterInitialized = false;
  int? _selectedSegmentId;

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
    for (final draft in _segmentDrafts.values) {
      draft.dispose();
    }
    for (final focusNode in _segmentFocusNodes.values) {
      focusNode.dispose();
    }
    _segmentDrafts.clear();
    _segmentFocusNodes.clear();
    _segmentKeys.clear();
    _expandedTimingSegmentIds.clear();
    if (_searchController.text.isNotEmpty) {
      _searchController.clear();
    }
    setState(() {
      _result = null;
      _timingProblem = null;
      _error = null;
      _actionError = null;
      _failedAction = null;
      _loading = false;
      _saving = false;
      _reexporting = false;
      _exportedInSession = false;
      _updateDirty(false);
      _notice = '';
      _selectedOutputFormat = null;
      _selectedBilingual = null;
      _selectedBilingualOrder = null;
      _selectedPreferSingleLine = null;
      _exportBaseline = null;
      _filter = _SegmentFilter.all;
      _filterInitialized = false;
      _selectedSegmentId = null;
    });
    unawaited(_loadResult());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _segmentScrollController.dispose();
    for (final draft in _segmentDrafts.values) {
      draft.dispose();
    }
    for (final focusNode in _segmentFocusNodes.values) {
      focusNode.dispose();
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
      _actionError = null;
      _failedAction = null;
    });
    try {
      final result = await _client.openTaskResult(taskId);
      if (!mounted) return;
      _syncSegmentDrafts(result, force: true);
      _initializeExportSelection(result);
      setState(() {
        _result = result;
        if (!_filterInitialized) {
          _filter = widget.focusIssuesInitially && result.issueCount > 0
              ? _SegmentFilter.issues
              : _SegmentFilter.all;
          _filterInitialized = true;
        }
        if (_selectedSegmentId == null && _filter == _SegmentFilter.issues) {
          final issues = _issueSegments(result);
          if (issues.isNotEmpty) _selectedSegmentId = issues.first.id;
        }
        final selected = _segmentById(result.segments, _selectedSegmentId);
        if (selected != null && _segmentHasTimingIssue(selected)) {
          _expandedTimingSegmentIds.add(selected.id);
        }
        final timingProblem = _timingProblem;
        if (timingProblem != null) {
          _expandedTimingSegmentIds.add(timingProblem.segmentId);
        }
        _loading = false;
        _updateDirty(false);
        _actionError = null;
        _failedAction = null;
        _exportedInSession = false;
        _notice = '';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        final message = _friendlyResultError(error);
        if (_result == null) {
          _error = message;
        } else {
          _actionError = message;
          _failedAction = _FailedReviewAction.refresh;
        }
        _loading = false;
      });
    }
  }

  void _syncSegmentDrafts(TaskResultWorkspace result, {bool force = false}) {
    final seen = <int>{};
    _syncingSegmentDrafts = true;
    try {
      for (final segment in result.segments) {
        seen.add(segment.id);
        final existing = _segmentDrafts[segment.id];
        if (existing == null) {
          _segmentDrafts[segment.id] = _SegmentDraft(
            segment: segment,
            onChanged: _handleSegmentDraftChanged,
          );
        } else if (force || !_dirty) {
          existing.sync(segment);
        }
      }
      final stale = _segmentDrafts.keys
          .where((id) => !seen.contains(id))
          .toList();
      for (final id in stale) {
        _segmentDrafts.remove(id)?.dispose();
        _segmentFocusNodes.remove(id)?.dispose();
        _segmentKeys.remove(id);
        _expandedTimingSegmentIds.remove(id);
      }
    } finally {
      _syncingSegmentDrafts = false;
    }
    _timingProblem = _firstTimingProblem(result);
  }

  _SegmentDraft _draftFor(ResultSegment segment) {
    return _segmentDrafts.putIfAbsent(segment.id, () {
      return _SegmentDraft(
        segment: segment,
        onChanged: _handleSegmentDraftChanged,
      );
    });
  }

  FocusNode _focusNodeFor(ResultSegment segment) {
    return _segmentFocusNodes.putIfAbsent(
      segment.id,
      () => FocusNode(debugLabel: 'result-segment-${segment.id}'),
    );
  }

  GlobalKey _keyFor(ResultSegment segment) {
    return _segmentKeys.putIfAbsent(
      segment.id,
      () => GlobalKey(debugLabel: 'result-segment-${segment.id}'),
    );
  }

  bool _hasModifiedSegments(TaskResultWorkspace result) {
    return result.segments.any(
      (segment) => _draftFor(segment).isModified(segment),
    );
  }

  void _handleSegmentDraftChanged() {
    if (!mounted || _syncingSegmentDrafts) return;
    final result = _result;
    if (result == null) return;
    final dirty = _hasModifiedSegments(result);
    final timingProblem = _firstTimingProblem(result);
    final timingProblemChanged = !_sameTimingProblem(
      _timingProblem,
      timingProblem,
    );
    final shouldRebuild =
        _dirty != dirty ||
        timingProblemChanged ||
        _notice.isNotEmpty ||
        _actionError != null ||
        _failedAction != null ||
        _filter == _SegmentFilter.modified ||
        _filter == _SegmentFilter.emptyTarget;
    if (!shouldRebuild) return;
    setState(() {
      _timingProblem = timingProblem;
      _updateDirty(dirty);
      if (dirty) {
        _notice = '';
        _actionError = null;
        _failedAction = null;
        _exportedInSession = false;
      }
    });
  }

  void _updateDirty(bool value) {
    if (_dirty == value) return;
    _dirty = value;
    scheduleMicrotask(() {
      if (mounted) widget.onDirtyChanged?.call(value);
    });
  }

  void _discardEdits() {
    final result = _result;
    if (result == null || !_dirty || _saving || _reexporting) return;
    _syncingSegmentDrafts = true;
    try {
      for (final segment in result.segments) {
        _draftFor(segment).sync(segment);
      }
    } finally {
      _syncingSegmentDrafts = false;
    }
    setState(() {
      _timingProblem = _firstTimingProblem(result);
      _updateDirty(false);
      _notice = '已放弃未保存修改';
      _actionError = null;
      _failedAction = null;
    });
  }

  void _restoreSegment(ResultSegment segment) {
    final result = _result;
    if (result == null || _saving || _reexporting) return;
    final draft = _draftFor(segment);
    if (!draft.isModified(segment)) return;
    _syncingSegmentDrafts = true;
    try {
      draft.sync(segment);
    } finally {
      _syncingSegmentDrafts = false;
    }
    final dirty = _hasModifiedSegments(result);
    setState(() {
      _timingProblem = _firstTimingProblem(result);
      _updateDirty(dirty);
      _notice = dirty ? '' : '已还原片段修改';
      _actionError = null;
      _failedAction = null;
    });
  }

  Future<TaskResultWorkspace?> _saveEdits() async {
    final result = _result;
    if (result == null || _saving) return result;
    final timingProblem = _firstTimingProblem(result);
    if (timingProblem != null) {
      _revealTimingProblem(result, timingProblem);
      return null;
    }
    setState(() {
      _saving = true;
      _actionError = null;
      _failedAction = null;
      _notice = '';
    });
    try {
      final payload = result.segments.map((segment) {
        final draft = _draftFor(segment);
        final timing = _timingDraftValues(draft);
        return <String, Object?>{
          ...segment.raw,
          'id': segment.id,
          'start': timing.start,
          'end': timing.end,
          'text_src': segment.sourceText,
          'text_tgt': draft.targetController.text,
        };
      }).toList();
      final saved = await _client.resultSegmentsSave(_taskId, payload);
      if (!mounted) return saved;
      _syncSegmentDrafts(saved, force: true);
      final filterHasSegments = saved.segments.any(
        (segment) => _matchesFilter(segment, _filter, _draftFor),
      );
      setState(() {
        _result = saved;
        if (_filter != _SegmentFilter.all && !filterHasSegments) {
          _filter = _SegmentFilter.all;
        }
        _updateDirty(false);
        _saving = false;
        _exportedInSession = false;
        _notice = '';
      });
      widget.onResultChanged?.call();
      return saved;
    } on Object catch (error) {
      if (!mounted) return null;
      setState(() {
        _actionError = _friendlyResultError(error);
        _failedAction = _FailedReviewAction.save;
        _saving = false;
      });
      return null;
    }
  }

  Future<Map<String, Object?>?> _reexport() async {
    var result = _result;
    if (result == null || _reexporting) return null;
    final timingProblem = _firstTimingProblem(result);
    if (timingProblem != null) {
      _revealTimingProblem(result, timingProblem);
      return null;
    }
    setState(() {
      _reexporting = true;
      _actionError = null;
      _failedAction = null;
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
        subtitleBilingualOrder: _exportBilingualOrderFor(result),
        subtitlePreferSingleLine: _exportPreferSingleLineFor(result),
      );
      final refreshed = await _client.openTaskResult(_taskId);
      if (!mounted) return reexported;
      _syncSegmentDrafts(refreshed, force: true);
      setState(() {
        _result = refreshed;
        _updateDirty(false);
        _reexporting = false;
        _exportBaseline = _currentExportSelection(refreshed);
        _exportedInSession = true;
        _notice = '';
      });
      widget.onResultChanged?.call();
      return reexported;
    } on Object catch (error) {
      if (!mounted) return null;
      setState(() {
        _actionError = _friendlyResultError(error);
        _failedAction = _FailedReviewAction.reexport;
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
    if (formats.contains('lrc')) return 'lrc';
    return 'both';
  }

  String _exportFormatFor(TaskResultWorkspace result) {
    return _normalizeOutputFormat(_selectedOutputFormat) ??
        _outputFormatFor(result);
  }

  bool _exportBilingualFor(TaskResultWorkspace result) {
    return _selectedBilingual ?? result.task.bilingual;
  }

  String _exportBilingualOrderFor(TaskResultWorkspace result) {
    return _normalizeBilingualOrder(_selectedBilingualOrder) ??
        _exportSelectionFor(result).bilingualOrder;
  }

  bool _exportPreferSingleLineFor(TaskResultWorkspace result) {
    return _selectedPreferSingleLine ??
        _exportSelectionFor(result).preferSingleLine;
  }

  void _initializeExportSelection(TaskResultWorkspace result) {
    if (_exportBaseline != null) return;
    final selection = _exportSelectionFor(result);
    _selectedOutputFormat = selection.outputFormat;
    _selectedBilingual = selection.bilingual;
    _selectedBilingualOrder = selection.bilingualOrder;
    _selectedPreferSingleLine = selection.preferSingleLine;
    _exportBaseline = selection;
  }

  _ExportSelection _exportSelectionFor(TaskResultWorkspace result) {
    final task = result.task;
    final reexportStyle = _stringMap(
      task.settings['reexport_subtitle_ass_style'],
    );
    final taskStyle = _stringMap(task.settings['subtitle_ass_style']);
    final style = reexportStyle.isNotEmpty ? reexportStyle : taskStyle;
    return (
      outputFormat: _outputFormatFor(result),
      bilingual:
          _boolValue(task.settings['reexport_bilingual']) ?? task.bilingual,
      bilingualOrder:
          _normalizeBilingualOrder(_stringValue(style['bilingual_order'])) ??
          'target_source',
      preferSingleLine: _boolValue(style['prefer_single_line']) ?? true,
    );
  }

  _ExportSelection _currentExportSelection(TaskResultWorkspace result) {
    return (
      outputFormat: _exportFormatFor(result),
      bilingual: _exportBilingualFor(result),
      bilingualOrder: _exportBilingualOrderFor(result),
      preferSingleLine: _exportPreferSingleLineFor(result),
    );
  }

  bool _hasExportSelectionChanges(TaskResultWorkspace result) {
    final baseline = _exportBaseline;
    return baseline != null && baseline != _currentExportSelection(result);
  }

  _ReviewFlowState _flowState(TaskResultWorkspace result) {
    if (_reexporting) return _ReviewFlowState.exporting;
    if (_saving) return _ReviewFlowState.saving;
    if (_actionError != null) return _ReviewFlowState.failed;
    if (_timingProblem != null) return _ReviewFlowState.invalid;
    if (_dirty) return _ReviewFlowState.dirty;
    if (result.task.hasSavedResultPendingExport ||
        _hasExportSelectionChanges(result)) {
      return _ReviewFlowState.savedPendingExport;
    }
    if (_exportedInSession) return _ReviewFlowState.exported;
    return _ReviewFlowState.synced;
  }

  String _flowMessage(TaskResultWorkspace result) {
    return switch (_flowState(result)) {
      _ReviewFlowState.synced => _notice.isNotEmpty ? _notice : '字幕内容与已导出文件一致',
      _ReviewFlowState.dirty => '有未保存修改',
      _ReviewFlowState.saving => '正在保存字幕修改…',
      _ReviewFlowState.savedPendingExport =>
        result.task.hasSavedResultPendingExport
            ? '修改已保存，字幕文件尚未更新'
            : '交付方案已调整，尚未重新导出',
      _ReviewFlowState.exporting => '正在生成新的字幕文件…',
      _ReviewFlowState.exported => '字幕文件已更新',
      _ReviewFlowState.failed => _actionError ?? '操作没有完成，请重试。',
      _ReviewFlowState.invalid =>
        '片段 #${_timingProblem?.segmentId ?? ''}：${_timingProblem?.message ?? '时间码需要修正'}',
    };
  }

  void _setOutputFormat(String format) {
    setState(() {
      _selectedOutputFormat = _normalizeOutputFormat(format);
      _notice = '';
      _actionError = null;
      _failedAction = null;
      _exportedInSession = false;
    });
  }

  void _setBilingual(bool value) {
    setState(() {
      _selectedBilingual = value;
      _notice = '';
      _actionError = null;
      _failedAction = null;
      _exportedInSession = false;
    });
  }

  void _setBilingualOrder(String value) {
    setState(() {
      _selectedBilingualOrder = _normalizeBilingualOrder(value);
      _notice = '';
      _actionError = null;
      _failedAction = null;
      _exportedInSession = false;
    });
  }

  void _setPreferSingleLine(bool value) {
    setState(() {
      _selectedPreferSingleLine = value;
      _notice = '';
      _actionError = null;
      _failedAction = null;
      _exportedInSession = false;
    });
  }

  List<ResultSegment> _issueSegments(TaskResultWorkspace result) {
    return result.segments
        .where(
          (segment) =>
              segment.issues.isNotEmpty || segment.qualityIssues.isNotEmpty,
        )
        .toList(growable: false);
  }

  void _selectSegment(ResultSegment segment) {
    if (_selectedSegmentId == segment.id) return;
    setState(() => _selectedSegmentId = segment.id);
  }

  void _toggleTimingEditor(ResultSegment segment) {
    if (_saving || _reexporting) return;
    setState(() {
      _selectedSegmentId = segment.id;
      if (!_expandedTimingSegmentIds.add(segment.id)) {
        _expandedTimingSegmentIds.remove(segment.id);
      }
    });
  }

  void _nudgeTiming(
    ResultSegment segment,
    _TimingField field,
    int milliseconds,
  ) {
    if (_saving || _reexporting) return;
    final draft = _draftFor(segment);
    final controller = field == _TimingField.start
        ? draft.startController
        : draft.endController;
    final original = field == _TimingField.start ? segment.start : segment.end;
    final current = _parseTimecode(controller.text) ?? original;
    final next = (current + milliseconds / 1000).clamp(0.0, double.infinity);
    final nextText = _formatTimecode(next);
    controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    if (!_expandedTimingSegmentIds.contains(segment.id)) {
      setState(() => _expandedTimingSegmentIds.add(segment.id));
    }
  }

  void _normalizeTiming(ResultSegment segment, _TimingField field) {
    final draft = _draftFor(segment);
    final controller = field == _TimingField.start
        ? draft.startController
        : draft.endController;
    final parsed = _parseTimecode(controller.text);
    if (parsed == null) return;
    final normalized = _formatTimecode(parsed);
    if (controller.text == normalized) return;
    controller.value = TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
  }

  _TimingProblem? _firstTimingProblem(TaskResultWorkspace result) {
    for (final segment in result.segments) {
      final timing = _timingDraftValues(_draftFor(segment));
      if (timing.message != null) {
        return _TimingProblem(
          segmentId: segment.id,
          message: timing.message!,
          field: timing.errorField,
        );
      }
    }
    return null;
  }

  void _revealTimingProblem(
    TaskResultWorkspace result,
    _TimingProblem problem,
  ) {
    final segment = _segmentById(result.segments, problem.segmentId);
    if (segment == null) return;
    if (_searchController.text.isNotEmpty) _searchController.clear();
    setState(() {
      _timingProblem = problem;
      _filter = _SegmentFilter.all;
      _filterInitialized = true;
      _selectedSegmentId = segment.id;
      _expandedTimingSegmentIds.add(segment.id);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        _revealSegment(
          segment,
          result.segments.indexOf(segment),
          result.segments.length,
          focusTarget: false,
        ),
      );
    });
  }

  void _navigateIssue(int direction) {
    final result = _result;
    if (result == null || _saving || _reexporting) return;
    final issues = _issueSegments(result);
    if (issues.isEmpty) return;
    final currentIndex = issues.indexWhere(
      (segment) => segment.id == _selectedSegmentId,
    );
    final nextIndex = currentIndex < 0
        ? (direction < 0 ? issues.length - 1 : 0)
        : (currentIndex + direction) % issues.length;
    final normalizedIndex = nextIndex < 0 ? issues.length - 1 : nextIndex;
    final target = issues[normalizedIndex];
    if (_searchController.text.isNotEmpty) {
      _searchController.clear();
    }
    setState(() {
      _filter = _SegmentFilter.issues;
      _filterInitialized = true;
      _selectedSegmentId = target.id;
      if (_segmentHasTimingIssue(target)) {
        _expandedTimingSegmentIds.add(target.id);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_revealSegment(target, normalizedIndex, issues.length));
    });
  }

  Future<void> _revealSegment(
    ResultSegment target,
    int index,
    int itemCount, {
    bool focusTarget = true,
  }) async {
    if (!mounted) return;
    final initialContext = _keyFor(target).currentContext;
    if (initialContext == null && _segmentScrollController.hasClients) {
      final position = _segmentScrollController.position;
      final ratio = itemCount <= 1 ? 0.0 : index / (itemCount - 1);
      final offset = position.maxScrollExtent * ratio;
      await _segmentScrollController.animateTo(
        offset.clamp(position.minScrollExtent, position.maxScrollExtent),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted) return;
    final visibleContext = _keyFor(target).currentContext;
    if (visibleContext != null && visibleContext.mounted) {
      await Scrollable.ensureVisible(
        visibleContext,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        alignment: 0.18,
      );
    }
    if (mounted && focusTarget) _focusNodeFor(target).requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f8): () => _navigateIssue(1),
        const SingleActivator(LogicalKeyboardKey.f8, shift: true): () =>
            _navigateIssue(-1),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          if (_dirty && !_saving && !_reexporting) unawaited(_saveEdits());
        },
      },
      child: FocusTraversalGroup(child: _body()),
    );
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
      selectedOutputFormat: _exportFormatFor(result),
      selectedBilingual: _exportBilingualFor(result),
      selectedBilingualOrder: _exportBilingualOrderFor(result),
      selectedPreferSingleLine: _exportPreferSingleLineFor(result),
      flowState: _flowState(result),
      flowMessage: _flowMessage(result),
      failedAction: _failedAction,
      filter: _filter,
      selectedSegmentId: _selectedSegmentId,
      searchController: _searchController,
      segmentScrollController: _segmentScrollController,
      draftFor: _draftFor,
      focusNodeFor: _focusNodeFor,
      keyFor: _keyFor,
      expandedTimingSegmentIds: _expandedTimingSegmentIds,
      onRefresh: _loadResult,
      onSave: _saveEdits,
      onOutputFormatChanged: _setOutputFormat,
      onBilingualChanged: _setBilingual,
      onBilingualOrderChanged: _setBilingualOrder,
      onPreferSingleLineChanged: _setPreferSingleLine,
      onFilterChanged: (filter) => setState(() {
        _filter = filter;
        _filterInitialized = true;
      }),
      onClearSearch: _searchController.clear,
      onDiscardEdits: _discardEdits,
      onRestoreSegment: _restoreSegment,
      onSelectSegment: _selectSegment,
      onToggleTiming: _toggleTimingEditor,
      onNudgeTiming: _nudgeTiming,
      onNormalizeTiming: _normalizeTiming,
      onPreviousIssue: () => _navigateIssue(-1),
      onNextIssue: () => _navigateIssue(1),
      onReexport: () => unawaited(_reexport()),
    );
  }
}

typedef _ExportSelection = ({
  String outputFormat,
  bool bilingual,
  String bilingualOrder,
  bool preferSingleLine,
});

enum _ReviewFlowState {
  synced,
  dirty,
  invalid,
  saving,
  savedPendingExport,
  exporting,
  exported,
  failed,
}

enum _FailedReviewAction { refresh, save, reexport }

enum _SegmentFilter { all, issues, emptyTarget, modified }

enum _TimingField { start, end }

class _TimingProblem {
  const _TimingProblem({
    required this.segmentId,
    required this.message,
    required this.field,
  });

  final int segmentId;
  final String message;
  final _TimingField? field;
}

class _TimingDraftValues {
  const _TimingDraftValues({
    required this.start,
    required this.end,
    this.message,
    this.errorField,
  });

  final double? start;
  final double? end;
  final String? message;
  final _TimingField? errorField;
}

class _SegmentDraft {
  _SegmentDraft({
    required ResultSegment segment,
    required VoidCallback onChanged,
  }) : targetController = TextEditingController(text: segment.targetText),
       startController = TextEditingController(
         text: _formatTimecode(segment.start),
       ),
       endController = TextEditingController(
         text: _formatTimecode(segment.end),
       ) {
    targetController.addListener(onChanged);
    startController.addListener(onChanged);
    endController.addListener(onChanged);
  }

  final TextEditingController targetController;
  final TextEditingController startController;
  final TextEditingController endController;
  late final Listenable listenable = Listenable.merge([
    targetController,
    startController,
    endController,
  ]);

  void sync(ResultSegment segment) {
    final start = _formatTimecode(segment.start);
    final end = _formatTimecode(segment.end);
    if (targetController.text != segment.targetText) {
      targetController.text = segment.targetText;
    }
    if (startController.text != start) startController.text = start;
    if (endController.text != end) endController.text = end;
  }

  bool hasTimingChanges(ResultSegment segment) {
    final start = _parseTimecode(startController.text);
    final end = _parseTimecode(endController.text);
    return start == null ||
        end == null ||
        !_sameTimestamp(start, segment.start) ||
        !_sameTimestamp(end, segment.end);
  }

  bool isModified(ResultSegment segment) {
    return targetController.text != segment.targetText ||
        hasTimingChanges(segment);
  }

  void dispose() {
    targetController.dispose();
    startController.dispose();
    endController.dispose();
  }
}

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
