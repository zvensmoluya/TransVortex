import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/model/translation_settings_controller.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';

void main() {
  group('TranslationSettingsController', () {
    late _RecordingTransport transport;
    late AppServiceClient client;
    late List<String> labelUpdates;
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
      controller = TranslationSettingsController(client, (
        label, {
        required configured,
      }) async {
        labelUpdates.add(label);
      });
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
    });

    test('setPrimary writes only the routing profiles', () async {
      await controller.load();
      await controller.setPrimary(
        const ModelRef(connection: 'openai', model: 'gpt-4o'),
      );

      final methods = callsAfterInitialLoad().map((c) => c.method).toList();
      expect(methods, contains('provider.routing.save'));
      expect(methods, isNot(contains('provider.save')));

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
    });

    test('addFallback appends a route without touching the provider', () async {
      await controller.load();
      await controller.addFallback(
        const ModelRef(connection: 'openai', model: 'gpt-4o'),
      );

      final methods = callsAfterInitialLoad().map((c) => c.method).toList();
      expect(methods, contains('provider.routing.save'));
      expect(methods, isNot(contains('provider.save')));

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
        },
        {
          'name': 'openai',
          'models': ['gpt-4o'],
          'has_key': true,
          'base_url': 'https://api.openai.com/v1',
          'compat_mode': 'openai_chat',
          'api_type': 'openai-compatible',
          'credential_id': 'openai',
          'env_key': 'OPENAI_API_KEY',
        },
      ],
      'provider_presets': [
        {
          'id': 'deepseek',
          'label': 'DeepSeek',
          'base_url': 'https://api.deepseek.com',
          'models': ['deepseek-v4-pro'],
          'compat_mode': 'openai_chat',
          'protocol_template_id': 'openai_chat',
          'env_key': 'DEEPSEEK_API_KEY',
          'credential_id': 'deepseek',
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
