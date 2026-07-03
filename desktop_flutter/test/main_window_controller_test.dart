import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/model/main_window_controller.dart';
import 'package:transvortex_desktop_flutter/model/session.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/local_service_controller.dart';

void main() {
  test('controller derives empty and ready states from source and snapshot', () async {
    final controller = MainWindowController(service: _readyController());
    await controller.startService();

    expect(controller.view.state, MainState.empty);

    controller.pickSource(r'D:\movie.mp4');

    expect(controller.view.state, MainState.ready);
    expect(controller.view.translationLabel, 'RealProvider · real-model');
    expect(controller.view.asrLabel, '本机 · large-v3');
  });

  test('controller blocks unsupported subtitle input before payload build', () async {
    final controller = MainWindowController(service: _readyController());
    await controller.startService();

    controller.pickSource(r'D:\subtitle.ass');

    expect(controller.view.state, MainState.failed);
    expect(controller.view.failure?.reason, contains('只支持 SRT'));
    expect(() => controller.buildRunRequest(), throwsStateError);
  });

  test('controller builds run payload from real snapshot and draft', () async {
    final controller = MainWindowController(service: _readyController());
    await controller.startService();
    controller.pickSource(r'D:\movie.mp4');

    final payload = controller.buildRunRequest();
    final overrides = payload['overrides'] as Map<String, Object?>;

    expect(payload['input_type'], 'video_asr_translate');
    expect(payload['provider'], 'RealProvider');
    expect(payload['model'], 'real-model');
    expect(overrides['output_format'], 'both');
    expect(overrides['subtitle_quality_mode'], 'balanced');
    expect(overrides['memory_bootstrap_enabled'], isTrue);
    expect(overrides['memory_patch_enabled'], isTrue);
    expect(overrides['asr_provider'], 'local');
    expect(overrides['asr_model'], 'large-v3');
  });

  test('controller maps provider errors to translation recovery action', () {
    final controller = MainWindowController(service: _readyController());

    controller.pickSource(r'D:\movie.mp4');
    controller.applyFailureForTesting(
      RpcRemoteException(
        'routing_provider_missing',
        'provider not found',
        details: {
          'error_info': {
            'code': 'routing_provider_missing',
            'hint_zh': '翻译服务还没配置好。',
          },
        },
      ),
    );

    expect(controller.view.state, MainState.failed);
    expect(controller.view.failure?.reason, '翻译服务还没配置好。');
    expect(
      controller.view.failure?.target,
      MainRecoveryTarget.translationSettings,
    );
  });
}

LocalServiceController _readyController() {
  return LocalServiceController(
    sessionFactory: () async => _FakeHandle(_desktopSnapshot()),
  );
}

DesktopSnapshot _desktopSnapshot() {
  return DesktopSnapshot.fromJson({
    'config': {
      'routing': {
        'primary': {'provider': 'RealProvider', 'model': 'real-model'},
        'fallback': [
          {'provider': 'FallbackProvider', 'model': 'fallback-model'},
        ],
      },
      'pipeline': {'asr_provider': 'local'},
      'providers': [
        {
          'name': 'RealProvider',
          'has_key': true,
          'base_url': 'https://example.com/v1',
          'api_type': 'openai-compatible',
          'compat_mode': 'openai_chat',
          'credential_id': 'RealProvider',
          'models': ['real-model'],
        },
      ],
      'asr_providers': {
        'local': {
          'name': 'local',
          'kind': 'local_inprocess',
          'protocol': 'faster_whisper',
          'model': 'large-v3',
          'has_key': true,
        },
      },
    },
    'tasks': [],
    'runtime': {},
    'environment': {},
  });
}

class _FakeHandle implements LocalServiceHandle {
  _FakeHandle(DesktopSnapshot snapshot)
    : client = AppServiceClient(
        _FakeTransport({
          'service.info': {
            'service': 'transvortex.app_service',
            'protocol_version': 1,
            'app_version': 'test',
            'capabilities': ['desktop_snapshot'],
          },
          'service.health': {
            'service': 'transvortex.app_service',
            'status': 'healthy',
            'runtime': {'active': null},
            'pump': {'enabled': true},
          },
          'desktop.snapshot': snapshot.raw,
        }),
      );

  final _exit = Completer<int>();

  @override
  final AppServiceClient client;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> shutdown({
    Duration rpcTimeout = const Duration(seconds: 2),
    Duration exitTimeout = const Duration(seconds: 2),
  }) async {}
}

class _FakeTransport implements AppServiceTransport {
  _FakeTransport(this.results);

  final Map<String, Object?> results;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    if (!results.containsKey(method)) {
      throw RpcRemoteException('method_not_found', method);
    }
    return results[method];
  }

  @override
  Future<void> close() async {}
}
