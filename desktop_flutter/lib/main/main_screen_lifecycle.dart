part of '../main.dart';

extension _MainScreenLifecycle on _MainScreenState {
  void _syncBridgeState() {
    final view = _controller.view;
    _notificationObserver.handle(view);
    _updateTrayPresentation(view);
    widget.store.replace(
      widget.store.value.copyWith(
        translationDefaultLabel: view.translationLabel,
        translationConfigured: view.translationConfigured,
        asrDefaultLabel: view.asrLabel,
        asrConfigured: view.asrConfigured,
      ),
    );
  }

  Future<void> _initializeDesktopLifecycle() async {
    final trayService = widget.desktopTrayService ?? SystemDesktopTrayService();
    _trayService = trayService;
    _trayActionSubscription = trayService.actions.listen(_handleTrayAction);
    final initialized = await trayService.initialize(
      _trayPresentation(_controller.view),
    );
    if (!mounted || !initialized) {
      await _disposeTrayService(trayService);
      return;
    }
    try {
      await windowManager.setPreventClose(true);
      _trayReady = true;
      _updateTrayPresentation(_controller.view);
    } on Object {
      await _disposeTrayService(trayService);
    }
  }

  Future<void> _disposeTrayService(DesktopTrayService trayService) async {
    _trayReady = false;
    await _trayActionSubscription?.cancel();
    _trayActionSubscription = null;
    if (identical(_trayService, trayService)) _trayService = null;
    await trayService.dispose();
  }

  void _updateTrayPresentation(MainWindowViewModel view) {
    final trayService = _trayService;
    if (!_trayReady || trayService == null) return;
    unawaited(
      trayService.update(_trayPresentation(view)).catchError((_) {
        // A temporary tray update failure must not affect the active task.
      }),
    );
  }

  DesktopTrayPresentation _trayPresentation(MainWindowViewModel view) {
    final activeTasks = _activeTasks();
    final activeTask = activeTasks.isEmpty ? null : activeTasks.first;
    final activeAsrOperation = _activeAsrOperations().firstOrNull;
    final taskName = _shortTrayName(activeTask?.displayName ?? '');
    final taskSuffix = taskName.isEmpty ? '' : ' · $taskName';
    final status = activeTask != null
        ? activeTask.status == 'QUEUED'
              ? '等待制作$taskSuffix'
              : activeTask.status == 'CANCEL_REQUESTED'
              ? '正在取消$taskSuffix'
              : '正在制作$taskSuffix'
        : activeAsrOperation != null
        ? asrTrayStatusLabel(activeAsrOperation)
        : switch (view.state) {
            MainState.running => view.canceling ? '正在取消任务' : '正在制作字幕',
            MainState.completed => '本次任务已完成',
            MainState.failed => '任务需要处理',
            MainState.empty when view.homeTaskReminder != null => '有任务可以继续',
            _ => '空闲 · 可以开始新任务',
          };
    return DesktopTrayPresentation(
      statusLabel: status,
      toolTip: 'TransVortex · $status',
    );
  }

  List<TaskSummary> _activeTasks() {
    final snapshot = _service.snapshot.desktopSnapshot;
    if (snapshot == null) return const [];
    return snapshot.tasks
        .where((task) => task.isActive && !task.isTerminal)
        .toList(growable: false);
  }

  List<AsrOperationStatus> _activeAsrOperations() {
    final snapshot = _service.snapshot.desktopSnapshot;
    if (snapshot == null) return const [];
    return snapshot.asrOperations
        .where((operation) => operation.active)
        .toList(growable: false);
  }

  String _shortTrayName(String value) {
    final normalized = value.trim();
    if (normalized.length <= 26) return normalized;
    return '${normalized.substring(0, 25)}…';
  }

  void _handleTrayAction(DesktopTrayAction action) {
    switch (action) {
      case DesktopTrayAction.showMain:
        unawaited(_focusMainWindow());
        return;
      case DesktopTrayAction.openTasks:
        unawaited(_openTaskProcessingFromTray());
        return;
      case DesktopTrayAction.exitApp:
        unawaited(_requestAppExit());
        return;
    }
  }

  Future<void> _openTaskProcessingFromTray() async {
    await _focusMainWindow();
    await _openToolWindow(AppWindowType.taskProcessing);
  }

  Future<void> _handleNativeWindowClose() async {
    _trayCloseEventObserved = true;
    if (!_trayReady || _exitRequested) return;
    await _hideToTray();
  }

  Future<void> _hideToTray() async {
    if (!_trayReady || _exitRequested || _trayHideInProgress) return;
    _trayHideInProgress = true;
    try {
      _trayHideAttempted = true;
      _trayHideError = '';
      if (!await _closeToolWindows()) {
        _trayHideError = '工作台或工具窗口尚未安全关闭';
        return;
      }
      try {
        await windowManager.hide();
        await _closeApplicationSettings(animate: false);
      } on Object catch (error) {
        _trayHideError = '$error';
        // If hiding fails, keep the visible app alive rather than shutting down.
      }
    } finally {
      _trayHideInProgress = false;
    }
  }

