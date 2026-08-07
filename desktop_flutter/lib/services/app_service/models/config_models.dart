part of '../models.dart';

class NetworkSettingsOption {
  const NetworkSettingsOption({this.mode = 'system', this.proxyPort = 0});

  final String mode;
  final int proxyPort;

  factory NetworkSettingsOption.fromJson(Object? value) {
    final map = _stringMap(value);
    final mode = (_stringValue(map['mode']) ?? 'system').trim().toLowerCase();
    return NetworkSettingsOption(
      mode: const {'system', 'direct', 'local_proxy'}.contains(mode)
          ? mode
          : 'system',
      proxyPort:
          _intValue(map['proxy_port']) ?? _intValue(map['proxyPort']) ?? 0,
    );
  }
}

class DesktopSnapshot {
  const DesktopSnapshot({
    required this.config,
    required this.tasks,
    required this.runtime,
    required this.environment,
    required this.raw,
  });

  final Map<String, Object?> config;
  final List<TaskSummary> tasks;
  final Map<String, Object?> runtime;
  final Map<String, Object?> environment;
  final Map<String, Object?> raw;

  factory DesktopSnapshot.fromJson(Object? value) {
    final map = _stringMap(value);
    return DesktopSnapshot(
      config: _stringMap(map['config']),
      tasks: parseTaskSummaries(map['tasks']),
      runtime: _stringMap(map['runtime']),
      environment: _stringMap(map['environment']),
      raw: map,
    );
  }

  DesktopSnapshot copyWith({
    Map<String, Object?>? config,
    List<TaskSummary>? tasks,
    Map<String, Object?>? runtime,
    Map<String, Object?>? environment,
    Map<String, Object?>? raw,
  }) {
    final nextConfig = config ?? this.config;
    return DesktopSnapshot(
      config: nextConfig,
      tasks: tasks ?? this.tasks,
      runtime: runtime ?? this.runtime,
      environment: environment ?? this.environment,
      raw: raw ?? {...this.raw, 'config': nextConfig},
    );
  }

  ConfigReadiness get configReadiness => ConfigReadiness.fromConfig(config);

  NetworkSettingsOption get networkSettings =>
      NetworkSettingsOption.fromJson(config['network']);

  List<ProviderOption> get providers {
    return _objectList(config['providers'])
        .map(ProviderOption.fromJson)
        .where((provider) => provider.name.isNotEmpty)
        .toList();
  }

  List<ProviderTemplateOption> get providerPresets {
    return _objectList(config['provider_presets'])
        .map(ProviderTemplateOption.fromJson)
        .where((template) => template.id.isNotEmpty)
        .toList();
  }

  List<ModelCatalogOption> get modelCatalog {
    return _objectList(config['model_catalog'])
        .map(ModelCatalogOption.fromJson)
        .where((entry) => entry.id.isNotEmpty)
        .toList();
  }

  List<ProviderTemplateOption> get protocolTemplates {
    return _objectList(config['protocol_templates'])
        .map(ProviderTemplateOption.fromJson)
        .where((template) => template.id.isNotEmpty)
        .toList();
  }

  ProviderTemplateOption? get customAdapterTemplate {
    final template = ProviderTemplateOption.fromJson(
      config['custom_adapter_template'],
    );
    return template.id.isEmpty ? null : template;
  }

