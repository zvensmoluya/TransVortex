import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transvortex_desktop_flutter/model/window_state.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/window_state_bridge.dart';
import 'package:transvortex_desktop_flutter/widgets/application_network_settings.dart';
import 'package:transvortex_desktop_flutter/widgets/application_settings_panel.dart';
import 'package:transvortex_desktop_flutter/widgets/asr_resource_management.dart';
import 'package:transvortex_desktop_flutter/widgets/settings_common.dart';
import '../support/widget_test_support.dart';

void main() {
  testWidgets(
    'application settings organize global network and local resources',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      var modelInstalled = true;
      final calls = <String>[];
      Map<String, Object?>? removeParams;
      bridge.attachServiceCaller((method, params) async {
        calls.add(method);
        if (method == 'desktop.snapshot') {
          return desktopSnapshotFixture(
            managedAsr: true,
            localModel: 'small',
            asrLocal: managedAsrResources(modelInstalled: modelInstalled),
          ).raw;
        }
        if (method == 'asr.component.remove') {
          removeParams = Map<String, Object?>.from(params);
          modelInstalled = false;
          return {
            'ok': true,
            'kind': params['kind'],
            'item_id': params['item_id'],
            'removed': true,
          };
        }
        throw RpcRemoteException('method_not_found', method);
      });

      final service = readyController();
      addTearDown(service.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 480,
            height: 520,
            child: ApplicationSettingsPanel(
              bridge: bridge,
              service: service,
              workspaceOperations: FakeWorkspaceDataOperations(),
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.byKey(const ValueKey('application-settings-panel')),
        findsOneWidget,
      );
      expect(find.text('应用设置'), findsOneWidget);
      expect(find.text('网络'), findsOneWidget);
      expect(find.text('连接方式'), findsOneWidget);
      expect(find.text('工作数据'), findsOneWidget);
      expect(find.text('识别资源'), findsOneWidget);
      expect(find.text('Agent / CLI'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('application-settings-drag-area')),
        findsOneWidget,
      );
      expect(find.text('翻译模型设置'), findsNothing);
      expect(find.text('语音识别设置'), findsNothing);
      expect(find.text('Whisper Small'), findsNothing);
      expect(find.text('刷新'), findsNothing);
      expect(find.byKey(const ValueKey('asr-resource-refresh')), findsNothing);

      await tester.tap(find.text('工作数据'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('workspace-data-management')),
        findsOneWidget,
      );
      expect(find.textContaining(r'D:\TransVortexData'), findsOneWidget);

      await tester.tap(find.text('识别资源'));
      await tester.pumpAndSettle();
      expect(find.text('Whisper Small'), findsOneWidget);
      expect(find.text('刷新'), findsNothing);

      await tester.drag(
        find.descendant(
          of: find.byKey(const ValueKey('asr-resource-manager')),
          matching: find.byType(ListView),
        ),
        const Offset(0, -80),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('asr-resource-remove-model-small')),
      );
      await tester.pump();
      expect(find.text('删除Whisper Small？'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('asr-resource-confirm-remove')),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(calls, contains('asr.component.remove'));
      expect(removeParams, {'kind': 'model', 'item_id': 'small'});
      expect(find.text('Whisper Small已删除。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('asr-resource-remove-model-small')),
        findsNothing,
      );
      expectNoFlutterException();
    },
  );

  testWidgets('application settings expose the installed Agent entry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = '${(call.arguments as Map)['text']}';
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final bridge = WindowStateBridge.main(WindowStateStore());
    var openedCodex = false;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      if (method == 'agent.client.get') return codexAgentClientPayload();
      if (method == 'agent.client.open') {
        openedCodex = true;
        return {
          'launched': true,
          'pid': 100,
          'workspace': r'D:\TransVortex\Cache\AgentHandoffs\ClientOpen',
          'client': codexAgentClientPayload(),
        };
      }
      if (method == 'agent.entry.get') {
        return {
          'schema_version': 1,
          'app_version': '1.2.3',
          'protocol_version': '0.1',
          'registered': true,
          'install_root': r'C:\Programs\TransVortex\App',
          'config_root': r'C:\Users\tester\AppData\Local\TransVortex\Config',
          'agent_entry_document':
              r'C:\Users\tester\AppData\Local\TransVortex\Agent\README.md',
          'agent_entry_state':
              r'C:\Users\tester\AppData\Local\TransVortex\Agent\current.json',
          'agent_docs_root': r'C:\Programs\TransVortex\App\agent',
          'documents': const <String, Object?>{},
          'cli_argv_prefix': [
            r'C:\Programs\TransVortex\App\runtime\python\python.exe',
            '-B',
            '-m',
            'transvortex.cli',
            '--root',
            r'C:\Users\tester\AppData\Local\TransVortex\Config',
          ],
          'capabilities_argv': ['python.exe', 'agent-info', '--json'],
          'handoff_text': 'read stable entry',
          'asr_environment_handoff_text': 'read ASR workflow',
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });
    final pathOpener = RecordingPathOpener();
    final service = readyController();
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 480,
          height: 520,
          child: ApplicationSettingsPanel(
            bridge: bridge,
            service: service,
            pathOpener: pathOpener,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Agent / CLI'));
    await tester.pumpAndSettle();

    expect(find.text('Codex CLI 已就绪'), findsOneWidget);
    expect(find.text('TransVortex Agent 接口'), findsOneWidget);
    expect(find.text('打开 Codex'), findsOneWidget);
    expect(find.text('复制交接信息'), findsOneWidget);
    expect(find.text('定位稳定入口'), findsOneWidget);
    expect(find.text('打开版本文档'), findsOneWidget);
    expect(
      find.text(r'C:\Users\tester\AppData\Local\TransVortex\Agent\README.md'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('agent-entry-copy')));
    await tester.pump();
    expect(clipboardText, 'read stable entry');
    expect(find.text('交接信息已复制，可交给 Agent。'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-client-open')));
    await tester.pump();
    expect(openedCodex, isTrue);
    expect(find.text('Codex CLI 已打开，尚未发送任务。'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-entry-reveal')));
    await tester.pump();
    expect(pathOpener.revealedFiles, [
      r'C:\Users\tester\AppData\Local\TransVortex\Agent\README.md',
    ]);
    await tester.tap(find.byKey(const ValueKey('agent-docs-open')));
    await tester.pump();
    expect(pathOpener.openedDirectories, [
      r'C:\Programs\TransVortex\App\agent',
    ]);
    expectNoFlutterException();
  });

  testWidgets('application settings save the shared local proxy setting', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? saved;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      if (method == 'network.settings.save') {
        saved = Map<String, Object?>.from(params);
        return {
          'ok': true,
          'network': {'mode': 'local_proxy', 'proxy_port': 7890},
          'pipeline_file_version': {'mtime_ns': 7, 'size': 8},
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });
    final service = readyController();
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 480,
          height: 520,
          child: ApplicationSettingsPanel(
            bridge: bridge,
            service: service,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('本地代理'));
    await tester.pumpAndSettle();
    final portField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '例如 7890',
    );
    expect(portField, findsOneWidget);
    await tester.enterText(portField, '7890');
    await tester.pump();
    await tester.tap(find.text('保存网络设置'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(saved, {
      'mode': 'local_proxy',
      'proxy_port': 7890,
      'expected_version': {'mtime_ns': 1, 'size': 2},
    });
    expect(find.textContaining('127.0.0.1:7890'), findsWidgets);
    expect(find.text('刷新'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('application settings migrates workspace and reloads service', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final operations = FakeWorkspaceDataOperations();
    String? savedWorkspace;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      if (method == 'workspace.storage.set') {
        savedWorkspace = '${params['workspace_root']}';
        operations.root = savedWorkspace!;
        return {
          'ok': true,
          'workspace_root': savedWorkspace,
          'restart_required': true,
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });
    final service = readyController();
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 480,
          height: 520,
          child: ApplicationSettingsPanel(
            bridge: bridge,
            service: service,
            workspaceOperations: operations,
            directoryPicker: (_) async => r'E:\TransVortexData',
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('工作数据'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('workspace-change-location')));
    await tester.pumpAndSettle();
    expect(find.text('迁移工作数据？'), findsOneWidget);
    await tester.tap(find.text('开始迁移'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(savedWorkspace, r'E:\TransVortexData');
    expect(operations.copiedTarget, r'E:\TransVortexData');
    expect(operations.removedSource, isTrue);
    expect(find.textContaining(r'E:\TransVortexData'), findsWidgets);
    expect(find.textContaining('工作数据已迁移到'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('workspace migration rolls back when the RPC reply is lost', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = WindowStateBridge.main(WindowStateStore());
    final operations = FakeWorkspaceDataOperations();
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      if (method == 'workspace.storage.set') {
        operations.root = '${params['workspace_root']}';
        throw RpcRemoteException('connection_lost', '本地服务连接已中断。');
      }
      throw RpcRemoteException('method_not_found', method);
    });
    final service = readyController();
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 480,
          height: 520,
          child: ApplicationSettingsPanel(
            bridge: bridge,
            service: service,
            workspaceOperations: operations,
            directoryPicker: (_) async => r'E:\TransVortexData',
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('工作数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-change-location')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始迁移'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(operations.restoredConfiguration, isTrue);
    expect(operations.discardedTarget, isTrue);
    expect(operations.removedSource, isFalse);
    expect(operations.root, r'D:\TransVortexData');
    expect(find.text('本地服务连接已中断。'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('application network retry clears a resolved sync error', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(448, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = WindowStateBridge.main(WindowStateStore());
    final transport = FakeAppServiceTransport(
      {'desktop.snapshot': desktopSnapshotFixture().raw},
      failures: {
        'desktop.snapshot': [
          RpcRemoteException('service_unavailable', 'offline'),
        ],
      },
    );
    final service = readyController();
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: SizedBox(
            width: 448,
            height: 420,
            child: ApplicationNetworkSettings(
              client: AppServiceClient(transport),
              bridge: bridge,
              service: service,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('重试同步'), findsOneWidget);
    await tester.tap(find.text('重试同步'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('重试同步'), findsNothing);
    expect(find.text('保存网络设置'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('managed resources follow service snapshots without refresh', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(448, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final initial = desktopSnapshotFixture(
      managedAsr: true,
      localModel: 'small',
      asrLocal: managedAsrResources(),
    );
    final updated = desktopSnapshotFixture(
      managedAsr: true,
      localModel: 'small',
      asrLocal: managedAsrResources(modelInstalled: false),
    );
    final serviceTransport = FakeAppServiceTransport(
      {
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
        'desktop.snapshot': updated.raw,
      },
      sequences: {
        'desktop.snapshot': [initial.raw, updated.raw],
      },
    );
    final service = controllerForTransport(serviceTransport);
    addTearDown(service.dispose);
    await service.start();
    final bridge = WindowStateBridge.main(WindowStateStore());
    final client = AppServiceClient(
      FakeAppServiceTransport({'desktop.snapshot': initial.raw}),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 448,
          height: 360,
          child: AsrResourceManagement(
            client: client,
            bridge: bridge,
            service: service,
            showHeader: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Whisper Small'), findsOneWidget);
    expect(
      tester
          .widget<ActionButton>(
            find.byKey(const ValueKey('asr-resource-remove-model-small')),
          )
          .onTap,
      isNotNull,
    );
    expect(find.text('刷新'), findsNothing);

    await service.refresh();
    await tester.pump();

    expect(find.text('Whisper Small'), findsNothing);
    expect(find.text('本机 Whisper'), findsOneWidget);
    expect(find.text('本机 Whisper 运行组件'), findsNothing);
    expect(find.text('刷新'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('managed resource storage explains a blocked change inline', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(448, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final asrLocal = managedAsrResources();
    asrLocal['storage'] = {
      ...Map<String, Object?>.from(asrLocal['storage']! as Map),
      'customized': true,
      'can_change': false,
      'change_blocker': 'managed_resources_present',
    };
    final snapshot = desktopSnapshotFixture(
      managedAsr: true,
      localModel: 'small',
      asrLocal: asrLocal,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 448,
          height: 420,
          child: AsrResourceManagement(
            client: AppServiceClient(
              FakeAppServiceTransport({'desktop.snapshot': snapshot.raw}),
            ),
            bridge: WindowStateBridge.main(WindowStateStore()),
            showHeader: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('更改'), findsOneWidget);
    final change = tester.widget<ActionButton>(
      find.byKey(const ValueKey('asr-resource-change-storage')),
    );
    expect(change.onTap, isNull);
    expect(find.textContaining('删除下方已下载资源后'), findsOneWidget);
    expect(find.text('更改识别资源位置'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('managed resource storage changes from application settings', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(448, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const selectedRoot = r'E:\TransVortex-ASR';
    var currentRoot = r'D:\TransVortex-ASR';
    var refreshes = 0;
    final storageCalls = <Map<String, Object?>>[];
    final bridge = WindowStateBridge.main(WindowStateStore());

    Map<String, Object?> currentAsrLocal() {
      final value = managedAsrResources(modelInstalled: false);
      value['storage'] = {
        ...Map<String, Object?>.from(value['storage']! as Map),
        'root': currentRoot,
        'default_root': r'C:\TransVortex-ASR',
        'customized': currentRoot != r'C:\TransVortex-ASR',
        'can_change': true,
        'change_blocker': '',
      };
      return value;
    }

    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          managedAsr: true,
          localModel: 'small',
          asrLocal: currentAsrLocal(),
        ).raw;
      }
      if (method == 'asr.storage.set') {
        storageCalls.add(Map<String, Object?>.from(params));
        currentRoot = '${params['storage_root']}';
        return Map<String, Object?>.from(currentAsrLocal()['storage']! as Map);
      }
      throw RpcRemoteException('method_not_found', method);
    });
    bridge.attachServiceRefresher(() async {
      refreshes += 1;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 448,
          height: 420,
          child: AsrResourceManagement(
            client: AppServiceClient(WindowBridgeTransport(bridge)),
            bridge: bridge,
            directoryPicker: (_) async => selectedRoot,
            showHeader: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('asr-resource-change-storage')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(storageCalls, [
      {'storage_root': selectedRoot},
    ]);
    expect(find.textContaining(selectedRoot), findsWidgets);
    expect(refreshes, 1);
    expectNoFlutterException();
  });

  testWidgets('empty managed resources do not expose a storage location', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(448, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final asrLocal = managedAsrResources(modelInstalled: false);
    asrLocal['runtime'] = {
      ...Map<String, Object?>.from(asrLocal['runtime']! as Map),
      'installed': false,
    };
    final snapshot = desktopSnapshotFixture(asrLocal: asrLocal);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 448,
          height: 360,
          child: AsrResourceManagement(
            client: AppServiceClient(
              FakeAppServiceTransport({'desktop.snapshot': snapshot.raw}),
            ),
            bridge: WindowStateBridge.main(WindowStateStore()),
            showHeader: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('暂无已下载的识别组件'), findsOneWidget);
    expect(find.text(r'D:\TransVortex-ASR'), findsNothing);
    expect(
      find.byKey(const ValueKey('asr-resource-change-storage')),
      findsNothing,
    );
    expectNoFlutterException();
  });

  testWidgets('standalone managed resources stay idle without a trigger', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(448, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final initial = desktopSnapshotFixture(
      managedAsr: true,
      localModel: 'small',
      asrLocal: managedAsrResources(),
    );
    final transport = FakeAppServiceTransport({
      'desktop.snapshot': initial.raw,
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 448,
          height: 360,
          child: AsrResourceManagement(
            client: AppServiceClient(transport),
            bridge: WindowStateBridge.main(WindowStateStore()),
            showHeader: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Whisper Small'), findsOneWidget);
    expect(
      tester
          .widget<ActionButton>(
            find.byKey(const ValueKey('asr-resource-remove-model-small')),
          )
          .onTap,
      isNotNull,
    );

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Whisper Small'), findsOneWidget);
    expect(
      tester
          .widget<ActionButton>(
            find.byKey(const ValueKey('asr-resource-remove-model-small')),
          )
          .onTap,
      isNotNull,
    );
    expect(
      transport.calls.where((method) => method == 'desktop.snapshot').length,
      1,
    );
    expect(find.text('刷新'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('managed resource retry clears a resolved sync error', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(448, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport = FakeAppServiceTransport(
      {
        'desktop.snapshot': desktopSnapshotFixture(
          managedAsr: true,
          localModel: 'small',
          asrLocal: managedAsrResources(),
        ).raw,
      },
      failures: {
        'desktop.snapshot': [
          RpcRemoteException('service_unavailable', 'offline'),
        ],
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 448,
          height: 360,
          child: AsrResourceManagement(
            client: AppServiceClient(transport),
            bridge: WindowStateBridge.main(WindowStateStore()),
            showHeader: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('重试同步'), findsOneWidget);
    await tester.tap(find.text('重试同步'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('重试同步'), findsNothing);
    expect(find.text('Whisper Small'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('missing managed resources are reconciled automatically', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(448, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var modelInstalled = true;
    var serviceRefreshes = 0;
    final bridge = WindowStateBridge.main(WindowStateStore());
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          managedAsr: true,
          localModel: 'small',
          asrLocal: managedAsrResources(modelInstalled: modelInstalled),
        ).raw;
      }
      if (method == 'asr.component.remove') {
        modelInstalled = false;
        throw RpcRemoteException('component_not_found', 'already removed');
      }
      throw RpcRemoteException('method_not_found', method);
    });
    bridge.attachServiceRefresher(() async {
      serviceRefreshes += 1;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 448,
          height: 360,
          child: AsrResourceManagement(
            client: AppServiceClient(WindowBridgeTransport(bridge)),
            bridge: bridge,
            showHeader: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(
      find.byKey(const ValueKey('asr-resource-remove-model-small')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('asr-resource-confirm-remove')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Whisper Small'), findsNothing);
    expect(find.textContaining('列表已自动同步'), findsOneWidget);
    expect(serviceRefreshes, 1);
    expect(find.text('刷新'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('resource removal refreshes shared state after its page closes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(448, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final releaseRemove = Completer<void>();
    final removeStarted = Completer<void>();
    var modelInstalled = true;
    var serviceRefreshes = 0;
    final bridge = WindowStateBridge.main(WindowStateStore());
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          managedAsr: true,
          localModel: 'small',
          asrLocal: managedAsrResources(modelInstalled: modelInstalled),
        ).raw;
      }
      if (method == 'asr.component.remove') {
        removeStarted.complete();
        await releaseRemove.future;
        modelInstalled = false;
        return {'ok': true, 'removed': true};
      }
      throw RpcRemoteException('method_not_found', method);
    });
    bridge.attachServiceRefresher(() async {
      serviceRefreshes += 1;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 448,
          height: 360,
          child: AsrResourceManagement(
            client: AppServiceClient(WindowBridgeTransport(bridge)),
            bridge: bridge,
            showHeader: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(
      find.byKey(const ValueKey('asr-resource-remove-model-small')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('asr-resource-confirm-remove')));
    await tester.pump();
    await removeStarted.future;

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    releaseRemove.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(modelInstalled, isFalse);
    expect(serviceRefreshes, 1);
    expectNoFlutterException();
  });

  testWidgets('network save refreshes shared state after its page closes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(448, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final releaseSave = Completer<void>();
    final saveStarted = Completer<void>();
    var serviceRefreshes = 0;
    final bridge = WindowStateBridge.main(WindowStateStore());
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      if (method == 'network.settings.save') {
        saveStarted.complete();
        await releaseSave.future;
        return {
          'ok': true,
          'network': {'mode': 'local_proxy', 'proxy_port': 7890},
          'pipeline_file_version': {'mtime_ns': 7, 'size': 8},
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });
    bridge.attachServiceRefresher(() async {
      serviceRefreshes += 1;
    });
    final service = readyController();
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: SizedBox(
            width: 448,
            height: 420,
            child: ApplicationNetworkSettings(
              client: AppServiceClient(WindowBridgeTransport(bridge)),
              bridge: bridge,
              service: service,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('本地代理'));
    await tester.pumpAndSettle();
    final portField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '例如 7890',
    );
    await tester.enterText(portField, '7890');
    await tester.pump();
    await tester.tap(find.text('保存网络设置'));
    await tester.pump();
    await saveStarted.future;

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    releaseSave.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(serviceRefreshes, 1);
    expectNoFlutterException();
  });

  testWidgets('application settings honor reduced motion', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = readyController();
    addTearDown(service.dispose);
    final bridge = WindowStateBridge.main(WindowStateStore());
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: SizedBox(
            width: 480,
            height: 520,
            child: ApplicationSettingsPanel(
              bridge: bridge,
              service: service,
              entranceAnimation: const AlwaysStoppedAnimation(0),
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('应用设置'), findsOneWidget);
    expect(find.text('连接方式'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('application-settings-transition')),
      findsNothing,
    );
    expectNoFlutterException();
  });
}
