import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../model/startup_args.dart';
import '../model/task_labels.dart';
import '../model/window_state.dart';
import '../services/app_service_client.dart';
import '../services/directory_probe.dart';
import '../services/local_service_controller.dart';
import '../services/path_opener.dart';
import '../services/smoke_render_capture.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';
import 'title_bar.dart';

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

  DesktopSnapshot? _snapshot;
  List<TaskSummary>? _diagnosticTasks;
  TaskResultWorkspace? _diagnosticResult;
  final Map<String, DirectoryProbeResult> _diagnosticOutputDirectoryResults =
      {};
  final Set<String> _checkingDiagnosticOutputDirectoryTaskIds = {};
  String? _selectedDiagnosticTaskId;
  String? _selectedProvider;
  String? _selectedModel;
  final Map<String, List<String>> _fetchedProviderModels = {};
  String _selectedAsrProvider = 'faster_whisper_large_v3';
  String? _selectedDiagnosticCheck;
  String? _message;
  String? _error;
  bool _loading = false;
  bool _savingProvider = false;
  bool _savingDefault = false;
  bool _loadingModels = false;
  bool _testingProvider = false;
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
    _loadConfig();
  }

  @override
  void dispose() {
    _smokeService?.dispose();
    _ownedFallbackService?.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _key.dispose();
    _endpoint.dispose();
    _device.dispose();
    super.dispose();
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
      final previousProvider = _selectedProvider;
      final previousModel = _selectedModel ?? _model.text.trim();
      final snapshot = await _client.desktopSnapshot();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        if (widget.type == AppWindowType.diagnostics) {
          _diagnosticTasks = null;
          _diagnosticResult = null;
          _selectedDiagnosticTaskId = null;
        }
        if (_isTranslation) {
          final routedProvider = snapshot.translationProvider;
          final routedProviderExists =
              routedProvider != null &&
              snapshot.providers.any(
                (provider) => provider.name == routedProvider,
              );
          final previousProviderExists =
              previousProvider != null &&
              snapshot.providers.any(
                (provider) => provider.name == previousProvider,
              );
          _selectedProvider = previousProviderExists
              ? previousProvider
              : (routedProviderExists
                    ? routedProvider
                    : (snapshot.providers.isNotEmpty
                          ? snapshot.providers.first.name
                          : null));
          final selectedProvider = _providerByName(snapshot, _selectedProvider);
          final visibleModels = _visibleModels(selectedProvider);
          _selectedModel =
              previousProviderExists &&
                  previousProvider == _selectedProvider &&
                  previousModel.isNotEmpty
              ? previousModel
              : (_selectedProvider == routedProvider && routedProviderExists
                    ? snapshot.translationModel
                    : (visibleModels.isNotEmpty ? visibleModels.first : null));
          _loadProviderDraftFields();
        } else if (_isAsr) {
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
    final provider = _selectedProvider;
    final selectedProviderOption = snapshot == null || provider == null
        ? null
        : _providerByName(snapshot, provider);
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
      'selected_model': _selectedModel ?? _model.text.trim(),
      'selected_provider_model_count':
          selectedProviderOption?.models.length ?? 0,
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
    final snapshot = _snapshot;
    final providers = snapshot?.providers ?? const <ProviderOption>[];
    final selected = _selectedProvider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DefaultBar(
          text: _translationDefaultText(snapshot),
          busy: _loading || _savingDefault,
          error: _error,
          message: _message,
        ),
        const SizedBox(height: T.s16),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 210,
                child: _ProviderList(
                  providers: providers,
                  selected: selected,
                  defaultProvider: snapshot?.translationProvider,
                  onPick: _pickProvider,
                ),
              ),
              const SizedBox(width: T.s32),
              Expanded(child: _translationDetails()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _translationDetails() {
    final provider = _selectedProvider == null || _snapshot == null
        ? const ProviderOption(name: '', models: [])
        : _providerByName(_snapshot!, _selectedProvider);
    final visibleModels = _visibleModels(provider);
    final model = _translationModelSelection(provider);
    return _ToolPanel(
      footer: [
        _ActionButton(
          label: _loadingModels ? '拉取中' : '拉取模型列表',
          onTap: _loadingModels ? null : _fetchModels,
        ),
        _ActionButton(
          label: _testingProvider ? '测试中' : '测试连接',
          onTap: _testingProvider ? null : _testProvider,
        ),
        _ActionButton(
          label: _savingProvider ? '保存中' : '保存供应商',
          onTap: _savingProvider ? null : _saveProvider,
        ),
        _ActionButton(
          label: _savingDefault ? '保存中' : '设为翻译默认',
          strong: true,
          onTap: _savingDefault ? null : _saveTranslationDefault,
        ),
        _ActionButton(
          label: _loading ? '刷新中' : '刷新配置',
          onTap: _loading ? null : _loadConfig,
        ),
      ],
      footnote: '供应商配置保存服务地址、协议和模型清单；密钥只写入用户级凭据。',
      children: [
        Text(
          provider.name.isEmpty ? '选择一个模型供应商' : provider.name,
          style: T.tSection,
        ),
        const SizedBox(height: T.s12),
        Wrap(
          spacing: T.s8,
          runSpacing: T.s8,
          children: [
            _MetaPill(label: '默认', value: _translationRouteLabel(_snapshot)),
            _MetaPill(label: '配置组', value: _routingProfileLabel(_snapshot)),
            _MetaPill(label: '凭据', value: _credentialStatusLabel(provider)),
            _MetaPill(label: '编辑', value: _providersFileLabel(_snapshot)),
          ],
        ),
        const SizedBox(height: T.s16),
        _SettingsSection(
          title: '连接信息',
          children: [
            _ReadonlyRow(
              label: '协议适配',
              value: _providerProtocolLabel(provider),
            ),
            const SizedBox(height: T.s12),
            _Input(label: '服务地址 (Base URL)', controller: _baseUrl),
          ],
        ),
        _SettingsSection(
          title: '可用模型',
          children: [
            Wrap(
              spacing: T.s8,
              runSpacing: T.s8,
              children: [
                for (final item in visibleModels)
                  _ChoicePill(
                    label: item,
                    selected: item == model,
                    onTap: () {
                      setState(() {
                        _selectedModel = item;
                        _model.clear();
                      });
                    },
                  ),
                _InlineTextField(
                  controller: _model,
                  hint: visibleModels.isEmpty ? '填写模型名' : '自定义模型名',
                ),
              ],
            ),
            const SizedBox(height: T.s12),
            Text(
              _modelListHelp(provider),
              style: T.tCaption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        _SettingsSection(
          title: '凭据',
          children: [
            _ReadonlyRow(label: '状态', value: _credentialStatusLabel(provider)),
            const SizedBox(height: T.s8),
            _ReadonlyRow(
              label: '凭据 ID',
              value: provider.credentialId.isEmpty
                  ? provider.name
                  : provider.credentialId,
            ),
            const SizedBox(height: T.s8),
            _ReadonlyRow(
              label: '环境变量',
              value: provider.envKey.isEmpty ? '未配置' : provider.envKey,
            ),
            const SizedBox(height: T.s12),
            _Input(
              label: 'API key（留空则沿用已保存凭据）',
              controller: _key,
              obscure: true,
            ),
          ],
        ),
      ],
    );
  }

  Widget _asrBody() {
    final snapshot = _snapshot;
    final selected = _selectedAsrProvider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DefaultBar(
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
    return _ToolPanel(
      footer: [
        _ActionButton(
          label: _savingAsr ? '保存中' : '保存识别默认',
          strong: true,
          onTap: _savingAsr ? null : _saveAsrProvider,
        ),
        _ActionButton(
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
                child: _Input(label: '模型规格', controller: _model),
              ),
              const SizedBox(width: T.s12),
              Expanded(
                child: _Input(label: '运算设备', controller: _device),
              ),
            ],
          ),
          const SizedBox(height: T.s12),
          const Text('保存后可在诊断入口确认本机语音识别依赖和当前配置。', style: T.tCaption),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: _Input(
                  label: kind == 'local_server' ? '本地服务地址' : '服务地址 (Base URL)',
                  controller: _baseUrl,
                ),
              ),
              const SizedBox(width: T.s12),
              Expanded(
                child: _Input(label: '模型', controller: _model),
              ),
            ],
          ),
          const SizedBox(height: T.s12),
          Row(
            children: [
              Expanded(
                child: _Input(label: '接口路径 (Endpoint)', controller: _endpoint),
              ),
              const SizedBox(width: T.s12),
              Expanded(
                child: kind == 'remote'
                    ? _Input(
                        label: '密钥 (API key，留空则沿用)',
                        controller: _key,
                        obscure: true,
                      )
                    : const _ReadonlyRow(label: '密钥', value: '本地服务不需要密钥'),
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
        _DefaultBar(
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

  void _pickProvider(String providerName) {
    setState(() {
      _selectedProvider = providerName;
      final provider = _snapshot == null
          ? const ProviderOption(name: '', models: [])
          : _providerByName(_snapshot!, providerName);
      final models = _visibleModels(provider);
      _selectedModel = models.isEmpty ? null : models.first;
      _loadProviderDraftFields();
      _message = null;
      _error = null;
    });
  }

  void _loadProviderDraftFields() {
    final snapshot = _snapshot;
    final provider = snapshot == null
        ? const ProviderOption(name: '', models: [])
        : _providerByName(snapshot, _selectedProvider);
    final model =
        _selectedProvider != null &&
            _selectedProvider == snapshot?.translationProvider
        ? _selectedModel ?? snapshot?.translationModel
        : _selectedModel;
    _baseUrl.text = provider.baseUrl;
    final models = _visibleModels(provider);
    final selectedModel = model ?? (models.isNotEmpty ? models.first : '');
    if (selectedModel.isNotEmpty && models.contains(selectedModel)) {
      _selectedModel = selectedModel;
      _model.clear();
    } else {
      _model.text = selectedModel;
    }
    _key.clear();
  }

  String _translationDefaultText(DesktopSnapshot? snapshot) {
    final provider = snapshot?.translationProvider;
    final model = snapshot?.translationModel;
    if (provider == null || provider.isEmpty) return '还没选默认模型';
    final label = model == null || model.isEmpty
        ? provider
        : '$provider · $model';
    if (snapshot?.configReadiness.translationConfigured == true) {
      return '翻译默认：$label';
    }
    final providerExists =
        snapshot?.providers.any((item) => item.name == provider) ?? false;
    return providerExists ? '翻译默认需配置：$label' : '还没选默认模型';
  }

  Future<void> _saveProvider() async {
    final provider = _selectedProvider;
    final providerOption = _snapshot == null || provider == null
        ? const ProviderOption(name: '', models: [])
        : _providerByName(_snapshot!, provider);
    final model = _translationModelSelection(providerOption);
    if (provider == null || provider.isEmpty) {
      setState(() => _error = '需要先选择翻译服务');
      return;
    }
    if (model.isEmpty) {
      setState(() => _error = '模型名不能为空');
      return;
    }
    setState(() {
      _savingProvider = true;
      _error = null;
      _message = null;
    });
    try {
      await _client.providerSave(
        providerDraft: _translationDraft(
          providerName: provider,
          models: _mergedModelsForProvider(providerOption, model),
        ),
        apiKey: _keyTextOrNull(),
        expectedVersion: _snapshot?.providersFileVersion,
      );
      _selectedModel = model;
      await _loadConfig();
      if (!mounted) return;
      setState(() {
        _selectedModel = model;
        _fetchedProviderModels.remove(provider);
        if (_visibleModels(providerOption).contains(model)) _model.clear();
        _message = '供应商已保存；默认翻译没有自动切换。';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _savingProvider = false);
    }
  }

  Future<void> _saveTranslationDefault() async {
    final provider = _selectedProvider;
    final providerOption = _snapshot == null || provider == null
        ? const ProviderOption(name: '', models: [])
        : _providerByName(_snapshot!, provider);
    final model = _translationModelSelection(providerOption);
    if (provider == null || provider.isEmpty || model.isEmpty) {
      setState(() => _error = '需要先选择翻译服务和模型');
      return;
    }
    setState(() {
      _savingDefault = true;
      _error = null;
      _message = null;
    });
    try {
      Map<String, Object?>? expectedVersion;
      var savedProviderBeforeRouting = false;
      if (_providerModelsNeedSave(providerOption, model)) {
        final saveResult = await _client.providerSave(
          providerDraft: _translationDraft(
            providerName: provider,
            models: _mergedModelsForProvider(providerOption, model),
          ),
          apiKey: _keyTextOrNull(),
          expectedVersion: _snapshot?.providersFileVersion,
        );
        expectedVersion = _stringMap(saveResult['providers_file_version']);
        savedProviderBeforeRouting = true;
      }
      await _saveRouting(provider, model, expectedVersion: expectedVersion);
      await _loadConfig();
      if (!mounted) return;
      setState(() {
        _selectedModel = model;
        if (savedProviderBeforeRouting) _fetchedProviderModels.remove(provider);
        if (_visibleModels(providerOption).contains(model)) _model.clear();
        _message = '默认翻译已切换到 $provider · $model。';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _savingDefault = false);
    }
  }

  Future<void> _saveRouting(
    String provider,
    String model, {
    Map<String, Object?>? expectedVersion,
  }) async {
    final snapshot = _snapshot ?? await _client.desktopSnapshot();
    await _client.saveTranslationRouting(
      provider: provider,
      model: model,
      fallback: snapshot.translationFallback,
      expectedVersion: expectedVersion ?? snapshot.providersFileVersion,
    );
    await widget.bridge.setTranslationDefault(
      '$provider · $model',
      configured: true,
    );
  }

  Future<void> _fetchModels() async {
    final provider = _selectedProvider;
    if (provider == null || provider.isEmpty) {
      setState(() => _error = '需要先选择翻译服务');
      return;
    }
    setState(() {
      _loadingModels = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await _client.providerModels(
        providerDraft: _translationDraft(providerName: provider),
        apiKey: _keyTextOrNull(),
      );
      final models = _normalizedModels(_stringList(result['models']));
      if (!mounted) return;
      setState(() {
        if (models.isNotEmpty) {
          _fetchedProviderModels[provider] = models;
          _selectedModel = models.first;
          _model.clear();
          final hint = _stringValue(result['hint_zh']);
          _message = hint == null || hint.isEmpty
              ? '已拉取到 ${models.length} 个模型，已显示在可用模型里。'
              : '$hint 已显示在可用模型里。';
        } else {
          _message = _stringValue(result['hint_zh']) ?? '没有解析到模型，可以手动填写模型名。';
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _testProvider() async {
    final provider = _selectedProvider;
    final providerOption = _snapshot == null || provider == null
        ? const ProviderOption(name: '', models: [])
        : _providerByName(_snapshot!, provider);
    final model = _translationModelSelection(providerOption);
    if (provider == null || provider.isEmpty || model.isEmpty) {
      setState(() => _error = '需要先选择翻译服务和模型');
      return;
    }
    setState(() {
      _testingProvider = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await _client.providerTest(
        providerDraft: _translationDraft(
          providerName: provider,
          models: _mergedModelsForProvider(providerOption, model),
        ),
        model: model,
        apiKey: _keyTextOrNull(),
      );
      final status = _stringValue(result['status']) ?? 'UNKNOWN';
      final checks = _objectList(result['checks']);
      final first = checks.isEmpty
          ? const <String, Object?>{}
          : _stringMap(checks.first);
      if (!mounted) return;
      setState(() {
        _message =
            '$status：${_stringValue(first['hint_zh']) ?? _stringValue(first['message']) ?? '连接测试完成'}';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _testingProvider = false);
    }
  }

  ProviderOption _providerByName(DesktopSnapshot snapshot, String? name) {
    return snapshot.providers.firstWhere(
      (provider) => provider.name == name,
      orElse: () => const ProviderOption(name: '', models: []),
    );
  }

  Map<String, Object?> _translationDraft({
    required String providerName,
    List<String>? models,
  }) {
    final provider = _snapshot == null
        ? const ProviderOption(name: '', models: [])
        : _providerByName(_snapshot!, providerName);
    return {
      ...provider.raw,
      'name': providerName,
      'base_url': _baseUrl.text.trim().isNotEmpty
          ? _baseUrl.text.trim()
          : provider.baseUrl,
      'models':
          models ??
          _mergedModelsForProvider(
            provider,
            _translationModelSelection(provider),
          ),
      'compat_mode': provider.compatMode.isNotEmpty
          ? provider.compatMode
          : 'openai_chat',
      'api_type': provider.apiType.isNotEmpty
          ? provider.apiType
          : 'openai-compatible',
      'credential_id': provider.credentialId.isNotEmpty
          ? provider.credentialId
          : providerName,
    };
  }

  String _translationModelSelection(ProviderOption provider) {
    final customModel = _model.text.trim();
    if (customModel.isNotEmpty) return customModel;
    return _selectedModel ??
        (_visibleModels(provider).isNotEmpty
            ? _visibleModels(provider).first
            : '');
  }

  List<String> _mergedModelsForProvider(ProviderOption provider, String model) {
    final seen = <String>{};
    final merged = <String>[];
    for (final item in [
      if (model.isNotEmpty) model,
      ...?_fetchedProviderModels[provider.name],
      ...provider.models,
    ]) {
      final trimmed = item.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed)) merged.add(trimmed);
    }
    return merged;
  }

  List<String> _visibleModels(ProviderOption provider) {
    return _normalizedModels([
      ...?_fetchedProviderModels[provider.name],
      ...provider.models,
    ]);
  }

  List<String> _normalizedModels(List<String> models) {
    final seen = <String>{};
    final normalized = <String>[];
    for (final item in models) {
      final trimmed = item.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed)) normalized.add(trimmed);
    }
    return normalized;
  }

  bool _providerModelsNeedSave(ProviderOption provider, String model) {
    final saved = provider.models.toSet();
    if (model.trim().isNotEmpty && !saved.contains(model.trim())) return true;
    final fetched = _fetchedProviderModels[provider.name] ?? const <String>[];
    return fetched.any((item) => !saved.contains(item));
  }

  String _modelListHelp(ProviderOption provider) {
    if (provider.name.isEmpty) return '选择供应商后可以查看或手动填写模型。';
    final fetched = _fetchedProviderModels[provider.name] ?? const <String>[];
    if (fetched.isNotEmpty) {
      return '拉取结果还未保存；点击“保存供应商”后会写入模型清单。';
    }
    if (provider.models.isEmpty) return '这个供应商还没有保存模型，可以手动填写模型名。';
    return '模型清单来自当前供应商配置；拉取后可先预览，再保存进供应商配置。';
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

String _providerProtocolLabel(ProviderOption provider) {
  final compat = provider.compatMode.trim().toLowerCase();
  return switch (compat) {
    'openai_chat' => 'OpenAI Chat 兼容',
    'openai_responses' => 'OpenAI Responses',
    'openai_completions' => 'OpenAI Completions',
    'anthropic_messages' => 'Anthropic Messages',
    'gemini_generate_content' => 'Gemini GenerateContent',
    'vertex_express' => 'Google Vertex Express',
    'custom_json' => '自定义 JSON 协议',
    _ => _translationProtocolLabel(provider.apiType),
  };
}

String _credentialSourceLabel(String source) {
  return switch (source.trim().toLowerCase()) {
    'auth_json' => '用户级凭据',
    'env' => '环境变量',
    'dotenv' => '开发 .env',
    'explicit' => '当前输入',
    'not_required' => '不需要密钥',
    'missing' => '未找到',
    '' => '未知',
    _ => source,
  };
}

String _credentialStatusLabel(ProviderOption provider) {
  if (provider.name.isEmpty) return '未选择供应商';
  final source = _credentialSourceLabel(provider.credentialSource);
  return provider.hasKey ? '已配置 · $source' : '缺密钥 · $source';
}

String _translationRouteLabel(DesktopSnapshot? snapshot) {
  final provider = snapshot?.translationProvider;
  final model = snapshot?.translationModel;
  if (provider == null || provider.isEmpty) return '还没选默认模型';
  if (model == null || model.isEmpty) return provider;
  return '$provider · $model';
}

String _routingProfileLabel(DesktopSnapshot? snapshot) {
  final routing = _stringMap(snapshot?.config['routing']);
  final active = _stringValue(routing['active_profile']);
  final fallbackCount = _objectList(routing['fallback']).length;
  final profile = active == null || active.isEmpty ? 'default' : active;
  return fallbackCount == 0
      ? '$profile · 无备用'
      : '$profile · $fallbackCount 个备用';
}

String _providersFileLabel(DesktopSnapshot? snapshot) {
  final raw = _stringValue(snapshot?.config['providers_file']);
  if (raw == null || raw.isEmpty) return '未知';
  final normalized = raw.replaceAll('\\', '/');
  final marker = '/.transvortex-desktop/';
  final markerIndex = normalized.indexOf(marker);
  if (markerIndex >= 0) {
    final tail = normalized.substring(markerIndex + 1).replaceAll('/', '\\');
    return '${_providersFileKindLabel(tail)} · $tail';
  }
  final parts = normalized.split('/');
  final fileName = parts.isEmpty ? raw : parts.last;
  return '${_providersFileKindLabel(fileName)} · $fileName';
}

String _providersFileKindLabel(String path) {
  final normalized = path.replaceAll('\\', '/').toLowerCase();
  if (normalized.endsWith('/providers.local.yaml') ||
      normalized == 'providers.local.yaml') {
    return '本机配置';
  }
  if (normalized.endsWith('/providers.example.yaml') ||
      normalized == 'providers.example.yaml') {
    return '示例配置';
  }
  if (normalized.endsWith('/providers.yaml') ||
      normalized == 'providers.yaml') {
    return normalized.contains('/.transvortex-desktop/') ? '默认副本' : '默认配置';
  }
  return '配置文件';
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

class _DefaultBar extends StatelessWidget {
  const _DefaultBar({
    required this.text,
    required this.busy,
    this.error,
    this.message,
  });

  final String text;
  final bool busy;
  final String? error;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: T.line, width: 1)),
      ),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Expanded(child: Text(text, style: T.tSection)),
          if (busy) Text('同步中…', style: T.tCaption),
          if (!busy && error != null)
            Flexible(
              child: Text(
                error!,
                style: T.tCaption.copyWith(color: T.danger),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (!busy && error == null && message != null)
            Flexible(
              child: Text(
                message!,
                style: T.tCaption.copyWith(color: T.accentStrong),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 5),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line, width: 1),
      ),
      child: RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: T.tCaption,
          children: [
            TextSpan(
              text: '$label ',
              style: const TextStyle(color: T.muted),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                color: T.ink,
                fontWeight: T.wMedium,
                fontFamily: T.fontFamily,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: T.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: T.tCaption.copyWith(fontWeight: T.wBold)),
          const SizedBox(height: T.s8),
          ...children,
          const SizedBox(height: T.s12),
          const Divider(height: 1, color: T.line),
        ],
      ),
    );
  }
}

class _ProviderList extends StatelessWidget {
  const _ProviderList({
    required this.providers,
    required this.selected,
    required this.defaultProvider,
    required this.onPick,
  });

  final List<ProviderOption> providers;
  final String? selected;
  final String? defaultProvider;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('模型供应商', style: T.tSection),
        const SizedBox(height: T.s12),
        if (providers.isEmpty)
          const Text('还没有模型供应商', style: T.tCaption)
        else
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final provider in providers)
                  _ChoiceRow(
                    label: provider.name,
                    detail: [
                      if (provider.name == defaultProvider) '默认',
                      _providerProtocolLabel(provider),
                      provider.hasKey ? '密钥已配置' : '未配置密钥',
                    ].join(' · '),
                    selected: provider.name == selected,
                    warn: provider.name == defaultProvider && !provider.hasKey,
                    onTap: () => onPick(provider.name),
                  ),
              ],
            ),
          ),
      ],
    );
  }
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
          _SegmentButton(
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
                  _ChoiceRow(
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
    return _ToolPanel(
      footer: [
        if (repairTarget != null)
          _ActionButton(
            label: _diagnosticRepairLabel(repairTarget),
            onTap: () => onOpenTool(
              repairTarget,
              taskId: repairTarget == AppWindowType.taskProcessing
                  ? _diagnosticRepairTaskId(check!, snapshot)
                  : null,
            ),
          ),
        if (pathAction != null)
          _ActionButton(
            label: pathAction.label,
            onTap: () => onOpenPath(pathAction),
          ),
        _ActionButton(
          label: onRefresh == null ? '刷新中' : '刷新诊断',
          strong: true,
          onTap: onRefresh,
        ),
      ],
      footnote: '诊断读取本机配置、依赖和翻译服务协议预检；不会上传音视频或密钥。',
      children: [
        _DiagnosticMetricStrip(checks: checks),
        const SizedBox(height: T.s16),
        _ReadonlyRow(label: '项目根目录', value: rootDir),
        const SizedBox(height: T.s12),
        _ReadonlyRow(label: '翻译配置文件', value: providersFile),
        const SizedBox(height: T.s12),
        _ReadonlyRow(label: '产物目录', value: artifactsDir),
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
          _ReadonlyRow(label: '当前任务', value: activeTaskLabel),
          const SizedBox(height: T.s8),
          _ReadonlyRow(label: '任务数', value: '$taskCount'),
          const SizedBox(height: T.s8),
          _ReadonlyRow(label: '队列', value: '${queued.length} 个等待'),
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
          _ReadonlyRow(label: '中断任务', value: '${interrupted.length} 个'),
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
          _ReadonlyRow(label: '最新任务', value: latestLabel),
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
        _ReadonlyRow(label: '片段', value: '${result.segments.length}'),
        const SizedBox(height: T.s8),
        _ReadonlyRow(label: '问题', value: '${result.issueCount}'),
        const SizedBox(height: T.s8),
        _ReadonlyRow(label: '输出', value: formats.isEmpty ? '无记录' : formats),
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

class _ToolPanel extends StatelessWidget {
  const _ToolPanel({
    required this.children,
    required this.footer,
    required this.footnote,
  });
  final List<Widget> children;
  final List<Widget> footer;
  final String footnote;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ListView(padding: EdgeInsets.zero, children: children),
        ),
        const SizedBox(height: T.s12),
        Wrap(spacing: T.s12, runSpacing: T.s8, children: footer),
        const SizedBox(height: T.s8),
        Text(
          footnote,
          style: T.tCaption,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _Input extends StatelessWidget {
  const _Input({
    required this.label,
    required this.controller,
    this.obscure = false,
  });
  final String label;
  final TextEditingController controller;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: T.tCaption),
        const SizedBox(height: T.s4),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: T.tBody,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: T.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(T.rMd),
              borderSide: const BorderSide(color: T.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(T.rMd),
              borderSide: const BorderSide(color: T.accent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _InlineTextField extends StatelessWidget {
  const _InlineTextField({required this.controller, required this.hint});
  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      height: 32,
      child: TextField(
        controller: controller,
        style: T.tCaption.copyWith(color: T.ink),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: T.tCaption,
          isDense: true,
          filled: true,
          fillColor: T.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: T.s8,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rSm),
            borderSide: const BorderSide(color: T.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rSm),
            borderSide: const BorderSide(color: T.accent, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _ReadonlyRow extends StatelessWidget {
  const _ReadonlyRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 96, child: Text(label, style: T.tCaption)),
        Expanded(
          child: Text(value, style: T.tBody, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

class _ActionButton extends StatefulWidget {
  const _ActionButton({
    required this.label,
    required this.onTap,
    this.strong = false,
  });
  final String label;
  final VoidCallback? onTap;
  final bool strong;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final bg = widget.strong
        ? (enabled ? (_hover ? T.accentStrong : T.accent) : T.line)
        : (_hover && enabled ? T.accentSoft : T.surface);
    final fg = widget.strong
        ? const Color(0xFFFFFFFF)
        : (enabled ? T.accentStrong : T.muted);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(
              color: widget.strong ? bg : (enabled ? T.accent : T.line),
              width: 1.2,
            ),
          ),
          child: Text(
            widget.label,
            style: T.tBody.copyWith(color: fg, fontWeight: T.wMedium),
          ),
        ),
      ),
    );
  }
}

class _ChoicePill extends StatefulWidget {
  const _ChoicePill({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ChoicePill> createState() => _ChoicePillState();
}

class _ChoicePillState extends State<_ChoicePill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 180),
          padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 6),
          decoration: BoxDecoration(
            color: widget.selected || _hover ? T.accentSoft : T.surface,
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(
              color: widget.selected ? T.accent : T.line,
              width: 1,
            ),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.tCaption.copyWith(
              color: widget.selected ? T.accentStrong : T.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChoiceRow extends StatefulWidget {
  const _ChoiceRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.detail,
    this.warn = false,
  });

  final String label;
  final String? detail;
  final bool selected;
  final bool warn;
  final VoidCallback onTap;

  @override
  State<_ChoiceRow> createState() => _ChoiceRowState();
}

class _ChoiceRowState extends State<_ChoiceRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.warn ? T.warn : T.accentStrong;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: widget.selected ? color : const Color(0x00000000),
                width: 3,
              ),
              bottom: const BorderSide(color: T.line, width: 1),
            ),
            color: _hover || widget.selected ? T.accentSoft : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: T.s12),
          alignment: Alignment.centerLeft,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.warn ? '${widget.label} ●' : widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.tBody.copyWith(
                  color: widget.warn ? T.warn : T.ink,
                  fontWeight: widget.selected ? T.wBold : T.wRegular,
                ),
              ),
              if (widget.detail != null && widget.detail!.isNotEmpty)
                Text(
                  widget.detail!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SegmentButton extends StatefulWidget {
  const _SegmentButton({
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SegmentButton> createState() => _SegmentButtonState();
}

class _SegmentButtonState extends State<_SegmentButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 150,
          padding: const EdgeInsets.symmetric(
            horizontal: T.s12,
            vertical: T.s8,
          ),
          decoration: BoxDecoration(
            color: widget.selected || _hover ? T.accentSoft : T.surface,
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(
              color: widget.selected ? T.accent : T.line,
              width: 1.2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.label,
                style: T.tBody.copyWith(
                  fontWeight: widget.selected ? T.wBold : T.wRegular,
                ),
              ),
              const SizedBox(height: 2),
              Text(widget.detail, style: T.tCaption),
            ],
          ),
        ),
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

List<String> _stringList(Object? value) {
  return _objectList(value).map((item) => '$item').toList();
}

String? _stringValue(Object? value) {
  if (value == null) return null;
  final text = '$value';
  return text.isEmpty ? null : text;
}

String _friendlySettingsError(Object error) {
  if (error is PlatformException) {
    final rawMessage = error.message ?? '';
    if (rawMessage.contains('Local Service caller')) {
      return '本地服务未连接，请稍后刷新。';
    }
    if (error.code == 'service_unavailable') {
      final message = rawMessage.trim();
      return message.isEmpty ? '本地服务暂时不可用，请稍后重试。' : message;
    }
    final message = rawMessage.trim();
    if (message.isNotEmpty) return message;
  }
  if (error is RpcRemoteException) {
    final details = _stringMap(error.details);
    final info = _stringMap(details['error_info']);
    final hint =
        _stringValue(info['hint_zh']) ??
        _stringValue(info['hint']) ??
        _stringValue(details['hint_zh']) ??
        _stringValue(details['hint']);
    if (hint != null && hint.isNotEmpty) return hint;
    final message = error.message.trim();
    if (message.isNotEmpty) return message;
  }
  final text = '$error';
  if (text.contains('CHANNEL_UNREGISTERED') ||
      text.contains('WindowChannelException')) {
    return '本地服务未连接，请稍后刷新。';
  }
  return text;
}
