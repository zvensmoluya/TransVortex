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
      expect(snapshot.configReadiness.asrLabel, '本机');
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
      expect(snapshot.configReadiness.asrLabel, '云端');
    },
  );

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
    expect(byName['local']?.displayLabel, '本机');
    expect(byName['funasr_sensevoice_local']?.displayLabel, 'FunASR');
    expect(byName['openai_whisper']?.displayLabel, '云端');
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
    expect(snapshot.configReadiness.asrLabel, '本机');
    expect(snapshot.asrLabel, '本机');
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
            {'code': 'cps_high', 'message': 'too fast'},
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
    expect(workspace.issueCount, 2);
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
      final selectedWorkspace = await Directory.systemTemp.createTemp(
        'transvortex_product_workspace_',
      );
      addTearDown(() => _deleteDirectoryWithRetries(desktopHome));
      addTearDown(() => _deleteDirectoryWithRetries(selectedWorkspace));
      final appPaths = _desktopPaths(desktopHome);
      final settings = DesktopWorkspaceSettings(
        paths: appPaths,
        environment: const {},
      );
      await settings.saveWorkspaceRoot(selectedWorkspace.path);
      final supervisor = LocalServiceSupervisor(
        repoRoot: Directory.current.parent,
        appPaths: appPaths,
        workspaceSettings: settings,
        pythonExecutable: Platform.isWindows ? 'python' : 'python3',
        requestTimeout: const Duration(seconds: 10),
      );
      final session = await supervisor.start();
      addTearDown(session.shutdown);

      final snapshot = await session.client.desktopSnapshot();
      final expectedConfig = appPaths.configRoot.resolveSymbolicLinksSync();
      final expectedTasks = appPaths
          .tasksRoot(selectedWorkspace)
          .resolveSymbolicLinksSync();

      expect(snapshot.config['root_dir'], expectedConfig);
      expect(snapshot.config['artifacts_dir'], expectedTasks);
      expect(Directory(expectedTasks).existsSync(), isTrue);
      expect('$expectedConfig'.contains('.transvortex-desktop'), isFalse);
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
      final workspaceSettings = DesktopWorkspaceSettings(
        paths: appPaths,
        environment: const {},
      );
      final selectedWorkspace = Directory(
        '${desktopHome.path}${Platform.pathSeparator}Selected Workspace',
      );
      await workspaceSettings.saveWorkspaceRoot(selectedWorkspace.path);
      final supervisor = LocalServiceSupervisor(
        repoRoot: repoRoot,
        appPaths: appPaths,
        workspaceSettings: workspaceSettings,
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
      final runtimeArtifacts = appPaths.tasksRoot(selectedWorkspace);
      expect(executable, 'python-test');
      expect(arguments, [
        '-m',
        'transvortex.app_service',
        '--root',
        runtimeRoot.path,
        '--artifacts-dir',
        runtimeArtifacts.path,
      ]);
      expect(capturedWorkingDirectory, repoRoot.path);
      expect(capturedEnvironment?['PYTHONIOENCODING'], 'utf-8');
      expect(runtimeRoot.existsSync(), isTrue);
      expect(
        File(
          '${runtimeRoot.path}${Platform.pathSeparator}pipeline.yaml',
        ).readAsStringSync(encoding: utf8),
        'artifacts_dir: artifacts\nsource_mode: asr\n',
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
        workspaceSettings: DesktopWorkspaceSettings(
          paths: appPaths,
          environment: const {},
        ),
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
      workspaceSettings: DesktopWorkspaceSettings(
        paths: appPaths,
        environment: const {},
      ),
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

    expect(transport.calls.map((call) => call.method), [
      'provider.save',
      'provider.models',
      'provider.test',
      'provider.delete',
      'provider.routing.save',
      'provider.routing.save',
      'asr.provider.save',
    ]);
    expect(transport.calls.first.params['api_key'], 'secret');
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
  return DesktopAppPaths(
    appDataRoot: appDataRoot,
    configRoot: Directory('${appDataRoot.path}${Platform.pathSeparator}Config'),
    defaultWorkspaceRoot: Directory(
      '${appDataRoot.path}${Platform.pathSeparator}Workspace',
    ),
    settingsFile: File(
      '${appDataRoot.path}${Platform.pathSeparator}desktop-settings.json',
    ),
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
