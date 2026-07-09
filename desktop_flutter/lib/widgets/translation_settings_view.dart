import 'package:flutter/material.dart';

import '../model/translation_settings_controller.dart';
import '../services/app_service_client.dart';
import '../theme/tokens.dart';
import 'settings_common.dart';

/// Translation model settings body. Splits into two segments:
///  - 模型连接 (connections): manage providers and their supported models.
///  - 翻译方案 (profiles): pick the primary + fallback models for the active
///    routing profile.
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
  final _profileName = TextEditingController();

  int _seededDraftRevision = -1;
  String? _seededProfileId;
  bool _showAdvanced = false;

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
    _profileName.dispose();
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
    }
    if (c.activeProfileId != _seededProfileId) {
      _seededProfileId = c.activeProfileId;
      _profileName.text = c.activeProfileName;
    }
  }

  void _syncConnectionDraftFromFields() {
    c.editName(_name.text);
    c.editBaseUrl(_baseUrl.text);
    c.editApiKey(_apiKey.text);
    c.editModelInput(_modelInput.text);
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
        ),
        const SizedBox(height: T.s16),
        Row(
          children: [
            SegmentButton(
              label: '模型连接',
              detail: '${c.connections.length} 个连接',
              selected: c.tab == TranslationTab.connections,
              onTap: () => c.switchTab(TranslationTab.connections),
            ),
            const SizedBox(width: T.s8),
            SegmentButton(
              label: '翻译方案',
              detail: c.activeProfileName,
              selected: c.tab == TranslationTab.profiles,
              onTap: () => c.switchTab(TranslationTab.profiles),
            ),
          ],
        ),
        const SizedBox(height: T.s24),
        Expanded(
          child: c.tab == TranslationTab.connections
              ? _connectionsTab()
              : _profilesTab(),
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
        const SizedBox(width: T.s32),
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
      ActionButton(
        label: c.busy == TranslationBusy.savingConnection ? '保存中' : '保存连接',
        strong: true,
        onTap: busy ? null : _saveConnection,
      ),
      ActionButton(
        label: c.busy == TranslationBusy.testingConnection ? '测试中' : '测试连接',
        onTap: busy ? null : _testConnection,
      ),
      ActionButton(
        label: c.busy == TranslationBusy.fetchingModels ? '拉取中' : '拉取模型',
        onTap: busy ? null : _fetchModels,
      ),
      if (!creating && c.selectedConnection != null)
        ActionButton(
          label: c.busy == TranslationBusy.deletingConnection ? '删除中' : '删除连接',
          onTap: busy ? null : c.deleteConnection,
        ),
      ActionButton(
        label: c.busy == TranslationBusy.loading ? '刷新中' : '刷新',
        onTap: busy ? null : c.refresh,
      ),
    ];

    return ToolPanel(
      footer: footer,
      children: [
        Text(
          creating ? '添加模型连接' : (isBlank ? '选择一个连接或添加连接' : provider.name),
          style: T.tSection,
        ),
        const SizedBox(height: T.s16),
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
              ReadonlyRow(label: '协议', value: _providerProtocolLabel(provider)),
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
            const SizedBox(height: T.s16),
            Text('模型', style: T.tCaption.copyWith(fontWeight: T.wBold)),
            const SizedBox(height: T.s8),
            Wrap(
              spacing: T.s8,
              runSpacing: T.s8,
              children: [
                for (final model in c.draft.models)
                  _ModelChip(
                    label: model,
                    onRemove: () => c.removeModel(model),
                  ),
                InlineTextField(
                  controller: _modelInput,
                  hint: c.draft.models.isEmpty ? '填写模型名' : '添加模型名',
                  onChanged: c.editModelInput,
                  onSubmitted: (value) {
                    c.editModelInput(value);
                    _addModelFromInput();
                  },
                ),
                ActionButton(label: '添加模型', onTap: _addModelFromInput),
              ],
            ),
            if (_modelHelp() != null) ...[
              const SizedBox(height: T.s12),
              Text(_modelHelp()!, style: T.tCaption, maxLines: 2),
            ],
          ],
        ),
        if (!isBlank && !creating) _advancedSection(provider),
      ],
    );
  }

  Widget _advancedSection(ProviderOption provider) {
    return SettingsSection(
      title: '高级配置',
      divider: false,
      children: [
        ActionButton(
          label: _showAdvanced ? '收起高级配置' : '展开高级配置',
          onTap: () => setState(() => _showAdvanced = !_showAdvanced),
        ),
        if (_showAdvanced) ...[
          const SizedBox(height: T.s12),
          ReadonlyRow(label: '配置来源', value: _providersFileLabel(c.snapshot)),
          const SizedBox(height: T.s8),
          ReadonlyRow(label: '协议标识', value: _providerCompatModeLabel(provider)),
          const SizedBox(height: T.s8),
          ReadonlyRow(label: '凭据 ID', value: _providerCredentialId(provider)),
          const SizedBox(height: T.s8),
          ReadonlyRow(label: '环境变量', value: _providerEnvKey(provider)),
          const SizedBox(height: T.s8),
          ReadonlyRow(label: '请求端点', value: _providerEndpointLabel(provider)),
          const SizedBox(height: T.s8),
          ReadonlyRow(label: '模型列表', value: _modelListEndpointLabel(provider)),
          const SizedBox(height: T.s8),
          ReadonlyRow(
            label: '响应提取',
            value: _providerResponseMappingLabel(provider),
          ),
          const SizedBox(height: T.s8),
          ReadonlyRow(label: '调用限制', value: _providerLimitsLabel(provider)),
        ],
      ],
    );
  }

  String _presetLabel() {
    final id = c.draft.presetId;
    if (id == null) return '自定义厂商';
    for (final template in c.presetTemplates) {
      if (template.id == id) return providerTemplateLabel(template);
    }
    return '自定义厂商';
  }

  String? _modelHelp() {
    if (c.draft.models.isNotEmpty) return null;
    return '这个连接还没有模型，填写模型名或点“拉取模型”。';
  }

  // ---- profiles tab --------------------------------------------------------

  Widget _profilesTab() {
    if (!c.hasAnyConnection) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('还没有连接，先到「模型连接」添加。', style: T.tBody),
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
    return ToolPanel(
      footer: [
        ActionButton(
          label: c.busy == TranslationBusy.loading ? '刷新中' : '刷新',
          onTap: busy ? null : c.refresh,
        ),
      ],
      footnote: '主模型和备用模型都从「模型连接」里已保存的连接中选择。',
      children: [
        SettingsSection(
          title: '翻译方案',
          divider: false,
          children: [
            Wrap(
              spacing: T.s8,
              runSpacing: T.s8,
              children: [
                for (final profile in c.profiles)
                  ChoicePill(
                    label: profile.displayName,
                    selected: profile.id == c.activeProfileId,
                    onTap: () => c.switchProfile(profile.id),
                  ),
              ],
            ),
            const SizedBox(height: T.s12),
            Input(label: '方案名称', controller: _profileName),
            const SizedBox(height: T.s12),
            Wrap(
              spacing: T.s12,
              runSpacing: T.s8,
              children: [
                ActionButton(
                  label: '重命名方案',
                  onTap: busy ? null : () => c.renameProfile(_profileName.text),
                ),
                ActionButton(
                  label: '另存为新方案',
                  onTap: busy ? null : () => c.createProfile(_profileName.text),
                ),
                ActionButton(
                  label: '删除当前方案',
                  onTap: busy || c.profiles.length <= 1
                      ? null
                      : c.deleteProfile,
                ),
              ],
            ),
          ],
        ),
        SettingsSection(
          title: '主模型',
          divider: false,
          children: [
            Text('当前主模型：${c.primary?.label ?? '未设置'}', style: T.tBody),
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
              const Text('暂未设置备用模型', style: T.tCaption)
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
                    onMoveUp: busy ? null : () => c.moveFallback(index, -1),
                    onMoveDown: busy ? null : () => c.moveFallback(index, 1),
                    onRemove: busy ? null : () => c.removeFallback(index),
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
    );
  }
}

/// A removable model chip in the connection's model list.
class _ModelChip extends StatelessWidget {
  const _ModelChip({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final width = label.length <= 24 ? 180.0 : 280.0;
    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.only(left: T.s12, right: T.s4),
        height: 32,
        decoration: BoxDecoration(
          color: T.surface,
          borderRadius: BorderRadius.circular(T.rSm),
          border: Border.all(color: T.line, width: 1),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.tCaption.copyWith(color: T.ink),
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
                    label: model,
                    selected: widget.actionLabel == null
                        ? selectedModel?.connection == provider.name &&
                              selectedModel?.model == model
                        : model == stagedModel,
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

String _providerCompatModeLabel(ProviderOption provider) {
  final compat = provider.compatMode.trim();
  return compat.isEmpty ? '未指定' : compat;
}

String _providerEndpointLabel(ProviderOption provider) {
  final endpoint = _map(provider.raw['endpoint']);
  final method = _str(endpoint['method']) ?? 'POST';
  final path =
      _str(endpoint['path_template']) ?? _str(endpoint['pathTemplate']) ?? '/';
  return '$method $path';
}

String _providerResponseMappingLabel(ProviderOption provider) {
  final response = _map(provider.raw['response_mapping']);
  final paths = _strList(response['text_paths']);
  if (paths.isEmpty) return '按协议默认响应路径';
  return paths.join(', ');
}

String _providerLimitsLabel(ProviderOption provider) {
  final limits = _map(provider.raw['limits']);
  final concurrency = _str(limits['concurrency']) ?? '默认';
  final timeout =
      _str(limits['timeout_seconds']) ?? _str(limits['timeoutSeconds']) ?? '默认';
  final retry = _str(limits['retry']) ?? '默认';
  return '并发 $concurrency · 超时 ${timeout}s · 重试 $retry';
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
  if (provider.name.isEmpty) return '未选择连接';
  final source = _credentialSourceLabel(provider.credentialSource);
  return provider.hasKey ? '已配置 · $source' : '缺密钥 · $source';
}

String _providerCredentialId(ProviderOption provider) {
  if (provider.credentialId.isNotEmpty) return provider.credentialId;
  return provider.name.isEmpty ? '待填写' : provider.name;
}

String _providerEnvKey(ProviderOption provider) {
  if (provider.envKey.isNotEmpty) return provider.envKey;
  final name = provider.name.trim();
  if (name.isEmpty) return '待填写';
  final slug = name
      .toUpperCase()
      .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return 'TVX_PROVIDER_${slug.isEmpty ? 'CUSTOM' : slug}_API_KEY';
}

String _modelListEndpointLabel(ProviderOption provider) {
  final modelList = _map(provider.raw['model_list']);
  final path =
      _str(modelList['path_template']) ?? _str(modelList['pathTemplate']);
  if (path == null || path.isEmpty) return '手动填写';
  final method = _str(modelList['method']) ?? 'GET';
  return '$method $path';
}

String _providersFileLabel(DesktopSnapshot? snapshot) {
  final raw = _str(snapshot?.config['providers_file']);
  if (raw == null || raw.isEmpty) return '未知';
  final normalized = raw.replaceAll('\\', '/');
  const marker = '/.transvortex-desktop/';
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

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.map((k, v) => MapEntry('$k', v)) : const {};

List<String> _strList(Object? value) =>
    value is List ? [for (final item in value) '$item'] : const <String>[];

String? _str(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return '$value';
}
