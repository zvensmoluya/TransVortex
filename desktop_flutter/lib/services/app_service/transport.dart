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
  Future<void> _writeTail = Future<void>.value();
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
    final write = _writeTail.then((_) async {
      if (_closed) {
        throw RpcConnectionClosedException('service is closed');
      }
      stdin.writeln(jsonEncode(payload));
      await stdin.flush();
    });
    _writeTail = write.then<void>((_) {}, onError: (_) {});
    unawaited(
      write.catchError((Object error) {
        final removed = _pending.remove(id);
        removed?.completeError(
          error is RpcConnectionClosedException
              ? error
              : RpcConnectionClosedException('failed to write request: $error'),
        );
      }),
    );

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
      await _writeTail;
    } on Object {
      // Pending write failures are already forwarded to their RPC callers.
    }
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
    final id = _responseId(response?['id']);
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

int? _responseId(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