  Future<void> _requestAppExit() async {
    if (_exitRequested || _exitRequestInProgress) return;
    _exitRequestInProgress = true;
    try {
      final shouldCancelActiveWork = _hasActiveWork;
      if (shouldCancelActiveWork) {
        await _focusMainWindow();
        final confirmed = await _confirmCancelAndExit();
        if (confirmed != true) return;
      }

      if (!await _closeToolWindows()) return;
      if (shouldCancelActiveWork && !await _cancelActiveTasksForExit()) return;
      _exitRequested = true;
      try {
        await windowManager.hide().timeout(_MainScreenState._exitPluginTimeout);
      } on Object {
        // Continue with destruction if the native hide acknowledgement is late.
      }
      try {
        await windowManager
            .setPreventClose(false)
            .timeout(_MainScreenState._exitPluginTimeout);
      } on Object {
        // destroy() below bypasses prevent-close if this best-effort call fails.
      }
      final trayService = _trayService;
      await Future.wait([
        _bestEffortExitCleanup(
          _service.shutdown(
            rpcTimeout: _MainScreenState._exitRpcTimeout,
            exitTimeout: _MainScreenState._exitProcessTimeout,
          ),
        ),
        if (trayService != null)
          _bestEffortExitCleanup(
            _disposeTrayService(
              trayService,
            ).timeout(_MainScreenState._exitPluginTimeout),
          ),
      ]);
      try {
        await windowManager.destroy().timeout(
          _MainScreenState._exitPluginTimeout,
        );
      } on Object {
        exit(0);
      }
    } finally {
      if (!_exitRequested) _exitRequestInProgress = false;
    }
  }

  Future<void> _bestEffortExitCleanup(Future<void> cleanup) async {
    try {
      await cleanup;
    } on Object {
      // The process exit below is the final cleanup boundary.
    }
  }

  Future<bool?> _confirmCancelAndExit() {
    if (!mounted) return Future<bool?>.value(false);
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: T.surface,
        surfaceTintColor: T.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rMd),
          side: const BorderSide(color: T.line),
        ),
        title: Row(
          children: [
            const Icon(Icons.hourglass_top_rounded, color: T.accentStrong),
            const SizedBox(width: T.s8),
            Text('后台任务仍在进行', style: T.tSection),
          ],
        ),
        content: Text(
          '关闭窗口会继续留在托盘；如果现在退出，TransVortex 会先取消进行中的字幕任务和识别环境下载。',
          style: T.tBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续后台'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('取消任务并退出'),
          ),
        ],
      ),
    );
  }

  Future<bool> _cancelActiveTasksForExit() async {
    try {
      await _service.start();
      final client = _service.client;
      if (client == null) throw StateError('本地服务未连接');
      final taskIds = <String>{
        for (final task in _activeTasks()) task.taskId,
        if (_controller.view.state == MainState.running &&
            _controller.view.taskId?.trim().isNotEmpty == true)
          _controller.view.taskId!.trim(),
      };
      for (final taskId in taskIds) {
        await client.cancel(taskId);
      }
      final asrOperations = _activeAsrOperations();
      for (final operation in asrOperations) {
        await client.asrOperationCancel(operation.id);
      }
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      for (final operation in asrOperations) {
        while (DateTime.now().isBefore(deadline)) {
          final latest = await client.asrOperation(operation.id);
          if (!latest.active) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      return true;
    } on Object catch (error) {
      _toast('取消任务失败，应用将继续在后台：$error');
      return false;
    }
  }

  bool get _hasActiveWork {
    return _controller.view.state == MainState.running ||
        _activeTasks().isNotEmpty ||
        _activeAsrOperations().isNotEmpty;
  }

  Future<bool> _closeToolWindows() async {
    if (_toolWindows.isEmpty) return true;
    await _pruneClosedToolWindows();
    final entries = _toolWindows.entries.toList(growable: false);
    for (final entry in entries) {
      final controller = entry.value;
      try {
        await controller
            .invokeMethod<Object?>('window_ping')
            .timeout(const Duration(seconds: 2));
      } on Object {
        if (await _toolWindowStillExists(controller)) {
          try {
            await controller.show().timeout(const Duration(seconds: 2));
          } on Object {
            // Keeping the main window visible is the safe fallback.
          }
          return false;
        }
        _toolWindows.remove(entry.key);
        continue;
      }

      Object? request;
      try {
        request = await controller.invokeMethod<Object?>(
          'window_request_close',
        );
      } on Object {
        if (await _toolWindowStillExists(controller)) return false;
        _toolWindows.remove(entry.key);
        continue;
      }
      if (!windowCloseResultAccepted(request)) {
        try {
          await controller
              .invokeMethod<void>('window_focus')
              .timeout(const Duration(seconds: 2));
        } on Object {
          // The refusal is authoritative even if focus restoration fails.
        }
        return false;
      }
      try {
        final result = await controller
            .invokeMethod<Object?>('window_close')
            .timeout(const Duration(seconds: 2));
        if (!windowCloseResultAccepted(result)) return false;
      } on Object {
        if (await _toolWindowStillExists(controller)) return false;
      }
      _toolWindows.remove(entry.key);
    }
    return true;
  }

  Future<void> _pruneClosedToolWindows() async {
    try {
      final windows = await WindowController.getAll().timeout(
        _MainScreenState._toolWindowInventoryTimeout,
      );
      final liveWindowIds = windows.map((window) => window.windowId).toSet();
      _toolWindows.removeWhere(
        (_, controller) => !liveWindowIds.contains(controller.windowId),
      );
    } on Object {
      // Fall back to the per-window close checks when inventory is unavailable.
    }
  }

  Future<bool> _toolWindowStillExists(WindowController controller) async {
    try {
      final windows = await WindowController.getAll().timeout(
        const Duration(seconds: 2),
      );
      return windows.any((window) => window.windowId == controller.windowId);
    } on Object {
      // An uncertain child state must not allow the app to hide or exit.
      return true;
    }
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
}
