import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:window_manager/window_manager.dart';

import '../model/startup_args.dart';
import '../model/task_labels.dart';
import '../model/translation_settings_controller.dart';
import '../model/window_state.dart';
import '../services/app_service_client.dart';
import '../services/directory_probe.dart';
import '../services/local_service_controller.dart';
import '../services/path_opener.dart';
import '../services/settings_error.dart';
import '../services/smoke_render_capture.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';
import 'settings_common.dart';
import 'title_bar.dart';
import 'translation_settings_view.dart';

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

class _BridgeOrLocalSettingsTransport implements AppServiceTransport {
  _BridgeOrLocalSettingsTransport({
    required WindowStateBridge bridge,
    required this.service,
  }) : _bridge = WindowBridgeTransport(bridge);

  final WindowBridgeTransport _bridge;
  final LocalServiceController service;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    try {
      return await _bridge.call(method, params, timeout);
    } on Object catch (error) {
      if (!_shouldUseLocalService(error)) rethrow;
    }
    await service.start();
    final client = service.client;
    if (client == null) {
      throw PlatformException(
        code: 'service_unavailable',
        message: '本地服务暂时不可用，请稍后重试。',
      );
    }
    return client.call(method, params, timeout);
  }

  @override
  Future<void> close() async {}

  bool _shouldUseLocalService(Object error) {
    if (error is PlatformException) {
      final message = error.message ?? '';
      return error.code == 'service_unavailable' ||
          message.contains('Local Service caller') ||
          '$error'.contains('CHANNEL_UNREGISTERED') ||
          '$error'.contains('WindowChannelException');
    }
    final text = '$error';
    return text.contains('CHANNEL_UNREGISTERED') ||
        text.contains('WindowChannelException');
  }
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
    this.smoke,
  });

  final AppWindowType type;
  final WindowStateStore store;
  final WindowStateBridge bridge;
  final LocalServiceController? localServiceController;
  final PathOpener? pathOpener;
  final DirectoryWriteProbe? directoryProbe;
  final AppSmokeArgs? smoke;

  @override
  State<SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<SettingsWindow> {
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  final _endpoint = TextEditingController();
  final _device = TextEditingController(text: 'auto');
  final _externalModelPath = TextEditingController();
  final GlobalKey _renderKey = GlobalKey(debugLabel: 'settings-smoke-render');
  LocalServiceController? _smokeService;
  LocalServiceController? _ownedFallbackService;
  late final AppServiceClient _client;
  late final PathOpener _pathOpener;
  late final DirectoryWriteProbe _directoryProbe;

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
  bool _loading = false;
  bool _savingAsr = false;
  bool _testingAsr = false;
  bool _probingAsrModel = false;
  bool _asrDraftDirty = false;
  String _asrModelSource = 'managed';
  String _detectedExternalModelId = '';
  AsrOperationStatus? _activeAsrOperation;
  Timer? _asrOperationPoll;
  bool _loadingDiagnosticTasks = false;
  bool _loadingDiagnosticResult = false;

  bool get _isTranslation => widget.type == AppWindowType.translationSettings;
  bool get _isAsr => widget.type == AppWindowType.asrSettings;

  @override
  void initState() {
    super.initState();
    _client = AppServiceClient(_settingsTransport());
    _pathOpener = widget.pathOpener ?? SystemPathOpener();
    _directoryProbe = widget.directoryProbe ?? SystemDirectoryWriteProbe();
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
    _asrOperationPoll?.cancel();
    super.dispose();
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

  AppServiceTransport _settingsTransport() {
    final smoke = widget.smoke;
    if (smoke == null) {
      final service = widget.localServiceController ?? LocalServiceController();
      if (widget.localServiceController == null) {
        _ownedFallbackService = service;
      }
      return _BridgeOrLocalSettingsTransport(
        bridge: widget.bridge,
        service: service,
      );
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

  Future<void> _loadConfig() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await _client.desktopSnapshot();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        if (widget.type == AppWindowType.diagnostics) {
          _diagnosticTasks = null;
          _diagnosticResult = null;
          _selectedDiagnosticTaskId = null;
        }
        if (_isAsr) {
          _selectedAsrProvider = _asrSelectionIdForProvider(
            snapshot,
            snapshot.asrProviderName,
          );
          _loadAsrDraftFields();
          _activeAsrOperation = snapshot.asrOperations
              .where((operation) => operation.active)
              .firstOrNull;
        } else if (widget.type == AppWindowType.diagnostics) {
          _selectedDiagnosticCheck = _defaultDiagnosticSelection(snapshot);
        }
      });
      if (_activeAsrOperation?.active == true) {
        _startAsrOperationPolling();
      }
      _syncMainLabels(snapshot);
      if (widget.smoke != null) {
        if (mounted) setState(() => _loading = false);
        await _writeSettingsSmokeReport(snapshot);
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlySettingsError(error);
        _loading = false;
      });
      if (widget.smoke != null) {
        await _writeSettingsSmokeReport(null, error: error);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
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
      AppWindowType.taskProcessing => '任务处理',
      AppWindowType.main => 'TransVortex',
    };
    final status = switch (widget.type) {
      AppWindowType.translationSettings => '配好模型服务，选定默认模型',
      AppWindowType.asrSettings => '视频没有现成字幕时，用它把语音转成字幕',
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
                  AppWindowType.asrSettings => _asrBody(),
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

  Widget _asrBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DefaultBar(
          text: _savedAsrHeaderLabel(),
          busy: _loading || _savingAsr,
          error: _error,
          message: _message,
        ),
        const SizedBox(height: T.s16),
        _SegmentedEngines(
          selected: _selectedAsrProvider,
          onPick: _pickAsrProvider,
        ),
        const SizedBox(height: T.s24),
        Expanded(child: _asrDetails()),
      ],
    );
  }

  Widget _asrDetails() {
    final draft = _asrDraft(_selectedAsrProvider);
    final kind = '${draft['kind']}';
    final provider = _selectedAsrOption();
    return ToolPanel(
      footer: [
        if (kind != 'local_worker' || _asrModelSource == 'managed')
          ActionButton(
            label: _savingAsr ? '保存中' : '保存并设为默认',
            strong: true,
            onTap: _savingAsr ? null : _saveAsrProvider,
          ),
        if (kind == 'local_server' || kind == 'remote')
          ActionButton(
            label: _testingAsr ? '测试中' : '测试连接',
            onTap: _testingAsr ? null : _testAsrProvider,
          ),
      ],
      footnote: kind == 'remote' ? '密钥保存在用户级凭据文件中。' : null,
      children: [
        Row(
          children: [
            Expanded(child: Text(_asrLabelForDraft(draft), style: T.tSection)),
            _AsrStatusText(
              readiness: provider?.readiness,
              draftDirty: _asrDraftDirty,
            ),
          ],
        ),
        const SizedBox(height: T.s12),
        if (kind == 'local_worker') ...[
          _localWhisperSettings(),
        ] else if (kind == 'local_inprocess') ...[
          Row(
            children: [
              Expanded(
                child: Input(
                  label: '模型规格',
                  controller: _model,
                  onChanged: (_) => _markAsrDraftDirty(),
                ),
              ),
              const SizedBox(width: T.s12),
              Expanded(
                child: Input(
                  label: '运算设备',
                  controller: _device,
                  onChanged: (_) => _markAsrDraftDirty(),
                ),
              ),
            ],
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: Input(
                  label: kind == 'local_server' ? '本地服务地址' : '服务地址 (Base URL)',
                  controller: _baseUrl,
                  onChanged: (_) => _markAsrDraftDirty(),
                ),
              ),
              const SizedBox(width: T.s12),
              Expanded(
                child: Input(
                  label: '模型',
                  controller: _model,
                  onChanged: (_) => _markAsrDraftDirty(),
                ),
              ),
            ],
          ),
          if (kind == 'remote') ...[
            const SizedBox(height: T.s12),
            Input(
              label: 'OpenAI API key（留空则沿用已保存密钥）',
              controller: _key,
              obscure: true,
              onChanged: (_) => _markAsrDraftDirty(),
            ),
          ],
        ],
      ],
    );
  }

  Widget _localWhisperSettings() {
    final models = _snapshot?.asrModels ?? const <AsrComponentOption>[];
    final modelIds = models.isEmpty
        ? const ['small', 'medium', 'large-v3']
        : models.map((item) => item.id).toList(growable: false);
    final selectedModel = modelIds.contains(_model.text.trim())
        ? _model.text.trim()
        : 'large-v3';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('模型来源', style: T.tCaption),
        const SizedBox(height: T.s8),
        Row(
          children: [
            SegmentButton(
              label: '自动准备',
              detail: '下载并校验模型',
              selected: _asrModelSource == 'managed',
              onTap: () => _setAsrModelSource('managed'),
            ),
            const SizedBox(width: T.s12),
            SegmentButton(
              label: '使用已有模型',
              detail: '直接使用当前位置',
              selected: _asrModelSource == 'external',
              onTap: () => _setAsrModelSource('external'),
            ),
          ],
        ),
        const SizedBox(height: T.s16),
        if (_asrModelSource == 'managed')
          _managedWhisperModelSettings(modelIds, selectedModel)
        else
          _externalWhisperModelSettings(selectedModel),
      ],
    );
  }

  Widget _managedWhisperModelSettings(
    List<String> modelIds,
    String selectedModel,
  ) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _AsrSelect(
                label: 'Whisper 模型',
                value: selectedModel,
                items: {for (final id in modelIds) id: _asrModelLabel(id)},
                onChanged: _selectLocalWhisperModel,
              ),
            ),
            const SizedBox(width: T.s12),
            Expanded(child: _asrDeviceSelect()),
          ],
        ),
        const SizedBox(height: T.s16),
        _managedWhisperComponents(selectedModel, includeModel: true),
      ],
    );
  }

  Widget _externalWhisperModelSettings(String selectedModel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: ReadonlyRow(
                label: '模型目录',
                value: _externalModelPath.text.isEmpty
                    ? '尚未选择'
                    : _externalModelPath.text,
              ),
            ),
            const SizedBox(width: T.s12),
            ActionButton(label: '选择目录', onTap: _pickExternalModelPath),
          ],
        ),
        if (_detectedExternalModelId.isNotEmpty) ...[
          const SizedBox(height: T.s8),
          ReadonlyRow(
            label: '识别结果',
            value: '${_asrModelLabel(_detectedExternalModelId)} · 文件完整',
          ),
        ],
        const SizedBox(height: T.s12),
        SizedBox(width: 220, child: _asrDeviceSelect()),
        const SizedBox(height: T.s16),
        _managedWhisperComponents(selectedModel, includeModel: false),
        const SizedBox(height: T.s16),
        ActionButton(
          label: _probingAsrModel ? '验证中' : '验证并使用',
          strong: true,
          onTap: _probingAsrModel || _externalModelPath.text.isEmpty
              ? null
              : _probeManagedAsrModel,
        ),
      ],
    );
  }

  Widget _asrDeviceSelect() {
    return _AsrSelect(
      label: '运算方式',
      value: const {'auto', 'cpu', 'cuda'}.contains(_device.text)
          ? _device.text
          : 'auto',
      items: const {'auto': '自动', 'cpu': 'CPU', 'cuda': 'NVIDIA'},
      onChanged: (value) => setState(() {
        _device.text = value;
        _asrDraftDirty = true;
      }),
    );
  }

  void _setAsrModelSource(String source) {
    if (_asrModelSource == source) return;
    setState(() {
      _asrModelSource = source;
      _asrDraftDirty = true;
      _message = null;
      _error = null;
      if (source == 'managed') _detectedExternalModelId = '';
    });
  }

  Widget _managedWhisperComponents(
    String selectedModel, {
    required bool includeModel,
  }) {
    final snapshot = _snapshot;
    final runtime = snapshot?.asrRuntime;
    final model = snapshot?.asrModels.firstWhere(
      (item) => item.id == selectedModel,
      orElse: () => AsrComponentOption(id: selectedModel, kind: 'model'),
    );
    final accelerator = snapshot?.asrAccelerators.firstOrNull;
    return Column(
      children: [
        _AsrComponentRow(
          label: 'Whisper 运行组件',
          detail: runtime == null
              ? '清单不可用'
              : runtime.installed
              ? '已安装 ${runtime.version}'
              : runtime.published
              ? '未安装'
              : '尚未发布',
          installed: runtime?.installed ?? false,
          onInstall: runtime == null || runtime.installed || !runtime.published
              ? null
              : () => _startAsrInstall('runtime'),
        ),
        if (includeModel)
          _AsrComponentRow(
            label: _asrModelLabel(selectedModel),
            detail: model?.installed == true
                ? '已安装 · ${_formatBytes(model!.size)}'
                : '未安装 · ${_formatBytes(model?.size ?? 0)}',
            installed: model?.installed ?? false,
            onInstall: model?.installed == true
                ? null
                : () => _startAsrInstall('model', itemId: selectedModel),
          ),
        if (accelerator != null)
          _AsrComponentRow(
            label: 'NVIDIA 加速包',
            detail: accelerator.installed
                ? '已安装 ${accelerator.version}'
                : accelerator.published
                ? '可选 · 未安装'
                : '尚未发布',
            installed: accelerator.installed,
            actionLabel: accelerator.installed ? '检查' : '安装',
            onInstall: accelerator.installed
                ? _probeManagedAsrHardware
                : !accelerator.published
                ? null
                : () => _startAsrInstall('accelerator', itemId: accelerator.id),
          ),
        if (_activeAsrOperation != null) ...[
          const SizedBox(height: T.s12),
          _AsrOperationProgress(
            operation: _activeAsrOperation!,
            onCancel: _activeAsrOperation!.active ? _cancelAsrOperation : null,
          ),
        ],
      ],
    );
  }

  void _selectLocalWhisperModel(String modelId) {
    setState(() {
      _model.text = modelId;
      _asrDraftDirty = true;
    });
  }

  Widget _diagnosticsBody() {
    final snapshot = _snapshot;
    final checks = _diagnosticChecks(snapshot);
    final report = _diagnosticReport(snapshot);
    final selected = _selectedDiagnostic(checks);
    final selectedName = selected == null ? null : _diagnosticId(selected);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DefaultBar(
          text: _diagnosticHeader(snapshot),
          busy: _loading,
          error: _error,
          message: _message,
        ),
        const SizedBox(height: T.s16),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 230,
                child: _DiagnosticSummaryList(
                  checks: checks,
                  selectedName: selectedName,
                  onPick: _pickDiagnosticCheck,
                ),
              ),
              const SizedBox(width: T.s32),
              Expanded(
                child: _DiagnosticDetails(
                  snapshot: snapshot,
                  tasks: _diagnosticTasks,
                  selectedTaskId: _selectedDiagnosticTaskId,
                  result: _diagnosticResult,
                  outputDirectoryResults: _diagnosticOutputDirectoryResults,
                  checkingOutputDirectoryTaskIds:
                      _checkingDiagnosticOutputDirectoryTaskIds,
                  report: report,
                  checks: checks,
                  highlighted: selected,
                  onRefresh: _loading ? null : _loadConfig,
                  onRefreshTasks: _loadingDiagnosticTasks
                      ? null
                      : _loadDiagnosticTasks,
                  onOpenResult: _loadingDiagnosticResult
                      ? null
                      : _openDiagnosticResult,
                  onOpenTask: _openDiagnosticTask,
                  onOpenTaskId: _openDiagnosticTaskId,
                  onCheckOutputDirectory: _checkDiagnosticOutputDirectory,
                  onOpenTool: _openDiagnosticTool,
                  onOpenPath: _openDiagnosticPath,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _pickAsrProvider(String providerName) {
    setState(() {
      _selectedAsrProvider = providerName;
      _loadAsrDraftFields();
      _message = null;
      _error = null;
    });
  }

  void _loadAsrDraftFields() {
    final draft = _asrDraft(_selectedAsrProvider, useEditedFields: false);
    _baseUrl.text = '${draft['base_url'] ?? ''}';
    _model.text = '${draft['model'] ?? ''}';
    _endpoint.text = '${draft['endpoint'] ?? '/v1/audio/transcriptions'}';
    final local = _stringMap(draft['local']);
    _device.text = '${local['device'] ?? 'auto'}';
    final runtime = _stringMap(draft['runtime']);
    final runtimeSource = '${runtime['source'] ?? 'managed'}';
    _asrModelSource = '${local['model_source'] ?? ''}' == 'external'
        ? 'external'
        : runtimeSource == 'external'
        ? 'external'
        : 'managed';
    _externalModelPath.text = '${local['model_path'] ?? ''}';
    if (_externalModelPath.text.isEmpty && runtimeSource == 'external') {
      final environmentId = '${runtime['id'] ?? ''}';
      final savedEnvironment = _snapshot?.asrEnvironments.firstWhere(
        (item) => item.id == environmentId,
        orElse: () =>
            const PythonEnvironmentOption(id: '', pythonExecutable: ''),
      );
      _externalModelPath.text =
          '${savedEnvironment?.modelPaths[_model.text.trim()] ?? ''}';
    }
    final readiness = _selectedAsrOption()?.readiness;
    _detectedExternalModelId =
        _asrModelSource == 'external' && readiness?.canRun == true
        ? _model.text.trim()
        : '';
    _key.clear();
    _asrDraftDirty = false;
  }

  void _markAsrDraftDirty() {
    if (_asrDraftDirty) return;
    setState(() {
      _asrDraftDirty = true;
      _message = null;
      _error = null;
    });
  }

  Future<void> _saveAsrProvider({String? successMessage}) async {
    final providerName = _asrProviderNameForSelection(_selectedAsrProvider);
    setState(() {
      _savingAsr = true;
      _error = null;
      _message = null;
    });
    try {
      final latest = await _client.desktopSnapshot();
      _snapshot = latest;
      final draft = _asrDraft(providerName);
      await _client.asrProviderSave(
        providerDraft: draft,
        apiKey: _keyTextOrNull(),
        expectedVersion: latest.pipelineFileVersion,
      );
      await _loadConfig();
      if (!mounted) return;
      final savedSnapshot = _snapshot;
      final savedProvider = savedSnapshot == null
          ? null
          : _asrProviderByName(savedSnapshot, providerName);
      await widget.bridge.setAsrDefault(
        savedProvider?.displayLabel ?? _asrLabelForDraft(draft),
        configured: savedProvider?.canRun ?? false,
      );
      await widget.bridge.refreshServiceSnapshot();
      if (!mounted) return;
      setState(
        () =>
            _message = successMessage ?? '识别默认已保存：${_asrLabelForDraft(draft)}。',
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _savingAsr = false);
    }
  }

  AsrProviderOption? _selectedAsrOption() {
    final snapshot = _snapshot;
    if (snapshot == null) return null;
    final name = _asrProviderNameForSelection(_selectedAsrProvider);
    final provider = _asrProviderByName(snapshot, name);
    return provider.name.isEmpty ? null : provider;
  }

  Future<void> _startAsrInstall(String kind, {String? itemId}) async {
    setState(() {
      _error = null;
      _message = null;
    });
    try {
      final operation = await _client.asrComponentInstall(kind, itemId: itemId);
      if (!mounted) return;
      setState(() => _activeAsrOperation = operation);
      _startAsrOperationPolling();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    }
  }

  void _startAsrOperationPolling() {
    _asrOperationPoll?.cancel();
    _asrOperationPoll = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_pollAsrOperation()),
    );
  }

  Future<void> _pollAsrOperation() async {
    final operationId = _activeAsrOperation?.id;
    if (operationId == null || operationId.isEmpty) return;
    try {
      final operation = await _client.asrOperation(operationId);
      if (!mounted || _activeAsrOperation?.id != operationId) return;
      setState(() => _activeAsrOperation = operation);
      if (!operation.active) {
        _asrOperationPoll?.cancel();
        _asrOperationPoll = null;
        await _loadConfig();
        if (!mounted) return;
        setState(() {
          _activeAsrOperation = operation;
          if (operation.state == 'completed') {
            _message = '本机 Whisper 组件已就绪。';
          } else if (operation.state == 'failed') {
            _error = operation.message.isEmpty
                ? '安装失败：${operation.errorCode}'
                : operation.message;
          } else if (operation.state == 'cancelled') {
            _message = '安装已取消，可继续下载。';
          }
        });
      }
    } on Object catch (error) {
      _asrOperationPoll?.cancel();
      _asrOperationPoll = null;
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    }
  }

  Future<void> _cancelAsrOperation() async {
    final operationId = _activeAsrOperation?.id;
    if (operationId == null || operationId.isEmpty) return;
    try {
      final operation = await _client.asrOperationCancel(operationId);
      if (!mounted) return;
      setState(() => _activeAsrOperation = operation);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    }
  }

  Future<void> _probeManagedAsrHardware() async {
    setState(() {
      _testingAsr = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await _client.probeAsrHardware();
      final cuda = _stringMap(result['cuda']);
      if (!mounted) return;
      await _loadConfig();
      if (!mounted) return;
      setState(() {
        if (result['ok'] == true && cuda['available'] == true) {
          _message = 'NVIDIA 硬件检查通过。';
        } else {
          _error = '${result['message'] ?? 'NVIDIA 硬件不可用，请改用 CPU。'}';
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _testingAsr = false);
    }
  }

  Future<void> _pickExternalModelPath() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择 faster-whisper 模型目录',
    );
    if (path == null || path.isEmpty || !mounted) return;
    setState(() {
      _externalModelPath.text = path;
      _asrModelSource = 'external';
      _detectedExternalModelId = '';
      _asrDraftDirty = true;
      _message = null;
      _error = null;
    });
  }

  Future<void> _probeManagedAsrModel() async {
    setState(() {
      _probingAsrModel = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await _client.probeManagedAsrModel(
        modelPath: _externalModelPath.text,
        device: _device.text,
      );
      if (!mounted) return;
      if (result['ok'] == true) {
        final model = _stringMap(result['model']);
        final modelId = '${model['model_id'] ?? ''}'.trim();
        if (modelId.isEmpty) {
          setState(() => _error = '无法识别这个模型目录。');
        } else {
          setState(() {
            _detectedExternalModelId = modelId;
            _model.text = modelId;
            _asrModelSource = 'external';
            _asrDraftDirty = true;
          });
          await _saveAsrProvider(
            successMessage: '已有 ${_asrModelLabel(modelId)} 已验证并设为默认。',
          );
        }
      } else {
        final code = '${result['code'] ?? 'model_probe_failed'}';
        final message = '${result['message'] ?? ''}'.trim();
        setState(() {
          _error = _friendlyAsrModelProbeError(code, message);
        });
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _probingAsrModel = false);
    }
  }

  Future<void> _testAsrProvider() async {
    setState(() {
      _testingAsr = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await _client.asrProviderTest(
        providerDraft: _asrDraft(_selectedAsrProvider),
      );
      if (!mounted) return;
      setState(() {
        if (result['ok'] == true) {
          _message = '连接和最小识别测试通过。';
        } else {
          final message = '${result['message'] ?? ''}'.trim();
          _error = message.isEmpty
              ? '连接测试失败：${result['code'] ?? 'connection_failed'}'
              : message;
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _testingAsr = false);
    }
  }

  Map<String, Object?> _asrDraft(
    String selectedProvider, {
    bool useEditedFields = true,
  }) {
    final providerName = _asrProviderNameForSelection(selectedProvider);
    final existing = _snapshot == null
        ? null
        : _asrProviderByName(_snapshot!, providerName);
    final hasExisting = existing != null && existing.name.isNotEmpty;
    final kind = hasExisting && existing.kind != 'local_inprocess'
        ? existing.kind
        : _defaultAsrKind(selectedProvider);
    final protocol = hasExisting
        ? existing.protocol
        : _defaultAsrProtocol(kind, selectedProvider);
    final editedModel = useEditedFields ? _model.text.trim() : '';
    final editedBaseUrl = useEditedFields ? _baseUrl.text.trim() : '';
    final editedEndpoint = useEditedFields ? _endpoint.text.trim() : '';
    final model = editedModel.isNotEmpty
        ? editedModel
        : (hasExisting ? existing.model : _defaultAsrModel(kind, protocol));
    final baseUrl = editedBaseUrl.isNotEmpty
        ? editedBaseUrl
        : (hasExisting ? existing.baseUrl : _defaultAsrBaseUrl(kind, protocol));
    final endpoint = editedEndpoint.isNotEmpty
        ? editedEndpoint
        : (hasExisting && existing.endpoint.isNotEmpty
              ? existing.endpoint
              : '/v1/audio/transcriptions');
    final auth = hasExisting
        ? _stringMap(existing.raw['auth'])
        : const <String, Object?>{};
    final local = hasExisting
        ? Map<String, Object?>.from(_stringMap(existing.raw['local']))
        : <String, Object?>{};
    local['model_size'] = model;
    if (kind == 'local_worker' && useEditedFields) {
      local['model_source'] = _asrModelSource;
      local['model_path'] = _asrModelSource == 'external'
          ? _externalModelPath.text.trim()
          : '';
    }
    local['device'] = _device.text.trim().isEmpty
        ? 'auto'
        : _device.text.trim();
    final runtime = hasExisting
        ? Map<String, Object?>.from(_stringMap(existing.raw['runtime']))
        : <String, Object?>{};
    if (kind == 'local_worker' && useEditedFields) {
      runtime['source'] = 'managed';
      runtime['id'] = 'managed:faster-whisper';
    }
    return {
      if (hasExisting) ...existing.raw,
      'name': providerName,
      'kind': kind,
      'protocol': protocol,
      'model': model,
      if (kind != 'local_inprocess' && kind != 'local_worker')
        'base_url': baseUrl,
      if (kind != 'local_inprocess' && kind != 'local_worker')
        'endpoint': endpoint,
      if (kind == 'remote')
        'auth': auth.isNotEmpty
            ? auth
            : {
                'type': 'bearer',
                'env_key': 'OPENAI_API_KEY',
                'credential_id': providerName,
              }
      else
        'auth': {'type': 'none'},
      if (kind == 'local_inprocess' || kind == 'local_worker') 'local': local,
      if (kind == 'local_worker') 'runtime': runtime,
    };
  }

  AsrProviderOption _asrProviderByName(DesktopSnapshot snapshot, String? name) {
    return snapshot.asrProviders.firstWhere(
      (provider) => provider.name == name,
      orElse: () => const AsrProviderOption(
        name: '',
        kind: 'remote',
        protocol: 'openai_transcriptions',
        model: '',
      ),
    );
  }

  String _asrProviderNameForSelection(String selected) {
    final snapshot = _snapshot;
    if (snapshot != null) {
      final selectedExisting = _asrProviderByName(snapshot, selected);
      if (selectedExisting.name.isNotEmpty) return selectedExisting.name;
      for (final provider in snapshot.asrProviders) {
        if (_asrPresetIdFor(provider) == selected) return provider.name;
      }
    }
    return selected;
  }

  String _asrSelectionIdForProvider(DesktopSnapshot snapshot, String? name) {
    if (name == null || name.isEmpty) return 'faster_whisper_large_v3';
    final provider = _asrProviderByName(snapshot, name);
    return provider.name.isEmpty
        ? _asrPresetIdForName(name)
        : _asrPresetIdFor(provider);
  }

  String _asrPresetIdFor(AsrProviderOption provider) {
    if (provider.kind == 'local_worker' || provider.kind == 'local_inprocess') {
      return 'faster_whisper_large_v3';
    }
    if (provider.kind == 'local_server' ||
        provider.protocol == 'funasr_openai') {
      return 'funasr_sensevoice_local';
    }
    return 'openai_whisper';
  }

  String _defaultAsrKind(String providerName) {
    final preset = _asrPresetIdForName(providerName);
    if (preset == 'faster_whisper_large_v3') return 'local_worker';
    if (preset == 'funasr_sensevoice_local') return 'local_server';
    return 'remote';
  }

  String _defaultAsrProtocol(String kind, String providerName) {
    if (kind == 'local_worker' || kind == 'local_inprocess') {
      return 'faster_whisper';
    }
    if (kind == 'local_server' ||
        _asrPresetIdForName(providerName) == 'funasr_sensevoice_local') {
      return 'funasr_openai';
    }
    return 'openai_transcriptions';
  }

  String _asrPresetIdForName(String providerName) {
    final lower = providerName.toLowerCase();
    if (providerName == 'faster_whisper_large_v3' ||
        lower == 'local' ||
        lower.contains('faster_whisper') ||
        lower.contains('faster-whisper')) {
      return 'faster_whisper_large_v3';
    }
    if (providerName == 'funasr_sensevoice_local' ||
        lower.contains('funasr') ||
        lower.contains('sensevoice')) {
      return 'funasr_sensevoice_local';
    }
    return 'openai_whisper';
  }

  String _defaultAsrModel(String kind, String protocol) {
    if (kind == 'local_worker' || kind == 'local_inprocess') {
      return 'large-v3';
    }
    if (protocol == 'funasr_openai') return 'sensevoice';
    return 'whisper-1';
  }

  String _defaultAsrBaseUrl(String kind, String protocol) {
    if (kind == 'local_server' || protocol == 'funasr_openai') {
      return 'http://127.0.0.1:8899';
    }
    return 'https://api.openai.com/v1';
  }

  String _asrLabelForDraft(Map<String, Object?> draft) {
    return switch (draft['kind']) {
      'local_worker' || 'local_inprocess' => '本机 Whisper',
      'local_server' =>
        draft['protocol'] == 'funasr_openai' ? 'FunASR' : '本地服务',
      'remote' => 'OpenAI Whisper',
      _ => '${draft['name']}',
    };
  }

  String _asrHeaderLabel(String providerName) {
    final draft = _asrDraft(providerName, useEditedFields: false);
    return '${_asrLabelForDraft(draft)} · ${draft['model']}';
  }

  String _savedAsrHeaderLabel() {
    final snapshot = _snapshot;
    if (snapshot == null) return '默认识别：正在读取';
    final providerName = snapshot.asrProviderName;
    if (providerName == null || providerName.isEmpty) return '默认识别：尚未设置';
    return '默认识别：${_asrHeaderLabel(providerName)}';
  }

  String? _keyTextOrNull() {
    final text = _key.text.trim();
    return text.isEmpty ? null : text;
  }

  Map<String, Object?> _diagnosticReport(DesktopSnapshot? snapshot) {
    return _stringMap(snapshot?.environment);
  }

  List<Map<String, Object?>> _diagnosticChecks(DesktopSnapshot? snapshot) {
    return _objectList(
      _diagnosticReport(snapshot)['checks'],
    ).map(_stringMap).where((check) => check.isNotEmpty).toList();
  }

  String _diagnosticStatus(DesktopSnapshot? snapshot) {
    final status = _stringValue(_diagnosticReport(snapshot)['status']);
    return status == null || status.isEmpty ? 'UNKNOWN' : status;
  }

  String _diagnosticHeader(DesktopSnapshot? snapshot) {
    if (snapshot == null) return '诊断：等待服务';
    final checks = _diagnosticChecks(snapshot);
    final fail = _diagnosticCount(checks, 'FAIL');
    final warn = _diagnosticCount(checks, 'WARN');
    final pass = _diagnosticCount(checks, 'PASS');
    return '诊断：${_diagnosticStatusLabel(_diagnosticStatus(snapshot))} · 通过 $pass / 警告 $warn / 失败 $fail';
  }

  String? _defaultDiagnosticSelection(DesktopSnapshot snapshot) {
    final checks = _diagnosticChecks(snapshot);
    if (checks.isEmpty) return null;
    final current = _selectedDiagnosticCheck;
    if (current != null &&
        checks.any((check) => _diagnosticId(check) == current)) {
      return current;
    }
    for (final check in checks) {
      final status = _diagnosticCheckStatus(check);
      if (status == 'FAIL' || status == 'WARN') {
        return _diagnosticId(check);
      }
    }
    return _diagnosticId(checks.first);
  }

  Map<String, Object?>? _selectedDiagnostic(List<Map<String, Object?>> checks) {
    if (checks.isEmpty) return null;
    final selectedName = _selectedDiagnosticCheck;
    if (selectedName != null) {
      for (final check in checks) {
        if (_diagnosticId(check) == selectedName) return check;
      }
    }
    return checks.first;
  }

  void _pickDiagnosticCheck(String name) {
    setState(() {
      _selectedDiagnosticCheck = name;
      _message = null;
      _error = null;
    });
  }

  Future<void> _openDiagnosticTool(AppWindowType type, {String? taskId}) async {
    try {
      await widget.bridge.openToolWindow(type, taskId: taskId);
      if (!mounted) return;
      setState(() {
        _message = '已打开${type.title}';
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _message = null;
        _error = '打开${type.title}失败：${_friendlySettingsError(error)}';
      });
    }
  }

  Future<void> _loadDiagnosticTasks() async {
    setState(() {
      _loadingDiagnosticTasks = true;
      _message = null;
      _error = null;
    });
    try {
      final tasks = await _client.taskList();
      if (!mounted) return;
      setState(() {
        _diagnosticTasks = tasks;
        final ids = tasks.map((task) => task.taskId).toSet();
        _diagnosticOutputDirectoryResults.removeWhere(
          (taskId, _) => !ids.contains(taskId),
        );
        _message = '已读取 ${tasks.length} 个最近任务。';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _loadingDiagnosticTasks = false);
    }
  }

  Future<void> _openDiagnosticResult(TaskSummary task) async {
    if (!task.isDone) return;
    setState(() {
      _loadingDiagnosticResult = true;
      _selectedDiagnosticTaskId = task.taskId;
      _diagnosticResult = null;
      _message = null;
      _error = null;
    });
    try {
      final result = await _client.openTaskResult(task.taskId);
      if (!mounted) return;
      setState(() {
        _diagnosticResult = result;
        _message = '已读取结果摘要。';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _loadingDiagnosticResult = false);
    }
  }

  Future<void> _openDiagnosticTask(TaskSummary task) {
    return _openDiagnosticTool(
      AppWindowType.taskProcessing,
      taskId: task.taskId,
    );
  }

  Future<void> _openDiagnosticTaskId(String taskId) {
    return _openDiagnosticTool(AppWindowType.taskProcessing, taskId: taskId);
  }

  Future<void> _checkDiagnosticOutputDirectory(TaskSummary task) async {
    final dir = _diagnosticOutputDirectoryFor(task);
    if (dir == null || dir.isEmpty) {
      setState(() {
        _selectedDiagnosticTaskId = task.taskId;
        _message = null;
        _error = '这个任务没有结果目录记录。';
      });
      return;
    }
    setState(() {
      _selectedDiagnosticTaskId = task.taskId;
      _checkingDiagnosticOutputDirectoryTaskIds.add(task.taskId);
      _message = null;
      _error = null;
    });
    try {
      final result = await _directoryProbe.checkWritable(dir);
      if (!mounted) return;
      setState(() {
        _diagnosticOutputDirectoryResults[task.taskId] = result;
        _message = result.ok ? '结果目录可写：$dir' : '结果目录不可写：${result.message}';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) {
        setState(() {
          _checkingDiagnosticOutputDirectoryTaskIds.remove(task.taskId);
        });
      }
    }
  }

  Future<Map<String, Object?>> _diagnosticSmokeOutputDirectoryCheck(
    DesktopSnapshot? snapshot,
  ) async {
    final task = _diagnosticLatestTask(snapshot);
    if (task == null) {
      return const {
        'diagnostic_output_dir_checked': false,
        'diagnostic_output_dir_writable': false,
        'diagnostic_output_dir_task_id': '',
        'diagnostic_output_dir_path': '',
        'diagnostic_output_dir_message': '没有任务记录',
      };
    }
    final dir = _diagnosticOutputDirectoryFor(task);
    if (dir == null || dir.isEmpty) {
      return {
        'diagnostic_output_dir_checked': false,
        'diagnostic_output_dir_writable': false,
        'diagnostic_output_dir_task_id': task.taskId,
        'diagnostic_output_dir_path': '',
        'diagnostic_output_dir_message': '没有结果目录记录',
      };
    }
    final result = await _directoryProbe.checkWritable(dir);
    return {
      'diagnostic_output_dir_checked': true,
      'diagnostic_output_dir_writable': result.ok,
      'diagnostic_output_dir_task_id': task.taskId,
      'diagnostic_output_dir_path': dir,
      'diagnostic_output_dir_message': result.message,
    };
  }

  Future<void> _openDiagnosticPath(_DiagnosticPathAction action) async {
    try {
      await _pathOpener.openDirectory(action.path);
      if (!mounted) return;
      setState(() {
        _message = action.successMessage;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _message = null;
        _error = '打开目录失败：${_friendlySettingsError(error)}';
      });
    }
  }
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
    AppWindowType.taskProcessing => '查看任务处理',
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

String _serviceValueLabel(String lower, {required String fallback}) {
  if (lower == 'local' || lower.contains('faster_whisper')) {
    return '本机语音识别';
  }
  if (lower.contains('funasr') || lower.contains('sensevoice')) {
    return 'FunASR';
  }
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

Color _diagnosticStatusColor(String status) {
  return switch (status) {
    'PASS' => T.ok,
    'WARN' => T.warn,
    'FAIL' => T.danger,
    _ => T.muted,
  };
}

class _SegmentedEngines extends StatelessWidget {
  const _SegmentedEngines({required this.selected, required this.onPick});

  final String selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    const items = [
      ('faster_whisper_large_v3', '本机 Whisper', '本机运行'),
      ('openai_whisper', 'OpenAI Whisper', '云端识别'),
      ('funasr_sensevoice_local', 'FunASR', '本地服务'),
    ];
    return Row(
      children: [
        for (final item in items) ...[
          SegmentButton(
            label: item.$2,
            detail: item.$3,
            selected: selected == item.$1,
            onTap: () => onPick(item.$1),
          ),
          const SizedBox(width: T.s8),
        ],
      ],
    );
  }
}

class _AsrSelect extends StatelessWidget {
  const _AsrSelect({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String value;
  final Map<String, String> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = items.containsKey(value) ? value : items.keys.first;
    return DropdownButtonFormField<String>(
      key: ValueKey('$label:$selected'),
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        filled: true,
        fillColor: T.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: T.s12,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(T.rMd),
          borderSide: const BorderSide(color: T.line),
        ),
      ),
      items: [
        for (final entry in items.entries)
          DropdownMenuItem<String>(
            value: entry.key,
            child: Text(entry.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (next) {
        if (next != null) onChanged(next);
      },
    );
  }
}

class _AsrStatusText extends StatelessWidget {
  const _AsrStatusText({this.readiness, this.draftDirty = false});

  final AsrReadiness? readiness;
  final bool draftDirty;

  @override
  Widget build(BuildContext context) {
    if (draftDirty) {
      return Text(
        '尚未保存',
        style: T.tCaption.copyWith(color: T.accentStrong, fontWeight: T.wBold),
      );
    }
    final value = readiness;
    final state = value?.state ?? 'unavailable';
    final color = switch (state) {
      'ready' => T.ok,
      'checking' => T.accentStrong,
      'needs_action' => T.warn,
      _ => T.danger,
    };
    return Text(
      value?.statusLabel ?? '状态未知',
      style: T.tCaption.copyWith(color: color, fontWeight: T.wBold),
    );
  }
}

class _AsrComponentRow extends StatelessWidget {
  const _AsrComponentRow({
    required this.label,
    required this.detail,
    required this.installed,
    this.actionLabel = '安装',
    this.onInstall,
  });

  final String label;
  final String detail;
  final bool installed;
  final String actionLabel;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: T.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(label, style: T.tBody),
                Text(detail, style: T.tCaption),
              ],
            ),
          ),
          if (onInstall != null)
            ActionButton(label: actionLabel, onTap: onInstall)
          else if (installed)
            Text('可用', style: T.tCaption.copyWith(color: T.ok))
          else
            ActionButton(label: actionLabel, onTap: null),
        ],
      ),
    );
  }
}

class _AsrOperationProgress extends StatelessWidget {
  const _AsrOperationProgress({required this.operation, this.onCancel});

  final AsrOperationStatus operation;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final progress = operation.progress;
    final percent = progress == null ? '' : '${(progress * 100).round()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                operation.active
                    ? '${operation.itemId} · $percent'
                    : operation.state == 'completed'
                    ? '${operation.itemId} · 已完成'
                    : '${operation.itemId} · ${operation.state}',
                style: T.tCaption,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onCancel != null) ActionButton(label: '取消', onTap: onCancel),
          ],
        ),
        const SizedBox(height: T.s8),
        LinearProgressIndicator(
          value: progress,
          minHeight: 4,
          color: T.accent,
          backgroundColor: T.line,
        ),
        if (operation.currentFile.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            operation.currentFile,
            style: T.tCaption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

String _asrModelLabel(String modelId) {
  return switch (modelId) {
    'small' => 'Whisper Small',
    'medium' => 'Whisper Medium',
    'large-v3' => 'Whisper Large v3',
    _ => modelId,
  };
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '大小未知';
  const gib = 1024 * 1024 * 1024;
  const mib = 1024 * 1024;
  if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(1)} GB';
  return '${(bytes / mib).toStringAsFixed(0)} MB';
}

class _DiagnosticSummaryList extends StatelessWidget {
  const _DiagnosticSummaryList({
    required this.checks,
    required this.selectedName,
    required this.onPick,
  });

  final List<Map<String, Object?>> checks;
  final String? selectedName;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final actionable = checks
        .where((check) => _diagnosticCheckStatus(check) != 'PASS')
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('检查项', style: T.tSection),
        const SizedBox(height: T.s12),
        if (checks.isEmpty)
          const Text('暂无诊断结果', style: T.tCaption)
        else
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final check in checks)
                  _DiagnosticRow(
                    label: _diagnosticDisplayName(check),
                    detail: _diagnosticHint(check),
                    status: _diagnosticCheckStatus(check),
                    selected: _diagnosticId(check) == selectedName,
                    onTap: () => onPick(_diagnosticId(check)),
                  ),
              ],
            ),
          ),
        if (checks.isNotEmpty) ...[
          const SizedBox(height: T.s12),
          Text('需要处理：$actionable', style: T.tCaption),
        ],
      ],
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({
    required this.label,
    required this.detail,
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String detail;
  final String status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = _diagnosticStatusColor(status);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 46),
          decoration: BoxDecoration(
            color: selected ? T.accentSoft : const Color(0x00000000),
            border: const Border(bottom: BorderSide(color: T.line, width: 1)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: T.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$label · ${_diagnosticStatusLabel(status)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.tBody.copyWith(
                        color: color,
                        fontWeight: selected ? T.wBold : T.wMedium,
                      ),
                    ),
                    if (detail.isNotEmpty)
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: T.tCaption,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiagnosticDetails extends StatelessWidget {
  const _DiagnosticDetails({
    required this.snapshot,
    required this.tasks,
    required this.selectedTaskId,
    required this.result,
    required this.outputDirectoryResults,
    required this.checkingOutputDirectoryTaskIds,
    required this.report,
    required this.checks,
    required this.highlighted,
    required this.onRefresh,
    required this.onRefreshTasks,
    required this.onOpenResult,
    required this.onOpenTask,
    required this.onOpenTaskId,
    required this.onCheckOutputDirectory,
    required this.onOpenTool,
    required this.onOpenPath,
  });

  final DesktopSnapshot? snapshot;
  final List<TaskSummary>? tasks;
  final String? selectedTaskId;
  final TaskResultWorkspace? result;
  final Map<String, DirectoryProbeResult> outputDirectoryResults;
  final Set<String> checkingOutputDirectoryTaskIds;
  final Map<String, Object?> report;
  final List<Map<String, Object?>> checks;
  final Map<String, Object?>? highlighted;
  final VoidCallback? onRefresh;
  final VoidCallback? onRefreshTasks;
  final ValueChanged<TaskSummary>? onOpenResult;
  final ValueChanged<TaskSummary>? onOpenTask;
  final ValueChanged<String>? onOpenTaskId;
  final ValueChanged<TaskSummary>? onCheckOutputDirectory;
  final _DiagnosticToolOpener onOpenTool;
  final ValueChanged<_DiagnosticPathAction> onOpenPath;

  @override
  Widget build(BuildContext context) {
    final rootDir = _stringValue(report['root_dir']) ?? '未知';
    final providersFile = _stringValue(report['providers_file']) ?? '未知';
    final artifactsDir = _stringValue(report['artifacts_dir']) ?? '未加载';
    final check = highlighted;
    final repairTarget = check == null ? null : _diagnosticRepairTarget(check);
    final pathAction = check == null
        ? null
        : _diagnosticPathAction(check, report);
    return ToolPanel(
      footer: [
        if (repairTarget != null)
          ActionButton(
            label: _diagnosticRepairLabel(repairTarget),
            onTap: () => onOpenTool(
              repairTarget,
              taskId: repairTarget == AppWindowType.taskProcessing
                  ? _diagnosticRepairTaskId(check!, snapshot)
                  : null,
            ),
          ),
        if (pathAction != null)
          ActionButton(
            label: pathAction.label,
            onTap: () => onOpenPath(pathAction),
          ),
        ActionButton(
          label: onRefresh == null ? '刷新中' : '刷新诊断',
          strong: true,
          onTap: onRefresh,
        ),
      ],
      footnote: '诊断读取本机配置、依赖和翻译服务协议预检；不会上传音视频或密钥。',
      children: [
        _DiagnosticMetricStrip(checks: checks),
        const SizedBox(height: T.s16),
        ReadonlyRow(label: '项目根目录', value: rootDir),
        const SizedBox(height: T.s12),
        ReadonlyRow(label: '翻译配置文件', value: providersFile),
        const SizedBox(height: T.s12),
        ReadonlyRow(label: '产物目录', value: artifactsDir),
        const SizedBox(height: T.s24),
        Text(
          check == null ? '暂无需要处理的项目' : _diagnosticDisplayName(check),
          style: T.tSection,
        ),
        const SizedBox(height: T.s8),
        if (check == null)
          const Text('当前没有诊断结果。', style: T.tCaption)
        else ...[
          Wrap(
            spacing: T.s8,
            runSpacing: T.s8,
            children: [
              _DiagnosticBadge(status: _diagnosticCheckStatus(check)),
              if (_stringValue(check['code']) != null)
                _DiagnosticCode(
                  label: _diagnosticCodeLabel(_stringValue(check['code'])!),
                ),
            ],
          ),
          const SizedBox(height: T.s12),
          Text(_diagnosticHint(check), style: T.tBody),
          const SizedBox(height: T.s8),
          Text(_diagnosticMessage(check), style: T.tCaption),
          for (final line in _diagnosticDetailLines(check)) ...[
            const SizedBox(height: T.s8),
            Text(line, style: T.tCaption, overflow: TextOverflow.ellipsis),
          ],
        ],
        const SizedBox(height: T.s24),
        _DiagnosticTaskContext(snapshot: snapshot, onOpenTaskId: onOpenTaskId),
        const SizedBox(height: T.s16),
        _DiagnosticRecentTasks(
          snapshot: snapshot,
          tasks: tasks,
          selectedTaskId: selectedTaskId,
          result: result,
          outputDirectoryResults: outputDirectoryResults,
          checkingOutputDirectoryTaskIds: checkingOutputDirectoryTaskIds,
          onRefreshTasks: onRefreshTasks,
          onOpenResult: onOpenResult,
          onOpenTask: onOpenTask,
          onCheckOutputDirectory: onCheckOutputDirectory,
        ),
      ],
    );
  }
}

class _DiagnosticTaskContext extends StatelessWidget {
  const _DiagnosticTaskContext({
    required this.snapshot,
    required this.onOpenTaskId,
  });

  final DesktopSnapshot? snapshot;
  final ValueChanged<String>? onOpenTaskId;

  @override
  Widget build(BuildContext context) {
    final activeTask = _diagnosticActiveTask(snapshot);
    final activeTaskId = _diagnosticActiveTaskId(snapshot);
    final activeTaskLabel = activeTask != null
        ? _diagnosticTaskSummaryLabel(activeTask)
        : activeTaskId == null
        ? '无'
        : '任务 $activeTaskId';
    final latest = _diagnosticLatestTask(snapshot);
    final taskCount = snapshot?.tasks.length ?? 0;
    final queued = _diagnosticRuntimeIds(snapshot, 'queued');
    final interrupted = _diagnosticRuntimeIds(snapshot, 'interrupted');
    final latestLabel = latest == null
        ? '无'
        : _diagnosticTaskSummaryLabel(latest);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('任务上下文', style: T.tSection),
          const SizedBox(height: T.s8),
          ReadonlyRow(label: '当前任务', value: activeTaskLabel),
          const SizedBox(height: T.s8),
          ReadonlyRow(label: '任务数', value: '$taskCount'),
          const SizedBox(height: T.s8),
          ReadonlyRow(label: '队列', value: '${queued.length} 个等待'),
          if (queued.isNotEmpty) ...[
            const SizedBox(height: T.s8),
            _DiagnosticRuntimeTaskLinks(
              label: '等待任务',
              snapshot: snapshot,
              taskIds: queued,
              onOpenTaskId: onOpenTaskId,
            ),
          ],
          const SizedBox(height: T.s8),
          ReadonlyRow(label: '中断任务', value: '${interrupted.length} 个'),
          if (interrupted.isNotEmpty) ...[
            const SizedBox(height: T.s8),
            _DiagnosticRuntimeTaskLinks(
              label: '中断线索',
              snapshot: snapshot,
              taskIds: interrupted,
              onOpenTaskId: onOpenTaskId,
            ),
          ],
          const SizedBox(height: T.s8),
          ReadonlyRow(label: '最新任务', value: latestLabel),
        ],
      ),
    );
  }
}

