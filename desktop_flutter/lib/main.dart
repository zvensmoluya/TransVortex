import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'model/main_window_controller.dart';
import 'model/session.dart';
import 'model/startup_args.dart';
import 'model/task_labels.dart';
import 'model/window_state.dart';
import 'painters/source_object_painter.dart';
import 'services/app_service_client.dart';
import 'services/directory_probe.dart';
import 'services/current_window_controls.dart';
import 'services/local_service_controller.dart';
import 'services/path_opener.dart';
import 'services/smoke_render_capture.dart';
import 'services/task_notification_service.dart';
import 'services/window_state_bridge.dart';
import 'theme/tokens.dart';
import 'widgets/job_line.dart';
import 'widgets/primary_action.dart';
import 'widgets/designed_tooltip.dart';
import 'widgets/settings_window.dart';
import 'widgets/task_processing_window.dart';
import 'widgets/title_bar.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await _currentWindowController();
  final startupArgs = AppStartupArgs.fromSources(controller?.arguments, args);
  final parsedArgs = startupArgs.window;
  final store = WindowStateStore();
  final bridge = parsedArgs.type == AppWindowType.main
      ? WindowStateBridge.main(store)
      : WindowStateBridge.child(store);
  if (parsedArgs.type == AppWindowType.main) {
    await bridge.initializeMain();
  }
  await configureCurrentWindow(parsedArgs);
  await registerCurrentWindowControls();

  runApp(
    TransVortexApp(
      windowType: parsedArgs.type,
      taskId: parsedArgs.taskId,
      store: store,
      bridge: bridge,
      smoke: startupArgs.smoke,
    ),
  );
  unawaited(_showConfiguredWindowAfterFirstRaster());
}

Future<WindowController?> _currentWindowController() async {
  try {
    return await WindowController.fromCurrentEngine();
  } on Object {
    return null;
  }
}

Future<void> _showConfiguredWindowAfterFirstRaster() async {
  try {
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized.timeout(
      const Duration(seconds: 10),
    );
  } on TimeoutException {
    // Do not leave a window hidden forever if a host cannot report rasterization.
  } on Object {
    // Unsupported test hosts still need the normal best-effort show path below.
  }
  await showConfiguredWindow();
}

const List<String> _sourceLanguageOptions = [
  'auto',
  'ja',
  'en',
  'zh-CN',
  'zh-TW',
  'ko',
  'fr',
  'de',
  'es',
];

const List<String> _targetLanguageOptions = [
  'zh-CN',
  'zh-TW',
  'en',
  'ja',
  'ko',
  'fr',
  'de',
  'es',
];

class TransVortexApp extends StatelessWidget {
  const TransVortexApp({
    super.key,
    this.windowType = AppWindowType.main,
    this.taskId,
    this.store,
    this.bridge,
    this.localServiceController,
    this.taskNotificationService,
    this.pathOpener,
    this.directoryProbe,
    this.smoke,
  });

  final AppWindowType windowType;
  final String? taskId;
  final WindowStateStore? store;
  final WindowStateBridge? bridge;
  final LocalServiceController? localServiceController;
  final TaskNotificationService? taskNotificationService;
  final PathOpener? pathOpener;
  final DirectoryWriteProbe? directoryProbe;
  final AppSmokeArgs? smoke;

