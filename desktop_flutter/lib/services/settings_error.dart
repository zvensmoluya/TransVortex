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
    if (error.code == 'network_config_conflict') {
      return '网络设置仍在其他窗口变化，请稍后再次保存。';
    }
    if (error.code == 'operation_active') {
      return '已有识别环境任务正在进行，请先等待完成或取消当前任务。';
    }
    if (error.code == 'storage_change_requires_migration') {
      return '当前位置已有识别资源或下载断点；当前版本不会自动搬动大文件，请继续使用该位置。';
    }
    if (error.code == 'storage_target_has_managed_data') {
      return '所选文件夹已包含另一套识别资源，请选择新的专用文件夹。';
    }
    if (error.code == 'invalid_storage_root') {
      return '请选择本地磁盘中的专用文件夹，不要直接选择磁盘根目录。';
    }
    if (error.code == 'storage_root_unwritable') {
      return '所选文件夹无法写入，请检查权限或改选其他位置。';
    }
    if (error.code == 'storage_root_unavailable') {
      return '识别资源位置当前不可用，请重新连接目标磁盘或改选其他位置。';
    }
    if (error.code == 'storage_config_invalid') {
      return '识别资源位置配置无效，请重新选择保存位置。';
    }
    if (error.code == 'insufficient_disk_space') {
      return '目标盘剩余空间不足，请清理空间或更改识别资源位置。';
    }
    if (error.code == 'component_remove_failed') {
      return '无法删除识别资源；请关闭正在使用它的程序后重试。';
    }
    if (error.code == 'component_not_found') {
      return '这个识别资源已不存在，当前状态已自动同步。';
    }
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