  List<AsrProviderOption> get asrProviders {
    final source = _stringMap(config['asr_providers']);
    return source.entries
        .map((entry) => AsrProviderOption.fromJson(entry.value, id: entry.key))
        .where((provider) => provider.name.isNotEmpty)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  Map<String, Object?> get asrLocal => _stringMap(config['asr_local']);

  AsrStorageOption get asrStorage =>
      AsrStorageOption.fromJson(asrLocal['storage']);

  List<AsrComponentOption> get asrModels {
    return _objectList(asrLocal['models'])
        .map((item) => AsrComponentOption.fromJson(item, kind: 'model'))
        .where((item) => item.id.isNotEmpty)
        .toList(growable: false);
  }

  AsrComponentOption? get asrRuntime {
    final raw = _stringMap(asrLocal['runtime']);
    if (raw.isEmpty) return null;
    return AsrComponentOption.fromJson(raw, kind: 'runtime');
  }

  List<AsrComponentOption> get asrAccelerators {
    return _objectList(asrLocal['accelerators'])
        .map((item) => AsrComponentOption.fromJson(item, kind: 'accelerator'))
        .where((item) => item.id.isNotEmpty)
        .toList(growable: false);
  }

  List<AsrRegisteredResourceOption> get asrRegisteredAccelerators {
    return _objectList(asrLocal['registered_accelerators'])
        .map(
          (item) =>
              AsrRegisteredResourceOption.fromJson(item, kind: 'accelerator'),
        )
        .where((item) => item.id.isNotEmpty)
        .toList(growable: false);
  }

  List<AsrRegisteredResourceOption> get asrRegisteredModels {
    return _objectList(asrLocal['registered_models'])
        .map(
          (item) => AsrRegisteredResourceOption.fromJson(item, kind: 'model'),
        )
        .where((item) => item.id.isNotEmpty)
        .toList(growable: false);
  }

  AsrActiveExecution get asrActiveExecution =>
      AsrActiveExecution.fromJson(asrLocal['active_execution']);

  List<AsrOperationStatus> get asrOperations {
    return _objectList(asrLocal['operations'])
        .map(AsrOperationStatus.fromJson)
        .where((item) => item.id.isNotEmpty)
        .toList(growable: false);
  }

  List<PythonEnvironmentOption> get asrEnvironments {
    return _objectList(asrLocal['environments'])
        .map(PythonEnvironmentOption.fromJson)
        .where((item) => item.pythonExecutable.isNotEmpty)
        .toList(growable: false);
  }

  Map<String, Object?>? get providersFileVersion {
    final version = _stringMap(config['providers_file_version']);
    return version.isEmpty ? null : version;
  }

  Map<String, Object?>? get pipelineFileVersion {
    final direct = _stringMap(config['pipeline_file_version']);
    if (direct.isNotEmpty) return direct;
    final pipeline = _stringMap(config['pipeline']);
    final nested = _stringMap(pipeline['pipeline_file_version']);
    return nested.isEmpty ? null : nested;
  }

  TaskSummary? taskById(String taskId) {
    for (final task in tasks) {
      if (task.taskId == taskId) return task;
    }
    return null;
  }

  TaskSummary? get latestActiveTask {
    for (final task in tasks) {
      if (task.isRuntimeActive) return task;
    }
    for (final task in tasks) {
      if (task.isTerminal) return task;
    }
    return null;
  }

  String? get translationProvider {
    final routing = _stringMap(config['routing']);
    final primary = _stringMap(routing['primary']);
    return _stringValue(primary['provider']);
  }

  String? get translationModel {
    final routing = _stringMap(config['routing']);
    final primary = _stringMap(routing['primary']);
    return _stringValue(primary['model']);
  }

  String get activeRoutingProfile {
    final routing = _stringMap(config['routing']);
    final active =
        _stringValue(config['active_routing_profile']) ??
        _stringValue(routing['active_profile']);
    if (active != null && active.isNotEmpty) return active;
    final profiles = routingProfiles;
    return profiles.isEmpty ? 'default' : profiles.first.id;
  }

  int get routingProfileNextSeq {
    return _intValue(config['routing_profile_next_seq']) ?? 1;
  }

  List<RoutingProfileOption> get routingProfiles {
    final rows = _objectList(config['routing_profiles'])
        .map(RoutingProfileOption.fromJson)
        .where((profile) => profile.id.isNotEmpty)
        .toList();
    if (rows.isNotEmpty) return rows;
    final routing = _stringMap(config['routing']);
    final primary = _stringMap(routing['primary']);
    final provider = _stringValue(primary['provider']) ?? '';
    final model = _stringValue(primary['model']) ?? '';
    final reasoningEffort =
        _stringValue(primary['reasoning_effort']) ??
        _stringValue(primary['reasoningEffort']) ??
        'auto';
    if (provider.isEmpty && model.isEmpty) {
      return const <RoutingProfileOption>[];
    }
    return [
      RoutingProfileOption(
        id: 'default',
        name: 'Default',
        provider: provider,
        model: model,
        reasoningEffort: reasoningEffort,
        fallback: _objectList(routing['fallback']),
        raw: {
          'id': 'default',
          'name': 'Default',
          'primary': {
            'provider': provider,
            'model': model,
            'reasoning_effort': reasoningEffort,
          },
          'fallback': _objectList(routing['fallback']),
        },
      ),
    ];
  }

  List<Object?> get translationFallback {
    final routing = _stringMap(config['routing']);
    return _objectList(routing['fallback']);
  }

  String? get asrProviderName {
    final pipeline = _stringMap(config['pipeline']);
    return _stringValue(pipeline['asr_provider']);
  }

  String? get asrModel {
    final pipeline = _stringMap(config['pipeline']);
    final providerName = _stringValue(pipeline['asr_provider']);
    if (providerName == null) return null;
    final asrProviders = _stringMap(config['asr_providers']);
    final provider = _stringMap(asrProviders[providerName]);
    final local = _stringMap(provider['local']);
    return _stringValue(provider['model']) ??
        _stringValue(local['model_size']) ??
        _stringValue(provider['name']);
  }

  String? get asrLabel {
    final pipeline = _stringMap(config['pipeline']);
    final providerName = _stringValue(pipeline['asr_provider']);
    if (providerName == null) return null;
    final asrProviders = _stringMap(config['asr_providers']);
    final provider = AsrProviderOption.fromJson(
      asrProviders[providerName],
      id: providerName,
    );
    return provider.name.isEmpty ? providerName : provider.displayLabel;
  }
}

class ConfigReadiness {
  const ConfigReadiness({
    required this.translationConfigured,
    required this.translationLabel,
    required this.asrConfigured,
    required this.asrLabel,
    this.asrState = 'unavailable',
    this.asrCode = 'unknown',
    this.asrAction = '',
  });

