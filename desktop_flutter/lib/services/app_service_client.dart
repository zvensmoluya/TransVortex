import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model/task_labels.dart';
import 'desktop_app_paths.dart';

abstract class AppServiceTransport {
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]);

  Future<void> close();
}

const Object _preserveFallback = Object();

class RpcRemoteException implements Exception {
  RpcRemoteException(this.code, this.message, {this.details});

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'RPC error $code: $message';
}

class RpcTimeoutException implements Exception {
  RpcTimeoutException(this.method, this.timeout);

  final String method;
  final Duration timeout;

  @override
  String toString() => 'RPC timeout calling $method after $timeout';
}

class RpcConnectionClosedException implements Exception {
  RpcConnectionClosedException(this.message);

  final String message;

  @override
  String toString() => message;
}

class JsonRpcTransport implements AppServiceTransport {
  JsonRpcTransport({
    required Stream<List<int>> stdout,
    required this.stdin,
    required Future<int> exitCode,
    Stream<List<int>>? stderr,
    this.defaultTimeout = const Duration(seconds: 8),
  }) {
    _stdoutSub = stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: (Object error) => _closeWith(
            RpcConnectionClosedException('service stdout failed: $error'),
          ),
          onDone: () =>
              _closeWith(RpcConnectionClosedException('service stdout closed')),
        );
    _stderrSub = stderr
        ?.transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          _diagnosticLines.add('stderr: $line');
          if (_diagnosticLines.length > 80) {
            _diagnosticLines.removeAt(0);
          }
        });
    unawaited(
      exitCode.then((code) {
        _exitCode = code;
        _closeWith(
          RpcConnectionClosedException('service exited with code $code'),
        );
      }),
    );
  }

  final IOSink stdin;
  final Duration defaultTimeout;
  final Map<int, _PendingRpc> _pending = {};
  final List<String> _diagnosticLines = [];
  late final StreamSubscription<String> _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  int _nextId = 1;
  int? _exitCode;
  bool _closed = false;

  bool get isClosed => _closed;

  int? get exitCode => _exitCode;

  List<String> get diagnosticLines => List.unmodifiable(_diagnosticLines);

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) {
    if (_closed) {
      return Future.error(RpcConnectionClosedException('service is closed'));
    }
    final id = _nextId++;
    final pending = _PendingRpc();
    _pending[id] = pending;
    final payload = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    };
    try {
      stdin.writeln(jsonEncode(payload));
      unawaited(stdin.flush());
    } on Object catch (error) {
      _pending.remove(id);
      return Future.error(
        RpcConnectionClosedException('failed to write request: $error'),
      );
    }

    final effectiveTimeout = timeout ?? defaultTimeout;
    Timer? timer;
    if (effectiveTimeout > Duration.zero) {
      timer = Timer(effectiveTimeout, () {
        final removed = _pending.remove(id);
        if (removed != null) {
          removed.completeError(RpcTimeoutException(method, effectiveTimeout));
        }
      });
    }
    return pending.future.whenComplete(() => timer?.cancel());
  }

  @override
  Future<void> close() async {
    _closed = true;
    for (final pending in _pending.values) {
      pending.completeError(RpcConnectionClosedException('service is closed'));
    }
    _pending.clear();
    await _stdoutSub.cancel();
    await _stderrSub?.cancel();
    try {
      await stdin.close();
    } on Object {
      // Closing is best effort during app shutdown.
    }
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      _diagnosticLines.add(line);
      if (_diagnosticLines.length > 80) {
        _diagnosticLines.removeAt(0);
      }
      return;
    }
    final response = decoded is Map ? decoded : null;
    final id = _intValue(response?['id']);
    if (id == null) {
      _diagnosticLines.add(line);
      if (_diagnosticLines.length > 80) {
        _diagnosticLines.removeAt(0);
      }
      return;
    }
    final pending = _pending.remove(id);
    if (pending == null) return;
    final error = response?['error'];
    if (error is Map) {
      pending.completeError(
        RpcRemoteException(
          '${error['code'] ?? 'remote_error'}',
          '${error['message'] ?? 'Remote error'}',
          details: error['details'],
        ),
      );
      return;
    }
    pending.complete(response?['result']);
  }

  void _closeWith(RpcConnectionClosedException error) {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
  }
}

typedef ProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

Future<Process> _defaultProcessStarter(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) {
  return Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
}

