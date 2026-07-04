import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../model/main_window_controller.dart';
import '../model/session.dart';

abstract class TaskNotificationService {
  Future<void> notifyCompleted(MainWindowViewModel view);
  Future<void> notifyFailed(MainWindowViewModel view);
}

typedef NotificationActivationHandler =
    FutureOr<void> Function(String? payload);
typedef NotificationGate = FutureOr<bool> Function(MainWindowViewModel view);

class NoopTaskNotificationService implements TaskNotificationService {
  const NoopTaskNotificationService();

  @override
  Future<void> notifyCompleted(MainWindowViewModel view) async {}

  @override
  Future<void> notifyFailed(MainWindowViewModel view) async {}
}

class WindowsTaskNotificationService implements TaskNotificationService {
  WindowsTaskNotificationService({
    FlutterLocalNotificationsWindows? plugin,
    WindowsNotificationSink? sink,
    NotificationActivationHandler? onActivated,
    NotificationGate? shouldNotify,
  }) : this._(plugin, sink, onActivated, shouldNotify);

  WindowsTaskNotificationService._(
    this._plugin,
    this._sink,
    this._onActivated,
    this._shouldNotify,
  );

  static const appUserModelId = 'TransVortex.Desktop';
  static const activationGuid = '4ad03d91-3bd9-4d27-8c15-6f0b4b534a26';

  FlutterLocalNotificationsWindows? _plugin;
  WindowsNotificationSink? _sink;
  final NotificationActivationHandler? _onActivated;
  final NotificationGate? _shouldNotify;
  Future<bool>? _initializing;
  bool _available = false;

  Future<bool> initialize() {
    return _initializing ??= _initialize();
  }

  Future<bool> _initialize() async {
    try {
      final existingSink = _sink;
      if (existingSink != null) {
        _available = await existingSink.initialize();
        return _available;
      }
      if (defaultTargetPlatform != TargetPlatform.windows) return false;
      final plugin = _plugin ??= FlutterLocalNotificationsWindows();
      final sink = _sink ??= PluginWindowsNotificationSink(plugin);
      _available = await plugin.initialize(
        settings: const WindowsInitializationSettings(
          appName: 'TransVortex',
          appUserModelId: appUserModelId,
          guid: activationGuid,
        ),
        onDidReceiveNotificationResponse: (response) {
          handleActivation(response.payload ?? response.actionId);
        },
      );
      _available = _available && await sink.initialize();
    } on Object {
      _available = false;
    }
    return _available;
  }

  @override
  Future<void> notifyCompleted(MainWindowViewModel view) async {
    if (!await _shouldSend(view)) return;
    if (!await initialize()) return;
    await _sink!.show(
      id: _notificationId(view, offset: 1),
      title: '字幕已生成',
      body: _sourceName(view),
      payload: _payload(view, 'completed'),
      notificationDetails: WindowsNotificationDetails(
        duration: WindowsNotificationDuration.long,
        actions: const [
          WindowsAction(content: '打开 TransVortex', arguments: 'open-app'),
        ],
      ),
    );
  }

  @override
  Future<void> notifyFailed(MainWindowViewModel view) async {
    if (!await _shouldSend(view)) return;
    if (!await initialize()) return;
    await _sink!.show(
      id: _notificationId(view, offset: 2),
      title: '制作失败',
      body: view.failure?.reason ?? _sourceName(view),
      payload: _payload(view, 'failed'),
      notificationDetails: WindowsNotificationDetails(
        duration: WindowsNotificationDuration.long,
        actions: const [WindowsAction(content: '查看问题', arguments: 'open-app')],
      ),
    );
  }

  int _notificationId(MainWindowViewModel view, {required int offset}) {
    final key = _taskPayload(view);
    return Object.hash('transvortex', key, offset) & 0x7fffffff;
  }

  String _taskPayload(MainWindowViewModel view) {
    final taskId = view.taskId;
    if (taskId != null && taskId.isNotEmpty) return taskId;
    final fallback = view.source?.path ?? view.source?.name ?? 'current';
    return 'local-${fallback.hashCode & 0x7fffffff}';
  }

