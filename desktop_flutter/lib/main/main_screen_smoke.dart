part of '../main.dart';

extension _MainScreenSmokeDriver on _MainScreenState {
  Future<void> _runStartupSmoke(AppSmokeArgs smoke) async {
    final startedAt = DateTime.now().toUtc();
    final deadline = startedAt.add(smoke.timeout);
    final reportFile = File(smoke.reportPath);
    await reportFile.parent.create(recursive: true);
    try {
      await _controller.startService().timeout(smoke.timeout);
      final checkTrayBeforeTask =
          smoke.checkTray &&
          (smoke.mainPhase != SmokeMainPhase.normal || smoke.inputPath == null);
      final trayReport = checkTrayBeforeTask
          ? await _checkTrayLifecycle(deadline)
          : const <String, Object?>{};
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
          'failure_action': _controller.view.failure?.actionLabel ?? '',
          'failure_target': _controller.view.failure?.target.name ?? '',
          'failure_reason': _controller.view.failure?.reason ?? '',
          'translation_label': _controller.view.translationLabel,
          'asr_label': _controller.view.asrLabel,
          'started_at': startedAt.toIso8601String(),
          'finished_at': DateTime.now().toUtc().toIso8601String(),
          'last_error': _service.snapshot.lastError ?? '',
          ...trayReport,
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
        ...trayReport,
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
      if (smoke.checkTray) {
        await _prepareSmokeExit();
      }
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

  Future<Map<String, Object?>> _checkTrayLifecycle(DateTime deadline) async {
    final initialWindowShow = _initialWindowShowCompleter?.future;
    if (initialWindowShow != null) {
      await initialWindowShow.timeout(_remaining(deadline));
    }
    final initializationDeadline = _earlierDeadline(
      deadline,
      DateTime.now().add(const Duration(seconds: 5)),
    );
    while (!_trayReady && DateTime.now().isBefore(initializationDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!_trayReady) {
      throw StateError('系统托盘未能在时限内初始化');
    }

    if (!await windowManager.isVisible()) {
      await _focusMainWindow();
    }
    final visibleBeforeClose = await _waitForWindowVisibility(
      expected: true,
      deadline: initializationDeadline,
    );
    final preventClose = await windowManager.isPreventClose();
    if (!visibleBeforeClose || !preventClose) {
      throw StateError('系统托盘未接管主窗口关闭行为');
    }

    await windowManager.close();
    final hiddenAfterClose = await _waitForWindowVisibility(
      expected: false,
      deadline: _earlierDeadline(
        deadline,
        DateTime.now().add(const Duration(seconds: 3)),
      ),
    );
    if (!hiddenAfterClose) {
      throw StateError(
        '关闭主窗口后应用没有隐藏到系统托盘'
        '（closeEvent=$_trayCloseEventObserved, '
        'hideAttempted=$_trayHideAttempted, hideError=$_trayHideError）',
      );
    }

    final client = _service.client;
    if (client == null) {
      throw StateError('主窗口隐藏后本地服务连接丢失');
    }
    final health = await client.health().timeout(_remaining(deadline));

    final activation = await _activateExistingInstance(deadline);
    final restored = await _waitForWindowVisibility(
      expected: true,
      deadline: _earlierDeadline(
        deadline,
        DateTime.now().add(const Duration(seconds: 3)),
      ),
    );
    if (!restored) {
      throw StateError('无法从系统托盘生命周期恢复主窗口');
    }

    return <String, Object?>{
      'tray_initialized': true,
      'tray_prevent_close': preventClose,
      'tray_visible_before_close': visibleBeforeClose,
      'tray_close_hid_window': hiddenAfterClose,
      'tray_service_alive_after_hide': true,
      'tray_service_health': health.status,
      'tray_restore_visible': restored,
      ...activation,
    };
  }

  Future<Map<String, Object?>> _activateExistingInstance(
    DateTime deadline,
  ) async {
    final activationProcess = await Process.start(
      Platform.resolvedExecutable,
      const ['--tvx-activate-existing'],
    );
    int? exitCode;
    try {
      exitCode = await activationProcess.exitCode.timeout(
        _remaining(
          _earlierDeadline(
            deadline,
            DateTime.now().add(const Duration(seconds: 5)),
          ),
        ),
      );
    } on TimeoutException {
      activationProcess.kill();
      try {
        await activationProcess.exitCode.timeout(const Duration(seconds: 2));
      } on Object {
        // The smoke report below records that activation did not exit cleanly.
      }
    }
    if (exitCode != 0) {
      throw StateError('再次启动应用没有唤醒现有托盘实例（exitCode=$exitCode）');
    }
    return <String, Object?>{
      'tray_restore_trigger': 'second_instance_activation',
      'tray_activation_process_exited': true,
      'tray_activation_exit_code': exitCode,
    };
  }

  Future<bool> _waitForWindowVisibility({
    required bool expected,
    required DateTime deadline,
  }) async {
    while (DateTime.now().isBefore(deadline)) {
      if (await windowManager.isVisible() == expected) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return await windowManager.isVisible() == expected;
  }

  Future<void> _prepareSmokeExit() async {
    _exitRequested = true;
    registerNativeWindowCloseHandler(null);
    try {
      await windowManager.setPreventClose(false);
    } on Object {
      // The final close below still has an exit(0) fallback.
    }
    final trayService = _trayService;
    if (trayService != null) await _disposeTrayService(trayService);
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
              'code': 'provider_preflight_failed',
              'stage': 'TRANSLATE',
              'hint_zh': '翻译服务暂时连不上，请检查服务地址、模型名和凭据后继续任务。',
              'retryable': false,
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
    final trayTaskWasActive = !submitted.terminal;
    final trayReport = smoke.checkTray
        ? await _checkTrayLifecycle(deadline)
        : const <String, Object?>{};
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
      if (smoke.checkTray) 'tray_task_active_before_close': trayTaskWasActive,
      ...trayReport,
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
    final trayTaskWasActive = _controller.view.state == MainState.running;
    final trayReport = smoke.checkTray
        ? await _checkTrayLifecycle(deadline)
        : const <String, Object?>{};
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
    final unsavedToolWindowReport = smoke.checkTray
        ? await _checkTrayUnsavedToolWindowGuard(taskId, deadline)
        : const <String, Object?>{};

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
      if (smoke.checkTray) 'tray_task_active_before_close': trayTaskWasActive,
      ...trayReport,
      ...unsavedToolWindowReport,
    };
  }

  Future<Map<String, Object?>> _checkTrayUnsavedToolWindowGuard(
    String taskId,
    DateTime deadline,
  ) async {
    await _focusMainWindow();
    await _openToolWindow(AppWindowType.taskProcessing, taskId: taskId);
    final windowKey = _toolWindowKey(
      AppWindowType.taskProcessing,
      taskId: taskId,
    );
    final childReadyDeadline = _earlierDeadline(
      deadline,
      DateTime.now().add(const Duration(seconds: 6)),
    );
    WindowController? controller;
    Object? lastChildError;
    var refusalEnabled = false;
    while (DateTime.now().isBefore(childReadyDeadline)) {
      controller = _toolWindows[windowKey];
      if (controller != null) {
        try {
          final result = await controller
              .invokeMethod<Object?>('window_smoke_set_close_refusal', const {
                'enabled': true,
              })
              .timeout(const Duration(milliseconds: 750));
          refusalEnabled =
              result is Map &&
              result['ok'] == true &&
              result['enabled'] == true;
          if (refusalEnabled) break;
        } on Object catch (error) {
          lastChildError = error;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (controller == null || !refusalEnabled) {
      throw StateError('任务处理窗未能进入关闭保护 smoke 状态：$lastChildError');
    }

    var keptMainVisible = false;
    var keptToolWindow = false;
    var serviceAlive = false;
    var cleanupOk = false;
    var refusalReason = '';
    try {
      _trayHideAttempted = false;
      _trayHideError = '';
      await _focusMainWindow();
      await windowManager.close();
      final refusalDeadline = _earlierDeadline(
        deadline,
        DateTime.now().add(const Duration(seconds: 4)),
      );
      while (_trayHideError.isEmpty &&
          DateTime.now().isBefore(refusalDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      keptMainVisible = await windowManager.isVisible();
      keptToolWindow = identical(_toolWindows[windowKey], controller);
      refusalReason = _trayHideError;
      final client = _service.client;
      if (client != null) {
        final health = await client.health().timeout(_remaining(deadline));
        serviceAlive = health.status.trim().isNotEmpty;
      }
    } finally {
      if (!await windowManager.isVisible()) await _focusMainWindow();
      try {
        await controller
            .invokeMethod<Object?>('window_smoke_set_close_refusal', const {
              'enabled': false,
            })
            .timeout(const Duration(seconds: 2));
      } on Object {
        // Cleanup below also drops a child that already exited unexpectedly.
      }
      cleanupOk = await _closeToolWindows();
    }

    if (!_trayHideAttempted ||
        refusalReason.isEmpty ||
        !keptMainVisible ||
        !keptToolWindow ||
        !serviceAlive ||
        !cleanupOk) {
      throw StateError(
        '未保存字幕关闭保护失败'
        '（hideAttempted=$_trayHideAttempted, reason=$refusalReason, '
        'mainVisible=$keptMainVisible, toolRetained=$keptToolWindow, '
        'serviceAlive=$serviceAlive, cleanup=$cleanupOk）',
      );
    }

    return <String, Object?>{
      'tray_unsaved_close_guard_checked': true,
      'tray_unsaved_close_kept_main_visible': keptMainVisible,
      'tray_unsaved_close_kept_tool_window': keptToolWindow,
      'tray_unsaved_close_service_alive': serviceAlive,
      'tray_unsaved_close_reason': refusalReason,
      'tray_unsaved_close_cleanup_ok': cleanupOk,
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
}