class LocalServiceLaunchException implements Exception {
  LocalServiceLaunchException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalServiceSupervisor {
  LocalServiceSupervisor({
    this.repoRoot,
    this.serviceRoot,
    this.appPaths,
    ProcessStarter? processStarter,
    this.pythonExecutable = 'python',
    this.requestTimeout = const Duration(seconds: 8),
  }) : _processStarter = processStarter ?? _defaultProcessStarter;

  final Directory? repoRoot;
  final Directory? serviceRoot;
  final DesktopAppPaths? appPaths;
  final ProcessStarter _processStarter;
  final String pythonExecutable;
  final Duration requestTimeout;

  Future<LocalServiceSession> start() async {
    final root = repoRoot ?? findRepoRoot();
    if (root == null) {
      throw LocalServiceLaunchException('找不到本地服务所需的仓库根目录');
    }
    final paths = appPaths ?? DesktopAppPaths.system();
    final explicitServiceRoot = serviceRoot;
    final runtimeRoot = explicitServiceRoot ?? paths.configRoot;
    final taskArtifactsRoot = explicitServiceRoot == null
        ? paths.tasksRoot
        : null;
    final taskCacheRoot = explicitServiceRoot == null ? paths.cacheRoot : null;
    if (explicitServiceRoot == null) {
      await _prepareDesktopRuntimeRoot(root, runtimeRoot);
    }
    if (taskArtifactsRoot != null) {
      await taskArtifactsRoot.create(recursive: true);
    }
    if (taskCacheRoot != null) {
      await taskCacheRoot.create(recursive: true);
    }
    final arguments = <String>[
      '-m',
      'transvortex.app_service',
      '--root',
      runtimeRoot.path,
      if (taskArtifactsRoot != null) ...[
        '--artifacts-dir',
        taskArtifactsRoot.path,
      ],
      if (taskCacheRoot != null) ...['--cache-dir', taskCacheRoot.path],
    ];
    final process = await _processStarter(
      pythonExecutable,
      arguments,
      workingDirectory: root.path,
      environment: {
        'PYTHONIOENCODING': 'utf-8',
        'PYTHONUTF8': '1',
        'PYTHONPATH': _pythonPath(root),
      },
    );
    final transport = JsonRpcTransport(
      stdout: process.stdout,
      stdin: process.stdin,
      stderr: process.stderr,
      exitCode: process.exitCode,
      defaultTimeout: requestTimeout,
    );
    return LocalServiceSession(
      process: process,
      transport: transport,
      client: AppServiceClient(transport),
    );
  }

  static Future<Directory> _prepareDesktopRuntimeRoot(
    Directory repoRoot,
    Directory runtimeRoot,
  ) async {
    if (!runtimeRoot.existsSync()) {
      await runtimeRoot.create(recursive: true);
    }
    await _copyConfigIfMissing(
      source: File('${repoRoot.path}${Platform.pathSeparator}pipeline.yaml'),
      target: File('${runtimeRoot.path}${Platform.pathSeparator}pipeline.yaml'),
      fallback: 'artifacts_dir: artifacts\n',
    );
    await _syncDesktopDefaultConfig(
      source: File('${repoRoot.path}${Platform.pathSeparator}providers.yaml'),
      target: File(
        '${runtimeRoot.path}${Platform.pathSeparator}providers.yaml',
      ),
      localOverride: File(
        '${runtimeRoot.path}${Platform.pathSeparator}providers.local.yaml',
      ),
    );
    return runtimeRoot;
  }

  static Future<void> _copyConfigIfMissing({
    required File source,
    required File target,
    String fallback = '',
  }) async {
    if (target.existsSync()) return;
    await target.parent.create(recursive: true);
    if (source.existsSync()) {
      await source.copy(target.path);
      return;
    }
    if (fallback.isNotEmpty) {
      await target.writeAsString(fallback);
    }
  }

  static Future<void> _syncDesktopDefaultConfig({
    required File source,
    required File target,
    required File localOverride,
    String fallback = '',
  }) async {
    if (localOverride.existsSync()) return;
    await target.parent.create(recursive: true);
    if (source.existsSync()) {
      await source.copy(target.path);
      return;
    }
    if (!target.existsSync() && fallback.isNotEmpty) {
      await target.writeAsString(fallback);
    }
  }

  static Directory? findRepoRoot() {
    final candidates = <Directory>[
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ];
    for (final start in candidates) {
      var cursor = start;
      while (true) {
        final marker = File(
          '${cursor.path}${Platform.pathSeparator}src'
          '${Platform.pathSeparator}transvortex'
          '${Platform.pathSeparator}app_service.py',
        );
        if (marker.existsSync()) return cursor;
        final parent = cursor.parent;
        if (parent.path == cursor.path) break;
        cursor = parent;
      }
    }
    return null;
  }

  static String _pythonPath(Directory root) {
    final entries = <String>[
      '${root.path}${Platform.pathSeparator}src',
      root.path,
      if ((Platform.environment['PYTHONPATH'] ?? '').trim().isNotEmpty)
        Platform.environment['PYTHONPATH']!,
    ];
    return entries.join(Platform.isWindows ? ';' : ':');
  }
}

abstract class LocalServiceHandle {
  AppServiceClient get client;

