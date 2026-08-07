import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transvortex_desktop_flutter/main.dart';
import 'package:transvortex_desktop_flutter/model/window_state.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/directory_probe.dart';
import 'package:transvortex_desktop_flutter/services/window_state_bridge.dart';
import '../support/widget_test_support.dart';

void main() {
  testWidgets('diagnostics window reads doctor report through bridge', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final openedTools = <AppWindowType>[];
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          environment: doctorEnvironmentFixture(),
        ).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });
    bridge.attachToolWindowOpener((args) async {
      openedTools.add(args.type);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.diagnostics,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('诊断'), findsOneWidget);
    expect(find.text('检查项'), findsOneWidget);
    expect(find.textContaining('诊断：失败'), findsOneWidget);
    expect(find.text('翻译配置文件'), findsOneWidget);
    expect(find.text('产物目录'), findsOneWidget);
    expect(find.text('Provider 文件'), findsNothing);
    expect(find.text('Artifacts'), findsNothing);
    expect(find.textContaining('provider 协议'), findsNothing);
    expect(find.textContaining('provider 配置'), findsNothing);
    expect(find.textContaining('ASR provider'), findsNothing);
    expect(find.textContaining('本机识别依赖'), findsWidgets);
    expect(find.text('faster-whisper 缺失'), findsOneWidget);
    expect(find.text('faster_whisper_missing'), findsNothing);
    expect(find.textContaining('本机语音识别需要 faster-whisper'), findsWidgets);
    expect(find.textContaining('服务：本机语音识别'), findsOneWidget);
    expect(find.textContaining('类型：本机处理'), findsOneWidget);
    expect(find.textContaining('local_inprocess'), findsNothing);
    expect(find.text('去语音识别设置'), findsOneWidget);
    await tester.tap(find.text('去语音识别设置'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(openedTools, [AppWindowType.asrSettings]);
    expect(find.textContaining('已打开语音识别设置'), findsOneWidget);
    expect(find.text('python_found'), findsNothing);
    await tester.tap(find.text('Python · 通过'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Python 可用'), findsOneWidget);
    expect(find.text('python_found'), findsNothing);
    expect(find.text('去语音识别设置'), findsNothing);
    expect(find.text('刷新诊断'), findsOneWidget);
    expect(find.textContaining('method_not_found'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('diagnostics window opens artifact directory checks', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final pathOpener = RecordingPathOpener();
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          environment: {
            'status': 'FAIL',
            'root_dir': r'D:\thevox\TransVortex',
            'providers_file': r'D:\thevox\TransVortex\providers.yaml',
            'artifacts_dir': r'E:\blocked-artifacts',
            'checks': [
              {
                'name': 'python',
                'status': 'PASS',
                'code': 'python_found',
                'message': 'Python is available',
                'hint_zh': 'Python 已可用。',
              },
              {
                'name': 'artifacts',
                'status': 'FAIL',
                'code': 'artifacts_not_writable',
                'message': 'artifacts directory is not writable',
                'hint_zh': 'artifacts 目录不可写。请检查路径和权限。',
                'details': {'path': r'E:\blocked-artifacts'},
              },
            ],
          },
        ).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.diagnostics,
        store: store,
        bridge: bridge,
        pathOpener: pathOpener,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('产物目录 · 失败'), findsOneWidget);
    expect(find.text('产物目录不可用'), findsOneWidget);
    expect(find.text('打开产物目录'), findsOneWidget);

    await tester.tap(find.text('打开产物目录'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(pathOpener.openedDirectories, [r'E:\blocked-artifacts']);
    expect(find.text('已打开产物目录'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('diagnostics window shows task context from snapshot', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final openedTools = <AppWindowArgs>[];
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          environment: doctorEnvironmentFixture(
            status: 'PASS',
            extraChecks: [
              {
                'name': 'runtime_queue',
                'status': 'WARN',
                'code': 'runtime_interruptedtaskPayloads',
                'message': 'Interrupted tasks need user review.',
                'hint_zh': '有中断任务需要查看和处理。',
                'details': {'task_id': 'tvx_diag_context_active_123456'},
              },
            ],
          ),
          runtime: {
            'active': {'task_id': 'tvx_diag_context_active_123456'},
            'queued': ['tvx_waiting_1'],
            'interrupted': ['tvx_interrupted_1'],
          },
          tasks: [
            taskPayload(
              taskId: 'tvx_diag_context_active_123456',
              status: 'RUNNING',
              inputFile: r'D:\media\active.mp4',
              runtime: {'state': 'running'},
            ),
            taskPayload(
              taskId: 'tvx_diag_context_done_654321',
              status: 'DONE',
              inputFile: r'D:\media\done.mp4',
            ),
          ],
        ).raw;
      }
      throw RpcRemoteException('method_not_found', method);
    });
    bridge.attachToolWindowOpener((args) async {
      openedTools.add(args);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.diagnostics,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.drag(find.byType(Scrollable).last, const Offset(0, -520));
    await tester.pumpAndSettle();

    expect(find.text('任务上下文'), findsOneWidget);
    expect(find.text('当前任务'), findsOneWidget);
    expect(find.text('active.mp4 · 制作中'), findsWidgets);
    expect(find.text('任务数'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('队列'), findsOneWidget);
    expect(find.text('1 个等待'), findsOneWidget);
    expect(find.text('中断任务'), findsOneWidget);
    expect(find.text('1 个'), findsOneWidget);
    expect(find.text('等待任务'), findsOneWidget);
    expect(find.text('任务 tvx_waiting_1'), findsOneWidget);
    expect(find.text('中断线索'), findsOneWidget);
    expect(find.text('任务 tvx_inte…pted_1'), findsOneWidget);
    expect(find.text('最新任务'), findsOneWidget);
    expect(find.textContaining('tvx_diag_context_active_123456'), findsNothing);
    expect(find.textContaining('RUNNING'), findsNothing);

    await tester.tap(find.text('任务 tvx_waiting_1'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(openedTools.single.type, AppWindowType.taskProcessing);
    expect(openedTools.single.taskId, 'tvx_waiting_1');

    expect(find.text('查看任务处理'), findsOneWidget);
    await tester.tap(find.text('查看任务处理'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(openedTools.length, 2);
    expect(openedTools.last.type, AppWindowType.taskProcessing);
    expect(openedTools.last.taskId, 'tvx_diag_context_active_123456');
    expect(find.textContaining('已打开任务处理'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets('diagnostics window reads recent tasks and result summary', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(760, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final openedTools = <AppWindowArgs>[];
    final directoryProbe = RecordingDirectoryProbe(
      const DirectoryProbeResult(ok: false, message: '目录不可写：denied'),
    );
    bridge.attachServiceCaller((method, params) async {
      if (method == 'desktop.snapshot') {
        return desktopSnapshotFixture(
          environment: doctorEnvironmentFixture(status: 'PASS'),
          tasks: [
            taskPayload(
              taskId: 'tvx_snapshot_done_123456',
              status: 'DONE',
              inputFile: r'D:\media\snapshot.mp4',
            ),
          ],
        ).raw;
      }
      if (method == 'tasks.list') {
        return [
          taskPayload(
            taskId: 'tvx_recent_done_abcdef',
            status: 'DONE',
            inputFile: r'D:\media\recent.mp4',
            outputPaths: {'srt': r'D:\media\recent.zh-CN.srt'},
          ),
          taskPayload(
            taskId: 'tvx_recent_running_abcdef',
            status: 'RUNNING',
            inputFile: r'D:\media\running.mp4',
            runtime: {'state': 'running'},
          ),
        ];
      }
      if (method == 'result.open') {
        expect(params['task_id'], 'tvx_recent_done_abcdef');
        return {
          'task': taskPayload(
            taskId: 'tvx_recent_done_abcdef',
            status: 'DONE',
            inputFile: r'D:\media\recent.mp4',
          ),
          'segments': [
            {
              'id': 1,
              'start': 0,
              'end': 1,
              'text_src': 'Hello',
              'text_tgt': '你好',
              'issues': ['字幕阅读速度偏快'],
            },
            {
              'id': 2,
              'start': 1,
              'end': 2,
              'text_src': 'World',
              'text_tgt': '世界',
            },
          ],
          'output_paths': {'srt': r'D:\media\recent.zh-CN.srt'},
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });
    bridge.attachToolWindowOpener((args) async {
      openedTools.add(args);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.diagnostics,
        store: store,
        bridge: bridge,
        directoryProbe: directoryProbe,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.drag(find.byType(Scrollable).last, const Offset(0, -720));
    await tester.pumpAndSettle();

    expect(find.text('最近任务'), findsOneWidget);
    expect(find.text('snapshot.mp4'), findsOneWidget);
    await tester.tap(find.text('刷新'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.text('recent.mp4'), findsOneWidget);
    expect(find.text('running.mp4'), findsOneWidget);
    expect(find.text('状态：已完成'), findsOneWidget);
    expect(find.text('状态：制作中'), findsOneWidget);
    expect(find.text('未完成'), findsOneWidget);
    expect(find.textContaining('tvx_recent'), findsNothing);
    expect(find.textContaining('DONE'), findsNothing);
    await tester.tap(find.text('检查目录'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(directoryProbe.checkedPaths, [r'D:\media']);
    expect(find.text('结果目录：目录不可写：denied'), findsOneWidget);
    expect(find.textContaining('结果目录不可写'), findsOneWidget);
    await tester.tap(find.text('任务处理').first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(openedTools.single.type, AppWindowType.taskProcessing);
    expect(openedTools.single.taskId, 'tvx_recent_done_abcdef');
    expect(find.textContaining('已打开任务处理'), findsOneWidget);
    await tester.tap(find.text('结果摘要').first);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.text('结果摘要'), findsWidgets);
    expect(find.text('片段'), findsOneWidget);
    expect(find.text('2'), findsWidgets);
    expect(find.text('问题'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
    expect(find.text('srt'), findsOneWidget);
    expect(find.textContaining('已读取结果摘要'), findsOneWidget);
    expectNoFlutterException();
  });
}
