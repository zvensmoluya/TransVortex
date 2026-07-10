import 'package:flutter/foundation.dart';

import '../services/app_service_client.dart';
import '../services/settings_error.dart';

/// Sink used to mirror the active translation route back onto the main window
/// label (wired to `WindowStateBridge.setTranslationDefault`).
typedef TranslationLabelSink =
    Future<void> Function(String label, {required bool configured});

typedef TranslationConfigChangedSink = Future<void> Function();

/// Which half of the translation settings window is showing.
enum TranslationTab { connections, profiles }

/// A single in-flight action. Replaces the ~10 scattered boolean busy flags of
/// the legacy `_SettingsWindowState`: user interactions are serial, so one
/// pending action at a time is enough to drive button/disabled states.
enum TranslationBusy {
  idle,
  loading,
  savingConnection,
  deletingConnection,
  fetchingModels,
  testingConnection,
  savingProfile,
}

@immutable
class ConnectionTestResult {
  const ConnectionTestResult({
    required this.title,
    required this.detail,
    required this.ok,
  });

  final String title;
  final String detail;
  final bool ok;
}

/// A "connection → model" reference. Both the primary and every fallback route
/// are expressed with this type, so the routing tab never deals with free-text
/// model names — a model can only be picked from a saved connection.
@immutable
class ModelRef {
  const ModelRef({required this.connection, required this.model});

  final String connection;
  final String model;

  bool get isEmpty => connection.isEmpty && model.isEmpty;

  String get label {
    if (connection.isEmpty && model.isEmpty) return '未配置';
    if (model.isEmpty) return connection;
    return '$connection · $model';
  }

  @override
  bool operator ==(Object other) =>
      other is ModelRef &&
      other.connection == connection &&
      other.model == model;

  @override
  int get hashCode => Object.hash(connection, model);
}

/// Editable state for the connection currently shown in the connections tab.
/// `models` is a single list — the connection's supported models — which
/// removes the legacy `_model` ↔ `_selectedModel` dual source entirely.
class ConnectionDraft {
  bool creating = false;
  String? presetId;
  String? protocolId;
  String name = '';
  String baseUrl = '';
  String apiKey = '';
  List<String> models = <String>[];
  String modelInput = '';
  String? selectedModel;
  Map<String, ModelRuntimeDraft> modelConfigs = <String, ModelRuntimeDraft>{};

  void reset() {
    creating = false;
    presetId = null;
    protocolId = null;
    name = '';
    baseUrl = '';
    apiKey = '';
    models = <String>[];
    modelInput = '';
    selectedModel = null;
    modelConfigs = <String, ModelRuntimeDraft>{};
  }
}

class ModelRuntimeDraft {
  ModelRuntimeDraft({
    this.maxBatchLines = '',
    this.maxContextTokens = '',
    this.maxOutputTokens = '',
    this.recommendedOutputTokens = '',
    this.reasoningEffort = '',
    this.raw = const <String, Object?>{},
  });

  String maxBatchLines;
  String maxContextTokens;
  String maxOutputTokens;
  String recommendedOutputTokens;
  String reasoningEffort;
  final Map<String, Object?> raw;

  Map<String, Object?> toPayload() {
    final payload = <String, Object?>{...raw};
    void writeNumber(String key, String value) {
      payload.remove(switch (key) {
        'max_batch_lines' => 'maxBatchLines',
        'max_context_tokens' => 'maxContextTokens',
        'max_output_tokens' => 'maxOutputTokens',
        _ => 'recommendedOutputTokens',
      });
      final parsed = int.tryParse(value.trim()) ?? 0;
      if (parsed > 0) {
        payload[key] = parsed;
      } else {
        payload.remove(key);
      }
    }

    writeNumber('max_batch_lines', maxBatchLines);
    writeNumber('max_context_tokens', maxContextTokens);
    writeNumber('max_output_tokens', maxOutputTokens);
    writeNumber('recommended_output_tokens', recommendedOutputTokens);
    payload.remove('reasoningEffort');
    payload.remove('reasoning');
    if (reasoningEffort.trim().isEmpty) {
      payload.remove('reasoning_effort');
    } else {
      payload['reasoning_effort'] = reasoningEffort.trim();
    }
    return payload;
  }
}

/// Owns all state and side effects for the translation model settings window.
///
/// Compared with the legacy `_SettingsWindowState` this controller:
///  - keeps connection editing (providers) and routing (profiles) as two
///    independent concerns, so a control never means two things at once;
///  - saves connections and routes on separate paths and never does an
///    implicit provider save while editing a route;
///  - always writes routing through the profiles path (there is always at
///    least a synthesized `default` profile), so the single-route RPC is
///    unused from the desktop side.
class TranslationSettingsController extends ChangeNotifier {
  TranslationSettingsController(
    this._client,
    this._onLabel, {
    this.onConfigChanged,
  });

  final AppServiceClient _client;
  final TranslationLabelSink _onLabel;
  final TranslationConfigChangedSink? onConfigChanged;

  DesktopSnapshot? _snapshot;
  TranslationTab _tab = TranslationTab.connections;
  TranslationBusy _busy = TranslationBusy.idle;
  String? _message;
  String? _error;
  ConnectionTestResult? _testResult;
  String? _selectedConnection;
  final ConnectionDraft _draft = ConnectionDraft();

  // Bumped whenever the draft's text fields are replaced wholesale (selecting a
  // connection, entering/leaving create mode, picking a preset/protocol). The
  // view watches this to reseed its TextEditingControllers exactly once per
  // change instead of on every rebuild — that is what lets us drop the old
  // listener + `_updatingProviderName` suppression hack.
  int _draftRevision = 0;

  // ---- exposed state -------------------------------------------------------

  DesktopSnapshot? get snapshot => _snapshot;
  TranslationTab get tab => _tab;
  TranslationBusy get busy => _busy;
  bool get isBusy => _busy != TranslationBusy.idle;
  String? get message => _message;
  String? get error => _error;
  ConnectionTestResult? get testResult => _testResult;
  int get draftRevision => _draftRevision;

