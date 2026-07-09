import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../model/window_state.dart';
import '../theme/tokens.dart';

Future<void> Function(AppWindowArgs args)? _retargetHandler;
_WindowGeometryMemoryListener? _geometryMemoryListener;
AppWindowArgs? _configuredWindowArgs;
WindowGeometryMemory? _windowGeometryMemory = WindowGeometryMemory.userStore();

void registerCurrentWindowRetargetHandler(
  Future<void> Function(AppWindowArgs args)? handler,
) {
  _retargetHandler = handler;
}

Future<void> configureCurrentWindow(AppWindowArgs args) async {
  await windowManager.ensureInitialized();

  _configuredWindowArgs = args;
  final rememberedBounds = await _windowGeometryMemory?.readBounds(args.type);
  final geometry = windowGeometryFor(args, rememberedBounds: rememberedBounds);
  final options = WindowOptions(
    size: geometry.size,
    center: geometry.center,
    minimumSize: geometry.minimumSize,
    backgroundColor: T.bg,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  await windowManager.waitUntilReadyToShow(options);
  await windowManager.setAsFrameless();
  await windowManager.setHasShadow(false);
  await windowManager.setResizable(geometry.resizable);
  await windowManager.setMaximizable(geometry.maximizable);
  if (geometry.position != null) {
    await windowManager.setPosition(geometry.position!);
  } else if (geometry.alignment != null) {
    await windowManager.setAlignment(geometry.alignment!);
  }
  await _installWindowGeometryMemory(args.type);
}

@visibleForTesting
WindowGeometry windowGeometryFor(AppWindowArgs args, {Rect? rememberedBounds}) {
  final type = args.type;
  final role = _roleFor(type);
  final minimumSize = _minimumSize(type);
  final hasRememberedBounds =
      role != WindowRole.main && rememberedBounds != null;
  final size = hasRememberedBounds
      ? _normalizeRememberedSize(rememberedBounds.size, minimumSize)
      : _defaultSize(type);
  final proposedPosition = hasRememberedBounds
      ? rememberedBounds.topLeft
      : args.parentBounds == null
      ? null
      : _positionFromParent(args.parentBounds!, type);
  final position = proposedPosition == null
      ? null
      : clampWindowPosition(proposedPosition, size, args.visibleBounds);
  return switch (role) {
    WindowRole.main => WindowGeometry(
      role: role,
      size: size,
      center: true,
      resizable: false,
      maximizable: false,
    ),
    WindowRole.tool => WindowGeometry(
      role: role,
      size: size,
      minimumSize: minimumSize,
      center: false,
      position: position,
      alignment: position == null ? Alignment.topRight : null,
      resizable: true,
      maximizable: false,
    ),
    WindowRole.workbench => WindowGeometry(
      role: role,
      size: size,
      minimumSize: minimumSize,
      center: position == null,
      position: position,
      resizable: true,
      maximizable: true,
    ),
  };
}

@visibleForTesting
class WindowGeometryMemory {
  WindowGeometryMemory(this.file);

  final File file;

  static WindowGeometryMemory? userStore() {
    final home = _transvortexHomePath();
    if (home == null || home.isEmpty) return null;
    return WindowGeometryMemory(
      File(_joinPath(home, 'desktop_window_geometry.json')),
    );
  }

  Future<Rect?> readBounds(AppWindowType type) async {
    final key = _geometryMemoryKey(type);
    if (key == null) return null;
    final document = await _readDocument();
    final windows = _asStringMap(document['windows']);
    return _rectFromJson(windows[key]);
  }

  Future<void> writeBounds(AppWindowType type, Rect bounds) async {
    final key = _geometryMemoryKey(type);
    if (key == null || bounds.width <= 0 || bounds.height <= 0) return;
    final document = await _readDocument();
    final windows = Map<String, Object?>.from(
      _asStringMap(document['windows']),
    );
    windows[key] = _rectToJson(bounds);
    await _writeDocument({'version': 1, 'windows': windows});
  }

  Future<void> reset([AppWindowType? type]) async {
    if (type == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    final key = _geometryMemoryKey(type);
    if (key == null || !await file.exists()) return;
    final document = await _readDocument();
    final windows = Map<String, Object?>.from(
      _asStringMap(document['windows']),
    );
    windows.remove(key);
    await _writeDocument({'version': 1, 'windows': windows});
  }

  Future<Map<String, Object?>> _readDocument() async {
    try {
      if (!await file.exists()) return const <String, Object?>{};
      final decoded = jsonDecode(await file.readAsString());
      return _asStringMap(decoded);
    } on Object {
      return const <String, Object?>{};
    }
  }

  Future<void> _writeDocument(Map<String, Object?> document) async {
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString('${encoder.convert(document)}\n');
  }
}

@visibleForTesting
Future<void> resetStoredWindowGeometry([AppWindowType? type]) async {
  await _windowGeometryMemory?.reset(type);
}

Future<void> _resetCurrentWindowGeometry() async {
  final args = _configuredWindowArgs;
  if (args == null) return;
  await resetStoredWindowGeometry(args.type);
  final geometry = windowGeometryFor(args);
  await windowManager.setSize(geometry.size);
  if (geometry.position != null) {
    await windowManager.setPosition(geometry.position!);
  } else if (geometry.alignment != null) {
    await windowManager.setAlignment(geometry.alignment!);
  }
}

@visibleForTesting
Offset clampWindowPosition(
  Offset position,
  Size windowSize,
  Rect? visibleBounds,
) {
  if (visibleBounds == null || visibleBounds.isEmpty) return position;
  final maxLeft =
      visibleBounds.right -
      (windowSize.width > visibleBounds.width
          ? visibleBounds.width
          : windowSize.width);
  final maxTop =
      visibleBounds.bottom -
      (windowSize.height > visibleBounds.height
          ? visibleBounds.height
          : windowSize.height);
  return Offset(
    position.dx.clamp(visibleBounds.left, maxLeft).toDouble(),
    position.dy.clamp(visibleBounds.top, maxTop).toDouble(),
  );
}

Size _normalizeRememberedSize(Size size, Size minimumSize) {
  return Size(
    math.max(size.width, minimumSize.width),
    math.max(size.height, minimumSize.height),
  );
}

Future<Rect?> currentDisplayVisibleBoundsFor(Rect? anchorBounds) async {
  try {
    final displays = await screenRetriever.getAllDisplays();
    if (displays.isEmpty) return null;
    final primaryDisplay = await screenRetriever.getPrimaryDisplay();
    final primaryBounds = _visibleBoundsForDisplay(primaryDisplay);
    final anchor = anchorBounds?.center;
    if (anchor != null) {
      for (final display in displays) {
        final bounds = _visibleBoundsForDisplay(display);
        if (bounds.contains(anchor)) return bounds;
      }
    }
    if (anchorBounds != null) {
      Rect? bestBounds;
      var bestArea = 0.0;
      for (final display in displays) {
        final bounds = _visibleBoundsForDisplay(display);
        final area = bounds.intersect(anchorBounds).size;
        final overlap = math.max(0.0, area.width) * math.max(0.0, area.height);
        if (overlap > bestArea) {
          bestArea = overlap;
          bestBounds = bounds;
        }
      }
      if (bestBounds != null) return bestBounds;
    }
    return primaryBounds;
  } on Object {
    return null;
  }
}

@visibleForTesting
class WindowGeometry {
  const WindowGeometry({
    required this.role,
    required this.size,
    required this.center,
    required this.resizable,
    required this.maximizable,
    this.minimumSize,
    this.position,
    this.alignment,
  });

  final WindowRole role;
  final Size size;
  final Size? minimumSize;
  final bool center;
  final Offset? position;
  final Alignment? alignment;
  final bool resizable;
  final bool maximizable;
}

@visibleForTesting
enum WindowRole { main, tool, workbench }

WindowRole _roleFor(AppWindowType type) => switch (type) {
  AppWindowType.main => WindowRole.main,
  AppWindowType.taskProcessing => WindowRole.workbench,
  AppWindowType.translationSettings ||
  AppWindowType.asrSettings ||
  AppWindowType.diagnostics => WindowRole.tool,
};

Size _defaultSize(AppWindowType type) => switch (type) {
  AppWindowType.main => const Size(720, 520),
  AppWindowType.translationSettings => const Size(820, 600),
  AppWindowType.asrSettings => const Size(760, 560),
  AppWindowType.diagnostics => const Size(780, 580),
  AppWindowType.taskProcessing => const Size(1040, 720),
};

Size _minimumSize(AppWindowType type) => switch (type) {
  AppWindowType.main => const Size(720, 520),
  AppWindowType.translationSettings => const Size(760, 540),
  AppWindowType.asrSettings => const Size(700, 500),
  AppWindowType.diagnostics => const Size(720, 520),
  AppWindowType.taskProcessing => const Size(900, 640),
};

Offset _positionFromParent(Rect parent, AppWindowType type) {
  final step = switch (type) {
    AppWindowType.translationSettings => 0,
    AppWindowType.asrSettings => 1,
    AppWindowType.diagnostics => 2,
    AppWindowType.taskProcessing => 2,
    AppWindowType.main => 0,
  };
  final isWorkbench = type == AppWindowType.taskProcessing;
  final dx = isWorkbench ? 112.0 : 72.0 + step * 28.0;
  final dy = isWorkbench ? 56.0 : 48.0 + step * 24.0;
  return Offset(parent.left + dx, parent.top + dy);
}

Rect _visibleBoundsForDisplay(Display display) {
  final position = display.visiblePosition ?? Offset.zero;
  final size = display.visibleSize ?? display.size;
  return position & size;
}

Future<void> _installWindowGeometryMemory(AppWindowType type) async {
  final memory = _windowGeometryMemory;
  _geometryMemoryListener?.dispose();
  if (_geometryMemoryListener != null) {
    windowManager.removeListener(_geometryMemoryListener!);
    _geometryMemoryListener = null;
  }
  if (memory == null || _geometryMemoryKey(type) == null) return;
  final listener = _WindowGeometryMemoryListener(type, memory);
  _geometryMemoryListener = listener;
  windowManager.addListener(listener);
}

class _WindowGeometryMemoryListener with WindowListener {
  _WindowGeometryMemoryListener(this.type, this.memory);

  final AppWindowType type;
  final WindowGeometryMemory memory;
  Timer? _debounce;

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowResized() => _scheduleSave();

  @override
  void onWindowUnmaximize() => _scheduleSave();

  @override
  void onWindowUndocked() => _scheduleSave();

  @override
  void onWindowClose() => unawaited(_save());

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    try {
      if (await windowManager.isMinimized() ||
          await windowManager.isMaximized() ||
          await windowManager.isFullScreen()) {
        return;
      }
      final bounds = await windowManager.getBounds();
      await memory.writeBounds(type, bounds);
    } on Object {
      // Geometry memory is a convenience; it must not block window controls.
    }
  }

  void dispose() {
    _debounce?.cancel();
  }
}

Future<void> registerCurrentWindowControls() async {
  try {
    final current = await WindowController.fromCurrentEngine();
    await current.setWindowMethodHandler((call) async {
      switch (call.method) {
        case 'window_focus':
          await windowManager.show();
          await windowManager.focus();
          return null;
        case 'window_retarget':
          final retargetArgs = AppWindowArgs.parse('${call.arguments}');
          final handler = _retargetHandler;
          if (handler != null) {
            await handler(retargetArgs);
          }
          await windowManager.show();
          await windowManager.focus();
          return null;
        case 'window_close':
          await windowManager.close();
          return null;
        case 'window_reset_geometry':
          await _resetCurrentWindowGeometry();
          return {'ok': true};
        default:
          throw MissingPluginException('No handler for ${call.method}');
      }
    });
  } on Object {
    // Widget tests and unsupported hosts still render the Flutter tree.
  }
}

String? _geometryMemoryKey(AppWindowType type) {
  final role = _roleFor(type);
  if (role == WindowRole.main) return null;
  return '${role.name}:${type.id}';
}

Map<String, Object?> _rectToJson(Rect rect) => {
  'x': rect.left,
  'y': rect.top,
  'width': rect.width,
  'height': rect.height,
};

Rect? _rectFromJson(Object? value) {
  final map = _asStringMap(value);
  final x = _numToDouble(map['x'] ?? map['left']);
  final y = _numToDouble(map['y'] ?? map['top']);
  final width = _numToDouble(map['width'] ?? map['w']);
  final height = _numToDouble(map['height'] ?? map['h']);
  if (x == null || y == null || width == null || height == null) return null;
  if (width <= 0 || height <= 0) return null;
  return Rect.fromLTWH(x, y, width, height);
}

Map<String, Object?> _asStringMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return const <String, Object?>{};
}

