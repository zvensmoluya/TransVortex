import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_service_client.dart';

enum LocalServiceConnectionStatus {
  idle,
  starting,
  ready,
  degraded,
  unavailable,
  stopped,
}

extension LocalServiceConnectionStatusLabel on LocalServiceConnectionStatus {
  String get zh => switch (this) {
    LocalServiceConnectionStatus.idle => '未启动',
    LocalServiceConnectionStatus.starting => '启动中',
    LocalServiceConnectionStatus.ready => '已连接',
    LocalServiceConnectionStatus.degraded => '降级',
    LocalServiceConnectionStatus.unavailable => '不可用',
    LocalServiceConnectionStatus.stopped => '已停止',
  };
}

class LocalServiceSnapshot {
  const LocalServiceSnapshot({
    required this.status,
    this.info,
    this.health,
    this.desktopSnapshot,
    this.lastError,
  });

  final LocalServiceConnectionStatus status;
  final ServiceInfo? info;
  final ServiceHealth? health;
  final DesktopSnapshot? desktopSnapshot;
  final String? lastError;

  LocalServiceSnapshot copyWith({
    LocalServiceConnectionStatus? status,
    Object? info = _unset,
    Object? health = _unset,
    Object? desktopSnapshot = _unset,
    Object? lastError = _unset,
  }) {
    return LocalServiceSnapshot(
      status: status ?? this.status,
      info: info == _unset ? this.info : info as ServiceInfo?,
      health: health == _unset ? this.health : health as ServiceHealth?,
      desktopSnapshot: desktopSnapshot == _unset
          ? this.desktopSnapshot
          : desktopSnapshot as DesktopSnapshot?,
      lastError: lastError == _unset ? this.lastError : lastError as String?,
    );
  }

  static const _unset = Object();
}

typedef LocalServiceSessionFactory = Future<LocalServiceHandle> Function();

class LocalServiceController extends ChangeNotifier {
  LocalServiceController({
    LocalServiceSupervisor? supervisor,
    this.sessionFactory,
  }) : _supervisor = supervisor ?? LocalServiceSupervisor();

  final LocalServiceSupervisor _supervisor;
  final LocalServiceSessionFactory? sessionFactory;
  LocalServiceHandle? _session;
  Future<void>? _starting;
  int _generation = 0;
  bool _disposed = false;

  LocalServiceSnapshot _snapshot = const LocalServiceSnapshot(
    status: LocalServiceConnectionStatus.idle,
  );

  LocalServiceSnapshot get snapshot => _snapshot;

  AppServiceClient? get client => _session?.client;

  Future<void> start() async {
    if (_disposed) return;
    final starting = _starting;
    if (starting != null) {
      await starting;
      return;
    }
    if (_session != null &&
        (_snapshot.status == LocalServiceConnectionStatus.ready ||
            _snapshot.status == LocalServiceConnectionStatus.degraded)) {
      return;
    }
    final generation = _nextGeneration();
    final startFuture = _startSession(generation);
    _starting = startFuture;
    await startFuture.whenComplete(() {
      if (identical(_starting, startFuture)) {
        _starting = null;
      }
    });
  }

  Future<void> restart() async {
    if (_disposed) return;
    final session = _detachCurrentSession();
    _starting = null;
    if (session != null) {
      await _shutdownBestEffort(session);
    }
    await start();
  }

  Future<void> _startSession(int generation) async {
    _set(
      const LocalServiceSnapshot(status: LocalServiceConnectionStatus.starting),
    );
    try {
      final session = await (sessionFactory?.call() ?? _supervisor.start());
      if (!_isGenerationActive(generation)) {
        unawaited(_shutdownBestEffort(session));
        return;
      }
      _session = session;
      unawaited(
        session.exitCode.then(
          (code) => _handleSessionExit(session, generation, code),
          onError: (Object error) =>
              _handleSessionExit(session, generation, null, error: error),
        ),
      );
      await _refreshSession(session, generation, retryOnFatal: false);
    } on Object catch (error) {
      if (!_isGenerationActive(generation)) return;
      _session = null;
      _set(
        LocalServiceSnapshot(
          status: LocalServiceConnectionStatus.unavailable,
          lastError: '$error',
        ),
      );
    }
  }

