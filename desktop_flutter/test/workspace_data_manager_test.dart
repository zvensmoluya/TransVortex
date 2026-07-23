import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/desktop_app_paths.dart';
import 'package:transvortex_desktop_flutter/services/workspace_data_manager.dart';

void main() {
  late Directory sandbox;
  late Directory appData;
  late Directory workspace;
  late DesktopAppPaths paths;
  late WorkspaceDataManager manager;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('tvx-workspace-test-');
    appData = Directory('${sandbox.path}${Platform.pathSeparator}AppData');
    workspace = Directory(
      '${sandbox.path}${Platform.pathSeparator}CurrentWorkspace',
    );
    paths = DesktopAppPaths(
      appDataRoot: appData,
      configRoot: Directory('${appData.path}${Platform.pathSeparator}Config'),
      workspaceRoot: workspace,
      tasksRoot: Directory('${workspace.path}${Platform.pathSeparator}Tasks'),
      cacheRoot: Directory('${workspace.path}${Platform.pathSeparator}Cache'),
    );
    manager = WorkspaceDataManager(pathsResolver: () => paths);
    final task = Directory(
      '${paths.tasksRoot.path}${Platform.pathSeparator}task-1',
    );
    await task.create(recursive: true);
    await File(
      '${task.path}${Platform.pathSeparator}task.json',
    ).writeAsString('{}');
    await File(
      '${task.path}${Platform.pathSeparator}result.srt',
    ).writeAsString('subtitle');
    await paths.cacheRoot.create(recursive: true);
    await File(
      '${paths.cacheRoot.path}${Platform.pathSeparator}audio.tmp',
    ).writeAsBytes([1, 2, 3, 4]);
    await paths.configRoot.create(recursive: true);
    await File(
      '${paths.configRoot.path}${Platform.pathSeparator}$workspaceStorageConfigName',
    ).writeAsString('old-config');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('inspects task and cache usage', () async {
    final status = await manager.inspect();

    expect(status.root, workspace.absolute.path);
    expect(status.taskCount, 1);
    expect(status.tasksBytes, greaterThan(0));
    expect(status.cacheBytes, 4);
    expect(status.totalBytes, status.tasksBytes + 4);
  });

  test('copies, verifies, restores config, and removes old data', () async {
    final target = Directory(
      '${sandbox.path}${Platform.pathSeparator}NewWorkspace',
    );
    final progress = <int>[];

    final receipt = await manager.copyTo(
      target.path,
      onProgress: (copied, _) => progress.add(copied),
    );

    expect(
      File(
        '${target.path}${Platform.pathSeparator}Tasks${Platform.pathSeparator}task-1${Platform.pathSeparator}result.srt',
      ).readAsStringSync(),
      'subtitle',
    );
    expect(
      File(
        '${target.path}${Platform.pathSeparator}Cache${Platform.pathSeparator}audio.tmp',
      ).readAsBytesSync(),
      [1, 2, 3, 4],
    );
    expect(progress.last, greaterThan(0));

    await receipt.configFile.writeAsString('new-config');
    await manager.restoreConfiguration(receipt);
    expect(await receipt.configFile.readAsString(), 'old-config');

    await manager.removeMigratedSource(receipt);
    expect(await paths.tasksRoot.exists(), isFalse);
    expect(await paths.cacheRoot.exists(), isFalse);
  });

  test('cache cleanup preserves task records', () async {
    await manager.clearCache();

    expect(await paths.cacheRoot.list().isEmpty, isTrue);
    expect(await paths.tasksRoot.exists(), isTrue);
  });

  test('discarding a failed copy keeps a pre-existing target folder', () async {
    final target = Directory(
      '${sandbox.path}${Platform.pathSeparator}EmptyTarget',
    );
    await target.create();
    final receipt = await manager.copyTo(target.path);

    await manager.discardCopiedTarget(receipt);

    expect(await target.exists(), isTrue);
    expect(await target.list().isEmpty, isTrue);
    expect(await paths.tasksRoot.exists(), isTrue);
  });

  test('rejects non-empty and nested targets', () async {
    final nonEmpty = Directory(
      '${sandbox.path}${Platform.pathSeparator}Occupied',
    );
    await nonEmpty.create();
    await File(
      '${nonEmpty.path}${Platform.pathSeparator}personal.txt',
    ).writeAsString('keep');

    await expectLater(
      manager.copyTo(nonEmpty.path),
      throwsA(
        isA<WorkspaceDataException>().having(
          (error) => error.code,
          'code',
          'target_not_empty',
        ),
      ),
    );
    await expectLater(
      manager.copyTo('${workspace.path}${Platform.pathSeparator}Nested'),
      throwsA(
        isA<WorkspaceDataException>().having(
          (error) => error.code,
          'code',
          'nested_target',
        ),
      ),
    );
  });
}
