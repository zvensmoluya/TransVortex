import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transvortex_desktop_flutter/model/main_window_controller.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/current_window_controls.dart';
import 'package:transvortex_desktop_flutter/services/directory_probe.dart';
import 'package:transvortex_desktop_flutter/services/desktop_app_paths.dart';
import 'package:transvortex_desktop_flutter/services/local_service_controller.dart';
import 'package:transvortex_desktop_flutter/services/path_opener.dart';
import 'package:transvortex_desktop_flutter/services/task_notification_service.dart';
import 'package:transvortex_desktop_flutter/services/workspace_data_manager.dart';

void expectNoFlutterException() {
  final exception = TestWidgetsFlutterBinding.instance.takeException();
  expect(exception, isNull);
}

void installFilePickerMock(
  WidgetTester tester, {
  String name = 'movie.mp4',
  String path = r'D:\movie.mp4',
}) {
  FilePickerIO.registerWith();
  const pickerChannel = MethodChannel(
    'miguelruivo.flutter.plugins.filepicker',
    JSONMethodCodec(),
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pickerChannel,
      null,
    );
  });
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    pickerChannel,
    (call) async {
      expect(call.method, 'any');
      return [
        {'name': name, 'path': path, 'size': 1234},
      ];
    },
  );
}

Future<void> pickSourceAndStart(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('main-empty-pick-target')));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.text('开始译制'));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void activatePopupMenuItem(WidgetTester tester, Key key) {
  final dynamic state = tester.state(find.byKey(key));
  state.handleTap();
}

LocalServiceController readyController({DesktopSnapshot? snapshot}) {
  return LocalServiceController(
    sessionFactory: () async => FakeLocalServiceHandle(
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
      snapshot: snapshot ?? desktopSnapshotFixture(),
    ),
  );
}

Map<String, Object?> codexAgentClientPayload({bool ready = true}) {
  return {
    'schema_version': 1,
    'id': 'codex_cli',
    'name': 'Codex CLI',
    'default': true,
    'detected': ready,
    'ready': ready,
    'launch_supported': true,
    'executable': ready ? r'C:\Users\tester\AppData\Roaming\npm\codex.cmd' : '',
    'version': ready ? '0.144.6' : '',
    'version_label': ready ? 'codex-cli 0.144.6' : '',
    'status_code': ready ? 'ready' : 'codex_cli_not_found',
    'message': ready ? 'Codex CLI is ready' : 'Codex CLI was not found',
  };
}

Map<String, Object?> managedAsrResources({bool modelInstalled = true}) {
  return {
    'storage': {
      'root': r'D:\TransVortex-ASR',
      'default_root': r'D:\TransVortex-ASR',
      'space_known': true,
      'free_bytes': 10737418240,
      'writable': true,
      'can_change': true,
    },
    'runtime': {
      'id': 'managed:faster-whisper',
      'version': '1.0.0',
      'installed': true,
      'artifact': {'published': true, 'size': 559000000},
    },
    'models': [
      {
        'id': 'small',
        'display_name': 'Whisper Small',
        'revision': 'fixture-revision',
        'installed': modelInstalled,
        'size': 500000000,
      },
    ],
    'accelerators': const [],
    'environments': const [],
    'operations': const [],
  };
}

LocalServiceController controllerForTransport(
  FakeAppServiceTransport transport,
) {
  return LocalServiceController(
    sessionFactory: () async => FakeLocalServiceHandle.fromTransport(transport),
  );
}

