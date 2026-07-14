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
      paths.tasksRoot.path,
      endsWith('Workspace${Platform.pathSeparator}Tasks'),
    );
    expect(
      paths.cacheRoot.path,
      endsWith('Workspace${Platform.pathSeparator}Cache'),
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
    expect(paths.tasksRoot.path, r'D:\tvx-home\Workspace\Tasks');
    expect(paths.cacheRoot.path, r'D:\tvx-home\Workspace\Cache');
  });
}
