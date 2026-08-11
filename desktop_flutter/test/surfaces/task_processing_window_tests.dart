import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transvortex_desktop_flutter/main.dart';
import 'package:transvortex_desktop_flutter/model/window_state.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/current_window_controls.dart';
import 'package:transvortex_desktop_flutter/services/directory_probe.dart';
import 'package:transvortex_desktop_flutter/services/window_state_bridge.dart';
import '../support/widget_test_support.dart';

void main() {
  testWidgets('task processing window selects tasks and runs light actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1040, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final pathOpener = RecordingPathOpener();
    final directoryProbe = RecordingDirectoryProbe(
      const DirectoryProbeResult(ok: true, message: '目录可写'),
    );
    final calls = <String>[];
    final paramsByMethod = <String, Map<String, Object?>>{};
    final eventParams = <Map<String, Object?>>[];
    final opened = <AppWindowArgs>[];
    var targetText = '早上好。';
    var runningStatus = 'RUNNING';
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      paramsByMethod[method] = params;
      if (method == 'tasks.list') {
        return [
          taskPayload(
            taskId: 'tvx_processing_done_123456',
            status: 'DONE',
            inputFile: r'D:\media\processing-done.mp4',
            taskDir: r'D:\artifacts\tvx_processing_done_123456',
            outputPaths: {'srt': r'D:\media\processing-done.zh-CN.srt'},
            runtime: {'state': 'terminal'},
            createdAt: '2026-07-06T08:00:00',
            updatedAt: '2026-07-06T09:30:00',
            progressDetail: {
              'asr_usage': {
                'provider': 'openrouter',
                'request_count': 2,
                'cost_usd': 0.000182,
                'audio_seconds': 6.9,
                'usage_complete': true,
                'cost_complete': true,
              },
            },
          ),
          taskPayload(
            taskId: 'tvx_processing_failed_123456',
            status: 'FAILED',
            inputFile: r'D:\media\processing-failed.mp4',
            taskDir: r'D:\artifacts\tvx_processing_failed_123456',
            errorInfo: {
              'hint_zh': '缺少必要环境变量，请在 .env 或 env_key 中配置。',
              'code': 'missing_env',
              'stage': 'ASR',
              'retryable': false,
            },
            runtime: {'can_resume': true, 'state': 'stale'},
            createdAt: '2026-07-05T08:00:00',
            updatedAt: '2026-07-05T08:30:00',
            progressDetail: {
              'asr_usage': {
                'provider': 'openrouter',
                'request_count': 2,
                'cost_usd': 0.000091,
                'audio_seconds': 3.45,
                'usage_complete': true,
                'cost_complete': false,
              },
            },
          ),
          taskPayload(
            taskId: 'tvx_processing_running_123456',
            status: runningStatus,
            inputFile: r'D:\media\processing-running.mp4',
            taskDir: r'D:\artifacts\tvx_processing_running_123456',
            runtime: {'can_cancel': true, 'state': 'running'},
            createdAt: '2026-07-06T10:00:00',
            updatedAt: '2026-07-06T10:05:00',
          ),
        ];
      }
      if (method == 'tasks.events') {
        eventParams.add(Map<String, Object?>.from(params));
        final taskId = params['task_id'];
        final cursor = params['cursor'] as int? ?? 0;
        return {
          'task_id': taskId,
          'events': [
            {
              'type': 'stage',
              'stage': cursor == 0 ? 'EXPORT' : 'QUALITY',
              'message': cursor == 0
                  ? taskId == 'tvx_processing_done_123456'
                        ? 'done export'
                        : 'failed export'
                  : 'older event',
              'created_at': '2026-07-06T10:00:00Z',
            },
          ],
          'cursor': cursor,
          'next_cursor': cursor + 1,
          'has_more': taskId == 'tvx_processing_done_123456' && cursor == 0,
        };
      }
      if (method == 'runtime.submitResume') {
        return {
          'ok': true,
          'task_id': 'tvx_processing_failed_123456',
          'status': 'QUEUED',
          'message': '任务已重新排队。',
        };
      }
      if (method == 'runtime.retranslate') {
        return {
          'ok': true,
          'task_id': 'tvx_processing_derived_123456',
          'status': 'QUEUED',
          'message': '新的翻译任务已排队。',
        };
      }
      if (method == 'runtime.cancel') {
        runningStatus = 'CANCEL_REQUESTED';
        return taskPayload(
          taskId: 'tvx_processing_running_123456',
          status: runningStatus,
          inputFile: r'D:\media\processing-running.mp4',
          taskDir: r'D:\artifacts\tvx_processing_running_123456',
          runtime: {'can_cancel': true, 'state': 'running'},
        );
      }
      if (method == 'result.open') {
        return {
          'task': taskPayload(
            taskId: 'tvx_processing_done_123456',
            status: 'DONE',
            inputFile: r'D:\media\processing-done.mp4',
            outputPaths: {'srt': r'D:\media\processing-done.zh-CN.srt'},
          ),
          'segments': [
            {
              'id': 1,
              'start': 0.4,
              'end': 2.8,
              'text_src': 'Good morning.',
              'text_tgt': targetText,
              'provider': 'RealProvider',
              'model': 'real-model',
            },
          ],
          'output_paths': {'srt': r'D:\media\processing-done.zh-CN.srt'},
        };
      }
      if (method == 'result.segments.save') {
        final segments = params['segments'] as List<Object?>;
        final first = segments.first as Map<Object?, Object?>;
        targetText = '${first['text_tgt']}';
        return {
          'task': taskPayload(
            taskId: 'tvx_processing_done_123456',
            status: 'DONE',
            inputFile: r'D:\media\processing-done.mp4',
            outputPaths: {'srt': r'D:\media\processing-done.zh-CN.srt'},
          ),
          'segments': [
            {
              'id': 1,
              'start': 0.4,
              'end': 2.8,
              'text_src': 'Good morning.',
              'text_tgt': targetText,
            },
          ],
          'output_paths': {'srt': r'D:\media\processing-done.zh-CN.srt'},
        };
      }
      if (method == 'memory.collections.list') {
        return {
          'collections': [
            {'id': 'characters', 'name': '人物名', 'revision': 2, 'entries': 1},
          ],
        };
      }
      if (method == 'memory.collection.get') {
        return {
          'collection': {
            'id': 'characters',
            'name': '人物名',
            'revision': 2,
            'entries': [
              {
                'id': 'subaru',
                'source': 'スバル',
                'target': '昴',
                'status': 'locked',
              },
            ],
          },
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });
    bridge.attachToolWindowOpener((args) async {
      opened.add(args);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.taskProcessing,
        taskId: 'tvx_processing_done_123456',
        store: store,
        bridge: bridge,
        pathOpener: pathOpener,
        directoryProbe: directoryProbe,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('tasks.list'));
    expect(calls, contains('tasks.events'));
    expect(find.text('工作台'), findsOneWidget);
    expect(find.text('任务与字幕'), findsOneWidget);
    expect(find.text('术语库'), findsOneWidget);
    expect(find.text('任务片列'), findsOneWidget);
    expect(find.text('processing-done.mp4'), findsWidgets);
    expect(find.text('processing-failed.mp4'), findsOneWidget);
    expect(find.text('processing-running.mp4'), findsOneWidget);
    expect(find.text('全部 3'), findsOneWidget);
    expect(find.text('字幕编辑'), findsOneWidget);
    expect(find.text('导出格式'), findsOneWidget);
    expect(calls, contains('result.open'));
    expect(opened, isEmpty);

    await tester.enterText(
      find.widgetWithText(TextField, '输入译文').first,
      '这是未保存修改。',
    );
    await tester.pump(const Duration(milliseconds: 100));
    final lockedTaskSearch = find.widgetWithText(TextField, '搜索任务');
    expect(tester.widget<TextField>(lockedTaskSearch).enabled, isFalse);

    await tester.tap(find.text('术语库'));
    await tester.pumpAndSettle();
    expect(find.text('集中维护跨任务复用的术语资产；任务使用的是开始制作时冻结的版本快照。'), findsOneWidget);
    expect(find.text('スバル  →  昴'), findsOneWidget);
    await tester.tap(find.text('任务与字幕'));
    await tester.pump();
    expect(find.text('这是未保存修改。'), findsOneWidget);

    final closeRequest = requestCurrentWindowCloseForTesting();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('放弃未保存修改？'), findsOneWidget);
    expect(find.textContaining('关闭工作台后'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byIcon(Icons.edit_note_rounded),
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, '继续校对'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(await closeRequest, isFalse);
    expect(find.text('这是未保存修改。'), findsOneWidget);

    await tester.tap(find.text('返回概览'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('放弃未保存修改？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '继续编辑'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('字幕编辑'), findsOneWidget);
    expect(find.text('这是未保存修改。'), findsOneWidget);

    await tester.tap(find.text('返回概览'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(FilledButton, '放弃修改'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('字幕编辑'), findsNothing);

    expect(find.text('创建 2026-07-06 08:00:00'), findsOneWidget);
    expect(find.text('更新 2026-07-06 09:30:00'), findsOneWidget);
    expect(find.text('运行记录 已结束'), findsOneWidget);
    expect(find.text('OpenRouter 用量 \$0.000182 · 6.90 秒'), findsOneWidget);
    expect(find.text('重新翻译'), findsOneWidget);
    await tester.tap(find.text('重新翻译'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('重新翻译当前识别稿'), findsOneWidget);
    expect(find.textContaining('不会重新运行语音识别'), findsOneWidget);
    await tester.tap(find.text('创建翻译任务'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(paramsByMethod['runtime.retranslate'], {
      'task_id': 'tvx_processing_done_123456',
    });
    expect(find.text('阶段'), findsOneWidget);
    expect(find.text('加载更多事件'), findsOneWidget);
    await tester.tap(find.text('加载更多事件'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('阶段'), findsNWidgets(2));
    expect(find.text('older event'), findsOneWidget);
    expect(find.text('加载更多事件'), findsNothing);
    expect(eventParams, contains(containsPair('cursor', 1)));

    final eventSearch = find.widgetWithText(TextField, '搜索事件');
    expect(eventSearch, findsOneWidget);
    await tester.enterText(eventSearch, 'older');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('older event'), findsOneWidget);
    expect(find.text('正在写出字幕文件'), findsNothing);
    expect(find.text('阶段'), findsOneWidget);

    await tester.tap(find.byTooltip('清除事件搜索'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('older event'), findsOneWidget);
    expect(find.text('正在写出字幕文件'), findsOneWidget);
    expect(find.text('阶段'), findsNWidgets(2));

    await tester.tap(find.text('结果目录'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(pathOpener.openedDirectories, [r'D:\media']);
    expect(find.text('已打开结果目录'), findsOneWidget);
    expect(find.text('检查结果目录'), findsNothing);
    expect(directoryProbe.checkedPaths, isEmpty);

    expect(find.text('全部 3'), findsOneWidget);
    expect(find.text('制作中 1'), findsOneWidget);
    expect(find.text('待处理 1'), findsOneWidget);
    expect(find.text('已完成 1'), findsOneWidget);

    final taskSearch = find.widgetWithText(TextField, '搜索任务');
    expect(taskSearch, findsOneWidget);
    await tester.enterText(taskSearch, 'failed');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('显示 1 / 3 个任务'), findsOneWidget);
    expect(find.text('全部 1'), findsOneWidget);
    expect(find.text('待处理 1'), findsOneWidget);
    expect(find.text('processing-failed.mp4'), findsWidgets);
    expect(find.text('processing-done.mp4'), findsNothing);
    expect(find.text('processing-running.mp4'), findsNothing);

    await tester.tap(find.byTooltip('清除任务搜索'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('最近 3 个任务'), findsOneWidget);
    expect(find.text('全部 3'), findsOneWidget);
    expect(find.text('processing-done.mp4'), findsOneWidget);
    expect(find.text('processing-failed.mp4'), findsWidgets);
    expect(find.text('processing-running.mp4'), findsOneWidget);

    await tester.tap(find.text('制作中 1'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('显示 1 / 3 个任务'), findsOneWidget);
    expect(find.text('processing-running.mp4'), findsWidgets);
    expect(find.text('processing-done.mp4'), findsNothing);
    expect(find.text('processing-failed.mp4'), findsNothing);

    await tester.tap(find.text('待处理 1'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('processing-failed.mp4'), findsWidgets);
    expect(find.text('processing-running.mp4'), findsNothing);
    expect(find.text('编辑字幕'), findsNothing);
    expect(find.text('取消任务'), findsNothing);
    expect(find.text('结果目录'), findsNothing);
    expect(find.text('失败线索'), findsOneWidget);
    expect(find.textContaining('语音识别凭据还没有配置'), findsOneWidget);
    expect(find.text('阶段 识别语音'), findsOneWidget);
    expect(find.textContaining('.env'), findsNothing);
    expect(find.textContaining('env_key'), findsNothing);
    expect(find.text('重试性 可重试'), findsNothing);
    expect(find.text('运行状态 记录过期'), findsNothing);
    expect(find.text('OpenRouter 已报告用量 \$0.000091 · 3.45 秒'), findsOneWidget);

    await tester.tap(find.text('检查识别设置'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(opened, hasLength(1));
    expect(opened.single.type, AppWindowType.asrSettings);
    expect(find.textContaining('修好后可以回来继续任务'), findsOneWidget);

    await tester.tap(find.text('继续任务'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(paramsByMethod['runtime.submitResume'], {
      'request': {
        'request_version': 1,
        'task_id': 'tvx_processing_failed_123456',
      },
    });
    await tester.tap(find.text('制作中 1'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('运行记录 运行中'), findsOneWidget);
    expect(find.text('编辑字幕'), findsNothing);
    expect(find.text('继续任务'), findsNothing);
    expect(find.text('结果目录'), findsNothing);
    await tester.tap(find.text('取消任务'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(paramsByMethod['runtime.cancel'], {
      'task_id': 'tvx_processing_running_123456',
      'force': false,
    });
    expect(find.text('已请求取消任务。'), findsOneWidget);

    await tester.tap(find.text('待处理 1'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('任务目录'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(pathOpener.openedDirectories, [
      r'D:\media',
      r'D:\artifacts\tvx_processing_failed_123456',
    ]);
    expectNoFlutterException();
  });

  testWidgets('task processing screens review and cancelled tasks', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1040, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    bridge.attachServiceCaller((method, params) async {
      if (method == 'tasks.list') {
        return [
          taskPayload(
            taskId: 'tvx_review_needed_123456',
            status: 'DONE',
            inputFile: r'D:\media\review-me.mp4',
            taskDir: r'D:\artifacts\tvx_review_needed_123456',
            outputPaths: {'srt': r'D:\media\review-me.zh-CN.srt'},
            runtime: {'state': 'terminal'},
            progressDetail: {
              'quality_status': 'WARN',
              'quality_residual_counts': {'cps_too_high': 2},
              'delivery_status': 'WARN',
              'delivery_issue_counts': {
                'srt': {'line_too_long': 1},
              },
            },
          ),
          taskPayload(
            taskId: 'tvx_review_clean_123456',
            status: 'DONE',
            inputFile: r'D:\media\clean.mp4',
            taskDir: r'D:\artifacts\tvx_review_clean_123456',
            outputPaths: {'srt': r'D:\media\clean.zh-CN.srt'},
            runtime: {'state': 'terminal'},
            progressDetail: {
              'quality_status': 'PASS',
              'quality_issue_counts': {'repaired': 12},
              'quality_residual_counts': {'cps_too_high': 0},
              'delivery_status': 'PASS',
            },
          ),
          taskPayload(
            taskId: 'tvx_review_pending_export_123456',
            status: 'DONE',
            inputFile: r'D:\media\pending-export.mp4',
            taskDir: r'D:\artifacts\tvx_review_pending_export_123456',
            outputPaths: {'srt': r'D:\media\pending-export.zh-CN.srt'},
            runtime: {'state': 'terminal'},
            settings: {'result_revision': 2, 'result_export_revision': 1},
            progressDetail: {
              'quality_status': 'PASS',
              'delivery_status': 'PASS',
            },
          ),
          taskPayload(
            taskId: 'tvx_review_cancelled_123456',
            status: 'CANCELLED',
            inputFile: r'D:\media\cancelled.mp4',
            taskDir: r'D:\artifacts\tvx_review_cancelled_123456',
            runtime: {'state': 'terminal', 'can_resume': false},
          ),
        ];
      }
      if (method == 'tasks.events') {
        return {
          'task_id': params['task_id'],
          'events': const [],
          'cursor': 0,
          'next_cursor': 0,
          'has_more': false,
        };
      }
      if (method == 'result.open') {
        expect(params['task_id'], 'tvx_review_needed_123456');
        return {
          'task': taskPayload(
            taskId: 'tvx_review_needed_123456',
            status: 'DONE',
            inputFile: r'D:\media\review-me.mp4',
            outputPaths: {'srt': r'D:\media\review-me.zh-CN.srt'},
          ),
          'segments': [
            {
              'id': 1,
              'start': 0.0,
              'end': 0.8,
              'text_src': 'Needs review.',
              'text_tgt': '需要校对。',
              'issues': ['字幕阅读速度偏快'],
            },
            {
              'id': 2,
              'start': 1.0,
              'end': 2.0,
              'text_src': 'Already clean.',
              'text_tgt': '已经通过。',
            },
          ],
          'output_paths': {'srt': r'D:\media\review-me.zh-CN.srt'},
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.taskProcessing,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('全部 4'), findsOneWidget);
    expect(find.text('制作中 0'), findsOneWidget);
    expect(find.text('待处理 0'), findsOneWidget);
    expect(find.text('待校对 2'), findsOneWidget);
    expect(find.text('已完成 3'), findsOneWidget);
    expect(find.text('已取消 1'), findsOneWidget);
    expect(find.text('还有字幕值得再看一眼'), findsOneWidget);
    expect(find.textContaining('3 条质量或交付提示'), findsOneWidget);
    expect(find.text('质量检查 有提醒'), findsOneWidget);
    expect(find.text('交付检查 有提醒'), findsOneWidget);

    await tester.tap(find.text('待校对 2'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('review-me.mp4'), findsWidgets);
    expect(find.text('pending-export.mp4'), findsOneWidget);
    expect(find.text('clean.mp4'), findsNothing);
    expect(find.text('cancelled.mp4'), findsNothing);

    await tester.tap(find.text('编辑字幕'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Needs review.'), findsOneWidget);
    expect(find.text('Already clean.'), findsNothing);
    expect(find.text('字幕阅读速度偏快'), findsOneWidget);

    await tester.tap(find.text('返回概览'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('pending-export.mp4'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('待导出 · 修改已保存'), findsOneWidget);
    expect(find.textContaining('成品文件仍是旧版本'), findsOneWidget);

    await tester.tap(find.text('已取消 1'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('cancelled.mp4'), findsWidgets);
    expect(find.text('review-me.mp4'), findsNothing);
    expect(find.text('继续任务'), findsNothing);

    await tester.tap(find.text('已完成 3'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('review-me.mp4'), findsWidgets);
    expect(find.text('clean.mp4'), findsOneWidget);
    expect(find.text('pending-export.mp4'), findsOneWidget);
    expect(find.text('cancelled.mp4'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('task processing repairs an output failure in a new directory', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1040, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    FilePickerIO.registerWith();
    const pickerChannel = MethodChannel(
      'miguelruivo.flutter.plugins.filepicker',
      JSONMethodCodec(),
    );
    var pickerCalls = 0;
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pickerChannel,
        null,
      );
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pickerChannel,
      (call) async {
        expect(call.method, 'dir');
        pickerCalls += 1;
        return r'E:\fixed-output';
      },
    );

    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final reexportParams = <Map<String, Object?>>[];
    var taskStatus = 'FAILED';
    var outputPaths = <String, String>{};
    bridge.attachServiceCaller((method, params) async {
      if (method == 'tasks.list') {
        return [
          taskPayload(
            taskId: 'tvx_output_recovery_123456',
            status: taskStatus,
            inputFile: r'D:\media\output-failed.mp4',
            taskDir: r'D:\artifacts\tvx_output_recovery_123456',
            outputPaths: outputPaths,
            errorInfo: taskStatus == 'FAILED'
                ? {
                    'code': 'output_not_writable',
                    'stage': 'EXPORT',
                    'hint_zh': '输出目录不可写。',
                    'retryable': false,
                  }
                : const {},
            runtime: {'state': 'terminal'},
            settings: {
              'output_format': 'ass',
              'subtitle_ass_style': {
                'bilingual_order': 'target_source',
                'prefer_single_line': true,
              },
              'reexport_bilingual': false,
              'reexport_subtitle_ass_style': {
                'bilingual_order': 'source_target',
                'prefer_single_line': false,
              },
            },
          ),
        ];
      }
      if (method == 'tasks.events') {
        return {
          'task_id': 'tvx_output_recovery_123456',
          'events': const [],
          'cursor': 0,
          'next_cursor': 0,
          'has_more': false,
        };
      }
      if (method == 'result.reexport') {
        reexportParams.add(Map<String, Object?>.from(params));
        if (reexportParams.length == 1) {
          throw RpcRemoteException(
            'runtime_error',
            'read events.json for task_id=tvx_output_recovery_123456',
            details: const {
              'error_info': {
                'code': 'runtime_error',
                'hint_zh': '请查看 events.json 和 task_id 后重试。',
              },
            },
          );
        }
        taskStatus = 'DONE';
        outputPaths = {'ass': r'E:\fixed-output\output-failed.zh-CN.ass'};
        return {
          'task_id': 'tvx_output_recovery_123456',
          'output_paths': outputPaths,
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.taskProcessing,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('选择输出目录'), findsOneWidget);
    expect(find.text('检查结果目录'), findsNothing);
    expect(find.text('继续任务'), findsNothing);

    await tester.tap(find.text('选择输出目录'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(pickerCalls, 1);
    expect(reexportParams.single, {
      'task_id': 'tvx_output_recovery_123456',
      'output_format': 'ass',
      'output_dir': r'E:\fixed-output',
      'bilingual': false,
      'subtitle_bilingual_order': 'source_target',
      'subtitle_prefer_single_line': false,
    });
    expect(find.textContaining('任务运行失败，可以先重试'), findsOneWidget);
    expect(find.textContaining('events.json'), findsNothing);
    expect(find.textContaining('task_id'), findsNothing);
    expect(find.text('选择输出目录'), findsOneWidget);

    await tester.tap(find.text('选择输出目录'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(pickerCalls, 2);
    expect(reexportParams, hasLength(2));
    expect(find.text('字幕已重新导出到新目录。'), findsOneWidget);
    expect(find.text('编辑字幕'), findsOneWidget);
    expect(find.text('选择输出目录'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('task processing re-exports a missing result in place', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1040, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    Map<String, Object?>? reexportParams;
    var taskStatus = 'FAILED';
    bridge.attachServiceCaller((method, params) async {
      if (method == 'tasks.list') {
        return [
          taskPayload(
            taskId: 'tvx_result_recovery_123456',
            status: taskStatus,
            inputFile: r'D:\media\result-missing.mp4',
            taskDir: r'D:\artifacts\tvx_result_recovery_123456',
            outputPaths: taskStatus == 'DONE'
                ? {'srt': r'D:\media\result-missing.zh-CN.srt'}
                : const {},
            errorInfo: taskStatus == 'FAILED'
                ? {
                    'code': 'result_missing',
                    'stage': 'EXPORT',
                    'hint_zh': '字幕输出文件已被移动。',
                  }
                : const {},
            runtime: {'state': 'terminal'},
            settings: {'output_format': 'srt'},
          ),
        ];
      }
      if (method == 'tasks.events') {
        return {
          'task_id': 'tvx_result_recovery_123456',
          'events': const [],
          'cursor': 0,
          'next_cursor': 0,
          'has_more': false,
        };
      }
      if (method == 'result.reexport') {
        reexportParams = Map<String, Object?>.from(params);
        taskStatus = 'DONE';
        return {
          'task_id': 'tvx_result_recovery_123456',
          'output_paths': {'srt': r'D:\media\result-missing.zh-CN.srt'},
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      TransVortexApp(
        windowType: AppWindowType.taskProcessing,
        store: store,
        bridge: bridge,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('重新导出'), findsOneWidget);
    expect(find.text('选择输出目录'), findsNothing);

    await tester.tap(find.text('重新导出'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(reexportParams, {
      'task_id': 'tvx_result_recovery_123456',
      'output_format': 'srt',
      'bilingual': true,
    });
    expect(find.text('字幕已重新导出。'), findsOneWidget);
    expect(find.text('编辑字幕'), findsOneWidget);
    expectNoFlutterException();
  });
}
