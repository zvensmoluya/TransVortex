part of '../result_review_workspace.dart';

/// Owns editable segment controllers and their synchronization with the last
/// authoritative result snapshot. Focus, scrolling, filters, and RPC actions
/// remain window concerns.
class _ResultDraftController {
  _ResultDraftController(this._onChanged);

  final VoidCallback _onChanged;
  final Map<int, _SegmentDraft> _drafts = {};
  bool _syncing = false;

  bool get syncing => _syncing;

  _SegmentDraft draftFor(ResultSegment segment) {
    return _drafts.putIfAbsent(segment.id, () {
      return _SegmentDraft(segment: segment, onChanged: _onChanged);
    });
  }

  List<int> sync(
    TaskResultWorkspace result, {
    bool force = false,
    required bool hasUnsavedChanges,
  }) {
    final seen = <int>{};
    final stale = <int>[];
    _syncing = true;
    try {
      for (final segment in result.segments) {
        seen.add(segment.id);
        final existing = _drafts[segment.id];
        if (existing == null) {
          _drafts[segment.id] = _SegmentDraft(
            segment: segment,
            onChanged: _onChanged,
          );
        } else if (force || !hasUnsavedChanges) {
          existing.sync(segment);
        }
      }
      stale.addAll(_drafts.keys.where((id) => !seen.contains(id)));
      for (final id in stale) {
        _drafts.remove(id)?.dispose();
      }
    } finally {
      _syncing = false;
    }
    return stale;
  }

  bool hasModifiedSegments(TaskResultWorkspace result) {
    return result.segments.any(
      (segment) => draftFor(segment).isModified(segment),
    );
  }

  void discard(TaskResultWorkspace result) {
    _syncing = true;
    try {
      for (final segment in result.segments) {
        draftFor(segment).sync(segment);
      }
    } finally {
      _syncing = false;
    }
  }

  bool restore(ResultSegment segment) {
    final draft = draftFor(segment);
    if (!draft.isModified(segment)) return false;
    _syncing = true;
    try {
      draft.sync(segment);
    } finally {
      _syncing = false;
    }
    return true;
  }

  void clear() {
    for (final draft in _drafts.values) {
      draft.dispose();
    }
    _drafts.clear();
  }

  void dispose() => clear();
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
