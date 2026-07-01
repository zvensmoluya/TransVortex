import 'dart:async';
import 'dart:convert';
import 'dart:io';

abstract class AppServiceTransport {
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]);

  Future<void> close();
}

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
    ProcessStarter? processStarter,
    this.pythonExecutable = 'python',
    this.requestTimeout = const Duration(seconds: 8),
  }) : _processStarter = processStarter ?? _defaultProcessStarter;

  final Directory? repoRoot;
  final ProcessStarter _processStarter;
  final String pythonExecutable;
  final Duration requestTimeout;

  Future<LocalServiceSession> start() async {
    final root = repoRoot ?? findRepoRoot();
    if (root == null) {
      throw LocalServiceLaunchException(
        'could not find repository root for Local Service',
      );
    }
    final process = await _processStarter(
      pythonExecutable,
      ['-m', 'transvortex.app_service', '--root', root.path],
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

  Future<ServiceInfo> info() async {
    return ServiceInfo.fromJson(await _transport.call('service.info'));
  }

  Future<ServiceHealth> health() async {
    return ServiceHealth.fromJson(await _transport.call('service.health'));
  }

  Future<DesktopSnapshot> desktopSnapshot() async {
    return DesktopSnapshot.fromJson(await _transport.call('desktop.snapshot'));
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

  bool get degraded => status == 'degraded' || pump['last_error'] != null;

  Map<String, Object?> get active {
    return _stringMap(runtime['active']);
  }

  String get activeTaskLabel {
    final taskId =
        _stringValue(active['task_id']) ?? _stringValue(active['taskId']);
    final status = _stringValue(active['status']);
    if (taskId == null || taskId.isEmpty) return '无 active task';
    return status == null ? taskId : '$taskId · $status';
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
  final List<Object?> tasks;
  final Map<String, Object?> runtime;
  final Map<String, Object?> environment;
  final Map<String, Object?> raw;

  factory DesktopSnapshot.fromJson(Object? value) {
    final map = _stringMap(value);
    return DesktopSnapshot(
      config: _stringMap(map['config']),
      tasks: _objectList(map['tasks']),
      runtime: _stringMap(map['runtime']),
      environment: _stringMap(map['environment']),
      raw: map,
    );
  }

  ConfigReadiness get configReadiness => ConfigReadiness.fromConfig(config);
}

class ConfigReadiness {
  const ConfigReadiness({
    required this.translationConfigured,
    required this.translationLabel,
    required this.asrConfigured,
    required this.asrLabel,
  });

  final bool translationConfigured;
  final String translationLabel;
  final bool asrConfigured;
  final String asrLabel;

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
    final asrLabel =
        _stringValue(selectedAsr['name']) ?? selectedAsrName ?? '需配置';

    return ConfigReadiness(
      translationConfigured: selectedProvider['has_key'] == true,
      translationLabel: translationLabel,
      asrConfigured: selectedAsr['has_key'] == true,
      asrLabel: asrLabel,
    );
  }
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
