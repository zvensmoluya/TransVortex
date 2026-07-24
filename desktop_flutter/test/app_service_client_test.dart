import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/model/task_labels.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/desktop_app_paths.dart';
import 'package:transvortex_desktop_flutter/model/window_state.dart';
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

  test('JsonRpcTransport serializes writes across sink flushes', () async {
    final stdout = StreamController<List<int>>();
    final stdin = _ControlledFlushSink();
    final exit = Completer<int>();
    final transport = JsonRpcTransport(
      stdout: stdout.stream,
      stdin: stdin,
      exitCode: exit.future,
      defaultTimeout: const Duration(seconds: 1),
    );

    final first = transport.call('service.info');
    final second = transport.call('service.health');

    await stdin.firstFlushStarted.future;
    expect(stdin.writes, hasLength(1));
    expect(stdin.secondFlushStarted.isCompleted, isFalse);

    stdin.releaseFlush();
    await stdin.secondFlushStarted.future;
    expect(stdin.writes, hasLength(2));
    stdin.releaseFlush();

    stdout.add(
      utf8.encode('{"jsonrpc":"2.0","id":1,"result":{"service":"ready"}}\n'),
    );
    stdout.add(
      utf8.encode('{"jsonrpc":"2.0","id":2,"result":{"status":"healthy"}}\n'),
    );

    expect(await first, {'service': 'ready'});
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
      stdout.add(utf8.encode('\n'));
      stdout.add(
        utf8.encode(
          '{"jsonrpc":"2.0","id":1,"error":{"code":"method_not_found","message":"missing"}}\n',
        ),
      );

      await expectLater(call, throwsA(isA<RpcRemoteException>()));
      expect(transport.diagnosticLines, contains('not-json'));
      expect(transport.diagnosticLines, isNot(contains('')));
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
      expect(health.activeTaskLabel, 'tvx_1 · 制作中');
      expect(health.pumpLabel, 'running');
      expect(snapshot.tasks, hasLength(2));
      expect(snapshot.configReadiness.translationConfigured, isTrue);
      expect(snapshot.configReadiness.translationLabel, 'p2');
      expect(snapshot.configReadiness.asrConfigured, isTrue);
      expect(snapshot.configReadiness.asrLabel, '本机 Whisper');
    },
  );

  test('ServiceHealth ignores empty pump last_error', () {
    final health = ServiceHealth.fromJson({
      'service': 'transvortex.app_service',
      'status': 'healthy',
      'runtime': {},
      'pump': {'enabled': true, 'last_error': ''},
    });

    expect(health.degraded, isFalse);
    expect(health.pumpLabel, 'running');
  });

  test('AppServiceClient parses the installed Agent entry contract', () async {
    final client = AppServiceClient(
      _FakeTransport({
        'agent.entry.get': {
          'schema_version': 1,
          'app_version': '1.2.3',
          'protocol_version': '0.1',
          'registered': true,
          'install_root': r'C:\Programs\TransVortex\App',
          'config_root': r'C:\Users\tester\AppData\Local\TransVortex\Config',
          'agent_entry_document':
              r'C:\Users\tester\AppData\Local\TransVortex\Agent\README.md',
          'agent_entry_state':
              r'C:\Users\tester\AppData\Local\TransVortex\Agent\current.json',
          'agent_docs_root': r'C:\Programs\TransVortex\App\agent',
          'documents': {
            'usage': r'C:\Programs\TransVortex\App\agent\AGENT_USAGE.md',
            'asr_environment_setup':
                r'C:\Programs\TransVortex\App\agent\workflows\ASR_ENVIRONMENT_SETUP.md',
          },
          'cli_argv_prefix': [
            r'C:\Programs\TransVortex\App\runtime\python\python.exe',
            '-B',
            '-m',
            'transvortex.cli',
            '--root',
            r'C:\Users\tester\AppData\Local\TransVortex\Config',
          ],
          'capabilities_argv': ['python.exe', 'agent-info', '--json'],
          'handoff_text': 'general handoff',
          'asr_environment_handoff_text': 'asr handoff',
        },
      }),
    );

    final entry = await client.agentEntry();

    expect(entry.registered, isTrue);
    expect(entry.appVersion, '1.2.3');
    expect(entry.entryDocument, endsWith(r'Agent\README.md'));
    expect(entry.cliArgvPrefix[3], 'transvortex.cli');
    expect(entry.documentPath('usage'), endsWith('AGENT_USAGE.md'));
    expect(entry.asrEnvironmentHandoffText, 'asr handoff');
  });

  test('ServiceHealth active task label uses user facing text', () {
    final active = ServiceHealth.fromJson({
      'service': 'transvortex.app_service',
      'status': 'healthy',
      'runtime': {
        'active': {
          'task_id': 'tvx_20260704_long_identifier_abcdef',
          'status': 'TRANSLATE',
        },
      },
      'pump': {'enabled': true},
    });
    final idle = ServiceHealth.fromJson({
      'service': 'transvortex.app_service',
      'status': 'healthy',
      'runtime': {},
      'pump': {'enabled': true},
    });

    expect(active.activeTaskLabel, 'tvx_2026…abcdef · 翻译字幕');
    expect(active.activeTaskLabel, isNot(contains('TRANSLATE')));
    expect(idle.activeTaskLabel, '无活动任务');
    expect(idle.activeTaskLabel, isNot(contains('active task')));
  });

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
      expect(snapshot.configReadiness.asrLabel, 'OpenAI Whisper');
    },
  );

  test('ConfigReadiness uses backend ASR readiness instead of auth shape', () {
    final snapshot = DesktopSnapshot.fromJson({
      'config': {
        'pipeline': {'asr_provider': 'local'},
        'asr_providers': {
          'local': {
            'name': 'Local ASR',
            'kind': 'local_worker',
            'has_key': true,
            'readiness': {
              'state': 'needs_action',
              'code': 'runtime_missing',
              'can_run': false,
              'primary_action': 'install_runtime',
            },
          },
        },
      },
      'tasks': [],
      'runtime': {},
      'environment': {},
    });

    expect(snapshot.configReadiness.asrConfigured, isFalse);
    expect(snapshot.configReadiness.asrState, 'needs_action');
    expect(snapshot.configReadiness.asrCode, 'runtime_missing');
    expect(snapshot.asrProviders.single.readiness.statusLabel, '组件未安装');
  });

  test('ASR operation parses progress and terminal state', () {
    final active = AsrOperationStatus.fromJson({
      'id': 'asr_1',
      'kind': 'setup',
      'item_id': 'large-v3',
      'state': 'running',
      'phase': 'model',
      'phase_index': 1,
      'phase_count': 3,
      'bytes_done': 25,
      'bytes_total': 100,
    });
    final failed = AsrOperationStatus.fromJson({
      'id': 'asr_2',
      'kind': 'runtime',
      'item_id': 'managed:faster-whisper',
      'state': 'failed',
      'error_code': 'checksum_mismatch',
    });

    expect(active.active, isTrue);
    expect(active.progress, 0.25);
    expect(active.phase, 'model');
    expect(active.phaseIndex, 1);
    expect(active.phaseCount, 3);
    expect(failed.active, isFalse);
    expect(failed.errorCode, 'checksum_mismatch');
  });

  test('DesktopSnapshot infers ASR engine labels from legacy provider ids', () {
    final snapshot = DesktopSnapshot.fromJson({
      'config': {
        'pipeline': {'asr_provider': 'funasr_sensevoice_local'},
        'asr_providers': {
          'local': {'name': 'Local ASR', 'has_key': true},
          'funasr_sensevoice_local': {
            'name': 'SenseVoice local service',
            'has_key': true,
          },
          'openai_whisper': {'name': 'Whisper', 'has_key': true},
        },
      },
      'tasks': [],
      'runtime': {},
      'environment': {},
    });

    final byName = {
      for (final option in snapshot.asrProviders) option.name: option,
    };
    expect(byName['local']?.displayLabel, '本机 Whisper');
    expect(byName['funasr_sensevoice_local']?.displayLabel, 'FunASR');
    expect(byName['openai_whisper']?.displayLabel, 'OpenAI Whisper');
    expect(snapshot.asrLabel, 'FunASR');
  });

  test('DesktopSnapshot reads local ASR model_size as selected model', () {
    final snapshot = DesktopSnapshot.fromJson({
      'config': {
        'routing': {
          'primary': {'provider': 'p1', 'model': 'model-a'},
        },
        'pipeline': {'asr_provider': 'local'},
        'providers': [
          {'name': 'p1', 'has_key': true},
        ],
        'asr_providers': {
          'local': {
            'name': 'local',
            'kind': 'local_inprocess',
            'protocol': 'faster_whisper',
            'local': {'model_size': 'large-v3', 'device': 'auto'},
            'has_key': true,
          },
        },
      },
      'tasks': [],
      'runtime': {},
      'environment': {},
    });

    expect(snapshot.asrModel, 'large-v3');
    expect(snapshot.asrProviders.single.name, 'local');
    expect(snapshot.asrProviders.single.displayName, 'local');
    expect(snapshot.asrProviders.single.model, 'large-v3');
    expect(snapshot.configReadiness.asrConfigured, isTrue);
    expect(snapshot.configReadiness.asrLabel, '本机 Whisper');
    expect(snapshot.asrLabel, '本机 Whisper');
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

  test('TaskResultWorkspace parses result review payload', () {
    final workspace = TaskResultWorkspace.fromJson({
      'task': {
        'task_id': 'tvx_done',
        'status': 'DONE',
        'input_file': r'D:\movie.srt',
        'task_dir': r'D:\artifacts\tvx_done',
      },
      'segments': [
        {
          'id': 7,
          'start': 1.2,
          'end': 3.4,
          'text_src': 'Hello',
          'text_tgt': '你好',
          'provider': 'p1',
          'model': 'm1',
          'compat_mode': 'openai_chat',
          'chunk_id': 'chunk-1',
          'issues': ['译文为空'],
          'quality_issues': [
            {'code': 'empty_target', 'message': 'empty target'},
            {'code': 'cps_too_high', 'message': 'too fast'},
            {'code': 'line_too_long', 'message': 'long line'},
            {'code': 'line_too_wide', 'message': 'wide line'},
          ],
        },
      ],
      'quality': {'hard_issues': 1},
      'delivery': {
        'srt': {'lines': 1},
      },
      'reflow': {'enabled': true},
      'memory': {'entries': 2},
      'output_paths': {'srt': r'D:\movie.zh-CN.srt'},
    });

    expect(workspace.task.taskId, 'tvx_done');
    expect(workspace.task.taskDir, r'D:\artifacts\tvx_done');
    expect(workspace.hasSegments, isTrue);
    expect(workspace.segments.single.timeRangeLabel, '00:01.200 - 00:03.400');
    expect(workspace.segments.single.sourceText, 'Hello');
    expect(workspace.segments.single.targetText, '你好');
    expect(workspace.segments.single.provider, 'p1');
    expect(workspace.issueCount, 3);
    expect(workspace.outputPaths, {'srt': r'D:\movie.zh-CN.srt'});
  });

  test(
    'AppServiceClient calls runtime and result methods with typed payloads',
    () async {
      final transport = _RecordingTransport({
        'tasks.list': [
          {
            'task_id': 'tvx_done',
            'status': 'DONE',
            'input_file': r'D:\done.mp4',
            'task_dir': r'D:\artifacts\tvx_done',
          },
        ],
        'runtime.submitRun': {
          'ok': true,
          'task_id': 'tvx_1',
          'status': 'QUEUED',
          'task_dir': r'D:\artifacts\tvx_1',
          'terminal': false,
          'message': 'Task queued.',
        },
        'runtime.submitResume': {
          'ok': true,
          'task_id': 'tvx_1',
          'status': 'QUEUED',
          'task_dir': r'D:\artifacts\tvx_1',
          'terminal': false,
          'message': 'Resume queued.',
        },
        'runtime.cancel': {
          'task_id': 'tvx_1',
          'status': 'CANCEL_REQUESTED',
          'input_file': r'D:\input.mp4',
          'runtime': {'can_cancel': true},
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
          'task': {
            'task_id': 'tvx_1',
            'status': 'DONE',
            'input_file': r'D:\input.mp4',
          },
          'segments': [
            {'id': 1, 'start': 0, 'end': 1, 'text_src': 'Hi'},
          ],
          'output_paths': {'srt': r'D:\out.srt'},
        },
        'result.segments.save': {
          'task': {
            'task_id': 'tvx_1',
            'status': 'DONE',
            'input_file': r'D:\input.mp4',
          },
          'segments': [
            {'id': 1, 'start': 0, 'end': 1, 'text_src': 'Hi', 'text_tgt': '嗨'},
          ],
          'output_paths': {'srt': r'D:\out.srt'},
        },
        'result.reexport': {
          'output_paths': {'srt': r'E:\fixed-output\out.srt'},
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
      final tasks = await client.taskList();
      final events = await client.taskEvents('tvx_1', cursor: 0, limit: 10);
      final result = await client.resultOpen('tvx_1');
      final workspace = await client.openTaskResult('tvx_1');
      final savedWorkspace = await client.resultSegmentsSave('tvx_1', [
        {'id': 1, 'start': 0, 'end': 1, 'text_src': 'Hi', 'text_tgt': '嗨'},
      ]);
      final reexported = await client.resultReexport(
        'tvx_1',
        outputFormat: 'srt',
        outputDir: r'E:\fixed-output',
        bilingual: false,
      );
      final resumed = await client.submitResume({
        'request_version': 1,
        'task_id': 'tvx_1',
        'overrides': {'output_format': 'srt'},
      });
      final cancelled = await client.cancel('tvx_1');

      expect(submitted.taskId, 'tvx_1');
      expect(resumed.message, 'Resume queued.');
      expect(cancelled.status, 'CANCEL_REQUESTED');
      expect(runtime.activeTaskId, 'tvx_1');
      expect(runtime.queued, ['tvx_2']);
      expect(tasks.single.taskId, 'tvx_done');
      expect(tasks.single.taskDir, r'D:\artifacts\tvx_done');
      expect(events.events, hasLength(1));
      expect(result['output_paths'], {'srt': r'D:\out.srt'});
      expect(workspace.task.taskId, 'tvx_1');
      expect(workspace.segments.single.id, 1);
      expect(savedWorkspace.segments.single.targetText, '嗨');
      expect(reexported['output_paths'], {'srt': r'E:\fixed-output\out.srt'});
      expect(
        transport.calls.first.params['request'],
        containsPair('input', r'D:\input.mp4'),
      );
      expect(transport.calls[3].params, containsPair('cursor', 0));
      expect(transport.calls[3].params, containsPair('limit', 10));
      expect(transport.calls[6].method, 'result.segments.save');
      expect(transport.calls[6].params, containsPair('task_id', 'tvx_1'));
      expect(transport.calls[6].params['segments'], isA<List>());
      expect(transport.calls[7].method, 'result.reexport');
      expect(transport.calls[7].params, containsPair('task_id', 'tvx_1'));
      expect(transport.calls[7].params, containsPair('output_format', 'srt'));
      expect(
        transport.calls[7].params,
        containsPair('output_dir', r'E:\fixed-output'),
      );
      expect(transport.calls[7].params, containsPair('bilingual', false));
      expect(transport.calls[8].method, 'runtime.submitResume');
      expect(
        transport.calls[8].params['request'],
        containsPair('task_id', 'tvx_1'),
      );
      expect(transport.calls[9].method, 'runtime.cancel');
      expect(transport.calls[9].params, containsPair('task_id', 'tvx_1'));
      expect(transport.calls[9].params, containsPair('force', false));
    },
  );

  test(
    'AppServiceClient creates a translation task from saved source',
    () async {
      final transport = _RecordingTransport({
        'runtime.retranslate': {
          'ok': true,
          'task_id': 'tvx_child',
          'status': 'QUEUED',
          'task_dir': r'D:\artifacts\tvx_child',
          'terminal': false,
          'message': 'Task queued.',
        },
      });
      final client = AppServiceClient(transport);

      final result = await client.retranslate(
        'tvx_parent',
        provider: 'p2',
        model: 'm2',
        overrides: {'memory_bootstrap_enabled': false},
      );

      expect(result.taskId, 'tvx_child');
      expect(transport.calls.single.method, 'runtime.retranslate');
      expect(transport.calls.single.params, {
        'task_id': 'tvx_parent',
        'provider': 'p2',
        'model': 'm2',
        'overrides': {'memory_bootstrap_enabled': false},
      });
    },
  );

  test('LocalServiceSupervisor talks to real app service process', () async {
    final serviceRoot = await Directory.systemTemp.createTemp(
      'transvortex_service_smoke_',
    );
    File(
      '${serviceRoot.path}${Platform.pathSeparator}pipeline.yaml',
    ).writeAsStringSync('artifacts_dir: artifacts\n', encoding: utf8);
    File(
      '${serviceRoot.path}${Platform.pathSeparator}providers.yaml',
    ).writeAsStringSync('''
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: PROVIDER_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
''', encoding: utf8);
    File(
      '${serviceRoot.path}${Platform.pathSeparator}demo.mp4',
    ).writeAsBytesSync(const [0, 1, 2, 3]);
    final repoRoot = Directory.current.parent;
    final supervisor = LocalServiceSupervisor(
      repoRoot: repoRoot,
      serviceRoot: serviceRoot,
      pythonExecutable: Platform.isWindows ? 'python' : 'python3',
      requestTimeout: const Duration(seconds: 10),
    );
    final session = await supervisor.start();
    addTearDown(() async {
      await session.shutdown();
      await _deleteDirectoryWithRetries(serviceRoot);
    });

    final info = await session.client.info();
    final snapshot = await session.client.desktopSnapshot();
    final submitted = await session.client.submitRun({
      'request_version': 1,
      'input': '${serviceRoot.path}${Platform.pathSeparator}demo.mp4',
      'source_lang': 'en',
      'target_lang': 'zh-CN',
      'provider': 'p1',
      'model': 'm1',
    });
    final cancelled = await session.client.cancel(
      submitted.taskId,
      force: false,
    );
    final events = await session.client.taskEvents(submitted.taskId, limit: 10);

    expect(info.service, 'transvortex.app_service');
    expect(snapshot.configReadiness.translationLabel, 'p1');
    expect(submitted.status, 'QUEUED');
    expect(cancelled.status, 'CANCEL_REQUESTED');
    expect(events.events, isNotEmpty);
    expect(events.events.first, isA<Map>());
  });

  test(
    'LocalServiceSupervisor applies product workspace to real app service',
    () async {
      final desktopHome = await Directory.systemTemp.createTemp(
        'transvortex_product_home_',
      );
      addTearDown(() => _deleteDirectoryWithRetries(desktopHome));
      final appPaths = _desktopPaths(desktopHome);
      final supervisor = LocalServiceSupervisor(
        repoRoot: Directory.current.parent,
        appPaths: appPaths,
        pythonExecutable: Platform.isWindows ? 'python' : 'python3',
        requestTimeout: const Duration(seconds: 20),
      );
      final session = await supervisor.start();
      addTearDown(session.shutdown);

      final snapshot = await session.client.desktopSnapshot();
      final expectedConfig = appPaths.configRoot.resolveSymbolicLinksSync();
      final expectedTasks = appPaths.tasksRoot.resolveSymbolicLinksSync();
      final expectedCache = appPaths.cacheRoot.resolveSymbolicLinksSync();

      expect(snapshot.config['root_dir'], expectedConfig);
      expect(snapshot.config['artifacts_dir'], expectedTasks);
      expect(Directory(expectedTasks).existsSync(), isTrue);
      expect(Directory(expectedCache).existsSync(), isTrue);
      expect(expectedConfig.contains('.transvortex-desktop'), isFalse);
    },
  );

  test(
    'LocalServiceSupervisor uses an isolated desktop runtime root',
    () async {
      final repoRoot = await Directory.systemTemp.createTemp(
        'transvortex_repo_root_',
      );
      final desktopHome = await Directory.systemTemp.createTemp(
        'transvortex_desktop_home_',
      );
      addTearDown(() => _deleteDirectoryWithRetries(repoRoot));
      addTearDown(() => _deleteDirectoryWithRetries(desktopHome));
      await Directory(
        '${repoRoot.path}${Platform.pathSeparator}src'
        '${Platform.pathSeparator}transvortex',
      ).create(recursive: true);
      File(
        '${repoRoot.path}${Platform.pathSeparator}src'
        '${Platform.pathSeparator}transvortex'
        '${Platform.pathSeparator}app_service.py',
      ).writeAsStringSync('# marker\n', encoding: utf8);
      File(
        '${repoRoot.path}${Platform.pathSeparator}pipeline.yaml',
      ).writeAsStringSync(
        'artifacts_dir: artifacts\nsource_mode: asr\n',
        encoding: utf8,
      );
      File(
        '${repoRoot.path}${Platform.pathSeparator}pipeline.desktop.yaml',
      ).writeAsStringSync(
        'artifacts_dir: desktop-artifacts\nsource_mode: asr\n',
        encoding: utf8,
      );
      File(
        '${repoRoot.path}${Platform.pathSeparator}providers.yaml',
      ).writeAsStringSync('providers: []\n', encoding: utf8);
      await Directory(
        '${repoRoot.path}${Platform.pathSeparator}artifacts',
      ).create(recursive: true);

      String? executable;
      List<String>? arguments;
      String? capturedWorkingDirectory;
      Map<String, String>? capturedEnvironment;
      final appPaths = _desktopPaths(desktopHome);
      final supervisor = LocalServiceSupervisor(
        repoRoot: repoRoot,
        appPaths: appPaths,
        pythonExecutable: 'python-test',
        processStarter:
            (
              String startedExecutable,
              List<String> startedArguments, {
              String? workingDirectory,
              Map<String, String>? environment,
            }) async {
              executable = startedExecutable;
              arguments = List<String>.from(startedArguments);
              capturedWorkingDirectory = workingDirectory;
              capturedEnvironment = environment;
              return _FakeProcess();
            },
      );

      await supervisor.start();

      final runtimeRoot = appPaths.configRoot;
      final runtimeArtifacts = appPaths.tasksRoot;
      final runtimeCache = appPaths.cacheRoot;
      expect(executable, 'python-test');
      expect(arguments, [
        '-m',
        'transvortex.app_service',
        '--root',
        runtimeRoot.path,
        '--artifacts-dir',
        runtimeArtifacts.path,
        '--cache-dir',
        runtimeCache.path,
      ]);
      expect(capturedWorkingDirectory, repoRoot.path);
      expect(capturedEnvironment?['PYTHONIOENCODING'], 'utf-8');
      expect(runtimeRoot.existsSync(), isTrue);
      expect(
        File(
          '${runtimeRoot.path}${Platform.pathSeparator}pipeline.yaml',
        ).readAsStringSync(encoding: utf8),
        'artifacts_dir: desktop-artifacts\nsource_mode: asr\n',
      );
      expect(
        File(
          '${runtimeRoot.path}${Platform.pathSeparator}providers.yaml',
        ).readAsStringSync(encoding: utf8),
        'providers: []\n',
      );
      expect(runtimeArtifacts.existsSync(), isTrue);
      expect(
        Directory(
          '${repoRoot.path}${Platform.pathSeparator}.transvortex-desktop',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'LocalServiceSupervisor refreshes desktop provider defaults from repo',
    () async {
      final repoRoot = await Directory.systemTemp.createTemp(
        'transvortex_repo_root_',
      );
      final desktopHome = await Directory.systemTemp.createTemp(
        'transvortex_desktop_home_',
      );
      addTearDown(() => _deleteDirectoryWithRetries(repoRoot));
      addTearDown(() => _deleteDirectoryWithRetries(desktopHome));
      File(
        '${repoRoot.path}${Platform.pathSeparator}pipeline.yaml',
      ).writeAsStringSync('artifacts_dir: repo-artifacts\n', encoding: utf8);
      File(
        '${repoRoot.path}${Platform.pathSeparator}providers.yaml',
      ).writeAsStringSync('providers: [fresh]\n', encoding: utf8);

      final appPaths = _desktopPaths(desktopHome);
      final runtimeRoot = appPaths.configRoot;
      await runtimeRoot.create(recursive: true);
      File(
        '${runtimeRoot.path}${Platform.pathSeparator}pipeline.yaml',
      ).writeAsStringSync('artifacts_dir: runtime-artifacts\n', encoding: utf8);
      File(
        '${runtimeRoot.path}${Platform.pathSeparator}providers.yaml',
      ).writeAsStringSync('providers: [stale]\n', encoding: utf8);

      final supervisor = LocalServiceSupervisor(
        repoRoot: repoRoot,
        appPaths: appPaths,
        pythonExecutable: 'python-test',
        processStarter:
            (
              String startedExecutable,
              List<String> startedArguments, {
              String? workingDirectory,
              Map<String, String>? environment,
            }) async {
              return _FakeProcess();
            },
      );

      await supervisor.start();

      expect(
        File(
          '${runtimeRoot.path}${Platform.pathSeparator}providers.yaml',
        ).readAsStringSync(encoding: utf8),
        'providers: [fresh]\n',
      );
      expect(
        File(
          '${runtimeRoot.path}${Platform.pathSeparator}pipeline.yaml',
        ).readAsStringSync(encoding: utf8),
        'artifacts_dir: runtime-artifacts\n',
      );
    },
  );

  test(
    'LocalServiceSupervisor uses bundled app runtime without PYTHONPATH',
    () async {
      final appRoot = await Directory.systemTemp.createTemp(
        'transvortex_bundled_app_',
      );
      final desktopHome = await Directory.systemTemp.createTemp(
        'transvortex_bundled_home_',
      );
      addTearDown(() => _deleteDirectoryWithRetries(appRoot));
      addTearDown(() => _deleteDirectoryWithRetries(desktopHome));
      final runtimeRoot = Directory(
        '${appRoot.path}${Platform.pathSeparator}runtime',
      );
      final runtimePython = File(
        '${runtimeRoot.path}${Platform.pathSeparator}python'
        '${Platform.pathSeparator}python.exe',
      );
      await runtimePython.parent.create(recursive: true);
      await runtimePython.writeAsBytes(const []);
      await File(
        '${runtimeRoot.path}${Platform.pathSeparator}app_runtime.json',
      ).writeAsString('{"schema_version":1}', encoding: utf8);
      final mediaToolsRoot = Directory(
        '${appRoot.path}${Platform.pathSeparator}tools'
        '${Platform.pathSeparator}ffmpeg',
      );
      await File(
        '${mediaToolsRoot.path}${Platform.pathSeparator}ffmpeg_runtime.json',
      ).create(recursive: true);
      final mediaBin = Directory(
        '${mediaToolsRoot.path}${Platform.pathSeparator}bin',
      );
      await File(
        '${mediaBin.path}${Platform.pathSeparator}ffmpeg.exe',
      ).create(recursive: true);
      await File(
        '${mediaBin.path}${Platform.pathSeparator}ffprobe.exe',
      ).create(recursive: true);
      await File(
        '${appRoot.path}${Platform.pathSeparator}pipeline.yaml',
      ).writeAsString('artifacts_dir: artifacts\n', encoding: utf8);
      await File(
        '${appRoot.path}${Platform.pathSeparator}providers.yaml',
      ).writeAsString('providers: []\n', encoding: utf8);

      String? executable;
      List<String>? capturedArguments;
      String? capturedWorkingDirectory;
      Map<String, String>? capturedEnvironment;
      final supervisor = LocalServiceSupervisor(
        repoRoot: appRoot,
        appPaths: _desktopPaths(desktopHome),
        processStarter:
            (
              String startedExecutable,
              List<String> startedArguments, {
              String? workingDirectory,
              Map<String, String>? environment,
            }) async {
              executable = startedExecutable;
              capturedArguments = List<String>.from(startedArguments);
              capturedWorkingDirectory = workingDirectory;
              capturedEnvironment = environment;
              return _FakeProcess();
            },
      );

      await supervisor.start();

      expect(executable, runtimePython.path);
      expect(capturedArguments?.take(2), ['-m', 'transvortex.app_service']);
      expect(capturedWorkingDirectory, appRoot.path);
      expect(capturedEnvironment?['PYTHONPATH'], '');
      expect(capturedEnvironment?['PYTHONNOUSERSITE'], '1');
      expect(
        capturedEnvironment?['TRANSVORTEX_MEDIA_TOOLS_DIR'],
        mediaBin.path,
      );
      expect(
        Directory('${appRoot.path}${Platform.pathSeparator}src').existsSync(),
        isFalse,
      );
    },
  );

  test(
    'LocalServiceSupervisor does not fall back from a broken runtime',
    () async {
      final appRoot = await Directory.systemTemp.createTemp(
        'transvortex_broken_runtime_',
      );
      addTearDown(() => _deleteDirectoryWithRetries(appRoot));
      final runtimeRoot = Directory(
        '${appRoot.path}${Platform.pathSeparator}runtime',
      );
      await runtimeRoot.create(recursive: true);
      await File(
        '${runtimeRoot.path}${Platform.pathSeparator}app_runtime.json',
      ).writeAsString('{"schema_version":1}', encoding: utf8);

      final supervisor = LocalServiceSupervisor(repoRoot: appRoot);

      await expectLater(
        supervisor.start(),
        throwsA(
          isA<LocalServiceLaunchException>().having(
            (error) => error.message,
            'message',
            contains('runtime 不完整'),
          ),
        ),
      );
    },
  );

  test(
    'LocalServiceSupervisor rejects incomplete bundled FFmpeg tools',
    () async {
      final appRoot = await Directory.systemTemp.createTemp(
        'transvortex_broken_ffmpeg_',
      );
      addTearDown(() => _deleteDirectoryWithRetries(appRoot));
      await File(
        '${appRoot.path}${Platform.pathSeparator}runtime'
        '${Platform.pathSeparator}app_runtime.json',
      ).create(recursive: true);
      await File(
        '${appRoot.path}${Platform.pathSeparator}runtime'
        '${Platform.pathSeparator}python'
        '${Platform.pathSeparator}python.exe',
      ).create(recursive: true);
      await File(
        '${appRoot.path}${Platform.pathSeparator}tools'
        '${Platform.pathSeparator}ffmpeg'
        '${Platform.pathSeparator}ffmpeg_runtime.json',
      ).create(recursive: true);

      final supervisor = LocalServiceSupervisor(repoRoot: appRoot);

      await expectLater(
        supervisor.start(),
        throwsA(
          isA<LocalServiceLaunchException>().having(
            (error) => error.message,
            'message',
            contains('FFmpeg 工具不完整'),
          ),
        ),
      );
    },
  );

  test('LocalServiceSupervisor preserves local provider overrides', () async {
    final repoRoot = await Directory.systemTemp.createTemp(
      'transvortex_repo_root_',
    );
    final desktopHome = await Directory.systemTemp.createTemp(
      'transvortex_desktop_home_',
    );
    addTearDown(() => _deleteDirectoryWithRetries(repoRoot));
    addTearDown(() => _deleteDirectoryWithRetries(desktopHome));
    File(
      '${repoRoot.path}${Platform.pathSeparator}pipeline.yaml',
    ).writeAsStringSync('artifacts_dir: repo-artifacts\n', encoding: utf8);
    File(
      '${repoRoot.path}${Platform.pathSeparator}providers.yaml',
    ).writeAsStringSync('providers: [fresh]\n', encoding: utf8);

    final appPaths = _desktopPaths(desktopHome);
    final runtimeRoot = appPaths.configRoot;
    await runtimeRoot.create(recursive: true);
    File(
      '${runtimeRoot.path}${Platform.pathSeparator}providers.yaml',
    ).writeAsStringSync('providers: [stale]\n', encoding: utf8);
    File(
      '${runtimeRoot.path}${Platform.pathSeparator}providers.local.yaml',
    ).writeAsStringSync('providers: [local]\n', encoding: utf8);

    final supervisor = LocalServiceSupervisor(
      repoRoot: repoRoot,
      appPaths: appPaths,
      pythonExecutable: 'python-test',
      processStarter:
          (
            String startedExecutable,
            List<String> startedArguments, {
            String? workingDirectory,
            Map<String, String>? environment,
          }) async {
            return _FakeProcess();
          },
    );

    await supervisor.start();

    expect(
      File(
        '${runtimeRoot.path}${Platform.pathSeparator}providers.yaml',
      ).readAsStringSync(encoding: utf8),
      'providers: [stale]\n',
    );
    expect(
      File(
        '${runtimeRoot.path}${Platform.pathSeparator}providers.local.yaml',
      ).readAsStringSync(encoding: utf8),
      'providers: [local]\n',
    );
  });

  test(
    'LocalServiceSupervisor runs a real embedded-subtitle worker to DONE',
    () async {
      final serviceRoot = await Directory.systemTemp.createTemp(
        'transvortex_worker_smoke_',
      );
      File(
        '${serviceRoot.path}${Platform.pathSeparator}pipeline.yaml',
      ).writeAsStringSync('artifacts_dir: artifacts\n', encoding: utf8);
      File(
        '${serviceRoot.path}${Platform.pathSeparator}providers.yaml',
      ).writeAsStringSync('''
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: PROVIDER_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
''', encoding: utf8);
      final video = await _writeEmbeddedSubtitleVideo(serviceRoot);
      final repoRoot = Directory.current.parent;
      final supervisor = LocalServiceSupervisor(
        repoRoot: repoRoot,
        serviceRoot: serviceRoot,
        pythonExecutable: Platform.isWindows ? 'python' : 'python3',
        requestTimeout: const Duration(seconds: 10),
      );
      final session = await supervisor.start();
      String? submittedTaskId;
      addTearDown(() async {
        final taskId = submittedTaskId;
        if (taskId != null) {
          try {
            final snapshot = await session.client.desktopSnapshot();
            final task = snapshot.taskById(taskId);
            if (task?.isTerminal != true) {
              await session.client.cancel(taskId, force: true);
            }
          } on Object {
            // Best effort cleanup for a worker smoke that may already be done.
          }
        }
        await session.shutdown();
        await _deleteDirectoryWithRetries(serviceRoot);
      });

      final submitted = await session.client.submitRun({
        'request_version': 1,
        'input_type': 'video_asr',
        'input': video.path,
        'source_lang': 'en',
        'target_lang': 'zh-CN',
        'source_mode': 'embedded_subtitle',
      });
      submittedTaskId = submitted.taskId;
      final completed = await _waitForTerminalTask(
        session.client,
        submitted.taskId,
      );
      final events = await session.client.taskEvents(submitted.taskId);

      expect(submitted.status, 'QUEUED');
      expect(completed.status, 'DONE');
      expect(completed.outputPath, isNotNull);
      expect(completed.outputPaths['segments'], completed.outputPath);
      final output = File(completed.outputPath!);
      expect(output.existsSync(), isTrue);
      expect(
        output.readAsStringSync(encoding: utf8),
        contains('Hello from subtitle'),
      );
      expect(
        events.events.any((event) => event is Map && event['type'] == 'done'),
        isTrue,
      );
    },
    skip: _hasEmbeddedSubtitleSmokeTools()
        ? false
        : 'ffmpeg and ffprobe are required for the real worker smoke',
  );

  test(
    'LocalServiceSupervisor drives a real worker cancel to CANCELLED',
    () async {
      final serviceRoot = await Directory.systemTemp.createTemp(
        'transvortex_worker_cancel_smoke_',
      );
      final slowAsr = await _SlowAsrServer.start();
      addTearDown(() => slowAsr.close());
      File(
        '${serviceRoot.path}${Platform.pathSeparator}pipeline.yaml',
      ).writeAsStringSync('''
artifacts_dir: artifacts
source_mode: asr
asr:
  provider: slow_asr
asr_providers:
  - name: slow_asr
    kind: local_server
    protocol: openai_transcriptions
    base_url: http://127.0.0.1:${slowAsr.port}
    endpoint: /v1/audio/transcriptions
    model: whisper-test
    auth:
      type: none
    execution:
      concurrency: 1
      timeout_seconds: 10
      retry: 1
    chunking:
      mode: none
      window_seconds: 30
      max_window_seconds: 30
      min_window_seconds: 1
      overlap_seconds: 0
      short_audio_seconds: 30
    preprocessing:
      trim_silence:
        enabled: false
''', encoding: utf8);
      File(
        '${serviceRoot.path}${Platform.pathSeparator}providers.yaml',
      ).writeAsStringSync('''
providers:
  - name: p1
    api_type: openai
    base_url: https://example.com/v1
    env_key: PROVIDER_KEY
    models: [m1]
routing:
  primary: {provider: p1, model: m1}
''', encoding: utf8);
      final video = await _writeAudioVideo(serviceRoot);
      final repoRoot = Directory.current.parent;
      final supervisor = LocalServiceSupervisor(
        repoRoot: repoRoot,
        serviceRoot: serviceRoot,
        pythonExecutable: Platform.isWindows ? 'python' : 'python3',
        requestTimeout: const Duration(seconds: 10),
      );
      final session = await supervisor.start();
      String? submittedTaskId;
      addTearDown(() async {
        final taskId = submittedTaskId;
        if (taskId != null) {
          try {
            final snapshot = await session.client.desktopSnapshot();
            final task = snapshot.taskById(taskId);
            if (task?.isTerminal != true) {
              await session.client.cancel(taskId, force: true);
            }
          } on Object {
            // Best effort cleanup for a worker smoke that may already be done.
          }
        }
        await session.shutdown();
        await _deleteDirectoryWithRetries(serviceRoot);
      });

      final submitted = await session.client.submitRun({
        'request_version': 1,
        'input_type': 'video_asr',
        'input': video.path,
        'source_lang': 'en',
        'target_lang': 'zh-CN',
        'source_mode': 'asr',
      });
      submittedTaskId = submitted.taskId;
      await _waitForSlowAsrRequestOrFail(
        slowAsr,
        client: session.client,
        transport: session.transport,
        serviceRoot: serviceRoot,
        taskId: submitted.taskId,
      );
      final cancelRequested = await session.client.cancel(submitted.taskId);
      slowAsr.release();
      final terminal = await _waitForTerminalTask(
        session.client,
        submitted.taskId,
      );
      final events = await session.client.taskEvents(submitted.taskId);

      expect(cancelRequested.status, 'CANCEL_REQUESTED');
      expect(terminal.status, 'CANCELLED');
      expect(
        events.events.any(
          (event) => event is Map && event['type'] == 'cancel_requested',
        ),
        isTrue,
      );
      expect(
        events.events.any(
          (event) => event is Map && event['type'] == 'cancelled',
        ),
        isTrue,
      );
      expect(
        events.events.any((event) => event is Map && event['type'] == 'done'),
        isFalse,
      );
    },
    skip: _hasEmbeddedSubtitleSmokeTools()
        ? false
        : 'ffmpeg and ffprobe are required for the real worker smoke',
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test('AppServiceClient calls provider and ASR admin methods', () async {
    final transport = _RecordingTransport({
      'provider.save': {'ok': true},
      'provider.models': {
        'status': 'PASS',
        'models': ['model-a'],
      },
      'provider.test': {'status': 'PASS', 'checks': []},
      'provider.delete': {'deleted': true},
      'provider.routing.save': {
        'routing': {
          'primary': {'provider': 'p1', 'model': 'model-a'},
        },
      },
      'asr.provider.save': {'ok': true, 'provider': 'openai_whisper'},
      'asr.setup.start': {
        'id': 'asr_setup_small',
        'kind': 'setup',
        'item_id': 'small',
        'state': 'queued',
        'phase': 'runtime',
        'phase_index': 0,
        'phase_count': 3,
      },
      'asr.storage.set': {
        'root': r'D:\TransVortex-ASR',
        'default_root': r'C:\Users\tester\AppData\Local\TransVortex',
        'customized': true,
        'free_bytes': 5000000000,
        'reserve_bytes': 268435456,
        'space_known': true,
        'writable': true,
        'can_change': true,
      },
      'network.settings.save': {
        'ok': true,
        'network': {'mode': 'local_proxy', 'proxy_port': 7890},
      },
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
    await client.providerTest(
      providerDraft: {'name': 'p1'},
      model: 'model-a',
      reasoningEffort: 'high',
    );
    await client.providerDelete(
      name: 'p1',
      expectedVersion: {'mtime_ns': 7, 'size': 8},
    );
    await client.saveTranslationRouting(
      provider: 'p1',
      model: 'model-a',
      fallback: [
        {'provider': 'p2', 'model': 'model-b'},
      ],
      expectedVersion: {'mtime_ns': 1, 'size': 2},
    );
    await client.saveTranslationRoutingProfiles(
      profiles: [
        {
          'id': 'route_1',
          'name': '配置 1',
          'primary': {'provider': 'p1', 'model': 'model-a'},
          'fallback': [],
        },
      ],
      activeProfile: 'route_1',
      nextProfileSeq: 2,
      expectedVersion: {'mtime_ns': 5, 'size': 6},
    );
    await client.asrProviderSave(
      providerDraft: {
        'name': 'openai_whisper',
        'kind': 'remote',
        'model': 'whisper-1',
      },
      expectedVersion: {'mtime_ns': 3, 'size': 4},
    );
    final setup = await client.asrSetupStart('small');
    final storage = await client.asrStorageSet(r'D:\TransVortex-ASR');
    await client.networkSettingsSave(
      mode: 'local_proxy',
      proxyPort: 7890,
      expectedVersion: {'mtime_ns': 9, 'size': 10},
    );

    expect(transport.calls.map((call) => call.method), [
      'provider.save',
      'provider.models',
      'provider.test',
      'provider.delete',
      'provider.routing.save',
      'provider.routing.save',
      'asr.provider.save',
      'asr.setup.start',
      'asr.storage.set',
      'network.settings.save',
    ]);
    expect(setup.kind, 'setup');
    expect(setup.phase, 'runtime');
    expect(storage.root, r'D:\TransVortex-ASR');
    expect(storage.customized, isTrue);
    expect(storage.hasSpaceFor(1000000000), isTrue);
    expect(transport.calls[7].params, {'model_id': 'small'});
    expect(transport.calls[8].params, {'storage_root': r'D:\TransVortex-ASR'});
    expect(transport.calls.first.params['api_key'], 'secret');
    expect(transport.calls[2].params['reasoning_effort'], 'high');
    expect(transport.calls[3].params['name'], 'p1');
    expect(transport.calls[3].params['expected_version'], {
      'mtime_ns': 7,
      'size': 8,
    });
    expect(transport.calls[3].params.containsKey('api_key'), isFalse);
    expect(transport.calls[4].params['primary'], {
      'provider': 'p1',
      'model': 'model-a',
    });
    expect(transport.calls[4].params['fallback'], [
      {'provider': 'p2', 'model': 'model-b'},
    ]);
    expect(transport.calls[4].params['expected_version'], {
      'mtime_ns': 1,
      'size': 2,
    });
    expect(transport.calls[5].params['active_profile'], 'route_1');
    expect(transport.calls[5].params['next_profile_seq'], 2);
    expect(transport.calls[5].params['expected_version'], {
      'mtime_ns': 5,
      'size': 6,
    });
    expect(
      transport.calls[6].params['provider_draft'],
      containsPair('kind', 'remote'),
    );
    expect(transport.calls[6].params['expected_version'], {
      'mtime_ns': 3,
      'size': 4,
    });
    expect(transport.calls.last.params, {
      'mode': 'local_proxy',
      'proxy_port': 7890,
      'expected_version': {'mtime_ns': 9, 'size': 10},
    });
  });

  test(
    'AppServiceClient validates an existing model with managed runtime',
    () async {
      final transport = _RecordingTransport({
        'asr.model.probe': {
          'ok': true,
          'model': {
            'model_id': 'large-v3',
            'model_path': r'D:\Models\large-v3',
          },
        },
      });
      final client = AppServiceClient(transport);

      final result = await client.probeManagedAsrModel(
        modelPath: r'D:\Models\large-v3',
        device: 'cpu',
      );

      expect(result['ok'], isTrue);
      expect(transport.calls.single.method, 'asr.model.probe');
      expect(transport.calls.single.params, {
        'model_path': r'D:\Models\large-v3',
        'device': 'cpu',
        'compute_type': 'auto',
      });
    },
  );

  test('AppServiceClient discovers models below a selected folder', () async {
    final transport = _RecordingTransport({
      'asr.model.discover': {
        'ok': true,
        'root': r'D:\Models',
        'scanned_directories': 12,
        'truncated': false,
        'candidates': [
          {
            'model_id': 'custom-123456789abc',
            'display_name': 'Custom faster-whisper model',
            'path': r'D:\Models\customer\snapshot',
            'relative_path': r'customer\snapshot',
            'model_bytes': 1234,
            'catalog_config_match': false,
          },
        ],
      },
    });
    final client = AppServiceClient(transport);

    final result = await client.discoverManagedAsrModels(r'D:\Models');

    expect(result.ok, isTrue);
    expect(result.scannedDirectories, 12);
    expect(result.candidates.single.modelId, 'custom-123456789abc');
    expect(result.candidates.single.modelBytes, 1234);
    expect(result.candidates.single.catalogConfigMatch, isFalse);
    expect(transport.calls.single.method, 'asr.model.discover');
    expect(transport.calls.single.params, {'search_root': r'D:\Models'});
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
      'runtime': {'can_resume': true, 'state': 'stale'},
      'input_type': 'video_asr_translate',
      'checkpoint_status': 'TRANSLATE',
      'progress_detail': {
        'translate_done_count': 2,
        'translate_total_chunks': 4,
        'model_request_count': 7,
        'model_request_counts': {
          'translate': 4,
          'memory_bootstrap_extract': 1,
          'memory_bootstrap_classify': 1,
          'batch_recovery': 1,
        },
      },
    });

    expect(task.taskId, 'tvx_1');
    expect(task.isFailed, isTrue);
    expect(task.inputType, 'video_asr_translate');
    expect(task.displayName, 'input.mp4');
    expect(task.canResume, isTrue);
    expect(task.runtimeState, 'stale');
    expect(task.isRuntimeActive, isFalse);
    expect(task.isRuntimeStale, isTrue);
    expect(task.latestProgress, 0.5);
    expect(task.displayStatus, 'TRANSLATE');
    expect(task.translationDoneCount, 2);
    expect(task.translationTotalChunks, 4);
    expect(task.modelRequestCount, 7);
    expect(task.modelRequestCounts['batch_recovery'], 1);
    expect(task.outputPaths['srt'], r'D:\out.srt');
  });

  test('TaskSummary identifies completed work that still needs review', () {
    final review = TaskSummary.fromJson({
      'task_id': 'tvx_review',
      'status': 'DONE',
      'progress_detail': {
        'quality_status': 'WARN',
        'quality_issue_counts': {'repaired': 12},
        'quality_residual_counts': {'cps_too_high': 2},
        'delivery_status': 'FAIL',
        'delivery_issue_counts': {
          'srt': {'empty_target': 1},
          'ass': {'line_too_long': 2},
        },
      },
    });
    final clean = TaskSummary.fromJson({
      'task_id': 'tvx_clean',
      'status': 'DONE',
      'progress_detail': {
        'quality_status': 'PASS',
        'quality_issue_counts': {'repaired': 99},
        'quality_residual_counts': {'cps_too_high': 0},
        'delivery_status': 'PASS',
        'delivery_issue_counts': {
          'srt': {'empty_target': 0},
        },
      },
    });
    final failed = TaskSummary.fromJson({
      'task_id': 'tvx_failed',
      'status': 'FAILED',
      'progress_detail': {'quality_status': 'WARN'},
    });
    final pendingExport = TaskSummary.fromJson({
      'task_id': 'tvx_pending_export',
      'status': 'DONE',
      'settings': {'result_revision': 3, 'result_export_revision': 2},
      'progress_detail': {'quality_status': 'PASS', 'delivery_status': 'PASS'},
    });

    expect(review.qualityStatus, 'WARN');
    expect(review.deliveryStatus, 'FAIL');
    expect(review.qualityResidualIssueCount, 2);
    expect(review.deliveryIssueCount, 3);
    expect(review.reviewIssueCount, 5);
    expect(review.needsReview, isTrue);
    expect(clean.needsReview, isFalse);
    expect(failed.needsReview, isFalse);
    expect(pendingExport.hasSavedResultPendingExport, isTrue);
    expect(pendingExport.reviewIssueCount, 0);
    expect(pendingExport.needsReview, isTrue);
  });

  test('TaskSummary does not infer task type from legacy file extension', () {
    final task = TaskSummary.fromJson({
      'task_id': 'tvx_jsonl',
      'status': 'FAILED',
      'input_file': r'D:\artifacts\segments.jsonl',
      'runtime': {'can_resume': true},
    });

    expect(task.inputType, isEmpty);
    expect(task.displayName, 'segments.jsonl');
  });

  test('DesktopSnapshot restores only runtime-active or terminal tasks', () {
    final staleThenQueued = DesktopSnapshot.fromJson({
      'tasks': [
        {
          'task_id': 'tvx_stale',
          'status': 'TRANSLATE',
          'runtime': {'state': 'stale'},
        },
        {
          'task_id': 'tvx_queued',
          'status': 'QUEUED',
          'runtime': {'state': 'queued'},
        },
      ],
    });
    final runningThenDone = DesktopSnapshot.fromJson({
      'tasks': [
        {
          'task_id': 'tvx_running',
          'status': 'TRANSLATE',
          'runtime': {'state': 'running'},
        },
        {'task_id': 'tvx_done', 'status': 'DONE'},
      ],
    });
    final terminalOnly = DesktopSnapshot.fromJson({
      'tasks': [
        {
          'task_id': 'tvx_interrupted',
          'status': 'INTERRUPTED',
          'runtime': {'state': 'interrupted'},
        },
      ],
    });

    expect(staleThenQueued.latestActiveTask, isNull);
    expect(runningThenDone.latestActiveTask?.taskId, 'tvx_running');
    expect(terminalOnly.latestActiveTask?.taskId, 'tvx_interrupted');
  });

  test('task labels localize runtime lifecycle stages', () {
    expect(taskStatusLabel('INIT'), '等待中');
    expect(taskStatusLabel('PRECHECK'), '检查环境');
    expect(taskStatusLabel('ASR'), '识别语音');
    expect(taskStatusLabel('MEMORY'), '准备术语');
    expect(taskStatusLabel('TRANSLATE'), '翻译字幕');
    expect(taskStatusLabel('EXPORT'), '写出字幕');
    expect(taskStageLabel('checkpoint: translate'), '翻译字幕');
    expect(taskEventTypeLabel('provider_attempt'), '模型请求');
    expect(taskEventTypeLabel('provider_response'), '模型返回');
    expect(
      taskEventMessageLabel(
        type: 'provider_response',
        message: 'Provider response received',
      ),
      '模型返回已接收',
    );
    expect(languageLabel('en'), '英语');
    expect(languageLabel('zh-CN'), '简体中文');
    expect(languageLabel('zh_TW'), '繁体中文');

    final initTask = TaskSummary.fromJson({
      'task_id': 'tvx_init',
      'status': 'INIT',
    });
    final asrTask = TaskSummary.fromJson({
      'task_id': 'tvx_asr',
      'status': 'ASR',
    });
    final memoryTask = TaskSummary.fromJson({
      'task_id': 'tvx_memory',
      'status': 'MEMORY',
    });

    expect(initTask.isActive, isTrue);
    expect(asrTask.isActive, isTrue);
    expect(memoryTask.isActive, isTrue);
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

  test('WindowStateBridge opens attached tool windows', () async {
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final opened = <AppWindowArgs>[];
    bridge.attachToolWindowOpener((args) async {
      opened.add(args);
    });

    await bridge.openToolWindow(AppWindowType.asrSettings);
    await bridge.openToolWindow(
      AppWindowType.taskProcessing,
      taskId: 'tvx_processing_1',
    );

    expect(opened.map((args) => args.type), [
      AppWindowType.asrSettings,
      AppWindowType.taskProcessing,
    ]);
    expect(opened[1].taskId, 'tvx_processing_1');
  });

  test('WindowStateBridge runs attached service refresher', () async {
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    var refreshCount = 0;
    bridge.attachServiceRefresher(() async {
      refreshCount += 1;
    });

    await bridge.refreshServiceSnapshot();

    expect(refreshCount, 1);
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

bool _hasEmbeddedSubtitleSmokeTools() {
  try {
    final ffmpeg = Process.runSync('ffmpeg', const ['-version']);
    final ffprobe = Process.runSync('ffprobe', const ['-version']);
    return ffmpeg.exitCode == 0 && ffprobe.exitCode == 0;
  } on Object {
    return false;
  }
}

Future<File> _writeEmbeddedSubtitleVideo(Directory root) async {
  final subtitle = File('${root.path}${Platform.pathSeparator}demo.en.srt');
  subtitle.writeAsStringSync(
    '1\n'
    '00:00:00,000 --> 00:00:00,800\n'
    'Hello from subtitle\n',
    encoding: utf8,
  );
  final video = File('${root.path}${Platform.pathSeparator}demo.mkv');
  final result = await Process.run('ffmpeg', [
    '-y',
    '-f',
    'lavfi',
    '-i',
    'color=c=black:s=160x90:d=1',
    '-f',
    'srt',
    '-i',
    subtitle.path,
    '-map',
    '0:v:0',
    '-map',
    '1:s:0',
    '-c:v',
    'ffv1',
    '-c:s',
    'srt',
    '-metadata:s:s:0',
    'language=eng',
    video.path,
  ]);
  if (result.exitCode != 0) {
    fail('ffmpeg could not create embedded-subtitle fixture: ${result.stderr}');
  }
  return video;
}

Future<File> _writeAudioVideo(Directory root) async {
  final video = File('${root.path}${Platform.pathSeparator}demo_audio.mkv');
  final result = await Process.run('ffmpeg', [
    '-y',
    '-f',
    'lavfi',
    '-i',
    'color=c=black:s=160x90:d=1',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=440:duration=1',
    '-map',
    '0:v:0',
    '-map',
    '1:a:0',
    '-c:v',
    'ffv1',
    '-c:a',
    'aac',
    '-shortest',
    video.path,
  ]);
  if (result.exitCode != 0) {
    fail('ffmpeg could not create audio-video fixture: ${result.stderr}');
  }
  return video;
}

Future<void> _waitForSlowAsrRequestOrFail(
  _SlowAsrServer slowAsr, {
  required AppServiceClient client,
  required JsonRpcTransport transport,
  required Directory serviceRoot,
  required String taskId,
  Duration timeout = const Duration(seconds: 45),
}) async {
  try {
    await slowAsr.firstRequest.timeout(timeout);
  } on TimeoutException catch (error) {
    fail(
      'slow ASR server did not receive a request within '
      '${timeout.inSeconds}s: $error\n'
      '${await _workerSmokeDiagnostics(client, transport, serviceRoot, taskId)}',
    );
  }
}

Future<String> _workerSmokeDiagnostics(
  AppServiceClient client,
  JsonRpcTransport transport,
  Directory serviceRoot,
  String taskId,
) async {
  final lines = <String>[];
  try {
    final health = await client.health();
    lines.add('health=${health.status}; pump=${jsonEncode(health.pump)}');
  } on Object catch (error) {
    lines.add('health_error=$error');
  }
  try {
    final snapshot = await client.desktopSnapshot();
    final task = snapshot.taskById(taskId);
    lines.add(
      'task=${task?.status ?? 'missing'}; checkpoint=${task?.displayStatus ?? 'missing'}; '
      'error=${task?.error ?? ''}; runtime=${jsonEncode(task?.runtime ?? {})}',
    );
    lines.add('runtime=${jsonEncode(snapshot.runtime)}');
  } on Object catch (error) {
    lines.add('snapshot_error=$error');
  }
  try {
    final events = await client.taskEvents(taskId);
    lines.add('events=${_eventTypeSummary(events.events)}');
  } on Object catch (error) {
    lines.add('events_error=$error');
  }
  lines.add('transport_diagnostics=${transport.diagnosticLines.join(' | ')}');
  final taskDir = Directory(
    '${serviceRoot.path}${Platform.pathSeparator}artifacts'
    '${Platform.pathSeparator}$taskId',
  );
  for (final relativePath in const [
    'runtime_request.json',
    'worker.json',
    'checkpoint.json',
    'worker/stdout.log',
    'worker/stderr.log',
  ]) {
    final file = File(
      '${taskDir.path}${Platform.pathSeparator}'
      '${relativePath.replaceAll('/', Platform.pathSeparator)}',
    );
    if (file.existsSync()) {
      lines.add('$relativePath=${_tailFile(file)}');
    } else {
      lines.add('$relativePath=<missing>');
    }
  }
  return lines.join('\n');
}

String _eventTypeSummary(List<Object?> events) {
  if (events.isEmpty) return '<none>';
  return events
      .map((event) {
        if (event is! Map) return '<non-map>';
        final type = event['type'] ?? '?';
        final stage = event['stage'] ?? '';
        final message = event['message'] ?? '';
        return '$type/$stage/$message';
      })
      .join(' | ');
}

String _tailFile(File file, {int maxChars = 4000}) {
  try {
    final text = file.readAsStringSync(encoding: utf8);
    if (text.length <= maxChars) return text;
    return text.substring(text.length - maxChars);
  } on Object catch (error) {
    return '<read_error: $error>';
  }
}

class _SlowAsrServer {
  _SlowAsrServer._(this._server);

  final HttpServer _server;
  final _firstRequest = Completer<void>();
  final _release = Completer<void>();

  int get port => _server.port;
  Future<void> get firstRequest => _firstRequest.future;

  static Future<_SlowAsrServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _SlowAsrServer._(server);
    unawaited(instance._serve());
    return instance;
  }

  void release() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  Future<void> close() async {
    release();
    await _server.close(force: true);
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      await request.drain<void>();
      if (!_firstRequest.isCompleted) {
        _firstRequest.complete();
      }
      await _release.future.timeout(const Duration(seconds: 20));
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'text': 'hello from slow asr',
          'segments': [
            {'start': 0.0, 'end': 0.8, 'text': 'hello from slow asr'},
          ],
        }),
      );
    } on Object catch (error, stackTrace) {
      if (!_firstRequest.isCompleted) {
        _firstRequest.completeError(error, stackTrace);
      }
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('slow asr error');
    } finally {
      await request.response.close();
    }
  }
}

Future<TaskSummary> _waitForTerminalTask(
  AppServiceClient client,
  String taskId, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  TaskSummary? latest;
  while (DateTime.now().isBefore(deadline)) {
    final snapshot = await client.desktopSnapshot();
    latest = snapshot.taskById(taskId);
    if (latest?.isTerminal == true) {
      return latest!;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  final status = latest == null
      ? 'not found in desktop snapshot'
      : '${latest.status}: ${latest.error ?? ''}';
  fail('task $taskId did not reach a terminal state: $status');
}

Future<void> _deleteDirectoryWithRetries(Directory directory) async {
  Object? lastError;
  StackTrace? lastStackTrace;
  for (var attempt = 0; attempt < 10; attempt += 1) {
    if (!await directory.exists()) return;
    try {
      await directory.delete(recursive: true);
      return;
    } on Object catch (error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;
      await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
    }
  }
  if (lastError != null) {
    Error.throwWithStackTrace(lastError, lastStackTrace ?? StackTrace.current);
  }
}

DesktopAppPaths _desktopPaths(Directory appDataRoot) {
  final workspaceRoot = Directory(
    '${appDataRoot.path}${Platform.pathSeparator}Workspace',
  );
  return DesktopAppPaths(
    appDataRoot: appDataRoot,
    configRoot: Directory('${appDataRoot.path}${Platform.pathSeparator}Config'),
    workspaceRoot: workspaceRoot,
    tasksRoot: Directory('${workspaceRoot.path}${Platform.pathSeparator}Tasks'),
    cacheRoot: Directory('${workspaceRoot.path}${Platform.pathSeparator}Cache'),
  );
}

class _FakeProcess implements Process {
  final _exit = Completer<int>();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 12345;

  @override
  IOSink get stdin => _FakeSink();

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) {
      _exit.complete(0);
    }
    return true;
  }
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

class _ControlledFlushSink implements IOSink {
  final writes = <Object?>[];
  final firstFlushStarted = Completer<void>();
  final secondFlushStarted = Completer<void>();
  Completer<void>? _activeFlush;
  int _flushCount = 0;
  bool closed = false;

  @override
  Encoding encoding = utf8;

  void _checkWritable() {
    final active = _activeFlush;
    if (active != null && !active.isCompleted) {
      throw StateError('StreamSink is bound to a stream');
    }
  }

  void releaseFlush() {
    final active = _activeFlush;
    if (active != null && !active.isCompleted) active.complete();
  }

  @override
  void add(List<int> data) {
    _checkWritable();
    writes.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    _checkWritable();
    await for (final data in stream) {
      writes.add(data);
    }
  }

  @override
  Future<void> close() async {
    releaseFlush();
    closed = true;
  }

  @override
  Future<void> get done async {}

  @override
  Future<void> flush() {
    _checkWritable();
    final completer = Completer<void>();
    _activeFlush = completer;
    _flushCount += 1;
    if (_flushCount == 1) firstFlushStarted.complete();
    if (_flushCount == 2) secondFlushStarted.complete();
    return completer.future.whenComplete(() {
      if (identical(_activeFlush, completer)) _activeFlush = null;
    });
  }

  @override
  void write(Object? object) {
    _checkWritable();
    writes.add(object);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _checkWritable();
    writes.add(objects.join(separator));
  }

  @override
  void writeCharCode(int charCode) {
    _checkWritable();
    writes.add(charCode);
  }

  @override
  void writeln([Object? object = '']) {
    _checkWritable();
    writes.add('$object\n');
  }
}
