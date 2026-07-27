import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/app_service_client.dart';
import '../services/local_service_controller.dart';
import '../services/path_opener.dart';
import 'reasoning_effort.dart';
import 'session.dart';
import 'task_labels.dart';

enum MainRecoveryTarget {
  retry,
  cancel,
  resume,
  translationSettings,
  asrSettings,
  pickSource,
  outputDirectory,
  reexport,
  reexportDirectory,
  taskProcessing,
}

@immutable
class MainSourceDraft {
  const MainSourceDraft({
    required this.name,
    required this.path,
    required this.kind,
    this.unsupportedReason,
  });

  final String name;
  final String path;
  final SourceKind kind;
  final String? unsupportedReason;

  bool get supported => unsupportedReason == null;
}

@immutable
class MainFailureView {
  const MainFailureView({
    required this.reason,
    required this.actionLabel,
    required this.target,
  });

  final String reason;
  final String actionLabel;
  final MainRecoveryTarget target;
}

@immutable
class HomeTaskReminder {
  const HomeTaskReminder({
    required this.taskId,
    required this.sourceName,
    required this.reason,
    required this.resumableCount,
  });

  final String taskId;
  final String sourceName;
  final String reason;
  final int resumableCount;
}

@immutable
class TaskOption {
  const TaskOption({
    required this.label,
    required this.configured,
    this.provider,
    this.model,
  });

  final String label;
  final bool configured;
  final String? provider;
  final String? model;
}

enum TranslationChoiceSource { profile, direct, task }

@immutable
class TranslationRuntimeChoice {
  const TranslationRuntimeChoice({
    required this.label,
    required this.configured,
    required this.routing,
    required this.source,
    this.detail = '',
    this.provider,
    this.model,
  });

  final String label;
  final String detail;
  final bool configured;
  final String? provider;
  final String? model;
  final Map<String, Object?> routing;
  final TranslationChoiceSource source;
}

enum MainRunStage {
  queued,
  precheck,
  ingest,
  asr,
  memory,
  segment,
  translate,
  align,
  quality,
  export,
  cancelling,
}

@immutable
class MainRunProgress {
  const MainRunProgress({
    required this.stage,
    required this.title,
    required this.detail,
    required this.overallProgress,
    required this.phaseProgress,
    required this.phaseIndex,
    this.phaseCount = 9,
    this.counter = '',
    this.activity = '',
  });

  final MainRunStage stage;
  final String title;
  final String detail;
  final double overallProgress;
  final double phaseProgress;
  final int phaseIndex;
  final int phaseCount;
  final String counter;
  final String activity;

  MainRunProgress copyWith({
    MainRunStage? stage,
    String? title,
    String? detail,
    double? overallProgress,
    double? phaseProgress,
    int? phaseIndex,
    int? phaseCount,
    String? counter,
    String? activity,
  }) {
    return MainRunProgress(
      stage: stage ?? this.stage,
      title: title ?? this.title,
      detail: detail ?? this.detail,
      overallProgress: overallProgress ?? this.overallProgress,
      phaseProgress: phaseProgress ?? this.phaseProgress,
      phaseIndex: phaseIndex ?? this.phaseIndex,
      phaseCount: phaseCount ?? this.phaseCount,
      counter: counter ?? this.counter,
      activity: activity ?? this.activity,
    );
  }
}

@immutable
class MainWindowViewModel {
  const MainWindowViewModel({
    required this.state,
    required this.statusLine,
    required this.taskId,
    required this.source,
    required this.translationLabel,
    required this.translationDetail,
    required this.translationConfigured,
    required this.asrLabel,
    required this.asrConfigured,
    required this.translationOptions,
    required this.translationDirectOptions,
    required this.asrOptions,
    required this.sourceLang,
    required this.targetLang,
    required this.bilingual,
    required this.formats,
    required this.termsEnabled,
    required this.runningText,
    required this.progress,
    required this.canceling,
    required this.outputPaths,
    required this.outputDirectory,
    required this.failure,
    required this.homeTaskReminder,
    required this.submitting,
    this.sourceNeedsAsr,
    this.sourceInspectionPending = false,
    this.runProgress,
    this.completionNotice,
    this.reasoningLabel = '由服务决定',
    this.reasoningDetail = '',
    this.reasoningConfigurable = false,
    this.reasoningOptions = const <ReasoningEffortChoice>[],
    this.reasoningSupport = const ReasoningEffortSupport.unsupported(),
  });

  final MainState state;
  final String statusLine;
  final String? taskId;
  final MainSourceDraft? source;
  final String translationLabel;
  final String translationDetail;
  final bool translationConfigured;
  final String asrLabel;
  final bool asrConfigured;
  final List<TranslationRuntimeChoice> translationOptions;
  final List<TranslationRuntimeChoice> translationDirectOptions;
  final List<TaskOption> asrOptions;
  final String sourceLang;
  final String targetLang;
  final bool bilingual;
  final List<String> formats;
  final bool termsEnabled;
  final String? runningText;
  final double progress;
  final bool canceling;
  final Map<String, String> outputPaths;
  final String? outputDirectory;
  final MainFailureView? failure;
  final HomeTaskReminder? homeTaskReminder;
  final bool submitting;
  final bool? sourceNeedsAsr;
  final bool sourceInspectionPending;
  final MainRunProgress? runProgress;
  final String? completionNotice;
  final String reasoningLabel;
  final String reasoningDetail;
  final bool reasoningConfigurable;
  final List<ReasoningEffortChoice> reasoningOptions;
  final ReasoningEffortSupport reasoningSupport;

  bool get hasSource => source != null;
  bool get requiresAsr => sourceNeedsAsr ?? source?.kind != SourceKind.subtitle;
}

class MainWindowController extends ChangeNotifier {
  MainWindowController({
    required LocalServiceController service,
    PathOpener? pathOpener,
  }) : service = service,
       _pathOpener = pathOpener ?? SystemPathOpener() {
    service.addListener(_applyServiceSnapshot);
    _view = _buildView();
  }

  final LocalServiceController service;
  final PathOpener _pathOpener;
  Timer? _taskPoll;
  MainSourceDraft? _source;
  String _sourceLang = 'auto';
  String _targetLang = 'zh-CN';
  bool _bilingual = true;
  List<String> _formats = const ['SRT', 'ASS'];
  bool _termsEnabled = true;
  String? _outputDirectory;
  String? _taskId;
  bool _submitting = false;
  bool _canceling = false;
  bool _completed = false;
  bool _running = false;
  double _progress = 0;
  String? _statusText;
  MainRunProgress? _runProgress;
  String _eventActivity = '';
  String? _completionNotice;
  Map<String, String> _outputPaths = const {};
  MainFailureView? _failure;
  int _eventCursor = 0;
  List<Map<String, Object?>> _recentEvents = const [];
  TranslationRuntimeChoice? _selectedTranslation;
  String? _selectedReasoningEffort;
  TaskOption? _selectedAsr;
  MediaInspection? _sourceInspection;
  String? _sourceInspectionLanguage;
  int _sourceInspectionGeneration = 0;
  Future<MediaInspection>? _videoInspectionFuture;
  int? _videoInspectionFutureGeneration;
  String? _videoInspectionFutureLanguage;
  String? _videoInspectionFuturePath;
  final Set<String> _dismissedHomeTaskReminderIds = <String>{};

  late MainWindowViewModel _view;

  MainWindowViewModel get view => _view;

  @override
  void dispose() {
    _taskPoll?.cancel();
    service.removeListener(_applyServiceSnapshot);
    super.dispose();
  }

  Future<void> startService() async {
    await service.start();
    _applyServiceSnapshot();
  }

  void pickSource(String path, {String? name}) {
    final displayName = name ?? _basename(path);
    final kind = _kindOf(displayName);
    final unsupported =
        kind == SourceKind.subtitle &&
            !displayName.toLowerCase().endsWith('.srt')
        ? '字幕输入暂时只支持 SRT；ASS / VTT / LRC 目前只能作为输出格式。'
        : null;
    _source = MainSourceDraft(
      name: displayName,
      path: path,
      kind: kind,
      unsupportedReason: unsupported,
    );
    _sourceInspectionGeneration += 1;
    _discardVideoInspectionFuture();
    _sourceInspection = switch (kind) {
      SourceKind.subtitle => const MediaInspection(
        kind: 'subtitle',
        sourceMode: 'subtitle_file',
        needsAsr: false,
      ),
      SourceKind.audio => const MediaInspection(
        kind: 'audio',
        sourceMode: 'asr',
        needsAsr: true,
      ),
      SourceKind.video => null,
    };
    _sourceInspectionLanguage = kind == SourceKind.video ? null : _sourceLang;
    _outputDirectory = null;
    _taskId = null;
    _statusText = null;
    _runProgress = null;
    _eventActivity = '';
    _completionNotice = null;
    _completed = false;
    _running = false;
    _canceling = false;
    _progress = 0;
    _outputPaths = const {};
    _failure = unsupported == null
        ? null
        : MainFailureView(
            reason: unsupported,
            actionLabel: '重新选择片源',
            target: MainRecoveryTarget.pickSource,
          );
    _recentEvents = const [];
    _eventCursor = 0;
    _publish();
    if (kind == SourceKind.video && service.client != null) {
      unawaited(_inspectCurrentVideo(showFailure: false));
    }
  }

