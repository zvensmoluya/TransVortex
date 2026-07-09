import 'dart:async';
import 'dart:io';

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
import 'package:transvortex_desktop_flutter/widgets/designed_tooltip.dart';
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

  test('translation settings view source contains no NUL bytes', () {
    final bytes = File(
      'lib/widgets/translation_settings_view.dart',
    ).readAsBytesSync();
    expect(bytes.contains(0), isFalse);
  });

  testWidgets('app uses packaged CJK font family', (tester) async {
    await tester.pumpWidget(
      TransVortexApp(localServiceController: _readyController()),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final theme = Theme.of(tester.element(find.text('TransVortex')));
    expect(theme.textTheme.bodyMedium?.fontFamily, T.fontFamily);
    expect(T.displayFontFamily, 'TransVortexDisplay');
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

    expect(find.text('把视频或字幕放进来吧'), findsOneWidget);
    expect(find.text('浏览文件'), findsNothing);
    expect(
      find.byKey(const ValueKey('main-empty-pick-target')),
      findsOneWidget,
    );
    expect(find.textContaining('也可以点击选择'), findsNothing);
    expect(find.textContaining('支持视频'), findsNothing);
    expect(find.textContaining('翻译'), findsOneWidget);
    expect(find.textContaining('DeepSeek'), findsNothing);
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

    await tester.tap(find.byKey(const ValueKey('main-empty-pick-target')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('picked-video.mp4'), findsOneWidget);
    expect(find.textContaining('也会'), findsOneWidget);
    final termsToggle = find.text('整理术语记忆');
    expect(termsToggle, findsOneWidget);
    final enabledTooltips = tester
        .widgetList<DesignedTooltip>(find.byType(DesignedTooltip))
        .map((tooltip) => tooltip.message)
        .whereType<String>()
        .toList();
    expect(enabledTooltips, contains('制作时自动整理术语记忆。不会改动人工术语表。'));

    await tester.tap(termsToggle);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('不整理术语记忆'), findsOneWidget);
    final disabledTooltips = tester
        .widgetList<DesignedTooltip>(find.byType(DesignedTooltip))
        .map((tooltip) => tooltip.message)
        .whereType<String>()
        .toList();
    expect(disabledTooltips, contains('本次不生成新的术语记忆。已有术语表不受影响。'));
    expect(find.text('开始译制'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('main translation menu submits profile routing snapshot', (
    tester,
  ) async {
    installFilePickerMock(tester);
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
        multiRoutingProfiles: true,
        withRoutingFallback: true,
      ).raw,
      'runtime.submitRun': {
        'ok': true,
        'task_id': 'tvx_profile_route',
        'status': 'QUEUED',
      },
      'tasks.events': {
        'task_id': 'tvx_profile_route',
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
    await tester.tap(find.byKey(const ValueKey('main-empty-pick-target')));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('real-model'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('配置 1'), findsOneWidget);
    expect(find.text('backup-model'), findsOneWidget);

    activatePopupMenuItem(
      tester,
      const ValueKey('translation-choice-profile-RealProvider-backup-model'),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('开始译制'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final submitParams = transport.lastParams['runtime.submitRun'];
    final request = submitParams?['request'] as Map<String, Object?>?;
    final routing = request?['routing'] as Map<String, Object?>?;
    final primary = routing?['primary'] as Map<String, Object?>?;
    final fallback = routing?['fallback'] as List<Object?>?;
    expect(primary?['provider'], 'RealProvider');
    expect(primary?['model'], 'backup-model');
    expect(fallback, isEmpty);
    expect(request?.containsKey('provider'), isFalse);
    expect(request?.containsKey('model'), isFalse);
    expectNoFlutterException();
  });

  testWidgets('main translation menu direct model has no fallback', (
    tester,
  ) async {
    installFilePickerMock(tester);
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
        multiRoutingProfiles: true,
        withTwoRoutingFallbacks: true,
      ).raw,
      'runtime.submitRun': {
        'ok': true,
        'task_id': 'tvx_direct_route',
        'status': 'QUEUED',
      },
      'tasks.events': {
        'task_id': 'tvx_direct_route',
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
    await tester.tap(find.byKey(const ValueKey('main-empty-pick-target')));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('real-model'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('third-model'), findsNothing);
    activatePopupMenuItem(tester, const ValueKey('translation-more-models'));
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.text('更多翻译模型'), findsOneWidget);

    activatePopupMenuItem(
      tester,
      const ValueKey('translation-choice-direct-RealProvider-third-model'),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('开始译制'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final submitParams = transport.lastParams['runtime.submitRun'];
    final request = submitParams?['request'] as Map<String, Object?>?;
    final routing = request?['routing'] as Map<String, Object?>?;
    final primary = routing?['primary'] as Map<String, Object?>?;
    final fallback = routing?['fallback'] as List<Object?>?;
    expect(primary?['provider'], 'RealProvider');
    expect(primary?['model'], 'third-model');
    expect(fallback, isEmpty);
    expect(request?.containsKey('provider'), isFalse);
    expect(request?.containsKey('model'), isFalse);
    expectNoFlutterException();
  });

  testWidgets('main screen keeps readonly service status out of chrome', (
    tester,
  ) async {
    await tester.pumpWidget(
      TransVortexApp(localServiceController: _readyController()),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('TransVortex'), findsOneWidget);
    expect(find.textContaining('服务已连接'), findsNothing);
    expect(find.textContaining('等待片源'), findsNothing);
    expect(find.text('把视频或字幕放进来吧'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('main screen running state tolerates long task text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    installFilePickerMock(
      tester,
      name:
          'video_2026-05-21_21-07-52.zh-CN.style3-preview-part04-with-a-ridiculously-long-tail.mp4',
      path:
          r'D:\AICenter\neko\video_2026-05-21_21-07-52.zh-CN.style3-preview-part04-with-a-ridiculously-long-tail.mp4',
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
      'desktop.snapshot': _desktopSnapshot().raw,
      'runtime.submitRun': {
        'ok': true,
        'task_id': 'tvx_widget_running',
        'status': 'QUEUED',
      },
      'tasks.events': {
        'task_id': 'tvx_widget_running',
        'events': [
          {'stage': 'translate', 'progress': 0.42},
        ],
        'cursor': 0,
        'next_cursor': 1,
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
    await pickSourceAndStart(tester);

    expect(find.textContaining('正在翻译字幕'), findsOneWidget);
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
    installFilePickerMock(
      tester,
      name:
          'video_2026-05-21_21-07-52.zh-CN.style3-preview-part04-with-a-very-long-tail.mp4',
      path: longPath,
    );
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
        'desktop.snapshot': _desktopSnapshot().raw,
      },
      failures: {
        'runtime.submitRun': [
          RpcRemoteException(
            'routing_provider_missing',
            'provider not found',
            details: const {
              'error_info': {
                'code': 'routing_provider_missing',
                'hint_zh':
                    '翻译服务还没配置好，请打开翻译模型设置检查 provider、模型、base_url 和凭据；这是一段特意很长的恢复提示，用来防止失败态再次溢出。',
              },
            },
          ),
        ],
      },
    );

    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: _controllerForTransport(transport),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('main-empty-pick-target')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('开始译制'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('翻译服务还没配置好'), findsOneWidget);
    expect(find.textContaining('制作失败'), findsNothing);
    expect(find.text('继续任务'), findsNothing);
    final tooltipMessages = tester
        .widgetList<DesignedTooltip>(find.byType(DesignedTooltip))
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
    installFilePickerMock(tester);
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
      'desktop.snapshot': _desktopSnapshot().raw,
      'runtime.submitRun': {
        'ok': true,
        'task_id': 'tvx_widget_task',
        'status': 'QUEUED',
      },
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
    await pickSourceAndStart(tester);

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
    installFilePickerMock(tester);
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
      'desktop.snapshot': _desktopSnapshot().raw,
      'runtime.submitRun': {
        'ok': true,
        'task_id': 'tvx_widget_task',
        'status': 'QUEUED',
      },
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
    await pickSourceAndStart(tester);

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
        if (call.method == 'any') {
          return [
            {'name': 'movie.mp4', 'path': r'D:\movie.mp4', 'size': 1234},
          ];
        }
        expect(call.method, 'dir');
        return r'E:\subtitle-output';
      },
    );
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
        'desktop.snapshot': _desktopSnapshot().raw,
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
      },
      failures: {
        'runtime.submitRun': [
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
    );

    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: _controllerForTransport(transport),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const ValueKey('main-empty-pick-target')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('开始译制'));
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

  testWidgets('main home reminder resumes resumable tasks', (tester) async {
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

    expect(find.textContaining('有 1 个未完成制作'), findsOneWidget);
    expect(find.textContaining('movie.mp4'), findsOneWidget);
    expect(find.textContaining('制作失败'), findsNothing);
    await tester.tap(find.text('继续'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final resumeParams = transport.lastParams['runtime.submitResume'];
    final request = resumeParams?['request'] as Map<String, Object?>?;
    final overrides = request?['overrides'] as Map<String, Object?>?;
    final routing = request?['routing'] as Map<String, Object?>?;
    final primary = routing?['primary'] as Map<String, Object?>?;
    expect(request?['task_id'], 'tvx_resumable_failed');
    expect(primary?['provider'], 'RealProvider');
    expect(primary?['model'], 'real-model');
    expect(request?.containsKey('provider'), isFalse);
    expect(request?.containsKey('model'), isFalse);
    expect(overrides?['output_format'], 'both');
    expect(overrides?['memory_enabled'], isTrue);
    expectNoFlutterException();
  });

  testWidgets('main home reminder can be dismissed without blocking new work', (
    tester,
  ) async {
    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: _readyController(
          snapshot: _desktopSnapshot(
            tasks: [
              _task(
                taskId: 'tvx_dismissible_failed',
                status: 'INTERRUPTED',
                inputFile: r'D:\movie.mp4',
                runtime: {'can_resume': true},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('有 1 个未完成制作'), findsOneWidget);
    await tester.tap(find.text('稍后'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('有 1 个未完成制作'), findsNothing);
    expect(
      find.byKey(const ValueKey('main-empty-pick-target')),
      findsOneWidget,
    );
    expectNoFlutterException();
  });

  testWidgets('main failed recovery re-exports missing results', (
    tester,
  ) async {
    installFilePickerMock(tester);
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
      'desktop.snapshot': _desktopSnapshot().raw,
      'runtime.submitRun': {
        'ok': true,
        'task_id': 'tvx_result_missing',
        'status': 'QUEUED',
      },
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

    final controller = _controllerForTransport(transport);

    await tester.pumpWidget(TransVortexApp(localServiceController: controller));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await pickSourceAndStart(tester);
    transport.results['desktop.snapshot'] = _desktopSnapshot(
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
    ).raw;
    await controller.refresh();
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
          if (call.method == 'any') {
            return [
              {'name': 'movie.mp4', 'path': r'D:\movie.mp4', 'size': 1234},
            ];
          }
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
          'desktop.snapshot': _desktopSnapshot().raw,
          'runtime.submitRun': {
            'ok': true,
            'task_id': 'tvx_reexport_output_failed',
            'status': 'QUEUED',
          },
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
      );
      final controller = _controllerForTransport(transport);

      await tester.pumpWidget(
        TransVortexApp(localServiceController: controller),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      transport.results['desktop.snapshot'] = initialSnapshot;
      await pickSourceAndStart(tester);

      expect(find.text('重新导出'), findsOneWidget);
      await tester.tap(find.text('重新导出'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('选择输出目录'), findsOneWidget);

      transport.results['desktop.snapshot'] = recoveredSnapshot;
      await tester.tap(find.text('选择输出目录'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(transport.lastParams['result.reexport'], {
        'task_id': 'tvx_reexport_output_failed',
        'output_format': 'both',
        'output_dir': r'E:\fixed-output',
        'bilingual': true,
      });
      expect(find.textContaining('已重新导出字幕'), findsOneWidget);
      expectNoFlutterException();
    },
  );

  testWidgets('translation settings window renders connections and profiles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
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

    // Default tab is 连接: the connection list + detail are visible.
    expect(find.text('翻译模型设置'), findsOneWidget);
    expect(find.text('连接'), findsWidgets);
    expect(find.text('常用模型'), findsWidgets);
    expect(find.text('模型连接'), findsNothing);
    expect(find.text('翻译方案'), findsNothing);
    expect(find.text('刷新'), findsNothing);
    expect(find.text('已配置连接'), findsOneWidget);
    expect(find.text('服务地址 (Base URL)'), findsOneWidget);
    expect(find.text('连接设置'), findsOneWidget);
    expect(find.text('连接状态'), findsOneWidget);
    expect(find.text('RealProvider'), findsWidgets);
    expect(find.text('OpenAI Chat 兼容'), findsWidgets);
    expect(find.textContaining('用户级凭据'), findsWidgets);
    expect(find.textContaining('中文备注'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets(
    'settings window falls back to local service when bridge is absent',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(820, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      final localService = _readyController();
      addTearDown(localService.dispose);
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
          localServiceController: localService,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('RealProvider'), findsWidgets);
      expect(find.textContaining('需要从主窗口打开设置'), findsNothing);
      expect(find.textContaining('CHANNEL_UNREGISTERED'), findsNothing);
      expect(find.textContaining('WindowChannelException'), findsNothing);
      expectNoFlutterException();
    },
  );

  testWidgets('translation settings window explains empty connections', (
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

    expect(find.text('还没有连接'), findsOneWidget);
    expect(find.text('添加一个模型服务后，就能保存可用模型。'), findsOneWidget);
    expect(find.textContaining('method_not_found'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('translation profiles tab guides when there are no connections', (
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

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('先添加连接'), findsOneWidget);
    expect(find.text('常用模型由主模型和备用模型组成。'), findsOneWidget);
    expect(find.text('去添加连接'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings tolerates long model names', (
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

    expect(find.text('gemini-2.0-flash-lite-preview-02-05'), findsOneWidget);

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.ensureVisible(find.text('主模型'));
    await tester.pump();

    expect(find.text('gemini-2.0-flash-lite-preview-02-05'), findsWidgets);
    expectNoFlutterException();
  });

  testWidgets('translation settings window fetches models into the draft', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return _desktopSnapshot().raw;
      if (method == 'provider.models') {
        return {
          'status': 'PASS',
          'hint_zh': '已拉取到 2 个模型。',
          'models': ['model-a', 'model-b'],
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

    await tester.tap(find.text('拉取模型'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('model-a'), findsOneWidget);
    expect(find.text('model-b'), findsOneWidget);
    expect(find.textContaining('并入模型清单'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings window saves a connection only', (
    tester,
  ) async {
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    Map<String, Object?>? savedProviderDraft;
    String? savedApiKey;
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') return _desktopSnapshot().raw;
      if (method == 'provider.save') {
        savedProviderDraft = Map<String, Object?>.from(
          params['provider_draft'] as Map,
        );
        savedApiKey = params['api_key'] as String?;
        return {'ok': true};
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

    final baseUrlField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.controller?.text == 'https://example.com/v1',
    );
    expect(baseUrlField, findsOneWidget);
    await tester.enterText(baseUrlField, 'https://edited.example/v1');

    final apiKeyField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.obscureText,
    );
    expect(apiKeyField, findsOneWidget);
    await tester.enterText(apiKeyField, 'sk-edited');

    final modelInput = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.hintText == '添加模型名',
    );
    expect(modelInput, findsOneWidget);
    await tester.enterText(modelInput, 'typed-model');

    await tester.tap(find.text('保存连接'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('provider.save'));
    expect(calls, isNot(contains('provider.routing.save')));
    expect(savedProviderDraft?['base_url'], 'https://edited.example/v1');
    expect(savedProviderDraft?['models'], contains('real-model'));
    expect(savedProviderDraft?['models'], contains('typed-model'));
    expect(savedProviderDraft?.containsKey('api_key'), isFalse);
    expect(savedApiKey, 'sk-edited');
    expect(calls.where((method) => method == 'provider.save').length, 1);
    expect(find.textContaining('连接已保存'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings prevents removing referenced model', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
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

    final removeModel = find.byKey(const ValueKey('remove-model-real-model'));
    expect(removeModel, findsOneWidget);
    await tester.ensureVisible(removeModel);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(removeModel);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('这个模型正在被常用模型使用'), findsOneWidget);
    expect(find.text('real-model'), findsWidgets);
    expect(calls, isNot(contains('provider.save')));
    expect(calls, isNot(contains('provider.routing.save')));
    expectNoFlutterException();
  });

  testWidgets(
    'translation settings creates a connection from provider preset',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      Map<String, Object?>? savedProviderDraft;
      bridge.attachServiceCaller((method, params) async {
        if (method == 'desktop.snapshot') return _desktopSnapshot().raw;
        if (method == 'provider.save') {
          savedProviderDraft = Map<String, Object?>.from(
            params['provider_draft'] as Map,
          );
          return {'ok': true};
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

      await tester.tap(find.text('添加连接'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('选择厂商'), findsOneWidget);
      expect(find.text('选择协议'), findsOneWidget);
      await tester.ensureVisible(find.text('连接信息'));
      await tester.pump();
      expect(find.text('连接信息'), findsOneWidget);
      expect(find.text('DeepSeek'), findsWidgets);

      await tester.tap(find.text('保存连接'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(savedProviderDraft?['name'], 'deepseek');
      expect(savedProviderDraft?['base_url'], 'https://api.deepseek.com');
      expect(savedProviderDraft?['env_key'], 'DEEPSEEK_API_KEY');
      expect(savedProviderDraft?['credential_id'], 'deepseek');
      expect(savedProviderDraft?['compat_mode'], 'openai_chat');
      expect(savedProviderDraft?['api_type'], 'openai-compatible');
      expect(savedProviderDraft?['models'], contains('deepseek-v4-pro'));
      expect(
        (savedProviderDraft?['endpoint'] as Map?)?['path_template'],
        '/chat/completions',
      );
      expect(find.textContaining('连接已保存'), findsOneWidget);
      expectNoFlutterException();
    },
  );

  testWidgets(
    'translation settings creates a custom provider with selected protocol',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      Map<String, Object?>? savedProviderDraft;
      bridge.attachServiceCaller((method, params) async {
        if (method == 'desktop.snapshot') return _desktopSnapshot().raw;
        if (method == 'provider.save') {
          savedProviderDraft = Map<String, Object?>.from(
            params['provider_draft'] as Map,
          );
          return {'ok': true};
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

      await tester.tap(find.text('添加连接'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('自定义厂商'));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.ensureVisible(find.text('连接信息'));
      await tester.pump();
      expect(find.text('自定义厂商'), findsWidgets);
      expect(find.text('OpenAI-compatible Chat'), findsWidgets);

      final nameField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.controller?.text == 'custom_provider',
      );
      expect(nameField, findsOneWidget);
      await tester.enterText(nameField, 'my_gateway');

      final baseUrlField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.controller?.text == 'https://api.openai.com/v1',
      );
      expect(baseUrlField, findsOneWidget);
      await tester.enterText(baseUrlField, 'https://gateway.example/v1');

      await tester.tap(find.text('保存连接'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(savedProviderDraft?['name'], 'my_gateway');
      expect(savedProviderDraft?['base_url'], 'https://gateway.example/v1');
      expect(savedProviderDraft?['env_key'], 'TVX_PROVIDER_MY_GATEWAY_API_KEY');
      expect(savedProviderDraft?['credential_id'], 'my_gateway');
      expect(savedProviderDraft?['compat_mode'], 'openai_chat');
      expect(savedProviderDraft?['models'], contains('custom-model'));
      expect(find.textContaining('连接已保存'), findsOneWidget);
      expectNoFlutterException();
    },
  );

  testWidgets('translation settings hides provider internals from the app UI', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
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

    await tester.ensureVisible(find.text('连接状态'));
    await tester.pump();
    expect(find.text('连接状态'), findsOneWidget);
    expect(find.text('服务类型'), findsWidgets);
    expect(find.text('来源'), findsWidgets);
    expect(find.text('凭据'), findsOneWidget);
    expect(find.text('本机配置'), findsWidgets);
    expect(find.text('OpenAI Chat 兼容'), findsWidgets);
    expect(find.text('展开高级配置'), findsNothing);
    expect(find.text('高级配置'), findsNothing);
    expect(find.text('协议标识'), findsNothing);
    expect(find.text('环境变量'), findsNothing);
    expect(find.text('请求端点'), findsNothing);
    expect(find.text('响应提取'), findsNothing);
    expect(find.text('调用限制'), findsNothing);
    expect(find.text('凭据 ID'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('translation settings deletes an unused connection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final initial = _desktopSnapshot();
    final afterDelete = _desktopSnapshot(withProviders: false);
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    var snapshotCalls = 0;
    Map<String, Object?>? deleteParams;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        snapshotCalls += 1;
        return snapshotCalls == 1 ? initial.raw : afterDelete.raw;
      }
      if (method == 'provider.delete') {
        deleteParams = Map<String, Object?>.from(params);
        return {'deleted': true};
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

    await tester.tap(find.text('删除连接'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(deleteParams, {
      'name': 'RealProvider',
      'expected_version': {'mtime_ns': 3, 'size': 4},
    });
    expect(find.textContaining('连接已删除：RealProvider'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings explains blocked connection deletion', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return _desktopSnapshot().raw;
      if (method == 'provider.delete') {
        return {'deleted': false, 'blocked': true, 'code': 'provider_in_use'};
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

    await tester.tap(find.text('删除连接'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('正在被常用模型使用'), findsOneWidget);
    expect(find.text('RealProvider'), findsWidgets);
    expectNoFlutterException();
  });

  testWidgets('translation profiles tab sets the primary model', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(multiRoutingProfiles: true).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': 'route_1',
          'routing_profiles': params['profiles'],
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

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.ensureVisible(find.text('主模型'));
    await tester.pump();
    // The primary picker lists connection then model pills; tap the backup
    // model under the RealProvider connection to set it as primary.
    await tester.tap(
      find.byKey(const ValueKey('primary-model-RealProvider-backup-model')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('provider.routing.save'));
    expect(calls, isNot(contains('provider.save')));
    final profiles = savedRouting?['profiles'] as List?;
    final active = profiles?.cast<Map>().firstWhere(
      (item) => item['id'] == 'route_1',
    );
    expect(active?['primary'], {
      'provider': 'RealProvider',
      'model': 'backup-model',
    });
    expect(find.textContaining('主模型已设为'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings switches routing profiles', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    var activeProfile = 'route_1';
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(
          multiRoutingProfiles: true,
          activeRoutingProfile: activeProfile,
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        activeProfile = '${params['active_profile']}';
        return {
          'active_routing_profile': activeProfile,
          'routing_profiles': params['profiles'],
          'routing': {
            'active_profile': activeProfile,
            'primary': {'provider': 'RealProvider', 'model': 'backup-model'},
          },
          'providers_file_version': {'mtime_ns': 5, 'size': 6},
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

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('配置 1'), findsWidgets);
    expect(find.text('配置 2'), findsWidgets);

    await tester.tap(find.text('配置 2'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(savedRouting?['active_profile'], 'route_2');
    expect(savedRouting?['next_profile_seq'], 3);
    expect(savedRouting?['expected_version'], {'mtime_ns': 3, 'size': 4});
    expect(savedRouting?['profiles'], isA<List>());
    expect(find.textContaining('已切换常用模型：配置 2'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings renames routing profile', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(
          multiRoutingProfiles: true,
          activeRoutingProfile: 'route_1',
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': 'route_1',
          'routing_profiles': params['profiles'],
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

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    final nameField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller?.text == '配置 1',
    );
    expect(nameField, findsOneWidget);
    await tester.enterText(nameField, '正式翻译');
    final saveName = find.byKey(const ValueKey('save-profile-name'));
    await tester.ensureVisible(saveName);
    await tester.pump();
    await tester.tap(saveName);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final profiles = savedRouting?['profiles'] as List?;
    final renamed = profiles?.cast<Map>().firstWhere(
      (item) => item['id'] == 'route_1',
    );
    expect(renamed?['name'], '正式翻译');
    expect(savedRouting?['active_profile'], 'route_1');
    expect(find.textContaining('常用模型已重命名：正式翻译'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings saves current route as a new profile', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(
          multiRoutingProfiles: true,
          activeRoutingProfile: 'route_1',
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': params['active_profile'],
          'routing_profiles': params['profiles'],
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

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    final createProfile = find.byKey(const ValueKey('create-profile'));
    await tester.ensureVisible(createProfile);
    await tester.pump();
    await tester.tap(createProfile);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final profiles = savedRouting?['profiles'] as List?;
    final created = profiles?.cast<Map>().firstWhere(
      (item) => item['id'] == 'route_3',
    );
    expect(savedRouting?['active_profile'], 'route_3');
    expect(savedRouting?['next_profile_seq'], 4);
    expect(created?['name'], '常用模型 3');
    expect(created?['primary'], {
      'provider': 'RealProvider',
      'model': 'real-model',
    });
    expect(find.textContaining('已新建常用模型：常用模型 3'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings deletes active routing profile', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(
          multiRoutingProfiles: true,
          activeRoutingProfile: 'route_1',
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': params['active_profile'],
          'routing_profiles': params['profiles'],
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

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    final deleteProfile = find.byKey(const ValueKey('delete-profile'));
    await tester.ensureVisible(deleteProfile);
    await tester.pump();
    await tester.tap(deleteProfile);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final profiles = savedRouting?['profiles'] as List?;
    expect(savedRouting?['active_profile'], 'route_2');
    expect(profiles?.cast<Map>().map((item) => item['id']), ['route_2']);
    expect(find.textContaining('已删除常用模型：配置 1'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings adds a fallback model', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(
          multiRoutingProfiles: true,
          activeRoutingProfile: 'route_1',
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': params['active_profile'],
          'routing_profiles': params['profiles'],
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

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.ensureVisible(find.text('加入备用'));
    await tester.pump();
    // Stage the backup model in the fallback picker, then confirm.
    await tester.tap(find.text('backup-model').last);
    await tester.pump();
    await tester.ensureVisible(find.text('加入备用'));
    await tester.pump();
    await tester.tap(find.text('加入备用'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final profiles = savedRouting?['profiles'] as List?;
    final active = profiles?.cast<Map>().firstWhere(
      (item) => item['id'] == 'route_1',
    );
    expect(active?['fallback'], [
      {'provider': 'RealProvider', 'model': 'backup-model'},
    ]);
    expect(savedRouting?['active_profile'], 'route_1');
    expect(find.textContaining('已加入备用模型'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings removes fallback model', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(
          multiRoutingProfiles: true,
          activeRoutingProfile: 'route_1',
          withRoutingFallback: true,
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': params['active_profile'],
          'routing_profiles': params['profiles'],
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

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    final removeFallback = find.byTooltip('移除备用模型');
    await tester.ensureVisible(removeFallback);
    await tester.pump();
    await tester.tap(removeFallback);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final profiles = savedRouting?['profiles'] as List?;
    final active = profiles?.cast<Map>().firstWhere(
      (item) => item['id'] == 'route_1',
    );
    expect(active?['fallback'], isEmpty);
    expect(savedRouting?['active_profile'], 'route_1');
    expect(find.textContaining('已移除备用模型'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings moves fallback model', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') {
        return _desktopSnapshot(
          multiRoutingProfiles: true,
          activeRoutingProfile: 'route_1',
          withTwoRoutingFallbacks: true,
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': params['active_profile'],
          'routing_profiles': params['profiles'],
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

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    final moveDown = find.byTooltip('下移备用模型').first;
    await tester.ensureVisible(moveDown);
    await tester.pump();
    await tester.tap(moveDown);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final profiles = savedRouting?['profiles'] as List?;
    final active = profiles?.cast<Map>().firstWhere(
      (item) => item['id'] == 'route_1',
    );
    expect(active?['fallback'], [
      {'provider': 'RealProvider', 'model': 'third-model'},
      {'provider': 'RealProvider', 'model': 'backup-model'},
    ]);
    expect(calls, contains('provider.routing.save'));
    expect(calls, isNot(contains('provider.save')));
    expect(find.textContaining('备用模型顺序已更新'), findsOneWidget);
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
    expect(find.text('等待任务'), findsOneWidget);
    expect(find.text('任务 tvx_waiting_1'), findsOneWidget);
    expect(find.text('中断线索'), findsOneWidget);
    expect(find.text('任务 tvx_inte…pted_1'), findsOneWidget);
    expect(find.text('最新任务'), findsOneWidget);
    expect(find.textContaining('tvx_diag_context_active_123456'), findsNothing);
    expect(find.textContaining('RUNNING'), findsNothing);

    await tester.tap(find.text('任务 tvx_waiting_1'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(openedTools.single.type, AppWindowType.taskProcessing);
    expect(openedTools.single.taskId, 'tvx_waiting_1');

    expect(find.text('查看任务处理'), findsOneWidget);
    await tester.tap(find.text('查看任务处理'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(openedTools.length, 2);
    expect(openedTools.last.type, AppWindowType.taskProcessing);
    expect(openedTools.last.taskId, 'tvx_diag_context_active_123456');
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
    expect(find.text('导出复核'), findsOneWidget);
    expect(find.text('将导出 SRT · 双语字幕'), findsOneWidget);
    expect(find.text('已有输出 SRT review-source.zh-CN.srt'), findsOneWidget);
    expect(find.text('Good morning.'), findsOneWidget);
    expect(find.text('早上好。'), findsOneWidget);
    expect(find.text('Welcome back.'), findsOneWidget);
    expect(find.text('字幕阅读速度偏快'), findsOneWidget);

    final segmentSearch = find.widgetWithText(TextField, '搜索源文或译文');
    expect(segmentSearch, findsOneWidget);
    await tester.enterText(segmentSearch, 'welcome');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Good morning.'), findsNothing);
    expect(find.text('Welcome back.'), findsOneWidget);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Good morning.'), findsOneWidget);
    expect(find.text('Welcome back.'), findsOneWidget);

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

    await tester.tap(find.text('已修改'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('没有已修改片段。'), findsOneWidget);

    await tester.tap(find.text('全部'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(
      find.widgetWithText(TextField, '输入译文').last,
      '欢迎回来。',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('已修改'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Good morning.'), findsNothing);
    expect(find.text('Welcome back.'), findsOneWidget);
    expect(find.text('欢迎回来。'), findsOneWidget);
    expect(find.text('还原片段'), findsOneWidget);

    await tester.tap(find.text('还原片段'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('没有已修改片段。'), findsOneWidget);
    expect(find.text('已还原片段修改'), findsOneWidget);
    expect(find.text('欢迎回来。'), findsNothing);
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

    await tester.enterText(
      find.widgetWithText(TextField, '输入译文').first,
      '早上好，欢迎回来。',
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('有未保存修改'), findsOneWidget);

    await tester.tap(find.text('放弃修改'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已放弃未保存修改'), findsOneWidget);
    expect(find.text('早上好。'), findsOneWidget);
    expect(paramsByMethod.containsKey('result.segments.save'), isFalse);

    await tester.enterText(
      find.widgetWithText(TextField, '输入译文').first,
      '早上好，欢迎回来。',
    );
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
    expect(find.text('将导出 ASS · 单语字幕'), findsOneWidget);

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
    final eventParams = <Map<String, Object?>>[];
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
            runtime: {'state': 'terminal'},
            createdAt: '2026-07-06T08:00:00',
            updatedAt: '2026-07-06T09:30:00',
          ),
          _task(
            taskId: 'tvx_processing_failed_123456',
            status: 'FAILED',
            inputFile: r'D:\media\processing-failed.mp4',
            taskDir: r'D:\artifacts\tvx_processing_failed_123456',
            errorInfo: {
              'hint_zh': '可以继续任务。',
              'code': 'provider_connection_failed',
              'stage': 'TRANSLATE',
              'retryable': true,
            },
            runtime: {'can_resume': true, 'state': 'stale'},
            createdAt: '2026-07-05T08:00:00',
            updatedAt: '2026-07-05T08:30:00',
          ),
          _task(
            taskId: 'tvx_processing_running_123456',
            status: runningStatus,
            inputFile: r'D:\media\processing-running.mp4',
            taskDir: r'D:\artifacts\tvx_processing_running_123456',
            runtime: {'can_cancel': true, 'state': 'running'},
            createdAt: '2026-07-06T10:00:00',
            updatedAt: '2026-07-06T10:05:00',
          ),
        ];
      }
      if (method == 'tasks.events') {
        eventParams.add(Map<String, Object?>.from(params));
        final taskId = params['task_id'];
        final cursor = params['cursor'] as int? ?? 0;
        return {
          'task_id': taskId,
          'events': [
            {
              'type': 'stage',
              'stage': cursor == 0 ? 'EXPORT' : 'QUALITY',
              'message': cursor == 0
                  ? taskId == 'tvx_processing_done_123456'
                        ? 'done export'
                        : 'failed export'
                  : 'older event',
              'created_at': '2026-07-06T10:00:00Z',
            },
          ],
          'cursor': cursor,
          'next_cursor': cursor + 1,
          'has_more': taskId == 'tvx_processing_done_123456' && cursor == 0,
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
    expect(find.text('全部 3'), findsOneWidget);
    expect(find.text('字幕编辑'), findsOneWidget);
    expect(find.text('导出格式'), findsOneWidget);
    expect(calls, contains('result.open'));
    expect(opened, isEmpty);

    await tester.tap(find.text('返回概览'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('创建 2026-07-06 08:00:00'), findsOneWidget);
    expect(find.text('更新 2026-07-06 09:30:00'), findsOneWidget);
    expect(find.text('运行记录 已结束'), findsOneWidget);
    expect(find.text('操作 可编辑结果'), findsOneWidget);
    expect(find.text('阶段'), findsOneWidget);
    expect(find.text('加载更多事件'), findsOneWidget);
    await tester.tap(find.text('加载更多事件'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('阶段'), findsNWidgets(2));
    expect(find.text('older event'), findsOneWidget);
    expect(find.text('加载更多事件'), findsNothing);
    expect(eventParams, contains(containsPair('cursor', 1)));

    final eventSearch = find.widgetWithText(TextField, '搜索事件');
    expect(eventSearch, findsOneWidget);
    await tester.enterText(eventSearch, 'older');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('older event'), findsOneWidget);
    expect(find.text('正在写出字幕文件'), findsNothing);
    expect(find.text('阶段'), findsOneWidget);

    await tester.tap(find.byTooltip('清除事件搜索'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('older event'), findsOneWidget);
    expect(find.text('正在写出字幕文件'), findsOneWidget);
    expect(find.text('阶段'), findsNWidgets(2));

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

    final taskSearch = find.widgetWithText(TextField, '搜索任务');
    expect(taskSearch, findsOneWidget);
    await tester.enterText(taskSearch, 'failed');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('显示 1 / 3 个任务'), findsOneWidget);
    expect(find.text('全部 1'), findsOneWidget);
    expect(find.text('待处理 1'), findsOneWidget);
    expect(find.text('processing-failed.mp4'), findsWidgets);
    expect(find.text('processing-done.mp4'), findsNothing);
    expect(find.text('processing-running.mp4'), findsNothing);

    await tester.tap(find.byTooltip('清除任务搜索'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('最近 3 个任务'), findsOneWidget);
    expect(find.text('全部 3'), findsOneWidget);
    expect(find.text('processing-done.mp4'), findsOneWidget);
    expect(find.text('processing-failed.mp4'), findsWidgets);
    expect(find.text('processing-running.mp4'), findsOneWidget);

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
    expect(find.text('操作 可继续任务'), findsOneWidget);
    expect(find.text('失败线索'), findsOneWidget);
    expect(find.text('提示 可以继续任务。'), findsOneWidget);
    expect(find.text('错误码 provider_connection_failed'), findsOneWidget);
    expect(find.text('阶段 翻译字幕'), findsOneWidget);
    expect(find.text('重试性 可重试'), findsOneWidget);
    expect(find.text('运行状态 记录过期'), findsOneWidget);
    expect(find.text('恢复 可继续任务'), findsOneWidget);

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
    expect(find.text('运行记录 运行中'), findsOneWidget);
    expect(find.text('操作 可取消任务'), findsOneWidget);
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

void installFilePickerMock(
  WidgetTester tester, {
  String name = 'movie.mp4',
  String path = r'D:\movie.mp4',
}) {
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
        {'name': name, 'path': path, 'size': 1234},
      ];
    },
  );
}

Future<void> pickSourceAndStart(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('main-empty-pick-target')));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.text('开始译制'));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void activatePopupMenuItem(WidgetTester tester, Key key) {
  final state = tester.state<PopupMenuItemState<Object, PopupMenuItem<Object>>>(
    find.byKey(key),
  );
  // ignore: invalid_use_of_protected_member
  state.handleTap();
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
  bool multiRoutingProfiles = false,
  String activeRoutingProfile = '',
  bool withRoutingFallback = false,
  bool withTwoRoutingFallbacks = false,
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
      : [
          'real-model',
          if (multiRoutingProfiles) 'backup-model',
          if (withTwoRoutingFallbacks) 'third-model',
        ];
  final activeRouteId = activeRoutingProfile.isNotEmpty
      ? activeRoutingProfile
      : (multiRoutingProfiles ? 'route_1' : 'default');
  final routingProfiles = multiRoutingProfiles
      ? [
          {
            'id': 'route_1',
            'name': '配置 1',
            'primary': {'provider': 'RealProvider', 'model': 'real-model'},
            'fallback': withTwoRoutingFallbacks
                ? [
                    {'provider': 'RealProvider', 'model': 'backup-model'},
                    {'provider': 'RealProvider', 'model': 'third-model'},
                  ]
                : withRoutingFallback
                ? [
                    {'provider': 'RealProvider', 'model': 'backup-model'},
                  ]
                : const [],
          },
          {
            'id': 'route_2',
            'name': '配置 2',
            'primary': {'provider': 'RealProvider', 'model': 'backup-model'},
            'fallback': const [],
          },
        ]
      : [
          {
            'id': 'default',
            'name': 'Default',
            'primary': {'provider': 'RealProvider', 'model': models.first},
            'fallback': [
              {'provider': 'RealProvider', 'model': 'real-model'},
            ],
          },
        ];
  final activeProfile = routingProfiles.firstWhere(
    (profile) => profile['id'] == activeRouteId,
    orElse: () => routingProfiles.first,
  );
  final activePrimary = Map<String, Object?>.from(
    activeProfile['primary'] as Map,
  );
  return DesktopSnapshot.fromJson({
    'config': {
      'routing': {
        'active_profile': activeProfile['id'],
        'primary': activePrimary,
        'fallback': [
          {'provider': 'RealProvider', 'model': 'real-model'},
        ],
      },
      'active_routing_profile': activeProfile['id'],
      'routing_profiles': routingProfiles,
      'routing_profile_next_seq': multiRoutingProfiles ? 3 : 1,
      'pipeline': {'asr_provider': 'local'},
      'pipeline_file_version': {'mtime_ns': 1, 'size': 2},
      'providers_file_version': {'mtime_ns': 3, 'size': 4},
      'provider_presets': [
        {
          'id': 'deepseek',
          'label': 'DeepSeek',
          'api_type': 'openai-compatible',
          'compat_mode': 'openai_chat',
          'base_url': 'https://api.deepseek.com',
          'env_key': 'DEEPSEEK_API_KEY',
          'credential_id': 'deepseek',
          'models': ['deepseek-v4-pro'],
          'auth': {
            'type': 'bearer',
            'header_name': 'Authorization',
            'prefix': 'Bearer ',
          },
          'endpoint': {'path_template': '/chat/completions', 'method': 'POST'},
          'request_mapping': {'style': 'openai_chat'},
          'response_mapping': {
            'text_paths': ['choices[0].message.content'],
          },
          'model_list': {
            'path_template': '/models',
            'method': 'GET',
            'response_paths': ['data[].id'],
          },
        },
        {
          'id': 'openai_official',
          'label': 'OpenAI',
          'api_type': 'openai-compatible',
          'compat_mode': 'openai_responses',
          'base_url': 'https://api.openai.com/v1',
          'env_key': 'OPENAI_API_KEY',
          'credential_id': 'openai',
          'models': ['gpt-5.5'],
          'endpoint': {'path_template': '/responses', 'method': 'POST'},
          'request_mapping': {'style': 'openai_responses'},
          'response_mapping': {
            'text_paths': ['output_text'],
          },
          'model_list': {
            'path_template': '/models',
            'method': 'GET',
            'response_paths': ['data[].id'],
          },
        },
      ],
      'protocol_templates': [
        {
          'id': 'openai_chat',
          'label': 'OpenAI-compatible Chat',
          'api_type': 'openai-compatible',
          'compat_mode': 'openai_chat',
          'base_url': 'https://api.openai.com/v1',
          'models': ['custom-model'],
          'endpoint': {'path_template': '/chat/completions', 'method': 'POST'},
          'request_mapping': {'style': 'openai_chat'},
          'response_mapping': {
            'text_paths': ['choices[0].message.content'],
          },
          'model_list': {
            'path_template': '/models',
            'method': 'GET',
            'response_paths': ['data[].id'],
          },
        },
        {
          'id': 'anthropic_messages',
          'label': 'Anthropic Messages',
          'api_type': 'anthropic',
          'compat_mode': 'anthropic_messages',
          'base_url': 'https://api.anthropic.com/v1',
          'models': ['claude-sonnet'],
          'endpoint': {'path_template': '/messages', 'method': 'POST'},
          'request_mapping': {'style': 'anthropic_messages'},
          'response_mapping': {
            'text_paths': ['content[].text'],
          },
          'model_list': {
            'path_template': '/models',
            'method': 'GET',
            'response_paths': ['data[].id'],
          },
        },
      ],
      'custom_adapter_template': {
        'id': 'custom_json',
        'label': 'Custom JSON',
        'api_type': 'custom',
        'compat_mode': 'custom_json',
        'base_url': 'https://example.com',
        'models': ['custom-model'],
        'endpoint': {'path_template': '/', 'method': 'POST'},
        'request_mapping': {
          'style': 'custom_json',
          'body_template': {'model': '{{model}}', 'prompt': '{{prompt}}'},
        },
        'response_mapping': {
          'text_paths': ['text'],
        },
        'model_list': {
          'path_template': '',
          'method': 'GET',
          'response_paths': [],
        },
      },
      'providers': withProviders
          ? [
              {
                'name': 'RealProvider',
                'has_key': true,
                'base_url': 'https://example.com/v1',
                'env_key': 'REAL_PROVIDER_KEY',
                'api_type': 'openai-compatible',
                'compat_mode': 'openai_chat',
                'credential_id': 'RealProvider',
                'credential_source': 'auth_json',
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
  String? createdAt,
  String? updatedAt,
  Map<String, String> outputPaths = const {},
  Map<String, Object?> errorInfo = const {},
  Map<String, Object?> runtime = const {},
  String? inputType,
}) {
  return {
    'task_id': taskId ?? 'tvx_widget_$status',
    'status': status,
    'input_file': inputFile,
    'input_type': ?inputType,
    'task_dir': ?taskDir,
    'source_lang': 'en',
    'target_lang': 'zh-CN',
    'bilingual': true,
    'progress': ?progress,
    'checkpoint_status': ?checkpointStatus,
    'created_at': ?createdAt,
    'updated_at': ?updatedAt,
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