class _DiagnosticRuntimeTaskLinks extends StatelessWidget {
  const _DiagnosticRuntimeTaskLinks({
    required this.label,
    required this.snapshot,
    required this.taskIds,
    required this.onOpenTaskId,
  });

  final String label;
  final DesktopSnapshot? snapshot;
  final List<String> taskIds;
  final ValueChanged<String>? onOpenTaskId;

  @override
  Widget build(BuildContext context) {
    final uniqueTaskIds = <String>{
      for (final taskId in taskIds)
        if (taskId.trim().isNotEmpty) taskId.trim(),
    }.toList(growable: false);
    final visibleTaskIds = uniqueTaskIds.take(3).toList(growable: false);
    if (uniqueTaskIds.isEmpty) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 96, child: Text(label, style: T.tCaption)),
        Expanded(
          child: Wrap(
            spacing: T.s8,
            runSpacing: T.s8,
            children: [
              for (final taskId in visibleTaskIds)
                _DiagnosticRuntimeTaskLink(
                  label: _diagnosticRuntimeTaskLinkLabel(snapshot, taskId),
                  onTap: onOpenTaskId == null
                      ? null
                      : () => onOpenTaskId!(taskId),
                ),
              if (uniqueTaskIds.length > visibleTaskIds.length)
                Text(
                  '另有 ${uniqueTaskIds.length - visibleTaskIds.length} 个',
                  style: T.tCaption,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DiagnosticRuntimeTaskLink extends StatelessWidget {
  const _DiagnosticRuntimeTaskLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 5),
          decoration: BoxDecoration(
            color: enabled ? T.accentSoft : T.surface,
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(color: enabled ? T.accent : T.line),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.tCaption.copyWith(
              color: enabled ? T.accentStrong : T.muted,
              fontWeight: enabled ? T.wBold : T.wMedium,
            ),
          ),
        ),
      ),
    );
  }
}

