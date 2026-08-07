part of '../result_review_workspace.dart';

extension _ResultReviewSegmentEditing on _ResultReviewWorkspaceState {
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
    _setReviewState(() => _selectedSegmentId = segment.id);
  }

  void _toggleTimingEditor(ResultSegment segment) {
    if (_saving || _reexporting) return;
    _setReviewState(() {
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
      _setReviewState(() => _expandedTimingSegmentIds.add(segment.id));
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
    _setReviewState(() {
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
    _setReviewState(() {
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
}
