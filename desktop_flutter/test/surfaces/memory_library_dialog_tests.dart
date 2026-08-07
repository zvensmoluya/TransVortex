import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/widgets/memory_library_dialog.dart';

import '../app_service/app_service_test_support.dart';

void main() {
  testWidgets(
    'memory library separates task selection from collection editing',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(720, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final transport = RecordingRpcTransport({
        'memory.collections.list': {
          'collections': [
            {
              'id': 'characters',
              'name': '人物名',
              'description': '跨任务复用的人物译名',
              'revision': 2,
              'entries': 1,
            },
          ],
        },
        'memory.collection.get': {
          'collection': {
            'id': 'characters',
            'name': '人物名',
            'description': '跨任务复用的人物译名',
            'revision': 2,
            'entries': [
              {
                'id': 'subaru',
                'source': 'スバル',
                'target': '昴',
                'status': 'locked',
                'category': 'name',
              },
            ],
          },
        },
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MemoryLibraryDialog(client: AppServiceClient(transport)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('术语库独立于作品和任务。勾选的是本任务要使用的库；任务开始时会冻结版本快照。'),
        findsOneWidget,
      );
      expect(find.text('人物名'), findsWidgets);
      expect(find.text('スバル  →  昴'), findsOneWidget);
      expect(find.text('用于本任务（0）'), findsOneWidget);

      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      expect(find.text('用于本任务（1）'), findsOneWidget);
      expect(transport.calls.map((call) => call.method), [
        'memory.collections.list',
        'memory.collection.get',
      ]);
    },
  );

  testWidgets('candidate promotion previews before the persistent write', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport = RecordingRpcTransport({
      'memory.collections.list': {
        'collections': [
          {'id': 'shared', 'name': '共享术语', 'revision': 4, 'entries': 2},
        ],
      },
      'memory.candidates.promote': {
        'applied': [
          {'entry_id': 'candidate-1', 'collection_entry_id': 'saved-1'},
        ],
        'conflicts': [],
      },
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryPromotionDialog(
            client: AppServiceClient(transport),
            taskId: 'task-1',
            candidates: [
              MemoryEntryItem.fromJson({
                'id': 'candidate-1',
                'source': 'エミリア',
                'target': '爱蜜莉雅',
                'status': 'proposed',
              }),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.tap(find.text('保存所选（1）'));
    await tester.pumpAndSettle();
    expect(find.text('保存这些术语？'), findsOneWidget);
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    final promoteCalls = transport.calls
        .where((call) => call.method == 'memory.candidates.promote')
        .toList();
    expect(promoteCalls, hasLength(2));
    expect(promoteCalls.first.params['dry_run'], isTrue);
    expect(promoteCalls.last.params['dry_run'], isFalse);
    expect(promoteCalls.last.params['expected_revision'], 4);
    expect(promoteCalls.last.params['entry_ids'], ['candidate-1']);
  });
}
