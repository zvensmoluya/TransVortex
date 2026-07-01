import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/local_service_controller.dart';

void main() {
  test(
    'controller starts, refreshes, and keeps stopped after shutdown',
    () async {
      final handle = _FakeHandle.ready();
      final controller = LocalServiceController(
        sessionFactory: () async => handle,
      );

      await controller.start();
      expect(controller.snapshot.status, LocalServiceConnectionStatus.ready);

      await controller.shutdown();
      handle.completeExit(0);
      await Future<void>.delayed(Duration.zero);

      expect(controller.snapshot.status, LocalServiceConnectionStatus.stopped);
      expect(handle.shutdownCalled, isTrue);
    },
  );

  test('controller reports degraded health', () async {
    final controller = LocalServiceController(
      sessionFactory: () async => _FakeHandle.degraded(),
    );

    await controller.start();

    expect(controller.snapshot.status, LocalServiceConnectionStatus.degraded);
  });

  test('process exit clears session and refresh can start a new handle', () async {
    var starts = 0;
    late _FakeHandle first;
    late _FakeHandle second;
    final controller = LocalServiceController(
      sessionFactory: () async {
        starts += 1;
        if (starts == 1) {
          return first = _FakeHandle.ready();
        }
        return second = _FakeHandle.ready(appVersion: 'second');
      },
    );

    await controller.start();
    first.completeExit(7);
    await Future<void>.delayed(Duration.zero);

    expect(controller.snapshot.status, LocalServiceConnectionStatus.unavailable);
    expect(controller.client, isNull);

    await controller.refresh();

    expect(starts, 2);
    expect(controller.client, same(second.client));
    expect(controller.snapshot.status, LocalServiceConnectionStatus.ready);
    expect(controller.snapshot.info?.appVersion, 'second');
  });

  test('connection closed during refresh retries once with a new handle', () async {
    var starts = 0;
    late _FakeHandle failed;
    late _FakeHandle recovered;
    final controller = LocalServiceController(
      sessionFactory: () async {
        starts += 1;
        if (starts == 1) {
          return failed = _FakeHandle.ready();
        }
        return recovered = _FakeHandle.ready(appVersion: 'recovered');
      },
    );
    await controller.start();
    failed.transport.failures['service.health'] =
        RpcConnectionClosedException('service stdout closed');

    await controller.refresh();

    expect(starts, 2);
    expect(failed.shutdownCalled, isTrue);
    expect(controller.client, same(recovered.client));
    expect(controller.snapshot.status, LocalServiceConnectionStatus.ready);
    expect(controller.snapshot.info?.appVersion, 'recovered');
  });

  test('timeout during refresh degrades without restarting', () async {
    var starts = 0;
    late _FakeHandle handle;
    final controller = LocalServiceController(
      sessionFactory: () async {
        starts += 1;
        return handle = _FakeHandle.ready();
      },
    );
    await controller.start();
    handle.transport.failures['service.health'] = RpcTimeoutException(
      'service.health',
      const Duration(seconds: 8),
    );

    await controller.refresh();

    expect(starts, 1);
    expect(controller.client, same(handle.client));
    expect(controller.snapshot.status, LocalServiceConnectionStatus.degraded);
    expect(controller.snapshot.lastError, contains('RPC timeout'));
  });

  test('remote error during refresh degrades without restarting', () async {
    var starts = 0;
    late _FakeHandle handle;
    final controller = LocalServiceController(
      sessionFactory: () async {
        starts += 1;
        return handle = _FakeHandle.ready();
      },
    );
    await controller.start();
    handle.transport.failures['desktop.snapshot'] = RpcRemoteException(
      'internal_error',
      'snapshot failed',
    );

    await controller.refresh();

    expect(starts, 1);
    expect(controller.client, same(handle.client));
    expect(controller.snapshot.status, LocalServiceConnectionStatus.degraded);
    expect(controller.snapshot.lastError, contains('RPC error internal_error'));
  });

  test('concurrent start only creates one session', () async {
    var starts = 0;
    final releaseStart = Completer<void>();
    final controller = LocalServiceController(
      sessionFactory: () async {
        starts += 1;
        await releaseStart.future;
        return _FakeHandle.ready();
      },
    );

    final first = controller.start();
    final second = controller.start();
    releaseStart.complete();
    await Future.wait([first, second]);

    expect(starts, 1);
    expect(controller.snapshot.status, LocalServiceConnectionStatus.ready);
  });

  test('restart ignores stale exit callback from previous session', () async {
    var starts = 0;
    late _FakeHandle first;
    late _FakeHandle second;
    final controller = LocalServiceController(
      sessionFactory: () async {
        starts += 1;
        if (starts == 1) {
          return first = _FakeHandle.ready(appVersion: 'first');
        }
        return second = _FakeHandle.ready(appVersion: 'second');
      },
    );

    await controller.start();
    await controller.restart();
    first.completeExit(9);
    await Future<void>.delayed(Duration.zero);

    expect(first.shutdownCalled, isTrue);
    expect(controller.client, same(second.client));
    expect(controller.snapshot.status, LocalServiceConnectionStatus.ready);
    expect(controller.snapshot.info?.appVersion, 'second');
  });
}

