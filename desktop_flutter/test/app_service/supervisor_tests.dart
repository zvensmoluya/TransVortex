import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'app_service_test_support.dart';

void main() {
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
      await deleteDirectoryWithRetries(serviceRoot);
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
      addTearDown(() => deleteDirectoryWithRetries(desktopHome));
      final appPaths = desktopPathsFixture(desktopHome);
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
      addTearDown(() => deleteDirectoryWithRetries(repoRoot));
      addTearDown(() => deleteDirectoryWithRetries(desktopHome));
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
      final appPaths = desktopPathsFixture(desktopHome);
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
              return FakeProcess();
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
      addTearDown(() => deleteDirectoryWithRetries(repoRoot));
      addTearDown(() => deleteDirectoryWithRetries(desktopHome));
      File(
        '${repoRoot.path}${Platform.pathSeparator}pipeline.yaml',
      ).writeAsStringSync('artifacts_dir: repo-artifacts\n', encoding: utf8);
      File(
        '${repoRoot.path}${Platform.pathSeparator}providers.yaml',
      ).writeAsStringSync('providers: [fresh]\n', encoding: utf8);

      final appPaths = desktopPathsFixture(desktopHome);
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
              return FakeProcess();
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
      addTearDown(() => deleteDirectoryWithRetries(appRoot));
      addTearDown(() => deleteDirectoryWithRetries(desktopHome));
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
        appPaths: desktopPathsFixture(desktopHome),
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
              return FakeProcess();
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
      addTearDown(() => deleteDirectoryWithRetries(appRoot));
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
      addTearDown(() => deleteDirectoryWithRetries(appRoot));
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
    addTearDown(() => deleteDirectoryWithRetries(repoRoot));
    addTearDown(() => deleteDirectoryWithRetries(desktopHome));
    File(
      '${repoRoot.path}${Platform.pathSeparator}pipeline.yaml',
    ).writeAsStringSync('artifacts_dir: repo-artifacts\n', encoding: utf8);
    File(
      '${repoRoot.path}${Platform.pathSeparator}providers.yaml',
    ).writeAsStringSync('providers: [fresh]\n', encoding: utf8);

    final appPaths = desktopPathsFixture(desktopHome);
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
            return FakeProcess();
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
      final video = await writeEmbeddedSubtitleVideo(serviceRoot);
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
        await deleteDirectoryWithRetries(serviceRoot);
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
      final completed = await waitForTerminalTask(
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
    skip: hasEmbeddedSubtitleSmokeTools()
        ? false
        : 'ffmpeg and ffprobe are required for the real worker smoke',
  );

  test(
    'LocalServiceSupervisor drives a real worker cancel to CANCELLED',
    () async {
      final serviceRoot = await Directory.systemTemp.createTemp(
        'transvortex_worker_cancel_smoke_',
      );
      final slowAsr = await SlowAsrServer.start();
      addTearDown(() => slowAsr.close());
      File(
        '${serviceRoot.path}${Platform.pathSeparator}pipeline.yaml',
      ).writeAsStringSync('''
config_schema_version: 2
artifacts_dir: artifacts
source_mode: asr
asr: {engine: slow_asr}
asr_engines:
  - id: slow_asr
    type: funasr_service
    model: whisper-test
    endpoint:
      scope: loopback
      base_url: http://127.0.0.1:${slowAsr.port}
      path: /v1/audio/transcriptions
    policy_overrides:
      execution:
        request_deadline_seconds: 10
        max_attempts: 1
        split_retry: false
      chunking:
        mode: none
      preprocessing:
        trim_silence: false
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
      final video = await writeAudioVideo(serviceRoot);
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
        await deleteDirectoryWithRetries(serviceRoot);
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
      await waitForSlowAsrRequestOrFail(
        slowAsr,
        client: session.client,
        transport: session.transport,
        serviceRoot: serviceRoot,
        taskId: submitted.taskId,
      );
      final cancelRequested = await session.client.cancel(submitted.taskId);
      slowAsr.release();
      final terminal = await waitForTerminalTask(
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
    skip: hasEmbeddedSubtitleSmokeTools()
        ? false
        : 'ffmpeg and ffprobe are required for the real worker smoke',
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