  @override
  Widget build(BuildContext context) {
    final appStore = store ?? WindowStateStore();
    final appBridge =
        bridge ??
        (windowType == AppWindowType.main
            ? WindowStateBridge.main(appStore)
            : WindowStateBridge.child(appStore));
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: windowType.title,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: T.fontFamily,
        scaffoldBackgroundColor: T.bg,
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(color: T.line, width: 1),
          ),
          textStyle: T.tCaption.copyWith(color: T.ink, height: 1.25),
          padding: const EdgeInsets.symmetric(
            horizontal: T.s12,
            vertical: T.s8,
          ),
          margin: const EdgeInsets.all(T.s12),
          waitDuration: const Duration(milliseconds: 450),
          showDuration: const Duration(seconds: 3),
        ),
        colorScheme: ColorScheme.fromSeed(
          seedColor: T.accent,
          brightness: Brightness.light,
        ),
      ),
      home: switch (windowType) {
        AppWindowType.main => MainScreen(
          store: appStore,
          bridge: appBridge,
          localServiceController: localServiceController,
          taskNotificationService: taskNotificationService,
          smoke: smoke,
        ),
        AppWindowType.taskProcessing => TaskProcessingWindow(
          taskId: taskId,
          bridge: appBridge,
          pathOpener: pathOpener,
          directoryProbe: directoryProbe,
          smoke: smoke,
        ),
        _ => SettingsWindow(
          type: windowType,
          store: appStore,
          bridge: appBridge,
          localServiceController: localServiceController,
          pathOpener: pathOpener,
          directoryProbe: directoryProbe,
          smoke: smoke,
        ),
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    required this.store,
    required this.bridge,
    this.localServiceController,
    this.taskNotificationService,
    this.smoke,
  });

  final WindowStateStore store;
  final WindowStateBridge bridge;
  final LocalServiceController? localServiceController;
  final TaskNotificationService? taskNotificationService;
  final AppSmokeArgs? smoke;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  late final LocalServiceController _service;
  late final bool _ownsService;
  late final MainWindowController _controller;
  SmokeWindowsNotificationSink? _smokeNotificationSink;
  late final TaskNotificationObserver _notificationObserver;
  final GlobalKey _renderKey = GlobalKey(debugLabel: 'main-smoke-render');
  final Map<String, WindowController> _toolWindows = {};
  bool _dropTargetHover = false;
  bool _dropTargetDown = false;

  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  late final AnimationController _drag = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );

  @override
  void initState() {
    super.initState();
    _service =
        widget.localServiceController ??
        LocalServiceController(supervisor: _localServiceSupervisor());
    _ownsService = widget.localServiceController == null;
    _notificationObserver = TaskNotificationObserver(_notificationService());
    _controller = MainWindowController(service: _service)
      ..addListener(_syncBridgeState);
    widget.bridge.attachServiceCaller((method, params) async {
      await _service.start();
      final client = _service.client;
      if (client == null) throw StateError('本地服务未连接');
      return client.call(method, params);
    });
    widget.bridge.attachToolWindowOpener(_openToolWindowFromArgs);
    widget.bridge.attachServiceRefresher(_controller.refreshSnapshot);
    unawaited(_controller.startService());
    final smoke = widget.smoke;
    if (smoke != null) {
      unawaited(_runStartupSmoke(smoke));
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_syncBridgeState);
    _controller.dispose();
    if (_ownsService) _service.dispose();
    _breathe.dispose();
    _drag.dispose();
    super.dispose();
  }

  void _syncBridgeState() {
    final view = _controller.view;
    _notificationObserver.handle(view);
    widget.store.replace(
      widget.store.value.copyWith(
        translationDefaultLabel: view.translationLabel,
        translationConfigured: view.translationConfigured,
        asrDefaultLabel: view.asrLabel,
        asrConfigured: view.asrConfigured,
      ),
    );
  }

  TaskNotificationService _defaultNotificationService() {
    return WindowsTaskNotificationService(
      onActivated: (_) => _focusMainWindow(),
      shouldNotify: (_) async {
        try {
          return !await windowManager.isFocused();
        } on Object {
          return true;
        }
      },
    );
  }

  TaskNotificationService _notificationService() {
    final injected = widget.taskNotificationService;
    if (injected != null) return injected;
    if (widget.smoke?.checkNotifications == true) {
      final sink = SmokeWindowsNotificationSink();
      _smokeNotificationSink = sink;
      return WindowsTaskNotificationService(
        sink: sink,
        shouldNotify: (_) => true,
        onActivated: (_) => _focusMainWindow(),
      );
    }
    return _defaultNotificationService();
  }

  LocalServiceSupervisor _localServiceSupervisor() {
    final serviceRoot = widget.smoke?.serviceRoot;
    if (serviceRoot == null || serviceRoot.isEmpty) {
      return LocalServiceSupervisor();
    }
    return LocalServiceSupervisor(serviceRoot: Directory(serviceRoot));
  }

  Future<void> _runStartupSmoke(AppSmokeArgs smoke) async {
    final startedAt = DateTime.now().toUtc();
    final deadline = startedAt.add(smoke.timeout);
    final reportFile = File(smoke.reportPath);
    await reportFile.parent.create(recursive: true);
    try {
      await _controller.startService().timeout(smoke.timeout);
      if (smoke.mainPhase != SmokeMainPhase.normal) {
        await _applyMainPhaseSmoke(smoke);
        final payload = <String, Object?>{
          'ok': true,
          'status': _service.snapshot.status.name,
          'service': _service.snapshot.info?.service ?? '',
          'app_version': _service.snapshot.info?.appVersion ?? '',
          'window_type': 'main',
          'main_phase': smoke.mainPhase.id,
          'controller_state': _controller.view.state.name,
          'translation_label': _controller.view.translationLabel,
          'asr_label': _controller.view.asrLabel,
          'started_at': startedAt.toIso8601String(),
          'finished_at': DateTime.now().toUtc().toIso8601String(),
          'last_error': _service.snapshot.lastError ?? '',
        };
        payload.addAll(
          await captureSmokeRender(
            boundaryKey: _renderKey,
            path: smoke.screenshotPath,
          ),
        );
        if (smoke.screenshotPath != null) {
          payload['ok'] =
              payload['ok'] == true && payload['render_capture_ok'] == true;
        }
        await _waitForMinimumVisibleDuration(smoke, startedAt, deadline);
        await _writeSmokeReportAndHold(reportFile, payload, smoke);
        return;
      }
      final taskReport = smoke.inputPath == null
          ? const <String, Object?>{}
          : await _runSmokeTask(smoke, deadline);
      String refreshError = '';
      try {
        await _service.refresh().timeout(_remaining(deadline));
      } on Object catch (error) {
        refreshError = '$error';
      }
      final snapshot = _service.snapshot;
      final desktop = snapshot.desktopSnapshot;
      final outputOk = taskReport['task_output_ok'];
      final doneEvent = taskReport['task_done_event'];
      final terminalEvidence = taskReport['task_terminal_evidence'];
      final reexportOk = taskReport['reexport_ok'];
      final taskDone =
          taskReport['task_status'] == 'DONE' ||
          taskReport['controller_state'] == 'completed';
      final taskOk = smoke.inputPath == null
          ? true
          : taskDone &&
                outputOk == true &&
                (doneEvent == true || terminalEvidence == 'controller_view') &&
                (!smoke.useControllerSubmission || reexportOk == true);
      final payload = <String, Object?>{
        'ok':
            (snapshot.status == LocalServiceConnectionStatus.ready ||
                snapshot.status == LocalServiceConnectionStatus.degraded) &&
            taskOk,
        'status': snapshot.status.name,
        'service': snapshot.info?.service ?? '',
        'app_version': snapshot.info?.appVersion ?? '',
        'translation_label': desktop?.configReadiness.translationLabel ?? '',
        'asr_label': desktop?.configReadiness.asrLabel ?? '',
        'task_count': desktop?.tasks.length ?? 0,
        ...taskReport,
        'started_at': startedAt.toIso8601String(),
        'finished_at': DateTime.now().toUtc().toIso8601String(),
        'last_error': snapshot.lastError ?? '',
        'refresh_error': refreshError,
      };
      if (smoke.checkNotifications) {
        await _waitForSmokeNotification(deadline);
        payload.addAll(_smokeNotificationReport());
        payload['ok'] =
            payload['ok'] == true && payload['notification_check_ok'] == true;
      }
      payload.addAll(
        await captureSmokeRender(
          boundaryKey: _renderKey,
          path: smoke.screenshotPath,
        ),
      );
      if (smoke.screenshotPath != null) {
        payload['ok'] =
            payload['ok'] == true && payload['render_capture_ok'] == true;
      }
      await _waitForMinimumVisibleDuration(smoke, startedAt, deadline);
      await _writeSmokeReportAndHold(reportFile, payload, smoke);
    } on Object catch (error) {
      final payload = <String, Object?>{
        'ok': false,
        'status': 'error',
        'error': '$error',
        'started_at': startedAt.toIso8601String(),
        'finished_at': DateTime.now().toUtc().toIso8601String(),
      };
      await _writeSmokeReportAndHold(reportFile, payload, smoke);
    } finally {
      try {
        await _service.shutdown();
      } on Object {
        // Smoke shutdown is best effort; the report above is authoritative.
      }
      try {
        await windowManager.close();
      } on Object {
        exit(0);
      }
    }
  }

  Future<void> _applyMainPhaseSmoke(AppSmokeArgs smoke) async {
    switch (smoke.mainPhase) {
      case SmokeMainPhase.normal:
        return;
      case SmokeMainPhase.empty:
        _controller.removeSource();
        return;
      case SmokeMainPhase.ready:
        _controller.pickSource(
          r'D:\Media\sample-opening-line.wav',
          name: 'sample-opening-line.wav',
        );
        return;
      case SmokeMainPhase.blockedTranslation:
        _controller.pickSource(
          r'D:\Media\sample-opening-line.srt',
          name: 'sample-opening-line.srt',
        );
        return;
      case SmokeMainPhase.blockedAsr:
        _controller.pickSource(
          r'D:\Media\sample-opening-line.wav',
          name: 'sample-opening-line.wav',
        );
        return;
      case SmokeMainPhase.running:
        _controller.applySmokeTask(
          _smokeTaskSummary(
            status: 'RUNNING',
            progress: 0.707,
            checkpointStatus: 'TRANSLATE',
            progressDetail: const {
              'translate_done_count': 12,
              'translate_total_chunks': 38,
              'translate_current_mode': 'batch_recovery',
              'translate_recovery_segment_count': 79,
              'model_request_count': 5,
              'model_request_counts': {
                'translate': 3,
                'memory_bootstrap_extract': 1,
                'batch_recovery': 1,
              },
            },
            runtime: const {'state': 'running', 'progress': 0.707},
          ),
        );
        return;
      case SmokeMainPhase.failed:
        _controller.applySmokeTask(
          _smokeTaskSummary(
            status: 'FAILED',
            error: '翻译服务连不上。',
            errorInfo: const {
              'hint_zh': '翻译服务暂时连不上，请检查服务地址、模型名和凭据后继续任务。',
              'recoverable': true,
            },
          ),
        );
        return;
    }
  }

  TaskSummary _smokeTaskSummary({
    required String status,
    double? progress,
    String? checkpointStatus,
    Map<String, Object?> progressDetail = const {},
    String? error,
    Map<String, Object?> runtime = const {},
    Map<String, Object?> errorInfo = const {},
  }) {
    return TaskSummary.fromJson({
      'task_id': 'tvx_release_smoke_${status.toLowerCase()}',
      'status': status,
      'input_file': r'D:\Media\sample-opening-line.mp4',
      'source_lang': 'auto',
      'target_lang': 'zh-CN',
      'bilingual': true,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'progress': ?progress,
      'checkpoint_status': ?checkpointStatus,
      if (progressDetail.isNotEmpty) 'progress_detail': progressDetail,
      if (runtime.isNotEmpty) 'runtime': runtime,
      'error': ?error,
      if (errorInfo.isNotEmpty) 'error_info': errorInfo,
    });
  }

  Future<void> _waitForMinimumVisibleDuration(
    AppSmokeArgs smoke,
    DateTime startedAt,
    DateTime deadline,
  ) async {
    final minimum = smoke.minVisibleDuration;
    if (minimum <= Duration.zero) return;
    final target = startedAt.add(minimum);
    final wait = target.difference(DateTime.now().toUtc());
    if (wait <= Duration.zero) return;
    final remaining = deadline.difference(DateTime.now().toUtc());
    if (remaining <= Duration.zero) return;
    await Future<void>.delayed(wait < remaining ? wait : remaining);
  }

  Future<void> _writeSmokeReportAndHold(
    File reportFile,
    Map<String, Object?> payload,
    AppSmokeArgs smoke,
  ) async {
    await reportFile.writeAsString(jsonEncode(payload), encoding: utf8);
    final hold = smoke.postReportVisibleDuration;
    if (hold <= Duration.zero) return;
    await Future<void>.delayed(hold);
  }

  Map<String, Object?> _smokeNotificationReport() {
    final sink = _smokeNotificationSink;
    return <String, Object?>{
      'notification_check_ok':
          sink != null &&
          sink.initializeCalls == 1 &&
          sink.showCalls == 1 &&
          sink.lastPayload.endsWith(':completed'),
      'notification_trigger_path': 'observer_state_transition',
      'notification_initialize_calls': sink?.initializeCalls ?? 0,
      'notification_show_calls': sink?.showCalls ?? 0,
      'notification_last_id': sink?.lastId,
      'notification_last_title': sink?.lastTitle ?? '',
      'notification_last_payload': sink?.lastPayload ?? '',
      'notification_app_user_model_id':
          WindowsTaskNotificationService.appUserModelId,
      'notification_activation_guid':
          WindowsTaskNotificationService.activationGuid,
      'notification_error': '',
    };
  }

  Future<void> _waitForSmokeNotification(DateTime deadline) async {
    final notificationDeadline = _earlierDeadline(
      deadline,
      DateTime.now().add(const Duration(seconds: 4)),
    );
    while (DateTime.now().isBefore(notificationDeadline)) {
      final sink = _smokeNotificationSink;
      if (sink != null && sink.showCalls >= 1) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<Map<String, Object?>> _runSmokeTask(
    AppSmokeArgs smoke,
    DateTime deadline,
  ) async {
    final client = _service.client;
    if (client == null) {
      throw StateError('本地服务未连接，无法提交 smoke 任务');
    }
    final inputPath = smoke.inputPath;
    if (inputPath == null || inputPath.isEmpty) return const {};
    if (smoke.useControllerSubmission) {
      return _runSmokeTaskThroughController(smoke, deadline, inputPath);
    }

    final submitted = await client
        .submitRun({
          'request_version': 1,
          'input_type': 'video_asr',
          'input': inputPath,
          'source_lang': 'auto',
          'target_lang': 'zh-CN',
          'source_mode': 'embedded_subtitle',
        })
        .timeout(_remaining(deadline));
    final terminal = await _waitForSmokeTask(
      client,
      submitted.taskId,
      deadline,
    );
    final events = await client
        .taskEvents(submitted.taskId)
        .timeout(_remaining(deadline));
    final outputPath = terminal.outputPath;
    var outputExists = false;
    var outputContainsExpectedText = smoke.expectedOutputText == null;
    if (outputPath != null && outputPath.isNotEmpty) {
      final output = File(outputPath);
      outputExists = await output.exists();
      if (outputExists && smoke.expectedOutputText != null) {
        final text = await output.readAsString(encoding: utf8);
        outputContainsExpectedText = text.contains(smoke.expectedOutputText!);
      }
    }

    return <String, Object?>{
      'task_submitted_status': submitted.status,
      'task_id': submitted.taskId,
      'task_status': terminal.status,
      'task_input': inputPath,
      'task_output_path': outputPath ?? '',
      'task_output_paths': terminal.outputPaths,
      'task_output_exists': outputExists,
      'task_output_contains_expected_text': outputContainsExpectedText,
      'task_output_ok': outputExists && outputContainsExpectedText,
      'task_done_event': events.events.any(
        (event) => event is Map && event['type'] == 'done',
      ),
      'task_error': terminal.error ?? '',
    };
  }

  Future<Map<String, Object?>> _runSmokeTaskThroughController(
    AppSmokeArgs smoke,
    DateTime deadline,
    String inputPath,
  ) async {
    _controller.pickSource(inputPath);
    await _controller.submitRun().timeout(_remaining(deadline));
    final taskId = _controller.view.taskId;
    if (taskId == null || taskId.isEmpty) {
      final failure = _controller.view.failure?.reason ?? 'unknown failure';
      throw StateError('Smoke controller submission failed: $failure');
    }
    final client = await _ensureSmokeClient(deadline);
    final controllerTerminal = await _waitForControllerSmokeTask(deadline);
    final outputPaths = controllerTerminal.outputPaths;
    final outputPath = MainWindowController.primaryOutputPath(outputPaths);
    var outputExists = false;
    var outputContainsExpectedText = smoke.expectedOutputText == null;
    if (outputPath != null && outputPath.isNotEmpty) {
      final output = File(outputPath);
      outputExists = await output.exists();
      if (outputExists && smoke.expectedOutputText != null) {
        final text = await output.readAsString(encoding: utf8);
        outputContainsExpectedText = text.contains(smoke.expectedOutputText!);
      }
    }
    var doneEvent = false;
    var terminalEvidence = 'controller_view';
    var terminalStatus = 'DONE';
    String taskError = '';
    if (!outputExists || !outputContainsExpectedText) {
      final terminal = await _waitForSmokeTask(client, taskId, deadline);
      terminalStatus = terminal.status;
      taskError = terminal.error ?? '';
      terminalEvidence = 'desktop_snapshot';
    }
    doneEvent = await _waitForTaskEvent(client, taskId, 'done', deadline);
    var modelRequestCount = 0;
    var modelRequestCounts = const <String, int>{};
    try {
      final tasks = await client.taskList().timeout(_remaining(deadline));
      final summary = tasks.where((task) => task.taskId == taskId).firstOrNull;
      modelRequestCount = summary?.modelRequestCount ?? 0;
      modelRequestCounts = summary?.modelRequestCounts ?? const <String, int>{};
    } on Object {
      // The remaining smoke evidence still reports the missing request summary.
    }
    var resultOpenOk = false;
    var resultOpenOutputPath = '';
    var resultOpenOutputPaths = const <String, String>{};
    var resultOpenSameDirectory = false;
    var resultOpenError = '';
    if (outputExists && outputContainsExpectedText) {
      try {
        final resultClient = await _ensureSmokeClient(deadline);
        final opened = await resultClient
            .resultOpen(taskId)
            .timeout(_remaining(deadline));
        resultOpenOutputPaths = opened['output_paths'] is Map
            ? (opened['output_paths'] as Map).map(
                (key, value) => MapEntry('$key', '$value'),
              )
            : const <String, String>{};
        resultOpenOutputPath =
            MainWindowController.primaryOutputPath(resultOpenOutputPaths) ?? '';
        resultOpenSameDirectory =
            outputPath != null &&
            outputPath.isNotEmpty &&
            resultOpenOutputPath.isNotEmpty &&
            File(outputPath).parent.path ==
                File(resultOpenOutputPath).parent.path;
        resultOpenOk =
            resultOpenOutputPath.isNotEmpty &&
            await File(resultOpenOutputPath).exists() &&
            resultOpenSameDirectory;
      } on Object catch (error) {
        resultOpenError = '$error';
      }
    }
    var reexportOk = false;
    var reexportEvent = false;
    var reexportOutputPath = '';
    var reexportOutputPaths = const <String, String>{};
    var reexportSameDirectory = false;
    var reexportError = '';
    if (outputExists && outputContainsExpectedText) {
      try {
        await _controller.reexportResult().timeout(_remaining(deadline));
        reexportOutputPaths = _controller.view.outputPaths;
        reexportOutputPath =
            MainWindowController.primaryOutputPath(reexportOutputPaths) ?? '';
        reexportSameDirectory =
            outputPath != null &&
            outputPath.isNotEmpty &&
            reexportOutputPath.isNotEmpty &&
            File(outputPath).parent.path ==
                File(reexportOutputPath).parent.path;
        reexportOk =
            reexportOutputPath.isNotEmpty &&
            await File(reexportOutputPath).exists() &&
            reexportSameDirectory;
        reexportEvent = await _waitForTaskEvent(
          client,
          taskId,
          'reexported',
          deadline,
        );
      } on Object catch (error) {
        reexportError = '$error';
      }
    }

    return <String, Object?>{
      'task_submission_path': 'controller',
      'task_id': taskId,
      'task_status': terminalStatus,
      'task_input': inputPath,
      'task_output_path': outputPath ?? '',
      'task_output_paths': outputPaths,
      'task_output_exists': outputExists,
      'task_output_contains_expected_text': outputContainsExpectedText,
      'task_output_ok': outputExists && outputContainsExpectedText,
      'task_done_event': doneEvent,
      'task_terminal_evidence': terminalEvidence,
      'task_error': taskError,
      'task_model_request_count': modelRequestCount,
      'task_model_request_counts': modelRequestCounts,
      'controller_state': _controller.view.state.name,
      'result_open_ok': resultOpenOk,
      'result_open_output_path': resultOpenOutputPath,
      'result_open_output_paths': resultOpenOutputPaths,
      'result_open_same_directory': resultOpenSameDirectory,
      'result_open_error': resultOpenError,
      'reexport_ok': reexportOk,
      'reexport_event': reexportEvent,
      'reexport_output_path': reexportOutputPath,
      'reexport_output_paths': reexportOutputPaths,
      'reexport_same_directory': reexportSameDirectory,
      'reexport_error': reexportError,
    };
  }

  Future<MainWindowViewModel> _waitForControllerSmokeTask(
    DateTime deadline,
  ) async {
    MainWindowViewModel latest = _controller.view;
    while (DateTime.now().isBefore(deadline)) {
      latest = _controller.view;
      if (latest.state == MainState.completed ||
          latest.state == MainState.failed) {
        return latest;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw TimeoutException(
      'smoke controller task did not finish: ${latest.state.name}',
    );
  }

  Future<TaskSummary> _waitForSmokeTask(
    AppServiceClient client,
    String taskId,
    DateTime deadline,
  ) async {
    TaskSummary? latest;
    while (DateTime.now().isBefore(deadline)) {
      final snapshot = await client.desktopSnapshot().timeout(
        _remaining(deadline),
      );
      latest = snapshot.taskById(taskId);
      if (latest?.isTerminal == true) return latest!;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final status = latest == null
        ? 'not found in desktop snapshot'
        : '${latest.status}: ${latest.error ?? ''}';
    throw TimeoutException('smoke task $taskId did not finish: $status');
  }

  Future<bool> _waitForTaskEvent(
    AppServiceClient client,
    String taskId,
    String type,
    DateTime deadline,
  ) async {
    final eventDeadline = _earlierDeadline(
      deadline,
      DateTime.now().add(const Duration(seconds: 4)),
    );
    while (DateTime.now().isBefore(eventDeadline)) {
      try {
        final events = await client
            .taskEvents(taskId)
            .timeout(_remaining(eventDeadline));
        if (events.events.any(
          (event) => event is Map && event['type'] == type,
        )) {
          return true;
        }
      } on Object {
        try {
          client = await _ensureSmokeClient(eventDeadline);
        } on Object {
          return false;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  Future<AppServiceClient> _ensureSmokeClient(DateTime deadline) async {
    await _service.refresh().timeout(_remaining(deadline));
    final client = _service.client;
    if (client == null) {
      throw StateError('本地服务未连接，无法执行 smoke 验证');
    }
    return client;
  }

  DateTime _earlierDeadline(DateTime a, DateTime b) {
    return a.isBefore(b) ? a : b;
  }

  Duration _remaining(DateTime deadline) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining > const Duration(milliseconds: 500)) return remaining;
    return const Duration(milliseconds: 500);
  }

  Future<void> _focusMainWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } on Object {
      // Notification activation is best-effort; the in-window task state remains authoritative.
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final view = _controller.view;
        return RepaintBoundary(
          key: _renderKey,
          child: Scaffold(
            body: DropTarget(
              onDragEntered: (_) => _drag.forward(),
              onDragExited: (_) {
                _drag.reverse();
                if (_dropTargetHover) {
                  setState(() => _dropTargetHover = false);
                }
              },
              onDragDone: (detail) {
                _drag.reverse();
                if (_dropTargetHover || _dropTargetDown) {
                  setState(() {
                    _dropTargetHover = false;
                    _dropTargetDown = false;
                  });
                }
                final file = detail.files.isNotEmpty
                    ? detail.files.first
                    : null;
                final path = file?.path;
                if (path != null) {
                  _controller.pickSource(path, name: file?.name);
                }
              },
              child: Container(
                decoration: BoxDecoration(
                  color: T.bg,
                  border: Border.all(color: T.line, width: 1),
                ),
                child: Column(
                  children: [
                    TitleBar(
                      menuKey: const ValueKey('main-menu-button'),
                      onMenu: () => unawaited(_showChromeMenu()),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          T.s32,
                          T.s8,
                          T.s32,
                          T.s16,
                        ),
                        child: _body(view),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body(MainWindowViewModel view) {
    return Column(
      children: [
        Expanded(
          child: Align(alignment: Alignment.center, child: _subject(view)),
        ),
        if (view.state == MainState.empty ||
            view.state == MainState.ready ||
            view.state == MainState.blocked) ...[
          JobLine(
            view: view,
            onPickTranslation: _pickTranslation,
            onPickAsr: _pickAsr,
            onPickSourceLanguage: _pickSourceLanguage,
            onPickTargetLanguage: _pickTargetLanguage,
            onPickBilingual: _pickBilingual,
            onPickFormats: _pickFormats,
            onToggleTerms: _toggleTerms,
            onConfigureTranslation: () =>
                _openToolWindow(AppWindowType.translationSettings),
            onConfigureAsr: () => _openToolWindow(AppWindowType.asrSettings),
          ),
          const SizedBox(height: T.s16),
        ],
        if (view.state != MainState.failed) ...[
          PrimaryAction(
            key: ValueKey(
              'main-cta-${view.state.name}-${_ctaVariant(view).name}',
            ),
            label: _ctaLabel(view),
            variant: _ctaVariant(view),
            onTap: () => _onCta(view),
          ),
          if (view.state == MainState.completed) ...[
            const SizedBox(height: T.s8),
            _TextAction(
              label: '制作新片源',
              onTap: () => unawaited(_controller.resetForNext()),
            ),
          ],
          const SizedBox(height: T.s4),
        ] else if (view.state == MainState.failed)
          const SizedBox(height: 50),
      ],
    );
  }

  Widget _subject(MainWindowViewModel view) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 300.0;
        final hasSource = view.state != MainState.empty;
        final objectHeight = hasSource
            ? (maxHeight - 96).clamp(126.0, 170.0).toDouble()
            : 170.0;
        final objectWidth = hasSource
            ? (objectHeight * 1.76).clamp(230.0, 300.0).toDouble()
            : 300.0;
        final captionHeight = hasSource
            ? (maxHeight - objectHeight - T.s8).clamp(64.0, 92.0).toDouble()
            : null;

        final content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: objectWidth,
              height: objectHeight,
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_breathe, _drag]),
                  builder: (context, _) {
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        CustomPaint(
                          size: Size(objectWidth, objectHeight),
                          painter: SourceObjectPainter(
                            state: view.state,
                            progress: view.progress,
                            phaseIndex: view.runProgress?.phaseIndex ?? 0,
                            phaseCount: view.runProgress?.phaseCount ?? 9,
                            phaseProgress: view.runProgress?.phaseProgress ?? 0,
                            breathe: _breathe.value,
                            dragOver: _drag.value,
                            pickHover: _dropTargetHover,
                            pickDown: _dropTargetDown,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: T.s8),
            if (view.state == MainState.empty) ...[
              _emptyPrompt(),
              if (view.homeTaskReminder != null) ...[
                const SizedBox(height: T.s12),
                _PendingTaskSlip(
                  reminder: view.homeTaskReminder!,
                  onResume: _resumeHomeTaskReminder,
                  onOpen: () => _openToolWindow(
                    AppWindowType.taskProcessing,
                    taskId: view.homeTaskReminder!.taskId,
                  ),
                  onDismiss: () => _controller.dismissHomeTaskReminder(
                    view.homeTaskReminder!.taskId,
                  ),
                ),
              ],
            ] else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: captionHeight!),
                child: _subjectCaption(view),
              ),
          ],
        );
        return GestureDetector(
          behavior: view.state == MainState.empty
              ? HitTestBehavior.translucent
              : HitTestBehavior.deferToChild,
          onSecondaryTapDown: view.source == null
              ? null
              : (details) => _showSourceContextMenu(details.globalPosition),
          child: view.state == MainState.empty
              ? _DropPickTarget(
                  onTap: () => unawaited(_pickFile()),
                  onHoverChanged: (hover) =>
                      setState(() => _dropTargetHover = hover),
                  onDownChanged: (down) =>
                      setState(() => _dropTargetDown = down),
                  child: content,
                )
              : content,
        );
      },
    );
  }

  Widget _emptyPrompt() {
    return AnimatedBuilder(
      animation: _drag,
      builder: (context, _) {
        final active = _drag.value > 0.35;
        return _HeroPrompt(
          text: active ? '松手就收下啦' : '把音频、视频或字幕放进来吧',
          active: active,
        );
      },
    );
  }

  Widget _subjectCaption(MainWindowViewModel view) {
    final caption = switch (view.state) {
      MainState.empty => const SizedBox.shrink(),
      MainState.ready || MainState.blocked => _fileHeader(view),
      MainState.running => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _fileHeader(view, showType: false),
          const SizedBox(height: T.s4),
          _runningStatus(view),
        ],
      ),
      MainState.completed => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _fileHeader(view, showType: false),
          if (view.completionNotice != null) ...[
            const SizedBox(height: T.s4),
            Text(
              view.completionNotice!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: T.tCaption.copyWith(color: T.warn),
            ),
          ],
          const SizedBox(height: T.s8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: T.s8,
            runSpacing: 6,
            children: [
              _Chip(label: '打开字幕', onTap: _openOutputFile),
              _Chip(label: '打开文件夹', onTap: _openOutputFolder),
              _Chip(label: '重新导出', onTap: _reexportResult),
            ],
          ),
        ],
      ),
      MainState.failed => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _fileHeader(view, showType: false),
          const SizedBox(height: 6),
          _RepairStrip(
            failure: view.failure,
            onTap: () => _runRecovery(view.failure),
          ),
        ],
      ),
    };
    return caption;
  }

  Widget _runningStatus(MainWindowViewModel view) {
    final run = view.runProgress;
    if (run == null) {
      return Text(
        view.runningText ?? (view.canceling ? '正在取消…' : '制作中…'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: T.tCaption.copyWith(color: T.accentStrong),
      );
    }
    final detail = run.activity.isNotEmpty ? run.activity : run.detail;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(run.title, style: T.tSection.copyWith(color: T.accentStrong)),
            if (run.counter.isNotEmpty) ...[
              const SizedBox(width: T.s8),
              Text(run.counter, style: T.tCaption),
            ],
          ],
        ),
        const SizedBox(height: 2),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 390),
          child: Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: T.tCaption,
          ),
        ),
      ],
    );
  }

  Widget _fileHeader(MainWindowViewModel view, {bool showType = true}) {
    final source = view.source;
    if (source == null) return const SizedBox.shrink();
    return Column(
      children: [
        DesignedTooltip(
          message: fileTooltipLabel(source.path, fallbackName: source.name),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 390),
            child: Text(
              source.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: T.tFilename,
            ),
          ),
        ),
        if (showType) ...[
          const SizedBox(height: T.s8),
          _TypeTag(kind: source.kind),
        ],
      ],
    );
  }

  String _ctaLabel(MainWindowViewModel view) {
    return switch (view.state) {
      MainState.empty => '选择片源',
      MainState.ready =>
        view.sourceInspectionPending
            ? '检查片源中…'
            : view.submitting
            ? '提交中…'
            : '开始译制',
      MainState.blocked => !view.translationConfigured ? '去配置翻译' : '去配置识别',
      MainState.running => view.canceling ? '取消中…' : '取消任务',
      MainState.completed => '审看结果',
      MainState.failed => view.failure?.actionLabel ?? '重试',
    };
  }

  CtaVariant _ctaVariant(MainWindowViewModel view) {
    if (view.state == MainState.ready && view.sourceInspectionPending) {
      return CtaVariant.disabled;
    }
    return switch (view.state) {
      MainState.empty => CtaVariant.filled,
      MainState.running => CtaVariant.outline,
      _ => CtaVariant.filled,
    };
  }

  void _onCta(MainWindowViewModel view) {
    switch (view.state) {
      case MainState.empty:
        unawaited(_pickFile());
        break;
      case MainState.ready:
        if (view.sourceInspectionPending) return;
        unawaited(_controller.submitRun());
        break;
      case MainState.blocked:
        if (!view.translationConfigured) {
          _openToolWindow(AppWindowType.translationSettings);
        } else {
          _openToolWindow(AppWindowType.asrSettings);
        }
        break;
      case MainState.running:
        unawaited(_controller.cancelRun());
        break;
      case MainState.completed:
        _openResultReview(view);
        break;
      case MainState.failed:
        _runRecovery(view.failure);
        break;
    }
  }

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles();
    final file = res?.files.singleOrNull;
    final path = file?.path;
    if (mounted && (_dropTargetHover || _dropTargetDown)) {
      setState(() {
        _dropTargetHover = false;
        _dropTargetDown = false;
      });
    }
    if (path != null) _controller.pickSource(path, name: file?.name);
  }

  Future<void> _showChromeMenu() async {
    final selected = await showMenu<String>(
      context: context,
      color: T.surface,
      position: const RelativeRect.fromLTRB(560, 40, 28, 0),
      items: [
        _menuItem('translation', '翻译模型设置'),
        _menuItem('asr', '语音识别设置'),
        _menuItem('history', '任务处理'),
      ],
    );
    switch (selected) {
      case 'translation':
        _openToolWindow(AppWindowType.translationSettings);
        break;
      case 'asr':
        _openToolWindow(AppWindowType.asrSettings);
        break;
      case 'history':
        _openToolWindow(AppWindowType.taskProcessing);
        break;
    }
  }

  PopupMenuItem<String> _menuItem(String value, String label) {
    return PopupMenuItem<String>(
      key: ValueKey('main-menu-$value'),
      value: value,
      child: Text(label, style: T.tBody),
    );
  }

  Future<void> _showSourceContextMenu(Offset position) async {
    final selected = await showMenu<String>(
      context: context,
      color: T.surface,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        _menuItem('replace', '换片源'),
        _menuItem('remove', '移除'),
        _menuItem('copy_path', '复制完整路径'),
      ],
    );
    switch (selected) {
      case 'replace':
        await _pickFile();
        break;
      case 'remove':
        _controller.removeSource();
        break;
      case 'copy_path':
        final path = _controller.view.source?.path;
        if (path != null) {
          await Clipboard.setData(ClipboardData(text: path));
          _toast('已复制完整路径');
        }
        break;
    }
  }

  Future<void> _pickTranslation() async {
    final view = _controller.view;
    final selected = await showMenu<Object>(
      context: context,
      color: T.surface,
      position: const RelativeRect.fromLTRB(248, 318, 248, 0),
      items: [
        PopupMenuItem<Object>(
          enabled: false,
          child: Text('翻译模型', style: T.tSection),
        ),
        if (view.translationOptions.isEmpty)
          const PopupMenuItem<Object>(
            enabled: false,
            child: Text('还没有常用翻译模型', style: T.tCaption),
          )
        else
          for (final option in view.translationOptions)
            _translationMenuItem(option),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          key: const ValueKey('translation-more-models'),
          value: _menuMoreTranslationModels,
          child: Text('更多模型', style: T.tBody),
        ),
        PopupMenuItem<Object>(
          value: _menuFooter,
          child: Text(
            '去翻译模型设置',
            style: T.tBody.copyWith(color: T.accentStrong),
          ),
        ),
      ],
    );
    if (identical(selected, _menuFooter)) {
      _openToolWindow(AppWindowType.translationSettings);
      return;
    }
    if (identical(selected, _menuMoreTranslationModels)) {
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!mounted) return;
      await _selectDirectTranslation();
      return;
    }
    if (selected is TranslationRuntimeChoice) {
      _controller.selectTranslation(selected);
    }
  }

  Future<void> _selectDirectTranslation() async {
    final direct = await _pickDirectTranslation();
    if (!mounted || direct == null) return;
    _controller.selectTranslation(direct);
  }

  Future<TranslationRuntimeChoice?> _pickDirectTranslation() async {
    final view = _controller.view;
    final selected = await showMenu<Object>(
      context: context,
      color: T.surface,
      position: const RelativeRect.fromLTRB(248, 318, 248, 0),
      items: [
        PopupMenuItem<Object>(
          enabled: false,
          child: Text('更多翻译模型', style: T.tSection),
        ),
        if (view.translationDirectOptions.isEmpty)
          const PopupMenuItem<Object>(
            enabled: false,
            child: Text('还没有可用翻译模型', style: T.tCaption),
          )
        else
          for (final option in view.translationDirectOptions)
            _translationMenuItem(option),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          value: _menuFooter,
          child: Text(
            '去翻译模型设置',
            style: T.tBody.copyWith(color: T.accentStrong),
          ),
        ),
      ],
    );
    if (identical(selected, _menuFooter)) {
      _openToolWindow(AppWindowType.translationSettings);
      return null;
    }
    return selected is TranslationRuntimeChoice ? selected : null;
  }

  Future<void> _pickAsr() async {
    final view = _controller.view;
    final selected = await _showOptionMenu<TaskOption>(
      title: '语音识别引擎',
      options: view.asrOptions,
      emptyLabel: '还没有可用识别引擎',
      footerLabel: '去语音识别设置',
      onFooter: () => _openToolWindow(AppWindowType.asrSettings),
      labelOf: (option) => option.label,
    );
    if (selected != null) _controller.selectAsr(selected);
  }

  Future<void> _pickSourceLanguage() async {
    final selected = await _showOptionMenu<String>(
      title: '源语言',
      options: _sourceLanguageOptions,
      emptyLabel: '',
      labelOf: languageLabel,
      keyOf: (value) => ValueKey('source-language-$value'),
    );
    if (selected != null) _controller.setSourceLang(selected);
  }

  Future<void> _pickTargetLanguage() async {
    final selected = await _showOptionMenu<String>(
      title: '目标语言',
      options: _targetLanguageOptions,
      emptyLabel: '',
      labelOf: languageLabel,
      keyOf: (value) => ValueKey('target-language-$value'),
    );
    if (selected != null) _controller.setTargetLang(selected);
  }

  Future<void> _pickBilingual() async {
    final selected = await _showOptionMenu<bool>(
      title: '字幕语言',
      options: const [true, false],
      emptyLabel: '',
      labelOf: (value) => value ? '双语' : '单语',
    );
    if (selected != null) _controller.setBilingual(selected);
  }

  Future<void> _pickFormats() async {
    final selected = await _showOptionMenu<List<String>>(
      title: '输出格式',
      options: const [
        ['SRT'],
        ['ASS'],
        ['VTT'],
        ['LRC'],
        ['SRT', 'ASS'],
      ],
      emptyLabel: '',
      labelOf: (value) => value.join('·'),
    );
    if (selected != null) _controller.setFormats(selected);
  }

  void _toggleTerms() {
    _controller.setTermsEnabled(!_controller.view.termsEnabled);
  }

  Future<TValue?> _showOptionMenu<TValue>({
    required String title,
    required List<TValue> options,
    required String emptyLabel,
    required String Function(TValue option) labelOf,
    Key? Function(TValue option)? keyOf,
    String? footerLabel,
    VoidCallback? onFooter,
  }) async {
    final selected = await showMenu<Object>(
      context: context,
      color: T.surface,
      position: const RelativeRect.fromLTRB(248, 318, 248, 0),
      items: [
        PopupMenuItem<Object>(
          enabled: false,
          child: Text(title, style: T.tSection),
        ),
        if (options.isEmpty)
          PopupMenuItem<Object>(
            enabled: false,
            child: Text(emptyLabel, style: T.tCaption),
          )
        else
          for (final option in options)
            PopupMenuItem<Object>(
              key: keyOf?.call(option),
              value: option as Object,
              child: Text(labelOf(option), style: T.tBody),
            ),
        if (footerLabel != null) const PopupMenuDivider(),
        if (footerLabel != null)
          PopupMenuItem<Object>(
            value: _menuFooter,
            child: Text(
              footerLabel,
              style: T.tBody.copyWith(color: T.accentStrong),
            ),
          ),
      ],
    );
    if (identical(selected, _menuFooter)) {
      onFooter?.call();
      return null;
    }
    return selected as TValue?;
  }

  PopupMenuItem<Object> _translationMenuItem(TranslationRuntimeChoice option) {
    return PopupMenuItem<Object>(
      key: ValueKey(
        'translation-choice-${option.source.name}-${option.provider ?? ''}-${option.model ?? ''}',
      ),
      value: option,
      child: SizedBox(
        width: 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              option.label,
              style: T.tBody,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (option.detail.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                option.detail,
                style: T.tCaption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _runRecovery(MainFailureView? failure) async {
    switch (failure?.target ?? MainRecoveryTarget.retry) {
      case MainRecoveryTarget.translationSettings:
        _openToolWindow(AppWindowType.translationSettings);
        break;
      case MainRecoveryTarget.asrSettings:
        _openToolWindow(AppWindowType.asrSettings);
        break;
      case MainRecoveryTarget.pickSource:
        await _pickFile();
        break;
      case MainRecoveryTarget.resume:
        unawaited(_controller.resumeRun());
        break;
      case MainRecoveryTarget.retry:
        unawaited(_controller.retryRun());
        break;
      case MainRecoveryTarget.outputDirectory:
        await _pickOutputDirectoryAndRetry();
        break;
      case MainRecoveryTarget.reexportDirectory:
        await _pickOutputDirectoryAndReexport();
        break;
      case MainRecoveryTarget.reexport:
        unawaited(_reexportResult());
        break;
    }
  }

  Future<void> _resumeHomeTaskReminder() async {
    try {
      await _controller.resumeHomeTaskReminder();
    } on Object catch (error) {
      _toast('$error');
    }
  }

  Future<void> _pickOutputDirectoryAndRetry() async {
    try {
      final selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择输出目录',
        lockParentWindow: true,
        initialDirectory: _controller.view.outputDirectory,
      );
      if (selected == null || selected.trim().isEmpty) return;
      _controller.setOutputDirectory(selected);
      _toast('已选择输出目录，正在重试');
      unawaited(_controller.retryRun());
    } on Object catch (error) {
      _toast('选择输出目录失败：$error');
    }
  }

  Future<void> _pickOutputDirectoryAndReexport() async {
    try {
      final selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择输出目录',
        lockParentWindow: true,
        initialDirectory: _controller.view.outputDirectory,
      );
      if (selected == null || selected.trim().isEmpty) return;
      _controller.setOutputDirectory(selected);
      _toast('已选择输出目录，正在重新导出');
      unawaited(_reexportResult(outputDirectory: selected));
    } on Object catch (error) {
      _toast('选择输出目录失败：$error');
    }
  }

  Future<void> _openOutputFile() async {
    try {
      await _controller.openResultFile();
    } on Object catch (error) {
      _toast('打开字幕失败：$error');
    }
  }

  Future<void> _openOutputFolder() async {
    try {
      await _controller.openResultFolder();
    } on Object catch (error) {
      _toast('打开文件夹失败：$error');
    }
  }

  Future<void> _reexportResult({String? outputDirectory}) async {
    try {
      if (outputDirectory == null || outputDirectory.trim().isEmpty) {
        await _controller.reexportResult();
      } else {
        await _controller.reexportResultToDirectory(outputDirectory);
      }
      _toast('已重新导出字幕');
    } on Object catch (error) {
      _toast('重新导出失败：$error');
    }
  }

  Future<void> _openResultReview(MainWindowViewModel view) async {
    final taskId = view.taskId?.trim();
    if (taskId == null || taskId.isEmpty) {
      _toast('没有可审看的任务结果');
      return;
    }
    await _openToolWindow(AppWindowType.taskProcessing, taskId: taskId);
  }

  Future<void> _openToolWindowFromArgs(AppWindowArgs args) {
    return _openToolWindow(args.type, taskId: args.taskId);
  }

  Future<void> _openToolWindow(AppWindowType type, {String? taskId}) async {
    final parentBounds = await _currentWindowBounds();
    final args = AppWindowArgs(
      type: type,
      taskId: taskId,
      parentBounds: parentBounds,
      visibleBounds: await currentDisplayVisibleBoundsFor(parentBounds),
    );
    final windowKey = _toolWindowKey(type, taskId: taskId);
    final existing = _toolWindows[windowKey];
    if (existing != null) {
      try {
        if (type == AppWindowType.taskProcessing) {
          await existing.invokeMethod<void>('window_retarget', args.encode());
        } else {
          await existing.invokeMethod<void>('window_focus');
        }
        return;
      } on Object {
        _toolWindows.remove(windowKey);
      }
    }
    try {
      final controller = await WindowController.create(
        WindowConfiguration(hiddenAtLaunch: true, arguments: args.encode()),
      );
      _toolWindows[windowKey] = controller;
      // Child windows reveal themselves after their first Flutter frame. Showing
      // here races the child render path and can expose a blank native window.
    } on Object catch (exc) {
      _toast('打开${type.title}失败：$exc');
    }
  }

  String _toolWindowKey(AppWindowType type, {String? taskId}) {
    if (type == AppWindowType.taskProcessing) return type.id;
    return '${type.id}:${taskId?.trim() ?? ''}';
  }

  Future<Rect?> _currentWindowBounds() async {
    try {
      return await windowManager.getBounds();
    } on Object {
      return null;
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: T.tBody.copyWith(color: T.ink)),
          backgroundColor: T.surface,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }
}

enum _MenuAction { footer, moreTranslationModels }

const Object _menuFooter = _MenuAction.footer;
const Object _menuMoreTranslationModels = _MenuAction.moreTranslationModels;

class _TypeTag extends StatelessWidget {
  const _TypeTag({required this.kind});
  final SourceKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: T.s8, vertical: 3),
      decoration: BoxDecoration(
        color: T.accentSoft,
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.accent, width: 1),
      ),
      child: Text(
        kind.zh,
        style: T.tCaption.copyWith(
          color: T.accentStrong,
          fontWeight: T.wMedium,
        ),
      ),
    );
  }
}

