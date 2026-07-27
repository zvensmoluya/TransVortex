import 'dart:convert';
import 'dart:io';

import 'desktop_app_paths.dart';

const String workspaceMarkerName = '.transvortex-workspace.json';
const String agentHandoffCacheName = 'AgentHandoffs';
const String agentHandoffStateName = 'handoff.json';

typedef WorkspacePathsResolver = DesktopAppPaths Function();
typedef WorkspaceCopyProgress = void Function(int copiedBytes, int totalBytes);

class WorkspaceDataException implements Exception {
  WorkspaceDataException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class WorkspaceDataStatus {
  const WorkspaceDataStatus({
    required this.root,
    required this.tasksBytes,
    required this.cacheBytes,
    required this.taskCount,
  });

  final String root;
  final int tasksBytes;
  final int cacheBytes;
  final int taskCount;

  int get totalBytes => tasksBytes + cacheBytes;
}

class WorkspaceMigrationReceipt {
  const WorkspaceMigrationReceipt({
    required this.sourceRoot,
    required this.targetRoot,
    required this.configFile,
    required this.previousConfig,
    required this.targetExisted,
  });

  final Directory sourceRoot;
  final Directory targetRoot;
  final File configFile;
  final List<int>? previousConfig;
  final bool targetExisted;
}

abstract class WorkspaceDataOperations {
  DesktopAppPaths currentPaths();

  Future<WorkspaceDataStatus> inspect();

  Future<void> clearCache();

  Future<WorkspaceMigrationReceipt> copyTo(
    String targetPath, {
    WorkspaceCopyProgress? onProgress,
  });

  Future<void> restoreConfiguration(WorkspaceMigrationReceipt receipt);

  Future<void> discardCopiedTarget(WorkspaceMigrationReceipt receipt);

  Future<void> removeMigratedSource(WorkspaceMigrationReceipt receipt);
}

class WorkspaceDataManager implements WorkspaceDataOperations {
  WorkspaceDataManager({WorkspacePathsResolver? pathsResolver})
    : _pathsResolver = pathsResolver ?? DesktopAppPaths.system;

  final WorkspacePathsResolver _pathsResolver;

  @override
  DesktopAppPaths currentPaths() => _pathsResolver();

  @override
  Future<WorkspaceDataStatus> inspect() async {
    final paths = currentPaths();
    return WorkspaceDataStatus(
      root: paths.workspaceRoot.path,
      tasksBytes: await _directoryBytes(paths.tasksRoot),
      cacheBytes: await _directoryBytes(paths.cacheRoot),
      taskCount: await _taskDirectoryCount(paths.tasksRoot),
    );
  }

  @override
  Future<void> clearCache() async {
    final cache = currentPaths().cacheRoot.absolute;
    if (!await cache.exists()) return;
    await for (final entity in cache.list(followLinks: false)) {
      if (entity is Directory &&
          _basename(entity.path) == agentHandoffCacheName) {
        await _clearAgentHandoffCache(entity);
        continue;
      }
      await entity.delete(recursive: true);
    }
  }

