import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transvortex_desktop_flutter/main.dart';
import 'package:transvortex_desktop_flutter/model/window_state.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/window_state_bridge.dart';
import 'package:transvortex_desktop_flutter/widgets/settings_common.dart';
import 'package:transvortex_desktop_flutter/widgets/settings_window.dart';
import '../support/widget_test_support.dart';

void main() {
  testWidgets('ASR settings window saves default provider through bridge', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(700, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    Map<String, Object?>? activatedResources;
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          managedAsr: true,
          asrLocal: const {
            'runtime': {
              'id': 'managed:faster-whisper',
              'version': '1.0.0',
              'installed': true,
              'artifact': {'published': true, 'size': 100},
            },
            'models': [
              {
                'id': 'large-v3',
                'display_name': 'Whisper Large v3',
                'installed': true,
                'size': 100,
              },
            ],
            'accelerators': [],
            'environments': [],
            'operations': [],
          },
        ).raw;
      }
      if (method == 'asr.resources.activate') {
        activatedResources = Map<String, Object?>.from(params);
        return {'ok': true, 'provider': 'local'};
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('应用设置'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('asr.resources.activate'));
    expect(activatedResources?['provider'], 'local');
    expect(activatedResources?['managed_model_id'], 'large-v3');
    expect(activatedResources?['device'], 'auto');
    expect(activatedResources?['compute_type'], 'auto');
    expect(find.textContaining('识别默认已保存'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('ASR settings confirm, copy, and send scoped Agent handoffs', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
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
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? launchParams;
    var clientReady = true;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          managedAsr: true,
          localModel: 'small',
          asrLocal: managedAsrResources(),
        ).raw;
      }
      if (method == 'agent.entry.get') {
        return {
          'schema_version': 1,
          'registered': true,
          'asr_environment_handoff_text': 'read ASR workflow',
          'asr_environment_handoffs': {
            'inspect': 'inspect this machine',
            'prepare_model': 'prepare the model',
            'prepare_accelerator': 'prepare NVIDIA resources',
            'register': 'register existing resources',
            'full': 'read ASR workflow',
          },
        };
      }
      if (method == 'agent.client.get') {
        return codexAgentClientPayload(ready: clientReady);
      }
      if (method == 'agent.handoff.launch') {
        launchParams = Map<String, Object?>.from(params);
        return {
          'launched': true,
          'pid': 101,
          'workspace': r'D:\TransVortex\Cache\AgentHandoffs\handoff_1',
          'handoff_id': 'handoff_1',
          'workflow': 'asr_environment',
          'scope': params['scope'],
          'client': codexAgentClientPayload(),
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('交给 Agent'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('asr-agent-handoff')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('完整准备本机识别'), findsOneWidget);
    expect(find.text('只准备模型'), findsOneWidget);
    expect(find.text('只准备 GPU 加速'), findsOneWidget);
    expect(find.text('接入已有资源'), findsOneWidget);
    expect(find.text('了解本机环境'), findsOneWidget);
    expect(find.text('更多 Agent 操作'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('asr-agent-scope-accelerator')));
    await tester.pumpAndSettle();

    expect(clipboardText, isNull);
    expect(find.text('交给 Agent'), findsWidgets);
    expect(find.text('准备 GPU 加速'), findsOneWidget);
    expect(find.text('发送给 Codex'), findsOneWidget);
    expect(find.textContaining('Codex 账户额度'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-handoff-copy')));
    await tester.pumpAndSettle();
    expect(clipboardText, 'prepare NVIDIA resources');
    expect(find.text('“准备 GPU 加速”交接已复制；返回本窗口时会自动刷新。'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('asr-agent-handoff')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('asr-agent-scope-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-handoff-send')));
    await tester.pumpAndSettle();

    expect(launchParams, {
      'workflow': 'asr_environment',
      'scope': 'prepare_model',
    });
    expect(find.text('“准备模型”已发送给 Codex；返回本窗口时会自动刷新。'), findsOneWidget);

    clientReady = false;
    await tester.tap(find.byKey(const ValueKey('asr-agent-handoff')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('asr-agent-scope-inspect')));
    await tester.pumpAndSettle();
    expect(find.text('未检测到 Codex CLI，仍可复制交接。'), findsOneWidget);
    final sendButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('agent-handoff-send')),
    );
    expect(sendButton.onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('agent-handoff-copy')));
    await tester.pumpAndSettle();
    expect(clipboardText, 'inspect this machine');
    expectNoFlutterException();
  });

  testWidgets(
    'ASR settings leaves installed resource cleanup to app settings',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(760, 560));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      bridge.attachServiceCaller((method, params) async {
        if (method == 'desktop.snapshot') {
          return desktopSnapshotFixture(
            managedAsr: true,
            localModel: 'small',
            asrLocal: managedAsrResources(),
          ).raw;
        }
        throw RpcRemoteException('method_not_found', method);
      });

      await tester.pumpWidget(
        TransVortexApp(
          windowType: AppWindowType.asrSettings,
          store: store,
          bridge: bridge,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('本次设置'), findsNothing);
      expect(find.textContaining('复用现有'), findsNothing);
      expect(find.textContaining('当前版本不会'), findsNothing);
      expect(find.byKey(const ValueKey('asr-resource-manager')), findsNothing);
      expect(find.text('Whisper Small'), findsWidgets);
      expect(
        find.byKey(const ValueKey('asr-resource-remove-model-small')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('asr-download-storage')), findsNothing);
      expect(
        find.byKey(const ValueKey('application-settings-window')),
        findsNothing,
      );
      expectNoFlutterException();
    },
  );

  testWidgets('ASR settings keeps a bounded layout in wide windows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          managedAsr: true,
          localModel: 'small',
          asrLocal: managedAsrResources(),
        ).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final configuration = find.byKey(const ValueKey('asr-local-configuration'));
    expect(configuration, findsOneWidget);
    expect(tester.getSize(configuration).width, 860);
    expect(tester.getCenter(configuration).dx, closeTo(960, 1));
    expect(find.byType(SegmentButton), findsNWidgets(4));
    expectNoFlutterException();
  });

  testWidgets('ASR model plan presents managed resource storage as read only', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final asrLocal = managedAsrResources(modelInstalled: false);
    asrLocal['storage'] = {
      ...Map<String, Object?>.from(asrLocal['storage']! as Map),
      'can_change': false,
      'change_blocker': 'managed_resources_present',
    };
    final calls = <String>[];
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          managedAsr: true,
          localModel: 'small',
          asrLocal: asrLocal,
        ).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('当前版本不会'), findsNothing);
    expect(find.byKey(const ValueKey('asr-apply-summary')), findsOneWidget);
    expect(find.text(r'保存到 D:\TransVortex-ASR'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('asr-download-storage-change')),
      findsNothing,
    );
    expect(find.textContaining('已有组件固定在此位置'), findsNothing);
    expect(find.text('更改识别资源位置'), findsNothing);
    expect(calls, isNot(contains('asr.storage.set')));
    expectNoFlutterException();
  });

  testWidgets('ASR settings window omits the legacy default banner', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(localModelSizeOnly: true).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('默认识别：'), findsNothing);
    expect(find.text('本机 Whisper'), findsWidgets);
    expectNoFlutterException();
  });

  testWidgets(
    'ASR settings window keeps one engine selector without saved list',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(760, 560));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      bridge.attachServiceCaller((method, params) async {
        if (method == 'desktop.snapshot') {
          return desktopSnapshotFixture(withAsrProviders: false).raw;
        }
        throw RpcRemoteException('method_not_found', method);
      });

      await tester.pumpWidget(
        TransVortexApp(
          windowType: AppWindowType.asrSettings,
          store: store,
          bridge: bridge,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('默认识别：'), findsNothing);
      expect(find.text('本机 Whisper'), findsWidgets);
      expect(find.text('OpenAI Whisper'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
      expect(find.text('FunASR'), findsOneWidget);
      expect(find.text('已保存方案'), findsNothing);
      expect(find.text('下载并启用'), findsOneWidget);
      expect(find.textContaining('method_not_found'), findsNothing);
      expectNoFlutterException();
    },
  );

  testWidgets(
    'ASR settings keeps the selected engine across background refresh',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(820, 620));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      final openRouterProvider = <String, Object?>{
        'name': 'openrouter_asr',
        'kind': 'remote',
        'protocol': 'openrouter_stt',
        'base_url': 'https://openrouter.ai/api/v1',
        'endpoint': '/audio/transcriptions',
        'model': 'openai/whisper-large-v3',
        'auth': {
          'type': 'bearer',
          'env_key': 'OPENROUTER_API_KEY',
          'credential_id': 'openrouter_asr',
        },
        'has_key': false,
        'readiness': {
          'state': 'needs_action',
          'code': 'credential_missing',
          'can_run': false,
        },
      };
      bridge.attachServiceCaller((method, params) async {
        if (method == 'desktop.snapshot') {
          return desktopSnapshotFixture(
            activeAsrProvider: 'local',
            additionalAsrProviders: {'openrouter_asr': openRouterProvider},
          ).raw;
        }
        throw RpcRemoteException('method_not_found', method);
      });

      await tester.pumpWidget(
        TransVortexApp(
          windowType: AppWindowType.asrSettings,
          store: store,
          bridge: bridge,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      expect(find.text('OpenRouter API key（留空则沿用已保存密钥）'), findsOneWidget);

      final dynamic state = tester.state(find.byType(SettingsWindow));
      state.onWindowFocus();
      await tester.pumpAndSettle();

      expect(find.text('OpenRouter API key（留空则沿用已保存密钥）'), findsOneWidget);
      expect(find.text('下载并启用'), findsNothing);
      expectNoFlutterException();
    },
  );

  testWidgets('ASR settings saves a remote draft without making it default', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? savedParams;
    Map<String, Object?>? testedParams;
    final openAiProvider = <String, Object?>{
      'name': 'openai_whisper',
      'kind': 'remote',
      'protocol': 'openai_transcriptions',
      'base_url': 'https://api.openai.com/v1',
      'endpoint': '/v1/audio/transcriptions',
      'model': 'whisper-1',
      'auth': {
        'type': 'bearer',
        'env_key': 'OPENAI_API_KEY',
        'credential_id': 'openai_whisper',
      },
      'has_key': false,
      'readiness': {
        'state': 'needs_action',
        'code': 'credential_missing',
        'can_run': false,
        'primary_action': 'set_credential',
      },
    };
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          activeAsrProvider: 'local',
          additionalAsrProviders: {'openai_whisper': openAiProvider},
        ).raw;
      }
      if (method == 'asr.provider.save') {
        savedParams = Map<String, Object?>.from(params);
        return {
          'ok': true,
          'provider': 'openai_whisper',
          'default_changed': false,
          'active_provider': 'local',
        };
      }
      if (method == 'asr.provider.test') {
        testedParams = Map<String, Object?>.from(params);
        return {'ok': true, 'code': 'ready'};
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI Whisper').first);
    await tester.pumpAndSettle();

    expect(find.text('缺少密钥'), findsOneWidget);
    expect(find.textContaining('添加后才能设为默认并开始识别'), findsOneWidget);
    expect(find.text('保存配置'), findsOneWidget);
    expect(find.textContaining('先保存服务配置'), findsOneWidget);

    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();

    expect(savedParams?['set_default'], isFalse);
    expect(find.textContaining('识别配置已保存：OpenAI Whisper'), findsOneWidget);
    expect(find.text('OpenAI API key（留空则沿用已保存密钥）'), findsOneWidget);

    final keyInput = find.widgetWithText(Input, 'OpenAI API key（留空则沿用已保存密钥）');
    await tester.enterText(
      find.descendant(of: keyInput, matching: find.byType(TextField)),
      'example-token',
    );
    await tester.pump();

    expect(find.text('保存并设为默认'), findsOneWidget);
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(testedParams?['api_key'], 'example-token');
    expectNoFlutterException();
  });

  testWidgets('ASR settings exposes curated OpenRouter model profiles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(820, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? testedDraft;
    Map<String, Object?>? usageDraft;
    var usageCalls = 0;
    final initialUsage = Completer<Map<String, Object?>>();
    var asrTestResult = <String, Object?>{'ok': true, 'code': 'ready'};
    final openRouterProvider = <String, Object?>{
      'name': 'openrouter_asr',
      'kind': 'remote',
      'protocol': 'openrouter_stt',
      'base_url': 'https://openrouter.ai/api/v1',
      'endpoint': '/audio/transcriptions',
      'model': 'openai/whisper-large-v3',
      'auth': {
        'type': 'bearer',
        'env_key': 'OPENROUTER_API_KEY',
        'credential_id': 'openrouter_asr',
      },
      'has_key': true,
      'readiness': {'state': 'ready', 'code': 'ready', 'can_run': true},
      'engine_spec': {'id': 'openrouter_asr', 'kind': 'openrouter_asr'},
      'policy_resolution': {
        'policy': {
          'chunking': {'window_target_seconds': 300.0, 'overlap_seconds': 3.0},
          'execution': {'target_concurrency': 4},
        },
      },
      'capabilities': {
        'timeline': {
          'granularities': ['segment'],
        },
      },
      'available_models': [
        {
          'model': 'openai/whisper-large-v3',
          'display_name': 'Whisper Large V3',
          'status': 'candidate',
          'notes_zh': '要求分段时间戳。',
        },
        {
          'model': 'x-ai/grok-stt-1.0',
          'display_name': 'Grok STT 1.0',
          'status': 'experimental',
          'notes_zh': '使用词级时间戳生成字幕段，缺失时间戳时会停止任务。',
        },
      ],
    };
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          activeAsrProvider: 'openrouter_asr',
          additionalAsrProviders: {'openrouter_asr': openRouterProvider},
        ).raw;
      }
      if (method == 'asr.provider.test') {
        testedDraft = Map<String, Object?>.from(
          params['provider_draft']! as Map,
        );
        return asrTestResult;
      }
      if (method == 'asr.provider.usage') {
        usageCalls += 1;
        usageDraft = Map<String, Object?>.from(
          params['provider_draft']! as Map,
        );
        expect(params.containsKey('api_key'), isFalse);
        final usage = <String, Object?>{
          'currency': 'USD',
          'usage_usd': 0.25,
          'limit_usd': 1.0,
          'limit_remaining_usd': 0.75,
          'limit_reset': 'monthly',
        };
        if (usageCalls == 1) return initialUsage.future;
        return usage;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('OpenRouter'), findsOneWidget);
    expect(find.text('Whisper / Grok'), findsOneWidget);
    expect(find.text('OpenRouter API key（留空则沿用已保存密钥）'), findsOneWidget);
    expect(find.textContaining('时间轴候选：要求分段时间戳'), findsOneWidget);
    expect(
      find.textContaining('自动运行策略 · 分窗 300 秒 · 重叠 3 秒 · 并发目标 4 路 · 分段时间戳'),
      findsOneWidget,
    );
    expect(find.textContaining('音频会上传到 OpenRouter'), findsOneWidget);
    expect(find.text('查询中'), findsOneWidget);
    expect(
      tester
          .widget<ActionButton>(find.widgetWithText(ActionButton, '保存并设为默认'))
          .onTap,
      isNotNull,
    );
    expect(
      tester
          .widget<ActionButton>(find.widgetWithText(ActionButton, '测试连接'))
          .onTap,
      isNotNull,
    );
    expect(usageCalls, 1);

    initialUsage.complete({
      'currency': 'USD',
      'usage_usd': 0.25,
      'limit_usd': 1.0,
      'limit_remaining_usd': 0.75,
      'limit_reset': 'monthly',
    });
    await tester.pumpAndSettle();

    expect(find.text('查询用量'), findsOneWidget);
    expect(
      find.textContaining(
        'OpenRouter 密钥用量：本月已用 \$0.25 / \$1.00 · 剩余 \$0.75 · 每月重置',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Whisper Large V3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Grok STT 1.0 · 实验性').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('实验性模型：使用词级时间戳生成字幕段'), findsOneWidget);
    await tester.tap(find.text('查询用量'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'OpenRouter 密钥用量：本月已用 \$0.25 / \$1.00 · 剩余 \$0.75 · 每月重置',
      ),
      findsOneWidget,
    );
    expect(usageCalls, 2);
    expect(usageDraft?['protocol'], 'openrouter_stt');
    expect(usageDraft?['model'], 'x-ai/grok-stt-1.0');

    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    expect(find.textContaining('真实语音时间轴仍需在任务中验证'), findsOneWidget);
    expect(testedDraft?['protocol'], 'openrouter_stt');
    expect(testedDraft?['model'], 'x-ai/grok-stt-1.0');
    expect(testedDraft?['base_url'], 'https://openrouter.ai/api/v1');
    expect(testedDraft?['endpoint'], '/audio/transcriptions');
    expect((testedDraft?['auth'] as Map?)?['env_key'], 'OPENROUTER_API_KEY');
    expect(testedDraft?.containsKey('engine_spec'), isFalse);
    expect(testedDraft?.containsKey('policy_resolution'), isFalse);
    expect(testedDraft?.containsKey('capabilities'), isFalse);

    asrTestResult = {'ok': false, 'code': 'payment_required'};
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('模型服务账户余额不足'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('ASR settings shows unsaved state for edited OpenAI draft', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return desktopSnapshotFixture().raw;
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('OpenAI Whisper'));
    await tester.pump();

    final baseUrlInput = find.widgetWithText(Input, '服务地址 (Base URL)');
    final modelInput = find.widgetWithText(Input, '模型');
    expect(
      tester.widget<Input>(baseUrlInput).controller.text,
      'https://api.openai.com/v1',
    );
    expect(tester.widget<Input>(modelInput).controller.text, 'whisper-1');
    expect(find.text('接口路径 (Endpoint)'), findsNothing);

    await tester.enterText(
      find.descendant(of: baseUrlInput, matching: find.byType(TextField)),
      'https://api.openai.com/v1/',
    );
    await tester.pump();

    expect(find.text('尚未保存'), findsOneWidget);
    expect(find.textContaining('默认识别：'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('ASR settings shows an active verified model as enabled', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    var modelUserLabel = '日语访谈模型';
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          managedAsr: true,
          localModelSource: 'external',
          localModelPath: r'D:\Models\faster-whisper-large-v3',
          managedModelSize: 'large-v3',
          asrLocal: {
            'paths': {
              'app_data_root': r'C:\Users\tester\AppData\Local\TransVortex',
            },
            'runtime': {
              'id': 'managed:faster-whisper',
              'version': '1.0.0',
              'installed': true,
              'artifact': {'published': true, 'size': 100},
            },
            'models': [
              {
                'id': 'small',
                'display_name': 'Whisper Small',
                'installed': true,
                'size': 500000000,
              },
              {
                'id': 'medium',
                'display_name': 'Whisper Medium',
                'installed': false,
                'size': 1500000000,
              },
              {
                'id': 'large-v3',
                'display_name': 'Whisper Large v3',
                'installed': false,
                'size': 3113851289,
              },
            ],
            'accelerators': [],
            'environments': [],
            'operations': [],
            'registered_models': [
              {
                'id': 'model-large-registration',
                'model_id': 'large-v3',
                'model_path': r'D:\Models\faster-whisper-large-v3',
                'display_name': 'Whisper Large v3',
                'user_label': modelUserLabel,
                'signature': 'fixture-signature',
                'probe': {
                  'ok': true,
                  'model': {
                    'loaded': true,
                    'device': 'cpu',
                    'compute_type': 'auto',
                  },
                  'transcription': {'ok': true},
                },
              },
            ],
          },
        ).raw;
      }
      if (method == 'asr.model.label.set') {
        modelUserLabel = '${params['user_label'] ?? ''}';
        return {'ok': true};
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('应用管理'), findsNothing);
    expect(find.text('本地已有'), findsNothing);
    expect(find.text('当前使用'), findsNothing);
    expect(find.text('当前默认'), findsOneWidget);
    expect(find.text('当前方案'), findsOneWidget);
    expect(find.text('调整本机 Whisper'), findsNothing);
    expect(find.text('本地模型文件夹'), findsOneWidget);
    expect(find.text('日语访谈模型'), findsWidgets);
    expect(
      find.textContaining(r'D:\Models\faster-whisper-large-v3'),
      findsNothing,
    );
    expect(find.text('Python'), findsNothing);
    expect(find.textContaining('python.exe'), findsNothing);
    expect(find.text('查找登记环境'), findsNothing);
    expect(find.text('取消更改'), findsNothing);
    expect(find.text('已启用'), findsNothing);
    expect(find.text('验证并启用'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('asr-model-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('asr-model-user-label-input')),
      '采访专用模型',
    );
    await tester.tap(find.byKey(const ValueKey('asr-model-user-label-save')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(modelUserLabel, '采访专用模型');
    expect(find.text('采访专用模型'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('asr-model-change')));
    await tester.pumpAndSettle();
    expect(find.text('调整本机 Whisper'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('asr-managed-model-small')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('asr-managed-model-medium')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('asr-managed-model-large-v3')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('asr-external-model')), findsOneWidget);
    expect(find.text('即将应用'), findsNothing);
    expect(find.text('完成'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('当前方案'), findsOneWidget);
    expect(find.text('取消更改'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('asr-model-change')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('asr-managed-model-large-v3')));
    await tester.pumpAndSettle();
    expect(find.text('即将应用'), findsOneWidget);
    expect(find.textContaining('采访专用模型（本地文件夹）'), findsOneWidget);
    expect(find.text('需要下载 2.9 GB'), findsOneWidget);
    expect(find.text('下载并切换'), findsOneWidget);
    expect(find.text('取消更改'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets(
    'ASR settings activates Agent-prepared external CUDA without losing state',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(760, 620));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      const modelPath = r'D:\Models\large-v3';
      const acceleratorRoot = r'D:\External\CUDA';
      const modelRegistrationId = 'model-large-registration';
      const acceleratorRegistrationId = 'external:nvidia-cuda12:test';
      var activated = false;
      Map<String, Object?>? activatedResources;

      Map<String, Object?> asrLocal() => {
        'runtime': {
          'id': 'managed:faster-whisper',
          'version': '1.0.0',
          'installed': true,
          'artifact': {'published': true, 'size': 100},
        },
        'models': const [],
        'accelerators': const [],
        'environments': const [],
        'operations': const [],
        'registered_models': const [
          {
            'id': modelRegistrationId,
            'model_id': 'large-v3',
            'model_path': modelPath,
            'probe': {
              'ok': true,
              'model': {
                'loaded': true,
                'device': 'cuda',
                'compute_type': 'float16',
              },
              'transcription': {'ok': true},
            },
          },
        ],
        'registered_accelerators': const [
          {
            'id': acceleratorRegistrationId,
            'accelerator_id': 'nvidia-cuda12',
            'root': acceleratorRoot,
            'version': '12.4',
            'probe': {
              'ok': true,
              'cuda': {
                'available': true,
                'device_count': 1,
                'compute_types': ['float16', 'int8_float16'],
              },
            },
          },
        ],
        'active_execution': {
          'provider': 'local',
          'kind': 'local_worker',
          'model': 'large-v3',
          'requested_device': activated ? 'cuda' : 'cpu',
          'resolved_device': activated ? 'cuda' : 'cpu',
          'device_resolution': 'explicit_configuration',
          'compute_type': activated ? 'float16' : 'auto',
          'can_run': true,
          'model_resource': const {
            'source': 'external',
            'id': 'large-v3',
            'registration_id': modelRegistrationId,
            'path': modelPath,
            'state': 'ready',
            'ready': true,
          },
          'accelerator': {
            'source': activated ? 'external' : 'managed',
            'id': activated ? acceleratorRegistrationId : 'nvidia-cuda12',
            'registration_id': activated ? acceleratorRegistrationId : '',
            'root': activated ? acceleratorRoot : '',
            'version': activated ? '12.4' : '',
            'state': activated ? 'ready' : 'not_available',
            'ready': activated,
            'active': activated,
            'cuda': {
              'available': activated,
              'device_count': activated ? 1 : 0,
              'compute_types': activated
                  ? const ['float16', 'int8_float16']
                  : const <String>[],
            },
          },
        },
      };

      DesktopSnapshot snapshot() => desktopSnapshotFixture(
        managedAsr: true,
        localModel: 'large-v3',
        localModelSource: 'external',
        localModelPath: modelPath,
        externalModelId: 'large-v3',
        externalModelPath: modelPath,
        localDevice: activated ? 'cuda' : 'cpu',
        localComputeType: activated ? 'float16' : 'auto',
        localAccelerator: activated
            ? const {'source': 'external', 'id': acceleratorRegistrationId}
            : const {},
        localCanRun: true,
        asrLocal: asrLocal(),
      );

      bridge.attachServiceCaller((method, params) async {
        if (method == 'desktop.snapshot') return snapshot().raw;
        if (method == 'asr.resources.activate') {
          activatedResources = Map<String, Object?>.from(params);
          activated = true;
          return {'ok': true, 'provider': 'local'};
        }
        throw RpcRemoteException('method_not_found', method);
      });

      await tester.pumpWidget(
        TransVortexApp(
          windowType: AppWindowType.asrSettings,
          store: store,
          bridge: bridge,
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('当前方案'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('asr-model-change')));
      await tester.pumpAndSettle();
      expect(find.text('CPU'), findsOneWidget);
      expect(find.text('CPU（推荐）'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('运算方式:cpu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('NVIDIA（外部资源，已验证）').last);
      await tester.pumpAndSettle();
      expect(find.text('应用更改'), findsOneWidget);

      await tester.tap(find.text('应用更改'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(activatedResources?['model_registration_id'], modelRegistrationId);
      expect(
        activatedResources?['accelerator_registration_id'],
        acceleratorRegistrationId,
      );
      expect(activatedResources?['device'], 'cuda');
      expect(activatedResources?['compute_type'], 'float16');
      expect(find.text('当前方案'), findsOneWidget);
      expect(find.textContaining('NVIDIA · float16'), findsOneWidget);
      expectNoFlutterException();
    },
  );

  testWidgets('ASR settings finds model candidates below a parent folder', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    const selectedRoot = r'D:\Models';
    const customPath = r'D:\Models\customer\snapshot';
    const customId = 'custom-123456789abc';
    const registrationId = 'model-custom-registration';
    var savedPath = '';
    var savedModel = 'large-v3';
    var modelRegistered = false;
    Map<String, Object?>? activatedResources;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          managedAsr: true,
          localModel: savedModel,
          localModelSource: 'external',
          localModelPath: savedPath,
          asrLocal: {
            'paths': {
              'app_data_root': r'C:\Users\tester\AppData\Local\TransVortex',
            },
            'runtime': {
              'id': 'managed:faster-whisper',
              'version': '1.0.0',
              'installed': true,
              'artifact': {'published': true, 'size': 100},
            },
            'models': [],
            'accelerators': [],
            'environments': [],
            'operations': [],
            if (modelRegistered)
              'registered_models': [
                {
                  'id': registrationId,
                  'model_id': customId,
                  'model_path': customPath,
                  'probe': {
                    'ok': true,
                    'model': {
                      'loaded': true,
                      'device': 'cpu',
                      'compute_type': 'auto',
                    },
                    'transcription': {'ok': true},
                  },
                },
              ],
          },
        ).raw;
      }
      if (method == 'asr.model.discover') {
        expect(params['search_root'], selectedRoot);
        return {
          'ok': true,
          'root': selectedRoot,
          'scanned_directories': 8,
          'truncated': false,
          'candidates': const [
            {
              'model_id': 'small',
              'path': r'D:\Models\official\small',
              'relative_path': r'official\small',
              'model_bytes': 483546902,
              'catalog_config_match': true,
            },
            {
              'model_id': customId,
              'path': customPath,
              'relative_path': r'customer\snapshot',
              'model_bytes': 900000000,
              'catalog_config_match': false,
            },
          ],
        };
      }
      if (method == 'asr.model.probe') {
        expect(params['model_path'], customPath);
        modelRegistered = true;
        return {
          'ok': true,
          'code': 'ready',
          'model': {
            'id': registrationId,
            'model_id': customId,
            'model_path': customPath,
          },
        };
      }
      if (method == 'asr.resources.activate') {
        activatedResources = Map<String, Object?>.from(params);
        savedPath = customPath;
        savedModel = customId;
        return {'ok': true, 'provider': 'local'};
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
        directoryPicker: (_) async => selectedRoot,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const ValueKey('asr-model-change')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('asr-external-model')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('asr-external-model')));
    await tester.pumpAndSettle();

    expect(find.text('找到 2 个模型'), findsOneWidget);
    expect(find.text('Whisper Small'), findsWidgets);
    expect(find.text('自定义 Whisper'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('asr-model-candidate-$customPath')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining(customPath), findsNothing);
    expect(find.text('本地模型文件夹 · 等待验证'), findsOneWidget);

    await tester.tap(find.text('验证并启用'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(activatedResources?['model_registration_id'], registrationId);
    expect(activatedResources?['managed_model_id'], isNull);
    expect(activatedResources?['device'], 'auto');
    expect(find.textContaining('自定义 Whisper 验证通过，已设为默认'), findsOneWidget);
    expect(find.text('验证并启用'), findsNothing);
    expect(find.text('已启用'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('ASR settings validation pins its target and locks navigation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final probeResult = Completer<Map<String, Object?>>();
    const registrationId = 'model-small-registration';
    var modelRegistered = false;
    Map<String, Object?>? activatedResources;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          managedAsr: true,
          localModel: 'small',
          localModelSource: 'external',
          localModelPath: r'D:\Models\small',
          externalModelId: 'small',
          externalModelPath: r'D:\Models\small',
          localCanRun: false,
          asrLocal: {
            'runtime': {
              'id': 'managed:faster-whisper',
              'version': '1.0.0',
              'installed': true,
              'artifact': {'published': true, 'size': 100},
            },
            'models': [],
            'accelerators': [],
            'environments': [],
            'operations': [],
            if (modelRegistered)
              'registered_models': [
                {
                  'id': registrationId,
                  'model_id': 'small',
                  'model_path': r'D:\Models\small',
                  'probe': {
                    'ok': true,
                    'model': {
                      'loaded': true,
                      'device': 'cpu',
                      'compute_type': 'auto',
                    },
                    'transcription': {'ok': true},
                  },
                },
              ],
          },
        ).raw;
      }
      if (method == 'asr.model.probe') {
        return probeResult.future.then((value) {
          modelRegistered = true;
          return value;
        });
      }
      if (method == 'asr.resources.activate') {
        activatedResources = Map<String, Object?>.from(params);
        return {'ok': true, 'provider': 'local'};
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('验证并启用'));
    await tester.pump();

    expect(find.text('验证中'), findsOneWidget);
    final openAiButton = tester.widget<SegmentButton>(
      find.ancestor(
        of: find.text('OpenAI Whisper'),
        matching: find.byType(SegmentButton),
      ),
    );
    expect(openAiButton.onTap, isNull);

    probeResult.complete({
      'ok': true,
      'code': 'ready',
      'model': {
        'id': registrationId,
        'model_id': 'small',
        'model_path': r'D:\Models\small',
        'device': 'cpu',
      },
    });
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(activatedResources?['provider'], 'local');
    expect(activatedResources?['model_registration_id'], registrationId);
    expect(activatedResources?['device'], 'auto');
    expectNoFlutterException();
  });

  testWidgets('ASR settings keeps managed and external drafts independently', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    var activeSource = 'external';
    var activeModel = 'large-v3';
    var activePath = r'D:\Models\large-v3';
    var rememberedManaged = 'small';
    var rememberedExternal = 'large-v3';
    var rememberedExternalPath = r'D:\Models\large-v3';

    Map<String, Object?> snapshot() => desktopSnapshotFixture(
      managedAsr: true,
      localModel: activeModel,
      localModelSource: activeSource,
      localModelPath: activePath,
      managedModelSize: rememberedManaged,
      externalModelId: rememberedExternal,
      externalModelPath: rememberedExternalPath,
      localCanRun: true,
      asrLocal: const {
        'runtime': {
          'id': 'managed:faster-whisper',
          'version': '1.0.0',
          'installed': true,
          'artifact': {'published': true, 'size': 100},
        },
        'models': [
          {
            'id': 'small',
            'display_name': 'Whisper Small',
            'installed': true,
            'size': 100,
          },
        ],
        'accelerators': [],
        'environments': [],
        'operations': [],
        'registered_models': [
          {
            'id': 'model-large-registration',
            'model_id': 'large-v3',
            'model_path': r'D:\Models\large-v3',
            'signature': 'fixture-signature',
            'probe': {
              'ok': true,
              'model': {
                'loaded': true,
                'device': 'cpu',
                'compute_type': 'auto',
              },
              'transcription': {'ok': true},
            },
          },
        ],
      },
    ).raw;

    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') return snapshot();
      if (method == 'asr.resources.activate') {
        if ('${params['managed_model_id'] ?? ''}'.isNotEmpty) {
          activeSource = 'managed';
          activeModel = '${params['managed_model_id']}';
          activePath = '';
          rememberedManaged = activeModel;
        } else if ('${params['model_registration_id'] ?? ''}'.isNotEmpty) {
          activeSource = 'external';
          activeModel = rememberedExternal;
          activePath = rememberedExternalPath;
        }
        return {'ok': true, 'provider': 'local'};
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.byKey(const ValueKey('asr-model-open-location')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('asr-model-change')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('asr-managed-model-small')));
    await tester.pumpAndSettle();
    expect(find.text('应用更改'), findsOneWidget);

    await tester.tap(find.text('应用更改'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(activeSource, 'managed');
    expect(rememberedManaged, 'small');
    expect(rememberedExternal, 'large-v3');
    expect(rememberedExternalPath, r'D:\Models\large-v3');

    await tester.tap(find.byKey(const ValueKey('asr-model-change')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('asr-external-model')));
    await tester.pumpAndSettle();
    expect(find.text('已登记模型'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('asr-external-choice-confirm')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('asr-model-open-location')),
      findsOneWidget,
    );
    expect(find.text('本地模型文件夹 · 已验证'), findsOneWidget);
    expect(find.text('应用更改'), findsOneWidget);
    expect(find.text('验证并启用'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('ASR settings window renders managed component progress', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? cancelParams;
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          managedAsr: true,
          asrLocal: const {
            'runtime': {
              'id': 'managed:faster-whisper',
              'version': '1.0.0',
              'installed': false,
              'artifact': {'published': false, 'size': 0},
            },
            'models': [
              {
                'id': 'large-v3',
                'display_name': 'Whisper Large v3',
                'installed': false,
                'size': 100,
              },
            ],
            'accelerators': [],
            'environments': [],
            'operations': [
              {
                'id': 'asr_progress',
                'kind': 'setup',
                'item_id': 'large-v3',
                'state': 'running',
                'phase': 'model',
                'phase_index': 1,
                'phase_count': 3,
                'bytes_done': 25,
                'bytes_total': 100,
                'current_file': 'model.bin',
              },
            ],
          },
        ).raw;
      }
      if (method == 'asr.operation.cancel') {
        cancelParams = Map<String, Object?>.from(params);
        return {
          'id': 'asr_progress',
          'kind': 'setup',
          'item_id': 'large-v3',
          'state': 'cancelling',
          'phase': 'model',
          'phase_index': 1,
          'phase_count': 3,
          'bytes_done': 25,
          'bytes_total': 100,
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('正在下载 Whisper Large v3'), findsOneWidget);
    expect(find.text('识别引擎'), findsOneWidget);
    expect(find.text('识别模型'), findsOneWidget);
    expect(find.text('检查可用性'), findsOneWidget);
    expect(find.text('25 B / 100 B'), findsOneWidget);
    expect(find.textContaining('model.bin'), findsNothing);
    expect(find.text('取消下载'), findsOneWidget);

    await tester.tap(find.text('OpenAI Whisper'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('asr-background-operation')),
      findsOneWidget,
    );
    expect(find.textContaining('正在后台继续'), findsOneWidget);
    expect(find.widgetWithText(Input, '服务地址 (Base URL)'), findsOneWidget);

    await tester.tap(find.text('本机 Whisper'));
    await tester.pump();

    await tester.tap(find.text('取消下载'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(cancelParams, {'operation_id': 'asr_progress'});
    expect(find.text('正在取消…'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('ASR settings dismisses terminal operation feedback', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(920, 680));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    var snapshotCalls = 0;
    final running = {
      'id': 'asr_terminal',
      'kind': 'setup',
      'item_id': 'large-v3',
      'state': 'running',
      'phase': 'model',
      'phase_index': 1,
      'phase_count': 3,
      'bytes_done': 25,
      'bytes_total': 100,
      'current_file': 'model.bin',
    };
    final terminal = {
      'id': 'asr_terminal',
      'kind': 'setup',
      'item_id': 'large-v3',
      'state': 'completed',
      'phase': 'activate',
      'phase_index': 2,
      'phase_count': 3,
      'bytes_done': 100,
      'bytes_total': 100,
      'current_file': '',
    };
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        snapshotCalls += 1;
        return desktopSnapshotFixture(
          managedAsr: true,
          asrLocal: {
            'runtime': {
              'id': 'managed:faster-whisper',
              'version': '1.0.0',
              'installed': true,
              'artifact': {'published': true, 'size': 100},
            },
            'models': [
              {
                'id': 'large-v3',
                'display_name': 'Whisper Large v3',
                'installed': false,
                'size': 100,
              },
            ],
            'accelerators': [],
            'environments': [],
            'operations': snapshotCalls <= 2 ? [running] : const [],
          },
        ).raw;
      }
      if (method == 'asr.operation.get') return terminal;
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在下载 Whisper Large v3'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Whisper Large v3 已准备好'), findsOneWidget);
    expect(find.textContaining('已下载，可在本机 Whisper 中启用'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2300));
    expect(find.text('Whisper Large v3 已准备好'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('ASR settings keeps cancelled setup recovery visible', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    var snapshotCalls = 0;
    final running = {
      'id': 'asr_cancelled',
      'kind': 'setup',
      'item_id': 'small',
      'state': 'running',
      'phase': 'model',
      'phase_index': 1,
      'phase_count': 3,
      'bytes_done': 25,
      'bytes_total': 100,
    };
    final cancelled = {
      ...running,
      'state': 'cancelled',
      'error_code': 'cancelled',
      'message': 'partial data kept',
    };
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        snapshotCalls += 1;
        return desktopSnapshotFixture(
          managedAsr: true,
          asrLocal: {
            'runtime': {
              'id': 'managed:faster-whisper',
              'version': '1.0.0',
              'installed': true,
              'artifact': {'published': true, 'size': 100},
            },
            'models': [
              {
                'id': 'small',
                'display_name': 'Whisper Small',
                'installed': false,
                'size': 100,
              },
            ],
            'accelerators': const [],
            'environments': const [],
            'operations': snapshotCalls <= 2 ? [running] : const [],
          },
        ).raw;
      }
      if (method == 'asr.operation.get') return cancelled;
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('继续下载'), findsOneWidget);
    expect(find.textContaining('已校验的部分会保留'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2400));

    expect(find.text('继续下载'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('ASR settings defers managed activation until setup completes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    var serviceRefreshes = 0;
    Map<String, Object?>? setupParams;
    bridge.attachServiceRefresher(() async {
      serviceRefreshes += 1;
    });
    final snapshot = desktopSnapshotFixture(
      withAsrProviders: false,
      asrLocal: const {
        'paths': {
          'app_data_root': r'C:\Users\tester\AppData\Local\TransVortex',
        },
        'runtime': {
          'id': 'managed:faster-whisper',
          'version': '1.0.0',
          'installed': false,
          'artifact': {'published': true, 'size': 100},
        },
        'models': [
          {
            'id': 'small',
            'display_name': 'Whisper Small',
            'installed': false,
            'size': 200,
          },
        ],
        'accelerators': [],
        'environments': [],
        'operations': [],
      },
    );
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'desktop.snapshot') return snapshot.raw;
      if (method == 'asr.setup.start') {
        setupParams = Map<String, Object?>.from(params);
        return {
          'id': 'asr_setup_small',
          'kind': 'setup',
          'item_id': 'small',
          'state': 'running',
          'phase': 'runtime',
          'phase_index': 0,
          'phase_count': 3,
          'bytes_done': 0,
          'bytes_total': 300,
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(const ValueKey('asr-managed-model-small')),
      findsOneWidget,
    );
    expect(find.text('需下载 200 B'), findsOneWidget);
    expect(find.text('Whisper Small'), findsWidgets);
    expect(find.text('自动（当前：CPU）'), findsOneWidget);
    expect(find.text('需要下载 300 B'), findsOneWidget);
    expect(find.text('下载并启用'), findsOneWidget);

    await tester.tap(find.text('下载并启用'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('asr.setup.start'));
    expect(calls, isNot(contains('asr.provider.save')));
    expect(calls, isNot(contains('asr.component.install')));
    expect(serviceRefreshes, 1);
    expect(setupParams, {
      'model_id': 'small',
      'activate_on_complete': true,
      'provider': 'faster_whisper_large_v3',
      'device': 'auto',
      'compute_type': 'auto',
    });
    expect(find.text('正在下载本地识别引擎'), findsOneWidget);
    expect(find.textContaining('关闭此窗口'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('ASR settings shows managed download location as read only', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    const defaultRoot = r'C:\Users\tester\AppData\Local\TransVortex';
    const selectedRoot = r'D:\TransVortex-ASR';
    var customized = false;
    final storageCalls = <Map<String, Object?>>[];

    Map<String, Object?> localSnapshot() => {
      'paths': {
        'app_data_root': defaultRoot,
        'storage_root': customized ? selectedRoot : defaultRoot,
      },
      'storage': {
        'root': customized ? selectedRoot : defaultRoot,
        'default_root': defaultRoot,
        'customized': customized,
        'free_bytes': 20 * 1024 * 1024 * 1024,
        'total_bytes': 100 * 1024 * 1024 * 1024,
        'reserve_bytes': 256 * 1024 * 1024,
        'space_known': true,
        'writable': true,
        'can_change': true,
        'change_blocker': '',
      },
      'runtime': {
        'id': 'managed:faster-whisper',
        'version': '1.0.0',
        'installed': false,
        'artifact': {'published': true, 'size': 100 * 1024 * 1024},
      },
      'models': [
        {
          'id': 'small',
          'display_name': 'Whisper Small',
          'installed': false,
          'size': 500 * 1024 * 1024,
        },
      ],
      'accelerators': const [],
      'environments': const [],
      'operations': const [],
    };

    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          withAsrProviders: false,
          asrLocal: localSnapshot(),
        ).raw;
      }
      if (method == 'asr.storage.set') {
        storageCalls.add(Map<String, Object?>.from(params));
        customized = true;
        return Map<String, Object?>.from(localSnapshot()['storage']! as Map);
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
        directoryPicker: (_) async => selectedRoot,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('更改'), findsNothing);
    expect(find.textContaining('可用 20.0 GB'), findsOneWidget);
    expect(find.textContaining(defaultRoot), findsOneWidget);
    expect(
      find.byKey(const ValueKey('asr-download-storage-change')),
      findsNothing,
    );
    expect(storageCalls, isEmpty);
    expect(find.text('默认'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('ASR settings blocks managed download when target is full', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          withAsrProviders: false,
          asrLocal: const {
            'paths': {'app_data_root': r'C:\TVX'},
            'storage': {
              'root': r'C:\TVX',
              'default_root': r'C:\TVX',
              'free_bytes': 128,
              'reserve_bytes': 256,
              'space_known': true,
              'writable': true,
              'can_change': true,
            },
            'runtime': {
              'id': 'managed:faster-whisper',
              'installed': false,
              'artifact': {'published': true, 'size': 100},
            },
            'models': [
              {'id': 'small', 'installed': false, 'size': 200},
            ],
            'accelerators': [],
            'environments': [],
            'operations': [],
          },
        ).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.asrSettings,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('保存空间不足'), findsOneWidget);
    expect(find.textContaining('至少需要'), findsOneWidget);
    expect(find.text('更改'), findsNothing);
    expectNoFlutterException();
  });
}
