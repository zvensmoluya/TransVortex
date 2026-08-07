part of '../settings_window.dart';

extension _AsrSettingsSurface on _SettingsWindowState {
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
              _setSettingsState(() {
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
    _setSettingsState(() {
      _editingLocalWhisper = true;
      _message = null;
      _error = null;
    });
  }

  void _closeLocalWhisperEditor() {
    if (_savingAsr || _probingAsrModel || _discoveringAsrModels) return;
    _setSettingsState(() {
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
    _setSettingsState(() {
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
    _setSettingsState(() => _editingLocalWhisper = true);
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
    _setSettingsState(() {
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

  void _pickAsrProvider(String providerName) {
    if (_savingAsr || _probingAsrModel || _testingAsr) return;
    _openRouterUsageRequestRevision += 1;
    _setSettingsState(() {
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
    _setSettingsState(() {
      _asrDraftDirty = true;
      _message = null;
      _error = null;
    });
  }

  void _markOpenRouterKeyChanged() {
    _openRouterUsageRequestRevision += 1;
    _setSettingsState(() {
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
    _setSettingsState(() {
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
    _setSettingsState(() {
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
      _setSettingsState(() {
        _message =
            successMessage ??
            (setAsDefault
                ? '识别默认已保存：${_asrLabelForDraft(draft)}。'
                : '识别配置已保存：${_asrLabelForDraft(draft)}。添加 API key 后可设为默认。');
      });
    } on Object catch (error) {
      if (!mounted) return;
      _setSettingsState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) _setSettingsState(() => _savingAsr = false);
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
    _asrOperationController.dismiss();
    _setSettingsState(() {
      _savingAsr = true;
      _error = null;
      _message = null;
    });
    try {
      final latest = await _client.desktopSnapshot();
      if (!mounted) return;
      _setSettingsState(() => _snapshot = latest);
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
      _asrOperationController.attach(operation);
      await widget.bridge.refreshServiceSnapshot();
      if (!mounted) return;
      _startAsrOperationPolling();
    } on Object catch (error) {
      if (!mounted) return;
      _setSettingsState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) _setSettingsState(() => _savingAsr = false);
    }
  }

  Future<void> _startAsrInstall(String kind, {String? itemId}) async {
    _asrOperationController.dismiss();
    _setSettingsState(() {
      _error = null;
      _message = null;
    });
    try {
      final operation = await _client.asrComponentInstall(kind, itemId: itemId);
      if (!mounted) return;
      _asrOperationController.attach(operation);
      await widget.bridge.refreshServiceSnapshot();
      if (!mounted) return;
      _startAsrOperationPolling();
    } on Object catch (error) {
      if (!mounted) return;
      _setSettingsState(() => _error = _friendlySettingsError(error));
    }
  }

  void _startAsrOperationPolling() {
    _asrOperationController.startPolling();
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

  Future<void> _cancelAsrOperation() async {
    final operationId = _activeAsrOperation?.id;
    if (operationId == null || operationId.isEmpty) return;
    try {
      await _asrOperationController.cancel();
      if (!mounted) return;
      await widget.bridge.refreshServiceSnapshot();
    } on Object catch (error) {
      if (!mounted) return;
      _setSettingsState(() => _error = _friendlySettingsError(error));
    }
  }

  Future<void> _retryAsrOperation() async {
    final operation = _activeAsrOperation;
    if (operation == null || operation.active) return;
    _asrOperationController.dismiss();
    if (operation.kind == 'setup') {
      _managedModelId = operation.itemId;
      _model.text = operation.itemId;
      await _startManagedAsrSetup();
      return;
    }
    await _startAsrInstall(operation.kind, itemId: operation.itemId);
  }

  void _dismissAsrOperation() {
    _asrOperationController.dismiss();
    _setSettingsState(() {
      _error = null;
      _message = null;
    });
  }

  Future<void> _pickExternalModelPath() async {
    if (_probingAsrModel || _savingAsr || _discoveringAsrModels) return;
    final path = await _directoryPicker('选择模型文件夹或它的上层文件夹');
    if (path == null || path.trim().isEmpty || !mounted) return;
    _setSettingsState(() {
      _discoveringAsrModels = true;
      _message = null;
      _error = null;
    });
    try {
      final discovery = await _client.discoverExternalAsrModels(path.trim());
      if (!mounted) return;
      if (!discovery.ok) {
        _setSettingsState(() {
          _error = discovery.message.isEmpty
              ? '无法读取所选位置，请重新选择。'
              : discovery.message;
        });
        return;
      }
      if (discovery.candidates.isEmpty) {
        _setSettingsState(() {
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
      _setSettingsState(() {
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
      _setSettingsState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) _setSettingsState(() => _discoveringAsrModels = false);
    }
  }

  Future<void> _openExternalModelPath(String path) async {
    final target = path.trim();
    if (target.isEmpty) return;
    try {
      await _pathOpener.openDirectory(target);
    } on Object catch (error) {
      if (mounted) {
        _setSettingsState(() => _error = _friendlySettingsError(error));
      }
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
    _setSettingsState(() {
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
      _setSettingsState(() {
        _message = selected.trim().isEmpty ? '已恢复自动模型名称。' : '模型显示名称已保存。';
      });
      await widget.bridge.refreshServiceSnapshot();
    } on Object catch (error) {
      if (mounted) {
        _setSettingsState(() => _error = _friendlySettingsError(error));
      }
    } finally {
      if (mounted) _setSettingsState(() => _renamingAsrModel = false);
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
    _setSettingsState(() {
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
          _setSettingsState(() => _error = '无法识别这个模型目录。');
        } else {
          _setSettingsState(() {
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
        _setSettingsState(() {
          _error = _friendlyAsrModelProbeError(code, message);
        });
      }
    } on Object catch (error) {
      if (!mounted) return;
      _setSettingsState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) _setSettingsState(() => _probingAsrModel = false);
    }
  }

  Future<void> _openAsrAgentHandoff(String scope, String label) async {
    if (_copyingAgentHandoff) return;
    _setSettingsState(() {
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
      _setSettingsState(() => _copyingAgentHandoff = false);
      final action = await showDialog<_AgentHandoffAction>(
        context: context,
        builder: (dialogContext) => _AgentHandoffDialog(
          scope: scope,
          label: label,
          client: agentClient,
        ),
      );
      if (action == null || !mounted) return;
      _setSettingsState(() => _copyingAgentHandoff = true);
      switch (action) {
        case _AgentHandoffAction.copy:
          await Clipboard.setData(ClipboardData(text: text));
          if (mounted) {
            _setSettingsState(() => _message = '“$label”交接已复制；返回本窗口时会自动刷新。');
          }
          break;
        case _AgentHandoffAction.send:
          final result = await _client.launchAsrAgentHandoff(scope);
          if (!result.launched) {
            throw StateError('Codex CLI did not launch');
          }
          if (mounted) {
            _setSettingsState(
              () => _message = '“$label”已发送给 Codex；返回本窗口时会自动刷新。',
            );
          }
          break;
      }
    } on Object catch (error) {
      if (!mounted) return;
      _setSettingsState(() => _error = _friendlyAgentEntryError(error));
    } finally {
      if (mounted) _setSettingsState(() => _copyingAgentHandoff = false);
    }
  }

  Future<void> _testAsrProvider() async {
    _setSettingsState(() {
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
      _setSettingsState(() {
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
      _setSettingsState(() => _error = _friendlySettingsError(error));
    } finally {
      if (mounted) _setSettingsState(() => _testingAsr = false);
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
    _setSettingsState(() {
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
      _setSettingsState(() {
        _openRouterUsageMessage = _openRouterKeyUsageMessage(result);
        _openRouterUsageError = null;
      });
    } on Object catch (error) {
      if (!mounted ||
          requestRevision != _openRouterUsageRequestRevision ||
          selectedProvider != _selectedAsrProvider) {
        return;
      }
      _setSettingsState(
        () => _openRouterUsageError = _friendlySettingsError(error),
      );
    } finally {
      if (mounted && requestRevision == _openRouterUsageRequestRevision) {
        _setSettingsState(() => _checkingOpenRouterUsage = false);
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
}
