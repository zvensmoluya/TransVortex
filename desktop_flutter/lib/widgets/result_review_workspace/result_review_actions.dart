part of '../result_review_workspace.dart';

extension _ResultReviewActions on _ResultReviewWorkspaceState {
  Future<void> _promoteMemoryCandidates() async {
    final result = _result;
    if (result == null || _saving || _reexporting) return;
    final rawCandidates = result.memory['entry_items'];
    final candidates =
        (rawCandidates is List ? rawCandidates : const <Object?>[])
            .map(MemoryEntryItem.fromJson)
            .where((entry) => entry.id.isNotEmpty)
            .toList();
    if (candidates.isEmpty) return;
    final promoted = await showDialog<MemoryPromotionResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => MemoryPromotionDialog(
        client: _client,
        taskId: _taskId,
        candidates: candidates,
      ),
    );
    if (promoted == null || !mounted) return;
    _setReviewState(() {
      _notice = promoted.applied > 0
          ? '已将 ${promoted.applied} 条术语保存到术语库${promoted.conflicts > 0 ? '，其中 ${promoted.conflicts} 条发生冲突' : ''}'
          : '没有新增持久术语';
      _actionError = null;
      _failedAction = null;
    });
  }

  Future<void> _loadResult() async {
    final taskId = _taskId;
    if (taskId.isEmpty) {
      _setReviewState(() {
        _error = '没有传入任务 ID，无法读取结果。';
        _loading = false;
      });
      return;
    }
    _setReviewState(() {
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
      _setReviewState(() {
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
      _setReviewState(() {
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
    final stale = _draftController.sync(
      result,
      force: force,
      hasUnsavedChanges: _dirty,
    );
    for (final id in stale) {
      _segmentFocusNodes.remove(id)?.dispose();
      _segmentKeys.remove(id);
      _expandedTimingSegmentIds.remove(id);
    }
    _timingProblem = _firstTimingProblem(result);
  }

  _SegmentDraft _draftFor(ResultSegment segment) {
    return _draftController.draftFor(segment);
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
    return _draftController.hasModifiedSegments(result);
  }

  void _handleSegmentDraftChanged() {
    if (!mounted || _draftController.syncing) return;
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
    _setReviewState(() {
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
    _draftController.discard(result);
    _setReviewState(() {
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
    if (!_draftController.restore(segment)) return;
    final dirty = _hasModifiedSegments(result);
    _setReviewState(() {
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
    _setReviewState(() {
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
      _setReviewState(() {
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
      _setReviewState(() {
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
    _setReviewState(() {
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
            _setReviewState(() => _reexporting = false);
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
      _setReviewState(() {
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
      _setReviewState(() {
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
    _setReviewState(() {
      _selectedOutputFormat = _normalizeOutputFormat(format);
      _notice = '';
      _actionError = null;
      _failedAction = null;
      _exportedInSession = false;
    });
  }

  void _setBilingual(bool value) {
    _setReviewState(() {
      _selectedBilingual = value;
      _notice = '';
      _actionError = null;
      _failedAction = null;
      _exportedInSession = false;
    });
  }

  void _setBilingualOrder(String value) {
    _setReviewState(() {
      _selectedBilingualOrder = _normalizeBilingualOrder(value);
      _notice = '';
      _actionError = null;
      _failedAction = null;
      _exportedInSession = false;
    });
  }

  void _setPreferSingleLine(bool value) {
    _setReviewState(() {
      _selectedPreferSingleLine = value;
      _notice = '';
      _actionError = null;
      _failedAction = null;
      _exportedInSession = false;
    });
  }
}
