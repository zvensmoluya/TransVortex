import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

import '../model/window_state.dart';
import 'app_service_client.dart';

const stateChannelName = 'transvortex.state';

class WindowStateBridge {
  WindowStateBridge.main(this.store) : _channel = null;

  WindowStateBridge.child(this.store)
    : _channel = const WindowMethodChannel(
        stateChannelName,
        mode: ChannelMode.unidirectional,
      );

  final WindowStateStore store;
  final WindowMethodChannel? _channel;
  Future<Object?> Function(String method, Map<String, Object?> params)?
  _serviceCaller;
  Future<void> Function(AppWindowArgs args)? _toolWindowOpener;

  void attachServiceCaller(
    Future<Object?> Function(String method, Map<String, Object?> params) caller,
  ) {
    _serviceCaller = caller;
  }

  void attachToolWindowOpener(
    Future<void> Function(AppWindowArgs args) opener,
  ) {
    _toolWindowOpener = opener;
  }

  Future<void> initializeMain() async {
    const channel = WindowMethodChannel(
      stateChannelName,
      mode: ChannelMode.unidirectional,
    );
    try {
      await channel.setMethodCallHandler(_handleMainMessage);
    } on WindowChannelException {
      // In tests or unsupported hosts this leaves the in-memory store usable.
    }
  }

  Future<void> initializeChild() async {
    final snapshot = await requestSnapshot();
    store.replace(snapshot);
  }

  Future<dynamic> _handleMainMessage(MethodCall call) async {
    switch (call.method) {
      case 'state.snapshot':
        return store.value.toJson();
      case 'state.setTranslationDefault':
        final args = _asMap(call.arguments);
        store.setTranslationDefault(
          args['label'] as String? ?? '需配置',
          configured: args['configured'] as bool? ?? true,
        );
        return store.value.toJson();
      case 'state.setAsrDefault':
        final args = _asMap(call.arguments);
        store.setAsrDefault(
          args['label'] as String? ?? '本机',
          configured: args['configured'] as bool? ?? true,
        );
        return store.value.toJson();
      case 'service.call':
        final args = _asMap(call.arguments);
        final method = args['method'];
        final params = _asStringMap(args['params']);
        final caller = _serviceCaller;
        if (caller == null || method is! String || method.trim().isEmpty) {
          throw PlatformException(
            code: 'service_unavailable',
            message: 'Local Service caller is not attached',
          );
        }
        return caller(method.trim(), params);
      case 'tool.open':
        final args = _asMap(call.arguments);
        final type = AppWindowTypeLabel.maybeFromId(args['type'] as String?);
        final taskId = _optionalString(args['task_id'] ?? args['taskId']);
        final opener = _toolWindowOpener;
        if (type == null || opener == null) {
          throw PlatformException(
            code: 'tool_unavailable',
            message: 'Tool window opener is not attached',
          );
        }
        await opener(AppWindowArgs(type: type, taskId: taskId));
        return {'ok': true, 'type': type.id, 'task_id': ?taskId};
      default:
        throw PlatformException(
          code: 'unknown_method',
          message: 'Unknown window state method: ${call.method}',
        );
    }
  }

  Future<AppWindowState> requestSnapshot() async {
    final channel = _channel;
    if (channel == null) return store.value;
    try {
      final result = await channel.invokeMethod<Object?>('state.snapshot');
      return AppWindowState.fromJson(result);
    } on Object {
      return store.value;
    }
  }

  Future<void> setTranslationDefault(
    String label, {
    required bool configured,
  }) async {
    final channel = _channel;
    store.setTranslationDefault(label, configured: configured);
    if (channel == null) return;
    try {
      final result = await channel.invokeMethod<Object?>(
        'state.setTranslationDefault',
        {'label': label, 'configured': configured},
      );
      store.replace(AppWindowState.fromJson(result));
    } on Object {
      // Keep the local optimistic state; the main window refreshes from service snapshots.
    }
  }

  Future<void> setAsrDefault(String label, {required bool configured}) async {
    final channel = _channel;
    store.setAsrDefault(label, configured: configured);
    if (channel == null) return;
    try {
      final result = await channel.invokeMethod<Object?>(
        'state.setAsrDefault',
        {'label': label, 'configured': configured},
      );
      store.replace(AppWindowState.fromJson(result));
    } on Object {
      // Keep the local optimistic state; the main window refreshes from service snapshots.
    }
  }

  Future<Object?> callService(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final caller = _serviceCaller;
    if (caller != null) {
      return caller(method, params);
    }
    final channel = _channel;
    if (channel == null) {
      throw PlatformException(
        code: 'service_unavailable',
        message: 'Local Service caller is not attached',
      );
    }
    try {
      return await channel.invokeMethod<Object?>('service.call', {
        'method': method,
        'params': params,
      });
    } on WindowChannelException catch (error) {
      throw PlatformException(
        code: 'service_unavailable',
        message: 'Local Service caller is not available',
        details: error.message,
      );
    }
  }

  Future<void> openToolWindow(AppWindowType type, {String? taskId}) async {
    final args = AppWindowArgs(type: type, taskId: taskId);
    final opener = _toolWindowOpener;
    if (opener != null) {
      await opener(args);
      return;
    }
    final channel = _channel;
    if (channel == null) {
      throw PlatformException(
        code: 'tool_unavailable',
        message: 'Tool window opener is not attached',
      );
    }
    try {
      await channel.invokeMethod<Object?>('tool.open', {
        'type': args.type.id,
        if (args.taskId != null) 'task_id': args.taskId,
      });
    } on WindowChannelException catch (error) {
      throw PlatformException(
        code: 'tool_unavailable',
        message: 'Tool window opener is not available',
        details: error.message,
      );
    }
  }

  static Map<Object?, Object?> _asMap(Object? value) {
    return value is Map ? value : const <Object?, Object?>{};
  }

  static Map<String, Object?> _asStringMap(Object? value) {
    if (value is Map) {
      return value.map((key, item) => MapEntry('$key', item));
    }
    return const <String, Object?>{};
  }
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

class WindowBridgeTransport implements AppServiceTransport {
  WindowBridgeTransport(this.bridge);

  final WindowStateBridge bridge;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) {
    final result = bridge.callService(method, params);
    return timeout == null ? result : result.timeout(timeout);
  }

  @override
  Future<void> close() async {}
}
