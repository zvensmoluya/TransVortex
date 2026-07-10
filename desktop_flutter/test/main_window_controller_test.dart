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
      expect(controller.view.asrLabel, '本机 · large-v3');
      expect(controller.view.sourceLang, 'auto');
      expect(controller.view.targetLang, 'zh-CN');
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
    expect(overrides['allowSystemSuggestions'], isTrue);
    expect(overrides['memory_enabled'], isTrue);
    expect(overrides['memory_bootstrap_enabled'], isTrue);
    expect(overrides['memory_patch_enabled'], isTrue);
    expect(overrides['asr_provider'], 'local');
    expect(overrides['asr_model'], 'large-v3');
  });

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
    expect(overrides['allowSystemSuggestions'], isFalse);
    expect(overrides.containsKey('memory_enabled'), isFalse);
    expect(overrides['memory_bootstrap_enabled'], isFalse);
    expect(overrides['memory_patch_enabled'], isFalse);
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

      expect(controller.view.state, MainState.blocked);
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

    expect(controller.view.failure?.reason, '缺少 API key。');
    expect(controller.view.failure?.actionLabel, '去配置翻译');
    expect(
      controller.view.failure?.target,
      MainRecoveryTarget.translationSettings,
    );
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

    expect(controller.view.failure?.reason, '找不到片源文件。');
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

      expect(controller.view.failure?.reason, '任务运行失败，请在任务处理中查看失败线索后重试。');
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

    expect(controller.view.runningText, '正在翻译字幕');
    expect(controller.view.progress, 0.35);
  });

  test('controller sends cancel request for running task', () async {
    final handle = _FakeHandle(
      _desktopSnapshot(
        tasks: [
          _task(
            status: 'RUNNING',
            inputFile: r'D:\movie.mp4',
            progress: 0.2,
            runtime: {'state': 'running'},
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
          status: 'RUNNING',
          inputFile: r'D:\movie.mp4',
          progress: 0.2,
          runtime: {'state': 'running'},
        ),
      ),
    );
    await controller.cancelRun();

    expect(handle.transport.calls, contains('runtime.cancel'));
    expect(handle.transport.lastParams['runtime.cancel'], {
      'task_id': 'tvx_controller_RUNNING',
      'force': false,
    });
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
      final overrides = request['overrides'] as Map<String, Object?>;
      final routing = request['routing'] as Map<String, Object?>;
      final primary = routing['primary'] as Map<String, Object?>;
      final fallback = routing['fallback'] as List<Object?>;
      expect(request['task_id'], 'tvx_controller_FAILED');
      expect(primary['provider'], 'RealProvider');
      expect(primary['model'], 'resume-model');
      expect(
        (fallback.first as Map<String, Object?>)['model'],
        'fallback-model',
      );
      expect(request.containsKey('provider'), isFalse);
      expect(request.containsKey('model'), isFalse);
      expect(overrides['output_format'], 'both');
      expect(overrides['allowSystemSuggestions'], isTrue);
      expect(overrides['memory_enabled'], isTrue);
      expect(overrides['memory_bootstrap_enabled'], isTrue);
      expect(overrides['memory_patch_enabled'], isTrue);
    },
  );

  test(
    'controller disables only memory generation through home reminder resume payload',
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
      final overrides = request['overrides'] as Map<String, Object?>;
      expect(overrides['allowSystemSuggestions'], isFalse);
      expect(overrides.containsKey('memory_enabled'), isFalse);
      expect(overrides['memory_bootstrap_enabled'], isFalse);
      expect(overrides['memory_patch_enabled'], isFalse);
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
  List<String> extraModels = const [],
  List<Map<String, Object?>> routingProfiles = const [],
  List<Map<String, Object?>> tasks = const [],
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
        },
      ],
      'asr_providers': {
        'local': {
          'name': 'local',
          'kind': 'local_inprocess',
          'protocol': 'faster_whisper',
          'model': 'large-v3',
          'has_key': asrHasKey,
        },
      },
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
    RpcRemoteException? resultReexportError,
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
         failures: {'result.reexport': ?resultReexportError},
         sequences: {
           'desktop.snapshot': ?snapshotAfterReexport == null
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