  void removeSource() {
    _taskPoll?.cancel();
    _taskPoll = null;
    _source = null;
    _sourceInspectionGeneration += 1;
    _discardVideoInspectionFuture();
    _sourceInspection = null;
    _sourceInspectionLanguage = null;
    _outputDirectory = null;
    _taskId = null;
    _statusText = null;
    _runProgress = null;
    _eventActivity = '';
    _completionNotice = null;
    _completed = false;
    _running = false;
    _canceling = false;
    _progress = 0;
    _outputPaths = const {};
    _failure = null;
    _recentEvents = const [];
    _eventCursor = 0;
    _publish();
  }

  void setBilingual(bool value) {
    _bilingual = value;
    _publish();
  }

  void setSourceLang(String value) {
    final normalized = value.trim();
    _sourceLang = normalized.isEmpty ? 'auto' : normalized;
    if (_source?.kind == SourceKind.video) {
      _sourceInspectionGeneration += 1;
      _discardVideoInspectionFuture();
      _sourceInspection = null;
      _sourceInspectionLanguage = null;
      if (service.client != null) {
        unawaited(_inspectCurrentVideo(showFailure: false));
      }
    }
    _publish();
  }

  void setTargetLang(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return;
    _targetLang = normalized;
    _publish();
  }

  void setFormats(List<String> value) {
    if (value.isEmpty) return;
    _formats = List.unmodifiable(value);
    _publish();
  }

  void setTermsEnabled(bool value) {
    _termsEnabled = value;
    _publish();
  }

  void setOutputDirectory(String? path) {
    final normalized = path?.trim();
    _outputDirectory = normalized == null || normalized.isEmpty
        ? null
        : normalized;
    _publish();
  }

  void selectTranslation(TranslationRuntimeChoice option) {
    final selectedEffort = _selectedReasoningEffort;
    _selectedTranslation = option;
    if (selectedEffort != null) {
      final primary = _asStringMap(option.routing['primary']);
      final support = reasoningEffortSupportFor(
        service.snapshot.desktopSnapshot,
        providerName: '${primary['provider'] ?? option.provider ?? ''}',
        model: '${primary['model'] ?? option.model ?? ''}',
        currentValue: reasoningEffortAuto,
      );
      final normalized = normalizeReasoningEffort(selectedEffort);
      if (!support.supported ||
          !support.choices.any((choice) => choice.value == normalized)) {
        _selectedReasoningEffort = null;
      }
    }
    _publish();
  }

  void selectReasoningEffort(ReasoningEffortChoice option) {
    selectReasoningEffortValue(option.value);
  }

  void selectReasoningEffortValue(String value) {
    _selectedReasoningEffort = normalizeReasoningEffort(value);
    _publish();
  }

  void selectAsr(TaskOption option) {
    _selectedAsr = option;
    _publish();
  }

  @visibleForTesting
  void applyFailureForTesting(Object error) {
    _failure = _failureFromError(error);
    _running = false;
    _completed = false;
    _publish();
  }

  void applySmokeTask(TaskSummary task) {
    _applyTask(task);
    _publish();
  }

  Future<void> submitRun() async {
    if (_submitting) return;
    final source = _source;
    if (source == null) return;
    if (!source.supported) {
      _failure = MainFailureView(
        reason: source.unsupportedReason!,
        actionLabel: '重新选择片源',
        target: MainRecoveryTarget.pickSource,
      );
      _publish();
      return;
    }
    final readiness = service.snapshot.desktopSnapshot?.configReadiness;
    if (readiness != null && !readiness.translationConfigured) {
      _failure = null;
      _publish();
      return;
    }
    if (source.kind == SourceKind.video &&
        !await _inspectCurrentVideo(showFailure: true)) {
      return;
    }
    if (readiness != null && _requiresAsr && !readiness.asrConfigured) {
      _failure = null;
      _publish();
      return;
    }
    _submitting = true;
    _running = true;
    _completed = false;
    _canceling = false;
    _progress = 0;
    _statusText = '正在排队';
    _runProgress = const MainRunProgress(
      stage: MainRunStage.queued,
      title: '等待接单',
      detail: '任务已交给本地制作队列',
      overallProgress: 0,
      phaseProgress: 0,
      phaseIndex: 0,
    );
    _eventActivity = '';
    _completionNotice = null;
    _failure = null;
    _publish();
    try {
      await service.start();
      final client = service.client;
      if (client == null) throw StateError('本地服务未连接');
      final result = await client.submitRun(buildRunRequest());
      _taskId = result.taskId;
      _statusText = result.status.isEmpty ? result.message : result.status;
      _running = true;
      _completed = false;
      _eventCursor = 0;
      _recentEvents = const [];
      _eventActivity = '';
      _ensureTaskPolling();
      await refreshSnapshot();
    } on Object catch (error) {
      _running = false;
      _canceling = false;
      _runProgress = null;
      _failure = _failureFromError(error);
      _publish();
    } finally {
      _submitting = false;
      _publish();
    }
  }

  Future<void> cancelRun() async {
    final taskId = _taskId;
    if (taskId == null) {
      _running = false;
      _canceling = false;
      _progress = 0;
      _runProgress = null;
      _publish();
      return;
    }
    _canceling = true;
    _statusText = '正在取消';
    _eventActivity = '';
    _runProgress =
        (_runProgress ??
                const MainRunProgress(
                  stage: MainRunStage.queued,
                  title: '正在取消',
                  detail: '等待当前步骤安全停下',
                  overallProgress: 0,
                  phaseProgress: 0,
                  phaseIndex: 0,
                ))
            .copyWith(
              stage: MainRunStage.cancelling,
              title: '正在取消',
              detail: '等待当前步骤安全停下',
              activity: '',
            );
    _publish();
    try {
      final cancelledTask = await service.client?.cancel(taskId);
      if (cancelledTask != null) _applyTask(cancelledTask);
      await refreshSnapshot();
    } on Object catch (error) {
      _canceling = false;
      _failure = _failureFromError(
        error,
        fallbackAction: '重试取消',
        fallbackTarget: MainRecoveryTarget.cancel,
        forceFallback: true,
      );
      _publish();
    }
  }

  Future<void> resumeRun() async {
    if (_submitting) return;
    final taskId = _taskId;
    if (taskId == null || taskId.isEmpty) {
      _failure = const MainFailureView(
        reason: '还没有可继续的任务',
        actionLabel: '重试',
        target: MainRecoveryTarget.retry,
      );
      _publish();
      return;
    }
    _submitting = true;
    _running = true;
    _completed = false;
    _canceling = false;
    _statusText = '正在继续任务';
    _runProgress = const MainRunProgress(
      stage: MainRunStage.queued,
      title: '等待接单',
      detail: '正在从上次中断处继续',
      overallProgress: 0,
      phaseProgress: 0,
      phaseIndex: 0,
    );
    _eventActivity = '';
    _failure = null;
    _publish();
    try {
      await service.start();
      final client = service.client;
      if (client == null) throw StateError('本地服务未连接');
      final result = await client.submitResume(buildResumeRequest());
      _taskId = result.taskId.isEmpty ? taskId : result.taskId;
      _statusText = result.status.isEmpty ? result.message : result.status;
      _eventCursor = 0;
      _recentEvents = const [];
      _ensureTaskPolling();
      await refreshSnapshot();
    } on Object catch (error) {
      _running = false;
      _canceling = false;
      _failure = _failureFromError(error);
      _publish();
    } finally {
      _submitting = false;
      _publish();
    }
  }

  Future<void> retryRun() => submitRun();

  Future<void> resumeHomeTaskReminder() async {
    final task = _homeTaskReminderTask(service.snapshot.desktopSnapshot);
    if (task == null) {
      await refreshSnapshot();
      final refreshed = _homeTaskReminderTask(service.snapshot.desktopSnapshot);
      if (refreshed == null) {
        throw StateError('没有可继续的历史任务');
      }
      return _resumeReminderTask(refreshed);
    }
    return _resumeReminderTask(task);
  }