  @override
  Future<WorkspaceMigrationReceipt> copyTo(
    String targetPath, {
    WorkspaceCopyProgress? onProgress,
  }) async {
    final paths = currentPaths();
    final source = paths.workspaceRoot.absolute;
    final target = _validatedTarget(
      targetPath,
      sourceRoot: source,
      configRoot: paths.configRoot.absolute,
    );
    final targetExisted = await target.exists();
    if (targetExisted && !await target.list(followLinks: false).isEmpty) {
      throw WorkspaceDataException(
        'target_not_empty',
        '所选文件夹不是空文件夹，请新建一个专用文件夹。',
      );
    }
    final configFile = File(
      _join(paths.configRoot.path, workspaceStorageConfigName),
    );
    final previousConfig = await configFile.exists()
        ? await configFile.readAsBytes()
        : null;
    final receipt = WorkspaceMigrationReceipt(
      sourceRoot: source,
      targetRoot: target,
      configFile: configFile,
      previousConfig: previousConfig,
      targetExisted: targetExisted,
    );
    try {
      await target.create(recursive: true);
      final sources = [paths.tasksRoot.absolute, paths.cacheRoot.absolute];
      final totalBytes = await _directoriesBytes(sources);
      var copiedBytes = 0;
      onProgress?.call(0, totalBytes);
      for (final sourceDirectory in sources) {
        final destination = Directory(
          _join(target.path, _basename(sourceDirectory.path)),
        );
        copiedBytes = await _copyDirectory(
          sourceDirectory,
          destination,
          copiedBytes: copiedBytes,
          totalBytes: totalBytes,
          onProgress: onProgress,
        );
      }
      final copiedTotal = await _directoriesBytes([
        Directory(_join(target.path, 'Tasks')),
        Directory(_join(target.path, 'Cache')),
      ]);
      if (copiedTotal != totalBytes) {
        throw WorkspaceDataException(
          'copy_verification_failed',
          '工作数据复制校验失败，尚未切换保存位置。',
        );
      }
      onProgress?.call(totalBytes, totalBytes);
      return receipt;
    } on Object {
      await discardCopiedTarget(receipt);
      rethrow;
    }
  }

  @override
  Future<void> restoreConfiguration(WorkspaceMigrationReceipt receipt) async {
    final configFile = receipt.configFile;
    final previous = receipt.previousConfig;
    if (previous == null) {
      if (await configFile.exists()) await configFile.delete();
      return;
    }
    await configFile.parent.create(recursive: true);
    final temporary = File('${configFile.path}.rollback.tmp');
    await temporary.writeAsBytes(previous, flush: true);
    if (await configFile.exists()) await configFile.delete();
    await temporary.rename(configFile.path);
  }