class _DropPickTarget extends StatefulWidget {
  const _DropPickTarget({
    required this.child,
    required this.onTap,
    required this.onHoverChanged,
    required this.onDownChanged,
  });

  final Widget child;
  final VoidCallback onTap;
  final ValueChanged<bool> onHoverChanged;
  final ValueChanged<bool> onDownChanged;

  @override
  State<_DropPickTarget> createState() => _DropPickTargetState();
}

class _DropPickTargetState extends State<_DropPickTarget> {
  bool _hover = false;
  bool _down = false;

  void _setHover(bool value) {
    if (_hover == value) return;
    _hover = value;
    widget.onHoverChanged(value);
  }

  void _setDown(bool value) {
    if (_down == value) return;
    _down = value;
    widget.onDownChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHover(true),
      onExit: (_) {
        _setHover(false);
        _setDown(false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setDown(true),
        onTapUp: (_) => _setDown(false),
        onTapCancel: () => _setDown(false),
        onTap: widget.onTap,
        child: Semantics(
          key: const ValueKey('main-empty-pick-target'),
          button: true,
          label: '浏览文件',
          child: widget.child,
        ),
      ),
    );
  }
}

class _HeroPrompt extends StatelessWidget {
  const _HeroPrompt({required this.text, required this.active});

  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 140),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: SizedBox(
        key: ValueKey(text),
        width: 390,
        height: 46,
        child: CustomPaint(
          painter: _HeroPromptPainter(active: active),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: T.displayFontFamily,
                  fontSize: 23,
                  fontWeight: T.wMedium,
                  height: 1.0,
                  letterSpacing: 0,
                ).copyWith(color: active ? T.accentStrong : T.ink),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroPromptPainter extends CustomPainter {
  const _HeroPromptPainter({required this.active});

  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height * 0.58;
    final fillPath = Path()
      ..moveTo(22, 10)
      ..quadraticBezierTo(size.width * 0.38, 5.5, size.width - 34, 9)
      ..lineTo(size.width - 20, centerY + 9)
      ..quadraticBezierTo(size.width * 0.52, centerY + 15, 26, centerY + 10)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..color = active
            ? T.accentSoft.withValues(alpha: 0.46)
            : T.surface.withValues(alpha: 0.56),
    );

    final underline = Paint()
      ..color = active
          ? T.accent.withValues(alpha: 0.76)
          : T.accent.withValues(alpha: 0.34)
      ..style = PaintingStyle.stroke
      ..strokeWidth = active ? 2.0 : 1.4
      ..strokeCap = StrokeCap.round;

    final underlineY = size.height - 7;
    final segments = active
        ? <(double, double)>[(73, 219)]
        : <(double, double)>[(78, 102), (112, 139), (150, 178), (188, 214)];
    for (final segment in segments) {
      canvas.drawLine(
        Offset(segment.$1, underlineY),
        Offset(segment.$2, underlineY),
        underline,
      );
    }

    final dotPaint = Paint()
      ..color = active
          ? T.sky.withValues(alpha: 0.8)
          : T.sky.withValues(alpha: 0.46)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(48, 15), active ? 2.2 : 1.7, dotPaint);
    canvas.drawCircle(
      Offset(size.width - 51, 14),
      active ? 2.0 : 1.5,
      dotPaint,
    );

    final spark = Paint()
      ..color = T.accent.withValues(alpha: active ? 0.78 : 0.38)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(36, 25), const Offset(42, 25), spark);
    canvas.drawLine(const Offset(39, 22), const Offset(39, 28), spark);
    canvas.drawLine(
      Offset(size.width - 36, 25),
      Offset(size.width - 30, 25),
      spark,
    );
    canvas.drawLine(
      Offset(size.width - 33, 22),
      Offset(size.width - 33, 28),
      spark,
    );
  }

  @override
  bool shouldRepaint(covariant _HeroPromptPainter oldDelegate) =>
      oldDelegate.active != active;
}

