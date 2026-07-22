import 'dart:async';

import 'package:flutter/material.dart';

import '../model/translation_settings_controller.dart';
import '../services/app_service_client.dart';
import '../theme/tokens.dart';
import 'network_settings_form.dart';
import 'reasoning_effort_picker.dart';
import 'settings_common.dart';

const _customCapabilityValue = '__custom__';

class _CapacityChoice {
  const _CapacityChoice(this.value, this.label);

  final String value;
  final String label;
}

const _batchLineChoices = <_CapacityChoice>[
  _CapacityChoice('120', '120 行 · 小批量'),
  _CapacityChoice('240', '240 行 · 均衡'),
  _CapacityChoice('480', '480 行 · 减少请求'),
  _CapacityChoice('1000', '1,000 行 · 仅限大容量模型'),
];

/// Translation model settings body. Splits into three segments:
///  - 连接 (connections): manage provider access and saved model names.
///  - 常用模型 (profiles): pick the primary + fallback models for the active
///    global default profile.
///  - 网络 (network): choose the app-wide outbound network policy.
///
/// All state and side effects live in [TranslationSettingsController]; this
/// widget only renders it and forwards intents. Text fields are owned here and
/// reseeded from the controller draft exactly when [TranslationSettingsController.draftRevision]
/// changes, so there is no listener/suppression dance.
class TranslationSettingsView extends StatefulWidget {
  const TranslationSettingsView({super.key, required this.controller});

  final TranslationSettingsController controller;

  @override
  State<TranslationSettingsView> createState() =>
      _TranslationSettingsViewState();
}

class _TranslationSettingsViewState extends State<TranslationSettingsView> {
  final _name = TextEditingController();
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _modelInput = TextEditingController();
  final _maxBatchLines = TextEditingController();
  final _maxContextTokens = TextEditingController();
  final _maxInputTokens = TextEditingController();
  final _maxOutputTokens = TextEditingController();
  final _targetOutputTokens = TextEditingController();
  final _profileName = TextEditingController();
  final _proxyPort = TextEditingController();
  final _modelSearch = TextEditingController();

  int _seededDraftRevision = -1;
  String? _seededProfileId;
  String? _seededRuntimeModel;
  String? _seededNetworkKey;
  String? _seededModelDiscoveryContext;
  final Set<String> _customCapabilityFields = <String>{};
  bool _advancedCapacityExpanded = false;

