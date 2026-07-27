import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/model/main_window_controller.dart';
import 'package:transvortex_desktop_flutter/model/session.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/local_service_controller.dart';
import 'package:transvortex_desktop_flutter/services/path_opener.dart';

void main() {
  test('session readiness only requires ASR for media sources', () {
    const subtitle = Session(
      fileName: 'source.srt',
      filePath: r'D:\source.srt',
      kind: SourceKind.subtitle,
      asrConfigured: false,
    );
    const audio = Session(
      fileName: 'source.mp3',
      filePath: r'D:\source.mp3',
      kind: SourceKind.audio,
      asrConfigured: false,
    );

    expect(subtitle.state, MainState.ready);
    expect(audio.state, MainState.blocked);
  });

  test(
    'controller derives empty and ready states from source and snapshot',
    () async {
      final controller = MainWindowController(service: _readyController());
      await controller.startService();

      expect(controller.view.state, MainState.empty);

      controller.pickSource(r'D:\movie.mp4');

      expect(controller.view.state, MainState.ready);
      expect(controller.view.translationLabel, 'real-model');
      expect(controller.view.translationDetail, contains('默认模型'));
      expect(controller.view.translationDetail, contains('备用 fallback-model'));
      expect(controller.view.asrLabel, '本机 Whisper · Large v3');
      expect(controller.view.sourceLang, 'auto');
      expect(controller.view.targetLang, 'zh-CN');
    },
  );

  test('controller hides generated custom Whisper model ids', () async {
    final controller = MainWindowController(
      service: _readyController(
        snapshot: _desktopSnapshot(asrModel: 'custom-123456789abc'),
      ),
    );
    await controller.startService();

    expect(controller.view.asrLabel, '本机 Whisper · 自定义 Whisper');
  });

  test(
    'controller distinguishes external and app-managed Whisper models',
    () async {
      final managed = MainWindowController(
        service: _readyController(
          snapshot: _desktopSnapshot(
            asrKind: 'local_worker',
            asrModelSource: 'managed',
          ),
        ),
      );
      final external = MainWindowController(
        service: _readyController(
          snapshot: _desktopSnapshot(
            asrKind: 'local_worker',
            asrModelSource: 'external',
            asrLocal: const {
              'active_execution': {
                'provider': 'local',
                'kind': 'local_worker',
                'model': 'large-v3',
                'can_run': true,
                'model_resource': {
                  'source': 'external',
                  'user_label': '日语访谈模型',
                  'ready': true,
                },
              },
            },
          ),
        ),
      );
      addTearDown(managed.dispose);
      addTearDown(external.dispose);
      await managed.startService();
      await external.startService();

      expect(managed.view.asrLabel, '本机 Whisper · Large v3');
      expect(external.view.asrLabel, '本机 Whisper · 日语访谈模型（本地文件夹）');
    },
  );

  test(
    'controller keeps snapshots fresh while an ASR setup is active',
    () async {
      final active = _desktopSnapshot(
        asrLocal: const {
          'operations': [
            {
              'id': 'asr_setup_small',
              'kind': 'setup',
              'item_id': 'small',
              'state': 'running',
              'phase': 'model',
            },
          ],
        },
      );
      final terminal = _desktopSnapshot(asrLocal: const {'operations': []});
      final handle = _FakeHandle(active, snapshotSequence: [active, terminal]);
      final service = _readyController(handle: handle);
      final controller = MainWindowController(service: service);
      addTearDown(() {
        controller.dispose();
        service.dispose();
      });

      await controller.startService();
      expect(
        service.snapshot.desktopSnapshot?.asrOperations.single.active,
        isTrue,
      );

      await Future<void>.delayed(const Duration(milliseconds: 2200));

      expect(
        handle.transport.calls
            .where((call) => call == 'desktop.snapshot')
            .length,
        greaterThanOrEqualTo(2),
      );
      expect(service.snapshot.desktopSnapshot?.asrOperations, isEmpty);
    },
  );

  test(
    'controller blocks unsupported subtitle input before payload build',
    () async {
      final controller = MainWindowController(service: _readyController());
      await controller.startService();

      controller.pickSource(r'D:\subtitle.ass');

      expect(controller.view.state, MainState.failed);
      expect(controller.view.failure?.reason, contains('只支持 SRT'));
      expect(() => controller.buildRunRequest(), throwsStateError);
    },
  );

  test('controller skips ASR readiness for SRT translation', () async {
    final handle = _FakeHandle(_desktopSnapshot(asrHasKey: false));
    final controller = MainWindowController(
      service: _readyController(handle: handle),
    );
    await controller.startService();

    controller.pickSource(r'D:\subtitle.srt');

    expect(controller.view.source?.kind, SourceKind.subtitle);
    expect(controller.view.requiresAsr, isFalse);
    expect(controller.view.state, MainState.ready);
    final payload = controller.buildRunRequest();
    final overrides = payload['overrides'] as Map<String, Object?>;
    expect(payload['input_type'], 'srt_translate');
    expect(overrides.containsKey('asr_provider'), isFalse);
    expect(overrides.containsKey('asr_model'), isFalse);

    await controller.submitRun();

    expect(handle.transport.calls, contains('runtime.submitRun'));
  });

  test(
    'controller inspects video and skips ASR when an embedded subtitle is selected',
    () async {
      final handle = _FakeHandle(
        _desktopSnapshot(asrHasKey: false),
        mediaInspection: const {
          'kind': 'video',
          'source_mode': 'embedded_subtitle',
          'needs_asr': false,
          'available': true,
          'code': 'ready',
          'subtitle_streams': [
            {'index': 2, 'supported': true, 'language': 'ja'},
          ],
          'selected_subtitle_stream': {
            'index': 2,
            'supported': true,
            'language': 'ja',
          },
        },
      );
      final controller = MainWindowController(
        service: _readyController(handle: handle),
      );
      await controller.startService();
      controller.pickSource(r'D:\movie.mkv');

      expect(controller.view.sourceInspectionPending, isTrue);

      await controller.submitRun();

      expect(controller.view.sourceInspectionPending, isFalse);
      expect(
        handle.transport.calls.where((call) => call == 'media.inspect'),
        hasLength(1),
      );
      expect(controller.view.requiresAsr, isFalse);
      final request =
          handle.transport.lastParams['runtime.submitRun']!['request']
              as Map<String, Object?>;
      final overrides = request['overrides'] as Map<String, Object?>;
      expect(overrides['source_mode'], 'embedded_subtitle');
      expect(overrides['subtitle_track'], '2');
      expect(overrides.containsKey('asr_provider'), isFalse);
      expect(overrides.containsKey('asr_model'), isFalse);
    },
  );

  test('controller always requires ASR for audio input', () async {
    final handle = _FakeHandle(_desktopSnapshot(asrHasKey: false));
    final controller = MainWindowController(
      service: _readyController(handle: handle),
    );
    await controller.startService();
    controller.pickSource(r'D:\voice.wav');

    await controller.submitRun();

    expect(controller.view.requiresAsr, isTrue);
    expect(controller.view.state, MainState.blocked);
    expect(handle.transport.calls, isNot(contains('media.inspect')));
    expect(handle.transport.calls, isNot(contains('runtime.submitRun')));
  });

  test(
    'controller keeps launch empty and exposes resumable task reminder',
    () async {
      final controller = MainWindowController(
        service: _readyController(
          snapshot: _desktopSnapshot(
            tasks: [
              _task(
                taskId: 'tvx_resumable_history',
                status: 'FAILED',
                inputFile: r'D:\media\history-failed.mp4',
                errorInfo: const {'hint_zh': '可以继续上次任务。'},
                runtime: const {'can_resume': true},
              ),
            ],
          ),
        ),
      );

      await controller.startService();

      expect(controller.view.state, MainState.empty);
      expect(controller.view.taskId, isNull);
      expect(controller.view.source, isNull);
      expect(controller.view.homeTaskReminder?.taskId, 'tvx_resumable_history');
      expect(
        controller.view.homeTaskReminder?.sourceName,
        'history-failed.mp4',
      );
      expect(controller.view.homeTaskReminder?.reason, '可以继续上次任务。');
    },
  );

  test('controller dismisses home task reminder for this session', () async {
    final controller = MainWindowController(
      service: _readyController(
        snapshot: _desktopSnapshot(
          tasks: [
            _task(
              taskId: 'tvx_resumable_history',
              status: 'INTERRUPTED',
              inputFile: r'D:\media\history-interrupted.mp4',
              runtime: const {'can_resume': true},
            ),
          ],
        ),
      ),
    );

    await controller.startService();
    expect(controller.view.homeTaskReminder?.taskId, 'tvx_resumable_history');

    controller.dismissHomeTaskReminder('tvx_resumable_history');

    expect(controller.view.state, MainState.empty);
    expect(controller.view.homeTaskReminder, isNull);
  });

  test(
    'controller dismisses all current home reminders for this session',
    () async {
      final controller = MainWindowController(
        service: _readyController(
          snapshot: _desktopSnapshot(
            tasks: [
              _task(
                taskId: 'tvx_resumable_first',
                status: 'FAILED',
                inputFile: r'D:\media\first.mp4',
                runtime: const {'can_resume': true},
              ),
              _task(
                taskId: 'tvx_resumable_second',
                status: 'INTERRUPTED',
                inputFile: r'D:\media\second.mp4',
                runtime: const {'can_resume': true},
              ),
            ],
          ),
        ),
      );

      await controller.startService();
      expect(controller.view.homeTaskReminder?.resumableCount, 2);

      controller.dismissHomeTaskReminder('tvx_resumable_first');

      expect(controller.view.state, MainState.empty);
      expect(controller.view.homeTaskReminder, isNull);
    },
  );

  test(
    'controller does not restore running, stale, queued, or done history',
    () async {
      final runningController = MainWindowController(
        service: _readyController(
          snapshot: _desktopSnapshot(
            tasks: [
              _task(
                status: 'RUNNING',
                inputFile: r'D:\running.mp4',
                runtime: {'state': 'running'},
              ),
            ],
          ),
        ),
      );
      final staleController = MainWindowController(
        service: _readyController(
          snapshot: _desktopSnapshot(
            tasks: [
              _task(
                status: 'TRANSLATE',
                inputFile: r'D:\stale.mp4',
                runtime: {'state': 'stale'},
              ),
            ],
          ),
        ),
      );
      final queuedController = MainWindowController(
        service: _readyController(
          snapshot: _desktopSnapshot(
            tasks: [
              _task(
                status: 'QUEUED',
                inputFile: r'D:\queued.mp4',
                runtime: {'state': 'queued'},
              ),
            ],
          ),
        ),
      );
      final doneController = MainWindowController(
        service: _readyController(
          snapshot: _desktopSnapshot(
            tasks: [_task(status: 'DONE', inputFile: r'D:\done.mp4')],
          ),
        ),
      );

      await runningController.startService();
      await staleController.startService();
      await queuedController.startService();
      await doneController.startService();

      expect(runningController.view.state, MainState.empty);
      expect(runningController.view.taskId, isNull);
      expect(runningController.view.homeTaskReminder, isNull);
      expect(staleController.view.state, MainState.empty);
      expect(staleController.view.taskId, isNull);
      expect(queuedController.view.state, MainState.empty);
      expect(queuedController.view.taskId, isNull);
      expect(doneController.view.state, MainState.empty);
      expect(doneController.view.taskId, isNull);
      expect(doneController.view.homeTaskReminder, isNull);
    },
  );

  test('controller opens and reexports completed task results', () async {
    final pathOpener = _RecordingPathOpener();
    final temp = await Directory.systemTemp.createTemp('tvx_result_open_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final srt = File('${temp.path}${Platform.pathSeparator}out.srt');
    final ass = File('${temp.path}${Platform.pathSeparator}out.ass');
    await srt.writeAsString('subtitle', encoding: utf8);
    await ass.writeAsString('subtitle', encoding: utf8);
    final handle = _FakeHandle(
      _desktopSnapshot(
        tasks: [
          _task(
            status: 'DONE',
            inputFile: '${temp.path}${Platform.pathSeparator}movie.mp4',
            outputPaths: {'ass': ass.path, 'srt': srt.path},
          ),
        ],
      ),
    );
    final controller = MainWindowController(
      service: _readyController(handle: handle),
      pathOpener: pathOpener,
    );

    await controller.startService();
    controller.applySmokeTask(
      TaskSummary.fromJson(
        _task(
          status: 'DONE',
          inputFile: '${temp.path}${Platform.pathSeparator}movie.mp4',
          outputPaths: {'ass': ass.path, 'srt': srt.path},
        ),
      ),
    );
    expect(controller.view.state, MainState.completed);

    await controller.openResultFile();
    await controller.openResultFolder();
    await controller.reexportResult();

    expect(pathOpener.revealed, [srt.path]);
    expect(pathOpener.openedDirectories, [temp.path]);
    expect(handle.transport.calls, contains('result.reexport'));
    expect(handle.transport.lastParams['result.reexport'], {
      'task_id': 'tvx_controller_DONE',
      'output_format': 'both',
      'bilingual': true,
    });
  });

  test(
    'controller turns missing result files into re-export recovery',
    () async {
      final pathOpener = _RecordingPathOpener();
      final temp = await Directory.systemTemp.createTemp('tvx_missing_result_');
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final missing = File('${temp.path}${Platform.pathSeparator}gone.srt');
      final handle = _FakeHandle(
        _desktopSnapshot(
          tasks: [
            _task(
              status: 'DONE',
              inputFile: '${temp.path}${Platform.pathSeparator}movie.mp4',
              outputPaths: {'srt': missing.path},
            ),
          ],
        ),
        resultOpen: {
          'output_paths': {'srt': missing.path},
        },
      );
      final controller = MainWindowController(
        service: _readyController(handle: handle),
        pathOpener: pathOpener,
      );

      await controller.startService();
      controller.applySmokeTask(
        TaskSummary.fromJson(
          _task(
            status: 'DONE',
            inputFile: '${temp.path}${Platform.pathSeparator}movie.mp4',
            outputPaths: {'srt': missing.path},
          ),
        ),
      );
      expect(controller.view.state, MainState.completed);

      await expectLater(controller.openResultFile(), throwsStateError);

      expect(pathOpener.revealed, isEmpty);
      expect(controller.view.state, MainState.failed);
      expect(controller.view.failure?.reason, contains('结果文件不在原位置'));
      expect(controller.view.failure?.actionLabel, '重新导出');
      expect(controller.view.failure?.target, MainRecoveryTarget.reexport);
      expect(handle.transport.calls, contains('result.open'));
    },
  );

  test(
    'controller maps failed re-export to output directory recovery',
    () async {
      final temp = await Directory.systemTemp.createTemp('tvx_reexport_fail_');
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final srt = File('${temp.path}${Platform.pathSeparator}out.srt');
      await srt.writeAsString('subtitle', encoding: utf8);
      final handle = _FakeHandle(
        _desktopSnapshot(
          tasks: [
            _task(
              status: 'DONE',
              inputFile: '${temp.path}${Platform.pathSeparator}movie.mp4',
              outputPaths: {'srt': srt.path},
            ),
          ],
        ),
        resultReexportError: RpcRemoteException(
          'output_not_writable',
          'output path is not writable',
          details: const {
            'error_info': {
              'code': 'output_not_writable',
              'hint_zh': '输出目录不可写。',
            },
          },
        ),
      );
      final controller = MainWindowController(
        service: _readyController(handle: handle),
      );

      await controller.startService();
      controller.applySmokeTask(
        TaskSummary.fromJson(
          _task(
            status: 'DONE',
            inputFile: '${temp.path}${Platform.pathSeparator}movie.mp4',
            outputPaths: {'srt': srt.path},
          ),
        ),
      );
      await expectLater(
        controller.reexportResult(),
        throwsA(isA<RpcRemoteException>()),
      );

      expect(controller.view.state, MainState.failed);
      expect(controller.view.failure?.reason, '输出目录不可写。');
      expect(controller.view.failure?.actionLabel, '选择输出目录');
      expect(
        controller.view.failure?.target,
        MainRecoveryTarget.reexportDirectory,
      );
    },
  );

  test('controller retries a generic re-export failure as re-export', () async {
    final handle = _FakeHandle(
      _desktopSnapshot(),
      resultReexportError: RpcRemoteException(
        'invalid_request',
        'temporary invalid result request',
        details: const {
          'error_info': {'code': 'invalid_request', 'hint_zh': '结果请求暂时无法处理。'},
        },
      ),
    );
    final controller = MainWindowController(
      service: _readyController(handle: handle),
    );
    await controller.startService();
    controller.applySmokeTask(
      TaskSummary.fromJson(
        _task(
          status: 'DONE',
          inputFile: r'D:\movie.mp4',
          outputPaths: const {'srt': r'D:\movie.srt'},
        ),
      ),
    );

    await expectLater(
      controller.reexportResult(),
      throwsA(isA<RpcRemoteException>()),
    );

    expect(controller.view.failure?.actionLabel, '重新导出');
    expect(controller.view.failure?.target, MainRecoveryTarget.reexport);
  });

  test(
    'controller reexports failed task to selected output directory',
    () async {
      final temp = await Directory.systemTemp.createTemp('tvx_reexport_dir_');
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final outDir = '${temp.path}${Platform.pathSeparator}fixed';
      final handle = _FakeHandle(
        _desktopSnapshot(
          tasks: [
            _task(
              status: 'FAILED',
              inputFile: '${temp.path}${Platform.pathSeparator}movie.mp4',
              errorInfo: {'code': 'output_not_writable', 'hint_zh': '输出目录不可写。'},
            ),
          ],
        ),
        snapshotAfterReexport: _desktopSnapshot(
          tasks: [
            _task(
              taskId: 'tvx_controller_FAILED',
              status: 'DONE',
              inputFile: '${temp.path}${Platform.pathSeparator}movie.mp4',
              outputPaths: {'srt': r'D:\out.srt'},
            ),
          ],
        ),
      );
      final controller = MainWindowController(
        service: _readyController(handle: handle),
      );

      await controller.startService();
      controller.applySmokeTask(
        TaskSummary.fromJson(
          _task(
            status: 'FAILED',
            inputFile: '${temp.path}${Platform.pathSeparator}movie.mp4',
            errorInfo: {'code': 'output_not_writable', 'hint_zh': '输出目录不可写。'},
          ),
        ),
      );
      expect(controller.view.state, MainState.failed);

      await controller.reexportResultToDirectory(outDir);

      expect(handle.transport.lastParams['result.reexport'], {
        'task_id': 'tvx_controller_FAILED',
        'output_format': 'both',
        'output_dir': outDir,
        'bilingual': true,
      });
      expect(controller.view.outputPaths, {'srt': r'D:\out.srt'});
      expect(controller.view.failure, isNull);
    },
  );

  test('controller builds run payload from real snapshot and draft', () async {
    final controller = MainWindowController(service: _readyController());
    await controller.startService();
    controller.pickSource(r'D:\movie.mp4');

    final payload = controller.buildRunRequest();
    final overrides = payload['overrides'] as Map<String, Object?>;

    expect(payload['input_type'], 'video_asr_translate');
    expect(payload['source_lang'], 'auto');
    expect(payload['target_lang'], 'zh-CN');
    expect(payload['output_dir'], 'D:\\');
    final routing = payload['routing'] as Map<String, Object?>;
    final primary = routing['primary'] as Map<String, Object?>;
    final fallback = routing['fallback'] as List<Object?>;
    expect(primary['provider'], 'RealProvider');
    expect(primary['model'], 'real-model');
    expect((fallback.first as Map<String, Object?>)['model'], 'fallback-model');
    expect(payload.containsKey('provider'), isFalse);
    expect(payload.containsKey('model'), isFalse);
    expect(overrides['output_format'], 'both');
    expect(overrides['subtitle_quality_mode'], 'balanced');
    expect(overrides['memory_enabled'], isTrue);
    expect(overrides['memory_bootstrap_enabled'], isTrue);
    expect(overrides['memory_patch_enabled'], isTrue);
    expect(overrides['memory_patch_window_chunks'], 3);
    expect(overrides['asr_provider'], 'local');
    expect(overrides['asr_model'], 'large-v3');
  });

  test('controller snapshots a task-level reasoning override', () async {
    final controller = MainWindowController(service: _readyController());
    await controller.startService();
    controller.pickSource(r'D:\movie.mp4');

    expect(controller.view.reasoningConfigurable, isTrue);
    expect(controller.view.reasoningLabel, '低');
    expect(controller.view.reasoningDetail, '低（模型默认）');
    final disabled = controller.view.reasoningOptions.firstWhere(
      (option) => option.value == 'none',
    );

    controller.selectReasoningEffort(disabled);

    final payload = controller.buildRunRequest();
    final routing = payload['routing'] as Map<String, Object?>;
    final primary = routing['primary'] as Map<String, Object?>;
    expect(controller.view.reasoningLabel, '关闭');
    expect(primary['reasoning_effort'], 'none');
  });

  test(
    'controller keeps reasoning strength across compatible models',
    () async {
      final controller = MainWindowController(
        service: _readyController(
          snapshot: _desktopSnapshot(extraModels: const ['pro-model']),
        ),
      );
      await controller.startService();
      controller.pickSource(r'D:\movie.mp4');
      controller.selectReasoningEffortValue('medium');

      final compatible = controller.view.translationDirectOptions.firstWhere(
        (item) => item.model == 'pro-model',
      );
      controller.selectTranslation(compatible);

      var routing =
          controller.buildRunRequest()['routing'] as Map<String, Object?>;
      var primary = routing['primary'] as Map<String, Object?>;
      expect(controller.view.reasoningLabel, '中');
      expect(primary['reasoning_effort'], 'medium');

      controller.selectTranslation(
        const TranslationRuntimeChoice(
          label: 'plain-model',
          configured: true,
          routing: {
            'primary': {'provider': 'PlainProvider', 'model': 'plain-model'},
            'fallback': <Object?>[],
          },
          source: TranslationChoiceSource.direct,
          provider: 'PlainProvider',
          model: 'plain-model',
        ),
      );

      routing = controller.buildRunRequest()['routing'] as Map<String, Object?>;
      primary = routing['primary'] as Map<String, Object?>;
      expect(controller.view.reasoningConfigurable, isFalse);
      expect(primary['reasoning_effort'], 'auto');
    },
  );

  test('controller sends selected language pair in run payload', () async {
    final controller = MainWindowController(service: _readyController());
    await controller.startService();
    controller.pickSource(r'D:\movie.mp4');
    controller.setSourceLang('ja');
    controller.setTargetLang('en');

    final payload = controller.buildRunRequest();

    expect(controller.view.sourceLang, 'ja');
    expect(controller.view.targetLang, 'en');
    expect(payload['source_lang'], 'ja');
    expect(payload['target_lang'], 'en');
  });

  test('controller sends LRC output format in run payload', () async {
    final controller = MainWindowController(service: _readyController());
    await controller.startService();
    controller.pickSource(r'D:\song.mp3');
    controller.setFormats(const ['LRC']);

    final payload = controller.buildRunRequest();
    final overrides = payload['overrides'] as Map<String, Object?>;

    expect(controller.view.formats, ['LRC']);
    expect(overrides['output_format'], 'lrc');
  });

  test('controller exposes routing profiles as model-first choices', () async {
    final controller = MainWindowController(
      service: _readyController(
        snapshot: _desktopSnapshot(
          routingProfiles: [
            {
              'id': 'route_1',
              'name': '日常省钱',
              'primary': {'provider': 'RealProvider', 'model': 'real-model'},
              'fallback': [
                {'provider': 'RealProvider', 'model': 'fallback-model'},
              ],
            },
            {
              'id': 'route_2',
              'name': '精修质量',
              'primary': {'provider': 'RealProvider', 'model': 'pro-model'},
              'fallback': const [],
            },
          ],
        ),
      ),
    );
    await controller.startService();

    expect(controller.view.translationOptions.map((item) => item.label), [
      'real-model',
      'pro-model',
    ]);
    expect(controller.view.translationOptions.first.detail, contains('日常省钱'));
    expect(
      controller.view.translationOptions.first.detail,
      contains('备用 fallback-model'),
    );
  });

  test(
    'controller direct model choice sends routing without fallback',
    () async {
      final controller = MainWindowController(
        service: _readyController(
          snapshot: _desktopSnapshot(extraModels: const ['pro-model']),
        ),
      );
      await controller.startService();
      controller.pickSource(r'D:\movie.mp4');

      final direct = controller.view.translationDirectOptions.firstWhere(
        (item) => item.model == 'pro-model',
      );
      controller.selectTranslation(direct);
      final payload = controller.buildRunRequest();
      final routing = payload['routing'] as Map<String, Object?>;
      final primary = routing['primary'] as Map<String, Object?>;
      final fallback = routing['fallback'] as List<Object?>;

      expect(primary['provider'], 'RealProvider');
      expect(primary['model'], 'pro-model');
      expect(fallback, isEmpty);
      expect(payload.containsKey('provider'), isFalse);
      expect(payload.containsKey('model'), isFalse);
    },
  );

  test('controller disables memory generation through run payload', () async {
    final controller = MainWindowController(service: _readyController());
    await controller.startService();
    controller.pickSource(r'D:\movie.mp4');
    controller.setTermsEnabled(false);

    final payload = controller.buildRunRequest();
    final overrides = payload['overrides'] as Map<String, Object?>;

    expect(controller.view.termsEnabled, isFalse);
    expect(overrides.containsKey('memory_enabled'), isFalse);
    expect(overrides['memory_bootstrap_enabled'], isFalse);
    expect(overrides['memory_patch_enabled'], isFalse);
    expect(overrides.containsKey('memory_patch_window_chunks'), isFalse);
  });

  test(
    'controller lets recovery override output directory for the next run',
    () async {
      final handle = _FakeHandle(_desktopSnapshot());
      final controller = MainWindowController(
        service: _readyController(handle: handle),
      );
      await controller.startService();

      controller.pickSource(r'D:\movie.mp4');
      controller.applyFailureForTesting(
        RpcRemoteException(
          'output_not_writable',
          'output path is not writable',
          details: {
            'error_info': {
              'code': 'output_not_writable',
              'hint_zh': '输出目录不可写。',
            },
          },
        ),
      );

      expect(controller.view.failure?.actionLabel, '选择输出目录');
      expect(
        controller.view.failure?.target,
        MainRecoveryTarget.outputDirectory,
      );

      controller.setOutputDirectory(r'E:\字幕输出');
      await controller.submitRun();

      final request =
          handle.transport.lastParams['runtime.submitRun']!['request']
              as Map<String, Object?>;
      expect(request['output_dir'], r'E:\字幕输出');
    },
  );

  test(
    'controller blocks run submission when translation key is missing',
    () async {
      final handle = _FakeHandle(_desktopSnapshot(translationHasKey: false));
      final controller = MainWindowController(
        service: _readyController(handle: handle),
      );
      await controller.startService();

      controller.pickSource(r'D:\movie.mp4');
      await Future<void>.delayed(Duration.zero);

      expect(controller.view.state, MainState.blocked);
      expect(controller.view.requiresAsr, isTrue);
      expect(controller.view.statusLine, contains('需要先配置翻译'));
      expect(controller.view.translationLabel, '需配置');
      expect(controller.view.translationConfigured, isFalse);

      await controller.submitRun();

      expect(controller.view.state, MainState.blocked);
      expect(handle.transport.calls, isNot(contains('runtime.submitRun')));
    },
  );

  test(
    'controller blocks run submission when ASR default is missing',
    () async {
      final handle = _FakeHandle(_desktopSnapshot(asrHasKey: false));
      final controller = MainWindowController(
        service: _readyController(handle: handle),
      );
      await controller.startService();

      controller.pickSource(r'D:\movie.mp4');
      await Future<void>.delayed(Duration.zero);

      expect(controller.view.state, MainState.blocked);
      expect(controller.view.statusLine, contains('需要先配置识别'));
      expect(controller.view.asrLabel, '需配置');
      expect(controller.view.asrConfigured, isFalse);

      await controller.submitRun();

      expect(controller.view.state, MainState.blocked);
      expect(handle.transport.calls, isNot(contains('runtime.submitRun')));
    },
  );

  test('controller maps provider errors to translation recovery action', () {
    final controller = MainWindowController(service: _readyController());

    controller.pickSource(r'D:\movie.mp4');
    controller.applyFailureForTesting(
      RpcRemoteException(
        'routing_provider_missing',
        'provider not found',
        details: {
          'error_info': {
            'code': 'routing_provider_missing',
            'hint_zh': '翻译服务还没配置好。',
          },
        },
      ),
    );

    expect(controller.view.state, MainState.failed);
    expect(controller.view.failure?.reason, '翻译服务还没配置好。');
    expect(
      controller.view.failure?.target,
      MainRecoveryTarget.translationSettings,
    );
  });

  test('controller retries transient provider submission errors', () {
    final controller = MainWindowController(service: _readyController());

    controller.pickSource(r'D:\movie.mp4');
    controller.applyFailureForTesting(
      RpcRemoteException(
        'provider_gateway_timeout',
        'gateway timeout',
        details: const {
          'error_info': {
            'code': 'provider_gateway_timeout',
            'hint_zh': '翻译服务暂时超时，可以重试。',
            'retryable': true,
          },
        },
      ),
    );

    expect(controller.view.failure?.reason, '翻译服务暂时超时，可以重试。');
    expect(controller.view.failure?.actionLabel, '重试');
    expect(controller.view.failure?.target, MainRecoveryTarget.retry);
  });

  test('controller resumes checkpoint after a transient provider failure', () {
    final controller = MainWindowController(service: _readyController());

    controller.applySmokeTask(
      TaskSummary.fromJson(
        _task(
          status: 'FAILED',
          inputFile: r'D:\movie.mp4',
          errorInfo: const {
            'code': 'provider_retryable_http_error',
            'hint_zh': '翻译服务暂时不可用，可以继续任务。',
            'retryable': true,
          },
          runtime: const {'can_resume': true},
        ),
      ),
    );

    expect(controller.view.failure?.actionLabel, '继续任务');
    expect(controller.view.failure?.target, MainRecoveryTarget.resume);
  });

  test('controller replaces an unreadable media source', () {
    final controller = MainWindowController(service: _readyController());

    controller.pickSource(r'D:\broken.mp4');
    controller.applyFailureForTesting(
      RpcRemoteException(
        'media_processing_failed',
        'ffmpeg failed',
        details: const {
          'error_info': {
            'code': 'media_processing_failed',
            'hint_zh': '音频处理失败，请换一个文件。',
          },
        },
      ),
    );

    expect(controller.view.failure?.actionLabel, '重新选择片源');
    expect(controller.view.failure?.target, MainRecoveryTarget.pickSource);
  });

  test('controller does not treat missing credentials as missing results', () {
    final controller = MainWindowController(service: _readyController());

    controller.pickSource(r'D:\movie.mp4');
    controller.applyFailureForTesting(
      RpcRemoteException(
        'missing_env',
        'missing credential',
        details: const {
          'error_info': {'code': 'missing_env', 'hint_zh': '缺少 API key。'},
        },
      ),
    );

    expect(controller.view.failure?.reason, contains('翻译模型凭据'));
    expect(controller.view.failure?.actionLabel, '检查翻译设置');
    expect(
      controller.view.failure?.target,
      MainRecoveryTarget.translationSettings,
    );
  });

  test('controller routes ASR credentials without exposing env internals', () {
    final controller = MainWindowController(service: _readyController());

    controller.pickSource(r'D:\voice.wav');
    controller.applyFailureForTesting(
      RpcRemoteException(
        'missing_env',
        'missing environment variable OPENAI_API_KEY',
        details: const {
          'error_info': {
            'code': 'missing_env',
            'stage': 'ASR',
            'hint_zh': '缺少必要环境变量，请在 .env 或 env_key 中配置。',
          },
        },
      ),
    );

    expect(controller.view.failure?.actionLabel, '检查识别设置');
    expect(controller.view.failure?.target, MainRecoveryTarget.asrSettings);
    expect(controller.view.failure?.reason, contains('语音识别凭据'));
    expect(controller.view.failure?.reason, isNot(contains('.env')));
    expect(controller.view.failure?.reason, isNot(contains('env_key')));
  });

  test('controller maps missing input to picking a new source', () {
    final controller = MainWindowController(service: _readyController());

    controller.pickSource(r'D:\movie.mp4');
    controller.applyFailureForTesting(
      RpcRemoteException(
        'input_not_found',
        'input file not found',
        details: const {
          'error_info': {'code': 'input_not_found', 'hint_zh': '找不到片源文件。'},
        },
      ),
    );

    expect(controller.view.failure?.reason, contains('原片源'));
    expect(controller.view.failure?.actionLabel, '重新选择片源');
    expect(controller.view.failure?.target, MainRecoveryTarget.pickSource);
  });

  test(
    'controller hides internal log hints from failed task summaries',
    () async {
      final controller = MainWindowController(
        service: _readyController(
          snapshot: _desktopSnapshot(
            tasks: [
              _task(
                status: 'FAILED',
                inputFile: r'D:\media\broken.mp3',
                errorInfo: const {
                  'code': 'runtime_error',
                  'hint_zh': '任务运行失败，请查看 events.jsonl 和 stderr 日志。',
                },
              ),
            ],
          ),
        ),
      );

      await controller.startService();
      controller.applySmokeTask(
        TaskSummary.fromJson(
          _task(
            status: 'FAILED',
            inputFile: r'D:\media\broken.mp3',
            errorInfo: const {
              'code': 'runtime_error',
              'hint_zh': '任务运行失败，请查看 events.jsonl 和 stderr 日志。',
            },
          ),
        ),
      );

      expect(
        controller.view.failure?.reason,
        '任务运行失败，可以先重试；如果仍失败，请在任务处理中查看失败线索。',
      );
      expect(controller.view.failure?.reason, isNot(contains('events.json')));
      expect(controller.view.failure?.reason, isNot(contains('stderr')));
    },
  );

  test('controller localizes internal task event messages', () async {
    final controller = MainWindowController(
      service: _readyController(
        taskEvents: {
          'task_id': 'tvx_1',
          'events': [
            {'message': 'Task created'},
            {'stage': 'translate', 'progress': 0.35},
          ],
          'cursor': 0,
          'next_cursor': 2,
          'has_more': false,
        },
      ),
    );
    await controller.startService();
    controller.pickSource(r'D:\movie.mp4');

    await controller.submitRun();

    expect(controller.view.runningText, '翻译字幕');
    expect(controller.view.progress, 0.35);
    expect(controller.view.runProgress?.stage, MainRunStage.translate);
  });

  test('controller derives stable ASR window progress from checkpoint', () {
    final controller = MainWindowController(service: _readyController());

    controller.applySmokeTask(
      TaskSummary.fromJson(
        _task(
          status: 'RUNNING',
          inputFile: r'D:\movie.mp4',
          progress: 0.375,
          checkpointStatus: 'ASR',
          progressDetail: const {'asr_done_count': 5, 'asr_total_segments': 10},
          runtime: const {'state': 'running'},
        ),
      ),
    );

    expect(controller.view.runProgress?.title, '识别台词');
    expect(controller.view.runProgress?.detail, '语音分窗 5 / 10');
    expect(controller.view.runProgress?.counter, '5/10');
    expect(controller.view.runProgress?.phaseProgress, 0.5);
    expect(controller.view.progress, 0.375);
  });

  test('controller exposes batch recovery as translation activity', () {
    final controller = MainWindowController(service: _readyController());

    controller.applySmokeTask(
      TaskSummary.fromJson(
        _task(
          status: 'RUNNING',
          inputFile: r'D:\movie.mp4',
          progress: 0.71,
          checkpointStatus: 'TRANSLATE',
          progressDetail: const {
            'translate_done_count': 1,
            'translate_total_chunks': 3,
            'translate_current_mode': 'batch_recovery',
            'translate_recovery_segment_count': 79,
            'model_request_count': 5,
          },
          runtime: const {'state': 'running'},
        ),
      ),
    );

    expect(controller.view.runProgress?.title, '翻译字幕');
    expect(controller.view.runProgress?.detail, '批量补回被截断的 79 行字幕');
    expect(controller.view.runProgress?.counter, '1/3 · 模型 5 次');
  });

  test('controller surfaces residual quality issues after completion', () {
    final controller = MainWindowController(service: _readyController());

    controller.applySmokeTask(
      TaskSummary.fromJson(
        _task(
          status: 'DONE',
          inputFile: r'D:\movie.mp4',
          checkpointStatus: 'DONE',
          progressDetail: const {
            'quality_status': 'FAIL',
            'quality_residual_counts': {'hard_cps': 3, 'line_width': 5},
            'delivery_status': 'WARN',
          },
          outputPaths: const {'srt': r'D:\movie.srt'},
        ),
      ),
    );

    expect(controller.view.completionNotice, '已生成字幕，仍有 8 处需要审看');
  });

  test('controller distinguishes delivery warnings after completion', () {
    final controller = MainWindowController(service: _readyController());

    controller.applySmokeTask(
      TaskSummary.fromJson(
        _task(
          status: 'DONE',
          inputFile: r'D:\movie.mp4',
          checkpointStatus: 'DONE',
          progressDetail: const {
            'quality_status': 'PASS',
            'delivery_status': 'WARN',
            'delivery_issue_counts': {
              'ass': {'line_width': 2},
            },
          },
          outputPaths: const {'ass': r'D:\movie.ass'},
        ),
      ),
    );

    expect(controller.view.completionNotice, '已生成字幕，交付格式检查仍有提醒');
  });

  test('controller sends cancel request for running task', () async {
    final handle = _FakeHandle(
      _desktopSnapshot(
        tasks: [
          _task(
            status: 'RUNNING',
            inputFile: r'D:\movie.mp4',
            progress: 0.2,
            checkpointStatus: 'TRANSLATE',
            progressDetail: const {
              'translate_done_count': 1,
              'translate_total_chunks': 3,
            },
            runtime: {'state': 'running'},
          ),
        ],
      ),
      taskEvents: {
        'task_id': 'tvx_controller_RUNNING',
        'events': [
          {
            'stage': 'TRANSLATE',
            'details': {
              'mode': 'batch_recovery',
              'segment_ids': [321, 322],
            },
          },
        ],
        'cursor': 0,
        'next_cursor': 1,
        'has_more': false,
      },
    );
    final controller = MainWindowController(
      service: _readyController(handle: handle),
    );

    await controller.startService();
    controller.applySmokeTask(
      TaskSummary.fromJson(
        _task(
          status: 'RUNNING',
          inputFile: r'D:\movie.mp4',
          progress: 0.2,
          checkpointStatus: 'TRANSLATE',
          progressDetail: const {
            'translate_done_count': 1,
            'translate_total_chunks': 3,
          },
          runtime: {'state': 'running'},
        ),
      ),
    );
    await controller.pollTaskEvents();
    expect(controller.view.runProgress?.activity, '正在批量补回 2 行');

    await controller.cancelRun();

    expect(handle.transport.calls, contains('runtime.cancel'));
    expect(handle.transport.lastParams['runtime.cancel'], {
      'task_id': 'tvx_controller_RUNNING',
      'force': false,
    });
    expect(controller.view.state, MainState.running);
    expect(controller.view.canceling, isTrue);
    expect(controller.view.runProgress?.stage, MainRunStage.cancelling);
    expect(controller.view.runProgress?.detail, '等待当前步骤安全停下');
    expect(controller.view.runProgress?.activity, isEmpty);
  });

  test('controller retries a failed cancel with cancel again', () async {
    final handle = _FakeHandle(
      _desktopSnapshot(),
      runtimeCancelError: RpcRemoteException(
        'task_not_found',
        'task not found while cancelling',
        details: const {
          'error_info': {
            'code': 'task_not_found',
            'hint_zh': '取消时暂时找不到任务。',
            'retryable': false,
          },
        },
      ),
    );
    final controller = MainWindowController(
      service: _readyController(handle: handle),
    );
    await controller.startService();
    controller.applySmokeTask(
      TaskSummary.fromJson(
        _task(
          status: 'RUNNING',
          inputFile: r'D:\movie.mp4',
          runtime: {'state': 'running', 'can_cancel': true},
        ),
      ),
    );

    await controller.cancelRun();

    expect(controller.view.failure?.actionLabel, '重试取消');
    expect(controller.view.failure?.target, MainRecoveryTarget.cancel);
  });

  test(
    'controller resumes home task reminder through runtime.submitResume',
    () async {
      final handle = _FakeHandle(
        _desktopSnapshot(
          tasks: [
            _task(
              status: 'FAILED',
              inputFile: r'D:\movie.mp4',
              runtime: {'can_resume': true},
              settings: {
                'routing': {
                  'primary': {
                    'provider': 'RealProvider',
                    'model': 'resume-model',
                  },
                  'fallback': [
                    {'provider': 'RealProvider', 'model': 'fallback-model'},
                  ],
                },
              },
            ),
          ],
        ),
      );
      final controller = MainWindowController(
        service: _readyController(handle: handle),
      );

      await controller.startService();

      expect(controller.view.state, MainState.empty);
      expect(controller.view.taskId, isNull);
      expect(controller.view.homeTaskReminder?.taskId, 'tvx_controller_FAILED');

      await controller.resumeHomeTaskReminder();

      expect(handle.transport.calls, contains('runtime.submitResume'));
      final request =
          handle.transport.lastParams['runtime.submitResume']!['request']
              as Map<String, Object?>;
      expect(request, {
        'request_version': 1,
        'task_id': 'tvx_controller_FAILED',
      });
    },
  );

  test(
    'controller keeps the original task snapshot when resuming from home',
    () async {
      final handle = _FakeHandle(
        _desktopSnapshot(
          tasks: [
            _task(
              status: 'FAILED',
              inputFile: r'D:\movie.mp4',
              runtime: {'can_resume': true},
            ),
          ],
        ),
      );
      final controller = MainWindowController(
        service: _readyController(handle: handle),
      );

      await controller.startService();
      controller.setTermsEnabled(false);

      await controller.resumeHomeTaskReminder();

      final request =
          handle.transport.lastParams['runtime.submitResume']!['request']
              as Map<String, Object?>;
      expect(request, {
        'request_version': 1,
        'task_id': 'tvx_controller_FAILED',
      });
    },
  );
}

LocalServiceController _readyController({
  _FakeHandle? handle,
  DesktopSnapshot? snapshot,
  Map<String, Object?>? taskEvents,
}) {
  return LocalServiceController(
    sessionFactory: () async =>
        handle ??
        _FakeHandle(snapshot ?? _desktopSnapshot(), taskEvents: taskEvents),
  );
}

DesktopSnapshot _desktopSnapshot({
  bool translationHasKey = true,
  bool asrHasKey = true,
  String asrModel = 'large-v3',
  String asrKind = 'local_inprocess',
  String asrModelSource = 'managed',
  List<String> extraModels = const [],
  List<Map<String, Object?>> routingProfiles = const [],
  List<Map<String, Object?>> tasks = const [],
  Map<String, Object?> asrLocal = const {},
}) {
  final models = ['real-model', 'fallback-model', ...extraModels];
  final activeProfile = routingProfiles.isEmpty ? null : routingProfiles.first;
  return DesktopSnapshot.fromJson({
    'config': {
      'routing': {
        'active_profile': activeProfile?['id'] ?? 'default',
        'primary':
            activeProfile?['primary'] ??
            {'provider': 'RealProvider', 'model': 'real-model'},
        'fallback':
            activeProfile?['fallback'] ??
            [
              {'provider': 'RealProvider', 'model': 'fallback-model'},
            ],
      },
      if (routingProfiles.isNotEmpty) 'routing_profiles': routingProfiles,
      if (routingProfiles.isNotEmpty)
        'active_routing_profile': activeProfile?['id'],
      'pipeline': {'asr_provider': 'local'},
      'providers': [
        {
          'name': 'RealProvider',
          'has_key': translationHasKey,
          'base_url': 'https://example.com/v1',
          'api_type': 'openai-compatible',
          'compat_mode': 'openai_chat',
          'credential_id': 'RealProvider',
          'models': models,
          'capabilities': {
            'reasoning_effort_param': 'reasoning_effort',
            'reasoning_efforts': ['none', 'low', 'medium', 'high'],
          },
        },
      ],
      'model_catalog': [
        {
          'id': 'real-model',
          'label': 'Real Model',
          'vendor': 'test',
          'reasoning_efforts': ['none', 'low', 'medium', 'high'],
          'runtime': {'reasoning_effort': 'low'},
        },
      ],
      'asr_providers': {
        'local': {
          'name': 'local',
          'kind': asrKind,
          'protocol': 'faster_whisper',
          'model': asrModel,
          'has_key': asrHasKey,
          if (asrKind == 'local_worker')
            'local': {'model_source': asrModelSource},
        },
      },
      if (asrLocal.isNotEmpty) 'asr_local': asrLocal,
    },
    'tasks': tasks,
    'runtime': {},
    'environment': {},
  });
}

Map<String, Object?> _task({
  String? taskId,
  required String status,
  required String inputFile,
  double? progress,
  String? checkpointStatus,
  Map<String, Object?> progressDetail = const {},
  Map<String, String> outputPaths = const {},
  Map<String, Object?> errorInfo = const {},
  Map<String, Object?> runtime = const {},
  Map<String, Object?> settings = const {},
}) {
  return {
    'task_id': taskId ?? 'tvx_controller_$status',
    'status': status,
    'input_file': inputFile,
    'source_lang': 'en',
    'target_lang': 'zh-CN',
    'bilingual': true,
    'progress': ?progress,
    'checkpoint_status': ?checkpointStatus,
    if (progressDetail.isNotEmpty) 'progress_detail': progressDetail,
    if (outputPaths.isNotEmpty) 'output_paths': outputPaths,
    if (errorInfo.isNotEmpty) 'error_info': errorInfo,
    if (runtime.isNotEmpty) 'runtime': runtime,
    if (settings.isNotEmpty) 'settings': settings,
  };
}

class _FakeHandle implements LocalServiceHandle {
  _FakeHandle(
    DesktopSnapshot snapshot, {
    DesktopSnapshot? snapshotAfterReexport,
    Map<String, Object?>? taskEvents,
    Map<String, Object?>? resultOpen,
    Map<String, Object?>? mediaInspection,
    RpcRemoteException? resultReexportError,
    RpcRemoteException? runtimeCancelError,
    List<DesktopSnapshot>? snapshotSequence,
  }) : transport = _FakeTransport(
         {
           'service.info': {
             'service': 'transvortex.app_service',
             'protocol_version': 1,
             'app_version': 'test',
             'capabilities': ['desktop_snapshot'],
           },
           'service.health': {
             'service': 'transvortex.app_service',
             'status': 'healthy',
             'runtime': {'active': null},
             'pump': {'enabled': true},
           },
           'desktop.snapshot': snapshot.raw,
           'runtime.submitRun': {
             'ok': true,
             'task_id': 'tvx_1',
             'status': 'QUEUED',
             'terminal': false,
             'message': 'Task created',
           },
           'media.inspect':
               mediaInspection ??
               {
                 'kind': 'video',
                 'source_mode': 'asr',
                 'needs_asr': true,
                 'available': true,
                 'code': 'ready',
                 'subtitle_streams': [],
                 'selected_subtitle_stream': null,
               },
           'runtime.submitResume': {
             'ok': true,
             'task_id': 'tvx_controller_FAILED',
             'status': 'QUEUED',
             'terminal': false,
             'message': 'Resume queued',
           },
           'runtime.cancel': {
             'task_id': 'tvx_controller_RUNNING',
             'status': 'CANCEL_REQUESTED',
             'input_file': r'D:\movie.mp4',
             'runtime': {'can_cancel': true},
           },
           'tasks.events':
               taskEvents ??
               {
                 'task_id': 'tvx_1',
                 'events': [],
                 'cursor': 0,
                 'next_cursor': 0,
                 'has_more': false,
               },
           'result.reexport': {
             'ok': true,
             'output_paths': {'srt': r'D:\out.srt'},
           },
           'result.open': resultOpen,
         },
         failures: {
           'result.reexport': ?resultReexportError,
           'runtime.cancel': ?runtimeCancelError,
         },
         sequences: {
           'desktop.snapshot': ?snapshotSequence != null
               ? snapshotSequence.map((item) => item.raw).toList()
               : snapshotAfterReexport == null
               ? null
               : [snapshot.raw, snapshotAfterReexport.raw],
         },
       ) {
    client = AppServiceClient(transport);
  }

  final _exit = Completer<int>();
  final _FakeTransport transport;

  @override
  late final AppServiceClient client;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> shutdown({
    Duration rpcTimeout = const Duration(seconds: 2),
    Duration exitTimeout = const Duration(seconds: 2),
  }) async {}
}

class _FakeTransport implements AppServiceTransport {
  _FakeTransport(
    this.results, {
    Map<String, RpcRemoteException> failures = const {},
    Map<String, List<Object?>> sequences = const {},
  }) : failures = Map.of(failures),
       sequences = sequences.map((key, value) => MapEntry(key, List.of(value)));

  final Map<String, Object?> results;
  final Map<String, RpcRemoteException> failures;
  final Map<String, List<Object?>> sequences;
  final List<String> calls = [];
  final Map<String, Map<String, Object?>> lastParams = {};

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    calls.add(method);
    lastParams[method] = params;
    final failure = failures[method];
    if (failure != null) throw failure;
    final sequence = sequences[method];
    if (sequence != null && sequence.isNotEmpty) {
      if (sequence.length == 1) return sequence.single;
      return sequence.removeAt(0);
    }
    if (!results.containsKey(method)) {
      throw RpcRemoteException('method_not_found', method);
    }
    return results[method];
  }

  @override
  Future<void> close() async {}
}

class _RecordingPathOpener extends PathOpener {
  final List<String> revealed = [];
  final List<String> openedDirectories = [];

  @override
  Future<void> revealFile(String path) async {
    revealed.add(path);
  }

  @override
  Future<void> openDirectory(String path) async {
    openedDirectories.add(path);
  }
}