class _PendingTaskSlip extends StatelessWidget {
  const _PendingTaskSlip({
    required this.reminder,
    required this.onResume,
    required this.onOpen,
    required this.onDismiss,
  });

  final HomeTaskReminder reminder;
  final VoidCallback onResume;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final hasMany = reminder.resumableCount > 1;
    final title = hasMany
        ? '有 ${reminder.resumableCount} 个未完成制作'
        : '有 1 个未完成制作';
    final source = reminder.sourceName.trim();
    final sourceLabel = source.isEmpty
        ? '上次制作还没完成'
        : hasMany
        ? '最近：$source'
        : source;
    return SizedBox(
      width: 430,
      height: 78,
      child: CustomPaint(
        painter: _PendingTaskSlipPainter(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(T.s24, T.s12, T.s16, T.s8),
          child: Row(
            children: [
              SizedBox(
                width: 58,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '待续',
                      style: T.tSection.copyWith(color: T.accentStrong),
                    ),
                    const SizedBox(height: 2),
                    Text('制作', style: T.tCaption.copyWith(fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: T.s12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.tBody.copyWith(fontWeight: T.wMedium),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      sourceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: T.tCaption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: T.s12),
              _SlipAction(
                label: hasMany ? '继续最近' : '继续',
                onTap: onResume,
                primary: true,
              ),
              const SizedBox(width: T.s8),
              _SlipAction(label: hasMany ? '查看全部' : '查看', onTap: onOpen),
              const SizedBox(width: T.s4),
              _SlipAction(label: '稍后', onTap: onDismiss),
            ],
          ),
        ),
      ),
    );
  }
}

