import 'package:flutter/services.dart';

import 'app_service_client.dart';
import 'local_service_controller.dart';
import 'window_state_bridge.dart';

/// Uses the main window's Local Service connection when available and starts a
/// local fallback only for isolated settings hosts and tests.
class SettingsServiceTransport implements AppServiceTransport {
  SettingsServiceTransport({
    required WindowStateBridge bridge,
    required this.service,
  }) : _bridge = WindowBridgeTransport(bridge);

  final WindowBridgeTransport _bridge;
  final LocalServiceController service;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    try {
      return await _bridge.call(method, params, timeout);
    } on Object catch (error) {
      if (!_shouldUseLocalService(error)) rethrow;
    }
    await service.start();
    final client = service.client;
    if (client == null) {
      throw PlatformException(
        code: 'service_unavailable',
        message: '本地服务暂时不可用，请稍后重试。',
      );
    }
    return client.call(method, params, timeout);
  }

  @override
  Future<void> close() async {}

  bool _shouldUseLocalService(Object error) {
    if (error is PlatformException) {
      final message = error.message ?? '';
      return error.code == 'service_unavailable' ||
          message.contains('Local Service caller') ||
          '$error'.contains('CHANNEL_UNREGISTERED') ||
          '$error'.contains('WindowChannelException');
    }
    final text = '$error';
    return text.contains('CHANNEL_UNREGISTERED') ||
        text.contains('WindowChannelException');
  }
}