class _DiagnosticRecentTasks extends StatelessWidget {
  const _DiagnosticRecentTasks({
    required this.snapshot,
    required this.tasks,
    required this.selectedTaskId,
    required this.result,
    required this.outputDirectoryResults,
    required this.checkingOutputDirectoryTaskIds,
    required this.onRefreshTasks,
    required this.onOpenResult,
    required this.onOpenTask,
    required this.onCheckOutputDirectory,
  });

  final DesktopSnapshot? snapshot;
  final List<TaskSummary>? tasks;
  final String? selectedTaskId;
  final TaskResultWorkspace? result;
  final Map<String, DirectoryProbeResult> outputDirectoryResults;
  final Set<String> checkingOutputDirectoryTaskIds;
  final VoidCallback? onRefreshTasks;
  final ValueChanged<TaskSummary>? onOpenResult;
  final ValueChanged<TaskSummary>? onOpenTask;
  final ValueChanged<TaskSummary>? onCheckOutputDirectory;

  @override
  Widget build(BuildContext context) {
    final visibleTasks = (tasks ?? snapshot?.tasks ?? const <TaskSummary>[])
        .take(5)
        .toList();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('最近任务', style: T.tSection)),
              _MiniTextButton(
                label: onRefreshTasks == null ? '刷新中' : '刷新',
                onTap: onRefreshTasks,
              ),
            ],
          ),
          const SizedBox(height: T.s8),
          if (visibleTasks.isEmpty)
            const Text('还没有任务记录', style: T.tCaption)
          else
            for (final task in visibleTasks) ...[
              _DiagnosticTaskRow(
                task: task,
                selected: task.taskId == selectedTaskId,
                outputDirectoryResult: outputDirectoryResults[task.taskId],
                checkingOutputDirectory: checkingOutputDirectoryTaskIds
                    .contains(task.taskId),
                onOpenTask: onOpenTask == null ? null : () => onOpenTask!(task),
                onOpenResult: task.isDone && onOpenResult != null
                    ? () => onOpenResult!(task)
                    : null,
                onCheckOutputDirectory:
                    _diagnosticOutputDirectoryFor(task) == null ||
                        onCheckOutputDirectory == null
                    ? null
                    : () => onCheckOutputDirectory!(task),
              ),
              const SizedBox(height: T.s8),
            ],
          if (result != null) ...[
            const SizedBox(height: T.s4),
            _DiagnosticResultSummary(result: result!),
          ],
        ],
      ),
    );
  }
}

