import 'package:flutter/material.dart';

import '../model/translation_settings_controller.dart';
import '../services/app_service_client.dart';
import '../theme/tokens.dart';
import 'settings_common.dart';

/// Translation model settings body. Splits into two segments:
///  - 连接 (connections): manage provider access and saved model names.
///  - 常用模型 (profiles): pick the primary + fallback models for the active
///    global default profile.
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
          onRetry: c.snapshot == null && !c.isBusy ? c.refresh : null,
        ),
        const SizedBox(height: T.s16),
        _TranslationTabs(selected: c.tab, onPick: c.switchTab),
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
              const SizedBox(height: T.s12),
              ReadonlyRow(label: '来源', value: _providersFileLabel(c.snapshot)),
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
        if (!creating) _connectionStatusSection(provider),
      ],
    );
  }

  Widget _connectionStatusSection(ProviderOption provider) {
    return SettingsSection(
      title: '连接状态',
      divider: false,
      children: [
        ReadonlyRow(label: '服务类型', value: _providerProtocolLabel(provider)),
        const SizedBox(height: T.s8),
        ReadonlyRow(label: '凭据', value: _credentialStatusLabel(provider)),
        const SizedBox(height: T.s8),
        ReadonlyRow(label: '来源', value: _providersFileLabel(c.snapshot)),
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
    return ToolPanel(
      footer: const [],
      children: [
        SettingsSection(
          title: '常用模型',
          divider: false,
          children: [
            Wrap(
              spacing: T.s8,
              runSpacing: T.s8,
              children: [
                for (final profile in c.profiles)
                  ChoicePill(
                    label: c.profileDisplayName(profile),
                    selected: profile.id == c.activeProfileId,
                    onTap: () => c.switchProfile(profile.id),
                  ),
                ActionButton(
                  label: '新建常用模型',
                  onTap: busy ? null : () => c.createProfile(_profileName.text),
                ),
              ],
            ),
            const SizedBox(height: T.s12),
            Row(
              children: [
                Text(c.activeProfileName, style: T.tSection),
                const SizedBox(width: T.s8),
                const _GlobalDefaultBadge(),
              ],
            ),
            const SizedBox(height: T.s12),
            Input(label: '名称', controller: _profileName),
            const SizedBox(height: T.s12),
            Wrap(
              spacing: T.s12,
              runSpacing: T.s8,
              children: [
                ActionButton(
                  label: '重命名',
                  onTap: busy ? null : () => c.renameProfile(_profileName.text),
                ),
                ActionButton(
                  label: '删除当前常用模型',
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

class _TranslationTabs extends StatelessWidget {
  const _TranslationTabs({required this.selected, required this.onPick});

  final TranslationTab selected;
  final ValueChanged<TranslationTab> onPick;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.line, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TranslationTabButton(
            label: '连接',
            selected: selected == TranslationTab.connections,
            onTap: () => onPick(TranslationTab.connections),
          ),
          _TranslationTabButton(
            label: '常用模型',
            selected: selected == TranslationTab.profiles,
            onTap: () => onPick(TranslationTab.profiles),
          ),
        ],
      ),
    );
  }
}

class _TranslationTabButton extends StatelessWidget {
  const _TranslationTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 96,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? T.accentSoft : const Color(0x00000000),
          borderRadius: BorderRadius.circular(T.rSm),
          border: Border.all(
            color: selected ? T.accent : const Color(0x00000000),
            width: 1,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: T.tBody.copyWith(
            color: selected ? T.accentStrong : T.ink,
            fontWeight: selected ? T.wBold : T.wMedium,
          ),
        ),
      ),
    );
  }
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

String _providersFileLabel(DesktopSnapshot? snapshot) {
  final raw = _str(snapshot?.config['providers_file']);
  if (raw == null || raw.isEmpty) return '本机配置';
  final normalized = raw.replaceAll('\\', '/');
  const marker = '/.transvortex-desktop/';
  final markerIndex = normalized.indexOf(marker);
  if (markerIndex >= 0) {
    final tail = normalized.substring(markerIndex + 1).replaceAll('/', '\\');
    return _providersFileKindLabel(tail);
  }
  final parts = normalized.split('/');
  final fileName = parts.isEmpty ? raw : parts.last;
  return _providersFileKindLabel(fileName);
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

String? _str(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return '$value';
}