  @override
  Future<void> discardCopiedTarget(WorkspaceMigrationReceipt receipt) async {
    final target = receipt.targetRoot.absolute;
    for (final name in ['Tasks', 'Cache', workspaceMarkerName]) {
      final entityPath = _join(target.path, name);
      final type = await FileSystemEntity.type(entityPath, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      await (type == FileSystemEntityType.directory
          ? Directory(entityPath).delete(recursive: true)
          : File(entityPath).delete());
    }
    if (!receipt.targetExisted && await target.exists()) {
      if (await target.list(followLinks: false).isEmpty) {
        await target.delete();
      }
    }
  }

  @override
  Future<void> removeMigratedSource(WorkspaceMigrationReceipt receipt) async {
    final source = receipt.sourceRoot.absolute;
    for (final name in ['Tasks', 'Cache', workspaceMarkerName]) {
      final entityPath = _join(source.path, name);
      final type = await FileSystemEntity.type(entityPath, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      await (type == FileSystemEntityType.directory
          ? Directory(entityPath).delete(recursive: true)
          : File(entityPath).delete());
    }
    if (await source.exists() &&
        await source.list(followLinks: false).isEmpty) {
      await source.delete();
    }
  }
}

Future<void> _clearAgentHandoffCache(Directory root) async {
  await for (final entity in root.list(followLinks: false)) {
    if (entity is Directory && await _isActiveAgentHandoff(entity)) continue;
    await entity.delete(recursive: true);
  }
  if (await root.exists() && await root.list(followLinks: false).isEmpty) {
    await root.delete();
  }
}

Future<bool> _isActiveAgentHandoff(Directory directory) async {
  final stateFile = File(_join(directory.path, agentHandoffStateName));
  if (!await stateFile.exists()) return false;
  try {
    final decoded = jsonDecode(await stateFile.readAsString());
    return decoded is Map &&
        decoded['schema_version'] == 1 &&
        decoded['product'] == 'TransVortex' &&
        decoded['handoff_id'] == _basename(directory.path) &&
        decoded['status'] == 'launched';
  } on Object {
    return false;
  }
}

Directory _validatedTarget(
  String rawPath, {
  required Directory sourceRoot,
  required Directory configRoot,
}) {
  final value = rawPath.trim();
  if (value.isEmpty || !Directory(value).isAbsolute) {
    throw WorkspaceDataException('invalid_target', '请选择磁盘上的专用工作数据文件夹。');
  }
  final target = Directory(value).absolute;
  if (_samePath(target.path, target.parent.path)) {
    throw WorkspaceDataException('invalid_target', '不能直接使用磁盘根目录。');
  }
  if (_samePath(target.path, sourceRoot.path)) {
    throw WorkspaceDataException('same_target', '所选位置已经是当前工作数据位置。');
  }
  if (_sameOrChild(target.path, configRoot.path)) {
    throw WorkspaceDataException('config_target', '工作数据不能放在应用配置目录中。');
  }
  if (_sameOrChild(target.path, sourceRoot.path) ||
      _sameOrChild(sourceRoot.path, target.path)) {
    throw WorkspaceDataException('nested_target', '新旧工作数据文件夹不能互相嵌套。');
  }
  return target;
}

Future<int> _copyDirectory(
  Directory source,
  Directory destination, {
  required int copiedBytes,
  required int totalBytes,
  WorkspaceCopyProgress? onProgress,
}) async {
  await destination.create(recursive: true);
  if (!await source.exists()) return copiedBytes;
  await for (final entity in source.list(followLinks: false)) {
    final destinationPath = _join(destination.path, _basename(entity.path));
    if (entity is Directory) {
      copiedBytes = await _copyDirectory(
        entity,
        Directory(destinationPath),
        copiedBytes: copiedBytes,
        totalBytes: totalBytes,
        onProgress: onProgress,
      );
    } else if (entity is File) {
      await entity.copy(destinationPath);
      final length = await entity.length();
      final copiedLength = await File(destinationPath).length();
      if (copiedLength != length) {
        throw WorkspaceDataException(
          'copy_verification_failed',
          '文件复制校验失败：${_basename(entity.path)}',
        );
      }
      copiedBytes += length;
      onProgress?.call(copiedBytes, totalBytes);
    } else {
      throw WorkspaceDataException(
        'unsupported_entry',
        '工作数据中包含不支持迁移的链接：${entity.path}',
      );
    }
  }
  return copiedBytes;
}

Future<int> _directoriesBytes(Iterable<Directory> directories) async {
  var total = 0;
  for (final directory in directories) {
    total += await _directoryBytes(directory);
  }
  return total;
}

Future<int> _directoryBytes(Directory directory) async {
  if (!await directory.exists()) return 0;
  var total = 0;
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) total += await entity.length();
  }
  return total;
}

Future<int> _taskDirectoryCount(Directory directory) async {
  if (!await directory.exists()) return 0;
  var count = 0;
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is Directory &&
        await File(_join(entity.path, 'task.json')).exists()) {
      count += 1;
    }
  }
  return count;
}

String _join(String first, String second) {
  if (first.endsWith('/') || first.endsWith(r'\')) return '$first$second';
  return '$first${Platform.pathSeparator}$second';
}

String _basename(String path) {
  final normalized = path.replaceAll(r'\', '/');
  return normalized.split('/').where((part) => part.isNotEmpty).last;
}

bool _sameOrChild(String candidate, String parent) {
  final normalizedCandidate = _normalizedPath(candidate);
  final normalizedParent = _normalizedPath(parent);
  return normalizedCandidate == normalizedParent ||
      normalizedCandidate.startsWith('$normalizedParent/');
}

bool _samePath(String first, String second) =>
    _normalizedPath(first) == _normalizedPath(second);

String _normalizedPath(String value) {
  var normalized = Directory(value).absolute.path.replaceAll(r'\', '/');
  while (normalized.endsWith('/') && normalized.length > 3) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}