  List<ProviderOption> get connections => _snapshot?.providers ?? const [];
  String? get selectedConnection => _selectedConnection;
  ConnectionDraft get draft => _draft;
  String? get selectedModel => _draft.selectedModel;
  ModelRuntimeDraft? get selectedModelConfig {
    final model = _draft.selectedModel;
    return model == null ? null : _draft.modelConfigs[model];
  }

  List<String> get reasoningEfforts {
    final capabilities = _currentProviderCapabilities();
    final configured = _strList(
      capabilities['reasoning_efforts'] ?? capabilities['reasoningEfforts'],
    ).map((item) => item.trim()).where((item) => item.isNotEmpty).toList();
    final current = selectedModelConfig?.reasoningEffort.trim() ?? '';
    return _normalized([...configured, if (current.isNotEmpty) current]);
  }

  bool get supportsReasoningEffort {
    final capabilities = _currentProviderCapabilities();
    final param =
        (_str(
                  capabilities['reasoning_effort_param'] ??
                      capabilities['reasoningEffortParam'],
                ) ??
                '')
            .trim();
    return param.isNotEmpty || reasoningEfforts.isNotEmpty;
  }

  bool get creating => _draft.creating;
  bool get hasAnyConnection => connections.isNotEmpty;

  /// The provider row backing the current connection selection, or an empty
  /// placeholder when creating / nothing selected.
  ProviderOption get selectedProviderOption {
    final snapshot = _snapshot;
    if (snapshot == null || _selectedConnection == null) {
      return const ProviderOption(name: '', models: []);
    }
    return _providerByName(snapshot, _selectedConnection);
  }

  List<ProviderTemplateOption> get presetTemplates =>
      _snapshot?.providerPresets ?? const [];

  List<ProviderTemplateOption> get protocolTemplates {
    final snapshot = _snapshot;
    if (snapshot == null) return const [];
    return [
      ...snapshot.protocolTemplates,
      if (snapshot.customAdapterTemplate != null)
        snapshot.customAdapterTemplate!,
    ];
  }

  // routing (profiles) ----

  List<RoutingProfileOption> get profiles =>
      _snapshot?.routingProfiles ?? const [];

  String get activeProfileId => _snapshot?.activeRoutingProfile ?? 'default';

  RoutingProfileOption? get activeProfile {
    final snapshot = _snapshot;
    if (snapshot == null) return null;
    for (final profile in snapshot.routingProfiles) {
      if (profile.id == activeProfileId) return profile;
    }
    return snapshot.routingProfiles.isEmpty
        ? null
        : snapshot.routingProfiles.first;
  }

  String get activeProfileName {
    final profile = activeProfile;
    return profile == null ? '默认模型' : profileDisplayName(profile);
  }

  String profileDisplayName(RoutingProfileOption profile) {
    final name = profile.displayName.trim();
    if (profile.id == 'default' ||
        name.isEmpty ||
        name.toLowerCase() == 'default' ||
        name == '默认方案') {
      return '默认模型';
    }
    return name;
  }

  ModelRef? get primary {
    final profile = activeProfile;
    if (profile == null) return null;
    if (profile.provider.isEmpty && profile.model.isEmpty) return null;
    return ModelRef(connection: profile.provider, model: profile.model);
  }

  List<ModelRef> get fallback {
    final profile = activeProfile;
    if (profile == null) return const [];
    final routes = <ModelRef>[];
    for (final raw in profile.fallback) {
      final map = _map(raw);
      final provider = (_str(map['provider']) ?? '').trim();
      final model = (_str(map['model']) ?? '').trim();
      if (provider.isEmpty || model.isEmpty) continue;
      routes.add(ModelRef(connection: provider, model: model));
    }
    return routes;
  }

  /// Header text for the top bar: describes the active profile + primary model.
  String get headerText {
    final profile = activeProfile;
    final ref = primary;
    if (profile == null || ref == null) return '默认模型还没选主模型';
    final fallbackCount = fallback.length;
    final fallbackText = fallbackCount == 0 ? '无备用' : '备用 $fallbackCount 个';
    return '${profileDisplayName(profile)} · ${ref.model} · $fallbackText';
  }

  bool get configured =>
      _snapshot?.configReadiness.translationConfigured ?? false;

  // ---- lifecycle -----------------------------------------------------------

  Future<void> load() async {
    _busy = TranslationBusy.loading;
    _error = null;
    notifyListeners();
    try {
      final snapshot = await _client.desktopSnapshot();
      _snapshot = snapshot;
      _selectedConnection = _reconcileConnection(snapshot);
      if (!_draft.creating) {
        _loadDraftFromSelection();
      }
    } on Object catch (error) {
      _error = friendlySettingsError(error);
    } finally {
      _busy = TranslationBusy.idle;
      notifyListeners();
    }
  }

  Future<void> refresh() => load();

  void switchTab(TranslationTab tab) {
    if (_tab == tab) return;
    _tab = tab;
    _message = null;
    _error = null;
    notifyListeners();
  }

  /// Reconcile which connection should be selected after a reload. Explicit
  /// rules, replacing the legacy nested-ternary guessing:
  ///   keep the current selection if it still exists → else the routed primary
  ///   provider → else the first connection → else nothing.
  String? _reconcileConnection(DesktopSnapshot snapshot) {
    final names = snapshot.providers.map((p) => p.name).toSet();
    if (_draft.creating) return _selectedConnection;
    final current = _selectedConnection;
    if (current != null && names.contains(current)) return current;
    final routed = snapshot.translationProvider;
    if (routed != null && names.contains(routed)) return routed;
    return snapshot.providers.isEmpty ? null : snapshot.providers.first.name;
  }

  // ---- connection intents --------------------------------------------------

  void selectConnection(String name) {
    _draft.creating = false;
    _selectedConnection = name;
    _loadDraftFromSelection();
    _message = null;
    _error = null;
    _testResult = null;
    notifyListeners();
  }