class _DiagnosticTaskRow extends StatelessWidget {
  const _DiagnosticTaskRow({
    required this.task,
    required this.selected,
    required this.outputDirectoryResult,
    required this.checkingOutputDirectory,
    required this.onOpenTask,
    required this.onOpenResult,
    required this.onCheckOutputDirectory,
  });

  final TaskSummary task;
  final bool selected;
  final DirectoryProbeResult? outputDirectoryResult;
  final bool checkingOutputDirectory;
  final VoidCallback? onOpenTask;
  final VoidCallback? onOpenResult;
  final VoidCallback? onCheckOutputDirectory;

  @override
  Widget build(BuildContext context) {
    final canOpen = onOpenResult != null;
    final outputCheckLabel = checkingOutputDirectory
        ? '检查中'
        : onCheckOutputDirectory == null
        ? '无目录'
        : '检查目录';
    return Container(
      decoration: BoxDecoration(
        border: const Border(bottom: BorderSide(color: T.line)),
      ),
      padding: const EdgeInsets.only(bottom: T.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _diagnosticTaskLabel(task),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tBody.copyWith(
                    color: selected ? T.accentStrong : T.ink,
                    fontWeight: selected ? T.wBold : T.wMedium,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '状态：${taskStatusLabel(task.status)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption,
                ),
                if (outputDirectoryResult != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    outputDirectoryResult!.ok
                        ? '结果目录：可写'
                        : '结果目录：${outputDirectoryResult!.message}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: T.tCaption.copyWith(
                      color: outputDirectoryResult!.ok ? T.ok : T.danger,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: T.s8),
          _MiniTextButton(label: '任务处理', onTap: onOpenTask),
          const SizedBox(width: T.s8),
          _MiniTextButton(label: canOpen ? '结果摘要' : '未完成', onTap: onOpenResult),
          const SizedBox(width: T.s8),
          _MiniTextButton(
            label: outputCheckLabel,
            onTap: checkingOutputDirectory ? null : onCheckOutputDirectory,
          ),
        ],
      ),
    );
  }
}