  TranslationSettingsController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _modelInput.dispose();
    _maxBatchLines.dispose();
    _maxContextTokens.dispose();
    _maxInputTokens.dispose();
    _maxOutputTokens.dispose();
    _targetOutputTokens.dispose();
    _profileName.dispose();
    _proxyPort.dispose();
    _modelSearch.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _reseedIfNeeded() {
    if (c.draftRevision != _seededDraftRevision) {
      _seededDraftRevision = c.draftRevision;
      _name.text = c.draft.name;
      _baseUrl.text = c.draft.baseUrl;
      _apiKey.text = c.draft.apiKey;
      _modelInput.text = c.draft.modelInput;
      final model = c.selectedModelConfig;
      _maxBatchLines.text = model?.maxBatchLines ?? '';
      _maxContextTokens.text = model?.maxContextTokens ?? '';
      _maxInputTokens.text = model?.maxInputTokens ?? '';
      _maxOutputTokens.text = model?.maxOutputTokens ?? '';
      _targetOutputTokens.text = model?.recommendedOutputTokens ?? '';
      if (_seededRuntimeModel != c.selectedModel) {
        _seededRuntimeModel = c.selectedModel;
        _customCapabilityFields.clear();
        _advancedCapacityExpanded = false;
      }
    }
    if (c.activeProfileId != _seededProfileId) {
      _seededProfileId = c.activeProfileId;
      _profileName.text = c.activeProfileName;
    }
    final networkKey = '${c.networkMode}:${c.proxyPort}';
    if (networkKey != _seededNetworkKey) {
      _seededNetworkKey = networkKey;
      _proxyPort.text = c.proxyPort;
    }
    final discoveryContext = '${c.creating}:${c.modelDiscoveryKey}';
    if (!c.isBusy && discoveryContext != _seededModelDiscoveryContext) {
      _seededModelDiscoveryContext = discoveryContext;
      _modelSearch.clear();
      final discoveryKey = c.modelDiscoveryKey;
      if (!c.creating && discoveryKey.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || c.modelDiscoveryKey != discoveryKey) return;
          unawaited(c.ensureModelsDiscovered());
        });
      }
    }
  }

  void _syncConnectionDraftFromFields() {
    c.editName(_name.text);
    c.editBaseUrl(_baseUrl.text);
    c.editApiKey(_apiKey.text);
    c.editModelInput(_modelInput.text);
    c.editModelMaxBatchLines(_maxBatchLines.text);
    c.editModelMaxContextTokens(_maxContextTokens.text);
    c.editModelMaxInputTokens(_maxInputTokens.text);
    c.editModelMaxOutputTokens(_maxOutputTokens.text);
    c.editModelRecommendedOutputTokens(_targetOutputTokens.text);
  }

  Future<void> _saveConnection() async {
    _syncConnectionDraftFromFields();
    await c.saveConnection();
  }

  Future<void> _testConnection() async {
    _syncConnectionDraftFromFields();
    await c.testConnection();
  }

  Future<void> _fetchModels() async {
    _syncConnectionDraftFromFields();
    await c.fetchModels();
  }

  Future<void> _saveNetwork() async {
    c.editProxyPort(_proxyPort.text);
    await c.saveNetwork();
  }

  void _addModelFromInput() {
    _syncConnectionDraftFromFields();
    c.addModelFromInput();
  }

  @override
  Widget build(BuildContext context) {
    _reseedIfNeeded();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DefaultBar(
          text: c.headerText,
          busy: c.busy == TranslationBusy.loading,
          error: c.error,
          message: c.message,
          onRetry: c.snapshot == null && !c.isBusy ? c.refresh : null,
        ),
        const SizedBox(height: T.s16),
        SettingsTabs<TranslationTab>(
          options: const [
            SettingsTabOption(value: TranslationTab.connections, label: '连接'),
            SettingsTabOption(value: TranslationTab.profiles, label: '常用模型'),
            SettingsTabOption(value: TranslationTab.network, label: '网络'),
          ],
          selected: c.tab,
          onPick: c.switchTab,
        ),
        const SizedBox(height: T.s24),
        Expanded(
          child: switch (c.tab) {
            TranslationTab.connections => _connectionsTab(),
            TranslationTab.profiles => _profilesTab(),
            TranslationTab.network => _networkTab(),
          },
        ),
      ],
    );
  }

  Widget _networkTab() {
    final busy = c.isBusy || c.networkSyncing;
    return ToolPanel(
      footer: [
        FeedbackActionButton(
          label: '保存网络设置',
          strong: true,
          busy: c.busy == TranslationBusy.savingNetwork,
          onTap: busy || !c.networkDirty ? null : _saveNetwork,
        ),
      ],
      children: [
        Text('网络连接', style: T.tSection),
        const SizedBox(height: T.s16),
        NetworkSettingsForm(
          mode: c.networkMode,
          proxyPortController: _proxyPort,
          onModeChanged: c.selectNetworkMode,
          onProxyPortChanged: c.editProxyPort,
          enabled: !busy,
        ),
      ],
    );
  }

  // ---- connections tab -----------------------------------------------------

  Widget _connectionsTab() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 210,
          child: ProviderList(
            providers: c.connections,
            selected: c.selectedConnection,
            defaultProvider: c.snapshot?.translationProvider,
            creating: c.creating,
            onPick: c.selectConnection,
            onCreate: c.startCreate,
          ),
        ),
        const SizedBox(width: T.s8),
        Container(width: 1, color: T.line),
        const SizedBox(width: T.s24),
        Expanded(child: _connectionDetail()),
      ],
    );
  }

  Widget _connectionDetail() {
    final creating = c.creating;
    final provider = c.selectedProviderOption;
    final isBlank = !creating && (c.selectedConnection == null);
    final busy = c.isBusy;

    final footer = <Widget>[
      FeedbackActionButton(
        label: '保存连接',
        strong: true,
        busy: c.busy == TranslationBusy.savingConnection,
        onTap: busy ? null : _saveConnection,
      ),
      FeedbackActionButton(
        label: '测试连接',
        busy: c.busy == TranslationBusy.testingConnection,
        onTap: busy ? null : _testConnection,
      ),
      if (!creating && c.selectedConnection != null)
        FeedbackActionButton(
          label: '删除连接',
          busy: c.busy == TranslationBusy.deletingConnection,
          danger: true,
          onTap: busy ? null : c.deleteConnection,
        ),
    ];

    if (isBlank) {
      return ToolPanel(
        footer: footer,
        children: const [_EmptyConnectionState()],
      );
    }

    return ToolPanel(
      footer: footer,
      children: [
        Text(creating ? '添加连接' : provider.name, style: T.tSection),
        const SizedBox(height: T.s16),
        if (!creating && _connectionTestStatus() != null) ...[
          _connectionTestStatus()!,
          const SizedBox(height: T.s16),
        ],
        if (creating) ...[
          SettingsSection(
            title: '选择厂商',
            divider: false,
            children: [
              Wrap(
                spacing: T.s8,
                runSpacing: T.s8,
                children: [
                  for (final template in c.presetTemplates)
                    ChoicePill(
                      label: providerTemplateLabel(template),
                      selected: template.id == c.draft.presetId,
                      onTap: () => c.pickPreset(template),
                    ),
                  ChoicePill(
                    label: '自定义厂商',
                    selected: c.draft.presetId == null,
                    onTap: c.startCustom,
                  ),
                ],
              ),
            ],
          ),
          SettingsSection(
            title: '选择协议',
            divider: false,
            children: [
              TemplateSelect(
                templates: c.protocolTemplates,
                selected: c.draft.protocolId,
                onPick: c.pickProtocol,
              ),
            ],
          ),
        ],
        SettingsSection(
          title: creating ? '连接信息' : '连接设置',
          divider: false,
          children: [
            if (creating) ...[
              ReadonlyRow(label: '厂商', value: _presetLabel()),
              const SizedBox(height: T.s12),
              Input(label: '连接名称', controller: _name, onChanged: c.editName),
            ] else ...[
              ReadonlyRow(label: '连接名称', value: provider.name),
              const SizedBox(height: T.s12),
              ReadonlyRow(
                label: '服务类型',
                value: _providerProtocolLabel(provider),
              ),
            ],
            const SizedBox(height: T.s12),
            Input(
              label: '服务地址 (Base URL)',
              controller: _baseUrl,
              onChanged: c.editBaseUrl,
            ),
            const SizedBox(height: T.s12),
            ReadonlyRow(
              label: '凭据状态',
              value: creating ? '待保存' : _credentialStatusLabel(provider),
            ),
            const SizedBox(height: T.s12),
            Input(
              label: 'API key（留空则沿用已保存凭据）',
              controller: _apiKey,
              obscure: true,
              onChanged: c.editApiKey,
            ),
          ],
        ),
        SettingsSection(
          title: '已启用模型',
          divider: false,
          children: [
            Text(
              c.draft.models.isEmpty
                  ? '还没有启用模型。请从上游列表选择，或手动添加模型 ID。'
                  : '点击模型可编辑翻译设置；只有这里的模型可以加入常用模型。修改后请保存连接。',
              style: T.tCaption,
            ),
            const SizedBox(height: T.s8),
            Wrap(
              spacing: T.s8,
              runSpacing: T.s8,
              children: [
                for (final model in c.draft.models)
                  _ModelChip(
                    label: model,
                    selected: model == c.selectedModel,
                    onTap: () => c.selectModel(model),
                    onRemove: () => c.removeModel(model),
                  ),
                InlineTextField(
                  controller: _modelInput,
                  hint: '手动填写模型 ID',
                  onChanged: c.editModelInput,
                  onSubmitted: (value) {
                    c.editModelInput(value);
                    _addModelFromInput();
                  },
                ),
                ActionButton(label: '启用模型', onTap: _addModelFromInput),
              ],
            ),
          ],
        ),
        if (c.selectedModelConfig != null)
          SettingsSection(
            title: '模型翻译设置 · ${c.selectedModel}',
            divider: false,
            children: _modelRuntimeChildren(),
          ),
        SettingsSection(
          title: '上游可用模型',
          divider: false,
          children: [_upstreamModelCatalog()],
        ),
      ],
    );
  }

  Widget? _connectionTestStatus() {
    if (c.busy == TranslationBusy.testingConnection) {
      return const _ConnectionTestCard.loading();
    }
    final result = c.testResult;
    return result == null ? null : _ConnectionTestCard.result(result);
  }

  String _presetLabel() {
    final id = c.draft.presetId;
    if (id == null) return '自定义厂商';
    for (final template in c.presetTemplates) {
      if (template.id == id) return providerTemplateLabel(template);
    }
    return '自定义厂商';
  }

  Widget _upstreamModelCatalog() {
    final status = c.modelDiscoveryStatus;
    final models = _visibleDiscoveredModels();
    final total = c.discoveredModels.length;
    final query = _modelSearch.text.trim();
    final statusText = switch (status) {
      ModelDiscoveryStatus.idle =>
        c.creating ? '保存连接后会自动获取；也可以先填写凭据再刷新。' : '准备自动获取上游模型列表。',
      ModelDiscoveryStatus.loading => '正在从上游服务获取模型列表…',
      ModelDiscoveryStatus.ready =>
        c.modelDiscoveryHint.isEmpty
            ? '已从上游获取 $total 个模型。'
            : c.modelDiscoveryHint,
      ModelDiscoveryStatus.unavailable =>
        c.modelDiscoveryHint.isEmpty
            ? '没有获取到上游模型，可以手动添加模型 ID。'
            : c.modelDiscoveryHint,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (status == ModelDiscoveryStatus.loading) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
              const SizedBox(width: T.s8),
            ],
            Expanded(
              child: Text(
                statusText,
                style: T.tCaption.copyWith(
                  color: status == ModelDiscoveryStatus.unavailable
                      ? T.warn
                      : T.muted,
                ),
              ),
            ),
            const SizedBox(width: T.s8),
            FeedbackActionButton(
              label: '刷新列表',
              busy: c.isDiscoveringModels,
              onTap: c.isBusy || c.isDiscoveringModels ? null : _fetchModels,
            ),
          ],
        ),
        if (c.discoveredModels.isNotEmpty) ...[
          const SizedBox(height: T.s12),
          SizedBox(
            width: 320,
            child: Input(
              label: '筛选上游模型',
              controller: _modelSearch,
              hintText: '输入模型名称',
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: T.s12),
          if (models.isEmpty)
            const Text('没有匹配的上游模型。', style: T.tCaption)
          else
            Wrap(
              spacing: T.s8,
              runSpacing: T.s8,
              children: [
                for (final model in models)
                  ChoicePill(
                    key: ValueKey('discovered-model-$model'),
                    label: model,
                    selected: c.draft.models.contains(model),
                    showCheck: true,
                    onTap: () {
                      if (!c.isBusy) c.toggleDiscoveredModel(model);
                    },
                  ),
              ],
            ),
          if (models.length <
              c.discoveredModels
                  .where(
                    (model) =>
                        query.isEmpty ||
                        model.toLowerCase().contains(query.toLowerCase()),
                  )
                  .length) ...[
            const SizedBox(height: T.s8),
            const Text('结果较多，请继续输入名称缩小范围。', style: T.tCaption),
          ],
        ],
      ],
    );
  }

  List<String> _visibleDiscoveredModels() {
    final query = _modelSearch.text.trim().toLowerCase();
    return c.discoveredModels
        .where((model) => query.isEmpty || model.toLowerCase().contains(query))
        .take(60)
        .toList();
  }

  List<Widget> _modelRuntimeChildren() {
    final config = c.selectedModelConfig!;
    final recommendation = c.selectedModelRecommendation;
    final testReasoning = c.connectionTestReasoningSupport;

    return [
      if (testReasoning.supported) ...[
        Row(
          children: [
            Text('测试请求', style: T.tCaption),
            const Spacer(),
            ReasoningEffortButton(
              support: testReasoning,
              buttonKey: const ValueKey('connection-test-reasoning-effort'),
              tooltip: '仅本次连接测试的思考程度',
              onChanged: c.isBusy ? null : c.setConnectionTestReasoningEffort,
            ),
          ],
        ),
        const SizedBox(height: T.s12),
        const Divider(height: 1, color: T.line),
        const SizedBox(height: T.s12),
      ],
      Wrap(
        spacing: T.s8,
        runSpacing: T.s8,
        children: [
          ChoicePill(
            label: '自动（推荐）',
            selected: c.usesAutomaticBatchLimit,
            onTap: c.useAutomaticBatchLimit,
          ),
          if (recommendation != null || c.selectedModelCapacityKnown)
            ChoicePill(
              label: '小批量（120 行）',
              selected:
                  c.usesConservativeBatchLimit && !c.usesAutomaticBatchLimit,
              onTap: c.applyConservativeBatchLimit,
            ),
        ],
      ),
      const SizedBox(height: T.s12),
      Wrap(
        spacing: T.s12,
        runSpacing: T.s12,
        children: [
          _CapabilitySelect(
            selectKey: const ValueKey('model-batch-lines-select'),
            label: '每批行数上限',
            value: config.maxBatchLines,
            automaticLabel: '自动（当前 ${c.selectedModelEffectiveBatchLines} 行）',
            options: c.selectedModelCapacityKnown
                ? _batchLineChoices
                : const [_CapacityChoice('120', '120 行')],
            customEditing: _customCapabilityFields.contains('batch'),
            onChanged: (value) => _selectCapability(
              field: 'batch',
              value: value,
              controller: _maxBatchLines,
              edit: c.editModelMaxBatchLines,
            ),
          ),
        ],
      ),
      if (_customCapabilityFields.isNotEmpty) ...[
        const SizedBox(height: T.s12),
        Wrap(
          spacing: T.s12,
          runSpacing: T.s12,
          children: [
            if (_customCapabilityFields.contains('batch'))
              SizedBox(
                width: 220,
                child: Input(
                  label: '自定义单次请求行数',
                  controller: _maxBatchLines,
                  hintText: '例如 240',
                  keyboardType: TextInputType.number,
                  onChanged: c.editModelMaxBatchLines,
                ),
              ),
          ],
        ),
      ],
      const SizedBox(height: T.s12),
      TextButton.icon(
        key: const ValueKey('model-advanced-capacity-toggle'),
        onPressed: () => setState(
          () => _advancedCapacityExpanded = !_advancedCapacityExpanded,
        ),
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          foregroundColor: T.accentStrong,
        ),
        icon: Icon(
          _advancedCapacityExpanded
              ? Icons.keyboard_arrow_up_rounded
              : Icons.keyboard_arrow_down_rounded,
          size: 18,
        ),
        label: Text(_advancedCapacityExpanded ? '收起高级容量设置' : '高级容量设置'),
      ),
      if (_advancedCapacityExpanded) ..._advancedCapacityChildren(),
    ];
  }

  List<Widget> _advancedCapacityChildren() {
    final recommendation = c.selectedModelRecommendation;
    return [
      const SizedBox(height: T.s4),
      const Text(
        '这些值是运行时安全边界。留空表示继承模型目录或当前连接；连接声明的较低上限不会被目录规格放大。',
        style: T.tCaption,
      ),
      if (c.selectedModelSourceSummary case final source?) ...[
        const SizedBox(height: T.s8),
        Text('目录来源：$source', style: T.tCaption),
      ],
      const SizedBox(height: T.s12),
      Wrap(
        spacing: T.s12,
        runSpacing: T.s12,
        children: [
          SizedBox(
            width: 220,
            child: Input(
              key: const ValueKey('model-max-context-input'),
              label: '上下文窗口（tokens）',
              controller: _maxContextTokens,
              hintText: _inheritedCapacityHint(
                c.selectedModelEffectiveMaxContextTokens,
              ),
              keyboardType: TextInputType.number,
              onChanged: c.editModelMaxContextTokens,
            ),
          ),
          SizedBox(
            width: 220,
            child: Input(
              key: const ValueKey('model-max-input-input'),
              label: '最大输入（tokens）',
              controller: _maxInputTokens,
              hintText: _inheritedCapacityHint(
                c.selectedModelEffectiveMaxInputTokens,
              ),
              keyboardType: TextInputType.number,
              onChanged: c.editModelMaxInputTokens,
            ),
          ),
          SizedBox(
            width: 220,
            child: Input(
              key: const ValueKey('model-max-output-input'),
              label: '最大输出（tokens）',
              controller: _maxOutputTokens,
              hintText: _inheritedCapacityHint(
                c.selectedModelEffectiveMaxOutputTokens,
              ),
              keyboardType: TextInputType.number,
              onChanged: c.editModelMaxOutputTokens,
            ),
          ),
          SizedBox(
            width: 220,
            child: Input(
              key: const ValueKey('model-target-output-input'),
              label: '目标输出预算（tokens）',
              controller: _targetOutputTokens,
              hintText: _inheritedCapacityHint(
                c.selectedModelEffectiveTargetOutputTokens,
              ),
              keyboardType: TextInputType.number,
              onChanged: c.editModelRecommendedOutputTokens,
            ),
          ),
        ],
      ),
      const SizedBox(height: T.s12),
      Wrap(
        spacing: T.s8,
        runSpacing: T.s8,
        children: [
          if (recommendation != null)
            ActionButton(
              label: '应用目录容量',
              onTap: c.applySelectedModelCapacityRecommendation,
            ),
          ActionButton(
            label: '清除容量覆盖',
            onTap: c.clearSelectedModelCapacityOverrides,
          ),
        ],
      ),
    ];
  }

  String _inheritedCapacityHint(int value) => value > 0
      ? '继承 ${ModelRuntimeDraft.compactNumber('$value')}'
      : '未知（留空继承）';

  void _selectCapability({
    required String field,
    required String value,
    required TextEditingController controller,
    required ValueChanged<String> edit,
  }) {
    if (value == _customCapabilityValue) {
      setState(() => _customCapabilityFields.add(field));
      return;
    }
    setState(() => _customCapabilityFields.remove(field));
    controller.text = ModelRuntimeDraft.compactInput(value);
    edit(controller.text);
  }

  // ---- profiles tab --------------------------------------------------------

  Widget _profilesTab() {
    if (!c.hasAnyConnection) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _EmptyRecipeState(),
          const SizedBox(height: T.s12),
          ActionButton(
            label: '去添加连接',
            strong: true,
            onTap: () => c.switchTab(TranslationTab.connections),
          ),
        ],
      );
    }
    final busy = c.isBusy;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 210, child: _profileList(busy)),
        const SizedBox(width: T.s8),
        Container(width: 1, color: T.line),
        const SizedBox(width: T.s24),
        Expanded(
          child: ToolPanel(
            footer: const [],
            children: [
              _profileEditorHeader(busy),
              SettingsSection(
                title: '主模型',
                divider: false,
                children: [
                  _PrimarySummary(
                    primary: c.primary,
                    reasoningControl:
                        c.primary != null &&
                            c.reasoningSupport(c.primary!).supported
                        ? ReasoningEffortButton(
                            support: c.reasoningSupport(c.primary!),
                            buttonKey: const ValueKey(
                              'primary-reasoning-effort-button',
                            ),
                            tooltip: '主模型默认思考程度',
                            onChanged: busy
                                ? null
                                : (value) => unawaited(
                                    c.setPrimaryReasoningEffort(value),
                                  ),
                          )
                        : null,
                  ),
                  const SizedBox(height: T.s12),
                  _ModelRefPicker(
                    connections: c.connections,
                    selected: c.primary,
                    onPick: busy ? null : c.setPrimary,
                  ),
                ],
              ),
              SettingsSection(
                title: '备用模型',
                divider: false,
                children: [
                  if (c.fallback.isEmpty)
                    const _EmptyFallbackStrip()
                  else
                    for (var index = 0; index < c.fallback.length; index += 1)
                      Padding(
                        padding: EdgeInsets.only(
                          bottom: index == c.fallback.length - 1 ? 0 : T.s8,
                        ),
                        child: FallbackRouteRow(
                          provider: c.fallback[index].connection,
                          model: c.fallback[index].model,
                          canMoveUp: index > 0,
                          canMoveDown: index < c.fallback.length - 1,
                          onMoveUp: busy
                              ? null
                              : () => c.moveFallback(index, -1),
                          onMoveDown: busy
                              ? null
                              : () => c.moveFallback(index, 1),
                          onRemove: busy ? null : () => c.removeFallback(index),
                          reasoningControl:
                              c.reasoningSupport(c.fallback[index]).supported
                              ? ReasoningEffortButton(
                                  support: c.reasoningSupport(
                                    c.fallback[index],
                                  ),
                                  buttonKey: ValueKey(
                                    'fallback-reasoning-effort-button-$index',
                                  ),
                                  tooltip: '备用模型默认思考程度',
                                  onChanged: busy
                                      ? null
                                      : (value) => unawaited(
                                          c.setFallbackReasoningEffort(
                                            index,
                                            value,
                                          ),
                                        ),
                                )
                              : null,
                        ),
                      ),
                  const SizedBox(height: T.s12),
                  const Text('加入备用模型', style: T.tCaption),
                  const SizedBox(height: T.s8),
                  _ModelRefPicker(
                    connections: c.connections,
                    selected: null,
                    actionLabel: '加入备用',
                    onPick: busy ? null : c.addFallback,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _profileList(bool busy) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('常用模型', style: T.tSection)),
            IconToolButton(
              icon: Icons.add_rounded,
              tooltip: '新建常用模型',
              buttonKey: const ValueKey('create-profile'),
              onTap: busy ? null : () => c.createProfile(_profileName.text),
            ),
          ],
        ),
        const SizedBox(height: T.s12),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              for (final profile in c.profiles)
                _ProfileListRow(
                  name: c.profileDisplayName(profile),
                  primary: profile.model.isEmpty ? '未选主模型' : profile.model,
                  detail: _profileRowDetail(profile),
                  fallbackCount: profile.fallback.length,
                  selected: profile.id == c.activeProfileId,
                  onTap: busy ? null : () => c.switchProfile(profile.id),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _profileEditorHeader(bool busy) {
    final fallbackCount = c.fallback.length;
    final primaryModel = c.primary?.model ?? '未选主模型';
    return Padding(
      padding: const EdgeInsets.only(bottom: T.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            c.activeProfileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: T.tSection,
                          ),
                        ),
                        const SizedBox(width: T.s8),
                        const _GlobalDefaultBadge(),
                      ],
                    ),
                    const SizedBox(height: T.s4),
                    Text(
                      '$primaryModel · ${fallbackCount == 0 ? '无备用' : '备用 $fallbackCount 个'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.tCaption,
                    ),
                  ],
                ),
              ),
              IconToolButton(
                icon: Icons.delete_outline_rounded,
                tooltip: '删除常用模型',
                buttonKey: const ValueKey('delete-profile'),
                onTap: busy || c.profiles.length <= 1 ? null : c.deleteProfile,
              ),
            ],
          ),
          const SizedBox(height: T.s16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Input(label: '名称', controller: _profileName),
              ),
              const SizedBox(width: T.s8),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: IconToolButton(
                  icon: Icons.check_rounded,
                  tooltip: '保存名称',
                  buttonKey: const ValueKey('save-profile-name'),
                  onTap: busy ? null : () => c.renameProfile(_profileName.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: T.s12),
          const Divider(height: 1, color: T.line),
        ],
      ),
    );
  }

  String _profileRowDetail(RoutingProfileOption profile) {
    final parts = <String>[
      if (profile.provider.isNotEmpty) profile.provider,
      profile.fallback.isEmpty ? '无备用' : '备用 ${profile.fallback.length} 个',
    ];
    return parts.isEmpty ? '待配置' : parts.join(' · ');
  }
}