  void startCreate() {
    final template = _defaultProviderTemplate(_snapshot);
    _draft.creating = true;
    _selectedConnection = null;
    _draft.presetId = template != null && _isPreset(template.id)
        ? template.id
        : null;
    _draft.protocolId = _protocolTemplateIdFor(template);
    _loadDraftFromTemplate(template);
    _message = null;
    _error = null;
    _testResult = null;
    _bumpDraft();
    notifyListeners();
  }

  void pickPreset(ProviderTemplateOption template) {
    _draft.presetId = template.id;
    _draft.protocolId = _protocolTemplateIdFor(template);
    _loadDraftFromTemplate(template);
    _message = null;
    _error = null;
    _testResult = null;
    _bumpDraft();
    notifyListeners();
  }

  void pickProtocol(ProviderTemplateOption template) {
    _draft.protocolId = template.id;
    final preset = _presetOption();
    if (preset == null || _draft.baseUrl.trim().isEmpty) {
      _draft.baseUrl = template.baseUrl;
    }
    if (_draft.models.isEmpty) {
      _draft.models = _normalized([...?preset?.models, ...template.models]);
      final merged = _mergedTemplate();
      _loadModelRuntimeDrafts(
        models: _draft.models,
        capabilities: merged?.capabilities ?? template.capabilities,
        modelConfigs: merged?.modelConfigs ?? template.modelConfigs,
        raw: merged?.raw ?? template.raw,
      );
    }
    _message = null;
    _error = null;
    _testResult = null;
    _bumpDraft();
    notifyListeners();
  }

  void startCustom() {
    final protocol = _protocolOption() ?? _defaultProtocolTemplate(_snapshot);
    _draft.presetId = null;
    _draft.protocolId = protocol?.id;
    _draft.name = _uniqueProviderName('custom_provider');
    _draft.baseUrl = protocol?.baseUrl ?? '';
    _draft.models = _normalized(protocol?.models ?? const []);
    _draft.apiKey = '';
    _draft.modelInput = '';
    _loadModelRuntimeDrafts(
      models: _draft.models,
      capabilities: protocol?.capabilities ?? const <String, Object?>{},
      modelConfigs:
          protocol?.modelConfigs ?? const <String, ModelRuntimeOption>{},
      raw: protocol?.raw ?? const <String, Object?>{},
    );
    _message = null;
    _error = null;
    _testResult = null;
    _bumpDraft();
    notifyListeners();
  }

  void editName(String value) => _draft.name = value;
  void editBaseUrl(String value) => _draft.baseUrl = value;
  void editApiKey(String value) => _draft.apiKey = value;
  void editModelInput(String value) => _draft.modelInput = value;

  void selectModel(String model) {
    if (!_draft.models.contains(model) || _draft.selectedModel == model) return;
    _draft.selectedModel = model;
    _ensureModelRuntimeDraft(model);
    _bumpDraft();
    notifyListeners();
  }

  void editModelMaxBatchLines(String value) {
    final config = selectedModelConfig;
    if (config != null) config.maxBatchLines = value;
  }

  void editModelMaxContextTokens(String value) {
    final config = selectedModelConfig;
    if (config != null) config.maxContextTokens = value;
  }

  void editModelMaxOutputTokens(String value) {
    final config = selectedModelConfig;
    if (config != null) config.maxOutputTokens = value;
  }

  void editModelRecommendedOutputTokens(String value) {
    final config = selectedModelConfig;
    if (config != null) config.recommendedOutputTokens = value;
  }

  void setModelReasoningEffort(String value) {
    final config = selectedModelConfig;
    if (config == null || config.reasoningEffort == value) return;
    config.reasoningEffort = value;
    notifyListeners();
  }

  void addModelFromInput() {
    final model = _draft.modelInput.trim();
    if (model.isEmpty) return;
    if (!_draft.models.contains(model)) {
      _draft.models = [..._draft.models, model];
    }
    _ensureModelRuntimeDraft(model);
    _draft.selectedModel = model;
    _draft.modelInput = '';
    _bumpDraft();
    notifyListeners();
  }

  void removeModel(String model) {
    final normalized = model.trim();
    if (_isModelReferencedByProfiles(_draftName(), normalized)) {
      _fail('这个模型正在被常用模型使用，请先修改主模型或备用模型。');
      return;
    }
    _draft.models = _draft.models.where((m) => m != model).toList();
    _draft.modelConfigs.remove(model);
    if (_draft.selectedModel == model) {
      _draft.selectedModel = _draft.models.isEmpty ? null : _draft.models.first;
    }
    _bumpDraft();
    notifyListeners();
  }

  Future<void> saveConnection() async {
    final name = _draftName();
    if (name.isEmpty) {
      _fail('连接名称不能为空');
      return;
    }
    final models = _draftModels();
    if (models.isEmpty) {
      _fail('连接至少要有一个模型');
      return;
    }
    final missingReferenced = _missingReferencedModels(name, models);
    if (missingReferenced.isNotEmpty) {
      _fail('这个模型正在被常用模型使用，请先修改主模型或备用模型。');
      return;
    }
    final modelConfigError = _validateModelRuntimeDrafts(models);
    if (modelConfigError != null) {
      _fail(modelConfigError);
      return;
    }
    _begin(TranslationBusy.savingConnection);
    try {
      await _client.providerSave(
        providerDraft: _connectionPayload(name, models),
        apiKey: _apiKeyOrNull(),
        expectedVersion: _snapshot?.providersFileVersion,
      );
      _draft.creating = false;
      _selectedConnection = name;
      await _reload();
      await _notifyConfigChanged();
      _message = '连接已保存。';
    } on Object catch (error) {
      _error = friendlySettingsError(error);
    } finally {
      _end();
    }
  }

  Future<void> deleteConnection() async {
    final snapshot = _snapshot;
    final name = _selectedConnection;
    if (snapshot == null || name == null || name.isEmpty) return;
    _begin(TranslationBusy.deletingConnection);
    try {
      final result = await _client.providerDelete(
        name: name,
        expectedVersion: snapshot.providersFileVersion,
      );
      if (result['blocked'] == true ||
          _str(result['code']) == 'provider_in_use') {
        _error = '这个连接正在被常用模型使用，请先修改主模型或备用模型。';
        return;
      }
      _selectedConnection = null;
      await _reload();
      await _notifyConfigChanged();
      _message = '连接已删除：$name。';
    } on Object catch (error) {
      _error = friendlySettingsError(error);
    } finally {
      _end();
    }
  }

