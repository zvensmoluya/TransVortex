import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

import 'package:transvortex_desktop_flutter/model/translation_settings_controller.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';

void main() {
  group('TranslationSettingsController', () {
    late _RecordingTransport transport;
    late AppServiceClient client;
    late List<String> labelUpdates;
    late int configChangedCount;
    late TranslationSettingsController controller;

    setUp(() {
      transport = _RecordingTransport({
        'desktop.snapshot': _snapshot(),
        'provider.save': <String, Object?>{'provider': 'openai'},
        'provider.delete': <String, Object?>{'ok': true},
        'provider.models': <String, Object?>{
          'models': ['gpt-4o', 'gpt-4o-mini'],
        },
        'provider.test': <String, Object?>{
          'status': 'OK',
          'checks': [
            {'hint_zh': '连接正常'},
          ],
        },
        'provider.routing.save': <String, Object?>{'ok': true},
        'network.settings.save': <String, Object?>{
          'ok': true,
          'network': {'mode': 'local_proxy', 'proxy_port': 7890},
          'pipeline_file_version': {'mtime_ns': 3, 'size': 4},
        },
      });
      client = AppServiceClient(transport);
      labelUpdates = [];
      configChangedCount = 0;
      controller = TranslationSettingsController(
        client,
        (label, {required configured}) async {
          labelUpdates.add(label);
        },
        onConfigChanged: () async {
          configChangedCount += 1;
        },
      );
    });

    List<_RecordedCall> callsAfterInitialLoad() => transport.calls
        .skipWhile((c) => c.method == 'desktop.snapshot')
        .toList();

    test(
      'load reconciles selection to the routed primary connection',
      () async {
        await controller.load();

        expect(controller.selectedConnection, 'deepseek');
        expect(controller.draft.name, 'deepseek');
        expect(controller.draft.models, ['deepseek-v4-pro']);
        expect(controller.selectedModel, 'deepseek-v4-pro');
        expect(controller.selectedModelConfig?.maxContextTokens, isEmpty);
        expect(controller.selectedModelEffectiveMaxContextTokens, 1000000);
        expect(controller.selectedModelConfig?.reasoningEffort, isEmpty);
        expect(controller.profiles.length, 2);
        expect(controller.activeProfileId, 'default');
        expect(
          controller.primary,
          const ModelRef(connection: 'deepseek', model: 'deepseek-v4-pro'),
        );
      },
    );

    test('exposes the fields the smoke report mirrors', () async {
      await controller.load();

      // Smoke report keys: selected_provider / selected_model /
      // selected_provider_model_count are read off these getters.
      final provider =
          controller.selectedConnection ?? controller.primary?.connection;
      final model = controller.primary?.model ?? '';
      final modelCount = controller.connections
          .firstWhere((c) => c.name == provider)
          .models
          .length;
      expect(provider, 'deepseek');
      expect(model, 'deepseek-v4-pro');
      expect(modelCount, 1);
    });

    test('load keeps an explicit selection across a reload', () async {
      await controller.load();
      controller.selectConnection('openai');
      await controller.refresh();

      expect(controller.selectedConnection, 'openai');
    });

    test('saves the global local proxy port independently', () async {
      await controller.load();
      controller.switchTab(TranslationTab.network);
      controller.selectNetworkMode('local_proxy');
      controller.editProxyPort('7890');

      await controller.saveNetwork();

      final save = transport.calls.firstWhere(
        (call) => call.method == 'network.settings.save',
      );
      expect(save.params['mode'], 'local_proxy');
      expect(save.params['proxy_port'], 7890);
      expect(save.params['expected_version'], {'mtime_ns': 2, 'size': 3});
      expect(controller.networkMode, 'local_proxy');
      expect(controller.proxyPort, '7890');
      expect(controller.message, contains('127.0.0.1:7890'));
      expect(configChangedCount, 1);
    });

    test('rejects an invalid local proxy port before RPC', () async {
      await controller.load();
      controller.selectNetworkMode('local_proxy');
      controller.editProxyPort('70000');

      await controller.saveNetwork();

      expect(
        transport.calls.map((call) => call.method),
        isNot(contains('network.settings.save')),
      );
      expect(controller.error, contains('1 到 65535'));
    });

    test('ignores an invalid hidden proxy port outside proxy mode', () async {
      await controller.load();
      controller.selectNetworkMode('local_proxy');
      controller.editProxyPort('70000');
      controller.selectNetworkMode('direct');

      await controller.saveNetwork();

      final save = transport.calls.firstWhere(
        (call) => call.method == 'network.settings.save',
      );
      expect(save.params['mode'], 'direct');
      expect(save.params['proxy_port'], 0);
      expect(controller.error, isNull);
    });

    test('syncs an external network change without a refresh action', () async {
      await controller.load();
      final latest = _snapshot();
      final config = Map<String, Object?>.from(latest['config'] as Map);
      config['network'] = {'mode': 'local_proxy', 'proxy_port': 7897};
      config['pipeline_file_version'] = {'mtime_ns': 9, 'size': 10};
      transport.results['desktop.snapshot'] = {...latest, 'config': config};

      await controller.syncNetworkSettings();

      expect(controller.networkMode, 'local_proxy');
      expect(controller.proxyPort, '7897');
      expect(controller.networkDirty, isFalse);
      expect(controller.message, contains('自动同步'));
    });

    test('successful network sync clears an earlier sync error', () async {
      final flakyTransport = _FlakyNetworkSyncTransport();
      final flakyController = TranslationSettingsController(
        AppServiceClient(flakyTransport),
        (label, {required configured}) async {},
      );
      addTearDown(flakyController.dispose);
      await flakyController.load();

      await flakyController.syncNetworkSettings();
      expect(flakyController.error, isNotNull);

      await flakyController.syncNetworkSettings();
      expect(flakyController.error, isNull);
      expect(flakyController.networkSyncing, isFalse);
    });

    test(
      'save waits for focus sync and preserves an externally changed draft',
      () async {
        final pendingTransport = _PendingNetworkSyncTransport();
        final pendingController = TranslationSettingsController(
          AppServiceClient(pendingTransport),
          (label, {required configured}) async {},
        );
        addTearDown(pendingController.dispose);
        await pendingController.load();
        pendingController.selectNetworkMode('local_proxy');
        pendingController.editProxyPort('7890');

        final sync = pendingController.syncNetworkSettings();
        await pendingTransport.syncStarted.future;
        expect(pendingController.networkSyncing, isTrue);

        final save = pendingController.saveNetwork();
        pendingTransport.releaseSync.complete();
        await Future.wait([sync, save]);

        expect(
          pendingTransport.calls.where(
            (call) => call.method == 'network.settings.save',
          ),
          isEmpty,
        );
        expect(pendingController.networkDirty, isTrue);
        expect(pendingController.message, contains('未保存内容已保留'));

        await pendingController.saveNetwork();
        expect(
          pendingTransport.calls.where(
            (call) => call.method == 'network.settings.save',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'external network changes require confirming a preserved draft',
      () async {
        final externalTransport = _ExternalNetworkChangeTransport();
        final externalController = TranslationSettingsController(
          AppServiceClient(externalTransport),
          (label, {required configured}) async {},
        );
        addTearDown(externalController.dispose);
        await externalController.load();
        externalController.selectNetworkMode('local_proxy');
        externalController.editProxyPort('7890');

        await externalController.saveNetwork();

        expect(
          externalTransport.calls.where(
            (call) => call.method == 'network.settings.save',
          ),
          isEmpty,
        );
        expect(externalController.proxyPort, '7890');
        expect(externalController.networkDirty, isTrue);
        expect(externalController.message, contains('确认后再次保存'));

        await externalController.saveNetwork();

        final save = externalTransport.calls.singleWhere(
          (call) => call.method == 'network.settings.save',
        );
        expect(save.params['proxy_port'], 7890);
        expect(save.params['expected_version'], {'mtime_ns': 9, 'size': 10});
        expect(externalController.error, isNull);
      },
    );

    test(
      'network save resolves a version conflict without manual refresh',
      () async {
        final conflictTransport = _NetworkConflictTransport();
        final conflictController = TranslationSettingsController(
          AppServiceClient(conflictTransport),
          (label, {required configured}) async {},
        );
        addTearDown(conflictController.dispose);
        await conflictController.load();
        conflictController.selectNetworkMode('local_proxy');
        conflictController.editProxyPort('7890');

        await conflictController.saveNetwork();

        var saves = conflictTransport.calls
            .where((call) => call.method == 'network.settings.save')
            .toList();
        expect(saves, hasLength(1));
        expect(conflictController.message, contains('确认后再次保存'));

        await conflictController.saveNetwork();

        saves = conflictTransport.calls
            .where((call) => call.method == 'network.settings.save')
            .toList();
        expect(saves, hasLength(2));
        expect(saves.first.params['expected_version'], {
          'mtime_ns': 9,
          'size': 10,
        });
        expect(saves.last.params['expected_version'], {
          'mtime_ns': 9,
          'size': 10,
        });
        expect(conflictController.error, isNull);
        expect(conflictController.message, contains('127.0.0.1:7890'));
      },
    );

    test('saveConnection only writes the provider, never the route', () async {
      await controller.load();
      controller.selectConnection('openai');
      controller.editApiKey('sk-test');
      await controller.saveConnection();

      final methods = callsAfterInitialLoad().map((c) => c.method).toList();
      expect(methods, contains('provider.save'));
      expect(methods, isNot(contains('provider.routing.save')));

      final save = transport.calls.firstWhere(
        (c) => c.method == 'provider.save',
      );
      final draft = save.params['provider_draft'] as Map<String, Object?>;
      expect(draft['name'], 'openai');
      expect(draft['models'], contains('gpt-4o'));
      final modelConfigs = draft['model_configs'] as Map<String, Object?>;
      expect(
        modelConfigs['openai/gpt-5.6-terra'],
        isEmpty,
        reason:
            'inherited catalog and provider values must not become overrides',
      );
      expect(save.params['api_key'], 'sk-test');
      expect(controller.message, '连接已保存。');
      expect(configChangedCount, 1);
    });

    test(
      'connection failure keeps the localized hint and upstream error',
      () async {
        transport.results['provider.test'] = <String, Object?>{
          'status': 'FAIL',
          'checks': [
            {
              'hint_zh': 'Provider 拒绝了当前模型请求，请检查请求字段。',
              'message':
                  'provider upstream returned HTTP 400: '
                  '{"detail":"Unsupported parameter: temperature"}',
            },
          ],
        };
        await controller.load();

        await controller.testConnection();

        expect(controller.testResult?.ok, isFalse);
        expect(controller.testResult?.detail, contains('Provider 拒绝了当前模型请求'));
        expect(
          controller.testResult?.detail,
          contains('Unsupported parameter: temperature'),
        );
      },
    );

    test(
      'connection test uses the selected model and a session-only reasoning effort',
      () async {
        await controller.load();
        controller.selectConnection('openai');
        controller.selectModel('openai/gpt-5.6-terra');

        expect(controller.connectionTestReasoningSupport.supported, isTrue);
        expect(controller.connectionTestReasoningSupport.compactLabel, '低');

        controller.setConnectionTestReasoningEffort('high');
        await controller.testConnection();

        final test = transport.calls.lastWhere(
          (call) => call.method == 'provider.test',
        );
        expect(test.params['model'], 'openai/gpt-5.6-terra');
        expect(test.params['reasoning_effort'], 'high');
        final draft = test.params['provider_draft'] as Map<String, Object?>;
        final modelConfigs = draft['model_configs'] as Map<String, Object?>;
        expect(
          modelConfigs['openai/gpt-5.6-terra'],
          isEmpty,
          reason: 'the test effort must not become a saved model override',
        );
      },
    );

    test('model runtime settings are edited and saved per model', () async {
      await controller.load();
      controller.selectConnection('openai');

      expect(controller.selectedModel, 'gpt-4o');
      expect(controller.selectedModelConfig?.maxContextTokens, '128000');
      expect(controller.selectedModelConfig?.reasoningEffort, 'low');
      expect(
        controller
            .reasoningSupport(
              const ModelRef(connection: 'openai', model: 'gpt-4o'),
            )
            .supported,
        isTrue,
      );

      controller.editModelMaxBatchLines('180');
      controller.editModelMaxContextTokens('1M');
      controller.editModelMaxInputTokens('900K');
      controller.editModelMaxOutputTokens('64K');
      controller.editModelRecommendedOutputTokens('16k');
      await controller.saveConnection();

      final save = transport.calls.firstWhere(
        (c) => c.method == 'provider.save',
      );
      final draft = save.params['provider_draft'] as Map<String, Object?>;
      final modelConfigs = draft['model_configs'] as Map<String, Object?>;
      final model = modelConfigs['gpt-4o'] as Map<String, Object?>;
      expect(model['max_batch_lines'], 180);
      expect(model['max_context_tokens'], 1000000);
      expect(model['max_input_tokens'], 900000);
      expect(model['max_output_tokens'], 64000);
      expect(model['recommended_output_tokens'], 16000);
      expect(model['reasoning_effort'], 'low');
    });

    test('model capacity notation stays exact in editable fields', () {
      expect(ModelRuntimeDraft.parseNumber('1M'), 1000000);
      expect(ModelRuntimeDraft.parseNumber('128K'), 128000);
      expect(ModelRuntimeDraft.parseNumber('32.768K'), 32768);
      expect(ModelRuntimeDraft.compactInput('1000000'), '1M');
      expect(ModelRuntimeDraft.compactInput('32768'), '32768');
      expect(ModelRuntimeDraft.compactNumber('32768'), '32.8K');

      final payload = ModelRuntimeDraft(
        maxContextTokens: '1M',
        maxInputTokens: '900K',
        maxOutputTokens: '384K',
        recommendedOutputTokens: '32.768K',
      ).toPayload();
      expect(payload['max_context_tokens'], 1000000);
      expect(payload['max_input_tokens'], 900000);
      expect(payload['max_output_tokens'], 384000);
      expect(payload['recommended_output_tokens'], 32768);
    });

    test(
      'known DeepSeek models expose recommended and conservative profiles',
      () async {
        await controller.load();
        controller.selectConnection('deepseek');

        expect(
          controller.selectedModelRecommendationLabel,
          'DeepSeek V4 Pro 官方规格 · 240 行',
        );
        expect(controller.usesSelectedModelRecommendation, isFalse);
        expect(
          controller
              .reasoningSupport(controller.primary!)
              .choices
              .map((choice) => choice.value),
          ['auto', 'service_default', 'high', 'max'],
        );

        controller.applySelectedModelRecommendation();
        expect(controller.usesSelectedModelRecommendation, isTrue);

        controller.applyConservativeBatchLimit();
        expect(controller.selectedModelConfig?.maxBatchLines, '120');
        expect(controller.selectedModelConfig?.maxContextTokens, '1000000');
        expect(controller.usesConservativeBatchLimit, isTrue);
        expect(controller.usesSelectedModelRecommendation, isFalse);

        controller.applySelectedModelRecommendation();
        expect(controller.selectedModelConfig?.maxBatchLines, '240');
        expect(controller.selectedModelConfig?.maxOutputTokens, '384000');
        expect(
          controller.selectedModelConfig?.recommendedOutputTokens,
          '32768',
        );
        expect(controller.selectedModelConfig?.reasoningEffort, isEmpty);
        expect(controller.usesSelectedModelRecommendation, isTrue);

        await controller.saveConnection();
        final save = transport.calls.lastWhere(
          (call) => call.method == 'provider.save',
        );
        final draft = save.params['provider_draft'] as Map<String, Object?>;
        final modelConfigs = draft['model_configs'] as Map<String, Object?>;
        final model = modelConfigs['deepseek-v4-pro'] as Map<String, Object?>;
        expect(model['max_batch_lines'], 240);
        expect(model['max_context_tokens'], 1000000);
        expect(model['max_output_tokens'], 384000);
      },
    );

    test(
      'official catalog follows exact model aliases across gateways',
      () async {
        await controller.load();
        controller.selectConnection('openai');
        controller.selectModel('openai/gpt-5.6-terra');

        expect(controller.selectedModelCatalog?.id, 'gpt-5.6-terra');
        expect(
          controller.selectedModelRecommendationLabel,
          'GPT-5.6 Terra 官方规格 · 240 行',
        );
        expect(
          controller.selectedModelSourceSummary,
          contains('OpenAI 官方模型文档'),
        );
        expect(controller.selectedModelPriceSummary, contains('超过 272K'));
        expect(controller.selectedModelPriceSummary, contains('输入 2×'));
        expect(
          controller
              .reasoningSupport(
                const ModelRef(
                  connection: 'openai',
                  model: 'openai/gpt-5.6-terra',
                ),
              )
              .choices
              .map((choice) => choice.value),
          [
            'auto',
            'service_default',
            'none',
            'low',
            'medium',
            'high',
            'xhigh',
            'max',
          ],
        );

        controller.applySelectedModelRecommendation();
        expect(controller.selectedModelConfig?.maxContextTokens, '1050000');
        expect(controller.selectedModelConfig?.maxInputTokens, '922000');
        expect(controller.selectedModelConfig?.maxOutputTokens, '32768');
        expect(
          controller.selectedModelConfig?.recommendedOutputTokens,
          '16384',
        );
        expect(controller.selectedModelConfig?.reasoningEffort, isEmpty);
      },
    );

    test(
      'saveConnection rejects an output budget above model maximum',
      () async {
        await controller.load();
        controller.selectConnection('openai');
        controller.editModelMaxOutputTokens('1000');
        controller.editModelRecommendedOutputTokens('2000');

        await controller.saveConnection();

        expect(controller.error, contains('目标输出预算不能大于最大输出'));
        expect(callsAfterInitialLoad(), isEmpty);
      },
    );

    test('automatic batching clears only the line override', () async {
      await controller.load();
      controller.selectConnection('openai');
      controller.editModelMaxBatchLines('180');
      controller.editModelMaxContextTokens('256K');
      controller.editModelMaxInputTokens('224K');
      controller.editModelMaxOutputTokens('32K');
      controller.editModelRecommendedOutputTokens('16K');

      controller.useAutomaticBatchLimit();

      expect(controller.selectedModelConfig?.maxBatchLines, isEmpty);
      expect(controller.selectedModelConfig?.maxContextTokens, '256K');
      expect(controller.selectedModelConfig?.maxInputTokens, '224K');
      expect(controller.selectedModelConfig?.maxOutputTokens, '32K');
      expect(controller.selectedModelConfig?.recommendedOutputTokens, '16K');
    });

    test('setPrimary writes only the routing profiles', () async {
      await controller.load();
      await controller.setPrimary(
        const ModelRef(connection: 'openai', model: 'gpt-4o'),
      );

      final methods = callsAfterInitialLoad().map((c) => c.method).toList();
      expect(methods, contains('provider.routing.save'));
      expect(methods, isNot(contains('provider.save')));
      expect(methods, isNot(contains('desktop.snapshot')));

      final save = transport.calls.firstWhere(
        (c) => c.method == 'provider.routing.save',
      );
      expect(save.params['active_profile'], 'default');
      final profiles = save.params['profiles'] as List<Object?>;
      final active = profiles
          .map((p) => p as Map<String, Object?>)
          .firstWhere((p) => p['id'] == 'default');
      final primary = active['primary'] as Map<String, Object?>;
      expect(primary['provider'], 'openai');
      expect(primary['model'], 'gpt-4o');
      expect(labelUpdates, contains('openai · gpt-4o'));
      expect(configChangedCount, 1);
    });

    test('default reasoning effort is stored on the active route', () async {
      await controller.load();

      await controller.setPrimaryReasoningEffort('service_default');

      final save = transport.calls.firstWhere(
        (call) => call.method == 'provider.routing.save',
      );
      final profiles = save.params['profiles'] as List<Object?>;
      final active = profiles
          .map((item) => item as Map<String, Object?>)
          .firstWhere((item) => item['id'] == 'default');
      final primary = active['primary'] as Map<String, Object?>;
      expect(primary['provider'], 'deepseek');
      expect(primary['model'], 'deepseek-v4-pro');
      expect(primary['reasoning_effort'], 'service_default');
      expect(controller.primary?.reasoningEffort, 'service_default');
      expect(callsAfterInitialLoad().map((call) => call.method), [
        'provider.routing.save',
      ]);
    });

    test('addFallback appends a route without touching the provider', () async {
      await controller.load();
      await controller.addFallback(
        const ModelRef(connection: 'openai', model: 'gpt-4o'),
      );

      final methods = callsAfterInitialLoad().map((c) => c.method).toList();
      expect(methods, contains('provider.routing.save'));
      expect(methods, isNot(contains('provider.save')));
      expect(methods, isNot(contains('desktop.snapshot')));

      final save = transport.calls.firstWhere(
        (c) => c.method == 'provider.routing.save',
      );
      final profiles = save.params['profiles'] as List<Object?>;
      final active = profiles
          .map((p) => p as Map<String, Object?>)
          .firstWhere((p) => p['id'] == 'default');
      final fallback = active['fallback'] as List<Object?>;
      expect(fallback, isNotEmpty);
      expect((fallback.last as Map)['model'], 'gpt-4o');
    });

    test('addFallback rejects the current primary model', () async {
      await controller.load();
      await controller.addFallback(
        const ModelRef(connection: 'deepseek', model: 'deepseek-v4-pro'),
      );

      expect(controller.error, '这已经是主模型');
      expect(callsAfterInitialLoad(), isEmpty);
    });

    test('switchProfile persists the active profile id', () async {
      await controller.load();
      await controller.switchProfile('route_2');

      final save = transport.calls.firstWhere(
        (c) => c.method == 'provider.routing.save',
      );
      expect(save.params['active_profile'], 'route_2');
    });

    test('renameProfile updates the active profile name', () async {
      await controller.load();
      await controller.renameProfile('工作方案');

      final save = transport.calls.firstWhere(
        (c) => c.method == 'provider.routing.save',
      );
      final profiles = save.params['profiles'] as List<Object?>;
      final active = profiles
          .map((p) => p as Map<String, Object?>)
          .firstWhere((p) => p['id'] == 'default');
      expect(active['name'], '工作方案');
    });

    test(
      'createProfile allocates the next id and bumps the sequence',
      () async {
        await controller.load();
        await controller.createProfile('实验方案');

        final save = transport.calls.firstWhere(
          (c) => c.method == 'provider.routing.save',
        );
        expect(save.params['active_profile'], 'route_3');
        expect(save.params['next_profile_seq'], 4);
        final profiles = save.params['profiles'] as List<Object?>;
        expect(profiles.length, 3);
      },
    );

    test('deleteProfile falls back to the first surviving profile', () async {
      await controller.load();
      await controller.deleteProfile();

      final save = transport.calls.firstWhere(
        (c) => c.method == 'provider.routing.save',
      );
      expect(save.params['active_profile'], 'route_2');
      final profiles = save.params['profiles'] as List<Object?>;
      expect(profiles.length, 1);
    });

    test('deleteConnection surfaces the in-use guard', () async {
      transport.results['provider.delete'] = <String, Object?>{
        'blocked': true,
        'code': 'provider_in_use',
      };
      await controller.load();
      controller.selectConnection('deepseek');
      await controller.deleteConnection();

      expect(controller.error, contains('正在被常用模型使用'));
    });

    test(
      'fetchModels keeps discovery separate until a model is enabled',
      () async {
        await controller.load();
        controller.selectConnection('openai');
        await controller.fetchModels();

        expect(controller.discoveredModels, ['gpt-4o', 'gpt-4o-mini']);
        expect(controller.draft.models, isNot(contains('gpt-4o-mini')));

        controller.toggleDiscoveredModel('gpt-4o-mini');

        expect(controller.draft.models, contains('gpt-4o-mini'));
        expect(
          controller.selectedModel,
          'gpt-4o',
          reason:
              'enabling an upstream model must not change the model being edited',
        );
        final methods = callsAfterInitialLoad().map((c) => c.method).toList();
        expect(methods, isNot(contains('provider.routing.save')));
      },
    );

    test(
      'automatic model discovery caches until the connection is saved',
      () async {
        await controller.load();
        controller.selectConnection('openai');

        await controller.ensureModelsDiscovered();
        await controller.ensureModelsDiscovered();

        expect(controller.modelDiscoveryStatus, ModelDiscoveryStatus.ready);
        expect(
          transport.calls.where((call) => call.method == 'provider.models'),
          hasLength(1),
        );

        await controller.saveConnection();
        await controller.ensureModelsDiscovered();

        expect(
          transport.calls.where((call) => call.method == 'provider.models'),
          hasLength(2),
        );
      },
    );

    test(
      'removeModel rejects models referenced by a routing profile',
      () async {
        await controller.load();
        controller.removeModel('deepseek-v4-pro');

        expect(controller.error, contains('正在被常用模型使用'));
        expect(controller.draft.models, contains('deepseek-v4-pro'));
        expect(callsAfterInitialLoad(), isEmpty);
      },
    );
  });
}

Map<String, Object?> _snapshot() {
  return {
    'config': {
      'providers': [
        {
          'name': 'deepseek',
          'models': ['deepseek-v4-pro'],
          'has_key': true,
          'base_url': 'https://api.deepseek.com',
          'compat_mode': 'openai_chat',
          'api_type': 'openai-compatible',
          'credential_id': 'deepseek',
          'env_key': 'DEEPSEEK_API_KEY',
          'request_mapping': {
            'style': 'openai_chat',
            'body_overrides': {'reasoning_effort': 'high'},
          },
          'capabilities': {
            'max_batch_lines': 1000,
            'max_context_tokens': 1000000,
            'max_output_tokens': 384000,
            'recommended_output_tokens': 32768,
            'reasoning_effort_param': 'reasoning_effort',
            'reasoning_efforts': ['minimal', 'low', 'medium', 'high'],
          },
        },
        {
          'name': 'openai',
          'models': ['gpt-4o', 'openai/gpt-5.6-terra'],
          'has_key': true,
          'base_url': 'https://api.openai.com/v1',
          'compat_mode': 'openai_chat',
          'api_type': 'openai-compatible',
          'credential_id': 'openai',
          'env_key': 'OPENAI_API_KEY',
          'capabilities': {
            'max_batch_lines': 1000,
            'max_output_tokens': 32768,
            'recommended_output_tokens': 16384,
            'reasoning_effort_param': 'reasoning_effort',
            'reasoning_efforts': ['minimal', 'low', 'medium', 'high'],
          },
          'model_configs': {
            'gpt-4o': {'max_context_tokens': 128000, 'reasoning_effort': 'low'},
          },
        },
      ],
      'model_catalog': [
        {
          'id': 'gpt-5.6-terra',
          'label': 'GPT-5.6 Terra',
          'vendor': 'OpenAI',
          'aliases': ['openai/gpt-5.6-terra'],
          'reasoning_efforts': [
            'none',
            'low',
            'medium',
            'high',
            'xhigh',
            'max',
          ],
          'source_label': 'OpenAI 官方模型文档',
          'source_url':
              'https://developers.openai.com/api/docs/models/gpt-5.6-terra',
          'verified_at': '2026-07-13',
          'runtime': {
            'max_batch_lines': 240,
            'max_context_tokens': 1050000,
            'max_input_tokens': 922000,
            'max_output_tokens': 128000,
            'recommended_output_tokens': 32768,
            'reasoning_effort': 'low',
          },
          'pricing': {
            'kind': 'official_reference',
            'threshold_input_tokens': 272000,
            'above_threshold_input_multiplier': 2.0,
            'above_threshold_output_multiplier': 1.5,
          },
        },
        {
          'id': 'deepseek-v4-pro',
          'label': 'DeepSeek V4 Pro',
          'vendor': 'DeepSeek',
          'aliases': <String>[],
          'reasoning_efforts': ['high', 'max'],
          'source_label': 'DeepSeek 官方模型文档',
          'source_url': 'https://api-docs.deepseek.com/',
          'verified_at': '2026-07-13',
          'runtime': {
            'max_batch_lines': 240,
            'max_context_tokens': 1000000,
            'max_output_tokens': 384000,
            'recommended_output_tokens': 32768,
            'reasoning_effort': 'high',
          },
          'pricing': <String, Object?>{},
        },
      ],
      'provider_presets': [
        {
          'id': 'deepseek',
          'label': 'DeepSeek',
          'base_url': 'https://api.deepseek.com',
          'models': ['deepseek-v4-flash', 'deepseek-v4-pro'],
          'compat_mode': 'openai_chat',
          'protocol_template_id': 'openai_chat',
          'env_key': 'DEEPSEEK_API_KEY',
          'credential_id': 'deepseek',
          'capabilities': {
            'max_batch_lines': 240,
            'max_context_tokens': 1000000,
            'max_output_tokens': 384000,
            'recommended_output_tokens': 32768,
            'reasoning_effort_param': 'reasoning_effort',
            'reasoning_efforts': ['high', 'max'],
          },
          'model_configs': {
            for (final model in ['deepseek-v4-flash', 'deepseek-v4-pro'])
              model: {
                'max_batch_lines': 240,
                'max_context_tokens': 1000000,
                'max_output_tokens': 384000,
                'recommended_output_tokens': 32768,
                'reasoning_effort': 'high',
              },
          },
        },
      ],
      'protocol_templates': [
        {
          'id': 'openai_chat',
          'label': 'OpenAI Chat',
          'base_url': '',
          'compat_mode': 'openai_chat',
          'api_type': 'openai-compatible',
        },
      ],
      'routing_profiles': [
        {
          'id': 'default',
          'name': '默认方案',
          'primary': {'provider': 'deepseek', 'model': 'deepseek-v4-pro'},
          'fallback': <Object?>[],
        },
        {
          'id': 'route_2',
          'name': '方案 2',
          'primary': {'provider': 'openai', 'model': 'gpt-4o'},
          'fallback': [
            {'provider': 'deepseek', 'model': 'deepseek-v4-pro'},
          ],
        },
      ],
      'active_routing_profile': 'default',
      'routing_profile_next_seq': 3,
      'providers_file_version': {'mtime': 1, 'size': 2},
      'pipeline_file_version': {'mtime_ns': 2, 'size': 3},
      'network': {'mode': 'system', 'proxy_port': 0},
      'routing': {
        'primary': {'provider': 'deepseek', 'model': 'deepseek-v4-pro'},
        'fallback': <Object?>[],
        'active_profile': 'default',
        'next_profile_seq': 3,
      },
    },
  };
}

class _RecordingTransport implements AppServiceTransport {
  _RecordingTransport(this.results);

  final Map<String, Object?> results;
  final List<_RecordedCall> calls = [];

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    calls.add(_RecordedCall(method, params));
    if (!results.containsKey(method)) {
      throw RpcRemoteException('method_not_found', method);
    }
    return results[method];
  }

  @override
  Future<void> close() async {}
}

class _NetworkConflictTransport implements AppServiceTransport {
  final List<_RecordedCall> calls = [];
  var _snapshotCalls = 0;
  var _saveCalls = 0;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    calls.add(_RecordedCall(method, params));
    if (method == 'desktop.snapshot') {
      final snapshot = _snapshot();
      if (_snapshotCalls++ == 0) return snapshot;
      final config = Map<String, Object?>.from(snapshot['config'] as Map);
      config['pipeline_file_version'] = {'mtime_ns': 9, 'size': 10};
      return {...snapshot, 'config': config};
    }
    if (method == 'network.settings.save') {
      if (_saveCalls++ == 0) {
        throw RpcRemoteException(
          'network_config_conflict',
          'Network config changed on disk',
        );
      }
      return <String, Object?>{
        'ok': true,
        'network': {'mode': 'local_proxy', 'proxy_port': 7890},
        'pipeline_file_version': {'mtime_ns': 11, 'size': 12},
      };
    }
    throw RpcRemoteException('method_not_found', method);
  }

  @override
  Future<void> close() async {}
}

class _ExternalNetworkChangeTransport implements AppServiceTransport {
  final List<_RecordedCall> calls = [];
  var _snapshotCalls = 0;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    calls.add(_RecordedCall(method, params));
    if (method == 'desktop.snapshot') {
      final snapshot = _snapshot();
      if (_snapshotCalls++ == 0) return snapshot;
      final config = Map<String, Object?>.from(snapshot['config'] as Map);
      config['network'] = {'mode': 'local_proxy', 'proxy_port': 7897};
      config['pipeline_file_version'] = {'mtime_ns': 9, 'size': 10};
      return {...snapshot, 'config': config};
    }
    if (method == 'network.settings.save') {
      return <String, Object?>{
        'ok': true,
        'network': {'mode': 'local_proxy', 'proxy_port': 7890},
        'pipeline_file_version': {'mtime_ns': 11, 'size': 12},
      };
    }
    throw RpcRemoteException('method_not_found', method);
  }

  @override
  Future<void> close() async {}
}