class _CapabilitySelect extends StatelessWidget {
  const _CapabilitySelect({
    required this.selectKey,
    required this.label,
    required this.value,
    required this.automaticLabel,
    required this.options,
    required this.customEditing,
    required this.onChanged,
  });

  final Key selectKey;
  final String label;
  final String value;
  final String automaticLabel;
  final List<_CapacityChoice> options;
  final bool customEditing;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final parsed = ModelRuntimeDraft.parseNumber(value) ?? 0;
    final matching = options.where(
      (option) => ModelRuntimeDraft.parseNumber(option.value) == parsed,
    );
    final selected = customEditing
        ? _customCapabilityValue
        : parsed <= 0
        ? ''
        : matching.isNotEmpty
        ? matching.first.value
        : '__current__';
    return SizedBox(
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: T.tCaption),
          const SizedBox(height: T.s4),
          Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: T.s12),
            decoration: BoxDecoration(
              color: T.surface,
              borderRadius: BorderRadius.circular(T.rMd),
              border: Border.all(color: T.line),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: selectKey,
                value: selected,
                isExpanded: true,
                style: T.tBody,
                icon: const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: T.muted,
                ),
                items: [
                  DropdownMenuItem(value: '', child: Text(automaticLabel)),
                  for (final option in options)
                    DropdownMenuItem(
                      value: option.value,
                      child: Text(
                        option.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (parsed > 0 && matching.isEmpty)
                    DropdownMenuItem(
                      value: '__current__',
                      child: Text(
                        '当前：${ModelRuntimeDraft.compactNumber(value)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const DropdownMenuItem(
                    value: _customCapabilityValue,
                    child: Text('自定义…'),
                  ),
                ],
                onChanged: (next) {
                  if (next == null || next == '__current__') return;
                  onChanged(next);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileListRow extends StatefulWidget {
  const _ProfileListRow({
    required this.name,
    required this.primary,
    required this.detail,
    required this.fallbackCount,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final String primary;
  final String detail;
  final int fallbackCount;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_ProfileListRow> createState() => _ProfileListRowState();
}

class _ProfileListRowState extends State<_ProfileListRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 62),
          padding: const EdgeInsets.symmetric(
            horizontal: T.s12,
            vertical: T.s8,
          ),
          decoration: BoxDecoration(
            color: widget.selected || _hover ? T.accentSoft : null,
            border: Border(
              left: BorderSide(
                color: widget.selected ? T.accent : const Color(0x00000000),
                width: 3,
              ),
              bottom: const BorderSide(color: T.line, width: 1),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            widget.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: T.tBody.copyWith(
                              color: widget.selected ? T.accentStrong : T.ink,
                              fontWeight: widget.selected ? T.wBold : T.wMedium,
                            ),
                          ),
                        ),
                        if (widget.selected) ...[
                          const SizedBox(width: T.s8),
                          const _MiniDefaultBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.primary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.tCaption.copyWith(color: T.ink),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      widget.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.tCaption,
                    ),
                  ],
                ),
              ),
              if (widget.fallbackCount > 0) ...[
                const SizedBox(width: T.s8),
                Text(
                  '${widget.fallbackCount}',
                  style: T.tCaption.copyWith(
                    color: widget.selected ? T.accentStrong : T.muted,
                    fontWeight: T.wBold,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimarySummary extends StatelessWidget {
  const _PrimarySummary({required this.primary, this.reasoningControl});

  final ModelRef? primary;
  final Widget? reasoningControl;

  @override
  Widget build(BuildContext context) {
    final ref = primary;
    final configured = ref != null && !ref.isEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: configured ? T.accentSoft : T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: configured ? T.accent : T.line, width: 1),
      ),
      child: Row(
        children: [
          Icon(
            configured ? Icons.check_rounded : Icons.radio_button_unchecked,
            size: 17,
            color: configured ? T.accentStrong : T.muted,
          ),
          const SizedBox(width: T.s8),
          Expanded(
            child: RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                style: T.tCaption.copyWith(
                  color: T.ink,
                  fontFamily: T.fontFamily,
                ),
                children: [
                  TextSpan(
                    text: configured ? ref.model : '未选主模型',
                    style: const TextStyle(fontWeight: T.wBold),
                  ),
                  if (configured) ...[
                    const TextSpan(
                      text: ' · ',
                      style: TextStyle(color: T.muted),
                    ),
                    TextSpan(text: ref.connection),
                  ],
                ],
              ),
            ),
          ),
          if (reasoningControl case final control?) ...[
            const SizedBox(width: T.s8),
            control,
          ],
        ],
      ),
    );
  }
}