  Future<void> fetchModels() async {
    final name = _draftName();
    if (name.isEmpty) {
      _fail('需要先填写连接名称');
      return;
    }
    _begin(TranslationBusy.fetchingModels);
    try {
      final result = await _client.providerModels(
        providerDraft: _connectionPayload(name, _draftModels()),
        apiKey: _apiKeyOrNull(),
      );
      final models = _normalized(_strList(result['models']));
      if (models.isNotEmpty) {
        _draft.models = _normalized([..._draft.models, ...models]);
        for (final model in _draft.models) {
          _ensureModelRuntimeDraft(model);
        }
        _draft.selectedModel ??= _draft.models.first;
        _bumpDraft();
        final hint = _str(result['hint_zh']);
        _message = hint == null || hint.isEmpty
            ? '已拉取到 ${models.length} 个模型，已并入模型清单。'
            : '$hint 已并入模型清单。';
      } else {
        _message = _str(result['hint_zh']) ?? '没有解析到模型，可以手动填写模型名。';
      }
    } on Object catch (error) {
      _error = friendlySettingsError(error);
    } finally {
      _end();
    }
  }

  Future<void> testConnection() async {
    final name = _draftName();
    final models = _draftModels();
    if (name.isEmpty || models.isEmpty) {
      _fail('需要先填写连接名称和至少一个模型');
      return;
    }
    _begin(TranslationBusy.testingConnection);
    _testResult = null;
    try {
      final result = await _client.providerTest(
        providerDraft: _connectionPayload(name, models),
        model: models.first,
        apiKey: _apiKeyOrNull(),
      );
      final status = _str(result['status']) ?? 'UNKNOWN';
      final checks = _list(result['checks']);
      final first = checks.isEmpty
          ? const <String, Object?>{}
          : _map(checks.first);
      final ok = status.toUpperCase() == 'PASS' || status.toUpperCase() == 'OK';
      _testResult = ConnectionTestResult(
        title: ok ? '测试通过' : '测试完成',
        detail:
            _str(first['hint_zh']) ?? _str(first['message']) ?? '模型服务已返回测试结果。',
        ok: ok,
      );
    } on Object catch (error) {
      _testResult = ConnectionTestResult(
        title: '测试未通过',
        detail: friendlySettingsError(error),
        ok: false,
      );
    } finally {
      _end();
    }
  }

  // ---- routing (profiles) intents -----------------------------------------

  Future<void> switchProfile(String id) async {
    final snapshot = _snapshot;
    if (snapshot == null || id == activeProfileId) return;
    final profiles = [for (final item in snapshot.routingProfiles) item.raw];
    await _saveProfiles(
      snapshot: snapshot,
      profiles: profiles,
      activeProfile: id,
      nextProfileSeq: snapshot.routingProfileNextSeq,
      messageBuilder: () => '已切换常用模型：$activeProfileName。',
      syncLabel: true,
    );
  }

  Future<void> renameProfile(String name) async {
    final snapshot = _snapshot;
    final profile = activeProfile;
    if (snapshot == null || profile == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _fail('常用模型名称不能为空');
      return;
    }
    await _saveProfiles(
      snapshot: snapshot,
      profiles: _profilePayloads(snapshot, profile.id, name: trimmed),
      activeProfile: profile.id,
      nextProfileSeq: snapshot.routingProfileNextSeq,
      messageBuilder: () => '常用模型已重命名：$trimmed。',
    );
  }

