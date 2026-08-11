import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/app_service_client.dart';
import 'package:transvortex_desktop_flutter/widgets/memory_library_dialog.dart';

import '../app_service/app_service_test_support.dart';

void main() {
  testWidgets(
    'workbench memory library maintains collections without task selection',
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
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: MemoryLibraryDialog(
                client: AppServiceClient(transport),
                embedded: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('集中维护跨任务复用的术语资产；任务使用的是开始制作时冻结的版本快照。'), findsOneWidget);
      expect(find.text('人物名'), findsWidgets);
      expect(find.text('スバル  →  昴'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      expect(transport.calls.map((call) => call.method), [
        'memory.collections.list',
        'memory.collection.get',
      ]);
    },
  );

  testWidgets('main task picker only selects reusable memory collections', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport = RecordingRpcTransport({
      'memory.collections.list': {
        'collections': [
          {'id': 'characters', 'name': '人物名', 'revision': 2, 'entries': 1},
        ],
      },
    });
    var openedManager = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryLibraryDialog(
            client: AppServiceClient(transport),
            selectedCollectionIds: const ['characters'],
            selectionOnly: true,
            onManageLibrary: () async => openedManager = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本任务使用的术语库'), findsOneWidget);
    expect(find.text('管理术语库'), findsOneWidget);
    expect(find.text('用于本任务（1）'), findsOneWidget);
    expect(find.text('スバル  →  昴'), findsNothing);
    expect(transport.calls.map((call) => call.method), [
      'memory.collections.list',
    ]);
    await tester.tap(find.text('管理术语库'));
    await tester.pump();
    expect(openedManager, isTrue);
  });

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
