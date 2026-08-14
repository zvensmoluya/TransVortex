part of '../models.dart';

class AsrProviderOption {
  const AsrProviderOption({
    required this.name,
    required this.kind,
    required this.protocol,
    required this.model,
    this.displayName = '',
    this.baseUrl = '',
    this.endpoint = '',
    this.hasKey = false,
    this.credentialId = '',
    this.credentialSource = '',
    this.readiness = const AsrReadiness(),
    this.engineSpec = const <String, Object?>{},
    this.capabilities = const <String, Object?>{},
    this.policyResolution = const <String, Object?>{},
    this.raw = const <String, Object?>{},
  });

  final String name;
  final String kind;
  final String protocol;
  final String model;
  final String displayName;
  final String baseUrl;
  final String endpoint;
  final bool hasKey;
  final String credentialId;
  final String credentialSource;
  final AsrReadiness readiness;
  final Map<String, Object?> engineSpec;
  final Map<String, Object?> capabilities;
  final Map<String, Object?> policyResolution;
  final Map<String, Object?> raw;

  factory AsrProviderOption.fromJson(Object? value, {String? id}) {
    final map = _stringMap(value);
    final name =
        id ?? _stringValue(map['id']) ?? _stringValue(map['name']) ?? '';
    final kind = _stringValue(map['kind']) ?? _inferKind(name);
    return AsrProviderOption(
      name: name,
      displayName: _stringValue(map['name']) ?? '',
      kind: kind,
      protocol: _stringValue(map['protocol']) ?? _inferProtocol(kind, name),
      model:
          _stringValue(map['model']) ??
          _stringValue(_stringMap(map['local'])['model_size']) ??
          '',
      baseUrl:
          _stringValue(map['base_url']) ?? _stringValue(map['baseUrl']) ?? '',
      endpoint: _stringValue(map['endpoint']) ?? '',
      hasKey: map['has_key'] == true || map['hasKey'] == true,
      credentialId:
          _stringValue(map['credential_id']) ??
          _stringValue(map['credentialId']) ??
          '',
      credentialSource:
          _stringValue(map['credential_source']) ??
          _stringValue(map['credentialSource']) ??
          '',
      readiness: AsrReadiness.fromJson(
        map['readiness'],
        legacyCanRun: map['has_key'] == true || map['hasKey'] == true,
      ),
      engineSpec: _stringMap(map['engine_spec']),
      capabilities: _stringMap(map['capabilities']),
      policyResolution: _stringMap(map['policy_resolution']),
      raw: map,
    );
  }

  String get displayLabel {
    return switch (kind) {
      'local_worker' || 'local_inprocess' => '本机 Whisper',
      'local_server' => protocol == 'funasr_openai' ? 'FunASR' : '本地服务',
      'remote' =>
        protocol == 'openai_transcriptions'
            ? 'OpenAI Whisper'
            : protocol == 'openrouter_stt'
            ? 'OpenRouter · ${_openRouterAsrModelLabel(model)}'
            : '云端识别',
      _ => displayName.isNotEmpty ? displayName : name,
    };
  }

  bool get canRun => readiness.canRun;

  static String _inferKind(String name) {
    final lower = name.toLowerCase();
    if (_looksLikeFasterWhisper(lower)) return 'local_worker';
    if (lower.contains('funasr')) return 'local_server';
    return 'remote';
  }

  static String _inferProtocol(String kind, String name) {
    final lower = name.toLowerCase();
    if (kind == 'local_worker' ||
        kind == 'local_inprocess' ||
        _looksLikeFasterWhisper(lower)) {
      return 'faster_whisper';
    }
    if (kind == 'local_server' || lower.contains('funasr')) {
      return 'funasr_openai';
    }
    if (lower.contains('openrouter')) return 'openrouter_stt';
    return 'openai_transcriptions';
  }

  static bool _looksLikeFasterWhisper(String lower) {
    return lower == 'local' ||
        lower.contains('faster_whisper') ||
        lower.contains('faster-whisper');
  }
}