  String _payload(MainWindowViewModel view, String status) {
    return 'task:${_taskPayload(view)}:$status';
  }

  String _sourceName(MainWindowViewModel view) {
    final name = view.source?.name;
    if (name == null || name.isEmpty) return 'TransVortex 任务';
    return name;
  }

  Future<bool> _shouldSend(MainWindowViewModel view) async {
    final gate = _shouldNotify;
    if (gate == null) return true;
    try {
      return await Future.value(gate(view));
    } on Object {
      return true;
    }
  }

  @visibleForTesting
  void handleActivation(String? payload) {
    final callback = _onActivated;
    if (callback != null) unawaited(Future.sync(() => callback(payload)));
  }
}

abstract class WindowsNotificationSink {
  Future<bool> initialize();

  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required WindowsNotificationDetails notificationDetails,
  });
}

class PluginWindowsNotificationSink implements WindowsNotificationSink {
  PluginWindowsNotificationSink(this._plugin);

  final FlutterLocalNotificationsWindows _plugin;

  @override
  Future<bool> initialize() async => true;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required WindowsNotificationDetails notificationDetails,
  }) {
    return _plugin.show(
      id: id,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: notificationDetails,
    );
  }
}

class SmokeWindowsNotificationSink implements WindowsNotificationSink {
  SmokeWindowsNotificationSink() : _plugin = FlutterLocalNotificationsWindows();

  final FlutterLocalNotificationsWindows _plugin;
  late final PluginWindowsNotificationSink _delegate =
      PluginWindowsNotificationSink(_plugin);
  int initializeCalls = 0;
  int showCalls = 0;
  int? lastId;
  String lastTitle = '';
  String lastPayload = '';
  bool _initialized = false;

  @override
  Future<bool> initialize() async {
    initializeCalls += 1;
    if (_initialized) return true;
    _initialized = await _plugin.initialize(
      settings: const WindowsInitializationSettings(
        appName: 'TransVortex',
        appUserModelId: WindowsTaskNotificationService.appUserModelId,
        guid: WindowsTaskNotificationService.activationGuid,
      ),
    );
    if (!_initialized) return false;
    return _delegate.initialize();
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required WindowsNotificationDetails notificationDetails,
  }) async {
    showCalls += 1;
    lastId = id;
    lastTitle = title;
    lastPayload = payload;
    await _delegate.show(
      id: id,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: notificationDetails,
    );
  }
}

class TaskNotificationObserver {
  TaskNotificationObserver(this._service);

  final TaskNotificationService _service;
  MainState? _lastState;
  String? _lastNotificationKey;
  String? _lastSourcePath;
  bool _sentCompleted = false;
  bool _sentFailed = false;

  void handle(MainWindowViewModel view) {
    final sourcePath = view.source?.path;
    final notificationKey = view.taskId ?? sourcePath;
    if (notificationKey != _lastNotificationKey ||
        sourcePath != _lastSourcePath) {
      _sentCompleted = false;
      _sentFailed = false;
      _lastNotificationKey = notificationKey;
      _lastSourcePath = sourcePath;
    }

    final cameFromRunning = _lastState == MainState.running;
    if (cameFromRunning && view.state == MainState.completed) {
      if (!_sentCompleted) {
        _sentCompleted = true;
        _sentFailed = false;
        _lastState = view.state;
        _notifyCompleted(view);
        return;
      }
    }

    if (cameFromRunning && view.state == MainState.failed) {
      if (!_sentFailed) {
        _sentFailed = true;
        _sentCompleted = false;
        _lastState = view.state;
        _notifyFailed(view);
        return;
      }
    }

    _lastState = view.state;
  }

  void _notifyCompleted(MainWindowViewModel view) {
    unawaited(_service.notifyCompleted(view));
  }

  void _notifyFailed(MainWindowViewModel view) {
    unawaited(_service.notifyFailed(view));
  }
}
