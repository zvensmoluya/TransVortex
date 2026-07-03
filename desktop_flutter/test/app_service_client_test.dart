import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/model/spike_state.dart';
import 'package:transvortex_desktop_flutter/services/window_state_bridge.dart';

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

  test(
    'ConfigReadiness does not fall back to another translation provider',
    () {
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
    },
  );

  test(
    'ConfigReadiness uses selected ASR provider and legacy routing shape',
    () {
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
    },
  );

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

  test(
    'AppServiceClient calls runtime and result methods with typed payloads',
    () async {
      final transport = _RecordingTransport({
        'runtime.submitRun': {
          'ok': true,
          'task_id': 'tvx_1',
          'status': 'QUEUED',
          'task_dir': r'D:\artifacts\tvx_1',
          'terminal': false,
          'message': 'Task queued.',
        },
        'runtime.snapshot': {
          'active': {'task_id': 'tvx_1'},
          'queued': ['tvx_2'],
          'interrupted': [],
        },
        'tasks.events': {
          'task_id': 'tvx_1',
          'events': [
            {'message': 'Translating', 'progress': 0.5},
          ],
          'cursor': 0,
          'next_cursor': 1,
          'has_more': false,
        },
        'result.open': {
          'output_paths': {'srt': r'D:\out.srt'},
        },
      });
      final client = AppServiceClient(transport);

      final submitted = await client.submitRun({
        'input': r'D:\input.mp4',
        'source_lang': 'en',
        'target_lang': 'zh-CN',
        'overrides': {'output_format': 'both'},
      });
      final runtime = await client.runtimeSnapshot();
      final events = await client.taskEvents('tvx_1', cursor: 0, limit: 10);
      final result = await client.resultOpen('tvx_1');

      expect(submitted.taskId, 'tvx_1');
      expect(runtime.activeTaskId, 'tvx_1');
      expect(runtime.queued, ['tvx_2']);
      expect(events.events, hasLength(1));
      expect(result['output_paths'], {'srt': r'D:\out.srt'});
      expect(
        transport.calls.first.params['request'],
        containsPair('input', r'D:\input.mp4'),
      );
      expect(transport.calls[2].params, containsPair('cursor', 0));
      expect(transport.calls[2].params, containsPair('limit', 10));
    },
  );

  test('AppServiceClient calls provider and ASR admin methods', () async {
    final transport = _RecordingTransport({
      'provider.save': {'ok': true},
      'provider.models': {
        'status': 'PASS',
        'models': ['model-a'],
      },
      'provider.test': {'status': 'PASS', 'checks': []},
      'provider.routing.save': {
        'routing': {
          'primary': {'provider': 'p1', 'model': 'model-a'},
        },
      },
      'asr.provider.save': {'ok': true, 'provider': 'openai_whisper'},
    });
    final client = AppServiceClient(transport);

    await client.providerSave(
      providerDraft: {
        'name': 'p1',
        'models': ['model-a'],
      },
      apiKey: 'secret',
    );
    await client.providerModels(providerDraft: {'name': 'p1'});
    await client.providerTest(providerDraft: {'name': 'p1'}, model: 'model-a');
    await client.saveTranslationRouting(
      provider: 'p1',
      model: 'model-a',
      fallback: [
        {'provider': 'p2', 'model': 'model-b'},
      ],
      expectedVersion: {'mtime_ns': 1, 'size': 2},
    );
    await client.asrProviderSave(
      providerDraft: {
        'name': 'openai_whisper',
        'kind': 'remote',
        'model': 'whisper-1',
      },
      expectedVersion: {'mtime_ns': 3, 'size': 4},
    );

    expect(transport.calls.map((call) => call.method), [
      'provider.save',
      'provider.models',
      'provider.test',
      'provider.routing.save',
      'asr.provider.save',
    ]);
    expect(transport.calls.first.params['api_key'], 'secret');
    expect(transport.calls[3].params['primary'], {
      'provider': 'p1',
      'model': 'model-a',
    });
    expect(transport.calls[3].params['fallback'], [
      {'provider': 'p2', 'model': 'model-b'},
    ]);
    expect(transport.calls[3].params['expected_version'], {
      'mtime_ns': 1,
      'size': 2,
    });
    expect(
      transport.calls.last.params['provider_draft'],
      containsPair('kind', 'remote'),
    );
    expect(transport.calls.last.params['expected_version'], {
      'mtime_ns': 3,
      'size': 4,
    });
  });

  test('TaskSummary parses status, runtime, progress, and errors', () {
    final task = TaskSummary.fromJson({
      'task_id': 'tvx_1',
      'status': 'FAILED',
      'input_file': r'D:\input.mp4',
      'source_lang': 'en',
      'target_lang': 'zh-CN',
      'bilingual': true,
      'created_at': '2026-07-01T00:00:00Z',
      'updated_at': '2026-07-01T00:01:00Z',
      'output_paths': {'srt': r'D:\out.srt'},
      'error_info': {'hint_zh': 'Provider 配置不可用。'},
      'runtime': {'can_resume': true},
      'checkpoint_status': 'TRANSLATE',
      'progress_detail': {
        'translate_done_count': 2,
        'translate_total_chunks': 4,
      },
    });

    expect(task.taskId, 'tvx_1');
    expect(task.isFailed, isTrue);
    expect(task.canResume, isTrue);
    expect(task.latestProgress, 0.5);
    expect(task.displayStatus, 'TRANSLATE');
    expect(task.outputPaths['srt'], r'D:\out.srt');
  });

  test(
    'WindowBridgeTransport delegates calls to the attached main bridge',
    () async {
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      final calls = <_RecordedCall>[];
      bridge.attachServiceCaller((method, params) async {
        calls.add(_RecordedCall(method, params));
        return {
          'service': 'transvortex.app_service',
          'protocol_version': 1,
          'app_version': 'test',
          'capabilities': ['desktop_snapshot'],
        };
      });
      final client = AppServiceClient(WindowBridgeTransport(bridge));

      final info = await client.info();

      expect(info.service, 'transvortex.app_service');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'service.info');
      expect(calls.single.params, isEmpty);
    },
  );
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

class _RecordingTransport implements AppServiceTransport {
  _RecordingTransport(this.results);

  final Map<String, Object?> results;
  final List<_RecordedCall> calls = [];

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    calls.add(_RecordedCall(method, params));
    if (!results.containsKey(method)) {
      throw RpcRemoteException('method_not_found', method);
    }
    return results[method];
  }

  @override
  Future<void> close() async {}
}

class _RecordedCall {
  const _RecordedCall(this.method, this.params);

  final String method;
  final Map<String, Object?> params;
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
