import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';

void main() {
  test('JsonRpcTransport matches responses by id', () async {
    final stdout = StreamController<List<int>>();
    final stdin = _FakeSink();
    final exit = Completer<int>();
    final transport = JsonRpcTransport(
      stdout: stdout.stream,
      stdin: stdin,
      exitCode: exit.future,
      defaultTimeout: const Duration(seconds: 1),
    );

    final first = transport.call('service.info');
    final second = transport.call('service.health');
    stdout.add(
      utf8.encode('{"jsonrpc":"2.0","id":2,"result":{"status":"healthy"}}\n'),
    );
    stdout.add(
      utf8.encode(
        '{"jsonrpc":"2.0","id":1,"result":{"service":"transvortex.app_service"}}\n',
      ),
    );

    expect(await first, {'service': 'transvortex.app_service'});
    expect(await second, {'status': 'healthy'});
    await transport.close();
    await stdout.close();
  });

  test(
    'JsonRpcTransport surfaces RPC errors and ignores non JSON diagnostics',
    () async {
      final stdout = StreamController<List<int>>();
      final stdin = _FakeSink();
      final exit = Completer<int>();
      final transport = JsonRpcTransport(
        stdout: stdout.stream,
        stdin: stdin,
        exitCode: exit.future,
        defaultTimeout: const Duration(seconds: 1),
      );

      final call = transport.call('missing.method');
      stdout.add(utf8.encode('not-json\n'));
      stdout.add(
        utf8.encode(
          '{"jsonrpc":"2.0","id":1,"error":{"code":"method_not_found","message":"missing"}}\n',
        ),
      );

      await expectLater(call, throwsA(isA<RpcRemoteException>()));
      expect(transport.diagnosticLines, contains('not-json'));
      await transport.close();
      await stdout.close();
    },
  );

  test('JsonRpcTransport timeout leaves connection open', () async {
    final stdout = StreamController<List<int>>();
    final stdin = _FakeSink();
    final exit = Completer<int>();
    final transport = JsonRpcTransport(
      stdout: stdout.stream,
      stdin: stdin,
      exitCode: exit.future,
      defaultTimeout: const Duration(milliseconds: 20),
    );

    await expectLater(
      transport.call('service.health'),
      throwsA(isA<RpcTimeoutException>()),
    );

    expect(transport.isClosed, isFalse);
    expect(stdin.closed, isFalse);
    await transport.close();
    await stdout.close();
  });

  test(
    'AppServiceClient parses service info, health, and snapshot readiness',
    () async {
      final client = AppServiceClient(
        _FakeTransport({
          'service.info': {
            'service': 'transvortex.app_service',
            'protocol_version': 1,
            'app_version': '1.2.3',
            'capabilities': ['desktop_snapshot', 'runtime_pump'],
          },
          'service.health': {
            'service': 'transvortex.app_service',
            'status': 'healthy',
            'runtime': {
              'active': {'task_id': 'tvx_1', 'status': 'RUNNING'},
            },
            'pump': {'enabled': true},
          },
          'desktop.snapshot': {
            'config': {
              'routing': {
                'primary': {'provider': 'p2', 'model': 'model-b'},
              },
              'pipeline': {'asr_provider': 'local'},
              'providers': [
                {'name': 'p1', 'has_key': false},
                {'name': 'p2', 'has_key': true},
              ],
              'asr_providers': {
                'local': {'name': 'Local ASR', 'has_key': true},
              },
            },
            'tasks': ['task-a', 'task-b'],
            'runtime': {},
            'environment': {},
          },
        }),
      );

      final info = await client.info();
      final health = await client.health();
      final snapshot = await client.desktopSnapshot();

      expect(info.protocolVersion, 1);
      expect(info.capabilities, contains('runtime_pump'));
      expect(health.activeTaskLabel, 'tvx_1 · RUNNING');
      expect(health.pumpLabel, 'running');
      expect(snapshot.tasks, hasLength(2));
      expect(snapshot.configReadiness.translationConfigured, isTrue);
      expect(snapshot.configReadiness.translationLabel, 'p2');
      expect(snapshot.configReadiness.asrConfigured, isTrue);
      expect(snapshot.configReadiness.asrLabel, 'Local ASR');
    },
  );

  test('ConfigReadiness does not fall back to another translation provider', () {
    final snapshot = DesktopSnapshot.fromJson({
      'config': {
        'routing': {
          'primary': {'provider': 'p1', 'model': 'model-a'},
        },
        'pipeline': {'asr_provider': 'local'},
        'providers': [
          {'name': 'p1', 'has_key': false},
          {'name': 'p2', 'has_key': true},
        ],
        'asr_providers': {
          'local': {'name': 'Local ASR', 'has_key': true},
        },
      },
      'tasks': [],
      'runtime': {},
      'environment': {},
    });

    expect(snapshot.configReadiness.translationConfigured, isFalse);
    expect(snapshot.configReadiness.translationLabel, 'p1');
    expect(snapshot.configReadiness.asrConfigured, isTrue);
  });

  test('ConfigReadiness uses selected ASR provider and legacy routing shape', () {
    final snapshot = DesktopSnapshot.fromJson({
      'config': {
        'routing': {'primary': 'p1'},
        'pipeline': {'asr_provider': 'selected'},
        'providers': [
          {'name': 'p1', 'has_key': true},
        ],
        'asr_providers': {
          'other': {'name': 'Other ASR', 'has_key': true},
          'selected': {'name': 'Selected ASR', 'has_key': false},
        },
      },
      'tasks': [],
      'runtime': {},
      'environment': {},
    });

    expect(snapshot.configReadiness.translationConfigured, isTrue);
    expect(snapshot.configReadiness.translationLabel, 'p1');
    expect(snapshot.configReadiness.asrConfigured, isFalse);
    expect(snapshot.configReadiness.asrLabel, 'Selected ASR');
  });

  test('TaskEventsPage parses cursor payload', () {
    final page = TaskEventsPage.fromJson({
      'task_id': 'tvx_1',
      'events': [
        {'type': 'started'},
      ],
      'cursor': 2,
      'next_cursor': 3,
      'has_more': true,
    });

    expect(page.taskId, 'tvx_1');
    expect(page.events, hasLength(1));
    expect(page.cursor, 2);
    expect(page.nextCursor, 3);
    expect(page.hasMore, isTrue);
  });
}

class _FakeTransport implements AppServiceTransport {
  _FakeTransport(this.results);

  final Map<String, Object?> results;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    if (!results.containsKey(method)) {
      throw RpcRemoteException('method_not_found', method);
    }
    return results[method];
  }

  @override
  Future<void> close() async {}
}

class _FakeSink implements IOSink {
  final writes = <Object?>[];
  bool closed = false;

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) => writes.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> get done async {}

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) => writes.add(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    writes.add(objects.join(separator));
  }

  @override
  void writeCharCode(int charCode) => writes.add(charCode);

  @override
  void writeln([Object? object = '']) => writes.add('$object\n');
}