DesktopSnapshot desktopSnapshotFixture({
  bool longModels = false,
  bool localModelSizeOnly = false,
  bool withProviders = true,
  bool withAsrProviders = true,
  String activeAsrProvider = 'local',
  Map<String, Object?> additionalAsrProviders = const {},
  bool managedAsr = false,
  String localModel = 'large-v3',
  String localModelSource = 'managed',
  String localModelPath = '',
  String managedModelSize = '',
  String externalModelId = '',
  String externalModelPath = '',
  String localDevice = 'auto',
  String localComputeType = 'auto',
  Map<String, Object?> localAccelerator = const {},
  bool? localCanRun,
  bool multiRoutingProfiles = false,
  String activeRoutingProfile = '',
  bool withRoutingFallback = false,
  bool withTwoRoutingFallbacks = false,
  String primaryReasoningEffort = '',
  List<Map<String, Object?>> tasks = const [],
  Map<String, Object?> runtime = const {},
  Map<String, Object?>? environment,
  Map<String, Object?> asrLocal = const {},
}) {
  final models = longModels
      ? [
          'gemini-3.5-flash',
          'gemini-3.1-pro-preview',
          'gemini-3.1-flash-lite-preview',
          'gemini-2.5-flash',
          'gemini-2.5-pro',
          'gemini-2.5-flash-lite',
          'gemini-2.0-flash-lite-preview-02-05',
        ]
      : [
          'real-model',
          if (multiRoutingProfiles) 'backup-model',
          if (withTwoRoutingFallbacks) 'third-model',
        ];
  final activeRouteId = activeRoutingProfile.isNotEmpty
      ? activeRoutingProfile
      : (multiRoutingProfiles ? 'route_1' : 'default');
  final routingProfiles = multiRoutingProfiles
      ? [
          {
            'id': 'route_1',
            'name': '配置 1',
            'primary': {
              'provider': 'RealProvider',
              'model': 'real-model',
              if (primaryReasoningEffort.isNotEmpty)
                'reasoning_effort': primaryReasoningEffort,
            },
            'fallback': withTwoRoutingFallbacks
                ? [
                    {'provider': 'RealProvider', 'model': 'backup-model'},
                    {'provider': 'RealProvider', 'model': 'third-model'},
                  ]
                : withRoutingFallback
                ? [
                    {'provider': 'RealProvider', 'model': 'backup-model'},
                  ]
                : const [],
          },
          {
            'id': 'route_2',
            'name': '配置 2',
            'primary': {'provider': 'RealProvider', 'model': 'backup-model'},
            'fallback': const [],
          },
        ]
      : [
          {
            'id': 'default',
            'name': 'Default',
            'primary': {
              'provider': 'RealProvider',
              'model': models.first,
              if (primaryReasoningEffort.isNotEmpty)
                'reasoning_effort': primaryReasoningEffort,
            },
            'fallback': [
              {'provider': 'RealProvider', 'model': 'real-model'},
            ],
          },
        ];
  final activeProfile = routingProfiles.firstWhere(
    (profile) => profile['id'] == activeRouteId,
    orElse: () => routingProfiles.first,
  );
  final activePrimary = Map<String, Object?>.from(
    activeProfile['primary'] as Map,
  );
  return DesktopSnapshot.fromJson({
    'config': {
      'routing': {
        'active_profile': activeProfile['id'],
        'primary': activePrimary,
        'fallback': [
          {'provider': 'RealProvider', 'model': 'real-model'},
        ],
      },
      'active_routing_profile': activeProfile['id'],
      'routing_profiles': routingProfiles,
      'routing_profile_next_seq': multiRoutingProfiles ? 3 : 1,
      'pipeline': {'asr_provider': activeAsrProvider},
      'pipeline_file_version': {'mtime_ns': 1, 'size': 2},
      'providers_file_version': {'mtime_ns': 3, 'size': 4},
      'network': {'mode': 'system', 'proxy_port': 0},
      'provider_presets': [
        {
          'id': 'deepseek',
          'label': 'DeepSeek',
          'api_type': 'openai-compatible',
          'compat_mode': 'openai_chat',
          'base_url': 'https://api.deepseek.com',
          'env_key': 'DEEPSEEK_API_KEY',
          'credential_id': 'deepseek',
          'models': ['deepseek-v4-flash', 'deepseek-v4-pro'],
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
          'auth': {
            'type': 'bearer',
            'header_name': 'Authorization',
            'prefix': 'Bearer ',
          },
          'endpoint': {'path_template': '/chat/completions', 'method': 'POST'},
          'request_mapping': {'style': 'openai_chat'},
          'response_mapping': {
            'text_paths': ['choices[0].message.content'],
          },
          'model_list': {
            'path_template': '/models',
            'method': 'GET',
            'response_paths': ['data[].id'],
          },
        },
        {
          'id': 'openai_official',
          'label': 'OpenAI',
          'api_type': 'openai-compatible',
          'compat_mode': 'openai_responses',
          'base_url': 'https://api.openai.com/v1',
          'env_key': 'OPENAI_API_KEY',
          'credential_id': 'openai',
          'models': ['gpt-5.5'],
          'endpoint': {'path_template': '/responses', 'method': 'POST'},
          'request_mapping': {'style': 'openai_responses'},
          'response_mapping': {
            'text_paths': ['output_text'],
          },
          'model_list': {
            'path_template': '/models',
            'method': 'GET',
            'response_paths': ['data[].id'],
          },
        },
      ],
      'protocol_templates': [
        {
          'id': 'openai_chat',
          'label': 'OpenAI-compatible Chat',
          'api_type': 'openai-compatible',
          'compat_mode': 'openai_chat',
          'base_url': 'https://api.openai.com/v1',
          'models': ['custom-model'],
          'endpoint': {'path_template': '/chat/completions', 'method': 'POST'},
          'request_mapping': {'style': 'openai_chat'},
          'response_mapping': {
            'text_paths': ['choices[0].message.content'],
          },
          'model_list': {
            'path_template': '/models',
            'method': 'GET',
            'response_paths': ['data[].id'],
          },
        },
        {
          'id': 'anthropic_messages',
          'label': 'Anthropic Messages',
          'api_type': 'anthropic',
          'compat_mode': 'anthropic_messages',
          'base_url': 'https://api.anthropic.com/v1',
          'models': ['claude-sonnet'],
          'endpoint': {'path_template': '/messages', 'method': 'POST'},
          'request_mapping': {'style': 'anthropic_messages'},
          'response_mapping': {
            'text_paths': ['content[].text'],
          },
          'model_list': {
            'path_template': '/models',
            'method': 'GET',
            'response_paths': ['data[].id'],
          },
        },
      ],
      'custom_adapter_template': {
        'id': 'custom_json',
        'label': 'Custom JSON',
        'api_type': 'custom',
        'compat_mode': 'custom_json',
        'base_url': 'https://example.com',
        'models': ['custom-model'],
        'endpoint': {'path_template': '/', 'method': 'POST'},
        'request_mapping': {
          'style': 'custom_json',
          'body_template': {'model': '{{model}}', 'prompt': '{{prompt}}'},
        },
        'response_mapping': {
          'text_paths': ['text'],
        },
        'model_list': {
          'path_template': '',
          'method': 'GET',
          'response_paths': [],
        },
      },
      'model_catalog': [
        {
          'id': 'gemini-3.5-flash',
          'label': 'Gemini 3.5 Flash',
          'vendor': 'Google',
          'aliases': ['models/gemini-3.5-flash', 'google/gemini-3.5-flash'],
          'source_label': 'Google Gemini 官方模型文档',
          'source_url':
              'https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash',
          'verified_at': '2026-07-13',
          'runtime': {
            'max_batch_lines': 240,
            'max_context_tokens': 1048576,
            'max_output_tokens': 65536,
            'recommended_output_tokens': 32768,
          },
          'pricing': {
            'kind': 'official_reference',
            'input_per_million_usd': 1.5,
            'output_per_million_usd': 9,
          },
        },
      ],
      'providers': withProviders
          ? [
              {
                'name': 'RealProvider',
                'has_key': true,
                'base_url': 'https://example.com/v1',
                'env_key': 'REAL_PROVIDER_KEY',
                'api_type': 'openai-compatible',
                'compat_mode': 'openai_chat',
                'credential_id': 'RealProvider',
                'credential_source': 'auth_json',
                'models': models,
                'capabilities': {
                  'max_batch_lines': 1000,
                  'max_output_tokens': 32768,
                  'recommended_output_tokens': 16384,
                  'reasoning_effort_param': 'reasoning_effort',
                  'reasoning_efforts': ['minimal', 'low', 'medium', 'high'],
                },
                'model_configs': {
                  models.first: {
                    'max_context_tokens': 128000,
                    'reasoning_effort': 'medium',
                  },
                },
              },
            ]
          : const [],
      'asr_providers': withAsrProviders
          ? {
              'local': {
                'name': 'Local ASR',
                'kind': managedAsr ? 'local_worker' : 'local_inprocess',
                'protocol': 'faster_whisper',
                if (!localModelSizeOnly) 'model': localModel,
                'local': {
                  if (localModelSizeOnly) 'model_size': localModel,
                  'model_source': localModelSource,
                  if (localModelPath.isNotEmpty) 'model_path': localModelPath,
                  if (managedModelSize.isNotEmpty)
                    'managed_model_size': managedModelSize,
                  if (externalModelId.isNotEmpty)
                    'external_model_id': externalModelId,
                  if (externalModelPath.isNotEmpty)
                    'external_model_path': externalModelPath,
                  'device': localDevice,
                  'compute_type': localComputeType,
                },
                'has_key': true,
                if (managedAsr)
                  'runtime': {
                    'source': 'managed',
                    'id': 'managed:faster-whisper',
                  },
                if (managedAsr && localAccelerator.isNotEmpty)
                  'accelerator': localAccelerator,
                if (managedAsr)
                  'readiness': {
                    'state': (localCanRun ?? localModelPath.isNotEmpty)
                        ? 'ready'
                        : 'checking',
                    'code': !(localCanRun ?? localModelPath.isNotEmpty)
                        ? 'model_installing'
                        : 'ready',
                    'can_run': localCanRun ?? localModelPath.isNotEmpty,
                    'primary_action':
                        !(localCanRun ?? localModelPath.isNotEmpty)
                        ? 'cancel_install'
                        : '',
                  },
              },
              ...additionalAsrProviders,
            }
          : const {},
      if (asrLocal.isNotEmpty) 'asr_local': asrLocal,
    },
    'tasks': tasks,
    'runtime': runtime,
    'environment': environment ?? doctorEnvironmentFixture(status: 'PASS'),
  });
}