String _openRouterAsrModelLabel(String model) {
  return switch (model.trim()) {
    'openai/whisper-large-v3' => 'Whisper Large V3',
    'x-ai/grok-stt-1.0' => 'Grok STT 1.0',
    _ => model.trim().isEmpty ? '语音识别' : model.trim(),
  };
}

class AsrReadiness {
  const AsrReadiness({
    this.state = 'unavailable',
    this.code = 'unknown',
    this.canRun = false,
    this.primaryAction = '',
    this.checkedAt = '',
    this.details = const <String, Object?>{},
  });

  final String state;
  final String code;
  final bool canRun;
  final String primaryAction;
  final String checkedAt;
  final Map<String, Object?> details;

  factory AsrReadiness.fromJson(Object? value, {bool legacyCanRun = false}) {
    final map = _stringMap(value);
    if (map.isEmpty) {
      return AsrReadiness(
        state: legacyCanRun ? 'ready' : 'unavailable',
        code: legacyCanRun ? 'legacy_ready' : 'unknown',
        canRun: legacyCanRun,
      );
    }
    return AsrReadiness(
      state: _stringValue(map['state']) ?? 'unavailable',
      code: _stringValue(map['code']) ?? 'unknown',
      canRun: map['can_run'] == true || map['canRun'] == true,
      primaryAction:
          _stringValue(map['primary_action']) ??
          _stringValue(map['primaryAction']) ??
          '',
      checkedAt:
          _stringValue(map['checked_at']) ??
          _stringValue(map['checkedAt']) ??
          '',
      details: _stringMap(map['details']),
    );
  }

  String get statusLabel {
    return switch (state) {
      'ready' => '可用',
      'checking' => '处理中',
      'needs_action' => _asrReadinessCodeLabel(code),
      _ => _asrReadinessCodeLabel(code),
    };
  }
}

class AsrStorageOption {
  const AsrStorageOption({
    this.root = '',
    this.defaultRoot = '',
    this.customized = false,
    this.totalBytes = 0,
    this.freeBytes = 0,
    this.reserveBytes = 0,
    this.spaceKnown = false,
    this.writable = false,
    this.canChange = false,
    this.changeBlocker = '',
    this.configError = '',
    this.diskError = '',
  });

  final String root;
  final String defaultRoot;
  final bool customized;
  final int totalBytes;
  final int freeBytes;
  final int reserveBytes;
  final bool spaceKnown;
  final bool writable;
  final bool canChange;
  final String changeBlocker;
  final String configError;
  final String diskError;

  factory AsrStorageOption.fromJson(Object? value) {
    final map = _stringMap(value);
    return AsrStorageOption(
      root: _stringValue(map['root']) ?? '',
      defaultRoot:
          _stringValue(map['default_root']) ??
          _stringValue(map['defaultRoot']) ??
          '',
      customized: map['customized'] == true,
      totalBytes:
          _intValue(map['total_bytes']) ?? _intValue(map['totalBytes']) ?? 0,
      freeBytes:
          _intValue(map['free_bytes']) ?? _intValue(map['freeBytes']) ?? 0,
      reserveBytes:
          _intValue(map['reserve_bytes']) ??
          _intValue(map['reserveBytes']) ??
          0,
      spaceKnown: map['space_known'] == true || map['spaceKnown'] == true,
      writable: map['writable'] == true,
      canChange: map['can_change'] == true || map['canChange'] == true,
      changeBlocker:
          _stringValue(map['change_blocker']) ??
          _stringValue(map['changeBlocker']) ??
          '',
      configError:
          _stringValue(map['config_error']) ??
          _stringValue(map['configError']) ??
          '',
      diskError:
          _stringValue(map['disk_error']) ??
          _stringValue(map['diskError']) ??
          '',
    );
  }

  int requiredBytesFor(int downloadBytes) {
    final normalized = downloadBytes < 0 ? 0 : downloadBytes;
    if (normalized == 0) return 0;
    final proportional = normalized ~/ 10;
    final safety = reserveBytes > proportional ? reserveBytes : proportional;
    return normalized + safety;
  }