class _PendingTaskSlipPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paper = Path()
      ..moveTo(13, 9)
      ..lineTo(size.width - 34, 5)
      ..lineTo(size.width - 12, 22)
      ..lineTo(size.width - 15, size.height - 12)
      ..lineTo(24, size.height - 6)
      ..lineTo(8, size.height - 22)
      ..close();
    canvas.drawPath(
      paper,
      Paint()
        ..color = T.surface
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      paper,
      Paint()
        ..color = T.line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round,
    );

    final fold = Path()
      ..moveTo(size.width - 34, 5)
      ..lineTo(size.width - 12, 22)
      ..lineTo(size.width - 35, 24)
      ..close();
    canvas.drawPath(
      fold,
      Paint()
        ..color = T.accentSoft.withValues(alpha: 0.65)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      fold,
      Paint()
        ..color = T.line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final tape = Path()
      ..moveTo(42, 0)
      ..lineTo(122, 0)
      ..lineTo(116, 14)
      ..lineTo(36, 14)
      ..close();
    canvas.drawPath(
      tape,
      Paint()
        ..color = T.sky.withValues(alpha: 0.18)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      tape,
      Paint()
        ..color = T.sky.withValues(alpha: 0.30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final divider = Paint()
      ..color = T.line
      ..strokeWidth = 1;
    canvas.drawLine(
      const Offset(92, 17),
      Offset(92, size.height - 17),
      divider,
    );

    final holePaint = Paint()
      ..color = T.bg
      ..style = PaintingStyle.fill;
    final holeStroke = Paint()
      ..color = T.inkLine.withValues(alpha: 0.62)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    for (final y in [25.0, 39.0, 53.0]) {
      final rect = Rect.fromCenter(center: Offset(22, y), width: 7, height: 8);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(2));
      canvas
        ..drawRRect(rrect, holePaint)
        ..drawRRect(rrect, holeStroke);
    }

    canvas.drawCircle(
      const Offset(390, 56),
      2.4,
      Paint()
        ..color = T.warn.withValues(alpha: 0.75)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _PendingTaskSlipPainter oldDelegate) => false;
}

class _SlipAction extends StatefulWidget {
  const _SlipAction({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  State<_SlipAction> createState() => _SlipActionState();
}

class _SlipActionState extends State<_SlipAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fg = widget.primary ? const Color(0xFFFFFFFF) : T.accentStrong;
    final bg = widget.primary
        ? (_hover ? T.accentStrong : T.accent)
        : (_hover ? T.accentSoft : const Color(0x00000000));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: T.s8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(T.rSm),
            border: Border.all(color: T.accent, width: 1),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.tCaption.copyWith(color: fg, fontWeight: T.wMedium),
          ),
        ),
      ),
    );
  }
}