  Future<void> _resumeReminderTask(TaskSummary task) async {
    if (!task.canResume) {
      _dismissedHomeTaskReminderIds.add(task.taskId);
      await refreshSnapshot();
      _publish();
      throw StateError('这个任务现在不能继续了');
    }
    _applyTask(task);
    _publish();
    await resumeRun();
  }

  void dismissHomeTaskReminder(String taskId) {
    final normalized = taskId.trim();
    if (normalized.isEmpty) return;
    final tasks = _homeTaskReminderTasks(service.snapshot.desktopSnapshot);
    if (tasks.isEmpty) {
      _dismissedHomeTaskReminderIds.add(normalized);
    } else {
      _dismissedHomeTaskReminderIds.addAll(
        tasks.map((task) => task.taskId).where((id) => id.trim().isNotEmpty),
      );
    }
    _publish();
  }

  Future<void> resetForNext() async {
    removeSource();
  }

  Future<void> refreshSnapshot() async {
    try {
      await service.refresh();
      await pollTaskEvents();
    } on Object catch (error) {
      _statusText = '刷新失败：$error';
      _publish();
    }
  }

  Future<void> pollTaskEvents() async {
    final taskId = _taskId;
    final client = service.client;
    if (taskId == null || client == null) return;
    try {
      final previousCursor = _eventCursor;
      final page = await client.taskEvents(taskId, cursor: previousCursor);
      final nextEvents = page.nextCursor > previousCursor
          ? page.events
                .map(_asStringMap)
                .where((event) => event.isNotEmpty)
                .toList()
          : <Map<String, Object?>>[];
      _eventCursor = page.nextCursor > previousCursor
          ? page.nextCursor
          : previousCursor;
      _recentEvents = [..._recentEvents, ...nextEvents];
      if (_recentEvents.length > 12) {
        _recentEvents = _recentEvents.sublist(_recentEvents.length - 12);
      }
      if (nextEvents.isNotEmpty) {
        _eventActivity = _latestStructuredActivity(nextEvents) ?? '';
      }
      if (_runProgress == null || _runProgress?.stage == MainRunStage.queued) {
        final fallback = _runProgressFromEvents(_recentEvents);
        if (fallback != null) {
          _runProgress = fallback.copyWith(activity: _eventActivity);
          _progress = fallback.overallProgress;
          _statusText = fallback.title;
        }
      } else if (_runProgress != null) {
        _runProgress = _runProgress!.copyWith(activity: _eventActivity);
      }
      _publish();
    } on Object catch (error) {
      _statusText = '刷新失败：$error';
      _publish();
    }
  }

  Future<void> openResultFile() async {
    final path = await _existingPrimaryResultPath();
    if (path == null) throw StateError('还没有输出文件记录');
    await _pathOpener.revealFile(path);
  }

  Future<void> openResultFolder() async {
    final path = await _existingPrimaryResultPath();
    final dir = path == null ? null : _parentPath(path);
    if (dir == null || dir.isEmpty) throw StateError('还没有输出目录记录');
    await _pathOpener.openDirectory(dir);
  }

  Future<void> reexportResult() async {
    await _reexportResultTo(outputDirectory: null);
  }

  Future<void> reexportResultToDirectory(String outputDirectory) async {
    final normalized = outputDirectory.trim();
    if (normalized.isEmpty) {
      _failure = const MainFailureView(
        reason: '还没有选择输出目录',
        actionLabel: '选择输出目录',
        target: MainRecoveryTarget.outputDirectory,
      );
      _publish();
      return;
    }
    _outputDirectory = normalized;
    await _reexportResultTo(outputDirectory: normalized);
  }

  Future<void> _reexportResultTo({required String? outputDirectory}) async {
    final taskId = _taskId;
    if (taskId == null) throw StateError('还没有可重新导出的任务');
    try {
      final result = await service.client?.resultReexport(
        taskId,
        outputFormat: outputFormatValue(_formats),
        outputDir: outputDirectory,
        bilingual: _bilingual,
      );
      final outputs = _asStringMap(
        result?['output_paths'],
      ).map((key, value) => MapEntry(key, '$value'));
      if (outputs.isNotEmpty) _outputPaths = outputs;
      _failure = null;
      _completed = true;
      await refreshSnapshot();
    } on Object catch (error) {
      _completed = false;
      _running = false;
      final failure = _failureFromError(
        error,
        fallbackAction: '重新导出',
        fallbackTarget: MainRecoveryTarget.reexport,
      );
      _failure = switch (failure.target) {
        MainRecoveryTarget.outputDirectory => MainFailureView(
          reason: failure.reason,
          actionLabel: failure.actionLabel,
          target: MainRecoveryTarget.reexportDirectory,
        ),
        MainRecoveryTarget.reexport => failure,
        _ => MainFailureView(
          reason: failure.reason,
          actionLabel: '重新导出',
          target: MainRecoveryTarget.reexport,
        ),
      };
      _publish();
      rethrow;
    }
  }

  Map<String, Object?> buildRunRequest() {
    final source = _source;
    if (source == null) throw StateError('还没有片源');
    if (!source.supported) {
      throw StateError(source.unsupportedReason ?? '片源暂不支持');
    }
    final snapshot = service.snapshot.desktopSnapshot;
    final translation = _effectiveTranslationChoice(snapshot);
    final routing = _routingWithReasoningSelection(translation.routing);
    final asr = _effectiveAsrOption(snapshot);
    final requiresAsr = _requestRequiresAsr;
    final outputDirectory = _effectiveOutputDirectory(source);
    final overrides = <String, Object?>{
      'output_format': outputFormatValue(_formats),
      'subtitle_quality_mode': 'balanced',
      ..._memoryGenerationOverrides(),
      if (source.kind == SourceKind.video && _sourceInspection != null)
        'source_mode': _sourceInspection!.sourceMode,
      if (source.kind == SourceKind.video &&
          _sourceInspection?.selectedSubtitleStream['index'] != null)
        'subtitle_track':
            '${_sourceInspection!.selectedSubtitleStream['index']}',
      if (requiresAsr && asr.provider != null && asr.provider!.isNotEmpty)
        'asr_provider': asr.provider,
      if (requiresAsr && asr.model != null && asr.model!.isNotEmpty)
        'asr_model': asr.model,
    };
    return {
      'request_version': 1,
      'input': source.path,
      'input_type': inputTypeFor(source.kind),
      'source_lang': _sourceLang,
      'target_lang': _targetLang,
      'bilingual': _bilingual,
      if (outputDirectory != null && outputDirectory.isNotEmpty)
        'output_dir': outputDirectory,
      if (routing.isNotEmpty) 'routing': routing,
      if (routing.isEmpty &&
          translation.provider != null &&
          translation.provider!.isNotEmpty)
        'provider': translation.provider,
      if (routing.isEmpty &&
          translation.model != null &&
          translation.model!.isNotEmpty)
        'model': translation.model,
      'overrides': overrides,
    };
  }

  Map<String, Object?> buildResumeRequest() {
    final taskId = _taskId;
    if (taskId == null || taskId.isEmpty) {
      throw StateError('还没有可继续的任务');
    }
    return {'request_version': 1, 'task_id': taskId};
  }

  Map<String, Object?> _memoryGenerationOverrides() => {
    if (_termsEnabled) 'memory_enabled': true,
    'memory_bootstrap_enabled': _termsEnabled,
    'memory_patch_enabled': _termsEnabled,
    if (_termsEnabled) 'memory_patch_window_chunks': 3,
  };

  void _applyServiceSnapshot() {
    final snapshot = service.snapshot.desktopSnapshot;
    final task = _taskFromSnapshot(snapshot);
    if (task != null) _applyTask(task);
    _syncSnapshotPolling(snapshot);
    _publish();
  }

  TaskSummary? _taskFromSnapshot(DesktopSnapshot? snapshot) {
    if (snapshot == null) return null;
    final taskId = _taskId;
    if (taskId != null) {
      final selectedTask = snapshot.taskById(taskId);
      if (selectedTask != null) return selectedTask;
    }
    return null;
  }

