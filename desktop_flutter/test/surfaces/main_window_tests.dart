import 'dart:ui' show PointerDeviceKind;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transvortex_desktop_flutter/main.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/current_window_controls.dart';
import 'package:transvortex_desktop_flutter/theme/tokens.dart';
import 'package:transvortex_desktop_flutter/widgets/designed_tooltip.dart';
import 'package:transvortex_desktop_flutter/widgets/job_line.dart';
import '../support/widget_test_support.dart';

void main() {
  testWidgets('app uses packaged CJK font family', (tester) async {
    await tester.pumpWidget(
      TransVortexApp(localServiceController: readyController()),
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
      TransVortexApp(localServiceController: readyController()),
    );
    // 呼吸动画在 repeat，不能 pumpAndSettle；推进一帧即可。
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('把音频、视频或字幕放进来吧'), findsOneWidget);
    expect(find.text('选择片源'), findsOneWidget);
    expect(find.text('新任务会按'), findsOneWidget);
    expect(find.text('自动生成术语建议'), findsOneWidget);
    expect(find.text('字幕，并'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('main-empty-pick-target')),
      findsOneWidget,
    );
    expect(find.textContaining('也可以点击选择'), findsNothing);
    expect(find.textContaining('支持视频'), findsNothing);
    expect(find.text('TransVortex'), findsOneWidget);
    expect(find.textContaining('调试态'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('main menu exposes product tools without diagnostics', (
    tester,
  ) async {
    await tester.pumpWidget(
      TransVortexApp(localServiceController: readyController()),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const ValueKey('main-menu-button')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('翻译模型设置'), findsOneWidget);
    expect(find.text('语音识别设置'), findsOneWidget);
    expect(find.text('任务处理'), findsOneWidget);
    expect(find.text('应用设置'), findsOneWidget);
    expect(find.text('全部设置'), findsNothing);
    expect(find.text('任务资料库位置'), findsNothing);
    expect(find.text('诊断'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets(
    'main expands once for application settings and keeps task surface fixed',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var panelMountedDuringNativeCollapse = false;
      final surface = FakeMainWindowSurfaceController(
        bounds: const Rect.fromLTWH(600, 280, 720, 520),
        visibleBounds: const Rect.fromLTWH(0, 0, 1920, 1080),
        onSetBounds: (bounds) {
          if (bounds.width == mainWindowSize.width) {
            panelMountedDuringNativeCollapse = find
                .byKey(const ValueKey('application-settings-panel'))
                .evaluate()
                .isNotEmpty;
          }
        },
      );
      final service = readyController(
        snapshot: desktopSnapshotFixture(
          managedAsr: true,
          localModel: 'small',
          asrLocal: managedAsrResources(),
        ),
      );
      addTearDown(service.dispose);

      await tester.pumpWidget(
        TransVortexApp(
          localServiceController: service,
          mainWindowSurfaceController: surface,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        tester.getSize(find.byKey(const ValueKey('main-workspace'))),
        mainWindowSize,
      );
      await tester.tap(find.byKey(const ValueKey('main-menu-button')));
      await tester.pump();
      activatePopupMenuItem(
        tester,
        const ValueKey('main-menu-application_settings'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(surface.writes, [const Rect.fromLTWH(600, 280, 1200, 520)]);
      expect(
        tester.getSize(find.byKey(const ValueKey('main-workspace'))),
        mainWindowSize,
      );
      expect(
        find.byKey(const ValueKey('application-settings-panel')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('application-settings-transition')),
            )
            .opacity,
        1,
      );
      expect(find.text('应用设置'), findsOneWidget);
      expect(find.text('翻译模型设置'), findsNothing);
      expect(find.text('语音识别设置'), findsNothing);
      expect(
        tester.getCenter(find.byKey(const ValueKey('main-menu-button'))).dx,
        lessThan(mainWindowSize.width),
      );
      expect(
        tester
            .getCenter(find.byKey(const ValueKey('application-settings-close')))
            .dx,
        greaterThan(mainWindowSize.width),
      );

      await tester.tap(find.byKey(const ValueKey('main-menu-button')));
      await tester.pump();
      expect(
        tester
            .getCenter(find.byKey(const ValueKey('main-menu-translation')))
            .dx,
        lessThan(mainWindowSize.width),
      );
      await tester.tapAt(const Offset(24, 120));
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('application-settings-close')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(surface.writes, [
        const Rect.fromLTWH(600, 280, 1200, 520),
        const Rect.fromLTWH(600, 280, 720, 520),
      ]);
      expect(panelMountedDuringNativeCollapse, isTrue);
      expect(
        find.byKey(const ValueKey('application-settings-panel')),
        findsNothing,
      );
      expectNoFlutterException();
    },
  );

  testWidgets(
    'application settings use an overlay without widening narrow windows',
    (tester) async {
      await tester.binding.setSurfaceSize(mainWindowSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final surface = FakeMainWindowSurfaceController(
        bounds: const Rect.fromLTWH(152, 100, 720, 520),
        visibleBounds: const Rect.fromLTWH(0, 0, 1024, 768),
      );
      final service = readyController();
      addTearDown(service.dispose);

      await tester.pumpWidget(
        TransVortexApp(
          localServiceController: service,
          mainWindowSurfaceController: surface,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('main-menu-button')));
      await tester.pump();
      activatePopupMenuItem(
        tester,
        const ValueKey('main-menu-application_settings'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pump();

      expect(surface.writes, isEmpty);
      expect(
        find.byKey(const ValueKey('main-with-settings-overlay')),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('main-workspace'))),
        mainWindowSize,
      );
      expect(
        find.byKey(const ValueKey('application-settings-panel')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('application-settings-close')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      await tester.pump();

      expect(surface.writes, isEmpty);
      expect(
        find.byKey(const ValueKey('application-settings-panel')),
        findsNothing,
      );
      expectNoFlutterException();
    },
  );

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
      TransVortexApp(localServiceController: readyController()),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('选择片源'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('picked-video.mp4'), findsOneWidget);
    expect(find.text('字幕，并'), findsOneWidget);
    final termsToggle = find.text('自动生成术语建议');
    expect(termsToggle, findsOneWidget);
    final enabledTooltips = tester
        .widgetList<DesignedTooltip>(find.byType(DesignedTooltip))
        .map((tooltip) => tooltip.message)
        .whereType<String>()
        .toList();
    expect(enabledTooltips, contains('本次制作允许系统生成术语建议。不会改动或关闭已有人工术语。'));

    await tester.tap(termsToggle);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('不生成术语建议'), findsOneWidget);
    final disabledTooltips = tester
        .widgetList<DesignedTooltip>(find.byType(DesignedTooltip))
        .map((tooltip) => tooltip.message)
        .whereType<String>()
        .toList();
    expect(disabledTooltips, contains('本次不生成新的术语建议。已有人工术语是否使用不受这个开关影响。'));
    expect(find.text('开始译制'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('main SRT draft skips speech recognition setup', (tester) async {
    installFilePickerMock(
      tester,
      name: 'source-subtitle.srt',
      path: r'D:\media\source-subtitle.srt',
    );
    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: readyController(
          snapshot: desktopSnapshotFixture(withAsrProviders: false),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('选择片源'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('source-subtitle.srt'), findsOneWidget);
    expect(find.text('源语，直接交给'), findsOneWidget);
    expect(find.text('先配置识别'), findsNothing);
    expect(find.text('开始译制'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('main keeps an unavailable current ASR provider visible', (
    tester,
  ) async {
    installFilePickerMock(tester);
    final openAiProvider = <String, Object?>{
      'name': 'openai_whisper',
      'kind': 'remote',
      'protocol': 'openai_transcriptions',
      'model': 'whisper-1',
      'has_key': false,
      'readiness': {
        'state': 'needs_action',
        'code': 'credential_missing',
        'can_run': false,
        'primary_action': 'set_credential',
      },
    };
    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: readyController(
          snapshot: desktopSnapshotFixture(
            activeAsrProvider: 'openai_whisper',
            additionalAsrProviders: {'openai_whisper': openAiProvider},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('选择片源'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final jobLine = tester.widget<JobLine>(find.byType(JobLine));
    expect(jobLine.view.requiresAsr, isTrue);
    expect(jobLine.view.asrLabel, 'OpenAI Whisper · whisper-1');
    expect(jobLine.view.asrDetail, '未配置 API key');
    final unavailableAsr = find.textContaining(
      'OpenAI Whisper · whisper-1（需配置）',
    );
    expect(unavailableAsr, findsOneWidget);
    await tester.tap(unavailableAsr);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('OpenAI Whisper · whisper-1'), findsOneWidget);
    expect(find.text('未配置 API key'), findsOneWidget);
    expect(find.text('去语音识别设置'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('main translation menu submits profile routing snapshot', (
    tester,
  ) async {
    installFilePickerMock(tester);
    final transport = FakeAppServiceTransport({
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
      'desktop.snapshot': desktopSnapshotFixture(
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
      TransVortexApp(localServiceController: controllerForTransport(transport)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('main-empty-pick-target')));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('real-model'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('本次思考程度'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('translation-reasoning-effort')),
      findsOneWidget,
    );
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

  testWidgets('main shows and submits the current reasoning value', (
    tester,
  ) async {
    installFilePickerMock(tester);
    final transport = FakeAppServiceTransport({
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
      'desktop.snapshot': desktopSnapshotFixture(
        primaryReasoningEffort: 'high',
      ).raw,
      'runtime.submitRun': {
        'ok': true,
        'task_id': 'tvx_reasoning_effort',
        'status': 'QUEUED',
      },
      'tasks.events': {
        'task_id': 'tvx_reasoning_effort',
        'events': [],
        'cursor': 0,
        'next_cursor': 0,
        'has_more': false,
      },
    });

    await tester.pumpWidget(
      TransVortexApp(localServiceController: controllerForTransport(transport)),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('job-reasoning-effort')), findsOneWidget);
    expect(find.text('高'), findsOneWidget);
    expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
    expect(find.text('，思考程度'), findsNothing);
    await tester.tap(find.byIcon(Icons.bolt_rounded));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const ValueKey('reasoning-effort-picker')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reasoning-effort-slider')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reasoning-reset-default')),
      findsOneWidget,
    );
    expect(find.text('高'), findsWidgets);
    await tester.tapAt(const Offset(8, 120));
    await tester.pump(const Duration(milliseconds: 200));

    await pickSourceAndStart(tester);
    final submitParams = transport.lastParams['runtime.submitRun'];
    final request = submitParams?['request'] as Map<String, Object?>?;
    final routing = request?['routing'] as Map<String, Object?>?;
    final primary = routing?['primary'] as Map<String, Object?>?;
    expect(primary?['reasoning_effort'], 'high');
    expectNoFlutterException();
  });

  testWidgets('main language menus update submitted language pair', (
    tester,
  ) async {
    installFilePickerMock(tester);
    final transport = FakeAppServiceTransport({
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
      'desktop.snapshot': desktopSnapshotFixture().raw,
      'runtime.submitRun': {
        'ok': true,
        'task_id': 'tvx_language_pair',
        'status': 'QUEUED',
      },
      'tasks.events': {
        'task_id': 'tvx_language_pair',
        'events': [],
        'cursor': 0,
        'next_cursor': 0,
        'has_more': false,
      },
    });

    await tester.pumpWidget(
      TransVortexApp(localServiceController: controllerForTransport(transport)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('main-empty-pick-target')));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('自动识别'), findsOneWidget);
    expect(find.text('简体中文'), findsOneWidget);

    await tester.tap(find.text('自动识别'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('源语言'), findsOneWidget);
    expect(find.textContaining('判断原始语言'), findsOneWidget);
    expect(find.text('常用语言'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('source-language-ja')));
    await tester.pump(const Duration(milliseconds: 100));

    final targetLanguageTrigger = find.text('简体中文');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(targetLanguageTrigger));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('目标语：简体中文'), findsOneWidget);

    await tester.tap(targetLanguageTrigger);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('目标语：简体中文'), findsNothing);
    expect(find.text('目标语言'), findsOneWidget);
    expect(find.byKey(const ValueKey('target-language-auto')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('target-language-en')));
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.removePointer();

    await tester.tap(find.text('开始译制'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final submitParams = transport.lastParams['runtime.submitRun'];
    final request = submitParams?['request'] as Map<String, Object?>?;
    expect(request?['source_lang'], 'ja');
    expect(request?['target_lang'], 'en');
    expectNoFlutterException();
  });

  testWidgets('main translation menu direct model has no fallback', (
    tester,
  ) async {
    installFilePickerMock(tester);
    final transport = FakeAppServiceTransport({
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
      'desktop.snapshot': desktopSnapshotFixture(
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
      TransVortexApp(localServiceController: controllerForTransport(transport)),
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
      TransVortexApp(localServiceController: readyController()),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('TransVortex'), findsOneWidget);
    expect(find.textContaining('服务已连接'), findsNothing);
    expect(find.textContaining('等待片源'), findsNothing);
    expect(find.text('把音频、视频或字幕放进来吧'), findsOneWidget);
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
    final transport = FakeAppServiceTransport({
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
      'desktop.snapshot': desktopSnapshotFixture().raw,
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
      TransVortexApp(localServiceController: controllerForTransport(transport)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await pickSourceAndStart(tester);

    expect(find.text('翻译字幕'), findsOneWidget);
    expect(find.text('按分片翻译对白'), findsOneWidget);
    expect(find.textContaining('ridiculously-long-tail'), findsOneWidget);
    expect(find.text('取消任务'), findsOneWidget);
    expect(find.text('自动生成术语建议'), findsNothing);
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
    final transport = FakeAppServiceTransport(
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
        'desktop.snapshot': desktopSnapshotFixture().raw,
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
      TransVortexApp(localServiceController: controllerForTransport(transport)),
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
    final notifications = RecordingTaskNotificationService();
    final transport = FakeAppServiceTransport({
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
      'desktop.snapshot': desktopSnapshotFixture().raw,
      'runtime.submitRun': {
        'ok': true,
        'task_id': 'tvx_widgettaskPayload',
        'status': 'QUEUED',
      },
      'tasks.events': {
        'task_id': 'tvx_widgettaskPayload',
        'events': [],
        'cursor': 0,
        'next_cursor': 0,
        'has_more': false,
      },
    });
    final controller = controllerForTransport(transport);

    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: controller,
        taskNotificationService: notifications,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await pickSourceAndStart(tester);

    transport.results['desktop.snapshot'] = desktopSnapshotFixture(
      tasks: [
        taskPayload(
          taskId: 'tvx_widgettaskPayload',
          status: 'DONE',
          inputFile: r'D:\movie.mp4',
        ),
      ],
    ).raw;
    await controller.refresh();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('审看结果'), findsOneWidget);
    expect(find.text('制作新片源'), findsOneWidget);
    expect(find.text('自动生成术语建议'), findsNothing);
    expect(notifications.completed, ['movie.mp4']);
    expect(notifications.failed, isEmpty);
    expectNoFlutterException();
  });

  testWidgets('main screen notifies when a running task fails', (tester) async {
    installFilePickerMock(tester);
    final notifications = RecordingTaskNotificationService();
    final transport = FakeAppServiceTransport({
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
      'desktop.snapshot': desktopSnapshotFixture().raw,
      'runtime.submitRun': {
        'ok': true,
        'task_id': 'tvx_widgettaskPayload',
        'status': 'QUEUED',
      },
      'tasks.events': {
        'task_id': 'tvx_widgettaskPayload',
        'events': [],
        'cursor': 0,
        'next_cursor': 0,
        'has_more': false,
      },
    });
    final controller = controllerForTransport(transport);

    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: controller,
        taskNotificationService: notifications,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await pickSourceAndStart(tester);

    transport.results['desktop.snapshot'] = desktopSnapshotFixture(
      tasks: [
        taskPayload(
          taskId: 'tvx_widgettaskPayload',
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
    final transport = FakeAppServiceTransport(
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
        'desktop.snapshot': desktopSnapshotFixture().raw,
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
      TransVortexApp(localServiceController: controllerForTransport(transport)),
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
    final transport = FakeAppServiceTransport({
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
      'desktop.snapshot': desktopSnapshotFixture(
        tasks: [
          taskPayload(
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
      TransVortexApp(localServiceController: controllerForTransport(transport)),
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
    expect(request, {'request_version': 1, 'task_id': 'tvx_resumable_failed'});
    expectNoFlutterException();
  });

  testWidgets('main home reminder can be dismissed without blocking new work', (
    tester,
  ) async {
    await tester.pumpWidget(
      TransVortexApp(
        localServiceController: readyController(
          snapshot: desktopSnapshotFixture(
            tasks: [
              taskPayload(
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
    final transport = FakeAppServiceTransport({
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
      'desktop.snapshot': desktopSnapshotFixture().raw,
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

    final controller = controllerForTransport(transport);

    await tester.pumpWidget(TransVortexApp(localServiceController: controller));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await pickSourceAndStart(tester);
    transport.results['desktop.snapshot'] = desktopSnapshotFixture(
      tasks: [
        taskPayload(
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
      final initialSnapshot = desktopSnapshotFixture(
        tasks: [
          taskPayload(
            taskId: 'tvx_reexport_output_failed',
            status: 'DONE',
            inputFile: r'D:\movie.mp4',
            outputPaths: {'srt': r'D:\movie.zh-CN.srt'},
          ),
        ],
      ).raw;
      final recoveredSnapshot = desktopSnapshotFixture(
        tasks: [
          taskPayload(
            taskId: 'tvx_reexport_output_failed',
            status: 'DONE',
            inputFile: r'D:\movie.mp4',
            outputPaths: {'srt': r'E:\fixed-output\movie.zh-CN.srt'},
          ),
        ],
      ).raw;
      final transport = FakeAppServiceTransport(
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
          'desktop.snapshot': desktopSnapshotFixture().raw,
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
      final controller = controllerForTransport(transport);

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
}
