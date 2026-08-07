import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/model/window_state.dart';
import 'package:transvortex_desktop_flutter/services/window_state_bridge.dart';
import 'app_service_test_support.dart';

void main() {
  test(
    'WindowBridgeTransport delegates calls to the attached main bridge',
    () async {
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      final calls = <RecordedRpcCall>[];
      bridge.attachServiceCaller((method, params) async {
        calls.add(RecordedRpcCall(method, params));
        return {
          'service': 'transvortex.app_service',
          'protocol_version': 1,
          'app_version': 'test',
          'capabilities': ['desktop_snapshot'],
        };
      });
      final client = AppServiceClient(WindowBridgeTransport(bridge));

      final info = await client.info();

      expect(info.service, 'transvortex.app_service');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'service.info');
      expect(calls.single.params, isEmpty);
    },
  );

  test('WindowStateBridge opens attached tool windows', () async {
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final opened = <AppWindowArgs>[];
    bridge.attachToolWindowOpener((args) async {
      opened.add(args);
    });

    await bridge.openToolWindow(AppWindowType.asrSettings);
    await bridge.openToolWindow(
      AppWindowType.taskProcessing,
      taskId: 'tvx_processing_1',
    );

    expect(opened.map((args) => args.type), [
      AppWindowType.asrSettings,
      AppWindowType.taskProcessing,
    ]);
    expect(opened[1].taskId, 'tvx_processing_1');
  });

  test('WindowStateBridge runs attached service refresher', () async {
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    var refreshCount = 0;
    bridge.attachServiceRefresher(() async {
      refreshCount += 1;
    });

    await bridge.refreshServiceSnapshot();

    expect(refreshCount, 1);
  });
}