class _DiagnosticResultSummary extends StatelessWidget {
  const _DiagnosticResultSummary({required this.result});

  final TaskResultWorkspace result;

  @override
  Widget build(BuildContext context) {
    final formats = result.outputPaths.keys.join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('结果摘要', style: T.tSection),
        const SizedBox(height: T.s8),
        ReadonlyRow(label: '片段', value: '${result.segments.length}'),
        const SizedBox(height: T.s8),
        ReadonlyRow(label: '问题', value: '${result.issueCount}'),
        const SizedBox(height: T.s8),
        ReadonlyRow(label: '输出', value: formats.isEmpty ? '无记录' : formats),
      ],
    );
  }
}

class _MiniTextButton extends StatelessWidget {
  const _MiniTextButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: T.tCaption.copyWith(
            color: enabled ? T.accentStrong : T.muted,
            fontWeight: enabled ? T.wBold : T.wMedium,
          ),
        ),
      ),
    );
  }
}

class _DiagnosticMetricStrip extends StatelessWidget {
  const _DiagnosticMetricStrip({required this.checks});

  final List<Map<String, Object?>> checks;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: T.s8,
      runSpacing: T.s8,
      children: [
        _DiagnosticCount(
          status: 'PASS',
          count: _diagnosticCount(checks, 'PASS'),
        ),
        _DiagnosticCount(
          status: 'WARN',
          count: _diagnosticCount(checks, 'WARN'),
        ),
        _DiagnosticCount(
          status: 'FAIL',
          count: _diagnosticCount(checks, 'FAIL'),
        ),
      ],
    );
  }
}