class _EmptyFallbackStrip extends StatelessWidget {
  const _EmptyFallbackStrip();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line, width: 1),
      ),
      child: Text('无备用模型', style: T.tCaption),
    );
  }
}

class _ConnectionTestCard extends StatefulWidget {
  const _ConnectionTestCard.loading()
    : title = '正在测试服务',
      detail = '等待模型服务返回测试结果',
      ok = null;

  _ConnectionTestCard.result(ConnectionTestResult result)
    : title = result.title,
      detail = result.detail,
      ok = result.ok;

  final String title;
  final String detail;
  final bool? ok;

  @override
  State<_ConnectionTestCard> createState() => _ConnectionTestCardState();
}

class _ConnectionTestCardState extends State<_ConnectionTestCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.ok == null) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _ConnectionTestCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ok == null && !_controller.isAnimating) {
      _controller.repeat();
    } else if (widget.ok != null && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final running = widget.ok == null;
    final color = widget.ok == false ? T.danger : T.accentStrong;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: T.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 96,
            height: 34,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => CustomPaint(
                painter: _ConnectionSignalPainter(
                  phase: running ? _controller.value : 1,
                  status: widget.ok,
                  color: color,
                ),
              ),
            ),
          ),
          const SizedBox(width: T.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tBody.copyWith(color: T.ink, fontWeight: T.wBold),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption.copyWith(color: T.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionSignalPainter extends CustomPainter {
  const _ConnectionSignalPainter({
    required this.phase,
    required this.status,
    required this.color,
  });

  final double phase;
  final bool? status;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final line = Paint()
      ..color = T.inkLine.withValues(alpha: 0.62)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    final terminal = Paint()
      ..color = T.surface
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(8, y), 5, terminal);
    canvas.drawCircle(Offset(8, y), 5, line);
    canvas.drawLine(Offset(13, y), Offset(30, y), line);

    if (status == false) {
      canvas.drawLine(Offset(30, y), Offset(42, y), line);
      canvas.drawLine(Offset(54, y), Offset(size.width - 13, y), line);
      final mark = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(44, y - 5), Offset(52, y + 5), mark);
      canvas.drawLine(Offset(52, y - 5), Offset(44, y + 5), mark);
    } else {
      canvas.drawLine(Offset(30, y), Offset(size.width - 13, y), line);
    }

    canvas.drawCircle(Offset(size.width - 8, y), 5, terminal);
    canvas.drawCircle(Offset(size.width - 8, y), 5, line);

    if (status == null) {
      final signalX = 30 + (size.width - 48) * phase;
      canvas.drawCircle(Offset(signalX, y), 3.4, Paint()..color = T.accent);
      canvas.drawCircle(
        Offset(signalX, y),
        6.5,
        Paint()..color = T.accent.withValues(alpha: 0.12),
      );
    } else if (status == true) {
      final stamp = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final x = size.width - 8;
      canvas.drawLine(Offset(x - 3, y), Offset(x - 0.5, y + 2.5), stamp);
      canvas.drawLine(Offset(x - 0.5, y + 2.5), Offset(x + 4, y - 3), stamp);
    }
  }

  @override
  bool shouldRepaint(covariant _ConnectionSignalPainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.status != status ||
      oldDelegate.color != color;
}

