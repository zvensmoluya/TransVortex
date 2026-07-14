import 'dart:convert';
import 'dart:io';

const String transVortexHomeEnvironment = 'TRANSVORTEX_HOME';
const String transVortexWorkspaceEnvironment = 'TRANSVORTEX_WORKSPACE_ROOT';

enum DesktopHostPlatform { windows, macos, linux }

class DesktopAppPaths {
  const DesktopAppPaths({
    required this.appDataRoot,
    required this.configRoot,
    required this.defaultWorkspaceRoot,
    required this.settingsFile,
  });

  final Directory appDataRoot;
  final Directory configRoot;
  final Directory defaultWorkspaceRoot;
  final File settingsFile;

  Directory tasksRoot(Directory workspaceRoot) =>
      Directory(_joinPath(workspaceRoot.path, 'Tasks'));

  Directory cacheRoot(Directory workspaceRoot) =>
      Directory(_joinPath(workspaceRoot.path, 'Cache'));

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
    return DesktopAppPaths(
      appDataRoot: appDataRoot,
      configRoot: Directory(_joinPath(appDataRoot.path, 'Config')),
      defaultWorkspaceRoot: Directory(_joinPath(appDataRoot.path, 'Workspace')),
      settingsFile: File(_joinPath(appDataRoot.path, 'desktop-settings.json')),
    );
  }
}

abstract class WorkspaceSettingsStore {
  Future<Directory> loadWorkspaceRoot();

  Future<void> saveWorkspaceRoot(String path);
}

typedef WorkspaceDirectoryPicker =
    Future<String?> Function(String initialDirectory);

class DesktopWorkspaceSettings implements WorkspaceSettingsStore {
  DesktopWorkspaceSettings({
    DesktopAppPaths? paths,
    Map<String, String>? environment,
  }) : paths = paths ?? DesktopAppPaths.system(environment: environment),
       environment = environment ?? Platform.environment;

  final DesktopAppPaths paths;
  final Map<String, String> environment;

  @override
  Future<Directory> loadWorkspaceRoot() async {
    final explicit = environment[transVortexWorkspaceEnvironment]?.trim() ?? '';
    if (explicit.isNotEmpty) {
      return Directory(_normalizeAbsolutePath(explicit));
    }
    final file = paths.settingsFile;
    if (!await file.exists()) return paths.defaultWorkspaceRoot;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('desktop settings must be an object');
      }
      final value = decoded['workspace_root'];
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('workspace_root is required');
      }
      return Directory(_normalizeAbsolutePath(value));
    } on DesktopWorkspaceSettingsException {
      rethrow;
    } on Object catch (error) {
      throw DesktopWorkspaceSettingsException('任务资料库设置无法读取：$error');
    }
  }

  @override
  Future<void> saveWorkspaceRoot(String path) async {
    if ((environment[transVortexWorkspaceEnvironment]?.trim() ?? '')
        .isNotEmpty) {
      throw const DesktopWorkspaceSettingsException(
        '当前任务资料库由 TRANSVORTEX_WORKSPACE_ROOT 固定，不能从应用内修改',
      );
    }
    final normalized = _normalizeAbsolutePath(path);
    await paths.appDataRoot.create(recursive: true);
    await paths.settingsFile.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'version': 1, 'workspace_root': normalized}),
      flush: true,
    );
  }
}

class DesktopWorkspaceSettingsException implements Exception {
  const DesktopWorkspaceSettingsException(this.message);

  final String message;

  @override
  String toString() => message;
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
    throw DesktopWorkspaceSettingsException('无法确定当前用户目录');
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

String _normalizeAbsolutePath(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || !_isAbsolutePath(trimmed)) {
    throw DesktopWorkspaceSettingsException('任务资料库必须使用绝对路径');
  }
  return Directory(trimmed).absolute.path;
}

bool pathIsInsideDirectory(String path, String directory) {
  String normalize(String value) {
    var normalized = Directory(value).absolute.path;
    if (Platform.isWindows) normalized = normalized.toLowerCase();
    while (normalized.length > 1 &&
        (normalized.endsWith('/') || normalized.endsWith(r'\'))) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  final candidate = normalize(path);
  final parent = normalize(directory);
  if (candidate == parent) return true;
  return candidate.startsWith('$parent${Platform.pathSeparator}');
}

bool _isAbsolutePath(String path) {
  if (path.startsWith('/') || path.startsWith(r'\\')) return true;
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
}

String _joinPath(String first, String second) {
  if (first.endsWith('/') || first.endsWith(r'\')) return '$first$second';
  return '$first${Platform.pathSeparator}$second';
}
