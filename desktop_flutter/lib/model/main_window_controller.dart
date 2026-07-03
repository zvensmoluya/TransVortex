import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/app_service_client.dart';
import '../services/local_service_controller.dart';
import '../services/path_opener.dart';
import 'session.dart';

enum MainRecoveryTarget {
  retry,
  resume,
  translationSettings,
  asrSettings,
  pickSource,
  outputDirectory,
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

@immutable
class MainWindowViewModel {
  const MainWindowViewModel({
    required this.state,
    required this.statusLine,
    required this.source,
    required this.translationLabel,
    required this.translationConfigured,
    required this.asrLabel,
    required this.asrConfigured,
    required this.translationOptions,
    required this.asrOptions,
    required this.bilingual,
    required this.formats,
    required this.termsEnabled,
    required this.runningText,
    required this.progress,
    required this.canceling,
    required this.outputPaths,
    required this.failure,
    required this.submitting,
  });

  final MainState state;
  final String statusLine;
  final MainSourceDraft? source;
  final String translationLabel;
  final bool translationConfigured;
  final String asrLabel;
  final bool asrConfigured;
  final List<TaskOption> translationOptions;
  final List<TaskOption> asrOptions;
  final bool bilingual;
  final List<String> formats;
  final bool termsEnabled;
  final String? runningText;
  final double progress;
  final bool canceling;
  final Map<String, String> outputPaths;
  final MainFailureView? failure;
  final bool submitting;

  bool get hasSource => source != null;
}

class MainWindowController extends ChangeNotifier {
  MainWindowController({
    required LocalServiceController service,
    PathOpener? pathOpener,
  }) : service = service,
       _pathOpener = pathOpener ?? PathOpener() {
    service.addListener(_applyServiceSnapshot);
    _view = _buildView();
  }

  final LocalServiceController service;
  final PathOpener _pathOpener;
  Timer? _taskPoll;
  MainSourceDraft? _source;
  String _sourceLang = 'en';
  String _targetLang = 'zh-CN';
  bool _bilingual = true;
  List<String> _formats = const ['SRT', 'ASS'];
  bool _termsEnabled = true;
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
  TaskOption? _selectedTranslation;
  TaskOption? _selectedAsr;

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
    final unsupported = kind == SourceKind.subtitle &&
            !displayName.toLowerCase().endsWith('.srt')
        ? '字幕输入暂时只支持 SRT；ASS / VTT 目前只能作为输出格式。'
        : null;
    _source = MainSourceDraft(
      name: displayName,
      path: path,
      kind: kind,
      unsupportedReason: unsupported,
    );
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

  void setFormats(List<String> value) {
    if (value.isEmpty) return;
    _formats = List.unmodifiable(value);
    _publish();
  }

  void setTermsEnabled(bool value) {
    _termsEnabled = value;
    _publish();
  }

  void selectTranslation(TaskOption option) {
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
      if (client == null) throw StateError('Local Service 未连接');
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

  Future<void> retryRun() => submitRun();

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
    final path = await _primaryResultPath();
    if (path == null) throw StateError('还没有输出文件记录');
    await _pathOpener.revealFile(path);
  }

  Future<void> openResultFolder() async {
    final path = await _primaryResultPath();
    final dir = path == null ? null : _parentPath(path);
    if (dir == null || dir.isEmpty) throw StateError('还没有输出目录记录');
    await _pathOpener.openDirectory(dir);
  }

  Future<void> reexportResult() async {
    final taskId = _taskId;
    if (taskId == null) throw StateError('还没有可重新导出的任务');
    await service.client?.resultReexport(
      taskId,
      outputFormat: outputFormatValue(_formats),
      bilingual: _bilingual,
    );
    await refreshSnapshot();
  }