class _GlobalDefaultBadge extends StatelessWidget {
  const _GlobalDefaultBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 3),
      decoration: BoxDecoration(
        color: T.accentSoft,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.accent, width: 1),
      ),
      child: Text(
        '全局默认',
        style: T.tCaption.copyWith(color: T.accentStrong, fontWeight: T.wBold),
      ),
    );
  }
}

class _MiniDefaultBadge extends StatelessWidget {
  const _MiniDefaultBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.accent, width: 1),
      ),
      child: Text(
        '默认',
        style: T.tCaption.copyWith(
          color: T.accentStrong,
          fontWeight: T.wBold,
          height: 1,
        ),
      ),
    );
  }
}

class _EmptyConnectionState extends StatelessWidget {
  const _EmptyConnectionState();

  @override
  Widget build(BuildContext context) {
    return const _IllustratedEmptyState(
      kind: _EmptyIllustrationKind.connection,
      title: '插槽空着',
      detail: '添加一个模型服务后，就能保存可用模型。',
    );
  }
}

class _EmptyRecipeState extends StatelessWidget {
  const _EmptyRecipeState();

  @override
  Widget build(BuildContext context) {
    return const _IllustratedEmptyState(
      kind: _EmptyIllustrationKind.recipe,
      title: '先添加连接',
      detail: '常用模型由主模型和备用模型组成。',
    );
  }
}