  void _applyTask(TaskSummary task) {
    if (_taskId != task.taskId) {
      _taskId = task.taskId;
      _eventCursor = 0;
      _recentEvents = const [];
      _eventActivity = '';
    }
    _source ??= MainSourceDraft(
      name: task.displayName,
      path: task.inputFile,
      kind: _kindOf(task.displayName),
    );
    if (task.sourceLang.isNotEmpty) _sourceLang = task.sourceLang;
    if (task.targetLang.isNotEmpty) _targetLang = task.targetLang;
    _bilingual = task.bilingual;
    final pendingCurrentTask =
        !task.isTerminal &&
        task.status == 'QUEUED' &&
        (_running || _submitting);
    _canceling =
        task.status == 'CANCEL_REQUESTED' || (_canceling && !task.isTerminal);
    _running =
        !task.isTerminal &&
        (task.isRuntimeActive || pendingCurrentTask || _canceling);
    _completed = task.isDone;
    var structuredProgress = _runProgressFromTask(
      task,
      activity: _eventActivity,
    );
    if (structuredProgress != null &&
        _runProgress != null &&
        structuredProgress.stage != _runProgress!.stage) {
      _eventActivity = '';
      structuredProgress = structuredProgress.copyWith(activity: '');
    }
    _runProgress = _canceling
        ? MainRunProgress(
            stage: MainRunStage.cancelling,
            title: '正在取消',
            detail: '等待当前步骤安全停下',
            overallProgress: structuredProgress?.overallProgress ?? _progress,
            phaseProgress: 0,
            phaseIndex: structuredProgress?.phaseIndex ?? 0,
          )
        : _running
        ? structuredProgress
        : null;
    _progress = task.isDone
        ? 1
        : (structuredProgress?.overallProgress ??
              task.latestProgress ??
              _progress);
    _outputPaths = task.outputPaths;
    _statusText = structuredProgress?.title ?? _taskStatusLabel(task);
    _completionNotice = task.isDone ? _completionNoticeFromTask(task) : null;
    _failure = task.isFailed || task.isCancelled
        ? _failureFromTask(task)
        : null;
    if (!task.isTerminal && (_running || _canceling)) {
      _ensureTaskPolling();
    }
  }

  void _syncSnapshotPolling(DesktopSnapshot? snapshot) {
    final hasActiveTask =
        _running ||
        _canceling ||
        (snapshot?.tasks.any((task) => task.isActive && !task.isTerminal) ??
            false);
    final hasActiveAsrSetup =
        snapshot?.asrOperations.any((operation) => operation.active) ?? false;
    if (hasActiveTask || hasActiveAsrSetup) {
      _ensureTaskPolling();
      return;
    }
    _taskPoll?.cancel();
    _taskPoll = null;
  }

