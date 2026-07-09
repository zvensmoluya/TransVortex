import 'package:flutter/services.dart';

import 'app_service_client.dart';

/// Localizes an error raised while loading or saving settings into a
/// user-facing (Chinese) message. Shared by the settings window (ASR /
/// diagnostics) and the translation settings controller so the wording — which
/// widget tests assert on — stays identical across entry points.
String friendlySettingsError(Object error) {
  if (error is PlatformException) {
    final rawMessage = error.message ?? '';
    if (rawMessage.contains('Local Service caller')) {
      return '本地服务未连接，请稍后重试。';
    }
    if (error.code == 'service_unavailable') {
      final message = rawMessage.trim();
      return message.isEmpty ? '本地服务暂时不可用，请稍后重试。' : message;
    }
    final message = rawMessage.trim();
    if (message.isNotEmpty) return message;
  }
  if (error is RpcRemoteException) {
    final details = _map(error.details);
    final info = _map(details['error_info']);
    final hint =
        _str(info['hint_zh']) ??
        _str(info['hint']) ??
        _str(details['hint_zh']) ??
        _str(details['hint']);
    if (hint != null && hint.isNotEmpty) return hint;
    final message = error.message.trim();
    if (message.isNotEmpty) return message;
  }
  final text = '$error';
  if (text.contains('CHANNEL_UNREGISTERED') ||
      text.contains('WindowChannelException')) {
    return '本地服务未连接，请稍后重试。';
  }
  return text;
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.map((k, v) => MapEntry('$k', v)) : const {};

String? _str(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return '$value';
}
