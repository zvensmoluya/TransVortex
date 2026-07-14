import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/desktop_app_paths.dart';

void main() {
  test('Windows desktop paths default outside the installation workspace', () {
    final paths = DesktopAppPaths.system(
      environment: const {
        'LOCALAPPDATA': r'C:\Users\demo\AppData\Local',
        'USERPROFILE': r'C:\Users\demo',
      },
      platform: DesktopHostPlatform.windows,
    );

    expect(paths.appDataRoot.path, contains(r'AppData\Local\TransVortex'));
    expect(paths.configRoot.path, endsWith('Config'));
    expect(paths.defaultWorkspaceRoot.path, endsWith('Workspace'));
    expect(paths.tasksRoot(paths.defaultWorkspaceRoot).path, endsWith('Tasks'));
  });

  test('TRANSVORTEX_HOME overrides the desktop app data root', () {
    final paths = DesktopAppPaths.system(
      environment: const {
        'TRANSVORTEX_HOME': r'D:\tvx-home',
        'USERPROFILE': r'C:\Users\demo',
      },
      platform: DesktopHostPlatform.windows,
    );

    expect(paths.appDataRoot.path, r'D:\tvx-home');
    expect(paths.settingsFile.path, endsWith('desktop-settings.json'));
  });

  test('workspace settings persist an absolute custom directory', () async {
    final temp = await Directory.systemTemp.createTemp('tvx_paths_test_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final paths = DesktopAppPaths(
      appDataRoot: Directory('${temp.path}${Platform.pathSeparator}app-data'),
      configRoot: Directory(
        '${temp.path}${Platform.pathSeparator}app-data${Platform.pathSeparator}Config',
      ),
      defaultWorkspaceRoot: Directory(
        '${temp.path}${Platform.pathSeparator}default-workspace',
      ),
      settingsFile: File(
        '${temp.path}${Platform.pathSeparator}app-data${Platform.pathSeparator}desktop-settings.json',
      ),
    );
    final settings = DesktopWorkspaceSettings(
      paths: paths,
      environment: const {},
    );
    final custom = Directory(
      '${temp.path}${Platform.pathSeparator}custom-workspace',
    );

    expect(
      (await settings.loadWorkspaceRoot()).path,
      paths.defaultWorkspaceRoot.path,
    );
    await settings.saveWorkspaceRoot(custom.path);

    expect((await settings.loadWorkspaceRoot()).path, custom.absolute.path);
    expect(await paths.settingsFile.exists(), isTrue);
    expect(await paths.settingsFile.readAsString(), contains('workspace_root'));
  });

  test('workspace environment override is read-only', () async {
    final temp = await Directory.systemTemp.createTemp('tvx_paths_test_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final paths = DesktopAppPaths(
      appDataRoot: temp,
      configRoot: Directory('${temp.path}${Platform.pathSeparator}Config'),
      defaultWorkspaceRoot: Directory(
        '${temp.path}${Platform.pathSeparator}Workspace',
      ),
      settingsFile: File(
        '${temp.path}${Platform.pathSeparator}desktop-settings.json',
      ),
    );
    final explicit = Directory('${temp.path}${Platform.pathSeparator}explicit');
    final settings = DesktopWorkspaceSettings(
      paths: paths,
      environment: {transVortexWorkspaceEnvironment: explicit.path},
    );

    expect((await settings.loadWorkspaceRoot()).path, explicit.absolute.path);
    await expectLater(
      settings.saveWorkspaceRoot(temp.path),
      throwsA(isA<DesktopWorkspaceSettingsException>()),
    );
  });

  test('path containment recognizes the directory itself and descendants', () {
    final root = Directory.current.absolute.path;
    final child = '$root${Platform.pathSeparator}child';
    final sibling =
        '${Directory.current.parent.path}${Platform.pathSeparator}sibling';

    expect(pathIsInsideDirectory(root, root), isTrue);
    expect(pathIsInsideDirectory(child, root), isTrue);
    expect(pathIsInsideDirectory(sibling, root), isFalse);
  });
}
