part of '../result_review_workspace.dart';

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