Map<String, Object?> doctorEnvironmentFixture({
  String status = 'FAIL',
  List<Map<String, Object?>> extraChecks = const [],
}) {
  return {
    'status': status,
    'root_dir': r'D:\thevox\TransVortex',
    'providers_file': r'D:\thevox\TransVortex\providers.yaml',
    'artifacts_dir': r'D:\thevox\TransVortex\artifacts',
    'checks': [
      {
        'name': 'python',
        'status': 'PASS',
        'code': 'python_found',
        'message': 'Python is available',
        'hint_zh': 'Python 已可用。',
        'details': {'executable': r'C:\Python\python.exe'},
      },
      {
        'name': 'faster_whisper',
        'status': status == 'PASS' ? 'PASS' : 'FAIL',
        'code': status == 'PASS'
            ? 'faster_whisper_found'
            : 'faster_whisper_missing',
        'message': 'faster-whisper is required for local in-process ASR',
        'hint_zh': status == 'PASS'
            ? 'faster-whisper 已可用。'
            : '本地 ASR 需要 faster-whisper。请执行 python -m pip install -e .[asr]。',
        'details': {'provider': 'local', 'kind': 'local_inprocess'},
      },
      ...extraChecks,
    ],
  };
}

Map<String, Object?> taskPayload({
  String? taskId,
  required String status,
  required String inputFile,
  String? taskDir,
  double? progress,
  String? checkpointStatus,
  String? createdAt,
  String? updatedAt,
  Map<String, String> outputPaths = const {},
  Map<String, Object?> errorInfo = const {},
  Map<String, Object?> runtime = const {},
  Map<String, Object?> settings = const {},
  Map<String, Object?> progressDetail = const {},
  String? inputType,
}) {
  return {
    'task_id': taskId ?? 'tvx_widget_$status',
    'status': status,
    'input_file': inputFile,
    'input_type': ?inputType,
    'task_dir': ?taskDir,
    'source_lang': 'en',
    'target_lang': 'zh-CN',
    'bilingual': true,
    'progress': ?progress,
    'checkpoint_status': ?checkpointStatus,
    'created_at': ?createdAt,
    'updated_at': ?updatedAt,
    if (outputPaths.isNotEmpty) 'output_paths': outputPaths,
    if (errorInfo.isNotEmpty) 'error_info': errorInfo,
    if (runtime.isNotEmpty) 'runtime': runtime,
    if (settings.isNotEmpty) 'settings': settings,
    if (progressDetail.isNotEmpty) 'progress_detail': progressDetail,
  };
}

