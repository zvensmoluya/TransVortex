import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:transvortex_desktop_flutter/model/window_state.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/services/window_state_bridge.dart';
import 'package:transvortex_desktop_flutter/widgets/result_review_workspace.dart';
import '../support/widget_test_support.dart';

void main() {
  testWidgets('result review workspace renders real result workspace', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      if (method == 'result.open') {
        expect(params['task_id'], 'tvx_review_done_123456');
        return {
          'task': taskPayload(
            taskId: 'tvx_review_done_123456',
            status: 'DONE',
            inputFile: r'D:\media\review-source.mp4',
            outputPaths: {'srt': r'D:\media\review-source.zh-CN.srt'},
          ),
          'segments': [
            {
              'id': 1,
              'start': 0.4,
              'end': 2.8,
              'text_src': 'Good morning.',
              'text_tgt': '早上好。',
              'provider': 'RealProvider',
              'model': 'real-model',
              'issues': ['字幕阅读速度偏快'],
            },
            {
              'id': 2,
              'start': 3.0,
              'end': 5.2,
              'text_src': 'Welcome back.',
              'text_tgt': '',
            },
          ],
          'output_paths': {'srt': r'D:\media\review-source.zh-CN.srt'},
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResultReviewWorkspace(
            taskId: 'tvx_review_done_123456',
            bridge: bridge,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, contains('result.open'));
    expect(find.text('结果审看'), findsNothing);
    expect(find.text('review-source.mp4'), findsOneWidget);
    expect(find.text('源语 英语 · 目标 简体中文'), findsOneWidget);
    expect(find.text('源语 en · 目标 zh-CN'), findsNothing);
    expect(find.text('2 个片段'), findsOneWidget);
    expect(find.text('1 条提示'), findsOneWidget);
    expect(find.text('已有 SRT'), findsOneWidget);
    expect(find.text('导出复核'), findsOneWidget);
    expect(find.text('将导出 SRT · 双语字幕 · 译文在前 · 尽量单行'), findsOneWidget);
    expect(find.text('已有输出 SRT review-source.zh-CN.srt'), findsOneWidget);
    expect(find.text('LRC'), findsOneWidget);
    expect(find.text('问题 1 条'), findsOneWidget);
    expect(find.text('Good morning.'), findsOneWidget);
    expect(find.text('早上好。'), findsOneWidget);
    expect(find.text('Welcome back.'), findsOneWidget);
    expect(find.text('字幕阅读速度偏快'), findsOneWidget);

    await tester.tap(find.byTooltip('下一条问题'));
    await tester.pumpAndSettle();
    expect(find.text('问题 1 / 1'), findsOneWidget);
    expect(find.byIcon(Icons.bookmark_rounded), findsOneWidget);
    expect(find.text('Good morning.'), findsOneWidget);
    expect(find.text('Welcome back.'), findsNothing);
    await tester.tap(find.text('全部'));
    await tester.pump(const Duration(milliseconds: 100));

    final segmentSearch = find.widgetWithText(TextField, '搜索源文或译文');
    expect(segmentSearch, findsOneWidget);
    await tester.enterText(segmentSearch, 'welcome');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Good morning.'), findsNothing);
    expect(find.text('Welcome back.'), findsOneWidget);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Good morning.'), findsOneWidget);
    expect(find.text('Welcome back.'), findsOneWidget);

    await tester.tap(find.text('有问题'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Good morning.'), findsOneWidget);
    expect(find.text('Welcome back.'), findsNothing);

    await tester.tap(find.text('空译文'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Good morning.'), findsNothing);
    expect(find.text('Welcome back.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '输入译文'), '欢迎回来。');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Welcome back.'), findsOneWidget);
    expect(find.text('欢迎回来。'), findsOneWidget);

    await tester.tap(find.text('全部'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Good morning.'), findsOneWidget);
    expect(find.text('Welcome back.'), findsOneWidget);
    await tester.tap(find.text('还原片段'));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('已修改'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('没有已修改片段。'), findsOneWidget);

    await tester.tap(find.text('全部'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(
      find.widgetWithText(TextField, '输入译文').last,
      '欢迎回来。',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('已修改'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Good morning.'), findsNothing);
    expect(find.text('Welcome back.'), findsOneWidget);
    expect(find.text('欢迎回来。'), findsOneWidget);
    expect(find.text('还原片段'), findsOneWidget);

    await tester.tap(find.text('还原片段'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('没有已修改片段。'), findsOneWidget);
    expect(find.text('已还原片段修改'), findsOneWidget);
    expect(find.text('欢迎回来。'), findsNothing);
    expect(find.textContaining('method_not_found'), findsNothing);
    expectNoFlutterException();
  });

  testWidgets('result review workspace saves edits and reexports subtitles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final calls = <String>[];
    final paramsByMethod = <String, Map<String, Object?>>{};
    final dirtyStates = <bool>[];
    var resultChanges = 0;
    var targetText = '早上好。';
    var resultRevision = 0;
    var resultExportRevision = 0;
    var outputFormat = 'srt';
    var exportBilingual = true;
    var bilingualOrder = 'target_source';
    var preferSingleLine = true;

    Map<String, Object?> resultPayload() => {
      'task': taskPayload(
        taskId: 'tvx_review_edit_123456',
        status: 'DONE',
        inputFile: r'D:\media\review-source.mp4',
        outputPaths: {
          outputFormat: 'D:\\media\\review-source.zh-CN.$outputFormat',
        },
        settings: {
          'result_revision': resultRevision,
          'result_export_revision': resultExportRevision,
          'reexport_bilingual': exportBilingual,
          'reexport_subtitle_ass_style': {
            'bilingual_order': bilingualOrder,
            'prefer_single_line': preferSingleLine,
          },
        },
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
      'output_paths': {
        outputFormat: 'D:\\media\\review-source.zh-CN.$outputFormat',
      },
    };

    bridge.attachServiceCaller((method, params) async {
      calls.add(method);
      paramsByMethod[method] = params;
      if (method == 'result.open') return resultPayload();
      if (method == 'result.segments.save') {
        final segments = params['segments'] as List<Object?>;
        final first = segments.first as Map<Object?, Object?>;
        targetText = '${first['text_tgt']}';
        resultRevision += 1;
        return resultPayload();
      }
      if (method == 'result.reexport') {
        outputFormat = '${params['output_format']}';
        exportBilingual = params['bilingual'] == true;
        bilingualOrder = '${params['subtitle_bilingual_order']}';
        preferSingleLine = params['subtitle_prefer_single_line'] == true;
        resultExportRevision = resultRevision;
        return {
          'task_id': 'tvx_review_edit_123456',
          'output_paths': {'ass': r'D:\media\review-source.zh-CN.ass'},
        };
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResultReviewWorkspace(
            taskId: 'tvx_review_edit_123456',
            bridge: bridge,
            onDirtyChanged: dirtyStates.add,
            onResultChanged: () => resultChanges += 1,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(
      find.widgetWithText(TextField, '输入译文').first,
      '早上好，欢迎回来。',
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('有未保存修改'), findsOneWidget);
    expect(dirtyStates.last, isTrue);

    final openCallsBeforeRefresh = calls
        .where((method) => method == 'result.open')
        .length;
    await tester.tap(find.text('刷新'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      calls.where((method) => method == 'result.open').length,
      openCallsBeforeRefresh,
    );

    await tester.tap(find.text('放弃修改'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已放弃未保存修改'), findsOneWidget);
    expect(find.text('早上好。'), findsOneWidget);
    expect(paramsByMethod.containsKey('result.segments.save'), isFalse);

    await tester.enterText(
      find.widgetWithText(TextField, '输入译文').first,
      '早上好，欢迎回来。',
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('有未保存修改'), findsOneWidget);

    await tester.tap(find.text('保存修改'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final savedSegments =
        paramsByMethod['result.segments.save']?['segments'] as List<Object?>;
    final savedFirst = savedSegments.first as Map<Object?, Object?>;
    expect(savedFirst['text_tgt'], '早上好，欢迎回来。');
    expect(find.text('修改已保存，字幕文件尚未更新'), findsOneWidget);
    expect(dirtyStates.last, isFalse);
    expect(resultChanges, 1);

    expect(find.text('导出格式'), findsOneWidget);
    await tester.tap(find.text('ASS'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('源文在前'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(Switch).last);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('将导出 ASS · 双语字幕 · 源文在前 · 自然换行'), findsOneWidget);

    await tester.tap(find.text('重新导出'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(paramsByMethod['result.reexport'], {
      'task_id': 'tvx_review_edit_123456',
      'output_format': 'ass',
      'bilingual': true,
      'subtitle_bilingual_order': 'source_target',
      'subtitle_prefer_single_line': false,
    });
    expect(calls.where((method) => method == 'result.open').length, 2);
    expect(find.text('字幕文件已更新'), findsOneWidget);
    expect(resultChanges, 2);
    expectNoFlutterException();
  });

  testWidgets('result review edits and validates subtitle timing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = WindowStateStore();
    final bridge = WindowStateBridge.main(store);
    final paramsByMethod = <String, Map<String, Object?>>{};
    var start = 1.5;
    var end = 3.0;
    var hasTimingIssue = true;
    var resultRevision = 0;

    Map<String, Object?> resultPayload() => {
      'task': taskPayload(
        taskId: 'tvx_review_timing_123456',
        status: 'DONE',
        inputFile: r'D:\media\review-timing.mp4',
        outputPaths: {'srt': r'D:\media\review-timing.zh-CN.srt'},
        settings: {
          'result_revision': resultRevision,
          'result_export_revision': 0,
        },
      ),
      'segments': [
        {
          'id': 2,
          'start': start,
          'end': end,
          'text_src': 'Check the timing.',
          'text_tgt': '检查时间码。',
          'issues': hasTimingIssue ? ['时间轴与上一条重叠'] : <String>[],
          'quality_issues': hasTimingIssue
              ? [
                  {
                    'code': 'timeline_overlap',
                    'message': 'overlap with previous cue',
                  },
                ]
              : <Map<String, Object?>>[],
        },
      ],
      'output_paths': {'srt': r'D:\media\review-timing.zh-CN.srt'},
    };

    bridge.attachServiceCaller((method, params) async {
      paramsByMethod[method] = params;
      if (method == 'result.open') return resultPayload();
      if (method == 'result.segments.save') {
        final segments = params['segments'] as List<Object?>;
        final segment = segments.single as Map<Object?, Object?>;
        start = (segment['start'] as num).toDouble();
        end = (segment['end'] as num).toDouble();
        hasTimingIssue = false;
        resultRevision += 1;
        return resultPayload();
      }
      throw RpcRemoteException('method_not_found', method);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 560,
              height: 640,
              child: ResultReviewWorkspace(
                taskId: 'tvx_review_timing_123456',
                bridge: bridge,
                focusIssuesInitially: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final startField = find.byKey(const ValueKey('result-time-start-2'));
    final endField = find.byKey(const ValueKey('result-time-end-2'));
    expect(startField, findsOneWidget);
    expect(endField, findsOneWidget);
    expect(find.byTooltip('收起时间码'), findsOneWidget);
    expect(find.text('问题 1 / 1'), findsOneWidget);

    await tester.tap(find.byTooltip('开始延后 0.1 秒'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<TextField>(startField).controller?.text, '00:01.600');
    expect(find.text('还原片段'), findsOneWidget);
    await tester.ensureVisible(find.text('还原片段'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('还原片段'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<TextField>(startField).controller?.text, '00:01.500');

    await tester.enterText(startField, '-0.1');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('开始时间不能小于 0'), findsOneWidget);
    await tester.enterText(startField, '00:01.500');
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(endField, '00:01.400');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('结束时间需要晚于开始时间'), findsOneWidget);
    expect(find.textContaining('片段 #2：结束时间需要晚于开始时间'), findsOneWidget);

    await tester.tap(find.text('保存修改'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(paramsByMethod.containsKey('result.segments.save'), isFalse);

    await tester.enterText(endField, '00:02,500');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('结束时间需要晚于开始时间'), findsNothing);
    await tester.ensureVisible(find.byTooltip('结束提前 0.1 秒'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('结束提前 0.1 秒'));
    await tester.pump(const Duration(milliseconds: 100));
    expect((tester.widget<TextField>(endField).controller?.text), '00:02.400');

    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    final savedSegments =
        paramsByMethod['result.segments.save']?['segments'] as List<Object?>;
    final savedSegment = savedSegments.single as Map<Object?, Object?>;
    expect(savedSegment['start'], 1.5);
    expect(savedSegment['end'], 2.4);
    expect(find.text('修改已保存，字幕文件尚未更新'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('Check the timing.'), findsOneWidget);
    expectNoFlutterException();
  });

  testWidgets(
    'result review keeps the workspace available after action failures',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = WindowStateStore();
      final bridge = WindowStateBridge.main(store);
      var targetText = '早上好。';
      var resultRevision = 0;
      var resultExportRevision = 0;
      var saveAttempts = 0;
      var exportAttempts = 0;

      Map<String, Object?> resultPayload() => {
        'task': taskPayload(
          taskId: 'tvx_review_retry_123456',
          status: 'DONE',
          inputFile: r'D:\media\review-retry.mp4',
          outputPaths: {'srt': r'D:\media\review-retry.zh-CN.srt'},
          settings: {
            'result_revision': resultRevision,
            'result_export_revision': resultExportRevision,
          },
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
        'output_paths': {'srt': r'D:\media\review-retry.zh-CN.srt'},
      };

      bridge.attachServiceCaller((method, params) async {
        if (method == 'result.open') return resultPayload();
        if (method == 'result.segments.save') {
          saveAttempts += 1;
          if (saveAttempts == 1) {
            throw RpcRemoteException('write_failed', '字幕修改暂时无法保存。');
          }
          final segments = params['segments'] as List<Object?>;
          final first = segments.first as Map<Object?, Object?>;
          targetText = '${first['text_tgt']}';
          resultRevision += 1;
          return resultPayload();
        }
        if (method == 'result.reexport') {
          exportAttempts += 1;
          if (exportAttempts == 1) {
            throw RpcRemoteException('output_not_writable', '字幕文件暂时无法写入。');
          }
          resultExportRevision = resultRevision;
          return {
            'task_id': 'tvx_review_retry_123456',
            'output_paths': {'srt': r'D:\media\review-retry.zh-CN.srt'},
          };
        }
        throw RpcRemoteException('method_not_found', method);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ResultReviewWorkspace(
              taskId: 'tvx_review_retry_123456',
              bridge: bridge,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, '输入译文'),
        '早上好，已经校对。',
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();

      expect(find.text('字幕修改暂时无法保存。'), findsOneWidget);
      expect(find.text('重试保存'), findsOneWidget);
      expect(find.text('Good morning.'), findsOneWidget);
      expect(find.text('早上好，已经校对。'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, '输入译文'),
        '早上好，二次校对。',
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('字幕修改暂时无法保存。'), findsNothing);
      expect(find.text('重试保存'), findsNothing);
      expect(find.text('有未保存修改'), findsOneWidget);

      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(find.text('修改已保存，字幕文件尚未更新'), findsOneWidget);

      await tester.tap(find.text('重新导出'));
      await tester.pumpAndSettle();
      expect(find.text('字幕文件暂时无法写入。'), findsOneWidget);
      expect(find.text('重试导出'), findsOneWidget);
      expect(find.text('Good morning.'), findsOneWidget);

      await tester.tap(find.text('重试导出'));
      await tester.pumpAndSettle();
      expect(find.text('字幕文件已更新'), findsOneWidget);
      expect(saveAttempts, 2);
      expect(exportAttempts, 2);
      expectNoFlutterException();
    },
  );
}