  bool hasSpaceFor(int downloadBytes) {
    if (configError.isNotEmpty || diskError.isNotEmpty) return false;
    return !spaceKnown || freeBytes >= requiredBytesFor(downloadBytes);
  }
}

class AsrComponentOption {
  const AsrComponentOption({
    required this.id,
    required this.kind,
    this.displayName = '',
    this.version = '',
    this.revision = '',
    this.installed = false,
    this.published = true,
    this.size = 0,
    this.path = '',
    this.raw = const <String, Object?>{},
  });

  final String id;
  final String kind;
  final String displayName;
  final String version;
  final String revision;
  final bool installed;
  final bool published;
  final int size;
  final String path;
  final Map<String, Object?> raw;

  factory AsrComponentOption.fromJson(Object? value, {required String kind}) {
    final map = _stringMap(value);
    final artifact = _stringMap(map['artifact']);
    return AsrComponentOption(
      id: _stringValue(map['id']) ?? '',
      kind: kind,
      displayName:
          _stringValue(map['display_name']) ??
          _stringValue(map['displayName']) ??
          _stringValue(map['id']) ??
          '',
      version: _stringValue(map['version']) ?? '',
      revision: _stringValue(map['revision']) ?? '',
      installed: map['installed'] == true,
      published: artifact.isEmpty || artifact['published'] == true,
      size: _intValue(map['size']) ?? _intValue(artifact['size']) ?? 0,
      path: _stringValue(map['path']) ?? '',
      raw: map,
    );
  }
}

class AsrRegisteredResourceOption {
  const AsrRegisteredResourceOption({
    required this.id,
    required this.kind,
    this.resourceId = '',
    this.displayName = '',
    this.userLabel = '',
    this.path = '',
    this.root = '',
    this.version = '',
    this.ready = false,
    this.cudaAvailable = false,
    this.deviceCount = 0,
    this.computeTypes = const <String>[],
    this.probeDevice = '',
    this.probeComputeType = '',
    this.raw = const <String, Object?>{},
  });

  final String id;
  final String kind;
  final String resourceId;
  final String displayName;
  final String userLabel;
  final String path;
  final String root;
  final String version;
  final bool ready;
  final bool cudaAvailable;
  final int deviceCount;
  final List<String> computeTypes;
  final String probeDevice;
  final String probeComputeType;
  final Map<String, Object?> raw;

  String get effectiveLabel {
    final custom = userLabel.trim();
    if (custom.isNotEmpty) return custom;
    final detected = displayName.trim();
    if (detected.isNotEmpty) return detected;
    return resourceId;
  }

  factory AsrRegisteredResourceOption.fromJson(
    Object? value, {
    required String kind,
  }) {
    final map = _stringMap(value);
    final probe = _stringMap(map['probe']);
    final cuda = _stringMap(probe['cuda']);
    final model = _stringMap(probe['model']);
    return AsrRegisteredResourceOption(
      id: _stringValue(map['id']) ?? '',
      kind: kind,
      resourceId:
          _stringValue(map[kind == 'model' ? 'model_id' : 'accelerator_id']) ??
          '',
      displayName:
          _stringValue(map['display_name']) ??
          _stringValue(map['displayName']) ??
          '',
      userLabel:
          _stringValue(map['user_label']) ??
          _stringValue(map['userLabel']) ??
          '',
      path: _stringValue(map['model_path']) ?? '',
      root: _stringValue(map['root']) ?? '',
      version: _stringValue(map['version']) ?? '',
      ready: probe['ok'] == true,
      cudaAvailable: cuda['available'] == true,
      deviceCount: _intValue(cuda['device_count']) ?? 0,
      computeTypes: _stringList(cuda['compute_types']),
      probeDevice: _stringValue(model['device']) ?? '',
      probeComputeType: _stringValue(model['compute_type']) ?? '',
      raw: map,
    );
  }
}

