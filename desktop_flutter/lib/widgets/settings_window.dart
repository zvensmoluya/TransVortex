import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:window_manager/window_manager.dart';

import '../model/startup_args.dart';
import '../model/asr_operation_controller.dart';
import '../model/task_labels.dart';
import '../model/translation_settings_controller.dart';
import '../model/window_state.dart';
import '../services/app_service_client.dart';
import '../services/directory_probe.dart';
import '../services/local_service_controller.dart';
import '../services/path_opener.dart';
import '../services/settings_error.dart';
import '../services/settings_service_transport.dart';
import '../services/smoke_render_capture.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';
import 'settings_common.dart';
import 'title_bar.dart';
import 'translation_settings_view.dart';

part 'settings_window/asr_widgets.dart';
part 'settings_window/asr_surface.dart';
part 'settings_window/diagnostic_widgets.dart';
part 'settings_window/diagnostics_surface.dart';

typedef SettingsDirectoryPicker = Future<String?> Function(String dialogTitle);

class _SmokeSettingsTransport implements AppServiceTransport {
  _SmokeSettingsTransport(this.service);

  final LocalServiceController service;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    await service.start();
    final client = service.client;
    if (client == null) {
      throw PlatformException(
        code: 'service_unavailable',
        message: '本地服务未连接，无法执行设置窗口 smoke',
      );
    }
    return client.call(method, params, timeout);
  }

  @override
  Future<void> close() => service.shutdown();
}

class SettingsWindow extends StatefulWidget {
  const SettingsWindow({
    super.key,
    required this.type,
    required this.store,
    required this.bridge,
    this.localServiceController,
    this.pathOpener,
    this.directoryProbe,
    this.directoryPicker,
    this.smoke,
  });

  final AppWindowType type;
  final WindowStateStore store;
  final WindowStateBridge bridge;
  final LocalServiceController? localServiceController;
  final PathOpener? pathOpener;
  final DirectoryWriteProbe? directoryProbe;
  final SettingsDirectoryPicker? directoryPicker;
  final AppSmokeArgs? smoke;

