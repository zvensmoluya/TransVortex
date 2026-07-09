import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/app_service_client.dart';
import '../services/local_service_controller.dart';
import '../services/path_opener.dart';
import 'session.dart';
import 'task_labels.dart';

enum MainRecoveryTarget {
  retry,
  resume,
  translationSettings,
  asrSettings,
  pickSource,
  outputDirectory,
  reexport,
  reexportDirectory,
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

  bool get hasSource => source != null;
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
  Map<String, String> _outputPaths = const {};
  MainFailureView? _failure;
  int _eventCursor = 0;
  List<Map<String, Object?>> _recentEvents = const [];
  TranslationRuntimeChoice? _selectedTranslation;
  TaskOption? _selectedAsr;
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
    _outputDirectory = null;
    _taskId = null;
    _statusText = null;
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
  }

  void removeSource() {
    _taskPoll?.cancel();
    _taskPoll = null;
    _source = null;
    _outputDirectory = null;
    _taskId = null;
    _statusText = null;
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
    _selectedTranslation = option;
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
    if (readiness != null && !readiness.asrConfigured) {
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

  Future<void> cancelRun() async {
    final taskId = _taskId;
    if (taskId == null) {
      _running = false;
      _canceling = false;
      _progress = 0;
      _publish();
      return;
    }
    _canceling = true;
    _statusText = '正在取消';
    _publish();
    try {
      await service.client?.cancel(taskId);
      await refreshSnapshot();
    } on Object catch (error) {
      _canceling = false;
      _failure = _failureFromError(error, fallbackAction: '重试取消');
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
      final page = await client.taskEvents(taskId, cursor: _eventCursor);
      final nextEvents = page.events
          .map(_asStringMap)
          .where((event) => event.isNotEmpty)
          .toList();
      _eventCursor = page.nextCursor;
      _recentEvents = [..._recentEvents, ...nextEvents];
      if (_recentEvents.length > 12) {
        _recentEvents = _recentEvents.sublist(_recentEvents.length - 12);
      }
      _progress = _latestEventProgress(_recentEvents) ?? _progress;
      _statusText = _latestEventMessage(_recentEvents) ?? _statusText;
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
      final failure = _failureFromError(error, fallbackAction: '重新导出');
      _failure = failure.target == MainRecoveryTarget.outputDirectory
          ? MainFailureView(
              reason: failure.reason,
              actionLabel: failure.actionLabel,
              target: MainRecoveryTarget.reexportDirectory,
            )
          : failure;
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
    final asr = _effectiveAsrOption(snapshot);
    final outputDirectory = _effectiveOutputDirectory(source);
    final overrides = <String, Object?>{
      'output_format': outputFormatValue(_formats),
      'subtitle_quality_mode': 'balanced',
      ..._memoryGenerationOverrides(),
      if (asr.provider != null && asr.provider!.isNotEmpty)
        'asr_provider': asr.provider,
      if (asr.model != null && asr.model!.isNotEmpty) 'asr_model': asr.model,
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
      if (translation.routing.isNotEmpty) 'routing': translation.routing,
      if (translation.routing.isEmpty &&
          translation.provider != null &&
          translation.provider!.isNotEmpty)
        'provider': translation.provider,
      if (translation.routing.isEmpty &&
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
    final snapshot = service.snapshot.desktopSnapshot;
    final translation = _effectiveTranslationChoice(snapshot);
    final asr = _effectiveAsrOption(snapshot);
    final overrides = <String, Object?>{
      'output_format': outputFormatValue(_formats),
      'subtitle_quality_mode': 'balanced',
      ..._memoryGenerationOverrides(),
      if (asr.provider != null && asr.provider!.isNotEmpty)
        'asr_provider': asr.provider,
      if (asr.model != null && asr.model!.isNotEmpty) 'asr_model': asr.model,
    };
    return {
      'request_version': 1,
      'task_id': taskId,
      if (translation.routing.isNotEmpty) 'routing': translation.routing,
      if (translation.routing.isEmpty &&
          translation.provider != null &&
          translation.provider!.isNotEmpty)
        'provider': translation.provider,
      if (translation.routing.isEmpty &&
          translation.model != null &&
          translation.model!.isNotEmpty)
        'model': translation.model,
      'overrides': overrides,
    };
  }

  Map<String, Object?> _memoryGenerationOverrides() => {
    'allowSystemSuggestions': _termsEnabled,
    if (_termsEnabled) 'memory_enabled': true,
    'memory_bootstrap_enabled': _termsEnabled,
    'memory_patch_enabled': _termsEnabled,
  };

  void _applyServiceSnapshot() {
    final snapshot = service.snapshot.desktopSnapshot;
    final task = _taskFromSnapshot(snapshot);
    if (task != null) _applyTask(task);
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
    _running = !task.isTerminal && (task.isRuntimeActive || pendingCurrentTask);
    _canceling = task.status == 'CANCEL_REQUESTED';
    _completed = task.isDone;
    _progress = task.isDone ? 1 : (task.latestProgress ?? _progress);
    _outputPaths = task.outputPaths;
    _statusText = _taskStatusLabel(task);
    _failure = task.isFailed || task.isCancelled
        ? _failureFromTask(task)
        : null;
    if (task.isTerminal || !_running) {
      _taskPoll?.cancel();
      _taskPoll = null;
    } else {
      _ensureTaskPolling();
    }
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
    final hint = '${task.errorInfo['hint_zh'] ?? ''}'.trim();
    if (hint.isNotEmpty) return _userFacingFailureReason(hint);
    final message = '${task.errorInfo['message'] ?? task.error ?? ''}'.trim();
    if (message.isNotEmpty) return _userFacingFailureReason(message);
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
    if (readiness == null || !translation.configured || !asr.configured) {
      return MainState.blocked;
    }
    return MainState.ready;
  }

  String _statusLine(MainState state) {
    final translationConfigured = _effectiveTranslationChoice(
      service.snapshot.desktopSnapshot,
    ).configured;
    final base = switch (state) {
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
      'primary': {'provider': profile.provider, 'model': profile.model},
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
        fallback: fallback,
      ),
      source: source,
    );
  }

  List<TaskOption> _asrOptions(DesktopSnapshot? snapshot) {
    if (snapshot == null) return const [];
    return snapshot.asrProviders
        .where((provider) => provider.hasKey)
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
    final modelText = model ?? option?.model ?? '';
    return modelText.isEmpty ? label : '$label · $modelText';
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
    if (provider.isEmpty && model.isEmpty) return const {};
    return _routingPayload(
      provider: provider,
      model: model,
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
      routes.add({'provider': provider, 'model': model});
    }
    return routes;
  }

  static Map<String, Object?> _routingPayload({
    required String provider,
    required String model,
    required List<Map<String, Object?>> fallback,
  }) {
    return {
      'primary': {'provider': provider.trim(), 'model': model.trim()},
      'fallback': [
        for (final route in fallback)
          {
            'provider': '${route['provider'] ?? ''}'.trim(),
            'model': '${route['model'] ?? ''}'.trim(),
          },
      ],
    };
  }

  MainFailureView _failureFromTask(TaskSummary task) {
    final hint = '${task.errorInfo['hint_zh'] ?? ''}'.trim();
    final code = '${task.errorInfo['code'] ?? ''}'.trim();
    final message = '${task.errorInfo['message'] ?? task.error ?? ''}'.trim();
    final reason = hint.isNotEmpty
        ? _userFacingFailureReason(hint)
        : (message.isNotEmpty
              ? _userFacingFailureReason(message)
              : _latestEventMessage(_recentEvents) ?? '制作失败');
    final mapped = _recoveryForCode(code, task: task);
    return MainFailureView(
      reason: reason,
      actionLabel: mapped.$1,
      target: mapped.$2,
    );
  }

  MainFailureView _failureFromError(
    Object error, {
    String fallbackAction = '重试',
  }) {
    if (error is RpcRemoteException) {
      final details = _asStringMap(error.details);
      final info = _asStringMap(details['error_info']);
      final hint = '${info['hint_zh'] ?? ''}'.trim();
      final code = '${info['code'] ?? error.code}'.trim();
      final mapped = _recoveryForCode(code);
      return MainFailureView(
        reason: _userFacingFailureReason(
          hint.isNotEmpty ? hint : error.message,
        ),
        actionLabel: mapped.$1,
        target: mapped.$2,
      );
    }
    return MainFailureView(
      reason: _userFacingFailureReason('$error'),
      actionLabel: fallbackAction,
      target: MainRecoveryTarget.retry,
    );
  }

  String _userFacingFailureReason(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '制作失败';
    final lower = text.toLowerCase();
    if (lower.contains('events.json') || lower.contains('stderr')) {
      return '任务运行失败，可以打开诊断查看任务详情。';
    }
    if (lower.contains('ffmpeg') ||
        lower.contains('returned non-zero exit status')) {
      return '音频处理失败，请确认片源能正常播放，或换一个文件重试。';
    }
    return text;
  }

  (String, MainRecoveryTarget) _recoveryForCode(
    String code, {
    TaskSummary? task,
  }) {
    final lower = code.toLowerCase();
    if (lower.contains('asr') || lower.contains('whisper')) {
      return ('去配置识别', MainRecoveryTarget.asrSettings);
    }
    if (lower.contains('provider') ||
        lower.contains('routing') ||
        lower.contains('credential') ||
        lower.contains('missing_env') ||
        lower.contains('env_key') ||
        lower.contains('api_key') ||
        lower.contains('key')) {
      return ('去配置翻译', MainRecoveryTarget.translationSettings);
    }
    if (lower.contains('result') ||
        lower.contains('export') ||
        lower.contains('moved') ||
        lower.contains('deleted')) {
      return ('重新导出', MainRecoveryTarget.reexport);
    }
    if (lower.contains('input') || lower.contains('not_found')) {
      return ('重新选择片源', MainRecoveryTarget.pickSource);
    }
    if (lower.contains('permission') ||
        lower.contains('output') ||
        lower.contains('writable')) {
      return ('选择输出目录', MainRecoveryTarget.outputDirectory);
    }
    if (task?.canResume == true || lower.contains('interrupt')) {
      return ('继续任务', MainRecoveryTarget.resume);
    }
    return ('重试', MainRecoveryTarget.retry);
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

  static Map<String, Object?> _asStringMap(Object? value) {
    if (value is Map) {
      return value.map((key, item) => MapEntry('$key', item));
    }
    return const {};
  }

  static double? _latestEventProgress(List<Map<String, Object?>> events) {
    for (final event in events.reversed) {
      final value = event['progress'];
      if (value is num) return value.toDouble().clamp(0.0, 1.0);
      if (value is String) {
        final parsed = double.tryParse(value);
        if (parsed != null) return parsed.clamp(0.0, 1.0);
      }
    }
    return null;
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
