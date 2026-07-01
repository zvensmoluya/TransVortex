import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transvortex_desktop_flutter/main.dart';
import 'package:transvortex_desktop_flutter/model/spike_state.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/local_service_controller.dart';
import 'package:transvortex_desktop_flutter/services/window_state_bridge.dart';
import 'package:transvortex_desktop_flutter/widgets/sidecar_probe_view.dart';

void main() {
  testWidgets('main screen renders empty-state subject', (tester) async {
    await tester.pumpWidget(
      TransVortexApp(localServiceController: _readyController()),
    );
    // 呼吸动画在 repeat，不能 pumpAndSettle；推进一帧即可。
    await tester.pump(const Duration(milliseconds: 100));

    // 「放入片源」出现两处：主体提示 + 空态禁用 CTA。
    expect(find.text('放入片源'), findsNWidgets(2));
    expect(find.textContaining('拖进来'), findsOneWidget);
    expect(find.text('TransVortex'), findsOneWidget);
    expect(find.textContaining('调试态'), findsOneWidget);
  });

  testWidgets('main screen applies readonly service snapshot readiness', (
    tester,
  ) async {
    await tester.pumpWidget(
      TransVortexApp(localServiceController: _readyController()),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('服务已连接'), findsOneWidget);
    await tester.tap(find.text('就绪'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.textContaining('RealProvider', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('Local ASR', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('service diagnostics renders degraded state', (tester) async {
    final controller = LocalServiceController(
      sessionFactory: () async => _FakeHandle(
        info: const ServiceInfo(
          service: 'transvortex.app_service',
          protocolVersion: 1,
          appVersion: 'test',
          capabilities: ['desktop_snapshot'],
        ),
        health: const ServiceHealth(
          service: 'transvortex.app_service',
          status: 'degraded',
          runtime: {
            'active': {'task_id': 'tvx_1', 'status': 'RUNNING'},
          },
          pump: {'enabled': true, 'last_error': 'launch failed'},
        ),
        snapshot: _desktopSnapshot(),
      ),
    );
    await controller.start();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SidecarProbeView(controller: controller)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Local Service 诊断'), findsOneWidget);
    expect(find.text('degraded'), findsWidgets);
    expect(find.text('tvx_1 · RUNNING'), findsOneWidget);
    expect(find.text('launch failed'), findsOneWidget);
  });

  testWidgets('translation settings window renders IME probe fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      const TransVortexApp(windowType: SpikeWindowType.translationSettings),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('翻译模型设置'), findsOneWidget);
    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('模型名'), findsOneWidget);
    expect(find.textContaining('中文备注'), findsOneWidget);
  });

  testWidgets('translation settings window reads providers through bridge', (
    tester,
  ) async {
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return _desktopSnapshot().raw;
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: SpikeWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('RealProvider'), findsWidgets);
    expect(find.text('real-model'), findsWidgets);
    expect(find.textContaining('API key 会写入用户级'), findsOneWidget);
  });

  testWidgets('translation settings window saves provider through bridge', (
    tester,
  ) async {
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') return _desktopSnapshot().raw;
      if (method == 'provider.save') return {'ok': true};
      if (method == 'provider.routing.save') {
        return {
          'routing': {
            'primary': {'provider': 'RealProvider', 'model': 'real-model'},
          },
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: SpikeWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('保存 provider'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('provider.save'));
    expect(calls, contains('provider.routing.save'));
    expect(find.textContaining('provider 已保存'), findsOneWidget);
  });

  testWidgets('ASR settings window saves default provider through bridge', (
    tester,
  ) async {
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') return _desktopSnapshot().raw;
      if (method == 'asr.provider.save') {
        return {'ok': true, 'provider': 'local'};
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: SpikeWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('保存识别默认'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('asr.provider.save'));
    expect(find.textContaining('识别默认已保存'), findsOneWidget);
  });
}

LocalServiceController _readyController() {
  return LocalServiceController(
    sessionFactory: () async => _FakeHandle(
      info: const ServiceInfo(
        service: 'transvortex.app_service',
        protocolVersion: 1,
        appVersion: 'test',
        capabilities: ['desktop_snapshot', 'runtime_pump'],
      ),
      health: const ServiceHealth(
        service: 'transvortex.app_service',
        status: 'healthy',
        runtime: {'active': null},
        pump: {'enabled': true},
      ),
      snapshot: _desktopSnapshot(),
    ),
  );
}

DesktopSnapshot _desktopSnapshot() {
  return DesktopSnapshot.fromJson({
    'config': {
      'routing': {
        'primary': {'provider': 'RealProvider', 'model': 'real-model'},
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
          'name': 'Local ASR',
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
  _FakeHandle({
    required this.info,
    required this.health,
    required this.snapshot,
  }) : client = AppServiceClient(
         _FakeTransport({
           'service.info': {
             'service': info.service,
             'protocol_version': info.protocolVersion,
             'app_version': info.appVersion,
             'capabilities': info.capabilities,
           },
           'service.health': {
             'service': health.service,
             'status': health.status,
             'runtime': health.runtime,
             'pump': health.pump,
             if (health.error != null) 'error': health.error,
           },
           'desktop.snapshot': snapshot.raw,
         }),
       );

  final ServiceInfo info;
  final ServiceHealth health;
  final DesktopSnapshot snapshot;

  @override
  final AppServiceClient client;

  @override
  Future<int> get exitCode => Completer<int>().future;

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
    return results[method];
  }

  @override
  Future<void> close() async {}
}
