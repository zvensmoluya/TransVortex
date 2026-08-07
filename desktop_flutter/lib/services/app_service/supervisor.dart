import 'dart:async';
import 'dart:io';

import '../desktop_app_paths.dart';
import 'client.dart';
import 'transport.dart';

typedef ProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

Future<Process> _defaultProcessStarter(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) {
  return Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
}

class LocalServiceLaunchException implements Exception {
  LocalServiceLaunchException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalServiceSupervisor {
  LocalServiceSupervisor({
    this.repoRoot,
    this.serviceRoot,
    this.appPaths,
    ProcessStarter? processStarter,
    this.pythonExecutable,
    this.requestTimeout = const Duration(seconds: 8),
  }) : _processStarter = processStarter ?? _defaultProcessStarter;

  final Directory? repoRoot;
  final Directory? serviceRoot;
  final DesktopAppPaths? appPaths;
  final ProcessStarter _processStarter;
  final String? pythonExecutable;
  final Duration requestTimeout;

  Future<LocalServiceSession> start() async {
    final root = repoRoot ?? findAppRoot();
    if (root == null) {
      throw LocalServiceLaunchException('找不到本地服务所需的应用资源目录');
    }
    final explicitPython = pythonExecutable?.trim() ?? '';
    final bundledPython = _bundledPython(root);
    final hasBundledRuntime = _hasBundledRuntimeManifest(root);
    final bundledMediaTools = _bundledMediaTools(root);
    final hasBundledMediaTools = _hasBundledMediaToolsManifest(root);
    if (explicitPython.isEmpty &&
        hasBundledRuntime &&
        !bundledPython.existsSync()) {
      throw LocalServiceLaunchException(
        '应用内置的 Python runtime 不完整：缺少 ${bundledPython.path}',
      );
    }
    if (hasBundledMediaTools &&
        (!_bundledFfmpeg(root).existsSync() ||
            !_bundledFfprobe(root).existsSync())) {
      throw LocalServiceLaunchException(
        '应用内置的 FFmpeg 工具不完整：${bundledMediaTools.path}',
      );
    }
    final useBundledRuntime = explicitPython.isEmpty && hasBundledRuntime;
    final servicePython = explicitPython.isNotEmpty
        ? explicitPython
        : useBundledRuntime
        ? bundledPython.path
        : 'python';
    final paths = appPaths ?? DesktopAppPaths.system();
    final explicitServiceRoot = serviceRoot;
    final runtimeRoot = explicitServiceRoot ?? paths.configRoot;
    final taskArtifactsRoot = explicitServiceRoot == null
        ? paths.tasksRoot
        : null;
    final taskCacheRoot = explicitServiceRoot == null ? paths.cacheRoot : null;
    if (explicitServiceRoot == null) {
      await _prepareDesktopRuntimeRoot(root, runtimeRoot);
    }
    if (taskArtifactsRoot != null) {
      await taskArtifactsRoot.create(recursive: true);
    }
    if (taskCacheRoot != null) {
      await taskCacheRoot.create(recursive: true);
    }
    final arguments = <String>[
      '-m',
      'transvortex.app_service',
      '--root',
      runtimeRoot.path,
      if (taskArtifactsRoot != null) ...[
        '--artifacts-dir',
        taskArtifactsRoot.path,
      ],
      if (taskCacheRoot != null) ...['--cache-dir', taskCacheRoot.path],
    ];
    final process = await _processStarter(
      servicePython,
      arguments,
      workingDirectory: root.path,
      environment: {
        'PYTHONIOENCODING': 'utf-8',
        'PYTHONUTF8': '1',
        if (hasBundledMediaTools)
          'TRANSVORTEX_MEDIA_TOOLS_DIR': bundledMediaTools.path,
        if (useBundledRuntime) ...{
          'PYTHONPATH': '',
          'PYTHONNOUSERSITE': '1',
        } else
          'PYTHONPATH': _pythonPath(root),
      },
    );
    final transport = JsonRpcTransport(
      stdout: process.stdout,
      stdin: process.stdin,
      stderr: process.stderr,
      exitCode: process.exitCode,
      defaultTimeout: requestTimeout,
    );
    return LocalServiceSession(
      process: process,
      transport: transport,
      client: AppServiceClient(transport),
    );
  }

  static Future<Directory> _prepareDesktopRuntimeRoot(
    Directory repoRoot,
    Directory runtimeRoot,
  ) async {
    if (!runtimeRoot.existsSync()) {
      await runtimeRoot.create(recursive: true);
    }
    await _copyConfigIfMissing(
      source: _desktopPipelineSeed(repoRoot),
      target: File('${runtimeRoot.path}${Platform.pathSeparator}pipeline.yaml'),
      fallback: 'artifacts_dir: artifacts\n',
    );
    await _syncDesktopDefaultConfig(
      source: File('${repoRoot.path}${Platform.pathSeparator}providers.yaml'),
      target: File(
        '${runtimeRoot.path}${Platform.pathSeparator}providers.yaml',
      ),
      localOverride: File(
        '${runtimeRoot.path}${Platform.pathSeparator}providers.local.yaml',
      ),
    );
    return runtimeRoot;
  }

  static File _desktopPipelineSeed(Directory repoRoot) {
    final productSeed = File(
      '${repoRoot.path}${Platform.pathSeparator}pipeline.desktop.yaml',
    );
    if (productSeed.existsSync()) return productSeed;
    return File('${repoRoot.path}${Platform.pathSeparator}pipeline.yaml');
  }

  static Future<void> _copyConfigIfMissing({
    required File source,
    required File target,
    String fallback = '',
  }) async {
    if (target.existsSync()) return;
    await target.parent.create(recursive: true);
    if (source.existsSync()) {
      await source.copy(target.path);
      return;
    }
    if (fallback.isNotEmpty) {
      await target.writeAsString(fallback);
    }
  }

  static Future<void> _syncDesktopDefaultConfig({
    required File source,
    required File target,
    required File localOverride,
    String fallback = '',
  }) async {
    if (localOverride.existsSync()) return;
    await target.parent.create(recursive: true);
    if (source.existsSync()) {
      await source.copy(target.path);
      return;
    }
    if (!target.existsSync() && fallback.isNotEmpty) {
      await target.writeAsString(fallback);
    }
  }

  static Directory? findAppRoot() {
    final candidates = <Directory>[
      File(Platform.resolvedExecutable).parent,
      Directory.current,
    ];
    for (final start in candidates) {
      var cursor = start;
      while (true) {
        if (_hasBundledRuntimeManifest(cursor) ||
            _hasDevelopmentService(cursor)) {
          return cursor;
        }
        final parent = cursor.parent;
        if (parent.path == cursor.path) break;
        cursor = parent;
      }
    }
    return null;
  }

  static Directory? findRepoRoot() {
    for (final start in <Directory>[
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ]) {
      var cursor = start;
      while (true) {
        if (_hasDevelopmentService(cursor)) return cursor;
        final parent = cursor.parent;
        if (parent.path == cursor.path) break;
        cursor = parent;
      }
    }
    return null;
  }

  static bool _hasBundledRuntimeManifest(Directory root) {
    return File(
      '${root.path}${Platform.pathSeparator}runtime'
      '${Platform.pathSeparator}app_runtime.json',
    ).existsSync();
  }

  static bool _hasDevelopmentService(Directory root) {
    return File(
      '${root.path}${Platform.pathSeparator}src'
      '${Platform.pathSeparator}transvortex'
      '${Platform.pathSeparator}app_service.py',
    ).existsSync();
  }

  static bool _hasBundledMediaToolsManifest(Directory root) {
    return File(
      '${root.path}${Platform.pathSeparator}tools'
      '${Platform.pathSeparator}ffmpeg'
      '${Platform.pathSeparator}ffmpeg_runtime.json',
    ).existsSync();
  }

  static File _bundledPython(Directory root) {
    return File(
      '${root.path}${Platform.pathSeparator}runtime'
      '${Platform.pathSeparator}python'
      '${Platform.pathSeparator}python.exe',
    );
  }

  static Directory _bundledMediaTools(Directory root) {
    return Directory(
      '${root.path}${Platform.pathSeparator}tools'
      '${Platform.pathSeparator}ffmpeg'
      '${Platform.pathSeparator}bin',
    );
  }

  static File _bundledFfmpeg(Directory root) {
    return File(
      '${_bundledMediaTools(root).path}${Platform.pathSeparator}ffmpeg.exe',
    );
  }

  static File _bundledFfprobe(Directory root) {
    return File(
      '${_bundledMediaTools(root).path}${Platform.pathSeparator}ffprobe.exe',
    );
  }

  static String _pythonPath(Directory root) {
    final entries = <String>[
      '${root.path}${Platform.pathSeparator}src',
      root.path,
      if ((Platform.environment['PYTHONPATH'] ?? '').trim().isNotEmpty)
        Platform.environment['PYTHONPATH']!,
    ];
    return entries.join(Platform.isWindows ? ';' : ':');
  }
}

abstract class LocalServiceHandle {
  AppServiceClient get client;

  Future<int> get exitCode;

  Future<void> shutdown({
    Duration rpcTimeout = const Duration(seconds: 2),
    Duration exitTimeout = const Duration(seconds: 2),
  });
}

class LocalServiceSession implements LocalServiceHandle {
  LocalServiceSession({
    required this.process,
    required this.transport,
    required this.client,
  });

  final Process process;
  final JsonRpcTransport transport;
  @override
  final AppServiceClient client;

  @override
  Future<int> get exitCode => process.exitCode;

  @override
  Future<void> shutdown({
    Duration rpcTimeout = const Duration(seconds: 2),
    Duration exitTimeout = const Duration(seconds: 2),
  }) async {
    try {
      await client.shutdown().timeout(rpcTimeout);
    } on Object {
      // Fall back to stream close / process termination below.
    }
    await transport.close();
    try {
      await process.exitCode.timeout(exitTimeout);
    } on TimeoutException {
      process.kill();
    }
  }
}
