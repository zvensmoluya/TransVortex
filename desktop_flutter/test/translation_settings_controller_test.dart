import 'package:flutter_test/flutter_test.dart';
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
        expect(controller.selectedModelConfig?.maxContextTokens, '1000000');
        expect(controller.selectedModelConfig?.reasoningEffort, 'high');
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
      expect(save.params['api_key'], 'sk-test');
      expect(controller.message, '连接已保存。');
      expect(configChangedCount, 1);
    });

    test('model runtime settings are edited and saved per model', () async {
      await controller.load();
      controller.selectConnection('openai');

      expect(controller.selectedModel, 'gpt-4o');
      expect(controller.selectedModelConfig?.maxContextTokens, '128000');
      expect(controller.selectedModelConfig?.reasoningEffort, 'low');
      expect(controller.supportsReasoningEffort, isTrue);

      controller.editModelMaxBatchLines('180');
      controller.editModelMaxContextTokens('1M');
      controller.editModelMaxOutputTokens('64K');
      controller.editModelRecommendedOutputTokens('16k');
      controller.setModelReasoningEffort('medium');
      await controller.saveConnection();

      final save = transport.calls.firstWhere(
        (c) => c.method == 'provider.save',
      );
      final draft = save.params['provider_draft'] as Map<String, Object?>;
      final modelConfigs = draft['model_configs'] as Map<String, Object?>;
      final model = modelConfigs['gpt-4o'] as Map<String, Object?>;
      expect(model['max_batch_lines'], 180);
      expect(model['max_context_tokens'], 1000000);
      expect(model['max_output_tokens'], 64000);
      expect(model['recommended_output_tokens'], 16000);
      expect(model['reasoning_effort'], 'medium');
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
        maxOutputTokens: '384K',
        recommendedOutputTokens: '32.768K',
      ).toPayload();
      expect(payload['max_context_tokens'], 1000000);
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
        expect(controller.reasoningEfforts, ['high', 'max']);

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
        expect(controller.selectedModelConfig?.reasoningEffort, 'high');
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
        expect(controller.reasoningEfforts, [
          'none',
          'low',
          'medium',
          'high',
          'xhigh',
          'max',
        ]);

        controller.applySelectedModelRecommendation();
        expect(controller.selectedModelConfig?.maxContextTokens, '1050000');
        expect(controller.selectedModelConfig?.maxOutputTokens, '128000');
        expect(controller.selectedModelConfig?.reasoningEffort, 'low');
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

        expect(controller.error, contains('日常输出预算不能大于最大输出'));
        expect(callsAfterInitialLoad(), isEmpty);
      },
    );

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

    test('fetchModels merges results into the draft model list', () async {
      await controller.load();
      controller.selectConnection('openai');
      await controller.fetchModels();

      expect(controller.draft.models, contains('gpt-4o-mini'));
      final methods = callsAfterInitialLoad().map((c) => c.method).toList();
      expect(methods, isNot(contains('provider.routing.save')));
    });

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

class _RecordedCall {
  const _RecordedCall(this.method, this.params);

  final String method;
  final Map<String, Object?> params;
}
