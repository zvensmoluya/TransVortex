import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    super.dispose();
  }

  Future<void> _initTranslation(TranslationSettingsController controller) async {
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
        } else if (widget.type == AppWindowType.diagnostics) {
          _selectedDiagnosticCheck = _defaultDiagnosticSelection(snapshot);
        }
      });
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
        ? (translation?.selectedConnection ??
              translation?.primary?.connection)
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
    final snapshot = _snapshot;
    final selected = _selectedAsrProvider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DefaultBar(
          text: '当前识别：${_asrHeaderLabel(selected)}',
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
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 210,
                child: _AsrSummaryList(
                  providers: snapshot?.asrProviders ?? const [],
                  selected: selected,
                  onPick: _pickAsrProvider,
                ),
              ),
              const SizedBox(width: T.s32),
              Expanded(child: _asrDetails()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _asrDetails() {
    final draft = _asrDraft(_selectedAsrProvider);
    final kind = '${draft['kind']}';
    return ToolPanel(
      footer: [
        ActionButton(
          label: _savingAsr ? '保存中' : '保存识别默认',
          strong: true,
          onTap: _savingAsr ? null : _saveAsrProvider,
        ),
        ActionButton(
          label: _loading ? '刷新中' : '刷新配置',
          onTap: _loading ? null : _loadConfig,
        ),
      ],
      footnote: '本机和 FunASR 不需要密钥；云端密钥只写入用户级凭据。',
      children: [
        Text(_asrLabelForDraft(draft), style: T.tSection),
        const SizedBox(height: T.s12),
        if (kind == 'local_inprocess') ...[
          Row(
            children: [
              Expanded(
                child: Input(label: '模型规格', controller: _model),
              ),
              const SizedBox(width: T.s12),
              Expanded(
                child: Input(label: '运算设备', controller: _device),
              ),
            ],
          ),
          const SizedBox(height: T.s12),
          const Text('保存后可在诊断入口确认本机语音识别依赖和当前配置。', style: T.tCaption),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: Input(
                  label: kind == 'local_server' ? '本地服务地址' : '服务地址 (Base URL)',
                  controller: _baseUrl,
                ),
              ),
              const SizedBox(width: T.s12),
              Expanded(
                child: Input(label: '模型', controller: _model),
              ),
            ],
          ),
          const SizedBox(height: T.s12),
          Row(
            children: [
              Expanded(
                child: Input(label: '接口路径 (Endpoint)', controller: _endpoint),
              ),
              const SizedBox(width: T.s12),
              Expanded(
                child: kind == 'remote'
                    ? Input(
                        label: '密钥 (API key，留空则沿用)',
                        controller: _key,
                        obscure: true,
                      )
                    : const ReadonlyRow(label: '密钥', value: '本地服务不需要密钥'),
              ),
            ],
          ),
        ],
      ],
    );
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
    _key.clear();
  }

  Future<void> _saveAsrProvider() async {
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
      await widget.bridge.setAsrDefault(
        _asrLabelForDraft(draft),
        configured: true,
      );
      await _loadConfig();
      if (!mounted) return;
      setState(() => _message = '识别默认已保存：${_asrLabelForDraft(draft)}。');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _savingAsr = false);
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
    final kind = hasExisting
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
    local['device'] = _device.text.trim().isEmpty
        ? 'auto'
        : _device.text.trim();
    return {
      if (hasExisting) ...existing.raw,
      'name': providerName,
      'kind': kind,
      'protocol': protocol,
      'model': model,
      if (kind != 'local_inprocess') 'base_url': baseUrl,
      if (kind != 'local_inprocess') 'endpoint': endpoint,
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
      if (kind == 'local_inprocess') 'local': local,
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
    if (provider.kind == 'local_inprocess') return 'faster_whisper_large_v3';
    if (provider.kind == 'local_server' ||
        provider.protocol == 'funasr_openai') {
      return 'funasr_sensevoice_local';
    }
    return 'openai_whisper';
  }

  String _defaultAsrKind(String providerName) {
    final preset = _asrPresetIdForName(providerName);
    if (preset == 'faster_whisper_large_v3') return 'local_inprocess';
    if (preset == 'funasr_sensevoice_local') return 'local_server';
    return 'remote';
  }

  String _defaultAsrProtocol(String kind, String providerName) {
    if (kind == 'local_inprocess') return 'faster_whisper';
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
    if (kind == 'local_inprocess') return 'large-v3';
    if (protocol == 'funasr_openai') return 'sensevoice';
    return 'whisper-1';
  }

  String _defaultAsrBaseUrl(String kind, String protocol) {
    if (kind == 'local_server' || protocol == 'funasr_openai') {
      return 'http://127.0.0.1:8899';
    }
    return 'https://api.openai.com';
  }

  String _asrLabelForDraft(Map<String, Object?> draft) {
    return switch (draft['kind']) {
      'local_inprocess' => '本机',
      'local_server' =>
        draft['protocol'] == 'funasr_openai' ? 'FunASR' : '本地服务',
      'remote' => '云端',
      _ => '${draft['name']}',
    };
  }

  String _asrHeaderLabel(String providerName) {
    final draft = _asrDraft(providerName, useEditedFields: false);
    return '${_asrLabelForDraft(draft)} · ${draft['model']}';
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
  for (final key in const ['srt', 'ass', 'vtt']) {
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
      ('faster_whisper_large_v3', '本机识别', 'faster-whisper'),
      ('funasr_sensevoice_local', 'FunASR', '本地服务'),
      ('openai_whisper', '云端识别', 'OpenAI Whisper'),
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

class _AsrSummaryList extends StatelessWidget {
  const _AsrSummaryList({
    required this.providers,
    required this.selected,
    required this.onPick,
  });

  final List<AsrProviderOption> providers;
  final String selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('已保存方案', style: T.tSection),
        const SizedBox(height: T.s12),
        if (providers.isEmpty)
          const Text('保存后会出现在这里', style: T.tCaption)
        else
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final provider in providers)
                  ChoiceRow(
                    label: provider.displayLabel,
                    detail:
                        '${provider.model}${provider.hasKey ? ' · 已配置' : ' · 缺密钥'}',
                    selected: provider.name == selected,
                    warn: !provider.hasKey,
                    onTap: () => onPick(provider.name),
                  ),
              ],
            ),
          ),
      ],
    );
  }
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