double? _numToDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

String? _transvortexHomePath() {
  final explicit = Platform.environment['TRANSVORTEX_HOME']?.trim();
  if (explicit != null && explicit.isNotEmpty) {
    return _expandHome(explicit);
  }
  final home = Platform.isWindows
      ? Platform.environment['USERPROFILE']?.trim()
      : Platform.environment['HOME']?.trim();
  if (home == null || home.isEmpty) return null;
  return _joinPath(_expandHome(home), '.transvortex');
}

String _expandHome(String path) {
  if (path == '~') return _platformHomePath() ?? path;
  if (path.startsWith('~/') || path.startsWith(r'~\')) {
    final home = _platformHomePath();
    if (home == null || home.isEmpty) return path;
    return _joinPath(home, path.substring(2));
  }
  return path;
}

String? _platformHomePath() {
  return Platform.isWindows
      ? Platform.environment['USERPROFILE']?.trim()
      : Platform.environment['HOME']?.trim();
}

String _joinPath(String first, String second) {
  if (first.endsWith('/') || first.endsWith(r'\')) return '$first$second';
  return '$first${Platform.pathSeparator}$second';
}

Future<void> showConfiguredWindow() async {
  try {
    await windowManager.show();
    await windowManager.focus();
  } on Object {
    // Widget tests and unsupported hosts still render the Flutter tree.
  }
}
