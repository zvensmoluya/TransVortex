import '../services/app_service_client.dart';

class NetworkSettingsValidationException implements Exception {
  const NetworkSettingsValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

int resolveNetworkProxyPort({
  required String mode,
  required String proxyPortText,
  required int fallbackPort,
}) {
  if (!const {'system', 'direct', 'local_proxy'}.contains(mode)) {
    throw const NetworkSettingsValidationException('请选择有效的网络连接方式。');
  }
  final text = proxyPortText.trim();
  final parsed = text.isEmpty ? 0 : int.tryParse(text);
  if (mode == 'local_proxy') {
    if (parsed == null || parsed < 1 || parsed > 65535) {
      throw const NetworkSettingsValidationException(
        '请填写 1 到 65535 之间的本地代理端口。',
      );
    }
    return parsed;
  }
  if (parsed != null && parsed >= 0 && parsed <= 65535) return parsed;
  return fallbackPort >= 0 && fallbackPort <= 65535 ? fallbackPort : 0;
}

Future<DesktopSnapshot> saveNetworkSettingsDraft({
  required AppServiceClient client,
  required DesktopSnapshot snapshot,
  required String mode,
  required String proxyPortText,
}) async {
  final retainedPort = resolveNetworkProxyPort(
    mode: mode,
    proxyPortText: proxyPortText,
    fallbackPort: snapshot.networkSettings.proxyPort,
  );

  Future<DesktopSnapshot> save(DesktopSnapshot base) async {
    final result = await client.networkSettingsSave(
      mode: mode,
      proxyPort: retainedPort,
      expectedVersion: base.pipelineFileVersion,
    );
    final network = _map(result['network']);
    final version = _map(result['pipeline_file_version']);
    return base.copyWith(
      config: <String, Object?>{
        ...base.config,
        'network': network.isEmpty
            ? {'mode': mode, 'proxy_port': retainedPort}
            : network,
        if (version.isNotEmpty) 'pipeline_file_version': version,
      },
    );
  }

  return save(snapshot);
}

bool isNetworkSettingsConflict(Object error) =>
    error is RpcRemoteException && error.code == 'network_config_conflict';

String networkSettingsLabel(String mode, String proxyPortText) {
  return switch (mode) {
    'direct' => '直连',
    'local_proxy' =>
      proxyPortText.trim().isEmpty
          ? '本地代理'
          : '本地代理 · 127.0.0.1:${proxyPortText.trim()}',
    _ => '跟随系统',
  };
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.map((key, item) => MapEntry('$key', item)) : const {};