  void _ensureTaskPolling() {
    if (_taskPoll != null) return;
    _taskPoll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(refreshSnapshot()),
    );
  }

  void _publish() {
    _view = _buildView();
    notifyListeners();
  }

  MainWindowViewModel _buildView() {
    final snapshot = service.snapshot.desktopSnapshot;
    final readiness = snapshot?.configReadiness;
    final translation = _effectiveTranslationChoice(snapshot);
    final reasoning = _reasoningSupport(snapshot, translation);
    final asr = _effectiveAsrOption(snapshot);
    final state = _deriveState(readiness, translation, asr);
    return MainWindowViewModel(
      state: state,
      statusLine: _statusLine(state),
      taskId: _taskId,
      source: _source,
      translationLabel: translation.configured ? translation.label : '需配置',
      translationDetail: translation.configured ? translation.detail : '',
      translationConfigured: translation.configured,
      asrLabel: asr.configured ? asr.label : '需配置',
      asrConfigured: asr.configured,
      translationOptions: _translationOptions(snapshot),
      translationDirectOptions: _translationDirectOptions(snapshot),
      asrOptions: _asrOptions(snapshot),
      sourceLang: _sourceLang,
      targetLang: _targetLang,
      bilingual: _bilingual,
      formats: _formats,
      termsEnabled: _termsEnabled,
      runningText: _statusText,
      progress: _progress,
      canceling: _canceling,
      outputPaths: _outputPaths,
      outputDirectory: _outputDirectory,
      failure: _failure,
      homeTaskReminder: state == MainState.empty
          ? _homeTaskReminder(snapshot)
          : null,
      submitting: _submitting,
      sourceNeedsAsr: _source == null ? null : _requiresAsr,
      sourceInspectionPending: _sourceInspectionPending,
      runProgress: _runProgress,
      completionNotice: _completionNotice,
      reasoningLabel: reasoning.displayLabel,
      reasoningDetail: reasoning.detailLabel,
      reasoningConfigurable: reasoning.supported,
      reasoningOptions: reasoning.choices,
      reasoningSupport: reasoning,
    );
  }

  HomeTaskReminder? _homeTaskReminder(DesktopSnapshot? snapshot) {
    final task = _homeTaskReminderTask(snapshot);
    if (task == null) return null;
    final resumableCount = _homeTaskReminderTasks(snapshot).length;
    return HomeTaskReminder(
      taskId: task.taskId,
      sourceName: task.displayName,
      reason: _homeTaskReminderReason(task),
      resumableCount: resumableCount,
    );
  }

  TaskSummary? _homeTaskReminderTask(DesktopSnapshot? snapshot) {
    final tasks = _homeTaskReminderTasks(snapshot);
    return tasks.isEmpty ? null : tasks.first;
  }

  List<TaskSummary> _homeTaskReminderTasks(DesktopSnapshot? snapshot) {
    if (snapshot == null) return const [];
    return snapshot.tasks
        .where((task) {
          if (!task.canResume) return false;
          if (_dismissedHomeTaskReminderIds.contains(task.taskId)) {
            return false;
          }
          return task.taskId.isNotEmpty;
        })
        .toList(growable: false);
  }

  String _homeTaskReminderReason(TaskSummary task) {
    if (task.errorInfo.isNotEmpty || (task.error ?? '').trim().isNotEmpty) {
      return taskFailurePresentation(
        error: task.error,
        errorInfo: task.errorInfo,
        canResume: task.canResume,
      ).reason;
    }
    if (task.status == 'INTERRUPTED') return '上次任务中断，可以继续。';
    if (task.status == 'CANCELLED') return '上次任务已取消，可以继续。';
    return '上次任务未完成，可以继续。';
  }

  MainState _deriveState(
    ConfigReadiness? readiness,
    TranslationRuntimeChoice translation,
    TaskOption asr,
  ) {
    if (_failure != null) return MainState.failed;
    if (_completed) return MainState.completed;
    if (_running) return MainState.running;
    if (_source == null) return MainState.empty;
    if (_source?.supported == false) return MainState.failed;
    if (readiness == null ||
        !translation.configured ||
        (_requiresAsr && !asr.configured)) {
      return MainState.blocked;
    }
    return MainState.ready;
  }

  bool get _requiresAsr {
    return switch (_source?.kind) {
      null || SourceKind.subtitle => false,
      SourceKind.audio => true,
      SourceKind.video => _sourceInspection?.needsAsr ?? false,
    };
  }

  bool get _requestRequiresAsr {
    return switch (_source?.kind) {
      null || SourceKind.subtitle => false,
      SourceKind.audio => true,
      SourceKind.video => _sourceInspection?.needsAsr ?? true,
    };
  }

  bool get _sourceInspectionPending {
    final source = _source;
    return source?.kind == SourceKind.video &&
        _videoInspectionFuture != null &&
        _videoInspectionFutureGeneration == _sourceInspectionGeneration &&
        _videoInspectionFutureLanguage == _sourceLang &&
        _videoInspectionFuturePath == source?.path;
  }

  Future<bool> _inspectCurrentVideo({required bool showFailure}) async {
    final source = _source;
    if (source == null || source.kind != SourceKind.video) return true;
    if (_sourceInspection != null && _sourceInspectionLanguage == _sourceLang) {
      return _sourceInspection!.available;
    }
    final generation = _sourceInspectionGeneration;
    final sourceLanguage = _sourceLang;
    final inspectionFuture = _videoInspectionFor(
      source: source,
      generation: generation,
      sourceLanguage: sourceLanguage,
    );
    try {
      final inspection = await inspectionFuture;
      if (_source?.path != source.path ||
          generation != _sourceInspectionGeneration ||
          sourceLanguage != _sourceLang) {
        return false;
      }
      _sourceInspection = inspection;
      _sourceInspectionLanguage = sourceLanguage;
      if (!inspection.available && showFailure) {
        _failure = const MainFailureView(
          reason: '没有找到可用的内嵌字幕轨，请改用语音识别或重新选择片源。',
          actionLabel: '重新选择片源',
          target: MainRecoveryTarget.pickSource,
        );
      } else if (inspection.available &&
          _failure?.target == MainRecoveryTarget.pickSource) {
        _failure = null;
      }
      _publish();
      return inspection.available;
    } on Object catch (_) {
      if (_source?.path != source.path ||
          generation != _sourceInspectionGeneration ||
          sourceLanguage != _sourceLang) {
        return false;
      }
      if (showFailure) {
        _failure = const MainFailureView(
          reason: '无法检查视频字幕轨，请重试；如果仍失败，可以换一个文件。',
          actionLabel: '重试',
          target: MainRecoveryTarget.retry,
        );
      }
      _publish();
      return false;
    }
  }

  Future<MediaInspection> _videoInspectionFor({
    required MainSourceDraft source,
    required int generation,
    required String sourceLanguage,
  }) {
    final current = _videoInspectionFuture;
    if (current != null &&
        _videoInspectionFutureGeneration == generation &&
        _videoInspectionFutureLanguage == sourceLanguage &&
        _videoInspectionFuturePath == source.path) {
      return current;
    }

    final next = _loadVideoInspection(source, sourceLanguage);
    _videoInspectionFuture = next;
    _videoInspectionFutureGeneration = generation;
    _videoInspectionFutureLanguage = sourceLanguage;
    _videoInspectionFuturePath = source.path;
    next.then<void>(
      (_) => _clearVideoInspectionFuture(next),
      onError: (_) => _clearVideoInspectionFuture(next),
    );
    _publish();
    return next;
  }

  Future<MediaInspection> _loadVideoInspection(
    MainSourceDraft source,
    String sourceLanguage,
  ) async {
    await service.start();
    final client = service.client;
    if (client == null) throw StateError('本地服务未连接');
    return client.inspectMedia(input: source.path, sourceLang: sourceLanguage);
  }

  void _clearVideoInspectionFuture(Future<MediaInspection> expected) {
    if (!identical(_videoInspectionFuture, expected)) return;
    _discardVideoInspectionFuture();
  }

  void _discardVideoInspectionFuture() {
    _videoInspectionFuture = null;
    _videoInspectionFutureGeneration = null;
    _videoInspectionFutureLanguage = null;
    _videoInspectionFuturePath = null;
  }

  String _statusLine(MainState state) {
    final translationConfigured = _effectiveTranslationChoice(
      service.snapshot.desktopSnapshot,
    ).configured;
    final inspectingVideo =
        _source?.kind == SourceKind.video &&
        _sourceInspection == null &&
        !_running &&
        _failure == null;
    final base = inspectingVideo
        ? '正在检查字幕轨'
        : switch (state) {
            MainState.empty => '等待片源',
            MainState.ready => '就绪 · 可开始',
            MainState.blocked => !translationConfigured ? '需要先配置翻译' : '需要先配置识别',
            MainState.running => '制作中',
            MainState.completed => '已完成',
            MainState.failed => '制作失败',
          };
    return switch (service.snapshot.status) {
      LocalServiceConnectionStatus.starting => '服务启动中 · $base',
      LocalServiceConnectionStatus.ready => '服务已连接 · $base',
      LocalServiceConnectionStatus.degraded => '服务降级 · $base',
      LocalServiceConnectionStatus.unavailable => '服务不可用 · $base',
      LocalServiceConnectionStatus.stopped => '服务已停止 · $base',
      LocalServiceConnectionStatus.idle => base,
    };
  }

  TranslationRuntimeChoice _effectiveTranslationChoice(
    DesktopSnapshot? snapshot,
  ) {
    final selected = _selectedTranslation;
    if (selected != null) return selected;
    final taskChoice = _taskRoutingChoice(snapshot);
    if (taskChoice != null) return taskChoice;
    final activeChoice = _activeProfileChoice(snapshot);
    if (activeChoice != null) return activeChoice;
    return const TranslationRuntimeChoice(
      label: '需配置',
      configured: false,
      routing: {},
      source: TranslationChoiceSource.profile,
    );
  }

  ReasoningEffortSupport _reasoningSupport(
    DesktopSnapshot? snapshot,
    TranslationRuntimeChoice translation,
  ) {
    final primary = _asStringMap(translation.routing['primary']);
    return reasoningEffortSupportFor(
      snapshot,
      providerName: '${primary['provider'] ?? translation.provider ?? ''}',
      model: '${primary['model'] ?? translation.model ?? ''}',
      currentValue:
          _selectedReasoningEffort ??
          primary['reasoning_effort'] ??
          primary['reasoningEffort'],
    );
  }

  Map<String, Object?> _routingWithReasoningSelection(
    Map<String, Object?> routing,
  ) {
    final normalized = _normalizedRouting(routing);
    if (normalized.isEmpty || _selectedReasoningEffort == null) {
      return normalized;
    }
    final primary = _asStringMap(normalized['primary']);
    return {
      ...normalized,
      'primary': {
        ...primary,
        'reasoning_effort': normalizeReasoningEffort(_selectedReasoningEffort),
      },
    };
  }

  TranslationRuntimeChoice? _taskRoutingChoice(DesktopSnapshot? snapshot) {
    final task = _taskFromSnapshot(snapshot);
    if (task == null) return null;
    final routing = _normalizedRouting(_asStringMap(task.settings['routing']));
    if (routing.isEmpty) return null;
    return _choiceFromRouting(
      snapshot,
      routing,
      source: TranslationChoiceSource.task,
      profileName: '本次任务',
    );
  }

  TranslationRuntimeChoice? _activeProfileChoice(DesktopSnapshot? snapshot) {
    if (snapshot == null) return null;
    final activeId = snapshot.activeRoutingProfile;
    RoutingProfileOption? active;
    for (final profile in snapshot.routingProfiles) {
      if (profile.id == activeId) {
        active = profile;
        break;
      }
    }
    active ??= snapshot.routingProfiles.isEmpty
        ? null
        : snapshot.routingProfiles.first;
    if (active == null) return null;
    return _choiceFromProfile(snapshot, active);
  }

  TaskOption _effectiveAsrOption(DesktopSnapshot? snapshot) {
    final selected = _selectedAsr;
    if (selected != null) return selected;
    final provider = snapshot?.asrProviderName;
    final model = snapshot?.asrModel;
    final readiness = snapshot?.configReadiness;
    final label = _asrDisplayLabel(snapshot, provider, model);
    return TaskOption(
      label: label,
      configured: readiness?.asrConfigured ?? false,
      provider: provider,
      model: model,
    );
  }

  List<TranslationRuntimeChoice> _translationOptions(
    DesktopSnapshot? snapshot,
  ) {
    if (snapshot == null) return const [];
    return snapshot.routingProfiles
        .map((profile) => _choiceFromProfile(snapshot, profile))
        .whereType<TranslationRuntimeChoice>()
        .where((choice) => choice.configured)
        .toList(growable: false);
  }

  List<TranslationRuntimeChoice> _translationDirectOptions(
    DesktopSnapshot? snapshot,
  ) {
    if (snapshot == null) return const [];
    return snapshot.providers
        .where((provider) => provider.hasKey)
        .expand((provider) {
          final models = provider.models.where(
            (model) => model.trim().isNotEmpty,
          );
          return models.map((model) {
            final routing = _routingPayload(
              provider: provider.name,
              model: model,
              reasoningEffort: reasoningEffortAuto,
              fallback: const [],
            );
            return TranslationRuntimeChoice(
              label: _modelLabel(model, provider.name),
              detail: '本次直接使用 · 无备用 · 连接 ${provider.name}',
              configured: true,
              provider: provider.name,
              model: model,
              routing: routing,
              source: TranslationChoiceSource.direct,
            );
          });
        })
        .toList(growable: false);
  }

  TranslationRuntimeChoice? _choiceFromProfile(
    DesktopSnapshot snapshot,
    RoutingProfileOption profile,
  ) {
    final routing = _normalizedRouting({
      'primary': {
        'provider': profile.provider,
        'model': profile.model,
        'reasoning_effort': profile.reasoningEffort,
      },
      'fallback': profile.fallback,
    });
    return _choiceFromRouting(
      snapshot,
      routing,
      source: TranslationChoiceSource.profile,
      profileName: _profileDisplayName(profile),
    );
  }

  TranslationRuntimeChoice? _choiceFromRouting(
    DesktopSnapshot? snapshot,
    Map<String, Object?> routing, {
    required TranslationChoiceSource source,
    required String profileName,
  }) {
    final primary = _asStringMap(routing['primary']);
    final provider = '${primary['provider'] ?? ''}'.trim();
    final model = '${primary['model'] ?? ''}'.trim();
    final reasoningEffort = normalizeReasoningEffort(
      primary['reasoning_effort'] ?? primary['reasoningEffort'],
    );
    if (provider.isEmpty || model.isEmpty) return null;
    final fallback = _routeList(routing['fallback']);
    final label = _modelLabel(model, provider);
    final fallbackText = fallback.isEmpty
        ? '无备用'
        : fallback.length == 1
        ? '备用 ${_routeShortLabel(fallback.first)}'
        : '备用 ${fallback.length} 个';
    return TranslationRuntimeChoice(
      label: label,
      detail: '$profileName · $fallbackText · 连接 $provider',
      configured: _providerHasKey(snapshot, provider),
      provider: provider,
      model: model,
      routing: _routingPayload(
        provider: provider,
        model: model,
        reasoningEffort: reasoningEffort,
        fallback: fallback,
      ),
      source: source,
    );
  }

  List<TaskOption> _asrOptions(DesktopSnapshot? snapshot) {
    if (snapshot == null) return const [];
    return snapshot.asrProviders
        .where((provider) => provider.canRun)
        .map(
          (provider) => TaskOption(
            label: _asrDisplayLabel(snapshot, provider.name, provider.model),
            configured: true,
            provider: provider.name,
            model: provider.model.isEmpty ? null : provider.model,
          ),
        )
        .toList(growable: false);
  }

  static String _asrDisplayLabel(
    DesktopSnapshot? snapshot,
    String? providerName,
    String? model,
  ) {
    if (providerName == null || providerName.isEmpty) return '需配置';
    final option = snapshot?.asrProviders.firstWhere(
      (item) => item.name == providerName,
      orElse: () => AsrProviderOption(
        name: providerName,
        kind: 'remote',
        protocol: 'openai_transcriptions',
        model: model ?? '',
      ),
    );
    final label = option?.displayLabel ?? providerName;
    final rawModel = model ?? option?.model ?? '';
    var modelText = whisperModelLabel(rawModel, includeEngine: false);
    if (option?.kind == 'local_worker' && modelText.isNotEmpty) {
      final local = _asStringMap(option?.raw['local']);
      final external = '${local['model_source'] ?? ''}' == 'external';
      if (external) {
        final active = snapshot?.asrActiveExecution;
        final activeUserLabel =
            active != null &&
                active.provider == option?.name &&
                active.model == rawModel
            ? active.modelUserLabel.trim()
            : '';
        if (activeUserLabel.isNotEmpty) modelText = activeUserLabel;
        final modelPath = '${local['model_path'] ?? ''}'.trim();
        for (final registration
            in snapshot?.asrRegisteredModels ??
                const <AsrRegisteredResourceOption>[]) {
          if (registration.resourceId != rawModel ||
              !_sameWindowsPath(registration.path, modelPath)) {
            continue;
          }
          final userLabel = registration.userLabel.trim();
          if (activeUserLabel.isEmpty && userLabel.isNotEmpty) {
            modelText = userLabel;
          }
          break;
        }
      }
      return external ? '$label · $modelText（本地文件夹）' : '$label · $modelText';
    }
    return modelText.isEmpty ? label : '$label · $modelText';
  }

  static bool _sameWindowsPath(String left, String right) {
    if (left.trim().isEmpty || right.trim().isEmpty) return false;
    String normalize(String value) =>
        value.trim().replaceAll('/', r'\').toLowerCase();
    return normalize(left) == normalize(right);
  }

  static bool _providerHasKey(DesktopSnapshot? snapshot, String providerName) {
    if (snapshot == null || providerName.isEmpty) return false;
    for (final provider in snapshot.providers) {
      if (provider.name == providerName) return provider.hasKey;
    }
    return false;
  }

  static String _profileDisplayName(RoutingProfileOption profile) {
    final name = profile.displayName.trim();
    if (profile.id == 'default' ||
        name.isEmpty ||
        name.toLowerCase() == 'default' ||
        name == '默认方案') {
      return '默认模型';
    }
    return name;
  }

  static String _modelLabel(String model, String provider) {
    final trimmed = model.trim();
    if (trimmed.isNotEmpty) return trimmed;
    return provider.trim().isEmpty ? '需配置' : provider.trim();
  }

  static String _routeShortLabel(Map<String, Object?> route) {
    final provider = '${route['provider'] ?? ''}'.trim();
    final model = '${route['model'] ?? ''}'.trim();
    if (model.isEmpty) return provider;
    return model;
  }

  static Map<String, Object?> _normalizedRouting(Map<String, Object?> raw) {
    if (raw.isEmpty) return const {};
    final primary = _asStringMap(raw['primary']);
    final provider = '${primary['provider'] ?? ''}'.trim();
    final model = '${primary['model'] ?? ''}'.trim();
    final reasoningEffort = normalizeReasoningEffort(
      primary['reasoning_effort'] ?? primary['reasoningEffort'],
    );
    if (provider.isEmpty && model.isEmpty) return const {};
    return _routingPayload(
      provider: provider,
      model: model,
      reasoningEffort: reasoningEffort,
      fallback: _routeList(raw['fallback']),
    );
  }

  static List<Map<String, Object?>> _routeList(Object? raw) {
    if (raw is! List) return const [];
    final routes = <Map<String, Object?>>[];
    for (final item in raw) {
      final route = _asStringMap(item);
      final provider = '${route['provider'] ?? ''}'.trim();
      final model = '${route['model'] ?? ''}'.trim();
      if (provider.isEmpty || model.isEmpty) continue;
      routes.add({
        'provider': provider,
        'model': model,
        'reasoning_effort': normalizeReasoningEffort(
          route['reasoning_effort'] ?? route['reasoningEffort'],
        ),
      });
    }
    return routes;
  }

  static Map<String, Object?> _routingPayload({
    required String provider,
    required String model,
    String reasoningEffort = reasoningEffortAuto,
    required List<Map<String, Object?>> fallback,
  }) {
    return {
      'primary': {
        'provider': provider.trim(),
        'model': model.trim(),
        'reasoning_effort': normalizeReasoningEffort(reasoningEffort),
      },
      'fallback': [
        for (final route in fallback)
          {
            'provider': '${route['provider'] ?? ''}'.trim(),
            'model': '${route['model'] ?? ''}'.trim(),
            'reasoning_effort': normalizeReasoningEffort(
              route['reasoning_effort'] ?? route['reasoningEffort'],
            ),
          },
      ],
    };
  }

  MainFailureView _failureFromTask(TaskSummary task) {
    final taskError = (task.error ?? '').trim();
    final infoMessage = '${task.errorInfo['message'] ?? ''}'.trim();
    final presentation = taskFailurePresentation(
      error: taskError.isNotEmpty
          ? taskError
          : infoMessage.isNotEmpty
          ? infoMessage
          : _latestEventMessage(_recentEvents),
      errorInfo: task.errorInfo,
      canResume: task.canResume,
    );
    return MainFailureView(
      reason: presentation.reason,
      actionLabel: presentation.actionLabel,
      target: _mainRecoveryTarget(presentation.target),
    );
  }

  MainFailureView _failureFromError(
    Object error, {
    String fallbackAction = '重试',
    MainRecoveryTarget fallbackTarget = MainRecoveryTarget.retry,
    bool forceFallback = false,
  }) {
    TaskFailurePresentation presentation;
    if (error is RpcRemoteException) {
      final details = _asStringMap(error.details);
      final info = _asStringMap(details['error_info']);
      presentation = taskFailurePresentation(
        error: error.message,
        errorInfo: {
          ...info,
          if ('${info['code'] ?? ''}'.trim().isEmpty) 'code': error.code,
        },
      );
    } else {
      presentation = taskFailurePresentation(error: '$error');
    }
    final useFallback =
        forceFallback || presentation.target == TaskFailureRecoveryTarget.retry;
    return MainFailureView(
      reason: presentation.reason,
      actionLabel: useFallback ? fallbackAction : presentation.actionLabel,
      target: useFallback
          ? fallbackTarget
          : _mainRecoveryTarget(presentation.target),
    );
  }

  MainRecoveryTarget _mainRecoveryTarget(TaskFailureRecoveryTarget target) {
    return switch (target) {
      TaskFailureRecoveryTarget.none || TaskFailureRecoveryTarget.taskDetails =>
        MainRecoveryTarget.taskProcessing,
      TaskFailureRecoveryTarget.retry => MainRecoveryTarget.retry,
      TaskFailureRecoveryTarget.resume => MainRecoveryTarget.resume,
      TaskFailureRecoveryTarget.translationSettings =>
        MainRecoveryTarget.translationSettings,
      TaskFailureRecoveryTarget.asrSettings => MainRecoveryTarget.asrSettings,
      TaskFailureRecoveryTarget.pickSource => MainRecoveryTarget.pickSource,
      TaskFailureRecoveryTarget.outputDirectory =>
        MainRecoveryTarget.outputDirectory,
      TaskFailureRecoveryTarget.reexport => MainRecoveryTarget.reexport,
    };
  }

  Future<String?> _existingPrimaryResultPath() async {
    final path = await _primaryResultPath();
    if (path == null) return null;
    if (await File(path).exists()) return path;

    final refreshed = await _refreshResultPaths();
    if (refreshed != null && await File(refreshed).exists()) return refreshed;

    _failure = const MainFailureView(
      reason: '结果文件不在原位置了，可能被移动或删除。可以重新导出字幕。',
      actionLabel: '重新导出',
      target: MainRecoveryTarget.reexport,
    );
    _completed = false;
    _publish();
    throw StateError('结果文件不在原位置了，可以重新导出字幕');
  }

  Future<String?> _primaryResultPath() async {
    if (_outputPaths.isNotEmpty) return primaryOutputPath(_outputPaths);
    return _refreshResultPaths();
  }

  Future<String?> _refreshResultPaths() async {
    final taskId = _taskId;
    if (taskId == null) return null;
    final result = await service.client?.resultOpen(taskId);
    final outputs = _asStringMap(
      result?['output_paths'],
    ).map((key, value) => MapEntry(key, '$value'));
    _outputPaths = outputs;
    return primaryOutputPath(outputs);
  }

  static SourceKind _kindOf(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const video = {'mp4', 'mkv', 'mov', 'avi', 'webm', 'flv'};
    const audio = {'mp3', 'wav', 'm4a', 'flac', 'aac', 'ogg'};
    if (audio.contains(ext)) return SourceKind.audio;
    if (ext == 'srt' || ext == 'ass' || ext == 'vtt' || ext == 'lrc') {
      return SourceKind.subtitle;
    }
    if (video.contains(ext)) return SourceKind.video;
    return SourceKind.video;
  }

  static String inputTypeFor(SourceKind kind) {
    return switch (kind) {
      SourceKind.subtitle => 'srt_translate',
      _ => 'video_asr_translate',
    };
  }

  static String outputFormatValue(List<String> formats) {
    final selected = formats.map((item) => item.toLowerCase()).toSet();
    if (selected.contains('srt') && selected.contains('ass')) return 'both';
    if (selected.contains('ass')) return 'ass';
    if (selected.contains('vtt')) return 'vtt';
    if (selected.contains('lrc')) return 'lrc';
    return 'srt';
  }

  static String? primaryOutputPath(Map<String, String> outputs) {
    for (final key in const ['srt', 'ass', 'vtt', 'lrc']) {
      final value = outputs[key]?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    for (final value in outputs.values) {
      final text = value.trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static String? _parentPath(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx <= 0) return null;
    if (idx == 2 && normalized.length > 2 && normalized[1] == ':') {
      return path.substring(0, 3);
    }
    return path.substring(0, idx);
  }

  String? _effectiveOutputDirectory(MainSourceDraft source) {
    final selected = _outputDirectory?.trim();
    if (selected != null && selected.isNotEmpty) return selected;
    return _parentPath(source.path);
  }

  static String _basename(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  static String _taskStatusLabel(TaskSummary task) {
    if (task.status == 'RUNNING' && task.displayStatus != task.status) {
      final stage = _friendlyStageText(task.displayStatus);
      if (stage != null) return stage;
    }
    return _friendlyStatusText(task.status) ??
        taskStageLabel(task.displayStatus);
  }

  static MainRunProgress? _runProgressFromTask(
    TaskSummary task, {
    String activity = '',
  }) {
    if (task.isTerminal && !task.isDone) return null;
    final detail = _asStringMap(task.raw['progress_detail']);
    final stage = task.status == 'CANCEL_REQUESTED'
        ? 'CANCELLING'
        : task.displayStatus.toUpperCase();
    final rawProgress = _number(task.raw['progress']);
    return _runProgressForStage(
      stage: stage,
      detail: detail,
      overallProgress: rawProgress ?? _overallProgressForStage(stage, detail),
      inputType: task.inputType,
      settings: task.settings,
      activity: activity,
    );
  }

  static MainRunProgress? _runProgressFromEvents(
    List<Map<String, Object?>> events,
  ) {
    for (final event in events.reversed) {
      final stage = '${event['stage'] ?? event['status'] ?? ''}'
          .trim()
          .toUpperCase();
      final progress = _number(event['progress']);
      final result = _runProgressForStage(
        stage: stage,
        detail: _asStringMap(event['details']),
        overallProgress: progress ?? _overallProgressForStage(stage, const {}),
        inputType: '',
        settings: const {},
        activity: _latestStructuredActivity(events) ?? '',
      );
      if (result != null) return result;
    }
    return null;
  }

  static MainRunProgress? _runProgressForStage({
    required String stage,
    required Map<String, Object?> detail,
    required double overallProgress,
    required String inputType,
    required Map<String, Object?> settings,
    required String activity,
  }) {
    final normalized = stage.toUpperCase();
    final overall = overallProgress.clamp(0.0, 1.0);
    switch (normalized) {
      case 'INIT':
      case 'QUEUED':
      case 'RUNNING':
        return MainRunProgress(
          stage: MainRunStage.queued,
          title: '等待接单',
          detail: '任务已交给本地制作队列',
          overallProgress: overall,
          phaseProgress: 0,
          phaseIndex: 0,
          activity: activity,
        );
      case 'PRECHECK':
        return MainRunProgress(
          stage: MainRunStage.precheck,
          title: '检查任务',
          detail: '确认片源、模型、凭据和输出目录',
          overallProgress: overall,
          phaseProgress: 0.35,
          phaseIndex: 0,
          activity: activity,
        );
      case 'INGEST':
        final subtitleInput = inputType == 'srt_translate';
        return MainRunProgress(
          stage: MainRunStage.ingest,
          title: subtitleInput ? '读取字幕' : '拆分音频',
          detail: subtitleInput ? '载入原字幕和时间轴' : '提取音轨并按停顿准备语音分窗',
          overallProgress: overall,
          phaseProgress: detail['ingest_done'] == true ? 1 : 0.45,
          phaseIndex: 1,
          activity: activity,
        );
      case 'ASR':
        final done = _integer(detail['asr_done_count']);
        final total = _integer(detail['asr_total_segments']);
        final ratio = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
        return MainRunProgress(
          stage: MainRunStage.asr,
          title: '识别台词',
          detail: total > 0 ? '语音分窗 $done / $total' : '正在识别语音分窗',
          overallProgress: overall,
          phaseProgress: ratio,
          phaseIndex: 2,
          counter: total > 0 ? '$done/$total' : '',
          activity: activity,
        );
      case 'MEMORY':
        final mode = '${detail['memory_current_mode'] ?? ''}';
        final actions = _integer(detail['memory_bootstrap_actions']);
        final requestCount = _integer(detail['model_request_count']);
        return MainRunProgress(
          stage: MainRunStage.memory,
          title: '整理术语',
          detail: actions > 0
              ? '已整理 $actions 条名称与术语候选'
              : mode == 'memory_bootstrap_extract'
              ? '从全片提取名称、称呼和固定表达'
              : mode == 'memory_bootstrap_classify'
              ? '筛选候选并整理成可用术语'
              : mode == 'memory_bootstrap'
              ? '从全片提取名称、称呼和固定译法'
              : '合并预设术语与运行时术语记忆',
          overallProgress: overall,
          phaseProgress: actions > 0 ? 1 : 0.5,
          phaseIndex: 3,
          counter: [
            if (actions > 0) '$actions 条',
            if (requestCount > 0) '模型 $requestCount 次',
          ].join(' · '),
          activity: activity,
        );
      case 'SEGMENT':
        final chunks = _integer(detail['translate_total_chunks']);
        return MainRunProgress(
          stage: MainRunStage.segment,
          title: '编排分片',
          detail: chunks > 0 ? '已规划 $chunks 个翻译分片' : '按模型容量和对白边界规划分片',
          overallProgress: overall,
          phaseProgress: chunks > 0 ? 1 : 0.5,
          phaseIndex: 4,
          counter: chunks > 0 ? '$chunks 片' : '',
          activity: activity,
        );
      case 'TRANSLATE':
        final done = _integer(detail['translate_done_count']);
        final total = _integer(detail['translate_total_chunks']);
        final ratio = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
        final mode = '${detail['translate_current_mode'] ?? 'translate'}';
        final segmentId = _integer(detail['translate_current_segment_id']);
        final recoveryCount = _integer(
          detail['translate_recovery_segment_count'],
        );
        final requestCount = _integer(detail['model_request_count']);
        final modeDetail = switch (mode) {
          'batch_recovery' when recoveryCount > 0 =>
            '批量补回被截断的 $recoveryCount 行字幕',
          'adaptive_split' => '当前分片超出容量，已自动拆小',
          'protocol_recovery' => '正在校正模型返回格式',
          'repair' when segmentId > 0 => '正在修复第 $segmentId 行字幕',
          'memory_patch' => '整理本段新增名称和术语',
          _ => total > 0 ? '翻译分片 $done / $total' : '按分片翻译对白',
        };
        return MainRunProgress(
          stage: MainRunStage.translate,
          title: '翻译字幕',
          detail: modeDetail,
          overallProgress: overall,
          phaseProgress: ratio,
          phaseIndex: 5,
          counter: [
            if (total > 0) '$done/$total',
            if (requestCount > 0) '模型 $requestCount 次',
          ].join(' · '),
          activity: activity,
        );
      case 'ALIGN':
        return MainRunProgress(
          stage: MainRunStage.align,
          title: '对齐时间轴',
          detail: '核对字幕编号、顺序和时间范围',
          overallProgress: overall,
          phaseProgress: 0.55,
          phaseIndex: 6,
          activity: activity,
        );
      case 'QUALITY':
        final status = '${detail['quality_status'] ?? ''}'.toUpperCase();
        final mode = '${detail['quality_current_mode'] ?? ''}';
        final requestCount = _integer(detail['model_request_count']);
        return MainRunProgress(
          stage: MainRunStage.quality,
          title: '检查可读性',
          detail: mode == 'quality_compression'
              ? '压缩阅读速度过快的长字幕'
              : mode == 'quality_reflow'
              ? '重排难读的对白和时间窗口'
              : status == 'FAIL'
              ? '发现需要人工审看的字幕'
              : status == 'WARN'
              ? '正在整理可读性提醒'
              : '检查行宽、阅读速度和术语一致性',
          overallProgress: overall,
          phaseProgress: status.isEmpty ? 0.5 : 1,
          phaseIndex: 7,
          counter: requestCount > 0 ? '模型 $requestCount 次' : '',
          activity: activity,
        );
      case 'EXPORT':
        final output = '${settings['output_format'] ?? 'srt'}'.toUpperCase();
        return MainRunProgress(
          stage: MainRunStage.export,
          title: '写出字幕',
          detail: '生成 $output 文件并检查交付格式',
          overallProgress: overall,
          phaseProgress: 0.65,
          phaseIndex: 8,
          activity: activity,
        );
      case 'CANCELLING':
      case 'CANCEL_REQUESTED':
        return MainRunProgress(
          stage: MainRunStage.cancelling,
          title: '正在取消',
          detail: '等待当前步骤安全停下',
          overallProgress: overall,
          phaseProgress: 0,
          phaseIndex: 0,
          activity: activity,
        );
    }
    return null;
  }

  static double _overallProgressForStage(
    String stage,
    Map<String, Object?> detail,
  ) {
    final normalized = stage.toUpperCase();
    if (normalized == 'ASR') {
      final done = _integer(detail['asr_done_count']);
      final total = _integer(detail['asr_total_segments']);
      if (total > 0) return 0.25 + 0.25 * (done / total).clamp(0.0, 1.0);
    }
    if (normalized == 'TRANSLATE') {
      final done = _integer(detail['translate_done_count']);
      final total = _integer(detail['translate_total_chunks']);
      if (total > 0) return 0.65 + 0.18 * (done / total).clamp(0.0, 1.0);
    }
    return switch (normalized) {
      'PRECHECK' => 0.02,
      'INGEST' => 0.08,
      'ASR' => 0.25,
      'MEMORY' => 0.54,
      'SEGMENT' => 0.55,
      'TRANSLATE' => 0.65,
      'ALIGN' => 0.85,
      'QUALITY' => 0.9,
      'EXPORT' => 0.95,
      'DONE' => 1,
      _ => 0,
    };
  }

  static String? _latestStructuredActivity(List<Map<String, Object?>> events) {
    if (events.isEmpty) return null;
    final event = events.last;
    final details = _asStringMap(event['details']);
    final mode = '${details['mode'] ?? event['mode'] ?? ''}'.trim();
    final count = details['segment_ids'] is List
        ? (details['segment_ids'] as List).length
        : 0;
    final segmentId = _integer(details['segment_id'] ?? event['segment_id']);
    final text = switch (mode) {
      'memory_bootstrap' => '正在生成初始术语记忆',
      'memory_bootstrap_extract' => '正在提取名称和称呼',
      'memory_bootstrap_classify' => '正在整理候选术语',
      'memory_patch' => '正在合并本段新增术语',
      'batch_recovery' when count > 0 => '正在批量补回 $count 行',
      'adaptive_split' => '分片已自动拆小后重试',
      'protocol_recovery' => '正在校正返回格式',
      'repair' when segmentId > 0 => '正在修复第 $segmentId 行',
      'quality_compression' => '正在压缩过长字幕',
      'quality_reflow' => '正在重排难读对白',
      _ => '',
    };
    return text.isEmpty ? null : text;
  }

  static String? _completionNoticeFromTask(TaskSummary task) {
    final detail = _asStringMap(task.raw['progress_detail']);
    final quality = '${detail['quality_status'] ?? ''}'.toUpperCase();
    final delivery = '${detail['delivery_status'] ?? ''}'.toUpperCase();
    if ({'WARN', 'FAIL'}.contains(quality)) {
      final count = _sumNumericValues(detail['quality_residual_counts']);
      if (count > 0) return '已生成字幕，仍有 $count 处需要审看';
      return '已生成字幕，质量检查仍有提醒';
    }
    if ({'WARN', 'FAIL'}.contains(delivery)) {
      return '已生成字幕，交付格式检查仍有提醒';
    }
    return null;
  }

  static double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse('${value ?? ''}');
  }

  static int _integer(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}') ?? 0;
  }

  static int _sumNumericValues(Object? value) {
    if (value is num) return value.toInt();
    if (value is Map) {
      return value.values.fold<int>(
        0,
        (total, item) => total + _sumNumericValues(item),
      );
    }
    if (value is List) {
      return value.fold<int>(
        0,
        (total, item) => total + _sumNumericValues(item),
      );
    }
    return 0;
  }

  static Map<String, Object?> _asStringMap(Object? value) {
    if (value is Map) {
      return value.map((key, item) => MapEntry('$key', item));
    }
    return const {};
  }

  static String? _latestEventMessage(List<Map<String, Object?>> events) {
    for (final event in events.reversed) {
      final stage = '${event['stage'] ?? ''}'.trim();
      final status = '${event['status'] ?? ''}'.trim();
      final message = '${event['message'] ?? ''}'.trim();
      final mapped = _friendlyEventText(stage, status, message);
      if (mapped != null) return mapped;
      if (message.isNotEmpty && !_looksInternalEventMessage(message)) {
        return message;
      }
      if (status.isNotEmpty) return _friendlyStatusText(status) ?? status;
      if (stage.isNotEmpty) return _friendlyStageText(stage) ?? stage;
    }
    return null;
  }

  static String? _friendlyEventText(
    String stage,
    String status,
    String message,
  ) {
    final normalized = [
      stage,
      status,
      message,
    ].where((item) => item.trim().isNotEmpty).join(' ').toLowerCase();
    if (normalized.isEmpty) return null;
    if (normalized.contains('created') || normalized.contains('queued')) {
      return '任务已创建，等待本地服务调度';
    }
    if (normalized.contains('asr') ||
        normalized.contains('whisper') ||
        normalized.contains('transcrib')) {
      return '正在识别语音';
    }
    if (normalized.contains('memory') || normalized.contains('术语')) {
      return '正在准备术语';
    }
    if (normalized.contains('translat')) return '正在翻译字幕';
    if (normalized.contains('subtitle') || normalized.contains('render')) {
      return '正在整理字幕';
    }
    if (normalized.contains('export') || normalized.contains('write')) {
      return '正在写出字幕文件';
    }
    if (normalized.contains('done') || normalized.contains('complete')) {
      return '字幕已生成';
    }
    return null;
  }

  static String? _friendlyStageText(String value) {
    final label = taskStageLabel(value);
    return label == value ? null : label;
  }

  static String? _friendlyStatusText(String value) {
    final label = taskStatusLabel(value);
    return label == value ? null : label;
  }

  static bool _looksInternalEventMessage(String value) {
    final lower = value.toLowerCase();
    return lower == 'task created' ||
        lower == 'task queued' ||
        lower.startsWith('task ');
  }
}