  @override
  State<SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<SettingsWindow> with WindowListener {
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  final _endpoint = TextEditingController();
  final _device = TextEditingController(text: 'auto');
  final _externalModelPath = TextEditingController();
  final _funasrExecutable = TextEditingController();
  final _funasrArguments = TextEditingController();
  final _funasrWorkingDirectory = TextEditingController();
  final _funasrHealthUrl = TextEditingController();
  final GlobalKey _renderKey = GlobalKey(debugLabel: 'settings-smoke-render');
  LocalServiceController? _smokeService;
  LocalServiceController? _ownedFallbackService;
  late final AppServiceClient _client;
  late final AsrOperationController _asrOperationController;
  late final PathOpener _pathOpener;
  late final DirectoryWriteProbe _directoryProbe;
  late final SettingsDirectoryPicker _directoryPicker;

  // Translation settings live in their own controller + view; the settings
  // window only owns it, mirrors its labels into the store, and drives smoke.
  TranslationSettingsController? _translationController;

  DesktopSnapshot? _snapshot;
  List<TaskSummary>? _diagnosticTasks;
  TaskResultWorkspace? _diagnosticResult;
  final Map<String, DirectoryProbeResult> _diagnosticOutputDirectoryResults =
      {};
  final Set<String> _checkingDiagnosticOutputDirectoryTaskIds = {};
  String? _selectedDiagnosticTaskId;
  String _selectedAsrProvider = 'faster_whisper_large_v3';
  String? _selectedDiagnosticCheck;
  String? _message;
  String? _error;
  String? _openRouterUsageMessage;
  String? _openRouterUsageError;
  String? _openRouterUsageAutoLoadedFor;
  bool _loading = false;
  bool _savingAsr = false;
  bool _testingAsr = false;
  bool _managingFunasr = false;
  bool _checkingOpenRouterUsage = false;
  bool _copyingAgentHandoff = false;
  bool _discoveringAsrModels = false;
  bool _probingAsrModel = false;
  bool _renamingAsrModel = false;
  bool _asrDraftDirty = false;
  bool _editingLocalWhisper = false;
  String _asrModelSource = 'managed';
  String _managedModelId = 'small';
  String _externalDraftModelId = '';
  String _externalDraftRegistrationId = '';
  String _localComputeType = 'auto';
  String _savedAsrModelSource = 'managed';
  String _savedManagedModelId = 'small';
  String _savedExternalModelId = '';
  String _savedExternalRegistrationId = '';
  String _savedExternalModelPath = '';
  String _savedLocalDevice = 'auto';
  String _savedLocalComputeType = 'auto';
  String _detectedExternalModelId = '';
  bool _loadingDiagnosticTasks = false;
  bool _loadingDiagnosticResult = false;
  int _configLoadRevision = 0;
  int _visibleConfigLoads = 0;
  int _openRouterUsageRequestRevision = 0;

  bool get _isTranslation => widget.type == AppWindowType.translationSettings;
  bool get _isAsr => widget.type == AppWindowType.asrSettings;
  AsrOperationStatus? get _activeAsrOperation =>
      _asrOperationController.operation;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _client = AppServiceClient(_settingsTransport());
    _asrOperationController = AsrOperationController(
      _client,
      onTerminal: _handleAsrOperationTerminal,
      onError: _handleAsrOperationError,
    )..addListener(_onAsrOperationChanged);
    _pathOpener = widget.pathOpener ?? SystemPathOpener();
    _directoryProbe = widget.directoryProbe ?? SystemDirectoryWriteProbe();
    _directoryPicker =
        widget.directoryPicker ??
        ((dialogTitle) =>
            FilePicker.platform.getDirectoryPath(dialogTitle: dialogTitle));
    if (widget.smoke == null) {
      widget.bridge.initializeChild();
    }
    if (_isTranslation) {
      final controller = TranslationSettingsController(
        _client,
        widget.bridge.setTranslationDefault,
        onConfigChanged: widget.bridge.refreshServiceSnapshot,
      );
      _translationController = controller;
      controller.addListener(_onTranslationChanged);
      _initTranslation(controller);
    } else {
      _loadConfig();
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _smokeService?.dispose();
    _ownedFallbackService?.dispose();
    _translationController?.removeListener(_onTranslationChanged);
    _translationController?.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _key.dispose();
    _endpoint.dispose();
    _device.dispose();
    _externalModelPath.dispose();
    _funasrExecutable.dispose();
    _funasrArguments.dispose();
    _funasrWorkingDirectory.dispose();
    _funasrHealthUrl.dispose();
    _asrOperationController
      ..removeListener(_onAsrOperationChanged)
      ..dispose();
    super.dispose();
  }

  @override
  void onWindowFocus() {
    final controller = _translationController;
    if (controller != null) unawaited(controller.syncNetworkSettings());
    if (_isAsr && widget.smoke == null) {
      unawaited(
        _loadConfig(
          preserveAsrDraft: _asrDraftDirty || _editingLocalWhisper,
          silent: true,
        ),
      );
    }
  }

  Future<void> _initTranslation(
    TranslationSettingsController controller,
  ) async {
    await controller.load();
    if (!mounted) return;
    final snapshot = controller.snapshot;
    if (snapshot != null) _syncMainLabels(snapshot);
    if (widget.smoke != null) {
      await _writeSettingsSmokeReport(snapshot, error: controller.error);
    }
  }

  void _onTranslationChanged() {
    if (!mounted) return;
    final controller = _translationController;
    if (controller != null &&
        !controller.isBusy &&
        controller.snapshot != null) {
      _syncMainLabels(controller.snapshot!);
    }
    setState(() {});
  }

  void _onAsrOperationChanged() {
    if (mounted) setState(() {});
  }

  void _handleAsrOperationError(Object error) {
    if (!mounted) return;
    setState(() => _error = _friendlySettingsError(error));
  }

  Future<void> _handleAsrOperationTerminal(AsrOperationStatus operation) async {
    final activatedSetup =
        operation.kind == 'setup' && operation.state == 'completed';
    await _loadConfig(preserveAsrDraft: !activatedSetup);
    if (!mounted) return;
    await widget.bridge.refreshServiceSnapshot();
    if (!mounted) return;
    setState(() {
      if (operation.state == 'completed') {
        _message = operation.kind == 'setup'
            ? _managedSetupIsCurrent(operation)
                  ? '${_asrModelLabel(operation.itemId)} 已下载并设为默认。'
                  : '${_asrModelLabel(operation.itemId)} 已下载，可在本机 Whisper 中启用。'
            : '${_asrOperationLabel(operation.itemId)}下载完成。';
      } else if (operation.state == 'failed' ||
          operation.state == 'cancelled') {
        _error = null;
        _message = null;
      }
    });
  }

  AppServiceTransport _settingsTransport() {
    final smoke = widget.smoke;
    if (smoke == null) {
      final service = widget.localServiceController ?? LocalServiceController();
      if (widget.localServiceController == null) {
        _ownedFallbackService = service;
      }
      return SettingsServiceTransport(bridge: widget.bridge, service: service);
    }
    final service = LocalServiceController(
      supervisor: LocalServiceSupervisor(serviceRoot: _serviceRoot(smoke)),
    );
    _smokeService = service;
    return _SmokeSettingsTransport(service);
  }

  Directory? _serviceRoot(AppSmokeArgs smoke) {
    final root = smoke.serviceRoot;
    if (root == null || root.isEmpty) return null;
    return Directory(root);
  }

  Future<void> _loadConfig({
    bool preserveAsrDraft = false,
    bool silent = false,
    String? preferredAsrProvider,
  }) async {
    final revision = ++_configLoadRevision;
    AsrOperationStatus? activeAsrOperation;
    if (!silent) {
      _visibleConfigLoads += 1;
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final snapshot = await _client.desktopSnapshot();
      if (!mounted || revision != _configLoadRevision) return;
      final previousSnapshot = _snapshot;
      final previousProviderName = previousSnapshot == null
          ? ''
          : _asrProviderNameForSelection(_selectedAsrProvider);
      final canRetainSelection =
          previousSnapshot != null &&
          previousProviderName.isNotEmpty &&
          snapshot.asrProviders.any(
            (provider) => provider.name == previousProviderName,
          );
      final retainedSelection = canRetainSelection
          ? _asrSelectionIdForProvider(snapshot, previousProviderName)
          : '';
      final preferredProviderName = preferredAsrProvider?.trim() ?? '';
      final canUsePreferredProvider =
          preferredProviderName.isNotEmpty &&
          snapshot.asrProviders.any(
            (provider) => provider.name == preferredProviderName,
          );
      setState(() {
        _snapshot = snapshot;
        if (widget.type == AppWindowType.diagnostics) {
          _diagnosticTasks = null;
          _diagnosticResult = null;
          _selectedDiagnosticTaskId = null;
        }
        if (_isAsr) {
          if (!preserveAsrDraft) {
            _selectedAsrProvider = canUsePreferredProvider
                ? _asrSelectionIdForProvider(snapshot, preferredProviderName)
                : canRetainSelection
                ? retainedSelection
                : _asrSelectionIdForProvider(
                    snapshot,
                    snapshot.asrProviderName,
                  );
            _loadAsrDraftFields();
          }
          activeAsrOperation = snapshot.asrOperations
              .where((operation) => operation.active)
              .firstOrNull;
        } else if (widget.type == AppWindowType.diagnostics) {
          _selectedDiagnosticCheck = _defaultDiagnosticSelection(snapshot);
        }
      });
      if (_isAsr) {
        _asrOperationController.attach(
          activeAsrOperation,
          poll: activeAsrOperation?.active == true,
        );
      }
      _syncMainLabels(snapshot);
      if (_isAsr) _maybeLoadOpenRouterUsage();
      if (widget.smoke != null) {
        await _writeSettingsSmokeReport(snapshot);
      }
    } on Object catch (error) {
      if (!mounted || revision != _configLoadRevision) return;
      if (!silent) {
        setState(() => _error = _friendlySettingsError(error));
      }
      if (!silent && widget.smoke != null) {
        await _writeSettingsSmokeReport(null, error: error);
      }
    } finally {
      if (!silent) {
        _visibleConfigLoads -= 1;
        if (mounted && _visibleConfigLoads == 0) {
          setState(() => _loading = false);
        }
      }
    }
  }

  Future<void> _writeSettingsSmokeReport(
    DesktopSnapshot? snapshot, {
    Object? error,
  }) async {
    final smoke = widget.smoke;
    if (smoke == null) return;
    final reportFile = File(smoke.reportPath);
    await reportFile.parent.create(recursive: true);
    final translation = _translationController;
    final provider = _isTranslation
        ? (translation?.selectedConnection ?? translation?.primary?.connection)
        : null;
    final selectedModel = _isTranslation
        ? (translation?.primary?.model ?? '')
        : _model.text.trim();
    final selectedModelCount = _isTranslation
        ? _smokeConnectionModelCount(snapshot, provider)
        : 0;
    final selectedAsr = _selectedAsrProvider;
    final diagnosticReport = _diagnosticReport(snapshot);
    final diagnosticChecks = _diagnosticChecks(snapshot);
    final diagnosticOutputDirectoryCheck =
        widget.type == AppWindowType.diagnostics
        ? await _diagnosticSmokeOutputDirectoryCheck(snapshot)
        : const <String, Object?>{};
    final payload = <String, Object?>{
      'ok': error == null && snapshot != null,
      'status': error == null ? 'ready' : 'error',
      'window_type': widget.type.id,
      'title': widget.type.title,
      'translation_label': snapshot?.configReadiness.translationLabel ?? '',
      'asr_label': snapshot?.configReadiness.asrLabel ?? '',
      'provider_count': snapshot?.providers.length ?? 0,
      'asr_provider_count': snapshot?.asrProviders.length ?? 0,
      'selected_provider': provider ?? '',
      'selected_model': selectedModel,
      'selected_provider_model_count': selectedModelCount,
      'selected_asr_provider': selectedAsr,
      'diagnostic_status': _diagnosticStatus(snapshot),
      'diagnostic_check_count': diagnosticChecks.length,
      'diagnostic_fail_count': _diagnosticCount(diagnosticChecks, 'FAIL'),
      'diagnostic_warn_count': _diagnosticCount(diagnosticChecks, 'WARN'),
      'diagnostic_root_dir': _stringValue(diagnosticReport['root_dir']) ?? '',
      'diagnostic_active_task': _diagnosticActiveTaskId(snapshot) ?? '',
      'diagnostic_task_count': snapshot?.tasks.length ?? 0,
      'diagnostic_queued_count': _diagnosticRuntimeIds(
        snapshot,
        'queued',
      ).length,
      'diagnostic_interrupted_count': _diagnosticRuntimeIds(
        snapshot,
        'interrupted',
      ).length,
      ...diagnosticOutputDirectoryCheck,
      'error': error == null ? '' : '$error',
      'finished_at': DateTime.now().toUtc().toIso8601String(),
    };
    payload.addAll(
      await captureSmokeRender(
        boundaryKey: _renderKey,
        path: smoke.screenshotPath,
      ),
    );
    if (smoke.screenshotPath != null) {
      payload['ok'] =
          payload['ok'] == true && payload['render_capture_ok'] == true;
    }
    await reportFile.writeAsString(jsonEncode(payload), encoding: utf8);
    final hold = smoke.postReportVisibleDuration;
    if (hold > Duration.zero) {
      await Future<void>.delayed(hold);
    }
    if (!mounted) return;
    try {
      await _smokeService?.shutdown();
      await windowManager.close();
    } on Object {
      exit(0);
    }
  }

  void _syncMainLabels(DesktopSnapshot snapshot) {
    final translation = snapshot.configReadiness;
    widget.store.setTranslationDefault(
      snapshot.translationProvider ?? translation.translationLabel,
      configured: translation.translationConfigured,
    );
    widget.store.setAsrDefault(
      snapshot.asrLabel ?? translation.asrLabel,
      configured: translation.asrConfigured,
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.type) {
      AppWindowType.translationSettings => '翻译模型设置',
      AppWindowType.asrSettings => '语音识别设置',
      AppWindowType.diagnostics => '诊断',
      AppWindowType.taskProcessing => '工作台',
      AppWindowType.main => 'TransVortex',
    };
    final status = switch (widget.type) {
      AppWindowType.translationSettings => '配好模型服务，选定默认模型',
      AppWindowType.asrSettings => '',
      AppWindowType.diagnostics => '检查本机运行环境、配置和翻译服务协议',
      AppWindowType.taskProcessing => '查看、修复和审看最近任务',
      AppWindowType.main => '',
    };
    return RepaintBoundary(
      key: _renderKey,
      child: Scaffold(
        backgroundColor: T.bg,
        body: Column(
          children: [
            TitleBar(title: title, status: status),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(T.s32, T.s16, T.s32, T.s24),
                child: switch (widget.type) {
                  AppWindowType.translationSettings => _translationBody(),
                  AppWindowType.asrSettings => LayoutBuilder(
                    builder: (context, constraints) => Align(
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        width: constraints.maxWidth.clamp(0, 860).toDouble(),
                        height: constraints.maxHeight,
                        child: _asrBody(),
                      ),
                    ),
                  ),
                  AppWindowType.diagnostics => _diagnosticsBody(),
                  AppWindowType.taskProcessing => _diagnosticsBody(),
                  AppWindowType.main => _diagnosticsBody(),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _translationBody() {
    final controller = _translationController;
    if (controller == null) return const SizedBox.shrink();
    return TranslationSettingsView(controller: controller);
  }

  int _smokeConnectionModelCount(DesktopSnapshot? snapshot, String? provider) {
    if (snapshot == null || provider == null) return 0;
    for (final option in snapshot.providers) {
      if (option.name == provider) return option.models.length;
    }
    return 0;
  }

  void _setSettingsState(VoidCallback update) => setState(update);
}

typedef _DiagnosticToolOpener =
    void Function(AppWindowType type, {String? taskId});

class _DiagnosticPathAction {
  const _DiagnosticPathAction({
    required this.label,
    required this.path,
    required this.successMessage,
  });

  final String label;
  final String path;
  final String successMessage;
}

int _diagnosticCount(List<Map<String, Object?>> checks, String status) {
  return checks
      .where((check) => _diagnosticCheckStatus(check) == status)
      .length;
}

String _diagnosticCheckStatus(Map<String, Object?> check) {
  final status = _stringValue(check['status'])?.toUpperCase();
  return status == null || status.isEmpty ? 'UNKNOWN' : status;
}

String _diagnosticName(Map<String, Object?> check) {
  return _stringValue(check['name']) ?? 'unknown';
}

String _diagnosticId(Map<String, Object?> check) {
  return _stringValue(check['name']) ??
      _stringValue(check['code']) ??
      _diagnosticMessage(check);
}

String _diagnosticDisplayName(Map<String, Object?> check) {
  final name = _diagnosticName(check);
  final code = _stringValue(check['code']) ?? '';
  final key = '$name $code'.toLowerCase();
  if (key.contains('python')) return 'Python';
  if (key.contains('transvortex_package')) return 'TransVortex 包';
  if (key.contains('faster_whisper')) return '本机识别依赖';
  if (key.contains('ffmpeg')) return 'FFmpeg';
  if (key.contains('ffprobe')) return 'FFprobe';
  if (key.contains('providers_file')) return '翻译配置文件';
  if (key.contains('artifacts')) return '产物目录';
  if (key.contains('asr_provider')) return '语音识别配置';
  if (key.contains('provider')) return '翻译服务配置';
  return name == 'unknown' ? '检查项' : name;
}

String _diagnosticStatusLabel(String status) {
  return switch (status.toUpperCase()) {
    'PASS' => '通过',
    'WARN' => '警告',
    'FAIL' => '失败',
    _ => '未知',
  };
}

String _diagnosticCodeLabel(String code) {
  final lower = code.toLowerCase();
  if (lower.contains('python_found')) return 'Python 可用';
  if (lower.contains('python_missing')) return 'Python 不可用';
  if (lower.contains('faster_whisper')) {
    return lower.contains('missing')
        ? 'faster-whisper 缺失'
        : 'faster-whisper 可用';
  }
  if (lower.contains('ffmpeg')) {
    return lower.contains('missing') ? 'FFmpeg 缺失' : 'FFmpeg 可用';
  }
  if (lower.contains('ffprobe')) {
    return lower.contains('missing') ? 'FFprobe 缺失' : 'FFprobe 可用';
  }
  if (lower.contains('providers_file')) {
    return lower.contains('missing') ? '翻译配置缺失' : '翻译配置可用';
  }
  if (lower.contains('artifacts')) {
    return lower.contains('missing') ||
            lower.contains('not_writable') ||
            lower.contains('unwritable')
        ? '产物目录不可用'
        : '产物目录可用';
  }
  if (lower.contains('asr_provider')) {
    return lower.contains('missing') ? '识别配置缺失' : '识别配置可用';
  }
  return code;
}

String _diagnosticHint(Map<String, Object?> check) {
  return _localizeDiagnosticText(
    _stringValue(check['hint_zh']) ??
        _stringValue(check['hint']) ??
        _diagnosticMessage(check),
  );
}

String _diagnosticMessage(Map<String, Object?> check) {
  final message = _stringValue(check['message']);
  if (message == null || message.isEmpty) return '暂无详情';
  final lower = message.toLowerCase();
  if (lower == 'python is available') return 'Python 已可用。';
  if (lower.contains('faster-whisper') && lower.contains('required')) {
    return '本机识别需要安装 faster-whisper。';
  }
  if (lower.contains('transvortex package') && lower.contains('import')) {
    return 'TransVortex 包已可用。';
  }
  if (lower.contains('ffmpeg') && lower.contains('available')) {
    return 'FFmpeg 已可用。';
  }
  if (lower.contains('ffprobe') && lower.contains('available')) {
    return 'FFprobe 已可用。';
  }
  return _localizeDiagnosticText(message);
}

String _localizeDiagnosticText(String text) {
  return text
      .replaceAll('ASR provider', '语音识别配置')
      .replaceAll('asr provider', '语音识别配置')
      .replaceAll('本地 ASR', '本机语音识别')
      .replaceAll('本机 ASR', '本机语音识别')
      .replaceAll('本机语音识别 需要', '本机语音识别需要')
      .replaceAll('provider 配置文件', '翻译配置文件')
      .replaceAll('Provider 配置文件', '翻译配置文件')
      .replaceAll('provider 配置', '翻译服务配置')
      .replaceAll('Provider 配置', '翻译服务配置')
      .replaceAll('artifacts 目录', '产物目录')
      .replaceAll('Artifacts 目录', '产物目录');
}

AppWindowType? _diagnosticRepairTarget(Map<String, Object?> check) {
  final haystack = [
    _diagnosticName(check),
    _stringValue(check['code']) ?? '',
    _diagnosticMessage(check),
    _diagnosticHint(check),
    ..._diagnosticDetailLines(check),
  ].join(' ').toLowerCase();
  if (haystack.contains('asr') ||
      haystack.contains('whisper') ||
      haystack.contains('funasr') ||
      haystack.contains('faster')) {
    return AppWindowType.asrSettings;
  }
  if (haystack.contains('routing') ||
      haystack.contains('provider') ||
      haystack.contains('env_key') ||
      haystack.contains('credential') ||
      haystack.contains('base_url') ||
      haystack.contains('api key') ||
      haystack.contains('api_key')) {
    return AppWindowType.translationSettings;
  }
  if (haystack.contains('runtime') ||
      haystack.contains('task') ||
      haystack.contains('queue') ||
      haystack.contains('queued') ||
      haystack.contains('interrupted') ||
      haystack.contains('resume') ||
      haystack.contains('任务') ||
      haystack.contains('队列') ||
      haystack.contains('中断') ||
      haystack.contains('继续')) {
    return AppWindowType.taskProcessing;
  }
  return null;
}

_DiagnosticPathAction? _diagnosticPathAction(
  Map<String, Object?> check,
  Map<String, Object?> report,
) {
  final details = _stringMap(check['details']);
  final haystack = [
    _diagnosticName(check),
    _stringValue(check['code']) ?? '',
    _diagnosticMessage(check),
    _diagnosticHint(check),
  ].join(' ').toLowerCase();
  if (haystack.contains('artifacts') || haystack.contains('产物目录')) {
    final path =
        _stringValue(details['path']) ?? _stringValue(report['artifacts_dir']);
    if (path != null && path.isNotEmpty) {
      return _DiagnosticPathAction(
        label: '打开产物目录',
        path: path,
        successMessage: '已打开产物目录',
      );
    }
  }
  if (haystack.contains('output_dir') ||
      haystack.contains('output directory') ||
      haystack.contains('output_not_writable') ||
      haystack.contains('输出目录')) {
    final path =
        _stringValue(details['output_dir']) ??
        _stringValue(details['outputDir']) ??
        _stringValue(details['path']);
    if (path != null && path.isNotEmpty) {
      return _DiagnosticPathAction(
        label: '打开输出目录',
        path: path,
        successMessage: '已打开输出目录',
      );
    }
  }
  return null;
}

String? _diagnosticRepairTaskId(
  Map<String, Object?> check,
  DesktopSnapshot? snapshot,
) {
  final details = _stringMap(check['details']);
  final direct =
      _stringValue(details['task_id']) ??
      _stringValue(details['taskId']) ??
      _stringValue(check['task_id']) ??
      _stringValue(check['taskId']);
  if (direct != null && direct.isNotEmpty) return direct;
  final active = _diagnosticActiveTaskRawId(snapshot);
  if (active != null && active.isNotEmpty) return active;
  return _diagnosticLatestTask(snapshot)?.taskId;
}

String _diagnosticRepairLabel(AppWindowType type) {
  return switch (type) {
    AppWindowType.translationSettings => '去翻译模型设置',
    AppWindowType.asrSettings => '去语音识别设置',
    AppWindowType.diagnostics => '刷新诊断',
    AppWindowType.taskProcessing => '打开工作台',
    AppWindowType.main => '回到主窗口',
  };
}

List<String> _diagnosticDetailLines(Map<String, Object?> check) {
  final details = _stringMap(check['details']);
  return details.entries
      .where((entry) => entry.value != null)
      .map(
        (entry) =>
            '${_diagnosticDetailLabel(entry.key)}：${_diagnosticDetailValue(entry.key, entry.value)}',
      )
      .take(4)
      .toList();
}

String _diagnosticDetailLabel(String key) {
  return switch (key) {
    'executable' => '可执行文件',
    'version' => '版本',
    'path' => '路径',
    'provider' => '服务',
    'kind' => '类型',
    'protocol' => '协议',
    'model' => '模型',
    'base_url' => '服务地址',
    'task_id' => '任务',
    'taskId' => '任务',
    _ => key,
  };
}

String _diagnosticDetailValue(String key, Object? value) {
  final text = '$value';
  final lower = text.toLowerCase();
  return switch (key) {
    'provider' => _serviceValueLabel(lower, fallback: text),
    'kind' => _serviceKindLabel(lower, fallback: text),
    'protocol' => _serviceProtocolLabel(lower, fallback: text),
    'task_id' => _shortTaskId(text),
    'taskId' => _shortTaskId(text),
    _ => _localizeDiagnosticText(text),
  };
}

String _openRouterAsrModelLabel(String model) {
  return switch (model.trim()) {
    'openai/whisper-large-v3' => 'Whisper Large V3',
    'x-ai/grok-stt-1.0' => 'Grok STT 1.0',
    _ => model.trim().isEmpty ? '语音识别' : model.trim(),
  };
}

String _serviceValueLabel(String lower, {required String fallback}) {
  if (lower == 'local' || lower.contains('faster_whisper')) {
    return '本机语音识别';
  }
  if (lower.contains('funasr') || lower.contains('sensevoice')) {
    return 'FunASR';
  }
  if (lower.contains('openrouter')) return 'OpenRouter';
  if (lower.contains('openai_whisper')) return 'OpenAI Whisper';
  return fallback;
}

String _serviceKindLabel(String lower, {required String fallback}) {
  return switch (lower) {
    'local_inprocess' => '本机处理',
    'local_server' => '本地服务',
    'remote' => '云端服务',
    _ => fallback,
  };
}

String _serviceProtocolLabel(String lower, {required String fallback}) {
  return switch (lower) {
    'faster_whisper' => 'faster-whisper',
    'funasr_openai' => 'FunASR 兼容接口',
    'openai_transcriptions' => 'OpenAI 转写接口',
    'openrouter_stt' => 'OpenRouter 语音转写接口',
    _ => _translationProtocolLabel(fallback),
  };
}

String _translationProtocolLabel(String apiType) {
  final normalized = apiType.trim().toLowerCase();
  return switch (normalized) {
    '' => 'OpenAI 兼容',
    'openai-compatible' => 'OpenAI 兼容',
    'openai_chat' => 'OpenAI Chat',
    'gemini-compatible' => 'Gemini 兼容',
    'gemini' => 'Gemini',
    _ => apiType,
  };
}

String? _diagnosticActiveTaskId(DesktopSnapshot? snapshot) {
  final activeTask = _diagnosticActiveTask(snapshot);
  if (activeTask != null) return _shortTaskId(activeTask.taskId);
  final taskId = _diagnosticActiveTaskRawId(snapshot);
  return taskId == null || taskId.isEmpty ? null : _shortTaskId(taskId);
}

String? _diagnosticActiveTaskRawId(DesktopSnapshot? snapshot) {
  final runtime = _stringMap(snapshot?.runtime);
  final active = _stringMap(runtime['active']);
  return _stringValue(active['task_id']) ?? _stringValue(active['taskId']);
}

TaskSummary? _diagnosticActiveTask(DesktopSnapshot? snapshot) {
  final tasks = snapshot?.tasks ?? const <TaskSummary>[];
  if (tasks.isEmpty) return null;
  final taskId = _diagnosticActiveTaskRawId(snapshot);
  if (taskId != null && taskId.isNotEmpty) {
    for (final task in tasks) {
      if (task.taskId == taskId) return task;
    }
  }
  return tasks.where((task) => task.isActive).firstOrNull;
}

List<String> _diagnosticRuntimeIds(DesktopSnapshot? snapshot, String key) {
  final runtime = _stringMap(snapshot?.runtime);
  return _objectList(runtime[key])
      .map((item) {
        if (item is String) return item;
        final map = _stringMap(item);
        return _stringValue(map['task_id']) ?? _stringValue(map['taskId']);
      })
      .whereType<String>()
      .where((item) => item.isNotEmpty)
      .toList();
}

TaskSummary? _diagnosticLatestTask(DesktopSnapshot? snapshot) {
  final tasks = snapshot?.tasks ?? const <TaskSummary>[];
  if (tasks.isEmpty) return null;
  return _diagnosticActiveTask(snapshot) ?? tasks.first;
}

TaskSummary? _diagnosticTaskById(DesktopSnapshot? snapshot, String taskId) {
  final target = taskId.trim();
  if (target.isEmpty) return null;
  for (final task in snapshot?.tasks ?? const <TaskSummary>[]) {
    if (task.taskId == target) return task;
  }
  return null;
}

String _diagnosticRuntimeTaskLinkLabel(
  DesktopSnapshot? snapshot,
  String taskId,
) {
  final task = _diagnosticTaskById(snapshot, taskId);
  if (task != null) return _diagnosticTaskSummaryLabel(task);
  return '任务 ${_shortTaskId(taskId)}';
}

String _diagnosticTaskLabel(TaskSummary task) {
  final filename = _basename(task.inputFile);
  return filename.isEmpty ? '任务 ${_shortTaskId(task.taskId)}' : filename;
}

String _diagnosticTaskSummaryLabel(TaskSummary task) {
  return '${_diagnosticTaskLabel(task)} · ${taskStatusLabel(task.status)}';
}

String? _diagnosticOutputDirectoryFor(TaskSummary task) {
  final outputPath = _diagnosticPrimaryOutputPath(task);
  if (outputPath == null || outputPath.isEmpty) return null;
  return File(outputPath).parent.path;
}

String? _diagnosticPrimaryOutputPath(TaskSummary task) {
  final direct = task.outputPath?.trim();
  if (direct != null && direct.isNotEmpty) return direct;
  for (final key in const ['srt', 'ass', 'vtt', 'lrc']) {
    final value = task.outputPaths[key]?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  for (final value in task.outputPaths.values) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

String _shortTaskId(String taskId) {
  return shortTaskIdLabel(taskId);
}

String _basename(String path) {
  if (path.isEmpty) return '';
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/');
  return parts.isEmpty ? path : parts.last;
}

String _normalizedWindowsPath(String path) {
  var value = path.trim().replaceAll('/', r'\');
  while (value.endsWith(r'\') && value.length > 3) {
    value = value.substring(0, value.length - 1);
  }
  return value.toLowerCase();
}

Color _diagnosticStatusColor(String status) {
  return switch (status) {
    'PASS' => T.ok,
    'WARN' => T.warn,
    'FAIL' => T.danger,
    _ => T.muted,
  };
}