class AsrActiveExecution {
  const AsrActiveExecution({
    this.provider = '',
    this.kind = '',
    this.model = '',
    this.requestedDevice = '',
    this.resolvedDevice = '',
    this.deviceResolution = '',
    this.computeType = '',
    this.canRun = false,
    this.modelSource = '',
    this.modelRegistrationId = '',
    this.modelPath = '',
    this.modelDisplayName = '',
    this.modelUserLabel = '',
    this.modelReady = false,
    this.acceleratorSource = '',
    this.acceleratorId = '',
    this.acceleratorRegistrationId = '',
    this.acceleratorRoot = '',
    this.acceleratorVersion = '',
    this.acceleratorState = '',
    this.acceleratorReady = false,
    this.cudaAvailable = false,
    this.cudaDeviceCount = 0,
    this.cudaComputeTypes = const <String>[],
    this.raw = const <String, Object?>{},
  });

  final String provider;
  final String kind;
  final String model;
  final String requestedDevice;
  final String resolvedDevice;
  final String deviceResolution;
  final String computeType;
  final bool canRun;
  final String modelSource;
  final String modelRegistrationId;
  final String modelPath;
  final String modelDisplayName;
  final String modelUserLabel;
  final bool modelReady;
  final String acceleratorSource;
  final String acceleratorId;
  final String acceleratorRegistrationId;
  final String acceleratorRoot;
  final String acceleratorVersion;
  final String acceleratorState;
  final bool acceleratorReady;
  final bool cudaAvailable;
  final int cudaDeviceCount;
  final List<String> cudaComputeTypes;
  final Map<String, Object?> raw;

  factory AsrActiveExecution.fromJson(Object? value) {
    final map = _stringMap(value);
    final model = _stringMap(map['model_resource']);
    final accelerator = _stringMap(map['accelerator']);
    final cuda = _stringMap(accelerator['cuda']);
    return AsrActiveExecution(
      provider: _stringValue(map['provider']) ?? '',
      kind: _stringValue(map['kind']) ?? '',
      model: _stringValue(map['model']) ?? '',
      requestedDevice: _stringValue(map['requested_device']) ?? '',
      resolvedDevice: _stringValue(map['resolved_device']) ?? '',
      deviceResolution: _stringValue(map['device_resolution']) ?? '',
      computeType: _stringValue(map['compute_type']) ?? '',
      canRun: map['can_run'] == true,
      modelSource: _stringValue(model['source']) ?? '',
      modelRegistrationId: _stringValue(model['registration_id']) ?? '',
      modelPath: _stringValue(model['path']) ?? '',
      modelDisplayName: _stringValue(model['display_name']) ?? '',
      modelUserLabel: _stringValue(model['user_label']) ?? '',
      modelReady: model['ready'] == true,
      acceleratorSource: _stringValue(accelerator['source']) ?? '',
      acceleratorId: _stringValue(accelerator['id']) ?? '',
      acceleratorRegistrationId:
          _stringValue(accelerator['registration_id']) ?? '',
      acceleratorRoot: _stringValue(accelerator['root']) ?? '',
      acceleratorVersion: _stringValue(accelerator['version']) ?? '',
      acceleratorState: _stringValue(accelerator['state']) ?? '',
      acceleratorReady: accelerator['ready'] == true,
      cudaAvailable: cuda['available'] == true,
      cudaDeviceCount: _intValue(cuda['device_count']) ?? 0,
      cudaComputeTypes: _stringList(cuda['compute_types']),
      raw: map,
    );
  }
}

class AsrModelCandidate {
  const AsrModelCandidate({
    required this.modelId,
    required this.path,
    this.displayName = '',
    this.relativePath = '',
    this.folderName = '',
    this.modelBytes = 0,
    this.catalogConfigMatch = false,
  });

  final String modelId;
  final String path;
  final String displayName;
  final String relativePath;
  final String folderName;
  final int modelBytes;
  final bool catalogConfigMatch;

