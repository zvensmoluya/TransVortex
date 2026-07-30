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
import '../services/settings_service_transport.dart';
import '../services/smoke_render_capture.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';
import 'settings_common.dart';
import 'title_bar.dart';
import 'translation_settings_view.dart';

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
  final GlobalKey _renderKey = GlobalKey(debugLabel: 'settings-smoke-render');
  LocalServiceController? _smokeService;
  LocalServiceController? _ownedFallbackService;
  late final AppServiceClient _client;
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
  AsrOperationStatus? _activeAsrOperation;
  Timer? _asrOperationPoll;
  Timer? _asrOperationDismissTimer;
  bool _loadingDiagnosticTasks = false;
  bool _loadingDiagnosticResult = false;
  int _configLoadRevision = 0;
  int _visibleConfigLoads = 0;
  int _openRouterUsageRequestRevision = 0;

  bool get _isTranslation => widget.type == AppWindowType.translationSettings;
  bool get _isAsr => widget.type == AppWindowType.asrSettings;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _client = AppServiceClient(_settingsTransport());
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
    _asrOperationPoll?.cancel();
    _asrOperationDismissTimer?.cancel();
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
      AppWindowType.taskProcessing => '任务处理',
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

  Widget _asrBody() {
    final activeOperation = _activeAsrOperation;
    final selectedKind = '${_asrDraft(_selectedAsrProvider)['kind']}';
    final showBackgroundOperation =
        activeOperation?.active == true && selectedKind != 'local_worker';
    final busy =
        _loading ||
        _savingAsr ||
        _probingAsrModel ||
        _renamingAsrModel ||
        _testingAsr ||
        _copyingAgentHandoff;
    final showFeedback = busy || _error != null || _message != null;
    final snapshot = _snapshot;
    final activeSelection = snapshot == null
        ? ''
        : _asrSelectionIdForProvider(snapshot, snapshot.asrProviderName);
    final activeProvider = snapshot == null
        ? null
        : _asrProviderByName(snapshot, snapshot.asrProviderName);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _SegmentedEngines(
                selected: _selectedAsrProvider,
                active: activeSelection,
                activeReady: activeProvider?.canRun ?? false,
                onPick:
                    _savingAsr ||
                        _probingAsrModel ||
                        _renamingAsrModel ||
                        _testingAsr ||
                        _copyingAgentHandoff
                    ? null
                    : _pickAsrProvider,
              ),
            ),
            const SizedBox(width: T.s12),
            MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  key: const ValueKey('asr-agent-scope-full'),
                  leadingIcon: const Icon(Icons.build_circle_outlined),
                  onPressed: () => _openAsrAgentHandoff('full', '完整准备'),
                  child: const Text('完整准备本机识别'),
                ),
                MenuItemButton(
                  key: const ValueKey('asr-agent-scope-model'),
                  leadingIcon: const Icon(Icons.view_in_ar_rounded),
                  onPressed: () =>
                      _openAsrAgentHandoff('prepare_model', '准备模型'),
                  child: const Text('只准备模型'),
                ),
                MenuItemButton(
                  key: const ValueKey('asr-agent-scope-accelerator'),
                  leadingIcon: const Icon(Icons.memory_rounded),
                  onPressed: () =>
                      _openAsrAgentHandoff('prepare_accelerator', '准备 GPU 加速'),
                  child: const Text('只准备 GPU 加速'),
                ),
                const Divider(height: 1),
                MenuItemButton(
                  key: const ValueKey('asr-agent-scope-register'),
                  leadingIcon: const Icon(Icons.link_rounded),
                  onPressed: () => _openAsrAgentHandoff('register', '接入已有资源'),
                  child: const Text('接入已有资源'),
                ),
                MenuItemButton(
                  key: const ValueKey('asr-agent-scope-inspect'),
                  leadingIcon: const Icon(Icons.manage_search_rounded),
                  onPressed: () => _openAsrAgentHandoff('inspect', '了解本机环境'),
                  child: const Text('了解本机环境'),
                ),
              ],
              builder: (context, controller, child) => ActionButton(
                key: const ValueKey('asr-agent-handoff'),
                label: '交给 Agent',
                icon: Icons.terminal_rounded,
                trailingIcon: Icons.expand_more_rounded,
                onTap: _copyingAgentHandoff
                    ? null
                    : () {
                        if (controller.isOpen) {
                          controller.close();
                        } else {
                          controller.open();
                        }
                      },
              ),
            ),
          ],
        ),
        if (showFeedback) ...[
          const SizedBox(height: T.s8),
          _AsrFeedbackBar(
            busy: busy,
            busyText: _copyingAgentHandoff ? '正在准备 Agent 交接…' : '正在同步…',
            error: _error,
            message: _message,
          ),
        ],
        if (showBackgroundOperation) ...[
          const SizedBox(height: T.s12),
          _AsrBackgroundOperation(
            operation: activeOperation!,
            onCancel: _cancelAsrOperation,
          ),
        ],
        const SizedBox(height: T.s16),
        Expanded(child: _asrDetails()),
      ],
    );
  }

  Widget _asrDetails() {
    final draft = _asrDraft(_selectedAsrProvider);
    final kind = '${draft['kind']}';
    final protocol = '${draft['protocol']}';
    final isOpenRouter = protocol == 'openrouter_stt';
    final provider = _selectedAsrOption();
    final canSetDefault =
        kind != 'remote' ||
        _keyTextOrNull() != null ||
        provider?.hasKey == true;
    if (kind == 'local_worker') {
      return _localWhisperSetupDetails(provider);
    }
    return ToolPanel(
      footer: [
        ActionButton(
          label: _savingAsr
              ? '保存中'
              : canSetDefault
              ? '保存并设为默认'
              : '保存配置',
          strong: true,
          onTap: _savingAsr || _testingAsr ? null : _saveAsrProvider,
        ),
        if (kind == 'local_server' || kind == 'remote')
          ActionButton(
            label: _testingAsr ? '测试中' : '测试连接',
            icon: Icons.wifi_tethering_rounded,
            onTap: _testingAsr || _savingAsr ? null : _testAsrProvider,
          ),
        if (isOpenRouter)
          ActionButton(
            key: const ValueKey('openrouter-key-usage'),
            label: _checkingOpenRouterUsage ? '查询中' : '查询用量',
            icon: Icons.receipt_long_outlined,
            onTap: _checkingOpenRouterUsage || _savingAsr || _testingAsr
                ? null
                : () => _checkOpenRouterUsage(),
          ),
      ],
      footnote: kind == 'remote'
          ? !canSetDefault
                ? '先保存服务配置；添加 API key 后才能设为默认。'
                : isOpenRouter
                ? '音频会上传到 OpenRouter 并产生模型费用；密钥保存在用户级凭据文件中。'
                : '密钥保存在用户级凭据文件中。'
          : null,
      children: [
        _AsrOverview(
          label: _asrLabelForDraft(draft),
          readiness: provider?.readiness,
          draftDirty: _asrDraftDirty,
        ),
        if (!_asrDraftDirty &&
            provider?.policyResolution.isNotEmpty == true) ...[
          const SizedBox(height: T.s8),
          _AsrExecutionSummary(provider: provider!),
        ],
        if (isOpenRouter &&
            (_checkingOpenRouterUsage ||
                _openRouterUsageMessage != null ||
                _openRouterUsageError != null)) ...[
          const SizedBox(height: T.s8),
          _AsrFeedbackBar(
            busy: _checkingOpenRouterUsage,
            busyText: '正在读取 OpenRouter 密钥用量…',
            error: _openRouterUsageError,
            message: _openRouterUsageMessage,
          ),
        ],
        const SizedBox(height: T.s8),
        if (kind == 'local_inprocess') ...[
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
                child: isOpenRouter
                    ? _AsrSelect(
                        label: 'OpenRouter 模型',
                        value: _model.text,
                        items: _openRouterModelItems(provider),
                        onChanged: (model) {
                          _model.text = model;
                          _markAsrDraftDirty();
                        },
                      )
                    : Input(
                        label: '模型',
                        controller: _model,
                        onChanged: (_) => _markAsrDraftDirty(),
                      ),
              ),
            ],
          ),
          if (isOpenRouter) ...[
            const SizedBox(height: T.s8),
            Text(
              _openRouterModelHint(provider, _model.text),
              style: T.tCaption.copyWith(color: T.muted),
            ),
          ],
          if (kind == 'remote') ...[
            const SizedBox(height: T.s12),
            Input(
              label: isOpenRouter
                  ? 'OpenRouter API key（留空则沿用已保存密钥）'
                  : 'OpenAI API key（留空则沿用已保存密钥）',
              controller: _key,
              obscure: true,
              onChanged: (_) => isOpenRouter
                  ? _markOpenRouterKeyChanged()
                  : _markAsrCredentialChanged(),
            ),
          ],
        ],
      ],
    );
  }

  Widget _localWhisperSetupDetails(AsrProviderOption? provider) {
    final models = _snapshot?.asrModels ?? const <AsrComponentOption>[];
    final modelIds = models.isEmpty
        ? const ['small', 'medium', 'large-v3']
        : models.map((item) => item.id).toList(growable: false);
    final editedModel = _asrModelSource == 'external'
        ? _externalDraftModelId.trim()
        : _managedModelId.trim();
    final selectedModel =
        _asrModelSource == 'external' && editedModel.isNotEmpty
        ? editedModel
        : modelIds.contains(editedModel)
        ? editedModel
        : 'small';
    final runtime = _snapshot?.asrRuntime;
    final model = models.firstWhere(
      (item) => item.id == selectedModel,
      orElse: () => AsrComponentOption(id: selectedModel, kind: 'model'),
    );
    final operation = _activeAsrOperation;
    final active = operation?.active == true;
    final storage = _snapshot?.asrStorage ?? const AsrStorageOption();
    final managedDownloadBytes =
        (runtime?.installed == true ? 0 : runtime?.size ?? 0) +
        (model.installed ? 0 : model.size);
    final externalDownloadBytes = runtime?.installed == true
        ? 0
        : runtime?.size ?? 0;
    final plannedDownloadBytes = _asrModelSource == 'managed'
        ? managedDownloadBytes
        : externalDownloadBytes;
    final storageAvailable =
        storage.configError.isEmpty && storage.diskError.isEmpty;
    final storageHasSpace = storage.hasSpaceFor(plannedDownloadBytes);
    final managedReady = runtime?.installed == true && model.installed;
    final isCurrentDefault =
        provider != null && provider.name == _snapshot?.asrProviderName;
    final savedReady = provider?.readiness.canRun ?? false;
    final current = _localWhisperCurrent(provider);
    final showEditor =
        _editingLocalWhisper || _asrDraftDirty || !current.configured;
    final needsPrimaryAction =
        _asrDraftDirty || !savedReady || !isCurrentDefault;
    final footer = <Widget>[];
    if (operation != null && !operation.active) {
      if (operation.state == 'failed' || operation.state == 'cancelled') {
        footer.add(
          ActionButton(
            label: operation.state == 'cancelled' ? '继续下载' : '重试',
            strong: true,
            onTap: _retryAsrOperation,
          ),
        );
        footer.add(ActionButton(label: '调整设置', onTap: _dismissAsrOperation));
      }
    } else if (!active && (needsPrimaryAction || showEditor)) {
      if (showEditor && current.configured) {
        footer.add(
          ActionButton(
            label: _asrDraftDirty ? '取消更改' : '完成',
            onTap: _closeLocalWhisperEditor,
          ),
        );
      }
      if (needsPrimaryAction && _asrModelSource == 'managed') {
        final actionLabel = managedReady
            ? _asrDraftDirty
                  ? '应用更改'
                  : savedReady && !isCurrentDefault
                  ? '设为默认'
                  : '应用设置'
            : plannedDownloadBytes > 0
            ? '下载并${current.configured ? '切换' : '启用'}'
            : '下载并启用';
        footer.add(
          ActionButton(
            label: _savingAsr
                ? '正在启动'
                : !storageAvailable
                ? '保存位置不可用'
                : !storageHasSpace
                ? '保存空间不足'
                : actionLabel,
            strong: true,
            onTap: _savingAsr || !storageHasSpace
                ? null
                : managedReady
                ? _saveAsrProvider
                : _startManagedAsrSetup,
          ),
        );
      } else if (needsPrimaryAction) {
        final runtimeReady = runtime?.installed == true;
        final verified = _detectedExternalModelId.isNotEmpty;
        final actionLabel = verified
            ? _asrDraftDirty
                  ? '应用更改'
                  : savedReady && !isCurrentDefault
                  ? '设为默认'
                  : '应用设置'
            : '验证并启用';
        footer.add(
          ActionButton(
            label: runtimeReady
                ? _probingAsrModel
                      ? '验证中'
                      : actionLabel
                : externalDownloadBytes > 0
                ? '下载 ${_formatBytes(externalDownloadBytes)} 识别组件'
                : '下载识别组件',
            strong: true,
            onTap: runtimeReady
                ? _probingAsrModel || _externalModelPath.text.isEmpty
                      ? null
                      : verified
                      ? () => _saveAsrProvider(
                          successMessage:
                              '${_externalModelDisplayLabel(_detectedExternalModelId, _externalModelPath.text)} 已设为默认。',
                        )
                      : _probeExternalAsrModel
                : storageHasSpace
                ? () => _startAsrInstall('runtime')
                : null,
          ),
        );
      }
    }

    return ToolPanel(
      footer: footer.isEmpty
          ? const []
          : [
              SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: T.s12,
                  runSpacing: T.s8,
                  children: footer,
                ),
              ),
            ],
      children: [
        if (operation != null)
          _AsrSetupProgress(
            operation: operation,
            onCancel: operation.active ? _cancelAsrOperation : null,
          )
        else ...[
          _localWhisperSettings(
            provider,
            modelIds,
            selectedModel,
            runtime: runtime,
            model: model,
            storage: storage,
          ),
        ],
      ],
    );
  }

  Widget _localWhisperSettings(
    AsrProviderOption? provider,
    List<String> modelIds,
    String selectedModel, {
    required AsrComponentOption? runtime,
    required AsrComponentOption model,
    required AsrStorageOption storage,
  }) {
    final current = _localWhisperCurrent(provider);
    final showEditor =
        _editingLocalWhisper || _asrDraftDirty || !current.configured;
    return Container(
      key: const ValueKey('asr-local-configuration'),
      width: double.infinity,
      padding: const EdgeInsets.all(T.s16),
      decoration: BoxDecoration(
        color: T.surface,
        border: Border.all(color: T.line),
        borderRadius: BorderRadius.circular(T.rMd),
      ),
      child: showEditor
          ? _localWhisperEditor(
              provider,
              modelIds,
              selectedModel,
              runtime: runtime,
              model: model,
              storage: storage,
            )
          : _localWhisperSummary(
              provider,
              runtime: runtime,
              model: model,
              storage: storage,
            ),
    );
  }

  Widget _localWhisperSummary(
    AsrProviderOption? provider, {
    required AsrComponentOption? runtime,
    required AsrComponentOption model,
    required AsrStorageOption storage,
  }) {
    final current = _localWhisperCurrent(provider);
    final external = current.modelSource == 'external';
    final title = external
        ? _externalModelDisplayLabel(current.modelId, current.modelPath)
        : _asrModelLabel(current.modelId);
    final execution = current.executionDetail
        .split(' · ')
        .take(2)
        .where((part) => part.isNotEmpty)
        .join(' · ');
    final detail = [
      external ? '本地模型文件夹' : '应用管理',
      if (execution.isNotEmpty) execution,
    ];
    final registration = external
        ? _registeredExternalModel(current.modelId, current.modelPath)
        : null;
    final runtimeDownload = runtime?.installed == true ? 0 : runtime?.size ?? 0;
    final modelDownload = !external && !model.installed ? model.size : 0;
    final downloadItems = <String>[
      if (runtimeDownload > 0) '识别组件 ${_formatBytes(runtimeDownload)}',
      if (modelDownload > 0) '$title ${_formatBytes(modelDownload)}',
    ];
    final statusColor = current.ready
        ? T.ok
        : current.configured
        ? T.warn
        : T.muted;
    final statusLabel = current.ready
        ? current.isDefault
              ? '可用'
              : '已保存'
        : current.configured
        ? '需要处理'
        : '尚未配置';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('当前方案', style: T.tSection),
            const Spacer(),
            _AsrStatusChip(label: statusLabel, color: statusColor),
          ],
        ),
        const SizedBox(height: T.s12),
        Row(
          children: [
            Icon(
              current.ready
                  ? Icons.check_circle_outline_rounded
                  : Icons.view_in_ar_outlined,
              size: 28,
              color: current.ready ? T.ok : T.muted,
            ),
            const SizedBox(width: T.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: T.tBody.copyWith(fontWeight: T.wBold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail.join(' · '),
                    style: T.tCaption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (external && current.modelPath.isNotEmpty)
              IconButton(
                key: const ValueKey('asr-model-open-location'),
                tooltip: '打开模型文件夹',
                onPressed: () => _openExternalModelPath(current.modelPath),
                icon: const Icon(Icons.folder_open_rounded, size: 19),
              ),
            if (registration != null)
              IconButton(
                key: const ValueKey('asr-model-rename'),
                tooltip: '修改显示名称',
                onPressed: _renamingAsrModel
                    ? null
                    : () => _renameExternalAsrModel(registration),
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
            const SizedBox(width: T.s8),
            ActionButton(
              key: const ValueKey('asr-model-change'),
              label: '调整方案',
              icon: Icons.tune_rounded,
              onTap: _probingAsrModel || _savingAsr
                  ? null
                  : _openLocalWhisperEditor,
            ),
          ],
        ),
        if (downloadItems.isNotEmpty) ...[
          const SizedBox(height: T.s12),
          _AsrApplySummary(
            changes: const [],
            downloadItems: downloadItems,
            requiredDownloadBytes: runtimeDownload + modelDownload,
            storage: storage,
          ),
        ],
      ],
    );
  }

  Widget _localWhisperEditor(
    AsrProviderOption? provider,
    List<String> modelIds,
    String selectedModel, {
    required AsrComponentOption? runtime,
    required AsrComponentOption model,
    required AsrStorageOption storage,
  }) {
    final current = _localWhisperCurrent(provider);
    final models = {
      for (final option in _snapshot?.asrModels ?? const <AsrComponentOption>[])
        option.id: option,
    };
    final currentLabel = current.configured
        ? _localWhisperCurrentLabel(current)
        : '尚未配置';
    final currentExternal = current.modelSource == 'external';
    final selectedExternal = _asrModelSource == 'external';
    final externalModelId = selectedExternal
        ? _externalDraftModelId
        : currentExternal
        ? current.modelId
        : '';
    final externalPath = selectedExternal
        ? _externalModelPath.text
        : currentExternal
        ? current.modelPath
        : '';
    final externalTitle = externalModelId.isEmpty
        ? '使用本地模型文件夹…'
        : _externalModelDisplayLabel(externalModelId, externalPath);
    final externalRegistration = externalModelId.isEmpty
        ? null
        : _registeredExternalModel(externalModelId, externalPath);
    final runtimeDownload = runtime?.installed == true ? 0 : runtime?.size ?? 0;
    final modelDownload = _asrModelSource == 'managed' && !model.installed
        ? model.size
        : 0;
    final downloadItems = <String>[
      if (runtimeDownload > 0) '识别组件 ${_formatBytes(runtimeDownload)}',
      if (modelDownload > 0)
        '${_asrModelLabel(selectedModel)} ${_formatBytes(modelDownload)}',
    ];
    final changes = _asrDraftDirty
        ? _localWhisperDraftChanges(current, selectedModel)
        : const <_AsrChange>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('调整本机 Whisper', style: T.tSection),
        const SizedBox(height: 2),
        Text(
          '当前：$currentLabel',
          style: T.tCaption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: T.s16),
        Text('选择模型', style: T.tBody.copyWith(fontWeight: T.wBold)),
        const SizedBox(height: T.s8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var index = 0; index < modelIds.length; index++) ...[
              if (index > 0) const SizedBox(width: T.s8),
              Expanded(
                child: _AsrManagedModelChoice(
                  key: ValueKey('asr-managed-model-${modelIds[index]}'),
                  label: _asrModelLabel(modelIds[index]),
                  detail: _asrManagedModelAvailability(
                    models[modelIds[index]] ??
                        AsrComponentOption(id: modelIds[index], kind: 'model'),
                  ),
                  selected:
                      _asrModelSource == 'managed' &&
                      selectedModel == modelIds[index],
                  current:
                      !currentExternal && current.modelId == modelIds[index],
                  onTap: _probingAsrModel || _savingAsr
                      ? null
                      : () => _selectManagedWhisperModel(modelIds[index]),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: T.s8),
        _AsrExternalModelChoiceRow(
          key: const ValueKey('asr-external-model'),
          title: externalTitle,
          detail: selectedExternal
              ? _detectedExternalModelId.isNotEmpty
                    ? '本地模型文件夹 · 已验证'
                    : '本地模型文件夹 · 等待验证'
              : currentExternal
              ? '本地模型文件夹 · 当前方案'
              : '登记并原地使用已有 faster-whisper 模型',
          selected: selectedExternal,
          current: currentExternal,
          onTap: _discoveringAsrModels || _probingAsrModel || _renamingAsrModel
              ? null
              : _openExternalWhisperModelPicker,
          onOpen: externalPath.trim().isEmpty
              ? null
              : () => _openExternalModelPath(externalPath),
          onRename: externalRegistration == null || _renamingAsrModel
              ? null
              : () => _renameExternalAsrModel(externalRegistration),
        ),
        const SizedBox(height: T.s16),
        const Divider(height: 1, color: T.line),
        const SizedBox(height: T.s12),
        Row(
          children: [
            SizedBox(width: 320, child: _asrDeviceSelect()),
            const SizedBox(width: T.s16),
            Expanded(
              child: Text(
                _device.text == 'auto'
                    ? '自动会优先使用已验证的 NVIDIA 资源，否则使用 CPU。'
                    : '此选择将用于之后创建的本机识别任务。',
                style: T.tCaption,
                maxLines: 2,
              ),
            ),
          ],
        ),
        if (changes.isNotEmpty || downloadItems.isNotEmpty) ...[
          const SizedBox(height: T.s12),
          _AsrApplySummary(
            changes: changes,
            downloadItems: downloadItems,
            requiredDownloadBytes: runtimeDownload + modelDownload,
            storage: storage,
          ),
        ],
      ],
    );
  }

  String _asrManagedModelAvailability(AsrComponentOption model) {
    if (model.installed) return '已在本机';
    return model.size > 0 ? '需下载 ${_formatBytes(model.size)}' : '需要下载';
  }

  Widget _asrDeviceSelect() {
    final active = _snapshot?.asrActiveExecution ?? const AsrActiveExecution();
    final selectedProvider = _asrProviderNameForSelection(_selectedAsrProvider);
    final activeMatchesSelection =
        active.kind == 'local_worker' && active.provider == selectedProvider;
    final installedManagedNvidia =
        _snapshot?.asrAccelerators.any((item) => item.installed) ?? false;
    final verifiedManagedNvidia =
        _snapshot?.asrAccelerators.any((item) {
          if (!item.installed) return false;
          final hardware = _stringMap(item.raw['hardware_probe']);
          final cuda = _stringMap(hardware['cuda']);
          return hardware['ok'] == true && cuda['available'] == true;
        }) ??
        false;
    final activeExternalNvidia =
        activeMatchesSelection &&
        active.resolvedDevice == 'cuda' &&
        active.acceleratorSource == 'external' &&
        active.acceleratorReady;
    final activeManagedNvidia =
        activeMatchesSelection &&
        active.resolvedDevice == 'cuda' &&
        active.acceleratorSource == 'managed' &&
        active.acceleratorReady;
    final availableExternalNvidia =
        _snapshot?.asrRegisteredAccelerators.any(
          (item) => item.ready && item.cudaAvailable,
        ) ??
        false;
    final preferExternalNvidia =
        activeExternalNvidia ||
        (!activeManagedNvidia && availableExternalNvidia);
    final supportedCudaComputeTypes = <String>{
      if (activeMatchesSelection) ...active.cudaComputeTypes,
      for (final item
          in _snapshot?.asrRegisteredAccelerators ??
              const <AsrRegisteredResourceOption>[])
        if (item.ready && item.cudaAvailable) ...item.computeTypes,
      for (final item
          in _snapshot?.asrAccelerators ?? const <AsrComponentOption>[])
        if (item.installed)
          ..._objectList(
            _stringMap(
              _stringMap(item.raw['hardware_probe'])['cuda'],
            )['compute_types'],
          ).map((value) => '$value').where((value) => value.isNotEmpty),
    };
    final hasNvidia = installedManagedNvidia || availableExternalNvidia;
    final resolvedDevice = _device.text == 'auto'
        ? (activeMatchesSelection && active.resolvedDevice == 'cuda') ||
                  (!activeMatchesSelection &&
                      (verifiedManagedNvidia || availableExternalNvidia))
              ? 'cuda'
              : 'cpu'
        : _device.text;
    final items = <String, String>{
      'auto': '自动（当前：${resolvedDevice == 'cuda' ? 'NVIDIA' : 'CPU'}）',
      'cpu': 'CPU',
      if (hasNvidia || _device.text == 'cuda')
        'cuda': preferExternalNvidia
            ? 'NVIDIA（外部资源，已验证）'
            : verifiedManagedNvidia
            ? 'NVIDIA（应用管理，已验证）'
            : installedManagedNvidia
            ? 'NVIDIA（应用管理，待验证）'
            : 'NVIDIA（需要处理）',
    };
    return _AsrSelect(
      label: '运算方式',
      value: items.containsKey(_device.text) ? _device.text : 'auto',
      items: items,
      onChanged: _probingAsrModel || _savingAsr
          ? null
          : (value) {
              if (_probingAsrModel || _savingAsr) return;
              setState(() {
                _device.text = value;
                if (value == 'cpu' || value == 'auto') {
                  _localComputeType = 'auto';
                } else if (_localComputeType == 'auto' ||
                    const {
                      'int8',
                      'int8_float32',
                    }.contains(_localComputeType)) {
                  _localComputeType =
                      active.computeType.isNotEmpty &&
                          active.computeType != 'auto'
                      ? active.computeType
                      : supportedCudaComputeTypes.contains('float16')
                      ? 'float16'
                      : 'auto';
                }
                if (_asrModelSource == 'external') {
                  final registration = _registeredExternalModel(
                    _externalDraftModelId,
                    _externalModelPath.text,
                  );
                  _externalDraftRegistrationId = registration?.id ?? '';
                  _detectedExternalModelId = registration == null
                      ? ''
                      : _externalDraftModelId;
                }
                _asrDraftDirty = !_localDraftMatchesSaved();
              });
            },
    );
  }

  String _asrExecutionDetail() {
    final active = _snapshot?.asrActiveExecution;
    final selectedProvider = _asrProviderNameForSelection(_selectedAsrProvider);
    if (active == null ||
        active.kind != 'local_worker' ||
        active.provider != selectedProvider ||
        !active.canRun) {
      return '';
    }
    final device = active.resolvedDevice == 'cuda' ? 'NVIDIA' : 'CPU';
    final compute = active.computeType.isEmpty ? 'auto' : active.computeType;
    final source = active.resolvedDevice == 'cuda'
        ? active.acceleratorSource == 'external'
              ? '外部资源已验证'
              : '应用管理资源'
        : '';
    return [device, compute, if (source.isNotEmpty) source].join(' · ');
  }

  _LocalWhisperCurrent _localWhisperCurrent(AsrProviderOption? provider) {
    final snapshot = _snapshot;
    final active = snapshot?.asrActiveExecution;
    final hasProvider = provider != null && provider.name.isNotEmpty;
    final activeMatches =
        hasProvider &&
        active != null &&
        active.provider == provider.name &&
        active.kind == 'local_worker';
    final local = _stringMap(provider?.raw['local']);
    final modelId = activeMatches && active.model.isNotEmpty
        ? active.model
        : provider?.model ?? '';
    final modelSource = activeMatches && active.modelSource.isNotEmpty
        ? active.modelSource
        : '${local['model_source'] ?? ''}'.trim();
    final modelPath = activeMatches && active.modelPath.isNotEmpty
        ? active.modelPath
        : '${local['model_path'] ?? ''}'.trim();
    final ready = activeMatches ? active.canRun : provider?.canRun ?? false;
    return _LocalWhisperCurrent(
      configured: hasProvider && modelId.isNotEmpty,
      isDefault: hasProvider && provider.name == snapshot?.asrProviderName,
      ready: ready,
      modelId: modelId,
      modelSource: modelSource,
      modelPath: modelPath,
      executionDetail: activeMatches && active.canRun
          ? _asrExecutionDetail()
          : '',
    );
  }

  String _localWhisperCurrentLabel(_LocalWhisperCurrent current) {
    if (!current.configured) return '尚未配置';
    final modelLabel = current.modelSource == 'external'
        ? _externalModelDisplayLabel(current.modelId, current.modelPath)
        : _asrModelLabel(current.modelId);
    final execution = current.executionDetail
        .split(' · ')
        .take(2)
        .where((part) => part.isNotEmpty)
        .join(' · ');
    return [
      modelLabel,
      current.modelSource == 'external' ? '本地文件夹' : '应用下载',
      if (execution.isNotEmpty) execution,
    ].join(' · ');
  }

  List<_AsrChange> _localWhisperDraftChanges(
    _LocalWhisperCurrent current,
    String selectedModel,
  ) {
    final changes = <_AsrChange>[];
    final sourceOrModelChanged =
        _asrModelSource != _savedAsrModelSource ||
        (_asrModelSource == 'managed'
            ? _managedModelId != _savedManagedModelId
            : _externalDraftModelId != _savedExternalModelId ||
                  _externalDraftRegistrationId != _savedExternalRegistrationId);
    final externalPathChanged =
        _asrModelSource == 'external' &&
        _normalizedWindowsPath(_externalModelPath.text) !=
            _normalizedWindowsPath(_savedExternalModelPath);
    if (sourceOrModelChanged) {
      changes.add(
        _AsrChange(
          label: '模型',
          before: current.configured
              ? _localWhisperCurrentModelChoiceLabel(current)
              : '尚未配置',
          after: _localWhisperDraftModelChoiceLabel(selectedModel),
        ),
      );
    } else if (externalPathChanged) {
      changes.add(
        const _AsrChange(label: '模型文件夹', before: '当前登记位置', after: '新选择的位置'),
      );
    }
    if (_device.text.trim() != _savedLocalDevice ||
        _localComputeType != _savedLocalComputeType) {
      changes.add(
        _AsrChange(
          label: '运算',
          before: _localWhisperDeviceLabel(
            _savedLocalDevice,
            _savedLocalComputeType,
          ),
          after: _localWhisperDeviceLabel(
            _device.text.trim(),
            _localComputeType,
          ),
        ),
      );
    }
    return changes;
  }

  String _localWhisperCurrentModelChoiceLabel(_LocalWhisperCurrent current) {
    final modelLabel = current.modelSource == 'external'
        ? _externalModelDisplayLabel(current.modelId, current.modelPath)
        : _asrModelLabel(current.modelId);
    final source = current.modelSource == 'external' ? '本地文件夹' : '应用下载';
    return '$modelLabel（$source）';
  }

  String _localWhisperDraftModelChoiceLabel(String selectedModel) {
    final modelLabel = _asrModelSource == 'external'
        ? _externalModelDisplayLabel(selectedModel, _externalModelPath.text)
        : _asrModelLabel(selectedModel);
    final source = _asrModelSource == 'external' ? '本地文件夹' : '应用下载';
    return '$modelLabel（$source）';
  }

  String _localWhisperDeviceLabel(String device, String computeType) {
    return switch (device.trim()) {
      'cuda' => [
        'NVIDIA',
        if (computeType.trim().isNotEmpty && computeType != 'auto') computeType,
      ].join(' · '),
      'cpu' => 'CPU',
      _ => '自动',
    };
  }

  void _openLocalWhisperEditor() {
    if (_probingAsrModel || _savingAsr || _discoveringAsrModels) return;
    setState(() {
      _editingLocalWhisper = true;
      _message = null;
      _error = null;
    });
  }

  void _closeLocalWhisperEditor() {
    if (_savingAsr || _probingAsrModel || _discoveringAsrModels) return;
    setState(() {
      if (_asrDraftDirty) {
        _loadAsrDraftFields();
      } else {
        _editingLocalWhisper = false;
      }
      _message = null;
      _error = null;
    });
  }

  void _selectManagedWhisperModel(String modelId) {
    if (_probingAsrModel || _savingAsr || _discoveringAsrModels) return;
    setState(() {
      _editingLocalWhisper = true;
      _asrModelSource = 'managed';
      _managedModelId = modelId;
      _model.text = modelId;
      _asrDraftDirty = !_localDraftMatchesSaved();
      _message = null;
      _error = null;
    });
  }

  Future<void> _openExternalWhisperModelPicker() async {
    if (_probingAsrModel || _savingAsr || _discoveringAsrModels) return;
    setState(() => _editingLocalWhisper = true);
    final registeredModels = (_snapshot?.asrRegisteredModels ?? const [])
        .where(
          (item) =>
              item.ready &&
              item.id.trim().isNotEmpty &&
              item.resourceId.trim().isNotEmpty &&
              item.path.trim().isNotEmpty,
        )
        .toList(growable: false);
    if (registeredModels.isEmpty) {
      await _pickExternalModelPath();
      return;
    }
    final currentRegistration = _registeredExternalModel(
      _externalDraftModelId,
      _externalModelPath.text,
    );
    final choice = await showDialog<_AsrExternalModelChoice>(
      context: context,
      builder: (dialogContext) => _AsrExternalModelDialog(
        registeredModels: registeredModels,
        initialExternalRegistrationId:
            currentRegistration?.id ?? _externalDraftRegistrationId,
      ),
    );
    if (!mounted || choice == null) return;
    if (choice.browseExternal) {
      await _pickExternalModelPath();
      return;
    }
    AsrRegisteredResourceOption? registration;
    for (final item in registeredModels) {
      if (item.id == choice.externalRegistrationId) {
        registration = item;
        break;
      }
    }
    if (registration == null) return;
    setState(() {
      _editingLocalWhisper = true;
      _asrModelSource = 'external';
      _externalDraftModelId = registration!.resourceId;
      _externalDraftRegistrationId = registration.id;
      _externalModelPath.text = registration.path;
      _model.text = registration.resourceId;
      _detectedExternalModelId = registration.resourceId;
      _asrDraftDirty = !_localDraftMatchesSaved();
      _message = null;
      _error = null;
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
    if (_savingAsr || _probingAsrModel || _testingAsr) return;
    _openRouterUsageRequestRevision += 1;
    setState(() {
      _selectedAsrProvider = providerName;
      _loadAsrDraftFields();
      _checkingOpenRouterUsage = false;
      _openRouterUsageMessage = null;
      _openRouterUsageError = null;
      _openRouterUsageAutoLoadedFor = null;
      _message = null;
      _error = null;
    });
    _maybeLoadOpenRouterUsage(force: true);
  }

  void _loadAsrDraftFields() {
    final draft = _asrDraft(_selectedAsrProvider, useEditedFields: false);
    _baseUrl.text = '${draft['base_url'] ?? ''}';
    final savedModel = '${draft['model'] ?? ''}'.trim();
    final local = _stringMap(draft['local']);
    final runtime = _stringMap(draft['runtime']);
    final runtimeSource = '${runtime['source'] ?? 'managed'}';
    _asrModelSource = '${local['model_source'] ?? ''}' == 'external'
        ? 'external'
        : runtimeSource == 'external'
        ? 'external'
        : 'managed';
    if (draft['kind'] == 'local_worker') {
      final availableModels =
          _snapshot?.asrModels.map((item) => item.id).toList() ??
          const <String>[];
      final savedManaged = '${local['managed_model_size'] ?? ''}'.trim();
      final managedCandidate = savedManaged.isNotEmpty
          ? savedManaged
          : _asrModelSource == 'managed'
          ? savedModel
          : 'small';
      _managedModelId = availableModels.isEmpty
          ? (managedCandidate.isEmpty ? 'small' : managedCandidate)
          : availableModels.contains(managedCandidate)
          ? managedCandidate
          : availableModels.contains('small')
          ? 'small'
          : availableModels.first;
      final activeExternalPath = '${local['model_path'] ?? ''}'.trim();
      final rememberedExternalPath = '${local['external_model_path'] ?? ''}'
          .trim();
      _externalModelPath.text = _asrModelSource == 'external'
          ? activeExternalPath
          : rememberedExternalPath;
      final rememberedExternalId = '${local['external_model_id'] ?? ''}'.trim();
      _externalDraftModelId = rememberedExternalId.isNotEmpty
          ? rememberedExternalId
          : _asrModelSource == 'external'
          ? savedModel
          : '';
      _model.text = _asrModelSource == 'external'
          ? _externalDraftModelId
          : _managedModelId;
    } else {
      _model.text = savedModel;
      _externalModelPath.clear();
      _externalDraftModelId = '';
      _externalDraftRegistrationId = '';
    }
    _endpoint.text = '${draft['endpoint'] ?? '/v1/audio/transcriptions'}';
    final savedDevice = '${local['device'] ?? 'auto'}'.trim().toLowerCase();
    _device.text = const {'auto', 'cpu', 'cuda'}.contains(savedDevice)
        ? savedDevice
        : 'auto';
    _localComputeType = '${local['compute_type'] ?? 'auto'}'.trim();
    if (_localComputeType.isEmpty) _localComputeType = 'auto';
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
    final externalRegistration = _registeredExternalModel(
      _externalDraftModelId,
      _externalModelPath.text,
    );
    _externalDraftRegistrationId = externalRegistration?.id ?? '';
    _detectedExternalModelId =
        externalRegistration != null ||
            (_asrModelSource == 'external' && readiness?.canRun == true)
        ? _externalDraftModelId
        : '';
    _key.clear();
    _savedAsrModelSource = _asrModelSource;
    _savedManagedModelId = _managedModelId;
    _savedExternalModelId = _externalDraftModelId;
    _savedExternalRegistrationId = _externalDraftRegistrationId;
    _savedExternalModelPath = _externalModelPath.text.trim();
    _savedLocalDevice = _device.text.trim();
    _savedLocalComputeType = _localComputeType;
    _asrDraftDirty = false;
    _editingLocalWhisper = false;
  }

  bool _localDraftMatchesSaved() {
    return _asrModelSource == _savedAsrModelSource &&
        _managedModelId == _savedManagedModelId &&
        _externalDraftModelId == _savedExternalModelId &&
        _externalDraftRegistrationId == _savedExternalRegistrationId &&
        _normalizedWindowsPath(_externalModelPath.text) ==
            _normalizedWindowsPath(_savedExternalModelPath) &&
        _device.text.trim() == _savedLocalDevice &&
        _localComputeType == _savedLocalComputeType;
  }

  AsrRegisteredResourceOption? _registeredExternalModel(
    String modelId,
    String modelPath,
  ) {
    final normalizedId = modelId.trim();
    final normalizedPath = _normalizedWindowsPath(modelPath);
    if (normalizedId.isEmpty || normalizedPath.isEmpty) return null;
    for (final registration
        in _snapshot?.asrRegisteredModels ??
            const <AsrRegisteredResourceOption>[]) {
      if (registration.resourceId != normalizedId || !registration.ready) {
        continue;
      }
      if (_normalizedWindowsPath(registration.path) != normalizedPath) continue;
      return registration;
    }
    return null;
  }

  String _externalModelDisplayLabel(String modelId, String modelPath) {
    final registration = _registeredExternalModel(modelId, modelPath);
    final userLabel = registration?.userLabel.trim() ?? '';
    return userLabel.isNotEmpty ? userLabel : _asrExternalModelLabel(modelId);
  }

  void _markAsrDraftDirty() {
    if (_asrDraftDirty) return;
    setState(() {
      _asrDraftDirty = true;
      _message = null;
      _error = null;
    });
  }

  void _markOpenRouterKeyChanged() {
    _openRouterUsageRequestRevision += 1;
    setState(() {
      _checkingOpenRouterUsage = false;
      _openRouterUsageMessage = null;
      _openRouterUsageError = null;
      _openRouterUsageAutoLoadedFor = null;
      _asrDraftDirty = true;
      _message = null;
      _error = null;
    });
  }

  void _markAsrCredentialChanged() {
    setState(() {
      _asrDraftDirty = true;
      _message = null;
      _error = null;
    });
  }

  Future<void> _saveAsrProvider({
    String? successMessage,
    String? providerNameOverride,
    Map<String, Object?>? draftOverride,
  }) async {
    final providerName =
        providerNameOverride ??
        _asrProviderNameForSelection(_selectedAsrProvider);
    setState(() {
      _savingAsr = true;
      _error = null;
      _message = null;
    });
    try {
      final latest = await _client.desktopSnapshot();
      _snapshot = latest;
      final draft = draftOverride ?? _asrDraft(providerName);
      final providerKind = '${draft['kind'] ?? ''}';
      final savedCredential = _asrProviderByName(latest, providerName).hasKey;
      final setAsDefault =
          providerKind != 'remote' ||
          _keyTextOrNull() != null ||
          savedCredential;
      if (providerKind == 'local_worker') {
        await _activateLocalAsrResources(
          providerName: providerName,
          snapshot: latest,
        );
      } else {
        await _client.asrProviderSave(
          providerDraft: draft,
          apiKey: _keyTextOrNull(),
          expectedVersion: latest.pipelineFileVersion,
          setDefault: setAsDefault,
        );
      }
      await _loadConfig(preferredAsrProvider: providerName);
      if (!mounted) return;
      final savedSnapshot = _snapshot;
      final savedProvider = savedSnapshot == null
          ? null
          : _asrProviderByName(savedSnapshot, providerName);
      if (setAsDefault) {
        await widget.bridge.setAsrDefault(
          savedProvider?.displayLabel ?? _asrLabelForDraft(draft),
          configured: savedProvider?.canRun ?? false,
        );
      }
      await widget.bridge.refreshServiceSnapshot();
      if (!mounted) return;
      setState(() {
        _message =
            successMessage ??
            (setAsDefault
                ? '识别默认已保存：${_asrLabelForDraft(draft)}。'
                : '识别配置已保存：${_asrLabelForDraft(draft)}。添加 API key 后可设为默认。');
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _savingAsr = false);
    }
  }

  Future<void> _activateLocalAsrResources({
    required String providerName,
    required DesktopSnapshot snapshot,
  }) async {
    final device = _device.text.trim().isEmpty ? 'auto' : _device.text.trim();
    final activeExecution = snapshot.asrActiveExecution;
    final accelerator = _asrAcceleratorTarget(snapshot, device);
    final resolvesToCuda =
        device == 'cuda' ||
        (device == 'auto' &&
            (activeExecution.resolvedDevice == 'cuda' ||
                accelerator.managedId != null ||
                accelerator.registrationId != null));
    final computeType = resolvesToCuda ? _localComputeType : 'auto';
    String? managedModelId;
    String? modelRegistrationId;
    if (_asrModelSource == 'external') {
      final registration = _externalDraftRegistrationId.isNotEmpty
          ? snapshot.asrRegisteredModels.firstWhere(
              (item) => item.id == _externalDraftRegistrationId,
              orElse: () =>
                  const AsrRegisteredResourceOption(id: '', kind: 'model'),
            )
          : _registeredExternalModel(
              _externalDraftModelId,
              _externalModelPath.text,
            );
      if (registration == null ||
          registration.id.isEmpty ||
          !registration.ready) {
        throw StateError('外部 Whisper 模型尚未完成注册验证。');
      }
      modelRegistrationId = registration.id;
    } else {
      managedModelId = _managedModelId;
    }

    if (device == 'cuda' &&
        accelerator.registrationId == null &&
        accelerator.managedId == null) {
      throw StateError('NVIDIA 加速资源尚未完成验证。');
    }

    await _client.activateAsrResources(
      provider: providerName,
      managedModelId: managedModelId,
      modelRegistrationId: modelRegistrationId,
      managedAcceleratorId: accelerator.managedId,
      acceleratorRegistrationId: accelerator.registrationId,
      device: device,
      computeType: computeType,
      expectedVersion: snapshot.pipelineFileVersion,
    );
  }

  ({String? managedId, String? registrationId}) _asrAcceleratorTarget(
    DesktopSnapshot snapshot,
    String device,
  ) {
    if (device == 'cpu') return (managedId: null, registrationId: null);
    final active = snapshot.asrActiveExecution;

    bool managedReady(AsrComponentOption item) {
      if (!item.installed) return false;
      final hardware = _stringMap(item.raw['hardware_probe']);
      final cuda = _stringMap(hardware['cuda']);
      return hardware['ok'] == true && cuda['available'] == true;
    }

    if (active.acceleratorSource == 'external') {
      for (final item in snapshot.asrRegisteredAccelerators) {
        if (item.id == active.acceleratorRegistrationId &&
            item.ready &&
            item.cudaAvailable) {
          return (managedId: null, registrationId: item.id);
        }
      }
    } else if (active.acceleratorSource == 'managed') {
      for (final item in snapshot.asrAccelerators) {
        if (item.id == active.acceleratorId && managedReady(item)) {
          return (managedId: item.id, registrationId: null);
        }
      }
    }
    for (final item in snapshot.asrRegisteredAccelerators) {
      if (item.ready && item.cudaAvailable) {
        return (managedId: null, registrationId: item.id);
      }
    }
    for (final item in snapshot.asrAccelerators) {
      if (managedReady(item)) {
        return (managedId: item.id, registrationId: null);
      }
    }
    return (managedId: null, registrationId: null);
  }

  AsrProviderOption? _selectedAsrOption() {
    final snapshot = _snapshot;
    if (snapshot == null) return null;
    final name = _asrProviderNameForSelection(_selectedAsrProvider);
    final provider = _asrProviderByName(snapshot, name);
    return provider.name.isEmpty ? null : provider;
  }

  Future<void> _startManagedAsrSetup() async {
    final modelId = _managedModelId.trim().isEmpty
        ? 'small'
        : _managedModelId.trim();
    final providerName = _asrProviderNameForSelection(_selectedAsrProvider);
    _asrOperationDismissTimer?.cancel();
    _asrOperationDismissTimer = null;
    setState(() {
      _savingAsr = true;
      _error = null;
      _message = null;
    });
    try {
      final latest = await _client.desktopSnapshot();
      if (!mounted) return;
      setState(() => _snapshot = latest);
      final device = _device.text.trim().isEmpty ? 'auto' : _device.text.trim();
      final accelerator = _asrAcceleratorTarget(latest, device);
      if (device == 'cuda' &&
          accelerator.registrationId == null &&
          accelerator.managedId == null) {
        throw StateError('NVIDIA 加速资源尚未完成验证。');
      }
      final resolvesToCuda =
          device == 'cuda' ||
          (device == 'auto' &&
              (accelerator.managedId != null ||
                  accelerator.registrationId != null));
      final operation = await _client.asrSetupStart(
        modelId,
        activateOnComplete: true,
        provider: providerName,
        managedAcceleratorId: accelerator.managedId,
        acceleratorRegistrationId: accelerator.registrationId,
        device: device,
        computeType: resolvesToCuda ? _localComputeType : 'auto',
      );
      if (!mounted) return;
      setState(() {
        _activeAsrOperation = operation;
      });
      await widget.bridge.refreshServiceSnapshot();
      if (!mounted) return;
      _startAsrOperationPolling();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _savingAsr = false);
    }
  }

  Future<void> _startAsrInstall(String kind, {String? itemId}) async {
    _asrOperationDismissTimer?.cancel();
    _asrOperationDismissTimer = null;
    setState(() {
      _error = null;
      _message = null;
    });
    try {
      final operation = await _client.asrComponentInstall(kind, itemId: itemId);
      if (!mounted) return;
      setState(() => _activeAsrOperation = operation);
      await widget.bridge.refreshServiceSnapshot();
      if (!mounted) return;
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
        final activatedSetup =
            operation.kind == 'setup' && operation.state == 'completed';
        await _loadConfig(preserveAsrDraft: !activatedSetup);
        if (!mounted) return;
        await widget.bridge.refreshServiceSnapshot();
        if (!mounted) return;
        setState(() {
          _activeAsrOperation = operation;
          if (operation.state == 'completed') {
            _message = operation.kind == 'setup'
                ? _managedSetupIsCurrent(operation)
                      ? '${_asrModelLabel(operation.itemId)} 已下载并设为默认。'
                      : '${_asrModelLabel(operation.itemId)} 已下载，可在本机 Whisper 中启用。'
                : '${_asrOperationLabel(operation.itemId)}下载完成。';
          } else if (operation.state == 'failed') {
            _error = null;
            _message = null;
          } else if (operation.state == 'cancelled') {
            _error = null;
            _message = null;
          }
        });
        _scheduleAsrOperationDismiss(operation);
      }
    } on Object catch (error) {
      _asrOperationPoll?.cancel();
      _asrOperationPoll = null;
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    }
  }

  bool _managedSetupIsCurrent(AsrOperationStatus operation) {
    if (operation.kind != 'setup') return false;
    final snapshot = _snapshot;
    final provider = snapshot == null
        ? null
        : _asrProviderByName(snapshot, snapshot.asrProviderName);
    if (provider == null || provider.name.isEmpty || !provider.canRun) {
      return false;
    }
    final local = _stringMap(provider.raw['local']);
    return provider.kind == 'local_worker' &&
        '${local['model_source'] ?? ''}' != 'external' &&
        provider.model == operation.itemId;
  }

  void _scheduleAsrOperationDismiss(AsrOperationStatus operation) {
    _asrOperationDismissTimer?.cancel();
    if (operation.active || operation.state != 'completed') return;
    _asrOperationDismissTimer = Timer(const Duration(milliseconds: 2200), () {
      if (!mounted || _activeAsrOperation?.id != operation.id) return;
      setState(() => _activeAsrOperation = null);
    });
  }

  Future<void> _cancelAsrOperation() async {
    final operationId = _activeAsrOperation?.id;
    if (operationId == null || operationId.isEmpty) return;
    try {
      final operation = await _client.asrOperationCancel(operationId);
      if (!mounted) return;
      setState(() => _activeAsrOperation = operation);
      await widget.bridge.refreshServiceSnapshot();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    }
  }

  Future<void> _retryAsrOperation() async {
    final operation = _activeAsrOperation;
    if (operation == null || operation.active) return;
    setState(() => _activeAsrOperation = null);
    if (operation.kind == 'setup') {
      _managedModelId = operation.itemId;
      _model.text = operation.itemId;
      await _startManagedAsrSetup();
      return;
    }
    await _startAsrInstall(operation.kind, itemId: operation.itemId);
  }

  void _dismissAsrOperation() {
    _asrOperationDismissTimer?.cancel();
    setState(() {
      _activeAsrOperation = null;
      _error = null;
      _message = null;
    });
  }

  Future<void> _pickExternalModelPath() async {
    if (_probingAsrModel || _savingAsr || _discoveringAsrModels) return;
    final path = await _directoryPicker('选择模型文件夹或它的上层文件夹');
    if (path == null || path.trim().isEmpty || !mounted) return;
    setState(() {
      _discoveringAsrModels = true;
      _message = null;
      _error = null;
    });
    try {
      final discovery = await _client.discoverExternalAsrModels(path.trim());
      if (!mounted) return;
      if (!discovery.ok) {
        setState(() {
          _error = discovery.message.isEmpty
              ? '无法读取所选位置，请重新选择。'
              : discovery.message;
        });
        return;
      }
      if (discovery.candidates.isEmpty) {
        setState(() {
          _error = discovery.truncated
              ? '所选范围太大，暂未找到模型；请改选更靠近模型的位置。'
              : '没有找到可加载的 faster-whisper 模型。可以改选模型本身或它的上层文件夹。';
        });
        return;
      }
      final candidate = discovery.candidates.length == 1
          ? discovery.candidates.single
          : await _chooseExternalModelCandidate(discovery.candidates);
      if (candidate == null || !mounted) return;
      final registration = _registeredExternalModel(
        candidate.modelId,
        candidate.path,
      );
      setState(() {
        _externalModelPath.text = candidate.path;
        _model.text = candidate.modelId;
        _asrModelSource = 'external';
        _externalDraftModelId = candidate.modelId;
        _externalDraftRegistrationId = registration?.id ?? '';
        _detectedExternalModelId = registration == null
            ? ''
            : candidate.modelId;
        _asrDraftDirty = !_localDraftMatchesSaved();
        _message = registration == null
            ? '已找到 ${_asrExternalModelLabel(candidate.modelId)}，可以进行本机兼容性测试。'
            : '${_externalModelDisplayLabel(candidate.modelId, candidate.path)} 已通过兼容性测试。';
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _discoveringAsrModels = false);
    }
  }

  Future<void> _openExternalModelPath(String path) async {
    final target = path.trim();
    if (target.isEmpty) return;
    try {
      await _pathOpener.openDirectory(target);
    } on Object catch (error) {
      if (mounted) setState(() => _error = _friendlySettingsError(error));
    }
  }

  Future<void> _renameExternalAsrModel(
    AsrRegisteredResourceOption registration,
  ) async {
    if (_renamingAsrModel || registration.id.isEmpty) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _AsrModelRenameDialog(
        initialValue: registration.userLabel,
        automaticLabel: registration.displayName.trim().isNotEmpty
            ? registration.displayName.trim()
            : _asrExternalModelLabel(registration.resourceId),
      ),
    );
    if (!mounted || selected == null) return;
    setState(() {
      _renamingAsrModel = true;
      _message = null;
      _error = null;
    });
    try {
      await _client.setExternalAsrModelLabel(
        registrationId: registration.id,
        userLabel: selected.trim(),
      );
      await _loadConfig(preserveAsrDraft: true, silent: true);
      if (!mounted) return;
      setState(() {
        _message = selected.trim().isEmpty ? '已恢复自动模型名称。' : '模型显示名称已保存。';
      });
      await widget.bridge.refreshServiceSnapshot();
    } on Object catch (error) {
      if (mounted) setState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) setState(() => _renamingAsrModel = false);
    }
  }

  Future<AsrModelCandidate?> _chooseExternalModelCandidate(
    List<AsrModelCandidate> candidates,
  ) {
    final height = (candidates.length * 74.0).clamp(140.0, 340.0);
    return showDialog<AsrModelCandidate>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('找到 ${candidates.length} 个模型'),
        content: SizedBox(
          width: 520,
          height: height,
          child: ListView.separated(
            itemCount: candidates.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final candidate = candidates[index];
              final location = candidate.relativePath.isEmpty
                  ? candidate.path
                  : candidate.relativePath == '.'
                  ? candidate.folderName
                  : candidate.relativePath;
              return ListTile(
                key: ValueKey('asr-model-candidate-${candidate.path}'),
                contentPadding: const EdgeInsets.symmetric(horizontal: T.s4),
                title: Text(_asrExternalModelLabel(candidate.modelId)),
                subtitle: Text(
                  '$location · ${_formatBytes(candidate.modelBytes)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).pop(candidate),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _probeExternalAsrModel() async {
    final targetProvider = _asrProviderNameForSelection(_selectedAsrProvider);
    final targetPath = _externalModelPath.text.trim();
    final targetDevice = _device.text;
    final activeExecution = _snapshot?.asrActiveExecution;
    final acceleratorRoot =
        (targetDevice == 'cuda' ||
            (targetDevice == 'auto' &&
                activeExecution?.resolvedDevice == 'cuda'))
        ? activeExecution?.acceleratorRoot
        : null;
    if (targetPath.isEmpty) return;
    setState(() {
      _probingAsrModel = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await _client.probeExternalAsrModel(
        modelPath: targetPath,
        device: targetDevice,
        computeType: _localComputeType,
        acceleratorRoot: acceleratorRoot?.isEmpty == true
            ? null
            : acceleratorRoot,
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
            _externalDraftModelId = modelId;
            _externalDraftRegistrationId = '${model['id'] ?? ''}'.trim();
            _model.text = modelId;
            _asrModelSource = 'external';
            _asrDraftDirty = true;
          });
          final verifiedDraft = _asrDraft(targetProvider);
          await _saveAsrProvider(
            providerNameOverride: targetProvider,
            draftOverride: verifiedDraft,
            successMessage: '${_asrExternalModelLabel(modelId)} 验证通过，已设为默认。',
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

  Future<void> _openAsrAgentHandoff(String scope, String label) async {
    if (_copyingAgentHandoff) return;
    setState(() {
      _copyingAgentHandoff = true;
      _error = null;
      _message = null;
    });
    try {
      final results = await Future.wait<Object>([
        _client.agentEntry(),
        _client.agentClient(),
      ]);
      final entry = results[0] as AgentEntryInfo;
      final agentClient = results[1] as AgentClientInfo;
      final scopedText = entry.asrEnvironmentHandoffs[scope]?.trim() ?? '';
      final text = scopedText.isNotEmpty
          ? scopedText
          : entry.asrEnvironmentHandoffText.trim();
      if (text.isEmpty) {
        throw StateError('ASR Agent handoff is empty');
      }
      if (!mounted) return;
      setState(() => _copyingAgentHandoff = false);
      final action = await showDialog<_AgentHandoffAction>(
        context: context,
        builder: (dialogContext) => _AgentHandoffDialog(
          scope: scope,
          label: label,
          client: agentClient,
        ),
      );
      if (action == null || !mounted) return;
      setState(() => _copyingAgentHandoff = true);
      switch (action) {
        case _AgentHandoffAction.copy:
          await Clipboard.setData(ClipboardData(text: text));
          if (mounted) {
            setState(() => _message = '“$label”交接已复制；返回本窗口时会自动刷新。');
          }
          break;
        case _AgentHandoffAction.send:
          final result = await _client.launchAsrAgentHandoff(scope);
          if (!result.launched) {
            throw StateError('Codex CLI did not launch');
          }
          if (mounted) {
            setState(() => _message = '“$label”已发送给 Codex；返回本窗口时会自动刷新。');
          }
          break;
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyAgentEntryError(error));
    } finally {
      if (mounted) setState(() => _copyingAgentHandoff = false);
    }
  }

  Future<void> _testAsrProvider() async {
    setState(() {
      _testingAsr = true;
      _error = null;
      _message = null;
    });
    try {
      final providerDraft = _asrDraft(_selectedAsrProvider);
      final result = await _client.asrProviderTest(
        providerDraft: providerDraft,
        apiKey: _keyTextOrNull(),
      );
      if (!mounted) return;
      setState(() {
        if (result['ok'] == true) {
          _message = providerDraft['protocol'] == 'openrouter_stt'
              ? '连接和最小请求通过；真实语音时间轴仍需在任务中验证。'
              : '连接和最小识别测试通过。';
        } else {
          final message = '${result['message'] ?? ''}'.trim();
          _error = message.isEmpty
              ? _friendlyAsrConnectionTestError(result['code'])
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

  void _maybeLoadOpenRouterUsage({bool force = false}) {
    if (!_isAsr || widget.smoke != null) return;
    final draft = _asrDraft(_selectedAsrProvider);
    if ('${draft['protocol'] ?? ''}' != 'openrouter_stt') return;
    final providerName = _asrProviderNameForSelection(_selectedAsrProvider);
    final hasCredential =
        _keyTextOrNull() != null || _selectedAsrOption()?.hasKey == true;
    if (!hasCredential) return;
    if (!force && _openRouterUsageAutoLoadedFor == providerName) return;
    _openRouterUsageAutoLoadedFor = providerName;
    unawaited(_checkOpenRouterUsage());
  }

  Future<void> _checkOpenRouterUsage() async {
    final requestRevision = ++_openRouterUsageRequestRevision;
    final selectedProvider = _selectedAsrProvider;
    final providerDraft = _asrDraft(selectedProvider);
    _openRouterUsageAutoLoadedFor = _asrProviderNameForSelection(
      selectedProvider,
    );
    setState(() {
      _checkingOpenRouterUsage = true;
      _openRouterUsageError = null;
    });
    try {
      final result = await _client.asrProviderUsage(
        providerDraft: providerDraft,
        apiKey: _keyTextOrNull(),
      );
      if (!mounted ||
          requestRevision != _openRouterUsageRequestRevision ||
          selectedProvider != _selectedAsrProvider) {
        return;
      }
      setState(() {
        _openRouterUsageMessage = _openRouterKeyUsageMessage(result);
        _openRouterUsageError = null;
      });
    } on Object catch (error) {
      if (!mounted ||
          requestRevision != _openRouterUsageRequestRevision ||
          selectedProvider != _selectedAsrProvider) {
        return;
      }
      setState(() => _openRouterUsageError = _friendlySettingsError(error));
    } finally {
      if (mounted && requestRevision == _openRouterUsageRequestRevision) {
        setState(() => _checkingOpenRouterUsage = false);
      }
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
    final editedModel = useEditedFields
        ? kind == 'local_worker'
              ? _asrModelSource == 'external'
                    ? _externalDraftModelId.trim()
                    : _managedModelId.trim()
              : _model.text.trim()
        : '';
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
              : _defaultAsrEndpoint(protocol));
    final auth = hasExisting
        ? _stringMap(existing.raw['auth'])
        : const <String, Object?>{};
    final local = hasExisting
        ? Map<String, Object?>.from(_stringMap(existing.raw['local']))
        : <String, Object?>{};
    local['model_size'] = model;
    if (kind == 'local_worker' && useEditedFields) {
      local['model_source'] = _asrModelSource;
      local['managed_model_size'] = _managedModelId;
      local['external_model_id'] = _externalDraftModelId;
      local['external_model_path'] = _externalModelPath.text.trim();
      local['model_path'] = _asrModelSource == 'external'
          ? _externalModelPath.text.trim()
          : '';
    }
    if (useEditedFields) {
      local['device'] = _device.text.trim().isEmpty
          ? 'auto'
          : _device.text.trim();
      local['compute_type'] = _localComputeType.isEmpty
          ? 'auto'
          : _localComputeType;
    } else {
      local.putIfAbsent('device', () => 'auto');
      local.putIfAbsent('compute_type', () => 'auto');
    }
    final runtime = hasExisting
        ? Map<String, Object?>.from(_stringMap(existing.raw['runtime']))
        : <String, Object?>{};
    if (kind == 'local_worker' && useEditedFields) {
      runtime['source'] = 'managed';
      runtime['id'] = 'managed:faster-whisper';
    }
    return {
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
                'env_key': protocol == 'openrouter_stt'
                    ? 'OPENROUTER_API_KEY'
                    : 'OPENAI_API_KEY',
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
    if (provider.protocol == 'openrouter_stt') return 'openrouter_asr';
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
    if (_asrPresetIdForName(providerName) == 'openrouter_asr') {
      return 'openrouter_stt';
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
    if (providerName == 'openrouter_asr' || lower.contains('openrouter')) {
      return 'openrouter_asr';
    }
    return 'openai_whisper';
  }

  String _defaultAsrModel(String kind, String protocol) {
    if (kind == 'local_worker' || kind == 'local_inprocess') {
      return 'small';
    }
    if (protocol == 'funasr_openai') return 'sensevoice';
    if (protocol == 'openrouter_stt') return 'openai/whisper-large-v3';
    return 'whisper-1';
  }

  String _defaultAsrBaseUrl(String kind, String protocol) {
    if (kind == 'local_server' || protocol == 'funasr_openai') {
      return 'http://127.0.0.1:8899';
    }
    if (protocol == 'openrouter_stt') {
      return 'https://openrouter.ai/api/v1';
    }
    return 'https://api.openai.com/v1';
  }

  String _defaultAsrEndpoint(String protocol) {
    return protocol == 'openrouter_stt'
        ? '/audio/transcriptions'
        : '/v1/audio/transcriptions';
  }

  String _asrLabelForDraft(Map<String, Object?> draft) {
    return switch (draft['kind']) {
      'local_worker' || 'local_inprocess' => '本机 Whisper',
      'local_server' =>
        draft['protocol'] == 'funasr_openai' ? 'FunASR' : '本地服务',
      'remote' =>
        draft['protocol'] == 'openrouter_stt'
            ? 'OpenRouter · ${_openRouterAsrModelLabel((draft['model'] ?? '').toString())}'
            : 'OpenAI Whisper',
      _ => '${draft['name']}',
    };
  }

  Map<String, String> _openRouterModelItems(AsrProviderOption? provider) {
    final result = <String, String>{};
    for (final raw in _objectList(provider?.raw['available_models'])) {
      final row = _stringMap(raw);
      final model = '${row['model'] ?? ''}'.trim();
      if (model.isEmpty) continue;
      final display = '${row['display_name'] ?? ''}'.trim();
      final status = '${row['status'] ?? ''}'.trim();
      final suffix = status == 'experimental' ? ' · 实验性' : '';
      result[model] = '${display.isEmpty ? model : display}$suffix';
    }
    if (result.isNotEmpty) return result;
    return const {
      'openai/whisper-large-v3': 'Whisper Large V3',
      'x-ai/grok-stt-1.0': 'Grok STT 1.0 · 实验性',
    };
  }

  String _openRouterModelHint(
    AsrProviderOption? provider,
    String selectedModel,
  ) {
    for (final raw in _objectList(provider?.raw['available_models'])) {
      final row = _stringMap(raw);
      if ('${row['model'] ?? ''}' != selectedModel) continue;
      final notes = '${row['notes_zh'] ?? ''}'.trim();
      final status = '${row['status'] ?? ''}'.trim();
      final prefix = status == 'experimental' ? '实验性模型：' : '时间轴候选：';
      return '$prefix$notes';
    }
    return selectedModel == 'x-ai/grok-stt-1.0'
        ? '实验性模型：使用词级时间戳生成字幕段，缺失时间戳时会停止任务。'
        : '时间轴候选：要求服务返回分段时间戳，不会静默降级为整段字幕。';
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

class _AsrFeedbackBar extends StatelessWidget {
  const _AsrFeedbackBar({
    required this.busy,
    required this.busyText,
    required this.error,
    required this.message,
  });

  final bool busy;
  final String busyText;
  final String? error;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final text = busy
        ? busyText
        : error?.trim().isNotEmpty == true
        ? error!.trim()
        : message?.trim() ?? '';
    final color = !busy && error?.trim().isNotEmpty == true
        ? T.danger
        : T.accentStrong;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(T.rSm),
      ),
      child: Row(
        children: [
          if (busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            )
          else
            Icon(
              error?.trim().isNotEmpty == true
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              size: 16,
              color: color,
            ),
          const SizedBox(width: T.s8),
          Expanded(
            child: Text(
              text,
              style: T.tCaption.copyWith(color: color),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _SegmentedEngines extends StatelessWidget {
  const _SegmentedEngines({
    required this.selected,
    required this.active,
    required this.activeReady,
    required this.onPick,
  });

  final String selected;
  final String active;
  final bool activeReady;
  final ValueChanged<String>? onPick;

  @override
  Widget build(BuildContext context) {
    const items = [
      ('faster_whisper_large_v3', '本机 Whisper', '本机运行'),
      ('openai_whisper', 'OpenAI Whisper', '云端识别'),
      ('openrouter_asr', 'OpenRouter', 'Whisper / Grok'),
      ('funasr_sensevoice_local', 'FunASR', '本地服务'),
    ];
    return Row(
      children: [
        for (var index = 0; index < items.length; index++) ...[
          if (index > 0) const SizedBox(width: T.s8),
          Expanded(
            child: SegmentButton(
              width: double.infinity,
              label: items[index].$2,
              detail: items[index].$3,
              selected: selected == items[index].$1,
              statusLabel: active == items[index].$1
                  ? activeReady
                        ? '当前默认'
                        : '默认未配置'
                  : null,
              statusColor: activeReady ? T.ok : T.warn,
              onTap: onPick == null ? null : () => onPick!(items[index].$1),
            ),
          ),
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
  final ValueChanged<String>? onChanged;

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
      onChanged: onChanged == null
          ? null
          : (next) {
              if (next != null) onChanged!(next);
            },
    );
  }
}

class _AsrOverview extends StatelessWidget {
  const _AsrOverview({
    required this.label,
    required this.readiness,
    required this.draftDirty,
  });

  final String label;
  final AsrReadiness? readiness;
  final bool draftDirty;

  @override
  Widget build(BuildContext context) {
    final state = readiness?.state ?? 'unavailable';
    final color = draftDirty ? T.accentStrong : _asrStateColor(state);
    final status = draftDirty ? '尚未保存' : _asrStatusChipLabel(readiness);
    final hint = draftDirty
        ? '保存后会重新检查这套本地识别方案。'
        : _asrReadinessHint(readiness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rMd),
        border: Border.all(color: T.line),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 40,
            height: 40,
            child: CustomPaint(painter: _WhisperBuddyPainter()),
          ),
          const SizedBox(width: T.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: T.tBody.copyWith(fontWeight: T.wBold)),
                const SizedBox(height: 2),
                Text(hint, style: T.tCaption, maxLines: 1),
              ],
            ),
          ),
          const SizedBox(width: T.s12),
          _AsrStatusChip(label: status, color: color),
        ],
      ),
    );
  }
}

class _AsrExecutionSummary extends StatelessWidget {
  const _AsrExecutionSummary({required this.provider});

  final AsrProviderOption provider;

  @override
  Widget build(BuildContext context) {
    final policy = _stringMap(provider.policyResolution['policy']);
    final chunking = _stringMap(policy['chunking']);
    final execution = _stringMap(policy['execution']);
    final timeline = _stringMap(provider.capabilities['timeline']);
    final granularities = (timeline['granularities'] as List? ?? const [])
        .map((item) => '$item')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final parts = <String>[
      if (chunking['window_target_seconds'] case final num seconds)
        '分窗 ${_compactNumber(seconds)} 秒',
      if (chunking['overlap_seconds'] case final num seconds)
        '重叠 ${_compactNumber(seconds)} 秒',
      if (execution['target_concurrency'] case final num concurrency)
        '并发目标 ${concurrency.toInt()} 路',
      if (granularities.contains('word'))
        '逐词时间戳'
      else if (granularities.contains('segment'))
        '分段时间戳',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        const Icon(Icons.tune_rounded, size: 16, color: T.muted),
        const SizedBox(width: T.s8),
        Expanded(
          child: Text(
            '自动运行策略 · ${parts.join(' · ')}',
            style: T.tCaption.copyWith(color: T.muted),
          ),
        ),
      ],
    );
  }

  static String _compactNumber(num value) {
    final number = value.toDouble();
    return number == number.roundToDouble()
        ? number.toInt().toString()
        : number.toStringAsFixed(1);
  }
}

class _LocalWhisperCurrent {
  const _LocalWhisperCurrent({
    required this.configured,
    required this.isDefault,
    required this.ready,
    required this.modelId,
    required this.modelSource,
    required this.modelPath,
    required this.executionDetail,
  });

  final bool configured;
  final bool isDefault;
  final bool ready;
  final String modelId;
  final String modelSource;
  final String modelPath;
  final String executionDetail;
}

class _AsrChange {
  const _AsrChange({
    required this.label,
    required this.before,
    required this.after,
  });

  final String label;
  final String before;
  final String after;
}

class _AsrApplySummary extends StatelessWidget {
  const _AsrApplySummary({
    required this.changes,
    required this.downloadItems,
    required this.requiredDownloadBytes,
    required this.storage,
  });

  final List<_AsrChange> changes;
  final List<String> downloadItems;
  final int requiredDownloadBytes;
  final AsrStorageOption storage;

  @override
  Widget build(BuildContext context) {
    final storageAvailable =
        storage.configError.isEmpty && storage.diskError.isEmpty;
    final hasSpace = storage.hasSpaceFor(requiredDownloadBytes);
    final requiredBytes = storage.requiredBytesFor(requiredDownloadBytes);
    final storageHint = !storageAvailable
        ? '识别资源位置不可用，请检查目标磁盘。'
        : !hasSpace
        ? '至少需要 ${_formatBytes(requiredBytes)} 可用空间。'
        : '';
    return Container(
      key: const ValueKey('asr-apply-summary'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.lilacSoft.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (changes.isNotEmpty) ...[
            Row(
              children: [
                const Icon(Icons.tune_rounded, size: 17, color: T.muted),
                const SizedBox(width: T.s8),
                Text(
                  '即将应用',
                  style: T.tCaption.copyWith(color: T.ink, fontWeight: T.wBold),
                ),
              ],
            ),
            for (final change in changes) ...[
              const SizedBox(height: T.s4),
              Padding(
                padding: const EdgeInsets.only(left: 25),
                child: Text(
                  '${change.label}：${change.before}  →  ${change.after}',
                  style: T.tCaption.copyWith(color: T.ink),
                ),
              ),
            ],
          ],
          if (downloadItems.isNotEmpty) ...[
            if (changes.isNotEmpty) const SizedBox(height: T.s8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.download_rounded, size: 17, color: T.warn),
                const SizedBox(width: T.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '需要下载 ${_formatBytes(requiredDownloadBytes)}',
                        style: T.tCaption.copyWith(
                          color: T.ink,
                          fontWeight: T.wBold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(downloadItems.join(' · '), style: T.tCaption),
                      const SizedBox(height: T.s4),
                      Row(
                        children: [
                          const Icon(
                            Icons.folder_outlined,
                            size: 15,
                            color: T.muted,
                          ),
                          const SizedBox(width: T.s4),
                          Expanded(
                            child: Tooltip(
                              message: storage.root,
                              child: Text(
                                storage.root.isEmpty
                                    ? '保存位置尚未就绪'
                                    : '保存到 ${storage.root}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: T.tCaption,
                              ),
                            ),
                          ),
                          if (storage.spaceKnown) ...[
                            const SizedBox(width: T.s8),
                            Text(
                              '可用 ${_formatBytes(storage.freeBytes)}',
                              style: T.tCaption,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
          if (storageHint.isNotEmpty) ...[
            const SizedBox(height: T.s8),
            Text(storageHint, style: T.tCaption.copyWith(color: T.danger)),
          ],
        ],
      ),
    );
  }
}

class _AsrExternalModelChoice {
  const _AsrExternalModelChoice.registered(this.externalRegistrationId)
    : browseExternal = false;

  const _AsrExternalModelChoice.browse()
    : externalRegistrationId = '',
      browseExternal = true;

  final String externalRegistrationId;
  final bool browseExternal;
}

class _AsrExternalModelDialog extends StatefulWidget {
  const _AsrExternalModelDialog({
    required this.registeredModels,
    required this.initialExternalRegistrationId,
  });

  final List<AsrRegisteredResourceOption> registeredModels;
  final String initialExternalRegistrationId;

  @override
  State<_AsrExternalModelDialog> createState() =>
      _AsrExternalModelDialogState();
}

class _AsrExternalModelDialogState extends State<_AsrExternalModelDialog> {
  late String _externalRegistrationId;

  @override
  void initState() {
    super.initState();
    _externalRegistrationId =
        widget.registeredModels.any(
          (item) => item.id == widget.initialExternalRegistrationId,
        )
        ? widget.initialExternalRegistrationId
        : widget.registeredModels.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final registeredLabels = {
      for (final item in widget.registeredModels)
        item.id: item.effectiveLabel.trim().isEmpty
            ? item.resourceId
            : item.effectiveLabel,
    };
    return AlertDialog(
      title: const Text('使用本地 Whisper 模型'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('选择已验证的模型，或登记其他模型文件夹。'),
            const SizedBox(height: T.s12),
            _AsrSelect(
              label: '已登记模型',
              value: _externalRegistrationId,
              items: registeredLabels,
              onChanged: (value) =>
                  setState(() => _externalRegistrationId = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('asr-external-choice-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton.icon(
          key: const ValueKey('asr-external-choice-browse'),
          onPressed: () =>
              Navigator.of(context).pop(const _AsrExternalModelChoice.browse()),
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: const Text('选择其他文件夹'),
        ),
        TextButton(
          key: const ValueKey('asr-external-choice-confirm'),
          onPressed: () => Navigator.of(
            context,
          ).pop(_AsrExternalModelChoice.registered(_externalRegistrationId)),
          child: const Text('使用此模型'),
        ),
      ],
    );
  }
}

class _AsrStatusChip extends StatelessWidget {
  const _AsrStatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: T.s4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: color.withValues(alpha: 0.52)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: T.s4),
          Text(
            label,
            style: T.tCaption.copyWith(color: color, fontWeight: T.wBold),
          ),
        ],
      ),
    );
  }
}

class _AsrModelRenameDialog extends StatefulWidget {
  const _AsrModelRenameDialog({
    required this.initialValue,
    required this.automaticLabel,
  });

  final String initialValue;
  final String automaticLabel;

  @override
  State<_AsrModelRenameDialog> createState() => _AsrModelRenameDialogState();
}

class _AsrModelRenameDialogState extends State<_AsrModelRenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue.trim(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改模型显示名称'),
      content: SizedBox(
        width: 360,
        child: TextField(
          key: const ValueKey('asr-model-user-label-input'),
          controller: _controller,
          autofocus: true,
          maxLength: 80,
          decoration: InputDecoration(
            labelText: '显示名称',
            hintText: widget.automaticLabel,
            helperText: '留空使用自动名称，不会改动模型文件夹。',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          key: const ValueKey('asr-model-user-label-save'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _AsrManagedModelChoice extends StatelessWidget {
  const _AsrManagedModelChoice({
    super.key,
    required this.label,
    required this.detail,
    required this.selected,
    required this.current,
    required this.onTap,
  });

  final String label;
  final String detail;
  final bool selected;
  final bool current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? T.accentSoft.withValues(alpha: 0.52) : T.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rSm),
          side: BorderSide(color: selected ? T.accent : T.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(T.rSm),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(T.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: T.tBody.copyWith(fontWeight: T.wBold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: selected ? T.accentStrong : T.muted,
                    ),
                  ],
                ),
                const SizedBox(height: T.s4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        detail,
                        style: T.tCaption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (current) ...[
                      const SizedBox(width: T.s4),
                      const _AsrInlineTag(label: '当前', color: T.ok),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AsrExternalModelChoiceRow extends StatelessWidget {
  const _AsrExternalModelChoiceRow({
    super.key,
    required this.title,
    required this.detail,
    required this.selected,
    required this.current,
    required this.onTap,
    this.onOpen,
    this.onRename,
  });

  final String title;
  final String detail;
  final bool selected;
  final bool current;
  final VoidCallback? onTap;
  final VoidCallback? onOpen;
  final VoidCallback? onRename;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? T.accentSoft.withValues(alpha: 0.44) : T.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rSm),
          side: BorderSide(color: selected ? T.accent : T.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(T.rSm),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: T.s12,
              vertical: T.s8,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.folder_open_rounded,
                  size: 20,
                  color: selected ? T.accentStrong : T.muted,
                ),
                const SizedBox(width: T.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: T.tBody.copyWith(fontWeight: T.wBold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: T.tCaption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (current) ...[
                  const SizedBox(width: T.s8),
                  const _AsrInlineTag(label: '当前', color: T.ok),
                ],
                if (onOpen != null)
                  IconButton(
                    key: const ValueKey('asr-model-open-location'),
                    tooltip: '打开模型文件夹',
                    onPressed: onOpen,
                    icon: const Icon(Icons.folder_outlined, size: 18),
                  ),
                if (onRename != null)
                  IconButton(
                    key: const ValueKey('asr-model-rename'),
                    tooltip: '修改显示名称',
                    onPressed: onRename,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                  ),
                const SizedBox(width: T.s4),
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.chevron_right_rounded,
                  size: 19,
                  color: selected ? T.accentStrong : T.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AsrInlineTag extends StatelessWidget {
  const _AsrInlineTag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(T.rSm),
      ),
      child: Text(
        label,
        style: T.tCaption.copyWith(color: color, fontWeight: T.wBold),
      ),
    );
  }
}

class _AsrSetupProgress extends StatelessWidget {
  const _AsrSetupProgress({required this.operation, this.onCancel});

  final AsrOperationStatus operation;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final progress = operation.progress;
    final title = _asrSetupTaskTitle(operation);
    final color = operation.state == 'failed'
        ? T.danger
        : operation.state == 'cancelled'
        ? T.warn
        : operation.state == 'completed'
        ? T.ok
        : T.accentStrong;
    return Semantics(
      label: title,
      value: progress == null ? '' : '${(progress * 100).round()}%',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(T.s16),
        decoration: BoxDecoration(
          color: T.surface,
          borderRadius: BorderRadius.circular(T.rMd),
          border: Border.all(color: color.withValues(alpha: 0.52)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.downloading_rounded, color: color, size: 22),
                const SizedBox(width: T.s8),
                Expanded(
                  child: Text(
                    title,
                    style: T.tSection,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onCancel != null)
                  ActionButton(
                    label: operation.state == 'cancelling' ? '正在取消…' : '取消下载',
                    onTap: operation.state == 'cancelling' ? null : onCancel,
                  ),
              ],
            ),
            if (operation.kind == 'setup') ...[
              const SizedBox(height: T.s16),
              _AsrSetupPhaseStrip(operation: operation),
            ],
            const SizedBox(height: T.s16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 8,
                value: progress,
                backgroundColor: T.line,
                color: color,
              ),
            ),
            const SizedBox(height: T.s8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _asrSetupPhaseLabel(operation),
                    style: T.tCaption,
                  ),
                ),
                if (operation.bytesTotal > 0)
                  Text(
                    '${_formatBytes(operation.bytesDone)} / ${_formatBytes(operation.bytesTotal)}',
                    style: T.tCaption,
                  ),
              ],
            ),
            if (operation.active) ...[
              const SizedBox(height: T.s12),
              Text('关闭此窗口后任务会继续，可从系统托盘重新打开。', style: T.tCaption),
            ] else if (operation.state == 'cancelled') ...[
              const SizedBox(height: T.s12),
              Text('下载已取消；已校验的部分会保留，继续下载时自动复用。', style: T.tBody),
            ] else if (operation.state == 'failed') ...[
              const SizedBox(height: T.s12),
              Text(
                _asrOperationFailureMessage(operation),
                style: T.tBody.copyWith(color: T.danger),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AsrBackgroundOperation extends StatelessWidget {
  const _AsrBackgroundOperation({
    required this.operation,
    required this.onCancel,
  });

  final AsrOperationStatus operation;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final progress = operation.progress;
    return Container(
      key: const ValueKey('asr-background-operation'),
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.accentSoft.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(T.rMd),
        border: Border.all(color: T.accent.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.downloading_rounded,
            size: 18,
            color: T.accentStrong,
          ),
          const SizedBox(width: T.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_asrSetupTaskTitle(operation)}，正在后台继续',
                  style: T.tCaption.copyWith(fontWeight: T.wBold),
                ),
                const SizedBox(height: T.s4),
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  color: T.accent,
                  backgroundColor: T.line,
                ),
              ],
            ),
          ),
          const SizedBox(width: T.s12),
          TextButton(
            onPressed: operation.state == 'cancelling' ? null : onCancel,
            child: Text(operation.state == 'cancelling' ? '正在取消' : '取消'),
          ),
        ],
      ),
    );
  }
}

class _AsrSetupPhaseStrip extends StatelessWidget {
  const _AsrSetupPhaseStrip({required this.operation});

  final AsrOperationStatus operation;

  @override
  Widget build(BuildContext context) {
    const labels = ['识别引擎', '识别模型', '检查可用性'];
    final completed = operation.state == 'completed';
    return Row(
      children: [
        for (var index = 0; index < labels.length; index++) ...[
          Expanded(
            child: _AsrSetupPhase(
              label: labels[index],
              index: index,
              currentIndex: operation.phaseIndex.clamp(0, labels.length - 1),
              completed: completed,
            ),
          ),
          if (index < labels.length - 1)
            Container(
              width: 24,
              height: 1,
              color: index < operation.phaseIndex || completed ? T.ok : T.line,
            ),
        ],
      ],
    );
  }
}

class _AsrSetupPhase extends StatelessWidget {
  const _AsrSetupPhase({
    required this.label,
    required this.index,
    required this.currentIndex,
    required this.completed,
  });

  final String label;
  final int index;
  final int currentIndex;
  final bool completed;

  @override
  Widget build(BuildContext context) {
    final done = completed || index < currentIndex;
    final current = !completed && index == currentIndex;
    final color = done
        ? T.ok
        : current
        ? T.accentStrong
        : T.muted;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done ? color : T.surface,
            border: Border.all(color: color, width: current ? 1.6 : 1),
          ),
          child: done
              ? const Icon(
                  Icons.check_rounded,
                  size: 13,
                  color: Color(0xFFFFFFFF),
                )
              : Text('${index + 1}', style: T.tCaption.copyWith(color: color)),
        ),
        const SizedBox(width: T.s4),
        Flexible(
          child: Text(
            label,
            style: T.tCaption.copyWith(
              color: current || done ? T.ink : T.muted,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

Color _asrStateColor(String state) {
  return switch (state) {
    'ready' => T.ok,
    'checking' => T.accentStrong,
    'needs_action' => T.warn,
    _ => T.danger,
  };
}

String _asrStatusChipLabel(AsrReadiness? readiness) {
  if (readiness?.code == 'credential_missing') return '缺少密钥';
  return switch (readiness?.state) {
    'ready' => '可以开始',
    'checking' => '检查中',
    'needs_action' => '还差一步',
    _ => '暂未准备',
  };
}

String _asrReadinessHint(AsrReadiness? readiness) {
  final value = readiness;
  if (value == null) return '正在读取本机识别状态。';
  if (value.code == 'credential_missing') {
    return '还未配置 API key，添加后才能设为默认并开始识别。';
  }
  return switch (value.state) {
    'ready' => '本地识别方案已准备好，可以开始处理视频。',
    'checking' => '正在检查运行环境和模型。',
    'needs_action' => '还差一步准备，完成后即可开始识别。',
    _ => value.statusLabel.isEmpty ? '当前方案还不能运行。' : value.statusLabel,
  };
}

String _asrOperationLabel(String itemId) {
  return switch (itemId) {
    'managed:faster-whisper' => '本地识别引擎',
    'small' => 'Whisper Small',
    'medium' => 'Whisper Medium',
    'large-v3' => 'Whisper Large v3',
    'nvidia-cuda12' => 'NVIDIA 加速环境',
    _ => itemId,
  };
}

String _asrSetupTaskTitle(AsrOperationStatus operation) {
  return switch (operation.state) {
    'queued' => '本机识别设置即将开始',
    'cancelling' => '正在取消本机识别设置',
    'completed' =>
      operation.kind == 'setup'
          ? '${_asrOperationLabel(operation.itemId)} 已准备好'
          : '${_asrOperationLabel(operation.itemId)}下载完成',
    'cancelled' => '本机识别下载已取消',
    'failed' => '本机识别设置需要处理',
    _ => switch (operation.phase) {
      'runtime' => '正在下载本地识别引擎',
      'model' => '正在下载 ${_asrOperationLabel(operation.itemId)}',
      'activate' => '正在检查本机识别可用性',
      _ => '正在下载 ${_asrOperationLabel(operation.itemId)}',
    },
  };
}

String _asrSetupPhaseLabel(AsrOperationStatus operation) {
  if (operation.state == 'cancelling') return '等待当前步骤安全停止';
  if (operation.state == 'completed') return '运行组件和模型已校验完成';
  if (operation.state == 'cancelled') return '可继续下载并复用已校验数据';
  if (operation.state == 'failed') return '保留安全断点，修复后可以重试';
  return switch (operation.phase) {
    'runtime' => '第 1 步，共 3 步 · 下载并校验识别引擎',
    'model' => '第 2 步，共 3 步 · 下载并校验识别模型',
    'activate' => '第 3 步，共 3 步 · 检查当前方案可用性',
    _ => '正在准备本机识别环境',
  };
}

String _asrOperationFailureMessage(AsrOperationStatus operation) {
  return switch (operation.errorCode) {
    'insufficient_disk_space' => '磁盘空间不足，请清理空间后重试。',
    'component_unpublished' => '当前版本的识别引擎尚未开放下载。',
    'checksum_mismatch' => '下载文件未通过完整性校验，请重试。',
    'download_failed' || 'download_incomplete' => '下载没有完成，请检查网络设置后重试。',
    'operation_interrupted' => '上次下载意外中断，可以从已保留的安全断点继续。',
    _ => operation.message.trim().isEmpty ? '本机识别设置失败，请重试。' : operation.message,
  };
}

class _WhisperBuddyPainter extends CustomPainter {
  const _WhisperBuddyPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(5, 9, 34, 29),
      const Radius.circular(11),
    );
    final fill = Paint()..color = T.accentSoft;
    final line = Paint()
      ..color = T.accentStrong
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(body, fill);
    canvas.drawRRect(body, line);
    final tail = Path()
      ..moveTo(12, 35)
      ..lineTo(9, 43)
      ..lineTo(19, 37)
      ..close();
    canvas.drawPath(tail, fill);
    canvas.drawPath(tail, line);

    final eye = Paint()..color = T.ink;
    canvas.drawCircle(const Offset(16, 23), 2.1, eye);
    canvas.drawCircle(const Offset(28, 23), 2.1, eye);
    final blush = Paint()..color = T.accent.withValues(alpha: 0.56);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(12.5, 28), width: 6, height: 3),
      blush,
    );
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(31.5, 28), width: 6, height: 3),
      blush,
    );
    final smile = Paint()
      ..color = T.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCenter(center: const Offset(22, 26.5), width: 8, height: 7),
      0.2,
      2.7,
      false,
      smile,
    );
    _drawSparkle(canvas, const Offset(40, 7), 4, T.accentStrong);
  }

  @override
  bool shouldRepaint(covariant _WhisperBuddyPainter oldDelegate) => false;
}

void _drawSparkle(Canvas canvas, Offset center, double radius, Color color) {
  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2
    ..strokeCap = StrokeCap.round;
  canvas.drawLine(
    Offset(center.dx, center.dy - radius),
    Offset(center.dx, center.dy + radius),
    paint,
  );
  canvas.drawLine(
    Offset(center.dx - radius, center.dy),
    Offset(center.dx + radius, center.dy),
    paint,
  );
}

String _asrModelLabel(String modelId) {
  return whisperModelLabel(modelId);
}

String _asrExternalModelLabel(String modelId) {
  if (modelId.startsWith('custom-')) return '自定义 Whisper';
  return _asrModelLabel(modelId);
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '大小未知';
  const gib = 1024 * 1024 * 1024;
  const mib = 1024 * 1024;
  const kib = 1024;
  if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(1)} GB';
  if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(0)} MB';
  if (bytes >= kib) return '${(bytes / kib).toStringAsFixed(0)} KB';
  return '$bytes B';
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

enum _AgentHandoffAction { copy, send }

class _AgentHandoffDialog extends StatelessWidget {
  const _AgentHandoffDialog({
    required this.scope,
    required this.label,
    required this.client,
  });

  final String scope;
  final String label;
  final AgentClientInfo client;

  @override
  Widget build(BuildContext context) {
    final version = client.version.isEmpty ? '' : ' · v${client.version}';
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.terminal_rounded, size: 21, color: T.accentStrong),
          SizedBox(width: T.s8),
          Text('交给 Agent'),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: T.tSection),
            const SizedBox(height: T.s4),
            Text(_agentHandoffScopeSummary(scope), style: T.tCaption),
            const SizedBox(height: T.s16),
            const Divider(height: 1, color: T.line),
            const SizedBox(height: T.s12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  client.ready
                      ? Icons.check_circle_outline_rounded
                      : Icons.error_outline_rounded,
                  size: 18,
                  color: client.ready ? T.ok : T.warn,
                ),
                const SizedBox(width: T.s8),
                Expanded(
                  child: Text(
                    client.ready
                        ? '发送至 Codex CLI$version'
                        : _agentHandoffClientStatus(client),
                    style: T.tBody,
                  ),
                ),
              ],
            ),
            if (client.ready) ...[
              const SizedBox(height: T.s8),
              const Text(
                '发送会创建新的 Codex 会话并使用你的 Codex 账户额度；命令审批沿用 Codex 当前设置。',
                style: T.tCaption,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('agent-handoff-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('agent-handoff-copy'),
          onPressed: () => Navigator.of(context).pop(_AgentHandoffAction.copy),
          icon: const Icon(Icons.content_copy_rounded, size: 17),
          label: const Text('复制交接'),
        ),
        FilledButton.icon(
          key: const ValueKey('agent-handoff-send'),
          onPressed: client.ready
              ? () => Navigator.of(context).pop(_AgentHandoffAction.send)
              : null,
          icon: const Icon(Icons.terminal_rounded, size: 17),
          label: const Text('发送给 Codex'),
        ),
      ],
    );
  }
}

String _agentHandoffScopeSummary(String scope) {
  return switch (scope) {
    'inspect' => '只检查本机环境并给出可执行方案。',
    'prepare_model' => '准备、接入并验证适合当前电脑的 Whisper 模型。',
    'prepare_accelerator' => '准备、接入并验证本机 NVIDIA GPU 加速。',
    'register' => '探测并接入用户已经准备好的模型或 GPU 资源。',
    _ => '把本机语音识别环境准备到可用，并完成严格验证。',
  };
}

String _agentHandoffClientStatus(AgentClientInfo client) {
  return switch (client.statusCode) {
    'codex_cli_not_found' => '未检测到 Codex CLI，仍可复制交接。',
    'codex_cli_terminal_unsupported' => '当前系统暂不支持直接打开 Codex CLI。',
    _ => 'Codex CLI 当前不可用，仍可复制交接。',
  };
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

String _openRouterKeyUsageMessage(Map<String, Object?> usage) {
  final totalSpent = _nonNegativeFiniteNumber(usage['usage_usd']);
  final limit = _nonNegativeFiniteNumber(usage['limit_usd']);
  final remaining = _nonNegativeFiniteNumber(usage['limit_remaining_usd']);
  final reset = '${usage['limit_reset'] ?? ''}';
  final (spent, spentLabel, resetLabel) = switch (reset) {
    'daily' => (
      _nonNegativeFiniteNumber(usage['usage_daily_usd']) ?? totalSpent,
      '今日已用',
      '每日重置',
    ),
    'weekly' => (
      _nonNegativeFiniteNumber(usage['usage_weekly_usd']) ?? totalSpent,
      '本周已用',
      '每周重置',
    ),
    'monthly' => (
      _nonNegativeFiniteNumber(usage['usage_monthly_usd']) ?? totalSpent,
      '本月已用',
      '每月重置',
    ),
    _ => (totalSpent, '该密钥已用', ''),
  };
  final parts = <String>[];
  if (spent != null && limit != null) {
    parts.add(
      '$spentLabel ${_formatUsageUsd(spent)} / ${_formatUsageUsd(limit)}',
    );
  } else if (spent != null) {
    parts.add('$spentLabel ${_formatUsageUsd(spent)}');
  }
  if (remaining != null) parts.add('剩余 ${_formatUsageUsd(remaining)}');
  if (resetLabel.isNotEmpty && limit != null) parts.add(resetLabel);
  return parts.isEmpty
      ? 'OpenRouter 没有返回可展示的密钥用量。'
      : 'OpenRouter 密钥用量：${parts.join(' · ')}';
}

double? _nonNegativeFiniteNumber(Object? value) {
  final parsed = value is num ? value.toDouble() : double.tryParse('$value');
  if (parsed == null || !parsed.isFinite || parsed < 0) return null;
  return parsed;
}

String _formatUsageUsd(double amount) {
  if (amount > 0 && amount < 0.01) return '\$${amount.toStringAsFixed(6)}';
  return '\$${amount.toStringAsFixed(2)}';
}

String _friendlySettingsError(Object error) => friendlySettingsError(error);

String _friendlyAsrConnectionTestError(Object? rawCode) {
  final code = '${rawCode ?? 'connection_failed'}'.trim().toLowerCase();
  return switch (code) {
    'credential_missing' => '连接测试失败：请先填写或保存这个识别服务的 API key。',
    'auth_error' => '连接测试失败：密钥无效或没有调用这个模型的权限。',
    'payment_required' => '连接测试失败：模型服务账户余额不足，请充值或更换可用密钥。',
    'rate_limit' => '连接测试失败：上游触发限流，请稍后再试。',
    'not_found' => '连接测试失败：当前模型不存在或暂时不可用，请确认所选模型。',
    'invalid_request' || 'unprocessable' => '连接测试失败：当前模型不接受这组专项请求参数。',
    'payload_too_large' => '连接测试失败：上传音频超过模型服务限制。',
    'content_policy_violation' => '连接测试失败：模型服务因账户或内容策略拒绝了请求。',
    'request_timeout' ||
    'provider_timeout' ||
    'gateway_timeout' => '连接测试失败：上游响应超时，请稍后再试。',
    'service_unreachable' ||
    'service_unavailable' ||
    'network_error' ||
    'connection_failed' => '连接测试失败：暂时无法连接识别服务，请检查网络和服务地址。',
    'openrouter_asr_timestamps_missing' =>
      'OpenRouter 已返回文本，但没有返回所选模型制作字幕所需的分段或词级时间戳；可重试或切换模型。',
    'unsupported_openrouter_asr_model' =>
      '这个 OpenRouter 模型尚未完成专项适配，请选择列表中的已支持模型。',
    'bad_schema' => '连接测试失败：上游返回了当前版本无法识别的结构。',
    _ => '连接测试失败，请检查识别服务配置。',
  };
}

String _friendlyAgentEntryError(Object error) {
  if (error is RpcRemoteException) {
    if (const {
      'agent_install_not_registered',
      'agent_install_invalid',
      'agent_documents_missing',
      'agent_cli_missing',
    }.contains(error.code)) {
      return '当前运行方式没有可用的安装版 Agent 入口。';
    }
    return switch (error.code) {
      'codex_cli_not_found' => '没有检测到 Codex CLI，请确认安装后可从 PATH 启动。',
      'codex_cli_probe_failed' => 'Codex CLI 已找到，但当前无法运行。',
      'codex_cli_terminal_unsupported' => '当前系统暂不支持从 TransVortex 打开 Codex CLI。',
      'codex_cli_launch_failed' => 'Codex CLI 启动失败，请在终端中检查 codex 是否可用。',
      'agent_handoff_scope_invalid' ||
      'agent_handoff_workflow_invalid' => '这项 Agent 任务当前不可用。',
      _ => _friendlySettingsError(error),
    };
  }
  return _friendlySettingsError(error);
}

String _friendlyAsrModelProbeError(String code, String message) {
  return switch (code) {
    'runtime_missing' => '请先安装 Whisper 运行组件。',
    'runtime_unpublished' => '当前版本的 Whisper 运行组件尚未发布。',
    'model_path_unavailable' => '模型目录不存在或当前无法访问。',
    'model_changed' => '验证期间模型文件发生了变化，请等待文件写入完成后重试。',
    'unsupported_model_directory' =>
      '这个目录不是可加载的 faster-whisper/CTranslate2 模型，请重新查找。',
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
