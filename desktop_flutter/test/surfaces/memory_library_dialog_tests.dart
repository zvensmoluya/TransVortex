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

      expect(
        find.text('术语库是一组可跨任务复用的术语；任务开始后会固定当前版本，之后的修改只影响新任务。'),
        findsOneWidget,
      );
      expect(find.text('人物名'), findsWidgets);
      expect(find.text('スバル  →  昴'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      expect(transport.calls.map((call) => call.method), [
        'memory.collections.list',
        'memory.collection.get',
      ]);
    },
  );

  testWidgets('new collection form favors choices over internal fields', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport = RecordingRpcTransport({
      'memory.collections.list': {'collections': []},
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryLibraryDialog(
            client: AppServiceClient(transport),
            embedded: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建术语库'));
    await tester.pumpAndSettle();

    expect(find.text('一个术语库可以包含多条跨任务复用的术语。创建后会进入术语列表。'), findsOneWidget);
    expect(find.text('ID（可留空自动生成）'), findsNothing);
    expect(find.text('语言对（逗号分隔，如 ja->zh-CN）'), findsNothing);
    expect(find.text('不限语言'), findsOneWidget);
    expect(find.text('更多属性（可选）'), findsOneWidget);

    await tester.tap(find.text('创建并进入术语库'));
    await tester.pump();
    expect(find.text('请填写术语库名称'), findsOneWidget);
  });

  testWidgets('task picker creates and selects a library in one step', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport = RecordingRpcTransport({
      'memory.collections.list': {'collections': []},
      'memory.collection.create': {
        'collection': {
          'id': 'memcol_demo',
          'name': '日语角色名库',
          'revision': 1,
          'language_pairs': ['ja->zh-CN'],
          'entries': [],
        },
      },
    });
    List<String>? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open-memory-picker'),
              onPressed: () async {
                selected = await showDialog<List<String>>(
                  context: context,
                  builder: (_) => MemoryLibraryDialog(
                    client: AppServiceClient(transport),
                    selectionOnly: true,
                    suggestedSourceLanguage: 'ja',
                    suggestedTargetLanguage: 'zh-CN',
                  ),
                );
              },
              child: const Text('选择术语库'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-memory-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建并用于本任务'));
    await tester.pumpAndSettle();
    expect(find.text('已按当前任务预填适用语言：日语 → 简体中文。也可以改为不限语言。'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, '日语角色名库');
    await tester.tap(find.text('创建并用于本任务'));
    await tester.pumpAndSettle();

    expect(selected, ['memcol_demo']);
    final createCall = transport.calls.firstWhere(
      (call) => call.method == 'memory.collection.create',
    );
    expect(createCall.params['language_pairs'], ['ja->zh-CN']);
  });

  testWidgets('collection scope selection produces a language-pair payload', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final results = <String, Object?>{
      'memory.collections.list': {'collections': []},
      'memory.collection.create': {
        'collection': {
          'id': 'memcol_demo',
          'name': '日语角色名库',
          'revision': 1,
          'language_pairs': ['ja->zh-CN'],
          'entries': [],
        },
      },
    };
    final transport = RecordingRpcTransport(results);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryLibraryDialog(
            client: AppServiceClient(transport),
            embedded: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建术语库'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('不限语言'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('指定语言对').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加语言对'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '日语角色名库');
    await tester.tap(find.text('创建并进入术语库'));
    await tester.pumpAndSettle();

    final createCall = transport.calls.firstWhere(
      (call) => call.method == 'memory.collection.create',
    );
    expect(createCall.params['name'], '日语角色名库');
    expect(createCall.params['collection_id'], '');
    expect(createCall.params['language_pairs'], ['ja->zh-CN']);
  });

  testWidgets('editing a wildcard language scope keeps its meaning', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport = RecordingRpcTransport({
      'memory.collections.list': {
        'collections': [
          {
            'id': 'wildcard',
            'name': '跨语言提示',
            'revision': 3,
            'language_pairs': ['ja->*'],
            'entries': 1,
          },
        ],
      },
      'memory.collection.get': {
        'collection': {
          'id': 'wildcard',
          'name': '跨语言提示',
          'revision': 3,
          'language_pairs': ['ja->*'],
          'entries': [],
        },
      },
      'memory.collection.update': {
        'collection': {
          'id': 'wildcard',
          'name': '跨语言提示',
          'revision': 4,
          'language_pairs': ['ja->*'],
          'entries': [],
        },
      },
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryLibraryDialog(
            client: AppServiceClient(transport),
            embedded: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑术语库'));
    await tester.pumpAndSettle();
    expect(find.text('日语 → 任意目标语言'), findsWidgets);
    await tester.tap(find.text('保存更改'));
    await tester.pumpAndSettle();

    final updateCall = transport.calls.firstWhere(
      (call) => call.method == 'memory.collection.update',
    );
    final changes = updateCall.params['changes']! as Map<String, Object?>;
    expect(changes['language_pairs'], ['ja->*']);
  });

  testWidgets('empty collection detail offers the first-term action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport = RecordingRpcTransport({
      'memory.collections.list': {
        'collections': [
          {'id': 'empty', 'name': '空术语库', 'revision': 1, 'entries': 0},
        ],
      },
      'memory.collection.get': {
        'collection': {
          'id': 'empty',
          'name': '空术语库',
          'revision': 1,
          'entries': [],
        },
      },
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryLibraryDialog(
            client: AppServiceClient(transport),
            embedded: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('术语'), findsOneWidget);
    expect(find.text('0 条'), findsOneWidget);
    expect(find.text('这个术语库还没有术语'), findsOneWidget);
    expect(find.text('添加第一条术语'), findsOneWidget);

    await tester.tap(find.text('添加第一条术语'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'スバル');
    await tester.tap(find.text('添加术语').last);
    await tester.pump();
    expect(find.text('请填写译文，或将使用方式改为“仅作提示”'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
  });

  testWidgets('source-only hint can be saved without a translation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transport = RecordingRpcTransport({
      'memory.collections.list': {
        'collections': [
          {'id': 'hints', 'name': '识别提示', 'revision': 1, 'entries': 0},
        ],
      },
      'memory.collection.get': {
        'collection': {
          'id': 'hints',
          'name': '识别提示',
          'revision': 1,
          'entries': [],
        },
      },
      'memory.entry.upsert': {
        'collection': {
          'id': 'hints',
          'name': '识别提示',
          'revision': 2,
          'entries': [
            {
              'id': 'hint-1',
              'source': 'スバル',
              'target': '',
              'status': 'confirmed',
              'constraint': 'hint',
            },
          ],
        },
      },
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryLibraryDialog(
            client: AppServiceClient(transport),
            embedded: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加第一条术语'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'スバル');
    await tester.tap(find.text('建议采用').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅作提示').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加术语').last);
    await tester.pumpAndSettle();

    final upsertCall = transport.calls.firstWhere(
      (call) => call.method == 'memory.entry.upsert',
    );
    final entry = upsertCall.params['entry']! as Map<String, Object?>;
    expect(entry['source'], 'スバル');
    expect(entry['target'], '');
    expect(entry['constraint'], 'hint');
  });

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