class _IllustratedEmptyState extends StatelessWidget {
  const _IllustratedEmptyState({
    required this.kind,
    required this.title,
    required this.detail,
  });

  final _EmptyIllustrationKind kind;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 78,
          height: 58,
          child: CustomPaint(painter: _EmptyIllustrationPainter(kind)),
        ),
        const SizedBox(width: T.s16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: T.tSection),
              const SizedBox(height: 4),
              Text(detail, style: T.tCaption),
            ],
          ),
        ),
      ],
    );
  }
}

enum _EmptyIllustrationKind { connection, recipe }

class _EmptyIllustrationPainter extends CustomPainter {
  const _EmptyIllustrationPainter(this.kind);

  final _EmptyIllustrationKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = T.inkLine
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = T.accentSoft
      ..style = PaintingStyle.fill;
    final blue = Paint()
      ..color = T.sky.withValues(alpha: 0.22)
      ..style = PaintingStyle.fill;

    if (kind == _EmptyIllustrationKind.connection) {
      final body = RRect.fromRectAndRadius(
        Rect.fromLTWH(10, 18, 38, 26),
        const Radius.circular(7),
      );
      canvas.drawRRect(body, fill);
      canvas.drawRRect(body, line);
      canvas.drawCircle(const Offset(21, 30), 3, line);
      canvas.drawCircle(const Offset(36, 30), 3, line);
      canvas.drawPath(
        Path()
          ..moveTo(48, 31)
          ..cubicTo(57, 31, 58, 17, 67, 17)
          ..lineTo(70, 17),
        line,
      );
      canvas.drawLine(const Offset(66, 12), const Offset(66, 22), line);
      canvas.drawLine(const Offset(72, 12), const Offset(72, 22), line);
      return;
    }