  Future<int> get exitCode;

  Future<void> shutdown({
    Duration rpcTimeout = const Duration(seconds: 2),
    Duration exitTimeout = const Duration(seconds: 2),
  });
}

class LocalServiceSession implements LocalServiceHandle {
  LocalServiceSession({
    required this.process,
    required this.transport,
    required this.client,
  });

  final Process process;
  final JsonRpcTransport transport;
  @override
  final AppServiceClient client;

  @override
  Future<int> get exitCode => process.exitCode;

  @override
  Future<void> shutdown({
    Duration rpcTimeout = const Duration(seconds: 2),
    Duration exitTimeout = const Duration(seconds: 2),
  }) async {
    try {
      await client.shutdown().timeout(rpcTimeout);
    } on Object {
      // Fall back to stream close / process termination below.
    }
    await transport.close();
    try {
      await process.exitCode.timeout(exitTimeout);
    } on TimeoutException {
      process.kill();
    }
  }
}

class AppServiceClient {
  AppServiceClient(this._transport);

  final AppServiceTransport _transport;

  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) {
    return _transport.call(method, params, timeout);
  }

  Future<ServiceInfo> info() async {
    return ServiceInfo.fromJson(await _transport.call('service.info'));
  }

  Future<ServiceHealth> health() async {
    return ServiceHealth.fromJson(await _transport.call('service.health'));
  }

  Future<DesktopSnapshot> desktopSnapshot() async {
    return DesktopSnapshot.fromJson(await _transport.call('desktop.snapshot'));
  }

  Future<RuntimeSnapshot> runtimeSnapshot() async {
    return RuntimeSnapshot.fromJson(await _transport.call('runtime.snapshot'));
  }

  Future<TaskSubmissionResult> submitRun(Map<String, Object?> request) async {
    return TaskSubmissionResult.fromJson(
      await _transport.call('runtime.submitRun', {'request': request}),
    );
  }

  Future<TaskSubmissionResult> submitResume(
    Map<String, Object?> request,
  ) async {
    return TaskSubmissionResult.fromJson(
      await _transport.call('runtime.submitResume', {'request': request}),
    );
  }

  Future<TaskSubmissionResult> retranslate(
    String taskId, {
    String? provider,
    String? model,
    Map<String, Object?>? routing,
    Map<String, Object?>? overrides,
  }) async {
    return TaskSubmissionResult.fromJson(
      await _transport.call('runtime.retranslate', {
        'task_id': taskId,
        'provider': ?provider,
        'model': ?model,
        'routing': ?routing,
        'overrides': ?overrides,
      }),
    );
  }

  Future<TaskSummary> cancel(String taskId, {bool force = false}) async {
    return TaskSummary.fromJson(
      await _transport.call('runtime.cancel', {
        'task_id': taskId,
        'force': force,
      }),
    );
  }

  Future<TaskEventsPage> taskEvents(
    String taskId, {
    int cursor = 0,
    int limit = 200,
  }) async {
    return TaskEventsPage.fromJson(
      await _transport.call('tasks.events', {
        'task_id': taskId,
        'cursor': cursor,
        'limit': limit,
      }),
    );
  }

  Future<List<TaskSummary>> taskList() async {
    return _taskList(await _transport.call('tasks.list'));
  }