  factory AsrModelCandidate.fromJson(Object? value) {
    final map = _stringMap(value);
    return AsrModelCandidate(
      modelId:
          _stringValue(map['model_id']) ?? _stringValue(map['modelId']) ?? '',
      path: _stringValue(map['path']) ?? '',
      displayName:
          _stringValue(map['display_name']) ??
          _stringValue(map['displayName']) ??
          '',
      relativePath:
          _stringValue(map['relative_path']) ??
          _stringValue(map['relativePath']) ??
          '',
      folderName:
          _stringValue(map['folder_name']) ??
          _stringValue(map['folderName']) ??
          '',
      modelBytes:
          _intValue(map['model_bytes']) ?? _intValue(map['modelBytes']) ?? 0,
      catalogConfigMatch:
          map['catalog_config_match'] == true ||
          map['catalogConfigMatch'] == true,
    );
  }
}

class AsrModelDiscovery {
  const AsrModelDiscovery({
    required this.ok,
    required this.root,
    this.code = '',
    this.message = '',
    this.candidates = const <AsrModelCandidate>[],
    this.scannedDirectories = 0,
    this.truncated = false,
  });

  final bool ok;
  final String root;
  final String code;
  final String message;
  final List<AsrModelCandidate> candidates;
  final int scannedDirectories;
  final bool truncated;

  factory AsrModelDiscovery.fromJson(Object? value) {
    final map = _stringMap(value);
    return AsrModelDiscovery(
      ok: map['ok'] == true,
      root: _stringValue(map['root']) ?? '',
      code: _stringValue(map['code']) ?? '',
      message: _stringValue(map['message']) ?? '',
      candidates: _objectList(map['candidates'])
          .map(AsrModelCandidate.fromJson)
          .where((item) => item.modelId.isNotEmpty && item.path.isNotEmpty)
          .toList(growable: false),
      scannedDirectories:
          _intValue(map['scanned_directories']) ??
          _intValue(map['scannedDirectories']) ??
          0,
      truncated: map['truncated'] == true,
    );
  }
}

class AsrOperationStatus {
  const AsrOperationStatus({
    required this.id,
    required this.kind,
    required this.itemId,
    required this.state,
    this.bytesDone = 0,
    this.bytesTotal = 0,
    this.currentFile = '',
    this.errorCode = '',
    this.message = '',
    this.phase = '',
    this.phaseIndex = 0,
    this.phaseCount = 0,
  });

  final String id;
  final String kind;
  final String itemId;
  final String state;
  final int bytesDone;
  final int bytesTotal;
  final String currentFile;
  final String errorCode;
  final String message;
  final String phase;
  final int phaseIndex;
  final int phaseCount;

  factory AsrOperationStatus.fromJson(Object? value) {
    final map = _stringMap(value);
    return AsrOperationStatus(
      id: _stringValue(map['id']) ?? '',
      kind: _stringValue(map['kind']) ?? '',
      itemId: _stringValue(map['item_id']) ?? _stringValue(map['itemId']) ?? '',
      state: _stringValue(map['state']) ?? 'unknown',
      bytesDone:
          _intValue(map['bytes_done']) ?? _intValue(map['bytesDone']) ?? 0,
      bytesTotal:
          _intValue(map['bytes_total']) ?? _intValue(map['bytesTotal']) ?? 0,
      currentFile:
          _stringValue(map['current_file']) ??
          _stringValue(map['currentFile']) ??
          '',
      errorCode:
          _stringValue(map['error_code']) ??
          _stringValue(map['errorCode']) ??
          '',
      message: _stringValue(map['message']) ?? '',
      phase: _stringValue(map['phase']) ?? '',
      phaseIndex:
          _intValue(map['phase_index']) ?? _intValue(map['phaseIndex']) ?? 0,
      phaseCount:
          _intValue(map['phase_count']) ?? _intValue(map['phaseCount']) ?? 0,
    );
  }

