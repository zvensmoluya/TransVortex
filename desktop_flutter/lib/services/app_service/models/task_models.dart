part of '../models.dart';

class TaskEventsPage {
  const TaskEventsPage({
    required this.taskId,
    required this.events,
    required this.cursor,
    required this.nextCursor,
    required this.hasMore,
  });

  final String taskId;
  final List<Object?> events;
  final int cursor;
  final int nextCursor;
  final bool hasMore;

  factory TaskEventsPage.fromJson(Object? value) {
    final map = _stringMap(value);
    return TaskEventsPage(
      taskId: _stringValue(map['task_id']) ?? _stringValue(map['taskId']) ?? '',
      events: _objectList(map['events']),
      cursor: _intValue(map['cursor']) ?? 0,
      nextCursor:
          _intValue(map['next_cursor']) ?? _intValue(map['nextCursor']) ?? 0,
      hasMore: map['has_more'] == true || map['hasMore'] == true,
    );
  }
}

class TaskSubmissionResult {
  const TaskSubmissionResult({
    required this.ok,
    required this.taskId,
    required this.status,
    required this.taskDir,
    required this.terminal,
    required this.message,
    this.raw = const <String, Object?>{},
  });

  final bool ok;
  final String taskId;
  final String status;
  final String taskDir;
  final bool terminal;
  final String message;
  final Map<String, Object?> raw;

  factory TaskSubmissionResult.fromJson(Object? value) {
    final map = _stringMap(value);
    return TaskSubmissionResult(
      ok: map['ok'] == true,
      taskId: _stringValue(map['task_id']) ?? _stringValue(map['taskId']) ?? '',
      status: _stringValue(map['status']) ?? 'unknown',
      taskDir:
          _stringValue(map['task_dir']) ?? _stringValue(map['taskDir']) ?? '',
      terminal: map['terminal'] == true,
      message: _stringValue(map['message']) ?? '',
      raw: map,
    );
  }
}

class RuntimeSnapshot {
  const RuntimeSnapshot({
    required this.active,
    required this.queued,
    required this.interrupted,
    required this.raw,
  });

  final Map<String, Object?> active;
  final List<String> queued;
  final List<String> interrupted;
  final Map<String, Object?> raw;

  factory RuntimeSnapshot.fromJson(Object? value) {
    final map = _stringMap(value);
    return RuntimeSnapshot(
      active: _stringMap(map['active']),
      queued: _stringList(map['queued']),
      interrupted: _stringList(map['interrupted']),
      raw: map,
    );
  }

  String? get activeTaskId {
    return _stringValue(active['task_id']) ?? _stringValue(active['taskId']);
  }
}

class TaskSummary {
  const TaskSummary({
    required this.taskId,
    required this.status,
    required this.inputFile,
    required this.inputType,
    required this.sourceLang,
    required this.targetLang,
    required this.bilingual,
    required this.createdAt,
    required this.updatedAt,
    required this.taskDir,
    required this.outputPath,
    required this.outputPaths,
    required this.error,
    required this.errorInfo,
    required this.runtime,
    required this.settings,
    required this.raw,
  });

  final String taskId;
  final String status;
  final String inputFile;
  final String inputType;
  final String sourceLang;
  final String targetLang;
  final bool bilingual;
  final String createdAt;
  final String updatedAt;
  final String taskDir;
  final String? outputPath;
  final Map<String, String> outputPaths;
  final String? error;
  final Map<String, Object?> errorInfo;
  final Map<String, Object?> runtime;
  final Map<String, Object?> settings;
  final Map<String, Object?> raw;

  factory TaskSummary.fromJson(Object? value) {
    if (value is String) {
      return TaskSummary(
        taskId: value,
        status: 'unknown',
        inputFile: '',
        inputType: '',
        sourceLang: '',
        targetLang: '',
        bilingual: false,
        createdAt: '',
        updatedAt: '',
        taskDir: '',
        outputPath: null,
        outputPaths: const {},
        error: null,
        errorInfo: const {},
        runtime: const {},
        settings: const {},
        raw: {'task_id': value},
      );
    }
    final map = _stringMap(value);
    final settings = _stringMap(map['settings']);
    final inputFile =
        _stringValue(map['input_file']) ?? _stringValue(map['inputFile']) ?? '';
    final inputType = _normalizeInputType(
      _stringValue(map['input_type']) ??
          _stringValue(map['inputType']) ??
          _stringValue(settings['input_type']),
    );
    return TaskSummary(
      taskId: _stringValue(map['task_id']) ?? _stringValue(map['taskId']) ?? '',
      status: _stringValue(map['status']) ?? 'unknown',
      inputFile: inputFile,
      inputType: inputType,
      sourceLang:
          _stringValue(map['source_lang']) ??
          _stringValue(map['sourceLang']) ??
          '',
      targetLang:
          _stringValue(map['target_lang']) ??
          _stringValue(map['targetLang']) ??
          '',
      bilingual: map['bilingual'] == true,
      createdAt:
          _stringValue(map['created_at']) ??
          _stringValue(map['createdAt']) ??
          '',
      updatedAt:
          _stringValue(map['updated_at']) ??
          _stringValue(map['updatedAt']) ??
          '',
      taskDir:
          _stringValue(map['task_dir']) ?? _stringValue(map['taskDir']) ?? '',
      outputPath:
          _stringValue(map['output_path']) ?? _stringValue(map['outputPath']),
      outputPaths: _stringMap(
        map['output_paths'],
      ).map((key, value) => MapEntry(key, '$value')),
      error: _stringValue(map['error']),
      errorInfo: _stringMap(map['error_info']),
      runtime: _stringMap(map['runtime']),
      settings: settings,
      raw: map,
    );
  }