class _RepairStrip extends StatelessWidget {
  const _RepairStrip({required this.failure, required this.onTap});

  final MainFailureView? failure;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 430),
      padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: T.s8),
      decoration: BoxDecoration(
        color: const Color(0xFFFBE4E0),
        borderRadius: BorderRadius.circular(T.rSm),
        border: Border.all(color: T.danger, width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              failure?.reason ?? '制作失败',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: T.tCaption.copyWith(color: T.ink),
            ),
          ),
          const SizedBox(width: T.s12),
          _Chip(
            label: failure?.actionLabel ?? '重试',
            danger: true,
            onTap: onTap,
          ),
        ],
      ),
    );
  }
}

class _TextAction extends StatefulWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_TextAction> createState() => _TextActionState();
}

class _TextActionState extends State<_TextAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: 4),
          child: Text(
            widget.label,
            style: T.tCaption.copyWith(
              color: _hover ? T.accentStrong : T.muted,
              decoration: _hover
                  ? TextDecoration.underline
                  : TextDecoration.none,
              decorationColor: T.accentStrong,
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatefulWidget {
  const _Chip({required this.label, required this.onTap, this.danger = false});
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.danger ? T.danger : T.accentStrong;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: T.s12, vertical: 7),
          decoration: BoxDecoration(
            color: _hover
                ? (widget.danger ? const Color(0xFFFFF7F1) : T.accentSoft)
                : const Color(0x00000000),
            borderRadius: BorderRadius.circular(T.rMd),
            border: Border.all(color: c, width: 1.4),
          ),
          child: Text(
            widget.label,
            style: T.tBody.copyWith(color: c, fontWeight: T.wMedium),
          ),
        ),
      ),
    );
  }
}
