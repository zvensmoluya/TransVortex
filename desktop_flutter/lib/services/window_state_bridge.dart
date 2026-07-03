import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

import '../model/spike_state.dart';
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

  void attachServiceCaller(
    Future<Object?> Function(String method, Map<String, Object?> params) caller,
  ) {
    _serviceCaller = caller;
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
      default:
        throw PlatformException(
          code: 'unknown_method',
          message: 'Unknown window state method: ${call.method}',
        );
    }
  }

  Future<AppSpikeState> requestSnapshot() async {
    final channel = _channel;
    if (channel == null) return store.value;
    try {
      final result = await channel.invokeMethod<Object?>('state.snapshot');
      return AppSpikeState.fromJson(result);
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
      store.replace(AppSpikeState.fromJson(result));
    } on Object {
      // Keep the local optimistic state; the spike UI surfaces this manually.
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
      store.replace(AppSpikeState.fromJson(result));
    } on Object {
      // Keep the local optimistic state; the spike UI surfaces this manually.
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
    return channel.invokeMethod<Object?>('service.call', {
      'method': method,
      'params': params,
    });
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