    final ticket = RRect.fromRectAndRadius(
      Rect.fromLTWH(12, 13, 48, 34),
      const Radius.circular(5),
    );
    canvas.drawRRect(ticket, fill);
    canvas.drawRRect(ticket, line);
    canvas.drawCircle(const Offset(12, 30), 4, blue);
    canvas.drawCircle(const Offset(60, 30), 4, blue);
    canvas.drawLine(const Offset(23, 24), const Offset(49, 24), line);
    canvas.drawLine(const Offset(23, 34), const Offset(43, 34), line);
  }

  @override
  bool shouldRepaint(covariant _EmptyIllustrationPainter oldDelegate) =>
      oldDelegate.kind != kind;
}

/// A removable model chip in the connection's model list.
class _ModelChip extends StatelessWidget {
  const _ModelChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final width = label.length <= 24 ? 180.0 : 280.0;
    return SizedBox(
      width: width,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.only(left: T.s12, right: T.s4),
          height: 32,
          decoration: BoxDecoration(
            color: selected ? T.accentSoft : T.surface,
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(color: selected ? T.accent : T.line, width: 1),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.tCaption.copyWith(
                    color: selected ? T.accentStrong : T.ink,
                  ),
                ),
              ),
              const SizedBox(width: T.s4),
              IconToolButton(
                buttonKey: ValueKey('remove-model-$label'),
                icon: Icons.close_rounded,
                tooltip: '移除模型',
                onTap: onRemove,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two-level "connection → model" picker. Row one is the connection pills; the
/// selected connection expands its models below. Tapping a model either fires
/// [onPick] directly (primary) or, when [actionLabel] is set, stages the model
/// and reveals a confirm button (fallback).
class _ModelRefPicker extends StatefulWidget {
  const _ModelRefPicker({
    required this.connections,
    required this.selected,
    required this.onPick,
    this.actionLabel,
  });

  final List<ProviderOption> connections;
  final ModelRef? selected;
  final ValueChanged<ModelRef>? onPick;
  final String? actionLabel;

  @override
  State<_ModelRefPicker> createState() => _ModelRefPickerState();
}

class _ModelRefPickerState extends State<_ModelRefPicker> {
  String? _connection;
  String? _model;

  ProviderOption? get _selectedConnection {
    // Fall back to the sole connection when there is exactly one — with a
    // single connection there is nothing to disambiguate, so its models should
    // show without an extra tap.
    final name =
        _connection ??
        widget.selected?.connection ??
        (widget.connections.length == 1 ? widget.connections.first.name : null);
    if (name == null) return null;
    for (final provider in widget.connections) {
      if (provider.name == name) return provider;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final provider = _selectedConnection;
    final activeConnection = provider?.name;
    final stagedModel = _model ?? widget.selected?.model;
    final selectedModel = widget.selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: T.s8,
          runSpacing: T.s8,
          children: [
            for (final option in widget.connections)
              ChoicePill(
                label: option.name,
                selected: option.name == activeConnection,
                onTap: () => setState(() {
                  _connection = option.name;
                  _model = null;
                }),
              ),
          ],
        ),
        if (provider != null) ...[
          const SizedBox(height: T.s8),
          if (provider.models.isEmpty)
            const Text('这个连接还没有保存模型', style: T.tCaption)
          else
            Wrap(
              spacing: T.s8,
              runSpacing: T.s8,
              children: [
                for (final model in provider.models)
                  ChoicePill(
                    key: ValueKey(
                      widget.actionLabel == null
                          ? 'primary-model-${provider.name}-$model'
                          : 'fallback-model-${provider.name}-$model',
                    ),
                    label: model,
                    selected: widget.actionLabel == null
                        ? selectedModel?.connection == provider.name &&
                              selectedModel?.model == model
                        : model == stagedModel,
                    showCheck: widget.actionLabel == null,
                    onTap: () => _onModelTap(provider.name, model),
                  ),
              ],
            ),
        ],
        if (widget.actionLabel != null) ...[
          const SizedBox(height: T.s12),
          ActionButton(
            label: widget.actionLabel!,
            onTap:
                widget.onPick == null || provider == null || stagedModel == null
                ? null
                : () {
                    widget.onPick!(
                      ModelRef(connection: provider.name, model: stagedModel),
                    );
                    setState(() => _model = null);
                  },
          ),
        ],
      ],
    );
  }

  void _onModelTap(String connection, String model) {
    if (widget.actionLabel != null) {
      setState(() {
        _connection = connection;
        _model = model;
      });
      return;
    }
    widget.onPick?.call(ModelRef(connection: connection, model: model));
  }
}

// ---- provider display helpers (ported from the legacy settings window) -----

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

String _credentialStatusLabel(ProviderOption provider) {
  if (provider.name.isEmpty) return '未选择连接';
  return provider.hasKey ? '已配置' : '需要配置';
}
