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
  final _baseUrl = TextEditingController(text: 'https://api.example.com/v1');
  final _model = TextEditingController(text: 'opus-translation-latest');
  final _key = TextEditingController();
  final _note = TextEditingController(text: '中文输入验证：候选窗位置、组合输入、复制粘贴。');
  late final AppServiceClient _client = AppServiceClient(
    WindowBridgeTransport(widget.bridge),
  );
  DesktopSnapshot? _snapshot;
  String? _selectedProvider;
  String? _selectedModel;
  String? _selectedAsrProvider;
  String? _settingsError;
  String? _settingsMessage;
  bool _loadingConfig = false;
  bool _savingDefault = false;
  bool _savingProvider = false;
  bool _loadingModels = false;
  bool _testingProvider = false;
  bool _savingAsr = false;

  @override
  void initState() {
    super.initState();
    widget.bridge.initializeChild();
    widget.store.addListener(_refresh);
    _loadConfig();
  }

  @override
  void dispose() {
    widget.store.removeListener(_refresh);
    _baseUrl.dispose();
    _model.dispose();
    _key.dispose();
    _note.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  Future<void> _loadConfig() async {
    setState(() {
      _loadingConfig = true;
      _settingsError = null;
    });
    try {
      final snapshot = await _client.desktopSnapshot();
      if (!mounted) return;
      final provider = snapshot.translationProvider;
      final model = snapshot.translationModel;
      final providerOption = _providerByName(snapshot, provider);
      final selectedModel =
          model ??
          (providerOption.models.isNotEmpty
              ? providerOption.models.first
              : null);
      final asrProvider = snapshot.asrProviderName;
      setState(() {
        _snapshot = snapshot;
        _selectedProvider = provider;
        _selectedModel = selectedModel;
        _selectedAsrProvider = asrProvider;
        if (widget.type == SpikeWindowType.translationSettings &&
            providerOption.name.isNotEmpty) {
          _baseUrl.text = providerOption.baseUrl;
          _model.text = selectedModel ?? '';
          _key.clear();
        }
        if (widget.type == SpikeWindowType.asrSettings && asrProvider != null) {
          final asrOption = _asrProviderByName(snapshot, asrProvider);
          _baseUrl.text = asrOption.baseUrl;
          _model.text = asrOption.model;
          _key.clear();
        }
        if (provider != null) {
          widget.store.setTranslationDefault(
            provider,
            configured: snapshot.configReadiness.translationConfigured,
          );
        }
        if (asrProvider != null) {
          widget.store.setAsrDefault(
            snapshot.asrLabel ?? asrProvider,
            configured: snapshot.configReadiness.asrConfigured,
          );
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _settingsError = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingConfig = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTranslation = widget.type == SpikeWindowType.translationSettings;
    final title = isTranslation ? '翻译模型设置' : '语音识别设置';
    final status = isTranslation ? '多窗口 + 中文 IME 验证' : '引擎选择 + 中文 IME 验证';
    return Scaffold(
      backgroundColor: T.bg,
      body: Column(
        children: [
          TitleBar(title: title, status: status),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(T.s32, T.s16, T.s32, T.s24),
              child: isTranslation ? _translationBody() : _asrBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _translationBody() {
    final value = widget.store.value;
    final providers = _snapshot?.providers ?? const <ProviderOption>[];
    final selected = _selectedProvider ?? value.translationDefaultLabel;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 190,
          child: _FlatChoiceList(
            title: '供应商',
            selected: selected,
            items: providers.isEmpty
                ? const [_ChoiceItem(label: '需配置', warn: true)]
                : providers
                      .map(
                        (provider) => _ChoiceItem(
                          label: provider.name,
                          warn: !provider.hasKey,
                          detail: provider.models.isEmpty
                              ? '未配置模型'
                              : provider.models.first,
                        ),
                      )
                      .toList(),
            onPick: _pickProvider,
          ),
        ),
        const SizedBox(width: T.s32),
        Expanded(
          child: SingleChildScrollView(
            child: _FormColumn(
              header: '默认翻译：$selected',
              footer: _translationFooter(providers),
              busy: _loadingConfig || _savingDefault,
              error: _settingsError,
              fields: [
                _FieldSpec('Base URL', _baseUrl),
                _FieldSpec('模型名', _model),
                _FieldSpec('API key（留空则沿用已保存凭据）', _key, obscure: true),
                _FieldSpec('中文备注 / IME 验证', _note, maxLines: 2),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _translationFooter(List<ProviderOption> providers) {
    final provider = providers.firstWhere(
      (item) => item.name == _selectedProvider,
      orElse: () => const ProviderOption(name: '', models: []),
    );
    final models = provider.models;
    final model = _selectedModel ?? (models.isEmpty ? '' : models.first);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (models.isNotEmpty) ...[
          Text('模型', style: T.tCaption),
          const SizedBox(height: T.s4),
          Wrap(
            spacing: T.s8,
            runSpacing: T.s8,
            children: [
              for (final item in models.take(8))
                _MiniChoice(
                  label: item,
                  selected: item == model,
                  onTap: () => setState(() {
                    _selectedModel = item;
                    _model.text = item;
                  }),
                ),
            ],
          ),
          const SizedBox(height: T.s16),
        ],
        Row(
          children: [
            _InlineAction(
              label: _savingProvider ? '保存中' : '保存 provider',
              onTap: _savingProvider ? null : _saveProvider,
            ),
            const SizedBox(width: T.s12),
            _InlineAction(
              label: _loadingModels ? '拉取中' : '拉模型',
              onTap: _loadingModels ? null : _fetchModels,
            ),
            const SizedBox(width: T.s12),
            _InlineAction(
              label: _testingProvider ? '测试中' : '测试连接',
              onTap: _testingProvider ? null : _testProvider,
            ),
          ],
        ),
        const SizedBox(height: T.s12),
        Row(
          children: [
            _InlineAction(
              label: _savingDefault ? '保存中' : '设为翻译默认',
              onTap: _savingDefault ? null : _saveTranslationDefault,
            ),
            const SizedBox(width: T.s12),
            _InlineAction(
              label: _loadingConfig ? '刷新中' : '刷新配置',
              onTap: _loadingConfig ? null : _loadConfig,
            ),
          ],
        ),
        const SizedBox(height: T.s12),
        Text(
          _settingsMessage ??
              'API key 会写入用户级 auth.json；provider YAML 只保存 credential_id、base_url 和模型名。',
          style: T.tCaption,
        ),
      ],
    );
  }

  void _pickProvider(_ChoiceItem item) {
    if (item.warn) {
      widget.bridge.setTranslationDefault(item.label, configured: false);
      setState(() {
        _selectedProvider = item.label;
        _selectedModel = null;
        _settingsMessage = null;
      });
      return;
    }
    final provider = _snapshot?.providers.firstWhere(
      (row) => row.name == item.label,
      orElse: () => const ProviderOption(name: '', models: []),
    );
    final model = provider == null || provider.models.isEmpty
        ? null
        : provider.models.first;
    setState(() {
      _selectedProvider = item.label;
      _selectedModel = model;
      _baseUrl.text = provider?.baseUrl ?? '';
      _model.text = model ?? '';
      _key.clear();
      _settingsMessage = null;
    });
    widget.bridge.setTranslationDefault(item.label, configured: true);
  }

  Future<void> _saveProvider() async {
    final provider = _selectedProvider;
    final model = _model.text.trim();
    if (provider == null || provider.isEmpty || provider == '需配置') {
      setState(() => _settingsError = '需要先选择 provider');
      return;
    }
    if (model.isEmpty) {
      setState(() => _settingsError = '模型名不能为空');
      return;
    }
    setState(() {
      _savingProvider = true;
      _settingsError = null;
      _settingsMessage = null;
    });
    try {
      await _client.providerSave(
        providerDraft: _translationDraft(
          providerName: provider,
          models: _mergedModels(model),
        ),
        apiKey: _keyTextOrNull(),
        expectedVersion: _snapshot?.providersFileVersion,
      );
      _selectedModel = model;
      await _client.saveTranslationRouting(provider: provider, model: model);
      await widget.bridge.setTranslationDefault(provider, configured: true);
      await _loadConfig();
      if (!mounted) return;
      setState(() {
        _settingsMessage = 'provider 已保存，并已设为当前翻译默认。';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _settingsError = '$error');
    } finally {
      if (mounted) setState(() => _savingProvider = false);
    }
  }

  Future<void> _fetchModels() async {
    final provider = _selectedProvider;
    if (provider == null || provider.isEmpty || provider == '需配置') {
      setState(() => _settingsError = '需要先选择 provider');
      return;
    }
    setState(() {
      _loadingModels = true;
      _settingsError = null;
      _settingsMessage = null;
    });
    try {
      final result = await _client.providerModels(
        providerDraft: _translationDraft(providerName: provider),
        apiKey: _keyTextOrNull(),
      );
      final models = _stringList(result['models']);
      if (models.isNotEmpty) {
        setState(() {
          _model.text = models.first;
          _selectedModel = models.first;
          _settingsMessage = '已拉取到 ${models.length} 个模型，已选中第一个。';
        });
      } else {
        setState(() {
          _settingsMessage =
              _stringValue(result['hint_zh']) ?? '没有解析到模型，可以手动填写模型名。';
        });
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _settingsError = '$error');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _testProvider() async {
    final provider = _selectedProvider;
    final model = _model.text.trim();
    if (provider == null || provider.isEmpty || provider == '需配置') {
      setState(() => _settingsError = '需要先选择 provider');
      return;
    }
    if (model.isEmpty) {
      setState(() => _settingsError = '模型名不能为空');
      return;
    }
    setState(() {
      _testingProvider = true;
      _settingsError = null;
      _settingsMessage = null;
    });
    try {
      final result = await _client.providerTest(
        providerDraft: _translationDraft(
          providerName: provider,
          models: _mergedModels(model),
        ),
        model: model,
        apiKey: _keyTextOrNull(),
      );
      final status = _stringValue(result['status']) ?? 'UNKNOWN';
      final checks = _objectList(result['checks']);
      final first = checks.isEmpty
          ? const <String, Object?>{}
          : _stringMap(checks.first);
      setState(() {
        _settingsMessage =
            '$status：${_stringValue(first['hint_zh']) ?? _stringValue(first['message']) ?? '连接测试完成'}';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _settingsError = '$error');
    } finally {
      if (mounted) setState(() => _testingProvider = false);
    }
  }

  Future<void> _saveTranslationDefault() async {
    final provider = _selectedProvider;
    final model = _model.text.trim().isNotEmpty
        ? _model.text.trim()
        : _selectedModel;
    if (provider == null ||
        provider.isEmpty ||
        model == null ||
        model.isEmpty) {
      setState(() {
        _settingsError = '需要先选择 provider 和模型';
      });
      return;
    }
    setState(() {
      _savingDefault = true;
      _settingsError = null;
      _settingsMessage = null;
    });
    try {
      await _client.saveTranslationRouting(
        provider: provider,
        model: model,
        expectedVersion: _snapshot?.providersFileVersion,
      );
      await widget.bridge.setTranslationDefault(provider, configured: true);
      await _loadConfig();
      if (!mounted) return;
      setState(() => _settingsMessage = '默认翻译已切换到 $provider · $model。');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _settingsError = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingDefault = false;
        });
      }
    }
  }

  Widget _asrBody() {
    final value = widget.store.value;
    final snapshot = _snapshot;
    final providers = snapshot?.asrProviders ?? const <AsrProviderOption>[];
    final selected = _selectedAsrProvider ?? snapshot?.asrProviderName;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 210,
          child: _FlatChoiceList(
            title: '识别引擎',
            selected: _asrChoiceLabel(selected, value.asrDefaultLabel),
            items: _asrChoices(providers),
            onPick: _pickAsr,
          ),
        ),
        const SizedBox(width: T.s32),
        Expanded(
          child: SingleChildScrollView(
            child: _FormColumn(
              header:
                  '当前识别：${_asrHeaderLabel(selected, value.asrDefaultLabel)}',
              footer: _asrFooter(),
              busy: _loadingConfig || _savingAsr,
              error: _settingsError,
              fields: [
                _FieldSpec('Base URL / 本地服务地址', _baseUrl),
                _FieldSpec('模型名', _model),
                _FieldSpec('访问 key（云端留空则沿用已保存凭据）', _key, obscure: true),
                _FieldSpec('中文备注 / IME 验证', _note, maxLines: 2),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _asrFooter() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _InlineAction(
              label: _savingAsr ? '保存中' : '保存识别默认',
              onTap: _savingAsr ? null : _saveAsrProvider,
            ),
            const SizedBox(width: T.s12),
            _InlineAction(
              label: _loadingConfig ? '刷新中' : '刷新配置',
              onTap: _loadingConfig ? null : _loadConfig,
            ),
          ],
        ),
        const SizedBox(height: T.s12),
        Text(
          _settingsMessage ?? '本机和 FunASR 不需要 key；云端 key 会写入用户级 auth.json。',
          style: T.tCaption,
        ),
      ],
    );
  }

  List<_ChoiceItem> _asrChoices(List<AsrProviderOption> providers) {
    final choices = <_ChoiceItem>[
      const _ChoiceItem(
        label: '本机',
        detail: 'faster-whisper',
        value: 'faster_whisper_large_v3',
      ),
      const _ChoiceItem(
        label: 'FunASR',
        detail: '本地服务',
        value: 'funasr_sensevoice_local',
      ),
      const _ChoiceItem(
        label: '云端',
        detail: 'OpenAI Whisper',
        value: 'openai_whisper',
      ),
    ];
    for (final provider in providers) {
      if (choices.any((item) => item.value == provider.name)) continue;
      choices.add(
        _ChoiceItem(
          label: provider.displayLabel,
          detail: provider.name,
          warn: !provider.hasKey,
          value: provider.name,
        ),
      );
    }
    return choices;
  }

  void _pickAsr(_ChoiceItem item) {
    final providerName = item.value ?? item.label;
    final draft = _asrDraft(providerName, useEditedFields: false);
    setState(() {
      _selectedAsrProvider = providerName;
      _baseUrl.text = '${draft['base_url'] ?? ''}';
      _model.text = '${draft['model'] ?? ''}';
      _key.clear();
      _settingsMessage = null;
    });
    widget.bridge.setAsrDefault(item.label, configured: !item.warn);
  }

  Future<void> _saveAsrProvider() async {
    final providerName = _selectedAsrProvider ?? 'faster_whisper_large_v3';
    final draft = _asrDraft(providerName);
    setState(() {
      _savingAsr = true;
      _settingsError = null;
      _settingsMessage = null;
    });
    try {
      await _client.asrProviderSave(
        providerDraft: draft,
        apiKey: _keyTextOrNull(),
      );
      await widget.bridge.setAsrDefault(
        _asrLabelForDraft(draft),
        configured: true,
      );
      await _loadConfig();
      if (!mounted) return;
      setState(() => _settingsMessage = '识别默认已保存：${_asrLabelForDraft(draft)}。');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _settingsError = '$error');
    } finally {
      if (mounted) setState(() => _savingAsr = false);
    }
  }

  ProviderOption _providerByName(DesktopSnapshot snapshot, String? name) {
    return snapshot.providers.firstWhere(
      (provider) => provider.name == name,
      orElse: () => const ProviderOption(name: '', models: []),
    );
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
      'models': models ?? _mergedModels(_model.text.trim()),
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

  Map<String, Object?> _asrDraft(
    String providerName, {
    bool useEditedFields = true,
  }) {
    final existing = _snapshot == null
        ? null
        : _asrProviderByName(_snapshot!, providerName);
    final hasExisting = existing != null && existing.name.isNotEmpty;
    final kind = hasExisting ? existing.kind : _defaultAsrKind(providerName);
    final protocol = hasExisting
        ? existing.protocol
        : _defaultAsrProtocol(kind, providerName);
    final editedModel = useEditedFields ? _model.text.trim() : '';
    final editedBaseUrl = useEditedFields ? _baseUrl.text.trim() : '';
    final model = editedModel.isNotEmpty
        ? editedModel
        : (hasExisting ? existing.model : _defaultAsrModel(kind, protocol));
    final baseUrl = editedBaseUrl.isNotEmpty
        ? editedBaseUrl
        : (hasExisting ? existing.baseUrl : _defaultAsrBaseUrl(kind, protocol));
    final auth = hasExisting
        ? _stringMap(existing.raw['auth'])
        : const <String, Object?>{};
    final local = hasExisting
        ? Map<String, Object?>.from(_stringMap(existing.raw['local']))
        : <String, Object?>{};
    local['model_size'] = model;
    local.putIfAbsent('device', () => 'auto');
    return {
      if (hasExisting) ...existing.raw,
      'name': providerName,
      'kind': kind,
      'protocol': protocol,
      'model': model,
      if (kind != 'local_inprocess') 'base_url': baseUrl,
      if (kind != 'local_inprocess') 'endpoint': '/v1/audio/transcriptions',
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
      'local_server' =>
        draft['protocol'] == 'funasr_openai' ? 'FunASR' : '本地服务',
      'remote' => '云端',
      _ => '${draft['name']}',
    };
  }

  String _asrChoiceLabel(String? providerName, String fallback) {
    if (providerName == null || providerName.isEmpty) return fallback;
    return _asrLabelForDraft(_asrDraft(providerName, useEditedFields: false));
  }

  String _asrHeaderLabel(String? providerName, String fallback) {
    if (providerName == null || providerName.isEmpty) return fallback;
    final draft = _asrDraft(providerName, useEditedFields: false);
    return '${_asrLabelForDraft(draft)} · ${draft['model']}';
  }

  String? _keyTextOrNull() {
    final text = _key.text.trim();
    return text.isEmpty ? null : text;
  }
}

class _FlatChoiceList extends StatelessWidget {
  const _FlatChoiceList({
    required this.title,
    required this.selected,
    required this.items,
    required this.onPick,
  });

  final String title;
  final String selected;
  final List<_ChoiceItem> items;
  final ValueChanged<_ChoiceItem> onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: T.tSection),
        const SizedBox(height: T.s12),
        for (final item in items)
          _ChoiceRow(
            label: item.label,
            detail: item.detail,
            selected: item.label == selected,
            warn: item.warn,
            onTap: () => onPick(item),
          ),
      ],
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
          height: 40,
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

class _FormColumn extends StatelessWidget {
  const _FormColumn({
    required this.header,
    required this.fields,
    this.footer,
    this.busy = false,
    this.error,
  });

  final String header;
  final List<_FieldSpec> fields;
  final Widget? footer;
  final bool busy;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(header, style: T.tSection),
        if (busy) ...[
          const SizedBox(height: T.s8),
          Text('正在同步 Local Service…', style: T.tCaption),
        ],
        if (error != null) ...[
          const SizedBox(height: T.s8),
          Text(error!, style: T.tCaption.copyWith(color: T.danger)),
        ],
        const SizedBox(height: T.s16),
        for (final field in fields) ...[
          Text(field.label, style: T.tCaption),
          const SizedBox(height: T.s4),
          TextField(
            controller: field.controller,
            obscureText: field.obscure,
            maxLines: field.obscure ? 1 : field.maxLines,
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
          const SizedBox(height: T.s16),
        ],
        Text(
          'Phase A 只验证跨窗状态和中文输入；这里的表单控件是 spike 占位，不是最终配置窗设计。',
          style: T.tCaption,
        ),
        if (footer != null) ...[const SizedBox(height: T.s16), footer!],
      ],
    );
  }
}

class _ChoiceItem {
  const _ChoiceItem({
    required this.label,
    this.detail,
    this.warn = false,
    this.value,
  });

  final String label;
  final String? detail;
  final bool warn;
  final String? value;
}

class _MiniChoice extends StatefulWidget {
  const _MiniChoice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_MiniChoice> createState() => _MiniChoiceState();
}

class _MiniChoiceState extends State<_MiniChoice> {
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
          padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 5),
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

class _InlineAction extends StatefulWidget {
  const _InlineAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<_InlineAction> createState() => _InlineActionState();
}

class _InlineActionState extends State<_InlineAction> {
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
          padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: 7),
          decoration: BoxDecoration(
            color: _hover && enabled ? T.accentSoft : T.surface,
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(color: enabled ? T.accent : T.line, width: 1.2),
          ),
          child: Text(
            widget.label,
            style: T.tBody.copyWith(
              color: enabled ? T.accentStrong : T.muted,
              fontWeight: T.wMedium,
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldSpec {
  _FieldSpec(
    this.label,
    this.controller, {
    this.obscure = false,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final bool obscure;
  final int maxLines;
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