class _FlakyNetworkSyncTransport implements AppServiceTransport {
  var _snapshotCalls = 0;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    if (method != 'desktop.snapshot') {
      throw RpcRemoteException('method_not_found', method);
    }
    if (_snapshotCalls++ == 1) {
      throw RpcRemoteException('service_unavailable', 'offline');
    }
    return _snapshot();
  }

  @override
  Future<void> close() async {}
}

class _PendingNetworkSyncTransport implements AppServiceTransport {
  final List<_RecordedCall> calls = [];
  final Completer<void> syncStarted = Completer<void>();
  final Completer<void> releaseSync = Completer<void>();
  var _snapshotCalls = 0;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    calls.add(_RecordedCall(method, params));
    if (method == 'desktop.snapshot') {
      final snapshot = _snapshot();
      final call = _snapshotCalls++;
      if (call == 0) return snapshot;
      if (call == 1) {
        syncStarted.complete();
        await releaseSync.future;
      }
      final config = Map<String, Object?>.from(snapshot['config'] as Map);
      config['network'] = {'mode': 'local_proxy', 'proxy_port': 7897};
      config['pipeline_file_version'] = {'mtime_ns': 9, 'size': 10};
      return {...snapshot, 'config': config};
    }
    if (method == 'network.settings.save') {
      return <String, Object?>{
        'ok': true,
        'network': {'mode': 'local_proxy', 'proxy_port': 7890},
        'pipeline_file_version': {'mtime_ns': 11, 'size': 12},
      };
    }
    throw RpcRemoteException('method_not_found', method);
  }

  @override
  Future<void> close() async {}
}

class _RecordedCall {
  const _RecordedCall(this.method, this.params);

  final String method;
  final Map<String, Object?> params;
}