  Future<void> createProfile(String name) async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final current = activeProfile;
    final newId = _nextProfileId(snapshot);
    final desired = name.trim();
    final fallbackName = '常用模型 ${snapshot.routingProfileNextSeq}';
    final currentName = current == null ? '' : profileDisplayName(current);
    final finalName = _uniqueProfileName(
      snapshot,
      desired.isEmpty ||
              desired == current?.displayName ||
              desired == currentName
          ? fallbackName
          : desired,
    );
    final fallback = current?.fallback ?? snapshot.translationFallback;
    final profiles = [
      for (final item in snapshot.routingProfiles) _profilePayload(item),
      {
        'id': newId,
        'name': finalName,
        'primary': {
          'provider': current?.provider ?? '',
          'model': current?.model ?? '',
        },
        'fallback': fallback,
      },
    ];
    await _saveProfiles(
      snapshot: snapshot,
      profiles: profiles,
      activeProfile: newId,
      nextProfileSeq: snapshot.routingProfileNextSeq + 1,
      messageBuilder: () => '已新建常用模型：$finalName。',
      syncLabel: true,
    );
  }

  Future<void> deleteProfile() async {
    final snapshot = _snapshot;
    final profile = activeProfile;
    if (snapshot == null || profile == null) return;
    if (snapshot.routingProfiles.length <= 1) {
      _fail('至少保留一个常用模型');
      return;
    }
    final kept = snapshot.routingProfiles
        .where((item) => item.id != profile.id)
        .toList();
    final nextActive = kept.first;
    await _saveProfiles(
      snapshot: snapshot,
      profiles: [for (final item in kept) _profilePayload(item)],
      activeProfile: nextActive.id,
      nextProfileSeq: snapshot.routingProfileNextSeq,
      messageBuilder: () => '已删除常用模型：${profileDisplayName(profile)}。',
      syncLabel: true,
    );
  }

  Future<void> setPrimary(ModelRef ref) async {
    final snapshot = _snapshot;
    final profile = activeProfile;
    if (snapshot == null || profile == null) return;
    if (ref.connection.isEmpty || ref.model.isEmpty) {
      _fail('请选择连接和模型');
      return;
    }
    await _saveProfiles(
      snapshot: snapshot,
      profiles: _profilePayloads(
        snapshot,
        profile.id,
        provider: ref.connection,
        model: ref.model,
      ),
      activeProfile: profile.id,
      nextProfileSeq: snapshot.routingProfileNextSeq,
      messageBuilder: () => '主模型已设为 ${ref.label}。',
      syncLabel: true,
    );
  }

  Future<void> addFallback(ModelRef ref) async {
    final profile = activeProfile;
    if (profile == null) return;
    if (ref.connection.isEmpty || ref.model.isEmpty) {
      _fail('请选择连接和模型');
      return;
    }
    if (ref.connection == profile.provider && ref.model == profile.model) {
      _fail('这已经是主模型');
      return;
    }
    final routes = fallback;
    if (routes.contains(ref)) {
      _fail('这个备用模型已经在列表中');
      return;
    }
    await _saveFallback([...routes, ref], message: '已加入备用模型：${ref.label}。');
  }

  Future<void> removeFallback(int index) async {
    final routes = fallback;
    if (index < 0 || index >= routes.length) return;
    final removed = routes[index];
    routes.removeAt(index);
    await _saveFallback(routes, message: '已移除备用模型：${removed.label}。');
  }

  Future<void> moveFallback(int index, int direction) async {
    final routes = fallback;
    final target = index + direction;
    if (index < 0 ||
        index >= routes.length ||
        target < 0 ||
        target >= routes.length) {
      return;
    }
    final item = routes.removeAt(index);
    routes.insert(target, item);
    await _saveFallback(routes, message: '备用模型顺序已更新。');
  }

  Future<void> _saveFallback(
    List<ModelRef> routes, {
    required String message,
  }) async {
    final snapshot = _snapshot;
    final profile = activeProfile;
    if (snapshot == null || profile == null) return;
    await _saveProfiles(
      snapshot: snapshot,
      profiles: _profilePayloads(
        snapshot,
        profile.id,
        fallback: [
          for (final ref in routes)
            {'provider': ref.connection, 'model': ref.model},
        ],
      ),
      activeProfile: profile.id,
      nextProfileSeq: snapshot.routingProfileNextSeq,
      messageBuilder: () => message,
    );
  }

  // ---- draft / payload builders -------------------------------------------

  void _loadDraftFromSelection() {
    final provider = selectedProviderOption;
    _draft.presetId = null;
    _draft.protocolId = null;
    _draft.name = provider.name;
    _draft.baseUrl = provider.baseUrl;
    _draft.apiKey = '';
    _draft.models = _normalized(provider.models);
    _draft.modelInput = '';
    _loadModelRuntimeDrafts(
      models: _draft.models,
      capabilities: provider.capabilities,
      modelConfigs: provider.modelConfigs,
      raw: provider.raw,
    );
    _bumpDraft();
  }

  void _loadDraftFromTemplate(ProviderTemplateOption? template) {
    if (template == null) {
      _draft.name = '';
      _draft.baseUrl = '';
      _draft.models = <String>[];
      _draft.apiKey = '';
      _draft.modelInput = '';
      _draft.selectedModel = null;
      _draft.modelConfigs = <String, ModelRuntimeDraft>{};
      return;
    }
    _draft.name = _uniqueProviderName(_providerNameSeed(template));
    _draft.baseUrl = template.baseUrl;
    _draft.models = _normalized(template.models);
    _draft.apiKey = '';
    _draft.modelInput = '';
    _loadModelRuntimeDrafts(
      models: _draft.models,
      capabilities: template.capabilities,
      modelConfigs: template.modelConfigs,
      raw: template.raw,
    );
  }

  void _loadModelRuntimeDrafts({
    required List<String> models,
    required Map<String, Object?> capabilities,
    required Map<String, ModelRuntimeOption> modelConfigs,
    required Map<String, Object?> raw,
  }) {
    final providerReasoning = _providerReasoningEffort(raw);
    _draft.modelConfigs = {
      for (final model in models)
        model: _modelRuntimeDraft(
          modelConfigs[model],
          capabilities,
          providerReasoning,
        ),
    };
    final selected = _draft.selectedModel;
    _draft.selectedModel = selected != null && models.contains(selected)
        ? selected
        : (models.isEmpty ? null : models.first);
  }

  ModelRuntimeDraft _modelRuntimeDraft(
    ModelRuntimeOption? model,
    Map<String, Object?> capabilities,
    String providerReasoning,
  ) {
    String number(int explicit, String snake, String camel) {
      final inherited =
          _int(capabilities[snake]) ?? _int(capabilities[camel]) ?? 0;
      final value = explicit > 0 ? explicit : inherited;
      return value > 0 ? '$value' : '';
    }

    final maxOutputTokens = number(
      model?.maxOutputTokens ?? 0,
      'max_output_tokens',
      'maxOutputTokens',
    );
    var recommendedOutputTokens = number(
      model?.recommendedOutputTokens ?? 0,
      'recommended_output_tokens',
      'recommendedOutputTokens',
    );
    final maxOutput = int.tryParse(maxOutputTokens) ?? 0;
    final recommended = int.tryParse(recommendedOutputTokens) ?? 0;
    if (maxOutput > 0 && recommended > maxOutput) {
      recommendedOutputTokens = '$maxOutput';
    }

    return ModelRuntimeDraft(
      maxBatchLines: number(
        model?.maxBatchLines ?? 0,
        'max_batch_lines',
        'maxBatchLines',
      ),
      maxContextTokens: number(
        model?.maxContextTokens ?? 0,
        'max_context_tokens',
        'maxContextTokens',
      ),
      maxOutputTokens: maxOutputTokens,
      recommendedOutputTokens: recommendedOutputTokens,
      reasoningEffort: model?.reasoningEffort.trim().isNotEmpty == true
          ? model!.reasoningEffort.trim()
          : providerReasoning,
      raw: model?.raw ?? const <String, Object?>{},
    );
  }

  void _ensureModelRuntimeDraft(String model) {
    if (_draft.modelConfigs.containsKey(model)) return;
    _draft.modelConfigs[model] = _modelRuntimeDraft(
      null,
      _currentProviderCapabilities(),
      _providerReasoningEffort(_currentProviderRaw()),
    );
  }

  Map<String, Object?> _currentProviderCapabilities() {
    if (_draft.creating) {
      return _mergedTemplate()?.capabilities ?? const <String, Object?>{};
    }
    return selectedProviderOption.capabilities;
  }

  Map<String, Object?> _currentProviderRaw() {
    if (_draft.creating) {
      return _mergedTemplate()?.raw ?? const <String, Object?>{};
    }
    return selectedProviderOption.raw;
  }

  String _providerReasoningEffort(Map<String, Object?> raw) {
    final mapping = _map(raw['request_mapping'] ?? raw['requestMapping']);
    final overrides = _map(
      mapping['body_overrides'] ?? mapping['bodyOverrides'],
    );
    final reasoning = _map(overrides['reasoning']);
    return (_str(
              reasoning['effort'] ??
                  overrides['reasoning_effort'] ??
                  overrides['reasoningEffort'],
            ) ??
            '')
        .trim();
  }

  String? _validateModelRuntimeDrafts(List<String> models) {
    for (final model in models) {
      final config = _draft.modelConfigs[model];
      if (config == null) continue;
      for (final field in <(String, String)>[
        ('单批字幕行上限', config.maxBatchLines),
        ('上下文窗口', config.maxContextTokens),
        ('最大输出', config.maxOutputTokens),
        ('日常输出预算', config.recommendedOutputTokens),
      ]) {
        final raw = field.$2.trim();
        if (raw.isEmpty) continue;
        final value = int.tryParse(raw);
        if (value == null || value < 0) {
          return '$model 的${field.$1}必须是非负整数';
        }
      }
      final maxOutput = int.tryParse(config.maxOutputTokens.trim()) ?? 0;
      final recommended =
          int.tryParse(config.recommendedOutputTokens.trim()) ?? 0;
      if (maxOutput > 0 && recommended > maxOutput) {
        return '$model 的日常输出预算不能大于最大输出';
      }
    }
    return null;
  }

  String _draftName() => _draft.name.trim();

  List<String> _draftModels() {
    final input = _draft.modelInput.trim();
    return _normalized([..._draft.models, if (input.isNotEmpty) input]);
  }

  List<String> _missingReferencedModels(
    String connection,
    List<String> models,
  ) {
    final savedModels = models.toSet();
    return _referencedModels(
      connection,
    ).where((model) => !savedModels.contains(model)).toList();
  }

  bool _isModelReferencedByProfiles(String connection, String model) {
    if (connection.isEmpty || model.isEmpty) return false;
    return _referencedModels(connection).contains(model);
  }

  Set<String> _referencedModels(String connection) {
    final snapshot = _snapshot;
    if (snapshot == null || connection.isEmpty) return const <String>{};
    final referenced = <String>{};
    for (final profile in snapshot.routingProfiles) {
      if (profile.provider == connection && profile.model.isNotEmpty) {
        referenced.add(profile.model);
      }
      for (final raw in profile.fallback) {
        final route = _map(raw);
        final provider = (_str(route['provider']) ?? '').trim();
        final model = (_str(route['model']) ?? '').trim();
        if (provider == connection && model.isNotEmpty) {
          referenced.add(model);
        }
      }
    }
    return referenced;
  }

  /// The template describing the connection while creating (preset merged with
  /// protocol), used as the base of the save payload so protocol config
  /// (endpoint/auth/mapping) is carried through.
  ProviderOption _activeTemplateProvider() {
    final template = _mergedTemplate();
    if (template == null) return const ProviderOption(name: '', models: []);
    return ProviderOption(
      name: _draftName(),
      models: _normalized(template.models),
      baseUrl: template.baseUrl,
      envKey: template.envKey,
      apiType: template.apiType,
      compatMode: template.compatMode,
      credentialId: template.credentialId,
      credentialSource: 'missing',
      capabilities: template.capabilities,
      modelConfigs: template.modelConfigs,
      raw: template.raw,
    );
  }

  Map<String, Object?> _connectionPayload(String name, List<String> models) {
    final base = _draft.creating
        ? _activeTemplateProvider()
        : (_snapshot == null
              ? const ProviderOption(name: '', models: [])
              : _providerByName(_snapshot!, name));
    return {
      ...base.raw,
      'name': name,
      'base_url': _draft.baseUrl.trim().isNotEmpty
          ? _draft.baseUrl.trim()
          : base.baseUrl,
      'models': models,
      'model_configs': {
        for (final model in models)
          if (_draft.modelConfigs[model] case final config?)
            model: config.toPayload(),
      },
      'compat_mode': base.compatMode.isNotEmpty
          ? base.compatMode
          : 'openai_chat',
      'api_type': base.apiType.isNotEmpty ? base.apiType : 'openai-compatible',
      'env_key': base.envKey.isNotEmpty ? base.envKey : _defaultEnvKey(name),
      'credential_id': base.credentialId.isNotEmpty ? base.credentialId : name,
    };
  }

  Map<String, Object?> _profilePayload(
    RoutingProfileOption profile, {
    String? name,
    String? provider,
    String? model,
    List<Object?>? fallback,
  }) {
    return {
      ...profile.raw,
      'id': profile.id,
      'name': name ?? profile.displayName,
      'primary': {
        'provider': provider ?? profile.provider,
        'model': model ?? profile.model,
      },
      'fallback': fallback ?? profile.fallback,
    };
  }

  List<Map<String, Object?>> _profilePayloads(
    DesktopSnapshot snapshot,
    String updatingProfileId, {
    String? name,
    String? provider,
    String? model,
    List<Object?>? fallback,
  }) {
    return [
      for (final profile in snapshot.routingProfiles)
        profile.id == updatingProfileId
            ? _profilePayload(
                profile,
                name: name,
                provider: provider,
                model: model,
                fallback: fallback,
              )
            : _profilePayload(profile),
    ];
  }

  Future<void> _saveProfiles({
    required DesktopSnapshot snapshot,
    required List<Object?> profiles,
    required String activeProfile,
    required int nextProfileSeq,
    required String Function() messageBuilder,
    bool syncLabel = false,
  }) async {
    final before = _snapshot;
    if (before == null) return;
    _begin(TranslationBusy.savingProfile);
    _snapshot = _snapshotWithRouting(
      snapshot,
      profiles: profiles,
      activeProfile: activeProfile,
      nextProfileSeq: nextProfileSeq,
    );
    notifyListeners();
    try {
      final result = await _client.saveTranslationRoutingProfiles(
        profiles: profiles,
        activeProfile: activeProfile,
        nextProfileSeq: nextProfileSeq,
        expectedVersion: snapshot.providersFileVersion,
      );
      _snapshot = _snapshotWithRouting(
        _snapshot ?? snapshot,
        profiles: _list(result['routing_profiles']).isEmpty
            ? profiles
            : _list(result['routing_profiles']),
        activeProfile: _str(result['active_routing_profile']) ?? activeProfile,
        nextProfileSeq:
            _int(result['routing_profile_next_seq']) ?? nextProfileSeq,
        routing: _map(result['routing']).isEmpty
            ? null
            : _map(result['routing']),
        providersFileVersion: _map(result['providers_file_version']).isEmpty
            ? null
            : _map(result['providers_file_version']),
      );
      if (syncLabel) {
        final profile = _activeProfileOption(_snapshot);
        if (profile != null) {
          await _onLabel(
            profile.routeLabel,
            configured: profile.provider.isNotEmpty,
          );
        }
      }
      await _notifyConfigChanged();
      _message = messageBuilder();
    } on Object catch (error) {
      _snapshot = before;
      _error = friendlySettingsError(error);
    } finally {
      _end();
    }
  }

  RoutingProfileOption? _activeProfileOption(DesktopSnapshot? snapshot) {
    if (snapshot == null) return null;
    final active = snapshot.activeRoutingProfile;
    for (final profile in snapshot.routingProfiles) {
      if (profile.id == active) return profile;
    }
    return snapshot.routingProfiles.isEmpty
        ? null
        : snapshot.routingProfiles.first;
  }

  DesktopSnapshot _snapshotWithRouting(
    DesktopSnapshot snapshot, {
    required List<Object?> profiles,
    required String activeProfile,
    required int nextProfileSeq,
    Map<String, Object?>? routing,
    Map<String, Object?>? providersFileVersion,
  }) {
    final profileRows = [for (final item in profiles) _map(item)];
    final active = profileRows.firstWhere(
      (item) => _str(item['id']) == activeProfile,
      orElse: () =>
          profileRows.isEmpty ? const <String, Object?>{} : profileRows.first,
    );
    final activeId = _str(active['id']) ?? activeProfile;
    final activePrimary = _map(active['primary']);
    final activeFallback = _list(active['fallback']);
    final incomingRouting = routing ?? const <String, Object?>{};
    final primaryFromRouting = _map(incomingRouting['primary']);
    final fallbackFromRouting = _list(incomingRouting['fallback']);
    final hasRoutingFallback = incomingRouting.containsKey('fallback');
    final nextRouting = <String, Object?>{
      ..._map(snapshot.config['routing']),
      ...incomingRouting,
      'active_profile': activeId,
      'next_profile_seq': nextProfileSeq,
      'primary': primaryFromRouting.isEmpty
          ? activePrimary
          : primaryFromRouting,
      'fallback': hasRoutingFallback ? fallbackFromRouting : activeFallback,
    };
    final nextConfig = <String, Object?>{
      ...snapshot.config,
      'routing': nextRouting,
      'active_routing_profile': activeId,
      'routing_profile_next_seq': nextProfileSeq,
      'routing_profiles': profileRows,
      if (providersFileVersion != null && providersFileVersion.isNotEmpty)
        'providers_file_version': providersFileVersion,
    };
    return snapshot.copyWith(config: nextConfig);
  }

  // ---- template resolution (ported from the legacy state) -----------------

  ProviderTemplateOption? _mergedTemplate() {
    final snapshot = _snapshot;
    if (snapshot == null) return null;
    final preset = _presetOption();
    final protocol = _protocolOption();
    if (preset == null && protocol == null) {
      return _draft.creating ? null : _defaultProviderTemplate(snapshot);
    }
    if (preset == null) return protocol;
    if (protocol == null) return preset;
    return _mergeTemplates(preset, protocol);
  }

  ProviderTemplateOption? _presetOption() =>
      _presetById(_snapshot, _draft.presetId);

  ProviderTemplateOption? _protocolOption() {
    final snapshot = _snapshot;
    if (snapshot == null) return null;
    return _protocolById(snapshot, _draft.protocolId) ??
        _protocolById(snapshot, _protocolTemplateIdFor(_presetOption()));
  }

  ProviderTemplateOption _mergeTemplates(
    ProviderTemplateOption preset,
    ProviderTemplateOption protocol,
  ) {
    final sameProtocol =
        preset.protocolTemplateId == protocol.id ||
        preset.compatMode == protocol.compatMode;
    final raw = <String, Object?>{
      ...protocol.raw,
      ...preset.raw,
      'api_type': protocol.apiType,
      'compat_mode': protocol.compatMode,
      'endpoint': protocol.raw['endpoint'],
      'auth': protocol.raw['auth'],
      'request_mapping': sameProtocol
          ? (preset.raw['request_mapping'] ?? protocol.raw['request_mapping'])
          : protocol.raw['request_mapping'],
      'response_mapping': sameProtocol
          ? (preset.raw['response_mapping'] ?? protocol.raw['response_mapping'])
          : protocol.raw['response_mapping'],
      'model_list': protocol.raw['model_list'],
      'capabilities': protocol.raw['capabilities'],
      'protocol_template_id': protocol.id,
    };
    return ProviderTemplateOption.fromJson(raw);
  }

  ProviderTemplateOption? _presetById(DesktopSnapshot? snapshot, String? id) {
    if (snapshot == null || id == null || id.isEmpty) return null;
    for (final template in snapshot.providerPresets) {
      if (template.id == id) return template;
    }
    return null;
  }

  ProviderTemplateOption? _protocolById(DesktopSnapshot snapshot, String? id) {
    if (id == null || id.isEmpty) return null;
    for (final template in [
      ...snapshot.protocolTemplates,
      if (snapshot.customAdapterTemplate != null)
        snapshot.customAdapterTemplate!,
    ]) {
      if (template.id == id) return template;
    }
    return null;
  }

  bool _isPreset(String id) =>
      _snapshot?.providerPresets.any((t) => t.id == id) ?? false;

  String? _protocolTemplateIdFor(ProviderTemplateOption? template) {
    if (template == null) return null;
    if (template.protocolTemplateId.isNotEmpty) {
      return template.protocolTemplateId;
    }
    final snapshot = _snapshot;
    if (snapshot == null) return template.id;
    if (_protocolById(snapshot, template.id) != null) return template.id;
    for (final protocol in protocolTemplates) {
      if (protocol.compatMode.isNotEmpty &&
          protocol.compatMode == template.compatMode) {
        return protocol.id;
      }
    }
    return null;
  }

  ProviderTemplateOption? _defaultProviderTemplate(DesktopSnapshot? snapshot) {
    if (snapshot == null) return null;
    for (final template in snapshot.providerPresets) {
      if (template.id == 'deepseek') return template;
    }
    if (snapshot.providerPresets.isNotEmpty) {
      return snapshot.providerPresets.first;
    }
    if (snapshot.protocolTemplates.isNotEmpty) {
      return snapshot.protocolTemplates.first;
    }
    return snapshot.customAdapterTemplate;
  }

  ProviderTemplateOption? _defaultProtocolTemplate(DesktopSnapshot? snapshot) {
    if (snapshot == null) return null;
    for (final template in snapshot.protocolTemplates) {
      if (template.id == 'openai_chat') return template;
    }
    if (snapshot.protocolTemplates.isNotEmpty) {
      return snapshot.protocolTemplates.first;
    }
    return snapshot.customAdapterTemplate;
  }

  String _providerNameSeed(ProviderTemplateOption template) {
    return switch (template.id) {
      'openai_official' => 'openai',
      'anthropic_official' => 'anthropic',
      'google_ai_studio' => 'google_ai_studio',
      'google_vertex_gemini' => 'google_vertex_gemini',
      'google_vertex_openai' => 'google_vertex_openai',
      _ => template.id,
    };
  }

  String _uniqueProviderName(String seed) {
    final normalized = _providerNameSlug(seed);
    final used = connections.map((p) => p.name).toSet();
    if (!used.contains(normalized)) return normalized;
    for (var index = 2; index < 100; index += 1) {
      final candidate = '${normalized}_$index';
      if (!used.contains(candidate)) return candidate;
    }
    return normalized;
  }

  String _providerNameSlug(String value) {
    final lower = value.trim().toLowerCase();
    final slug = lower.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final trimmed = slug.replaceAll(RegExp(r'^_+|_+$'), '');
    return trimmed.isEmpty ? 'custom_provider' : trimmed;
  }

  String _defaultEnvKey(String name) {
    final slug = name
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return 'TVX_PROVIDER_${slug.isEmpty ? 'CUSTOM' : slug}_API_KEY';
  }

  String _uniqueProfileName(DesktopSnapshot snapshot, String seed) {
    final used = <String>{
      for (final profile in snapshot.routingProfiles) ...[
        profile.displayName.trim(),
        profileDisplayName(profile).trim(),
      ],
    }..removeWhere((name) => name.isEmpty);
    final base = seed.trim().isEmpty ? '常用模型' : seed.trim();
    if (!used.contains(base)) return base;
    for (var index = 2; index < 100; index += 1) {
      final candidate = '$base $index';
      if (!used.contains(candidate)) return candidate;
    }
    return base;
  }

  String _nextProfileId(DesktopSnapshot snapshot) {
    final seq = snapshot.routingProfileNextSeq <= 0
        ? snapshot.routingProfiles.length + 1
        : snapshot.routingProfileNextSeq;
    final used = snapshot.routingProfiles.map((p) => p.id).toSet();
    var candidate = 'route_$seq';
    var next = seq + 1;
    while (used.contains(candidate)) {
      candidate = 'route_$next';
      next += 1;
    }
    return candidate;
  }

  ProviderOption _providerByName(DesktopSnapshot snapshot, String? name) {
    return snapshot.providers.firstWhere(
      (provider) => provider.name == name,
      orElse: () => const ProviderOption(name: '', models: []),
    );
  }

  // ---- small utilities -----------------------------------------------------

  List<String> _normalized(List<String> models) {
    final seen = <String>{};
    final out = <String>[];
    for (final item in models) {
      final trimmed = item.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed)) out.add(trimmed);
    }
    return out;
  }

  String? _apiKeyOrNull() {
    final text = _draft.apiKey.trim();
    return text.isEmpty ? null : text;
  }

  void _bumpDraft() => _draftRevision += 1;

  void _begin(TranslationBusy busy) {
    _busy = busy;
    _error = null;
    _message = null;
    notifyListeners();
  }

  void _end() {
    _busy = TranslationBusy.idle;
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    notifyListeners();
  }

  Future<void> _notifyConfigChanged() async {
    final callback = onConfigChanged;
    if (callback == null) return;
    await callback();
  }

  Future<void> _reload() async {
    final snapshot = await _client.desktopSnapshot();
    _snapshot = snapshot;
    _selectedConnection = _reconcileConnection(snapshot);
    if (!_draft.creating) {
      _loadDraftFromSelection();
    }
  }

  static Map<String, Object?> _map(Object? value) =>
      value is Map ? value.map((k, v) => MapEntry('$k', v)) : const {};

  static List<Object?> _list(Object? value) => value is List ? value : const [];

  static List<String> _strList(Object? value) =>
      value is List ? [for (final item in value) '$item'] : const <String>[];

  static String? _str(Object? value) => value == null ? null : '$value';

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}');
  }
}
