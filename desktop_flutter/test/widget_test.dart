import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transvortex_desktop_flutter/main.dart';
import 'package:transvortex_desktop_flutter/model/startup_args.dart';
import 'package:transvortex_desktop_flutter/model/window_state.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/current_window_controls.dart';
import 'package:transvortex_desktop_flutter/widgets/title_bar.dart';

import 'surfaces/application_settings_tests.dart' as application_settings_tests;
import 'surfaces/asr_settings_window_tests.dart' as asr_settings_window_tests;
import 'surfaces/diagnostics_window_tests.dart' as diagnostics_window_tests;
import 'surfaces/main_window_tests.dart' as main_window_tests;
import 'surfaces/result_review_workspace_tests.dart'
    as result_review_workspace_tests;
import 'surfaces/task_processing_window_tests.dart'
    as task_processing_window_tests;
import 'surfaces/translation_settings_window_tests.dart'
    as translation_settings_window_tests;

void main() {
  testWidgets('fixed title bars ignore double-click maximize', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TitleBar())),
    );

    final fixedDrag = tester.widget<GestureDetector>(
      find.descendant(
        of: find.byType(WindowDragArea),
        matching: find.byType(GestureDetector),
      ),
    );
    expect(fixedDrag.onDoubleTap, isNull);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TitleBar(canMaximize: true))),
    );
    final maximizableDrag = tester.widget<GestureDetector>(
      find.descendant(
        of: find.byType(WindowDragArea),
        matching: find.byType(GestureDetector),
      ),
    );
    expect(maximizableDrag.onDoubleTap, isNotNull);
  });

  test('tray reports the active ASR setup phase', () {
    final model = AsrOperationStatus.fromJson({
      'id': 'asr_setup',
      'kind': 'setup',
      'item_id': 'small',
      'state': 'running',
      'phase': 'model',
    });
    final cancelling = AsrOperationStatus.fromJson({
      'id': 'asr_setup',
      'kind': 'setup',
      'item_id': 'small',
      'state': 'cancelling',
      'phase': 'model',
    });

    expect(asrTrayStatusLabel(model), '正在下载 Whisper Small');
    expect(asrTrayStatusLabel(cancelling), '正在取消识别环境下载');
  });

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
      '{"type":"main","smoke":{"reportPath":"D:/tmp/report.json","serviceRoot":"D:/tmp/root","timeoutSeconds":3,"inputPath":"D:/tmp/demo.mkv","expectedOutputText":"Hello","screenshotPath":"D:/tmp/smoke.png","minVisibleSeconds":2,"postReportVisibleSeconds":3,"useControllerSubmission":true,"checkNotifications":true,"checkTray":true,"mainPhase":"blockedTranslation"}}',
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
    expect(startup.smoke?.checkTray, isTrue);
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
      '--tvx-smoke-check-tray=true',
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
    expect(flagStartup.smoke?.checkTray, isTrue);
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

  main_window_tests.main();
  application_settings_tests.main();
  translation_settings_window_tests.main();
  asr_settings_window_tests.main();
  diagnostics_window_tests.main();
  result_review_workspace_tests.main();
  task_processing_window_tests.main();
}
