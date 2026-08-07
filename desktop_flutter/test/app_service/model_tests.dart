import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/model/task_labels.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'app_service_test_support.dart';

void main() {
  test(
    'AppServiceClient parses service info, health, and snapshot readiness',
    () async {
      final client = AppServiceClient(
        FakeRpcTransport({
          'service.info': {
            'service': 'transvortex.app_service',
            'protocol_version': 1,
            'app_version': '1.2.3',
            'capabilities': ['desktop_snapshot', 'runtime_pump'],
          },
          'service.health': {
            'service': 'transvortex.app_service',
            'status': 'healthy',
            'runtime': {
              'active': {'task_id': 'tvx_1', 'status': 'RUNNING'},
            },
            'pump': {'enabled': true},
          },
          'desktop.snapshot': {
            'config': {
              'routing': {
                'primary': {'provider': 'p2', 'model': 'model-b'},
              },
              'pipeline': {'asr_provider': 'local'},
              'providers': [
                {'name': 'p1', 'has_key': false},
                {'name': 'p2', 'has_key': true},
              ],
              'asr_providers': {
                'local': {'name': 'Local ASR', 'has_key': true},
              },
            },
            'tasks': ['task-a', 'task-b'],
            'runtime': {},
            'environment': {},
          },
        }),
      );

      final info = await client.info();
      final health = await client.health();
      final snapshot = await client.desktopSnapshot();

      expect(info.protocolVersion, 1);
      expect(info.capabilities, contains('runtime_pump'));
      expect(health.activeTaskLabel, 'tvx_1 · 制作中');
      expect(health.pumpLabel, 'running');
      expect(snapshot.tasks, hasLength(2));
      expect(snapshot.configReadiness.translationConfigured, isTrue);
      expect(snapshot.configReadiness.translationLabel, 'p2');
      expect(snapshot.configReadiness.asrConfigured, isTrue);
      expect(snapshot.configReadiness.asrLabel, '本机 Whisper');
    },
  );

  test('ServiceHealth ignores empty pump last_error', () {
    final health = ServiceHealth.fromJson({
      'service': 'transvortex.app_service',
      'status': 'healthy',
      'runtime': {},
      'pump': {'enabled': true, 'last_error': ''},
    });

    expect(health.degraded, isFalse);
    expect(health.pumpLabel, 'running');
  });

  test('AppServiceClient parses the installed Agent entry contract', () async {
    final client = AppServiceClient(
      FakeRpcTransport({
        'agent.entry.get': {
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
          'documents': {
            'usage': r'C:\Programs\TransVortex\App\agent\AGENT_USAGE.md',
            'asr_environment_setup':
                r'C:\Programs\TransVortex\App\agent\workflows\ASR_ENVIRONMENT_SETUP.md',
          },
          'cli_argv_prefix': [
            r'C:\Programs\TransVortex\App\runtime\python\python.exe',
            '-B',
            '-m',
            'transvortex.cli',
            '--root',
            r'C:\Users\tester\AppData\Local\TransVortex\Config',
          ],
          'capabilities_argv': ['python.exe', 'agent-info', '--json'],
          'handoff_text': 'general handoff',
          'asr_environment_handoff_text': 'asr handoff',
          'asr_environment_handoffs': {
            'inspect': 'inspect handoff',
            'prepare_model': 'model handoff',
            'prepare_accelerator': 'accelerator handoff',
            'register': 'register handoff',
            'full': 'full handoff',
          },
        },
      }),
    );

    final entry = await client.agentEntry();

    expect(entry.registered, isTrue);
    expect(entry.appVersion, '1.2.3');
    expect(entry.entryDocument, endsWith(r'Agent\README.md'));
    expect(entry.cliArgvPrefix[3], 'transvortex.cli');
    expect(entry.documentPath('usage'), endsWith('AGENT_USAGE.md'));
    expect(entry.asrEnvironmentHandoffText, 'asr handoff');
    expect(entry.asrEnvironmentHandoffs['prepare_model'], 'model handoff');
  });

  test(
    'AppServiceClient parses and launches the default Agent client',
    () async {
      final clientPayload = {
        'schema_version': 1,
        'id': 'codex_cli',
        'name': 'Codex CLI',
        'default': true,
        'detected': true,
        'ready': true,
        'launch_supported': true,
        'executable': r'C:\Users\tester\AppData\Roaming\npm\codex.cmd',
        'version': '0.144.6',
        'version_label': 'codex-cli 0.144.6',
        'status_code': 'ready',
        'message': 'Codex CLI is ready',
      };
      final transport = RecordingRpcTransport({
        'agent.client.get': clientPayload,
        'agent.client.open': {
          'launched': true,
          'pid': 100,
          'workspace': r'D:\TransVortex\Cache\AgentHandoffs\ClientOpen',
          'client': clientPayload,
        },
        'agent.handoff.launch': {
          'launched': true,
          'pid': 101,
          'workspace': r'D:\TransVortex\Cache\AgentHandoffs\handoff_1',
          'handoff_id': 'handoff_1',
          'handoff_document':
              r'D:\TransVortex\Cache\AgentHandoffs\handoff_1\handoff.md',
          'workflow': 'asr_environment',
          'scope': 'prepare_model',
          'client': clientPayload,
        },
      });
      final client = AppServiceClient(transport);

      final status = await client.agentClient();
      final opened = await client.openAgentClient();
      final handoff = await client.launchAsrAgentHandoff('prepare_model');

      expect(status.ready, isTrue);
      expect(status.version, '0.144.6');
      expect(status.executable, endsWith('codex.cmd'));
      expect(opened.launched, isTrue);
      expect(opened.pid, 100);
      expect(handoff.handoffId, 'handoff_1');
      expect(handoff.scope, 'prepare_model');
      expect(transport.calls.last.method, 'agent.handoff.launch');
      expect(transport.calls.last.params, {
        'workflow': 'asr_environment',
        'scope': 'prepare_model',
      });
    },
  );

  test('ServiceHealth active task label uses user facing text', () {
    final active = ServiceHealth.fromJson({
      'service': 'transvortex.app_service',
      'status': 'healthy',
      'runtime': {
        'active': {
          'task_id': 'tvx_20260704_long_identifier_abcdef',
          'status': 'TRANSLATE',
        },
      },
      'pump': {'enabled': true},
    });
    final idle = ServiceHealth.fromJson({
      'service': 'transvortex.app_service',
      'status': 'healthy',
      'runtime': {},
      'pump': {'enabled': true},
    });

    expect(active.activeTaskLabel, 'tvx_2026…abcdef · 翻译字幕');
    expect(active.activeTaskLabel, isNot(contains('TRANSLATE')));
    expect(idle.activeTaskLabel, '无活动任务');
    expect(idle.activeTaskLabel, isNot(contains('active task')));
  });

  test(
    'ConfigReadiness does not fall back to another translation provider',
    () {
      final snapshot = DesktopSnapshot.fromJson({
        'config': {
          'routing': {
            'primary': {'provider': 'p1', 'model': 'model-a'},
          },
          'pipeline': {'asr_provider': 'local'},
          'providers': [
            {'name': 'p1', 'has_key': false},
            {'name': 'p2', 'has_key': true},
          ],
          'asr_providers': {
            'local': {'name': 'Local ASR', 'has_key': true},
          },
        },
        'tasks': [],
        'runtime': {},
        'environment': {},
      });

      expect(snapshot.configReadiness.translationConfigured, isFalse);
      expect(snapshot.configReadiness.translationLabel, 'p1');
      expect(snapshot.configReadiness.asrConfigured, isTrue);
    },
  );

  test(
    'ConfigReadiness uses selected ASR provider and legacy routing shape',
    () {
      final snapshot = DesktopSnapshot.fromJson({
        'config': {
          'routing': {'primary': 'p1'},
          'pipeline': {'asr_provider': 'selected'},
          'providers': [
            {'name': 'p1', 'has_key': true},
          ],
          'asr_providers': {
            'other': {'name': 'Other ASR', 'has_key': true},
            'selected': {'name': 'Selected ASR', 'has_key': false},
          },
        },
        'tasks': [],
        'runtime': {},
        'environment': {},
      });

      expect(snapshot.configReadiness.translationConfigured, isTrue);
      expect(snapshot.configReadiness.translationLabel, 'p1');
      expect(snapshot.configReadiness.asrConfigured, isFalse);
      expect(snapshot.configReadiness.asrLabel, 'OpenAI Whisper');
    },
  );

  test('ConfigReadiness uses backend ASR readiness instead of auth shape', () {
    final snapshot = DesktopSnapshot.fromJson({
      'config': {
        'pipeline': {'asr_provider': 'local'},
        'asr_providers': {
          'local': {
            'name': 'Local ASR',
            'kind': 'local_worker',
            'has_key': true,
            'readiness': {
              'state': 'needs_action',
              'code': 'runtime_missing',
              'can_run': false,
              'primary_action': 'install_runtime',
            },
          },
        },
      },
      'tasks': [],
      'runtime': {},
      'environment': {},
    });

    expect(snapshot.configReadiness.asrConfigured, isFalse);
    expect(snapshot.configReadiness.asrState, 'needs_action');
    expect(snapshot.configReadiness.asrCode, 'runtime_missing');
    expect(snapshot.asrProviders.single.readiness.statusLabel, '组件未安装');
  });

  test('ASR operation parses progress and terminal state', () {
    final active = AsrOperationStatus.fromJson({
      'id': 'asr_1',
      'kind': 'setup',
      'item_id': 'large-v3',
      'state': 'running',
      'phase': 'model',
      'phase_index': 1,
      'phase_count': 3,
      'bytes_done': 25,
      'bytes_total': 100,
    });
    final failed = AsrOperationStatus.fromJson({
      'id': 'asr_2',
      'kind': 'runtime',
      'item_id': 'managed:faster-whisper',
      'state': 'failed',
      'error_code': 'checksum_mismatch',
    });

    expect(active.active, isTrue);
    expect(active.progress, 0.25);
    expect(active.phase, 'model');
    expect(active.phaseIndex, 1);
    expect(active.phaseCount, 3);
    expect(failed.active, isFalse);
    expect(failed.errorCode, 'checksum_mismatch');
  });

  test('DesktopSnapshot infers ASR engine labels from legacy provider ids', () {
    final snapshot = DesktopSnapshot.fromJson({
      'config': {
        'pipeline': {'asr_provider': 'funasr_sensevoice_local'},
        'asr_providers': {
          'local': {'name': 'Local ASR', 'has_key': true},
          'funasr_sensevoice_local': {
            'name': 'SenseVoice local service',
            'has_key': true,
          },
          'openai_whisper': {'name': 'Whisper', 'has_key': true},
          'openrouter_asr': {
            'name': 'openrouter_asr',
            'kind': 'remote',
            'protocol': 'openrouter_stt',
            'model': 'openai/whisper-large-v3',
            'has_key': true,
          },
        },
      },
      'tasks': [],
      'runtime': {},
      'environment': {},
    });

    final byName = {
      for (final option in snapshot.asrProviders) option.name: option,
    };
    expect(byName['local']?.displayLabel, '本机 Whisper');
    expect(byName['funasr_sensevoice_local']?.displayLabel, 'FunASR');
    expect(byName['openai_whisper']?.displayLabel, 'OpenAI Whisper');
    expect(
      byName['openrouter_asr']?.displayLabel,
      'OpenRouter · Whisper Large V3',
    );
    expect(snapshot.asrLabel, 'FunASR');
  });

  test('DesktopSnapshot reads local ASR model_size as selected model', () {
    final snapshot = DesktopSnapshot.fromJson({
      'config': {
        'routing': {
          'primary': {'provider': 'p1', 'model': 'model-a'},
        },
        'pipeline': {'asr_provider': 'local'},
        'providers': [
          {'name': 'p1', 'has_key': true},
        ],
        'asr_providers': {
          'local': {
            'name': 'local',
            'kind': 'local_inprocess',
            'protocol': 'faster_whisper',
            'local': {'model_size': 'large-v3', 'device': 'auto'},
            'has_key': true,
          },
        },
      },
      'tasks': [],
      'runtime': {},
      'environment': {},
    });

    expect(snapshot.asrModel, 'large-v3');
    expect(snapshot.asrProviders.single.name, 'local');
    expect(snapshot.asrProviders.single.displayName, 'local');
    expect(snapshot.asrProviders.single.model, 'large-v3');
    expect(snapshot.configReadiness.asrConfigured, isTrue);
    expect(snapshot.configReadiness.asrLabel, '本机 Whisper');
    expect(snapshot.asrLabel, '本机 Whisper');
  });

  test('TaskEventsPage parses cursor payload', () {
    final page = TaskEventsPage.fromJson({
      'task_id': 'tvx_1',
      'events': [
        {'type': 'started'},
      ],
      'cursor': 2,
      'next_cursor': 3,
      'has_more': true,
    });

    expect(page.taskId, 'tvx_1');
    expect(page.events, hasLength(1));
    expect(page.cursor, 2);
    expect(page.nextCursor, 3);
    expect(page.hasMore, isTrue);
  });

  test('TaskResultWorkspace parses result review payload', () {
    final workspace = TaskResultWorkspace.fromJson({
      'task': {
        'task_id': 'tvx_done',
        'status': 'DONE',
        'input_file': r'D:\movie.srt',
        'task_dir': r'D:\artifacts\tvx_done',
      },
      'segments': [
        {
          'id': 7,
          'start': 1.2,
          'end': 3.4,
          'text_src': 'Hello',
          'text_tgt': '你好',
          'provider': 'p1',
          'model': 'm1',
          'compat_mode': 'openai_chat',
          'chunk_id': 'chunk-1',
          'issues': ['译文为空'],
          'quality_issues': [
            {'code': 'empty_target', 'message': 'empty target'},
            {'code': 'cps_too_high', 'message': 'too fast'},
            {'code': 'line_too_long', 'message': 'long line'},
            {'code': 'line_too_wide', 'message': 'wide line'},
          ],
        },
      ],
      'quality': {'hard_issues': 1},
      'delivery': {
        'srt': {'lines': 1},
      },
      'reflow': {'enabled': true},
      'memory': {'entries': 2},
      'output_paths': {'srt': r'D:\movie.zh-CN.srt'},
    });

    expect(workspace.task.taskId, 'tvx_done');
    expect(workspace.task.taskDir, r'D:\artifacts\tvx_done');
    expect(workspace.hasSegments, isTrue);
    expect(workspace.segments.single.timeRangeLabel, '00:01.200 - 00:03.400');
    expect(workspace.segments.single.sourceText, 'Hello');
    expect(workspace.segments.single.targetText, '你好');
    expect(workspace.segments.single.provider, 'p1');
    expect(workspace.issueCount, 3);
    expect(workspace.outputPaths, {'srt': r'D:\movie.zh-CN.srt'});
  });

  test('DesktopSnapshot projects active external CUDA execution', () {
    final snapshot = DesktopSnapshot.fromJson({
      'config': {
        'asr_local': {
          'registered_models': [
            {
              'id': 'model-reg',
              'model_id': 'large-v3',
              'model_path': r'D:\Models\large-v3',
              'display_name': 'Whisper Large v3',
              'user_label': '日语访谈模型',
              'probe': {
                'ok': true,
                'model': {'device': 'cuda', 'compute_type': 'float16'},
              },
            },
          ],
          'registered_accelerators': [
            {
              'id': 'accelerator-reg',
              'accelerator_id': 'nvidia-cuda12',
              'root': r'D:\CUDA',
              'probe': {
                'ok': true,
                'cuda': {
                  'available': true,
                  'device_count': 1,
                  'compute_types': ['float16'],
                },
              },
            },
          ],
          'active_execution': {
            'provider': 'local',
            'kind': 'local_worker',
            'model': 'large-v3',
            'requested_device': 'cuda',
            'resolved_device': 'cuda',
            'compute_type': 'float16',
            'can_run': true,
            'model_resource': {
              'source': 'external',
              'registration_id': 'model-reg',
              'path': r'D:\Models\large-v3',
              'display_name': 'Whisper Large v3',
              'user_label': '日语访谈模型',
              'ready': true,
            },
            'accelerator': {
              'source': 'external',
              'id': 'accelerator-reg',
              'registration_id': 'accelerator-reg',
              'root': r'D:\CUDA',
              'state': 'ready',
              'ready': true,
              'cuda': {
                'available': true,
                'device_count': 1,
                'compute_types': ['float16'],
              },
            },
          },
        },
      },
    });

    expect(snapshot.asrRegisteredModels.single.id, 'model-reg');
    expect(snapshot.asrRegisteredModels.single.probeDevice, 'cuda');
    expect(snapshot.asrRegisteredModels.single.effectiveLabel, '日语访谈模型');
    expect(snapshot.asrRegisteredAccelerators.single.id, 'accelerator-reg');
    expect(snapshot.asrRegisteredAccelerators.single.cudaAvailable, isTrue);
    expect(snapshot.asrActiveExecution.resolvedDevice, 'cuda');
    expect(snapshot.asrActiveExecution.computeType, 'float16');
    expect(snapshot.asrActiveExecution.modelUserLabel, '日语访谈模型');
    expect(
      snapshot.asrActiveExecution.acceleratorRegistrationId,
      'accelerator-reg',
    );
    expect(snapshot.asrActiveExecution.acceleratorReady, isTrue);
  });

  test('TaskSummary parses status, runtime, progress, and errors', () {
    final task = TaskSummary.fromJson({
      'task_id': 'tvx_1',
      'status': 'FAILED',
      'input_file': r'D:\input.mp4',
      'source_lang': 'en',
      'target_lang': 'zh-CN',
      'bilingual': true,
      'created_at': '2026-07-01T00:00:00Z',
      'updated_at': '2026-07-01T00:01:00Z',
      'output_paths': {'srt': r'D:\out.srt'},
      'error_info': {'hint_zh': 'Provider 配置不可用。'},
      'runtime': {'can_resume': true, 'state': 'stale'},
      'input_type': 'video_asr_translate',
      'checkpoint_status': 'TRANSLATE',
      'progress_detail': {
        'translate_done_count': 2,
        'translate_total_chunks': 4,
        'model_request_count': 7,
        'model_request_counts': {
          'translate': 4,
          'memory_bootstrap_extract': 1,
          'memory_bootstrap_classify': 1,
          'batch_recovery': 1,
        },
        'asr_usage': {
          'provider': 'OpenRouter',
          'request_count': 2,
          'cost_usd': '0.000182',
          'audio_seconds': 6.9,
          'total_tokens': 81,
          'input_tokens': 64,
          'output_tokens': 17,
          'usage_complete': true,
          'cost_complete': true,
        },
      },
    });

    expect(task.taskId, 'tvx_1');
    expect(task.isFailed, isTrue);
    expect(task.inputType, 'video_asr_translate');
    expect(task.displayName, 'input.mp4');
    expect(task.canResume, isTrue);
    expect(task.runtimeState, 'stale');
    expect(task.isRuntimeActive, isFalse);
    expect(task.isRuntimeStale, isTrue);
    expect(task.latestProgress, 0.5);
    expect(task.displayStatus, 'TRANSLATE');
    expect(task.translationDoneCount, 2);
    expect(task.translationTotalChunks, 4);
    expect(task.modelRequestCount, 7);
    expect(task.modelRequestCounts['batch_recovery'], 1);
    expect(task.hasOpenRouterAsrUsage, isTrue);
    expect(task.asrUsageRequestCount, 2);
    expect(task.asrUsageCostUsd, 0.000182);
    expect(task.asrUsageAudioSeconds, 6.9);
    expect(task.asrUsageTotalTokens, 81);
    expect(task.asrUsageInputTokens, 64);
    expect(task.asrUsageOutputTokens, 17);
    expect(task.asrUsageComplete, isTrue);
    expect(task.asrUsageCostComplete, isTrue);
    expect(task.hasCompleteOpenRouterAsrUsage, isTrue);
    expect(task.outputPaths['srt'], r'D:\out.srt');
  });

  test('TaskSummary safely ignores invalid ASR usage values', () {
    final task = TaskSummary.fromJson({
      'task_id': 'tvx_invalid_usage',
      'status': 'DONE',
      'progress_detail': {
        'asr_usage': {
          'provider': 'openrouter',
          'request_count': -2,
          'cost_usd': 'NaN',
          'audio_seconds': -1,
          'total_tokens': -3,
          'usage_complete': true,
          'cost_complete': false,
        },
      },
    });

    expect(task.hasOpenRouterAsrUsage, isFalse);
    expect(task.asrUsageRequestCount, 0);
    expect(task.asrUsageCostUsd, isNull);
    expect(task.asrUsageAudioSeconds, isNull);
    expect(task.asrUsageTotalTokens, isNull);
    expect(task.asrUsageComplete, isTrue);
    expect(task.asrUsageCostComplete, isFalse);
    expect(task.hasCompleteOpenRouterAsrUsage, isFalse);
  });

  test('TaskSummary identifies completed work that still needs review', () {
    final review = TaskSummary.fromJson({
      'task_id': 'tvx_review',
      'status': 'DONE',
      'progress_detail': {
        'quality_status': 'WARN',
        'quality_issue_counts': {'repaired': 12},
        'quality_residual_counts': {'cps_too_high': 2},
        'delivery_status': 'FAIL',
        'delivery_issue_counts': {
          'srt': {'empty_target': 1},
          'ass': {'line_too_long': 2},
        },
      },
    });
    final clean = TaskSummary.fromJson({
      'task_id': 'tvx_clean',
      'status': 'DONE',
      'progress_detail': {
        'quality_status': 'PASS',
        'quality_issue_counts': {'repaired': 99},
        'quality_residual_counts': {'cps_too_high': 0},
        'delivery_status': 'PASS',
        'delivery_issue_counts': {
          'srt': {'empty_target': 0},
        },
      },
    });
    final failed = TaskSummary.fromJson({
      'task_id': 'tvx_failed',
      'status': 'FAILED',
      'progress_detail': {'quality_status': 'WARN'},
    });
    final pendingExport = TaskSummary.fromJson({
      'task_id': 'tvx_pending_export',
      'status': 'DONE',
      'settings': {'result_revision': 3, 'result_export_revision': 2},
      'progress_detail': {'quality_status': 'PASS', 'delivery_status': 'PASS'},
    });

    expect(review.qualityStatus, 'WARN');
    expect(review.deliveryStatus, 'FAIL');
    expect(review.qualityResidualIssueCount, 2);
    expect(review.deliveryIssueCount, 3);
    expect(review.reviewIssueCount, 5);
    expect(review.needsReview, isTrue);
    expect(clean.needsReview, isFalse);
    expect(failed.needsReview, isFalse);
    expect(pendingExport.hasSavedResultPendingExport, isTrue);
    expect(pendingExport.reviewIssueCount, 0);
    expect(pendingExport.needsReview, isTrue);
  });

  test('TaskSummary does not infer task type from legacy file extension', () {
    final task = TaskSummary.fromJson({
      'task_id': 'tvx_jsonl',
      'status': 'FAILED',
      'input_file': r'D:\artifacts\segments.jsonl',
      'runtime': {'can_resume': true},
    });

    expect(task.inputType, isEmpty);
    expect(task.displayName, 'segments.jsonl');
  });

  test('DesktopSnapshot restores only runtime-active or terminal tasks', () {
    final staleThenQueued = DesktopSnapshot.fromJson({
      'tasks': [
        {
          'task_id': 'tvx_stale',
          'status': 'TRANSLATE',
          'runtime': {'state': 'stale'},
        },
        {
          'task_id': 'tvx_queued',
          'status': 'QUEUED',
          'runtime': {'state': 'queued'},
        },
      ],
    });
    final runningThenDone = DesktopSnapshot.fromJson({
      'tasks': [
        {
          'task_id': 'tvx_running',
          'status': 'TRANSLATE',
          'runtime': {'state': 'running'},
        },
        {'task_id': 'tvx_done', 'status': 'DONE'},
      ],
    });
    final terminalOnly = DesktopSnapshot.fromJson({
      'tasks': [
        {
          'task_id': 'tvx_interrupted',
          'status': 'INTERRUPTED',
          'runtime': {'state': 'interrupted'},
        },
      ],
    });

    expect(staleThenQueued.latestActiveTask, isNull);
    expect(runningThenDone.latestActiveTask?.taskId, 'tvx_running');
    expect(terminalOnly.latestActiveTask?.taskId, 'tvx_interrupted');
  });

  test('task labels localize runtime lifecycle stages', () {
    expect(taskStatusLabel('INIT'), '等待中');
    expect(taskStatusLabel('PRECHECK'), '检查环境');
    expect(taskStatusLabel('ASR'), '识别语音');
    expect(taskStatusLabel('MEMORY'), '准备术语');
    expect(taskStatusLabel('TRANSLATE'), '翻译字幕');
    expect(taskStatusLabel('EXPORT'), '写出字幕');
    expect(taskStageLabel('checkpoint: translate'), '翻译字幕');
    expect(taskEventTypeLabel('provider_attempt'), '模型请求');
    expect(taskEventTypeLabel('provider_response'), '模型返回');
    expect(
      taskEventMessageLabel(
        type: 'provider_response',
        message: 'Provider response received',
      ),
      '模型返回已接收',
    );
    expect(languageLabel('en'), '英语');
    expect(languageLabel('zh-CN'), '简体中文');
    expect(languageLabel('zh_TW'), '繁体中文');

    final initTask = TaskSummary.fromJson({
      'task_id': 'tvx_init',
      'status': 'INIT',
    });
    final asrTask = TaskSummary.fromJson({
      'task_id': 'tvx_asr',
      'status': 'ASR',
    });
    final memoryTask = TaskSummary.fromJson({
      'task_id': 'tvx_memory',
      'status': 'MEMORY',
    });

    expect(initTask.isActive, isTrue);
    expect(asrTask.isActive, isTrue);
    expect(memoryTask.isActive, isTrue);
  });
}