class FakeWorkspaceDataOperations implements WorkspaceDataOperations {
  String root = r'D:\TransVortexData';
  String? copiedTarget;
  bool removedSource = false;
  bool restoredConfiguration = false;
  bool discardedTarget = false;

  @override
  DesktopAppPaths currentPaths() => DesktopAppPaths(
    appDataRoot: Directory(r'D:\AppData\TransVortex'),
    configRoot: Directory(r'D:\AppData\TransVortex\Config'),
    workspaceRoot: Directory(root),
    tasksRoot: Directory('$root\\Tasks'),
    cacheRoot: Directory('$root\\Cache'),
  );

  @override
  Future<WorkspaceDataStatus> inspect() async => WorkspaceDataStatus(
    root: root,
    tasksBytes: 2048,
    cacheBytes: 1024,
    taskCount: 2,
  );

  @override
  Future<void> clearCache() async {}

  @override
  Future<WorkspaceMigrationReceipt> copyTo(
    String targetPath, {
    WorkspaceCopyProgress? onProgress,
  }) async {
    copiedTarget = targetPath;
    onProgress?.call(3072, 3072);
    return WorkspaceMigrationReceipt(
      sourceRoot: Directory(root),
      targetRoot: Directory(targetPath),
      configFile: File(r'D:\AppData\TransVortex\Config\workspace_storage.json'),
      previousConfig: null,
      targetExisted: false,
    );
  }

