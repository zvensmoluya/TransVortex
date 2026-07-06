import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../model/window_state.dart';
import '../theme/tokens.dart';

Future<void> configureCurrentWindow(AppWindowType type) async {
  await windowManager.ensureInitialized();

  final size = switch (type) {
    AppWindowType.main => const Size(720, 520),
    AppWindowType.translationSettings => const Size(820, 600),
    AppWindowType.asrSettings => const Size(760, 560),
    AppWindowType.diagnostics => const Size(760, 560),
    AppWindowType.resultReview => const Size(900, 640),
    AppWindowType.taskHistory => const Size(820, 600),
    AppWindowType.taskDetail => const Size(860, 620),
  };

  final options = WindowOptions(
    size: size,
    center: true,
    backgroundColor: T.bg,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  await windowManager.waitUntilReadyToShow(options);
  await windowManager.setResizable(false);
  await windowManager.setMaximizable(false);
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
