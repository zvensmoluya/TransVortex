import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transvortex_desktop_flutter/main.dart';
import 'package:transvortex_desktop_flutter/model/main_window_controller.dart';
import 'package:transvortex_desktop_flutter/model/startup_args.dart';
import 'package:transvortex_desktop_flutter/model/window_state.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/current_window_controls.dart';
import 'package:transvortex_desktop_flutter/services/directory_probe.dart';
import 'package:transvortex_desktop_flutter/services/local_service_controller.dart';
import 'package:transvortex_desktop_flutter/services/path_opener.dart';
import 'package:transvortex_desktop_flutter/services/task_notification_service.dart';
import 'package:transvortex_desktop_flutter/services/window_state_bridge.dart';
import 'package:transvortex_desktop_flutter/theme/tokens.dart';
import 'package:transvortex_desktop_flutter/widgets/result_review_workspace.dart';

void main() {
  test('window argument parser falls back to CLI args when window args empty', () {
    expect(
      AppWindowArgs.parse(
        windowArgumentFromSources('', ['{"type":"translationSettings"}']),
      ).type,
      AppWindowType.translationSettings,
    );
    expect(
      AppWindowArgs.parse(
        windowArgumentFromSources('{"type":"asrSettings"}', [
          '{"type":"translationSettings"}',
        ]),
      ).type,
      AppWindowType.asrSettings,
    );
    expect(
      AppWindowArgs.parse(
        windowArgumentFromSources(null, ['asrSettings']),
      ).type,
      AppWindowType.asrSettings,
    );
    expect(
      AppWindowArgs.parse(
        windowArgumentFromSources(null, ['diagnostics']),
      ).type,
      AppWindowType.diagnostics,
    );
    expect(
      AppWindowArgs.parse(
        windowArgumentFromSources(null, ['{type:translationSettings}']),
      ).type,
      AppWindowType.translationSettings,
    );
    final startup = AppStartupArgs.parse(
      '{"type":"main","smoke":{"reportPath":"D:/tmp/report.json","serviceRoot":"D:/tmp/root","timeoutSeconds":3,"inputPath":"D:/tmp/demo.mkv","expectedOutputText":"Hello","screenshotPath":"D:/tmp/smoke.png","minVisibleSeconds":2,"postReportVisibleSeconds":3,"useControllerSubmission":true,"checkNotifications":true,"mainPhase":"blockedTranslation"}}',
    );
    expect(startup.window.type, AppWindowType.main);
    expect(startup.smoke?.reportPath, 'D:/tmp/report.json');
    expect(startup.smoke?.serviceRoot, 'D:/tmp/root');
    expect(startup.smoke?.timeout, const Duration(seconds: 3));
    expect(startup.smoke?.inputPath, 'D:/tmp/demo.mkv');
    expect(startup.smoke?.expectedOutputText, 'Hello');
    expect(startup.smoke?.screenshotPath, 'D:/tmp/smoke.png');
    expect(startup.smoke?.minVisibleDuration, const Duration(seconds: 2));
    expect(
      startup.smoke?.postReportVisibleDuration,
      const Duration(seconds: 3),
    );
    expect(startup.smoke?.useControllerSubmission, isTrue);
    expect(startup.smoke?.checkNotifications, isTrue);
    expect(startup.smoke?.mainPhase, SmokeMainPhase.blockedTranslation);
    final flagStartup = AppStartupArgs.fromSources(null, [
      '--tvx-smoke-report=D:/tmp/report.json',
      '--tvx-service-root=D:/tmp/root',
      '--tvx-smoke-timeout=4',
      '--tvx-smoke-input=D:/tmp/demo.mkv',
      '--tvx-smoke-expected-text=Hello',
      '--tvx-smoke-screenshot=D:/tmp/smoke.png',
      '--tvx-smoke-min-visible-seconds=5',
      '--tvx-smoke-post-report-seconds=6',
      '--tvx-smoke-use-controller=true',
      '--tvx-smoke-check-notifications=true',
      '--tvx-smoke-main-phase=blockedAsr',
      '--tvx-smoke-task-processing-scenario=edit',
    ]);
    expect(flagStartup.window.type, AppWindowType.main);
    expect(flagStartup.smoke?.reportPath, 'D:/tmp/report.json');
    expect(flagStartup.smoke?.serviceRoot, 'D:/tmp/root');
    expect(flagStartup.smoke?.timeout, const Duration(seconds: 4));
    expect(flagStartup.smoke?.inputPath, 'D:/tmp/demo.mkv');
    expect(flagStartup.smoke?.expectedOutputText, 'Hello');
    expect(flagStartup.smoke?.screenshotPath, 'D:/tmp/smoke.png');
    expect(flagStartup.smoke?.minVisibleDuration, const Duration(seconds: 5));
    expect(
      flagStartup.smoke?.postReportVisibleDuration,
      const Duration(seconds: 6),
    );
    expect(flagStartup.smoke?.useControllerSubmission, isTrue);
    expect(flagStartup.smoke?.checkNotifications, isTrue);
    expect(flagStartup.smoke?.mainPhase, SmokeMainPhase.blockedAsr);
    expect(flagStartup.smoke?.taskProcessingScenario, 'edit');
    final cancelFlagStartup = AppStartupArgs.fromSources(null, [
      '--tvx-smoke-report=D:/tmp/report.json',
      '--tvx-smoke-task-processing-scenario=cancel',
    ]);
    expect(cancelFlagStartup.smoke?.taskProcessingScenario, 'cancel');

    final emptyScreenshotStartup = AppStartupArgs.fromSources(null, [
      '--tvx-smoke-report=D:/tmp/report.json',
      '--tvx-smoke-screenshot=',
    ]);
    expect(emptyScreenshotStartup.smoke?.screenshotPath, isNull);

    final reviewArgs = AppWindowArgs.parse(
      '{"type":"resultReview","task_id":"tvx_review_123"}',
    );
    expect(reviewArgs.type, AppWindowType.taskProcessing);
    expect(reviewArgs.taskId, 'tvx_review_123');
    final positionedArgs = AppWindowArgs.parse(
      '{"type":"translationSettings","parent_bounds":{"x":40,"y":60,"width":720,"height":520},"visible_bounds":{"x":0,"y":0,"width":1920,"height":1080}}',
    );
    expect(positionedArgs.type, AppWindowType.translationSettings);
    expect(positionedArgs.parentBounds, const Rect.fromLTWH(40, 60, 720, 520));
    expect(positionedArgs.visibleBounds, const Rect.fromLTWH(0, 0, 1920, 1080));
    expect(
      AppWindowArgs.parse(positionedArgs.encode()).parentBounds,
      const Rect.fromLTWH(40, 60, 720, 520),
    );
    expect(
      AppWindowArgs.parse(positionedArgs.encode()).visibleBounds,
      const Rect.fromLTWH(0, 0, 1920, 1080),
    );
    expect(
      AppStartupArgs.parse(
        '{"type":"resultReview","taskId":"tvx_review_456","smoke":{"reportPath":"D:/tmp/review.json","taskProcessingScenario":"resume"}}',
      ).window.taskId,
      'tvx_review_456',
    );
    expect(
      AppStartupArgs.parse(
        '{"type":"resultReview","smoke":{"reportPath":"D:/tmp/review.json","task_processing_scenario":"resume"}}',
      ).smoke?.taskProcessingScenario,
      'resume',
    );
    final flaggedStartup = AppStartupArgs.fromSources(null, [
      '--tvx-window-type=resultReview',
      '--tvx-task-id=tvx_review_flagged',
    ]);
    expect(flaggedStartup.window.type, AppWindowType.taskProcessing);
    expect(flaggedStartup.window.taskId, 'tvx_review_flagged');
    expect(
      AppStartupArgs.fromSources(null, [
        '--tvx-window-type=taskProcessing',
        '--tvx-task-id=tvx_processing_123',
      ]).window.type,
      AppWindowType.taskProcessing,
    );
    final rawFlagStartup = AppStartupArgs.fromSources(
      '--tvx-window-type=taskProcessing --tvx-task-id=tvx_processing_raw',
      ['--tvx-smoke-report=D:/tmp/task-processing.json'],
    );
    expect(rawFlagStartup.window.type, AppWindowType.taskProcessing);
    expect(rawFlagStartup.window.taskId, 'tvx_processing_raw');
    expect(rawFlagStartup.smoke?.reportPath, 'D:/tmp/task-processing.json');
    expect(
      AppStartupArgs.fromSources(null, [
        '--tvx-window-type=taskProcessing',
        '--tvx-task-id=tvx_processing_123',
      ]).window.taskId,
      'tvx_processing_123',
    );
    expect(
      AppStartupArgs.fromSources(null, [
        '--tvx-window-type=taskHistory',
      ]).window.type,
      AppWindowType.taskProcessing,
    );
    final detailStartup = AppStartupArgs.fromSources(null, [
      '--tvx-window-type=taskDetail',
      '--tvx-task-id=tvx_detail_789',
    ]);
    expect(detailStartup.window.type, AppWindowType.taskProcessing);
    expect(detailStartup.window.taskId, 'tvx_detail_789');
  });

  test('window geometry follows native window roles', () {
    final parent = const Rect.fromLTWH(100, 200, 720, 520);
    final mainGeometry = windowGeometryFor(
      const AppWindowArgs(type: AppWindowType.main),
    );
    expect(mainGeometry.role, WindowRole.main);
    expect(mainGeometry.size, const Size(720, 520));
    expect(mainGeometry.center, isTrue);
    expect(mainGeometry.resizable, isFalse);
    expect(mainGeometry.maximizable, isFalse);

    final toolGeometry = windowGeometryFor(
      AppWindowArgs(
        type: AppWindowType.translationSettings,
        parentBounds: parent,
      ),
    );
    expect(toolGeometry.role, WindowRole.tool);
    expect(toolGeometry.size, const Size(820, 600));
    expect(toolGeometry.center, isFalse);
    expect(toolGeometry.position, const Offset(172, 248));
    expect(toolGeometry.alignment, isNull);
    expect(toolGeometry.resizable, isTrue);
    expect(toolGeometry.maximizable, isFalse);

    final directToolGeometry = windowGeometryFor(
      const AppWindowArgs(type: AppWindowType.asrSettings),
    );
    expect(directToolGeometry.center, isFalse);
    expect(directToolGeometry.position, isNull);
    expect(directToolGeometry.alignment, Alignment.topRight);

    final taskProcessingGeometry = windowGeometryFor(
      AppWindowArgs(type: AppWindowType.taskProcessing, parentBounds: parent),
    );
    expect(taskProcessingGeometry.role, WindowRole.workbench);
    expect(taskProcessingGeometry.size, const Size(1040, 720));
    expect(taskProcessingGeometry.position, const Offset(212, 256));
    expect(taskProcessingGeometry.maximizable, isTrue);

    final visibleBounds = const Rect.fromLTWH(0, 0, 1920, 1080);
    final lowerRightParent = const Rect.fromLTWH(1760, 960, 720, 520);
    final clampedToolGeometry = windowGeometryFor(
      AppWindowArgs(
        type: AppWindowType.translationSettings,
        parentBounds: lowerRightParent,
        visibleBounds: visibleBounds,
      ),
    );
    expect(clampedToolGeometry.position, const Offset(1100, 480));

    final clampedWorkbenchGeometry = windowGeometryFor(
      AppWindowArgs(
        type: AppWindowType.taskProcessing,
        parentBounds: lowerRightParent,
        visibleBounds: visibleBounds,
      ),
    );
    expect(clampedWorkbenchGeometry.position, const Offset(880, 360));

    expect(
      clampWindowPosition(
        const Offset(-200, -80),
        const Size(1040, 720),
        const Rect.fromLTWH(0, 0, 800, 600),
      ),
      Offset.zero,
    );
  });

  testWidgets('app uses packaged CJK font family', (tester) async {
    await tester.pumpWidget(
      TransVortexApp(localServiceController: _readyController()),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final theme = Theme.of(tester.element(find.text('TransVortex')));
    expect(theme.textTheme.bodyMedium?.fontFamily, T.fontFamily);
    expect(T.tFilename.fontFamily, T.fontFamily);
    expect(T.tCta.fontFamily, T.fontFamily);
    expect(T.tBrand.fontFamily, T.fontFamily);
    expect(T.tSection.fontFamily, T.fontFamily);
    expect(T.tBody.fontFamily, T.fontFamily);
    expect(T.tCaption.fontFamily, T.fontFamily);
  });

  testWidgets('main screen renders empty-state subject', (tester) async {
    await tester.pumpWidget(
      TransVortexApp(localServiceController: _readyController()),
    );
    // 呼吸动画在 repeat，不能 pumpAndSettle；推进一帧即可。
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('放入片源'), findsOneWidget);
    expect(find.text('选择片源'), findsOneWidget);
    expect(find.textContaining('SRT 字幕'), findsOneWidget);
    expect(find.text('TransVortex'), findsOneWidget);
    expect(find.textContaining('调试态'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('main empty-state CTA opens native picker path', (tester) async {
    FilePickerIO.registerWith();
    const pickerChannel = MethodChannel(
      'miguelruivo.flutter.plugins.filepicker',
      JSONMethodCodec(),
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pickerChannel,
        null,
      );
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pickerChannel,
      (call) async {
        expect(call.method, 'any');
        return [
          {
            'name': 'picked-video.mp4',
            'path': r'D:\media\picked-video.mp4',
            'size': 1234,
          },
        ];
      },
    );

    await tester.pumpWidget(
      TransVortexApp(localServiceController: _readyController()),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('选择片源'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('picked-video.mp4'), findsOneWidget);
    expect(find.text('开始译制'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('main screen applies readonly service snapshot readiness', (
    tester,
  ) async {
    await tester.pumpWidget(
      TransVortexApp(localServiceController: _readyController()),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('服务已连接'), findsOneWidget);
    expect(find.textContaining('等待片源'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('main screen running state tolerates long task text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: _readyController(
          snapshot: _desktopSnapshot(
            tasks: [
              _task(
                status: 'RUNNING',
                inputFile:
                    r'D:\AICenter\neko\video_2026-05-21_21-07-52.zh-CN.style3-preview-part04-with-a-ridiculously-long-tail.mp4',
                progress: 0.42,
                runtime: {'state': 'running'},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('制作中'), findsWidgets);
    expect(find.textContaining('ridiculously-long-tail'), findsOneWidget);
    expect(find.text('停止任务'), findsOneWidget);
    expect(find.textContaining('Task created'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('main screen failed state tolerates long recovery text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const longPath =
        r'D:\AICenter\neko\video_2026-05-21_21-07-52.zh-CN.style3-preview-part04-with-a-very-long-tail.mp4';

    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: _readyController(
          snapshot: _desktopSnapshot(
            tasks: [
              _task(
                status: 'FAILED',
                inputFile: longPath,
                errorInfo: {
                  'code': 'routing_provider_missing',
                  'hint_zh':
                      '翻译服务还没配置好，请打开翻译模型设置检查 provider、模型、base_url 和凭据；这是一段特意很长的恢复提示，用来防止失败态再次溢出。',
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('制作失败'), findsWidgets);
    expect(find.textContaining('翻译服务还没配置好'), findsOneWidget);
    expect(find.text('继续任务'), findsNothing);
    final tooltipMessages = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((tooltip) => tooltip.message)
        .whereType<String>()
        .toList();
    expect(tooltipMessages, isNot(contains(longPath)));
    expect(
      tooltipMessages.any(
        (message) =>
            message.contains('文件：video_2026-05-21') &&
            message.contains(r'位置：D:\AICenter\neko'),
      ),
      isTrue,
    );
    expectNoFlutterException();
  });

  testWidgets('main screen notifies when a running task completes', (
    tester,
  ) async {
    final notifications = _RecordingTaskNotificationService();
    final transport = _FakeTransport({
      'service.info': {
        'service': 'transvortex.app_service',
        'protocol_version': 1,
        'app_version': 'test',
        'capabilities': ['desktop_snapshot', 'runtime_pump'],
      },
      'service.health': {
        'service': 'transvortex.app_service',
        'status': 'healthy',
        'runtime': {'active': null},
        'pump': {'enabled': true},
      },
      'desktop.snapshot': _desktopSnapshot(
        tasks: [
          _task(
            taskId: 'tvx_widget_task',
            status: 'RUNNING',
            inputFile: r'D:\movie.mp4',
            runtime: {'state': 'running'},
          ),
        ],
      ).raw,
      'tasks.events': {
        'task_id': 'tvx_widget_task',
        'events': [],
        'cursor': 0,
        'next_cursor': 0,
        'has_more': false,
      },
    });
    final controller = _controllerForTransport(transport);

    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: controller,
        taskNotificationService: notifications,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    transport.results['desktop.snapshot'] = _desktopSnapshot(
      tasks: [
        _task(
          taskId: 'tvx_widget_task',
          status: 'DONE',
          inputFile: r'D:\movie.mp4',
        ),
      ],
    ).raw;
    await controller.refresh();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('审看结果'), findsOneWidget);
    expect(find.text('处理新片源'), findsOneWidget);
    expect(notifications.completed, ['movie.mp4']);
    expect(notifications.failed, isEmpty);
    expectNoFlutterException();
  });

  testWidgets('main screen notifies when a running task fails', (tester) async {
    final notifications = _RecordingTaskNotificationService();
    final transport = _FakeTransport({
      'service.info': {
        'service': 'transvortex.app_service',
        'protocol_version': 1,
        'app_version': 'test',
        'capabilities': ['desktop_snapshot', 'runtime_pump'],
      },
      'service.health': {
        'service': 'transvortex.app_service',
        'status': 'healthy',
        'runtime': {'active': null},
        'pump': {'enabled': true},
      },
      'desktop.snapshot': _desktopSnapshot(
        tasks: [
          _task(
            taskId: 'tvx_widget_task',
            status: 'RUNNING',
            inputFile: r'D:\movie.mp4',
            runtime: {'state': 'running'},
          ),
        ],
      ).raw,
      'tasks.events': {
        'task_id': 'tvx_widget_task',
        'events': [],
        'cursor': 0,
        'next_cursor': 0,
        'has_more': false,
      },
    });
    final controller = _controllerForTransport(transport);

    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: controller,
        taskNotificationService: notifications,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    transport.results['desktop.snapshot'] = _desktopSnapshot(
      tasks: [
        _task(
          taskId: 'tvx_widget_task',
          status: 'FAILED',
          inputFile: r'D:\movie.mp4',
          errorInfo: {'hint_zh': '翻译服务连不上。'},
        ),
      ],
    ).raw;
    await controller.refresh();
    await tester.pump(const Duration(milliseconds: 100));

    expect(notifications.completed, isEmpty);
    expect(notifications.failed, ['翻译服务连不上。']);
    expectNoFlutterException();
  });

  testWidgets('main failed recovery picks output directory and retries', (
    tester,
  ) async {
    FilePickerIO.registerWith();
    const pickerChannel = MethodChannel(
      'miguelruivo.flutter.plugins.filepicker',
      JSONMethodCodec(),
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pickerChannel,
        null,
      );
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pickerChannel,
      (call) async {
        expect(call.method, 'dir');
        return r'E:\subtitle-output';
      },
    );
    final transport = _FakeTransport({
      'service.info': {
        'service': 'transvortex.app_service',
        'protocol_version': 1,
        'app_version': 'test',
        'capabilities': ['desktop_snapshot', 'runtime_pump'],
      },
      'service.health': {
        'service': 'transvortex.app_service',
        'status': 'healthy',
        'runtime': {'active': null},
        'pump': {'enabled': true},
      },
      'desktop.snapshot': _desktopSnapshot(
        tasks: [
          _task(
            taskId: 'tvx_output_failed',
            status: 'FAILED',
            inputFile: r'D:\movie.mp4',
            errorInfo: {'code': 'output_not_writable', 'hint_zh': '输出目录不可写。'},
          ),
        ],
      ).raw,
      'runtime.submitRun': {
        'ok': true,
        'task_id': 'tvx_retry',
        'status': 'QUEUED',
      },
      'tasks.events': {
        'task_id': 'tvx_retry',
        'events': [],
        'cursor': 0,
        'next_cursor': 0,
        'has_more': false,
      },
    });

    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: _controllerForTransport(transport),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('选择输出目录'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final submitParams = transport.lastParams['runtime.submitRun'];
    final request = submitParams?['request'] as Map<String, Object?>?;
    expect(request?['output_dir'], r'E:\subtitle-output');
    expect(find.textContaining('正在重试'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('main failed recovery resumes resumable tasks', (tester) async {
    final transport = _FakeTransport({
      'service.info': {
        'service': 'transvortex.app_service',
        'protocol_version': 1,
        'app_version': 'test',
        'capabilities': ['desktop_snapshot', 'runtime_pump'],
      },
      'service.health': {
        'service': 'transvortex.app_service',
        'status': 'healthy',
        'runtime': {'active': null},
        'pump': {'enabled': true},
      },
      'desktop.snapshot': _desktopSnapshot(
        tasks: [
          _task(
            taskId: 'tvx_resumable_failed',
            status: 'FAILED',
            inputFile: r'D:\movie.mp4',
            runtime: {'can_resume': true},
          ),
        ],
      ).raw,
      'runtime.submitResume': {
        'ok': true,
        'task_id': 'tvx_resumable_failed',
        'status': 'QUEUED',
      },
      'tasks.events': {
        'task_id': 'tvx_resumable_failed',
        'events': [],
        'cursor': 0,
        'next_cursor': 0,
        'has_more': false,
      },
    });

    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: _controllerForTransport(transport),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('继续任务'), findsOneWidget);
    await tester.tap(find.text('继续任务'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final resumeParams = transport.lastParams['runtime.submitResume'];
    final request = resumeParams?['request'] as Map<String, Object?>?;
    final overrides = request?['overrides'] as Map<String, Object?>?;
    expect(request?['task_id'], 'tvx_resumable_failed');
    expect(request?['provider'], 'RealProvider');
    expect(request?['model'], 'real-model');
    expect(overrides?['output_format'], 'both');
    expect(overrides?['memory_enabled'], isTrue);
    expectNoFlutterException();
  });

  testWidgets('main failed recovery re-exports missing results', (
    tester,
  ) async {
    final transport = _FakeTransport({
      'service.info': {
        'service': 'transvortex.app_service',
        'protocol_version': 1,
        'app_version': 'test',
        'capabilities': ['desktop_snapshot', 'runtime_pump'],
      },
      'service.health': {
        'service': 'transvortex.app_service',
        'status': 'healthy',
        'runtime': {'active': null},
        'pump': {'enabled': true},
      },
      'desktop.snapshot': _desktopSnapshot(
        tasks: [
          _task(
            taskId: 'tvx_result_missing',
            status: 'FAILED',
            inputFile: r'D:\movie.mp4',
            errorInfo: {
              'code': 'result_missing',
              'hint_zh': '结果文件不在原位置了，可以重新导出字幕。',
            },
          ),
        ],
      ).raw,
      'result.reexport': {
        'ok': true,
        'output_paths': {'srt': r'D:\movie.srt'},
      },
      'tasks.events': {
        'task_id': 'tvx_result_missing',
        'events': [],
        'cursor': 0,
        'next_cursor': 0,
        'has_more': false,
      },
    });

    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: _controllerForTransport(transport),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('重新导出'), findsOneWidget);
    await tester.tap(find.text('重新导出'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(transport.lastParams['result.reexport'], {
      'task_id': 'tvx_result_missing',
      'output_format': 'both',
      'bilingual': true,
    });
    expect(find.textContaining('已重新导出字幕'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets(
    'main output-directory recovery re-exports existing task results',
    (tester) async {
      const pickerChannel = MethodChannel(
        'miguelruivo.flutter.plugins.filepicker',
        JSONMethodCodec(),
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          pickerChannel,
          null,
        );
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pickerChannel,
        (call) async {
          expect(call.method, 'dir');
          return r'E:\fixed-output';
        },
      );
      final initialSnapshot = _desktopSnapshot(
        tasks: [
          _task(
            taskId: 'tvx_reexport_output_failed',
            status: 'DONE',
            inputFile: r'D:\movie.mp4',
            outputPaths: {'srt': r'D:\movie.zh-CN.srt'},
          ),
        ],
      ).raw;
      final recoveredSnapshot = _desktopSnapshot(
        tasks: [
          _task(
            taskId: 'tvx_reexport_output_failed',
            status: 'DONE',
            inputFile: r'D:\movie.mp4',
            outputPaths: {'srt': r'E:\fixed-output\movie.zh-CN.srt'},
          ),
        ],
      ).raw;
      final transport = _FakeTransport(
        {
          'service.info': {
            'service': 'transvortex.app_service',
            'protocol_version': 1,
            'app_version': 'test',
            'capabilities': ['desktop_snapshot', 'runtime_pump'],
          },
          'service.health': {
            'service': 'transvortex.app_service',
            'status': 'healthy',
            'runtime': {'active': null},
            'pump': {'enabled': true},
          },
          'desktop.snapshot': initialSnapshot,
          'result.reexport': {
            'ok': true,
            'output_paths': {'srt': r'E:\fixed-output\movie.zh-CN.srt'},
          },
          'tasks.events': {
            'task_id': 'tvx_reexport_output_failed',
            'events': [],
            'cursor': 0,
            'next_cursor': 0,
            'has_more': false,
          },
        },
        failures: {
          'result.reexport': [
            RpcRemoteException(
              'output_not_writable',
              'output path is not writable',
              details: const {
                'error_info': {
                  'code': 'output_not_writable',
                  'hint_zh': '输出目录不可写。',
                },
              },
            ),
          ],
        },
        sequences: {
          'desktop.snapshot': [initialSnapshot, recoveredSnapshot],
        },
      );

      await tester.pumpWidget(
        TransVortexApp(
          localServiceController: _controllerForTransport(transport),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('重新导出'), findsOneWidget);
      await tester.tap(find.text('重新导出'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('选择输出目录'), findsOneWidget);

      await tester.tap(find.text('选择输出目录'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(transport.lastParams['result.reexport'], {
        'task_id': 'tvx_reexport_output_failed',
        'output_format': 'both',
        'output_dir': r'E:\fixed-output',
        'bilingual': true,
      });
      expect(transport.calls, isNot(contains('runtime.submitRun')));
      expect(find.textContaining('已重新导出字幕'), findsOneWidget);
      expectNoFlutterException();
    },
  );

  testWidgets('translation settings window renders provider tool layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      const TransVortexApp(windowType: AppWindowType.translationSettings),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('翻译模型设置'), findsOneWidget);
    expect(find.text('翻译服务'), findsOneWidget);
    expect(find.text('服务地址 (Base URL)'), findsOneWidget);
    expect(find.textContaining('中文备注'), findsNothing);
    expect(find.textContaining('spike'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('settings window hides raw window channel errors', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      throw PlatformException(
        code: 'service_unavailable',
        message: 'Local Service caller is not attached',
      );
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('需要从主窗口打开设置'), findsOneWidget);
    expect(find.textContaining('CHANNEL_UNREGISTERED'), findsNothing);
    expect(find.textContaining('WindowChannelException'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('translation settings window reads providers through bridge', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return _desktopSnapshot().raw;
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('RealProvider'), findsWidgets);
    expect(find.text('real-model'), findsWidgets);
    expect(find.widgetWithText(TextField, '自定义模型名'), findsOneWidget);
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(
      fields.map((field) => field.controller?.text),
      isNot(contains('real-model')),
    );
    expect(find.textContaining('密钥只写入用户级凭据'), findsOneWidget);
    expect(find.text('OpenAI 兼容'), findsWidgets);
    expect(find.text('openai-compatible'), findsNothing);
    expect(find.textContaining('auth.json'), findsNothing);
    expect(find.textContaining('provider YAML'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('translation settings window explains empty provider config', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(withProviders: false).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('还没选默认模型'), findsOneWidget);
    expect(find.text('还没有翻译服务'), findsOneWidget);
    expect(find.text('选择一个翻译服务'), findsOneWidget);
    expect(find.textContaining('method_not_found'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('translation settings window tolerates long model lists', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(longModels: true).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('gemini-3.5-flash'), findsWidgets);
    expect(find.text('设为翻译默认'), findsOneWidget);
    expect(find.textContaining('密钥只写入用户级凭据'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings window saves provider through bridge', (
    tester,
  ) async {
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    Map<String, Object?>? savedProviderDraft;
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') return _desktopSnapshot().raw;
      if (method == 'provider.save') {
        savedProviderDraft = Map<String, Object?>.from(
          params['provider_draft'] as Map,
        );
        return {'ok': true};
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'routing': {
            'primary': {'provider': 'RealProvider', 'model': 'real-model'},
          },
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('保存翻译服务'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('provider.save'));
    expect(calls, contains('provider.routing.save'));
    expect(savedProviderDraft?['models'], contains('real-model'));
    expect(savedRouting?['primary'], {
      'provider': 'RealProvider',
      'model': 'real-model',
    });
    expect(find.textContaining('翻译服务已保存'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings window localizes provider test failures', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return _desktopSnapshot().raw;
      if (method == 'provider.test') {
        throw RpcRemoteException(
          'provider_connection_failed',
          'connection refused by upstream',
          details: {
            'error_info': {'hint_zh': '模型服务暂时连不上，请检查服务地址和网络。'},
          },
        );
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('测试连接'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('模型服务暂时连不上'), findsOneWidget);
    expect(find.textContaining('connection refused'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('ASR settings window saves default provider through bridge', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(700, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') return _desktopSnapshot().raw;
      if (method == 'asr.provider.save') {
        return {'ok': true, 'provider': 'local'};
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('保存识别默认'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('asr.provider.save'));
    expect(find.textContaining('识别默认已保存'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('ASR settings window mirrors local model_size into editor', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(localModelSizeOnly: true).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('当前识别：'), findsOneWidget);
    expect(find.textContaining('large-v3'), findsWidgets);
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields.map((field) => field.controller?.text), contains('large-v3'));
    expectNoFlutterException();
  });

  testWidgets('ASR settings window explains empty saved schemes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(withAsrProviders: false).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('当前识别：本机'), findsOneWidget);
    expect(find.text('保存后会出现在这里'), findsOneWidget);
    expect(find.text('保存识别默认'), findsOneWidget);
    expect(find.textContaining('method_not_found'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('diagnostics window reads doctor report through bridge', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final openedTools = <AppWindowType>[];
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(environment: _doctorEnvironment()).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });
    bridge.attachToolWindowOpener((args) async {
      openedTools.add(args.type);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.diagnostics,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('诊断'), findsOneWidget);
    expect(find.text('检查项'), findsOneWidget);
    expect(find.textContaining('诊断：失败'), findsOneWidget);
    expect(find.text('翻译配置文件'), findsOneWidget);
    expect(find.text('产物目录'), findsOneWidget);
    expect(find.text('Provider 文件'), findsNothing);
    expect(find.text('Artifacts'), findsNothing);
    expect(find.textContaining('provider 协议'), findsNothing);
    expect(find.textContaining('provider 配置'), findsNothing);
    expect(find.textContaining('ASR provider'), findsNothing);
    expect(find.textContaining('本机识别依赖'), findsWidgets);
    expect(find.text('faster-whisper 缺失'), findsOneWidget);
    expect(find.text('faster_whisper_missing'), findsNothing);
    expect(find.textContaining('本机语音识别需要 faster-whisper'), findsWidgets);
    expect(find.textContaining('服务：本机语音识别'), findsOneWidget);
    expect(find.textContaining('类型：本机处理'), findsOneWidget);
    expect(find.textContaining('local_inprocess'), findsNothing);
    expect(find.text('去语音识别设置'), findsOneWidget);
    await tester.tap(find.text('去语音识别设置'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(openedTools, [AppWindowType.asrSettings]);
    expect(find.textContaining('已打开语音识别设置'), findsOneWidget);
    expect(find.text('python_found'), findsNothing);
    await tester.tap(find.text('Python · 通过'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Python 可用'), findsOneWidget);
    expect(find.text('python_found'), findsNothing);
    expect(find.text('去语音识别设置'), findsNothing);
    expect(find.text('刷新诊断'), findsOneWidget);
    expect(find.textContaining('method_not_found'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('diagnostics window opens artifact directory checks', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final pathOpener = _RecordingPathOpener();
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(
          environment: {
            'status': 'FAIL',
            'root_dir': r'D:\thevox\TransVortex',
            'providers_file': r'D:\thevox\TransVortex\providers.yaml',
            'artifacts_dir': r'E:\blocked-artifacts',
            'checks': [
              {
                'name': 'python',
                'status': 'PASS',
                'code': 'python_found',
                'message': 'Python is available',
                'hint_zh': 'Python 已可用。',
              },
              {
                'name': 'artifacts',
                'status': 'FAIL',
                'code': 'artifacts_not_writable',
                'message': 'artifacts directory is not writable',
                'hint_zh': 'artifacts 目录不可写。请检查路径和权限。',
                'details': {'path': r'E:\blocked-artifacts'},
              },
            ],
          },
        ).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.diagnostics,
        store: store,
        bridge: bridge,
        pathOpener: pathOpener,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('产物目录 · 失败'), findsOneWidget);
    expect(find.text('产物目录不可用'), findsOneWidget);
    expect(find.text('打开产物目录'), findsOneWidget);

    await tester.tap(find.text('打开产物目录'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(pathOpener.openedDirectories, [r'E:\blocked-artifacts']);
    expect(find.text('已打开产物目录'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('diagnostics window shows task context from snapshot', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final openedTools = <AppWindowArgs>[];
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(
          environment: _doctorEnvironment(
            status: 'PASS',
            extraChecks: [
              {
                'name': 'runtime_queue',
                'status': 'WARN',
                'code': 'runtime_interrupted_tasks',
                'message': 'Interrupted tasks need user review.',
                'hint_zh': '有中断任务需要查看和处理。',
                'details': {'task_id': 'tvx_diag_context_active_123456'},
              },
            ],
          ),
          runtime: {
            'active': {'task_id': 'tvx_diag_context_active_123456'},
            'queued': ['tvx_waiting_1'],
            'interrupted': ['tvx_interrupted_1'],
          },
          tasks: [
            _task(
              taskId: 'tvx_diag_context_active_123456',
              status: 'RUNNING',
              inputFile: r'D:\media\active.mp4',
              runtime: {'state': 'running'},
            ),
            _task(
              taskId: 'tvx_diag_context_done_654321',
              status: 'DONE',
              inputFile: r'D:\media\done.mp4',
            ),
          ],
        ).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });
    bridge.attachToolWindowOpener((args) async {
      openedTools.add(args);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.diagnostics,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.drag(find.byType(Scrollable).last, const Offset(0, -520));
    await tester.pumpAndSettle();

    expect(find.text('任务上下文'), findsOneWidget);
    expect(find.text('当前任务'), findsOneWidget);
    expect(find.text('active.mp4 · 制作中'), findsWidgets);
    expect(find.text('任务数'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('队列'), findsOneWidget);
    expect(find.text('1 个等待'), findsOneWidget);
    expect(find.text('中断任务'), findsOneWidget);
    expect(find.text('1 个'), findsOneWidget);
    expect(find.text('最新任务'), findsOneWidget);
    expect(find.textContaining('tvx_diag'), findsNothing);
    expect(find.textContaining('RUNNING'), findsNothing);
    expect(find.text('查看任务处理'), findsOneWidget);
    await tester.tap(find.text('查看任务处理'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(openedTools.single.type, AppWindowType.taskProcessing);
    expect(openedTools.single.taskId, 'tvx_diag_context_active_123456');
    expect(find.textContaining('已打开任务处理'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('diagnostics window reads recent tasks and result summary', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final openedTools = <AppWindowArgs>[];
    final directoryProbe = _RecordingDirectoryProbe(
      const DirectoryProbeResult(ok: false, message: '目录不可写：denied'),
    );
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(
          environment: _doctorEnvironment(status: 'PASS'),
          tasks: [
            _task(
              taskId: 'tvx_snapshot_done_123456',
              status: 'DONE',
              inputFile: r'D:\media\snapshot.mp4',
            ),
          ],
        ).raw;
      }
      if (method == 'tasks.list') {
        return [
          _task(
            taskId: 'tvx_recent_done_abcdef',
            status: 'DONE',
            inputFile: r'D:\media\recent.mp4',
            outputPaths: {'srt': r'D:\media\recent.zh-CN.srt'},
          ),
          _task(
            taskId: 'tvx_recent_running_abcdef',
            status: 'RUNNING',
            inputFile: r'D:\media\running.mp4',
            runtime: {'state': 'running'},
          ),
        ];
      }
      if (method == 'result.open') {
        expect(params['task_id'], 'tvx_recent_done_abcdef');
        return {
          'task': _task(
            taskId: 'tvx_recent_done_abcdef',
            status: 'DONE',
            inputFile: r'D:\media\recent.mp4',
          ),
          'segments': [
            {
              'id': 1,
              'start': 0,
              'end': 1,
              'text_src': 'Hello',
              'text_tgt': '你好',
              'issues': ['字幕阅读速度偏快'],
            },
            {
              'id': 2,
              'start': 1,
              'end': 2,
              'text_src': 'World',
              'text_tgt': '世界',
            },
          ],
          'output_paths': {'srt': r'D:\media\recent.zh-CN.srt'},
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });
    bridge.attachToolWindowOpener((args) async {
      openedTools.add(args);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.diagnostics,
        store: store,
        bridge: bridge,
        directoryProbe: directoryProbe,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.drag(find.byType(Scrollable).last, const Offset(0, -720));
    await tester.pumpAndSettle();

    expect(find.text('最近任务'), findsOneWidget);
    expect(find.text('snapshot.mp4'), findsOneWidget);
    await tester.tap(find.text('刷新'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.text('recent.mp4'), findsOneWidget);
    expect(find.text('running.mp4'), findsOneWidget);
    expect(find.text('状态：已完成'), findsOneWidget);
    expect(find.text('状态：制作中'), findsOneWidget);
    expect(find.text('未完成'), findsOneWidget);
    expect(find.textContaining('tvx_recent'), findsNothing);
    expect(find.textContaining('DONE'), findsNothing);
    await tester.tap(find.text('检查目录'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(directoryProbe.checkedPaths, [r'D:\media']);
    expect(find.text('结果目录：目录不可写：denied'), findsOneWidget);
    expect(find.textContaining('结果目录不可写'), findsOneWidget);
    await tester.tap(find.text('任务处理').first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(openedTools.single.type, AppWindowType.taskProcessing);
    expect(openedTools.single.taskId, 'tvx_recent_done_abcdef');
    expect(find.textContaining('已打开任务处理'), findsOneWidget);
    await tester.tap(find.text('结果摘要').first);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.text('结果摘要'), findsWidgets);
    expect(find.text('片段'), findsOneWidget);
    expect(find.text('2'), findsWidgets);
    expect(find.text('问题'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
    expect(find.text('srt'), findsOneWidget);
    expect(find.textContaining('已读取结果摘要'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('result review workspace renders real result workspace', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'result.open') {
        expect(params['task_id'], 'tvx_review_done_123456');
        return {
          'task': _task(
            taskId: 'tvx_review_done_123456',
            status: 'DONE',
            inputFile: r'D:\media\review-source.mp4',
            outputPaths: {'srt': r'D:\media\review-source.zh-CN.srt'},
          ),
          'segments': [
            {
              'id': 1,
              'start': 0.4,
              'end': 2.8,
              'text_src': 'Good morning.',
              'text_tgt': '早上好。',
              'provider': 'RealProvider',
              'model': 'real-model',
              'issues': ['字幕阅读速度偏快'],
            },
            {
              'id': 2,
              'start': 3.0,
              'end': 5.2,
              'text_src': 'Welcome back.',
              'text_tgt': '',
            },
          ],
          'output_paths': {'srt': r'D:\media\review-source.zh-CN.srt'},
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResultReviewWorkspace(
            taskId: 'tvx_review_done_123456',
            bridge: bridge,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('result.open'));
    expect(find.text('结果审看'), findsNothing);
    expect(find.text('review-source.mp4'), findsOneWidget);
    expect(find.text('源语 英语 · 目标 简体中文'), findsOneWidget);
    expect(find.text('源语 en · 目标 zh-CN'), findsNothing);
    expect(find.text('片段'), findsOneWidget);
    expect(find.text('2'), findsWidgets);
    expect(find.text('问题'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
    expect(find.text('Good morning.'), findsOneWidget);
    expect(find.text('早上好。'), findsOneWidget);
    expect(find.text('Welcome back.'), findsOneWidget);
    expect(find.text('字幕阅读速度偏快'), findsOneWidget);

    await tester.tap(find.text('有问题'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Good morning.'), findsOneWidget);
    expect(find.text('Welcome back.'), findsNothing);

    await tester.tap(find.text('空译文'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Good morning.'), findsNothing);
    expect(find.text('Welcome back.'), findsOneWidget);

    await tester.tap(find.text('全部'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Good morning.'), findsOneWidget);
    expect(find.text('Welcome back.'), findsOneWidget);
    expect(find.textContaining('method_not_found'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('result review workspace saves edits and reexports subtitles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    final paramsByMethod = <String, Map<String, Object?>>{};
    var targetText = '早上好。';

    Map<String, Object?> resultPayload() => {
      'task': _task(
        taskId: 'tvx_review_edit_123456',
        status: 'DONE',
        inputFile: r'D:\media\review-source.mp4',
        outputPaths: {'srt': r'D:\media\review-source.zh-CN.srt'},
      ),
      'segments': [
        {
          'id': 1,
          'start': 0.4,
          'end': 2.8,
          'text_src': 'Good morning.',
          'text_tgt': targetText,
          'provider': 'RealProvider',
          'model': 'real-model',
        },
      ],
      'output_paths': {'srt': r'D:\media\review-source.zh-CN.srt'},
    };

    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      paramsByMethod[method] = params;
      if (method == 'result.open') return resultPayload();
      if (method == 'result.segments.save') {
        final segments = params['segments'] as List<Object?>;
        final first = segments.first as Map<Object?, Object?>;
        targetText = '${first['text_tgt']}';
        return resultPayload();
      }
      if (method == 'result.reexport') {
        return {
          'task_id': 'tvx_review_edit_123456',
          'output_paths': {'ass': r'D:\media\review-source.zh-CN.ass'},
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResultReviewWorkspace(
            taskId: 'tvx_review_edit_123456',
            bridge: bridge,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField).first, '早上好，欢迎回来。');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('有未保存修改'), findsOneWidget);

    await tester.tap(find.text('保存修改'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final savedSegments =
        paramsByMethod['result.segments.save']?['segments'] as List<Object?>;
    final savedFirst = savedSegments.first as Map<Object?, Object?>;
    expect(savedFirst['text_tgt'], '早上好，欢迎回来。');
    expect(find.text('已保存修改'), findsOneWidget);

    expect(find.text('导出格式'), findsOneWidget);
    await tester.tap(find.text('ASS'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(Switch).first);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('重新导出'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(paramsByMethod['result.reexport'], {
      'task_id': 'tvx_review_edit_123456',
      'output_format': 'ass',
      'bilingual': false,
    });
    expect(calls.where((method) => method == 'result.open').length, 2);
    expect(find.text('已重新导出字幕'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('task processing window selects tasks and runs light actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1040, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final pathOpener = _RecordingPathOpener();
    final directoryProbe = _RecordingDirectoryProbe(
      const DirectoryProbeResult(ok: true, message: '目录可写'),
    );
    final calls = <String>[];
    final paramsByMethod = <String, Map<String, Object?>>{};
    final opened = <AppWindowArgs>[];
    var targetText = '早上好。';
    var runningStatus = 'RUNNING';
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      paramsByMethod[method] = params;
      if (method == 'tasks.list') {
        return [
          _task(
            taskId: 'tvx_processing_done_123456',
            status: 'DONE',
            inputFile: r'D:\media\processing-done.mp4',
            taskDir: r'D:\artifacts\tvx_processing_done_123456',
            outputPaths: {'srt': r'D:\media\processing-done.zh-CN.srt'},
          ),
          _task(
            taskId: 'tvx_processing_failed_123456',
            status: 'FAILED',
            inputFile: r'D:\media\processing-failed.mp4',
            taskDir: r'D:\artifacts\tvx_processing_failed_123456',
            errorInfo: {'hint_zh': '可以继续任务。'},
            runtime: {'can_resume': true},
          ),
          _task(
            taskId: 'tvx_processing_running_123456',
            status: runningStatus,
            inputFile: r'D:\media\processing-running.mp4',
            taskDir: r'D:\artifacts\tvx_processing_running_123456',
            runtime: {'can_cancel': true, 'state': 'running'},
          ),
        ];
      }
      if (method == 'tasks.events') {
        final taskId = params['task_id'];
        return {
          'task_id': taskId,
          'events': [
            {
              'type': 'stage',
              'stage': 'EXPORT',
              'message': taskId == 'tvx_processing_done_123456'
                  ? 'done export'
                  : 'failed export',
              'created_at': '2026-07-06T10:00:00Z',
            },
          ],
          'cursor': 0,
          'next_cursor': 1,
          'has_more': false,
        };
      }
      if (method == 'runtime.submitResume') {
        return {
          'ok': true,
          'task_id': 'tvx_processing_failed_123456',
          'status': 'QUEUED',
          'message': '任务已重新排队。',
        };
      }
      if (method == 'runtime.cancel') {
        runningStatus = 'CANCEL_REQUESTED';
        return _task(
          taskId: 'tvx_processing_running_123456',
          status: runningStatus,
          inputFile: r'D:\media\processing-running.mp4',
          taskDir: r'D:\artifacts\tvx_processing_running_123456',
          runtime: {'can_cancel': true, 'state': 'running'},
        );
      }
      if (method == 'result.open') {
        return {
          'task': _task(
            taskId: 'tvx_processing_done_123456',
            status: 'DONE',
            inputFile: r'D:\media\processing-done.mp4',
            outputPaths: {'srt': r'D:\media\processing-done.zh-CN.srt'},
          ),
          'segments': [
            {
              'id': 1,
              'start': 0.4,
              'end': 2.8,
              'text_src': 'Good morning.',
              'text_tgt': targetText,
              'provider': 'RealProvider',
              'model': 'real-model',
            },
          ],
          'output_paths': {'srt': r'D:\media\processing-done.zh-CN.srt'},
        };
      }
      if (method == 'result.segments.save') {
        final segments = params['segments'] as List<Object?>;
        final first = segments.first as Map<Object?, Object?>;
        targetText = '${first['text_tgt']}';
        return {
          'task': _task(
            taskId: 'tvx_processing_done_123456',
            status: 'DONE',
            inputFile: r'D:\media\processing-done.mp4',
            outputPaths: {'srt': r'D:\media\processing-done.zh-CN.srt'},
          ),
          'segments': [
            {
              'id': 1,
              'start': 0.4,
              'end': 2.8,
              'text_src': 'Good morning.',
              'text_tgt': targetText,
            },
          ],
          'output_paths': {'srt': r'D:\media\processing-done.zh-CN.srt'},
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });
    bridge.attachToolWindowOpener((args) async {
      opened.add(args);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.taskProcessing,
        taskId: 'tvx_processing_done_123456',
        store: store,
        bridge: bridge,
        pathOpener: pathOpener,
        directoryProbe: directoryProbe,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('tasks.list'));
    expect(calls, contains('tasks.events'));
    expect(find.text('任务处理'), findsOneWidget);
    expect(find.text('任务片列'), findsOneWidget);
    expect(find.text('processing-done.mp4'), findsWidgets);
    expect(find.text('processing-failed.mp4'), findsOneWidget);
    expect(find.text('processing-running.mp4'), findsOneWidget);
    expect(find.text('字幕编辑'), findsOneWidget);
    expect(find.text('导出格式'), findsOneWidget);
    expect(calls, contains('result.open'));
    expect(opened, isEmpty);

    await tester.tap(find.text('返回概览'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('结果目录'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(pathOpener.openedDirectories, [r'D:\media']);
    expect(find.text('已打开结果目录'), findsOneWidget);

    await tester.tap(find.text('检查结果目录'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(directoryProbe.checkedPaths, [r'D:\media']);
    expect(find.text('结果目录可写，可以重新导出。'), findsOneWidget);

    expect(find.text('全部 3'), findsOneWidget);
    expect(find.text('制作中 1'), findsOneWidget);
    expect(find.text('待处理 1'), findsOneWidget);
    expect(find.text('已完成 1'), findsOneWidget);

    await tester.tap(find.text('制作中 1'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('显示 1 / 3 个任务'), findsOneWidget);
    expect(find.text('processing-running.mp4'), findsWidgets);
    expect(find.text('processing-done.mp4'), findsNothing);
    expect(find.text('processing-failed.mp4'), findsNothing);

    await tester.tap(find.text('待处理 1'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('processing-failed.mp4'), findsWidgets);
    expect(find.text('processing-running.mp4'), findsNothing);

    await tester.tap(find.text('继续任务'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(paramsByMethod['runtime.submitResume'], {
      'request': {
        'request_version': 1,
        'task_id': 'tvx_processing_failed_123456',
      },
    });
    await tester.tap(find.text('制作中 1'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('取消任务'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(paramsByMethod['runtime.cancel'], {
      'task_id': 'tvx_processing_running_123456',
      'force': false,
    });
    expect(find.text('已请求取消任务。'), findsOneWidget);

    await tester.tap(find.text('待处理 1'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('任务目录'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(pathOpener.openedDirectories, [
      r'D:\media',
      r'D:\artifacts\tvx_processing_failed_123456',
    ]);
    expectNoFlutterException();
  });
}

void expectNoFlutterException() {
  final exception = TestWidgetsFlutterBinding.instance.takeException();
  expect(exception, isNull);
}

LocalServiceController _readyController({DesktopSnapshot? snapshot}) {
  return LocalServiceController(
    sessionFactory: () async => _FakeHandle(
      info: const ServiceInfo(
        service: 'transvortex.app_service',
        protocolVersion: 1,
        appVersion: 'test',
        capabilities: ['desktop_snapshot', 'runtime_pump'],
      ),
      health: const ServiceHealth(
        service: 'transvortex.app_service',
        status: 'healthy',
        runtime: {'active': null},
        pump: {'enabled': true},
      ),
      snapshot: snapshot ?? _desktopSnapshot(),
    ),
  );
}

LocalServiceController _controllerForTransport(_FakeTransport transport) {
  return LocalServiceController(
    sessionFactory: () async => _FakeHandle.fromTransport(transport),
  );
}

DesktopSnapshot _desktopSnapshot({
  bool longModels = false,
  bool localModelSizeOnly = false,
  bool withProviders = true,
  bool withAsrProviders = true,
  List<Map<String, Object?>> tasks = const [],
  Map<String, Object?> runtime = const {},
  Map<String, Object?>? environment,
}) {
  final models = longModels
      ? [
          'gemini-3.5-flash',
          'gemini-3.1-pro-preview',
          'gemini-3.1-flash-lite-preview',
          'gemini-2.5-flash',
          'gemini-2.5-pro',
          'gemini-2.5-flash-lite',
          'gemini-2.0-flash-lite-preview-02-05',
        ]
      : ['real-model'];
  return DesktopSnapshot.fromJson({
    'config': {
      'routing': {
        'primary': {'provider': 'RealProvider', 'model': models.first},
        'fallback': [
          {'provider': 'RealProvider', 'model': 'real-model'},
        ],
      },
      'pipeline': {'asr_provider': 'local'},
      'pipeline_file_version': {'mtime_ns': 1, 'size': 2},
      'providers_file_version': {'mtime_ns': 3, 'size': 4},
      'providers': withProviders
          ? [
              {
                'name': 'RealProvider',
                'has_key': true,
                'base_url': 'https://example.com/v1',
                'api_type': 'openai-compatible',
                'compat_mode': 'openai_chat',
                'credential_id': 'RealProvider',
                'models': models,
              },
            ]
          : const [],
      'asr_providers': withAsrProviders
          ? {
              'local': {
                'name': 'Local ASR',
                'kind': 'local_inprocess',
                'protocol': 'faster_whisper',
                if (!localModelSizeOnly) 'model': 'large-v3',
                if (localModelSizeOnly) 'local': {'model_size': 'large-v3'},
                'has_key': true,
              },
            }
          : const {},
    },
    'tasks': tasks,
    'runtime': runtime,
    'environment': environment ?? _doctorEnvironment(status: 'PASS'),
  });
}

Map<String, Object?> _doctorEnvironment({
  String status = 'FAIL',
  List<Map<String, Object?>> extraChecks = const [],
}) {
  return {
    'status': status,
    'root_dir': r'D:\thevox\TransVortex',
    'providers_file': r'D:\thevox\TransVortex\providers.yaml',
    'artifacts_dir': r'D:\thevox\TransVortex\artifacts',
    'checks': [
      {
        'name': 'python',
        'status': 'PASS',
        'code': 'python_found',
        'message': 'Python is available',
        'hint_zh': 'Python 已可用。',
        'details': {'executable': r'C:\Python\python.exe'},
      },
      {
        'name': 'faster_whisper',
        'status': status == 'PASS' ? 'PASS' : 'FAIL',
        'code': status == 'PASS'
            ? 'faster_whisper_found'
            : 'faster_whisper_missing',
        'message': 'faster-whisper is required for local in-process ASR',
        'hint_zh': status == 'PASS'
            ? 'faster-whisper 已可用。'
            : '本地 ASR 需要 faster-whisper。请执行 python -m pip install -e .[asr]。',
        'details': {'provider': 'local', 'kind': 'local_inprocess'},
      },
      ...extraChecks,
    ],
  };
}

Map<String, Object?> _task({
  String? taskId,
  required String status,
  required String inputFile,
  String? taskDir,
  double? progress,
  String? checkpointStatus,
  Map<String, String> outputPaths = const {},
  Map<String, Object?> errorInfo = const {},
  Map<String, Object?> runtime = const {},
}) {
  return {
    'task_id': taskId ?? 'tvx_widget_$status',
    'status': status,
    'input_file': inputFile,
    'task_dir': ?taskDir,
    'source_lang': 'en',
    'target_lang': 'zh-CN',
    'bilingual': true,
    'progress': ?progress,
    'checkpoint_status': ?checkpointStatus,
    if (outputPaths.isNotEmpty) 'output_paths': outputPaths,
    if (errorInfo.isNotEmpty) 'error_info': errorInfo,
    if (runtime.isNotEmpty) 'runtime': runtime,
  };
}

class _FakeHandle implements LocalServiceHandle {
  _FakeHandle({
    required this.info,
    required this.health,
    required this.snapshot,
  }) : client = AppServiceClient(
         _FakeTransport({
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
         }),
       );

  _FakeHandle.fromTransport(_FakeTransport transport)
    : info = const ServiceInfo(
        service: 'transvortex.app_service',
        protocolVersion: 1,
        appVersion: 'test',
        capabilities: ['desktop_snapshot', 'runtime_pump'],
      ),
      health = const ServiceHealth(
        service: 'transvortex.app_service',
        status: 'healthy',
        runtime: {'active': null},
        pump: {'enabled': true},
      ),
      snapshot = DesktopSnapshot(
        config: const {},
        tasks: const [],
        runtime: const {},
        environment: const {},
        raw: const {},
      ),
      client = AppServiceClient(transport);

  final ServiceInfo info;
  final ServiceHealth health;
  final DesktopSnapshot snapshot;

  @override
  final AppServiceClient client;

  @override
  Future<int> get exitCode => Completer<int>().future;

  @override
  Future<void> shutdown({
    Duration rpcTimeout = const Duration(seconds: 2),
    Duration exitTimeout = const Duration(seconds: 2),
  }) async {}
}

class _FakeTransport implements AppServiceTransport {
  _FakeTransport(
    this.results, {
    Map<String, List<RpcRemoteException>> failures = const {},
    Map<String, List<Object?>> sequences = const {},
  }) : failures = failures.map((key, value) => MapEntry(key, List.of(value))),
       sequences = sequences.map((key, value) => MapEntry(key, List.of(value)));

  final Map<String, Object?> results;
  final Map<String, List<RpcRemoteException>> failures;
  final Map<String, List<Object?>> sequences;
  final calls = <String>[];
  final lastParams = <String, Map<String, Object?>>{};

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    calls.add(method);
    lastParams[method] = params;
    final failure = failures[method];
    if (failure != null && failure.isNotEmpty) {
      throw failure.removeAt(0);
    }
    final sequence = sequences[method];
    if (sequence != null && sequence.isNotEmpty) {
      if (sequence.length == 1) return sequence.single;
      return sequence.removeAt(0);
    }
    return results[method];
  }

  @override
  Future<void> close() async {}
}

class _RecordingTaskNotificationService implements TaskNotificationService {
  final completed = <String>[];
  final failed = <String>[];

  @override
  Future<void> notifyCompleted(MainWindowViewModel view) async {
    completed.add(view.source?.name ?? '');
  }

  @override
  Future<void> notifyFailed(MainWindowViewModel view) async {
    failed.add(view.failure?.reason ?? '');
  }
}

class _RecordingPathOpener extends PathOpener {
  final openedDirectories = <String>[];

  @override
  Future<void> openDirectory(String path) async {
    openedDirectories.add(path);
  }
}

class _RecordingDirectoryProbe extends DirectoryWriteProbe {
  _RecordingDirectoryProbe(this.result);

  final DirectoryProbeResult result;
  final checkedPaths = <String>[];

  @override
  Future<DirectoryProbeResult> checkWritable(String path) async {
    checkedPaths.add(path);
    return result;
  }
}