  Future<void> refresh() async {
    final session = _session;
    if (session == null) {
      await start();
      return;
    }
    await _refreshSession(session, _generation, retryOnFatal: true);
  }

  Future<void> _refreshSession(
    LocalServiceHandle session,
    int generation, {
    required bool retryOnFatal,
  }) async {
    try {
      final info = await session.client.info();
      final health = await session.client.health();
      final desktopSnapshot = await session.client.desktopSnapshot();
      if (!_isCurrentSession(session, generation)) return;
      _set(
        LocalServiceSnapshot(
          status: health.degraded
              ? LocalServiceConnectionStatus.degraded
              : LocalServiceConnectionStatus.ready,
          info: info,
          health: health,
          desktopSnapshot: desktopSnapshot,
        ),
      );
    } on Object catch (error) {
      if (!_isCurrentSession(session, generation)) return;
      if (_isFatalConnectionError(error)) {
        _markCurrentSessionUnavailable(session, generation, '$error');
        unawaited(_shutdownBestEffort(session));
        if (retryOnFatal) {
          await start();
        }
        return;
      }
      _set(
        _snapshot.copyWith(
          status: LocalServiceConnectionStatus.degraded,
          lastError: '$error',
        ),
      );
    }
  }

  Future<void> shutdown() async {
    final session = _detachCurrentSession();
    _starting = null;
    if (session == null) {
      _set(
        const LocalServiceSnapshot(
          status: LocalServiceConnectionStatus.stopped,
        ),
      );
      return;
    }
    try {
      await session.shutdown();
    } on Object catch (error) {
      _set(
        LocalServiceSnapshot(
          status: LocalServiceConnectionStatus.unavailable,
          lastError: '$error',
        ),
      );
      return;
    }
    _set(
      const LocalServiceSnapshot(status: LocalServiceConnectionStatus.stopped),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    final session = _detachCurrentSession();
    _starting = null;
    if (session != null) {
      unawaited(session.shutdown());
    }
    super.dispose();
  }

  void _set(LocalServiceSnapshot next) {
    if (_disposed) return;
    _snapshot = next;
    notifyListeners();
  }

  int _nextGeneration() {
    _generation += 1;
    return _generation;
  }

  bool _isGenerationActive(int generation) {
    return !_disposed && _generation == generation;
  }

  bool _isCurrentSession(LocalServiceHandle session, int generation) {
    return _isGenerationActive(generation) && identical(_session, session);
  }

  LocalServiceHandle? _detachCurrentSession() {
    final session = _session;
    _session = null;
    _nextGeneration();
    return session;
  }

  void _handleSessionExit(
    LocalServiceHandle session,
    int generation,
    int? code, {
    Object? error,
  }) {
    if (!_isCurrentSession(session, generation)) return;
    _session = null;
    _nextGeneration();
    final message = error == null ? '本地服务已退出，退出码 $code' : '本地服务退出监视失败：$error';
    _set(
      LocalServiceSnapshot(
        status: LocalServiceConnectionStatus.unavailable,
        lastError: message,
      ),
    );
  }

  void _markCurrentSessionUnavailable(
    LocalServiceHandle session,
    int generation,
    String message,
  ) {
    if (!_isCurrentSession(session, generation)) return;
    _session = null;
    _nextGeneration();
    _set(
      LocalServiceSnapshot(
        status: LocalServiceConnectionStatus.unavailable,
        lastError: message,
      ),
    );
  }

  bool _isFatalConnectionError(Object error) {
    return error is RpcConnectionClosedException;
  }

  Future<void> _shutdownBestEffort(LocalServiceHandle session) async {
    try {
      await session.shutdown();
    } on Object {
      // Best effort cleanup for abandoned or stale sessions.
    }
  }
}