  @override
  Future<void> discardCopiedTarget(WorkspaceMigrationReceipt receipt) async {
    discardedTarget = true;
  }

  @override
  Future<void> removeMigratedSource(WorkspaceMigrationReceipt receipt) async {
    removedSource = true;
  }

  @override
  Future<void> restoreConfiguration(WorkspaceMigrationReceipt receipt) async {
    restoredConfiguration = true;
    root = receipt.sourceRoot.path;
  }
}

class FakeMainWindowSurfaceController implements MainWindowSurfaceController {
  FakeMainWindowSurfaceController({
    required this.bounds,
    required this.visibleBounds,
    this.onSetBounds,
  });

  Rect bounds;
  final Rect? visibleBounds;
  final ValueChanged<Rect>? onSetBounds;
  final List<Rect> writes = [];

  @override
  Future<Rect?> getBounds() async => bounds;

  @override
  Future<void> setBounds(Rect value) async {
    onSetBounds?.call(value);
    bounds = value;
    writes.add(value);
  }

  @override
  Future<Rect?> visibleBoundsFor(Rect bounds) async => visibleBounds;
}

class FakeLocalServiceHandle implements LocalServiceHandle {
  FakeLocalServiceHandle({
    required this.info,
    required this.health,
    required this.snapshot,
  }) : client = AppServiceClient(
         FakeAppServiceTransport({
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
           'media.inspect': {
             'kind': 'video',
             'source_mode': 'asr',
             'needs_asr': true,
             'available': true,
             'code': 'ready',
             'subtitle_streams': [],
             'selected_subtitle_stream': null,
           },
         }),
       );

  FakeLocalServiceHandle.fromTransport(FakeAppServiceTransport transport)
    : info = const ServiceInfo(
        service: 'transvortex.app_service',
        protocolVersion: 1,
        appVersion: 'test',
        capabilities: ['desktop_snapshot', 'runtime_pump'],
      ),
      health = const ServiceHealth(
        service: 'transvortex.app_service',
        status: 'healthy',
        runtime: {'active': null},
        pump: {'enabled': true},
      ),
      snapshot = DesktopSnapshot(
        config: const {},
        tasks: const [],
        runtime: const {},
        environment: const {},
        raw: const {},
      ),
      client = AppServiceClient(transport);

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

class FakeAppServiceTransport implements AppServiceTransport {
  FakeAppServiceTransport(
    this.results, {
    Map<String, List<RpcRemoteException>> failures = const {},
    Map<String, List<Object?>> sequences = const {},
  }) : failures = failures.map((key, value) => MapEntry(key, List.of(value))),
       sequences = sequences.map((key, value) => MapEntry(key, List.of(value)));

  final Map<String, Object?> results;
  final Map<String, List<RpcRemoteException>> failures;
  final Map<String, List<Object?>> sequences;
  final calls = <String>[];
  final lastParams = <String, Map<String, Object?>>{};

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    calls.add(method);
    lastParams[method] = params;
    final failure = failures[method];
    if (failure != null && failure.isNotEmpty) {
      throw failure.removeAt(0);
    }
    final sequence = sequences[method];
    if (sequence != null && sequence.isNotEmpty) {
      if (sequence.length == 1) return sequence.single;
      return sequence.removeAt(0);
    }
    return results[method];
  }

  @override
  Future<void> close() async {}
}

class RecordingTaskNotificationService implements TaskNotificationService {
  final completed = <String>[];
  final failed = <String>[];

  @override
  Future<void> notifyCompleted(MainWindowViewModel view) async {
    completed.add(view.source?.name ?? '');
  }

  @override
  Future<void> notifyFailed(MainWindowViewModel view) async {
    failed.add(view.failure?.reason ?? '');
  }
}

class RecordingPathOpener extends PathOpener {
  final openedDirectories = <String>[];
  final revealedFiles = <String>[];

  @override
  Future<void> revealFile(String path) async {
    revealedFiles.add(path);
  }

  @override
  Future<void> openDirectory(String path) async {
    openedDirectories.add(path);
  }
}

class RecordingDirectoryProbe extends DirectoryWriteProbe {
  RecordingDirectoryProbe(this.result);

  final DirectoryProbeResult result;
  final checkedPaths = <String>[];

  @override
  Future<DirectoryProbeResult> checkWritable(String path) async {
    checkedPaths.add(path);
    return result;
  }
}
