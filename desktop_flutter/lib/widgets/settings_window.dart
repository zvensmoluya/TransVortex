import 'package:flutter/material.dart';

import '../model/spike_state.dart';
import '../services/app_service_client.dart';
import '../services/window_state_bridge.dart';
import '../theme/tokens.dart';
import 'title_bar.dart';

class SettingsWindow extends StatefulWidget {
  const SettingsWindow({
    super.key,
    required this.type,
    required this.store,
    required this.bridge,
  });

  final SpikeWindowType type;
  final WindowStateStore store;
  final WindowStateBridge bridge;

  @override
  State<SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends State<SettingsWindow> {
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  final _endpoint = TextEditingController();
  final _device = TextEditingController(text: 'auto');
  late final AppServiceClient _client = AppServiceClient(
    WindowBridgeTransport(widget.bridge),
  );

  DesktopSnapshot? _snapshot;
  String? _selectedProvider;
  String? _selectedModel;
  String _selectedAsrProvider = 'faster_whisper_large_v3';
  String? _message;
  String? _error;
  bool _loading = false;
  bool _savingProvider = false;
  bool _savingDefault = false;
  bool _loadingModels = false;
  bool _testingProvider = false;
  bool _savingAsr = false;

  bool get _isTranslation =>
      widget.type == SpikeWindowType.translationSettings;

  @override
  void initState() {
    super.initState();
    widget.bridge.initializeChild();
    _loadConfig();
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _key.dispose();
    _endpoint.dispose();
    _device.dispose();
    super.dispose();
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
        if (_isTranslation) {
          _selectedProvider = snapshot.translationProvider ??
              (snapshot.providers.isNotEmpty ? snapshot.providers.first.name : null);
          _selectedModel = snapshot.translationModel;
          _loadProviderDraftFields();
        } else {
          _selectedAsrProvider =
              snapshot.asrProviderName ?? 'faster_whisper_large_v3';
          _loadAsrDraftFields();
        }
      });
      _syncMainLabels(snapshot);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
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
    final title = _isTranslation ? '翻译模型设置' : '语音识别设置';
    final status = _isTranslation ? '配好模型服务，选定默认模型' : '视频没有现成字幕时，用它把语音转成字幕';
    return Scaffold(
      backgroundColor: T.bg,
      body: Column(
        children: [
          TitleBar(title: title, status: status),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(T.s32, T.s16, T.s32, T.s24),
              child: _isTranslation ? _translationBody() : _asrBody(),
            ),
          ),
        ],
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
          text: selected == null || _selectedModel == null
              ? '还没选默认模型'
              : '翻译默认：$selected · $_selectedModel',
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
    final model = _selectedModel ?? _model.text.trim();
    return _ToolPanel(
      children: [
        Text(
          provider.name.isEmpty ? '选择一个供应商' : provider.name,
          style: T.tSection,
        ),
        const SizedBox(height: T.s16),
        _ReadonlyRow(label: '协议格式', value: provider.apiType.isEmpty ? 'openai-compatible' : provider.apiType),
        const SizedBox(height: T.s12),
        _Input(label: 'Base URL', controller: _baseUrl),
        const SizedBox(height: T.s12),
        _Input(label: 'API key（留空则沿用已保存凭据）', controller: _key, obscure: true),
        const SizedBox(height: T.s16),
        Row(
          children: [
            _ActionButton(
              label: _loadingModels ? '拉取中' : '拉取模型列表',
              onTap: _loadingModels ? null : _fetchModels,
            ),
            const SizedBox(width: T.s12),
            _ActionButton(
              label: _testingProvider ? '测试中' : '测试连接',
              onTap: _testingProvider ? null : _testProvider,
            ),
            const SizedBox(width: T.s12),
            _ActionButton(
              label: _savingProvider ? '保存中' : '保存供应商',
              onTap: _savingProvider ? null : _saveProvider,
            ),
          ],
        ),
        const SizedBox(height: T.s16),
        Text('模型', style: T.tCaption),
        const SizedBox(height: T.s8),
        Wrap(
          spacing: T.s8,
          runSpacing: T.s8,
          children: [
            for (final item in provider.models.take(10))
              _ChoicePill(
                label: item,
                selected: item == model,
                onTap: () {
                  setState(() {
                    _selectedModel = item;
                    _model.text = item;
                  });
                },
              ),
            _InlineTextField(controller: _model, hint: '手动填写模型名'),
          ],
        ),
        const SizedBox(height: T.s16),
        Row(
          children: [
            _ActionButton(
              label: _savingDefault ? '保存中' : '设为翻译默认',
              strong: true,
              onTap: _savingDefault ? null : _saveTranslationDefault,
            ),
            const SizedBox(width: T.s12),
            _ActionButton(
              label: _loading ? '刷新中' : '刷新配置',
              onTap: _loading ? null : _loadConfig,
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        const Text(
          'API key 写入用户级 auth.json；provider YAML 只保存 credential_id、base_url 和模型名。',
          style: T.tCaption,
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
      children: [
        Text(_asrLabelForDraft(draft), style: T.tSection),
        const SizedBox(height: T.s12),
        if (kind == 'local_inprocess') ...[
          Row(
            children: [
              Expanded(child: _Input(label: '模型规格', controller: _model)),
              const SizedBox(width: T.s12),
              Expanded(child: _Input(label: '运算设备', controller: _device)),
            ],
          ),
          const SizedBox(height: T.s12),
          const Text('保存后由诊断入口确认模型和 GPU 可用性。', style: T.tCaption),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: _Input(
                  label: kind == 'local_server' ? '本地服务地址' : 'Base URL',
                  controller: _baseUrl,
                ),
              ),
              const SizedBox(width: T.s12),
              Expanded(child: _Input(label: '模型', controller: _model)),
            ],
          ),
          const SizedBox(height: T.s12),
          Row(
            children: [
              Expanded(child: _Input(label: 'Endpoint', controller: _endpoint)),
              const SizedBox(width: T.s12),
              Expanded(
                child: kind == 'remote'
                    ? _Input(
                        label: 'API key（留空则沿用）',
                        controller: _key,
                        obscure: true,
                      )
                    : const _ReadonlyRow(label: 'API key', value: '本地服务不需要 key'),
              ),
            ],
          ),
        ],
        const SizedBox(height: T.s12),
        Row(
          children: [
            _ActionButton(
              label: _savingAsr ? '保存中' : '保存识别默认',
              strong: true,
              onTap: _savingAsr ? null : _saveAsrProvider,
            ),
            const SizedBox(width: T.s12),
            _ActionButton(
              label: _loading ? '刷新中' : '刷新配置',
              onTap: _loading ? null : _loadConfig,
            ),
          ],
        ),
        const SizedBox(height: T.s8),
        const Text(
          '本机和 FunASR 不需要 key；云端 key 写入用户级 auth.json。',
          style: T.tCaption,
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
      _selectedModel = provider.models.isEmpty ? null : provider.models.first;
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
    final model = _selectedModel ?? snapshot?.translationModel;
    _baseUrl.text = provider.baseUrl;
    _model.text = model ?? (provider.models.isNotEmpty ? provider.models.first : '');
    _key.clear();
  }

  Future<void> _saveProvider() async {
    final provider = _selectedProvider;
    final model = _model.text.trim();
    if (provider == null || provider.isEmpty) {
      setState(() => _error = '需要先选择供应商');
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
        providerDraft: _translationDraft(providerName: provider, models: _mergedModels(model)),
        apiKey: _keyTextOrNull(),
        expectedVersion: _snapshot?.providersFileVersion,
      );
      _selectedModel = model;
      await _saveRouting(provider, model);
      await _loadConfig();
      if (!mounted) return;
      setState(() => _message = '供应商已保存，并已设为当前翻译默认。');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _savingProvider = false);
    }
  }

  Future<void> _saveTranslationDefault() async {
    final provider = _selectedProvider;
    final model = _model.text.trim().isNotEmpty
        ? _model.text.trim()
        : _selectedModel;
    if (provider == null || provider.isEmpty || model == null || model.isEmpty) {
      setState(() => _error = '需要先选择供应商和模型');
      return;
    }
    setState(() {
      _savingDefault = true;
      _error = null;
      _message = null;
    });
    try {
      await _saveRouting(provider, model);
      await _loadConfig();
      if (!mounted) return;
      setState(() => _message = '默认翻译已切换到 $provider · $model。');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _savingDefault = false);
    }
  }

  Future<void> _saveRouting(String provider, String model) async {
    final snapshot = _snapshot ?? await _client.desktopSnapshot();
    await _client.saveTranslationRouting(
      provider: provider,
      model: model,
      fallback: snapshot.translationFallback,
      expectedVersion: snapshot.providersFileVersion,
    );
    await widget.bridge.setTranslationDefault(provider, configured: true);
  }

  Future<void> _fetchModels() async {
    final provider = _selectedProvider;
    if (provider == null || provider.isEmpty) {
      setState(() => _error = '需要先选择供应商');
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
      final models = _stringList(result['models']);
      if (!mounted) return;
      setState(() {
        if (models.isNotEmpty) {
          _selectedModel = models.first;
          _model.text = models.first;
          _message = '已拉取到 ${models.length} 个模型，已选中第一个。';
        } else {
          _message = _stringValue(result['hint_zh']) ?? '没有解析到模型，可以手动填写模型名。';
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _testProvider() async {
    final provider = _selectedProvider;
    final model = _model.text.trim();
    if (provider == null || provider.isEmpty || model.isEmpty) {
      setState(() => _error = '需要先选择供应商和模型');
      return;
    }
    setState(() {
      _testingProvider = true;
      _error = null;
      _message = null;
    });
    try {
      final result = await _client.providerTest(
        providerDraft: _translationDraft(providerName: provider, models: _mergedModels(model)),
        model: model,
        apiKey: _keyTextOrNull(),
      );
      final status = _stringValue(result['status']) ?? 'UNKNOWN';
      final checks = _objectList(result['checks']);
      final first = checks.isEmpty ? const <String, Object?>{} : _stringMap(checks.first);
      if (!mounted) return;
      setState(() {
        _message = '$status：${_stringValue(first['hint_zh']) ?? _stringValue(first['message']) ?? '连接测试完成'}';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
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
      'base_url': _baseUrl.text.trim().isNotEmpty ? _baseUrl.text.trim() : provider.baseUrl,
      'models': models ?? _mergedModels(_model.text.trim()),
      'compat_mode': provider.compatMode.isNotEmpty ? provider.compatMode : 'openai_chat',
      'api_type': provider.apiType.isNotEmpty ? provider.apiType : 'openai-compatible',
      'credential_id': provider.credentialId.isNotEmpty ? provider.credentialId : providerName,
    };
  }

  List<String> _mergedModels(String model) {
    final provider = _selectedProvider == null || _snapshot == null
        ? const ProviderOption(name: '', models: [])
        : _providerByName(_snapshot!, _selectedProvider);
    final seen = <String>{};
    final merged = <String>[];
    for (final item in [if (model.isNotEmpty) model, ...provider.models]) {
      final trimmed = item.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed)) merged.add(trimmed);
    }
    return merged;
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
    final providerName = _selectedAsrProvider;
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
      await widget.bridge.setAsrDefault(_asrLabelForDraft(draft), configured: true);
      await _loadConfig();
      if (!mounted) return;
      setState(() => _message = '识别默认已保存：${_asrLabelForDraft(draft)}。');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _savingAsr = false);
    }
  }

  Map<String, Object?> _asrDraft(String providerName, {bool useEditedFields = true}) {
    final existing = _snapshot == null ? null : _asrProviderByName(_snapshot!, providerName);
    final hasExisting = existing != null && existing.name.isNotEmpty;
    final kind = hasExisting ? existing.kind : _defaultAsrKind(providerName);
    final protocol = hasExisting ? existing.protocol : _defaultAsrProtocol(kind, providerName);
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
        : (hasExisting && existing.endpoint.isNotEmpty ? existing.endpoint : '/v1/audio/transcriptions');
    final auth = hasExisting ? _stringMap(existing.raw['auth']) : const <String, Object?>{};
    final local = hasExisting ? Map<String, Object?>.from(_stringMap(existing.raw['local'])) : <String, Object?>{};
    local['model_size'] = model;
    local['device'] = _device.text.trim().isEmpty ? 'auto' : _device.text.trim();
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
            : {'type': 'bearer', 'env_key': 'OPENAI_API_KEY', 'credential_id': providerName}
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

  String _defaultAsrKind(String providerName) {
    if (providerName == 'faster_whisper_large_v3') return 'local_inprocess';
    if (providerName == 'funasr_sensevoice_local') return 'local_server';
    return 'remote';
  }

  String _defaultAsrProtocol(String kind, String providerName) {
    if (kind == 'local_inprocess') return 'faster_whisper';
    if (providerName == 'funasr_sensevoice_local') return 'funasr_openai';
    return 'openai_transcriptions';
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
      'local_server' => draft['protocol'] == 'funasr_openai' ? 'FunASR' : '本地服务',
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
            Flexible(child: Text(error!, style: T.tCaption.copyWith(color: T.danger), overflow: TextOverflow.ellipsis)),
          if (!busy && error == null && message != null)
            Flexible(child: Text(message!, style: T.tCaption.copyWith(color: T.accentStrong), overflow: TextOverflow.ellipsis)),
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
        const Text('供应商', style: T.tSection),
        const SizedBox(height: T.s12),
        if (providers.isEmpty)
          const Text('还没有 provider', style: T.tCaption)
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
                      if (provider.apiType.isNotEmpty) provider.apiType,
                      provider.hasKey ? '已配置' : '缺 key',
                    ].join(' · '),
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
                    detail: '${provider.model}${provider.hasKey ? ' · 已配置' : ' · 缺 key'}',
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

class _ToolPanel extends StatelessWidget {
  const _ToolPanel({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

class _Input extends StatelessWidget {
  const _Input({required this.label, required this.controller, this.obscure = false});
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
          contentPadding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(T.rSm),
            borderSide: const BorderSide(color: T.line),
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
        Expanded(child: Text(value, style: T.tBody, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}

class _ActionButton extends StatefulWidget {
  const _ActionButton({required this.label, required this.onTap, this.strong = false});
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
    final fg = widget.strong ? const Color(0xFFFFFFFF) : (enabled ? T.accentStrong : T.muted);
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
            border: Border.all(color: widget.strong ? bg : (enabled ? T.accent : T.line), width: 1.2),
          ),
          child: Text(widget.label, style: T.tBody.copyWith(color: fg, fontWeight: T.wMedium)),
        ),
      ),
    );
  }
}

class _ChoicePill extends StatefulWidget {
  const _ChoicePill({required this.label, required this.selected, required this.onTap});
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
            border: Border.all(color: widget.selected ? T.accent : T.line, width: 1),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.tCaption.copyWith(color: widget.selected ? T.accentStrong : T.ink),
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
              left: BorderSide(color: widget.selected ? color : const Color(0x00000000), width: 3),
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
                Text(widget.detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.tCaption),
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
          padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
          decoration: BoxDecoration(
            color: widget.selected || _hover ? T.accentSoft : T.surface,
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(color: widget.selected ? T.accent : T.line, width: 1.2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.label, style: T.tBody.copyWith(fontWeight: widget.selected ? T.wBold : T.wRegular)),
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
