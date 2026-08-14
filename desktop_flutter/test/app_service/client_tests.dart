import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'app_service_test_support.dart';

void main() {
  test(
    'AppServiceClient calls runtime and result methods with typed payloads',
    () async {
      final transport = RecordingRpcTransport({
        'tasks.list': [
          {
            'task_id': 'tvx_done',
            'status': 'DONE',
            'input_file': r'D:\done.mp4',
            'task_dir': r'D:\artifacts\tvx_done',
          },
        ],
        'runtime.submitRun': {
          'ok': true,
          'task_id': 'tvx_1',
          'status': 'QUEUED',
          'task_dir': r'D:\artifacts\tvx_1',
          'terminal': false,
          'message': 'Task queued.',
        },
        'runtime.submitResume': {
          'ok': true,
          'task_id': 'tvx_1',
          'status': 'QUEUED',
          'task_dir': r'D:\artifacts\tvx_1',
          'terminal': false,
          'message': 'Resume queued.',
        },
        'runtime.cancel': {
          'task_id': 'tvx_1',
          'status': 'CANCEL_REQUESTED',
          'input_file': r'D:\input.mp4',
          'runtime': {'can_cancel': true},
        },
        'runtime.snapshot': {
          'active': {'task_id': 'tvx_1'},
          'queued': ['tvx_2'],
          'interrupted': [],
        },
        'tasks.events': {
          'task_id': 'tvx_1',
          'events': [
            {'message': 'Translating', 'progress': 0.5},
          ],
          'cursor': 0,
          'next_cursor': 1,
          'has_more': false,
        },
        'result.open': {
          'task': {
            'task_id': 'tvx_1',
            'status': 'DONE',
            'input_file': r'D:\input.mp4',
          },
          'segments': [
            {'id': 1, 'start': 0, 'end': 1, 'text_src': 'Hi'},
          ],
          'output_paths': {'srt': r'D:\out.srt'},
        },
        'result.segments.save': {
          'task': {
            'task_id': 'tvx_1',
            'status': 'DONE',
            'input_file': r'D:\input.mp4',
          },
          'segments': [
            {'id': 1, 'start': 0, 'end': 1, 'text_src': 'Hi', 'text_tgt': '嗨'},
          ],
          'output_paths': {'srt': r'D:\out.srt'},
        },
        'result.reexport': {
          'output_paths': {'srt': r'E:\fixed-output\out.srt'},
        },
      });
      final client = AppServiceClient(transport);

      final submitted = await client.submitRun({
        'input': r'D:\input.mp4',
        'source_lang': 'en',
        'target_lang': 'zh-CN',
        'overrides': {'output_format': 'both'},
      });
      final runtime = await client.runtimeSnapshot();
      final tasks = await client.taskList();
      final events = await client.taskEvents('tvx_1', cursor: 0, limit: 10);
      final result = await client.resultOpen('tvx_1');
      final workspace = await client.openTaskResult('tvx_1');
      final savedWorkspace = await client.resultSegmentsSave('tvx_1', [
        {'id': 1, 'start': 0, 'end': 1, 'text_src': 'Hi', 'text_tgt': '嗨'},
      ]);
      final reexported = await client.resultReexport(
        'tvx_1',
        outputFormat: 'srt',
        outputDir: r'E:\fixed-output',
        bilingual: false,
      );
      final resumed = await client.submitResume({
        'request_version': 1,
        'task_id': 'tvx_1',
        'overrides': {'output_format': 'srt'},
      });
      final cancelled = await client.cancel('tvx_1');

      expect(submitted.taskId, 'tvx_1');
      expect(resumed.message, 'Resume queued.');
      expect(cancelled.status, 'CANCEL_REQUESTED');
      expect(runtime.activeTaskId, 'tvx_1');
      expect(runtime.queued, ['tvx_2']);
      expect(tasks.single.taskId, 'tvx_done');
      expect(tasks.single.taskDir, r'D:\artifacts\tvx_done');
      expect(events.events, hasLength(1));
      expect(result['output_paths'], {'srt': r'D:\out.srt'});
      expect(workspace.task.taskId, 'tvx_1');
      expect(workspace.segments.single.id, 1);
      expect(savedWorkspace.segments.single.targetText, '嗨');
      expect(reexported['output_paths'], {'srt': r'E:\fixed-output\out.srt'});
      expect(
        transport.calls.first.params['request'],
        containsPair('input', r'D:\input.mp4'),
      );
      expect(transport.calls[3].params, containsPair('cursor', 0));
      expect(transport.calls[3].params, containsPair('limit', 10));
      expect(transport.calls[6].method, 'result.segments.save');
      expect(transport.calls[6].params, containsPair('task_id', 'tvx_1'));
      expect(transport.calls[6].params['segments'], isA<List>());
      expect(transport.calls[7].method, 'result.reexport');
      expect(transport.calls[7].params, containsPair('task_id', 'tvx_1'));
      expect(transport.calls[7].params, containsPair('output_format', 'srt'));
      expect(
        transport.calls[7].params,
        containsPair('output_dir', r'E:\fixed-output'),
      );
      expect(transport.calls[7].params, containsPair('bilingual', false));
      expect(transport.calls[8].method, 'runtime.submitResume');
      expect(
        transport.calls[8].params['request'],
        containsPair('task_id', 'tvx_1'),
      );
      expect(transport.calls[9].method, 'runtime.cancel');
      expect(transport.calls[9].params, containsPair('task_id', 'tvx_1'));
      expect(transport.calls[9].params, containsPair('force', false));
    },
  );

  test(
    'AppServiceClient creates a translation task from saved source',
    () async {
      final transport = RecordingRpcTransport({
        'runtime.retranslate': {
          'ok': true,
          'task_id': 'tvx_child',
          'status': 'QUEUED',
          'task_dir': r'D:\artifacts\tvx_child',
          'terminal': false,
          'message': 'Task queued.',
        },
      });
      final client = AppServiceClient(transport);

      final result = await client.retranslate(
        'tvx_parent',
        provider: 'p2',
        model: 'm2',
        overrides: {'memory_bootstrap_enabled': false},
      );

      expect(result.taskId, 'tvx_child');
      expect(transport.calls.single.method, 'runtime.retranslate');
      expect(transport.calls.single.params, {
        'task_id': 'tvx_parent',
        'provider': 'p2',
        'model': 'm2',
        'overrides': {'memory_bootstrap_enabled': false},
      });
    },
  );

  test('AppServiceClient calls provider and ASR admin methods', () async {
    final transport = RecordingRpcTransport({
      'provider.save': {'ok': true},
      'provider.models': {
        'status': 'PASS',
        'models': ['model-a'],
      },
      'provider.test': {'status': 'PASS', 'checks': []},
      'provider.delete': {'deleted': true},
      'provider.routing.save': {
        'routing': {
          'primary': {'provider': 'p1', 'model': 'model-a'},
        },
      },
      'asr.provider.save': {'ok': true, 'provider': 'openai_whisper'},
      'asr.setup.start': {
        'id': 'asr_setup_small',
        'kind': 'setup',
        'item_id': 'small',
        'state': 'queued',
        'phase': 'runtime',
        'phase_index': 0,
        'phase_count': 3,
      },
      'asr.storage.set': {
        'root': r'D:\TransVortex-ASR',
        'default_root': r'C:\Users\tester\AppData\Local\TransVortex',
        'customized': true,
        'free_bytes': 5000000000,
        'reserve_bytes': 268435456,
        'space_known': true,
        'writable': true,
        'can_change': true,
      },
      'network.settings.save': {
        'ok': true,
        'network': {'mode': 'local_proxy', 'proxy_port': 7890},
      },
    });
    final client = AppServiceClient(transport);

    await client.providerSave(
      providerDraft: {
        'name': 'p1',
        'models': ['model-a'],
      },
      apiKey: 'secret',
    );
    await client.providerModels(providerDraft: {'name': 'p1'});
    await client.providerTest(
      providerDraft: {'name': 'p1'},
      model: 'model-a',
      reasoningEffort: 'high',
    );
    await client.providerDelete(
      name: 'p1',
      expectedVersion: {'mtime_ns': 7, 'size': 8},
    );
    await client.saveTranslationRouting(
      provider: 'p1',
      model: 'model-a',
      fallback: [
        {'provider': 'p2', 'model': 'model-b'},
      ],
      expectedVersion: {'mtime_ns': 1, 'size': 2},
    );
    await client.saveTranslationRoutingProfiles(
      profiles: [
        {
          'id': 'route_1',
          'name': '配置 1',
          'primary': {'provider': 'p1', 'model': 'model-a'},
          'fallback': [],
        },
      ],
      activeProfile: 'route_1',
      nextProfileSeq: 2,
      expectedVersion: {'mtime_ns': 5, 'size': 6},
    );
    await client.asrProviderSave(
      providerDraft: {
        'name': 'openai_whisper',
        'kind': 'remote',
        'model': 'whisper-1',
      },
      expectedVersion: {'mtime_ns': 3, 'size': 4},
      setDefault: false,
    );
    final setup = await client.asrSetupStart('small');
    final storage = await client.asrStorageSet(r'D:\TransVortex-ASR');
    await client.networkSettingsSave(
      mode: 'local_proxy',
      proxyPort: 7890,
      expectedVersion: {'mtime_ns': 9, 'size': 10},
    );

    expect(transport.calls.map((call) => call.method), [
      'provider.save',
      'provider.models',
      'provider.test',
      'provider.delete',
      'provider.routing.save',
      'provider.routing.save',
      'asr.provider.save',
      'asr.setup.start',
      'asr.storage.set',
      'network.settings.save',
    ]);
    expect(setup.kind, 'setup');
    expect(setup.phase, 'runtime');
    expect(storage.root, r'D:\TransVortex-ASR');
    expect(storage.customized, isTrue);
    expect(storage.hasSpaceFor(1000000000), isTrue);
    expect(transport.calls[7].params, {'model_id': 'small'});
    expect(transport.calls[8].params, {'storage_root': r'D:\TransVortex-ASR'});
    expect(transport.calls.first.params['api_key'], 'secret');
    expect(transport.calls[2].params['reasoning_effort'], 'high');
    expect(transport.calls[3].params['name'], 'p1');
    expect(transport.calls[3].params['expected_version'], {
      'mtime_ns': 7,
      'size': 8,
    });
    expect(transport.calls[3].params.containsKey('api_key'), isFalse);
    expect(transport.calls[4].params['primary'], {
      'provider': 'p1',
      'model': 'model-a',
    });
    expect(transport.calls[4].params['fallback'], [
      {'provider': 'p2', 'model': 'model-b'},
    ]);
    expect(transport.calls[4].params['expected_version'], {
      'mtime_ns': 1,
      'size': 2,
    });
    expect(transport.calls[5].params['active_profile'], 'route_1');
    expect(transport.calls[5].params['next_profile_seq'], 2);
    expect(transport.calls[6].params['set_default'], isFalse);
    expect(transport.calls[5].params['expected_version'], {
      'mtime_ns': 5,
      'size': 6,
    });
    expect(
      transport.calls[6].params['provider_draft'],
      containsPair('kind', 'remote'),
    );
    expect(transport.calls[6].params['expected_version'], {
      'mtime_ns': 3,
      'size': 4,
    });
    expect(transport.calls.last.params, {
      'mode': 'local_proxy',
      'proxy_port': 7890,
      'expected_version': {'mtime_ns': 9, 'size': 10},
    });
  });

  test('AppServiceClient queries OpenRouter ASR key usage', () async {
    final transport = RecordingRpcTransport({
      'asr.provider.usage': {
        'currency': 'USD',
        'usage_usd': 1.25,
        'limit_remaining_usd': 8.75,
      },
    });
    final client = AppServiceClient(transport);

    final result = await client.asrProviderUsage(
      providerDraft: {'name': 'openrouter_asr', 'protocol': 'openrouter_stt'},
      apiKey: 'one-time-key',
    );

    expect(result['usage_usd'], 1.25);
    expect(transport.calls.single.method, 'asr.provider.usage');
    expect(transport.calls.single.params['provider_draft'], {
      'name': 'openrouter_asr',
      'protocol': 'openrouter_stt',
    });
    expect(transport.calls.single.params['api_key'], 'one-time-key');
  });

  test(
    'AppServiceClient validates an existing model with managed runtime',
    () async {
      final transport = RecordingRpcTransport({
        'asr.model.probe': {
          'ok': true,
          'model': {
            'model_id': 'large-v3',
            'model_path': r'D:\Models\large-v3',
          },
        },
      });
      final client = AppServiceClient(transport);

      final result = await client.probeExternalAsrModel(
        modelPath: r'D:\Models\large-v3',
        device: 'cuda',
        computeType: 'float16',
        acceleratorRoot: r'D:\CUDA',
      );

      expect(result['ok'], isTrue);
      expect(transport.calls.single.method, 'asr.model.probe');
      expect(transport.calls.single.params, {
        'model_path': r'D:\Models\large-v3',
        'device': 'cuda',
        'compute_type': 'float16',
        'accelerator_root': r'D:\CUDA',
      });
    },
  );

  test(
    'AppServiceClient activates verified ASR resources atomically',
    () async {
      final transport = RecordingRpcTransport({
        'asr.resources.activate': {'ok': true},
      });
      final client = AppServiceClient(transport);

      await client.activateAsrResources(
        provider: 'local',
        modelRegistrationId: 'model-reg',
        acceleratorRegistrationId: 'accelerator-reg',
        device: 'cuda',
        computeType: 'float16',
        expectedVersion: const {'mtime_ns': 1, 'size': 2},
      );

      expect(transport.calls.single.method, 'asr.resources.activate');
      expect(transport.calls.single.params, {
        'provider': 'local',
        'model_registration_id': 'model-reg',
        'accelerator_registration_id': 'accelerator-reg',
        'device': 'cuda',
        'compute_type': 'float16',
        'expected_version': {'mtime_ns': 1, 'size': 2},
      });
    },
  );

  test('AppServiceClient changes an external ASR model display name', () async {
    final transport = RecordingRpcTransport({
      'asr.model.label.set': {'ok': true},
    });
    final client = AppServiceClient(transport);

    await client.setExternalAsrModelLabel(
      registrationId: 'model-reg',
      userLabel: '日语访谈模型',
    );

    expect(transport.calls.single.method, 'asr.model.label.set');
    expect(transport.calls.single.params, {
      'registration_id': 'model-reg',
      'user_label': '日语访谈模型',
    });
  });

  test('AppServiceClient discovers models below a selected folder', () async {
    final transport = RecordingRpcTransport({
      'asr.model.discover': {
        'ok': true,
        'root': r'D:\Models',
        'scanned_directories': 12,
        'truncated': false,
        'candidates': [
          {
            'model_id': 'custom-123456789abc',
            'display_name': 'Custom faster-whisper model',
            'path': r'D:\Models\customer\snapshot',
            'relative_path': r'customer\snapshot',
            'model_bytes': 1234,
            'catalog_config_match': false,
          },
        ],
      },
    });
    final client = AppServiceClient(transport);

    final result = await client.discoverExternalAsrModels(r'D:\Models');

    expect(result.ok, isTrue);
    expect(result.scannedDirectories, 12);
    expect(result.candidates.single.modelId, 'custom-123456789abc');
    expect(result.candidates.single.modelBytes, 1234);
    expect(result.candidates.single.catalogConfigMatch, isFalse);
    expect(transport.calls.single.method, 'asr.model.discover');
    expect(transport.calls.single.params, {'search_root': r'D:\Models'});
  });

  test(
    'AppServiceClient manages memory collections with revision guards',
    () async {
      final collection = {
        'id': 'characters',
        'name': '人物名',
        'revision': 3,
        'entries': [
          {'id': 'subaru', 'source': 'スバル', 'target': '昴', 'status': 'locked'},
        ],
      };
      final transport = RecordingRpcTransport({
        'memory.collections.list': {
          'collections': [
            {...collection, 'entries': 1},
          ],
        },
        'memory.collection.get': {'collection': collection},
        'memory.entry.upsert': {'collection': collection},
        'memory.candidates.promote': {
          'applied': [
            {'entry_id': 'candidate-1'},
          ],
          'conflicts': [],
        },
      });
      final client = AppServiceClient(transport);

      final listed = await client.memoryCollections();
      final loaded = await client.memoryCollection('characters');
      await client.upsertMemoryEntry(
        'characters',
        expectedRevision: 3,
        entry: const {'source': 'エミリア', 'target': '爱蜜莉雅'},
      );
      final promoted = await client.promoteMemoryCandidates(
        taskId: 'task-1',
        collectionId: 'characters',
        entryIds: const ['candidate-1'],
        expectedRevision: 3,
        dryRun: true,
      );

      expect(listed.single.entryCount, 1);
      expect(loaded.entries.single.source, 'スバル');
      expect(promoted['applied'], hasLength(1));
      expect(transport.calls[2].params['expected_revision'], 3);
      expect(transport.calls[3].params, containsPair('dry_run', true));
      expect(transport.calls[3].params['entry_ids'], ['candidate-1']);
    },
  );

  test('AppServiceClient exposes translation style contracts', () async {
    const style = {
      'id': 'localized',
      'name': '本地化',
      'description': '自然处理文化表达',
      'prompt': 'Localize jokes naturally.',
      'revision': 2,
      'builtin': false,
    };
    final transport = RecordingRpcTransport({
      'translation.styles.list': {
        'styles': [style],
      },
      'translation.style.get': {'style': style},
      'translation.style.update': {'style': style},
    });
    final client = AppServiceClient(transport);

    final listed = await client.translationStyles();
    final loaded = await client.translationStyle('localized');
    await client.updateTranslationStyle(
      'localized',
      expectedRevision: 2,
      name: '本地化',
      description: '自然处理文化表达',
      prompt: 'Localize jokes naturally.',
    );

    expect(listed.single.name, '本地化');
    expect(loaded.prompt, 'Localize jokes naturally.');
    expect(transport.calls.last.params['expected_revision'], 2);
  });
}
