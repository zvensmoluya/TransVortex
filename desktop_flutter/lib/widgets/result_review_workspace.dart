import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/task_labels.dart';
import '../services/app_service_client.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';

part 'result_review_workspace/result_review_actions.dart';
part 'result_review_workspace/result_review_draft_controller.dart';
part 'result_review_workspace/result_review_models.dart';
part 'result_review_workspace/result_review_segment_editing.dart';
part 'result_review_workspace/result_review_widgets.dart';

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
  late final _ResultDraftController _draftController;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _segmentScrollController = ScrollController();
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
    _draftController = _ResultDraftController(_handleSegmentDraftChanged);
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
    _draftController.clear();
    for (final focusNode in _segmentFocusNodes.values) {
      focusNode.dispose();
    }
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
    _draftController.dispose();
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

  void _setReviewState(VoidCallback update) => setState(update);

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
