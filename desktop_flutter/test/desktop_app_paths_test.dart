import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvortex_desktop_flutter/services/desktop_app_paths.dart';

void main() {
  test('Windows desktop paths use fixed app-managed storage', () {
    final paths = DesktopAppPaths.system(
      environment: const {
        'LOCALAPPDATA': r'C:\Users\demo\AppData\Local',
        'USERPROFILE': r'C:\Users\demo',
      },
      platform: DesktopHostPlatform.windows,
    );

    expect(paths.appDataRoot.path, contains(r'AppData\Local\TransVortex'));
    expect(paths.configRoot.path, endsWith('Config'));
    expect(
      paths.workspaceRoot.path,
      endsWith('TransVortex${Platform.pathSeparator}Workspace'),
    );
    expect(
      paths.tasksRoot.path,
      endsWith('Workspace${Platform.pathSeparator}Tasks'),
    );
    expect(
      paths.cacheRoot.path,
      endsWith('Workspace${Platform.pathSeparator}Cache'),
    );
    expect(
      paths.memoryRoot.path,
      endsWith('Workspace${Platform.pathSeparator}Memory'),
    );
  });

  test('TRANSVORTEX_HOME overrides all desktop paths for development', () {
    final paths = DesktopAppPaths.system(
      environment: const {
        'TRANSVORTEX_HOME': r'D:\tvx-home',
        'USERPROFILE': r'C:\Users\demo',
      },
      platform: DesktopHostPlatform.windows,
    );

    expect(paths.appDataRoot.path, r'D:\tvx-home');
    expect(paths.configRoot.path, r'D:\tvx-home\Config');
    expect(paths.workspaceRoot.path, r'D:\tvx-home\Workspace');
    expect(paths.tasksRoot.path, r'D:\tvx-home\Workspace\Tasks');
    expect(paths.cacheRoot.path, r'D:\tvx-home\Workspace\Cache');
    expect(paths.memoryRoot.path, r'D:\tvx-home\Workspace\Memory');
  });

  test('workspace config keeps task data outside the user profile', () {
    final localAppData = Directory.systemTemp.createTempSync(
      'transvortex-paths-',
    );
    addTearDown(() => localAppData.deleteSync(recursive: true));
    final configRoot = Directory(
      '${localAppData.path}${Platform.pathSeparator}TransVortex'
      '${Platform.pathSeparator}Config',
    )..createSync(recursive: true);
    File(
      '${configRoot.path}${Platform.pathSeparator}$workspaceStorageConfigName',
    ).writeAsStringSync(
      '{"schema_version":1,"workspace_root":"D:\\\\TransVortexData"}',
    );

    final paths = DesktopAppPaths.system(
      environment: {
        'LOCALAPPDATA': localAppData.path,
        'USERPROFILE': r'C:\Users\demo',
      },
      platform: DesktopHostPlatform.windows,
    );

    expect(paths.configRoot.path, startsWith(localAppData.path));
    expect(paths.workspaceRoot.path, r'D:\TransVortexData');
    expect(paths.tasksRoot.path, r'D:\TransVortexData\Tasks');
    expect(paths.cacheRoot.path, r'D:\TransVortexData\Cache');
    expect(paths.memoryRoot.path, r'D:\TransVortexData\Memory');
  });

  test('invalid workspace config falls back to app data', () {
    final localAppData = Directory.systemTemp.createTempSync(
      'transvortex-paths-',
    );
    addTearDown(() => localAppData.deleteSync(recursive: true));
    final configRoot = Directory(
      '${localAppData.path}${Platform.pathSeparator}TransVortex'
      '${Platform.pathSeparator}Config',
    )..createSync(recursive: true);
    File(
      '${configRoot.path}${Platform.pathSeparator}$workspaceStorageConfigName',
    ).writeAsStringSync('{"schema_version":2,"workspace_root":"D:\\\\Data"}');

    final paths = DesktopAppPaths.system(
      environment: {
        'LOCALAPPDATA': localAppData.path,
        'USERPROFILE': r'C:\Users\demo',
      },
      platform: DesktopHostPlatform.windows,
    );

    expect(
      paths.workspaceRoot.path,
      endsWith('TransVortex${Platform.pathSeparator}Workspace'),
    );
  });
}