  Map<String, Object?> buildRunRequest() {
    final source = _source;
    if (source == null) throw StateError('还没有片源');
    if (!source.supported) {
      throw StateError(source.unsupportedReason ?? '片源暂不支持');
    }
    final snapshot = service.snapshot.desktopSnapshot;
    final translation = _effectiveTranslationOption(snapshot);
    final asr = _effectiveAsrOption(snapshot);
    final overrides = <String, Object?>{
      'output_format': outputFormatValue(_formats),
      'subtitle_quality_mode': 'balanced',
      'memory_bootstrap_enabled': _termsEnabled,
      'memory_patch_enabled': _termsEnabled,
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
      if (translation.provider != null && translation.provider!.isNotEmpty)
        'provider': translation.provider,
      if (translation.model != null && translation.model!.isNotEmpty)
        'model': translation.model,
      'overrides': overrides,
    };
  }

  void _applyServiceSnapshot() {
    final snapshot = service.snapshot.desktopSnapshot;
    final taskId = _taskId;
    final task = taskId == null ? null : snapshot?.taskById(taskId);
    if (task != null) _applyTask(task);
    _publish();
  }

  void _applyTask(TaskSummary task) {
    _source ??= MainSourceDraft(
      name: _basename(task.inputFile),
      path: task.inputFile,
      kind: _kindOf(task.inputFile),
    );
    if (task.sourceLang.isNotEmpty) _sourceLang = task.sourceLang;
    if (task.targetLang.isNotEmpty) _targetLang = task.targetLang;
    _bilingual = task.bilingual;
    _running = !task.isTerminal;
    _canceling = task.status == 'CANCEL_REQUESTED';
    _completed = task.isDone;
    _progress = task.isDone ? 1 : (task.latestProgress ?? _progress);
    _outputPaths = task.outputPaths;
    _statusText = _taskStatusLabel(task);
    _failure = task.isFailed || task.isCancelled ? _failureFromTask(task) : null;
    if (task.isTerminal) {
      _taskPoll?.cancel();
      _taskPoll = null;
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
    final translation = _effectiveTranslationOption(snapshot);
    final asr = _effectiveAsrOption(snapshot);
    final state = _deriveState(readiness, translation, asr);
    return MainWindowViewModel(
      state: state,
      statusLine: _statusLine(state),
      source: _source,
      translationLabel: translation.configured ? translation.label : '需配置',
      translationConfigured: translation.configured,
      asrLabel: asr.configured ? asr.label : '需配置',
      asrConfigured: asr.configured,
      translationOptions: _translationOptions(snapshot),
      asrOptions: _asrOptions(snapshot),
      bilingual: _bilingual,
      formats: _formats,
      termsEnabled: _termsEnabled,
      runningText: _statusText,
      progress: _progress,
      canceling: _canceling,
      outputPaths: _outputPaths,
      failure: _failure,
      submitting: _submitting,
    );
  }

  MainState _deriveState(
    ConfigReadiness? readiness,
    TaskOption translation,
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
    final translationConfigured = _effectiveTranslationOption(
      service.snapshot.desktopSnapshot,
    ).configured;
    final base = switch (state) {
      MainState.empty => '等待片源',
      MainState.ready => '就绪 · 可开始',
      MainState.blocked => !translationConfigured
          ? '需要先配置翻译'
          : '需要先配置识别',
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

  TaskOption _effectiveTranslationOption(DesktopSnapshot? snapshot) {
    final selected = _selectedTranslation;
    if (selected != null) return selected;
    final provider = snapshot?.translationProvider;
    final model = snapshot?.translationModel;
    final readiness = snapshot?.configReadiness;
    final label = provider == null || provider.isEmpty
        ? readiness?.translationLabel ?? '需配置'
        : (model == null || model.isEmpty ? provider : '$provider · $model');
    return TaskOption(
      label: label,
      configured: readiness?.translationConfigured ?? false,
      provider: provider,
      model: model,
    );
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

  List<TaskOption> _translationOptions(DesktopSnapshot? snapshot) {
    if (snapshot == null) return const [];
    return snapshot.providers
        .where((provider) => provider.hasKey)
        .expand(
          (provider) {
            final models = provider.models.isEmpty ? [''] : provider.models;
            return models.map(
              (model) => TaskOption(
                label: model.isEmpty ? provider.name : '${provider.name} · $model',
                configured: true,
                provider: provider.name,
                model: model.isEmpty ? null : model,
              ),
            );
          },
        )
        .toList(growable: false);
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

  MainFailureView _failureFromTask(TaskSummary task) {
    final hint = '${task.errorInfo['hint_zh'] ?? ''}'.trim();
    final code = '${task.errorInfo['code'] ?? ''}'.trim();
    final message = '${task.errorInfo['message'] ?? task.error ?? ''}'.trim();
    final reason = hint.isNotEmpty
        ? hint
        : (message.isNotEmpty ? message : _latestEventMessage(_recentEvents) ?? '制作失败');
    final mapped = _recoveryForCode(code, task: task);
    return MainFailureView(
      reason: reason,
      actionLabel: mapped.$1,
      target: mapped.$2,
    );
  }

  MainFailureView _failureFromError(Object error, {String fallbackAction = '重试'}) {
    if (error is RpcRemoteException) {
      final details = _asStringMap(error.details);
      final info = _asStringMap(details['error_info']);
      final hint = '${info['hint_zh'] ?? ''}'.trim();
      final code = '${info['code'] ?? error.code}'.trim();
      final mapped = _recoveryForCode(code);
      return MainFailureView(
        reason: hint.isNotEmpty ? hint : error.message,
        actionLabel: mapped.$1,
        target: mapped.$2,
      );
    }
    return MainFailureView(
      reason: '$error',
      actionLabel: fallbackAction,
      target: MainRecoveryTarget.retry,
    );
  }

  (String, MainRecoveryTarget) _recoveryForCode(String code, {TaskSummary? task}) {
    final lower = code.toLowerCase();
    if (lower.contains('asr') || lower.contains('whisper')) {
      return ('去配置识别', MainRecoveryTarget.asrSettings);
    }
    if (lower.contains('provider') ||
        lower.contains('routing') ||
        lower.contains('credential') ||
        lower.contains('api_key') ||
        lower.contains('key')) {
      return ('去配置翻译', MainRecoveryTarget.translationSettings);
    }
    if (lower.contains('input') || lower.contains('not_found')) {
      return ('重新选择片源', MainRecoveryTarget.pickSource);
    }
    if (lower.contains('permission') ||
        lower.contains('output') ||
        lower.contains('writable')) {
      return ('查看输出目录', MainRecoveryTarget.outputDirectory);
    }
    if (task?.canResume == true || lower.contains('interrupt')) {
      return ('继续任务', MainRecoveryTarget.resume);
    }
    return ('重试', MainRecoveryTarget.retry);
  }

  Future<String?> _primaryResultPath() async {
    if (_outputPaths.isNotEmpty) return primaryOutputPath(_outputPaths);
    final taskId = _taskId;
    if (taskId == null) return null;
    final result = await service.client?.resultOpen(taskId);
    final outputs = _asStringMap(result?['output_paths']).map(
      (key, value) => MapEntry(key, '$value'),
    );
    _outputPaths = outputs;
    return primaryOutputPath(outputs);
  }

  static SourceKind _kindOf(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const video = {'mp4', 'mkv', 'mov', 'avi', 'webm', 'flv'};
    const audio = {'mp3', 'wav', 'm4a', 'flac', 'aac', 'ogg'};
    if (audio.contains(ext)) return SourceKind.audio;
    if (ext == 'srt' || ext == 'ass' || ext == 'vtt') {
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
    return 'srt';
  }

  static String? primaryOutputPath(Map<String, String> outputs) {
    for (final key in const ['srt', 'ass', 'vtt']) {
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
    return path.substring(0, idx);
  }

  static String _basename(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  static String _taskStatusLabel(TaskSummary task) {
    return switch (task.status) {
      'QUEUED' => '等待本地服务调度',
      'CANCEL_REQUESTED' => '正在取消',
      'DONE' => '字幕已生成',
      'FAILED' => '制作失败',
      'CANCELLED' => '已取消',
      'INTERRUPTED' => '任务中断',
      _ => task.displayStatus,
    };
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
      final message = '${event['message'] ?? ''}'.trim();
      if (message.isNotEmpty) return message;
      final stage = '${event['stage'] ?? ''}'.trim();
      if (stage.isNotEmpty) return stage;
    }
    return null;
  }
}
