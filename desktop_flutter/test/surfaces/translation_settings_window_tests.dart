import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transvortex_desktop_flutter/main.dart';
import 'package:transvortex_desktop_flutter/model/window_state.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/window_state_bridge.dart';
import '../support/widget_test_support.dart';

void main() {
  testWidgets('translation settings window renders connections and profiles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // Default tab is 连接: the connection list + detail are visible.
    expect(find.text('翻译模型设置'), findsOneWidget);
    expect(find.text('连接'), findsWidgets);
    expect(find.text('常用模型'), findsWidgets);
    expect(find.text('网络'), findsOneWidget);
    expect(find.text('模型连接'), findsNothing);
    expect(find.text('翻译方案'), findsNothing);
    expect(find.text('刷新'), findsNothing);
    expect(find.text('已配置连接'), findsOneWidget);
    expect(find.text('服务地址 (Base URL)'), findsOneWidget);
    expect(find.text('连接设置'), findsOneWidget);
    expect(find.text('连接状态'), findsNothing);
    expect(find.text('RealProvider'), findsWidgets);
    expect(find.text('OpenAI Chat 兼容'), findsWidgets);
    expect(find.text('已配置'), findsWidgets);
    expect(find.textContaining('.env'), findsNothing);
    expect(find.text('来源'), findsNothing);
    expect(find.textContaining('中文备注'), findsNothing);
    expect(find.text('模型翻译设置 · real-model'), findsOneWidget);
    expect(find.text('每批行数上限'), findsOneWidget);
    expect(find.text('推理强度'), findsNothing);
    expect(
      find.byKey(const ValueKey('connection-test-reasoning-effort')),
      findsOneWidget,
    );
    expect(find.text('高级容量设置'), findsOneWidget);
    expect(find.text('上下文窗口（tokens）'), findsNothing);
    expect(find.text('最大输入（tokens）'), findsNothing);
    expect(find.text('最大输出（tokens）'), findsNothing);
    expect(find.text('目标输出预算（tokens）'), findsNothing);
    expect(find.textContaining('规格来源：'), findsNothing);
    expect(find.textContaining('渠道以实际账单为准'), findsNothing);

    final batchSelect = find.byKey(const ValueKey('model-batch-lines-select'));
    expect(batchSelect, findsOneWidget);
    expect(find.text('自定义单次请求行数'), findsNothing);

    await tester.ensureVisible(batchSelect);
    await tester.pumpAndSettle();
    await tester.tap(batchSelect);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义…').last);
    await tester.pumpAndSettle();

    expect(find.text('自定义单次请求行数'), findsOneWidget);

    final advancedToggle = find.byKey(
      const ValueKey('model-advanced-capacity-toggle'),
    );
    await tester.ensureVisible(advancedToggle);
    await tester.drag(find.byType(ListView).last, const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.tap(advancedToggle);
    await tester.pumpAndSettle();

    expect(find.text('上下文窗口（tokens）'), findsOneWidget);
    expect(find.text('最大输入（tokens）'), findsOneWidget);
    expect(find.text('最大输出（tokens）'), findsOneWidget);
    expect(find.text('目标输出预算（tokens）'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings saves a local proxy port', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 680));
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

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('网络'));
    await tester.pumpAndSettle();
    expect(find.text('跟随系统'), findsWidgets);
    expect(find.text('直连'), findsOneWidget);
    expect(find.text('本地代理端口（HTTP / Mixed）'), findsNothing);

    await tester.tap(find.text('本地代理'));
    await tester.pumpAndSettle();
    final portField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '例如 7890',
    );
    expect(portField, findsOneWidget);
    await tester.tap(portField);
    await tester.enterText(portField, '7');
    await tester.pump();
    var textField = tester.widget<TextField>(portField);
    expect(textField.controller?.text, '7');
    expect(
      textField.controller?.selection,
      const TextSelection.collapsed(offset: 1),
      reason: 'rebuilding after a digit must preserve the insertion caret',
    );

    await tester.enterText(portField, '78');
    await tester.pump();
    textField = tester.widget<TextField>(portField);
    expect(
      textField.controller?.selection,
      const TextSelection.collapsed(offset: 2),
    );
    await tester.enterText(portField, '7890');
    await tester.pump();
    expect(find.text('代理地址：http://127.0.0.1:7890'), findsOneWidget);
    await tester.tap(find.text('保存网络设置'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(saved, {
      'mode': 'local_proxy',
      'proxy_port': 7890,
      'expected_version': {'mtime_ns': 1, 'size': 2},
    });
    expect(find.textContaining('127.0.0.1:7890'), findsWidgets);
    expectNoFlutterException();
  });

  testWidgets('known gateway model keeps catalog annotations out of settings', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(longModels: true).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.drag(find.byType(ListView).last, const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(find.text('模型翻译设置 · gemini-3.5-flash'), findsOneWidget);
    expect(find.text('每批行数上限'), findsOneWidget);
    expect(find.textContaining('规格来源：'), findsNothing);
    expect(find.textContaining('输入 \$1.50 / 输出 \$9'), findsNothing);
    expect(find.textContaining('OpenRouter、Zven'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets(
    'settings window falls back to local service when bridge is absent',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(820, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      final localService = readyController();
      addTearDown(localService.dispose);
      bridge.attachServiceCaller((method, params) async {
        throw PlatformException(
          code: 'service_unavailable',
          message: 'Local Service caller is not attached',
        );
      });

      await tester.pumpWidget(
        TransVortexApp(
          windowType: AppWindowType.translationSettings,
          store: store,
          bridge: bridge,
          localServiceController: localService,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('RealProvider'), findsWidgets);
      expect(find.textContaining('需要从主窗口打开设置'), findsNothing);
      expect(find.textContaining('CHANNEL_UNREGISTERED'), findsNothing);
      expect(find.textContaining('WindowChannelException'), findsNothing);
      expectNoFlutterException();
    },
  );

  testWidgets('translation settings window explains empty connections', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(withProviders: false).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('还没有连接'), findsOneWidget);
    expect(find.text('添加一个模型服务后，就能保存可用模型。'), findsOneWidget);
    expect(find.textContaining('method_not_found'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('translation profiles tab guides when there are no connections', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(withProviders: false).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('先添加连接'), findsOneWidget);
    expect(find.text('常用模型由主模型和备用模型组成。'), findsOneWidget);
    expect(find.text('去添加连接'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings tolerates long model names', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(longModels: true).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('gemini-2.0-flash-lite-preview-02-05'), findsOneWidget);

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.ensureVisible(find.text('主模型'));
    await tester.pump();

    expect(find.text('gemini-2.0-flash-lite-preview-02-05'), findsWidgets);
    expectNoFlutterException();
  });

  testWidgets('enabling a discovered model keeps the current editor', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      if (method == 'provider.models') {
        return {
          'status': 'PASS',
          'hint_zh': '已拉取到 2 个模型。',
          'models': ['model-a', 'model-b'],
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pump(const Duration(milliseconds: 100));

    await tester.drag(find.byType(ListView).last, const Offset(0, -360));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -360));
    await tester.pumpAndSettle();

    expect(find.text('model-a'), findsOneWidget);
    expect(find.text('model-b'), findsOneWidget);
    expect(find.byKey(const ValueKey('remove-model-model-b')), findsNothing);
    expect(find.textContaining('已拉取到 2 个模型'), findsOneWidget);

    final discoveredModel = find.byKey(
      const ValueKey('discovered-model-model-b'),
    );
    await tester.ensureVisible(discoveredModel);
    await tester.pumpAndSettle();
    expect(find.text('模型翻译设置 · real-model'), findsOneWidget);
    await tester.tap(discoveredModel);
    await tester.pumpAndSettle();
    expect(find.text('模型翻译设置 · real-model'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, 360));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, 360));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('remove-model-model-b')), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings window saves a connection only', (
    tester,
  ) async {
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    Map<String, Object?>? savedProviderDraft;
    String? savedApiKey;
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      if (method == 'provider.save') {
        savedProviderDraft = Map<String, Object?>.from(
          params['provider_draft'] as Map,
        );
        savedApiKey = params['api_key'] as String?;
        return {'ok': true};
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final baseUrlField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.controller?.text == 'https://example.com/v1',
    );
    expect(baseUrlField, findsOneWidget);
    await tester.enterText(baseUrlField, 'https://edited.example/v1');

    final apiKeyField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.obscureText,
    );
    expect(apiKeyField, findsOneWidget);
    await tester.enterText(apiKeyField, 'sk-edited');

    final modelInput = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '手动填写模型 ID',
    );
    expect(modelInput, findsOneWidget);
    await tester.enterText(modelInput, 'typed-model');

    await tester.tap(find.text('保存连接'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('provider.save'));
    expect(calls, isNot(contains('provider.routing.save')));
    expect(savedProviderDraft?['base_url'], 'https://edited.example/v1');
    expect(savedProviderDraft?['models'], contains('real-model'));
    expect(savedProviderDraft?['models'], contains('typed-model'));
    expect(savedProviderDraft?.containsKey('api_key'), isFalse);
    expect(savedApiKey, 'sk-edited');
    expect(calls.where((method) => method == 'provider.save').length, 1);
    expect(find.textContaining('连接已保存'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings prevents removing referenced model', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final removeModel = find.byKey(const ValueKey('remove-model-real-model'));
    expect(removeModel, findsOneWidget);
    await tester.ensureVisible(removeModel);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(removeModel);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('这个模型正在被常用模型使用'), findsOneWidget);
    expect(find.text('real-model'), findsWidgets);
    expect(calls, isNot(contains('provider.save')));
    expect(calls, isNot(contains('provider.routing.save')));
    expectNoFlutterException();
  });

  testWidgets(
    'translation settings creates a connection from provider preset',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      Map<String, Object?>? savedProviderDraft;
      bridge.attachServiceCaller((method, params) async {
        if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
        if (method == 'provider.save') {
          savedProviderDraft = Map<String, Object?>.from(
            params['provider_draft'] as Map,
          );
          return {'ok': true};
        }
        throw RpcRemoteException('method_not_found', method);
      });

      await tester.pumpWidget(
        TransVortexApp(
          windowType: AppWindowType.translationSettings,
          store: store,
          bridge: bridge,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('添加连接'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('选择厂商'), findsOneWidget);
      expect(find.text('选择协议'), findsOneWidget);
      await tester.ensureVisible(find.text('连接信息'));
      await tester.pump();
      expect(find.text('连接信息'), findsOneWidget);
      expect(find.text('DeepSeek'), findsWidgets);

      await tester.tap(find.text('保存连接'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(savedProviderDraft?['name'], 'deepseek');
      expect(savedProviderDraft?['base_url'], 'https://api.deepseek.com');
      expect(savedProviderDraft?['env_key'], 'DEEPSEEK_API_KEY');
      expect(savedProviderDraft?['credential_id'], 'deepseek');
      expect(savedProviderDraft?['compat_mode'], 'openai_chat');
      expect(savedProviderDraft?['api_type'], 'openai-compatible');
      final capabilities = savedProviderDraft?['capabilities'] as Map?;
      expect(capabilities?['max_batch_lines'], 240);
      expect(capabilities?['max_context_tokens'], 1000000);
      expect(capabilities?['max_output_tokens'], 384000);
      expect(capabilities?['reasoning_efforts'], ['high', 'max']);
      expect(savedProviderDraft?['models'], contains('deepseek-v4-flash'));
      expect(savedProviderDraft?['models'], contains('deepseek-v4-pro'));
      final modelConfigs = savedProviderDraft?['model_configs'] as Map?;
      final flashConfig = modelConfigs?['deepseek-v4-flash'] as Map?;
      expect(flashConfig?['max_batch_lines'], 240);
      expect(flashConfig?['max_context_tokens'], 1000000);
      expect(flashConfig?['max_output_tokens'], 384000);
      expect(flashConfig?['reasoning_effort'], isNull);
      expect(
        (savedProviderDraft?['endpoint'] as Map?)?['path_template'],
        '/chat/completions',
      );
      expect(find.textContaining('连接已保存'), findsOneWidget);
      expectNoFlutterException();
    },
  );

  testWidgets(
    'translation settings creates a custom provider with selected protocol',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      Map<String, Object?>? savedProviderDraft;
      bridge.attachServiceCaller((method, params) async {
        if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
        if (method == 'provider.save') {
          savedProviderDraft = Map<String, Object?>.from(
            params['provider_draft'] as Map,
          );
          return {'ok': true};
        }
        throw RpcRemoteException('method_not_found', method);
      });

      await tester.pumpWidget(
        TransVortexApp(
          windowType: AppWindowType.translationSettings,
          store: store,
          bridge: bridge,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('添加连接'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('自定义厂商'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('OpenAI-compatible Chat'), findsWidgets);
      await tester.ensureVisible(find.text('连接信息'));
      await tester.pump();
      expect(find.text('自定义厂商'), findsWidgets);

      final nameField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.controller?.text == 'custom_provider',
      );
      expect(nameField, findsOneWidget);
      await tester.enterText(nameField, 'my_gateway');

      final baseUrlField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.controller?.text == 'https://api.openai.com/v1',
      );
      expect(baseUrlField, findsOneWidget);
      await tester.enterText(baseUrlField, 'https://gateway.example/v1');

      await tester.tap(find.text('保存连接'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(savedProviderDraft?['name'], 'my_gateway');
      expect(savedProviderDraft?['base_url'], 'https://gateway.example/v1');
      expect(savedProviderDraft?['env_key'], 'TVX_PROVIDER_MY_GATEWAY_API_KEY');
      expect(savedProviderDraft?['credential_id'], 'my_gateway');
      expect(savedProviderDraft?['compat_mode'], 'openai_chat');
      expect(savedProviderDraft?['models'], contains('custom-model'));
      expect(find.textContaining('连接已保存'), findsOneWidget);
      expectNoFlutterException();
    },
  );

  testWidgets('translation settings hides provider internals from the app UI', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.ensureVisible(find.text('凭据状态'));
    await tester.pump();
    expect(find.text('连接状态'), findsNothing);
    expect(find.text('服务类型'), findsWidgets);
    expect(find.text('来源'), findsNothing);
    expect(find.text('凭据状态'), findsOneWidget);
    expect(find.text('本机配置'), findsNothing);
    expect(find.textContaining('.env'), findsNothing);
    expect(find.text('OpenAI Chat 兼容'), findsWidgets);
    expect(find.text('展开高级配置'), findsNothing);
    expect(find.text('高级配置'), findsNothing);
    expect(find.text('协议标识'), findsNothing);
    expect(find.text('环境变量'), findsNothing);
    expect(find.text('请求端点'), findsNothing);
    expect(find.text('响应提取'), findsNothing);
    expect(find.text('调用限制'), findsNothing);
    expect(find.text('凭据 ID'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('translation settings deletes an unused connection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final initial = desktopSnapshotFixture();
    final afterDelete = desktopSnapshotFixture(withProviders: false);
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    var snapshotCalls = 0;
    Map<String, Object?>? deleteParams;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        snapshotCalls += 1;
        return snapshotCalls == 1 ? initial.raw : afterDelete.raw;
      }
      if (method == 'provider.delete') {
        deleteParams = Map<String, Object?>.from(params);
        return {'deleted': true};
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('删除连接'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(deleteParams, {
      'name': 'RealProvider',
      'expected_version': {'mtime_ns': 3, 'size': 4},
    });
    expect(find.textContaining('连接已删除：RealProvider'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings explains blocked connection deletion', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      if (method == 'provider.delete') {
        return {'deleted': false, 'blocked': true, 'code': 'provider_in_use'};
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('删除连接'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('正在被常用模型使用'), findsOneWidget);
    expect(find.text('RealProvider'), findsWidgets);
    expectNoFlutterException();
  });

  testWidgets('translation profiles tab sets the primary model', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(multiRoutingProfiles: true).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': 'route_1',
          'routing_profiles': params['profiles'],
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.ensureVisible(find.text('主模型'));
    await tester.pump();
    expect(find.text('默认推理强度'), findsNothing);
    expect(
      find.byKey(const ValueKey('primary-reasoning-effort-button')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('primary-reasoning-effort-button')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reasoning-effort-picker')),
      findsOneWidget,
    );
    final pickerSize = tester.getSize(
      find.byKey(const ValueKey('reasoning-effort-picker')),
    );
    expect(pickerSize.width, 320);
    expect(pickerSize.height, lessThan(280));
    expect(
      find.byKey(const ValueKey('reasoning-effort-slider')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reasoning-current-effort')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reasoning-default-badge')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reasoning-reset-default')), findsNothing);
    expect(
      find.byKey(const ValueKey('reasoning-mode-service-default')),
      findsNothing,
    );
    final sliderRect = tester.getRect(
      find.byKey(const ValueKey('reasoning-effort-slider')),
    );
    await tester.tapAt(Offset(sliderRect.right - 24, sliderRect.center.dy));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reasoning-effort-picker')), findsNothing);
    expect(calls, contains('provider.routing.save'));
    var profiles = savedRouting?['profiles'] as List?;
    var active = profiles?.cast<Map>().firstWhere(
      (item) => item['id'] == 'route_1',
    );
    expect((active?['primary'] as Map?)?['reasoning_effort'], 'high');

    await tester.tap(
      find.byKey(const ValueKey('primary-reasoning-effort-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('高'), findsWidgets);
    expect(
      find.byKey(const ValueKey('reasoning-reset-default')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('reasoning-advanced-toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reasoning-mode-service-default')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('reasoning-reset-default')));
    await tester.pumpAndSettle();
    // The primary picker lists connection then model pills; tap the backup
    // model under the RealProvider connection to set it as primary.
    await tester.tap(
      find.byKey(const ValueKey('primary-model-RealProvider-backup-model')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('provider.routing.save'));
    expect(calls, isNot(contains('provider.save')));
    profiles = savedRouting?['profiles'] as List?;
    active = profiles?.cast<Map>().firstWhere(
      (item) => item['id'] == 'route_1',
    );
    expect(active?['primary'], {
      'provider': 'RealProvider',
      'model': 'backup-model',
      'reasoning_effort': 'auto',
    });
    expect(find.textContaining('主模型已设为'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings switches routing profiles', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    var activeProfile = 'route_1';
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          multiRoutingProfiles: true,
          activeRoutingProfile: activeProfile,
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        activeProfile = '${params['active_profile']}';
        return {
          'active_routing_profile': activeProfile,
          'routing_profiles': params['profiles'],
          'routing': {
            'active_profile': activeProfile,
            'primary': {'provider': 'RealProvider', 'model': 'backup-model'},
          },
          'providers_file_version': {'mtime_ns': 5, 'size': 6},
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('配置 1'), findsWidgets);
    expect(find.text('配置 2'), findsWidgets);

    await tester.tap(find.text('配置 2'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(savedRouting?['active_profile'], 'route_2');
    expect(savedRouting?['next_profile_seq'], 3);
    expect(savedRouting?['expected_version'], {'mtime_ns': 3, 'size': 4});
    expect(savedRouting?['profiles'], isA<List>());
    expect(find.textContaining('已切换常用模型：配置 2'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings renames routing profile', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          multiRoutingProfiles: true,
          activeRoutingProfile: 'route_1',
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': 'route_1',
          'routing_profiles': params['profiles'],
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    final nameField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller?.text == '配置 1',
    );
    expect(nameField, findsOneWidget);
    await tester.enterText(nameField, '正式翻译');
    final saveName = find.byKey(const ValueKey('save-profile-name'));
    await tester.ensureVisible(saveName);
    await tester.pump();
    await tester.tap(saveName);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final profiles = savedRouting?['profiles'] as List?;
    final renamed = profiles?.cast<Map>().firstWhere(
      (item) => item['id'] == 'route_1',
    );
    expect(renamed?['name'], '正式翻译');
    expect(savedRouting?['active_profile'], 'route_1');
    expect(find.textContaining('常用模型已重命名：正式翻译'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings saves current route as a new profile', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          multiRoutingProfiles: true,
          activeRoutingProfile: 'route_1',
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': params['active_profile'],
          'routing_profiles': params['profiles'],
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    final createProfile = find.byKey(const ValueKey('create-profile'));
    await tester.ensureVisible(createProfile);
    await tester.pump();
    await tester.tap(createProfile);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final profiles = savedRouting?['profiles'] as List?;
    final created = profiles?.cast<Map>().firstWhere(
      (item) => item['id'] == 'route_3',
    );
    expect(savedRouting?['active_profile'], 'route_3');
    expect(savedRouting?['next_profile_seq'], 4);
    expect(created?['name'], '常用模型 3');
    expect(created?['primary'], {
      'provider': 'RealProvider',
      'model': 'real-model',
      'reasoning_effort': 'auto',
    });
    expect(find.textContaining('已新建常用模型：常用模型 3'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings deletes active routing profile', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          multiRoutingProfiles: true,
          activeRoutingProfile: 'route_1',
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': params['active_profile'],
          'routing_profiles': params['profiles'],
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    final deleteProfile = find.byKey(const ValueKey('delete-profile'));
    await tester.ensureVisible(deleteProfile);
    await tester.pump();
    await tester.tap(deleteProfile);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final profiles = savedRouting?['profiles'] as List?;
    expect(savedRouting?['active_profile'], 'route_2');
    expect(profiles?.cast<Map>().map((item) => item['id']), ['route_2']);
    expect(find.textContaining('已删除常用模型：配置 1'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings adds a fallback model', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          multiRoutingProfiles: true,
          activeRoutingProfile: 'route_1',
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': params['active_profile'],
          'routing_profiles': params['profiles'],
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.ensureVisible(find.text('加入备用'));
    await tester.pump();
    // Stage the backup model in the fallback picker, then confirm.
    await tester.tap(find.text('backup-model').last);
    await tester.pump();
    await tester.ensureVisible(find.text('加入备用'));
    await tester.pump();
    await tester.tap(find.text('加入备用'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final profiles = savedRouting?['profiles'] as List?;
    final active = profiles?.cast<Map>().firstWhere(
      (item) => item['id'] == 'route_1',
    );
    expect(active?['fallback'], [
      {
        'provider': 'RealProvider',
        'model': 'backup-model',
        'reasoning_effort': 'auto',
      },
    ]);
    expect(savedRouting?['active_profile'], 'route_1');
    expect(find.textContaining('已加入备用模型'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings removes fallback model', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          multiRoutingProfiles: true,
          activeRoutingProfile: 'route_1',
          withRoutingFallback: true,
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': params['active_profile'],
          'routing_profiles': params['profiles'],
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    final removeFallback = find.byTooltip('移除备用模型');
    await tester.ensureVisible(removeFallback);
    await tester.pump();
    await tester.tap(removeFallback);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final profiles = savedRouting?['profiles'] as List?;
    final active = profiles?.cast<Map>().firstWhere(
      (item) => item['id'] == 'route_1',
    );
    expect(active?['fallback'], isEmpty);
    expect(savedRouting?['active_profile'], 'route_1');
    expect(find.textContaining('已移除备用模型'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings moves fallback model', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    Map<String, Object?>? savedRouting;
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          multiRoutingProfiles: true,
          activeRoutingProfile: 'route_1',
          withTwoRoutingFallbacks: true,
        ).raw;
      }
      if (method == 'provider.routing.save') {
        savedRouting = Map<String, Object?>.from(params);
        return {
          'active_routing_profile': params['active_profile'],
          'routing_profiles': params['profiles'],
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('常用模型'));
    await tester.pump(const Duration(milliseconds: 100));

    final moveDown = find.byTooltip('下移备用模型').first;
    await tester.ensureVisible(moveDown);
    await tester.pump();
    await tester.tap(moveDown);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final profiles = savedRouting?['profiles'] as List?;
    final active = profiles?.cast<Map>().firstWhere(
      (item) => item['id'] == 'route_1',
    );
    expect(active?['fallback'], [
      {
        'provider': 'RealProvider',
        'model': 'third-model',
        'reasoning_effort': 'auto',
      },
      {
        'provider': 'RealProvider',
        'model': 'backup-model',
        'reasoning_effort': 'auto',
      },
    ]);
    expect(calls, contains('provider.routing.save'));
    expect(calls, isNot(contains('provider.save')));
    expect(find.textContaining('备用模型顺序已更新'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('translation settings window localizes provider test failures', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      if (method == 'provider.test') {
        throw RpcRemoteException(
          'provider_connection_failed',
          'connection refused by upstream',
          details: {
            'error_info': {'hint_zh': '模型服务暂时连不上，请检查服务地址和网络。'},
          },
        );
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.translationSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('测试连接'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('模型服务暂时连不上'), findsOneWidget);
    expect(find.textContaining('connection refused'), findsNothing);
    expectNoFlutterException();
  });
}
