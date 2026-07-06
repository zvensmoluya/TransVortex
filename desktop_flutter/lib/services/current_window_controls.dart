import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../model/window_state.dart';
import '../theme/tokens.dart';

Future<void> Function(AppWindowArgs args)? _retargetHandler;

void registerCurrentWindowRetargetHandler(
  Future<void> Function(AppWindowArgs args)? handler,
) {
  _retargetHandler = handler;
}

Future<void> configureCurrentWindow(AppWindowArgs args) async {
  await windowManager.ensureInitialized();

  final geometry = windowGeometryFor(args);
  final options = WindowOptions(
    size: geometry.size,
    center: geometry.center,
    minimumSize: geometry.minimumSize,
    backgroundColor: T.bg,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  await windowManager.waitUntilReadyToShow(options);
  await windowManager.setResizable(geometry.resizable);
  await windowManager.setMaximizable(geometry.maximizable);
  if (geometry.position != null) {
    await windowManager.setPosition(geometry.position!);
  } else if (geometry.alignment != null) {
    await windowManager.setAlignment(geometry.alignment!);
  }
}

@visibleForTesting
WindowGeometry windowGeometryFor(AppWindowArgs args) {
  final type = args.type;
  final role = _roleFor(type);
  final size = _defaultSize(type);
  final proposedPosition = args.parentBounds == null
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
      minimumSize: _minimumSize(type),
      center: false,
      position: position,
      alignment: position == null ? Alignment.topRight : null,
      resizable: true,
      maximizable: false,
    ),
    WindowRole.workbench => WindowGeometry(
      role: role,
      size: size,
      minimumSize: _minimumSize(type),
      center: position == null,
      position: position,
      resizable: true,
      maximizable: true,
    ),
  };
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
        default:
          throw MissingPluginException('No handler for ${call.method}');
      }
    });
  } on Object {
    // Widget tests and unsupported hosts still render the Flutter tree.
  }
}

Future<void> showConfiguredWindow() async {
  try {
    await windowManager.show();
    await windowManager.focus();
  } on Object {
    // Widget tests and unsupported hosts still render the Flutter tree.
  }
}