  bool get active => const {'queued', 'running', 'cancelling'}.contains(state);
  double? get progress => bytesTotal <= 0
      ? null
      : (bytesDone / bytesTotal).clamp(0.0, 1.0).toDouble();
}

class PythonEnvironmentOption {
  const PythonEnvironmentOption({
    required this.id,
    required this.pythonExecutable,
    this.source = '',
    this.probe = const <String, Object?>{},
    this.modelPaths = const <String, Object?>{},
  });

  final String id;
  final String pythonExecutable;
  final String source;
  final Map<String, Object?> probe;
  final Map<String, Object?> modelPaths;

  factory PythonEnvironmentOption.fromJson(Object? value) {
    final map = _stringMap(value);
    return PythonEnvironmentOption(
      id: _stringValue(map['id']) ?? '',
      pythonExecutable:
          _stringValue(map['python_executable']) ??
          _stringValue(map['pythonExecutable']) ??
          '',
      source: _stringValue(map['source']) ?? '',
      probe: _stringMap(map['probe']),
      modelPaths: _stringMap(map['model_paths']),
    );
  }
}

class MediaInspection {
  const MediaInspection({
    required this.kind,
    required this.sourceMode,
    required this.needsAsr,
    this.available = true,
    this.code = 'ready',
    this.audioStreams = const <Object?>[],
    this.selectedAudioStream = const <String, Object?>{},
    this.subtitleStreams = const <Object?>[],
    this.selectedSubtitleStream = const <String, Object?>{},
  });

  final String kind;
  final String sourceMode;
  final bool needsAsr;
  final bool available;
  final String code;
  final List<Object?> audioStreams;
  final Map<String, Object?> selectedAudioStream;
  final List<Object?> subtitleStreams;
  final Map<String, Object?> selectedSubtitleStream;

  factory MediaInspection.fromJson(Object? value) {
    final map = _stringMap(value);
    return MediaInspection(
      kind: _stringValue(map['kind']) ?? '',
      sourceMode:
          _stringValue(map['source_mode']) ??
          _stringValue(map['sourceMode']) ??
          '',
      needsAsr: map['needs_asr'] == true || map['needsAsr'] == true,
      available: map['available'] != false,
      code: _stringValue(map['code']) ?? 'ready',
      audioStreams: _objectList(map['audio_streams']),
      selectedAudioStream: _stringMap(map['selected_audio_stream']),
      subtitleStreams: _objectList(map['subtitle_streams']),
      selectedSubtitleStream: _stringMap(map['selected_subtitle_stream']),
    );
  }
}

String _asrReadinessCodeLabel(String code) {
  return switch (code) {
    'runtime_missing' => '组件未安装',
    'runtime_unpublished' => '组件尚未发布',
    'runtime_installing' => '正在安装组件',
    'model_missing' => '模型未安装',
    'model_installing' => '正在下载模型',
    'model_path_missing' => '需要选择模型目录',
    'model_path_unavailable' => '模型位置不可用',
    'model_unverified' => '已有模型尚未验证',
    'model_changed' => '模型文件发生变化',
    'model_mismatch' => '模型规格不匹配',
    'device_unavailable' => '加速组件不可用',
    'hardware_untested' => '需要检查 NVIDIA 硬件',
    'hardware_incompatible' => 'NVIDIA 硬件不兼容',
    'compute_type_incompatible' => '计算精度不兼容',
    'accelerator_installing' => '正在安装加速组件',
    'environment_missing' => '需要选择 Python 环境',
    'environment_unavailable' => 'Python 环境不可用',
    'environment_protocol_incompatible' => 'Python 环境协议不兼容',
    'connection_untested' => '需要测试连接',
    'service_unreachable' => '服务连接失败',
    'credential_missing' => '需要配置密钥',
    'config_invalid' => '配置无效',
    _ => code == 'ready' ? '可用' : '不可用',
  };
}

String? _routeProviderName(Object? primary) {
  final route = _stringMap(primary);
  return _stringValue(route['provider']) ?? _stringValue(primary);
}