class _FakeHandle implements LocalServiceHandle {
  _FakeHandle({
    required ServiceInfo info,
    required ServiceHealth health,
    required DesktopSnapshot snapshot,
  }) : transport = _FakeTransport({
         'service.info': {
           'service': info.service,
           'protocol_version': info.protocolVersion,
           'app_version': info.appVersion,
           'capabilities': info.capabilities,
         },
         'service.health': {
           'service': health.service,
           'status': health.status,
           'runtime': health.runtime,
           'pump': health.pump,
           if (health.error != null) 'error': health.error,
         },
         'desktop.snapshot': snapshot.raw,
       }) {
    client = AppServiceClient(transport);
  }

  factory _FakeHandle.ready({String appVersion = 'test'}) {
    return _FakeHandle(
      info: ServiceInfo(
        service: 'transvortex.app_service',
        protocolVersion: 1,
        appVersion: appVersion,
        capabilities: const ['desktop_snapshot'],
      ),
      health: const ServiceHealth(
        service: 'transvortex.app_service',
        status: 'healthy',
        runtime: {'active': null},
        pump: {'enabled': true},
      ),
      snapshot: _desktopSnapshot(),
    );
  }

  factory _FakeHandle.degraded() {
    return _FakeHandle(
      info: const ServiceInfo(
        service: 'transvortex.app_service',
        protocolVersion: 1,
        appVersion: 'test',
        capabilities: ['desktop_snapshot'],
      ),
      health: const ServiceHealth(
        service: 'transvortex.app_service',
        status: 'degraded',
        runtime: {'active': null},
        pump: {'enabled': true, 'last_error': 'launch failed'},
      ),
      snapshot: _desktopSnapshot(),
    );
  }

  final _exit = Completer<int>();
  final _FakeTransport transport;
  bool shutdownCalled = false;

  @override
  late final AppServiceClient client;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> shutdown({
    Duration rpcTimeout = const Duration(seconds: 2),
    Duration exitTimeout = const Duration(seconds: 2),
  }) async {
    shutdownCalled = true;
  }

  void completeExit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }
}

class _FakeTransport implements AppServiceTransport {
  _FakeTransport(this.results);

  final Map<String, Object?> results;
  final Map<String, Object> failures = {};

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    final failure = failures[method];
    if (failure != null) {
      throw failure;
    }
    return results[method];
  }

  @override
  Future<void> close() async {}
}

DesktopSnapshot _desktopSnapshot() {
  return DesktopSnapshot.fromJson({
    'config': {
      'routing': {
        'primary': {'provider': 'p1', 'model': 'model-a'},
      },
      'pipeline': {'asr_provider': 'local'},
      'providers': [
        {'name': 'p1', 'has_key': true},
      ],
      'asr_providers': {},
    },
    'tasks': [],
    'runtime': {},
    'environment': {},
  });
}