  String get displayName => _pathBasename(inputFile);

  bool get isDone => status == 'DONE';
  bool get isFailed => status == 'FAILED';
  bool get isCancelled => status == 'CANCELLED' || status == 'INTERRUPTED';
  String get runtimeState =>
      (_stringValue(runtime['state']) ?? '').trim().toLowerCase();
  bool get isRuntimeActive =>
      runtimeState == 'running' || runtimeState == 'claimed';
  bool get isRuntimeStale => runtimeState == 'stale';
  bool get isActive =>
      status == 'INIT' ||
      status == 'QUEUED' ||
      status == 'PRECHECK' ||
      status == 'INGEST' ||
      status == 'ASR' ||
      status == 'MEMORY' ||
      status == 'SEGMENT' ||
      status == 'TRANSLATE' ||
      status == 'ALIGN' ||
      status == 'QUALITY' ||
      status == 'EXPORT' ||
      status == 'RUNNING' ||
      status == 'CANCEL_REQUESTED';
  bool get isTerminal => isDone || isFailed || isCancelled;
  bool get canCancel => runtime['can_cancel'] == true;
  bool get canResume => runtime['can_resume'] == true;
  Map<String, Object?> get progressDetail => _stringMap(raw['progress_detail']);
  int get asrDoneCount => _intValue(progressDetail['asr_done_count']) ?? 0;
  int get asrTotalSegments =>
      _intValue(progressDetail['asr_total_segments']) ?? 0;
  int get translationDoneCount =>
      _intValue(progressDetail['translate_done_count']) ?? 0;
  int get translationTotalChunks =>
      _intValue(progressDetail['translate_total_chunks']) ?? 0;
  int get modelRequestCount =>
      _intValue(progressDetail['model_request_count']) ?? 0;
  Map<String, int> get modelRequestCounts => _stringMap(
    progressDetail['model_request_counts'],
  ).map((key, value) => MapEntry(key, _intValue(value) ?? 0));
  Map<String, Object?> get asrUsage => _stringMap(progressDetail['asr_usage']);
  String get asrUsageProvider =>
      (_stringValue(asrUsage['provider']) ?? '').trim().toLowerCase();
  int get asrUsageRequestCount =>
      _nonNegativeInt(asrUsage['request_count']) ?? 0;
  double? get asrUsageCostUsd => _nonNegativeFiniteDouble(asrUsage['cost_usd']);
  double? get asrUsageAudioSeconds =>
      _nonNegativeFiniteDouble(asrUsage['audio_seconds']);
  int? get asrUsageTotalTokens => _nonNegativeInt(asrUsage['total_tokens']);
  int? get asrUsageInputTokens => _nonNegativeInt(asrUsage['input_tokens']);
  int? get asrUsageOutputTokens => _nonNegativeInt(asrUsage['output_tokens']);
  bool get asrUsageComplete => asrUsage['usage_complete'] == true;
  bool get asrUsageCostComplete => asrUsage['cost_complete'] == true;
  bool get hasOpenRouterAsrUsage =>
      asrUsageProvider == 'openrouter' && asrUsageRequestCount > 0;
  bool get hasCompleteOpenRouterAsrUsage =>
      hasOpenRouterAsrUsage && asrUsageComplete && asrUsageCostComplete;
  String get qualityStatus =>
      (_stringValue(progressDetail['quality_status']) ?? '').toUpperCase();
  String get deliveryStatus =>
      (_stringValue(progressDetail['delivery_status']) ?? '').toUpperCase();
  int get qualityResidualIssueCount =>
      _sumNumericLeaves(progressDetail['quality_residual_counts']);
  int get deliveryIssueCount =>
      _sumNumericLeaves(progressDetail['delivery_issue_counts']);
  int get reviewIssueCount => qualityResidualIssueCount + deliveryIssueCount;
  int get resultRevision => _intValue(settings['result_revision']) ?? 0;
  int get resultExportRevision =>
      _intValue(settings['result_export_revision']) ?? 0;
  bool get hasSavedResultPendingExport =>
      isDone && resultRevision > resultExportRevision;
  bool get needsReview =>
      isDone &&
      ({'WARN', 'FAIL'}.contains(qualityStatus) ||
          {'WARN', 'FAIL'}.contains(deliveryStatus) ||
          reviewIssueCount > 0 ||
          hasSavedResultPendingExport);

  double? get latestProgress {
    final progress = _numValue(raw['progress']);
    if (progress != null) return progress.toDouble().clamp(0.0, 1.0);
    final detail = progressDetail;
    final done = _numValue(detail['translate_done_count']);
    final total = _numValue(detail['translate_total_chunks']);
    if (done != null && total != null && total > 0) {
      return (done / total).clamp(0.0, 1.0);
    }
    return null;
  }

  String get displayStatus {
    final checkpoint = _stringValue(raw['checkpoint_status']);
    if (checkpoint != null && checkpoint.isNotEmpty) return checkpoint;
    return status;
  }
}
