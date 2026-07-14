import 'dart:io';

const String transVortexHomeEnvironment = 'TRANSVORTEX_HOME';

enum DesktopHostPlatform { windows, macos, linux }

class DesktopAppPaths {
  const DesktopAppPaths({
    required this.appDataRoot,
    required this.configRoot,
    required this.tasksRoot,
    required this.cacheRoot,
  });

  final Directory appDataRoot;
  final Directory configRoot;
  final Directory tasksRoot;
  final Directory cacheRoot;

  factory DesktopAppPaths.system({
    Map<String, String>? environment,
    DesktopHostPlatform? platform,
  }) {
    final env = environment ?? Platform.environment;
    final host = platform ?? _currentPlatform();
    final explicitHome = env[transVortexHomeEnvironment]?.trim() ?? '';
    final appDataRoot = Directory(
      explicitHome.isNotEmpty
          ? _expandHome(explicitHome, env, host)
          : _defaultAppDataRoot(env, host),
    ).absolute;
    final workspaceRoot = Directory(_joinPath(appDataRoot.path, 'Workspace'));
    return DesktopAppPaths(
      appDataRoot: appDataRoot,
      configRoot: Directory(_joinPath(appDataRoot.path, 'Config')),
      tasksRoot: Directory(_joinPath(workspaceRoot.path, 'Tasks')),
      cacheRoot: Directory(_joinPath(workspaceRoot.path, 'Cache')),
    );
  }
}

DesktopHostPlatform _currentPlatform() {
  if (Platform.isWindows) return DesktopHostPlatform.windows;
  if (Platform.isMacOS) return DesktopHostPlatform.macos;
  return DesktopHostPlatform.linux;
}

String _defaultAppDataRoot(
  Map<String, String> environment,
  DesktopHostPlatform platform,
) {
  switch (platform) {
    case DesktopHostPlatform.windows:
      final localAppData = environment['LOCALAPPDATA']?.trim() ?? '';
      if (localAppData.isNotEmpty) {
        return _joinPath(localAppData, 'TransVortex');
      }
      final home = _homePath(environment, platform);
      return _joinPath(_joinPath(home, 'AppData'), 'Local\\TransVortex');
    case DesktopHostPlatform.macos:
      final home = _homePath(environment, platform);
      return _joinPath(
        _joinPath(home, 'Library'),
        'Application Support/TransVortex',
      );
    case DesktopHostPlatform.linux:
      final xdgDataHome = environment['XDG_DATA_HOME']?.trim() ?? '';
      if (xdgDataHome.isNotEmpty) {
        return _joinPath(xdgDataHome, 'transvortex');
      }
      final home = _homePath(environment, platform);
      return _joinPath(_joinPath(home, '.local'), 'share/transvortex');
  }
}

String _homePath(
  Map<String, String> environment,
  DesktopHostPlatform platform,
) {
  final key = platform == DesktopHostPlatform.windows ? 'USERPROFILE' : 'HOME';
  final home = environment[key]?.trim() ?? '';
  if (home.isEmpty) {
    throw StateError('无法确定当前用户目录');
  }
  return home;
}

String _expandHome(
  String path,
  Map<String, String> environment,
  DesktopHostPlatform platform,
) {
  if (path == '~') return _homePath(environment, platform);
  if (path.startsWith('~/') || path.startsWith(r'~\')) {
    return _joinPath(_homePath(environment, platform), path.substring(2));
  }
  return path;
}

String _joinPath(String first, String second) {
  if (first.endsWith('/') || first.endsWith(r'\')) return '$first$second';
  return '$first${Platform.pathSeparator}$second';
}