  final bool translationConfigured;
  final String translationLabel;
  final bool asrConfigured;
  final String asrLabel;
  final String asrState;
  final String asrCode;
  final String asrAction;

  factory ConfigReadiness.fromConfig(Map<String, Object?> config) {
    final providers = _objectList(
      config['providers'],
    ).map(_stringMap).where((provider) => provider.isNotEmpty).toList();
    final routing = _stringMap(config['routing']);
    final primaryName = _routeProviderName(routing['primary']);
    final selectedProvider = providers.firstWhere(
      (provider) => _stringValue(provider['name']) == primaryName,
      orElse: () => const <String, Object?>{},
    );
    final translationLabel =
        _stringValue(selectedProvider['name']) ?? primaryName ?? '需配置';

    final pipeline = _stringMap(config['pipeline']);
    final selectedAsrName =
        _stringValue(pipeline['asr_provider']) ??
        _stringValue(pipeline['asrProvider']);
    final asrProviders = _stringMap(config['asr_providers']);
    final selectedAsr = selectedAsrName == null
        ? const <String, Object?>{}
        : _stringMap(asrProviders[selectedAsrName]);
    final asrOption = selectedAsrName == null
        ? null
        : AsrProviderOption.fromJson(selectedAsr, id: selectedAsrName);
    final asrLabel = asrOption == null || asrOption.name.isEmpty
        ? selectedAsrName ?? '需配置'
        : asrOption.displayLabel;
    final asrReadiness = AsrReadiness.fromJson(
      selectedAsr['readiness'],
      legacyCanRun: selectedAsr['has_key'] == true,
    );

    return ConfigReadiness(
      translationConfigured: selectedProvider['has_key'] == true,
      translationLabel: translationLabel,
      asrConfigured: asrReadiness.canRun,
      asrLabel: asrLabel,
      asrState: asrReadiness.state,
      asrCode: asrReadiness.code,
      asrAction: asrReadiness.primaryAction,
    );
  }
}

class RoutingProfileOption {
  const RoutingProfileOption({
    required this.id,
    required this.name,
    required this.provider,
    required this.model,
    this.reasoningEffort = 'auto',
    this.fallback = const <Object?>[],
    this.raw = const <String, Object?>{},
  });

  final String id;
  final String name;
  final String provider;
  final String model;
  final String reasoningEffort;
  final List<Object?> fallback;
  final Map<String, Object?> raw;

  factory RoutingProfileOption.fromJson(Object? value) {
    final map = _stringMap(value);
    final primary = _stringMap(map['primary']);
    final id = _stringValue(map['id']) ?? '';
    return RoutingProfileOption(
      id: id,
      name: _stringValue(map['name']) ?? id,
      provider: _stringValue(primary['provider']) ?? '',
      model: _stringValue(primary['model']) ?? '',
      reasoningEffort:
          _stringValue(primary['reasoning_effort']) ??
          _stringValue(primary['reasoningEffort']) ??
          'auto',
      fallback: _objectList(map['fallback']),
      raw: map,
    );
  }