  Future<Map<String, Object?>> authSet(String credentialId, String apiKey) {
    return call('auth.set', {
      'credential_id': credentialId,
      'api_key': apiKey,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> providerSave({
    required Map<String, Object?> providerDraft,
    String? apiKey,
    Map<String, Object?>? expectedVersion,
  }) {
    return call('provider.save', {
      'provider_draft': providerDraft,
      'api_key': ?apiKey,
      'expected_version': ?expectedVersion,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> providerDelete({
    required String name,
    Map<String, Object?>? expectedVersion,
  }) {
    return call('provider.delete', {
      'name': name,
      'expected_version': ?expectedVersion,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> providerModels({
    required Map<String, Object?> providerDraft,
    String? apiKey,
  }) {
    return call('provider.models', {
      'provider_draft': providerDraft,
      'api_key': ?apiKey,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> providerTest({
    required Map<String, Object?> providerDraft,
    required String model,
    String? apiKey,
  }) {
    return call('provider.test', {
      'provider_draft': providerDraft,
      'model': model,
      'api_key': ?apiKey,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> saveTranslationRouting({
    required String provider,
    required String model,
    Object? fallback = _preserveFallback,
    Map<String, Object?>? expectedVersion,
  }) {
    final params = <String, Object?>{
      'primary': {'provider': provider, 'model': model},
      'expected_version': ?expectedVersion,
    };
    if (!identical(fallback, _preserveFallback)) {
      params['fallback'] = fallback;
    }
    return call('provider.routing.save', params).then(_stringMap);
  }

  Future<Map<String, Object?>> saveTranslationRoutingProfiles({
    required List<Object?> profiles,
    required String activeProfile,
    int? nextProfileSeq,
    Map<String, Object?>? expectedVersion,
  }) {
    return call('provider.routing.save', {
      'profiles': profiles,
      'active_profile': activeProfile,
      'next_profile_seq': ?nextProfileSeq,
      'expected_version': ?expectedVersion,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> asrProviderSave({
    required Map<String, Object?> providerDraft,
    String? apiKey,
    Map<String, Object?>? expectedVersion,
  }) {
    return call('asr.provider.save', {
      'provider_draft': providerDraft,
      'api_key': ?apiKey,
      'expected_version': ?expectedVersion,
    }).then(_stringMap);
  }

  Future<Map<String, Object?>> asrProviderTest({
    String? provider,
    Map<String, Object?>? providerDraft,
    String sourceLang = 'en',
  }) {
    return call('asr.provider.test', {
      'provider': ?provider,
      'provider_draft': ?providerDraft,
      'source_lang': sourceLang,
    }).then(_stringMap);
  }

  Future<AsrOperationStatus> asrComponentInstall(
    String kind, {
    String? itemId,
  }) async {
    return AsrOperationStatus.fromJson(
      await call('asr.component.install', {'kind': kind, 'item_id': ?itemId}),
    );
  }

  Future<Map<String, Object?>> asrComponentRemove(
    String kind, {
    String? itemId,
  }) {
    return call('asr.component.remove', {
      'kind': kind,
      'item_id': ?itemId,
    }).then(_stringMap);
  }

  Future<AsrOperationStatus> asrOperation(String operationId) async {
    return AsrOperationStatus.fromJson(
      await call('asr.operation.get', {'operation_id': operationId}),
    );
  }

  Future<AsrOperationStatus> asrOperationCancel(String operationId) async {
    return AsrOperationStatus.fromJson(
      await call('asr.operation.cancel', {'operation_id': operationId}),
    );
  }

  Future<Map<String, Object?>> probeAsrHardware() {
    return call('asr.hardware.probe').then(_stringMap);
  }

  Future<List<PythonEnvironmentOption>> discoverAsrEnvironments() async {
    final payload = _stringMap(await call('asr.environment.discover'));
    return _objectList(payload['environments'])
        .map(PythonEnvironmentOption.fromJson)
        .where((item) => item.pythonExecutable.isNotEmpty)
        .toList(growable: false);
  }

  Future<Map<String, Object?>> probeAsrEnvironment({
    required String pythonExecutable,
    String? modelId,
    String? modelPath,
    String device = 'auto',
    String computeType = 'auto',
    bool save = true,
  }) {
    return call('asr.environment.probe', {
      'python_executable': pythonExecutable,
      'model_id': ?modelId,
      'model_path': ?modelPath,
      'device': device,
      'compute_type': computeType,
      'save': save,
    }, const Duration(minutes: 3)).then(_stringMap);
  }

  Future<MediaInspection> inspectMedia({
    required String input,
    String sourceLang = 'auto',
    String sourceMode = 'auto',
    String subtitleTrack = 'auto',
  }) async {
    return MediaInspection.fromJson(
      await call('media.inspect', {
        'input': input,
        'source_lang': sourceLang,
        'source_mode': sourceMode,
        'subtitle_track': subtitleTrack,
      }, const Duration(seconds: 30)),
    );
  }

  Future<Map<String, Object?>> resultOpen(String taskId) async {
    return _stringMap(
      await _transport.call('result.open', {'task_id': taskId}),
    );
  }

  Future<TaskResultWorkspace> openTaskResult(String taskId) async {
    return TaskResultWorkspace.fromJson(await resultOpen(taskId));
  }

  Future<TaskResultWorkspace> resultSegmentsSave(
    String taskId,
    List<Map<String, Object?>> segments,
  ) async {
    return TaskResultWorkspace.fromJson(
      await _transport.call('result.segments.save', {
        'task_id': taskId,
        'segments': segments,
      }),
    );
  }

  Future<Map<String, Object?>> resultReexport(
    String taskId, {
    String outputFormat = 'both',
    String? outputDir,
    bool bilingual = true,
    String? subtitleBilingualOrder,
    bool? subtitlePreferSingleLine,
  }) async {
    final params = <String, Object?>{
      'task_id': taskId,
      'output_format': outputFormat,
      'output_dir': ?outputDir,
      'bilingual': bilingual,
      'subtitle_bilingual_order': ?subtitleBilingualOrder,
      'subtitle_prefer_single_line': ?subtitlePreferSingleLine,
    };
    return _stringMap(await _transport.call('result.reexport', params));
  }

  Future<void> shutdown() async {
    await _transport.call(
      'service.shutdown',
      const {},
      const Duration(seconds: 2),
    );
  }
}

class ServiceInfo {
  const ServiceInfo({
    required this.service,
    required this.protocolVersion,
    required this.appVersion,
    required this.capabilities,
  });

  final String service;
  final int protocolVersion;
  final String appVersion;
  final List<String> capabilities;

  factory ServiceInfo.fromJson(Object? value) {
    final map = _stringMap(value);
    return ServiceInfo(
      service: _stringValue(map['service']) ?? 'unknown',
      protocolVersion: _intValue(map['protocol_version']) ?? 0,
      appVersion: _stringValue(map['app_version']) ?? 'unknown',
      capabilities: _stringList(map['capabilities']),
    );
  }
}

class ServiceHealth {
  const ServiceHealth({
    required this.service,
    required this.status,
    required this.runtime,
    required this.pump,
    this.error,
  });

  final String service;
  final String status;
  final Map<String, Object?> runtime;
  final Map<String, Object?> pump;
  final String? error;

  factory ServiceHealth.fromJson(Object? value) {
    final map = _stringMap(value);
    return ServiceHealth(
      service: _stringValue(map['service']) ?? 'unknown',
      status: _stringValue(map['status']) ?? 'unknown',
      runtime: _stringMap(map['runtime']),
      pump: _stringMap(map['pump']),
      error: _stringValue(map['error']),
    );
  }

  bool get degraded {
    final lastError = _stringValue(pump['last_error']);
    return status == 'degraded' || (lastError != null && lastError.isNotEmpty);
  }

  Map<String, Object?> get active {
    return _stringMap(runtime['active']);
  }

  String get activeTaskLabel {
    final taskId =
        _stringValue(active['task_id']) ?? _stringValue(active['taskId']);
    final status = _stringValue(active['status']);
    if (taskId == null || taskId.isEmpty) return '无活动任务';
    final taskLabel = shortTaskIdLabel(taskId);
    if (status == null || status.trim().isEmpty) return taskLabel;
    return '$taskLabel · ${taskStatusLabel(status)}';
  }

  String get pumpLabel {
    final enabled = pump['enabled'] == true;
    final lastError = _stringValue(pump['last_error']);
    if (!enabled) return 'disabled';
    if (lastError != null && lastError.isNotEmpty) return 'degraded';
    return 'running';
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
      tasks: _taskList(map['tasks']),
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
    if (provider.isEmpty && model.isEmpty) {
      return const <RoutingProfileOption>[];
    }
    return [
      RoutingProfileOption(
        id: 'default',
        name: 'Default',
        provider: provider,
        model: model,
        fallback: _objectList(routing['fallback']),
        raw: {
          'id': 'default',
          'name': 'Default',
          'primary': {'provider': provider, 'model': model},
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
    this.fallback = const <Object?>[],
    this.raw = const <String, Object?>{},
  });

  final String id;
  final String name;
  final String provider;
  final String model;
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
      raw: map,
    );
  }

  String get displayLabel {
    return switch (kind) {
      'local_worker' || 'local_inprocess' => '本机 Whisper',
      'local_server' => protocol == 'funasr_openai' ? 'FunASR' : '本地服务',
      'remote' => '云端',
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
    return 'openai_transcriptions';
  }

  static bool _looksLikeFasterWhisper(String lower) {
    return lower == 'local' ||
        lower.contains('faster_whisper') ||
        lower.contains('faster-whisper');
  }
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
    this.subtitleStreams = const <Object?>[],
    this.selectedSubtitleStream = const <String, Object?>{},
  });

  final String kind;
  final String sourceMode;
  final bool needsAsr;
  final bool available;
  final String code;
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

class TaskEventsPage {
  const TaskEventsPage({
    required this.taskId,
    required this.events,
    required this.cursor,
    required this.nextCursor,
    required this.hasMore,
  });

  final String taskId;
  final List<Object?> events;
  final int cursor;
  final int nextCursor;
  final bool hasMore;

  factory TaskEventsPage.fromJson(Object? value) {
    final map = _stringMap(value);
    return TaskEventsPage(
      taskId: _stringValue(map['task_id']) ?? _stringValue(map['taskId']) ?? '',
      events: _objectList(map['events']),
      cursor: _intValue(map['cursor']) ?? 0,
      nextCursor:
          _intValue(map['next_cursor']) ?? _intValue(map['nextCursor']) ?? 0,
      hasMore: map['has_more'] == true || map['hasMore'] == true,
    );
  }
}

class TaskSubmissionResult {
  const TaskSubmissionResult({
    required this.ok,
    required this.taskId,
    required this.status,
    required this.taskDir,
    required this.terminal,
    required this.message,
    this.raw = const <String, Object?>{},
  });

  final bool ok;
  final String taskId;
  final String status;
  final String taskDir;
  final bool terminal;
  final String message;
  final Map<String, Object?> raw;

  factory TaskSubmissionResult.fromJson(Object? value) {
    final map = _stringMap(value);
    return TaskSubmissionResult(
      ok: map['ok'] == true,
      taskId: _stringValue(map['task_id']) ?? _stringValue(map['taskId']) ?? '',
      status: _stringValue(map['status']) ?? 'unknown',
      taskDir:
          _stringValue(map['task_dir']) ?? _stringValue(map['taskDir']) ?? '',
      terminal: map['terminal'] == true,
      message: _stringValue(map['message']) ?? '',
      raw: map,
    );
  }
}

class RuntimeSnapshot {
  const RuntimeSnapshot({
    required this.active,
    required this.queued,
    required this.interrupted,
    required this.raw,
  });

  final Map<String, Object?> active;
  final List<String> queued;
  final List<String> interrupted;
  final Map<String, Object?> raw;

  factory RuntimeSnapshot.fromJson(Object? value) {
    final map = _stringMap(value);
    return RuntimeSnapshot(
      active: _stringMap(map['active']),
      queued: _stringList(map['queued']),
      interrupted: _stringList(map['interrupted']),
      raw: map,
    );
  }

  String? get activeTaskId {
    return _stringValue(active['task_id']) ?? _stringValue(active['taskId']);
  }
}

class TaskSummary {
  const TaskSummary({
    required this.taskId,
    required this.status,
    required this.inputFile,
    required this.inputType,
    required this.sourceLang,
    required this.targetLang,
    required this.bilingual,
    required this.createdAt,
    required this.updatedAt,
    required this.taskDir,
    required this.outputPath,
    required this.outputPaths,
    required this.error,
    required this.errorInfo,
    required this.runtime,
    required this.settings,
    required this.raw,
  });

  final String taskId;
  final String status;
  final String inputFile;
  final String inputType;
  final String sourceLang;
  final String targetLang;
  final bool bilingual;
  final String createdAt;
  final String updatedAt;
  final String taskDir;
  final String? outputPath;
  final Map<String, String> outputPaths;
  final String? error;
  final Map<String, Object?> errorInfo;
  final Map<String, Object?> runtime;
  final Map<String, Object?> settings;
  final Map<String, Object?> raw;

  factory TaskSummary.fromJson(Object? value) {
    if (value is String) {
      return TaskSummary(
        taskId: value,
        status: 'unknown',
        inputFile: '',
        inputType: '',
        sourceLang: '',
        targetLang: '',
        bilingual: false,
        createdAt: '',
        updatedAt: '',
        taskDir: '',
        outputPath: null,
        outputPaths: const {},
        error: null,
        errorInfo: const {},
        runtime: const {},
        settings: const {},
        raw: {'task_id': value},
      );
    }
    final map = _stringMap(value);
    final settings = _stringMap(map['settings']);
    final inputFile =
        _stringValue(map['input_file']) ?? _stringValue(map['inputFile']) ?? '';
    final inputType = _normalizeInputType(
      _stringValue(map['input_type']) ??
          _stringValue(map['inputType']) ??
          _stringValue(settings['input_type']),
    );
    return TaskSummary(
      taskId: _stringValue(map['task_id']) ?? _stringValue(map['taskId']) ?? '',
      status: _stringValue(map['status']) ?? 'unknown',
      inputFile: inputFile,
      inputType: inputType,
      sourceLang:
          _stringValue(map['source_lang']) ??
          _stringValue(map['sourceLang']) ??
          '',
      targetLang:
          _stringValue(map['target_lang']) ??
          _stringValue(map['targetLang']) ??
          '',
      bilingual: map['bilingual'] == true,
      createdAt:
          _stringValue(map['created_at']) ??
          _stringValue(map['createdAt']) ??
          '',
      updatedAt:
          _stringValue(map['updated_at']) ??
          _stringValue(map['updatedAt']) ??
          '',
      taskDir:
          _stringValue(map['task_dir']) ?? _stringValue(map['taskDir']) ?? '',
      outputPath:
          _stringValue(map['output_path']) ?? _stringValue(map['outputPath']),
      outputPaths: _stringMap(
        map['output_paths'],
      ).map((key, value) => MapEntry(key, '$value')),
      error: _stringValue(map['error']),
      errorInfo: _stringMap(map['error_info']),
      runtime: _stringMap(map['runtime']),
      settings: settings,
      raw: map,
    );
  }

  String get displayName => _pathBasename(inputFile);

  bool get isDone => status == 'DONE';
  bool get isFailed => status == 'FAILED';
  bool get isCancelled => status == 'CANCELLED' || status == 'INTERRUPTED';
  String get runtimeState =>
      (_stringValue(runtime['state']) ?? '').trim().toLowerCase();
  bool get isRuntimeActive =>
      runtimeState == 'running' || runtimeState == 'claimed';
  bool get isRuntimeStale => runtimeState == 'stale';
  bool get isActive =>
      status == 'INIT' ||
      status == 'QUEUED' ||
      status == 'PRECHECK' ||
      status == 'INGEST' ||
      status == 'ASR' ||
      status == 'MEMORY' ||
      status == 'SEGMENT' ||
      status == 'TRANSLATE' ||
      status == 'ALIGN' ||
      status == 'QUALITY' ||
      status == 'EXPORT' ||
      status == 'RUNNING' ||
      status == 'CANCEL_REQUESTED';
  bool get isTerminal => isDone || isFailed || isCancelled;
  bool get canCancel => runtime['can_cancel'] == true;
  bool get canResume => runtime['can_resume'] == true;
  Map<String, Object?> get progressDetail => _stringMap(raw['progress_detail']);
  int get asrDoneCount => _intValue(progressDetail['asr_done_count']) ?? 0;
  int get asrTotalSegments =>
      _intValue(progressDetail['asr_total_segments']) ?? 0;
  int get translationDoneCount =>
      _intValue(progressDetail['translate_done_count']) ?? 0;
  int get translationTotalChunks =>
      _intValue(progressDetail['translate_total_chunks']) ?? 0;
  int get modelRequestCount =>
      _intValue(progressDetail['model_request_count']) ?? 0;
  Map<String, int> get modelRequestCounts => _stringMap(
    progressDetail['model_request_counts'],
  ).map((key, value) => MapEntry(key, _intValue(value) ?? 0));

  double? get latestProgress {
    final progress = _numValue(raw['progress']);
    if (progress != null) return progress.toDouble().clamp(0.0, 1.0);
    final detail = progressDetail;
    final done = _numValue(detail['translate_done_count']);
    final total = _numValue(detail['translate_total_chunks']);
    if (done != null && total != null && total > 0) {
      return (done / total).clamp(0.0, 1.0);
    }
    return null;
  }

  String get displayStatus {
    final checkpoint = _stringValue(raw['checkpoint_status']);
    if (checkpoint != null && checkpoint.isNotEmpty) return checkpoint;
    return status;
  }
}

class TaskResultWorkspace {
  const TaskResultWorkspace({
    required this.task,
    required this.segments,
    required this.outputPaths,
    required this.quality,
    required this.delivery,
    required this.reflow,
    required this.memory,
    required this.raw,
  });

  final TaskSummary task;
  final List<ResultSegment> segments;
  final Map<String, String> outputPaths;
  final Map<String, Object?> quality;
  final Map<String, Object?> delivery;
  final Map<String, Object?> reflow;
  final Map<String, Object?> memory;
  final Map<String, Object?> raw;

  factory TaskResultWorkspace.fromJson(Object? value) {
    final map = _stringMap(value);
    final outputPaths = _stringMap(
      map['output_paths'],
    ).map((key, value) => MapEntry(key, '$value'));
    return TaskResultWorkspace(
      task: TaskSummary.fromJson(map['task']),
      segments: _objectList(map['segments'])
          .map(ResultSegment.fromJson)
          .where((segment) => segment.id >= 0)
          .toList(),
      outputPaths: outputPaths,
      quality: _stringMap(map['quality']),
      delivery: _stringMap(map['delivery']),
      reflow: _stringMap(map['reflow']),
      memory: _stringMap(map['memory']),
      raw: map,
    );
  }

  bool get hasSegments => segments.isNotEmpty;

  int get issueCount {
    return segments.fold<int>(
      0,
      (total, segment) =>
          total + segment.issues.length + segment.qualityIssues.length,
    );
  }
}

class ResultSegment {
  const ResultSegment({
    required this.id,
    required this.start,
    required this.end,
    required this.sourceText,
    required this.targetText,
    required this.provider,
    required this.model,
    required this.compatMode,
    required this.chunkId,
    required this.issues,
    required this.qualityIssues,
    required this.raw,
  });

  final int id;
  final double start;
  final double end;
  final String sourceText;
  final String targetText;
  final String provider;
  final String model;
  final String compatMode;
  final String chunkId;
  final List<String> issues;
  final List<Map<String, Object?>> qualityIssues;
  final Map<String, Object?> raw;

  factory ResultSegment.fromJson(Object? value) {
    final map = _stringMap(value);
    return ResultSegment(
      id: _intValue(map['id']) ?? -1,
      start: _numValue(map['start'])?.toDouble() ?? 0,
      end: _numValue(map['end'])?.toDouble() ?? 0,
      sourceText:
          _stringValue(map['text_src']) ??
          _stringValue(map['sourceText']) ??
          '',
      targetText:
          _stringValue(map['text_tgt']) ??
          _stringValue(map['targetText']) ??
          '',
      provider: _stringValue(map['provider']) ?? '',
      model: _stringValue(map['model']) ?? '',
      compatMode: _stringValue(map['compat_mode']) ?? '',
      chunkId: _stringValue(map['chunk_id']) ?? '',
      issues: _stringList(map['issues']),
      qualityIssues: _objectList(
        map['quality_issues'],
      ).map(_stringMap).where((issue) => issue.isNotEmpty).toList(),
      raw: map,
    );
  }

  String get timeRangeLabel {
    return '${_formatTimestamp(start)} - ${_formatTimestamp(end)}';
  }
}

class _PendingRpc {
  _PendingRpc();

  final _completer = Completer<Object?>();

  Future<Object?> get future => _completer.future;

  void complete(Object? value) {
    if (!_completer.isCompleted) _completer.complete(value);
  }

  void completeError(Object error) {
    if (!_completer.isCompleted) _completer.completeError(error);
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

List<TaskSummary> _taskList(Object? value) {
  return _objectList(
    value,
  ).map(TaskSummary.fromJson).where((task) => task.taskId.isNotEmpty).toList();
}

List<String> _stringList(Object? value) {
  return _objectList(value).map((item) => '$item').toList();
}

String? _stringValue(Object? value) {
  if (value == null) return null;
  final text = '$value';
  return text.isEmpty ? null : text;
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

num? _numValue(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value);
  return null;
}

String _normalizeInputType(String? value) {
  final raw = (value ?? '').trim();
  if (raw == 'srt' || raw == 'srt_translate') return 'srt_translate';
  if (raw == 'segments' || raw == 'segments_translate') {
    return 'segments_translate';
  }
  if (raw == 'video_asr' || raw == 'video_asr_translate') return raw;
  return '';
}

String _pathBasename(String path) {
  if (path.trim().isEmpty) return '';
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

String _formatTimestamp(double seconds) {
  final safeSeconds = seconds.isFinite ? seconds.clamp(0, double.infinity) : 0;
  final millis = (safeSeconds * 1000).round();
  final duration = Duration(milliseconds: millis);
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final secs = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final ms = duration.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
  final hours = duration.inHours;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:$minutes:$secs.$ms';
  }
  return '$minutes:$secs.$ms';
}