class _DiagnosticCount extends StatelessWidget {
  const _DiagnosticCount({required this.status, required this.count});

  final String status;
  final int count;

  @override
  Widget build(BuildContext context) {
    final color = _diagnosticStatusColor(status);
    return Container(
      constraints: const BoxConstraints(minWidth: 82),
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        '${_diagnosticStatusLabel(status)} $count',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: T.tBody.copyWith(color: color, fontWeight: T.wMedium),
      ),
    );
  }
}

class _DiagnosticBadge extends StatelessWidget {
  const _DiagnosticBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = _diagnosticStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 5),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        _diagnosticStatusLabel(status),
        style: T.tCaption.copyWith(color: color, fontWeight: T.wMedium),
      ),
    );
  }
}

class _DiagnosticCode extends StatelessWidget {
  const _DiagnosticCode({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 5),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line, width: 1),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: T.tCaption.copyWith(color: T.ink),
      ),
    );
  }
}

Map<String, Object?> _stringMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return const <String, Object?>{};
}

List<Object?> _objectList(Object? value) {
  if (value is List) return value;
  return const <Object?>[];
}

String? _stringValue(Object? value) {
  if (value == null) return null;
  final text = '$value';
  return text.isEmpty ? null : text;
}

String _friendlySettingsError(Object error) => friendlySettingsError(error);

String _friendlyAsrModelProbeError(String code, String message) {
  return switch (code) {
    'runtime_missing' => '请先安装 Whisper 运行组件。',
    'runtime_unpublished' => '当前版本的 Whisper 运行组件尚未发布。',
    'model_path_unavailable' => '模型目录不存在或当前无法访问。',
    'model_changed' => '验证期间模型文件发生了变化，请等待文件写入完成后重试。',
    'unsupported_model_directory' =>
      '无法识别这个模型目录；请选择兼容的 Whisper Small、Medium 或 Large v3 模型。',
    'file_not_found' => '模型文件不完整，请重新选择完整的 faster-whisper 模型目录。',
    'environment_probe_failed' ||
    'environment_probe_invalid_json' ||
    'environment_probe_invalid_payload' => 'Whisper 运行组件未能完成模型验证，请重试。',
    'runtime_error' => '当前 Whisper 运行组件无法加载这个模型。',
    'unsupported_device' => '请选择自动、CPU 或 NVIDIA 运算方式。',
    'unsupported_compute_type' => '当前运算方式与这个运行环境不兼容。',
    _ => message.isEmpty ? '模型验证失败，请检查目录内容。' : message,
  };
}