  String get displayName => name.trim().isEmpty ? id : name;

  String get routeLabel {
    if (provider.isEmpty && model.isEmpty) return '未配置默认模型';
    if (model.isEmpty) return provider;
    return '$provider · $model';
  }
}

class ProviderTemplateOption {
  const ProviderTemplateOption({
    required this.id,
    required this.label,
    this.baseUrl = '',
    this.envKey = '',
    this.apiType = '',
    this.compatMode = '',
    this.credentialId = '',
    this.protocolTemplateId = '',
    this.models = const <String>[],
    this.capabilities = const <String, Object?>{},
    this.modelConfigs = const <String, ModelRuntimeOption>{},
    this.raw = const <String, Object?>{},
  });

  final String id;
  final String label;
  final String baseUrl;
  final String envKey;
  final String apiType;
  final String compatMode;
  final String credentialId;
  final String protocolTemplateId;
  final List<String> models;
  final Map<String, Object?> capabilities;
  final Map<String, ModelRuntimeOption> modelConfigs;
  final Map<String, Object?> raw;

  factory ProviderTemplateOption.fromJson(Object? value) {
    final map = _stringMap(value);
    final id = _stringValue(map['id']) ?? '';
    return ProviderTemplateOption(
      id: id,
      label: _stringValue(map['label']) ?? id,
      baseUrl:
          _stringValue(map['base_url']) ?? _stringValue(map['baseUrl']) ?? '',
      envKey: _stringValue(map['env_key']) ?? _stringValue(map['envKey']) ?? '',
      apiType:
          _stringValue(map['api_type']) ?? _stringValue(map['apiType']) ?? '',
      compatMode:
          _stringValue(map['compat_mode']) ??
          _stringValue(map['compatMode']) ??
          '',
      credentialId:
          _stringValue(map['credential_id']) ??
          _stringValue(map['credentialId']) ??
          '',
      protocolTemplateId:
          _stringValue(map['protocol_template_id']) ??
          _stringValue(map['protocolTemplateId']) ??
          '',
      models: _stringList(map['models']),
      capabilities: _stringMap(map['capabilities']),
      modelConfigs: _modelRuntimeOptions(
        map['model_configs'] ?? map['modelConfigs'],
      ),
      raw: map,
    );
  }
}

class ProviderOption {
  const ProviderOption({
    required this.name,
    required this.models,
    this.hasKey = false,
    this.baseUrl = '',
    this.envKey = '',
    this.apiType = '',
    this.compatMode = '',
    this.credentialId = '',
    this.credentialSource = '',
    this.capabilities = const <String, Object?>{},
    this.modelConfigs = const <String, ModelRuntimeOption>{},
    this.raw = const <String, Object?>{},
  });

  final String name;
  final List<String> models;
  final bool hasKey;
  final String baseUrl;
  final String envKey;
  final String apiType;
  final String compatMode;
  final String credentialId;
  final String credentialSource;
  final Map<String, Object?> capabilities;
  final Map<String, ModelRuntimeOption> modelConfigs;
  final Map<String, Object?> raw;

  factory ProviderOption.fromJson(Object? value) {
    final map = _stringMap(value);
    return ProviderOption(
      name: _stringValue(map['name']) ?? '',
      models: _stringList(map['models']),
      hasKey: map['has_key'] == true || map['hasKey'] == true,
      baseUrl:
          _stringValue(map['base_url']) ?? _stringValue(map['baseUrl']) ?? '',
      envKey: _stringValue(map['env_key']) ?? _stringValue(map['envKey']) ?? '',
      apiType:
          _stringValue(map['api_type']) ?? _stringValue(map['apiType']) ?? '',
      compatMode:
          _stringValue(map['compat_mode']) ??
          _stringValue(map['compatMode']) ??
          '',
      credentialId:
          _stringValue(map['credential_id']) ??
          _stringValue(map['credentialId']) ??
          '',
      credentialSource:
          _stringValue(map['credential_source']) ??
          _stringValue(map['credentialSource']) ??
          '',
      capabilities: _stringMap(map['capabilities']),
      modelConfigs: _modelRuntimeOptions(
        map['model_configs'] ?? map['modelConfigs'],
      ),
      raw: map,
    );
  }
}

class ModelRuntimeOption {
  const ModelRuntimeOption({
    this.maxBatchLines = 0,
    this.maxContextTokens = 0,
    this.maxInputTokens = 0,
    this.maxOutputTokens = 0,
    this.recommendedOutputTokens = 0,
    this.reasoningEffort = '',
    this.raw = const <String, Object?>{},
  });

  final int maxBatchLines;
  final int maxContextTokens;
  final int maxInputTokens;
  final int maxOutputTokens;
  final int recommendedOutputTokens;
  final String reasoningEffort;
  final Map<String, Object?> raw;

  factory ModelRuntimeOption.fromJson(Object? value) {
    final map = _stringMap(value);
    return ModelRuntimeOption(
      maxBatchLines:
          _intValue(map['max_batch_lines']) ??
          _intValue(map['maxBatchLines']) ??
          0,
      maxContextTokens:
          _intValue(map['max_context_tokens']) ??
          _intValue(map['maxContextTokens']) ??
          0,
      maxInputTokens:
          _intValue(map['max_input_tokens']) ??
          _intValue(map['maxInputTokens']) ??
          0,
      maxOutputTokens:
          _intValue(map['max_output_tokens']) ??
          _intValue(map['maxOutputTokens']) ??
          0,
      recommendedOutputTokens:
          _intValue(map['recommended_output_tokens']) ??
          _intValue(map['recommendedOutputTokens']) ??
          0,
      reasoningEffort:
          _stringValue(map['reasoning_effort']) ??
          _stringValue(map['reasoningEffort']) ??
          '',
      raw: map,
    );
  }
}

class ModelCatalogOption {
  const ModelCatalogOption({
    required this.id,
    required this.label,
    required this.vendor,
    required this.runtime,
    this.aliases = const <String>[],
    this.reasoningEfforts = const <String>[],
    this.maxInputTokens = 0,
    this.sourceLabel = '',
    this.sourceUrl = '',
    this.verifiedAt = '',
    this.pricing = const <String, Object?>{},
    this.raw = const <String, Object?>{},
  });

  final String id;
  final String label;
  final String vendor;
  final List<String> aliases;
  final List<String> reasoningEfforts;
  final int maxInputTokens;
  final ModelRuntimeOption runtime;
  final String sourceLabel;
  final String sourceUrl;
  final String verifiedAt;
  final Map<String, Object?> pricing;
  final Map<String, Object?> raw;

  factory ModelCatalogOption.fromJson(Object? value) {
    final map = _stringMap(value);
    return ModelCatalogOption(
      id: _stringValue(map['id']) ?? '',
      label: _stringValue(map['label']) ?? _stringValue(map['id']) ?? '',
      vendor: _stringValue(map['vendor']) ?? '',
      aliases: _stringList(map['aliases']),
      reasoningEfforts: _stringList(
        map['reasoning_efforts'] ?? map['reasoningEfforts'],
      ),
      maxInputTokens:
          _intValue(map['max_input_tokens']) ??
          _intValue(map['maxInputTokens']) ??
          0,
      runtime: ModelRuntimeOption.fromJson(map['runtime']),
      sourceLabel:
          _stringValue(map['source_label']) ??
          _stringValue(map['sourceLabel']) ??
          '',
      sourceUrl:
          _stringValue(map['source_url']) ??
          _stringValue(map['sourceUrl']) ??
          '',
      verifiedAt:
          _stringValue(map['verified_at']) ??
          _stringValue(map['verifiedAt']) ??
          '',
      pricing: _stringMap(map['pricing']),
      raw: map,
    );
  }

  bool matches(String modelId) {
    final normalized = modelId.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    return id.toLowerCase() == normalized ||
        aliases.any((alias) => alias.toLowerCase() == normalized);
  }
}

Map<String, ModelRuntimeOption> _modelRuntimeOptions(Object? value) {
  final map = _stringMap(value);
  return {
    for (final entry in map.entries)
      if (entry.key.trim().isNotEmpty)
        entry.key: ModelRuntimeOption.fromJson(entry.value),
  };
}
